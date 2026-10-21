-- scrubber_updater.lua — PageScrubber
-- Busca actualizaciones del plugin en GitHub y las instala desde el propio lector.
-- Pregunta por la última release, la compara con la versión instalada (campo `version` de _meta.lua)
-- y, si el usuario acepta, descarga el .zip, lo descomprime en una carpeta temporal y lo copia
-- encima de la carpeta del plugin (guardando antes una copia para poder volver atrás si falla).
-- Después de copiar, borra los archivos instalados (.lua, .svg, .png, .po) que ya no están en la versión nueva
-- (así, si un archivo se mueve de carpeta o se elimina, no quedan copias viejas sueltas) y las carpetas que
-- hayan quedado vacías.
-- Al detectar una versión nueva se abre un visor (TextViewer) con las notas completas y los botones Install / Cancel.
-- Al terminar ofrece reiniciar KOReader.
-- Basado en el updater de Kobold/Mythos.

local ConfirmBox  = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local UIManager   = require("ui/uimanager")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local _           = require("gettext")

local Updater = {}

local API_URL    = "https://api.github.com/repos/lautaroelkin/page_scrubber.koplugin/releases/latest"
local ASSET_NAME = "page_scrubber.koplugin.zip"   -- asset preferido de la release (si no está, se usa el primer .zip o el zip del código)

-- Carpeta de este plugin (donde vive este archivo)
local PLUGIN_DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")

-- Versión instalada: campo `version` de _meta.lua (ej: version = "1.2.0")
local cached_version
function Updater.installedVersion()
    if cached_version then return cached_version end
    if not PLUGIN_DIR then return nil end
    local ok, meta = pcall(dofile, PLUGIN_DIR .. "/_meta.lua")
    if ok and type(meta) == "table" and meta.version then
        cached_version = tostring(meta.version)   -- se guarda: los ajustes lo consultan en cada pintado
        return cached_version
    end
    return nil
end

-- true si la versión a es más nueva que b ("v1.2" > "1.1.9")
local function newer(a, b)
    local function parts(v)
        v = (v or ""):match("^v?(.-)[-+]") or (v or ""):match("^v?(.+)$") or ""
        local t = {}
        for n in (v .. "."):gmatch("(%d+)%.") do t[#t + 1] = tonumber(n) or 0 end
        while #t < 3 do t[#t + 1] = 0 end
        return t
    end
    local pa, pb = parts(a), parts(b)
    for i = 1, 3 do
        if pa[i] ~= pb[i] then return pa[i] > pb[i] end
    end
    return false
end

local function request(url, sink, headers)
    local https = require("ssl.https")
    local http = require("socket.http")
    local req = url:match("^https") and https or http
    local h = { ["User-Agent"] = "KOReader-PageScrubber-Updater" }
    for k, v in pairs(headers or {}) do h[k] = v end
    return req.request{ url = url, sink = sink, headers = h }
end

local function httpGet(url)
    local ltn12 = require("ltn12")
    local out = {}
    local ok, code = request(url, ltn12.sink.table(out), { ["Accept"] = "application/vnd.github.v3+json" })
    if not ok or code ~= 200 then return nil, tostring(code) end
    return table.concat(out)
end

-- Los archivos de las releases redirigen al servidor de archivos de GitHub: se sigue un redirect
local function download(url, dest)
    local ltn12 = require("ltn12")
    local ok, code, headers = request(url, ltn12.sink.table({}))
    local final = url
    if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
        final = headers and (headers.location or headers.Location)
        if not final then return nil, "redirect without a location" end
    elseif not ok or code ~= 200 then
        return nil, tostring(code)
    end
    local fh, err = io.open(dest, "wb")
    if not fh then return nil, tostring(err) end
    local ok2, code2 = request(final, ltn12.sink.file(fh))
    if not ok2 or code2 ~= 200 then
        pcall(os.remove, dest)
        return nil, tostring(code2)
    end
    return true
end

local NOTES_MAX = 4000

-- Markdown de GitHub -> texto plano legible: sin #, **, *, `código` ni enlaces [texto](url).
local function cleanNotes(raw)
    local t = (raw or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    t = t:gsub("<!%-%-.-%-%->", "")                  -- comentarios HTML (marcas)
    t = t:gsub("%[([^%]]+)%]%([^%)]+%)", "%1")       -- [texto](url) -> texto
    t = t:gsub("\n[ \t]*[%*%+][ \t]+", "\n- ")             -- viñetas "* " / "+ " -> "- " (antes de tocar los *)
    t = t:gsub("^[ \t]*[%*%+][ \t]+", "- ")
    t = t:gsub("\n#+[ \t]*", "\n"):gsub("^#+[ \t]*", "")    -- títulos "## Texto" -> "Texto"
    t = t:gsub("%*%*(.-)%*%*", "%1")
    t = t:gsub("%*([^%s%*][^%*\n]-)%*", "%1")
    t = t:gsub("`(.-)`", "%1")
    t = t:gsub("\n%s*\n%s*\n+", "\n\n")
    t = t:match("^%s*(.-)%s*$") or ""
    if #t > NOTES_MAX then t = t:sub(1, NOTES_MAX - 3) .. "..." end
    return t
end

-- { version, url, notes } de la última release, o nil y el motivo.
-- Las notas son el texto entre <!--pagescrubber--> y <!--/pagescrubber--> de la descripción de la release,
-- o toda la descripción si no hay marcas. Se limpia el markdown (el visor muestra texto plano) y solo se recorta
-- si pasa de NOTES_MAX caracteres (mismo criterio que el updater de X-Ray).
local function latestRelease()
    local body, err = httpGet(API_URL)
    if not body then return nil, err end
    local ok, JSON = pcall(require, "rapidjson")
    if not ok then ok, JSON = pcall(require, "json") end
    if not ok then return nil, "no JSON reader" end
    local ok_d, data = pcall(JSON.decode, body)
    if not ok_d or type(data) ~= "table" or not data.tag_name then return nil, "bad release data" end

    local url
    for _i, asset in ipairs(data.assets or {}) do
        if asset.name == ASSET_NAME then url = asset.browser_download_url break end
    end
    if not url then
        for _i, asset in ipairs(data.assets or {}) do
            if type(asset.name) == "string" and asset.name:match("%.zip$") then
                url = asset.browser_download_url
                break
            end
        end
    end
    if not url then url = data.zipball_url end   -- zip del código de la release (si no se subió ningún .zip)

    local raw = (data.body or ""):gsub("\r\n", "\n")
    local notes = raw:match("<!%-%-pagescrubber%-%->(.-)<!%-%-/pagescrubber%-%->")
    if not notes or not notes:match("%S") then notes = raw end
    notes = cleanNotes(notes)
    return { version = data.tag_name:match("^v?(.*)$"), url = url, notes = notes ~= "" and notes or nil }
end

local function sh(cmd)
    local ret = os.execute(cmd)
    return ret == 0 or ret == true
end

-- Extensiones que la limpieza considera "del plugin". Además de .lua y .svg (pedidos), se incluyen .png y .po
-- (iconos raster y traducciones) con el mismo criterio: instalado, pero ausente en la versión nueva.
local CLEAN_EXT = { lua = true, svg = true, png = true, po = true }

-- Los enlaces simbólicos no se siguen ni se borran: así nunca se sale de la carpeta del plugin.
local linkAttributes = lfs.symlinkattributes or lfs.attributes

-- Todos los archivos con extensión de CLEAN_EXT de una carpeta (recursivo), como set de rutas relativas
-- ("scrubber_ui.lua", "grid/grid_view.lua", "icons/undo.svg")
local function listFiles(root, rel, out)
    rel = rel or ""
    out = out or {}
    local path = rel == "" and root or (root .. "/" .. rel)
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if not ok or not iter then return out end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." then
            local r = rel == "" and name or (rel .. "/" .. name)
            local mode = linkAttributes(root .. "/" .. r, "mode")
            if mode == "directory" then
                listFiles(root, r, out)
            elseif mode == "file" then
                local ext = name:match("%.([^.]+)$")
                if ext and CLEAN_EXT[ext:lower()] then out[r] = true end
            end
        end
    end
    return out
end

-- Borra de `installed_dir` los archivos (.lua, .svg, .png, .po) que no vienen en `new_dir` (la versión recién
-- copiada) y después las carpetas que hayan quedado vacías (nunca la carpeta del plugin en sí).
-- Seguro: si lo descargado no trae main.lua y _meta.lua, no borra nada. Si un borrado falla, lo registra y sigue.
local function removeStaleFiles(new_dir, installed_dir)
    local fresh = listFiles(new_dir)
    if not fresh["main.lua"] or not fresh["_meta.lua"] then return 0 end
    local removed = 0
    local touched = {}   -- carpetas (rutas relativas) donde se borró algo: candidatas a quedar vacías
    for rel in pairs(listFiles(installed_dir)) do
        if not fresh[rel] then
            local ok, res, err = pcall(os.remove, installed_dir .. "/" .. rel)
            if ok and res then
                removed = removed + 1
                logger.info("PageScrubber: removed stale file", rel)
                local d = rel:match("^(.*)/[^/]+$")
                while d and not touched[d] do   -- también los padres (icons/sub/ → icons/)
                    touched[d] = true
                    d = d:match("^(.*)/[^/]+$")
                end
            else
                logger.warn("PageScrubber: could not remove stale file", rel, tostring(ok and err or res))
            end
        end
    end
    -- Carpetas vacías: de la más profunda a la más superficial. lfs.rmdir solo borra directorios vacíos,
    -- así que una carpeta con cualquier otro contenido (u otro tipo de archivo) simplemente se queda.
    local dirs = {}
    for d in pairs(touched) do dirs[#dirs + 1] = d end
    table.sort(dirs, function(a, b)
        local _n1, da = a:gsub("/", "")
        local _n2, db = b:gsub("/", "")
        if da ~= db then return da > db end
        return a > b
    end)
    for _i, d in ipairs(dirs) do
        local path = installed_dir .. "/" .. d
        if linkAttributes(path, "mode") == "directory" then
            local ok, res = pcall(lfs.rmdir, path)
            if ok and res then
                logger.info("PageScrubber: removed empty folder", d)
            else
                logger.dbg("PageScrubber: kept non-empty folder", d)
            end
        end
    end
    return removed
end

-- Descarga e instala `release`. Corre con un pequeño retraso para que el mensaje "Downloading" ya esté en pantalla.
local function install(release)
    local dir = PLUGIN_DIR
    if not dir then
        UIManager:show(InfoMessage:new{ text = _("Cannot find PageScrubber's folder. Please update manually.") })
        return
    end
    local work = DataStorage:getSettingsDir() .. "/page_scrubber_update"
    local zip = work .. ".zip"
    local backup = work .. "_backup"
    local progress = InfoMessage:new{ text = string.format(_("Downloading PageScrubber %s…"), release.version), timeout = 120 }
    UIManager:show(progress)
    UIManager:scheduleIn(0.3, function()
        local ok, err = download(release.url, zip)
        UIManager:close(progress)
        if not ok then
            UIManager:show(InfoMessage:new{ text = _("Download failed: ") .. tostring(err), timeout = 5 })
            return
        end

        sh(string.format("rm -rf %q", work))
        lfs.mkdir(work)
        local unzipped = sh(string.format("unzip -o -q %q -d %q", zip, work))
        os.remove(zip)

        -- El zip trae una carpeta (*.koplugin, o la del zip del código); su contenido va encima del plugin.
        local inner, only_dir, n_dirs
        n_dirs = 0
        for name in lfs.dir(work) do
            if name ~= "." and name ~= ".." then
                local path = work .. "/" .. name
                if lfs.attributes(path, "mode") == "directory" then
                    n_dirs = n_dirs + 1
                    only_dir = path
                    if name:match("%.koplugin$") then inner = path end
                end
            end
        end
        inner = inner or (n_dirs == 1 and only_dir) or nil

        -- Seguro: solo se instala si lo descargado realmente es el plugin (tiene main.lua)
        local valid = unzipped and inner and lfs.attributes(inner .. "/main.lua", "mode") == "file"
        if not valid then
            sh(string.format("rm -rf %q", work))
            logger.err("PageScrubber: update package is not valid", tostring(unzipped), tostring(inner))
            UIManager:show(InfoMessage:new{ text = _("Installing the update failed. Please update manually."), timeout = 5 })
            return
        end

        -- Copia de seguridad de la versión actual, por si algo sale mal al copiar
        sh(string.format("rm -rf %q", backup))
        lfs.mkdir(backup)
        local backed_up = sh(string.format("cp -rf %q/. %q/", dir, backup))

        local copied = sh(string.format("cp -rf %q/. %q/", inner, dir))
        if not copied then
            if backed_up then sh(string.format("cp -rf %q/. %q/", backup, dir)) end
            sh(string.format("rm -rf %q %q", work, backup))
            logger.err("PageScrubber: update install failed")
            UIManager:show(InfoMessage:new{ text = _("Installing the update failed. The previous version was restored."), timeout = 5 })
            return
        end

        -- Limpieza: archivos viejos (.lua, .svg, .png, .po) que la versión nueva ya no trae, y carpetas que quedaron
        -- vacías (si falla, no impide terminar la instalación)
        pcall(removeStaleFiles, inner, dir)

        sh(string.format("rm -rf %q %q", work, backup))
        UIManager:show(ConfirmBox:new{
            text = string.format(_("PageScrubber %s is installed.\n\nRestart KOReader to use it?"), release.version),
            ok_text = _("Restart now"),
            cancel_text = _("Later"),
            ok_callback = function()
                if UIManager.restartKOReader then
                    UIManager:restartKOReader()
                else
                    UIManager:show(InfoMessage:new{ text = _("Please restart KOReader to use the new version.") })
                end
            end,
        })
    end)
end

-- Visor con las notas completas de la release (scrolleable, sin recortar) y los botones Install / Cancel.
-- Se abre directamente al detectar una versión nueva (sin paso intermedio con un resumen corto).
local function showUpdateDialog(release, current)
    local TextViewer = require("ui/widget/textviewer")
    local text = string.format(_("PageScrubber %s is available. You have %s."), release.version, current)
        .. (release.notes and ("\n\n" .. release.notes) or "")
        .. "\n\n" .. _("Download and install now?")
    local viewer
    viewer = TextViewer:new{
        title = "PageScrubber " .. tostring(release.version),
        text = text,
        justified = false,   -- las notas son texto de GitHub (listas, líneas cortas): mejor sin justificar
        buttons_table = {{
            {
                text = _("Cancel"),
                callback = function() UIManager:close(viewer) end,
            },
            {
                text = _("Install"),
                is_enter_default = true,
                callback = function()
                    UIManager:close(viewer)
                    install(release)
                end,
            },
        }},
    }
    UIManager:show(viewer)
end

-- Busca una release más nueva en GitHub y ofrece instalarla. Enciende el Wi-Fi si hace falta,
-- como hacen las funciones de red del propio KOReader.
function Updater.check()
    local current = Updater.installedVersion()
    if not current then
        UIManager:show(InfoMessage:new{
            text = _("Could not read the installed version. Add a version line to _meta.lua, for example: version = \"1.0.0\""),
        })
        return
    end

    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local checking = InfoMessage:new{ text = _("Checking for updates…"), timeout = 15 }
        UIManager:show(checking)
        UIManager:scheduleIn(0.3, function()
            local release, err = latestRelease()
            UIManager:close(checking)
            if not release then
                UIManager:show(InfoMessage:new{ text = _("Could not check for updates: ") .. tostring(err), timeout = 4 })
                return
            end
            if not newer(release.version, current) then
                UIManager:show(InfoMessage:new{
                    text = string.format(_("PageScrubber is up to date (%s)."), current), timeout = 3,
                })
                return
            end
            if not release.url then
                UIManager:show(InfoMessage:new{
                    text = string.format(_("PageScrubber %s is out, but its download is not ready yet."), release.version),
                })
                return
            end
            showUpdateDialog(release, current)
        end)
    end)
end

return Updater

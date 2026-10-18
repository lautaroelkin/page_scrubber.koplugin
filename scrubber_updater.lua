-- scrubber_updater.lua — PageScrubber
-- Busca actualizaciones del plugin en GitHub y las instala desde el propio lector.
-- Pregunta por la última release, la compara con la versión instalada (campo `version` de _meta.lua)
-- y, si el usuario acepta, descarga el .zip, lo descomprime en una carpeta temporal y lo copia
-- encima de la carpeta del plugin (guardando antes una copia para poder volver atrás si falla).
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

-- { version, url, notes } de la última release, o nil y el motivo.
-- Las notas son el texto entre <!--pagescrubber--> y <!--/pagescrubber--> de la descripción de la release,
-- o el principio de la descripción si no hay marcas.
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
    if not notes or not notes:match("%S") then
        notes = #raw > 600 and (raw:sub(1, 600) .. "...") or raw
    end
    notes = notes:match("^%s*(.-)%s*$")
    return { version = data.tag_name:match("^v?(.*)$"), url = url, notes = notes ~= "" and notes or nil }
end

local function sh(cmd)
    local ret = os.execute(cmd)
    return ret == 0 or ret == true
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
            UIManager:show(ConfirmBox:new{
                text = string.format(_("PageScrubber %s is available. You have %s."), release.version, current)
                    .. (release.notes and ("\n\n" .. release.notes) or "")
                    .. "\n\n" .. _("Download and install now?"),
                ok_text = _("Install"),
                ok_callback = function() install(release) end,
            })
        end)
    end)
end

return Updater

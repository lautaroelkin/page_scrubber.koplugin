--[[
    page_scrubber.koplugin/sel_custom_buttons.lua

    Botones propios del selection menu ("Add button" en Settings > Selection menu >
    Buttons in selection menu). El usuario elige uno de los botones que otros plugins
    agregan al diálogo de resaltado de KOReader (los que hoy aparecen al tocar "More") y
    le pone un svg; el botón pasa a la barra principal, con su lugar en la lista ordenable.

    Cada botón guardado es { key, id, reg_key, text, icon }:
      key      "ext_<id>": su clave en la lista de orden (page_scrubber_sel_btn_order) y base
               de su ajuste de encendido (page_scrubber_sel_show_<key>)
      id       el id del botón del otro plugin (btn.id, o la clave con que se registró)
      reg_key  la clave con que el otro plugin lo registró en ui.highlight._highlight_buttons
      text     su texto (para mostrarlo en la lista y como respaldo sin svg)
      icon     nombre del svg copiado en settings/page_scrubber/button_icons/ (nil = solo texto)

    El svg elegido se COPIA a esa carpeta, así sigue funcionando aunque el original se
    mueva o se borre, y "Reset all to default" de Custom icons no lo toca.
]]--

local DataStorage = require("datastorage")

local M = {}

M.SETTING    = "page_scrubber_sel_custom_buttons"
M.ORDER_KEY  = "page_scrubber_sel_btn_order"
M.KEY_PREFIX = "ext_"
local MAX_SVG_BYTES = 512 * 1024

local function getLfs()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs then return lfs end
    ok, lfs = pcall(require, "lfs")
    return ok and lfs or nil
end

local function fileExists(p)
    if not p or p == "" then return false end
    local lfs = getLfs()
    if lfs then return lfs.attributes(p, "mode") == "file" end
    local f = io.open(p, "r")
    if f then f:close(); return true end
    return false
end

-- ── Carpeta de íconos ──────────────────────────────────────────────────────
function M.iconDir()
    return DataStorage:getSettingsDir() .. "/page_scrubber/button_icons"
end

local function ensureIconDir()
    local dir = M.iconDir()
    local lfs = getLfs()
    if lfs and lfs.attributes(dir, "mode") ~= "directory" then
        pcall(function() require("util").makePath(dir) end)
    end
    return dir
end

-- Copia src a dst (solo .svg, hasta 512 KB, que parezca un svg). Escribe a un temporal y
-- renombra, así un corte a mitad de la copia no deja un ícono roto.
local function copySvg(src, dst)
    if not fileExists(src) then return false, "missing file" end
    if not tostring(src):lower():match("%.svg$") then return false, "not an .svg" end
    local fin = io.open(src, "rb")
    if not fin then return false, "cannot open source" end
    local data = fin:read("*a")
    fin:close()
    if not data or #data == 0 then return false, "empty file" end
    if #data > MAX_SVG_BYTES then return false, "file too big" end
    if not data:lower():find("<svg", 1, true) then return false, "not a valid SVG" end

    local tmp = dst .. ".tmp"
    local fout = io.open(tmp, "wb")
    if not fout then return false, "cannot write" end
    local ok_w = fout:write(data)
    fout:close()
    if not ok_w then os.remove(tmp); return false, "write failed" end
    os.remove(dst)
    local ok_r, err = os.rename(tmp, dst)
    if not ok_r then os.remove(tmp); return false, err or "rename failed" end
    return true
end

-- ── La lista guardada ──────────────────────────────────────────────────────
local function cleanList(raw)
    local out, seen = {}, {}
    if type(raw) ~= "table" then return out end
    for _i, e in ipairs(raw) do
        if type(e) == "table" and type(e.key) == "string" and e.key ~= ""
            and type(e.id) == "string" and e.id ~= "" and not seen[e.key] then
            seen[e.key] = true
            out[#out + 1] = {
                key = e.key, id = e.id,
                reg_key = type(e.reg_key) == "string" and e.reg_key or nil,
                text = (type(e.text) == "string" and e.text ~= "") and e.text or e.id,
                icon = type(e.icon) == "string" and e.icon ~= "" and e.icon or nil,
            }
        end
    end
    return out
end

function M.list()
    local raw = G_reader_settings and G_reader_settings:readSetting(M.SETTING)
    return cleanList(raw)
end

local function save(list)
    if not G_reader_settings then return end
    G_reader_settings:saveSetting(M.SETTING, list)
    G_reader_settings:flush()
end

function M.get(key)
    for _i, e in ipairs(M.list()) do
        if e.key == key then return e end
    end
    return nil
end

function M.isCustomKey(key)
    return type(key) == "string" and key:sub(1, #M.KEY_PREFIX) == M.KEY_PREFIX and M.get(key) ~= nil
end

-- El ajuste que enciende / apaga un botón (mismo patrón que los botones nativos)
function M.toggleSetting(key)
    return "page_scrubber_sel_show_" .. key
end

-- Ruta completa del svg de un botón, o nil si no tiene (o el archivo ya no está)
function M.iconPath(entry)
    if type(entry) ~= "table" or not entry.icon then return nil end
    local p = M.iconDir() .. "/" .. entry.icon
    if fileExists(p) then return p end
    return nil
end

-- Los ids de los botones personalizados que están encendidos: la fila de More no los repite
function M.shownIds()
    local out = {}
    for _i, e in ipairs(M.list()) do
        local on = G_reader_settings and G_reader_settings:readSetting(M.toggleSetting(e.key))
        if on == nil or on == true then out[e.id] = true end
    end
    return out
end

-- Las claves de los botones personalizados, en el orden en que se agregaron
function M.keys()
    local out = {}
    for _i, e in ipairs(M.list()) do out[#out + 1] = e.key end
    return out
end

-- Agrega las claves de los botones personalizados a una lista de orden por defecto, justo
-- antes de "more" (que siempre va en un extremo)
function M.withCustomKeys(default_order)
    local out = {}
    local customs = M.keys()
    local inserted = false
    for _i, k in ipairs(default_order) do
        if k == "more" and not inserted then
            for _j, ck in ipairs(customs) do out[#out + 1] = ck end
            inserted = true
        end
        out[#out + 1] = k
    end
    if not inserted then
        for _j, ck in ipairs(customs) do out[#out + 1] = ck end
    end
    return out
end

-- ── Alta, cambio de ícono y baja ───────────────────────────────────────────
local function keyFor(id)
    local base = tostring(id):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if base == "" then base = "button" end
    return M.KEY_PREFIX .. base:sub(1, 40)
end

-- Agrega el botón `info` ({ id, reg_key, text }) con el svg src_icon (o sin svg si es nil).
-- Devuelve true, o false y el motivo.
function M.add(info, src_icon)
    if type(info) ~= "table" or type(info.id) ~= "string" then return false, "no button" end
    local key = keyFor(info.id)
    local list = M.list()
    local entry
    for _i, e in ipairs(list) do
        if e.key == key then entry = e; break end
    end
    if not entry then
        entry = { key = key, id = info.id }
        list[#list + 1] = entry
    end
    entry.reg_key = info.reg_key
    entry.text = (type(info.text) == "string" and info.text ~= "") and info.text or info.id

    if src_icon then
        local dir = ensureIconDir()
        local name = key .. ".svg"
        local ok, err = copySvg(src_icon, dir .. "/" .. name)
        if not ok then return false, err end
        entry.icon = name
    end
    save(list)
    -- Si estaba apagado de antes, vuelve encendido
    if G_reader_settings then
        G_reader_settings:saveSetting(M.toggleSetting(key), true)
        G_reader_settings:flush()
    end
    return true
end

-- Cambia el svg de un botón ya agregado
function M.setIcon(key, src_icon)
    local list = M.list()
    for _i, e in ipairs(list) do
        if e.key == key then
            local dir = ensureIconDir()
            local name = key .. ".svg"
            local ok, err = copySvg(src_icon, dir .. "/" .. name)
            if not ok then return false, err end
            e.icon = name
            save(list)
            return true
        end
    end
    return false, "unknown button"
end

-- Le saca el svg a un botón (queda con su texto)
function M.clearIcon(key)
    local list = M.list()
    for _i, e in ipairs(list) do
        if e.key == key then
            if e.icon then os.remove(M.iconDir() .. "/" .. e.icon) end
            e.icon = nil
            save(list)
            return true
        end
    end
    return false
end

-- Quita un botón: su svg, su ajuste de encendido y su lugar en la lista de orden
function M.remove(key)
    local list = M.list()
    local kept, removed = {}, nil
    for _i, e in ipairs(list) do
        if e.key == key then removed = e else kept[#kept + 1] = e end
    end
    if not removed then return false end
    if removed.icon then os.remove(M.iconDir() .. "/" .. removed.icon) end
    save(kept)
    if G_reader_settings then
        G_reader_settings:delSetting(M.toggleSetting(key))
        local order = G_reader_settings:readSetting(M.ORDER_KEY)
        if type(order) == "table" then
            local new_order = {}
            for _i, k in ipairs(order) do
                if k ~= key then new_order[#new_order + 1] = k end
            end
            G_reader_settings:saveSetting(M.ORDER_KEY, new_order)
        end
        G_reader_settings:flush()
    end
    return true
end

-- Borra todos los svg copiados (al restablecer todos los ajustes)
function M.clearIcons()
    local dir = M.iconDir()
    local lfs = getLfs()
    if not lfs or lfs.attributes(dir, "mode") ~= "directory" then return end
    local to_remove = {}
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then to_remove[#to_remove + 1] = entry end
    end
    for _i, entry in ipairs(to_remove) do pcall(os.remove, dir .. "/" .. entry) end
end

-- ── Descubrir los botones de otros plugins ─────────────────────────────────
-- ¿Es un botón que el plugin ya resuelve por su cuenta (nativos de KOReader, X-Ray, el
-- asistente, resaltado, nota...)? Mismos criterios que la fila de More de floating_dict.lua.
local function isKnown(key, btn)
    local k_clean = tostring(key):gsub("^%d+_", ""):lower()
    local id_clean = tostring(btn.id or ""):lower()
    local txt_clean = tostring(btn.text or ""):lower()
    local function any_eq(...)
        for i = 1, select("#", ...) do
            local v = select(i, ...)
            if k_clean == v or id_clean == v or txt_clean == v then return true end
        end
        return false
    end
    if any_eq("select", "start_selection", "seleccionar", "copy", "copiar", "dict", "dictionary",
        "diccionario", "wiki", "wikipedia", "search", "buscar", "translate", "traducir",
        "highlight", "resaltar", "note", "add_note", "nota", "strike", "strikethrough",
        "underline", "invert", "assistant", "ai") then
        return true
    end
    local function has(s) return k_clean:find(s) or id_clean:find(s) or txt_clean:find(s) end
    if has("share") or has("compart") or has("html") or has("xray") or has("x%-ray") then return true end
    if txt_clean:find("assistant") or txt_clean:find("asistente") then return true end
    return false
end

local function buttonText(btn, hl)
    local t = btn.text
    if type(btn.text_func) == "function" then
        local ok, res = pcall(btn.text_func, hl)
        if ok and res then t = res end
    end
    t = tostring(t or "")
    if t == "" then t = tostring(btn.id or "?") end
    return t
end

local function iterator()
    local ok, ffiUtil = pcall(require, "ffi/util")
    return (ok and ffiUtil and ffiUtil.orderedPairs) or pairs
end

-- De dónde viene la función que arma un botón: el archivo donde está definida
local function sourceOf(fn)
    local ok, info = pcall(debug.getinfo, fn, "S")
    return (ok and info and tostring(info.source)) or ""
end

-- Los botones propios de KOReader (readerhighlight.lua) que no son los de siempre son
-- contextuales ("Hyphenate", "Follow Link"): dependen de la selección y de un link, así que
-- no tienen sentido como botón fijo y en More casi nunca aparecen.
local function isCore(fn)
    return sourceOf(fn):find("readerhighlight%.lua") ~= nil
end

-- El nombre del plugin que registró el botón ("xray" de plugins/xray.koplugin/...), para
-- mostrarlo como línea chica en la lista.
local function pluginNameOf(fn)
    local name = sourceOf(fn):match("([^/\\]+)%.koplugin")
    return name
end

-- ── Botones que ya aparecieron en More ─────────────────────────────────────
-- Un botón que depende de la selección (show_in_highlight_dialog_func) no se puede evaluar
-- desde Settings, donde no hay nada seleccionado. Cada vez que More se arma se anota cuáles
-- se mostraron de verdad, y esos quedan disponibles para "Add button" aunque en Settings no
-- se pueda saber si aplican.
M.SEEN_SETTING = "page_scrubber_sel_more_seen"

local function readSeen()
    local raw = G_reader_settings and G_reader_settings:readSetting(M.SEEN_SETTING)
    return type(raw) == "table" and raw or {}
end

-- `buttons` = { { id, reg_key, text }, ... } los que se mostraron en More esta vez
function M.rememberSeen(buttons)
    if not G_reader_settings or type(buttons) ~= "table" or #buttons == 0 then return end
    local seen = readSeen()
    local changed = false
    for _i, b in ipairs(buttons) do
        local id = tostring(b.id or "")
        if id ~= "" then
            local prev = seen[id]
            if not prev or prev.reg_key ~= tostring(b.reg_key) or prev.text ~= b.text then
                seen[id] = { reg_key = tostring(b.reg_key), text = tostring(b.text or id) }
                changed = true
            end
        end
    end
    if changed then
        G_reader_settings:saveSetting(M.SEEN_SETTING, seen)
        G_reader_settings:flush()
    end
end

function M.clearSeen()
    if G_reader_settings then G_reader_settings:delSetting(M.SEEN_SETTING) end
end

-- Los botones que otros plugins agregan al diálogo de resaltado y que todavía no se
-- agregaron a la barra: { { id, reg_key, text, plugin }, ... }
--
-- Solo entran los que de verdad aparecen en More y funcionan: los mismos filtros que usa
-- More (no son de KOReader, no los resuelve ya el plugin, enabled ~= false) y que además
-- se muestran ahora (show_in_highlight_dialog_func) o ya se mostraron alguna vez en More.
function M.available(ui)
    local hl = ui and ui.highlight
    local reg = hl and hl._highlight_buttons
    local out = {}
    if type(reg) ~= "table" then return out end
    local taken = {}
    for _i, e in ipairs(M.list()) do taken[e.id] = true end
    local seen_before = readSeen()
    local seen = {}
    for key, fn in iterator()(reg) do
        if type(fn) == "function" and not isCore(fn) then
            local ok, btn = pcall(fn, hl, nil)
            if ok and type(btn) == "table" and btn.enabled ~= false then
                local id = tostring(btn.id or key)
                if not isKnown(key, btn) and not taken[id] and not seen[id] then
                    local applies = M.isShown(btn) or seen_before[id] ~= nil
                    if applies then
                        seen[id] = true
                        out[#out + 1] = {
                            id = id, reg_key = tostring(key), text = buttonText(btn, hl),
                            plugin = pluginNameOf(fn),
                        }
                    end
                end
            end
        end
    end
    return out
end

-- ¿El botón se muestra ahora? (los plugins pueden ocultarse según la selección)
function M.isShown(btn)
    if type(btn) ~= "table" or btn.enabled == false then return false end
    if type(btn.show_in_highlight_dialog_func) == "function" then
        local ok, res = pcall(btn.show_in_highlight_dialog_func)
        return ok and res and true or false
    end
    return true
end

-- El botón vivo de otro plugin para un botón guardado: lo busca primero por la clave con
-- que se registró y, si no, entre todos por id. nil si el plugin ya no está.
function M.findButton(hl, entry, index)
    local reg = hl and hl._highlight_buttons
    if type(reg) ~= "table" or type(entry) ~= "table" then return nil end
    local function try(key, fn)
        if type(fn) ~= "function" then return nil end
        local ok, btn = pcall(fn, hl, index)
        if ok and type(btn) == "table" and tostring(btn.id or key) == entry.id then
            btn.id = btn.id or key
            return btn
        end
        return nil
    end
    if entry.reg_key then
        local fn = reg[entry.reg_key]
        if fn == nil then fn = reg[tonumber(entry.reg_key) or entry.reg_key] end
        local found = try(entry.reg_key, fn)
        if found then return found end
    end
    for key, fn in pairs(reg) do
        local found = try(key, fn)
        if found then return found end
    end
    return nil
end

return M

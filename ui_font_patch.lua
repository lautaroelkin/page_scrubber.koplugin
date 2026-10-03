-- Page Scrubber: fuente del sistema (aplicación temprana)
--
-- Page Scrubber copia este archivo solo a patches/2--page-scrubber-font.lua.
-- No lo edites ahí: se sobrescribe con la versión del plugin.
--
-- Tiene que correr antes que el resto de la interfaz de KOReader: los widgets
-- fijan su fuente cuando se cargan, y un plugin se carga demasiado tarde.
--
-- Basado en 2--ui-font.lua de sebdelsol / mysiak.
-- La fuente se puede elegir desde Page Scrubber > Configuration > Fuente del sistema
-- o desde los Ajustes de KOReader (entrada "UI font"), así que sigue siendo
-- administrable aunque se desinstale el plugin. Ambos usan los mismos ajustes
-- (ui_font_enabled / ui_font_name en G_reader_settings).

local Font = require("ui/font")
local FontList = require("fontlist")
local logger = require("logger")

local function norm(s)
    return (tostring(s):lower():gsub("[^%w]", ""))
end

-- ¿El plugin SimpleUI está instalado y habilitado?
-- Sus ajustes quedan en disco aunque se lo desactive o desinstale,
-- así que no alcanza con leer simpleui_ui_font_enabled.
local function simpleui_plugin_active()
    -- Ya cargado (solo posible con KOReader ya iniciado)
    if type(package.loaded["sui_store"]) == "table" then return true end

    -- Desactivado desde el administrador de plugins
    local disabled = G_reader_settings and G_reader_settings:readSetting("plugins_disabled")
    if type(disabled) == "table" then
        for name, off in pairs(disabled) do
            if off and norm(name):find("simpleui", 1, true) then return false end
        end
    end

    -- Instalado
    local ok, installed = pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        local DataStorage = require("datastorage")
        local dir = DataStorage:getDataDir() .. "/plugins"
        local seen, found = 0, false
        for entry in lfs.dir(dir) do
            if entry:match("%.koplugin$") then
                seen = seen + 1
                if norm(entry):find("simpleui", 1, true) then found = true end
            end
        end
        if seen == 0 then return true end -- no sabemos: asumimos que está instalado
        return found
    end)
    if not ok then return true end
    return installed
end

-- ¿SimpleUI está gestionando la fuente del sistema?
-- Lee simpleui_ui_font_enabled de settings/simpleui/sui_settings.lua
local function simpleui_font_enabled()
    local ok, res = pcall(function()
        if not simpleui_plugin_active() then return false end
        local store = package.loaded["sui_store"]
        if type(store) == "table" and store.isTrue then
            return store:isTrue("simpleui_ui_font_enabled")
        end
        local DataStorage = require("datastorage")
        local lfs = require("libs/libkoreader-lfs")
        local path = DataStorage:getSettingsDir() .. "/simpleui/sui_settings.lua"
        if lfs.attributes(path, "mode") ~= "file" then return false end
        local LuaSettings = require("luasettings")
        return LuaSettings:open(path):readSetting("simpleui_ui_font_enabled") == true
    end)
    return ok and res == true
end

-- Si el usuario eligió una fuente en SimpleUI, descartamos la nuestra
local function clear_own_font_choice()
    if not G_reader_settings then return end
    if G_reader_settings:readSetting("ui_font_name") == nil
       and G_reader_settings:readSetting("ui_font_enabled") == false then
        return
    end
    G_reader_settings:saveSetting("ui_font_enabled", false)
    G_reader_settings:delSetting("ui_font_name")
    G_reader_settings:flush()
end

local function get_bold_path(path_regular)
    -- "Font-Regular.ext" -> "Font-Bold.ext"
    local path_bold, n_repl = path_regular:gsub("%-Regular%.", "-Bold.", 1)
    if n_repl > 0 then return path_bold end
    -- "Font.ext" -> "Font-Bold.ext"
    path_bold, n_repl = path_regular:gsub("(%.)([^.]+)$", "-Bold.%2", 1)
    return n_repl > 0 and path_bold
end

-- ¿El archivo de la familia ya es bold? ("Font-Bold.ttf", "Font-Bold-Italic.ttf", "Font-SemiBold.ttf")
-- Se miran las palabras del nombre después de la primera (la familia), así una
-- fuente llamada "Boldonse-Regular" no se confunde, y si dice "regular" no es bold.
local function name_is_bold_only(base)
    local stem = base:gsub("%.[^.]+$", "")
    local is_first, found_bold, found_regular = true, false, false
    for token in stem:gmatch("[^-_ ]+") do
        if is_first then
            is_first = false
        elseif token:find("regular", 1, true) then
            found_regular = true
        elseif token:find("bold", 1, true) then
            found_bold = true
        end
    end
    return found_bold and not found_regular
end

-- Fuentes disponibles (se calcula una sola vez, y solo si hace falta).
-- Las que no tienen bold se incluyen igual, usando el regular para el bold
-- (como hace SimpleUI), y se marcan para avisarlo en el menú.
local font_cache
local function get_fonts()
    if font_cache then return font_cache end
    local cre = require("document/credocument"):engineInit()

    local path_exists = {}
    for _i, font in ipairs(FontList.fontlist) do path_exists[font] = true end

    local list, data = {}, {}
    for _i, name in ipairs(cre.getFontFaces()) do
        local path_regular = cre.getFontFaceFilenameAndFaceIndex(name)
        if path_regular then
            if path_exists[path_regular] then
                local path_bold = get_bold_path(path_regular)
                local has_bold = path_bold and path_exists[path_bold] or false
                local base = (path_regular:match("([^/\\]+)$") or path_regular):lower()
                -- si el único archivo de la familia ya es bold, no es "sin bold"
                local bold_only = name_is_bold_only(base)
                table.insert(list, name)
                data[name] = {
                    regular = path_regular,
                    bold = has_bold and path_bold or path_regular,
                    no_bold = not has_bold and not bold_only,
                    bold_only = bold_only,
                    italic_only = base:find("italic", 1, true) ~= nil or base:find("oblique", 1, true) ~= nil,
                }
            end
        end
    end
    font_cache = { list = list, data = data }
    return font_cache
end

local function apply()
    if not G_reader_settings then return end
    local is_enabled = G_reader_settings:readSetting("ui_font_enabled", true)
    local font_name = G_reader_settings:readSetting("ui_font_name")
    -- Sin fuente elegida no hay nada que aplicar ni que limpiar:
    -- así no leemos los ajustes de SimpleUI en cada arranque para nada
    if not is_enabled or not font_name then return end

    -- SimpleUI gestiona la fuente: no tocamos Font.fontmap y descartamos la nuestra
    if simpleui_font_enabled() then
        clear_own_font_choice()
        return
    end

    local fonts_data = get_fonts().data
    if not fonts_data[font_name] then return end

    local font_type = { regular = "NotoSans-Regular.ttf", bold = "NotoSans-Bold.ttf" }
    local type_font = {}
    for typ, font in pairs(font_type) do type_font[font] = typ end

    for name, font in pairs(Font.fontmap) do
        local typ = type_font[font]
        if typ then
            Font.fontmap[name] = fonts_data[font_name][typ]
        end
    end

    -- Page Scrubber lo usa para saber si en este arranque se aplicó nuestra fuente
    Font.__scrubber_font_applied = true
end

-- Un error acá nunca debe impedir que KOReader arranque
local ok, err = pcall(apply)
if not ok then
    logger.warn("page_scrubber font patch:", err)
end

-- ============================================================================
-- Menú en Ajustes de KOReader (explorador de archivos y lector)
-- ============================================================================

local ES = {
    ["UI font: %1"] = "Fuente del sistema: %1",
    ["UI font: [Select a font]"] = "Fuente del sistema: [Elegir una fuente]",
    ["UI font: [Disabled]"] = "Fuente del sistema: [Desactivada]",
    ["UI font: [Managed by SimpleUI]"] = "Fuente del sistema: [Gestionada por SimpleUI]",
    ["UI font: [Disabled by ZenOS]"] = "Fuente del sistema: [Desactivada por ZenOS]",
    ["no bold"] = "sin negrita",
    ["italic only"] = "solo cursiva",
    ["bold only"] = "solo negrita",
    ["bold italic only"] = "solo negrita cursiva",
    ["Disable font replacement"] = "Desactivar reemplazo de fuente",
    ["Enable font replacement"] = "Activar reemplazo de fuente",
    ["Restart to apply the change"] = "Es necesario reiniciar para aplicar el cambio",
    ["Restart to apply the UI font change"] = "Es necesario reiniciar para aplicar la fuente",
    ["The system font is managed by SimpleUI. Restart KOReader to apply it."] =
        "La fuente del sistema la gestiona SimpleUI. Es necesario reiniciar KOReader para aplicarla.",
    ["The system font is managed by SimpleUI. Change it from SimpleUI's settings."] =
        "La fuente del sistema la gestiona SimpleUI. Se cambia desde los ajustes de SimpleUI.",
}

local _dict_cache = nil

local function load_po_dict(lang)
    local dict = {}
    local DataStorage = require("datastorage")
    local po_path = DataStorage:getDataDir() .. "/plugins/page_scrubber.koplugin/locales/" .. lang .. ".po"
    
    local f = io.open(po_path, "r")
    if not f then return nil end
    
    local current_id
    for line in f:lines() do
        local id = line:match('^msgid%s+"(.*)"')
        if id then current_id = id:gsub('\\"', '"') end
        local str = line:match('^msgstr%s+"(.*)"')
        if str and current_id then
            dict[current_id] = str:gsub('\\"', '"')
            current_id = nil
        end
    end
    f:close()
    return dict
end

local function tr(text)
    local lang_setting = G_reader_settings and G_reader_settings:readSetting("language") or ""
    local lang_code = type(lang_setting) == "string" and lang_setting:sub(1, 2) or "en"
    
    if lang_code == "en" then return text end

    if _dict_cache == nil then
        _dict_cache = load_po_dict(lang_code) or {}
    end

    if _dict_cache[text] then
        return _dict_cache[text]
    end

    if lang_code == "es" and ES[text] then
        return ES[text]
    end
    
    return require("gettext")(text)
end

local function zenos_active()
    local ok, TouchMenu = pcall(require, "ui/widget/touchmenu")
    return ok and type(TouchMenu) == "table" and TouchMenu.__zen_patched == true
end

local function build_menu_entry()
    local UIManager = require("ui/uimanager")
    local T = require("ffi/util").template

    local function is_enabled() return G_reader_settings:readSetting("ui_font_enabled", true) end
    local function current_name() return G_reader_settings:readSetting("ui_font_name") end
    local function save(enabled, name)
        G_reader_settings:saveSetting("ui_font_enabled", enabled)
        if name then G_reader_settings:saveSetting("ui_font_name", name) end
        G_reader_settings:flush()
    end

    return {
        text_func = function()
            if zenos_active() then return tr("UI font: [Disabled by ZenOS]") end
            if simpleui_font_enabled() then return tr("UI font: [Managed by SimpleUI]") end
            if not is_enabled() then return tr("UI font: [Disabled]") end
            local name = current_name()
            if name then return T(tr("UI font: %1"), name) end
            return tr("UI font: [Select a font]")
        end,
        enabled_func = function() return not zenos_active() end,
        sub_item_table_func = function()
            -- SimpleUI gestiona la fuente: descartamos la nuestra y solo avisamos
            if simpleui_font_enabled() then
                clear_own_font_choice()
                if Font.__scrubber_font_applied then
                    local msg = tr("The system font is managed by SimpleUI. Restart KOReader to apply it.")
                    return {{ text = msg, callback = function() UIManager:askForRestart(msg) end }}
                end
                return {{
                    text = tr("The system font is managed by SimpleUI. Change it from SimpleUI's settings."),
                    enabled_func = function() return false end,
                }}
            end

            local items = {
                {
                    text = is_enabled() and tr("Disable font replacement") or tr("Enable font replacement"),
                    callback = function()
                        save(not is_enabled())
                        UIManager:askForRestart(tr("Restart to apply the change"))
                    end,
                    separator = true,
                },
            }

            local fonts = get_fonts()
            for _i, name in ipairs(fonts.list) do
                local info = fonts.data[name]
                local notes = {}
                if info.bold_only and info.italic_only then
                    table.insert(notes, tr("bold italic only"))
                elseif info.bold_only then
                    table.insert(notes, tr("bold only"))
                else
                    if info.italic_only then table.insert(notes, tr("italic only")) end
                    if info.no_bold then table.insert(notes, tr("no bold")) end
                end
                local label = name
                if #notes > 0 then label = label .. "  (" .. table.concat(notes, ", ") .. ")" end
                table.insert(items, {
                    text = label,
                    enabled_func = function() return name ~= current_name() or not is_enabled() end,
                    font_func = function(size) return Font:getFace(fonts.data[name].regular, size) end,
                    callback = function()
                        save(true, name)
                        UIManager:askForRestart(tr("Restart to apply the UI font change"))
                    end,
                })
            end
            return items
        end,
    }
end

local function hook_menus()
    local FileManagerMenu = require("apps/filemanager/filemanagermenu")
    local ReaderMenu = require("apps/reader/modules/readermenu")
    local KEY = "page_scrubber_ui_font"

    local function contains(t, value)
        for _i, v in ipairs(t) do
            if v == value then return true end
        end
        return false
    end

    local function patch(menu, order)
        if not contains(order.setting, KEY) then
            table.insert(order.setting, KEY)
        end
        menu.menu_items[KEY] = build_menu_entry()
    end

    local orig_FileManagerMenu_setUpdateItemTable = FileManagerMenu.setUpdateItemTable
    function FileManagerMenu:setUpdateItemTable()
        patch(self, require("ui/elements/filemanager_menu_order"))
        orig_FileManagerMenu_setUpdateItemTable(self)
    end

    local orig_ReaderMenu_setUpdateItemTable = ReaderMenu.setUpdateItemTable
    function ReaderMenu:setUpdateItemTable()
        patch(self, require("ui/elements/reader_menu_order"))
        orig_ReaderMenu_setUpdateItemTable(self)
    end
end

-- Un error acá nunca debe impedir que KOReader arranque
local ok_menu, err_menu = pcall(hook_menus)
if not ok_menu then
    logger.warn("page_scrubber font patch (menu):", err_menu)
end

--[[
    page_scrubber.koplugin/scrubber_settings.lua
    Menú de configuración drill-down modular y minimalista estilo Glimpse
]]--

local Device          = require("device")
local Blitbuffer      = require("ffi/blitbuffer")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local SpinWidget      = require("ui/widget/spinwidget")
local InputDialog     = require("ui/widget/inputdialog")
local InfoMessage     = require("ui/widget/infomessage")
local ConfirmBox      = require("ui/widget/confirmbox")
local FontList        = require("fontlist")
local cre             = require("document/credocument"):engineInit()

local Screen = Device.screen
local plugin_path = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"

-- Lógica interna para manejar el cambio de fuente del sistema (UI Font patch)
local function get_bold_path(path_regular)
    local path_bold, n_repl = path_regular:gsub("%-Regular%.", "-Bold.", 1)
    if n_repl > 0 then return path_bold end
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

-- Qué le falta a una fuente: ¿no tiene bold? ¿es solo cursiva? ¿es solo bold?
local function font_flags(path_regular, path_exists)
    local path_bold = get_bold_path(path_regular)
    local has_bold = path_bold and path_exists[path_bold] or false
    local base = (path_regular:match("([^/\\]+)$") or path_regular):lower()
    -- si el único archivo de la familia ya es bold, no es "sin bold"
    local bold_only = name_is_bold_only(base)
    local italic_only = base:find("italic", 1, true) ~= nil or base:find("oblique", 1, true) ~= nil
    return not has_bold and not bold_only, italic_only, bold_only
end

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

local _dict = {}
local _lang = "en"
if G_reader_settings then
    local l = G_reader_settings:readSetting("language")
    if type(l) == "string" then _lang = l:sub(1, 2) end
end

if _lang ~= "en" then
    local po_path = plugin_path .. "locales/" .. _lang .. ".po"
    local f = io.open(po_path, "r")
    if f then
        local current_id
        for line in f:lines() do
            local id = line:match('^msgid%s+"(.*)"')
            if id then current_id = id:gsub('\\"', '"') end
            local str = line:match('^msgstr%s+"(.*)"')
            if str and current_id then
                _dict[current_id] = str:gsub('\\"', '"')
                current_id = nil
            end
        end
        f:close()
    end
end

local function _(text)
    return _dict[text] or text
end

local function getTextOffset()
    if not G_reader_settings then return 0 end
    local size = G_reader_settings:readSetting("page_scrubber_text_size")
    if size == "small" then return -2
    elseif size == "large" then
        local is_eink = (Device.isKindle and Device:isKindle()) or (Device.isKobo and Device:isKobo()) or (Device.isEink and Device:isEink())
        return is_eink and 4 or 2
    end
    return 0
end

local function scale(px)
    local scale_factor = (G_reader_settings and G_reader_settings:readSetting("page_scrubber_ui_scale")) or 1.0
    return math.floor(Screen:scaleBySize(px) * scale_factor + 0.5)
end

local function scaleText(px)
    return scale(px + getTextOffset())
end

local function getTouchPoint(...)
    for i = 1, select("#", ...) do
        local a = select(i, ...)
        if type(a) == "table" then
            if a.pos and a.pos.x and a.pos.y then
                return a.pos
            elseif a.x and a.y then
                return a
            end
        end
    end
    return nil
end

local function pointInRect(p, r)
    if not p or not r then return false end
    return p.x >= r.x and p.x <= (r.x + r.w) and p.y >= r.y and p.y <= (r.y + r.h)
end

local function paintCornerRect(bb, x, y, w, h, r, color, round_tl, round_tr, round_bl, round_br)
    if w <= 0 or h <= 0 then return end
    r = math.min(r, math.floor(w / 2), math.floor(h / 2))
    if r <= 0 then bb:paintRect(x, y, w, h, color); return end
    bb:paintRect(x + r, y, w - 2*r, h, color)
    bb:paintRect(x, y + r, r, math.max(1, h - 2*r), color)
    bb:paintRect(x + w - r, y + r, r, math.max(1, h - 2*r), color)
    if not round_tl then bb:paintRect(x, y, r, r, color) end
    if not round_tr then bb:paintRect(x + w - r, y, r, r, color) end
    if not round_bl then bb:paintRect(x, y + h - r, r, r, color) end
    if not round_br then bb:paintRect(x + w - r, y + h - r, r, r, color) end
    for j = 0, r - 1 do
        local arc = math.ceil(math.sqrt(r*r - (r-j-0.5)*(r-j-0.5)))
        if arc > 0 then
            if round_tl then bb:paintRect(x + r - arc, y + j, arc, 1, color) end
            if round_tr then bb:paintRect(x + w - r,   y + j, arc, 1, color) end
            if round_bl then bb:paintRect(x + r - arc, y + h - 1 - j, arc, 1, color) end
            if round_br then bb:paintRect(x + w - r,   y + h - 1 - j, arc, 1, color) end
        end
    end
end

local function paintRoundRect(bb, x, y, w, h, r, color)
    paintCornerRect(bb, x, y, w, h, r, color, true, true, true, true)
end

-- Triángulo macizo (flechas del paginador; mismo dibujo que el panel de detalle del split)
local function paintTriangle(bb, x, y, w, h, pointing_left, color)
    for c = 0, w - 1 do
        local frac = pointing_left and ((c + 1) / w) or ((w - c) / w)
        local hc = math.max(1, math.floor(h * frac + 0.5))
        bb:paintRect(x + c, y + math.floor((h - hc) / 2), 1, hc, color)
    end
end

local _icon_cache = {}

-- Vacía la caché de íconos (sin free(): puede haber widgets en pantalla que todavía los usan)
local function clear_icon_cache()
    for k in pairs(_icon_cache) do
        _icon_cache[k] = nil
    end
end

-- Reemplazos del usuario en settings/page_scrubber/icons/ (tienen prioridad sobre los del plugin)
local ok_icon_mgr, IconManager = pcall(require, "icon_manager")
if not ok_icon_mgr then IconManager = nil end

local function getSvgPath(filename)
    if not filename or filename == "" then return nil end
    if IconManager then
        local resolved = IconManager.resolvePath(filename)
        if resolved then return resolved end
    end
    local paths = {
        plugin_path .. "icons/" .. filename,
        plugin_path .. filename
    }
    for _i, p in ipairs(paths) do
        local f = io.open(p, "r")
        if f then f:close(); return p end
    end
    return nil
end

local function loadSvg(filename, sz, fgcolor)
    if not filename or filename == "" then return nil end
    fgcolor = fgcolor or Blitbuffer.COLOR_BLACK
    local key = tostring(filename) .. "_" .. tostring(sz) .. "_" .. tostring(fgcolor)
    if _icon_cache[key] ~= nil then return _icon_cache[key] or nil end

    local path = getSvgPath(filename)
    if not path then
        _icon_cache[key] = false
        return nil
    end

    local ImageWidget = require("ui/widget/imagewidget")
    local ok, widget = pcall(function()
        return ImageWidget:new{
            file = path,
            width = sz,
            height = sz,
            alpha = true,
            fgcolor = fgcolor,
            original_in_nightmode = false,
            file_do_cache = false,   -- así un reemplazo con el mismo nombre no muestra el ícono viejo
        }
    end)

    if ok and widget then
        _icon_cache[key] = widget
        return widget
    end
    _icon_cache[key] = false
    return nil
end

-- Medidas del rediseño de la ventana de ajustes
local function frameBorder() return math.max(1, scale(1)) end
local function rowPad() return scale(14) end
local PRESSED_ROW_BG = Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_GRAY_D or Blitbuffer.COLOR_LIGHT_GRAY

-- ==========================================
-- PAGINADOR COMPARTIDO (Custom icons, Add Scrubber Action)
-- Puntitos si entran (los mismos del panel de detalle del split); si no, |< < 1/23 > >|
-- ==========================================
local function computePagerGeo(pager, nav)
    local n, idx = pager.n, pager.idx
    local text_w = nav.w - rowPad() * 2
    local dot_r = math.max(2, math.floor(scale(2.5)))
    local dot_rmax = math.floor(dot_r * 1.5)
    local dot_min_pitch = 2 * dot_r + scale(3)
    local dot_pitch = scale(11)
    if n > 1 then
        dot_pitch = math.floor(math.min(dot_pitch, (text_w - 2 * dot_rmax) / (n - 1)))
    end
    local geo = { dimen = nav, n = n, idx = idx, dot_r = dot_r, dot_rmax = dot_rmax }
    if n > 1 and dot_pitch >= dot_min_pitch then
        local dots_w = (n - 1) * dot_pitch + 2 * dot_rmax
        geo.use_dots = true
        geo.pitch = dot_pitch
        geo.x0 = nav.x + math.floor((nav.w - dots_w) / 2) + dot_rmax
        geo.cy = nav.y + math.floor(nav.h / 2)
    else
        local defs = { { key = "first", wt = 1 }, { key = "prev", wt = 1 }, { key = "counter", wt = 1.5 },
                       { key = "next", wt = 1 }, { key = "last", wt = 1 } }
        local total_wt = 0
        for _i, c in ipairs(defs) do total_wt = total_wt + c.wt end
        geo.cells = {}
        local cx = nav.x
        for i, c in ipairs(defs) do
            local cw = (i == #defs) and (nav.x + nav.w - cx) or math.floor(nav.w * c.wt / total_wt)
            geo.cells[#geo.cells + 1] = { key = c.key, dimen = Geom:new{ x = cx, y = nav.y, w = cw, h = nav.h } }
            cx = cx + cw
        end
    end
    return geo
end

local function paintPager(bb, geo, pressed_key)
    if not geo then return end
    local BLACK, GRAY = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_GRAY
    local idx, n = geo.idx, geo.n
    if geo.use_dots then
        for i = 1, n do
            local is_cur = (i == idx)
            local rr = is_cur and geo.dot_rmax or geo.dot_r
            paintRoundRect(bb, geo.x0 + (i - 1) * geo.pitch - rr, geo.cy - rr, rr * 2, rr * 2, rr,
                is_cur and BLACK or Blitbuffer.COLOR_DARK_GRAY)
        end
        return
    end
    local gh, gw, barw, gap = scale(16), scale(11), scale(3), scale(3)
    for _i, c in ipairs(geo.cells) do
        local cd = c.dimen
        local k = c.key
        if k == "counter" then
            local ctw = TextWidget:new{
                text = string.format("%d/%d", idx, n),
                face = Font:getFace("cfont", scaleText(11)),
                fgcolor = BLACK,
            }
            local csz = ctw:getSize()
            ctw:paintTo(bb, cd.x + math.floor((cd.w - csz.w) / 2), cd.y + math.floor((cd.h - csz.h) / 2))
            ctw:free()
        else
            local en
            if k == "first" or k == "prev" then en = idx > 1 else en = idx < n end
            local col = en and BLACK or GRAY
            if pressed_key == k then
                paintRoundRect(bb, cd.x + scale(4), cd.y + scale(3), cd.w - scale(8), cd.h - scale(6), scale(10), PRESSED_ROW_BG)
            end
            local with_bar = (k == "first" or k == "last")
            local total_w = with_bar and (gw + gap + barw) or gw
            local gx = cd.x + math.floor((cd.w - total_w) / 2)
            local gy = cd.y + math.floor((cd.h - gh) / 2)
            if k == "first" then
                bb:paintRect(gx, gy, barw, gh, col)
                paintTriangle(bb, gx + barw + gap, gy, gw, gh, true, col)
            elseif k == "prev" then
                paintTriangle(bb, gx, gy, gw, gh, true, col)
            elseif k == "next" then
                paintTriangle(bb, gx, gy, gw, gh, false, col)
            else
                paintTriangle(bb, gx, gy, gw, gh, false, col)
                bb:paintRect(gx + gw + gap, gy, barw, gh, col)
            end
        end
    end
end

-- Qué hizo el toque sobre el paginador: nil (fuera), "goto", n (puntito) | "step", key (flecha activa) | "none"
local function pagerTapAction(geo, pos)
    if not (geo and pos and pointInRect(pos, geo.dimen)) then return nil end
    if geo.use_dots then
        return "goto", math.floor((pos.x - geo.x0) / geo.pitch + 0.5) + 1
    end
    for _i, c in ipairs(geo.cells or {}) do
        if c.key ~= "counter" and pointInRect(pos, c.dimen) then
            local en
            if c.key == "first" or c.key == "prev" then en = geo.idx > 1 else en = geo.idx < geo.n end
            if en then return "step", c.key end
            return "none"
        end
    end
    return "none"
end

-- Caché del escaneo de imágenes (pestaña Images): vive en settings/page_scrubber_images.lua.
-- Los favoritos están en otro archivo (page_scrubber_images_fav.lua) y NO se tocan.
local function imageCachePath()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/page_scrubber_images.lua"
end

local function imageCacheSizeLabel()
    local label = "0 KB"
    pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        local size = lfs.attributes(imageCachePath(), "size") or 0
        if size >= 1024 * 1024 then
            label = string.format("%.1f MB", size / (1024 * 1024))
        else
            label = string.format("%d KB", math.ceil(size / 1024))
        end
    end)
    return label
end

local ScrubberSettings = InputContainer:extend({
    ui = nil,
    scrubber_ui = nil,
    current_view = "main",
    history = nil,
    row_dimens = nil,
    btn_back_dimen = nil,
    btn_close_dimen = nil,
    card_w = nil,
})

function ScrubberSettings:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()

    -- MODAL ESTRICTO: Bloquea el 100% de los toques para que NO pasen a PageScrubber
    self.is_modal = true
    self.history = {}
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    self:calculateGlobalCardWidth()
    self:updateLayout()

    if Device:isTouchDevice() then
        self.ges_events = {
            Tap   = { GestureRange:new{ ges = "tap",   range = self.dimen } },
            Hold  = { GestureRange:new{ ges = "hold",  range = self.dimen } },
            Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
    end
end

-- Absorbe cualquier gesto residual para que no despierte acciones en el scrubber de fondo
function ScrubberSettings:onHold() return true end
function ScrubberSettings:onSwipe(arg1, arg2)
    if self._flash_busy then return true end
    local ges = arg2 or arg1
    -- Con paginador (ej. Custom icons): swipe izquierda = página siguiente, derecha = anterior
    if self._pager and ges and ges.pos and self.popup_rect and ges.pos:intersectWith(self.popup_rect) then
        if ges.direction == "west" then
            self:pagerStep("next")
        elseif ges.direction == "east" then
            self:pagerStep("prev")
        end
    end
    return true
end

function ScrubberSettings:readSetting(key, default_val)
    if key == "page_scrubber_rtl" and self.ui and self.ui.doc_settings then
        local doc_val = self.ui.doc_settings:readSetting("page_scrubber_rtl")
        if doc_val ~= nil then return doc_val end
    end
    if not G_reader_settings then return default_val end
    local val = G_reader_settings:readSetting(key)
    if val == nil then return default_val end
    return val
end

function ScrubberSettings:saveSetting(key, val)
    if key == "page_scrubber_rtl" and self.ui and self.ui.doc_settings then
        self.ui.doc_settings:saveSetting("page_scrubber_rtl", val)
        if self.ui.doc_settings.flush then
            pcall(function() self.ui.doc_settings:flush() end)
        end
        return
    end
    if G_reader_settings then
        G_reader_settings:saveSetting(key, val)
        G_reader_settings:flush()
    end
end

-- =========================================================================
-- MOTOR MODULAR PARA LISTAS REORDENABLES CON TOGGLE (FÁCILMENTE REPLICABLE)
-- =========================================================================
function ScrubberSettings:getOrder(order_setting, default_order)
    local saved = self:readSetting(order_setting, nil)
    if type(saved) ~= "table" then
        if order_setting == "page_scrubber_sel_btn_order" and G_reader_settings and (G_reader_settings:isTrue("page_scrubber_sel_reverse_order") or G_reader_settings:isTrue("page_scrubber_sel_more_first")) then
            saved = { "more", "highlight", "invert", "underline", "strikethrough", "note", "ai", "xray" }
        else
            saved = {}
        end
    end
    local seen = {}
    local order = {}
    for _i, k in ipairs(saved) do
        if not seen[k] then
            for _i, def_k in ipairs(default_order) do
                if def_k == k then
                    seen[k] = true
                    table.insert(order, k)
                    break
                end
            end
        end
    end
    for _i, def_k in ipairs(default_order) do
        if not seen[def_k] then
            seen[def_k] = true
            table.insert(order, def_k)
        end
    end

    -- Si "more" quedó en el medio por alguna configuración antigua, lo envía al final
    for i, k in ipairs(order) do
        if k == "more" and i > 1 and i < #order then
            table.remove(order, i)
            table.insert(order, "more")
            break
        end
    end

    return order
end

function ScrubberSettings:moveOrderableItem(order_setting, default_order, item_key, direction)
    local order = self:getOrder(order_setting, default_order)
    local idx = nil
    for i, k in ipairs(order) do
        if k == item_key then idx = i; break end
    end
    if not idx then return end

    -- REGLA ESTRICTA PARA 'MORE': solo salta entre primero (1) y último (#order)
    if item_key == "more" then
        if direction == 1 and idx == 1 then
            table.remove(order, 1)
            table.insert(order, "more")
            self:saveSetting(order_setting, order)
        elseif direction == -1 and idx == #order then
            table.remove(order, #order)
            table.insert(order, 1, "more")
            self:saveSetting(order_setting, order)
        end
        return
    end

    -- Elementos normales: no pueden saltar por encima de 'more' para no dejarlo en el medio
    local target = idx + direction
    if target >= 1 and target <= #order then
        if order[target] == "more" then
            return
        end
        order[idx], order[target] = order[target], order[idx]
        self:saveSetting(order_setting, order)
    end
end

function ScrubberSettings:getOrderableTogglePage(cfg)
    local order = self:getOrder(cfg.order_setting, cfg.default_order)
    local items = {}
    local total_items = #order

    -- Detectar si 'more' está en la lista y en qué extremo se ubica
    local more_idx = nil
    for i, key in ipairs(order) do
        if key == "more" then more_idx = i; break end
    end

    for i, key in ipairs(order) do
        local def = cfg.items_def[key]
        if def then
            local can_up = false
            local can_down = false

            if key == "more" then
                if i == 1 then
                    can_down = (total_items > 1)
                    can_up = false
                elseif i == total_items then
                    can_up = (total_items > 1)
                    can_down = false
                end
            else
                if more_idx == 1 then
                    can_up = (i > 2)
                    can_down = (i < total_items)
                elseif more_idx == total_items then
                    can_up = (i > 1)
                    can_down = (i < total_items - 1)
                else
                    can_up = (i > 1)
                    can_down = (i < total_items)
                end
            end

            table.insert(items, {
                kind = "orderable_toggle",
                text = def.text,
                icon = def.icon,
                setting = def.setting,
                default = (def.default == nil) and true or def.default,
                order_setting = cfg.order_setting,
                default_order = cfg.default_order,
                item_key = key,
                order_idx = i,
                total_items = total_items,
                can_up = can_up,
                can_down = can_down,
            })
        end
    end

    table.insert(items, {
        text = _("Restore default order"),
        icon = "arrow-down-wide-narrow.svg",
        kind = "action",
        action = function()
            self:saveSetting(cfg.order_setting, cfg.default_order)
            self:refreshView()
        end
    })

    return {
        title = cfg.title,
        items = items,
    }
end

-- Texto del valor actual (Small / Medium / Large) de una opción, para mostrarlo a la derecha de la fila
function ScrubberSettings:sizeLabel(key, default)
    local map = { small = _("Small"), medium = _("Medium"), large = _("Large") }
    return map[self:readSetting(key, default)] or ""
end

-- Estilo actual del título del libro (mismos alias que normaliza la página "title_bg")
function ScrubberSettings:titleStyleLabel()
    local raw = self:readSetting("page_scrubber_title_bg", "none")
    if raw == "border" or raw == true or raw == "true" or raw == 1 then return _("With border") end
    if raw == "no_border" or raw == "borderless" then return _("No border") end
    if raw == "translucent" or raw == "opacity" or raw == "semi_transparent" then return _("Translucent") end
    if raw == "aura" or raw == "off" then return _("Aura") end
    if raw == "bar" or raw == "kindle_bar" then return _("Bar") end
    return _("None")
end

-- Nombre del wallpaper elegido ("None" si no hay)
function ScrubberSettings:wallpaperLabel()
    local cur = self:readSetting("page_scrubber_wallpaper", "none")
    if cur == nil or cur == "" or cur == "none" then return _("None") end
    local label
    pcall(function()
        local ScrubberWallpaper = require("scrubber_wallpaper")
        for _i, wp in ipairs(ScrubberWallpaper.list()) do
            if wp.id == cur then label = wp.label; break end
        end
    end)
    return label or _("None")
end

-- Versión instalada del plugin (campo `version` de _meta.lua) para mostrarla en la fila de actualizaciones
function ScrubberSettings:updaterVersionLabel()
    local label = ""
    pcall(function()
        local Updater = require("scrubber_updater")
        local v = Updater.installedVersion()
        if v then label = "v" .. v end
    end)
    return label
end

function ScrubberSettings:checkForUpdates()
    local ok, Updater = pcall(require, "scrubber_updater")
    if not ok then
        UIManager:show(InfoMessage:new{ text = _("The updater is not available.") })
        return
    end
    Updater.check()
end

-- Fuente del sistema elegida (para mostrarla a la derecha de la fila); "Disabled" si no hay ninguna activa
function ScrubberSettings:systemFontLabel()
    if not G_reader_settings then return "" end
    local enabled = G_reader_settings:readSetting("ui_font_enabled", true) == true
    local name = G_reader_settings:readSetting("ui_font_name")
    if enabled and type(name) == "string" and name ~= "" then
        return name
    end
    return _("None")
end

function ScrubberSettings:getPageTitle(data)
    if data and data.title and data.title ~= "" then return data.title end
    return _("Settings")
end

function ScrubberSettings:getPageDefinition(page_id)
    if page_id == "main" then
        return {
            title = "",
            items = {
                { section = _("Interface"), text = _("Layout"), icon = "square-arrow-right-enter.svg", kind = "submenu", target = "layout" },
                { text = _("Appearance"), icon = "sparkles.svg", kind = "submenu", target = "appearance" },
                { text = _("Reading Pop-Ups"), icon = "notepad-text.svg", kind = "submenu", target = "popups" },
                { text = _("Quick Menu"), icon = "sun.svg", kind = "submenu", target = "quick_menu" },
                { section = _("Document"), text = _("Export notes of this document"), icon = "book-marked.svg", kind = "action", action = function() self:exportNotes() end },
                { text = _("Study mode"), icon = "book-open-text.svg", kind = "submenu", target = "review" },
                { section = _("Other"), text = _("Advanced"), icon = "settings-2.svg", kind = "submenu", target = "advanced" },
            }
        }

    elseif page_id == "quick_menu" then
        local qm_enabled = self:readSetting("page_scrubber_quick_menu", true)
        return {
            title = _("Quick Menu"),
            items = {
                {
                    text = _("Enable Quick Menu"),
                    icon = "settings-2.svg",
                    kind = "toggle",
                    setting = "page_scrubber_quick_menu",
                    default = true,
                    bold = true,
                },
                {
                    text = _("Start quick menu with..."),
                    value = ({ quick = _("Quick actions"), typo = _("Typography (Aa)") })[self:readSetting("page_scrubber_quick_menu_start_tab", "quick")] or "",
                    icon = "square-arrow-right-enter.svg",
                    kind = "submenu",
                    target = "quick_menu_start_tab",
                    disabled = not qm_enabled,
                },
                {
                    text = _("Status row"),
                    icon = "zap.svg",
                    kind = "toggle",
                    setting = "page_scrubber_quick_menu_status_row",
                    default = false,
                    disabled = not qm_enabled,
                },
                {
                    text = _("Favorite Fonts"),
                    icon = "droplet.svg",
                    kind = "submenu",
                    target = "favorite_fonts",
                    disabled = not qm_enabled,
                },
                {
                    text = _("Quick Actions"),
                    icon = "warehouse.svg",
                    kind = "submenu",
                    target = "scrubber_actions",
                    disabled = not qm_enabled,
                },
            }
        }

    elseif page_id == "quick_menu_start_tab" then
        local cur = self:readSetting("page_scrubber_quick_menu_start_tab", "quick")
        return {
            title = _("Start quick menu with..."),
            items = {
                {
                    text = _("Quick actions"),
                    icon = "sun.svg",
                    kind = "radio",
                    setting = "page_scrubber_quick_menu_start_tab",
                    val = "quick",
                    checked = (cur == "quick"),
                },
                {
                    text = _("Typography (Aa)"),
                    icon = "droplet.svg",
                    kind = "radio",
                    setting = "page_scrubber_quick_menu_start_tab",
                    val = "typo",
                    checked = (cur == "typo"),
                },
            }
        }

    elseif page_id == "favorite_fonts" then
        local fonts = self:readSetting("page_scrubber_favorite_fonts", {})
        local items = {
            {
                text = _("+ Add fonts"),
                icon = nil,
                kind = "action",
                action = function() self:openAddFontDialog() end,
            },
        }
        local total_fonts = #fonts
        for idx, fname in ipairs(fonts) do
            local curr_idx = idx
            local curr_fname = fname
            table.insert(items, {
                text = curr_fname,
                font_name = curr_fname,
                icon = "Aa",
                kind = "orderable_action",
                right_icon = "trash-2.svg",
                action_idx = curr_idx,
                total_actions = total_fonts,
                can_up = (curr_idx > 1),
                can_down = (curr_idx < total_fonts),
                action = function()
                    self:confirmDeleteFont(curr_idx, curr_fname)
                end,
            })
        end
        return {
            title = _("Favorite Fonts"),
            items = items,
        }

    elseif page_id == "layout" then
        local is_rtl_active = function()
            local doc_val = self.ui and self.ui.doc_settings and self.ui.doc_settings:readSetting("page_scrubber_rtl")
            if doc_val ~= nil then
                return doc_val == true
            end
            if self.scrubber_ui and self.scrubber_ui.is_rtl ~= nil then
                return self.scrubber_ui.is_rtl
            end
            return false
        end

        return {
            title = _("Layout"),
            items = {
                {
                    text = _("3-Page Grid: Show full pages"),
                    icon = "gallery-horizontal.svg",
                    kind = "toggle",
                    setting = "page_scrubber_full_page_grid",
                    default = false,
                },
                {
                    text = _("Multi Grid: Show 9 pages"),
                    icon = "layout-grid.svg",
                    kind = "toggle",
                    setting = "page_scrubber_multigrid_nine",
                    default = false,
                    on_change = function()
                        local sc = self.scrubber_ui
                        if sc and sc._view_mode == "grid_six" then
                            if sc._clearGridTiles then sc:_clearGridTiles(true) end
                            sc._is_busy = false
                            sc._tasks_in_flight = 0
                            if sc._updateTexts then sc:_updateTexts() end
                            if sc._updateGridPages then sc:_updateGridPages() end
                            UIManager:setDirty(sc, "ui")
                        end
                    end,
                },
                {
                    text = _("Show chapter marks in slider"),
                    icon = "step-forward.svg",
                    kind = "toggle",
                    setting = "page_scrubber_show_chapter_marks",
                    default = true,
                    on_change = function()
                        if self.scrubber_ui and self.scrubber_ui._updateChapterMarks then
                            self.scrubber_ui:_updateChapterMarks()
                        end
                    end,
                },
                {
                    text = _("Disable Images tab"),
                    icon = "image-minus.svg",
                    kind = "toggle",
                    setting = "page_scrubber_hide_images_tab",
                    default = false,
                },
                {
                    text = "RTL",
                    icon = "arrow-left.svg",
                    kind = "toggle",
                    setting = "page_scrubber_rtl",
                    read_func = is_rtl_active,
                    on_change = function(new_val)
                        if self.ui and self.ui.doc_settings then
                            self.ui.doc_settings:saveSetting("page_scrubber_rtl", new_val)
                            if self.ui.doc_settings.flush then
                                pcall(function() self.ui.doc_settings:flush() end)
                            end
                        end
                        if self.scrubber_ui then
                            self.scrubber_ui.is_rtl = new_val
                            if self.scrubber_ui._slider then
                                self.scrubber_ui._slider.is_rtl = new_val
                            end
                            if self.scrubber_ui._clearGridTiles then
                                self.scrubber_ui:_clearGridTiles(true)
                            end
                            if self.scrubber_ui._updateGridPages then
                                self.scrubber_ui:_updateGridPages()
                            end
                            if self.scrubber_ui._updateTexts then
                                self.scrubber_ui:_updateTexts()
                            end
                            UIManager:setDirty(self.scrubber_ui, "ui")
                        end
                    end,
                },
            }
        }

    elseif page_id == "appearance" then
        -- Detectar si ZenOS está activo buscando su huella dactilar (__zen_patched)
        local has_zenos = false
        pcall(function()
            local TouchMenu = require("ui/widget/touchmenu")
            if TouchMenu and TouchMenu.__zen_patched then
                has_zenos = true
            end
        end)

        local has_simpleui = (not has_zenos) and simpleui_font_enabled()

        return {
            title = _("Appearance"),
            items = {
                { 
                    text = has_zenos and _("System Font (Disabled by ZenOS)") or (has_simpleui and _("System Font (Managed by SimpleUI)") or _("System Font")), 
                    icon = "droplet.svg", 
                    kind = "action",
                    value = (not has_zenos and not has_simpleui) and self:systemFontLabel() or nil,
                    disabled = has_zenos,
                    action = function()
                        if has_simpleui then self:showSimpleUIManagedNotice() else self:openSystemFontDialog() end
                    end 
                },
                { text = _("UI Scale (%)"), icon = "search.svg", kind = "action", value = tostring(math.floor(self:readSetting("page_scrubber_ui_scale", 1.0) * 100 + 0.5)) .. "%", action = function() self:openScaleDialog() end },
                { text = _("Text size"), icon = "pencil-ruler.svg", kind = "submenu", target = "text_size", value = self:sizeLabel("page_scrubber_text_size", "medium") },
                { text = _("Choose wallpaper"), icon = "image-plus.svg", kind = "submenu", target = "choose_wallpaper", value = self:wallpaperLabel() },
                { text = _("Custom icons"), icon = "droplet2.svg", kind = "submenu", target = "custom_icons" },
                { section = _("Top bar"), text = _("Book title style"), icon = "contrast.svg", kind = "submenu", target = "title_bg", value = self:titleStyleLabel() },
                {
                    text = _("Top bar separator line"),
                    icon = "underline.svg",
                    kind = "toggle",
                    setting = "page_scrubber_top_line",
                    default = false,
                    on_change = function()
                        if self.scrubber_ui then
                            UIManager:setDirty(self.scrubber_ui, "ui")
                        end
                    end,
                },
            }
        }

    elseif page_id == "scrubber_actions" then
        local actions = self:readSetting("page_scrubber_quick_actions", {})
        local items = {
            {
                text = _("+ Add action"),
                icon = nil,
                kind = "action",
                action = function() self:openAddActionDialog() end,
            },
        }
        local total_acts = #actions
        for idx, act in ipairs(actions) do
            local curr_idx = idx
            local curr_act = act
            local act_title = (type(curr_act) == "table" and (curr_act.title or curr_act.id)) or tostring(curr_act)
            table.insert(items, {
                text = act_title,
                icon = self:getActionIcon(curr_act),
                kind = "orderable_action",
                right_icon = "trash-2.svg",
                action_idx = curr_idx,
                total_actions = total_acts,
                can_up = (curr_idx > 1),
                can_down = (curr_idx < total_acts),
                action = function()
                    self:confirmDeleteAction(curr_idx, curr_act)
                end,
            })
        end
        return {
            title = _("Scrubber Actions"),
            items = items,
        }

    elseif page_id == "actions_launcher" then
        local actions = self:readSetting("page_scrubber_quick_actions", {})
        local items = {}
        if #actions == 0 then
            table.insert(items, {
                text = _("+ Add action"),
                icon = "package.svg",
                kind = "action",
                action = function()
                    self:pushView("scrubber_actions")
                end,
            })
        else
            for _i, act in ipairs(actions) do
                local action_def = act
                local act_id = (type(action_def) == "table" and action_def.id) or tostring(action_def)
                local act_title = (type(action_def) == "table" and (action_def.title or action_def.id)) or act_id
                table.insert(items, {
                    text = act_title,
                    icon = self:getActionIcon(action_def),
                    kind = "action",
                    action = function()
                        self:executeAction(act_id)
                    end,
                })
            end
        end
        return {
            title = "",
            items = items,
        }

    elseif page_id == "popups" then
        local dict_enabled = self:readSetting("page_scrubber_floating_dict_enabled", false)
        local sel_enabled = self:readSetting("page_scrubber_selection_menu_enabled", false)

        return {
            title = _("Reading Pop-Ups"),
            items = {
                {
                    section = _("Dictionary"),
                    text = _("Scrubber Dictionary"),
                    icon = "globe.svg",
                    kind = "toggle",
                    setting = "page_scrubber_floating_dict_enabled",
                    default = false,
                    bold = true,
                },
                {
                    text = _("Buttons in dictionary"),
                    icon = "pencil-sparkles.svg",
                    kind = "submenu",
                    target = "dict_buttons",
                    disabled = not dict_enabled,
                },
                {
                    text = _("Plugin buttons in dictionary"),
                    icon = "package.svg",
                    kind = "toggle",
                    setting = "page_scrubber_fdict_show_plugins",
                    default = true,
                    disabled = not dict_enabled,
                },
                {
                    text = _("Dictionary text size"),
                    value = ({ very_small = _("Very small"), small = _("Small"), normal = _("Normal"), large = _("Large"), very_large = _("Very large") })[self:readSetting("page_scrubber_dict_font_size", "normal")] or "",
                    icon = "pencil-ruler.svg",
                    kind = "submenu",
                    target = "dict_text_size",
                    disabled = not dict_enabled,
                },
                {
                    section = _("Selection menu"),
                    text = _("Scrubber Selection Menu"),
                    icon = "crop.svg",
                    kind = "toggle",
                    setting = "page_scrubber_selection_menu_enabled",
                    default = false,
                    bold = true,
                },
                {
                    text = _("Position of selection menu"),
                    value = ({ right_v = _("Right (Vertical)"), left_v = _("Left (Vertical)"), bottom_h = _("Bottom (Horizontal)"), center_h = _("Center (Horizontal)") })[self:readSetting("page_scrubber_sel_menu_position", "right_v")] or "",
                    icon = "square-arrow-right-enter.svg",
                    kind = "submenu",
                    target = "sel_pos",
                    disabled = not sel_enabled,
                },
                {
                    text = _("Size of selection menu"),
                    value = self:sizeLabel("page_scrubber_sel_menu_size", "medium"),
                    icon = "search.svg",
                    kind = "submenu",
                    target = "sel_size",
                    disabled = not sel_enabled,
                },
                {
                    text = _("Buttons in selection menu"),
                    icon = "highlighter.svg",
                    kind = "submenu",
                    target = "sel_buttons",
                    disabled = not sel_enabled,
                },
            }
        }

    elseif page_id == "dict_buttons" then
        local has_xray = false
        pcall(function()
            local lfs = require("libs/libkoreader-lfs")
            has_xray = (lfs.attributes("plugins/xray.koplugin", "mode") == "directory")
        end)
        local has_ai = false
        pcall(function()
            local lfs = require("libs/libkoreader-lfs")
            has_ai = (lfs.attributes("plugins/assistant.koplugin", "mode") == "directory")
                  or (self.ui and self.ui.assistant ~= nil)
                  or (package.loaded["apps/reader/modules/readerassistant"] ~= nil)
        end)

        return self:getOrderableTogglePage({
            title = _("Buttons in dictionary"),
            order_setting = "page_scrubber_fdict_btn_order",
            default_order = { "wiki", "translate", "ai", "highlight", "search", "xray" },
            items_def = {
                wiki      = { text = _("Wikipedia"), icon = "globe.svg", setting = "page_scrubber_fdict_show_wiki", default = true },
                translate = { text = _("Translate"), icon = "languages.svg", setting = "page_scrubber_fdict_show_translate", default = true },
                ai        = { text = _("AI Assistant"), icon = "sparkles.svg", setting = "page_scrubber_fdict_show_ai", default = has_ai },
                highlight = { text = _("Highlight"), icon = "highlighter.svg", setting = "page_scrubber_fdict_show_highlight", default = true },
                search    = { text = _("Search"), icon = "search.svg", setting = "page_scrubber_fdict_show_search", default = true },
                xray      = { text = "X-Ray", icon = "xray.svg", setting = "page_scrubber_fdict_show_xray", default = has_xray },
            }
        })

    elseif page_id == "dict_text_size" then
        local cur = self:readSetting("page_scrubber_dict_font_size", "normal")
        return {
            title = _("Dictionary text size"),
            items = {
                { text = _("Very small"), icon = nil, kind = "radio", setting = "page_scrubber_dict_font_size", val = "very_small", checked = (cur == "very_small") },
                { text = _("Small"), icon = nil, kind = "radio", setting = "page_scrubber_dict_font_size", val = "small", checked = (cur == "small") },
                { text = _("Normal"), icon = nil, kind = "radio", setting = "page_scrubber_dict_font_size", val = "normal", checked = (cur == "normal") },
                { text = _("Large"), icon = nil, kind = "radio", setting = "page_scrubber_dict_font_size", val = "large", checked = (cur == "large") },
                { text = _("Very large"), icon = nil, kind = "radio", setting = "page_scrubber_dict_font_size", val = "very_large", checked = (cur == "very_large") },
            }
        }

    elseif page_id == "sel_buttons" then
        local has_xray = false
        pcall(function()
            local lfs = require("libs/libkoreader-lfs")
            has_xray = (lfs.attributes("plugins/xray.koplugin", "mode") == "directory")
        end)
        local has_ai = false
        pcall(function()
            local lfs = require("libs/libkoreader-lfs")
            has_ai = (lfs.attributes("plugins/assistant.koplugin", "mode") == "directory")
                  or (self.ui and self.ui.assistant ~= nil)
                  or (package.loaded["apps/reader/modules/readerassistant"] ~= nil)
        end)

        return self:getOrderableTogglePage({
            title = _("Buttons in selection menu"),
            order_setting = "page_scrubber_sel_btn_order",
            default_order = { "xray", "ai", "note", "strikethrough", "underline", "invert", "highlight", "select", "dict", "wiki", "translate", "more" },
            items_def = {
                xray          = { text = "X-Ray", icon = "xray.svg", setting = "page_scrubber_sel_show_xray", default = has_xray },
                ai            = { text = _("AI Assistant"), icon = "sparkles.svg", setting = "page_scrubber_sel_show_ai", default = has_ai },
                note          = { text = _("Note"), icon = "notepad-text.svg", setting = "page_scrubber_sel_show_note", default = true },
                strikethrough = { text = _("Strikethrough"), icon = "strikethrough.svg", setting = "page_scrubber_sel_show_strikethrough", default = true },
                underline     = { text = _("Underline"), icon = "underline.svg", setting = "page_scrubber_sel_show_underline", default = true },
                invert        = { text = _("Invert"), icon = "contrast.svg", setting = "page_scrubber_sel_show_invert", default = true },
                highlight     = { text = _("Highlight"), icon = "highlighter.svg", setting = "page_scrubber_sel_show_highlight", default = true },
                select        = { text = _("Text selection"), icon = "crop.svg", setting = "page_scrubber_sel_show_select", default = false },
                dict          = { text = _("Dictionary"), icon = "book-marked.svg", setting = "page_scrubber_sel_show_dict", default = false },
                wiki          = { text = _("Wikipedia"), icon = "globe.svg", setting = "page_scrubber_sel_show_wiki", default = false },
                translate     = { text = _("Translate"), icon = "languages.svg", setting = "page_scrubber_sel_show_translate", default = false },
                more          = { text = _("More"), icon = "more.svg", setting = "page_scrubber_sel_show_more", default = true },
            }
        })

    elseif page_id == "sel_pos" then
        local cur = self:readSetting("page_scrubber_sel_menu_position", "right_v")
        return {
            title = _("Position of selection menu"),
            items = {
                { text = _("Right (Vertical)"), icon = nil, kind = "radio", setting = "page_scrubber_sel_menu_position", val = "right_v", checked = (cur == "right_v") },
                { text = _("Left (Vertical)"), icon = nil, kind = "radio", setting = "page_scrubber_sel_menu_position", val = "left_v", checked = (cur == "left_v") },
                { text = _("Bottom (Horizontal)"), icon = nil, kind = "radio", setting = "page_scrubber_sel_menu_position", val = "bottom_h", checked = (cur == "bottom_h") },
                { text = _("Center (Horizontal)"), icon = nil, kind = "radio", setting = "page_scrubber_sel_menu_position", val = "center_h", checked = (cur == "center_h") },
            }
        }

    elseif page_id == "sel_size" then
        local cur = self:readSetting("page_scrubber_sel_menu_size", "medium")
        return {
            title = _("Size of selection menu"),
            items = {
                { text = _("Small"), icon = nil, kind = "radio", setting = "page_scrubber_sel_menu_size", val = "small", checked = (cur == "small") },
                { text = _("Medium"), icon = nil, kind = "radio", setting = "page_scrubber_sel_menu_size", val = "medium", checked = (cur == "medium") },
                { text = _("Large"), icon = nil, kind = "radio", setting = "page_scrubber_sel_menu_size", val = "large", checked = (cur == "large") },
            }
        }

    elseif page_id == "review" then
        local SRS = require("srs")
        local mode = SRS.getStudyMode()
        local folder = self:readSetting("page_scrubber_review_folder", nil)
        local study_items = {
            { text = _("Off"), icon = nil, kind = "radio", setting = "page_scrubber_review_mode", val = "off", checked = (mode == "off") },
            { text = _("Everywhere"), icon = nil, kind = "radio", setting = "page_scrubber_review_mode", val = "all", checked = (mode == "all") },
            {
                text = _("Only in a folder"), icon = nil, kind = "radio",
                setting = "page_scrubber_review_mode", val = "folder", checked = (mode == "folder"),
                on_select = function() self:chooseReviewFolder() end,   -- abre el selector; el modo se guarda al confirmar
            },
        }
        -- Con una carpeta elegida: una fila con su nombre para cambiarla
        if mode == "folder" and type(folder) == "string" and folder ~= "" then
            table.insert(study_items, {
                text = folder:match("([^/]+)/*$") or folder,
                icon = "folder.svg",
                kind = "action",
                value = _("Change"),
                action = function() self:chooseReviewFolder() end,
            })
        end
        table.insert(study_items, {
            section = _("This book"),
            text = _("Reset study progress"),
            icon = "undo.svg",
            kind = "action",
            action = function() self:confirmResetReview() end,
        })
        return {
            title = _("Study mode"),
            items = study_items,
        }

    elseif page_id == "advanced" then
        return {
            title = _("Advanced"),
            items = {
                { section = _("Settings"), text = _("Back up settings"), icon = "folder.svg", kind = "action", action = function() self:backupSettings() end },
                { text = _("Restore settings from backup"), icon = "undo.svg", kind = "action", action = function() self:confirmRestoreSettings() end },
                { text = _("Reset all settings"), icon = "trash-2.svg", kind = "action", action = function() self:confirmResetSettings() end },
                { section = _("Cache"), text = _("Clear image cache"), icon = "image.svg", kind = "action", value = imageCacheSizeLabel(), action = function() self:confirmClearImageCache() end },
                { section = _("Updates"), text = _("Check for updates"), icon = "zap.svg", kind = "action", value = self:updaterVersionLabel(), action = function() self:checkForUpdates() end },
            }
        }

    elseif page_id == "text_size" then
        local cur = self:readSetting("page_scrubber_text_size", "medium")
        return {
            title = _("Text size"),
            items = {
                { text = _("Small"), icon = nil, kind = "radio", setting = "page_scrubber_text_size", val = "small", checked = (cur == "small") },
                { text = _("Medium"), icon = nil, kind = "radio", setting = "page_scrubber_text_size", val = "medium", checked = (cur == "medium") },
                { text = _("Large"), icon = nil, kind = "radio", setting = "page_scrubber_text_size", val = "large", checked = (cur == "large") },
            }
        }

    elseif page_id == "choose_wallpaper" then
        local ScrubberWallpaper = require("scrubber_wallpaper")
        local cur = self:readSetting("page_scrubber_wallpaper", "none")
        local is_none = (cur == "none" or cur == nil or cur == "")

        local items = {
            {
                text = _("None"),
                icon = nil,
                kind = "radio",
                setting = "page_scrubber_wallpaper",
                val = "none",
                checked = is_none,
            },
        }

        local list = ScrubberWallpaper.list()
        for _i, wp in ipairs(list) do
            table.insert(items, {
                text = wp.label,
                icon = nil,
                kind = "radio",
                setting = "page_scrubber_wallpaper",
                val = wp.id,
                checked = (cur == wp.id),
            })
        end

        table.insert(items, {
            text = _("Add wallpaper"),
            icon = "folder.svg",
            kind = "action",
            action = function() self:showWallpaperFolderInfo() end,
        })

        return {
            title = _("Choose wallpaper"),
            items = items,
        }

    elseif page_id == "custom_icons" then
        local all_icons = IconManager and IconManager.listPluginIcons() or {}
        local PER_PAGE = 12
        local total_pages = math.max(1, math.ceil(#all_icons / PER_PAGE))
        local page = math.max(1, math.min(self._icons_page or 1, total_pages))
        self._icons_page = page

        local items = {
            { section = _("Overview"), text = _("Reset all to default"),
              icon = "undo.svg", kind = "action",
              action = function() self:confirmResetAllIcons() end },
        }

        local start_i = (page - 1) * PER_PAGE + 1
        local end_i   = math.min(start_i + PER_PAGE - 1, #all_icons)
        for i = start_i, end_i do
            local filename = all_icons[i]
            table.insert(items, {
                section = (i == start_i) and _("Icons") or nil,
                text  = filename,
                icon  = filename,
                value = IconManager.hasCustom(filename) and _("Custom") or _("Default"),
                kind  = "submenu",
                target = "icon_edit:" .. filename,
            })
        end
        -- Paginador (puntitos / |< < 1/23 > >|) en vez de filas Prev/Next. min_rows mantiene
        -- la altura fija para que la barra no se mueva de lugar entre páginas.
        local pager = nil
        if total_pages > 1 then
            pager = { key = "_icons_page", idx = page, n = total_pages, min_rows = 1 + PER_PAGE }
        end
        return { title = _("Custom icons"), items = items, pager = pager }

    elseif page_id and page_id:match("^icon_edit:") then
        local filename = page_id:sub(#"icon_edit:" + 1)
        local items = {
            { text = _("Pick a custom SVG..."), icon = "folder.svg", kind = "action",
              action = function() self:pickCustomIcon(filename) end },
        }
        if IconManager and IconManager.hasCustom(filename) then
            table.insert(items, {
                text = _("Reset to default icon"), icon = "undo.svg", kind = "action",
                action = function() self:confirmResetIcon(filename) end,
            })
        end
        return { title = filename, items = items }

    elseif page_id == "title_bg" then
        local raw = self:readSetting("page_scrubber_title_bg", "none")
        local cur = "none"
        if raw == "border" or raw == true or raw == "true" or raw == 1 then
            cur = "border"
        elseif raw == "no_border" or raw == "borderless" then
            cur = "no_border"
        elseif raw == "translucent" or raw == "opacity" or raw == "semi_transparent" then
            cur = "translucent"
        elseif raw == "aura" or raw == "off" then
            cur = "aura"
        elseif raw == "bar" or raw == "kindle_bar" then
            cur = "bar"   -- "kindle_bar" era el nombre anterior de este estilo
        elseif raw == "none" or raw == false or raw == "false" or raw == 0 then
            cur = "none"
        end

        return {
            title = _("Book title style"),
            items = {
                {
                    text = _("None"),
                    icon = nil,
                    kind = "radio",
                    setting = "page_scrubber_title_bg",
                    val = "none",
                    checked = (cur == "none"),
                },
                {
                    text = _("With border"),
                    icon = nil,
                    kind = "radio",
                    setting = "page_scrubber_title_bg",
                    val = "border",
                    checked = (cur == "border"),
                },
                {
                    text = _("No border"),
                    icon = nil,
                    kind = "radio",
                    setting = "page_scrubber_title_bg",
                    val = "no_border",
                    checked = (cur == "no_border"),
                },
                {
                    text = _("Translucent"),
                    icon = nil,
                    kind = "radio",
                    setting = "page_scrubber_title_bg",
                    val = "translucent",
                    checked = (cur == "translucent"),
                },
                {
                    text = _("Aura"),
                    icon = nil,
                    kind = "radio",
                    setting = "page_scrubber_title_bg",
                    val = "aura",
                    checked = (cur == "aura"),
                },
                {
                    text = _("Bar"),
                    icon = nil,
                    kind = "radio",
                    setting = "page_scrubber_title_bg",
                    val = "bar",
                    checked = (cur == "bar"),
                },
            }
        }
    end

    return { title = "", items = {} }
end

function ScrubberSettings:calculateGlobalCardWidth()
    local sw = Screen:getWidth()
    local pages = { "main", "layout", "appearance", "quick_menu", "quick_menu_start_tab", "favorite_fonts", "choose_wallpaper", "title_bg", "popups", "dict_buttons", "dict_text_size", "sel_buttons", "sel_pos", "sel_size", "review", "advanced", "text_size", "scrubber_actions", "actions_launcher" }
    local max_item_w = 0

    for _i, pid in ipairs(pages) do
        -- Medimos solo los textos nativos de configuración para que NUNCA se corten,
        -- evitando que nombres externos (acciones del sistema, fuentes o archivos de imagen) estiren el menú.
        local is_dynamic_page = (pid == "scrubber_actions" or pid == "favorite_fonts" or pid == "actions_launcher" or pid == "choose_wallpaper")
        if not is_dynamic_page then
            local pdef = self:getPageDefinition(pid)
            if pdef.title and pdef.title ~= "" then
                local tw = TextWidget:new{
                    text = pdef.title,
                    face = Font:getFace("cfont", scaleText(12)),
                    bold = true,
                }
                local sz = tw:getSize()
                if sz.w > max_item_w then max_item_w = sz.w end
                tw:free()
            end
            for _i, item in ipairs(pdef.items or {}) do
                local tw = TextWidget:new{
                    text = item.text,
                    face = Font:getFace("cfont", scaleText(11)),
                }
                local sz = tw:getSize()
                local w_total = sz.w
                tw:free()
                -- Las filas con valor a la derecha necesitan lugar para el texto del valor
                if item.value and item.value ~= "" then
                    local tv = TextWidget:new{ text = tostring(item.value), face = Font:getFace("cfont", scaleText(10)) }
                    w_total = w_total + math.min(tv:getSize().w, scale(130)) + scale(10)
                    tv:free()
                end
                if w_total > max_item_w then max_item_w = w_total end
            end
        end
    end

    local needed_w = max_item_w + scale(105)
    local min_w = scale(280)
    local max_w = sw - scale(16)
    self.card_w = math.max(min_w, math.min(needed_w, max_w))
end

function ScrubberSettings:updateLayout()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local data = self:getPageDefinition(self.current_view)
    local items = data.items or {}
    local has_back = #self.history > 0
    local pager = data.pager
    self._pager = pager

    if not self.card_w then
        self:calculateGlobalCardWidth()
    end

    local border = frameBorder()
    local sect_h = scale(38)
    local pad_bottom = scale(8)
    self.header_h = scale(42)

    local top_bar = self.scrubber_ui and self.scrubber_ui._top_bar_dimen
    local top_bar_bottom = top_bar and (top_bar.y + top_bar.h) or scale(58)
    local target_y = top_bar_bottom + scale(6)

    local n_sections = 0
    for _i, item in ipairs(items) do
        if item.section then n_sections = n_sections + 1 end
    end

    -- Filas más altas y cómodas; si la página es muy larga se compactan para que entre en pantalla
    local nav_h = pager and scale(34) or 0
    local layout_rows = pager and math.max(#items, pager.min_rows or 0) or #items
    local fixed_h = (border * 2) + self.header_h + (n_sections * sect_h) + pad_bottom + nav_h
    local avail_h = sh - target_y - scale(12)
    local row_h = scale(38)
    if fixed_h + (layout_rows * row_h) > avail_h then
        row_h = math.max(scale(28), math.floor((avail_h - fixed_h) / math.max(1, layout_rows)))
    end
    self.row_h = row_h
    self.card_h = fixed_h + (layout_rows * row_h)

    local target_x = math.floor((sw * 0.75) - (self.card_w / 2))
    if target_x + self.card_w > sw - scale(8) then
        target_x = sw - self.card_w - scale(8)
    end
    if target_x < scale(8) then
        target_x = scale(8)
    end

    if target_y + self.card_h > sh - scale(10) then target_y = sh - self.card_h - scale(10) end

    self.popup_rect = Geom:new{ x = target_x, y = target_y, w = self.card_w, h = self.card_h }

    local r = self.popup_rect
    local btn_w = scale(56)

    -- Encabezado: botón volver (izquierda, solo en submenús) y botón cerrar (derecha, siempre)
    if has_back then
        self.btn_back_dimen = Geom:new{ x = r.x, y = r.y, w = r.w - btn_w, h = self.header_h + border }
    else
        self.btn_back_dimen = nil
    end
    self.btn_close_dimen = Geom:new{ x = r.x + r.w - btn_w, y = r.y, w = btn_w, h = self.header_h + border }

    self.row_dimens = {}
    local curr_y = r.y + border + self.header_h
    for _i, item in ipairs(items) do
        local section_y
        if item.section then
            section_y = curr_y
            curr_y = curr_y + sect_h
        end
        local row_rect = Geom:new{ x = r.x + border, y = curr_y, w = r.w - (border * 2), h = self.row_h }
        table.insert(self.row_dimens, { dimen = row_rect, item = item, section_y = section_y, section_h = sect_h })
        curr_y = curr_y + self.row_h
    end

    -- Fila del paginador: pegada abajo, justo antes del margen inferior
    self._pager_geo = nil
    if pager then
        local nav = Geom:new{ x = r.x + border, y = r.y + r.h - border - pad_bottom - nav_h, w = r.w - (border * 2), h = nav_h }
        self._pager_geo = computePagerGeo(pager, nav)
    end
end

-- Cambia de página del paginador activo (taps en puntitos / flechas y swipes)
function ScrubberSettings:pagerStep(key, goto_idx)
    local pg = self._pager
    if not pg then return false end
    local target = pg.idx
    if key == "goto" then target = tonumber(goto_idx) or pg.idx
    elseif key == "first" then target = 1
    elseif key == "prev" then target = pg.idx - 1
    elseif key == "next" then target = pg.idx + 1
    elseif key == "last" then target = pg.n end
    target = math.max(1, math.min(pg.n, target))
    if target ~= pg.idx then
        self[pg.key] = target
        self:refreshView()
    end
    return true
end

function ScrubberSettings:refreshView()
    local prev_rect = self.popup_rect
    self:updateLayout()

    local dirty_geom = self.popup_rect
    if prev_rect then
        local pad = scale(6)
        local min_x = math.min(prev_rect.x, self.popup_rect.x) - pad
        local min_y = math.min(prev_rect.y, self.popup_rect.y) - pad
        local max_x = math.max(prev_rect.x + prev_rect.w, self.popup_rect.x + self.popup_rect.w) + pad
        local max_y = math.max(prev_rect.y + prev_rect.h, self.popup_rect.y + self.popup_rect.h) + pad
        dirty_geom = Geom:new{ x = min_x, y = min_y, w = max_x - min_x, h = max_y - min_y }
    end

    local function getDirty()
        return "ui", dirty_geom
    end

    if self.scrubber_ui then
        UIManager:setDirty(self.scrubber_ui, getDirty)
    end
    if self.ui then
        UIManager:setDirty(self.ui, getDirty)
    else
        UIManager:setDirty(nil, getDirty)
    end
    UIManager:setDirty(self, "ui")
end

function ScrubberSettings:pushView(target)
    if target == "custom_icons" then self._icons_page = 1 end
    table.insert(self.history, self.current_view)
    self.current_view = target
    self:refreshView()
end

function ScrubberSettings:popView()
    if #self.history > 0 then
        self.current_view = table.remove(self.history)
        self:refreshView()
    else
        UIManager:close(self)
    end
end

function ScrubberSettings:reopenEntireScrubber()
    local ui = self.ui
    local scrubber = self.scrubber_ui

    UIManager:close(self)
    if not scrubber then return end

    local view_mode = scrubber.view_mode or scrubber.initial_view_mode or "grid"
    local tab = scrubber.current_tab or scrubber.initial_tab or "bookmarks"
    local page = scrubber.current_page or (ui and ui.view and ui.view.state and ui.view.state.page) or 1
    local doc = scrubber.document or (ui and ui.document)

    pcall(function()
        if scrubber.onClose then scrubber:onClose() end
    end)
    pcall(function()
        UIManager:close(scrubber)
    end)

    UIManager:nextTick(function()
        if ui and (doc or ui.document) then
            local ScrubberUI = require("scrubber_ui")
            local scale_val = 1.0
            if G_reader_settings then
                scale_val = G_reader_settings:readSetting("page_scrubber_ui_scale") or 1.0
            end
            UIManager:show(ScrubberUI:new{
                ui                = ui,
                document          = doc or ui.document,
                initial_view_mode = view_mode,
                initial_tab       = tab,
                initial_page      = page,
                transparent_bg    = (view_mode == "grid_simple"),
                ui_scale          = scale_val,
            })
            if Device:isKindle() then
                UIManager:setDirty(nil, "full")
            end
        end
    end)
end

function ScrubberSettings:getActionIcon(act)
    if not act then return "package.svg" end
    local id = (type(act) == "table" and tostring(act.id or "")) or tostring(act or "")
    local cat = (type(act) == "table" and tostring(act.category or "")) or ""
    local title = (type(act) == "table" and tostring(act.title or "")) or id
    id = id:lower()
    cat = cat:lower()
    title = title:lower()

    if id:find("rtl") or title:find("rtl") then
        return "arrow-left.svg"
    end

    if id:find("exit") or id:find("back") or id:find("prev_loc") or id:find("history_back")
            or title:find("exit") or title:find("salir") or title:find("volver")
            or title:find("ubicación anterior") then
        return "chevron-left.svg"
    end

    if id:find("pin") or id:find("goto") or id:find("go_to") or id:find("locat") or id:find("vocab")
            or title:find("pin") or title:find("go to") or title:find("ir a")
            or title:find("locat") or title:find("ubicaci") or title:find("vocab") then
        return "pin.svg"
    end

    if id:find("history") or id:find("hist") or id:find("lookup") or id:find("look")
            or id:find("search") or id:find("find")
            or title:find("history") or title:find("historial") or title:find("lookup")
            or title:find("look") or title:find("buscar") then
        return "search.svg"
    end

    if id:find("touch") or id:find("wifi") or id:find("server") or id:find("push")
            or id:find("pull") or id:find("sync") or id:find("network") or id:find("refresh")
            or title:find("touch") or title:find("táctil") or title:find("tactil")
            or title:find("wifi") or title:find("server") or title:find("servidor")
            or title:find("sync") or title:find("push") or title:find("pull")
            or title:find("refresh") or title:find("refrescar") or title:find("actualiz")
            or title:find("network") or title:find("red") or title:find("sinc") then
        return "zap.svg"
    end

    if id:find("receipt") or id:find("profile") or id:find("table") or id:find("menu") or id:find("book_map") or id:find("bookmap") or id:find("overview")
            or title:find("receipt") or title:find("recibo") or title:find("profile") or title:find("perfil")
            or title:find("table") or title:find("tabla") or title:find("menu") or title:find("menú")
            or title:find("book map") or title:find("mapa") then
        return "layout-grid.svg"
    end

    if id:find("style") or title:find("style") or title:find("estilo") then
        return "pencil-ruler.svg"
    end

    if id:find("orient") or id:find("stat")
            or title:find("orient") or title:find("estadístic") or title:find("reading stat") then
        return "gallery-horizontal.svg"
    end

    if id:find("file") or id:find("folder") or id:find("dir") or id:find("storage")
            or id:find("favorit") or id:find("collection")
            or title:find("file") or title:find("folder") or title:find("storage")
            or title:find("archivo") or title:find("carpeta") or title:find("almacenamiento")
            or title:find("directorio") or title:find("favorit") or title:find("collection") or title:find("colecci") then
        return "folder.svg"
    end

    if id:find("document") or id:find("doc") or id:find("note") or id:find("link") or id:find("attach")
            or title:find("document") or title:find("doc") or title:find("documento")
            or title:find("nota") or title:find("enlace") or title:find("vínculo") then
        return "paperclip.svg"
    end

    if id:find("book") or id:find("bookmark") or id:find("cover")
            or title:find("book") or title:find("libro") or title:find("marcador")
            or title:find("portada") then
        return "book-marked.svg"
    end

    if id:find("font") or title:find("fuente") or title:find("tipograf") or title:find("letra") or title:find("weight") or title:find("grosor") then
        return "droplet.svg"
    end

    if id:find("highlight") or title:find("resalt") or title:find("subray") then
        return "highlighter.svg"
    end

    if id:find("dict") or id:find("translat") or title:find("diccionario") or title:find("traduc") then
        return "languages.svg"
    end

    if id:find("frontlight") or id:find("light") or id:find("brightness") or title:find("luz") or title:find("brillo") then
        return "sun.svg"
    end

    if id:find("night") or id:find("invert") or id:find("dark") or title:find("noche") or title:find("oscuro") then
        return "contrast.svg"
    end

    if id:find("search") or id:find("find") or title:find("buscar") then
        return "search.svg"
    end

    if id:find("page") or id:find("chapter") or id:find("toc") or title:find("página") or title:find("capítulo") then
        return "step-forward.svg"
    end

    if cat == "navigation" or cat == "paging" then
        return "step-forward.svg"
    elseif cat == "bookmark" or cat == "bookmarks" then
        return "book-marked.svg"
    elseif cat == "search" or cat == "find" then
        return "search.svg"
    elseif cat == "highlight" or cat == "annotations" then
        return "highlighter.svg"
    elseif cat == "notes" then
        return "paperclip.svg"
    elseif cat == "text" or cat == "typography" then
        return "droplet.svg"
    elseif cat == "language" or cat == "translation" then
        return "languages.svg"
    elseif cat == "view" or cat == "display" then
        return "contrast.svg"
    elseif cat == "tools" then
        return "pencil-sparkles.svg"
    end

    return "package.svg"
end

function ScrubberSettings:getAvailableActions()
    local ok_d, Dispatcher = pcall(require, "dispatcher")
    if not ok_d or not Dispatcher then return {} end
    pcall(function() Dispatcher:init() end)

    local settings_list, dispatcher_menu_order
    local fn_idx = 1
    while true do
        local name, val = debug.getupvalue(Dispatcher.registerAction, fn_idx)
        if not name then break end
        if name == "settingsList" then settings_list = val end
        if name == "dispatcher_menu_order" then dispatcher_menu_order = val end
        fn_idx = fn_idx + 1
    end

    if type(settings_list) ~= "table" then return {} end

    local order = (type(dispatcher_menu_order) == "table" and dispatcher_menu_order)
        or (function()
            local t = {}
            for k in pairs(settings_list) do t[#t + 1] = k end
            table.sort(t)
            return t
        end)()

    local results = {}
    for _i, action_id in ipairs(order) do
        local def = settings_list[action_id]
        if type(def) == "table" and def.category == "none" then
            local cond_ok = true
            if def.condition ~= nil then
                if type(def.condition) == "function" then
                    local ok, cval = pcall(def.condition)
                    cond_ok = ok and (cval == true)
                elseif def.condition == false then
                    cond_ok = false
                end
            end

            if cond_ok then
                local raw_t = def.title
                if type(raw_t) == "function" then
                    local ok, tval = pcall(raw_t)
                    raw_t = (ok and tval) and tval or action_id
                end
                local aid = tostring(action_id or ""):lower()
                local atitle = tostring(raw_t or ""):lower()

                local is_wifi_on_off = (aid:find("wifi") or atitle:find("wifi"))
                    and (aid:find("off") or aid:find("on") or atitle:find("off") or atitle:find("on"))
                    and not (aid:find("toggle") or atitle:find("toggle"))

                local is_rotation_non_toggle = (aid:find("rotat") or atitle:find("rotat"))
                    and not (aid:find("toggle") or atitle:find("toggle"))

                local is_view_mode = aid:find("view_mode") or aid:find("viewmode") or atitle:find("view mode")
                local is_zoom = aid:find("zoom") or atitle:find("zoom")
                local is_metadata_archive = aid:find("metadata") or aid:find("archive") or atitle:find("metadata") or atitle:find("archive")
                local is_characters_corners = aid:find("character") or aid:find("corner") or atitle:find("character") or atitle:find("corner")
                local is_highlight_cycle = (aid:find("highlight") and (aid:find("action") or aid:find("style") or aid:find("cycle")))
                    or atitle:find("highlight action") or atitle:find("highlight style") or atitle:find("cycle highlight")

                local is_blacklisted = is_wifi_on_off
                    or is_rotation_non_toggle
                    or is_view_mode
                    or is_zoom
                    or is_metadata_archive
                    or is_characters_corners
                    or is_highlight_cycle
                    or (aid:find("page_scrubber") and not aid:find("simple_grid") and not aid:find("rtl"))
                    or aid:find("touch_input")
                    or aid:find("overlap")
                    or aid:find("next_chapter")
                    or aid:find("handmade")
                    or aid:find("style_tweak")
                    or aid:find("page_turn")
                    or aid:find("reading_order")
                    or aid:find("turn_direction")
                    or atitle:find("page turn")
                    or atitle:find("turn direction")
                    or atitle:find("reading order")
                    or aid:find("night_mode")
                    or aid:find("nightmode")
                    or aid:find("frontlight")
                    or aid:find("screenshot")
                    or aid:find("straighten")
                    or aid:find("sort")
                    or aid:find("language")
                    or aid:find("reflow")
                    or aid:find("refresh_content")
                    or aid:find("subfolder")
                    or aid:find("select_mode")
                    or aid:find("flipping")
                    or aid:find("quality")
                    or aid:find("render")
                    or aid:find("watermark")
                    or (aid:find("bookmark") and (aid:find("next") or aid:find("prev")))

                if not is_blacklisted and raw_t and tostring(raw_t) ~= "" then
                    table.insert(results, {
                        id = action_id,
                        title = tostring(raw_t),
                        category = "none",
                    })
                end
            end
        end
    end

    table.sort(results, function(a, b)
        return tostring(a.title):lower() < tostring(b.title):lower()
    end)
    return results
end

local ActionSelectDialog = InputContainer:extend{
    ui = nil,
    scrubber_ui = nil,
    actions = nil,
    page = 1,
    items_per_page = 14,
    card_rect = nil,
    row_dimens = nil,
    footer_rect = nil,
    btn_back_dimen = nil,
    btn_close_dimen = nil,
    popup_w = nil,   -- ancho de la ventana de ajustes, para que ambas se vean iguales
    on_close = nil,
}

function ActionSelectDialog:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    self.header_h = scale(42)   -- mismo alto de encabezado que ajustes
    self.row_h = scale(38)
    self.footer_h = scale(34)
    self.page = 1

    self:updateLayout()

    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
            Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
    end
end

function ActionSelectDialog:updateLayout()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()

    local top_bar = self.scrubber_ui and self.scrubber_ui._top_bar_dimen
    local top_bar_bottom = top_bar and (top_bar.y + top_bar.h) or scale(58)
    local start_y = top_bar_bottom + scale(6)

    local bottom_limit = (self.scrubber_ui and self.scrubber_ui._chapter_dimen and self.scrubber_ui._chapter_dimen.y) or (sh - scale(115))

    local border = frameBorder()
    local max_avail = bottom_limit - start_y
    local rows_avail = max_avail - self.header_h - self.footer_h - (border * 2)

    -- Filas del mismo alto que en ajustes; si no entran 10, se compactan
    self.row_h = scale(38)
    local ipp = math.floor(rows_avail / self.row_h)
    if ipp < 10 then
        self.row_h = math.max(scale(28), math.floor(rows_avail / 10))
        ipp = math.max(10, math.floor(rows_avail / self.row_h))
    end
    self.items_per_page = ipp

    local total_items = #(self.actions or {})
    self.total_pages = math.max(1, math.ceil(total_items / self.items_per_page))
    self.page = math.max(1, math.min(self.page, self.total_pages))

    local start_idx = (self.page - 1) * self.items_per_page + 1
    local end_idx = math.min(start_idx + self.items_per_page - 1, total_items)
    self.current_items = {}
    for i = start_idx, end_idx do
        table.insert(self.current_items, self.actions[i])
    end

    -- Mismo ancho y misma posición que la ventana de ajustes (a la derecha, pegada a la barra superior)
    self.card_w = self.popup_w or math.min(sw - scale(16), scale(640))
    self.card_h = self.header_h + (self.items_per_page * self.row_h) + self.footer_h + (border * 2)

    local card_x = math.floor((sw * 0.75) - (self.card_w / 2))
    if card_x + self.card_w > sw - scale(8) then
        card_x = sw - self.card_w - scale(8)
    end
    if card_x < scale(8) then
        card_x = scale(8)
    end
    local card_y = start_y
    self.card_rect = Geom:new{ x = card_x, y = card_y, w = self.card_w, h = self.card_h }

    -- Encabezado: volver (izquierda, ocupa casi todo) y cerrar (derecha), como en ajustes
    local btn_w = scale(56)
    self.btn_back_dimen = Geom:new{ x = card_x, y = card_y, w = self.card_w - btn_w, h = self.header_h + border }
    self.btn_close_dimen = Geom:new{ x = card_x + self.card_w - btn_w, y = card_y, w = btn_w, h = self.header_h + border }

    self.row_dimens = {}
    local curr_y = card_y + border + self.header_h
    for _i, item in ipairs(self.current_items) do
        local r_rect = Geom:new{ x = card_x + border, y = curr_y, w = self.card_w - (border * 2), h = self.row_h }
        table.insert(self.row_dimens, { dimen = r_rect, item = item })
        curr_y = curr_y + self.row_h
    end

    local fy = card_y + border + self.header_h + (self.items_per_page * self.row_h)
    local fw = self.card_w - (border * 2)
    self.footer_rect = Geom:new{ x = card_x + border, y = fy, w = fw, h = self.footer_h }

    -- Paginador del pie (mismo que Custom icons); con una sola página no se dibuja
    self._pager_geo = nil
    if self.total_pages > 1 then
        self._pager_geo = computePagerGeo({ n = self.total_pages, idx = self.page }, self.footer_rect)
    end
end

function ActionSelectDialog:goToPage(target)
    target = math.max(1, math.min(self.total_pages or 1, tonumber(target) or self.page))
    if target == self.page then return end
    self.page = target
    self:updateLayout()
    UIManager:setDirty(self, "ui")
end

function ActionSelectDialog:prevPage()
    if self.page > 1 then
        self.page = self.page - 1
        self:updateLayout()
        UIManager:setDirty(self, "ui")
    end
end

function ActionSelectDialog:nextPage()
    if self.page < self.total_pages then
        self.page = self.page + 1
        self:updateLayout()
        UIManager:setDirty(self, "ui")
    end
end

-- Color de las lineas divisorias entre filas (la linea debajo del titulo con la flecha "‹" sigue negra)
local ROW_DIVIDER_COLOR = Blitbuffer.COLOR_LIGHT_GRAY

function ActionSelectDialog:paintTo(bb, x, y)
    local r = self.card_rect
    if not r then return end
    local border = frameBorder()
    local radius = scale(18)
    local pad = rowPad()

    paintRoundRect(bb, r.x, r.y, r.w, r.h, radius, Blitbuffer.COLOR_BLACK)
    paintRoundRect(bb, r.x + border, r.y + border, r.w - (border * 2), r.h - (border * 2), math.max(1, radius - border), Blitbuffer.COLOR_WHITE)

    -- Encabezado: [undo]  Título  [X]  (igual que ajustes; gris clarito solo mientras se presiona "volver")
    do
        local hy = r.y + border
        local hh = self.header_h
        if self._pressed_header then
            paintCornerRect(bb, r.x + border, hy, r.w - (border * 2), hh, math.max(1, radius - border), PRESSED_ROW_BG, true, true, false, false)
        end
        local ico_sz = scale(18)
        local ico_y = hy + math.floor((hh - ico_sz) / 2)

        local back_icon = loadSvg("undo.svg", ico_sz, Blitbuffer.COLOR_BLACK)
        if back_icon then
            pcall(function() back_icon:paintTo(bb, r.x + pad, ico_y) end)
        else
            local tw_b = TextWidget:new{ text = "‹", face = Font:getFace("cfont", scaleText(15)), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
            local bsz = tw_b:getSize()
            tw_b:paintTo(bb, r.x + pad, hy + math.floor((hh - bsz.h) / 2))
            tw_b:free()
        end

        local close_icon = loadSvg("x.svg", ico_sz, Blitbuffer.COLOR_BLACK)
        if close_icon then
            pcall(function() close_icon:paintTo(bb, r.x + r.w - pad - ico_sz, ico_y) end)
        else
            local tw_x = TextWidget:new{ text = "✕", face = Font:getFace("cfont", scaleText(12)), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
            local xsz = tw_x:getSize()
            tw_x:paintTo(bb, r.x + r.w - pad - xsz.w, hy + math.floor((hh - xsz.h) / 2))
            tw_x:free()
        end

        local tw_title = TextWidget:new{
            text = _("Add Scrubber Action"),
            face = Font:getFace("cfont", scaleText(12)),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = r.w - (scale(56) * 2),
            truncate_with_ellipsis = true,
        }
        local tsz = tw_title:getSize()
        tw_title:paintTo(bb, r.x + pad + ico_sz + scale(12), hy + math.floor((hh - tsz.h) / 2))
        tw_title:free()

        bb:paintRect(r.x + border, hy + hh - 1, r.w - (border * 2), 1, Blitbuffer.COLOR_BLACK)
    end

    local saved_actions = (G_reader_settings and G_reader_settings:readSetting("page_scrubber_quick_actions")) or {}

    for idx, rdef in ipairs(self.row_dimens or {}) do
        local item = rdef.item
        local ry = rdef.dimen.y
        local rh = rdef.dimen.h

        -- Fila presionada: pastilla redondeada gris clarito (como en ajustes)
        if self._pressed_row == idx then
            local pin = scale(6)
            paintRoundRect(bb, r.x + border + pin, ry + scale(2), r.w - (border + pin) * 2, rh - scale(4), scale(10), PRESSED_ROW_BG)
        end

        -- Divisor gris con sangría (no se dibuja pegado a la pastilla)
        if idx > 1 and self._pressed_row ~= idx and self._pressed_row ~= (idx - 1) then
            bb:paintRect(r.x + pad, ry, r.w - pad * 2, 1, ROW_DIVIDER_COLOR)
        end

        local icon_name = ScrubberSettings.getActionIcon and ScrubberSettings:getActionIcon(item) or "package.svg"
        local icon_sz = scale(17)
        local text_x = r.x + pad + scale(4)

        local icon_w = loadSvg(icon_name, icon_sz, Blitbuffer.COLOR_BLACK)
        if icon_w then
            local iy = ry + math.floor((rh - icon_sz) / 2)
            pcall(function() icon_w:paintTo(bb, text_x, iy) end)
            text_x = text_x + icon_sz + scale(8)
        end

        local max_tw = math.max(scale(40), r.w - (text_x - r.x) - scale(28))
        local tw_item = TextWidget:new{
            text = tostring(item.title or item.id),
            face = Font:getFace("cfont", scaleText(11)),
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = max_tw,
            truncate_with_ellipsis = true,
        }
        local isz = tw_item:getSize()
        tw_item:paintTo(bb, text_x, ry + math.floor((rh - isz.h) / 2))
        tw_item:free()

        local is_already_added = false
        for _i, ex in ipairs(saved_actions) do
            local ex_id = (type(ex) == "table" and ex.id) or ex
            if ex_id == item.id then
                is_already_added = true
                break
            end
        end

        -- Ya agregada: tilde negro (como las opciones tildadas de ajustes); si no, "+" gris
        local tw_sym = TextWidget:new{
            text = is_already_added and "✓" or "+",
            face = Font:getFace("cfont", scaleText(is_already_added and 12 or 13)),
            bold = true,
            fgcolor = is_already_added and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        }
        local psz = tw_sym:getSize()
        tw_sym:paintTo(bb, r.x + r.w - pad - psz.w, ry + math.floor((rh - psz.h) / 2))
        tw_sym:free()
    end

    -- Paginador (puntitos o |< < 1/N > >|), sin línea encima, igual que Custom icons
    paintPager(bb, self._pager_geo, self._pressed_nav)
end

function ActionSelectDialog:closeDialog()
    -- Primero se muestra el menú anterior y recién después se cierra el diálogo: ambos cambios
    -- se dibujan en una sola actualización de pantalla (sin el "cierra y abre" visible)
    if self.on_close then
        self.on_close()
    end
    UIManager:close(self)
end

function ActionSelectDialog:onSwipe(arg1, arg2)
    local ges = arg2 or arg1
    if not ges then return false end

    local dir = ges.direction
    local dx = (ges.pos and ges.start_pos) and (ges.pos.x - ges.start_pos.x) or 0
    local dy = (ges.pos and ges.start_pos) and (ges.pos.y - ges.start_pos.y) or 0

    if dir == "left" or dir == "west" or dir == "up" or dir == "north" or dx < -30 or dy < -30 then
        self:nextPage()
        return true
    elseif dir == "right" or dir == "east" or dir == "down" or dir == "south" or dx > 30 or dy > 30 then
        self:prevPage()
        return true
    end
    return false
end

function ActionSelectDialog:onTap(arg1, arg2)
    if self._flash_busy then return true end
    local p = getTouchPoint(arg1, arg2)
    if not p then return false end

    -- Tocar fuera cierra, como en ajustes
    if not pointInRect(p, self.card_rect) then
        UIManager:close(self)
        return true
    end

    -- X (derecha): cierra todo
    if self.btn_close_dimen and pointInRect(p, self.btn_close_dimen) then
        UIManager:close(self)
        return true
    end

    -- Volver (izquierda): se pone gris un instante y vuelve a Scrubber Actions
    if self.btn_back_dimen and pointInRect(p, self.btn_back_dimen) then
        self._pressed_header = true
        self._flash_busy = true
        UIManager:setDirty(self, "ui", self.card_rect)
        UIManager:scheduleIn(0.1, function()
            self._flash_busy = false
            self._pressed_header = false
            if self._closed then return end
            self:closeDialog()
        end)
        return true
    end

    for idx, rdef in ipairs(self.row_dimens or {}) do
        if pointInRect(p, rdef.dimen) then
            local act = rdef.item
            local saved = (G_reader_settings and G_reader_settings:readSetting("page_scrubber_quick_actions")) or {}
            for _i, existing in ipairs(saved) do
                local existing_id = (type(existing) == "table" and existing.id) or existing
                if existing_id == act.id then
                    return true
                end
            end

            -- Pastilla gris un instante y recién ahí se agrega (mismo feedback que las filas de ajustes)
            self._pressed_row = idx
            self._flash_busy = true
            UIManager:setDirty(self, "ui", self.card_rect)
            UIManager:scheduleIn(0.1, function()
                self._flash_busy = false
                self._pressed_row = nil
                if self._closed then return end
                local saved_now = (G_reader_settings and G_reader_settings:readSetting("page_scrubber_quick_actions")) or {}
                table.insert(saved_now, {
                    id = act.id,
                    title = act.title,
                    category = act.category or "none",
                })
                if G_reader_settings then
                    G_reader_settings:saveSetting("page_scrubber_quick_actions", saved_now)
                    G_reader_settings:flush()
                end
                self:closeDialog()
            end)
            return true
        end
    end

    if self.footer_rect and pointInRect(p, self.footer_rect) then
        local pkind, pval = pagerTapAction(self._pager_geo, p)
        if pkind == "goto" then
            self:goToPage(pval)
        elseif pkind == "step" then
            self._pressed_nav = pval
            self._flash_busy = true
            UIManager:setDirty(self, "ui", self.footer_rect)
            UIManager:scheduleIn(0.1, function()
                self._flash_busy = false
                self._pressed_nav = nil
                if self._closed then return end
                local targets = { first = 1, prev = self.page - 1, next = self.page + 1, last = self.total_pages }
                self:goToPage(targets[pval])
            end)
        end
        return true
    end

    return true
end

function ActionSelectDialog:onShow()
    if self.ui then
        UIManager:setDirty(self.ui, "ui")
    end
    UIManager:setDirty(self, "ui")
end

function ActionSelectDialog:onCloseWidget()
    self._closed = true
    if self.scrubber_ui then
        UIManager:setDirty(self.scrubber_ui, "ui")
    end
    if self.ui then
        UIManager:setDirty(self.ui, "ui")
    else
        UIManager:setDirty(nil, "ui")
    end
end

-- =========================================================================
-- PIEZAS COMPARTIDAS DE LOS DIÁLOGOS DE FUENTES
-- Mismo estilo que el menú de ajustes y que Add Scrubber Action (encabezado con undo/X,
-- filas con divisor con sangría, pastilla al presionar y paginador de puntitos)
-- =========================================================================
local function fontDialogLayout(self, items)
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()

    local top_bar = self.scrubber_ui and self.scrubber_ui._top_bar_dimen
    local top_bar_bottom = top_bar and (top_bar.y + top_bar.h) or scale(58)
    local start_y = top_bar_bottom + scale(6)

    local bottom_limit = (self.scrubber_ui and self.scrubber_ui._chapter_dimen and self.scrubber_ui._chapter_dimen.y) or (sh - scale(115))

    local border = frameBorder()
    local max_avail = bottom_limit - start_y
    local rows_avail = max_avail - self.header_h - self.footer_h - (border * 2)

    -- Filas del mismo alto que en ajustes; si no entran 10, se compactan
    self.row_h = scale(38)
    local ipp = math.floor(rows_avail / self.row_h)
    if ipp < 10 then
        self.row_h = math.max(scale(28), math.floor(rows_avail / 10))
        ipp = math.max(10, math.floor(rows_avail / self.row_h))
    end
    self.items_per_page = ipp

    local total_items = #(items or {})
    self.total_pages = math.max(1, math.ceil(total_items / self.items_per_page))
    self.page = math.max(1, math.min(self.page, self.total_pages))

    local start_idx = (self.page - 1) * self.items_per_page + 1
    local end_idx = math.min(start_idx + self.items_per_page - 1, total_items)
    self.current_items = {}
    for i = start_idx, end_idx do
        table.insert(self.current_items, items[i])
    end

    -- Mismo ancho y misma posición que la ventana de ajustes
    self.card_w = self.popup_w or math.min(sw - scale(16), scale(640))
    self.card_h = self.header_h + (self.items_per_page * self.row_h) + self.footer_h + (border * 2)

    local card_x = math.floor((sw * 0.75) - (self.card_w / 2))
    if card_x + self.card_w > sw - scale(8) then
        card_x = sw - self.card_w - scale(8)
    end
    if card_x < scale(8) then
        card_x = scale(8)
    end
    local card_y = start_y
    self.card_rect = Geom:new{ x = card_x, y = card_y, w = self.card_w, h = self.card_h }

    local btn_w = scale(56)
    self.btn_back_dimen = Geom:new{ x = card_x, y = card_y, w = self.card_w - btn_w, h = self.header_h + border }
    self.btn_close_dimen = Geom:new{ x = card_x + self.card_w - btn_w, y = card_y, w = btn_w, h = self.header_h + border }

    self.row_dimens = {}
    local curr_y = card_y + border + self.header_h
    for _i, item in ipairs(self.current_items) do
        local r_rect = Geom:new{ x = card_x + border, y = curr_y, w = self.card_w - (border * 2), h = self.row_h }
        table.insert(self.row_dimens, { dimen = r_rect, item = item })
        curr_y = curr_y + self.row_h
    end

    local fy = card_y + border + self.header_h + (self.items_per_page * self.row_h)
    local fw = self.card_w - (border * 2)
    self.footer_rect = Geom:new{ x = card_x + border, y = fy, w = fw, h = self.footer_h }

    -- Paginador del pie (puntitos o |< < 1/N > >|); con una sola página no se dibuja
    self._pager_geo = nil
    if self.total_pages > 1 then
        self._pager_geo = computePagerGeo({ n = self.total_pages, idx = self.page }, self.footer_rect)
    end
end

local function fontDialogGoToPage(self, target)
    target = math.max(1, math.min(self.total_pages or 1, tonumber(target) or self.page))
    if target == self.page then return end
    self.page = target
    self:updateLayout()
    UIManager:setDirty(self, "ui")
end

-- Marco + encabezado [undo] Título [X]; devuelve r, border, pad
local function fontDialogPaintFrame(self, bb, title)
    local r = self.card_rect
    local border = frameBorder()
    local radius = scale(18)
    local pad = rowPad()

    paintRoundRect(bb, r.x, r.y, r.w, r.h, radius, Blitbuffer.COLOR_BLACK)
    paintRoundRect(bb, r.x + border, r.y + border, r.w - (border * 2), r.h - (border * 2), math.max(1, radius - border), Blitbuffer.COLOR_WHITE)

    local hy = r.y + border
    local hh = self.header_h
    if self._pressed_header then
        paintCornerRect(bb, r.x + border, hy, r.w - (border * 2), hh, math.max(1, radius - border), PRESSED_ROW_BG, true, true, false, false)
    end
    local ico_sz = scale(18)
    local ico_y = hy + math.floor((hh - ico_sz) / 2)

    local back_icon = loadSvg("undo.svg", ico_sz, Blitbuffer.COLOR_BLACK)
    if back_icon then
        pcall(function() back_icon:paintTo(bb, r.x + pad, ico_y) end)
    else
        local tw_b = TextWidget:new{ text = "‹", face = Font:getFace("cfont", scaleText(15)), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
        local bsz = tw_b:getSize()
        tw_b:paintTo(bb, r.x + pad, hy + math.floor((hh - bsz.h) / 2))
        tw_b:free()
    end

    local close_icon = loadSvg("x.svg", ico_sz, Blitbuffer.COLOR_BLACK)
    if close_icon then
        pcall(function() close_icon:paintTo(bb, r.x + r.w - pad - ico_sz, ico_y) end)
    else
        local tw_x = TextWidget:new{ text = "✕", face = Font:getFace("cfont", scaleText(12)), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
        local xsz = tw_x:getSize()
        tw_x:paintTo(bb, r.x + r.w - pad - xsz.w, hy + math.floor((hh - xsz.h) / 2))
        tw_x:free()
    end

    local tw_title = TextWidget:new{
        text = title,
        face = Font:getFace("cfont", scaleText(12)),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = r.w - (scale(56) * 2),
        truncate_with_ellipsis = true,
    }
    local tsz = tw_title:getSize()
    tw_title:paintTo(bb, r.x + pad + ico_sz + scale(12), hy + math.floor((hh - tsz.h) / 2))
    tw_title:free()

    bb:paintRect(r.x + border, hy + hh - 1, r.w - (border * 2), 1, Blitbuffer.COLOR_BLACK)
    return r, border, pad
end

-- Pastilla de fila presionada + divisor con sangría
local function fontDialogRowBg(self, bb, r, border, pad, idx, ry, rh)
    if self._pressed_row == idx then
        local pin = scale(6)
        paintRoundRect(bb, r.x + border + pin, ry + scale(2), r.w - (border + pin) * 2, rh - scale(4), scale(10), PRESSED_ROW_BG)
    end
    if idx > 1 and self._pressed_row ~= idx and self._pressed_row ~= (idx - 1) then
        bb:paintRect(r.x + pad, ry, r.w - pad * 2, 1, ROW_DIVIDER_COLOR)
    end
end

-- Cara real de la fuente de la fila (para previsualizarla); si falla, la de la interfaz
local function fontDialogRowFace(fname)
    local item_face = Font:getFace("cfont", scaleText(12))
    pcall(function()
        local ok_cre, credoc = pcall(require, "document/credocument")
        if ok_cre and credoc and credoc.engineInit then
            local ok2, cre2 = pcall(credoc.engineInit, credoc)
            if ok2 and cre2 and cre2.getFontFaceFilenameAndFaceIndex then
                local f_file, f_idx = cre2.getFontFaceFilenameAndFaceIndex(fname)
                if not f_file then f_file, f_idx = cre2.getFontFaceFilenameAndFaceIndex(fname, nil, true) end
                if f_file and f_idx then
                    local ok_f, custom_face = pcall(Font.getFace, Font, f_file, scaleText(12), f_idx)
                    if ok_f and custom_face then item_face = custom_face end
                end
            end
        end
    end)
    return item_face
end

-- Tocar fuera / X cierra todo; volver (izquierda) parpadea y regresa al menú anterior. true = consumido
local function fontDialogChromeTap(self, p)
    if not pointInRect(p, self.card_rect) then
        UIManager:close(self)
        return true
    end
    if self.btn_close_dimen and pointInRect(p, self.btn_close_dimen) then
        UIManager:close(self)
        return true
    end
    if self.btn_back_dimen and pointInRect(p, self.btn_back_dimen) then
        self._pressed_header = true
        self._flash_busy = true
        UIManager:setDirty(self, "ui", self.card_rect)
        UIManager:scheduleIn(0.1, function()
            self._flash_busy = false
            self._pressed_header = false
            if self._closed then return end
            self:closeDialog()
        end)
        return true
    end
    return false
end

-- Pie con paginador: puntitos saltan a la página; flechas parpadean y avanzan. true = consumido
local function fontDialogPagerTap(self, p)
    if not (self.footer_rect and pointInRect(p, self.footer_rect)) then return false end
    local pkind, pval = pagerTapAction(self._pager_geo, p)
    if pkind == "goto" then
        self:goToPage(pval)
    elseif pkind == "step" then
        self._pressed_nav = pval
        self._flash_busy = true
        UIManager:setDirty(self, "ui", self.footer_rect)
        UIManager:scheduleIn(0.1, function()
            self._flash_busy = false
            self._pressed_nav = nil
            if self._closed then return end
            local targets = { first = 1, prev = self.page - 1, next = self.page + 1, last = self.total_pages }
            self:goToPage(targets[pval])
        end)
    end
    return true
end

-- =========================================================================
-- DIÁLOGO Y GESTIÓN DE FUENTES FAVORITAS
-- =========================================================================
local FontSelectDialog = InputContainer:extend{
    ui = nil,
    scrubber_ui = nil,
    fonts = nil,
    page = 1,
    items_per_page = 14,
    card_rect = nil,
    row_dimens = nil,
    footer_rect = nil,
    btn_back_dimen = nil,
    btn_close_dimen = nil,
    popup_w = nil,   -- ancho de la ventana de ajustes, para que ambas se vean iguales
    on_close = nil,
}

function FontSelectDialog:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    self.header_h = scale(42)   -- mismo alto de encabezado que ajustes
    self.row_h = scale(38)
    self.footer_h = scale(34)
    self.page = 1

    self:updateLayout()

    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
            Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
    end
end

function FontSelectDialog:updateLayout()
    fontDialogLayout(self, self.fonts)
end

FontSelectDialog.goToPage = fontDialogGoToPage

function FontSelectDialog:prevPage()
    if self.page > 1 then
        self.page = self.page - 1
        self:updateLayout()
        UIManager:setDirty(self, "ui")
    end
end

function FontSelectDialog:nextPage()
    if self.page < self.total_pages then
        self.page = self.page + 1
        self:updateLayout()
        UIManager:setDirty(self, "ui")
    end
end

function FontSelectDialog:paintTo(bb, x, y)
    if not self.card_rect then return end
    local r, border, pad = fontDialogPaintFrame(self, bb, _("+ Add fonts"))

    local saved_fonts = (G_reader_settings and G_reader_settings:readSetting("page_scrubber_favorite_fonts")) or {}
    local saved_map = {}
    for _i, f in ipairs(saved_fonts) do saved_map[f] = true end

    for idx, rdef in ipairs(self.row_dimens or {}) do
        local fname = rdef.item
        local ry = rdef.dimen.y
        local rh = rdef.dimen.h

        fontDialogRowBg(self, bb, r, border, pad, idx, ry, rh)

        local item_face = fontDialogRowFace(fname)
        local is_already_added = saved_map[fname] == true
        local text_x = r.x + pad + scale(4)
        local max_tw = math.max(scale(40), r.w - (text_x - r.x) - scale(28))
        local tw_item = TextWidget:new{
            text = tostring(fname),
            face = item_face,
            bold = is_already_added,
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = max_tw,
            truncate_with_ellipsis = true,
        }
        local isz = tw_item:getSize()
        tw_item:paintTo(bb, text_x, ry + math.floor((rh - isz.h) / 2))
        tw_item:free()

        local tw_sym = TextWidget:new{
            text = is_already_added and "✓" or "+",
            face = Font:getFace("cfont", scaleText(is_already_added and 12 or 13)),
            bold = true,
            fgcolor = is_already_added and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        }
        local psz = tw_sym:getSize()
        tw_sym:paintTo(bb, r.x + r.w - pad - psz.w, ry + math.floor((rh - psz.h) / 2))
        tw_sym:free()
    end

    paintPager(bb, self._pager_geo, self._pressed_nav)
end

function FontSelectDialog:closeDialog()
    -- Primero se muestra el menú anterior y recién después se cierra el diálogo: ambos cambios
    -- se dibujan en una sola actualización de pantalla (sin el "cierra y abre" visible)
    if self.on_close then self.on_close() end
    UIManager:close(self)
end

function FontSelectDialog:onSwipe(arg1, arg2)
    local ges = arg2 or arg1
    if not ges then return false end
    local dir = ges.direction
    if dir == "left" or dir == "west" or dir == "up" or dir == "north" then
        self:nextPage()
        return true
    elseif dir == "right" or dir == "east" or dir == "down" or dir == "south" then
        self:prevPage()
        return true
    end
    return false
end

function FontSelectDialog:onTap(arg1, arg2)
    if self._flash_busy then return true end
    local p = getTouchPoint(arg1, arg2)
    if not p then return false end

    if fontDialogChromeTap(self, p) then return true end

    for idx, rdef in ipairs(self.row_dimens or {}) do
        if pointInRect(p, rdef.dimen) then
            local fname = rdef.item
            -- Pastilla gris un instante y recién ahí se agrega / quita de favoritas
            self._pressed_row = idx
            self._flash_busy = true
            UIManager:setDirty(self, "ui", self.card_rect)
            UIManager:scheduleIn(0.1, function()
                self._flash_busy = false
                self._pressed_row = nil
                if self._closed then return end

                local saved = (G_reader_settings and G_reader_settings:readSetting("page_scrubber_favorite_fonts")) or {}
                local idx_found = nil
                for i, existing in ipairs(saved) do
                    if existing == fname then
                        idx_found = i
                        break
                    end
                end

                if idx_found then
                    table.remove(saved, idx_found)
                else
                    table.insert(saved, fname)
                end

                if G_reader_settings then
                    G_reader_settings:saveSetting("page_scrubber_favorite_fonts", saved)
                    G_reader_settings:flush()
                end

                UIManager:setDirty(self, "ui")
            end)
            return true
        end
    end

    fontDialogPagerTap(self, p)
    return true
end

function FontSelectDialog:onShow()
    if self.ui then UIManager:setDirty(self.ui, "ui") end
    UIManager:setDirty(self, "ui")
end

function FontSelectDialog:onCloseWidget()
    self._closed = true
    if self.scrubber_ui then UIManager:setDirty(self.scrubber_ui, "ui") end
    if self.ui then UIManager:setDirty(self.ui, "ui") else UIManager:setDirty(nil, "ui") end
end

function ScrubberSettings:getAllSystemFonts()
    if self._cached_system_fonts then
        return self._cached_system_fonts
    end
    local faces = {}
    pcall(function()
        local ok, credoc = pcall(require, "document/credocument")
        if ok and credoc and credoc.engineInit then
            local ok2, cre = pcall(credoc.engineInit, credoc)
            if ok2 and cre and cre.getFontFaces then
                faces = cre.getFontFaces() or {}
            end
        end
    end)
    if type(faces) ~= "table" or #faces == 0 then
        faces = { "Noto Serif", "Noto Sans", "Droid Sans", "FreeSerif", "FreeSans" }
    end
    table.sort(faces, function(a, b) return tostring(a):lower() < tostring(b):lower() end)
    self._cached_system_fonts = faces
    return faces
end

-- =========================================================================
-- DIÁLOGO DE FUENTE DEL SISTEMA (mismo estilo que Add fonts / Scrubber Actions)
-- =========================================================================
local SystemFontSelectDialog = InputContainer:extend{
    ui = nil,
    scrubber_ui = nil,
    fonts = nil,
    font_notes = nil,
    page = 1,
    items_per_page = 14,
    card_rect = nil,
    row_dimens = nil,
    footer_rect = nil,
    btn_back_dimen = nil,
    btn_close_dimen = nil,
    popup_w = nil,   -- ancho de la ventana de ajustes, para que ambas se vean iguales
    on_close = nil,
}

function SystemFontSelectDialog:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    self.header_h = scale(42)   -- mismo alto de encabezado que ajustes
    self.row_h = scale(38)
    self.footer_h = scale(34)
    self.page = 1

    self:updateLayout()

    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
            Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
    end
end

function SystemFontSelectDialog:updateLayout()
    fontDialogLayout(self, self.fonts)
end

SystemFontSelectDialog.goToPage = fontDialogGoToPage

function SystemFontSelectDialog:prevPage()
    if self.page > 1 then
        self.page = self.page - 1
        self:updateLayout()
        UIManager:setDirty(self, "ui")
    end
end

function SystemFontSelectDialog:nextPage()
    if self.page < self.total_pages then
        self.page = self.page + 1
        self:updateLayout()
        UIManager:setDirty(self, "ui")
    end
end

function SystemFontSelectDialog:paintTo(bb, x, y)
    if not self.card_rect then return end
    local is_enabled = (G_reader_settings and G_reader_settings:readSetting("ui_font_enabled", true)) == true
    local title_txt = is_enabled and (_("System Font") .. "  ✓") or _("System Font")
    local r, border, pad = fontDialogPaintFrame(self, bb, title_txt)

    local current_name = (G_reader_settings and G_reader_settings:readSetting("ui_font_name")) or nil

    for idx, rdef in ipairs(self.row_dimens or {}) do
        local fname = rdef.item
        local ry = rdef.dimen.y
        local rh = rdef.dimen.h

        fontDialogRowBg(self, bb, r, border, pad, idx, ry, rh)

        local item_face = fontDialogRowFace(fname)
        local is_selected = (is_enabled and current_name == fname)
        local text_x = r.x + pad + scale(4)
        local max_tw = math.max(scale(40), r.w - (text_x - r.x) - scale(28))
        local tw_item = TextWidget:new{
            text = tostring(fname),
            face = item_face,
            bold = is_selected,
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = max_tw,
            truncate_with_ellipsis = true,
        }
        local isz = tw_item:getSize()
        tw_item:paintTo(bb, text_x, ry + math.floor((rh - isz.h) / 2))
        local name_w = isz.w
        tw_item:free()

        -- Aviso en gris al lado del nombre: sin bold / solo cursiva
        local note = self.font_notes and self.font_notes[fname]
        if note then
            local note_x = text_x + name_w + scale(8)
            local note_max = (r.x + r.w - pad - scale(28)) - note_x
            if note_max >= scale(40) then
                local tw_note = TextWidget:new{
                    text = note,
                    face = Font:getFace("cfont", scaleText(9)),
                    fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                    max_width = note_max,
                    truncate_with_ellipsis = true,
                }
                local nsz = tw_note:getSize()
                tw_note:paintTo(bb, note_x, ry + math.floor((rh - nsz.h) / 2))
                tw_note:free()
            end
        end

        local tw_sym = TextWidget:new{
            text = is_selected and "✓" or "",
            face = Font:getFace("cfont", scaleText(12)),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local psz = tw_sym:getSize()
        tw_sym:paintTo(bb, r.x + r.w - pad - psz.w, ry + math.floor((rh - psz.h) / 2))
        tw_sym:free()
    end

    paintPager(bb, self._pager_geo, self._pressed_nav)
end

function SystemFontSelectDialog:closeDialog()
    -- Primero se muestra el menú anterior y recién después se cierra el diálogo: ambos cambios
    -- se dibujan en una sola actualización de pantalla (sin el "cierra y abre" visible)
    if self.on_close then self.on_close() end
    UIManager:close(self)
end

function SystemFontSelectDialog:onSwipe(arg1, arg2)
    local ges = arg2 or arg1
    if not ges then return false end
    local dir = ges.direction
    if dir == "left" or dir == "west" or dir == "up" or dir == "north" then
        self:nextPage()
        return true
    elseif dir == "right" or dir == "east" or dir == "down" or dir == "south" then
        self:prevPage()
        return true
    end
    return false
end

-- La fuente del sistema se aplica con un patch mínimo (ui_font_patch.lua) que tiene
-- que correr ANTES de que KOReader cargue su interfaz. Un plugin se carga demasiado
-- tarde, así que lo copiamos solos a patches/. Se aplica en el próximo reinicio.
local function ensure_font_patch()
    local ok, err = pcall(function()
        local DataStorage = require("datastorage")
        local lfs = require("libs/libkoreader-lfs")
        local patches_dir = DataStorage:getDataDir() .. "/patches"
        if lfs.attributes(patches_dir, "mode") ~= "directory" then
            lfs.mkdir(patches_dir)
        end
        local function read_all(path)
            local f = io.open(path, "rb")
            if not f then return nil end
            local data = f:read("*a")
            f:close()
            return data
        end
        local src = read_all(plugin_path .. "ui_font_patch.lua")
        if not src then return end
        local dest = patches_dir .. "/2--page-scrubber-font.lua"
        if read_all(dest) == src then return end
        local f = assert(io.open(dest, "wb"))
        f:write(src)
        f:close()
    end)
    if not ok then
        require("logger").warn("page_scrubber: no se pudo instalar el patch de fuente:", err)
    end
end

function SystemFontSelectDialog:onTap(arg1, arg2)
    if self._flash_busy then return true end
    local p = getTouchPoint(arg1, arg2)
    if not p then return false end

    if fontDialogChromeTap(self, p) then return true end

    for idx, rdef in ipairs(self.row_dimens or {}) do
        if pointInRect(p, rdef.dimen) then
            local fname = rdef.item
            -- Pastilla gris un instante y recién ahí se aplica la elección
            self._pressed_row = idx
            self._flash_busy = true
            UIManager:setDirty(self, "ui", self.card_rect)
            UIManager:scheduleIn(0.1, function()
                self._flash_busy = false
                self._pressed_row = nil
                if self._closed then return end

                local current_name = (G_reader_settings and G_reader_settings:readSetting("ui_font_name")) or nil
                local is_enabled = (G_reader_settings and G_reader_settings:readSetting("ui_font_enabled", true)) == true

                -- Solo guardamos settings. NO aplicamos Font.fontmap acá
                -- (el patch 2--ui-font.lua lo aplica solo al arrancar).
                if is_enabled and current_name == fname then
                    if G_reader_settings then
                        G_reader_settings:saveSetting("ui_font_enabled", false)
                        G_reader_settings:flush()
                    end
                else
                    if G_reader_settings then
                        G_reader_settings:saveSetting("ui_font_enabled", true)
                        G_reader_settings:saveSetting("ui_font_name", fname)
                        G_reader_settings:flush()
                        ensure_font_patch()
                    end
                end

                -- Cerrar primero el diálogo de fuentes, después mostrar el cartel
                local ui_ref = self.ui
                local scrubber_ref = self.scrubber_ui
                local on_close_cb = self.on_close

                UIManager:close(self)

                UIManager:nextTick(function()
                    UIManager:show(ConfirmBox:new{
                        text = _("For the changes to apply, KOReader needs to be restarted."),
                        ok_text = _("Restart"),
                        cancel_text = _("Cancel"),
                        ok_callback = function()
                            UIManager:nextTick(function()
                                if UIManager.restartKOReader then
                                    UIManager:restartKOReader()
                                else
                                    -- Exit code 85 = restart en KOReader
                                    UIManager:quit(85)
                                end
                            end)
                        end,
                        cancel_callback = function()
                            -- Seguir como si nada: reabrir Appearance
                            if on_close_cb then
                                on_close_cb()
                            elseif ui_ref then
                                UIManager:nextTick(function()
                                    local ScrubberSettingsMod = require("scrubber_settings")
                                    local inst = ScrubberSettingsMod:new{
                                        ui = ui_ref,
                                        scrubber_ui = scrubber_ref,
                                    }
                                    inst.current_view = "appearance"
                                    inst.history = { "main" }
                                    inst.card_w = nil
                                    inst:updateLayout()
                                    UIManager:show(inst)
                                end)
                            end
                        end,
                    })
                end)
            end)
            return true
        end
    end

    fontDialogPagerTap(self, p)
    return true
end

function SystemFontSelectDialog:onShow()
    if self.ui then UIManager:setDirty(self.ui, "ui") end
    UIManager:setDirty(self, "ui")
end

function SystemFontSelectDialog:onCloseWidget()
    self._closed = true
    if self.scrubber_ui then UIManager:setDirty(self.scrubber_ui, "ui") end
    if self.ui then UIManager:setDirty(self.ui, "ui") else UIManager:setDirty(nil, "ui") end
end

function ScrubberSettings:getUIFontList()
    local font_list = {}
    local font_notes = {}
    local path_exists = {}
    for _i, font in ipairs(FontList.fontlist or {}) do
        path_exists[font] = true
    end
    pcall(function()
        for _i, name in ipairs(cre.getFontFaces() or {}) do
            local path_regular = cre.getFontFaceFilenameAndFaceIndex(name)
            if path_regular then
                if path_exists[path_regular] then
                    table.insert(font_list, name)
                    local no_bold, italic_only, bold_only = font_flags(path_regular, path_exists)
                    local notes = {}
                    if bold_only and italic_only then
                        table.insert(notes, _("bold italic only"))
                    elseif bold_only then
                        table.insert(notes, _("bold only"))
                    else
                        if italic_only then table.insert(notes, _("italic only")) end
                        if no_bold then table.insert(notes, _("no bold")) end
                    end
                    if #notes > 0 then font_notes[name] = "(" .. table.concat(notes, ", ") .. ")" end
                end
            end
        end
    end)
    table.sort(font_list, function(a, b) return tostring(a):lower() < tostring(b):lower() end)
    return font_list, font_notes
end

function ScrubberSettings:showSimpleUIManagedNotice()
    -- La fuente la gestiona SimpleUI: descartamos la que se eligió acá
    clear_own_font_choice()

    if Font.__scrubber_font_applied then
        -- Este arranque se aplicó nuestra fuente: hace falta reiniciar para que SimpleUI aplique la suya
        UIManager:show(ConfirmBox:new{
            text = _("The system font is managed by SimpleUI. Restart KOReader to apply it."),
            ok_text = _("Restart"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                UIManager:nextTick(function()
                    if UIManager.restartKOReader then
                        UIManager:restartKOReader()
                    else
                        UIManager:quit(85)
                    end
                end)
            end,
        })
    else
        UIManager:show(InfoMessage:new{
            text = _("The system font is managed by SimpleUI. Change it from SimpleUI's settings."),
        })
    end
end

function ScrubberSettings:openSystemFontDialog()
    ensure_font_patch()
    local font_list, font_notes = self:getUIFontList()
    local ui = self.ui
    local scrubber_ui = self.scrubber_ui

    UIManager:close(self)

    local dlg = SystemFontSelectDialog:new{
        ui = ui,
        scrubber_ui = scrubber_ui,
        fonts = font_list,
        popup_w = self.card_w,
        font_notes = font_notes,
        on_close = function()
            do   -- mismo tick (sin nextTick): se dibuja junto con el cierre del diálogo, sin parpadeo
                local ScrubberSettingsMod = require("scrubber_settings")
                local inst = ScrubberSettingsMod:new{
                    ui = ui,
                    scrubber_ui = scrubber_ui,
                }
                inst.current_view = "appearance"
                inst.history = { "main" }
                inst.card_w = nil
                inst:updateLayout()
                UIManager:show(inst)
            end
        end,
    }
    UIManager:show(dlg)
end

function ScrubberSettings:openAddFontDialog()
    local all_fonts = self:getAllSystemFonts()
    local ui = self.ui
    local scrubber_ui = self.scrubber_ui

    UIManager:close(self)

    local dlg = FontSelectDialog:new{
        ui = ui,
        scrubber_ui = scrubber_ui,
        fonts = all_fonts,
        popup_w = self.card_w,
        on_close = function()
            do   -- mismo tick (sin nextTick): se dibuja junto con el cierre del diálogo, sin parpadeo
                local ScrubberSettingsMod = require("scrubber_settings")
                local inst = ScrubberSettingsMod:new{
                    ui = ui,
                    scrubber_ui = scrubber_ui,
                }
                inst.current_view = "favorite_fonts"
                inst.history = { "main", "quick_menu" }
                inst.card_w = nil
                inst:updateLayout()
                UIManager:show(inst)
            end
        end,
    }
    UIManager:show(dlg)
end

function ScrubberSettings:confirmDeleteFont(idx, fname)
    UIManager:show(ConfirmBox:new{
        text = string.format(_("Remove \"%s\" from Favorite Fonts?"), tostring(fname)),
        ok_text = _("Remove"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            local current = self:readSetting("page_scrubber_favorite_fonts", {})
            table.remove(current, idx)
            self:saveSetting("page_scrubber_favorite_fonts", current)
            self:refreshView()
        end,
    })
end

function ScrubberSettings:openAddActionDialog()
    local current = self:readSetting("page_scrubber_quick_actions", {})
    if #current >= 8 then
        local alert_box = ConfirmBox:new{
            text = _("Maximum of 8 actions reached. Remove one first."),
            ok_text = _("OK"),
        }
        UIManager:show(alert_box)
        UIManager:scheduleIn(2, function()
            pcall(function() UIManager:close(alert_box) end)
        end)
        return
    end

    local actions = self:getAvailableActions()
    if #actions == 0 then
        local alert_box = ConfirmBox:new{
            text = _("No system actions available."),
            ok_text = _("OK"),
        }
        UIManager:show(alert_box)
        UIManager:scheduleIn(2, function()
            pcall(function() UIManager:close(alert_box) end)
        end)
        return
    end

    local ui = self.ui
    local scrubber_ui = self.scrubber_ui

    UIManager:close(self)

    local dlg = ActionSelectDialog:new{
        ui = ui,
        scrubber_ui = scrubber_ui,
        actions = actions,
        popup_w = self.card_w,
        on_close = function()
            do   -- mismo tick (sin nextTick): se dibuja junto con el cierre del diálogo, sin parpadeo
                local ScrubberSettingsMod = require("scrubber_settings")
                local inst = ScrubberSettingsMod:new{
                    ui = ui,
                    scrubber_ui = scrubber_ui,
                }
                inst.current_view = "scrubber_actions"
                inst.history = { "main", "quick_menu" }
                inst.card_w = nil
                inst:updateLayout()
                UIManager:show(inst)
            end
        end,
    }
    UIManager:show(dlg)
end

function ScrubberSettings:confirmDeleteAction(idx, action_def)
    local act_title = (type(action_def) == "table" and (action_def.title or action_def.id)) or tostring(action_def)
    UIManager:show(ConfirmBox:new{
        text = string.format(_("Remove \"%s\" from Scrubber Actions?"), act_title),
        ok_text = _("Remove"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            local current = self:readSetting("page_scrubber_quick_actions", {})
            table.remove(current, idx)
            self:saveSetting("page_scrubber_quick_actions", current)
            self:refreshView()
        end,
    })
end

function ScrubberSettings:executeAction(action_id)
    local scrubber = self.scrubber_ui
    UIManager:close(self)

    if scrubber then
        if scrubber._closeStay then
            pcall(function() scrubber:_closeStay() end)
        else
            pcall(function() UIManager:close(scrubber) end)
        end
    end

    UIManager:nextTick(function()
        local ok_disp, Dispatcher = pcall(require, "dispatcher")
        if not ok_disp or not Dispatcher then return end
        pcall(function() Dispatcher:init() end)

        local success, err = pcall(function()
            Dispatcher:execute({ [action_id] = true })
        end)

        if not success then
            local retry_ok = pcall(function()
                Dispatcher:execute(action_id)
            end)

            if not retry_ok then
                local alert_box = ConfirmBox:new{
                    text = _("Action unavailable in this document or view."),
                    ok_text = _("OK"),
                }
                UIManager:show(alert_box)
                UIManager:scheduleIn(2, function()
                    pcall(function() UIManager:close(alert_box) end)
                end)
            end
        end
    end)
end

function ScrubberSettings:showWallpaperFolderInfo()
    local ScrubberWallpaper = require("scrubber_wallpaper")
    local own_dir = ScrubberWallpaper.getOwnDir() or "koreader/settings/page_scrubber/wallpapers"
    local info_text = _("To add your own wallpapers, copy images (.png, .jpg) to:")
        .. "\n\n" .. own_dir .. "/\n\n"
        .. _("Shared folders also detected:") .. "\n"
        .. "• koreader/settings/bookshelf/wallpapers/\n"
        .. "• koreader/settings/simpleui/sui_wallpapers/\n"
        .. "• /mnt/us/Wallpapers/"

    UIManager:show(ConfirmBox:new{
        text = info_text,
        ok_text = _("OK"),
    })
end

function ScrubberSettings:openScaleDialog()
    local cur = math.floor((self:readSetting("page_scrubber_ui_scale", 1.0) * 100) + 0.5)
    local spin = SpinWidget:new{
        title_text = _("UI Scale (%)"),
        value = cur,
        value_min = 50, value_max = 200,
        value_step = 5, value_hold_step = 5,
        ok_text = _("Save"),
        callback = function(spin_widget)
            self:saveSetting("page_scrubber_ui_scale", spin_widget.value / 100)
            self:reopenEntireScrubber()
        end,
    }
    UIManager:show(spin)
end

-- =========================================================================
-- AJUSTES AVANZADOS: respaldo, restauración y reinicio de las opciones del plugin
-- =========================================================================
local function backupPath()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/page_scrubber_backup.lua"
end

-- Favoritos de la pestaña Images (archivo aparte, uno por libro)
local function favPath()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/page_scrubber_images_fav.lua"
end

-- Todas las opciones del plugin (las claves que empiezan con "page_scrubber_")
local function collectOwnSettings()
    local out = {}
    local data = G_reader_settings and G_reader_settings.data
    if type(data) == "table" then
        for k, v in pairs(data) do
            if type(k) == "string" and k:find("^page_scrubber_") then out[k] = v end
        end
    end
    return out
end

function ScrubberSettings:backupSettings()
    local path = backupPath()
    local count = 0
    local ok = pcall(function()
        local LuaSettings = require("luasettings")
        local f = LuaSettings:open(path)
        for k in pairs(f.data) do f.data[k] = nil end
        for k, v in pairs(collectOwnSettings()) do
            f:saveSetting(k, v)
            count = count + 1
        end
        -- Imágenes favoritas (clave sin prefijo "page_scrubber_": el bucle de restauración la ignora)
        local fav = LuaSettings:open(favPath())
        if type(fav.data) == "table" and next(fav.data) then
            f:saveSetting("images_fav", fav.data)
        end
        f:flush()
    end)
    if ok then
        UIManager:show(InfoMessage:new{
            text = _("Settings backed up to:") .. "\n" .. path .. "\n\n"
                .. _("To restore them on another device, copy this file to the same folder there."),
        })
    else
        UIManager:show(InfoMessage:new{ text = _("Could not back up the settings.") })
    end
end

function ScrubberSettings:confirmRestoreSettings()
    local path = backupPath()
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "file" then
        UIManager:show(InfoMessage:new{
            text = _("No backup found.") .. "\n\n"
                .. _("Use \"Back up settings\" first, or copy your page_scrubber_backup.lua file to:") .. "\n" .. path,
        })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("Restore the settings from this backup file? Your current settings will be replaced.") .. "\n\n" .. path,
        ok_text = _("Restore"),
        ok_callback = function()
            local ok = pcall(function()
                local LuaSettings = require("luasettings")
                local f = LuaSettings:open(path)
                for k, v in pairs(f.data) do
                    if type(k) == "string" and k:find("^page_scrubber_") then
                        G_reader_settings:saveSetting(k, v)
                    end
                end
                G_reader_settings:flush()

                -- Imágenes favoritas: se fusionan con las actuales (no se pisan)
                local bfav = f:readSetting("images_fav")
                if type(bfav) == "table" then
                    local ui = self.ui
                    local fs = (ui and ui._image_scanner_fav_settings) or LuaSettings:open(favPath())
                    for book, imgs in pairs(bfav) do
                        if type(imgs) == "table" then
                            local cur = fs:readSetting(book)
                            if type(cur) ~= "table" then cur = {} end
                            for p, v in pairs(imgs) do cur[p] = v end
                            fs:saveSetting(book, cur)
                        end
                    end
                    fs:flush()
                    -- Descarta la copia en memoria del libro abierto: si no, el próximo guardado pisaría lo restaurado
                    if ui then ui._image_scanner_book = nil end
                end
            end)
            if ok then
                self:reopenEntireScrubber()
            else
                UIManager:show(InfoMessage:new{ text = _("Could not restore the settings.") })
            end
        end,
    })
end

function ScrubberSettings:confirmClearImageCache()
    UIManager:show(ConfirmBox:new{
        text = _("Clear the image cache? The Images tab will scan your books again the next time you open it. Your favorite images are kept."),
        ok_text = _("Clear"),
        ok_callback = function()
            local ok = pcall(function()
                local LuaSettings = require("luasettings")
                local ui = self.ui

                -- 1) Archivo del caché en disco
                local f = LuaSettings:open(imageCachePath())
                for k in pairs(f.data) do f.data[k] = nil end
                f:flush()

                -- 2) Copias en memoria del libro abierto: si quedaran, el próximo guardado volvería a escribir el caché
                if ui then
                    local cached = ui._image_scanner_settings
                    if cached and type(cached.data) == "table" then
                        for k in pairs(cached.data) do cached.data[k] = nil end
                        cached:flush()
                    end
                    local book = ui._image_scanner_book
                    if type(book) == "table" then book.scan = nil end
                end
            end)
            -- Reabre el scrubber para que la pestaña Images arranque limpia (sin el escaneo viejo en memoria)
            self:reopenEntireScrubber()
            UIManager:scheduleIn(0.6, function()
                UIManager:show(InfoMessage:new{
                    text = ok and _("Image cache cleared.") or _("Could not clear the image cache."),
                    timeout = 2,
                })
            end)
        end,
    })
end

-- Selector de carpeta para el modo estudio "solo en una carpeta".
-- Al confirmar guarda la carpeta, pasa el modo a "folder" y reabre el scrubber.
function ScrubberSettings:chooseReviewFolder()
    local PathChooser = require("ui/widget/pathchooser")
    local lfs = require("libs/libkoreader-lfs")

    local start = self:readSetting("page_scrubber_review_folder", nil)
    if type(start) ~= "string" or lfs.attributes(start, "mode") ~= "directory" then
        start = G_reader_settings and G_reader_settings:readSetting("home_dir") or nil
    end

    UIManager:show(PathChooser:new{
        title = _("Choose study folder"),
        path = start,
        select_directory = true,
        select_file = false,
        show_files = false,
        onConfirm = function(path)
            if type(path) ~= "string" or path == "" then return end
            if #path > 1 then path = path:gsub("/+$", "") end
            self:saveSetting("page_scrubber_review_folder", path)
            self:saveSetting("page_scrubber_review_mode", "folder")
            self:reopenEntireScrubber()
        end,
    })
end

-- Reinicia el repaso espaciado (SRS) del libro abierto: todas las tarjetas empiezan de nuevo
function ScrubberSettings:confirmResetReview()
    UIManager:show(ConfirmBox:new{
        text = _("Reset the study progress of this book? Every highlight and note will start again from zero."),
        ok_text = _("Reset"),
        ok_callback = function()
            local ok = pcall(function()
                local SRS = require("srs")
                SRS.resetAll(self.ui)
            end)
            -- Reabre el scrubber para que el contador del tab de repaso se actualice
            self:reopenEntireScrubber()
            UIManager:scheduleIn(0.6, function()
                UIManager:show(InfoMessage:new{
                    text = ok and _("Study progress reset.") or _("Could not reset the study progress."),
                    timeout = 2,
                })
            end)
        end,
    })
end

function ScrubberSettings:confirmResetSettings()
    UIManager:show(ConfirmBox:new{
        text = _("Reset ALL PageScrubber settings to their defaults? This also clears your favorite fonts and quick actions. Tip: back them up first."),
        ok_text = _("Reset"),
        ok_callback = function()
            pcall(function()
                for k in pairs(collectOwnSettings()) do
                    G_reader_settings:delSetting(k)
                end
                G_reader_settings:flush()
            end)
            -- También las imágenes favoritas: se vacía la copia en memoria antes de borrar el archivo
            pcall(function()
                local ui = self.ui
                local fs = ui and ui._image_scanner_fav_settings
                if fs and type(fs.data) == "table" then
                    for k in pairs(fs.data) do fs.data[k] = nil end
                end
                if ui then
                    ui._image_scanner_book = nil
                    ui._image_scanner_fav_settings = nil
                end
                -- LuaSettings guarda la versión anterior en ".old" y la usa si falta el archivo principal:
                -- hay que borrarla también o los favoritos viejos reaparecen
                os.remove(favPath())
                os.remove(favPath() .. ".old")
                os.remove(favPath() .. ".new")
            end)
            self:reopenEntireScrubber()
        end,
    })
end

function ScrubberSettings:exportNotes()
    UIManager:close(self)
    local ui = self.ui
    if not ui or not ui.document then return end

    local title = "Book"
    pcall(function()
        if ui.doc_props and ui.doc_props.title and ui.doc_props.title ~= "" then
            title = ui.doc_props.title
        elseif ui.document and ui.document.file then
            title = ui.document.file:match("([^/\\]+)$") or "Book"
            title = title:gsub("%.%w+$", "")
        end
    end)

    local safe_title = title:gsub("%s+", "_"):gsub("[\\/:*?\"<>|]", "")
    local default_filename = safe_title .. "_" .. _("Notes") .. ".md"

    local dialog
    dialog = InputDialog:new{
        title = _("Export as..."),
        input = default_filename,
        buttons = {
            {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local filename = dialog:getInputText()
                        UIManager:close(dialog)

                        local info = InfoMessage:new{ text = _("Exporting...") }
                        UIManager:show(info)
                        UIManager:forceRePaint()

                        UIManager:scheduleIn(0.1, function()
                            local bm_pages_set = {}
                            pcall(function()
                                local bms = ui.doc_props and ui.doc_props.bookmarks
                                if type(bms) == "table" then
                                    for k, v in pairs(bms) do
                                        local p = tonumber(k) or (type(v) == "table" and (tonumber(v.page) or tonumber(v.pageno)))
                                        if p then bm_pages_set[math.floor(p)] = true end
                                    end
                                end
                            end)

                            local annotations = ui.annotation and ui.annotation.annotations or {}
                            local pages = {}
                            local page_order = {}

                            for _i, ann in ipairs(annotations) do
                                local p = tonumber(ann.pageno) or tonumber(ann.page) or tonumber(ann.pos0)
                                if type(ann.page) == "string" and ui.document and ui.document.getPageFromXPointer then
                                    pcall(function() p = ui.document:getPageFromXPointer(ann.page) end)
                                end
                                if p then
                                    p = math.floor(p)
                                    local has_drawer = ann.drawer ~= nil
                                    local has_note = ann.note and ann.note ~= ""
                                    if has_drawer or has_note then
                                        if not pages[p] then
                                            pages[p] = {}
                                            table.insert(page_order, p)
                                        end
                                        table.insert(pages[p], ann)
                                    else
                                        bm_pages_set[p] = true
                                    end
                                end
                            end
                            table.sort(page_order)

                            local bm_list = {}
                            for p, _v in pairs(bm_pages_set) do table.insert(bm_list, p) end
                            table.sort(bm_list)

                            local export_dir = ""
                            pcall(function()
                                local export_dir_ok, res = pcall(function()
                                    if ui.document and ui.document.file then
                                        return ui.document.file:match("^(.*[/\\])") or ""
                                    end
                                    return ""
                                end)
                                if export_dir_ok then export_dir = res end
                                if export_dir == "" then
                                    local DataStorage = require("datastorage")
                                    export_dir = DataStorage:getDataDir() .. "/"
                                end
                            end)

                            local full_path = export_dir .. filename
                            if not full_path:match("%.md$") then full_path = full_path .. ".md" end

                            local ok_export = pcall(function()
                                local f = io.open(full_path, "w")
                                if f then
                                    f:write("# " .. title .. "\n\n")
                                    if #bm_list > 0 then f:write("⚑ : " .. table.concat(bm_list, ", ") .. "\n\n") end
                                    f:write("---\n\n")
                                    for _i, p in ipairs(page_order) do
                                        f:write("## " .. tostring(p) .. "\n")

                                        for _i, ann in ipairs(pages[p]) do
                                            if ann.text and ann.text ~= "" then
                                                local text = ann.text:gsub("\n", " ")
                                                local drawer = ann.drawer or "lighten"
                                                if drawer == "invert" then f:write("> ◧ *" .. text .. "*\n")
                                                elseif drawer == "underscore" then f:write("> ﹏ **" .. text .. "**\n")
                                                elseif drawer == "strikeout" then f:write("> ✖ ~~" .. text .. "~~\n")
                                                else f:write("> ✪ " .. text .. "\n") end
                                            end
                                            if ann.note and ann.note ~= "" then f:write("- " .. ann.note:gsub("\n", " ") .. "\n") end
                                            f:write("\n")
                                        end
                                        f:write("---\n\n")
                                    end
                                    f:close()
                                    UIManager:close(info)
                                    local success_box = ConfirmBox:new{
                                        text = _("Saved successfully in:") .. "\n\n" .. full_path,
                                        ok_text = _("OK"),
                                    }
                                    UIManager:show(success_box)
                                else
                                    UIManager:close(info)
                                    local err_box = ConfirmBox:new{
                                        text = _("Failed to export notes"),
                                        ok_text = _("OK"),
                                    }
                                    UIManager:show(err_box)
                                end
                            end)

                            if not ok_export then
                                UIManager:close(info)
                                local err_box = ConfirmBox:new{
                                    text = _("System Error exporting notes."),
                                    ok_text = _("OK"),
                                }
                                UIManager:show(err_box)
                            end
                        end)
                    end
                }
            }
        }
    }
    UIManager:show(dialog)
end

function ScrubberSettings:paintTo(bb, x, y)
    local r = self.popup_rect
    local border = frameBorder()
    local radius = scale(18)

    paintRoundRect(bb, r.x, r.y, r.w, r.h, radius, Blitbuffer.COLOR_BLACK)
    paintRoundRect(bb, r.x + border, r.y + border, r.w - (border * 2), r.h - (border * 2), math.max(1, radius - border), Blitbuffer.COLOR_WHITE)

    local pad = rowPad()
    local data = self:getPageDefinition(self.current_view)
    local has_back = #self.history > 0

    -- Encabezado: [undo]  Título centrado  [X]  (se pone gris clarito solo mientras se presiona "volver")
    do
        local hy = r.y + border
        local hh = self.header_h
        if self._pressed_header then
            paintCornerRect(bb, r.x + border, hy, r.w - (border * 2), hh, math.max(1, radius - border), PRESSED_ROW_BG, true, true, false, false)
        end
        local ico_sz = scale(18)
        local ico_y = hy + math.floor((hh - ico_sz) / 2)

        if has_back then
            local back_icon = loadSvg("undo.svg", ico_sz, Blitbuffer.COLOR_BLACK)
            if back_icon then
                pcall(function() back_icon:paintTo(bb, r.x + pad, ico_y) end)
            else
                local tw_b = TextWidget:new{ text = "‹", face = Font:getFace("cfont", scaleText(15)), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
                local bsz = tw_b:getSize()
                tw_b:paintTo(bb, r.x + pad, hy + math.floor((hh - bsz.h) / 2))
                tw_b:free()
            end
        end

        local close_icon = loadSvg("x.svg", ico_sz, Blitbuffer.COLOR_BLACK)
        if close_icon then
            pcall(function() close_icon:paintTo(bb, r.x + r.w - pad - ico_sz, ico_y) end)
        else
            local tw_x = TextWidget:new{ text = "✕", face = Font:getFace("cfont", scaleText(12)), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
            local xsz = tw_x:getSize()
            tw_x:paintTo(bb, r.x + r.w - pad - xsz.w, hy + math.floor((hh - xsz.h) / 2))
            tw_x:free()
        end

        local tw_title = TextWidget:new{
            text = self:getPageTitle(data),
            face = Font:getFace("cfont", scaleText(12)),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK, -- Cambiado de COLOR_DARK_GRAY a COLOR_BLACK
            max_width = r.w - (scale(56) * 2),
            truncate_with_ellipsis = true,
        }
        local tsz = tw_title:getSize()
        
        -- Calcular posición izquierda, dejando espacio si está el botón "volver"
        local title_x = r.x + pad
        if has_back then
            title_x = title_x + ico_sz + scale(12)
        end
        
        tw_title:paintTo(bb, title_x, hy + math.floor((hh - tsz.h) / 2)) -- Alineado a la izquierda
        tw_title:free()

        -- La línea debajo del título es negra (el resto de divisiones son grises)
        bb:paintRect(r.x + border, hy + hh - 1, r.w - (border * 2), 1, Blitbuffer.COLOR_BLACK)
    end

    for idx, rdef in ipairs(self.row_dimens or {}) do
        local item = rdef.item
        local ry = rdef.dimen.y
        local rh = rdef.dimen.h

        -- Rótulo de sección (texto chico gris) encima del primer ítem del grupo
        if rdef.section_y and item.section then
            local tw_sec = TextWidget:new{
                text = tostring(item.section),
                face = Font:getFace("cfont", scaleText(9)),
                bold = true,
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                max_width = r.w - pad * 2,
                truncate_with_ellipsis = true,
            }
            local ssz = tw_sec:getSize()
            tw_sec:paintTo(bb, r.x + pad + scale(2), rdef.section_y + rdef.section_h - ssz.h - scale(3))
            tw_sec:free()
        end

        -- Fila presionada: pastilla redondeada gris clarito (mismo estilo que el menú derecho)
        if self._pressed_row == idx then
            local pin = scale(6)
            paintRoundRect(bb, r.x + border + pin, ry + scale(2), r.w - (border + pin) * 2, rh - scale(4), scale(10), PRESSED_ROW_BG)
        end

        -- Divisor gris con sangría (no se dibuja entre grupos ni pegado a la pastilla)
        if idx > 1 and not item.section and self._pressed_row ~= idx and self._pressed_row ~= (idx - 1) then
            bb:paintRect(r.x + pad, ry, r.w - pad * 2, 1, ROW_DIVIDER_COLOR)
        end

        local text_color = item.disabled and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK
        local icon_color = item.disabled and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK

        -- Resolver la fuente real de la fila antes de pintar el ícono o el texto
        local item_face = Font:getFace("cfont", scaleText(11))
        if item.font_name and item.font_name ~= "" then
            pcall(function()
                local ok_cre, credoc = pcall(require, "document/credocument")
                if ok_cre and credoc and credoc.engineInit then
                    local ok2, cre = pcall(credoc.engineInit, credoc)
                    if ok2 and cre and cre.getFontFaceFilenameAndFaceIndex then
                        local f_file, f_idx = cre.getFontFaceFilenameAndFaceIndex(item.font_name)
                        if not f_file then f_file, f_idx = cre.getFontFaceFilenameAndFaceIndex(item.font_name, nil, true) end
                        if f_file and f_idx then
                            local ok_f, custom_face = pcall(Font.getFace, Font, f_file, scaleText(11), f_idx)
                            if ok_f and custom_face then item_face = custom_face end
                        end
                    end
                end
            end)
        end

        local icon_offset_x = scale(4)
        local text_x = r.x + pad + icon_offset_x
        local icon_sz = scale(17)

        if item.icon and item.icon ~= "" then
            if not item.icon:match("%.svg$") then
                local tw_ico = TextWidget:new{
                    text = item.icon,
                    face = item_face,
                    bold = true,
                    fgcolor = icon_color,
                }
                local isz = tw_ico:getSize()
                local ix = r.x + pad + icon_offset_x + math.floor((icon_sz - isz.w) / 2)
                local iy = ry + math.floor((rh - isz.h) / 2)
                tw_ico:paintTo(bb, ix, iy)
                tw_ico:free()
                text_x = r.x + pad + icon_offset_x + icon_sz + scale(8)
            else
                local icon_widget = loadSvg(item.icon, icon_sz, icon_color)
                if icon_widget then
                    local iy = ry + math.floor((rh - icon_sz) / 2)
                    pcall(function()
                        icon_widget:paintTo(bb, r.x + pad + icon_offset_x, iy)
                    end)
                    text_x = r.x + pad + icon_offset_x + icon_sz + scale(8)
                end
            end
        end

        local right_reserved = scale(28)
        local tw_val
        if (item.kind == "submenu" or item.kind == "action") and not item.right_icon and item.value and item.value ~= "" then
            tw_val = TextWidget:new{
                text = tostring(item.value),
                face = Font:getFace("cfont", scaleText(10)),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                max_width = scale(130),
                truncate_with_ellipsis = true,
            }
            right_reserved = right_reserved + tw_val:getSize().w + scale(10)
        end
        if item.kind == "orderable_action" then
            -- Scrubber Actions y Favorite Fonts: reservan espacio para papelera, divisor y flechas (↑ ↓)
            right_reserved = scale(94)
        elseif item.kind == "orderable_toggle" then
            right_reserved = scale(98)
        end
        -- Wallpapers y opciones de radio usan el default de scale(28) para aprovechar todo el ancho hasta el tilde
        local max_tw = math.max(scale(40), r.w - (text_x - r.x) - right_reserved)

        local tw_item = TextWidget:new{
            text = tostring(item.text or ""),
            face = item_face,
            bold = item.bold == true,
            fgcolor = text_color,
            max_width = max_tw,
            truncate_with_ellipsis = true
        }
        local isz = tw_item:getSize()
        tw_item:paintTo(bb, text_x, ry + math.floor((rh - isz.h) / 2))
        tw_item:free()

        if item.kind == "orderable_toggle" then
            local check_w = scale(32)
            local arrow_w = scale(22)
            local is_chk = (self:readSetting(item.setting, item.default) == true)

            -- 1. Toggle switch a la derecha (\u{EC20} / \u{EC21})
            local toggle_str = is_chk and "\u{EC20}" or "\u{EC21}"
            local tw_chk = TextWidget:new{
                text = toggle_str,
                face = Font:getFace("cfont", scaleText(16)),
                fgcolor = is_chk and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
            }
            local cksz = tw_chk:getSize()
            tw_chk:paintTo(bb, r.x + r.w - pad - cksz.w, ry + math.floor((rh - cksz.h) / 2))
            tw_chk:free()

            -- Divisor sutil entre flechas y checkbox
            local div_x = r.x + r.w - pad - check_w - scale(4)
            bb:paintRect(div_x, ry + scale(5), 1, rh - scale(10), Blitbuffer.COLOR_LIGHT_GRAY)

            local icon_sz = scale(16)

            -- 2. Flecha ABAJO [ ↓ ]
            local can_down = (item.can_down ~= nil) and item.can_down or (item.order_idx < item.total_items)
            if can_down then
                local down_slot_x = div_x - scale(4) - arrow_w
                local down_icon = loadSvg("chevron-down.svg", icon_sz, Blitbuffer.COLOR_BLACK)

                if down_icon then
                    local ix = down_slot_x + math.floor((arrow_w - icon_sz) / 2)
                    local iy = ry + math.floor((rh - icon_sz) / 2)
                    pcall(function() down_icon:paintTo(bb, ix, iy) end)
                else
                    local tw_down = TextWidget:new{
                        text = "↓",
                        face = Font:getFace("cfont", scaleText(12)),
                        bold = true,
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    }
                    local dsz = tw_down:getSize()
                    tw_down:paintTo(bb, down_slot_x + math.floor((arrow_w - dsz.w) / 2), ry + math.floor((rh - dsz.h) / 2))
                    tw_down:free()
                end
            end

            -- 3. Flecha ARRIBA [ ↑ ]
            local can_up = (item.can_up ~= nil) and item.can_up or (item.order_idx > 1)
            if can_up then
                local up_slot_x = div_x - scale(4) - (arrow_w * 2)
                local up_icon = loadSvg("chevron-up.svg", icon_sz, Blitbuffer.COLOR_BLACK)

                if up_icon then
                    local ix = up_slot_x + math.floor((arrow_w - icon_sz) / 2)
                    local iy = ry + math.floor((rh - icon_sz) / 2)
                    pcall(function() up_icon:paintTo(bb, ix, iy) end)
                else
                    local tw_up = TextWidget:new{
                        text = "↑",
                        face = Font:getFace("cfont", scaleText(12)),
                        bold = true,
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    }
                    local usz = tw_up:getSize()
                    tw_up:paintTo(bb, up_slot_x + math.floor((arrow_w - usz.w) / 2), ry + math.floor((rh - usz.h) / 2))
                    tw_up:free()
                end
            end

        elseif item.kind == "orderable_action" then
            local trash_w = scale(26)
            local arrow_w = scale(22)
            local icon_sz = scale(16)

            -- 1. Botón Papelera (trash-2.svg)
            local trash_slot_x = r.x + r.w - pad - trash_w
            local trash_icon = loadSvg("trash-2.svg", icon_sz, Blitbuffer.COLOR_BLACK)
            if trash_icon then
                local ix = trash_slot_x + math.floor((trash_w - icon_sz) / 2)
                local iy = ry + math.floor((rh - icon_sz) / 2)
                pcall(function() trash_icon:paintTo(bb, ix, iy) end)
            else
                local tw_del = TextWidget:new{
                    text = "✕",
                    face = Font:getFace("cfont", scaleText(11)),
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
                local dsz = tw_del:getSize()
                tw_del:paintTo(bb, trash_slot_x + math.floor((trash_w - dsz.w) / 2), ry + math.floor((rh - dsz.h) / 2))
                tw_del:free()
            end

            -- Divisor sutil entre flechas y papelera
            local div_x = trash_slot_x - scale(4)
            bb:paintRect(div_x, ry + scale(5), 1, rh - scale(10), Blitbuffer.COLOR_LIGHT_GRAY)

            -- 2. Flecha ABAJO [ ↓ ]
            if item.can_down then
                local down_slot_x = div_x - scale(4) - arrow_w
                local down_icon = loadSvg("chevron-down.svg", icon_sz, Blitbuffer.COLOR_BLACK)
                if down_icon then
                    local ix = down_slot_x + math.floor((arrow_w - icon_sz) / 2)
                    local iy = ry + math.floor((rh - icon_sz) / 2)
                    pcall(function() down_icon:paintTo(bb, ix, iy) end)
                else
                    local tw_down = TextWidget:new{
                        text = "↓",
                        face = Font:getFace("cfont", scaleText(12)),
                        bold = true,
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    }
                    local dsz = tw_down:getSize()
                    tw_down:paintTo(bb, down_slot_x + math.floor((arrow_w - dsz.w) / 2), ry + math.floor((rh - dsz.h) / 2))
                    tw_down:free()
                end
            end

            -- 3. Flecha ARRIBA [ ↑ ]
            if item.can_up then
                local up_slot_x = div_x - scale(4) - (arrow_w * 2)
                local up_icon = loadSvg("chevron-up.svg", icon_sz, Blitbuffer.COLOR_BLACK)
                if up_icon then
                    local ix = up_slot_x + math.floor((arrow_w - icon_sz) / 2)
                    local iy = ry + math.floor((rh - icon_sz) / 2)
                    pcall(function() up_icon:paintTo(bb, ix, iy) end)
                else
                    local tw_up = TextWidget:new{
                        text = "↑",
                        face = Font:getFace("cfont", scaleText(12)),
                        bold = true,
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    }
                    local usz = tw_up:getSize()
                    tw_up:paintTo(bb, up_slot_x + math.floor((arrow_w - usz.w) / 2), ry + math.floor((rh - usz.h) / 2))
                    tw_up:free()
                end
            end

        elseif item.kind == "toggle" then
            local is_chk = item.read_func and (item.read_func() == true) or (self:readSetting(item.setting, item.default) == true)
            local toggle_str = is_chk and "\u{EC20}" or "\u{EC21}"
            local tw_chk = TextWidget:new{
                text = toggle_str,
                face = Font:getFace("cfont", scaleText(16)),
                fgcolor = item.disabled and Blitbuffer.COLOR_DARK_GRAY or (is_chk and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY)
            }
            local cksz = tw_chk:getSize()
            tw_chk:paintTo(bb, r.x + r.w - pad - cksz.w, ry + math.floor((rh - cksz.h) / 2))
            tw_chk:free()

        elseif item.kind == "submenu" or item.kind == "action" then
            if item.right_icon then
                local icon_sz = scale(16)
                local right_widget = loadSvg(item.right_icon, icon_sz, item.disabled and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK)
                if right_widget then
                    local iy = ry + math.floor((rh - icon_sz) / 2)
                    pcall(function()
                        right_widget:paintTo(bb, r.x + r.w - pad - icon_sz, iy)
                    end)
                else
                    local tw_del = TextWidget:new{
                        text = "✕",
                        face = Font:getFace("cfont", scaleText(11)),
                        bold = true,
                        fgcolor = item.disabled and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK
                    }
                    local dsz = tw_del:getSize()
                    tw_del:paintTo(bb, r.x + r.w - pad - dsz.w, ry + math.floor((rh - dsz.h) / 2))
                    tw_del:free()
                end
            else
                local tw_arrow = TextWidget:new{
                    text = "›",
                    face = Font:getFace("cfont", scaleText(13)),
                    bold = true,
                    fgcolor = item.disabled and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_DARK_GRAY
                }
                local asz = tw_arrow:getSize()
                tw_arrow:paintTo(bb, r.x + r.w - pad - asz.w, ry + math.floor((rh - asz.h) / 2))
                tw_arrow:free()
                if tw_val then
                    local vsz = tw_val:getSize()
                    tw_val:paintTo(bb, r.x + r.w - pad - asz.w - scale(6) - vsz.w, ry + math.floor((rh - vsz.h) / 2))
                end
            end

        elseif item.kind == "radio" and item.checked then
            local tw_chk = TextWidget:new{
                text = "✓",
                face = Font:getFace("cfont", scaleText(12)),
                bold = true,
                fgcolor = item.disabled and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK
            }
            local rsz = tw_chk:getSize()
            tw_chk:paintTo(bb, r.x + r.w - pad - rsz.w, ry + math.floor((rh - rsz.h) / 2))
            tw_chk:free()
        end

        if tw_val then tw_val:free() end
    end

    -- Paginador: puntitos (o |< < 1/23 > >| si no entran), igual que el panel de detalle del split
    paintPager(bb, self._pager_geo, self._pressed_nav)
end

function ScrubberSettings:onTap(arg1, arg2)
    -- Mientras la pastilla de "fila presionada" está en pantalla, se absorben los toques
    if self._flash_busy then return true end

    local ges = arg2 or arg1

    -- Encabezado (volver): se pone gris un instante y después vuelve al menú anterior
    if ges and ges.pos and self.btn_back_dimen and ges.pos:intersectWith(self.btn_back_dimen) then
        self._pressed_header = true
        self._flash_busy = true
        UIManager:setDirty(self, "ui", self.popup_rect)
        UIManager:scheduleIn(0.1, function()
            self._flash_busy = false
            self._pressed_header = false
            if self._closed then return end
            self:_onTapInner(arg1, arg2)
            if not self._closed then
                UIManager:setDirty(self, "ui", self.popup_rect)
            end
        end)
        return true
    end

    -- Paginador: tocar un puntito salta a esa página; las flechas parpadean un instante y avanzan
    local pkind, pval = pagerTapAction(self._pager_geo, ges and ges.pos)
    if pkind then
        if pkind == "goto" then
            self:pagerStep("goto", pval)
        elseif pkind == "step" then
            self._pressed_nav = pval
            self._flash_busy = true
            UIManager:setDirty(self, "ui", self.popup_rect)
            UIManager:scheduleIn(0.1, function()
                self._flash_busy = false
                self._pressed_nav = nil
                if self._closed then return end
                self:pagerStep(pval)
                if not self._closed then
                    UIManager:setDirty(self, "ui", self.popup_rect)
                end
            end)
        end
        return true
    end

    if ges and ges.pos and self.row_dimens then
        for idx, rdef in ipairs(self.row_dimens) do
            local k = rdef.item.kind
            if ges.pos:intersectWith(rdef.dimen) and not rdef.item.disabled
               and (k == "submenu" or k == "action" or k == "radio" or k == "toggle") then
                self._pressed_row = idx
                self._flash_busy = true
                UIManager:setDirty(self, "ui", self.popup_rect)
                UIManager:scheduleIn(0.1, function()
                    self._flash_busy = false
                    self._pressed_row = nil
                    if self._closed then return end
                    self:_onTapInner(arg1, arg2)
                    if not self._closed then
                        UIManager:setDirty(self, "ui", self.popup_rect)
                    end
                end)
                return true
            end
        end
    end
    return self:_onTapInner(arg1, arg2)
end

function ScrubberSettings:_onTapInner(arg1, arg2)
    local ges = arg2 or arg1
    if not ges or not ges.pos then return false end

    -- Tocar fuera cierra ÚNICAMENTE la ventana de ajustes; retorna true para no pasárselo a PageScrubber
    if not ges.pos:intersectWith(self.popup_rect) then
        UIManager:close(self)
        return true
    end

    local r = self.popup_rect

    -- Botón Atrás (encabezado, izquierda)
    if self.btn_back_dimen and ges.pos:intersectWith(self.btn_back_dimen) then
        self:popView()
        return true
    end

    -- Botón Cerrar (encabezado, derecha)
    if self.btn_close_dimen and ges.pos:intersectWith(self.btn_close_dimen) then
        UIManager:close(self)
        return true
    end

    -- Filas
    if self.row_dimens then
        for _i, rdef in ipairs(self.row_dimens) do
            if ges.pos:intersectWith(rdef.dimen) then
                local it = rdef.item

                if it.disabled then
                    return true
                end

                if it.kind == "orderable_toggle" then
                    local pad = rowPad()
                    local check_w = scale(32)
                    local arrow_w = scale(22)
                    local div_x = r.x + r.w - pad - check_w - scale(4)
                    local down_left = div_x - scale(4) - arrow_w
                    local up_left = down_left - arrow_w

                    if ges.pos.x >= div_x then
                        -- Tocar en la casilla activa/desactiva
                        local cur = (self:readSetting(it.setting, it.default) == true)
                        self:saveSetting(it.setting, not cur)
                        self:refreshView()
                        return true
                    elseif ges.pos.x >= down_left then
                        -- Flecha abajo
                        local can_down = (it.can_down ~= nil) and it.can_down or (it.order_idx < it.total_items)
                        if can_down then
                            self:moveOrderableItem(it.order_setting, it.default_order, it.item_key, 1)
                            self:refreshView()
                        end
                        return true
                    elseif ges.pos.x >= up_left then
                        -- Flecha arriba
                        local can_up = (it.can_up ~= nil) and it.can_up or (it.order_idx > 1)
                        if can_up then
                            self:moveOrderableItem(it.order_setting, it.default_order, it.item_key, -1)
                            self:refreshView()
                        end
                        return true
                    else
                        -- Tocar el nombre/ícono también cambia el estado del checkbox
                        local cur = (self:readSetting(it.setting, it.default) == true)
                        self:saveSetting(it.setting, not cur)
                        self:refreshView()
                        return true
                    end

                elseif it.kind == "orderable_action" then
                    local pad = rowPad()
                    local trash_w = scale(26)
                    local arrow_w = scale(22)
                    local div_x = r.x + r.w - pad - trash_w - scale(4)
                    local down_left = div_x - scale(4) - arrow_w
                    local up_left = down_left - arrow_w
                    local is_font_list = (self.current_view == "favorite_fonts")
                    local setting_key = is_font_list and "page_scrubber_favorite_fonts" or "page_scrubber_quick_actions"

                    if ges.pos.x >= div_x then
                        -- Tocar en la papelera: borra el ítem
                        if it.action then it.action() end
                        return true
                    elseif ges.pos.x >= down_left then
                        -- Flecha abajo: intercambia hacia adelante
                        if it.can_down then
                            local acts = self:readSetting(setting_key, {})
                            local idx = it.action_idx
                            if acts[idx] and acts[idx + 1] then
                                acts[idx], acts[idx + 1] = acts[idx + 1], acts[idx]
                                self:saveSetting(setting_key, acts)
                                self:refreshView()
                            end
                        end
                        return true
                    elseif ges.pos.x >= up_left then
                        -- Flecha arriba: intercambia hacia atrás
                        if it.can_up then
                            local acts = self:readSetting(setting_key, {})
                            local idx = it.action_idx
                            if acts[idx] and acts[idx - 1] then
                                acts[idx], acts[idx - 1] = acts[idx - 1], acts[idx]
                                self:saveSetting(setting_key, acts)
                                self:refreshView()
                            end
                        end
                        return true
                    else
                        if it.action then it.action() end
                        return true
                    end

                elseif it.kind == "submenu" then
                    self:pushView(it.target)
                    return true
                elseif it.kind == "toggle" then
                    local cur = it.read_func and (it.read_func() == true) or (self:readSetting(it.setting, it.default) == true)
                    local new_state = not cur
                    if not it.read_func then
                        self:saveSetting(it.setting, new_state)
                    end
                    if it.on_change then it.on_change(new_state) end

                    if it.setting == "page_scrubber_full_page_grid" or it.setting == "page_scrubber_hide_images_tab" or it.setting == "page_scrubber_review_enabled" then
                        self:reopenEntireScrubber()
                        return true
                    end

                    self:refreshView()
                    return true
                elseif it.kind == "radio" then
                    -- Opciones que necesitan un paso extra antes de guardarse (ej. elegir una carpeta)
                    if it.on_select then
                        it.on_select()
                        return true
                    end
                    self:saveSetting(it.setting, it.val)

                    if it.setting == "page_scrubber_review_mode" then
                        -- El botón Study aparece/desaparece: se reabre el scrubber como con el resto de ajustes de layout
                        self:reopenEntireScrubber()
                        return true
                    end

                    if it.setting == "page_scrubber_title_bg" then
                        if self.scrubber_ui then
                            UIManager:setDirty(self.scrubber_ui, "ui")
                        end
                        self:refreshView()
                        return true
                    end

                    if it.setting == "page_scrubber_text_size" then
                        self:reopenEntireScrubber()
                        return true
                    end

                    if it.setting == "page_scrubber_wallpaper" then
                        local ok_wp, ScrubberWallpaper = pcall(require, "scrubber_wallpaper")
                        if ok_wp and ScrubberWallpaper and ScrubberWallpaper.free then
                            ScrubberWallpaper.free()
                        end
                        if self.scrubber_ui then
                            UIManager:setDirty(self.scrubber_ui, "ui")
                        end
                        self:refreshView()
                        return true
                    end

                    self:refreshView()
                    return true
                elseif it.kind == "action" and it.action then
                    it.action()
                    return true
                end
            end
        end
    end

    return true
end

function ScrubberSettings:onShow()
    if self.ui then
        UIManager:setDirty(self.ui, "ui")
    end
    UIManager:setDirty(self, "ui")
end

function ScrubberSettings:onCloseWidget()
    self._closed = true
    if self.scrubber_ui then
        UIManager:setDirty(self.scrubber_ui, "ui")
    end
    if self.ui then
        UIManager:setDirty(self.ui, "ui")
    else
        UIManager:setDirty(nil, "ui")
    end
end

-- ==========================================
-- ÍCONOS PERSONALIZADOS (Appearance → Custom icons)
-- ==========================================
function ScrubberSettings:pickCustomIcon(filename)
    if not IconManager then return end
    local PathChooser = require("ui/widget/pathchooser")
    local lfs = require("libs/libkoreader-lfs")

    local start = self:readSetting("page_scrubber_icons_last_dir", nil)
    if type(start) ~= "string" or lfs.attributes(start, "mode") ~= "directory" then
        start = G_reader_settings and G_reader_settings:readSetting("home_dir") or nil
    end

    UIManager:show(PathChooser:new{
        title = string.format(_("Pick an SVG for %s"), filename),
        path = start,
        select_file = true,
        select_directory = false,
        show_files = true,
        file_filter = function(fname) return IconManager.isSvgFile(fname) end,
        onConfirm = function(path)
            if type(path) ~= "string" or path == "" then return end
            if not IconManager.isSvgFile(path) then
                UIManager:show(InfoMessage:new{ text = _("Please select a .svg file") })
                return
            end
            local folder = path:match("^(.*)[/\\][^/\\]+$")
            if folder and folder ~= "" then
                self:saveSetting("page_scrubber_icons_last_dir", folder)
            end
            local ok, err = IconManager.setCustom(filename, path)
            if ok then
                clear_icon_cache()
                UIManager:show(InfoMessage:new{
                    text = _("Icon updated. Reopen the scrubber to see the change."),
                    timeout = 3,
                })
                UIManager:nextTick(function() self:refreshView() end)
            else
                UIManager:show(InfoMessage:new{ text = _("Could not use that icon: ") .. tostring(err) })
            end
        end,
    })
end

function ScrubberSettings:confirmResetIcon(filename)
    UIManager:show(ConfirmBox:new{
        text = string.format(_("Reset \"%s\" to the default icon?"), filename),
        ok_text = _("Reset"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            if IconManager then IconManager.clearCustom(filename) end
            clear_icon_cache()
            self:refreshView()
        end,
    })
end

function ScrubberSettings:confirmResetAllIcons()
    UIManager:show(ConfirmBox:new{
        text = _("Reset ALL custom icons back to the plugin defaults?"),
        ok_text = _("Reset"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            if IconManager then IconManager.clearAllCustom() end
            clear_icon_cache()
            self:refreshView()
        end,
    })
end

-- =========================================================================================
-- NAVEGACIÓN CON TECLAS (dispositivos sin pantalla táctil o con botones físicos)
-- Mismas convenciones que scrubber_ui.lua (Device:hasKeys, Device.input.group.*):
--   Arriba / Abajo        = mover el foco entre filas (en diálogos con varias páginas, pasa de página en los extremos)
--   Select / Press        = activar la fila con foco (misma lógica que un toque, sin duplicarla)
--   Izquierda / Derecha   = página anterior / siguiente (también las teclas de página ← →);
--                           en filas ordenables (sin paginado) = subir / bajar el elemento
--   Atrás                 = volver una vista / cerrar el diálogo (como el botón "atrás" del encabezado)
-- El foco se dibuja como un marco negro sobre la fila: siempre sin pantalla táctil; con pantalla táctil
-- aparece al usar una tecla y se oculta al tocar.
-- =========================================================================================
do
    local function flatten_keys(...)
        local keys = {}
        for i = 1, select("#", ...) do
            local item = select(i, ...)
            if type(item) == "table" then
                for _, k in ipairs(item) do table.insert(keys, { k }) end
            elseif type(item) == "string" then table.insert(keys, { item }) end
        end
        return keys
    end

    -- Filas de ScrubberSettings que responden a un toque (las deshabilitadas no reciben foco)
    local FOCUSABLE_KINDS = {
        submenu = true, action = true, radio = true, toggle = true,
        orderable_toggle = true, orderable_action = true,
    }

    local function installKeyNav(Class, opts)
        local orig_init, orig_paint, orig_tap = Class.init, Class.paintTo, Class.onTap

        local function focusable(self, idx)
            local rdef = self.row_dimens and self.row_dimens[idx]
            if not rdef then return false end
            if opts.is_dialog then return true end
            local it = rdef.item
            return type(it) == "table" and FOCUSABLE_KINDS[it.kind] == true and not it.disabled
        end

        -- Deja el foco en una fila válida (la primera si el índice anterior ya no sirve)
        local function ensure(self)
            local n = self.row_dimens and #self.row_dimens or 0
            local f = self._kfocus
            if f and f >= 1 and f <= n and focusable(self, f) then return end
            self._kfocus = nil
            for i = 1, n do
                if focusable(self, i) then self._kfocus = i; return end
            end
        end

        local function edge(self, last)
            local n = self.row_dimens and #self.row_dimens or 0
            if last then
                for i = n, 1, -1 do if focusable(self, i) then return i end end
            else
                for i = 1, n do if focusable(self, i) then return i end end
            end
        end

        local function dirty(self)
            UIManager:setDirty(self, "ui", self.popup_rect or self.card_rect or self.dimen)
        end

        -- Reutiliza el onTap táctil con un toque sintético (así no se duplica la lógica de cada fila)
        local function tapAt(self, x, y)
            self._kfake = true
            Class.onTap(self, nil, { pos = Geom:new{ x = x, y = y, w = 0, h = 0 } })
            self._kfake = false
        end

        -- Cambia de página (pager de ScrubberSettings o diálogos paginados). true si hubo cambio.
        local function pageStep(self, dir)
            if opts.is_dialog then
                local total = self.total_pages or 1
                local target = (self.page or 1) + dir
                if total > 1 and target >= 1 and target <= total and self.goToPage then
                    self:goToPage(target)
                    return true
                end
                return false
            end
            if self._pager then
                self:pagerStep(dir > 0 and "next" or "prev")
                return true
            end
            return false
        end

        local function move(self, dir)
            ensure(self)
            local n = self.row_dimens and #self.row_dimens or 0
            local i = self._kfocus
            if n == 0 or not i then return end
            local first_f, last_f = edge(self, false), edge(self, true)
            if opts.is_dialog and (self.total_pages or 1) > 1 then
                if dir > 0 and i == last_f and pageStep(self, 1) then
                    self._kfocus = edge(self, false); return
                elseif dir < 0 and i == first_f and pageStep(self, -1) then
                    self._kfocus = edge(self, true); return
                end
            end
            for _ = 1, n do
                i = i + dir
                if i < 1 then i = n elseif i > n then i = 1 end
                if focusable(self, i) then self._kfocus = i; return end
            end
        end

        -- Subir / bajar una fila ordenable: mismo toque que las flechas ▲▼ y mismas condiciones
        local function reorder(self, dir)
            ensure(self)
            local f = self._kfocus
            local rdef = f and self.row_dimens[f]
            local it = rdef and rdef.item
            if type(it) ~= "table" or not (it.kind == "orderable_toggle" or it.kind == "orderable_action") then return end
            local can
            if it.kind == "orderable_toggle" then
                if dir < 0 then can = (it.can_up ~= nil) and it.can_up or (it.order_idx > 1)
                else can = (it.can_down ~= nil) and it.can_down or (it.order_idx < it.total_items) end
            else
                can = (dir < 0) and it.can_up or it.can_down
            end
            if not can then return end
            local r = self.popup_rect
            local arrow_w = scale(22)
            local tail_w = (it.kind == "orderable_toggle") and scale(32) or scale(26)
            local div_x = r.x + r.w - rowPad() - tail_w - scale(4)
            local down_left = div_x - scale(4) - arrow_w
            local up_left = down_left - arrow_w
            local x = ((dir < 0) and up_left or down_left) + math.floor(arrow_w / 2)
            tapAt(self, x, rdef.dimen.y + math.floor(rdef.dimen.h / 2))
            self._kfocus = math.max(1, math.min(#self.row_dimens, f + dir))   -- el foco acompaña al elemento
        end

        Class.init = function(self, ...)
            orig_init(self, ...)
            if Device:hasKeys() then
                self.key_events = {
                    ScrubKeyBack   = flatten_keys(Device.input.group.Back),
                    ScrubKeyPrev   = flatten_keys(Device.input.group.PgBack, Device.input.group.Left),
                    ScrubKeyNext   = flatten_keys(Device.input.group.PgFwd, Device.input.group.Right),
                    ScrubKeyUp     = flatten_keys(Device.input.group.Up),
                    ScrubKeyDown   = flatten_keys(Device.input.group.Down),
                    ScrubKeySelect = flatten_keys(Device.input.group.Select, Device.input.group.Press),
                }
            end
            self._key_vis = not Device:isTouchDevice()
        end

        -- Con un toque real, el marco de foco del teclado se oculta
        Class.onTap = function(self, a1, a2)
            if not self._kfake then self._key_vis = false end
            return orig_tap(self, a1, a2)
        end

        -- Marco de foco encima de lo ya pintado
        Class.paintTo = function(self, bb, x, y)
            orig_paint(self, bb, x, y)
            if self._key_vis and not self._closed then
                ensure(self)
                local f = self._kfocus
                local rdef = f and self.row_dimens and self.row_dimens[f]
                if rdef then
                    local d = rdef.dimen
                    local bx, by = d.x + scale(6), d.y + scale(2)
                    local bw, bh = d.w - scale(12), d.h - scale(4)
                    local th = math.max(2, scale(2))
                    local BLACK = Blitbuffer.COLOR_BLACK
                    bb:paintRect(bx, by, bw, th, BLACK)
                    bb:paintRect(bx, by + bh - th, bw, th, BLACK)
                    bb:paintRect(bx, by, th, bh, BLACK)
                    bb:paintRect(bx + bw - th, by, th, bh, BLACK)
                end
            end
        end

        -- Al cambiar de vista el foco vuelve a la primera fila
        if opts.view_change then
            for _i, name in ipairs({ "pushView", "popView" }) do
                local orig = Class[name]
                Class[name] = function(self, ...)
                    self._kfocus = nil
                    return orig(self, ...)
                end
            end
        end

        Class.onScrubKeyBack = function(self)
            if self._flash_busy or self._closed then return true end
            opts.back(self)
            return true
        end

        Class.onScrubKeyUp = function(self)
            if self._flash_busy or self._closed then return true end
            self._key_vis = true
            move(self, -1)
            dirty(self)
            return true
        end

        Class.onScrubKeyDown = function(self)
            if self._flash_busy or self._closed then return true end
            self._key_vis = true
            move(self, 1)
            dirty(self)
            return true
        end

        local function onSide(self, dir)
            if self._flash_busy or self._closed then return true end
            self._key_vis = true
            if pageStep(self, dir) then
                self._kfocus = nil   -- página nueva: foco en su primera fila
            elseif opts.reorder then
                reorder(self, dir)
            end
            dirty(self)
            return true
        end
        Class.onScrubKeyPrev = function(self) return onSide(self, -1) end
        Class.onScrubKeyNext = function(self) return onSide(self, 1) end

        Class.onScrubKeySelect = function(self)
            if self._flash_busy or self._closed then return true end
            self._key_vis = true
            ensure(self)
            local f = self._kfocus
            local rdef = f and self.row_dimens[f]
            if not rdef then return true end
            local d = rdef.dimen
            -- A la izquierda de la fila (zona del nombre): evita las flechas / casilla de las filas ordenables
            tapAt(self, d.x + math.floor(d.w * 0.25), d.y + math.floor(d.h / 2))
            return true
        end
    end

    installKeyNav(ScrubberSettings,       { back = function(self) self:popView() end, reorder = true, view_change = true })
    installKeyNav(ActionSelectDialog,     { is_dialog = true, back = function(self) self:closeDialog() end })
    installKeyNav(FontSelectDialog,       { is_dialog = true, back = function(self) self:closeDialog() end })
    installKeyNav(SystemFontSelectDialog, { is_dialog = true, back = function(self) self:closeDialog() end })
end

return ScrubberSettings

--[[
    page_scrubber.koplugin/scrubber_ui.lua
]]--

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local DocCache        = require("document/doccache")
local Event           = require("ui/event")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local UIManager       = require("ui/uimanager")
local logger          = require("logger")

-- Lector de .po en vivo (Estilo Storefront)
local _dict = {}
local _lang = "en"
if G_reader_settings then
    local l = G_reader_settings:readSetting("language")
    if type(l) == "string" then _lang = l:sub(1, 2) end
end

if _lang ~= "en" then
    local plugin_path = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
    local po_path = plugin_path .. "locales/" .. _lang .. ".po"
    local f = io.open(po_path, "r")
    if f then
        local current_id
        for line in f:lines() do
            local id = line:match('^msgid%s+"(.*)"')
            if id then current_id = id end
            local str = line:match('^msgstr%s+"(.*)"')
            if str and current_id then
                _dict[current_id] = str
                current_id = nil
            end
        end
        f:close()
    end
end

local function _(text)
    return _dict[text] or text
end

-- Colores de resaltado de KOReader, en el mismo orden que su menú
local HL_COLOR_ORDER = { "red", "orange", "yellow", "green", "olive", "cyan", "blue", "purple", "gray" }
local _gt = (function()
    local ok, g = pcall(require, "gettext")
    if ok and g then return g end
    return function(s) return s end
end)()
local HL_COLOR_NAMES = {
    red    = _gt("Red"),
    orange = _gt("Orange"),
    yellow = _gt("Yellow"),
    green  = _gt("Green"),
    olive  = _gt("Olive"),
    cyan   = _gt("Cyan"),
    blue   = _gt("Blue"),
    purple = _gt("Purple"),
    gray   = _gt("Gray"),
}

local GridSimpleView    = require("grid_simple_view")
local ProgressSlider    = require("progress_slider")
local ScrubberWallpaper = require("scrubber_wallpaper")
local ok_icon_mgr, IconManager = pcall(require, "icon_manager")   -- reemplazos de íconos del usuario
if not ok_icon_mgr then IconManager = nil end
local Screen            = Device.screen

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

-- Redibuja el contorno de un recuadro redondeado POR ENCIMA de lo que haya adentro (una imagen a
-- pantalla completa queda "detras" del borde). Las esquinas de afuera del contorno quedan blancas.
local function paintFrameOver(bb, x, y, w, h, r, thick)
    r = math.max(0, math.min(r, math.floor(w / 2), math.floor(h / 2)))
    local ri = math.max(0, r - thick)
    local function inset(j, rad)
        if rad <= 0 or j >= rad then return 0 end
        local d = rad - j - 0.5
        return rad - math.ceil(math.sqrt(rad * rad - d * d))
    end
    for row = 0, h - 1 do
        local edge = math.min(row, h - 1 - row)
        local o = inset(edge, r)
        if o > 0 then
            bb:paintRect(x, y + row, o, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x + w - o, y + row, o, 1, Blitbuffer.COLOR_WHITE)
        end
        if edge < thick then
            bb:paintRect(x + o, y + row, w - o * 2, 1, Blitbuffer.COLOR_BLACK)
        else
            local ii = thick + inset(edge - thick, ri)
            if ii > o then
                bb:paintRect(x + o, y + row, ii - o, 1, Blitbuffer.COLOR_BLACK)
                bb:paintRect(x + w - ii, y + row, ii - o, 1, Blitbuffer.COLOR_BLACK)
            end
        end
    end
end

-- Algoritmo de división en franjas horizontales exactas estilo Bookshelf
local function _roundedSpans(x, y, w, h, r)
    r = math.min(r or 0, math.floor(w / 2), math.floor(h / 2))
    if r <= 0 then
        return { { x = x, y = y, w = w, h = h } }
    end

    local spans = {}
    for i = 0, r - 1 do
        local dy = r - i - 0.5
        local inset = math.floor(r - math.sqrt(r * r - dy * dy) + 0.5)
        local sw = w - inset * 2
        if sw > 0 then
            spans[#spans + 1] = { x = x + inset, y = y + i,         w = sw, h = 1 }
            spans[#spans + 1] = { x = x + inset, y = y + h - 1 - i, w = sw, h = 1 }
        end
    end
    local mid_h = h - r * 2
    if mid_h > 0 then
        spans[#spans + 1] = { x = x, y = y + r, w = w, h = mid_h }
    end
    return spans
end

-- Tintado nativo por C (blendRectRGB32) con cero alocación de memoria
local function paintTranslucentPill(bb, x, y, w, h, r, strength)
    if not bb or w <= 0 or h <= 0 then return end
    strength = strength or 0.80 -- 80% de blanco para asegurar contraste
    local alpha = math.floor(255 * strength + 0.5)

    local no_cbb = type(bb.canUseCbb) == "function" and not bb:canUseCbb()
    local opaque = alpha >= 255 or not bb.blendRectRGB32 or no_cbb

    if opaque then
        paintRoundRect(bb, x, y, w, h, r, Blitbuffer.COLOR_WHITE)
        return
    end

    local tint = Blitbuffer.ColorRGB32(255, 255, 255, alpha)
    local spans = _roundedSpans(x, y, w, h, r)
    for i = 1, #spans do
        local s = spans[i]
        bb:blendRectRGB32(s.x, s.y, s.w, s.h, tint)
    end
end

local function paintTopSquareBottomRounded(bb, x, y, w, h, r, color)
    if w <= 0 or h <= 0 then return end
    paintRoundRect(bb, x, y, w, h, r, color)
    if r > 0 and h > r and w > 0 then bb:paintRect(x, y, w, r, color) end
end

local function paintBottomRoundedTab(bb, x, y, w, h, r, color)
    if w <= 0 or h <= 0 then return end
    r = math.min(r, h, math.floor(w / 2)) 
    if r <= 0 then bb:paintRect(x, y, w, h, color); return end
    
    bb:paintRect(x + r, y, w - 2*r, h, color)
    local flat_h = h - r
    if flat_h > 0 then
        bb:paintRect(x, y, r, flat_h, color)
        bb:paintRect(x + w - r, y, r, flat_h, color)
    end
    for j = 0, r - 1 do
        local arc = math.ceil(math.sqrt(r*r - (r-j-0.5)*(r-j-0.5)))
        if arc > 0 then
            bb:paintRect(x + r - arc, y + h - 1 - j, arc, 1, color)
            bb:paintRect(x + w - r,   y + h - 1 - j, arc, 1, color)
        end
    end
end

local function drawBookmarkRibbon(bb, x, y, w, h, color)
    local cut = math.floor(w / 2)
    local straight = h - cut
    if straight > 0 then bb:paintRect(x, y, w, straight, color) end
    for r = 0, cut - 1 do
        local leg = math.floor(w/2) - r
        if leg > 0 then
            bb:paintRect(x, y + straight + r, leg, 1, color)
            bb:paintRect(x + w - leg, y + straight + r, leg, 1, color)
        end
    end
end

local function paintTripleText(tw, bb, x, y)
    -- Triple dibujado para mejorar la legibilidad del texto gris oscuro en E-Ink
    tw:paintTo(bb, x, y)
    tw:paintTo(bb, x + 1, y)
    tw:paintTo(bb, x, y + 1)
end

local function paintTextWithHalo(tw, bb, x, y, halo_radius)
    local r = halo_radius or 1
    local max_r = math.max(1, math.floor(r + 0.5))
    local orig_fg = tw.fgcolor
    tw.fgcolor = Blitbuffer.COLOR_WHITE

    -- Barrido circular denso: cubre diagonales e intermedias eliminando huecos y pixelado
    local r_sq = max_r * max_r + max_r
    for dx = -max_r, max_r do
        for dy = -max_r, max_r do
            if dx ~= 0 or dy ~= 0 then
                if (dx * dx + dy * dy) <= r_sq then
                    tw:paintTo(bb, x + dx, y + dy)
                end
            end
        end
    end

    tw.fgcolor = orig_fg
    tw:paintTo(bb, x, y)
end

local function processTile(tile, req_w, req_h)
    if not tile or not tile.bb then return nil end
    -- Protege la lectura de dimensiones contra buffers C en estado transitorio
    local ok_dim, w, h = pcall(function() return tile.bb:getWidth(), tile.bb:getHeight() end)
    if not ok_dim or not w or not h or w <= 0 or h <= 0 then return nil end

    if w > req_w + 4 or h > req_h + 4 then
        -- Reducimos conservando la proporción real de la página (nunca se estira a req_w x req_h)
        local f = math.min(req_w / w, req_h / h)
        local nw = math.max(1, math.floor(w * f))
        local nh = math.max(1, math.floor(h * f))
        local ok, scaled = pcall(function() return tile.bb:scale(nw, nh) end)
        if ok and scaled then return { bb = scaled, is_scaled = true } end
    end
    
    -- Aislar memoria: copiamos el buffer nativo para evitar SIGSEGV si el motor limpia su caché
    local ok_cp, copied = pcall(function() return tile.bb:copy() end)
    if ok_cp and copied then return { bb = copied, is_scaled = true } end
    
    return nil
end

local function isDocRTL(ui)
    if not ui then return false end

    local function checkRTL(val)
        if not val then return false end
        local s = tostring(val):upper()
        return s == "R2L" or s == "RTL" or s == "REVERSE" or s == "BACKWARD" or s:find("RIGHT") ~= nil
    end

    -- 1. Ajustes del documento en KOReader (orden invertido / dirección)
    if ui.doc_settings and type(ui.doc_settings.readSetting) == "function" then
        if ui.doc_settings:readSetting("inverse_reading_order") == true then return true end
        if checkRTL(ui.doc_settings:readSetting("reading_direction")) then return true end
        if checkRTL(ui.doc_settings:readSetting("page_turns_direction")) then return true end
        local tap_zones = ui.doc_settings:readSetting("page_turns_tap_zones")
        if tap_zones == "invert" or tap_zones == "inverted" then return true end
    end

    -- 2. Propiedades nativas del motor del documento
    if ui.document then
        if type(ui.document.getReadingDirection) == "function" then
            local ok, dir = pcall(function() return ui.document:getReadingDirection() end)
            if ok and (checkRTL(dir) or dir == 2) then return true end
        end
        if ui.document.info then
            if checkRTL(ui.document.info.direction) then return true end
            if checkRTL(ui.document.info.manga) or checkRTL(ui.document.info.reading_direction) then return true end
        end
        if ui.document.is_rtl == true then return true end
    end

    -- 3. Módulo de paginación activo
    if ui.paging then
        if checkRTL(ui.paging.reading_direction) or checkRTL(ui.paging.page_turns_direction) then
            return true
        end
        if type(ui.paging.isRTL) == "function" then
            local ok, res = pcall(function() return ui.paging:isRTL() end)
            if ok and res == true then return true end
        end
    end

    -- 4. Detección por nombre de carpeta o archivo
    local file_path = (ui.document and ui.document.file) or ""
    local lower_path = file_path:lower()
    if lower_path:find("[/%s%-_]mangas?[/%s%-_]")
        or lower_path:find("%[manga%]")
        or lower_path:find("%(manga%)") then
        return true
    end

    -- 5. Configuración global nativa de KOReader
    if G_reader_settings then
        if G_reader_settings:readSetting("inverse_reading_order") == true then return true end
        if checkRTL(G_reader_settings:readSetting("reading_direction")) then return true end
        if checkRTL(G_reader_settings:readSetting("page_turns_direction")) then return true end
        local glob_tz = G_reader_settings:readSetting("page_turns_tap_zones")
        if glob_tz == "invert" or glob_tz == "inverted" then return true end
    end

    return false
end

local PageScrubber = InputContainer:extend{ name = "page_scrubber", transparent = true }

function PageScrubber:init()
    self._anti_ghost_ready = false
    require("ui/uimanager"):scheduleIn(0.4, function() 
        self._anti_ghost_ready = true 
    end)
    
    local ui  = self.ui
    local doc = ui.document

    local is_comic = false
    do
        local file = ui.document and ui.document.file
        local ext = file and file:match("%.([%a%d]+)$")
        if ext then
            ext = ext:lower()
            is_comic = (ext == "cbz" or ext == "cbr" or ext == "cb7" or ext == "cbt")
        end
    end
    self._is_comic = is_comic
    -- Tab de imagenes: solo en formatos soportados (EPUB); en comics/PDF el tab directamente no aparece
    if self._imgTabEnabled and self._imgSupported and not self:_imgSupported() then
        self._imgTabEnabled = false
    end
    -- Opcion de Ajustes > Layout: "Disable Images tab"
    if self._imgTabEnabled and G_reader_settings and G_reader_settings:isTrue("page_scrubber_hide_images_tab") then
        self._imgTabEnabled = false
    end
    local manual_rtl = nil
    if ui and ui.doc_settings then
        manual_rtl = ui.doc_settings:readSetting("page_scrubber_rtl")
    end
    if manual_rtl == nil and G_reader_settings then
        manual_rtl = G_reader_settings:readSetting("page_scrubber_rtl")
    end

    if manual_rtl ~= nil then
        self.is_rtl = (manual_rtl == true)
    else
        self.is_rtl = isDocRTL(ui)
    end

    local scale_factor = self.ui_scale or 1
    self.S = function(val)
        local base_px = Screen:scaleBySize(val)
        local res = math.floor((base_px * scale_factor) + 0.5)
        if val > 0 and res <= 0 then res = 1 end
        return res
    end
    local S = self.S

    self._old_can_do = Device.canDoSwipeAnimation
    Device.canDoSwipeAnimation = function() return false end
    self._saved_swipe_animations = Screen.swipe_animations
    Screen.swipe_animations = false

    self._origin_page = self.initial_origin or (ui.view and ui.view.state and ui.view.state.page) or 1
    self._cur_page    = self.initial_page or self._origin_page
    self._total_pages = (doc and doc.getPageCount and doc:getPageCount()) or 1

    -- Si cambio el layout (screen DPI / nro de paginas / tamano de pantalla), las miniaturas
    -- que ReaderThumbnail tiene en cache por nro de pagina ya no corresponden: se descartan.
    do
        local sig = table.concat({ tostring(Screen:getDPI()), tostring(self._total_pages),
                                   tostring(Screen:getWidth()), tostring(Screen:getHeight()) }, "|")
        -- Igual que el listado nativo de marcadores: refrescar pageno/pageref de TODAS las anotaciones
        -- desde su xpointer (ReaderAnnotation:updatePageNumbers). Sin esto, tras un cambio de
        -- orientacion/DPI/fuente KOReader las deja desactualizadas hasta que se abre ese listado.
        if ui and ui.annotation and type(ui.annotation.updatePageNumbers) == "function" then
            local changed = (ui._page_scrubber_layout_sig ~= sig)
            pcall(function() ui.annotation:updatePageNumbers(changed) end)
        end
        if ui and ui._page_scrubber_layout_sig ~= sig then
            if ui._page_scrubber_layout_sig ~= nil and ui.thumbnail then
                if ui.thumbnail.removeFromCache then
                    pcall(function() ui.thumbnail:removeFromCache(nil, true) end)
                elseif ui.thumbnail.tidyCache then
                    pcall(function() ui.thumbnail:tidyCache() end)
                end
            end
            ui._page_scrubber_layout_sig = sig
        end
    end
    self._pressed_btn = nil
    self._closing     = false
    self._hold_token  = 0
    self._hold_active = false
    
    self._view_mode = self.initial_view_mode or "grid" 
    self._base_grid_mode = self.base_mode or ((self.initial_view_mode == "grid_simple") and "grid_simple" or "grid")
    self._active_tab = self.initial_tab or "bookmarks"
    if self._active_tab == "images" and not self._imgTabEnabled then self._active_tab = "bookmarks" end 
    self._sort_order = self.initial_sort_order or "desc" 
    self._split_bm_page = self.initial_bm_page or 1  
    self._force_menu_sync = true 
    self._hide_action_buttons = true 
    self._split_fixed_page = self.initial_fixed_page or ((self._view_mode == "split") and self._cur_page or nil) 
    self._split_divider_x = nil
    self._hl_filter = self.initial_hl_filter or nil 
    self._hl_color_filter = self.initial_hl_color_filter or nil
    self._hl_color_counts = {}
    self._note_color_counts = {}
    self._tab_arrow_dimen = nil
    self._tab_arrow_tab_dimen = nil
    self._target_hl_order = self.initial_hl_order or self.hl_order or self.target_order or nil
    self._hl_types_present = { normal = false, invert = false, underline = false }
    self._hl_filter_dimens = {}
    self._hl_main_tab_dimen = nil
    self._tab_sort_dimen = nil

    if self._is_comic and self._view_mode == "split" then
        self._view_mode = "grid"
    end

    self._cached_bms  = nil
    self._cached_hl   = nil
    self._cached_notes = nil
    self._page_data   = {}
    
    -- Búfer de precarga deslizante estilo Zen OS (hasta 8 miniaturas en RAM)
    self._tile_cache = {}
    self._max_cached_tiles = 8
    
    self._is_busy     = true
    self._tasks_in_flight = 0
    self._pending_grid_update = false

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self._sw = sw
    self._sh = sh
    local pad = S(16)

    -- Calculamos el offset dinámico según la configuración del usuario
    local text_size_pref = G_reader_settings and G_reader_settings:readSetting("page_scrubber_text_size") or "medium"
    local t_off = 0
    if text_size_pref == "small" then t_off = -2
    elseif text_size_pref == "large" then
        local is_eink = (Device.isKindle and Device:isKindle()) or (Device.isKobo and Device:isKobo()) or (Device.isEink and Device:isEink())
        t_off = is_eink and 4 or 2
    end

    -- Aplicamos el desplazamiento a todos los tamaños base
    local S_GRANDE   = S(15 + t_off)
    local S_MEDIANO  = S(13 + t_off)
    local S_CHIQUITO = S(10 + t_off)
    local S_BOTTOM_GRAY = S(14 + t_off) 
    self.S_BOTTOM_GRAY = S_BOTTOM_GRAY


    self._tw_tab_sort = TextWidget:new{ text = "", face = Font:getFace("cfont", S_CHIQUITO) }
    self._tw_tab_bm   = TextWidget:new{ text = "", face = Font:getFace("cfont", S_CHIQUITO) }
    self._tw_tab_hl   = TextWidget:new{ text = "", face = Font:getFace("cfont", S_CHIQUITO) }
    self._tw_tab_note = TextWidget:new{ text = "", face = Font:getFace("cfont", S_CHIQUITO) }

    local top_h     = S(58)
    local top_bar_y = 0
    self._top_bar_dimen = Geom:new{ x = 0, y = top_bar_y, w = sw, h = top_h }
    self._top_bar_bg_color = 0xFFEAEAEA -- Gris tenue (92% luminosidad)

    self.font_ch    = Font:getFace("cfont", S_GRANDE)   -- se sigue usando en los botones "Delete"
    self.font_chapter = Font:getFace("cfont", S_MEDIANO) -- título del capítulo: mismo tamaño que "Library"
    self.font_title = Font:getFace("cfont", S_MEDIANO)  -- mismo tamaño que el texto "Library"
    self.font_info  = Font:getFace("cfont", self.S_BOTTOM_GRAY or S_MEDIANO)

    local function getBookTitle()
        local title
        if ui.doc_props and ui.doc_props.title and ui.doc_props.title ~= "" then title = ui.doc_props.title end
        if not title and ui.document and ui.document.getProps then
            local ok, props = pcall(function() return ui.document:getProps() end)
            if ok and props and props.title and props.title ~= "" then title = props.title end
        end
        if not title and ui.document and ui.document.file then
            local base = ui.document.file:match("([^/\\]+)$") or ui.document.file
            title = base:gsub("%.%w+$", "")
        end
        return title or ""
    end

    self._cbtn_sz  = S(46)
    local side_margin_btn = pad + S(6) 
    self.max_title_w = sw - (side_margin_btn * 2) - (self._cbtn_sz * 2) - S(10)
    
    self.tw_booktitle = TextWidget:new{ text = getBookTitle(), face = self.font_title, bold = true, fgcolor = Blitbuffer.COLOR_BLACK, max_width = sw - pad * 3 - S(44) }
    self.tw_chapter  = TextWidget:new{ text = "", face = self.font_chapter, bold = true, fgcolor = Blitbuffer.COLOR_BLACK, max_width = self.max_title_w }
    self.tw_info     = TextWidget:new{ text = "", face = self.font_info, fgcolor = Blitbuffer.COLOR_DARK_GRAY }

    self.tw_chapter:setText(_("—"))
    self.tw_info:setText("100% · 9999 / 9999")

    local title_margin_top = S(14)
    local title_margin_bot = S(8)
    local title_h = self.tw_booktitle:getSize().h
    
    self._booktitle_y = top_h + title_margin_top
    -- Donde empieza la barra blanca "Kindle": justo debajo de la linea divisoria de la barra superior
    -- (la negra de la barra inferior es la de _bar_dimen; esta se mide desde la superior)
    self._bar_top_y = top_h

    local ch_h = self.tw_chapter:getSize().h
    local info_h = self.tw_info:getSize().h

    self._slider = ProgressSlider:new{ width = sw - pad * 4, value = self._cur_page, value_min = 1, value_max = self._total_pages, ticks = nil, S = S, is_rtl = self.is_rtl }
    
    self:_updateChapterMarks()
    self:_invalidateBookmarksCache()
    local slider_h = self._slider:getSize().h

    local PLUGIN_DIR = debug.getinfo(1, "S").source:gsub("^@(.*)/[^/]*", "%1")

    local function createSafeIcon(icon_char, svg_filename, sz, custom_color)
        local fg = custom_color or Blitbuffer.COLOR_BLACK
        local base_path = PLUGIN_DIR .. "/icons/" .. svg_filename
        if IconManager then
            local custom_path = IconManager.resolvePath(svg_filename)
            if custom_path then base_path = custom_path end
        end
        local ok, widget = pcall(function()
            local ImageWidget = require("ui/widget/imagewidget")
            return ImageWidget:new{ 
                file = base_path, width = sz, height = sz, 
                alpha = true, fgcolor = fg,
                original_in_nightmode = false,
                file_do_cache = false,
            }
        end)
        if ok and widget then return widget end
        return TextWidget:new{ text = icon_char, face = Font:getFace("cfont", sz), fgcolor = fg }
    end

    local top_icon_sz = S(28)

    self.tw_lib       = createSafeIcon("\u{E344}", "arrow-left.svg", top_icon_sz)
    self.tw_lib_label = TextWidget:new{ text = _("Library"), face = Font:getFace("cfont", S_MEDIANO), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
    
    self.tw_fn        = createSafeIcon("⚙", "settings-2.svg", top_icon_sz)
    self.tw_bm        = createSafeIcon("\u{F044}", "notebook-pen.svg", top_icon_sz)
    self.tw_gallery   = createSafeIcon("\u{F009}", "gallery-horizontal.svg", top_icon_sz)
    self.tw_toc       = createSafeIcon("\u{F0CA}", "table-of-contents.svg", top_icon_sz)
    self.tw_grid_toggle = createSafeIcon("\u{E8EF}", "layout-grid.svg", top_icon_sz)
    self.tw_x         = createSafeIcon("✕", "x.svg", top_icon_sz)

    self.tw_ch_l      = createSafeIcon("\u{EBAD}", "skip-back.svg", S(32))
    self.tw_ch_r      = createSafeIcon("\u{EBAC}", "skip-forward.svg", S(32))

    local ctrl_icon_sz = S(24)
    local mark_icon_sz = S(42) 
    
    self.tw_ctrl_prev = createSafeIcon("‹", "chevron-left.svg", ctrl_icon_sz)
    self.icon_mark_empty = createSafeIcon("\u{F097}", "gravity-ui--bookmark.svg", mark_icon_sz)
    self.icon_mark_filled = createSafeIcon("\u{F02E}", "gravity-ui--bookmark-fill.svg", mark_icon_sz)
    self.tw_ctrl_mark = self.icon_mark_filled 
    self.tw_ctrl_next = createSafeIcon("›", "chevron-right.svg", ctrl_icon_sz)

    local tab_icon_sz = S(24)
    self.icon_tab_bm   = createSafeIcon("\u{E7B9}", "majesticons--book.svg", tab_icon_sz)
    self.icon_tab_hl   = createSafeIcon("\u{E931}", "majesticons--filter.svg", tab_icon_sz)
    self.icon_tab_note = createSafeIcon("\u{F075}", "majesticons--chat-2-text.svg", tab_icon_sz)
    self.icon_tab_img  = createSafeIcon("\u{F03E}", "image-svgrepo-com.svg", tab_icon_sz)

    -- Ícono del tab de repaso (SRS): highlighter.svg; si falta, glifo de refresco
    self.icon_tab_review = createSafeIcon("\u{F021}", "highlighter.svg", tab_icon_sz)
    -- Icono de aviso al lado del texto del botón Study (alert-circle.svg; si falta, un "!")
    self.icon_study_alert = createSafeIcon("!", "alert-circle.svg", tab_icon_sz)
    -- Ícono del botón Study cuando ya no queda nada por estudiar (abre el modo repaso): award.svg
    self.icon_study_done = createSafeIcon("\u{2605}", "award.svg", tab_icon_sz)

    self.icon_sort_asc  = createSafeIcon("\u{EBBB}", "arrow-up-wide-narrow.svg", tab_icon_sz)
    self.icon_sort_desc = createSafeIcon("\u{EBBC}", "arrow-down-wide-narrow.svg", tab_icon_sz)

    local pol_icon_sz = S(20) 
    self.icon_pol_note = createSafeIcon("\u{F448}", "gravity-ui--pencil-to-square.svg", pol_icon_sz)
    self.icon_pol_hl   = createSafeIcon("\u{ED51}", "boxicons--highlight-filled.svg", pol_icon_sz)
    self.icon_pol_bm   = createSafeIcon("\u{F02E}", "gravity-ui--bookmark-fill.svg", pol_icon_sz)
    self.icon_pol_pencil = createSafeIcon("\u{F040}", "pencil-line.svg", pol_icon_sz)
    self.icon_pol_img  = createSafeIcon("\u{F03E}", "image.svg", pol_icon_sz)
    self.icon_pol_img_fav  = createSafeIcon("*", "img-folder-fav.svg",     pol_icon_sz, Blitbuffer.COLOR_BLACK)
    self.icon_pol_img_gen  = createSafeIcon("=", "img-folder-general.svg", pol_icon_sz, Blitbuffer.COLOR_BLACK)
    self.icon_pol_img_junk = createSafeIcon("x", "trash-2.svg",            pol_icon_sz, Blitbuffer.COLOR_BLACK)
    self.icon_details_close = createSafeIcon("\u{21BA}", "undo.svg", S(22))      -- solo para salir del zoom
    self.icon_details_expand = createSafeIcon("\u{2922}", "expand.svg", S(22))   -- panel normal -> expandido
    self.icon_details_shrink = createSafeIcon("\u{2921}", "shrink.svg", S(22))   -- panel expandido -> normal

    local filter_icon_sz = S(14)
    self.icon_filter_hl_on  = createSafeIcon("\u{ED51}", "droplet.svg", filter_icon_sz, Blitbuffer.COLOR_BLACK)
    self.icon_filter_hl_off = createSafeIcon("\u{ED51}", "droplet.svg", filter_icon_sz, Blitbuffer.COLOR_DARK_GRAY)
    -- Carpetas del tab de imagenes: favoritas / generales / basura (encendido = negro, apagado = gris)
    self.icon_img_fav_on   = createSafeIcon("*", "img-folder-fav.svg",     filter_icon_sz, Blitbuffer.COLOR_BLACK)
    self.icon_img_fav_off  = createSafeIcon("*", "img-folder-fav.svg",     filter_icon_sz, Blitbuffer.COLOR_DARK_GRAY)
    self.icon_img_gen_on   = createSafeIcon("=", "img-folder-general.svg", filter_icon_sz, Blitbuffer.COLOR_BLACK)
    self.icon_img_gen_off  = createSafeIcon("=", "img-folder-general.svg", filter_icon_sz, Blitbuffer.COLOR_DARK_GRAY)
    self.icon_img_junk_on  = createSafeIcon("x", "trash-2.svg",            filter_icon_sz, Blitbuffer.COLOR_BLACK)
    self.icon_img_junk_off = createSafeIcon("x", "trash-2.svg",            filter_icon_sz, Blitbuffer.COLOR_DARK_GRAY)
    
    self.icon_filter_inv_on  = createSafeIcon("\u{F043}", "contrast.svg", filter_icon_sz, Blitbuffer.COLOR_BLACK)
    self.icon_filter_inv_off = createSafeIcon("\u{F043}", "contrast.svg", filter_icon_sz, Blitbuffer.COLOR_DARK_GRAY)
    
    self.icon_filter_ul_on  = createSafeIcon("\u{E932}", "underline.svg", filter_icon_sz, Blitbuffer.COLOR_BLACK)
    self.icon_filter_ul_off = createSafeIcon("\u{E932}", "underline.svg", filter_icon_sz, Blitbuffer.COLOR_DARK_GRAY)
    
    self.icon_filter_st_on  = createSafeIcon("\u{F0CC}", "strikethrough.svg", filter_icon_sz, Blitbuffer.COLOR_BLACK)
    self.icon_filter_st_off = createSafeIcon("\u{F0CC}", "strikethrough.svg", filter_icon_sz, Blitbuffer.COLOR_DARK_GRAY)

    local picker_icon_sz = S(22)
    self.icon_picker_hl  = createSafeIcon("\u{ED51}", "droplet.svg", picker_icon_sz, Blitbuffer.COLOR_BLACK)
    self.icon_picker_inv = createSafeIcon("\u{F043}", "contrast.svg", picker_icon_sz, Blitbuffer.COLOR_BLACK)
    self.icon_picker_ul  = createSafeIcon("\u{E932}", "underline.svg", picker_icon_sz, Blitbuffer.COLOR_BLACK)
    self.icon_picker_st  = createSafeIcon("\u{F0CC}", "strikethrough.svg", picker_icon_sz, Blitbuffer.COLOR_BLACK)
    -- Iconos de carpeta de imagenes para el panel de detalles (mismo tamano que los de tipo de highlight)
    self.icon_det_img_fav  = createSafeIcon("*", "img-folder-fav.svg",     picker_icon_sz, Blitbuffer.COLOR_BLACK)
    self.icon_det_img_gen  = createSafeIcon("=", "img-folder-general.svg", picker_icon_sz, Blitbuffer.COLOR_BLACK)
    self.icon_det_img_junk = createSafeIcon("x", "trash-2.svg",            picker_icon_sz, Blitbuffer.COLOR_BLACK)

    self.icon_btn_trash     = createSafeIcon("\u{F014}", "trash-2.svg", S(22), Blitbuffer.COLOR_BLACK)
    self.icon_btn_edit      = createSafeIcon("\u{F040}", "pencil-sparkles.svg", S(22), Blitbuffer.COLOR_BLACK)
    self.icon_btn_type      = createSafeIcon("\u{F1FC}", "pencil-ruler.svg", S(22), Blitbuffer.COLOR_BLACK)

    local box_icon_sz = S(22)
    self.icon_box_plus       = createSafeIcon("\u{002B}", "square-plus.svg", box_icon_sz)
    self.icon_box_minus_fill = createSafeIcon("\u{2212}", "square-minus-filled.svg", box_icon_sz)
    self.icon_box_minus      = createSafeIcon("\u{2212}", "square-minus.svg", box_icon_sz)
    self.icon_img_plus       = createSafeIcon("\u{002B}", "image-plus.svg", box_icon_sz)
    self.icon_img_minus      = createSafeIcon("\u{2212}", "image-minus.svg", box_icon_sz)
    self.icon_box_arrow      = createSafeIcon("\u{003E}", "square-arrow-right-enter.svg", box_icon_sz)
    
    self.icon_chevron_left   = createSafeIcon("‹", "chevron-left.svg", box_icon_sz)
    self.icon_chevron_right  = createSafeIcon("›", "chevron-right.svg", box_icon_sz)

    local gs_chevron_sz = S(44)
    self.icon_gs_chevron_left  = createSafeIcon("‹", "chevron-left.svg", gs_chevron_sz)
    self.icon_gs_chevron_right = createSafeIcon("›", "chevron-right.svg", gs_chevron_sz)
    
    local gs_x_sz = S(36)
    self.icon_gs_x = createSafeIcon("✕", "x.svg", gs_x_sz)
    -- Versiones blancas para el efecto al apretar del grid simple (fondo negro)
    self.icon_gs_x_inv             = createSafeIcon("✕", "x.svg", gs_x_sz, Blitbuffer.COLOR_WHITE)
    -- Flechitas del selector de color de las pestañas. El SVG tiene el trazo negro y el fgcolor no lo recolorea,
    -- así que se crean normales y se pintan con el truco de inversión (igual que los demás íconos de la pestaña activa)
    self.icon_tab_chev_down = createSafeIcon("\u{25BE}", "chevron-down.svg", S(16))
    self.icon_tab_chev_up   = createSafeIcon("\u{25B4}", "chevron-up.svg", S(16))
    self.icon_gs_chevron_left_inv  = createSafeIcon("‹", "chevron-left.svg", gs_chevron_sz, Blitbuffer.COLOR_WHITE)
    self.icon_gs_chevron_right_inv = createSafeIcon("›", "chevron-right.svg", gs_chevron_sz, Blitbuffer.COLOR_WHITE)

    self.tw_fb_l = TextWidget:new{ text = "‹", face = Font:getFace("cfont", S(48)), fgcolor = Blitbuffer.COLOR_BLACK }
    self.tw_fb_r = TextWidget:new{ text = "›", face = Font:getFace("cfont", S(48)), fgcolor = Blitbuffer.COLOR_BLACK }

    local p_top = S(8)
    local spacing1 = S(3)
    local spacing2 = S(4)
    local spacing3 = S(10)
    local mark_sz = S(36)
    local p_bot = S(12) 

    local bar_h = p_top + ch_h + spacing1 + info_h + spacing2 + slider_h + spacing3 + mark_sz + p_bot
    local bar_y = sh - bar_h
    self._bar_dimen = Geom:new{ x = 0, y = bar_y, w = sw, h = bar_h }

    local grid_top = self._booktitle_y + title_h + title_margin_bot
    local grid_y_avail = bar_y - grid_top
    self._grid_dimen = Geom:new{ x = 0, y = grid_top, w = sw, h = grid_y_avail }
    
    self._grid_cols = 3
    self._grid_rows = 1
    self._grid_margin = S(10)

    local is_landscape = sw > sh
    local fit_to_width = false
    if G_reader_settings then
        if G_reader_settings.isTrue then
            fit_to_width = G_reader_settings:isTrue("page_scrubber_full_page_grid")
        else
            local val = G_reader_settings:readSetting("page_scrubber_full_page_grid")
            fit_to_width = (val == true or val == "true" or val == 1)
        end
    end

    if is_landscape and (self._view_mode == "grid" or self._view_mode == "grid_six") then
        self._grid_dimen = Geom:new{ x = 0, y = top_h + S(8), w = sw, h = bar_y - top_h - S(8) }
        if self._view_mode == "grid_six" then
            local ok, GridSixLandscapeView = pcall(require, "grid_six_landscape_view")
            if ok and GridSixLandscapeView and GridSixLandscapeView.getSlotDimens then
                local slots = GridSixLandscapeView.getSlotDimens(self)
                if slots and slots[1] then
                    self._grid_item_w = slots[1].w
                    self._grid_item_h = slots[1].h
                end
            end
        else
            local ok, GridLandscapeView = pcall(require, "grid_landscape_view")
            if ok and GridLandscapeView and GridLandscapeView.getThumbDims then
                self._grid_item_w, self._grid_item_h = GridLandscapeView.getThumbDims(self)
            else
                local gap = S(16)
                self._grid_item_w = math.floor((sw - S(32) - gap * 2) / 3)
                self._grid_item_h = self._grid_dimen.h
            end
        end
    elseif fit_to_width then
        self._grid_item_w = math.floor((sw - 2 * self._grid_margin) / 3)
        self._grid_item_h = math.floor(self._grid_item_w * sh / sw)
    else
        self._grid_item_h = self._grid_dimen.h - 2 * self._grid_margin
        self._grid_item_w = math.floor(self._grid_item_h * sw / sh)
    end

    self._thumb_req_w = self._grid_item_w
    self._thumb_req_h = self._grid_item_h

    self._split_preview_w = math.floor(sw * 0.45)
    self._thumb_req_split_w = self._split_preview_w - S(20)
    self._thumb_req_split_h = math.floor(self._thumb_req_split_w * sh / sw)

    self._grid_tiles      = {}
    self._grid_start_page = nil
    self._grid_back_dimen = nil
    self._center_bm_touch_dimen = nil
    self._grid_batch_id   = nil
    self._grid_batch_seq  = 0
    self._grid_instance_id = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
    self._grid_disabled = not (ui.thumbnail and ui.thumbnail.getPageThumbnail)

    self._fallback_prev_dimen = Geom:new{ x = 0, y = self._grid_dimen.y, w = math.floor(sw / 3), h = self._grid_dimen.h }
    self._fallback_next_dimen = Geom:new{ x = sw - math.floor(sw / 3), y = self._grid_dimen.y, w = math.floor(sw / 3), h = self._grid_dimen.h }

    self._slider.on_change = function(v)
        self:_previewPage(v, self._slider._dragging)
    end

    self:_updateTexts()

    local btn_sz = S(42)
    local spacing = S(10)
    local left_base = S(16)
    local right_base = sw - S(14)
    local top_y = top_bar_y + math.floor((top_h - btn_sz) / 2)

    self._x_dimen   = Geom:new{ x = right_base - btn_sz, y = top_y, w = btn_sz, h = btn_sz }
    self._fn_dimen  = Geom:new{ x = self._x_dimen.x - spacing - btn_sz, y = top_y, w = btn_sz, h = btn_sz }
    self._bm_dimen  = Geom:new{ x = self._fn_dimen.x - spacing - btn_sz, y = top_y, w = btn_sz, h = btn_sz }
    self._toc_dimen = Geom:new{ x = self._bm_dimen.x - spacing - btn_sz, y = top_y, w = btn_sz, h = btn_sz }
    self._grid_toggle_dimen = Geom:new{ x = self._toc_dimen.x - spacing - btn_sz, y = top_y, w = btn_sz, h = btn_sz }

    self._lib_icon_dimen = Geom:new{ x = left_base, y = top_y, w = btn_sz, h = btn_sz }
    local lib_label_gap = S(4)
    local lib_label_sz = self.tw_lib_label:getSize()
    local lib_label_x = self._lib_icon_dimen.x + btn_sz + lib_label_gap
    self._lib_label_x = lib_label_x
    self._lib_label_y = top_bar_y + math.floor((top_h - lib_label_sz.h) / 2)
    self._lib_dimen = Geom:new{ x = left_base, y = top_y, w = (lib_label_x + lib_label_sz.w) - left_base + S(10), h = btn_sz }
    
    local current_y = bar_y + p_top
    self.ch_y_pos = current_y
    current_y = current_y + ch_h + spacing1

    self.info_y_pos = current_y
    current_y = current_y + info_h + spacing2

    self.slider_y_pos = current_y
    current_y = current_y + slider_h + spacing3

    self.ctrl_y_pos = current_y

    local side_sz = S(36)
    local ctrl_sp = S(10)
    local total_ctrl_w = side_sz * 2 + mark_sz + ctrl_sp * 2
    local ctrl_x = math.floor((sw - total_ctrl_w) / 2)
    self._ctrl_row_x0 = ctrl_x
    self._ctrl_row_x1 = ctrl_x + total_ctrl_w
    self._ctrl_row_h = mark_sz

    self._ctrl_prev_dimen = Geom:new{ x = ctrl_x, y = self.ctrl_y_pos, w = side_sz, h = side_sz }
    self._ctrl_mark_dimen = Geom:new{ x = ctrl_x + side_sz + ctrl_sp, y = self.ctrl_y_pos, w = mark_sz, h = mark_sz }
    self._ctrl_next_dimen = Geom:new{ x = ctrl_x + side_sz + mark_sz + ctrl_sp * 2, y = self.ctrl_y_pos, w = side_sz, h = side_sz }

    local g6_btn_w = S(50)
    self._gsix_prev_dimen = Geom:new{ x = pad * 2, y = self.ctrl_y_pos, w = g6_btn_w, h = mark_sz }
    self._gsix_next_dimen = Geom:new{ x = sw - pad * 2 - g6_btn_w, y = self.ctrl_y_pos, w = g6_btn_w, h = mark_sz }

    self._prev_ch_dimen = Geom:new{ x = side_margin_btn, y = self.ch_y_pos + S(2), w = self._cbtn_sz, h = self._cbtn_sz }
    self._next_ch_dimen = Geom:new{ x = sw - side_margin_btn - self._cbtn_sz, y = self.ch_y_pos + S(2), w = self._cbtn_sz, h = self._cbtn_sz }

    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    if Device:hasKeys() then
        self.key_events = {
            Close          = flatten_keys(Device.input.group.Back),
            PrevPage       = flatten_keys(Device.input.group.PgBack, Device.input.group.Left),
            NextPage       = flatten_keys(Device.input.group.PgFwd, Device.input.group.Right),
            NextChapterKey = flatten_keys(Device.input.group.PrevLine, Device.input.group.Up),
            PrevChapterKey = flatten_keys(Device.input.group.NextLine, Device.input.group.Down),
            Select         = flatten_keys(Device.input.group.Select, Device.input.group.Press),
        }
    end

    if self._grid_disabled then
        self.ges_events = { 
            Tap        = { GestureRange:new{ ges = "tap",         range = self.dimen } }, 
            Swipe      = { GestureRange:new{ ges = "swipe",       range = self.dimen } }, 
            MultiSwipe = { GestureRange:new{ ges = "multiswipe",  range = self.dimen } } 
        }
    else
        self.ges_events = {
            Touch       = { GestureRange:new{ ges = "touch",       range = self.dimen } },
            Tap         = { GestureRange:new{ ges = "tap",         range = self.dimen } },
            Pan         = { GestureRange:new{ ges = "pan",         range = self.dimen } },
            PanRelease  = { GestureRange:new{ ges = "pan_release", range = Geom:new{ x = 0, y = 0, w = sw, h = sh } } },
            Swipe       = { GestureRange:new{ ges = "swipe",       range = self.dimen } },
            MultiSwipe  = { GestureRange:new{ ges = "multiswipe",  range = self.dimen } },
            Hold        = { GestureRange:new{ ges = "hold",        range = self.dimen } },
            HoldRelease = { GestureRange:new{ ges = "hold_release",range = self.dimen } },
            Pinch       = { GestureRange:new{ ges = "pinch",       range = self.dimen } },
            Spread      = { GestureRange:new{ ges = "spread",      range = self.dimen } },
        }
    end

    if not self._grid_disabled then
        if self._is_comic then
            UIManager:scheduleIn(0.35, function()
                if not self._closing then self:_updateGridPages() end
            end)
        else
            UIManager:nextTick(function()
                if not self._closing then self:_updateGridPages() end
            end)
        end
    end

    -- Acción de Dispatcher "Study": abre el Review Card apenas el scrubber terminó de construirse
    if self.initial_open_review then
        UIManager:scheduleIn(0.35, function()
            if self._closing then return end
            -- Respeta el modo estudio (Off / Everywhere / Only in a folder) del libro abierto
            if not require("srs").isStudyActive(self.ui) then
                UIManager:show(InfoMessage:new{ text = _("Study mode is off for this book."), timeout = 2 })
                return
            end
            -- Las anotaciones se cargan perezosamente: asegurarlas antes de armar las tarjetas
            if not self._cached_hl then pcall(function() self:_extractAnnotations() end) end
            self:_openReviewCard()
        end)
    end
end

function PageScrubber:_freeTile(slot)
    -- Los buffers ahora son gestionados por self._tile_cache
    if slot then
        slot.tile_bb = nil
        slot.is_scaled = false
    end
end

function PageScrubber:_cacheTile(page, bb, is_scaled, w, h)
    if not page or not bb then return end
    if self._failed_pages then self._failed_pages[page] = nil end
    self._tile_cache[page] = {
        bb = bb,
        is_scaled = is_scaled,
        w = w,
        h = h,
        last_used = os.clock(),
    }

    -- Poda LRU: mantener el consumo de memoria acotado
    local count = 0
    local oldest_page = nil
    local oldest_time = math.huge

    for p, item in pairs(self._tile_cache) do
        count = count + 1
        -- Proteger las páginas actualmente en pantalla o adyacentes inmediatas (y las que se precargaron
        -- para el siguiente / anterior bookmark del panel de detalles)
        local is_protected = (math.abs(p - self._cur_page) <= 1) or (self._prefetch_keep and self._prefetch_keep[p])
        if not is_protected and item.last_used < oldest_time then
            oldest_time = item.last_used
            oldest_page = p
        end
    end

            if count > ((self._max_cached_tiles or 8) + (self._details_open and 3 or 0)) and oldest_page then
                self._tile_cache[oldest_page] = nil
            end

end

-- Precarga inmediata de las paginas vecinas (asi el siguiente tap ya la encuentra en cache).
-- Lo que evita el tildado es que cada navegacion nueva cancela las precargas viejas
-- (ver _updateGridPages), no demorar la precarga.
function PageScrubber:_preloadNeighborPages()
    if self._closing or self._grid_disabled then return end
    -- Panel de bookmark abierto: las paginas fisicas vecinas no sirven y harian esperar (en cola) a las
    -- de los bookmarks vecinos, que son las que se van a pedir al pasar
    if self:_preloadDetailsNeighborPages() then return end
    self:_doPreloadNeighborPages()
end

-- Panel de detalles de un BOOKMARK: muestra la pagina entera, y al pasar al siguiente / anterior bookmark esa
-- pagina suele estar lejos (la precarga normal solo cubre las paginas fisicas vecinas). Aca se precargan las
-- paginas de los bookmarks vecinos de la lista para que, al pasar, la miniatura ya este en cache.
function PageScrubber:_preloadDetailsNeighborPages()
    if self._closing or self._grid_disabled or self._view_mode ~= "split" or not self._details_open then return end
    local thumbnail = self.ui and self.ui.thumbnail
    if not (thumbnail and thumbnail.getPageThumbnail) then return end
    local w, h = self._thumb_req_split_w, self._thumb_req_split_h
    if not (w and h) then return end
    local ctx = self:_getDetailsContext()
    if not ctx or type(ctx.entry) == "table" or type(ctx.items) ~= "table" then
        self._prefetch_keep = nil   -- highlights / notas / imagenes no usan la miniatura de la pagina
        return
    end

    local dir = self._details_step_dir or 1
    local batch = "page_scrubber_preload_" .. tostring(self._grid_instance_id)
    self._details_prefetch_t = self._details_prefetch_t or {}
    local now = os.time()
    local keep = {}
    -- Orden de la cola: el siguiente en el sentido en que se pasa, el opuesto, y el segundo siguiente
    for _, off in ipairs({ dir, -dir, 2 * dir }) do
        local item = ctx.items[ctx.idx + off]
        local p = tonumber(type(item) == "table" and item.page or item)
        if p and p >= 1 and p <= self._total_pages then
            keep[p] = true
            if p ~= self._cur_page then
                local c = self._tile_cache[p]
                local ready = c and c.bb and c.w == w and c.h == h
                local t = self._details_prefetch_t[p]
                if not ready and not (self._failed_pages and self._failed_pages[p]) and not (t and now - t < 2) then
                    self._details_prefetch_t[p] = now
                    thumbnail:getPageThumbnail(p, w, h, batch, function(tile)
                        if self._details_prefetch_t then self._details_prefetch_t[p] = nil end
                        if self._closing or not tile or not tile.bb then return end
                        local processed = processTile(tile, w, h)
                        if processed and processed.bb then
                            self:_cacheTile(p, processed.bb, processed.is_scaled, w, h)
                        end
                    end)
                end
            end
        end
    end
    self._prefetch_keep = keep
    return true
end

function PageScrubber:_doPreloadNeighborPages()
    if self._closing or self._grid_disabled then return end
    local thumbnail = self.ui and self.ui.thumbnail
    if not thumbnail or not thumbnail.getPageThumbnail then return end

    local expected_req_w = (self._view_mode == "grid") and self._grid_item_w or self._thumb_req_split_w
    local expected_req_h = (self._view_mode == "grid") and self._grid_item_h or self._thumb_req_split_h
    if not expected_req_w or not expected_req_h then return end

    -- En Simple Grid se precargan [P+1, P-1, P+2, P-2]. En modo Grid [P+2, P-2].
    local offsets = (self._view_mode == "grid") and { 2, -2, 3, -3 } or { 1, -1, 2, -2 }
    if self.is_rtl then
        for i = 1, #offsets do offsets[i] = -offsets[i] end
    end
    -- Primero las paginas en la direccion en la que se esta navegando.
    if self._nav_dir and self._nav_dir ~= 0 then
        local first, rest = {}, {}
        for _, off in ipairs(offsets) do
            if (off > 0 and self._nav_dir > 0) or (off < 0 and self._nav_dir < 0) then
                first[#first + 1] = off
            else
                rest[#rest + 1] = off
            end
        end
        offsets = {}
        for _, off in ipairs(first) do offsets[#offsets + 1] = off end
        for _, off in ipairs(rest) do offsets[#offsets + 1] = off end
    end

    local preload_batch = "page_scrubber_preload_" .. tostring(self._grid_instance_id)

    for _, off in ipairs(offsets) do
        local target_p = self._cur_page + off
        if target_p >= 1 and target_p <= self._total_pages and not self._tile_cache[target_p] then
            thumbnail:getPageThumbnail(target_p, expected_req_w, expected_req_h, preload_batch, function(tile, resp_batch)
                if self._closing or not tile or not tile.bb then return end
                local processed = processTile(tile, expected_req_w, expected_req_h)
                if processed and processed.bb then
                    self:_cacheTile(target_p, processed.bb, processed.is_scaled, expected_req_w, expected_req_h)
                end
            end)
        end
    end
end

function PageScrubber:_updateChapterMarks()
    local show_marks = true
    if G_reader_settings then
        local val = G_reader_settings:readSetting("page_scrubber_show_chapter_marks")
        if val ~= nil then show_marks = val end
    end
    
    if not show_marks or not self.ui.toc then
        if self._slider then self._slider.chapters = nil end
        return
    end
    
    local marks = {}
    local curr = 0
    local last_title = self:_getChapter(1)
    local safety = 0
    
    -- Navegación dinámica: consulta las páginas de pantalla reales en vivo
    while curr and safety < 1000 do
        safety = safety + 1
        local next_p = self.ui.toc:getNextChapter(curr)
        if not next_p or next_p <= curr or next_p > self._total_pages then
            break
        end
        
        local current_title = self:_getChapter(next_p)
        -- Solo registra la marca si el nombre del capítulo inferior cambia
        if current_title and current_title ~= "—" and current_title ~= _("—") and current_title ~= last_title then
            table.insert(marks, next_p)
            last_title = current_title
        end
        curr = next_p
    end

    table.sort(marks)
    if self._slider then self._slider.chapters = marks end
end

function PageScrubber:_invalidateBookmarksCache()
    self._cached_bms = nil
    self._slider.bookmarks = self:_getAllBookmarks()
    self:_extractAnnotations()
end

function PageScrubber:_getNumericalPage(v)
    if type(v) ~= "table" then return nil end
    -- Documentos reflowables (EPUB/CRE): el xpointer es la fuente de verdad.
    -- `pageno` se guarda al crear la anotacion y queda desactualizado cuando cambia
    -- el layout (screen DPI, fuente, margenes...), mostrando una pagina equivocada.
    local doc = self.ui and self.ui.document
    if doc and type(doc.getPageFromXPointer) == "function" then
        for _, xp in ipairs({ v.page, v.pos0, v.xpointer }) do
            if type(xp) == "string" and not tonumber(xp) then
                local ok, res = pcall(function() return doc:getPageFromXPointer(xp) end)
                if ok and type(res) == "number" then return res end
            end
        end
    end
    if v.pageno and tonumber(v.pageno) then return tonumber(v.pageno) end
    local function try_convert(xp)
        if not xp then return nil end
        if tonumber(xp) then return tonumber(xp) end
        if self.ui.document and self.ui.document.getPageFromXPointer then
            local ok, res = pcall(function() return self.ui.document:getPageFromXPointer(xp) end)
            if ok and type(res) == "number" then return res end
        end
        return nil
    end
    return try_convert(v.page) or try_convert(v.pos0) or try_convert(v.xpointer)
end

function PageScrubber:_getAllBookmarks()
    if self._cached_bms then return self._cached_bms end
    local bms_map = {}
    local tp = self._total_pages or 1
    local function add_page(p)
        if type(p) == "number" and p >= 1 and p <= tp then bms_map[math.floor(p)] = true end
    end
    local function extract(list, strict_bookmark_only)
        if type(list) ~= "table" then return end
        for k, v in pairs(list) do
            if type(v) == "table" then
                local is_bm = (v.bookmark == true) or (v.type == "bookmark")
                local has_drawer = v.drawer ~= nil 
                if not strict_bookmark_only or is_bm or (not has_drawer and not v.highlight) then
                    local p = self:_getNumericalPage(v)
                    if p then add_page(p) end
                end
            else
                if type(k) == "number" and (type(v) == "string" or type(v) == "boolean") then add_page(k) end
            end
        end
    end
    pcall(function() extract(self.ui.doc_props and self.ui.doc_props.bookmarks, false) end)
    pcall(function() extract(self.ui.bookmark and self.ui.bookmark._bookmarks, false) end)
    pcall(function() extract(self.ui.bookmark and self.ui.bookmark.bookmarks, false) end)
    pcall(function() extract(self.ui.annotation and self.ui.annotation.annotations, true) end)

    local bms = {}
    for p, _ in pairs(bms_map) do table.insert(bms, p) end
    table.sort(bms, function(a, b) return tonumber(a) > tonumber(b) end)
    self._cached_bms = bms
    self._cached_bms_map = bms_map
    return bms
end

function PageScrubber:_extractAnnotations()
    self._cached_hl = {}
    self._cached_notes = {}
    self._page_data = {}
    self._hl_types_present = { normal = false, invert = false, underline = false, strikethrough = false }
    self._note_types_present = { normal = false, invert = false, underline = false, strikethrough = false }
    self._hl_color_counts = {}
    self._note_color_counts = {}
    local tp = self._total_pages or 1

    local function drawer_to_filter(drawer)
        if not drawer or drawer == "lighten" then return "normal"
        elseif drawer == "invert" then return "invert"
        elseif drawer == "underscore" then return "underline"
        elseif drawer == "strikeout" then return "strikethrough"
        end
        return "normal"
    end

    -- 1. Recolectar todas las anotaciones válidas
    local raw_anns = (self.ui.annotation and self.ui.annotation.annotations) or {}
    local valid_entries = {}

    for idx, item in ipairs(raw_anns) do
        local p = self:_getNumericalPage(item)
        if type(p) == "number" and p >= 1 and p <= tp then
            p = math.floor(p)
            local is_real_hl = (item.drawer ~= nil) or (item.pos0 ~= nil and item.pos1 ~= nil) or (item.highlight == true)
            local is_real_note = (item.note ~= nil and item.note ~= "")
            if is_real_hl or is_real_note then
                table.insert(valid_entries, { item = item, raw_index = idx, p = p })
            end
        end
    end

    -- Ordenar por posición real en el libro (pantalla de lectura y orden de creación)
    table.sort(valid_entries, function(a, b)
        if a.p ~= b.p then return a.p < b.p end
        return a.raw_index < b.raw_index
    end)

    -- Agrupar por página visible en pantalla (disp_page)
    local anns_by_disp = {}
    local disp_order = {}

    for _, entry in ipairs(valid_entries) do
        local disp_p = tostring(self:_getDisplayPageInfo(entry.p))
        if not anns_by_disp[disp_p] then
            anns_by_disp[disp_p] = {}
            table.insert(disp_order, disp_p)
        end
        table.insert(anns_by_disp[disp_p], entry)
    end

    -- 2. Asignar el orden por página visible y registrar en las listas
    for _, disp_p in ipairs(disp_order) do
        local items_on_disp = anns_by_disp[disp_p]
        local total_on_page = #items_on_disp

        for order, entry in ipairs(items_on_disp) do
            local item = entry.item
            local p = entry.p
            local filt = drawer_to_filter(item.drawer)
            local col = self:_getAnnColor(item)
            local date_val = item.datetime or item.time or item.date or item.timestamp

            self._page_data[p] = self._page_data[p] or {}
            if date_val and not self._page_data[p].date then
                self._page_data[p].date = date_val
            end

            -- Poblar datos de la página para los verificadores de interfaz
            if not self._page_data[p].hl_types then self._page_data[p].hl_types = {} end
            self._page_data[p].hl_types[filt] = true
            if item.text and item.text ~= "" then
                self._page_data[p].text = (self._page_data[p].text and (self._page_data[p].text .. " | ") or "") .. item.text
            end
            if item.note and item.note ~= "" then
                self._page_data[p].note = (self._page_data[p].note and (self._page_data[p].note .. " | ") or "") .. item.note
            end

            local data_entry = {
                page = p,
                disp_page = disp_p,
                order = order,
                total_on_page = total_on_page,
                type = filt,
                color = col,
                text = item.text or "",
                note = item.note or "",
                date = date_val,
                annotation = item,
                raw_index = entry.raw_index,
            }

            -- Destacados (Highlights)
            if (item.text and item.text ~= "") or item.drawer then
                table.insert(self._cached_hl, data_entry)
                self._hl_types_present[filt] = true
                if col then self._hl_color_counts[col] = (self._hl_color_counts[col] or 0) + 1 end
            end

            -- Notas
            if item.note and item.note ~= "" then
                table.insert(self._cached_notes, data_entry)
                self._note_types_present[filt] = true
                if col then self._note_color_counts[col] = (self._note_color_counts[col] or 0) + 1 end
            end
        end
    end

    -- Cargar fechas para páginas con marcadores puros
    local function extract_dates(src)
        if type(src) ~= "table" then return end
        for k, v in pairs(src) do
            local p = self:_getNumericalPage(v) or tonumber(k)
            if p and p >= 1 and p <= tp then
                p = math.floor(p)
                self._page_data[p] = self._page_data[p] or {}
                if not self._page_data[p].date then
                    local d = (type(v) == "table") and (v.datetime or v.time or v.date or v.timestamp) or v
                    if type(d) == "string" or type(d) == "number" then self._page_data[p].date = d end
                end
            end
        end
    end
    extract_dates(self.ui.doc_props and self.ui.doc_props.bookmarks)
    extract_dates(self.ui.bookmark and self.ui.bookmark._bookmarks)
    extract_dates(self.ui.bookmark and self.ui.bookmark.bookmarks)

    -- Validar que el filtro de color siga existiendo
    if self._hl_color_filter then
        local counts = (self._active_tab == "notes") and self._note_color_counts or self._hl_color_counts
        if (self._active_tab ~= "highlights" and self._active_tab ~= "notes")
           or not counts or (counts[self._hl_color_filter] or 0) <= 0 then
            self._hl_color_filter = nil
        end
    end

    -- Validar que el filtro de tipo activo siga existiendo (dentro del color elegido, si hay)
    local types_present = self:_getTypesPresent()
    if self._hl_filter and not types_present[self._hl_filter] then
        self._hl_filter = nil
    end
end

-- Color efectivo de una anotación. El estilo "invert" no admite color, así que no cuenta.
function PageScrubber:_getAnnColor(item)
    if not item or item.drawer == "invert" then return nil end
    return item.color or "gray"
end

-- Colores presentes en la pestaña (en el orden del menú de KOReader), con su cantidad
function PageScrubber:_getColorList(tab)
    tab = tab or self._active_tab
    local counts = (tab == "notes") and self._note_color_counts or self._hl_color_counts
    local list, seen = {}, {}
    if not counts then return list end
    for _, key in ipairs(HL_COLOR_ORDER) do
        if (counts[key] or 0) > 0 then
            table.insert(list, { key = key, count = counts[key], name = HL_COLOR_NAMES[key] })
            seen[key] = true
        end
    end
    local extras = {}
    for key, n in pairs(counts) do
        if not seen[key] and n > 0 then table.insert(extras, key) end
    end
    table.sort(extras)
    for _, key in ipairs(extras) do
        table.insert(list, { key = key, count = counts[key], name = key:sub(1, 1):upper() .. key:sub(2) })
    end
    return list
end

-- Color elegido en el filtro y su cantidad dentro de la pestaña (o nil si no hay filtro)
function PageScrubber:_getSelectedColorInfo(tab)
    tab = tab or self._active_tab
    if not self._hl_color_filter or (tab ~= "highlights" and tab ~= "notes") then return nil end
    for _, c in ipairs(self:_getColorList(tab)) do
        if c.key == self._hl_color_filter then return c.key, c.count end
    end
    return nil
end

-- Círculo con el color de resaltado (aro + relleno)
function PageScrubber:_paintColorDot(bb, x, y, d, key, ring_color)
    local ok, CFM = pcall(require, "color_filter_menu")
    if ok and CFM and CFM.paintDot then
        CFM.paintDot(bb, x, y, d, key, ring_color or Blitbuffer.COLOR_BLACK)
    end
end

function PageScrubber:_hasMultiColor(tab)
    tab = tab or self._active_tab
    if tab ~= "highlights" and tab ~= "notes" then return false end
    return #self:_getColorList(tab) >= 2
end

-- Tipos de estilo presentes en la pestaña activa (respetando el filtro de color)
function PageScrubber:_getTypesPresent()
    local tab = self._active_tab
    local base = (tab == "notes") and self._note_types_present or self._hl_types_present
    if not self._hl_color_filter then return base end
    local list = (tab == "notes") and self._cached_notes or self._cached_hl
    local present = { normal = false, invert = false, underline = false, strikethrough = false }
    for _, it in ipairs(list or {}) do
        if it.color == self._hl_color_filter then present[it.type] = true end
    end
    return present
end

function PageScrubber:_setColorFilter(key)
    if key == self._hl_color_filter then key = nil end
    self._hl_color_filter = key
    local types_present = self:_getTypesPresent()
    if self._hl_filter and not types_present[self._hl_filter] then
        self._hl_filter = nil
    end
    self._split_bm_page = 1
    self._split_selected_item = nil
    self:_scheduleDetailsResync()
    UIManager:setDirty(self, "ui", self.dimen)
end

function PageScrubber:_openColorMenu(anchor)
    local list = self:_getColorList()
    if #list < 2 then return end
    local ok, ColorFilterMenu = pcall(require, "color_filter_menu")
    if not ok or not ColorFilterMenu then return end

    self._color_menu_is_open = true
    if self._tab_arrow_tab_dimen then
        UIManager:setDirty(self, "ui", self._tab_arrow_tab_dimen)
    end

    -- Retrasamos 50ms la apertura para que el Kindle refresque primero
    -- el cambio del triángulo y no "recorte" el menú de E-ink.
    UIManager:scheduleIn(0.05, function()
        UIManager:show(ColorFilterMenu:new{
            scrubber_ui = self,
            anchor = anchor,
            items = list,
            selected = self._hl_color_filter,
            on_select = function(key)
                self._color_menu_is_open = false
                self:_setColorFilter(key)
            end,
            on_close = function()
                self._color_menu_is_open = false
                if self._tab_arrow_tab_dimen then
                    UIManager:setDirty(self, "ui", self._tab_arrow_tab_dimen)
                end
            end,
            on_cancel = function()
                self._color_menu_is_open = false
                if self._tab_arrow_tab_dimen then
                    UIManager:setDirty(self, "ui", self._tab_arrow_tab_dimen)
                end
            end
        })
    end)
end

-- Anotaciones del libro para el repaso: highlights + notas, sin duplicar las que tienen ambos
function PageScrubber:_getReviewItems()
    local items, seen = {}, {}
    for _i, it in ipairs(self._cached_hl or {}) do
        local k = it.raw_index or it.page
        if k and not seen[k] then seen[k] = true; items[#items + 1] = it end
    end
    for _i, it in ipairs(self._cached_notes or {}) do
        local k = it.raw_index or it.page
        if k and not seen[k] then seen[k] = true; items[#items + 1] = it end
    end
    return items
end

-- Botón "Study" a la derecha de las pestañas del split: abre el Review Card.
-- Muestra "Study (N)" con las tarjetas por repasar; si no hay lugar, solo "Study"; si tampoco, solo el ícono.
-- free_x = primer x libre después de la última pestaña; right_x = borde derecho disponible.
-- Devuelve el rectángulo del botón (para el toque) o nil si no entra.
function PageScrubber:_paintStudyButton(bb, y, h, free_x, right_x, font_sz)
    local S = self.S
    local SRS = require("srs")
    local review_items = self:_getReviewItems()
    local n = SRS.getDueCount(self.ui, review_items)
    -- Nada por estudiar: en vez de desaparecer queda solo el ícono award.svg (abre el modo repaso).
    -- Solo se oculta si el libro no tiene ningún highlight ni nota.
    local review_only = (n <= 0)
    if review_only and #review_items == 0 then return nil end
    local pressed = (self._pressed_btn == "study")
    local fg = pressed and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local face = Font:getFace("cfont", font_sz)
    local pad = S(14)
    local avail = right_x - free_x - S(6)

    -- Prioridad: texto con contador > sin contador; en cada caso se prefiere con el ícono de aviso a su izquierda
    local alert = self.icon_study_alert
    local asz = alert and alert:getSize() or { w = 0, h = 0 }
    local agap = S(6)
    local tw, use_alert
    local cands = review_only and {} or {
        { _("Study") .. " (" .. tostring(n) .. ")", true }, { _("Study") .. " (" .. tostring(n) .. ")", false },
        { _("Study"), true }, { _("Study"), false },
    }
    for _i, cand in ipairs(cands) do
        if not cand[2] or alert then
            local t = TextWidget:new{ text = cand[1], face = face, bold = true, fgcolor = fg }
            local need = t:getSize().w + pad * 2 + (cand[2] and (asz.w + agap) or 0)
            if need <= avail then tw = t; use_alert = cand[2]; break end
            t:free()
        end
    end

    local btn_icon = review_only and (self.icon_study_done or self.icon_tab_review) or self.icon_tab_review
    local isz = btn_icon and btn_icon:getSize() or { w = S(18), h = S(18) }
    local w = tw and (tw:getSize().w + pad * 2 + (use_alert and (asz.w + agap) or 0)) or (isz.w + S(16))
    if w > avail then return nil end

    local x = right_x - w
    local r = math.floor(h / 2)
    -- Gris clarito como las pestañas inactivas; negro mientras se presiona
    local fill = pressed and Blitbuffer.COLOR_BLACK
        or (Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_GRAY_D or Blitbuffer.COLOR_LIGHT_GRAY)
    paintRoundRect(bb, x, y, w, h, r, fill)

    if tw then
        local tsz = tw:getSize()
        local group_w = tsz.w + (use_alert and (asz.w + agap) or 0)
        local gx = x + math.floor((w - group_w) / 2)
        if use_alert then
            local ax, ay = gx, y + math.floor((h - asz.h) / 2)
            if pressed then
                bb:paintRect(ax, ay, asz.w, asz.h, Blitbuffer.COLOR_WHITE)
                alert:paintTo(bb, ax, ay)
                bb:invertRect(ax, ay, asz.w, asz.h)
            else
                alert:paintTo(bb, ax, ay)
            end
            gx = gx + asz.w + agap
        end
        tw:paintTo(bb, gx, y + math.floor((h - tsz.h) / 2))
        tw:free()
    elseif btn_icon then
        local ix, iy = x + math.floor((w - isz.w) / 2), y + math.floor((h - isz.h) / 2)
        if pressed then
            bb:paintRect(ix, iy, isz.w, isz.h, Blitbuffer.COLOR_WHITE)
            btn_icon:paintTo(bb, ix, iy)
            bb:invertRect(ix, iy, isz.w, isz.h)
        else
            btn_icon:paintTo(bb, ix, iy)
        end
    end
    return Geom:new{ x = x, y = y, w = w, h = h }
end

-- Etiqueta del tipo de anotación con su color entre paréntesis, igual que el título del panel de detalle:
-- "Highlight (Yellow)", "Strikethrough (Orange)", "Invert", "Note"
function PageScrubber:_getHighlightTypeLabel(e)
    if type(e) ~= "table" then return nil end
    local a = e.annotation
    if a and a.drawer == nil and type(e.note) == "string" and e.note ~= "" then
        return _("Note")
    end
    local type_names = {
        normal = _("Highlight"), invert = _("Invert"),
        underline = _("Underline"), strikethrough = _("Strikethrough"),
    }
    local label = type_names[e.type] or _("Highlight")
    if e.type ~= "invert" and type(e.color) == "string" and e.color ~= "" then
        local cname = HL_COLOR_NAMES[e.color] or (e.color:sub(1, 1):upper() .. e.color:sub(2))
        label = label .. " (" .. cname .. ")"
    end
    return label
end

-- Abre el Review Card (repaso espaciado)
function PageScrubber:_openReviewCard()
    local SRS = require("srs")
    local items = self:_getReviewItems()
    local due = SRS.getDue(self.ui, items)
    -- Sin tarjetas due: modo repaso (todas las tarjetas, sin botones Again/Good/Easy, no toca el SRS)
    local review_only = false
    if #due == 0 then
        due = SRS.getAll(self.ui, items)
        review_only = true
    end
    if #due == 0 then
        UIManager:show(InfoMessage:new{ text = _("Nothing to study right now."), timeout = 2 })
        return
    end
    local ReviewView = require("review_view")
    local rv = ReviewView:new{
        scrubber_ui = self,
        due = due,
        review_only = review_only,
        on_close = function()
            -- Refresca el contador del tab al cerrar el Review Card
            pcall(function() UIManager:setDirty(self, "ui", self.dimen) end)
        end,
    }
    -- e-ink (Kindle): refresh explícito de pantalla completa al abrir. Sin esto, la tarjeta queda pintada
    -- en el buffer pero la pantalla solo refresca el rect del botón (_flashAndDo) hasta el primer toque.
    UIManager:show(rv, "ui", rv.dimen)
    UIManager:setDirty(rv, "ui", rv.dimen)
end

-- Flechita hacia abajo (triángulo) para las pestañas con selector de color
function PageScrubber:_paintChevronDown(bb, x, y, w, h, color)
    for row = 0, h - 1 do
        local rw = w - math.floor(row * (w - 2) / math.max(1, h - 1))
        rw = math.max(2, rw)
        bb:paintRect(x + math.floor((w - rw) / 2), y + row, rw, 1, color)
    end
end

-- Flechita hacia arriba cuando el menú está abierto
function PageScrubber:_paintChevronUp(bb, x, y, w, h, color)
    for row = 0, h - 1 do
        local rw = w - math.floor((h - 1 - row) * (w - 2) / math.max(1, h - 1))
        rw = math.max(2, rw)
        bb:paintRect(x + math.floor((w - rw) / 2), y + row, rw, 1, color)
    end
end

-- Dentro de un mismo frame de pintado la lista filtrada se pide varias veces (menu, panel de detalles,
-- sincronizacion de seleccion...): se arma y ordena una sola vez mientras no cambie nada que la afecte.
-- Fuera del pintado (gestos, teclas) siempre se recalcula.
function PageScrubber:_getFilteredActiveList()
    if not self._in_paint then return self:_getFilteredActiveListUncached() end
    local fixed = self._split_fixed_page or self._origin_page
    local m = self._fal_memo
    if m and m.seq == self._paint_seq and m.tab == self._active_tab and m.hlf == self._hl_filter
        and m.hlcf == self._hl_color_filter and m.imgf == self._img_folder and m.sort == self._sort_order
        and m.fixed == fixed and m.hl == self._cached_hl and m.notes == self._cached_notes
        and m.bms == self._cached_bms then
        return m.list
    end
    local list = self:_getFilteredActiveListUncached()
    self._fal_memo = {
        seq = self._paint_seq, tab = self._active_tab, hlf = self._hl_filter, hlcf = self._hl_color_filter,
        imgf = self._img_folder, sort = self._sort_order, fixed = fixed,
        hl = self._cached_hl, notes = self._cached_notes, bms = self._cached_bms, list = list,
    }
    return list
end

function PageScrubber:_getFilteredActiveListUncached()
    local fixed_page = self._split_fixed_page or self._origin_page
    local active_list = {}
    if self._active_tab == "bookmarks" then active_list = self:_getAllBookmarks()
    elseif self._active_tab == "highlights" then active_list = self._cached_hl or {}
    elseif self._active_tab == "notes" then active_list = self._cached_notes or {}
    elseif self._active_tab == "images" and self._imgList then active_list = self:_imgList() end

    local other_items = {}
    for _, it in ipairs(active_list) do
        if self._active_tab == "bookmarks" then
            -- La pagina fijada tambien aparece en la lista si tiene bookmark (ademas de la fila fija de abajo)
            local p = tonumber(it)
            if p then
                table.insert(other_items, p)
            end
        else
            local passes_filter = true
            if self._hl_filter then
                passes_filter = (it.type == self._hl_filter)
            end
            if passes_filter and self._hl_color_filter then
                passes_filter = (it.color == self._hl_color_filter)
            end
            if passes_filter then
                table.insert(other_items, it)
            end
        end
    end

        local is_asc = (self._sort_order == "asc")
        if self._active_tab == "bookmarks" then
            table.sort(other_items, function(a, b)
                local na, nb = tonumber(a) or 0, tonumber(b) or 0
                if na ~= nb then
                    if is_asc then return na < nb else return na > nb end
                end
                return false
            end)
        else
            table.sort(other_items, function(a, b)
                -- 1. Ordenar por número de página
                if a.page ~= b.page then
                    if is_asc then return a.page < b.page else return a.page > b.page end
                end

                -- 2. En la misma página: asc va de 1 a X, desc va de X a 1
                local oa = a.order or 1
                local ob = b.order or 1
                if oa ~= ob then
                    if is_asc then return oa < ob else return oa > ob end
                end

                -- 3. Desempate estricto y consistente
                local ra = a.raw_index or 0
                local rb = b.raw_index or 0
                if is_asc then return ra < rb else return ra > rb end
            end)
        end
        return other_items
end

function PageScrubber:onNextChapterKey()
    if self._closing then return true end
    if self._view_mode == "split" then
        local items = self:_getFilteredActiveList()
        if #items > 0 then
            local cur_idx = nil
            for idx, it in ipairs(items) do
                if self._split_selected_item then
                    if it == self._split_selected_item then cur_idx = idx; break end
                else
                    local p = (type(it) == "table") and it.page or it
                    if tonumber(p) == tonumber(self._cur_page) then cur_idx = idx; break end
                end
            end
            local target_idx = (cur_idx and cur_idx > 1) and (cur_idx - 1) or #items
            local target_entry = items[target_idx]
            self._split_selected_item = (type(target_entry) == "table") and target_entry or nil
            local target_page = (type(target_entry) == "table") and target_entry.page or target_entry
            self._force_menu_sync = true
            self:_previewPage(target_page, false)
            return true
        end
    else
        self:_prevChapter()
    end
    return true
end

function PageScrubber:onPrevChapterKey()
    if self._closing then return true end
    if self._view_mode == "split" then
        local items = self:_getFilteredActiveList()
        if #items > 0 then
            local cur_idx = nil
            for idx, it in ipairs(items) do
                if self._split_selected_item then
                    if it == self._split_selected_item then cur_idx = idx; break end
                else
                    local p = (type(it) == "table") and it.page or it
                    if tonumber(p) == tonumber(self._cur_page) then cur_idx = idx; break end
                end
            end
            local target_idx = (cur_idx and cur_idx < #items) and (cur_idx + 1) or 1
            local target_entry = items[target_idx]
            self._split_selected_item = (type(target_entry) == "table") and target_entry or nil
            local target_page = (type(target_entry) == "table") and target_entry.page or target_entry
            self._force_menu_sync = true
            self:_previewPage(target_page, false)
            return true
        end
    else
        self:_nextChapter()
    end
    return true
end

function PageScrubber:onPrevPage() 
    if self._closing then return true end
    if self._view_mode == "split" then
        if self._active_tab == "images" then self._active_tab = "notes"
        elseif self._active_tab == "notes" then self._active_tab = "highlights"
        elseif self._active_tab == "highlights" then self._active_tab = "bookmarks"
        else self._active_tab = self._imgTabEnabled and "images" or "notes" end
        self._img_folder = nil
        self._split_selected_item = nil
        if self._active_tab == "images" then self:_imgEnsureScan() end
        self._hl_color_filter = nil
        self._split_bm_page = self.initial_bm_page or 1
        self:_extractAnnotations()
        UIManager:setDirty(self, "ui", self.dimen)
        return true
    else
        local jump = (self._view_mode == "grid_six") and self:_g6Count() or 1
        self:_stepPreview(self._cur_page - jump) 
    end
    return true 
end
function PageScrubber:onPageBackward() return self:onPrevPage() end

function PageScrubber:onNextPage() 
    if self._closing then return true end
    if self._view_mode == "split" then
        if self._active_tab == "bookmarks" then self._active_tab = "highlights"
        elseif self._active_tab == "highlights" then self._active_tab = "notes"
        elseif self._active_tab == "notes" and self._imgTabEnabled then self._active_tab = "images"
        else self._active_tab = "bookmarks" end
        self._img_folder = nil
        self._split_selected_item = nil
        if self._active_tab == "images" then self:_imgEnsureScan() end
        self._hl_color_filter = nil
        self._split_bm_page = self.initial_bm_page or 1
        self:_extractAnnotations()
        UIManager:setDirty(self, "ui", self.dimen)
        return true
    else
        local jump = (self._view_mode == "grid_six") and self:_g6Count() or 1
        self:_stepPreview(self._cur_page + jump) 
    end
    return true 
end
function PageScrubber:onPageForward() return self:onNextPage() end

function PageScrubber:onSelect()
    if self._closing then return true end
    self:_gotoPage(self._cur_page)
    self:_closeStay()
    return true
end

function PageScrubber:_removeBookmarkDirectly(target_page)
    local p = tonumber(target_page)
    if not p then return false end
    local ui = self.ui
    local removed = false

    -- 1. Intentar mediante la API de ReaderBookmark si existe
    if ui.bookmark then
        local bk = ui.bookmark
        if type(bk.removeBookmark) == "function" then
            pcall(function() bk:removeBookmark(p); removed = true end)
        end
        if not removed and type(bk.getBookmarkIndex) == "function" then
            local ok, idx = pcall(function() return bk:getBookmarkIndex(p) end)
            if ok and idx then
                if type(bk.removeItemByIndex) == "function" then
                    pcall(function() bk:removeItemByIndex(idx); removed = true end)
                elseif type(bk.removeBookmarkByIndex) == "function" then
                    pcall(function() bk:removeBookmarkByIndex(idx); removed = true end)
                end
            end
        end
    end

    -- 2. Limpieza en la lista unificada de anotaciones
    if ui.annotation and type(ui.annotation.annotations) == "table" then
        local anns = ui.annotation.annotations
        for i = #anns, 1, -1 do
            local item = anns[i]
            local item_p = self:_getNumericalPage(item)
            if item_p and math.floor(item_p) == p then
                local is_bm = (item.bookmark == true) or (item.type == "bookmark") or (not item.drawer and not item.highlight and not item.note)
                if is_bm then
                    table.remove(anns, i)
                    removed = true
                end
            end
        end
        if removed and type(ui.annotation.saveAnnotations) == "function" then
            pcall(function() ui.annotation:saveAnnotations() end)
        end
    end

    -- 3. Limpieza en tablas secundarias de bookmarks
    if ui.bookmark then
        local bk = ui.bookmark
        local lists = { bk.bookmarks, bk._bookmarks }
        for _, list in ipairs(lists) do
            if type(list) == "table" then
                for i = #list, 1, -1 do
                    local item = list[i]
                    local item_p = self:_getNumericalPage(item) or tonumber(item)
                    if item_p and math.floor(item_p) == p then
                        table.remove(list, i)
                        removed = true
                    end
                end
            end
        end
        if type(bk.saveBookmarks) == "function" then
            pcall(function() bk:saveBookmarks() end)
        elseif type(bk.onSaveSettings) == "function" then
            pcall(function() bk:onSaveSettings() end)
        end
    end

    -- 4. Limpieza en las propiedades del documento y doc_settings
    if ui.doc_props and type(ui.doc_props.bookmarks) == "table" then
        local dp_bms = ui.doc_props.bookmarks
        for i = #dp_bms, 1, -1 do
            local item = dp_bms[i]
            local item_p = self:_getNumericalPage(item) or tonumber(item)
            if item_p and math.floor(item_p) == p then
                table.remove(dp_bms, i)
                removed = true
            end
        end
    end

    if ui.doc_settings and type(ui.doc_settings.readSetting) == "function" then
        local set_bms = ui.doc_settings:readSetting("bookmarks")
        if type(set_bms) == "table" then
            local mod = false
            for i = #set_bms, 1, -1 do
                local item = set_bms[i]
                local item_p = self:_getNumericalPage(item) or tonumber(item)
                if item_p and math.floor(item_p) == p then
                    table.remove(set_bms, i)
                    mod = true
                    removed = true
                end
            end
            if mod and type(ui.doc_settings.saveSetting) == "function" then
                pcall(function()
                    ui.doc_settings:saveSetting("bookmarks", set_bms)
                    if ui.doc_settings.flush then ui.doc_settings:flush() end
                end)
            end
        end
    end

    return removed
end

function PageScrubber:_safeBookmarkToggle(target_page)
    if self._closing or self._toggling_bm then return end
    self._toggling_bm = true

    self:_waitForIdle(function()
        if self._closing then
            self._toggling_bm = false
            return
        end

        local p = tonumber(target_page) or self._cur_page
        local origin_view_page = self._cur_page
        self:_invalidateGridTilesForPage(p)

        -- Resincronizamos crengine obligatoriamente con la página a marcar:
        if self.ui.view and self.ui.view.state then
            self.ui.view.state.page = -1
        end
        pcall(function() self.ui:handleEvent(Event:new("GotoPage", p)) end)

        UIManager:scheduleIn(0.25, function()
            if self._closing then
                self._toggling_bm = false
                return
            end

            -- Disparamos el evento nativo de KOReader que guarda y actualiza el marcador real
            pcall(function() self.ui:handleEvent(Event:new("ToggleBookmark")) end)

            UIManager:scheduleIn(0.25, function()
                if self._closing then
                    self._toggling_bm = false
                    return
                end
                -- Si se desmarcó/marcó una página remota, devolvemos crengine a la página en vista
                if origin_view_page and origin_view_page ~= p then
                    if self.ui.view and self.ui.view.state then
                        self.ui.view.state.page = -1
                    end
                    pcall(function() self.ui:handleEvent(Event:new("GotoPage", origin_view_page)) end)
                end
                self:_invalidateBookmarksCache()
                self:_updateGridPages()
                self._toggling_bm = false
                UIManager:setDirty(self, "ui", self.dimen)
            end)
        end)
    end)
end

function PageScrubber:_getChapter(page)
    if self.ui.toc then
        local t = self.ui.toc:getTocTitleByPage(page)
        if t and t ~= "" then return t end
    end
    return _("—")
end

function PageScrubber:_isCurrentPageBookmarked(check_page)
    local target = check_page or self._cur_page
    local bms = self:_getAllBookmarks()
    for _, p in ipairs(bms) do
        if tonumber(p) == tonumber(target) then return true end
    end
    local actual_bg_page = (self.ui.view and self.ui.view.state and self.ui.view.state.page) or self._origin_page
    if target == actual_bg_page then
        if self.ui.view and self.ui.view.dogear_visible then return true end
    end
    return false
end

function PageScrubber:_findPrevBookmark()
    local bms = self:_getAllBookmarks()
    local target = nil
    for _, p in ipairs(bms) do
        local num = tonumber(p)
        if num and num < self._cur_page then
            if not target or num > target then target = num end
        end
    end
    return target
end

function PageScrubber:_findNextBookmark()
    local bms = self:_getAllBookmarks()
    local target = nil
    for _, p in ipairs(bms) do
        local num = tonumber(p)
        if num and num > self._cur_page then
            if not target or num < target then target = num end
        end
    end
    return target
end

function PageScrubber:_getDisplayPageInfo(raw_page)
    local fallback_p = tostring(raw_page)
    local ui = self.ui
    if not ui then return fallback_p, self._total_pages end

    local pagemap = ui.pagemap
    local doc = ui.document

    -- Detectar si el documento posee páginas estables (activadas o nativas)
    local has_labels = false
    if pagemap then
        if type(pagemap.wantsPageLabels) == "function" and pagemap:wantsPageLabels() then
            has_labels = true
        elseif type(pagemap.hasPageLabels) == "function" and pagemap:hasPageLabels() then
            has_labels = true
        end
    end

    if not has_labels then
        return fallback_p, self._total_pages
    end

    -- 1. Total de páginas según la última etiqueta física del libro (ej: 879 en vez de 905)
    if not self._stable_total then
        if pagemap and type(pagemap.getLastPageLabel) == "function" then
            local ok, l = pcall(pagemap.getLastPageLabel, pagemap, true)
            if ok and l and l ~= "" then self._stable_total = tostring(l) end
        end
        if not self._stable_total and pagemap and type(pagemap.getPageLabelProps) == "function" then
            local ok, last_idx = pcall(pagemap.getPageLabelProps, pagemap)
            if ok and last_idx and tonumber(last_idx) then
                self._stable_total = tostring(last_idx)
            end
        end
    end
    local disp_total = self._stable_total or tostring(self._total_pages)

    -- 2. Caché en memoria para respuesta en 0 ms
    if not self._page_label_cache then
        self._page_label_cache = {}
    end
    if self._page_label_cache[raw_page] then
        return self._page_label_cache[raw_page], disp_total
    end

    local resolved_label = nil

    -- 3. Método nativo para EPUB (resolución real vía XPointer con anticipación en pantalla actual)
    if doc and type(doc.getPageXPointer) == "function" and pagemap and type(pagemap.getXPointerPageLabel) == "function" then
        -- Etiqueta al tope de la pantalla
        local ok_xp, xp = pcall(doc.getPageXPointer, doc, raw_page)
        if ok_xp and xp then
            local ok_lbl, lbl = pcall(pagemap.getXPointerPageLabel, pagemap, xp, true)
            if ok_lbl and lbl and lbl ~= "" then
                resolved_label = lbl
            end
        end

        -- Detección de salto a mitad de pantalla: consultar el límite con la siguiente
        local cand_lbl = nil
        local ok_next_xp, next_xp = pcall(doc.getPageXPointer, doc, raw_page + 1)
        if ok_next_xp and next_xp then
            local ok_cand, clbl = pcall(pagemap.getXPointerPageLabel, pagemap, next_xp, true)
            if ok_cand and clbl and clbl ~= "" then
                cand_lbl = clbl
            end
        elseif pagemap and type(pagemap.getLastPageLabel) == "function" then
            local ok_last, llbl = pcall(pagemap.getLastPageLabel, pagemap, true)
            if ok_last and llbl and llbl ~= "" then
                cand_lbl = llbl
            end
        end

        -- Si la etiqueta cambió antes de la página siguiente, verificar si nació en esta misma pantalla
        if cand_lbl and cand_lbl ~= resolved_label and type(pagemap.getPageLabelProps) == "function" then
            local ok_props, idx, label_pn = pcall(pagemap.getPageLabelProps, pagemap, cand_lbl)
            if ok_props and label_pn and label_pn == raw_page then
                resolved_label = cand_lbl
            end
        end
    end

    -- 4. Método nativo para PDF / formatos fijos (doc:getPageLabel)
    if not resolved_label and doc and type(doc.getPageLabel) == "function" then
        local ok, lbl = pcall(doc.getPageLabel, doc, raw_page)
        if ok and lbl and lbl ~= "" then
            resolved_label = lbl
        end
    end

    -- 5. Fallback directo al pagemap
    if not resolved_label and pagemap and type(pagemap.getPageLabel) == "function" then
        local ok, lbl = pcall(pagemap.getPageLabel, pagemap, raw_page, true)
        if ok and lbl and lbl ~= "" then
            resolved_label = lbl
        end
    end

    -- 6. Limpieza de caracteres invisibles y guardado en memoria
    if resolved_label then
        if pagemap and type(pagemap.cleanPageLabel) == "function" then
            local ok_clean, cleaned = pcall(pagemap.cleanPageLabel, pagemap, resolved_label)
            if ok_clean and cleaned and cleaned ~= "" then
                resolved_label = cleaned
            end
        end
        local res = tostring(resolved_label)
        self._page_label_cache[raw_page] = res
        return res, disp_total
    end

    self._page_label_cache[raw_page] = fallback_p
    return fallback_p, disp_total
end

function PageScrubber:_updateTexts()
    local disp_page, disp_total = self:_getDisplayPageInfo(self._cur_page)
    local num_p = tonumber(disp_page) or self._cur_page
    local num_tot = tonumber(disp_total) or self._total_pages
    local pct = math.floor(num_p / math.max(1, num_tot) * 100)

    self.tw_chapter:setText(self:_getChapter(self._cur_page))
    
    if self._view_mode == "grid_six" then
        local g6_count, g6_origin = self:_g6Count(), self:_g6Origin()
        local start_raw = math.max(1, self._cur_page - (g6_origin - 1))
        local end_raw = math.min(self._cur_page + (g6_count - g6_origin), self._total_pages)
        
        local disp_start = self:_getDisplayPageInfo(start_raw)
        local disp_end = self:_getDisplayPageInfo(end_raw)
        
        self.tw_info:setText(_("Pages") .. " " .. disp_start .. " - " .. disp_end)
    else
        self.tw_info:setText(pct .. "%  ·  " .. disp_page .. " / " .. disp_total)
    end
end

-- Multi Grid: cantidad de páginas en pantalla (6 ó 9) y slot donde va la página actual (2 ó 5).
-- Aplica tanto en vertical como en horizontal.
function PageScrubber:_g6Count()
    if G_reader_settings and G_reader_settings:readSetting("page_scrubber_multigrid_nine") == true then
        return 9
    end
    return 6
end

function PageScrubber:_g6Origin()
    return (self:_g6Count() == 9) and 5 or 2
end

function PageScrubber:_gridSlotDimen(idx)
    local gd, m = self._grid_dimen, self._grid_margin
    local w, h  = self._grid_item_w, self._grid_item_h
    local mid_x = gd.x + math.floor((gd.w - w) / 2)
    local y     = gd.y + math.floor((gd.h - h) / 2)
    local offsets = { -(w + m), 0, (w + m) }
    return Geom:new{ x = mid_x + offsets[idx], y = y, w = w, h = h }
end

function PageScrubber:_updateGridPages()
    if self._grid_disabled or self._closing then return end
    self._pending_grid_update = false
    -- Una navegacion nueva invalida cualquier precarga que estuviera esperando su turno.
    self._preload_token = (self._preload_token or 0) + 1
    self._gate_pending = {}
    self._details_prefetch_t = {}   -- las precargas del panel de bookmark tambien se cancelan: hay que poder pedirlas de nuevo
    local thumbnail = self.ui.thumbnail
    local S = self.S
    local sw, sh = Screen:getWidth(), Screen:getHeight()

    local is_landscape = sw > sh
    if is_landscape and (self._view_mode == "grid" or self._view_mode == "grid_six") then
        self._grid_dimen.y = self._top_bar_dimen.y + self._top_bar_dimen.h + S(8)
        self._grid_dimen.h = self._bar_dimen.y - self._grid_dimen.y - S(8)
        if self._view_mode == "grid" then
            local ok, GridLandscapeView = pcall(require, "grid_landscape_view")
            if ok and GridLandscapeView and GridLandscapeView.getThumbDims then
                self._grid_item_w, self._grid_item_h = GridLandscapeView.getThumbDims(self)
                self._thumb_req_w = self._grid_item_w
                self._thumb_req_h = self._grid_item_h
            end
        end
    elseif self._view_mode == "grid_six" then
        -- Con 9 páginas se reduce el margen vertical para ganar altura
        local g6_vpad = (self:_g6Count() == 9) and S(6) or S(26)
        self._grid_dimen.y = self._top_bar_dimen.y + self._top_bar_dimen.h + g6_vpad
        self._grid_dimen.h = self._bar_dimen.y - self._grid_dimen.y - g6_vpad
    elseif self._view_mode == "grid_simple" then
        self._grid_dimen.y = 0
        self._grid_dimen.h = self._bar_dimen.y
    else
        self._grid_dimen.y = self._booktitle_y + self.tw_booktitle:getSize().h + S(8)
        self._grid_dimen.h = self._bar_dimen.y - self._grid_dimen.y
    end

    if self._view_mode == "split" then
        local is_landscape = sw > sh
        if is_landscape then
            local ok, SplitLandscapeView = pcall(require, "split_landscape_view")
            if ok and SplitLandscapeView and SplitLandscapeView.getThumbDims then
                self._thumb_req_split_w, self._thumb_req_split_h = SplitLandscapeView.getThumbDims(self)
            end
        else
            local available_h = self._grid_dimen.h
            local status_h = S(32)
            local fx_h = S(56)
            local gap_x = S(28)
            
            local max_pr_w_allowed = math.max(S(50), math.floor((sw - S(40) - gap_x) * 0.65))
            local target_pr_w = max_pr_w_allowed
            local target_pr_h = math.floor(target_pr_w * (sh / sw))
            
            local max_left_h_allowed = math.max(S(150), available_h - S(30))
            
            if target_pr_h + status_h > max_left_h_allowed then
                target_pr_h = max_left_h_allowed - status_h
                target_pr_w = math.floor(target_pr_h * (sw / sh))
            end
            
            local left_total_h = target_pr_h + status_h
            local available_menu_h = left_total_h - S(12) - fx_h
            
            if available_menu_h < S(80) then
                left_total_h = S(80) + S(12) + fx_h
                if left_total_h > max_left_h_allowed then
                    left_total_h = max_left_h_allowed
                end
                target_pr_h = left_total_h - status_h
                target_pr_w = math.floor(target_pr_h * (sw / sh))
            end
            
            self._thumb_req_split_w = math.max(S(30), target_pr_w)
            self._thumb_req_split_h = math.max(S(30), target_pr_h)
        end

    elseif self._view_mode == "grid_simple" then
        if sw > sh then
            local ok, GSView = pcall(require, "grid_simple_landscape_view")
            if ok and GSView and GSView.getThumbDims then
                self._thumb_req_split_w, self._thumb_req_split_h = GSView.getThumbDims(self)
            end
        else
            local available_y = self._bar_dimen.y
            local max_p_w = math.floor(sw * 0.72)
            local max_p_h = math.floor(available_y * 0.78)

            local th = max_p_h
            local tw = math.floor(th * (sw / sh))
            if tw > max_p_w then
                tw = max_p_w
                th = math.floor(tw * (sh / sw))
            end

            self._thumb_req_split_w = tw
            self._thumb_req_split_h = th
        end
    elseif self._view_mode == "grid_six" then
        local mod_req = (sw > sh) and "grid_six_landscape_view" or "grid_six_view"
        local ok, GridSixMod = pcall(require, mod_req)
        if ok and GridSixMod and GridSixMod.getSlotDimens then
            local slots = GridSixMod.getSlotDimens(self)
            if slots and slots[1] then
                self._thumb_req_split_w = slots[1].w
                self._thumb_req_split_h = slots[1].h
            end
        end
    end

    self._grid_batch_seq = (self._grid_batch_seq or 0) + 1
    local current_seq = self._grid_batch_seq
    local batch_id = "page_scrubber_grid_" .. self._grid_instance_id .. "_" .. tostring(current_seq)
    self._grid_batch_id = batch_id

    -- Cancelación nativa de lotes de secuencias anteriores
    if thumbnail and thumbnail.cancelPageThumbnailRequests and type(thumbnail.thumbnails_requests) == "table" then
        for b_id in pairs(thumbnail.thumbnails_requests) do
            if type(b_id) == "string" and (
                    (b_id:find("^page_scrubber_grid_") and not b_id:find("_" .. tostring(current_seq) .. "_"))
                    -- Las precargas viejas ya no sirven y, si quedan en cola, la pagina que SI se
                    -- necesita espera detras de ellas (era la causa del "tildado" al tapear rapido).
                    or b_id:find("^page_scrubber_preload_")) then
                thumbnail:cancelPageThumbnailRequests(b_id)
            end
        end
    end

    self._grid_tiles = {}
    local missing = {}

    local expected_req_w = (self._view_mode == "grid") and self._grid_item_w or self._thumb_req_split_w
    local expected_req_h = (self._view_mode == "grid") and self._grid_item_h or self._thumb_req_split_h

    local function resolveSlot(idx, page, mode)
        local valid = page and page >= 1 and page <= self._total_pages
        local slot = { page = valid and page or nil, loading = valid, is_scaled = false, mode = mode }
        if valid then
            local cached = self._tile_cache[page]
            if cached and cached.bb and cached.w == expected_req_w and cached.h == expected_req_h then
                slot.tile_bb = cached.bb
                slot.is_scaled = cached.is_scaled
                slot.loading = false
                cached.last_used = os.clock()
            end
        end
        self._grid_tiles[idx] = slot
        if valid and not slot.tile_bb then
            missing[#missing + 1] = idx
        end
    end

    if self._view_mode == "grid" then
        local nb_items = self._grid_cols * self._grid_rows
        for idx = 1, nb_items do
            local offset_p = idx - 2
            if self.is_rtl then offset_p = -offset_p end
            resolveSlot(idx, self._cur_page + offset_p, "grid")
        end
    elseif self._view_mode == "grid_six" then
        local g6_origin = self:_g6Origin()
        for idx = 1, self:_g6Count() do
            resolveSlot(idx, self._cur_page + (idx - g6_origin), "grid_six")
        end
    else
        resolveSlot(2, self._cur_page, self._view_mode)
    end

    -- Si todas las miniaturas necesarias están en memoria, refrescar pantalla en un único ciclo
    local center_missing = nil
    local side_missing = {}

    if self._view_mode == "grid" then
        if self._grid_tiles[2] and self._grid_tiles[2].page and not self._grid_tiles[2].tile_bb then
            center_missing = 2
        end
        local side_order = self.is_rtl and { 1, 3 } or { 3, 1 }
        for _, idx in ipairs(side_order) do
            local slot = self._grid_tiles[idx]
            if slot and slot.page and not slot.tile_bb then
                table.insert(side_missing, idx)
            end
        end
    elseif self._view_mode == "grid_six" then
        local g6_origin, g6_count = self:_g6Origin(), self:_g6Count()
        if self._grid_tiles[g6_origin] and self._grid_tiles[g6_origin].page and not self._grid_tiles[g6_origin].tile_bb then
            center_missing = g6_origin
        end
        -- Orden de carga: vecina derecha, vecina izquierda y luego el resto
        local g6_order = { g6_origin + 1, g6_origin - 1 }
        for i = 1, g6_count do
            if i ~= g6_origin and i ~= g6_origin + 1 and i ~= g6_origin - 1 then
                g6_order[#g6_order + 1] = i
            end
        end
        for _, idx in ipairs(g6_order) do
            local slot = self._grid_tiles[idx]
            if slot and slot.page and not slot.tile_bb then
                table.insert(side_missing, idx)
            end
        end
    else
        if self._grid_tiles[2] and self._grid_tiles[2].page and not self._grid_tiles[2].tile_bb then
            center_missing = 2
        end
    end

    local total_missing = (center_missing and 1 or 0) + #side_missing

    -- En cualquier caso, plasmamos el estado actual (nueva selección de lista y página cargada/cargando)
    if self._view_mode == "split" then
        UIManager:setDirty(self, "ui", self.dimen)
    elseif self._view_mode == "grid_simple" then
        local r = self._gs_panel_dimen or self._grid_dimen
        if r then
            local pad = S(6)
            local safe_r = Geom:new{
                x = math.max(0, r.x - pad),
                y = math.max(0, r.y - pad),
                w = math.min(sw - math.max(0, r.x - pad), r.w + pad * 2),
                h = math.min(sh - math.max(0, r.y - pad), r.h + pad * 2 + S(6)),
            }
            UIManager:setDirty(self, "ui", safe_r)
        else
            UIManager:setDirty(self, "ui", self.dimen)
        end
    else
        UIManager:setDirty(self, "ui", self._grid_dimen)
    end

    if total_missing == 0 then
        self._is_busy = false
        self._tasks_in_flight = 0
        self:_preloadNeighborPages()
        if self._pending_grid_update and not self._closing then
            self._pending_grid_update = false
            self:_updateGridPages()
        end
        return
    end

    self._is_busy = true
    self._tasks_in_flight = total_missing

    local function checkFinished()
        if self._tasks_in_flight <= 0 then
            self._is_busy = false
            self:_preloadNeighborPages()
            if self._pending_grid_update and not self._closing then
                self._pending_grid_update = false
                self:_updateGridPages()
            end
        end
    end

    local function refreshSlotIndividually(slot_idx)
        if self._closing or self._grid_batch_seq ~= current_seq then return end
        local r = nil
        if self._view_mode == "grid" and self._gridSlotDimen then
            local slot_d = self:_gridSlotDimen(slot_idx)
            if slot_d then
                local pad_b = self.S(4)
                r = Geom:new{ x = slot_d.x - pad_b, y = slot_d.y - pad_b, w = slot_d.w + pad_b * 2, h = slot_d.h + pad_b * 2 }
            end
        elseif self._view_mode == "grid_six" then
            local mod_req = (sw > sh) and "grid_six_landscape_view" or "grid_six_view"
            local ok_m, G6Mod = pcall(require, mod_req)
            if ok_m and G6Mod and G6Mod.getSlotDimens then
                local slots = G6Mod.getSlotDimens(self)
                if slots and slots[slot_idx] then
                    local slot_d = slots[slot_idx]
                    local pad_b = self.S(4)
                    r = Geom:new{ x = slot_d.x - pad_b, y = slot_d.y - pad_b, w = slot_d.w + pad_b * 2, h = slot_d.h + pad_b * 2 }
                end
            end
        elseif self._view_mode == "grid_simple" then
            local p_dim = self._gs_panel_dimen or self._grid_dimen
            if p_dim then
                local pad = self.S(6)
                r = Geom:new{
                    x = math.max(0, p_dim.x - pad),
                    y = math.max(0, p_dim.y - pad),
                    w = math.min(sw - math.max(0, p_dim.x - pad), p_dim.w + pad * 2),
                    h = math.min(sh - math.max(0, p_dim.y - pad), p_dim.h + pad * 2 + self.S(6)),
                }
            end
        elseif self._view_mode == "split" then
            r = self._grid_dimen
        end
        if r then
            UIManager:setDirty(self, "ui", r)
        else
            UIManager:setDirty(self, "ui", self._grid_dimen)
        end
    end

    local function requestSlot(idx, req_batch_id, on_complete)
        local slot = self._grid_tiles[idx]
        if not slot or not slot.page then
            self._tasks_in_flight = self._tasks_in_flight - 1
            checkFinished()
            if on_complete then on_complete() end
            return
        end

        local req_page = slot.page
        local timed_out = false

        UIManager:scheduleIn(6.9, function()
            if self._closing or timed_out or self._grid_batch_seq ~= current_seq then return end
            timed_out = true
            if slot.loading then
                slot.loading = false
                slot.error = true
                self._failed_pages = self._failed_pages or {}
                self._failed_pages[req_page] = true
                refreshSlotIndividually(idx)
                self._tasks_in_flight = self._tasks_in_flight - 1
                checkFinished()
                if on_complete then on_complete() end
            end
        end)

        thumbnail:getPageThumbnail(req_page, expected_req_w, expected_req_h, req_batch_id,
            function(tile, resp_batch_id)
                if self._closing or timed_out or self._grid_batch_seq ~= current_seq then return end
                timed_out = true

                local processed = processTile(tile, expected_req_w, expected_req_h)
                if processed and processed.bb and self._grid_tiles[idx] then
                    self._grid_tiles[idx].tile_bb = processed.bb
                    self._grid_tiles[idx].is_scaled = processed.is_scaled
                    self._grid_tiles[idx].loading = false
                    self._grid_tiles[idx].error = nil
                    self:_cacheTile(req_page, processed.bb, processed.is_scaled, expected_req_w, expected_req_h)
                elseif self._grid_tiles[idx] then
                    self._grid_tiles[idx].loading = false
                    self._grid_tiles[idx].error = true
                    self._failed_pages = self._failed_pages or {}
                    self._failed_pages[req_page] = true
                end

                refreshSlotIndividually(idx)
                self._tasks_in_flight = self._tasks_in_flight - 1
                checkFinished()
                if on_complete then on_complete() end
            end
        )
    end

    local function requestSideSlots()
        if self._closing or self._grid_batch_seq ~= current_seq then return end
        for _, idx in ipairs(side_missing) do
            requestSlot(idx, batch_id .. "_s")
        end
    end

    -- 1. Si falta el centro, se pide con exclusividad y espera a que termine para pedir los costados
    if center_missing then
        requestSlot(center_missing, batch_id .. "_c", function()
            if #side_missing > 0 then
                requestSideSlots()
            end
        end)
    else
        -- 2. Si el centro ya estaba en caché, despacha los costados de inmediato
        if #side_missing > 0 then
            requestSideSlots()
        end
    end
end

function PageScrubber:_waitForIdle(callback)
    if not self._is_busy and (self._tasks_in_flight or 0) == 0 then
        callback()
        return
    end
    UIManager:scheduleIn(0.05, function() self:_waitForIdle(callback) end)
end

function PageScrubber:_invalidateGridTilesForPage(page)
    if self._tile_cache then
        self._tile_cache[page] = nil
    end
    for idx, slot in pairs(self._grid_tiles) do
        if slot.page == page then
            self:_freeTile(slot)
            slot.loading = true
            slot.error = nil
        end
    end
end

function PageScrubber:_clearGridTiles(force_all)
    for idx, slot in pairs(self._grid_tiles) do
        -- Solo conservamos si no es forzado y si la miniatura ya pertenecía a esta misma vista
        if force_all or slot.page ~= self._cur_page or slot.mode ~= self._view_mode then
            self:_freeTile(slot)
            slot.loading = true
            slot.error = nil
        end
    end
end

function PageScrubber:_nudgeDecoder(page)
    if self._closing or not self._is_comic then return end
    local thumbnail = self.ui.thumbnail
    if not thumbnail or not thumbnail.getPageThumbnail then return end

    local neighbor = page + 3
    if neighbor > self._total_pages then neighbor = page - 3 end
    if neighbor < 1 or neighbor > self._total_pages or neighbor == page then return end

    pcall(function()
        thumbnail:getPageThumbnail(neighbor, self._thumb_req_w, self._thumb_req_h,
            "page_scrubber_nudge_" .. tostring(neighbor), function() end)
    end)
end

function PageScrubber:_forceRefreshCurrentTile()
    if self._grid_disabled or self._closing then return end
    local page = self._cur_page

    self._grid_flash_idx = 2
    UIManager:setDirty(self, "ui", self:_gridSlotDimen(2))

    UIManager:scheduleIn(0.12, function()
        if self._closing then return end
        self._grid_flash_idx = nil

        self:_nudgeDecoder(page)
        self:_invalidateGridTilesForPage(page)

        self._thumb_req_w = (self._thumb_req_w == self._grid_item_w)
                            and (self._grid_item_w + 1) or self._grid_item_w

        UIManager:setDirty(self, "ui", self._grid_dimen)
        self:_updateGridPages()
    end)
end

function PageScrubber:_paintGrid(bb)
    local nb_items = self._grid_cols * self._grid_rows
    local all_bms = self:_getAllBookmarks()
    self._center_bm_touch_dimen = nil

    local sw, sh = Screen:getWidth(), Screen:getHeight()

    local file_ext = (self.ui and self.ui.document and self.ui.document.file and self.ui.document.file:match("%.([%a%d]+)$")) or ""
    file_ext = file_ext:lower()
    local is_fixed_page = self._is_comic or self.is_rtl or (file_ext == "pdf")

    for idx = 1, nb_items do
        local slot = self._grid_tiles[idx]
        local rect = self:_gridSlotDimen(idx)
        local is_cur = (idx == 2)
        local border = self.S(1)   -- la pagina del medio con el mismo grosor que las de los costados

        if slot and slot.page then
            if slot.tile_bb and slot.mode == "grid" then
                local tw, th = slot.tile_bb:getWidth(), slot.tile_bb:getHeight()
                local src_x, src_y = 0, 0
                local blit_w, blit_h = tw, th
                
                if blit_w > rect.w then
                    src_x = math.floor((blit_w - rect.w) / 2)
                    blit_w = rect.w
                end
                if blit_h > rect.h then
                    src_y = math.floor((blit_h - rect.h) / 2)
                    blit_h = rect.h
                end

                local ox = rect.x + math.floor((rect.w - blit_w) / 2)
                local oy = rect.y + math.floor((rect.h - blit_h) / 2)
                
                if ox < 0 then src_x = src_x - ox; blit_w = blit_w + ox; ox = 0 end
                if oy < 0 then src_y = src_y - oy; blit_h = blit_h + oy; oy = 0 end
                if ox + blit_w > sw then blit_w = sw - ox end
                if oy + blit_h > sh then blit_h = sh - oy end

                local box_x = rect.x
                local box_y = is_fixed_page and oy or rect.y
                local box_w = rect.w
                local box_h = is_fixed_page and blit_h or rect.h

                bb:paintRect(box_x, box_y, box_w, box_h, Blitbuffer.COLOR_WHITE)

                if blit_w > 0 and blit_h > 0 then
                    local ok_blit = pcall(function()
                        bb:blitFrom(slot.tile_bb, ox, oy, src_x, src_y, blit_w, blit_h)
                    end)
                    if not ok_blit then
                        slot.tile_bb = nil
                        slot.error = true
                    end
                end

                if self._grid_flash_idx == idx then
                    bb:paintRect(box_x, box_y, box_w, box_h, Blitbuffer.COLOR_BLACK)
                end

                local is_bmed = self._cached_bms_map and self._cached_bms_map[tonumber(slot.page)]

                if is_cur then
                    local bw, bh = self.S(28), self.S(46)
                    local bx = box_x + box_w - bw - self.S(16) - border
                    local by = box_y + border
                    self._center_bm_touch_dimen = Geom:new{ x = bx - self.S(10), y = by, w = bw + self.S(20), h = bh + self.S(20) }
                end

                if is_bmed then
                    local bw, bh = self.S(28), self.S(46)
                    local bx = box_x + box_w - bw - self.S(16) - border
                    local by = box_y + border

                    local mask_x = bx - self.S(2)
                    local mask_y = by
                    local mask_w = (box_x + box_w - border) - mask_x
                    local mask_h = self.S(26)

                    bb:paintRect(mask_x, mask_y, mask_w, mask_h, Blitbuffer.COLOR_WHITE)
                    drawBookmarkRibbon(bb, bx, by, bw, bh, Blitbuffer.COLOR_BLACK)
                end

                -- Puntito gris indicador en la esquina superior izquierda de la página de origen
                if tonumber(slot.page) == tonumber(self._origin_page) then
                    local dot_sz = self.S(8)
                    local dot_off = self.S(8)
                    local dx = box_x + dot_off + border
                    local dy = box_y + dot_off + border
                    paintRoundRect(bb, dx, dy, dot_sz, dot_sz, math.floor(dot_sz / 2), Blitbuffer.COLOR_DARK_GRAY)
                end

                bb:paintBorder(box_x, box_y, box_w, box_h, border, Blitbuffer.COLOR_BLACK, 0)

            elseif slot.error then
                if not is_fixed_page then
                    bb:paintRect(rect.x, rect.y, rect.w, rect.h, Blitbuffer.COLOR_WHITE)
                    bb:paintBorder(rect.x, rect.y, rect.w, rect.h, border, Blitbuffer.COLOR_BLACK, 0)
                end
                if not self._tw_grid_error then
                    self._tw_grid_error = TextWidget:new{
                        text = "!", face = Font:getFace("cfont", self.S(32)),
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    }
                end
                local etsz = self._tw_grid_error:getSize()
                self._tw_grid_error:paintTo(bb, rect.x + math.floor((rect.w - etsz.w) / 2),
                    rect.y + math.floor((rect.h - etsz.h) / 2))
            elseif slot.loading then
                if not is_fixed_page then
                    bb:paintRect(rect.x, rect.y, rect.w, rect.h, Blitbuffer.COLOR_WHITE)
                    bb:paintRect(rect.x + math.floor(rect.w / 2) - 1, rect.y + math.floor(rect.h / 2) - 1,
                        2, 2, Blitbuffer.COLOR_GRAY)
                    bb:paintBorder(rect.x, rect.y, rect.w, rect.h, border, Blitbuffer.COLOR_BLACK, 0)
                end
            end
        end
    end
end

-- ============================================================================
-- PANEL DE DETALLES DE LA ANOTACION
-- Ventana que cubre toda la polaroid del split menu (pagina + linea de texto) y muestra
-- fecha, capitulo/pagina, tipo/color, cita y nota de la anotacion seleccionada.
-- El contenido sale SIEMPRE de la anotacion seleccionada en la lista de la derecha, asi que
-- las flechas del panel, los taps en la lista y los botones de edicion quedan sincronizados.
-- ============================================================================
local DETAILS_MONTHS = nil  -- se arma una sola vez (los nombres pasan por el traductor)

local function paintTriangle(bb, x, y, w, h, pointing_left, color)
    for c = 0, w - 1 do
        local frac = pointing_left and ((c + 1) / w) or ((w - c) / w)
        local hc = math.max(1, math.floor(h * frac + 0.5))
        bb:paintRect(x + c, y + math.floor((h - hc) / 2), 1, hc, color)
    end
end

local function paintCross(bb, x, y, size, thick, color)
    for i = 0, size - 1 do
        bb:paintRect(x + i, y + i, thick, thick, color)
        bb:paintRect(x + size - 1 - i, y + i, thick, thick, color)
    end
end

-- Cara italica de la fuente de la interfaz (si existe); si no, la normal
local function italic_face(size)
    local cands = {}
    local base = Font.fontmap and Font.fontmap["cfont"]
    if type(base) == "string" then
        local c = base:gsub("Regular", "Italic")
        if c ~= base then cands[#cands + 1] = c end
    end
    cands[#cands + 1] = "NotoSerif-Italic.ttf"
    cands[#cands + 1] = "NotoSans-Italic.ttf"
    for _, name in ipairs(cands) do
        local ok, face = pcall(function() return Font:getFace(name, size) end)
        if ok and face then return face end
    end
    return Font:getFace("cfont", size)
end

-- Rectangulo de color real (RGB32) cuando la pantalla lo soporta
local function paint_color_rect(bb, x, y, w, h, color)
    if w <= 0 or h <= 0 then return end
    if bb.blendRectRGB32 then bb:blendRectRGB32(x, y, w, h, color)
    elseif bb.paintRectRGB32 then bb:paintRectRGB32(x, y, w, h, color)
    else bb:paintRect(x, y, w, h, color) end
end

-- Corte de lineas por palabras; measure(str) devuelve el ancho en pixeles
local function wrap_text(measure, text, max_w)
    local lines = {}
    for para in (text .. "\n"):gmatch("(.-)\n") do
        if para == "" then
            lines[#lines + 1] = ""
        else
            local cur = ""
            for word in para:gmatch("%S+") do
                local cand = (cur == "") and word or (cur .. " " .. word)
                if measure(cand) <= max_w then
                    cur = cand
                else
                    if cur ~= "" then lines[#lines + 1] = cur; cur = "" end
                    if measure(word) <= max_w then
                        cur = word
                    else
                        -- palabra mas ancha que la columna: se parte por caracteres
                        local piece = ""
                        for ch in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                            if piece == "" or measure(piece .. ch) <= max_w then
                                piece = piece .. ch
                            else
                                lines[#lines + 1] = piece
                                piece = ch
                            end
                        end
                        cur = piece
                    end
                end
            end
            lines[#lines + 1] = cur
        end
    end
    return lines
end

function PageScrubber:_formatDetailsDate(raw)
    if raw == nil or raw == "" then return nil end
    if not DETAILS_MONTHS then
        DETAILS_MONTHS = { _("January"), _("February"), _("March"), _("April"), _("May"), _("June"),
                           _("July"), _("August"), _("September"), _("October"), _("November"), _("December") }
    end
    local y, m, d, hh, mm
    if type(raw) == "number" then
        local t = os.date("*t", raw)
        if t then y, m, d, hh, mm = t.year, t.month, t.day, t.hour, t.min end
    else
        local s = tostring(raw)
        y, m, d = s:match("(%d%d%d%d)[%-%/%.](%d%d)[%-%/%.](%d%d)")
        if not y then
            d, m, y = s:match("(%d%d)[%-%/%.](%d%d)[%-%/%.](%d%d%d%d)")
        end
        hh, mm = s:match("[%sT_](%d%d):(%d%d)")
    end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not (y and m and d and DETAILS_MONTHS[m]) then return tostring(raw) end
    local out = string.format("%s %d, %d", DETAILS_MONTHS[m], d, y)
    if hh and mm then out = out .. string.format(" · %02d:%02d", tonumber(hh), tonumber(mm)) end
    return out
end

-- Lista visible, posicion de la anotacion actual dentro de ella y la anotacion en si.
-- Fecha de un bookmark (busca en las anotaciones/bookmarks de KOReader la pagina indicada)
function PageScrubber:_findBookmarkDate(target_p)
    target_p = tonumber(target_p)
    local possible_sources = {
        self.ui.annotation and self.ui.annotation.annotations,
        self.ui.doc_props and self.ui.doc_props.bookmarks,
        self.ui.bookmark and self.ui.bookmark._bookmarks,
        self.ui.bookmark and self.ui.bookmark.bookmarks,
    }
    for _, src in ipairs(possible_sources) do
        if type(src) == "table" then
            for k, v in pairs(src) do
                if type(v) == "table" then
                    local p = self:_getNumericalPage(v) or tonumber(v.page) or tonumber(v.pos0)
                    if p == target_p then
                        local d = v.datetime or v.time or v.date or v.timestamp
                        if d then return d end
                    end
                else
                    if tonumber(k) == target_p and (type(v) == "string" or type(v) == "number") then return v end
                end
            end
        end
    end
    return nil
end

-- Contexto de un bookmark: lista de TODOS los bookmarks (incluye el de la pildora fija, que la
-- lista activa excluye) y la posicion de la pagina actual dentro de ella.
function PageScrubber:_getBookmarkDetailsContext()
    local cur = tonumber(self._cur_page)
    local list, seen = {}, {}
    for _, bp in ipairs(self:_getAllBookmarks() or {}) do
        local p = tonumber(bp)
        if p and not seen[p] then seen[p] = true; list[#list + 1] = p end
    end
    local is_asc = (self._sort_order == "asc")
    table.sort(list, function(a, b) if is_asc then return a < b else return a > b end end)
    for i, p in ipairs(list) do
        if p == cur then return { items = list, idx = i, n = #list, entry = p, bm = true } end
    end
    return nil
end

-- Tras cambiar de tab / filtro o borrar una anotacion, el panel (si esta abierto) NO se cierra:
-- pasa a mostrar la anotacion de la nueva lista mas cercana a la pagina actual.
function PageScrubber:_scheduleDetailsResync()
    if not self._details_open then return end
    self._details_bm_mode = false
    self._details_resync_pending = true
    UIManager:nextTick(function()
        if self._closing then return end
        self:_syncDetailsAfterListChange()
    end)
end

function PageScrubber:_syncDetailsAfterListChange()
    self._details_resync_pending = false
    if not self._details_open or self._closing then return end
    if self:_getDetailsContext(true) then
        self._force_menu_sync = true
        UIManager:setDirty(self, "ui", self.dimen)
        return
    end
    local items = self:_getFilteredActiveList() or {}
    local cur = tonumber(self._cur_page) or 0
    local best, best_d
    for _, it in ipairs(items) do
        local p = tonumber((type(it) == "table") and it.page or it)
        if p then
            local d = math.abs(p - cur)
            if not best_d or d < best_d then best, best_d = it, d end
        end
    end
    if not best then
        self:_closeDetailsPanel(false)   -- la nueva lista esta vacia: no hay nada que mostrar
        return
    end
    self._split_selected_item = (type(best) == "table") and best or nil
    local page = (type(best) == "table") and best.page or best
    self._hide_action_buttons = true
    self._force_menu_sync = true
    self:_previewPage(page, false)
    UIManager:setDirty(self, "ui", self.dimen)
end

-- Lista visible, posicion de la anotacion actual dentro de ella y la anotacion en si.
-- no_bm = true: solo mira la lista activa (sin el modo/fallback de bookmark).
function PageScrubber:_getDetailsContext(no_bm)
    -- Modo bookmark: se mantiene mientras no se elija otra anotacion en la lista
    if self._details_bm_mode and not no_bm then
        if self._split_selected_item == nil then
            local c = self:_getBookmarkDetailsContext()
            if c then return c end
        end
        self._details_bm_mode = false
    end

    local items = self:_getFilteredActiveList() or {}
    local idx = nil
    local sel = self._split_selected_item
    if sel then
        for i, it in ipairs(items) do
            if it == sel then idx = i; break end
        end
    end
    if not idx then
        for i, it in ipairs(items) do
            local p = (type(it) == "table") and it.page or it
            if tonumber(p) == tonumber(self._cur_page) then idx = i; break end
        end
    end
    if idx then
        return { items = items, idx = idx, n = #items, entry = items[idx] }
    end

    if no_bm then return nil end
    if self._active_tab == "images" then return nil end   -- el fallback de bookmark no aplica a imagenes

    -- Sin anotacion en la lista activa: puede ser un bookmark (p.ej. el de la pildora fija)
    local c = self:_getBookmarkDetailsContext()
    if c then
        self._details_bm_mode = true
        return c
    end
    return nil
end

function PageScrubber:_buildDetailsData(ctx)
    local e = ctx.entry
    local is_tbl = (type(e) == "table")
    local page = is_tbl and tonumber(e.page) or tonumber(e) or self._cur_page
    local a = is_tbl and e.annotation or nil
    local data = {}
    data.is_bookmark = not is_tbl
    data.page = page

    -- Titulo (tipo + color) e icono segun el tipo de anotacion
    if not is_tbl then
        data.title = _("Bookmark")
        data.icon = self.icon_pol_bm
    elseif e.img then
        -- Titulo = capitulo; icono = carpeta de la imagen (favorita / general / basura)
        data.title = self:_getChapter(page)
        data.title_icon = e.is_fav and self.icon_det_img_fav
            or (e.cls == "junk" and self.icon_det_img_junk or self.icon_det_img_gen)
        data.image_entry = e
    elseif a and a.drawer == nil and e.note and e.note ~= "" then
        data.title = _("Note")
        data.icon = self.icon_pol_note
    else
        local type_names = {
            normal = _("Highlight"), invert = _("Invert"),
            underline = _("Underline"), strikethrough = _("Strikethrough"),
        }
        data.title = type_names[e.type] or _("Highlight")
        if e.type ~= "invert" and type(e.color) == "string" and e.color ~= "" then
            local cname = HL_COLOR_NAMES[e.color] or (e.color:sub(1, 1):upper() .. e.color:sub(2))
            data.title = data.title .. " (" .. cname .. ")"
        end
        if e.type == "invert" then data.icon = self.icon_picker_inv
        elseif e.type == "underline" then data.icon = self.icon_picker_ul
        elseif e.type == "strikethrough" then data.icon = self.icon_picker_st
        else data.icon = self.icon_picker_hl or self.icon_pol_hl end
    end

    local raw_date
    if is_tbl then
        raw_date = e.date or (a and (a.datetime or a.time or a.date or a.timestamp))
    else
        raw_date = self:_findBookmarkDate(page)
        if not raw_date then
            local pd = self._page_data and self._page_data[page]
            raw_date = pd and pd.date
        end
    end
    data.date = self:_formatDetailsDate(raw_date)

    local chapter = a and a.chapter
    if type(chapter) ~= "string" or chapter == "" then chapter = self:_getChapter(page) end
    if type(chapter) == "string" and chapter ~= "" and not data.image_entry then data.chapter = chapter end
    local label = self:_getDisplayPageInfo(page)
    data.page_line = _("Page") .. " " .. tostring(label)

    if is_tbl and type(e.text) == "string" and e.text ~= "" then
        data.quote = e.text
        data.quote_type = e.type or "normal"
        data.quote_color = (type(e.color) == "string" and e.color ~= "") and e.color or "yellow"
    end
    if is_tbl and type(e.note) == "string" and e.note ~= "" then
        data.note = e.note
    end
    return data
end

function PageScrubber:_freeDetailsWidgets()
    if self._details_tbw then
        for _, ent in pairs(self._details_tbw) do
            if ent and ent.w then pcall(function() ent.w:free() end) end
        end
    end
    self._details_tbw = nil
    self._details_qcache = nil
    if self._details_img and self._details_img.bb then pcall(function() self._details_img.bb:free() end) end
    self._details_img = nil
    if self._img_zoom_src and self._img_zoom_src.bb then pcall(function() self._img_zoom_src.bb:free() end) end
    self._img_zoom_src, self._img_zoom, self._img_zoom_cur_key = nil, nil, nil
    self._prefetch_keep, self._details_prefetch_t, self._details_step_dir = nil, nil, nil
    self:_freeZoomRender()
    self._zoom_pan_last, self._img_tap_last = nil, nil
    for _, k in ipairs({ "_tw_details_title", "_tw_details_date", "_tw_details_page", "_tw_details_counter",
                   "_tw_details_qline", "_tw_details_qline_inv", "_tw_details_measure", "_tw_details_link" }) do
        local wdg = self[k]
        if wdg then pcall(function() wdg:free() end) end
        self[k] = nil
    end
end

-- Imagen de una pagina (para el panel de un bookmark). La busqueda vive en image_scanner.lua;
-- aca solo se guarda en cache el resultado (y se libera el anterior).
-- Pagina entera (la miniatura que ya esta en la vista previa) reducida para entrar en max_w x max_h.
-- Devuelve una copia propia (el panel la libera al cerrarse); nil si la pagina todavia no cargo.
function PageScrubber:_getPageTileBB(page, max_w, max_h)
    local slot = self._grid_tiles and self._grid_tiles[2]
    if not (slot and slot.page == page and slot.tile_bb) then return nil end
    if max_w < 1 or max_h < 1 then return nil end
    local src = slot.tile_bb
    local sw, sh = src:getWidth(), src:getHeight()
    if sw < 1 or sh < 1 then return nil end
    local scale = math.min(max_w / sw, max_h / sh)
    local nw, nh = math.max(1, math.floor(sw * scale)), math.max(1, math.floor(sh * scale))
    local key = "tile|" .. tostring(page) .. "|" .. nw .. "x" .. nh
    local cached = self._details_img
    if cached and cached.key == key then return cached.bb end

    local ok, bb = pcall(function()
        if nw == sw and nh == sh then return src:copy() end
        return src:scale(nw, nh)
    end)
    if not ok then bb = nil end
    if cached and cached.bb then pcall(function() cached.bb:free() end) end
    self._details_img = { key = key, bb = bb }
    return bb
end

function PageScrubber:_getPageImageBB(page, max_w, max_h)
    local key = tostring(page) .. "|" .. tostring(max_w) .. "x" .. tostring(max_h)
    local cached = self._details_img
    if cached and cached.key == key then return cached.bb end

    local bb = nil
    local okm, Scanner = pcall(require, "image_scanner")
    if okm and Scanner and Scanner.isSupported(self.ui) then
        local ok, res = pcall(Scanner.getPageImageBB, self.ui, page, max_w, max_h, self._total_pages)
        if ok then bb = res end
    end
    if cached and cached.bb then pcall(function() cached.bb:free() end) end
    self._details_img = { key = key, bb = bb }
    return bb
end

-- ---------------------------------------------------------------------------
-- Zoom de la imagen en el panel de detalles: pinch / spread, arrastre y doble tap para volver
-- ---------------------------------------------------------------------------
local IMG_ZOOM_MAX = 6
local IMG_ZOOM_SRC_MAX = 2048   -- lado maximo (px) de la imagen decodificada para hacer zoom

local function monoNow()
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.gettime then return socket.gettime() end
    return os.time()
end

-- Lado maximo de la imagen "fuente" (la que se decodifica una vez y alimenta panel y zoom): como mucho el
-- doble del lado mayor de la pantalla (mas que eso no se nota ni con zoom y solo gasta memoria)
local function imgSrcMax()
    local m = math.max(Screen:getWidth(), Screen:getHeight())
    return math.max(1024, math.min(IMG_ZOOM_SRC_MAX, m * 2))
end

-- ---- Esquinas de afuera de un recuadro redondeado ----
-- Con fondo de pantalla (o con el libro detras) lo que se pinta dentro de un recuadro redondeado -- la
-- miniatura, la imagen con zoom, el blanco de paintFrameOver -- puede asomar en las esquinas, fuera del
-- contorno. Se guardan esas 4 esquinas del fondo ANTES de pintar y se restauran DESPUES. Asi no depende
-- del grosor del borde y respeta cualquier fondo. La forma es la misma de paintCornerRect.
local function cornerOutsideInset(j, r)
    if r <= 0 or j >= r then return 0 end
    local d = r - j - 0.5
    return r - math.ceil(math.sqrt(r * r - d * d))
end

function PageScrubber:_snapCorners(bb, x, y, w, h, r)
    r = math.max(0, math.min(r or 0, math.floor(w / 2), math.floor(h / 2)))
    if r <= 0 then return nil end
    local ok, snap = pcall(function()
        local t = bb:getType()
        local function patch(px, py)
            local pb = Blitbuffer.new(r, r, t)
            pb:blitFrom(bb, 0, 0, px, py, r, r)
            return pb
        end
        return { r = r, x = x, y = y, w = w, h = h,
                 tl = patch(x, y), tr = patch(x + w - r, y),
                 bl = patch(x, y + h - r), br = patch(x + w - r, y + h - r) }
    end)
    return ok and snap or nil
end

function PageScrubber:_restoreCorners(bb, snap)
    if not snap then return end
    pcall(function()
        local r, x, y, w, h = snap.r, snap.x, snap.y, snap.w, snap.h
        for j = 0, r - 1 do
            local o = cornerOutsideInset(j, r)
            if o > 0 then
                bb:blitFrom(snap.tl, x, y + j, 0, j, o, 1)
                bb:blitFrom(snap.tr, x + w - o, y + j, r - o, j, o, 1)
                bb:blitFrom(snap.bl, x, y + h - 1 - j, 0, r - 1 - j, o, 1)
                bb:blitFrom(snap.br, x + w - o, y + h - 1 - j, r - o, r - 1 - j, o, 1)
            end
        end
    end)
    for _, k in ipairs({ "tl", "tr", "bl", "br" }) do
        pcall(function() snap[k]:free() end)
    end
end

-- Copia / restaura una region entera (el modo expandido tapa la columna derecha: se restaura el fondo
-- que habia debajo en vez de pintar un rectangulo blanco)
function PageScrubber:_snapRegion(bb, x, y, w, h)
    if w <= 0 or h <= 0 then return nil end
    local ok, snap = pcall(function()
        local c = Blitbuffer.new(w, h, bb:getType())
        c:blitFrom(bb, 0, 0, x, y, w, h)
        return { bb = c, x = x, y = y, w = w, h = h }
    end)
    return ok and snap or nil
end

function PageScrubber:_restoreRegion(bb, snap)
    if not snap then return false end
    local ok = pcall(function() bb:blitFrom(snap.bb, snap.x, snap.y, 0, 0, snap.w, snap.h) end)
    pcall(function() snap.bb:free() end)
    return ok
end

-- Libera el ultimo cuadro con zoom guardado
function PageScrubber:_freeZoomRender()
    local rc = self._zoom_render
    if rc and rc.bb then pcall(function() rc.bb:free() end) end
    self._zoom_render = nil
end

-- Imagen "fuente" de una entrada del tab de imagenes: se lee y decodifica UNA vez y se reutiliza para el
-- panel (normal / expandido) y para el zoom. Vive en _img_zoom_src (se libera al cambiar de imagen).
function PageScrubber:_getImageSource(entry)
    local key = tostring(entry.path) .. "|" .. tostring(entry.page)
    local zs = self._img_zoom_src
    if zs and zs.key == key then return zs.bb end
    if zs and zs.bb then pcall(function() zs.bb:free() end) end
    local src = nil
    local okm, Scanner = pcall(require, "image_scanner")
    if okm and Scanner and Scanner.decodeSource then
        local ok, res = pcall(Scanner.decodeSource, self.ui, entry.img, imgSrcMax())
        if ok then src = res end
    end
    self._img_zoom_src = { key = key, bb = src }
    return src
end

-- Escala un blitbuffer (libera el original si lo logra); nil si falla
local function scaleBB(bb, w, h)
    local okR, RenderImage = pcall(require, "ui/renderimage")
    if okR and RenderImage and RenderImage.scaleBlitBuffer then
        local ok, res = pcall(RenderImage.scaleBlitBuffer, RenderImage, bb, w, h, true)
        if ok and res then return res end
    end
    local ok, res = pcall(function() return bb:scale(w, h) end)
    if ok and res then
        pcall(function() bb:free() end)
        return res
    end
    return nil
end

function PageScrubber:_imgZoomActive(ges)
    return self._view_mode == "split" and self._details_open and self._img_zoom_cur_key ~= nil
        and self._details_panel_dimen ~= nil
        and (not (ges and ges.pos) or ges.pos:intersectWith(self._details_panel_dimen))
end

-- Pantalla e-ink (Kindle/Kobo...): ahi cada refresco "ui" deja ghosting, asi que se pinta menos y con "partial"
function PageScrubber:_zoomEink()
    if self._zoom_is_eink == nil then
        self._zoom_is_eink = (Device.hasEinkScreen and Device:hasEinkScreen()) and true or false
    end
    return self._zoom_is_eink
end

-- Refresco de los cambios de zoom / expandido: "partial" en e-ink (limpia ghosting), "ui" en pantallas fluidas
function PageScrubber:_zoomDirty(region)
    UIManager:setDirty(self, self:_zoomEink() and "partial" or "ui", region or self._details_panel_dimen or self.dimen)
end

-- true si el panel muestra una imagen CON zoom aplicado y el gesto cae dentro del panel
function PageScrubber:_imgZoomed(ges)
    return self._img_zoom ~= nil and self:_imgZoomActive(ges)
end

-- Estado de zoom de la imagen que se esta mostrando (nil si esta sin zoom)
function PageScrubber:_imgZoomState(entry)
    local key = tostring(entry.path) .. "|" .. tostring(entry.page)
    self._img_zoom_cur_key = key
    local zs = self._img_zoom_src
    if zs and zs.key ~= key then
        if zs.bb then pcall(function() zs.bb:free() end) end
        self._img_zoom_src = nil
    end
    local st = self._img_zoom
    if st and st.key ~= key then self._img_zoom = nil; st = nil end
    if st and st.z > 1 then return st end
    self:_freeZoomRender()
    return nil
end

-- Pinch (zoom_in = false) / spread (zoom_in = true) sobre el panel de una imagen
function PageScrubber:_imgZoomApply(ges, zoom_in)
    if not self:_imgZoomActive(ges) then return false end
    local f = 1.6
    local span = ges and tonumber(ges.span)
    if span and span > 0 then
        f = math.max(1.25, 1 + math.min(2, 2 * span / Screen:getWidth()))
    end
    local st = self._img_zoom
    if not st or st.key ~= self._img_zoom_cur_key then
        st = { key = self._img_zoom_cur_key, z = 1, cx = 0.5, cy = 0.5 }
    end
    local z = zoom_in and (st.z * f) or (st.z / f)
    z = math.min(IMG_ZOOM_MAX, z)
    if z <= 1.05 then
        self._img_zoom = nil
    else
        st.z = z
        self._img_zoom = st
    end
    self:_zoomDirty()
    return true
end

-- Arrastre con un dedo mientras hay zoom
function PageScrubber:_imgZoomPan(ges)
    local st = self._img_zoom
    if not (st and st.s and ges and ges.pos) then return false end
    local now = monoNow()
    local last = self._zoom_pan_last
    -- un arrastre nuevo: si el anterior termino en un swipe, no queda "last" viejo
    if last and now - (self._zoom_pan_tlast or 0) > 0.6 then last = nil end
    if not last and not self:_imgZoomActive(ges) then return false end
    self._zoom_pan_last = { x = ges.pos.x, y = ges.pos.y }
    self._zoom_pan_tlast = now
    if not last then return true end
    self._zoom_pan_seen = true
    st.cx = st.cx - (ges.pos.x - last.x) / (st.sw * st.s)
    st.cy = st.cy - (ges.pos.y - last.y) / (st.sh * st.s)
    if not self:_zoomEink() and (not self._zoom_pan_t or now - self._zoom_pan_t > 0.08) then
        self._zoom_pan_t = now
        UIManager:setDirty(self, "ui", self._details_panel_dimen)
    end
    return true
end

-- Un arrastre rapido termina en "swipe" (en vez de pan_release): cierra el arrastre y repinta
function PageScrubber:_imgZoomSwipe(ges)
    local st = self._img_zoom
    if not (st and self._img_zoom_cur_key) then return false end
    if st.s and not self._zoom_pan_seen and ges and ges.direction then
        -- Flick sin eventos de pan: mueve segun la direccion y la distancia del swipe
        local d = tonumber(ges.distance) or 0
        local dir = ges.direction
        local dx = (dir:find("east") and d or 0) - (dir:find("west") and d or 0)
        local dy = (dir:find("south") and d or 0) - (dir:find("north") and d or 0)
        st.cx = st.cx - dx / (st.sw * st.s)
        st.cy = st.cy - dy / (st.sh * st.s)
    end
    self._zoom_pan_last, self._zoom_pan_seen, self._zoom_pan_t = nil, nil, nil
    self:_zoomDirty()
    return true
end

-- Dibuja la imagen con zoom dentro del recuadro (zx, zy, zw, zh). false si no se pudo.
function PageScrubber:_paintZoomedImage(bb, entry, base_bb, st, zx, zy, zw, zh)
    -- La fuente ya se decodifico al mostrar la imagen: aca solo se reutiliza (sin leer ni decodificar de nuevo)
    local src = self:_getImageSource(entry)
    if not src then return false end
    local sw, sh = src:getWidth(), src:getHeight()
    if sw < 1 or sh < 1 or zw < 1 or zh < 1 then return false end

    local s = (base_bb:getWidth() / sw) * st.z            -- px de pantalla por px de imagen
    local vis_w, vis_h = math.min(sw, zw / s), math.min(sh, zh / s)
    local sx = math.max(0, math.min(sw - vis_w, st.cx * sw - vis_w / 2))
    local sy = math.max(0, math.min(sh - vis_h, st.cy * sh - vis_h / 2))
    st.cx, st.cy = (sx + vis_w / 2) / sw, (sy + vis_h / 2) / sh
    st.s, st.sw, st.sh = s, sw, sh

    local sxi, syi = math.floor(sx), math.floor(sy)
    local cw = math.max(1, math.min(sw - sxi, math.ceil(vis_w)))
    local ch = math.max(1, math.min(sh - syi, math.ceil(vis_h)))
    local dw = math.min(zw, math.max(1, math.floor(cw * s + 0.5)))
    local dh = math.min(zh, math.max(1, math.floor(ch * s + 0.5)))

    -- Si es exactamente el mismo cuadro que la vez anterior (repintados por otros motivos, refrescos
    -- de limpieza...) se reutiliza: recortar + escalar es lo mas caro del zoom.
    local sig = table.concat({ st.key, sxi, syi, cw, ch, dw, dh }, "|")
    local rc = self._zoom_render
    local scaled = (rc and rc.sig == sig and rc.bb) or nil
    if not scaled then
        local okc, crop = pcall(function()
            local c = Blitbuffer.new(cw, ch, src:getType())
            c:blitFrom(src, 0, 0, sxi, syi, cw, ch)
            return c
        end)
        if not (okc and crop) then return false end
        scaled = scaleBB(crop, dw, dh)
        if not scaled then
            pcall(function() crop:free() end)
            return false
        end
        self:_freeZoomRender()
        self._zoom_render = { sig = sig, bb = scaled }
    end
    -- fondo blanco: tapa el titulo y lo que haya debajo
    bb:paintRect(zx, zy, zw, zh, Blitbuffer.COLOR_WHITE)
    bb:blitFrom(scaled, zx + math.floor((zw - dw) / 2), zy + math.floor((zh - dh) / 2), 0, 0, dw, dh)
    return true
end

-- Imagen de una entrada del tab de imagenes (para su panel de detalles), ajustada al recuadro.
function PageScrubber:_getEntryImageBB(entry, max_w, max_h)
    if not (entry and entry.img) or max_w < 1 or max_h < 1 then return nil end
    local key = "img|" .. tostring(entry.path) .. "|" .. tostring(entry.page) .. "|" .. tostring(max_w) .. "x" .. tostring(max_h)
    local cached = self._details_img
    if cached and cached.key == key then return cached.bb end

    local bb = nil
    local okm, Scanner = pcall(require, "image_scanner")
    if okm and Scanner then
        if Scanner.decodeSource and Scanner.fitFrom then
            -- La fuente se decodifica una vez; expandir/reducir y el zoom la reutilizan
            local src = self:_getImageSource(entry)
            if src then
                local ok, res = pcall(Scanner.fitFrom, src, max_w, max_h, 1.5)
                if ok then bb = res end
            end
        else
            local ok, res = pcall(Scanner.decodeFit, self.ui, entry.img, max_w, max_h)
            if ok then bb = res end
        end
    end
    if cached and cached.bb then pcall(function() cached.bb:free() end) end
    self._details_img = { key = key, bb = bb }
    return bb
end

-- full_w: ancho que toma el panel en modo expandido (desde x hasta el contorno derecho del menu derecho)
function PageScrubber:_paintDetailsPanel(bb, x, y, w, h, radius, thick, full_w)
    local pw = w
    if self._details_open and self._details_expanded and full_w and full_w > w then pw = full_w end
    local snap = self._details_open and self:_snapCorners(bb, x, y, pw, h, radius) or nil
    self:_paintDetailsPanelInner(bb, x, y, w, h, radius, thick, full_w)
    self:_restoreCorners(bb, snap)
end

function PageScrubber:_paintDetailsPanelInner(bb, x, y, w, h, radius, thick, full_w)
    self._details_panel_dimen = nil
    self._details_close_dimen = nil
    self._details_nav_dimens = nil
    self._details_quote_dimen = nil
    self._details_note_dimen = nil
    self._details_filter_dimens = nil
    self._details_link_dimen = nil
    self._details_back_dimen = nil
    if not self._details_open then
        self._details_expanded = false
        return
    end
    if self._details_expanded and full_w and full_w > w then
        w = full_w   -- todo lo de abajo (textos, puntitos, imagenes, zoom) se calcula con el nuevo ancho
    end

    local ctx = self:_getDetailsContext()
    if not ctx then
        if self._details_resync_pending then return end   -- cambio de tab/filtro en curso
        self._details_open = false
        self:_freeDetailsWidgets()
        return
    end
    local data = self:_buildDetailsData(ctx)
    self._img_zoom_cur_key = nil   -- se vuelve a fijar abajo si el panel muestra una imagen

    local S = self.S
    local BLACK, WHITE, GRAY = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_GRAY
    local line = S(2)
    local thin = math.max(1, S(1))
    local pad = S(14)
    -- Tamanos: chico = el de "Page" del encabezado; mediano = el de los numeros de la lista
    local small = self.S_BOTTOM_GRAY and (self.S_BOTTOM_GRAY - S(4)) or S(10)
    local medium = self.S_BOTTOM_GRAY or S(14)

    self._details_panel_dimen = Geom:new{ x = x, y = y, w = w, h = h }

    -- Contorno y fondo: mismo estilo que la polaroid
    paintRoundRect(bb, x, y, w, h, radius, BLACK)
    paintRoundRect(bb, x + thick, y + thick, w - thick * 2, h - thick * 2, math.max(1, radius - thick), WHITE)

    local ix, iw = x + thick, w - thick * 2
    local top_y = y + thick
    local top_h = S(38)
    local nav_h = S(40)
    local nav_y = y + h - thick - nav_h
    local link_h = S(30)                     -- fila "Show in book", justo arriba de los puntitos
    local content_bottom = nav_y - link_h    -- el contenido (imagen / texto) termina antes de esa fila
    local text_w = iw - pad * 2

    local function small_tw(slot, max_w)
        if not self[slot] then
            self[slot] = TextWidget:new{ text = "", face = Font:getFace("cfont", small), bold = true, fgcolor = BLACK, truncate_with_ellipsis = true }
        end
        self[slot].max_width = max_w
        return self[slot]
    end

    -- Cache de TextBoxWidgets por "slot" (se recrean solo si cambia el texto / ancho / alto)
    local function get_tbw(slot, text, width, height, fsz, bold)
        local key = table.concat({ text, tostring(width), tostring(height or 0), tostring(fsz), bold and "1" or "0" }, "\1")
        self._details_tbw = self._details_tbw or {}
        local ent = self._details_tbw[slot]
        if not ent or ent.key ~= key then
            if ent and ent.w then pcall(function() ent.w:free() end) end
            local args = { text = text, face = Font:getFace("cfont", fsz), width = width,
                           alignment = "left", fgcolor = BLACK, bold = bold and true or false }
            if height then
                args.height = height
                args.height_adjust = true
                args.height_overflow_show_ellipsis = true
            end
            ent = { key = key, w = TextBoxWidget:new(args) }
            self._details_tbw[slot] = ent
        end
        return ent.w
    end

    local function scroll_marks(wdg, bx, by, bw, bh)
        local okv, vis, all, vtop = pcall(function()
            return wdg:getVisLineCount(), wdg:getAllLineCount(), wdg.virtual_line_num
        end)
        if okv and vis and all and vtop and all > vis then
            local gw, gh = S(10), S(6)
            local gx = bx + bw - pad + math.floor((pad - gw) / 2)
            if vtop > 1 then
                for row = 0, gh - 1 do
                    local rw = math.max(1, math.floor(gw * (row + 1) / gh + 0.5))
                    bb:paintRect(gx + math.floor((gw - rw) / 2), by + row, rw, 1, BLACK)
                end
            end
            if vtop + vis - 1 < all then
                self:_paintChevronDown(bb, gx, by + bh - gh, gw, gh, BLACK)
            end
        end
        return okv and vtop or 1
    end

    -- ---- Titulo (tipo + color, tamano de la lista) + X ----
    if not self._tw_details_title then
        self._tw_details_title = TextWidget:new{ text = "", face = Font:getFace("cfont", medium), bold = true, fgcolor = BLACK, truncate_with_ellipsis = true }
    end
    local close_sz = S(40)
    local title = self._tw_details_title
    -- A la izquierda de la primera linea va el boton "atras" (undo.svg): vuelve al split menu en esta pagina.
    -- Reemplaza al icono de carpeta que tenian las imagenes y se suma a las anotaciones/bookmarks (sin icono).
    local back_sz = S(40)
    local is_img = (data.image_entry ~= nil)
    -- Filtros del menu derecho (estilos de highlight / carpetas de imagenes): solo en modo expandido,
    -- arriba a la derecha, a la izquierda del boton shrink
    local filt_list = {}
    local filt_cell_w = S(30)
    if self._details_expanded then
        local defs = nil
        if self._active_tab == "images" and self._imgTabEnabled then
            defs = self:_imgFilterDefs()
        elseif self._active_tab == "highlights" or self._active_tab == "notes" then
            local all_defs = {
                { key = "normal",        icon_on = self.icon_filter_hl_on,  icon_off = self.icon_filter_hl_off },
                { key = "underline",     icon_on = self.icon_filter_ul_on,  icon_off = self.icon_filter_ul_off },
                { key = "invert",        icon_on = self.icon_filter_inv_on, icon_off = self.icon_filter_inv_off },
                { key = "strikethrough", icon_on = self.icon_filter_st_on,  icon_off = self.icon_filter_st_off },
            }
            local types_source = self:_getTypesPresent()
            defs = {}
            for _, fd in ipairs(all_defs) do
                if types_source and types_source[fd.key] then defs[#defs + 1] = fd end
            end
        end
        if defs and #defs >= 2 then filt_list = defs end
    end
    local filt_total_w = #filt_list * filt_cell_w
    title.max_width = iw - back_sz - close_sz - (filt_total_w > 0 and (filt_total_w + S(8)) or 0)
    title.text = nil
    title:setText(data.title)
    local title_h = title:getSize().h
    local title_y = top_y + S(8)
    title:paintTo(bb, ix + back_sz, title_y)
    self._details_back_dimen = Geom:new{ x = ix, y = top_y, w = back_sz, h = title_h + S(16) }
    do
        local back_icon = self.icon_details_close
        if back_icon then
            local bsz2 = back_icon:getSize()
            back_icon:paintTo(bb, ix + math.floor((back_sz - bsz2.w) / 2) + S(2),
                title_y + math.floor((title_h - bsz2.h) / 2))
        else
            paintCross(bb, ix + math.floor((back_sz - S(12)) / 2), title_y + math.floor((title_h - S(12)) / 2), S(12), S(2), BLACK)
        end
        if self._pressed_btn == "details_back" then
            bb:invertRect(ix + S(6), top_y + S(4), back_sz - S(12), title_h + S(8))
        end
    end

    local cross = S(12)
    self._details_close_dimen = Geom:new{ x = ix + iw - close_sz, y = top_y, w = close_sz, h = title_h + S(16) }
    local close_icon = self.icon_details_close   -- undo.svg: solo se usa mas abajo, en modo zoom
    local toggle_icon = self._details_expanded and self.icon_details_shrink or self.icon_details_expand
    if toggle_icon then
        local csz = toggle_icon:getSize()
        toggle_icon:paintTo(bb, self._details_close_dimen.x + math.floor((close_sz - csz.w) / 2),
            title_y + math.floor((title_h - csz.h) / 2))
    else
        paintCross(bb, self._details_close_dimen.x + math.floor((close_sz - cross) / 2),
            title_y + math.floor((title_h - cross) / 2), cross, S(2), BLACK)
    end
    if self._pressed_btn == "details_close" then
        bb:invertRect(self._details_close_dimen.x + S(6), top_y + S(4), close_sz - S(12), title_h + S(8))
    end

    if #filt_list > 0 then
        local cell_h = title_h + S(16)
        local fx0 = self._details_close_dimen.x - filt_total_w
        local active_key = (self._active_tab == "images") and self._img_folder or self._hl_filter
        self._details_filter_dimens = {}
        for i, fd in ipairs(filt_list) do
            local cx0 = fx0 + (i - 1) * filt_cell_w
            local is_active = (active_key == fd.key)
            local ficon = is_active and fd.icon_on or fd.icon_off
            if ficon then
                local fsz = ficon:getSize()
                local fix = cx0 + math.floor((filt_cell_w - fsz.w) / 2)
                local fiy = top_y + math.floor((cell_h - fsz.h) / 2)
                ficon:paintTo(bb, fix, fiy)
                if is_active then
                    bb:paintRect(fix + S(2), fiy + fsz.h + S(2), math.max(1, fsz.w - S(4)), S(3), BLACK)
                end
            end
            self._details_filter_dimens[#self._details_filter_dimens + 1] = {
                key = fd.key,
                dimen = Geom:new{ x = cx0, y = top_y, w = filt_cell_w, h = cell_h },
            }
        end
    end

    -- ---- Fecha (italica), pegada al titulo ----
    local cy = title_y + title_h + S(2)
    local date_h = S(14)
    if data.date then
        if not self._tw_details_date then
            self._tw_details_date = TextWidget:new{ text = "", face = italic_face(small), fgcolor = BLACK, truncate_with_ellipsis = true }
        end
        local dtw = self._tw_details_date
        dtw.max_width = text_w
        dtw.text = nil
        dtw:setText(data.date)
        dtw:paintTo(bb, ix + pad, cy)
        date_h = dtw:getSize().h
    end
    if is_img then
        cy = title_y + title_h + S(10)
    else
        cy = cy + date_h + date_h   -- una linea entera de separacion
    end

    -- ---- Icono + capitulo (fuente de la lista). "Page N" ahora va en la fila de "Show in book" ----
    local icon = data.icon
    local icon_w, icon_h = S(20), S(20)
    if icon then
        local isz = icon:getSize()
        icon_w, icon_h = isz.w, isz.h
    end
    local indent = icon_w + S(10)     -- columna de texto: capitulo, page, cita y nota
    local col_x = ix + pad + indent
    local col_w = text_w - indent

    -- Alto de una linea con la fuente mediana (la de la lista derecha)
    local med_lh = get_tbw("med_probe", "Ag", col_w, nil, medium, false):getSize().h

    local chap_h = 0
    if data.chapter then
        local chap = get_tbw("chapter", data.chapter, col_w, nil, medium, false)
        chap:paintTo(bb, col_x, cy)
        chap_h = chap:getSize().h
    end
    if not is_img then
        local row_h = math.max(icon_h, chap_h)
        if icon then
            local first_line_h = (data.chapter and med_lh) or icon_h
            icon:paintTo(bb, ix + pad, cy + math.floor((first_line_h - icon_h) / 2))
        end
        cy = cy + row_h + S(12)
    end

    -- ---- Bookmark: la pagina entera donde se hizo el bookmark, en el espacio libre ----
    if data.is_bookmark then
        local img_h = content_bottom - S(4) - cy
        local img = self:_getPageTileBB(data.page, text_w, img_h)
        if img then
            local iw2, ih2 = img:getWidth(), img:getHeight()
            -- Centrada en horizontal; en vertical un poco por encima del centro:
            -- IMG_V_BIAS = 0 (pegada arriba) ... 0.5 (centrada del todo)
            local IMG_V_BIAS = 0.3
            local px = ix + pad + math.floor((text_w - iw2) / 2)
            local py = cy + math.max(0, math.floor((img_h - ih2) * IMG_V_BIAS))
            bb:blitFrom(img, px, py, 0, 0, iw2, ih2)
            pcall(function() bb:paintBorder(px, py, iw2, ih2, 1, Blitbuffer.COLOR_DARK_GRAY, 0) end)
        end
    end

    -- ---- Tab de imagenes: la imagen ocupa el espacio libre, centrada ----
    if data.image_entry then
        local img_h = content_bottom - S(4) - cy
        local img = self:_getEntryImageBB(data.image_entry, text_w, img_h)
        local zst = self:_imgZoomState(data.image_entry)
        local zoomed = false
        if img and zst then
            -- Con zoom la imagen ocupa TODO el interior del panel (tapa titulo y puntitos) y queda
            -- detras del contorno, que se redibuja encima para que no se salga
            local zy = top_y
            zoomed = self:_paintZoomedImage(bb, data.image_entry, img, zst, ix, zy, iw, (y + h - thick) - zy)
            if zoomed then
                paintFrameOver(bb, x, y, w, h, radius, thick)
                -- Boton de volver (sale del zoom) encima de la imagen
                local cd = self._details_close_dimen
                local bsz = close_sz - S(6)
                local bx, by = cd.x + S(3), top_y + S(4)
                paintRoundRect(bb, bx, by, bsz, bsz, S(8), BLACK)
                paintRoundRect(bb, bx + thin * 2, by + thin * 2, bsz - thin * 4, bsz - thin * 4, S(6), WHITE)
                if close_icon then
                    local csz = close_icon:getSize()
                    close_icon:paintTo(bb, bx + math.floor((bsz - csz.w) / 2), by + math.floor((bsz - csz.h) / 2))
                else
                    paintCross(bb, bx + math.floor((bsz - cross) / 2), by + math.floor((bsz - cross) / 2), cross, S(2), BLACK)
                end
                self._details_nav_dimens = {}   -- sin puntitos en modo zoom
                self._details_filter_dimens = nil   -- ni filtros (el zoom tapa el titulo)
                self._details_link_dimen = nil      -- ni "Show in book"
                self._details_back_dimen = nil      -- ni el boton atras de la izquierda
                do return end
            end
        end
        if img and not zoomed then
            local iw2, ih2 = img:getWidth(), img:getHeight()
            local px, py = ix + pad + math.floor((text_w - iw2) / 2), cy + math.max(0, math.floor((img_h - ih2) / 2))
            bb:blitFrom(img, px, py, 0, 0, iw2, ih2)
            self._img_view_rect = { x = px, y = py, w = iw2, h = ih2 }
        end
    end

    -- ---- Texto del highlight (resaltado de verdad) y, si hay, nota ----
    local avail = content_bottom - S(4) - cy
    local small_lh = get_tbw("small_probe", "Ag", col_w, nil, small, true):getSize().h
    local has_note = data.note ~= nil
    local note_icon = self.icon_pol_pencil
    local note_icon_h = 0
    if has_note and note_icon then note_icon_h = note_icon:getSize().h end

    -- Lineas del resaltado (se cortan a mano para poder pintar el fondo de cada linea)
    local qc, qlh, ql, qinv = nil, 0, nil, nil
    if data.quote then
        if not self._tw_details_qline then
            self._tw_details_qline = TextWidget:new{ text = "Ag", face = Font:getFace("cfont", small), bold = true, fgcolor = BLACK }
            self._tw_details_qline_inv = TextWidget:new{ text = "Ag", face = Font:getFace("cfont", small), bold = true, fgcolor = WHITE }
        end
        ql, qinv = self._tw_details_qline, self._tw_details_qline_inv
        ql.text = nil; ql:setText("Ag")
        qlh = ql:getSize().h
        local qkey = data.quote .. "\1" .. tostring(col_w) .. "\1" .. tostring(small)
        if not self._details_qcache or self._details_qcache.key ~= qkey then
            if not self._tw_details_measure then
                self._tw_details_measure = TextWidget:new{ text = "Ag", face = Font:getFace("cfont", small), bold = true, fgcolor = BLACK }
            end
            local m = self._tw_details_measure
            local function measure(str) m.text = nil; m:setText(str); return m:getSize().w end
            local lines = wrap_text(measure, data.quote, col_w)
            local widths = {}
            for i, ln in ipairs(lines) do widths[i] = (ln == "") and 0 or measure(ln) end
            self._details_qcache = { key = qkey, lines = lines, widths = widths }
            self._details_quote_first = 1
        end
        qc = self._details_qcache
    end

    local function draw_marks(first, vis, total, bx, by, bw, bh)
        if total <= vis then return end
        local gw, gh = S(10), S(6)
        local gx = bx + bw - pad + math.floor((pad - gw) / 2)
        if first > 1 then
            for row = 0, gh - 1 do
                local rw = math.max(1, math.floor(gw * (row + 1) / gh + 0.5))
                bb:paintRect(gx + math.floor((gw - rw) / 2), by + row, rw, 1, BLACK)
            end
        end
        if first + vis - 1 < total then
            self:_paintChevronDown(bb, gx, by + bh - gh, gw, gh, BLACK)
        end
    end

    if (data.quote or has_note) and avail >= small_lh then
        local div_space = (data.quote and has_note) and S(12) or 0
        local note_hdr = (has_note and note_icon) and (note_icon_h + S(4)) or 0   -- fila del icono de la nota
        local space = avail - div_space - note_hdr
        local total_l = qc and #qc.lines or 0
        local nat_q = total_l * qlh
        local nat_n = has_note and get_tbw("note_nat", data.note, col_w, nil, small, true):getSize().h or 0

        local q_h, n_h = nat_q, nat_n
        local limited = false
        if nat_q + nat_n > space then
            limited = true
            if data.quote and has_note then
                n_h = math.min(nat_n, math.max(small_lh * 2, math.floor(space * 0.4)))
                q_h = space - n_h
                if nat_q < q_h then q_h = nat_q; n_h = math.min(nat_n, space - q_h) end
            elseif data.quote then
                q_h = space
            else
                n_h = space
            end
        end

        if data.quote and qc then
            local vis = total_l
            if limited then
                vis = math.max(1, math.floor(q_h / qlh))
                q_h = vis * qlh
            end
            local first = math.max(1, math.min(self._details_quote_first or 1, math.max(1, total_l - vis + 1)))
            self._details_quote_first = first
            self._details_quote_st = { first = first, vis = vis, total = total_l }

            local etype = data.quote_type or "normal"
            local hl_color = nil
            if etype ~= "invert" then
                local okc, CFM = pcall(require, "color_filter_menu")
                if okc and CFM and CFM.resolveColor then hl_color = CFM.resolveColor(data.quote_color or "yellow") end
                hl_color = hl_color or GRAY
            end
            for i = 0, vis - 1 do
                local li = first + i
                local ln = qc.lines[li]
                if not ln then break end
                local lw = qc.widths[li]
                local ly = cy + i * qlh
                if ln ~= "" then
                    if etype == "invert" then
                        bb:paintRect(col_x, ly, lw, qlh, BLACK)
                        qinv.text = nil; qinv:setText(ln); qinv:paintTo(bb, col_x, ly)
                    else
                        if etype == "normal" then paint_color_rect(bb, col_x, ly, lw, qlh, hl_color) end
                        ql.text = nil; ql:setText(ln); ql:paintTo(bb, col_x, ly)
                        if etype == "underline" then
                            paint_color_rect(bb, col_x, ly + qlh - S(3), lw, S(2), hl_color)
                        elseif etype == "strikethrough" then
                            paint_color_rect(bb, col_x, ly + math.floor(qlh / 2), lw, S(2), hl_color)
                        end
                    end
                end
            end
            self._details_quote_dimen = Geom:new{ x = ix, y = cy, w = iw, h = q_h }
            if limited then draw_marks(first, vis, total_l, ix, cy, iw, q_h) end
            cy = cy + q_h
        end

        if data.quote and has_note then
            cy = cy + S(12)   -- solo aire entre el highlight y la nota
        end

        if has_note then
            -- Icono del lapiz alineado con el capitulo; el texto de la nota va en la linea de abajo
            if note_icon then
                note_icon:paintTo(bb, col_x, cy)
                cy = cy + note_icon_h + S(4)
            end
            local nw = limited and get_tbw("note", data.note, col_w, n_h, small, true)
                       or get_tbw("note_nat", data.note, col_w, nil, small, true)
            nw:paintTo(bb, col_x, cy)
            self._details_note_dimen = Geom:new{ x = ix, y = cy, w = iw, h = n_h }
            self._details_note_tbw = nw
            if limited then scroll_marks(nw, ix, cy, iw, n_h) end
        end
    end

    -- ---- "Show in book - Page N": todo subrayado; toda la fila (incluido el numero) es tocable ----
    do
        local ltw = small_tw("_tw_details_link", text_w)
        ltw.text = nil
        -- En ingles: "Show in book - Page N". En otros idiomas solo "Page N" (la palabra "Page" ya viene
        -- traducida de KOReader), asi no hace falta traducir "Show in book".
        local lang = (G_reader_settings and G_reader_settings:readSetting("language")) or "en"
        local is_english = (lang == "en") or (tostring(lang):match("^en[_%-]") ~= nil)
        local link_text
        if is_english or not data.page_line or data.page_line == "" then
            link_text = _("Show in book")
            if data.page_line and data.page_line ~= "" then
                link_text = link_text .. " - " .. data.page_line
            end
        else
            link_text = data.page_line
        end
        ltw:setText(link_text)
        local lsz = ltw:getSize()
        local ly = nav_y - link_h
        local lx = ix + math.floor((iw - lsz.w) / 2)
        local ty = ly + math.floor((link_h - lsz.h) / 2)
        ltw:paintTo(bb, lx, ty)
        bb:paintRect(lx, ty + lsz.h, lsz.w, math.max(1, S(2)), BLACK)   -- subrayado negro (todo el texto)
        self._details_link_dimen = Geom:new{ x = ix, y = ly, w = iw, h = link_h }   -- toda la fila es tocable
        if self._pressed_btn == "details_link" then
            bb:invertRect(lx - S(6), ly + S(2), lsz.w + S(12), link_h - S(4))
        end
    end

    -- ---- Fila de navegacion (sin contornos) ----
    -- Puntitos (los mismos del indice) si entran; si no, el formato anterior: |<  <  1/7  >  >|
    local ncell_y = nav_y
    local ncell_h = (y + h - thick) - ncell_y
    local idx, n = ctx.idx, ctx.n
    local enabled = { first = idx > 1, prev = idx > 1, next = idx < n, last = idx < n }

    local dot_r = math.max(2, math.floor(S(2.5)))
    local dot_rmax = math.floor(dot_r * 1.5)
    local dot_min_pitch = 2 * dot_r + S(3)
    local dot_pitch = S(11)
    if n > 1 then
        dot_pitch = math.floor(math.min(dot_pitch, (text_w - 2 * dot_rmax) / (n - 1)))
    end
    local use_dots = (n > 1) and (dot_pitch >= dot_min_pitch)

    self._details_nav_dimens = {}
    if use_dots then
        local dots_w = (n - 1) * dot_pitch + 2 * dot_rmax
        local dots_x = ix + math.floor((iw - dots_w) / 2)
        local dots_cy = ncell_y + math.floor(ncell_h / 2)
        local x0 = dots_x + dot_rmax
        for i = 1, n do
            local is_cur = (i == idx)
            local r = is_cur and dot_rmax or dot_r
            paintRoundRect(bb, x0 + (i - 1) * dot_pitch - r, dots_cy - r, r * 2, r * 2, r,
                is_cur and BLACK or Blitbuffer.COLOR_DARK_GRAY)
        end
        self._details_nav_dimens[1] = {
            key = "dots", enabled = true, x0 = x0, pitch = dot_pitch,
            dimen = Geom:new{ x = ix, y = ncell_y, w = iw, h = ncell_h },
        }
    end

    local cells = use_dots and {} or {
        { key = "first", wt = 1 }, { key = "prev", wt = 1 }, { key = "counter", wt = 1.5 },
        { key = "next", wt = 1 }, { key = "last", wt = 1 },
    }
    local total_wt = 0
    for _, c in ipairs(cells) do total_wt = total_wt + c.wt end
    local gh, gw, barw, gap = S(16), S(11), S(3), S(3)
    local cx = ix
    for i, c in ipairs(cells) do
        local cw = (i == #cells) and (ix + iw - cx) or math.floor(iw * c.wt / total_wt)
        local k = c.key
        if k == "counter" then
            local ctw = small_tw("_tw_details_counter", cw)
            ctw.text = nil
            ctw:setText(string.format("%d/%d", idx, n))
            local csz = ctw:getSize()
            ctw:paintTo(bb, cx + math.floor((cw - csz.w) / 2), ncell_y + math.floor((ncell_h - csz.h) / 2))
        else
            local en = enabled[k]
            local col = en and BLACK or GRAY
            local with_bar = (k == "first" or k == "last")
            local total_w = with_bar and (gw + gap + barw) or gw
            local gx = cx + math.floor((cw - total_w) / 2)
            local gy = ncell_y + math.floor((ncell_h - gh) / 2)
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
            if self._pressed_btn == "details_" .. k then
                bb:invertRect(cx + S(4), ncell_y + S(3), cw - S(8), ncell_h - S(10))
            end
            self._details_nav_dimens[#self._details_nav_dimens + 1] = {
                key = k, enabled = en,
                dimen = Geom:new{ x = cx, y = ncell_y, w = cw, h = ncell_h },
            }
        end
        cx = cx + cw
    end
end

function PageScrubber:_openDetailsPanel()
    if self._details_open then return true end
    local ctx = self:_getDetailsContext()
    if not ctx then return false end
    if type(ctx.entry) == "table" then self._split_selected_item = ctx.entry end
    self._details_open = true
    self._details_expanded = false
    self._hide_action_buttons = true
    self._show_delete_confirm = false
    self._show_type_picker = false
    self._force_menu_sync = true
    UIManager:setDirty(self, "ui", self.dimen)
    self:_preloadDetailsNeighborPages()
    return true
end

-- go_origin = true: ademas vuelve la previsualizacion a la pagina real del libro
function PageScrubber:_closeDetailsPanel(go_origin)
    self._details_open = false
    self._details_expanded = false
    self._details_bm_mode = false
    self:_freeDetailsWidgets()
    if go_origin then
        self._split_selected_item = nil
        self._hide_action_buttons = true
        self._force_menu_sync = true
        self:_previewPage(self._origin_page or self._cur_page, false)
    end
    UIManager:setDirty(self, "ui", self.dimen)
end

function PageScrubber:_detailsStep(key, goto_idx)
    local ctx = self:_getDetailsContext()
    if not ctx then return end
    local target = ctx.idx
    if key == "goto" then target = tonumber(goto_idx) or ctx.idx
    elseif key == "first" then target = 1
    elseif key == "prev" then target = ctx.idx - 1
    elseif key == "next" then target = ctx.idx + 1
    elseif key == "last" then target = ctx.n end
    target = math.max(1, math.min(ctx.n, target))
    if target == ctx.idx then return end

    local entry = ctx.items[target]
    self._split_selected_item = (type(entry) == "table") and entry or nil
    local page = (type(entry) == "table") and entry.page or entry
    self._details_step_dir = (target > ctx.idx) and 1 or -1
    self._hide_action_buttons = true
    self._show_delete_confirm = false
    self._show_type_picker = false
    self._force_menu_sync = true
    self:_previewPage(page, false)
    UIManager:setDirty(self, "ui", self.dimen)
end

function PageScrubber:_scrollDetails(dir, pos)
    if pos and self._details_note_dimen and self._details_note_tbw and pos:intersectWith(self._details_note_dimen) then
        pcall(function()
            if dir > 0 then self._details_note_tbw:scrollDown() else self._details_note_tbw:scrollUp() end
        end)
        UIManager:setDirty(self, "ui", self._details_note_dimen)
        return
    end
    local st = self._details_quote_st
    if pos and st and self._details_quote_dimen and pos:intersectWith(self._details_quote_dimen) and st.total > st.vis then
        local step = math.max(1, st.vis - 1)
        local first = self._details_quote_first or 1
        if dir > 0 then first = math.min(st.total - st.vis + 1, first + step)
        else first = math.max(1, first - step) end
        self._details_quote_first = first
        UIManager:setDirty(self, "ui", self._details_quote_dimen)
    end
end

function PageScrubber:_paintSplitView(bb, title_strip_y, title_strip_h)
    local gd = self._grid_dimen
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local S = self.S
    
    local shadow_offset = S(4)
    local box_radius = S(12)
    local b_thick = S(2)   -- estilo nativo: contorno mas fino (antes S(3)); los redondeados no cambian
    -- Atados dinámicamente a tu configuración base:
    local font_sz_chiquito = self.S_BOTTOM_GRAY and (self.S_BOTTOM_GRAY - S(4)) or S(10)
    local S_MEDIANO = self.S_BOTTOM_GRAY or S(14) 

    
    local real_top_y = title_strip_y
    local real_available_h = (gd.y + gd.h) - real_top_y
    
    local status_h = S(32) 
    local fx_h = S(56)
    local gap_x = S(28)
    local target_gap = S(12)
    local tab_h = S(36) 
    local tab_sp_y = S(8)
    
    local margin_y = S(12) 
    local max_content_h = real_available_h - tab_h - tab_sp_y - (margin_y * 2)
    if max_content_h < S(200) then max_content_h = S(200) end
    
    local max_pr_w_allowed = math.max(S(50), math.floor((sw - S(40) - gap_x) * 0.65))
    local target_pr_w = max_pr_w_allowed
    local target_pr_h = math.floor(target_pr_w * (sh / sw))
    local target_content_h = target_pr_h + status_h
    
    if target_content_h > max_content_h then
        target_content_h = max_content_h
        target_pr_h = target_content_h - status_h
        target_pr_w = math.floor(target_pr_h * (sw / sh))
    end
    
    local min_menu_h = S(100)
    local available_menu_h = target_content_h - target_gap - fx_h
    
    if available_menu_h < min_menu_h then
        available_menu_h = min_menu_h
        target_content_h = available_menu_h + target_gap + fx_h
        target_pr_h = target_content_h - status_h
        target_pr_w = math.floor(target_pr_h * (sw / sh))
    end
    
    local pr_w = target_pr_w
    local pr_h = target_pr_h
    local lm_w = math.floor(pr_w * (35 / 65))
    
    self._thumb_req_split_w = math.max(S(30), pr_w)
    self._thumb_req_split_h = math.max(S(30), pr_h)
    
    if pr_w < S(40) then pr_w = S(40) end
    if pr_h < S(40) then pr_h = S(40) end
    if lm_w < S(40) then lm_w = S(40) end
    
    local header_h = S(30)
    local black_line_thickness = S(0)
    local available_list_h = math.max(S(50), available_menu_h - header_h - black_line_thickness)
    
    local target_row_h = S(50)
    local num_rows = math.max(2, math.floor(available_list_h / target_row_h + 0.5))
    local row_h = math.floor(available_list_h / num_rows)
    local exact_menu_h = header_h + black_line_thickness + num_rows * row_h
    
    local gap_y = math.max(0, target_content_h - exact_menu_h - fx_h)
    
    local block_total_w = pr_w + gap_x + lm_w
    local pr_x = math.max(S(12), math.floor((sw - block_total_w) / 2))
    local lm_x = pr_x + pr_w + gap_x
    self._split_divider_x = lm_x - math.floor(gap_x / 2)

    local final_content_h = exact_menu_h + gap_y + fx_h
    local total_block_h = tab_h + tab_sp_y + final_content_h
    
    local block_start_y = real_top_y + math.floor((real_available_h - total_block_h) / 2)
    
    if block_start_y < real_top_y + S(4) then
        block_start_y = real_top_y + S(4)
    end
    
    local tab_draw_y = block_start_y
    local top_box_y = tab_draw_y + tab_h + tab_sp_y
    
    local pr_y = top_box_y
    local menu_y = top_box_y
    local fx_y = menu_y + exact_menu_h + gap_y
    
    self._split_preview_dimen = Geom:new{ x = pr_x, y = pr_y, w = pr_w, h = pr_h }

    local bm_count = #(self:_getAllBookmarks() or {})
    local hl_count = #(self._cached_hl or {})
    local note_count = #(self._cached_notes or {})

    local b_thick = S(2)
    local tab_sp = S(6)
    local current_tab_x = pr_x
    local r = math.floor(tab_h / 2)

    local active_sort_icon = (self._sort_order == "asc") and self.icon_sort_asc or self.icon_sort_desc
    local sort_tsz = active_sort_icon and active_sort_icon:getSize() or {w = S(18), h = S(18)}
    local sort_tab_w = sort_tsz.w + S(16)

    paintRoundRect(bb, current_tab_x, tab_draw_y, sort_tab_w, tab_h, r, Blitbuffer.COLOR_BLACK)
    paintRoundRect(bb, current_tab_x + b_thick, tab_draw_y + b_thick, sort_tab_w - b_thick*2, tab_h - b_thick*2, math.max(1, r - b_thick), Blitbuffer.COLOR_WHITE)

    local stx = current_tab_x + math.floor((sort_tab_w - sort_tsz.w) / 2)
    local sty = tab_draw_y + math.floor((tab_h - sort_tsz.h) / 2)

    if active_sort_icon then
        active_sort_icon:paintTo(bb, stx, sty)
    end

    self._tab_sort_dimen = Geom:new{ x = current_tab_x, y = tab_draw_y, w = sort_tab_w, h = tab_h }
    current_tab_x = current_tab_x + sort_tab_w + tab_sp

        local function drawTabWithSVG(id, icon_widget, count_num)
            local is_active = (self._active_tab == id)

            -- Lazy caching para los contadores de pestañas
            if not self._tw_tab_count_normal then
                self._tw_tab_count_normal = TextWidget:new{ text = "", face = Font:getFace("cfont", font_sz_chiquito), fgcolor = Blitbuffer.COLOR_BLACK }
                self._tw_tab_count_bold   = TextWidget:new{ text = "", face = Font:getFace("cfont", font_sz_chiquito), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
            end
            
            -- Con un color elegido, la pestaña muestra el círculo de ese color y su cantidad
            local sel_key, sel_count = nil, nil
            if is_active then sel_key, sel_count = self:_getSelectedColorInfo(id) end
            if sel_key then count_num = sel_count end

            local tw_cnt = is_active and self._tw_tab_count_bold or self._tw_tab_count_normal
            tw_cnt.text = nil
            tw_cnt.fgcolor = is_active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
            -- count_num == nil (imagenes sin escanear): solo el icono, sin parentesis
            local has_count = (count_num ~= nil)
            tw_cnt:setText(has_count and ("(" .. tostring(count_num) .. ")") or "")
            
            local isz = icon_widget and icon_widget:getSize() or {w = S(18), h = S(18)}
            local nsz = { w = 0, h = 0 }
            local sel_name_str = nil

            if sel_key then
                local dot_d = math.min(isz.w, isz.h)
                isz = { w = dot_d, h = dot_d }

                -- Preparar el nombre del color
                sel_name_str = HL_COLOR_NAMES[sel_key] or (sel_key:sub(1,1):upper() .. sel_key:sub(2))
                if not self._tw_tab_color_name then
                    self._tw_tab_color_name = TextWidget:new{ text = "", face = Font:getFace("cfont", font_sz_chiquito), bold = true, fgcolor = Blitbuffer.COLOR_WHITE }
                end
                self._tw_tab_color_name.text = nil
                self._tw_tab_color_name:setText(sel_name_str)
                nsz = self._tw_tab_color_name:getSize()
            end

            local csz = has_count and tw_cnt:getSize() or { w = 0, h = 0 }
            local gap = has_count and S(4) or 0

            -- Flechita para elegir color (solo en la pestaña activa y con más de un color)
            local show_arrow = is_active and (id == "highlights" or id == "notes") and self:_hasMultiColor(id)
            local arrow_w, arrow_h, arrow_gap = S(16), S(16), S(3)
            local arrow_extra = show_arrow and (arrow_w + arrow_gap) or 0

            -- Si hay nombre de color sumamos su ancho y un gap adicional
            local name_extra_w = sel_key and (nsz.w + gap) or 0
            local content_w = arrow_extra + isz.w + gap + name_extra_w + csz.w
            local tab_w = content_w + S(16)

            if is_active then
                -- Relleno negro sólido completo sin marco blanco interno
                paintRoundRect(bb, current_tab_x, tab_draw_y, tab_w, tab_h, r, Blitbuffer.COLOR_BLACK)
            else
                -- Pestaña inactiva: gris, sin contorno
                paintRoundRect(bb, current_tab_x, tab_draw_y, tab_w, tab_h, r, Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_GRAY_D or Blitbuffer.COLOR_LIGHT_GRAY)
            end

            local lead_x = current_tab_x + math.floor((tab_w - content_w) / 2)
            local ix = lead_x
            local nx = ix + isz.w + gap
            local cx = nx + name_extra_w
            
            local iy = tab_draw_y + math.floor((tab_h - isz.h) / 2)
            local ny = tab_draw_y + math.floor((tab_h - nsz.h) / 2) - S(1)
            local cy = tab_draw_y + math.floor((tab_h - csz.h) / 2) - S(1)

            if show_arrow then
                -- Flechita (chevron) a la derecha del contenido de la pestaña
                local ax = cx + csz.w + arrow_gap
                local ay = tab_draw_y + math.floor((tab_h - arrow_h) / 2)
                local arrow_icon = self._color_menu_is_open and self.icon_tab_chev_up or self.icon_tab_chev_down
                if arrow_icon then
                    -- Blanco sobre la pestaña negra: fondo blanco + ícono negro + inversión
                    bb:paintRect(ax, ay, arrow_w, arrow_h, Blitbuffer.COLOR_WHITE)
                    arrow_icon:paintTo(bb, ax, ay)
                    bb:invertRect(ax, ay, arrow_w, arrow_h)
                end
                local hit_x = ax - S(8)
                self._tab_arrow_dimen = Geom:new{
                    x = hit_x, y = tab_draw_y,
                    w = math.max(S(30), (current_tab_x + tab_w) - hit_x), h = tab_h,
                }
                self._tab_arrow_tab_dimen = Geom:new{ x = current_tab_x, y = tab_draw_y, w = tab_w, h = tab_h }
            end

            if sel_key then
                self:_paintColorDot(bb, ix, iy, isz.w, sel_key, Blitbuffer.COLOR_WHITE)
                self._tw_tab_color_name:paintTo(bb, nx, ny)
            elseif icon_widget then
                if is_active then
                    -- Inversión del icono sobre fondo negro sólido para que quede blanco puro
                    bb:paintRect(ix, iy, isz.w, isz.h, Blitbuffer.COLOR_WHITE)
                    icon_widget:paintTo(bb, ix, iy)
                    bb:invertRect(ix, iy, isz.w, isz.h)
                else
                    icon_widget:paintTo(bb, ix, iy)
                end
            end

            if has_count then tw_cnt:paintTo(bb, cx, cy) end

            local dimen = Geom:new{ x = current_tab_x, y = tab_draw_y, w = tab_w, h = tab_h }
            current_tab_x = current_tab_x + tab_w + tab_sp 
            return dimen
        end        
    
    self._tab_arrow_dimen = nil
    self._tab_arrow_tab_dimen = nil
    self._tab_bm_dimen   = drawTabWithSVG("bookmarks", self.icon_tab_bm, bm_count)
    self._tab_hl_dimen   = drawTabWithSVG("highlights", self.icon_tab_hl, hl_count)
    self._tab_note_dimen = drawTabWithSVG("notes", self.icon_tab_note, note_count)

    self._tab_review_dimen = nil
    self._tab_img_dimen = nil
    if self._imgTabEnabled then
        if self._active_tab == "images" and not self._img_scan_requested then
            self._img_scan_requested = true
            self:_imgEnsureScan()
        end
        local img_count = self:_imgCount()
        self._tab_img_dimen = drawTabWithSVG("images", self.icon_tab_img, img_count)
    end

    -- Botón "Study" (repaso espaciado) a la derecha de las pestañas; solo si el ajuste está activo
    if require("srs").isStudyActive(self.ui) then
        self._tab_review_dimen = self:_paintStudyButton(bb, tab_draw_y, tab_h, current_tab_x, sw - pr_x, font_sz_chiquito + S(1))
    end

    local card_x = pr_x
    local card_y = pr_y
    local card_w = pr_w
    local card_h = pr_h + status_h
    
    self._card_snap = self:_snapCorners(bb, card_x, card_y, card_w, card_h, box_radius)   -- esquinas de afuera (fondo)
    paintRoundRect(bb, card_x, card_y, card_w, card_h, box_radius, Blitbuffer.COLOR_BLACK)
    paintRoundRect(bb, card_x + b_thick, card_y + b_thick, card_w - b_thick*2, card_h - b_thick*2, math.max(1, box_radius - b_thick), Blitbuffer.COLOR_WHITE)

    local tile = self._grid_tiles[2] or {}
    -- Si el panel de detalles esta abierto (se pinto en el frame anterior) cubre toda la tarjeta:
    -- no se gasta tiempo en dibujar la miniatura de abajo
    local card_covered = self._details_open and self._details_panel_dimen ~= nil and not self._details_resync_pending
    if card_covered then
        -- (nada: lo tapa el panel)
    elseif tile.tile_bb then
        local target_w = pr_w - b_thick*2
        local target_h = pr_h - b_thick
        local tw, th = tile.tile_bb:getWidth(), tile.tile_bb:getHeight()

        local src_x, src_y = 0, 0
        local blit_w, blit_h = tw, th
        
        if blit_w > target_w then
            src_x = math.floor((blit_w - target_w) / 2)
            blit_w = target_w
        end
        if blit_h > target_h then
            src_y = math.floor((blit_h - target_h) / 2)
            blit_h = target_h
        end

        local ox = card_x + b_thick + math.floor((target_w - blit_w) / 2)
        local oy = card_y + b_thick + math.floor((target_h - blit_h) / 2)
        
        if ox < 0 then src_x = src_x - ox; blit_w = blit_w + ox; ox = 0 end
        if oy < 0 then src_y = src_y - oy; blit_h = blit_h + oy; oy = 0 end
        if ox + blit_w > sw then blit_w = sw - ox end
        if oy + blit_h > sh then blit_h = sh - oy end
        
        if blit_w > 0 and blit_h > 0 then
            bb:blitFrom(tile.tile_bb, ox, oy, src_x, src_y, blit_w, blit_h)

            -- Recorte suave de las esquinas superiores de la miniatura para no deformar la curva
            local r_in = math.max(1, box_radius - b_thick)
            for j = 0, box_radius - 1 do
                local arc_out = math.ceil(math.sqrt(box_radius*box_radius - (box_radius - j - 0.5)*(box_radius - j - 0.5)))
                local arc_in = 0
                if j >= b_thick and (j - b_thick) < r_in then
                    local k = j - b_thick
                    arc_in = math.ceil(math.sqrt(r_in*r_in - (r_in - k - 0.5)*(r_in - k - 0.5)))
                end
                local w_c = arc_out - arc_in
                if w_c > 0 then
                    bb:paintRect(card_x + box_radius - arc_out, card_y + j, w_c, 1, Blitbuffer.COLOR_BLACK)
                    bb:paintRect(card_x + card_w - box_radius + arc_in, card_y + j, w_c, 1, Blitbuffer.COLOR_BLACK)
                end
            end
        end

    elseif tile.error then
        local err_tw = TextWidget:new{ text = "!", face = Font:getFace("cfont", S(32)), fgcolor = Blitbuffer.COLOR_BLACK }
        local etsz = err_tw:getSize()
        err_tw:paintTo(bb, card_x + math.floor((card_w - etsz.w) / 2), card_y + math.floor((pr_h - etsz.h) / 2))
    elseif tile.loading then
        bb:paintRect(card_x + math.floor(card_w / 2) - 1, card_y + math.floor(pr_h / 2) - 1, 2, 2, Blitbuffer.COLOR_GRAY)
    end
    
    local active_pol_icon = nil
    local text_str = "—"
    local pd = self._page_data[self._cur_page]
    
    local function safe_string(str, max_len)
        if string.len(str) > max_len then return string.sub(str, 1, max_len - 3) .. "..." end
        return str
    end

    local function get_specific_style_icon(default_fallback)
        if self._hl_filter ~= nil then
            return default_fallback
        end
        local it_type = self._split_selected_item and self._split_selected_item.type
        if it_type == "invert" then return self.icon_picker_inv
        elseif it_type == "underline" then return self.icon_picker_ul
        elseif it_type == "strikethrough" then return self.icon_picker_st
        elseif it_type == "normal" then return self.icon_picker_hl
        end
        return default_fallback
    end

    if self._active_tab == "highlights" then
        active_pol_icon = get_specific_style_icon(self.icon_pol_hl)
        if self._split_selected_item and self._split_selected_item.page == self._cur_page and self._split_selected_item.text ~= "" then
            text_str = "“" .. safe_string(self._split_selected_item.text, 500) .. "”"
        elseif self._hl_filter and pd and pd.texts_by_type and pd.texts_by_type[self._hl_filter] then
            text_str = "“" .. safe_string(pd.texts_by_type[self._hl_filter], 500) .. "”"
        elseif pd and pd.text then
            text_str = "“" .. safe_string(pd.text, 500) .. "”"
        end
    elseif self._active_tab == "notes" then
        active_pol_icon = get_specific_style_icon(self.icon_pol_note)
        if self._split_selected_item and self._split_selected_item.page == self._cur_page and self._split_selected_item.note ~= "" then
            text_str = safe_string(self._split_selected_item.note, 500)
        elseif pd and pd.note then
            text_str = safe_string(pd.note, 500)
        end
    elseif self._active_tab == "images" and self._imgTabEnabled then
        active_pol_icon = self:_imgChinIcon(self._split_selected_item)
        text_str = self:_imgChinText(self._split_selected_item)
    elseif self._active_tab == "bookmarks" then
        active_pol_icon = self.icon_pol_bm
        local is_bmed = false
        local raw_date = nil
        
        local function find_deep_date()
            local target_p = tonumber(self._cur_page)
            local possible_sources = {
                self.ui.annotation and self.ui.annotation.annotations,
                self.ui.doc_props and self.ui.doc_props.bookmarks,
                self.ui.bookmark and self.ui.bookmark._bookmarks,
                self.ui.bookmark and self.ui.bookmark.bookmarks
            }
            for _, src in ipairs(possible_sources) do
                if type(src) == "table" then
                    for k, v in pairs(src) do
                        if type(v) == "table" then
                            local p = self:_getNumericalPage(v) or tonumber(v.page) or tonumber(v.pos0)
                            if not p and type(v.page) == "string" and self.ui.document and self.ui.document.getPageFromXPointer then
                                pcall(function() p = self.ui.document:getPageFromXPointer(v.page) end)
                            end
                            if p == target_p then
                                local d = v.datetime or v.time or v.date or v.timestamp
                                if d then return d end
                            end
                        else
                            if tonumber(k) == target_p and (type(v) == "string" or type(v) == "number") then return v end
                        end
                    end
                end
            end
            return nil
        end
        
        do
            local ann = self.ui.annotation and self.ui.annotation.annotations
            local ann_n = type(ann) == "table" and #ann or 0
            local cm = self._chin_date_memo
            if cm and cm.page == self._cur_page and cm.n == ann_n and cm.bms == self._cached_bms then
                raw_date = cm.date
            else
                raw_date = find_deep_date()
                self._chin_date_memo = { page = self._cur_page, n = ann_n, bms = self._cached_bms, date = raw_date }
            end
        end
        if raw_date then is_bmed = true end
        if not is_bmed then
            for _, bmp in ipairs(self:_getAllBookmarks()) do
                if tonumber(bmp) == tonumber(self._cur_page) then is_bmed = true; break end
            end
        end
        
        if is_bmed then
            if raw_date then
                local y, m, d
                if type(raw_date) == "number" then
                    y = os.date("%Y", raw_date); m = os.date("%m", raw_date); d = os.date("%d", raw_date)
                else
                    local raw_s = tostring(raw_date)
                    y, m, d = raw_s:match("(%d%d%d%d)[%-%/%.%s_](%d%d)[%-%/%.%s_](%d%d)")
                    if not y then d, m, y = raw_s:match("(%d%d)[%-%/%.%s_](%d%d)[%-%/%.%s_](%d%d%d%d)") end
                end
                if y and m and d then
                    local months = { _("Jan"), _("Feb"), _("Mar"), _("Apr"), _("May"), _("Jun"), _("Jul"), _("Aug"), _("Sep"), _("Oct"), _("Nov"), _("Dec") }
                    text_str = _("Added on") .. " " .. (months[tonumber(m)] or m) .. " " .. tonumber(d) .. ", " .. y
                else
                    text_str = _("Added on") .. " " .. tostring(raw_date)
                end
            else
                text_str = _("Bookmarked")
            end
        end
    end

    local pad_x = S(14)
    local gap = S(8)
    
    local isz = active_pol_icon and active_pol_icon:getSize() or {w = S(20), h = S(20)}
    local text_max_w = card_w - (pad_x * 2) - isz.w - gap
    local clean_str = text_str:gsub("\n", " "):gsub("\r", "")
    
    local ix = card_x + pad_x
    local iy = card_y + pr_h + math.floor((status_h - isz.h) / 2)
    
    if active_pol_icon then
        active_pol_icon:paintTo(bb, ix, iy)
    end
    
    local tx = ix + isz.w + gap
    if not self._tw_preview_text then
        self._tw_preview_text = TextWidget:new{ text = "", face = Font:getFace("cfont", font_sz_chiquito), bold = true, fgcolor = Blitbuffer.COLOR_BLACK, truncate_with_ellipsis = true }
    end
    self._tw_preview_text.max_width = text_max_w
    self._tw_preview_text.text = nil
    self._tw_preview_text:setText(clean_str)
    
    local tsz = self._tw_preview_text:getSize()
    local ty = card_y + pr_h + math.floor((status_h - tsz.h) / 2)
    
    self._tw_preview_text:paintTo(bb, tx, ty)

    -- Regiones de la polaroid completa y de su linea de texto (chin) + panel de detalles
    self._split_card_dimen = Geom:new{ x = card_x, y = card_y, w = card_w, h = card_h }
    self._split_chin_dimen = Geom:new{ x = card_x, y = card_y + pr_h, w = card_w, h = status_h }
    -- Termino la tarjeta: lo que asomo (miniatura, etc.) fuera de las esquinas redondeadas se restaura al fondo
    self:_restoreCorners(bb, self._card_snap)
    self._card_snap = nil

    if not (self._details_open and self._details_expanded) then
        local okp, errp = pcall(self._paintDetailsPanel, self, bb, card_x, card_y, card_w, card_h, box_radius, b_thick, lm_x + lm_w - card_x)
        if not okp then
            logger.warn("page-scrubber details panel error:", errp)
            self._details_open = false
        end
        if card_covered and not self._details_panel_dimen then
            UIManager:setDirty(self, "ui", self.dimen)   -- la tarjeta se salto y el panel no se pinto: repintar
        end
    end

    self._btn_delete_dimen = nil
    self._btn_confirm_del_dimen = nil
    self._btn_edit_dimen = nil
    self._btn_type_dimen = nil
    self._type_picker_dimens = nil

    local show_delete_btn = false
    
    if not self._is_comic then
        if self._active_tab == "notes" or self._active_tab == "highlights" then
            if self._split_selected_item and self._split_selected_item.page == self._cur_page then
                if self._active_tab == "notes" then
                    show_delete_btn = (self._split_selected_item.note and self._split_selected_item.note ~= "")
                else
                    show_delete_btn = true
                end
            else
                local items = (self._active_tab == "notes") and self._cached_notes or self._cached_hl
                for _, it in ipairs(items or {}) do
                    if it.page == self._cur_page then
                        show_delete_btn = true
                        break
                    end
                end
            end
        end
    end

    if show_delete_btn and not self._hide_action_buttons then
        local bw, bh = S(56), S(56)
        local btn_x = card_x + S(20)
        local btn_y = card_y + pr_h - bh - S(76)
        local btn_thick = S(2)
        local btn_radius = S(16)

        -- Trash Button (Blanco por defecto, Activo Negro)
        local is_trash_active = self._show_delete_confirm or (self._pressed_btn == "delete")
        paintRoundRect(bb, btn_x, btn_y, bw, bh, btn_radius, Blitbuffer.COLOR_BLACK)
        if not is_trash_active then
            paintRoundRect(bb, btn_x + btn_thick, btn_y + btn_thick, bw - btn_thick*2, bh - btn_thick*2, math.max(1, btn_radius - btn_thick), Blitbuffer.COLOR_WHITE)
        end

        if self.icon_btn_trash then
            local isz_btn = self.icon_btn_trash:getSize()
            local bix = btn_x + math.floor((bw - isz_btn.w)/2)
            local biy = btn_y + math.floor((bh - isz_btn.h)/2)
            if is_trash_active then
                bb:paintRect(bix, biy, isz_btn.w, isz_btn.h, Blitbuffer.COLOR_WHITE)
                self.icon_btn_trash:paintTo(bb, bix, biy)
                bb:invertRect(bix, biy, isz_btn.w, isz_btn.h)
            else
                self.icon_btn_trash:paintTo(bb, bix, biy)
            end
        end
        self._btn_delete_dimen = Geom:new{ x = btn_x, y = btn_y, w = bw, h = bh }

        -- Edit Button (Blanco por defecto, Activo Negro)
        local ebw, ebh = bw, bh
        local edit_gap = S(8)
        local ebtn_x = btn_x
        local ebtn_y = btn_y - ebh - edit_gap
        
        local is_edit_active = (self._pressed_btn == "edit")
        paintRoundRect(bb, ebtn_x, ebtn_y, ebw, ebh, btn_radius, Blitbuffer.COLOR_BLACK)
        if not is_edit_active then
            paintRoundRect(bb, ebtn_x + btn_thick, ebtn_y + btn_thick, ebw - btn_thick*2, ebh - btn_thick*2, math.max(1, btn_radius - btn_thick), Blitbuffer.COLOR_WHITE)
        end

        if self.icon_btn_edit then
            local isz_edit = self.icon_btn_edit:getSize()
            local eix = ebtn_x + math.floor((ebw - isz_edit.w)/2)
            local eiy = ebtn_y + math.floor((ebh - isz_edit.h)/2)
            if is_edit_active then
                bb:paintRect(eix, eiy, isz_edit.w, isz_edit.h, Blitbuffer.COLOR_WHITE)
                self.icon_btn_edit:paintTo(bb, eix, eiy)
                bb:invertRect(eix, eiy, isz_edit.w, isz_edit.h)
            else
                self.icon_btn_edit:paintTo(bb, eix, eiy)
            end
        end
        self._btn_edit_dimen = Geom:new{ x = ebtn_x, y = ebtn_y, w = ebw, h = ebh }

        -- Type (Highlight Color) Button (Blanco por defecto, Activo Negro)
        local tbw, tbh = bw, bh
        local tbtn_x = btn_x
        local tbtn_y = ebtn_y - tbh - edit_gap

        local is_type_active = self._show_type_picker or (self._pressed_btn == "type")
        paintRoundRect(bb, tbtn_x, tbtn_y, tbw, tbh, btn_radius, Blitbuffer.COLOR_BLACK)
        if not is_type_active then
            paintRoundRect(bb, tbtn_x + btn_thick, tbtn_y + btn_thick, tbw - btn_thick*2, tbh - btn_thick*2, math.max(1, btn_radius - btn_thick), Blitbuffer.COLOR_WHITE)
        end

        if self.icon_btn_type then
            local isz_type = self.icon_btn_type:getSize()
            local tix = tbtn_x + math.floor((tbw - isz_type.w)/2)
            local tiy = tbtn_y + math.floor((tbh - isz_type.h)/2)
            if is_type_active then
                bb:paintRect(tix, tiy, isz_type.w, isz_type.h, Blitbuffer.COLOR_WHITE)
                self.icon_btn_type:paintTo(bb, tix, tiy)
                bb:invertRect(tix, tiy, isz_type.w, isz_type.h)
            else
                self.icon_btn_type:paintTo(bb, tix, tiy)
            end
        end
        self._btn_type_dimen = Geom:new{ x = tbtn_x, y = tbtn_y, w = tbw, h = tbh }

        if self._show_delete_confirm then
            local cw = card_w - S(40)
            local ch = S(56)
            local cx = card_x + S(20)
            local cy = card_y + pr_h - ch - S(10)
            local b_thick = S(2)

            local is_del_pressed = (self._pressed_btn == "confirm_del")
            
            -- Fondo negro por defecto. Si se presiona, el interior se vuelve blanco
            paintRoundRect(bb, cx, cy, cw, ch, S(14), Blitbuffer.COLOR_BLACK)
            if is_del_pressed then
                paintRoundRect(bb, cx + b_thick, cy + b_thick, cw - b_thick*2, ch - b_thick*2, math.max(1, S(14) - b_thick), Blitbuffer.COLOR_WHITE)
            end

            local fg_col = is_del_pressed and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
            if not self._tw_confirm_del then
                self._tw_confirm_del = TextWidget:new{ text = _("Delete"), face = self.font_ch, bold = true }
            end
            self._tw_confirm_del.fgcolor = fg_col
            local ctsz = self._tw_confirm_del:getSize()
            self._tw_confirm_del:paintTo(bb, cx + math.floor((cw - ctsz.w)/2), cy + math.floor((ch - ctsz.h)/2))

            self._btn_confirm_del_dimen = Geom:new{ x = cx, y = cy, w = cw, h = ch }
        end

        if self._show_type_picker then
            local cw = card_w - S(40)
            local ch = S(56)
            local cx = card_x + S(20)
            local cy = card_y + pr_h - ch - S(10)
            local b_thick = S(2)

            local current_drawer = "lighten"
            if self._split_selected_item and self._split_selected_item.annotation then
                current_drawer = self._split_selected_item.annotation.drawer or "lighten"
            else
                local pd_edit = self._page_data[self._cur_page]
                if self._hl_filter then
                    if self._hl_filter == "normal" then current_drawer = "lighten"
                    elseif self._hl_filter == "invert" then current_drawer = "invert"
                    elseif self._hl_filter == "underline" then current_drawer = "underscore"
                    elseif self._hl_filter == "strikethrough" then current_drawer = "strikeout"
                    end
                elseif pd_edit and pd_edit.hl_types then
                    if pd_edit.hl_types["normal"] then current_drawer = "lighten"
                    elseif pd_edit.hl_types["underline"] then current_drawer = "underscore"
                    elseif pd_edit.hl_types["invert"] then current_drawer = "invert"
                    elseif pd_edit.hl_types["strikethrough"] then current_drawer = "strikeout"
                    end
                end
            end

            local type_defs = {
                { key = "lighten",    icon = self.icon_picker_hl },
                { key = "underscore", icon = self.icon_picker_ul },
                { key = "strikeout",  icon = self.icon_picker_st },
                { key = "invert",     icon = self.icon_picker_inv },
            }
            -- Círculo con el color del highlight (no aparece en "invert")
            local color_key = self:_getPickerColor(current_drawer)

            -- Una fila, dos cajas separadas: [ los 4 tipos ]  [ círculo de color ]
            local color_gap = S(6)
            local color_sz  = math.floor(ch * 0.68)   -- el circulo de color pesa menos que los 4 tipos
            local types_w = cw - (color_key and (color_gap + color_sz) or 0)
            local slot_w = math.floor((types_w - S(8)) / #type_defs)

            -- Diseño completamente plano sin sombreado
            paintRoundRect(bb, cx, cy, types_w, ch, S(14), Blitbuffer.COLOR_BLACK)
            paintRoundRect(bb, cx + b_thick, cy + b_thick, types_w - b_thick*2, ch - b_thick*2, math.max(1, S(14) - b_thick), Blitbuffer.COLOR_WHITE)

            -- Zona donde se centra el menú de colores: la tarjeta, sin pisar los 3 botones de la izquierda
            local free_x = card_x + S(20) + S(56) + S(12)
            local free_r = card_x + card_w - S(12)
            self._color_menu_region = Geom:new{ x = free_x, y = card_y, w = math.max(1, free_r - free_x), h = pr_h }
            -- El borde inferior del menú coincide con el borde inferior del botón de la papelera
            self._color_menu_bottom = card_y + pr_h - S(76)

            self._type_picker_dimens = {}
            for idx, td in ipairs(type_defs) do
                local slot_x = cx + S(4) + (idx - 1) * slot_w
                local is_pressed = (self._pressed_btn == "type_" .. td.key)
                local is_selected = (current_drawer == td.key)

                if td.icon then
                    local tisz = td.icon:getSize()
                    local circle_d = S(36)
                    local circle_x = slot_x + math.floor((slot_w - circle_d) / 2)
                    local circle_y = cy + math.floor((ch - circle_d) / 2)
                    
                    if is_pressed then
                        paintRoundRect(bb, circle_x, circle_y, circle_d, circle_d, math.floor(circle_d / 2), Blitbuffer.COLOR_DARK_GRAY)
                    elseif is_selected then
                        paintRoundRect(bb, circle_x, circle_y, circle_d, circle_d, math.floor(circle_d / 2), Blitbuffer.COLOR_LIGHT_GRAY)
                    end
                    
                    local tix = slot_x + math.floor((slot_w - tisz.w) / 2)
                    local tiy = cy + math.floor((ch - tisz.h) / 2)
                    td.icon:paintTo(bb, tix, tiy)
                end

                table.insert(self._type_picker_dimens, {
                    key = td.key,
                    dimen = Geom:new{ x = slot_x, y = cy, w = slot_w, h = ch }
                })
            end

            if color_key then
                local box_x = cx + types_w + color_gap
                local box_y = cy + math.floor((ch - color_sz) / 2)
                self:_paintPickerColorBox(bb, box_x, box_y, color_sz, color_sz, color_key, S(14), (self._pressed_btn == "type___color"))
                table.insert(self._type_picker_dimens, {
                    key = "__color",
                    dimen = Geom:new{ x = box_x, y = box_y, w = color_sz, h = color_sz }
                })
            end
        end
    end

    -- Panel expandido: el menu derecho se pinta y luego se tapa; se guarda el fondo de esa columna para
    -- restaurarlo (con fondo de pantalla un rectangulo blanco se notaria)
    if self._details_open and self._details_expanded then
        self._col_snap = self:_snapRegion(bb, card_x + card_w, card_y, (lm_x + lm_w) - (card_x + card_w), card_h)
    else
        self._col_snap = nil
    end

    local fixed_page = self._split_fixed_page or self._origin_page
    local fx_w = lm_w
    local is_f_sel = (self._cur_page == fixed_page)

    local is_page_bmed = false
    for _, b in ipairs(self:_getAllBookmarks()) do
        if tonumber(b) == tonumber(fixed_page) then is_page_bmed = true end
    end

    -- Fila fija: borde negro siempre; seleccionada = relleno gris muy clarito (texto e ícono quedan negros)
    local fixed_fill = is_f_sel and (Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_GRAY_D or Blitbuffer.COLOR_LIGHT_GRAY) or Blitbuffer.COLOR_WHITE
    paintRoundRect(bb, lm_x, fx_y, lm_w, fx_h, box_radius, Blitbuffer.COLOR_BLACK)
    paintRoundRect(bb, lm_x + b_thick, fx_y + b_thick, lm_w - b_thick*2, fx_h - b_thick*2, math.max(1, box_radius - b_thick), fixed_fill)
    
    local active_fixed_icon = is_page_bmed and self.icon_box_minus_fill or self.icon_box_plus
    local bsz_f = active_fixed_icon and active_fixed_icon:getSize() or {w = S(22), h = S(22)}
    local btn_xf = lm_x + lm_w - bsz_f.w - S(12)
    
    if not self._tw_row_normal then
        self._tw_row_normal = TextWidget:new{ text = "", face = Font:getFace("cfont", S_MEDIANO), fgcolor = Blitbuffer.COLOR_BLACK }
        self._tw_row_bold   = TextWidget:new{ text = "", face = Font:getFace("cfont", S_MEDIANO), bold = true, fgcolor = Blitbuffer.COLOR_WHITE }
    end
    
    local tw_pg_f = is_f_sel and self._tw_row_bold or self._tw_row_normal
    tw_pg_f.max_width = nil 
    tw_pg_f.text = nil
    tw_pg_f.fgcolor = Blitbuffer.COLOR_BLACK
    
    local disp_f = self:_getDisplayPageInfo(fixed_page)
    tw_pg_f:setText(tostring(disp_f))
    
    local pt_sz = tw_pg_f:getSize()
    local f_area_x = lm_x + b_thick
    local f_area_w = (btn_xf - S(8)) - f_area_x
    local f_show_dot = is_f_sel and self._details_open
    local ptx = f_area_x + math.max(f_show_dot and S(30) or S(10), math.floor((f_area_w - pt_sz.w) / 2))
    local pty = fx_y + math.floor((fx_h - pt_sz.h) / 2) + S(2)

    if f_show_dot then
        local dot_d = S(8)
        paintRoundRect(bb, lm_x + b_thick + S(17), fx_y + math.floor((fx_h - dot_d) / 2), dot_d, dot_d, math.floor(dot_d / 2), Blitbuffer.COLOR_GRAY_9 or Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_DARK_GRAY)
    end
    tw_pg_f:paintTo(bb, ptx, pty)

    if active_fixed_icon then
        local ix = btn_xf
        local iy = fx_y + math.floor((fx_h - bsz_f.h)/2)
        
        active_fixed_icon:paintTo(bb, ix, iy)
    end

    local row_clickable_w = (btn_xf - S(10)) - lm_x
    self._split_fixed_row_dimen = Geom:new{ x = lm_x, y = fx_y, w = row_clickable_w, h = fx_h }
    self._split_fixed_toggle_dimen = Geom:new{ x = btn_xf - S(10), y = fx_y, w = bsz_f.w + S(20), h = fx_h }

    local filter_defs = {
        { key = "normal",        icon_on = self.icon_filter_hl_on,  icon_off = self.icon_filter_hl_off },
        { key = "underline",     icon_on = self.icon_filter_ul_on,  icon_off = self.icon_filter_ul_off },
        { key = "invert",        icon_on = self.icon_filter_inv_on, icon_off = self.icon_filter_inv_off },
        { key = "strikethrough", icon_on = self.icon_filter_st_on,  icon_off = self.icon_filter_st_off },
    }
    local present_filters = {}
    local types_source = self:_getTypesPresent()
    if self._active_tab == "highlights" or self._active_tab == "notes" then
        for _, fd in ipairs(filter_defs) do
            if types_source and types_source[fd.key] then table.insert(present_filters, fd) end
        end
    end

    if self._active_tab == "images" and self._imgTabEnabled then
        present_filters = self:_imgFilterDefs()
    end

    local other_items = self:_getFilteredActiveList()
    local ITEMS_PER_PAGE
    local needs_pagination = false
    
    if #other_items <= num_rows then
        ITEMS_PER_PAGE = num_rows
        needs_pagination = false
    else
        ITEMS_PER_PAGE = num_rows - 1
        needs_pagination = true
    end

    if ITEMS_PER_PAGE < 1 then ITEMS_PER_PAGE = 1 end

    -- Asegurar que en Destacados/Notas solo quede un ítem seleccionado a la vez
    if self._active_tab ~= "bookmarks" then
        local found = nil
        local cur_disp = tostring(self:_getDisplayPageInfo(self._cur_page))

        -- Restauración local post-edición
        local target_order = PageScrubber._last_edited_order or self._target_hl_order
        if target_order then
            for _, it in ipairs(other_items) do
                if type(it) == "table" and it.disp_page == cur_disp and it.order == target_order then
                    found = it
                    break
                end
            end
            if not found then
                for _, it in ipairs(other_items) do
                    if type(it) == "table" and it.page == self._cur_page and it.order == target_order then
                        found = it
                        break
                    end
                end
            end

            if found and found.page and found.page ~= self._cur_page then
                self._cur_page = found.page
                self._slider.value = self._cur_page
                self._force_menu_sync = true
            end

            PageScrubber._last_edited_order = nil
            self._target_hl_order = nil
        end

        -- 2. Navegación normal: conservar la selección previa solo si pertenece a la página actual
        if not found and self._split_selected_item then
            local sel = self._split_selected_item
            local is_on_current_page = (sel.disp_page and sel.disp_page == cur_disp) or (sel.page == self._cur_page)
            if is_on_current_page then
                for _, it in ipairs(other_items) do
                    if it == sel then
                        found = it
                        break
                    end
                end
            end
        end

        -- 3. Si cambiamos de página con el slider o swipe, seleccionar la primera anotación de la página activa
        if not found then
            for _, it in ipairs(other_items) do
                if type(it) == "table" and (it.disp_page == cur_disp or it.page == self._cur_page) then
                    found = it
                    break
                end
            end
        end

        self._split_selected_item = found
    end

    if self._force_menu_sync then
        local target_idx = nil
        for i, it in ipairs(other_items) do
            if self._active_tab == "bookmarks" then
                if tonumber(it) == tonumber(self._cur_page) then
                    target_idx = i; break
                end
            else
                if self._split_selected_item and it == self._split_selected_item then
                    target_idx = i; break
                elseif not self._split_selected_item and it.page == self._cur_page then
                    target_idx = i; break
                end
            end
        end
        if target_idx then
            self._split_bm_page = math.ceil(target_idx / ITEMS_PER_PAGE)
        end
        self._force_menu_sync = false
    end
    
    local total_pages = math.max(1, math.ceil(#other_items / ITEMS_PER_PAGE))
    local cur_page = tonumber(self._split_bm_page) or 1
    if cur_page > total_pages then cur_page = total_pages end
    if cur_page < 1 then cur_page = 1 end
    self._split_bm_page = cur_page
    
    local start_idx, end_idx = 1, 0
    if #other_items > 0 then
        start_idx = (cur_page - 1) * ITEMS_PER_PAGE + 1
        if start_idx > #other_items then
            cur_page = 1
            self._split_bm_page = 1
            start_idx = 1
        end
        end_idx = math.min(cur_page * ITEMS_PER_PAGE, #other_items)
    end

    self._split_rows = {}

    -- Tarjeta flotante con 4 esquinas redondeadas y grosor b_thick unificado
    paintRoundRect(bb, lm_x, menu_y, lm_w, exact_menu_h, box_radius, Blitbuffer.COLOR_BLACK)
    paintRoundRect(bb, lm_x + b_thick, menu_y + b_thick, lm_w - b_thick*2, exact_menu_h - b_thick*2, math.max(1, box_radius - b_thick), Blitbuffer.COLOR_WHITE)

    bb:paintRect(lm_x + b_thick, menu_y + header_h - S(2), lm_w - b_thick*2, S(2), Blitbuffer.COLOR_LIGHT_GRAY)

    if not self._tw_header_page then
        self._tw_header_page = TextWidget:new{ text = _("Page"), face = Font:getFace("cfont", font_sz_chiquito), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
        self._tw_empty_list  = TextWidget:new{ text = "—", face = Font:getFace("cfont", self.S_BOTTOM_GRAY or S_MEDIANO), fgcolor = Blitbuffer.COLOR_DARK_GRAY }
    end

    local hsz = self._tw_header_page:getSize()
    local htx = lm_x + S(15)
    local hty = menu_y + S(2) + math.floor((header_h - S(2) - hsz.h) / 2)
    self._tw_header_page:paintTo(bb, htx, hty)

    self._hl_main_tab_dimen = Geom:new{ x = lm_x, y = menu_y, w = htx + hsz.w + S(6) - lm_x, h = header_h }
    self._hl_filter_dimens = {}
    
    if #present_filters >= 2 then
        local f_h = S(20)
        local f_w = S(18) 
        
        local start_x = htx + hsz.w + S(12) 
        local max_w_avail = (lm_x + lm_w - S(4)) - start_x
        
        local num_f = #present_filters
        local f_gap = S(4)
        local total_needed = (num_f * f_w) + ((num_f - 1) * f_gap)
        
        if total_needed > max_w_avail and num_f > 1 then
            f_gap = math.floor((max_w_avail - (num_f * f_w)) / (num_f - 1))
        end

        local curr_f_x = start_x
        local curr_f_y = menu_y + math.floor((header_h - f_h) / 2)

        for _, fd in ipairs(present_filters) do
            local is_active = ((self._active_tab == "images" and self._img_folder or self._hl_filter) == fd.key)
            local touch_w = math.max(S(8), f_w + f_gap)
            local f_dimen = Geom:new{ x = curr_f_x, y = menu_y, w = touch_w, h = header_h }
            table.insert(self._hl_filter_dimens, { key = fd.key, dimen = f_dimen })

            local active_icon = is_active and fd.icon_on or fd.icon_off
            if is_active then
                bb:paintRect(curr_f_x + S(2), menu_y + header_h - S(3), f_w - S(4), S(3), Blitbuffer.COLOR_BLACK)
            end

            if active_icon then
                local isz = active_icon:getSize()
                local ix = curr_f_x + math.floor((f_w - isz.w) / 2)
                local iy = curr_f_y + math.floor((f_h - isz.h) / 2) 
                active_icon:paintTo(bb, ix, iy)
            end

            curr_f_x = curr_f_x + f_w + f_gap
        end
    end

    local list_y = menu_y + header_h
    local list_h = exact_menu_h - header_h

    if #other_items == 0 then
        self._tw_empty_list.text = nil
        self._tw_empty_list:setText((self._active_tab == "images" and self._imgEmptyText) and self:_imgEmptyText() or "—")
        local n_sz = self._tw_empty_list:getSize()
        paintTripleText(self._tw_empty_list, bb, lm_x + math.floor((lm_w - n_sz.w)/2), list_y + math.floor((list_h - n_sz.h)/2))
    else
        -- Expandido: el menu derecho queda tapado por el panel, no se pintan sus filas
        if self._details_open and self._details_expanded then end_idx = start_idx - 1 end
        local row_y_float = list_y
        -- ¿La fila idx de la lista es la seleccionada? (misma regla que usa el pintado de cada fila)
        local function row_is_selected(idx)
            local o = other_items[idx]
            if not o then return false end
            local pp = (type(o) == "table") and o.page or o
            local oo = (type(o) == "table") and o or nil
            if self._active_tab == "bookmarks" then return self._cur_page == pp end
            if self._split_selected_item then return self._split_selected_item == oo end
            return self._cur_page == pp
        end
        for i = start_idx, end_idx do
            local current_row_y = math.floor(row_y_float)
            local it = other_items[i]
            local p, order, total_on_page, item_obj
            if type(it) == "table" then
                p = it.page
                order = it.order
                total_on_page = it.total_on_page
                item_obj = it
            else
                p = it
                order = nil
                total_on_page = 1
                item_obj = nil
            end

            local is_r_sel = false
            if self._active_tab == "bookmarks" then
                is_r_sel = (self._cur_page == p)
            else
                if self._split_selected_item then
                    is_r_sel = (self._split_selected_item == item_obj)
                else
                    is_r_sel = (self._cur_page == p)
                end
            end
            local physical_row = i - start_idx + 1
    
            if is_r_sel then
                -- Pastilla redondeada (estilo iOS) en vez de pintar la fila entera de negro
                local pill_inset = S(5)
                local pill_pad_y = S(3)
                local pill_h = row_h - pill_pad_y * 2
                paintRoundRect(bb, lm_x + b_thick + pill_inset, current_row_y + pill_pad_y,
                    lm_w - (b_thick + pill_inset) * 2, pill_h,
                    math.min(S(14), math.floor(pill_h / 2)), Blitbuffer.COLOR_BLACK)
                -- Puntito blanco a la izquierda: aparece solo cuando el panel de detalle está abierto en esta fila
                if self._details_open then
                    local dot_d = S(8)
                    paintRoundRect(bb, lm_x + b_thick + pill_inset + S(12), current_row_y + math.floor((row_h - dot_d) / 2),
                        dot_d, dot_d, math.floor(dot_d / 2), Blitbuffer.COLOR_WHITE)
                end
            end
            
            -- Línea Hairline divisoria color Gris Claro (no se dibuja pegada a la pastilla)
            if not is_r_sel and i < end_idx and not row_is_selected(i + 1) then
                bb:paintRect(lm_x + S(15), current_row_y + row_h - 1, lm_w - S(30), 1, Blitbuffer.COLOR_LIGHT_GRAY)
            end
            
            local active_row_icon
            if self._active_tab == "bookmarks" then
                active_row_icon = self.icon_box_minus
            elseif self._active_tab == "images" then
                -- favorita: "-" para quitarla; no favorita: "+" para agregarla
                active_row_icon = (item_obj and item_obj.is_fav) and self.icon_img_minus or self.icon_img_plus
            else
                active_row_icon = self.icon_box_arrow
            end
            local rm_sz = active_row_icon and active_row_icon:getSize() or {w = S(22), h = S(22)}
            local rm_x = lm_x + lm_w - rm_sz.w - S(12)
            
            if active_row_icon then
                local ix = rm_x
                local iy = current_row_y + math.floor((row_h - rm_sz.h)/2)
                local is_btn_pressed = (self._pressed_btn == "row_toggle_" .. p)
                
                if is_btn_pressed then
                    local pad = is_r_sel and S(3) or S(6)
                    local bg_c = is_r_sel and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
                    paintRoundRect(bb, ix - pad, iy - pad, rm_sz.w + pad * 2, rm_sz.h + pad * 2, S(8), bg_c)
                    
                    if not is_r_sel then
                        bb:invertRect(ix, iy, rm_sz.w, rm_sz.h)
                        active_row_icon:paintTo(bb, ix, iy)
                        bb:invertRect(ix, iy, rm_sz.w, rm_sz.h)
                    else
                        active_row_icon:paintTo(bb, ix, iy)
                    end
                elseif is_r_sel then
                    bb:paintRect(ix, iy, rm_sz.w, rm_sz.h, Blitbuffer.COLOR_WHITE)
                    active_row_icon:paintTo(bb, ix, iy)
                    bb:invertRect(ix, iy, rm_sz.w, rm_sz.h)
                else
                    active_row_icon:paintTo(bb, ix, iy)
                end
            end
            
            local text_max_w_menu = lm_w - rm_sz.w - S(30)
            
            if not self._tw_row_normal then
                self._tw_row_normal = TextWidget:new{ text = "", face = Font:getFace("cfont", S_MEDIANO), fgcolor = Blitbuffer.COLOR_BLACK }
                self._tw_row_bold   = TextWidget:new{ text = "", face = Font:getFace("cfont", S_MEDIANO), bold = true, fgcolor = Blitbuffer.COLOR_WHITE }
            end
            if not self._tw_row_super_normal then
                self._tw_row_super_normal = TextWidget:new{ text = "", face = Font:getFace("cfont", font_sz_chiquito), fgcolor = Blitbuffer.COLOR_BLACK }
                self._tw_row_super_bold   = TextWidget:new{ text = "", face = Font:getFace("cfont", font_sz_chiquito), bold = true, fgcolor = Blitbuffer.COLOR_WHITE }
            end
            
            local tw_pg = is_r_sel and self._tw_row_bold or self._tw_row_normal
            tw_pg.max_width = text_max_w_menu
            tw_pg.text = nil 
            tw_pg.fgcolor = is_r_sel and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
            
            local disp_p = self:_getDisplayPageInfo(p)
            tw_pg:setText(tostring(disp_p))
            
            local tw_pg_sz = tw_pg:getSize()

            local tw_super, tw_super_sz
            if total_on_page and total_on_page > 1 and order then
                tw_super = is_r_sel and self._tw_row_super_bold or self._tw_row_super_normal
                tw_super.text = nil
                tw_super.fgcolor = is_r_sel and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
                tw_super:setText(tostring(order))
                tw_super_sz = tw_super:getSize()
            end

            -- Número de página (con su superíndice) centrado entre el borde izquierdo y el ícono de la fila
            local group_w = tw_pg_sz.w + (tw_super_sz and (S(2) + tw_super_sz.w) or 0)
            local area_x = lm_x + b_thick
            local area_w = (rm_x - S(8)) - area_x
            local pg_x = area_x + math.max((is_r_sel and self._details_open) and S(30) or S(10), math.floor((area_w - group_w) / 2))
            local pg_y = current_row_y + math.floor((row_h - tw_pg_sz.h) / 2) + S(2) - 1

            tw_pg:paintTo(bb, pg_x, pg_y)
            if tw_super then
                tw_super:paintTo(bb, pg_x + tw_pg_sz.w + S(2), pg_y - S(3))
            end
            
            local t_dim = Geom:new{ x = rm_x - S(10), y = current_row_y, w = rm_sz.w + S(20), h = row_h }
            local dyn_clickable_w = (rm_x - S(10)) - lm_x
            local r_dim = Geom:new{ x = lm_x, y = current_row_y, w = dyn_clickable_w, h = row_h }
            
            table.insert(self._split_rows, { dimen = r_dim, toggle_dimen = t_dim, page = p, item = item_obj })
            row_y_float = row_y_float + row_h
        end
        
        self._split_prev_dimen = nil
        self._split_next_dimen = nil
        
        if needs_pagination then
            local pag_h = row_h
            local pag_y = list_y + (num_rows - 1) * row_h
            
            -- Línea horizontal completa, negra e idéntica a la que está debajo de "Page"
            bb:paintRect(lm_x + b_thick, pag_y, lm_w - b_thick*2, S(1), Blitbuffer.COLOR_LIGHT_GRAY)
            
            local pag_str = cur_page .. " / " .. total_pages
            if not self._tw_pagination then
                -- Texto limpio, negro, tamaño CHIQUITO y en negrita (match exacto con el encabezado)
                self._tw_pagination = TextWidget:new{ text = "", face = Font:getFace("cfont", font_sz_chiquito), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
            end
            self._tw_pagination.text = nil
            self._tw_pagination:setText(pag_str)
            
            local pag_sz = self._tw_pagination:getSize()
            local text_y = pag_y + math.floor((pag_h - pag_sz.h)/2)
            
            -- Dibujado estándar, nítido y sin efectos grises raros
            self._tw_pagination:paintTo(bb, lm_x + math.floor((lm_w - pag_sz.w)/2), text_y)
            
            local btn_w = S(48) 
            
            if cur_page > 1 then
                self._split_prev_dimen = Geom:new{ x = lm_x, y = pag_y, w = btn_w, h = pag_h }
                local is_pressed = (self._pressed_btn == "split_prev")
                
                local bg_x = self._split_prev_dimen.x + S(6)
                local bg_y = self._split_prev_dimen.y + S(6)
                local bg_w = self._split_prev_dimen.w - S(12)
                local bg_h = self._split_prev_dimen.h - S(12)
                
                if is_pressed then
                    paintRoundRect(bb, bg_x, bg_y, bg_w, bg_h, S(8), Blitbuffer.COLOR_BLACK)
                end
                
                local active_prev_icon = self.icon_chevron_left
                if active_prev_icon then
                    local p_sz = active_prev_icon:getSize()
                    local ix = bg_x + math.floor((bg_w - p_sz.w) / 2)
                    local iy = bg_y + math.floor((bg_h - p_sz.h) / 2)
                    
                    if is_pressed then
                        bb:paintRect(ix, iy, p_sz.w, p_sz.h, Blitbuffer.COLOR_WHITE)
                        active_prev_icon:paintTo(bb, ix, iy)
                        bb:invertRect(ix, iy, p_sz.w, p_sz.h)
                    else
                        active_prev_icon:paintTo(bb, ix, iy)
                    end
                end
            end
            
            if cur_page < total_pages then
                self._split_next_dimen = Geom:new{ x = lm_x + lm_w - btn_w, y = pag_y, w = btn_w, h = pag_h }
                local is_pressed = (self._pressed_btn == "split_next")
                
                local bg_x = self._split_next_dimen.x + S(6)
                local bg_y = self._split_next_dimen.y + S(6)
                local bg_w = self._split_next_dimen.w - S(12)
                local bg_h = self._split_next_dimen.h - S(12)
                
                if is_pressed then
                    paintRoundRect(bb, bg_x, bg_y, bg_w, bg_h, S(8), Blitbuffer.COLOR_BLACK)
                end
                
                local active_next_icon = self.icon_chevron_right
                if active_next_icon then
                    local n_sz = active_next_icon:getSize()
                    local ix = bg_x + math.floor((bg_w - n_sz.w) / 2)
                    local iy = bg_y + math.floor((bg_h - n_sz.h) / 2)
                    
                    if is_pressed then
                        bb:paintRect(ix, iy, n_sz.w, n_sz.h, Blitbuffer.COLOR_WHITE)
                        active_next_icon:paintTo(bb, ix, iy)
                        bb:invertRect(ix, iy, n_sz.w, n_sz.h)
                    else
                        active_next_icon:paintTo(bb, ix, iy)
                    end
                end
            end
        end
    end

    -- Panel de detalles EXPANDIDO: se pinta al final, encima del menu derecho, estirando el contorno
    -- derecho de la tarjeta izquierda hasta el contorno derecho del menu derecho.
    if self._details_open and self._details_expanded then
        if self:_getDetailsContext() == nil then
            -- Ya no hay anotacion que mostrar: se cierra el panel y el menu derecho queda a la vista
            if not self._details_resync_pending then
                self._details_open = false
                self._details_expanded = false
                self:_freeDetailsWidgets()
            end
            UIManager:setDirty(self, "ui", self.dimen)   -- la tarjeta no se pinto: repintar con el menu a la vista
        else
            if not self:_restoreRegion(bb, self._col_snap) then
                bb:paintRect(card_x + card_w, card_y, (lm_x + lm_w) - (card_x + card_w), card_h, Blitbuffer.COLOR_WHITE)
            end
            self._col_snap = nil
            local okx, errx = pcall(self._paintDetailsPanel, self, bb, card_x, card_y, card_w, card_h, box_radius, b_thick, lm_x + lm_w - card_x)
            if not okx then
                logger.warn("page-scrubber expanded details panel error:", errx)
                self._details_open = false
                self._details_expanded = false
            elseif self._details_panel_dimen then
                -- El menu derecho queda tapado: que sus zonas no reciban toques
                self._split_rows = {}
                self._split_fixed_row_dimen, self._split_fixed_toggle_dimen = nil, nil
                self._hl_main_tab_dimen, self._hl_filter_dimens = nil, {}
                self._split_prev_dimen, self._split_next_dimen = nil, nil
            end
        end
    end
end

function PageScrubber:_paintBackLabel(bb)
    self._grid_back_dimen = nil
    local BACK_LABEL_THRESHOLD = 10
    if math.abs(self._cur_page - self._origin_page) < BACK_LABEL_THRESHOLD then return end

    local S = self.S
    local origin_on_left
    if self.is_rtl then
        -- En RTL los números avanzan hacia la izquierda: si la página actual es menor, el origen está a la izquierda
        origin_on_left = (self._cur_page < self._origin_page)
    else
        -- En LTR estándar: si la página actual es mayor, el origen quedó atrás (a la izquierda)
        origin_on_left = (self._cur_page > self._origin_page)
    end

    local arrow_char = origin_on_left and "\u{F104}" or "\u{F105}"
    local bg_face = Font:getFace("cfont", self.S_BOTTOM_GRAY or S(14))

    if not self._tw_grid_back_icon then
        self._tw_grid_back_icon = TextWidget:new{
            text = arrow_char, face = bg_face,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
    else
        self._tw_grid_back_icon.face = bg_face
        self._tw_grid_back_icon:setText(arrow_char)
    end

    local disp_origin = self:_getDisplayPageInfo(self._origin_page)
    local label_text = _("Page") .. " " .. disp_origin
    if not self._tw_grid_back then
        self._tw_grid_back = TextWidget:new{
            text = label_text, face = bg_face,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
    else
        self._tw_grid_back.face = bg_face
        self._tw_grid_back:setText(label_text)
    end

    local isz = self._tw_grid_back_icon:getSize()
    local tsz = self._tw_grid_back:getSize()
    local gap = S(10)
    local pad_x, pad_y = S(12), S(8)

    local content_h = math.max(isz.h, tsz.h)
    local lbl_w = pad_x * 2 + isz.w + gap + tsz.w
    
    local text_y_shift = origin_on_left and S(4) or S(1)
    local group_y_shift = origin_on_left and 0 or S(3)
    local icon_y = self.ctrl_y_pos + math.floor((self._ctrl_row_h - isz.h) / 2) - group_y_shift
    local text_y = self.ctrl_y_pos + math.floor((self._ctrl_row_h - tsz.h) / 2) - text_y_shift - group_y_shift

    local lbl_x
    if origin_on_left then
        lbl_x = math.floor((self._ctrl_row_x0 - lbl_w) / 2)
    else
        local sw = Screen:getWidth()
        lbl_x = self._ctrl_row_x1 + math.floor((sw - self._ctrl_row_x1 - lbl_w) / 2)
    end

    local actual_top = math.min(icon_y, text_y)
    local actual_bottom = math.max(icon_y + isz.h, text_y + tsz.h)
    self._grid_back_dimen = Geom:new{ x = lbl_x, y = actual_top - pad_y, w = lbl_w, h = (actual_bottom - actual_top) + pad_y * 2 }

    local is_pressed = (self._pressed_btn == "grid_back")
    if is_pressed then
        paintRoundRect(bb, self._grid_back_dimen.x, self._grid_back_dimen.y, self._grid_back_dimen.w, self._grid_back_dimen.h, S(8), Blitbuffer.COLOR_BLACK)
        self._tw_grid_back_icon.fgcolor = Blitbuffer.COLOR_WHITE
        self._tw_grid_back.fgcolor = Blitbuffer.COLOR_WHITE
        
        if origin_on_left then
            self._tw_grid_back_icon:paintTo(bb, lbl_x + pad_x, icon_y)
            self._tw_grid_back:paintTo(bb, lbl_x + pad_x + isz.w + gap, text_y)
        else
            self._tw_grid_back:paintTo(bb, lbl_x + pad_x, text_y)
            self._tw_grid_back_icon:paintTo(bb, lbl_x + pad_x + tsz.w + gap, icon_y)
        end
    else
        self._tw_grid_back_icon.fgcolor = Blitbuffer.COLOR_DARK_GRAY
        self._tw_grid_back.fgcolor = Blitbuffer.COLOR_DARK_GRAY
        
        if origin_on_left then
            paintTripleText(self._tw_grid_back_icon, bb, lbl_x + pad_x, icon_y)
            paintTripleText(self._tw_grid_back, bb, lbl_x + pad_x + isz.w + gap, text_y)
        else
            paintTripleText(self._tw_grid_back, bb, lbl_x + pad_x, text_y)
            paintTripleText(self._tw_grid_back_icon, bb, lbl_x + pad_x + tsz.w + gap, icon_y)
        end
    end
end

function PageScrubber:_gotoPage(page)
    if self._closing then return end
    self._cur_page = math.max(1, math.min(self._total_pages, page))
    self._slider.value = self._cur_page
    self:_updateTexts()

    self._grid_batch_seq = (self._grid_batch_seq or 0) + 1
    self._grid_batch_id = "page_scrubber_cancelled_" .. tostring(self._grid_instance_id) .. "_" .. tostring(self._grid_batch_seq)
    self._is_busy = false
    self._tasks_in_flight = 0

    self._nav_token = (self._nav_token or 0) + 1
    local my_token = self._nav_token
    local target_page = self._cur_page
    local origin_page = self._origin_page

    self:_waitForIdle(function()
        if self._nav_token == my_token then
            -- Guardamos la ubicación en el historial de KOReader antes de hacer el salto
            if target_page ~= origin_page then
                pcall(function()
                    if self.ui.link and self.ui.link.addCurrentLocationToStack then
                        self.ui.link:addCurrentLocationToStack()
                    end
                end)
            end
            self.ui:handleEvent(Event:new("GotoPage", target_page))
        end
    end)

    if not self._grid_disabled then self:_updateGridPages() end
    UIManager:setDirty(self, "ui", self.dimen)
end

-- ============================================================================
-- SEMAFORO DE NAVEGACION
-- En grid y simple grid, un paso de pagina (flechas, saltos, tap en miniatura) solo se acepta si
-- la pagina destino ya esta cargada: si esta en blanco en el costado, no se entra a ella (no queda
-- una pagina en blanco en el centro). Solo se mira el destino, no el resto de la ventana.
-- No aplica en split ni en grid six. Valvulas de seguridad: paginas que fallaron/expiraron
-- cuentan como listas, y a los 4 s se deja pasar igual.
-- ============================================================================
function PageScrubber:_expectedTileDims()
    if self._view_mode == "grid" then return self._grid_item_w, self._grid_item_h end
    return self._thumb_req_split_w, self._thumb_req_split_h
end

function PageScrubber:_pagesNeededFor(target)
    local list = {}
    if self._view_mode == "grid" then
        for off = -1, 1 do list[#list + 1] = target + off end
    elseif self._view_mode == "grid_six" then
        local o = self:_g6Origin()
        for idx = 1, self:_g6Count() do list[#list + 1] = target + (idx - o) end
    else
        list[1] = target
    end
    return list
end

function PageScrubber:_isTileReady(p)
    local w, h = self:_expectedTileDims()
    if not w or not h then return true end
    local c = self._tile_cache and self._tile_cache[p]
    if c and c.bb and c.w == w and c.h == h then return true end
    return (self._failed_pages and self._failed_pages[p]) and true or false
end

function PageScrubber:_requestTileFor(page)
    local thumbnail = self.ui and self.ui.thumbnail
    local w, h = self:_expectedTileDims()
    if not (thumbnail and thumbnail.getPageThumbnail and w and h) then return end
    self._gate_pending = self._gate_pending or {}
    local now = os.time()
    if self._gate_pending[page] and now - self._gate_pending[page] < 2 then return end
    self._gate_pending[page] = now
    thumbnail:getPageThumbnail(page, w, h, "page_scrubber_preload_" .. tostring(self._grid_instance_id),
        function(tile)
            if self._gate_pending then self._gate_pending[page] = nil end
            if self._closing then return end
            if not tile or not tile.bb then
                self._failed_pages = self._failed_pages or {}
                self._failed_pages[page] = true
                return
            end
            local processed = processTile(tile, w, h)
            if processed and processed.bb then
                self:_cacheTile(page, processed.bb, processed.is_scaled, w, h)
            end
        end)
end

function PageScrubber:_canStepTo(target)
    -- Sin semaforo en split ni en grid six (multi grid).
    if self._grid_disabled or self._closing or self._view_mode == "split" or self._view_mode == "grid_six" then
        return true
    end
    if target < 1 or target > self._total_pages or target == self._cur_page then return true end
    -- Solo se avanza a una pagina que YA esta cargada: si la vecina (costado) sigue en blanco,
    -- el paso se ignora, asi nunca queda una pagina en blanco en el centro al pasar rapido.
    if self:_isTileReady(target) then
        self._gate_since = nil
        return true
    end
    local now = os.time()
    self._gate_since = self._gate_since or {}
    self._gate_since[target] = self._gate_since[target] or now
    if now - self._gate_since[target] >= 4 then  -- valvula de seguridad
        self._gate_since[target] = nil
        return true
    end
    self:_requestTileFor(target)
    return false
end

-- Paso de pagina protegido por el semaforo. Devuelve true si se hizo el paso.
function PageScrubber:_stepPreview(target)
    if not self:_canStepTo(target) then return false end
    self:_previewPage(target, false)
    return true
end

-- true si en la pagina actual hay algo que mostrar en el panel de detalles (anotacion de la lista activa o bookmark)
function PageScrubber:_pageHasDetails()
    local cur = tonumber(self._cur_page)
    for _, it in ipairs(self:_getFilteredActiveList() or {}) do
        local p = tonumber((type(it) == "table") and it.page or it)
        if p and p == cur then return true end
    end
    if self._active_tab ~= "images" and self:_getBookmarkDetailsContext() then return true end
    return false
end

function PageScrubber:_previewPage(page, is_dragging)
    if self._closing then return end
    local prev_page = self._cur_page
    self._cur_page = math.max(1, math.min(self._total_pages, page))
    if prev_page and self._cur_page ~= prev_page then
        self._nav_dir = (self._cur_page > prev_page) and 1 or -1
    end
    self._hide_action_buttons = true
    self._slider.value = self._cur_page
    self:_updateTexts()

    if self._details_open and self._view_mode == "split" and not self._details_resync_pending
       and not self:_pageHasDetails() then
        self:_closeDetailsPanel(false)
    end

    -- Actualizamos los números lógicos de los slots de inmediato
    if self._view_mode == "grid_six" and self._grid_tiles then
        local g6_origin = self:_g6Origin()
        for idx = 1, self:_g6Count() do
            local p = self._cur_page + (idx - g6_origin)
            if p >= 1 and p <= self._total_pages then
                self._grid_tiles[idx] = self._grid_tiles[idx] or {}
                if self._grid_tiles[idx].page ~= p then
                    self._grid_tiles[idx].page = p
                    self._grid_tiles[idx].loading = true
                    self._grid_tiles[idx].tile_bb = nil
                end
            else
                self._grid_tiles[idx] = { page = nil, loading = false }
            end
        end
    end

    -- 1. Comportamiento durante el arrastre continuo (evita parpadeos y svalora CPU)
    if is_dragging then
        if self._grid_tiles and not self._scrubbing_blank then
            self._scrubbing_blank = true
            for idx, slot in pairs(self._grid_tiles) do
                slot.tile_bb = nil
                slot.loading = true
            end
            UIManager:setDirty(self, "ui", self._grid_dimen)
        end

        UIManager:setDirty(self, "fast", self._bar_dimen)

        self._drag_token = (self._drag_token or 0) + 1
        local my_token = self._drag_token

        UIManager:scheduleIn(0.25, function()
            if self._closing or self._drag_token ~= my_token then return end
            self._scrubbing_blank = false
            if not self._grid_disabled then
                self:_updateGridPages()
            end
        end)
        return
    end

    -- 2. Salto normal de página / tap directo
    self._scrubbing_blank = false
    self._drag_token = (self._drag_token or 0) + 1
    self._is_busy = false
    self._tasks_in_flight = 0
    self._pending_grid_update = false

    -- La barra inferior (capítulo, página, slider) se actualiza en cada cambio
    if self._bar_dimen then
        UIManager:setDirty(self, "ui", self._bar_dimen)
    end

    if not self._grid_disabled then 
        self:_updateGridPages() 
    else
        UIManager:setDirty(self, "ui", self.dimen)
    end
end

function PageScrubber:_reopenWithMode(new_mode, target_page)
    if self._closing then return end
    self._closing = true
    self:_cancelHold()
    
    -- Abortamos inmediatamente cualquier decodificación en vuelo para evitar crasheos de memoria en C
    self._slider._dragging = false
    self._is_busy = false
    self._tasks_in_flight = 0
    self._grid_batch_seq = (self._grid_batch_seq or 0) + 1
    self._grid_batch_id = "safe_reopen_" .. tostring(os.time())

    local thumbnail = self.ui and self.ui.thumbnail
    if thumbnail and thumbnail.cancelPageThumbnailRequests and type(thumbnail.thumbnails_requests) == "table" then
        for b_id in pairs(thumbnail.thumbnails_requests) do
            if type(b_id) == "string" and b_id:find("^page_scrubber_") then
                thumbnail:cancelPageThumbnailRequests(b_id)
            end
        end
    end

    local ui = self.ui
    local origin = self._origin_page
    local scale = self.ui_scale or 1.0
    local tab = self._active_tab
    local is_trans = (new_mode == "grid_simple")
    local base_md = self._base_grid_mode

    UIManager:close(self)
    UIManager:setDirty(nil, "full")
    
    -- Para grid_simple damos 0.15s para que KOReader pinte limpiamente la hoja del libro de fondo
    local delay = is_trans and 0.15 or 0.08
    UIManager:scheduleIn(delay, function()
        local ScrubberUI = require("scrubber_ui")
        local new_widget = ScrubberUI:new{
            ui = ui,
            document = ui.document,
            initial_view_mode = new_mode,
            initial_tab = tab,
            transparent_bg = is_trans,
            ui_scale = scale,
            initial_origin = origin,
            initial_page = target_page,
            base_mode = base_md,
        }
        UIManager:show(new_widget)
    end)
end

function PageScrubber:_showUIScaleSpinner()
    self:_closeStay()
    
    local function reopen()
        UIManager:scheduleIn(0.1, function()
            local ScrubberUI = require("scrubber_ui")
            local new_widget = ScrubberUI:new{
                ui = self.ui,
                document = self.ui.document,
                initial_view_mode = self._view_mode,
                initial_tab = self._active_tab,
                transparent_bg = self.transparent_bg,
                ui_scale = (G_reader_settings and G_reader_settings:readSetting("page_scrubber_ui_scale")) or 1.0,
                initial_origin = self._origin_page,
                initial_page = self._cur_page,
                base_mode = self._base_grid_mode,
            }
            UIManager:show(new_widget)
        end)
    end
    
    local SpinWidget = require("ui/widget/spinwidget")
    local current_scale = (G_reader_settings and G_reader_settings:readSetting("page_scrubber_ui_scale")) or 1.0
    
    local spin = SpinWidget:new{
        title_text = "Page Scrubber UI scale (%)", 
        value = math.floor(current_scale * 100),
        value_min = 50, value_max = 200, 
        value_step = 5, value_hold_step = 5,
        ok_text = "Save",
        callback = function(spin_widget)
            if G_reader_settings then
                G_reader_settings:saveSetting("page_scrubber_ui_scale", spin_widget.value / 100)
                G_reader_settings:flush()
            end
            reopen()
        end,
        cancel_callback = function()
            reopen()
        end,
    }
    UIManager:show(spin)
end

function PageScrubber:_flashAndDo(btn_id, rect, action_func)
    if self._closing then return end
    self._pressed_btn = btn_id
    if rect then
        UIManager:setDirty(self, "ui", rect)
    end
    UIManager:scheduleIn(0.05, function()
        self._pressed_btn = nil
        action_func()
        if rect and not self._closing then
            UIManager:setDirty(self, "ui", rect)
        end
    end)
end

function PageScrubber:_openNoteTextEditor()
    local target_page = self._cur_page
    local target_item = nil
    local target_index = nil

    if self._split_selected_item and self._split_selected_item.annotation then
        target_item = self._split_selected_item.annotation
    end

    -- Buscar el índice exacto de la anotación en la lista nativa
    if self.ui.annotation and self.ui.annotation.annotations then
        for i, item in ipairs(self.ui.annotation.annotations) do
            if target_item then
                if item == target_item then
                    target_index = i
                    break
                end
            else
                -- Fallback si no hay selección específica: agarra la primera de la página actual
                if math.floor(self:_getNumericalPage(item) or 0) == target_page then
                    target_index = i
                    break
                end
            end
        end
    end

    if not target_index then return end

    -- Invocar el editor de notas nativo de KOReader (ReaderBookmark:setBookmarkNote)
    if self.ui.bookmark and type(self.ui.bookmark.setBookmarkNote) == "function" then
        local edited_ann = self.ui.annotation and self.ui.annotation.annotations
                           and self.ui.annotation.annotations[target_index]
        self.ui.bookmark:setBookmarkNote(target_index, nil, nil, function()
            -- Este callback se ejecuta automáticamente cuando el usuario presiona "Save"
            self:_extractAnnotations()
            self:_relinkSelectedAnnotation(edited_ann)
            UIManager:setDirty(self, "ui", self._grid_dimen)
        end)
    end
end

-- Highlight que se está editando desde el split (el seleccionado, o el de la página actual)
function PageScrubber:_getTargetHighlight()
    local target_page = self._cur_page
    local current_filter = self._hl_filter

    if self._split_selected_item and self._split_selected_item.annotation then
        return self._split_selected_item.annotation
    end

    if self.ui.annotation and self.ui.annotation.annotations then
        for _, item in ipairs(self.ui.annotation.annotations) do
            local p = self:_getNumericalPage(item)
            local is_real_hl = item.pos0 and item.pos1
            if p and math.floor(p) == target_page and is_real_hl and item.text and item.text ~= "" then
                local d = item.drawer or "lighten"
                local item_filt = "normal"
                if d == "invert" then item_filt = "invert"
                elseif d == "underscore" then item_filt = "underline"
                elseif d == "strikeout" then item_filt = "strikethrough" end

                if not current_filter or item_filt == current_filter then
                    return item
                end
            end
        end

        for _, item in ipairs(self.ui.annotation.annotations) do
            local p = self:_getNumericalPage(item)
            local is_real_hl = item.pos0 and item.pos1
            if p and math.floor(p) == target_page and is_real_hl and item.text and item.text ~= "" then
                return item
            end
        end
    end
    return nil
end

-- Color del highlight que se está editando (nil si es "invert", que no admite color)
function PageScrubber:_getPickerColor(current_drawer)
    if current_drawer == "invert" then return nil end
    local tgt = self:_getTargetHighlight()
    if not tgt or (tgt.drawer or "lighten") == "invert" then return nil end
    return tgt.color or "gray"
end

-- Caja propia (separada de los 4 tipos) con el círculo del color del highlight
function PageScrubber:_paintPickerColorBox(bb, x, y, w, h, color_key, _radius, pressed)
    local S = self.S
    local b = S(2)
    -- Contenedor circular (el radio es la mitad del lado)
    local radius = math.floor(math.min(w, h) / 2)
    paintRoundRect(bb, x, y, w, h, radius, Blitbuffer.COLOR_BLACK)
    paintRoundRect(bb, x + b, y + b, w - b * 2, h - b * 2, math.max(1, radius - b),
        pressed and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE)
    local d = math.floor(math.min(w, h) * 0.5)
    self:_paintColorDot(bb, x + math.floor((w - d) / 2), y + math.floor((h - d) / 2), d, color_key, Blitbuffer.COLOR_BLACK)
end

-- Menú con todos los colores para cambiar el color del highlight seleccionado
function PageScrubber:_openColorChangeMenu(anchor)
    local target = self:_getTargetHighlight()
    if not target or (target.drawer or "lighten") == "invert" then return end
    local ok, ColorFilterMenu = pcall(require, "color_filter_menu")
    local Swatch = ok and ColorFilterMenu and ColorFilterMenu.Swatch
    if not Swatch then return end

    -- Todos los colores de KOReader (sin cantidades), más cualquier color no estándar que ya exista
    local items, seen = {}, {}
    for _, key in ipairs(HL_COLOR_ORDER) do
        table.insert(items, { key = key, name = HL_COLOR_NAMES[key] })
        seen[key] = true
    end
    for _, c in ipairs(self:_getColorList()) do
        if not seen[c.key] then table.insert(items, { key = c.key, name = c.name }) end
    end

    -- Forzamos la separación del renderizado para pantallas E-ink
    UIManager:scheduleIn(0.05, function()
        UIManager:show(Swatch:new{
            scrubber_ui = self,
            center_rect = self._color_menu_region,
            align_bottom = self._color_menu_bottom,
            -- En horizontal el menu se ancla arriba del circulo de color, extendido hacia la izquierda
            anchor_above = (Screen:getWidth() > Screen:getHeight()) and anchor or nil,
            items = items,
            selected = target.color or "gray",
            on_select = function(key) self:_setHighlightColor(key) end,
        })
    end)
end

-- Cambia el color del highlight (misma técnica que _setHighlightType)
-- Tras _extractAnnotations() los objetos de la lista son nuevos y la seleccion vieja deja de
-- estar en ella (se caia en "la primera anotacion de la pagina"). Se vuelve a seleccionar la
-- MISMA anotacion usando su objeto original de KOReader.
function PageScrubber:_relinkSelectedAnnotation(ann)
    if not ann or self._active_tab == "bookmarks" then return false end
    for _, it in ipairs(self:_getFilteredActiveList() or {}) do
        if type(it) == "table" and it.annotation == ann then
            self._split_selected_item = it
            return true
        end
    end
    return false
end

function PageScrubber:_setHighlightColor(new_color)
    local target_item = self:_getTargetHighlight()
    if not target_item then return end
    if (target_item.drawer or "lighten") == "invert" then return end
    if (target_item.color or "gray") == new_color then return end

    local target_page = self._cur_page

    -- 1. Actualizar el color y guardar en el libro
    target_item.color = new_color
    pcall(function()
        if self.ui.annotation and self.ui.annotation.saveAnnotations then
            self.ui.annotation:saveAnnotations()
        end
    end)

    -- 2. Notificar al sistema de lectura de KOReader que la anotación cambió
    pcall(function()
        local Event = require("ui/event")
        if self.ui and self.ui.handleEvent then
            self.ui:handleEvent(Event:new("AnnotationsModified", { target_item }))
            self.ui:handleEvent(Event:new("RedrawCurrentPage"))
        end
    end)

    -- 3. Si hay un color filtrado y el highlight sale de ese filtro, ya no queda seleccionado
    if self._hl_color_filter and self._hl_color_filter ~= new_color then
        self._split_selected_item = nil
    end

    -- 4. Ocultar el selector de forma instantánea
    self._show_type_picker = false
    self._show_delete_confirm = false

    -- 5. Invalidar las miniaturas de esta página
    self:_invalidateGridTilesForPage(target_page)

    -- 6. Actualizar las listas en memoria y repintar
    UIManager:scheduleIn(0.08, function()
        if self._closing then return end
        self:_extractAnnotations()
        self:_relinkSelectedAnnotation(target_item)
        self:_updateGridPages()
        UIManager:setDirty(self, "ui", self.dimen)
    end)
end

function PageScrubber:_setHighlightType(new_drawer)
    local target_page = self._cur_page
    local target_item = nil
    local current_filter = self._hl_filter

    if self._split_selected_item and self._split_selected_item.annotation then
        target_item = self._split_selected_item.annotation
    elseif self.ui.annotation and self.ui.annotation.annotations then
        for _, item in ipairs(self.ui.annotation.annotations) do
            local p = self:_getNumericalPage(item)
            local is_real_hl = item.pos0 and item.pos1
            if p and math.floor(p) == target_page and is_real_hl and item.text and item.text ~= "" then
                local d = item.drawer or "lighten"
                local item_filt = "normal"
                if d == "invert" then item_filt = "invert"
                elseif d == "underscore" then item_filt = "underline"
                elseif d == "strikeout" then item_filt = "strikethrough" end

                if not current_filter or item_filt == current_filter then
                    target_item = item
                    break
                end
            end
        end

        if not target_item then
            for _, item in ipairs(self.ui.annotation.annotations) do
                local p = self:_getNumericalPage(item)
                local is_real_hl = item.pos0 and item.pos1
                if p and math.floor(p) == target_page and is_real_hl and item.text and item.text ~= "" then
                    target_item = item
                    break
                end
            end
        end
    end

    if not target_item then return end

    -- 1. Actualizar el estilo de resaltado y guardar en el libro
    target_item.drawer = new_drawer
    pcall(function()
        if self.ui.annotation and self.ui.annotation.saveAnnotations then
            self.ui.annotation:saveAnnotations()
        end
    end)

    -- 2. Notificar al sistema de lectura de KOReader que la anotación cambió
    pcall(function()
        local Event = require("ui/event")
        if self.ui and self.ui.handleEvent then
            self.ui:handleEvent(Event:new("AnnotationsModified", { target_item }))
            self.ui:handleEvent(Event:new("RedrawCurrentPage"))
        end
    end)

    -- 3. Calcular y actualizar el filtro si correspondía
    local new_filt = "normal"
    if new_drawer == "invert" then new_filt = "invert"
    elseif new_drawer == "underscore" then new_filt = "underline"
    elseif new_drawer == "strikeout" then new_filt = "strikethrough" end
    if self._hl_filter then
        -- Con un color filtrado, "invert" (que no tiene color) sacaría todo de la lista: se quita el filtro de tipo
        if self._hl_color_filter and new_filt == "invert" then
            self._hl_filter = nil
        else
            self._hl_filter = new_filt
        end
    end

    -- Con un color filtrado, un highlight que pasa a invert sale de esa lista: ya no queda seleccionado
    if self._hl_color_filter and new_drawer == "invert" then
        self._split_selected_item = nil
    end

    -- 4. Ocultar el selector de tipos de forma instantánea
    self._show_type_picker = false
    self._show_delete_confirm = false

    -- 5. Invalidar únicamente las miniaturas de esta página en el scrubber
    self:_invalidateGridTilesForPage(target_page)

    -- 6. Actualizar las listas en memoria y repintar la miniatura
    UIManager:scheduleIn(0.08, function()
        if self._closing then return end
        self:_extractAnnotations()
        self:_relinkSelectedAnnotation(target_item)
        self:_updateGridPages()
        UIManager:setDirty(self, "ui", self.dimen)
    end)
end

function PageScrubber:paintTo(bb, x, y)
    if self._closing then return end
    -- Durante el pintado, los helpers "puros" pueden memorizar su resultado dentro del mismo frame
    self._paint_seq = (self._paint_seq or 0) + 1
    self._in_paint = true
    local ok, err = pcall(function() self:_paintToImpl(bb, x, y) end)
    self._in_paint = false
    if not ok then logger.warn("page-scrubber paintTo error:", err) end
end

function PageScrubber:_paintToImpl(bb, x, y)

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local S  = self.S
    local pad = S(16)
    local is_landscape = sw > sh

    local has_wallpaper = false
    if not self.transparent_bg then
        -- Solo se copia el fondo completo si no es un repintado parcial localizado
        has_wallpaper = ScrubberWallpaper.paintTo(bb, sw, sh, Screen.night_mode)
        if not has_wallpaper then
            bb:paintRect(0, 0, sw, sh, Blitbuffer.COLOR_WHITE)
        end
    end

    -- MODO HORIZONTAL PROTEGIDO (SIMPLE GRID)
    if is_landscape and self._view_mode == "grid_simple" then
        local ok, GSView = pcall(require, "grid_simple_landscape_view")
        if ok and GSView and GSView.paint then
            GSView.paint(self, bb)
        end
        return
    end

    local show_top_line = false
    if G_reader_settings then
        local line_setting = G_reader_settings:readSetting("page_scrubber_top_line")
        if line_setting ~= nil then
            show_top_line = (line_setting == true or line_setting == "true" or line_setting == 1)
        end
    end

    -- MODO HORIZONTAL PROTEGIDO (SPLIT, GRID Y GRID_SIX)
    if is_landscape and (self._view_mode == "split" or self._view_mode == "grid" or self._view_mode == "grid_six") then
        local td = self._top_bar_dimen
        bb:paintRect(td.x, td.y, td.w, td.h, Blitbuffer.COLOR_WHITE)
        if show_top_line then
            local gray_t = math.max(S(2), math.min(S(3) - 1, S(2) + 1))   -- un poco mas gruesa, siempre menos que la negra
            bb:paintRect(td.x, td.y + td.h - gray_t, td.w, gray_t, Blitbuffer.COLOR_LIGHT_GRAY)
        end

        if self._view_mode == "split" then
            local ok_req, SplitLandscapeView = pcall(require, "split_landscape_view")
            if ok_req and SplitLandscapeView and type(SplitLandscapeView.paint) == "function" then
                pcall(SplitLandscapeView.paint, self, bb)
            else
                self:_paintSplitView(bb, td.y + td.h, 0)
            end
        elseif self._view_mode == "grid_six" then
            local ok_req, GridSixLandscapeView = pcall(require, "grid_six_landscape_view")
            if ok_req and GridSixLandscapeView and type(GridSixLandscapeView.paint) == "function" then
                pcall(GridSixLandscapeView.paint, self, bb)
            end
        else
            local ok_req, GridLandscapeView = pcall(require, "grid_landscape_view")
            if ok_req and GridLandscapeView and type(GridLandscapeView.paint) == "function" then
                pcall(GridLandscapeView.paint, self, bb)
            end
        end

        -- Coordenadas táctiles en horizontal: [Toggle 6-grid] [ToC] [BM/Grilla] [Config] [✕]
        local btn_sz = S(42)
        local spacing = S(10)
        local right_base = sw - S(14)
        local top_y = td.y + math.floor((td.h - btn_sz) / 2)

        self._x_dimen   = Geom:new{ x = right_base - btn_sz, y = top_y, w = btn_sz, h = btn_sz }
        self._fn_dimen  = Geom:new{ x = self._x_dimen.x - spacing - btn_sz, y = top_y, w = btn_sz, h = btn_sz }
        self._bm_dimen  = Geom:new{ x = self._fn_dimen.x - spacing - btn_sz, y = top_y, w = btn_sz, h = btn_sz }
        self._toc_dimen = Geom:new{ x = self._bm_dimen.x - spacing - btn_sz, y = top_y, w = btn_sz, h = btn_sz }

        if self._view_mode == "grid" or self._view_mode == "grid_six" or self._view_mode == "split" then
            self._grid_toggle_dimen = Geom:new{ x = self._toc_dimen.x - spacing - btn_sz, y = top_y, w = btn_sz, h = btn_sz }
        else
            self._grid_toggle_dimen = nil
        end

        local function drawTopBtn(btn_id, dimen, tw)
            if not dimen or not tw then return end
            local is_pressed = (self._pressed_btn == btn_id and btn_id ~= "fn")
            if is_pressed then
                local bg_d = (btn_id == "lib") and self._lib_dimen or dimen
                paintRoundRect(bb, bg_d.x, bg_d.y, bg_d.w, bg_d.h, S(8), Blitbuffer.COLOR_BLACK)
            end
            local tsz = tw:getSize()
            local ix = dimen.x + math.floor((dimen.w - tsz.w) / 2)
            local iy = dimen.y + math.floor((dimen.h - tsz.h) / 2)
            
            if tw.text then
                if tw.text == "\u{F015}" or tw.text == "\u{F0F6}" or tw.text == "\u{F02D}" or tw.text == "\u{F044}" or tw.text == "\u{F44E}" or tw.text == "\u{F0CA}" or tw.text == "\u{E344}" then
                    iy = iy + S(1)
                elseif tw.text == "⚙" then
                    iy = iy - S(1) - 1
                    ix = ix - S(1) - 2
                end
            end

            if is_pressed then
                bb:paintRect(ix, iy, tsz.w, tsz.h, Blitbuffer.COLOR_WHITE)
                tw.fgcolor = Blitbuffer.COLOR_BLACK
                tw:paintTo(bb, ix, iy)
                bb:invertRect(ix, iy, tsz.w, tsz.h)
            else
                tw.fgcolor = Blitbuffer.COLOR_BLACK
                tw:paintTo(bb, ix, iy)
            end
        end

        drawTopBtn("lib", self._lib_icon_dimen, self.tw_lib)
        local is_lib_p = (self._pressed_btn == "lib")
        if self.tw_lib_label then
            if is_lib_p then
                local lsz = self.tw_lib_label:getSize()
                bb:paintRect(self._lib_label_x, self._lib_label_y, lsz.w, lsz.h, Blitbuffer.COLOR_WHITE)
                self.tw_lib_label.fgcolor = Blitbuffer.COLOR_BLACK
                self.tw_lib_label:paintTo(bb, self._lib_label_x, self._lib_label_y)
                bb:invertRect(self._lib_label_x, self._lib_label_y, lsz.w, lsz.h)
            else
                self.tw_lib_label.fgcolor = Blitbuffer.COLOR_BLACK
                self.tw_lib_label:paintTo(bb, self._lib_label_x, self._lib_label_y)
            end
        end
        
        if self._grid_toggle_dimen then
            local toggle_icon = (self._view_mode == "grid_six") and self.tw_gallery or self.tw_grid_toggle
            drawTopBtn("grid_toggle", self._grid_toggle_dimen, toggle_icon)
        end

        drawTopBtn("toc", self._toc_dimen, self.tw_toc)
        
        local active_bm_icon = (self._view_mode == "split") and self.tw_gallery or self.tw_bm
        drawTopBtn("bm", self._bm_dimen, active_bm_icon)
        
        drawTopBtn("fn", self._fn_dimen, self.tw_fn)
        drawTopBtn("x", self._x_dimen, self.tw_x)
        return
    end

    -- Restauración automática de dimensiones estándar al volver a la grilla o vertical
    local ch_h = self.tw_chapter:getSize().h
    local info_h = self.tw_info:getSize().h
    local slider_h = self._slider:getSize().h
    local bar_h = S(8) + ch_h + S(3) + info_h + S(4) + slider_h + S(10) + S(36) + S(12)
    self._bar_dimen = Geom:new{ x = 0, y = sh - bar_h, w = sw, h = bar_h }
    self._slider.width = sw - pad * 4
    local bd = self._bar_dimen
    local td = self._top_bar_dimen

    bb:paintRect(bd.x, bd.y, bd.w, bd.h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(bd.x, bd.y, bd.w, S(3) - math.max(1, math.floor(S(1) / 2)), Blitbuffer.COLOR_BLACK)   -- linea superior de la barra inferior

    if self._view_mode == "grid_simple" then
        local ok, GridSimpleView = pcall(require, "grid_simple_view")
        if ok and GridSimpleView then
            GridSimpleView.paint(self, bb)
        end
    else
        local title_strip_y = td.y + td.h
        local grid_y = self._grid_dimen and self._grid_dimen.y or title_strip_y
        local title_strip_h = math.max(0, grid_y - title_strip_y)
        
        if not has_wallpaper and title_strip_h > 0 then
            bb:paintRect(0, title_strip_y, sw, title_strip_h, Blitbuffer.COLOR_WHITE)
        end

        -- Barra superior: fondo blanco con línea divisoria si está habilitada
        bb:paintRect(td.x, td.y, td.w, td.h, Blitbuffer.COLOR_WHITE)
        if show_top_line then
            local gray_t = math.max(S(2), math.min(S(3) - 1, S(2) + 1))   -- un poco mas gruesa, siempre menos que la negra
            bb:paintRect(td.x, td.y + td.h - gray_t, td.w, gray_t, Blitbuffer.COLOR_LIGHT_GRAY)
        end
        
        if self._view_mode == "grid" or self._view_mode == "grid_six" then
            if self._view_mode ~= "grid_six" then
                local title_x = pad
                local pill_mode = "none"
                local title_bar = false
                if G_reader_settings then
                    local s_val = G_reader_settings:readSetting("page_scrubber_title_bg")
                    if s_val == "bar" or s_val == "kindle_bar" then
                        title_bar = true
                    elseif s_val == "border" or s_val == true or s_val == "true" or s_val == 1 then
                        pill_mode = "border"
                    elseif s_val == "no_border" or s_val == "borderless" then
                        pill_mode = "no_border"
                    elseif s_val == "translucent" or s_val == "opacity" or s_val == "semi_transparent" then
                        pill_mode = "translucent"
                    elseif s_val == "aura" or s_val == "off" then
                        pill_mode = "aura"
                    else
                        pill_mode = "none"
                    end
                end

                if title_bar then
                    -- Barra blanca de ancho completo desde la linea divisoria de la barra superior
                    -- hasta la altura del titulo, con una linea horizontal en su borde inferior
                    local tsz = self.tw_booktitle:getSize()
                    local bar_top = self._bar_top_y or (self._booktitle_y - S(14))
                    local bar_bot = self._booktitle_y + tsz.h + S(8)
                    local line_t = S(3) - math.max(1, math.floor(S(1) / 2))   -- mismo grosor que la linea negra de la barra inferior (bd)
                    -- Barra blanca de ancho completo; la linea horizontal va en su borde inferior
                    bb:paintRect(0, bar_top, sw, bar_bot - bar_top, Blitbuffer.COLOR_WHITE)
                    bb:paintRect(0, bar_bot - line_t, sw, line_t, Blitbuffer.COLOR_BLACK)
                    -- Título centrado en vertical entre la línea de arriba (la de la barra superior) y la línea negra de abajo
                    local bar_inner_h = (bar_bot - line_t) - bar_top
                    local title_y = bar_top + math.floor((bar_inner_h - tsz.h) / 2)
                    self.tw_booktitle.fgcolor = Blitbuffer.COLOR_BLACK
                    self.tw_booktitle:paintTo(bb, title_x, title_y)
                elseif pill_mode == "border" or pill_mode == "no_border" or pill_mode == "translucent" then
                    local tsz = self.tw_booktitle:getSize()
                    local pad_h = S(12)
                    local pad_v = S(4)
                    local pill_w = tsz.w + pad_h * 2
                    local pill_h = tsz.h + pad_v * 2
                    local pill_x = title_x
                    local pill_y = self._booktitle_y - pad_v
                    local r = math.floor(pill_h / 2)
                    local b = S(2)

                    if pill_mode == "border" then
                        paintRoundRect(bb, pill_x, pill_y, pill_w, pill_h, r, Blitbuffer.COLOR_BLACK)
                        paintRoundRect(bb, pill_x + b, pill_y + b, pill_w - b*2, pill_h - b*2, math.max(1, r - b), Blitbuffer.COLOR_WHITE)
                    elseif pill_mode == "translucent" then
                        if has_wallpaper then
                            paintTranslucentPill(bb, pill_x, pill_y, pill_w, pill_h, r, 0.82)
                        else
                            paintRoundRect(bb, pill_x, pill_y, pill_w, pill_h, r, Blitbuffer.COLOR_WHITE)
                        end
                    else
                        paintRoundRect(bb, pill_x, pill_y, pill_w, pill_h, r, Blitbuffer.COLOR_WHITE)
                    end
                    self.tw_booktitle.fgcolor = Blitbuffer.COLOR_BLACK
                    self.tw_booktitle:paintTo(bb, pill_x + pad_h, self._booktitle_y)
                elseif pill_mode == "aura" and has_wallpaper then
                    paintTextWithHalo(self.tw_booktitle, bb, title_x, self._booktitle_y, self.S(2))
                else
                    self.tw_booktitle.fgcolor = Blitbuffer.COLOR_BLACK
                    self.tw_booktitle:paintTo(bb, title_x, self._booktitle_y)
                end
            end

            if not self._grid_disabled then
                if self._view_mode == "grid_six" then
                    local ok, GridSixView = pcall(require, "grid_six_view")
                    if ok and GridSixView then GridSixView.paint(self, bb) end
                else
                    self:_paintGrid(bb)
                end
            else
                local gd = self._grid_dimen
                bb:paintRect(gd.x, gd.y, gd.w, gd.h, Blitbuffer.COLOR_WHITE)
                local p_dim = self._fallback_prev_dimen
                local n_dim = self._fallback_next_dimen
                local ptsz = self.tw_fb_l:getSize()
                self.tw_fb_l:paintTo(bb, p_dim.x + math.floor((p_dim.w - ptsz.w) / 2), p_dim.y + math.floor((p_dim.h - ptsz.h) / 2))
                local ntsz = self.tw_fb_r:getSize()
                self.tw_fb_r:paintTo(bb, n_dim.x + math.floor((n_dim.w - ntsz.w) / 2), n_dim.y + math.floor((n_dim.h - ntsz.h) / 2))
            end
        elseif self._view_mode == "split" then
            self:_paintSplitView(bb, title_strip_y, title_strip_h)
        end

        local function drawFloatingBtn(btn_id, dimen, tw, is_disabled)
            local is_pressed = (self._pressed_btn == btn_id and btn_id ~= "fn")
            
            local cx = dimen.x + math.floor(dimen.w / 2)
            local cy = dimen.y + math.floor(dimen.h / 2)
            
            if btn_id == "x" or btn_id == "bm" or btn_id == "toc" or btn_id == "grid_toggle" or btn_id == "fn" or btn_id == "lib" then
                local bg_color = (is_pressed and not is_disabled) and Blitbuffer.COLOR_BLACK or nil
                if bg_color then
                    local bg_d = (btn_id == "lib") and self._lib_dimen or dimen
                    paintRoundRect(bb, bg_d.x, bg_d.y, bg_d.w, bg_d.h, S(8), bg_color)
                end
                
                local tsz = tw:getSize()
                local ix = cx - math.floor(tsz.w / 2)
                local iy = cy - math.floor(tsz.h / 2)
                
                if tw.text then
                    if tw.text == "\u{F015}" or tw.text == "\u{F0F6}" or tw.text == "\u{F02D}" or tw.text == "\u{F044}" or tw.text == "\u{F44E}" or tw.text == "\u{F0CA}" or tw.text == "\u{E344}" then
                        iy = iy + S(1)
                    elseif tw.text == "⚙" then
                        iy = iy - S(1) - 1
                        ix = ix - S(1) - 2
                    end
                end

                if is_pressed and not is_disabled then
                    bb:paintRect(ix, iy, tsz.w, tsz.h, Blitbuffer.COLOR_WHITE)
                    tw:paintTo(bb, ix, iy)
                    bb:invertRect(ix, iy, tsz.w, tsz.h)
                else
                    if is_disabled then
                        tw.fgcolor = Blitbuffer.COLOR_LIGHT_GRAY
                    else
                        tw.fgcolor = Blitbuffer.COLOR_BLACK
                    end
                    tw:paintTo(bb, ix, iy)
                end
            end
        end

        drawFloatingBtn("lib", self._lib_icon_dimen, self.tw_lib)
        local is_lib_p_vert = (self._pressed_btn == "lib")
        if self.tw_lib_label then
            if is_lib_p_vert then
                local lsz = self.tw_lib_label:getSize()
                bb:paintRect(self._lib_label_x, self._lib_label_y, lsz.w, lsz.h, Blitbuffer.COLOR_WHITE)
                self.tw_lib_label.fgcolor = Blitbuffer.COLOR_BLACK
                self.tw_lib_label:paintTo(bb, self._lib_label_x, self._lib_label_y)
                bb:invertRect(self._lib_label_x, self._lib_label_y, lsz.w, lsz.h)
            else
                self.tw_lib_label.fgcolor = Blitbuffer.COLOR_BLACK
                self.tw_lib_label:paintTo(bb, self._lib_label_x, self._lib_label_y)
            end
        end

        local toggle_icon = (self._view_mode == "grid_six") and self.tw_gallery or self.tw_grid_toggle
        drawFloatingBtn("grid_toggle", self._grid_toggle_dimen, toggle_icon)
        drawFloatingBtn("toc", self._toc_dimen, self.tw_toc)
        
        local active_bm_icon = (self._view_mode == "split") and self.tw_gallery or self.tw_bm
        drawFloatingBtn("bm", self._bm_dimen, active_bm_icon)
        
        drawFloatingBtn("fn", self._fn_dimen, self.tw_fn)
        drawFloatingBtn("x", self._x_dimen, self.tw_x)
    end

    local current_display = self._cur_page
    local can_prev_ch = self.ui.toc and self.ui.toc:getPreviousChapter(current_display) ~= nil
    local can_next_ch = self.ui.toc and self.ui.toc:getNextChapter(current_display) ~= nil

    local function drawFloatingBtnBottom(btn_id, dimen, tw, is_disabled)
        if is_disabled or not dimen or not tw then return end
        
        local cx = dimen.x + math.floor(dimen.w / 2)
        local cy = dimen.y + math.floor(dimen.h / 2)
        
        local tsz = tw:getSize()
        local y_offset = 0
        if tw.text and type(tw.text) == "string" then
            if tw.text == "\u{F097}" or tw.text == "\u{F02E}" then y_offset = S(1)
            elseif tw.text == "\u{EBAD}" or tw.text == "\u{EBAC}" then y_offset = -S(1)
            elseif tw.text == "\u{F0D9}" or tw.text == "\u{F0DA}" then y_offset = -S(2) end
        end
        
        if btn_id == "ctrl_mark" then 
            y_offset = -S(1) - 1 
            if self._view_mode == "grid_simple" then
                y_offset = y_offset - 1
            end
        end

        local is_pressed = (self._pressed_btn == btn_id and btn_id ~= "ctrl_mark" and btn_id ~= "gsix_prev" and btn_id ~= "gsix_next")
        local draw_x = cx - math.floor(tsz.w / 2)
        local draw_y = cy - math.floor(tsz.h / 2) + y_offset

        if is_pressed then
            local is_bm_ctrl = (btn_id == "ctrl_prev" or btn_id == "ctrl_next")
            if is_bm_ctrl then
                local btn_rad = math.floor(math.min(dimen.w, dimen.h) / 2)
                paintRoundRect(bb, dimen.x, dimen.y, dimen.w, dimen.h, btn_rad, Blitbuffer.COLOR_BLACK)
                if tw.text then
                    tw.fgcolor = Blitbuffer.COLOR_WHITE
                    tw:paintTo(bb, draw_x, draw_y)
                    tw.fgcolor = Blitbuffer.COLOR_BLACK
                else
                    bb:paintRect(draw_x, draw_y, tsz.w, tsz.h, Blitbuffer.COLOR_WHITE)
                    tw:paintTo(bb, draw_x, draw_y)
                    bb:invertRect(draw_x, draw_y, tsz.w, tsz.h)
                end
            else
                local pad = S(6)
                paintRoundRect(bb, draw_x - pad, draw_y - pad, tsz.w + pad*2, tsz.h + pad*2, S(8), Blitbuffer.COLOR_BLACK)
                bb:paintRect(draw_x, draw_y, tsz.w, tsz.h, Blitbuffer.COLOR_WHITE)
                tw:paintTo(bb, draw_x, draw_y)
                bb:invertRect(draw_x, draw_y, tsz.w, tsz.h)
            end
        else
            tw:paintTo(bb, draw_x, draw_y)
        end
    end

    local side_margin_btn = pad + S(6)
    local ch_btn_sz = self._cbtn_sz or S(46)
    local ch_btn_y = self.ch_y_pos + S(2)

    local show_ch_l, show_ch_r
    if self.is_rtl then
        show_ch_l = can_next_ch
        show_ch_r = can_prev_ch
    else
        show_ch_l = can_prev_ch
        show_ch_r = can_next_ch
    end

    if show_ch_l then
        self._prev_ch_dimen = Geom:new{ x = side_margin_btn, y = ch_btn_y, w = ch_btn_sz, h = ch_btn_sz }
        drawFloatingBtnBottom("ch_l", self._prev_ch_dimen, self.tw_ch_l, false)
    else
        self._prev_ch_dimen = nil
    end

    if show_ch_r then
        self._next_ch_dimen = Geom:new{ x = sw - side_margin_btn - ch_btn_sz, y = ch_btn_y, w = ch_btn_sz, h = ch_btn_sz }
        drawFloatingBtnBottom("ch_r", self._next_ch_dimen, self.tw_ch_r, false)
    else
        self._next_ch_dimen = nil
    end

    if self._view_mode == "grid_six" then
        local btn_w = S(50)
        local mark_sz = S(36)

        local can_page_l, can_page_r
        if self.is_rtl then
            can_page_l = (self._cur_page < self._total_pages)
            can_page_r = (self._cur_page > 1)
        else
            can_page_l = (self._cur_page > 1)
            can_page_r = (self._cur_page < self._total_pages)
        end

        if can_page_l then
            self._gsix_prev_dimen = Geom:new{ x = pad * 2, y = self.ctrl_y_pos, w = btn_w, h = mark_sz }
            drawFloatingBtnBottom("gsix_prev", self._gsix_prev_dimen, self.icon_gs_chevron_left, false)
        else
            self._gsix_prev_dimen = nil
        end
        
        if can_page_r then
            self._gsix_next_dimen = Geom:new{ x = sw - pad * 2 - btn_w, y = self.ctrl_y_pos, w = btn_w, h = mark_sz }
            drawFloatingBtnBottom("gsix_next", self._gsix_next_dimen, self.icon_gs_chevron_right, false)
        else
            self._gsix_next_dimen = nil
        end

        if self._cur_page ~= self._origin_page then
            local bg_face = Font:getFace("cfont", self.S_BOTTOM_GRAY or S(14))
            local disp_origin = self:_getDisplayPageInfo(self._origin_page)
            if not self._tw_gsix_origin then
                self._tw_gsix_origin = TextWidget:new{ text = _("Page") .. " " .. disp_origin, face = bg_face, fgcolor = Blitbuffer.COLOR_DARK_GRAY }
            else
                self._tw_gsix_origin.face = bg_face
                self._tw_gsix_origin:setText(_("Page") .. " " .. disp_origin)
            end
            
            local csz = self._tw_gsix_origin:getSize()
            local cx = math.floor(sw / 2)
            local cy = self.ctrl_y_pos + math.floor(mark_sz / 2)
            
            self._gsix_origin_dimen = Geom:new{ x = cx - math.floor(csz.w/2) - S(15), y = cy - math.floor(csz.h/2) - S(10), w = csz.w + S(30), h = csz.h + S(20) }

            local is_pressed = (self._pressed_btn == "gsix_origin")
            if is_pressed then
                paintRoundRect(bb, self._gsix_origin_dimen.x, self._gsix_origin_dimen.y, self._gsix_origin_dimen.w, self._gsix_origin_dimen.h, self.S(8), Blitbuffer.COLOR_BLACK)
                self._tw_gsix_origin.fgcolor = Blitbuffer.COLOR_WHITE
                self._tw_gsix_origin:paintTo(bb, cx - math.floor(csz.w/2), cy - math.floor(csz.h/2))
            else
                self._tw_gsix_origin.fgcolor = Blitbuffer.COLOR_DARK_GRAY
                paintTripleText(self._tw_gsix_origin, bb, cx - math.floor(csz.w/2), cy - math.floor(csz.h/2))
            end
        else
            self._gsix_origin_dimen = nil
        end
    else
        local is_bmed_page = self:_isCurrentPageBookmarked(self._cur_page)
        self.tw_ctrl_mark = is_bmed_page and self.icon_mark_filled or self.icon_mark_empty

        local has_left_bm, has_right_bm
        if self.is_rtl then
            has_left_bm  = (self:_findNextBookmark() ~= nil)
            has_right_bm = (self:_findPrevBookmark() ~= nil)
        else
            has_left_bm  = (self:_findPrevBookmark() ~= nil)
            has_right_bm = (self:_findNextBookmark() ~= nil)
        end

        drawFloatingBtnBottom("ctrl_prev", self._ctrl_prev_dimen, self.tw_ctrl_prev, not has_left_bm)
        
        if self._view_mode == "grid_simple" then
            drawFloatingBtnBottom("ctrl_mark", self._ctrl_mark_dimen, self.tw_gallery, false)
        else
            drawFloatingBtnBottom("ctrl_mark", self._ctrl_mark_dimen, self.tw_ctrl_mark, false)
        end
        
        drawFloatingBtnBottom("ctrl_next", self._ctrl_next_dimen, self.tw_ctrl_next, not has_right_bm)
    end

    if self._view_mode ~= "grid_six" then
        self:_paintBackLabel(bb)
    end
    self:_updateTexts()
    
    local csz_tw = self.tw_chapter:getSize()
    local ctx = math.floor((sw - csz_tw.w) / 2)
    local isz = self.tw_info:getSize()
    local infox = math.floor((sw - isz.w) / 2)

    if self._view_mode == "grid_simple" then
        local btn_center_y = ch_btn_y + math.floor(ch_btn_sz / 2)
        local new_ch_y = btn_center_y - math.floor(csz_tw.h / 2)

        self.tw_chapter:paintTo(bb, ctx, new_ch_y)

        local new_info_y
        if self._gs_panel_dimen then
            local card_bottom = self._gs_panel_dimen.y + self._gs_panel_dimen.h
            new_info_y = card_bottom - isz.h - S(7)
        else
            new_info_y = self._bar_dimen.y - isz.h - S(30)
        end
        
        paintTripleText(self.tw_info, bb, infox, new_info_y)
    elseif not (is_landscape and self._view_mode == "split") then
        self.tw_chapter:paintTo(bb, ctx, self.ch_y_pos)
        paintTripleText(self.tw_info, bb, infox, self.info_y_pos)
    end

    local slider_x = pad * 2
    self._slider.value = current_display
    
    if self._view_mode == "grid_simple" then
        local slider_h = self._slider:getSize().h
        local espacio_arriba = ch_btn_y + ch_btn_sz
        local espacio_abajo = self.ctrl_y_pos
        local nuevo_slider_y = espacio_arriba + math.floor((espacio_abajo - espacio_arriba - slider_h) / 2)
        
        self._slider:paintTo(bb, slider_x, nuevo_slider_y)
    elseif not (is_landscape and self._view_mode == "split") then
        self._slider:paintTo(bb, slider_x, self.slider_y_pos)
    end
end

function PageScrubber:_closeReturn()
    if self._closing then return end
    self._closing = true
    self:_cancelHold()
    
    self._slider._dragging = false
    self._is_busy = false
    self._tasks_in_flight = 0
    self._grid_batch_seq = (self._grid_batch_seq or 0) + 1
    self._grid_batch_id = "safe_close_" .. tostring(os.time())

    local thumbnail = self.ui and self.ui.thumbnail
    if thumbnail and thumbnail.cancelPageThumbnailRequests and type(thumbnail.thumbnails_requests) == "table" then
        for b_id in pairs(thumbnail.thumbnails_requests) do
            if type(b_id) == "string" and b_id:find("^page_scrubber_") then
                thumbnail:cancelPageThumbnailRequests(b_id)
            end
        end
    end
    
    UIManager:nextTick(function()
        if self._cur_page ~= self._origin_page then
            self.ui:handleEvent(Event:new("GotoPage", self._origin_page))
        end
        UIManager:close(self)
        UIManager:setDirty(nil, "full")
    end)
end

function PageScrubber:_closeStay(on_closed_callback)
    if self._closing then return end
    self._closing = true
    self:_cancelHold()
    
    self._slider._dragging = false
    self._is_busy = false
    self._tasks_in_flight = 0
    self._grid_batch_seq = (self._grid_batch_seq or 0) + 1
    self._grid_batch_id = "safe_close_" .. tostring(os.time())

    local thumbnail = self.ui and self.ui.thumbnail
    if thumbnail and thumbnail.cancelPageThumbnailRequests and type(thumbnail.thumbnails_requests) == "table" then
        for b_id in pairs(thumbnail.thumbnails_requests) do
            if type(b_id) == "string" and b_id:find("^page_scrubber_") then
                thumbnail:cancelPageThumbnailRequests(b_id)
            end
        end
    end

    if on_closed_callback then
        UIManager:close(self)
        UIManager:setDirty(nil, "full")
        UIManager:scheduleIn(0.18, function()
            pcall(on_closed_callback)
        end)
    else
        UIManager:nextTick(function()
            UIManager:close(self)
            UIManager:setDirty(nil, "full")
        end)
    end
end

function PageScrubber:_closeAndShow(event_name, event_data)
    if self._closing then return end
    self._closing = true
    self:_cancelHold()
    
    self._slider._dragging = false
    self._is_busy = false
    self._tasks_in_flight = 0
    self._grid_batch_seq = (self._grid_batch_seq or 0) + 1
    self._grid_batch_id = "safe_close_" .. tostring(os.time())

    -- Cancelación inmediata de decodificación en segundo plano para evitar colisiones en C
    local thumbnail = self.ui and self.ui.thumbnail
    if thumbnail and thumbnail.cancelPageThumbnailRequests and type(thumbnail.thumbnails_requests) == "table" then
        for b_id in pairs(thumbnail.thumbnails_requests) do
            if type(b_id) == "string" and b_id:find("^page_scrubber_") then
                thumbnail:cancelPageThumbnailRequests(b_id)
            end
        end
    end
    
    UIManager:close(self)
    UIManager:setDirty(nil, "full")

    -- El scrubber se desmonta y la pantalla refresca el libro antes de abrir la acción
    UIManager:scheduleIn(0.18, function()
        pcall(function()
            if type(event_name) == "function" then
                event_name(event_data)
            elseif type(event_name) == "table" then
                if event_name.callback then
                    event_name.callback(event_data)
                elseif event_name.action then
                    event_name.action(event_data)
                elseif event_name.event then
                    self.ui:handleEvent(Event:new(event_name.event, event_name.arg or event_data))
                else
                    self.ui:handleEvent(event_name)
                end
            elseif type(event_name) == "string" then
                self.ui:handleEvent(Event:new(event_name, event_data))
            end
        end)
    end)
end

-- Alias de seguridad para lanzadores de acciones
PageScrubber.executeAction = PageScrubber._closeAndShow
PageScrubber.executeScrubberAction = PageScrubber._closeAndShow
PageScrubber._closeAndRun = PageScrubber._closeAndShow

-- Botón Library: va al destino de "Start with..." de KOReader.
--   * "homescreen_simpleui" -> evento de SimpleUI (el mismo del gesto "Go to Homescreen").
--   * resto -> cierre nativo del libro (ReaderUI:onClose + showFileManager, igual que
--     ReaderUI:onHome) y, EN EL MISMO TICK, ir a home_dir y abrir historial/favoritos/atajos
--     como hace reader.lua al arrancar (sin esperar con timers, para que no se vea el explorador).
-- Nunca toca self después del cierre del scrubber.
function PageScrubber:_goToLibrary()
    local ui = self.ui
    local start_with = G_reader_settings and G_reader_settings:readSetting("start_with") or "filemanager"

    self:_closeStay(function()
        -- 1) SimpleUI homescreen
        if start_with == "homescreen_simpleui" and ui and ui.handleEvent then
            local ok, handled = pcall(function()
                return ui:handleEvent(Event:new("SimpleUIGoHomescreen"))
            end)
            if ok and handled then return end
        end

        -- 2) Cierre nativo + destino según start_with
        local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
        local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
        if not ok_fm then return end

        local function goDestination()
            local fm = FileManager.instance
            if not fm then return false end
            local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
            if home and fm.file_chooser then
                pcall(function() fm.file_chooser:changeToPath(home) end)
            end
            pcall(function()
                if start_with == "history" and fm.history then
                    fm.history:onShowHist()
                elseif start_with == "favorites" and fm.collections then
                    fm.collections:onShowColl()
                elseif start_with == "folder_shortcuts" and fm.folder_shortcuts then
                    fm.folder_shortcuts:onShowFolderShortcutsDialog()
                end
            end)
            return true
        end

        local rui = ok_rui and ReaderUI.instance
        local closed = false
        if rui then
            local file = rui.document and rui.document.file
            closed = pcall(function()
                rui:onClose()
                rui:showFileManager(file)
            end)
        end

        if closed and goDestination() then return end

        -- Fallback: evento nativo "Home" y esperar al FileManager
        if not closed and ui and ui.handleEvent then
            pcall(function() ui:handleEvent(Event:new("Home")) end)
        end
        local tries = 0
        local function poll()
            tries = tries + 1
            local reader_gone = not (ok_rui and ReaderUI.instance)
            if reader_gone and goDestination() then return end
            if tries < 30 then UIManager:scheduleIn(0.1, poll) end
        end
        UIManager:scheduleIn(0.2, poll)
    end)
end

function PageScrubber:_startHold(action)
    self._hold_active = true
    self._hold_token = self._hold_token + 1
    local current_token = self._hold_token

    local initial_delay = 0.20  -- Arranca rápido una vez reconocido el toque
    local repeat_delay  = 0.65  -- Ritmo constante para darle tiempo a la tinta de pintar bien el texto

    local function rep()
        if not self._hold_active or self._closing or self._hold_token ~= current_token then 
            self:_cancelHold()
            return 
        end

        -- Si el renderizado previo aún está trabajando, esperamos un momento para no colisionar la pantalla
        if self._is_busy then
            UIManager:scheduleIn(0.08, rep)
            return
        end

        local target_page = self._cur_page
        local jump = (self._view_mode == "grid_six") and self:_g6Count() or 1

        if action == "prev" then 
            if target_page > 1 then 
                self._force_menu_sync = true
                self:_stepPreview(self._cur_page - jump) 
            else 
                self:_cancelHold()
                return 
            end
        elseif action == "next" then 
            if target_page < self._total_pages then 
                self._force_menu_sync = true
                self:_stepPreview(self._cur_page + jump) 
            else 
                self:_cancelHold()
                return 
            end
        end

        UIManager:scheduleIn(repeat_delay, rep)
    end

    UIManager:scheduleIn(initial_delay, rep)
end

function PageScrubber:_cancelHold()
    self._hold_active = false
    self._hold_token = self._hold_token + 1
    if self._gs_pressed then self:_gsClearPressed() end
end

-- ==========================================================================
-- Efecto visual al apretar en grid simple (✕ y ‹ ›). SOLO dibujo: no cambia
-- cómo se reconocen ni se ejecutan los gestos (tap / hold / swipe).
-- ==========================================================================
function PageScrubber:_gsRefreshPress(which)
    if self._closing or self._view_mode ~= "grid_simple" then return end
    local mod_name = (self._sw and self._sh and self._sw > self._sh) and "grid_simple_landscape_view" or "grid_simple_view"
    local ok, GSV = pcall(require, mod_name)
    if not (ok and GSV and GSV.pressRect) then return end
    local r = GSV.pressRect(self, which)
    if not r then return end
    local pad = self.S(4)
    UIManager:setDirty(self, "ui", Geom:new{
        x = math.max(0, r.x - pad), y = math.max(0, r.y - pad),
        w = r.w + pad * 2,          h = r.h + pad * 2,
    })
end

function PageScrubber:_gsClearPressed()
    local which = self._gs_pressed
    if not which then return end
    self._gs_pressed = nil
    self._gs_press_token = (self._gs_press_token or 0) + 1
    self:_gsRefreshPress(which)
end

function PageScrubber:_gsSetPressed(which, duration)
    if self._closing or self._gs_pressed == which then return end
    local prev = self._gs_pressed
    self._gs_pressed = which
    self._gs_press_token = (self._gs_press_token or 0) + 1
    if prev then self:_gsRefreshPress(prev) end
    self:_gsRefreshPress(which)

    -- Se apaga solo (si nunca llega un "soltar"); mientras dura un hold sigue encendido
    local token = self._gs_press_token
    local function auto_off()
        if self._closing or self._gs_press_token ~= token or not self._gs_pressed then return end
        if self._hold_active and not duration then
            UIManager:scheduleIn(1.0, auto_off)
            return
        end
        self:_gsClearPressed()
    end
    UIManager:scheduleIn(duration or 1.0, auto_off)
end

function PageScrubber:onTouch(_, ges)
    if self._closing or self._view_mode ~= "grid_simple" or not (ges and ges.pos) then return false end
    local which
    if self._gs_close_dimen and ges.pos:intersectWith(self._gs_close_dimen) then
        which = "close"
    elseif self._gs_prev_dimen and ges.pos:intersectWith(self._gs_prev_dimen) then
        which = "prev"
    elseif self._gs_next_dimen and ges.pos:intersectWith(self._gs_next_dimen) then
        which = "next"
    end
    if which then self:_gsSetPressed(which) end
    return false   -- nunca consume el evento: el táctil sigue exactamente igual que antes
end

function PageScrubber:onHide()
    self:_cancelHold()
end

function PageScrubber:_prevChapter()
    local ui = self.ui
    if ui.toc then
        local p = ui.toc:getPreviousChapter(self._cur_page)
        if p then 
            self._force_menu_sync = true
            self:_previewPage(p, false) 
        end
    end
end

function PageScrubber:_nextChapter()
    local ui = self.ui
    if ui.toc then
        local p = ui.toc:getNextChapter(self._cur_page)
        if p then 
            self._force_menu_sync = true
            self:_previewPage(p, false) 
        end
    end
end

function PageScrubber:onTap(_, ges)
    self:_cancelHold()
    if self._slider then self._slider._dragging = false end
    if self._closing then return true end
    
    if not self._anti_ghost_ready then
        return true 
    end

    if self._view_mode == "grid_six" then
        if self._gsix_prev_dimen and ges.pos:intersectWith(self._gsix_prev_dimen) then
            self:_flashAndDo("gsix_prev", self._gsix_prev_dimen, function()
                self._force_menu_sync = true
                local delta = self.is_rtl and self:_g6Count() or -self:_g6Count()
                self:_stepPreview(self._cur_page + delta)
            end)
            return true
        end
        if self._gsix_next_dimen and ges.pos:intersectWith(self._gsix_next_dimen) then
            self:_flashAndDo("gsix_next", self._gsix_next_dimen, function()
                self._force_menu_sync = true
                local delta = self.is_rtl and -self:_g6Count() or self:_g6Count()
                self:_stepPreview(self._cur_page + delta)
            end)
            return true
        end
        if self._gsix_origin_dimen and ges.pos:intersectWith(self._gsix_origin_dimen) then
            self:_flashAndDo("gsix_origin", self._gsix_origin_dimen, function()
                self._force_menu_sync = true
                self:_previewPage(self._origin_page, false)
            end)
            return true
        end
        
        local mod_name = (self._sw > self._sh) and "grid_six_landscape_view" or "grid_six_view"
        local ok, GridSixMod = pcall(require, mod_name)
        if ok and GridSixMod and GridSixMod.onTap then
            if GridSixMod.onTap(self, ges) then return true end
        end
    end

    if self._view_mode == "grid_simple" and self._gs_panel_dimen then
        if not ges.pos:intersectWith(self._gs_panel_dimen) and not ges.pos:intersectWith(self._bar_dimen) then
            self:_closeReturn()
            return true
        end

        if self._gs_close_dimen and ges.pos:intersectWith(self._gs_close_dimen) then
            self:_closeReturn()
            return true
        end
        if self._gs_prev_dimen and ges.pos:intersectWith(self._gs_prev_dimen) then
            self:_gsSetPressed("prev", 0.25)
            self._force_menu_sync = true
            local delta = self.is_rtl and 1 or -1
            self:_stepPreview(self._cur_page + delta)
            return true
        end
        if self._gs_next_dimen and ges.pos:intersectWith(self._gs_next_dimen) then
            self:_gsSetPressed("next", 0.25)
            self._force_menu_sync = true
            local delta = self.is_rtl and -1 or 1
            self:_stepPreview(self._cur_page + delta)
            return true
        end
        if self._gs_page_dimen and ges.pos:intersectWith(self._gs_page_dimen) then
            self:_gotoPage(self._cur_page)
            self:_closeStay()
            return true
        end
    end

    if self._bm_dimen and ges.pos:intersectWith(self._bm_dimen) then
        if self._view_mode ~= "grid_simple" then
            self:_flashAndDo("bm", self._bm_dimen, function() 
                if self._view_mode == "split" then
                    self._details_open = false; self._view_mode = "grid"
                    self:_clearGridTiles(true)
                    self._is_busy = false
                    self._tasks_in_flight = 0
                    self:_updateTexts()
                    self:_updateGridPages()
                    UIManager:setDirty(self, "full", self.dimen)
                else
                    self._view_mode = "split"
                    self._active_tab = "bookmarks"
                    self._split_fixed_page = self._cur_page
                    self._split_bm_page = self.initial_bm_page or 1
                    self._force_menu_sync = true
                    self:_clearGridTiles(true)
                    self._is_busy = false
                    self._tasks_in_flight = 0
                    self:_updateTexts()
                    self:_updateGridPages()
                    UIManager:setDirty(self, "full", self.dimen)
                end
            end)
            return true
        end
    end

    if self._view_mode == "grid" then
        if self._center_bm_touch_dimen and ges.pos:intersectWith(self._center_bm_touch_dimen) then
            local tgt = self._cur_page
            self:_safeBookmarkToggle(tgt)
            return true
        end
    end

    if self._view_mode == "split" then
        if self._btn_confirm_del_dimen and ges.pos:intersectWith(self._btn_confirm_del_dimen) then
            self:_flashAndDo("confirm_del", self._btn_confirm_del_dimen, function()
                local target_page = self._cur_page
                local current_tab = self._active_tab
                local current_filter = self._hl_filter
                local target_ann = self._split_selected_item and self._split_selected_item.annotation

                self._show_delete_confirm = false
                UIManager:setDirty(self, "ui", self.dimen)

                self:_waitForIdle(function()
                    if self._closing then return end
                    self:_invalidateGridTilesForPage(target_page)
                    local ok, err = pcall(function()
                        self.ui:handleEvent(Event:new("GotoPage", target_page))
                        local an = self.ui.annotation
                        local hl = self.ui.highlight
                        local bk = self.ui.bookmark
                        if an and an.annotations then
                            local found_idx = nil
                            for i, item in ipairs(an.annotations) do
                                if target_ann then
                                    if item == target_ann then
                                        found_idx = i
                                        break
                                    end
                                else
                                    local p = self:_getNumericalPage(item)
                                    if p and math.floor(p) == target_page then
                                        local is_target = true
                                        if current_tab == "highlights" and current_filter then
                                            local d = item.drawer or "lighten"
                                            local mapped = "normal"
                                            if d == "invert" then mapped = "invert"
                                            elseif d == "underscore" then mapped = "underline"
                                            elseif d == "strikeout" then mapped = "strikethrough" end
                                            if mapped ~= current_filter then is_target = false end
                                        end
                                        if current_tab == "notes" then
                                            if not item.note or item.note == "" then is_target = false end
                                        end
                                        if is_target then
                                            found_idx = i
                                            break
                                        end
                                    end
                                end
                            end

                            if found_idx then
                                local item = an.annotations[found_idx]
                                if item and item.drawer and hl and hl.deleteHighlight then
                                    hl:deleteHighlight(found_idx)
                                elseif bk and bk.removeItemByIndex then
                                    bk:removeItemByIndex(found_idx)
                                else
                                    table.remove(an.annotations, found_idx)
                                end
                                if an.saveAnnotations then an:saveAnnotations() end
                            end
                        end
                    end)
                    if not ok then logger.warn("page-scrubber: safe delete failed:", err) end
                    self._split_selected_item = nil; self:_scheduleDetailsResync()
                    self._hide_action_buttons = true
                    self:_extractAnnotations()
                    self._split_bm_page = self.initial_bm_page or 1
                    if not self._closing then
                        self:_updateGridPages()
                        UIManager:setDirty(self, "ui", self.dimen)
                    end
                end)
            end)
            return true
        end

        if self._type_picker_dimens then
            for _, t in ipairs(self._type_picker_dimens) do
                if ges.pos:intersectWith(t.dimen) then
                    if t.key == "__color" then
                        self:_flashAndDo("type___color", t.dimen, function()
                            self:_openColorChangeMenu(t.dimen)
                        end)
                        return true
                    end
                    self:_flashAndDo("type_" .. t.key, t.dimen, function()
                        self:_setHighlightType(t.key)
                    end)
                    return true
                end
            end
        end

        if self._btn_delete_dimen and ges.pos:intersectWith(self._btn_delete_dimen) then
            self._show_delete_confirm = not self._show_delete_confirm
            self._show_type_picker = false
            UIManager:setDirty(self, "ui", self._grid_dimen)
            return true
        end

        if self._btn_type_dimen and ges.pos:intersectWith(self._btn_type_dimen) then
            self._show_type_picker = not self._show_type_picker
            self._show_delete_confirm = false
            UIManager:setDirty(self, "ui", self._grid_dimen)
            return true
        end

        if self._btn_edit_dimen and ges.pos:intersectWith(self._btn_edit_dimen) then
            self:_flashAndDo("edit", self._btn_edit_dimen, function()
                self:_openNoteTextEditor()
            end)
            return true
        end

        if self._show_delete_confirm then
            self._show_delete_confirm = false
            UIManager:setDirty(self, "ui", self._grid_dimen)
        end

        if self._show_type_picker then
            self._show_type_picker = false
            UIManager:setDirty(self, "ui", self._grid_dimen)
        end

        -- Panel de detalles: absorbe los taps dentro de la polaroid (X, flechas, cuerpo)
        if self._details_open and self._details_panel_dimen and ges.pos:intersectWith(self._details_panel_dimen) then
            if self._details_back_dimen and ges.pos:intersectWith(self._details_back_dimen) then
                -- Misma accion que mantener apretado el panel: volver al split menu en esta pagina
                self:_flashAndDo("details_back", self._details_back_dimen, function()
                    self:_closeDetailsPanel(false)
                    self:_zoomDirty(self.dimen)
                end)
                return true
            end
            if self._details_close_dimen and ges.pos:intersectWith(self._details_close_dimen) then
                self:_flashAndDo("details_close", self._details_close_dimen, function()
                    if self._img_zoom and self._img_zoom_cur_key then
                        -- Con zoom, "volver" deja la misma imagen sin zoom (no cierra el panel)
                        self._img_zoom, self._zoom_pan_last, self._img_tap_last = nil, nil, nil
                        self:_zoomDirty()
                    else
                        -- Sin zoom, el boton alterna entre panel normal y expandido
                        self._details_expanded = not self._details_expanded
                        self._hide_action_buttons = true
                        self._show_delete_confirm = false
                        self._show_type_picker = false
                        self._force_menu_sync = true
                        self:_zoomDirty(self.dimen)
                    end
                end)
                return true
            end
            for _, f in ipairs(self._details_filter_dimens or {}) do
                if ges.pos:intersectWith(f.dimen) then
                    -- Mismo comportamiento que los filtros del menu derecho: tocar el activo lo apaga
                    if self._active_tab == "images" then
                        if self._img_folder == f.key then self._img_folder = nil else self._img_folder = f.key end
                    else
                        if self._hl_filter == f.key then self._hl_filter = nil else self._hl_filter = f.key end
                    end
                    self._split_bm_page = 1
                    self._split_selected_item = nil; self:_scheduleDetailsResync()
                    UIManager:setDirty(self, "ui", self.dimen)
                    return true
                end
            end
            if self._details_link_dimen and ges.pos:intersectWith(self._details_link_dimen) then
                -- Igual que mantener apretada la tarjeta: ir a esta pagina del libro y cerrar
                self:_flashAndDo("details_link", self._details_link_dimen, function()
                    self:_gotoPage(self._cur_page)
                    self:_closeStay()
                end)
                return true
            end
            for _, nb in ipairs(self._details_nav_dimens or {}) do
                if nb.enabled and ges.pos:intersectWith(nb.dimen) then
                    if nb.key == "dots" then
                        -- Puntitos: salta al mas cercano al toque (como en el indice)
                        local t = math.floor((ges.pos.x - nb.x0) / nb.pitch + 0.5) + 1
                        self:_detailsStep("goto", t)
                    else
                        self:_flashAndDo("details_" .. nb.key, nb.dimen, function()
                            self:_detailsStep(nb.key)
                        end)
                    end
                    return true
                end
            end
            -- Imagen: doble tap hace zoom (centrado donde tocaste); con zoom, doble tap vuelve al tamano original
            if self._img_zoom_cur_key then
                local now = monoNow()
                local last = self._img_tap_last
                if last and now - last.t < 0.5 and math.abs(ges.pos.x - last.x) < self.S(60)
                   and math.abs(ges.pos.y - last.y) < self.S(60) then
                    self._img_tap_last, self._zoom_pan_last = nil, nil
                    if self._img_zoom then
                        self._img_zoom = nil
                    else
                        local r = self._img_view_rect
                        local cx, cy = 0.5, 0.5
                        if r and r.w > 0 and r.h > 0 then
                            cx = math.max(0, math.min(1, (ges.pos.x - r.x) / r.w))
                            cy = math.max(0, math.min(1, (ges.pos.y - r.y) / r.h))
                        end
                        self._img_zoom = { key = self._img_zoom_cur_key, z = 2.5, cx = cx, cy = cy }
                    end
                    self:_zoomDirty()
                else
                    self._img_tap_last = { t = now, x = ges.pos.x, y = ges.pos.y }
                end
            end
            return true
        end

        if self._tab_sort_dimen and ges.pos:intersectWith(self._tab_sort_dimen) then
            self._sort_order = (self._sort_order == "asc") and "desc" or "asc"
            self._split_bm_page = 1
            self._force_menu_sync = false
            self._hide_action_buttons = true
            UIManager:setDirty(self, "ui", self.dimen)
            return true
        end

        if self._active_tab == "images" then
            -- "Page" saca el filtro de carpeta (todas las imagenes); los iconos eligen la carpeta
            if self._hl_main_tab_dimen and ges.pos:intersectWith(self._hl_main_tab_dimen) and self._img_folder ~= nil then
                self._img_folder = nil
                self._split_bm_page = 1
                self._split_selected_item = nil; self:_scheduleDetailsResync()
                UIManager:setDirty(self, "ui", self.dimen)
                return true
            end
            for _, f in ipairs(self._hl_filter_dimens or {}) do
                if ges.pos:intersectWith(f.dimen) then
                    if self._img_folder == f.key then self._img_folder = nil else self._img_folder = f.key end
                    self._split_bm_page = 1
                    self._split_selected_item = nil; self:_scheduleDetailsResync()
                    UIManager:setDirty(self, "ui", self.dimen)
                    return true
                end
            end
        end

        if self._tab_img_dimen and ges.pos:intersectWith(self._tab_img_dimen) then
            self._active_tab = "images"
            self._hl_filter = nil
            self._hl_color_filter = nil
            self._img_folder = nil
            self._split_bm_page = 1
            self._split_selected_item = nil; self:_scheduleDetailsResync()
            self:_imgEnsureScan()
            UIManager:setDirty(self, "ui", self.dimen)
            return true
        end

        if self._tab_arrow_dimen and (self._active_tab == "highlights" or self._active_tab == "notes")
           and ges.pos:intersectWith(self._tab_arrow_dimen) then
            self:_openColorMenu(self._tab_arrow_tab_dimen)
            return true
        end

        if self._tab_hl_dimen and ges.pos:intersectWith(self._tab_hl_dimen) then
            self._active_tab = "highlights"
            self._hl_filter = self.initial_hl_filter or nil
            self._hl_color_filter = nil
            self._split_bm_page = self.initial_bm_page or 1
            self._split_selected_item = nil; self:_scheduleDetailsResync()
            self:_extractAnnotations()
            UIManager:setDirty(self, "ui", self.dimen)
            return true
        end

        if (self._active_tab == "highlights" or self._active_tab == "notes") and self._hl_main_tab_dimen and ges.pos:intersectWith(self._hl_main_tab_dimen) then
            if self._hl_filter ~= nil or self._hl_color_filter ~= nil then
                self._hl_filter = nil
                self._hl_color_filter = nil
                self._split_bm_page = 1
                self._split_selected_item = nil; self:_scheduleDetailsResync()
                UIManager:setDirty(self, "ui", self.dimen)
                return true
            end
        end

        if (self._active_tab == "highlights" or self._active_tab == "notes") and self._hl_filter_dimens then
            for _, f in ipairs(self._hl_filter_dimens) do
                if ges.pos:intersectWith(f.dimen) then
                    if self._hl_filter == f.key then
                        self._hl_filter = nil
                    else
                        self._hl_filter = f.key
                    end
                    self._split_bm_page = 1
                    self._split_selected_item = nil; self:_scheduleDetailsResync()
                    UIManager:setDirty(self, "ui", self.dimen)
                    return true
                end
            end
        end
        
        if self._tab_bm_dimen and ges.pos:intersectWith(self._tab_bm_dimen) then
            self._active_tab = "bookmarks"
            self._hl_filter = nil
            self._hl_color_filter = nil
            self._split_bm_page = 1
            self._split_selected_item = nil; self:_scheduleDetailsResync()
            self:_extractAnnotations()
            UIManager:setDirty(self, "ui", self.dimen)
            return true
        end

        if self._tab_note_dimen and ges.pos:intersectWith(self._tab_note_dimen) then
            self._active_tab = "notes"
            self._hl_filter = nil
            self._hl_color_filter = nil
            self._split_bm_page = 1
            self._split_selected_item = nil; self:_scheduleDetailsResync()
            self:_extractAnnotations()
            UIManager:setDirty(self, "ui", self.dimen)
            return true
        end

        -- Tap en el tab de repaso: abre el Review Card
        if self._tab_review_dimen and ges.pos:intersectWith(self._tab_review_dimen) then
            self:_flashAndDo("study", self._tab_review_dimen, function() self:_openReviewCard() end)
            return true
        end

        if self._split_fixed_toggle_dimen and ges.pos:intersectWith(self._split_fixed_toggle_dimen) then
            local tgt = self._split_fixed_page or self._origin_page
            self:_safeBookmarkToggle(tgt)
            return true
        end
        
        if self._split_fixed_row_dimen and ges.pos:intersectWith(self._split_fixed_row_dimen) then
            local tgt_page = self._split_fixed_page or self._origin_page
            if self._details_open then
                -- Con el panel de detalles abierto, tocar la fila fijada lo cierra y vuelve a la
                -- previsualizacion de la pagina fijada (sin reabrir el panel)
                self:_closeDetailsPanel(false)
                self._force_menu_sync = true
                self:_previewPage(tgt_page, false)
                UIManager:setDirty(self, "ui", self.dimen)
                return true
            end
            if self._cur_page == tgt_page then
                -- Volver a tocar la fila abre el panel de detalles (al grid se entra tocando la pagina)
                if self:_openDetailsPanel() then return true end
                if self._base_grid_mode == "grid_simple" then
                    self:_reopenWithMode("grid_simple", tgt_page)
                else
                    self._details_open = false; self._view_mode = "grid"
                    self:_clearGridTiles(true)
                    self._is_busy = false
                    self._tasks_in_flight = 0
                    self:_updateTexts()
                    self:_updateGridPages()
                    UIManager:setDirty(self, "full", self.dimen)
                end
            else
                self._force_menu_sync = true
                self:_previewPage(tgt_page, false)
                UIManager:setDirty(self, "ui", self.dimen)
            end
            return true
        end
        
        if self._split_prev_dimen and ges.pos:intersectWith(self._split_prev_dimen) then
            self:_flashAndDo("split_prev", self._split_prev_dimen, function()
                self._split_bm_page = math.max(1, (self._split_bm_page or 1) - 1)
                UIManager:setDirty(self, "ui", self._grid_dimen)
            end)
            return true
        end
        if self._split_next_dimen and ges.pos:intersectWith(self._split_next_dimen) then
            self:_flashAndDo("split_next", self._split_next_dimen, function()
                self._split_bm_page = (self._split_bm_page or 1) + 1
                UIManager:setDirty(self, "ui", self._grid_dimen)
            end)
            return true
        end
        
        if self._split_rows then
            for _, row in ipairs(self._split_rows) do
                if ges.pos:intersectWith(row.toggle_dimen) then
                    local order_num = (type(row.item) == "table" and row.item.order) or 1
                    local flash_id = "row_toggle_" .. tostring(row.page) .. "_" .. tostring(order_num)
                    self:_flashAndDo(flash_id, row.toggle_dimen, function()
                        if self._active_tab == "bookmarks" then
                            self:_safeBookmarkToggle(row.page)
                        elseif self._active_tab == "images" then
                            self:_imgToggleFavorite(row.item)
                            UIManager:setDirty(self, "ui", self.dimen)
                        else
                            local was_same = (self._split_selected_item == row.item and self._cur_page == row.page)
                            local new_hide_state = was_same and (not self._hide_action_buttons) or false
                            self._split_selected_item = row.item
                            self._force_menu_sync = true
                            self:_previewPage(row.page, false)
                            self._hide_action_buttons = new_hide_state
                            UIManager:setDirty(self, "ui", self.dimen)
                        end
                    end)
                    return true
                end
                
                if ges.pos:intersectWith(row.dimen) then
                    if self._active_tab == "bookmarks" then
                        if self._cur_page == row.page then
                            if self._details_open then self:_closeDetailsPanel(false); return true end
                            if self:_openDetailsPanel() then return true end
                            if self._base_grid_mode == "grid_simple" then
                                self:_reopenWithMode("grid_simple", row.page)
                            else
                                self._details_open = false; self._view_mode = "grid"
                                self:_clearGridTiles(true)
                                self._is_busy = false
                                self._tasks_in_flight = 0
                                self:_updateTexts()
                                self:_updateGridPages()
                                UIManager:setDirty(self, "full", self.dimen)
                            end
                        else
                            self._force_menu_sync = true
                            self:_previewPage(row.page, false)
                            UIManager:setDirty(self, "ui", self.dimen)
                        end
                    else
                        -- En Destacados y Notas: solo sale al lector si se pulsa el MISMO ítem que ya estaba seleccionado
                        local was_already_selected = (self._split_selected_item == row.item and self._cur_page == row.page)
                        self._split_selected_item = row.item
                        if was_already_selected then
                            if self._details_open then self:_closeDetailsPanel(false); return true end
                            if self:_openDetailsPanel() then return true end
                            if self._base_grid_mode == "grid_simple" then
                                self:_reopenWithMode("grid_simple", row.page)
                            else
                                self._details_open = false; self._view_mode = "grid"
                                self:_clearGridTiles(true)
                                self._is_busy = false
                                self._tasks_in_flight = 0
                                self:_updateTexts()
                                self:_updateGridPages()
                                UIManager:setDirty(self, "full", self.dimen)
                            end
                        else
                            -- Cambia entre (1), (2), (3) manteniendo los botones ocultos hasta pulsar el lápiz
                            self._force_menu_sync = true
                            self:_previewPage(row.page, false)
                            self._hide_action_buttons = true
                            UIManager:setDirty(self, "ui", self.dimen)
                        end

                    end
                    return true
                end
            end
        end
        
        -- Tap en la linea de texto bajo la polaroid: abre el panel de detalles de la anotacion
        if self._split_chin_dimen and not self._details_open and ges.pos:intersectWith(self._split_chin_dimen) then
            if self:_openDetailsPanel() then return true end
        end

        if self._split_preview_dimen and ges.pos:intersectWith(self._split_preview_dimen) then
            if self._base_grid_mode == "grid_simple" then
                self:_reopenWithMode("grid_simple", self._cur_page)
            else
                self._details_open = false; self._view_mode = "grid"
                self:_clearGridTiles(true)
                self._is_busy = false
                self._tasks_in_flight = 0
                self:_updateTexts()
                self:_updateGridPages()
                UIManager:setDirty(self, "full", self.dimen)
            end
            return true
        end
    end

    if self._view_mode ~= "grid_simple" then
        if self._grid_toggle_dimen and ges.pos:intersectWith(self._grid_toggle_dimen) then
            self:_flashAndDo("grid_toggle", self._grid_toggle_dimen, function()
                if self._view_mode == "grid_six" then
                    self._details_open = false; self._view_mode = "grid"
                else
                    self._view_mode = "grid_six"
                end
                
                local S = self.S
                if self._sw > self._sh then
                    self._grid_dimen.y = self._top_bar_dimen.y + self._top_bar_dimen.h + S(8)
                    self._grid_dimen.h = self._bar_dimen.y - self._grid_dimen.y - S(8)
                elseif self._view_mode == "grid_six" then
                    self._grid_dimen.y = self._top_bar_dimen.y + self._top_bar_dimen.h + S(26)
                    self._grid_dimen.h = self._bar_dimen.y - self._grid_dimen.y - S(26)
                else
                    self._grid_dimen.y = self._booktitle_y + self.tw_booktitle:getSize().h + S(8)
                    self._grid_dimen.h = self._bar_dimen.y - self._grid_dimen.y
                end

                self:_clearGridTiles(true)
                self._is_busy = false
                self._tasks_in_flight = 0
                self:_updateTexts()
                self:_updateGridPages()
                UIManager:setDirty(self, "full", self.dimen)
            end)
            return true
        end

        if self._lib_dimen and ges.pos:intersectWith(self._lib_dimen) then
            self:_flashAndDo("lib", self._lib_dimen, function() self:_goToLibrary() end)
            return true
        end
        
        if self._fn_dimen and ges.pos:intersectWith(self._fn_dimen) then
            local ScrubberMenu = require("scrubber_menu")
            local UIManager = require("ui/uimanager")
            UIManager:show(ScrubberMenu:new{
                ui = self.ui,
                scrubber_ui = self,
            })
            return true
        end

        if self._toc_dimen and ges.pos:intersectWith(self._toc_dimen) then
            self:_flashAndDo("toc", self._toc_dimen, function() 
                local ScrubberToc = require("scrubber_toc")
                local mi_nuevo_toc = ScrubberToc:new{
                    ui = self.ui,
                    initial_page = self._cur_page,
                    initial_origin = self._origin_page,
                    parent_scrubber = self,
                    is_rtl = self.is_rtl,
                }
                local UIManager = require("ui/uimanager")
                UIManager:show(mi_nuevo_toc)
            end)
            return true
        end
    
        if self._x_dimen and ges.pos:intersectWith(self._x_dimen) then
            self:_flashAndDo("x", self._x_dimen, function() self:_closeReturn() end)
            return true
        end
    end

    if self._ctrl_prev_dimen and ges.pos:intersectWith(self._ctrl_prev_dimen) then
        local target
        if self.is_rtl then
            target = self:_findNextBookmark()
        else
            target = self:_findPrevBookmark()
        end
        if target then
            self:_flashAndDo("ctrl_prev", self._ctrl_prev_dimen, function()
                self._force_menu_sync = true
                self:_previewPage(target, false)
            end)
        end
        return true
    end
    
    if self._ctrl_mark_dimen and ges.pos:intersectWith(self._ctrl_mark_dimen) then
        if self._view_mode == "grid_simple" then
            self:_flashAndDo("ctrl_mark", self._ctrl_mark_dimen, function()
                self:_reopenWithMode("grid", self._cur_page)
            end)
            return true
        elseif self._view_mode == "grid_six" then
            return true
        end
        self:_flashAndDo("ctrl_mark", self._ctrl_mark_dimen, function()
            self:_safeBookmarkToggle(self._cur_page)
        end)
        return true
    end
    
    if self._ctrl_next_dimen and ges.pos:intersectWith(self._ctrl_next_dimen) then
        local target
        if self.is_rtl then
            target = self:_findPrevBookmark()
        else
            target = self:_findNextBookmark()
        end
        if target then
            self:_flashAndDo("ctrl_next", self._ctrl_next_dimen, function()
                self._force_menu_sync = true
                self:_previewPage(target, false)
            end)
        end
        return true
    end
    
    if self._prev_ch_dimen and ges.pos:intersectWith(self._prev_ch_dimen) then
        if self.is_rtl then self:_nextChapter() else self:_prevChapter() end
        return true
    end
    if self._next_ch_dimen and ges.pos:intersectWith(self._next_ch_dimen) then
        if self.is_rtl then self:_prevChapter() else self:_nextChapter() end
        return true
    end
    
    -- Solo evaluar tap en el slider si el toque ocurre físicamente en la franja de la barra inferior
    if self._bar_dimen and ges.pos and ges.pos.y >= self._bar_dimen.y then
        if self._slider:handleTap(ges) then
            self._force_menu_sync = true
            return true 
        end
    end

    -- Evaluación prioritaria de las tarjetas de la grilla antes de descartar por barra inferior
    if self._view_mode == "grid" and not self._grid_disabled and self._grid_dimen and ges.pos:intersectWith(self._grid_dimen) then
        local nb_items = self._grid_cols * self._grid_rows
        for idx = 1, nb_items do
            local rect = self:_gridSlotDimen(idx)
            if ges.pos:intersectWith(rect) then
                local slot = self._grid_tiles[idx]
                if slot and slot.page then
                    if idx == 2 then
                        self:_gotoPage(slot.page)
                        self:_closeStay()
                    elseif slot.error then
                        slot.error = false
                        slot.loading = true
                        UIManager:setDirty(self, "ui", rect)
                        self._thumb_req_w = (self._thumb_req_w == self._grid_item_w) and (self._grid_item_w + 1) or self._grid_item_w
                        self:_updateGridPages()
                    else
                        self:_stepPreview(slot.page)
                    end
                end
                return true
            end
        end
        return true
    end

    if self._grid_back_dimen and ges.pos:intersectWith(self._grid_back_dimen) then
        self:_flashAndDo("grid_back", self._grid_back_dimen, function()
            self._force_menu_sync = true
            self:_previewPage(self._origin_page, false)
        end)
        return true
    end

    if self._bar_dimen and ges.pos:intersectWith(self._bar_dimen) then return true end
    if self._top_bar_dimen and ges.pos:intersectWith(self._top_bar_dimen) then return true end

    if self._grid_disabled and self._grid_dimen and ges.pos:intersectWith(self._grid_dimen) then
        if ges.pos.intersectWith and ges.pos:intersectWith(self._fallback_prev_dimen) then
            self:_stepPreview(self._cur_page - 1)
        elseif ges.pos.intersectWith and ges.pos:intersectWith(self._fallback_next_dimen) then
            self:_stepPreview(self._cur_page + 1)
        else
            self:_gotoPage(self._cur_page)
            self:_closeStay()
        end
        return true
    end

    return true
end

function PageScrubber:onPan(_, ges)
    if self._closing or not self._anti_ghost_ready then return true end
    if self:_imgZoomPan(ges) then return true end
    local on_bar = self._bar_dimen and ges.pos and (ges.pos.y >= self._bar_dimen.y - self.S(10))
    if on_bar and self._slider and self._slider:handlePan(ges) then
        self._force_menu_sync = true
        return true 
    end
    self:_cancelHold()
    return true
end

function PageScrubber:onPanRelease(_, ges)
    self:_cancelHold()
    if self._closing then return end
    if self:_imgZoomed(ges) then
        self._zoom_pan_last, self._zoom_pan_seen, self._zoom_pan_t = nil, nil, nil
        self:_zoomDirty()
        return true
    end
    if self._zoom_pan_last then
        -- Fin del arrastre con zoom: repinta con la posicion final
        self._zoom_pan_last, self._zoom_pan_seen, self._zoom_pan_t = nil, nil, nil
        self:_zoomDirty()
        return true
    end
    self._last_drag_time = os.clock()
    self._scrubbing_blank = false
    self._drag_token = (self._drag_token or 0) + 1

    local was_dragging = self._slider and self._slider._dragging
    if self._slider and was_dragging then
        self._slider:handlePanRelease(ges)
        if not self._grid_disabled then self:_updateGridPages() end
        UIManager:setDirty(self, "partial")
        return true
    end
    return true
end

function PageScrubber:onRelease(_, ges)
    self:_cancelHold()
    self._scrubbing_blank = false
    self._drag_token = (self._drag_token or 0) + 1

    local was_dragging = self._slider and self._slider._dragging
    if self._slider and was_dragging then
        self._last_drag_time = os.clock()
        self._slider:handlePanRelease(ges)
        if not self._grid_disabled then self:_updateGridPages() end
        UIManager:setDirty(self, "partial")
    end
    return true
end

function PageScrubber:onPinch(_, ges)
    if self._closing then return true end
    if self:_imgZoomApply(ges, false) then return true end
    if self._grid_disabled then return true end
    if self._view_mode == "grid" then
        self._view_mode = "grid_six"
        local S = self.S
        self._grid_dimen.y = self._top_bar_dimen.y + self._top_bar_dimen.h + S(26)
        self._grid_dimen.h = self._bar_dimen.y - self._grid_dimen.y - S(26)
        self:_clearGridTiles(true)
        self._is_busy = false
        self._tasks_in_flight = 0
        self:_updateTexts()
        self:_updateGridPages()
        UIManager:setDirty(self, "full", self.dimen)
    end
    return true
end

function PageScrubber:onSpread(_, ges)
    if self._closing then return true end
    if self:_imgZoomApply(ges, true) then return true end
    if self._grid_disabled then return true end
    if self._view_mode == "grid_six" then
        self._view_mode = "grid"
        local S = self.S
        self._grid_dimen.y = self._booktitle_y + self.tw_booktitle:getSize().h + S(8)
        self._grid_dimen.h = self._bar_dimen.y - self._grid_dimen.y
        self:_clearGridTiles(true)
        self._is_busy = false
        self._tasks_in_flight = 0
        self:_updateTexts()
        self:_updateGridPages()
        UIManager:setDirty(self, "full", self.dimen)
    end
    return true
end

function PageScrubber:onSwipe(_, ges)
    if self._closing or not self._anti_ghost_ready then return true end

    -- Bloquea swipes accidentales inmediatamente posteriores al arrastre del slider
    local now = os.clock()
    if self._last_drag_time and (now - self._last_drag_time) < 0.35 and not self:_imgZoomed(ges) then
        return true
    end

    -- El slider SOLO debe capturar swipes realizados dentro de la barra inferior
    local on_bar = self._bar_dimen and ges.pos and (ges.pos.y >= self._bar_dimen.y - self.S(10))
    if on_bar and self._slider and self._slider:handleSwipe(ges) then
        self._scrubbing_blank = false
        self._force_menu_sync = true
        if not self._grid_disabled then self:_updateGridPages() end
        UIManager:setDirty(self, "partial")
        return true
    end

    if on_bar then return true end

    if self._view_mode == "split" and self._details_open and self._details_panel_dimen and ges.pos
       and ges.pos:intersectWith(self._details_panel_dimen) then
        if self:_imgZoomSwipe(ges) then return true end   -- con zoom el arrastre mueve la imagen, no cambia de imagen
        if ges.direction == "west" then
            self:_detailsStep("next")
        elseif ges.direction == "east" then
            self:_detailsStep("prev")
        elseif ges.direction == "north" then
            self:_scrollDetails(1, ges.pos)
        elseif ges.direction == "south" then
            self:_scrollDetails(-1, ges.pos)
        end
        return true
    end

    if self._view_mode == "split" and ges.pos then
        local sw = Screen:getWidth()
        local div_x = self._split_divider_x or math.floor(sw * 0.65)

        if ges.pos.x > div_x then
            -- Lado derecho (Lista): paginación estándar
            if ges.direction == "west" then
                self._split_bm_page = (self._split_bm_page or 1) + 1
                UIManager:setDirty(self, "ui", self.dimen)
                return true
            elseif ges.direction == "east" then
                self._split_bm_page = math.max(1, (self._split_bm_page or 1) - 1)
                UIManager:setDirty(self, "ui", self.dimen)
                return true
            end
        else
            -- Lado izquierdo (Previsualización):
            -- LTR: deslizar al oeste avanza (+1), al este retrocede (-1)
            -- RTL: deslizar al este avanza (+1), al oeste retrocede (-1)
            local step = 0
            if ges.direction == "west" then
                step = self.is_rtl and -1 or 1
            elseif ges.direction == "east" then
                step = self.is_rtl and 1 or -1
            end

            if step ~= 0 then
                self._force_menu_sync = false
                self:_stepPreview(self._cur_page + step)
                return true
            end
        end
    end

    local jump = (self._view_mode == "grid_six") and self:_g6Count() or 1
    local swipe_forward = (ges.direction == "west")
    local swipe_backward = (ges.direction == "east")
    if self.is_rtl then
        swipe_forward = (ges.direction == "east")
        swipe_backward = (ges.direction == "west")
    end

    if swipe_forward then
        self._force_menu_sync = true
        self:_stepPreview(self._cur_page + jump) 
        return true
    elseif swipe_backward then
        self._force_menu_sync = true
        self:_stepPreview(self._cur_page - jump) 
        return true
    elseif ges.direction == "south" then
        self:_closeReturn()
        return true
    end
    return false
end

function PageScrubber:onMultiSwipe(_, ges)
    if self._closing then return true end
    if self:_imgZoomed(ges) then
        -- Varios swipes rapidos seguidos sobre la imagen con zoom: solo cierra el arrastre y repinta
        self._zoom_pan_last, self._zoom_pan_seen, self._zoom_pan_t = nil, nil, nil
        self:_zoomDirty()
        return true
    end
    if ges.direction == "south" then
        self:_closeReturn()
        return true
    end
    return false
end

function PageScrubber:onHold(_, ges)
    if self._closing then return end

    -- Con zoom, un dedo que se detiene un instante mientras arrastras la imagen NO debe disparar el
    -- "ir a la pagina y cerrar" de la tarjeta/filas (en modo expandido el panel cubre mucha mas area)
    if self:_imgZoomed(ges) then
        return true
    end

    -- Mantener apretado sobre el panel de detalles: vuelve al split menu en esa misma pagina, con la
    -- previsualizacion mostrando esa pagina (para ir al libro esta la linea "Show in book")
    if self._view_mode == "split" and self._details_open and self._details_panel_dimen
       and ges.pos and ges.pos:intersectWith(self._details_panel_dimen) then
        self:_cancelHold()
        self:_closeDetailsPanel(false)
        self:_zoomDirty(self.dimen)
        return true
    end

    if self._fn_dimen and ges.pos:intersectWith(self._fn_dimen) then
        self:_cancelHold()
        local ScrubberSettings = require("scrubber_settings")
        UIManager:show(ScrubberSettings:new{
            ui = self.ui,
            scrubber_ui = self,
            current_view = "actions_launcher",
        })
        return true
    end

    if self._view_mode ~= "grid_simple" then
        if self._bm_dimen and ges.pos:intersectWith(self._bm_dimen) then
            self:_cancelHold()
            self._view_mode = "split"
            self._active_tab = "highlights"
            self._hl_filter = nil
            self._hl_color_filter = nil
            self._split_fixed_page = self._cur_page
            self._split_bm_page = 1
            self._split_selected_item = nil
            self._force_menu_sync = true
            self:_extractAnnotations()
            self:_clearGridTiles(true)
            self._is_busy = false
            self._tasks_in_flight = 0
            self:_updateTexts()
            self:_updateGridPages()
            UIManager:setDirty(self, "full", self.dimen)
            return true
        end

        if self._grid_toggle_dimen and ges.pos:intersectWith(self._grid_toggle_dimen) then
            self:_cancelHold()
            self:_reopenWithMode("grid_simple", self._cur_page)
            return true
        end

        if self._toc_dimen and ges.pos:intersectWith(self._toc_dimen) then
            self:_cancelHold()
            local ScrubberToc = require("scrubber_toc")
            local mi_nuevo_toc = ScrubberToc:new{
                ui = self.ui,
                initial_page = self._cur_page,
                initial_origin = self._origin_page,
                parent_scrubber = self,
                is_rtl = self.is_rtl,
                initial_expanded = true,
            }
            local UIManager = require("ui/uimanager")
            UIManager:show(mi_nuevo_toc)
            return true
        end
    end

    if self._view_mode == "grid_simple" then
        if self._gs_prev_dimen and ges.pos:intersectWith(self._gs_prev_dimen) then
            self:_gsSetPressed("prev")
            self:_startHold(self.is_rtl and "next" or "prev"); return true
        end
        if self._gs_next_dimen and ges.pos:intersectWith(self._gs_next_dimen) then
            self:_gsSetPressed("next")
            self:_startHold(self.is_rtl and "prev" or "next"); return true
        end
        if self._gs_page_dimen and ges.pos:intersectWith(self._gs_page_dimen) then
            self:_reopenWithMode("split", self._cur_page); return true
        end
    end

    if self._ctrl_mark_dimen and ges.pos:intersectWith(self._ctrl_mark_dimen) then
        if self._view_mode == "grid_simple" or self._view_mode == "grid_six" then
            return true
        elseif self._view_mode == "grid" then
            self._view_mode = "split"
            self._active_tab = "bookmarks"
            self._split_fixed_page = self._cur_page
            self._split_bm_page = self.initial_bm_page or 1
            self._force_menu_sync = true
            self:_clearGridTiles()
            self:_previewPage(self._cur_page, false)
        else
            self._view_mode = "grid"
            self:_clearGridTiles()
            self:_previewPage(self._cur_page, false)
        end
        return true
    end
    
    if self._view_mode == "split" then
        if self._split_rows then
            for _, row in ipairs(self._split_rows) do
                if ges.pos:intersectWith(row.dimen) and not ges.pos:intersectWith(row.toggle_dimen) then
                    self:_gotoPage(row.page)
                    self:_closeStay()
                    return true
                end
            end
        end
        
        local fixed_page = self._split_fixed_page or self._origin_page
        if self._split_fixed_row_dimen and ges.pos:intersectWith(self._split_fixed_row_dimen) and not ges.pos:intersectWith(self._split_fixed_toggle_dimen) then
            self:_gotoPage(fixed_page)
            self:_closeStay()
            return true
        end

        if self._split_preview_dimen and ges.pos:intersectWith(self._split_preview_dimen) then
            self:_gotoPage(self._cur_page)
            self:_closeStay()
            return true
        end

        return true 
    end

    if not self._grid_disabled and self._grid_dimen then
        if self._view_mode == "grid_six" then
            local ok, GridSixView = pcall(require, "grid_six_view")
            if ok and GridSixView and GridSixView.getSlotDimens then
                local slots = GridSixView.getSlotDimens(self)
                if slots then
                    local g6_origin = self:_g6Origin()
                    for idx = 1, self:_g6Count() do
                        if slots[idx] and ges.pos:intersectWith(slots[idx]) then
                            local target_page = self._cur_page + (idx - g6_origin)
                            if target_page >= 1 and target_page <= self._total_pages then
                                self._view_mode = "split"
                                self._active_tab = "bookmarks"
                                self._split_fixed_page = target_page
                                self._split_bm_page = self.initial_bm_page or 1
                                self._force_menu_sync = true
                                self:_clearGridTiles(true)
                                self._is_busy = false
                                self._tasks_in_flight = 0
                                self:_updateTexts()
                                self:_updateGridPages()
                                UIManager:setDirty(self, "full", self.dimen)
                            end
                            return true
                        end
                    end
                end
            end
            return true
        elseif self._view_mode == "grid" then
            if ges.pos:intersectWith(self:_gridSlotDimen(1)) then
                self:_startHold(self.is_rtl and "next" or "prev"); return true
            end
            if ges.pos:intersectWith(self:_gridSlotDimen(3)) then
                self:_startHold(self.is_rtl and "prev" or "next"); return true
            end
            if ges.pos:intersectWith(self:_gridSlotDimen(2)) then
                self._view_mode = "split"
                self._active_tab = "bookmarks"
                self._split_fixed_page = self._cur_page
                self._split_bm_page = self.initial_bm_page or 1
                self._force_menu_sync = true
                self:_clearGridTiles(true)
                self._is_busy = false
                self._tasks_in_flight = 0
                self:_updateTexts()
                self:_updateGridPages()
                UIManager:setDirty(self, "full", self.dimen)
                return true
            end
        end
    elseif self._grid_disabled and self._grid_dimen then
        if ges.pos and ges.pos.intersectWith and ges.pos:intersectWith(self._fallback_prev_dimen) then
            self:_startHold("prev"); return true
        end
        if ges.pos and ges.pos.intersectWith and ges.pos:intersectWith(self._fallback_next_dimen) then
            self:_startHold("next"); return true
        end
    end
    return true
end

function PageScrubber:onHoldRelease(_, ges)
    local was_holding = self._hold_active
    self:_cancelHold()
    if was_holding then
        if not self._grid_disabled then self:_updateGridPages() end
        UIManager:setDirty(self, "ui")
    end
    return true
end

function PageScrubber:onCloseWidget()
    self._closing = true
    if self._imgFree then self:_imgFree() end
    self:_freeDetailsWidgets()
    self:_cancelHold()
    self._drag_token = (self._drag_token or 0) + 1
    
    self._slider._dragging = false
    self._is_busy = false
    self._tasks_in_flight = 0
    self._grid_batch_seq = (self._grid_batch_seq or 0) + 1
    self._grid_batch_id = "safe_close_" .. tostring(os.time())

    -- Aborta cualquier petición de miniaturas pendiente del plugin en ReaderThumbnail
    local thumbnail = self.ui and self.ui.thumbnail
    if thumbnail and thumbnail.cancelPageThumbnailRequests and type(thumbnail.thumbnails_requests) == "table" then
        for b_id in pairs(thumbnail.thumbnails_requests) do
            if type(b_id) == "string" and b_id:find("^page_scrubber_") then
                thumbnail:cancelPageThumbnailRequests(b_id)
            end
        end
    end

    if not self._grid_disabled then
        if self._tile_cache then
            for _, item in pairs(self._tile_cache) do
                if item.is_scaled and item.bb then
                    pcall(function() item.bb:free() end)
                end
            end
            self._tile_cache = {}
        end
        self._grid_tiles = {}
        UIManager:scheduleIn(0.01, function()
            if self.ui and self.ui.thumbnail and self.ui.thumbnail.tidyCache then
                pcall(function() self.ui.thumbnail:tidyCache() end)
            end
        end)
    end

    if ScrubberWallpaper and ScrubberWallpaper.free then
        ScrubberWallpaper.free()
    end

    if self._old_can_do then Device.canDoSwipeAnimation = self._old_can_do end
    if self._saved_swipe_animations ~= nil then Screen.swipe_animations = self._saved_swipe_animations end

    local widgets_to_free = {
        self._tw_row_normal, self._tw_row_bold,
        self._tw_row_super_normal, self._tw_row_super_bold,
        self._tw_tab_count_normal, self._tw_tab_count_bold, self._tw_tab_color_name,
        self._tw_preview_text, self._tw_header_page, self._tw_empty_list, self._tw_pagination,
        self._tw_tab_sort, self._tw_tab_bm, self._tw_tab_hl, self._tw_tab_note,
        self.tw_booktitle, self.tw_chapter, self.tw_info,
        self.tw_lib, self.tw_lib_label, self.tw_fn, self.tw_bm, self.tw_gallery, self.tw_toc, self.tw_grid_toggle, self.tw_x,
        self.icon_gs_x_inv, self.icon_gs_chevron_left_inv, self.icon_gs_chevron_right_inv,
        self.icon_tab_chev_down, self.icon_tab_chev_up, self.icon_tab_review, self.icon_study_alert, self.icon_study_done,
        self.tw_ch_l, self.tw_ch_r,
        self.tw_ctrl_prev, self.tw_ctrl_next,
        self.tw_fb_l, self.tw_fb_r,
        self._tw_grid_error, self._tw_grid_back_icon, self._tw_grid_back,
        self._tw_gs_clock, self._tw_gs_error,
        self._tw_gsix_page,
        self._slider, self._tw_gsix_origin
    }
    
    for _, w in ipairs(widgets_to_free) do
        if w and w.free then
            pcall(function() w:free() end)
        end
    end
end

function PageScrubber:onClose()
    self:_closeStay()
    return true
end
    
-- Tab de imagenes (images_tab.lua + image_scanner.lua). Si faltan, el tab simplemente no aparece.
do
    local okIT, ImagesTab = pcall(require, "images_tab")
    if okIT and type(ImagesTab) == "table" and ImagesTab.install then
        local okI, errI = pcall(ImagesTab.install, PageScrubber, _)
        if not okI then logger.warn("page-scrubber images tab install error:", errI) end
    end
end

return PageScrubber

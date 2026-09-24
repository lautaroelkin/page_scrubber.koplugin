local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local ImageWidget = require("ui/widget/imagewidget")

local Screen = Device.screen
local plugin_path = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"

local ReaderHighlight = nil
pcall(function() ReaderHighlight = require("apps/reader/modules/readerhighlight") end)

local modern_plugin_buttons_shared = {}

local FloatingDict = {
    ui = nil,
    enabled = true,
    patched_dictionary = nil,
    opening_original_popup = false,
}

local SETTING_DICT_ENABLED = "page_scrubber_floating_dict_enabled"
local SETTING_SELECTION_ENABLED = "page_scrubber_selection_menu_enabled"

local function getScale()
    return (G_reader_settings and G_reader_settings:readSetting("page_scrubber_popup_scale")) or 1.0
end
local function getTextOffset()
    if not G_reader_settings then return 0 end
    local size = G_reader_settings:readSetting("page_scrubber_text_size")
    if size == "small" then return -5
    elseif size == "large" then return 5
    end
    return 0
end
local function scale(px)
    return math.floor(Screen:scaleBySize(px) * getScale() + 0.5)
end
local function scaleText(px)
    return scale(px + getTextOffset())
end

local function is_btn_enabled(key)
    if not G_reader_settings then return true end
    local val = G_reader_settings:readSetting(key)
    if val == nil then return true end
    return val == true
end

local function htmlEscape(text)
    text = tostring(text or "")
    text = text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
    return text
end

local function shouldAnchorTop(boxes)
    if type(boxes) ~= "table" or #boxes == 0 then return false end
    local selection_bottom
    for _, box in ipairs(boxes) do
        if type(box) == "table" and box.y and box.h then
            local box_bottom = box.y + box.h
            if not selection_bottom or box_bottom > selection_bottom then
                selection_bottom = box_bottom
            end
        end
    end
    if not selection_bottom then return false end
    return selection_bottom > (Screen:getHeight() / 2)
end

local function shouldAnchorLeft(boxes)
    if type(boxes) ~= "table" or #boxes == 0 then return false end
    local min_x, max_x
    for _, box in ipairs(boxes) do
        if type(box) == "table" and box.x and box.w then
            if not min_x or box.x < min_x then min_x = box.x end
            local right = box.x + box.w
            if not max_x or right > max_x then max_x = right end
        end
    end
    if not min_x or not max_x then return false end
    -- Si la palabra está en la mitad derecha (> 50%), el diccionario ancla en la izquierda
    return ((min_x + max_x) / 2) > (Screen:getWidth() / 2)
end

local function cleanWordForLookup(raw_word)
    if not raw_word then return nil end
    local s = tostring(raw_word)
    s = s:gsub("<[^>]+>", "")
    s = s:gsub("^[%s%p¿¡«»“”\"']+", ""):gsub("[%s%p¿¡«»“”\"']+$", "")
    s = s:match("^%s*(.-)%s*$") or s
    if #s > 0 then return s end
    return nil
end

-- ==========================================
-- DIBUJO DE BORDES REDONDEADOS
-- ==========================================
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
    if not round_br then bb:paintRect(x + w - r,   y + h - r, r, r, color) end
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

-- ==========================================
-- TARJETA DICCIONARIO (ADAPTABLE VERTICAL / HORIZONTAL)
-- ==========================================
local FloatingCard = WidgetContainer:extend({
    anchor_top = false,
    anchor_left = false,
    is_landscape = false,
    radius = scale(24),
    bordersize = scale(3),
    content = nil,
})
function FloatingCard:init()
    local c_sz = self.content:getSize()
    local b = self.bordersize
    local pad_top, pad_bot, pad_left, pad_right = 0, 0, 0, 0

    if self.is_landscape then
        self.dimen = Geom:new({ w = c_sz.w + b, h = Screen:getHeight() })
        if self.anchor_left then pad_right = b else pad_left = b end
    else
        self.dimen = Geom:new({ w = c_sz.w, h = c_sz.h + b })
        if self.anchor_top then pad_bot = b else pad_top = b end
    end
    
    self.frame = FrameContainer:new({
        padding_top = pad_top, padding_bottom = pad_bot,
        padding_left = pad_left, padding_right = pad_right,
        bordersize = 0, background = nil,
        self.content
    })
    self[1] = self.frame
end
function FloatingCard:getSize() return self.dimen end
function FloatingCard:paintTo(bb, x, y)
    local w, h = self.dimen.w, self.dimen.h
    local b = self.bordersize
    local r = self.radius

    if self.is_landscape then
        -- MODO HORIZONTAL: concéntrico usando paintCornerRect
        local by = y - b
        local bh = h + (b * 2)
        local round_tl = not self.anchor_left
        local round_tr = self.anchor_left
        local round_bl = not self.anchor_left
        local round_br = self.anchor_left

        paintCornerRect(bb, x, by, w, bh, r, Blitbuffer.COLOR_BLACK,
            round_tl, round_tr, round_bl, round_br)

        local wx = self.anchor_left and x or (x + b)
        local ww = w - b
        local wr = math.max(0, r - b)
        paintCornerRect(bb, wx, y, ww, h, wr, Blitbuffer.COLOR_WHITE,
            round_tl, round_tr, round_bl, round_br)
    else
        -- MODO VERTICAL
        local bx = x - b
        local bw = w + (b * 2)
        paintCornerRect(bb, bx, y, bw, h, r, Blitbuffer.COLOR_BLACK, 
            not self.anchor_top, not self.anchor_top, self.anchor_top, self.anchor_top)
        
        local wy = self.anchor_top and y or (y + b)
        local wh = h - b
        local wr = math.max(0, r - b)
        paintCornerRect(bb, x, wy, w, wh, wr, Blitbuffer.COLOR_WHITE,
            not self.anchor_top, not self.anchor_top, self.anchor_top, self.anchor_top)
    end
        
    if self[1] then self[1]:paintTo(bb, x, y) end
end

-- ==========================================
-- TARJETA MULTI-SELECCIÓN (PÍLDORA FLOTANTE)
-- ==========================================
local FloatingPillCard = WidgetContainer:extend({
    radius = scale(16),
    bordersize = scale(2),
    content = nil,
})
function FloatingPillCard:init()
    local c_sz = self.content:getSize()
    local b = self.bordersize
    self.dimen = Geom:new({ w = c_sz.w + (b * 2), h = c_sz.h + (b * 2) })
    
    self.frame = FrameContainer:new({
        padding_top = b,
        padding_bottom = b,
        padding_left = b,
        padding_right = b,
        bordersize = 0,
        background = nil,
        self.content
    })
    self[1] = self.frame
end
function FloatingPillCard:getSize() return self.dimen end
function FloatingPillCard:paintTo(bb, x, y)
    local w, h = self.dimen.w, self.dimen.h
    local b = self.bordersize
    local r = self.radius

    paintCornerRect(bb, x, y, w, h, r, Blitbuffer.COLOR_BLACK, true, true, true, true)
    
    local wr = math.max(0, r - b)
    paintCornerRect(bb, x + b, y + b, math.max(0, w - (b * 2)), math.max(0, h - (b * 2)), wr, Blitbuffer.COLOR_WHITE, true, true, true, true)
        
    if self[1] then self[1]:paintTo(bb, x, y) end
end

-- ==========================================
-- CSS DINÁMICO (TIPOGRAFÍA AJUSTADA)
-- ==========================================
local function getBookFontFamilyName(ui)
    local doc_family
    if ui and ui.font and ui.font.configurable then
        doc_family = ui.font.configurable.font_face
    end
    if not doc_family and ui and ui.font then
        doc_family = ui.font.font_face
    end
    if not doc_family and ui and ui.doc_settings then
        doc_family = ui.doc_settings:readSetting("font_face")
              or ui.doc_settings:readSetting("font_family")
              or ui.doc_settings:readSetting("cre_font_family")
    end
    if not doc_family and G_reader_settings then
        doc_family = G_reader_settings:readSetting("cre_font_family")
              or G_reader_settings:readSetting("font_face")
              or G_reader_settings:readSetting("font_family")
    end
    return doc_family
end

-- Cachea la resolución de archivos de fuente por nombre de familia + archivo
-- del libro. Sin esto, getBookFontPaths llamaba a credoc.engineInit +
-- cre.getFontFaceFilenameAndFaceIndex (hasta 4 veces) en CADA apertura del
-- diccionario -- cada palabra mantenida, cada búsqueda interna. Se incluye el
-- archivo del libro en la clave porque dos EPUBs distintos pueden tener una
-- fuente EMBEBIDA con el mismo nombre genérico mapeando a archivos distintos.
local _font_paths_cache = {}

local function getBookFontPaths(ui)
    local regular = "fonts/noto/NotoSans-Regular.ttf"
    local bold = "fonts/noto/NotoSans-Bold.ttf"
    local italic = "fonts/noto/NotoSans-Italic.ttf"
    local bolditalic = "fonts/noto/NotoSans-BoldItalic.ttf"

    if G_reader_settings then
        local cfont = G_reader_settings:readSetting("cfont")
        if type(cfont) == "string" and cfont ~= "" then
            regular = cfont
            bold = G_reader_settings:readSetting("cfont_b") or cfont
            italic = G_reader_settings:readSetting("cfont_i") or cfont
            bolditalic = G_reader_settings:readSetting("cfont_bi") or cfont
        end
    end

    local doc_family = getBookFontFamilyName(ui)

    if doc_family and doc_family ~= "" then
        local doc_file = (ui and ui.document and ui.document.file) or ""
        local cache_key = doc_family .. "|" .. doc_file
        local cached = _font_paths_cache[cache_key]
        if cached then
            return cached[1], cached[2], cached[3], cached[4]
        end

        local ok, credoc = pcall(require, "document/credocument")
        if ok and credoc and credoc.engineInit then
            local ok2, cre = pcall(credoc.engineInit, credoc)
            if ok2 and cre and cre.getFontFaceFilenameAndFaceIndex then
                local fn_reg = cre.getFontFaceFilenameAndFaceIndex(doc_family, false, false)
                            or cre.getFontFaceFilenameAndFaceIndex(doc_family)
                            or cre.getFontFaceFilenameAndFaceIndex(doc_family, nil, true)
                if fn_reg then
                    regular = fn_reg
                    bold = cre.getFontFaceFilenameAndFaceIndex(doc_family, true, false) or fn_reg
                    italic = cre.getFontFaceFilenameAndFaceIndex(doc_family, false, true) or fn_reg
                    bolditalic = cre.getFontFaceFilenameAndFaceIndex(doc_family, true, true) or bold or fn_reg
                end
            end
        end
        _font_paths_cache[cache_key] = { regular, bold, italic, bolditalic }
    end
    return regular, bold, italic, bolditalic
end

local function getBookRawFontSize(ui)
    local size
    if ui and ui.font and ui.font.configurable then
        size = ui.font.configurable.font_size
    end
    if not size and ui and ui.font and type(ui.font.font_size) == "number" then
        size = ui.font.font_size
    end
    if not size and ui and ui.doc_settings then
        size = ui.doc_settings:readSetting("font_size")
              or ui.doc_settings:readSetting("cre_font_size")
    end
    if not size and G_reader_settings then
        size = G_reader_settings:readSetting("cre_font_size")
              or G_reader_settings:readSetting("font_size")
              or G_reader_settings:readSetting("kopt_font_size")
    end
    return size or 26
end

local function getDictFontSize(ui)
    local base_fs = getBookRawFontSize(ui) or 26
    -- Tamaño exacto 1:1 con la letra del libro
    return scale(math.max(8, base_fs))
end

local function getMetaFontSize(ui)
    local base_fs = getBookRawFontSize(ui) or 26
    -- Exactamente 1 punto más chica que la letra del libro
    return scale(math.max(7, base_fs - 1))
end

local function getDictLineHeight(ui)
    local pct
    -- 1. Consultar el módulo de fuentes activo en vivo
    if ui and ui.font then
        if ui.font.configurable then
            pct = ui.font.configurable.line_space_percent
               or ui.font.configurable.line_spacing
        end
        if not pct then
            pct = ui.font.line_space_percent
               or ui.font.line_spacing
        end
    end
    -- 2. Consultar ajustes guardados del documento
    if not pct and ui and ui.doc_settings then
        pct = ui.doc_settings:readSetting("line_space_percent")
           or ui.doc_settings:readSetting("line_spacing")
           or ui.doc_settings:readSetting("cre_line_space_percent")
    end
    -- 3. Consultar ajustes globales
    if not pct and G_reader_settings then
        pct = G_reader_settings:readSetting("line_space_percent")
           or G_reader_settings:readSetting("line_spacing")
           or G_reader_settings:readSetting("cre_line_space_percent")
    end

    pct = tonumber(pct) or 100
    if pct > 0 and pct <= 3 then
        pct = pct * 100
    end

    -- Base 1.30em multiplicado por la escala del libro con unidad explícita para CREngine
    local base_em = 1.30
    local calc_em = base_em * (pct / 100)
    return string.format("%.2fem", calc_em)
end

local function getBaseCss(ui)
    local reg, bld, ita, bita = getBookFontPaths(ui)
    local doc_family = getBookFontFamilyName(ui) or "serif"
    local lh = getDictLineHeight(ui)
    local meta_fs = getMetaFontSize(ui)
    return string.format([[
@font-face { font-family: "BookFont"; src: url("%s"); }
@font-face { font-family: "BookFont"; src: url("%s"); font-weight: bold; }
@font-face { font-family: "BookFont"; src: url("%s"); font-style: italic; }
@font-face { font-family: "BookFont"; src: url("%s"); font-weight: bold; font-style: italic; }

* { font-family: "BookFont", "%s", serif !important; }

@page { margin: 0; }
body { margin: 0; padding: 0 0.45em; line-height: %s; }
p, div, li { line-height: %s !important; margin: 0 0 0.28em 0; }
ol, ul { padding-left: 1.35em; margin-top: 0.18em; margin-bottom: 0.28em; }

.floatingdictionary-word { font-size: 1.20em !important; font-weight: bold !important; line-height: 1.20em !important; color: #000000 !important; }
.floatingdictionary-meta { margin-top: 0.20em; margin-bottom: 0.35em; font-size: %dpx !important; color: #111111 !important; font-style: italic; text-transform: uppercase; line-height: 1.25em !important; }
.search-content, .search-content * { font-size: 1.0em !important; line-height: %s !important; color: #000000 !important; }
.search-content { font-weight: normal !important; }
.search-content b, .search-content strong { font-weight: bold !important; }
]], reg, bld, ita, bita, doc_family, lh, lh, meta_fs, lh)
end

local function getBookFace(ui, size, bold)
    local reg, bld = getBookFontPaths(ui)
    local font_file = bold and bld or reg
    if font_file and font_file ~= "" then
        local ok, face = pcall(Font.getFace, Font, font_file, size)
        if ok and face then
            return face
        end
    end
    return Font:getFace("cfont", size)
end

-- ==========================================
-- VERIFICADOR DE SVG SEGURO
-- ==========================================
local function getValidSvgPath(svg_name)
    if not svg_name then return nil end
    local variants = {
        svg_name,
        svg_name:gsub("-", "_"),
        svg_name:gsub("_", "-")
    }
    for _, name in ipairs(variants) do
        local paths = {
            plugin_path .. "icons/" .. name,
            plugin_path .. name,
            "resources/icons/" .. name,
            "resources/icons/svg/" .. name
        }
        for _, p in ipairs(paths) do
            local f = io.open(p, "r")
            if f then
                f:close()
                return p
            end
        end
    end
    return nil
end

-- ==========================================
-- WIDGET BOTÓN REUTILIZABLE
-- ==========================================
local PreviewButton = InputContainer:extend({
    icon_svg = nil, icon_char = nil, text = nil, font_size = nil, width = nil, height = nil, callback = nil, show_parent = nil, always_show_text = false, icon_size = nil, face = nil, bold = nil,
})
function PreviewButton:init()
    local inner_h = self.height or scale(48)
    local content_elements = {}

    local icon_widget = nil
    if self.icon_svg then
        local icon_sz = self.icon_size or scale(24)
        local ok, widget = pcall(function()
            return ImageWidget:new{
                file = self.icon_svg,
                width = icon_sz,
                height = icon_sz,
                alpha = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
                original_in_nightmode = false,
            }
        end)
        if ok and widget then
            icon_widget = widget
        end
    end

    if not icon_widget and self.icon_char then
        icon_widget = TextWidget:new{
            text = self.icon_char,
            face = self.face or Font:getFace("cfont", self.font_size or scaleText(14)),
            fgcolor = Blitbuffer.COLOR_BLACK
        }
    end
    
    if icon_widget then
        table.insert(content_elements, icon_widget)
    end

    if self.text and (not icon_widget or self.always_show_text) then
        if icon_widget then
            table.insert(content_elements, VerticalSpan:new({ width = scale(1) }))
        end
        self._text_widget = TextWidget:new({
            text = self.text, 
            face = self.face or Font:getFace("cfont", self.font_size or scaleText(12)), 
            bold = (self.bold ~= nil) and self.bold or (self.face == nil), 
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = self.width and (self.width - scale(4)) or nil,
            truncate_with_ellipsis = true
        })
        table.insert(content_elements, self._text_widget)
    end
    
    if #content_elements == 0 then
        self._text_widget = TextWidget:new({
            text = "?", 
            face = Font:getFace("cfont", self.font_size or scaleText(8)), 
            fgcolor = Blitbuffer.COLOR_BLACK
        })
        table.insert(content_elements, self._text_widget)
    end

    local btn_content = CenterContainer:new({ 
        dimen = Geom:new({ w = self.width, h = inner_h })
    })
    btn_content[1] = VerticalGroup:new(content_elements)
    
    self.frame = FrameContainer:new({ show_parent = self.show_parent, bordersize = 0, padding_left = 0, padding_right = 0 })
    self.frame[1] = btn_content
    self.dimen = self.frame:getSize()
    self[1] = self.frame
    self.ges_events = { TapSelectButton = { GestureRange:new({ ges = "tap", range = self.dimen }) } }
end

function PreviewButton:setText(new_text)
    self.text = new_text
    if self._text_widget then
        self._text_widget:setText(new_text)
        if self.show_parent then
            UIManager:setDirty(self.show_parent, "ui")
        else
            UIManager:setDirty(self, "ui")
        end
    end
end

function PreviewButton:onTapSelectButton()
    if self.callback then self.callback(); return true end
    return false
end

-- ==========================================
-- HACK DE CURSOR REDONDEADO
-- ==========================================
local function applyRoundedScrollbar(htmlwidget)
    local original_paintTo = htmlwidget.paintTo
    htmlwidget.paintTo = function(self, bb, x, y)
        local sb = self.scrollbar
        self.scrollbar = nil 
        original_paintTo(self, bb, x, y)
        self.scrollbar = sb
        
        if sb and self.virtual_dimen and self.virtual_dimen.h > self.dimen.h then
            local max_h = self.dimen.h
            local max_v = self.virtual_dimen.h
            local thumb_h = math.max(scale(24), math.floor(max_h * max_h / max_v))
            local thumb_y = y + math.floor((self.pos / max_v) * max_h)
            if thumb_y + thumb_h > y + max_h then thumb_y = y + max_h - thumb_h end
            
            local sw = scale(6)
            local sx = x + self.dimen.w - sw - scale(2)
            paintCornerRect(bb, sx, thumb_y, sw, thumb_h, math.floor(sw/2), Blitbuffer.COLOR_GRAY, true, true, true, true)
        end
    end
end

-- ==========================================
-- LÓGICA DE PLUGINS EXTERNOS (SOLO DICCIONARIO)
-- ==========================================
function FloatingDict:discoverExternalButtons(dict_self, word, result, result_index, results, boxes, link, popup_instance)
    local all_buttons = {}
    if not (self.ui and self.ui.handleEvent) then return {} end

    result = result or {}
    
    local active_highlight = (popup_instance and popup_instance.highlight_obj)
        or (dict_self and dict_self.highlight)
        or (self.ui and self.ui.highlight)

    local active_selected_text = (active_highlight and active_highlight.selected_text)
        or { text = word, pos0 = nil, pos1 = nil }

    if active_highlight and not active_highlight.selected_text then
        active_highlight.selected_text = active_selected_text
    end

    local clean_w = (type(cleanWordForLookup) == "function" and cleanWordForLookup(word)) or word

    local fake_popup = {
        ui = self.ui,
        dialog = popup_instance or (dict_self and dict_self.dialog),
        dimen = Geom:new({x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight()}),
        highlight = active_highlight,
        selected_text = active_selected_text,
        text = word,
        word = word,
        clean_text = clean_w,
        clean_word = clean_w,
        lookupword = result.word or word,
        results = results,
        boxes = boxes,
        word_boxes = boxes,
        selected_link = link,
        is_wiki = false,
        dict_index = result_index or 1,
        dictionary = result.dict,
        lang = result.lang,
        close = function()
            if popup_instance then UIManager:close(popup_instance) end
        end,
        onClose = function()
            if popup_instance then UIManager:close(popup_instance) end
        end,
        closeWidget = function()
            if popup_instance then UIManager:close(popup_instance) end
        end,
        updateButtons = function() end,
    }

    if popup_instance then
        setmetatable(fake_popup, { __index = popup_instance })
    end

    local fake_button_table = { 
        getButtonById = function(self_tbl, id)
            local real_btn = fake_popup._real_buttons and fake_popup._real_buttons[id]
            return { 
                width = real_btn and real_btn.width or scale(100),
                dimen = real_btn and real_btn.dimen or Geom:new({w = scale(100), h = scale(40)}),
                setText = function(self_btn, text) 
                    if real_btn then
                        real_btn:setText(text)
                    end
                end, 
                refresh = function() end, 
                enable = function() end, 
                disable = function() end 
            } 
        end 
    }

    fake_button_table.button_by_id = setmetatable({}, {
        __index = function(t, id)
            return fake_button_table:getButtonById(id)
        end
    })

    fake_popup.button_table = fake_button_table

    local seen_ids = {}

    local function extract_btn_text(s)
        local t = s.text or s.menu_text or "?"
        if type(s.text_func) == "function" then
            local ok, res = pcall(s.text_func, fake_popup)
            if ok and res then t = res end
        end
        return t
    end

    local function scan_for_buttons(tbl)
        if type(tbl) ~= "table" then return end
        for k, v in pairs(tbl) do
            if type(v) == "table" then
                if v.id and type(v.callback) == "function" then
                    modern_plugin_buttons_shared[v.id] = v
                elseif type(k) == "number" or type(k) == "string" then
                    for sub_k, sub_v in pairs(v) do
                        if type(sub_v) == "table" and sub_v.id and type(sub_v.callback) == "function" then
                            modern_plugin_buttons_shared[sub_v.id] = sub_v
                        end
                    end
                end
            end
        end
    end
    
    if dict_self then
        scan_for_buttons(dict_self.dict_plugin_buttons)
        scan_for_buttons(dict_self.dict_buttons_by_id)
        scan_for_buttons(dict_self.dict_buttons)
        scan_for_buttons(dict_self.registered_buttons)
    end

    for id, spec in pairs(modern_plugin_buttons_shared) do
        local should_show = true
        if type(spec.show_func) == "function" then
            local ok_show, res = pcall(spec.show_func, fake_popup)
            should_show = ok_show and res
        end

        if should_show and type(spec.callback) == "function" and not seen_ids[spec.id] then
            table.insert(all_buttons, {
                id = spec.id,
                text = extract_btn_text(spec),
                callback = function() return spec.callback(fake_popup) end,
                fake_popup = fake_popup,
                row_group = spec.row_group
            })
            seen_ids[spec.id] = true
        end
    end

    local legacy_rows = {
        { { id = "dummy1" } },
        { { id = "dummy2" } }
    }
    seen_ids["dummy1"] = true
    seen_ids["dummy2"] = true

    local original_add_to_dict = nil
    if self.ui and self.ui.dictionary then
        original_add_to_dict = self.ui.dictionary.addToDictButtons
        self.ui.dictionary.addToDictButtons = nil
    end

    pcall(function()
        self.ui:handleEvent(Event:new("DictButtonsReady", fake_popup, legacy_rows))
    end)

    if self.ui and self.ui.dictionary then
        self.ui.dictionary.addToDictButtons = original_add_to_dict
    end

    local legacy_group_counter = 1
    for _, item in ipairs(legacy_rows) do
        if type(item) == "table" then
            if type(item.callback) == "function" then
                if not seen_ids[item.id] then
                    table.insert(all_buttons, {
                        id = item.id,
                        text = extract_btn_text(item),
                        callback = function() return item.callback(fake_popup) end,
                        fake_popup = fake_popup,
                        row_group = item.row_group
                    })
                    seen_ids[item.id] = true
                end
            else
                local auto_group = "legacy_row_" .. legacy_group_counter
                legacy_group_counter = legacy_group_counter + 1
                
                for _, spec in ipairs(item) do
                    if type(spec) == "table" and type(spec.callback) == "function" and not seen_ids[spec.id] then
                        table.insert(all_buttons, {
                            id = spec.id,
                            text = extract_btn_text(spec),
                            callback = function() return spec.callback(fake_popup) end,
                            fake_popup = fake_popup,
                            row_group = spec.row_group or auto_group
                        })
                        seen_ids[spec.id] = true
                    end
                end
            end
        end
    end

    local grouped_rows_map = {}
    for _, btn in ipairs(all_buttons) do
        local group_name = btn.row_group
        if not group_name and btn.id then
            group_name = btn.id:match("^([a-zA-Z0-9]+)_") or btn.id
        end
        group_name = group_name or "ungrouped"
        
        grouped_rows_map[group_name] = grouped_rows_map[group_name] or {}
        table.insert(grouped_rows_map[group_name], btn)
    end

    local sorted_group_names = {}
    for grp in pairs(grouped_rows_map) do table.insert(sorted_group_names, grp) end
    
    table.sort(sorted_group_names, function(a, b)
        local len_a = #grouped_rows_map[a]
        local len_b = #grouped_rows_map[b]
        if len_a == len_b then
            return a < b
        end
        return len_a < len_b
    end)

    local final_rows = {}
    for _, grp in ipairs(sorted_group_names) do
        table.insert(final_rows, grouped_rows_map[grp])
    end

    return final_rows
end

-- ==========================================
-- TARJETA: PALABRA ÚNICA (DICCIONARIO ORIGINAL)
-- ==========================================
local FloatingDictionaryPopup = InputContainer:extend({
    text = nil, results = nil, boxes = nil, anchor_top = false, anchor_left = false, is_landscape = false,
    highlight_obj = nil, plugin = nil, current_result_idx = 1,
})
function FloatingDictionaryPopup:init()
    self.dialog = self.dialog or self
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()
    self.is_landscape = (screen_width > screen_height)

    self.width = self.is_landscape and math.floor(screen_width * 0.48) or screen_width
    local content_w = self.is_landscape and (self.width - scale(3)) or self.width

    self.current_result_idx = self.current_result_idx or 1
    local total_dicts = self.results and #self.results or 1
    local entry = self.results and self.results[self.current_result_idx] or {}
    
    local dict_name = tostring(entry.dict or "Diccionario")
    local def_body = tostring(entry.definition or "<p>Sin definición.</p>")
    if not def_body:find("<") then def_body = "<p>" .. htmlEscape(def_body):gsub("\n", "<br/>") .. "</p>" end
    
    local dict_indicator = ""
    if total_dicts > 1 then
        dict_indicator = string.format("<b>[%d/%d]</b> &nbsp;&bull;&nbsp; ", self.current_result_idx, total_dicts)
    end

    local html_body = string.format([[
        <div class="floatingdictionary-meta">%s%s</div>
        <div class="search-content">%s</div>
    ]], dict_indicator, htmlEscape(dict_name), def_body)

    local ui_instance = self.plugin and self.plugin.ui
    local icon_btn_specs = {}

    local external_rows = {}
    
    local base_buttons = {}
    if is_btn_enabled("page_scrubber_fdict_show_wiki") then
        table.insert(base_buttons, { svg = "globe.svg", text = "Wiki", action = "wiki" })
    end
    if is_btn_enabled("page_scrubber_fdict_show_translate") then
        table.insert(base_buttons, { svg = "languages.svg", text = "Translate", action = "translate" })
    end
    if is_btn_enabled("page_scrubber_fdict_show_ai") then
        table.insert(base_buttons, { svg = "sparkles.svg", text = "AI", action = "ai" })
    end
    if is_btn_enabled("page_scrubber_fdict_show_highlight") then
        table.insert(base_buttons, { svg = "highlighter.svg", text = "Highlight", action = "highlight" })
    end
    if is_btn_enabled("page_scrubber_fdict_show_search") then
        table.insert(base_buttons, { svg = "search.svg", text = "Search", action = "search" })
    end
    
    for _, btn in ipairs(base_buttons) do
        local path = getValidSvgPath(btn.svg)
        if not path and btn.action == "ai" then
            path = getValidSvgPath("ai.svg") or getValidSvgPath("bot.svg")
        end

        if path then
            table.insert(icon_btn_specs, { icon_svg = path, text = nil, action = btn.action })
        else
            table.insert(icon_btn_specs, { icon_svg = nil, text = btn.text, font_size = scaleText(12), action = btn.action })
        end
    end
    
    self.word = self.text
    self.clean_text = cleanWordForLookup(self.text) or self.text
    self.clean_word = self.clean_text
    self.highlight = self.highlight_obj
    self.selected_text = (self.highlight_obj and self.highlight_obj.selected_text) or { text = self.text }

    if is_btn_enabled("page_scrubber_fdict_show_plugins") then
        if self.plugin and type(self.plugin.discoverExternalButtons) == "function" then
            local plugin_rows = self.plugin:discoverExternalButtons(self.plugin.patched_dictionary, self.text, entry, self.current_result_idx, self.results, self.boxes, nil, self)
            for _, row in ipairs(plugin_rows) do
                local current_text_row = {}
                for _, ext in ipairs(row) do
                    local assigned_svg = nil
                    local id_lower = (ext.id or ""):lower()
                    local txt_lower = (ext.text or ""):lower()
                    
                    if id_lower:find("xray") or id_lower:find("x%-ray") or txt_lower:find("xray") or txt_lower:find("x%-ray") then
                        assigned_svg = getValidSvgPath("xray.svg")
                    end

                    if assigned_svg then
                        table.insert(icon_btn_specs, {
                            id = ext.id,
                            icon_svg = assigned_svg,
                            text = nil,
                            external_callback = ext.callback,
                            fake_popup = ext.fake_popup
                        })
                    else
                        table.insert(current_text_row, {
                            id = ext.id,
                            icon_svg = nil,
                            text = ext.text or "Plug-in",
                            font_size = scaleText(12),
                            external_callback = ext.callback,
                            fake_popup = ext.fake_popup
                        })
                    end
                end
                
                if #current_text_row > 0 then
                    table.insert(external_rows, current_text_row)
                end
            end
        end
    end

    local raw_fs = getBookRawFontSize(ui_instance) or 26
    local font_ratio = math.max(0.85, math.min(1.40, raw_fs / 26))
    local dynamic_icon_sz = scale(36)
    local icon_btn_h = scale(56)

    local icon_widgets = {}
    if #icon_btn_specs > 0 then
        local icon_btn_w = math.floor((self.width - (#icon_btn_specs - 1) * scale(1)) / #icon_btn_specs)
        for _, spec in ipairs(icon_btn_specs) do
            local btn = PreviewButton:new({
                icon_svg = spec.icon_svg,
                icon_size = dynamic_icon_sz,
                text = spec.text,
                font_size = spec.font_size,
                face = not spec.icon_svg and getBookFace(ui_instance, spec.font_size or scaleText(12), true) or nil,
                width = icon_btn_w, 
                height = icon_btn_h, 
                always_show_text = false,
                show_parent = self,
                callback = function()
                    if spec.external_callback then
                        UIManager:close(self)
                        pcall(spec.external_callback)
                    else
                        self:invokeNative(spec.action)
                    end
                end
            })
            
            if spec.fake_popup and spec.id then
                spec.fake_popup._real_buttons = spec.fake_popup._real_buttons or {}
                spec.fake_popup._real_buttons[spec.id] = btn
            end
            
            table.insert(icon_widgets, btn)
        end
    end

    local text_row_widgets = {}
    if #external_rows > 0 then
        -- Agrupa plugins de a 2 por fila (2 columnas) en ambas orientaciones
        local flat = {}
        for _, r in ipairs(external_rows) do
            for _, spec in ipairs(r) do
                table.insert(flat, spec)
            end
        end
        local rows_to_render = {}
        for i = 1, #flat, 2 do
            local pair = { flat[i] }
            if flat[i + 1] then
                table.insert(pair, flat[i + 1])
            end
            table.insert(rows_to_render, pair)
        end

        for _, txt_row in ipairs(rows_to_render) do
            local row_widgets = {}
            local count = #txt_row
            local pad_x = scale(24)
            local gap_x = (count > 1) and scale(6) or 0
            local avail_w = content_w - (pad_x * 2) - ((count - 1) * gap_x)
            local btn_w = math.floor(avail_w / count)
            local max_text_w = btn_w - scale(8)

            local base_target_fs = scaleText(14)
            if count == 2 then
                base_target_fs = scaleText(13)
            elseif count == 3 then
                base_target_fs = scaleText(12)
            elseif count >= 4 then
                base_target_fs = scaleText(11)
            end
            local min_allowed_fs = scaleText(10)

            if pad_x > 0 then
                table.insert(row_widgets, HorizontalSpan:new({ width = pad_x }))
            end

            for i, spec in ipairs(txt_row) do
                local btn_text = spec.text or "Plug-in"
                local chosen_fs = min_allowed_fs

                -- Comportamiento nativo de KOReader: reducción dinámica celda por celda
                for test_fs = base_target_fs, min_allowed_fs, -1 do
                    local test_face = getBookFace(ui_instance, test_fs, false)
                    local tw = TextWidget:new({ text = btn_text, face = test_face })
                    local needed_w = tw:getSize().w
                    tw:free()
                    if needed_w <= max_text_w then
                        chosen_fs = test_fs
                        break
                    end
                end

                local plugin_face = getBookFace(ui_instance, chosen_fs, false)

                local btn = PreviewButton:new({
                    icon_svg = nil,
                    text = btn_text,
                    face = plugin_face,
                    font_size = chosen_fs,
                    width = btn_w, 
                    height = scale(34), 
                    always_show_text = true,
                    show_parent = self,
                    callback = function()
                        local id_lower = (spec.id or ""):lower()
                        local text_lower = (spec.text or ""):lower()
                        local is_vocab = id_lower:find("vocab") or text_lower:find("vocab")

                        if is_vocab then
                            -- Toggle en vivo: agrega/elimina la palabra y actualiza el texto sin cerrar el popup
                            pcall(spec.external_callback)
                        else
                            -- Plugins de reproducción/acción (TTS, audiolibros, etc.): ejecutan y cierran el panel
                            UIManager:close(self)
                            pcall(spec.external_callback)
                        end
                    end
                })

                if spec.fake_popup then
                    spec.fake_popup._real_buttons = spec.fake_popup._real_buttons or {}
                    if spec.id then
                        spec.fake_popup._real_buttons[spec.id] = btn
                    end
                    local t_lower = (spec.text or ""):lower()
                    if t_lower:find("vocab") then
                        spec.fake_popup._real_buttons["vocab_toggle"] = btn
                        spec.fake_popup._real_buttons["vocabulary_builder"] = btn
                        spec.fake_popup._real_buttons["vocab"] = btn
                    end
                end

                table.insert(row_widgets, btn)
                if i < count and gap_x > 0 then
                    table.insert(row_widgets, HorizontalSpan:new({ width = gap_x }))
                end
            end

            if pad_x > 0 then
                table.insert(row_widgets, HorizontalSpan:new({ width = pad_x }))
            end

            table.insert(text_row_widgets, HorizontalGroup:new(row_widgets))
        end
    end
    
    local content_w = self.is_landscape and (self.width - scale(3)) or self.width
    local top_pad = self.is_landscape and scale(20) or (self.anchor_top and scale(32) or scale(20))
    local bot_pad = self.is_landscape and scale(14) or (self.anchor_top and scale(20) or scale(8))

    -- Cabecera fija: palabra en 1 sola línea con elipsis + botón de búsqueda manual
    local title_avail_w = content_w - scale(48)
    local edit_btn_sz = scale(28)
    local title_gap = scale(8)
    local max_word_w = title_avail_w - edit_btn_sz - title_gap

    local base_fs = getBookRawFontSize(ui_instance) or 26
    local word_fs = scale(base_fs + 4) -- Un poco más grande que el texto del libro
    local word_face = getBookFace(ui_instance, word_fs, true)
    local raw_display_word = tostring(entry.word or self.text or ""):gsub("\n", " ")

    self.word_widget = TextWidget:new({
        text = raw_display_word,
        face = word_face,
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = max_word_w,
        truncate_with_ellipsis = true,
    })

    local actual_word_w = self.word_widget:getSize().w
    local spacer_w = math.max(title_gap, title_avail_w - actual_word_w - edit_btn_sz)

    local more_svg = getValidSvgPath("more.svg")

    local edit_btn = PreviewButton:new({
        icon_svg = more_svg,
        icon_char = not more_svg and "..." or nil,
        icon_size = scale(22),
        font_size = scaleText(14),
        width = edit_btn_sz,
        height = edit_btn_sz,
        show_parent = self,
        callback = function()
            local clean_w = (type(cleanWordForLookup) == "function" and cleanWordForLookup(self.text)) or self.text
            local ui = self.plugin and self.plugin.ui
            local dict = (ui and ui.dictionary) or (self.plugin and self.plugin.patched_dictionary)

            UIManager:close(self)

            UIManager:scheduleIn(0.05, function()
                if dict and type(dict.onShowDictionaryLookup) == "function" then
                    dict:onShowDictionaryLookup(clean_w)
                elseif ui and type(ui.handleEvent) == "function" then
                    ui:handleEvent(Event:new("ShowDictionaryLookup", clean_w))
                end
            end)
        end
    })

    self.title_row = HorizontalGroup:new({
        align = "center",
        HorizontalSpan:new({ width = scale(24) }),
        self.word_widget,
        HorizontalSpan:new({ width = spacer_w }),
        edit_btn,
        HorizontalSpan:new({ width = scale(24) })
    })

    local title_row_h = math.max(self.word_widget:getSize().h, edit_btn_sz)
    local title_bot_pad = scale(6)

    -- Descuenta con precisión matemática todas las filas de cabecera, plugins e iconos existentes
    local fixed_h = top_pad + title_row_h + title_bot_pad + scale(12) + bot_pad
    local num_text_rows = #text_row_widgets
    if num_text_rows > 0 then
        local sep_h = scale(4) + math.max(1, scale(1)) + scale(4)
        local num_seps = (#icon_widgets > 0) and num_text_rows or (num_text_rows - 1)
        fixed_h = fixed_h + (num_text_rows * scale(34)) + (math.max(0, num_seps) * sep_h)
    end
    if #icon_widgets > 0 then
        fixed_h = fixed_h + scale(56)
    end

    -- Margen de resguardo inferior y piso protegido de lectura (40% de la pantalla)
    local safety_pad = self.is_landscape and scale(20) or 0
    local min_reading_h = math.floor(screen_height * 0.40)
    local avail_h = screen_height - fixed_h - safety_pad
    self.max_html_height = self.is_landscape and math.max(min_reading_h, avail_h) or math.floor(screen_height * 0.35)

    self.htmlwidget = ScrollHtmlWidget:new({
        html_body = html_body, is_xhtml = true, css = getBaseCss(ui_instance),
        default_font_size = getDictFontSize(ui_instance), width = content_w - scale(48), height = self.max_html_height,
        scroll_bar_width = scale(6), dialog = self.dialog, highlight_text_selection = true,
    })
    applyRoundedScrollbar(self.htmlwidget)

    self.html_row = HorizontalGroup:new({
        HorizontalSpan:new({ width = scale(24) }),
        self.htmlwidget,
        HorizontalSpan:new({ width = scale(24) })
    })

    local rows = {
        VerticalSpan:new({ width = top_pad }),
        self.title_row,
        VerticalSpan:new({ width = title_bot_pad }),
        self.html_row,
        VerticalSpan:new({ width = scale(12) })
    }

    local function createDictSeparator()
        local line_w = content_w - scale(48)
        return HorizontalGroup:new({
            HorizontalSpan:new({ width = scale(24) }),
            LineWidget:new({
                background = Blitbuffer.COLOR_GRAY,
                width = line_w,
                height = math.max(1, scale(1)),
                dimen = Geom:new({ w = line_w, h = math.max(1, scale(1)) }),
            }),
            HorizontalSpan:new({ width = scale(24) }),
        })
    end

    if #text_row_widgets > 0 then
        for i, row_widget in ipairs(text_row_widgets) do
            table.insert(rows, row_widget)
            if i < #text_row_widgets then
                table.insert(rows, VerticalSpan:new({ width = scale(4) }))
                table.insert(rows, createDictSeparator())
                table.insert(rows, VerticalSpan:new({ width = scale(4) }))
            elseif #icon_widgets > 0 then
                table.insert(rows, VerticalSpan:new({ width = scale(4) }))
                table.insert(rows, createDictSeparator())
                table.insert(rows, VerticalSpan:new({ width = scale(4) }))
            end
        end
    end

    if #icon_widgets > 0 then
        table.insert(rows, HorizontalGroup:new(icon_widgets))
    end
    
    table.insert(rows, VerticalSpan:new({ width = bot_pad }))
    local popup_content = VerticalGroup:new(rows)

    self.container = FloatingCard:new({
        anchor_top = self.anchor_top,
        anchor_left = self.anchor_left,
        is_landscape = self.is_landscape,
        content = popup_content,
        bordersize = scale(3),
        radius = scale(24)
    })

    local container_w = self.container:getSize().w
    local container_h = self.container:getSize().h

    if self.is_landscape then
        local target_x = self.anchor_left and 0 or (screen_width - container_w)
        self.popup_rect = Geom:new({ x = target_x, y = 0, w = container_w, h = screen_height })

        self[1] = VerticalGroup:new({
            align = "left",
            HorizontalGroup:new({
                HorizontalSpan:new({ width = target_x }),
                self.container
            })
        })
    else
        local target_y = self.anchor_top and 0 or (screen_height - container_h)
        self.popup_rect = Geom:new({ x = 0, y = target_y, w = self.width, h = container_h })

        self[1] = VerticalGroup:new({
            VerticalSpan:new({ width = math.max(0, math.floor(target_y)) }),
            self.container
        })
    end
    
    self.dimen = Geom:new({ x = 0, y = 0, w = screen_width, h = screen_height })
    
    if Device:isTouchDevice() then 
        self.ges_events = { 
            TapClose = { GestureRange:new({ ges = "tap", range = self.dimen }) },
            Swipe    = { GestureRange:new({ ges = "swipe", range = self.dimen }) },
            HoldStartText = {
                GestureRange:new{
                    ges = "hold",
                    range = self.dimen,
                },
            },
            HoldPanText = {
                GestureRange:new{
                    ges = "hold_pan",
                    range = self.dimen,
                },
            },
            HoldReleaseText = {
                GestureRange:new{
                    ges = "hold_release",
                    range = self.dimen,
                },
                args = function(text)
                    if text and text ~= "" then
                        self:lookupWordDirect(text)
                    end
                end,
            },
        } 
    end
end

function FloatingDictionaryPopup:onClose() UIManager:close(self) end
function FloatingDictionaryPopup:close() UIManager:close(self) end
function FloatingDictionaryPopup:closeWidget() UIManager:close(self) end

function FloatingDictionaryPopup:onHoldStartText() return true end
function FloatingDictionaryPopup:onHoldPanText() return true end
function FloatingDictionaryPopup:onHoldReleaseText() return true end

function FloatingDictionaryPopup:lookupWordDirect(word)
    local clean = cleanWordForLookup(word)
    if not clean or #clean == 0 then return false end

    -- Preservar la posición actual (arriba/abajo o lateral) y las cajas de la palabra original
    if self.plugin then
        self.plugin._inherited_anchor_top = self.anchor_top
        self.plugin._inherited_anchor_left = self.anchor_left
    end
    local original_boxes = self.boxes

    local UIManager = require("ui/uimanager")
    UIManager:close(self)

    UIManager:scheduleIn(0.05, function()
        if self.plugin and self.plugin.ui then
            local Event = require("ui/event")
            self.plugin.ui:handleEvent(Event:new("LookupWord", clean, true, original_boxes))
        end
    end)
    return true
end

function FloatingDictionaryPopup:onSwipe(arg1, arg2)
    local ges = arg2 or arg1
    if not self.results or #self.results <= 1 then return false end
    
    if ges.direction == "west" then
        if self.current_result_idx < #self.results then
            self:switchDict(self.current_result_idx + 1)
            return true
        end
    elseif ges.direction == "east" then
        if self.current_result_idx > 1 then
            self:switchDict(self.current_result_idx - 1)
            return true
        end
    end
    return false
end

function FloatingDictionaryPopup:switchDict(new_idx)
    self.current_result_idx = new_idx
    local total_dicts = #self.results
    local entry = self.results[new_idx] or {}
    
    local dict_name = tostring(entry.dict or "Diccionario")
    local def_body = tostring(entry.definition or "<p>Sin definición.</p>")
    if not def_body:find("<") then def_body = "<p>" .. htmlEscape(def_body):gsub("\n", "<br/>") .. "</p>" end
    
    local dict_indicator = string.format("<b>[%d/%d]</b> &nbsp;&bull;&nbsp; ", new_idx, total_dicts)

    local html_body = string.format([[
        <div class="floatingdictionary-meta">%s%s</div>
        <div class="search-content">%s</div>
    ]], dict_indicator, htmlEscape(dict_name), def_body)

    if self.word_widget and self.word_widget.setText then
        local raw_display_word = tostring(entry.word or self.text or ""):gsub("\n", " ")
        self.word_widget:setText(raw_display_word)
    end

    if self.htmlwidget.free then pcall(function() self.htmlwidget:free() end) end

    local ui_instance = self.plugin and self.plugin.ui
    local content_w = self.is_landscape and (self.width - scale(3)) or self.width
    self.htmlwidget = ScrollHtmlWidget:new({
        html_body = html_body, is_xhtml = true, css = getBaseCss(ui_instance),
        default_font_size = getDictFontSize(ui_instance), width = content_w - scale(48), height = self.max_html_height,
        scroll_bar_width = scale(6), dialog = self.dialog, highlight_text_selection = true,
    })
    
    applyRoundedScrollbar(self.htmlwidget)
    self.html_row[2] = self.htmlwidget

    UIManager:setDirty(self.dialog, "ui", self.popup_rect)
end

-- ==========================================
-- TARJETA: MÚLTIPLES PALABRAS (UNA SOLA COLUMNA EN EL SUR-ESTE)
-- ==========================================
local FloatingActionMenu = InputContainer:extend({
    text = nil, boxes = nil, anchor_top = false, highlight_obj = nil, plugin = nil, pos0 = nil, pos1 = nil, annotation_index = nil,
    show_more = false,
    more_card = nil,
    more_container = nil,
    more_popup_rect = nil,
})

function FloatingActionMenu:init()
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()

    local raw_buttons = {}

    -- 1. X-Ray (si está presente)
    if self.plugin and type(self.plugin.discoverExternalButtons) == "function" then
        local plugin_rows = self.plugin:discoverExternalButtons(self.plugin.patched_dictionary, self.text, nil, 1, nil, self.boxes, nil)
        for _, row in ipairs(plugin_rows) do
            for _, ext in ipairs(row) do
                local id_lower = (ext.id or ""):lower()
                local txt_lower = (ext.text or ""):lower()
                if id_lower:find("xray") or id_lower:find("x%-ray") or txt_lower:find("xray") or txt_lower:find("x%-ray") then
                    local assigned_svg = getValidSvgPath("xray.svg")
                    table.insert(raw_buttons, {
                        id = ext.id,
                        svg = "xray.svg",
                        text = assigned_svg and nil or "X-Ray",
                        external_callback = ext.callback,
                        fake_popup = ext.fake_popup,
                    })
                    break
                end
            end
        end
    end

    -- 2. Herramientas principales de lectura (Ajustar selección, Buscar y Traducir están en el '+')
    if is_btn_enabled("page_scrubber_sel_show_ai") then
        table.insert(raw_buttons, { svg = "sparkles.svg", text = "AI", action = "ai" })
    end
    if is_btn_enabled("page_scrubber_sel_show_note") then
        table.insert(raw_buttons, { svg = "notepad-text.svg", text = "Note", action = "note" })
    end
    if is_btn_enabled("page_scrubber_sel_show_strikethrough") then
        table.insert(raw_buttons, { svg = "strikethrough.svg", text = "Str", action = "strikethrough" })
    end
    if is_btn_enabled("page_scrubber_sel_show_underline") then
        table.insert(raw_buttons, { svg = "underline.svg", text = "Und", action = "underline" })
    end
    if is_btn_enabled("page_scrubber_sel_show_invert") then
        table.insert(raw_buttons, { svg = "contrast.svg", text = "Inv", action = "invert" })
    end
    if is_btn_enabled("page_scrubber_sel_show_highlight") then
        table.insert(raw_buttons, { svg = "droplet.svg", text = "HL", action = "highlight" })
    end

    -- 3. Botón de más herramientas (more.svg)
    local more_svg = getValidSvgPath("more.svg") or getValidSvgPath("square-plus.svg") or getValidSvgPath("plus.svg")
    table.insert(raw_buttons, {
        svg = "more.svg",
        text = not more_svg and "+" or nil,
        action = "more",
        is_plus = true,
    })

    -- Inversión del orden si está activado
    if G_reader_settings and G_reader_settings:isTrue("page_scrubber_sel_reverse_order") then
        local reversed = {}
        for i = #raw_buttons, 1, -1 do
            table.insert(reversed, raw_buttons[i])
        end
        raw_buttons = reversed
    end

    local pos_pref = (G_reader_settings and G_reader_settings:readSetting("page_scrubber_sel_menu_position")) or "right_v"
    local is_horizontal = (pos_pref == "bottom_h" or pos_pref == "center_h")
    self._pos_pref = pos_pref
    self._is_horizontal = is_horizontal

    local margin_side = scale(24)
    local margin_bottom = scale(54)

    local ui_instance = self.plugin and self.plugin.ui
    local raw_fs = getBookRawFontSize(ui_instance) or 26
    local font_ratio = math.max(0.85, math.min(1.40, raw_fs / 26))

    -- Íconos y botones fijos al DPI táctil; el texto preserva el ratio del libro
    local dynamic_icon_sz = scale(36)
    local btn_w = is_horizontal and scale(56) or scale(62)
    local btn_h = is_horizontal and scale(56) or scale(54)
    local text_fs = math.floor(scaleText(12) * font_ratio + 0.5)
    self._btn_w = btn_w
    self._btn_h = btn_h
    self._font_ratio = font_ratio

    local icon_widgets = {}
    self._plus_btn_index = nil

    for idx, spec in ipairs(raw_buttons) do
        local path = getValidSvgPath(spec.svg)
        if not path and spec.action == "ai" then
            path = getValidSvgPath("ai.svg") or getValidSvgPath("bot.svg")
        end

        local cb
        if spec.is_plus then
            self._plus_btn_index = idx
            cb = function() self:toggleMore() end
        elseif spec.external_callback then
            cb = function() pcall(spec.external_callback) end
        else
            cb = function() self:invokeNative(spec.action) end
        end

        local btn = PreviewButton:new({
            icon_svg = path,
            icon_size = dynamic_icon_sz,
            text = not path and spec.text or nil,
            font_size = text_fs,
            face = not path and getBookFace(ui_instance, text_fs, true) or nil,
            width = btn_w,
            height = btn_h,
            always_show_text = false,
            show_parent = self,
            callback = cb,
        })

        if spec.fake_popup and spec.id then
            spec.fake_popup._real_buttons = spec.fake_popup._real_buttons or {}
            spec.fake_popup._real_buttons[spec.id] = btn
        end

        table.insert(icon_widgets, btn)
    end

    local card_pad = math.floor(scale(4) * font_ratio + 0.5)
    local card_sep = math.max(1, math.floor(scale(2) * font_ratio + 0.5))
    self._card_pad = card_pad
    self._card_sep = card_sep

    local popup_content

    if is_horizontal then
        local total_single_w = card_pad * 2 + (#icon_widgets * btn_w) + ((#icon_widgets - 1) * card_sep) + scale(6)
        local max_avail_w = screen_width - scale(16)

        if total_single_w > max_avail_w then
            self._num_rows = 2
            local per_row = math.ceil(#icon_widgets / 2)
            self._per_row = per_row

            local row1_items = { HorizontalSpan:new({ width = card_pad }) }
            for i = 1, per_row do
                table.insert(row1_items, icon_widgets[i])
                if i < per_row then
                    table.insert(row1_items, HorizontalSpan:new({ width = card_sep }))
                end
            end
            table.insert(row1_items, HorizontalSpan:new({ width = card_pad }))

            local row2_items = { HorizontalSpan:new({ width = card_pad }) }
            for i = per_row + 1, #icon_widgets do
                table.insert(row2_items, icon_widgets[i])
                if i < #icon_widgets then
                    table.insert(row2_items, HorizontalSpan:new({ width = card_sep }))
                end
            end
            table.insert(row2_items, HorizontalSpan:new({ width = card_pad }))

            popup_content = VerticalGroup:new({
                VerticalSpan:new({ width = card_pad }),
                HorizontalGroup:new(row1_items),
                VerticalSpan:new({ width = card_sep }),
                HorizontalGroup:new(row2_items),
                VerticalSpan:new({ width = card_pad }),
            })
        else
            self._num_rows = 1
            self._per_row = #icon_widgets

            local items = { HorizontalSpan:new({ width = card_pad }) }
            for i, btn_widget in ipairs(icon_widgets) do
                table.insert(items, btn_widget)
                if i < #icon_widgets then
                    table.insert(items, HorizontalSpan:new({ width = card_sep }))
                end
            end
            table.insert(items, HorizontalSpan:new({ width = card_pad }))
            popup_content = HorizontalGroup:new(items)
        end
    else
        local total_single_h = card_pad * 2 + (#icon_widgets * btn_h) + ((#icon_widgets - 1) * card_sep) + scale(6)
        local max_avail_h = screen_height - margin_bottom - scale(20)

        if total_single_h > max_avail_h then
            self._num_cols = 2
            local per_col = math.ceil(#icon_widgets / 2)
            self._per_col = per_col

            local col1_items = { VerticalSpan:new({ width = card_pad }) }
            for i = 1, per_col do
                table.insert(col1_items, icon_widgets[i])
                if i < per_col then
                    table.insert(col1_items, VerticalSpan:new({ width = card_sep }))
                end
            end
            table.insert(col1_items, VerticalSpan:new({ width = card_pad }))

            local col2_items = { VerticalSpan:new({ width = card_pad }) }
            for i = per_col + 1, #icon_widgets do
                table.insert(col2_items, icon_widgets[i])
                if i < #icon_widgets then
                    table.insert(col2_items, VerticalSpan:new({ width = card_sep }))
                end
            end
            table.insert(col2_items, VerticalSpan:new({ width = card_pad }))

            popup_content = HorizontalGroup:new({
                HorizontalSpan:new({ width = card_pad }),
                VerticalGroup:new(col1_items),
                HorizontalSpan:new({ width = card_sep }),
                VerticalGroup:new(col2_items),
                HorizontalSpan:new({ width = card_pad }),
            })
        else
            self._num_cols = 1
            self._per_col = #icon_widgets

            local rows = { VerticalSpan:new({ width = card_pad }) }
            for i, btn_widget in ipairs(icon_widgets) do
                table.insert(rows, btn_widget)
                if i < #icon_widgets then
                    table.insert(rows, VerticalSpan:new({ width = card_sep }))
                end
            end
            table.insert(rows, VerticalSpan:new({ width = card_pad }))
            popup_content = VerticalGroup:new(rows)
        end
    end

    self.card = FloatingPillCard:new({
        content = popup_content, bordersize = scale(2), radius = math.floor(scale(14) * font_ratio + 0.5)
    })

    local card_size = self.card:getSize()
    local card_w = card_size.w
    local card_h = card_size.h

    local target_x, target_y

    if pos_pref == "left_v" then
        target_x = margin_side
        target_y = screen_height - card_h - margin_bottom
    elseif pos_pref == "bottom_h" then
        target_x = math.floor((screen_width - card_w) / 2)
        target_y = screen_height - card_h - margin_bottom
    elseif pos_pref == "center_h" then
        target_x = math.floor((screen_width - card_w) / 2)
        target_y = math.floor((screen_height - card_h) / 2)
    else
        target_x = screen_width - card_w - margin_side
        target_y = screen_height - card_h - margin_bottom
    end

    if target_y < scale(10) then target_y = scale(10) end
    if target_x < scale(10) then target_x = scale(10) end

    self.popup_rect = Geom:new({ x = target_x, y = target_y, w = card_w, h = card_h })

    self[1] = VerticalGroup:new({
        align = "left",
        VerticalSpan:new({ width = math.max(0, math.floor(target_y)) }),
        HorizontalGroup:new({
            HorizontalSpan:new({ width = math.max(0, math.floor(target_x)) }),
            self.card
        })
    })

    self.dimen = Geom:new({ x = 0, y = 0, w = screen_width, h = screen_height })
    if Device:isTouchDevice() then 
        self.ges_events = { TapClose = { GestureRange:new({ ges = "tap", range = self.dimen }) } } 
    end

    self:buildMoreCard()
end

function FloatingActionMenu:buildMoreCard()
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()
    local hl = self.highlight_obj

    local native_buttons = {}
    local unknown_buttons = {}

    if hl and hl._highlight_buttons then
        local ok, ffiUtil = pcall(require, "ffi/util")
        local iterator = (ok and ffiUtil and ffiUtil.orderedPairs) or pairs
        for key, fn in iterator(hl._highlight_buttons) do
            if type(fn) == "function" then
                local ok_b, btn = pcall(fn, hl, self.annotation_index)
                if ok_b and type(btn) == "table" then
                    local show = true
                    if type(btn.show_in_highlight_dialog_func) == "function" then
                        local ok_s, res_s = pcall(btn.show_in_highlight_dialog_func)
                        show = ok_s and res_s
                    end
                    if show then
                        local k_clean = tostring(key):gsub("^%d+_", ""):lower()
                        local id_clean = tostring(btn.id or ""):lower()
                        local txt_clean = tostring(btn.text or ""):lower()

                        btn.id = btn.id or key

                        -- Captura estricta de callbacks del sistema para la fila 1
                        local is_native_select = (k_clean == "select" or k_clean == "start_selection" or id_clean == "select" or txt_clean == "select" or txt_clean == "seleccionar")
                        local is_native_copy = (k_clean == "copy" or id_clean == "copy" or txt_clean == "copy" or txt_clean == "copiar")
                        local is_native_dict = (k_clean == "dict" or k_clean == "dictionary" or id_clean == "dict" or id_clean == "dictionary" or txt_clean == "dictionary" or txt_clean == "diccionario")
                        local is_native_wiki = (k_clean == "wiki" or k_clean == "wikipedia" or id_clean == "wiki" or id_clean == "wikipedia" or txt_clean == "wikipedia" or txt_clean == "wiki")
                        local is_native_search = (k_clean == "search" or id_clean == "search" or txt_clean == "search" or txt_clean == "buscar")
                        local is_native_trans = (k_clean == "translate" or id_clean == "translate" or txt_clean == "translate" or txt_clean == "traducir")

                        if is_native_select then
                            native_buttons["select"] = btn
                        elseif is_native_copy then
                            native_buttons["copy"] = btn
                        elseif is_native_dict then
                            native_buttons["dict"] = btn
                        elseif is_native_wiki then
                            native_buttons["wiki"] = btn
                        elseif is_native_search then
                            native_buttons["search"] = btn
                        elseif is_native_trans then
                            native_buttons["translate"] = btn
                        end

                        -- Bloqueo de duplicados y funciones sin soporte en Kindle
                        local is_share = id_clean:find("share") or k_clean:find("share") or txt_clean:find("share") or txt_clean:find("compart")
                        local is_html = id_clean:find("html") or k_clean:find("html") or txt_clean:find("html")
                        local is_xray = id_clean:find("xray") or id_clean:find("x%-ray") or k_clean:find("xray") or k_clean:find("x%-ray") or txt_clean:find("xray") or txt_clean:find("x%-ray")
                        local is_native_assistant = (
                            k_clean == "assistant" or id_clean == "assistant" or 
                            k_clean == "ai" or id_clean == "ai" or
                            txt_clean:find("assistant") or txt_clean:find("asistente") or
                            txt_clean:find("ai assistant") or txt_clean:find("ia assistant")
                        )

                        -- Filtro estricto: descarta herramientas resueltas, duplicadas o bloqueadas
                        local is_known = (
                            is_native_select or is_native_copy or is_native_dict
                            or is_native_wiki or is_native_search or is_native_trans
                            or is_share or is_html or is_xray or is_native_assistant
                            or k_clean == "highlight" or id_clean == "highlight" or txt_clean == "highlight" or txt_clean == "resaltar"
                            or k_clean == "note" or k_clean == "add_note" or id_clean == "note" or txt_clean == "note" or txt_clean == "nota"
                            or id_clean == "strike" or id_clean == "strikethrough" or id_clean == "underline" or id_clean == "invert"
                        )

                        if not is_known and btn.enabled ~= false then
                            table.insert(unknown_buttons, btn)
                        end
                    end
                end
            end
        end
    end

    local ui_instance = self.plugin and self.plugin.ui
    local raw_fs = getBookRawFontSize(ui_instance) or 26
    local font_ratio = self._font_ratio or math.max(0.85, math.min(1.40, raw_fs / 26))

    local row1_specs = {
        { svg = "crop.svg", text = "Sel", action = "select" },
        { svg = "copy.svg", text = "Copy", action = "copy" },
        { svg = "book-marked.svg", fallback_svg = "book-open.svg", text = "Dict", action = "dict" },
        { svg = "globe.svg", text = "Wiki", action = "wiki" },
        { svg = "search.svg", text = "Search", action = "search" },
        { svg = "languages.svg", text = "Trans", action = "translate" },
    }

    local row1_icon_sz = scale(31)
    local min_btn_w = scale(52)
    local row1_btn_h = scale(52)
    local row1_text_fs = math.floor(scaleText(11) * font_ratio + 0.5)

    -- Ancho base mínimo requerido por los 6 iconos superiores
    local min_more_w = (min_btn_w * #row1_specs) + ((#row1_specs - 1) * scale(2)) + scale(12)
    local max_needed_w = min_more_w

    -- Extraer textos y calcular dinámicamente el ancho necesario para no recortar
    local button_texts = {}
    if #unknown_buttons > 0 then
        for idx, u_btn in ipairs(unknown_buttons) do
            local u_text = u_btn.text
            if type(u_btn.text_func) == "function" then
                local ok_t, res_t = pcall(u_btn.text_func, hl)
                if ok_t and res_t then u_text = res_t end
            end
            u_text = tostring(u_text or u_btn.id or "?")
            button_texts[idx] = u_text

            local test_face = getBookFace(ui_instance, scaleText(11), false)
            local tw = TextWidget:new({ text = u_text, face = test_face })
            local needed = tw:getSize().w + scale(32)
            tw:free()
            if needed > max_needed_w then
                max_needed_w = needed
            end
        end
    end

    -- Salvaguarda de pantalla según la orientación activa
    local max_allowed_w = screen_width - scale(24)
    if not self._is_horizontal and self.popup_rect then
        max_allowed_w = math.min(max_allowed_w, screen_width - self.popup_rect.w - scale(28))
    end
    max_allowed_w = math.min(max_allowed_w, scale(350))

    local more_w = math.max(min_more_w, math.min(max_needed_w, max_allowed_w))
    local u_btn_w = more_w - scale(12)
    local line_w = more_w - scale(12)

    -- Reparto simétrico de los 6 iconos superiores al ancho final expandido
    local row1_btn_w = math.floor((more_w - scale(12) - ((#row1_specs - 1) * scale(2))) / #row1_specs)

    local row1_widgets = {}
    for _, spec in ipairs(row1_specs) do
        local path = getValidSvgPath(spec.svg) or (spec.fallback_svg and getValidSvgPath(spec.fallback_svg))
        table.insert(row1_widgets, PreviewButton:new({
            icon_svg = path,
            icon_size = row1_icon_sz,
            text = not path and spec.text or nil,
            font_size = row1_text_fs,
            face = not path and getBookFace(ui_instance, row1_text_fs, true) or nil,
            width = row1_btn_w,
            height = row1_btn_h,
            always_show_text = false,
            show_parent = self,
            callback = function()
                local act = spec.action
                if act == "select" then
                    self:invokeNative("adjust")
                elseif native_buttons[act] and type(native_buttons[act].callback) == "function" then
                    UIManager:close(self)
                    pcall(native_buttons[act].callback, hl, self.annotation_index)
                else
                    self:invokeNative(act)
                end
            end,
        }))
    end

    local row1_items = { HorizontalSpan:new({ width = scale(6) }) }
    for i, w in ipairs(row1_widgets) do
        table.insert(row1_items, w)
        if i < #row1_widgets then
            table.insert(row1_items, HorizontalSpan:new({ width = scale(2) }))
        end
    end
    table.insert(row1_items, HorizontalSpan:new({ width = scale(6) }))
    local row1_group = HorizontalGroup:new(row1_items)

    local card_vertical_items = {
        VerticalSpan:new({ width = scale(6) }),
        row1_group,
    }

    local function createSeparator()
        return HorizontalGroup:new({
            HorizontalSpan:new({ width = scale(6) }),
            LineWidget:new({
                background = Blitbuffer.COLOR_GRAY,
                width = line_w,
                height = math.max(1, scale(1)),
                dimen = Geom:new({ w = line_w, h = math.max(1, scale(1)) }),
            }),
            HorizontalSpan:new({ width = scale(6) }),
        })
    end

    -- Filas siguientes: reducción tipográfica dinámica para que no aparezcan puntos suspensivos
    if #unknown_buttons > 0 then
        local max_text_avail_w = u_btn_w - scale(12)
        local target_fs = scaleText(14)
        local min_fs = scaleText(10)

        for idx, u_btn in ipairs(unknown_buttons) do
            table.insert(card_vertical_items, VerticalSpan:new({ width = scale(4) }))
            table.insert(card_vertical_items, createSeparator())
            table.insert(card_vertical_items, VerticalSpan:new({ width = scale(4) }))

            local u_text = button_texts[idx] or "?"
            local chosen_fs = min_fs

            for test_fs = target_fs, min_fs, -1 do
                local test_face = getBookFace(ui_instance, test_fs, false)
                local tw = TextWidget:new({ text = u_text, face = test_face })
                local tw_w = tw:getSize().w
                tw:free()
                if tw_w <= max_text_avail_w then
                    chosen_fs = test_fs
                    break
                end
            end

            local plugin_face = getBookFace(ui_instance, chosen_fs, false)
            local u_btn_h = math.max(scale(30), math.floor(chosen_fs * 1.8 + 0.5))

            local btn_widget = PreviewButton:new({
                icon_svg = nil,
                text = u_text,
                face = plugin_face,
                font_size = chosen_fs,
                width = u_btn_w,
                height = u_btn_h,
                always_show_text = true,
                show_parent = self,
                callback = function()
                    UIManager:close(self)
                    if type(u_btn.callback) == "function" then
                        pcall(u_btn.callback, hl, self.annotation_index)
                    end
                end,
            })

            table.insert(card_vertical_items, HorizontalGroup:new({
                HorizontalSpan:new({ width = scale(6) }),
                btn_widget,
                HorizontalSpan:new({ width = scale(6) }),
            }))
        end
    end

    table.insert(card_vertical_items, VerticalSpan:new({ width = scale(6) }))
    local more_content = VerticalGroup:new(card_vertical_items)

    self.more_card = FloatingPillCard:new({
        content = more_content, bordersize = scale(2), radius = math.floor(scale(14) * font_ratio + 0.5)
    })
end

function FloatingActionMenu:updateMoreLayout()
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()
    local more_size = self.more_card:getSize()
    local more_w = more_size.w
    local more_h = more_size.h

    -- Calcular la posición absoluta en pantalla del botón '+'
    local btn_idx = self._plus_btn_index or 1
    local b = scale(3)
    local btn_plus_x, btn_plus_y
    local btn_w, btn_h = self._btn_w, self._btn_h
    local card_pad = self._card_pad or scale(6)
    local card_sep = self._card_sep or scale(2)

    if self._is_horizontal then
        if self._num_rows == 2 then
            local per_row = self._per_row or math.ceil(btn_idx / 2)
            local row_idx = (btn_idx <= per_row) and 0 or 1
            local col_idx = (btn_idx <= per_row) and (btn_idx - 1) or (btn_idx - per_row - 1)
            local rel_x = b + card_pad + (col_idx * (btn_w + card_sep))
            local rel_y = b + card_pad + (row_idx * (btn_h + card_sep))
            btn_plus_x = self.popup_rect.x + rel_x
            btn_plus_y = self.popup_rect.y + rel_y
        else
            local rel_x = b + card_pad + ((btn_idx - 1) * (btn_w + card_sep))
            btn_plus_x = self.popup_rect.x + rel_x
            btn_plus_y = self.popup_rect.y + b + card_pad
        end
    else
        if self._num_cols == 2 then
            local per_col = self._per_col or math.ceil(btn_idx / 2)
            local col_idx = (btn_idx <= per_col) and 0 or 1
            local row_idx = (btn_idx <= per_col) and (btn_idx - 1) or (btn_idx - per_col - 1)
            local rel_x = b + card_pad + (col_idx * (btn_w + card_sep))
            local rel_y = b + card_pad + (row_idx * (btn_h + card_sep))
            btn_plus_x = self.popup_rect.x + rel_x
            btn_plus_y = self.popup_rect.y + rel_y
        else
            local rel_y = b + card_pad + ((btn_idx - 1) * (btn_h + card_sep))
            btn_plus_x = self.popup_rect.x + b + card_pad
            btn_plus_y = self.popup_rect.y + rel_y
        end
    end

    local gap = scale(6)
    local margin = scale(8)
    local target_more_x, target_more_y

    if self._is_horizontal then
        -- Eje Y: en bottom_h brota arriba; en center_h brota abajo
        if self._pos_pref == "bottom_h" then
            target_more_y = self.popup_rect.y - more_h - gap
        else -- "center_h"
            target_more_y = self.popup_rect.y + self.popup_rect.h + gap
        end

        -- Eje X: centrado en el '+' pero restringido estrictamente al contorno de popup_rect
        target_more_x = math.floor(btn_plus_x + (btn_w / 2) - (more_w / 2))

        if more_w <= self.popup_rect.w then
            local min_x = self.popup_rect.x
            local max_x = self.popup_rect.x + self.popup_rect.w - more_w
            target_more_x = math.max(min_x, math.min(target_more_x, max_x))
        else
            -- Si el menú secundario es más ancho que la barra, alinea al borde donde se ubica el '+'
            if (btn_plus_x + btn_w / 2) >= (self.popup_rect.x + self.popup_rect.w / 2) then
                target_more_x = self.popup_rect.x + self.popup_rect.w - more_w
            else
                target_more_x = self.popup_rect.x
            end
        end
    else
        -- Eje X: brota al lateral correspondiente
        if self._pos_pref == "left_v" then
            target_more_x = self.popup_rect.x + self.popup_rect.w + gap
        else -- "right_v"
            target_more_x = self.popup_rect.x - more_w - gap
        end

        -- Eje Y: centrado en el '+' pero restringido estrictamente al contorno de popup_rect
        target_more_y = math.floor(btn_plus_y + (btn_h / 2) - (more_h / 2))

        if more_h <= self.popup_rect.h then
            local min_y = self.popup_rect.y
            local max_y = self.popup_rect.y + self.popup_rect.h - more_h
            target_more_y = math.max(min_y, math.min(target_more_y, max_y))
        else
            -- Si el menú secundario es más alto que la barra, alinea al borde donde se ubica el '+'
            if (btn_plus_y + btn_h / 2) >= (self.popup_rect.y + self.popup_rect.h / 2) then
                target_more_y = self.popup_rect.y + self.popup_rect.h - more_h
            else
                target_more_y = self.popup_rect.y
            end
        end
    end

    -- Salvaguardas de pantalla para evitar recortes en bordes del dispositivo
    if target_more_x + more_w > screen_width - margin then
        target_more_x = screen_width - more_w - margin
    end
    if target_more_x < margin then target_more_x = margin end
    if target_more_y + more_h > screen_height - margin then
        target_more_y = screen_height - more_h - margin
    end
    if target_more_y < margin then target_more_y = margin end

    self.more_popup_rect = Geom:new({ x = target_more_x, y = target_more_y, w = more_w, h = more_h })

    self.more_container = VerticalGroup:new({
        align = "left",
        VerticalSpan:new({ width = math.max(0, math.floor(target_more_y)) }),
        HorizontalGroup:new({
            HorizontalSpan:new({ width = math.max(0, math.floor(target_more_x)) }),
            self.more_card
        })
    })
end

function FloatingActionMenu:toggleMore()
    if self.show_more then
        local dirty_rect = self.more_popup_rect
        self.show_more = false
        self.more_container = nil

        if dirty_rect then
            -- Redibuja el libro debajo para restaurar la página sin dejar fantasmas en E-ink
            local pad = scale(3)
            local clear_geom = Geom:new({
                x = math.max(0, dirty_rect.x - pad),
                y = math.max(0, dirty_rect.y - pad),
                w = dirty_rect.w + (pad * 2),
                h = dirty_rect.h + (pad * 2),
            })
            if self.plugin and self.plugin.ui then
                UIManager:setDirty(self.plugin.ui, function() return "ui", clear_geom end)
            else
                UIManager:setDirty(nil, function() return "ui", clear_geom end)
            end
        end
        UIManager:setDirty(self, function() return "ui", self.popup_rect end)
    else
        self.show_more = true
        self:updateMoreLayout()
        if self.more_popup_rect then
            UIManager:setDirty(self, function() return "ui", self.more_popup_rect end)
        else
            UIManager:setDirty(self, function() return "ui", self.dimen end)
        end
    end
end

function FloatingActionMenu:paintTo(bb, x, y)
    if self[1] then
        self[1]:paintTo(bb, x, y)
    end
    if self.show_more and self.more_container then
        self.more_container:paintTo(bb, x, y)
    end
end

function FloatingActionMenu:handleEvent(event)
    if self.show_more and self.more_container then
        if self.more_container:handleEvent(event) then
            return true
        end
    end
    return InputContainer.handleEvent(self, event)
end

-- ==========================================
-- LÓGICA COMPARTIDA DE ACCIONES NATIVAS
-- ==========================================
local function saveCustomHighlight(self_obj, style)
    local hl = self_obj.highlight_obj
    if not hl then return end
    
    if type(hl.saveHighlightFormatted) == "function" then
        local saved_color = hl.view and hl.view.highlight and hl.view.highlight.saved_color
        local ok = pcall(function()
            hl:saveHighlightFormatted(true, style, saved_color)
            if hl.clear then hl:clear() end
        end)
        if ok then return end
    end

    local util = require("util")
    local Event = require("ui/event")
    
    local sel = hl.selected_text or {
        pos0 = self_obj.pos0,
        pos1 = self_obj.pos1,
        text = self_obj.text
    }
    if not sel.pos0 or not sel.pos1 then return end
    
    -- FIX 1: Evitar el crash fatal de Lua ("attempt to index a string value").
    -- En EPUBs, pos0 es un texto. Intentar sacarle ".page" rompía todo el plugin.
    local page
    if type(sel.pos0) == "string" then
        page = sel.pos0
    elseif type(sel.pos0) == "table" and sel.pos0.page then
        page = sel.pos0.page
    else
        page = sel.pos0
    end
    
    local saved_color = (hl.view and hl.view.highlight and hl.view.highlight.saved_color) or "yellow"
    
    -- FIX 2: Capturar el capítulo de forma 100% nativa y a prueba de fallos.
    local current_chapter = nil
    pcall(function()
        -- Intento A: Usar la función nativa de KOReader para marcadores
        if hl.ui and type(hl.ui.getBookmarkChapter) == "function" then
            current_chapter = hl.ui:getBookmarkChapter(sel.pos0)
        end
        
        -- Intento B: Si falla, buscar manualmente en el índice usando el número real de página
        if not current_chapter and hl.ui and hl.ui.toc then
            local pageno = 1
            if type(hl.ui.getCurrentPage) == "function" then pageno = hl.ui:getCurrentPage() end
            
            if type(hl.ui.toc.getTocIndexByPage) == "function" then
                local idx = hl.ui.toc:getTocIndexByPage(pageno)
                if idx and hl.ui.toc.toc and type(hl.ui.toc.toc[idx]) == "table" then
                    current_chapter = hl.ui.toc.toc[idx].text or hl.ui.toc.toc[idx].title
                end
            end
        end
    end)
    
    local item = {
        chapter = current_chapter,
        page = page,
        pos0 = sel.pos0,
        pos1 = sel.pos1,
        text = util.cleanupSelectedText(sel.text),
        drawer = style,
        color = saved_color,
    }
    
    if hl.ui and hl.ui.paging then
        item.pboxes = sel.pboxes or self_obj.boxes
        item.ext = sel.ext
        if hl.writePdfAnnotation then pcall(function() hl:writePdfAnnotation("save", item) end) end
    end
    
    local ok, index = pcall(function() return hl.ui.annotation:addItem(item) end)
    if ok and index then
        if hl.view and hl.view.footer and type(hl.view.footer.maybeUpdateFooter) == "function" then
            pcall(function() hl.view.footer:maybeUpdateFooter() end)
        end
        pcall(function() hl.ui:handleEvent(Event:new("AnnotationsModified", { item, nb_highlights_added = 1, index_modified = index })) end)
    end
    if hl.clear then pcall(function() hl:clear() end) end
end

local function invokeAction(self_obj, action_name)
    local hl = self_obj.highlight_obj
    local text = self_obj.text
    local pos0 = self_obj.pos0
    local pos1 = self_obj.pos1
    local boxes = self_obj.boxes

    -- MODO CROP (Ajustar Selección) - La función nativa real
    if action_name == "adjust" then
        if hl and type(hl.startSelection) == "function" then
            hl:startSelection(self_obj.annotation_index)
        end
        local UIManager = require("ui/uimanager")
        UIManager:close(self_obj)
        return
    end

    -- Sincronizamos KOReader para el resto de los botones
    if hl then hl.highlight_menu = nil end
    local UIManager = require("ui/uimanager")
    UIManager:close(self_obj)
    
    UIManager:scheduleIn(0.1, function()
        pcall(function()
            if action_name == "highlight" then
                saveCustomHighlight(self_obj, "lighten")
            elseif action_name == "invert" then
                saveCustomHighlight(self_obj, "invert")
            elseif action_name == "underline" then
                saveCustomHighlight(self_obj, "underscore")
            elseif action_name == "strikethrough" then
                saveCustomHighlight(self_obj, "strikeout")
            elseif action_name == "note" then
                if hl and type(hl.addNote) == "function" then
                    hl:addNote()
                elseif hl and type(hl.onAddNote) == "function" then
                    hl:onAddNote()
                elseif hl and hl.ui and hl.ui.annotation and type(hl.ui.annotation.onAddNote) == "function" then
                    hl.ui.annotation:onAddNote({ pos0 = pos0, pos1 = pos1, text = text, pboxes = boxes })
                end
            elseif action_name == "translate" then
                if hl and hl.translateHighlightedWord then hl:translateHighlightedWord(text) end
                self_obj.plugin.ui:handleEvent(Event:new("LookupTranslation", text))
                self_obj.plugin.ui:handleEvent(Event:new("TranslateText", text))
                self_obj.plugin.ui:handleEvent(Event:new("TranslateWord", text))
            -- El adjust ya se manejó arriba de forma nativa, este bloque queda libre
            elseif action_name == "ai" then
                local assistant = (self_obj.plugin and self_obj.plugin.ui and self_obj.plugin.ui.assistant)
                    or (hl and hl.ui and hl.ui.assistant)
                if assistant and assistant.assistant_dialog then
                    local NetworkMgr = require("ui/network/manager")
                    NetworkMgr:runWhenOnline(function()
                        UIManager:nextTick(function()
                            assistant.assistant_dialog:show(text)
                        end)
                    end)
                else
                    if self_obj.plugin and self_obj.plugin.ui then
                        self_obj.plugin.ui:handleEvent(Event:new("AskAIAssistant", text))
                    end
                end
            elseif action_name == "wiki" then
                if hl and hl.lookupWikipedia then hl:lookupWikipedia()
                elseif hl and hl.wikipediaHighlightedWord then hl:wikipediaHighlightedWord(text)
                else self_obj.plugin.ui:handleEvent(Event:new("LookupWikipedia", text)) end
            elseif action_name == "search" then
                if hl and hl.onHighlightSearch then hl:onHighlightSearch()
                elseif self_obj.plugin.ui.search then self_obj.plugin.ui.search:onShowFulltextSearchInput(text)
                else self_obj.plugin.ui:handleEvent(Event:new("ShowFulltextSearchInput", text)) end
            elseif action_name == "dict" then
                if self_obj.results and self_obj.plugin.original_showDict then
                    self_obj.plugin.opening_original_popup = true
                    self_obj.plugin.original_showDict(self_obj.plugin.patched_dictionary, text, self_obj.results, boxes)
                    self_obj.plugin.opening_original_popup = false
                elseif self_obj.plugin and self_obj.plugin.ui and self_obj.plugin.ui.dictionary then
                    self_obj.plugin.ui.dictionary:onLookupWord(text, false, boxes, hl)
                end
            elseif action_name == "copy" then
                if hl and type(hl.copyToClipboard) == "function" then
                    hl:copyToClipboard(text)
                elseif hl and type(hl.onCopy) == "function" then
                    hl:onCopy()
                else
                    local ok_dev, Dev = pcall(require, "device")
                    if ok_dev and Dev and Dev.setClipboardText then
                        Dev.setClipboardText(text)
                    end
                end
                local ok_notif, Notification = pcall(require, "ui/widget/notification")
                if ok_notif and Notification then
                    local _ = require("gettext")
                    UIManager:show(Notification:new{ text = _("Copied to clipboard") })
                end
                if hl and hl.clear then pcall(function() hl:clear() end) end
            elseif action_name == "share" then
                if hl and type(hl.onShare) == "function" then
                    hl:onShare()
                elseif self_obj.plugin and self_obj.plugin.ui then
                    self_obj.plugin.ui:handleEvent(Event:new("ShareText", text))
                end
            elseif action_name == "html" then
                if hl and type(hl.onViewHtml) == "function" then
                    hl:onViewHtml()
                elseif self_obj.plugin and self_obj.plugin.ui then
                    self_obj.plugin.ui:handleEvent(Event:new("ViewHTML", text))
                    self_obj.plugin.ui:handleEvent(Event:new("ViewSource", text))
                end
            end
        end)
    end)
end

function FloatingDictionaryPopup:invokeNative(a) invokeAction(self, a) end
function FloatingActionMenu:invokeNative(a) invokeAction(self, a) end

local function checkClose(self_obj, ges)
    if ges and ges.pos then
        local in_main = self_obj.popup_rect and ges.pos:intersectWith(self_obj.popup_rect)
        local in_more = self_obj.show_more and self_obj.more_popup_rect and ges.pos:intersectWith(self_obj.more_popup_rect)
        if not in_main and not in_more then
            UIManager:close(self_obj)
            if self_obj.highlight_obj and self_obj.highlight_obj.clear then
                pcall(function() self_obj.highlight_obj:clear() end)
            end
            return true
        end
    end
    return false
end

function FloatingDictionaryPopup:onTapClose(_arg, ges) return checkClose(self, ges) end
function FloatingActionMenu:onTapClose(_arg, ges) return checkClose(self, ges) end
function FloatingDictionaryPopup:onShow() UIManager:setDirty(self.dialog, function() return "ui", self.dimen end) end
function FloatingDictionaryPopup:onCloseWidget() UIManager:setDirty(self.dialog, function() return "ui", self.dimen end) end
function FloatingActionMenu:onShow() UIManager:setDirty(self, function() return "ui", self.dimen end) end
function FloatingActionMenu:onCloseWidget() UIManager:setDirty(self, function() return "ui", self.dimen end) end

-- ==========================================
-- FUNCIONES DE CONFIGURACIÓN Y ACTIVACIÓN
-- ==========================================
function FloatingDict:isEnabled()
    if G_reader_settings then
        local val = G_reader_settings:readSetting(SETTING_DICT_ENABLED)
        if val ~= nil then return val == true end
    end
    return false
end

function FloatingDict:setEnabled(state)
    if G_reader_settings then 
        G_reader_settings:saveSetting(SETTING_DICT_ENABLED, state)
        G_reader_settings:flush() 
    end
end

function FloatingDict:isSelectionMenuEnabled()
    if G_reader_settings then
        local val = G_reader_settings:readSetting(SETTING_SELECTION_ENABLED)
        if val ~= nil then return val == true end
    end
    return false
end

function FloatingDict:setSelectionMenuEnabled(state)
    if G_reader_settings then 
        G_reader_settings:saveSetting(SETTING_SELECTION_ENABLED, state)
        G_reader_settings:flush() 
    end
end

-- ==========================================
-- DISPARADOR PRINCIPAL DE MENÚ FLOTANTE (+2 PALABRAS)
-- ==========================================
local function showCustomActionMenu(hl_self, plugin, index)
    local sel = hl_self and hl_self.selected_text
    if not sel or not sel.text or sel.text == "" then
        return false
    end

    -- Verificamos si hay al menos dos palabras reales (separadas por espacio o puntuación)
    local trimmed_text = sel.text:gsub("^%s*(.-)%s*$", "%1")
    local words_count = 0
    for _ in trimmed_text:gmatch("%S+") do
        words_count = words_count + 1
    end

    if words_count <= 1 then
        -- Es una sola palabra. Si el diccionario flotante está activo, derivar a lookup limpio
        if plugin:isEnabled() and plugin.ui and plugin.ui.dictionary then
            local clean_word = cleanWordForLookup(trimmed_text)
            if clean_word and #clean_word > 0 then
                local boxes = sel.pboxes or hl_self.boxes
                if not boxes and type(hl_self.getHighlightedBoxes) == "function" then
                    boxes = hl_self:getHighlightedBoxes(sel.pos0, sel.pos1)
                end
                plugin.ui.dictionary:onLookupWord(clean_word, false, boxes, hl_self)
                return true
            end
        end
        return false
    end

    local boxes = sel.pboxes or hl_self.boxes
    if not boxes and type(hl_self.getHighlightedBoxes) == "function" then
        boxes = hl_self:getHighlightedBoxes(sel.pos0, sel.pos1)
    end

    local popup = FloatingActionMenu:new({
        text = sel.text,
        boxes = boxes,
        pos0 = sel.pos0,
        pos1 = sel.pos1,
        highlight_obj = hl_self,
        plugin = plugin,
        annotation_index = index -- ACÁ SE LO PASAMOS
    })
    UIManager:show(popup)
    return true
end

-- ==========================================
-- INYECCIÓN EN KOREADER
-- ==========================================
function FloatingDict:init(ui)
    self.ui = ui
    self:patchSystem()
end

function FloatingDict:onReaderReady()
    self:patchSystem()
end

function FloatingDict:patchSystem()
    local dictionary = self.ui and self.ui.dictionary
    local highlight = self.ui and self.ui.highlight
    local plugin = self

    if ReaderHighlight and not ReaderHighlight._ps_fdict_class_patched then
        local orig_class_onShowHighlightMenu = ReaderHighlight.onShowHighlightMenu
        -- Capturamos el index explícitamente en los parámetros
        ReaderHighlight.onShowHighlightMenu = function(hl_self, index, ...)
            if plugin:isSelectionMenuEnabled() and hl_self.selected_text and hl_self.selected_text.text and hl_self.selected_text.text ~= "" then
                local shown = showCustomActionMenu(hl_self, plugin, index)
                if shown then return true end
            end
            if type(orig_class_onShowHighlightMenu) == "function" then
                return orig_class_onShowHighlightMenu(hl_self, index, ...)
            end
        end
        ReaderHighlight._ps_fdict_class_patched = true
    end

    if dictionary and not dictionary._ps_fdict_addbuttons_patched then
        if type(dictionary.addToDictButtons) == "function" then
            local original_addToDictButtons = dictionary.addToDictButtons
            dictionary.addToDictButtons = function(dict_self, spec)
                if spec and spec.id then
                    modern_plugin_buttons_shared[spec.id] = spec
                end
                return original_addToDictButtons(dict_self, spec)
            end
        end
        dictionary._ps_fdict_addbuttons_patched = true
    end

    if dictionary and not dictionary._ps_fdict_patched then
        plugin.original_showDict = dictionary.showDict
        plugin.patched_dictionary = dictionary
        
        dictionary.showDict = function(dict_self, ...)
            local args = {...}
            local word = args[1]
            local results = args[2]
            local boxes = args[3]
            
            if not plugin:isEnabled() or plugin.opening_original_popup or type(results) ~= "table" or not results[1] then
                return plugin.original_showDict(dict_self, ...)
            end
            
            pcall(function()
                if dict_self.dismissLookupInfo then pcall(function() dict_self:dismissLookupInfo() end) end
                
                local is_landscape = Screen:getWidth() > Screen:getHeight()
                local anchor_top = false
                local anchor_left = false

                if is_landscape then
                    if plugin._inherited_anchor_left ~= nil then
                        anchor_left = plugin._inherited_anchor_left
                        plugin._inherited_anchor_left = nil
                    else
                        anchor_left = shouldAnchorLeft(boxes)
                    end
                else
                    if plugin._inherited_anchor_top ~= nil then
                        anchor_top = plugin._inherited_anchor_top
                        plugin._inherited_anchor_top = nil
                    else
                        anchor_top = shouldAnchorTop(boxes)
                    end
                end

                local popup = FloatingDictionaryPopup:new({
                    text = word, results = results, boxes = boxes,
                    anchor_top = anchor_top, anchor_left = anchor_left, is_landscape = is_landscape,
                    highlight_obj = highlight, plugin = plugin, current_result_idx = 1
                })
                UIManager:show(popup)
            end)
            return true
        end
        dictionary._ps_fdict_patched = true
    end

    if highlight and not highlight._ps_fdict_instance_patched then
        local orig_inst_onShowHighlightMenu = highlight.onShowHighlightMenu
        -- Capturamos el index explícitamente en la instancia también
        highlight.onShowHighlightMenu = function(hl_self, index, ...)
            if plugin:isSelectionMenuEnabled() and hl_self.selected_text and hl_self.selected_text.text and hl_self.selected_text.text ~= "" then
                local shown = showCustomActionMenu(hl_self, plugin, index)
                if shown then return true end
            end
            if type(orig_inst_onShowHighlightMenu) == "function" then
                return orig_inst_onShowHighlightMenu(hl_self, index, ...)
            end
        end
        highlight._ps_fdict_instance_patched = true
    end
end

return FloatingDict

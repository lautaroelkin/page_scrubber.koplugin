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
    return (G_reader_settings and G_reader_settings:readSetting("page_scrubber_ui_scale")) or 1.0
end
local function getTextOffset()
    if not G_reader_settings then return 0 end
    local size = G_reader_settings:readSetting("page_scrubber_text_size")
    if size == "small" then return -2
    elseif size == "large" then return 2
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
-- TARJETA DICCIONARIO (ORIGINAL INTACTA)
-- ==========================================
local FloatingCard = WidgetContainer:extend({
    anchor_top = false,
    radius = scale(24),
    bordersize = scale(3),
    content = nil,
})
function FloatingCard:init()
    local c_sz = self.content:getSize()
    self.dimen = Geom:new({ w = c_sz.w, h = c_sz.h + self.bordersize })
    
    local top_pad = self.anchor_top and 0 or self.bordersize
    local bot_pad = self.anchor_top and self.bordersize or 0
    
    self.frame = FrameContainer:new({
        padding_top = top_pad, padding_bottom = bot_pad,
        padding_left = 0, padding_right = 0,
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

    local bx = x - b
    local bw = w + (b * 2)
    paintCornerRect(bb, bx, y, bw, h, r, Blitbuffer.COLOR_BLACK, 
        not self.anchor_top, not self.anchor_top, self.anchor_top, self.anchor_top)
    
    local wy = self.anchor_top and y or (y + b)
    local wh = h - b
    local wr = math.max(0, r - b)
    paintCornerRect(bb, x, wy, w, wh, wr, Blitbuffer.COLOR_WHITE,
        not self.anchor_top, not self.anchor_top, self.anchor_top, self.anchor_top)
        
    if self[1] then self[1]:paintTo(bb, x, y) end
end

-- ==========================================
-- TARJETA MULTI-SELECCIÓN (PÍLDORA FLOTANTE)
-- ==========================================
local FloatingPillCard = WidgetContainer:extend({
    radius = scale(16),
    bordersize = scale(3),
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
local function getUiFontPaths()
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
    return regular, bold, italic, bolditalic
end

local function getBaseCss()
    local reg, bld, ita, bita = getUiFontPaths()
    return string.format([[
@font-face { font-family: "UIFont"; src: url("%s"); }
@font-face { font-family: "UIFont"; src: url("%s"); font-weight: bold; }
@font-face { font-family: "UIFont"; src: url("%s"); font-style: italic; }
@font-face { font-family: "UIFont"; src: url("%s"); font-weight: bold; font-style: italic; }

* { font-family: "UIFont", sans-serif !important; }

@page { margin: 0; }
body { margin: 0; padding: 0 0.45em; line-height: 1.3; }
p { margin: 0 0 0.28em 0; }
ol, ul { padding-left: 1.35em; margin-top: 0.18em; margin-bottom: 0.28em; }
li { margin-bottom: 0.22em; }

.floatingdictionary-word { font-size: 1.15em !important; font-weight: bold !important; line-height: 1.12; }
.floatingdictionary-meta { margin-top: 0.18em; font-size: 0.78em !important; color: #555; font-style: italic; text-transform: uppercase; }
.floatingdictionary-separator { border-top: 1px solid #eee; margin: 0.3em 0 0.4em 0; }
.search-content, .search-content * { font-size: 0.98em !important; line-height: 1.35; color: #222; }
]], reg, bld, ita, bita)
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
            plugin_path .. name
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
    icon_svg = nil, icon_char = nil, text = nil, font_size = nil, width = nil, height = nil, callback = nil, show_parent = nil, always_show_text = false
})
function PreviewButton:init()
    local inner_h = self.height or scale(48)
    local content_elements = {}

    local icon_widget = nil
    if self.icon_svg then
        local ok, widget = pcall(function()
            return ImageWidget:new{
                file = self.icon_svg,
                width = scale(24),
                height = scale(24),
                alpha = true,
                fgcolor = Blitbuffer.COLOR_BLACK
            }
        end)
        if ok and widget then
            icon_widget = widget
        end
    end

    if not icon_widget and self.icon_char then
        icon_widget = TextWidget:new{
            text = self.icon_char,
            face = Font:getFace("cfont", self.font_size or scaleText(14)),
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
            face = Font:getFace("cfont", self.font_size or scaleText(8)), 
            bold = true, 
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
function FloatingDict:discoverExternalButtons(dict_self, word, result, result_index, results, boxes, link)
    local all_buttons = {}
    if not (self.ui and self.ui.handleEvent) then return {} end

    result = result or {}
    
    local fake_popup = {
        ui = self.ui,
        dialog = dict_self and dict_self.dialog,
        dimen = Geom:new({x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight()}),
        highlight = dict_self and dict_self.highlight,
        word = word,
        lookupword = result.word or word,
        results = results,
        word_boxes = boxes,
        selected_link = link,
        is_wiki = false,
        dict_index = result_index or 1,
        dictionary = result.dict,
        lang = result.lang,
        close = function() end,
        onClose = function() end,
        closeWidget = function() end,
        updateButtons = function() end,
    }

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
    text = nil, results = nil, boxes = nil, anchor_top = false, highlight_obj = nil, plugin = nil, current_result_idx = 1,
})
function FloatingDictionaryPopup:init()
    self.dialog = self.dialog or self
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()
    self.width = screen_width
    self.max_html_height = math.floor(screen_height * 0.35)

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
        <div class="floatingdictionary-word">%s</div>
        <div class="floatingdictionary-meta">%s%s</div>
        <div class="floatingdictionary-separator"></div>
        <div class="search-content">%s</div>
    ]], htmlEscape(entry.word or self.text), dict_indicator, htmlEscape(dict_name), def_body)

    self.htmlwidget = ScrollHtmlWidget:new({
        html_body = html_body, is_xhtml = true, css = getBaseCss(),
        default_font_size = scaleText(18), width = self.width - scale(48), height = self.max_html_height,
        scroll_bar_width = scale(6), dialog = self.dialog, highlight_text_selection = true,
    })
    
    applyRoundedScrollbar(self.htmlwidget)

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
            table.insert(icon_btn_specs, { icon_svg = nil, text = btn.text, font_size = scaleText(8), action = btn.action })
        end
    end
    
    if is_btn_enabled("page_scrubber_fdict_show_plugins") then
        if self.plugin and type(self.plugin.discoverExternalButtons) == "function" then
            local plugin_rows = self.plugin:discoverExternalButtons(self.plugin.patched_dictionary, self.text, entry, self.current_result_idx, self.results, self.boxes, nil)
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
                            font_size = scaleText(8),
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

    local icon_widgets = {}
    if #icon_btn_specs > 0 then
        local icon_btn_w = math.floor((self.width - (#icon_btn_specs - 1) * scale(1)) / #icon_btn_specs)
        for _, spec in ipairs(icon_btn_specs) do
            local btn = PreviewButton:new({
                icon_svg = spec.icon_svg, 
                text = spec.text,
                font_size = spec.font_size,
                width = icon_btn_w, 
                height = scale(48), 
                always_show_text = false,
                show_parent = self,
                callback = function()
                    if spec.external_callback then
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
        for _, txt_row in ipairs(external_rows) do
            local row_widgets = {}
            local btn_w = math.floor((self.width - (#txt_row - 1) * scale(1)) / #txt_row)
            
            for _, spec in ipairs(txt_row) do
                local btn = PreviewButton:new({
                    icon_svg = nil,
                    text = spec.text,
                    font_size = spec.font_size or scaleText(8),
                    width = btn_w, 
                    height = scale(30), 
                    always_show_text = true,
                    show_parent = self,
                    callback = function()
                        pcall(spec.external_callback)
                    end
                })
                
                if spec.fake_popup and spec.id then
                    spec.fake_popup._real_buttons = spec.fake_popup._real_buttons or {}
                    spec.fake_popup._real_buttons[spec.id] = btn
                end

                table.insert(row_widgets, btn)
            end
            table.insert(text_row_widgets, HorizontalGroup:new(row_widgets))
        end
    end
    
    local top_pad = self.anchor_top and scale(32) or scale(20)
    local bot_pad = self.anchor_top and scale(20) or scale(8)
    
    self.html_row = HorizontalGroup:new({
        HorizontalSpan:new({ width = scale(24) }),
        self.htmlwidget,
        HorizontalSpan:new({ width = scale(24) })
    })

    local rows = {
        VerticalSpan:new({ width = top_pad }),
        self.html_row,
        VerticalSpan:new({ width = scale(12) })
    }

    if #text_row_widgets > 0 then
        for i, row_widget in ipairs(text_row_widgets) do
            table.insert(rows, row_widget)
            if i < #text_row_widgets or #icon_widgets > 0 then
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
        anchor_top = self.anchor_top, content = popup_content, bordersize = scale(3), radius = scale(24)
    })

    local container_h = self.container:getSize().h
    local target_y = self.anchor_top and 0 or (screen_height - container_h)
    self.popup_rect = Geom:new({ x = 0, y = target_y, w = self.width, h = container_h })

    self[1] = VerticalGroup:new({
        VerticalSpan:new({ width = math.max(0, math.floor(target_y)) }),
        self.container
    })
    
    self.dimen = Geom:new({ x = 0, y = 0, w = screen_width, h = screen_height })
    
    if Device:isTouchDevice() then 
        self.ges_events = { 
            TapClose = { GestureRange:new({ ges = "tap", range = self.dimen }) },
            Swipe = { GestureRange:new({ ges = "swipe", range = self.dimen }) }
        } 
    end
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
        <div class="floatingdictionary-word">%s</div>
        <div class="floatingdictionary-meta">%s%s</div>
        <div class="floatingdictionary-separator"></div>
        <div class="search-content">%s</div>
    ]], htmlEscape(entry.word or self.text), dict_indicator, htmlEscape(dict_name), def_body)

    if self.htmlwidget.free then pcall(function() self.htmlwidget:free() end) end

    self.htmlwidget = ScrollHtmlWidget:new({
        html_body = html_body, is_xhtml = true, css = getBaseCss(),
        default_font_size = scaleText(18), width = self.width - scale(48), height = self.max_html_height,
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
})
function FloatingActionMenu:init()
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()

    local raw_buttons = {}

    -- 1. X-Ray (si está presente en el sistema se incluye automáticamente)
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

    -- 2. Herramientas configurables de selección múltiple
    if is_btn_enabled("page_scrubber_sel_show_search") then
        table.insert(raw_buttons, { svg = "search.svg", text = "Search", action = "search" })
    end
    if is_btn_enabled("page_scrubber_sel_show_adjust") then
        table.insert(raw_buttons, { svg = "crop.svg", text = "Adj", action = "adjust" })
    end
    if is_btn_enabled("page_scrubber_sel_show_translate") then
        table.insert(raw_buttons, { svg = "languages.svg", text = "Translate", action = "translate" })
    end
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
        table.insert(raw_buttons, { svg = "highlighter.svg", text = "HL", action = "highlight" })
    end

    local btn_w = scale(50)
    local btn_h = scale(42)
    local icon_widgets = {}

    for _, spec in ipairs(raw_buttons) do
        local path = getValidSvgPath(spec.svg)
        if not path and spec.action == "ai" then
            path = getValidSvgPath("ai.svg") or getValidSvgPath("bot.svg")
        end

        local btn = PreviewButton:new({
            icon_svg = path,
            text = not path and spec.text or nil,
            font_size = scaleText(8),
            width = btn_w,
            height = btn_h,
            always_show_text = false,
            show_parent = self,
            callback = function()
                if spec.external_callback then
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

    local rows = {
        VerticalSpan:new({ width = scale(6) }),
    }

    for i, btn_widget in ipairs(icon_widgets) do
        table.insert(rows, btn_widget)
        if i < #icon_widgets then
            table.insert(rows, VerticalSpan:new({ width = scale(2) }))
        end
    end
    table.insert(rows, VerticalSpan:new({ width = scale(6) }))

    local popup_content = VerticalGroup:new(rows)

    self.card = FloatingPillCard:new({
        content = popup_content, bordersize = scale(3), radius = scale(16)
    })

    local card_size = self.card:getSize()
    local card_w = card_size.w
    local card_h = card_size.h

    -- Posicionamiento en el Sureste (Sur-Este / Bottom-Right)
    local margin_right = scale(16)
    local margin_bottom = scale(24)
    local target_x = screen_width - card_w - margin_right
    local target_y = screen_height - card_h - margin_bottom

    if target_y < scale(10) then
        target_y = scale(10)
    end

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
    if Device:isTouchDevice() then self.ges_events = { TapClose = { GestureRange:new({ ges = "tap", range = self.dimen }) } } end
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
                self_obj.plugin.opening_original_popup = true
                self_obj.plugin.original_showDict(self_obj.plugin.patched_dictionary, text, self_obj.results, boxes)
                self_obj.plugin.opening_original_popup = false
            end
        end)
    end)
end

function FloatingDictionaryPopup:invokeNative(a) invokeAction(self, a) end
function FloatingActionMenu:invokeNative(a) invokeAction(self, a) end

local function checkClose(self_obj, ges)
    if ges and ges.pos and self_obj.popup_rect and ges.pos:notIntersectWith(self_obj.popup_rect) then
        UIManager:close(self_obj)
        if self_obj.highlight_obj and self_obj.highlight_obj.clear then
            pcall(function() self_obj.highlight_obj:clear() end)
        end
        return true
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
    return true
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
    return true
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

    -- FIX: Forzar la regla de "+2 PALABRAS"
    -- Limpiamos espacios basura en los extremos y verificamos si hay espacios en el medio
    local trimmed_text = sel.text:gsub("^%s*(.-)%s*$", "%1")
    if not trimmed_text:find("%s") then
        -- Es una sola palabra. Ignoramos y dejamos que abra tu FloatingDictionaryPopup.
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
                
                local popup = FloatingDictionaryPopup:new({
                    text = word, results = results, boxes = boxes,
                    anchor_top = shouldAnchorTop(boxes), highlight_obj = highlight, plugin = plugin, current_result_idx = 1
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

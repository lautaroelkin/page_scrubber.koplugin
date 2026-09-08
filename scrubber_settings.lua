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

local Screen = Device.screen
local plugin_path = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"

-- Lector de .po en vivo sincronizado con main.lua
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

local function getTextOffset()
    if not G_reader_settings then return 0 end
    local size = G_reader_settings:readSetting("page_scrubber_text_size")
    if size == "small" then return -2
    elseif size == "large" then return 2 end
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

-- ==========================================
-- GESTOR DE ÍCONOS SVG
-- ==========================================
local _icon_cache = {}

local function getSvgPath(filename)
    if not filename or filename == "" then return nil end
    local paths = {
        plugin_path .. "icons/" .. filename,
        plugin_path .. filename
    }
    for _, p in ipairs(paths) do
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
        }
    end)

    if ok and widget then
        _icon_cache[key] = widget
        return widget
    end
    _icon_cache[key] = false
    return nil
end

-- ==========================================
-- WIDGET PRINCIPAL
-- ==========================================
local ScrubberSettings = InputContainer:extend({
    ui = nil,
    scrubber_ui = nil,
    current_view = "main",
    history = nil,
    row_dimens = nil,
    btn_back_dimen = nil,
    card_w = nil,
})

function ScrubberSettings:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()

    self.history = {}
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    self.has_ai = false
    pcall(function()
        self.has_ai = (self.ui and self.ui.assistant ~= nil)
            or (package.loaded["plugins/assistant"] ~= nil)
            or (package.loaded["assistant"] ~= nil)
    end)

    self:calculateGlobalCardWidth()
    self:updateLayout()

    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        }
    end
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
    end
    if G_reader_settings then
        G_reader_settings:saveSetting(key, val)
        G_reader_settings:flush()
    end
end

function ScrubberSettings:getPageDefinition(page_id)
    if page_id == "main" then
        return {
            title = "",
            items = {
                { text = _("Reading Pop-Ups"), icon = "notepad-text.svg", kind = "submenu", target = "popups" },
                {
                    text = _("Show chapter marks in slider"), icon = "step-forward.svg", kind = "toggle",
                    setting = "page_scrubber_show_chapter_marks", default = true,
                    on_change = function()
                        if self.scrubber_ui and self.scrubber_ui._updateChapterMarks then
                            self.scrubber_ui:_updateChapterMarks()
                        end
                    end,
                },
                { text = _("3-Page Grid: Show full pages"), icon = "gallery-horizontal.svg", kind = "toggle", setting = "page_scrubber_full_page_grid", default = false },
                { text = _("Text size"), icon = "pencil-ruler.svg", kind = "submenu", target = "text_size" },
                { text = _("UI Scale (%)"), icon = "search.svg", kind = "action", action = function() self:openScaleDialog() end },
                { text = _("Export notes of this document"), icon = "book-marked.svg", kind = "action", action = function() self:exportNotes() end },
            }
        }

    elseif page_id == "popups" then
        local dict_enabled = self:readSetting("page_scrubber_floating_dict_enabled", true)
        local sel_enabled = self:readSetting("page_scrubber_selection_menu_enabled", true)

        return {
            title = _("Reading Pop-Ups"),
            items = {
                {
                    text = _("Scrubber Dictionary"),
                    icon = "globe.svg",
                    kind = "toggle",
                    setting = "page_scrubber_floating_dict_enabled",
                    default = true,
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
                    icon = "xray.svg",
                    kind = "toggle",
                    setting = "page_scrubber_fdict_show_plugins",
                    default = true,
                    disabled = not dict_enabled,
                },
                {
                    text = _("Scrubber Selection Menu"),
                    icon = "crop.svg",
                    kind = "toggle",
                    setting = "page_scrubber_selection_menu_enabled",
                    default = true,
                },
                {
                    text = _("Position of selection menu"),
                    icon = "square-arrow-right-enter.svg",
                    kind = "submenu",
                    target = "sel_pos",
                    disabled = not sel_enabled,
                },
                {
                    text = _("Buttons in selection menu"),
                    icon = "highlighter.svg",
                    kind = "submenu",
                    target = "sel_buttons",
                    disabled = not sel_enabled,
                },
                {
                    text = _("Reverse selection buttons"),
                    icon = "arrow-down-wide-narrow.svg",
                    kind = "toggle",
                    setting = "page_scrubber_sel_reverse_order",
                    default = false,
                    disabled = not sel_enabled,
                },
            }
        }

    elseif page_id == "dict_buttons" then
        local items = {
            { text = _("Wikipedia"), icon = "globe.svg", kind = "toggle", setting = "page_scrubber_fdict_show_wiki", default = true },
            { text = _("Translate"), icon = "languages.svg", kind = "toggle", setting = "page_scrubber_fdict_show_translate", default = true },
            { text = _("Highlight"), icon = "highlighter.svg", kind = "toggle", setting = "page_scrubber_fdict_show_highlight", default = true },
            { text = _("Search"), icon = "search.svg", kind = "toggle", setting = "page_scrubber_fdict_show_search", default = true },
        }
        if self.has_ai then
            table.insert(items, { text = _("AI Assistant"), icon = "sparkles.svg", kind = "toggle", setting = "page_scrubber_fdict_show_ai", default = true })
        end
        return { title = _("Buttons in dictionary"), items = items }

    elseif page_id == "sel_buttons" then
        local items = {
            { text = _("Search"), icon = "search.svg", kind = "toggle", setting = "page_scrubber_sel_show_search", default = true },
            { text = _("Translate"), icon = "languages.svg", kind = "toggle", setting = "page_scrubber_sel_show_translate", default = true },
            { text = _("Adjust Selection"), icon = "crop.svg", kind = "toggle", setting = "page_scrubber_sel_show_adjust", default = true },
            { text = _("Note"), icon = "notepad-text.svg", kind = "toggle", setting = "page_scrubber_sel_show_note", default = true },
            { text = _("Strikethrough"), icon = "strikethrough.svg", kind = "toggle", setting = "page_scrubber_sel_show_strikethrough", default = true },
            { text = _("Underline"), icon = "underline.svg", kind = "toggle", setting = "page_scrubber_sel_show_underline", default = true },
            { text = _("Invert"), icon = "contrast.svg", kind = "toggle", setting = "page_scrubber_sel_show_invert", default = true },
            { text = _("Highlight"), icon = "highlighter.svg", kind = "toggle", setting = "page_scrubber_sel_show_highlight", default = true },
        }
        if self.has_ai then
            table.insert(items, { text = _("AI Assistant"), icon = "sparkles.svg", kind = "toggle", setting = "page_scrubber_sel_show_ai", default = true })
        end
        return { title = _("Buttons in selection menu"), items = items }

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
    end

    return { title = "", items = {} }
end

function ScrubberSettings:calculateGlobalCardWidth()
    local sw = Screen:getWidth()
    local pages = { "main", "popups", "dict_buttons", "sel_buttons", "sel_pos", "text_size" }
    local max_item_w = 0

    for _, pid in ipairs(pages) do
        local pdef = self:getPageDefinition(pid)
        if pdef.title and pdef.title ~= "" then
            local tw = TextWidget:new{
                text = "‹  " .. pdef.title,
                face = Font:getFace("cfont", scaleText(11)),
                bold = true,
            }
            local sz = tw:getSize()
            if sz.w > max_item_w then max_item_w = sz.w end
            tw:free()
        end
        for _, item in ipairs(pdef.items or {}) do
            local tw = TextWidget:new{
                text = item.text,
                face = Font:getFace("cfont", scaleText(11)),
            }
            local sz = tw:getSize()
            if sz.w > max_item_w then max_item_w = sz.w end
            tw:free()
        end
    end

    local needed_w = max_item_w + scale(75)
    local min_w = scale(260)
    local max_w = sw - scale(16)
    self.card_w = math.max(min_w, math.min(needed_w, max_w))
end

function ScrubberSettings:updateLayout()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local data = self:getPageDefinition(self.current_view)
    local num_items = #data.items
    local has_back = #self.history > 0

    if not self.card_w then
        self:calculateGlobalCardWidth()
    end

    self.header_h = has_back and scale(28) or 0
    self.row_h = scale(31)
    self.card_h = self.header_h + (num_items * self.row_h) + scale(4)

    local top_bar = self.scrubber_ui and self.scrubber_ui._top_bar_dimen
    local top_bar_bottom = top_bar and (top_bar.y + top_bar.h) or scale(58)
    local target_y = top_bar_bottom + scale(6)

    local fn = self.scrubber_ui and self.scrubber_ui._fn_dimen
    local target_x
    if fn then
        target_x = (fn.x + fn.w) - self.card_w + scale(6)
    else
        target_x = sw - self.card_w - scale(14)
    end

    if target_x + self.card_w > sw - scale(8) then target_x = sw - self.card_w - scale(8) end
    if target_x < scale(8) then target_x = scale(8) end
    if target_y + self.card_h > sh - scale(10) then target_y = sh - self.card_h - scale(10) end

    self.popup_rect = Geom:new{ x = target_x, y = target_y, w = self.card_w, h = self.card_h }

    local r = self.popup_rect
    local border = scale(2)

    if has_back then
        self.btn_back_dimen = Geom:new{ x = r.x, y = r.y, w = r.w, h = self.header_h + border }
    else
        self.btn_back_dimen = nil
    end

    self.row_dimens = {}
    local curr_y = r.y + border + self.header_h
    for _, item in ipairs(data.items) do
        local row_rect = Geom:new{ x = r.x + border, y = curr_y, w = r.w - (border * 2), h = self.row_h }
        table.insert(self.row_dimens, { dimen = row_rect, item = item })
        curr_y = curr_y + self.row_h
    end
end

function ScrubberSettings:refreshView()
    self:updateLayout()
    if self.scrubber_ui then
        UIManager:setDirty(self.scrubber_ui, "ui")
    else
        UIManager:setDirty(nil, "ui")
    end
    UIManager:setDirty(self, "ui")
end

function ScrubberSettings:pushView(target)
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

    -- Cerrar primero el menú de configuración
    UIManager:close(self)
    if not scrubber then return end

    -- Guardar el estado actual de lectura y modo del scrubber
    local view_mode = scrubber.view_mode or scrubber.initial_view_mode or "grid"
    local tab = scrubber.current_tab or scrubber.initial_tab or "bookmarks"
    local page = scrubber.current_page or (ui and ui.view and ui.view.state and ui.view.state.page) or 1
    local doc = scrubber.document or (ui and ui.document)

    -- Cerrar por completo el widget scrubber actual
    pcall(function()
        if scrubber.onClose then scrubber:onClose() end
    end)
    pcall(function()
        UIManager:close(scrubber)
    end)

    -- Relanzar de inmediato en el siguiente ciclo con la nueva configuración aplicada
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

                            for _, ann in ipairs(annotations) do
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
                            for p, _ in pairs(bm_pages_set) do table.insert(bm_list, p) end
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
                                    if #bm_list > 0 then f:write("★ : " .. table.concat(bm_list, ", ") .. "\n\n") end
                                    f:write("---\n\n")
                                    for _, p in ipairs(page_order) do
                                        f:write("## " .. tostring(p) .. "\n")
                                        for _, ann in ipairs(pages[p]) do
                                            if ann.text and ann.text ~= "" then
                                                local text = ann.text:gsub("\n", " ")
                                                local drawer = ann.drawer or "lighten"
                                                if drawer == "invert" then f:write("> *" .. text .. "*\n")
                                                elseif drawer == "underscore" then f:write("> **" .. text .. "**\n")
                                                elseif drawer == "strikeout" then f:write("> ~~" .. text .. "~~\n")
                                                else f:write("> " .. text .. "\n") end
                                            end
                                            if ann.note and ann.note ~= "" then f:write("- " .. ann.note:gsub("\n", " ") .. "\n") end
                                            f:write("\n")
                                        end
                                        f:write("---\n\n")
                                    end
                                    f:close()
                                    UIManager:close(info)
                                    UIManager:show(InfoMessage:new{ text = _("Saved successfully in:") .. "\n\n" .. full_path, timeout = 6 })
                                else
                                    UIManager:close(info)
                                    UIManager:show(InfoMessage:new{ text = _("Failed to export notes") })
                                end
                            end)

                            if not ok_export then
                                UIManager:close(info)
                                UIManager:show(InfoMessage:new{ text = _("System Error exporting notes.") })
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
    local border = scale(2)
    local radius = scale(16)

    paintRoundRect(bb, r.x, r.y, r.w, r.h, radius, Blitbuffer.COLOR_BLACK)
    paintRoundRect(bb, r.x + border, r.y + border, r.w - (border * 2), r.h - (border * 2), math.max(1, radius - border), Blitbuffer.COLOR_WHITE)

    local pad = scale(10)
    local data = self:getPageDefinition(self.current_view)
    local has_back = #self.history > 0

    if has_back then
        local hy = r.y + border
        local hh = self.header_h

        local tw_back = TextWidget:new{
            text = "‹  " .. data.title,
            face = Font:getFace("cfont", scaleText(11)),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK
        }
        local bsz = tw_back:getSize()
        tw_back:paintTo(bb, r.x + pad, hy + math.floor((hh - bsz.h) / 2))
        tw_back:free()

        bb:paintRect(r.x + border, hy + hh - 1, r.w - (border * 2), 1, Blitbuffer.COLOR_BLACK)
    end

    for idx, rdef in ipairs(self.row_dimens or {}) do
        local item = rdef.item
        local ry = rdef.dimen.y
        local rh = rdef.dimen.h

        if idx > 1 then
            bb:paintRect(r.x + border, ry, r.w - (border * 2), 1, Blitbuffer.COLOR_BLACK)
        end

        local text_color = item.disabled and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK
        local icon_color = item.disabled and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK

        local text_x = r.x + pad
        local icon_sz = scale(17)

        if item.icon and item.icon ~= "" then
            local icon_widget = loadSvg(item.icon, icon_sz, icon_color)
            if icon_widget then
                local iy = ry + math.floor((rh - icon_sz) / 2)
                icon_widget:paintTo(bb, r.x + pad, iy)
                text_x = r.x + pad + icon_sz + scale(8)
            end
        end

        local max_tw = r.w - (text_x - r.x) - scale(28)
        local tw_item = TextWidget:new{
            text = item.text,
            face = Font:getFace("cfont", scaleText(11)),
            fgcolor = text_color,
            max_width = max_tw,
            truncate_with_ellipsis = true
        }
        local isz = tw_item:getSize()
        tw_item:paintTo(bb, text_x, ry + math.floor((rh - isz.h) / 2))
        tw_item:free()

        if item.kind == "toggle" then
            local is_chk = item.read_func and (item.read_func() == true) or (self:readSetting(item.setting, item.default) == true)
            local check_str = is_chk and "☑" or "☐"
            local tw_chk = TextWidget:new{
                text = check_str,
                face = Font:getFace("cfont", scaleText(14)),
                bold = is_chk and not item.disabled,
                fgcolor = item.disabled and Blitbuffer.COLOR_DARK_GRAY or (is_chk and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY)
            }
            local cksz = tw_chk:getSize()
            tw_chk:paintTo(bb, r.x + r.w - pad - cksz.w, ry + math.floor((rh - cksz.h) / 2))
            tw_chk:free()

        elseif item.kind == "submenu" or item.kind == "action" then
            local tw_arrow = TextWidget:new{
                text = "›",
                face = Font:getFace("cfont", scaleText(13)),
                bold = true,
                fgcolor = item.disabled and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_DARK_GRAY
            }
            local asz = tw_arrow:getSize()
            tw_arrow:paintTo(bb, r.x + r.w - pad - asz.w, ry + math.floor((rh - asz.h) / 2))
            tw_arrow:free()

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
    end
end

function ScrubberSettings:onTap(arg1, arg2)
    local touch_pos = getTouchPoint(arg1, arg2)
    if not touch_pos then return false end

    -- Cerrar al tocar fuera del marco del menú
    if not pointInRect(touch_pos, self.popup_rect) then
        UIManager:close(self)
        return true
    end

    local r = self.popup_rect
    local border = scale(2)

    -- 1. Botón Volver (‹ Back) en submenús
    if self.btn_back_dimen then
        if touch_pos.y >= r.y and touch_pos.y < (r.y + border + self.header_h) then
            self:popView()
            return true
        end
    end

    -- 2. Filas de opciones
    if self.row_dimens then
        for _, rdef in ipairs(self.row_dimens) do
            local ry = rdef.dimen.y
            local rh = rdef.dimen.h
            if touch_pos.y >= ry and touch_pos.y < (ry + rh) then
                local it = rdef.item

                if it.disabled then
                    return true
                end

                if it.kind == "submenu" then
                    self:pushView(it.target)
                    return true
                elseif it.kind == "toggle" then
                    local cur = it.read_func and (it.read_func() == true) or (self:readSetting(it.setting, it.default) == true)
                    local new_state = not cur
                    if not it.read_func then
                        self:saveSetting(it.setting, new_state)
                    end
                    if it.on_change then it.on_change(new_state) end

                    -- Reabrir todo el scrubber al cambiar pantalla completa en 3-Page Grid
                    if it.setting == "page_scrubber_full_page_grid" then
                        self:reopenEntireScrubber()
                        return true
                    end

                    self:refreshView()
                    return true
                elseif it.kind == "radio" then
                    self:saveSetting(it.setting, it.val)

                    -- Reabrir todo el scrubber al cambiar tamaño de letra
                    if it.setting == "page_scrubber_text_size" then
                        self:reopenEntireScrubber()
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
    UIManager:setDirty(self, "ui")
end

function ScrubberSettings:onCloseWidget()
    if self.scrubber_ui then
        UIManager:setDirty(self.scrubber_ui, "ui")
    else
        UIManager:setDirty(nil, "ui")
    end
end

return ScrubberSettings

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

local Screen = Device.screen
local plugin_path = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"

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
                { text = _("Scrubber Actions"), icon = "warehouse.svg", kind = "submenu", target = "scrubber_actions" },
                { text = _("Export notes of this document"), icon = "book-marked.svg", kind = "action", action = function() self:exportNotes() end },
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
        for idx, act in ipairs(actions) do
            local curr_idx = idx
            local curr_act = act
            local act_title = (type(curr_act) == "table" and (curr_act.title or curr_act.id)) or tostring(curr_act)
            table.insert(items, {
                text = act_title,
                icon = self:getActionIcon(curr_act),
                kind = "action",
                right_icon = "trash-2.svg",
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
            for _, act in ipairs(actions) do
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
            { text = _("AI Assistant"), icon = "sparkles.svg", kind = "toggle", setting = "page_scrubber_fdict_show_ai", default = true },
        }
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
            { text = _("AI Assistant"), icon = "sparkles.svg", kind = "toggle", setting = "page_scrubber_sel_show_ai", default = true },
        }
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
    local pages = { "main", "popups", "dict_buttons", "sel_buttons", "sel_pos", "text_size", "scrubber_actions", "actions_launcher" }
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

    local target_x = math.floor((sw - self.card_w) / 2)

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
    end
    if self.ui then
        UIManager:setDirty(self.ui, "ui")
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
    for _, action_id in ipairs(order) do
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
                    or (aid:find("page_scrubber") and not aid:find("simple_grid"))
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
    btn_header_rect = nil,
    on_close = nil,
}

function ActionSelectDialog:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    self.header_h = scale(34)
    self.row_h = scale(32)
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

    local border = scale(2)
    local max_avail = bottom_limit - start_y
    self.items_per_page = math.max(10, math.floor((max_avail - self.header_h - self.footer_h - (border * 2)) / self.row_h))

    local total_items = #(self.actions or {})
    self.total_pages = math.max(1, math.ceil(total_items / self.items_per_page))
    self.page = math.max(1, math.min(self.page, self.total_pages))

    local start_idx = (self.page - 1) * self.items_per_page + 1
    local end_idx = math.min(start_idx + self.items_per_page - 1, total_items)
    self.current_items = {}
    for i = start_idx, end_idx do
        table.insert(self.current_items, self.actions[i])
    end

    self.card_w = math.min(sw - scale(16), scale(640))
    self.card_h = self.header_h + (self.items_per_page * self.row_h) + self.footer_h + (border * 2)

    local card_x = math.floor((sw - self.card_w) / 2)
    local card_y = start_y
    self.card_rect = Geom:new{ x = card_x, y = card_y, w = self.card_w, h = self.card_h }

    self.btn_header_rect = Geom:new{ x = card_x, y = card_y, w = self.card_w, h = self.header_h + border }

    self.row_dimens = {}
    local curr_y = card_y + border + self.header_h
    for _, item in ipairs(self.current_items) do
        local r_rect = Geom:new{ x = card_x + border, y = curr_y, w = self.card_w - (border * 2), h = self.row_h }
        table.insert(self.row_dimens, { dimen = r_rect, item = item })
        curr_y = curr_y + self.row_h
    end

    local fy = card_y + border + self.header_h + (self.items_per_page * self.row_h)
    local fw = self.card_w - (border * 2)
    self.footer_rect = Geom:new{ x = card_x + border, y = fy, w = fw, h = self.footer_h }
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

function ActionSelectDialog:paintTo(bb, x, y)
    local r = self.card_rect
    if not r then return end
    local border = scale(2)
    local radius = scale(16)
    local pad = scale(14)

    paintRoundRect(bb, r.x, r.y, r.w, r.h, radius, Blitbuffer.COLOR_BLACK)
    paintRoundRect(bb, r.x + border, r.y + border, r.w - (border * 2), r.h - (border * 2), math.max(1, radius - border), Blitbuffer.COLOR_WHITE)

    local hy = r.y + border
    local hh = self.header_h
    local tw_title = TextWidget:new{
        text = "‹  " .. _("Add Scrubber Action"),
        face = Font:getFace("cfont", scaleText(11)),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local tsz = tw_title:getSize()
    tw_title:paintTo(bb, r.x + pad, hy + math.floor((hh - tsz.h) / 2))
    tw_title:free()

    local tw_close = TextWidget:new{
        text = "✕",
        face = Font:getFace("cfont", scaleText(11)),
        bold = true,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    local csz = tw_close:getSize()
    tw_close:paintTo(bb, r.x + r.w - pad - csz.w, hy + math.floor((hh - csz.h) / 2))
    tw_close:free()

    bb:paintRect(r.x + border, hy + hh - 1, r.w - (border * 2), 1, Blitbuffer.COLOR_BLACK)

    local saved_actions = (G_reader_settings and G_reader_settings:readSetting("page_scrubber_quick_actions")) or {}

    for idx, rdef in ipairs(self.row_dimens or {}) do
        local item = rdef.item
        local ry = rdef.dimen.y
        local rh = rdef.dimen.h

        if idx > 1 then
            bb:paintRect(r.x + border, ry, r.w - (border * 2), 1, Blitbuffer.COLOR_BLACK)
        end

        local icon_name = ScrubberSettings.getActionIcon and ScrubberSettings:getActionIcon(item) or "package.svg"
        local icon_sz = scale(18)
        local text_x = r.x + pad

        local icon_w = loadSvg(icon_name, icon_sz, Blitbuffer.COLOR_BLACK)
        if icon_w then
            local iy = ry + math.floor((rh - icon_sz) / 2)
            pcall(function() icon_w:paintTo(bb, text_x, iy) end)
            text_x = text_x + icon_sz + scale(10)
        end

        local max_tw = r.w - (text_x - r.x) - scale(36)
        local tw_item = TextWidget:new{
            text = tostring(item.title or item.id),
            face = Font:getFace("cfont", scaleText(11)),
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = math.max(scale(60), max_tw),
            truncate_with_ellipsis = true,
        }
        local isz = tw_item:getSize()
        tw_item:paintTo(bb, text_x, ry + math.floor((rh - isz.h) / 2))
        tw_item:free()

        local is_already_added = false
        for _, ex in ipairs(saved_actions) do
            local ex_id = (type(ex) == "table" and ex.id) or ex
            if ex_id == item.id then
                is_already_added = true
                break
            end
        end

        local tw_sym = TextWidget:new{
            text = is_already_added and "✓" or "+",
            face = Font:getFace("cfont", scaleText(13)),
            bold = true,
            fgcolor = is_already_added and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        }
        local psz = tw_sym:getSize()
        tw_sym:paintTo(bb, r.x + r.w - pad - psz.w, ry + math.floor((rh - psz.h) / 2))
        tw_sym:free()
    end

    if self.footer_rect then
        local fy = self.footer_rect.y
        local fh = self.footer_rect.h
        bb:paintRect(r.x + border, fy - 1, r.w - (border * 2), 1, Blitbuffer.COLOR_BLACK)

        local tw_p = TextWidget:new{
            text = "‹",
            face = Font:getFace("cfont", scaleText(14)),
            bold = true,
            fgcolor = (self.page > 1) and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        }
        local psz = tw_p:getSize()
        tw_p:paintTo(bb, r.x + scale(28) - math.floor(psz.w / 2), fy + math.floor((fh - psz.h) / 2))
        tw_p:free()

        local tw_cnt = TextWidget:new{
            text = string.format("%d / %d", self.page, self.total_pages),
            face = Font:getFace("cfont", scaleText(11)),
            bold = true,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        local cnsz = tw_cnt:getSize()
        tw_cnt:paintTo(bb, r.x + math.floor((r.w - cnsz.w) / 2), fy + math.floor((fh - cnsz.h) / 2))
        tw_cnt:free()

        local tw_n = TextWidget:new{
            text = "›",
            face = Font:getFace("cfont", scaleText(14)),
            bold = true,
            fgcolor = (self.page < self.total_pages) and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        }
        local nsz = tw_n:getSize()
        tw_n:paintTo(bb, r.x + r.w - scale(28) - math.floor(nsz.w / 2), fy + math.floor((fh - nsz.h) / 2))
        tw_n:free()
    end
end

function ActionSelectDialog:closeDialog()
    UIManager:close(self)
    if self.on_close then
        self.on_close()
    end
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
    local p = getTouchPoint(arg1, arg2)
    if not p then return false end

    if not pointInRect(p, self.card_rect) then
        self:closeDialog()
        return true
    end

    if self.btn_header_rect and pointInRect(p, self.btn_header_rect) then
        self:closeDialog()
        return true
    end

    for _, rdef in ipairs(self.row_dimens or {}) do
        if pointInRect(p, rdef.dimen) then
            local act = rdef.item
            local saved = (G_reader_settings and G_reader_settings:readSetting("page_scrubber_quick_actions")) or {}
                for _, existing in ipairs(saved) do
                    local existing_id = (type(existing) == "table" and existing.id) or existing
                    if existing_id == act.id then
                        return true
                    end
                end

            table.insert(saved, {
                id = act.id,
                title = act.title,
                category = act.category or "none",
            })
            if G_reader_settings then
                G_reader_settings:saveSetting("page_scrubber_quick_actions", saved)
                G_reader_settings:flush()
            end

            self:closeDialog()
            return true
        end
    end

    if self.footer_rect and pointInRect(p, self.footer_rect) then
        local left_zone = self.card_rect.x + math.floor(self.card_w * 0.4)
        local right_zone = self.card_rect.x + self.card_w - math.floor(self.card_w * 0.4)

        if p.x <= left_zone then
            self:prevPage()
            return true
        elseif p.x >= right_zone then
            self:nextPage()
            return true
        end
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
    if self.scrubber_ui then
        UIManager:setDirty(self.scrubber_ui, "ui")
    end
    if self.ui then
        UIManager:setDirty(self.ui, "ui")
    else
        UIManager:setDirty(nil, "ui")
    end
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
        on_close = function()
            UIManager:nextTick(function()
                local ScrubberSettingsMod = require("scrubber_settings")
                local inst = ScrubberSettingsMod:new{
                    ui = ui,
                    scrubber_ui = scrubber_ui,
                }
                inst.current_view = "scrubber_actions"
                inst.history = { "main" }
                inst.card_w = nil
                inst:updateLayout()
                UIManager:show(inst)
            end)
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
                                    if #bm_list > 0 then f:write("⚑ : " .. table.concat(bm_list, ", ") .. "\n\n") end
                                    f:write("---\n\n")
                                    for _, p in ipairs(page_order) do
                                        f:write("## " .. tostring(p) .. "\n")

                                        for _, ann in ipairs(pages[p]) do
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
                pcall(function()
                    icon_widget:paintTo(bb, r.x + pad, iy)
                end)
                text_x = r.x + pad + icon_sz + scale(8)
            end
        end

        local max_tw = math.max(scale(40), r.w - (text_x - r.x) - scale(28))
        local tw_item = TextWidget:new{
            text = tostring(item.text or ""),
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
    end
end

function ScrubberSettings:onTap(arg1, arg2)
    local touch_pos = getTouchPoint(arg1, arg2)
    if not touch_pos then return false end

    if not pointInRect(touch_pos, self.popup_rect) then
        UIManager:close(self)
        return true
    end

    local r = self.popup_rect
    local border = scale(2)

    if self.btn_back_dimen then
        if touch_pos.y >= r.y and touch_pos.y < (r.y + border + self.header_h) then
            self:popView()
            return true
        end
    end

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

                    if it.setting == "page_scrubber_full_page_grid" then
                        self:reopenEntireScrubber()
                        return true
                    end

                    self:refreshView()
                    return true
                elseif it.kind == "radio" then
                    self:saveSetting(it.setting, it.val)

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
    if self.ui then
        UIManager:setDirty(self.ui, "ui")
    end
    UIManager:setDirty(self, "ui")
end

function ScrubberSettings:onCloseWidget()
    if self.scrubber_ui then
        UIManager:setDirty(self.scrubber_ui, "ui")
    end
    if self.ui then
        UIManager:setDirty(self.ui, "ui")
    else
        UIManager:setDirty(nil, "ui")
    end
end

return ScrubberSettings

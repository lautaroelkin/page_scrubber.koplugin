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
local UIManager       = require("ui/uimanager")
local logger          = require("logger")
local _               = require("gettext")

local GridSimpleView  = require("grid_simple_view")
local ProgressSlider  = require("progress_slider")
local Screen          = Device.screen

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

local function processTile(tile, req_w, req_h)
    if not tile or not tile.bb then return nil end
    local w, h = tile.bb:getWidth(), tile.bb:getHeight()
    if w <= 0 or h <= 0 then return nil end
    if w > req_w + 4 or h > req_h + 4 then
        local ok, scaled = pcall(function() return tile.bb:scale(req_w, req_h) end)
        if ok and scaled then return { bb = scaled, is_scaled = true } end
    end
    return { bb = tile.bb, is_scaled = false }
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
    self._pressed_btn = nil
    self._closing     = false
    self._hold_token  = 0
    self._hold_active = false
    
    self._view_mode = self.initial_view_mode or "grid" 
    self._base_grid_mode = self.base_mode or ((self.initial_view_mode == "grid_simple") and "grid_simple" or "grid")
    self._active_tab = self.initial_tab or "bookmarks" 
    self._sort_order = self.initial_sort_order or "desc" 
    self._split_bm_page = self.initial_bm_page or 1  
    self._force_menu_sync = true 
    self._split_fixed_page = self.initial_fixed_page or ((self._view_mode == "split") and self._cur_page or nil) 
    self._split_divider_x = nil
    self._hl_filter = self.initial_hl_filter or nil 
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
    
    self._is_busy     = true
    self._tasks_in_flight = 0
    self._pending_grid_update = false

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self._sw = sw
    self._sh = sh
    local pad = S(16)

    local S_GRANDE   = S(15)
    local S_MEDIANO  = S(13)
    local S_CHIQUITO = S(12)

    self._tw_tab_sort = TextWidget:new{ text = "", face = Font:getFace("cfont", S_CHIQUITO) }
    self._tw_tab_bm   = TextWidget:new{ text = "", face = Font:getFace("cfont", S_CHIQUITO) }
    self._tw_tab_hl   = TextWidget:new{ text = "", face = Font:getFace("cfont", S_CHIQUITO) }
    self._tw_tab_note = TextWidget:new{ text = "", face = Font:getFace("cfont", S_CHIQUITO) }

    local top_h     = S(58)
    local top_bar_y = 0
    self._top_bar_dimen = Geom:new{ x = 0, y = top_bar_y, w = sw, h = top_h }

    self.font_ch    = Font:getFace("cfont", S_GRANDE)
    self.font_title = Font:getFace("cfont", S_GRANDE) 
    self.font_info  = Font:getFace("cfont", S_MEDIANO)

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
    self.tw_chapter  = TextWidget:new{ text = "", face = self.font_ch, bold = true, fgcolor = Blitbuffer.COLOR_BLACK, max_width = self.max_title_w }
    self.tw_info     = TextWidget:new{ text = "", face = self.font_info, fgcolor = Blitbuffer.COLOR_DARK_GRAY }

    self.tw_chapter:setText(_("—"))
    self.tw_info:setText("100% · 9999 / 9999")

    local title_margin_top = S(14)
    local title_margin_bot = S(8)
    local title_h = self.tw_booktitle:getSize().h
    
    self._booktitle_y = top_h + title_margin_top

    local ch_h = self.tw_chapter:getSize().h
    local info_h = self.tw_info:getSize().h

    self._slider = ProgressSlider:new{ width = sw - pad * 4, value = self._cur_page, value_min = 1, value_max = self._total_pages, ticks = nil, S = S }
    
    self:_invalidateBookmarksCache()
    local slider_h = self._slider:getSize().h

    local PLUGIN_DIR = debug.getinfo(1, "S").source:gsub("^@(.*)/[^/]*", "%1")

    local function createSafeIcon(icon_char, svg_filename, sz, custom_color)
        local fg = custom_color or Blitbuffer.COLOR_BLACK
        local base_path = PLUGIN_DIR .. "/icons/" .. svg_filename
        local ok, widget = pcall(function()
            local ImageWidget = require("ui/widget/imagewidget")
            return ImageWidget:new{ 
                file = base_path, width = sz, height = sz, 
                alpha = true, fgcolor = fg 
            }
        end)
        if ok and widget then return widget end
        return TextWidget:new{ text = icon_char, face = Font:getFace("cfont", sz), fgcolor = fg }
    end

    local top_icon_sz = S(28)

    self.tw_lib       = createSafeIcon("\u{E344}", "arrow-left.svg", top_icon_sz)
    self.tw_lib_label = TextWidget:new{ text = "Library", face = Font:getFace("cfont", S_MEDIANO), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
    
    self.tw_fn        = createSafeIcon("⚙", "settings-2.svg", top_icon_sz)
    self.tw_bm        = createSafeIcon("\u{F044}", "notebook-pen.svg", top_icon_sz)
    self.tw_gallery   = createSafeIcon("\u{F009}", "gallery-horizontal.svg", top_icon_sz)
    self.tw_toc       = createSafeIcon("\u{F0CA}", "table-of-contents.svg", top_icon_sz)
    self.tw_grid_toggle = createSafeIcon("\u{E8EF}", "layout-grid.svg", top_icon_sz)
    self.tw_x         = createSafeIcon("✕", "x.svg", top_icon_sz)

    self.tw_ch_l      = createSafeIcon("\u{EBAD}", "skip-back.svg", S(32))
    self.tw_ch_r      = createSafeIcon("\u{EBAC}", "skip-forward.svg", S(32))

    local font_ctrl_carets = Font:getFace("cfont", S(20))
    local mark_icon_sz = S(42) 
    
    self.tw_ctrl_prev = TextWidget:new{ text = "\u{F0D9}", face = font_ctrl_carets, fgcolor = Blitbuffer.COLOR_BLACK }
    self.icon_mark_empty = createSafeIcon("\u{F097}", "gravity-ui--bookmark.svg", mark_icon_sz)
    self.icon_mark_filled = createSafeIcon("\u{F02E}", "gravity-ui--bookmark-fill.svg", mark_icon_sz)
    self.tw_ctrl_mark = self.icon_mark_empty 
    self.tw_ctrl_next = TextWidget:new{ text = "\u{F0DA}", face = font_ctrl_carets, fgcolor = Blitbuffer.COLOR_BLACK }

    local tab_icon_sz = S(24)
    self.icon_tab_bm   = createSafeIcon("\u{E7B9}", "majesticons--book.svg", tab_icon_sz)
    self.icon_tab_hl   = createSafeIcon("\u{E931}", "majesticons--filter.svg", tab_icon_sz)
    self.icon_tab_note = createSafeIcon("\u{F075}", "majesticons--chat-2-text.svg", tab_icon_sz)

    self.icon_sort_asc  = createSafeIcon("\u{EBBB}", "arrow-up-wide-narrow.svg", tab_icon_sz)
    self.icon_sort_desc = createSafeIcon("\u{EBBC}", "arrow-down-wide-narrow.svg", tab_icon_sz)

    local pol_icon_sz = S(20) 
    self.icon_pol_note = createSafeIcon("\u{F448}", "gravity-ui--pencil-to-square.svg", pol_icon_sz)
    self.icon_pol_hl   = createSafeIcon("\u{ED51}", "boxicons--highlight-filled.svg", pol_icon_sz)
    self.icon_pol_bm   = createSafeIcon("\u{F02E}", "gravity-ui--bookmark-fill.svg", pol_icon_sz)

    local filter_icon_sz = S(14)
    self.icon_filter_hl_on  = createSafeIcon("\u{ED51}", "droplet.svg", filter_icon_sz, Blitbuffer.COLOR_BLACK)
    self.icon_filter_hl_off = createSafeIcon("\u{ED51}", "droplet.svg", filter_icon_sz, Blitbuffer.COLOR_DARK_GRAY)
    
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

    self.icon_btn_trash     = createSafeIcon("\u{F014}", "trash-2.svg", S(22), Blitbuffer.COLOR_BLACK)
    self.icon_btn_edit      = createSafeIcon("\u{F040}", "pencil-sparkles.svg", S(22), Blitbuffer.COLOR_BLACK)
    self.icon_btn_type      = createSafeIcon("\u{F1FC}", "pencil-ruler.svg", S(22), Blitbuffer.COLOR_BLACK)

    local box_icon_sz = S(22)
    self.icon_box_plus       = createSafeIcon("\u{002B}", "square-plus.svg", box_icon_sz)
    self.icon_box_minus_fill = createSafeIcon("\u{2212}", "square-minus-filled.svg", box_icon_sz)
    self.icon_box_minus      = createSafeIcon("\u{2212}", "square-minus.svg", box_icon_sz)
    self.icon_box_arrow      = createSafeIcon("\u{003E}", "square-arrow-right-enter.svg", box_icon_sz)
    
    self.icon_chevron_left   = createSafeIcon("‹", "chevron-left.svg", box_icon_sz)
    self.icon_chevron_right  = createSafeIcon("›", "chevron-right.svg", box_icon_sz)

    local gs_chevron_sz = S(44)
    self.icon_gs_chevron_left  = createSafeIcon("‹", "chevron-left.svg", gs_chevron_sz)
    self.icon_gs_chevron_right = createSafeIcon("›", "chevron-right.svg", gs_chevron_sz)
    
    local gs_x_sz = S(36)
    self.icon_gs_x = createSafeIcon("✕", "x.svg", gs_x_sz)

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

    local fit_to_width = false
    if G_reader_settings and G_reader_settings:readSetting("page_scrubber_full_page_grid") then
        fit_to_width = true
    end

    if self._is_comic or fit_to_width then
        self._grid_item_w = math.floor((sw - 2 * self._grid_margin) / 3)
        self._grid_item_h = math.floor(self._grid_item_w * sh / sw)
    else
        self._grid_item_h = grid_y_avail - 2 * self._grid_margin
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

    local side_sz = S(30)
    local ctrl_sp = S(10)
    local total_ctrl_w = side_sz * 2 + mark_sz + ctrl_sp * 2
    local ctrl_x = math.floor((sw - total_ctrl_w) / 2)
    self._ctrl_row_x0 = ctrl_x
    self._ctrl_row_x1 = ctrl_x + total_ctrl_w
    self._ctrl_row_h = mark_sz

    self._ctrl_prev_dimen = Geom:new{ x = ctrl_x, y = self.ctrl_y_pos + math.floor((mark_sz - side_sz)/2), w = side_sz, h = side_sz }
    self._ctrl_mark_dimen = Geom:new{ x = ctrl_x + side_sz + ctrl_sp, y = self.ctrl_y_pos, w = mark_sz, h = mark_sz }
    self._ctrl_next_dimen = Geom:new{ x = ctrl_x + side_sz + mark_sz + ctrl_sp * 2, y = self.ctrl_y_pos + math.floor((mark_sz - side_sz)/2), w = side_sz, h = side_sz }

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
        self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } }, Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }, MultiSwipe = { GestureRange:new{ ges = "multiswipe", range = self.dimen } } }
    else
        self.ges_events = {
            Tap         = { GestureRange:new{ ges = "tap",          range = self.dimen } },
            Pan         = { GestureRange:new{ ges = "pan",          range = self.dimen } },
            PanRelease  = { GestureRange:new{ pan_release = "pan_release",  range = self.dimen } },
            Swipe       = { GestureRange:new{ ges = "swipe",        range = self.dimen } },
            MultiSwipe  = { GestureRange:new{ ges = "multiswipe",   range = self.dimen } },
            Hold        = { GestureRange:new{ ges = "hold",         range = self.dimen } },
            HoldRelease = { GestureRange:new{ ges = "hold_release", range = self.dimen } },
            Release     = { GestureRange:new{ ges = "release",      range = self.dimen } },
            Pinch       = { GestureRange:new{ ges = "pinch",        range = self.dimen } },
            Spread      = { GestureRange:new{ ges = "spread",       range = self.dimen } },
        }
    end

    if not self._grid_disabled then
        local ok_clear, err_clear = pcall(function() DocCache:clear() end)
        if not ok_clear then logger.warn("page-scrubber: failed to clear DocCache:", err_clear) end
        UIManager:scheduleIn(self._is_comic and 0.5 or 0.15, function()
            if not self._closing then self:_updateGridPages() end
        end)
    end
end

function PageScrubber:_freeTile(slot)
    if slot and slot.is_scaled and slot.tile_bb then
        pcall(function() slot.tile_bb:free() end)
    end
    if slot then
        slot.tile_bb = nil
        slot.is_scaled = false
    end
end

function PageScrubber:_invalidateBookmarksCache()
    self._cached_bms = nil
    self._slider.bookmarks = self:_getAllBookmarks()
    self:_extractAnnotations()
end

function PageScrubber:_getNumericalPage(v)
    if type(v) ~= "table" then return nil end
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
    return bms
end

function PageScrubber:_extractAnnotations()
    self._cached_hl = {}
    self._cached_notes = {}
    self._page_data = {}
    self._hl_types_present = { normal = false, invert = false, underline = false, strikethrough = false }
    local hl_map = {}
    local note_map = {}
    local tp = self._total_pages or 1

    local function drawer_to_filter(drawer)
        if not drawer or drawer == "lighten" then return "normal"
        elseif drawer == "invert" then return "invert"
        elseif drawer == "underscore" then return "underline"
        elseif drawer == "strikeout" then return "strikethrough"
        end
        return "normal"
    end

    local function process_item(v, k)
        if type(v) == "table" then
            local p = self:_getNumericalPage(v)
            if type(p) == "number" and p >= 1 and p <= tp then
                p = math.floor(p)
                if not self._page_data[p] then self._page_data[p] = {} end
                local date_val = v.datetime or v.time or v.date or v.timestamp
                if date_val and not self._page_data[p].date then self._page_data[p].date = date_val end

                local is_real_highlight = (v.drawer ~= nil) or (v.pos0 ~= nil and v.pos1 ~= nil) or (v.highlight == true)
                local is_real_note = (v.note ~= nil and v.note ~= "")
                
                if is_real_note or is_real_highlight then
                    if is_real_highlight and v.text and v.text ~= "" then
                        local filt = drawer_to_filter(v.drawer)
                        if filt then
                            if not self._page_data[p].hl_types then self._page_data[p].hl_types = {} end
                            self._page_data[p].hl_types[filt] = true
                            self._hl_types_present[filt] = true

                            if not self._page_data[p].texts_by_type then self._page_data[p].texts_by_type = {} end
                            if self._page_data[p].texts_by_type[filt] then
                                if not string.find(self._page_data[p].texts_by_type[filt], v.text, 1, true) then
                                    self._page_data[p].texts_by_type[filt] = self._page_data[p].texts_by_type[filt] .. " | " .. v.text
                                end
                            else
                                self._page_data[p].texts_by_type[filt] = v.text
                            end
                        end

                        if self._page_data[p].text and not string.find(self._page_data[p].text, v.text, 1, true) then
                            self._page_data[p].text = self._page_data[p].text .. " | " .. v.text
                        else
                            self._page_data[p].text = v.text
                        end
                        hl_map[p] = true
                    end
                    if is_real_note and v.note and v.note ~= "" then
                        if self._page_data[p].note and not string.find(self._page_data[p].note, v.note, 1, true) then
                            self._page_data[p].note = self._page_data[p].note .. " | " .. v.note
                        else
                            self._page_data[p].note = v.note
                        end
                        note_map[p] = true
                    end
                end
            end
        else
            local p_val = tonumber(k)
            if p_val and p_val >= 1 and p_val <= tp and (type(v) == "string" or type(v) == "number") then
                p_val = math.floor(p_val)
                if not self._page_data[p_val] then self._page_data[p_val] = {} end
                if not self._page_data[p_val].date then self._page_data[p_val].date = v end
            end
        end
    end

    if self.ui.annotation and self.ui.annotation.annotations then
        for k, v in pairs(self.ui.annotation.annotations) do process_item(v, k) end
    end
    if self.ui.doc_props and self.ui.doc_props.bookmarks then
        for k, v in pairs(self.ui.doc_props.bookmarks) do process_item(v, k) end
    end
    if self.ui.bookmark and self.ui.bookmark._bookmarks then
        for k, v in pairs(self.ui.bookmark._bookmarks) do process_item(v, k) end
    end
    if self.ui.bookmark and self.ui.bookmark.bookmarks then
        for k, v in pairs(self.ui.bookmark.bookmarks) do process_item(v, k) end
    end
    
    for p, _ in pairs(hl_map) do table.insert(self._cached_hl, p) end
    for p, _ in pairs(note_map) do table.insert(self._cached_notes, p) end
    table.sort(self._cached_hl, function(a,b) return tonumber(a) > tonumber(b) end)
    table.sort(self._cached_notes, function(a,b) return tonumber(a) > tonumber(b) end)

    local types_count = 0
    for _, present in pairs(self._hl_types_present) do
        if present then types_count = types_count + 1 end
    end
    
    if self._hl_filter and not self._hl_types_present[self._hl_filter] then
        self._hl_filter = self.initial_hl_filter or nil
    elseif types_count < 2 then
        self._hl_filter = self.initial_hl_filter or nil
    end
end

function PageScrubber:_getFilteredActiveList()
    local fixed_page = self._split_fixed_page or self._origin_page
    local active_list = {}
    if self._active_tab == "bookmarks" then active_list = self:_getAllBookmarks()
    elseif self._active_tab == "highlights" then active_list = self._cached_hl or {}
    elseif self._active_tab == "notes" then active_list = self._cached_notes or {} end

    local other_items = {}
    for _, p in ipairs(active_list) do
        local is_excluded = (self._active_tab == "bookmarks") and (tonumber(p) == tonumber(fixed_page))
        if not is_excluded then
            local passes_filter = true
            if self._active_tab == "highlights" and self._hl_filter then
                local pdata = self._page_data[tonumber(p)]
                passes_filter = pdata and pdata.hl_types and pdata.hl_types[self._hl_filter] or false
            end
            if passes_filter then table.insert(other_items, p) end
        end
    end

    if self._sort_order == "asc" then
        table.sort(other_items, function(a, b) return tonumber(a) < tonumber(b) end)
    else
        table.sort(other_items, function(a, b) return tonumber(a) > tonumber(b) end)
    end
    return other_items
end

function PageScrubber:onNextChapterKey()
    if self._closing then return true end
    if self._view_mode == "split" then
        local items = self:_getFilteredActiveList()
        if #items > 0 then
            local cur_idx = nil
            for idx, p in ipairs(items) do
                if tonumber(p) == tonumber(self._cur_page) then cur_idx = idx; break end
            end
            local target_idx = (cur_idx and cur_idx > 1) and (cur_idx - 1) or #items
            self._force_menu_sync = true
            self:_previewPage(items[target_idx], false)
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
            for idx, p in ipairs(items) do
                if tonumber(p) == tonumber(self._cur_page) then cur_idx = idx; break end
            end
            local target_idx = (cur_idx and cur_idx < #items) and (cur_idx + 1) or 1
            self._force_menu_sync = true
            self:_previewPage(items[target_idx], false)
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
        if self._active_tab == "notes" then self._active_tab = "highlights"
        elseif self._active_tab == "highlights" then self._active_tab = "bookmarks"
        else self._active_tab = "notes" end
        self._split_bm_page = self.initial_bm_page or 1
        self:_extractAnnotations()
        UIManager:setDirty(self, "ui", self.dimen)
        return true
    else
        local jump = (self._view_mode == "grid_six") and 6 or 1
        self:_previewPage(self._cur_page - jump, false) 
    end
    return true 
end
function PageScrubber:onPageBackward() return self:onPrevPage() end

function PageScrubber:onNextPage() 
    if self._closing then return true end
    if self._view_mode == "split" then
        if self._active_tab == "bookmarks" then self._active_tab = "highlights"
        elseif self._active_tab == "highlights" then self._active_tab = "notes"
        else self._active_tab = "bookmarks" end
        self._split_bm_page = self.initial_bm_page or 1
        self:_extractAnnotations()
        UIManager:setDirty(self, "ui", self.dimen)
        return true
    else
        local jump = (self._view_mode == "grid_six") and 6 or 1
        self:_previewPage(self._cur_page + jump, false) 
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

function PageScrubber:_safeBookmarkToggle(target_page)
    self:_waitForIdle(function()
        if self._closing then return end
        
        self:_invalidateGridTilesForPage(target_page)

        local ok, err = pcall(function()
            self.ui:handleEvent(Event:new("GotoPage", target_page))
            self.ui:handleEvent(Event:new("ToggleBookmark"))
        end)

        if not ok then logger.warn("page-scrubber: safe toggle failed:", err) end

        self:_invalidateBookmarksCache()

        if not self._closing then
            self:_updateGridPages()
            UIManager:setDirty(self, "ui", self.dimen)
        end
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

function PageScrubber:_updateTexts()
    local pct = math.floor(self._cur_page / math.max(1, self._total_pages) * 100)
    self.tw_chapter:setText(self:_getChapter(self._cur_page))
    
    if self._view_mode == "grid_six" then
        local start_p = math.max(1, self._cur_page - 1)
        local end_p = math.min(self._cur_page + 4, self._total_pages)
        self.tw_info:setText("Páginas " .. start_p .. " - " .. end_p)
    else
        self.tw_info:setText(pct .. "%  ·  " .. self._cur_page .. " / " .. self._total_pages)
    end
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
    local thumbnail = self.ui.thumbnail
    local S = self.S
    local sw, sh = Screen:getWidth(), Screen:getHeight()

    if self._view_mode == "grid_six" then
        self._grid_dimen.y = self._top_bar_dimen.y + self._top_bar_dimen.h + S(26)
        self._grid_dimen.h = self._bar_dimen.y - self._grid_dimen.y - S(26)
    else
        self._grid_dimen.y = self._booktitle_y + self.tw_booktitle:getSize().h + S(8)
        self._grid_dimen.h = self._bar_dimen.y - self._grid_dimen.y
    end

    if self._view_mode == "split" then
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

    elseif self._view_mode == "grid_simple" then
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
    elseif self._view_mode == "grid_six" then
        local ok, GridSixView = pcall(require, "grid_six_view")
        if ok and GridSixView then
            local slots = GridSixView.getSlotDimens(self)
            if slots and slots[1] then
                self._thumb_req_split_w = slots[1].w
                self._thumb_req_split_h = slots[1].h
            end
        end
    end

    self._grid_batch_seq = self._grid_batch_seq + 1
    local batch_id = "page_scrubber_grid_" .. self._grid_instance_id .. "_" .. tostring(self._grid_batch_seq)
    self._grid_batch_id = batch_id

    local old_tiles = self._grid_tiles or {}
    self._grid_tiles = {}
    local missing = {}

    local expected_req_w = (self._view_mode == "grid") and self._grid_item_w or self._thumb_req_split_w
    local expected_req_h = (self._view_mode == "grid") and self._grid_item_h or self._thumb_req_split_h

    if self._view_mode == "grid" then
        local nb_items = self._grid_cols * self._grid_rows
        for idx = 1, nb_items do
            local page = self._cur_page + (idx - 2)
            local valid = page >= 1 and page <= self._total_pages
            
            self._grid_tiles[idx] = { page = valid and page or nil, loading = valid, is_scaled = false, mode = "grid" }
            
            if valid then
                for old_idx, old_slot in pairs(old_tiles) do
                    if old_slot.page == page and old_slot.tile_bb and old_slot.mode == "grid" then
                        self._grid_tiles[idx].tile_bb = old_slot.tile_bb
                        self._grid_tiles[idx].is_scaled = old_slot.is_scaled
                        self._grid_tiles[idx].loading = false
                        old_tiles[old_idx] = nil 
                        break
                    end
                end
            end
        end
        for _, idx in ipairs({ 2, 3, 1 }) do
            local slot = self._grid_tiles[idx]
            if slot and slot.page and not slot.tile_bb then missing[#missing + 1] = idx end
        end
    elseif self._view_mode == "grid_six" then
        for idx = 1, 6 do
            local page = self._cur_page + (idx - 2)
            local valid = page >= 1 and page <= self._total_pages
            
            self._grid_tiles[idx] = { page = valid and page or nil, loading = valid, is_scaled = false, mode = "grid_six" }
            
            if valid then
                for old_idx, old_slot in pairs(old_tiles) do
                    if old_slot.page == page and old_slot.tile_bb and old_slot.mode == "grid_six" then
                        self._grid_tiles[idx].tile_bb = old_slot.tile_bb
                        self._grid_tiles[idx].is_scaled = old_slot.is_scaled
                        self._grid_tiles[idx].loading = false
                        old_tiles[old_idx] = nil 
                        break
                    end
                end
            end
        end
        for idx = 1, 6 do
            local slot = self._grid_tiles[idx]
            if slot and slot.page and not slot.tile_bb then missing[#missing + 1] = idx end
        end
    else
        local page = self._cur_page
        local valid = page >= 1 and page <= self._total_pages
        self._grid_tiles[2] = { page = valid and page or nil, loading = valid, is_scaled = false, mode = self._view_mode }
        
        if valid then
            for old_idx, old_slot in pairs(old_tiles) do
                if old_slot.page == page and old_slot.tile_bb and old_slot.mode == self._view_mode then
                    self._grid_tiles[2].tile_bb = old_slot.tile_bb
                    self._grid_tiles[2].is_scaled = old_slot.is_scaled
                    self._grid_tiles[2].loading = false
                    old_tiles[old_idx] = nil 
                    break
                end
            end
        end
        if self._grid_tiles[2] and self._grid_tiles[2].page and not self._grid_tiles[2].tile_bb then
            missing[#missing + 1] = 2
        end
    end

    for _, old_slot in pairs(old_tiles) do self:_freeTile(old_slot) end

    if #missing == 0 then
        self._is_busy = false
        self._tasks_in_flight = 0
        UIManager:setDirty(self, "ui", self._grid_dimen)
        if self._pending_grid_update and not self._closing then
            self._pending_grid_update = false
            self:_updateGridPages()
        end
        return
    end

    self._is_busy = true
    self._tasks_in_flight = #missing
    local inter_request_delay = (self._is_comic and self._grid_batch_seq == 1) and 0.45 or 0.01

    local function requestOne(pos)
        if self._closing or self._grid_batch_id ~= batch_id then return end

        local idx = missing[pos]
        if not idx then
            self._is_busy = false
            self._tasks_in_flight = 0
            if self._pending_grid_update and not self._closing then
                self._pending_grid_update = false
                self:_updateGridPages()
            end
            return
        end

        local slot = self._grid_tiles[idx]
        local req_page = slot and slot.page
        if not req_page then
            requestOne(pos + 1)
            return
        end

        local advanced = false
        local function advance()
            if advanced then return end
            advanced = true
            self._tasks_in_flight = math.max(0, self._tasks_in_flight - 1)
            if self._tasks_in_flight == 0 then
                self._is_busy = false
                if self._pending_grid_update and not self._closing then
                    self._pending_grid_update = false
                    self:_updateGridPages()
                end
            end
            if not self._closing then
                UIManager:scheduleIn(inter_request_delay, function() requestOne(pos + 1) end)
            end
        end

        local retry_count = 0
        local RETRY_DELAYS = { 0.3, 1.2, 3.0, 6.0 }
        local MAX_RETRIES = #RETRY_DELAYS
        
        local current_req_w = expected_req_w
        local current_req_h = expected_req_h

        local function dispatch()
            if self._closing or self._grid_batch_id ~= batch_id then return end

            local timed_out = false
            UIManager:scheduleIn(6.9, function()
                if self._closing then return end
                if not advanced and self._grid_batch_id == batch_id then
                    timed_out = true
                    if retry_count < MAX_RETRIES then
                        retry_count = retry_count + 1
                        current_req_w = (current_req_w == expected_req_w) and (expected_req_w + 1) or expected_req_w
                        if not self._closing then
                            self:_nudgeDecoder(req_page)
                            UIManager:scheduleIn(RETRY_DELAYS[retry_count], dispatch)
                        end
                        return
                    end

                    if slot then
                        slot.loading = false
                        slot.error = true
                        UIManager:setDirty(self, "ui", self._grid_dimen)
                    end
                    advance()
                end
            end)

            thumbnail:getPageThumbnail(req_page, current_req_w, current_req_h, batch_id,
                function(tile, resp_batch_id, async_response)
                    if self._closing then return end
                    if timed_out then return end
                    if resp_batch_id ~= batch_id or self._grid_batch_id ~= batch_id then return end

                    local processed = processTile(tile, current_req_w, current_req_h)
                    local corrupted = false
                    if not processed or not processed.bb then corrupted = true end

                    if corrupted and retry_count < MAX_RETRIES then
                        retry_count = retry_count + 1
                        current_req_w = (current_req_w == expected_req_w) and (expected_req_w + 1) or expected_req_w
                        if not self._closing then
                            self:_nudgeDecoder(req_page)
                            UIManager:scheduleIn(RETRY_DELAYS[retry_count], dispatch)
                        end
                        return
                    end

                    if corrupted and self._is_comic then pcall(function() DocCache:clear() end) end

                    if not self._closing then
                        if not corrupted and processed then
                            slot.tile_bb = processed.bb
                            slot.is_scaled = processed.is_scaled
                            slot.loading = false
                        elseif corrupted then
                            slot.loading = false
                            slot.error = true
                        end
                        UIManager:setDirty(self, "ui", self._grid_dimen)
                    end
                    advance()
                end)
        end
        dispatch()
    end
    requestOne(1)
    UIManager:setDirty(self, "ui", self._grid_dimen)
end

function PageScrubber:_waitForIdle(callback)
    if not self._is_busy and (self._tasks_in_flight or 0) == 0 then
        callback()
        return
    end
    UIManager:scheduleIn(0.05, function() self:_waitForIdle(callback) end)
end

function PageScrubber:_invalidateGridTilesForPage(page)
    for idx, slot in pairs(self._grid_tiles) do
        if slot.page == page then
            self:_freeTile(slot)
            slot.loading = true
            slot.error = nil
        end
    end
end

function PageScrubber:_clearGridTiles()
    for idx, slot in pairs(self._grid_tiles) do
        self:_freeTile(slot)
        slot.loading = true
        slot.error = nil
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

        if self._is_comic then pcall(function() DocCache:clear() end) end

        UIManager:setDirty(self, "ui", self._grid_dimen)
        self:_updateGridPages()
    end)
end

function PageScrubber:_paintGrid(bb)
    local nb_items = self._grid_cols * self._grid_rows
    local all_bms = self:_getAllBookmarks()
    self._center_bm_touch_dimen = nil

    local sw, sh = Screen:getWidth(), Screen:getHeight()

    for idx = 1, nb_items do
        local slot = self._grid_tiles[idx]
        local rect = self:_gridSlotDimen(idx)
        local is_cur = (idx == 2)
        local border = is_cur and self.S(3) or self.S(1)

        bb:paintRect(rect.x, rect.y, rect.w, rect.h, Blitbuffer.COLOR_WHITE)
        
        if slot and slot.page then
            if slot.tile_bb then
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
                
                if blit_w > 0 and blit_h > 0 then
                    bb:blitFrom(slot.tile_bb, ox, oy, src_x, src_y, blit_w, blit_h)
                end
            elseif slot.error then
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
                bb:paintRect(rect.x + math.floor(rect.w / 2) - 1, rect.y + math.floor(rect.h / 2) - 1,
                    2, 2, Blitbuffer.COLOR_GRAY)
            end
            
            if self._grid_flash_idx == idx then
                bb:paintRect(rect.x, rect.y, rect.w, rect.h, Blitbuffer.COLOR_BLACK)
            end
            
            local is_bmed = false
            for _, bmp in ipairs(all_bms) do
                if tonumber(bmp) == tonumber(slot.page) then
                    is_bmed = true
                    break
                end
            end
            
            if is_cur then
                local bw, bh = self.S(28), self.S(46)
                local bx = rect.x + rect.w - bw - self.S(16) - border
                local by = rect.y + border
                self._center_bm_touch_dimen = Geom:new{ x = bx - self.S(10), y = by, w = bw + self.S(20), h = bh + self.S(20) }
            end
            
            if is_bmed then
                local bw, bh = self.S(28), self.S(46)
                local bx = rect.x + rect.w - bw - self.S(16) - border
                local by = rect.y + border
                
                local mask_x = bx - self.S(2)
                local mask_y = by
                local mask_w = (rect.x + rect.w - border) - mask_x
                local mask_h = self.S(26)
                
                bb:paintRect(mask_x, mask_y, mask_w, mask_h, Blitbuffer.COLOR_WHITE)
                drawBookmarkRibbon(bb, bx, by, bw, bh, Blitbuffer.COLOR_BLACK)
            end

            bb:paintBorder(rect.x, rect.y, rect.w, rect.h, border, Blitbuffer.COLOR_BLACK, 0)
        end
    end
end

function PageScrubber:_paintSplitView(bb, title_strip_y, title_strip_h)
    local gd = self._grid_dimen
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local S = self.S
    
    bb:paintRect(gd.x, gd.y, gd.w, gd.h, Blitbuffer.COLOR_WHITE)
    
    local shadow_offset = S(4)
    local box_radius = S(12)
    local font_sz_chiquito = S(15) 
    local S_MEDIANO = S(17) 
    
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

    local tab_sp = S(6)
    local current_tab_x = pr_x
    local r = math.floor(tab_h / 2)

    local active_sort_icon = (self._sort_order == "asc") and self.icon_sort_asc or self.icon_sort_desc
    local sort_tsz = active_sort_icon and active_sort_icon:getSize() or {w = S(18), h = S(18)}
    local sort_tab_w = sort_tsz.w + S(16)

    paintRoundRect(bb, current_tab_x, tab_draw_y, sort_tab_w, tab_h, r, Blitbuffer.COLOR_BLACK)
    paintRoundRect(bb, current_tab_x + S(1), tab_draw_y + S(1), sort_tab_w - S(2), tab_h - S(2), math.max(1, r - S(1)), Blitbuffer.COLOR_WHITE)

    local stx = current_tab_x + math.floor((sort_tab_w - sort_tsz.w) / 2)
    local sty = tab_draw_y + math.floor((tab_h - sort_tsz.h) / 2)

    if active_sort_icon then
        active_sort_icon:paintTo(bb, stx, sty)
    end

    self._tab_sort_dimen = Geom:new{ x = current_tab_x, y = tab_draw_y, w = sort_tab_w, h = tab_h }
    current_tab_x = current_tab_x + sort_tab_w + tab_sp

    local function drawTabWithSVG(id, icon_widget, count_num)
        local is_active = (self._active_tab == id)

        local tw_cnt = TextWidget:new{ text = "(" .. tostring(count_num) .. ")", face = Font:getFace("cfont", S(15)), bold = is_active, fgcolor = Blitbuffer.COLOR_BLACK }
        
        local isz = icon_widget and icon_widget:getSize() or {w = S(18), h = S(18)}
        local csz = tw_cnt:getSize()
        local gap = S(4)
        local content_w = isz.w + gap + csz.w
        local tab_w = content_w + S(16)

        if is_active then
            paintRoundRect(bb, current_tab_x, tab_draw_y, tab_w, tab_h, r, Blitbuffer.COLOR_BLACK)
            paintRoundRect(bb, current_tab_x + S(3), tab_draw_y + S(3), tab_w - S(6), tab_h - S(6), math.max(1, r - S(3)), Blitbuffer.COLOR_WHITE)
        else
            paintRoundRect(bb, current_tab_x, tab_draw_y, tab_w, tab_h, r, Blitbuffer.COLOR_BLACK)
            paintRoundRect(bb, current_tab_x + S(1), tab_draw_y + S(1), tab_w - S(2), tab_h - S(2), math.max(1, r - S(1)), Blitbuffer.COLOR_WHITE)
        end

        local ix = current_tab_x + math.floor((tab_w - content_w) / 2)
        local cx = ix + isz.w + gap
        local iy = tab_draw_y + math.floor((tab_h - isz.h) / 2)
        local cy = tab_draw_y + math.floor((tab_h - csz.h) / 2) - S(1)

        if icon_widget then
            icon_widget:paintTo(bb, ix, iy)
        end

        tw_cnt:paintTo(bb, cx, cy)
        tw_cnt:free()

        local dimen = Geom:new{ x = current_tab_x, y = tab_draw_y, w = tab_w, h = tab_h }
        current_tab_x = current_tab_x + tab_w + tab_sp 
        return dimen
    end
    
    self._tab_bm_dimen   = drawTabWithSVG("bookmarks", self.icon_tab_bm, bm_count)
    self._tab_hl_dimen   = drawTabWithSVG("highlights", self.icon_tab_hl, hl_count)
    self._tab_note_dimen = drawTabWithSVG("notes", self.icon_tab_note, note_count)

    local card_x = pr_x
    local card_y = pr_y
    local card_w = pr_w
    local card_h = pr_h + status_h
    
    paintTopSquareBottomRounded(bb, card_x + shadow_offset, card_y, card_w, card_h, box_radius, Blitbuffer.COLOR_DARK_GRAY)
    paintTopSquareBottomRounded(bb, card_x, card_y, card_w, card_h, box_radius, Blitbuffer.COLOR_BLACK)
    local b_thick = S(3) 
    paintTopSquareBottomRounded(bb, card_x + b_thick, card_y + b_thick, card_w - b_thick*2, card_h - b_thick*2, math.max(1, box_radius - b_thick), Blitbuffer.COLOR_WHITE)

    local tile = self._grid_tiles[2] or {}
    if tile.tile_bb then
        local target_w = pr_w - b_thick*2
        local target_h = pr_h - b_thick
        local tw, th = tile.tile_bb:getWidth(), tile.tile_bb:getHeight()

        local render_bb = tile.tile_bb
        local must_free_render_bb = false
        if math.abs(tw - target_w) > 6 or math.abs(th - target_h) > 6 then
            local ok, sc = pcall(function() return tile.tile_bb:scale(target_w, target_h) end)
            if ok and sc then
                render_bb = sc
                must_free_render_bb = true
                tw, th = render_bb:getWidth(), render_bb:getHeight()
            end
        end

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
            bb:blitFrom(render_bb, ox, oy, src_x, src_y, blit_w, blit_h)
        end

        if must_free_render_bb then
            pcall(function() render_bb:free() end)
        end
    elseif tile.error then
        local err_tw = TextWidget:new{ text = "!", face = Font:getFace("cfont", S(32)), fgcolor = Blitbuffer.COLOR_BLACK }
        local etsz = err_tw:getSize()
        err_tw:paintTo(bb, card_x + math.floor((card_w - etsz.w) / 2), card_y + math.floor((pr_h - etsz.h) / 2))
        err_tw:free()
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

    if self._active_tab == "highlights" then
        active_pol_icon = self.icon_pol_hl
        if self._hl_filter and pd and pd.texts_by_type and pd.texts_by_type[self._hl_filter] then
            text_str = "“" .. safe_string(pd.texts_by_type[self._hl_filter], 500) .. "”"
        elseif pd and pd.text then
            text_str = "“" .. safe_string(pd.text, 500) .. "”"
        end
    elseif self._active_tab == "notes" then
        active_pol_icon = self.icon_pol_note
        if pd and pd.note then text_str = safe_string(pd.note, 500) end
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
                            local p = tonumber(v.pageno) or tonumber(v.page) or tonumber(v.pos0)
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
        
        raw_date = find_deep_date()
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
                    local months = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
                    text_str = "Added on " .. (months[tonumber(m)] or m) .. " " .. tonumber(d) .. ", " .. y
                else
                    text_str = "Added on " .. tostring(raw_date)
                end
            else
                text_str = "Bookmarked"
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
    local tw_st = TextWidget:new{ text = clean_str, face = Font:getFace("cfont", font_sz_chiquito), bold = true, fgcolor = Blitbuffer.COLOR_BLACK, max_width = text_max_w, truncate_with_ellipsis = true }
    local tsz = tw_st:getSize()
    local ty = card_y + pr_h + math.floor((status_h - tsz.h) / 2)
    
    tw_st:paintTo(bb, tx, ty)
    tw_st:free()

    self._btn_delete_dimen = nil
    self._btn_confirm_del_dimen = nil
    self._btn_edit_dimen = nil
    self._btn_type_dimen = nil
    self._type_picker_dimens = nil

    local show_delete_btn = false
    
    if not self._is_comic then
        local pd_edit = self._page_data[self._cur_page]
        if self._active_tab == "notes" then
            if pd_edit and pd_edit.note and pd_edit.note ~= "" then show_delete_btn = true end
        elseif self._active_tab == "highlights" then
            if pd_edit and pd_edit.text and pd_edit.text ~= "" then
                if self._hl_filter then
                    if pd_edit.hl_types and pd_edit.hl_types[self._hl_filter] then show_delete_btn = true end
                else
                    show_delete_btn = true
                end
            end
        end
    end

    if show_delete_btn and not self._hide_action_buttons then
        local bw, bh = S(48), S(48)
        local btn_x = card_x + pr_w - bw - S(20)
        local btn_y = card_y + pr_h - bh - S(76)

        paintRoundRect(bb, btn_x + S(3), btn_y + S(3), bw, bh, S(12), Blitbuffer.COLOR_DARK_GRAY)
        paintRoundRect(bb, btn_x, btn_y, bw, bh, S(12), Blitbuffer.COLOR_WHITE)
        paintRoundRect(bb, btn_x+S(2), btn_y+S(2), bw-S(4), bh-S(4), S(10), Blitbuffer.COLOR_BLACK)
        paintRoundRect(bb, btn_x+S(4), btn_y+S(4), bw-S(8), bh-S(8), S(8), Blitbuffer.COLOR_WHITE)

        if self.icon_btn_trash then
            local isz_btn = self.icon_btn_trash:getSize()
            local bix = btn_x + math.floor((bw - isz_btn.w)/2)
            local biy = btn_y + math.floor((bh - isz_btn.h)/2)
            self.icon_btn_trash:paintTo(bb, bix, biy)
        end

        self._btn_delete_dimen = Geom:new{ x = btn_x, y = btn_y, w = bw, h = bh }

        local ebw, ebh = bw, bh
        local edit_gap = S(10)
        local ebtn_x = btn_x
        local ebtn_y = btn_y - ebh - edit_gap

        paintRoundRect(bb, ebtn_x + S(3), ebtn_y + S(3), ebw, ebh, S(12), Blitbuffer.COLOR_DARK_GRAY)
        paintRoundRect(bb, ebtn_x, ebtn_y, ebw, ebh, S(12), Blitbuffer.COLOR_WHITE)
        paintRoundRect(bb, ebtn_x+S(2), ebtn_y+S(2), ebw-S(4), ebh-S(4), S(10), Blitbuffer.COLOR_BLACK)
        paintRoundRect(bb, ebtn_x+S(4), ebtn_y+S(4), ebw-S(8), ebh-S(8), S(8), Blitbuffer.COLOR_WHITE)

        if self.icon_btn_edit then
            local isz_edit = self.icon_btn_edit:getSize()
            local eix = ebtn_x + math.floor((ebw - isz_edit.w)/2)
            local eiy = ebtn_y + math.floor((ebh - isz_edit.h)/2)
            self.icon_btn_edit:paintTo(bb, eix, eiy)
        end

        self._btn_edit_dimen = Geom:new{ x = ebtn_x, y = ebtn_y, w = ebw, h = ebh }

        local tbw, tbh = bw, bh
        local tbtn_x = btn_x
        local tbtn_y = ebtn_y - tbh - edit_gap

        paintRoundRect(bb, tbtn_x + S(3), tbtn_y + S(3), tbw, tbh, S(12), Blitbuffer.COLOR_DARK_GRAY)
        paintRoundRect(bb, tbtn_x, tbtn_y, tbw, tbh, S(12), Blitbuffer.COLOR_WHITE)
        paintRoundRect(bb, tbtn_x+S(2), tbtn_y+S(2), tbw-S(4), tbh-S(4), S(10), Blitbuffer.COLOR_BLACK)
        paintRoundRect(bb, tbtn_x+S(4), tbtn_y+S(4), tbw-S(8), tbh-S(8), S(8), Blitbuffer.COLOR_WHITE)

        if self.icon_btn_type then
            local isz_type = self.icon_btn_type:getSize()
            local tix = tbtn_x + math.floor((tbw - isz_type.w)/2)
            local tiy = tbtn_y + math.floor((tbh - isz_type.h)/2)
            self.icon_btn_type:paintTo(bb, tix, tiy)
        end

        self._btn_type_dimen = Geom:new{ x = tbtn_x, y = tbtn_y, w = tbw, h = tbh }

        if self._show_delete_confirm then
            local cw = card_w - S(40)
            local ch = S(56)
            local cx = card_x + S(20)
            local cy = card_y + pr_h - ch - S(10)

            paintRoundRect(bb, cx + S(4), cy + S(4), cw, ch, S(14), Blitbuffer.COLOR_DARK_GRAY)
            paintRoundRect(bb, cx, cy, cw, ch, S(14), Blitbuffer.COLOR_BLACK)
            paintRoundRect(bb, cx + S(2), cy + S(2), cw - S(4), ch - S(4), S(12), Blitbuffer.COLOR_WHITE)
            paintRoundRect(bb, cx + S(4), cy + S(4), cw - S(8), ch - S(8), S(10), Blitbuffer.COLOR_BLACK)

            local ctw = TextWidget:new{ text = "Delete", face = Font:getFace("cfont", S(17)), bold = true, fgcolor = Blitbuffer.COLOR_WHITE }
            local ctsz = ctw:getSize()
            ctw:paintTo(bb, cx + math.floor((cw - ctsz.w)/2), cy + math.floor((ch - ctsz.h)/2))
            ctw:free()

            self._btn_confirm_del_dimen = Geom:new{ x = cx, y = cy, w = cw, h = ch }
        end

        if self._show_type_picker then
            local cw = card_w - S(40)
            local ch = S(56)
            local cx = card_x + S(20)
            local cy = card_y + pr_h - ch - S(10)

            paintRoundRect(bb, cx + S(4), cy + S(4), cw, ch, S(14), Blitbuffer.COLOR_DARK_GRAY)
            paintRoundRect(bb, cx, cy, cw, ch, S(14), Blitbuffer.COLOR_WHITE)
            paintRoundRect(bb, cx+S(2), cy+S(2), cw-S(4), ch-S(4), S(12), Blitbuffer.COLOR_BLACK)
            paintRoundRect(bb, cx+S(4), cy+S(4), cw-S(8), ch-S(8), S(10), Blitbuffer.COLOR_WHITE)

            local current_drawer = "lighten"
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

            local type_defs = {
                { key = "lighten",    icon = self.icon_picker_hl },
                { key = "underscore", icon = self.icon_picker_ul },
                { key = "strikeout",  icon = self.icon_picker_st },
                { key = "invert",     icon = self.icon_picker_inv },
            }
            local slot_w = math.floor((cw - S(8)) / #type_defs)

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
        end
    end

    local fixed_page = self._split_fixed_page or self._origin_page
    local fx_w = lm_w
    local is_f_sel = (self._cur_page == fixed_page)
    local fg_f = is_f_sel and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK

    local is_page_bmed = false
    for _, b in ipairs(self:_getAllBookmarks()) do
        if tonumber(b) == tonumber(fixed_page) then is_page_bmed = true end
    end

    paintRoundRect(bb, lm_x + shadow_offset, fx_y, lm_w, fx_h, box_radius, Blitbuffer.COLOR_DARK_GRAY)
    paintRoundRect(bb, lm_x, fx_y, lm_w, fx_h, box_radius, Blitbuffer.COLOR_BLACK)
    paintRoundRect(bb, lm_x + S(2), fx_y + S(2), lm_w - S(4), fx_h - S(4), math.max(1, box_radius - S(2)), Blitbuffer.COLOR_WHITE)

    if is_f_sel then
        paintRoundRect(bb, lm_x + S(4), fx_y + S(4), lm_w - S(8), fx_h - S(8), S(8), Blitbuffer.COLOR_BLACK)
    end
    
    local active_fixed_icon = is_page_bmed and self.icon_box_minus_fill or self.icon_box_plus
    local bsz_f = active_fixed_icon and active_fixed_icon:getSize() or {w = S(22), h = S(22)}
    local btn_xf = lm_x + lm_w - bsz_f.w - S(12)
    
    local tw_pg_f = TextWidget:new{ text = tostring(fixed_page), face = Font:getFace("cfont", S_MEDIANO), bold = is_f_sel, fgcolor = fg_f }
    local pt_sz = tw_pg_f:getSize()
    local ptx = lm_x + S(15) 
    local pty = fx_y + math.floor((fx_h - pt_sz.h) / 2) + S(2)
    
    tw_pg_f:paintTo(bb, ptx, pty)
    tw_pg_f:free()

    if active_fixed_icon then
        local ix = btn_xf
        local iy = fx_y + math.floor((fx_h - bsz_f.h)/2)
        
        if is_f_sel then
            bb:paintRect(ix, iy, bsz_f.w, bsz_f.h, Blitbuffer.COLOR_WHITE)
            active_fixed_icon:paintTo(bb, ix, iy)
            bb:invertRect(ix, iy, bsz_f.w, bsz_f.h)
        else
            active_fixed_icon:paintTo(bb, ix, iy)
        end
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
    if self._active_tab == "highlights" then
        for _, fd in ipairs(filter_defs) do
            if self._hl_types_present[fd.key] then table.insert(present_filters, fd) end
        end
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

    if self._force_menu_sync then
        local target_idx = nil
        for i, p in ipairs(other_items) do
            if tonumber(p) == tonumber(self._cur_page) then
                target_idx = i; break
            end
        end
        if target_idx then
            self._split_bm_page = math.ceil(target_idx / ITEMS_PER_PAGE)
        end
        self._force_menu_sync = false
    end
    
    local total_pages = math.max(1, math.ceil(#other_items / ITEMS_PER_PAGE))
    local cur_page = self._split_bm_page or 1
    if cur_page > total_pages then cur_page = total_pages end
    if cur_page < 1 then cur_page = 1 end
    self._split_bm_page = cur_page
    
    local start_idx, end_idx = 1, 0
    if #other_items > 0 then
        start_idx = (cur_page - 1) * ITEMS_PER_PAGE + 1
        end_idx = math.min(cur_page * ITEMS_PER_PAGE, #other_items)
    end

    self._split_rows = {}

    paintRoundRect(bb, lm_x + shadow_offset, menu_y, lm_w, exact_menu_h, box_radius, Blitbuffer.COLOR_DARK_GRAY)
    paintRoundRect(bb, lm_x, menu_y, lm_w, exact_menu_h, box_radius, Blitbuffer.COLOR_BLACK)
    paintRoundRect(bb, lm_x + S(2), menu_y + S(2), lm_w - S(4), exact_menu_h - S(4), math.max(1, box_radius - S(2)), Blitbuffer.COLOR_WHITE)

    bb:paintRect(lm_x + S(2), menu_y + header_h - S(1), lm_w - S(4), S(1), Blitbuffer.COLOR_BLACK)

    local tw_hdr = TextWidget:new{ text = "Pag", face = Font:getFace("cfont", font_sz_chiquito), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
    local hsz = tw_hdr:getSize()
    local htx = lm_x + S(15)
    local hty = menu_y + S(2) + math.floor((header_h - S(2) - hsz.h) / 2)

    tw_hdr:paintTo(bb, htx, hty)
    tw_hdr:free()

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
            local is_active = (self._hl_filter == fd.key)
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
        local n_tw = TextWidget:new{ text = "—", face = Font:getFace("cfont", S_MEDIANO), fgcolor = Blitbuffer.COLOR_DARK_GRAY }
        local n_sz = n_tw:getSize()
        n_tw:paintTo(bb, lm_x + math.floor((lm_w - n_sz.w)/2), list_y + math.floor((list_h - n_sz.h)/2))
        n_tw:free()
    else
        local row_y_float = list_y
        for i = start_idx, end_idx do
            local current_row_y = math.floor(row_y_float)
            local p = other_items[i]
            local is_r_sel = (self._cur_page == p)
            local fg_r = is_r_sel and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    
            if is_r_sel then
                paintRoundRect(bb, lm_x + S(4), current_row_y + S(4), lm_w - S(8), row_h - S(8), S(8), Blitbuffer.COLOR_BLACK)
            end
            
            if not is_r_sel and i < end_idx then
                bb:paintRect(lm_x + S(15), current_row_y + row_h - 1, lm_w - S(30), 1, Blitbuffer.COLOR_GRAY)
            end
            
            local active_row_icon = (self._active_tab == "bookmarks") and self.icon_box_minus or self.icon_box_arrow
            local rm_sz = active_row_icon and active_row_icon:getSize() or {w = S(22), h = S(22)}
            local rm_x = lm_x + lm_w - rm_sz.w - S(12)
            
            if active_row_icon then
                local ix = rm_x
                local iy = current_row_y + math.floor((row_h - rm_sz.h)/2)
                local is_btn_pressed = (self._pressed_btn == "row_toggle_" .. p)
                
                if is_btn_pressed then
                    local pad = S(6)
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
            local tw_pg = TextWidget:new{ text = tostring(p), face = Font:getFace("cfont", S_MEDIANO), bold = is_r_sel, fgcolor = fg_r, max_width = text_max_w_menu }
            local tw_pg_sz = tw_pg:getSize()
            local pg_x = lm_x + S(15)
            local pg_y = current_row_y + math.floor((row_h - tw_pg_sz.h) / 2) + S(2) - 1
            
            tw_pg:paintTo(bb, pg_x, pg_y)
            tw_pg:free()
            
            local t_dim = Geom:new{ x = rm_x - S(10), y = current_row_y, w = rm_sz.w + S(20), h = row_h }
            local dyn_clickable_w = (rm_x - S(10)) - lm_x
            local r_dim = Geom:new{ x = lm_x, y = current_row_y, w = dyn_clickable_w, h = row_h }
            
            table.insert(self._split_rows, { dimen = r_dim, toggle_dimen = t_dim, page = p })
            row_y_float = row_y_float + row_h
        end
        
        self._split_prev_dimen = nil
        self._split_next_dimen = nil
        
        if needs_pagination then
            local pag_h = row_h
            local pag_y = list_y + (num_rows - 1) * row_h
            
            bb:paintRect(lm_x + S(15), pag_y, lm_w - S(30), S(1), Blitbuffer.COLOR_GRAY)
            
            local pag_str = cur_page .. " / " .. total_pages
            local pag_tw = TextWidget:new{ text = pag_str, face = Font:getFace("cfont", S(15)), fgcolor = Blitbuffer.COLOR_DARK_GRAY }
            local pag_sz = pag_tw:getSize()
            
            local text_y = pag_y + math.floor((pag_h - pag_sz.h)/2) + S(2)
            pag_tw:paintTo(bb, lm_x + math.floor((lm_w - pag_sz.w)/2), text_y)
            pag_tw:free()
            
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
end

function PageScrubber:_paintBackLabel(bb)
    self._grid_back_dimen = nil
    local BACK_LABEL_THRESHOLD = 10
    if math.abs(self._cur_page - self._origin_page) < BACK_LABEL_THRESHOLD then return end

    local S = self.S
    local ahead = self._cur_page > self._origin_page
    local arrow_char = ahead and "\u{F104}" or "\u{F105}"

    if not self._tw_grid_back_icon then
        self._tw_grid_back_icon = TextWidget:new{
            text = arrow_char, face = Font:getFace("cfont", S(13)),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
    else
        self._tw_grid_back_icon:setText(arrow_char)
    end

    local label_text = "Pag " .. self._origin_page
    if not self._tw_grid_back then
        self._tw_grid_back = TextWidget:new{
            text = label_text, face = Font:getFace("cfont", S(13)),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
    else
        self._tw_grid_back:setText(label_text)
    end

    local isz = self._tw_grid_back_icon:getSize()
    local tsz = self._tw_grid_back:getSize()
    local gap = S(10)
    local pad_x, pad_y = S(12), S(8)

    local content_h = math.max(isz.h, tsz.h)
    local lbl_w = pad_x * 2 + isz.w + gap + tsz.w
    
    local text_y_shift = ahead and S(4) or S(1)
    local group_y_shift = ahead and 0 or S(3)
    local icon_y = self.ctrl_y_pos + math.floor((self._ctrl_row_h - isz.h) / 2) - group_y_shift
    local text_y = self.ctrl_y_pos + math.floor((self._ctrl_row_h - tsz.h) / 2) - text_y_shift - group_y_shift

    local lbl_x
    if ahead then
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
    else
        self._tw_grid_back_icon.fgcolor = Blitbuffer.COLOR_DARK_GRAY
        self._tw_grid_back.fgcolor = Blitbuffer.COLOR_DARK_GRAY
    end

    if ahead then
        self._tw_grid_back_icon:paintTo(bb, lbl_x + pad_x, icon_y)
        self._tw_grid_back:paintTo(bb, lbl_x + pad_x + isz.w + gap, text_y)
    else
        self._tw_grid_back:paintTo(bb, lbl_x + pad_x, text_y)
        self._tw_grid_back_icon:paintTo(bb, lbl_x + pad_x + tsz.w + gap, icon_y)
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

    self:_waitForIdle(function()
        if self._nav_token == my_token then
            self.ui:handleEvent(Event:new("GotoPage", target_page))
        end
    end)

    if not self._grid_disabled then self:_updateGridPages() end
    UIManager:setDirty(self, "ui", self.dimen)
end

function PageScrubber:_previewPage(page, is_dragging)
    if self._closing then return end
    self._cur_page = math.max(1, math.min(self._total_pages, page))
    self._hide_action_buttons = false
    self._slider.value = self._cur_page
    self:_updateTexts()

    UIManager:setDirty(self, "ui", self.dimen)

    if self._is_busy then
        self._pending_grid_update = true
        return
    end

    if not self._grid_disabled then self:_updateGridPages() end
end

function PageScrubber:_reopenWithMode(new_mode, target_page)
    if self._closing then return end
    self._closing = true
    self:_cancelHold()
    
    local ui = self.ui
    local origin = self._origin_page
    local scale = self.ui_scale or 1.0
    local tab = self._active_tab
    local is_trans = (new_mode == "grid_simple")
    local base_md = self._base_grid_mode

    UIManager:close(self)
    UIManager:setDirty(nil, "full")
    
    if new_mode == "grid_simple" then
        UIManager:scheduleIn(0.05, function()
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
    else
        UIManager:nextTick(function()
            local ScrubberUI = require("scrubber_ui")
            local new_widget = ScrubberUI:new{
                ui = ui,
                document = ui.document,
                initial_view_mode = new_mode,
                initial_tab = tab,
                transparent_bg = false,
                ui_scale = scale,
                initial_origin = origin,
                initial_page = target_page,
                base_mode = base_md,
            }
            UIManager:show(new_widget)
        end)
    end
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
    UIManager:setDirty(self, "ui", rect)
    UIManager:scheduleIn(0.05, function()
        self._pressed_btn = nil
        action_func()
    end)
end

function PageScrubber:_openNoteTextEditor()
    local target_page = self._cur_page
    local target_item = nil
    if self.ui.annotation and self.ui.annotation.annotations then
        for _, item in ipairs(self.ui.annotation.annotations) do
            if math.floor(self:_getNumericalPage(item) or 0) == target_page then
                target_item = item; break
            end
        end
    end

    if not target_item then return end

    local dialog
    dialog = InputDialog:new{
        title = _("Edit note"),
        input = target_item.note or "",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        target_item.note = dialog:getInputText()
                        pcall(function()
                            if self.ui.annotation and self.ui.annotation.saveAnnotations then
                                self.ui.annotation:saveAnnotations()
                            end
                        end)
                        self:_extractAnnotations()
                        UIManager:setDirty(self, "ui", self.dimen)
                        UIManager:close(dialog)
                    end
                }
            }
        }
    }
    UIManager:show(dialog)
end

function PageScrubber:_setHighlightType(new_drawer)
    local target_page = self._cur_page
    local target_item = nil
    local current_filter = self._hl_filter

    if self.ui.annotation and self.ui.annotation.annotations then
        -- Priorizar el highlight que coincida con el filtro de tipo activo
        for _, item in ipairs(self.ui.annotation.annotations) do
            local p = self:_getNumericalPage(item)
            if p and math.floor(p) == target_page and item.text and item.text ~= "" then
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

        -- Fallback si no hubo coincidencia por filtro
        if not target_item then
            for _, item in ipairs(self.ui.annotation.annotations) do
                local p = self:_getNumericalPage(item)
                if p and math.floor(p) == target_page and item.text and item.text ~= "" then
                    target_item = item
                    break
                end
            end
        end
    end

    if not target_item then return end

    -- 1. Actualizar el estilo (drawer) en la anotación
    target_item.drawer = new_drawer

    -- 2. Guardar en el archivo .sdr del libro
    pcall(function()
        if self.ui.annotation and self.ui.annotation.saveAnnotations then
            self.ui.annotation:saveAnnotations()
        end
    end)

    -- 3. Calcular el nuevo filtro para que coincida con el nuevo tipo
    local new_filt = "normal"
    if new_drawer == "invert" then new_filt = "invert"
    elseif new_drawer == "underscore" then new_filt = "underline"
    elseif new_drawer == "strikeout" then new_filt = "strikethrough" end
    local next_hl_filter = current_filter and new_filt or nil

    -- 4. Mostrar pantalla de carga
    local loading_widget = InfoMessage:new{ text = _("Updating highlight…") }
    UIManager:show(loading_widget)

    -- 5. Guardar el estado completo en el Bridge para restaurar exactamente la vista
    pcall(function()
        local Bridge = require("page_scrubber_bridge")
        Bridge.requestReopenAfterReload{
            mode       = "split",
            tab        = self._active_tab or "highlights",
            page       = self._cur_page,
            origin     = self._origin_page,
            fixed_page = self._split_fixed_page,
            base_mode  = self._base_grid_mode,
            sort_order = self._sort_order,
            bm_page    = self._split_bm_page,
            hl_filter  = next_hl_filter,
        }
        Bridge.setLoadingWidget(loading_widget)
    end)

    -- Timeout de seguridad
    UIManager:scheduleIn(10, function()
        pcall(function()
            local Bridge = require("page_scrubber_bridge")
            Bridge.closeLoadingWidget()
        end)
    end)

    -- 6. Cerrar el scrubber y forzar el reload del motor crengine para que redibuje con el nuevo drawer
    self._closing = true
    self:_cancelHold()
    UIManager:close(self)
    UIManager:scheduleIn(0.02, function()
        pcall(function() self.ui:reloadDocument(nil, true) end)
    end)
end

function PageScrubber:paintTo(bb, x, y)
    if self._closing then return end
    local ok, err = pcall(function() self:_paintToImpl(bb, x, y) end)
    if not ok then logger.warn("page-scrubber paintTo error:", err) end
end

function PageScrubber:_paintToImpl(bb, x, y)

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local S  = self.S
    local pad = S(16)
    local bd = self._bar_dimen
    local td = self._top_bar_dimen

    if not self.transparent_bg then
        bb:paintRect(0, 0, sw, sh, Blitbuffer.COLOR_WHITE)
    end

    bb:paintRect(bd.x, bd.y, bd.w, bd.h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(bd.x, bd.y, bd.w, S(3), Blitbuffer.COLOR_BLACK)

    if self._view_mode == "grid_simple" then
        local ok, GridSimpleView = pcall(require, "grid_simple_view")
        if ok and GridSimpleView then
            GridSimpleView.paint(self, bb)
        end
    else
        local title_strip_y = td.y + td.h
        local grid_y = self._grid_dimen and self._grid_dimen.y or title_strip_y
        local title_strip_h = math.max(0, grid_y - title_strip_y)
        
        if title_strip_h > 0 then
            bb:paintRect(0, title_strip_y, sw, title_strip_h, Blitbuffer.COLOR_WHITE)
        end

        local tab_border = S(3)
        local tab_radius = S(38) 
        local shadow_offset = S(4) 
        
        paintBottomRoundedTab(bb, td.x, td.y + shadow_offset, td.w, td.h, tab_radius, Blitbuffer.COLOR_DARK_GRAY)
        paintBottomRoundedTab(bb, td.x, td.y, td.w, td.h, tab_radius, Blitbuffer.COLOR_BLACK)
        paintBottomRoundedTab(bb, td.x + tab_border, td.y, td.w - (tab_border * 2), td.h - tab_border, math.max(1, tab_radius - tab_border), Blitbuffer.COLOR_WHITE)
        
        if self._view_mode == "grid" or self._view_mode == "grid_six" then
            if self._view_mode ~= "grid_six" then
                local title_x = pad
                self.tw_booktitle:paintTo(bb, title_x, self._booktitle_y)
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
            local is_pressed = (self._pressed_btn == btn_id)
            
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
        self.tw_lib_label.fgcolor = (self._pressed_btn == "lib") and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        self.tw_lib_label:paintTo(bb, self._lib_label_x, self._lib_label_y)

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
        if is_disabled then return end
        
        local cx = dimen.x + math.floor(dimen.w / 2)
        local cy = dimen.y + math.floor(dimen.h / 2)
        
        local tsz = tw:getSize()
        local y_offset = 0
        if tw.text and type(tw.text) == "string" then
            if tw.text == "\u{F097}" or tw.text == "\u{F02E}" then y_offset = S(1)
            elseif tw.text == "\u{EBAD}" or tw.text == "\u{EBAC}" then y_offset = -S(1)
            elseif tw.text == "\u{F0D9}" or tw.text == "\u{F0DA}" then y_offset = -S(2) end
        end
        if btn_id == "ctrl_mark" then y_offset = -S(1) - 1 end

        local draw_x = cx - math.floor(tsz.w / 2)
        local draw_y = cy - math.floor(tsz.h / 2) + y_offset

        tw:paintTo(bb, draw_x, draw_y)
    end

    drawFloatingBtnBottom("ch_l", self._prev_ch_dimen, self.tw_ch_l, not can_prev_ch)
    drawFloatingBtnBottom("ch_r", self._next_ch_dimen, self.tw_ch_r, not can_next_ch)

    if self._view_mode == "grid_six" then
        local btn_w = S(50)
        local mark_sz = S(36)
        if not self._gsix_prev_dimen then
            self._gsix_prev_dimen = Geom:new{ x = pad * 2, y = self.ctrl_y_pos, w = btn_w, h = mark_sz }
            self._gsix_next_dimen = Geom:new{ x = sw - pad * 2 - btn_w, y = self.ctrl_y_pos, w = btn_w, h = mark_sz }
        end
        
        drawFloatingBtnBottom("gsix_prev", self._gsix_prev_dimen, self.icon_gs_chevron_left, self._cur_page <= 1)
        drawFloatingBtnBottom("gsix_next", self._gsix_next_dimen, self.icon_gs_chevron_right, self._cur_page >= self._total_pages)

        if self._cur_page ~= self._origin_page then
            if not self._tw_gsix_origin then
                self._tw_gsix_origin = TextWidget:new{ text = "Pag " .. self._origin_page, face = Font:getFace("cfont", S(16)), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
            else
                self._tw_gsix_origin:setText("Pag " .. self._origin_page)
            end
            
            local csz = self._tw_gsix_origin:getSize()
            local cx = math.floor(sw / 2)
            local cy = self.ctrl_y_pos + math.floor(mark_sz / 2)
            
            self._gsix_origin_dimen = Geom:new{ x = cx - math.floor(csz.w/2) - S(15), y = cy - math.floor(csz.h/2) - S(10), w = csz.w + S(30), h = csz.h + S(20) }

            local is_pressed = (self._pressed_btn == "gsix_origin")
            if is_pressed then
                paintRoundRect(bb, self._gsix_origin_dimen.x, self._gsix_origin_dimen.y, self._gsix_origin_dimen.w, self._gsix_origin_dimen.h, self.S(8), Blitbuffer.COLOR_BLACK)
                self._tw_gsix_origin.fgcolor = Blitbuffer.COLOR_WHITE
            else
                self._tw_gsix_origin.fgcolor = Blitbuffer.COLOR_BLACK
            end
            
            self._tw_gsix_origin:paintTo(bb, cx - math.floor(csz.w/2), cy - math.floor(csz.h/2))
        else
            self._gsix_origin_dimen = nil
        end
    else
        local is_marked = self:_isCurrentPageBookmarked(current_display)
        self.tw_ctrl_mark = is_marked and self.icon_mark_filled or self.icon_mark_empty

        local has_prev_bm = self:_findPrevBookmark() ~= nil
        local has_next_bm = self:_findNextBookmark() ~= nil

        drawFloatingBtnBottom("ctrl_prev", self._ctrl_prev_dimen, self.tw_ctrl_prev, not has_prev_bm)
        drawFloatingBtnBottom("ctrl_mark", self._ctrl_mark_dimen, self.tw_ctrl_mark, false)
        drawFloatingBtnBottom("ctrl_next", self._ctrl_next_dimen, self.tw_ctrl_next, not has_next_bm)
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
        local btn_center_y = self._prev_ch_dimen.y + math.floor(self._prev_ch_dimen.h / 2)
        local new_ch_y = btn_center_y - math.floor(csz_tw.h / 2)

        self.tw_chapter:paintTo(bb, ctx, new_ch_y)

        local new_info_y
        if self._gs_panel_dimen then
            local card_bottom = self._gs_panel_dimen.y + self._gs_panel_dimen.h
            new_info_y = card_bottom - isz.h - S(2)
        else
            new_info_y = self._bar_dimen.y - isz.h - S(40)
        end
        
        self.tw_info:paintTo(bb, infox, new_info_y)
    else
        self.tw_chapter:paintTo(bb, ctx, self.ch_y_pos)
        self.tw_info:paintTo(bb, infox, self.info_y_pos)
    end

    local slider_x = pad * 2
    self._slider.value = current_display
    
    if self._view_mode == "grid_simple" then
        local slider_h = self._slider:getSize().h
        local espacio_arriba = self._prev_ch_dimen.y + self._prev_ch_dimen.h
        local espacio_abajo = self.ctrl_y_pos
        local nuevo_slider_y = espacio_arriba + math.floor((espacio_abajo - espacio_arriba - slider_h) / 2)
        
        self._slider:paintTo(bb, slider_x, nuevo_slider_y)
    else
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
    
    UIManager:nextTick(function()
        if self._cur_page ~= self._origin_page then
            self.ui:handleEvent(Event:new("GotoPage", self._origin_page))
        end
        UIManager:close(self)
        UIManager:setDirty(nil, "full")
    end)
end

function PageScrubber:_closeStay()
    if self._closing then return end
    self._closing = true
    self:_cancelHold()
    
    self._slider._dragging = false
    self._is_busy = false
    self._tasks_in_flight = 0
    self._grid_batch_seq = (self._grid_batch_seq or 0) + 1
    self._grid_batch_id = "safe_close_" .. tostring(os.time())
    
    UIManager:nextTick(function()
        UIManager:close(self)
        UIManager:setDirty(nil, "full")
    end)
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
    
    UIManager:close(self)
    UIManager:setDirty(nil, "full")
    UIManager:scheduleIn(0.15, function()
        pcall(function() self.ui:handleEvent(Event:new(event_name, event_data)) end)
    end)
end

function PageScrubber:_startHold(action)
    self._hold_active = true
    self._hold_token = self._hold_token + 1
    local current_token = self._hold_token
    
    local delay = 0.55
    local max_steps = 20
    local steps = 0

    local function rep()
        if not self._hold_active or self._closing or self._hold_token ~= current_token then 
            self:_cancelHold()
            return 
        end
        
        steps = steps + 1
        if steps > max_steps then
            self:_cancelHold()
            return
        end
        
        local target_page = self._cur_page
        local jump = (self._view_mode == "grid_six") and 6 or 1
        
        if action == "prev" then 
            if target_page > 1 then 
                self._force_menu_sync = true
                self:_previewPage(self._cur_page - jump, false) 
            else 
                self:_cancelHold(); return 
            end
        elseif action == "next" then 
            if target_page < self._total_pages then 
                self._force_menu_sync = true
                self:_previewPage(self._cur_page + jump, false) 
            else 
                self:_cancelHold(); return 
            end
        end
        
        UIManager:scheduleIn(delay, rep)
    end
    
    UIManager:scheduleIn(delay, rep)
end

function PageScrubber:_cancelHold()
    self._hold_active = false
    self._hold_token = self._hold_token + 1
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
    if self._closing then return true end
    
    if not self._anti_ghost_ready then
        return true 
    end

    if self._view_mode == "grid_six" then
        if self._gsix_prev_dimen and ges.pos:intersectWith(self._gsix_prev_dimen) then
            self:_flashAndDo("gsix_prev", self._gsix_prev_dimen, function()
                self._force_menu_sync = true
                self:_previewPage(self._cur_page - 6, false)
            end)
            return true
        end
        if self._gsix_next_dimen and ges.pos:intersectWith(self._gsix_next_dimen) then
            self:_flashAndDo("gsix_next", self._gsix_next_dimen, function()
                self._force_menu_sync = true
                self:_previewPage(self._cur_page + 6, false)
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
        
        local ok, GridSixView = pcall(require, "grid_six_view")
        if ok and GridSixView then
            if GridSixView.onTap(self, ges) then return true end
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
            self._force_menu_sync = true
            self:_previewPage(self._cur_page - 1, false)
            return true
        end
        if self._gs_next_dimen and ges.pos:intersectWith(self._gs_next_dimen) then
            self._force_menu_sync = true
            self:_previewPage(self._cur_page + 1, false)
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
                    self._view_mode = "grid"
                    self:_clearGridTiles()
                    self:_previewPage(self._cur_page, false)
                    UIManager:setDirty(nil, "full")
                else
                    self._view_mode = "split"
                    self._active_tab = "bookmarks"
                    self._split_fixed_page = self._cur_page
                    self._split_bm_page = self.initial_bm_page or 1
                    self._force_menu_sync = true
                    self:_clearGridTiles()
                    self:_previewPage(self._cur_page, false)
                    UIManager:setDirty(nil, "full")
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
                            for i = #an.annotations, 1, -1 do
                                local item = an.annotations[i]
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
                                        if item.drawer and hl and hl.deleteHighlight then
                                            hl:deleteHighlight(i)
                                        elseif bk and bk.removeItemByIndex then
                                            bk:removeItemByIndex(i)
                                        else
                                            table.remove(an.annotations, i)
                                        end
                                    end
                                end
                            end
                            if an.saveAnnotations then an:saveAnnotations() end
                        end
                    end)
                    if not ok then logger.warn("page-scrubber: safe delete failed:", err) end
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
            UIManager:setDirty(self, "ui", self.dimen)
            return true
        end

        if self._btn_type_dimen and ges.pos:intersectWith(self._btn_type_dimen) then
            self._show_type_picker = not self._show_type_picker
            self._show_delete_confirm = false
            UIManager:setDirty(self, "ui", self.dimen)
            return true
        end

        if self._btn_edit_dimen and ges.pos:intersectWith(self._btn_edit_dimen) then
            self:_openNoteTextEditor()
            return true
        end

        if self._show_delete_confirm then
            self._show_delete_confirm = false
            UIManager:setDirty(self, "ui", self.dimen)
        end

        if self._show_type_picker then
            self._show_type_picker = false
            UIManager:setDirty(self, "ui", self.dimen)
        end

        if self._tab_sort_dimen and ges.pos:intersectWith(self._tab_sort_dimen) then
            self._sort_order = (self._sort_order == "asc") and "desc" or "asc"
            self._split_bm_page = self.initial_bm_page or 1
            UIManager:setDirty(self, "ui", self.dimen)
            return true
        end

        if self._tab_hl_dimen and ges.pos:intersectWith(self._tab_hl_dimen) then
            self._active_tab = "highlights"
            self._hl_filter = self.initial_hl_filter or nil
            self._split_bm_page = self.initial_bm_page or 1
            self:_extractAnnotations()
            UIManager:setDirty(self, "ui", self.dimen)
            return true
        end

        if self._active_tab == "highlights" and self._hl_main_tab_dimen and ges.pos:intersectWith(self._hl_main_tab_dimen) then
            if self._hl_filter ~= nil then
                self._hl_filter = self.initial_hl_filter or nil
                self._split_bm_page = self.initial_bm_page or 1
                UIManager:setDirty(self, "ui", self.dimen)
                return true
            end
        end

        if self._active_tab == "highlights" and self._hl_filter_dimens then
            for _, f in ipairs(self._hl_filter_dimens) do
                if ges.pos:intersectWith(f.dimen) then
                    if self._hl_filter == f.key then self._hl_filter = self.initial_hl_filter or nil else self._hl_filter = f.key end
                    self._split_bm_page = self.initial_bm_page or 1
                    UIManager:setDirty(self, "ui", self.dimen)
                    return true
                end
            end
        end
        
        if self._tab_bm_dimen and ges.pos:intersectWith(self._tab_bm_dimen) then
            self._active_tab = "bookmarks"
            self._split_bm_page = self.initial_bm_page or 1
            self:_extractAnnotations()
            UIManager:setDirty(self, "ui", self.dimen)
            return true
        end

        if self._tab_note_dimen and ges.pos:intersectWith(self._tab_note_dimen) then
            self._active_tab = "notes"
            self._split_bm_page = self.initial_bm_page or 1
            self:_extractAnnotations()
            UIManager:setDirty(self, "ui", self.dimen)
            return true
        end
        
        if self._split_fixed_toggle_dimen and ges.pos:intersectWith(self._split_fixed_toggle_dimen) then
            local tgt = self._split_fixed_page or self._origin_page
            self:_safeBookmarkToggle(tgt)
            return true
        end
        
        if self._split_fixed_row_dimen and ges.pos:intersectWith(self._split_fixed_row_dimen) then
            local tgt_page = self._split_fixed_page or self._origin_page
            if self._cur_page == tgt_page then
                self._hide_action_buttons = not self._hide_action_buttons
                UIManager:setDirty(self, "ui", self.dimen)
            else
                self._force_menu_sync = true
                self:_previewPage(tgt_page, false)
            end
            return true
        end
        
        if self._split_prev_dimen and ges.pos:intersectWith(self._split_prev_dimen) then
            self:_flashAndDo("split_prev", self._split_prev_dimen, function()
                self._split_bm_page = math.max(1, (self._split_bm_page or 1) - 1)
                UIManager:setDirty(self, "ui", self.dimen)
            end)
            return true
        end
        if self._split_next_dimen and ges.pos:intersectWith(self._split_next_dimen) then
            self:_flashAndDo("split_next", self._split_next_dimen, function()
                self._split_bm_page = (self._split_bm_page or 1) + 1
                UIManager:setDirty(self, "ui", self.dimen)
            end)
            return true
        end
        
        if self._split_rows then
            for _, row in ipairs(self._split_rows) do
                if ges.pos:intersectWith(row.toggle_dimen) then
                    self:_flashAndDo("row_toggle_" .. row.page, row.toggle_dimen, function()
                        if self._active_tab == "bookmarks" then
                            self:_safeBookmarkToggle(row.page)
                        else
                            self:_gotoPage(row.page)
                            self:_closeStay()
                        end
                    end)
                    return true
                end
                
                if ges.pos:intersectWith(row.dimen) then
                    if self._cur_page == row.page then
                        self._hide_action_buttons = not self._hide_action_buttons
                        UIManager:setDirty(self, "ui", self.dimen)
                    else
                        self._force_menu_sync = true
                        self:_previewPage(row.page, false)
                    end
                    return true
                end
            end
        end
        
        if self._split_preview_dimen and ges.pos:intersectWith(self._split_preview_dimen) then
            self._view_mode = "grid"
            self:_clearGridTiles()
            self:_previewPage(self._cur_page, false)
            UIManager:setDirty(nil, "full")
            return true
        end
    end

    if self._view_mode ~= "grid_simple" then
        if self._grid_toggle_dimen and ges.pos:intersectWith(self._grid_toggle_dimen) then
            self:_flashAndDo("grid_toggle", self._grid_toggle_dimen, function()
                if self._view_mode == "grid_six" then
                    self._view_mode = "grid"
                else
                    self._view_mode = "grid_six"
                end
                
                local S = self.S
                if self._view_mode == "grid_six" then
                    self._grid_dimen.y = self._top_bar_dimen.y + self._top_bar_dimen.h + S(26)
                    self._grid_dimen.h = self._bar_dimen.y - self._grid_dimen.y - S(26)
                else
                    self._grid_dimen.y = self._booktitle_y + self.tw_booktitle:getSize().h + S(8)
                    self._grid_dimen.h = self._bar_dimen.y - self._grid_dimen.y
                end

                self:_clearGridTiles()
                self:_previewPage(self._cur_page, false)
                UIManager:setDirty(nil, "full")
            end)
            return true
        end

        if self._lib_dimen and ges.pos:intersectWith(self._lib_dimen) then
            self:_flashAndDo("lib", self._lib_dimen, function() self:_closeAndShow("Home") end)
            return true
        end
        if self._fn_dimen and ges.pos:intersectWith(self._fn_dimen) then
            self:_flashAndDo("fn", self._fn_dimen, function() self:_closeAndShow("ShowMenu") end)
            return true
        end

        if self._toc_dimen and ges.pos:intersectWith(self._toc_dimen) then
            self:_flashAndDo("toc", self._toc_dimen, function() 
                self:_closeAndShow("ShowToc") 
            end)
            return true
        end
    
        if self._x_dimen and ges.pos:intersectWith(self._x_dimen) then
            self:_flashAndDo("x", self._x_dimen, function() self:_closeReturn() end)
            return true
        end
    end

    if self._ctrl_prev_dimen and ges.pos:intersectWith(self._ctrl_prev_dimen) then
        local target = self:_findPrevBookmark()
        if target then
            self:_flashAndDo("ctrl_prev", self._ctrl_prev_dimen, function()
                self._force_menu_sync = true
                self:_previewPage(target, false)
            end)
        end
        return true
    end
    
    if self._ctrl_mark_dimen and ges.pos:intersectWith(self._ctrl_mark_dimen) then
        if self._view_mode == "grid_simple" or self._view_mode == "grid_six" then
            return true
        end
        self:_safeBookmarkToggle(self._cur_page)
        return true
    end
    
    if self._ctrl_next_dimen and ges.pos:intersectWith(self._ctrl_next_dimen) then
        local target = self:_findNextBookmark()
        if target then
            self:_flashAndDo("ctrl_next", self._ctrl_next_dimen, function()
                self._force_menu_sync = true
                self:_previewPage(target, false)
            end)
        end
        return true
    end
    
    if self._prev_ch_dimen and ges.pos:intersectWith(self._prev_ch_dimen) then
        self:_prevChapter()
        return true
    end
    if self._next_ch_dimen and ges.pos:intersectWith(self._next_ch_dimen) then
        self:_nextChapter()
        return true
    end
    
    if self._slider:handleTap(ges) then
        self._force_menu_sync = true
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

    if self._view_mode == "grid" and not self._grid_disabled and self._grid_dimen and ges.pos:intersectWith(self._grid_dimen) then
        local nb_items = self._grid_cols * self._grid_rows
        for idx = 1, nb_items do
            local rect = self:_gridSlotDimen(idx)
            if ges.pos:intersectWith(rect) then
                local slot = self._grid_tiles[idx]
                if slot and slot.page then
                    if idx == 2 then
                        if slot.error then pcall(function() DocCache:clear() end) end
                        self:_gotoPage(slot.page)
                        self:_closeStay()
                    elseif slot.error then
                        slot.error = false
                        slot.loading = true
                        UIManager:setDirty(self, "ui", rect)
                        self._thumb_req_w = (self._thumb_req_w == self._grid_item_w) and (self._grid_item_w + 1) or self._grid_item_w
                        self:_updateGridPages()
                    else
                        self:_previewPage(slot.page, false)
                    end
                end
                return true
            end
        end
        return true
    end

    if self._grid_disabled and self._grid_dimen and ges.pos:intersectWith(self._grid_dimen) then
        if ges.pos.intersectWith and ges.pos:intersectWith(self._fallback_prev_dimen) then
            self:_previewPage(self._cur_page - 1, false)
        elseif ges.pos.intersectWith and ges.pos:intersectWith(self._fallback_next_dimen) then
            self:_previewPage(self._cur_page + 1, false)
        else
            self:_gotoPage(self._cur_page)
            self:_closeStay()
        end
        return true
    end

    return true
end

function PageScrubber:onPan(_, ges)
    if self._closing then return true end
    if self._slider:handlePan(ges) then
        self._force_menu_sync = true
        if self._slider._dragging then
            self._drag_watchdog_gen = (self._drag_watchdog_gen or 0) + 1
            local my_gen = self._drag_watchdog_gen
            UIManager:scheduleIn(1.0, function()
                if self._closing then return end
                if self._drag_watchdog_gen == my_gen and self._slider._dragging then
                    self._slider._dragging = false
                    if not self._grid_disabled then self:_updateGridPages() end
                    UIManager:setDirty(self, "ui", self.dimen)
                end
            end)
        end
        return true 
    end
    self:_cancelHold()
    return true
end

function PageScrubber:onPanRelease(_, ges)
    self:_cancelHold()
    if self._closing then return true end
    if self._slider:handlePanRelease(ges) then 
        UIManager:setDirty(nil, "full")
        return true 
    end
    return true
end

function PageScrubber:onPinch(_, ges)
    if self._closing or self._grid_disabled then return true end
    if self._view_mode == "grid" then
        self._view_mode = "grid_six"
        local S = self.S
        self._grid_dimen.y = self._top_bar_dimen.y + self._top_bar_dimen.h + S(26)
        self._grid_dimen.h = self._bar_dimen.y - self._grid_dimen.y - S(26)
        self:_clearGridTiles()
        self:_previewPage(self._cur_page, false)
        UIManager:setDirty(nil, "full")
    end
    return true
end

function PageScrubber:onSpread(_, ges)
    if self._closing or self._grid_disabled then return true end
    if self._view_mode == "grid_six" then
        self._view_mode = "grid"
        local S = self.S
        self._grid_dimen.y = self._booktitle_y + self.tw_booktitle:getSize().h + S(8)
        self._grid_dimen.h = self._bar_dimen.y - self._grid_dimen.y
        self:_clearGridTiles()
        self:_previewPage(self._cur_page, false)
        UIManager:setDirty(nil, "full")
    end
    return true
end

function PageScrubber:onSwipe(_, ges)
    if self._closing then return true end
    if self._slider._dragging then
        self._slider._dragging = false
        UIManager:setDirty(self, "ui", self.dimen)
    end

    if self._bar_dimen and ges.pos and ges.pos.y >= self._bar_dimen.y then return true end

    if self._view_mode == "split" and ges.pos then
        local sw = Screen:getWidth()
        local div_x = self._split_divider_x or math.floor(sw * 0.65)
        
        if ges.pos.x > div_x then
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
            if ges.direction == "west" then
                self._force_menu_sync = false
                self:_previewPage(self._cur_page + 1, false) 
                return true
            elseif ges.direction == "east" then
                self._force_menu_sync = false
                self:_previewPage(self._cur_page - 1, false) 
                return true
            end
        end
    end

    local jump = (self._view_mode == "grid_six") and 6 or 1

    if ges.direction == "west" then
        self._force_menu_sync = true
        self:_previewPage(self._cur_page + jump, false) 
        return true
    elseif ges.direction == "east" then
        self._force_menu_sync = true
        self:_previewPage(self._cur_page - jump, false) 
        return true
    elseif ges.direction == "south" then
        self:_closeReturn()
        return true
    end
    return false
end

function PageScrubber:onMultiSwipe(_, ges)
    if self._closing then return true end
    if ges.direction == "south" then
        self:_closeReturn()
        return true
    end
    return false
end

function PageScrubber:onHold(_, ges)
    if self._closing then return end

    if self._fn_dimen and ges.pos:intersectWith(self._fn_dimen) then
        self:_showUIScaleSpinner()
        return true
    end

    if self._view_mode == "grid_simple" then
        if self._gs_prev_dimen and ges.pos:intersectWith(self._gs_prev_dimen) then
            self:_startHold("prev"); return true
        end
        if self._gs_next_dimen and ges.pos:intersectWith(self._gs_next_dimen) then
            self:_startHold("next"); return true
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
                    if self._base_grid_mode == "grid_simple" then
                        self:_reopenWithMode("grid_simple", row.page)
                    else
                        self._view_mode = "grid"
                        self:_clearGridTiles()
                        self._force_menu_sync = true
                        self:_previewPage(row.page, false)
                    end
                    return true
                end
            end
        end
        
        local fixed_page = self._split_fixed_page or self._origin_page
        if self._split_fixed_row_dimen and ges.pos:intersectWith(self._split_fixed_row_dimen) and not ges.pos:intersectWith(self._split_fixed_toggle_dimen) then
            if self._base_grid_mode == "grid_simple" then
                self:_reopenWithMode("grid_simple", fixed_page)
            else
                self._view_mode = "grid"
                self:_clearGridTiles()
                self._force_menu_sync = true
                self:_previewPage(fixed_page, false)
            end
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
                    for idx = 1, 6 do
                        if slots[idx] and ges.pos:intersectWith(slots[idx]) then
                            local target_page = self._cur_page + (idx - 2)
                            if target_page >= 1 and target_page <= self._total_pages then
                                self._view_mode = "split"
                                self._active_tab = "bookmarks"
                                self._split_fixed_page = target_page
                                self._split_bm_page = self.initial_bm_page or 1
                                self._force_menu_sync = true
                                self:_clearGridTiles()
                                self:_previewPage(target_page, false)
                            end
                            return true
                        end
                    end
                end
            end
            return true
        elseif self._view_mode == "grid" then
            if ges.pos:intersectWith(self:_gridSlotDimen(1)) then
                self:_startHold("prev"); return true
            end
            if ges.pos:intersectWith(self:_gridSlotDimen(3)) then
                self:_startHold("next"); return true
            end
            if ges.pos:intersectWith(self:_gridSlotDimen(2)) then
                self._view_mode = "split"
                self._active_tab = "bookmarks"
                self._split_fixed_page = self._cur_page
                self._split_bm_page = self.initial_bm_page or 1
                self._force_menu_sync = true
                self:_clearGridTiles()
                self:_previewPage(self._cur_page, false)
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
    self:_cancelHold()
    return true
end

function PageScrubber:onRelease(_, ges)
    self:_cancelHold()
    if self._slider._dragging then
        self._slider._dragging = false
        if not self._grid_disabled then self:_updateGridPages() end
        UIManager:setDirty(nil, "full")
    end
    return true
end

function PageScrubber:onCloseWidget()
    self._closing = true
    self:_cancelHold()
    
    self._slider._dragging = false
    self._is_busy = false
    self._tasks_in_flight = 0
    self._grid_batch_seq = (self._grid_batch_seq or 0) + 1
    self._grid_batch_id = "safe_close_" .. tostring(os.time())

    if not self._grid_disabled then
        for _, slot in pairs(self._grid_tiles) do
            self:_freeTile(slot)
        end
        self._grid_tiles = {}
        UIManager:scheduleIn(0.01, function()
            if self.ui and self.ui.thumbnail and self.ui.thumbnail.tidyCache then
                pcall(function() self.ui.thumbnail:tidyCache() end)
            end
        end)
    end

    if self._old_can_do then Device.canDoSwipeAnimation = self._old_can_do end
    if self._saved_swipe_animations ~= nil then Screen.swipe_animations = self._saved_swipe_animations end

    local widgets_to_free = {
        self._tw_tab_sort, self._tw_tab_bm, self._tw_tab_hl, self._tw_tab_note,
        self.tw_booktitle, self.tw_chapter, self.tw_info,
        self.tw_lib, self.tw_lib_label, self.tw_fn, self.tw_bm, self.tw_gallery, self.tw_toc, self.tw_grid_toggle, self.tw_x,
        self.tw_ch_l, self.tw_ch_r,
        self.tw_ctrl_prev, self.tw_ctrl_mark, self.tw_ctrl_next,
        self.tw_fb_l, self.tw_fb_r,
        self._tw_grid_error, self._tw_grid_back_icon, self._tw_grid_back,
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
    
return PageScrubber

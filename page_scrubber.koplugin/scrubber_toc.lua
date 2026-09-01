--[[
    page_scrubber.koplugin/scrubber_toc.lua
    Módulo interactivo de Tabla de Contenidos (ToC)
]]--

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local DocCache        = require("document/doccache")
local Event           = require("ui/event")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local ProgressSlider  = require("progress_slider")
local TextWidget      = require("ui/widget/textwidget")
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

local function normalize_title(s)
    if not s or s == "" then return "" end
    s = s:gsub("\xE2\x80[\x8B\x8C\x8D]", "")
    s = s:gsub("\xEF\xBB\xBF", "")
    s = s:gsub("\xC2\xA0", " ")
    s = s:gsub("\xE2\x80\xAF", " ")
    s = s:gsub("%s+", " ")
    s = s:match("^%s*(.-)%s*$") or s
    return s
end

local function is_placeholder_title(title)
    local stripped = title:gsub("%s+", ""):gsub("%-", "")
        :gsub("\xE2\x80\x93", ""):gsub("\xE2\x80\x94", "")
    return stripped == ""
end

local function get_entry_title(ui, entry, page)
    local title = normalize_title(entry.title or entry.text or "")
    local toc = ui and ui.toc
    if is_placeholder_title(title) and toc
            and type(toc.getTocTitleByPage) == "function" then
        local resolved = normalize_title(toc:getTocTitleByPage(page) or "")
        if not is_placeholder_title(resolved) then title = resolved end
    end
    if title == "" then title = _("Capítulo") end
    return title
end

local function splitTitle(text, face_obj, max_w)
    local tw = TextWidget:new{ text = text, face = face_obj }
    local w = tw:getSize().w
    tw:free()
    if w <= max_w then return { text } end
    
    local words = {}
    for word in text:gmatch("%S+") do table.insert(words, word) end
    local line1 = ""
    local line2 = ""
    for i, word in ipairs(words) do
        local test_line = line1 == "" and word or line1 .. " " .. word
        local test_tw = TextWidget:new{ text = test_line, face = face_obj }
        local test_w = test_tw:getSize().w
        test_tw:free()
        if test_w <= max_w then
            line1 = test_line
        else
            for j = i, #words do
                line2 = line2 == "" and words[j] or line2 .. " " .. words[j]
            end
            break
        end
    end
    return { line1, line2 }
end

local ScrubberToc = InputContainer:extend{
    name = "scrubber_toc",
    transparent = true,
}

function ScrubberToc:init()
    local ui  = self.ui
    local doc = ui.document

    local scale_factor = self.ui_scale or (G_reader_settings and G_reader_settings:readSetting("page_scrubber_ui_scale")) or 1.0
    self.S = function(val)
        local base_px = Screen:scaleBySize(val)
        local res = math.floor((base_px * scale_factor) + 0.5)
        if val > 0 and res <= 0 then res = 1 end
        return res
    end
    local S = self.S

    self._origin_page = self.initial_origin or (ui.view and ui.view.state and ui.view.state.page) or 1
    self._cur_page    = self.initial_page or self._origin_page
    self._total_pages = (doc and doc.getPageCount and doc:getPageCount()) or 1
    self._pressed_btn = nil
    self._closing     = false
    self._repeat_running = false

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self._sw = sw
    self._sh = sh

    local PLUGIN_DIR = debug.getinfo(1, "S").source:gsub("^@(.*)/[^/]*", "%1")
    local function createSafeIcon(icon_char, svg_filename, sz, custom_color)
        local fg = custom_color or Blitbuffer.COLOR_BLACK
        local base_path = PLUGIN_DIR .. "/icons/" .. svg_filename
        local ok, widget = pcall(function()
            local ImageWidget = require("ui/widget/imagewidget")
            return ImageWidget:new{ file = base_path, width = sz, height = sz, alpha = true, fgcolor = fg }
        end)
        if ok and widget then return widget end
        return TextWidget:new{ text = icon_char, face = Font:getFace("cfont", sz), fgcolor = fg }
    end

    -- Iconos Normales e Invertidos (Blanco)
    self.icon_wifi_0    = createSafeIcon("0", "wifi-zero.svg", S(42))
    self.icon_wifi_1    = createSafeIcon("1", "wifi-low.svg", S(42))
    self.icon_wifi_2    = createSafeIcon("2", "wifi-high.svg", S(42))
    
    self.icon_ch_prev   = createSafeIcon("|<", "skip-back.svg", S(40)) 
    self.icon_ch_prev_inv = createSafeIcon("|<", "skip-back.svg", S(40), Blitbuffer.COLOR_WHITE) 

    self.icon_ch_next   = createSafeIcon(">|", "skip-forward.svg", S(40))
    self.icon_ch_next_inv = createSafeIcon(">|", "skip-forward.svg", S(40), Blitbuffer.COLOR_WHITE)
    
    self.icon_toc_first = createSafeIcon("<<", "step-back.svg", S(24))
    self.icon_toc_first_inv = createSafeIcon("<<", "step-back.svg", S(24), Blitbuffer.COLOR_WHITE)

    self.icon_toc_prev  = createSafeIcon("<", "chevron-left.svg", S(24))
    self.icon_toc_prev_inv = createSafeIcon("<", "chevron-left.svg", S(24), Blitbuffer.COLOR_WHITE)

    self.icon_toc_next  = createSafeIcon(">", "chevron-right.svg", S(24))
    self.icon_toc_next_inv = createSafeIcon(">", "chevron-right.svg", S(24), Blitbuffer.COLOR_WHITE)

    self.icon_toc_last  = createSafeIcon(">>", "step-forward.svg", S(24))
    self.icon_toc_last_inv = createSafeIcon(">>", "step-forward.svg", S(24), Blitbuffer.COLOR_WHITE)

    local function getBookProps()
        local title, author
        if ui.doc_props then
            title = ui.doc_props.title
            author = ui.doc_props.authors or ui.doc_props.author
        end
        if (not title or title == "") and doc and doc.getProps then
            local ok, props = pcall(function() return doc:getProps() end)
            if ok and props then
                title = props.title
                author = props.authors or props.author
            end
        end
        if not title or title == "" then
            local file = doc and doc.file
            local base = file and file:match("([^/\\]+)$") or file
            title = base and base:gsub("%.%w+$", "") or _("Untitled")
        end
        return title or "Sin Título", author or ""
    end

    self.book_title, self.book_author = getBookProps()

    self._flat_toc = {}
    local raw_toc = (ui.toc and ui.toc.toc) or {}
    local page_to_idx = {}
    
    local min_depth = 999
    local max_depth = 0

    for _i, e in ipairs(raw_toc) do
        local p = e.page or e.pageno
        if not p and e.pos0 and doc and doc.getPageFromXPointer then
            pcall(function() p = doc:getPageFromXPointer(e.pos0) end)
        end
        if p and tonumber(p) then
            local page_num = math.floor(tonumber(p))
            if page_num >= 1 and page_num <= self._total_pages then
                local depth = e.depth or 1
                if depth <= 3 then
                    local title = get_entry_title(self.ui, e, page_num)
                    local idx = page_to_idx[page_num]
                    
                    if idx then
                        local existing = self._flat_toc[idx].title
                        if title ~= "" and is_placeholder_title(existing) then
                            self._flat_toc[idx].title = title
                        elseif title ~= "" and title ~= existing then
                            self._flat_toc[idx].title = existing .. " · " .. title
                        end
                        if depth < self._flat_toc[idx].depth then
                            self._flat_toc[idx].depth = depth
                        end
                    else
                        page_to_idx[page_num] = #self._flat_toc + 1
                        table.insert(self._flat_toc, {
                            title = title,
                            page = page_num,
                            depth = depth,
                        })
                    end
                end
            end
        end
    end

    for _, ch in ipairs(self._flat_toc) do
        if ch.depth < min_depth then min_depth = ch.depth end
        if ch.depth > max_depth then max_depth = ch.depth end
    end
    
    if min_depth < 999 and min_depth > 0 then
        for _, ch in ipairs(self._flat_toc) do
            ch.depth = ch.depth - min_depth
        end
        max_depth = max_depth - min_depth
    end

    self._has_multiple_levels = (max_depth > 0)

    self._filter_level = 2 
    self._filtered_toc = {}
    
    self.refreshFilter = function()
        self._filtered_toc = {}
        for _, ch in ipairs(self._flat_toc) do
            if self._filter_level == 2 or ch.depth <= self._filter_level then
                table.insert(self._filtered_toc, ch)
            end
        end
        self:_syncTocPageWithCurrentPage()
    end
    self.refreshFilter()

    local text_size_pref = G_reader_settings and G_reader_settings:readSetting("page_scrubber_text_size") or "medium"
    local t_off = 0
    if text_size_pref == "small" then t_off = -2
    elseif text_size_pref == "large" then t_off = 2 end
    self.S_BOTTOM_GRAY = S(14 + t_off)

    self.font_title  = Font:getFace("cfont", S(20 + t_off))
    self.font_author = Font:getFace("cfont", S(15 + t_off))
    self.font_item   = Font:getFace("cfont", S(15 + t_off))
    self.font_badge  = Font:getFace("cfont", S(16 + t_off))

    self.tw_x = createSafeIcon("✕", "x.svg", S(28))
    self.tw_x_inv = createSafeIcon("✕", "x.svg", S(28), Blitbuffer.COLOR_WHITE)
    
    local max_title_w = sw - S(48)
    self.title_lines = splitTitle(self.book_title, self.font_title, max_title_w)
    self.tw_titles = {}
    for _, txt in ipairs(self.title_lines) do
        table.insert(self.tw_titles, TextWidget:new{ 
            text = txt, face = self.font_title, bold = true, 
            fgcolor = Blitbuffer.COLOR_BLACK, max_width = max_title_w, 
            truncate_with_ellipsis = true 
        })
    end
    
    self.tw_author = TextWidget:new{ text = self.book_author, face = self.font_author, fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = sw - S(48), truncate_with_ellipsis = true }

    -- =========================================================================
    -- GEOMETRÍA: BARRA INFERIOR (MATEMÁTICA IDÉNTICA AL GRID)
    -- =========================================================================
    local font_ch_measure = Font:getFace("cfont", S(15 + t_off))
    local font_info_measure = Font:getFace("cfont", S(13 + t_off))
    local tw_ch_dummy = TextWidget:new{ text = "—", face = font_ch_measure }
    local tw_info_dummy = TextWidget:new{ text = "100%", face = font_info_measure }
    local ch_h = tw_ch_dummy:getSize().h
    local info_h = tw_info_dummy:getSize().h
    tw_ch_dummy:free()
    tw_info_dummy:free()

    local p_top = S(8)
    local spacing1 = S(3)
    local spacing2 = S(4)
    local spacing3 = S(10)
    local mark_sz = S(36)
    local p_bot = S(12) 
    
    local slider_pad_x = S(32)
    local slider_w = sw - (slider_pad_x * 2)
    self._slider_x = slider_pad_x
    self._slider = ProgressSlider:new{ width = slider_w, value = self._cur_page, value_min = 1, value_max = self._total_pages, ticks = nil, S = S }
    local slider_h = self._slider:getSize().h

    local bar_h = p_top + ch_h + spacing1 + info_h + spacing2 + slider_h + spacing3 + mark_sz + p_bot
    local bar_y = sh - bar_h
    self._bar_dimen = Geom:new{ x = 0, y = bar_y, w = sw, h = bar_h }

    local inner_h = bar_h - p_top - p_bot
    local row_step = math.floor(inner_h / 3)

    local ch_btn_sz = S(40)
    local toc_btn_sz = S(34)
    
    local lvl1_y = bar_y + p_top + math.floor((row_step - ch_btn_sz) / 2)
    local lvl2_y = bar_y + p_top + row_step + math.floor((row_step - toc_btn_sz) / 2)
    self.slider_y_pos = bar_y + p_top + (row_step * 2) + math.floor((row_step - slider_h) / 2)

    local c1 = math.floor(sw * 0.20)
    local c2 = math.floor(sw * 0.80)
    
    self._prev_ch_dimen = Geom:new{ x = c1 - math.floor(ch_btn_sz/2), y = lvl1_y, w = ch_btn_sz, h = ch_btn_sz }
    self._next_ch_dimen = Geom:new{ x = c2 - math.floor(ch_btn_sz/2), y = lvl1_y, w = ch_btn_sz, h = ch_btn_sz }

    local gap_between_pairs = S(45)

    local t1 = c1 - math.floor(gap_between_pairs / 2)
    local t2 = c1 + math.floor(gap_between_pairs / 2)
    local t3 = c2 - math.floor(gap_between_pairs / 2)
    local t4 = c2 + math.floor(gap_between_pairs / 2)

    self._first_toc_dimen = Geom:new{ x = t1 - math.floor(toc_btn_sz/2), y = lvl2_y, w = toc_btn_sz, h = toc_btn_sz }
    self._prev_toc_dimen  = Geom:new{ x = t2 - math.floor(toc_btn_sz/2), y = lvl2_y, w = toc_btn_sz, h = toc_btn_sz }
    self._next_toc_dimen  = Geom:new{ x = t3 - math.floor(toc_btn_sz/2), y = lvl2_y, w = toc_btn_sz, h = toc_btn_sz }
    self._last_toc_dimen  = Geom:new{ x = t4 - math.floor(toc_btn_sz/2), y = lvl2_y, w = toc_btn_sz, h = toc_btn_sz }

    -- =========================================================================
    -- GEOMETRÍA: MINI PREVIEW
    -- =========================================================================
    local preview_h = math.floor(sh * 0.20)
    if preview_h < S(120) then preview_h = S(120) end
    
    local preview_w = math.floor(preview_h * sw / sh)
    local preview_x = math.floor((sw - preview_w) / 2)
    
    local preview_y = self.slider_y_pos - preview_h - S(4)
    
    self._preview_dimen = Geom:new{ x = preview_x, y = preview_y, w = preview_w, h = preview_h }
    self._thumb_req_w = preview_w - S(4)
    self._thumb_req_h = preview_h - S(4)

    -- =========================================================================
    -- GEOMETRÍA: PANEL ÚNICO DEL TOC
    -- =========================================================================
    local panel_h = preview_y - S(10)
    self._top_panel_dimen = Geom:new{ x = 0, y = 0, w = sw, h = panel_h }

    local py = #self.tw_titles > 1 and S(8) or S(16)
    self._title_y = py 
    for _, tw in ipairs(self.tw_titles) do
        py = py + tw:getSize().h + S(2)
    end

    self._author_y = py + S(2)
    local asz = self.tw_author:getSize()
    py = self._author_y + asz.h + S(12)

    self._divider_y = py
    py = py + S(1) + S(8)

    self._bot_internal_h = S(50)
    self._bot_internal_y = panel_h - self._bot_internal_h - S(8)

    local filter_sz = S(48)
    if self._has_multiple_levels then
        self._filter_dimen = Geom:new{ x = S(16), y = self._bot_internal_y + math.floor((self._bot_internal_h - filter_sz)/2), w = filter_sz, h = filter_sz }
    else
        self._filter_dimen = nil
    end

    local btn_sz_top = S(42)
    self._close_dimen = Geom:new{ x = sw - S(14) - btn_sz_top, y = self._bot_internal_y + math.floor((self._bot_internal_h - btn_sz_top) / 2), w = btn_sz_top, h = btn_sz_top }

    self._list_y = py
    self._list_avail_h = self._bot_internal_y - self._list_y - S(8)
    
    local target_row_h = S(48)
    self._items_per_page = math.max(2, math.floor(self._list_avail_h / target_row_h))
    self._row_h = math.floor(self._list_avail_h / self._items_per_page)

    self._slider.on_change = function(v)
        self:_previewPage(v, self._slider._dragging)
    end

    self._toc_page = 1
    self._toc_rows = {}
    self._preview_tile = nil
    self._grid_batch_seq = 0
    self._grid_instance_id = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))

    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    self:_syncTocPageWithCurrentPage()

    if Device:hasKeys() then
        self.key_events = {
            Close          = flatten_keys(Device.input.group.Back),
            PrevPage       = flatten_keys(Device.input.group.PgBack, Device.input.group.Left),
            NextPage       = flatten_keys(Device.input.group.PgFwd, Device.input.group.Right),
            PrevChapterKey = flatten_keys(Device.input.group.PrevLine, Device.input.group.Up),
            NextChapterKey = flatten_keys(Device.input.group.NextLine, Device.input.group.Down),
            Select         = flatten_keys(Device.input.group.Select, Device.input.group.Press),
        }
    end

    self.ges_events = {
        Tap         = { GestureRange:new{ ges = "tap",          range = self.dimen } },
        Hold        = { GestureRange:new{ ges = "hold",         range = self.dimen } },
        HoldRelease = { GestureRange:new{ ges = "hold_release", range = self.dimen } },
        Pan         = { GestureRange:new{ ges = "pan",          range = self.dimen } },
        PanRelease  = { GestureRange:new{ pan_release = "pan_release", range = self.dimen } },
        Swipe       = { GestureRange:new{ ges = "swipe",        range = self.dimen } },
        Release     = { GestureRange:new{ ges = "release",      range = self.dimen } },
    }

    UIManager:scheduleIn(0.05, function()
        if not self._closing then 
            -- Cambiamos el flash completo por una actualización suave (solo la UI del menú)
            UIManager:setDirty(self, "ui")
            self:_updatePreviewTile() 
        end
    end)
end

function ScrubberToc:_getChapterIndexForPage(page)
    if #self._filtered_toc == 0 then return 1 end
    local best_idx = 1
    for idx, ch in ipairs(self._filtered_toc) do
        if ch.page <= page then best_idx = idx else break end
    end
    return best_idx
end

function ScrubberToc:_getActiveChapterIndex()
    if self._slider and self._slider._dragging then 
        return nil 
    end
    return self:_getChapterIndexForPage(self._cur_page)
end

function ScrubberToc:_syncTocPageWithCurrentPage()
    local idx = self:_getChapterIndexForPage(self._cur_page)
    if idx and self._items_per_page and self._items_per_page > 0 then
        self._toc_page = math.ceil(idx / self._items_per_page)
    end
end

function ScrubberToc:_getPrevChapterPage()
    local cur = self._cur_page
    local best = 1
    if not self._flat_toc or #self._flat_toc == 0 then return math.max(1, cur - 10) end
    for i = #self._flat_toc, 1, -1 do
        if self._flat_toc[i].page < cur then
            best = self._flat_toc[i].page
            break
        end
    end
    return best
end

function ScrubberToc:_getNextChapterPage()
    local cur = self._cur_page
    local best = self._total_pages
    if not self._flat_toc or #self._flat_toc == 0 then return math.min(self._total_pages, cur + 10) end
    for i = 1, #self._flat_toc do
        if self._flat_toc[i].page > cur then
            best = self._flat_toc[i].page
            break
        end
    end
    return best
end

function ScrubberToc:_updatePreviewTile()
    if self._closing then return end
    local thumbnail = self.ui.thumbnail
    if not thumbnail or not thumbnail.getPageThumbnail then return end

    local page = self._cur_page
    self._grid_batch_seq = self._grid_batch_seq + 1
    local batch_id = "scrubber_toc_" .. self._grid_instance_id .. "_" .. tostring(self._grid_batch_seq)
    self._current_batch_id = batch_id

    local req_w = self._thumb_req_w
    local req_h = self._thumb_req_h

    thumbnail:getPageThumbnail(page, req_w, req_h, batch_id, function(tile, resp_batch_id)
        if self._closing or resp_batch_id ~= self._current_batch_id then return end
        local processed = processTile(tile, req_w, req_h)
        if processed and processed.bb then
            if self._preview_tile and self._preview_tile.is_scaled and self._preview_tile.bb then
                pcall(function() self._preview_tile.bb:free() end)
            end
            self._preview_tile = processed
            UIManager:setDirty(self, "ui", self._preview_dimen)
        end
    end)
end

function ScrubberToc:_previewPage(page, is_dragging)
    if self._closing then return end
    
    local state_changed = (self._last_drag_state ~= is_dragging)
    self._last_drag_state = is_dragging
    
    if self._cur_page == page and not state_changed then 
        if not is_dragging then
            UIManager:setDirty(self, "ui", self.dimen)
        end
        return 
    end
    
    self._cur_page = math.max(1, math.min(self._total_pages, page))
    if self._slider then self._slider.value = self._cur_page end
    
    self:_syncTocPageWithCurrentPage()
    
    if is_dragging then
        UIManager:setDirty(self, "ui", self.dimen)
        
        self._preview_drag_seq = (self._preview_drag_seq or 0) + 1
        local current_seq = self._preview_drag_seq
        UIManager:scheduleIn(0.08, function()
            if self._closing or self._preview_drag_seq ~= current_seq then return end
            self:_updatePreviewTile()
        end)
    else
        self:_updatePreviewTile()
        UIManager:setDirty(self, "ui", self.dimen)
    end
end

function ScrubberToc:_startRepeatAction(action_func)
    if self._closing then return end
    self._repeat_running = true

    local function repeat_step()
        if self._closing or not self._repeat_running then 
            self._repeat_timer = nil
            return 
        end
        action_func()
        self._repeat_timer = UIManager:scheduleIn(0.15, repeat_step)
    end

    self._repeat_timer = UIManager:scheduleIn(0.05, function()
        if self._closing or not self._repeat_running then
            self._repeat_timer = nil
            return
        end
        action_func()
        self._repeat_timer = UIManager:scheduleIn(0.4, repeat_step)
    end)
end

function ScrubberToc:_stopRepeatAction()
    self._repeat_running = false
    if self._repeat_timer then
        UIManager:unschedule(self._repeat_timer)
        self._repeat_timer = nil
    end
end

function ScrubberToc:_gotoPageDirectly(page)
    if self._closing then return end
    self._closing = true
    
    self:_stopRepeatAction()

    self._cur_page = math.max(1, math.min(self._total_pages, page))
    local target_page = self._cur_page
    local origin_page = self._origin_page

    if target_page ~= origin_page then
        pcall(function()
            if self.ui.link and self.ui.link.addCurrentLocationToStack then
                self.ui.link:addCurrentLocationToStack()
            end
        end)
    end

    local ui_ref = self.ui
    local parent_ref = self.parent_scrubber

    local UIManager = require("ui/uimanager")
    UIManager:close(self)
    
    if parent_ref then
        pcall(function()
            parent_ref._closing = true
            UIManager:close(parent_ref)
        end)
    end
    
    UIManager:setDirty(nil, "full")
    ui_ref:handleEvent(Event:new("GotoPage", target_page))
end

function ScrubberToc:_returnToGrid(page)
    if self._closing then return end
    
    if not self.parent_scrubber then
        self:_gotoPageDirectly(page)
        return
    end

    self._closing = true
    self:_stopRepeatAction()

    local parent_ref = self.parent_scrubber
    local UIManager = require("ui/uimanager")
    UIManager:close(self)
    
    pcall(function()
        parent_ref:_previewPage(page, false)
        UIManager:setDirty(nil, "full")
    end)
end

function ScrubberToc:_closeReturn()
    if self._closing then return end
    self._closing = true
    self:_stopRepeatAction()

    local UIManager = require("ui/uimanager")
    UIManager:close(self)
    
    if self.parent_scrubber then
        self.parent_scrubber:_previewPage(self.initial_page or self._origin_page, false)
        UIManager:setDirty(nil, "full")
    else
        UIManager:setDirty(nil, "full")
    end
end

function ScrubberToc:_closeStay()
    if self._closing then return end
    self._closing = true
    self:_stopRepeatAction()

    local UIManager = require("ui/uimanager")
    UIManager:close(self)
    if self.parent_scrubber then
        self.parent_scrubber:_closeStay()
    else
        UIManager:setDirty(nil, "full")
    end
end

function ScrubberToc:onClose()
    self:_closeReturn()
    return true
end

function ScrubberToc:paintTo(bb, x, y)
    if self._closing then return end
    local ok, err = pcall(function() self:_paintToImpl(bb, x, y) end)
    if not ok then logger.warn("scrubber_toc paintTo error:", err) end
end

function ScrubberToc:_paintToImpl(bb, x, y)
    local sw, sh = self._sw, self._sh
    local S = self.S
    local pd = self._top_panel_dimen
    local bd = self._bar_dimen
    
    local tab_radius = S(24)
    
    -- Grosor S(3) IDÉNTICO AL GRID (scrubber_ui.lua)
    local b_thick = S(3)
    
    local shadow_offset = S(2)

    local mesh_start_y = pd.h
    local mesh_end_y = bd.y
    for dy = mesh_start_y, mesh_end_y, 2 do
        bb:paintRect(0, dy, sw, 1, Blitbuffer.COLOR_WHITE)
    end

    paintBottomRoundedTab(bb, 0, shadow_offset, sw, pd.h, tab_radius, Blitbuffer.COLOR_GRAY)
    paintBottomRoundedTab(bb, 0, 0, sw, pd.h, tab_radius, Blitbuffer.COLOR_BLACK)
    
    -- El relleno blanco deja S(3) en los laterales y S(3) en el borde inferior
    paintBottomRoundedTab(bb, b_thick, 0, sw - (b_thick * 2), pd.h - b_thick, math.max(1, tab_radius - b_thick), Blitbuffer.COLOR_WHITE)

    local head_pad_x = S(24)
    local current_py = self._title_y
    for _, tw in ipairs(self.tw_titles) do
        tw:paintTo(bb, head_pad_x, current_py)
        current_py = current_py + tw:getSize().h + S(2)
    end
    
    -- Triple dibujado para el autor (mejora legibilidad del gris en e-ink)
    self.tw_author:paintTo(bb, head_pad_x, self._author_y)
    self.tw_author:paintTo(bb, head_pad_x + 1, self._author_y)
    self.tw_author:paintTo(bb, head_pad_x, self._author_y + 1)
    
    bb:paintRect(S(16), self._divider_y, sw - S(32), S(1), Blitbuffer.COLOR_LIGHT_GRAY)

    local is_scrubbing = (self._slider and self._slider._dragging) or self._repeat_running

    local total_items = #self._filtered_toc
    local total_pages = math.max(1, math.ceil(total_items / self._items_per_page))
    if self._toc_page > total_pages then self._toc_page = total_pages end
    if self._toc_page < 1 then self._toc_page = 1 end

    local start_idx = (self._toc_page - 1) * self._items_per_page + 1
    local end_idx   = math.min(self._toc_page * self._items_per_page, total_items)
    
    local active_ch_idx = is_scrubbing and -1 or self:_getActiveChapterIndex()

    self._toc_rows = {}

    if total_items == 0 then
        local empty_tw = TextWidget:new{ text = _("No chapters found"), face = self.font_item, fgcolor = Blitbuffer.COLOR_DARK_GRAY }
        local esz = empty_tw:getSize()
        empty_tw:paintTo(bb, math.floor((sw - esz.w)/2), self._list_y + math.floor((self._list_avail_h - esz.h)/2))
        empty_tw:free()
    else
        local curr_y = self._list_y
        for i = start_idx, end_idx do
            local ch = self._filtered_toc[i]
            local is_active = (i == active_ch_idx)
            local row_rect = Geom:new{ x = S(12), y = curr_y, w = sw - S(24), h = self._row_h - S(4) }

            if is_active then
                paintRoundRect(bb, row_rect.x, row_rect.y, row_rect.w, row_rect.h, S(8), Blitbuffer.COLOR_BLACK)
            else
                bb:paintRect(row_rect.x + S(8), row_rect.y + row_rect.h + S(1), row_rect.w - S(16), 1, Blitbuffer.COLOR_LIGHT_GRAY)
            end

            local pg_str = _("Page") .. " " .. tostring(ch.page)
            local fg_col = is_active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
            local tw_pnum = TextWidget:new{ text = pg_str, face = self.font_badge, bold = is_active, fgcolor = fg_col }
            local pnum_sz = tw_pnum:getSize()
            local pnum_x = row_rect.x + row_rect.w - pnum_sz.w - S(14)
            local pnum_y = row_rect.y + math.floor((row_rect.h - pnum_sz.h) / 2)
            tw_pnum:paintTo(bb, pnum_x, pnum_y)
            tw_pnum:free()

            local ch_title_text = ch.title
            local ch_x = row_rect.x
            
            if ch.depth == 0 then
                ch_x = ch_x + S(12)
            elseif ch.depth == 1 then
                ch_x = ch_x + S(40)
            else
                ch_x = ch_x + S(40)
                ch_title_text = "• " .. ch_title_text
            end

            local max_ch_w = row_rect.w - pnum_sz.w - (ch_x - row_rect.x) - S(16)
            local tw_ch = TextWidget:new{
                text = ch_title_text, face = self.font_item, bold = is_active,
                fgcolor = fg_col, max_width = max_ch_w, truncate_with_ellipsis = true,
            }
            local ch_sz = tw_ch:getSize()
            local ch_y = row_rect.y + math.floor((row_rect.h - ch_sz.h) / 2)
            tw_ch:paintTo(bb, ch_x, ch_y)
            tw_ch:free()

            table.insert(self._toc_rows, { dimen = row_rect, index = i, page = ch.page })
            curr_y = curr_y + self._row_h
        end
    end

    local pag_str = self._toc_page .. " / " .. total_pages
    local tw_pag = TextWidget:new{ text = pag_str, face = self.font_badge, bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
    local psz_w = tw_pag:getSize().w
    local psz_h = tw_pag:getSize().h
    local text_center = math.floor(sw / 2)
    tw_pag:paintTo(bb, text_center - math.floor(psz_w/2), self._bot_internal_y + math.floor((self._bot_internal_h - psz_h)/2))
    tw_pag:free()
    
    if self._has_multiple_levels and self._filter_dimen then
        local fd = self._filter_dimen
        local is_pressed = (self._pressed_btn == "filter")
        
        local current_wifi
        if self._filter_level == 0 then current_wifi = self.icon_wifi_0
        elseif self._filter_level == 1 then current_wifi = self.icon_wifi_1
        else current_wifi = self.icon_wifi_2 end

        local ic_sz = current_wifi:getSize()
        local ix = fd.x + math.floor((fd.w - ic_sz.w) / 2)
        local iy = fd.y + math.floor((fd.h - ic_sz.h) / 2) - S(6) 

        if is_pressed then
            current_wifi.fgcolor = Blitbuffer.COLOR_GRAY
            current_wifi:paintTo(bb, ix, iy)
            current_wifi.fgcolor = Blitbuffer.COLOR_BLACK
        else
            current_wifi:paintTo(bb, ix, iy)
        end
    end

    local x_sz = self.tw_x:getSize()
    local cx = self._close_dimen.x + math.floor((self._close_dimen.w - x_sz.w) / 2)
    local cy = self._close_dimen.y + math.floor((self._close_dimen.h - x_sz.h) / 2)
    
    if self._pressed_btn == "x" then
        paintRoundRect(bb, self._close_dimen.x, self._close_dimen.y, self._close_dimen.w, self._close_dimen.h, S(12), Blitbuffer.COLOR_BLACK)
        self.tw_x_inv:paintTo(bb, cx, cy)
    else
        self.tw_x:paintTo(bb, cx, cy)
    end

    -- =========================================================================
    -- 2. BARRA INFERIOR (Capa base, botones, slider)
    -- =========================================================================
    bb:paintRect(bd.x, bd.y, bd.w, bd.h, Blitbuffer.COLOR_WHITE)
    
    -- Grosor S(3) IDÉNTICO AL GRID (scrubber_ui.lua)
    bb:paintRect(bd.x, bd.y, bd.w, S(3), Blitbuffer.COLOR_BLACK)

    local bloom_ch = S(4)
    local rad_ch = S(12)

    local is_prev_ch = self._pressed_btn == "prev_ch" or self._repeat_running_id == "prev_ch"
    local asz_pch = self.icon_ch_prev:getSize()
    local pch_x = self._prev_ch_dimen.x + math.floor((self._prev_ch_dimen.w - asz_pch.w)/2)
    local pch_y = self._prev_ch_dimen.y + math.floor((self._prev_ch_dimen.h - asz_pch.h)/2)
    
    if is_prev_ch then
        local d = self._prev_ch_dimen
        paintRoundRect(bb, d.x - bloom_ch, d.y - bloom_ch, d.w + bloom_ch*2, d.h + bloom_ch*2, rad_ch, Blitbuffer.COLOR_BLACK)
        self.icon_ch_prev_inv:paintTo(bb, pch_x, pch_y)
    else
        self.icon_ch_prev:paintTo(bb, pch_x, pch_y)
    end

    local is_next_ch = self._pressed_btn == "next_ch" or self._repeat_running_id == "next_ch"
    local asz_nch = self.icon_ch_next:getSize()
    local nch_x = self._next_ch_dimen.x + math.floor((self._next_ch_dimen.w - asz_nch.w)/2)
    local nch_y = self._next_ch_dimen.y + math.floor((self._next_ch_dimen.h - asz_nch.h)/2)
    
    if is_next_ch then
        local d = self._next_ch_dimen
        paintRoundRect(bb, d.x - bloom_ch, d.y - bloom_ch, d.w + bloom_ch*2, d.h + bloom_ch*2, rad_ch, Blitbuffer.COLOR_BLACK)
        self.icon_ch_next_inv:paintTo(bb, nch_x, nch_y)
    else
        self.icon_ch_next:paintTo(bb, nch_x, nch_y)
    end

    local bloom_toc = S(4)
    local rad_toc = S(10)

    if self._toc_page > 1 then
        local asz_f = self.icon_toc_first:getSize()
        local f_x = self._first_toc_dimen.x + math.floor((self._first_toc_dimen.w - asz_f.w)/2)
        local f_y = self._first_toc_dimen.y + math.floor((self._first_toc_dimen.h - asz_f.h)/2)
        if self._pressed_btn == "first_toc" then 
            local d = self._first_toc_dimen
            paintRoundRect(bb, d.x - bloom_toc, d.y - bloom_toc, d.w + bloom_toc*2, d.h + bloom_toc*2, rad_toc, Blitbuffer.COLOR_BLACK)
            self.icon_toc_first_inv:paintTo(bb, f_x, f_y)
        else
            self.icon_toc_first:paintTo(bb, f_x, f_y)
        end

        local asz_p = self.icon_toc_prev:getSize()
        local p_x = self._prev_toc_dimen.x + math.floor((self._prev_toc_dimen.w - asz_p.w)/2)
        local p_y = self._prev_toc_dimen.y + math.floor((self._prev_toc_dimen.h - asz_p.h)/2)
        if self._pressed_btn == "prev_toc" then 
            local d = self._prev_toc_dimen
            paintRoundRect(bb, d.x - bloom_toc, d.y - bloom_toc, d.w + bloom_toc*2, d.h + bloom_toc*2, rad_toc, Blitbuffer.COLOR_BLACK)
            self.icon_toc_prev_inv:paintTo(bb, p_x, p_y)
        else
            self.icon_toc_prev:paintTo(bb, p_x, p_y)
        end
    end

    if self._toc_page < total_pages then
        local asz_n = self.icon_toc_next:getSize()
        local n_x = self._next_toc_dimen.x + math.floor((self._next_toc_dimen.w - asz_n.w)/2)
        local n_y = self._next_toc_dimen.y + math.floor((self._next_toc_dimen.h - asz_n.h)/2)
        if self._pressed_btn == "next_toc" then 
            local d = self._next_toc_dimen
            paintRoundRect(bb, d.x - bloom_toc, d.y - bloom_toc, d.w + bloom_toc*2, d.h + bloom_toc*2, rad_toc, Blitbuffer.COLOR_BLACK)
            self.icon_toc_next_inv:paintTo(bb, n_x, n_y)
        else
            self.icon_toc_next:paintTo(bb, n_x, n_y)
        end

        local asz_l = self.icon_toc_last:getSize()
        local l_x = self._last_toc_dimen.x + math.floor((self._last_toc_dimen.w - asz_l.w)/2)
        local l_y = self._last_toc_dimen.y + math.floor((self._last_toc_dimen.h - asz_l.h)/2)
        if self._pressed_btn == "last_toc" then 
            local d = self._last_toc_dimen
            paintRoundRect(bb, d.x - bloom_toc, d.y - bloom_toc, d.w + bloom_toc*2, d.h + bloom_toc*2, rad_toc, Blitbuffer.COLOR_BLACK)
            self.icon_toc_last_inv:paintTo(bb, l_x, l_y)
        else
            self.icon_toc_last:paintTo(bb, l_x, l_y)
        end
    end

    self._slider.value = self._cur_page
    self._slider:paintTo(bb, self._slider_x, self.slider_y_pos)

    -- =========================================================================
    -- 3. MINI PREVIEW
    -- =========================================================================
    local pr = self._preview_dimen
    paintRoundRect(bb, pr.x, pr.y + S(4), pr.w, pr.h, S(8), Blitbuffer.COLOR_DARK_GRAY)
    paintRoundRect(bb, pr.x, pr.y, pr.w, pr.h, S(8), Blitbuffer.COLOR_BLACK)
    local pr_b_thick = S(3)
    paintRoundRect(bb, pr.x + pr_b_thick, pr.y + pr_b_thick, pr.w - pr_b_thick*2, pr.h - pr_b_thick*2, S(6), Blitbuffer.COLOR_WHITE)

    if self._preview_tile and self._preview_tile.bb then
        local tw, th = self._preview_tile.bb:getWidth(), self._preview_tile.bb:getHeight()
        local blit_w = math.min(tw, pr.w - pr_b_thick*2)
        local blit_h = math.min(th, pr.h - pr_b_thick*2)
        local ox = pr.x + pr_b_thick + math.floor((pr.w - pr_b_thick*2 - blit_w) / 2)
        local oy = pr.y + pr_b_thick + math.floor((pr.h - pr_b_thick*2 - blit_h) / 2)
        bb:blitFrom(self._preview_tile.bb, ox, oy, 0, 0, blit_w, blit_h)
    else
        bb:paintRect(pr.x + math.floor(pr.w/2) - 1, pr.y + math.floor(pr.h/2) - 1, 2, 2, Blitbuffer.COLOR_GRAY)
    end
end

function ScrubberToc:_flashAndDo(btn_id, rect, action_func)
    if self._closing then return end
    self._pressed_btn = btn_id
    UIManager:setDirty(self, "ui", rect)
    UIManager:scheduleIn(0.05, function()
        self._pressed_btn = nil
        action_func()
    end)
end

function ScrubberToc:onHold(arg1, arg2)
    local ges = arg2 or arg1
    if self._closing then return true end

    if self._preview_dimen and ges.pos:intersectWith(self._preview_dimen) then
        local target_page = self._cur_page
        self:_flashAndDo("hold_preview", self._preview_dimen, function()
            self:_gotoPageDirectly(target_page)
        end)
        return true
    end

    if self._toc_rows then
        for _, row in ipairs(self._toc_rows) do
            if ges.pos:intersectWith(row.dimen) then
                local target_page = row.page
                self:_flashAndDo("hold_row_" .. tostring(target_page), row.dimen, function()
                    self:_gotoPageDirectly(target_page)
                end)
                return true
            end
        end
    end

    if self._prev_ch_dimen and ges.pos:intersectWith(self._prev_ch_dimen) then
        self._repeat_running_id = "prev_ch"
        self:_startRepeatAction(function()
            local p = self:_getPrevChapterPage()
            self:_previewPage(p, true)
        end)
        return true
    end

    if self._next_ch_dimen and ges.pos:intersectWith(self._next_ch_dimen) then
        self._repeat_running_id = "next_ch"
        self:_startRepeatAction(function()
            local p = self:_getNextChapterPage()
            self:_previewPage(p, true)
        end)
        return true
    end

    return true
end

function ScrubberToc:onTap(arg1, arg2)
    local ges = arg2 or arg1
    if self._closing then return true end

    if self._close_dimen and ges.pos:intersectWith(self._close_dimen) then
        self:_flashAndDo("x", self._close_dimen, function() 
            self:_closeReturn()
        end)
        return true
    end

    if self._has_multiple_levels and self._filter_dimen and ges.pos:intersectWith(self._filter_dimen) then
        self:_flashAndDo("filter", self._filter_dimen, function()
            self._filter_level = (self._filter_level + 1) % 3
            self.refreshFilter()
            UIManager:setDirty(self, "ui", self._top_panel_dimen)
        end)
        return true
    end

    if self._preview_dimen and ges.pos:intersectWith(self._preview_dimen) then
        self:_returnToGrid(self._cur_page)
        return true
    end

    if self._prev_ch_dimen and ges.pos:intersectWith(self._prev_ch_dimen) then
        self:_flashAndDo("prev_ch", self._prev_ch_dimen, function()
            local p = self:_getPrevChapterPage()
            self:_previewPage(p, false)
        end)
        return true
    end

    if self._next_ch_dimen and ges.pos:intersectWith(self._next_ch_dimen) then
        self:_flashAndDo("next_ch", self._next_ch_dimen, function()
            local p = self:_getNextChapterPage()
            self:_previewPage(p, false)
        end)
        return true
    end

    if self._first_toc_dimen and ges.pos:intersectWith(self._first_toc_dimen) then
        if self._toc_page > 1 then
            self:_flashAndDo("first_toc", self._first_toc_dimen, function()
                self._toc_page = 1
                UIManager:setDirty(self, "ui", self.dimen)
            end)
        end
        return true
    end

    if self._prev_toc_dimen and ges.pos:intersectWith(self._prev_toc_dimen) then
        if self._toc_page > 1 then
            self:_flashAndDo("prev_toc", self._prev_toc_dimen, function()
                self._toc_page = self._toc_page - 1
                UIManager:setDirty(self, "ui", self.dimen)
            end)
        end
        return true
    end

    if self._next_toc_dimen and ges.pos:intersectWith(self._next_toc_dimen) then
        local total_pages = math.max(1, math.ceil(#self._filtered_toc / (self._items_per_page or 6)))
        if self._toc_page < total_pages then
            self:_flashAndDo("next_toc", self._next_toc_dimen, function()
                self._toc_page = self._toc_page + 1
                UIManager:setDirty(self, "ui", self.dimen)
            end)
        end
        return true
    end

    if self._last_toc_dimen and ges.pos:intersectWith(self._last_toc_dimen) then
        local total_pages = math.max(1, math.ceil(#self._filtered_toc / (self._items_per_page or 6)))
        if self._toc_page < total_pages then
            self:_flashAndDo("last_toc", self._last_toc_dimen, function()
                self._toc_page = total_pages
                UIManager:setDirty(self, "ui", self.dimen)
            end)
        end
        return true
    end

    if self._toc_rows then
        for _, row in ipairs(self._toc_rows) do
            if ges.pos:intersectWith(row.dimen) then
                if self._cur_page == row.page then
                    self:_returnToGrid(row.page)
                else
                    self:_previewPage(row.page, false)
                end
                return true
            end
        end
    end

    if ges.pos.y > self._top_panel_dimen.h and ges.pos.y < self._bar_dimen.y then
        if not (self._preview_dimen and ges.pos:intersectWith(self._preview_dimen)) and
           not (self._prev_ch_dimen and ges.pos:intersectWith(self._prev_ch_dimen)) and
           not (self._next_ch_dimen and ges.pos:intersectWith(self._next_ch_dimen)) then
            self:_closeReturn()
            return true
        end
    end

    if self._slider:handleTap(ges) then return true end

    return true
end

function ScrubberToc:onPan(arg1, arg2)
    local ges = arg2 or arg1
    if self._closing then return true end
    
    if self._slider:handlePan(ges) then
        if self._slider._dragging then
            self:_previewPage(self._slider.value, true)
            
            self._pan_watchdog_gen = (self._pan_watchdog_gen or 0) + 1
            local my_gen = self._pan_watchdog_gen
            UIManager:scheduleIn(0.6, function()
                if self._closing then return end
                if self._pan_watchdog_gen == my_gen and self._slider._dragging then
                    self._slider._dragging = false
                    self:_previewPage(self._slider.value, false)
                end
            end)
        end
        return true
    end
    return true
end

function ScrubberToc:onPanRelease(arg1, arg2)
    local ges = arg2 or arg1
    if self._closing then return true end
    
    local was_dragging = self._slider and self._slider._dragging
    if self._slider:handlePanRelease(ges) or was_dragging then
        if self._slider then self._slider._dragging = false end
        self:_previewPage(self._slider.value, false)
        return true
    end
    return true
end

function ScrubberToc:onSwipe(arg1, arg2)
    local ges = arg2 or arg1
    if self._closing then return true end
    
    if self._slider and self._slider._dragging then
        self._slider._dragging = false
        pcall(function() self._slider:handlePanRelease(ges) end)
        self:_previewPage(self._slider.value, false)
        return true 
    end

    local total_pages = math.max(1, math.ceil(#self._filtered_toc / (self._items_per_page or 6)))

    if ges.direction == "west" then
        if self._toc_page < total_pages then
            self._toc_page = self._toc_page + 1
            UIManager:setDirty(self, "ui", self._top_panel_dimen)
            return true
        end
    elseif ges.direction == "east" then
        if self._toc_page > 1 then
            self._toc_page = self._toc_page - 1
            UIManager:setDirty(self, "ui", self._top_panel_dimen)
            return true
        end
    elseif ges.direction == "south" then
        self:_closeReturn()
        return true
    end
    return false
end

function ScrubberToc:onRelease(arg1, arg2)
    local ges = arg2 or arg1
    
    local was_repeating = self._repeat_running
    self:_stopRepeatAction()
    
    if self._closing then return true end

    if self._repeat_running_id or was_repeating then
        self._repeat_running_id = nil
        self:_updatePreviewTile() 
        UIManager:setDirty(self, "ui", self.dimen)
    end

    if self._slider and self._slider._dragging then
        self._slider._dragging = false
        pcall(function() self._slider:handlePanRelease(ges) end)
        self:_previewPage(self._slider.value, false)
    end
    return true
end

function ScrubberToc:onHoldRelease(arg1, arg2)
    return self:onRelease(arg1, arg2)
end

function ScrubberToc:onCloseWidget()
    self._closing = true
    self:_stopRepeatAction()

    if self._preview_tile and self._preview_tile.is_scaled and self._preview_tile.bb then
        pcall(function() self._preview_tile.bb:free() end)
    end
    self._preview_tile = nil

    local widgets_to_free = { 
        self.tw_author, self.tw_x, self.tw_x_inv, self._slider,
        self.icon_wifi_0, self.icon_wifi_1, self.icon_wifi_2,
        self.icon_ch_prev, self.icon_ch_next,
        self.icon_toc_prev, self.icon_toc_next,
        self.icon_toc_first, self.icon_toc_last,
        self.icon_ch_prev_inv, self.icon_ch_next_inv,
        self.icon_toc_prev_inv, self.icon_toc_next_inv,
        self.icon_toc_first_inv, self.icon_toc_last_inv
    }
    
    if self.tw_titles then
        for _, tw in ipairs(self.tw_titles) do
            if tw and tw.free then pcall(function() tw:free() end) end
        end
    end
    
    for _, w in ipairs(widgets_to_free) do
        if w and w.free then pcall(function() w:free() end) end
    end
end

-- =========================================================================
-- SOPORTE PARA BOTONES FÍSICOS (Non-Touch)
-- =========================================================================

function ScrubberToc:onPrevPage()
    if self._closing then return true end
    self:_previewPage(math.max(1, self._cur_page - 1), false)
    return true
end

function ScrubberToc:onNextPage()
    if self._closing then return true end
    self:_previewPage(math.min(self._total_pages, self._cur_page + 1), false)
    return true
end

function ScrubberToc:onPrevChapterKey()
    if self._closing then return true end
    self:_previewPage(self:_getPrevChapterPage(), false)
    return true
end

function ScrubberToc:onNextChapterKey()
    if self._closing then return true end
    self:_previewPage(self:_getNextChapterPage(), false)
    return true
end

function ScrubberToc:onSelect()
    if self._closing then return true end
    self:_gotoPageDirectly(self._cur_page)
    return true
end

return ScrubberToc

--[[
    page_scrubber.koplugin/toc_landscape_view.lua
    Vista Apaisada (Landscape) para el ToC:
    - Altura de barra inferior estandarizada idéntica al Grid.
    - Separación sutil exacta entre el ToC y la barra inferior.
    - Lateral izquierdo limpio (sin contorno) con título en 2 líneas, miniatura y duración.
    - Lateral derecho con lista limpia, punto gris de origen y controles inferiores.
    - Barra inferior de 2 niveles: Nivel 1 (Botones con flecha dinámica) y Nivel 2 (Slider).
]]--

local Blitbuffer      = require("ffi/blitbuffer")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local TextWidget      = require("ui/widget/textwidget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Widget          = require("ui/widget/widget")

local _dict = {}
local _lang = "en"
if G_reader_settings then
    local l = G_reader_settings:readSetting("language")
    if type(l) == "string" then _lang = l:sub(1, 2) end
end
local function _(text) return _dict[text] or text end

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

local GlimpseDots = Widget:extend{
    nb = 1, cur = 1, dot_r = 3, pitch = 11, height = 10,
}
function GlimpseDots:getSize()
    local r_max = math.floor(self.dot_r * 1.5)
    return Geom:new{ w = math.floor((self.nb - 1) * self.pitch + 2 * r_max), h = math.floor(self.height) }
end
function GlimpseDots:paintTo(bb, x, y)
    local cy = y + math.floor(self.height / 2)
    local r_max = math.floor(self.dot_r * 1.5)
    local x0 = x + r_max
    for i = 1, self.nb do
        local cx = x0 + (i - 1) * self.pitch
        local is_active = (i == self.cur)
        local color = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
        local r = is_active and r_max or self.dot_r
        for dy = -r, r do
            local dx = math.floor(math.sqrt(math.max(0, r*r - dy*dy)))
            bb:paintRect(cx - dx, cy + dy, dx * 2, 1, color)
        end
    end
end

local GlimpsePill = WidgetContainer:extend{
    inner = nil, padding_h = 9, height = 21, radius = 8, stroke = 2,
}
function GlimpsePill:getSize()
    local inner = self.inner:getSize()
    return Geom:new{ w = math.floor(inner.w + 2 * self.padding_h), h = math.floor(math.max(self.height, inner.h)) }
end
function GlimpsePill:paintTo(bb, x, y)
    local size = self:getSize()
    paintRoundRect(bb, x, y, size.w, size.h, self.radius, Blitbuffer.COLOR_WHITE)
    local inner_size = self.inner:getSize()
    self.inner:paintTo(bb, x + math.floor((size.w - inner_size.w) / 2), y + math.floor((size.h - inner_size.h) / 2))
end
function GlimpsePill:free(...)
    if self.inner and self.inner.free then self.inner:free() end
    WidgetContainer.free(self, ...)
end

local function splitTitle(text, face_obj, max_w)
    local tw = TextWidget:new{ text = text, face = face_obj }
    local w = tw:getSize().w
    tw:free()
    if w <= max_w then return { text } end

    local words = {}
    for word in text:gmatch("%S+") do table.insert(words, word) end
    local line1, line2, line3 = "", "", ""
    for i, word in ipairs(words) do
        local test_line = (line1 == "") and word or (line1 .. " " .. word)
        local test_tw = TextWidget:new{ text = test_line, face = face_obj }
        local test_w = test_tw:getSize().w
        test_tw:free()
        if test_w <= max_w then
            line1 = test_line
        else
            for j = i, #words do
                local w2 = words[j]
                local test_line2 = (line2 == "") and w2 or (line2 .. " " .. w2)
                local test_tw2 = TextWidget:new{ text = test_line2, face = face_obj }
                local test_w2 = test_tw2:getSize().w
                test_tw2:free()
                if test_w2 <= max_w then
                    line2 = test_line2
                else
                    for k = j, #words do
                        line3 = (line3 == "") and words[k] or (line3 .. " " .. words[k])
                    end
                    break
                end
            end
            break
        end
    end
    if line3 ~= "" then return { line1, line2, line3 } end
    if line2 ~= "" then return { line1, line2 } end
    return { line1 }
end

local TocLandscapeView = {}

function TocLandscapeView.getThumbDims(toc)
    local sw, sh = toc._sw, toc._sh
    local S = toc.S
    local col_left_w = math.floor(sw * 0.34)
    local max_txt_w = col_left_w - S(32)
    local ratio = sw / sh
    local tw_box = math.floor(max_txt_w * 0.90)
    local th_box = math.floor(tw_box / ratio)
    return tw_box, th_box
end

function TocLandscapeView.updateLayout(toc)
    local sw, sh = toc._sw, toc._sh
    local S = toc.S

    -- 1. Barra inferior idéntica a grid_landscape_view
    local l1_h = S(38)
    local l2_h = S(38)
    local bar_pad_y = S(6)
    local bar_gap = S(4)
    local bar_h = bar_pad_y * 2 + l1_h + bar_gap + l2_h
    local bar_y = sh - bar_h

    toc._bar_dimen = Geom:new{ x = 0, y = bar_y, w = sw, h = bar_h }

    -- Espacio sutil exacto entre persiana y barra inferior
    local panel_gap = S(10)
    local panel_h = toc._is_expanded and sh or (bar_y - panel_gap)
    toc._top_panel_dimen = Geom:new{ x = 0, y = 0, w = sw, h = panel_h }

    -- Columnas izquierda y derecha
    local pad = S(16)
    local col_left_w = math.floor(sw * 0.34)
    local col_right_w = sw - col_left_w - (pad * 3)

    toc._lnd_left_dimen  = Geom:new{ x = pad, y = S(14), w = col_left_w, h = panel_h - S(24) }
    toc._lnd_right_dimen = Geom:new{ x = pad * 2 + col_left_w, y = S(14), w = col_right_w, h = panel_h - S(24) }

    -- Fila inferior de la persiana
    toc._bot_internal_h = S(44)
    toc._bot_internal_y = panel_h - toc._bot_internal_h - S(8)

    local btn_sz = S(38)

    -- Botón de subcapítulos (solo si el libro contiene niveles o subcapítulos)
    local has_subchapters = toc._has_subchapters
    if has_subchapters == nil then
        has_subchapters = toc.has_subchapters
    end
    if has_subchapters == nil and toc._max_depth then
        has_subchapters = (toc._max_depth > 0)
    end
    if has_subchapters == nil and toc._flat_toc then
        local min_d, max_d = nil, nil
        for _, item in ipairs(toc._flat_toc) do
            local d = item.depth or 0
            if not min_d or d < min_d then min_d = d end
            if not max_d or d > max_d then max_d = d end
        end
        has_subchapters = (min_d and max_d and max_d > min_d)
    end

    if has_subchapters then
        toc._filter_dimen = Geom:new{
            x = toc._lnd_right_dimen.x + S(6),
            y = toc._bot_internal_y + math.floor((toc._bot_internal_h - btn_sz) / 2),
            w = btn_sz,
            h = btn_sz
        }
    else
        toc._filter_dimen = nil
    end

    local right_edge = toc._lnd_right_dimen.x + toc._lnd_right_dimen.w - S(6)
    toc._close_dimen = Geom:new{
        x = right_edge - btn_sz,
        y = toc._bot_internal_y + math.floor((toc._bot_internal_h - btn_sz) / 2),
        w = btn_sz,
        h = btn_sz
    }

    toc._toggle_expand_dimen = Geom:new{
        x = toc._close_dimen.x - btn_sz - S(6),
        y = toc._close_dimen.y,
        w = btn_sz,
        h = btn_sz
    }

    -- Filas de capítulos
    toc._list_y = toc._lnd_right_dimen.y + S(4)
    toc._list_avail_h = toc._bot_internal_y - toc._list_y - S(6)
    local target_row_h = S(46)
    toc._items_per_page = math.max(2, math.floor(toc._list_avail_h / target_row_h))
    toc._row_h = math.floor(toc._list_avail_h / toc._items_per_page)

    local tw_box, th_box = TocLandscapeView.getThumbDims(toc)
    toc._thumb_req_w = tw_box
    toc._thumb_req_h = th_box

    local ld = toc._lnd_left_dimen
    local thumb_x = ld.x + math.floor((ld.w - tw_box) / 2)
    local thumb_y = ld.y + S(60)
    toc._preview_dimen = Geom:new{ x = thumb_x, y = thumb_y, w = tw_box, h = th_box }

    -- Botones de la barra inferior (Nivel 1)
    local pad_x = S(16)
    local l1_y = bar_y + bar_pad_y
    local b_sz = S(34)
    local gap_b = S(8)

    toc._prev_ch_dimen = nil
    toc._next_ch_dimen = nil

    -- 4 botones de navegación centrados exactamente debajo de los puntos de página del lateral derecho
    local rd_center_x = toc._lnd_right_dimen.x + math.floor(toc._lnd_right_dimen.w / 2)
    local right_4_w = b_sz * 4 + gap_b * 3
    local r_start = rd_center_x - math.floor(right_4_w / 2)

    toc._first_toc_dimen = Geom:new{ x = r_start, y = l1_y + math.floor((l1_h - b_sz)/2), w = b_sz, h = b_sz }
    toc._prev_toc_dimen  = Geom:new{ x = r_start + b_sz + gap_b, y = l1_y + math.floor((l1_h - b_sz)/2), w = b_sz, h = b_sz }
    toc._next_toc_dimen  = Geom:new{ x = r_start + (b_sz + gap_b) * 2, y = l1_y + math.floor((l1_h - b_sz)/2), w = b_sz, h = b_sz }
    toc._last_toc_dimen  = Geom:new{ x = r_start + (b_sz + gap_b) * 3, y = l1_y + math.floor((l1_h - b_sz)/2), w = b_sz, h = b_sz }
end

function TocLandscapeView.paint(toc, bb)
    local sw, sh = toc._sw, toc._sh
    local S = toc.S
    local pd = toc._top_panel_dimen
    local bd = toc._bar_dimen
    
    local tab_radius = S(24)
    local b_thick = S(3)

    -- Fondo blanco general
    bb:paintRect(0, 0, sw, sh, Blitbuffer.COLOR_WHITE)

    -- Persiana exterior limpia sin tramas ni sombras
    paintBottomRoundedTab(bb, 0, 0, sw, pd.h, tab_radius, Blitbuffer.COLOR_BLACK)
    paintBottomRoundedTab(bb, b_thick, 0, sw - (b_thick * 2), pd.h - b_thick, math.max(1, tab_radius - b_thick), Blitbuffer.COLOR_WHITE)

    -- =========================================================================
    -- 1. LATERAL IZQUIERDO (Limpio, sin recuadros)
    -- =========================================================================
    local ld = toc._lnd_left_dimen
    local cur_y = ld.y + S(4)
    local inner_pad = S(12)
    local max_txt_w = ld.w - (inner_pad * 2)

    local t_lines = splitTitle(toc.book_title, toc.font_title, max_txt_w)
    for _, line in ipairs(t_lines) do
        local tw = TextWidget:new{ text = line, face = toc.font_title, bold = true, fgcolor = Blitbuffer.COLOR_BLACK, max_width = max_txt_w, truncate_with_ellipsis = true }
        tw:paintTo(bb, ld.x + inner_pad, cur_y)
        cur_y = cur_y + tw:getSize().h + S(2)
        tw:free()
    end
    cur_y = cur_y + S(2)

    bb:paintRect(ld.x + inner_pad, cur_y, max_txt_w, 1, Blitbuffer.COLOR_LIGHT_GRAY)
    cur_y = cur_y + S(8)

    local tw_box, th_box = TocLandscapeView.getThumbDims(toc)
    local thumb_x = ld.x + math.floor((ld.w - tw_box) / 2)
    local thumb_y = cur_y
    toc._preview_dimen = Geom:new{ x = thumb_x, y = thumb_y, w = tw_box, h = th_box }

    if toc._preview_tile and toc._preview_tile.bb then
        local ptw, pth = toc._preview_tile.bb:getWidth(), toc._preview_tile.bb:getHeight()
        local bw = math.min(ptw, tw_box)
        local bh = math.min(pth, th_box)
        local ox = thumb_x + math.floor((tw_box - bw) / 2)
        local oy = thumb_y + math.floor((th_box - bh) / 2)
        bb:paintRect(thumb_x, thumb_y, tw_box, th_box, Blitbuffer.COLOR_WHITE)
        bb:blitFrom(toc._preview_tile.bb, ox, oy, 0, 0, bw, bh)
    else
        bb:paintRect(thumb_x, thumb_y, tw_box, th_box, Blitbuffer.COLOR_WHITE)
        bb:paintRect(thumb_x + math.floor(tw_box/2) - 1, thumb_y + math.floor(th_box/2) - 1, 2, 2, Blitbuffer.COLOR_GRAY)
    end

    cur_y = thumb_y + th_box + S(8)

    local ax = ld.x + inner_pad
    toc.tw_author.max_width = max_txt_w
    toc.tw_author:paintTo(bb, ax, cur_y)
    toc.tw_author:paintTo(bb, ax + 1, cur_y)
    toc.tw_author:paintTo(bb, ax, cur_y + 1)
    cur_y = cur_y + toc.tw_author:getSize().h + S(2)

    local is_scrubbing = (toc._slider and toc._slider._dragging) or toc._repeat_running
    if not is_scrubbing then
        local ch_idx = toc:_getActiveChapterIndex()
        local ch = toc._filtered_toc and toc._filtered_toc[ch_idx]
        if ch then
            local flat_idx = 1
            for i, fch in ipairs(toc._flat_toc) do
                if fch.page == ch.page and fch.title == ch.title then flat_idx = i; break end
            end
            local cur_depth = ch.depth or 0
            local next_p = toc._total_pages
            for j = flat_idx + 1, #toc._flat_toc do
                if (toc._flat_toc[j].depth or 0) <= cur_depth then
                    next_p = toc._flat_toc[j].page
                    break
                end
            end
            local pages_len = math.max(0, next_p - ch.page)
            local stats = toc.ui and toc.ui.statistics
            local time_str = (pages_len > 0 and stats and type(stats.getTimeForPages) == "function") and stats:getTimeForPages(pages_len) or nil

            if time_str and time_str ~= "" then
                if not toc._tw_lnd_time then
                    toc._tw_lnd_time = TextWidget:new{ text = "", face = toc.font_author, fgcolor = Blitbuffer.COLOR_DARK_GRAY }
                end
                toc._tw_lnd_time:setText(time_str)
                local tx = ld.x + inner_pad
                toc._tw_lnd_time:paintTo(bb, tx, cur_y)
                toc._tw_lnd_time:paintTo(bb, tx + 1, cur_y)
                toc._tw_lnd_time:paintTo(bb, tx, cur_y + 1)
            end
        end
    end

    -- =========================================================================
    -- 2. LATERAL DERECHO: Capítulos con punto gris de origen
    -- =========================================================================
    local rd = toc._lnd_right_dimen

    if not toc._tw_pnum_normal then
        toc._tw_pnum_normal = TextWidget:new{ text = "", face = toc.font_badge, fgcolor = Blitbuffer.COLOR_BLACK }
        toc._tw_pnum_bold   = TextWidget:new{ text = "", face = toc.font_badge, bold = true, fgcolor = Blitbuffer.COLOR_WHITE }
    end
    if not toc._tw_ch_normal then
        toc._tw_ch_normal = TextWidget:new{ text = "", face = toc.font_item, fgcolor = Blitbuffer.COLOR_BLACK, truncate_with_ellipsis = true }
        toc._tw_ch_bold   = TextWidget:new{ text = "", face = toc.font_item, bold = true, fgcolor = Blitbuffer.COLOR_WHITE, truncate_with_ellipsis = true }
    end

    local total_items = #toc._filtered_toc
    local total_pages = math.max(1, math.ceil(total_items / toc._items_per_page))
    if toc._toc_page > total_pages then toc._toc_page = total_pages end
    if toc._toc_page < 1 then toc._toc_page = 1 end

    local start_idx = (toc._toc_page - 1) * toc._items_per_page + 1
    local end_idx   = math.min(toc._toc_page * toc._items_per_page, total_items)
    local is_scrubbing = (toc._slider and toc._slider._dragging) or toc._repeat_running
    local active_ch_idx = is_scrubbing and -1 or toc:_getActiveChapterIndex()
    local origin_ch_idx = toc:_getChapterIndexForPage(toc._origin_page)

    toc._toc_rows = {}
    local r_y = toc._list_y

    for i = start_idx, end_idx do
        local entry = toc._filtered_toc[i]
        local is_act = (i == active_ch_idx)
        local is_origin_ch = (i == origin_ch_idx)
        local row_rect = Geom:new{ x = rd.x, y = r_y, w = rd.w, h = toc._row_h - S(4) }

        if is_act then
            paintRoundRect(bb, row_rect.x, row_rect.y, row_rect.w, row_rect.h, S(8), Blitbuffer.COLOR_BLACK)
        end

        local disp_p = tostring(entry.page)
        local scrubber = toc.parent_scrubber or toc._scrubber_helper
        if scrubber and type(scrubber._getDisplayPageInfo) == "function" then
            local ok, dp = pcall(function() return scrubber:_getDisplayPageInfo(entry.page) end)
            if ok and dp then disp_p = tostring(dp) end
        end

        local tw_p = is_act and toc._tw_pnum_bold or toc._tw_pnum_normal
        tw_p:setText(_("Page") .. " " .. disp_p)
        local psz = tw_p:getSize()
        tw_p:paintTo(bb, row_rect.x + row_rect.w - psz.w - S(10), row_rect.y + math.floor((row_rect.h - psz.h)/2))

        local tw_c = is_act and toc._tw_ch_bold or toc._tw_ch_normal
        local indent = (entry.depth or 0) * S(18)
        local ch_title = ((entry.depth or 0) > 1) and ("• " .. entry.title) or entry.title
        local origin_dot_w = is_origin_ch and S(14) or 0
        tw_c.max_width = row_rect.w - psz.w - indent - S(24) - origin_dot_w
        tw_c:setText(ch_title)
        
        local ch_sz = tw_c:getSize()
        local ch_x = row_rect.x + S(10) + indent
        local ch_y = row_rect.y + math.floor((row_rect.h - ch_sz.h)/2)
        tw_c:paintTo(bb, ch_x, ch_y)

        -- Punto gris de origen
        if is_origin_ch then
            local dot_color = is_act and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_DARK_GRAY
            if not toc._tw_origin_dot then
                toc._tw_origin_dot = TextWidget:new{ text = "•", face = toc.font_item, fgcolor = dot_color }
            else
                toc._tw_origin_dot.fgcolor = dot_color
            end
            local dot_y = row_rect.y + math.floor((row_rect.h - toc._tw_origin_dot:getSize().h) / 2)
            local dot_x = ch_x + ch_sz.w + S(6)
            toc._tw_origin_dot:paintTo(bb, dot_x, dot_y)
            toc._tw_origin_dot:paintTo(bb, dot_x + 1, dot_y)
            toc._tw_origin_dot:paintTo(bb, dot_x, dot_y + 1)
        end

        table.insert(toc._toc_rows, { dimen = row_rect, index = i, page = entry.page })
        r_y = r_y + toc._row_h
    end

    -- =========================================================================
    -- Controles inferiores: [WiFi] bien a la izquierda ... [Puntitos] ... [v] [X]
    -- =========================================================================
    if toc._filter_dimen then
        local fd = toc._filter_dimen
        local is_p = (toc._pressed_btn == "filter")
        local cur_wifi = (toc._filter_level == 0) and toc.icon_wifi_0 or ((toc._filter_level == 1) and toc.icon_wifi_1 or toc.icon_wifi_2)
        if not cur_wifi then cur_wifi = toc.icon_wifi_2 end
        local wsz = cur_wifi:getSize()
        local ix = fd.x + math.floor((fd.w - wsz.w)/2)
        local iy = fd.y + math.floor((fd.h - wsz.h)/2)
        if is_p then
            paintRoundRect(bb, fd.x, fd.y, fd.w, fd.h, S(8), Blitbuffer.COLOR_BLACK)
            bb:paintRect(ix, iy, wsz.w, wsz.h, Blitbuffer.COLOR_WHITE)
            cur_wifi:paintTo(bb, ix, iy)
            bb:invertRect(ix, iy, wsz.w, wsz.h)
        else
            cur_wifi:paintTo(bb, ix, iy)
        end
    end

    if total_pages > 1 then
        local dot_r = math.max(2, math.floor(S(2.5)))
        local pitch = S(11)
        local pill_widget = GlimpsePill:new{
            padding_h = S(9), height = S(21), radius = S(8), stroke = S(2),
            inner = GlimpseDots:new{ nb = total_pages, cur = toc._toc_page, pitch = math.floor(pitch), dot_r = dot_r, height = S(10) }
        }
        local psz = pill_widget:getSize()
        local px = rd.x + math.floor((rd.w - psz.w) / 2)
        local py = toc._bot_internal_y + math.floor((toc._bot_internal_h - psz.h) / 2)
        toc._pill_dimen = Geom:new{ x = px, y = py, w = psz.w, h = psz.h }
        toc._pill_info = { is_dots = true, nb = total_pages, pitch = pitch, r_max = math.floor(dot_r * 1.5), pad_h = S(9) }
        pill_widget:paintTo(bb, px, py)
        pill_widget:free()
    end

    if toc._toggle_expand_dimen then
        local td = toc._toggle_expand_dimen
        local is_p = (toc._pressed_btn == "toggle_expand")
        local icon_exp = toc._is_expanded and toc.icon_chevron_up or toc.icon_chevron_down
        local icon_exp_inv = toc._is_expanded and toc.icon_chevron_up_inv or toc.icon_chevron_down_inv
        local esz = icon_exp:getSize()
        local ex = td.x + math.floor((td.w - esz.w)/2)
        local ey = td.y + math.floor((td.h - esz.h)/2)
        if is_p then
            paintRoundRect(bb, td.x, td.y, td.w, td.h, S(8), Blitbuffer.COLOR_BLACK)
            icon_exp_inv:paintTo(bb, ex, ey)
        else
            icon_exp:paintTo(bb, ex, ey)
        end
    end

    if toc._close_dimen then
        local cd = toc._close_dimen
        local is_p = (toc._pressed_btn == "x")
        local xsz = toc.tw_x:getSize()
        local xx = cd.x + math.floor((cd.w - xsz.w)/2)
        local xy = cd.y + math.floor((cd.h - xsz.h)/2)
        if is_p then
            paintRoundRect(bb, cd.x, cd.y, cd.w, cd.h, S(8), Blitbuffer.COLOR_BLACK)
            toc.tw_x_inv:paintTo(bb, xx, xy)
        else
            toc.tw_x:paintTo(bb, xx, xy)
        end
    end

    -- =========================================================================
    -- 3. BARRA INFERIOR DE 2 NIVELES (Nivel 1: Botones | Nivel 2: Slider)
    -- =========================================================================
    if not toc._is_expanded then
        bb:paintRect(0, bd.y, sw, bd.h, Blitbuffer.COLOR_WHITE)
        bb:paintRect(0, bd.y, sw, S(2), Blitbuffer.COLOR_BLACK)

        local pad_x = S(16)
        local l1_h = S(38)
        local l2_h = S(38)
        local bar_gap = S(4)
        local bar_pad_y = S(6)
        local l1_y = bd.y + bar_pad_y

        local function drawBtnWithPress(btn_id, dim, widget, widget_inv, y_off, is_disabled)
            if not dim or not widget then return end
            local is_p = (toc._pressed_btn == btn_id and not is_disabled and btn_id ~= "prev_ch" and btn_id ~= "next_ch")
            local wsz = widget:getSize()
            local wx = dim.x + math.floor((dim.w - wsz.w)/2)
            local wy = dim.y + math.floor((dim.h - wsz.h)/2) + (y_off or 0)

            if is_disabled then
                widget.fgcolor = Blitbuffer.COLOR_LIGHT_GRAY
                widget:paintTo(bb, wx, wy)
                widget.fgcolor = Blitbuffer.COLOR_BLACK
            elseif is_p then
                paintRoundRect(bb, dim.x, dim.y, dim.w, dim.h, S(8), Blitbuffer.COLOR_BLACK)
                if widget_inv then
                    widget_inv:paintTo(bb, wx, wy)
                else
                    bb:paintRect(wx, wy, wsz.w, wsz.h, Blitbuffer.COLOR_WHITE)
                    widget.fgcolor = Blitbuffer.COLOR_BLACK
                    widget:paintTo(bb, wx, wy)
                    bb:invertRect(wx, wy, wsz.w, wsz.h)
                end
            else
                widget.fgcolor = Blitbuffer.COLOR_BLACK
                widget:paintTo(bb, wx, wy)
            end
        end

        local has_prev_toc = (toc._toc_page > 1)
        local has_next_toc = (toc._toc_page < total_pages)

        -- 1. Métricas del capítulo activo (Páginas, Marcadores y Destacados)
        local ch_idx = toc:_getActiveChapterIndex()
        local bm_cnt, hl_cnt = 0, 0
        local start_page, end_page
        if ch_idx and toc._filtered_toc and toc._filtered_toc[ch_idx] then
            local ch = toc._filtered_toc[ch_idx]
            local flat_idx = 1
            for i, fch in ipairs(toc._flat_toc) do
                if fch.page == ch.page and fch.title == ch.title then flat_idx = i; break end
            end
            local cur_depth = ch.depth or 0
            end_page = toc._total_pages
            for j = flat_idx + 1, #toc._flat_toc do
                local next_ch = toc._flat_toc[j]
                if (next_ch.depth or 0) <= cur_depth then
                    end_page = next_ch.page - 1
                    break
                end
            end
            start_page = ch.page
            if end_page < start_page then end_page = start_page end

            if toc.parent_scrubber and toc.parent_scrubber._cached_hl then
                for _, it in ipairs(toc.parent_scrubber._cached_hl) do
                    local p = it.page
                    if p and p >= start_page and p <= end_page then
                        hl_cnt = hl_cnt + 1
                    end
                end
            else
                local raw_anns = (toc.ui and toc.ui.annotation and toc.ui.annotation.annotations) or {}
                local doc = toc.ui and toc.ui.document
                local function getPage(item)
                    if not item or type(item) ~= "table" then return nil end
                    if item.pageno and tonumber(item.pageno) then return tonumber(item.pageno) end
                    if item.page and tonumber(item.page) then return tonumber(item.page) end
                    if item.pos0 and doc and doc.getPageFromXPointer then
                        local ok, p = pcall(function() return doc:getPageFromXPointer(item.pos0) end)
                        if ok and p then return tonumber(p) end
                    end
                    return nil
                end
                for _, it in ipairs(raw_anns) do
                    local p = getPage(it)
                    if p and p >= start_page and p <= end_page then
                        if it.drawer or it.highlight or (it.pos0 and it.pos1) or (it.text and it.text ~= "") then
                            hl_cnt = hl_cnt + 1
                        end
                    end
                end
            end

            local bms_seen = {}
            local function check_and_add_bm(p)
                if p and p >= start_page and p <= end_page and not bms_seen[p] then
                    bms_seen[p] = true
                    bm_cnt = bm_cnt + 1
                end
            end

            if toc.parent_scrubber and toc.parent_scrubber._getAllBookmarks then
                local all_b = toc.parent_scrubber:_getAllBookmarks()
                for _, bp in ipairs(all_b) do
                    check_and_add_bm(tonumber(bp))
                end
            else
                local raw_bms = (toc.ui and toc.ui.bookmark and (toc.ui.bookmark._bookmarks or toc.ui.bookmark.bookmarks)) or {}
                for k, v in pairs(raw_bms) do
                    local p = type(v) == "table" and (v.pageno or v.page) or tonumber(k)
                    check_and_add_bm(p)
                end
            end
        end

        -- Cálculo de páginas con soporte para subcapítulos y stable pages (pagemap)
        local ch_pages = 0
        if start_page and end_page then
            local ui = toc.ui
            if ui and ui.pagemap and type(ui.pagemap.wantsPageLabels) == "function" and ui.pagemap:wantsPageLabels() and ui.toc and type(ui.toc.getPagePagemapIndex) == "function" then
                local p_start = ui.toc:getPagePagemapIndex(start_page)
                local p_end = ui.toc:getPagePagemapIndex(end_page + 1) or ui.toc:getPagePagemapIndex(end_page)
                if p_start and p_end and p_end >= p_start then
                    ch_pages = (p_end - p_start)
                    if ch_pages == 0 then ch_pages = 1 end
                end
            end
            if ch_pages == 0 then
                ch_pages = math.max(1, end_page - start_page + 1)
            end
        else
            ch_pages = toc._total_pages or 1
        end

        local l1_cy = l1_y + math.floor(l1_h / 2)
        local icon_gap = S(6)
        local group_gap = S(18)
        local cur_left_x = pad_x + S(8)

        -- 2. LATERAL IZQUIERDO: [book-open-text.svg] N, [gravity-ui--bookmark.svg] N y [pin.svg] N
        if toc.icon_stat_pages and toc._tw_stat_pages_cnt then
            toc._tw_stat_pages_cnt:setText(tostring(ch_pages))
            toc._tw_stat_pages_cnt.fgcolor = (ch_pages > 0) and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY

            local isz = toc.icon_stat_pages:getSize()
            local tsz = toc._tw_stat_pages_cnt:getSize()

            toc.icon_stat_pages:paintTo(bb, cur_left_x, l1_cy - math.floor(isz.h / 2))
            toc._tw_stat_pages_cnt:paintTo(bb, cur_left_x + isz.w + icon_gap, l1_cy - math.floor(tsz.h / 2))
            cur_left_x = cur_left_x + isz.w + icon_gap + tsz.w + group_gap
        end

        if toc.icon_stat_bm and toc._tw_stat_bm_cnt then
            toc._tw_stat_bm_cnt:setText(tostring(bm_cnt))
            local col = (bm_cnt > 0) and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
            toc._tw_stat_bm_cnt.fgcolor = col

            local isz = toc.icon_stat_bm:getSize()
            local tsz = toc._tw_stat_bm_cnt:getSize()

            toc.icon_stat_bm:paintTo(bb, cur_left_x, l1_cy - math.floor(isz.h / 2))
            toc._tw_stat_bm_cnt:paintTo(bb, cur_left_x + isz.w + icon_gap, l1_cy - math.floor(tsz.h / 2))
            cur_left_x = cur_left_x + isz.w + icon_gap + tsz.w + group_gap
        end

        if toc.icon_stat_hl and toc._tw_stat_hl_cnt then
            toc._tw_stat_hl_cnt:setText(tostring(hl_cnt))
            local col = (hl_cnt > 0) and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
            toc._tw_stat_hl_cnt.fgcolor = col

            local isz = toc.icon_stat_hl:getSize()
            local tsz = toc._tw_stat_hl_cnt:getSize()

            toc.icon_stat_hl:paintTo(bb, cur_left_x, l1_cy - math.floor(isz.h / 2))
            toc._tw_stat_hl_cnt:paintTo(bb, cur_left_x + isz.w + icon_gap, l1_cy - math.floor(tsz.h / 2))
            cur_left_x = cur_left_x + isz.w + icon_gap + tsz.w + S(24)
        end

        -- 3. CENTRO: Botón volver al origen (Page X)
        if toc._cur_page ~= toc._origin_page then
            local disp_origin = tostring(toc._origin_page)
            local scrubber = toc.parent_scrubber or toc._scrubber_helper
            if scrubber and type(scrubber._getDisplayPageInfo) == "function" then
                local ok, dp = pcall(function() return scrubber:_getDisplayPageInfo(toc._origin_page) end)
                if ok and dp then disp_origin = tostring(dp) end
            end

            local origin_on_left
            if toc.is_rtl then
                origin_on_left = (toc._cur_page < toc._origin_page)
            else
                origin_on_left = (toc._cur_page > toc._origin_page)
            end

            local arrow_char = origin_on_left and "‹ " or " ›"
            local back_str = origin_on_left and (arrow_char .. _("Page") .. " " .. disp_origin)
                                             or (_("Page") .. " " .. disp_origin .. arrow_char)

            if not toc._tw_back_origin then
                toc._tw_back_origin = TextWidget:new{ text = back_str, face = Font:getFace("cfont", toc.S_BOTTOM_GRAY or S(13)), bold = true, fgcolor = Blitbuffer.COLOR_DARK_GRAY }
            else
                toc._tw_back_origin:setText(back_str)
            end

            local bsz = toc._tw_back_origin:getSize()
            local bx = cur_left_x
            local by = l1_y + math.floor((l1_h - bsz.h) / 2)
            toc._grid_back_dimen = Geom:new{ x = bx, y = l1_y, w = bsz.w + S(16), h = l1_h }

            local is_back_p = (toc._pressed_btn == "grid_back")
            if is_back_p then
                paintRoundRect(bb, bx, l1_y, bsz.w + S(16), l1_h, S(6), Blitbuffer.COLOR_BLACK)
                toc._tw_back_origin.fgcolor = Blitbuffer.COLOR_WHITE
                toc._tw_back_origin:paintTo(bb, bx + S(8), by)
            else
                toc._tw_back_origin.fgcolor = Blitbuffer.COLOR_DARK_GRAY
                toc._tw_back_origin:paintTo(bb, bx + S(8), by)
                toc._tw_back_origin:paintTo(bb, bx + S(9), by)
                toc._tw_back_origin:paintTo(bb, bx + S(8), by + 1)
            end
        else
            toc._grid_back_dimen = nil
        end

        -- 4. LATERAL DERECHO: [<<] [<] [>] [>>]
        drawBtnWithPress("first_toc", toc._first_toc_dimen, toc.icon_toc_first, toc.icon_toc_first_inv, 0, not has_prev_toc)
        drawBtnWithPress("prev_toc", toc._prev_toc_dimen, toc.icon_toc_prev, toc.icon_toc_prev_inv, 0, not has_prev_toc)
        drawBtnWithPress("next_toc", toc._next_toc_dimen, toc.icon_toc_next, toc.icon_toc_next_inv, 0, not has_next_toc)
        drawBtnWithPress("last_toc", toc._last_toc_dimen, toc.icon_toc_last, toc.icon_toc_last_inv, 0, not has_next_toc)

        -- Nivel 2: Slider a todo lo ancho con altura coincidente con Grid
        local l2_y = l1_y + l1_h + bar_gap
        local slider_x = pad_x
        local slider_w = sw - (pad_x * 2)
        toc._slider.width = slider_w
        toc._slider.value = toc._cur_page
        toc._slider:paintTo(bb, slider_x, l2_y + math.floor((l2_h - toc._slider:getSize().h)/2))
    end
end

return TocLandscapeView

--[[
    page_scrubber.koplugin/grid_six_landscape_view.lua
    Modo Apaisado (Landscape) para la vista 3x2 (Six Grid):
    - 6 páginas a proporción real idéntica al Grid Landscape sin achatamiento.
    - Barra inferior de 2 niveles estandarizada a la misma altura que Grid y Split.
    - Botones ‹ y › precalculados en posición fija para evitar saltos.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")

local _dict = {}
local _lang = "en"
if G_reader_settings then
    local l = G_reader_settings:readSetting("language")
    if type(l) == "string" then _lang = l:sub(1, 2) end
end
local function _(text) return _dict[text] or text end

local GridSixLandscapeView = {}

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

local function paintTripleText(tw, bb, x, y)
    if not tw then return end
    tw:paintTo(bb, x, y)
    tw:paintTo(bb, x + 1, y)
    tw:paintTo(bb, x, y + 1)
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

local function getLandscapeAspectRatio(scrubber)
    local doc = scrubber.ui and scrubber.ui.document
    if doc and type(doc.getPageDimension) == "function" then
        local ok, dim = pcall(function() return doc:getPageDimension(scrubber._cur_page) end)
        if ok and dim and dim.w and dim.h and dim.w > 0 and dim.h > 0 then
            return dim.w / dim.h
        end
    end
    return scrubber._sw / scrubber._sh
end

function GridSixLandscapeView.getSlotDimens(scrubber)
    local sw, sh = scrubber._sw, scrubber._sh
    local S = scrubber.S
    local top_h = scrubber._top_bar_dimen.h
    local bar_h = S(6) * 2 + S(38) * 2 + S(4)
    local avail_h = sh - top_h - bar_h - S(16)
    local avail_w = sw - S(32)

    local gap_x = S(16)
    local gap_y = S(12)
    local cols, rows = 3, 2

    local ratio = getLandscapeAspectRatio(scrubber)
    local max_cell_w = math.floor((avail_w - gap_x * (cols - 1)) / cols)
    local max_cell_h = math.floor((avail_h - gap_y * (rows - 1)) / rows)

    local cell_w = max_cell_w
    local cell_h = math.floor(cell_w / ratio)

    if cell_h > max_cell_h then
        cell_h = max_cell_h
        cell_w = math.floor(cell_h * ratio)
    end

    local grid_w = cell_w * cols + gap_x * (cols - 1)
    local grid_h = cell_h * rows + gap_y * (rows - 1)
    local start_x = math.floor((sw - grid_w) / 2)
    local start_y = top_h + S(8) + math.floor((avail_h - grid_h) / 2)

    local is_rtl = scrubber.is_rtl == true
    local slots = {}
    for r = 0, rows - 1 do
        for c = 0, cols - 1 do
            local col = is_rtl and (cols - 1 - c) or c
            table.insert(slots, Geom:new{
                x = start_x + col * (cell_w + gap_x),
                y = start_y + r * (cell_h + gap_y),
                w = cell_w,
                h = cell_h
            })
        end
    end
    return slots
end

function GridSixLandscapeView.paint(scrubber, bb)
    scrubber:_updateTexts()

    local sw, sh = scrubber._sw, scrubber._sh
    local S = scrubber.S
    local top_h = scrubber._top_bar_dimen.h
    local font_badge = Font:getFace("cfont", S(12))

    -- 1. Barra inferior estandarizada (2 niveles)
    local l1_h = S(38)
    local l2_h = S(38)
    local bar_pad_y = S(6)
    local bar_gap = S(4)
    local bar_h = bar_pad_y * 2 + l1_h + bar_gap + l2_h
    local bar_y = sh - bar_h

    scrubber._bar_dimen = Geom:new{ x = 0, y = bar_y, w = sw, h = bar_h }
    scrubber._grid_dimen = Geom:new{ x = 0, y = top_h, w = sw, h = bar_y - top_h }

    bb:paintRect(0, top_h, sw, bar_y - top_h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(0, bar_y, sw, bar_h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(0, bar_y, sw, S(2), Blitbuffer.COLOR_BLACK)

    -- 2. Matriz de 6 miniaturas a escala proporcional real
    local slots = GridSixLandscapeView.getSlotDimens(scrubber)
    local all_bms = scrubber:_getAllBookmarks() or {}

    for idx = 1, 6 do
        local rect = slots[idx]
        local slot = scrubber._grid_tiles[idx]
        local is_origin = (slot and slot.page and tonumber(slot.page) == tonumber(scrubber._origin_page))
        local border = is_origin and S(3) or S(1)

        bb:paintRect(rect.x, rect.y, rect.w, rect.h, Blitbuffer.COLOR_WHITE)

        if slot and slot.page then
            if slot.tile_bb then
                local tw, th = slot.tile_bb:getWidth(), slot.tile_bb:getHeight()
                local render_bb = slot.tile_bb
                local must_free = false
                if math.abs(tw - rect.w) > 4 or math.abs(th - rect.h) > 4 then
                    local ok, sc = pcall(function() return slot.tile_bb:scale(rect.w, rect.h) end)
                    if ok and sc then render_bb = sc; must_free = true end
                end

                local bw = render_bb:getWidth()
                local bh = render_bb:getHeight()
                local ox = rect.x + math.floor((rect.w - bw) / 2)
                local oy = rect.y + math.floor((rect.h - bh) / 2)

                bb:blitFrom(render_bb, ox, oy, 0, 0, bw, bh)
                if must_free then pcall(function() render_bb:free() end) end

                local is_bmed = false
                for _, bmp in ipairs(all_bms) do
                    if tonumber(bmp) == tonumber(slot.page) then is_bmed = true; break end
                end

                if is_bmed then
                    local rw, rh = S(22), S(38)
                    local rx = rect.x + rect.w - rw - S(10) - border
                    local ry = rect.y + border

                    local mask_x = rx - S(2)
                    local mask_y = ry
                    local mask_w = (rect.x + rect.w - border) - mask_x
                    local mask_h = S(24)

                    bb:paintRect(mask_x, mask_y, mask_w, mask_h, Blitbuffer.COLOR_WHITE)
                    drawBookmarkRibbon(bb, rx, ry, rw, rh, Blitbuffer.COLOR_BLACK)
                end

                bb:paintBorder(rect.x, rect.y, rect.w, rect.h, border, Blitbuffer.COLOR_BLACK, 0)

                -- Pastilla con número de página
                if not scrubber._tw_gsix_page then
                    scrubber._tw_gsix_page = TextWidget:new{ text = "", face = font_badge, fgcolor = Blitbuffer.COLOR_WHITE, padding = 0 }
                end
                local disp_p = scrubber:_getDisplayPageInfo(slot.page)
                scrubber._tw_gsix_page:setText(tostring(disp_p))
                local tsz = scrubber._tw_gsix_page:getSize()
                local badge_h = tsz.h + S(4)
                local badge_w = math.max(tsz.w + S(10), badge_h)
                local bx = rect.x + math.floor((rect.w - badge_w) / 2)
                local by = rect.y + rect.h - badge_h

                paintRoundRect(bb, bx, by, badge_w, badge_h, math.floor(badge_h / 2), Blitbuffer.COLOR_BLACK)
                scrubber._tw_gsix_page:paintTo(bb, bx + math.floor((badge_w - tsz.w)/2), by + math.floor((badge_h - tsz.h)/2))
            elseif slot.error then
                bb:paintBorder(rect.x, rect.y, rect.w, rect.h, border, Blitbuffer.COLOR_BLACK, 0)
                if not scrubber._tw_grid_error then
                    scrubber._tw_grid_error = TextWidget:new{ text = "!", face = Font:getFace("cfont", S(32)), fgcolor = Blitbuffer.COLOR_BLACK }
                end
                local etsz = scrubber._tw_grid_error:getSize()
                scrubber._tw_grid_error:paintTo(bb, rect.x + math.floor((rect.w - etsz.w)/2), rect.y + math.floor((rect.h - etsz.h)/2))
            elseif slot.loading then
                bb:paintBorder(rect.x, rect.y, rect.w, rect.h, border, Blitbuffer.COLOR_BLACK, 0)
                bb:paintRect(rect.x + math.floor(rect.w/2) - 1, rect.y + math.floor(rect.h/2) - 1, 2, 2, Blitbuffer.COLOR_GRAY)
            end
        end
    end

    -- 3. Barra de navegación inferior
    local pad_x = S(16)
    local l1_y = bar_y + bar_pad_y
    local ch_btn_sz = S(34)
    scrubber._prev_ch_dimen = Geom:new{ x = pad_x, y = l1_y + math.floor((l1_h - ch_btn_sz)/2), w = ch_btn_sz, h = ch_btn_sz }
    scrubber._next_ch_dimen = Geom:new{ x = sw - pad_x - ch_btn_sz, y = l1_y + math.floor((l1_h - ch_btn_sz)/2), w = ch_btn_sz, h = ch_btn_sz }

    local function drawBtn(btn_id, dim, widget, y_off, is_disabled)
        if not dim or not widget then return end
        local is_p = (scrubber._pressed_btn == btn_id and not is_disabled and btn_id ~= "gsix_prev" and btn_id ~= "gsix_next")
        local wsz = widget:getSize()
        local wx = dim.x + math.floor((dim.w - wsz.w)/2)
        local wy = dim.y + math.floor((dim.h - wsz.h)/2) + (y_off or 0)

        if is_disabled then
            widget.fgcolor = Blitbuffer.COLOR_LIGHT_GRAY
            widget:paintTo(bb, wx, wy)
        elseif is_p then
            local pad_p = S(6)
            paintRoundRect(bb, wx - pad_p, wy - pad_p, wsz.w + pad_p*2, wsz.h + pad_p*2, S(8), Blitbuffer.COLOR_BLACK)
            bb:paintRect(wx, wy, wsz.w, wsz.h, Blitbuffer.COLOR_WHITE)
            widget.fgcolor = Blitbuffer.COLOR_BLACK
            widget:paintTo(bb, wx, wy)
            bb:invertRect(wx, wy, wsz.w, wsz.h)
        else
            widget.fgcolor = Blitbuffer.COLOR_BLACK
            widget:paintTo(bb, wx, wy)
        end
    end

    -- Nivel 1: Capítulos y slider
    drawBtn("ch_l", scrubber._prev_ch_dimen, scrubber.tw_ch_l, -S(1), false)
    drawBtn("ch_r", scrubber._next_ch_dimen, scrubber.tw_ch_r, -S(1), false)

    local slider_x = scrubber._prev_ch_dimen.x + ch_btn_sz + S(12)
    local slider_w = scrubber._next_ch_dimen.x - S(12) - slider_x
    scrubber._slider.width = slider_w
    scrubber._slider.value = scrubber._cur_page
    scrubber._slider:paintTo(bb, slider_x, l1_y + math.floor((l1_h - scrubber._slider:getSize().h)/2))

    -- Nivel 2: Botones ‹ y › con posición fija precalculada
    local l2_y = l1_y + l1_h + bar_gap
    local btn_w = S(34)
    local mark_sz = S(36)
    local isz_info = scrubber.tw_info and scrubber.tw_info:getSize() or { w = 0, h = 0 }
    local info_x = sw - pad_x - isz_info.w

    local cx = math.floor(sw / 2)
    local origin_slot_w = S(116)
    local gap_center = S(10)
    local half_slot = math.floor(origin_slot_w / 2) + gap_center

    scrubber._gsix_prev_dimen = Geom:new{ x = cx - half_slot - btn_w, y = l2_y + math.floor((mark_sz - btn_w)/2), w = btn_w, h = btn_w }
    scrubber._gsix_next_dimen = Geom:new{ x = cx + half_slot, y = l2_y + math.floor((mark_sz - btn_w)/2), w = btn_w, h = btn_w }

    drawBtn("gsix_prev", scrubber._gsix_prev_dimen, scrubber.icon_gs_chevron_left, 0, scrubber._cur_page <= 1)
    drawBtn("gsix_next", scrubber._gsix_next_dimen, scrubber.icon_gs_chevron_right, 0, scrubber._cur_page >= scrubber._total_pages)

    -- Botón dinámico en el centro exacto (‹ Page X ›) sin empujar a los chevrons
    local has_back = (scrubber._cur_page ~= scrubber._origin_page)
    if has_back then
        local disp_origin = scrubber:_getDisplayPageInfo(scrubber._origin_page)
        local origin_on_left
        if scrubber.is_rtl then
            origin_on_left = (scrubber._cur_page < scrubber._origin_page)
        else
            origin_on_left = (scrubber._cur_page > scrubber._origin_page)
        end

        local arrow_char = origin_on_left and "‹ " or " ›"
        local back_str = origin_on_left and (arrow_char .. _("Page") .. " " .. tostring(disp_origin))
                                         or (_("Page") .. " " .. tostring(disp_origin) .. arrow_char)

        if not scrubber._tw_gsix_origin then
            scrubber._tw_gsix_origin = TextWidget:new{ text = back_str, face = Font:getFace("cfont", scrubber.S_BOTTOM_GRAY or S(13)), bold = true, fgcolor = Blitbuffer.COLOR_DARK_GRAY }
        else
            scrubber._tw_gsix_origin:setText(back_str)
        end
        local bsz = scrubber._tw_gsix_origin:getSize()
        local bw = bsz.w + S(14)
        local bx = cx - math.floor(bw / 2)
        scrubber._gsix_origin_dimen = Geom:new{ x = bx, y = l2_y, w = bw, h = mark_sz }

        local is_orig_p = (scrubber._pressed_btn == "gsix_origin")
        if is_orig_p then
            paintRoundRect(bb, bx, l2_y, bw, mark_sz, S(6), Blitbuffer.COLOR_BLACK)
            scrubber._tw_gsix_origin.fgcolor = Blitbuffer.COLOR_WHITE
            scrubber._tw_gsix_origin:paintTo(bb, bx + S(7), l2_y + math.floor((mark_sz - bsz.h)/2))
        else
            scrubber._tw_gsix_origin.fgcolor = Blitbuffer.COLOR_DARK_GRAY
            paintTripleText(scrubber._tw_gsix_origin, bb, bx + S(7), l2_y + math.floor((mark_sz - bsz.h)/2))
        end
    else
        scrubber._gsix_origin_dimen = nil
    end

    -- Título del capítulo anclado a la izquierda con ancho delimitado
    if scrubber.tw_chapter then
        scrubber.tw_chapter.max_width = scrubber._gsix_prev_dimen.x - pad_x - S(12)
        scrubber.tw_chapter:paintTo(bb, pad_x, l2_y + math.floor((mark_sz - scrubber.tw_chapter:getSize().h)/2))
    end

    -- Rango de páginas fijo a la derecha
    if scrubber.tw_info then
        paintTripleText(scrubber.tw_info, bb, info_x, l2_y + math.floor((mark_sz - isz_info.h)/2))
    end
end

function GridSixLandscapeView.onTap(scrubber, ges)
    local slots = GridSixLandscapeView.getSlotDimens(scrubber)
    local S = scrubber.S
    for idx = 1, 6 do
        local rect = slots[idx]
        if ges.pos:intersectWith(rect) then
            local slot = scrubber._grid_tiles[idx]
            if slot and slot.page then
                local rw, rh = S(22), S(38)
                local bm_w = math.max(S(36), rw + S(16))
                local bm_h = math.max(S(42), rh + S(10))
                local bm_touch_rect = Geom:new{
                    x = rect.x + rect.w - bm_w,
                    y = rect.y,
                    w = bm_w,
                    h = bm_h
                }
                if ges.pos:intersectWith(bm_touch_rect) then
                    scrubber:_safeBookmarkToggle(slot.page)
                    return true
                end

                scrubber:_gotoPage(slot.page)
                scrubber:_closeStay()
            end
            return true
        end
    end
    return false
end

return GridSixLandscapeView

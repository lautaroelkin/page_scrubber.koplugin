--[[
    page_scrubber.koplugin/grid_landscape_view.lua
    Modo Apaisado (Landscape):
    - Full Page activado: Las 3 páginas completas entran en pantalla.
    - Full Page desactivado: Carrusel con la página del medio completa y las laterales asomando cortadas por los bordes de la pantalla.
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

local GridLandscapeView = {}

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

local function isFullPage()
    if not G_reader_settings then return false end
    if G_reader_settings.isTrue then
        return G_reader_settings:isTrue("page_scrubber_full_page_grid")
    end
    local val = G_reader_settings:readSetting("page_scrubber_full_page_grid")
    return val == true or val == "true" or val == 1
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

function GridLandscapeView.getThumbDims(scrubber)
    local sw, sh = scrubber._sw, scrubber._sh
    local S = scrubber.S
    local top_h = scrubber._top_bar_dimen.h
    local bar_h = S(6) * 2 + S(38) * 2 + S(4)
    local avail_h = sh - top_h - bar_h - S(16)
    local gap = S(16)
    local pad_x = S(16)

    local ratio = getLandscapeAspectRatio(scrubber)

    if isFullPage() then
        local max_col_w = math.floor((sw - (pad_x * 2) - (gap * 2)) / 3)
        local fit_w = max_col_w
        local fit_h = math.floor(fit_w / ratio)
        if fit_h > avail_h then
            fit_h = avail_h
            fit_w = math.floor(fit_h * ratio)
        end
        return fit_w, fit_h
    else
        local item_h = avail_h
        local item_w = math.floor(item_h * ratio)
        return item_w, item_h
    end
end

function GridLandscapeView.paint(scrubber, bb)
    scrubber:_updateTexts()

    local sw, sh = scrubber._sw, scrubber._sh
    local S = scrubber.S
    local top_h = scrubber._top_bar_dimen.h

    -- 1. Barra inferior (2 líneas de controles)
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

    -- 2. Posicionamiento según el modo
    local gap = S(16)
    local avail_h = bar_y - top_h - S(16)
    local full = isFullPage()
    local item_w, item_h = GridLandscapeView.getThumbDims(scrubber)

    local mid_x = math.floor((sw - item_w) / 2)
    local start_y = top_h + S(8) + math.floor((avail_h - item_h) / 2)

    local start_x
    if full then
        local total_w = (item_w * 3) + (gap * 2)
        start_x = math.floor((sw - total_w) / 2)
    else
        start_x = mid_x - (item_w + gap)
    end

    local all_bms = scrubber:_getAllBookmarks()
    scrubber._center_bm_touch_dimen = nil
    scrubber._slot_dimens = {}

    for idx = 1, 3 do
        local slot = scrubber._grid_tiles[idx]
        local is_cur = (idx == 2)
        local border = is_cur and S(3) or S(1)

        local box_x = start_x + (idx - 1) * (item_w + gap)
        local box_y = start_y
        local box_w = item_w
        local box_h = item_h

        scrubber._slot_dimens[idx] = Geom:new{ x = box_x, y = box_y, w = box_w, h = box_h }

        if slot and slot.page and slot.tile_bb then
            local tw, th = slot.tile_bb:getWidth(), slot.tile_bb:getHeight()

            local render_bb = slot.tile_bb
            local must_free = false
            if math.abs(tw - box_w) > 4 or math.abs(th - box_h) > 4 then
                local ok, sc = pcall(function() return slot.tile_bb:scale(box_w, box_h) end)
                if ok and sc then render_bb = sc; must_free = true end
            end

            local ox = box_x
            local oy = box_y
            local src_x = 0
            local src_y = 0
            local blit_w = box_w
            local blit_h = box_h

            if ox < 0 then
                src_x = -ox
                blit_w = blit_w + ox
                ox = 0
            end
            if ox + blit_w > sw then
                blit_w = sw - ox
            end

            if blit_w > 0 and blit_h > 0 then
                bb:paintRect(ox, oy, blit_w, blit_h, Blitbuffer.COLOR_WHITE)
                bb:blitFrom(render_bb, ox, oy, src_x, src_y, blit_w, blit_h)
            end

            if must_free then pcall(function() render_bb:free() end) end

            if scrubber._grid_flash_idx == idx and blit_w > 0 then
                bb:paintRect(ox, oy, blit_w, blit_h, Blitbuffer.COLOR_BLACK)
            end

            local is_bmed = false
            for _, bmp in ipairs(all_bms) do
                if tonumber(bmp) == tonumber(slot.page) then is_bmed = true; break end
            end

            if is_cur then
                local bw, bh = S(28), S(46)
                local bx = box_x + box_w - bw - S(14) - border
                local by = box_y + border
                scrubber._center_bm_touch_dimen = Geom:new{ x = bx - S(10), y = by, w = bw + S(20), h = bh + S(20) }
            end

            if is_bmed and (box_x + box_w) <= sw and (box_x + box_w) >= 0 then
                local bw, bh = S(28), S(46)
                local bx = box_x + box_w - bw - S(14) - border
                local by = box_y + border

                local mask_x = bx - S(2)
                local mask_y = by
                local mask_w = (box_x + box_w - border) - mask_x
                local mask_h = S(26)

                bb:paintRect(mask_x, mask_y, mask_w, mask_h, Blitbuffer.COLOR_WHITE)
                drawBookmarkRibbon(bb, bx, by, bw, bh, Blitbuffer.COLOR_BLACK)
            end

            -- Puntito gris en la esquina superior izquierda de la página de origen
            if tonumber(slot.page) == tonumber(scrubber._origin_page) then
                local dot_sz = S(8)
                local dot_off = S(8)
                local dx = box_x + dot_off + border
                local dy = box_y + dot_off + border
                paintRoundRect(bb, dx, dy, dot_sz, dot_sz, math.floor(dot_sz / 2), Blitbuffer.COLOR_DARK_GRAY)
            end

            bb:paintBorder(box_x, box_y, box_w, box_h, border, Blitbuffer.COLOR_BLACK, 0)
        else
            local ox = math.max(0, box_x)
            local ow = math.min(sw - ox, (box_x + box_w) - ox)
            if ow > 0 then
                bb:paintRect(ox, box_y, ow, box_h, Blitbuffer.COLOR_WHITE)
                if slot and slot.error then
                    if not scrubber._tw_grid_error then
                        scrubber._tw_grid_error = TextWidget:new{ text = "!", face = Font:getFace("cfont", S(32)), fgcolor = Blitbuffer.COLOR_BLACK }
                    end
                    local etsz = scrubber._tw_grid_error:getSize()
                    scrubber._tw_grid_error:paintTo(bb, box_x + math.floor((box_w - etsz.w) / 2), box_y + math.floor((box_h - etsz.h) / 2))
                else
                    if (box_x + math.floor(box_w / 2)) >= 0 and (box_x + math.floor(box_w / 2)) <= sw then
                        bb:paintRect(box_x + math.floor(box_w / 2) - 1, box_y + math.floor(box_h / 2) - 1, 2, 2, Blitbuffer.COLOR_GRAY)
                    end
                end
            end
            bb:paintBorder(box_x, box_y, box_w, box_h, border, Blitbuffer.COLOR_BLACK, 0)
        end
    end

    scrubber._gridSlotDimen = function(self, idx)
        return self._slot_dimens[idx] or Geom:new{ x = start_x + (idx - 1) * (item_w + gap), y = start_y, w = item_w, h = item_h }
    end

    -- 3. Barra inferior de navegación
    local pad_x = S(16)
    local l1_y = bar_y + bar_pad_y
    local ch_btn_sz = S(34)
    scrubber._prev_ch_dimen = Geom:new{ x = pad_x, y = l1_y + math.floor((l1_h - ch_btn_sz)/2), w = ch_btn_sz, h = ch_btn_sz }
    scrubber._next_ch_dimen = Geom:new{ x = sw - pad_x - ch_btn_sz, y = l1_y + math.floor((l1_h - ch_btn_sz)/2), w = ch_btn_sz, h = ch_btn_sz }

    local function drawBtnWithPress(btn_id, dim, widget, y_off, is_disabled)
        if not dim or not widget then return end
        -- Excluimos "ctrl_mark" para que no dibuje el recuadro negro (el cambio de icono ya es feedback visual)
        local is_p = (scrubber._pressed_btn == btn_id and not is_disabled and btn_id ~= "ctrl_mark")
        local wsz = widget:getSize()
        local wx = dim.x + math.floor((dim.w - wsz.w)/2)
        local wy = dim.y + math.floor((dim.h - wsz.h)/2) + (y_off or 0)

        if is_disabled then return end
        if is_p then
            local is_bm_ctrl = (btn_id == "ctrl_prev" or btn_id == "ctrl_next")
            local btn_rad = is_bm_ctrl and math.floor(math.min(dim.w, dim.h) / 2) or S(8)
            local bg_y = dim.y
            paintRoundRect(bb, dim.x, bg_y, dim.w, dim.h, btn_rad, Blitbuffer.COLOR_BLACK)
            if widget.text then
                widget.fgcolor = Blitbuffer.COLOR_WHITE
                widget:paintTo(bb, wx, wy)
                widget.fgcolor = Blitbuffer.COLOR_BLACK
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

    drawBtnWithPress("ch_l", scrubber._prev_ch_dimen, scrubber.tw_ch_l, -S(1))
    drawBtnWithPress("ch_r", scrubber._next_ch_dimen, scrubber.tw_ch_r, -S(1))

    local slider_x = scrubber._prev_ch_dimen.x + ch_btn_sz + S(12)
    local slider_w = scrubber._next_ch_dimen.x - S(12) - slider_x
    scrubber._slider.width = slider_w
    scrubber._slider.value = scrubber._cur_page
    scrubber._slider:paintTo(bb, slider_x, l1_y + math.floor((l1_h - scrubber._slider:getSize().h)/2))

    local l2_y = l1_y + l1_h + bar_gap
    scrubber.ctrl_y_pos = l2_y
    local mark_sz = S(36)
    local side_sz = S(36)
    local ctrl_sp = S(12)
    local total_ctrl_w = side_sz * 2 + mark_sz + ctrl_sp * 2
    local ctrl_x = math.floor((sw - total_ctrl_w) / 2)
    scrubber._ctrl_row_x0 = ctrl_x
    scrubber._ctrl_row_x1 = ctrl_x + total_ctrl_w
    scrubber._ctrl_row_h = mark_sz

    scrubber._ctrl_prev_dimen = Geom:new{ x = ctrl_x, y = l2_y, w = side_sz, h = side_sz }
    scrubber._ctrl_mark_dimen = Geom:new{ x = ctrl_x + side_sz + ctrl_sp, y = l2_y, w = mark_sz, h = mark_sz }
    scrubber._ctrl_next_dimen = Geom:new{ x = ctrl_x + side_sz + mark_sz + ctrl_sp * 2, y = l2_y, w = side_sz, h = side_sz }

    local has_prev_bm = scrubber:_findPrevBookmark() ~= nil
    drawBtnWithPress("ctrl_prev", scrubber._ctrl_prev_dimen, scrubber.tw_ctrl_prev, 0, not has_prev_bm)

    local is_bmed_page = scrubber:_isCurrentPageBookmarked(scrubber._cur_page)
    scrubber.tw_ctrl_mark = is_bmed_page and scrubber.icon_mark_filled or scrubber.icon_mark_empty
    drawBtnWithPress("ctrl_mark", scrubber._ctrl_mark_dimen, scrubber.tw_ctrl_mark, -S(1), false)

    local has_next_bm = scrubber:_findNextBookmark() ~= nil
    drawBtnWithPress("ctrl_next", scrubber._ctrl_next_dimen, scrubber.tw_ctrl_next, 0, not has_next_bm)

    local has_back = math.abs(scrubber._cur_page - scrubber._origin_page) >= 10
    scrubber._grid_back_dimen = nil

    local origin_on_left = scrubber.is_rtl and (scrubber._cur_page < scrubber._origin_page) or (scrubber._cur_page > scrubber._origin_page)
    local isz_info = scrubber.tw_info and scrubber.tw_info:getSize() or { w = 0, h = 0 }
    local info_x = sw - pad_x - isz_info.w

    if has_back then
        local disp_orig = scrubber:_getDisplayPageInfo(scrubber._origin_page)
        local arrow_char = origin_on_left and "‹ " or " ›"
        local back_str = origin_on_left and (arrow_char .. _("Page") .. " " .. tostring(disp_orig))
                                         or (_("Page") .. " " .. tostring(disp_orig) .. arrow_char)

        if not scrubber._tw_lnd_back then
            scrubber._tw_lnd_back = TextWidget:new{ text = back_str, face = Font:getFace("cfont", scrubber.S_BOTTOM_GRAY or S(13)), bold = true, fgcolor = Blitbuffer.COLOR_DARK_GRAY }
        else
            scrubber._tw_lnd_back:setText(back_str)
        end
        local bsz = scrubber._tw_lnd_back:getSize()
        local bw = bsz.w + S(14)
        local is_back_p = (scrubber._pressed_btn == "grid_back")

        local bx = scrubber._ctrl_row_x1 + S(10)
        scrubber._grid_back_dimen = Geom:new{ x = bx, y = l2_y, w = bw, h = mark_sz }

        if is_back_p then
            paintRoundRect(bb, bx, l2_y, bw, mark_sz, S(6), Blitbuffer.COLOR_BLACK)
            scrubber._tw_lnd_back.fgcolor = Blitbuffer.COLOR_WHITE
            scrubber._tw_lnd_back:paintTo(bb, bx + S(7), l2_y + math.floor((mark_sz - bsz.h)/2))
        else
            scrubber._tw_lnd_back.fgcolor = Blitbuffer.COLOR_DARK_GRAY
            paintTripleText(scrubber._tw_lnd_back, bb, bx + S(7), l2_y + math.floor((mark_sz - bsz.h)/2))
        end
    end

    if scrubber.tw_chapter then
        scrubber.tw_chapter.max_width = ctrl_x - pad_x - S(12)
        scrubber.tw_chapter:paintTo(bb, pad_x, l2_y + math.floor((mark_sz - scrubber.tw_chapter:getSize().h)/2))
    end
    if scrubber.tw_info then
        paintTripleText(scrubber.tw_info, bb, info_x, l2_y + math.floor((mark_sz - isz_info.h)/2))
    end
end

return GridLandscapeView

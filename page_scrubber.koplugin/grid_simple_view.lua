--[[
    page_scrubber.koplugin/grid_simple_view.lua
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local os         = require("os")

-- 1. Importamos la matemática de bordes redondeados
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

local GridSimpleView = {}

function GridSimpleView.paint(scrubber, bb)
    local sw, sh = scrubber._sw, scrubber._sh
    local S = scrubber.S
    local available_y = scrubber._bar_dimen.y

    local max_p_w = math.floor(sw * 0.72)
    local max_p_h = math.floor(available_y * 0.78)

    local target_h = max_p_h
    local target_w = math.floor(target_h * (sw / sh))
    if target_w > max_p_w then
        target_w = max_p_w
        target_h = math.floor(target_w * (sh / sw))
    end

    local pad_x = S(8)
    local arrow_area_w = S(38)
    local top_offset = S(55) 
    local bot_offset = S(12)

    local panel_w = target_w + (arrow_area_w * 2) + (pad_x * 2)
    local panel_h = target_h + top_offset + bot_offset
    local panel_x = math.floor((sw - panel_w) / 2)
    local panel_y = math.floor((available_y - panel_h) / 2)

    local page_x = panel_x + pad_x + arrow_area_w
    local page_y = panel_y + top_offset

    scrubber._gs_panel_dimen = Geom:new{ x = panel_x, y = panel_y, w = panel_w, h = panel_h }

    -- 2. MAGIA DE DISEÑO: Bordes redondeados y sombra offset dura
    local shadow_offset = S(6)
    local radius = S(12)
    local border = S(3)

    -- Sombreado desfasado (Gris Oscuro para pantallas e-ink)
    paintRoundRect(bb, panel_x + shadow_offset, panel_y + shadow_offset, panel_w, panel_h, radius, Blitbuffer.COLOR_DARK_GRAY)
    -- Borde negro (fondo de la tarjeta)
    paintRoundRect(bb, panel_x, panel_y, panel_w, panel_h, radius, Blitbuffer.COLOR_BLACK)
    -- Relleno blanco
    paintRoundRect(bb, panel_x + border, panel_y + border, panel_w - border*2, panel_h - border*2, math.max(1, radius - border), Blitbuffer.COLOR_WHITE)

    local time_str = os.date("%H:%M")
    local tw_clock = TextWidget:new{ text = time_str, face = Font:getFace("cfont", S(13)), fgcolor = Blitbuffer.COLOR_BLACK }
    local csz = tw_clock:getSize()
    local clock_x = panel_x + math.floor((panel_w - csz.w) / 2)
    local clock_y = panel_y + S(15)

    tw_clock:paintTo(bb, clock_x, clock_y)
    tw_clock:paintTo(bb, clock_x + 1, clock_y)
    tw_clock:paintTo(bb, clock_x, clock_y + 1)
    tw_clock:paintTo(bb, clock_x + 1, clock_y + 1)
    tw_clock:free()

    local slot = scrubber._grid_tiles[2]
    if slot and slot.page then
        if slot.tile_bb then
            local tw, th = slot.tile_bb:getWidth(), slot.tile_bb:getHeight()
            local render_bb = slot.tile_bb
            local must_free = false

            if math.abs(tw - target_w) > 6 or math.abs(th - target_h) > 6 then
                local ok, sc = pcall(function() return slot.tile_bb:scale(target_w, target_h) end)
                if ok and sc then
                    render_bb = sc
                    must_free = true
                    tw, th = render_bb:getWidth(), render_bb:getHeight()
                end
            end

            local src_x, src_y = 0, 0
            local blit_w, blit_h = tw, th
            if blit_w > target_w then src_x = math.floor((blit_w - target_w) / 2); blit_w = target_w end
            if blit_h > target_h then src_y = math.floor((blit_h - target_h) / 2); blit_h = target_h end

            local ox = page_x + math.floor((target_w - blit_w) / 2)
            local oy = page_y + math.floor((target_h - blit_h) / 2)

            if blit_w > 0 and blit_h > 0 then
                bb:blitFrom(render_bb, ox, oy, src_x, src_y, blit_w, blit_h)
            end
            if must_free then pcall(function() render_bb:free() end) end
        elseif slot.error then
            local err_tw = TextWidget:new{ text = "!", face = Font:getFace("cfont", S(32)), fgcolor = Blitbuffer.COLOR_BLACK }
            local etsz = err_tw:getSize()
            err_tw:paintTo(bb, page_x + math.floor((target_w - etsz.w) / 2), page_y + math.floor((target_h - etsz.h) / 2))
            err_tw:free()
        elseif slot.loading then
            bb:paintRect(page_x + math.floor(target_w / 2) - 1, page_y + math.floor(target_h / 2) - 1, 2, 2, Blitbuffer.COLOR_GRAY)
        end
    end

    -- 3. Dibujamos los Chevrons SVG (con tamaño doble exclusivo para el grid)
    local icon_l = scrubber.icon_gs_chevron_left or scrubber.icon_chevron_left
    local icon_r = scrubber.icon_gs_chevron_right or scrubber.icon_chevron_right
    local lsz = icon_l and icon_l:getSize() or {w = S(44), h = S(44)}
    local rsz = icon_r and icon_r:getSize() or {w = S(44), h = S(44)}

    local left_arrow_x = panel_x + pad_x + math.floor((arrow_area_w - lsz.w) / 2)
    local right_arrow_x = page_x + target_w + math.floor((arrow_area_w - rsz.w) / 2)
    
    local arrow_l_y = panel_y + math.floor((panel_h - lsz.h) / 2)
    local arrow_r_y = panel_y + math.floor((panel_h - rsz.h) / 2)

    if icon_l then
        icon_l.fgcolor = Blitbuffer.COLOR_BLACK
        icon_l:paintTo(bb, left_arrow_x, arrow_l_y)
        icon_l:paintTo(bb, left_arrow_x + 1, arrow_l_y) 
    end
    if icon_r then
        icon_r.fgcolor = Blitbuffer.COLOR_BLACK
        icon_r:paintTo(bb, right_arrow_x, arrow_r_y)
        icon_r:paintTo(bb, right_arrow_x + 1, arrow_r_y) 
    end

    -- 4. Dibujamos la Cruz SVG para cerrar (tamaño ajustado al grid simple)
    local icon_x = scrubber.icon_gs_x or scrubber.tw_x
    local xsz = icon_x and icon_x:getSize() or {w = S(36), h = S(36)}
    
    local xx = panel_x + panel_w - xsz.w - S(16)
    local xy = clock_y + math.floor((csz.h - xsz.h) / 2)

    local touch_btn_size = math.max(xsz.w, xsz.h) + S(20)
    scrubber._gs_close_dimen = Geom:new{
        x = xx - math.floor((touch_btn_size - xsz.w)/2),
        y = xy - math.floor((touch_btn_size - xsz.h)/2),
        w = touch_btn_size,
        h = touch_btn_size
    }

    if icon_x then
        icon_x.fgcolor = Blitbuffer.COLOR_BLACK
        icon_x:paintTo(bb, xx, xy)
    end

    scrubber._gs_prev_dimen = Geom:new{ x = panel_x, y = panel_y, w = pad_x + arrow_area_w, h = panel_h }
    local next_y_start = scrubber._gs_close_dimen.y + scrubber._gs_close_dimen.h
    scrubber._gs_next_dimen = Geom:new{ 
        x = page_x + target_w, 
        y = next_y_start, 
        w = panel_x + panel_w - (page_x + target_w), 
        h = panel_y + panel_h - next_y_start 
    }
    scrubber._gs_page_dimen = Geom:new{ x = page_x, y = page_y, w = target_w, h = target_h }
end

return GridSimpleView

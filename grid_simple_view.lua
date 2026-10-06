--[[
    page_scrubber.koplugin/grid_simple_view.lua
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local os         = require("os")

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

local GridSimpleView = {}

local function getPageAspectRatio(scrubber)
    local doc = scrubber.ui and scrubber.ui.document
    if doc and type(doc.getPageDimension) == "function" then
        local ok, dim = pcall(function() return doc:getPageDimension(scrubber._cur_page) end)
        if ok and dim and dim.w and dim.h and dim.w > 0 and dim.h > 0 then
            return dim.w / dim.h
        end
    end
    -- En vertical, sw / sh da una proporción correcta (< 1) para el fallback de una página
    return scrubber._sw / scrubber._sh
end

-- Altura del efecto de ‹ › como fracción de la altura de la página (más chico = más bajo).
-- Siempre queda centrado en la altura de las flechas y es igual para los dos lados.
local SIDE_PILL_H_RATIO = 0.40

-- Pinta un icono en BLANCO sobre el efecto negro. Se dibuja el icono (en negro) en un buffer
-- temporal de grises y solo se escriben en pantalla los píxeles con "tinta", con su
-- antialiasing. Así no queda ningún recuadro ni esquinas del SVG.
-- clip (opcional): rectángulo fuera del cual no se escribe nada.
local function paintIconWhite(bb, icon, x, y, double, clip)
    local sz = icon:getSize()
    local w, h = sz.w + 2, sz.h
    local ok = pcall(function()
        local tmp = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
        tmp:fill(Blitbuffer.COLOR_WHITE)
        icon.fgcolor = Blitbuffer.COLOR_BLACK
        icon:paintTo(tmp, 0, 0)
        if double then icon:paintTo(tmp, 1, 0) end
        for py = 0, h - 1 do
            local dy = y + py
            if not clip or (dy >= clip.y and dy < clip.y + clip.h) then
                for px = 0, w - 1 do
                    local dx = x + px
                    if not clip or (dx >= clip.x and dx < clip.x + clip.w) then
                        local ink = 255 - tmp:getPixel(px, py):getColor8().a
                        if ink > 8 then
                            bb:setPixel(dx, dy, Blitbuffer.Color8(ink))
                        end
                    end
                end
            end
        end
        tmp:free()
    end)
    if not ok then
        icon.fgcolor = Blitbuffer.COLOR_WHITE
        icon:paintTo(bb, x, y)
        if double then icon:paintTo(bb, x + 1, y) end
    end
end

-- Margen (en dp) entre las puntas de la ✕ y el borde del círculo. Subilo para agrandar.
local X_PRESS_PAD_DP = 5

-- Radio mínimo (px) del círculo que encierra toda la tinta del icono. Se mide una sola vez.
local _ink_r_cache = {}
local function inkRadius(icon)
    local sz = icon:getSize()
    local key = sz.w .. "x" .. sz.h
    if _ink_r_cache[key] then return _ink_r_cache[key] end
    local r = math.ceil(math.sqrt((sz.w / 2) ^ 2 + (sz.h / 2) ^ 2))   -- plan B: diagonal
    pcall(function()
        local tmp = Blitbuffer.new(sz.w, sz.h, Blitbuffer.TYPE_BB8)
        tmp:fill(Blitbuffer.COLOR_WHITE)
        icon:paintTo(tmp, 0, 0)
        local cx, cy = sz.w / 2, sz.h / 2
        local m = 0
        for py = 0, sz.h - 1 do
            for px = 0, sz.w - 1 do
                if 255 - tmp:getPixel(px, py):getColor8().a > 8 then
                    local dx, dy = px + 0.5 - cx, py + 0.5 - cy
                    local d2 = dx * dx + dy * dy
                    if d2 > m then m = d2 end
                end
            end
        end
        tmp:free()
        if m > 0 then r = math.ceil(math.sqrt(m)) end
    end)
    _ink_r_cache[key] = r
    return r
end

-- Zona (y radio) del efecto al apretar, calculada con las áreas táctiles de la última
-- pintada. which: "close" (círculo), "prev" / "next" (todo el espacio tocable).
function GridSimpleView.pressRect(scrubber, which)
    local S = scrubber.S
    local pn = scrubber._gs_panel_dimen
    if not pn then return nil end
    local inset = S(2) + S(4)            -- borde de la tarjeta + aire
    local rad = S(14)
    local x, y, w, h

    -- Los dos botones ‹ › son simétricos: misma altura, centrados en la altura de las
    -- flechas, y siempre dentro de la zona entre la ✕ y el borde inferior de la página
    -- (por encima del porcentaje y las páginas).
    local function side_y_range()
        local nd = scrubber._gs_next_dimen
        local pg = scrubber._gs_page_dimen
        if not (nd and pg) then return nil end
        local min_top = nd.y + S(2)
        local max_bottom = pg.y + pg.h
        local h = math.floor(pg.h * SIDE_PILL_H_RATIO)
        h = math.min(h, max_bottom - min_top)
        local cy = pn.y + math.floor(pn.h / 2)       -- centro de las flechas
        local top = cy - math.floor(h / 2)
        if top < min_top then top = min_top end
        if top + h > max_bottom then top = max_bottom - h end
        return top, h
    end

    if which == "close" then
        local cd = scrubber._gs_close_dimen
        if not cd then return nil end
        -- Diámetro = diagonal del recuadro del icono (+ aire), así las esquinas del SVG
        -- quedan siempre dentro del círculo y no se ven "puntitas" a los costados.
        local icon = scrubber.icon_gs_x or scrubber.tw_x
        local isz = icon and icon:getSize() or { w = S(36), h = S(36) }
        local d = 2 * ((icon and inkRadius(icon) or math.floor(isz.w / 2)) + S(X_PRESS_PAD_DP))
        x = cd.x + math.floor((cd.w - d) / 2)
        y = cd.y + math.floor((cd.h - d) / 2)
        w, h = d, d
        rad = math.floor(d / 2)          -- círculo
    elseif which == "prev" then
        local d = scrubber._gs_prev_dimen
        if not d then return nil end
        local ty, th = side_y_range()
        if not ty then return nil end
        x = d.x + inset
        y = ty
        w = d.w - inset          -- hasta el borde de la página
        h = th
    elseif which == "next" then
        local d = scrubber._gs_next_dimen
        if not d then return nil end
        local ty, th = side_y_range()
        if not ty then return nil end
        x = d.x                  -- desde el borde de la página
        y = ty
        w = (pn.x + pn.w - inset) - x
        h = th
    else
        return nil
    end

    if w <= 0 or h <= 0 then return nil end
    return Geom:new{ x = x, y = y, w = w, h = h }, rad
end

function GridSimpleView.paint(scrubber, bb)
    local sw, sh = scrubber._sw, scrubber._sh
    local S = scrubber.S
    local available_y = scrubber._bar_dimen.y

    local max_p_w = math.floor(sw * 0.72)
    local max_p_h = math.floor(available_y * 0.78)

    -- Tarjeta fija base: proporcional a la pantalla para mantener los botones estables.
    local target_h = max_p_h
    local target_w = math.floor(target_h * (sw / sh))
    if target_w > max_p_w then
        target_w = max_p_w
        target_h = math.floor(target_w * (sh / sw))
    end

    local pad_x = S(8)
    local arrow_area_w = S(38)
    local top_offset = S(55)
    local bot_offset = S(34)

    local panel_w = target_w + (arrow_area_w * 2) + (pad_x * 2)
    local panel_h = target_h + top_offset + bot_offset
    local panel_x = math.floor((sw - panel_w) / 2)
    local panel_y = math.floor((available_y - panel_h) / 2)

    local page_x = panel_x + pad_x + arrow_area_w
    local page_y = panel_y + top_offset

    scrubber._gs_panel_dimen = Geom:new{ x = panel_x, y = panel_y, w = panel_w, h = panel_h }

    local shadow_offset = S(5)
    local radius = S(18)
    local border = S(2)

    -- Sombra gris clásica offset inferior
    paintRoundRect(bb, panel_x, panel_y + shadow_offset, panel_w, panel_h, radius, Blitbuffer.COLOR_DARK_GRAY)
    -- Contorno negro de la tarjeta
    paintRoundRect(bb, panel_x, panel_y, panel_w, panel_h, radius, Blitbuffer.COLOR_BLACK)
    -- Relleno blanco interior
    paintRoundRect(bb, panel_x + border, panel_y + border, panel_w - border*2, panel_h - border*2, math.max(1, radius - border), Blitbuffer.COLOR_WHITE)

    -- Efecto al apretar: ✕ circular; ‹ › ocupan todo su espacio tocable, con bordes redondeados.
    -- Se pinta antes que iconos y textos para que queden por encima.
    if scrubber._gs_pressed and scrubber._gs_pressed ~= "close" then
        local pr, prad = GridSimpleView.pressRect(scrubber, scrubber._gs_pressed)
        if pr then
            paintRoundRect(bb, pr.x, pr.y, pr.w, pr.h, prad, Blitbuffer.COLOR_BLACK)
        end
    end

    local time_str = os.date("%H:%M")
    
    if not scrubber._tw_gs_clock then
        scrubber._tw_gs_clock = TextWidget:new{ text = "", face = Font:getFace("cfont", S(13)), fgcolor = Blitbuffer.COLOR_BLACK }
    end
    scrubber._tw_gs_clock.text = nil
    scrubber._tw_gs_clock:setText(time_str)

    local csz = scrubber._tw_gs_clock:getSize()
    local clock_x = panel_x + math.floor((panel_w - csz.w) / 2)
    local clock_y = panel_y + S(15)

    scrubber._tw_gs_clock:paintTo(bb, clock_x, clock_y)
    scrubber._tw_gs_clock:paintTo(bb, clock_x + 1, clock_y)
    scrubber._tw_gs_clock:paintTo(bb, clock_x, clock_y + 1)
    scrubber._tw_gs_clock:paintTo(bb, clock_x + 1, clock_y + 1)

    local slot = scrubber._grid_tiles[2]
    if slot and slot.page then
        if slot.tile_bb then
            local tw, th = slot.tile_bb:getWidth(), slot.tile_bb:getHeight()
            local render_bb = slot.tile_bb
            local must_free = false

            -- ESCALADO PROPORCIONAL ESTRICTO: evita achatamientos
            local scale_factor = math.min(target_w / tw, target_h / th)
            local new_w = math.max(1, math.floor(tw * scale_factor))
            local new_h = math.max(1, math.floor(th * scale_factor))

            if math.abs(tw - new_w) > 4 or math.abs(th - new_h) > 4 then
                local ok, sc = pcall(function() return slot.tile_bb:scale(new_w, new_h) end)
                if ok and sc then
                    render_bb = sc
                    must_free = true
                    tw, th = new_w, new_h
                end
            end

            local src_x, src_y = 0, 0
            local blit_w, blit_h = tw, th
            if blit_w > target_w then src_x = math.floor((blit_w - target_w) / 2); blit_w = target_w end
            if blit_h > target_h then src_y = math.floor((blit_h - target_h) / 2); blit_h = target_h end

            local ox = page_x + math.floor((target_w - blit_w) / 2)
            local oy = page_y + math.floor((target_h - blit_h) / 2)

            bb:paintRect(page_x, page_y, target_w, target_h, Blitbuffer.COLOR_WHITE)

            if blit_w > 0 and blit_h > 0 then
                bb:blitFrom(render_bb, ox, oy, src_x, src_y, blit_w, blit_h)
            end
            if must_free then pcall(function() render_bb:free() end) end
        elseif slot.error then
            if not scrubber._tw_gs_error then
                scrubber._tw_gs_error = TextWidget:new{ text = "!", face = Font:getFace("cfont", S(32)), fgcolor = Blitbuffer.COLOR_BLACK }
            end
            local etsz = scrubber._tw_gs_error:getSize()
            scrubber._tw_gs_error:paintTo(bb, page_x + math.floor((target_w - etsz.w) / 2), page_y + math.floor((target_h - etsz.h) / 2))
        elseif slot.loading then
            bb:paintRect(page_x + math.floor(target_w / 2) - 1, page_y + math.floor(target_h / 2) - 1, 2, 2, Blitbuffer.COLOR_GRAY)
        end
    end

    -- Máscara blanca en la esquina superior derecha para tapar el dogear nativo de KOReader
    if scrubber:_isCurrentPageBookmarked(scrubber._cur_page) then
        local mask_sz = S(28)
        bb:paintRect(page_x + target_w - mask_sz, page_y, mask_sz, mask_sz, Blitbuffer.COLOR_WHITE)
    end

    local icon_l = scrubber.icon_gs_chevron_left or scrubber.icon_chevron_left
    local icon_r = scrubber.icon_gs_chevron_right or scrubber.icon_chevron_right
    local lsz = icon_l and icon_l:getSize() or {w = S(44), h = S(44)}
    local rsz = icon_r and icon_r:getSize() or {w = S(44), h = S(44)}

    local left_arrow_x = panel_x + pad_x + math.floor((arrow_area_w - lsz.w) / 2)
    local right_arrow_x = page_x + target_w + math.floor((arrow_area_w - rsz.w) / 2)
    
    local arrow_l_y = panel_y + math.floor((panel_h - lsz.h) / 2)
    local arrow_r_y = panel_y + math.floor((panel_h - rsz.h) / 2)

    if icon_l then
        if scrubber._gs_pressed == "prev" then
            paintIconWhite(bb, icon_l, left_arrow_x, arrow_l_y, true, (GridSimpleView.pressRect(scrubber, "prev")))
        else
            icon_l.fgcolor = Blitbuffer.COLOR_BLACK
            icon_l:paintTo(bb, left_arrow_x, arrow_l_y)
            icon_l:paintTo(bb, left_arrow_x + 1, arrow_l_y)
        end
    end
    if icon_r then
        if scrubber._gs_pressed == "next" then
            paintIconWhite(bb, icon_r, right_arrow_x, arrow_r_y, true, (GridSimpleView.pressRect(scrubber, "next")))
        else
            icon_r.fgcolor = Blitbuffer.COLOR_BLACK
            icon_r:paintTo(bb, right_arrow_x, arrow_r_y)
            icon_r:paintTo(bb, right_arrow_x + 1, arrow_r_y)
        end
    end

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

    if icon_x and scrubber._gs_pressed ~= "close" then
        icon_x.fgcolor = Blitbuffer.COLOR_BLACK
        icon_x:paintTo(bb, xx, xy)
    end

    -- Máscara blanca en la esquina superior derecha de la página (tapa la orejita nativa)
    local is_cur_bmed = scrubber:_isCurrentPageBookmarked(scrubber._cur_page)
    if is_cur_bmed then
        local mask_sz = S(28)
        bb:paintRect(page_x + target_w - mask_sz, page_y, mask_sz, mask_sz, Blitbuffer.COLOR_WHITE)
    end

    -- Indicadores en la cabecera de la ventana (a la misma altura que la ✕)
    local header_x = panel_x + S(16)
    if is_cur_bmed then
        local bm_icon = scrubber.icon_pol_bm or scrubber.icon_mark_filled
        if bm_icon then
            local bmsz = bm_icon:getSize()
            local bmy = xy + math.floor((xsz.h - bmsz.h) / 2)
            bm_icon.fgcolor = Blitbuffer.COLOR_BLACK
            bm_icon:paintTo(bb, header_x, bmy)
            header_x = header_x + bmsz.w + S(8)
        end
    end

    -- Punto gris en la cabecera solo en la página de origen
    if tonumber(scrubber._cur_page) == tonumber(scrubber._origin_page) then
        local dot_sz = S(8)
        local dot_y = xy + math.floor((xsz.h - dot_sz) / 2)
        paintRoundRect(bb, header_x, dot_y, dot_sz, dot_sz, math.floor(dot_sz / 2), Blitbuffer.COLOR_DARK_GRAY)
    end

    local next_y_start = scrubber._gs_close_dimen.y + scrubber._gs_close_dimen.h
    scrubber._gs_prev_dimen = Geom:new{
        x = panel_x,
        y = next_y_start,
        w = pad_x + arrow_area_w,
        h = panel_y + panel_h - next_y_start,
    }
    scrubber._gs_next_dimen = Geom:new{ 
        x = page_x + target_w, 
        y = next_y_start, 
        w = panel_x + panel_w - (page_x + target_w), 
        h = panel_y + panel_h - next_y_start 
    }
    scrubber._gs_page_dimen = Geom:new{ x = page_x, y = page_y, w = target_w, h = target_h }

    -- ✕ apretada: círculo + icono blanco al final, para que ni la página ni la máscara del
    -- marcador lo tapen. El icono se pinta solo en sus píxeles (sin recuadro), así no se ven
    -- las esquinas del SVG.
    if icon_x and scrubber._gs_pressed == "close" then
        local pr, prad = GridSimpleView.pressRect(scrubber, "close")
        if pr then
            paintRoundRect(bb, pr.x, pr.y, pr.w, pr.h, prad, Blitbuffer.COLOR_BLACK)
            paintIconWhite(bb, icon_x, xx, xy, false, pr)
        end
    end
end

return GridSimpleView

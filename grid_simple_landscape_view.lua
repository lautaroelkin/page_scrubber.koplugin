--[[
    page_scrubber.koplugin/grid_simple_landscape_view.lua
    Modo Simple Grid Apaisado (Landscape):
    - Hoja a escala real (idéntica a la pantalla y al libro) sin achatamiento.
    - Porcentaje y páginas (% · Pág. X / Y) al pie de la tarjeta.
    - Barra inferior de 2 niveles estandarizada (|<, >|, slider, ‹ [🖼️] › y retorno).
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local os         = require("os")

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
    -- Las páginas de libros/cómics son naturalmente verticales.
    -- Al estar en modo apaisado (sw > sh), el fallback correcto es sh / sw.
    return scrubber._sh / scrubber._sw
end

local GridSimpleLandscapeView = {}

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
-- pintada. which: "close" (círculo), "prev" / "next" (espacio tocable lateral).
function GridSimpleLandscapeView.pressRect(scrubber, which)
    local S = scrubber.S
    local pn = scrubber._gs_panel_dimen
    if not pn then return nil end
    local inset = S(2) + S(4)            -- borde de la tarjeta + aire
    local rad = S(14)
    local x, y, w, h

    -- ‹ › simétricos: misma altura, centrados en la altura de las flechas y siempre dentro
    -- de la zona entre la ✕ y el borde inferior de la página (sobre el porcentaje y páginas).
    local function side_y_range()
        local nd = scrubber._gs_next_dimen
        local pg = scrubber._gs_page_dimen
        if not (nd and pg) then return nil end
        local min_top = nd.y + S(2)
        local max_bottom = pg.y + pg.h
        local h = math.max(math.floor(pg.h * SIDE_PILL_H_RATIO), S(64))
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
        -- Diámetro = diagonal del icono (+ aire), pero sin salirse de la tarjeta.
        local icon = scrubber.icon_gs_x or scrubber.tw_x
        local isz = icon and icon:getSize() or { w = S(32), h = S(32) }
        local d = 2 * ((icon and inkRadius(icon) or math.floor(isz.w / 2)) + S(X_PRESS_PAD_DP))
        local cx = cd.x + math.floor(cd.w / 2)
        local cy = cd.y + math.floor(cd.h / 2)
        local margin = S(2)
        d = math.min(d,
                     2 * (cy - (pn.y + margin)),
                     2 * ((pn.x + pn.w - margin) - cx))
        if d < S(20) then d = S(20) end
        x = cx - math.floor(d / 2)
        y = cy - math.floor(d / 2)
        w, h = d, d
        rad = math.floor(d / 2)          -- círculo
    elseif which == "prev" then
        local d = scrubber._gs_prev_dimen
        if not d then return nil end
        local ty, th = side_y_range()
        if not ty then return nil end
        x = d.x + inset
        y = ty
        w = d.w - inset                  -- hasta el borde de la página
        h = th
    elseif which == "next" then
        local d = scrubber._gs_next_dimen
        if not d then return nil end
        local ty, th = side_y_range()
        if not ty then return nil end
        x = d.x                          -- desde el borde de la página
        y = ty
        w = (pn.x + pn.w - inset) - x
        h = th
    else
        return nil
    end

    if w <= 0 or h <= 0 then return nil end
    return Geom:new{ x = x, y = y, w = w, h = h }, rad
end

function GridSimpleLandscapeView.getThumbDims(scrubber)
    local sw, sh = scrubber._sw, scrubber._sh
    local S = scrubber.S
    local bar_h = S(6) * 2 + S(38) * 2 + S(4)
    local avail_h = sh - bar_h - S(16)
    local avail_w = sw - S(32)

    local top_offset = S(38)
    local bot_offset = S(28)
    local arrow_area_w = S(42)
    local pad_x = S(8)

    -- Fijamos el recuadro blanco al tamaño máximo permitido en horizontal.
    -- Así la interfaz queda estable y "apaisada". La imagen luego se escalará dentro de esto.
    local page_h = avail_h - top_offset - bot_offset
    local page_w = math.floor(avail_w * 0.75) - (arrow_area_w * 2) - (pad_x * 2)

    return page_w, page_h
end

function GridSimpleLandscapeView.paint(scrubber, bb)
    scrubber:_updateTexts()

    local sw, sh = scrubber._sw, scrubber._sh
    local S = scrubber.S

    -- 1. Barra inferior estandarizada (2 niveles)
    local l1_h = S(38)
    local l2_h = S(38)
    local bar_pad_y = S(6)
    local bar_gap = S(4)
    local bar_h = bar_pad_y * 2 + l1_h + bar_gap + l2_h
    local bar_y = sh - bar_h

    scrubber._bar_dimen = Geom:new{ x = 0, y = bar_y, w = sw, h = bar_h }
    local available_y = bar_y

    -- 2. Tarjeta centrada proporcional a la hoja
    local page_w, page_h = GridSimpleLandscapeView.getThumbDims(scrubber)
    local pad_x = S(8)
    local arrow_area_w = S(42)
    local top_offset = S(38)
    local bot_offset = S(28)

    local panel_w = page_w + (arrow_area_w * 2) + (pad_x * 2)
    local panel_h = page_h + top_offset + bot_offset
    local panel_x = math.floor((sw - panel_w) / 2)
    local panel_y = math.floor((available_y - panel_h) / 2)

    local page_x = panel_x + pad_x + arrow_area_w
    local page_y = panel_y + top_offset

    scrubber._gs_panel_dimen = Geom:new{ x = panel_x, y = panel_y, w = panel_w, h = panel_h }

    local shadow_offset = S(4)
    local radius = S(16)
    local border = S(2)

    -- Sombra y marco de la tarjeta
    paintRoundRect(bb, panel_x, panel_y + shadow_offset, panel_w, panel_h, radius, Blitbuffer.COLOR_DARK_GRAY)
    paintRoundRect(bb, panel_x, panel_y, panel_w, panel_h, radius, Blitbuffer.COLOR_BLACK)
    paintRoundRect(bb, panel_x + border, panel_y + border, panel_w - border*2, panel_h - border*2, math.max(1, radius - border), Blitbuffer.COLOR_WHITE)

    -- Efecto al apretar ‹ › (negro, redondeado). Se pinta antes que iconos y textos.
    -- El de la ✕ se pinta al final de la tarjeta para que la página no lo tape.
    if scrubber._gs_pressed == "prev" or scrubber._gs_pressed == "next" then
        local pr, prad = GridSimpleLandscapeView.pressRect(scrubber, scrubber._gs_pressed)
        if pr then
            paintRoundRect(bb, pr.x, pr.y, pr.w, pr.h, prad, Blitbuffer.COLOR_BLACK)
        end
    end

    -- Reloj en la cabecera
    local time_str = os.date("%H:%M")
    if not scrubber._tw_gs_clock then
        scrubber._tw_gs_clock = TextWidget:new{ text = "", face = Font:getFace("cfont", S(13)), fgcolor = Blitbuffer.COLOR_BLACK }
    end
    scrubber._tw_gs_clock:setText(time_str)

    local csz = scrubber._tw_gs_clock:getSize()
    local clock_x = panel_x + math.floor((panel_w - csz.w) / 2)
    local clock_y = panel_y + S(12)
    paintTripleText(scrubber._tw_gs_clock, bb, clock_x, clock_y)

    -- Botón de cierre (✕) en la esquina superior derecha
    local icon_x = scrubber.icon_gs_x or scrubber.tw_x
    local xsz = icon_x and icon_x:getSize() or { w = S(32), h = S(32) }
    local xx = panel_x + panel_w - xsz.w - S(14)
    local xy = clock_y + math.floor((csz.h - xsz.h) / 2)

    local touch_btn_size = math.max(xsz.w, xsz.h) + S(16)
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

    -- Indicadores en la cabecera de la ventana (a la misma altura que la ✕)
    local is_cur_bmed = scrubber:_isCurrentPageBookmarked(scrubber._cur_page)
    local header_x = panel_x + S(14)

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

    -- Miniatura a proporción real sin deformación
    local slot = scrubber._grid_tiles[2]
    if slot and slot.page then
        if slot.tile_bb then
            local tw, th = slot.tile_bb:getWidth(), slot.tile_bb:getHeight()
            local render_bb = slot.tile_bb
            local must_free = false

            -- ESCALADO PROPORCIONAL ESTRICTO: evita achatamientos
            local scale_factor = math.min(page_w / tw, page_h / th)
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
            if blit_w > page_w then src_x = math.floor((blit_w - page_w) / 2); blit_w = page_w end
            if blit_h > page_h then src_y = math.floor((blit_h - page_h) / 2); blit_h = page_h end

            local ox = page_x + math.floor((page_w - blit_w) / 2)
            local oy = page_y + math.floor((page_h - blit_h) / 2)

            bb:paintRect(page_x, page_y, page_w, page_h, Blitbuffer.COLOR_WHITE)

            if blit_w > 0 and blit_h > 0 then
                bb:blitFrom(render_bb, ox, oy, src_x, src_y, blit_w, blit_h)
            end
            if must_free then pcall(function() render_bb:free() end) end
        elseif slot.error then
            if not scrubber._tw_gs_error then
                scrubber._tw_gs_error = TextWidget:new{ text = "!", face = Font:getFace("cfont", S(32)), fgcolor = Blitbuffer.COLOR_BLACK }
            end
            local etsz = scrubber._tw_gs_error:getSize()
            scrubber._tw_gs_error:paintTo(bb, page_x + math.floor((page_w - etsz.w) / 2), page_y + math.floor((page_h - etsz.h) / 2))
        elseif slot.loading then
            bb:paintRect(page_x + math.floor(page_w / 2) - 1, page_y + math.floor(page_h / 2) - 1, 2, 2, Blitbuffer.COLOR_GRAY)
        end
    end

    -- Flechas laterales
    local icon_l = scrubber.icon_gs_chevron_left or scrubber.icon_chevron_left
    local icon_r = scrubber.icon_gs_chevron_right or scrubber.icon_chevron_right
    local lsz = icon_l and icon_l:getSize() or { w = S(38), h = S(38) }
    local rsz = icon_r and icon_r:getSize() or { w = S(38), h = S(38) }

    local left_arrow_x = panel_x + pad_x + math.floor((arrow_area_w - lsz.w) / 2)
    local right_arrow_x = page_x + page_w + math.floor((arrow_area_w - rsz.w) / 2)
    local arrow_l_y = panel_y + math.floor((panel_h - lsz.h) / 2)
    local arrow_r_y = panel_y + math.floor((panel_h - rsz.h) / 2)

    if icon_l then
        if scrubber._gs_pressed == "prev" then
            paintIconWhite(bb, icon_l, left_arrow_x, arrow_l_y, false, (GridSimpleLandscapeView.pressRect(scrubber, "prev")))
        else
            icon_l.fgcolor = Blitbuffer.COLOR_BLACK
            icon_l:paintTo(bb, left_arrow_x, arrow_l_y)
        end
    end
    if icon_r then
        if scrubber._gs_pressed == "next" then
            paintIconWhite(bb, icon_r, right_arrow_x, arrow_r_y, false, (GridSimpleLandscapeView.pressRect(scrubber, "next")))
        else
            icon_r.fgcolor = Blitbuffer.COLOR_BLACK
            icon_r:paintTo(bb, right_arrow_x, arrow_r_y)
        end
    end

    -- ‹ y › simétricos: los dos arrancan debajo de la ✕
    local next_y_start = scrubber._gs_close_dimen.y + scrubber._gs_close_dimen.h
    scrubber._gs_prev_dimen = Geom:new{
        x = panel_x,
        y = next_y_start,
        w = pad_x + arrow_area_w,
        h = panel_y + panel_h - next_y_start,
    }
    scrubber._gs_next_dimen = Geom:new{ 
        x = page_x + page_w, 
        y = next_y_start, 
        w = panel_x + panel_w - (page_x + page_w), 
        h = panel_y + panel_h - next_y_start 
    }
    scrubber._gs_page_dimen = Geom:new{ x = page_x, y = page_y, w = page_w, h = page_h }

    -- ✕ apretada: círculo negro + icono blanco (solo sus píxeles, sin recuadro)
    if icon_x and scrubber._gs_pressed == "close" then
        local pr, prad = GridSimpleLandscapeView.pressRect(scrubber, "close")
        if pr then
            paintRoundRect(bb, pr.x, pr.y, pr.w, pr.h, prad, Blitbuffer.COLOR_BLACK)
            paintIconWhite(bb, icon_x, xx, xy, false, pr)
        end
    end

    -- Información de lectura (% · Pág. X / Y) al pie de la tarjeta
    if scrubber.tw_info then
        local isz = scrubber.tw_info:getSize()
        local infox = panel_x + math.floor((panel_w - isz.w) / 2)
        local infoy = page_y + page_h + math.floor((bot_offset - isz.h) / 2)
        paintTripleText(scrubber.tw_info, bb, infox, infoy)
    end

    -- 3. Barra inferior de 2 niveles estandarizada
    bb:paintRect(0, bar_y, sw, bar_h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(0, bar_y, sw, S(2), Blitbuffer.COLOR_BLACK)

    local function drawBtnWithPress(btn_id, dim, widget, y_off, is_disabled)
        if not dim or not widget then return end
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

    -- Nivel 1: Capítulos y Slider
    local pad_x_bar = S(16)
    local l1_y = bar_y + bar_pad_y
    local ch_btn_sz = S(34)

    local current_display = scrubber._cur_page
    local can_prev_ch = scrubber.ui and scrubber.ui.toc and scrubber.ui.toc:getPreviousChapter(current_display) ~= nil
    local can_next_ch = scrubber.ui and scrubber.ui.toc and scrubber.ui.toc:getNextChapter(current_display) ~= nil

    local show_ch_l, show_ch_r
    if scrubber.is_rtl then
        show_ch_l = can_next_ch
        show_ch_r = can_prev_ch
    else
        show_ch_l = can_prev_ch
        show_ch_r = can_next_ch
    end

    if show_ch_l then
        scrubber._prev_ch_dimen = Geom:new{ x = pad_x_bar, y = l1_y + math.floor((l1_h - ch_btn_sz)/2), w = ch_btn_sz, h = ch_btn_sz }
        drawBtnWithPress("ch_l", scrubber._prev_ch_dimen, scrubber.tw_ch_l, -S(1), false)
    else
        scrubber._prev_ch_dimen = nil
    end

    if show_ch_r then
        scrubber._next_ch_dimen = Geom:new{ x = sw - pad_x_bar - ch_btn_sz, y = l1_y + math.floor((l1_h - ch_btn_sz)/2), w = ch_btn_sz, h = ch_btn_sz }
        drawBtnWithPress("ch_r", scrubber._next_ch_dimen, scrubber.tw_ch_r, -S(1), false)
    else
        scrubber._next_ch_dimen = nil
    end

    local slider_x = pad_x_bar + ch_btn_sz + S(12)
    local slider_w = (sw - pad_x_bar - ch_btn_sz) - S(12) - slider_x
    scrubber._slider.width = slider_w
    scrubber._slider.value = scrubber._cur_page
    scrubber._slider:paintTo(bb, slider_x, l1_y + math.floor((l1_h - scrubber._slider:getSize().h)/2))

    -- Nivel 2: Título de capítulo a la izquierda, controles centrales (‹ [🖼️] ›) y botón volver al origen
    local l2_y = l1_y + l1_h + bar_gap
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

    local has_left_bm, has_right_bm
    if scrubber.is_rtl then
        has_left_bm  = (scrubber:_findNextBookmark() ~= nil)
        has_right_bm = (scrubber:_findPrevBookmark() ~= nil)
    else
        has_left_bm  = (scrubber:_findPrevBookmark() ~= nil)
        has_right_bm = (scrubber:_findNextBookmark() ~= nil)
    end

    drawBtnWithPress("ctrl_prev", scrubber._ctrl_prev_dimen, scrubber.tw_ctrl_prev, 0, not has_left_bm)
    drawBtnWithPress("ctrl_mark", scrubber._ctrl_mark_dimen, scrubber.tw_gallery, 0, false)
    drawBtnWithPress("ctrl_next", scrubber._ctrl_next_dimen, scrubber.tw_ctrl_next, 0, not has_right_bm)

    -- Botón volver al origen anclado siempre a la derecha con flecha direccional
    local has_back = math.abs(scrubber._cur_page - scrubber._origin_page) >= 10
    scrubber._grid_back_dimen = nil

    local origin_on_left
    if scrubber.is_rtl then
        origin_on_left = (scrubber._cur_page < scrubber._origin_page)
    else
        origin_on_left = (scrubber._cur_page > scrubber._origin_page)
    end

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

    -- Título de capítulo en el margen izquierdo (con espacio completo disponible)
    local ch_avail_w = ctrl_x - pad_x_bar - S(12)
    if scrubber.tw_chapter and ch_avail_w > S(50) then
        scrubber.tw_chapter.max_width = ch_avail_w
        scrubber.tw_chapter:paintTo(bb, pad_x_bar, l2_y + math.floor((mark_sz - scrubber.tw_chapter:getSize().h)/2))
    end
end

return GridSimpleLandscapeView


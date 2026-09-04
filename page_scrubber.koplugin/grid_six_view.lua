--[[
    page_scrubber.koplugin/grid_six_view.lua
    Renderizador y manejador táctil para la vista de 6 páginas (3x2).
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local Device     = require("device")
local Screen     = Device.screen

local GridSixView = {}

-- Calcula la matriz de 3x2 dinámica según el espacio disponible
function GridSixView.getSlotDimens(scrubber)
    local gd = scrubber._grid_dimen
    local S = scrubber.S
    local margin_x = S(16)
    local gap_x = S(12)
    local gap_y = S(16)
    local cols, rows = 3, 2
    
    local cell_w = math.floor((gd.w - (margin_x * 2) - (gap_x * (cols - 1))) / cols)
    local cell_h = math.floor((gd.h - (gap_y * (rows - 1))) / rows)

    -- Mantener la proporción (aspect ratio) parecida a la de una hoja real
    if scrubber._is_comic then
        cell_h = math.floor(cell_w * Screen:getHeight() / Screen:getWidth())
    else
        local try_w = math.floor(cell_h * Screen:getWidth() / Screen:getHeight())
        if try_w < cell_w then cell_w = try_w end
    end

    local start_x = gd.x + math.floor((gd.w - (cell_w * cols + gap_x * (cols - 1))) / 2)
    local start_y = gd.y + math.floor((gd.h - (cell_h * rows + gap_y * (rows - 1))) / 2)

    local slots = {}
    for row = 0, rows - 1 do
        for col = 0, cols - 1 do
            table.insert(slots, Geom:new{
                x = start_x + col * (cell_w + gap_x),
                y = start_y + row * (cell_h + gap_y),
                w = cell_w,
                h = cell_h
            })
        end
    end
    return slots
end

function GridSixView.paint(scrubber, bb)
    local slots = GridSixView.getSlotDimens(scrubber)
    local S = scrubber.S
    local font_badge = Font:getFace("cfont", S(13))
    local sw, sh = Screen:getWidth(), Screen:getHeight()

    -- Asumimos que _grid_tiles va a tener 6 elementos cargados cuando este modo esté activo
    for idx = 1, 6 do
        local rect = slots[idx]
        local slot = scrubber._grid_tiles[idx]
        
        bb:paintRect(rect.x, rect.y, rect.w, rect.h, Blitbuffer.COLOR_WHITE)

        -- La página actual es la 2 (Arriba al centro)
        local is_cur = (idx == 2) 
        local border = is_cur and S(4) or S(1)

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
                
                -- Clipping de seguridad
                if ox < 0 then src_x = src_x - ox; blit_w = blit_w + ox; ox = 0 end
                if oy < 0 then src_y = src_y - oy; blit_h = blit_h + oy; oy = 0 end
                if ox + blit_w > sw then blit_w = sw - ox end
                if oy + blit_h > sh then blit_h = sh - oy end
                
                if blit_w > 0 and blit_h > 0 then
                    bb:blitFrom(slot.tile_bb, ox, oy, src_x, src_y, blit_w, blit_h)
                end
            elseif slot.error then
                -- Dibujar advertencia de error (Optimizada y bug de tipeo arreglado)
                if not scrubber._tw_grid_error then
                    scrubber._tw_grid_error = TextWidget:new{ text = "!", face = Font:getFace("cfont", S(32)), fgcolor = Blitbuffer.COLOR_BLACK }
                end
                local etsz = scrubber._tw_grid_error:getSize()
                scrubber._tw_grid_error:paintTo(bb, rect.x + math.floor((rect.w - etsz.w)/2), rect.y + math.floor((rect.h - etsz.h)/2))
            elseif slot.loading then
                -- Dibujar puntito de carga
                bb:paintRect(rect.x + math.floor(rect.w/2)-1, rect.y + math.floor(rect.h/2)-1, 2, 2, Blitbuffer.COLOR_GRAY)
            end

            -- Dibujar el borde de la página
            bb:paintBorder(rect.x, rect.y, rect.w, rect.h, border, Blitbuffer.COLOR_BLACK, 0)

            -- Dibujar el número de página estilo "Pastilla" anclada al fondo (Optimizado)
            if not scrubber._tw_gsix_page then
                scrubber._tw_gsix_page = TextWidget:new{ text = "", face = font_badge, fgcolor = Blitbuffer.COLOR_WHITE, padding = 0 }
            end
            scrubber._tw_gsix_page.text = nil
            
            -- Aplicamos la función estable para la "pastilla"
            local disp_p = scrubber:_getDisplayPageInfo(slot.page)
            scrubber._tw_gsix_page:setText(tostring(disp_p))
            
            local tsz = scrubber._tw_gsix_page:getSize()
            local pv, ph = S(2), S(5)
            local badge_h = tsz.h + 2 * pv
            local badge_w = math.max(tsz.w + 2 * ph, badge_h)
            local bx = rect.x + math.floor((rect.w - badge_w) / 2)
            -- Pegado exactamente a la línea negra inferior
            local by = rect.y + rect.h - badge_h

            -- Fondo redondeado color negro puro
            local r = badge_h / 2
            for row = 0, badge_h - 1 do
                local dy = math.abs(row + 0.5 - r)
                local dx = math.sqrt(math.max(0, r * r - dy * dy))
                local x0 = math.ceil(bx + r - dx)
                local x1 = math.floor(bx + badge_w - r + dx)
                local w_line = x1 - x0
                if w_line > 0 then bb:paintRect(x0, by + row, w_line, 1, Blitbuffer.COLOR_BLACK) end
            end

            scrubber._tw_gsix_page:paintTo(bb, bx + math.floor((badge_w - tsz.w)/2), by + math.floor((badge_h - tsz.h)/2))
        end
    end
end

-- Tocar cualquier miniatura viaja directo a la página y cierra
function GridSixView.onTap(scrubber, ges)
    local slots = GridSixView.getSlotDimens(scrubber)
    for idx = 1, 6 do
        if ges.pos:intersectWith(slots[idx]) then
            local slot = scrubber._grid_tiles[idx]
            if slot and slot.page then
                scrubber:_gotoPage(slot.page)
                scrubber:_closeStay()
            end
            return true
        end
    end
    return false
end

return GridSixView

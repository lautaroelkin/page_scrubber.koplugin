--[[
    page_scrubber.koplugin/grid_six_view.lua
    Renderizador y manejador táctil para la vista multi-grid en vertical (6 páginas 3x2, o 9 páginas 3x3 si
    el ajuste page_scrubber_multigrid_nine está activo):
    - Proporción real de página idéntica al documento (sin achatamiento ni recuadros desfasados).
    - Contorno fiel al borde exacto de la miniatura.
    - Ocultamiento de la orejita nativa mediante máscara blanca detrás del bookmark.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local Device     = require("device")
local Screen     = Device.screen

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

local function drawBookmarkRibbon(bb, x, y, w, h, color)
    local cut = math.floor(w / 2)
    local straight = h - cut
    if straight > 0 then bb:paintRect(x, y, w, straight, color) end
    for r = 0, cut - 1 do
        local leg = math.floor(w / 2) - r
        if leg > 0 then
            bb:paintRect(x, y + straight + r, leg, 1, color)
            bb:paintRect(x + w - leg, y + straight + r, leg, 1, color)
        end
    end
end

local function getDocPageAspectRatio(scrubber)
    local doc = scrubber.ui and scrubber.ui.document
    if doc and type(doc.getPageDimension) == "function" then
        local ok, dim = pcall(function() return doc:getPageDimension(scrubber._cur_page) end)
        if ok and dim and dim.w and dim.h and dim.w > 0 and dim.h > 0 then
            return dim.w / dim.h
        end
    end
    return Screen:getWidth() / Screen:getHeight()
end


-- ¿Documento de página fija (cómic / PDF)? Ahí cada página puede tener su propia proporción.
local function isFixedPageDoc(scrubber)
    if scrubber._is_comic then return true end
    local doc = scrubber.ui and scrubber.ui.document
    local ext = (doc and doc.file and doc.file:match("%.([%a%d]+)$")) or ""
    return ext:lower() == "pdf"
end

-- Recuadro que ocupa realmente la página dentro de la celda: la miniatura se dibuja a su
-- proporción real (centrada) y el contorno la sigue, igual que en el grid de 3.
local function getPageBox(rect, slot)
    local tb = slot and slot.tile_bb
    if tb then
        local ok, tw, th = pcall(function() return tb:getWidth(), tb:getHeight() end)
        if ok and tw and th and tw > 0 and th > 0 then
            local bw, bh = math.min(tw, rect.w), math.min(th, rect.h)
            if bw < rect.w - 2 or bh < rect.h - 2 then
                return rect.x + math.floor((rect.w - bw) / 2),
                       rect.y + math.floor((rect.h - bh) / 2), bw, bh
            end
        end
    end
    return rect.x, rect.y, rect.w, rect.h
end

local GridSixView = {}

-- Devuelve cols, rows y total de celdas según el ajuste "Multi Grid: Show 9 pages"
function GridSixView.getLayout()
    local nine = G_reader_settings and G_reader_settings:readSetting("page_scrubber_multigrid_nine") == true
    if nine then return 3, 3, 9 end
    return 3, 2, 6
end

-- Calcula la matriz (3x2 o 3x3) ajustada a la proporción real de la página
function GridSixView.getSlotDimens(scrubber)
    local gd = scrubber._grid_dimen
    local S = scrubber.S
    local cols, rows = GridSixView.getLayout()
    local is_nine = (rows == 3)
    -- En 9 páginas los márgenes son más chicos para aprovechar la pantalla
    local margin_x = is_nine and S(10) or S(16)
    local gap_x = is_nine and S(8) or S(12)
    local gap_y = is_nine and S(5) or S(16)

    local max_cell_w = math.floor((gd.w - (margin_x * 2) - (gap_x * (cols - 1))) / cols)
    local max_cell_h = math.floor((gd.h - (gap_y * (rows - 1))) / rows)

    local ratio = getDocPageAspectRatio(scrubber)

    local cell_w = max_cell_w
    local cell_h = math.floor(cell_w / ratio)

    if cell_h > max_cell_h then
        cell_h = max_cell_h
        cell_w = math.floor(cell_h * ratio)
    end

    -- En 9 páginas: miniaturas un poco más chicas para dar más aire a todo
    if is_nine then
        local SHRINK = 0.94
        cell_w = math.floor(cell_w * SHRINK)
        cell_h = math.floor(cell_h * SHRINK)
        -- Espacio vertical repartido por igual entre filas y bordes
        local space_v = math.floor((gd.h - (cell_h * rows)) / (rows + 1))
        if space_v > gap_y then gap_y = space_v end
    end

    -- En 9 páginas: el espacio entre página y borde es un poco menor (EDGE_RATIO) que entre páginas
    if is_nine then
        local EDGE_RATIO = 0.7
        local free = gd.w - (cell_w * cols)
        local gap = math.floor(free / (2 * EDGE_RATIO + (cols - 1)))
        if gap >= 0 then
            gap_x = gap
            margin_x = math.floor(gap * EDGE_RATIO)
        end
    end

    local grid_w = cell_w * cols + gap_x * (cols - 1)
    local grid_h = cell_h * rows + gap_y * (rows - 1)
    local start_x = gd.x + math.floor((gd.w - grid_w) / 2)
    local start_y = gd.y + math.floor((gd.h - grid_h) / 2)

    local is_rtl = scrubber.is_rtl == true
    local slots = {}
    for row = 0, rows - 1 do
        for c = 0, cols - 1 do
            local col = is_rtl and (cols - 1 - c) or c
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
    local _, _, total = GridSixView.getLayout()
    local S = scrubber.S
    local font_badge = Font:getFace("cfont", S(12))
    local all_bms = scrubber:_getAllBookmarks() or {}

    local is_fixed = isFixedPageDoc(scrubber)

    for idx = 1, total do
        local rect = slots[idx]
        local slot = scrubber._grid_tiles[idx]
        
        bb:paintRect(rect.x, rect.y, rect.w, rect.h, Blitbuffer.COLOR_WHITE)

        local is_origin = (slot and slot.page and tonumber(slot.page) == tonumber(scrubber._origin_page))
        local border = is_origin and S(3) or S(1)

        if slot and slot.page then
            if slot.tile_bb then
                local tw, th = slot.tile_bb:getWidth(), slot.tile_bb:getHeight()
                local render_bb = slot.tile_bb

                -- Solo reducimos (conservando proporción) si la miniatura no entra en la celda.
                -- Nunca se estira a rect.w x rect.h: eso aplastaba cómics y PDF.
                if tw > rect.w or th > rect.h then
                    local f = math.min(rect.w / tw, rect.h / th)
                    local nw = math.max(1, math.floor(tw * f))
                    local nh = math.max(1, math.floor(th * f))
                    local ok, sc = pcall(function() return slot.tile_bb:scale(nw, nh) end)
                    if ok and sc then
                        slot.tile_bb = sc
                        slot.is_scaled = true
                        render_bb = sc
                    end
                end

                local bw = render_bb:getWidth()
                local bh = render_bb:getHeight()
                local ox = rect.x + math.floor((rect.w - bw) / 2)
                local oy = rect.y + math.floor((rect.h - bh) / 2)

                bb:blitFrom(render_bb, ox, oy, 0, 0, bw, bh)

                -- Marcador y solapa blanca para tapar la orejita nativa
                local box_x, box_y, box_w, box_h = getPageBox(rect, slot)

                local is_bmed = false
                if scrubber._cached_bms_map then
                    is_bmed = scrubber._cached_bms_map[tonumber(slot.page)] or false
                else
                    for _, bmp in ipairs(all_bms) do
                        if tonumber(bmp) == tonumber(slot.page) then is_bmed = true; break end
                    end
                end

                if is_bmed then
                    local rw, rh = S(20), S(34)
                    local rx = box_x + box_w - rw - S(8) - border
                    local ry = box_y + border

                    local mask_x = rx - S(2)
                    local mask_y = ry
                    local mask_w = (box_x + box_w - border) - mask_x
                    local mask_h = S(22)

                    bb:paintRect(mask_x, mask_y, mask_w, mask_h, Blitbuffer.COLOR_WHITE)
                    drawBookmarkRibbon(bb, rx, ry, rw, rh, Blitbuffer.COLOR_BLACK)
                end

            elseif slot.error then
                if not scrubber._tw_grid_error then
                    scrubber._tw_grid_error = TextWidget:new{ text = "!", face = Font:getFace("cfont", S(32)), fgcolor = Blitbuffer.COLOR_BLACK }
                end
                local etsz = scrubber._tw_grid_error:getSize()
                scrubber._tw_grid_error:paintTo(bb, rect.x + math.floor((rect.w - etsz.w) / 2), rect.y + math.floor((rect.h - etsz.h) / 2))
            elseif slot.loading then
                bb:paintRect(rect.x + math.floor(rect.w / 2) - 1, rect.y + math.floor(rect.h / 2) - 1, 2, 2, Blitbuffer.COLOR_GRAY)
            end

            -- Contorno exacto en los bordes de la página real (sigue a la miniatura, no a la celda)
            local box_x, box_y, box_w, box_h = getPageBox(rect, slot)
            if slot.tile_bb or not is_fixed then
                bb:paintBorder(box_x, box_y, box_w, box_h, border, Blitbuffer.COLOR_BLACK, 0)
            end

            -- Pastilla con número de página (SIEMPRE VISIBLE: cargada, cargando o con error)
            if not scrubber._tw_gsix_page then
                scrubber._tw_gsix_page = TextWidget:new{ text = "", face = font_badge, fgcolor = Blitbuffer.COLOR_WHITE, padding = 0 }
            end
            local disp_p = scrubber:_getDisplayPageInfo(slot.page)
            scrubber._tw_gsix_page:setText(tostring(disp_p))

            local tsz = scrubber._tw_gsix_page:getSize()
            local badge_h = tsz.h + S(4)
            local badge_w = math.max(tsz.w + S(10), badge_h)
            local bx = box_x + math.floor((box_w - badge_w) / 2)
            local by = box_y + box_h - badge_h

            paintRoundRect(bb, bx, by, badge_w, badge_h, math.floor(badge_h / 2), Blitbuffer.COLOR_BLACK)
            scrubber._tw_gsix_page:paintTo(bb, bx + math.floor((badge_w - tsz.w) / 2), by + math.floor((badge_h - tsz.h) / 2))
        end
    end
end

function GridSixView.onTap(scrubber, ges)
    local slots = GridSixView.getSlotDimens(scrubber)
    local _, _, total = GridSixView.getLayout()
    local S = scrubber.S
    for idx = 1, total do
        local rect = slots[idx]
        if ges.pos:intersectWith(rect) then
            local slot = scrubber._grid_tiles[idx]
            if slot and slot.page then
                local rw, rh = S(20), S(34)
                local bm_w = math.max(S(36), rw + S(16))
                local bm_h = math.max(S(42), rh + S(10))
                local box_x, box_y, box_w = getPageBox(rect, slot)
                local bm_touch_rect = Geom:new{
                    x = box_x + box_w - bm_w,
                    y = box_y,
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

return GridSixView

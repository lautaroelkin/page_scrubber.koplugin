
--[[
    page_scrubber.koplugin/grid_view.lua
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")

local GridView = {}

function GridView.paint(scrubber, bb)
    local nb_items = scrubber._grid_cols * scrubber._grid_rows
    local all_bms = scrubber:_getAllBookmarks()
    scrubber._center_bm_touch_dimen = nil

    local sw, sh = scrubber._sw, scrubber._sh
    local S = scrubber.S

    for idx = 1, nb_items do
        local slot = scrubber._grid_tiles[idx]
        local rect = scrubber:_gridSlotDimen(idx)
        local is_cur = (idx == 2)
        local border = is_cur and S(3) or S(1)

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
                if not scrubber._tw_grid_error then
                    scrubber._tw_grid_error = TextWidget:new{
                        text = "!", face = Font:getFace("cfont", S(32)),
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    }
                end
                local etsz = scrubber._tw_grid_error:getSize()
                scrubber._tw_grid_error:paintTo(bb, rect.x + math.floor((rect.w - etsz.w) / 2),
                    rect.y + math.floor((rect.h - etsz.h) / 2))
            elseif slot.loading then
                bb:paintRect(rect.x + math.floor(rect.w / 2) - 1, rect.y + math.floor(rect.h / 2) - 1,
                    2, 2, Blitbuffer.COLOR_GRAY)
            end
            
            if scrubber._grid_flash_idx == idx then
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
                local bw, bh = S(28), S(46)
                local bx = rect.x + rect.w - bw - S(16) - border
                local by = rect.y + border
                scrubber._center_bm_touch_dimen = Geom:new{ x = bx - S(10), y = by, w = bw + S(20), h = bh + S(20) }
            end
            
            if is_bmed then
                local bw, bh = S(28), S(46)
                local bx = rect.x + rect.w - bw - S(16) - border
                local by = rect.y + border
                
                local mask_x = bx - S(2)
                local mask_y = by
                local mask_w = (rect.x + rect.w - border) - mask_x
                local mask_h = S(26)
                
                bb:paintRect(mask_x, mask_y, mask_w, mask_h, Blitbuffer.COLOR_WHITE)
                scrubber.drawBookmarkRibbon(bb, bx, by, bw, bh, Blitbuffer.COLOR_BLACK)
            end

            bb:paintBorder(rect.x, rect.y, rect.w, rect.h, border, Blitbuffer.COLOR_BLACK, 0)
        end
    end
end

return GridView

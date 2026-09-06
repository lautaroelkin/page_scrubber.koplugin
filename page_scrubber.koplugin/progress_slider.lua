--[[
    page_scrubber.koplugin/progress_slider.lua
    Componente aislado para la barra de progreso
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device     = require("device")
local Geom       = require("ui/geometry")

local Screen = Device.screen

local function paintPill(bb, px, py, pw, ph, color)
    if pw <= 0 or ph <= 0 then return end
    local r = math.min(pw, ph) / 2.0
    for row = 0, ph - 1 do
        local dy = (row + 0.5) - ph * 0.5
        local inset = math.abs(dy) < r and math.ceil(r - math.sqrt(r*r - dy*dy)) or 0
        local rw = pw - 2 * inset
        if rw > 0 then bb:paintRect(px + inset, py + row, rw, 1, color) end
    end
end

local function paintCornerRect(bb, x, y, w, h, r, color)
    if w <= 0 or h <= 0 then return end
    r = math.min(r, math.floor(w / 2), math.floor(h / 2))
    if r <= 0 then bb:paintRect(x, y, w, h, color); return end
    bb:paintRect(x + r, y, w - 2*r, h, color)
    bb:paintRect(x, y + r, r, math.max(1, h - 2*r), color)
    bb:paintRect(x + w - r, y + r, r, math.max(1, h - 2*r), color)
    for j = 0, r - 1 do
        local arc = math.ceil(math.sqrt(r*r - (r-j-0.5)*(r-j-0.5)))
        if arc > 0 then
            bb:paintRect(x + r - arc, y + j, arc, 1, color)
            bb:paintRect(x + w - r,   y + j, arc, 1, color)
            bb:paintRect(x + r - arc, y + h - 1 - j, arc, 1, color)
            bb:paintRect(x + w - r,   y + h - 1 - j, arc, 1, color)
        end
    end
end

local function paintCircle(bb, cx, cy, r, color)
    if r <= 0 then return end
    for row = -r, r do
        local half = math.floor(math.sqrt(r*r - row*row) + 0.5)
        if half > 0 then bb:paintRect(cx - half, cy + row, half * 2, 1, color) end
    end
end

local function paintRoundedDownTriangle(bb, cx, bottom_y, w, h, color)
    if w <= 0 or h <= 0 then return end
    local H = math.max(1, h - 1)
    local half_w = w / 2

    for dy = 0, H do
        local cur_y = bottom_y - 1 - dy
        local t = dy / H
        -- Caída suave con pendiente convexa
        local span = math.floor((t ^ 0.75) * half_w + 0.5)

        -- Suavizado de esquinas superiores
        if dy == H and span > 1 then
            span = span - 1
        end

        if span >= 0 then
            bb:paintRect(cx - span, cur_y, span * 2 + 1, 1, color)
        end
    end
end

local ProgressSlider = {}
ProgressSlider.__index = ProgressSlider

function ProgressSlider:new(o)
    local obj = setmetatable(o or {}, self)
    local S = obj.S or function(v) return Screen:scaleBySize(v) end
    obj.knob_r = S(16)
    obj.height = obj.knob_r * 2 + S(6)
    obj.dimen   = Geom:new{ x = 0, y = 0, w = obj.width or 0, h = obj.height }
    obj._dragging = false
    obj.is_rtl = (obj.is_rtl == true)
    return obj
end

function ProgressSlider:getSize() return self.dimen end

function ProgressSlider:_valueToX(v)
    local range = self.value_max - self.value_min
    if range == 0 then return self.knob_r end
    local frac = (v - self.value_min) / range
    if self.is_rtl then
        frac = 1 - frac
    end
    if self.chapters then
        return frac * (self.width or 0)
    end
    return self.knob_r + frac * ((self.width or 0) - self.knob_r * 2)
end

function ProgressSlider:_xToValue(lx)
    local range = self.value_max - self.value_min
    local frac
    if self.chapters then
        frac = lx / math.max(1, self.width or 0)
    else
        frac = (lx - self.knob_r) / math.max(1, (self.width or 0) - self.knob_r * 2)
    end
    frac = math.max(0, math.min(1, frac))
    if self.is_rtl then
        frac = 1 - frac
    end
    return math.floor(self.value_min + frac * range + 0.5)
end

function ProgressSlider:paintTo(bb, x, y)
    self.dimen.x = x; self.dimen.y = y
    local w, h = self.width or 0, self.height
    local S = self.S
    local cy = math.floor(y + h / 2)

    -- Altura: 7px en modo capítulos, 4px en modo normal
    local bar_h = self.chapters and S(7) or S(4)
    local bar_y = cy - math.floor(bar_h / 2)

    -- Pista de fondo (Gris claro)
    paintPill(bb, x, bar_y, w, bar_h, Blitbuffer.COLOR_LIGHT_GRAY)

    -- Pista de avance (Negro)
    local range = math.max(1, self.value_max - self.value_min)
    local frac = (self.value - self.value_min) / range
    local fw = math.floor(frac * w + 0.5)

    if fw > 0 then
        if self.is_rtl then
            paintPill(bb, x + w - fw, bar_y, fw, bar_h, Blitbuffer.COLOR_BLACK)
        else
            paintPill(bb, x, bar_y, fw, bar_h, Blitbuffer.COLOR_BLACK)
        end
    end

    -- Marcas de capítulos
    if self.chapters then
        local chapter_xs = {}

        for _, ch_page in ipairs(self.chapters) do
            if ch_page >= self.value_min and ch_page <= self.value_max then
                local ch_frac = (ch_page - self.value_min) / range
                if self.is_rtl then
                    ch_frac = 1 - ch_frac
                end
                local cx = math.floor(x + ch_frac * w + 0.5)
                table.insert(chapter_xs, cx)
            end
        end

        table.sort(chapter_xs)

        local gap_thresh = S(8)
        local dense_w = math.max(2, S(2)) -- 2px si están amontonados
        local wide_w  = math.max(3, S(4)) -- 4px estándar
        local tick_h  = bar_h             -- 7px exactos al ras
        local tick_y  = bar_y

        for i, cx in ipairs(chapter_xs) do
            if cx > x + S(4) and cx < (x + w - S(4)) then
                local prev_cx = chapter_xs[i - 1]
                local next_cx = chapter_xs[i + 1]

                local is_crowded = (prev_cx and (cx - prev_cx) <= gap_thresh)
                                or (next_cx and (next_cx - cx) <= gap_thresh)
                local tick_w = is_crowded and dense_w or wide_w
                local tick_x = cx - math.floor(tick_w / 2)

                bb:paintRect(tick_x, tick_y, tick_w, tick_h, Blitbuffer.COLOR_WHITE)
            end
        end
    end

    -- Marcadores de páginas guardadas (Bookmarks)
    if self.bookmarks then
        if self.chapters then
            local tw_out = S(8)
            local th_out = S(7)
            local tw_in  = S(6)
            local th_in  = S(5)
            local base_y = bar_y

            for _, bmpage in ipairs(self.bookmarks) do
                if bmpage >= self.value_min and bmpage <= self.value_max then
                    local bmx = math.floor(x + self:_valueToX(bmpage))
                    paintRoundedDownTriangle(bb, bmx, base_y + 1, tw_out, th_out, Blitbuffer.COLOR_WHITE)
                    paintRoundedDownTriangle(bb, bmx, base_y, tw_in, th_in, Blitbuffer.COLOR_BLACK)
                end
            end
        else
            local bm_r_outer = S(8)
            local bm_r_inner = S(5)
            for _, bmpage in ipairs(self.bookmarks) do
                if bmpage >= self.value_min and bmpage <= self.value_max then
                    local bmx = math.floor(x + self:_valueToX(bmpage))
                    paintCircle(bb, bmx, cy, bm_r_outer, Blitbuffer.COLOR_WHITE)
                    paintCircle(bb, bmx, cy, bm_r_inner, Blitbuffer.COLOR_BLACK)
                end
            end
        end
    end

    -- Cursor deslizador (Knob)
    local kx = math.floor(x + self:_valueToX(self.value))
    if self.chapters then
        local kw = S(6)
        local kh = S(16)
        local kx_pos = kx - math.floor(kw / 2)
        local ky_pos = cy - math.floor(kh / 2)
        local kr = math.floor(kw / 2)

        paintCornerRect(bb, kx_pos - 1, ky_pos - 1, kw + 2, kh + 2, kr + 1, Blitbuffer.COLOR_WHITE)
        paintCornerRect(bb, kx_pos, ky_pos, kw, kh, kr, Blitbuffer.COLOR_BLACK)
    else
        local r = self.knob_r
        paintCircle(bb, kx, cy, r, Blitbuffer.COLOR_BLACK)
        paintCircle(bb, kx, cy, r - S(3), Blitbuffer.COLOR_WHITE)
    end
end

function ProgressSlider:handleTap(ges)
    if not self.dimen or not ges.pos:intersectWith(self.dimen) then return false end
    local tap_x = ges.pos.x - self.dimen.x
    local v = self:_xToValue(tap_x)
    local S = self.S
    if self.bookmarks then
        for _, bmpage in ipairs(self.bookmarks) do
            local bmx = self:_valueToX(bmpage)
            if math.abs(tap_x - bmx) < S(20) then 
                v = bmpage; break
            end
        end
    end
    if v ~= self.value then 
        self.value = v
        if self.on_change then self.on_change(v) end 
    end
    return true
end

function ProgressSlider:handlePan(ges)
    if self._dragging then
        local v = self:_xToValue(ges.pos.x - (self.dimen.x or 0))
        if v ~= self.value then 
            self.value = v
            if self.on_change then self.on_change(v) end 
        end
        return true
    end
    if not (self.dimen and ges.pos:intersectWith(self.dimen)) then return false end
    local dir = ges.direction
    if dir == "north" or dir == "south" then return false end
    self._dragging = true
    local v = self:_xToValue(ges.pos.x - self.dimen.x)
    if v ~= self.value then 
        self.value = v
        if self.on_change then self.on_change(v) end 
    end
    return true
end

function ProgressSlider:handlePanRelease(ges)
    if not self._dragging then return false end
    self._dragging = false
    local v = self:_xToValue(ges.pos.x - (self.dimen.x or 0))
    if v ~= self.value then self.value = v end
    if self.on_change then self.on_change(self.value) end 
    return true
end

function ProgressSlider:getDisplayPageInfo(raw_page, ui)
    if not ui then return raw_page, self.value_max end

    local disp_page, disp_total = nil, nil

    if ui.pagemap then
        local pm = ui.pagemap
        disp_total = pm.page_count or self.value_max

        local funcs_to_try = { "getPageText", "getPageLabel", "pageNumberToLabel", "getLabel", "getPageString" }
        for _, fn_name in ipairs(funcs_to_try) do
            if type(pm[fn_name]) == "function" then
                local ok, res = pcall(function() return pm[fn_name](pm, raw_page) end)
                if ok and res and res ~= "" then
                    disp_page = res
                    break
                end
            end
        end
    end

    if not disp_page and ui.document then
        local doc = ui.document
        
        local funcs_to_try = { "getFormattedPage", "getRefPage", "getPageText" }
        for _, fn_name in ipairs(funcs_to_try) do
            if type(doc[fn_name]) == "function" then
                local ok, res = pcall(function() return doc[fn_name](doc, raw_page) end)
                if ok and res and res ~= "" then
                    disp_page = res
                    disp_total = self.value_max
                    break
                end
            end
        end

        if not disp_page and type(doc.hasHiddenFlows) == "function" then
            local ok, has_flows = pcall(function() return doc:hasHiddenFlows() end)
            if ok and has_flows then
                pcall(function()
                    local flow = doc:getPageFlow(raw_page)
                    disp_page = doc:getPageNumberInFlow(raw_page)
                    disp_total = doc:getTotalPagesInFlow(flow)
                end)
            end
        end
    end

    return disp_page or raw_page, disp_total or self.value_max
end

return ProgressSlider

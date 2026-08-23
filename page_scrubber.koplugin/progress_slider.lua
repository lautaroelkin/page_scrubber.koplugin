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

local function paintCircle(bb, cx, cy, r, color)
    if r <= 0 then return end
    for row = -r, r do
        local half = math.floor(math.sqrt(r*r - row*row) + 0.5)
        if half > 0 then bb:paintRect(cx - half, cy + row, half * 2, 1, color) end
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
    return obj
end

function ProgressSlider:getSize() return self.dimen end

function ProgressSlider:_valueToX(v)
    local range = self.value_max - self.value_min
    if range == 0 then return self.knob_r end
    return self.knob_r + (v - self.value_min) / range * ((self.width or 0) - self.knob_r * 2)
end

function ProgressSlider:_xToValue(lx)
    local range = self.value_max - self.value_min
    local frac = (lx - self.knob_r) / math.max(1, (self.width or 0) - self.knob_r * 2)
    frac = math.max(0, math.min(1, frac))
    return math.floor(self.value_min + frac * range + 0.5)
end

function ProgressSlider:paintTo(bb, x, y)
    self.dimen.x = x; self.dimen.y = y
    local w, h = self.width or 0, self.height
    local r = self.knob_r
    local cy = math.floor(y + h / 2)
    local S = self.S
    
    paintPill(bb, x, cy - S(2), w, S(4), Blitbuffer.COLOR_LIGHT_GRAY)
    local frac = (self.value - self.value_min) / math.max(1, self.value_max - self.value_min)
    local fw = math.floor(frac * w + 0.5)
    
    if fw > 0 then paintPill(bb, x, cy - S(2), fw, S(4), Blitbuffer.COLOR_BLACK) end

    if self.bookmarks then
        for _, bmpage in ipairs(self.bookmarks) do
            if bmpage >= self.value_min and bmpage <= self.value_max then
                local bmx = math.floor(x + self:_valueToX(bmpage))
                paintCircle(bb, bmx, cy, S(9), Blitbuffer.COLOR_WHITE)
                paintCircle(bb, bmx, cy, S(6), Blitbuffer.COLOR_BLACK)
            end
        end
    end

    if not self._dragging then
        local kx = math.floor(x + self:_valueToX(self.value))
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

return ProgressSlider

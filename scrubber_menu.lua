--[[
    page_scrubber.koplugin/scrubber_menu.lua
    Popup rápido de lectura y configuración con diseño minimalista y sombra Glimpse
]]--

local Device          = require("device")
local Blitbuffer      = require("ffi/blitbuffer")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local Event           = require("ui/event")
local Notification    = require("ui/widget/notification")
local _               = require("gettext")

local Screen = Device.screen
local plugin_path = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"

local function scale(px)
    local scale_factor = (G_reader_settings and G_reader_settings:readSetting("page_scrubber_ui_scale")) or 1.0
    return math.floor(Screen:scaleBySize(px) * scale_factor + 0.5)
end

local function expandRect(geom, pad)
    return Geom:new{
        x = geom.x - pad,
        y = geom.y - pad,
        w = geom.w + (pad * 2),
        h = geom.h + (pad * 2),
    }
end

-- ============================================================================
-- SOMBRA ORDENADA POR DITHERING (BAYER 8x8) ESTILO GLIMPSE
-- ============================================================================
local SHADOW_BAYER8 = {
    { 0, 32,  8, 40,  2, 34, 10, 42},
    {48, 16, 56, 24, 50, 18, 58, 26},
    {12, 44,  4, 36, 14, 46,  6, 38},
    {60, 28, 52, 20, 62, 30, 54, 22},
    { 3, 35, 11, 43,  1, 33,  9, 41},
    {51, 19, 59, 27, 49, 17, 57, 25},
    {15, 47,  7, 39, 13, 45,  5, 37},
    {63, 31, 55, 23, 61, 29, 53, 21},
}

local _shadow_cache = {}
local function drop_shadow_bb(w, h, r, blur, dy, opacity, night, dither)
    local value = night and 0xFF or 0x00
    local key = table.concat({ w, h, r, blur, dy, opacity, value, dither and 1 or 0 }, ":")
    if _shadow_cache[key] then return _shadow_cache[key] end
    local sw, sh = w + 2 * blur, h + 2 * blur + dy
    local bb = Blitbuffer.new(sw, sh, Blitbuffer.TYPE_BBRGB32)

    local inL, inR = blur + r, blur + w - r
    local inT, inB = blur + r, blur + h - r

    local function emit(px, py)
        local sx = math.min(math.max(px + 0.5, blur + r), blur + w - r)
        local sy = math.min(math.max(py + 0.5, blur + r), blur + h - r)
        local ddx, ddy = px + 0.5 - sx, py + 0.5 - sy
        local dist = math.sqrt(ddx * ddx + ddy * ddy) - r
        local cov = dist <= 0 and 1 or math.max(0, 1 - dist / blur)
        if cov > 0 then
            cov = cov * cov * (3 - 2 * cov)
            if dither then
                local level = opacity * cov * 255
                local threshold = (SHADOW_BAYER8[(px % 8) + 1][(py % 8) + 1] + 0.5) * 4
                if level > threshold then
                    bb:setPixel(px, py, Blitbuffer.ColorRGB32(value, value, value, 255))
                end
            else
                local a = math.floor(opacity * cov * 255 + 0.5)
                if a > 0 then
                    bb:setPixel(px, py, Blitbuffer.ColorRGB32(value, value, value, a))
                end
            end
        end
    end

    for py = 0, sh - 1 do
        if py >= inT and py < inB then
            for px = 0, inL - 1 do emit(px, py) end
            for px = inR, sw - 1 do emit(px, py) end
        else
            for px = 0, sw - 1 do emit(px, py) end
        end
    end

    _shadow_cache[key] = bb
    return bb
end

local function paint_drop_shadow(bb, x, y, w, h, r, blur, dy, day_op, night_op, dither, is_night)
    local s = drop_shadow_bb(w, h, r, blur, dy, is_night and night_op or day_op, is_night, dither)
    local sw, sh = s:getWidth(), s:getHeight()
    local ox, oy = x - blur, y - blur + dy
    local inL, inR = blur + r, blur + w - r
    local inT, inB = blur + r, blur + h - r
    if inR <= inL or inB <= inT then
        bb:alphablitFrom(s, ox, oy, 0, 0, sw, sh)
        return
    end
    bb:alphablitFrom(s, ox, oy, 0, 0, sw, inT)
    bb:alphablitFrom(s, ox, oy + inB, 0, inB, sw, sh - inB)
    bb:alphablitFrom(s, ox, oy + inT, 0, inT, inL, inB - inT)
    bb:alphablitFrom(s, ox + inR, oy + inT, inR, inT, sw - inR, inB - inT)
end

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

-- ==========================================
-- CARGADOR DE ÍCONOS SVG
-- ==========================================
local function getSvgPath(filename)
    local paths = {
        plugin_path .. "icons/" .. filename,
        plugin_path .. filename
    }
    for _, p in ipairs(paths) do
        local f = io.open(p, "r")
        if f then
            f:close()
            return p
        end
    end
    return nil
end

local function loadSvg(filename, w, h)
    local path = getSvgPath(filename)
    if not path then return nil end
    local ImageWidget = require("ui/widget/imagewidget")
    local ok, widget = pcall(function()
        return ImageWidget:new{
            file = path,
            width = w,
            height = h or w,
            alpha = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            original_in_nightmode = false,
        }
    end)
    if ok and widget then return widget end
    return nil
end

-- ==========================================
-- WIDGET PRINCIPAL
-- ==========================================
local ScrubberMenu = InputContainer:extend({
    ui = nil,
    scrubber_ui = nil,
    alpha = 0.25,
})

function ScrubberMenu:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()

    self.card_w = scale(196)
    self.card_h = scale(124)

    self._fl_on = self:readInitialFrontlightState()

    local top_bar = self.scrubber_ui and self.scrubber_ui._top_bar_dimen
    local top_bar_bottom = top_bar and (top_bar.y + top_bar.h) or scale(58)
    local target_y = top_bar_bottom + scale(6)

    local fn = self.scrubber_ui and self.scrubber_ui._fn_dimen
    local target_x
    if fn then
        target_x = (fn.x + fn.w) - self.card_w + scale(6)
    else
        target_x = sw - self.card_w - scale(14)
    end

    if target_x + self.card_w > sw - scale(8) then
        target_x = sw - self.card_w - scale(8)
    end
    if target_x < scale(8) then
        target_x = scale(8)
    end

    self.popup_rect = Geom:new{ x = target_x, y = target_y, w = self.card_w, h = self.card_h }
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    local icon_sz = scale(28)
    self.icon_sun = loadSvg("sun.svg", icon_sz, icon_sz)
    self.icon_wifi = loadSvg("wifi-zero.svg", icon_sz, icon_sz)
    self.icon_toggle_on = loadSvg("toggle-right.svg", icon_sz, icon_sz)
    self.icon_toggle_off = loadSvg("toggle-left.svg", icon_sz, icon_sz)

    self.tw_check = TextWidget:new{
        text = "✓",
        face = Font:getFace("cfont", scale(18)),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        }
    end
end

function ScrubberMenu:readInitialFrontlightState()
    if G_reader_settings then
        local saved = G_reader_settings:readSetting("page_scrubber_frontlight_state")
        if saved ~= nil then return saved == true end
    end

    if Device.hasFrontlight and Device:hasFrontlight() then
        if Device.power and type(Device.power.isFrontlightOn) == "function" then
            local ok, val = pcall(function() return Device.power:isFrontlightOn() end)
            if ok and val ~= nil then return val == true end
        end
        if G_reader_settings then
            local fl = G_reader_settings:readSetting("frontlight")
            if fl ~= nil then return fl ~= 0 end
        end
    end
    return false
end

function ScrubberMenu:isFrontlightOn()
    return self._fl_on == true
end

function ScrubberMenu:toggleFrontlight()
    self._fl_on = not self._fl_on

    if G_reader_settings then
        G_reader_settings:saveSetting("page_scrubber_frontlight_state", self._fl_on)
        G_reader_settings:saveSetting("frontlight", self._fl_on and 1 or 0)
        G_reader_settings:flush()
    end

    pcall(function()
        if self.ui and self.ui.handleEvent then
            self.ui:handleEvent(Event:new("ToggleFrontlight"))
        elseif Device.power and type(Device.power.toggleFrontlight) == "function" then
            Device.power:toggleFrontlight()
        end
    end)

    local status_text = self._fl_on and _("Frontlight enabled") or _("Frontlight disabled")
    UIManager:show(Notification:new{
        text = status_text,
    })

    UIManager:setDirty(self, "ui", expandRect(self.popup_rect, scale(8)))
end

function ScrubberMenu:isNightMode()
    if Device.screen and Device.screen.night_mode ~= nil then
        return Device.screen.night_mode
    end
    if G_reader_settings then
        return G_reader_settings:readSetting("night_mode") == true
    end
    return false
end

function ScrubberMenu:setNightMode(enable)
    local current = self:isNightMode()
    if current ~= enable then
        if self.ui and self.ui.handleEvent then
            self.ui:handleEvent(Event:new("ToggleNightMode"))
        elseif Device.screen and Device.screen.toggleNightMode then
            Device.screen:toggleNightMode()
        end
        UIManager:setDirty(nil, "full")
    end
end

function ScrubberMenu:paintTo(bb, x, y)
    local r = self.popup_rect
    local pad = scale(12)
    local border = scale(2)
    local radius = scale(16)

    local is_night = self:isNightMode()

    paint_drop_shadow(bb, r.x, r.y, r.w, r.h, radius, scale(5), scale(3), 0.35, 0.55, true, is_night)

    paintRoundRect(bb, r.x, r.y, r.w, r.h, radius, Blitbuffer.COLOR_BLACK)
    paintRoundRect(bb, r.x + border, r.y + border, r.w - (border * 2), r.h - (border * 2), math.max(1, radius - border), Blitbuffer.COLOR_WHITE)

    -- ----------------------------------------------------
    -- 1. FILA SUPERIOR: Recuadros Día / Noche
    -- ----------------------------------------------------
    local swatch_y = r.y + pad + scale(2)
    local swatch_h = scale(40)
    local gap = scale(10)
    local swatch_w = math.floor((r.w - (pad * 2) - gap) / 2)
    local swatch_r = scale(8)

    local day_fill, day_border, day_check_color
    local night_fill, night_border, night_check_color

    if not is_night then
        day_fill = Blitbuffer.COLOR_WHITE
        day_border = Blitbuffer.COLOR_BLACK
        day_check_color = Blitbuffer.COLOR_BLACK

        night_fill = Blitbuffer.COLOR_BLACK
        night_border = Blitbuffer.COLOR_BLACK
        night_check_color = Blitbuffer.COLOR_WHITE
    else
        day_fill = Blitbuffer.COLOR_BLACK
        day_border = Blitbuffer.COLOR_WHITE
        day_check_color = Blitbuffer.COLOR_WHITE

        night_fill = Blitbuffer.COLOR_WHITE
        night_border = Blitbuffer.COLOR_BLACK
        night_check_color = Blitbuffer.COLOR_BLACK
    end

    -- Recuadro Día
    local day_x = r.x + pad
    self.swatch_day_dimen = Geom:new{ x = day_x, y = swatch_y, w = swatch_w, h = swatch_h }
    paintRoundRect(bb, day_x, swatch_y, swatch_w, swatch_h, swatch_r, day_border)
    paintRoundRect(bb, day_x + border, swatch_y + border, swatch_w - (border * 2), swatch_h - (border * 2), math.max(1, swatch_r - border), day_fill)

    if not is_night then
        self.tw_check.fgcolor = day_check_color
        local csz = self.tw_check:getSize()
        self.tw_check:paintTo(bb, day_x + math.floor((swatch_w - csz.w) / 2), swatch_y + math.floor((swatch_h - csz.h) / 2))
    end

    -- Recuadro Noche
    local night_x = day_x + swatch_w + gap
    self.swatch_night_dimen = Geom:new{ x = night_x, y = swatch_y, w = swatch_w, h = swatch_h }
    paintRoundRect(bb, night_x, swatch_y, swatch_w, swatch_h, swatch_r, night_border)
    paintRoundRect(bb, night_x + border, swatch_y + border, swatch_w - (border * 2), swatch_h - (border * 2), math.max(1, swatch_r - border), night_fill)

    if is_night then
        self.tw_check.fgcolor = night_check_color
        local csz = self.tw_check:getSize()
        self.tw_check:paintTo(bb, night_x + math.floor((swatch_w - csz.w) / 2), swatch_y + math.floor((swatch_h - csz.h) / 2))
    end

    -- ----------------------------------------------------
    -- 2. FILA INFERIOR: Sol + Toggle (Izquierda) ... WiFi (Derecha)
    -- ----------------------------------------------------
    local bottom_y = swatch_y + swatch_h + scale(12)
    local bottom_h = scale(38)

    -- Sol (28 px)
    local sun_sz = scale(28)
    local sun_x = r.x + pad
    local sun_y = bottom_y + math.floor((bottom_h - sun_sz) / 2)
    if self.icon_sun then
        self.icon_sun:paintTo(bb, sun_x, sun_y)
    end

    -- Toggle (28 px, mismo tamaño que el sol)
    local toggle_sz = scale(28)
    local toggle_x = sun_x + sun_sz + scale(8)
    local toggle_y = bottom_y + math.floor((bottom_h - toggle_sz) / 2)
    local is_fl = self:isFrontlightOn()
    local toggle_widget = is_fl and self.icon_toggle_on or self.icon_toggle_off

    if toggle_widget then
        toggle_widget:paintTo(bb, toggle_x, toggle_y)
    else
        local tw_w = scale(40)
        local tw_h = scale(25)
        local tr = math.floor(tw_h / 2)
        local circle_d = tw_h - scale(4)
        local circle_r = math.floor(circle_d / 2)
        local fb_y = bottom_y + math.floor((bottom_h - tw_h) / 2)
        if is_fl then
            paintRoundRect(bb, toggle_x, fb_y, tw_w, tw_h, tr, Blitbuffer.COLOR_BLACK)
            local cx = toggle_x + tw_w - scale(2) - circle_d
            local cy = fb_y + scale(2)
            paintRoundRect(bb, cx, cy, circle_d, circle_d, circle_r, Blitbuffer.COLOR_WHITE)
        else
            paintRoundRect(bb, toggle_x, fb_y, tw_w, tw_h, tr, Blitbuffer.COLOR_BLACK)
            paintRoundRect(bb, toggle_x + scale(1), fb_y + scale(1), tw_w - scale(2), tw_h - scale(2), tr - scale(1), Blitbuffer.COLOR_WHITE)
            local cx = toggle_x + scale(2)
            local cy = fb_y + scale(2)
            paintRoundRect(bb, cx, cy, circle_d, circle_d, circle_r, Blitbuffer.COLOR_BLACK)
        end
    end

    -- Hitbox táctil unificada para Sol + Toggle
    local toggle_w = toggle_widget and toggle_sz or scale(40)
    self.row_light_dimen = Geom:new{
        x = sun_x - scale(4),
        y = bottom_y - scale(2),
        w = (toggle_x + toggle_w) - sun_x + scale(8),
        h = bottom_h + scale(4)
    }

    -- Botón de configuraciones (wifi-zero a 28 px)
    local wifi_sz = scale(28)
    local wifi_x = r.x + r.w - pad - wifi_sz
    local wifi_y = bottom_y + math.floor((bottom_h - wifi_sz) / 2)
    self.btn_wifi_dimen = Geom:new{
        x = wifi_x - scale(4),
        y = bottom_y - scale(2),
        w = wifi_sz + scale(8),
        h = bottom_h + scale(4)
    }

    if self._pressed_btn == "wifi" then
        paintRoundRect(bb, wifi_x, wifi_y, wifi_sz, wifi_sz, scale(6), Blitbuffer.COLOR_BLACK)
        if self.icon_wifi then
            local isz = self.icon_wifi:getSize()
            local ix = wifi_x + math.floor((wifi_sz - isz.w) / 2)
            local iy = wifi_y + math.floor((wifi_sz - isz.h) / 2)
            bb:paintRect(ix, iy, isz.w, isz.h, Blitbuffer.COLOR_WHITE)
            self.icon_wifi:paintTo(bb, ix, iy)
            bb:invertRect(ix, iy, isz.w, isz.h)
        end
    else
        if self.icon_wifi then
            local isz = self.icon_wifi:getSize()
            local ix = wifi_x + math.floor((wifi_sz - isz.w) / 2)
            local iy = wifi_y + math.floor((wifi_sz - isz.h) / 2)
            self.icon_wifi:paintTo(bb, ix, iy)
        end
    end
end

function ScrubberMenu:onTap(arg1, arg2)
    local ges = arg2 or arg1
    if not ges or not ges.pos then return false end

    if not ges.pos:intersectWith(self.popup_rect) then
        UIManager:close(self)
        return true
    end

    if self.btn_wifi_dimen and ges.pos:intersectWith(self.btn_wifi_dimen) then
        self._pressed_btn = "wifi"
        UIManager:setDirty(self, "ui", expandRect(self.popup_rect, scale(8)))
        UIManager:scheduleIn(0.06, function()
            self._pressed_btn = nil
            local ui = self.ui
            local scrubber_ui = self.scrubber_ui
            UIManager:close(self)
            UIManager:nextTick(function()
                local ScrubberSettings = require("scrubber_settings")
                UIManager:show(ScrubberSettings:new{
                    ui = ui,
                    scrubber_ui = scrubber_ui,
                })
            end)
        end)
        return true
    end

    if self.swatch_day_dimen and ges.pos:intersectWith(self.swatch_day_dimen) then
        self:setNightMode(false)
        UIManager:setDirty(self, "ui", expandRect(self.popup_rect, scale(8)))
        return true
    end

    if self.swatch_night_dimen and ges.pos:intersectWith(self.swatch_night_dimen) then
        self:setNightMode(true)
        UIManager:setDirty(self, "ui", expandRect(self.popup_rect, scale(8)))
        return true
    end

    if self.row_light_dimen and ges.pos:intersectWith(self.row_light_dimen) then
        self:toggleFrontlight()
        return true
    end

    return true
end

function ScrubberMenu:onShow()
    UIManager:setDirty(self, "ui", expandRect(self.popup_rect, scale(8)))
end

function ScrubberMenu:onCloseWidget()
    local to_free = {
        self.icon_sun, self.icon_wifi,
        self.icon_toggle_on, self.icon_toggle_off,
        self.tw_check
    }
    for _, w in ipairs(to_free) do
        if w and w.free then pcall(function() w:free() end) end
    end
    UIManager:setDirty(nil, "ui", expandRect(self.popup_rect, scale(8)))
end

return ScrubberMenu

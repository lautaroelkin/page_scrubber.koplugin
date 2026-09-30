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

local function getTextOffset()
    if not G_reader_settings then return 0 end
    local size = G_reader_settings:readSetting("page_scrubber_text_size")
    if size == "small" then return -2
    elseif size == "large" then return 2 end
    return 0
end

local function scale(px)
    local scale_factor = (G_reader_settings and G_reader_settings:readSetting("page_scrubber_ui_scale")) or 1.0
    return math.floor(Screen:scaleBySize(px) * scale_factor + 0.5)
end

local function scaleText(px)
    return scale(px + getTextOffset())
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
-- WIDGETS DE PUNTITOS Y PÍLDORA ESTILO GLIMPSE
-- ==========================================
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local GlimpseDots = Widget:extend{
    nb = 1, cur = 1, dot_r = 3, pitch = 11, height = 10,
}
function GlimpseDots:getSize()
    local r_max = math.floor(self.dot_r * 1.5)
    return Geom:new{ w = math.floor((self.nb - 1) * self.pitch + 2 * r_max), h = math.floor(self.height) }
end
function GlimpseDots:paintTo(bb, x, y)
    local cy = y + math.floor(self.height / 2)
    local r_max = math.floor(self.dot_r * 1.5)
    local x0 = x + r_max
    for i = 1, self.nb do
        local cx = x0 + (i - 1) * self.pitch
        local is_active = (i == self.cur)
        local color = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
        local r = is_active and r_max or self.dot_r
        paintRoundRect(bb, cx - r, cy - r, r * 2, r * 2, r, color)
    end
end

local GlimpsePill = WidgetContainer:extend{
    inner = nil, padding_h = 9, height = 21, radius = 8, stroke = 2,
}
function GlimpsePill:getSize()
    local inner = self.inner:getSize()
    return Geom:new{ w = math.floor(inner.w + 2 * self.padding_h), h = math.floor(math.max(self.height, inner.h)) }
end
function GlimpsePill:paintTo(bb, x, y)
    local size = self:getSize()
    local w, h = size.w, size.h
    self.dimen = Geom:new{ x = x, y = y, w = w, h = h }
    paintRoundRect(bb, x, y, w, h, self.radius, Blitbuffer.COLOR_WHITE)
    local inner_size = self.inner:getSize()
    self.inner:paintTo(bb, x + math.floor((w - inner_size.w) / 2), y + math.floor((h - inner_size.h) / 2))
end
function GlimpsePill:free(...)
    if self.inner and self.inner.free then
        self.inner:free()
    end
    WidgetContainer.free(self, ...)
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
    if type(h) ~= "number" or h <= 0 then
        h = w
    end
    local ImageWidget = require("ui/widget/imagewidget")
    local ok, widget = pcall(function()
        return ImageWidget:new{
            file = path,
            width = w,
            height = h,
            alpha = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            original_in_nightmode = false,
        }
    end)
    if ok and widget then return widget end
    return nil
end


-- ==========================================
-- RESOLUCIÓN DE FUENTES (CRENGINE + FONT INDEX)
-- ==========================================
local function getCreFace(font_name, size)
    if not font_name or font_name == "" then
        return Font:getFace("cfont", size)
    end

    -- 1. Intentar obtener archivo físico e índice de cara mediante crengine (idéntico a readerfont.lua)
    local ok_cre, credoc = pcall(require, "document/credocument")
    if ok_cre and credoc and credoc.engineInit then
        local ok_init, cre = pcall(credoc.engineInit, credoc)
        if ok_init and cre and cre.getFontFaceFilenameAndFaceIndex then
            local file, idx = cre.getFontFaceFilenameAndFaceIndex(font_name)
            if not file then
                file, idx = cre.getFontFaceFilenameAndFaceIndex(font_name, nil, true)
            end
            if file and idx then
                local ok_face, face = pcall(Font.getFace, Font, file, size, idx)
                if ok_face and face then
                    return face
                end
            end
        end
    end

    -- 2. Intento directo por nombre de familia
    local ok_dir, dir_face = pcall(Font.getFace, Font, font_name, size)
    if ok_dir and dir_face then
        return dir_face
    end

    -- 3. Fallback seguro a la fuente del sistema
    return Font:getFace("cfont", size)
end

-- ==========================================
-- WIDGET PRINCIPAL CON PESTAÑAS (PULIDO)
-- ==========================================
local ScrubberMenu = InputContainer:extend({
    ui = nil,
    scrubber_ui = nil,
    alpha = 0.25,
    active_tab = "quick", -- "quick" | "typo" | "font_list" | "actions_list"
    font_page = 1,
    actions_page = 1,
})

function ScrubberMenu:new(o)
    if G_reader_settings and G_reader_settings:readSetting("page_scrubber_quick_menu") == false then
        local ScrubberSettings = require("scrubber_settings")
        return ScrubberSettings:new(o)
    end
    return InputContainer.new(self, o)
end

function ScrubberMenu:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()

    self.is_modal = true

    local start_tab = "quick"
    if G_reader_settings then
        start_tab = G_reader_settings:readSetting("page_scrubber_quick_menu_start_tab") or "quick"
    end
    self.active_tab = start_tab

    self.font_page = 1
    self.actions_page = 1
    self._typo_changed = false
    self._fl_on = self:readInitialFrontlightState()

    local icon_sz = scale(28)
    self.icon_sun = loadSvg("sun.svg", scale(32), scale(32))
    self.icon_warehouse = loadSvg("warehouse.svg", icon_sz, icon_sz)
    self.icon_wifi = loadSvg("wifi-zero.svg", icon_sz, icon_sz)
    self.icon_chevron_right = loadSvg("chevron-right.svg", scale(16), scale(16))
    self.icon_toggle_on = loadSvg("toggle-right.svg", scale(26), scale(26))
    self.icon_toggle_off = loadSvg("toggle-left.svg", scale(26), scale(26))
    self.tw_check = TextWidget:new{
        text = "✓",
        face = Font:getFace("cfont", scale(18)),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self:updateLayout()

    if Device:isTouchDevice() then
        self.ges_events = {
            Tap   = { GestureRange:new{ ges = "tap",   range = self.dimen } },
            Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
    end
end

function ScrubberMenu:onHold() return true end

function ScrubberMenu:onSwipe(arg1, arg2)
    local ges = arg2 or arg1
    if not ges then return true end

    -- Swipe horizontal sobre la fila de fuente para cambiar entre fuentes
    if self.active_tab == "typo" and self.btn_font_row_dimen then
        local p = ges.pos or ges.start_pos
        if p and p:intersectWith(self.btn_font_row_dimen) then
            local dir = ges.direction
            if dir == "left" or dir == "west" then
                self:cycleBookFont(1)
                return true
            elseif dir == "right" or dir == "east" then
                self:cycleBookFont(-1)
                return true
            end
        end
    end

    -- Swipe para cambiar de página en el catálogo de fuentes o acciones
    if self.active_tab == "font_list" then
        local dir = ges.direction
        if dir == "left" or dir == "west" or dir == "up" or dir == "north" then
            if self.font_page < (self.font_total_pages or 1) then
                self.font_page = self.font_page + 1
                self:refreshMenu()
            end
        elseif dir == "right" or dir == "east" or dir == "down" or dir == "south" then
            if self.font_page > 1 then
                self.font_page = self.font_page - 1
                self:refreshMenu()
            end
        end
    elseif self.active_tab == "actions_list" then
        local dir = ges.direction
        if dir == "left" or dir == "west" or dir == "up" or dir == "north" then
            if self.actions_page < (self.actions_total_pages or 1) then
                self.actions_page = self.actions_page + 1
                self:refreshMenu()
            end
        elseif dir == "right" or dir == "east" or dir == "down" or dir == "south" then
            if self.actions_page > 1 then
                self.actions_page = self.actions_page - 1
                self:refreshMenu()
            end
        end
    end
    return true
end

function ScrubberMenu:updateLayout()
    local sw = Screen:getWidth()
    self.tab_h = scale(32)

    -- Tamaño unificado y fijo: la ventana NUNCA cambia de tamaño
    self.card_w = scale(224)
    self.card_h = self.tab_h + scale(128) + scale(4) -- scale(164)

    -- Subvistas paginadas (fuentes y acciones)
    self.fonts_per_page = 4
    self.actions_per_page = 4
    self.font_row_h = scale(25)
    self.font_footer_h = scale(28)

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
end

function ScrubberMenu:refreshMenu()
    local prev_rect = self.popup_rect
    self:updateLayout()

    local dirty_geom = expandRect(self.popup_rect, scale(8))
    if prev_rect then
        local p_exp = expandRect(prev_rect, scale(8))
        local min_x = math.min(p_exp.x, dirty_geom.x)
        local min_y = math.min(p_exp.y, dirty_geom.y)
        local max_x = math.max(p_exp.x + p_exp.w, dirty_geom.x + dirty_geom.w)
        local max_y = math.max(p_exp.y + p_exp.h, dirty_geom.y + dirty_geom.h)
        dirty_geom = Geom:new{ x = min_x, y = min_y, w = max_x - min_x, h = max_y - min_y }
    end

    local function getDirty() return "ui", dirty_geom end
    UIManager:setDirty(self, getDirty)
end

-- ==========================================
-- LECTURA Y AJUSTE DE TIPOGRAFÍA
-- ==========================================
function ScrubberMenu:getAvailableFonts()
    local favs = (G_reader_settings and G_reader_settings:readSetting("page_scrubber_favorite_fonts"))
    if type(favs) == "table" then
        return favs
    end
    return {}
end

function ScrubberMenu:getBookFontFace()
    local ui = self.ui
    if ui and ui.font and ui.font.configurable and ui.font.configurable.font_face then
        return ui.font.configurable.font_face
    end
    if ui and ui.font and ui.font.font_face then
        return ui.font.font_face
    end
    if ui and ui.doc_settings then
        local f = ui.doc_settings:readSetting("font_face") or ui.doc_settings:readSetting("cre_font_family")
        if f then return f end
    end
    if G_reader_settings then
        local f = G_reader_settings:readSetting("cre_font_family") or G_reader_settings:readSetting("font_face")
        if f then return f end
    end
    return "Serif"
end

function ScrubberMenu:getBookFontSize()
    if self._pending_font_size then
        return self._pending_font_size
    end
    local ui = self.ui
    if ui and ui.font and ui.font.configurable and ui.font.configurable.font_size then
        return tonumber(ui.font.configurable.font_size) or 22
    end
    if ui and ui.font and type(ui.font.font_size) == "number" then
        return ui.font.font_size
    end
    if ui and ui.doc_settings then
        local sz = ui.doc_settings:readSetting("font_size") or ui.doc_settings:readSetting("cre_font_size")
        if sz then return tonumber(sz) or 22 end
    end
    if G_reader_settings then
        local sz = G_reader_settings:readSetting("cre_font_size") or G_reader_settings:readSetting("font_size")
        if sz then return tonumber(sz) or 22 end
    end
    return 22
end

function ScrubberMenu:getBookLineSpacing()
    if self._pending_line_space then
        return self._pending_line_space
    end
    local ui = self.ui
    local pct
    if ui and ui.font and ui.font.configurable then
        pct = ui.font.configurable.line_space_percent or ui.font.configurable.line_spacing
    end
    if not pct and ui and ui.font then
        pct = ui.font.line_space_percent or ui.font.line_spacing
    end
    if not pct and ui and ui.doc_settings then
        pct = ui.doc_settings:readSetting("line_space_percent") or ui.doc_settings:readSetting("line_spacing")
    end
    if not pct and G_reader_settings then
        pct = G_reader_settings:readSetting("line_space_percent") or G_reader_settings:readSetting("line_spacing")
    end
    pct = tonumber(pct) or 100
    if pct > 0 and pct <= 3 then pct = math.floor(pct * 100 + 0.5) end
    return pct
end

function ScrubberMenu:notifyScrubberDocumentChanged()
    local s = self.scrubber_ui
    if not s then return end
    pcall(function()
        if self.ui and self.ui.document and self.ui.document.getPageCount then
            s.total_pages = self.ui.document:getPageCount()
        end
        if s._clearGridTiles then s:_clearGridTiles(true) end
        if s._updateChapterMarks then s:_updateChapterMarks() end
        if s._updateGridPages then s:_updateGridPages() end
        if s._updateTexts then s:_updateTexts() end
    end)
end

function ScrubberMenu:applyPendingTypography()
    self._pending_font_size = nil
    self._pending_line_space = nil
end

function ScrubberMenu:setBookFontFace(face_name)
    if not face_name or face_name == "" then return end
    pcall(function()
        if self.ui and self.ui.handleEvent then
            self.ui:handleEvent(Event:new("SetFont", face_name))
        elseif self.ui and self.ui.font and self.ui.font.onSetFont then
            self.ui.font:onSetFont(face_name)
        end
    end)
    self._typo_changed = true
    self:refreshMenu()
end

function ScrubberMenu:cycleBookFont(delta)
    local fonts = self:getAvailableFonts()
    if #fonts == 0 then return end
    local cur = self:getBookFontFace()
    local idx = 1
    for i, f in ipairs(fonts) do
        if f == cur then idx = i; break end
    end
    local next_idx = ((idx - 1 + delta) % #fonts) + 1
    self:setBookFontFace(fonts[next_idx])
end

function ScrubberMenu:changeBookFontSize(delta)
    local cur = self:getBookFontSize()
    local next_sz = math.max(10, math.min(72, cur + delta))
    if next_sz == cur then return end
    self._pending_font_size = next_sz
    self._typo_changed = true

    pcall(function()
        if self.ui and self.ui.handleEvent then
            self.ui:handleEvent(Event:new("SetFontSize", next_sz))
        elseif self.ui and self.ui.font and self.ui.font.onSetFontSize then
            self.ui.font:onSetFontSize(next_sz)
        end
    end)

    self:refreshMenu()
end

function ScrubberMenu:changeBookLineSpacing(delta)
    local cur = self:getBookLineSpacing()
    local next_sp = math.max(70, math.min(250, cur + delta))
    if next_sp == cur then return end
    self._pending_line_space = next_sp
    self._typo_changed = true

    pcall(function()
        if self.ui and self.ui.handleEvent then
            self.ui:handleEvent(Event:new("SetLineSpace", next_sp))
        elseif self.ui and self.ui.font and self.ui.font.onSetLineSpace then
            self.ui.font:onSetLineSpace(next_sp)
        end
    end)

    self:refreshMenu()
end

function ScrubberMenu:readInitialFrontlightState()
    if G_reader_settings then
        local fl = G_reader_settings:readSetting("frontlight")
        if fl ~= nil then return fl ~= 0 end
    end
    return false
end

function ScrubberMenu:isFrontlightOn()
    if self._fl_on == nil then
        self._fl_on = self:readInitialFrontlightState()
    end
    return self._fl_on == true
end

function ScrubberMenu:toggleFrontlight()
    self._fl_on = not self:isFrontlightOn()

    pcall(function()
        local ui = self.ui
        if ui and ui.frontlight and type(ui.frontlight.toggle) == "function" then
            ui.frontlight:toggle()
        elseif ui and ui.handleEvent then
            ui:handleEvent(Event:new("ToggleFrontlight"))
        elseif Device.power and type(Device.power.toggleFrontlight) == "function" then
            Device.power:toggleFrontlight()
        end
    end)

    if G_reader_settings then
        G_reader_settings:saveSetting("frontlight", self._fl_on and 1 or 0)
        G_reader_settings:flush()
    end

    local status_text = self._fl_on and _("Frontlight enabled") or _("Frontlight disabled")
    UIManager:show(Notification:new{
        text = status_text,
    })

    self:refreshMenu()
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

function ScrubberMenu:closeEntireWidget()
    local scrubber = self.scrubber_ui
    UIManager:close(self)
    if scrubber then
        if scrubber._closeStay then
            pcall(function() scrubber:_closeStay() end)
        else
            pcall(function() UIManager:close(scrubber) end)
        end
    else
        UIManager:setDirty(nil, "full")
    end
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

function ScrubberMenu:getQuickActions()
    local actions = (G_reader_settings and G_reader_settings:readSetting("page_scrubber_quick_actions")) or {}
    return actions
end

function ScrubberMenu:getActionIcon(act)
    local ScrubberSettings = require("scrubber_settings")
    if ScrubberSettings and ScrubberSettings.getActionIcon then
        return ScrubberSettings:getActionIcon(act)
    end
    return "package.svg"
end

function ScrubberMenu:executeQuickAction(action_id)
    self:closeEntireWidget()
    UIManager:nextTick(function()
        local ok_disp, Dispatcher = pcall(require, "dispatcher")
        if not ok_disp or not Dispatcher then return end
        pcall(function() Dispatcher:init() end)

        local success = pcall(function()
            Dispatcher:execute({ [action_id] = true })
        end)

        if not success then
            pcall(function()
                Dispatcher:execute(action_id)
            end)
        end
    end)
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

    -- ====================================================
    -- BARRA DE PESTAÑAS (SIN LÍNEA VERTICAL INTERMEDIA)
    -- ====================================================
    local tab_y = r.y + border
    local tab_h = self.tab_h
    local inner_w = r.w - (border * 2)
    local half_w = math.floor(inner_w / 2)

    self.tab_quick_dimen = Geom:new{ x = r.x + border, y = tab_y, w = half_w, h = tab_h }
    self.tab_typo_dimen  = Geom:new{ x = r.x + border + half_w, y = tab_y, w = inner_w - half_w, h = tab_h }

    -- Pestaña 1: Lámpara Unicode \u{EDB3} (activa tanto en vista principal como en actions_list)
    local is_quick = (self.active_tab == "quick" or self.active_tab == "actions_list")
    local tw_gear = TextWidget:new{
        text = "\u{EDB3}",
        face = Font:getFace("cfont", scale(15)),
        bold = is_quick,
        fgcolor = is_quick and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
    }
    local gsz = tw_gear:getSize()
    tw_gear:paintTo(bb, self.tab_quick_dimen.x + math.floor((self.tab_quick_dimen.w - gsz.w) / 2), tab_y + math.floor((tab_h - gsz.h) / 2))
    tw_gear:free()

    local is_typo = (self.active_tab == "typo" or self.active_tab == "font_list")
    local tw_aa = TextWidget:new{
        text = "Aa",
        face = Font:getFace("cfont", scale(13)),
        bold = is_typo,
        fgcolor = is_typo and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
    }
    local aasz = tw_aa:getSize()
    tw_aa:paintTo(bb, self.tab_typo_dimen.x + math.floor((self.tab_typo_dimen.w - aasz.w) / 2), tab_y + math.floor((tab_h - aasz.h) / 2))
    tw_aa:free()

    -- Borde horizontal inferior de pestañas e indicador de selección activa
    bb:paintRect(r.x + border, tab_y + tab_h - 1, inner_w, 1, Blitbuffer.COLOR_BLACK)

    local ind_h = scale(3)
    if is_quick then
        bb:paintRect(self.tab_quick_dimen.x + scale(16), tab_y + tab_h - ind_h, half_w - scale(32), ind_h, Blitbuffer.COLOR_BLACK)
    else
        bb:paintRect(self.tab_typo_dimen.x + scale(16), tab_y + tab_h - ind_h, (inner_w - half_w) - scale(32), ind_h, Blitbuffer.COLOR_BLACK)
    end

    local content_top = tab_y + tab_h

    -- ====================================================
    -- CONTENIDO PESTAÑA 1: RÁPIDO
    -- ====================================================
    if self.active_tab == "quick" then
        local swatch_y = content_top + scale(12)
        local swatch_h = scale(44)
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

        local day_x = r.x + pad
        self.swatch_day_dimen = Geom:new{ x = day_x, y = swatch_y, w = swatch_w, h = swatch_h }
        paintRoundRect(bb, day_x, swatch_y, swatch_w, swatch_h, swatch_r, day_border)
        paintRoundRect(bb, day_x + border, swatch_y + border, swatch_w - (border * 2), swatch_h - (border * 2), math.max(1, swatch_r - border), day_fill)

        if not is_night then
            self.tw_check.fgcolor = day_check_color
            local csz = self.tw_check:getSize()
            self.tw_check:paintTo(bb, day_x + math.floor((swatch_w - csz.w) / 2), swatch_y + math.floor((swatch_h - csz.h) / 2))
        end

        local night_x = day_x + swatch_w + gap
        self.swatch_night_dimen = Geom:new{ x = night_x, y = swatch_y, w = swatch_w, h = swatch_h }
        paintRoundRect(bb, night_x, swatch_y, swatch_w, swatch_h, swatch_r, night_border)
        paintRoundRect(bb, night_x + border, swatch_y + border, swatch_w - (border * 2), swatch_h - (border * 2), math.max(1, swatch_r - border), night_fill)

        if is_night then
            self.tw_check.fgcolor = night_check_color
            local csz = self.tw_check:getSize()
            self.tw_check:paintTo(bb, night_x + math.floor((swatch_w - csz.w) / 2), swatch_y + math.floor((swatch_h - csz.h) / 2))
        end

        local bottom_y = swatch_y + swatch_h + scale(14)
        local bottom_h = scale(40)

        local sun_sz = scale(32)
        local sun_x = r.x + pad + scale(4)
        local sun_y = bottom_y + math.floor((bottom_h - sun_sz) / 2)
        if self.icon_sun then self.icon_sun:paintTo(bb, sun_x, sun_y) end

        local is_fl = self:isFrontlightOn()
        local toggle_sz = scale(26)
        local toggle_x = sun_x + sun_sz + scale(8)
        local toggle_y = bottom_y + math.floor((bottom_h - toggle_sz) / 2)
        local toggle_widget = is_fl and self.icon_toggle_on or self.icon_toggle_off

        if toggle_widget then
            toggle_widget:paintTo(bb, toggle_x, toggle_y)
        end

        self.row_light_dimen = Geom:new{
            x = sun_x - scale(4),
            y = bottom_y - scale(2),
            w = (toggle_x + toggle_sz) - sun_x + scale(8),
            h = bottom_h + scale(4)
        }

        local wifi_sz = scale(28)
        local wifi_x = r.x + r.w - pad - wifi_sz
        local wifi_y = bottom_y + math.floor((bottom_h - wifi_sz) / 2)
        self.btn_wifi_dimen = Geom:new{
            x = wifi_x - scale(4),
            y = bottom_y - scale(2),
            w = wifi_sz + scale(8),
            h = bottom_h + scale(4)
        }

        local actions_sz = scale(28)
        local actions_x = wifi_x - actions_sz - scale(12)
        local actions_y = bottom_y + math.floor((bottom_h - actions_sz) / 2)
        self.btn_actions_dimen = Geom:new{
            x = actions_x - scale(4),
            y = bottom_y - scale(2),
            w = actions_sz + scale(8),
            h = bottom_h + scale(4)
        }

        if self.icon_warehouse then
            local isz = self.icon_warehouse:getSize()
            local ix = actions_x + math.floor((actions_sz - isz.w) / 2)
            local iy = actions_y + math.floor((actions_sz - isz.h) / 2)
            self.icon_warehouse:paintTo(bb, ix, iy)
        end

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

    -- ====================================================
    -- CONTENIDO PESTAÑA 2: TIPOGRAFÍA (PULIDA)
    -- ====================================================
    elseif self.active_tab == "typo" then
        local row_h = scale(42)
        local btn_w = scale(34)
        local btn_h = scale(28)
        local btn_r = scale(8)

        local btn_bg_color = is_night and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_LIGHT_GRAY
        local btn_fg_color = Blitbuffer.COLOR_BLACK

        -- 1. FILA FUENTE: Nombre de Fuente (con su propia font) ... Chevron (Der)
        local r1_y = content_top
        self.btn_font_row_dimen = Geom:new{ x = r.x + border, y = r1_y, w = inner_w, h = row_h }

        local chev_sz = scale(16)
        local chev_x = r.x + r.w - pad - chev_sz
        local chev_y = r1_y + math.floor((row_h - chev_sz) / 2)

        local painted_icon = false
        if self.icon_chevron_right then
            painted_icon = pcall(function() self.icon_chevron_right:paintTo(bb, chev_x, chev_y) end)
        end
        if not painted_icon then
            local tw_c = TextWidget:new{ text = "›", face = Font:getFace("cfont", scale(14)), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
            local csz = tw_c:getSize()
            tw_c:paintTo(bb, chev_x + math.floor((chev_sz - csz.w) / 2), r1_y + math.floor((row_h - csz.h) / 2))
            tw_c:free()
        end

        local cur_font = self:getBookFontFace()
        local max_font_w = math.max(scale(40), chev_x - (r.x + pad) - scale(8))

        local font_face_preview = getCreFace(cur_font, scaleText(13))

        local tw_font = TextWidget:new{
            text = tostring(cur_font),
            face = font_face_preview,
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = max_font_w,
            truncate_with_ellipsis = true,
        }
        local ftsz = tw_font:getSize()
        tw_font:paintTo(bb, r.x + pad, r1_y + math.floor((row_h - ftsz.h) / 2))
        tw_font:free()

        -- 2. FILA TAMAÑO DE TEXTO: [ − ]   Aa (bold)  22 pt (regular)   [ + ]
        local r2_y = r1_y + row_h
        local btn2_y = r2_y + math.floor((row_h - btn_h) / 2)
        local left_btn_x = r.x + pad
        local right_btn_x = r.x + r.w - pad - btn_w

        self.btn_size_dec_dimen = Geom:new{ x = r.x + border, y = r2_y, w = pad + btn_w + scale(6), h = row_h }
        self.btn_size_inc_dimen = Geom:new{ x = right_btn_x - scale(6), y = r2_y, w = pad + btn_w + scale(6), h = row_h }

        -- Botón - \u{F068} (limpio sin fondo)
        local tw_ad = TextWidget:new{ text = "\u{F068}", face = Font:getFace("cfont", scale(13)), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
        local adsz = tw_ad:getSize()
        tw_ad:paintTo(bb, left_btn_x + math.floor((btn_w - adsz.w) / 2), r2_y + math.floor((row_h - adsz.h) / 2))
        tw_ad:free()

        -- Botón + \u{F067} (limpio sin fondo)
        local tw_au = TextWidget:new{ text = "\u{F067}", face = Font:getFace("cfont", scale(13)), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
        local ausz = tw_au:getSize()
        tw_au:paintTo(bb, right_btn_x + math.floor((btn_w - ausz.w) / 2), r2_y + math.floor((row_h - ausz.h) / 2))
        tw_au:free()

        -- Centro: \u{E97E} (ícono tamaño de font) + 22 pt (regular)
        local cur_sz = self:getBookFontSize()
        local tw_aa_ico = TextWidget:new{
            text = "\u{E97E}",
            face = Font:getFace("cfont", scaleText(14)),
            bold = false,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local tw_sz_val = TextWidget:new{
            text = string.format("%d pt", cur_sz),
            face = Font:getFace("cfont", scaleText(11)),
            bold = false,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local aasz2 = tw_aa_ico:getSize()
        local svsz = tw_sz_val:getSize()
        local gap_lbl = scale(6)
        local total_w2 = aasz2.w + gap_lbl + svsz.w
        local start_x2 = r.x + math.floor((r.w - total_w2) / 2)

        tw_aa_ico:paintTo(bb, start_x2, r2_y + math.floor((row_h - aasz2.h) / 2))
        tw_sz_val:paintTo(bb, start_x2 + aasz2.w + gap_lbl, r2_y + math.floor((row_h - svsz.h) / 2))
        tw_aa_ico:free()
        tw_sz_val:free()

        -- 3. FILA INTERLINEADO: [ − ]   \u{E977} (interlineado)  100% (regular)   [ + ]
        local r3_y = r2_y + row_h

        self.btn_space_dec_dimen = Geom:new{ x = r.x + border, y = r3_y, w = pad + btn_w + scale(6), h = row_h }
        self.btn_space_inc_dimen = Geom:new{ x = right_btn_x - scale(6), y = r3_y, w = pad + btn_w + scale(6), h = row_h }

        -- Botón - \u{F068} (limpio sin fondo)
        local tw_m2 = TextWidget:new{ text = "\u{F068}", face = Font:getFace("cfont", scale(13)), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
        local m2sz = tw_m2:getSize()
        tw_m2:paintTo(bb, left_btn_x + math.floor((btn_w - m2sz.w) / 2), r3_y + math.floor((row_h - m2sz.h) / 2))
        tw_m2:free()

        -- Botón + \u{F067} (limpio sin fondo)
        local tw_p2 = TextWidget:new{ text = "\u{F067}", face = Font:getFace("cfont", scale(13)), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
        local p2sz = tw_p2:getSize()
        tw_p2:paintTo(bb, right_btn_x + math.floor((btn_w - p2sz.w) / 2), r3_y + math.floor((row_h - p2sz.h) / 2))
        tw_p2:free()

        -- Centro: \u{E977} (ícono interlineado) + 100% (regular)
        local cur_sp = self:getBookLineSpacing()
        local tw_eq_ico = TextWidget:new{
            text = "\u{E977}",
            face = Font:getFace("cfont", scaleText(14)),
            bold = false,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local tw_sp_val = TextWidget:new{
            text = string.format("%d%%", cur_sp),
            face = Font:getFace("cfont", scaleText(11)),
            bold = false,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local eqsz = tw_eq_ico:getSize()
        local spsz = tw_sp_val:getSize()
        local total_w3 = eqsz.w + gap_lbl + spsz.w
        local start_x3 = r.x + math.floor((r.w - total_w3) / 2)

        tw_eq_ico:paintTo(bb, start_x3, r3_y + math.floor((row_h - eqsz.h) / 2))
        tw_sp_val:paintTo(bb, start_x3 + eqsz.w + gap_lbl, r3_y + math.floor((row_h - spsz.h) / 2))
        tw_eq_ico:free()
        tw_sp_val:free()

    -- ====================================================
    -- SUBVISTA: LISTA PAGINADA DE FUENTES (CADA UNA EN SU PROPIA FUENTE)
    -- ====================================================
    elseif self.active_tab == "font_list" then
        local fonts = self:getAvailableFonts()
        local cur_font = self:getBookFontFace()

        -- Si entran hasta 5 fuentes, mostramos 5 en 1 sola página sin barra inferior
        local per_page = (#fonts <= 5) and 5 or 4
        self.font_total_pages = math.max(1, math.ceil(#fonts / per_page))
        self.font_page = math.max(1, math.min(self.font_page, self.font_total_pages))

        local start_i = (self.font_page - 1) * per_page + 1
        local end_i = math.min(start_i + per_page - 1, #fonts)

        self.font_row_dimens = {}
        local curr_y = content_top
        local rh = self.font_row_h

        if #fonts == 0 then
            local tw_empty = TextWidget:new{
                text = _("+ Add fonts"),
                face = Font:getFace("cfont", scale(11)),
                bold = true,
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            }
            local esz = tw_empty:getSize()
            tw_empty:paintTo(bb, r.x + math.floor((r.w - esz.w) / 2), content_top + scale(40))
            tw_empty:free()
            self.btn_empty_add_font = Geom:new{ x = r.x + border, y = content_top, w = inner_w, h = scale(80) }
            self.font_pill_dimen = nil
            self.font_footer_dimen = nil
        else
            self.btn_empty_add_font = nil
            for i = start_i, end_i do
                local fname = fonts[i]
                local row_rect = Geom:new{ x = r.x + border, y = curr_y, w = inner_w, h = rh }
                table.insert(self.font_row_dimens, { dimen = row_rect, font = fname })

                if i > start_i then
                    bb:paintRect(r.x + border, curr_y, inner_w, 1, Blitbuffer.COLOR_LIGHT_GRAY)
                end

                local is_sel = (fname == cur_font)
                local item_face = getCreFace(fname, scaleText(13))

                local tw_f = TextWidget:new{
                    text = fname,
                    face = item_face,
                    bold = is_sel,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    max_width = inner_w - scale(36),
                    truncate_with_ellipsis = true,
                }
                local fsz = tw_f:getSize()
                tw_f:paintTo(bb, r.x + pad, curr_y + math.floor((rh - fsz.h) / 2))
                tw_f:free()

                if is_sel then
                    local tw_c = TextWidget:new{ text = "✓", face = Font:getFace("cfont", scaleText(13)), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
                    local csz = tw_c:getSize()
                    tw_c:paintTo(bb, r.x + r.w - pad - csz.w, curr_y + math.floor((rh - csz.h) / 2))
                    tw_c:free()
                end

                curr_y = curr_y + rh
            end

            -- Solo mostramos pie con puntitos si hay más de 1 página
            if self.font_total_pages > 1 then
                local fy = content_top + (per_page * rh)
                local fh = self.font_footer_h
                bb:paintRect(r.x + border, fy, inner_w, 1, Blitbuffer.COLOR_BLACK)
                self.font_footer_dimen = Geom:new{ x = r.x + border, y = fy, w = inner_w, h = fh }

                local total_pages = self.font_total_pages
                local cur_page = self.font_page
                local dot_r = math.max(2, math.floor(scale(2.5)))
                local natural_pitch = scale(10)
                local side_reserved = scale(20)
                local budget = inner_w - (side_reserved * 2)

                local pitch = math.min(natural_pitch, (budget - 2 * dot_r) / (total_pages - 1))

                local pill_widget = GlimpsePill:new{
                    padding_h = scale(8), height = scale(16), radius = scale(7), stroke = scale(1),
                    inner = GlimpseDots:new{ nb = total_pages, cur = cur_page, pitch = math.floor(pitch), dot_r = dot_r, height = scale(8) }
                }

                local pill_sz = pill_widget:getSize()
                local pill_x = r.x + math.floor((r.w - pill_sz.w) / 2)
                local pill_y = fy + math.floor((fh - pill_sz.h) / 2)

                self.font_pill_dimen = Geom:new{ x = pill_x, y = pill_y, w = pill_sz.w, h = pill_sz.h }
                self.font_pill_info = { nb = total_pages, pitch = pitch, r_max = math.floor(dot_r * 1.5), pad_h = scale(8) }

                pill_widget:paintTo(bb, pill_x, pill_y)
                pill_widget:free()
            else
                self.font_pill_dimen = nil
                self.font_footer_dimen = nil
            end
        end

    -- ====================================================
    -- SUBVISTA: LISTA PAGINADA DE ACCIONES RÁPIDAS
    -- ====================================================
    elseif self.active_tab == "actions_list" then
        local actions = self:getQuickActions()

        -- Si entran hasta 5 acciones, mostramos 5 en 1 sola página sin barra inferior
        local per_page = (#actions <= 5) and 5 or 4
        self.actions_total_pages = math.max(1, math.ceil(#actions / per_page))
        self.actions_page = math.max(1, math.min(self.actions_page, self.actions_total_pages))

        local start_i = (self.actions_page - 1) * per_page + 1
        local end_i = math.min(start_i + per_page - 1, #actions)

        self.action_row_dimens = {}
        local curr_y = content_top
        local rh = self.font_row_h

        if #actions == 0 then
            local tw_empty = TextWidget:new{
                text = _("+ Add action"),
                face = Font:getFace("cfont", scale(11)),
                bold = true,
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            }
            local esz = tw_empty:getSize()
            tw_empty:paintTo(bb, r.x + math.floor((r.w - esz.w) / 2), content_top + scale(40))
            tw_empty:free()
            self.btn_empty_add_action = Geom:new{ x = r.x + border, y = content_top, w = inner_w, h = scale(80) }
            self.actions_pill_dimen = nil
            self.actions_footer_dimen = nil
        else
            self.btn_empty_add_action = nil
            for i = start_i, end_i do
                local act = actions[i]
                local act_id = (type(act) == "table" and act.id) or tostring(act)
                local act_title = (type(act) == "table" and (act.title or act.id)) or act_id

                local row_rect = Geom:new{ x = r.x + border, y = curr_y, w = inner_w, h = rh }
                table.insert(self.action_row_dimens, { dimen = row_rect, id = act_id })

                if i > start_i then
                    bb:paintRect(r.x + border, curr_y, inner_w, 1, Blitbuffer.COLOR_LIGHT_GRAY)
                end

                local icon_name = self:getActionIcon(act)
                local icon_sz = scale(16)
                local icon_widget = loadSvg(icon_name, icon_sz, Blitbuffer.COLOR_BLACK)
                local text_x = r.x + pad

                if icon_widget then
                    local iy = curr_y + math.floor((rh - icon_sz) / 2)
                    pcall(function() icon_widget:paintTo(bb, text_x, iy) end)
                    text_x = text_x + icon_sz + scale(8)
                end

                local max_w = inner_w - (text_x - (r.x + border)) - scale(8)
                local tw_act = TextWidget:new{
                    text = act_title,
                    face = Font:getFace("cfont", scaleText(13)),
                    bold = false,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    max_width = math.max(scale(40), max_w),
                    truncate_with_ellipsis = true,
                }
                local asz = tw_act:getSize()
                tw_act:paintTo(bb, text_x, curr_y + math.floor((rh - asz.h) / 2))
                tw_act:free()

                curr_y = curr_y + rh
            end

            -- Solo mostramos pie con puntitos si hay más de 1 página
            if self.actions_total_pages > 1 then
                local fy = content_top + (per_page * rh)
                local fh = self.font_footer_h
                bb:paintRect(r.x + border, fy, inner_w, 1, Blitbuffer.COLOR_BLACK)
                self.actions_footer_dimen = Geom:new{ x = r.x + border, y = fy, w = inner_w, h = fh }

                local total_pages = self.actions_total_pages
                local cur_page = self.actions_page
                local dot_r = math.max(2, math.floor(scale(2.5)))
                local natural_pitch = scale(10)
                local side_reserved = scale(20)
                local budget = inner_w - (side_reserved * 2)

                local pitch = math.min(natural_pitch, (budget - 2 * dot_r) / (total_pages - 1))

                local pill_widget = GlimpsePill:new{
                    padding_h = scale(8), height = scale(16), radius = scale(7), stroke = scale(1),
                    inner = GlimpseDots:new{ nb = total_pages, cur = cur_page, pitch = math.floor(pitch), dot_r = dot_r, height = scale(8) }
                }

                local pill_sz = pill_widget:getSize()
                local pill_x = r.x + math.floor((r.w - pill_sz.w) / 2)
                local pill_y = fy + math.floor((fh - pill_sz.h) / 2)

                self.actions_pill_dimen = Geom:new{ x = pill_x, y = pill_y, w = pill_sz.w, h = pill_sz.h }
                self.actions_pill_info = { nb = total_pages, pitch = pitch, r_max = math.floor(dot_r * 1.5), pad_h = scale(8) }

                pill_widget:paintTo(bb, pill_x, pill_y)
                pill_widget:free()
            else
                self.actions_pill_dimen = nil
                self.actions_footer_dimen = nil
            end
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

    -- Cambio de pestaña
    if self.tab_quick_dimen and ges.pos:intersectWith(self.tab_quick_dimen) then
        if self.active_tab == "actions_list" then
            self.active_tab = "quick"
            self:refreshMenu()
        elseif self.active_tab ~= "quick" then
            self.active_tab = "quick"
            self:refreshMenu()
        end
        return true
    end

    if self.tab_typo_dimen and ges.pos:intersectWith(self.tab_typo_dimen) then
        if self.active_tab == "font_list" then
            self.active_tab = "typo"
            self:refreshMenu()
        elseif self.active_tab ~= "typo" then
            self.active_tab = "typo"
            self:refreshMenu()
        end
        return true
    end

    -- Acciones Pestaña 1: Rápido
    if self.active_tab == "quick" then
        if self.btn_actions_dimen and ges.pos:intersectWith(self.btn_actions_dimen) then
            self.actions_page = 1
            self.active_tab = "actions_list"
            self:refreshMenu()
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
            self:refreshMenu()
            return true
        end

        if self.swatch_night_dimen and ges.pos:intersectWith(self.swatch_night_dimen) then
            self:setNightMode(true)
            self:refreshMenu()
            return true
        end

        if self.row_light_dimen and ges.pos:intersectWith(self.row_light_dimen) then
            self:toggleFrontlight()
            self:refreshMenu()
            return true
        end

    -- Acciones Pestaña 2: Tipografía
    elseif self.active_tab == "typo" then
        -- Fila de Fuente (tocar abre el catálogo)
        if self.btn_font_row_dimen and ges.pos:intersectWith(self.btn_font_row_dimen) then
            local fonts = self:getAvailableFonts()
            local cur = self:getBookFontFace()
            for i, f in ipairs(fonts) do
                if f == cur then
                    self.font_page = math.ceil(i / (self.fonts_per_page or 4))
                    break
                end
            end
            self.active_tab = "font_list"
            self:refreshMenu()
            return true
        end

        -- Tamaño de fuente (− / +)
        if self.btn_size_dec_dimen and ges.pos:intersectWith(self.btn_size_dec_dimen) then
            self:changeBookFontSize(-1)
            return true
        end
        if self.btn_size_inc_dimen and ges.pos:intersectWith(self.btn_size_inc_dimen) then
            self:changeBookFontSize(1)
            return true
        end

        -- Interlineado (− / +)
        if self.btn_space_dec_dimen and ges.pos:intersectWith(self.btn_space_dec_dimen) then
            self:changeBookLineSpacing(-5)
            return true
        end
        if self.btn_space_inc_dimen and ges.pos:intersectWith(self.btn_space_inc_dimen) then
            self:changeBookLineSpacing(5)
            return true
        end

    -- Acciones Catálogo de Fuentes
    elseif self.active_tab == "font_list" then
        if self.btn_empty_add_font and ges.pos:intersectWith(self.btn_empty_add_font) then
            local ui = self.ui
            local scrubber_ui = self.scrubber_ui
            UIManager:close(self)
            UIManager:nextTick(function()
                local ScrubberSettings = require("scrubber_settings")
                local inst = ScrubberSettings:new{
                    ui = ui,
                    scrubber_ui = scrubber_ui,
                    current_view = "favorite_fonts",
                }
                inst.history = { "main", "quick_menu" }
                inst.card_w = nil
                inst:updateLayout()
                UIManager:show(inst)
            end)
            return true
        end

        for _, rdef in ipairs(self.font_row_dimens or {}) do
            if ges.pos:intersectWith(rdef.dimen) then
                self:setBookFontFace(rdef.font)
                self.active_tab = "typo"
                self:refreshMenu()
                return true
            end
        end
        -- Toque directo en los puntitos de fuentes (o en la barra de pie)
        if self.font_pill_dimen and ges.pos:intersectWith(self.font_pill_dimen) then
            if self.font_pill_info then
                local rel_x = ges.pos.x - self.font_pill_dimen.x - self.font_pill_info.pad_h - self.font_pill_info.r_max
                local idx = math.floor(rel_x / self.font_pill_info.pitch + 0.5) + 1
                idx = math.max(1, math.min(self.font_pill_info.nb, idx))
                if idx ~= self.font_page then
                    self.font_page = idx
                    self:refreshMenu()
                end
            end
            return true
        end

    -- Acciones Subvista: Acciones Rápidas
    elseif self.active_tab == "actions_list" then
        if self.btn_empty_add_action and ges.pos:intersectWith(self.btn_empty_add_action) then
            local ui = self.ui
            local scrubber_ui = self.scrubber_ui
            UIManager:close(self)
            UIManager:nextTick(function()
                local ScrubberSettings = require("scrubber_settings")
                local inst = ScrubberSettings:new{
                    ui = ui,
                    scrubber_ui = scrubber_ui,
                    current_view = "scrubber_actions",
                }
                UIManager:show(inst)
            end)
            return true
        end

        for _, rdef in ipairs(self.action_row_dimens or {}) do
            if ges.pos:intersectWith(rdef.dimen) then
                self:executeQuickAction(rdef.id)
                return true
            end
        end

        -- Toque directo en los puntitos de acciones
        if self.actions_pill_dimen and ges.pos:intersectWith(self.actions_pill_dimen) then
            if self.actions_pill_info then
                local rel_x = ges.pos.x - self.actions_pill_dimen.x - self.actions_pill_info.pad_h - self.actions_pill_info.r_max
                local idx = math.floor(rel_x / self.actions_pill_info.pitch + 0.5) + 1
                idx = math.max(1, math.min(self.actions_pill_info.nb, idx))
                if idx ~= self.actions_page then
                    self.actions_page = idx
                    self:refreshMenu()
                end
            end
            return true
        end
    end

    return true
end

function ScrubberMenu:onShow()
    local dirty_rect = expandRect(self.popup_rect, scale(8))
    UIManager:setDirty(self, function() return "ui", dirty_rect end)
end

function ScrubberMenu:openActionsLauncher()
    local ui = self.ui
    local scrubber_ui = self.scrubber_ui
    UIManager:close(self)
    UIManager:nextTick(function()
        local ScrubberSettings = require("scrubber_settings")
        local inst = ScrubberSettings:new{
            ui = ui,
            scrubber_ui = scrubber_ui,
            current_view = "actions_launcher",
        }
        UIManager:show(inst)
    end)
end

function ScrubberMenu:onCloseWidget()
    local typo_changed = self._typo_changed
    self:applyPendingTypography()

    local to_free = {
        self.icon_sun, self.icon_warehouse, self.icon_wifi,
        self.icon_toggle_on, self.icon_toggle_off, self.icon_chevron_right,
        self.tw_check
    }
    for _, w in ipairs(to_free) do
        if w and w.free then pcall(function() w:free() end) end
    end

    local s = self.scrubber_ui
    local ui = self.ui

    if typo_changed then
        if s then
            -- MODO A: Se abrió desde el Page Scrubber (Grid / Split / Simple)
            -- 1. Vaciar caché de miniaturas del scrubber
            s._tile_cache = {}
            if s._clearGridTiles then s:_clearGridTiles(true) end

            -- 2. Alternar 1px la dimensión solicitada para que ReaderThumbnail regenere con la nueva fuente
            if s._grid_item_w then
                s._thumb_req_w = (s._thumb_req_w == s._grid_item_w) and (s._grid_item_w + 1) or s._grid_item_w
            end
            if s._thumb_req_split_w then
                s._thumb_req_split_w = s._thumb_req_split_w + 1
            end

            -- 3. Actualizar y regenerar la cuadrícula usando el flujo limpio de previewPage
            UIManager:nextTick(function()
                pcall(function()
                    if ui and ui.document and ui.document.getPageCount then
                        s._total_pages = ui.document:getPageCount()
                    end
                    if s._slider then
                        s._slider.value_max = s._total_pages
                    end
                    if s._updateChapterMarks then s:_updateChapterMarks() end

                    if s._previewPage then
                        s:_previewPage(s._cur_page or 1, false)
                    elseif s._updateGridPages then
                        s:_updateGridPages()
                    end

                    if Device:isKindle() or Device:hasEink() then
                        UIManager:setDirty(nil, "full")
                    else
                        UIManager:setDirty(s, "ui", s.dimen)
                    end
                end)
            end)
        else
            -- MODO B: Se abrió directamente desde el gesto de lectura en el libro
            UIManager:nextTick(function()
                pcall(function()
                    if ui and ui.handleEvent then
                        ui:handleEvent(Event:new("RedrawCurrentPage"))
                        ui:handleEvent(Event:new("PageUpdate"))
                    end
                    if Device:isKindle() then
                        UIManager:setDirty(nil, "full")
                    else
                        UIManager:setDirty(ui, "ui")
                    end
                end)
            end)
        end
    else
        local dirty_geom = expandRect(self.popup_rect, scale(8))
        if s then
            UIManager:setDirty(s, function() return "ui", dirty_geom end)
        end
        if ui then
            UIManager:setDirty(ui, function() return "ui", dirty_geom end)
        else
            UIManager:setDirty(nil, function() return "ui", dirty_geom end)
        end
    end
end

return ScrubberMenu

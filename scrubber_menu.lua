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
-- IconManager se carga una sola vez (prioriza los reemplazos del usuario en settings/page_scrubber/icons/)
local ok_icon_mgr, IconManager = pcall(require, "icon_manager")
if not ok_icon_mgr then IconManager = nil end

local function getSvgPath(filename)
    if not filename or filename == "" then return nil end
    if IconManager then
        local resolved = IconManager.resolvePath(filename)
        if resolved then return resolved end
    end
    -- Fallback si IconManager no cargó
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
            file_do_cache = false,   -- si no, un reemplazo con el mismo path podría seguir mostrando el ícono viejo
        }
    end)
    if ok and widget then return widget end
    return nil
end


-- ==========================================
-- FILA DE ESTADO (hora / estudio / wifi / batería)
-- ==========================================
local function getTimeStr()
    local ok, DateTime = pcall(require, "datetime")
    if ok and DateTime and DateTime.secondsToHour then
        local twelve = G_reader_settings and G_reader_settings:isTrue("twelve_hour_clock")
        local ok2, s = pcall(DateTime.secondsToHour, os.time(), twelve)
        if ok2 and type(s) == "string" and s ~= "" then return s end
    end
    return os.date("%H:%M")
end

-- Devuelve porcentaje (0-100) y si está cargando; nil si el dispositivo no informa batería
local function getBattery()
    local ok, pd = pcall(function() return Device:getPowerDevice() end)
    if not ok or not pd then return nil end
    local ok2, cap = pcall(function() return pd:getCapacity() end)
    if not ok2 or type(cap) ~= "number" then return nil end
    local charging = false
    pcall(function() charging = pd:isCharging() and true or false end)
    return math.max(0, math.min(100, math.floor(cap))), charging
end

local function getNetworkMgr()
    local ok, nm = pcall(require, "ui/network/manager")
    if ok and nm then return nm end
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

-- Cara de la fuente de símbolos de KOReader (nerdfonts). El ícono de la lámpara (U+EDB3) vive en esa fuente:
-- con "cfont" el glifo se tomaba por fallback y quedaba posicionado según las métricas de la fuente del sistema,
-- por eso subía o bajaba al cambiar la tipografía de la interfaz. Con su propia fuente la posición es siempre la misma.
local function getSymbolsFace(size)
    local ok, face = pcall(Font.getFace, Font, "symbols", size)
    if ok and face then return face end
    return Font:getFace("cfont", size)
end

-- Fila de estado (unidades de escala)
local STATUS_ROW_H = 28      -- alto de la fila
local STATUS_ROW_TOP = 12    -- distancia desde la línea de las pestañas hasta la fila

-- Ajuste fino vertical del ícono de la lámpara (en unidades de escala; positivo = más abajo)
local LAMP_Y_NUDGE = 0

-- Gris clarito de la pastilla que aparece un instante al presionar una pestaña
local PRESSED_TAB_BG = Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_GRAY_D or Blitbuffer.COLOR_LIGHT_GRAY

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

    local icon_sz = scale(32)
    self.icon_sun = loadSvg("sun.svg", scale(32), scale(32))
    self.icon_warehouse = loadSvg("warehouse.svg", icon_sz, icon_sz)
    self.icon_wifi = loadSvg("zero.svg", icon_sz, icon_sz)
    self.icon_chevron_right = loadSvg("chevron-right.svg", scale(16), scale(16))
    self.tw_check = TextWidget:new{
        text = "✓",
        face = Font:getFace("cfont", scale(18)),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self:updateLayout()
    if self:_statusRowEnabled() then self:_refreshStudyState() end

    if Device:isTouchDevice() then
        self.ges_events = {
            Tap   = { GestureRange:new{ ges = "tap",   range = self.dimen } },
            Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
    end
end

-- Fila de estado activada (Settings > Quick Menu > Status row). Por defecto DESACTIVADA.
function ScrubberMenu:_statusRowEnabled()
    if not G_reader_settings then return false end
    return G_reader_settings:readSetting("page_scrubber_quick_menu_status_row") == true
end

-- Estado del modo estudio para la fila de estado: nil si no está activo en este libro (o no hay nada para
-- estudiar); si no, { n = por estudiar, total = tarjetas }.
-- Con el scrubber abierto se usan sus listas; si el menú se abrió directo desde el Dispatcher (sin scrubber),
-- se leen las anotaciones del libro con el mismo criterio.
function ScrubberMenu:_refreshStudyState()
    self._study = nil
    local s = self.scrubber_ui
    local ui = self.ui or (s and s.ui)
    if not ui then return end
    local ok_srs, SRS = pcall(require, "srs")
    if not ok_srs or not SRS then return end
    local ok_act, active = pcall(SRS.isStudyActive, ui)
    if not ok_act or not active then return end

    local items
    if s and s._getReviewItems then
        -- Las anotaciones se cargan perezosamente: asegurarlas antes de contar
        if not s._cached_hl then pcall(function() s:_extractAnnotations() end) end
        local ok_it, it = pcall(function() return s:_getReviewItems() end)
        if ok_it then items = it end
    else
        items = {}
        local raw = (ui.annotation and ui.annotation.annotations) or {}
        -- Mismo criterio que PageScrubber:_extractAnnotations (scrubber_ui.lua): solo highlights reales y notas.
        -- Sin esto se contaban también los marcadores de página (tienen `text` automático), que el Review Card
        -- nunca muestra: esas tarjetas no se podían calificar y el número por estudiar no bajaba nunca.
        for _i, a in ipairs(raw) do
            if type(a) == "table" then
                local is_real_hl = (a.drawer ~= nil) or (a.pos0 ~= nil and a.pos1 ~= nil) or (a.highlight == true)
                local has_note   = (a.note ~= nil and a.note ~= "")
                if is_real_hl or has_note then
                    local has_text = (a.text ~= nil and a.text ~= "")
                    if has_text or a.drawer or has_note then
                        items[#items + 1] = a
                    end
                end
            end
        end
    end
    if type(items) ~= "table" or #items == 0 then return end
    local ok_n, n = pcall(SRS.getDueCount, ui, items)
    self._study = { n = ok_n and n or 0, total = #items }
end

-- Ícono SVG cacheado (false = el archivo no existe, no se vuelve a buscar)
function ScrubberMenu:_statusIcon(name, sz)
    self._st_icons = self._st_icons or {}
    local key = name .. ":" .. tostring(sz)
    local w = self._st_icons[key]
    if w == nil then
        w = loadSvg(name, sz, sz) or false
        self._st_icons[key] = w
    end
    return w or nil
end

-- Wi-Fi conectado o no (cacheado 2 s: se consulta en cada repintado)
function ScrubberMenu:_isWifiConnected()
    local now = os.time()
    local c = self._wifi_cache
    if c and now - c.t < 2 then return c.v end
    local v = false
    local NM = getNetworkMgr()
    if NM then
        pcall(function() v = NM:isConnected() and true or false end)
    end
    self._wifi_cache = { t = now, v = v }
    return v
end

-- Toca el wifi: conecta / desconecta. El ícono se actualiza al terminar y con algunos re-chequeos
-- (conectar tarda unos segundos).
function ScrubberMenu:toggleWifi()
    local NM = getNetworkMgr()
    if not NM then return end
    local on = false
    pcall(function() on = NM:isWifiOn() and true or false end)

    local function resync()
        self._wifi_cache = nil
        if not self._closed then self:refreshMenu() end
    end

    if on then
        local fn = NM.toggleWifiOff or NM.disableWifi
        if fn then pcall(fn, NM, resync) end
    else
        local fn = NM.toggleWifiOn or NM.enableWifi
        if fn then pcall(fn, NM, resync) end
    end
    self._wifi_cache = nil
    for _i, d in ipairs({ 1.5, 4, 8 }) do UIManager:scheduleIn(d, resync) end
end

-- Toca el botón de estudio: cierra este menú y abre las tarjetas que correspondan
-- (las pendientes, o el modo repaso si ya no queda ninguna). Sin scrubber (menú abierto desde el Dispatcher)
-- usa la misma acción "Study" que ya abre el split + Review Card.
function ScrubberMenu:openStudy()
    local s = self.scrubber_ui
    local ui = self.ui
    UIManager:close(self)
    UIManager:nextTick(function()
        if s and s._openReviewCard then
            pcall(function() s:_openReviewCard() end)
        elseif ui and ui.onPageScrubberStudy then
            pcall(function() ui:onPageScrubberStudy() end)
        end
    end)
end

-- Íconos dibujados en código: el wifi y la batería comparten ancho, alto y grosor, así se ven coherentes
-- (y no dependen de que existan los svg). Ambos ocupan una caja de w x h.
local function paintWifiIcon(bb, x, y, w, h, connected)
    local col = connected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
    local ox = x + w / 2
    local t = math.max(2, h * 0.17)                 -- grosor de cada arco
    local radii = { h * 0.40, h * 0.70, h * 1.00 }  -- radio exterior de cada arco
    local tan_w = math.tan(math.rad(48))            -- abertura del abanico (±48° desde la vertical)
    for py = 0, h - 1 do
        for px = 0, w - 1 do
            local dx = (x + px + 0.5) - ox
            local dy = (y + h) - (y + py + 0.5)
            if dy > 0 and math.abs(dx) <= dy * tan_w then
                local d = math.sqrt(dx * dx + dy * dy)
                for _i, ro in ipairs(radii) do
                    if d <= ro and d >= ro - t then
                        bb:paintRect(x + px, y + py, 1, 1, col)
                        break
                    end
                end
            end
        end
    end
    -- Punto de abajo
    local dr = math.max(1.5, h * 0.12)
    for py = -math.ceil(dr), math.ceil(dr) do
        for px = -math.ceil(dr), math.ceil(dr) do
            if px * px + py * py <= dr * dr then
                bb:paintRect(math.floor(ox + px), math.floor(y + h - dr + py), 1, 1, col)
            end
        end
    end
    -- Sin conexión: barra diagonal negra encima
    if not connected then
        local th = math.max(2, math.floor(h * 0.16))
        local steps = w
        for i = 0, steps do
            local px = x + math.floor(i * (w - 1) / steps)
            local py = y + h - 1 - math.floor(i * (h - 1) / steps)
            bb:paintRect(px - math.floor(th / 2), py - math.floor(th / 2), th, th, Blitbuffer.COLOR_BLACK)
        end
    end
end

local function paintBatteryIcon(bb, x, y, w, h, pct)
    local BLACK = Blitbuffer.COLOR_BLACK
    local t = math.max(2, math.floor(h * 0.15))      -- grosor del contorno (igual al de los arcos del wifi)
    local nub = math.max(2, math.floor(h * 0.14))
    local bw = w - nub
    local bh = math.max(t * 2 + 2, math.floor(h * 0.72))
    local by = y + math.floor((h - bh) / 2)
    bb:paintRect(x, by, bw, bh, BLACK)
    bb:paintRect(x + t, by + t, bw - t * 2, bh - t * 2, Blitbuffer.COLOR_WHITE)
    bb:paintRect(x + bw, by + math.floor(bh * 0.28), nub, math.max(2, math.floor(bh * 0.44)), BLACK)
    local gap = math.max(1, math.floor(t / 2))       -- aire entre contorno y relleno
    local fx, fy = x + t + gap, by + t + gap
    local fw_max, fh = bw - (t + gap) * 2, bh - (t + gap) * 2
    local fw = math.floor(fw_max * pct / 100 + 0.5)
    if pct > 0 then fw = math.max(1, fw) end
    if fw > 0 and fh > 0 then bb:paintRect(fx, fy, fw, fh, BLACK) end
end

-- Fila de estado en el espacio entre los dos swatches (día / noche) y la fila de sol / acciones / ajustes (el tamaño del menú no cambia).
-- Un solo grupo centrado: hora · estudio (solo si está activo en este libro) · wifi · batería (solo el ícono, el relleno ya refleja
-- el porcentaje), separados por puntitos y limitados al ancho de los swatches de arriba.
function ScrubberMenu:_paintStatusRow(bb, r, pad, top, row_h, center_y)
    self._status_dimens = {}
    local BLACK = Blitbuffer.COLOR_BLACK
    local ic_h = scale(14)                 -- alto común de TODOS los íconos de la fila
    local ic_w = math.floor(ic_h * 1.5)    -- caja del wifi y de la batería (mismo ancho y alto)
    local gap = scale(4)
    local face = Font:getFace("cfont", scaleText(10))
    local cy = center_y or (top + math.floor(row_h / 2))
    local frees = {}

    local function textPart(text)
        local tw = TextWidget:new{ text = text, face = face, fgcolor = BLACK }
        frees[#frees + 1] = tw
        local sz = tw:getSize()
        return { w = sz.w, draw = function(x) tw:paintTo(bb, x, cy - math.floor(sz.h / 2)) end }
    end
    local function svgPart(name)
        local ic = self:_statusIcon(name, ic_h)
        if not ic then return nil end
        local sz = ic:getSize()
        return { w = sz.w, draw = function(x) ic:paintTo(bb, x, cy - math.floor(sz.h / 2)) end }
    end

    -- Izquierda: hora · estudio. Derecha: wifi · batería (solo el ícono).
    local left, right = {}, {}

    -- Hora
    left[#left + 1] = { key = "time", parts = { textPart(getTimeStr()) } }

    -- Estudio: alert-circle.svg (el mismo del botón Study del split) con la cantidad por estudiar;
    -- award.svg si ya está todo completo
    local st = self._study
    if st then
        local done = (st.n or 0) <= 0
        local parts = {}
        local ic = svgPart(done and "award.svg" or "alert-circle.svg")
        if ic then parts[#parts + 1] = ic end
        if not done then
            if ic then parts[#parts + 1] = { w = gap } end
            parts[#parts + 1] = textPart(tostring(st.n))
        end
        left[#left + 1] = { key = "study", parts = parts }
    end

    -- Wifi (tocar = conectar / desconectar)
    do
        local connected = self:_isWifiConnected()
        right[#right + 1] = { key = "wifi", parts = { {
            w = ic_w,
            draw = function(x) paintWifiIcon(bb, x, cy - math.floor(ic_h / 2), ic_w, ic_h, connected) end,
        } } }
    end

    -- Batería: solo el ícono (si el dispositivo la informa)
    do
        local pct = getBattery()
        if pct then
            right[#right + 1] = { key = "battery", parts = {
                { w = ic_w, draw = function(x) paintBatteryIcon(bb, x, cy - math.floor(ic_h / 2), ic_w, ic_h, pct) end },
            } }
        end
    end

    -- Un solo grupo centrado horizontalmente en la fila, con puntitos como separadores.
    -- Orden de siempre: hora · estudio · wifi · batería (estudio y batería solo si existen).
    local by_key = {}
    for _i, it in ipairs(left) do by_key[it.key] = it end
    for _i, it in ipairs(right) do by_key[it.key] = it end
    local items = {}
    for _i, k in ipairs({ "time", "study", "wifi", "battery" }) do
        if by_key[k] then items[#items + 1] = by_key[k] end
    end
    local n = #items
    if n == 0 then return end

    -- Límites de la fila = bordes exteriores de los botones día / noche (el grupo nunca se sale de ahí)
    local row_x = r.x + pad
    local row_w = r.w - pad * 2
    local sd, sn = self.swatch_day_dimen, self.swatch_night_dimen
    if sd and sn then
        row_x = sd.x
        row_w = (sn.x + sn.w) - sd.x
    end

    local total = 0
    for _i, it in ipairs(items) do
        it.w = 0
        for _j, p in ipairs(it.parts) do it.w = it.w + p.w end
        total = total + it.w
    end

    local dot_d = math.max(2, scale(3))      -- diámetro del puntito separador
    local gap_side = scale(16)               -- espacio a cada lado del puntito
    if n > 1 then
        -- Si no entra, se achica el espacio (con un mínimo) para no salirse de los bordes
        local max_gap = math.floor((row_w - total - (n - 1) * dot_d) / ((n - 1) * 2))
        gap_side = math.max(scale(6), math.min(gap_side, max_gap))
    end
    local group_w = total + (n - 1) * (dot_d + 2 * gap_side)
    local x = row_x + math.floor((row_w - group_w) / 2)

    local dot_cx = {}
    for i, it in ipairs(items) do
        it.x = x
        local ix = x
        for _j, p in ipairs(it.parts) do
            if p.draw then p.draw(ix) end
            ix = ix + p.w
        end
        x = x + it.w
        if i < n then
            local dx = x + gap_side
            paintRoundRect(bb, dx, cy - math.floor(dot_d / 2), dot_d, dot_d, math.floor(dot_d / 2), BLACK)
            dot_cx[i] = dx + math.floor(dot_d / 2)
            x = dx + dot_d + gap_side
        end
    end

    -- Zonas de toque: cada ítem llega hasta el puntito vecino (y hasta los bordes de la fila en los extremos)
    for i, it in ipairs(items) do
        local zl = (i == 1) and row_x or dot_cx[i - 1]
        local zr = (i == n) and (row_x + row_w) or dot_cx[i]
        self._status_dimens[#self._status_dimens + 1] = {
            key = it.key,
            dimen = Geom:new{ x = zl, y = top, w = zr - zl, h = row_h },
        }
    end
    for _i, w in ipairs(frees) do pcall(function() w:free() end) end
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
    self.tab_h = scale(36)

    -- Tamaño unificado y fijo: la ventana NUNCA cambia de tamaño
    self.card_w = scale(256)
    self.card_h = self.tab_h + scale(164) + scale(4) -- el contenido (164) entra 4 filas de lista + el pie de paginación

    -- Subvistas paginadas (fuentes y acciones)
    self.fonts_per_page = 4
    self.actions_per_page = 4
    self.font_row_h = scale(34)
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

-- Estado REAL del frontlight: igual que el slider de brightness (luz prendida = intensidad > 0).
-- nil si no se puede saber.
function ScrubberMenu:getRealFrontlightState()
    local ok, res = pcall(function()
        if Device.hasFrontlight and Device:hasFrontlight() then
            local powerd = Device:getPowerDevice()
            if powerd and type(powerd.frontlightIntensity) == "function" then
                return (tonumber(powerd:frontlightIntensity()) or 0) > 0
            elseif powerd and type(powerd.isFrontlightOn) == "function" then
                return powerd:isFrontlightOn()
            end
        end
        return nil
    end)
    if ok and res ~= nil then return res == true end
    return nil
end

function ScrubberMenu:readInitialFrontlightState()
    -- Primero lo que realmente está pasando con la luz; el valor guardado solo es un respaldo
    local real = self:getRealFrontlightState()
    if real ~= nil then return real end
    if G_reader_settings then
        local fl = G_reader_settings:readSetting("frontlight")
        if fl ~= nil then return fl ~= 0 end
    end
    return false
end

function ScrubberMenu:isFrontlightOn()
    -- Se consulta el estado real en cada repintado (así el toggle nunca queda desfasado)
    local real = self:getRealFrontlightState()
    if real ~= nil then
        self._fl_on = real
    elseif self._fl_on == nil then
        self._fl_on = self:readInitialFrontlightState()
    end
    return self._fl_on == true
end

-- Último nivel de luz antes de apagarla (para volver a él al prender)
function ScrubberMenu:_rememberFrontlightLevel(level)
    if G_reader_settings and tonumber(level) and level > 0 then
        G_reader_settings:saveSetting("page_scrubber_fl_last", level)
    end
end

-- Nivel al que sube la luz al prenderla: el último que tenía; si no hay, un pasito a la derecha
-- (una décima del recorrido, como el "+" del slider)
function ScrubberMenu:_frontlightOnLevel(powerd)
    local lo = math.max(tonumber(powerd.fl_min) or 0, 1)
    local hi = tonumber(powerd.fl_max) or 100
    local last = G_reader_settings and tonumber(G_reader_settings:readSetting("page_scrubber_fl_last"))
    if not last or last < lo then
        last = math.max(lo, math.floor((hi - lo) / 10 + 0.5))
    end
    return math.min(hi, last)
end

-- Guarda el nivel de luz en los ajustes de KOReader enseguida (como brightness.lua)
local function saveLight()
    local powerd = Device.getPowerDevice and Device:getPowerDevice()
    if not powerd then return end
    local ok = powerd.saveSettings and pcall(powerd.saveSettings, powerd)
    if not ok and G_reader_settings then
        if powerd.fl_intensity then G_reader_settings:saveSetting("frontlight_intensity", powerd.fl_intensity) end
    end
    if G_reader_settings and G_reader_settings.flush then
        pcall(G_reader_settings.flush, G_reader_settings)
    end
end

-- Enciende o apaga el frontlight igual que el slider de brightness:
--   apagado = intensidad 0 (slider al mínimo); prendido = intensidad > 0 (slider corrido un poquito a la derecha).
function ScrubberMenu:setFrontlight(on)
    on = on and true or false
    local handled = false

    pcall(function()
        local powerd = Device.getPowerDevice and Device:getPowerDevice()
        if powerd and Device.hasFrontlight and Device:hasFrontlight() and type(powerd.setIntensity) == "function" then
            if on then
                powerd:setIntensity(self:_frontlightOnLevel(powerd))
            else
                local cur = tonumber(powerd:frontlightIntensity()) or 0
                if cur > 0 then self:_rememberFrontlightLevel(cur) end
                powerd:setIntensity(0)
            end
            if type(powerd.updateResumeFrontlightState) == "function" then
                powerd:updateResumeFrontlightState()
            end
            handled = true
        else
            -- Sin acceso directo: solo se alterna si el estado real es distinto del pedido
            local real = self:getRealFrontlightState()
            if real == nil or real ~= on then
                local ui = self.ui
                if ui and ui.frontlight and type(ui.frontlight.toggle) == "function" then
                    ui.frontlight:toggle()
                elseif ui and ui.handleEvent then
                    ui:handleEvent(Event:new("ToggleFrontlight"))
                end
            end
        end
    end)

    local real = self:getRealFrontlightState()
    self._fl_on = (real ~= nil) and real or on

    if handled then saveLight() end

    UIManager:show(Notification:new{
        text = self._fl_on and _("Frontlight enabled") or _("Frontlight disabled"),
    })

    self:refreshMenu()
end

function ScrubberMenu:toggleFrontlight()
    self:setFrontlight(not self:isFrontlightOn())
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
    local pad = scale(16)
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

    -- Pastilla gris solo mientras se presiona una pestaña
    do
        local pressed = (self._pressed_btn == "tab_quick" and self.tab_quick_dimen)
            or (self._pressed_btn == "tab_typo" and self.tab_typo_dimen)
        if pressed then
            local pin = scale(6)
            paintRoundRect(bb, pressed.x + pin, tab_y + scale(3), pressed.w - pin * 2, tab_h - scale(11), scale(10), PRESSED_TAB_BG)
        end
    end

    -- Pestaña 1: Lámpara Unicode \u{EDB3} (activa tanto en vista principal como en actions_list)
    local is_quick = (self.active_tab == "quick" or self.active_tab == "actions_list")
    local tw_gear = TextWidget:new{
        text = "\u{EDB3}",
        face = getSymbolsFace(scale(15)),
        bold = is_quick,
        fgcolor = is_quick and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
    }
    local gsz = tw_gear:getSize()
    tw_gear:paintTo(bb, self.tab_quick_dimen.x + math.floor((self.tab_quick_dimen.w - gsz.w) / 2), tab_y + math.floor((tab_h - gsz.h) / 2) + scale(LAMP_Y_NUDGE))
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

    -- Línea divisoria inferior de pestañas: gris y más gruesa (crece hacia arriba, el contenido no se mueve).
    -- El indicador negro de la pestaña activa se pinta DESPUÉS, por encima de esta línea.
    local div_h = scale(2)
    bb:paintRect(r.x + border, tab_y + tab_h - div_h, inner_w, div_h, Blitbuffer.COLOR_LIGHT_GRAY)

    local ind_h = scale(3)   -- más alto que la línea: la cubre por completo en el tramo activo
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
        local show_status = self:_statusRowEnabled()

        -- Orden vertical: botones día / noche → fila de estado (opcional) → sol / acciones / ajustes.
        -- Con la fila de estado se compacta; sin ella se usa el layout del menú viejo (24 / 24)
        if not show_status then self._status_dimens = {} end
        local swatch_y = content_top + scale(show_status and 14 or 24)
        local swatch_h = scale(48)
        local gap = scale(14)
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

        local bottom_y
        local bottom_h = scale(48)
        if show_status then
            -- Fila de estado entre los botones día / noche y la fila de abajo (usa el ancho de los swatches ya dibujados).
            -- Centrada en el hueco VISIBLE: desde el borde de abajo de los swatches hasta el borde de arriba de los
            -- íconos de la fila inferior (que tienen su propio margen interno dentro de bottom_h).
            local status_h = scale(STATUS_ROW_H)
            local sw_end   = swatch_y + swatch_h
            bottom_y = sw_end + scale(40)
            local icons_top = bottom_y + math.floor((bottom_h - scale(32)) / 2)
            local center_y  = sw_end + math.floor((icons_top - sw_end) / 2)
            self:_paintStatusRow(bb, r, pad, center_y - math.floor(status_h / 2), status_h, center_y)
        else
            bottom_y = swatch_y + swatch_h + scale(24)
        end

        -- Tres celdas que reparten todo el ancho: [luz (sol + toggle)] [acciones] [ajustes]
        local row_x = r.x + pad
        local row_w = r.w - pad * 2
        local cw1 = math.floor(row_w * 0.46)
        local cw = math.floor((row_w - cw1) / 2)
        local cell_y = bottom_y - scale(2)
        local cell_h = bottom_h + scale(4)

        -- Celda 1: sol + toggle (mismo toggle que los ajustes), centrados en su celda
        local sun_sz = scale(32)
        local is_fl = self:isFrontlightOn()
        local tw_toggle = TextWidget:new{
            text = is_fl and "\u{EC20}" or "\u{EC21}",
            face = Font:getFace("cfont", scaleText(16)),
            fgcolor = is_fl and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        }
        local tsz = tw_toggle:getSize()
        local group_w = sun_sz + scale(10) + tsz.w
        local sun_x = row_x + math.floor((cw1 - group_w) / 2)
        local sun_y = bottom_y + math.floor((bottom_h - sun_sz) / 2)
        if self.icon_sun then self.icon_sun:paintTo(bb, sun_x, sun_y) end
        tw_toggle:paintTo(bb, sun_x + sun_sz + scale(10), bottom_y + math.floor((bottom_h - tsz.h) / 2))
        tw_toggle:free()
        self.row_light_dimen = Geom:new{ x = row_x, y = cell_y, w = cw1, h = cell_h }

        -- Celda 2: acciones del scrubber (centrado)
        self.btn_actions_dimen = Geom:new{ x = row_x + cw1, y = cell_y, w = cw, h = cell_h }
        if self.icon_warehouse then
            local isz = self.icon_warehouse:getSize()
            local ix = row_x + cw1 + math.floor((cw - isz.w) / 2)
            local iy = bottom_y + math.floor((bottom_h - isz.h) / 2)
            self.icon_warehouse:paintTo(bb, ix, iy)
        end

        -- Celda 3: ajustes (centrado); al presionar se marca con el recuadro negro
        local set_cx = row_x + cw1 + cw
        self.btn_wifi_dimen = Geom:new{ x = set_cx, y = cell_y, w = row_x + row_w - set_cx, h = cell_h }
        local box_sz = scale(40)
        local box_x = set_cx + math.floor((cw - box_sz) / 2)
        local box_y = bottom_y + math.floor((bottom_h - box_sz) / 2)
        if self.icon_wifi then
            local isz = self.icon_wifi:getSize()
            local ix = set_cx + math.floor((cw - isz.w) / 2)
            local iy = bottom_y + math.floor((bottom_h - isz.h) / 2)
            if self._pressed_btn == "wifi" then
                paintRoundRect(bb, box_x, box_y, box_sz, box_sz, scale(8), Blitbuffer.COLOR_BLACK)
                bb:paintRect(ix, iy, isz.w, isz.h, Blitbuffer.COLOR_WHITE)
                self.icon_wifi:paintTo(bb, ix, iy)
                bb:invertRect(ix, iy, isz.w, isz.h)
            else
                self.icon_wifi:paintTo(bb, ix, iy)
            end
        end

        -- Última fila: estado (wifi · hora · estudio · batería), debajo de sol / acciones / ajustes


    -- ====================================================
    -- CONTENIDO PESTAÑA 2: TIPOGRAFÍA (PULIDA)
    -- ====================================================
    elseif self.active_tab == "typo" then
        local row_h = scale(52)
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
        local per_page = 4
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

                -- "Aa" en la propia fuente de la fila: hace de ícono. Columna de ancho fijo para alinear los nombres.
                local tw_aa = TextWidget:new{
                    text = "Aa",
                    face = item_face,
                    bold = is_sel,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
                local aa_sz = tw_aa:getSize()
                local aa_col_w = scale(36)
                local aa_x = r.x + pad + math.floor((aa_col_w - math.min(aa_sz.w, aa_col_w)) / 2)
                tw_aa:paintTo(bb, aa_x, curr_y + math.floor((rh - aa_sz.h) / 2))
                tw_aa:free()

                local name_x = r.x + pad + aa_col_w + scale(10)
                local tw_f = TextWidget:new{
                    text = fname,
                    face = item_face,
                    bold = is_sel,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    max_width = inner_w - scale(40) - aa_col_w - scale(10),
                    truncate_with_ellipsis = true,
                }
                local fsz = tw_f:getSize()
                tw_f:paintTo(bb, name_x, curr_y + math.floor((rh - fsz.h) / 2))
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
        local per_page = 4
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
                local icon_sz = scale(18)
                local icon_widget = loadSvg(icon_name, icon_sz, Blitbuffer.COLOR_BLACK)
                local text_x = r.x + pad

                if icon_widget then
                    local iy = curr_y + math.floor((rh - icon_sz) / 2)
                    pcall(function() icon_widget:paintTo(bb, text_x, iy) end)
                    text_x = text_x + icon_sz + scale(12)
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

-- Muestra un instante la pastilla gris de la pestaña presionada y después ejecuta la acción
function ScrubberMenu:_flashThen(key, fn)
    self._pressed_btn = key
    self._flash_busy = true
    UIManager:setDirty(self, "ui", expandRect(self.popup_rect, scale(8)))
    UIManager:scheduleIn(0.08, function()
        self._pressed_btn = nil
        self._flash_busy = false
        if self._closed then return end
        fn()
    end)
end

function ScrubberMenu:onTap(arg1, arg2)
    local ges = arg2 or arg1
    if not ges or not ges.pos then return false end

    -- Mientras la pastilla gris está en pantalla, se absorben los toques
    if self._flash_busy then return true end

    if not ges.pos:intersectWith(self.popup_rect) then
        UIManager:close(self)
        return true
    end

    -- Cambio de pestaña
    if self.tab_quick_dimen and ges.pos:intersectWith(self.tab_quick_dimen) then
        if self.active_tab ~= "quick" then
            self:_flashThen("tab_quick", function()
                self.active_tab = "quick"
                self:refreshMenu()
            end)
        end
        return true
    end

    if self.tab_typo_dimen and ges.pos:intersectWith(self.tab_typo_dimen) then
        if self.active_tab ~= "typo" then
            self:_flashThen("tab_typo", function()
                self.active_tab = "typo"
                self:refreshMenu()
            end)
        end
        return true
    end

    -- Acciones Pestaña 1: Rápido
    if self.active_tab == "quick" then
        -- Fila de estado: estudio abre las tarjetas, wifi conecta / desconecta
        for _i, sd in ipairs(self._status_dimens or {}) do
            if ges.pos:intersectWith(sd.dimen) then
                if sd.key == "study" then
                    self:openStudy()
                elseif sd.key == "wifi" then
                    self:toggleWifi()
                    self:refreshMenu()
                end
                return true
            end
        end

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
    self._closed = true
    local typo_changed = self._typo_changed
    self:applyPendingTypography()

    local to_free = {
        self.icon_sun, self.icon_warehouse, self.icon_wifi,
        self.icon_chevron_right,
        self.tw_check
    }
    for _, w in ipairs(to_free) do
        if w and w.free then pcall(function() w:free() end) end
    end
    for _k, w in pairs(self._st_icons or {}) do
        if w and w.free then pcall(function() w:free() end) end
    end
    self._st_icons = nil

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

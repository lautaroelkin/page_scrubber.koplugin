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
local logger          = require("logger")
local ScrubberState   = require("scrubber_state")
local Notification    = require("ui/widget/notification")
local _               = require("gettext")
local util            = require("util")
local ok_tbw, TextBoxWidget = pcall(require, "ui/widget/textboxwidget")
local ok_iw, IconWidget     = pcall(require, "ui/widget/iconwidget")

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

-- Pie de estado (unidades de escala): alto total, incluida la línea fina que lo separa del resto
local STATUS_FOOTER_H = 30

-- Guarda el nivel de la luz en los ajustes de KOReader (se define más abajo, junto a saveLight; los gestos del
-- slider la usan antes en el archivo)
local saveLightNow

-- Alto útil del contenido del menú (debajo de las pestañas), igual en todas las pestañas y subvistas:
-- 5 filas de lista de 36 + el pie de paginación de 32
local QUICK_CONTENT_H = 212

-- Ajuste fino vertical del ícono de la lámpara (en unidades de escala; positivo = más abajo)
local LAMP_Y_NUDGE = 0

-- Gris clarito de la pastilla que aparece un instante al presionar una pestaña
local PRESSED_TAB_BG = Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_GRAY_D or Blitbuffer.COLOR_LIGHT_GRAY

-- Líneas finas del menú rápido (pie de estado y divisor de la luz) y fondo de un ítem del pie mientras se lo presiona
local STATUS_DIVIDER    = Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_LIGHT_GRAY
local STATUS_PRESSED_BG = Blitbuffer.COLOR_GRAY_D or Blitbuffer.COLOR_LIGHT_GRAY

-- Switch del frontlight (más chico que el de KiKome, que es 52 x 28)
local SWITCH_W = 40
local SWITCH_H = 22

-- ==========================================
-- WIDGET PRINCIPAL CON PESTAÑAS (PULIDO)
-- ==========================================
local ScrubberMenu = InputContainer:extend({
    ui = nil,
    scrubber_ui = nil,
    alpha = 0.25,
    active_tab = "quick", -- "quick" | "typo" | "font_list" | "more_list" | "actions_list"
    font_page = 1,
    more_page = 1,
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
    self.more_page = 1
    self.actions_page = 1
    self._typo_changed = false
    self._fl_on = self:readInitialFrontlightState()

    local icon_sz = scale(32)
    self.icon_warehouse = loadSvg("warehouse.svg", icon_sz, icon_sz)
    self.icon_wifi = loadSvg("zero.svg", icon_sz, icon_sz)
    self.icon_search = loadSvg("search.svg", scale(18), scale(18))
    self.icon_rotate = loadSvg("rotate-screen.svg", icon_sz, icon_sz)
    -- Íconos de las píldoras de la pestaña Aa: columnas (una / dos) y modo de vista (página / continuo)
    self.icon_col_one = loadSvg("columns-one.svg", scale(20), scale(20))
    self.icon_col_two = loadSvg("columns-two.svg", scale(20), scale(20))
    self.icon_view_page = loadSvg("view-page.svg", scale(20), scale(20))
    self.icon_view_cont = loadSvg("view-continuous.svg", scale(20), scale(20))
    self.icon_chevron_right = loadSvg("chevron-right.svg", scale(16), scale(16))
    -- Íconos al inicio de las entradas de submenú de la pestaña Aa (View / Style options, Page / Reflow / Visual)
    self.icon_expand = loadSvg("expand.svg", scale(20), scale(20))
    self.icon_underline = loadSvg("underline.svg", scale(20), scale(20))
    self.icon_droplet2 = loadSvg("droplet2.svg", scale(20), scale(20))
    -- Botón "More" (⋮) de la pestaña Aa y estrella de "valor por defecto" (Aa y More)
    self.icon_more = loadSvg("more.svg", icon_sz, icon_sz)
    self.icon_pin = loadSvg("img-folder-fav-filled.svg", scale(12), scale(12))
    -- Selector propio de opciones: chevrón izquierdo y estrella vacía / rellena (predeterminado)
    self.icon_chev_left = loadSvg("chevron-left.svg", scale(16), scale(16))
    -- Flecha de "volver" (reemplaza al texto Aa de la pestaña dentro de los submenús) y ⋮ chico del selector
    self.icon_back = loadSvg("undo.svg", scale(20), scale(20))
    self.icon_more_sm = loadSvg("more.svg", scale(22), scale(22))
    self.icon_star = loadSvg("img-folder-fav.svg", scale(18), scale(18))
    self.icon_star_on = loadSvg("img-folder-fav-filled.svg", scale(18), scale(18))
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
            -- Slider de brillo: arrastrar la perilla (pan, o mantener y arrastrar) y toques rápidos en − / +
            -- (que pueden llegar como doble toque o como una pulsación un poco larga)
            Pan         = { GestureRange:new{ ges = "pan",          range = self.dimen } },
            PanRelease  = { GestureRange:new{ ges = "pan_release",  range = self.dimen } },
            Hold        = { GestureRange:new{ ges = "hold",         range = self.dimen } },
            HoldPan     = { GestureRange:new{ ges = "hold_pan",     range = self.dimen } },
            HoldRelease = { GestureRange:new{ ges = "hold_release", range = self.dimen } },
            Release     = { GestureRange:new{ ges = "release",      range = self.dimen } },
            DoubleTap   = { GestureRange:new{ ges = "double_tap",   range = self.dimen } },
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

-- Switch on / off pintado a mano (igual que el de KiKome): así queda exactamente centrado en su fila y no depende
-- de ningún glifo de la fuente. Encendido: píldora negra con la perilla blanca a la derecha.
-- Apagado: píldora blanca con borde negro y la perilla negra a la izquierda.
local function paintSwitch(bb, x, y, w, h, on)
    local border = math.max(2, scale(2))
    local gap = math.max(2, scale(2))
    local r = math.floor(h / 2)
    paintRoundRect(bb, x, y, w, h, r, Blitbuffer.COLOR_BLACK)
    if not on then
        paintRoundRect(bb, x + border, y + border, w - border * 2, h - border * 2, math.max(1, r - border), Blitbuffer.COLOR_WHITE)
    end
    local k = h - 2 * (border + gap)
    local kx = on and (x + w - border - gap - k) or (x + border + gap)
    paintRoundRect(bb, kx, y + border + gap, k, k, math.floor(k / 2), on and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK)
end

-- Píldora de superficie sutil (buscador del menú rápido, botones −/+, chips y botones del selector):
-- relleno gris muy suave sin borde; al presionarla o estar seleccionada usa negro sólido con texto blanco.
-- Devuelve el color del contenido y el del fondo para dibujar adentro.
local function paintPill(bb, x, y, w, h, pressed)
    local r = math.floor(h / 2)
    if pressed then
        paintRoundRect(bb, x, y, w, h, r, Blitbuffer.COLOR_BLACK)
        return Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
    end
    local bg = Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_LIGHT_GRAY
    paintRoundRect(bb, x, y, w, h, r, bg)
    return Blitbuffer.COLOR_BLACK, bg
end

-- Ícono SVG (negro sobre transparente) dentro de una píldora; si está invertida se ve blanco sobre negro
local function paintIconOn(bb, icon, x, y, inverted)
    if not icon then return end
    local isz = icon:getSize()
    if inverted then
        bb:paintRect(x, y, isz.w, isz.h, Blitbuffer.COLOR_WHITE)
        icon:paintTo(bb, x, y)
        bb:invertRect(x, y, isz.w, isz.h)
    else
        icon:paintTo(bb, x, y)
    end
end

-- Botón − / + chiquito (filas de la vista "More"): píldora con el signo dibujado en geometría
local function paintMiniStep(bb, bx, by, bw, bh, is_plus, pressed)
    local fg = paintPill(bb, bx, by, bw, bh, pressed)
    local arm = scale(9)
    local th = math.max(2, scale(2))
    local cx = bx + math.floor(bw / 2)
    local cy = by + math.floor(bh / 2)
    bb:paintRect(cx - math.floor(arm / 2), cy - math.floor(th / 2), arm, th, fg)
    if is_plus then
        bb:paintRect(cx - math.floor(th / 2), cy - math.floor(arm / 2), th, arm, fg)
    end
end

-- Control segmentado: píldora de contorno negro con dos opciones (ícono + etiqueta opcional).
-- La elegida va en una cápsula negra con contenido blanco; la otra, negro sobre blanco.
local function paintSegmented(bb, x, y, w, h, icons, labels, selected, count)
    if type(labels) == "number" then
        selected = labels
        labels = nil
    end
    local n = count or 2   -- cantidad de segmentos (2 por defecto; 3 en EPUB: 1 col / 2 col / continuo)
    local bw = math.max(2, scale(2))
    local r = math.floor(h / 2)
    paintRoundRect(bb, x, y, w, h, r, Blitbuffer.COLOR_BLACK)
    paintRoundRect(bb, x + bw, y + bw, w - bw * 2, h - bw * 2, math.max(1, r - bw), Blitbuffer.COLOR_WHITE)

    local seg_w = math.floor(w / n)
    local inset = bw + scale(2)
    local sx = x + (selected - 1) * seg_w
    local sw = (selected == n) and (x + w - sx) or seg_w
    local ch = h - inset * 2
    paintRoundRect(bb, sx + inset, y + inset, sw - inset * 2, ch, math.floor(ch / 2), Blitbuffer.COLOR_BLACK)

    local lbl_face = Font:getFace("cfont", scaleText(11))
    local gap = scale(5)

    for i = 1, n do
        local is_sel = (i == selected)
        local slot_x = x + (i - 1) * seg_w
        local slot_w = (i == n) and (w - (n - 1) * seg_w) or seg_w
        local icon = icons and icons[i]
        local isz = icon and icon:getSize() or { w = 0, h = 0 }

        local tw, lsz
        local lbl = labels and labels[i]
        if lbl and lbl ~= "" then
            local max_lbl_w = slot_w - isz.w - scale(14)
            if max_lbl_w >= scale(18) then
                tw = TextWidget:new{
                    text = lbl,
                    face = lbl_face,
                    bold = is_sel,
                    fgcolor = is_sel and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
                    max_width = max_lbl_w,
                    truncate_with_ellipsis = true,
                }
                lsz = tw:getSize()
            end
        end

        local total_w = isz.w + (tw and ((isz.w > 0 and gap or 0) + lsz.w) or 0)
        local cx = slot_x + math.floor((slot_w - total_w) / 2)

        if icon then
            paintIconOn(bb, icon, cx, y + math.floor((h - isz.h) / 2), is_sel)
            cx = cx + isz.w + gap
        end
        if tw then
            tw:paintTo(bb, cx, y + math.floor((h - lsz.h) / 2))
            tw:free()
        end
    end
end

-- Pie de estado: va abajo de todo el menú rápido (el tamaño del menú no cambia), separado por una línea fina.
-- Hora y estudio (solo si está activo en este libro) a la izquierda; wifi y batería (ícono + porcentaje, con rayo si carga)
-- a la derecha, alineados con los bordes de los botones de arriba. Sin fondo ni divisores: solo texto e íconos.
-- Cada ítem es una zona de toque y se marca un instante al presionarlo (wifi y estudio).
function ScrubberMenu:_paintStatusRow(bb, r, pad, top, row_h)
    self._status_dimens = {}
    local BLACK = Blitbuffer.COLOR_BLACK
    local ic_h = scale(14)                 -- alto común de TODOS los íconos del pie
    local ic_w = math.floor(ic_h * 1.5)    -- caja del wifi y de la batería (mismo ancho y alto)
    local gap = scale(4)
    local face = Font:getFace("cfont", scaleText(10))
    local line_h = math.max(1, scale(1))
    local cy = top + line_h + math.floor((row_h - line_h) / 2)
    local frees = {}

    local function textPart(text, bold)
        local tw = TextWidget:new{ text = text, face = face, fgcolor = BLACK, bold = bold or false }
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

    local left, right = {}, {}

    -- Hora
    left[#left + 1] = { key = "time", parts = { textPart(getTimeStr(), true) } }

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

    -- Batería: rayo (solo si carga) + ícono + porcentaje (si el dispositivo la informa).
    -- `droppable` = cuántas piezas del final se sacan si todo junto no entra en la fila.
    local battery
    do
        local pct, charging = getBattery()
        if pct then
            local parts = {}
            if charging then
                local bolt = svgPart("zap.svg")
                if bolt then
                    parts[#parts + 1] = bolt
                    parts[#parts + 1] = { w = math.floor(gap / 2) }
                end
            end
            parts[#parts + 1] = {
                w = ic_w,
                draw = function(x) paintBatteryIcon(bb, x, cy - math.floor(ic_h / 2), ic_w, ic_h, pct) end,
            }
            parts[#parts + 1] = { w = gap }
            parts[#parts + 1] = textPart(tostring(pct) .. "%")
            battery = { key = "battery", parts = parts, droppable = 2 }
            right[#right + 1] = battery
        end
    end

    local row_x = r.x + pad
    local row_w = r.w - pad * 2
    local item_gap = scale(18)

    local function itemWidth(it)
        local w = 0
        for _j, p in ipairs(it.parts) do w = w + p.w end
        return w
    end
    local function groupWidth(list)
        local w = 0
        for _i, it in ipairs(list) do
            it.w = itemWidth(it)
            w = w + it.w + (_i > 1 and item_gap or 0)
        end
        return w
    end
    local lw, rw = groupWidth(left), groupWidth(right)
    -- Si no entra todo, la batería queda solo con el ícono
    if battery and lw + rw + item_gap > row_w then
        for _k = 1, battery.droppable do battery.parts[#battery.parts] = nil end
        rw = groupWidth(right)
    end

    -- Línea fina que separa el pie del resto del menú
    bb:paintRect(row_x, top, row_w, line_h, STATUS_DIVIDER)

    local half = math.floor(item_gap / 2)
    local function drawGroup(list, x0)
        local x = x0
        for _i, it in ipairs(list) do
            local zx, zw = x - half, it.w + item_gap

            -- Ítem presionado: se marca un instante, como las pestañas
            if self._pressed_status == it.key then
                paintRoundRect(bb, zx, top + line_h + scale(3), zw, row_h - line_h - scale(6), scale(8), STATUS_PRESSED_BG)
            end

            local ix = x
            for _j, p in ipairs(it.parts) do
                if p.draw then p.draw(ix) end
                ix = ix + p.w
            end

            -- Zona de toque = el ítem con aire a los lados, de alto completo
            self._status_dimens[#self._status_dimens + 1] = {
                key = it.key,
                dimen = Geom:new{ x = zx, y = top, w = zw, h = row_h },
            }
            x = x + it.w + item_gap
        end
    end
    drawGroup(left, row_x)
    drawGroup(right, row_x + row_w - rw)

    for _i, w in ipairs(frees) do pcall(function() w:free() end) end
end

-- Una pulsación larga sobre la perilla empieza el arrastre; sobre − / + cuenta como un toque.
-- Fuera del slider no se hace nada (el evento sigue su camino, como antes).
function ScrubberMenu:onHold(arg1, arg2)
    local ges = arg2 or arg1
    if ges and ges.pos and self.active_tab == "opt_picker" then
        return self:_pickerHold(ges.pos)
    end
    -- Pestaña Aa / vista More: mantener apretada una opción -> poner / sacar su valor por defecto
    if ges and ges.pos and (self.active_tab == "typo" or self.active_tab == "more_list") then
        return self:_onTypoHold(ges.pos)
    end
    if not (ges and ges.pos) or self.active_tab ~= "quick" or not self._light_hit then return false end
    if self:_lightGrab(ges.pos) then
        self:_beginLightDrag(ges.pos.x)
        return true
    end
    local h = self._light_hit
    if h.minus and (ges.pos:intersectWith(h.minus) or ges.pos:intersectWith(h.plus)) then
        return self:_onLightTap(ges.pos)
    end
    return false
end

function ScrubberMenu:onPan(arg1, arg2)
    local ges = arg2 or arg1
    if not (ges and ges.pos) then return false end
    if self.active_tab == "opt_picker" then return self:_pickerPan(ges) end
    if not self._light_drag then
        if self.active_tab ~= "quick" or not self._light_hit then return false end
        -- Los desplazamientos verticales no son para un slider horizontal
        if ges.direction == "north" or ges.direction == "south" then return false end
        if not self:_lightGrab(ges.pos) then return false end
        self:_beginLightDrag(ges.pos.x)
        return true
    end
    self:_lightDragTo(ges.pos.x)
    return true
end

function ScrubberMenu:onHoldPan(arg1, arg2)
    local ges = arg2 or arg1
    if self._pick_drag and ges and ges.pos then
        self:_pickerDragTo(ges.pos.x)
        return true
    end
    if not (self._light_drag and ges and ges.pos) then return false end
    self:_lightDragTo(ges.pos.x)
    return true
end

function ScrubberMenu:_endLightDrag()
    if not self._light_drag then return false end
    self._light_drag = false
    saveLightNow()
    -- Al soltar: repintado "partial" del bloque (vuelve la perilla y se limpia el ghosting del "fast")
    local function repaint()
        UIManager:setDirty(self, "partial", self._light_block_dimen or expandRect(self.popup_rect, scale(8)))
    end
    repaint()
    -- Red de seguridad: un segundo repintado apenas después, por si el primero se mezcló con el "fast"
    -- pendiente; así la perilla siempre vuelve a aparecer.
    UIManager:scheduleIn(0.12, function()
        if self._closed or self._light_drag then return end
        repaint()
    end)
    return true
end
function ScrubberMenu:onPanRelease() return self:_endPickDrag() or self:_endLightDrag() end
function ScrubberMenu:onHoldRelease() return self:_endPickDrag() or self:_endLightDrag() end
-- Levantar el dedo sin que llegue pan_release / hold_release (p. ej. termina como swipe o suelta sin mover)
function ScrubberMenu:onRelease() return self:_endPickDrag() or self:_endLightDrag() end

-- Toques rápidos en − / + o sobre el slider pueden llegar como doble toque: cuentan igual que un toque
function ScrubberMenu:onDoubleTap(arg1, arg2)
    local ges = arg2 or arg1
    if not (ges and ges.pos) then return false end
    if self.active_tab == "typo" or self.active_tab == "more_list" or self.active_tab == "opt_picker" then
        return self:onTap(arg1, arg2)
    end
    if self.active_tab ~= "quick" or not self._light_hit then return false end
    local h = self._light_hit
    if h.track and (ges.pos:intersectWith(h.track) or ges.pos:intersectWith(h.minus) or ges.pos:intersectWith(h.plus)) then
        return self:_onLightTap(ges.pos)
    end
    return false
end

function ScrubberMenu:onSwipe(arg1, arg2)
    local ges = arg2 or arg1
    if not ges then return true end
    -- Si el arrastre del brillo terminó como swipe, se cierra y la perilla vuelve
    if self._light_drag then self:_endLightDrag(); return true end
    if self._pick_drag then self:_endPickDrag(); return true end

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
    elseif self.active_tab == "more_list" then
        local dir = ges.direction
        if dir == "left" or dir == "west" or dir == "up" or dir == "north" then
            if self.more_page < (self.more_total_pages or 1) then
                self.more_page = self.more_page + 1
                self:refreshMenu()
            end
        elseif dir == "right" or dir == "east" or dir == "down" or dir == "south" then
            if self.more_page > 1 then
                self.more_page = self.more_page - 1
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
    self.tab_h = scale(42)

    -- Tamaño unificado y fijo: la ventana NUNCA cambia de tamaño
    self.card_w = scale(266)
    self.card_h = self.tab_h + scale(QUICK_CONTENT_H) + scale(4) -- el contenido entra 5 filas de lista + el pie de paginación

    -- Subvistas paginadas (fuentes y acciones)
    self.fonts_per_page = 5
    self.actions_per_page = 5
    self.font_row_h = scale(36)
    self.font_footer_h = scale(32)

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
    -- Pestaña Aa abierta -> el scrubber se esconde (solo barras); fuera de Aa -> vuelve
    self:_syncPeek()
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

-- Columnas del libro (1 o 2): es la opción "Columns" de KOReader (visible_pages), solo para libros reflowables
function ScrubberMenu:getBookColumns()
    local ui = self.ui
    local v
    pcall(function()
        if ui and ui.document and ui.document.configurable then v = ui.document.configurable.visible_pages end
        if not v and ui and ui.rolling then v = ui.rolling.visible_pages end
        if not v and ui and ui.font and ui.font.configurable then v = ui.font.configurable.visible_pages end
    end)
    return (tonumber(v) == 2) and 2 or 1
end

-- "rolling" = libro reflowable (EPUB, etc.), "paging" = documento con páginas fijas (PDF, DjVu, CBZ…)
function ScrubberMenu:getDocKind()
    local ui = self.ui
    if ui and ui.rolling then return "rolling" end
    if ui and ui.paging then return "paging" end
    return nil
end

-- Columnas del libro reflowable: 1 o 2
function ScrubberMenu:setColumns(n)
    local ui = self.ui
    if not (ui and ui.rolling) or n == self:getBookColumns() then return end
    pcall(function()
        -- Igual que el diálogo de KOReader: primero el valor guardado del libro, después el evento
        local conf = ui.document and ui.document.configurable
        if conf then conf.visible_pages = n end
        ui:handleEvent(Event:new("SetVisiblePages", n))
    end)
    self._typo_changed = true
    self:refreshMenu()
end

-- Modo de vista de un documento con páginas: página a página / continuo (scroll)
function ScrubberMenu:isContinuousView()
    local v
    pcall(function() v = self.ui.view and self.ui.view.page_scroll end)
    return v == true or (type(v) == "number" and v ~= 0)
end

function ScrubberMenu:setViewMode(continuous)
    local ui = self.ui
    if not (ui and ui.paging) or continuous == self:isContinuousView() then return end
    pcall(function()
        -- Igual que el diálogo de KOReader: primero el valor guardado del documento, después el evento
        local conf = ui.document and ui.document.configurable
        if conf then conf.page_scroll = continuous and 1 or 0 end
        ui:handleEvent(Event:new("SetScrollMode", continuous))
        -- Si el evento esperaba 0 / 1 en vez de true / false y no cambió nada, se prueba de esa forma
        if self:isContinuousView() ~= continuous then
            ui:handleEvent(Event:new("SetScrollMode", continuous and 1 or 0))
        end
    end)
    self._typo_changed = true
    self:refreshMenu()
end

-- ==========================================
-- MÁS OPCIONES DE LA PESTAÑA Aa (botón ⋮ "More")
-- Usa las opciones nativas de KOReader (ui.config.options): cada una trae su evento y sus valores,
-- igual que hace ZenOS, así que no depende de cómo se llame cada evento en cada versión.
-- ==========================================
local function valuesEqual(a, b)
    if type(a) == "table" and type(b) == "table" then
        return util.tableEquals(a, b)
    end
    if type(a) == "number" and type(b) == "number" then
        return math.abs(a - b) < 0.000001
    end
    return a == b
end

local function deepCopy(v)
    if type(v) == "table" then return util.tableDeepCopy(v) end
    return v
end

-- Valor escalar de una opción (los pares, como {100, 90}, se promedian)
local function scalarOf(v)
    if type(v) == "table" then
        local a = tonumber(v[1]) or 0
        local b = tonumber(v[2]) or a
        return (a + b) / 2
    end
    return tonumber(v)
end

-- Tabla nombre -> opción nativa de KOReader del documento abierto
function ScrubberMenu:_cfgOptions()
    if self._cfg_opts then return self._cfg_opts end
    local map = {}
    local ui = self.ui
    local panels = ui and ui.config and ui.config.options
    if type(panels) == "table" then
        for _i, panel in ipairs(panels) do
            for _j, opt in ipairs(panel.options or {}) do
                if opt.name then map[opt.name] = opt end
            end
        end
    end
    self._cfg_opts = map
    return map
end

function ScrubberMenu:_conf()
    local ui = self.ui
    return ui and ui.document and ui.document.configurable
end

local function fmtCleanNum(n)
    if type(n) ~= "number" then return tostring(n) end
    local r = math.floor(n * 100 + 0.5) / 100
    if math.abs(r - math.floor(r + 0.5)) < 0.005 then
        return tostring(math.floor(r + 0.5))
    end
    return tostring(r)
end

-- ¿La opción existe y se puede mostrar para este documento?
function ScrubberMenu:_optAvailable(name)
    local opt = self:_cfgOptions()[name]
    local conf = self:_conf()
    if not opt or opt.show == false or not conf then return false end
    if conf[name] == nil and not opt.current_func then return false end
    if opt.show_func then
        local ok, res = pcall(opt.show_func, conf, self.ui.document)
        if ok and not res then return false end
    end
    return true
end

-- Texto del valor de una opción (ej. margen "36", contraste "1.05", espaciado "Medium")
function ScrubberMenu:_optValueText(name, value)
    local opt = self:_cfgOptions()[name]
    -- PDF / CBZ: el margen va de 0 a 1.5 (no son píxeles) y la dirección de zoom se muestra abreviada
    if name == "page_margin" and self:getDocKind() == "paging" and type(value) == "number" then
        return string.format("%.2f", value)
    end
    if name == "rotation_mode" and type(value) == "number" then
        local names = { [0] = _("0°"), [1] = _("90° CW"), [2] = _("180°"), [3] = _("90° CCW") }
        if names[value] then return names[value] end
    end
    if name == "zoom_direction" and type(value) == "number" then
        local codes = { "LRTB", "TBLR", "LRBT", "BTLR", "BTRL", "RLBT", "TBRL", "RLTB" }
        local c = codes[7 - value + 1]
        if c then return c end
    end
    if name == "h_page_margins" and type(value) == "table" then
        local a = math.floor((tonumber(value[1]) or 0) + 0.5)
        local b = math.floor((tonumber(value[2]) or 0) + 0.5)
        if a == b then return tostring(a) end
        return tostring(a) .. "/" .. tostring(b)
    end
    if (name == "t_page_margin" or name == "b_page_margin" or name == "page_margin") and type(value) == "number" then
        return tostring(math.floor(value + 0.5))
    end
    if opt and (name == "word_spacing" or name == "word_expansion") then
        local labels = opt.toggle or opt.labels or opt.item_text
            or (name == "word_spacing" and { _("Small"), _("Medium"), _("Large") }
                or { _("None"), _("Some"), _("More") })
        for i, cand in ipairs(opt.values or {}) do
            if valuesEqual(cand, value) and labels[i] ~= nil then
                return tostring(labels[i])
            end
        end
    end
    if opt then
        if opt.show_true_value_func then
            local ok, txt = pcall(opt.show_true_value_func, value)
            if ok and txt ~= nil then return tostring(txt) end
        end
        local params = opt.more_options_param or {}
        if params.value_table and type(value) == "number" then
            local t = params.value_table[value + (params.value_table_shift or 0)]
            if t ~= nil then return tostring(t) end
        end
        for i, cand in ipairs(opt.values or {}) do
            if valuesEqual(cand, value) then
                local label = (opt.labels or opt.toggle or opt.item_text or {})[i]
                if label ~= nil then return tostring(label) end
                break
            end
        end
    end
    if type(value) == "table" then
        local parts = {}
        for _i, part in ipairs(value) do parts[#parts + 1] = fmtCleanNum(part) end
        return table.concat(parts, "/")
    end
    if type(value) == "number" then
        return fmtCleanNum(value)
    end
    return tostring(value)
end

-- Aplica una opción nativa: primero ConfigChange (guarda el valor en el libro) y después su evento
function ScrubberMenu:_applyConfigOption(name, value)
    local ui = self.ui
    local opt = self:_cfgOptions()[name]
    if not (ui and opt) then return false end
    local ok = pcall(function()
        local params = opt.more_options_param
        if params and params.names and type(value) == "table" then
            for i, key in ipairs(params.names) do
                ui:handleEvent(Event:new("ConfigChange", key, value[i]))
            end
            ui:handleEvent(Event:new(params.event or opt.event, value))
            return
        end
        local arg = value
        for i, cand in ipairs(opt.values or {}) do
            if valuesEqual(cand, value) then
                if opt.args then arg = opt.args[i] end
                break
            end
        end
        ui:handleEvent(Event:new("ConfigChange", name, deepCopy(value)))
        if opt.event then ui:handleEvent(Event:new(opt.event, arg)) end
    end)
    if not ok then logger.warn("PageScrubber: no se pudo aplicar la opción " .. tostring(name)) end
    self._typo_changed = true
    return ok
end

-- Un paso de una opción numérica (dir = +1 sube el valor mostrado, -1 lo baja)
function ScrubberMenu:_stepOption(name, dir)
    local opt = self:_cfgOptions()[name]
    local conf = self:_conf()
    if not (opt and conf and conf[name] ~= nil) then return end
    local value = conf[name]
    local params = opt.more_options_param or {}
    local values = opt.values or {}
    local new
    -- En PDF / CBZ se avanza por los valores predefinidos de KOReader (el valor exacto se pone con el menú nativo al mantener apretado)
    local paging = self:getDocKind() == "paging"
    local continuous = (#values < 2) or (not paging and opt.more_options and (type(value) ~= "table" or name == "h_page_margins"))
    if continuous then
        local lo = params.value_min or params.left_min or scalarOf(values[1])
        local hi = params.value_max or params.left_max or scalarOf(values[#values])
        local step = params.value_step or params.left_step or 1
        if params.value_table then
            -- El valor guardado es un índice de la tabla (p. ej. contraste): el rango es el de la tabla entera
            local shift = params.value_table_shift or 0
            lo, hi, step = 1 - shift, #params.value_table - shift, 1
        end
        if name == "h_page_margins" or name == "t_page_margin" or name == "b_page_margin" or name == "page_margin" then
            step = math.max(step, 5)   -- los márgenes se afinan de a 5 (si no, hay que tocar demasiado)
            if type(lo) ~= "number" then lo = 0 end
            if type(hi) ~= "number" then hi = 200 end
        end
        if type(lo) ~= "number" or type(hi) ~= "number" then return end
        if hi < lo then lo, hi = hi, lo end
        local n = math.max(lo, math.min(hi, (scalarOf(value) or lo) + dir * step))
        n = tonumber(string.format("%.6f", n))
        if name == "h_page_margins" then new = { n, n } else new = n end
    else
        -- Valores predefinidos: el más cercano en la dirección pedida
        local cur = scalarOf(value) or 0
        local best, best_d
        for _i, v in ipairs(values) do
            local s = scalarOf(v)
            if s and (s - cur) * dir > 0.000001 then
                local d = math.abs(s - cur)
                if not best_d or d < best_d then best, best_d = v, d end
            end
        end
        if best ~= nil then new = deepCopy(best) end
    end
    if new == nil or valuesEqual(new, value) then return end
    self:_applyConfigOption(name, new)
end

function ScrubberMenu:_marginsSynced()
    local ui = self.ui
    local conf = self:_conf()
    if ui and ui.typeset and ui.typeset.sync_t_b_page_margins ~= nil then
        return ui.typeset.sync_t_b_page_margins == true
    end
    return conf and conf.sync_t_b_page_margins == 1
end

-- Margen superior e inferior van juntos (una sola fila "T/B")
function ScrubberMenu:_stepMarginTB(dir)
    self:_stepOption("t_page_margin", dir)
    local conf = self:_conf()
    if conf and conf.b_page_margin ~= nil and conf.t_page_margin ~= nil
            and conf.b_page_margin ~= conf.t_page_margin and not self:_marginsSynced() then
        self:_applyConfigOption("b_page_margin", conf.t_page_margin)
    end
end

-- Modo continuo (scroll) de un libro reflowable (EPUB y similares)
function ScrubberMenu:isRollingScroll()
    local conf = self:_conf()
    if conf and conf.view_mode ~= nil then return conf.view_mode == 1 end
    local ok, mode = pcall(function() return self.ui.view.view_mode end)
    return ok and mode == "scroll"
end

-- Píldora de 3 segmentos de un EPUB: 1 = una columna, 2 = dos columnas, 3 = continuo
function ScrubberMenu:setRollingLayout(i)
    if not (self.ui and self.ui.rolling) then return end
    if i == 3 then
        if not self:isRollingScroll() then self:_applyConfigOption("view_mode", 1) end
    else
        if self:isRollingScroll() then self:_applyConfigOption("view_mode", 0) end
        if i ~= self:getBookColumns() then
            -- setColumns ya marca el cambio y repinta
            self:setColumns(i)
            return
        end
    end
    self._typo_changed = true
    self:refreshMenu()
end

-- ¿La opción está habilitada ahora? (p. ej. el zoom se apaga cuando el reflow está activo)
function ScrubberMenu:_optEnabled(name)
    local opt = self:_cfgOptions()[name]
    local conf = self:_conf()
    if not opt then return false end
    if opt.enabled_func then
        local ok, res = pcall(opt.enabled_func, conf, self.ui and self.ui.document)
        if ok and res == false then return false end
    end
    return true
end

-- Filas de cada grupo de la pestaña Aa en PDF / CBZ: "reflow", "page" y "visual"
-- (solo las opciones que este documento tiene y que están habilitadas)
function ScrubberMenu:_groupRows(group)
    local rows = {}
    local function add(label, kind, name)
        if not (self:_optAvailable(name) and self:_optEnabled(name)) then return end
        local text = label
        local opt = self:_cfgOptions()[name]
        if name == "zoom_range_number" and opt and opt.name_text_func then
            local ok, t = pcall(opt.name_text_func, self:_conf())
            if ok and t then text = t end
        end
        rows[#rows + 1] = { id = name, label = text, kind = kind, name = name, names = { name } }
    end
    if group == "reflow" then
        add(_("Reflow"), "switch", "text_wrap")
        add(_("Font size"), "pick", "font_size")
        add(_("Word gap"), "pick", "word_spacing")
        add(_("Line spacing"), "pick", "line_spacing")
        add(_("Alignment"), "pick", "justification")
    elseif group == "page" then
        add(_("Rotation"), "pick", "rotation_mode")
        add(_("Page crop"), "pick", "trim_page")
        add(_("Margin"), "pick", "page_margin")
        add(_("Auto straighten"), "pick", "auto_straighten")
        add(_("Fit zoom to"), "pick", "zoom_mode_genus")
        add(_("Fit"), "pick", "zoom_mode_type")
        add(_("Rows"), "pick", "zoom_range_number")
        add(_("Zoom factor"), "pick", "zoom_factor")
        add(_("Direction"), "pick", "zoom_direction")
    elseif group == "visual" then
        add(_("Contrast"), "pick", "contrast")
        add(_("Saturation"), "pick", "saturation")
        add(_("White threshold"), "pick", "white_threshold")
        add(_("Dewatermark"), "switch", "page_opt")
        add(_("Background cleanup"), "switch", "background_cleanup")
        add(_("Dithering"), "switch", "hw_dithering")
        add(_("Dithering"), "switch", "sw_dithering")
        add(_("Render quality"), "pick", "quality")
    end
    return rows
end

-- Texto corto a la derecha de cada grupo en la pestaña Aa (PDF / CBZ)
function ScrubberMenu:_groupSummary(group)
    local conf = self:_conf()
    if not conf then return "" end
    local ok, txt = pcall(function()
        if group == "reflow" and self:_optAvailable("text_wrap") then
            return (conf.text_wrap == 1) and _("On") or _("Off")
        elseif group == "page" and self:_optAvailable("zoom_mode_genus") and self:_optEnabled("zoom_mode_genus") then
            return self:_optValueText("zoom_mode_genus", conf.zoom_mode_genus)
        end
    end)
    if ok and type(txt) == "string" then return txt end
    return ""
end

-- Filas de la vista More (solo las opciones que este documento tiene)
function ScrubberMenu:_moreRows()
    if self:getDocKind() == "paging" then
        return self:_groupRows(self.more_group or "page")
    end
    -- EPUB: dentro de View options / Style options se ven sus opciones
    local g = self.more_group
    if g == "view" or g == "style" then
        return self:_rollingGroupRows(g)
    end
    -- Lista principal de un EPUB (orden de KOReader): Rotation primero, márgenes y los dos submenús
    local rows = {}
    local function add(id, label, kind, name, names)
        if self:_optAvailable(name) then
            rows[#rows + 1] = { id = id, label = label, kind = kind, name = name, names = names or { name } }
        end
    end
    add("rotation", _("Rotation"), "pick", "rotation_mode")
    add("margin_lr", _("Margin L/R"), "step", "h_page_margins")
    add("margin_tb", _("Margin T/B"), "step", "t_page_margin", { "t_page_margin", "b_page_margin" })
    if #self:_rollingGroupRows("view") > 0 then
        rows[#rows + 1] = { id = "view_options", label = _("View options"), kind = "group", group = "view" }
    end
    if #self:_rollingGroupRows("style") > 0 then
        rows[#rows + 1] = { id = "style_options", label = _("Style options"), kind = "group", group = "style" }
    end
    return rows
end

-- Páginas de la vista More: hasta 6 filas entran juntas; si hay más, se pagina de a 5 con los puntitos abajo
function ScrubberMenu:_morePages()
    local pages = {}
    local all = self:_moreRows()
    if #all <= 6 then
        pages[1] = { entries = all, plain = true }
        return pages, false
    end
    local per = self.fonts_per_page or 5
    for i = 1, #all, per do
        local ents = {}
        for j = i, math.min(#all, i + per - 1) do ents[#ents + 1] = all[j] end
        pages[#pages + 1] = { entries = ents, plain = true }
    end
    return pages, #pages > 1
end

-- Submenús de un EPUB: "View options" y "Style options"
function ScrubberMenu:_rollingGroupRows(group)
    local rows = {}
    local function add(id, label, kind, name)
        if self:_optAvailable(name) and self:_optEnabled(name) then
            rows[#rows + 1] = { id = id, label = label, kind = kind, name = name, names = { name } }
        end
    end
    if group == "view" then
        add("render_mode", _("Render mode"), "pick", "block_rendering_mode")
        add("render_dpi", _("Zoom (dpi)"), "pick", "render_dpi")
        add("word_spacing", _("Word spacing"), "pick", "word_spacing")
        add("word_expansion", _("Word expansion"), "pick", "word_expansion")
    elseif group == "style" then
        add("contrast", _("Contrast"), "pick", "font_gamma")
        add("font_weight", _("Font weight"), "pick", "font_base_weight")
        add("font_hinting", _("Font hinting"), "pick", "font_hinting")
        add("font_kerning", _("Font kerning"), "pick", "font_kerning")
        add("embedded_css", _("Embedded style"), "switch", "embedded_css")
        add("embedded_fonts", _("Embedded fonts"), "switch", "embedded_fonts")
        add("image_scaling", _("Image scaling"), "switch", "smooth_scaling")
    end
    return rows
end

function ScrubberMenu:_moreStep(row, dir)
    if row.id == "margin_tb" then
        self:_stepMarginTB(dir)
    else
        self:_stepOption(row.name, dir)
    end
    self:refreshMenu()
end

function ScrubberMenu:_moreCycle(row)
    local opt = self:_cfgOptions()[row.name]
    local conf = self:_conf()
    if not (opt and conf) then return end
    local values = opt.values
    if not (values and #values > 0) then
        if row.name == "word_spacing" then
            values = { { 75, 50 }, { 100, 90 }, { 125, 115 } }
        elseif row.name == "word_expansion" then
            values = { 0, 15, 30 }
        else
            return
        end
    end
    local cur = conf[row.name]
    local idx = 0
    for i, v in ipairs(values) do
        if valuesEqual(v, cur) then idx = i; break end
    end
    if idx == 0 and cur ~= nil then
        local cur_s = scalarOf(cur)
        if cur_s then
            local best_d
            for i, v in ipairs(values) do
                local vs = scalarOf(v)
                if vs then
                    local d = math.abs(vs - cur_s)
                    if not best_d or d < best_d then best_d = d; idx = i end
                end
            end
        end
    end
    self:_applyConfigOption(row.name, values[(idx % #values) + 1])
    self:refreshMenu()
end

function ScrubberMenu:_moreToggle(row)
    local opt = self:_cfgOptions()[row.name]
    local conf = self:_conf()
    if not (opt and conf) then return end
    local on = conf[row.name] ~= nil and conf[row.name] ~= 0 and conf[row.name] ~= false
    local vals = opt.values or {}
    local new
    if #vals >= 2 then new = on and vals[1] or vals[2] else new = on and 0 or 1 end
    self:_applyConfigOption(row.name, new)
    self:refreshMenu()
end

-- ==========================================
-- VALORES POR DEFECTO (mantener apretada una opción)
-- Misma convención que KOReader / ZenOS: "copt_<opción>" (reflowable) o "kopt_<opción>" (PDF, CBZ…) en los
-- ajustes globales; los libros nuevos arrancan con eso, y los ya abiertos conservan lo suyo.
-- ==========================================
function ScrubberMenu:_defaultKey(name)
    if name == "font_face" then return "cre_font" end
    local ui = self.ui
    local prefix = ui and ui.config and ui.config.options and ui.config.options.prefix
    if not prefix then prefix = (ui and ui.rolling) and "copt" or "kopt" end
    return prefix .. "_" .. name
end

-- Valor actual de una opción para guardarlo como default
function ScrubberMenu:_currentFor(name)
    if name == "font_face" then return self:getBookFontFace() end
    if name == "rotation_mode" then
        local ok, mode = pcall(function() return Screen:getRotationMode() end)
        if ok and mode ~= nil then return mode end
    end
    if name == "font_size" and self:getDocKind() ~= "paging" then return self:getBookFontSize() end
    if name == "line_spacing" then
        local conf = self:_conf()
        if conf and conf.line_spacing ~= nil then return conf.line_spacing end
        return self:getBookLineSpacing()
    end
    local conf = self:_conf()
    if name == "visible_pages" then
        if conf and conf.visible_pages ~= nil then return conf.visible_pages end
        return self:getBookColumns()
    end
    if name == "view_mode" then
        if conf and conf.view_mode ~= nil then return conf.view_mode end
        return self:isRollingScroll() and 1 or 0
    end
    if name == "page_scroll" then
        if conf and conf.page_scroll ~= nil then return conf.page_scroll end
        return self:isContinuousView() and 1 or 0
    end
    return conf and conf[name]
end

function ScrubberMenu:_isDefaultSet(names)
    if not G_reader_settings or not names then return false end
    for _i, name in ipairs(names) do
        local d = G_reader_settings:readSetting(self:_defaultKey(name))
        local cur = self:_currentFor(name)
        if d == nil or cur == nil or not valuesEqual(d, cur) then return false end
    end
    return #names > 0
end

function ScrubberMenu:_showDefaultDialog(label, names)
    if not G_reader_settings then return end
    local list = {}
    for _i, name in ipairs(names) do
        local v = self:_currentFor(name)
        if v ~= nil then list[#list + 1] = { name = name, value = deepCopy(v) } end
    end
    if #list == 0 then return end
    local has_default = false
    for _i, it in ipairs(list) do
        if G_reader_settings:readSetting(self:_defaultKey(it.name)) ~= nil then has_default = true end
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {
        {{
            text = _("Set as default"),
            callback = function()
                UIManager:close(dialog)
                for _j, it in ipairs(list) do
                    G_reader_settings:saveSetting(self:_defaultKey(it.name), deepCopy(it.value))
                end
                if G_reader_settings.flush then G_reader_settings:flush() end
                if not self._closed then self:refreshMenu() end
            end,
        }},
    }
    if has_default then
        buttons[#buttons + 1] = {{
            text = _("Remove default"),
            callback = function()
                UIManager:close(dialog)
                for _j, it in ipairs(list) do
                    G_reader_settings:delSetting(self:_defaultKey(it.name))
                end
                if G_reader_settings.flush then G_reader_settings:flush() end
                if not self._closed then self:refreshMenu() end
            end,
        }}
    end
    dialog = ButtonDialog:new{ title = label, buttons = buttons }
    UIManager:show(dialog)
end

-- Controlador que le presta a la ventana de KOReader sus métodos nativos de ConfigDialog (el mismo truco que usa
-- ZenOS): así el menú de los tres puntitos (flechitas, valor exacto, "Set as default") es EXACTAMENTE el de KOReader.
function ScrubberMenu:_nativeController()
    local ui = self.ui
    if not (ui and ui.config and ui.config.options and ui.document) then return nil end
    if self._native_ctl and self._native_ctl.ui == ui then return self._native_ctl end
    local ok, ConfigDialog = pcall(require, "ui/widget/configdialog")
    if not ok or not ConfigDialog then return nil end
    local menu = self
    local ctl = setmetatable({
        ui = ui,
        document = ui.document,
        configurable = ui.config.configurable or ui.document.configurable,
        config_options = ui.config.options,
        dialog_frame = { dimen = self.dimen },
    }, { __index = ConfigDialog })
    ctl.config = ctl
    ctl.update = function()
        if not menu._closed then menu:refreshMenu() end
    end
    ctl.updateConfigPanel = ctl.update
    ctl.onConfigChoice = function(c, name, value)
        menu._typo_changed = true
        local r = ConfigDialog.onConfigChoice(c, name, value)
        -- Margen T/B: la fila las maneja juntas, así que el valor del margen superior se copia al inferior
        local m = menu._native_mirror
        if m and name == m.from and not menu:_marginsSynced() then
            menu:_applyConfigOption(m.to, value)
        end
        return r
    end
    self._native_ctl = ctl
    return ctl
end

-- Abre el menú nativo de KOReader de una opción (si tiene uno). Devuelve true si lo abrió.
function ScrubberMenu:_showNativeMore(name, label, mirror_to)
    local map = self:_cfgOptions()
    local key = name
    -- Tamaño de fuente de un libro reflowable: el menú nativo cuelga de "font_fine_tune"
    if name == "font_size" and map.font_fine_tune and map.font_fine_tune.more_options then
        key = "font_fine_tune"
    end
    local opt = map[key]
    if not (opt and opt.more_options) then return false end
    local ctl = self:_nativeController()
    if not ctl then return false end

    local params = {}
    for k, v in pairs(opt.more_options_param or {}) do params[k] = v end
    params.show_true_value_func = params.show_true_value_func or opt.show_true_value_func
    -- No se esconde ninguna ventana de fondo mientras está abierto el menú
    params.hide_on_picker_show = false

    local default = opt.default_value
    if params.names then
        default = {}
        for i, n in ipairs(params.names) do
            local o = map[n]
            default[i] = o and o.default_value
        end
    elseif default == nil and name == "font_size" and map.font_size then
        default = map.font_size.default_value
    end

    self._native_mirror = mirror_to and { from = name, to = mirror_to } or nil
    local ok = pcall(function()
        ctl:onConfigMoreChoose(opt.values, default, opt.name, opt.event, nil,
            label or params.name_text or opt.name_text, params)
    end)
    return ok
end

function ScrubberMenu:_onTypoHold(pos)
    if not pos:intersectWith(self.popup_rect) then return false end
    if self.active_tab == "typo" then
        for _i, h in ipairs(self._typo_hold or {}) do
            if pos:intersectWith(h.dimen) then
                self:_showDefaultDialog(h.label, h.names)
                return true
            end
        end
    elseif self.active_tab == "more_list" then
        for _i, hit in ipairs(self.more_hits or {}) do
            if pos:intersectWith(hit.dimen) then
                if hit.row.names then self:_showDefaultDialog(hit.row.label, hit.row.names) end
                return true
            end
        end
    end
    return false
end

-- ==========================================
-- PEEK: con la pestaña Aa abierta el scrubber se esconde y solo quedan las barras de arriba y abajo,
-- así se ve la página real del libro mientras se ajusta la tipografía. Al salir de Aa vuelve el scrubber.
-- ==========================================
-- ¿Estamos dentro de un submenú de Aa? (catálogo de fuentes, More / sus grupos, selector de una opción)
function ScrubberMenu:_isTypoSubview()
    local t = self.active_tab
    return t == "font_list" or t == "more_list" or t == "opt_picker"
end

-- Flecha de volver: sube un nivel. Selector de opción -> la lista de donde vino (sin aplicar nada, igual que
-- Cancel); grupo de More de un EPUB (View / Style options) -> More; el resto -> la pestaña Aa.
function ScrubberMenu:_typoBack()
    local t = self.active_tab
    if t == "opt_picker" then
        self:_pickerClose()
        return
    end
    if t == "more_list" and self:getDocKind() == "rolling" and self.more_group then
        self.more_group = nil
        self.more_page = 1
    else
        self.active_tab = "typo"
    end
    self:refreshMenu()
end

function ScrubberMenu:_isAaTab()
    local t = self.active_tab
    return t == "typo" or t == "font_list" or t == "more_list" or t == "opt_picker"
end

-- Sincroniza el lector de fondo con la página actual del scrubber al entrar en Aa
function ScrubberMenu:_syncReaderToScrubberPage()
    local s = self.scrubber_ui
    local ui = self.ui or (s and s.ui)
    if not (s and ui) then return end
    local target = tonumber(s._cur_page)
    if not target or target < 1 then return end
    local reader_page
    pcall(function()
        reader_page = (ui.rolling and ui.rolling.current_page)
            or (ui.paging and ui.paging.current_page)
            or (ui.getCurrentPage and ui:getCurrentPage())
    end)
    if reader_page ~= target then
        pcall(function()
            ui:handleEvent(Event:new("GotoPage", target))
        end)
    end
end

-- Suelta el modo peek del scrubber (libera el buffer de trabajo) y lo repinta completo
function ScrubberMenu:_releasePeek()
    local s = self.scrubber_ui
    if not (s and s._typo_peek) then return end
    s._typo_peek = false
    if s._peek_bb then
        pcall(function() s._peek_bb:free() end)
        s._peek_bb = nil
    end
    if not s._closing then
        UIManager:setDirty(s, "ui", s.dimen)
    end
end

-- Regenera miniaturas y datos del scrubber tras cambiar la tipografía (cantidad de páginas, capítulos…)
function ScrubberMenu:_regenScrubber()
    local s = self.scrubber_ui
    local ui = self.ui
    if not s or s._closing then return end

    local function applyRefresh()
        pcall(function()
            if s._closing then return end
            local total = (ui and ui.document and ui.document.getPageCount and ui.document:getPageCount())
                or s._total_pages or s.total_pages or 1
            s._total_pages = total
            s.total_pages = total

            local reader_page = (ui and ui.rolling and ui.rolling.current_page)
                or (ui and ui.paging and ui.paging.current_page)
                or (ui and ui.getCurrentPage and ui:getCurrentPage())
            if type(reader_page) == "number" and reader_page >= 1 then
                local clamped = math.max(1, math.min(total, reader_page))
                s._cur_page = clamped
                if s.cur_page ~= nil then s.cur_page = clamped end
            end

            if s._slider then
                s._slider.value_max = total
                if s._cur_page then s._slider.value = s._cur_page end
            end

            -- 1. Vaciar caché de miniaturas y vistas split
            s._tile_cache = {}
            if s._split_cache then s._split_cache = {} end
            s._split_preview_page = nil
            if s._clearGridTiles then s:_clearGridTiles(true) end

            -- 2. Alternar 1px la dimensión solicitada para que ReaderThumbnail regenere con la nueva fuente
            if s._grid_item_w then
                s._thumb_req_w = (s._thumb_req_w == s._grid_item_w) and (s._grid_item_w + 1) or s._grid_item_w
            end
            if s._thumb_req_split_w then
                s._thumb_req_split_w = s._thumb_req_split_w + 1
            end

            -- 3. Recargar slots inmediatamente para evitar que queden en blanco (slot.loading = true)
            if s._updateChapterMarks then s:_updateChapterMarks() end
            if s._updateTexts then s:_updateTexts() end
            if s._updateGridPages then
                s:_updateGridPages()
            elseif s._previewPage then
                s:_previewPage(s._cur_page or 1, false)
            end

            UIManager:setDirty(s, "ui", s.dimen)
        end)
    end

    applyRefresh()
    UIManager:nextTick(function()
        if s._closing then return end
        local new_total = ui and ui.document and ui.document.getPageCount and ui.document:getPageCount()
        if new_total and new_total ~= s._total_pages then
            applyRefresh()
        else
            pcall(function()
                if s._updateGridPages then s:_updateGridPages() end
                UIManager:setDirty(s, "ui", s.dimen)
            end)
        end
    end)
end

function ScrubberMenu:_syncPeek()
    local s = self.scrubber_ui
    if not s or s._closing or self._closed then return end
    if self:_isAaTab() then
        if not s._typo_peek then
            s._typo_peek = true
            self:_syncReaderToScrubberPage()
            -- Se repinta desde el lector (la página) hacia arriba: scrubber (solo barras) y este menú
            UIManager:setDirty(self.ui or "all", "partial")
        end
    elseif s._typo_peek then
        self:_releasePeek()
        if self._typo_changed then
            self._typo_changed = false
            self:_regenScrubber()
        end
    end
end

-- ¿La instancia pertenece a la clase (o a una subclase)?
local function isOfClass(widget, cls)
    local mt = getmetatable(widget)
    while mt do
        if mt == cls then return true end
        mt = getmetatable(mt)
    end
    return false
end

-- Cierra TODO lo del plugin que haya en la pila de ventanas (scrubber, índice, menús, ajustes). Devuelve cuántos cerró.
local function closeScrubberWidgets()
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return 0 end
    local classes = {}
    for _i, name in ipairs({ "scrubber_ui", "scrubber_menu", "scrubber_toc", "scrubber_settings" }) do
        local ok, cls = pcall(require, name)
        if ok and type(cls) == "table" then classes[#classes + 1] = cls end
    end
    local victims = {}
    for _i, win in ipairs(stack) do
        local w = win and win.widget
        if w then
            for _j, cls in ipairs(classes) do
                if isOfClass(w, cls) then victims[#victims + 1] = w; break end
            end
        end
    end
    for _i, w in ipairs(victims) do
        pcall(function() UIManager:close(w) end)
    end
    return #victims
end

-- Rota la pantalla: de vertical a horizontal (y de horizontal otra vez a vertical).
-- El scrubber se arma con el tamaño de pantalla con el que se abrió y no sabe re-acomodarse: si hay uno abierto
-- (o aparece uno) mientras se rota, se pinta con medidas viejas y queda roto. Por eso:
--   1. se marca "rotando": durante ese lapso el plugin no abre ningún scrubber / menú nuevo (un gesto que llegue
--      justo después de cerrarse el menú podía lanzar uno con las medidas de la orientación anterior);
--   2. se cierra de verdad todo lo del plugin que esté abierto, en el momento;
--   3. se rota con el libro ya repintado;
--   4. después de rotar se vuelve a barrer la pila por si quedó o apareció algo, y se repinta todo.
function ScrubberMenu:rotateScreen()
    if not Screen then return end
    local landscape = false
    pcall(function() landscape = (Screen:getScreenMode() == "landscape") end)
    local target = landscape and Screen.DEVICE_ROTATED_UPRIGHT or Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE
    self:rotateScreenTo(target)
end

-- Rota la pantalla a una de las 4 orientaciones de KOReader (0, 90 horario, 180, 90 antihorario)
function ScrubberMenu:rotateScreenTo(target)
    local ui = self.ui
    if not (Screen and ui) then return end
    if ScrubberState.rotating then return end
    if target == nil then return end

    ScrubberState.rotating = true
    -- Pase lo que pase, el bloqueo se levanta solo
    UIManager:scheduleIn(2.5, function() ScrubberState.rotating = false end)

    local function doRotate()
        pcall(function() ui:handleEvent(Event:new("SetRotationMode", target)) end)
        -- Respaldo: si nadie atendió el evento (la rotación quedó igual), se rota a mano como hace KOReader
        pcall(function()
            if Screen:getRotationMode() ~= target then
                Screen:setRotationMode(target)
                local size = Screen:getSize()
                ui:handleEvent(Event:new("SetDimensions", size))
                if ui.onScreenResize then ui:onScreenResize(size) end
            end
        end)
        UIManager:setDirty("all", "full")

        -- Barridos finales: si quedó (o apareció) algo del plugin, se cierra y se repinta todo
        UIManager:scheduleIn(0.35, function()
            local n = closeScrubberWidgets()
            if n > 0 then
                logger.warn("PageScrubber: tras rotar quedaron abiertos " .. n .. " widgets del plugin; se cerraron")
            end
            UIManager:setDirty("all", "full")
        end)
        UIManager:scheduleIn(1.0, function()
            local n = closeScrubberWidgets()
            if n > 0 then
                logger.warn("PageScrubber: tras rotar apareció " .. n .. " widget del plugin; se cerró")
                UIManager:setDirty("all", "full")
            end
        end)
    end

    UIManager:close(self)
    closeScrubberWidgets()
    UIManager:setDirty(nil, "full")
    UIManager:scheduleIn(0.25, doRotate)
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

saveLightNow = function()
    saveLight()
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

-- ==========================================
-- SLIDER DE BRILLO (el de KiKome, en el menú rápido)
-- ==========================================

-- Datos del slider para este dispositivo (nil si no hay acceso directo al nivel de la luz).
-- El mínimo es el primer nivel que realmente ilumina: el 0 apaga la luz y eso lo hace solo el toggle.
function ScrubberMenu:_getLightSlider()
    local ok, res = pcall(function()
        local powerd = Device.getPowerDevice and Device:getPowerDevice()
        if not (powerd and Device.hasFrontlight and Device:hasFrontlight()
                and type(powerd.setIntensity) == "function" and type(powerd.frontlightIntensity) == "function") then
            return nil
        end
        local base = tonumber(powerd.fl_min) or 0
        return {
            powerd = powerd,
            base = base,
            min = base + 1,
            max = tonumber(powerd.fl_max) or 100,
            cur = tonumber(powerd:frontlightIntensity()) or 0,
        }
    end)
    return ok and res or nil
end

-- Aplica un nivel nuevo y repinta solo el bloque de brillo
function ScrubberMenu:_setLightLevel(value)
    local sl = self:_getLightSlider()
    if not sl then return end
    local v = math.max(sl.min, math.min(sl.max, math.floor(value + 0.5)))
    if v == sl.cur then return end
    local powerd = sl.powerd
    pcall(function()
        powerd:setIntensity(v)
        -- Si ese nivel cuenta como apagado en este dispositivo, se sube hasta que prenda (como KiKome)
        local try = v
        while try < sl.max and (tonumber(powerd:frontlightIntensity()) or 0) <= 0 do
            try = try + 1
            powerd:setIntensity(try)
        end
        if type(powerd.updateResumeFrontlightState) == "function" then
            powerd:updateResumeFrontlightState()
        end
    end)
    self._fl_dirty = true
    -- Igual que la barra de progreso del scrubber: mientras se arrastra, refresco "fast" (rápido, sin
    -- parpadeo); al soltar, _endLightDrag hace un repintado completo del bloque para limpiar el ghosting.
    UIManager:setDirty(self, self._light_drag and "fast" or "ui",
        self._light_block_dimen or expandRect(self.popup_rect, scale(8)))
end

-- Empieza el arrastre: la perilla desaparece (queda solo el relleno, como en la barra del scrubber)
function ScrubberMenu:_beginLightDrag(x)
    self._light_drag = true
    -- Fuerza el repintado aunque el nivel no cambie en este primer toque, para que la perilla se oculte ya
    UIManager:setDirty(self, "fast", self._light_block_dimen or expandRect(self.popup_rect, scale(8)))
    self:_lightDragTo(x)
end

-- Zona donde se agarra la perilla: el riel entero y medio botón de margen a cada lado
function ScrubberMenu:_lightGrab(pos)
    local h = self._light_hit
    if self.active_tab ~= "quick" or not (h and h.track) then return false end
    local m = scale(15)
    local area = Geom:new{ x = h.track.x - m, y = h.track.y, w = h.track.w + 2 * m, h = h.track.h }
    return pos:intersectWith(area)
end

function ScrubberMenu:_lightDragTo(x)
    local h = self._light_hit
    local sl = self:_getLightSlider()
    if not (h and h.track and sl) then return end
    local frac = math.max(0, math.min(1, (x - h.track.x) / h.track.w))
    self:_setLightLevel(sl.base + frac * (sl.max - sl.base))
end

-- Toques del bloque de brillo. Devuelve true si el toque era suyo.
function ScrubberMenu:_onLightTap(pos)
    local h = self._light_hit
    if not h then return false end

    if h.toggle and pos:intersectWith(h.toggle) then
        self:toggleFrontlight()
        self:refreshMenu()
        return true
    end

    local sl = self:_getLightSlider()
    if not (sl and h.track) then return false end
    -- − / + mueven 1% del recorrido (al menos un nivel)
    local step = math.max(1, math.floor((sl.max - sl.min) / 100 + 0.5))
    if pos:intersectWith(h.minus) then
        -- Con la luz apagada "−" no la prende
        if sl.cur > 0 then self:_setLightLevel(sl.cur - step) end
        return true
    elseif pos:intersectWith(h.plus) then
        self:_setLightLevel(sl.cur + step)
        return true
    elseif pos:intersectWith(h.track) then
        local frac = math.max(0, math.min(1, (pos.x - h.track.x) / h.track.w))
        self:_setLightLevel(sl.base + frac * (sl.max - sl.base))
        return true
    end
    return false
end

-- Bloque de brillo: arriba el título con el % y el toggle (mismo toggle de siempre) a la derecha;
-- abajo [−] slider [+] con el riel gris, el relleno negro y la perilla de aro.
function ScrubberMenu:_paintLightBlock(bb, x, w, y, head_h, head_gap, slider_h, sl)
    local BLACK = Blitbuffer.COLOR_BLACK
    local is_fl = self:isFrontlightOn()
    local frac = 0
    if sl then
        frac = math.max(0, math.min(1, (sl.cur - sl.base) / math.max(sl.max - sl.base, 1)))
    end

    -- Cabecera
    local face = Font:getFace("cfont", scaleText(11))
    local tw_title = TextWidget:new{ text = _("Brightness"), face = face, bold = false, fgcolor = BLACK }
    local tsz = tw_title:getSize()
    tw_title:paintTo(bb, x, y + math.floor((head_h - tsz.h) / 2))
    tw_title:free()
    if sl then
        local tw_pct = TextWidget:new{
            text = string.format("%d%%", math.floor(frac * 100 + 0.5)),
            face = face, fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        local psz = tw_pct:getSize()
        tw_pct:paintTo(bb, x + tsz.w + scale(8), y + math.floor((head_h - psz.h) / 2))
        tw_pct:free()
    end

    local sw_w, sw_h = scale(SWITCH_W), scale(SWITCH_H)
    local sw_x = x + w - sw_w
    paintSwitch(bb, sw_x, y + math.floor((head_h - sw_h) / 2), sw_w, sw_h, is_fl)

    local hp = scale(12)
    self._light_hit = {
        toggle = Geom:new{ x = sw_x - hp, y = y - scale(4), w = sw_w + hp + scale(8), h = head_h + scale(8) },
    }
    self._light_block_dimen = Geom:new{ x = x - scale(6), y = y - scale(2), w = w + scale(12), h = head_h + head_gap + slider_h + scale(4) }

    if not sl then return end

    -- Slider
    local sy = y + head_h + head_gap
    local cy = sy + math.floor(slider_h / 2)
    local touch_h = scale(36)                 -- la zona de toque es más alta que lo que se ve
    local ty0 = cy - math.floor(touch_h / 2)
    local label_w = scale(22)
    local gap = scale(6)
    local knob = scale(18)
    local track_h = scale(3)
    local track_x = x + label_w + gap
    local track_w = w - 2 * (label_w + gap)

    -- Signos − / + dibujados a mano (sin círculo), centrados en su caja
    local arm = scale(14)
    local th = math.max(2, scale(2))
    local plus_x = x + w - label_w
    -- (pegados a los bordes de la fila, alineados con el título y con el toggle)
    bb:paintRect(x, cy - math.floor(th / 2), arm, th, BLACK)
    bb:paintRect(x + w - arm, cy - math.floor(th / 2), arm, th, BLACK)
    bb:paintRect(x + w - math.floor((arm + th) / 2), cy - math.floor(arm / 2), th, arm, BLACK)

    -- Riel gris, relleno negro hasta la perilla y perilla blanca con contorno fino
    local kx = math.max(0, math.min(track_w - knob, math.floor(frac * track_w) - math.floor(knob / 2)))
    local dragging = self._light_drag == true
    -- Arrastrando no hay perilla: el relleno llega exacto hasta el dedo (como la barra del scrubber)
    local fill_w = dragging and math.max(track_h, math.floor(frac * track_w + 0.5))
        or math.max(track_h, kx + math.floor(knob / 2))
    local tr = math.floor(track_h / 2)
    local ty = cy - tr
    paintRoundRect(bb, track_x, ty, track_w, track_h, tr, Blitbuffer.COLOR_LIGHT_GRAY)
    paintRoundRect(bb, track_x, ty, fill_w, track_h, tr, BLACK)
    if not dragging then
        local ring = 1
        local ky = cy - math.floor(knob / 2)
        local kr = math.floor(knob / 2)
        paintRoundRect(bb, track_x + kx, ky, knob, knob, kr, Blitbuffer.COLOR_DARK_GRAY)
        paintRoundRect(bb, track_x + kx + ring, ky + ring, knob - 2 * ring, knob - 2 * ring, math.max(1, kr - ring), Blitbuffer.COLOR_WHITE)
    end

    local half_gap = math.floor(gap / 2)
    self._light_hit.minus = Geom:new{ x = x, y = ty0, w = label_w + half_gap, h = touch_h }
    self._light_hit.plus  = Geom:new{ x = plus_x - half_gap, y = ty0, w = label_w + half_gap, h = touch_h }
    self._light_hit.track = Geom:new{ x = track_x, y = ty0, w = track_w, h = touch_h }
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

function ScrubberMenu:closeEntireWidget(suppress_dirty)
    if suppress_dirty then
        self._suppress_close_dirty = true
    end
    local scrubber = self.scrubber_ui
    UIManager:close(self)
    if scrubber then
        if scrubber._closeStay then
            pcall(function() scrubber:_closeStay() end)
        else
            pcall(function() UIManager:close(scrubber) end)
        end
    elseif not suppress_dirty then
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

-- Cierra el menú (y el scrubber) y abre el buscador de texto del libro de KOReader
-- (el mismo de Menú > Búsqueda > "Book text search"), para encontrar una palabra o nombre puntual.
function ScrubberMenu:openBookSearch()
    local ui = self.ui or (self.scrubber_ui and self.scrubber_ui.ui)
    self:closeEntireWidget(true)
    if not ui then return end
    local opened = false
    local search = ui.search
    if search and type(search.onShowFulltextSearchInput) == "function" then
        opened = pcall(function() search:onShowFulltextSearchInput() end)
    end
    if not opened then
        pcall(function() ui:handleEvent(Event:new("ShowFulltextSearchInput")) end)
    end
    UIManager:setDirty("all", "full")
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

-- ==========================================
-- SELECTOR PROPIO DE UNA OPCIÓN (pestaña Aa)
-- Tocar una opción abre este selector dentro de la misma tarjeta: se elige el valor (lista, grilla con íconos,
-- número con slider / flechas / valores típicos, o dos números a la vez) y NADA se aplica hasta tocar "Apply".
-- Así un PDF pesado se vuelve a dibujar una sola vez, en vez de una por cada toque.
-- ==========================================

-- Ancho de un texto en un tamaño dado
local function pickTextWidth(text, pt, bold)
    local tw = TextWidget:new{ text = text, face = Font:getFace("cfont", scaleText(pt)), bold = bold }
    local w = tw:getSize().w
    tw:free()
    return w
end

-- Texto que se achica hasta entrar en max_w (sin bajar de min_pt). Devuelve el widget y si entró entero.
local function fitTextWidget(text, start_pt, min_pt, max_w, bold, fgcolor)
    for pt = start_pt, min_pt, -1 do
        local tw = TextWidget:new{ text = text, face = Font:getFace("cfont", scaleText(pt)), bold = bold, fgcolor = fgcolor }
        if tw:getSize().w <= max_w then return tw, true end
        tw:free()
    end
    local tw = TextWidget:new{
        text = text, face = Font:getFace("cfont", scaleText(min_pt)), bold = bold, fgcolor = fgcolor,
        max_width = max_w, truncate_with_ellipsis = true,
    }
    return tw, false
end

-- Parte un texto en hasta max_lines renglones del ancho dado (con "…" si no entra todo)
local function wrapLines(text, pt, max_w, max_lines)
    local function width(str) return pickTextWidth(str, pt, false) end
    local words = {}
    for wd in tostring(text):gmatch("%S+") do words[#words + 1] = wd end
    local lines, cur, i = {}, "", 1
    while i <= #words do
        local try = (cur == "") and words[i] or (cur .. " " .. words[i])
        if cur == "" or width(try) <= max_w then
            cur = try
            i = i + 1
        else
            lines[#lines + 1] = cur
            cur = ""
            if #lines == max_lines then break end
        end
    end
    local leftover = i <= #words
    if cur ~= "" and #lines < max_lines then lines[#lines + 1] = cur end
    if leftover and #lines > 0 then
        local last = lines[#lines]
        while last ~= "" and width(last .. "…") > max_w do
            local trimmed = last:gsub("%s*%S+$", "")
            if trimmed == last then break end
            last = trimmed
        end
        lines[#lines] = last .. "…"
    end
    return lines
end

function ScrubberMenu:_pickerGeneralHelp(spec)
    local H = {
        page_margin = _("Space around the page after crop and zoom."),
        auto_straighten = _("Straightens tilted scans, up to this angle."),
        contrast = _("Darker text and a cleaner background."),
        font_gamma = _("Darker text and a cleaner background."),
        saturation = _("Lower fades the colors, higher intensifies them."),
        white_threshold = _("Lighter pixels become white. Lower = whiter page."),
        zoom_factor = _("Fixed zoom used when Fit zoom to is manual."),
        zoom_range_number = _("Columns or rows the page is split into."),
        zoom_direction = _("Order in which the view moves across the page."),
        trim_page = _("Cuts the blank margins of the page."),
        zoom_mode_genus = _("How the page is fitted to the screen."),
        zoom_mode_type = _("Which side of the page is fitted."),
        font_size = _("Size of the book text."),
        line_spacing = _("Space between the lines of text."),
        h_page_margins = _("Space at the left and right of the page."),
        t_page_margin = _("Space above and below the text."),
        word_spacing = _("Width of the spaces between words."),
        word_expansion = _("How much words may stretch to fill a line."),
        render_dpi = _("Scales CSS units and images. 96 = 1:1."),
        block_rendering_mode = _("How the book layout is rendered."),
        font_base_weight = _("Makes the text lighter or bolder."),
        font_hinting = _("Sharper or smoother font outlines."),
        font_kerning = _("Adjusts the space between letter pairs."),
        embedded_css = _("Uses the publisher's own styles included in the book."),
        embedded_fonts = _("Uses the fonts included in the book instead of yours."),
        smooth_scaling = _("How images are scaled: fast or best quality."),
        text_wrap = _("Reflows the page text to fit the screen, like an ebook."),
        background_cleanup = _("Black and white only: better contrast and faster. Good for scanned PDFs."),
        page_opt = _("Tries to remove watermarks and stains from the page."),
        hw_dithering = _("Dithering smooths grays and gradients on e-ink."),
        sw_dithering = _("Dithering smooths grays and gradients on e-ink."),
        quality = _("Quality of the text and images when reflowing. Higher is sharper but slower."),
        rotation_mode = _("Screen orientation."),
    }
    local txt = H[spec.name]
    if txt then return txt end
    if spec.opt and type(spec.opt.help_text) == "string" then return spec.opt.help_text end
    return ""
end

-- Explicación del valor que está elegido en este momento (si la opción lo tiene)
function ScrubberMenu:_pickerValueHelp(spec, value)
    local n = spec.name
    local t
    if n == "trim_page" then
        t = {
            [3] = _("Keeps the original margins."),
            [1] = _("Finds the content and trims the blank margins."),
            [2] = _("Auto-detects inside an area you mark once."),
            [0] = _("You mark the area."),
        }
    elseif n == "zoom_mode_genus" then
        t = {
            [4] = _("Fits the whole page."),
            [3] = _("Fits the content, ignoring blank margins."),
            [2] = _("Shows one column at a time."),
            [1] = _("Shows one row at a time."),
            [0] = _("Uses the fixed zoom factor."),
        }
    elseif n == "block_rendering_mode" then
        t = {
            [0] = _("Original CR3 block rendering."),
            [1] = _("Flat layout with accurate page breaks."),
            [2] = _("Adds floats, avoids overflows."),
            [3] = _("Like a web browser; may overflow."),
        }
    elseif n == "font_hinting" then
        t = {
            [0] = _("No hinting."),
            [1] = _("Uses the hinting of the font."),
            [2] = _("Automatic hinting."),
        }
    elseif n == "font_kerning" then
        t = {
            [0] = _("No kerning."),
            [1] = _("Fast kerning."),
            [2] = _("Good quality kerning."),
            [3] = _("Best quality kerning."),
        }
    elseif n == "text_wrap" then
        t = {
            [0] = _("The page keeps its original layout."),
            [1] = _("The text is reflowed to fit the screen."),
        }
    elseif n == "background_cleanup" then
        t = {
            [0] = _("Keeps the original colors and grays."),
            [1] = _("Black and white only. Faster, more contrast."),
        }
    elseif n == "embedded_css" then
        t = {
            [0] = _("Ignores the book's styles; yours are used."),
            [1] = _("Keeps the look the publisher designed."),
        }
    elseif n == "embedded_fonts" then
        t = {
            [0] = _("Uses your font for all the text."),
            [1] = _("Uses the fonts the book brings."),
        }
    elseif n == "smooth_scaling" then
        t = {
            [0] = _("Fast: quick, but images look rougher."),
            [1] = _("Best: slower, smoother and more accurate."),
        }
    elseif n == "quality" then
        t = {
            [0.5] = _("Faster, but less sharp."),
            [1.0] = _("Balanced."),
            [1.5] = _("Sharpest, but the slowest."),
        }
    elseif n == "page_opt" then
        t = {
            [0] = _("Keeps the original page without removing watermarks."),
            [1] = _("Removes faint watermarks and background marks from the page."),
        }
    elseif n == "hw_dithering" or n == "sw_dithering" then
        t = {
            [0] = _("Off."),
            [1] = _("On."),
        }
    elseif n == "zoom_mode_type" then
        t = {
            [2] = _("Whole page visible."),
            [1] = _("Fits the width; scroll vertically."),
            [0] = _("Fits the height; scroll horizontally."),
        }
    end
    return t and t[value] or nil
end

-- Opciones con valores "con nombre" (Small / Medium / Large, None / Some / More...) que además tienen barra(s):
-- esos botones se ofrecen PRIMERO (lo más simple) y el ⋮ del encabezado los cambia por la(s) barra(s).
-- Si la opción no tiene nombres (o son números sueltos), el selector queda como antes.
function ScrubberMenu:_pickerPresets(spec, name, opt, values)
    if not opt or name == "font_size" then return end
    if spec.kind ~= "numeric" and spec.kind ~= "dual" then return end
    local labels = (type(opt.toggle) == "table" and opt.toggle)
        or (type(opt.labels) == "table" and opt.labels)
        or (type(opt.item_text) == "table" and opt.item_text)
    if #values == 0 then
        if name == "word_spacing" then
            values = { { 75, 50 }, { 100, 90 }, { 125, 115 } }
        elseif name == "word_expansion" then
            values = { 0, 15, 30 }
        end
    end
    if not labels then
        if name == "word_spacing" then
            labels = { _("Small"), _("Medium"), _("Large") }
        elseif name == "word_expansion" then
            labels = { _("None"), _("Some"), _("More") }
        end
    end
    if not labels or #values < 2 or #values > 5 then return end
    local presets, wordy = {}, 0
    for i, v in ipairs(values) do
        local l = labels[i]
        if l == nil then return end
        if spec.kind == "numeric" and type(v) ~= "number" then return end
        if spec.kind == "dual" and not (type(v) == "table" and tonumber(v[1]) and tonumber(v[2])) then return end
        l = tostring(l)
        if tonumber(l) == nil then wordy = wordy + 1 end
        presets[#presets + 1] = { value = deepCopy(v), label = l }
    end
    -- Solo cuentan los nombres de verdad (no una fila de números como "48 · 96 · 167")
    if wordy * 2 <= #presets then return end
    spec.presets = presets
    spec.mode = "presets"
    spec.chips = {}   -- los valores típicos ya son los botones: no se repiten debajo de la barra
end

local SWITCH_OPTS = {
    text_wrap = true, embedded_css = true, embedded_fonts = true, smooth_scaling = true,
    background_cleanup = true, page_opt = true, hw_dithering = true, sw_dithering = true,
}

-- Arma la definición del selector de una opción. Devuelve nil si no se puede (sin valores...)
function ScrubberMenu:_pickerSpec(name, label, names, mirror)
    local map = self:_cfgOptions()
    local opt = map[name]
    local conf = self:_conf()
    local rolling = self:getDocKind() == "rolling"
    local params = (opt and opt.more_options_param) or {}
    local values = (opt and opt.values) or {}
    local spec = { name = name, label = label, names = names or { name }, mirror = mirror, opt = opt }

    -- ---------- Dos valores a la vez (márgenes izquierdo / derecho, superior / inferior, espacio entre palabras) ----------
    if opt and opt.more_options and params.left_min and conf then
        local cur
        if params.names then
            cur = { conf[params.names[1]], conf[params.names[2]] }
        else
            cur = conf[name]
        end
        if type(cur) ~= "table" or not (tonumber(cur[1]) and tonumber(cur[2])) then return nil end
        spec.kind = "dual"
        spec.dual_names = params.names
        spec.unit = params.unit and tostring(params.unit) or ""
        spec.fmt = fmtCleanNum
        spec.fields = {
            { label = params.left_text or _("Left"), lo = params.left_min, hi = params.left_max,
              step = params.left_step or 1, hold = params.left_hold_step or 5 },
            { label = params.right_text or _("Right"), lo = params.right_min or params.left_min,
              hi = params.right_max or params.left_max,
              step = params.right_step or 1, hold = params.right_hold_step or 5 },
        }
        spec.original = { cur[1], cur[2] }
        spec.pending = {
            math.max(spec.fields[1].lo, math.min(spec.fields[1].hi, cur[1])),
            math.max(spec.fields[2].lo, math.min(spec.fields[2].hi, cur[2])),
        }
        if params.names then
            spec.default_orig = { (map[params.names[1]] or {}).default_value, (map[params.names[2]] or {}).default_value }
        else
            spec.default_orig = opt.default_value
        end
        self:_pickerPresets(spec, name, opt, values)
        spec.help = self:_pickerGeneralHelp(spec)
        return spec
    end

    -- ---------- Un solo valor ----------
    local cur
    if rolling and name == "font_size" then
        cur = self:getBookFontSize()
    elseif rolling and name == "line_spacing" then
        cur = self:_currentFor("line_spacing")
    elseif opt and opt.current_func then
        local okc, cv = pcall(opt.current_func)
        cur = okc and cv or nil
    else
        cur = conf and conf[name]
    end
    if cur == nil or type(cur) == "table" then return nil end
    spec.original = deepCopy(cur)
    spec.pending = deepCopy(cur)
    spec.default_orig = opt and opt.default_value

    local special = rolling and (name == "font_size" or name == "line_spacing")
    local numeric = type(cur) == "number" and (special or (opt and opt.more_options
        and (params.value_min or params.value_table or #values >= 2)))
    if numeric then
        spec.kind = "numeric"
        if rolling and name == "font_size" then
            spec.lo, spec.hi, spec.step, spec.hold_step, spec.unit = 12, 100, 1, 4, " pt"
            spec.chips = { 12, 14, 16, 18, 20, 24, 28, 32 }
            spec.fmt = function(v) return string.format("%d", math.floor(v + 0.5)) end
        elseif rolling and name == "line_spacing" then
            spec.lo = params.value_min or 50
            spec.hi = params.value_max or 200
            spec.step, spec.hold_step, spec.unit = 1, params.value_hold_step or 5, "%"
            spec.chips = { 80, 90, 100, 110, 120, 140, 160, 200 }
            spec.fmt = function(v) return string.format("%d", math.floor(v + 0.5)) end
        elseif params.value_table then
            -- El valor guardado es un ÍNDICE de la tabla (p. ej. el contraste de un EPUB); se muestra lo que dice la tabla
            local vt = params.value_table
            local shift = params.value_table_shift or 0
            spec.lo, spec.hi = 1 - shift, #vt - shift
            spec.step = 1
            spec.hold_step = params.value_hold_step or 5
            spec.unit = ""
            spec.fmt = function(v)
                local t = vt[math.floor(v + 0.5) + shift]
                if t ~= nil then return tostring(t) end
                return fmtCleanNum(v)
            end
            spec.chip_fmt = spec.fmt
            local chips = {}
            for _i, v in ipairs(values) do
                if type(v) == "number" then chips[#chips + 1] = v end
            end
            spec.chips = chips
        else
            local lo, hi
            for _i, v in ipairs(values) do
                local sv = scalarOf(v)
                if sv then
                    lo = (lo == nil or sv < lo) and sv or lo
                    hi = (hi == nil or sv > hi) and sv or hi
                end
            end
            spec.lo = params.value_min or lo or 0
            spec.hi = params.value_max or hi or 100
            if spec.hi < spec.lo then spec.lo, spec.hi = spec.hi, spec.lo end
            spec.step = params.value_step or 1
            spec.hold_step = params.value_hold_step or (spec.step * 5)
            spec.unit = params.unit and tostring(params.unit) or ""
            local chips = {}
            for _i, v in ipairs(values) do
                if type(v) == "number" then chips[#chips + 1] = v end
            end
            spec.chips = chips
            if opt and opt.show_true_value_func then
                local f = opt.show_true_value_func
                local prec = params.precision
                spec.unit = ""   -- esa función ya agrega la unidad
                spec.fmt = function(v)
                    local ok, t = pcall(f, v)
                    if ok and t ~= nil then return tostring(t) end
                    if prec then return string.format(prec, v) end
                    return fmtCleanNum(v)
                end
            elseif params.precision then
                local prec = params.precision
                spec.fmt = function(v) return string.format(prec, v) end
            else
                spec.fmt = fmtCleanNum
            end
            -- Los valores típicos usan los nombres cortos de KOReader (off, 48, 96¹’¹, 167...) si los tiene
            if opt and type(opt.toggle) == "table" and #opt.toggle == #values then
                local labels = {}
                for i, v in ipairs(values) do labels[tostring(v)] = opt.toggle[i] end
                spec.chip_fmt = function(v)
                    local l = labels[tostring(v)]
                    if l ~= nil then return tostring(l) end
                    return fmtCleanNum(v)
                end
            end
        end
        -- Hasta 8 valores típicos (6 en contrast y saturation para evitar botones apretados)
        local max_chips = (name == "contrast" or name == "saturation" or name == "font_gamma") and 6 or 8
        if spec.chips and #spec.chips > max_chips then
            local sampled = {}
            for i = 1, max_chips do
                sampled[i] = spec.chips[math.floor((i - 1) * (#spec.chips - 1) / (max_chips - 1) + 1.5)]
            end
            spec.chips = sampled
        end
        if spec.hi <= spec.lo then return nil end
        spec.pending = math.max(spec.lo, math.min(spec.hi, spec.pending))
        self:_pickerPresets(spec, name, opt, values)
        spec.help = self:_pickerGeneralHelp(spec)
        return spec
    end

    -- ---------- Elegir una entre varias ----------
    if #values == 0 then
        if name == "word_expansion" then
            values = { 0, 15, 30 }
        else
            return nil
        end
    end
    spec.items = {}
    local has_icons = false
    local icon_list = opt and opt.item_icons
    if opt and opt.item_icons_func then
        local okf, res = pcall(opt.item_icons_func)
        if okf and type(res) == "table" then icon_list = res end
    end
    for i, v in ipairs(values) do
        local icon = icon_list and icon_list[i]
        if icon then has_icons = true end
        local long = opt and opt.labels and opt.labels[i]
        local short = self:_optValueText(name, v)
        if SWITCH_OPTS[name] and type(short) == "string" then
            short = short:gsub("^%l", string.upper)
        end
        spec.items[#spec.items + 1] = {
            value = deepCopy(v), label = short, icon = icon,
            long = (type(long) == "string" and long ~= short) and long or nil,
        }
    end
    spec.kind = (has_icons or #spec.items > 5) and "grid" or "list"
    spec.help = self:_pickerGeneralHelp(spec)
    return spec
end

function ScrubberMenu:_openPicker(name, label, back_tab, names, mirror)
    local spec = self:_pickerSpec(name, label, names, mirror)
    if not spec then
        -- Sin selector propio: se usa el menú nativo de KOReader
        return self:_showNativeMore(name, label, mirror)
    end
    spec.back = back_tab or self.active_tab
    self.picker = spec
    self._pick_drag = false
    self.active_tab = "opt_picker"
    self:refreshMenu()
    return true
end

function ScrubberMenu:_pickerText(spec, v)
    if spec.kind == "numeric" then
        return spec.fmt(v) .. (spec.unit or "")
    elseif spec.kind == "dual" then
        local u = spec.unit or ""
        return spec.fmt(v[1]) .. u .. " / " .. spec.fmt(v[2]) .. u
    end
    for _i, it in ipairs(spec.items or {}) do
        if valuesEqual(it.value, v) then return it.label end
    end
    return tostring(v)
end

-- f: cualquier tabla con lo / hi / step (el selector numérico o uno de los dos campos del doble)
function ScrubberMenu:_pickerQuant(f, v)
    local step = f.step or 1
    local n = math.floor((v - f.lo) / step + 0.5)
    local q = math.max(f.lo, math.min(f.hi, f.lo + n * step))
    return tonumber(string.format("%.6f", q))
end

-- Cambia el valor elegido (todavía no se aplica al libro) y repinta solo la tarjeta
function ScrubberMenu:_pickerSetPending(v, fast)
    local spec = self.picker
    if not spec then return end
    if valuesEqual(spec.pending, v) then return end
    spec.pending = deepCopy(v)
    local region = self._pick and self._pick.region or expandRect(self.popup_rect, scale(8))
    UIManager:setDirty(self, fast and "fast" or "ui", region)
end

-- Cambia uno de los dos valores del selector doble
function ScrubberMenu:_pickerSetField(k, v, fast)
    local spec = self.picker
    if not (spec and spec.kind == "dual") then return end
    local np = { spec.pending[1], spec.pending[2] }
    np[k] = v
    self:_pickerSetPending(np, fast)
end

-- ¿Sobre qué riel está el dedo? (true en el numérico, 1 / 2 en el doble)
function ScrubberMenu:_pickerTrackAt(pos)
    local spec, h = self.picker, self._pick
    if not (spec and h) then return nil end
    if spec.kind == "numeric" then
        if h.track and pos:intersectWith(h.track) then return true end
    elseif spec.kind == "dual" then
        for k, fh in ipairs(h.fields or {}) do
            if pos:intersectWith(fh.track) then return k end
        end
    end
    return nil
end

function ScrubberMenu:_pickerDragTo(x)
    local spec, h = self.picker, self._pick
    if not (spec and h) then return end
    if spec.kind == "numeric" and h.track_w then
        local frac = math.max(0, math.min(1, (x - h.track_x) / h.track_w))
        self:_pickerSetPending(self:_pickerQuant(spec, spec.lo + frac * (spec.hi - spec.lo)), true)
    elseif spec.kind == "dual" and type(self._pick_drag) == "number" then
        local k = self._pick_drag
        local fh, f = h.fields[k], spec.fields[k]
        if not (fh and f) then return end
        local frac = math.max(0, math.min(1, (x - fh.track_x) / fh.track_w))
        self:_pickerSetField(k, self:_pickerQuant(f, f.lo + frac * (f.hi - f.lo)), true)
    end
end

function ScrubberMenu:_pickerPan(ges)
    if not self._pick_drag then
        if ges.direction == "north" or ges.direction == "south" then return false end
        local t = self:_pickerTrackAt(ges.pos)
        if not t then return false end
        self._pick_drag = t
    end
    self:_pickerDragTo(ges.pos.x)
    return true
end

function ScrubberMenu:_endPickDrag()
    if not self._pick_drag then return false end
    self._pick_drag = false
    local region = self._pick and self._pick.region or expandRect(self.popup_rect, scale(8))
    UIManager:setDirty(self, "ui", region)
    return true
end

-- ¿El valor elegido es el que está guardado como predeterminado?
function ScrubberMenu:_pickerDefaultIsSet(spec)
    if not G_reader_settings then return false end
    if spec.kind == "dual" and spec.dual_names then
        for i, n in ipairs(spec.dual_names) do
            local d = G_reader_settings:readSetting(self:_defaultKey(n))
            if d == nil or not valuesEqual(d, spec.pending[i]) then return false end
        end
        return true
    end
    local d = G_reader_settings:readSetting(self:_defaultKey(spec.name))
    return d ~= nil and valuesEqual(d, spec.pending)
end

-- Estrella: guarda (o saca) el valor elegido como predeterminado para los libros nuevos
function ScrubberMenu:_pickerToggleDefault()
    local spec = self.picker
    if not (spec and G_reader_settings) then return end
    local was_set = self:_pickerDefaultIsSet(spec)
    if spec.kind == "dual" and spec.dual_names then
        for i, n in ipairs(spec.dual_names) do
            if was_set then
                G_reader_settings:delSetting(self:_defaultKey(n))
            else
                G_reader_settings:saveSetting(self:_defaultKey(n), spec.pending[i])
            end
        end
    else
        for _i, n in ipairs({ spec.name }) do
            if was_set then
                G_reader_settings:delSetting(self:_defaultKey(n))
            else
                G_reader_settings:saveSetting(self:_defaultKey(n), deepCopy(spec.pending))
            end
        end
    end
    if G_reader_settings.flush then G_reader_settings:flush() end
    UIManager:setDirty(self, "ui", self._pick and self._pick.region or expandRect(self.popup_rect, scale(8)))
end

-- Valor predeterminado de la opción (el guardado, o el de fábrica de KOReader)
function ScrubberMenu:_pickerDefaultValue(spec)
    if spec.kind == "dual" and spec.dual_names then
        local out = {}
        for i, n in ipairs(spec.dual_names) do
            local v = G_reader_settings and G_reader_settings:readSetting(self:_defaultKey(n))
            if v == nil and type(spec.default_orig) == "table" then v = spec.default_orig[i] end
            if v == nil then return nil end
            out[i] = v
        end
        return out
    end
    local v = G_reader_settings and G_reader_settings:readSetting(self:_defaultKey(spec.name))
    if v == nil then v = spec.default_orig end
    return deepCopy(v)
end

-- Botón del medio: lleva el valor elegido al predeterminado (todavía sin aplicar)
function ScrubberMenu:_pickerUseDefault()
    local spec = self.picker
    if not spec then return end
    local d = self:_pickerDefaultValue(spec)
    if d == nil then return end
    if spec.kind == "numeric" then
        if type(d) ~= "number" then return end
        d = math.max(spec.lo, math.min(spec.hi, d))
    elseif spec.kind == "dual" then
        if type(d) ~= "table" or not (tonumber(d[1]) and tonumber(d[2])) then return end
        d = {
            math.max(spec.fields[1].lo, math.min(spec.fields[1].hi, d[1])),
            math.max(spec.fields[2].lo, math.min(spec.fields[2].hi, d[2])),
        }
    end
    self:_pickerSetPending(d)
end

-- Vuelve a la vista anterior sin aplicar nada
function ScrubberMenu:_pickerClose()
    local spec = self.picker
    self.picker = nil
    self._pick = nil
    self._pick_drag = false
    self.active_tab = (spec and spec.back) or "typo"
    self:refreshMenu()
end

-- Esconde el menú mientras KOReader muestra su pantalla de recorte manual y lo devuelve al confirmar o cancelar
function ScrubberMenu:_hideForCrop()
    local ui = self.ui
    local cropping = ui and ui.cropping
    if not cropping or self._crop_hidden then return end
    local menu = self
    self._crop_hidden = true
    local own_c = rawget(cropping, "onConfirmPageCrop")
    local own_x = rawget(cropping, "onCancelPageCrop")
    local class_c = cropping.onConfirmPageCrop
    local class_x = cropping.onCancelPageCrop
    local finished = false
    local function done()
        if finished then return end
        finished = true
        cropping.onConfirmPageCrop = own_c
        cropping.onCancelPageCrop = own_x
        menu:_restoreAfterCrop()
    end
    cropping.onConfirmPageCrop = function(c, ...)
        local res = class_c(c, ...)
        done()
        return res
    end
    cropping.onCancelPageCrop = function(c, ...)
        local res = class_x(c, ...)
        done()
        return res
    end
    -- Red de seguridad: si KOReader no llegó a mostrar la pantalla de recorte, el menú vuelve solo
    UIManager:scheduleIn(1.2, function()
        if finished or menu._closed or not menu._crop_hidden then return end
        local dlg = cropping.crop_dialog
        local shown = false
        if dlg then
            local ok, res = pcall(function() return UIManager:isWidgetShown(dlg) end)
            shown = ok and res or false
        end
        if not shown then done() end
    end)
end

function ScrubberMenu:_restoreAfterCrop()
    self._crop_hidden = false
    self._typo_changed = true
    if self._closed then return end
    self:refreshMenu()
end

-- Aplica el valor elegido al libro (una sola vez)
function ScrubberMenu:_applyPickerValue(spec, v)
    local ui = self.ui
    local name = spec.name
    local rolling = self:getDocKind() == "rolling"
    if name == "rotation_mode" then
        -- Rotar cambia el tamaño de pantalla: se cierra el menú y se rota como hace el botón de rotar
        local same = false
        pcall(function() same = (Screen:getRotationMode() == v) end)
        if not same then self:rotateScreenTo(v) end
        return
    end
    if rolling and name == "font_size" then
        pcall(function() ui:handleEvent(Event:new("SetFontSize", v)) end)
        self._typo_changed = true
    elseif rolling and name == "line_spacing" then
        pcall(function() ui:handleEvent(Event:new("SetLineSpace", v)) end)
        self._typo_changed = true
    else
        -- Recorte manual / semi-automático: KOReader abre su pantalla para marcar el área
        if name == "trim_page" and (v == 0 or v == 2) then self:_hideForCrop() end
        self:_applyConfigOption(name, v)
        if spec.mirror and not self:_marginsSynced() then
            self:_applyConfigOption(spec.mirror, v)
        end
    end
end

function ScrubberMenu:_pickerCommit()
    local spec = self.picker
    if not spec then return end
    local back = spec.back or "typo"
    self.picker = nil
    self._pick = nil
    self._pick_drag = false
    if not valuesEqual(spec.pending, spec.original) then
        self:_applyPickerValue(spec, spec.pending)
    end
    self.active_tab = back
    if not self._closed then self:refreshMenu() end
end

-- Mantener apretadas las flechas mueve de a bastante; sobre un riel empieza el arrastre
function ScrubberMenu:_pickerHold(pos)
    local spec, h = self.picker, self._pick
    if not (spec and h) then return false end
    local t = self:_pickerTrackAt(pos)
    if t then
        self._pick_drag = t
        self:_pickerDragTo(pos.x)
        return true
    end
    if spec.kind == "numeric" then
        local hs = spec.hold_step or spec.step
        if h.minus and pos:intersectWith(h.minus) then
            self:_pickerSetPending(self:_pickerQuant(spec, spec.pending - hs))
            return true
        elseif h.plus and pos:intersectWith(h.plus) then
            self:_pickerSetPending(self:_pickerQuant(spec, spec.pending + hs))
            return true
        end
    elseif spec.kind == "dual" then
        for k, fh in ipairs(h.fields or {}) do
            local f = spec.fields[k]
            if pos:intersectWith(fh.minus) then
                self:_pickerSetField(k, self:_pickerQuant(f, spec.pending[k] - f.hold))
                return true
            elseif pos:intersectWith(fh.plus) then
                self:_pickerSetField(k, self:_pickerQuant(f, spec.pending[k] + f.hold))
                return true
            end
        end
    end
    return false
end

function ScrubberMenu:_pickerTap(pos)
    local spec, h = self.picker, self._pick
    if not (spec and h) then return end

    -- Estrella: guardar / sacar como predeterminado
    if h.star and pos:intersectWith(h.star) then
        self:_pickerToggleDefault()
        return
    end

    -- ⋮: cambia entre los botones con nombre y la(s) barra(s)
    if h.mode_btn and pos:intersectWith(h.mode_btn) then
        self:_flashStepBtn("pick_mode", h.mode_btn, function()
            spec.mode = (spec.mode == "bars") and "presets" or "bars"
            UIManager:setDirty(self, "ui", h.region)
        end)
        return
    end

    -- Botones inferiores (Cancelar / Default / Aplicar)
    if h.btn_cancel and pos:intersectWith(h.btn_cancel) then
        self:_flashStepBtn("pick_cancel", h.btn_cancel, function() end)
        UIManager:scheduleIn(0.05, function()
            if self._closed or self.active_tab ~= "opt_picker" then return end
            self:_pickerClose()
        end)
        return
    end
    if h.btn_def and pos:intersectWith(h.btn_def) then
        self:_flashStepBtn("pick_def", h.btn_def, function() self:_pickerUseDefault() end)
        return
    end
    if h.btn_apply and pos:intersectWith(h.btn_apply) then
        -- Se ve el botón presionado un instante y recién después se aplica (en un PDF pesado puede tardar)
        self._pressed_btn = "pick_apply"
        self._flash_busy = true
        UIManager:setDirty(self, "ui", expandRect(h.btn_apply, scale(4)))
        UIManager:scheduleIn(0.06, function()
            self._pressed_btn = nil
            self._flash_busy = false
            if self._closed then return end
            self:_pickerCommit()
        end)
        return
    end

    if spec.presets and spec.mode ~= "bars" then
        for _i, p in ipairs(h.presets) do
            if pos:intersectWith(p.dimen) then
                self:_pickerSetPending(p.value)
                return
            end
        end
        return
    end

    if spec.kind == "numeric" then
        if h.minus and pos:intersectWith(h.minus) then
            self:_flashStepBtn("pick_minus", h.minus, function()
                self:_pickerSetPending(self:_pickerQuant(spec, spec.pending - spec.step))
            end)
        elseif h.plus and pos:intersectWith(h.plus) then
            self:_flashStepBtn("pick_plus", h.plus, function()
                self:_pickerSetPending(self:_pickerQuant(spec, spec.pending + spec.step))
            end)
        elseif h.track and pos:intersectWith(h.track) then
            local frac = math.max(0, math.min(1, (pos.x - h.track_x) / h.track_w))
            self:_pickerSetPending(self:_pickerQuant(spec, spec.lo + frac * (spec.hi - spec.lo)))
        else
            for _i, c in ipairs(h.chips) do
                if pos:intersectWith(c.dimen) then
                    self:_pickerSetPending(c.value)
                    return
                end
            end
        end
    elseif spec.kind == "dual" then
        for k, fh in ipairs(h.fields or {}) do
            local f = spec.fields[k]
            if pos:intersectWith(fh.minus) then
                self:_flashStepBtn("pick_minus" .. k, fh.minus, function()
                    self:_pickerSetField(k, self:_pickerQuant(f, spec.pending[k] - f.step))
                end)
                return
            elseif pos:intersectWith(fh.plus) then
                self:_flashStepBtn("pick_plus" .. k, fh.plus, function()
                    self:_pickerSetField(k, self:_pickerQuant(f, spec.pending[k] + f.step))
                end)
                return
            elseif pos:intersectWith(fh.track) then
                local frac = math.max(0, math.min(1, (pos.x - fh.track_x) / fh.track_w))
                self:_pickerSetField(k, self:_pickerQuant(f, f.lo + frac * (f.hi - f.lo)))
                return
            end
        end
    else
        for _i, t in ipairs(h.tiles) do
            if pos:intersectWith(t.dimen) then
                if spec.kind == "list" and t.index then
                    self:_flashStepBtn("pick_tile_" .. t.index, t.dimen, function()
                        self:_pickerSetPending(t.value)
                    end)
                else
                    self:_pickerSetPending(t.value)
                end
                return
            end
        end
    end
end

function ScrubberMenu:_paintPicker(bb, r, border, inner_w, content_top, content_h)
    local spec = self.picker
    self._pick = nil
    if not spec then return end
    local BLACK, GRAY, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_DARK_GRAY, Blitbuffer.COLOR_WHITE
    local pad = scale(12)
    local x0 = r.x + border + pad
    local w = inner_w - pad * 2
    local hit = { tiles = {}, chips = {}, fields = {}, presets = {} }
    self._pick = hit
    hit.region = Geom:new{ x = r.x + border, y = content_top, w = inner_w, h = content_h }

    -- Explicación: la del valor elegido si la hay; si no, la general de la opción (máx. 2 renglones chicos)
    local help = spec.help or ""
    local selected_item
    if spec.items then
        for _i, it in ipairs(spec.items) do
            if valuesEqual(it.value, spec.pending) then
                selected_item = it
                local vh = self:_pickerValueHelp(spec, it.value)
                if vh then help = vh end
                break
            end
        end
    end
    local has_changes = not valuesEqual(spec.pending, spec.original)

    -- Íconos a la derecha del encabezado del contenido: ⋮ (modo) y estrella (predeterminado)
    local help_top = content_top + scale(6)
    local star_icon = self:_pickerDefaultIsSet(spec) and self.icon_star_on or self.icon_star
    local mode_icon = spec.presets and self.icon_more_sm or nil
    local right_x = x0 + w
    local right_icons_w = 0
    local min_icon_h = 0

    if mode_icon then
        local misz = mode_icon:getSize()
        min_icon_h = math.max(min_icon_h, misz.h)
        local mx = right_x - misz.w
        local my = help_top
        local mpressed = (self._pressed_btn == "pick_mode")
        if mpressed then
            local box = misz.h + scale(6)
            paintRoundRect(bb, mx + math.floor((misz.w - box) / 2), my + math.floor((misz.h - box) / 2), box, box, scale(6), BLACK)
        end
        paintIconOn(bb, mode_icon, mx, my, mpressed)
        hit.mode_btn = Geom:new{
            x = mx - scale(8),
            y = help_top - scale(2),
            w = misz.w + scale(16),
            h = misz.h + scale(8),
        }
        right_x = mx - scale(6)
        right_icons_w = right_icons_w + misz.w + scale(6)
    end

    if star_icon then
        local ssz = star_icon:getSize()
        min_icon_h = math.max(min_icon_h, ssz.h)
        local sx = right_x - ssz.w
        local sy = help_top + (mode_icon and math.floor((mode_icon:getSize().h - ssz.h) / 2) or 0)
        star_icon:paintTo(bb, sx, sy)
        hit.star = Geom:new{
            x = sx - scale(8),
            y = help_top - scale(2),
            w = ssz.w + scale(14),
            h = ssz.h + scale(8),
        }
        right_icons_w = right_icons_w + ssz.w + scale(6)
    end

    -- Título del submenú en línea antes de la explicación ("Título: explicación")
    local help_w = math.max(scale(60), w - right_icons_w)
    local help_pt = 9
    local prefix_str = (help ~= "") and (spec.label .. ": ") or spec.label
    local tw_pref = fitTextWidget(prefix_str, help_pt, 7, help_w, true, BLACK)
    local pref_sz = tw_pref:getSize()
    local line1_rem_w = math.max(0, help_w - pref_sz.w)

    local probe = TextWidget:new{ text = "Ag", face = Font:getFace("cfont", scaleText(help_pt)) }
    local help_lh = math.max(probe:getSize().h, pref_sz.h)
    probe:free()
    local help_step = math.floor(help_lh * 0.85)

    local line_widths = { line1_rem_w, w, w, w }

    local function wrapPrefixedHelp(text, widths, pt)
        if not text or text == "" then return {} end
        local function width(str) return pickTextWidth(str, pt, false) end
        local words = {}
        for wd in tostring(text):gmatch("%S+") do words[#words + 1] = wd end
        if #words == 0 then return {} end

        local lines = {}
        local i = 1
        for idx = 1, #widths do
            local max_w = widths[idx]
            local cur = ""
            while i <= #words do
                local try = (cur == "") and words[i] or (cur .. " " .. words[i])
                if (idx > 1 and cur == "") or width(try) <= max_w then
                    cur = try
                    i = i + 1
                else
                    break
                end
            end
            lines[idx] = cur
            if i > #words then break end
        end

        if i <= #words and #lines > 0 then
            local last_idx = #lines
            local last = lines[last_idx]
            local max_w = widths[last_idx]
            while last ~= "" and width(last .. "…") > max_w do
                local trimmed = last:gsub("%s*%S+$", "")
                if trimmed == last then break end
                last = trimmed
            end
            lines[last_idx] = (last ~= "") and (last .. "…") or "…"
        end

        while #lines > 0 and lines[#lines] == "" do
            lines[#lines] = nil
        end
        return lines
    end

    local help_lines = wrapPrefixedHelp(help, line_widths, help_pt)
    local help_rows = math.max(1, #help_lines)
    local help_h = math.max(min_icon_h, (help_rows - 1) * help_step + help_lh) + scale(4)
    local footer_h = scale(30)
    local footer_y = content_top + content_h - footer_h
    local body_y = help_top + help_h
    local body_bottom = footer_y - scale(4)
    local body_h = body_bottom - body_y

    tw_pref:paintTo(bb, x0, help_top + math.floor((help_lh - pref_sz.h) / 2))
    tw_pref:free()

    for i, line in ipairs(help_lines) do
        if line ~= "" then
            local tw = TextWidget:new{ text = line, face = Font:getFace("cfont", scaleText(help_pt)), fgcolor = GRAY }
            local lsz = tw:getSize()
            local lx = (i == 1) and (x0 + pref_sz.w) or x0
            local ly = help_top + (i - 1) * help_step + math.floor((help_lh - lsz.h) / 2)
            tw:paintTo(bb, lx, ly)
            tw:free()
        end
    end

    -- Flecha ‹ / › con los SVG de chevrón (se invierte al tocarla)
    local function paintArrow(ax, ay, aw, ah, icon, key)
        local pressed = (self._pressed_btn == key)
        paintPill(bb, ax, ay, aw, ah, pressed)
        if icon then
            local isz = icon:getSize()
            paintIconOn(bb, icon, ax + math.floor((aw - isz.w) / 2), ay + math.floor((ah - isz.h) / 2), pressed)
        end
    end

    -- Riel + perilla (mismo estilo que el slider de brillo)
    local function paintTrack(tx, tw_, cy, frac, dragging)
        local knob, track_h = scale(18), scale(3)
        local track_x = tx + math.floor(knob / 2)
        local track_w = tw_ - knob
        local kx = math.floor(frac * track_w)
        local tr = math.floor(track_h / 2)
        local fill_w = math.max(track_h, kx + (dragging and 0 or math.floor(knob / 2)))
        paintRoundRect(bb, track_x, cy - tr, track_w, track_h, tr, Blitbuffer.COLOR_LIGHT_GRAY)
        paintRoundRect(bb, track_x, cy - tr, math.min(track_w, fill_w), track_h, tr, BLACK)
        if not dragging then
            local ring = 1
            local ky = cy - math.floor(knob / 2)
            local kxx = track_x + kx - math.floor(knob / 2)
            local kr = math.floor(knob / 2)
            paintRoundRect(bb, kxx, ky, knob, knob, kr, Blitbuffer.COLOR_DARK_GRAY)
            paintRoundRect(bb, kxx + ring, ky + ring, knob - 2 * ring, knob - 2 * ring, math.max(1, kr - ring), WHITE)
        end
        return track_x, track_w
    end

    -- ---------- Cuerpo ----------
    if spec.presets and spec.mode ~= "bars" then
        -- Lo más simple primero: un botón por valor con nombre (Small / Medium / Large...)
        local n = #spec.presets
        local pgap = scale(6)
        local pw = math.floor((w - (n - 1) * pgap) / n)
        local ph = math.min(scale(44), math.max(scale(28), body_h - scale(8)))
        local matched = false
        for _i, p in ipairs(spec.presets) do
            if valuesEqual(p.value, spec.pending) then matched = true; break end
        end
        -- Si el valor actual no es ninguno de los botones (se ajustó con la barra), se avisa debajo en chico
        local note_h = (not matched and body_h >= ph + scale(20)) and scale(14) or 0
        local group_h = ph + note_h
        local py = body_y + math.floor((body_h - group_h) / 2)
        -- Un solo tamaño de letra para todos los botones (el más grande en que entra el más largo, en negrita,
        -- que es como se ve el elegido): así ninguno se corta y se ven parejos
        local label_pt = 12
        for pt = 12, 6, -1 do
            local fits = true
            for _i, p in ipairs(spec.presets) do
                if pickTextWidth(p.label, pt, true) > pw - scale(10) then fits = false; break end
            end
            label_pt = pt
            if fits then break end
        end
        for i, p in ipairs(spec.presets) do
            local px = x0 + (i - 1) * (pw + pgap)
            local sel = valuesEqual(p.value, spec.pending)
            local fg = paintPill(bb, px, py, pw, ph, sel)
            local tw = fitTextWidget(p.label, label_pt, label_pt, pw - scale(8), sel, fg)
            local sz = tw:getSize()
            tw:paintTo(bb, px + math.floor((pw - sz.w) / 2), py + math.floor((ph - sz.h) / 2))
            tw:free()
            hit.presets[#hit.presets + 1] = {
                dimen = Geom:new{ x = px - math.floor(pgap / 2), y = py - scale(4), w = pw + pgap, h = ph + scale(8) },
                value = p.value,
            }
        end
        if note_h > 0 then
            local tw_n = fitTextWidget(_("Custom") .. ": " .. self:_pickerText(spec, spec.pending), 9, 6, w, false, GRAY)
            local nsz = tw_n:getSize()
            tw_n:paintTo(bb, x0 + math.floor((w - nsz.w) / 2), py + ph + scale(3))
            tw_n:free()
        end

    elseif spec.kind == "numeric" then
        local vy = body_y
        local arrow_w, arrow_h = scale(44), scale(28)
        local row1_h = scale(30)
        local ay = vy + math.floor((row1_h - arrow_h) / 2)
        paintArrow(x0, ay, arrow_w, arrow_h, self.icon_chev_left, "pick_minus")
        paintArrow(x0 + w - arrow_w, ay, arrow_w, arrow_h, self.icon_chevron_right, "pick_plus")
        hit.minus = Geom:new{ x = x0 - scale(6), y = vy, w = arrow_w + scale(12), h = row1_h }
        hit.plus = Geom:new{ x = x0 + w - arrow_w - scale(6), y = vy, w = arrow_w + scale(12), h = row1_h }

        local tw_v = fitTextWidget(self:_pickerText(spec, spec.pending), 18, 10, w - arrow_w * 2 - scale(8), true, BLACK)
        local vsz = tw_v:getSize()
        tw_v:paintTo(bb, x0 + math.floor((w - vsz.w) / 2), vy + math.floor((row1_h - vsz.h) / 2))
        tw_v:free()

        -- ¿Entran los valores típicos sin cortarse? Si no (son muchos), se saca la fila y queda solo el slider
        local chips = spec.chips or {}
        local chip_fmt = spec.chip_fmt or fmtCleanNum
        local chip_gap = scale(3)
        local chip_pt = false
        if #chips > 0 then
            if spec._chip_pt == nil then
                local cw = math.floor((w - (#chips - 1) * chip_gap) / #chips)
                spec._chip_pt = false
                for pt = 9, 6, -1 do
                    local all_fit = true
                    for _i, v in ipairs(chips) do
                        if pickTextWidth(chip_fmt(v), pt, false) > cw - scale(5) then all_fit = false; break end
                    end
                    if all_fit then spec._chip_pt = pt; break end
                end
            end
            chip_pt = spec._chip_pt
        end

        local slider_h = scale(34)
        local sy
        if chip_pt then
            sy = vy + row1_h + scale(4)
        else
            sy = vy + row1_h + math.floor((body_h - row1_h - slider_h) / 2)
        end
        local cy = sy + math.floor(slider_h / 2)
        local frac = math.max(0, math.min(1, (spec.pending - spec.lo) / (spec.hi - spec.lo)))
        local track_x, track_w = paintTrack(x0, w, cy, frac, self._pick_drag == true)
        hit.track = Geom:new{ x = x0 - scale(4), y = cy - scale(18), w = w + scale(8), h = scale(36) }
        hit.track_x, hit.track_w = track_x, track_w

        if chip_pt then
            local n = #chips
            local chip_y = sy + slider_h + scale(4)
            local chip_h = math.min(scale(26), math.max(scale(18), body_bottom - chip_y - scale(2)))
            local cw = math.floor((w - (n - 1) * chip_gap) / n)
            local face = Font:getFace("cfont", scaleText(chip_pt))
            for i, v in ipairs(chips) do
                local cx = x0 + (i - 1) * (cw + chip_gap)
                local sel = math.abs(v - spec.pending) < 0.000001
                local fg = paintPill(bb, cx, chip_y, cw, chip_h, sel)
                local tw = TextWidget:new{ text = chip_fmt(v), face = face, bold = sel, fgcolor = fg }
                local sz = tw:getSize()
                tw:paintTo(bb, cx + math.floor((cw - sz.w) / 2), chip_y + math.floor((chip_h - sz.h) / 2))
                tw:free()
                hit.chips[#hit.chips + 1] = {
                    dimen = Geom:new{ x = cx - math.floor(chip_gap / 2), y = chip_y - scale(2), w = cw + chip_gap, h = chip_h + scale(4) },
                    value = v,
                }
            end
        end

    elseif spec.kind == "dual" then
        -- Dos valores: cada uno con sus flechas y su riel
        local rh = math.floor(body_h / 2)
        local arrow_w, arrow_h = scale(34), scale(22)
        for k = 1, 2 do
            local f = spec.fields[k]
            local ry = body_y + (k - 1) * rh
            local line1_h = math.floor(rh * 0.5)
            local ay = ry + math.floor((line1_h - arrow_h) / 2)
            local pk, pm = "pick_minus" .. k, "pick_plus" .. k
            paintArrow(x0, ay, arrow_w, arrow_h, self.icon_chev_left, pk)
            paintArrow(x0 + w - arrow_w, ay, arrow_w, arrow_h, self.icon_chevron_right, pm)

            -- "Etiqueta  valor" centrado entre las flechas
            local avail = w - arrow_w * 2 - scale(8)
            local tw_name = fitTextWidget(f.label, 10, 8, math.floor(avail * 0.5), false, GRAY)
            local tw_val = fitTextWidget(spec.fmt(spec.pending[k]) .. (spec.unit or ""), 15, 9,
                avail - tw_name:getSize().w - scale(6), true, BLACK)
            local nsz, vsz = tw_name:getSize(), tw_val:getSize()
            local total = nsz.w + scale(6) + vsz.w
            local tx = x0 + math.floor((w - total) / 2)
            tw_name:paintTo(bb, tx, ry + math.floor((line1_h - nsz.h) / 2) + scale(1))
            tw_val:paintTo(bb, tx + nsz.w + scale(6), ry + math.floor((line1_h - vsz.h) / 2))
            tw_name:free()
            tw_val:free()

            local cy = ry + line1_h + math.floor((rh - line1_h) / 2)
            local frac = math.max(0, math.min(1, (spec.pending[k] - f.lo) / (f.hi - f.lo)))
            local track_x, track_w = paintTrack(x0, w, cy, frac, self._pick_drag == k)
            hit.fields[k] = {
                minus = Geom:new{ x = x0 - scale(6), y = ry, w = arrow_w + scale(12), h = line1_h },
                plus = Geom:new{ x = x0 + w - arrow_w - scale(6), y = ry, w = arrow_w + scale(12), h = line1_h },
                track = Geom:new{ x = x0 - scale(4), y = cy - scale(14), w = w + scale(8), h = scale(28) },
                track_x = track_x, track_w = track_w,
            }
        end

    elseif spec.kind == "list" then
        local n = #spec.items
        local row_gap = (n <= 4) and scale(3) or scale(1)
        local rh = math.min(scale(36), math.floor((body_h - math.max(0, n - 1) * row_gap) / math.max(1, n)))
        local total_list_h = n * rh + math.max(0, n - 1) * row_gap
        local start_y = body_y + math.floor((body_h - total_list_h) / 2)
        local press_col = Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_LIGHT_GRAY
        for i, it in ipairs(spec.items) do
            local ry = start_y + (i - 1) * (rh + row_gap)
            local sel = valuesEqual(it.value, spec.pending)
            local pressed = (self._pressed_btn == ("pick_tile_" .. i))

            if pressed then
                local pm = scale(6)
                paintRoundRect(bb, r.x + border + pm, ry, inner_w - pm * 2, rh, scale(8), press_col)
            end

            local check_space = 0
            if sel then
                local tw_c = TextWidget:new{
                    text = "✓",
                    face = Font:getFace("cfont", scaleText(13)),
                    bold = true,
                    fgcolor = BLACK,
                }
                local csz = tw_c:getSize()
                tw_c:paintTo(bb, x0 + w - csz.w, ry + math.floor((rh - csz.h) / 2))
                tw_c:free()
                check_space = csz.w + scale(8)
            end

            local tw = fitTextWidget(it.label, 12, 8, w - check_space, sel, BLACK)
            local sz = tw:getSize()
            tw:paintTo(bb, x0, ry + math.floor((rh - sz.h) / 2))
            tw:free()

            hit.tiles[#hit.tiles + 1] = {
                dimen = Geom:new{ x = r.x + border, y = ry, w = inner_w, h = rh },
                value = it.value,
                index = i,
            }
        end

    else -- grilla con íconos (dirección, zoom, alineación, rotación)
        local n = #spec.items
        local cols = (n <= 5) and n or 4
        local rows = math.ceil(n / cols)
        local gap = scale(4)
        -- ¿Los casilleros tienen ícono? Entonces el título del elegido va abajo. Si el texto ya está adentro
        -- del casillero (números, etc.) el título sería repetido y solo ocuparía lugar: no se pone.
        local has_icons = false
        if ok_iw and IconWidget then
            for _i, it in ipairs(spec.items) do
                if it.icon then has_icons = true; break end
            end
        end
        -- Título del elegido: se mide su alto real (antes era un número fijo y el pie lo tapaba)
        local caption_title = selected_item and (selected_item.long or selected_item.label) or nil
        local caption_h, caption_gap = 0, 0
        if has_icons and caption_title then
            local probe_c = TextWidget:new{ text = "Ag", face = Font:getFace("cfont", scaleText(9)), bold = true }
            caption_h = probe_c:getSize().h
            probe_c:free()
            caption_gap = scale(3)
        end
        local caption_block = (caption_h > 0) and (caption_h + caption_gap) or 0
        local avail_h = body_h - caption_block
        local tile_w = math.floor((w - (cols - 1) * gap) / cols)
        local tile_h = math.min(scale(50), math.floor((avail_h - (rows - 1) * gap) / rows))
        local grid_h = rows * tile_h + (rows - 1) * gap
        -- Grilla + título se centran juntos en el cuerpo (y siempre quedan adentro: nunca llegan al pie)
        local gy = body_y + math.max(0, math.floor((body_h - (grid_h + caption_block)) / 2))
        for i, it in ipairs(spec.items) do
            local col = (i - 1) % cols
            local row = math.floor((i - 1) / cols)
            local tx = x0 + col * (tile_w + gap)
            local ty = gy + row * (tile_h + gap)
            local sel = valuesEqual(it.value, spec.pending)
            local rad = scale(8)
            if sel then
                paintRoundRect(bb, tx, ty, tile_w, tile_h, rad, BLACK)
                paintRoundRect(bb, tx + scale(2), ty + scale(2), tile_w - scale(4), tile_h - scale(4), rad - scale(2), WHITE)
            else
                paintRoundRect(bb, tx, ty, tile_w, tile_h, rad, Blitbuffer.COLOR_LIGHT_GRAY)
                paintRoundRect(bb, tx + 1, ty + 1, tile_w - 2, tile_h - 2, rad - 1, WHITE)
            end
            local icon_sz = math.min(scale(34), tile_h - scale(8), tile_w - scale(8))
            local shown_icon = false
            if it.icon and ok_iw and IconWidget and icon_sz > scale(10) then
                shown_icon = pcall(function()
                    local iw = IconWidget:new{ icon = it.icon, width = icon_sz, height = icon_sz }
                    iw:paintTo(bb, tx + math.floor((tile_w - icon_sz) / 2), ty + math.floor((tile_h - icon_sz) / 2))
                    iw:free()
                end)
            end
            if not shown_icon then
                -- Sin ícono: el texto va adentro del casillero
                local tw = fitTextWidget(it.label, 11, 7, tile_w - scale(4), sel, BLACK)
                local sz = tw:getSize()
                tw:paintTo(bb, tx + math.floor((tile_w - sz.w) / 2), ty + math.floor((tile_h - sz.h) / 2))
                tw:free()
            end
            hit.tiles[#hit.tiles + 1] = {
                dimen = Geom:new{ x = tx, y = ty, w = tile_w, h = tile_h }, value = it.value,
            }
        end
        -- Título de la opción elegida, debajo de la grilla (solo cuando los casilleros son íconos)
        if caption_block > 0 then
            local tw_c = fitTextWidget(caption_title, 9, 6, w, true, BLACK)
            local csz = tw_c:getSize()
            tw_c:paintTo(bb, x0 + math.floor((w - csz.w) / 2), gy + grid_h + caption_gap)
            tw_c:free()
        end
    end

    -- ---------- Pie inferior: Cancel (izq.) · Default (centro) · Apply (der.) ----------
    local cancel_pressed = (self._pressed_btn == "pick_cancel")
    local cancel_col = cancel_pressed and BLACK or GRAY
    local tw_cancel = fitTextWidget(_("Cancel"), 11, 8, math.floor(w * 0.3), false, cancel_col)
    local csz = tw_cancel:getSize()
    if cancel_pressed then
        paintRoundRect(bb, x0 - scale(6), footer_y + scale(3), csz.w + scale(12), footer_h - scale(6), scale(6), PRESSED_TAB_BG)
    end
    tw_cancel:paintTo(bb, x0, footer_y + math.floor((footer_h - csz.h) / 2))
    tw_cancel:free()
    hit.btn_cancel = Geom:new{
        x = r.x + border,
        y = footer_y,
        w = pad + csz.w + scale(10),
        h = footer_h,
    }

    local def_val = self:_pickerDefaultValue(spec)
    local can_def = (def_val ~= nil) and not valuesEqual(spec.pending, def_val)
    local def_pressed = (self._pressed_btn == "pick_def")
    local def_h = scale(22)
    local def_y = footer_y + math.floor((footer_h - def_h) / 2)
    local def_fg = paintPill(bb, 0, -100, 10, def_h, def_pressed)
    if not def_pressed and not can_def then
        def_fg = GRAY
    end
    local tw_def = fitTextWidget(_("Default"), 10, 7, math.floor(w * 0.34), false, def_fg)
    local dsz = tw_def:getSize()
    local def_w = dsz.w + scale(16)
    local def_x = x0 + math.floor((w - def_w) / 2)
    paintPill(bb, def_x, def_y, def_w, def_h, def_pressed)
    tw_def:paintTo(bb, def_x + math.floor((def_w - dsz.w) / 2), def_y + math.floor((def_h - dsz.h) / 2))
    tw_def:free()
    hit.btn_def = Geom:new{
        x = def_x - scale(4),
        y = footer_y,
        w = def_w + scale(8),
        h = footer_h,
    }

    local apply_pressed = (self._pressed_btn == "pick_apply")
    local apply_col = (has_changes or apply_pressed) and BLACK or GRAY
    local tw_apply = fitTextWidget(_("Apply"), 11, 8, math.floor(w * 0.3), true, apply_col)
    local asz = tw_apply:getSize()
    local apply_x = x0 + w - asz.w
    if apply_pressed then
        paintRoundRect(bb, apply_x - scale(6), footer_y + scale(3), asz.w + scale(12), footer_h - scale(6), scale(6), PRESSED_TAB_BG)
    end
    tw_apply:paintTo(bb, apply_x, footer_y + math.floor((footer_h - asz.h) / 2))
    tw_apply:free()
    hit.btn_apply = Geom:new{
        x = apply_x - scale(10),
        y = footer_y,
        w = asz.w + pad + scale(10),
        h = footer_h,
    }
end

function ScrubberMenu:paintTo(bb, x, y)
    if self._crop_hidden then return end
    local r = self.popup_rect
    local pad = scale(16)
    local border = math.max(1, scale(1))
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
            paintRoundRect(bb, pressed.x + pin, tab_y + scale(4), pressed.w - pin * 2, tab_h - scale(12), scale(10), PRESSED_TAB_BG)
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

    local is_typo = (self.active_tab == "typo" or self.active_tab == "font_list" or self.active_tab == "more_list" or self.active_tab == "opt_picker")
    if self:_isTypoSubview() and self.icon_back then
        -- Dentro de un submenú de Aa (fuentes, More, selector de una opción) el botón es la flecha de "volver"
        local bsz = self.icon_back:getSize()
        self.icon_back:paintTo(bb, self.tab_typo_dimen.x + math.floor((self.tab_typo_dimen.w - bsz.w) / 2),
            tab_y + math.floor((tab_h - bsz.h) / 2))
    else
        local tw_aa = TextWidget:new{
            text = "Aa",
            face = Font:getFace("cfont", scale(13)),
            bold = is_typo,
            fgcolor = is_typo and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        }
        local aasz = tw_aa:getSize()
        tw_aa:paintTo(bb, self.tab_typo_dimen.x + math.floor((self.tab_typo_dimen.w - aasz.w) / 2), tab_y + math.floor((tab_h - aasz.h) / 2))
        tw_aa:free()
    end

    -- Línea divisoria inferior de pestañas: hairline de 1px en COLOR_GRAY_E.
    -- El indicador negro de la pestaña activa se pinta DESPUÉS, por encima de esta línea.
    local div_h = math.max(1, scale(1))
    bb:paintRect(r.x + border, tab_y + tab_h - div_h, inner_w, div_h, Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_LIGHT_GRAY)

    local ind_h = math.max(2, scale(2))   -- cubre la línea divisoria en el tramo activo
    if is_quick then
        bb:paintRect(self.tab_quick_dimen.x + scale(16), tab_y + tab_h - ind_h, half_w - scale(32), ind_h, Blitbuffer.COLOR_BLACK)
    else
        bb:paintRect(self.tab_typo_dimen.x + scale(16), tab_y + tab_h - ind_h, (inner_w - half_w) - scale(32), ind_h, Blitbuffer.COLOR_BLACK)
    end

    local content_top = tab_y + tab_h
    local content_h = scale(QUICK_CONTENT_H)

    -- ====================================================
    -- CONTENIDO PESTAÑA 1: RÁPIDO
    -- ====================================================
    if self.active_tab == "quick" then
        local show_status = self:_statusRowEnabled()

        -- Orden vertical: botones día / noche → brillo (título + toggle, y debajo el slider) → buscar / acciones /
        -- ajustes → pie de estado (opcional). El contenido útil mide siempre content_h: se descuenta el pie (si está)
        -- y lo que queda se reparte en cuatro espacios iguales, medidos entre lo que SE VE de cada fila (los
        -- márgenes internos de las cajas de toque no cuentan): arriba · swatches→brillo · brillo→íconos · abajo.
        if not show_status then self._status_dimens = {} end
        local footer_h = show_status and scale(STATUS_FOOTER_H) or 0
        local swatch_h = scale(40)
        local light_slider = self:_getLightSlider()   -- nil: el dispositivo no da acceso al nivel → solo queda el toggle
        local head_h = scale(24)                       -- cabecera: lo que mide el toggle
        local head_gap = scale(6)                      -- aire entre la cabecera y el slider
        local slider_h = light_slider and scale(18) or 0   -- alto visible del slider = la perilla (la zona de toque es más alta)
        local block_h = head_h + (light_slider and (head_gap + slider_h) or 0)
        local bottom_h = scale(44)                     -- caja de toque de los íconos de abajo
        local icon_vis = scale(34)                     -- alto visible de la fila de abajo: lo que mide la píldora de búsqueda
        local G = math.floor((content_h - footer_h - swatch_h - block_h - icon_vis) / 4)
        local swatch_y = content_top + G
        local block_y = swatch_y + swatch_h + G
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

        -- Brillo: título + % + toggle a la derecha; debajo [−] slider [+] (como el popup de brillo de KiKome)
        local row_x = r.x + pad
        local row_w = r.w - pad * 2
        self:_paintLightBlock(bb, row_x, row_w, block_y, head_h, head_gap, slider_h, light_slider)

        -- Fila de abajo: sus íconos quedan a G del bloque de brillo
        local bottom_y = block_y + block_h + G - math.floor((bottom_h - icon_vis) / 2)

        -- Pie de estado: pegado al borde de abajo del contenido
        if show_status then
            self:_paintStatusRow(bb, r, pad, content_top + content_h - footer_h, footer_h)
        end

        -- Fila de abajo: [ Search 🔍 ] ····· [acciones] [ajustes]. Todo queda DENTRO de los bordes de los swatches
        -- (row_x … row_x + row_w): la píldora de búsqueda ocupa lo que sobra a la izquierda y los dos íconos van
        -- juntos a la derecha, con el de ajustes tocando el borde de adentro del cuadrado de noche.
        local isz_box = scale(32)
        local icon_gap = scale(4)
        local pill_gap = scale(10)
        local set_x = row_x + row_w - isz_box
        local act_x = set_x - icon_gap - isz_box
        local pill_w = act_x - pill_gap - row_x
        local pill_h = scale(34)
        local pill_y = bottom_y + math.floor((bottom_h - pill_h) / 2)

        -- Ícono centrado en center_x; al presionar se marca con el recuadro negro centrado sobre el ícono
        local box_sz = scale(38)
        local function paintCellIcon(icon, center_x, pressed)
            if not icon then return end
            local isz = icon:getSize()
            local ix = center_x - math.floor(isz.w / 2)
            local iy = bottom_y + math.floor((bottom_h - isz.h) / 2)
            if pressed then
                local box_x = center_x - math.floor(box_sz / 2)
                local box_y = bottom_y + math.floor((bottom_h - box_sz) / 2)
                paintRoundRect(bb, box_x, box_y, box_sz, box_sz, scale(8), Blitbuffer.COLOR_BLACK)
                bb:paintRect(ix, iy, isz.w, isz.h, Blitbuffer.COLOR_WHITE)
                icon:paintTo(bb, ix, iy)
                bb:invertRect(ix, iy, isz.w, isz.h)
            else
                icon:paintTo(bb, ix, iy)
            end
        end

        -- Buscador: píldora con el texto a la izquierda y la lupa a la derecha
        local search_pressed = self._pressed_btn == "search"
        local fg, _bg = paintPill(bb, row_x, pill_y, pill_w, pill_h, search_pressed)
        do
            local isz = self.icon_search and self.icon_search:getSize() or { w = 0, h = 0 }
            local ipad = scale(14)
            local tw_s = TextWidget:new{
                text = _("Search"), face = Font:getFace("cfont", scaleText(11)), fgcolor = fg,
                max_width = pill_w - ipad * 2 - isz.w - scale(8),
            }
            local tsz = tw_s:getSize()
            tw_s:paintTo(bb, row_x + scale(16), pill_y + math.floor((pill_h - tsz.h) / 2))
            tw_s:free()
            paintIconOn(bb, self.icon_search, row_x + pill_w - ipad - isz.w,
                pill_y + math.floor((pill_h - isz.h) / 2), search_pressed)
        end
        self.btn_search_dimen = Geom:new{ x = row_x, y = bottom_y, w = pill_w + math.floor(pill_gap / 2), h = bottom_h }

        -- Acciones del scrubber
        paintCellIcon(self.icon_warehouse, act_x + math.floor(isz_box / 2), false)
        self.btn_actions_dimen = Geom:new{
            x = act_x - math.floor(pill_gap / 2), y = bottom_y,
            w = isz_box + math.floor(pill_gap / 2) + math.floor(icon_gap / 2), h = bottom_h,
        }

        -- Ajustes; al presionar se marca con el recuadro negro
        paintCellIcon(self.icon_wifi, set_x + math.floor(isz_box / 2), self._pressed_btn == "wifi")
        local set_zone_x = set_x - math.floor(icon_gap / 2)
        self.btn_wifi_dimen = Geom:new{ x = set_zone_x, y = bottom_y, w = (r.x + r.w - border) - set_zone_x, h = bottom_h }


    -- ====================================================
    -- CONTENIDO PESTAÑA 2: TIPOGRAFÍA
    -- ====================================================
    elseif self.active_tab == "typo" then
        local row_x = r.x + pad
        local row_w = r.w - pad * 2
        local row_h = math.floor((content_h - scale(4)) / 4)

        -- Botón píldora con signo − o + dibujado en geometría (se invierte a negro/blanco al tocarlo)
        local function paintStepPill(bx, by, bw, bh, is_plus, pressed)
            local fg = paintPill(bb, bx, by, bw, bh, pressed)
            local arm = scale(11)
            local th = math.max(2, scale(2))
            local cx = bx + math.floor(bw / 2)
            local cy = by + math.floor(bh / 2)
            bb:paintRect(cx - math.floor(arm / 2), cy - math.floor(th / 2), arm, th, fg)
            if is_plus then
                bb:paintRect(cx - math.floor(th / 2), cy - math.floor(arm / 2), th, arm, fg)
            end
        end

        -- PDF / CBZ: en vez de fuente / tamaño / interlineado, tres accesos a submenús (Reflow, Page, Visual)
        local is_paging = (self:getDocKind() == "paging")
        local r1_y, r2_y, r3_y = content_top, content_top + row_h, content_top + row_h * 2
        self.btn_entry_dimens = nil
        if is_paging then
            self.btn_font_row_dimen = nil
            self.btn_size_dec_dimen, self.btn_size_inc_dimen = nil, nil
            self.btn_space_dec_dimen, self.btn_space_inc_dimen = nil, nil
            self.btn_size_mid_dimen, self.btn_space_mid_dimen = nil, nil
            self.btn_entry_dimens = {}
            local entries = {}
            for _i, def in ipairs({
                { group = "page",   label = _("Page"),   icon = self.icon_view_page },
                { group = "reflow", label = _("Reflow"), icon = self.icon_col_one },
                { group = "visual", label = _("Visual"), icon = self.icon_droplet2 },
            }) do
                -- Un grupo sin opciones para este documento (p. ej. Reflow en un CBZ) no se muestra
                if #self:_groupRows(def.group) > 0 then
                    def.summary = self:_groupSummary(def.group)
                    entries[#entries + 1] = def
                end
            end
            local chev_sz = scale(16)
            for i, e in ipairs(entries) do
                local ey = content_top + (i - 1) * row_h
                self.btn_entry_dimens[#self.btn_entry_dimens + 1] = {
                    group = e.group,
                    dimen = Geom:new{ x = r.x + border, y = ey, w = inner_w, h = row_h },
                }
                local chev_x = row_x + row_w - chev_sz
                local chev_y = ey + math.floor((row_h - chev_sz) / 2)
                local painted = false
                if self.icon_chevron_right then
                    painted = pcall(function() self.icon_chevron_right:paintTo(bb, chev_x, chev_y) end)
                end
                if not painted then
                    local tw_c = TextWidget:new{ text = "›", face = Font:getFace("cfont", scale(14)), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
                    local csz = tw_c:getSize()
                    tw_c:paintTo(bb, chev_x + math.floor((chev_sz - csz.w) / 2), ey + math.floor((row_h - csz.h) / 2))
                    tw_c:free()
                end
                local right_edge = chev_x - scale(8)
                if e.summary and e.summary ~= "" then
                    local tw_s = TextWidget:new{
                        text = e.summary,
                        face = Font:getFace("cfont", scaleText(11)),
                        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                        max_width = math.floor(row_w * 0.4),
                        truncate_with_ellipsis = true,
                    }
                    local ssz = tw_s:getSize()
                    tw_s:paintTo(bb, right_edge - ssz.w, ey + math.floor((row_h - ssz.h) / 2))
                    tw_s:free()
                    right_edge = right_edge - ssz.w - scale(8)
                end
                -- Ícono al inicio de la fila (si hay) y el nombre a continuación
                local label_x = row_x
                if e.icon then
                    local isz = e.icon:getSize()
                    local drawn = pcall(function()
                        e.icon:paintTo(bb, row_x, ey + math.floor((row_h - isz.h) / 2))
                    end)
                    if drawn then label_x = row_x + isz.w + scale(10) end
                end
                local tw_l = TextWidget:new{
                    text = e.label,
                    face = Font:getFace("cfont", scaleText(13)),
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    max_width = math.max(scale(40), right_edge - label_x),
                    truncate_with_ellipsis = true,
                }
                local lsz = tw_l:getSize()
                tw_l:paintTo(bb, label_x, ey + math.floor((row_h - lsz.h) / 2))
                tw_l:free()
            end
        else
        -- 1. FILA FUENTE: Nombre de Fuente (con su propia font) + Chevron a la derecha
        r1_y = content_top
        self.btn_font_row_dimen = Geom:new{ x = r.x + border, y = r1_y, w = inner_w, h = row_h }

        local chev_sz = scale(16)
        local chev_x = row_x + row_w - chev_sz
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
        local has_pin1 = self.icon_pin and self:_isDefaultSet({ "font_face" })
        local psz1 = has_pin1 and self.icon_pin:getSize() or { w = 0, h = 0 }
        local pin1_extra = has_pin1 and (scale(5) + psz1.w) or 0
        local max_font_w = math.max(scale(40), chev_x - row_x - scale(8) - pin1_extra)
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
        tw_font:paintTo(bb, row_x, r1_y + math.floor((row_h - ftsz.h) / 2))
        if has_pin1 then
            self.icon_pin:paintTo(bb, row_x + ftsz.w + scale(5), r1_y + math.floor((row_h - psz1.h) / 2))
        end
        tw_font:free()

        -- 2. FILA TAMAÑO DE TEXTO: [ − ]   Aa  22 pt   [ + ]
        r2_y = r1_y + row_h

        local step_w = scale(42)
        local step_h = scale(30)
        local step2_y = r2_y + math.floor((row_h - step_h) / 2)
        local right_step_x = row_x + row_w - step_w

        self.btn_size_dec_dimen = Geom:new{ x = r.x + border, y = r2_y, w = pad + step_w + scale(8), h = row_h }
        self.btn_size_inc_dimen = Geom:new{ x = right_step_x - scale(8), y = r2_y, w = pad + step_w + scale(8), h = row_h }
        self.btn_size_mid_dimen = Geom:new{
            x = self.btn_size_dec_dimen.x + self.btn_size_dec_dimen.w, y = r2_y,
            w = math.max(0, self.btn_size_inc_dimen.x - (self.btn_size_dec_dimen.x + self.btn_size_dec_dimen.w)), h = row_h }

        paintStepPill(row_x, step2_y, step_w, step_h, false, self._pressed_btn == "size_dec")
        paintStepPill(right_step_x, step2_y, step_w, step_h, true, self._pressed_btn == "size_inc")

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
        local has_pin2 = self.icon_pin and self:_isDefaultSet({ "font_size" })
        local psz2 = has_pin2 and self.icon_pin:getSize() or { w = 0, h = 0 }
        local pin2_extra = has_pin2 and (scale(4) + psz2.w) or 0
        local total_w2 = aasz2.w + gap_lbl + svsz.w + pin2_extra
        local start_x2 = r.x + math.floor((r.w - total_w2) / 2)

        tw_aa_ico:paintTo(bb, start_x2, r2_y + math.floor((row_h - aasz2.h) / 2))
        tw_sz_val:paintTo(bb, start_x2 + aasz2.w + gap_lbl, r2_y + math.floor((row_h - svsz.h) / 2))
        if has_pin2 then
            self.icon_pin:paintTo(bb, start_x2 + aasz2.w + gap_lbl + svsz.w + scale(4), r2_y + math.floor((row_h - psz2.h) / 2))
        end
        tw_aa_ico:free()
        tw_sz_val:free()

        -- 3. FILA INTERLINEADO: [ − ]   ≡  100%   [ + ]
        r3_y = r2_y + row_h

        local step3_y = r3_y + math.floor((row_h - step_h) / 2)
        self.btn_space_dec_dimen = Geom:new{ x = r.x + border, y = r3_y, w = pad + step_w + scale(8), h = row_h }
        self.btn_space_inc_dimen = Geom:new{ x = right_step_x - scale(8), y = r3_y, w = pad + step_w + scale(8), h = row_h }
        self.btn_space_mid_dimen = Geom:new{
            x = self.btn_space_dec_dimen.x + self.btn_space_dec_dimen.w, y = r3_y,
            w = math.max(0, self.btn_space_inc_dimen.x - (self.btn_space_dec_dimen.x + self.btn_space_dec_dimen.w)), h = row_h }

        paintStepPill(row_x, step3_y, step_w, step_h, false, self._pressed_btn == "space_dec")
        paintStepPill(right_step_x, step3_y, step_w, step_h, true, self._pressed_btn == "space_inc")

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
        local has_pin3 = self.icon_pin and self:_isDefaultSet({ "line_spacing" })
        local psz3 = has_pin3 and self.icon_pin:getSize() or { w = 0, h = 0 }
        local pin3_extra = has_pin3 and (scale(4) + psz3.w) or 0
        local total_w3 = eqsz.w + gap_lbl + spsz.w + pin3_extra
        local start_x3 = r.x + math.floor((r.w - total_w3) / 2)

        tw_eq_ico:paintTo(bb, start_x3, r3_y + math.floor((row_h - eqsz.h) / 2))
        tw_sp_val:paintTo(bb, start_x3 + eqsz.w + gap_lbl, r3_y + math.floor((row_h - spsz.h) / 2))
        if has_pin3 then
            self.icon_pin:paintTo(bb, start_x3 + eqsz.w + gap_lbl + spsz.w + scale(4), r3_y + math.floor((row_h - psz3.h) / 2))
        end
        tw_eq_ico:free()
        tw_sp_val:free()

        end

        -- 4. FILA INFERIOR: píldora segmentada (columnas / modo de vista) + botón More (⋮) + rotar
        local r4_y = r3_y + row_h

        local opt_h = scale(34)
        local opt_y = r4_y + math.floor((row_h - opt_h) / 2)
        local btn_sz = scale(32)
        local btn_gap = scale(2)
        local pill_gap = scale(10)
        -- EPUB: More (⋮) queda en el extremo derecho y Rotar a su izquierda.
        -- PDF / CBZ: no hay More, así que Rotar ocupa el extremo derecho.
        local edge_x = row_x + row_w - btn_sz
        local more_x = edge_x
        local rot_x = is_paging and edge_x or (edge_x - btn_gap - btn_sz)

        local seg_icons, selected, seg_n
        if self:getDocKind() == "paging" then
            seg_icons = { self.icon_view_page, self.icon_view_cont }
            selected = self:isContinuousView() and 2 or 1
            seg_n = 2
        elseif self:_optAvailable("view_mode") then
            -- EPUB: una columna / dos columnas / modo continuo (scroll)
            seg_icons = { self.icon_col_one, self.icon_col_two, self.icon_view_cont }
            selected = self:isRollingScroll() and 3 or self:getBookColumns()
            seg_n = 3
        else
            seg_icons = { self.icon_col_one, self.icon_col_two }
            selected = self:getBookColumns()
            seg_n = 2
        end

        local layout_names = (self:getDocKind() == "paging") and { "page_scroll" }
            or (seg_n == 3 and { "visible_pages", "view_mode" } or { "visible_pages" })
        local has_pin4 = self.icon_pin and self:_isDefaultSet(layout_names)
        local psz4 = has_pin4 and self.icon_pin:getSize() or { w = 0, h = 0 }
        local pin4_space = has_pin4 and (psz4.w + scale(4)) or 0
        local pill_w = rot_x - pill_gap - pin4_space - row_x   -- Rotar es siempre el botón más a la izquierda

        paintSegmented(bb, row_x, opt_y, pill_w, opt_h, seg_icons, nil, selected, seg_n)
        if has_pin4 then
            self.icon_pin:paintTo(bb, row_x + pill_w + scale(5), r4_y + math.floor((row_h - psz4.h) / 2))
        end
        local seg_w = math.floor(pill_w / seg_n)
        self.btn_seg_dimens = {}
        for i = 1, seg_n do
            local sx = row_x + (i - 1) * seg_w
            local sw_i = (i == seg_n) and (pill_w - (seg_n - 1) * seg_w) or seg_w
            self.btn_seg_dimens[i] = Geom:new{ x = sx, y = r4_y, w = sw_i, h = row_h }
        end

        -- Botón More (⋮) y botón de rotar: el ícono se invierte un instante al tocarlo
        local function paintSideBtn(icon, bx, pressed_key)
            if not icon then return end
            local isz = icon:getSize()
            local ix = bx + math.floor((btn_sz - isz.w) / 2)
            local iy = r4_y + math.floor((row_h - isz.h) / 2)
            if self._pressed_btn == pressed_key then
                local box = scale(38)
                local bxx = bx + math.floor((btn_sz - box) / 2)
                paintRoundRect(bb, bxx, r4_y + math.floor((row_h - box) / 2), box, box, scale(8), Blitbuffer.COLOR_BLACK)
                paintIconOn(bb, icon, ix, iy, true)
            else
                icon:paintTo(bb, ix, iy)
            end
        end
        if not is_paging then paintSideBtn(self.icon_more, more_x, "more") end
        paintSideBtn(self.icon_rotate, rot_x, "rotate")

        local right_edge = r.x + r.w - border
        local rot_zone_x = rot_x - math.floor(pill_gap / 2)
        if is_paging then
            self.btn_rotate_dimen = Geom:new{ x = rot_zone_x, y = r4_y, w = right_edge - rot_zone_x, h = row_h }
            self.btn_more_dimen = nil
        else
            local more_zone_x = more_x - math.floor(btn_gap / 2)
            self.btn_rotate_dimen = Geom:new{ x = rot_zone_x, y = r4_y, w = more_zone_x - rot_zone_x, h = row_h }
            self.btn_more_dimen = Geom:new{ x = more_zone_x, y = r4_y, w = right_edge - more_zone_x, h = row_h }
        end

        -- Zonas para mantener apretado (poner / sacar valor por defecto)
        local full_x, full_w = r.x + border, inner_w
        self._typo_hold = {
            { label = _("Font"), names = { "font_face" },
              dimen = Geom:new{ x = full_x, y = r1_y, w = full_w, h = row_h } },
            { label = _("Font size"), names = { "font_size" }, native = "font_size",
              dimen = Geom:new{ x = full_x, y = r2_y, w = full_w, h = row_h } },
            { label = _("Line spacing"), names = { "line_spacing" }, native = "line_spacing",
              dimen = Geom:new{ x = full_x, y = r3_y, w = full_w, h = row_h } },
            { label = _("Layout"),
              names = layout_names,
              dimen = Geom:new{ x = row_x, y = r4_y, w = pill_w + pin4_space, h = row_h } },
        }
        -- PDF / CBZ: las tres primeras filas son accesos a submenús; solo la fila de abajo tiene valor por defecto
        if is_paging then self._typo_hold = { self._typo_hold[4] } end

    -- ====================================================
    -- SUBVISTA: LISTA PAGINADA DE FUENTES (CADA UNA EN SU PROPIA FUENTE)
    -- ====================================================
    elseif self.active_tab == "font_list" then
        local fonts = self:getAvailableFonts()
        local cur_font = self:getBookFontFace()

        -- Si entran hasta 5 fuentes, mostramos 5 en 1 sola página sin barra inferior
        local per_page = self.fonts_per_page or 5
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
    -- SUBVISTA: SELECTOR PROPIO DE UNA OPCIÓN
    -- ====================================================
    elseif self.active_tab == "opt_picker" then
        self:_paintPicker(bb, r, border, inner_w, content_top, content_h)

    -- ====================================================
    -- SUBVISTA: MÁS OPCIONES (botón ⋮ de la pestaña Aa)
    -- ====================================================
    elseif self.active_tab == "more_list" then
        local conf = self:_conf() or {}
        local sect_h = scale(26)
        local full_rh = self.font_row_h
        local pages, paginated = self:_morePages()
        self.more_total_pages = math.max(1, #pages)
        self.more_page = math.max(1, math.min(self.more_page or 1, self.more_total_pages))
        self.more_pill_dimen = nil
        self.more_pill_info = nil
        local page_def = pages[self.more_page] or { entries = {} }
        local rows = page_def.entries
        local count = #rows
        local per_page = self.fonts_per_page or 5

        local rh
        if paginated then
            rh = full_rh
        elseif page_def.plain then
            rh = (count > 0) and math.min(full_rh, math.floor(content_h / count)) or full_rh
        else
            rh = full_rh
        end
        self.more_hits = {}

        if count == 0 then
            local tw_empty = TextWidget:new{
                text = _("No more options"),
                face = Font:getFace("cfont", scale(11)),
                bold = true,
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            }
            local esz = tw_empty:getSize()
            tw_empty:paintTo(bb, r.x + math.floor((r.w - esz.w) / 2), content_top + scale(40))
            tw_empty:free()
        end

        local m_pad = scale(12)
        local row_x = r.x + m_pad
        local right = r.x + r.w - m_pad
        local base_fsz = math.max(8, scaleText(10))
        local row_face = Font:getFace("cfont", base_fsz)
        local val_face = Font:getFace("cfont", base_fsz)

        local cur_y = content_top
        local used_h = 0
        for i = 1, count do
            local row = rows[i]
            if row.section then
                -- Rótulo de sección: texto chico, gris y en negrita, pegado a las filas de abajo
                local tw_sec = TextWidget:new{
                    text = tostring(row.section),
                    face = Font:getFace("cfont", scaleText(9)),
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                    max_width = r.w - m_pad * 2,
                    truncate_with_ellipsis = true,
                }
                local ssz = tw_sec:getSize()
                tw_sec:paintTo(bb, row_x + scale(2), math.max(cur_y + scale(4), cur_y + sect_h - ssz.h - scale(3)))
                tw_sec:free()
                cur_y = cur_y + sect_h
                used_h = used_h + sect_h
                goto continue_row
            end
            do
            local ry = cur_y
            cur_y = cur_y + rh
            used_h = used_h + rh
            local hit = { row = row, dimen = Geom:new{ x = r.x + border, y = ry, w = inner_w, h = rh } }
            self.more_hits[#self.more_hits + 1] = hit

            local value = row.name and self:_currentFor(row.name) or nil
            local ctl_left = right
            local lbl_off = 0   -- corrimiento del nombre cuando la fila lleva un ícono al inicio

            if row.kind == "step" then
                local step_w = scale(26)
                local step_h = math.min(scale(22), rh - scale(6))
                local minus_x = row_x
                local plus_x = right - step_w
                local sy = ry + math.floor((rh - step_h) / 2)
                paintMiniStep(bb, minus_x, sy, step_w, step_h, false, self._pressed_btn == "more_dec_" .. row.id)
                paintMiniStep(bb, plus_x, sy, step_w, step_h, true, self._pressed_btn == "more_inc_" .. row.id)

                local lbl_x = minus_x + step_w + scale(8)
                local val_right = plus_x - scale(8)

                local val_txt = value ~= nil and self:_optValueText(row.name, value) or "-"
                local tw_v = TextWidget:new{
                    text = val_txt,
                    face = val_face,
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
                local vsz = tw_v:getSize()
                local val_x = val_right - vsz.w
                tw_v:paintTo(bb, val_x, ry + math.floor((rh - vsz.h) / 2))
                tw_v:free()

                local has_pin = self.icon_pin and row.names and self:_isDefaultSet(row.names)
                local psz = has_pin and self.icon_pin:getSize() or { w = 0, h = 0 }
                local pin_extra = has_pin and (scale(3) + psz.w) or 0
                local lbl_max_w = math.max(scale(24), val_x - lbl_x - scale(6) - pin_extra)

                local tw_l = TextWidget:new{
                    text = row.label,
                    face = row_face,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    max_width = lbl_max_w,
                    truncate_with_ellipsis = true,
                }
                local lsz = tw_l:getSize()
                tw_l:paintTo(bb, lbl_x, ry + math.floor((rh - lsz.h) / 2))
                if has_pin then
                    self.icon_pin:paintTo(bb, lbl_x + lsz.w + scale(3), ry + math.floor((rh - psz.h) / 2))
                end
                tw_l:free()

                hit.dec = Geom:new{ x = r.x + border, y = ry, w = m_pad + step_w + scale(6), h = rh }
                hit.inc = Geom:new{ x = plus_x - scale(6), y = ry, w = m_pad + step_w + scale(6), h = rh }
                hit.mid = Geom:new{ x = hit.dec.x + hit.dec.w, y = ry,
                    w = math.max(0, hit.inc.x - (hit.dec.x + hit.dec.w)), h = rh }
            elseif row.kind == "group" then
                -- Entrada a un submenú: solo el nombre y la flechita
                local chev_x = right - scale(14)
                local painted = false
                if self.icon_chevron_right then
                    painted = pcall(function()
                        self.icon_chevron_right:paintTo(bb, chev_x, ry + math.floor((rh - scale(16)) / 2))
                    end)
                end
                hit.ctl = Geom:new{ x = r.x + border, y = ry, w = inner_w, h = rh }
                ctl_left = painted and chev_x or right
                local row_icon = (row.id == "view_options" and self.icon_expand)
                    or (row.id == "style_options" and self.icon_droplet2) or nil
                if row_icon then
                    local isz = row_icon:getSize()
                    local drawn = pcall(function()
                        row_icon:paintTo(bb, row_x, ry + math.floor((rh - isz.h) / 2))
                    end)
                    if drawn then lbl_off = isz.w + scale(10) end
                end
            elseif row.kind == "pick" then
                -- PDF / CBZ: valor actual + flechita; tocar abre el selector (no se cambia nada hasta confirmar)
                local val_txt = value ~= nil and self:_optValueText(row.name, value) or "-"
                local chev_sz = scale(14)
                local chev_x = right - chev_sz
                local painted = false
                if self.icon_chevron_right then
                    painted = pcall(function()
                        self.icon_chevron_right:paintTo(bb, chev_x, ry + math.floor((rh - scale(16)) / 2))
                    end)
                end
                local tw_v = TextWidget:new{
                    text = val_txt,
                    face = val_face,
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    max_width = math.floor(inner_w * 0.45),
                    truncate_with_ellipsis = true,
                }
                local vsz = tw_v:getSize()
                local val_x = (painted and chev_x - scale(6) or right) - vsz.w
                tw_v:paintTo(bb, val_x, ry + math.floor((rh - vsz.h) / 2))
                tw_v:free()
                hit.ctl = Geom:new{ x = r.x + border, y = ry, w = inner_w, h = rh }
                ctl_left = val_x
            elseif row.kind == "cycle" then
                local val_txt = value ~= nil and self:_optValueText(row.name, value) or "-"
                local tw_v = TextWidget:new{
                    text = val_txt,
                    face = val_face,
                    bold = true,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
                local vsz = tw_v:getSize()
                local val_x = right - vsz.w
                tw_v:paintTo(bb, val_x, ry + math.floor((rh - vsz.h) / 2))
                tw_v:free()
                hit.ctl = Geom:new{ x = r.x + border, y = ry, w = inner_w, h = rh }
                ctl_left = val_x
            else -- switch
                local on = value ~= nil and value ~= 0 and value ~= false
                local sw_w = scale(36)
                local sw_h = math.min(scale(20), rh - scale(8))
                local sx = right - sw_w
                paintSwitch(bb, sx, ry + math.floor((rh - sw_h) / 2), sw_w, sw_h, on)
                hit.ctl = Geom:new{ x = sx - scale(12), y = ry, w = sw_w + scale(12) + m_pad, h = rh }
                hit.label = Geom:new{ x = r.x + border, y = ry, w = math.max(0, (sx - scale(12)) - (r.x + border)), h = rh }
                ctl_left = sx
            end

            -- Etiqueta (+ marca de pin si el valor actual es el que está guardado por defecto)
            if row.kind ~= "step" then
                local tw_l = TextWidget:new{
                    text = row.label,
                    face = row_face,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    max_width = math.max(scale(40), ctl_left - row_x - lbl_off - scale(10)),
                    truncate_with_ellipsis = true,
                }
                local lsz = tw_l:getSize()
                tw_l:paintTo(bb, row_x + lbl_off, ry + math.floor((rh - lsz.h) / 2))
                if self.icon_pin and row.names and self:_isDefaultSet(row.names) then
                    local pin_x = row_x + lbl_off + lsz.w + scale(4)
                    local psz = self.icon_pin:getSize()
                    if pin_x + psz.w < ctl_left - scale(2) then
                        self.icon_pin:paintTo(bb, pin_x, ry + math.floor((rh - psz.h) / 2))
                    end
                end
                tw_l:free()
            end
            end -- do
            ::continue_row::
        end

        -- Pie con puntitos de página (solo si la lista tiene más de una página)
        if paginated and self.more_total_pages > 1 then
            local fy = content_top + (per_page * full_rh)
            local fh = self.font_footer_h

            local total_pages = self.more_total_pages
            local dot_r = math.max(2, math.floor(scale(2.5)))
            local natural_pitch = scale(10)
            local budget = inner_w - (scale(20) * 2)
            local pitch = math.min(natural_pitch, (budget - 2 * dot_r) / (total_pages - 1))

            local pill_widget = GlimpsePill:new{
                padding_h = scale(8), height = scale(16), radius = scale(7), stroke = scale(1),
                inner = GlimpseDots:new{ nb = total_pages, cur = self.more_page, pitch = math.floor(pitch), dot_r = dot_r, height = scale(8) }
            }
            local pill_sz = pill_widget:getSize()
            local pill_x = r.x + math.floor((r.w - pill_sz.w) / 2)
            local pill_y = fy + math.floor((fh - pill_sz.h) / 2)
            self.more_pill_dimen = Geom:new{ x = pill_x, y = pill_y, w = pill_sz.w, h = pill_sz.h }
            self.more_pill_info = { nb = total_pages, pitch = pitch, r_max = math.floor(dot_r * 1.5), pad_h = scale(8) }
            pill_widget:paintTo(bb, pill_x, pill_y)
            pill_widget:free()
        end

    -- ====================================================
    -- SUBVISTA: LISTA PAGINADA DE ACCIONES RÁPIDAS
    -- ====================================================
    elseif self.active_tab == "actions_list" then
        local actions = self:getQuickActions()

        -- Si entran hasta 5 acciones, mostramos 5 en 1 sola página sin barra inferior
        local per_page = self.actions_per_page or 5
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

-- Invierte un instante la píldora de − / + sin bloquear toques rápidos consecutivos
function ScrubberMenu:_flashStepBtn(key, btn_dimen, fn)
    self._pressed_btn = key
    self._flash_seq = (self._flash_seq or 0) + 1
    local seq = self._flash_seq
    fn()
    local dirty_rect = btn_dimen and expandRect(btn_dimen, scale(4)) or expandRect(self.popup_rect, scale(8))
    UIManager:setDirty(self, "ui", dirty_rect)
    UIManager:scheduleIn(0.09, function()
        if self._closed or self._flash_seq ~= seq then return end
        self._pressed_btn = nil
        UIManager:setDirty(self, "ui", dirty_rect)
    end)
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
    if self._light_drag then self:_endLightDrag() end

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
        if self:_isTypoSubview() then
            -- En un submenú: la flecha vuelve UN nivel (al menú anterior)
            self:_flashThen("tab_typo", function() self:_typoBack() end)
        elseif self.active_tab ~= "typo" then
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
                if sd.key == "study" or sd.key == "wifi" then
                    local key = sd.key
                    self._pressed_status = key
                    UIManager:setDirty(self, "ui", expandRect(self.popup_rect, scale(8)))
                    UIManager:scheduleIn(0.06, function()
                        self._pressed_status = nil
                        if self._closed then return end
                        if key == "study" then
                            self:openStudy()
                        else
                            self:toggleWifi()
                            self:refreshMenu()
                        end
                    end)
                end
                return true
            end
        end

        if self.btn_search_dimen and ges.pos:intersectWith(self.btn_search_dimen) then
            self._pressed_btn = "search"
            UIManager:setDirty(self, "ui", expandRect(self.popup_rect, scale(8)))
            UIManager:scheduleIn(0.05, function()
                self._pressed_btn = nil
                if self._closed then return end
                self:openBookSearch()
            end)
            return true
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

        -- Brillo: toggle (prende / apaga recordando el nivel), − / + y salto directo sobre el slider
        if self:_onLightTap(ges.pos) then return true end

    -- Acciones Pestaña 2: Tipografía
    elseif self.active_tab == "typo" then
        -- PDF / CBZ: tocar Reflow / Page / Visual abre su lista de opciones
        for _i, e in ipairs(self.btn_entry_dimens or {}) do
            if ges.pos:intersectWith(e.dimen) then
                self.more_group = e.group
                self.more_page = 1
                self.active_tab = "more_list"
                self:refreshMenu()
                return true
            end
        end

        -- Fila de Fuente (tocar abre el catálogo)
        if self.btn_font_row_dimen and ges.pos:intersectWith(self.btn_font_row_dimen) then
            local fonts = self:getAvailableFonts()
            local cur = self:getBookFontFace()
            for i, f in ipairs(fonts) do
                if f == cur then
                    self.font_page = math.ceil(i / (self.fonts_per_page or 5))
                    break
                end
            end
            self.active_tab = "font_list"
            self:refreshMenu()
            return true
        end

        -- Tocar el valor (centro) abre el selector propio de la opción
        if self.btn_size_mid_dimen and ges.pos:intersectWith(self.btn_size_mid_dimen) then
            self:_openPicker("font_size", _("Font size"), "typo", { "font_size" })
            return true
        end
        if self.btn_space_mid_dimen and ges.pos:intersectWith(self.btn_space_mid_dimen) then
            self:_openPicker("line_spacing", _("Line spacing"), "typo", { "line_spacing" })
            return true
        end

        -- Tamaño de fuente (− / +)
        if self.btn_size_dec_dimen and ges.pos:intersectWith(self.btn_size_dec_dimen) then
            self:_flashStepBtn("size_dec", self.btn_size_dec_dimen, function()
                self:changeBookFontSize(-1)
            end)
            return true
        end
        if self.btn_size_inc_dimen and ges.pos:intersectWith(self.btn_size_inc_dimen) then
            self:_flashStepBtn("size_inc", self.btn_size_inc_dimen, function()
                self:changeBookFontSize(1)
            end)
            return true
        end

        -- Interlineado (− / +)
        if self.btn_space_dec_dimen and ges.pos:intersectWith(self.btn_space_dec_dimen) then
            self:_flashStepBtn("space_dec", self.btn_space_dec_dimen, function()
                self:changeBookLineSpacing(-5)
            end)
            return true
        end
        if self.btn_space_inc_dimen and ges.pos:intersectWith(self.btn_space_inc_dimen) then
            self:_flashStepBtn("space_inc", self.btn_space_inc_dimen, function()
                self:changeBookLineSpacing(5)
            end)
            return true
        end

        -- Columnas (1 / 2) o modo de vista (Page / Continuous): cada segmento de la píldora es una opción.
        -- En un EPUB hay un tercero: modo continuo (scroll).
        if self.btn_seg_dimens then
            for i, dimen in ipairs(self.btn_seg_dimens) do
                if ges.pos:intersectWith(dimen) then
                    if self:getDocKind() == "paging" then
                        self:setViewMode(i == 2)
                    else
                        self:setRollingLayout(i)
                    end
                    return true
                end
            end
        end

        -- Botón More (⋮): abre la lista con el resto de las opciones
        if self.btn_more_dimen and ges.pos:intersectWith(self.btn_more_dimen) then
            self._pressed_btn = "more"
            UIManager:setDirty(self, "ui", expandRect(self.popup_rect, scale(8)))
            UIManager:scheduleIn(0.06, function()
                self._pressed_btn = nil
                if self._closed then return end
                self.more_page = 1
                self.more_group = nil
                self.active_tab = "more_list"
                self:refreshMenu()
            end)
            return true
        end

        -- Rotar a horizontal: el ícono se marca un instante antes de actuar
        if self.btn_rotate_dimen and ges.pos:intersectWith(self.btn_rotate_dimen) then
            self._pressed_btn = "rotate"
            UIManager:setDirty(self, "ui", expandRect(self.popup_rect, scale(8)))
            UIManager:scheduleIn(0.06, function()
                self._pressed_btn = nil
                if self._closed then return end
                self:rotateScreen()
            end)
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

    -- Acciones Subvista: selector propio de una opción
    elseif self.active_tab == "opt_picker" then
        self:_pickerTap(ges.pos)
        return true

    -- Acciones Subvista: Más opciones (⋮)
    elseif self.active_tab == "more_list" then
        for _i, hit in ipairs(self.more_hits or {}) do
            local row = hit.row
            if hit.dec and ges.pos:intersectWith(hit.dec) then
                self:_flashStepBtn("more_dec_" .. row.id, hit.dec, function() self:_moreStep(row, -1) end)
                return true
            end
            if hit.inc and ges.pos:intersectWith(hit.inc) then
                self:_flashStepBtn("more_inc_" .. row.id, hit.inc, function() self:_moreStep(row, 1) end)
                return true
            end
            local mirror = (row.id == "margin_tb") and "b_page_margin" or nil
            if hit.mid and ges.pos:intersectWith(hit.mid) then
                self:_openPicker(row.name, row.label, "more_list", row.names, mirror)
                return true
            end
            if hit.ctl and ges.pos:intersectWith(hit.ctl) then
                if row.kind == "group" then
                    self.more_group = row.group
                    self.more_page = 1
                    self:refreshMenu()
                    return true
                end
                if row.kind == "pick" or row.kind == "cycle" then
                    self:_openPicker(row.name, row.label, "more_list", row.names, mirror)
                else
                    self:_moreToggle(row)
                end
                return true
            end
            -- Interruptor: el nombre abre su propio menú (explicación + estrellita de predeterminado)
            if hit.label and ges.pos:intersectWith(hit.label) then
                self:_openPicker(row.name, row.label, "more_list", row.names, mirror)
                return true
            end
        end
        -- Toque directo en los puntitos de página
        if self.more_pill_dimen and ges.pos:intersectWith(self.more_pill_dimen) then
            if self.more_pill_info then
                local rel_x = ges.pos.x - self.more_pill_dimen.x - self.more_pill_info.pad_h - self.more_pill_info.r_max
                local idx = math.floor(rel_x / self.more_pill_info.pitch + 0.5) + 1
                idx = math.max(1, math.min(self.more_pill_info.nb, idx))
                if idx ~= self.more_page then
                    self.more_page = idx
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
    self:_syncPeek()
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
    if self._fl_dirty then saveLightNow() end
    local typo_changed = self._typo_changed
    self:applyPendingTypography()

    local to_free = {
        self.icon_warehouse, self.icon_wifi,
        self.icon_chevron_right,
        self.tw_check,
        self.icon_search, self.icon_rotate,
        self.icon_col_one, self.icon_col_two, self.icon_view_page, self.icon_view_cont,
        self.icon_more, self.icon_pin,
        self.icon_chev_left, self.icon_star, self.icon_star_on,
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

    -- Si el scrubber estaba escondido (pestaña Aa), vuelve entero
    self:_releasePeek()

    if typo_changed then
        if s then
            -- MODO A: Se abrió desde el Page Scrubber (Grid / Split / Simple)
            self:_regenScrubber()
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
    elseif not self._suppress_close_dirty then
        local dirty_geom = expandRect(self.popup_rect, scale(8))
        if s and not s._closing then
            UIManager:setDirty(s, function() return "ui", dirty_geom end)
        elseif ui then
            UIManager:setDirty(ui, function() return "ui", dirty_geom end)
        else
            UIManager:setDirty(nil, "ui", dirty_geom)
        end
    end
end

return ScrubberMenu

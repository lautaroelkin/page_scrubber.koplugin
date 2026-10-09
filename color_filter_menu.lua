--[[
    page_scrubber.koplugin/color_filter_menu.lua
    Menú desplegable (estilo popup de ajustes) para filtrar Destacados / Notas por color.
    Cada fila: círculo pintado con el color + (cantidad) + nombre del color.
]]--

local Device         = require("device")
local Blitbuffer     = require("ffi/blitbuffer")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")

local Screen = Device.screen

-- Mismos tonos que usa KOReader para los colores de resaltado (por si colorFromName no existe)
local COLOR_HEX = {
    red    = "#FF3300",
    orange = "#FF8800",
    yellow = "#FFFF33",
    green  = "#00AA66",
    olive  = "#88FF77",
    cyan   = "#00FFEE",
    blue   = "#0066FF",
    purple = "#EE00FF",
    gray   = "#808080",
}

local _color_cache = {}

local function resolveColor(name)
    if _color_cache[name] then return _color_cache[name] end
    local c

    -- 1) Obtener el código hexadecimal. KOReader almacena estos códigos en Blitbuffer.HIGHLIGHT_COLORS
    local color_code = Blitbuffer.HIGHLIGHT_COLORS and Blitbuffer.HIGHLIGHT_COLORS[name]

    -- Si no está en las constantes nativas, usamos el COLOR_HEX original (asegurando el formato "#RRGGBB")
    if not color_code and COLOR_HEX and COLOR_HEX[name] then
        color_code = COLOR_HEX[name]
        if not color_code:match("^#") then
            color_code = "#" .. color_code
        end
    end

    -- 2) Renderizar el color real usando la función nativa que utiliza el módulo de resaltados
    if color_code and Blitbuffer.colorFromString then
        local ok, col = pcall(Blitbuffer.colorFromString, color_code)
        if ok and col then c = col end
    end

    -- 3) Fallback a gris puro idéntico al de readerhighlight.lua
    if not c or name == "gray" then
        if Blitbuffer.gray then
            -- 0.2 es el factor de aclarado por defecto usado en KOReader
            local ok, col = pcall(Blitbuffer.gray, 0.2)
            if ok and col then c = col end
        end
    end

    c = c or Blitbuffer.COLOR_GRAY
    _color_cache[name] = c
    return c
end

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

-- Motor de dibujado de 32-bits exclusivo para conservar la forma del círculo a todo color
local function paintCornerRectRGB32(bb, x, y, w, h, r, color)
    if w <= 0 or h <= 0 then return end
    r = math.min(r, math.floor(w / 2), math.floor(h / 2))
    
    local function paint(px, py, pw, ph)
        if bb.blendRectRGB32 then bb:blendRectRGB32(px, py, pw, ph, color)
        elseif bb.paintRectRGB32 then bb:paintRectRGB32(px, py, pw, ph, color)
        else bb:paintRect(px, py, pw, ph, color) end
    end

    if r <= 0 then paint(x, y, w, h); return end
    paint(x + r, y, w - 2*r, h)
    paint(x, y + r, r, math.max(1, h - 2*r))
    paint(x + w - r, y + r, r, math.max(1, h - 2*r))
    for j = 0, r - 1 do
        local arc = math.ceil(math.sqrt(r*r - (r-j-0.5)*(r-j-0.5)))
        if arc > 0 then
            paint(x + r - arc, y + j, arc, 1)
            paint(x + w - r,   y + j, arc, 1)
            paint(x + r - arc, y + h - 1 - j, arc, 1)
            paint(x + w - r,   y + h - 1 - j, arc, 1)
        end
    end
end

-- Círculo prolijo: aro (ring_color en 8-bits) + relleno del color elegido (inyectado en 32-bits)
local function paintDot(bb, x, y, d, key, ring_color, ring)
    ring = ring or math.max(2, math.floor(d / 10))
    
    -- El anillo exterior usa dibujado normal porque es blanco/negro
    paintRoundRect(bb, x, y, d, d, math.floor(d / 2), ring_color)
    
    local inner = d - ring * 2
    if inner > 0 then
        local c = resolveColor(key)
        if bb.blendRectRGB32 or bb.paintRectRGB32 then
            -- Si la pantalla admite color, puenteamos la tinta electrónica
            paintCornerRectRGB32(bb, x + ring, y + ring, inner, inner, math.floor(inner / 2), c)
        else
            -- Dispositivos que son realmente blanco y negro
            paintRoundRect(bb, x + ring, y + ring, inner, inner, math.floor(inner / 2), c)
        end
    end
end

local ColorFilterMenu = InputContainer:extend({
    scrubber_ui = nil,
    anchor      = nil,   -- Geom de la pestaña desde donde se despliega
    center_rect = nil,   -- Si se da, el menú se centra dentro de este rectángulo (en vez de usar anchor)
    align_bottom = nil,  -- Si se da (y hay center_rect), el borde inferior del menú queda en esta coordenada Y
    items       = nil,   -- { { key = "red", name = "Rojo", count = 3 }, ... }
    selected    = nil,   -- key del color activo (o nil)
    on_select   = nil,   -- function(key)
})

function ColorFilterMenu:init()
    local S = (self.scrubber_ui and self.scrubber_ui.S) or function(v) return Screen:scaleBySize(v) end
    self.S = S
    local sw, sh = Screen:getWidth(), Screen:getHeight()

    self.is_modal = true
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    -- FILTER_K achica todo el menu de filtro (tamanos y fuente); 1.0 = tamano anterior.
    -- El contorno (border/ring) se mantiene en S(2) para que no cambie el grosor de linea.
    local FILTER_K = 0.8
    local function F(v) return math.max(1, math.floor(S(v) * FILTER_K + 0.5)) end

    self.border   = S(2)
    self.radius   = F(16)
    self.row_h    = F(40)
    self.pad      = F(14)
    self.circle_d = F(22)
    self.ring     = S(2)
    self.gap      = F(10)
    self.check_w  = F(18)

    local fsz = (self.scrubber_ui and self.scrubber_ui.S_BOTTOM_GRAY) or S(14)
    fsz = math.max(8, math.floor(fsz * FILTER_K + 0.5))
    self.face = Font:getFace("cfont", fsz)

    local max_cnt_w, max_name_w = 0, 0
    for _, it in ipairs(self.items or {}) do
        it.count_text = "(" .. tostring(it.count or 0) .. ")"
        local t1 = TextWidget:new{ text = it.count_text, face = self.face }
        local t2 = TextWidget:new{ text = it.name or it.key, face = self.face }
        max_cnt_w  = math.max(max_cnt_w,  t1:getSize().w)
        max_name_w = math.max(max_name_w, t2:getSize().w)
        t1:free(); t2:free()
    end
    self.cnt_col_w = max_cnt_w

    local content_w = self.pad + self.circle_d + self.gap + max_cnt_w + self.gap + max_name_w
                      + self.gap + self.check_w + self.pad
    local w = content_w + self.border * 2
    local h = #(self.items or {}) * self.row_h + self.border * 2

    local a = self.anchor or Geom:new{ x = S(12), y = S(60), w = 0, h = 0 }
    local x = a.x
    local y = a.y + a.h + S(6)
    if x + w > sw - S(8) then x = sw - w - S(8) end
    if x < S(8) then x = S(8) end
    if y + h > sh - S(10) then
        local above = a.y - h - S(6)
        if above >= S(8) then y = above else y = math.max(S(8), sh - h - S(10)) end
    end

    -- Modo centrado: se acomoda en el medio del rectángulo indicado (sin salirse de la pantalla)
    local cr = self.center_rect
    if cr then
        x = cr.x + math.floor((cr.w - w) / 2)
        -- Un poco más abajo que el centro exacto (65% del espacio libre queda arriba)
        y = cr.y + math.floor((cr.h - h) * 0.65)
        if w > cr.w then x = cr.x end   -- si no entra, se alinea al borde izquierdo de la zona libre
        if x + w > sw - S(8) then x = sw - w - S(8) end
        if x < cr.x and w <= cr.w then x = cr.x end
        if x < S(8) then x = S(8) end
        if self.align_bottom then y = self.align_bottom - h end
        if y + h > sh - S(10) then y = sh - h - S(10) end
        if y < S(8) then y = S(8) end
    end

    self.popup_rect = Geom:new{ x = x, y = y, w = w, h = h }

    self.row_dimens = {}
    local cy = y + self.border
    for _, it in ipairs(self.items or {}) do
        table.insert(self.row_dimens, {
            item = it,
            dimen = Geom:new{ x = x + self.border, y = cy, w = w - self.border * 2, h = self.row_h },
        })
        cy = cy + self.row_h
    end

    if Device:isTouchDevice() then
        self.ges_events = {
            Tap   = { GestureRange:new{ ges = "tap",   range = self.dimen } },
            Hold  = { GestureRange:new{ ges = "hold",  range = self.dimen } },
            Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
    end
end

function ColorFilterMenu:onHold() return true end
function ColorFilterMenu:onSwipe() return true end

function ColorFilterMenu:paintTo(bb, x, y)
    local r = self.popup_rect
    local border = self.border

    paintRoundRect(bb, r.x, r.y, r.w, r.h, self.radius, Blitbuffer.COLOR_BLACK)
    paintRoundRect(bb, r.x + border, r.y + border, r.w - border * 2, r.h - border * 2,
        math.max(1, self.radius - border), Blitbuffer.COLOR_WHITE)

    for idx, rd in ipairs(self.row_dimens or {}) do
        local it = rd.item
        local ry = rd.dimen.y
        local rh = rd.dimen.h

        if idx > 1 then
            bb:paintRect(r.x + border, ry, r.w - border * 2, 1, Blitbuffer.COLOR_BLACK)
        end

        -- Círculo prolijo: aro negro + relleno del color
        local d = self.circle_d
        local cx = r.x + border + self.pad
        local cy = ry + math.floor((rh - d) / 2)
        paintDot(bb, cx, cy, d, it.key, Blitbuffer.COLOR_BLACK, self.ring)

        -- (cantidad)
        local text_x = cx + d + self.gap
        local tw_cnt = TextWidget:new{ text = it.count_text, face = self.face, fgcolor = Blitbuffer.COLOR_BLACK }
        local csz = tw_cnt:getSize()
        tw_cnt:paintTo(bb, text_x, ry + math.floor((rh - csz.h) / 2))
        tw_cnt:free()

        -- nombre del color
        local name_x = text_x + self.cnt_col_w + self.gap
        local tw_name = TextWidget:new{ text = it.name or it.key, face = self.face, fgcolor = Blitbuffer.COLOR_BLACK }
        local nsz = tw_name:getSize()
        tw_name:paintTo(bb, name_x, ry + math.floor((rh - nsz.h) / 2))
        tw_name:free()

        -- tilde en el color activo
        if self.selected and it.key == self.selected then
            local tw_chk = TextWidget:new{ text = "✓", face = self.face, bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
            local ksz = tw_chk:getSize()
            tw_chk:paintTo(bb, r.x + r.w - border - self.pad - ksz.w, ry + math.floor((rh - ksz.h) / 2))
            tw_chk:free()
        end
    end
end

function ColorFilterMenu:onTap(arg1, arg2)
    local ges = arg2 or arg1
    if not ges or not ges.pos then return true end

    if not ges.pos:intersectWith(self.popup_rect) then
        UIManager:close(self)
        return true
    end

    for _, rd in ipairs(self.row_dimens or {}) do
        if ges.pos:intersectWith(rd.dimen) then
            local key = rd.item.key
            UIManager:close(self)
            if self.on_select then self.on_select(key) end
            return true
        end
    end
    return true
end

function ColorFilterMenu:onCloseWidget()
    if self.scrubber_ui then
        self.scrubber_ui._color_menu_is_open = false
        if self.scrubber_ui._tab_arrow_tab_dimen then
            UIManager:setDirty(self.scrubber_ui, "ui", self.scrubber_ui._tab_arrow_tab_dimen)
        end
        UIManager:setDirty(self.scrubber_ui, "ui")
    end
    if self.scrubber_ui and self.scrubber_ui.ui then
        UIManager:setDirty(self.scrubber_ui.ui, "ui")
    else
        UIManager:setDirty(nil, "ui")
    end
end


-- =====================================================================
-- Menú de círculos de color (grilla 3x3): se usa para cambiar el color de un highlight.
-- Mismo diseño compacto y dimensiones exactas del selector nativo de KOReader.
-- =====================================================================
local ColorSwatchMenu = InputContainer:extend({
    scrubber_ui  = nil,
    items        = nil,   -- { { key = "red", name = "Rojo" }, ... }
    selected     = nil,   -- key del color actual (se remarca)
    on_select    = nil,   -- function(key)
    center_rect  = nil,   
    align_bottom = nil,   
    anchor_above = nil,   -- Geom del boton: el menu aparece encima, con su borde derecho alineado al del boton
})

function ColorSwatchMenu:init()
    -- Tamano: depende de la escala del plugin (ui_scale, via scrubber_ui.S) multiplicada por
    -- MENU_K, que achica TODO el menu en bloque sin alterar sus proporciones.
    -- Subir MENU_K lo agranda, bajarlo lo achica (1.0 = tamano del floating_dict a escala 1).
    local MENU_K = 0.50
    local base_S = (self.scrubber_ui and self.scrubber_ui.S) or function(v) return Screen:scaleBySize(v) end
    local S = function(v) return base_S(v * MENU_K) end
    self.S = S
    local sw, sh = Screen:getWidth(), Screen:getHeight()

    self.is_modal = true
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    local clean = {}
    for _, it in ipairs(self.items or {}) do
        if type(it) == "table" and type(it.key) == "string" then table.insert(clean, it) end
    end
    self.items = clean

    local cols = 3
    local rows = math.max(1, math.ceil(#clean / cols))
    self.cols = cols
    
    -- Mismas proporciones que ColorSwatchPopup de floating_dict.lua
    self.radius   = S(16)
    self.pad      = S(14)
    self.circle_d = S(54)
    self.border   = S(2)
    self.top_gap  = S(4)   -- aire arriba del circulo
    self.text_gap = S(6)   -- aire entre circulo y nombre

    self.face = Font:getFace("cfont", S(17))

    -- El alto/ancho de celda se calcula con el texto REAL (no con numeros fijos): asi el nombre
    -- nunca invade el circulo de abajo, sea cual sea el DPI o la escala del plugin.
    local text_h, max_name_w = 0, 0
    for _, it in ipairs(clean) do
        local tw = TextWidget:new{ text = tostring(it.name or it.key), face = self.face, bold = true }
        local sz = tw:getSize()
        tw:free()
        if sz.h > text_h then text_h = sz.h end
        if sz.w > max_name_w then max_name_w = sz.w end
    end
    self.cell_w = math.max(S(104), max_name_w + S(12))
    self.cell_h = math.max(S(98), self.top_gap + self.circle_d + self.text_gap + text_h + S(12))

    local w = cols * self.cell_w + self.pad * 2
    local h = rows * self.cell_h + self.pad * 2

    local x = math.floor((sw - w) / 2)
    local y = math.floor((sh - h) / 2)

    local cr = self.center_rect
    if cr then
        if w <= cr.w then
            x = cr.x + math.floor((cr.w - w) / 2)
        else
            x = math.max(cr.x, math.floor((sw - w) / 2))
        end
        y = cr.y + math.floor((cr.h - h) * 0.65)
        if self.align_bottom then y = self.align_bottom - h end
    end
    -- Anclado al boton: encima de el, con el borde derecho alineado al del boton (crece hacia la izquierda)
    local ab = self.anchor_above
    if ab then
        x = ab.x + ab.w - w
        -- El circulo esta centrado dentro de la barra de botones (~24% de su alto de margen):
        -- se sube el menu por encima de TODA la barra para no taparla.
        y = ab.y - math.floor(ab.h * 0.24) - S(12) - h
    end
    if x + w > sw - S(8) then x = sw - w - S(8) end
    if x < S(8) then x = S(8) end
    if y + h > sh - S(10) then y = sh - h - S(10) end
    if y < S(8) then y = S(8) end

    self.popup_rect = Geom:new{ x = x, y = y, w = w, h = h }

    self.cells = {}
    for i, it in ipairs(clean) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        self.cells[i] = {
            key  = it.key,
            name = tostring(it.name or it.key),
            dimen = Geom:new{
                x = x + self.pad + col * self.cell_w,
                y = y + self.pad + row * self.cell_h,
                w = self.cell_w, h = self.cell_h,
            },
        }
    end

    if Device:isTouchDevice() then
        self.ges_events = {
            Tap   = { GestureRange:new{ ges = "tap",   range = self.dimen } },
            Hold  = { GestureRange:new{ ges = "hold",  range = self.dimen } },
            HoldRelease = { GestureRange:new{ ges = "hold_release", range = self.dimen } },
            Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
    end
end

function ColorSwatchMenu:onHold() return true end
function ColorSwatchMenu:onHoldRelease() return true end
function ColorSwatchMenu:onSwipe() return true end

function ColorSwatchMenu:paintTo(bb, x, y)
    local r = self.popup_rect
    local border = self.border

    paintRoundRect(bb, r.x, r.y, r.w, r.h, self.radius, Blitbuffer.COLOR_BLACK)
    paintRoundRect(bb, r.x + border, r.y + border, r.w - border * 2, r.h - border * 2,
        math.max(1, self.radius - border), Blitbuffer.COLOR_WHITE)

    for _, cell in ipairs(self.cells or {}) do
        local d = self.circle_d
        local cx = cell.dimen.x + math.floor((cell.dimen.w - d) / 2)
        local cy = cell.dimen.y + self.top_gap
        local is_current = (self.selected ~= nil and cell.key == self.selected)
        local ring = is_current and self.S(5) or self.S(2)

        paintDot(bb, cx, cy, d, cell.key, Blitbuffer.COLOR_BLACK, ring)

        local tw = TextWidget:new{ text = cell.name, face = self.face, bold = is_current, fgcolor = Blitbuffer.COLOR_BLACK }
        local tsz = tw:getSize()
        
        tw:paintTo(bb, cell.dimen.x + math.floor((cell.dimen.w - tsz.w) / 2), cy + d + self.text_gap)
        tw:free()
    end
end

function ColorSwatchMenu:onTap(arg1, arg2)
    local ges = arg2 or arg1
    if not ges or not ges.pos then return true end

    if not ges.pos:intersectWith(self.popup_rect) then
        UIManager:close(self)
        return true
    end

    for _, cell in ipairs(self.cells or {}) do
        if ges.pos:intersectWith(cell.dimen) then
            local key = cell.key
            UIManager:close(self)
            if self.on_select then self.on_select(key) end
            return true
        end
    end
    return true
end

function ColorSwatchMenu:onCloseWidget()
    if self.scrubber_ui then
        UIManager:setDirty(self.scrubber_ui, "ui")
    end
    if self.scrubber_ui and self.scrubber_ui.ui then
        UIManager:setDirty(self.scrubber_ui.ui, "ui")
    else
        UIManager:setDirty(nil, "ui")
    end
end

ColorFilterMenu.Swatch = ColorSwatchMenu

ColorFilterMenu.resolveColor = resolveColor
ColorFilterMenu.paintDot = paintDot

return ColorFilterMenu

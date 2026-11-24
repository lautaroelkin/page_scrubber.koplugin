--[[
Page Scrubber: cursores de selección.

Mientras seleccionás texto (mantener apretado y arrastrar) aparece un cursor en cada extremo
de la selección: una barrita fina pegada al borde del texto y un aro, arriba del inicio y
abajo del final. Con el menú de selección abierto se pueden arrastrar para ajustar la selección.

La idea (cursores en los extremos + ajustar arrastrando) está inspirada en FingerTips; el dibujo
es propio (barra + aro en vez de barra + círculo lleno) y no hace zoom de la página.

Cómo se engancha:
  * Dibujo: "view module" de ReaderView, se pinta después de la página y de los highlights.
  * Estado: envoltorios finos sobre la instancia de ReaderHighlight del libro abierto (onHold,
    onHoldPan, onHoldRelease, clear). Los originales siguen haciendo toda la selección; esto
    solo dibuja encima.
  * Ajuste con el dedo: lo hace FloatingActionMenu (floating_dict.lua) con handleAt / beginDrag /
    moveDrag / endDrag de este módulo.

Fases (self.phase):
  nil       nada visible
  "drag"    el usuario está seleccionando (dedo apretado)
  "menu"    el menú de selección está abierto
  "handle"  se está arrastrando un cursor
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Screen = Device.screen

-- Segundos que el cursor sigue visible tras soltar el dedo esperando que se abra la tarjeta o el menú
local RELEASE_GRACE = 1.2

local SelectionCursor = {}
SelectionCursor.__index = SelectionCursor

-- ==========================================
-- CAJAS DE LA SELECCIÓN (una por línea)
-- ==========================================

-- Rectángulos en pantalla de la selección, uno por línea, de arriba hacia abajo.
-- sel: tabla de selección de KOReader (selected_text) o una copia de una anotación
-- (solo trae pos0 / pos1: en ese caso las cajas se piden al motor del documento).
function SelectionCursor.selectionLines(ui, sel, page_hint)
    if not (ui and ui.view and type(sel) == "table") then return nil end
    local doc = ui.document
    local has_pages = ui.paging ~= nil
    local sboxes = sel.sboxes

    if not has_pages and doc and doc.getScreenBoxesFromPositions
            and type(sel.pos0) == "string" and type(sel.pos1) == "string"
            and (not sboxes or #sboxes <= 1) then
        -- Sin cajas (anotación guardada) o con una sola caja: una palabra cortada por el fin de línea
        -- (Some-|where) viene como una caja que cubre las dos líneas y el espacio entre ellas;
        -- crengine la devuelve línea por línea si se la pide así.
        local ok, per_line = pcall(doc.getScreenBoxesFromPositions, doc, sel.pos0, sel.pos1, true)
        if ok and type(per_line) == "table" and #per_line > 0 then sboxes = per_line end
    end
    if (not sboxes or #sboxes == 0) and has_pages then sboxes = sel.pboxes end
    if type(sboxes) ~= "table" or #sboxes == 0 then return nil end

    local page = page_hint
    if not page and type(sel.pos0) == "table" then page = sel.pos0.page end

    local boxes = {}
    for i = 1, #sboxes do
        local b = sboxes[i]
        local r = b
        if has_pages and page then
            local ok, converted = pcall(ui.view.pageToScreenTransform, ui.view, page, b)
            if ok and converted then r = converted end
        end
        if type(r) == "table" and r.w and r.h and r.w > 0 and r.h > 0 then
            table.insert(boxes, Geom:new{ x = r.x, y = r.y, w = r.w, h = r.h })
        end
    end
    if #boxes == 0 then return nil end

    -- Una línea puede venir en varios pedazos (estilos, links...): los que comparten línea se unen.
    table.sort(boxes, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        return a.x < b.x
    end)
    local lines = {}
    for i = 1, #boxes do
        local b = boxes[i]
        local last = lines[#lines]
        local b_mid = b.y + b.h / 2
        if last and b_mid > last.y and b_mid < last.y + last.h then
            lines[#lines] = last:combine(b)
        else
            table.insert(lines, b)
        end
    end
    return lines
end

local function averageHeight(lines)
    local h = 0
    for i = 1, #lines do h = h + lines[i].h end
    return h / #lines
end

-- ==========================================
-- GEOMETRÍA Y DIBUJO DE LOS CURSORES
-- ==========================================

-- Radio del cabezal de un cursor para una selección con esas líneas (lo usa también el menú
-- flotante para dejar aire entre el cursor y el menú).
function SelectionCursor.knobRadius(lines)
    return math.max(Screen:scaleBySize(5.5), math.floor(averageHeight(lines) * 0.24 + 0.5))
end

function SelectionCursor.geometry(lines)
    local first, last = lines[1], lines[#lines]
    local line_h = averageHeight(lines)
    local r = SelectionCursor.knobRadius(lines)
    local bar_w = math.max(2, math.floor(Screen:scaleBySize(2.2) + 0.5))
    local halo = math.max(1, math.floor(Screen:scaleBySize(1.5) + 0.5))
    local stem_ext = math.max(1, math.floor(Screen:scaleBySize(1.5) + 0.5))
    -- Cuello: el palito se abre con una curva (filete cóncavo de radio f, tangente al palito y al aro) hasta
    -- tocar el cabezal. dy = distancia del centro del aro al punto donde el palito termina de abrirse.
    local f = math.max(2, math.floor(r * 0.9 + 0.5))   -- 0.9: curva suave; más alto = cuello más largo y abierto
    local half = bar_w / 2
    local dy = math.sqrt(math.max(0, (r + f) * (r + f) - (half + f) * (half + f)))

    local start_top = first.y - stem_ext
    local start_bot = first.y + first.h + stem_ext
    local stop_top = last.y - stem_ext
    local stop_bot = last.y + last.h + stem_ext

    local g = {
        line_h = line_h,
        r = r,
        bar_w = bar_w,
        halo = halo,
        neck_f = f,
        neck_dy = dy,
        start = { x = first.x, top = start_top, bottom = start_bot, knob_y = start_top - dy },
        stop = { x = last.x + last.w, top = stop_top, bottom = stop_bot, knob_y = stop_bot + dy },
    }
    local function rect(hd)
        local pad_x = r + halo + 3
        local pad_y = halo + 3
        local top = math.min(hd.top, hd.knob_y - r)
        local bottom = math.max(hd.bottom, hd.knob_y + r)
        return Geom:new{
            x = hd.x - pad_x,
            y = top - pad_y,
            w = 2 * pad_x,
            h = (bottom - top) + 2 * pad_y,
        }
    end
    g.rect_start, g.rect_stop = rect(g.start), rect(g.stop)
    g.key = string.format("%d,%d,%d,%d,%d,%d", g.start.x, g.start.top, g.start.bottom,
        g.stop.x, g.stop.top, g.stop.bottom)
    return g
end

-- Una fila del cuello: el palito más ancho en `extra` píxeles (con un píxel gris de borde si hay fracción)
local function neckRow(bb, bar_x, bar_w, y, extra, color, antialias)
    local full = math.floor(extra)
    bb:paintRect(bar_x - full, y, bar_w + 2 * full, 1, color)
    if antialias then
        local frac = extra - full
        if frac > 0.2 then
            local gray = Blitbuffer.Color8(math.floor(255 * (1 - frac)))
            bb:paintRect(bar_x - full - 1, y, 1, 1, gray)
            bb:paintRect(bar_x + bar_w + full, y, 1, 1, gray)
        end
    end
end

-- La curva que une el palito con el aro. up = true: el aro está arriba del palito (cursor de inicio).
local function drawNeck(bb, g, hd, bar_x, dy_screen, up, color, halo)
    local r, f = g.r, g.neck_f
    local half = g.bar_w / 2
    local cy = hd.knob_y + dy_screen                 -- centro del aro
    local fc_y = up and hd.top + dy_screen or hd.bottom + dy_screen    -- centro del filete (a la altura del palito)
    -- Punto de tangencia con el aro: sobre la recta que une los dos centros
    local t_y = cy + (fc_y - cy) * r / (r + f)
    local y_from, y_to
    if up then y_from, y_to = math.ceil(t_y), math.floor(fc_y) else y_from, y_to = math.ceil(fc_y), math.floor(t_y) end
    for y = y_from, y_to do
        local d = math.abs(fc_y - (y + 0.5))
        if d <= f then
            local extra = f - math.sqrt(f * f - d * d)
            neckRow(bb, bar_x, g.bar_w, y, extra + halo, color, halo == 0 and color ~= Blitbuffer.COLOR_WHITE)
        end
    end
end

local function drawCursors(bb, g, dx, dy)
    local halo = g.halo or 1
    for idx, hd in ipairs({ g.start, g.stop }) do
        local up = idx == 1   -- el cursor de inicio tiene el aro arriba; el de fin, abajo
        local cx = math.floor(hd.x + dx + 0.5)
        local cy = math.floor(hd.knob_y + dy + 0.5)
        local bar_x = math.floor(hd.x + dx - g.bar_w / 2 + 0.5)
        local bar_y = math.floor(hd.top + dy)
        local bar_h = math.max(1, math.floor(hd.bottom - hd.top))

        -- Halo blanco de separación sobre texto o resaltados invertidos en E-ink
        bb:paintRect(bar_x - halo, bar_y, g.bar_w + halo * 2, bar_h, Blitbuffer.COLOR_WHITE)
        bb:paintCircle(cx, cy, g.r + halo, Blitbuffer.COLOR_WHITE)
        drawNeck(bb, g, hd, bar_x, dy, up, Blitbuffer.COLOR_WHITE, halo)

        -- Barra vertical, cabezal sólido (estilo pin Apple / Kindle) y la curva que los une
        bb:paintRect(bar_x, bar_y, g.bar_w, bar_h, Blitbuffer.COLOR_BLACK)
        bb:paintCircle(cx, cy, g.r, Blitbuffer.COLOR_BLACK)
        drawNeck(bb, g, hd, bar_x, dy, up, Blitbuffer.COLOR_BLACK, 0)
    end
end

-- ==========================================
-- OBJETO POR LIBRO
-- ==========================================

-- ui: ReaderUI del libro abierto. is_enabled: function() -> bool (se consulta en vivo, así activar o
-- desactivar el ajuste no necesita reiniciar nada).
function SelectionCursor.new(ui, is_enabled)
    local self = setmetatable({}, SelectionCursor)
    self.ui = ui
    self.is_enabled = is_enabled or function() return true end
    self.phase = nil
    self.geo = nil
    self.key = nil
    -- function() que cierra un menú de selección que haya quedado abierto (la asigna floating_dict)
    self.on_new_selection = nil
    return self
end

function SelectionCursor:isEnabled()
    local ok, v = pcall(self.is_enabled)
    return ok and v == true
end

function SelectionCursor:getLines()
    local hl = self.ui and self.ui.highlight
    if not hl then return nil end
    -- Con el menú de un highlight abierto, los cursores marcan los bordes de ese highlight (self.annotation)
    -- hasta que se empieza a arrastrar uno; desde ahí vale la selección viva de ReaderHighlight.
    if self.annotation and self.phase ~= "handle" then
        local page = type(self.annotation.pos0) == "table" and self.annotation.pos0.page or nil
        return SelectionCursor.selectionLines(self.ui, self.annotation, page)
    end
    local sel = hl.selected_text
    if not (hl.hold_pos and type(sel) == "table") then return nil end
    return SelectionCursor.selectionLines(self.ui, sel, hl.hold_pos.page)
end

function SelectionCursor:_dirtyTarget()
    local hl = self.ui and self.ui.highlight
    return (hl and hl.dialog) or self.ui
end

-- Recalcula qué hay que mostrar y pide refrescar solo las zonas que cambiaron.
function SelectionCursor:update()
    local g
    if self.phase and self:isEnabled() then
        local lines = self:getLines()
        if lines then g = SelectionCursor.geometry(lines) end
    end
    local new_key = g and g.key or nil
    if new_key == self.key then return end
    local old = self.geo
    self.geo, self.key = g, new_key
    local target = self:_dirtyTarget()
    if not target then return end
    for _, geo in ipairs({ old or false, g or false }) do
        if geo then
            UIManager:setDirty(target, "ui", geo.rect_start)
            UIManager:setDirty(target, "ui", geo.rect_stop)
        end
    end
end

function SelectionCursor:setPhase(phase)
    self._release_token = nil   -- cualquier cambio de fase cancela el apagado pendiente de onHoldRelease
    self.phase = phase
    if not phase then
        self.annotation = nil
        self:restoreDragStyle()
    end
    self:update()
end

-- Lo llama ReaderView después de dibujar la página y los highlights.
function SelectionCursor:paintTo(bb, x, y)
    if not self.phase or not self:isEnabled() then return end
    local lines = self:getLines()
    if not lines then return end
    local ok, err = pcall(function()
        -- Vista previa del highlight que se está ajustando (EPUB), con su estilo y su color
        local a = self.annotation
        if a and self._doc_wrapped and self.phase == "handle" then
            local hl = self.ui.highlight
            local drawer = self._drag_drawer or "lighten"
            local color
            if drawer ~= "invert" and hl.getHighlightColor then color = hl:getHighlightColor(a.color or "gray") end
            for _, line in ipairs(lines) do
                self.ui.view:drawHighlightRect(bb, x or 0, y or 0, line, drawer, color)
            end
        end
        drawCursors(bb, SelectionCursor.geometry(lines), x or 0, y or 0)
    end)
    if not ok then logger.warn("PageScrubber: no se pudo dibujar el cursor:", err) end
end

-- ==========================================
-- AJUSTE ARRASTRANDO UN CURSOR
-- ==========================================

-- El cursor bajo pos, si hay: { which = "start" | "stop", dx, dy }, donde (dx, dy) lleva desde el
-- dedo hasta el borde del texto que marca ese cursor (así el cursor conserva su distancia al dedo).
function SelectionCursor:handleAt(pos)
    if self.phase ~= "menu" or not pos then return nil end
    local lines = self:getLines()
    if not lines then return nil end
    local g = SelectionCursor.geometry(lines)
    local reach = math.max(Screen:scaleBySize(26), g.line_h)
    local best, best_d
    for _, which in ipairs({ "start", "stop" }) do
        local hd = g[which]
        local halo = g.halo or 0
        local y0 = math.min(hd.top, hd.knob_y - g.r - halo)
        local y1 = math.max(hd.bottom, hd.knob_y + g.r + halo)
        local ddx = pos.x - hd.x
        local ddy = 0
        if pos.y < y0 then ddy = y0 - pos.y elseif pos.y > y1 then ddy = pos.y - y1 end
        local d = math.sqrt(ddx * ddx + ddy * ddy)
        if d <= reach and (not best_d or d < best_d) then best, best_d = which, d end
    end
    if not best then return nil end
    local hd = g[best]
    local ex = best == "start" and hd.x + 1 or hd.x - 1
    local ey = math.floor((hd.top + hd.bottom) / 2)
    return { which = best, dx = ex - pos.x, dy = ey - pos.y }
end

-- Mientras se arrastra un borde de un highlight, la selección viva se dibuja con el estilo y el color de
-- ese highlight. ReaderView:drawTempHighlight dibuja la selección con view.highlight.temp_drawer (por
-- defecto "lighten") y solo usa el color si el ajuste "highlight_selection_use_highlight_color" está
-- activo (con saved_color y siempre que saved_drawer no sea "invert"). Se fija todo eso mientras dura el
-- arrastre y se restaura en restoreDragStyle.
local COLOR_SETTING = "highlight_selection_use_highlight_color"

function SelectionCursor:applyDragStyle()
    local hl = self.ui and self.ui.highlight
    local vh = hl and hl.view and hl.view.highlight
    local a = self.annotation
    if not (vh and a) or self._saved_style then return end
    local drawer = a.drawer or "lighten"
    self._drag_drawer = drawer
    -- El highlight original se oculta mientras se arrastra (KOReader solo dibuja los que tienen drawer):
    -- así no queda su dibujo viejo debajo ni se cancela con la vista previa (invert). Vuelve en restoreDragStyle.
    self._hidden_item, self._hidden_drawer = a, a.drawer
    a.drawer = nil
    vh.page_boxes = {}
    self._saved_style = {
        temp_drawer = vh.temp_drawer, saved_drawer = vh.saved_drawer, saved_color = vh.saved_color,
        use_color = G_reader_settings and G_reader_settings:readSetting(COLOR_SETTING),
    }
    vh.temp_drawer = drawer
    vh.saved_drawer = drawer
    if a.color then vh.saved_color = a.color end
    if G_reader_settings then G_reader_settings:saveSetting(COLOR_SETTING, true) end

    -- EPUB (crengine): la selección en pantalla la dibuja el motor del documento, con su color fijo, al pedir
    -- el texto con getTextFromPositions(pos0, pos1). Con el tercer argumento (do_not_draw_selection) no
    -- la dibuja, y el subrayado de vista previa lo pinta paintTo con el estilo del highlight.
    local doc = self.ui.document
    if not self.ui.paging and doc and not self._doc_wrapped then
        local own = rawget(doc, "getTextFromPositions")
        local orig = doc.getTextFromPositions
        if type(orig) == "function" then
            self._doc_wrapped = { own = own }
            doc.getTextFromPositions = function(d, pos0, pos1, ...)
                return orig(d, pos0, pos1, true)
            end
        end
    end
end

function SelectionCursor:restoreDragStyle()
    local hidden = self._hidden_item
    if hidden then
        hidden.drawer = self._hidden_drawer
        self._hidden_item, self._hidden_drawer = nil, nil
        local hl0 = self.ui and self.ui.highlight
        local vh0 = hl0 and hl0.view and hl0.view.highlight
        if vh0 then vh0.page_boxes = {} end
    end
    self._drag_drawer = nil
    local wrapped = self._doc_wrapped
    if wrapped then
        self._doc_wrapped = nil
        local doc = self.ui.document
        if doc then doc.getTextFromPositions = wrapped.own end
    end
    local saved = self._saved_style
    if not saved then return end
    self._saved_style = nil
    local hl = self.ui and self.ui.highlight
    local vh = hl and hl.view and hl.view.highlight
    if vh then
        vh.temp_drawer = saved.temp_drawer
        vh.saved_drawer = saved.saved_drawer
        vh.saved_color = saved.saved_color
    end
    if G_reader_settings then
        if saved.use_color == nil then
            G_reader_settings:delSetting(COLOR_SETTING)
        else
            G_reader_settings:saveSetting(COLOR_SETTING, saved.use_color)
        end
    end
end

-- Al arrastrar un cursor, el otro extremo se queda quieto: se lo toma como el punto desde el que
-- KOReader extiende la selección, como si el mantener apretado hubiera empezado ahí.
function SelectionCursor:beginDrag(which)
    local hl = self.ui and self.ui.highlight
    if not hl then return false end
    local lines = self:getLines()
    if not lines then return false end
    local ax, ay
    if which == "stop" then
        local l = lines[1]
        ax, ay = l.x + 1, l.y + l.h / 2
    else
        local l = lines[#lines]
        ax, ay = l.x + l.w - 1, l.y + l.h / 2
    end
    local anchor = self.ui.view:screenToPageTransform(Geom:new{ x = math.floor(ax), y = math.floor(ay), w = 0, h = 0 })
    if not anchor then return false end
    hl.hold_pos = anchor
    -- Editando un highlight: la selección viva arranca siendo una copia de él
    if self.annotation then
        local ok, util = pcall(require, "util")
        if ok then hl.selected_text = util.tableDeepCopy(self.annotation) end
        self:applyDragStyle()
    end
    self:setPhase("handle")
    return true
end

function SelectionCursor:moveDrag(grab, pos)
    local hl = self.ui and self.ui.highlight
    if not (hl and hl.hold_pos and grab and pos) then return end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local x = math.max(0, math.min(sw - 1, math.floor(pos.x + (grab.dx or 0) + 0.5)))
    local y = math.max(0, math.min(sh - 1, math.floor(pos.y + (grab.dy or 0) + 0.5)))
    hl:onHoldPan(nil, { ges = "hold_pan", pos = Geom:new{ x = x, y = y, w = 0, h = 0 } })
end

function SelectionCursor:endDrag()
    local hl = self.ui and self.ui.highlight
    -- El temporizador de "mantener apretado" de KOReader se reinicia con cada cambio de la selección:
    -- se detiene, como lo haría soltar el dedo normalmente.
    if hl and hl._resetHoldTimer then pcall(hl._resetHoldTimer, hl, true) end
    -- Editando un highlight, quien lo llamó guarda el cambio y apaga los cursores
    if self.annotation then return end
    self:setPhase("menu")
end

-- ==========================================
-- ENGANCHE EN READERHIGHLIGHT
-- ==========================================

function SelectionCursor:install()
    local ui = self.ui
    local hl = ui and ui.highlight
    if not hl or hl._ps_cursor_wrapped then return false end
    local view = ui.view
    if not (view and view.registerViewModule) then return false end
    hl._ps_cursor_wrapped = true
    view:registerViewModule("page_scrubber_cursor", self)

    local cursor = self

    -- Las funciones se envuelven en la instancia (no en la clase): queda local al libro abierto, y los
    -- touch zones llaman a hl:onHold() etc., así que pasan por acá.
    local orig_onHold = hl.onHold
    if type(orig_onHold) == "function" then
        hl.onHold = function(this, arg, ges, ...)
            -- Una selección nueva: si quedó un menú de la anterior, se cierra
            if cursor:isEnabled() and cursor.on_new_selection then pcall(cursor.on_new_selection) end
            local ret = orig_onHold(this, arg, ges, ...)
            if cursor:isEnabled() and this.hold_pos and this.selected_text then
                cursor:setPhase("drag")
            end
            return ret
        end
    end

    local orig_onHoldPan = hl.onHoldPan
    if type(orig_onHoldPan) == "function" then
        hl.onHoldPan = function(this, ...)
            local ret = orig_onHoldPan(this, ...)
            if cursor.phase == "drag" or cursor.phase == "handle" then cursor:update() end
            return ret
        end
    end

    local orig_onHoldRelease = hl.onHoldRelease
    if type(orig_onHoldRelease) == "function" then
        hl.onHoldRelease = function(this, ...)
            -- Soltó el dedo. Antes el cursor se apagaba acá y volvía a aparecer cuando se abría la tarjeta del
            -- diccionario o el menú (parpadeaba). Ahora se deja encendido: si algo se abre, toma el cursor con
            -- setPhase("menu") y, como la geometría es la misma, no se repinta nada; si nada lo toma, se apaga
            -- pasado un momento.
            local was_drag = cursor.phase == "drag"
            local ret = orig_onHoldRelease(this, ...)
            if was_drag and cursor.phase == "drag" then
                local token = {}
                cursor._release_token = token
                UIManager:scheduleIn(RELEASE_GRACE, function()
                    if cursor._release_token == token and cursor.phase == "drag" then cursor:setPhase(nil) end
                end)
            end
            return ret
        end
    end

    local orig_clear = hl.clear
    if type(orig_clear) == "function" then
        hl.clear = function(this, ...)
            local ret = orig_clear(this, ...)
            if cursor.phase then cursor:setPhase(nil) end
            return ret
        end
    end
    return true
end

return SelectionCursor

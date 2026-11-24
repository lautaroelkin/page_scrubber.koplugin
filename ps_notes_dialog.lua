--[[
    page_scrubber.koplugin/ps_notes_dialog.lua

    El menú para ESCRIBIR una nota (el "Edit note" de KOReader), con el diseño del plugin:

      · una tarjeta blanca con contorno negro y esquinas redondeadas, pegada arriba del teclado;
      · el texto de la nota en un recuadro gris relleno con esquinas redondeadas;
      · los botones de abajo en las esquinas: Cancel (solo texto) a la izquierda y Save (píldora
        negra) a la derecha; el texto se desplaza con el scroll de KOReader;
      · Paste (inserta el texto subrayado) arriba a la derecha, como el botón "Paste" nativo.

    El texto se escribe con el InputText de KOReader (mismo teclado, mismo cursor, mismo scroll),
    así que solo cambia lo que se ve. Al guardar o cancelar hace exactamente lo mismo que
    ReaderBookmark:setBookmarkNote (copiado de readerbookmark.lua), incluidos los eventos de
    anotaciones, el PDF y el refresco de la lista de marcadores.

      require("ps_notes_dialog").show(bookmark, item_or_index, is_new_note, new_note,
                                      caller_callback, { face = <fuente del texto> })

    Devuelve true si mostró el diálogo; si devuelve false (no hay anotación) quien llama deja el
    diálogo nativo. Lo engancha floating_dict.lua (Reading Pop-Ups > Notes menu > Menu notes).
]]--

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Event          = require("ui/event")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputText      = require("ui/widget/inputtext")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local gettext        = require("gettext")
local logger         = require("logger")
local Kit            = require("svg_picker").kit

-- Teclado de KiKome (ps_keyboard.lua). Si no carga, queda el teclado de KOReader.
local ok_kb, KKKeyboard = pcall(require, "ps_keyboard")
if not ok_kb then
    logger.warn("PageScrubber: no cargó ps_keyboard, se usa el teclado de KOReader:", KKKeyboard)
    KKKeyboard = nil
end

-- Ajuste Reading Pop-Ups > Notes menu > KiKome keyboard (encendido por defecto)
local function useKikomeKeyboard()
    if not KKKeyboard then return false end
    return not (G_reader_settings and G_reader_settings:readSetting("page_scrubber_kikome_keyboard") == false)
end

-- Con el teclado de KiKome el texto lo sigue manejando el InputText de KOReader (cursor, scroll,
-- selección), pero su teclado nunca se muestra: cuando quiere mostrarlo, se lo pide al diálogo.
local KKInput = InputText:extend{}
function KKInput:onShowKeyboard()
    local parent = self.parent
    if parent and parent.showKikomeKeyboard then parent:showKikomeKeyboard() end
    return true
end
function KKInput:onCloseKeyboard() return true end

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local C_FIELD     = Blitbuffer.Color8(0xE8)   -- relleno gris del recuadro del texto
local C_IDLE      = Blitbuffer.Color8(0xDD)   -- botones neutros (igual que ps_sheet)
local C_SECONDARY = Blitbuffer.Color8(0x55)   -- el encabezado (página / capítulo)
local FIELD_ALPHA = 23                        -- 255 * (1 - 23/255) = 232 = 0xE8

local U, face, iconWidget = Kit.U, Kit.face, Kit.iconWidget

local M = {}

-- Alto del teclado de la última vez: así el tamaño del recuadro se calcula de una sola vez.
M._kb_h = nil

local function keyboardHeight(input)
    local ok, h = pcall(function()
        local d = input:getKeyboardDimen()
        return d and d.h
    end)
    if ok and tonumber(h) and h > 0 then return h end
    return math.floor(Screen:getHeight() * 0.4)
end

local function inRect(r, pos)
    return r ~= nil and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

-- ════════════════════════════════════════════════════════════════════════════
-- EL DIÁLOGO
-- ════════════════════════════════════════════════════════════════════════════
local Dlg = InputContainer:extend{
    name = "page_scrubber_notes_dialog",
    -- Con el teclado arriba en el stack, UIManager solo le pasa los eventos a los widgets "siempre
    -- activos" (igual que InputDialog); sin esto los botones y el toque en el texto no llegaban.
    is_always_active = true,
    title = "",
    header = nil,        -- línea de arriba del texto (página, capítulo…)
    text = "",           -- la nota actual
    paste_text = nil,    -- texto subrayado para el botón Paste (nil: sin botón)
    text_face = nil,
    on_save = nil,       -- function(value) con el texto escrito ("" si quedó vacío)
    on_cancel = nil,
    single_line = false, -- un campo de una línea (por ejemplo el nombre de un archivo): sin Enter ni Paste
    use_kk = false,      -- teclado de KiKome en vez del de KOReader
}

function Dlg:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        TapCard = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    self.text_face = self.text_face or face(18)
    if self.use_kk and KKKeyboard then
        -- Los gestos del teclado de KiKome (toque, mantener, deslizar sobre la barra espaciadora, swipe)
        self.ges_events.HoldCard = { GestureRange:new{ ges = "hold", range = self.dimen } }
        self.ges_events.PanCard = { GestureRange:new{ ges = "pan", range = self.dimen } }
        self.ges_events.HoldPanCard = { GestureRange:new{ ges = "hold_pan", range = self.dimen } }
        self.ges_events.PanReleaseCard = { GestureRange:new{ ges = "pan_release", range = self.dimen } }
        self.ges_events.HoldReleaseCard = { GestureRange:new{ ges = "hold_release", range = self.dimen } }
        self.ges_events.SwipeCard = { GestureRange:new{ ges = "swipe", range = self.dimen } }
        self:_initKikomeKeyboard()
    else
        self.use_kk = false
    end
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:_build(self.text)
end

-- ── Teclado de KiKome ───────────────────────────────────────────────────────
function Dlg:_initKikomeKeyboard()
    local function input_do(fn)
        local input = self.input
        if input then
            local ok, err = pcall(fn, input)
            if not ok then logger.warn("PageScrubber: fallo al escribir con el teclado de KiKome:", err) end
        end
    end
    self.kb_open = true
    self.kb = KKKeyboard.new{
        multiline = not self.single_line,
        -- escribir y borrar pasan donde está el cursor del InputText
        on_insert = function(c) input_do(function(i) i:addChars(c) end) end,
        on_delete = function() input_do(function(i) i:delChar() end) end,
        -- mantener borrar: todo lo que hay a la izquierda del cursor (en su línea)
        on_clear = function() input_do(function(i) i:delToStartOfLine() end) end,
        -- deslizar el dedo sobre la barra espaciadora mueve el cursor
        on_move = function(delta)
            input_do(function(i)
                for _n = 1, math.abs(delta) do
                    if delta > 0 then i:rightChar() else i:leftChar() end
                end
            end)
        end,
        on_hide = function() self:_setKikomeKeyboard(false) end,
        is_empty = function()
            local ok, t = pcall(function() return self.input and self.input:getText() or "" end)
            return not ok or t == ""
        end,
        -- una tecla que se suelta: se redibuja solo esa tecla
        on_redraw = function(rects)
            if not (self.kb_open and self.kb_y) then return end
            self.kb_widget = self.kb:build(Screen:getWidth())
            self:_refreshKeyboard(rects)
        end,
    }
    self.kb:reset(self.text == nil or self.text == "")
end

function Dlg:_keyboardRegion()
    local sh = Screen:getHeight()
    return Geom:new{ x = 0, y = self.kb_y or sh, w = Screen:getWidth(), h = sh - (self.kb_y or sh) }
end

-- Redibuja solo esas áreas del teclado (si no hay ninguna, el teclado entero)
function Dlg:_refreshKeyboard(rects)
    if not rects or #rects == 0 then
        local r = self:_keyboardRegion()
        UIManager:setDirty(self, function() return "ui", r end)
        return
    end
    for _i, r in ipairs(rects) do
        UIManager:setDirty(self, function() return "ui", r end)
    end
end

function Dlg:_setKikomeKeyboard(open)
    if not self.kb or self.kb_open == open or self._closed then return end
    self.kb_open = open
    local region = self:_keyboardRegion()
    if open then
        self.kb:reset(self:getInputText() == "")
        self.kb_widget = self.kb:build(Screen:getWidth())
    end
    UIManager:setDirty(nil, function() return "ui", region end)
    UIManager:setDirty(self, function() return "ui", region end)
end

-- El InputText pidió el teclado (se tocó el texto)
function Dlg:showKikomeKeyboard() self:_setKikomeKeyboard(true) end

-- Lo que devolvió una tecla: se rearma el teclado si cambió algo y se refresca solo lo necesario
function Dlg:_afterKeyboard(handled, text_changed, kb_changed, rects)
    if handled and self.kb_open and (text_changed or kb_changed) then
        self.kb_widget = self.kb:build(Screen:getWidth())
        if kb_changed then
            self:_refreshKeyboard(nil)
        else
            self:_refreshKeyboard(rects)
        end
    end
    return handled
end

local function onKeyboard(self, pos)
    return self.use_kk and self.kb_open and self.kb_y and pos and pos.y >= self.kb_y
end

function Dlg:onHoldCard(_arg, ges)
    if onKeyboard(self, ges and ges.pos) then
        self:_afterKeyboard(self.kb:hold(ges.pos, self.kb_y))
        return true
    end
    return false
end

function Dlg:onPanCard(_arg, ges)
    if not (self.use_kk and self.kb_open and self.kb_y) then return false end
    local handled = self.kb:pan(ges, self.kb_y)
    return handled and true or false
end
function Dlg:onHoldPanCard(arg, ges) return self:onPanCard(arg, ges) end

function Dlg:onPanReleaseCard()
    if not self.kb then return false end
    return self.kb:panEnd() and true or false
end
function Dlg:onHoldReleaseCard() return self:onPanReleaseCard() end

function Dlg:onSwipeCard(_arg, ges)
    if not self.kb then return false end
    if self.kb:recentDrag() then return true end
    if not (self.kb_open and self.kb_y) then return false end
    return self:_afterKeyboard(self.kb:swipe(ges, self.kb_y)) and true or false
end

function Dlg:_dropInput()
    local input = self.input
    self.input = nil
    self[1] = nil
    if not input then return end
    pcall(function() input:onCloseKeyboard() end)
    if input.keyboard then pcall(function() UIManager:close(input.keyboard) end) end
    pcall(function() if input.free then input:free() end end)
end

function Dlg:_release()
    for _i, w in ipairs(self.labels or {}) do
        pcall(function() if w.free then w:free() end end)
    end
    self.labels = {}
    if self.strip then
        pcall(function() self.strip:free() end)
        self.strip, self.strip_w = nil, nil
    end
end

function Dlg:_newInput(text, w, h)
    return (self.use_kk and KKInput or InputText):new{
        text = text or "",
        face = self.text_face,
        width = w, height = h,
        padding = 0, margin = 0, bordersize = 0,
        scroll = true,
        scroll_by_pan = true,
        allow_newline = not self.single_line,
        cursor_at_end = true,
        parent = self,
    }
end

-- Toda la geometría (relativa a la tarjeta) para un alto de teclado dado
function Dlg:_layout(kb_h)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local g = {}
    g.pad, g.border, g.radius = U(14), math.max(2, U(2)), U(14)
    g.halo = U(5)   -- contorno blanco por fuera del borde negro, para separar la tarjeta del texto de la página
    g.fpad, g.field_r = U(10), U(12)
    g.card_w = math.min(sw - U(16), math.max(U(300), math.floor(math.min(sw, sh) * 0.94)))
    g.inner_w = g.card_w - 2 * g.pad

    -- Fila de arriba (título y Paste), encabezado
    g.top_y = g.border + g.pad
    g.top_h = U(34)
    local y = g.top_y + g.top_h
    if self.hdr then
        g.hdr_y = y
        y = y + self.hdr:getSize().h + U(4)
    end
    y = y + U(8)
    g.field_y = y

    -- Fila de abajo (Cancel · Save)
    g.row_h = U(44)
    g.below = U(12) + g.row_h + g.pad + g.border

    -- Arriba del teclado, sin tapar los botones
    local avail = sh - kb_h - U(14)
    local field_h = avail - g.field_y - g.below
    g.field_h = math.max(U(70), math.min(field_h, math.floor(sh * 0.40)))
    if self.single_line then g.field_h = U(56) end
    g.card_h = g.field_y + g.field_h + g.below
    g.card_x = math.floor((sw - g.card_w) / 2)
    g.card_y = math.max(U(6) + g.halo, sh - kb_h - U(8) - g.card_h)
    g.text_w = g.inner_w - 2 * g.fpad
    g.text_h = g.field_h - 2 * g.fpad
    return g
end

function Dlg:_build(text)
    self._busy = true
    local ok, err = pcall(self._buildInner, self, text)
    self._busy = false
    if not ok then error(err, 0) end
end

function Dlg:_buildInner(text)
    self:_release()
    self:_dropInput()
    self.dimen.w, self.dimen.h = Screen:getWidth(), Screen:getHeight()

    local function keep(w)
        self.labels[#self.labels + 1] = w
        return w
    end
    local inner_max = Screen:getWidth() - 2 * U(30)

    -- Textos (se miden una vez; el alto no depende del teclado)
    self.title_w = keep(TextWidget:new{ text = self.title, face = face(17), bold = true, max_width = inner_max })
    self.hdr = nil
    local header = tostring(self.header or "")
    header = header:gsub("%s+", " ")
    header = header:gsub("^ ", ""):gsub(" $", "")
    if header ~= "" then
        self.hdr = keep(TextWidget:new{ text = header, face = face(14), fgcolor = C_SECONDARY, max_width = inner_max })
    end
    self.paste_w = nil
    if not self.single_line and self.paste_text and self.paste_text ~= "" then
        self.paste_w = keep(TextWidget:new{ text = self.paste_label, face = face(14), bgcolor = C_IDLE })
    end
    self.cancel_w = keep(TextWidget:new{ text = self.cancel_label, face = face(16), bgcolor = WHITE })
    self.save_w = keep(TextWidget:new{ text = self.save_label, face = face(16), bold = true, fgcolor = WHITE, bgcolor = BLACK })

    local g
    if self.use_kk then
        -- El teclado de KiKome tiene un alto conocido: una sola pasada, y la tarjeta queda siempre en el
        -- mismo lugar aunque se oculte el teclado (así no se pierde el cursor al ocultarlo y mostrarlo)
        local kb_h = self.kb:height()
        g = self:_layout(kb_h)
        self.kb_y = Screen:getHeight() - kb_h
        self.kb_widget = self.kb:build(Screen:getWidth())
        self.input = self:_newInput(text, g.text_w, g.text_h)
    else
        -- Primera pasada con el alto de teclado conocido (o una estimación)
        local guess = M._kb_h or math.floor(Screen:getHeight() * 0.4)
        g = self:_layout(guess)
        self.input = self:_newInput(text, g.text_w, g.text_h)
        local real = keyboardHeight(self.input)
        if math.abs(real - guess) > U(2) then
            M._kb_h = real
            g = self:_layout(real)
            local old = self.input
            self.input = self:_newInput(text, g.text_w, g.text_h)
            pcall(function() if old.free then old:free() end end)
        else
            M._kb_h = real
        end
    end
    self[1] = self.input   -- los toques en el texto le llegan al InputText

    -- Posiciones (relativas a la pantalla)
    local cx, cy = g.card_x, g.card_y
    self.g = g
    self.card = { x = cx, y = cy, w = g.card_w, h = g.card_h }
    local pad = g.pad

    local tsz = self.title_w:getSize()
    self.title_pos = { x = cx + pad, y = cy + g.top_y + math.floor((g.top_h - tsz.h) / 2) }

    self.r_paste = nil
    if self.paste_w then
        local psz = self.paste_w:getSize()
        local ph = U(32)
        local pw = psz.w + 2 * U(16)
        self.r_paste = { x = cx + g.card_w - pad - pw, y = cy + g.top_y + math.floor((g.top_h - ph) / 2), w = pw, h = ph }
        self.paste_lbl_pos = {
            x = self.r_paste.x + math.floor((pw - psz.w) / 2),
            y = self.r_paste.y + math.floor((ph - psz.h) / 2),
        }
    end
    if self.hdr then self.hdr_pos = { x = cx + pad, y = cy + g.hdr_y } end

    self.r_field = { x = cx + pad, y = cy + g.field_y, w = g.inner_w, h = g.field_h }
    self.input_pos = { x = self.r_field.x + g.fpad, y = self.r_field.y + g.fpad }

    -- Fila de abajo: Cancel (solo texto, esquina izquierda) y Save (píldora, esquina derecha)
    local row_y = self.r_field.y + g.field_h + U(12)
    -- Cancel no tiene fondo pero ocupa el mismo lugar que tendría como botón (igual ancho que Save),
    -- con el texto centrado ahí, así no queda pegado al borde izquierdo
    local csz = self.cancel_w:getSize()
    local bw = math.max(U(96), math.max(csz.w, self.save_w:getSize().w) + 2 * U(20))
    self.r_cancel = { x = cx + pad, y = row_y, w = bw, h = g.row_h }
    self.cancel_pos = {
        x = self.r_cancel.x + math.floor((bw - csz.w) / 2),
        y = row_y + math.floor((g.row_h - csz.h) / 2),
    }
    self.r_save = { x = cx + g.card_w - pad - bw, y = row_y, w = bw, h = g.row_h }
end

function Dlg:cardRegion()
    local c = self.card
    local m = ((self.g and self.g.halo) or U(5)) + U(3)
    return Geom:new{ x = c.x - m, y = c.y - m, w = c.w + 2 * m, h = c.h + 2 * m }
end

-- El texto del recuadro se dibuja sobre blanco; se lo oscurece con negro translúcido para que
-- quede del mismo gris que el recuadro (el negro del texto no cambia). La tira de 1 px se arma con
-- setPixel (como la sombra de scrubber_menu.lua) porque fill() no respeta la transparencia.
function Dlg:_darken(bb, x, y, w, h)
    if w <= 0 or h <= 0 then return end
    if self.strip_w ~= w then
        if self.strip then pcall(function() self.strip:free() end) end
        self.strip, self.strip_w = nil, nil
        local ok, st = pcall(function()
            local b = Blitbuffer.new(w, 1, Blitbuffer.TYPE_BBRGB32)
            local c = Blitbuffer.ColorRGB32(0, 0, 0, FIELD_ALPHA)
            for px = 0, w - 1 do b:setPixel(px, 0, c) end
            return b
        end)
        if ok and st then self.strip, self.strip_w = st, w end
    end
    if self.strip then
        pcall(function()
            for row = 0, h - 1 do bb:alphablitFrom(self.strip, x, y + row, 0, 0, w, 1) end
        end)
    end
end

local function chip(bb, r, color, label, pos)
    bb:paintRoundedRect(r.x, r.y, r.w, r.h, color, math.floor(r.h / 2))
    local sz = label:getSize()
    label:paintTo(bb, pos and pos.x or (r.x + math.floor((r.w - sz.w) / 2)),
        pos and pos.y or (r.y + math.floor((r.h - sz.h) / 2)))
end

function Dlg:paintTo(bb, x, y)
    local c, g = self.card, self.g
    if not (c and g) then return end
    local cx, cy = x + c.x, y + c.y

    -- Tarjeta: contorno blanco, borde negro y fondo blanco, esquinas redondeadas
    bb:paintRoundedRect(cx - g.halo, cy - g.halo, c.w + 2 * g.halo, c.h + 2 * g.halo, WHITE, g.radius + g.halo)
    bb:paintRoundedRect(cx, cy, c.w, c.h, BLACK, g.radius)
    bb:paintRoundedRect(cx + g.border, cy + g.border, c.w - 2 * g.border, c.h - 2 * g.border,
        WHITE, math.max(0, g.radius - g.border))

    self.title_w:paintTo(bb, x + self.title_pos.x, y + self.title_pos.y)
    if self.hdr then self.hdr:paintTo(bb, x + self.hdr_pos.x, y + self.hdr_pos.y) end
    if self.r_paste then
        local r = self.r_paste
        chip(bb, { x = x + r.x, y = y + r.y, w = r.w, h = r.h }, C_IDLE, self.paste_w,
            { x = x + self.paste_lbl_pos.x, y = y + self.paste_lbl_pos.y })
    end

    -- El recuadro gris con el texto
    local f = self.r_field
    bb:paintRoundedRect(x + f.x, y + f.y, f.w, f.h, C_FIELD, g.field_r)
    if self.input then
        local ix, iy = x + self.input_pos.x, y + self.input_pos.y
        -- Todo el rectángulo del InputText parte de blanco: la franja de la barra de scroll no la pinta
        -- el InputText y, al oscurecer, quedaba más oscura que el resto (el "palo" gris del costado)
        local dw, dh = g.text_w, g.text_h
        pcall(function()
            local sz = self.input:getSize()
            if sz and sz.w > 0 and sz.h > 0 then dw, dh = sz.w, sz.h end
        end)
        bb:paintRect(ix, iy, dw, dh, WHITE)
        self.input:paintTo(bb, ix, iy)
        -- Se oscurece exactamente el rectángulo del InputText (barra de scroll incluida)
        self:_darken(bb, ix, iy, dw, dh)
    end

    -- Teclado de KiKome, pegado abajo
    if self.use_kk and self.kb_open and self.kb_widget and self.kb_y then
        self.kb_widget:paintTo(bb, x, y + self.kb_y)
    end

    -- Botones de abajo: Cancel es solo texto; Save, una píldora negra
    self.cancel_w:paintTo(bb, x + self.cancel_pos.x, y + self.cancel_pos.y)
    local sv = self.r_save
    chip(bb, { x = x + sv.x, y = y + sv.y, w = sv.w, h = sv.h }, BLACK, self.save_w)
end

-- ── Acciones ────────────────────────────────────────────────────────────────
function Dlg:_close()
    if self._closed then return end
    self._closed = true
    UIManager:close(self, "flashui", self:cardRegion())
end

function Dlg:save()
    if self._closed then return true end
    local value = ""
    pcall(function() value = self.input:getText() or "" end)
    self._last_text = value
    self:_close()
    local cb = self.on_save
    if cb then
        local ok, err = pcall(cb, value)
        if not ok then logger.warn("PageScrubber: fallo al guardar la nota:", err) end
    end
    return true
end

function Dlg:cancel()
    if self._closed then return true end
    self:_close()
    local cb = self.on_cancel
    if cb then
        local ok, err = pcall(cb)
        if not ok then logger.warn("PageScrubber: fallo al cancelar la nota:", err) end
    end
    return true
end

-- Como InputDialog:getInputText (lo usan los botones que se pasan por InputDialog)
function Dlg:getInputText()
    if self.input then
        local ok, t = pcall(function() return self.input:getText() end)
        if ok and t then return t end
    end
    return self._last_text or ""
end

function Dlg:paste()
    if not (self.paste_text and self.input) then return end
    pcall(function() self.input:addChars(self.paste_text) end)
end

function Dlg:onTapCard(_arg, ges)
    local pos = ges and ges.pos
    if not pos then return true end
    -- Teclado de KiKome: lo dibuja y lo maneja el diálogo
    if onKeyboard(self, pos) then
        self:_afterKeyboard(self.kb:tap(pos, self.kb_y))
        return true
    end
    if inRect(self.r_cancel, pos) then return self:cancel() end
    if inRect(self.r_save, pos) then return self:save() end
    if inRect(self.r_paste, pos) then self:paste(); return true end
    -- Un toque en el texto le llega al InputText
    if inRect(self.r_field, pos) then return false end
    -- Un toque fuera de la tarjeta (menos en el teclado) es como apretar Cancel
    if not inRect(self.card, pos) then
        local kb = self.input and self.input.keyboard
        local on_keyboard = false
        if kb and kb.dimen then
            local shown = true
            if UIManager.isWidgetShown then
                local ok, v = pcall(UIManager.isWidgetShown, UIManager, kb)
                if ok then shown = v and true or false end
            end
            on_keyboard = shown and inRect(kb.dimen, pos)
        end
        if on_keyboard then return false end
        if self.use_kk and self.kb_open and self.kb_y and pos.y >= self.kb_y then return true end
        return self:cancel()
    end
    return true
end

function Dlg:onClose()
    return self:cancel()
end

-- Cambió el alto del teclado o se rotó la pantalla: se rearma con el texto que haya
function Dlg:_rebuild()
    if self._busy or self._closed or not self.input then return true end
    local text = ""
    pcall(function() text = self.input:getText() or "" end)
    local old_region = self:cardRegion()
    local ok, err = pcall(function()
        self:_build(text)
        self._busy = true   -- los eventos del teclado que se disparen al mostrarlo no vuelven a entrar
        self.input:onShowKeyboard()
    end)
    self._busy = false
    if not ok then logger.warn("PageScrubber: fallo al rearmar el diálogo de la nota:", err) end
    UIManager:setDirty(nil, "ui", old_region)
    UIManager:setDirty(self, "ui", self:cardRegion())
    return true
end

-- Cambió el alto del teclado (solo se rearma si de verdad cambió)
function Dlg:onKeyboardHeightChanged()
    if self.use_kk then return false end   -- el teclado de KiKome tiene alto fijo
    if self._busy or self._closed or not self.input then return false end
    if math.abs(keyboardHeight(self.input) - (M._kb_h or 0)) <= U(2) then return false end
    return self:_rebuild()
end

-- Rotación de pantalla
function Dlg:onSetDimensions() return self:_rebuild() end

function Dlg:onShow()
    UIManager:setDirty(self, "ui", self:cardRegion())
    return true
end

function Dlg:onCloseWidget()
    self._closed = true
    if self.kb then pcall(function() self.kb:free() end) end
    local region = self.card and self:cardRegion() or nil
    self:_dropInput()
    self:_release()
    UIManager:setDirty(nil, "ui", region)
end

-- ════════════════════════════════════════════════════════════════════════════
-- ReaderBookmark:setBookmarkNote con este diálogo
-- (la lógica de guardar / cancelar es la de readerbookmark.lua, sin cambios)
-- ════════════════════════════════════════════════════════════════════════════
function M.show(bm, item_or_index, is_new_note, new_note, caller_callback, opts)
    opts = opts or {}
    local item, index
    if bm.bookmark_menu then
        item = item_or_index -- en item_table
        index = bm:getBookmarkItemIndex(item)
    else -- desde un highlight
        index = item_or_index
    end
    local annotation = bm.ui and bm.ui.annotation and bm.ui.annotation.annotations[index]
    if not annotation then return false end

    local type_before = item and item.type or bm.getBookmarkType(annotation)
    local input_text = annotation.note
    if new_note then
        if input_text then
            input_text = input_text .. "\n\n" .. new_note
        else
            input_text = new_note
        end
    end

    local header = ""
    pcall(function() header = bm:_getDialogHeader(annotation) or "" end)

    local dlg
    dlg = Dlg:new{
        use_kk = useKikomeKeyboard(),
        title = gettext("Edit note"),
        header = header,
        text = input_text or "",
        paste_text = annotation.text,
        paste_label = gettext("Paste"),
        cancel_label = gettext("Cancel"),
        save_label = gettext("Save"),
        text_face = opts.face,
        on_cancel = function()
            if is_new_note then -- "Add note" desde el menú del highlight y se canceló: se borra el highlight guardado
                bm:removeItemByIndex(index)
            end
        end,
        on_save = function(value)
            value = value ~= "" and value or nil -- un texto vacío borra la nota
            annotation.note = value
            local type_after, datetime_updated
            if type_before ~= "bookmark" then
                bm.ui.highlight:writePdfAnnotation("content", annotation, value or "")
                type_after = bm.getBookmarkType(annotation)
                if type_before ~= type_after then
                    if type_before == "highlight" then
                        bm.ui:handleEvent(Event:new("AnnotationsModified",
                            { annotation, nb_highlights_added = -1, nb_notes_added = 1 }))
                    else -- "note"
                        bm.ui:handleEvent(Event:new("AnnotationsModified",
                            { annotation, nb_highlights_added = 1, nb_notes_added = -1 }))
                    end
                    datetime_updated = true
                end
            end
            if not datetime_updated then
                bm.ui.annotation:onAnnotationsModified({ annotation })
            end
            if item then
                item.note = value
                item.type = type_after
                item.text = bm:getBookmarkItemText(item)
            end
            if caller_callback then
                caller_callback()
            end
        end,
    }
    UIManager:show(dlg)
    pcall(function() dlg.input:onShowKeyboard() end)
    return true
end

-- ════════════════════════════════════════════════════════════════════════════
-- Un campo de una línea con el mismo diseño y teclado, con la interfaz de InputDialog
-- (title, input, buttons = {{ cancelar, guardar }}): donde el plugin usaba InputDialog,
-- alcanza con cambiar la clase. Los callbacks de los botones se llaman igual
-- (dialog:getInputText(), UIManager:close(dialog)).
-- ════════════════════════════════════════════════════════════════════════════
M.InputDialog = {}
function M.InputDialog:new(opts)
    opts = opts or {}
    local cancel_cb, save_cb
    for _i, row in ipairs(opts.buttons or {}) do
        for _j, b in ipairs(row) do
            if b.id == "close" then cancel_cb = b.callback
            elseif b.is_enter_default then save_cb = b.callback end
        end
    end
    return Dlg:new{
        use_kk = useKikomeKeyboard(),
        single_line = true,
        title = opts.title or "",
        text = opts.input or "",
        cancel_label = gettext("Cancel"),
        save_label = gettext("Save"),
        on_save = function() if save_cb then save_cb() end end,
        on_cancel = function() if cancel_cb then cancel_cb() end end,
    }
end

-- El teclado de KOReader o el de KiKome, según el ajuste (por si alguna otra pantalla lo quiere saber)
M.useKikomeKeyboard = useKikomeKeyboard

return M

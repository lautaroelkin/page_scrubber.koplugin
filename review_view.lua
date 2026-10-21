--[[
    page_scrubber.koplugin/review_view.lua
    Review Card: modal full-screen para repasar highlights/notas una por una.
    Reutiliza el look del panel de detalles del split.
]]--

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local SRS             = require("srs")

local Screen = Device.screen

-- Offset de Ajustes > Appearance > Text size (mismo criterio que scrubber_ui.lua)
local function textOffset()
    local ts = G_reader_settings and G_reader_settings:readSetting("page_scrubber_text_size")
    if ts == "small" then return -2
    elseif ts == "large" then
        local is_eink = (Device.isKindle and Device:isKindle()) or (Device.isKobo and Device:isKobo()) or (Device.isEink and Device:isEink())
        return is_eink and 4 or 2
    end
    return 0
end

-- Teclas para dispositivos sin pantalla táctil / con botones físicos (mismo helper que scrubber_ui.lua)
local function flatten_keys(...)
    local keys = {}
    for i = 1, select("#", ...) do
        local item = select(i, ...)
        if type(item) == "table" then
            for _, k in ipairs(item) do table.insert(keys, { k }) end
        elseif type(item) == "string" then table.insert(keys, { item }) end
    end
    return keys
end

-- Traducciones: mismo mecanismo que scrubber_settings.lua (lee locales/<idioma>.po del plugin).
-- No se usa require("gettext") porque ese solo conoce las traducciones del propio KOReader.
local _dict = {}
do
    local plugin_path = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
    local lang = "en"
    if G_reader_settings then
        local l = G_reader_settings:readSetting("language")
        if type(l) == "string" then lang = l:sub(1, 2) end
    end
    if lang ~= "en" then
        local f = io.open(plugin_path .. "locales/" .. lang .. ".po", "r")
        if f then
            local current_id
            for line in f:lines() do
                local id = line:match('^msgid%s+"(.*)"')
                if id then current_id = (id:gsub('\\"', '"')) end
                local str = line:match('^msgstr%s+"(.*)"')
                if str and current_id then
                    _dict[current_id] = (str:gsub('\\"', '"'))
                    current_id = nil
                end
            end
            f:close()
        end
    end
end

local function _(text)
    return _dict[text] or text
end

-- ---------- helpers de dibujo ----------

local function paintCornerRect(bb, x, y, w, h, r, color, tl, tr, bl, br)
    if w <= 0 or h <= 0 then return end
    r = math.min(r, math.floor(w / 2), math.floor(h / 2))
    if r <= 0 then bb:paintRect(x, y, w, h, color); return end
    bb:paintRect(x + r, y, w - 2*r, h, color)
    bb:paintRect(x, y + r, r, math.max(1, h - 2*r), color)
    bb:paintRect(x + w - r, y + r, r, math.max(1, h - 2*r), color)
    if not tl then bb:paintRect(x, y, r, r, color) end
    if not tr then bb:paintRect(x + w - r, y, r, r, color) end
    if not bl then bb:paintRect(x, y + h - r, r, r, color) end
    if not br then bb:paintRect(x + w - r, y + h - r, r, r, color) end
    for j = 0, r - 1 do
        local arc = math.ceil(math.sqrt(r*r - (r-j-0.5)*(r-j-0.5)))
        if arc > 0 then
            if tl then bb:paintRect(x + r - arc, y + j, arc, 1, color) end
            if tr then bb:paintRect(x + w - r,   y + j, arc, 1, color) end
            if bl then bb:paintRect(x + r - arc, y + h - 1 - j, arc, 1, color) end
            if br then bb:paintRect(x + w - r,   y + h - 1 - j, arc, 1, color) end
        end
    end
end

local function paintRoundRect(bb, x, y, w, h, r, color)
    paintCornerRect(bb, x, y, w, h, r, color, true, true, true, true)
end

-- Feedback al tocar Again / Good / Easy. Pensado para e-ink: UN solo cuadro (el botón queda relleno de negro
-- un instante) y después se aplica la calificación. Para desactivarlo: FX_ENABLED = false.
local FX_ENABLED = true
local FX_HOLD    = 0.14   -- segundos que se ve el botón relleno antes de pasar a la siguiente tarjeta

-- Línea gruesa hecha con cuadraditos (no depende de ninguna fuente ni glifo)
local function drawLine(bb, x0, y0, x1, y1, t, color)
    local dx, dy = x1 - x0, y1 - y0
    local steps = math.max(math.abs(dx), math.abs(dy), 1)
    local half = math.floor(t / 2)
    for i = 0, steps do
        local x = math.floor(x0 + dx * i / steps + 0.5)
        local y = math.floor(y0 + dy * i / steps + 0.5)
        bb:paintRect(x - half, y - half, t, t, color)
    end
end

-- ---------- marcas de calificación: ! (Again) · ✓ (Good) · ★ (Easy) ----------
-- Se dibujan a mano (rectángulos / líneas), no dependen de ninguna fuente ni emoji.
-- (cx, cy) es el centro y `size` el alto aproximado de la marca.

local function paintCheck(bb, cx, cy, size, color)
    local t = math.max(2, math.floor(size * 0.14))
    drawLine(bb, cx - size * 0.50, cy + size * 0.05, cx - size * 0.15, cy + size * 0.42, t, color)
    drawLine(bb, cx - size * 0.15, cy + size * 0.42, cx + size * 0.55, cy - size * 0.45, t, color)
end

local function paintBang(bb, cx, cy, size, color)
    local t     = math.max(2, math.floor(size * 0.15))               -- grosor de la barra
    local bar_h = math.floor(size * 0.58)
    local dot   = t + math.max(1, math.floor(t * 0.4))               -- el punto un poco más grande que la barra
    local gap   = math.max(2, math.floor(size * 0.10))
    local top   = cy - math.floor((bar_h + gap + dot) / 2)
    bb:paintRect(cx - math.floor(t / 2), top, t, bar_h, color)
    bb:paintRect(cx - math.floor(dot / 2), top + bar_h + gap, dot, dot, color)
end

-- Estrella de 5 puntas rellena (scanline, regla par-impar). r_out = radio de las puntas.
local function paintStar(bb, cx, cy, r_out, color)
    local r_in = r_out * 0.40
    cy = cy + r_out * 0.095   -- la estrella es más alta arriba que abajo: se baja un poco para que quede centrada
    local px, py = {}, {}
    for i = 0, 9 do
        local ang = -math.pi / 2 + i * math.pi / 5
        local rad = (i % 2 == 0) and r_out or r_in
        px[i + 1] = cx + rad * math.cos(ang)
        py[i + 1] = cy + rad * math.sin(ang)
    end
    local y_top = math.floor(cy - r_out)
    local y_bot = math.ceil(cy + r_out * 0.81)
    for y = y_top, y_bot do
        local sy = y + 0.5
        local xs = {}
        for i = 1, 10 do
            local j = i % 10 + 1
            local ay, by = py[i], py[j]
            if (ay <= sy and by > sy) or (by <= sy and ay > sy) then
                xs[#xs + 1] = px[i] + (sy - ay) * (px[j] - px[i]) / (by - ay)
            end
        end
        table.sort(xs)
        for k = 1, #xs - 1, 2 do
            local x0 = math.floor(xs[k] + 0.5)
            local x1 = math.floor(xs[k + 1] + 0.5)
            if x1 > x0 then bb:paintRect(x0, y, x1 - x0, 1, color) end
        end
    end
end

local function paintQualityMark(bb, quality, cx, cy, size, color)
    if quality == "again" then paintBang(bb, cx, cy, size, color)
    elseif quality == "good" then paintCheck(bb, cx, cy, size, color)
    elseif quality == "easy" then paintStar(bb, cx, cy, size * 0.5, color)
    end
end

local function paintColorRect(bb, x, y, w, h, color)
    if w <= 0 or h <= 0 then return end
    if bb.blendRectRGB32 then bb:blendRectRGB32(x, y, w, h, color)
    elseif bb.paintRectRGB32 then bb:paintRectRGB32(x, y, w, h, color)
    else bb:paintRect(x, y, w, h, color) end
end

-- Triangulitos de scroll en el margen derecho: ▲ si hay texto arriba, ▼ si hay texto abajo
local function paintScrollMarks(bb, gx, gy, gw, gh, area_h, can_up, can_down)
    if can_up then
        for row = 0, gh - 1 do
            local rw = math.max(1, math.floor(gw * (row + 1) / gh + 0.5))
            bb:paintRect(gx + math.floor((gw - rw) / 2), gy + row, rw, 1, Blitbuffer.COLOR_BLACK)
        end
    end
    if can_down then
        for row = 0, gh - 1 do
            local rw = math.max(1, math.floor(gw * (gh - row) / gh + 0.5))
            bb:paintRect(gx + math.floor((gw - rw) / 2), gy + area_h - gh + row, rw, 1, Blitbuffer.COLOR_BLACK)
        end
    end
end

-- Corte de líneas por palabras; measure(str) devuelve el ancho en píxeles (igual que el panel de detalle)
local function wrap_text(measure, text, max_w)
    local lines = {}
    for para in (text .. "\n"):gmatch("(.-)\n") do
        if para == "" then
            lines[#lines + 1] = ""
        else
            local cur = ""
            for word in para:gmatch("%S+") do
                local cand = (cur == "") and word or (cur .. " " .. word)
                if measure(cand) <= max_w then
                    cur = cand
                else
                    if cur ~= "" then lines[#lines + 1] = cur; cur = "" end
                    if measure(word) <= max_w then
                        cur = word
                    else
                        -- palabra más ancha que la columna: se parte por caracteres
                        local piece = ""
                        for ch in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                            if piece == "" or measure(piece .. ch) <= max_w then
                                piece = piece .. ch
                            else
                                lines[#lines + 1] = piece
                                piece = ch
                            end
                        end
                        cur = piece
                    end
                end
            end
            lines[#lines + 1] = cur
        end
    end
    return lines
end

local function paintTriangle(bb, x, y, w, h, pointing_left, color)
    for c = 0, w - 1 do
        local frac = pointing_left and ((c + 1) / w) or ((w - c) / w)
        local hc = math.max(1, math.floor(h * frac + 0.5))
        bb:paintRect(x + c, y + math.floor((h - hc) / 2), 1, hc, color)
    end
end

-- ---------- widget ----------

local ReviewView = InputContainer:extend({
    scrubber_ui = nil,
    due         = nil,   -- lista de { id, state, entry }
    review_only = false, -- modo repaso: sin botones de calificación (no modifica el SRS); se navega con puntitos / flechas
    current     = 1,
    on_close    = nil,
    is_modal    = true,
})

function ReviewView:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local S = self.scrubber_ui and self.scrubber_ui.S
              or function(v) return Screen:scaleBySize(v) end
    self.S = S

    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.is_modal = true

    -- Geometría de la tarjeta
    local margin_x = S(16)
    local margin_y = S(24)
    local cw = sw - margin_x * 2
    local ch = sh - margin_y * 2
    if sw > sh then cw = math.min(cw, math.floor(sw * 0.75)) end
    self.card_rect = Geom:new{
        x = math.floor((sw - cw) / 2),
        y = math.floor((sh - ch) / 2),
        w = cw, h = ch,
    }
    self.radius = S(16)
    self.border = S(3)
    self.pad    = S(20)

    -- Layout fijo
    self.header_h   = S(48)
    self.review_only = self.review_only and true or false
    self.button_h   = self.review_only and S(56) or S(88)
    self.content_top = self.card_rect.y + self.border + self.header_h + S(10)
    self.button_y    = self.card_rect.y + self.card_rect.h - self.pad - self.button_h
    self.content_bot = self.button_y - S(12)

    -- Botones
    local gap  = S(10)
    local bw   = math.floor((self.card_rect.w - self.pad * 2 - gap * 2) / 3)
    local by   = self.button_y
    local bx   = self.card_rect.x + math.floor((self.card_rect.w - (bw * 3 + gap * 2)) / 2)   -- grupo centrado
    self.btn_rects = {
        { quality = "again", label = _("Again"), rect = Geom:new{ x = bx, y = by, w = bw, h = self.button_h } },
        { quality = "good",  label = _("Good"),  rect = Geom:new{ x = bx + bw + gap, y = by, w = bw, h = self.button_h } },
        { quality = "easy",  label = _("Easy"),  rect = Geom:new{ x = bx + (bw + gap) * 2, y = by, w = bw, h = self.button_h } },
    }

    -- Modo repaso: no hay botones de calificación; en su lugar va la fila de navegación (_paintNav)
    if self.review_only then
        self.btn_rects = {}
        self.nav_rect = Geom:new{
            x = self.card_rect.x + self.pad, y = self.button_y,
            w = self.card_rect.w - self.pad * 2, h = self.button_h,
        }
        self._nav_dimens = {}
    end

    -- Botón X
    local cs = S(44)
    self.close_rect = Geom:new{
        x = self.card_rect.x + self.card_rect.w - self.border - cs - S(8),
        y = self.card_rect.y + self.border + S(2),
        w = cs, h = cs,
    }

    -- Botón Undo: header, entre el capítulo y la X. Solo se pinta cuando hay historial.
    -- Misma altura que la X para que queden alineados y el área táctil sea cómoda.
    self.undo_rect = Geom:new{
        x = self.close_rect.x - S(40) - S(2),
        y = self.close_rect.y,
        w = S(40), h = self.close_rect.h,
    }

    -- Pila de deshacer (máx. 20): { id, prev_index, state, was_new, quality }. Vive solo mientras el Review Card está abierto.
    self._history = {}

    -- Estadísticas de la sesión + flag de la pantalla final
    self._stats = { again = 0, good = 0, easy = 0 }
    self._summary_mode = false

    -- Último estado para repintar (cacheado)
    self.widgets = {}
    self.display = {}

    if Device:isTouchDevice() then
        self.ges_events = {
            Tap   = { GestureRange:new{ ges = "tap",   range = self.dimen } },
            Hold  = { GestureRange:new{ ges = "hold",  range = self.dimen } },
            Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
    end

    -- Dispositivos con teclas (sin pantalla táctil o con botones físicos): mismas convenciones que scrubber_ui.lua
    if Device:hasKeys() then
        self.key_events = {
            ScrubKeyBack   = flatten_keys(Device.input.group.Back),
            ScrubKeyPrev   = flatten_keys(Device.input.group.PgBack, Device.input.group.Left),
            ScrubKeyNext   = flatten_keys(Device.input.group.PgFwd, Device.input.group.Right),
            ScrubKeyUp     = flatten_keys(Device.input.group.Up),
            ScrubKeyDown   = flatten_keys(Device.input.group.Down),
            ScrubKeySelect = flatten_keys(Device.input.group.Select, Device.input.group.Press),
        }
    end
    -- Foco de teclado: "undo" | "again" | "good" | "easy" (pantalla final: "done" | "undo").
    -- El anillo de foco se ve siempre sin pantalla táctil; con pantalla táctil aparece al usar una tecla.
    self._key_vis = not Device:isTouchDevice()
    self._kfocus = "good"

    self:_loadCurrent()
end

function ReviewView:_freeWidgets()
    for _, w in pairs(self.widgets or {}) do
        if w and w.free then pcall(function() w:free() end) end
    end
    for _, b in ipairs(self.btn_rects or {}) do
        if b.label_w and b.label_w.free then pcall(function() b.label_w:free() end) end
        if b.interval_w and b.interval_w.free then pcall(function() b.interval_w:free() end) end
        b.label_w, b.interval_w = nil, nil
    end
    self.widgets = {}
    self._page_link_dimen = nil
end

function ReviewView:_loadCurrent()
    self:_freeWidgets()
    local card = self.due[self.current]
    if not card then return end

    local entry = card.entry
    local scrubber = self.scrubber_ui
    local S = self.S

    local chapter = scrubber and scrubber:_getChapter(entry.page) or "—"
    local page_lbl = scrubber and scrubber:_getDisplayPageInfo(entry.page) or tostring(entry.page or "?")

    self.display.chapter     = chapter
    self.display.page_label  = page_lbl
    self.display.quote       = entry.text or ""
    self.display.quote_type  = entry.type or "normal"
    self.display.quote_color = entry.color or "yellow"
    self.display.note        = entry.note or ""

    -- Intervalos de preview
    self.display.intervals = {
        again = SRS.previewInterval(card.state, "again"),
        good  = SRS.previewInterval(card.state, "good"),
        easy  = SRS.previewInterval(card.state, "easy"),
    }

    -- Cabecera: "Page N" como link tappable (subrayado gris)  ·  "Tipo (Color)" como info secundaria
    -- (el capítulo va arriba, al lado del contador)
    local col_w0 = self.card_rect.w - self.pad * 2
    local type_label = scrubber and scrubber._getHighlightTypeLabel and scrubber:_getHighlightTypeLabel(entry)
    self.widgets.page_link = TextWidget:new{
        text = _("Page") .. " " .. tostring(page_lbl),
        face = Font:getFace("cfont", S(12 + textOffset())),
        bold = true,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        max_width = col_w0,
        truncate_with_ellipsis = true,
    }
    -- Modo repaso: marca de la última calificación que se le dio a esta tarjeta (a la izquierda de "Page N")
    self._mark = nil
    if self.review_only then
        local st = card.state
        local lq = st and st.last_quality
        if not lq and st and (st.review_count or 0) == 0 and (st.last_review or 0) > 0 then
            lq = "again"   -- tarjetas calificadas antes de guardar last_quality: solo Again deja review_count en 0
        end
        if lq == "again" or lq == "good" or lq == "easy" then
            local m = math.floor(self.widgets.page_link:getSize().h * 0.85)
            self._mark = { quality = lq, size = m, w = math.floor(m * 1.1), gap = S(8) }
        end
    end
    local mark_total = self._mark and (self._mark.w + self._mark.gap) or 0

    self.widgets.type_label = nil
    if type_label and type_label ~= "" then
        local type_max_w = col_w0 - mark_total - self.widgets.page_link:getSize().w - S(10)
        if type_max_w > S(30) then
            self.widgets.type_label = TextWidget:new{
                text = "· " .. type_label,
                face = Font:getFace("cfont", S(11 + textOffset())),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                max_width = type_max_w,
                truncate_with_ellipsis = true,
            }
        end
    end

    -- Botones: label + intervalo
    local btn_label_face = Font:getFace("cfont", S(15 + textOffset()))
    local btn_sub_face   = Font:getFace("cfont", S(10 + textOffset()))
    for _, b in ipairs(self.btn_rects) do
        b.label_w = TextWidget:new{
            text = b.label, face = btn_label_face, bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        b.interval_w = TextWidget:new{
            text = "<" .. SRS.formatInterval(self.display.intervals[b.quality]) .. ">",
            face = btn_sub_face, fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
    end

    -- Cita (línea por línea, como en el panel de detalle) + nota (TextBoxWidget)
    local available = self.content_bot - self.content_top
    local has_note  = self.display.note ~= ""
    local has_quote = self.display.quote ~= ""

    local t_off = textOffset()
    local quote_face = Font:getFace("cfont", S(15 + t_off))
    local note_face  = Font:getFace("cfont", S(12 + t_off))
    local underline_h = math.max(1, S(2))
    local pad_after_header = self.widgets.page_link:getSize().h + underline_h + S(12)
    local col_w = self.card_rect.w - self.pad * 2

    -- Altura máxima de la cita: 62% si hay nota, todo el espacio si no
    local quote_max_h = 0
    if has_quote and has_note then
        quote_max_h = math.floor((available - pad_after_header) * 0.62)
    elseif has_quote then
        quote_max_h = available - pad_after_header
    end

    self._quote = nil
    self._quote_h = 0
    if has_quote and quote_max_h > S(40) then
        local ql     = TextWidget:new{ text = "Ag", face = quote_face, bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
        local ql_inv = TextWidget:new{ text = "Ag", face = quote_face, bold = true, fgcolor = Blitbuffer.COLOR_WHITE }
        self.widgets.qline, self.widgets.qline_inv = ql, ql_inv
        local line_h = ql:getSize().h
        local function measure(str) ql.text = nil; ql:setText(str); return ql:getSize().w end

        local lines = wrap_text(measure, "“" .. self.display.quote .. "”", col_w)
        local vis = math.max(1, math.floor(quote_max_h / line_h))
        local widths = {}
        for i, ln in ipairs(lines) do widths[i] = (ln == "") and 0 or measure(ln) end
        -- Todas las líneas quedan guardadas; solo se muestran `vis` a la vez (se desplaza con un swipe vertical)
        self._quote = { lines = lines, widths = widths, line_h = line_h, vis = math.min(vis, #lines), first = 1 }
        self._quote_h = self._quote.vis * line_h
    end

    local note_h = 0
    if has_note then
        note_h = available - pad_after_header - self._quote_h - (has_quote and S(10) or 0)
    end

    if has_note and note_h > S(30) then
        self.widgets.note = TextBoxWidget:new{
            text = self.display.note,
            face = note_face,
            width = col_w,
            height = note_h,
            height_adjust = true,
            alignment = "left",
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        self._note_h = note_h
    else
        self._note_h = 0
    end
end

-- Escribe a disco el progreso pendiente del repaso (archivo propio del plugin, no la metadata del libro)
function ReviewView:_saveProgress()
    local ui = self.scrubber_ui and self.scrubber_ui.ui
    if ui then pcall(SRS.flush, ui) end
end

function ReviewView:_closeWithMessage(msg)
    if self._closed then return end
    self._closed = true
    local cb = self.on_close
    self:_saveProgress()
    self:_freeWidgets()
    UIManager:close(self)
    if msg then
        UIManager:show(InfoMessage:new{ text = msg, timeout = 2 })
    end
    if cb then pcall(cb) end
end

function ReviewView:_applyQuality(quality)
    local card = self.due[self.current]
    if not card then return end
    local scrubber = self.scrubber_ui
    local ui = scrubber and scrubber.ui

    -- Estadística de la sesión (se revierte con Undo)
    self._stats[quality] = (self._stats[quality] or 0) + 1

    if ui then
        -- Foto del estado ANTES del update, para poder deshacer
        local prev_state, was_new = SRS.captureState(ui, card.id)
        if prev_state then
            self._history[#self._history + 1] = {
                id = card.id, prev_index = self.current, state = prev_state,
                was_new = was_new, quality = quality,
            }
            if #self._history > 20 then table.remove(self._history, 1) end
        end

        -- El estado se actualiza en memoria; SRS lo escribe a su archivo propio con un pequeño retraso
        SRS.update(ui, card.id, quality)
    end

    self.current = self.current + 1
    if self.current > #self.due then
        -- Fin de la sesión: pantalla final en vez de cerrar
        self._summary_mode = true
        self._kfocus = "done"
        self:_saveProgress()
        UIManager:setDirty(self, "ui", self.dimen)
        return
    end
    self:_loadCurrent()
    UIManager:setDirty(self, "ui", self.dimen)
end

-- Deshace el último grade de esta sesión: restaura el estado previo de la tarjeta y vuelve a ella.
-- Se puede encadenar (hasta 20 niveles).
function ReviewView:_undo()
    if self._closed or self._going_to_book then return end
    local snap = self._history and table.remove(self._history)
    if not snap then return end

    -- Revertir la estadística de la sesión
    if snap.quality and self._stats[snap.quality] then
        self._stats[snap.quality] = math.max(0, self._stats[snap.quality] - 1)
    end

    local ui = self.scrubber_ui and self.scrubber_ui.ui
    if ui then
        SRS.restoreState(ui, snap.id, snap.state, snap.was_new)
    end

    local idx = math.max(1, math.min(snap.prev_index, #self.due))
    self.current = idx
    local card = self.due[idx]
    if card and ui then card.state = SRS.getState(ui, card.id) end   -- los botones muestran los intervalos correctos

    -- Si estábamos en la pantalla final, se vuelve a la tarjeta
    self._summary_mode = false
    self._summary_done_rect, self._summary_undo_rect = nil, nil
    self._kfocus = "good"

    self:_loadCurrent()
    UIManager:setDirty(self, "ui", self.dimen)
end

-- Muestra el botón tocado relleno (un solo refresco rápido sobre el botón) y recién después aplica la calificación.
function ReviewView:_playFx(b, pos)
    local quality = b.quality
    if not FX_ENABLED then
        self:_applyQuality(quality)
        return
    end
    self._fx = { quality = quality, rect = b.rect }
    UIManager:setDirty(self, "fast", b.rect)

    self._fx_timer = function()
        self._fx_timer = nil
        self._fx = nil
        if self._closed then return end
        self:_applyQuality(quality)
    end
    UIManager:scheduleIn(FX_HOLD, self._fx_timer)
end

-- "Page N" en el header: cierra el Review Card y navega al libro en esa página.
-- Delega en el scrubber (historial de navegación + cierre limpio), igual que "Show in book" del panel de detalles.
function ReviewView:_gotoPageInBook()
    if self._closed or self._going_to_book then return end
    local card = self.due[self.current]
    local scrubber = self.scrubber_ui
    local page = card and card.entry and card.entry.page
    if not scrubber or not page then return end
    self._going_to_book = true   -- evita que un segundo toque lo dispare dos veces

    -- Feedback breve antes de cerrar
    self._pressed_link = true
    if self._page_link_dimen then
        UIManager:setDirty(self, "ui", self._page_link_dimen)
    end

    UIManager:scheduleIn(0.08, function()
        self._pressed_link = false
        self:_saveProgress()
        self._closed = true
        self:_freeWidgets()
        UIManager:close(self)

        -- Con el Review Card ya cerrado, el scrubber navega y se cierra (el refresco completo lo hace _closeStay)
        UIManager:nextTick(function()
            pcall(function()
                scrubber:_gotoPage(page)
                scrubber:_closeStay()
            end)
        end)
    end)
end

function ReviewView:onTap(_arg, ges)
    if self._closed or not ges or not ges.pos then return true end
    if self._fx then return true end   -- mientras suena el efecto de un botón, se ignoran los toques
    self._key_vis = false              -- con toque, el anillo de foco del teclado se oculta

    if not ges.pos:intersectWith(self.card_rect) then
        self:_closeWithMessage(nil); return true
    end
    if ges.pos:intersectWith(self.close_rect) then
        self:_closeWithMessage(nil); return true
    end

    -- Pantalla final: solo "Done" y "Undo last card" responden
    if self._summary_mode then
        if self._summary_done_rect and ges.pos:intersectWith(self._summary_done_rect) then
            self:_closeWithMessage(nil)
            return true
        end
        if self._summary_undo_rect and ges.pos:intersectWith(self._summary_undo_rect) then
            self:_undo()
            return true
        end
        return true
    end

    -- Tap en "Page N" → cerrar el Review Card y saltar a esa página del libro
    if self._page_link_dimen and ges.pos:intersectWith(self._page_link_dimen) then
        self:_gotoPageInBook()
        return true
    end

    -- Tap en Undo → deshacer el último grade (solo si hay historial)
    if self._history and #self._history > 0 and ges.pos:intersectWith(self.undo_rect) then
        self:_undo()
        return true
    end

    -- Modo repaso: puntitos / flechas de navegación
    if self.review_only then
        for _, nb in ipairs(self._nav_dimens or {}) do
            if ges.pos:intersectWith(nb.dimen) then
                self:_navTap(nb, ges.pos); return true
            end
        end
        return true
    end

    for _, b in ipairs(self.btn_rects) do
        if ges.pos:intersectWith(b.rect) then
            self:_playFx(b, ges.pos); return true
        end
    end
    return true
end

-- Modo repaso: ir a la tarjeta `idx` (no guarda nada, solo cambia lo que se ve)
function ReviewView:_goTo(idx)
    if self._closed then return end
    idx = math.max(1, math.min(#self.due, idx))
    if idx == self.current then return end
    self.current = idx
    self:_loadCurrent()
    UIManager:setDirty(self, "ui", self.dimen)
end

function ReviewView:_navTap(nb, pos)
    local n = #self.due
    if nb.key == "dots" then
        -- Puntitos: salta al más cercano al toque (igual que en el panel de detalle)
        self:_goTo(math.floor((pos.x - nb.x0) / nb.pitch + 0.5) + 1)
    elseif nb.key == "first" then self:_goTo(1)
    elseif nb.key == "prev"  then self:_goTo(self.current - 1)
    elseif nb.key == "next"  then self:_goTo(self.current + 1)
    elseif nb.key == "last"  then self:_goTo(n)
    end
end

-- Si el Review Card se cierra por otra vía (no solo con la X), se liberan igual los widgets
function ReviewView:onCloseWidget()
    self._closed = true
    if self._fx_timer then UIManager:unschedule(self._fx_timer); self._fx_timer = nil end
    self._fx = nil
    self:_saveProgress()
    self:_freeWidgets()
end

-- Si el dispositivo se suspende con el Review Card abierto, se guarda lo pendiente (no se consume el evento)
function ReviewView:onSuspend()
    self:_saveProgress()
    return false
end

function ReviewView:onHold() return true end
-- Swipe vertical: desplaza la cita o la nota (la que esté bajo el dedo) cuando no entran completas
function ReviewView:onSwipe(_arg, ges)
    if self._summary_mode then return true end
    local dir = ges and ges.direction
    -- Modo repaso: swipe horizontal para pasar de tarjeta (izquierda = siguiente, derecha = anterior)
    if self.review_only then
        if dir == "west" then self:_goTo(self.current + 1); return true
        elseif dir == "east" then self:_goTo(self.current - 1); return true end
    end
    if dir == "north" then self:_scroll(1, ges.pos)
    elseif dir == "south" then self:_scroll(-1, ges.pos) end
    return true
end

function ReviewView:_scroll(dir, pos)
    local nr, nw = self._note_rect, self.widgets and self.widgets.note
    if pos and nr and nw and pos:intersectWith(nr) then
        pcall(function() if dir > 0 then nw:scrollDown() else nw:scrollUp() end end)
        UIManager:setDirty(self, "ui", nr)
        return
    end
    local q, qr = self._quote, self._quote_rect
    if q and qr and #q.lines > q.vis then
        local step = math.max(1, q.vis - 1)
        if dir > 0 then
            q.first = math.min(#q.lines - q.vis + 1, q.first + step)
        else
            q.first = math.max(1, q.first - step)
        end
        UIManager:setDirty(self, "ui", qr)
    end
end

-- ---------- Teclas (dispositivos sin pantalla táctil / con botones) ----------
-- Atrás = cerrar · Izquierda/Derecha (o página ←/→) = mover el foco entre Undo / Again / Good / Easy
-- (en modo repaso: tarjeta anterior / siguiente) · Select = confirmar lo que tiene foco
-- (en modo repaso: ir a la página del libro) · Arriba/Abajo = desplazar la cita o la nota.

function ReviewView:_keyOrder()
    local o = {}
    if self._history and #self._history > 0 then o[#o + 1] = "undo" end
    for _i, b in ipairs(self.btn_rects) do o[#o + 1] = b.quality end
    return o
end

function ReviewView:_keyDirty()
    local S, r = self.S, self.card_rect
    UIManager:setDirty(self, "ui", Geom:new{ x = r.x, y = self.button_y - S(8), w = r.w, h = self.button_h + S(16) })
    UIManager:setDirty(self, "ui", self.undo_rect)
end

function ReviewView:_keyMove(dir)
    local order = self:_keyOrder()
    local idx
    for i, k in ipairs(order) do
        if k == self._kfocus then idx = i; break end
    end
    if not idx then
        self._kfocus = "good"
    else
        self._kfocus = order[math.max(1, math.min(#order, idx + dir))]
    end
    self:_keyDirty()
end

-- Desplaza la cita; si ya no puede en esa dirección, la nota
function ReviewView:_scrollKey(dir)
    local q = self._quote
    if q and self._quote_rect and #q.lines > q.vis then
        local can = (dir > 0) and (q.first < #q.lines - q.vis + 1) or (dir < 0 and q.first > 1)
        if can then self:_scroll(dir); return end
    end
    local nr = self._note_rect
    if nr and self.widgets and self.widgets.note then
        self:_scroll(dir, Geom:new{ x = nr.x + 1, y = nr.y + 1, w = 0, h = 0 })
    end
end

function ReviewView:onScrubKeyBack()
    self:_closeWithMessage(nil)
    return true
end

function ReviewView:onScrubKeyPrev()
    if self._closed or self._fx then return true end
    self._key_vis = true
    if self._summary_mode then
        if self._history and #self._history > 0 then
            self._kfocus = "undo"
            UIManager:setDirty(self, "ui", self.card_rect)
        end
    elseif self.review_only then
        self:_goTo(self.current - 1)
    else
        self:_keyMove(-1)
    end
    return true
end

function ReviewView:onScrubKeyNext()
    if self._closed or self._fx then return true end
    self._key_vis = true
    if self._summary_mode then
        self._kfocus = "done"
        UIManager:setDirty(self, "ui", self.card_rect)
    elseif self.review_only then
        self:_goTo(self.current + 1)
    else
        self:_keyMove(1)
    end
    return true
end

function ReviewView:onScrubKeyUp()
    if self._closed or self._summary_mode then return true end
    self:_scrollKey(-1)
    return true
end

function ReviewView:onScrubKeyDown()
    if self._closed or self._summary_mode then return true end
    self:_scrollKey(1)
    return true
end

function ReviewView:onScrubKeySelect()
    if self._closed or self._fx then return true end
    self._key_vis = true
    local has_undo = self._history and #self._history > 0
    if self._summary_mode then
        if self._kfocus == "undo" and has_undo then self:_undo() else self:_closeWithMessage(nil) end
    elseif self.review_only then
        self:_gotoPageInBook()
    elseif self._kfocus == "undo" and has_undo then
        self:_undo()
    else
        local pick
        for _i, b in ipairs(self.btn_rects) do
            if b.quality == self._kfocus then pick = b; break end
            if b.quality == "good" then pick = pick or b end
        end
        if pick then self:_playFx(pick) end
    end
    return true
end

function ReviewView:paintTo(bb, _x, _y)
    local sw, sh = Screen:getWidth(), Screen:getHeight()

    -- Fondo: blanco con el patrón de rayas (hatching.lua); si no está disponible, gris clarito
    bb:paintRect(0, 0, sw, sh, Blitbuffer.COLOR_WHITE)
    local ok_h, Hatching = pcall(require, "hatching")
    if not (ok_h and Hatching and pcall(Hatching.paint, bb, 0, 0, sw, sh)) then
        bb:paintRect(0, 0, sw, sh, Blitbuffer.COLOR_LIGHT_GRAY)
    end

    local r = self.card_rect
    paintRoundRect(bb, r.x, r.y, r.w, r.h, self.radius, Blitbuffer.COLOR_BLACK)
    paintRoundRect(bb, r.x + self.border, r.y + self.border,
        r.w - self.border * 2, r.h - self.border * 2,
        math.max(1, self.radius - self.border), Blitbuffer.COLOR_WHITE)

    if self._summary_mode then
        self:_paintSummary(bb)
    else
        self:_paintHeader(bb)
        self:_paintContent(bb)
        if self.review_only then
            self:_paintNav(bb)
        else
            self:_paintButtons(bb)
        end
    end
end

function ReviewView:_paintCloseButton(bb)
    local S = self.S
    local cr = self.close_rect
    local tw_x = TextWidget:new{
        text = "✕", face = Font:getFace("cfont", S(16 + textOffset())), bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local xsz = tw_x:getSize()
    tw_x:paintTo(bb, cr.x + math.floor((cr.w - xsz.w) / 2), cr.y + math.floor((cr.h - xsz.h) / 2))
    tw_x:free()
end

function ReviewView:_paintHeader(bb)
    local r = self.card_rect
    local S = self.S

    -- Contador "N / M"
    local cnt = string.format("%d / %d", self.current, #self.due)
    local tw_cnt = TextWidget:new{
        text = cnt, face = Font:getFace("cfont", S(12 + textOffset())), bold = true,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    local csz = tw_cnt:getSize()
    tw_cnt:paintTo(bb, r.x + self.pad, r.y + self.border + math.floor((self.header_h - csz.h) / 2))
    tw_cnt:free()

    -- Undo (solo si hay historial), entre el capítulo y la X. Reutiliza el undo.svg del scrubber.
    local has_undo = self._history and #self._history > 0
    if has_undo then
        local ur = self.undo_rect
        if self._key_vis and self._kfocus == "undo" then   -- foco de teclado sobre Undo
            paintRoundRect(bb, ur.x, ur.y, ur.w, ur.h, S(10), Blitbuffer.COLOR_BLACK)
            paintRoundRect(bb, ur.x + S(2), ur.y + S(2), ur.w - S(4), ur.h - S(4), S(8), Blitbuffer.COLOR_WHITE)
        end
        local icon = self.scrubber_ui and self.scrubber_ui.icon_details_close
        if icon then
            local isz = icon:getSize()
            icon:paintTo(bb, ur.x + math.floor((ur.w - isz.w) / 2), ur.y + math.floor((ur.h - isz.h) / 2))
        else
            local tw_u = TextWidget:new{
                text = "↺", face = Font:getFace("cfont", S(18 + textOffset())), bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            local usz = tw_u:getSize()
            tw_u:paintTo(bb, ur.x + math.floor((ur.w - usz.w) / 2), ur.y + math.floor((ur.h - usz.h) / 2))
            tw_u:free()
        end
    end

    -- Título del capítulo al lado del contador (se corta con "…" si no entra antes del Undo / la X)
    local chapter = self.display and self.display.chapter
    if type(chapter) == "string" and chapter ~= "" and chapter ~= "—" then
        local cx0 = r.x + self.pad + csz.w + S(12)
        local right_limit = has_undo and self.undo_rect.x or self.close_rect.x
        local max_w = right_limit - S(8) - cx0
        if max_w > S(40) then
            local tw_ch = TextWidget:new{
                text = chapter, face = Font:getFace("cfont", S(12 + textOffset())),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                max_width = max_w, truncate_with_ellipsis = true,
            }
            local chsz = tw_ch:getSize()
            tw_ch:paintTo(bb, cx0, r.y + self.border + math.floor((self.header_h - chsz.h) / 2))
            tw_ch:free()
        end
    end

    self:_paintCloseButton(bb)

    -- Separador
    local sep_y = r.y + self.border + self.header_h
    bb:paintRect(r.x + self.border, sep_y, r.w - self.border * 2, 1, Blitbuffer.COLOR_LIGHT_GRAY)
end

function ReviewView:_paintContent(bb)
    local S = self.S
    local r = self.card_rect
    local cx = r.x + self.pad
    local cw = r.w - self.pad * 2
    local cy = self.content_top

    -- Header: "Page N" como link inline (subrayado gris) · "Tipo (Color)"
    if self.widgets.page_link then
        local psz = self.widgets.page_link:getSize()
        local link_x, link_y = cx, cy
        local underline_h = math.max(1, S(2))

        -- Marca de la última calificación (! / ✓ / ★) a la izquierda de "Page N"; el link se corre a la derecha
        local mk = self._mark
        if mk then
            paintQualityMark(bb, mk.quality, cx + math.floor(mk.w / 2), link_y + math.floor(psz.h / 2),
                mk.size, Blitbuffer.COLOR_BLACK)
            link_x = cx + mk.w + mk.gap
        end
        local gap_before_type = S(10)
        local gap_after_underline = S(12)

        -- Feedback visual al presionar (fondo gris clarito)
        if self._pressed_link then
            paintRoundRect(bb, link_x - S(4), link_y - S(4),
                psz.w + S(8), psz.h + underline_h + S(8), S(4),
                Blitbuffer.COLOR_LIGHT_GRAY)
        end

        self.widgets.page_link:paintTo(bb, link_x, link_y)

        -- Subrayado gris justo debajo del texto (mismo estilo que el link del panel de detalles)
        bb:paintRect(link_x, link_y + psz.h, psz.w, underline_h, Blitbuffer.COLOR_DARK_GRAY)

        -- Rectángulo táctil con padding generoso (no solapa el type label)
        self._page_link_dimen = Geom:new{
            x = link_x - S(6),
            y = link_y - S(6),
            w = psz.w + S(12),
            h = psz.h + underline_h + S(12),
        }

        -- Type label al lado del link (info secundaria, no tappable)
        if self.widgets.type_label then
            local tsz = self.widgets.type_label:getSize()
            local tx = link_x + psz.w + gap_before_type
            local ty = link_y + math.floor((psz.h - tsz.h) / 2)
            self.widgets.type_label:paintTo(bb, tx, ty)
        end

        cy = cy + psz.h + underline_h + gap_after_underline
    else
        self._page_link_dimen = nil
    end

    -- Cita como en el panel de detalles: cada línea con su fondo de color (resaltado), invertida
    -- (blanco sobre negro), subrayada o tachada, según el tipo de la anotación
    if self._quote and self._quote_h > 0 then
        local q = self._quote
        local etype = self.display.quote_type or "normal"
        local ql, ql_inv = self.widgets.qline, self.widgets.qline_inv
        local hl_color
        if etype ~= "invert" then
            local ok_cfm, CFM = pcall(require, "color_filter_menu")
            if ok_cfm and CFM and CFM.resolveColor then
                hl_color = CFM.resolveColor(self.display.quote_color or "yellow")
            end
            hl_color = hl_color or Blitbuffer.COLOR_GRAY
        end
        for i = q.first, q.first + q.vis - 1 do
            local ln = q.lines[i]
            if not ln then break end
            local lw = q.widths[i]
            local ly = cy + (i - q.first) * q.line_h
            if ln ~= "" then
                if etype == "invert" then
                    bb:paintRect(cx, ly, lw, q.line_h, Blitbuffer.COLOR_BLACK)
                    ql_inv.text = nil; ql_inv:setText(ln); ql_inv:paintTo(bb, cx, ly)
                else
                    if etype == "normal" then paintColorRect(bb, cx, ly, lw, q.line_h, hl_color) end
                    ql.text = nil; ql:setText(ln); ql:paintTo(bb, cx, ly)
                    if etype == "underline" then
                        paintColorRect(bb, cx, ly + q.line_h - S(3), lw, S(2), hl_color)
                    elseif etype == "strikethrough" then
                        paintColorRect(bb, cx, ly + math.floor(q.line_h / 2), lw, S(2), hl_color)
                    end
                end
            end
        end
        -- Zona del swipe y triangulitos de scroll (en el margen derecho, como en el panel de detalle)
        self._quote_rect = Geom:new{ x = cx, y = cy, w = cw + self.pad, h = self._quote_h }
        if #q.lines > q.vis then
            local gw, gh = S(10), S(6)
            paintScrollMarks(bb, cx + cw + math.floor((self.pad - gw) / 2), cy, gw, gh, self._quote_h,
                q.first > 1, (q.first + q.vis - 1) < #q.lines)
        end
        cy = cy + self._quote_h + S(10)
    else
        self._quote_rect = nil
    end

    -- Nota (con una fina línea separadora)
    if self.widgets.note and self._note_h > 0 then
        bb:paintRect(cx, cy - S(4), cw, 1, Blitbuffer.COLOR_LIGHT_GRAY)
        self.widgets.note:paintTo(bb, cx, cy)
        self._note_rect = Geom:new{ x = cx, y = cy, w = cw + self.pad, h = self._note_h }
        local nw = self.widgets.note
        local okv, vis, all, vtop = pcall(function()
            return nw:getVisLineCount(), nw:getAllLineCount(), nw.virtual_line_num
        end)
        if okv and vis and all and vtop and all > vis then
            local gw, gh = S(10), S(6)
            paintScrollMarks(bb, cx + cw + math.floor((self.pad - gw) / 2), cy, gw, gh, self._note_h,
                vtop > 1, (vtop + vis - 1) < all)
        end
    else
        self._note_rect = nil
    end
end

-- Pantalla final "SESSION COMPLETE!": título, cantidad de tarjetas, desglose Again/Good/Easy,
-- botón Done y link "Undo last card". El bloque de arriba se centra en el espacio libre y, si no entra
-- (pantalla horizontal, DPI alto), todo el bloque se achica en bloque en vez de solaparse.
function ReviewView:_paintSummary(bb)
    local S = self.S
    local r = self.card_rect
    local cx = r.x + math.floor(r.w / 2)
    local BLACK, GRAY = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_DARK_GRAY

    self:_paintCloseButton(bb)

    local stats = {}
    for _i, k in ipairs({ "again", "good", "easy" }) do
        if (self._stats[k] or 0) > 0 then stats[#stats + 1] = k end
    end
    local labels = { again = _("Again"), good = _("Good"), easy = _("Easy") }
    local total = (self._stats.again or 0) + (self._stats.good or 0) + (self._stats.easy or 0)
    local has_undo = #self._history > 0
    local t_off = textOffset()

    -- Bloque de abajo (fijo): Done + link de Undo
    local btn_w, btn_h = S(180), S(52)
    local undo_row_h = has_undo and S(30) or 0
    local bottom_block_h = btn_h + (has_undo and S(10) or 0) + undo_row_h
    local bottom_top = r.y + r.h - self.border - self.pad - bottom_block_h

    -- Espacio para el bloque de arriba
    local top_y = r.y + self.border + S(12)
    local avail = bottom_top - S(12) - top_y

    -- Arma el bloque de arriba con un factor de escala k (1 = tamaño normal)
    local function build(k)
        local items, frees = {}, {}
        local function K(v) return S(v * k) end
        local function text_item(text, size, bold, color, gap)
            local w = TextWidget:new{
                text = text, face = Font:getFace("cfont", math.max(8, math.floor(S((size + t_off) * k)))),
                bold = bold, fgcolor = color,
            }
            frees[#frees + 1] = w
            local sz = w:getSize()
            items[#items + 1] = { h = sz.h, gap = K(gap),
                paint = function(y) w:paintTo(bb, cx - math.floor(sz.w / 2), y) end }
        end

        text_item("★  " .. _("SESSION") .. "  ★", 15, true, GRAY, 2)
        text_item(_("COMPLETE!"), 34, true, BLACK, 18)
        local div_w, div_h = K(180), math.max(1, K(2))
        items[#items + 1] = { h = div_h, gap = K(18),
            paint = function(y) bb:paintRect(cx - math.floor(div_w / 2), y, div_w, div_h, BLACK) end }
        text_item(_("You studied"), 13, false, GRAY, 2)
        text_item(tostring(total), 64, true, BLACK, 2)
        text_item(total == 1 and _("card") or _("cards"), 13, false, GRAY, 24)

        if #stats > 0 then
            local num_f = Font:getFace("cfont", math.max(8, math.floor(S((30 + t_off) * k))))
            local lbl_f = Font:getFace("cfont", math.max(8, math.floor(S((12 + t_off) * k))))
            local col_w = math.min(S(120), math.floor((r.w - self.pad * 2) / #stats))
            local cols, row_h = {}, 0
            for _i, key in ipairs(stats) do
                local tn = TextWidget:new{ text = tostring(self._stats[key]), face = num_f, bold = true, fgcolor = BLACK }
                local tl = TextWidget:new{ text = labels[key] or key, face = lbl_f, fgcolor = GRAY }
                frees[#frees + 1] = tn; frees[#frees + 1] = tl
                local nsz, lsz = tn:getSize(), tl:getSize()
                row_h = math.max(row_h, nsz.h + K(4) + lsz.h)
                cols[#cols + 1] = { tn = tn, tl = tl, nsz = nsz, lsz = lsz }
            end
            local gap4 = K(4)
            items[#items + 1] = { h = row_h, gap = 0, paint = function(y)
                local x0 = cx - math.floor(col_w * #cols / 2)
                for i, c in ipairs(cols) do
                    local colx = x0 + (i - 1) * col_w
                    c.tn:paintTo(bb, colx + math.floor((col_w - c.nsz.w) / 2), y)
                    c.tl:paintTo(bb, colx + math.floor((col_w - c.lsz.w) / 2), y + c.nsz.h + gap4)
                end
            end }
        end

        local T = 0
        for i, it in ipairs(items) do T = T + it.h + (i < #items and it.gap or 0) end
        return items, frees, T
    end

    local k, items, frees, T = 1
    for _try = 1, 4 do
        items, frees, T = build(k)
        if T <= avail or k <= 0.5 then break end
        for _i, w in ipairs(frees) do pcall(function() w:free() end) end
        k = math.max(0.5, k * avail / T * 0.97)
    end

    local y = top_y + math.max(0, math.floor((avail - T) / 2))
    for i, it in ipairs(items) do
        it.paint(y)
        y = y + it.h + it.gap
    end
    for _i, w in ipairs(frees) do pcall(function() w:free() end) end

    -- Botón Done
    self._summary_done_rect = Geom:new{ x = cx - math.floor(btn_w / 2), y = bottom_top, w = btn_w, h = btn_h }
    local dr = self._summary_done_rect
    if self._key_vis and self._kfocus ~= "undo" then   -- anillo de foco de teclado alrededor de Done
        paintRoundRect(bb, dr.x - S(5), dr.y - S(5), dr.w + S(10), dr.h + S(10), S(19), BLACK)
        paintRoundRect(bb, dr.x - S(3), dr.y - S(3), dr.w + S(6), dr.h + S(6), S(17), Blitbuffer.COLOR_WHITE)
    end
    paintRoundRect(bb, dr.x, dr.y, dr.w, dr.h, S(14), BLACK)
    local tw_done = TextWidget:new{ text = _("Done"), face = Font:getFace("cfont", S(17 + t_off)), bold = true,
                                    fgcolor = Blitbuffer.COLOR_WHITE }
    local dsz = tw_done:getSize()
    tw_done:paintTo(bb, cx - math.floor(dsz.w / 2), dr.y + math.floor((dr.h - dsz.h) / 2))
    tw_done:free()

    -- Link "Undo last card"
    if has_undo then
        local tw_u = TextWidget:new{ text = "↺  " .. _("Undo last card"), face = Font:getFace("cfont", S(12 + t_off)),
                                     fgcolor = GRAY }
        local usz = tw_u:getSize()
        local row_y = dr.y + dr.h + S(10)
        tw_u:paintTo(bb, cx - math.floor(usz.w / 2), row_y + math.floor((undo_row_h - usz.h) / 2))
        tw_u:free()
        self._summary_undo_rect = Geom:new{
            x = cx - math.floor(usz.w / 2) - S(14), y = row_y,
            w = usz.w + S(28), h = undo_row_h,
        }
        if self._key_vis and self._kfocus == "undo" then   -- foco de teclado sobre "Undo last card"
            local ur2, th = self._summary_undo_rect, math.max(2, S(2))
            bb:paintRect(ur2.x, ur2.y, ur2.w, th, BLACK)
            bb:paintRect(ur2.x, ur2.y + ur2.h - th, ur2.w, th, BLACK)
            bb:paintRect(ur2.x, ur2.y, th, ur2.h, BLACK)
            bb:paintRect(ur2.x + ur2.w - th, ur2.y, th, ur2.h, BLACK)
        end
    else
        self._summary_undo_rect = nil
    end
end

-- Modo repaso: fila de navegación abajo. Puntitos (los mismos del panel de detalle) si entran;
-- si son demasiados: |<  <  14|69  >  >|
function ReviewView:_paintNav(bb)
    local S = self.S
    local BLACK, GRAY = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_DARK_GRAY
    local nr = self.nav_rect
    if not nr then return end
    local n, idx = #self.due, self.current
    local enabled = { first = idx > 1, prev = idx > 1, next = idx < n, last = idx < n }

    local dot_r = math.max(2, math.floor(S(2.5)))
    local dot_rmax = math.floor(dot_r * 1.5)
    local dot_min_pitch = 2 * dot_r + S(3)
    local dot_pitch = S(11)
    if n > 1 then
        dot_pitch = math.floor(math.min(dot_pitch, (nr.w - 2 * dot_rmax) / (n - 1)))
    end
    local use_dots = (n == 1) or (n > 1 and dot_pitch >= dot_min_pitch)

    self._nav_dimens = {}
    if use_dots then
        local dots_w = (n - 1) * dot_pitch + 2 * dot_rmax
        local dots_x = nr.x + math.floor((nr.w - dots_w) / 2)
        local dots_cy = nr.y + math.floor(nr.h / 2)
        local x0 = dots_x + dot_rmax
        for i = 1, n do
            local is_cur = (i == idx)
            local r = is_cur and dot_rmax or dot_r
            paintRoundRect(bb, x0 + (i - 1) * dot_pitch - r, dots_cy - r, r * 2, r * 2, r,
                is_cur and BLACK or GRAY)
        end
        if n > 1 then
            self._nav_dimens[1] = {
                key = "dots", x0 = x0, pitch = math.max(1, dot_pitch),
                dimen = Geom:new{ x = nr.x, y = nr.y, w = nr.w, h = nr.h },
            }
        end
        return
    end

    local cells = {
        { key = "first", wt = 1 }, { key = "prev", wt = 1 }, { key = "counter", wt = 1.5 },
        { key = "next", wt = 1 }, { key = "last", wt = 1 },
    }
    local total_wt = 0
    for _i, c in ipairs(cells) do total_wt = total_wt + c.wt end
    local gh, gw, barw, gap = S(16), S(11), S(3), S(3)
    local cx = nr.x
    for i, c in ipairs(cells) do
        local cw = (i == #cells) and (nr.x + nr.w - cx) or math.floor(nr.w * c.wt / total_wt)
        local k = c.key
        if k == "counter" then
            local ctw = TextWidget:new{
                text = string.format("%d|%d", idx, n), face = Font:getFace("cfont", S(14 + textOffset())), bold = true,
                fgcolor = BLACK,
            }
            local csz = ctw:getSize()
            ctw:paintTo(bb, cx + math.floor((cw - csz.w) / 2), nr.y + math.floor((nr.h - csz.h) / 2))
            ctw:free()
        else
            local en = enabled[k]
            local col = en and BLACK or Blitbuffer.COLOR_LIGHT_GRAY
            local with_bar = (k == "first" or k == "last")
            local total_w = with_bar and (gw + gap + barw) or gw
            local gx = cx + math.floor((cw - total_w) / 2)
            local gy = nr.y + math.floor((nr.h - gh) / 2)
            if k == "first" then
                bb:paintRect(gx, gy, barw, gh, col)
                paintTriangle(bb, gx + barw + gap, gy, gw, gh, true, col)
            elseif k == "prev" then
                paintTriangle(bb, gx, gy, gw, gh, true, col)
            elseif k == "next" then
                paintTriangle(bb, gx, gy, gw, gh, false, col)
            else
                paintTriangle(bb, gx, gy, gw, gh, false, col)
                bb:paintRect(gx + gw + gap, gy, barw, gh, col)
            end
            if en then
                self._nav_dimens[#self._nav_dimens + 1] = {
                    key = k, dimen = Geom:new{ x = cx, y = nr.y, w = cw, h = nr.h },
                }
            end
        end
        cx = cx + cw
    end
end

function ReviewView:_paintButtons(bb)
    local S = self.S
    for _, b in ipairs(self.btn_rects) do
        local r = b.rect
        -- Con teclado, el botón con foco lleva un borde más grueso
        local focused = self._key_vis and self._kfocus == b.quality
        local bw = focused and S(6) or S(2)
        paintRoundRect(bb, r.x, r.y, r.w, r.h, S(12), Blitbuffer.COLOR_BLACK)
        paintRoundRect(bb, r.x + bw, r.y + bw,
            r.w - bw * 2, r.h - bw * 2, math.max(1, S(12) - bw), Blitbuffer.COLOR_WHITE)

        if b.label_w and b.interval_w then
            local lsz = b.label_w:getSize()
            local ssz = b.interval_w:getSize()
            local gap = S(6)
            local group_h = lsz.h + gap + ssz.h
            local y0 = r.y + math.floor((r.h - group_h) / 2)
            b.label_w:paintTo(bb, r.x + math.floor((r.w - lsz.w) / 2), y0)
            b.interval_w:paintTo(bb, r.x + math.floor((r.w - ssz.w) / 2), y0 + lsz.h + gap)
        elseif b.label_w then
            local lsz = b.label_w:getSize()
            b.label_w:paintTo(bb, r.x + math.floor((r.w - lsz.w) / 2), r.y + math.floor((r.h - lsz.h) / 2))
        end

        if self._fx and self._fx.quality == b.quality then
            self:_paintButtonFx(bb, b)
        end
    end
end

-- El cuadro de feedback: botón relleno de negro con la marca en blanco y el intervalo debajo.
-- Cada botón lleva su marca fija (sin animar): Again → !   Good → ✓   Easy → ★
function ReviewView:_paintButtonFx(bb, b)
    local S = self.S
    local r = b.rect
    local q = b.quality
    local WHITE, BLACK = Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK

    paintRoundRect(bb, r.x, r.y, r.w, r.h, S(12), BLACK)

    local cx = r.x + math.floor(r.w / 2)
    local interval_txt = "<" .. SRS.formatInterval(self.display.intervals and self.display.intervals[q]) .. ">"

    paintQualityMark(bb, q, cx, r.y + math.floor(r.h * 0.40), S(30), WHITE)

    local tw = TextWidget:new{ text = interval_txt, face = Font:getFace("cfont", S(10 + textOffset())), fgcolor = WHITE }
    local sz = tw:getSize()
    tw:paintTo(bb, cx - math.floor(sz.w / 2), r.y + math.floor(r.h * 0.74) - math.floor(sz.h / 2))
    tw:free()
end

return ReviewView
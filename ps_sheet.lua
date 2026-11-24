--[[
    page_scrubber.koplugin/ps_sheet.lua

    Hojas que suben desde el borde de abajo, copiadas del option_sheet.lua y del
    confirm_sheet.lua de KiKome: un panel blanco con línea negra arriba y una flechita
    hacia abajo, un título en negrita sobre una regla y, abajo, píldoras de opciones (la
    elegida en negro, las demás en gris) o una pregunta con dos píldoras.

      local Sheet = require("ps_sheet")

      Sheet.options{                         -- una hoja de opciones
          title = "Add button",
          rows = {
              { options = { { id = "icon", label = "Change icon", icon = "image" },
                            { id = "remove", label = "Remove button", icon = "trash-2" } },
                close = true, on_pick = function(id) ... end },
          },
      }

      Sheet.confirm{                         -- una pregunta
          title = "Remove button", message = "Remove it from the selection menu?",
          confirm_text = "Remove", on_confirm = function() end, on_cancel = function() end,
      }
      Sheet.newConfirm{ ... }                -- lo mismo, pero devuelve el widget sin mostrarlo
                                             -- (lo usa ps_dialogs.lua para reemplazar ConfirmBox)

    Un cartel de una sola opción ("OK") no necesita hoja: ps_toast.lua.
]]--

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget  = require("ui/widget/textboxwidget")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local Kit            = require("svg_picker").kit

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local C_RULE      = Blitbuffer.Color8(0x99)  -- la regla fina bajo el título
local C_IDLE      = Blitbuffer.Color8(0xDD)  -- relleno de una opción no elegida / de Cancel
local C_SECONDARY = Blitbuffer.Color8(0x55)  -- rótulos y mensajes

local U, face, iconWidget, _ = Kit.U, Kit.face, Kit.iconWidget, Kit._

local M = {}

-- Cuánto sobrepasa la hoja el borde de arriba de la barra inferior: como la hoja tiene las
-- esquinas de arriba curvas, justo a ras se asoma la línea de la barra en las puntas.
local BAR_OVERSHOOT = U(16)

-- Un repintado más cuando el panel ya está libre, por si el primero se pierde (Kindle).
local function settle(widget, region_fn)
    local token = {}
    widget._ps_settle = token
    UIManager:scheduleIn(0.25, function()
        if widget._ps_settle ~= token then return end
        widget._ps_settle = nil
        if widget.closed then return end
        local ok, r = pcall(region_fn)
        if ok and r then UIManager:setDirty(nil, "ui", r) end
    end)
end

-- Texto con sus primeros caracteres cortados (y "…" al principio) hasta que entre.
local function tailText(text, f, max_w)
    local function width(s)
        local t = TextWidget:new{ text = s, face = f, bold = true }
        local w = t:getSize().w
        t:free()
        return w
    end
    if width(text) <= max_w then return text end
    local guard = 0
    while text ~= "" and width("…" .. text) > max_w and guard < 300 do
        text = (text:gsub("^[%z\1-\127\194-\244][\128-\191]*", "", 1))
        guard = guard + 1
    end
    return "…" .. text
end

-- Rectángulo con las esquinas de arriba de radio rt y las de abajo de radio rb (0: recto).
local function fillRounded(bb, x, y, w, h, color, rt, rb)
    local limit = math.floor(math.min(w, h) / 2)
    rt = math.max(0, math.min(rt, limit))
    rb = math.max(0, math.min(rb or 0, limit))
    if h - rt - rb > 0 then bb:paintRect(x, y + rt, w, h - rt - rb, color) end
    if rt > 0 then bb:paintRoundedRect(x, y, w, 2 * rt, color, rt) end
    if rb > 0 then bb:paintRoundedRect(x, y + h - 2 * rb, w, 2 * rb, color, rb) end
end

-- ════════════════════════════════════════════════════════════════════════════
-- HOJA DE OPCIONES
-- ════════════════════════════════════════════════════════════════════════════
local Options = InputContainer:extend{
    modal = true,
    name = "page_scrubber_option_sheet",
    title = "", rows = {}, on_close = nil,
}

function Options:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.left, self.width, self.bottom = 0, Screen:getWidth(), Screen:getHeight()
    self.corner, self.border = U(14), U(2)
    self.ges_events = {
        TapSheet   = { GestureRange:new{ ges = "tap",   range = self.dimen } },
        SwipeSheet = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self.key_events = self.key_events or {}
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
    self.chevron_size = U(26)
    self:build()
end

function Options:release()
    for _i, w in ipairs(self.widgets or {}) do
        if w.free then w:free() end
    end
end

function Options:build()
    self:release()
    self.widgets, self.chips = {}, {}
    self.labels, self.heads = {}, {}
    local function keep(w)
        self.widgets[#self.widgets + 1] = w
        return w
    end
    local w = self.width
    local inset = U(45)
    local chip_h, chip_gap, chip_pad = U(41), U(8), U(17)
    local icon_size, icon_gap = U(20), U(15)
    local label_h, row_gap = U(24), U(14)

    local y = U(3)
    self.chevron = keep(iconWidget("chevron-down", self.chevron_size, BLACK))
    self.heading = keep(TextWidget:new{
        text = self.title, face = face(17), bold = true, max_width = w - 2 * inset,
    })
    local center = y + U(61)
    self.heading_pos = { x = inset, y = center - math.floor(self.heading:getSize().h / 2) }
    local rule_y = center + U(24)
    self.rule = { x = U(17.5), y = rule_y, w = w - 2 * U(17.5), h = math.max(1, U(2)) }
    y = rule_y + self.rule.h + U(13)

    local function measure(src)
        local block = { src = src, chips = {} }
        if src.label then
            block.lbl = keep(TextWidget:new{ text = src.label, face = face(14), fgcolor = C_SECONDARY })
        end
        local line = 0
        for _i, opt in ipairs(src.options or {}) do
            local selected
            if src.multi then
                -- Selección múltiple: src.selected es un conjunto { id = true }
                selected = type(src.selected) == "table" and src.selected[opt.id] == true
            else
                selected = (opt.id == src.selected)
            end
            local chip = { id = opt.id, src = src, selected = selected }
            chip.label = keep(TextWidget:new{
                text = opt.label, face = face(15), fgcolor = selected and WHITE or BLACK,
                max_width = w - 2 * inset - 2 * chip_pad - icon_size - icon_gap,
            })
            if opt.icon then chip.image = keep(iconWidget(opt.icon, icon_size, BLACK)) end
            if opt.dot and not chip.image then chip.dot = opt.dot end   -- círculo con el color de un highlight
            local icon_space = (chip.image or chip.dot) and (icon_size + icon_gap) or 0
            chip.w = chip.label:getSize().w + icon_space + 2 * chip_pad
            block.chips[#block.chips + 1] = chip
            line = line + chip.w + ((#block.chips > 1) and chip_gap or 0)
        end
        block.w = math.max(line, block.lbl and block.lbl:getSize().w or 0)
        return block
    end

    local function place(block, x0, y0)
        local py = y0
        if block.lbl then
            self.labels[#self.labels + 1] = { w = block.lbl, x = x0, y = py, h = label_h }
            py = py + label_h
        end
        local x = x0
        for _i, chip in ipairs(block.chips) do
            if x > x0 and x + chip.w > w - inset then
                x = x0
                py = py + chip_h + chip_gap
            end
            chip.rect = Geom:new{ x = x, y = py, w = chip.w, h = chip_h }
            chip.label_x = x + chip.w - chip_pad - chip.label:getSize().w
            self.chips[#self.chips + 1] = chip
            x = x + chip.w + chip_gap
        end
        return py + chip_h + row_gap
    end

    for _ri, row in ipairs(self.rows) do
        if row.heading then
            local hw = keep(TextWidget:new{ text = row.heading, face = face(17), bold = true })
            local hc = y + U(26)
            local hrule_y = hc + U(24)
            self.heads[#self.heads + 1] = {
                w = hw, x = inset, y = hc - math.floor(hw:getSize().h / 2), rule_y = hrule_y,
            }
            y = hrule_y + math.max(1, U(2)) + U(13)
        else
            y = place(measure(row), inset, y)
        end
    end
    local natural = y + U(5)

    -- Altura mínima: con el scrubber abierto, el contorno de arriba queda a la altura del borde de
    -- arriba de la barra inferior (la hoja la cubre), igual que la hoja de confirmación. Si el
    -- contenido no entra, crece hacia arriba. Vale para toda hoja de opciones del plugin.
    local height = natural
    local okb, bar_top = pcall(function() return require("ps_bar").top() end)
    if okb and bar_top then
        height = math.max(natural, self.bottom - bar_top + BAR_OVERSHOOT)
    end
    local extra = height - natural
    if extra > 0 then
        -- las opciones quedan centradas en el espacio de abajo del título
        local shift = math.floor(extra / 2)
        for _i, chip in ipairs(self.chips) do chip.rect.y = chip.rect.y + shift end
        for _i, l in ipairs(self.labels) do l.y = l.y + shift end
        for _i, hd in ipairs(self.heads) do
            hd.y = hd.y + shift
            hd.rule_y = hd.rule_y + shift
        end
    end
    self.height = height
    self.top = self.bottom - self.height
end

function Options:region()
    local sep = U(3)
    return Geom:new{ x = self.left, y = self.top - sep, w = self.width, h = self.height + sep }
end

function Options:paintTo(bb, x, y)
    x = x + self.left
    local top = y + self.top
    local w, h, r, b = self.width, self.height, self.corner, self.border
    local sep = U(3)
    fillRounded(bb, x, top - sep, w, h + sep, WHITE, r, 0)          -- línea blanca que la despega
    fillRounded(bb, x, top, w, h, BLACK, r, 0)                      -- contorno
    fillRounded(bb, x + b, top + b, w - 2 * b, h - b, WHITE, math.max(0, r - b), 0)
    self.chevron:paintTo(bb, x + math.floor((w - self.chevron_size) / 2),
        top + U(21) - math.floor(self.chevron_size / 2))
    bb:paintRect(x + self.rule.x, top + self.rule.y, self.rule.w, self.rule.h, C_RULE)
    self.heading:paintTo(bb, x + self.heading_pos.x, top + self.heading_pos.y)
    for _i, hd in ipairs(self.heads or {}) do
        bb:paintRect(x + self.rule.x, top + hd.rule_y, self.rule.w, self.rule.h, C_RULE)
        hd.w:paintTo(bb, x + hd.x, top + hd.y)
    end
    for _i, l in ipairs(self.labels or {}) do
        l.w:paintTo(bb, x + l.x, top + l.y + math.floor((l.h - l.w:getSize().h) / 2))
    end
    for _i, chip in ipairs(self.chips) do
        local rc = chip.rect
        local radius = math.floor(rc.h / 2)
        bb:paintRoundedRect(x + rc.x, top + rc.y, rc.w, rc.h, chip.selected and BLACK or C_IDLE, radius)
        if chip.image then
            local isz = chip.image:getSize()
            local ix, iy = x + rc.x + U(17), top + rc.y + math.floor((rc.h - isz.h) / 2)
            if chip.selected then
                -- ícono negro sobre blanco y se invierte: ícono blanco sobre la píldora negra
                bb:paintRect(ix, iy, isz.w, isz.h, WHITE)
                chip.image:paintTo(bb, ix, iy)
                bb:invertRect(ix, iy, isz.w, isz.h)
            else
                chip.image:paintTo(bb, ix, iy)
            end
        end
        if chip.dot then
            local okc, CFM = pcall(require, "color_filter_menu")
            if okc and CFM and CFM.paintDot then
                local d = U(20)
                CFM.paintDot(bb, x + rc.x + U(17), top + rc.y + math.floor((rc.h - d) / 2), d, chip.dot,
                    chip.selected and WHITE or BLACK)
            end
        end
        chip.label:paintTo(bb, x + chip.label_x, top + rc.y + math.floor((rc.h - chip.label:getSize().h) / 2))
    end
end

function Options:dismiss()
    self.closed = true
    UIManager:close(self)
    return true
end

function Options:onTapSheet(_ev, ges)
    local pos = ges.pos
    -- un toque afuera de la hoja, o en su manija, la cierra
    if pos.y < self.top + U(42) or pos.x < self.left or pos.x >= self.left + self.width then
        return self:dismiss()
    end
    for _i, chip in ipairs(self.chips) do
        local r = chip.rect
        if pos.x >= self.left + r.x and pos.x < self.left + r.x + r.w
            and pos.y >= self.top + r.y and pos.y < self.top + r.y + r.h then
            local row = chip.src
            if row.multi then
                -- Tocar una opción la prende o la apaga; quien llama decide qué hace el cambio
                local now_on = not chip.selected
                if type(row.selected) ~= "table" then row.selected = {} end
                row.selected[chip.id] = now_on or nil
                if row.on_pick then row.on_pick(chip.id, now_on) end
                self:build()
                UIManager:setDirty(self, "ui", self:region())
                break
            end
            if chip.selected and not row.toggle then break end
            local value = (not chip.selected) and chip.id or nil
            row.selected = value
            if row.close then self:dismiss() end
            if row.on_pick then
                if row.close then
                    -- la hoja ya se cerró: lo que sigue abre otra pantalla un momento después
                    UIManager:nextTick(function() row.on_pick(value) end)
                else
                    row.on_pick(value)
                end
            end
            if not row.close then
                self:build()
                UIManager:setDirty(self, "ui", self:region())
            end
            break
        end
    end
    return true
end

function Options:onSwipeSheet(_ev, ges)
    if ges.direction == "south" then return self:dismiss() end
    return true
end

function Options:onAnyKeyPressed()
    return self:dismiss()
end

function Options:onShow()
    UIManager:setDirty(self, "ui", self:region())
    settle(self, function() return self:region() end)
    return true
end

function Options:onCloseWidget()
    self.closed = true
    self:release()
    UIManager:setDirty(nil, "ui", self:region())
    if self.on_close then
        local cb = self.on_close
        self.on_close = nil
        UIManager:nextTick(cb)
    end
end

function M.options(opts)
    local rows = opts.rows or {
        { options = opts.options or {}, selected = opts.selected, on_pick = opts.on_pick },
    }
    local sheet = Options:new{ title = opts.title or _("Options"), rows = rows, on_close = opts.on_close }
    UIManager:show(sheet, "ui", sheet:region())
    return sheet
end

-- ════════════════════════════════════════════════════════════════════════════
-- HOJA DE CONFIRMACIÓN
-- ════════════════════════════════════════════════════════════════════════════
local Confirm = InputContainer:extend{
    modal = true,
    name = "page_scrubber_confirm_sheet",
    title = "", title_tail = false, message = nil,
    confirm_text = nil, cancel_text = nil, toggle = nil,
    on_confirm = nil, on_cancel = nil,
}

function Confirm:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.width, self.left, self.bottom = Screen:getWidth(), 0, Screen:getHeight()
    self.corner, self.border = U(14), U(2)
    self.ges_events = {
        TapSheet   = { GestureRange:new{ ges = "tap",   range = self.dimen } },
        SwipeSheet = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:build()
end

function Confirm:release()
    for _i, w in ipairs(self.widgets or {}) do
        if w.free then w:free() end
    end
    self.widgets = nil
end

function Confirm:build()
    self:release()
    self.widgets = {}
    local function keep(w)
        self.widgets[#self.widgets + 1] = w
        return w
    end
    local w = self.width
    local inset = U(45)
    local inner = w - 2 * inset

    self.chevron_size = U(26)
    self.chevron = keep(iconWidget("chevron-down", self.chevron_size, BLACK))

    local has_title = self.title ~= nil and self.title ~= ""
    local y
    self.heading, self.rule = nil, nil
    if has_title then
        local f = face(17)
        local title = self.title
        if self.title_tail then title = tailText(title, f, inner) end
        self.heading = keep(TextWidget:new{ text = title, face = f, bold = true, max_width = inner })
        local center = U(3) + U(61)
        self.heading_pos = { x = inset, y = center - math.floor(self.heading:getSize().h / 2) }
        self.rule = { x = U(17.5), y = center + U(24), w = w - 2 * U(17.5), h = math.max(1, U(2)) }
        y = self.rule.y + self.rule.h + U(16)
    else
        y = U(56)
    end

    self.msg = nil
    if self.message and self.message ~= "" then
        self.msg = keep(TextBoxWidget:new{
            text = self.message, face = face(has_title and 15 or 17), width = inner,
            fgcolor = has_title and C_SECONDARY or BLACK, alignment = "left",
        })
        self.msg_pos = { x = inset, y = y }
        y = y + self.msg:getSize().h + U(20)
    end

    local pill_h, gap = U(44), U(12)
    local pill_w = math.floor((inner - gap) / 2)
    self.cancel_pill = { x = inset, y = y, w = pill_w, h = pill_h }
    self.ok_pill = { x = inset + pill_w + gap, y = y, w = pill_w, h = pill_h }
    self.cancel_label = keep(TextWidget:new{
        text = self.cancel_text or _("Cancel"), face = face(16),
        bgcolor = C_IDLE, max_width = pill_w - U(20),
    })
    self.ok_label = keep(TextWidget:new{
        text = self.confirm_text or _("Confirm"), face = face(16), bold = true,
        fgcolor = WHITE, bgcolor = BLACK, max_width = pill_w - U(20),
    })
    local natural = y + pill_h + U(26)

    -- Altura mínima: con el scrubber abierto, el contorno de arriba queda unos milímetros por encima del
    -- borde de arriba de la barra inferior (la hoja la cubre). Si el contenido no entra, crece hacia arriba.
    local height = natural
    local ok, bar_top = pcall(function() return require("ps_bar").top() end)
    if ok and bar_top then
        height = math.max(natural, self.bottom - bar_top + BAR_OVERSHOOT)
    end
    local extra = height - natural
    if extra > 0 then
        -- el mensaje y las píldoras quedan centrados en el espacio de abajo del título
        local shift = math.floor(extra / 2)
        if self.msg_pos then self.msg_pos.y = self.msg_pos.y + shift end
        self.cancel_pill.y = self.cancel_pill.y + shift
        self.ok_pill.y = self.ok_pill.y + shift
    end
    self.height = height
    self.top = self.bottom - self.height
end

function Confirm:region()
    return Geom:new{ x = self.left, y = self.top - U(3), w = self.width, h = self.height + U(3) }
end

function Confirm:paintTo(bb, x, y)
    local top = y + self.top
    local w, h, r, b = self.width, self.height, self.corner, self.border
    fillRounded(bb, x, top - U(3), w, h + U(3), WHITE, r, 0)
    fillRounded(bb, x, top, w, h, BLACK, r, 0)
    fillRounded(bb, x + b, top + b, w - 2 * b, h - b, WHITE, math.max(0, r - b), 0)
    self.chevron:paintTo(bb, x + math.floor((w - self.chevron_size) / 2),
        top + U(21) - math.floor(self.chevron_size / 2))
    if self.rule then
        bb:paintRect(x + self.rule.x, top + self.rule.y, self.rule.w, self.rule.h, C_RULE)
    end
    if self.heading then self.heading:paintTo(bb, x + self.heading_pos.x, top + self.heading_pos.y) end
    if self.msg then self.msg:paintTo(bb, x + self.msg_pos.x, top + self.msg_pos.y) end
    local function pill(p, color, label)
        bb:paintRoundedRect(x + p.x, top + p.y, p.w, p.h, color, math.floor(p.h / 2))
        local sz = label:getSize()
        label:paintTo(bb, x + p.x + math.floor((p.w - sz.w) / 2), top + p.y + math.floor((p.h - sz.h) / 2))
    end
    pill(self.cancel_pill, C_IDLE, self.cancel_label)
    pill(self.ok_pill, BLACK, self.ok_label)
end

local function hit(p, top, pos)
    return pos.x >= p.x and pos.x < p.x + p.w and pos.y >= top + p.y and pos.y < top + p.y + p.h
end

-- Cerrar sin confirmar (toque afuera, la manija, Back, Cancel).
function Confirm:cancel()
    self.closed = true
    UIManager:close(self)
    if self.on_cancel then
        local cb = self.on_cancel
        UIManager:nextTick(cb)
    end
    return true
end

function Confirm:onTapSheet(_ev, ges)
    local pos = ges.pos
    if pos.y < self.top + U(42) then return self:cancel() end
    if hit(self.ok_pill, self.top, pos) then
        self.closed = true
        UIManager:close(self)
        local fn = self.on_confirm
        if fn then UIManager:nextTick(function() fn() end) end
        return true
    end
    if hit(self.cancel_pill, self.top, pos) then return self:cancel() end
    return true
end

function Confirm:onSwipeSheet(_ev, ges)
    if ges.direction == "south" then return self:cancel() end
    return true
end

function Confirm:onClose()
    return self:cancel()
end

function Confirm:onShow()
    UIManager:setDirty(self, "ui", self:region())
    settle(self, function() return self:region() end)
    return true
end

function Confirm:onCloseWidget()
    self.closed = true
    self:release()
    UIManager:setDirty(nil, "ui", self:region())
end

function M.newConfirm(opts)
    return Confirm:new{
        title = opts.title, title_tail = opts.title_tail, message = opts.message,
        confirm_text = opts.confirm_text, cancel_text = opts.cancel_text,
        on_confirm = opts.on_confirm, on_cancel = opts.on_cancel,
    }
end

function M.confirm(opts)
    local sheet = M.newConfirm(opts)
    UIManager:show(sheet, "ui", sheet:region())
    return sheet
end

return M

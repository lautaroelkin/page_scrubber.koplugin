--[[
    page_scrubber.koplugin/ps_toast.lua

    Carteles cortos que aparecen y se van solos, copiados del toast.lua de KiKome: una
    píldora de borde negro fino (adentro blanca; un error es negra con texto blanco),
    centrada cerca del borde de abajo. Los toques pasan de largo hacia la pantalla de
    abajo. Varios a la vez se apilan: el más nuevo queda abajo.

      local Toast = require("ps_toast")
      Toast.show("Button added.")
      Toast.show("Saved", { timeout = 4 })
      Toast.error("Could not use that icon.")
      local t = Toast.working("Exporting…"); ...; Toast.dismiss(t)
      Toast.clear()

    Opciones de show / error: timeout (segundos; 3, y 4 los errores), persistent (true: no
    se va hasta Toast.dismiss), kind ("info" o "error"), bottom (píxeles desde el borde de
    abajo hasta el cartel más bajo).
]]--

local Blitbuffer    = require("ffi/blitbuffer")
local Device        = require("device")
local Geom          = require("ui/geometry")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget    = require("ui/widget/textwidget")
local UIManager     = require("ui/uimanager")
local Widget        = require("ui/widget/widget")
local Kit           = require("svg_picker").kit

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local U, face, _ = Kit.U, Kit.face, Kit._

local MAX_VISIBLE = 4   -- más que esto y el más viejo se va enseguida

local entries = {}      -- el más viejo primero: { text, kind, timeout, tb, w, h, expire }
local layer             -- el widget que los dibuja a todos mientras haya alguno

-- ── Medidas ────────────────────────────────────────────────────────────────
local function measure(entry)
    if entry.tb then return end
    local f = face(15)
    local pad_x, pad_y = U(20), U(12)
    local max_text_w = math.floor(Screen:getWidth() * 0.86) - 2 * pad_x
    local natural = 0
    for line in (entry.text .. "\n"):gmatch("(.-)\n") do
        local t = TextWidget:new{ text = line, face = f }
        natural = math.max(natural, t:getSize().w)
        t:free()
    end
    local text_w = math.max(U(40), math.min(natural + U(2), max_text_w))
    -- El TextBox pinta su propio fondo (blanco): sobre la píldora negra de un error
    -- necesita uno negro, o se ve un bloque blanco.
    local is_error = entry.kind == "error"
    entry.tb = TextBoxWidget:new{
        text = entry.text, face = f, width = text_w, alignment = "center",
        fgcolor = is_error and WHITE or BLACK,
        bgcolor = is_error and BLACK or WHITE,
    }
    local sz = entry.tb:getSize()
    entry.w, entry.h = sz.w + 2 * pad_x, sz.h + 2 * pad_y
    entry.pad_x, entry.pad_y = pad_x, pad_y
end

local function release(entry)
    if entry.tb then
        entry.tb:free()
        entry.tb = nil
    end
end

-- Dónde está el borde de abajo de la pila: el cartel más bajo termina acá.
-- Con el scrubber abierto, nunca más abajo que el borde de arriba de su barra inferior (con un
-- pequeño aire): el cartel no la tapa. Sin scrubber, un poco arriba del borde de la pantalla.
local function bottomEdge(opts_bottom)
    local edge = Screen:getHeight() - (opts_bottom or U(72))
    local ok, bar_top = pcall(function() return require("ps_bar").top() end)
    if ok and bar_top then
        edge = math.min(edge, bar_top - U(12))
    end
    return edge
end

local function layout()
    local W = Screen:getWidth()
    local gap = U(8)
    local last = entries[#entries]
    local y = bottomEdge(last and last.bottom)
    local rects = {}
    local top, bottom = nil, nil
    for i = #entries, 1, -1 do
        local e = entries[i]
        measure(e)
        y = y - e.h
        rects[i] = Geom:new{ x = math.floor((W - e.w) / 2), y = y, w = e.w, h = e.h }
        top = y
        bottom = bottom or (y + e.h)
        y = y - gap
    end
    local all
    if top then
        all = Geom:new{ x = 0, y = top - U(4), w = W, h = bottom - top + U(8) }
    end
    return rects, all
end

-- ── El widget que dibuja la pila ───────────────────────────────────────────
local Layer = Widget:extend{
    name = "page_scrubber_toast",
    -- KOReader deja pasar los eventos de un `toast` al widget de abajo.
    toast = true,
}

function Layer:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.rects, self.area = layout()
end

function Layer:getSize() return self.dimen end
function Layer:free() end

function Layer:relayout()
    local old = self.area
    self.rects, self.area = layout()
    if old and self.area then return old:combine(self.area) end
    return old or self.area
end

function Layer:paintTo(bb, x, y)
    for i, e in ipairs(entries) do
        local r = self.rects and self.rects[i]
        if r and e.tb then
            local rx, ry = x + r.x, y + r.y
            local radius = math.min(U(20), math.floor(r.h / 2))
            local border = U(2)
            bb:paintRoundedRect(rx, ry, r.w, r.h, BLACK, radius)
            if e.kind ~= "error" then
                bb:paintRoundedRect(rx + border, ry + border, r.w - 2 * border, r.h - 2 * border,
                    WHITE, math.max(0, radius - border))
            end
            e.tb:paintTo(bb, rx + e.pad_x, ry + e.pad_y)
        end
    end
end

function Layer:onCloseWidget()
    if self.area then UIManager:setDirty(nil, "ui", self.area) end
end

-- ── Público ────────────────────────────────────────────────────────────────
local Toast = {}

local function refresh()
    if #entries == 0 then
        if layer then
            local l = layer
            layer = nil
            UIManager:close(l)
        end
        return
    end
    if not layer then
        layer = Layer:new{}
        UIManager:show(layer, "ui", layer.area)
        return
    end
    local region = layer:relayout()
    if region then UIManager:setDirty(layer, function() return "ui", region end) end
end

local function remove(entry)
    for i, e in ipairs(entries) do
        if e == entry then
            table.remove(entries, i)
            break
        end
    end
    if entry.expire then
        UIManager:unschedule(entry.expire)
        entry.expire = nil
    end
    refresh()
    release(entry)
end

function Toast.show(text, opts)
    opts = opts or {}
    text = tostring(text or "")
    if text == "" then return end
    local kind = opts.kind or "info"
    local timeout = opts.timeout or (kind == "error" and 4 or 3)
    local persistent = opts.persistent

    -- El mismo mensaje ya está: solo se queda un rato más.
    for _i, e in ipairs(entries) do
        if e.text == text and e.kind == kind then
            if e.expire then UIManager:unschedule(e.expire) end
            e.expire = nil
            if not persistent then
                e.expire = function()
                    e.expire = nil
                    remove(e)
                end
                UIManager:scheduleIn(timeout, e.expire)
            end
            return e
        end
    end

    local entry = { text = text, kind = kind, bottom = opts.bottom }
    if not persistent then
        entry.expire = function()
            entry.expire = nil
            remove(entry)
        end
    end
    entries[#entries + 1] = entry
    while #entries > MAX_VISIBLE do remove(entries[1]) end
    if entry.expire then UIManager:scheduleIn(timeout, entry.expire) end
    refresh()
    return entry
end

function Toast.error(text, opts)
    opts = opts or {}
    opts.kind = "error"
    return Toast.show(text, opts)
end

-- Para un trabajo que bloquea: se queda hasta Toast.dismiss(entry) y se pinta ya.
function Toast.working(text, opts)
    opts = opts or {}
    opts.persistent = (opts.timeout == nil)
    local entry = Toast.show(text or _("Working…"), opts)
    UIManager:forceRePaint()
    return entry
end

function Toast.dismiss(entry)
    if entry then remove(entry) end
end

function Toast.clear()
    while #entries > 0 do remove(entries[#entries]) end
end

return Toast

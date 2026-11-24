--[[
    page_scrubber.koplugin/ps_list_picker.lua

    Lista a pantalla completa para elegir, copiada del list_picker.lua de KiKome:
    Cancel a la izquierda, el título en el medio, una píldora negra de acción a la derecha,
    debajo una línea opcional (la ruta) y las filas con la barra de páginas a la derecha.
    Es el mismo selector que usa KiKome para elegir qué corre una acción.

    Los tamaños son los de KiKome (filas 17, línea chica 13, título 18, píldoras 16, todos
    por Screen:scaleBySize) y la fuente es la del sistema, la misma del resto de Page Scrubber.

      require("ps_list_picker").show{
          title        = "Choose a button",
          action_label = "Next",              -- la píldora negra
          subtitle     = "texto" | function(picker) return "texto" end,   -- opcional
          rows         = function(picker)     -- se vuelve a leer con picker:reload()
              return { { text = "Name", sub = "línea gris chica", icon = "package",
                         marker = "tick" | "chevron" | nil, selected = false,
                         locked = false, id = cualquiera } }
          end,
          state        = { picked = nil },    -- tabla libre para quien llama
          can_finish   = function(picker) return true end,
          on_tap       = function(row, picker) end,   -- picker:reload() redibuja las filas
          on_finish    = function(picker) end,        -- la pantalla ya está cerrada
          empty_text   = "Nothing here.",
      }
]]--

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Kit             = require("svg_picker").kit

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local C_FIELD  = Kit.C_FIELD                   -- la píldora apagada, las baldosas de ícono
local C_PLACEHOLDER = Kit.C_PLACEHOLDER
local C_LINE   = Blitbuffer.COLOR_LIGHT_GRAY
local C_LOCKED = Blitbuffer.Color8(0x99)

local U, face, fixed, pill, tail = Kit.U, Kit.face, Kit.fixed, Kit.pill, Kit.tail
local iconWidget, subtitleColor, inside, _ = Kit.iconWidget, Kit.subtitleColor, Kit.inside, Kit._

local Picker = InputContainer:extend{
    name = "page_scrubber_list_picker",
    covers_fullscreen = true,
    dithered = true,
    title = nil, action_label = nil, subtitle = nil, rows = nil,
    can_finish = nil, on_tap = nil, on_finish = nil, empty_text = nil, on_close = nil,
}

function Picker:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.state = self.state or {}
    self.page = 1
    self.items = self.rows(self)
    self:build()
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    if Device:isTouchDevice() then
        self.ges_events = {
            TapPicker = { GestureRange:new{ ges = "tap", range = self.dimen } },
            SwipePicker = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
        Kit.registerBarDrag(self, {
            rect = function() return self.bar_rect end,
            bar  = function() return self.bar end,
            top  = function() return self.bar_rect.y end,
            goTo = function(page) self:goToPage(page) end,
        })
    end
end

-- Lee las filas otra vez y redibuja. La página queda salvo `to_first`.
function Picker:reload(to_first)
    self.items = self.rows(self)
    if to_first then self.page = 1 end
    self:build()
    UIManager:setDirty(self, "ui")
end

function Picker:canFinish()
    if self.can_finish then return self.can_finish(self) and true or false end
    return true
end

local function markerWidget(row, size)
    if row.marker == "tick" then
        return iconWidget(row.selected and "square-dot" or "square", size, row.locked and C_LOCKED or BLACK)
    elseif row.marker == "chevron" then
        return iconWidget("chevron-right", U(18), subtitleColor())
    end
    return HorizontalSpan:new{ width = 0 }
end

-- Una fila: un ícono sobre una baldosa gris, el texto (sobre una línea gris chica) y la
-- marca a la derecha.
function Picker:itemRow(row, row_w, row_h)
    local gap = U(16)
    local tile = math.min(U(44), row_h - U(16))
    local check_w = U(26)
    local text_w = row_w - tile - check_w - 2 * gap
    local fg = row.locked and C_LOCKED or BLACK
    local text = VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = row.text or "", face = face(17), fgcolor = fg, max_width = text_w },
    }
    if row.sub and row.sub ~= "" then
        text[#text + 1] = VerticalSpan:new{ width = U(3) }
        text[#text + 1] = TextWidget:new{
            text = row.sub, face = face(13),
            fgcolor = row.locked and C_LOCKED or subtitleColor(), max_width = text_w,
        }
    end
    local inner = iconWidget(row.icon or "folder", math.floor(tile * 0.5), fg)
    local icon_tile = FrameContainer:new{
        bordersize = 0, padding = 0, radius = U(12), background = C_FIELD,
        fixed(tile, tile, CenterContainer:new{ dimen = Geom:new{ w = tile, h = tile }, inner }),
    }
    local line_h = U(1)
    local body_h = row_h - line_h
    return VerticalGroup:new{
        align = "left",
        fixed(row_w, body_h, HorizontalGroup:new{
            align = "center",
            CenterContainer:new{ dimen = Geom:new{ w = tile, h = body_h }, icon_tile },
            HorizontalSpan:new{ width = gap },
            LeftContainer:new{ dimen = Geom:new{ w = text_w, h = body_h }, text },
            HorizontalSpan:new{ width = gap },
            CenterContainer:new{ dimen = Geom:new{ w = check_w, h = body_h }, markerWidget(row, check_w) },
        }),
        LineWidget:new{ dimen = Geom:new{ w = row_w, h = line_h }, background = C_LINE },
    }
end

function Picker:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local margin = U(30)
    local content_w = W - 2 * margin
    local gap = U(12)

    local body = VerticalGroup:new{ align = "left" }
    local y = U(32)
    body[#body + 1] = VerticalSpan:new{ width = y }

    -- Encabezado: Cancel, el título y la píldora de acción.
    local header_h = U(52)
    local can = self:canFinish()
    local label = self.action_label or _("Add")
    local create, create_w = pill(label, U(40), can and BLACK or C_FIELD, can and WHITE or C_PLACEHOLDER, true)
    local cancel = TextWidget:new{ text = _("Cancel"), face = face(17) }
    local side_w = math.max(create_w, cancel:getSize().w) + U(8)
    local title = TextWidget:new{
        text = self.title or "", face = face(18), bold = true,
        max_width = math.max(U(60), content_w - 2 * side_w - gap),
    }
    body[#body + 1] = fixed(content_w, header_h, HorizontalGroup:new{
        align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = side_w, h = header_h }, cancel },
        CenterContainer:new{ dimen = Geom:new{ w = content_w - 2 * side_w, h = header_h }, title },
        RightContainer:new{ dimen = Geom:new{ w = side_w, h = header_h }, create },
    })
    self.cancel_rect = Geom:new{ x = margin, y = y, w = side_w, h = header_h }
    self.create_rect = Geom:new{ x = margin + content_w - side_w, y = y, w = side_w, h = header_h }
    y = y + header_h
    body[#body + 1] = VerticalSpan:new{ width = U(6) }
    y = y + U(6)

    -- La línea de abajo del encabezado.
    local sub = self.subtitle
    if type(sub) == "function" then sub = sub(self) end
    if sub and sub ~= "" then
        local sub_h = U(28)
        local f = face(14)
        body[#body + 1] = fixed(content_w, sub_h, LeftContainer:new{
            dimen = Geom:new{ w = content_w, h = sub_h },
            TextWidget:new{ text = tail(sub, f, content_w - U(8)), face = f, fgcolor = subtitleColor() },
        })
        y = y + sub_h
    end
    body[#body + 1] = VerticalSpan:new{ width = gap }
    y = y + gap

    -- Las filas: todas las enteras que entran; el espacio que sobra se reparte.
    local list_h = H - U(20) - y
    local bar_w, bar_gap, arrow = U(28), U(10), U(24)
    local row_w = content_w - bar_w - bar_gap
    local base_h = math.floor(W * 0.14)
    local per_page = math.max(1, math.floor(list_h / base_h))
    local row_h = math.floor(list_h / per_page)
    if row_h > math.floor(base_h * 1.4) then row_h = base_h end
    self.per_page = per_page
    self.pages = math.max(1, math.ceil(#self.items / per_page))
    self.page = math.max(1, math.min(self.page, self.pages))
    local first = (self.page - 1) * per_page
    self.y_list, self.list_end = y, y + list_h
    self.row_hits = {}

    local rows = VerticalGroup:new{ align = "left" }
    local used = 0
    if #self.items == 0 then
        rows[#rows + 1] = CenterContainer:new{
            dimen = Geom:new{ w = row_w, h = list_h },
            TextWidget:new{
                text = self.empty_text or _("Nothing here."), face = face(15),
                fgcolor = subtitleColor(), max_width = row_w,
            },
        }
        used = list_h
    end
    for i = 1, per_page do
        local row = self.items[first + i]
        if not row then break end
        rows[#rows + 1] = self:itemRow(row, row_w, row_h)
        self.row_hits[#self.row_hits + 1] = {
            rect = Geom:new{ x = margin, y = y + used, w = row_w, h = row_h }, row = row,
        }
        used = used + row_h
    end
    rows[#rows + 1] = VerticalSpan:new{ width = math.max(0, list_h - used) }

    self.bar = { w = bar_w, h = list_h, page = self.page, pages = self.pages, arrow = arrow }
    local bar_x = margin + row_w + math.floor(bar_gap / 2)
    self.bar_rect = Geom:new{ x = bar_x, y = y, w = W - bar_x, h = list_h }
    body[#body + 1] = HorizontalGroup:new{
        align = "top",
        rows,
        HorizontalSpan:new{ width = bar_gap },
        Kit.pageBar(self.bar),
    }

    local layers = OverlapGroup:new{
        dimen = Geom:new{ w = W, h = H },
        FrameContainer:new{ bordersize = 0, padding = 0, padding_left = margin, body },
    }
    self[1] = FrameContainer:new{
        width = W, height = H, bordersize = 0, padding = 0,
        background = WHITE,
        layers,
    }
end

-- La pantalla se cierra: no se dibuja nada más.
function Picker:markClosed()
    if self.closed then return end
    self.closed = true
    if self.on_close then pcall(self.on_close, self) end
end

function Picker:dismiss()
    self:markClosed()
    UIManager:close(self, "ui")
    return true
end

function Picker:finish()
    if not self:canFinish() then return end
    self:markClosed()
    UIManager:close(self, "ui")
    if self.on_finish then self.on_finish(self) end
end

function Picker:goToPage(page)
    page = math.max(1, math.min(self.pages, page))
    if page == self.page then return end
    self.page = page
    self:build()
    local region = Geom:new{ x = 0, y = self.y_list, w = Screen:getWidth(), h = self.list_end - self.y_list }
    UIManager:setDirty(self, function() return "ui", region end)
end

function Picker:onTapPicker(_ev, ges)
    local pos = ges.pos
    if inside(self.cancel_rect, pos) then return self:dismiss() end
    if inside(self.create_rect, pos) then
        self:finish()
        return true
    end
    if inside(self.bar_rect, pos) then
        local page = Kit.pageBarTarget(pos.y - self.y_list, self.bar)
        if page then self:goToPage(page) end
        return true
    end
    for _i, hit in ipairs(self.row_hits or {}) do
        if inside(hit.rect, pos) then
            if not hit.row.locked and self.on_tap then self.on_tap(hit.row, self) end
            return true
        end
    end
    return true
end

-- Deslizar arriba: la página siguiente; abajo: la anterior.
function Picker:onSwipePicker(_ev, ges)
    if ges.pos.y < (self.y_list or 0) then return true end
    if ges.direction == "north" then
        self:goToPage(self.page + 1)
    elseif ges.direction == "south" then
        self:goToPage(self.page - 1)
    end
    return true
end

function Picker:onClose()
    return self:dismiss()
end

local ListPicker = {}

function ListPicker.show(opts)
    local picker = Picker:new(opts)
    UIManager:show(picker, "ui")
    return picker
end

return ListPicker

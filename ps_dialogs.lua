--[[
    page_scrubber.koplugin/ps_dialogs.lua

    Reemplazos de InfoMessage, Notification y ConfirmBox de KOReader con el mismo uso
    (`X:new{ ... }` y UIManager:show / UIManager:close), pero dibujados con los carteles de
    KiKome: así el plugin no muestra ningún cartel de KOReader y cada archivo solo cambia
    el require de arriba.

      local InfoMessage = require("ps_dialogs").InfoMessage
      local ConfirmBox  = require("ps_dialogs").ConfirmBox
      local Notification = require("ps_dialogs").Notification

    - InfoMessage / Notification: un cartel (ps_toast.lua) que se va solo. Acepta text y
      timeout (segundos; sin timeout, según el largo del texto) y dismiss_callback. Cerrarlo
      con UIManager:close() lo saca de inmediato, como el InfoMessage de KOReader.
    - ConfirmBox: con ok_callback o cancel_callback es una pregunta (la hoja de
      ps_sheet.lua, con ok_text y cancel_text). Sin ninguno de los dos solo avisa (como el
      "OK" suelto de KOReader) y se muestra como cartel.
]]--

local Geom      = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Widget    = require("ui/widget/widget")

-- Si por lo que sea los carteles propios no cargan, el plugin sigue andando con los de KOReader
local ok_load, Toast, Sheet, _ = pcall(function()
    return require("ps_toast"), require("ps_sheet"), require("svg_picker").kit._
end)
if not ok_load then
    pcall(function() require("logger").warn("PageScrubber: ps_dialogs falls back to KOReader widgets:", tostring(Toast)) end)
    return {
        InfoMessage  = require("ui/widget/infomessage"),
        ConfirmBox   = require("ui/widget/confirmbox"),
        Notification = require("ui/widget/notification"),
    }
end

local M = {}

-- ── Cartel (InfoMessage / Notification) ────────────────────────────────────
-- Un widget sin tamaño: no tapa ni frena nada; lo que se ve es el cartel de ps_toast.
local Info = Widget:extend{
    name = "page_scrubber_info",
    toast = true,           -- los toques pasan de largo, como con un cartel
    text = "",
    timeout = nil,
}

function Info:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = 0, h = 0 }
end

function Info:getSize() return self.dimen end
function Info:paintTo() end
function Info:free() end

local function defaultTimeout(text)
    local n = #tostring(text or "")
    return math.min(7, 3 + math.floor(n / 45))
end

function Info:onShow()
    local timeout = tonumber(self.timeout) or defaultTimeout(self.text)
    self.entry = Toast.show(self.text, { timeout = timeout })
    return false
end

function Info:onCloseWidget()
    if self.entry then
        Toast.dismiss(self.entry)
        self.entry = nil
    end
    if self.dismiss_callback then
        local cb = self.dismiss_callback
        self.dismiss_callback = nil
        pcall(cb)
    end
end

M.InfoMessage = Info
M.Notification = Info

-- ── Pregunta (ConfirmBox) ──────────────────────────────────────────────────
local Confirm = {}

function Confirm:new(o)
    o = o or {}
    local asks = o.ok_callback ~= nil or o.cancel_callback ~= nil or o.other_buttons ~= nil
    if not asks then
        -- solo un aviso con "OK": un cartel
        return Info:new{ text = o.text, timeout = o.timeout }
    end
    return Sheet.newConfirm{
        title = o.title,
        message = o.text,
        confirm_text = o.ok_text or _("OK"),
        cancel_text = o.cancel_text or _("Cancel"),
        on_confirm = o.ok_callback,
        on_cancel = o.cancel_callback,
    }
end

M.ConfirmBox = Confirm

return M

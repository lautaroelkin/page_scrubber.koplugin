--[[
    page_scrubber.koplugin/ps_bar.lua

    Dónde está la barra inferior del scrubber (capítulo, página y slider), para que las hojas y
    los carteles de ps_sheet.lua y ps_toast.lua se acomoden respecto a ella.

      local Bar = require("ps_bar")
      Bar.top()   --> la y del borde de arriba de la barra, o nil si el scrubber no está abierto

    El PageScrubber se anota en init y se saca en onCloseWidget; la medida se lee cada vez de su
    _bar_dimen, así que sigue a la barra si cambia (girar la pantalla, cambiar de vista).
]]--

local M = { instance = nil }

function M.register(widget)
    M.instance = widget
end

function M.unregister(widget)
    if M.instance == widget then M.instance = nil end
end

function M.top()
    local w = M.instance
    if not w or w._closing then return nil end
    local d = w._bar_dimen
    if d and type(d.y) == "number" and type(d.h) == "number" and d.h > 0 then
        return d.y
    end
    return nil
end

return M

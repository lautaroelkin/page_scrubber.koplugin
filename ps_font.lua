--[[
    page_scrubber.koplugin/ps_font.lua

    Un reemplazo de require("ui/font") para los archivos de Page Scrubber: igual que el Font de
    KOReader, salvo que `Font:getFace(nombre, tamaño)` respeta la opción "Automatic" de
    Settings > Text size.

    Por qué hace falta: el plugin pide sus fuentes como Font:getFace("cfont", scaleText(11)), y
    scaleText ya multiplica por la densidad de la pantalla; después Font:getFace la multiplica de
    nuevo. El texto queda escalado dos veces y se ve bastante más grande que el de KiKome, que
    pide Font:getFace("cfont", 17) y se escala una sola vez.

    - Small / Medium / Large: no cambia nada, el tamaño pasa tal cual (como siempre).
    - Automatic: se deshace el primer escalado y se pasa al tamaño equivalente de KiKome, de modo
      que Font:getFace lo escale una sola vez. El tamaño base 12 del plugin (el de las filas)
      equivale al 17 de las filas de KiKome, y de ahí el resto: 9→13, 10→14, 11→16, 13→18 …
      (la misma escala 17/12 para todo, así lo grande sigue siendo grande y lo chico, chico).

    Todo lo demás de Font (sizemap, fontmap, …) se consulta en el Font real.
]]--

local Device = require("device")
local RealFont = require("ui/font")

local Screen = Device.screen

-- El 12 del plugin (filas) ↔ el 17 de KiKome (filas)
local KIKOME_RATIO = 17 / 12
local MIN_SIZE = 8

local function isAutomatic()
    return G_reader_settings ~= nil
        and G_reader_settings:readSetting("page_scrubber_text_size") == "automatic"
end

local PSFont = {}

-- Cuánto multiplica Screen:scaleBySize (sin el redondeo a entero de un solo píxel)
local function densityScale()
    local ok, s = pcall(function() return Screen:scaleBySize(100) / 100 end)
    if ok and type(s) == "number" and s > 0 then return s end
    return 1
end

function PSFont.getFace(_self, name, size, ...)
    if type(size) == "number" and isAutomatic() then
        size = math.max(MIN_SIZE, math.floor(size / densityScale() * KIKOME_RATIO + 0.5))
    end
    return RealFont:getFace(name, size, ...)
end

-- Todo lo que no es getFace sale del Font de KOReader
return setmetatable(PSFont, {
    __index = function(_t, key) return RealFont[key] end,
    __newindex = function(_t, key, value) RealFont[key] = value end,
})

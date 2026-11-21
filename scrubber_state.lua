--[[
    page_scrubber.koplugin/scrubber_state.lua

    Estado compartido entre módulos del plugin.

    rotating: es true mientras se rota la pantalla desde el menú rápido (y un rato después). Durante ese lapso el plugin
    no abre ningún scrubber / menú nuevo: así un gesto que llegue justo después de cerrarse el menú no puede lanzar
    uno con las medidas de la orientación anterior.

    active / launching_at: una sola instancia del scrubber a la vez. Si el hilo principal está ocupado (por ejemplo
    justo después de abrir un libro) el gesto de lanzamiento se repite y todos los eventos se procesan juntos: sin
    guarda se apilaban 2 a 5 scrubbers, cada uno con su propia página de origen, y al saltar desde el de arriba
    aparecía otro idéntico cuyo centro devolvía el libro a esa página de origen.

    swipe_*: las animaciones de swipe se apagan mientras hay scrubber; el valor original se guarda una sola vez y
    se restaura cuando se cierra la última instancia (antes cada instancia guardaba "el valor actual", que con
    varias instancias ya era el valor apagado, y las animaciones podían quedar apagadas para siempre).
]]--

local S = {
    rotating     = false,
    active       = nil,    -- instancia visible del scrubber (o nil)
    launching_at = nil,    -- os.time() de un lanzamiento que todavía no llegó a mostrarse
    swipe_users  = 0,
    swipe_saved  = nil,
    log          = function() end,   -- lo reemplaza scrubber_ui (archivo de diagnóstico)
}

-- Instancia del scrubber que sigue en pantalla, o nil.
function S.openInstance()
    local w = S.active
    if not w or w._closing then return nil end
    local ok, shown = pcall(function() return require("ui/uimanager"):isWidgetShown(w) end)
    if ok and shown then return w end
    S.active = nil   -- ya no está en pantalla: estado viejo
    return nil
end

-- true si ya hay un scrubber abierto o uno en camino (con un tope de 5 s por seguridad).
function S.isBusy()
    if S.openInstance() then return true end
    local t = S.launching_at
    if t and (os.time() - t) < 5 then return true end
    S.launching_at = nil
    return false
end

function S.beginLaunch() S.launching_at = os.time() end
function S.endLaunch() S.launching_at = nil end

-- Apaga las animaciones de swipe mientras haya al menos una instancia.
function S.pushNoSwipe(Device, Screen)
    if S.swipe_users == 0 then
        S.swipe_saved = {
            can_do = Device.canDoSwipeAnimation,
            anim   = Screen.swipe_animations,
        }
        Device.canDoSwipeAnimation = function() return false end
        Screen.swipe_animations = false
    end
    S.swipe_users = S.swipe_users + 1
end

-- Restaura las animaciones cuando se cierra la última instancia.
function S.popNoSwipe(Device, Screen)
    if S.swipe_users <= 0 then return end
    S.swipe_users = S.swipe_users - 1
    if S.swipe_users == 0 and S.swipe_saved then
        if S.swipe_saved.can_do then Device.canDoSwipeAnimation = S.swipe_saved.can_do end
        if S.swipe_saved.anim ~= nil then Screen.swipe_animations = S.swipe_saved.anim end
        S.swipe_saved = nil
    end
end

return S

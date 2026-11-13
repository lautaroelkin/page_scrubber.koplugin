--[[
    page_scrubber.koplugin/scrubber_state.lua

    Estado compartido entre módulos del plugin.

    rotating: es true mientras se rota la pantalla desde el menú rápido (y un rato después). Durante ese lapso el plugin
    no abre ningún scrubber / menú nuevo: así un gesto que llegue justo después de cerrarse el menú no puede lanzar
    uno con las medidas de la orientación anterior.
]]--

return {
    rotating = false,
}

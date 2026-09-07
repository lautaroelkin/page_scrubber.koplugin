--[[
    page_scrubber.koplugin/page_scrubber_bridge.lua

    Puente de comunicación entre instancias de ReaderUI a través de un
    reloadDocument(). Usa el caché de módulos de Lua (require() siempre
    devuelve la misma tabla) como canal que sobrevive al reload -- el
    proceso de Lua no reinicia, solo se recrea la instancia de ReaderUI.
]]--

local Bridge = {}

local pending_reopen = nil
local loading_widget = nil

function Bridge.requestReopenAfterReload(state_table)
    pending_reopen = state_table
end

function Bridge.setLoadingWidget(widget)
    loading_widget = widget
end

function Bridge.closeLoadingWidget()
    if loading_widget then
        local UIManager = require("ui/uimanager")
        pcall(function() UIManager:close(loading_widget) end)
        loading_widget = nil
    end
end

function Bridge.consumePendingReopen()
    local req = pending_reopen
    pending_reopen = nil
    return req
end

return Bridge

--[[
    page_scrubber.koplugin/main.lua
]]--

local Dispatcher      = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ReaderUI        = require("apps/reader/readerui")
local UIManager       = require("ui/uimanager")
local Device          = require("device")
local ScrubberState   = require("scrubber_state")

local _ = require("ps_i18n").gettext   -- cargador único de traducciones (ver ps_i18n.lua)

local PageScrubberPlugin = WidgetContainer:extend{
    name        = "page_scrubber",
    description = "Advanced page scrubber",
    is_doc_only = true,
}

local SCALE_KEY = "page_scrubber_ui_scale"

local function getScale() 
    if G_reader_settings then
        local val = G_reader_settings:readSetting(SCALE_KEY)
        if type(val) == "number" then return val end
    end
    return 1.0 
end

-- KOReader le pone el prefijo "NEW:" a cualquier ítem de menú que no figure en su lista de orden
-- (reader_menu_order). Se registra el ítem ahí para que el submenú aparezca normal, sin el prefijo.
local MENU_ITEM_ID = "page_scrubber"

local function registerInMenuOrder()
    local ok, order = pcall(require, "ui/elements/reader_menu_order")
    if not ok or type(order) ~= "table" then return end
    -- El ítem puede quedar en "navi" o dentro de "document" según el menú; si en una de las
    -- listas no existe, KOReader simplemente ignora el id.
    for _i, section in ipairs({ "navi", "document" }) do
        local list = order[section]
        if type(list) == "table" then
            local found = false
            for _j, id in ipairs(list) do
                if id == MENU_ITEM_ID then found = true; break end
            end
            if not found then table.insert(list, MENU_ITEM_ID) end
        end
    end
end

-- "Swipe up to": al deslizar hacia arriba desde el borde de abajo, KOReader abre su menú de tipografía
-- (ReaderConfig:onSwipeShowConfigMenu). Si el usuario eligió una vista del scrubber en
-- Settings > Reading Pop-Ups > Swipe up to, se abre esa en su lugar. Con "Off" (por defecto) no cambia nada.
local SWIPE_UP_EVENTS = {
    grid          = "PageScrubberGrid",
    grid_simple   = "PageScrubberSimpleGrid",
    toc           = "PageScrubberToc",
    toc_expanded  = "PageScrubberTocExpanded",
    grid_six      = "PageScrubberMultiGrid",
    quick_menu    = "PageScrubberQuickMenu",
}

local swipe_up_patched = false

local function patchSwipeUp()
    if swipe_up_patched then return end
    local ok, ReaderConfig = pcall(require, "apps/reader/modules/readerconfig")
    if not (ok and type(ReaderConfig) == "table") then return end
    local orig = ReaderConfig.onSwipeShowConfigMenu
    if type(orig) ~= "function" then return end
    swipe_up_patched = true

    ReaderConfig.onSwipeShowConfigMenu = function(self_rc, ges, ...)
        if ges and ges.direction == "north" and G_reader_settings then
            local choice = G_reader_settings:readSetting("page_scrubber_swipe_up")
            local event = choice and SWIPE_UP_EVENTS[choice]
            local ui = self_rc.ui
            if event and ui and ui.document and not ScrubberState.rotating then
                local Event = require("ui/event")
                ui:handleEvent(Event:new(event))
                ui:handleEvent(Event:new("HandledAsSwipe"))
                return true
            end
        end
        return orig(self_rc, ges, ...)
    end
end

function PageScrubberPlugin:init()
    registerInMenuOrder()
    patchSwipeUp()
    Dispatcher:registerAction("page_scrubber_grid_action", { category = "none", event = "PageScrubberGrid", title = _("Page Scrubber: Grid"), reader = true })
    Dispatcher:registerAction("page_scrubber_simple_grid_action", { category = "none", event = "PageScrubberSimpleGrid", title = _("Page Scrubber: Simple Grid"), reader = true })
    Dispatcher:registerAction("page_scrubber_multi_grid_action", { category = "none", event = "PageScrubberMultiGrid", title = _("Page Scrubber: Multi-Grid"), reader = true })
    Dispatcher:registerAction("page_scrubber_menu_bm_action", { category = "none", event = "PageScrubberMenuBM", title = _("Page Scrubber: Menu (Bookmarks)"), reader = true })
    Dispatcher:registerAction("page_scrubber_menu_hl_action", { category = "none", event = "PageScrubberMenuHL", title = _("Page Scrubber: Menu (Highlights)"), reader = true })
    Dispatcher:registerAction("page_scrubber_toc_action", { category = "none", event = "PageScrubberToc", title = _("Page Scrubber: Index"), reader = true })
    Dispatcher:registerAction("page_scrubber_toc_expanded_action", { category = "none", event = "PageScrubberTocExpanded", title = _("Page Scrubber: Index (Table of Content)"), reader = true })
    Dispatcher:registerAction("page_scrubber_toggle_rtl_action", { category = "none", event = "PageScrubberToggleRTL", title = _("Page Scrubber: Toggle RTL"), reader = true })
    Dispatcher:registerAction("page_scrubber_study_action", { category = "none", event = "PageScrubberStudy", title = _("Page Scrubber: Study"), reader = true })
    Dispatcher:registerAction("page_scrubber_quick_menu_action", { category = "none", event = "PageScrubberQuickMenu", title = _("Page Scrubber: Quick Menu"), reader = true, separator = true })

    if self.ui.menu then self.ui.menu:registerToMainMenu(self) end

    -- Integración del Diccionario Flotante
    local ok_fdict, FloatingDict = pcall(require, "floating_dict")
    if ok_fdict and FloatingDict and type(FloatingDict.init) == "function" then
        pcall(function() FloatingDict:init(self.ui) end)
    end

    -- Bridge eliminado: las recargas destructivas de documento ya no son necesarias
end

function ReaderUI:onPageScrubberLaunch(mode, tab, page)
    local ui = self
    if not ui.document then return end
    -- Rotando la pantalla: no se abre nada con las medidas de la orientación anterior
    if ScrubberState.rotating then return true end

    -- Un solo scrubber a la vez. Si el hilo principal está ocupado (por ejemplo al abrir un libro) el gesto se repite y
    -- los eventos llegan juntos: sin esta guarda se apilaban varios scrubbers y el de abajo devolvía el libro a la
    -- página de origen.
    if ScrubberState.isBusy() then
        ScrubberState.log("lanzamiento ignorado: ya hay un scrubber abierto o en camino")
        return true
    end
    ScrubberState.beginLaunch()

    local target_mode = mode or "grid"
    local target_tab = tab or "bookmarks"
    local is_transparent = (target_mode == "grid_simple")

    UIManager:nextTick(function()
        ScrubberState.endLaunch()
        if not ui or not ui.document then return end
        if ScrubberState.rotating then return end
        if ScrubberState.openInstance() then return end
        local ScrubberUI = require("scrubber_ui")
        UIManager:show(ScrubberUI:new{
            ui                = ui,
            document          = ui.document,
            initial_view_mode = target_mode,
            initial_tab       = target_tab,
            initial_page      = page,
            transparent_bg    = is_transparent,
            ui_scale          = getScale(),
        })
        if Device:isKindle() then UIManager:setDirty(nil, "full") end
    end)
end

function ReaderUI:onPageScrubberGrid() self:onPageScrubberLaunch("grid") end
function ReaderUI:onPageScrubberSimpleGrid() self:onPageScrubberLaunch("grid_simple") end
function ReaderUI:onPageScrubberMultiGrid() self:onPageScrubberLaunch("grid_six") end
function ReaderUI:onPageScrubberMenuBM() self:onPageScrubberLaunch("split", "bookmarks") end
function ReaderUI:onPageScrubberMenuHL() self:onPageScrubberLaunch("split", "highlights") end

function ReaderUI:onPageScrubberToc()
    if ScrubberState.rotating then return true end
    local ui = self
    if not ui.document then return end
    UIManager:nextTick(function()
        local ScrubberToc = require("scrubber_toc")
        local cur_page = (ui.view and ui.view.state and ui.view.state.page) or 1
        UIManager:show(ScrubberToc:new{
            ui = ui,
            initial_page = cur_page,
            initial_origin = cur_page,
        })
        if Device:isKindle() then UIManager:setDirty(nil, "full") end
    end)
end

function ReaderUI:onPageScrubberTocExpanded()
    if ScrubberState.rotating then return true end
    local ui = self
    if not ui.document then return end
    UIManager:nextTick(function()
        local ScrubberToc = require("scrubber_toc")
        local cur_page = (ui.view and ui.view.state and ui.view.state.page) or 1
        UIManager:show(ScrubberToc:new{
            ui = ui,
            initial_page = cur_page,
            initial_origin = cur_page,
            initial_expanded = true,
        })
        if Device:isKindle() then UIManager:setDirty(nil, "full") end
    end)
end

function ReaderUI:onPageScrubberToggleRTL()
    local ui = self
    if not ui.document or not ui.doc_settings then return true end

    local doc_val = ui.doc_settings:readSetting("page_scrubber_rtl")
    local is_rtl = false
    if doc_val ~= nil then
        is_rtl = (doc_val == true)
    else
        if ui.doc_settings:readSetting("inverse_reading_order") == true then
            is_rtl = true
        else
            local dir = tostring(ui.doc_settings:readSetting("reading_direction") or ""):upper()
            is_rtl = (dir == "R2L" or dir == "RTL")
        end
    end

    local new_val = not is_rtl
    ui.doc_settings:saveSetting("page_scrubber_rtl", new_val)
    if ui.doc_settings.flush then
        pcall(function() ui.doc_settings:flush() end)
    end

    local InfoMessage = require("ps_dialogs").InfoMessage
    local msg = new_val and _("Page Scrubber: RTL (ON)") or _("Page Scrubber: RTL (OFF)")
    UIManager:show(InfoMessage:new{
        text = msg,
        timeout = 1.5,
    })
    return true
end

-- Abre el split y, apenas termina de construirse, el Review Card (ver initial_open_review en scrubber_ui.lua).
-- Respeta el modo estudio (Off / Everywhere / Only in a folder): si no está activo para este libro, solo avisa.
function ReaderUI:onPageScrubberStudy()
    if ScrubberState.rotating then return true end
    local ui = self
    if not ui.document then return end

    if not require("srs").isStudyActive(ui) then
        local InfoMessage = require("ps_dialogs").InfoMessage
        UIManager:show(InfoMessage:new{ text = _("Study mode is off for this book."), timeout = 2 })
        return true
    end

    if ScrubberState.isBusy() then
        ScrubberState.log("lanzamiento (study) ignorado: ya hay un scrubber abierto o en camino")
        return true
    end
    ScrubberState.beginLaunch()

    UIManager:nextTick(function()
        ScrubberState.endLaunch()
        if not ui or not ui.document then return end
        if ScrubberState.openInstance() then return end
        local ScrubberUI = require("scrubber_ui")
        UIManager:show(ScrubberUI:new{
            ui                  = ui,
            document            = ui.document,
            initial_view_mode   = "split",
            initial_tab         = "bookmarks",
            ui_scale            = getScale(),
            initial_open_review = true,
        })
        if Device:isKindle() then UIManager:setDirty(nil, "full") end
    end)
    return true
end

function ReaderUI:onPageScrubberQuickMenu()
    if ScrubberState.rotating then return true end
    local ui = self
    if not ui.document then return end
    UIManager:nextTick(function()
        local ScrubberMenu = require("scrubber_menu")
        UIManager:show(ScrubberMenu:new{
            ui = ui,
        })
        if Device:isKindle() then UIManager:setDirty(nil, "full") end
    end)
end

function PageScrubberPlugin:addToMainMenu(menu_items)
    local my_menu = { 
        text = "Page Scrubber", 
        sub_item_table = {
            {
                text = "⚙ " .. _("Configuration"),
                keep_menu_open = false,
                callback = function()
                    local ScrubberSettings = require("scrubber_settings")
                    UIManager:show(ScrubberSettings:new{
                        ui = self.ui,
                    })
                end,
                separator = true,
            },
            { text = _("Page Scrubber: Grid"), callback = function() self.ui:onPageScrubberGrid() end },
            { text = _("Page Scrubber: Simple Grid"), callback = function() self.ui:onPageScrubberSimpleGrid() end },
            { text = _("Page Scrubber: Multi-Grid"), callback = function() self.ui:onPageScrubberMultiGrid() end },
            { text = _("Page Scrubber: Menu (Bookmarks)"), callback = function() self.ui:onPageScrubberMenuBM() end },
            { text = _("Page Scrubber: Menu (Highlights)"), callback = function() self.ui:onPageScrubberMenuHL() end },
            { text = _("Page Scrubber: Index"), callback = function() self.ui:onPageScrubberToc() end },
            { text = _("Page Scrubber: Index (Table of Content)"), callback = function() self.ui:onPageScrubberTocExpanded() end },
        }
    }
    
    if menu_items.document and menu_items.document.sub_item_table then
        menu_items.document.sub_item_table.page_scrubber = my_menu
    else
        menu_items.page_scrubber = my_menu
    end
end

return PageScrubberPlugin

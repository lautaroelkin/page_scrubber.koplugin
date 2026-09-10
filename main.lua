--[[
    page_scrubber.koplugin/main.lua
]]--

local Dispatcher      = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ReaderUI        = require("apps/reader/readerui")
local UIManager       = require("ui/uimanager")
local Device          = require("device")

-- Lector de .po en vivo
local _dict = {}
local _lang = "en"
if G_reader_settings then
    local l = G_reader_settings:readSetting("language")
    if type(l) == "string" then _lang = l:sub(1, 2) end
end

if _lang ~= "en" then
    local plugin_path = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
    local po_path = plugin_path .. "locales/" .. _lang .. ".po"
    local f = io.open(po_path, "r")
    if f then
        local current_id
        for line in f:lines() do
            local id = line:match('^msgid%s+"(.*)"')
            if id then current_id = id end
            local str = line:match('^msgstr%s+"(.*)"')
            if str and current_id then
                _dict[current_id] = str
                current_id = nil
            end
        end
        f:close()
    end
end

local function _(text)
    return _dict[text] or text
end

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

function PageScrubberPlugin:init()
    Dispatcher:registerAction("page_scrubber_grid_action", { category = "none", event = "PageScrubberGrid", title = _("Page Scrubber: Grid"), reader = true })
    Dispatcher:registerAction("page_scrubber_simple_grid_action", { category = "none", event = "PageScrubberSimpleGrid", title = _("Page Scrubber: Simple Grid"), reader = true })
    Dispatcher:registerAction("page_scrubber_multi_grid_action", { category = "none", event = "PageScrubberMultiGrid", title = _("Page Scrubber: Multi-Grid"), reader = true })
    Dispatcher:registerAction("page_scrubber_menu_bm_action", { category = "none", event = "PageScrubberMenuBM", title = _("Page Scrubber: Menu (Bookmarks)"), reader = true })
    Dispatcher:registerAction("page_scrubber_menu_hl_action", { category = "none", event = "PageScrubberMenuHL", title = _("Page Scrubber: Menu (Highlights)"), reader = true })
    Dispatcher:registerAction("page_scrubber_toc_action", { category = "none", event = "PageScrubberToc", title = _("Page Scrubber: Index"), reader = true })

    if self.ui.menu then self.ui.menu:registerToMainMenu(self) end

    -- Integración del Diccionario Flotante
    local ok_fdict, FloatingDict = pcall(require, "floating_dict")
    if ok_fdict and FloatingDict and type(FloatingDict.init) == "function" then
        pcall(function() FloatingDict:init(self.ui) end)
    end

    local ok, Bridge = pcall(require, "page_scrubber_bridge")
    if ok and Bridge then
        local req = Bridge.consumePendingReopen()
        if req then
            local ui = self.ui
            UIManager:nextTick(function()
                pcall(function() Bridge.closeLoadingWidget() end)
                if ui and ui.document then
                    local ScrubberUI = require("scrubber_ui")
                    UIManager:show(ScrubberUI:new{
                        ui                 = ui,
                        document           = ui.document,
                        initial_view_mode  = req.mode or "split",
                        initial_tab        = req.tab or "highlights",
                        initial_page       = req.page,
                        initial_origin     = req.origin,
                        initial_fixed_page = req.fixed_page,
                        base_mode          = req.base_mode,
                        initial_sort_order = req.sort_order,
                        initial_bm_page    = req.bm_page,
                        initial_hl_filter  = req.hl_filter,
                        transparent_bg     = (req.mode == "grid_simple"),
                        ui_scale           = getScale(),
                    })
                    if Device:isKindle() then UIManager:setDirty(nil, "full") end
                end
            end)
        end
    end
end

function ReaderUI:onPageScrubberLaunch(mode, tab, page)
    local ui = self
    if not ui.document then return end

    local target_mode = mode or "grid"
    local target_tab = tab or "bookmarks"
    local is_transparent = (target_mode == "grid_simple")

    UIManager:nextTick(function()
        if not ui or not ui.document then return end
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

function PageScrubberPlugin:addToMainMenu(menu_items)
    local my_menu = { 
        text = "Page Scrubber", 
        sub_item_table = {
            {
                text = _("Configuration"),
                keep_menu_open = false,
                callback = function()
                    local ScrubberSettings = require("scrubber_settings")
                    UIManager:show(ScrubberSettings:new{
                        ui = self.ui,
                    })
                end,
            },
            { text = _("Page Scrubber: Grid"), callback = function() self.ui:onPageScrubberGrid() end },
            { text = _("Page Scrubber: Simple Grid"), callback = function() self.ui:onPageScrubberSimpleGrid() end },
            { text = _("Page Scrubber: Multi-Grid"), callback = function() self.ui:onPageScrubberMultiGrid() end },
            { text = _("Page Scrubber: Menu (Bookmarks)"), callback = function() self.ui:onPageScrubberMenuBM() end },
            { text = _("Page Scrubber: Menu (Highlights)"), callback = function() self.ui:onPageScrubberMenuHL() end },
            { text = _("Page Scrubber: Index"), callback = function() self.ui:onPageScrubberToc() end }
        }
    }
    
    if menu_items.document and menu_items.document.sub_item_table then
        menu_items.document.sub_item_table.page_scrubber = my_menu
    else
        menu_items.page_scrubber = my_menu
    end
end

return PageScrubberPlugin

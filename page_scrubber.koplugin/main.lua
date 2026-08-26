--[[
    page_scrubber.koplugin/main.lua
]]--

local Dispatcher      = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ReaderUI        = require("apps/reader/readerui")
local UIManager       = require("ui/uimanager")
local Device          = require("device")
local SpinWidget      = require("ui/widget/spinwidget")

local PageScrubberPlugin = WidgetContainer:extend{
    name        = "page_scrubber",
    description = "Advanced page scrubber",
    is_doc_only = true,
}

local SCALE_KEY = "page_scrubber_ui_scale"

local function getScale() return (G_reader_settings and G_reader_settings:readSetting(SCALE_KEY)) or 1.0 end
local function setScale(val)
    if G_reader_settings then
        G_reader_settings:saveSetting(SCALE_KEY, val)
        G_reader_settings:flush()
    end
end

function PageScrubberPlugin:init()
    Dispatcher:registerAction("page_scrubber_grid_action", { category = "none", event = "PageScrubberGrid", title = "Page Scrubber: Grid", reader = true })
    Dispatcher:registerAction("page_scrubber_simple_grid_action", { category = "none", event = "PageScrubberSimpleGrid", title = "Page Scrubber: Simple Grid", reader = true })
    Dispatcher:registerAction("page_scrubber_multi_grid_action", { category = "none", event = "PageScrubberMultiGrid", title = "Page Scrubber: Multi-Grid", reader = true })
    Dispatcher:registerAction("page_scrubber_menu_bm_action", { category = "none", event = "PageScrubberMenuBM", title = "Page Scrubber: Menu (Bookmarks)", reader = true })
    Dispatcher:registerAction("page_scrubber_menu_hl_action", { category = "none", event = "PageScrubberMenuHL", title = "Page Scrubber: Menu (Highlights)", reader = true })

    if self.ui.menu then self.ui.menu:registerToMainMenu(self) end

    -- Carga segura (pcall) para restaurar estado tras un reloadDocument()
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

function PageScrubberPlugin:addToMainMenu(menu_items)
    local my_menu = { 
        text = "Page Scrubber", 
        sub_item_table = {
            {
                text = "Configuration",
                sub_item_table = {
                    {
                        text_func = function() return "UI Scale: " .. math.floor(getScale() * 100) .. "%" end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            local spin = SpinWidget:new{
                                title_text = "UI Scale (%)", 
                                value = math.floor(getScale() * 100),
                                value_min = 50, value_max = 200, 
                                value_step = 5, value_hold_step = 5,
                                ok_text = "Save",
                                callback = function(spin_widget) 
                                    setScale(spin_widget.value / 100)
                                    if touchmenu_instance then touchmenu_instance:updateItems() end 
                                end,
                            }
                            UIManager:show(spin)
                        end,
                    },
                    {
                        text = "3-Page Grid: Show full pages",
                        checked_func = function()
                            return G_reader_settings and G_reader_settings:readSetting("page_scrubber_full_page_grid") == true
                        end,
                        callback = function()
                            local is_set = false
                            if G_reader_settings then
                                is_set = G_reader_settings:readSetting("page_scrubber_full_page_grid")
                                G_reader_settings:saveSetting("page_scrubber_full_page_grid", not is_set)
                                G_reader_settings:flush()
                            end
                        end,
                    }
                }
            },
            { text = "Page Scrubber: Grid", callback = function() self.ui:onPageScrubberGrid() end },
            { text = "Page Scrubber: Simple Grid", callback = function() self.ui:onPageScrubberSimpleGrid() end },
            { text = "Page Scrubber: Multi-Grid", callback = function() self.ui:onPageScrubberMultiGrid() end },
            { text = "Page Scrubber: Menu (Bookmarks)", callback = function() self.ui:onPageScrubberMenuBM() end },
            { text = "Page Scrubber: Menu (Highlights)", callback = function() self.ui:onPageScrubberMenuHL() end }
        }
    }
    
    if menu_items.document and menu_items.document.sub_item_table then
        menu_items.document.sub_item_table.page_scrubber = my_menu
    else
        menu_items.page_scrubber = my_menu
    end
end

return PageScrubberPlugin

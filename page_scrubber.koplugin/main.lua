
--[[
    page_scrubber.koplugin/main.lua
]]--

local Dispatcher      = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ReaderUI        = require("apps/reader/readerui")
local UIManager       = require("ui/uimanager")
local Device          = require("device")
local SpinWidget      = require("ui/widget/spinwidget")
local logger          = require("logger") 

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

-- ==========================================
-- GESTURE REGISTRY
-- ==========================================
function PageScrubberPlugin:init()
    Dispatcher:registerAction("page_scrubber_grid_action", { category = "none", event = "PageScrubberGrid", title = "Page Scrubber: Grid", reader = true })
    Dispatcher:registerAction("page_scrubber_simple_grid_action", { category = "none", event = "PageScrubberSimpleGrid", title = "Page Scrubber: Simple Grid", reader = true })
    Dispatcher:registerAction("page_scrubber_menu_bm_action", { category = "none", event = "PageScrubberMenuBM", title = "Page Scrubber: Menu (BM)", reader = true })
    Dispatcher:registerAction("page_scrubber_menu_hl_action", { category = "none", event = "PageScrubberMenuHL", title = "Page Scrubber: Menu (Highlights)", reader = true })

    if self.ui.menu then self.ui.menu:registerToMainMenu(self) end
end

-- ==========================================
-- LAUNCH TRIGGERS
-- ==========================================
function ReaderUI:onPageScrubberLaunch(mode, tab)
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
            transparent_bg    = is_transparent,
            ui_scale          = getScale(),
        })
        if Device:isKindle() then UIManager:setDirty(nil, "full") end
    end)
end

function ReaderUI:onPageScrubberGrid()
    self:onPageScrubberLaunch("grid")
end

function ReaderUI:onPageScrubberSimpleGrid()
    self:onPageScrubberLaunch("grid_simple")
end

function ReaderUI:onPageScrubberMenuBM()
    self:onPageScrubberLaunch("split", "bookmarks")
end

function ReaderUI:onPageScrubberMenuHL()
    self:onPageScrubberLaunch("split", "highlights")
end

-- ==========================================
-- KOREADER MENU BUILDER
-- ==========================================
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
                                title_text = "Page Scrubber UI scale (%)", 
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
                    }
                }
            },
            {
                text = "Page Scrubber: Grid",
                callback = function() self.ui:onPageScrubberGrid() end,
            },
            {
                text = "Page Scrubber: Simple Grid",
                callback = function() self.ui:onPageScrubberSimpleGrid() end,
            },
            {
                text = "Page Scrubber: Menu (BM)",
                callback = function() self.ui:onPageScrubberMenuBM() end,
            },
            {
                text = "Page Scrubber: Menu (Highlights)",
                callback = function() self.ui:onPageScrubberMenuHL() end,
            }
        }
    }
    
    if menu_items.document and menu_items.document.sub_item_table then
        menu_items.document.sub_item_table.page_scrubber = my_menu
    else
        menu_items.page_scrubber = my_menu
    end
end

return PageScrubberPlugin

--[[
    page_scrubber.koplugin/main.lua
]]--

local Dispatcher      = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ReaderUI        = require("apps/reader/readerui")
local UIManager       = require("ui/uimanager")
local Device          = require("device")
local SpinWidget      = require("ui/widget/spinwidget")
local InputDialog     = require("ui/widget/inputdialog")
local InfoMessage     = require("ui/widget/infomessage")

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

local function getScale() return (G_reader_settings and G_reader_settings:readSetting(SCALE_KEY)) or 1.0 end
local function setScale(val)
    if G_reader_settings then
        G_reader_settings:saveSetting(SCALE_KEY, val)
        G_reader_settings:flush()
    end
end

function PageScrubberPlugin:init()
    Dispatcher:registerAction("page_scrubber_grid_action", { category = "none", event = "PageScrubberGrid", title = _("Page Scrubber: Grid"), reader = true })
    Dispatcher:registerAction("page_scrubber_simple_grid_action", { category = "none", event = "PageScrubberSimpleGrid", title = _("Page Scrubber: Simple Grid"), reader = true })
    Dispatcher:registerAction("page_scrubber_multi_grid_action", { category = "none", event = "PageScrubberMultiGrid", title = _("Page Scrubber: Multi-Grid"), reader = true })
    Dispatcher:registerAction("page_scrubber_menu_bm_action", { category = "none", event = "PageScrubberMenuBM", title = _("Page Scrubber: Menu (Bookmarks)"), reader = true })
    Dispatcher:registerAction("page_scrubber_menu_hl_action", { category = "none", event = "PageScrubberMenuHL", title = _("Page Scrubber: Menu (Highlights)"), reader = true })
    
    Dispatcher:registerAction("page_scrubber_toc_action", { category = "none", event = "PageScrubberToc", title = _("Page Scrubber: Index"), reader = true })

    if self.ui.menu then self.ui.menu:registerToMainMenu(self) end

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
        UIManager:show(ScrubberToc:new{
            ui = ui,
            initial_page = ui.view and ui.view.state and ui.view.state.page or 1,
            initial_origin = ui.view and ui.view.state and ui.view.state.page or 1,
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
                sub_item_table = {
                    {
                        text_func = function() return _("UI Scale:") .. " " .. math.floor(getScale() * 100) .. "%" end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            local spin = SpinWidget:new{
                                title_text = _("UI Scale (%)"), 
                                value = math.floor(getScale() * 100),
                                value_min = 50, value_max = 200, 
                                value_step = 5, value_hold_step = 5,
                                ok_text = _("Save"),
                                callback = function(spin_widget) 
                                    setScale(spin_widget.value / 100)
                                    if touchmenu_instance then touchmenu_instance:updateItems() end 
                                end,
                            }
                            UIManager:show(spin)
                        end,
                    },
                    {
                        text = _("3-Page Grid: Show full pages"),
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
                    },
                    {
                        text = _("Export notes of this document"),
                        keep_menu_open = false,
                        callback = function()
                            local title = "Book"
                            if self.ui.doc_props and self.ui.doc_props.title and self.ui.doc_props.title ~= "" then
                                title = self.ui.doc_props.title
                            elseif self.ui.document and self.ui.document.file then
                                title = self.ui.document.file:match("([^/\\]+)$") or "Book"
                                title = title:gsub("%.%w+$", "")
                            end

                            local safe_title = title:gsub("%s+", "_"):gsub("[\\/:*?\"<>|]", "")
                            local default_filename = safe_title .. "_" .. _("Notes") .. ".md"

                            local dialog
                            dialog = InputDialog:new{
                                title = _("Export as..."),
                                input = default_filename,
                                buttons = {
                                    {
                                        {
                                            text = _("Cancel"),
                                            id = "close",
                                            callback = function() UIManager:close(dialog) end
                                        },
                                        {
                                            text = _("Save"),
                                            is_enter_default = true,
                                            callback = function()
                                                local filename = dialog:getInputText()
                                                UIManager:close(dialog)
                                                
                                                local info = InfoMessage:new{ text = _("Exporting...") }
                                                UIManager:show(info)
                                                
                                                UIManager:scheduleIn(0.1, function()
                                                    local bm_pages_set = {}
                                                    
                                                    -- Por si KOReader guardó algún marcador antiguo suelto
                                                    pcall(function()
                                                        local bms = self.ui.doc_props and self.ui.doc_props.bookmarks
                                                        if type(bms) == "table" then
                                                            for k, v in pairs(bms) do
                                                                local p = tonumber(k) or (type(v) == "table" and (tonumber(v.page) or tonumber(v.pageno)))
                                                                if p then bm_pages_set[math.floor(p)] = true end
                                                            end
                                                        end
                                                    end)

                                                    local annotations = self.ui.annotation and self.ui.annotation.annotations or {}
                                                    local pages = {}
                                                    local page_order = {}
                                                    
                                                    -- Separamos la paja del trigo en 1 sola pasada
                                                    for _, ann in ipairs(annotations) do
                                                        local p = tonumber(ann.pageno) or tonumber(ann.page) or tonumber(ann.pos0)
                                                        if type(ann.page) == "string" and self.ui.document and self.ui.document.getPageFromXPointer then
                                                            pcall(function() p = self.ui.document:getPageFromXPointer(ann.page) end)
                                                        end
                                                        
                                                        if p then
                                                            p = math.floor(p)
                                                            local has_drawer = ann.drawer ~= nil
                                                            local has_note = ann.note and ann.note ~= ""
                                                            
                                                            if has_drawer or has_note then
                                                                -- Tiene subrayado real o nota tuya: va al cuerpo del documento
                                                                if not pages[p] then
                                                                    pages[p] = {}
                                                                    table.insert(page_order, p)
                                                                end
                                                                table.insert(pages[p], ann)
                                                            else
                                                                -- No tiene línea ni nota: es solo un marcador de página (orejita)
                                                                bm_pages_set[p] = true
                                                            end
                                                        end
                                                    end
                                                    table.sort(page_order)
                                                    
                                                    local bm_list = {}
                                                    for p, _ in pairs(bm_pages_set) do table.insert(bm_list, p) end
                                                    table.sort(bm_list)

                                                    -- ESCRITURA DEL ARCHIVO CON LA RUTA EXACTA
                                                    local export_dir = self.ui.document.file:match("^(.*[/\\])") or "./"
                                                    local full_path = export_dir .. filename

                                                    local f = io.open(full_path, "w")
                                                    if f then
                                                        f:write("# " .. title .. "\n\n")
                                                        
                                                        if #bm_list > 0 then
                                                            f:write("🔖 : " .. table.concat(bm_list, ", ") .. "\n\n")
                                                        end

                                                        f:write("---\n\n")

                                                        for _, p in ipairs(page_order) do
                                                            f:write("## " .. tostring(p) .. "\n")
                                                            for _, ann in ipairs(pages[p]) do
                                                                if ann.text and ann.text ~= "" then
                                                                    local text = ann.text:gsub("\n", " ")
                                                                    local drawer = ann.drawer or "lighten"
                                                                    if drawer == "invert" then
                                                                        f:write("> *" .. text .. "*\n")
                                                                    elseif drawer == "underscore" then
                                                                        f:write("> **" .. text .. "**\n")
                                                                    elseif drawer == "strikeout" then
                                                                        f:write("> ~~" .. text .. "~~\n")
                                                                    else
                                                                        f:write("> " .. text .. "\n")
                                                                    end
                                                                end
                                                                if ann.note and ann.note ~= "" then
                                                                    f:write("- " .. ann.note:gsub("\n", " ") .. "\n")
                                                                end
                                                                f:write("\n")
                                                            end
                                                            f:write("---\n\n")
                                                        end
                                                        f:close()
                                                        UIManager:close(info)
                                                        
                                                        local success_msg = _("Saved successfully in:") .. "\n\n" .. full_path
                                                        UIManager:show(InfoMessage:new{ text = success_msg, timeout = 7 })
                                                    else
                                                        UIManager:close(info)
                                                        UIManager:show(InfoMessage:new{ text = _("Failed to export notes") })
                                                    end
                                                end)
                                            end
                                        }
                                    }
                                }
                            }
                            UIManager:show(dialog)
                        end,
                    }
                }
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

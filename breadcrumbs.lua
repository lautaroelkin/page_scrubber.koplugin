--[[
    page_scrubber.koplugin/breadcrumbs.lua
    Historial de "migas de pan" (estilo Kindle Page Flip) guardado por libro.
    Cada vez que se salta desde la posicion X a otra pagina, X queda guardada como pin.

    Cada pin se guarda como { p = <pagina>, xp = <xpointer> }. En documentos reflowables (EPUB)
    la pagina se recalcula desde el xpointer al leer, asi el pin sigue en su lugar aunque cambien
    fuente, margenes o DPI. En PDF/CBZ no hay xpointer y se usa el numero de pagina tal cual.
    Entradas viejas (solo un numero) siguen funcionando.
]]--

local Breadcrumbs = {}

local KEY = "page_scrubber_breadcrumbs"
-- Kindle: 3 puntos en total = origen (siempre, gris) + 2 de historial.
-- Se guardan 3 por si uno coincide con la pagina de origen y hay que descartarlo al mostrar.
local MAX_PINS = 3
Breadcrumbs.MAX_SHOWN = 2

-- Mientras vale true, el hook de addCurrentLocationToStack no registra nada
-- (lo usa _gotoPage, que ya registra la pagina de origen por su cuenta).
Breadcrumbs.suppress = false

function Breadcrumbs.isEnabled()
    return G_reader_settings ~= nil and G_reader_settings:isTrue("page_scrubber_breadcrumbs")
end

local function currentPage(ui)
    local p = ui.view and ui.view.state and ui.view.state.page
    if type(p) ~= "number" or p < 1 then
        local ok, res = pcall(function() return ui.document:getCurrentPage() end)
        p = ok and res or nil
    end
    return p
end

local function pageToXPointer(ui, page)
    local doc = ui and ui.document
    if not (doc and type(doc.getPageXPointer) == "function") then return nil end
    local ok, xp = pcall(doc.getPageXPointer, doc, page)
    if ok and type(xp) == "string" and xp ~= "" then return xp end
    return nil
end

-- Devuelve la pagina actual del pin: desde el xpointer si se puede, si no el numero guardado.
local function resolveEntry(ui, entry)
    local p, xp
    if type(entry) == "number" then
        p = entry
    elseif type(entry) == "table" then
        p, xp = entry.p, entry.xp
    end
    local doc = ui and ui.document
    if xp and doc and type(doc.getPageFromXPointer) == "function" then
        local ok, res = pcall(doc.getPageFromXPointer, doc, xp)
        if ok and type(res) == "number" and res >= 1 then p = res end
    end
    if type(p) == "number" and p >= 1 then return math.floor(p) end
    return nil
end

-- Guarda en memoria y fuerza la escritura a disco (si no, se perderia ante un apagado brusco)
local function save(ui, list)
    ui.doc_settings:saveSetting(KEY, list)
    if ui.doc_settings.flush then
        pcall(function() ui.doc_settings:flush() end)
    end
end

local function readEntries(ui)
    local list = ui and ui.doc_settings and ui.doc_settings:readSetting(KEY)
    return type(list) == "table" and list or {}
end

-- Paginas de los pines, de mas viejo a mas nuevo, sin repetidos ni fuera de rango.
function Breadcrumbs.get(ui, total)
    local out, seen = {}, {}
    local entries = readEntries(ui)
    -- recorremos de nuevo a viejo: si dos pines resuelven a la misma pagina, gana el mas reciente
    for i = #entries, 1, -1 do
        local p = resolveEntry(ui, entries[i])
        if p and (not total or p <= total) and not seen[p] then
            seen[p] = true
            table.insert(out, 1, p)
        end
    end
    while #out > MAX_PINS do table.remove(out, 1) end
    return out
end

-- Pines de historial a mostrar: los ultimos MAX_SHOWN, sin contar la pagina de origen
-- (el origen se dibuja aparte, en gris).
function Breadcrumbs.getShown(ui, total, origin_page)
    local pins = {}
    local hist = Breadcrumbs.get(ui, total)
    for i = #hist, 1, -1 do
        if hist[i] ~= origin_page then
            table.insert(pins, 1, hist[i])
            if #pins >= Breadcrumbs.MAX_SHOWN then break end
        end
    end
    return pins
end

-- Configura un ProgressSlider: con la opcion activa muestra origen (gris) + historial;
-- si no, deja `fallback_bookmarks` (los puntos normales de esa vista, o nil).
function Breadcrumbs.applyToSlider(slider, ui, total, origin_page, fallback_bookmarks)
    if not slider then return end
    if Breadcrumbs.isEnabled() then
        slider.breadcrumb_mode = true
        slider.origin_pin = origin_page
        slider.bookmarks = Breadcrumbs.getShown(ui, total, origin_page)
    else
        slider.breadcrumb_mode = false
        slider.origin_pin = nil
        slider.bookmarks = fallback_bookmarks
    end
end

function Breadcrumbs.push(ui, page, total)
    if not (ui and ui.doc_settings) or type(page) ~= "number" then return end
    page = math.floor(page)
    local entries = readEntries(ui)
    local kept = {}
    for _, e in ipairs(entries) do
        local p = resolveEntry(ui, e)
        if p and p ~= page and (not total or p <= total) then
            -- los viejos de un solo numero se migran al formato nuevo
            if type(e) == "number" then e = { p = p, xp = pageToXPointer(ui, p) } end
            kept[#kept + 1] = e
        end
    end
    kept[#kept + 1] = { p = page, xp = pageToXPointer(ui, page) }
    while #kept > MAX_PINS do table.remove(kept, 1) end
    save(ui, kept)
end

function Breadcrumbs.remove(ui, page)
    if not (ui and ui.doc_settings) then return end
    local kept = {}
    for _, e in ipairs(readEntries(ui)) do
        if resolveEntry(ui, e) ~= page then kept[#kept + 1] = e end
    end
    save(ui, kept)
end

function Breadcrumbs.clear(ui)
    if ui and ui.doc_settings then
        ui.doc_settings:delSetting(KEY)
        if ui.doc_settings.flush then
            pcall(function() ui.doc_settings:flush() end)
        end
    end
end

-- Engancha ReaderLink:addCurrentLocationToStack para capturar tambien los saltos hechos
-- FUERA del scrubber (footnotes, links, TOC, "ir a pagina"). Es idempotente.
function Breadcrumbs.hook(ui)
    local link = ui and ui.link
    if not link or link._ps_bc_hooked or type(link.addCurrentLocationToStack) ~= "function" then
        return
    end
    link._ps_bc_hooked = true
    local orig = link.addCurrentLocationToStack
    link.addCurrentLocationToStack = function(self_, ...)
        if not Breadcrumbs.suppress and Breadcrumbs.isEnabled() then
            local ok, p = pcall(currentPage, ui)
            if ok and p then
                local total = ui.document and ui.document.getPageCount and ui.document:getPageCount()
                pcall(Breadcrumbs.push, ui, p, total)
            end
        end
        return orig(self_, ...)
    end
end

return Breadcrumbs

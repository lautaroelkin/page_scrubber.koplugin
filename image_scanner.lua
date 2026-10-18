--[[
image_scanner.lua
Busqueda de imagenes en un libro (por ahora solo EPUB abierto con crengine).

Idea: para una pagina se le pide a crengine el HTML de su rango (del xpointer de la pagina al de
la siguiente), se buscan las etiquetas <img> / <image> de ese fragmento y cada "src" se resuelve
contra un indice de los archivos del EPUB (nombre base -> rutas completas).

API (todas reciben `ui`, el ReaderUI de KOReader):

    ImageScanner.isSupported(ui)                         -> boolean
    ImageScanner.getFileIndex(ui)                        -> { [nombre_base_en_minusculas] = { rutas... } } | nil
    ImageScanner.listPageImages(ui, page, total_pages)   -> { { path = "...", data = "<bytes>" }, ... }
                                                            (la de mayor peso primero)
    ImageScanner.decode(path, data)                      -> BlitBuffer | nil
    ImageScanner.fitToBox(bb, max_w, max_h, max_upscale) -> BlitBuffer escalado y aplanado sobre blanco
                                                            (libera `bb`) | nil
    ImageScanner.getPageImageBB(ui, page, max_w, max_h, total_pages, opts)
                                                         -> BlitBuffer listo para pintar | nil
        opts.min_size    (48)  imagenes con un lado menor se descartan (iconos)
        opts.max_upscale (2)   cuanto se permite agrandar una imagen chica
        opts.max_tries   (4)   cuantas candidatas se prueban para decodificar

    -- Para el tab de imagenes (escaneo incremental, clasificacion y persistencia):
    ImageScanner.probeSize(data)                         -> w, h | nil   (sin decodificar)
    ImageScanner.newScan(ui, to_page, opts)              -> scan  (scan:step(segundos) hasta scan.done)
    ImageScanner.classify(item, total_pages)             -> "general" | "junk", motivo
    ImageScanner.getBook(ui) / ImageScanner.flush(ui)    -> datos persistentes del libro (favoritos y cache)
    ImageScanner.decodeFit(ui, item, max_w, max_h)       -> BlitBuffer ajustado al recuadro | nil
    ImageScanner.decodeSource(ui, item, max_side)        -> BlitBuffer "fuente" (aplanado, en gris si la pantalla no
                                                            es de color, lado mayor <= max_side) | nil. Se decodifica UNA
                                                            vez por imagen y de ahi salen el panel y el zoom.
    ImageScanner.fitFrom(src, max_w, max_h, max_upscale) -> copia nueva de `src` ajustada al recuadro (NO libera `src`)

Quien recibe un BlitBuffer es responsable de liberarlo (bb:free()).
Nada de esto lanza errores: si algo no esta disponible en la version de KOReader, devuelve nil.
--]]

local Blitbuffer = require("ffi/blitbuffer")

local ImageScanner = {}

local INDEX_KEY = "_image_scanner_file_index"

-- ---------------------------------------------------------------------------
-- Helpers internos (puros: se pueden probar fuera de KOReader)
-- ---------------------------------------------------------------------------

-- Referencias a imagenes dentro de un fragmento HTML
function ImageScanner._htmlImageRefs(html)
    local refs = {}
    local function add(v)
        if v and v ~= "" and not v:match("^data:") and not v:match("^%a[%w+.-]*://") then
            refs[#refs + 1] = v
        end
    end
    for tag in html:gmatch("<[iI][mM][gG]%f[%s/>][^>]*>") do
        add(tag:match("[sS][rR][cC]%s*=%s*\"([^\"]+)\"") or tag:match("[sS][rR][cC]%s*=%s*\39([^\39]+)\39"))
    end
    for tag in html:gmatch("<[iI][mM][aA][gG][eE]%f[%s/>][^>]*>") do
        add(tag:match("[hH][rR][eE][fF]%s*=%s*\"([^\"]+)\"") or tag:match("[hH][rR][eE][fF]%s*=%s*\39([^\39]+)\39"))
    end
    return refs
end

-- Ruta real dentro del EPUB para un "src" relativo
function ImageScanner._resolveRef(by_base, ref)
    local clean = ref:gsub("[#?].*$", "")
    clean = clean:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    local base = clean:match("([^/]+)$")
    if not base then return nil end
    local list = by_base[base:lower()]
    if not list then return nil end
    if #list == 1 then return list[1] end
    -- varios archivos con el mismo nombre: gana el que mejor calza con el final de la ruta pedida
    local tail = clean
    while tail:sub(1, 3) == "../" or tail:sub(1, 2) == "./" do
        tail = tail:gsub("^%.%.?/", "", 1)
    end
    for _, p in ipairs(list) do
        if #p >= #tail and p:sub(-#tail) == tail then return p end
    end
    return list[1]
end

-- ---------------------------------------------------------------------------
-- API publica
-- ---------------------------------------------------------------------------

function ImageScanner.isSupported(ui)
    local doc = ui and ui.document
    return (doc and doc.file and doc.getPageXPointer and doc.getHTMLFromXPointers
            and doc.getDocumentFileContent and doc.file:lower():match("%.epub$")) and true or false
end

-- Indice nombre-base -> rutas completas de los archivos del EPUB (se arma una vez por sesion)
function ImageScanner.getFileIndex(ui)
    if ui[INDEX_KEY] ~= nil then return ui[INDEX_KEY] or nil end
    ui[INDEX_KEY] = false
    local doc = ui.document
    local okA, Archiver = pcall(require, "ffi/archiver")
    if not (okA and Archiver and Archiver.Reader) then return nil end
    local arc = Archiver.Reader:new()
    if not arc:open(doc.file) then return nil end
    local by_base = {}
    local ok = pcall(function()
        for entry in arc:iterate() do
            if entry.mode == "file" and entry.path then
                local base = entry.path:match("([^/]+)$")
                if base then
                    base = base:lower()
                    by_base[base] = by_base[base] or {}
                    table.insert(by_base[base], entry.path)
                end
            end
        end
    end)
    pcall(function() arc:close() end)
    if not ok then return nil end
    ui[INDEX_KEY] = by_base
    return by_base
end

function ImageScanner.listPageImages(ui, page, total_pages)
    if not ImageScanner.isSupported(ui) then return {} end
    local doc = ui.document

    local okx, html = pcall(function()
        local total = total_pages or (doc.getPageCount and doc:getPageCount()) or 1
        local xp0 = doc:getPageXPointer(page)
        local xp1 = (page < total) and doc:getPageXPointer(page + 1) or xp0
        return doc:getHTMLFromXPointers(xp0, xp1)
    end)
    if not (okx and type(html) == "string" and html ~= "") then return {} end

    local refs = ImageScanner._htmlImageRefs(html)
    if #refs == 0 then return {} end

    local by_base = ImageScanner.getFileIndex(ui)
    if not by_base then return {} end

    local cands, seen = {}, {}
    for _, ref in ipairs(refs) do
        local path = ImageScanner._resolveRef(by_base, ref)
        if path and not seen[path] then
            seen[path] = true
            local okd, data = pcall(doc.getDocumentFileContent, doc, path)
            if okd and type(data) == "string" and #data > 0 then
                cands[#cands + 1] = { path = path, data = data }
            end
        end
    end
    -- La de mayor peso primero (suele ser la ilustracion principal)
    table.sort(cands, function(a, b) return #a.data > #b.data end)
    return cands
end

function ImageScanner.decode(path, data)
    local okR, RenderImage = pcall(require, "ui/renderimage")
    if not okR then return nil end
    local img
    if path and path:lower():match("%.svg$") then
        local ok, res = pcall(RenderImage.renderSVGImageDataWithCRengine, RenderImage, data, #data)
        if ok then img = res end
    end
    if not img then
        local ok, res = pcall(RenderImage.renderImageData, RenderImage, data, #data)
        if ok then img = res end
    end
    return img
end

-- true solo si estamos SEGUROS de que la pantalla no es de color (si no se puede saber, no se convierte)
local function screenIsGray()
    local ok, color = pcall(function()
        local Device = require("device")
        local Screen = Device.screen
        if Screen and Screen.isColorEnabled then return Screen:isColorEnabled() end
        if Device.hasColorScreen then return Device:hasColorScreen() end
        return true
    end)
    return ok and (not color)
end

-- Aplana sobre blanco (transparencias). Libera `bb` si lo logra; si no, devuelve `bb` tal cual.
local function flattenOnWhite(bb)
    local okF, flat = pcall(function()
        local f = Blitbuffer.new(bb:getWidth(), bb:getHeight(), bb:getType())
        f:fill(Blitbuffer.COLOR_WHITE)
        f:alphablitFrom(bb, 0, 0, 0, 0, bb:getWidth(), bb:getHeight())
        return f
    end)
    if okF and flat then
        pcall(function() bb:free() end)
        return flat
    end
    return bb
end

-- Pasa a escala de grises (BB8) en pantallas sin color: 4 veces menos memoria, escalado y pintado
-- mas rapidos. Libera `bb` si lo logra; si no, devuelve `bb` tal cual.
local function toScreenGray(bb)
    if bb:getType() == Blitbuffer.TYPE_BB8 or not screenIsGray() then return bb end
    local okG, g = pcall(function()
        local gb = Blitbuffer.new(bb:getWidth(), bb:getHeight(), Blitbuffer.TYPE_BB8)
        gb:blitFrom(bb, 0, 0, 0, 0, bb:getWidth(), bb:getHeight())
        return gb
    end)
    if okG and g then
        pcall(function() bb:free() end)
        return g
    end
    return bb
end

function ImageScanner.fitToBox(bb, max_w, max_h, max_upscale)
    local okR, RenderImage = pcall(require, "ui/renderimage")
    if not okR then return nil end
    local iw, ih = bb:getWidth(), bb:getHeight()
    local scale = math.min(max_w / iw, max_h / ih, max_upscale or 2)
    local nw, nh = math.max(1, math.floor(iw * scale + 0.5)), math.max(1, math.floor(ih * scale + 0.5))
    local okS, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage, bb, nw, nh, true)
    if not (okS and scaled) then return nil end
    -- Aplanar sobre blanco (transparencias) y, en pantallas sin color, pasar a grises
    return toScreenGray(flattenOnWhite(scaled))
end

function ImageScanner.getPageImageBB(ui, page, max_w, max_h, total_pages, opts)
    opts = opts or {}
    if max_w < 8 or max_h < 8 then return nil end
    local cands = ImageScanner.listPageImages(ui, page, total_pages)
    local min_size = opts.min_size or 48
    for i = 1, math.min(#cands, opts.max_tries or 4) do
        local img = ImageScanner.decode(cands[i].path, cands[i].data)
        if img then
            if img:getWidth() >= min_size and img:getHeight() >= min_size then
                return ImageScanner.fitToBox(img, max_w, max_h, opts.max_upscale or 2)
            end
            img:free()
        end
    end
    return nil
end


-- ---------------------------------------------------------------------------
-- Tamano de una imagen SIN decodificarla (solo cabeceras). Devuelve w, h o nil.
-- ---------------------------------------------------------------------------
local function be16(s, i) local a, b = s:byte(i, i + 1); return a and (a * 256 + b) or nil end
local function le16(s, i) local a, b = s:byte(i, i + 1); return a and (a + b * 256) or nil end
local function be32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return a and (((a * 256 + b) * 256 + c) * 256 + d) or nil
end
local function le24(s, i)
    local a, b, c = s:byte(i, i + 2)
    return a and (a + b * 256 + c * 65536) or nil
end

function ImageScanner.probeSize(data)
    if type(data) ~= "string" or #data < 16 then return nil end
    -- PNG
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then
        local w, h = be32(data, 17), be32(data, 21)
        if w and h then return w, h end
        return nil
    end
    -- GIF
    if data:sub(1, 3) == "GIF" then
        return le16(data, 7), le16(data, 9)
    end
    -- JPEG: se recorren los marcadores hasta el primer SOFn
    if data:byte(1) == 0xFF and data:byte(2) == 0xD8 then
        local i, n = 3, #data
        local guard = 0
        while i + 8 < n and guard < 200 do
            guard = guard + 1
            if data:byte(i) ~= 0xFF then i = i + 1
            else
                local m = data:byte(i + 1)
                if m == 0xFF then
                    i = i + 1
                elseif m == 0x01 or (m >= 0xD0 and m <= 0xD9) then
                    i = i + 2
                elseif (m >= 0xC0 and m <= 0xCF) and m ~= 0xC4 and m ~= 0xC8 and m ~= 0xCC then
                    return be16(data, i + 7), be16(data, i + 5)
                else
                    local len = be16(data, i + 2)
                    if not len or len < 2 then return nil end
                    i = i + 2 + len
                end
            end
        end
        return nil
    end
    -- WebP
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        local kind = data:sub(13, 16)
        if kind == "VP8 " then
            local w, h = le16(data, 27), le16(data, 29)
            return w and (w % 16384), h and (h % 16384)
        elseif kind == "VP8L" then
            local b1, b2, b3, b4 = data:byte(23, 26)
            if not b4 then return nil end
            local w = 1 + (b1 + (b2 % 64) * 256)
            local h = 1 + (math.floor(b2 / 64) + b3 * 4 + (b4 % 16) * 1024)
            return w, h
        elseif kind == "VP8X" then
            local w, h = le24(data, 25), le24(data, 28)
            return w and (w + 1), h and (h + 1)
        end
        return nil
    end
    -- SVG: viewBox o width/height de la etiqueta raiz
    local head = data:sub(1, 2048)
    if head:find("<svg", 1, true) then
        local vb = head:match("[vV]iew[bB]ox%s*=%s*\"([^\"]+)\"")
        if vb then
            local _, _, w, h = vb:match("([%-%d%.]+)[%s,]+([%-%d%.]+)[%s,]+([%-%d%.]+)[%s,]+([%-%d%.]+)")
            w, h = tonumber(w), tonumber(h)
            if w and h and w > 0 and h > 0 then return w, h end
        end
        local w = tonumber((head:match("<svg[^>]-%swidth%s*=%s*\"([%d%.]+)")))
        local h = tonumber((head:match("<svg[^>]-%sheight%s*=%s*\"([%d%.]+)")))
        if w and h then return w, h end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Clasificacion: "junk" (ornamentos, logos, publicidad del final...) o "general"
-- ---------------------------------------------------------------------------
-- Criterios inspirados en Glimpse (glimpse_scanner.lua), versiones simples: sin leer epigrafes ni epub:type.
-- Nombres de archivo: palabra completa (iconic / brands no cuentan) o prefijo de palabra.
local JUNK_WORDS = {
    "logo", "icon", "brand", "bullet", "banner", "spacer", "divider", "barcode", "promo",
    "signup", "praise", "author",
}
local JUNK_PREFIXES = {
    "publisher", "colophon", "copyright", "advert", "ornament", "separator", "newsletter",
    "backad", "sign%-up", "also%-?by",
}
local JUNK_ANYWHERE = { "half.?title", "title.?page" }

local BACKMATTER_PAGES = 6   -- ultimas N paginas del libro

local function junkName(name)
    for _, w in ipairs(JUNK_WORDS) do
        if name:find("%f[%a]" .. w .. "%f[%A]") then return true end
    end
    for _, w in ipairs(JUNK_PREFIXES) do
        if name:find("%f[%a]" .. w) then return true end
    end
    for _, w in ipairs(JUNK_ANYWHERE) do
        if name:find(w) then return true end
    end
    return false
end

local function dupKey(it)
    if it.w and it.h and it.size then return it.w .. "x" .. it.h .. "|" .. it.size end
    return nil
end

-- Copias del mismo dibujo con otro nombre (separadores de capitulo, ornamentos...). Devuelve un set
-- { [item] = true } con las imagenes que tienen copia. Dos reglas:
--  1) exactas: mismas medidas y mismo peso en bytes (2 o mas)
--  2) parecidas: medidas dentro de +-2% y peso dentro de +-0.3%, con al menos 4 parecidas mas
--     (grupo de 5+). Atrapa copias recomprimidas sin confundir ilustraciones sueltas.
local SIZE_TOL = 0.003
local DIM_TOL = 0.02
local MIN_SIMILAR = 4
local SERIES_MAX_AREA = 50000   -- px2: "chica" (numeros de capitulo, tiras de titulo)
local SERIES_MIN = 4            -- cantidad de imagenes de la serie
local SERIES_STRIP_RATIO = 3       -- tiras anchas (titulos de capitulo) cuentan aunque sean grandes

function ImageScanner.dupGroups(items)
    local flagged, list, exact = {}, {}, {}
    for _, it in ipairs(items or {}) do
        if it.w and it.h and it.size and it.size > 0 then
            list[#list + 1] = it
            local k = dupKey(it)
            exact[k] = (exact[k] or 0) + 1
        end
    end
    for _, it in ipairs(list) do
        if exact[dupKey(it)] >= 2 then flagged[it] = true end
    end

    table.sort(list, function(a, b) return a.size < b.size end)
    local nb = {}
    for i = 1, #list do
        local a = list[i]
        local j = i + 1
        while j <= #list and list[j].size <= a.size * (1 + SIZE_TOL) do
            local b = list[j]
            if math.abs(a.w - b.w) <= a.w * DIM_TOL and math.abs(a.h - b.h) <= a.h * DIM_TOL then
                nb[a] = (nb[a] or 0) + 1
                nb[b] = (nb[b] or 0) + 1
            end
            j = j + 1
        end
    end
    for it, n in pairs(nb) do
        if n >= MIN_SIMILAR then flagged[it] = true end
    end

    -- 3) serie con las mismas medidas (numeros de capitulo, titulos, iconitos): 4 o mas imagenes
    --    chicas, o con forma de tira ancha (proporcion 3:1 o mas), de medidas parecidas aunque el
    --    peso difiera. No toca las ilustraciones grandes del mismo tamano.
    local smalls = {}
    for _, it in ipairs(items or {}) do
        if it.w and it.h and it.w > 0 and it.h > 0 then
            local ratio = math.max(it.w, it.h) / math.min(it.w, it.h)
            if it.w * it.h < SERIES_MAX_AREA or ratio >= SERIES_STRIP_RATIO then
                smalls[#smalls + 1] = it
            end
        end
    end
    for i, a in ipairs(smalls) do
        local n = 0
        for j, b in ipairs(smalls) do
            -- medidas parecidas: +-2% o +-3 px (en tiras finas 1 px ya es un 4%)
            if i ~= j and math.abs(a.w - b.w) <= math.max(a.w * DIM_TOL, 3)
                and math.abs(a.h - b.h) <= math.max(a.h * DIM_TOL, 3) then
                n = n + 1
            end
        end
        if n >= SERIES_MIN - 1 then flagged[a] = true end
    end
    return flagged
end

function ImageScanner.classify(item, total_pages, dups)
    local w, h = item.w, item.h
    if w and h and w > 0 and h > 0 then
        local short, long = math.min(w, h), math.max(w, h)
        -- Solo lo diminuto es basura por tamano; lo chico pero unico (dibujitos) queda en general.
        -- Si ademas se repite, lo agarran las reglas de repetidas de mas abajo.
        if short < 20 or (w * h) < 7000 then return "junk", "small" end
        if long / short > 12 then return "junk", "banner" end
    end
    -- Portadas (primera pagina o con "cover" en el nombre): nunca van a basura
    local name = (item.path or ""):lower():match("([^/]+)$") or ""
    if (item.page or 0) <= 1 or name:find("%f[%a]cover%f[%A]") then return "general", nil end
    -- Repetida: la misma ruta en 3+ paginas (dos veces todavia puede ser una imagen legitima),
    -- o varios archivos identicos / casi identicos (mismas medidas y peso)
    if (item.count or 1) >= 3 then return "junk", "repeated" end
    if dups and dups[item] then return "junk", "repeated" end
    -- Contraportada: las imagenes de las ultimas 6 paginas del libro son basura
    if total_pages and item.page and item.page > total_pages - BACKMATTER_PAGES then
        return "junk", "backmatter"
    end
    if junkName(name) then return "junk", "name" end
    return "general", nil
end

-- ---------------------------------------------------------------------------
-- Escaneo incremental: se procesa por rangos de paginas dentro de un presupuesto de tiempo
-- (para no congelar la interfaz). Un rango sin imagenes se descarta de una; uno con imagenes se
-- divide a la mitad hasta ubicarlas en su pagina. Solo se mira hasta `to_page`.
-- ---------------------------------------------------------------------------
local Scan = {}
Scan.__index = Scan

function ImageScanner.newScan(ui, to_page, opts)
    opts = opts or {}
    local doc = ui.document
    local total = opts.total_pages or (doc.getPageCount and doc:getPageCount()) or to_page
    local scan = setmetatable({
        ui = ui, doc = doc, total = total,
        -- La ultima pagina no se escanea: para su rango no hay "xpointer de la pagina siguiente"
        from = opts.from or 1, to = math.min(to_page, total - 1),
        chunk = opts.chunk or 16,
        items = opts.items or {}, by_path = {},
        stack = {}, done = false, pages_total = 0, pages_done = 0,
        changes = 0,   -- sube cada vez que se agrega una imagen o se incrementa un contador (invalida caches)
    }, Scan)
    for _, it in ipairs(scan.items) do scan.by_path[it.path] = it end
    scan.pages_total = math.max(0, scan.to - scan.from + 1)

    local ranges, a = {}, scan.from
    while a <= scan.to do
        local b = math.min(scan.to, a + scan.chunk - 1)
        ranges[#ranges + 1] = { a, b }
        a = b + 1
    end
    for i = #ranges, 1, -1 do scan.stack[#scan.stack + 1] = ranges[i] end
    scan.done = (#scan.stack == 0)
    return scan
end

function Scan:_rangeRefs(a, b)
    -- Refs de UNA pagina: se piden varias veces (la propia pagina y como "siguiente" de la anterior),
    -- asi que se guardan; extraer el HTML de crengine es lo mas caro del escaneo.
    if a == b then
        local c = self._page_refs and self._page_refs[a]
        if c then return c end
    end
    local refs = self:_rangeRefsRaw(a, b)
    if a == b then
        if not self._page_refs or (self._page_refs_n or 0) >= 64 then
            self._page_refs, self._page_refs_n = {}, 0
        end
        self._page_refs[a] = refs
        self._page_refs_n = self._page_refs_n + 1
    end
    return refs
end

function Scan:_rangeRefsRaw(a, b)
    local doc = self.doc
    local ok, html = pcall(function()
        local xp0 = doc:getPageXPointer(a)
        local xp1 = (b < self.total) and doc:getPageXPointer(b + 1) or xp0
        return doc:getHTMLFromXPointers(xp0, xp1)
    end)
    if not (ok and type(html) == "string" and html ~= "") then return {} end
    return ImageScanner._htmlImageRefs(html)
end

function Scan:_record(page, refs)
    local by_base = ImageScanner.getFileIndex(self.ui)
    if not by_base then return end
    local seen, order = {}, 0
    for _, ref in ipairs(refs) do
        local path = ImageScanner._resolveRef(by_base, ref)
        if path and not seen[path] then
            seen[path] = true
            order = order + 1
            local it = self.by_path[path]
            self.changes = self.changes + 1
            if it then
                it.count = (it.count or 1) + 1
            else
                local okd, data = pcall(self.doc.getDocumentFileContent, self.doc, path)
                local w, h, size
                if okd and type(data) == "string" then
                    size = #data
                    local okp, pw, ph = pcall(ImageScanner.probeSize, data)
                    if okp then w, h = pw, ph end
                end
                it = { path = path, page = page, w = w, h = h, size = size, count = 1, seq = #self.items + 1 }
                self.items[#self.items + 1] = it
                self.by_path[path] = it
            end
        end
    end
end

-- Imagenes de UNA pagina sin las que en realidad empiezan en la siguiente (el rango incluye el borde)
function Scan:_leafRefs(p)
    local refs = self:_rangeRefs(p, p)
    if #refs == 0 or p >= self.total then return refs end
    local nxt = {}
    for _, r in ipairs(self:_rangeRefs(p + 1, p + 1)) do nxt[r] = true end
    local out = {}
    for _, r in ipairs(refs) do
        if not nxt[r] then out[#out + 1] = r end
    end
    return out
end

-- Procesa rangos hasta agotar el presupuesto (segundos). Devuelve true cuando termino.
function Scan:step(budget)
    if self.done then return true end
    local deadline = os.clock() + (budget or 0.15)
    repeat
        local r = table.remove(self.stack)
        if not r then break end
        local a, b = r[1], r[2]
        local refs = self:_rangeRefs(a, b)
        if #refs == 0 then
            self.pages_done = self.pages_done + (b - a + 1)
        elseif a == b then
            self:_record(a, self:_leafRefs(a))
            self.pages_done = self.pages_done + 1
        else
            local mid = math.floor((a + b) / 2)
            self.stack[#self.stack + 1] = { mid + 1, b }
            self.stack[#self.stack + 1] = { a, mid }
        end
    until os.clock() >= deadline
    self.done = (#self.stack == 0)
    return self.done
end

function Scan:progress()
    if self.pages_total <= 0 then return 1 end
    return math.min(1, self.pages_done / self.pages_total)
end

-- ---------------------------------------------------------------------------
-- Datos persistentes por libro (favoritos + cache del escaneo) en la carpeta de ajustes
-- ---------------------------------------------------------------------------
-- Dos archivos en la carpeta de ajustes:
--   page_scrubber_images.lua      -> cache del escaneo por libro. Tiene tope: al superarlo se borran los usados hace mas tiempo
--   page_scrubber_images_fav.lua  -> favoritos por libro. Nunca se borran solos (no se pueden volver a conseguir)
local MAX_BOOKS = 50
local TOUCH_EVERY = 24 * 3600   -- como mucho una vez por dia se actualiza "last_used" al abrir un libro

local function openSettings(name)
    local okD, DataStorage = pcall(require, "datastorage")
    local okL, LuaSettings = pcall(require, "luasettings")
    if not (okD and okL) then return nil end
    local ok, settings = pcall(function()
        return LuaSettings:open(DataStorage:getSettingsDir() .. "/" .. name)
    end)
    return ok and settings or nil
end

local function hasKeys(t)
    return type(t) == "table" and next(t) ~= nil
end

-- Guarda los favoritos de un libro (si no hay ninguno, borra la entrada para no dejar basura)
local function saveFav(fav_settings, key, fav)
    if not (fav_settings and key) then return end
    pcall(function()
        if hasKeys(fav) then
            fav_settings:saveSetting(key, fav)
        else
            fav_settings:delSetting(key)
        end
        fav_settings:flush()
    end)
end

local function baseName(p) return tostring(p):match("([^/\\]+)$") end

-- Favoritos que vienen de otro dispositivo (o de un libro movido de carpeta):
-- se buscan por nombre de archivo y se re-indexan a la ruta actual
local function adoptFavByName(fav_settings, file)
    local data = fav_settings and fav_settings.data
    if type(data) ~= "table" then return nil end
    local name = baseName(file)
    local okL, lfs = pcall(require, "libs/libkoreader-lfs")
    local found
    for k, v in pairs(data) do
        if k ~= file and type(v) == "table" and baseName(k) == name
           and not (okL and lfs.attributes(k, "mode") == "file") then
            found = k
            break
        end
    end
    if not found then return nil end
    local fav = data[found]
    saveFav(fav_settings, file, fav)
    pcall(function()
        fav_settings:delSetting(found)
        fav_settings:flush()
    end)
    return fav
end

local function pruneOldBooks(settings, fav_settings, keep_key)
    local data = settings.data
    if type(data) ~= "table" then return end
    local keys = {}
    for k, v in pairs(data) do
        if type(v) == "table" then keys[#keys + 1] = k end
    end
    local excess = #keys - MAX_BOOKS
    if excess <= 0 then return end
    table.sort(keys, function(a, b)
        return (tonumber(data[a].last_used) or 0) < (tonumber(data[b].last_used) or 0)
    end)
    for _, k in ipairs(keys) do
        if excess <= 0 then break end
        if k ~= keep_key then
            -- Entradas viejas (formato anterior) guardaban los favoritos aca adentro: rescatarlos antes de borrar
            local legacy = data[k].fav
            if hasKeys(legacy) and fav_settings and not hasKeys(fav_settings:readSetting(k)) then
                saveFav(fav_settings, k, legacy)
            end
            settings:delSetting(k)
            excess = excess - 1
        end
    end
end

-- Lo que va al archivo con tope: todo menos los favoritos
local function scanOnly(book)
    local out = {}
    for k, v in pairs(book) do
        if k ~= "fav" then out[k] = v end
    end
    return out
end

function ImageScanner.getBook(ui)
    if ui._image_scanner_book then return ui._image_scanner_book end
    local book = { fav = {}, scan = nil }
    if ui.document and ui.document.file then
        local file = ui.document.file
        local settings = openSettings("page_scrubber_images.lua")
        local fav_settings = openSettings("page_scrubber_images_fav.lua")
        ui._image_scanner_fav_settings = fav_settings
        if settings then
            ui._image_scanner_settings = settings
            ui._image_scanner_key = file
            local saved = settings:readSetting(file)
            local legacy_fav = nil
            if type(saved) == "table" then
                book = saved
                legacy_fav = hasKeys(book.fav) and book.fav or nil   -- formato anterior: favoritos dentro de este archivo
                -- Marca el libro como usado (sin reescribir el archivo en cada apertura)
                local now = os.time()
                if now - (tonumber(book.last_used) or 0) > TOUCH_EVERY then
                    book.last_used = now
                    pcall(function()
                        settings:saveSetting(file, scanOnly(book))
                        settings:flush()
                    end)
                end
            end
            -- Favoritos: archivo aparte (+ migracion de los que estaban en el formato anterior)
            local fav = fav_settings and fav_settings:readSetting(file)
            if type(fav) ~= "table" then fav = adoptFavByName(fav_settings, file) end
            fav = type(fav) == "table" and fav or {}
            if legacy_fav then
                for path, v in pairs(legacy_fav) do fav[path] = v end
                saveFav(fav_settings, file, fav)
                pcall(function()
                    settings:saveSetting(file, scanOnly(book))   -- ya sin favoritos
                    settings:flush()
                end)
            end
            book.fav = fav
        end
    end
    ui._image_scanner_book = book
    return book
end

function ImageScanner.flush(ui)
    local settings, key, book = ui._image_scanner_settings, ui._image_scanner_key, ui._image_scanner_book
    if settings and key and book then
        book.last_used = os.time()
        saveFav(ui._image_scanner_fav_settings, key, book.fav)
        pcall(function()
            settings:saveSetting(key, scanOnly(book))
            pruneOldBooks(settings, ui._image_scanner_fav_settings, key)
            settings:flush()
        end)
    end
end

-- Decodifica el archivo de un item y lo ajusta al recuadro (usa el tamano real para no cargar de mas)
function ImageScanner.decodeFit(ui, item, max_w, max_h)
    local doc = ui and ui.document
    if not (doc and item and item.path) then return nil end
    local ok, data = pcall(doc.getDocumentFileContent, doc, item.path)
    if not (ok and type(data) == "string" and #data > 0) then return nil end
    local img = ImageScanner.decode(item.path, data)
    if not img then return nil end
    return ImageScanner.fitToBox(img, max_w, max_h, 1.5)
end

-- Fuente de una imagen para el panel y el zoom: se lee y decodifica UNA sola vez. Si es mas grande que
-- `max_side` se reduce; se aplana sobre blanco solo si puede tener transparencia (un JPEG es opaco);
-- y en pantallas sin color queda en grises.
function ImageScanner.decodeSource(ui, item, max_side)
    local doc = ui and ui.document
    if not (doc and item and item.path) then return nil end
    local ok, data = pcall(doc.getDocumentFileContent, doc, item.path)
    if not (ok and type(data) == "string" and #data > 0) then return nil end
    local is_jpeg = (data:byte(1) == 0xFF and data:byte(2) == 0xD8)
    local img = ImageScanner.decode(item.path, data)
    data = nil
    if not img then return nil end

    local iw, ih = img:getWidth(), img:getHeight()
    local longest = math.max(iw, ih)
    if max_side and longest > max_side then
        local f = max_side / longest
        local nw, nh = math.max(1, math.floor(iw * f + 0.5)), math.max(1, math.floor(ih * f + 0.5))
        local okR, RenderImage = pcall(require, "ui/renderimage")
        if okR and RenderImage and RenderImage.scaleBlitBuffer then
            local okS, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage, img, nw, nh, true)
            if okS and scaled then img = scaled end
        end
    end
    if not is_jpeg then img = flattenOnWhite(img) end
    return toScreenGray(img)
end

-- Copia nueva de `src` ajustada a max_w x max_h (sin agrandar mas de max_upscale). No toca `src`.
function ImageScanner.fitFrom(src, max_w, max_h, max_upscale)
    if not src or max_w < 1 or max_h < 1 then return nil end
    local iw, ih = src:getWidth(), src:getHeight()
    if iw < 1 or ih < 1 then return nil end
    local scale = math.min(max_w / iw, max_h / ih, max_upscale or 1)
    local nw, nh = math.max(1, math.floor(iw * scale + 0.5)), math.max(1, math.floor(ih * scale + 0.5))
    if nw == iw and nh == ih then
        local okc, c = pcall(function() return src:copy() end)
        return okc and c or nil
    end
    local okR, RenderImage = pcall(require, "ui/renderimage")
    if okR and RenderImage and RenderImage.scaleBlitBuffer then
        local okS, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage, src, nw, nh, false)
        if okS and scaled then
            if scaled == src then
                local okc, c = pcall(function() return src:copy() end)
                return okc and c or nil
            end
            return scaled
        end
    end
    local ok2, sc2 = pcall(function() return src:scale(nw, nh) end)
    return ok2 and sc2 or nil
end

return ImageScanner

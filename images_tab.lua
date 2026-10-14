--[[
images_tab.lua
Logica del tab "Imagenes" del split menu (sin dibujo de la lista: eso lo hace el split con los
mismos entries que usa para bookmarks/highlights/notas).

- Solo muestra imagenes hasta la pagina REAL donde esta el lector (sin spoilers) y solo
  escanea hasta ahi.
- El escaneo es incremental (por tandas con presupuesto de tiempo) para no congelar la interfaz,
  y se guarda en disco por libro (si el layout no cambio no se vuelve a escanear).
- Carpetas: favoritas / generales / basura (clasificadas automaticamente por image_scanner.classify).

Se instala con:  require("images_tab").install(PageScrubber, _)
Cada metodo agregado empieza con _img.
--]]

local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local logger = require("logger")
local Scanner = require("image_scanner")

local ImagesTab = {}

function ImagesTab.install(PageScrubber, _)
    _ = _ or function(s) return s end
    PageScrubber._imgTabEnabled = true

    local function state(self)
        if not self._img then
            self._img = { items = {}, scanned_to = 0, loaded = false, scanning = false,
                          fav_ver = 0, entries = nil, entries_key = nil, pv = nil }
        end
        return self._img
    end

    -- false en formatos que el escaner no soporta (comics, PDF): ahi el tab no se muestra
    function PageScrubber:_imgSupported()
        return Scanner.isSupported(self.ui) and true or false
    end

    function PageScrubber:_imgOrigin()
        return tonumber(self._origin_page) or tonumber(self._cur_page) or 1
    end

    function PageScrubber:_imgSig()
        return table.concat({ tostring(self._total_pages), tostring(Screen:getDPI()),
                              tostring(Screen:getWidth()), tostring(Screen:getHeight()) }, "|")
    end

    function PageScrubber:_imgLoadCache()
        local st = state(self)
        st.loaded = true
        st.items, st.scanned_to = {}, 0
        local book = Scanner.getBook(self.ui)
        local sc = book.scan
        if sc and sc.sig == self:_imgSig() and type(sc.items) == "table" then
            st.items = sc.items
            st.scanned_to = tonumber(sc.scanned_to) or 0
        end
    end

    -- Entradas visibles (hasta la pagina real del lector), con el mismo formato que usan las filas
    function PageScrubber:_imgEntries()
        local st = state(self)
        if not st.loaded then self:_imgLoadCache() end
        local origin = self:_imgOrigin()
        local key = tostring(#st.items) .. "|" .. tostring(origin) .. "|" .. tostring(st.fav_ver)
                    .. "|" .. tostring(st.items_ver or 0)
        if st.entries and st.entries_key == key then return st.entries end

        local fav = Scanner.getBook(self.ui).fav or {}
        local list = {}
        for _, it in ipairs(st.items) do
            if it.page and it.page <= origin then list[#list + 1] = it end
        end
        table.sort(list, function(a, b)
            if a.page ~= b.page then return a.page < b.page end
            return (a.seq or 0) < (b.seq or 0)
        end)
        local per_page = {}
        for _, it in ipairs(list) do per_page[it.page] = (per_page[it.page] or 0) + 1 end

        local groups = Scanner.dupGroups(st.items)
        local entries, seen_on_page = {}, {}
        for _, it in ipairs(list) do
            seen_on_page[it.page] = (seen_on_page[it.page] or 0) + 1
            local cls = Scanner.classify(it, self._total_pages, groups)
            entries[#entries + 1] = {
                page = it.page, order = seen_on_page[it.page], total_on_page = per_page[it.page],
                disp_page = tostring(self:_getDisplayPageInfo(it.page)),
                raw_index = it.seq or 0,
                img = it, path = it.path, is_fav = fav[it.path] and true or false, cls = cls,
            }
        end

        -- Se conserva la seleccion (los entries son objetos nuevos en cada reconstruccion)
        local sel = self._split_selected_item
        if sel and sel.path then
            self._split_selected_item = nil
            for _, e in ipairs(entries) do
                if e.path == sel.path and e.page == sel.page then self._split_selected_item = e; break end
            end
        end
        st.entries, st.entries_key = entries, key
        return entries
    end

    -- Lista de la carpeta elegida (nil = todas las imagenes)
    function PageScrubber:_imgList()
        local entries, folder = self:_imgEntries(), self._img_folder
        local st = state(self)
        -- Las entradas se reconstruyen (objeto nuevo) ante cualquier cambio, asi que la identidad basta
        local lc = st.list_cache
        if lc and lc.entries == entries and lc.folder == folder then return lc.list end
        local out = {}
        for _, e in ipairs(entries) do
            if folder == nil
               or (folder == "fav" and e.is_fav)
               or (folder == "general" and e.cls == "general")
               or (folder == "junk" and e.cls == "junk") then
                out[#out + 1] = e
            end
        end
        st.list_cache = { entries = entries, folder = folder, list = out }
        return out
    end

    -- Iconos de carpeta (favoritas / generales / basura) SOLO de las carpetas que tienen imagenes.
    -- La carpeta que esta elegida en este momento se mantiene visible para poder deseleccionarla.
    function PageScrubber:_imgFilterDefs()
        -- Se pide 2-3 veces por frame de pintado: se calcula una sola vez por frame
        local fm = self._img_defs_memo
        if self._in_paint and fm and fm.seq == self._paint_seq and fm.folder == self._img_folder then
            return fm.defs
        end
        local entries = self:_imgEntries()
        local st = state(self)
        local hc = st.has_cache
        if not (hc and hc.entries == entries) then
            local h = { fav = false, general = false, junk = false }
            for _, e in ipairs(entries) do
                if e.is_fav then h.fav = true end
                if e.cls == "general" then h.general = true
                elseif e.cls == "junk" then h.junk = true end
                if h.fav and h.general and h.junk then break end
            end
            hc = { entries = entries, has = h }
            st.has_cache = hc
        end
        local has = { fav = hc.has.fav, general = hc.has.general, junk = hc.has.junk }
        if self._img_folder then has[self._img_folder] = true end
        local all = {
            { key = "fav",     icon_on = self.icon_img_fav_on,  icon_off = self.icon_img_fav_off },
            { key = "general", icon_on = self.icon_img_gen_on,  icon_off = self.icon_img_gen_off },
            { key = "junk",    icon_on = self.icon_img_junk_on, icon_off = self.icon_img_junk_off },
        }
        local defs = {}
        for _, d in ipairs(all) do
            if has[d.key] then defs[#defs + 1] = d end
        end
        if self._in_paint then
            self._img_defs_memo = { seq = self._paint_seq, folder = self._img_folder, defs = defs }
        end
        return defs
    end

    -- Cantidad para el parentesis del tab: nil si todavia no se escaneo nada
    function PageScrubber:_imgCount()
        local st = state(self)
        if not st.loaded then self:_imgLoadCache() end
        if st.scanned_to <= 0 and not st.scanning then return nil end
        return #self:_imgEntries()
    end

    function PageScrubber:_imgEmptyText()
        local st = state(self)
        if st.unsupported then return _("EPUB only") end
        if st.scanning and st.scan then
            return string.format("%s %d%%", _("Scanning"), math.floor(st.scan:progress() * 100))
        end
        if st.error then return "!" end
        return "—"
    end

    -- Diagnostico: una linea por imagen en koreader.log (se llama al terminar cada escaneo)
    local function logDump(self)
        local st = state(self)
        local items = {}
        for _, it in ipairs(st.items) do items[#items + 1] = it end
        table.sort(items, function(a, b)
            if (a.page or 0) ~= (b.page or 0) then return (a.page or 0) < (b.page or 0) end
            return (a.seq or 0) < (b.seq or 0)
        end)
        local groups = Scanner.dupGroups(items)
        local dims = {}
        for _, it in ipairs(items) do
            if it.w and it.h then
                local k = it.w .. "x" .. it.h
                dims[k] = (dims[k] or 0) + 1
            end
        end
        logger.info("page-scrubber images dump: " .. #items .. " items, scanned_to=" .. tostring(st.scanned_to))
        for _, it in ipairs(items) do
            local cls, reason = Scanner.classify(it, self._total_pages, groups)
            local dk = (it.w and it.h) and (it.w .. "x" .. it.h) or "?"
            logger.info(string.format("page-scrubber img: p=%s file=%s dims=%s size=%s count=%s same_dims=%s dup=%s -> %s%s",
                tostring(it.page), tostring((it.path or ""):match("([^/]+)$")), dk, tostring(it.size),
                tostring(it.count or 1), tostring(dims[dk] or 0), tostring(groups[it] and "yes" or "no"),
                cls, reason and (" (" .. reason .. ")") or ""))
        end
    end

    local function refresh(self)
        if self._closing then return end
        if self._view_mode == "split" and self._active_tab == "images" then
            UIManager:setDirty(self, "ui", self.dimen)
        end
    end

    -- En e-ink cada refresco de pantalla completa deja ghosting y le quita CPU al escaneo
    local function refreshInterval()
        local ok, eink = pcall(function() return Device.hasEinkScreen and Device:hasEinkScreen() end)
        return (ok and eink) and 3 or 1
    end

    local function tick(self, delay)
        local st = state(self)
        UIManager:scheduleIn(delay or 0.05, function()
            if self._closing then return end
            local sc = st.scan
            if not sc then return end
            -- Mientras se hace zoom / se arrastra la imagen el escaneo espera (no le quita CPU a los gestos)
            if self._img_zoom ~= nil then tick(self, 0.4); return end
            local ok, done = pcall(sc.step, sc, 0.12)
            if not ok then
                logger.warn("page-scrubber images scan error:", done)
                st.scanning, st.scan, st.error = false, nil, tostring(done)
                refresh(self)
                return
            end
            st.items = sc.items
            -- Las entradas solo se reconstruyen si el escaneo agrego o modifico algo (antes: en cada paso)
            if sc.changes ~= st.changes_seen then
                st.changes_seen = sc.changes
                st.items_ver = (st.items_ver or 0) + 1
            end
            if done then
                st.scanning, st.scanned_to, st.scan = false, st.scan_target, nil
                local book = Scanner.getBook(self.ui)
                book.scan = { sig = self:_imgSig(), scanned_to = st.scanned_to, items = st.items }
                Scanner.flush(self.ui)
                pcall(logDump, self)
                refresh(self)
            else
                local now = os.time()
                if now - (st.last_refresh or 0) >= refreshInterval() then st.last_refresh = now; refresh(self) end
                tick(self)
            end
        end)
    end

    -- Arranca (o continua) el escaneo hasta la pagina real del lector
    function PageScrubber:_imgEnsureScan()
        local st = state(self)
        if not Scanner.isSupported(self.ui) then
            st.unsupported = true
            return
        end
        if not st.loaded then self:_imgLoadCache() end
        local target = math.min(self:_imgOrigin(), (self._total_pages or 1) - 1)
        if st.scanning or st.scanned_to >= target then return end
        st.error = nil
        st.scan_target = target
        st.changes_seen = 0
        st.scan = Scanner.newScan(self.ui, target, {
            from = st.scanned_to + 1, items = st.items, total_pages = self._total_pages,
        })
        st.scanning = true
        tick(self)
    end

    function PageScrubber:_imgToggleFavorite(entry)
        if not (entry and entry.path) then return end
        local st = state(self)
        local book = Scanner.getBook(self.ui)
        book.fav = book.fav or {}
        if book.fav[entry.path] then book.fav[entry.path] = nil else book.fav[entry.path] = true end
        Scanner.flush(self.ui)
        st.fav_ver = st.fav_ver + 1
        st.entries = nil
        self:_imgEntries()   -- reconstruye y conserva la seleccion
    end

    -- Pinta la imagen de `entry` ajustada al recuadro (x, y, w, h) de la tarjeta de preview
    function PageScrubber:_imgPaintPreview(bb, x, y, w, h, entry)
        local st = state(self)
        if not entry then
            local tw = TextWidget:new{ text = self:_imgEmptyText(), face = Font:getFace("cfont", self.S(18)),
                                       fgcolor = Blitbuffer.COLOR_DARK_GRAY }
            local sz = tw:getSize()
            tw:paintTo(bb, x + math.floor((w - sz.w) / 2), y + math.floor((h - sz.h) / 2))
            tw:free()
            return
        end
        local pad = self.S(8)
        local key = entry.path .. "|" .. w .. "x" .. h
        if not st.pv or st.pv.key ~= key then
            if st.pv and st.pv.bb then pcall(function() st.pv.bb:free() end) end
            st.pv = { key = key, bb = Scanner.decodeFit(self.ui, entry.img, w - pad * 2, h - pad * 2) }
        end
        local img = st.pv.bb
        if img then
            local iw, ih = img:getWidth(), img:getHeight()
            bb:blitFrom(img, x + math.floor((w - iw) / 2), y + math.floor((h - ih) / 2), 0, 0, iw, ih)
        else
            local tw = TextWidget:new{ text = "!", face = Font:getFace("cfont", self.S(32)), fgcolor = Blitbuffer.COLOR_BLACK }
            local sz = tw:getSize()
            tw:paintTo(bb, x + math.floor((w - sz.w) / 2), y + math.floor((h - sz.h) / 2))
            tw:free()
        end
    end

    -- Texto de la linea inferior de la polaroid: capitulo donde esta la imagen
    function PageScrubber:_imgChinText(entry)
        if not (entry and entry.page) then return "—" end
        return self:_getChapter(entry.page)
    end

    -- Icono del chin bajo la previsualizacion: sin carpeta elegida depende de la imagen
    -- (favorita > basura / general); con una carpeta elegida va directo el svg de imagen.
    function PageScrubber:_imgChinIcon(entry)
        if self._img_folder ~= nil or type(entry) ~= "table" then return self.icon_pol_img end
        if entry.is_fav then return self.icon_pol_img_fav or self.icon_pol_img end
        if entry.cls == "junk" then return self.icon_pol_img_junk or self.icon_pol_img end
        if entry.cls == "general" then return self.icon_pol_img_gen or self.icon_pol_img end
        return self.icon_pol_img
    end

    function PageScrubber:_imgFree()
        local st = self._img
        if st and st.pv and st.pv.bb then pcall(function() st.pv.bb:free() end) end
        if st then st.pv = nil; st.scan = nil; st.scanning = false end
    end
end

return ImagesTab

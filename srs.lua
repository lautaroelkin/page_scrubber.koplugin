--[[
    page_scrubber.koplugin/srs.lua
    Motor de repaso espaciado (SM-2 simplificado) para highlights y notas.
    Sin UI: solo lógica de estado.

    Persistencia: un archivo PROPIO dentro de la carpeta .sdr del libro (srs_review_data.lua), separado de la
    metadata de KOReader. Así guardar un repaso reescribe solo un archivo chico y nunca toca el progreso de
    lectura ni los subrayados del usuario.
    El estado vive en memoria mientras el libro está abierto: se carga una vez y se guarda con un pequeño retraso
    después del último cambio (varias tarjetas seguidas = una sola escritura), y al cerrar el Review Card.

    Todas las funciones reciben `ui` (ReaderUI) como primer argumento.
]]--

local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")

local SRS = {}

local FILE_NAME = "srs_review_data.lua"
local LEGACY_KEY = "page_scrubber_srs"   -- donde se guardaba antes (en la metadata del libro)
local FLUSH_DELAY = 2                    -- segundos entre el último cambio y la escritura a disco

local MIN_EASE = 1.3
local MAX_EASE = 3.0
local AGAIN_SECONDS = 600          -- 10 minutos
local DAY = 86400
local MAX_INTERVAL = 365 * DAY     -- tope anual

-- ---------------------------------------------------------------------------
-- IDs de tarjetas
-- ---------------------------------------------------------------------------

-- MD5 nativo de KOReader (ffi/sha2). Si no estuviera disponible, se usa un hash doble propio de respaldo.
local md5
do
    local ok, sha2 = pcall(require, "ffi/sha2")
    if ok and type(sha2) == "table" and type(sha2.md5) == "function" then md5 = sha2.md5 end
end

local function fallbackHash(s)
    local h1, h2 = 0, 0
    for i = 1, #s do
        local c = s:byte(i)
        h1 = (h1 * 31 + c) % 2147483647
        h2 = (h2 * 131 + c) % 2147483629
    end
    return string.format("%08x%08x", h1, h2)
end

local function hashString(s)
    if md5 then return md5(s) end
    return fallbackHash(s)
end

-- Caché de IDs: el ID se pide por cada anotación en cada repintado; calcularlo una sola vez por firma
-- evita recalcular el MD5 (lento en un e-reader). Se vacía si crece demasiado.
local id_cache, id_cache_n = {}, 0
local ID_CACHE_MAX = 5000

local function cachedId(sig)
    local id = id_cache[sig]
    if id then return id end
    id = hashString(sig)
    if id_cache_n >= ID_CACHE_MAX then id_cache, id_cache_n = {}, 0 end
    id_cache[sig] = id
    id_cache_n = id_cache_n + 1
    return id
end

-- Posición como texto estable. En EPUB es un xpointer (string); en PDF es una tabla {page, x, y}:
-- tostring(tabla) cambia en cada sesión ("table: 0x..."), así que se arma a partir de sus datos.
local function posToString(p)
    if type(p) == "table" then
        return string.format("%s:%.1f:%.1f", tostring(p.page or ""), tonumber(p.x) or 0, tonumber(p.y) or 0)
    end
    return tostring(p or "")
end

-- ID estable por anotación: xpointer + texto + fecha. Sobrevive a relayouts de CREngine.
function SRS.getId(ann)
    if not ann or type(ann) ~= "table" then return nil end
    local p0 = posToString(ann.pos0 or ann.page)
    local p1 = posToString(ann.pos1)
    local txt = tostring(ann.text or "")
    local dt = tostring(ann.datetime or "")
    if p0 == "" and p1 == "" and txt == "" and dt == "" then return nil end
    return cachedId(p0 .. "|" .. p1 .. "|" .. txt .. "|" .. dt)
end

-- ---------------------------------------------------------------------------
-- Almacenamiento: archivo propio en la carpeta .sdr, con estado en memoria
-- ---------------------------------------------------------------------------

local function dataPath(ui)
    local file = ui and ui.document and ui.document.file
    if not file then return nil end
    -- Respeta dónde el usuario eligió guardar la metadata (junto al libro, carpeta central o por hash)
    local ok, dir = pcall(function() return require("docsettings"):getSidecarDir(file) end)
    if not ok or type(dir) ~= "string" or dir == "" then
        -- Respaldo: la carpeta .sdr clásica, junto al libro
        dir = file:gsub("%.[^%./\\]+$", "") .. ".sdr"
    end
    return dir .. "/" .. FILE_NAME
end

-- Estado del libro abierto (se carga una sola vez y queda en `ui`)
local function getStore(ui)
    if not ui then return nil end
    local st = ui._page_scrubber_srs
    if st then return st end

    local path = dataPath(ui)
    if not path then return nil end

    st = { path = path, cards = {}, dirty = false }
    local ok, file = pcall(function() return require("luasettings"):open(path) end)
    if ok and file then
        st.file = file
        local cards = file:readSetting("cards")
        if type(cards) == "table" then st.cards = cards end
    end
    ui._page_scrubber_srs = st
    return st
end

local function flushStore(st)
    if not st or not st.dirty then return true end
    if st.timer then
        UIManager:unschedule(st.timer)
        st.timer = nil
    end
    local ok = pcall(function()
        local dir = st.path:match("^(.*)/[^/]*$")
        if dir and lfs.attributes(dir, "mode") ~= "directory" then
            require("util").makePath(dir)
        end
        if not st.file then st.file = require("luasettings"):open(st.path) end
        st.file:saveSetting("cards", st.cards)
        st.file:flush()
    end)
    if ok then st.dirty = false end
    return ok
end

-- Marca el estado como modificado y programa la escritura (cada cambio reinicia la cuenta)
local function markDirty(st)
    st.dirty = true
    if st.timer then UIManager:unschedule(st.timer) end
    st.timer = function()
        st.timer = nil
        flushStore(st)
    end
    UIManager:scheduleIn(FLUSH_DELAY, st.timer)
end

-- Guarda ya lo pendiente (al cerrar el Review Card, al suspender, etc.)
function SRS.flush(ui)
    local st = ui and ui._page_scrubber_srs
    if st then return flushStore(st) end
    return true
end

-- ---------------------------------------------------------------------------
-- Estado de tarjetas y SM-2
-- ---------------------------------------------------------------------------

local function newState()
    return {
        review_count = 0,
        last_review  = 0,
        next_review  = 0,      -- due inmediatamente
        ease         = 2.5,
        interval     = 0,
    }
end

function SRS.getState(ui, id)
    local st = getStore(ui)
    local s = st and st.cards[id]
    if type(s) ~= "table" then return newState() end
    return s
end

-- Intervalo (segundos) que resultaría de elegir esa calidad en esta tarjeta (para preview en botones)
function SRS.previewInterval(state, quality)
    if quality == "again" then return AGAIN_SECONDS end
    local reps = state.review_count or 0
    local ease = state.ease or 2.5
    local iv   = state.interval or 0
    local base
    if reps == 0 then
        -- Primera review: Easy salta a 4 días (estilo Anki); si no, quedaba en "1d" igual que Good
        base = (quality == "easy") and (4 * DAY) or DAY
    elseif reps == 1 then
        base = 6 * DAY
    else
        base = math.floor(iv * ease)
    end
    if quality == "easy" and reps > 0 then base = math.floor(base * 1.3) end
    return math.min(base, MAX_INTERVAL)
end

function SRS.update(ui, id, quality)
    local st = getStore(ui)
    if not st or not id then return nil end
    local s = st.cards[id]
    if type(s) ~= "table" then s = newState() end
    local now = os.time()

    local ease = s.ease or 2.5
    local reps = s.review_count or 0

    if quality == "again" then
        ease = math.max(MIN_EASE, ease - 0.2)
        reps = 0
        s.interval = AGAIN_SECONDS
    elseif quality == "good" then
        s.interval = SRS.previewInterval(s, "good")
        reps = reps + 1
    elseif quality == "easy" then
        s.interval = SRS.previewInterval(s, "easy")
        ease = math.min(MAX_EASE, ease + 0.1)
        reps = reps + 1
    else
        return nil
    end

    s.ease         = ease
    s.review_count = reps
    s.last_review  = now
    s.last_quality = quality   -- "again" | "good" | "easy": lo usa el Review Card (modo repaso) para mostrar la marca
    s.next_review  = now + s.interval
    st.cards[id] = s

    markDirty(st)
    return s
end

-- Captura el estado de una tarjeta ANTES de un update, para poder deshacerlo después.
-- Devuelve (copia_del_estado, was_new); was_new = true si la tarjeta todavía no estaba guardada.
function SRS.captureState(ui, id)
    local st = getStore(ui)
    if not st or not id then return nil, false end
    local s = st.cards[id]
    if type(s) ~= "table" then return newState(), true end
    local copy = {}
    for k, v in pairs(s) do copy[k] = v end
    return copy, false
end

-- Restaura el estado capturado por captureState. Si was_new, la tarjeta se elimina (el update la había creado).
-- Se restaura EN LUGAR (misma tabla): el Review Card guarda esa tabla como card.state para mostrar los
-- intervalos de los botones, así que reemplazarla dejaría esa vista con valores viejos.
function SRS.restoreState(ui, id, prev_state, was_new)
    local st = getStore(ui)
    if not st or not id then return end
    if was_new or type(prev_state) ~= "table" then
        st.cards[id] = nil
    else
        local s = st.cards[id]
        if type(s) ~= "table" then s = {}; st.cards[id] = s end
        for k in pairs(s) do s[k] = nil end
        for k, v in pairs(prev_state) do s[k] = v end
    end
    markDirty(st)
end

function SRS.reset(ui, id)
    local st = getStore(ui)
    if not st or not id then return end
    st.cards[id] = nil
    markDirty(st)
end

-- Reinicia TODO el repaso de este libro: todas las tarjetas vuelven a empezar desde cero
function SRS.resetAll(ui)
    local st = getStore(ui)
    if st then
        st.cards = {}
        markDirty(st)
        flushStore(st)
    end
    -- Limpia también datos de versiones anteriores guardados en la metadata del libro (sin forzar su escritura)
    pcall(function()
        local ds = ui and ui.doc_settings
        if ds and ds.readSetting and ds:readSetting(LEGACY_KEY) ~= nil then
            ds:delSetting(LEGACY_KEY)
        end
    end)
end

-- Anotaciones due (next_review <= ahora). `items` es la lista combinada de _cached_hl + _cached_notes.
function SRS.getDue(ui, items)
    local st = getStore(ui)
    local cards = st and st.cards or {}
    local now = os.time()
    local out, seen = {}, {}
    for _, item in ipairs(items or {}) do
        local id = SRS.getId(item.annotation or item)
        if id and not seen[id] then
            seen[id] = true
            local s = cards[id]
            if type(s) ~= "table" then s = newState() end
            if (s.next_review or 0) <= now then
                out[#out + 1] = { id = id, state = s, entry = item }
            end
        end
    end
    table.sort(out, function(a, b)
        return (a.state.next_review or 0) < (b.state.next_review or 0)
    end)
    return out
end

-- Todas las tarjetas, para el modo repaso (cuando ya no queda nada due). Solo LEE el estado: no escribe nada.
-- Orden: las más difíciles primero (ease más bajo; a igual ease, intervalo más corto); si empatan, el orden del libro.
function SRS.getAll(ui, items)
    local st = getStore(ui)
    local cards = st and st.cards or {}
    local out, seen = {}, {}
    for idx, item in ipairs(items or {}) do
        local id = SRS.getId(item.annotation or item)
        if id and not seen[id] then
            seen[id] = true
            local s = cards[id]
            if type(s) ~= "table" then s = newState() end
            out[#out + 1] = { id = id, state = s, entry = item, order = idx }
        end
    end
    table.sort(out, function(a, b)
        local ea, eb = a.state.ease or 2.5, b.state.ease or 2.5
        if ea ~= eb then return ea < eb end
        local ia, ib = a.state.interval or 0, b.state.interval or 0
        if ia ~= ib then return ia < ib end
        return a.order < b.order
    end)
    return out
end

-- Cantidad de tarjetas due. Se llama en cada repintado del split: no reserva tablas ni toca el disco.
function SRS.getDueCount(ui, items)
    local st = getStore(ui)
    local cards = st and st.cards or {}
    local n, now, seen = 0, os.time(), {}
    for _, item in ipairs(items or {}) do
        local id = SRS.getId(item.annotation or item)
        if id and not seen[id] then
            seen[id] = true
            local s = cards[id]
            if type(s) ~= "table" or (s.next_review or 0) <= now then n = n + 1 end
        end
    end
    return n
end

function SRS.formatInterval(sec)
    if not sec or sec <= 0 then return "now" end
    if sec < 3600 then return string.format("%dm", math.max(1, math.floor(sec / 60))) end
    if sec < DAY then return string.format("%dh", math.floor(sec / 3600)) end
    if sec < 30 * DAY then return string.format("%dd", math.floor(sec / DAY)) end
    if sec < 365 * DAY then return string.format("%dmo", math.floor(sec / (30 * DAY))) end
    return string.format("%dy", math.floor(sec / (365 * DAY)))
end

-- ---------------------------------------------------------------------------
-- Modo estudio: dónde está activo el botón "Study"
--   "off"    (por defecto) en ningún lado
--   "all"    en todos los libros
--   "folder" solo en los libros que estén dentro de la carpeta elegida (incluye subcarpetas)
-- Ajustes: page_scrubber_review_mode y page_scrubber_review_folder.
-- Si todavía no existe el modo, se respeta el ajuste viejo page_scrubber_review_enabled (true = "all").
-- ---------------------------------------------------------------------------

function SRS.getStudyMode()
    local gs = G_reader_settings
    if not gs then return "off" end
    local mode = gs:readSetting("page_scrubber_review_mode")
    if mode == "off" or mode == "all" or mode == "folder" then return mode end
    return gs:isTrue("page_scrubber_review_enabled") and "all" or "off"
end

local function normPath(p)
    local ok, ffiUtil = pcall(require, "ffi/util")
    local rp = ok and ffiUtil.realpath and ffiUtil.realpath(p) or nil
    return (((rp or p):gsub("/+$", "")))
end

-- Se consulta en cada repintado de las pestañas, así que el resultado se cachea por (carpeta, libro):
-- solo se recalcula (con realpath) cuando cambia alguno de los dos.
local study_cache = {}

function SRS.isStudyActive(ui)
    local mode = SRS.getStudyMode()
    if mode == "off" then return false end
    if mode == "all" then return true end

    local folder = G_reader_settings and G_reader_settings:readSetting("page_scrubber_review_folder")
    local file = ui and ui.document and ui.document.file
    if type(folder) ~= "string" or folder == "" or type(file) ~= "string" then return false end

    if study_cache.folder ~= folder or study_cache.file ~= file then
        local f, bf = normPath(folder), normPath(file)
        study_cache.folder, study_cache.file = folder, file
        study_cache.result = (bf:sub(1, #f + 1) == f .. "/")
    end
    return study_cache.result
end

return SRS

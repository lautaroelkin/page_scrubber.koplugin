local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ps_font")   -- como el de KOReader, pero respeta Text size > Automatic
local TextWidget = require("ui/widget/textwidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local ImageWidget = require("ui/widget/imagewidget")
local logger = require("logger")

local Screen = Device.screen
local plugin_path = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"

local ReaderHighlight = nil
pcall(function() ReaderHighlight = require("apps/reader/modules/readerhighlight") end)
local ReaderBookmark = nil
pcall(function() ReaderBookmark = require("apps/reader/modules/readerbookmark") end)

-- Menú propio para escribir notas (ps_notes_dialog.lua). Si no carga, queda el diálogo nativo de KOReader
local ok_notes_mod, NotesDialog = pcall(require, "ps_notes_dialog")
if not ok_notes_mod then
    logger.warn("PageScrubber: no cargó ps_notes_dialog, se usa el diálogo de notas nativo:", NotesDialog)
    NotesDialog = nil
end

-- Cursores de selección (módulo aparte). Si no carga, los menús siguen funcionando sin ellos
local ok_cursor_mod, SelectionCursor = pcall(require, "scrubber_cursor")
if not ok_cursor_mod then SelectionCursor = nil end

local modern_plugin_buttons_shared = {}

-- Recupera botones del diccionario que otros plugins YA registraron con ReaderDictionary:addToDictButtons.
-- Nuestro parche de addToDictButtons solo ve los registros posteriores a él: un plugin que se carga antes
-- (p. ej. OfflineTranslate y su botón "Learned") quedaba fuera del popup. Se buscan, de forma defensiva:
--   * campos del diccionario (instancia y clase) cuyo nombre contiene "button"
--   * tablas capturadas como upvalues por la función addToDictButtons original
local function harvestSpecs(tbl, depth)
    if type(tbl) ~= "table" or depth > 2 then return end
    for _, v in pairs(tbl) do
        if type(v) == "table" then
            if v.id and type(v.callback) == "function" then
                if not modern_plugin_buttons_shared[v.id] then
                    modern_plugin_buttons_shared[v.id] = v
                end
            else
                harvestSpecs(v, depth + 1)
            end
        end
    end
end

local function harvestExistingDictButtons(dictionary, add_fn)
    if type(dictionary) ~= "table" then return end
    pcall(function()
        local sources = { dictionary }
        local mt = getmetatable(dictionary)
        if mt and type(mt.__index) == "table" then table.insert(sources, mt.__index) end
        for _, src in ipairs(sources) do
            for k, v in pairs(src) do
                if type(k) == "string" and type(v) == "table" and k:lower():find("button") then
                    harvestSpecs(v, 0)
                end
            end
        end
    end)
    local fn = add_fn or dictionary._ps_orig_addToDictButtons or dictionary.addToDictButtons
    if type(fn) == "function" and type(debug) == "table" and type(debug.getupvalue) == "function" then
        pcall(function()
            for i = 1, 20 do
                local name, val = debug.getupvalue(fn, i)
                if not name then break end
                if type(val) == "table" and val ~= dictionary and val ~= _G then
                    harvestSpecs(val, 1)
                end
            end
        end)
    end
end

-- ==========================================
-- FASTDICT: MOTOR STARDIC EN MEMORIA
-- ==========================================
local fastdict_shared = {
    engine = nil,
    orig_rawSdcv = nil,
    session_disabled = false,
}

local SETTING_FASTDICT_ENABLED = "page_scrubber_fastdict_enabled"

local FloatingDict = {
    ui = nil,
    enabled = true,
    patched_dictionary = nil,
    opening_original_popup = false,
}

function FloatingDict:isFastDictEnabled()
    if G_reader_settings then
        local val = G_reader_settings:readSetting(SETTING_FASTDICT_ENABLED)
        if val ~= nil then return val == true end
    end
    return true -- Activado por defecto para máxima velocidad
end

function FloatingDict:getFastDictEngine(rd)
    if not fastdict_shared.engine then
        -- Garantiza que require("stardict") y require("dictzip") se encuentren sin fallar
        if plugin_path and not package.path:find(plugin_path, 1, true) then
            package.path = plugin_path .. "?.lua;" .. package.path
        end

        local ok_engine, engine_mod = pcall(require, "engine")
        if not ok_engine or not engine_mod then
            return nil
        end

        local lfs = require("libs/libkoreader-lfs")
        local DataStorage = require("datastorage")
        local util = require("util")

        local dict_dirs = { rd.data_dir }
        local dict_ext = rd.data_dir .. "_ext"
        if lfs.attributes(dict_ext, "mode") == "directory" then
            table.insert(dict_dirs, dict_ext)
        end
        local cache_dir = DataStorage:getDataDir() .. "/cache"
        util.makePath(cache_dir)

        fastdict_shared.engine = engine_mod.new({
            dict_dirs = dict_dirs,
            cache_dir = cache_dir,
        })
    end
    return fastdict_shared.engine
end

function FloatingDict:patchFastDict()
    if fastdict_shared.orig_rawSdcv then return end

    local ReaderDictionary = self.ui and self.ui.dictionary and self.ui.dictionary.class
    if not ReaderDictionary then
        local ok, mod = pcall(require, "apps/reader/modules/readerdictionary")
        if not ok or not mod then return end
        ReaderDictionary = mod
    end

    fastdict_shared.orig_rawSdcv = ReaderDictionary.rawSdcv
    local plugin = self

    ReaderDictionary.rawSdcv = function(rd, words, dict_names, fuzzy_search, lookup_progress_msg)
        if plugin:isFastDictEnabled() and not fastdict_shared.session_disabled and not fuzzy_search then
            local engine = plugin:getFastDictEngine(rd)
            if engine then
                local ok, results_or_err = pcall(function()
                    return engine:lookup_words(words, dict_names)
                end)
                -- Solo intercepta si devolvió coincidencias reales; si no, deriva al sdcv estándar
                if ok and results_or_err and #results_or_err > 0 and results_or_err[1] and #results_or_err[1] > 0 then
                    return false, results_or_err
                elseif not ok then
                    fastdict_shared.session_disabled = true
                end
            end
        end
        return fastdict_shared.orig_rawSdcv(rd, words, dict_names, fuzzy_search, lookup_progress_msg)
    end
end

local SETTING_DICT_ENABLED = "page_scrubber_floating_dict_enabled"
local SETTING_SELECTION_ENABLED = "page_scrubber_selection_menu_enabled"
local SETTING_HLMENU_ENABLED = "page_scrubber_hl_tap_menu"
local SETTING_NOTES_ENABLED = "page_scrubber_notes_menu"

-- Los dos ajustes de Reading Pop-Ups > Notes menu (Menu on highlight tap y Menu notes): apagados por
-- defecto, salvo que ya esté activado el Scrubber Selection Menu. Si el usuario los tocó, vale lo que eligió.
local function notesMenuSetting(key)
    if not G_reader_settings then return false end
    local v = G_reader_settings:readSetting(key)
    if v ~= nil then return v == true end
    return G_reader_settings:readSetting(SETTING_SELECTION_ENABLED) == true
end

local function getScale()
    return (G_reader_settings and G_reader_settings:readSetting("page_scrubber_popup_scale")) or 1.0
end
local function getTextOffset()
    if not G_reader_settings then return 0 end
    local size = G_reader_settings:readSetting("page_scrubber_text_size")
    if size == "small" then return -5
    elseif size == "large" then return 5
    end
    return 0
end
local function scale(px)
    return math.floor(Screen:scaleBySize(px) * getScale() + 0.5)
end
local function scaleText(px)
    return scale(px + getTextOffset())
end

-- Tamaño del selection menu (small / medium / large): escala íconos, botones y contorno.
-- "medium" es el tamaño original.
local function getSelSizeK()
    local v = G_reader_settings and G_reader_settings:readSetting("page_scrubber_sel_menu_size")
    if v == "small" then return 0.8 end
    if v == "large" then return 1.25 end
    return 1.0
end
local function sscale(px)
    return math.max(1, math.floor(scale(px) * getSelSizeK() + 0.5))
end
-- Grosor del contorno del selection menu (en px base; se escala con el tamaño elegido)
local SEL_BORDER_PX = 2.2

local function is_btn_enabled(key, default_val)
    if not G_reader_settings then
        return (default_val ~= nil) and default_val or true
    end
    local val = G_reader_settings:readSetting(key)
    if val == nil then
        if default_val ~= nil then return default_val end
        -- X-Ray y AI Assistant solo están activos si el plugin está presente
        if key:find("xray") then
            local ok, lfs = pcall(require, "libs/libkoreader-lfs")
            return ok and lfs and (lfs.attributes("plugins/xray.koplugin", "mode") == "directory") or false
        elseif key:find("_ai") then
            local ok, lfs = pcall(require, "libs/libkoreader-lfs")
            return ok and lfs and (lfs.attributes("plugins/assistant.koplugin", "mode") == "directory") or false
        end
        return true
    end
    return val == true
end

local function htmlEscape(text)
    text = tostring(text or "")
    text = text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
    return text
end

local function shouldAnchorTop(boxes)
    if type(boxes) ~= "table" or #boxes == 0 then return false end
    local selection_bottom
    for _, box in ipairs(boxes) do
        if type(box) == "table" and box.y and box.h then
            local box_bottom = box.y + box.h
            if not selection_bottom or box_bottom > selection_bottom then
                selection_bottom = box_bottom
            end
        end
    end
    if not selection_bottom then return false end
    return selection_bottom > (Screen:getHeight() / 2)
end

local function shouldAnchorLeft(boxes)
    if type(boxes) ~= "table" or #boxes == 0 then return false end
    local min_x, max_x
    for _, box in ipairs(boxes) do
        if type(box) == "table" and box.x and box.w then
            if not min_x or box.x < min_x then min_x = box.x end
            local right = box.x + box.w
            if not max_x or right > max_x then max_x = right end
        end
    end
    if not min_x or not max_x then return false end
    -- Si la palabra está en la mitad derecha (> 50%), el diccionario ancla en la izquierda
    return ((min_x + max_x) / 2) > (Screen:getWidth() / 2)
end

local function cleanWordForLookup(raw_word)
    if not raw_word then return nil end
    local s = tostring(raw_word)
    s = s:gsub("<[^>]+>", "")
    s = s:gsub("^[%s%p¿¡«»“”\"']+", ""):gsub("[%s%p¿¡«»“”\"']+$", "")
    s = s:match("^%s*(.-)%s*$") or s
    if #s > 0 then return s end
    return nil
end

-- Posición de un menú flotante horizontal pegado a un texto: arriba si hay lugar, si no abajo, y si no
-- entra en ninguno de los dos, al pie de la pantalla (como "Bottom").
--   lines: cajas en pantalla del texto, una por línea
--   opts.gap: aire entre el texto y el menú
--   opts.cx_top / opts.cx_bottom: centro horizontal del menú según quede arriba o abajo
--   opts.tapped: línea tocada; si el menú no entra fuera de todo el texto, se pega a esa línea
-- Devuelve x, y, grow_up (true si quedó arriba del texto: lo que se despliega sale hacia arriba).
local function placeNearLines(w, h, lines, opts)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local margin = scale(8)
    opts = opts or {}
    local gap = opts.gap or scale(10)
    local function clampx(cx)
        return math.max(margin, math.min(sw - margin - w, math.floor(cx - w / 2 + 0.5)))
    end
    local bottom_y = sh - h - scale(54)
    if type(lines) ~= "table" or #lines == 0 then
        return clampx(sw / 2), bottom_y, true
    end
    local first, last = lines[1], lines[#lines]
    local top, bottom = first.y, last.y + last.h
    local cx_top = opts.cx_top or (first.x + first.w / 2)
    local cx_bottom = opts.cx_bottom or (last.x + last.w / 2)
    if top - gap - h >= margin then return clampx(cx_top), top - gap - h, true end
    if bottom + gap + h <= sh - margin then return clampx(cx_bottom), bottom + gap, false end
    local t = opts.tapped
    if t then
        if t.y - gap - h >= margin then return clampx(cx_top), t.y - gap - h, true end
        if t.y + t.h + gap + h <= sh - margin then return clampx(cx_bottom), t.y + t.h + gap, false end
    end
    return clampx(cx_top), bottom_y, true
end

-- ==========================================
-- DIBUJO DE BORDES REDONDEADOS
-- ==========================================
local function paintCornerRect(bb, x, y, w, h, r, color, round_tl, round_tr, round_bl, round_br)
    if w <= 0 or h <= 0 then return end
    r = math.min(r, math.floor(w / 2), math.floor(h / 2))
    if r <= 0 then bb:paintRect(x, y, w, h, color); return end
    bb:paintRect(x + r, y, w - 2*r, h, color)
    bb:paintRect(x, y + r, r, math.max(1, h - 2*r), color)
    bb:paintRect(x + w - r, y + r, r, math.max(1, h - 2*r), color)
    if not round_tl then bb:paintRect(x, y, r, r, color) end
    if not round_tr then bb:paintRect(x + w - r, y, r, r, color) end
    if not round_bl then bb:paintRect(x, y + h - r, r, r, color) end
    if not round_br then bb:paintRect(x + w - r,   y + h - r, r, r, color) end
    for j = 0, r - 1 do
        local arc = math.ceil(math.sqrt(r*r - (r-j-0.5)*(r-j-0.5)))
        if arc > 0 then
            if round_tl then bb:paintRect(x + r - arc, y + j, arc, 1, color) end
            if round_tr then bb:paintRect(x + w - r,   y + j, arc, 1, color) end
            if round_bl then bb:paintRect(x + r - arc, y + h - 1 - j, arc, 1, color) end
            if round_br then bb:paintRect(x + w - r,   y + h - 1 - j, arc, 1, color) end
        end
    end
end

-- ==========================================
-- TARJETA DICCIONARIO (ADAPTABLE VERTICAL / HORIZONTAL)
-- ==========================================
local FloatingCard = WidgetContainer:extend({
    anchor_top = false,
    anchor_left = false,
    is_landscape = false,
    radius = scale(15),
    bordersize = math.max(2, scale(2.5)),
    outer_halo = nil,
    content = nil,
})
function FloatingCard:init()
    local c_sz = self.content:getSize()
    local b = self.bordersize
    local halo = self.outer_halo ~= nil and self.outer_halo or math.max(2, scale(3))
    self._halo = halo
    local inset = b + halo
    local pad_top, pad_bot, pad_left, pad_right = 0, 0, 0, 0

    if self.is_landscape then
        self.dimen = Geom:new({ w = c_sz.w + inset, h = Screen:getHeight() })
        if self.anchor_left then pad_right = inset else pad_left = inset end
    else
        self.dimen = Geom:new({ w = c_sz.w, h = c_sz.h + inset })
        if self.anchor_top then pad_bot = inset else pad_top = inset end
    end
    
    self.frame = FrameContainer:new({
        padding_top = pad_top, padding_bottom = pad_bot,
        padding_left = pad_left, padding_right = pad_right,
        bordersize = 0, background = nil,
        self.content
    })
    self[1] = self.frame
end
function FloatingCard:getSize() return self.dimen end
function FloatingCard:paintTo(bb, x, y)
    local w, h = self.dimen.w, self.dimen.h
    local b = self.bordersize
    local halo = self._halo or 0
    local r = self.radius

    if self.is_landscape then
        local round_tl = not self.anchor_left
        local round_tr = self.anchor_left
        local round_bl = not self.anchor_left
        local round_br = self.anchor_left

        if halo > 0 then
            local hy = y - b - halo
            local hh = h + (b + halo) * 2
            paintCornerRect(bb, x, hy, w, hh, r + halo, Blitbuffer.COLOR_WHITE,
                round_tl, round_tr, round_bl, round_br)
        end

        local bk_x = self.anchor_left and x or (x + halo)
        local bk_w = math.max(0, w - halo)
        local by = y - b
        local bh = h + (b * 2)
        paintCornerRect(bb, bk_x, by, bk_w, bh, r, Blitbuffer.COLOR_BLACK,
            round_tl, round_tr, round_bl, round_br)

        local wx = self.anchor_left and x or (x + b + halo)
        local ww = math.max(0, w - b - halo)
        local wr = math.max(0, r - b)
        paintCornerRect(bb, wx, y, ww, h, wr, Blitbuffer.COLOR_WHITE,
            round_tl, round_tr, round_bl, round_br)
    else
        local round_top = not self.anchor_top
        local round_bot = self.anchor_top

        if halo > 0 then
            local hx = x - b - halo
            local hw = w + (b + halo) * 2
            paintCornerRect(bb, hx, y, hw, h, r + halo, Blitbuffer.COLOR_WHITE,
                round_top, round_top, round_bot, round_bot)
        end

        local bk_y = self.anchor_top and y or (y + halo)
        local bk_h = math.max(0, h - halo)
        local bx = x - b
        local bw = w + (b * 2)
        paintCornerRect(bb, bx, bk_y, bw, bk_h, r, Blitbuffer.COLOR_BLACK, 
            round_top, round_top, round_bot, round_bot)
        
        local wy = self.anchor_top and y or (y + b + halo)
        local wh = math.max(0, h - b - halo)
        local wr = math.max(0, r - b)
        paintCornerRect(bb, x, wy, w, wh, wr, Blitbuffer.COLOR_WHITE,
            round_top, round_top, round_bot, round_bot)
    end
        
    if self[1] then self[1]:paintTo(bb, x, y) end
end

-- ==========================================
-- TARJETA MULTI-SELECCIÓN (PÍLDORA FLOTANTE CON BORDE BLANCO EXTERIOR)
-- ==========================================
local FloatingPillCard = WidgetContainer:extend({
    radius = scale(10),
    bordersize = math.max(2, scale(2.2)),
    outer_halo = nil,
    content = nil,
})
function FloatingPillCard:init()
    local c_sz = self.content:getSize()
    local b = self.bordersize
    local halo = self.outer_halo ~= nil and self.outer_halo or math.max(2, scale(3))
    self._halo = halo
    local inset = b + halo
    self.dimen = Geom:new({ w = c_sz.w + (inset * 2), h = c_sz.h + (inset * 2) })
    
    self.frame = FrameContainer:new({
        padding_top = inset,
        padding_bottom = inset,
        padding_left = inset,
        padding_right = inset,
        bordersize = 0,
        background = nil,
        self.content
    })
    self[1] = self.frame
end
function FloatingPillCard:getSize() return self.dimen end
function FloatingPillCard:paintTo(bb, x, y)
    local w, h = self.dimen.w, self.dimen.h
    local b = self.bordersize
    local halo = self._halo or 0
    local r = self.radius

    -- Halo blanco exterior para separar el borde negro del texto de la página
    if halo > 0 then
        paintCornerRect(bb, x, y, w, h, r + halo, Blitbuffer.COLOR_WHITE, true, true, true, true)
    end

    -- Contorno negro principal
    local bx, by = x + halo, y + halo
    local bw, bh = math.max(0, w - halo * 2), math.max(0, h - halo * 2)
    paintCornerRect(bb, bx, by, bw, bh, r, Blitbuffer.COLOR_BLACK, true, true, true, true)
    
    -- Interior blanco puro
    local wr = math.max(0, r - b)
    paintCornerRect(bb, bx + b, by + b, math.max(0, bw - (b * 2)), math.max(0, bh - (b * 2)), wr, Blitbuffer.COLOR_WHITE, true, true, true, true)
        
    if self[1] then self[1]:paintTo(bb, x, y) end
end

-- ==========================================
-- CSS DINÁMICO (TIPOGRAFÍA AJUSTADA)
-- ==========================================
local function getBookFontFamilyName(ui)
    local doc_family
    if ui and ui.font and ui.font.configurable then
        doc_family = ui.font.configurable.font_face
    end
    if not doc_family and ui and ui.font then
        doc_family = ui.font.font_face
    end
    if not doc_family and ui and ui.doc_settings then
        doc_family = ui.doc_settings:readSetting("font_face")
              or ui.doc_settings:readSetting("font_family")
              or ui.doc_settings:readSetting("cre_font_family")
    end
    if not doc_family and G_reader_settings then
        doc_family = G_reader_settings:readSetting("cre_font_family")
              or G_reader_settings:readSetting("font_face")
              or G_reader_settings:readSetting("font_family")
    end
    return doc_family
end

-- Cachea la resolución de archivos de fuente por nombre de familia + archivo
-- del libro. Sin esto, getBookFontPaths llamaba a credoc.engineInit +
-- cre.getFontFaceFilenameAndFaceIndex (hasta 4 veces) en CADA apertura del
-- diccionario -- cada palabra mantenida, cada búsqueda interna. Se incluye el
-- archivo del libro en la clave porque dos EPUBs distintos pueden tener una
-- fuente EMBEBIDA con el mismo nombre genérico mapeando a archivos distintos.
local _font_paths_cache = {}

local function getBookFontPaths(ui)
    local regular = "fonts/noto/NotoSans-Regular.ttf"
    local bold = "fonts/noto/NotoSans-Bold.ttf"
    local italic = "fonts/noto/NotoSans-Italic.ttf"
    local bolditalic = "fonts/noto/NotoSans-BoldItalic.ttf"

    if G_reader_settings then
        local cfont = G_reader_settings:readSetting("cfont")
        if type(cfont) == "string" and cfont ~= "" then
            regular = cfont
            bold = G_reader_settings:readSetting("cfont_b") or cfont
            italic = G_reader_settings:readSetting("cfont_i") or cfont
            bolditalic = G_reader_settings:readSetting("cfont_bi") or cfont
        end
    end

    local doc_family = getBookFontFamilyName(ui)

    if doc_family and doc_family ~= "" then
        local doc_file = (ui and ui.document and ui.document.file) or ""
        local cache_key = doc_family .. "|" .. doc_file
        local cached = _font_paths_cache[cache_key]
        if cached then
            return cached[1], cached[2], cached[3], cached[4]
        end

        local ok, credoc = pcall(require, "document/credocument")
        if ok and credoc and credoc.engineInit then
            local ok2, cre = pcall(credoc.engineInit, credoc)
            if ok2 and cre and cre.getFontFaceFilenameAndFaceIndex then
                local fn_reg = cre.getFontFaceFilenameAndFaceIndex(doc_family, false, false)
                            or cre.getFontFaceFilenameAndFaceIndex(doc_family)
                            or cre.getFontFaceFilenameAndFaceIndex(doc_family, nil, true)
                if fn_reg then
                    regular = fn_reg
                    bold = cre.getFontFaceFilenameAndFaceIndex(doc_family, true, false) or fn_reg
                    italic = cre.getFontFaceFilenameAndFaceIndex(doc_family, false, true) or fn_reg
                    bolditalic = cre.getFontFaceFilenameAndFaceIndex(doc_family, true, true) or bold or fn_reg
                end
            end
        end
        _font_paths_cache[cache_key] = { regular, bold, italic, bolditalic }
    end
    return regular, bold, italic, bolditalic
end

local function getBookRawFontSize(ui)
    local size
    if ui and ui.font and ui.font.configurable then
        size = ui.font.configurable.font_size
    end
    if not size and ui and ui.font and type(ui.font.font_size) == "number" then
        size = ui.font.font_size
    end
    if not size and ui and ui.doc_settings then
        size = ui.doc_settings:readSetting("font_size")
              or ui.doc_settings:readSetting("cre_font_size")
    end
    if not size and G_reader_settings then
        size = G_reader_settings:readSetting("cre_font_size")
              or G_reader_settings:readSetting("font_size")
              or G_reader_settings:readSetting("kopt_font_size")
    end
    return size or 26
end

-- Dictionary text size > Automatic: el texto del diccionario NO depende para nada del tamaño de letra del libro.
-- Igual que Text size > Automatic (ps_font.lua), usa los tamaños de KiKome: el cuerpo de la definición en 17
-- (el 17 de las filas de KiKome, que se escala una sola vez por la densidad de pantalla) y el resto con las
-- mismas diferencias de siempre (palabra +5, píldora -6, meta -1). Para cambiarlo, basta tocar este número.
local DICT_AUTO_BASE = 17

local function isDictAutomatic()
    return G_reader_settings ~= nil
        and G_reader_settings:readSetting("page_scrubber_dict_font_size") == "automatic"
end

-- Tamaño base del texto del diccionario: el del libro, o el fijo de KiKome en modo Automatic
local function getDictBaseFontSize(ui)
    if isDictAutomatic() then return DICT_AUTO_BASE end
    return getBookRawFontSize(ui) or 26
end

local function getDictFontScale()
    if not G_reader_settings then return 1.0 end
    local pref = G_reader_settings:readSetting("page_scrubber_dict_font_size") or "normal"
    if pref == "automatic" then return 1.0 end
    if pref == "very_small" then return 0.70
    elseif pref == "small" then return 0.85
    elseif pref == "large" then return 1.15
    elseif pref == "very_large" then return 1.30
    end
    return 1.0 -- "normal" (la del medio, escala actual 1:1)
end

local function getDictFontSize(ui)
    local base_fs = getDictBaseFontSize(ui)
    local font_scale = getDictFontScale()
    return scale(math.max(8, math.floor(base_fs * font_scale + 0.5)))
end

local function getMetaFontSize(ui)
    local base_fs = getDictBaseFontSize(ui)
    local font_scale = getDictFontScale()
    return scale(math.max(7, math.floor((base_fs - 1) * font_scale + 0.5)))
end

local function getDictLineHeight(ui)
    local pct
    -- 1. Consultar el módulo de fuentes activo en vivo
    if ui and ui.font then
        if ui.font.configurable then
            pct = ui.font.configurable.line_space_percent
               or ui.font.configurable.line_spacing
        end
        if not pct then
            pct = ui.font.line_space_percent
               or ui.font.line_spacing
        end
    end
    -- 2. Consultar ajustes guardados del documento
    if not pct and ui and ui.doc_settings then
        pct = ui.doc_settings:readSetting("line_space_percent")
           or ui.doc_settings:readSetting("line_spacing")
           or ui.doc_settings:readSetting("cre_line_space_percent")
    end
    -- 3. Consultar ajustes globales
    if not pct and G_reader_settings then
        pct = G_reader_settings:readSetting("line_space_percent")
           or G_reader_settings:readSetting("line_spacing")
           or G_reader_settings:readSetting("cre_line_space_percent")
    end

    pct = tonumber(pct) or 100
    if pct > 0 and pct <= 3 then
        pct = pct * 100
    end

    -- Base 1.30em multiplicado por la escala del libro con unidad explícita para CREngine
    local base_em = 1.30
    local calc_em = base_em * (pct / 100)
    return string.format("%.2fem", calc_em)
end

local function getBaseCss(ui)
    local reg, bld, ita, bita = getBookFontPaths(ui)
    local doc_family = getBookFontFamilyName(ui) or "serif"
    local lh = getDictLineHeight(ui)
    local meta_fs = getMetaFontSize(ui)
    return string.format([[
@font-face { font-family: "BookFont"; src: url("%s"); }
@font-face { font-family: "BookFont"; src: url("%s"); font-weight: bold; }
@font-face { font-family: "BookFont"; src: url("%s"); font-style: italic; }
@font-face { font-family: "BookFont"; src: url("%s"); font-weight: bold; font-style: italic; }

* { font-family: "BookFont", "%s", serif !important; }

@page { margin: 0; }
body { margin: 0; padding: 0 0.2em 0 0; line-height: %s; }
p, div, li { line-height: %s !important; margin: 0 0 0.28em 0; }
p:last-child, div:last-child, li:last-child { margin-bottom: 0 !important; }
ol, ul { padding-left: 1.35em; margin-top: 0.18em; margin-bottom: 0.28em; }

.floatingdictionary-word { font-size: 1.20em !important; font-weight: bold !important; line-height: 1.20em !important; color: #000000 !important; }
.floatingdictionary-meta { margin-top: 0.20em; margin-bottom: 0.35em; font-size: %dpx !important; color: #111111 !important; font-style: italic; text-transform: uppercase; line-height: 1.25em !important; }
.search-content, .search-content * { font-size: 1.0em !important; line-height: %s !important; color: #000000 !important; }
.search-content { font-weight: normal !important; }
.search-content b, .search-content strong { font-weight: bold !important; }
]], reg, bld, ita, bita, doc_family, lh, lh, meta_fs, lh)
end

local RealFont = require("ui/font")   -- el Font de KOReader sin el ajuste de Text size > Automatic

-- raw = true: el tamaño ya viene en unidades de KiKome (se escala una sola vez, adentro de Font:getFace),
-- así que no pasa por ps_font. Lo usa Dictionary text size > Automatic.
local function getBookFace(ui, size, bold, raw)
    local F = raw and RealFont or Font
    local reg, bld = getBookFontPaths(ui)
    local font_file = bold and bld or reg
    if font_file and font_file ~= "" then
        local ok, face = pcall(F.getFace, F, font_file, size)
        if ok and face then
            return face
        end
    end
    return F:getFace("cfont", size)
end

-- ==========================================
-- VERIFICADOR DE SVG SEGURO
-- ==========================================
local ok_icon_mgr, IconManager = pcall(require, "icon_manager")   -- reemplazos de íconos del usuario
if not ok_icon_mgr then IconManager = nil end
local ok_selcb, SelCustom = pcall(require, "sel_custom_buttons")   -- botones de otros plugins agregados a la barra
if not ok_selcb then SelCustom = nil end

local function getValidSvgPath(svg_name)
    if not svg_name then return nil end
    -- Cada gsub va entre paréntesis: así devuelve solo el string y no suma el contador a la tabla
    local variants = {
        svg_name,
        (svg_name:gsub("%-", "_")),
        (svg_name:gsub("_", "-"))
    }
    for _, name in ipairs(variants) do
        if IconManager then
            local custom_or_plugin = IconManager.resolvePath(name)
            if custom_or_plugin then return custom_or_plugin end
        end
        local paths = {
            plugin_path .. "icons/" .. name,
            plugin_path .. name,
            "resources/icons/" .. name,
            "resources/icons/svg/" .. name
        }
        for _, p in ipairs(paths) do
            local f = io.open(p, "r")
            if f then
                f:close()
                return p
            end
        end
    end
    return nil
end

-- ==========================================
-- WIDGET BOTÓN REUTILIZABLE
-- ==========================================
local PreviewButton = InputContainer:extend({
    icon_svg = nil, icon_char = nil, text = nil, font_size = nil, width = nil, height = nil, callback = nil, show_parent = nil, always_show_text = false, icon_size = nil, face = nil, bold = nil,
    bg_color = nil, radius = nil, text_pad = nil,   -- relleno redondeado (chips / fichas de íconos)
    horizontal = false, icon_gap = nil,
})
function PreviewButton:init()
    local inner_h = self.height or scale(48)
    local content_elements = {}

    local icon_widget = nil
    if self.icon_svg then
        local icon_sz = self.icon_size or scale(24)
        local ok, widget = pcall(function()
            return ImageWidget:new{
                file = self.icon_svg,
                width = icon_sz,
                height = icon_sz,
                alpha = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
                original_in_nightmode = false,
                file_do_cache = false,
            }
        end)
        if ok and widget then
            icon_widget = widget
        end
    end

    if not icon_widget and self.icon_char then
        icon_widget = TextWidget:new{
            text = self.icon_char,
            face = self.face or Font:getFace("cfont", self.font_size or scaleText(14)),
            fgcolor = Blitbuffer.COLOR_BLACK
        }
    end

    local icon_w = 0
    if icon_widget then
        table.insert(content_elements, icon_widget)
        icon_w = icon_widget:getSize().w
    end

    if self.text and (not icon_widget or self.always_show_text) then
        local gap_w = self.icon_gap or scale(6)
        if icon_widget then
            if self.horizontal then
                table.insert(content_elements, HorizontalSpan:new({ width = gap_w }))
            else
                table.insert(content_elements, VerticalSpan:new({ width = scale(1) }))
            end
        end
        local max_tw
        if self.width then
            if self.horizontal and icon_widget then
                max_tw = math.max(scale(16), self.width - icon_w - gap_w - (self.text_pad or scale(10)))
            else
                max_tw = self.width - (self.text_pad or scale(4))
            end
        end
        self._text_widget = TextWidget:new({
            text = self.text, 
            face = self.face or Font:getFace("cfont", self.font_size or scaleText(12)), 
            bold = (self.bold ~= nil) and self.bold or (self.face == nil), 
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = max_tw,
            truncate_with_ellipsis = true
        })
        table.insert(content_elements, self._text_widget)
    end
    
    if #content_elements == 0 then
        self._text_widget = TextWidget:new({
            text = "?", 
            face = Font:getFace("cfont", self.font_size or scaleText(8)), 
            fgcolor = Blitbuffer.COLOR_BLACK
        })
        table.insert(content_elements, self._text_widget)
    end

    local btn_content = CenterContainer:new({ 
        dimen = Geom:new({ w = self.width, h = inner_h })
    })
    if self.horizontal then
        content_elements.align = "center"
        btn_content[1] = HorizontalGroup:new(content_elements)
    else
        btn_content[1] = VerticalGroup:new(content_elements)
    end
    self._content_group = btn_content[1]
    
    -- Con relleno (chips / fichas) el marco no suma padding: si no, el alto queda mayor que el ancho y la ficha
    -- sale angosta en vez de cuadrada. Sin relleno se mantiene el padding vertical de siempre.
    self.frame = FrameContainer:new({ show_parent = self.show_parent, bordersize = 0, padding = self.bg_color and 0 or nil, padding_left = 0, padding_right = 0 })
        self.frame[1] = btn_content
        self.dimen = self.frame:getSize()
        self[1] = self.frame
        self.ges_events = { 
            TapSelectButton = { GestureRange:new({ ges = "tap", range = self.dimen }) },
            HoldSelectButton = { GestureRange:new({ ges = "hold", range = self.dimen }) },
            -- El dedo puede haberse corrido del botón al soltar: el release se escucha en toda la pantalla
            HoldReleaseSelectButton = { GestureRange:new({
                ges = "hold_release",
                range = Geom:new({ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }),
            }) },
        }
    end

function PreviewButton:onHoldSelectButton(arg1, ges)
    if not self.hold_callback then return false end
    -- La acción salta apenas se detecta el hold. El menú flotante NO se cierra acá (se cierra al elegir
    -- un color o al cancelar), así el hold_release lo sigue recibiendo este botón y no llega al lector.
    self._hold_active = true
    local anchor_pos = ges and ges.pos
    local UIManager = require("ui/uimanager")
    -- Aislar la acción del hilo de gestos táctiles para evitar bloqueos
    UIManager:scheduleIn(0, function()
        if self.hold_callback then self.hold_callback(self, anchor_pos) end
    end)
    return true
end

    function PreviewButton:onHoldReleaseSelectButton()
        if not self._hold_active then return false end
        self._hold_active = false
        -- Consumir la liberación del dedo para que no llegue al lector de KOReader
        return true
    end

function PreviewButton:onTapSelectButton()
    if self.callback then self.callback(); return true end
    return false
end

-- Relleno redondeado detrás del contenido (solo si el botón trae bg_color)
function PreviewButton:paintTo(bb, x, y)
    if self.bg_color and self.dimen then
        paintCornerRect(bb, x, y, self.dimen.w, self.dimen.h, self.radius or 0, self.bg_color, true, true, true, true)
    end
    InputContainer.paintTo(self, bb, x, y)
end

-- Los plugins externos (p. ej. Vocabulary builder: "Add to vocabulary" <-> "Remove word") cambian el texto
-- de su botón con button:setText(); sin este método el cambio fallaba y el botón nunca se actualizaba.
function PreviewButton:setText(text)
    if type(text) ~= "string" or text == self.text then return end
    self.text = text
    local group, old = self._content_group, self._text_widget
    if not (group and old) then return end
    local new_tw = TextWidget:new({
        text = text,
        face = old.face,
        bold = old.bold,
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = old.max_width,
        truncate_with_ellipsis = true,
    })
    for i, w in ipairs(group) do
        if w == old then
            group[i] = new_tw
            break
        end
    end
    pcall(function() old:free() end)
    self._text_widget = new_tw
    if group.resetLayout then group:resetLayout() end
    UIManager:setDirty(self.show_parent or "all", function() return "ui", self.dimen end)
end

-- ==========================================
-- HACK DE CURSOR REDONDEADO
-- ==========================================
local function applyRoundedScrollbar(htmlwidget)
    local original_paintTo = htmlwidget.paintTo
    htmlwidget.paintTo = function(self, bb, x, y)
        local sb = self.scrollbar
        self.scrollbar = nil 
        original_paintTo(self, bb, x, y)
        self.scrollbar = sb
        
        if sb and self.virtual_dimen and self.virtual_dimen.h > self.dimen.h then
            local max_h = self.dimen.h
            local max_v = self.virtual_dimen.h
            local thumb_h = math.max(scale(24), math.floor(max_h * max_h / max_v))
            local thumb_y = y + math.floor((self.pos / max_v) * max_h)
            if thumb_y + thumb_h > y + max_h then thumb_y = y + max_h - thumb_h end
            
            local sw = scale(6)
            local sx = x + self.dimen.w - sw - scale(2)
            paintCornerRect(bb, sx, thumb_y, sw, thumb_h, math.floor(sw/2), Blitbuffer.COLOR_GRAY, true, true, true, true)
        end
    end
end

-- ==========================================
-- LÓGICA DE PLUGINS EXTERNOS (SOLO DICCIONARIO)
-- ==========================================
function FloatingDict:discoverExternalButtons(dict_self, word, result, result_index, results, boxes, link, popup_instance)
    local all_buttons = {}
    if not (self.ui and self.ui.handleEvent) then return {} end

    result = result or {}
    
    local active_highlight = (popup_instance and popup_instance.highlight_obj)
        or (dict_self and dict_self.highlight)
        or (self.ui and self.ui.highlight)

    local active_selected_text = (active_highlight and active_highlight.selected_text)
        or { text = word, pos0 = nil, pos1 = nil }

    if active_highlight and not active_highlight.selected_text then
        active_highlight.selected_text = active_selected_text
    end

    local clean_w = (type(cleanWordForLookup) == "function" and cleanWordForLookup(word)) or word

    local fake_popup = {
        ui = self.ui,
        dialog = popup_instance or (dict_self and dict_self.dialog),
        dimen = Geom:new({x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight()}),
        highlight = active_highlight,
        selected_text = active_selected_text,
        text = word,
        word = clean_w,   -- como el popup nativo: la palabra consultada, sin puntuación alrededor
        clean_text = clean_w,
        clean_word = clean_w,
        lookupword = result.word or word,
        results = results,
        boxes = boxes,
        word_boxes = boxes,
        selected_link = link,
        is_wiki = false,
        dict_index = result_index or 1,
        dictionary = result.dict,
        lang = result.lang,
        close = function()
            if popup_instance then UIManager:close(popup_instance) end
        end,
        onClose = function()
            if popup_instance then UIManager:close(popup_instance) end
        end,
        closeWidget = function()
            if popup_instance then UIManager:close(popup_instance) end
        end,
        updateButtons = function() end,
    }

    if popup_instance then
        setmetatable(fake_popup, { __index = popup_instance })
    end

    local fake_button_table = { 
        getButtonById = function(self_tbl, id)
            local real_btn = fake_popup._real_buttons and fake_popup._real_buttons[id]
            return { 
                width = real_btn and real_btn.width or scale(100),
                dimen = real_btn and real_btn.dimen or Geom:new({w = scale(100), h = scale(40)}),
                setText = function(self_btn, text)
                    -- se resuelve el botón real recién ahora (puede haberse registrado después de pedir el id)
                    -- y se protege con pcall: este callback puede correr dentro de un cartel de confirmación
                    -- sin pcall, y un error ahí tira abajo KOReader
                    local rb = (fake_popup._real_buttons and fake_popup._real_buttons[id]) or real_btn
                    if rb and type(rb.setText) == "function" then
                        pcall(rb.setText, rb, text)
                    end
                end, 
                refresh = function() end, 
                enable = function() end, 
                disable = function() end 
            } 
        end 
    }

    fake_button_table.button_by_id = setmetatable({}, {
        __index = function(t, id)
            return fake_button_table:getButtonById(id)
        end
    })

    fake_popup.button_table = fake_button_table

    local seen_ids = {}

    local function extract_btn_text(s)
        local t = s.text or s.menu_text or "?"
        if type(s.text_func) == "function" then
            local ok, res = pcall(s.text_func, fake_popup)
            if ok and res then t = res end
        end
        return t
    end

    local function scan_for_buttons(tbl)
        if type(tbl) ~= "table" then return end
        for k, v in pairs(tbl) do
            if type(v) == "table" then
                if v.id and type(v.callback) == "function" then
                    modern_plugin_buttons_shared[v.id] = v
                elseif type(k) == "number" or type(k) == "string" then
                    for sub_k, sub_v in pairs(v) do
                        if type(sub_v) == "table" and sub_v.id and type(sub_v.callback) == "function" then
                            modern_plugin_buttons_shared[sub_v.id] = sub_v
                        end
                    end
                end
            end
        end
    end
    
    if dict_self then
        harvestExistingDictButtons(dict_self)
        scan_for_buttons(dict_self.dict_plugin_buttons)
        scan_for_buttons(dict_self.dict_buttons_by_id)
        scan_for_buttons(dict_self.dict_buttons)
        scan_for_buttons(dict_self.registered_buttons)
    end

    for id, spec in pairs(modern_plugin_buttons_shared) do
        local should_show = true
        if type(spec.show_func) == "function" then
            local ok_show, res = pcall(spec.show_func, fake_popup)
            should_show = ok_show and res
        end

        if should_show and type(spec.callback) == "function" and not seen_ids[spec.id] then
            table.insert(all_buttons, {
                id = spec.id,
                text = extract_btn_text(spec),
                callback = function() return spec.callback(fake_popup) end,
                fake_popup = fake_popup,
                row_group = spec.row_group
            })
            seen_ids[spec.id] = true
        end
    end

    local legacy_rows = {
        { { id = "dummy1" } },
        { { id = "dummy2" } }
    }
    seen_ids["dummy1"] = true
    seen_ids["dummy2"] = true

    local original_add_to_dict = nil
    if self.ui and self.ui.dictionary then
        original_add_to_dict = self.ui.dictionary.addToDictButtons
        self.ui.dictionary.addToDictButtons = nil
    end

    pcall(function()
        self.ui:handleEvent(Event:new("DictButtonsReady", fake_popup, legacy_rows))
    end)

    if self.ui and self.ui.dictionary then
        self.ui.dictionary.addToDictButtons = original_add_to_dict
    end

    local legacy_group_counter = 1
    for _, item in ipairs(legacy_rows) do
        if type(item) == "table" then
            if type(item.callback) == "function" then
                if not seen_ids[item.id] then
                    table.insert(all_buttons, {
                        id = item.id,
                        text = extract_btn_text(item),
                        callback = function() return item.callback(fake_popup) end,
                        fake_popup = fake_popup,
                        row_group = item.row_group
                    })
                    seen_ids[item.id] = true
                end
            else
                local auto_group = "legacy_row_" .. legacy_group_counter
                legacy_group_counter = legacy_group_counter + 1
                
                for _, spec in ipairs(item) do
                    if type(spec) == "table" and type(spec.callback) == "function" and not seen_ids[spec.id] then
                        table.insert(all_buttons, {
                            id = spec.id,
                            text = extract_btn_text(spec),
                            callback = function() return spec.callback(fake_popup) end,
                            fake_popup = fake_popup,
                            row_group = spec.row_group or auto_group
                        })
                        seen_ids[spec.id] = true
                    end
                end
            end
        end
    end

    local grouped_rows_map = {}
    for _, btn in ipairs(all_buttons) do
        local group_name = btn.row_group
        if not group_name and btn.id then
            group_name = btn.id:match("^([a-zA-Z0-9]+)_") or btn.id
        end
        group_name = group_name or "ungrouped"
        
        grouped_rows_map[group_name] = grouped_rows_map[group_name] or {}
        table.insert(grouped_rows_map[group_name], btn)
    end

    local sorted_group_names = {}
    for grp in pairs(grouped_rows_map) do table.insert(sorted_group_names, grp) end
    
    table.sort(sorted_group_names, function(a, b)
        local len_a = #grouped_rows_map[a]
        local len_b = #grouped_rows_map[b]
        if len_a == len_b then
            return a < b
        end
        return len_a < len_b
    end)

    local final_rows = {}
    for _, grp in ipairs(sorted_group_names) do
        table.insert(final_rows, grouped_rows_map[grp])
    end

    return final_rows
end

-- ==========================================
-- MEDICIÓN DE ALTURA HTML (SHRINK-TO-FIT)
-- ==========================================
local function getHtmlContentHeight(widget)
    if not widget then return nil end
    if type(widget.getSinglePageHeight) == "function" then
        local ok, h = pcall(widget.getSinglePageHeight, widget)
        if ok and type(h) == "number" and h > 0 then return h end
    end
    if widget.htmlbox_widget and type(widget.htmlbox_widget.getSinglePageHeight) == "function" then
        local ok, h = pcall(widget.htmlbox_widget.getSinglePageHeight, widget.htmlbox_widget)
        if ok and type(h) == "number" and h > 0 then return h end
    end
    return nil
end

local function estimateHtmlContentHeight(content_width, html_body, font_size)
    if not html_body or html_body == "" or not content_width or content_width <= 0 then
        return nil
    end

    local text = tostring(html_body)
    text = text:gsub("<%s*br%s*/?%s*>", "\n")
    text = text:gsub("<%s*/?%s*p[^>]*>", "\n")
    text = text:gsub("<%s*/?%s*div[^>]*>", "\n")
    text = text:gsub("<%s*/?%s*li[^>]*>", "\n")
    text = text:gsub("<%s*/?%s*h[1-6][^>]*>", "\n")
    text = text:gsub("<[^>]+>", "")
    text = text:gsub("&nbsp;", " ")
    text = text:gsub("&amp;", "&")
    text = text:gsub("&lt;", "<")
    text = text:gsub("&gt;", ">")
    text = text:gsub("&quot;", '"')
    text = text:gsub("&#39;", "'")
    text = text:gsub("^%s*\n+", "")
    text = text:gsub("\n+%s*$", "")

    font_size = font_size or scale(18)
    local avg_char_width = font_size * 0.60
    local chars_per_line = math.max(1, math.floor(content_width / avg_char_width))
    local line_height = font_size * 1.30

    local total_lines = 0
    local saw_content = false
    local prev_blank = false
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed == "" then
            if saw_content and not prev_blank then
                total_lines = total_lines + 1
                prev_blank = true
            end
        else
            local wrapped = math.max(1, math.ceil(#trimmed / chars_per_line))
            total_lines = total_lines + wrapped
            saw_content = true
            prev_blank = false
        end
    end

    if not saw_content or total_lines <= 0 then
        return nil
    end

    return math.ceil(total_lines * line_height) + scale(8)
end

-- ==========================================
-- ELEMENTOS VISUALES DE LA HOJA DEL DICCIONARIO
-- ==========================================
local SheetGrabber = WidgetContainer:extend({
    width = nil,
    pill_w = nil,
    pill_h = nil,
})
function SheetGrabber:init()
    self.pill_w = self.pill_w or scale(36)
    self.pill_h = self.pill_h or math.max(2, scale(3))
    self.dimen = Geom:new({ w = self.width or self.pill_w, h = self.pill_h })
end
function SheetGrabber:getSize() return self.dimen end
function SheetGrabber:paintTo(bb, x, y)
    local px = x + math.floor((self.dimen.w - self.pill_w) / 2)
    local r = math.floor(self.pill_h / 2)
    paintCornerRect(bb, px, y, self.pill_w, self.pill_h, r, Blitbuffer.COLOR_BLACK, true, true, true, true)
end

local DictBadgePill = InputContainer:extend({
    text = "",
    face = nil,
    max_width = nil,
    callback = nil,
    show_parent = nil,
})
function DictBadgePill:init()
    local pad_x = scale(8)
    local pad_y = scale(2)
    local b = math.max(1, scale(1))
    local max_tw = self.max_width and math.max(scale(16), self.max_width - (pad_x + b) * 2) or nil
    self.tw = TextWidget:new({
        text = self.text,
        face = self.face,
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = max_tw,
        truncate_with_ellipsis = true,
    })
    local tsz = self.tw:getSize()
    local w = tsz.w + (pad_x + b) * 2
    local h = tsz.h + (pad_y + b) * 2
    self.dimen = Geom:new({ w = w, h = h })
    self._pad_x = pad_x + b
    self._pad_y = pad_y + b
    self._b = b
    if self.callback and Device:isTouchDevice() then
        self.ges_events = {
            TapBadge = { GestureRange:new({ ges = "tap", range = self.dimen }) },
        }
    end
end
function DictBadgePill:getSize() return self.dimen end
function DictBadgePill:onTapBadge()
    if self.callback then self.callback(); return true end
    return false
end
function DictBadgePill:paintTo(bb, x, y)
    local w, h = self.dimen.w, self.dimen.h
    local r = math.floor(h / 2)
    local pill_bg = Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_LIGHT_GRAY
    paintCornerRect(bb, x, y, w, h, r, pill_bg, true, true, true, true)
    self.tw:paintTo(bb, x + self._pad_x, y + self._pad_y)
end
function DictBadgePill:free()
    if self.tw and self.tw.free then self.tw:free() end
end

-- ==========================================
-- TARJETA: PALABRA ÚNICA (DICCIONARIO ORIGINAL)
-- ==========================================
local FloatingDictionaryPopup = InputContainer:extend({
    text = nil, results = nil, boxes = nil, anchor_top = false, anchor_left = false, is_landscape = false,
    highlight_obj = nil, plugin = nil, current_result_idx = 1,
})
-- Al tocar una acción, el popup se cierra ANTES de ejecutarla, y al cerrarse borra la
-- selección de texto (highlight.selected_text = nil). Corremos fn con la selección que
-- el popup guardó al abrirse, y después la volvemos a limpiar.
function FloatingDictionaryPopup.withRestoredSelection(self_obj, fn)
    local hl = self_obj.highlight_obj
    local restored = false
    if hl and not hl.selected_text and self_obj.selected_text then
        hl.selected_text = self_obj.selected_text
        restored = true
    end
    local ok, err = pcall(fn)
    if restored and hl.selected_text == self_obj.selected_text then
        hl.selected_text = nil
    end
    return ok, err
end

function FloatingDictionaryPopup:init()
    self.dialog = self.dialog or self
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()
    self.is_landscape = (screen_width > screen_height)

    self.width = self.is_landscape and math.floor(screen_width * 0.48) or screen_width
    local content_w = self.is_landscape and (self.width - scale(3)) or self.width
    local side_pad = scale(28)

    self.current_result_idx = self.current_result_idx or 1
    local total_dicts = self.results and #self.results or 1
    local entry = self.results and self.results[self.current_result_idx] or {}
    
    local dict_name = tostring(entry.dict or "Diccionario")
    local def_body = tostring(entry.definition or "<p>Sin definición.</p>")
    if not def_body:find("<") then def_body = "<p>" .. htmlEscape(def_body):gsub("\n", "<br/>") .. "</p>" end

    local html_body = string.format([[
        <div class="search-content">%s</div>
    ]], def_body)

    local ui_instance = self.plugin and self.plugin.ui
    local icon_btn_specs = {}

    local external_rows = {}
    
    self.word = self.text
    self.clean_text = cleanWordForLookup(self.text) or self.text
    self.clean_word = self.clean_text
    self.highlight = self.highlight_obj
    self.selected_text = (self.highlight_obj and self.highlight_obj.selected_text) or { text = self.text }

    -- Cursores de selección: solo con una selección nueva hecha con el dedo (no con una palabra tocada
    -- dentro de otra tarjeta, que ya no tiene selección en el libro)
    do
        local cursor = self.plugin and self.plugin.cursor
        local hl_obj = self.highlight_obj
        if cursor and hl_obj and hl_obj.hold_pos and type(hl_obj.selected_text) == "table"
                and cursor:isEnabled() then
            self._cursor = cursor
        end
    end

    -- 1. Descubrir X-Ray si el plugin externo está presente
    local dict_xray_spec = nil
    local other_external_rows = {}

    if self.plugin and type(self.plugin.discoverExternalButtons) == "function" then
        local plugin_rows = self.plugin:discoverExternalButtons(self.plugin.patched_dictionary, self.text, entry, self.current_result_idx, self.results, self.boxes, nil, self)
        for _, row in ipairs(plugin_rows) do
            local current_text_row = {}
            for _, ext in ipairs(row) do
                local id_lower = (ext.id or ""):lower()
                local txt_lower = (ext.text or ""):lower()
                local is_xray = id_lower:find("xray") or id_lower:find("x%-ray") or txt_lower:find("xray") or txt_lower:find("x%-ray")

                if is_xray then
                    local assigned_svg = getValidSvgPath("xray.svg")
                    dict_xray_spec = {
                        id = ext.id,
                        icon_svg = assigned_svg,
                        text = not assigned_svg and "X-Ray" or nil,
                        external_callback = ext.callback,
                        fake_popup = ext.fake_popup,
                    }
                else
                    table.insert(current_text_row, {
                        id = ext.id,
                        icon_svg = nil,
                        text = ext.text or "Plug-in",
                        font_size = scaleText(12),
                        external_callback = ext.callback,
                        fake_popup = ext.fake_popup,
                    })
                end
            end
            if #current_text_row > 0 then
                table.insert(other_external_rows, current_text_row)
            end
        end
    end

    -- 2. Construir los botones superiores del diccionario en el orden configurado
    local DICT_BUTTON_SPECS = {
        wiki      = { svg = "globe.svg", text = "Wiki", action = "wiki", setting = "page_scrubber_fdict_show_wiki" },
        translate = { svg = "languages.svg", text = "Translate", action = "translate", setting = "page_scrubber_fdict_show_translate" },
        ai        = { svg = "sparkles.svg", text = "AI", action = "ai", setting = "page_scrubber_fdict_show_ai" },
        highlight = { svg = "highlighter.svg", text = "Highlight", action = "highlight", setting = "page_scrubber_fdict_show_highlight" },
        search    = { svg = "search.svg", text = "Search", action = "search", setting = "page_scrubber_fdict_show_search" },
    }
    local default_btn_order = { "xray", "wiki", "translate", "ai", "highlight", "search" }
    local saved_btn_order = G_reader_settings and G_reader_settings:readSetting("page_scrubber_fdict_btn_order")
    if type(saved_btn_order) ~= "table" then
        saved_btn_order = default_btn_order
    else
        local seen = {}
        for _, k in ipairs(saved_btn_order) do seen[k] = true end
        for _, k in ipairs(default_btn_order) do
            if not seen[k] then table.insert(saved_btn_order, k) end
        end
    end

    for _, btn_key in ipairs(saved_btn_order) do
        if btn_key == "xray" then
            if dict_xray_spec and is_btn_enabled("page_scrubber_fdict_show_xray") then
                table.insert(icon_btn_specs, dict_xray_spec)
            end
        else
            local b_spec = DICT_BUTTON_SPECS[btn_key]
            if b_spec and is_btn_enabled(b_spec.setting) then
                local path = getValidSvgPath(b_spec.svg)
                if not path and b_spec.action == "ai" then
                    path = getValidSvgPath("ai.svg") or getValidSvgPath("bot.svg")
                end
                if path then
                    table.insert(icon_btn_specs, { icon_svg = path, text = nil, action = b_spec.action })
                else
                    table.insert(icon_btn_specs, { icon_svg = nil, text = b_spec.text, font_size = scaleText(12), action = b_spec.action })
                end
            end
        end
    end

    if is_btn_enabled("page_scrubber_fdict_show_plugins") then
        external_rows = other_external_rows
    end

    local raw_fs = getBookRawFontSize(ui_instance) or 26
    local font_ratio = math.max(0.85, math.min(1.40, raw_fs / 26))
    local dynamic_icon_sz = scale(22)
    local ext_row_h = scale(32)

    -- Íconos: fichas cuadradas con relleno gris claro y esquinas redondeadas (mismo gris que la píldora del
    -- diccionario). Tamaño fijo, alineadas a la izquierda con el mismo borde que los chips; no hay rayitas.
    local tile_bg = Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_LIGHT_GRAY
    local tile_r = scale(10)
    local n_icons = #icon_btn_specs
    local icon_tile = scale(44)
    local icon_gap = scale(10)
    local icon_lead = side_pad
    if n_icons > 0 then
        local row_w = content_w - side_pad * 2
        icon_tile = math.min(scale(44), math.floor((row_w - (n_icons - 1) * icon_gap) / n_icons))
    end
    local icon_btn_h = icon_tile

    local icon_widgets = {}
    if n_icons > 0 then
        table.insert(icon_widgets, HorizontalSpan:new({ width = icon_lead }))
        for idx, spec in ipairs(icon_btn_specs) do
            local btn = PreviewButton:new({
                icon_svg = spec.icon_svg,
                icon_size = dynamic_icon_sz,
                text = spec.text,
                font_size = spec.font_size,
                face = not spec.icon_svg and getBookFace(ui_instance, spec.font_size or scaleText(12), true) or nil,
                width = icon_tile, 
                height = icon_tile, 
                bg_color = tile_bg,
                radius = tile_r,
                always_show_text = false,
                show_parent = self,
                callback = function()
                    if spec.external_callback then
                        UIManager:close(self)
                        pcall(spec.external_callback)
                    else
                        self:invokeNative(spec.action)
                    end
                end
            })
            
            if spec.fake_popup and spec.id then
                spec.fake_popup._real_buttons = spec.fake_popup._real_buttons or {}
                spec.fake_popup._real_buttons[spec.id] = btn
            end
            
            table.insert(icon_widgets, btn)
            if idx < n_icons and icon_gap > 0 then
                table.insert(icon_widgets, HorizontalSpan:new({ width = icon_gap }))
            end
        end
        -- Relleno a la derecha hasta el ancho total: el VerticalGroup centra a cada hijo, así que una fila más
        -- angosta que el popup se corría al centro. Con el ancho completo (como las filas de chips) queda a la izquierda.
        local used_w = icon_lead + n_icons * icon_tile + (n_icons - 1) * icon_gap
        if content_w > used_w then
            table.insert(icon_widgets, HorizontalSpan:new({ width = content_w - used_w }))
        end
    end

    local text_row_widgets = {}
    if #external_rows > 0 then
        -- Agrupa plugins de a 2 por fila (2 columnas) en ambas orientaciones
        local flat = {}
        for _, r in ipairs(external_rows) do
            for _, spec in ipairs(r) do
                table.insert(flat, spec)
            end
        end
        local rows_to_render = {}
        for i = 1, #flat, 2 do
            local pair = { flat[i] }
            if flat[i + 1] then
                table.insert(pair, flat[i + 1])
            end
            table.insert(rows_to_render, pair)
        end

        -- Chips: relleno gris claro redondeado, y el MISMO tamaño de letra en todos: el más grande que
        -- entra en el chip más ajustado (si ni así entra, se corta con "…")
        local chip_bg = Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_LIGHT_GRAY
        local chip_r = scale(10)
        local chip_gap = scale(6)
        local chip_text_pad = scale(16)
        local min_allowed_fs = scaleText(10)
        local uniform_base_fs = scaleText(14)
        for _, r in ipairs(rows_to_render) do
            if #r >= 2 then uniform_base_fs = scaleText(13); break end
        end
        local uniform_fs = uniform_base_fs
        for _, txt_row in ipairs(rows_to_render) do
            local cnt = #txt_row
            local gx = (cnt > 1) and chip_gap or 0
            local bw = math.floor((content_w - side_pad * 2 - (cnt - 1) * gx) / cnt)
            local max_tw = bw - chip_text_pad
            for _, spec in ipairs(txt_row) do
                local fit = min_allowed_fs
                for test_fs = uniform_base_fs, min_allowed_fs, -1 do
                    local test_face = getBookFace(ui_instance, test_fs, false)
                    local tw = TextWidget:new({ text = spec.text or "Plug-in", face = test_face })
                    local needed_w = tw:getSize().w
                    tw:free()
                    if needed_w <= max_tw then
                        fit = test_fs
                        break
                    end
                end
                if fit < uniform_fs then uniform_fs = fit end
            end
        end

        for _, txt_row in ipairs(rows_to_render) do
            local row_widgets = {}
            local count = #txt_row
            local pad_x = side_pad
            local gap_x = (count > 1) and chip_gap or 0
            local avail_w = content_w - (pad_x * 2) - ((count - 1) * gap_x)
            local btn_w = math.floor(avail_w / count)

            if pad_x > 0 then
                table.insert(row_widgets, HorizontalSpan:new({ width = pad_x }))
            end

            for i, spec in ipairs(txt_row) do
                local btn_text = spec.text or "Plug-in"
                local chosen_fs = uniform_fs

                local plugin_face = getBookFace(ui_instance, chosen_fs, false)

                local btn = PreviewButton:new({
                    icon_svg = nil,
                    text = btn_text,
                    face = plugin_face,
                    font_size = chosen_fs,
                    width = btn_w, 
                    height = ext_row_h, 
                    bg_color = chip_bg,
                    radius = chip_r,
                    text_pad = chip_text_pad,
                    always_show_text = true,
                    show_parent = self,
                    callback = function()
                        local id_lower = (spec.id or ""):lower()
                        local text_lower = (spec.text or ""):lower()
                        local is_vocab = id_lower:find("vocab") or text_lower:find("vocab")

                        if is_vocab then
                            -- Toggle en vivo: agrega/elimina la palabra y actualiza el texto sin cerrar el popup
                            pcall(spec.external_callback)
                        else
                            -- Plugins de reproducción/acción (TTS, audiolibros, etc.): ejecutan y cierran el panel
                            UIManager:close(self)
                            -- el cierre del popup borró la selección: se la restauramos al plugin
                            self:withRestoredSelection(spec.external_callback)
                        end
                    end
                })

                if spec.fake_popup then
                    spec.fake_popup._real_buttons = spec.fake_popup._real_buttons or {}
                    if spec.id then
                        spec.fake_popup._real_buttons[spec.id] = btn
                    end
                    local t_lower = (spec.text or ""):lower()
                    if t_lower:find("vocab") then
                        spec.fake_popup._real_buttons["vocab_toggle"] = btn
                        spec.fake_popup._real_buttons["vocabulary_builder"] = btn
                        spec.fake_popup._real_buttons["vocab"] = btn
                    end
                end

                table.insert(row_widgets, btn)
                if i < count and gap_x > 0 then
                    table.insert(row_widgets, HorizontalSpan:new({ width = gap_x }))
                end
            end

            if pad_x > 0 then
                table.insert(row_widgets, HorizontalSpan:new({ width = pad_x }))
            end

            table.insert(text_row_widgets, HorizontalGroup:new(row_widgets))
        end
    end
    
    local show_grabber = not self.is_landscape
    local grabber_h = math.max(2, scale(3))
    local grabber_gap_outer = scale(9)
    local grabber_gap_inner = scale(9)

    local top_pad, bot_pad
    if self.is_landscape then
        top_pad = scale(20)
        bot_pad = scale(14)
    elseif self.anchor_top then
        top_pad = scale(24)
        bot_pad = grabber_gap_inner + grabber_h + grabber_gap_outer
    else
        top_pad = grabber_gap_outer + grabber_h + grabber_gap_inner
        bot_pad = scale(10)
    end

    -- Cabecera fija: fila 1 (palabra + botón manual) y fila 2 (píldora del diccionario debajo)
    local title_avail_w = content_w - (side_pad * 2)
    local edit_btn_sz = scale(28)
    local right_gap = scale(6)

    local dict_auto = isDictAutomatic()
    local base_fs = getDictBaseFontSize(ui_instance)
    local word_fs = math.max(11, math.floor((base_fs + 5) * getDictFontScale() + 0.5))
    -- Automatic: tamaño de KiKome, escalado una sola vez por Font:getFace (solo con el zoom del popup)
    if dict_auto then
        word_fs = math.max(11, math.floor(word_fs * getScale() + 0.5))
    else
        word_fs = scale(word_fs)
    end
    local word_face = getBookFace(ui_instance, word_fs, true, dict_auto)
    local raw_display_word = tostring(entry.word or self.text or ""):gsub("\n", " ")

    local word_max_w = math.max(scale(80), title_avail_w - right_gap - edit_btn_sz)
    self.word_widget = TextWidget:new({
        text = raw_display_word,
        face = word_face,
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = word_max_w,
        truncate_with_ellipsis = true,
    })

    local actual_word_w = self.word_widget:getSize().w
    local badge_label = (total_dicts > 1)
        and string.format("%d/%d · %s", self.current_result_idx, total_dicts, dict_name)
        or dict_name
    local badge_fs = math.max(9, math.floor((base_fs - 6) * getDictFontScale() + 0.5))
    if dict_auto then
        badge_fs = math.max(9, math.floor(badge_fs * getScale() + 0.5))
    else
        badge_fs = scale(badge_fs)
    end
    local badge_face = getBookFace(ui_instance, badge_fs, true, dict_auto)

    local dict_badge = DictBadgePill:new({
        text = badge_label,
        face = badge_face,
        max_width = title_avail_w,
        show_parent = self,
        callback = (total_dicts > 1) and function()
            local next_idx = (self.current_result_idx % total_dicts) + 1
            self:switchDict(next_idx)
        end or nil,
    })
    local actual_badge_w = dict_badge:getSize().w

    local more_svg = getValidSvgPath("more.svg")

    local edit_btn = PreviewButton:new({
        icon_svg = more_svg,
        icon_char = not more_svg and "..." or nil,
        icon_size = scale(22),
        font_size = scaleText(14),
        width = edit_btn_sz,
        height = edit_btn_sz,
        show_parent = self,
        callback = function()
            local clean_w = (type(cleanWordForLookup) == "function" and cleanWordForLookup(self.text)) or self.text
            local ui = self.plugin and self.plugin.ui
            local dict = (ui and ui.dictionary) or (self.plugin and self.plugin.patched_dictionary)

            UIManager:close(self)

            UIManager:scheduleIn(0.05, function()
                if dict and type(dict.onShowDictionaryLookup) == "function" then
                    dict:onShowDictionaryLookup(clean_w)
                elseif ui and type(ui.handleEvent) == "function" then
                    ui:handleEvent(Event:new("ShowDictionaryLookup", clean_w))
                end
            end)
        end
    })

    local spacer_w = math.max(right_gap, title_avail_w - actual_word_w - edit_btn_sz)
    self.title_row = HorizontalGroup:new({
        align = "center",
        HorizontalSpan:new({ width = side_pad }),
        self.word_widget,
        HorizontalSpan:new({ width = spacer_w }),
        edit_btn,
        HorizontalSpan:new({ width = side_pad }),
    })

    self.badge_row = HorizontalGroup:new({
        align = "center",
        HorizontalSpan:new({ width = side_pad }),
        dict_badge,
        HorizontalSpan:new({ width = math.max(side_pad, content_w - side_pad - actual_badge_w) }),
    })

    local title_row_h = math.max(self.word_widget:getSize().h, edit_btn_sz)
    local badge_top_gap = scale(5)
    local badge_h = dict_badge:getSize().h
    local title_bot_pad = scale(8)

    -- Descuenta con precisión matemática todas las filas de cabecera, plugins e iconos existentes
    local fixed_h = top_pad + title_row_h + badge_top_gap + badge_h + title_bot_pad + scale(12) + bot_pad
    local block_gap = scale(10)   -- aire entre la fila de íconos y los chips
    local chip_gap_v = scale(6)   -- aire entre filas de chips
    local num_text_rows = #text_row_widgets
    if #icon_widgets > 0 then
        fixed_h = fixed_h + icon_btn_h
    end
    if num_text_rows > 0 then
        fixed_h = fixed_h + (num_text_rows * ext_row_h) + ((num_text_rows - 1) * chip_gap_v)
        if #icon_widgets > 0 then fixed_h = fixed_h + block_gap end
    end

    -- Margen de resguardo inferior y piso protegido de lectura (40% de la pantalla)
    local safety_pad = self.is_landscape and scale(20) or 0
    local min_reading_h = math.floor(screen_height * 0.40)
    local avail_h = screen_height - fixed_h - safety_pad
    self.max_html_height = self.is_landscape and math.max(min_reading_h, avail_h) or math.floor(screen_height * 0.35)

    local html_avail_w = content_w - (side_pad * 2)
    local function makeHtml(h)
        local w = ScrollHtmlWidget:new({
            html_body = html_body, is_xhtml = true, css = getBaseCss(ui_instance),
            default_font_size = getDictFontSize(ui_instance), width = html_avail_w, height = h,
            scroll_bar_width = scale(6), dialog = self.dialog, highlight_text_selection = true,
        })
        applyRoundedScrollbar(w)
        return w
    end

    self.htmlwidget = makeHtml(self.max_html_height)

    -- Auto-ajuste de altura vertical (Shrink-to-fit): elimina espacios vacíos si la definición es corta
    if not self.is_landscape then
        local natural_h = getHtmlContentHeight(self.htmlwidget)
            or estimateHtmlContentHeight(html_avail_w, html_body, getDictFontSize(ui_instance))
        if natural_h and natural_h < self.max_html_height then
            local min_h = scale(40)
            -- Se otorga holgura (scale(14)) para evitar que fracciones de píxel disparen la scrollbar
            local fitted_h = math.max(min_h, math.ceil(natural_h) + scale(14))
            if fitted_h < self.max_html_height then
                if self.htmlwidget.free then pcall(function() self.htmlwidget:free() end) end
                self.htmlwidget = makeHtml(fitted_h)
            end
        end
    end

    self.html_row = HorizontalGroup:new({
        HorizontalSpan:new({ width = side_pad }),
        self.htmlwidget,
        HorizontalSpan:new({ width = side_pad })
    })

    local rows = {}
    if show_grabber and not self.anchor_top then
        table.insert(rows, VerticalSpan:new({ width = grabber_gap_outer }))
        table.insert(rows, SheetGrabber:new({ width = content_w, pill_h = grabber_h }))
        table.insert(rows, VerticalSpan:new({ width = grabber_gap_inner }))
    else
        table.insert(rows, VerticalSpan:new({ width = top_pad }))
    end
    table.insert(rows, self.title_row)
    table.insert(rows, VerticalSpan:new({ width = badge_top_gap }))
    table.insert(rows, self.badge_row)
    table.insert(rows, VerticalSpan:new({ width = title_bot_pad }))
    table.insert(rows, self.html_row)
    table.insert(rows, VerticalSpan:new({ width = scale(12) }))

    if #icon_widgets > 0 then
        table.insert(rows, HorizontalGroup:new(icon_widgets))
    end
    if #text_row_widgets > 0 then
        if #icon_widgets > 0 then
            table.insert(rows, VerticalSpan:new({ width = block_gap }))
        end
        for i, row_widget in ipairs(text_row_widgets) do
            table.insert(rows, row_widget)
            if i < #text_row_widgets then
                table.insert(rows, VerticalSpan:new({ width = chip_gap_v }))
            end
        end
    end
    
    if show_grabber and self.anchor_top then
        table.insert(rows, VerticalSpan:new({ width = grabber_gap_inner }))
        table.insert(rows, SheetGrabber:new({ width = content_w, pill_h = grabber_h }))
        table.insert(rows, VerticalSpan:new({ width = grabber_gap_outer }))
    else
        table.insert(rows, VerticalSpan:new({ width = bot_pad }))
    end
    local popup_content = VerticalGroup:new(rows)

    self.container = FloatingCard:new({
        anchor_top = self.anchor_top,
        anchor_left = self.anchor_left,
        is_landscape = self.is_landscape,
        content = popup_content,
        bordersize = math.max(2, scale(2.5)),
        radius = scale(15)
    })

    local container_w = self.container:getSize().w
    local container_h = self.container:getSize().h

    if self.is_landscape then
        local target_x = self.anchor_left and 0 or (screen_width - container_w)
        self.popup_rect = Geom:new({ x = target_x, y = 0, w = container_w, h = screen_height })

        self[1] = VerticalGroup:new({
            align = "left",
            HorizontalGroup:new({
                HorizontalSpan:new({ width = target_x }),
                self.container
            })
        })
    else
        local target_y = self.anchor_top and 0 or (screen_height - container_h)
        self.popup_rect = Geom:new({ x = 0, y = target_y, w = self.width, h = container_h })

        self[1] = VerticalGroup:new({
            VerticalSpan:new({ width = math.max(0, math.floor(target_y)) }),
            self.container
        })
    end
    
    self.dimen = Geom:new({ x = 0, y = 0, w = screen_width, h = screen_height })
    
    if Device:isTouchDevice() then 
        self.ges_events = { 
            TapClose = { GestureRange:new({ ges = "tap", range = self.dimen }) },
            Swipe    = { GestureRange:new({ ges = "swipe", range = self.dimen }) },
            HoldStartText = {
                GestureRange:new{
                    ges = "hold",
                    range = self.dimen,
                },
            },
            HoldPanText = {
                GestureRange:new{
                    ges = "hold_pan",
                    range = self.dimen,
                },
            },
            HoldReleaseText = {
                GestureRange:new{
                    ges = "hold_release",
                    range = self.dimen,
                },
                args = function(text)
                    if text and text ~= "" then
                        self:lookupWordDirect(text)
                    end
                end,
            },
        } 
        -- Con cursores, arrastrar uno ajusta la selección. Estos gestos solo se consumen si empiezan
        -- sobre un cursor; el resto sigue de largo como siempre.
        if self._cursor then
            local function on(ges) return { GestureRange:new({ ges = ges, range = self.dimen }) } end
            self.ges_events.CurTouch = on("touch")
            self.ges_events.CurPan = on("pan")
            self.ges_events.CurPanRelease = on("pan_release")
            self.ges_events.CurSwipe = on("swipe")
            self.ges_events.CurHold = on("hold")
            self.ges_events.CurHoldPan = on("hold_pan")
            self.ges_events.CurHoldRelease = on("hold_release")
        end
    end
end

function FloatingDictionaryPopup:onClose() UIManager:close(self) end
function FloatingDictionaryPopup:close() UIManager:close(self) end
function FloatingDictionaryPopup:closeWidget() UIManager:close(self) end

function FloatingDictionaryPopup:onHoldStartText(_arg, ges)
    -- Si mantienes pulsado fuera de la tarjeta, permite seleccionar la nueva palabra del libro
    if self.popup_rect and ges and ges.pos and ges.pos:notIntersectWith(self.popup_rect) then
        return false
    end
    return true
end
function FloatingDictionaryPopup:onHoldPanText(_arg, ges)
    if self.popup_rect and ges and ges.pos and ges.pos:notIntersectWith(self.popup_rect) then
        return false
    end
    return true
end
function FloatingDictionaryPopup:onHoldReleaseText() return true end

function FloatingDictionaryPopup:lookupWordDirect(word)
    local clean = cleanWordForLookup(word)
    if not clean or #clean == 0 then return false end

    -- Preservar la posición actual (arriba/abajo o lateral) y las cajas de la palabra original
    if self.plugin then
        self.plugin._inherited_anchor_top = self.anchor_top
        self.plugin._inherited_anchor_left = self.anchor_left
    end
    local original_boxes = self.boxes

    local UIManager = require("ui/uimanager")
    UIManager:close(self)

    UIManager:scheduleIn(0.05, function()
        if self.plugin and self.plugin.ui then
            local Event = require("ui/event")
            self.plugin.ui:handleEvent(Event:new("LookupWord", clean, true, original_boxes))
        end
    end)
    return true
end

function FloatingDictionaryPopup:onSwipe(arg1, arg2)
    local ges = arg2 or arg1
    if self._cursor and ges and ges.pos and self._cursor:handleAt(ges.pos) then return false end
    if not self.results or #self.results <= 1 then return false end
    
    if ges.direction == "west" then
        if self.current_result_idx < #self.results then
            self:switchDict(self.current_result_idx + 1)
            return true
        end
    elseif ges.direction == "east" then
        if self.current_result_idx > 1 then
            self:switchDict(self.current_result_idx - 1)
            return true
        end
    end
    return false
end

function FloatingDictionaryPopup:switchDict(new_idx)
    local total_dicts = self.results and #self.results or 1
    if new_idx < 1 or new_idx > total_dicts then return end

    local plugin = self.plugin
    local text = self.text
    local results = self.results
    local boxes = self.boxes
    local anchor_top = self.anchor_top
    local anchor_left = self.anchor_left
    local is_landscape = self.is_landscape
    local highlight_obj = self.highlight_obj
    local old_rect = self.popup_rect

    -- La selección sigue viva en la tarjeta nueva: no se borra ni se apagan los cursores
    self._keep_selection = true
    self._keep_cursor = true
    UIManager:close(self)

    -- Redibujar la zona anterior para que no queden fantasmas en E-ink
    if old_rect then
        if plugin and plugin.ui then
            UIManager:setDirty(plugin.ui, function() return "ui", old_rect end)
        else
            UIManager:setDirty(nil, function() return "ui", old_rect end)
        end
    end

    local popup = FloatingDictionaryPopup:new({
        text = text,
        results = results,
        boxes = boxes,
        anchor_top = anchor_top,
        anchor_left = anchor_left,
        is_landscape = is_landscape,
        highlight_obj = highlight_obj,
        plugin = plugin,
        current_result_idx = new_idx
    })
    UIManager:show(popup)
end

-- ==========================================
-- TARJETA: MÚLTIPLES PALABRAS (UNA SOLA COLUMNA EN EL SUR-ESTE)
-- ==========================================
local FloatingActionMenu = InputContainer:extend({
    text = nil, boxes = nil, anchor_top = false, highlight_obj = nil, plugin = nil, pos0 = nil, pos1 = nil, annotation_index = nil,
    show_more = false,
    more_card = nil,
    more_container = nil,
    more_popup_rect = nil,
})

function FloatingActionMenu:init()
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()

    -- Cursores de selección: solo con una selección nueva (no con un highlight tocado) y si están activados
    do
        local cursor = self.plugin and self.plugin.cursor
        local hl_obj = self.highlight_obj
        if cursor and self.annotation_index == nil and hl_obj and hl_obj.hold_pos and cursor:isEnabled() then
            self._cursor = cursor
        end
    end
    if self.plugin then self.plugin.active_selection_menu = self end

    -- 1. Detección dinámica de X-Ray si el plugin está presente
    local xray_spec = nil
    if self.plugin and type(self.plugin.discoverExternalButtons) == "function" then
        local plugin_rows = self.plugin:discoverExternalButtons(self.plugin.patched_dictionary, self.text, nil, 1, nil, self.boxes, nil)
        for _, row in ipairs(plugin_rows) do
            for _, ext in ipairs(row) do
                local id_lower = (ext.id or ""):lower()
                local txt_lower = (ext.text or ""):lower()
                if id_lower:find("xray") or id_lower:find("x%-ray") or txt_lower:find("xray") or txt_lower:find("x%-ray") then
                    local assigned_svg = getValidSvgPath("xray.svg")
                    xray_spec = {
                        id = ext.id,
                        svg = "xray.svg",
                        text = assigned_svg and nil or "X-Ray",
                        external_callback = ext.callback,
                        fake_popup = ext.fake_popup,
                    }
                    break
                end
            end
            if xray_spec then break end
        end
    end

    local SEL_BUTTON_SPECS = {
        ai            = { svg = "sparkles.svg", text = "AI", action = "ai", setting = "page_scrubber_sel_show_ai" },
        note          = { svg = "notepad-text.svg", text = "Note", action = "note", setting = "page_scrubber_sel_show_note" },
        strikethrough = { svg = "strikethrough.svg", text = "Str", action = "strikethrough", setting = "page_scrubber_sel_show_strikethrough" },
        underline     = { svg = "underline.svg", text = "Und", action = "underline", setting = "page_scrubber_sel_show_underline" },
        invert        = { svg = "contrast.svg", text = "Inv", action = "invert", setting = "page_scrubber_sel_show_invert" },
        highlight     = { svg = "droplet.svg", text = "HL", action = "highlight", setting = "page_scrubber_sel_show_highlight" },
        -- Botones que por defecto viven en la fila de More; si se activan, suben a la barra principal
        select        = { svg = "crop.svg", text = "Sel", action = "select", setting = "page_scrubber_sel_show_select", default = false, row1 = true },
        dict          = { svg = "book-marked.svg", text = "Dict", action = "dict", setting = "page_scrubber_sel_show_dict", default = false, row1 = true },
        wiki          = { svg = "globe.svg", text = "Wiki", action = "wiki", setting = "page_scrubber_sel_show_wiki", default = false, row1 = true },
        translate     = { svg = "languages.svg", text = "Trans", action = "translate", setting = "page_scrubber_sel_show_translate", default = false, row1 = true },
    }

    local more_svg = getValidSvgPath("more.svg") or getValidSvgPath("square-plus.svg") or getValidSvgPath("plus.svg")
    local more_btn_spec = {
        svg = "more.svg",
        text = not more_svg and "+" or nil,
        action = "more",
        is_plus = true,
    }

    local default_sel_order = { "xray", "ai", "note", "strikethrough", "underline", "invert", "highlight", "select", "dict", "wiki", "translate", "more" }
    if SelCustom then default_sel_order = SelCustom.withCustomKeys(default_sel_order) end
    local saved_sel_order = G_reader_settings and G_reader_settings:readSetting("page_scrubber_sel_btn_order")
    if type(saved_sel_order) ~= "table" then
        if G_reader_settings and (G_reader_settings:isTrue("page_scrubber_sel_reverse_order") or G_reader_settings:isTrue("page_scrubber_sel_more_first")) then
            saved_sel_order = { "more", "highlight", "invert", "underline", "strikethrough", "note", "ai", "xray" }
        else
            saved_sel_order = default_sel_order
        end
    else
        -- Incorporar xray y more si el usuario ya tenía una configuración previa guardada
        local seen = {}
        for _, k in ipairs(saved_sel_order) do seen[k] = true end
        for _, k in ipairs(default_sel_order) do
            if not seen[k] then
                local more_pos
                for i, sk in ipairs(saved_sel_order) do
                    if sk == "more" then more_pos = i; break end
                end
                if k ~= "more" and more_pos then
                    table.insert(saved_sel_order, more_pos, k)
                else
                    table.insert(saved_sel_order, k)
                end
            end
        end
    end

    -- Botones de otros plugins agregados con "Add button": si falta alguno en el orden guardado, entra antes de More
    if SelCustom then
        local present = {}
        for _, k in ipairs(saved_sel_order) do present[k] = true end
        for _, ck in ipairs(SelCustom.keys()) do
            if not present[ck] then
                local more_pos
                for i, sk in ipairs(saved_sel_order) do
                    if sk == "more" then more_pos = i; break end
                end
                if more_pos and more_pos > 1 then
                    table.insert(saved_sel_order, more_pos, ck)
                else
                    table.insert(saved_sel_order, ck)
                end
            end
        end
    end

    -- Construcción de la barra respetando estrictamente el orden configurado
    local raw_buttons = {}
    for _, btn_key in ipairs(saved_sel_order) do
        if btn_key == "more" then
            if is_btn_enabled("page_scrubber_sel_show_more") then
                table.insert(raw_buttons, more_btn_spec)
            end
        elseif btn_key == "xray" then
            if xray_spec and is_btn_enabled("page_scrubber_sel_show_xray") then
                table.insert(raw_buttons, xray_spec)
            end
        elseif SelCustom and SelCustom.isCustomKey(btn_key) then
            local ce = SelCustom.get(btn_key)
            if ce and is_btn_enabled(SelCustom.toggleSetting(btn_key), true) then
                -- Solo se muestra si el plugin sigue instalado y su botón aplica a esta selección
                local live = SelCustom.findButton(self.highlight_obj, ce, self.annotation_index)
                if live and SelCustom.isShown(live) then
                    local icon_path = SelCustom.iconPath(ce)
                    table.insert(raw_buttons, {
                        svg_path = icon_path,
                        text = icon_path and nil or ce.text,
                        ext_btn = live,
                    })
                end
            end
        else
            local b_spec = SEL_BUTTON_SPECS[btn_key]
            if b_spec and is_btn_enabled(b_spec.setting, b_spec.default) then
                table.insert(raw_buttons, { svg = b_spec.svg, text = b_spec.text, action = b_spec.action, row1 = b_spec.row1 })
            end
        end
    end

    -- Salvaguarda: si More está habilitado pero no quedó en la lista, lo agrega al final
    if is_btn_enabled("page_scrubber_sel_show_more") then
        local has_more = false
        for _, b in ipairs(raw_buttons) do
            if b.is_plus then has_more = true; break end
        end
        if not has_more then
            table.insert(raw_buttons, more_btn_spec)
        end
    end

    local pos_pref = (G_reader_settings and G_reader_settings:readSetting("page_scrubber_sel_menu_position")) or "right_v"
    -- "auto_h": horizontal, sigue a la selección (arriba del texto, o abajo si no hay lugar). Sin el módulo
    -- de cursores no se puede saber dónde está la selección: en ese caso se comporta como "Bottom".
    if pos_pref == "auto_h" and not SelectionCursor then pos_pref = "bottom_h" end
    local is_auto = (pos_pref == "auto_h")
    local is_horizontal = (pos_pref == "bottom_h" or pos_pref == "center_h" or is_auto)
    self._pos_pref = pos_pref
    self._is_horizontal = is_horizontal

    local margin_side = scale(24)
    local margin_bottom = scale(54)

    local ui_instance = self.plugin and self.plugin.ui
    local raw_fs = getBookRawFontSize(ui_instance) or 26
    local font_ratio = math.max(0.85, math.min(1.40, raw_fs / 26))

    -- Íconos y botones fijos al DPI táctil; altura compacta para celdas cuadradas
    local dynamic_icon_sz = sscale(22)
    local btn_w = is_horizontal and sscale(45) or sscale(52)
    local btn_h = sscale(36)
    local text_fs = math.floor(scaleText(12) * getSelSizeK() * font_ratio + 0.5)
    self._btn_w = btn_w
    self._btn_h = btn_h
    self._font_ratio = font_ratio

    local icon_widgets = {}
    self._plus_btn_index = nil

    for idx, spec in ipairs(raw_buttons) do
        local path = spec.svg_path or getValidSvgPath(spec.svg)
        if not path and spec.action == "ai" then
            path = getValidSvgPath("ai.svg") or getValidSvgPath("bot.svg")
        end

        local cb
        local hold_cb
        if spec.is_plus then
            self._plus_btn_index = idx
            cb = function() self:toggleMore() end
        elseif spec.external_callback then
            cb = function() pcall(spec.external_callback) end
        elseif spec.ext_btn then
            cb = function() self:invokeExternalButton(spec.ext_btn) end
        elseif spec.row1 then
            cb = function() self:invokeRow1Action(spec.action) end
        else
            cb = function() self:invokeNative(spec.action) end
            hold_cb = function(btn_obj, anchor_pos) self:invokeNativeHold(spec.action, anchor_pos) end
        end

        local btn = PreviewButton:new({
            icon_svg = path,
            icon_size = dynamic_icon_sz,
            text = not path and spec.text or nil,
            font_size = text_fs,
            face = not path and getBookFace(ui_instance, text_fs, true) or nil,
            width = btn_w,
            height = btn_h,
            always_show_text = false,
            show_parent = self,
            callback = cb,
            hold_callback = hold_cb,
        })

        if spec.fake_popup and spec.id then
            spec.fake_popup._real_buttons = spec.fake_popup._real_buttons or {}
            spec.fake_popup._real_buttons[spec.id] = btn
        end

        table.insert(icon_widgets, btn)
    end

    local card_pad = math.floor(sscale(2) * font_ratio + 0.5)
    local card_sep = math.max(1, math.floor(sscale(2) * font_ratio + 0.5))
    self._card_pad = card_pad
    self._card_sep = card_sep

    local popup_content

    if is_horizontal then
        local total_single_w = card_pad * 2 + (#icon_widgets * btn_w) + ((#icon_widgets - 1) * card_sep) + scale(6)
        local max_avail_w = screen_width - scale(16)

        if total_single_w > max_avail_w then
            self._num_rows = 2
            local per_row = math.ceil(#icon_widgets / 2)
            self._per_row = per_row

            local row1_items = { HorizontalSpan:new({ width = card_pad }) }
            for i = 1, per_row do
                table.insert(row1_items, icon_widgets[i])
                if i < per_row then
                    table.insert(row1_items, HorizontalSpan:new({ width = card_sep }))
                end
            end
            table.insert(row1_items, HorizontalSpan:new({ width = card_pad }))

            local row2_items = { HorizontalSpan:new({ width = card_pad }) }
            for i = per_row + 1, #icon_widgets do
                table.insert(row2_items, icon_widgets[i])
                if i < #icon_widgets then
                    table.insert(row2_items, HorizontalSpan:new({ width = card_sep }))
                end
            end
            table.insert(row2_items, HorizontalSpan:new({ width = card_pad }))

            popup_content = VerticalGroup:new({
                VerticalSpan:new({ width = card_pad }),
                HorizontalGroup:new(row1_items),
                VerticalSpan:new({ width = card_sep }),
                HorizontalGroup:new(row2_items),
                VerticalSpan:new({ width = card_pad }),
            })
        else
            self._num_rows = 1
            self._per_row = #icon_widgets

            local items = { HorizontalSpan:new({ width = card_pad }) }
            for i, btn_widget in ipairs(icon_widgets) do
                table.insert(items, btn_widget)
                if i < #icon_widgets then
                    table.insert(items, HorizontalSpan:new({ width = card_sep }))
                end
            end
            table.insert(items, HorizontalSpan:new({ width = card_pad }))
            popup_content = HorizontalGroup:new(items)
        end
    else
        local total_single_h = card_pad * 2 + (#icon_widgets * btn_h) + ((#icon_widgets - 1) * card_sep) + scale(6)
        local max_avail_h = screen_height - margin_bottom - scale(20)

        if total_single_h > max_avail_h then
            self._num_cols = 2
            local per_col = math.ceil(#icon_widgets / 2)
            self._per_col = per_col

            local col1_items = { VerticalSpan:new({ width = card_pad }) }
            for i = 1, per_col do
                table.insert(col1_items, icon_widgets[i])
                if i < per_col then
                    table.insert(col1_items, VerticalSpan:new({ width = card_sep }))
                end
            end
            table.insert(col1_items, VerticalSpan:new({ width = card_pad }))

            local col2_items = { VerticalSpan:new({ width = card_pad }) }
            for i = per_col + 1, #icon_widgets do
                table.insert(col2_items, icon_widgets[i])
                if i < #icon_widgets then
                    table.insert(col2_items, VerticalSpan:new({ width = card_sep }))
                end
            end
            table.insert(col2_items, VerticalSpan:new({ width = card_pad }))

            popup_content = HorizontalGroup:new({
                HorizontalSpan:new({ width = card_pad }),
                VerticalGroup:new(col1_items),
                HorizontalSpan:new({ width = card_sep }),
                VerticalGroup:new(col2_items),
                HorizontalSpan:new({ width = card_pad }),
            })
        else
            self._num_cols = 1
            self._per_col = #icon_widgets

            local rows = { VerticalSpan:new({ width = card_pad }) }
            for i, btn_widget in ipairs(icon_widgets) do
                table.insert(rows, btn_widget)
                if i < #icon_widgets then
                    table.insert(rows, VerticalSpan:new({ width = card_sep }))
                end
            end
            table.insert(rows, VerticalSpan:new({ width = card_pad }))
            popup_content = VerticalGroup:new(rows)
        end
    end

    self.card = FloatingPillCard:new({
        content = popup_content, bordersize = sscale(SEL_BORDER_PX), radius = math.floor(sscale(10) * font_ratio + 0.5)
    })

    local card_size = self.card:getSize()
    local card_w = card_size.w
    local card_h = card_size.h

    local target_x, target_y, auto_grow_up

    if pos_pref == "left_v" then
        target_x = margin_side
        target_y = screen_height - card_h - margin_bottom
    elseif pos_pref == "bottom_h" then
        target_x = math.floor((screen_width - card_w) / 2)
        target_y = screen_height - card_h - margin_bottom
    elseif pos_pref == "center_h" then
        target_x = math.floor((screen_width - card_w) / 2)
        target_y = math.floor((screen_height - card_h) / 2)
    elseif is_auto then
        target_x, target_y, auto_grow_up = self:autoPlace(card_w, card_h)
    else
        target_x = screen_width - card_w - margin_side
        target_y = screen_height - card_h - margin_bottom
    end

    if target_y < scale(10) then target_y = scale(10) end
    if target_x < scale(10) then target_x = scale(10) end

    self.popup_rect = Geom:new({ x = target_x, y = target_y, w = card_w, h = card_h })
    -- Hacia dónde se despliega More / el selector de colores: arriba en "Bottom", abajo en "Center",
    -- y en "Auto" hacia el lado donde quedó el menú respecto de la selección
    self._grow_up = (pos_pref == "bottom_h") or (is_auto and auto_grow_up == true)

    self[1] = VerticalGroup:new({
        align = "left",
        VerticalSpan:new({ width = math.max(0, math.floor(target_y)) }),
        HorizontalGroup:new({
            HorizontalSpan:new({ width = math.max(0, math.floor(target_x)) }),
            self.card
        })
    })

    self.dimen = Geom:new({ x = 0, y = 0, w = screen_width, h = screen_height })
    if Device:isTouchDevice() then 
        self.ges_events = { TapClose = { GestureRange:new({ ges = "tap", range = self.dimen }) } } 
        -- Con los cursores activos, arrastrar uno ajusta la selección. Estos gestos solo se consumen si
        -- empiezan sobre un cursor; el resto sigue de largo hacia el lector como siempre.
        if self._cursor then
            local function on(ges) return { GestureRange:new({ ges = ges, range = self.dimen }) } end
            self.ges_events.CurTouch = on("touch")
            self.ges_events.CurPan = on("pan")
            self.ges_events.CurPanRelease = on("pan_release")
            self.ges_events.CurSwipe = on("swipe")
            self.ges_events.CurHold = on("hold")
            self.ges_events.CurHoldPan = on("hold_pan")
            self.ges_events.CurHoldRelease = on("hold_release")
        end
    end

    self:buildMoreCard()
end

-- Posición "automática": horizontal, arriba de la selección (abajo si arriba no hay lugar)
function FloatingActionMenu:autoPlace(w, h)
    local ui = self.plugin and self.plugin.ui
    local hl = self.highlight_obj
    local lines
    if SelectionCursor and ui and self.selected_text then
        local ok, res = pcall(SelectionCursor.selectionLines, ui, self.selected_text,
            hl and hl.hold_pos and hl.hold_pos.page)
        if ok then lines = res end
    end
    -- Con cursores, el aro de cada extremo sobresale de la línea: el menú se corre para no taparlo
    local gap = scale(10)
    if lines and self._cursor then
        gap = math.max(gap, 2 * SelectionCursor.knobRadius(lines) + scale(8))
    end
    return placeNearLines(w, h, lines, { gap = gap })
end

function FloatingActionMenu:invokeRow1Action(act)
    if act == "select" then
        self:invokeNative("adjust")
        return
    end
    local nb = self._native_buttons and self._native_buttons[act]
    if nb and type(nb.callback) == "function" then
        UIManager:close(self)
        pcall(nb.callback, self.highlight_obj, self.annotation_index)
    else
        self:invokeNative(act)
    end
end

-- Un botón de otro plugin agregado a la barra principal (Add button): se corre el callback del
-- botón vivo del plugin igual que desde la fila de More.
function FloatingActionMenu:invokeExternalButton(btn)
    local hl = self.highlight_obj
    if type(btn) ~= "table" or type(btn.callback) ~= "function" then return end
    UIManager:close(self)
    FloatingDictionaryPopup.withRestoredSelection(self, function()
        btn.callback(hl, self.annotation_index)
    end)
end

function FloatingActionMenu:buildMoreCard()
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()
    local hl = self.highlight_obj

    local native_buttons = {}
    local unknown_buttons = {}
    -- Los botones de otros plugins que el usuario agregó a la barra principal no se repiten acá
    local shown_custom_ids = SelCustom and SelCustom.shownIds() or nil

    if hl and hl._highlight_buttons then
        local ok, ffiUtil = pcall(require, "ffi/util")
        local iterator = (ok and ffiUtil and ffiUtil.orderedPairs) or pairs
        for key, fn in iterator(hl._highlight_buttons) do
            if type(fn) == "function" then
                local ok_b, btn = pcall(fn, hl, self.annotation_index)
                if ok_b and type(btn) == "table" then
                    local show = true
                    if type(btn.show_in_highlight_dialog_func) == "function" then
                        local ok_s, res_s = pcall(btn.show_in_highlight_dialog_func)
                        show = ok_s and res_s
                    end
                    if show then
                        local k_clean = tostring(key):gsub("^%d+_", ""):lower()
                        local id_clean = tostring(btn.id or ""):lower()
                        local txt_clean = tostring(btn.text or ""):lower()

                        btn.id = btn.id or key

                        -- Captura estricta de callbacks del sistema para la fila 1
                        local is_native_select = (k_clean == "select" or k_clean == "start_selection" or id_clean == "select" or txt_clean == "select" or txt_clean == "seleccionar")
                        local is_native_copy = (k_clean == "copy" or id_clean == "copy" or txt_clean == "copy" or txt_clean == "copiar")
                        local is_native_dict = (k_clean == "dict" or k_clean == "dictionary" or id_clean == "dict" or id_clean == "dictionary" or txt_clean == "dictionary" or txt_clean == "diccionario")
                        local is_native_wiki = (k_clean == "wiki" or k_clean == "wikipedia" or id_clean == "wiki" or id_clean == "wikipedia" or txt_clean == "wikipedia" or txt_clean == "wiki")
                        local is_native_search = (k_clean == "search" or id_clean == "search" or txt_clean == "search" or txt_clean == "buscar")
                        local is_native_trans = (k_clean == "translate" or id_clean == "translate" or txt_clean == "translate" or txt_clean == "traducir")

                        if is_native_select then
                            native_buttons["select"] = btn
                        elseif is_native_copy then
                            native_buttons["copy"] = btn
                        elseif is_native_dict then
                            native_buttons["dict"] = btn
                        elseif is_native_wiki then
                            native_buttons["wiki"] = btn
                        elseif is_native_search then
                            native_buttons["search"] = btn
                        elseif is_native_trans then
                            native_buttons["translate"] = btn
                        end

                        -- Bloqueo de duplicados y funciones sin soporte en Kindle
                        local is_share = id_clean:find("share") or k_clean:find("share") or txt_clean:find("share") or txt_clean:find("compart")
                        local is_html = id_clean:find("html") or k_clean:find("html") or txt_clean:find("html")
                        local is_xray = id_clean:find("xray") or id_clean:find("x%-ray") or k_clean:find("xray") or k_clean:find("x%-ray") or txt_clean:find("xray") or txt_clean:find("x%-ray")
                        local is_native_assistant = (
                            k_clean == "assistant" or id_clean == "assistant" or 
                            k_clean == "ai" or id_clean == "ai" or
                            txt_clean:find("assistant") or txt_clean:find("asistente") or
                            txt_clean:find("ai assistant") or txt_clean:find("ia assistant")
                        )

                        -- Filtro estricto: descarta herramientas resueltas, duplicadas o bloqueadas
                        local is_known = (
                            is_native_select or is_native_copy or is_native_dict
                            or is_native_wiki or is_native_search or is_native_trans
                            or is_share or is_html or is_xray or is_native_assistant
                            or k_clean == "highlight" or id_clean == "highlight" or txt_clean == "highlight" or txt_clean == "resaltar"
                            or k_clean == "note" or k_clean == "add_note" or id_clean == "note" or txt_clean == "note" or txt_clean == "nota"
                            or id_clean == "strike" or id_clean == "strikethrough" or id_clean == "underline" or id_clean == "invert"
                        )

                        if not is_known and btn.enabled ~= false and not (shown_custom_ids and shown_custom_ids[tostring(btn.id)]) then
                            btn._ps_reg_key = key   -- la clave con que el plugin lo registró (para "Add button")
                            table.insert(unknown_buttons, btn)
                        end
                    end
                end
            end
        end
    end

    local ui_instance = self.plugin and self.plugin.ui
    local raw_fs = getBookRawFontSize(ui_instance) or 26
    local font_ratio = self._font_ratio or math.max(0.85, math.min(1.40, raw_fs / 26))

    self._native_buttons = native_buttons

    local row1_specs = {
        { svg = "crop.svg", text = "Sel", action = "select" },
        { svg = "copy.svg", text = "Copy", action = "copy" },
        { svg = "book-marked.svg", fallback_svg = "book-open.svg", text = "Dict", action = "dict" },
        { svg = "globe.svg", text = "Wiki", action = "wiki" },
        { svg = "search.svg", text = "Search", action = "search" },
        { svg = "languages.svg", text = "Trans", action = "translate" },
    }

    -- Dict / Wiki / Trans: si están activados en la barra principal, no se repiten en la fila de More
    do
        local main_bar_setting = {
            select = "page_scrubber_sel_show_select",
            dict = "page_scrubber_sel_show_dict",
            wiki = "page_scrubber_sel_show_wiki",
            translate = "page_scrubber_sel_show_translate",
        }
        local filtered = {}
        for _, sp in ipairs(row1_specs) do
            local key = main_bar_setting[sp.action]
            if not (key and is_btn_enabled(key, false)) then
                table.insert(filtered, sp)
            end
        end
        row1_specs = filtered
    end

    local row1_icon_sz = sscale(22)
    local min_btn_w = sscale(46)
    local row1_btn_h = sscale(36)
    local row1_text_fs = math.floor(scaleText(11) * font_ratio + 0.5)

    -- Ancho base mínimo requerido por los 6 iconos superiores
    local min_more_w = (min_btn_w * #row1_specs) + ((#row1_specs - 1) * scale(2)) + scale(12)
    local max_needed_w = min_more_w

    -- Extraer textos y calcular dinámicamente el ancho necesario para no recortar
    local button_texts = {}
    if #unknown_buttons > 0 then
        for idx, u_btn in ipairs(unknown_buttons) do
            local u_text = u_btn.text
            if type(u_btn.text_func) == "function" then
                local ok_t, res_t = pcall(u_btn.text_func, hl)
                if ok_t and res_t then u_text = res_t end
            end
            u_text = tostring(u_text or u_btn.id or "?")
            button_texts[idx] = u_text

            local test_face = getBookFace(ui_instance, scaleText(11), false)
            local tw = TextWidget:new({ text = u_text, face = test_face })
            local needed = tw:getSize().w + scale(32)
            tw:free()
            if needed > max_needed_w then
                max_needed_w = needed
            end
        end
    end

    -- Salvaguarda de pantalla según la orientación activa
    local max_allowed_w = screen_width - scale(24)
    if not self._is_horizontal and self.popup_rect then
        max_allowed_w = math.min(max_allowed_w, screen_width - self.popup_rect.w - scale(28))
    end
    max_allowed_w = math.min(max_allowed_w, scale(350))

    -- Anota los botones que de verdad se muestran en More: "Add button" los ofrece aunque desde
    -- Settings (sin nada seleccionado) no se pueda saber si aplican
    if SelCustom and #unknown_buttons > 0 then
        local shown = {}
        for idx, u_btn in ipairs(unknown_buttons) do
            shown[#shown + 1] = { id = u_btn.id, reg_key = u_btn._ps_reg_key, text = button_texts[idx] }
        end
        pcall(SelCustom.rememberSeen, shown)
    end

    local more_w = math.max(min_more_w, math.min(max_needed_w, max_allowed_w))
    local u_btn_w = more_w - scale(12)
    local line_w = more_w - scale(12)

    -- Reparto simétrico de los 6 iconos superiores al ancho final expandido
    local row1_btn_w = math.floor((more_w - scale(12) - ((#row1_specs - 1) * scale(2))) / #row1_specs)

    local row1_widgets = {}
    for _, spec in ipairs(row1_specs) do
        local path = getValidSvgPath(spec.svg) or (spec.fallback_svg and getValidSvgPath(spec.fallback_svg))
        table.insert(row1_widgets, PreviewButton:new({
            icon_svg = path,
            icon_size = row1_icon_sz,
            text = not path and spec.text or nil,
            font_size = row1_text_fs,
            face = not path and getBookFace(ui_instance, row1_text_fs, true) or nil,
            width = row1_btn_w,
            height = row1_btn_h,
            always_show_text = false,
            show_parent = self,
            callback = function()
                local act = spec.action
                if act == "select" then
                    self:invokeNative("adjust")
                elseif native_buttons[act] and type(native_buttons[act].callback) == "function" then
                    UIManager:close(self)
                    pcall(native_buttons[act].callback, hl, self.annotation_index)
                else
                    self:invokeNative(act)
                end
            end,
        }))
    end

    local row1_items = { HorizontalSpan:new({ width = scale(6) }) }
    for i, w in ipairs(row1_widgets) do
        table.insert(row1_items, w)
        if i < #row1_widgets then
            table.insert(row1_items, HorizontalSpan:new({ width = scale(2) }))
        end
    end
    table.insert(row1_items, HorizontalSpan:new({ width = scale(6) }))
    local row1_group = HorizontalGroup:new(row1_items)

    local card_vertical_items = {
        VerticalSpan:new({ width = scale(6) }),
        row1_group,
    }

    local function createSeparator()
        return HorizontalGroup:new({
            HorizontalSpan:new({ width = scale(6) }),
            LineWidget:new({
                background = Blitbuffer.COLOR_GRAY,
                width = line_w,
                height = math.max(1, scale(1)),
                dimen = Geom:new({ w = line_w, h = math.max(1, scale(1)) }),
            }),
            HorizontalSpan:new({ width = scale(6) }),
        })
    end

    -- Filas siguientes: reducción tipográfica dinámica para que no aparezcan puntos suspensivos
    if #unknown_buttons > 0 then
        local max_text_avail_w = u_btn_w - scale(12)
        local target_fs = scaleText(14)
        local min_fs = scaleText(10)

        for idx, u_btn in ipairs(unknown_buttons) do
            table.insert(card_vertical_items, VerticalSpan:new({ width = scale(4) }))
            table.insert(card_vertical_items, createSeparator())
            table.insert(card_vertical_items, VerticalSpan:new({ width = scale(4) }))

            local u_text = button_texts[idx] or "?"
            local chosen_fs = min_fs

            for test_fs = target_fs, min_fs, -1 do
                local test_face = getBookFace(ui_instance, test_fs, false)
                local tw = TextWidget:new({ text = u_text, face = test_face })
                local tw_w = tw:getSize().w
                tw:free()
                if tw_w <= max_text_avail_w then
                    chosen_fs = test_fs
                    break
                end
            end

            local plugin_face = getBookFace(ui_instance, chosen_fs, false)
            local u_btn_h = math.max(scale(30), math.floor(chosen_fs * 1.8 + 0.5))

            local btn_widget = PreviewButton:new({
                icon_svg = nil,
                text = u_text,
                face = plugin_face,
                font_size = chosen_fs,
                width = u_btn_w,
                height = u_btn_h,
                always_show_text = true,
                show_parent = self,
                callback = function()
                    UIManager:close(self)
                    if type(u_btn.callback) == "function" then
                        -- Igual que en el diccionario: si al cerrar el menu KOReader limpio
                        -- hl.selected_text, se la restauramos al plugin mientras corre su callback.
                        FloatingDictionaryPopup.withRestoredSelection(self, function()
                            u_btn.callback(hl, self.annotation_index)
                        end)
                    end
                end,
            })

            table.insert(card_vertical_items, HorizontalGroup:new({
                HorizontalSpan:new({ width = scale(6) }),
                btn_widget,
                HorizontalSpan:new({ width = scale(6) }),
            }))
        end
    end

    table.insert(card_vertical_items, VerticalSpan:new({ width = scale(6) }))
    local more_content = VerticalGroup:new(card_vertical_items)

    self.more_card = FloatingPillCard:new({
        content = more_content, bordersize = sscale(SEL_BORDER_PX), radius = math.floor(sscale(14) * font_ratio + 0.5)
    })
end

function FloatingActionMenu:updateMoreLayout()
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()
    local more_size = self.more_card:getSize()
    local more_w = more_size.w
    local more_h = more_size.h

    -- Calcular la posición absoluta en pantalla del botón '+'
    local btn_idx = self._plus_btn_index or 1
    local b = sscale(SEL_BORDER_PX)  -- grosor real del contorno de la tarjeta principal
    local btn_plus_x, btn_plus_y
    local btn_w, btn_h = self._btn_w, self._btn_h
    local card_pad = self._card_pad or scale(6)
    local card_sep = self._card_sep or scale(2)

    if self._is_horizontal then
        if self._num_rows == 2 then
            local per_row = self._per_row or math.ceil(btn_idx / 2)
            local row_idx = (btn_idx <= per_row) and 0 or 1
            local col_idx = (btn_idx <= per_row) and (btn_idx - 1) or (btn_idx - per_row - 1)
            local rel_x = b + card_pad + (col_idx * (btn_w + card_sep))
            local rel_y = b + card_pad + (row_idx * (btn_h + card_sep))
            btn_plus_x = self.popup_rect.x + rel_x
            btn_plus_y = self.popup_rect.y + rel_y
        else
            local rel_x = b + card_pad + ((btn_idx - 1) * (btn_w + card_sep))
            btn_plus_x = self.popup_rect.x + rel_x
            btn_plus_y = self.popup_rect.y + b + card_pad
        end
    else
        if self._num_cols == 2 then
            local per_col = self._per_col or math.ceil(btn_idx / 2)
            local col_idx = (btn_idx <= per_col) and 0 or 1
            local row_idx = (btn_idx <= per_col) and (btn_idx - 1) or (btn_idx - per_col - 1)
            local rel_x = b + card_pad + (col_idx * (btn_w + card_sep))
            local rel_y = b + card_pad + (row_idx * (btn_h + card_sep))
            btn_plus_x = self.popup_rect.x + rel_x
            btn_plus_y = self.popup_rect.y + rel_y
        else
            local rel_y = b + card_pad + ((btn_idx - 1) * (btn_h + card_sep))
            btn_plus_x = self.popup_rect.x + b + card_pad
            btn_plus_y = self.popup_rect.y + rel_y
        end
    end

    local gap = scale(6)
    local margin = scale(8)
    local target_more_x, target_more_y

    if self._is_horizontal then
        -- Eje Y: en bottom_h brota arriba; en center_h brota abajo; en auto_h hacia el lado de la selección
        local grow_up = self._grow_up
        if self._pos_pref == "auto_h" then
            -- Si de ese lado no entra, sale por el otro
            if grow_up and (self.popup_rect.y - more_h - gap) < margin then
                grow_up = false
            elseif (not grow_up) and (self.popup_rect.y + self.popup_rect.h + gap + more_h) > screen_height - margin then
                grow_up = true
            end
        end
        if grow_up then
            target_more_y = self.popup_rect.y - more_h - gap
        else
            target_more_y = self.popup_rect.y + self.popup_rect.h + gap
        end

        -- Eje X: centrado en el '+' pero restringido estrictamente al contorno de popup_rect
        target_more_x = math.floor(btn_plus_x + (btn_w / 2) - (more_w / 2))

        if more_w <= self.popup_rect.w then
            local min_x = self.popup_rect.x
            local max_x = self.popup_rect.x + self.popup_rect.w - more_w
            target_more_x = math.max(min_x, math.min(target_more_x, max_x))
        else
            -- Si el menú secundario es más ancho que la barra, alinea al borde donde se ubica el '+'
            if (btn_plus_x + btn_w / 2) >= (self.popup_rect.x + self.popup_rect.w / 2) then
                target_more_x = self.popup_rect.x + self.popup_rect.w - more_w
            else
                target_more_x = self.popup_rect.x
            end
        end
    else
        -- Eje X: brota al lateral correspondiente
        if self._pos_pref == "left_v" then
            target_more_x = self.popup_rect.x + self.popup_rect.w + gap
        else -- "right_v"
            target_more_x = self.popup_rect.x - more_w - gap
        end

        -- Eje Y: centrado en el '+' pero restringido estrictamente al contorno de popup_rect
        target_more_y = math.floor(btn_plus_y + (btn_h / 2) - (more_h / 2))

        if more_h <= self.popup_rect.h then
            local min_y = self.popup_rect.y
            local max_y = self.popup_rect.y + self.popup_rect.h - more_h
            target_more_y = math.max(min_y, math.min(target_more_y, max_y))
        else
            -- Si el menú secundario es más alto que la barra, alinea al borde donde se ubica el '+'
            if (btn_plus_y + btn_h / 2) >= (self.popup_rect.y + self.popup_rect.h / 2) then
                target_more_y = self.popup_rect.y + self.popup_rect.h - more_h
            else
                target_more_y = self.popup_rect.y
            end
        end
    end

    -- Salvaguardas de pantalla para evitar recortes en bordes del dispositivo
    if target_more_x + more_w > screen_width - margin then
        target_more_x = screen_width - more_w - margin
    end
    if target_more_x < margin then target_more_x = margin end
    if target_more_y + more_h > screen_height - margin then
        target_more_y = screen_height - more_h - margin
    end
    if target_more_y < margin then target_more_y = margin end

    self.more_popup_rect = Geom:new({ x = target_more_x, y = target_more_y, w = more_w, h = more_h })

    self.more_container = VerticalGroup:new({
        align = "left",
        VerticalSpan:new({ width = math.max(0, math.floor(target_more_y)) }),
        HorizontalGroup:new({
            HorizontalSpan:new({ width = math.max(0, math.floor(target_more_x)) }),
            self.more_card
        })
    })
end

function FloatingActionMenu:toggleMore()
    if self.show_more then
        local dirty_rect = self.more_popup_rect
        self.show_more = false
        self.more_container = nil

        if dirty_rect then
            -- Redibuja el libro debajo para restaurar la página sin dejar fantasmas en E-ink
            local pad = scale(3)
            local clear_geom = Geom:new({
                x = math.max(0, dirty_rect.x - pad),
                y = math.max(0, dirty_rect.y - pad),
                w = dirty_rect.w + (pad * 2),
                h = dirty_rect.h + (pad * 2),
            })
            if self.plugin and self.plugin.ui then
                UIManager:setDirty(self.plugin.ui, function() return "ui", clear_geom end)
            else
                UIManager:setDirty(nil, function() return "ui", clear_geom end)
            end
        end
        UIManager:setDirty(self, function() return "ui", self.popup_rect end)
    else
        self.show_more = true
        self:updateMoreLayout()
        if self.more_popup_rect then
            UIManager:setDirty(self, function() return "ui", self.more_popup_rect end)
        else
            UIManager:setDirty(self, function() return "ui", self.dimen end)
        end
    end
end

-- ---- Ajuste de la selección arrastrando un cursor ----
local function pointInsideMenu(menu, pos)
    if not (pos and menu.popup_rect) then return false end
    if pos:intersectWith(menu.popup_rect) then return true end
    return (menu.show_more and menu.more_popup_rect and pos:intersectWith(menu.more_popup_rect)) and true or false
end

-- Refresca la zona del menú (y de More, si está abierto) para que aparezca o desaparezca
function FloatingActionMenu:_refreshMenuArea()
    local r = self.popup_rect
    if not r then return end
    if self.show_more and self.more_popup_rect then r = r:combine(self.more_popup_rect) end
    local pad = scale(4)
    local region = Geom:new({
        x = math.max(0, r.x - pad), y = math.max(0, r.y - pad), w = r.w + pad * 2, h = r.h + pad * 2,
    })
    local ui = self.plugin and self.plugin.ui
    UIManager:setDirty(ui or self, function() return "ui", region end)
end

function FloatingActionMenu:_curStart(grab)
    if self._cur_drag or not grab or not self._cursor then return false end
    if not self._cursor:beginDrag(grab.which) then return false end
    self._cur_drag = grab
    -- Mientras se arrastra, el menú se oculta para ver el texto
    self._hidden = true
    self:_refreshMenuArea()
    return true
end

function FloatingActionMenu:_curEnd()
    self._cur_drag = nil
    self._cur_grab = nil
    if self._cursor then self._cursor:endDrag() end
    -- La selección cambió (texto, cajas y quizá la posición): se arma un menú nuevo
    UIManager:nextTick(function()
        if self.plugin and self.plugin.reopenSelectionMenu then
            self.plugin:reopenSelectionMenu(self)
        else
            self._hidden = false
            self:_refreshMenuArea()
        end
    end)
end

function FloatingActionMenu:onCurTouch(_arg, ges)
    self._cur_grab = nil
    if not self._cursor or self._cur_drag or not (ges and ges.pos) then return false end
    if pointInsideMenu(self, ges.pos) then return false end
    self._cur_grab = self._cursor:handleAt(ges.pos)
    return false
end

function FloatingActionMenu:onCurPan(_arg, ges)
    if not self._cursor or not (ges and ges.pos) then return false end
    if not self._cur_drag then
        local start = ges.start_pos or ges.pos
        local grab = self._cur_grab
        if not grab and not pointInsideMenu(self, start) then grab = self._cursor:handleAt(start) end
        if not grab or not self:_curStart(grab) then return false end
    end
    self._cursor:moveDrag(self._cur_drag, ges.pos)
    return true
end

function FloatingActionMenu:onCurPanRelease(_arg, ges)
    if not self._cur_drag then return false end
    if ges and ges.pos then self._cursor:moveDrag(self._cur_drag, ges.pos) end
    self:_curEnd()
    return true
end

function FloatingActionMenu:onCurSwipe(_arg, ges)
    if self._cur_drag then
        -- Un gesto rápido cierra el arrastre que ya venía en curso
        if ges and ges.end_pos then self._cursor:moveDrag(self._cur_drag, ges.end_pos) end
        self:_curEnd()
        return true
    end
    if not self._cursor or not (ges and ges.pos) or pointInsideMenu(self, ges.pos) then return false end
    -- Un barrido corto sobre un cursor: lo lleva directo hasta donde terminó
    local grab = self._cursor:handleAt(ges.pos)
    if grab and ges.end_pos and self:_curStart(grab) then
        self._cursor:moveDrag(grab, ges.end_pos)
        self:_curEnd()
        return true
    end
    return false
end

function FloatingActionMenu:onCurHold(_arg, ges)
    if not self._cursor or self._cur_drag or not (ges and ges.pos) then return false end
    if pointInsideMenu(self, ges.pos) then return false end
    local grab = self._cursor:handleAt(ges.pos)
    if grab and self:_curStart(grab) then return true end
    return false
end

function FloatingActionMenu:onCurHoldPan(_arg, ges)
    if self._cur_drag and ges and ges.pos then
        self._cursor:moveDrag(self._cur_drag, ges.pos)
        return true
    end
    return false
end

function FloatingActionMenu:onCurHoldRelease(_arg, ges)
    if not self._cur_drag then return false end
    if ges and ges.pos then self._cursor:moveDrag(self._cur_drag, ges.pos) end
    self:_curEnd()
    return true
end

-- La tarjeta del diccionario usa los mismos gestos de arrastre de cursores que el menú de selección
for _, name in ipairs({ "_refreshMenuArea", "_curStart", "_curEnd", "onCurTouch", "onCurPan", "onCurPanRelease",
        "onCurSwipe", "onCurHold", "onCurHoldPan", "onCurHoldRelease" }) do
    FloatingDictionaryPopup[name] = FloatingActionMenu[name]
end

-- Mientras se arrastra un cursor la tarjeta se oculta para ver el texto
function FloatingDictionaryPopup:paintTo(bb, x, y)
    if self._hidden then return end
    InputContainer.paintTo(self, bb, x, y)
end

function FloatingActionMenu:paintTo(bb, x, y)
    if self._hidden then return end
    if self[1] then
        self[1]:paintTo(bb, x, y)
    end
    if self.show_more and self.more_container then
        self.more_container:paintTo(bb, x, y)
    end
end

function FloatingActionMenu:handleEvent(event)
    if self.show_more and self.more_container then
        if self.more_container:handleEvent(event) then
            return true
        end
    end
    return InputContainer.handleEvent(self, event)
end

-- ==========================================
-- LÓGICA COMPARTIDA DE ACCIONES NATIVAS
-- ==========================================
local function saveCustomHighlightInner(self_obj, style)
    local hl = self_obj.highlight_obj
    if not hl then return end
    
    if type(hl.saveHighlightFormatted) == "function" then
        local saved_color = hl.view and hl.view.highlight and hl.view.highlight.saved_color
        local ok = pcall(function()
            hl:saveHighlightFormatted(true, style, saved_color)
            if hl.clear then hl:clear() end
        end)
        if ok then return end
    end

    local util = require("util")
    local Event = require("ui/event")
    
    local sel = hl.selected_text or {
        pos0 = self_obj.pos0,
        pos1 = self_obj.pos1,
        text = self_obj.text
    }
    if not sel.pos0 or not sel.pos1 then return end
    
    -- FIX 1: Evitar el crash fatal de Lua ("attempt to index a string value").
    -- En EPUBs, pos0 es un texto. Intentar sacarle ".page" rompía todo el plugin.
    local page
    if type(sel.pos0) == "string" then
        page = sel.pos0
    elseif type(sel.pos0) == "table" and sel.pos0.page then
        page = sel.pos0.page
    else
        page = sel.pos0
    end
    
    local saved_color = (hl.view and hl.view.highlight and hl.view.highlight.saved_color) or "yellow"
    
    -- FIX 2: Capturar el capítulo de forma 100% nativa y a prueba de fallos.
    local current_chapter = nil
    pcall(function()
        -- Intento A: Usar la función nativa de KOReader para marcadores
        if hl.ui and type(hl.ui.getBookmarkChapter) == "function" then
            current_chapter = hl.ui:getBookmarkChapter(sel.pos0)
        end
        
        -- Intento B: Si falla, buscar manualmente en el índice usando el número real de página
        if not current_chapter and hl.ui and hl.ui.toc then
            local pageno = 1
            if type(hl.ui.getCurrentPage) == "function" then pageno = hl.ui:getCurrentPage() end
            
            if type(hl.ui.toc.getTocIndexByPage) == "function" then
                local idx = hl.ui.toc:getTocIndexByPage(pageno)
                if idx and hl.ui.toc.toc and type(hl.ui.toc.toc[idx]) == "table" then
                    current_chapter = hl.ui.toc.toc[idx].text or hl.ui.toc.toc[idx].title
                end
            end
        end
    end)
    
    local item = {
        chapter = current_chapter,
        page = page,
        pos0 = sel.pos0,
        pos1 = sel.pos1,
        text = util.cleanupSelectedText(sel.text),
        drawer = style,
        color = saved_color,
    }
    
    if hl.ui and hl.ui.paging then
        item.pboxes = sel.pboxes or self_obj.boxes
        item.ext = sel.ext
        if hl.writePdfAnnotation then pcall(function() hl:writePdfAnnotation("save", item) end) end
    end
    
    local ok, index = pcall(function() return hl.ui.annotation:addItem(item) end)
    if ok and index then
        if hl.view and hl.view.footer and type(hl.view.footer.maybeUpdateFooter) == "function" then
            pcall(function() hl.view.footer:maybeUpdateFooter() end)
        end
        pcall(function() hl.ui:handleEvent(Event:new("AnnotationsModified", { item, nb_highlights_added = 1, index_modified = index })) end)
    end
    if hl.clear then pcall(function() hl:clear() end) end
end

local function saveCustomHighlight(self_obj, style)
    FloatingDictionaryPopup.withRestoredSelection(self_obj, function()
        saveCustomHighlightInner(self_obj, style)
    end)
end

local function invokeAction(self_obj, action_name)
    local hl = self_obj.highlight_obj
    local text = self_obj.text
    local pos0 = self_obj.pos0
    local pos1 = self_obj.pos1
    local boxes = self_obj.boxes

    -- MODO CROP (Ajustar Selección) - La función nativa real
    if action_name == "adjust" then
        if hl and type(hl.startSelection) == "function" then
            hl:startSelection(self_obj.annotation_index)
        end
        local UIManager = require("ui/uimanager")
        UIManager:close(self_obj)
        return
    end

    -- Sincronizamos KOReader para el resto de los botones
    if hl then hl.highlight_menu = nil end
    local UIManager = require("ui/uimanager")
    UIManager:close(self_obj)
    
    UIManager:scheduleIn(0.1, function()
        pcall(function()
            if action_name == "highlight" then
                saveCustomHighlight(self_obj, "lighten")
            elseif action_name == "invert" then
                saveCustomHighlight(self_obj, "invert")
            elseif action_name == "underline" then
                saveCustomHighlight(self_obj, "underscore")
            elseif action_name == "strikethrough" then
                saveCustomHighlight(self_obj, "strikeout")
            elseif action_name == "note" then
                if hl and type(hl.addNote) == "function" then
                    hl:addNote()
                elseif hl and type(hl.onAddNote) == "function" then
                    hl:onAddNote()
                elseif hl and hl.ui and hl.ui.annotation and type(hl.ui.annotation.onAddNote) == "function" then
                    hl.ui.annotation:onAddNote({ pos0 = pos0, pos1 = pos1, text = text, pboxes = boxes })
                end
            elseif action_name == "translate" then
                if hl and hl.translateHighlightedWord then hl:translateHighlightedWord(text) end
                self_obj.plugin.ui:handleEvent(Event:new("LookupTranslation", text))
                self_obj.plugin.ui:handleEvent(Event:new("TranslateText", text))
                self_obj.plugin.ui:handleEvent(Event:new("TranslateWord", text))
            -- El adjust ya se manejó arriba de forma nativa, este bloque queda libre
            elseif action_name == "ai" then
                local assistant = (self_obj.plugin and self_obj.plugin.ui and self_obj.plugin.ui.assistant)
                    or (hl and hl.ui and hl.ui.assistant)
                if assistant and assistant.assistant_dialog then
                    local NetworkMgr = require("ui/network/manager")
                    NetworkMgr:runWhenOnline(function()
                        UIManager:nextTick(function()
                            -- AI Assistant (v1.18) exposes showAskDialog(), not show(); try both.
                            local dlg = assistant.assistant_dialog
                            if dlg.showAskDialog then dlg:showAskDialog(text)
                            elseif dlg.show then dlg:show(text) end
                        end)
                    end)
                else
                    if self_obj.plugin and self_obj.plugin.ui then
                        self_obj.plugin.ui:handleEvent(Event:new("AskAIAssistant", text))
                    end
                end
            elseif action_name == "wiki" then
                -- The popup was already closed above, which clears hl.selected_text,
                -- so hl:lookupWikipedia() would silently no-op. Use the stored text.
                self_obj.plugin.ui:handleEvent(Event:new("LookupWikipedia", text))
            elseif action_name == "search" then
                -- Same as wiki: hl:onHighlightSearch() needs hl.selected_text, already cleared.
                if self_obj.plugin.ui.search and self_obj.plugin.ui.search.searchText then self_obj.plugin.ui.search:searchText(text)
                elseif self_obj.plugin.ui.search then self_obj.plugin.ui.search:onShowFulltextSearchInput(text)
                else self_obj.plugin.ui:handleEvent(Event:new("ShowFulltextSearchInput", text)) end
            elseif action_name == "dict" then
                if self_obj.results and self_obj.plugin.original_showDict then
                    self_obj.plugin.opening_original_popup = true
                    self_obj.plugin.original_showDict(self_obj.plugin.patched_dictionary, text, self_obj.results, boxes)
                    self_obj.plugin.opening_original_popup = false
                elseif self_obj.plugin and self_obj.plugin.ui and self_obj.plugin.ui.dictionary then
                    self_obj.plugin.ui.dictionary:onLookupWord(text, false, boxes, hl)
                end
            elseif action_name == "copy" then
                if hl and type(hl.copyToClipboard) == "function" then
                    hl:copyToClipboard(text)
                elseif hl and type(hl.onCopy) == "function" then
                    hl:onCopy()
                else
                    local ok_dev, Dev = pcall(require, "device")
                    if ok_dev and Dev and Dev.setClipboardText then
                        Dev.setClipboardText(text)
                    end
                end
                local ok_notif, Notification = pcall(function() return require("ps_dialogs").Notification end)
                if ok_notif and Notification then
                    local _ = require("ps_i18n").gettext
                    UIManager:show(Notification:new{ text = _("Copied to clipboard") })
                end
                if hl and hl.clear then pcall(function() hl:clear() end) end
            elseif action_name == "share" then
                if hl and type(hl.onShare) == "function" then
                    hl:onShare()
                elseif self_obj.plugin and self_obj.plugin.ui then
                    self_obj.plugin.ui:handleEvent(Event:new("ShareText", text))
                end
            elseif action_name == "html" then
                if hl and type(hl.onViewHtml) == "function" then
                    hl:onViewHtml()
                elseif self_obj.plugin and self_obj.plugin.ui then
                    self_obj.plugin.ui:handleEvent(Event:new("ViewHTML", text))
                    self_obj.plugin.ui:handleEvent(Event:new("ViewSource", text))
                end
            end
        end)
    end)
end

-- LÓGICA DE PULSACIÓN LARGA (Selector de colores de KOReader)
-- Mantener apretado Resaltar / Subrayar / Tachar abre el selector de colores. Primero se intenta el
-- ButtonSelector nativo; en algunas versiones de KOReader falla al crearse ("bad argument #1 to 'unpack'"),
-- así que si eso pasa se usa un selector propio (3x3) con los mismos colores de KOReader.
-- Al elegir un color se guarda con el guardado nativo (ReaderHighlight:saveHighlight), con ese estilo y color,
-- sin tocar el color por defecto de KOReader.
local HOLD_STYLE = { highlight = "lighten", underline = "underscore", strikethrough = "strikeout" }

-- Relleno redondeado a todo color. En pantallas a color el relleno hay que pintarlo con blendRectRGB32
-- (paintRect pierde el color y lo deja en gris); en pantallas B/N se usa el pintado normal.
local function paintColorFill(bb, x, y, w, h, r, color)
    if w <= 0 or h <= 0 then return end
    if not (bb.blendRectRGB32 or bb.paintRectRGB32) then
        paintCornerRect(bb, x, y, w, h, r, color, true, true, true, true)
        return
    end
    r = math.min(r, math.floor(w / 2), math.floor(h / 2))
    local function paint(px, py, pw, ph)
        if bb.blendRectRGB32 then bb:blendRectRGB32(px, py, pw, ph, color)
        else bb:paintRectRGB32(px, py, pw, ph, color) end
    end
    if r <= 0 then paint(x, y, w, h); return end
    paint(x + r, y, w - 2 * r, h)
    paint(x, y + r, r, math.max(1, h - 2 * r))
    paint(x + w - r, y + r, r, math.max(1, h - 2 * r))
    for j = 0, r - 1 do
        local arc = math.ceil(math.sqrt(r * r - (r - j - 0.5) * (r - j - 0.5)))
        if arc > 0 then
            paint(x + r - arc, y + j, arc, 1)
            paint(x + w - r,   y + j, arc, 1)
            paint(x + r - arc, y + h - 1 - j, arc, 1)
            paint(x + w - r,   y + h - 1 - j, arc, 1)
        end
    end
end

local ColorSwatchPopup = InputContainer:extend({
    values = nil,      -- { { nombre, clave, color }, ... } (formato de ReaderHighlight:getHighlightColorList)
    current = nil,     -- clave del color actual (se remarca)
    on_select = nil,   -- function(clave)
    on_cancel = nil,   -- function()
    anchor_fn = nil,   -- function() -> { y = ... }, pop_down  (posición nativa de diálogos, opcional)
})

function ColorSwatchPopup:init()
    self.modal = true
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new({ x = 0, y = 0, w = sw, h = sh })

    local cols = 3
    -- Solo entradas válidas: { nombre, clave, color }
    local clean = {}
    for _, v in ipairs(self.values or {}) do
        if type(v) == "table" and type(v[2]) == "string" then table.insert(clean, v) end
    end
    self.values = clean
    local n = #clean
    local rows = math.max(1, math.ceil(n / cols))
    self.cols = cols
    -- POPUP_K achica todo el menu de colores (tamanos y fuente) en bloque; 1.0 = tamano anterior.
    -- El contorno (border / anillos) no se toca para conservar el grosor de linea.
    local POPUP_K = 0.75
    local function sk(v) return math.max(1, math.floor(scale(v) * POPUP_K + 0.5)) end
    self.pad = sk(14)
    self.cell_w = sk(104)
    self.cell_h = sk(98)
    self.circle_d = sk(50)
    self.border = math.max(2, scale(2.2))
    self.outer_halo = math.max(2, scale(3))
    self.radius = sk(12)
    local font_sz = math.max(8, math.floor(scaleText(17) * POPUP_K + 0.5))

    -- Los nombres de los colores cambian de largo según el idioma ("Verde oliva", "Amarillo"...): se mide el más
    -- ancho (en negrita, que es como se marca el actual) y, si no entra, primero se ensancha la celda y después,
    -- si hace falta, se achica la letra, para que los textos de celdas vecinas nunca se pisen.
    local function measure(face, text)
        local tw = TextWidget:new({ text = text, face = face, bold = true })
        local sz = tw:getSize()
        tw:free()
        return sz.w, sz.h
    end
    local max_cell_w = math.floor((sw - scale(16) - self.pad * 2) / cols)   -- tope: que el popup entre en pantalla
    local label_gap = scale(6)
    local face, widest, label_h
    while true do
        face = Font:getFace("cfont", font_sz)
        widest, label_h = 0, 0
        for _, v in ipairs(clean) do
            local lw, lh = measure(face, tostring(v[1] or v[2] or ""))
            if lw > widest then widest = lw end
            if lh > label_h then label_h = lh end
        end
        if widest + scale(8) <= max_cell_w or font_sz <= 8 then break end
        font_sz = font_sz - 1
    end
    self.face = face
    self.label_gap = label_gap
    self.cell_w = math.max(self.cell_w, math.min(max_cell_w, widest + scale(10)))
    -- Alto de la celda según el alto real del texto: círculo + aire + texto + aire (las filas no se solapan)
    self.cell_h = math.max(self.cell_h, scale(4) + self.circle_d + label_gap + label_h + scale(8))

    local halo = self.outer_halo or 0
    local w = cols * self.cell_w + (self.pad + halo) * 2
    local h = rows * self.cell_h + (self.pad + halo) * 2
    self._content_w, self._content_h = w, h
    local x = math.floor((sw - w) / 2)
    local y = math.floor((sh - h) / 2)

    -- Misma posición que usan los diálogos nativos de resaltado (arriba / centro / abajo / junto al texto)
    if self.anchor_fn then
        local ok, anchor, pop_down = pcall(self.anchor_fn, self)
        if ok and type(anchor) == "table" then
            if anchor.is_vertical and anchor.menu_rect then
                y = anchor.y - math.floor(h / 2)
                if anchor.pos_pref == "left_v" then
                    x = anchor.menu_rect.x + anchor.menu_rect.w + scale(6)
                else
                    x = anchor.menu_rect.x - w - scale(6)
                end
            elseif anchor.x and anchor.y then
                x = anchor.x - math.floor(w / 2)
                if pop_down == true then
                    y = anchor.y                 -- el diálogo se despliega hacia abajo desde y
                elseif pop_down == false then
                    y = anchor.y - h             -- el diálogo se despliega hacia arriba hasta y
                else
                    y = anchor.y                 -- "arriba" / "abajo" de la pantalla (se acota más abajo)
                end
            elseif anchor.y then
                if pop_down == true then
                    y = anchor.y
                elseif pop_down == false then
                    y = anchor.y - h
                else
                    y = anchor.y
                end
            end
        end
    end
    
    x = math.max(scale(8), math.min(x, sw - w - scale(8)))
    y = math.max(scale(8), math.min(y, sh - h - scale(8)))

    self.card_rect = Geom:new({ x = x, y = y, w = w, h = h })

    self.cells = {}
    for i, v in ipairs(self.values or {}) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        self.cells[i] = {
            name = tostring(v[1] or v[2] or ""),
            key = v[2],
            color = v[3],
            dimen = Geom:new({
                x = x + self.pad + col * self.cell_w,
                y = y + self.pad + row * self.cell_h,
                w = self.cell_w, h = self.cell_h,
            }),
        }
    end

    if Device:isTouchDevice() then
        self.ges_events = {
            Tap   = { GestureRange:new({ ges = "tap",   range = self.dimen }) },
            Hold  = { GestureRange:new({ ges = "hold",  range = self.dimen }) },
            HoldRelease = { GestureRange:new({ ges = "hold_release", range = self.dimen }) },
            Swipe = { GestureRange:new({ ges = "swipe", range = self.dimen }) },
        }
    end
end

-- Algunas posiciones nativas (junto al texto) necesitan conocer el alto del diálogo
function ColorSwatchPopup:getContentSize()
    return Geom:new({ w = self._content_w or 0, h = self._content_h or 0 })
end

function ColorSwatchPopup:onHold() return true end
function ColorSwatchPopup:onHoldRelease() return true end
function ColorSwatchPopup:onSwipe() return true end

function ColorSwatchPopup:onShow()
    UIManager:setDirty(self, function() return "ui", self.card_rect end)
end

function ColorSwatchPopup:paintTo(bb, x, y)
    -- Un error de pintado dentro del bucle de UI tumba KOReader: lo atajamos y cerramos el selector
    local ok, err = pcall(function()
        local r = self.card_rect
        local halo = self.outer_halo or 0
        if halo > 0 then
            paintCornerRect(bb, r.x, r.y, r.w, r.h, self.radius + halo, Blitbuffer.COLOR_WHITE, true, true, true, true)
        end
        local bx, by = r.x + halo, r.y + halo
        local bw, bh = r.w - halo * 2, r.h - halo * 2
        paintCornerRect(bb, bx, by, bw, bh, self.radius, Blitbuffer.COLOR_BLACK, true, true, true, true)
        paintCornerRect(bb, bx + self.border, by + self.border, bw - self.border * 2, bh - self.border * 2,
            math.max(1, self.radius - self.border), Blitbuffer.COLOR_WHITE, true, true, true, true)

        for _, cell in ipairs(self.cells) do
            local d = self.circle_d
            local cx = cell.dimen.x + math.floor((cell.dimen.w - d) / 2)
            local cy = cell.dimen.y + scale(4)
            local is_current = (self.current ~= nil and cell.key == self.current)

            local outer_ring = is_current and math.max(2, scale(2)) or math.max(1, scale(1))
            local outer_col = is_current and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY
            paintCornerRect(bb, cx, cy, d, d, math.floor(d / 2), outer_col, true, true, true, true)

            local gap = is_current and math.max(2, scale(2)) or 0
            if gap > 0 then
                local wd = d - outer_ring * 2
                paintCornerRect(bb, cx + outer_ring, cy + outer_ring, wd, wd, math.floor(wd / 2), Blitbuffer.COLOR_WHITE, true, true, true, true)
            end

            local inset = outer_ring + gap
            local inner = d - inset * 2
            local fill = cell.color or Blitbuffer.COLOR_GRAY
            local ok_fill = pcall(function()
                paintColorFill(bb, cx + inset, cy + inset, inner, inner, math.floor(inner / 2), fill)
            end)
            if not ok_fill then
                paintCornerRect(bb, cx + inset, cy + inset, inner, inner, math.floor(inner / 2), Blitbuffer.COLOR_GRAY, true, true, true, true)
            end

            -- max_width + "…" como último recurso: nunca invade la celda de al lado
            local tw = TextWidget:new({
                text = cell.name, face = self.face, fgcolor = Blitbuffer.COLOR_BLACK, bold = is_current,
                max_width = cell.dimen.w - scale(2), truncate_with_ellipsis = true,
            })
            local tsz = tw:getSize()
            tw:paintTo(bb, cell.dimen.x + math.floor((cell.dimen.w - tsz.w) / 2), cy + d + (self.label_gap or scale(6)))
            tw:free()
        end
    end)
    if not ok and not self._paint_failed then
        self._paint_failed = true
        local ok_log, logger = pcall(require, "logger")
        if ok_log and logger then logger.warn("floating_dict: error pintando el selector de colores:", err) end
        UIManager:scheduleIn(0, function()
            UIManager:close(self)
            if self.on_cancel then pcall(self.on_cancel) end
        end)
    end
end

function ColorSwatchPopup:onTap(_arg, ges)
    if not (ges and ges.pos) then return true end
    if not ges.pos:intersectWith(self.card_rect) then
        UIManager:close(self)
        if self.on_cancel then self.on_cancel() end
        return true
    end
    for _, cell in ipairs(self.cells) do
        if ges.pos:intersectWith(cell.dimen) then
            UIManager:close(self)
            if self.on_select then self.on_select(cell.key) end
            return true
        end
    end
    return true
end

function ColorSwatchPopup:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.card_rect end)
end

-- Lista { { nombre, clave, color }, ... } armada a partir de la paleta de KOReader.
-- No usamos hl:getHighlightColorList(): en algunas versiones devuelve entradas que no son tablas
-- (ButtonSelector falla con "bad argument #1 to 'unpack' (table expected, got cdata)").
local function buildColorValues(hl)
    local gt = require("ps_i18n").gettext
    local base = hl.highlight_colors
    if type(base) ~= "table" or #base == 0 then
        base = {
            { gt("Red"), "red" }, { gt("Orange"), "orange" }, { gt("Yellow"), "yellow" },
            { gt("Green"), "green" }, { gt("Olive"), "olive" }, { gt("Cyan"), "cyan" },
            { gt("Blue"), "blue" }, { gt("Purple"), "purple" }, { gt("Gray"), "gray" },
        }
    end
    local list = {}
    for _, c in ipairs(base) do
        if type(c) == "table" and type(c[2]) == "string" then
            local key = c[2]
            local color
            if type(hl.getHighlightColor) == "function" then
                local ok, col = pcall(hl.getHighlightColor, hl, key, nil, true)
                if ok then color = col end
            end
            local custom = type(hl.custom_colors) == "table" and hl.custom_colors[key]
            local name = (type(custom) == "table" and custom.name) or c[1] or key
            table.insert(list, { tostring(name), key, color })
        end
    end
    return list
end

local function invokeHoldAction(self_obj, action_name, anchor_pos)
    local hl = self_obj.highlight_obj
    if not hl then return end

    -- Solo para acciones de resaltado/dibujado (invert no admite color)
    local style = HOLD_STYLE[action_name]
    if not style then return end

    local UIManager = require("ui/uimanager")
    local ok_log, logger = pcall(require, "logger")
    local function warn(...) if ok_log and logger then logger.warn(...) end end
    local function info(...) if ok_log and logger then logger.info(...) end end

    info("floating_dict: hold en", action_name)

    if type(hl.saveHighlight) ~= "function" then
        -- Esta versión de KOReader no tiene el guardado nativo: se comporta como un toque normal
        warn("floating_dict: no existe saveHighlight, se guarda con el color por defecto")
        self_obj:invokeNative(action_name)
        return
    end

    -- Selección a guardar (si KOReader ya la limpió, usamos la copia que guardó el menú al abrirse)
    local sel = hl.selected_text or self_obj.selected_text
    if not (sel and sel.pos0 and sel.pos1) then
        warn("floating_dict: no hay selección para resaltar")
        return
    end
    hl.selected_text = sel

    local values_ok, values = pcall(buildColorValues, hl)
    if not values_ok or type(values) ~= "table" or #values == 0 then
        warn("floating_dict: no se pudo armar la paleta de colores:", values)
        self_obj:invokeNative(action_name)
        return
    end
    info("floating_dict: paleta con", #values, "colores")

    local current = hl.view and hl.view.highlight and hl.view.highlight.saved_color

    -- El menú flotante se cierra recién al elegir un color o al cancelar
    local function closeMenu()
        pcall(function() UIManager:close(self_obj) end)
    end

    local function finish(color_name)
        closeMenu()
        -- Con selecciones largas (p. ej. un parrafo entero) saveHighlight(true) puede extender la seleccion
        -- a oracion y trabajar sobre una tabla NUEVA que no trae drawer/color, y entonces usa los valores por
        -- defecto de KOReader (amarillo / lighten). Por eso, ademas de marcar selected_text, fijamos
        -- temporalmente el estilo y color por defecto durante el guardado y despues los restauramos.
        local vh = hl.view and hl.view.highlight
        local old_saved_drawer, old_saved_color
        if vh then
            old_saved_drawer, old_saved_color = vh.saved_drawer, vh.saved_color
            vh.saved_drawer = style
            if color_name then vh.saved_color = color_name end
        end
        local ok, err = pcall(function()
            if not hl.selected_text then hl.selected_text = sel end
            hl.selected_text.drawer = style
            if color_name then hl.selected_text.color = color_name end
            local saved_index = hl:saveHighlight(true)
            -- Verificacion: si el item guardado quedo con otro estilo/color, se corrige
            local annotation = hl.ui and hl.ui.annotation
            local item = type(saved_index) == "number" and annotation and annotation.annotations
                and annotation.annotations[saved_index]
            if type(item) == "table" then
                local wrong_style = item.drawer ~= style
                local wrong_color = color_name and item.color ~= color_name
                if wrong_style or wrong_color then
                    info("floating_dict: corrigiendo highlight guardado:", item.drawer, item.color, "->", style, color_name)
                    item.drawer = style
                    if color_name then item.color = color_name end
                    pcall(function() UIManager:setDirty("all", "ui") end)
                end
            end
            hl:clear()
        end)
        if vh then
            vh.saved_drawer, vh.saved_color = old_saved_drawer, old_saved_color
        end
        if not ok then
            warn("floating_dict: no se pudo guardar el highlight con color:", err)
            pcall(function() hl:clear() end)
        end
    end

    local function cancel()
        -- Al cancelar el menú de colores, NO cerramos el menú flotante principal
        -- ni limpiamos la selección, para que el texto siga marcado y el menú abierto.
    end

    local color_selector

    local function anchor_for(widget)
        if anchor_pos and self_obj.popup_rect then
            local rect = self_obj.popup_rect
            if self_obj._is_horizontal then
                if self_obj._grow_up then
                    return { x = anchor_pos.x, y = rect.y - scale(6) }, false
                else
                    return { x = anchor_pos.x, y = rect.y + rect.h + scale(6) }, true
                end
            else
                return { x = anchor_pos.x, y = anchor_pos.y, is_vertical = true, menu_rect = rect, pos_pref = self_obj._pos_pref }, false
            end
        end

        if type(hl._getDialogAnchor) ~= "function" then return nil end
        local ok_a, anchor, pop_down = pcall(function() return hl:_getDialogAnchor(widget) end)
        if ok_a then return anchor, pop_down end
        return nil
    end

    -- 1) Selector con círculos de colores
    local shown = false
    do
        local ok, err = pcall(function()
            local popup = ColorSwatchPopup:new{
                values = values,
                current = current,
                on_select = finish,
                on_cancel = cancel,
                anchor_fn = anchor_for,
            }
            UIManager:show(popup)
        end)
        shown = ok
        if ok then
            info("floating_dict: selector de círculos abierto")
        else
            warn("floating_dict: el selector de círculos falló, se prueba el nativo:", err)
        end
    end

    -- 2) Respaldo: selector nativo de KOReader (ButtonSelector)
    if not shown then
        local ok_bs, ButtonSelector = pcall(require, "ui/widget/buttonselector")
        if ok_bs and ButtonSelector then
            local ok, err = pcall(function()
                color_selector = ButtonSelector:new{
                    current_value = current,
                    values = values,
                    callback = function(selected_color_name) finish(selected_color_name) end,
                    -- Tocar afuera cancela: se deselecciona el texto sin guardar nada
                    tap_close_callback = cancel,
                    anchor = function() return anchor_for(color_selector) end,
                }
                UIManager:show(color_selector)
            end)
            if ok then
                info("floating_dict: selector nativo abierto")
            else
                -- Si no hay forma de mostrar un selector, el menú flotante queda como estaba
                warn("floating_dict: no se pudo abrir ningún selector de colores:", err)
                if color_selector then pcall(function() UIManager:close(color_selector) end) end
            end
        end
    end
end

-- ==========================================
-- MENÚ AL TOCAR UN HIGHLIGHT
-- ==========================================
-- Una píldora chica y simple junto al highlight tocado: borrar, estilo, nota, copiar y More.
-- "Estilo" cambia la misma píldora por una fila con los 4 estilos (el actual marcado) y, a la
-- derecha, un círculo con el color del highlight; tocarlo abre el selector de colores.
-- Reemplaza al diálogo nativo (ReaderHighlight:showHighlightDialog) solo si el ajuste está activado.

-- Botón con fondo negro sólido al ras del borde e ícono invertido en blanco cuando es la opción actual
local SelButton = PreviewButton:extend({
    selected = false,
    round_left = false,
    round_right = false,
    corner_radius = 0,
})
function SelButton:paintTo(bb, x, y)
    PreviewButton.paintTo(self, bb, x, y)
    if self.selected and self.dimen then
        local bx = x
        local by = y
        local bw = self.dimen.w
        local bh = self.dimen.h
        local r = math.min(self.corner_radius or 0, math.floor(math.min(bw, bh) / 2))
        if bw > 0 and bh > 0 then
            pcall(function()
                bb:invertRect(bx, by, bw, bh)
                if r > 0 and (self.round_left or self.round_right) then
                    for dy = 0, r - 1 do
                        local y_dist = r - 0.5 - dy
                        local x_dist = math.sqrt(math.max(0, r * r - y_dist * y_dist))
                        local dx = math.floor(r - x_dist + 0.5)
                        if dx > 0 then
                            if self.round_left then
                                bb:paintRect(bx, by + dy, dx, 1, Blitbuffer.COLOR_BLACK)
                                bb:paintRect(bx, by + bh - 1 - dy, dx, 1, Blitbuffer.COLOR_BLACK)
                            end
                            if self.round_right then
                                bb:paintRect(bx + bw - dx, by + dy, dx, 1, Blitbuffer.COLOR_BLACK)
                                bb:paintRect(bx + bw - dx, by + bh - 1 - dy, dx, 1, Blitbuffer.COLOR_BLACK)
                            end
                        end
                    end
                end
            end)
        end
    end
end

-- Botón que muestra un círculo con el color del highlight (doble anillo estilo Apple / Kindle)
local ColorDotButton = PreviewButton:extend({ color = nil })
function ColorDotButton:paintTo(bb, x, y)
    PreviewButton.paintTo(self, bb, x, y)
    if not self.dimen then return end
    local w, h = self.dimen.w, self.dimen.h
    local d = math.floor(math.min(w, h) * 0.54)
    local cx = x + math.floor((w - d) / 2)
    local cy = y + math.floor((h - d) / 2)
    local outer_ring = math.max(1, scale(1.5))
    local white_gap = math.max(1, scale(1.5))
    paintCornerRect(bb, cx, cy, d, d, math.floor(d / 2), Blitbuffer.COLOR_BLACK, true, true, true, true)
    local wd = d - outer_ring * 2
    paintCornerRect(bb, cx + outer_ring, cy + outer_ring, wd, wd, math.floor(wd / 2), Blitbuffer.COLOR_WHITE, true, true, true, true)
    local inset = outer_ring + white_gap
    local inner = d - inset * 2
    local ok = pcall(function()
        paintColorFill(bb, cx + inset, cy + inset, inner, inner, math.floor(inner / 2), self.color or Blitbuffer.COLOR_GRAY)
    end)
    if not ok then
        paintCornerRect(bb, cx + inset, cy + inset, inner, inner, math.floor(inner / 2), Blitbuffer.COLOR_GRAY, true, true, true, true)
    end
end

local HighlightTapMenu = InputContainer:extend({
    hl = nil, plugin = nil, index = nil, tap_pos = nil,
    mode = "main",   -- "main" | "style"
})

function HighlightTapMenu:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new({ x = 0, y = 0, w = sw, h = sh })
    -- Cursores en los bordes del highlight: arrastrarlos cambia dónde empieza y termina
    local cursor = self.plugin and self.plugin.cursor
    if cursor and cursor:isEnabled() then self._cursor = cursor end
    if self.plugin then self.plugin.active_hl_menu = self end
    if Device:isTouchDevice() then
        self.ges_events = { TapClose = { GestureRange:new({ ges = "tap", range = self.dimen }) } }
        if self._cursor then
            local function on(ges) return { GestureRange:new({ ges = ges, range = self.dimen }) } end
            self.ges_events.CurTouch = on("touch")
            self.ges_events.CurPan = on("pan")
            self.ges_events.CurPanRelease = on("pan_release")
            self.ges_events.CurSwipe = on("swipe")
            self.ges_events.CurHold = on("hold")
            self.ges_events.CurHoldPan = on("hold_pan")
            self.ges_events.CurHoldRelease = on("hold_release")
        end
    end
    self:build()
end

function HighlightTapMenu:getItem()
    local ann = self.hl and self.hl.ui and self.hl.ui.annotation
    return ann and ann.annotations and ann.annotations[self.index]
end

-- Cajas en pantalla del highlight (una por línea), o nil si no se pueden calcular
function HighlightTapMenu:getLines()
    local item = self:getItem()
    local ui = self.plugin and self.plugin.ui
    if not (SelectionCursor and ui and item) then return nil end
    local ok, lines = pcall(SelectionCursor.selectionLines, ui, item)
    if ok then return lines end
    return nil
end

function HighlightTapMenu:build()
    local ui_instance = self.plugin and self.plugin.ui
    local item = self:getItem()
    local raw_fs = getBookRawFontSize(ui_instance) or 26
    local font_ratio = math.max(0.85, math.min(1.40, raw_fs / 26))
    local icon_sz = sscale(22)
    local btn_w, btn_h = sscale(45), sscale(36)
    local text_fs = math.floor(scaleText(12) * getSelSizeK() * font_ratio + 0.5)
    local card_border = sscale(SEL_BORDER_PX)
    local card_radius = math.floor(sscale(10) * font_ratio + 0.5)
    local inner_radius = math.max(0, card_radius - card_border)
    local current_drawer = (item and item.drawer) or "lighten"
    local is_main_hl = (current_drawer ~= "underscore" and current_drawer ~= "strikeout" and current_drawer ~= "invert")

    local specs
    if self.mode == "style" then
        specs = {
            { svg = "chevron-left.svg", text = "<", w = sscale(40), icon_sz = sscale(20), callback = function() self:switchMode("main") end },
            { svg = "droplet.svg", text = "HL", selected = is_main_hl, callback = function() self:applyChange("drawer", "lighten") end },
            { svg = "underline.svg", text = "Und", selected = (current_drawer == "underscore"), callback = function() self:applyChange("drawer", "underscore") end },
            { svg = "strikethrough.svg", text = "Str", selected = (current_drawer == "strikeout"), callback = function() self:applyChange("drawer", "strikeout") end },
            { svg = "contrast.svg", text = "Inv", selected = (current_drawer == "invert"), callback = function() self:applyChange("drawer", "invert") end },
        }
        -- "invert" no admite color
        if current_drawer ~= "invert" then
            local color_key = (item and item.color) or "gray"
            local color
            pcall(function()
                for _, v in ipairs(buildColorValues(self.hl)) do
                    if v[2] == color_key then color = v[3]; break end
                end
            end)
            table.insert(specs, { dot = true, color = color, callback = function() self:openColors() end })
        end
    else
        -- Note: fondo negro (como un botón seleccionado) si el highlight ya tiene nota; sin fondo si no
        local note_txt = item and item.note
        local has_note = type(note_txt) == "string" and note_txt:match("%S") ~= nil
        specs = {
            { svg = "highlighter.svg", text = "Style", selected = true, callback = function() self:switchMode("style") end },
            { svg = "notepad-text.svg", text = "Note", selected = has_note, callback = function() self:doNote() end },
            { svg = "copy.svg", text = "Copy", callback = function() self:doCopy() end },
            { svg = "trash-2.svg", text = "Del", callback = function() self:doDelete() end },
            { svg = "more.svg", text = "...", callback = function() self:doMore() end },
        }
    end

    local widgets = {}
    for idx, spec in ipairs(specs) do
        local path = (not spec.dot) and getValidSvgPath(spec.svg) or nil
        local use_text = (not spec.dot) and not path
        local cls = spec.dot and ColorDotButton or SelButton
        table.insert(widgets, cls:new({
            icon_svg = path,
            icon_char = spec.dot and " " or nil,
            icon_size = spec.icon_sz or icon_sz,
            text = use_text and spec.text or nil,
            font_size = text_fs,
            face = use_text and getBookFace(ui_instance, text_fs, true) or nil,
            width = spec.w or btn_w,
            height = btn_h,
            always_show_text = false,
            show_parent = self,
            callback = spec.callback,
            selected = spec.selected,
            round_left = (idx == 1),
            round_right = (idx == #specs),
            corner_radius = inner_radius,
            color = spec.color,
        }))
    end

    local row = HorizontalGroup:new(widgets)

    self.card = FloatingPillCard:new({
        content = row,
        bordersize = card_border,
        radius = card_radius,
    })
    local size = self.card:getSize()

    -- Junto al highlight: arriba si hay lugar, si no abajo; centrado donde se tocó
    local lines = self:getLines()
    local tapped
    if lines and self.tap_pos then
        local best_d
        for _, l in ipairs(lines) do
            local d = 0
            if self.tap_pos.y < l.y then d = l.y - self.tap_pos.y
            elseif self.tap_pos.y > l.y + l.h then d = self.tap_pos.y - (l.y + l.h) end
            if not best_d or d < best_d then tapped, best_d = l, d end
        end
    end
    local cx = self.tap_pos and self.tap_pos.x or nil
    -- Con cursores, el aro de cada extremo sobresale: se deja aire para no taparlo
    local gap = scale(10)
    if lines and self._cursor then
        gap = math.max(gap, 2 * SelectionCursor.knobRadius(lines) + scale(8))
    end
    local x, y, grow_up = placeNearLines(size.w, size.h, lines, {
        gap = gap, cx_top = cx, cx_bottom = cx, tapped = tapped,
    })
    self._grow_up = grow_up
    self.popup_rect = Geom:new({ x = x, y = y, w = size.w, h = size.h })
    self[1] = VerticalGroup:new({
        align = "left",
        VerticalSpan:new({ width = math.max(0, math.floor(y)) }),
        HorizontalGroup:new({
            HorizontalSpan:new({ width = math.max(0, math.floor(x)) }),
            self.card,
        }),
    })
end

-- Cambia entre la fila principal y la de estilos sin mover el menú de lugar
function HighlightTapMenu:switchMode(mode)
    local old = self.popup_rect
    self.mode = mode
    self:build()
    local region = self.popup_rect
    if old then
        local pad = scale(4)
        local x0, y0 = math.min(old.x, region.x) - pad, math.min(old.y, region.y) - pad
        local x1 = math.max(old.x + old.w, region.x + region.w) + pad
        local y1 = math.max(old.y + old.h, region.y + region.h) + pad
        region = Geom:new({ x = math.max(0, x0), y = math.max(0, y0), w = x1 - math.max(0, x0), h = y1 - math.max(0, y0) })
    end
    local ui = self.plugin and self.plugin.ui
    -- primero la página de abajo (borra la píldora vieja), después el menú
    UIManager:setDirty(ui or self, function() return "ui", region end)
    UIManager:setDirty(self, function() return "ui", region end)
end

function HighlightTapMenu:closeMenu()
    local r = self.popup_rect
    if r then
        local pad = scale(4)
        UIManager:close(self, "ui", Geom:new({
            x = math.max(0, r.x - pad), y = math.max(0, r.y - pad), w = r.w + pad * 2, h = r.h + pad * 2,
        }))
    else
        UIManager:close(self)
    end
end

function HighlightTapMenu:onShow()
    UIManager:setDirty(self, function() return "ui", self.popup_rect end)
    if self._cursor then
        self._cursor.annotation = self:getItem()
        self._cursor:setPhase("menu")
    end
end

function HighlightTapMenu:onCloseWidget()
    if self.plugin and self.plugin.active_hl_menu == self then self.plugin.active_hl_menu = nil end
    -- Los cursores se van con el menú (salvo que se esté rearmando tras ajustar el highlight)
    if self._cursor and self._cursor.phase and not self._keep_cursor then self._cursor:setPhase(nil) end
end

function HighlightTapMenu:paintTo(bb, x, y)
    if self._hidden then return end
    if self[1] then self[1]:paintTo(bb, x, y) end
end

function HighlightTapMenu:onTapClose(_arg, ges)
    if ges and ges.pos and self.popup_rect and not ges.pos:intersectWith(self.popup_rect) then
        -- Un toque justo sobre un cursor no cierra el menú (se ajusta arrastrando)
        if self._cursor and self._cursor:handleAt(ges.pos) then return true end
        self:closeMenu()
        return true
    end
    return false
end

-- Arrastre de cursores: mismos gestos que el menú de selección
for _, name in ipairs({ "_refreshMenuArea", "_curStart", "onCurTouch", "onCurPan", "onCurPanRelease",
        "onCurSwipe", "onCurHold", "onCurHoldPan", "onCurHoldRelease" }) do
    HighlightTapMenu[name] = FloatingActionMenu[name]
end

function HighlightTapMenu:_curEnd()
    self._cur_drag = nil
    self._cur_grab = nil
    if self._cursor then self._cursor:endDrag() end
    UIManager:nextTick(function() self:commitCursorEdit() end)
end

-- Guarda los nuevos bordes del highlight. Se agrega uno nuevo (queda bien ordenado entre los demás) y
-- recién entonces se borra el viejo; si algo falla, el highlight original no se toca.
function HighlightTapMenu:commitCursorEdit()
    local hl, plugin = self.hl, self.plugin
    local ui = hl and hl.ui
    local ann = ui and ui.annotation
    -- Vuelve a mostrar el highlight original (el cursor lo oculta mientras se arrastra) antes de copiarlo
    if self._cursor then self._cursor:restoreDragStyle() end
    local item = self:getItem()
    local sel = hl and hl.selected_text
    local new_index
    if ann and item and sel and sel.pos0 and sel.pos1 and sel.text and sel.text ~= "" then
        local ok, err = pcall(function()
            local util = require("util")
            local new_item = util.tableDeepCopy(item)
            new_item.pos0, new_item.pos1 = sel.pos0, sel.pos1
            new_item.text = util.cleanupSelectedText(sel.text)
            if type(sel.pos0) == "table" and sel.pos0.page then new_item.page = sel.pos0.page else new_item.page = sel.pos0 end
            if ui.paging then
                new_item.pboxes = sel.pboxes
                new_item.ext = sel.ext
                if hl.writePdfAnnotation then pcall(function() hl:writePdfAnnotation("save", new_item) end) end
            end
            local idx = ann:addItem(new_item)
            if not idx then return end
            local old_i
            for i, a in ipairs(ann.annotations) do
                if a == item then old_i = i; break end
            end
            if old_i then
                hl:deleteHighlight(old_i)
                if old_i < idx then idx = idx - 1 end
            end
            new_index = idx
            pcall(function() ui:handleEvent(Event:new("AnnotationsModified", { new_item, index_modified = idx })) end)
        end)
        if not ok then logger.warn("PageScrubber: no se pudo ajustar el highlight:", err) end
    end
    pcall(function() hl:clear() end)
    self._keep_cursor = new_index ~= nil
    UIManager:close(self)
    if new_index then
        -- El menú vuelve, ahora con los bordes nuevos
        UIManager:show(HighlightTapMenu:new({ hl = hl, plugin = plugin, index = new_index, mode = self.mode }))
    end
end

-- Cambia el estilo o el color del highlight (misma técnica que el split: se modifica la anotación,
-- se guarda y se avisa a KOReader para que redibuje)
function HighlightTapMenu:applyChange(field, value)
    local hl = self.hl
    local item = self:getItem()
    self:closeMenu()
    if not item then return end
    local ui = hl and hl.ui
    item[field] = value
    pcall(function()
        if ui.annotation and ui.annotation.saveAnnotations then ui.annotation:saveAnnotations() end
    end)
    pcall(function()
        ui:handleEvent(Event:new("AnnotationsModified", { item, index_modified = self.index }))
        ui:handleEvent(Event:new("RedrawCurrentPage"))
    end)
    pcall(function() UIManager:setDirty(ui, "ui") end)
end

function HighlightTapMenu:openColors()
    local hl = self.hl
    local item = self:getItem()
    if not item then return end
    local ok_v, values = pcall(buildColorValues, hl)
    if not ok_v or type(values) ~= "table" or #values == 0 then return end
    local rect = self.popup_rect
    local grow_up = self._grow_up
    local ok, err = pcall(function()
        UIManager:show(ColorSwatchPopup:new({
            values = values,
            current = item.color or "gray",
            on_select = function(key) self:applyChange("color", key) end,
            on_cancel = function() end,
            anchor_fn = function()
                local ax = rect.x + math.floor(rect.w / 2)
                if grow_up then
                    return { x = ax, y = rect.y - scale(6) }, false
                end
                return { x = ax, y = rect.y + rect.h + scale(6) }, true
            end,
        }))
    end)
    if not ok then
        local ok_log, logger_mod = pcall(require, "logger")
        if ok_log and logger_mod then logger_mod.warn("floating_dict: no se pudo abrir el selector de colores del highlight:", err) end
    end
end

function HighlightTapMenu:doDelete()
    local hl, index = self.hl, self.index
    self:closeMenu()
    UIManager:scheduleIn(0.05, function()
        pcall(function() hl:deleteHighlight(index) end)
    end)
end

function HighlightTapMenu:doNote()
    local hl, index = self.hl, self.index
    self:closeMenu()
    UIManager:scheduleIn(0.05, function()
        pcall(function() hl:editNote(index) end)
    end)
end

function HighlightTapMenu:doCopy()
    local item = self:getItem()
    self:closeMenu()
    local text = item and item.text
    if not text or text == "" then return end
    local ok = false
    if Device.input and type(Device.input.setClipboardText) == "function" then
        ok = pcall(Device.input.setClipboardText, text)
    end
    if not ok and type(Device.setClipboardText) == "function" then
        pcall(Device.setClipboardText, text)
    end
    local ok_notif, Notification = pcall(function() return require("ps_dialogs").Notification end)
    if ok_notif and Notification then
        local gt = require("ps_i18n").gettext
        UIManager:show(Notification:new({ text = gt("Copied to clipboard") }))
    end
end

-- More: el mismo menú de selección, pero para este highlight (Sel, Dict, Wiki, Search...)
function HighlightTapMenu:doMore()
    local hl, index = self.hl, self.index
    local item = self:getItem()
    self:closeMenu()
    if not item then return end
    UIManager:scheduleIn(0.05, function()
        pcall(function()
            local util = require("util")
            hl.selected_text = util.tableDeepCopy(item)
            hl:onShowHighlightMenu(index)
        end)
    end)
end

-- ==========================================
-- MENÚ AL TOCAR UN HIGHLIGHT CON NOTA
-- ==========================================
-- Reemplaza al visor de nota nativo (ReaderHighlight:showHighlightNoteOrDialog: TextViewer "Note" con
-- Delete note / Edit note / Delete highlight / Highlight menu) con una tarjeta flotante del plugin:
-- el mismo marco, halo y esquinas de la píldora del highlight, la nota con el texto del libro (con
-- scroll si es larga) y los 4 botones como chips grises en dos filas. Depende del mismo ajuste que la
-- píldora (Menu on highlight tap). Las notas con formato (html / markdown) siguen en el visor nativo.
local C_NOTE_CHIP = Blitbuffer.Color8(0xDD)   -- relleno de los botones (igual que las opciones sin elegir de ps_sheet)
local C_NOTE_RULE = Blitbuffer.Color8(0x99)   -- regla fina entre la nota y los botones

local HighlightNoteMenu = InputContainer:extend({
    hl = nil, plugin = nil, index = nil, tap_pos = nil,
})

function HighlightNoteMenu:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new({ x = 0, y = 0, w = sw, h = sh })
    if self.plugin then self.plugin.active_hl_menu = self end
    if Device:isTouchDevice() then
        self.ges_events = { TapClose = { GestureRange:new({ ges = "tap", range = self.dimen }) } }
    end
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:build()
end

function HighlightNoteMenu:getItem()
    local ann = self.hl and self.hl.ui and self.hl.ui.annotation
    return ann and ann.annotations and ann.annotations[self.index]
end

function HighlightNoteMenu:getLines()
    local item = self:getItem()
    local ui = self.plugin and self.plugin.ui
    if not (SelectionCursor and ui and item) then return nil end
    local ok, lines = pcall(SelectionCursor.selectionLines, ui, item)
    if ok then return lines end
    return nil
end

function HighlightNoteMenu:build()
    local gt = require("ps_i18n").gettext
    local ui_instance = (self.hl and self.hl.ui) or (self.plugin and self.plugin.ui)
    local item = self:getItem()
    local sw, sh = Screen:getWidth(), Screen:getHeight()

    local raw_fs = getBookRawFontSize(ui_instance) or 26
    local font_ratio = math.max(0.85, math.min(1.40, raw_fs / 26))
    local card_border = sscale(SEL_BORDER_PX)
    local card_radius = math.floor(sscale(10) * font_ratio + 0.5)
    local halo = math.max(2, scale(3))
    local inset = card_border + halo

    -- Ancho: casi todo el ancho en vertical; en horizontal una tarjeta más angosta
    local short = math.min(sw, sh)
    local card_w = math.min(sw - scale(16), math.floor(short * 0.88))
    local inner_w = card_w - inset * 2
    local pad = sscale(12)
    local content_w = inner_w - pad * 2

    -- ── La nota (texto del libro, con scroll si no entra) ──────────────────
    local note_txt = (item and type(item.note) == "string") and item.note or ""
    local html_body = '<div class="search-content">'
        .. htmlEscape(note_txt):gsub("\r\n", "\n"):gsub("\n", "<br/>") .. '</div>'
    local max_h = math.floor(sh * 0.34)
    local function makeHtml(h)
        local w = ScrollHtmlWidget:new({
            html_body = html_body, is_xhtml = true, css = getBaseCss(ui_instance),
            default_font_size = getDictFontSize(ui_instance), width = content_w, height = h,
            scroll_bar_width = scale(6), dialog = self, highlight_text_selection = true,
        })
        applyRoundedScrollbar(w)
        return w
    end
    self.htmlwidget = makeHtml(max_h)
    -- Shrink-to-fit: una nota corta no deja espacio vacío
    local natural_h = getHtmlContentHeight(self.htmlwidget)
        or estimateHtmlContentHeight(content_w, html_body, getDictFontSize(ui_instance))
    if natural_h and natural_h < max_h then
        local fitted_h = math.max(scale(40), math.ceil(natural_h) + scale(14))
        if fitted_h < max_h then
            if self.htmlwidget.free then pcall(function() self.htmlwidget:free() end) end
            self.htmlwidget = makeHtml(fitted_h)
        end
    end

    -- ── Los 4 botones: dos filas de dos chips grises con ícono y rótulo en línea ─
    local icon_sz = sscale(18)
    local btn_h = sscale(38)
    local gap = sscale(8)
    local btn_w1 = math.floor((content_w - gap) / 2)
    local btn_w2 = content_w - gap - btn_w1
    -- Rótulos de los chips más chicos y en peso normal (antes 12 y negrita)
    local text_fs = math.floor(scaleText(12) * 0.88 * getSelSizeK() * font_ratio + 0.5)
    local chip_radius = sscale(10)

    local function chip(svg, label, callback, w)
        local path = getValidSvgPath(svg)
        return PreviewButton:new({
            icon_svg = path,
            icon_size = icon_sz,
            icon_gap = sscale(6),
            text = label,
            font_size = text_fs,
            face = getBookFace(ui_instance, text_fs, false),
            bold = false,
            always_show_text = true,
            horizontal = true,
            width = w or btn_w1,
            height = btn_h,
            show_parent = self,
            callback = callback,
            bg_color = C_NOTE_CHIP,
            radius = chip_radius,
        })
    end
    local function row(a, b)
        return HorizontalGroup:new({ a, HorizontalSpan:new({ width = gap }), b })
    end
    local row1 = row(
        chip("notepad-text.svg", gt("Edit note"), function() self:doEditNote() end, btn_w1),
        chip("square-minus.svg", gt("Delete note"), function() self:doDeleteNote() end, btn_w2))
    local row2 = row(
        chip("trash-2.svg", gt("Delete highlight"), function() self:doDeleteHighlight() end, btn_w1),
        chip("highlighter.svg", gt("Highlight menu"), function() self:doHighlightMenu() end, btn_w2))

    local body = VerticalGroup:new({
        align = "left",
        VerticalSpan:new({ width = pad }),
        HorizontalGroup:new({ HorizontalSpan:new({ width = pad }), self.htmlwidget, HorizontalSpan:new({ width = pad }) }),
        VerticalSpan:new({ width = sscale(10) }),
        HorizontalGroup:new({
            HorizontalSpan:new({ width = pad }),
            LineWidget:new({ dimen = Geom:new({ w = content_w, h = math.max(1, scale(1)) }), background = C_NOTE_RULE }),
            HorizontalSpan:new({ width = pad }),
        }),
        VerticalSpan:new({ width = sscale(10) }),
        HorizontalGroup:new({ HorizontalSpan:new({ width = pad }), row1, HorizontalSpan:new({ width = pad }) }),
        VerticalSpan:new({ width = gap }),
        HorizontalGroup:new({ HorizontalSpan:new({ width = pad }), row2, HorizontalSpan:new({ width = pad }) }),
        VerticalSpan:new({ width = pad }),
    })

    self.card = FloatingPillCard:new({
        content = body,
        bordersize = card_border,
        radius = card_radius,
    })
    local size = self.card:getSize()

    -- Junto al highlight: arriba si hay lugar, si no abajo; centrado donde se tocó
    local lines = self:getLines()
    local tapped
    if lines and self.tap_pos then
        local best_d
        for _, l in ipairs(lines) do
            local d = 0
            if self.tap_pos.y < l.y then d = l.y - self.tap_pos.y
            elseif self.tap_pos.y > l.y + l.h then d = self.tap_pos.y - (l.y + l.h) end
            if not best_d or d < best_d then tapped, best_d = l, d end
        end
    end
    local cx = self.tap_pos and self.tap_pos.x or nil
    local x, y = placeNearLines(size.w, size.h, lines, {
        gap = scale(10), cx_top = cx, cx_bottom = cx, tapped = tapped,
    })
    self.popup_rect = Geom:new({ x = x, y = y, w = size.w, h = size.h })
    self[1] = VerticalGroup:new({
        align = "left",
        VerticalSpan:new({ width = math.max(0, math.floor(y)) }),
        HorizontalGroup:new({
            HorizontalSpan:new({ width = math.max(0, math.floor(x)) }),
            self.card,
        }),
    })
end

function HighlightNoteMenu:closeMenu()
    local r = self.popup_rect
    if r then
        local pad = scale(4)
        UIManager:close(self, "ui", Geom:new({
            x = math.max(0, r.x - pad), y = math.max(0, r.y - pad), w = r.w + pad * 2, h = r.h + pad * 2,
        }))
    else
        UIManager:close(self)
    end
end

function HighlightNoteMenu:onShow()
    UIManager:setDirty(self, function() return "ui", self.popup_rect end)
end

function HighlightNoteMenu:onCloseWidget()
    if self.plugin and self.plugin.active_hl_menu == self then self.plugin.active_hl_menu = nil end
    if self.htmlwidget and self.htmlwidget.free then pcall(function() self.htmlwidget:free() end) end
    -- Repinta la página bajo la tarjeta
    local r = self.popup_rect
    if r then
        local ui = self.plugin and self.plugin.ui
        UIManager:setDirty(ui or nil, function() return "ui", r end)
    end
end

function HighlightNoteMenu:paintTo(bb, x, y)
    if self[1] then self[1]:paintTo(bb, x, y) end
end

function HighlightNoteMenu:onTapClose(_arg, ges)
    if ges and ges.pos and self.popup_rect and not ges.pos:intersectWith(self.popup_rect) then
        self:closeMenu()
        return true
    end
    return false
end

function HighlightNoteMenu:onClose()
    self:closeMenu()
    return true
end

-- Las mismas acciones que los botones del visor nativo (readerhighlight.lua)
function HighlightNoteMenu:doEditNote()
    local hl, index = self.hl, self.index
    self:closeMenu()
    UIManager:scheduleIn(0.05, function()
        pcall(function() hl:editNote(index) end)
    end)
end

function HighlightNoteMenu:doDeleteNote()
    local hl, index = self.hl, self.index
    local annotation = self:getItem()
    self:closeMenu()
    if not annotation then return end
    local ui = hl.ui
    annotation.note = nil
    pcall(function()
        ui:handleEvent(Event:new("AnnotationsModified",
            { annotation, nb_highlights_added = 1, nb_notes_added = -1 }))
    end)
    pcall(function() hl:writePdfAnnotation("content", annotation, "") end)
    -- Refresca el marcador de nota (si está activado)
    pcall(function()
        if hl.view and hl.view.highlight and hl.view.highlight.note_mark then
            UIManager:setDirty(hl.dialog, "ui")
        end
    end)
end

function HighlightNoteMenu:doDeleteHighlight()
    local hl, index = self.hl, self.index
    self:closeMenu()
    UIManager:scheduleIn(0.05, function()
        pcall(function() hl:deleteHighlight(index) end)
    end)
end

-- Highlight menu: abre el menú de píldora del plugin (showHighlightDialog está parcheado)
function HighlightNoteMenu:doHighlightMenu()
    local hl, index = self.hl, self.index
    local tap = self.tap_pos
    local plugin = self.plugin
    self:closeMenu()
    UIManager:scheduleIn(0.05, function()
        if plugin then plugin._last_tap_pos = tap end
        pcall(function() hl:showHighlightDialog(index) end)
    end)
end

-- Devuelve true si mostró el menú; si no (sin nota, nota con formato), el llamador deja el visor nativo
local function showHighlightNoteMenu(hl, plugin, index)
    local ann = hl and hl.ui and hl.ui.annotation
    local item = ann and ann.annotations and ann.annotations[index]
    if not item then return false end
    local note = item.note
    if type(note) ~= "string" or not note:match("%S") then return false end
    -- Notas html / markdown: el visor nativo las sabe dibujar
    if item.note_format then return false end
    local first = note:gsub("^%s*", ""):sub(1, 1)
    if first == "<" or first == "#" or first == "*" or first == "[" then return false end
    local tap = plugin._last_tap_pos
    plugin._last_tap_pos = nil
    UIManager:show(HighlightNoteMenu:new({ hl = hl, plugin = plugin, index = index, tap_pos = tap }))
    return true
end

-- Devuelve true si mostró el menú (si no, el llamador deja el diálogo nativo)
local function showHighlightTapMenu(hl, plugin, index)
    local ann = hl and hl.ui and hl.ui.annotation
    local item = ann and ann.annotations and ann.annotations[index]
    -- Solo highlights con texto y estilo (las notas sueltas y los marcadores usan el diálogo nativo)
    if not (item and item.pos0 and item.pos1 and item.drawer) then return false end
    local tap = plugin._last_tap_pos
    plugin._last_tap_pos = nil
    UIManager:show(HighlightTapMenu:new({ hl = hl, plugin = plugin, index = index, tap_pos = tap }))
    return true
end

-- Menú para escribir la nota (reemplaza al "Edit note" de ReaderBookmark:setBookmarkNote).
-- Devuelve true si lo mostró; si no, el llamador deja el diálogo nativo.
local function showNotesEditor(bm, plugin, item_or_index, is_new_note, new_note, caller_callback)
    if not NotesDialog then return false end
    local ui = bm.ui or plugin.ui
    -- El texto se escribe con la letra del libro, del mismo tamaño que el de las tarjetas del diccionario
    local raw = getDictBaseFontSize(ui) * getDictFontScale()
    local face = getBookFace(ui, math.max(8, math.floor(raw + 0.5)), false, true)
    return NotesDialog.show(bm, item_or_index, is_new_note, new_note, caller_callback, { face = face })
end

function FloatingDictionaryPopup:invokeNative(a) invokeAction(self, a) end
function FloatingActionMenu:invokeNative(a) invokeAction(self, a) end
function FloatingActionMenu:invokeNativeHold(a, anchor_pos) invokeHoldAction(self, a, anchor_pos) end

local function checkClose(self_obj, ges)
    if ges and ges.pos then
        local in_main = self_obj.popup_rect and ges.pos:intersectWith(self_obj.popup_rect)
        local in_more = self_obj.show_more and self_obj.more_popup_rect and ges.pos:intersectWith(self_obj.more_popup_rect)
        if not in_main and not in_more then
            -- Un toque justo sobre un cursor de selección no cierra el menú (se ajusta arrastrando)
            if self_obj._cursor and self_obj._cursor:handleAt(ges.pos) then return true end
            UIManager:close(self_obj)
            if self_obj.highlight_obj and self_obj.highlight_obj.clear then
                pcall(function() self_obj.highlight_obj:clear() end)
            end
            return true
        end
    end
    return false
end

function FloatingDictionaryPopup:onTapClose(_arg, ges) return checkClose(self, ges) end
function FloatingActionMenu:onTapClose(_arg, ges) return checkClose(self, ges) end
function FloatingDictionaryPopup:onShow()
    UIManager:setDirty(self.dialog, function() return "ui", self.dimen end)
    if self.plugin then self.plugin.active_dict_popup = self end
    if self._cursor then self._cursor:setPhase("menu") end
end
function FloatingDictionaryPopup:onCloseWidget()
    local plugin = self.plugin
    -- ¿Ya hay otra tarjeta del diccionario encima de esta? Entonces los cursores son de ella
    local newer = plugin and plugin.active_dict_popup and plugin.active_dict_popup ~= self
    if plugin and plugin.active_dict_popup == self then plugin.active_dict_popup = nil end
    -- Deseleccionar y limpiar el resaltado temporal para evitar que el siguiente toque reabra el diccionario
    -- (salvo que se esté ajustando la selección con un cursor o cambiando de diccionario: sigue viva)
    if not self._keep_selection then
        if self.highlight_obj and self.highlight_obj.clear then
            pcall(function() self.highlight_obj:clear() end)
        end
        if self.plugin and self.plugin.ui then
            local ui = self.plugin.ui
            if ui.highlight and ui.highlight.clear then
                pcall(function() ui.highlight:clear() end)
            end
            if ui.view and ui.view.clearSelection then
                pcall(function() ui.view:clearSelection() end)
            end
            if ui.handleEvent then
                pcall(function() ui:handleEvent(Event:new("ClearSelection")) end)
            end
        end
    end
    -- Los cursores se van con la tarjeta (salvo que se esté rearmando tras ajustar la selección)
    if self._cursor and self._cursor.phase and not self._keep_cursor and not newer then
        self._cursor:setPhase(nil)
    end

    local dirty_rect = self.popup_rect or self.dimen
    if self.plugin and self.plugin.ui then
        UIManager:setDirty(self.plugin.ui, function() return "ui", dirty_rect end)
    else
        UIManager:setDirty(nil, function() return "ui", dirty_rect end)
    end
end
function FloatingActionMenu:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    if self._cursor then self._cursor:setPhase("menu") end
end
function FloatingActionMenu:onCloseWidget()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    if self.plugin and self.plugin.active_selection_menu == self then self.plugin.active_selection_menu = nil end
    -- Los cursores se van con el menú (salvo que se esté rearmando el menú tras ajustar la selección)
    if self._cursor and self._cursor.phase and not self._keep_cursor then self._cursor:setPhase(nil) end
end

-- ==========================================
-- FUNCIONES DE CONFIGURACIÓN Y ACTIVACIÓN
-- ==========================================
function FloatingDict:isEnabled()
    if G_reader_settings then
        local val = G_reader_settings:readSetting(SETTING_DICT_ENABLED)
        if val ~= nil then return val == true end
    end
    return false
end

function FloatingDict:setEnabled(state)
    if G_reader_settings then 
        G_reader_settings:saveSetting(SETTING_DICT_ENABLED, state)
        G_reader_settings:flush() 
    end
end

function FloatingDict:isSelectionMenuEnabled()
    if G_reader_settings then
        local val = G_reader_settings:readSetting(SETTING_SELECTION_ENABLED)
        if val ~= nil then return val == true end
    end
    return false
end

-- Cursores de selección: siempre activos (sin ajuste); solo faltan si el módulo no cargó
function FloatingDict:isCursorEnabled()
    return SelectionCursor ~= nil
end

-- Menú propio al tocar un highlight (en vez del diálogo nativo)
function FloatingDict:isHighlightMenuEnabled()
    -- Apagado por defecto, salvo que el Scrubber Selection Menu ya esté activado
    return notesMenuSetting(SETTING_HLMENU_ENABLED)
end

-- Menú propio para escribir notas en vez del "Edit note" nativo (ps_notes_dialog.lua)
function FloatingDict:isNotesMenuEnabled()
    return NotesDialog ~= nil and notesMenuSetting(SETTING_NOTES_ENABLED)
end

-- Selección ajustada con un cursor sobre la tarjeta del diccionario: una sola palabra vuelve a buscarse
-- en el diccionario; con más palabras sigue el camino de una selección normal (menú de selección)
function FloatingDict:lookupAdjustedSelection(hl, sel)
    local trimmed = sel.text:gsub("^%s*(.-)%s*$", "%1")
    local words = 0
    for _ in trimmed:gmatch("%S+") do words = words + 1 end
    if words <= 1 and self:isEnabled() and self.ui and self.ui.dictionary then
        local clean = cleanWordForLookup(trimmed)
        if clean and #clean > 0 then
            local boxes = sel.pboxes or hl.boxes
            if not boxes and type(hl.getHighlightedBoxes) == "function" then
                boxes = hl:getHighlightedBoxes(sel.pos0, sel.pos1)
            end
            self.ui.dictionary:onLookupWord(clean, false, boxes, hl)
            return
        end
    end
    hl:onShowHighlightMenu()
end

-- Tras ajustar la selección con un cursor: cierra el menú (o la tarjeta del diccionario) viejo y abre
-- uno nuevo para la nueva selección
function FloatingDict:reopenSelectionMenu(old_menu)
    local hl = self.ui and self.ui.highlight
    local from_dict = old_menu ~= nil and old_menu.results ~= nil
    if old_menu then
        old_menu._keep_cursor = true
        old_menu._keep_selection = true
        pcall(function() UIManager:close(old_menu) end)
    end
    local sel = hl and hl.selected_text
    if sel and sel.text and sel.text ~= "" then
        local ok
        if from_dict then
            ok = pcall(function() self:lookupAdjustedSelection(hl, sel) end)
        else
            ok = pcall(function() hl:onShowHighlightMenu() end)
        end
        if ok then
            if from_dict then
                -- La búsqueda puede tardar un momento: si no aparece ninguna tarjeta ni menú, se apagan los cursores
                UIManager:scheduleIn(1, function()
                    if not self.active_selection_menu and not self.active_dict_popup
                            and self.cursor and self.cursor.phase then
                        self.cursor:setPhase(nil)
                    end
                end)
            elseif not self.active_selection_menu and not self.active_dict_popup and self.cursor then
                -- Si no quedó un menú de selección abierto (y una sola palabra no abrió el diccionario), no hay cursores
                self.cursor:setPhase(nil)
            end
            return
        end
    end
    if hl and hl.clear then pcall(function() hl:clear() end) end
    if self.cursor then self.cursor:setPhase(nil) end
end

function FloatingDict:setSelectionMenuEnabled(state)
    if G_reader_settings then 
        G_reader_settings:saveSetting(SETTING_SELECTION_ENABLED, state)
        G_reader_settings:flush() 
    end
end

-- ==========================================
-- DISPARADOR PRINCIPAL DE MENÚ FLOTANTE (+2 PALABRAS)
-- ==========================================
local function showCustomActionMenu(hl_self, plugin, index)
    local sel = hl_self and hl_self.selected_text
    if not sel or not sel.text or sel.text == "" then
        return false
    end

    -- Verificamos si hay al menos dos palabras reales (separadas por espacio o puntuación)
    local trimmed_text = sel.text:gsub("^%s*(.-)%s*$", "%1")
    local words_count = 0
    for _ in trimmed_text:gmatch("%S+") do
        words_count = words_count + 1
    end

    if words_count <= 1 then
        -- Es una sola palabra. Si el diccionario flotante está activo, derivar a lookup limpio
        if plugin:isEnabled() and plugin.ui and plugin.ui.dictionary then
            local clean_word = cleanWordForLookup(trimmed_text)
            if clean_word and #clean_word > 0 then
                local boxes = sel.pboxes or hl_self.boxes
                if not boxes and type(hl_self.getHighlightedBoxes) == "function" then
                    boxes = hl_self:getHighlightedBoxes(sel.pos0, sel.pos1)
                end
                plugin.ui.dictionary:onLookupWord(clean_word, false, boxes, hl_self)
                return true
            end
        end
        return false
    end

    local boxes = sel.pboxes or hl_self.boxes
    if not boxes and type(hl_self.getHighlightedBoxes) == "function" then
        boxes = hl_self:getHighlightedBoxes(sel.pos0, sel.pos1)
    end

    local popup = FloatingActionMenu:new({
        text = sel.text,
        boxes = boxes,
        pos0 = sel.pos0,
        pos1 = sel.pos1,
        highlight_obj = hl_self,
        plugin = plugin,
        selected_text = sel, -- copia de la selección, por si KOReader la limpia al cerrar el menú
        annotation_index = index -- ACÁ SE LO PASAMOS
    })
    UIManager:show(popup)
    return true
end

-- ==========================================
-- INYECCIÓN EN KOREADER
-- ==========================================
function FloatingDict:init(ui)
    self.ui = ui
    self.active_selection_menu = nil
    self.active_hl_menu = nil
    self._last_tap_pos = nil
    self:patchSystem()
end

function FloatingDict:onReaderReady()
    self:patchSystem()
end

function FloatingDict:patchSystem()
    self:patchFastDict()

    local dictionary = self.ui and self.ui.dictionary
    local highlight = self.ui and self.ui.highlight
    local plugin = self

    if ReaderHighlight then
        ReaderHighlight._ps_fdict_plugin = plugin
        if not ReaderHighlight._ps_fdict_class_patched then
            local orig_class_onShowHighlightMenu = ReaderHighlight.onShowHighlightMenu
            -- Capturamos el index explícitamente en los parámetros
            ReaderHighlight.onShowHighlightMenu = function(hl_self, index, ...)
                local active_plugin = ReaderHighlight._ps_fdict_plugin or plugin
                if active_plugin:isSelectionMenuEnabled() and hl_self.selected_text and hl_self.selected_text.text and hl_self.selected_text.text ~= "" then
                    local shown = showCustomActionMenu(hl_self, active_plugin, index)
                    if shown then return true end
                end
                if type(orig_class_onShowHighlightMenu) == "function" then
                    return orig_class_onShowHighlightMenu(hl_self, index, ...)
                end
            end
            ReaderHighlight._ps_fdict_class_patched = true
        end
        if type(ReaderHighlight.showHighlightNoteOrDialog) == "function" and not ReaderHighlight._ps_hlnote_class_patched then
            local orig_class_note_dialog = ReaderHighlight.showHighlightNoteOrDialog
            ReaderHighlight.showHighlightNoteOrDialog = function(hl_self, index, ...)
                local active_plugin = ReaderHighlight._ps_fdict_plugin or plugin
                if index and active_plugin:isHighlightMenuEnabled() then
                    local ok, shown = pcall(showHighlightNoteMenu, hl_self, active_plugin, index)
                    if ok and shown then return true end
                    if not ok then logger.warn("PageScrubber: fallo el menú de la nota, se usa el nativo:", shown) end
                end
                return orig_class_note_dialog(hl_self, index, ...)
            end
            ReaderHighlight._ps_hlnote_class_patched = true
        end
    end

    -- Menú para escribir notas (Reading Pop-Ups > Notes menu > Menu notes): todo "Edit note" de KOReader pasa
    -- por ReaderBookmark:setBookmarkNote (highlight, marcador, lista de marcadores, split del plugin)
    if ReaderBookmark and NotesDialog then
        ReaderBookmark._ps_notes_plugin = plugin
        if not ReaderBookmark._ps_notes_class_patched and type(ReaderBookmark.setBookmarkNote) == "function" then
            local orig_set_note = ReaderBookmark.setBookmarkNote
            ReaderBookmark.setBookmarkNote = function(bm_self, item_or_index, is_new_note, new_note, caller_callback)
                local active_plugin = ReaderBookmark._ps_notes_plugin
                if active_plugin and active_plugin:isNotesMenuEnabled() then
                    local ok, shown = pcall(showNotesEditor, bm_self, active_plugin, item_or_index, is_new_note, new_note, caller_callback)
                    if ok and shown then return end
                    if not ok then logger.warn("PageScrubber: fallo el menú de notas, se usa el nativo:", shown) end
                end
                return orig_set_note(bm_self, item_or_index, is_new_note, new_note, caller_callback)
            end
            ReaderBookmark._ps_notes_class_patched = true
        end
    end

    if dictionary and not dictionary._ps_fdict_addbuttons_patched then
        if type(dictionary.addToDictButtons) == "function" then
            local original_addToDictButtons = dictionary.addToDictButtons
            dictionary._ps_orig_addToDictButtons = original_addToDictButtons
            -- botones registrados antes que nuestro parche (plugins que cargan primero)
            harvestExistingDictButtons(dictionary, original_addToDictButtons)
            dictionary.addToDictButtons = function(dict_self, spec)
                if spec and spec.id then
                    modern_plugin_buttons_shared[spec.id] = spec
                end
                return original_addToDictButtons(dict_self, spec)
            end
        end
        dictionary._ps_fdict_addbuttons_patched = true
    end

    if dictionary and not dictionary._ps_fdict_patched then
        plugin.original_showDict = dictionary.showDict
        plugin.patched_dictionary = dictionary

        if type(dictionary.onLookupWord) == "function" then
            local orig_onLookupWord = dictionary.onLookupWord
            dictionary.onLookupWord = function(dict_self, ...)
                plugin._in_dict_lookup = (plugin._in_dict_lookup or 0) + 1
                local ok, r1, r2, r3 = pcall(orig_onLookupWord, dict_self, ...)
                plugin._in_dict_lookup = math.max(0, (plugin._in_dict_lookup or 1) - 1)
                if not ok then error(r1) end
                return r1, r2, r3
            end
        end

        if not UIManager._ps_fdict_show_patched then
            local orig_uim_show = UIManager.show
            UIManager.show = function(uim_self, widget, ...)
                if plugin:isEnabled() and not plugin.opening_original_popup
                        and type(widget) == "table" and widget.text
                        and widget.class and widget.class.name == "InfoMessage" then
                    local is_dict_msg = (plugin._in_dict_lookup or 0) > 0
                    if not is_dict_msg and type(debug) == "table" and type(debug.getinfo) == "function" then
                        for lvl = 2, 8 do
                            local info = debug.getinfo(lvl, "S")
                            if not info then break end
                            local src = (info.source or ""):lower()
                            if src:find("readerdictionary", 1, true) then
                                is_dict_msg = true
                                break
                            end
                        end
                    end
                    if not is_dict_msg then
                        local ok_gt, gt = pcall(require, "gettext")
                        local txt = tostring(widget.text)
                        local known = {
                            ["Not available"] = true,
                            ["No dictionaries available."] = true,
                            ["Searching…"] = true,
                            ["Searching..."] = true,
                        }
                        if ok_gt and type(gt) == "function" then
                            known[gt("Not available")] = true
                            known[gt("No dictionaries available.")] = true
                            known[gt("Searching…")] = true
                            known[gt("Searching...")] = true
                        end
                        if known[txt] then
                            is_dict_msg = true
                        end
                    end
                    if is_dict_msg then
                        local ok_notif, Notification = pcall(function()
                            return require("ps_dialogs").Notification
                        end)
                        if ok_notif and Notification and widget.class ~= Notification and not widget._ps_toast then
                            if plugin._last_dict_toast then
                                pcall(function() UIManager:close(plugin._last_dict_toast) end)
                            end
                            local toast = Notification:new({
                                text = widget.text,
                                timeout = widget.timeout or 2,
                            })
                            plugin._last_dict_toast = toast
                            return orig_uim_show(uim_self, toast, ...)
                        end
                    end
                end
                return orig_uim_show(uim_self, widget, ...)
            end
            UIManager._ps_fdict_show_patched = true
        end
        
        dictionary.showDict = function(dict_self, ...)
            local args = {...}
            local word = args[1]
            local results = args[2]
            local boxes = args[3]

            if plugin._last_dict_toast then
                pcall(function() UIManager:close(plugin._last_dict_toast) end)
                plugin._last_dict_toast = nil
            end
            
            if not plugin:isEnabled() or plugin.opening_original_popup or plugin._popup_disabled_session then
                return plugin.original_showDict(dict_self, ...)
            end

            if type(results) ~= "table" or not results[1] then
                local ok_notif, Notification = pcall(function()
                    return require("ps_dialogs").Notification
                end)
                if ok_notif and Notification then
                    local _ = require("ps_i18n").gettext
                    UIManager:show(Notification:new({ text = _("Not available"), timeout = 2 }))
                    if highlight and highlight.clear then pcall(function() highlight:clear() end) end
                    return true
                end
                return plugin.original_showDict(dict_self, ...)
            end

            local popup_shown = false
            local ok_popup, err_popup = pcall(function()
                if dict_self.dismissLookupInfo then pcall(function() dict_self:dismissLookupInfo() end) end
                
                local is_landscape = Screen:getWidth() > Screen:getHeight()
                local anchor_top = false
                local anchor_left = false

                if is_landscape then
                    if plugin._inherited_anchor_left ~= nil then
                        anchor_left = plugin._inherited_anchor_left
                        plugin._inherited_anchor_left = nil
                    else
                        anchor_left = shouldAnchorLeft(boxes)
                    end
                else
                    if plugin._inherited_anchor_top ~= nil then
                        anchor_top = plugin._inherited_anchor_top
                        plugin._inherited_anchor_top = nil
                    else
                        anchor_top = shouldAnchorTop(boxes)
                    end
                end

                local popup = FloatingDictionaryPopup:new({
                    text = word, results = results, boxes = boxes,
                    anchor_top = anchor_top, anchor_left = anchor_left, is_landscape = is_landscape,
                    highlight_obj = highlight, plugin = plugin, current_result_idx = 1
                })
                UIManager:show(popup)
                popup_shown = true
            end)
            if ok_popup and popup_shown then
                plugin._popup_failures = 0
                return true
            end

            -- Si el popup flotante no se pudo armar o mostrar (fuente, memoria, otro plugin, etc.), antes el error se
            -- descartaba y no aparecía ningún popup: la búsqueda quedaba "colgada" con la palabra resaltada. Ahora se
            -- avisa en el log y se muestra el popup nativo de KOReader; tras 3 fallos seguidos se deja de intentar
            -- con el flotante durante esta sesión.
            logger.warn("PageScrubber: fallo el popup flotante del diccionario, se usa el nativo:", err_popup)
            plugin._popup_failures = (plugin._popup_failures or 0) + 1
            if plugin._popup_failures >= 3 then plugin._popup_disabled_session = true end
            return plugin.original_showDict(dict_self, ...)
        end
        dictionary._ps_fdict_patched = true
    end

    if highlight and not highlight._ps_fdict_instance_patched then
        local orig_inst_onShowHighlightMenu = highlight.onShowHighlightMenu
        -- Capturamos el index explícitamente en la instancia también
        highlight.onShowHighlightMenu = function(hl_self, index, ...)
            if plugin:isSelectionMenuEnabled() and hl_self.selected_text and hl_self.selected_text.text and hl_self.selected_text.text ~= "" then
                local shown = showCustomActionMenu(hl_self, plugin, index)
                if shown then return true end
            end
            if type(orig_inst_onShowHighlightMenu) == "function" then
                return orig_inst_onShowHighlightMenu(hl_self, index, ...)
            end
        end
        highlight._ps_fdict_instance_patched = true
    end

    -- Cursores de selección (uno por libro abierto)
    if highlight and SelectionCursor then
        if not plugin.cursor or plugin.cursor.ui ~= self.ui then
            plugin.cursor = SelectionCursor.new(self.ui, function() return plugin:isCursorEnabled() end)
            -- Una selección nueva cierra el menú de la anterior si quedó abierto
            plugin.cursor.on_new_selection = function()
                for _, menu in ipairs({ plugin.active_selection_menu or false, plugin.active_hl_menu or false }) do
                    if menu then
                        menu._keep_cursor = true
                        pcall(function() UIManager:close(menu) end)
                    end
                end
            end
        end
        local ok_cur, err_cur = pcall(function() plugin.cursor:install() end)
        if not ok_cur then logger.warn("PageScrubber: no se pudieron instalar los cursores:", err_cur) end
    end

    -- Menú al tocar un highlight (apagado por defecto; se activa en Reading Pop-Ups > Notes menu)
    if highlight and not highlight._ps_hlmenu_patched then
        highlight._ps_hlmenu_patched = true
        local orig_dialog = highlight.showHighlightDialog
        if type(orig_dialog) == "function" then
            highlight.showHighlightDialog = function(hl_self, index, ...)
                if index and plugin:isHighlightMenuEnabled() then
                    local ok, shown = pcall(showHighlightTapMenu, hl_self, plugin, index)
                    if ok and shown then return true end
                    if not ok then logger.warn("PageScrubber: fallo el menú del highlight, se usa el nativo:", shown) end
                end
                return orig_dialog(hl_self, index, ...)
            end
        end
        -- Highlight con nota: en vez del visor nativo de la nota, la tarjeta del plugin (mismo ajuste)
        local orig_note_dialog = rawget(highlight, "showHighlightNoteOrDialog")
            or (not ReaderHighlight and highlight.showHighlightNoteOrDialog)
        if type(orig_note_dialog) == "function" and not highlight._ps_hlnote_patched then
            highlight._ps_hlnote_patched = true
            highlight.showHighlightNoteOrDialog = function(hl_self, index, ...)
                if index and plugin:isHighlightMenuEnabled() then
                    local ok, shown = pcall(showHighlightNoteMenu, hl_self, plugin, index)
                    if ok and shown then return true end
                    if not ok then logger.warn("PageScrubber: fallo el menú de la nota, se usa el nativo:", shown) end
                end
                return orig_note_dialog(hl_self, index, ...)
            end
        end
        -- Donde se tocó: el menú se centra ahí y se pega a esa línea
        local orig_tap = highlight.onTap
        if type(orig_tap) == "function" then
            highlight.onTap = function(hl_self, arg, ges, ...)
                plugin._last_tap_pos = (ges and ges.pos) and { x = ges.pos.x, y = ges.pos.y } or nil
                return orig_tap(hl_self, arg, ges, ...)
            end
        end
    end
end

return FloatingDict

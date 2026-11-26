--[[
    page_scrubber.koplugin/ps_i18n.lua

    Cargador de traducciones único del plugin. Todos los módulos lo usan:

        local _ = require("ps_i18n").gettext

    Qué hace:
    - Lee el idioma de KOReader (G_reader_settings "language", ej. "pt_BR", "zh_CN", "es").
    - Busca primero locales/<idioma completo>.po (pt_BR.po, zh_CN.po) y, si no existe,
      locales/<2 letras>.po (pt.po). Así los archivos con región también se usan.
    - Si el texto no está en el .po del plugin, prueba con el gettext de KOReader
      (sirve para textos como "Cancel" o "Save", que KOReader ya traduce) y,
      si tampoco, devuelve el texto original en inglés.
    - Un msgstr vacío se ignora (se muestra el inglés, no un texto en blanco).
    - Si un msgid aparece repetido en el .po, gana la última copia.
    - Entiende msgctxt (para textos iguales con distinto significado) y entradas
      de varias líneas.
]]--

local I18n = {}

local plugin_path = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"

-- ── Idioma actual ────────────────────────────────────────────────────────────

-- El idioma de KOReader solo cambia reiniciando, así que se lee una vez y se guarda.
local lang_full, lang_short

local function currentLang()
    if lang_full then return lang_full, lang_short end
    local full = "en"
    if G_reader_settings then
        local l = G_reader_settings:readSetting("language")
        if type(l) == "string" and l ~= "" then full = l end
        lang_full, lang_short = full, full:sub(1, 2)   -- recién se guarda con los ajustes ya disponibles
        return lang_full, lang_short
    end
    return full, full:sub(1, 2)
end

-- ── Lector de .po ────────────────────────────────────────────────────────────

local ESCAPES = { n = "\n", t = "\t", ['"'] = '"', ["\\"] = "\\" }
local function unescape(s)
    return (s:gsub("\\(.)", function(c) return ESCAPES[c] or ("\\" .. c) end))
end

local CTX_SEP = "\004"   -- separa msgctxt y msgid en la clave del diccionario

local function parsePo(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local dict = {}
    local ctx, id, str, mode
    local function flush()
        if id and id ~= "" and str and str ~= "" then
            dict[(ctx and (ctx .. CTX_SEP) or "") .. id] = str
        end
        ctx, id, str, mode = nil, nil, nil, nil
    end
    for raw in f:lines() do
        local line = raw:gsub("\r$", "")
        local c = line:match('^msgctxt%s+"(.*)"%s*$')
        local i = line:match('^msgid%s+"(.*)"%s*$')
        local s = line:match('^msgstr%s+"(.*)"%s*$')
        local cont = line:match('^%s*"(.*)"%s*$')
        if c then
            flush(); ctx = unescape(c); mode = "ctx"
        elseif i then
            if mode ~= "ctx" then flush() end
            id = unescape(i); mode = "id"
        elseif s then
            str = unescape(s); mode = "str"
        elseif cont then
            if mode == "ctx" then ctx = ctx .. unescape(cont)
            elseif mode == "id" then id = id .. unescape(cont)
            elseif mode == "str" then str = (str or "") .. unescape(cont) end
        end
    end
    flush()
    f:close()
    return dict
end

-- ── Diccionario (se carga una sola vez por idioma) ───────────────────────────

local cache = {}   -- [idioma completo] = diccionario ({} si no hay .po)

local function getDict()
    local full, short = currentLang()
    local d = cache[full]
    if d then return d end
    d = {}
    if short ~= "en" then
        d = parsePo(plugin_path .. "locales/" .. full .. ".po")
        if not d and short ~= full then
            d = parsePo(plugin_path .. "locales/" .. short .. ".po")
        end
        d = d or {}
    end
    cache[full] = d
    return d
end

local ko_gettext   -- gettext de KOReader (se busca una sola vez)
local function koreaderGettext(text)
    if ko_gettext == nil then
        local ok, gt = pcall(require, "gettext")
        ko_gettext = (ok and type(gt) == "function") and gt or false
    end
    if ko_gettext then
        local ok, res = pcall(ko_gettext, text)
        if ok and type(res) == "string" then return res end
    end
    return text
end

-- ── API ──────────────────────────────────────────────────────────────────────

-- Traduce `text`: .po del plugin → gettext de KOReader → texto original.
function I18n.gettext(text)
    if type(text) ~= "string" then return text end
    local _, short = currentLang()
    if short == "en" then return text end   -- inglés: no hay nada que traducir
    local tr = getDict()[text]
    if tr then return tr end
    return koreaderGettext(text)
end

-- Igual, pero con contexto (msgctxt) para textos iguales con distinto significado,
-- ej. I18n.pgettext("abbreviated month", "May"). Si no hay entrada con ese contexto,
-- cae a la traducción sin contexto.
function I18n.pgettext(ctx, text)
    if type(text) ~= "string" then return text end
    local tr = getDict()[ctx .. CTX_SEP .. text]
    if tr then return tr end
    return I18n.gettext(text)
end

-- Fechas traducibles. La plantilla "{month} {day}, {year}" se traduce como cualquier otro texto,
-- asi cada idioma pone su propio orden (ej. es/pt: "{day} de {month} de {year}").
-- Los nombres de mes usan contexto ("full month" / "abbreviated month") porque "May" es igual
-- en ingles para el nombre completo y el abreviado, y en otros idiomas no lo es ("Maio" / "Mai").
-- Si el idioma no tiene entradas con contexto, se usa la traduccion sin contexto (como antes).
local MONTHS_FULL = { "January", "February", "March", "April", "May", "June",
                      "July", "August", "September", "October", "November", "December" }
local MONTHS_ABBR = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- Devuelve el texto de la fecha, o nil si y/m/d no son validos.
function I18n.formatDate(y, m, d, abbreviated)
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not (y and m and d) or m < 1 or m > 12 then return nil end
    local month, tpl
    if abbreviated then
        month = I18n.pgettext("abbreviated month", MONTHS_ABBR[m])
        tpl = I18n.pgettext("abbreviated date", "{month} {day}, {year}")
    else
        month = I18n.pgettext("full month", MONTHS_FULL[m])
        tpl = I18n.gettext("{month} {day}, {year}")
    end
    local vals = { month = month, day = tostring(d), year = tostring(y) }
    return (tpl:gsub("{(%a+)}", function(k) return vals[k] end))
end

-- Código de idioma de 2 letras ("en", "pt", "zh") y el completo ("pt_BR"), por si algún
-- módulo necesita decidir algo según el idioma.
function I18n.lang()
    return currentLang()
end

return I18n

--[[
    page_scrubber.koplugin/scrubber_wallpaper.lua
    Módulo liviano y eficiente de fondos de pantalla para Page Scrubber.
    Inspirado en la gestión de memoria y renderizado directo C de Bookshelf.
]]--

local DataStorage = require("datastorage")
local Device      = require("device")
local Screen      = Device.screen
local UIManager   = require("ui/uimanager")
local logger      = require("logger")

local M = {}

M.EXT_LIST = { "png", "jpg", "jpeg", "bmp", "gif", "webp" }
local EXTS = {}
for _, ext in ipairs(M.EXT_LIST) do
    EXTS[ext] = true
end

M.SUBDIR = "page_scrubber/wallpapers"
M.SETTING_KEY = "page_scrubber_wallpaper"
M.SEEDED_KEY = "page_scrubber_wallpapers_seeded"

M._bg_bb  = nil
M._bg_key = nil
M._ensured = false

-- Obtiene la ruta física del plugin (donde vive assets/wallpapers/)
local function getPluginSourceDir()
    local src = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
    return src .. "assets/wallpapers"
end

-- Copia archivo por bloques de 64KB para no saturar memoria RAM en e-ink
local function copyFile(src, dst)
    local fi = io.open(src, "rb")
    if not fi then return false end
    local fo = io.open(dst, "wb")
    if not fo then fi:close(); return false end
    while true do
        local chunk = fi:read(64 * 1024)
        if not chunk then break end
        if not fo:write(chunk) then
            fi:close()
            fo:close()
            return false
        end
    end
    fi:close()
    fo:close()
    return true
end

local function lfs()
    local ok, l = pcall(require, "libs/libkoreader-lfs")
    return ok and l or nil
end

function M.getSettingsDir()
    if DataStorage and DataStorage.getSettingsDir then
        return DataStorage:getSettingsDir()
    end
    return nil
end

function M.getOwnDir()
    local base = M.getSettingsDir()
    if not base then return nil end
    return base .. "/" .. M.SUBDIR
end

-- Crea la carpeta propia y copia los fondos de muestra incluidos
function M.ensureDir()
    if M._ensured then return end
    local d = M.getOwnDir()
    local fs = lfs()
    if not (d and fs) then return end
    M._ensured = true

    local parent = d:match("^(.*)/[^/]+$")
    if parent and fs.attributes(parent, "mode") ~= "directory" then
        pcall(fs.mkdir, parent)
    end
    if fs.attributes(d, "mode") ~= "directory" then
        pcall(fs.mkdir, d)
    end

    -- Si la carpeta está lista, sembramos los wallpapers incluidos en assets/
    local assets_dir = getPluginSourceDir()
    if fs.attributes(assets_dir, "mode") == "directory" then
        local seeded_list = (G_reader_settings and G_reader_settings:readSetting(M.SEEDED_KEY)) or {}
        local seeded_map = {}
        for _, name in ipairs(seeded_list) do seeded_map[name] = true end

        local changed = false
        pcall(function()
            for file in fs.dir(assets_dir) do
                if file ~= "." and file ~= ".." then
                    local ext = file:match("%.([^%.]+)$")
                    if ext and EXTS[ext:lower()] and not seeded_map[file] then
                        local src_path = assets_dir .. "/" .. file
                        local dst_path = d .. "/" .. file
                        if copyFile(src_path, dst_path) then
                            table.insert(seeded_list, file)
                            seeded_map[file] = true
                            changed = true
                        end
                    end
                end
            end
        end)

        if changed and G_reader_settings then
            G_reader_settings:saveSetting(M.SEEDED_KEY, seeded_list)
            G_reader_settings:flush()
        end
    end
end

-- Directorios adicionales donde los usuarios suelen guardar fondos
function M.getExtraDirs()
    local out = {}
    local settings = M.getSettingsDir()
    if settings then
        out[#out + 1] = { token = "bookshelf", dir = settings .. "/bookshelf/wallpapers" }
        out[#out + 1] = { token = "simpleui",  dir = settings .. "/simpleui/sui_wallpapers" }
    end
    out[#out + 1] = { token = "system", dir = "/mnt/us/Wallpapers" }
    return out
end

-- Lista todos los fondos disponibles para el menú selector
function M.list()
    M.ensureDir()
    local fs = lfs()
    if not fs then return {} end

    local out = {}
    local seen_names = {}

    local function scanFolder(folder_path, prefix)
        if fs.attributes(folder_path, "mode") ~= "directory" then return end
        for file in fs.dir(folder_path) do
            if file ~= "." and file ~= ".." then
                local ext = file:match("%.([^%.]+)$")
                if ext and EXTS[ext:lower()] then
                    local label = file:match("^(.+)%.[^%.]+$") or file
                    local identifier = prefix and (prefix .. ":" .. file) or file
                    local full_path = folder_path .. "/" .. file
                    
                    out[#out + 1] = {
                        id = identifier,
                        label = prefix and (label .. " (" .. prefix .. ")") or label,
                        path = full_path,
                    }
                end
            end
        end
    end

    -- 1. Carpeta propia de Page Scrubber
    local own_dir = M.getOwnDir()
    if own_dir then
        scanFolder(own_dir, nil)
    end

    -- 2. Carpetas compartidas (Bookshelf, SimpleUI, /mnt/us/Wallpapers)
    for _, extra in ipairs(M.getExtraDirs()) do
        scanFolder(extra.dir, extra.token)
    end

    table.sort(out, function(a, b) return a.label:lower() < b.label:lower() end)
    return out
end

-- Resuelve la ruta física del archivo a partir de su ID
function M.getPathForId(id)
    if type(id) ~= "string" or id == "" or id == "none" then return nil end
    local fs = lfs()
    if not fs then return nil end

    local token, filename = id:match("^([^:]+):(.+)$")
    if token and filename then
        for _, extra in ipairs(M.getExtraDirs()) do
            if extra.token == token then
                local p = extra.dir .. "/" .. filename
                if fs.attributes(p, "mode") == "file" then return p end
            end
        end
    else
        local own_dir = M.getOwnDir()
        if own_dir then
            local p = own_dir .. "/" .. id
            if fs.attributes(p, "mode") == "file" then return p end
        end
    end
    return nil
end

-- Decodifica y adapta la imagen al tamaño exacto de pantalla de una sola vez
local function decodeImage(path, w, h)
    local ok_render, RenderImage = pcall(require, "ui/renderimage")
    if not ok_render or not RenderImage then return nil end

    local ok, img_bb = pcall(function()
        -- renderImageFile(path, max_w, max_h): decodifica ajustando a pantalla
        return RenderImage:renderImageFile(path, w, h)
    end)

    if ok and img_bb then
        local iw, ih = img_bb:getWidth(), img_bb:getHeight()
        -- Si la imagen difiere de las dimensiones de pantalla, la escalamos al tamaño exacto
        if (iw ~= w or ih ~= h) and img_bb.scale then
            local ok_sc, scaled = pcall(function() return img_bb:scale(w, h) end)
            pcall(function() img_bb:free() end)
            if ok_sc and scaled then
                return scaled
            end
        else
            return img_bb
        end
    end

    logger.warn("[page-scrubber] Error al decodificar wallpaper:", path)
    return nil
end

-- Libera la memoria del buffer inmediatamente
function M.free()
    local old_bb = M._bg_bb
    M._bg_bb = nil
    M._bg_key = nil
    if old_bb then
        pcall(function()
            if old_bb.free then old_bb:free() end
        end)
    end
end

-- Obtiene el fondo activo decodificado y en caché fija
function M.getWallpaper(w, h, night)
    local setting_val = G_reader_settings and G_reader_settings:readSetting(M.SETTING_KEY)
    if not setting_val or setting_val == "none" or setting_val == "" then
        if M._bg_bb ~= nil then
            M.free()
        end
        return nil
    end

    local path = M.getPathForId(setting_val)
    if not path then
        M.free()
        return nil
    end

    local key = path .. "|" .. tostring(w) .. "x" .. tostring(h) .. (night and "|n" or "")
    if M._bg_bb and M._bg_key == key then
        return M._bg_bb
    end

    M.free()
    local bb = decodeImage(path, w, h)
    if not bb then return nil end

    if night and bb.invertRect then
        pcall(function()
            bb:invertRect(0, 0, bb:getWidth(), bb:getHeight())
        end)
    end

    M._bg_bb = bb
    M._bg_key = key
    return M._bg_bb
end

-- Pinta el fondo en el Blitbuffer; soporta recorte por región (dirty rect) para no saturar memoria
function M.paintTo(bb, sw, sh, night, clip_rect)
    local bg = M.getWallpaper(sw, sh, night)
    if not bg then return false end

    pcall(function()
        if clip_rect and clip_rect.w and clip_rect.h and clip_rect.w > 0 and clip_rect.h > 0 then
            local cx = math.max(0, clip_rect.x or 0)
            local cy = math.max(0, clip_rect.y or 0)
            local cw = math.min(sw - cx, clip_rect.w)
            local ch = math.min(sh - cy, clip_rect.h)
            if cw > 0 and ch > 0 then
                bb:blitFrom(bg, cx, cy, cx, cy, cw, ch)
            end
        else
            bb:blitFrom(bg, 0, 0, 0, 0, sw, sh)
        end
    end)
    return true
end

return M

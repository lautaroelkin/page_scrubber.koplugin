--[[
    page_scrubber.koplugin/icon_manager.lua
    Resuelve iconos SVG priorizando overrides del usuario.
    Los reemplazos viven en settings/page_scrubber/icons/ y NO se borran al actualizar el plugin.
]]--

local DataStorage = require("datastorage")

local plugin_path = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"

local MAX_SVG_BYTES = 512 * 1024   -- un ícono pesado solo hace lento el redibujado

local IconManager = {}

local function basenameOf(filename)
    return (filename or ""):match("([^/\\]+)$") or ""
end

local _lfs
local function getLfs()
    if _lfs == nil then
        local ok, lfs = pcall(require, "libs/libkoreader-lfs")
        if not (ok and lfs) then
            ok, lfs = pcall(require, "lfs")
        end
        _lfs = (ok and lfs) or false
    end
    return _lfs or nil
end

local function fileExists(p)
    if not p or p == "" then return false end
    local lfs = getLfs()
    if lfs then return lfs.attributes(p, "mode") == "file" end
    local f = io.open(p, "r")
    if f then f:close(); return true end
    return false
end

local _custom_dir
function IconManager.getCustomDir()
    if not _custom_dir then
        _custom_dir = DataStorage:getSettingsDir() .. "/page_scrubber/icons"
    end
    return _custom_dir
end

function IconManager.ensureCustomDir()
    local dir = IconManager.getCustomDir()
    local lfs = getLfs()
    if lfs and lfs.attributes(dir, "mode") ~= "directory" then
        pcall(function() require("util").makePath(dir) end)
    end
    return dir
end

-- Path final: custom > plugin/icons > plugin root. Devuelve nil si no existe en ningún lado.
function IconManager.resolvePath(filename)
    local basename = basenameOf(filename)
    if basename == "" then return nil end
    local custom = IconManager.getCustomDir() .. "/" .. basename
    if fileExists(custom) then return custom end
    local in_plugin = plugin_path .. "icons/" .. basename
    if fileExists(in_plugin) then return in_plugin end
    local in_root = plugin_path .. basename
    if fileExists(in_root) then return in_root end
    return nil
end

function IconManager.hasCustom(filename)
    local basename = basenameOf(filename)
    if basename == "" then return false end
    return fileExists(IconManager.getCustomDir() .. "/" .. basename)
end

function IconManager.isSvgFile(p)
    return type(p) == "string" and p:lower():match("%.svg$") ~= nil
end

-- Copia src_path como override de `filename`. Valida extensión, tamaño y que parezca un SVG.
-- Escribe a un temporal y renombra, así un corte a mitad de copia no deja un ícono roto.
function IconManager.setCustom(filename, src_path)
    local basename = basenameOf(filename)
    if basename == "" or not fileExists(src_path) then
        return false, "missing file"
    end
    if not IconManager.isSvgFile(src_path) then
        return false, "not an .svg"
    end

    local fin = io.open(src_path, "rb")
    if not fin then return false, "cannot open source" end
    local data = fin:read("*a")
    fin:close()

    if not data or #data == 0 then return false, "empty file" end
    if #data > MAX_SVG_BYTES then return false, "file too big" end
    if not data:lower():find("<svg", 1, true) then return false, "not a valid SVG" end

    local dir = IconManager.ensureCustomDir()
    local dst = dir .. "/" .. basename
    local tmp = dst .. ".tmp"

    local fout = io.open(tmp, "wb")
    if not fout then return false, "cannot write" end
    local ok_w = fout:write(data)
    fout:close()
    if not ok_w then
        os.remove(tmp)
        return false, "write failed"
    end

    os.remove(dst)
    local ok_r, err = os.rename(tmp, dst)
    if not ok_r then
        os.remove(tmp)
        return false, err or "rename failed"
    end
    return true
end

function IconManager.clearCustom(filename)
    local basename = basenameOf(filename)
    if basename == "" then return false end
    local p = IconManager.getCustomDir() .. "/" .. basename
    if fileExists(p) then
        os.remove(p)
        return true
    end
    return false
end

-- Borra solo los .svg de la carpeta de overrides (junta primero, borra después)
function IconManager.clearAllCustom()
    local dir = IconManager.getCustomDir()
    local lfs = getLfs()
    if not lfs or lfs.attributes(dir, "mode") ~= "directory" then return end
    local to_remove = {}
    for entry in lfs.dir(dir) do
        if IconManager.isSvgFile(entry) then
            to_remove[#to_remove + 1] = entry
        end
    end
    for _i, entry in ipairs(to_remove) do
        pcall(os.remove, dir .. "/" .. entry)
    end
end

-- Lista de archivos SVG incluidos en el plugin
local _plugin_icons
function IconManager.listPluginIcons()
    if _plugin_icons then return _plugin_icons end   -- se consulta en cada repintado del menú
    local out = {}
    local dir = plugin_path .. "icons"
    local lfs = getLfs()
    if lfs and lfs.attributes(dir, "mode") == "directory" then
        for entry in lfs.dir(dir) do
            if IconManager.isSvgFile(entry) and not entry:match("^%.") then
                out[#out + 1] = entry
            end
        end
    end
    table.sort(out)
    _plugin_icons = out
    return out
end

return IconManager

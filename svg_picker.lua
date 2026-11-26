--[[
    page_scrubber.koplugin/svg_picker.lua

    Selector de íconos a pantalla completa, copiado del icon_picker.lua de KiKome
    (kobold/ui/icon_picker.lua): las carpetas del dispositivo y sus archivos como una
    grilla de baldosas, con Cancel a la izquierda, el título en el medio, una píldora
    negra de acción a la derecha, la carpeta abierta debajo y la barra de páginas a la
    derecha. Tocar una carpeta la abre, tocar un ícono lo elige (tocarlo otra vez lo
    suelta), deslizar arriba / abajo cambia de página.

    Es una copia autónoma: no necesita que KiKome esté instalado. Lo que KiKome toma de
    sus módulos (fuentes, íconos, barra de páginas, arrastre de la barra) está
    reescrito acá con lo mínimo.

      require("svg_picker").show{
          title        = "Choose an icon",
          action_label = "Use icon",          -- la píldora negra con algo elegido
          none_label   = "Skip",              -- opcional: con él la píldora también funciona
                                              -- sin nada elegido, y on_finish recibe nil
          current      = "/a/icon.svg",       -- opcional: archivo ya elegido
          start_dir    = "/a/carpeta",        -- opcional: carpeta donde abre si no hay current
          extensions   = { "svg" },           -- opcional: lo que lista (por defecto svg y png)
          kind         = "icons",             -- "icons" o "images": solo cambia los textos
          on_finish    = function(path) end,  -- la pantalla ya está cerrada; path es la ruta del
                                              -- archivo elegido, o nil
      }

    Las imágenes demasiado grandes para dibujarse rápido (un svg de más de 200 KB, otro
    archivo de más de 1 MB) muestran un ícono de imagen genérico en su baldosa; igual se
    pueden elegir.
]]--

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local lfs             = require("libs/libkoreader-lfs")

local Screen = Device.screen
local plugin_path = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"

local _ = require("ps_i18n").gettext   -- cargador único de traducciones (ver ps_i18n.lua)

local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local C_FIELD       = Blitbuffer.Color8(0xE8)   -- las baldosas, la píldora apagada
local C_PLACEHOLDER = Blitbuffer.Color8(0x77)

local function U(n) return Screen:scaleBySize(n) end

-- Los tamaños que se piden acá son los de KiKome (13 a 18), pero Page Scrubber dibuja su propio
-- texto bastante más chico (9 a 13 con scaleText). Se traducen a la escala del plugin y se les
-- aplican los mismos ajustes que al resto: "Text size" (small/normal/large) y "UI Scale (%)".
local TEXT_MAP = { [13] = 10, [14] = 10, [15] = 11, [16] = 12, [17] = 12, [18] = 13 }

local function textOffset()
    if not G_reader_settings then return 0 end
    local size = G_reader_settings:readSetting("page_scrubber_text_size")
    if size == "small" then return -2 end
    if size == "large" then
        local eink = (Device.isKindle and Device:isKindle()) or (Device.isKobo and Device:isKobo())
            or (Device.isEink and Device:isEink())
        return eink and 4 or 2
    end
    return 0
end

local function face(size)
    -- "Automatic": exactamente lo que hace KiKome, Font:getFace(fuente, tamaño). Font:getFace ya
    -- escala por la densidad de la pantalla, así que acá NO se escala antes (hacerlo duplicaría el
    -- escalado). Sin la traducción ni el UI Scale; el resto del plugin se comporta como Medium.
    if G_reader_settings and G_reader_settings:readSetting("page_scrubber_text_size") == "automatic" then
        return Font:getFace("cfont", size)
    end
    local base = TEXT_MAP[size] or math.max(8, math.floor(size * 0.7 + 0.5))
    local factor = (G_reader_settings and G_reader_settings:readSetting("page_scrubber_ui_scale")) or 1.0
    local px = math.floor(Screen:scaleBySize(base + textOffset()) * factor + 0.5)
    return Font:getFace("cfont", math.max(Screen:scaleBySize(7), px))
end
local function secondaryFace(size)
    -- "Automatic": igual que face(), Font:getFace ya escala por la densidad de la pantalla, así que no se
    -- escala antes con U() (el path de la carpeta, el conteo y el aviso de "no hay" salían más grandes).
    if G_reader_settings and G_reader_settings:readSetting("page_scrubber_text_size") == "automatic" then
        return Font:getFace("infofont", size)
    end
    return Font:getFace("infofont", U(size))
end
local function subtitleColor()
    local ok, c = pcall(function() return Blitbuffer.Color8(0x22) end)
    if ok and c then return c end
    return Blitbuffer.COLOR_DARK_GRAY
end

-- Una caja exacta de w x h con `child` dibujado en su esquina superior izquierda.
local function fixed(w, h, child)
    return OverlapGroup:new{ dimen = Geom:new{ w = w, h = h }, child }
end

local SCAN_MAX = 600     -- entradas que se miran para contar los íconos de una carpeta
local MAX_SVG  = 200 * 1024
local MAX_IMG_BYTES = 1024 * 1024

-- Archivos que no vale la pena preguntar si son carpetas.
local NOT_FOLDERS = {
    epub = true, pdf = true, mobi = true, azw = true, azw3 = true, kepub = true, cbz = true,
    cbr = true, fb2 = true, djvu = true, txt = true, zip = true, rar = true, json = true,
    xml = true, html = true, htm = true, db = true, lua = true, mp3 = true, mp4 = true,
    gif = true, webp = true, bmp = true, jpg = true, jpeg = true, doc = true, docx = true,
    odt = true, po = true, pot = true, md = true, ttf = true, otf = true, svg = true, png = true,
}

local last_dir = nil   -- la carpeta donde se cerró el selector, para la próxima vez

local function isDir(path) return path ~= nil and lfs.attributes(path, "mode") == "directory" end

local function parentOf(dir)
    local parent = dir:match("^(.*)/[^/]+/*$")
    if not parent or parent == "" then return "/" end
    return parent
end

local function builtinDir()
    local d = plugin_path .. "icons"
    d = d:gsub("//+", "/")
    return d
end

-- Un ícono propio del plugin por nombre ("folder", "arrow-left", ...), teñido con fg.
local function iconWidget(name, size, fg)
    fg = fg or BLACK
    local path
    local ok_im, IconManager = pcall(require, "icon_manager")
    if ok_im and IconManager then path = IconManager.resolvePath(name .. ".svg") end
    if not path then
        local p = plugin_path .. "icons/" .. name .. ".svg"
        if lfs.attributes(p, "mode") == "file" then path = p end
    end
    if path then
        local ok, w = pcall(function()
            return ImageWidget:new{
                file = path, width = size, height = size,
                alpha = true, fgcolor = fg,
                original_in_nightmode = false,
                file_do_cache = false,
            }
        end)
        if ok and w then return w end
    end
    local bs = math.max(1, U(2))
    return FrameContainer:new{
        bordersize = bs, padding = 0,
        fixed(size - 2 * bs, size - 2 * bs, HorizontalSpan:new{ width = 0 }),
    }
end

-- Una píldora redondeada de exactamente h de alto alrededor de un texto. Devuelve ella y su ancho.
local function pill(text, h, bg, fg, bold)
    local t = TextWidget:new{ text = text, face = face(16), bold = bold, fgcolor = fg }
    local th = t:getSize().h
    local top = math.floor((h - th) / 2)
    local frame = FrameContainer:new{
        bordersize = 0, radius = math.floor(h / 2), background = bg,
        padding = 0, padding_left = U(18), padding_right = U(18),
        padding_top = top, padding_bottom = h - th - top,
        t,
    }
    return frame, frame:getSize().w
end

-- Texto con sus primeros caracteres cortados (y "…" al principio) hasta que entre,
-- para que el final de la ruta siga visible.
local function tail(text, f, max_w)
    local function width(s)
        local t = TextWidget:new{ text = s, face = f }
        local w = t:getSize().w
        t:free()
        return w
    end
    if width(text) <= max_w then return text end
    local guard = 0
    while text ~= "" and width("…" .. text) > max_w and guard < 300 do
        text = (text:gsub("^[%z\1-\127\194-\244][\128-\191]*", "", 1))
        guard = guard + 1
    end
    return "…" .. text
end

local function inside(r, pos)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

-- ── Barra de páginas (igual a KoboldWidgets.pageBar y compañeras) ─────────
local function pageBar(opts)
    local w, h, arrow = opts.w, opts.h, opts.arrow
    local line_w  = Screen:scaleBySize(2)
    local thumb_w = Screen:scaleBySize(8)
    local thumb_min_h = Screen:scaleBySize(24)
    local track_h = h - 2 * arrow
    local multi = opts.pages > 1
    local track = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = track_h },
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = track_h },
            LineWidget:new{
                dimen = Geom:new{ w = line_w, h = track_h },
                background = Blitbuffer.COLOR_LIGHT_GRAY,
            },
        },
    }
    if multi then
        local thumb_h = math.max(thumb_min_h, math.floor(track_h / opts.pages))
        local thumb_y = math.floor((track_h - thumb_h) * (opts.page - 1) / (opts.pages - 1))
        track[#track + 1] = VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = thumb_y },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = math.floor((w - thumb_w) / 2) },
                FrameContainer:new{
                    bordersize = 0, padding = 0,
                    radius = math.floor(thumb_w / 2),
                    background = Blitbuffer.COLOR_DARK_GRAY,
                    fixed(thumb_w, thumb_h, HorizontalSpan:new{ width = 0 }),
                },
            },
        }
    end
    local function arrowCell(name)
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = arrow },
            multi and iconWidget(name, arrow, BLACK) or HorizontalSpan:new{ width = arrow },
        }
    end
    return VerticalGroup:new{
        arrowCell("chevron-up"),
        track,
        arrowCell("chevron-down"),
    }
end

-- La página que pide un toque en la barra: `y` se mide desde el borde de arriba de la barra.
local function pageBarTarget(y, opts)
    if opts.pages <= 1 then return nil end
    if y < opts.arrow then return opts.page - 1 end
    if y >= opts.h - opts.arrow then return opts.page + 1 end
    local frac = (y - opts.arrow) / math.max(opts.h - 2 * opts.arrow, 1)
    return math.floor(frac * opts.pages) + 1
end

-- La página para un dedo que arrastra por la barra: el centro del pulgar queda en `y`.
local function pageBarDragTarget(y, opts)
    if opts.pages <= 1 then return nil end
    local track_h = opts.h - 2 * opts.arrow
    local thumb_h = math.max(Screen:scaleBySize(24), math.floor(track_h / opts.pages))
    local span = math.max(track_h - thumb_h, 1)
    local frac = (y - opts.arrow - thumb_h / 2) / span
    frac = math.max(0, math.min(1, frac))
    return math.floor(frac * (opts.pages - 1) + 0.5) + 1
end

local ok_ffiutil, ffiUtil = pcall(require, "ffi/util")
local function now()
    if ok_ffiutil and ffiUtil and ffiUtil.getTimestamp then
        local ok, sec, usec = pcall(ffiUtil.getTimestamp)
        if ok and sec then return sec + (usec or 0) / 1e6 end
    end
    return os.time()
end

-- Deja arrastrar la barra de páginas como la perilla de un slider (igual a
-- KoboldWidgets.registerBarDrag). Llamar DESPUÉS de registrar los gestos propios.
local function registerBarDrag(widget, cfg)
    local state = { active = false, last = nil, stamp = 0 }
    local RECENT, STALE = 0.4, 3
    local full = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 }

    local function onBar(ges)
        local rect, bar = cfg.rect(), cfg.bar()
        if not (rect and bar and bar.pages > 1 and ges and ges.pos) then return false end
        local slack = Screen:scaleBySize(12)
        return ges.pos:intersectWith(Geom:new{
            x = rect.x - slack, y = rect.y, w = rect.w + slack, h = rect.h,
        })
    end
    local function follow(ges)
        local bar = cfg.bar()
        local page = bar and pageBarDragTarget(ges.pos.y - cfg.top(), bar)
        if page then cfg.goTo(page) end
    end
    local function finish()
        state.active = false
        state.last = now()
    end
    local function release()
        if not state.active then return false end
        finish()
        return true
    end
    widget._bar_drag_busy = function()
        local t = now()
        if state.active then
            if t - state.stamp > STALE then
                state.active = false
            else
                finish()
                return true
            end
        end
        return state.last ~= nil and t - state.last < RECENT
    end
    if not widget._bar_drag_wrapped then
        widget._bar_drag_wrapped = true
        local original = widget.onGesture
        widget.onGesture = function(self, ev)
            if ev and ev.ges == "swipe" and self._bar_drag_busy and self._bar_drag_busy() then
                return true
            end
            return original(self, ev)
        end
    end

    widget:registerTouchZones({
        {
            id = "PSPickerBarHold", ges = "hold", screen_zone = full,
            handler = function(ges)
                if onBar(ges) then state.active = true; state.stamp = now(); return true end
                return false
            end,
        },
        {
            id = "PSPickerBarPan", ges = "pan", screen_zone = full,
            handler = function(ges)
                if state.active then state.stamp = now(); follow(ges); return true end
                if ges.direction == "west" or ges.direction == "east" then return false end
                if onBar(ges) then
                    state.active = true
                    state.stamp = now()
                    follow(ges)
                    return true
                end
                return false
            end,
        },
        {
            id = "PSPickerBarHoldPan", ges = "hold_pan", screen_zone = full,
            handler = function(ges)
                if not state.active then return false end
                state.stamp = now()
                follow(ges)
                return true
            end,
        },
        { id = "PSPickerBarPanRelease",  ges = "pan_release",  screen_zone = full, handler = release },
        { id = "PSPickerBarHoldRelease", ges = "hold_release", screen_zone = full, handler = release },
        {
            id = "PSPickerBarSwipe", ges = "swipe", screen_zone = full,
            handler = function()
                return widget._bar_drag_busy()
            end,
        },
    })
    return state
end

-- ── El selector ────────────────────────────────────────────────────────────
local Picker = InputContainer:extend{
    name = "page_scrubber_svg_picker",
    covers_fullscreen = true,
    dithered = true,
    title = nil, action_label = nil, none_label = nil, current = nil, on_finish = nil,
    start_dir = nil, extensions = nil, kind = "icons",
}

function Picker:isPickable(name)
    local ext = tostring(name):lower():match("%.(%w+)$")
    return ext ~= nil and self.ext_set[ext] == true
end

function Picker:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.page = 1
    self.counts, self.cache = {}, {}

    self.ext_set = {}
    for _i, e in ipairs(self.extensions or { "svg", "png" }) do self.ext_set[e:lower()] = true end
    self.is_images = (self.kind == "images")

    -- Dónde abre: la carpeta del archivo que ya estaba elegido, si no la carpeta que se pidió,
    -- si no la última usada, si no la de íconos del plugin, si no la carpeta de inicio.
    local current = (type(self.current) == "string" and lfs.attributes(self.current, "mode") == "file")
        and self.current or nil
    local start = current and current:match("^(.*)/[^/]+$") or nil
    if not isDir(start) then start = self.start_dir end
    if not isDir(start) then start = last_dir end
    if not isDir(start) and not self.is_images then start = builtinDir() end
    if not isDir(start) then start = G_reader_settings and G_reader_settings:readSetting("home_dir") end
    if not isDir(start) then start = "/" end
    self.dir = (start:gsub("(.)/+$", "%1"))
    self.picked = current

    self:readDir()
    self:build()
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    if Device:isTouchDevice() then
        self.ges_events = {
            TapPicker = { GestureRange:new{ ges = "tap", range = self.dimen } },
            SwipePicker = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
        registerBarDrag(self, {
            rect = function() return self.bar_rect end,
            bar  = function() return self.bar end,
            top  = function() return self.bar_rect.y end,
            goTo = function(page) self:goToPage(page) end,
        })
    end
end

-- Las carpetas y archivos de la carpeta abierta: la baldosa "Parent folder", las
-- carpetas y luego los archivos, cada grupo por nombre.
function Picker:readDir()
    local dir = self.dir
    local folders, icons = {}, {}
    local ok, iter, st = pcall(lfs.dir, dir)
    if ok then
        for name in iter, st do
            if name:sub(1, 1) ~= "." and not name:match("%.sdr$") then
                local path = (dir == "/" and "" or dir) .. "/" .. name
                if self:isPickable(name) then
                    icons[#icons + 1] = { kind = "icon", name = name, key = name:lower(), path = path }
                else
                    local ext = name:match("%.(%w+)$")
                    if not (ext and NOT_FOLDERS[ext:lower()]) and isDir(path) then
                        folders[#folders + 1] = { kind = "folder", name = name, key = name:lower(), path = path }
                    end
                end
            end
        end
    end
    local function byKey(a, b)
        if a.key ~= b.key then return a.key < b.key end
        return a.name < b.name
    end
    table.sort(folders, byKey)
    table.sort(icons, byKey)
    local items = {}
    if dir ~= "/" then
        items[#items + 1] = { kind = "up", name = _("Parent folder"), path = parentOf(dir) }
    end
    for _i, f in ipairs(folders) do items[#items + 1] = f end
    for _i, f in ipairs(icons) do items[#items + 1] = f end
    self.items = items
end

-- "3 icons" debajo del nombre de una carpeta, contado solo por el nombre (no se abre ni se
-- mide nada), mirando como mucho SCAN_MAX entradas.
function Picker:folderCount(path)
    local known = self.counts[path]
    if known ~= nil then return known end
    local text = ""
    local ok, iter, st = pcall(lfs.dir, path)
    if ok then
        local n, seen, cut = 0, 0, false
        for name in iter, st do
            seen = seen + 1
            if name:sub(1, 1) ~= "." and self:isPickable(name) then n = n + 1 end
            if seen >= SCAN_MAX then cut = true; break end
        end
        local one, many, plus, none
        if self.is_images then
            one, many, plus, none = _("1 image"), _("%d images"), _("%d+ images"), _("No images")
        else
            one, many, plus, none = _("1 icon"), _("%d icons"), _("%d+ icons"), _("No icons")
        end
        if n == 0 then
            text = cut and "" or none
        elseif cut then
            text = string.format(plus, n)
        else
            text = (n == 1) and one or string.format(many, n)
        end
    end
    self.counts[path] = text
    return text
end

-- La imagen de la baldosa de un archivo. Se hace una vez por carpeta y tamaño.
function Picker:iconInner(item, size)
    local key = item.path .. "|" .. size
    local made = self.cache[key]
    if made then return made end
    local light = false
    local attr = lfs.attributes(item.path)
    if attr then
        if item.name:lower():match("%.svg$") then
            light = (attr.size or 0) <= MAX_SVG
        else
            light = (attr.size or 0) <= MAX_IMG_BYTES
        end
    end
    if light then
        local ok, w = pcall(function()
            return ImageWidget:new{
                file = item.path, width = size, height = size,
                alpha = true, original_in_nightmode = false,
                file_do_cache = false,
            }
        end)
        if ok and w then made = w end
    end
    if not made then made = iconWidget("image", size, C_PLACEHOLDER) end
    self.cache[key] = made
    return made
end

-- Una celda de la grilla: una baldosa gris con su imagen, el nombre debajo y, para una
-- carpeta, cuántos archivos tiene.
function Picker:cell(item, cell_w, tile)
    local selected = (item.kind == "icon" and item.path == self.picked)
    local b = selected and U(3) or 0
    local inner
    if item.kind == "icon" then
        inner = self:iconInner(item, math.floor(tile * 0.56))
    elseif item.kind == "folder" then
        inner = iconWidget("folder", math.floor(tile * 0.46), BLACK)
    else
        inner = iconWidget("arrow-left", math.floor(tile * 0.40), BLACK)
    end
    local inside_w = tile - 2 * b
    local box = FrameContainer:new{
        bordersize = b, color = BLACK, background = C_FIELD, radius = U(14), padding = 0,
        fixed(inside_w, inside_w, CenterContainer:new{
            dimen = Geom:new{ w = inside_w, h = inside_w }, inner,
        }),
    }
    local label_h, sub_h = U(22), U(18)
    local label = TextWidget:new{
        text = item.name, face = face(14), fgcolor = BLACK,
        max_width = cell_w - U(8), bold = selected,
    }
    local sub
    if item.kind == "folder" then
        local count = self:folderCount(item.path)
        if count ~= "" then
            sub = TextWidget:new{
                text = count, face = secondaryFace(12),
                fgcolor = subtitleColor(), max_width = cell_w - U(8),
            }
        end
    end
    return VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = U(4) },
        CenterContainer:new{ dimen = Geom:new{ w = cell_w, h = tile }, box },
        VerticalSpan:new{ width = U(6) },
        CenterContainer:new{ dimen = Geom:new{ w = cell_w, h = label_h }, label },
        CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = sub_h },
            sub or HorizontalSpan:new{ width = 0 },
        },
    }
end

function Picker:canFinish()
    return self.picked ~= nil or self.none_label ~= nil
end

function Picker:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local margin = U(30)
    local content_w = W - 2 * margin
    local gap = U(12)

    local body = VerticalGroup:new{ align = "left" }
    local y = U(32)
    body[#body + 1] = VerticalSpan:new{ width = y }

    local default_action = self.is_images and _("Use image") or _("Use icon")

    -- Encabezado: Cancel, el título y la píldora de acción.
    local header_h = U(52)
    local can = self:canFinish()
    local has_pick = self.picked ~= nil
    local label = has_pick and (self.action_label or default_action)
        or (self.none_label or self.action_label or default_action)
    local create, create_w = pill(label, U(40), can and BLACK or C_FIELD, can and WHITE or C_PLACEHOLDER, true)
    local cancel = TextWidget:new{ text = _("Cancel"), face = face(17) }
    local side_w = math.max(create_w, cancel:getSize().w) + U(8)
    local title = TextWidget:new{
        text = self.title or (self.is_images and _("Choose an image") or _("Choose an icon")),
        face = face(18), bold = true,
        max_width = math.max(U(60), content_w - 2 * side_w - gap),
    }
    body[#body + 1] = fixed(content_w, header_h, HorizontalGroup:new{
        align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = side_w, h = header_h }, cancel },
        CenterContainer:new{ dimen = Geom:new{ w = content_w - 2 * side_w, h = header_h }, title },
        RightContainer:new{ dimen = Geom:new{ w = side_w, h = header_h }, create },
    })
    self.cancel_rect = Geom:new{ x = margin, y = y, w = side_w, h = header_h }
    self.create_rect = Geom:new{ x = margin + content_w - side_w, y = y, w = side_w, h = header_h }
    y = y + header_h
    body[#body + 1] = VerticalSpan:new{ width = U(6) }
    y = y + U(6)

    -- La línea debajo del encabezado: la carpeta abierta.
    local sub_h = U(28)
    local sface = secondaryFace(14)
    body[#body + 1] = fixed(content_w, sub_h, LeftContainer:new{
        dimen = Geom:new{ w = content_w, h = sub_h },
        TextWidget:new{
            text = tail(self.dir, sface, content_w - U(8)), face = sface,
            fgcolor = subtitleColor(),
        },
    })
    y = y + sub_h
    body[#body + 1] = VerticalSpan:new{ width = gap }
    y = y + gap

    -- La grilla: tantas filas enteras como entren.
    local grid_h = H - U(20) - y
    local bar_w, bar_gap, arrow = U(28), U(10), U(24)
    local grid_w = content_w - bar_w - bar_gap
    local cols = math.max(3, math.min(6, math.floor(grid_w / U(130))))
    local cell_w = math.floor(grid_w / cols)
    local tile = cell_w - U(16)
    local cell_h = U(4) + tile + U(6) + U(22) + U(18) + U(10)
    local rows_per_page = math.max(1, math.floor(grid_h / cell_h))
    local per_page = cols * rows_per_page
    self.pages = math.max(1, math.ceil(#self.items / per_page))
    self.page = math.max(1, math.min(self.page, self.pages))
    local first = (self.page - 1) * per_page
    self.y_grid, self.grid_end = y, y + grid_h
    self.cell_hits = {}

    local grid = VerticalGroup:new{ align = "left" }
    if #self.items == 0 then
        grid[#grid + 1] = CenterContainer:new{
            dimen = Geom:new{ w = grid_w, h = grid_h },
            TextWidget:new{
                text = self.is_images and _("No folders or images here.") or _("No folders or icons here."),
                face = secondaryFace(15),
                fgcolor = subtitleColor(), max_width = grid_w,
            },
        }
    else
        local used = 0
        for r = 0, rows_per_page - 1 do
            local row = HorizontalGroup:new{}
            local any = false
            for c = 1, cols do
                local item = self.items[first + r * cols + c]
                if item then
                    any = true
                    row[#row + 1] = self:cell(item, cell_w, tile)
                    self.cell_hits[#self.cell_hits + 1] = {
                        rect = Geom:new{
                            x = margin + (c - 1) * cell_w, y = y + r * cell_h, w = cell_w, h = cell_h,
                        },
                        item = item,
                    }
                else
                    row[#row + 1] = HorizontalSpan:new{ width = cell_w }
                end
            end
            if not any then break end
            grid[#grid + 1] = row
            used = used + cell_h
        end
        grid[#grid + 1] = VerticalSpan:new{ width = math.max(0, grid_h - used) }
    end

    self.bar = { w = bar_w, h = grid_h, page = self.page, pages = self.pages, arrow = arrow }
    local bar_x = margin + grid_w + math.floor(bar_gap / 2)
    self.bar_rect = Geom:new{ x = bar_x, y = y, w = W - bar_x, h = grid_h }
    body[#body + 1] = HorizontalGroup:new{
        align = "top",
        grid,
        HorizontalSpan:new{ width = bar_gap },
        pageBar(self.bar),
    }

    local layers = OverlapGroup:new{
        dimen = Geom:new{ w = W, h = H },
        FrameContainer:new{ bordersize = 0, padding = 0, padding_left = margin, body },
    }
    self[1] = FrameContainer:new{
        width = W, height = H, bordersize = 0, padding = 0,
        background = WHITE,
        layers,
    }
end

-- ── Toques ─────────────────────────────────────────────────────────────────
function Picker:markClosed()
    if self.closed then return end
    self.closed = true
    self.cache = {}
end

function Picker:dismiss()
    self:markClosed()
    UIManager:close(self, "ui")
    return true
end

function Picker:finish()
    if not self:canFinish() then return end
    local picked = self.picked
    if picked then last_dir = self.dir end
    self:markClosed()
    UIManager:close(self, "ui")
    if self.on_finish then self.on_finish(picked or nil) end
end

function Picker:goToPage(page)
    page = math.max(1, math.min(self.pages, page))
    if page == self.page then return end
    self.page = page
    self:build()
    local region = Geom:new{ x = 0, y = self.y_grid, w = Screen:getWidth(), h = self.grid_end - self.y_grid }
    UIManager:setDirty(self, function() return "ui", region end)
end

-- Abre una carpeta: se leen sus archivos, la página vuelve a la primera.
function Picker:openDir(path)
    self.dir = path
    self.page = 1
    self.cache = {}
    self:readDir()
    self:build()
    UIManager:setDirty(self, "ui")
end

function Picker:onTapPicker(_ev, ges)
    local pos = ges.pos
    if inside(self.cancel_rect, pos) then return self:dismiss() end
    if inside(self.create_rect, pos) then
        self:finish()
        return true
    end
    if inside(self.bar_rect, pos) then
        local page = pageBarTarget(pos.y - self.y_grid, self.bar)
        if page then self:goToPage(page) end
        return true
    end
    for _i, hit in ipairs(self.cell_hits or {}) do
        if inside(hit.rect, pos) then
            local item = hit.item
            if item.kind == "icon" then
                -- uno a la vez: tocarlo de nuevo lo suelta
                self.picked = (self.picked ~= item.path) and item.path or nil
                self:build()
                UIManager:setDirty(self, "ui")
            else
                self:openDir(item.path)
            end
            return true
        end
    end
    return true
end

-- Deslizar hacia arriba para la página siguiente, hacia abajo para la anterior.
function Picker:onSwipePicker(_ev, ges)
    if ges.pos.y < (self.y_grid or 0) then return true end
    if ges.direction == "north" then
        self:goToPage(self.page + 1)
    elseif ges.direction == "south" then
        self:goToPage(self.page - 1)
    end
    return true
end

function Picker:onClose()
    return self:dismiss()
end

local SvgPicker = {}

function SvgPicker.show(opts)
    local picker = Picker:new(opts or {})
    UIManager:show(picker, "ui")
    return picker
end

-- Piezas que comparten los demás selectores y hojas de Page Scrubber (ps_list_picker.lua,
-- ps_sheet.lua, ps_toast.lua), copiadas de KiKome igual que este selector: así no se
-- repite el mismo código de íconos, píldoras y barra de páginas.
SvgPicker.kit = {
    _ = _, U = U, face = face, fixed = fixed, tail = tail, pill = pill,
    iconWidget = iconWidget, subtitleColor = subtitleColor, inside = inside,
    pageBar = pageBar, pageBarTarget = pageBarTarget, registerBarDrag = registerBarDrag,
    C_FIELD = C_FIELD, C_PLACEHOLDER = C_PLACEHOLDER,
}

return SvgPicker

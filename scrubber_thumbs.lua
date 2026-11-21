--[[
Miniaturas del scrubber generadas en el mismo proceso (solo Android).

Por qué: el ReaderThumbnail estándar genera cada miniatura con un fork() de todo el proceso, la dibuja en el hijo y
manda el resultado (varios MB) por un pipe que el padre deserializa. En Android el fork de un proceso con ART es
caro y en algunos equipos directamente aborta; ZenOS resolvió lo mismo dibujando la página en el proceso principal
y restaurando la posición del libro, y eso es lo que se replica acá, acotado para no tocar a nadie más:

  * solo Android;
  * solo libros reflowable (CRE) con una sola pagina visible, en vista de paginas o de scroll (en scroll se dibuja
    desde el inicio de la pagina pedida; se desactiva con M.ALLOW_SCROLL = false);
  * solo las requests del propio scrubber (lotes "page_scrubber_*", "scrubber_toc_*", "safe_reopen_*");
    el resto de los usuarios de ReaderThumbnail (page browser, book map, ZenOS...) siguen igual;
  * si algo falla se vuelve al metodo estandar (fork) para esa miniatura, y tras 3 fallos seguidos se desactiva;
  * se apaga con G_reader_settings "page_scrubber_inprocess_thumbs" = false.

El render es sincronico: la posicion del libro se guarda (getCurrentPos) y se restaura (gotoPos) dentro de la misma
llamada, asi que nada puede salir de ahi con el libro en otra pagina.
]]

local M = {
    stats = { inproc = 0, fallback = 0, failed_in_a_row = 0 },
    disabled = false,
    ALLOW_SCROLL = true,    -- false: en modo scroll se sigue usando el fork estandar
    debug = false,          -- true: mide y registra cada miniatura (lo activa scrubber_ui con su interruptor)
    log = function() end,   -- lo reemplaza scrubber_ui (escribe al archivo de diagnostico)
}

local OUR_PREFIXES = { "page_scrubber_", "scrubber_toc_", "safe_reopen_" }

local function isOurs(batch_id)
    if type(batch_id) ~= "string" then return false end
    for _, p in ipairs(OUR_PREFIXES) do
        if batch_id:sub(1, #p) == p then return true end
    end
    return false
end

local function nowT()
    local ok, t = pcall(function() return require("ui/time").now() end)
    return ok and t or nil
end

local function msSince(t0)
    if not t0 then return -1 end
    local ok, ms = pcall(function()
        local T = require("ui/time")
        return T.to_ms(T.since(t0))
    end)
    return ok and ms or -1
end

-- ¿Esta request se puede dibujar en el proceso principal?
function M.canRender(thumb, request)
    if M.disabled then return false end
    if not isOurs(request.batch_id) then return false end
    local ui = thumb and thumb.ui
    if not (ui and ui.rolling and ui.document and ui.view) then return false end
    if not thumb.bb_type then return false end
    local mode = ui.view.view_mode
    if mode ~= "page" and not (mode == "scroll" and M.ALLOW_SCROLL) then return false end
    if ui.rolling.rendering_state then return false end
    local doc = ui.document
    if doc.getVisiblePageCount and doc:getVisiblePageCount() ~= 1 then return false end
    if not (doc.drawCurrentViewByPage and doc.getCurrentPos and doc.gotoPos) then return false end
    return true
end

-- Dibuja la pagina request.page y devuelve un TileCacheItem (o nil, error). Siempre restaura la posicion del libro.
function M.render(thumb, request)
    local Blitbuffer = require("ffi/blitbuffer")
    local Geom = require("ui/geometry")
    local RenderImage = require("ui/renderimage")
    local TileCacheItem = require("document/tilecacheitem")
    local Screen = require("device").screen

    local ui = thumb.ui
    local doc = ui.document
    local saved_pos = doc:getCurrentPos()
    local bb, tile

    local ok, err = pcall(function()
        local width, height = Screen:getWidth(), Screen:getHeight()
        local rect = Geom:new{ w = width, h = height }
        bb = Blitbuffer.new(width, height, thumb.bb_type)
        doc:drawCurrentViewByPage(bb, 0, 0, rect, request.page)

        -- Resaltados (mismo aspecto que el worker estandar: un poco mas oscuros). Si falla, la miniatura sale igual.
        pcall(function()
            local view = ui.view
            if view.highlight_visible and view.drawSavedHighlight and view.highlight then
                local proxy = setmetatable({
                    state = { page = request.page, zoom = 1, rotation = 0, offset = Geom:new() },
                    page_scroll = false,
                    visible_area = rect,
                    highlight = setmetatable({
                        page_boxes = {},
                        lighten_factor = math.max(view.highlight.lighten_factor or 0, 0.3),
                    }, { __index = view.highlight }),
                }, { __index = view })
                proxy:drawSavedHighlight(bb, 0, 0)
            end
        end)

        -- Marca de pagina marcada (dogear). Si falla, la miniatura sale igual.
        pcall(function()
            local dogear = ui.view.dogear
            if dogear and ui.bookmark and ui.bookmark:isPageBookmarked(doc:getXPointer()) then
                local icon_x = require("ui/bidi").mirroredUILayout() and 0 or width - dogear.icon:getWidth()
                dogear.icon:paintTo(bb, icon_x, dogear.dogear_y_offset)
            end
        end)

        -- Se recorta la barra de estado superior alternativa, si la hay.
        local header_height = doc.getHeaderHeight and doc:getHeaderHeight() or 0
        if header_height and header_height > 0 then
            local cropped = bb:viewport(0, header_height, width, height - header_height):copy()
            bb:free()
            bb = cropped
        end

        local scale = math.min(request.width / bb:getWidth(), request.height / bb:getHeight())
        bb = RenderImage:scaleBlitBuffer(bb,
            math.floor(bb:getWidth() * scale),
            math.floor(bb:getHeight() * scale), true)
        tile = TileCacheItem:new{ bb = bb, pageno = request.page }
        tile.size = tonumber(tile.bb.stride) * tile.bb.h
    end)

    -- La posicion se restaura pase lo que pase.
    if saved_pos then pcall(doc.gotoPos, doc, saved_pos) end

    if not ok then
        if bb then pcall(bb.free, bb) end
        return nil, err
    end
    return tile
end

-- Mide cuanto tarda una miniatura por el camino estandar (fork), para comparar en el log.
local function wrapStockLatency(request)
    if not M.debug then return end
    if not isOurs(request.batch_id) then return end
    local cb = request.when_generated_callback
    if not cb then return end
    local t0 = nowT()
    request.when_generated_callback = function(tile, batch_id, async)
        pcall(M.log, string.format("thumb[fork] p=%s req=%sx%s total=%.0f ms ok=%s",
            tostring(request.page), tostring(request.width), tostring(request.height),
            msSince(t0), tostring(tile ~= nil)))
        return cb(tile, batch_id, async)
    end
end

function M.install()
    if M._installed then return M._installed end

    local ok_dev, Device = pcall(require, "device")
    if not (ok_dev and Device and Device.isAndroid and Device:isAndroid()) then
        M._installed = "no-android"
        return M._installed
    end
    if G_reader_settings and G_reader_settings.nilOrTrue
            and not G_reader_settings:nilOrTrue("page_scrubber_inprocess_thumbs") then
        M._installed = "apagado"
        return M._installed
    end

    local ok_rt, RT = pcall(require, "apps/reader/modules/readerthumbnail")
    if not (ok_rt and type(RT) == "table" and RT.startTileGeneration and RT.checkTileGeneration) then
        M._installed = "sin-readerthumbnail"
        return M._installed
    end
    if RT._ps_inprocess then
        M._installed = "ya-instalado"
        return M._installed
    end
    RT._ps_inprocess = true

    local prev_start = RT.startTileGeneration
    local prev_check = RT.checkTileGeneration

    RT.startTileGeneration = function(self, request)
        if not M.canRender(self, request) then
            wrapStockLatency(request)
            return prev_start(self, request)
        end

        local t0 = M.debug and nowT() or nil
        local tile, err = M.render(self, request)
        if tile then
            M.stats.inproc = M.stats.inproc + 1
            M.stats.failed_in_a_row = 0
            if M.debug then
                pcall(M.log, string.format("thumb[inproc] p=%s req=%sx%s tile=%sx%s %.0f ms mode=%s",
                    tostring(request.page), tostring(request.width), tostring(request.height),
                    tostring(tile.bb:getWidth()), tostring(tile.bb:getHeight()), msSince(t0),
                    tostring(self.ui.view and self.ui.view.view_mode)))
            end
            -- Se entrega ya (igual que cuando la miniatura estaba en cache), sin esperar al proximo ciclo.
            if self.tile_cache then self.tile_cache:insert(request.hash, tile) end
            if request.when_generated_callback then
                request.when_generated_callback(tile, request.batch_id, true)
            end
            request._ps_delivered = true
            return true
        end

        M.stats.fallback = M.stats.fallback + 1
        M.stats.failed_in_a_row = M.stats.failed_in_a_row + 1
        if M.debug then
            pcall(M.log, "thumb[inproc] fallo (" .. tostring(err) .. "); se usa el metodo estandar para esta miniatura")
        end
        if M.stats.failed_in_a_row >= 3 then
            M.disabled = true
            if M.debug then
                pcall(M.log, "thumb[inproc] desactivado por 3 fallos seguidos; de ahora en mas se usa el metodo estandar")
            end
        end
        wrapStockLatency(request)
        return prev_start(self, request)
    end

    RT.checkTileGeneration = function(self, request)
        if request._ps_delivered then
            request._ps_delivered = nil
            return false   -- ya entregada: no queda nada en progreso
        end
        return prev_check(self, request)
    end

    M._installed = "instalado"
    return M._installed
end

return M

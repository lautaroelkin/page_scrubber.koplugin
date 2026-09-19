--[[
    page_scrubber.koplugin/split_landscape_view.lua
    Modo Apaisado (Landscape): Previsualización a la izquierda (60%), Menú a la derecha (40%).
    Hoja completa proporcional sin achatado, pestañas sobre la Polaroid y alineación simétrica.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")

local _dict = {}
local _lang = "en"
if G_reader_settings then
    local l = G_reader_settings:readSetting("language")
    if type(l) == "string" then _lang = l:sub(1, 2) end
end

if _lang ~= "en" then
    local plugin_path = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
    local po_path = plugin_path .. "locales/" .. _lang .. ".po"
    local f = io.open(po_path, "r")
    if f then
        local current_id
        for line in f:lines() do
            local id = line:match('^msgid%s+"(.*)"')
            if id then current_id = id end
            local str = line:match('^msgstr%s+"(.*)"')
            if str and current_id then
                _dict[current_id] = str
                current_id = nil
            end
        end
        f:close()
    end
end

local function _(text)
    return _dict[text] or text
end

local SplitLandscapeView = {}

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
    if not round_br then bb:paintRect(x + w - r, y + h - r, r, r, color) end
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

local function paintRoundRect(bb, x, y, w, h, r, color)
    paintCornerRect(bb, x, y, w, h, r, color, true, true, true, true)
end

local function paintTopSquareBottomRounded(bb, x, y, w, h, r, color)
    if w <= 0 or h <= 0 then return end
    paintRoundRect(bb, x, y, w, h, r, color)
    if r > 0 and h > r and w > 0 then bb:paintRect(x, y, w, r, color) end
end

local function drawBookmarkRibbon(bb, x, y, w, h, color)
    local cut = math.floor(w / 2)
    local straight = h - cut
    if straight > 0 then bb:paintRect(x, y, w, straight, color) end
    for r = 0, cut - 1 do
        local leg = math.floor(w/2) - r
        if leg > 0 then
            bb:paintRect(x, y + straight + r, leg, 1, color)
            bb:paintRect(x + w - leg, y + straight + r, leg, 1, color)
        end
    end
end

local function paintTripleText(tw, bb, x, y)
    if not tw then return end
    tw:paintTo(bb, x, y)
    tw:paintTo(bb, x + 1, y)
    tw:paintTo(bb, x, y + 1)
end

local function getDocPageAspectRatio(scrubber)
    local doc = scrubber.ui and scrubber.ui.document
    if doc and type(doc.getPageDimension) == "function" then
        local ok, dim = pcall(function() return doc:getPageDimension(scrubber._cur_page) end)
        if ok and dim and dim.w and dim.h and dim.w > 0 and dim.h > 0 then
            return dim.w / dim.h
        end
    end
    return scrubber._sw / scrubber._sh
end

function SplitLandscapeView.getThumbDims(scrubber)
    local sw, sh = scrubber._sw, scrubber._sh
    local S = scrubber.S
    local top_h = scrubber._top_bar_dimen.h
    local bar_h = S(6) * 2 + S(38) * 2 + S(4)
    local avail_h = sh - top_h - bar_h - S(20)
    local avail_w = sw - (S(16) * 2) - S(16)

    local tab_h = S(34)
    local tab_sp_y = S(6)
    local status_h = S(32)
    local b_thick = S(3)

    -- La Polaroid toma el 60% del ancho disponible (el menú toma el 40%)
    local card_w = math.floor(avail_w * 0.60)
    local card_h = avail_h - tab_h - tab_sp_y

    local max_pr_w = card_w - b_thick * 2
    local max_pr_h = card_h - status_h - b_thick * 2

    local ratio = getDocPageAspectRatio(scrubber)
    
    local pr_w = max_pr_w
    local pr_h = math.floor(pr_w / ratio)

    if pr_h > max_pr_h then
        pr_h = max_pr_h
        pr_w = math.floor(pr_h * ratio)
    end

    return pr_w, pr_h
end

function SplitLandscapeView.paint(scrubber, bb)
    scrubber:_updateTexts()

    local sw, sh = scrubber._sw, scrubber._sh
    local S = scrubber.S
    local top_h = scrubber._top_bar_dimen.h

    -- 1. Barra inferior fija (2 líneas de navegación)
    local l1_h = S(38)
    local l2_h = S(38)
    local bar_pad_y = S(6)
    local bar_gap = S(4)
    local bar_h = bar_pad_y * 2 + l1_h + bar_gap + l2_h
    local bar_y = sh - bar_h

    scrubber._bar_dimen = Geom:new{ x = 0, y = bar_y, w = sw, h = bar_h }
    scrubber._grid_dimen = Geom:new{ x = 0, y = top_h, w = sw, h = bar_y - top_h }

    bb:paintRect(0, top_h, sw, bar_y - top_h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(0, bar_y, sw, bar_h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(0, bar_y, sw, S(2), Blitbuffer.COLOR_BLACK)

    -- 2. Reparto de anchos: 60% Polaroid (Izquierda) / 40% Menú (Derecha)
    local pad_x = S(16)
    local gap_col = S(16)
    local tab_h = S(34)
    local tab_sp_y = S(6)
    local avail_h = bar_y - top_h - S(20)
    local avail_w = sw - (pad_x * 2) - gap_col

    local card_w = math.floor(avail_w * 0.60)
    local col_right_w = avail_w - card_w

    local tab_draw_y = top_h + S(2)
    local card_y = tab_draw_y + tab_h + tab_sp_y
    local card_h = avail_h - tab_h - tab_sp_y
    local box_radius = S(12)
    local b_thick = S(3)
    local status_h = S(32)

    local card_x = pad_x
    local right_x = card_x + card_w + gap_col
    local menu_x = right_x

    local max_pr_w = card_w - b_thick * 2
    local max_pr_h = card_h - status_h - b_thick * 2

    scrubber._thumb_req_split_w = max_pr_w
    scrubber._thumb_req_split_h = max_pr_h

    -- Sincronizar selección de ítem activo en Highlights/Notes
    local other_items = scrubber:_getFilteredActiveList() or {}
    if scrubber._active_tab ~= "bookmarks" then
        local found = nil
        local cur_disp = tostring(scrubber:_getDisplayPageInfo(scrubber._cur_page))
        if scrubber._split_selected_item then
            local sel = scrubber._split_selected_item
            local is_on_current_page = (sel.disp_page and sel.disp_page == cur_disp) or (sel.page == scrubber._cur_page)
            if is_on_current_page then
                for _, it in ipairs(other_items) do
                    if it == sel then found = it; break end
                end
            end
        end
        if not found then
            for _, it in ipairs(other_items) do
                if type(it) == "table" and (it.disp_page == cur_disp or it.page == scrubber._cur_page) then
                    found = it; break
                end
            end
        end
        scrubber._split_selected_item = found
    end

    -- =========================================================
    -- PESTAÑAS PRINCIPALES (ARRIBA DE LA POLAROID)
    -- =========================================================
    local font_sz_chiquito = scrubber.S_BOTTOM_GRAY and (scrubber.S_BOTTOM_GRAY - S(4)) or S(10)
    local cur_tab_x = card_x
    local r_tab = math.floor(tab_h / 2)

    -- Sort
    local active_sort = (scrubber._sort_order == "asc") and scrubber.icon_sort_asc or scrubber.icon_sort_desc
    local sort_sz = active_sort and active_sort:getSize() or { w = S(16), h = S(16) }
    local sort_w = sort_sz.w + S(14)
    paintRoundRect(bb, cur_tab_x, tab_draw_y, sort_w, tab_h, r_tab, Blitbuffer.COLOR_BLACK)
    paintRoundRect(bb, cur_tab_x + S(1), tab_draw_y + S(1), sort_w - S(2), tab_h - S(2), math.max(1, r_tab - S(1)), Blitbuffer.COLOR_WHITE)
    if active_sort then
        active_sort:paintTo(bb, cur_tab_x + math.floor((sort_w - sort_sz.w)/2), tab_draw_y + math.floor((tab_h - sort_sz.h)/2))
    end
    scrubber._tab_sort_dimen = Geom:new{ x = cur_tab_x, y = tab_draw_y, w = sort_w, h = tab_h }
    cur_tab_x = cur_tab_x + sort_w + S(6)

    -- Tabs
    local function drawTab(id, icon, count)
        local is_act = (scrubber._active_tab == id)
        local isz_t = icon and icon:getSize() or { w = S(18), h = S(18) }

        if not scrubber._tw_tab_count_normal then
            scrubber._tw_tab_count_normal = TextWidget:new{ text = "", face = Font:getFace("cfont", font_sz_chiquito), fgcolor = Blitbuffer.COLOR_BLACK }
            scrubber._tw_tab_count_bold   = TextWidget:new{ text = "", face = Font:getFace("cfont", font_sz_chiquito), bold = true, fgcolor = Blitbuffer.COLOR_WHITE }
        end
        local tw_cnt = is_act and scrubber._tw_tab_count_bold or scrubber._tw_tab_count_normal
        tw_cnt.fgcolor = is_act and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        tw_cnt:setText("(" .. tostring(count) .. ")")
        local csz = tw_cnt:getSize()
        local w = isz_t.w + S(4) + csz.w + S(16)

        if is_act then
            paintRoundRect(bb, cur_tab_x, tab_draw_y, w, tab_h, r_tab, Blitbuffer.COLOR_BLACK)
        else
            paintRoundRect(bb, cur_tab_x, tab_draw_y, w, tab_h, r_tab, Blitbuffer.COLOR_BLACK)
            paintRoundRect(bb, cur_tab_x + S(1), tab_draw_y + S(1), w - S(2), tab_h - S(2), math.max(1, r_tab - S(1)), Blitbuffer.COLOR_WHITE)
        end

        local tix = cur_tab_x + S(6)
        local tiy = tab_draw_y + math.floor((tab_h - isz_t.h)/2)
        if icon then
            if is_act then
                bb:paintRect(tix, tiy, isz_t.w, isz_t.h, Blitbuffer.COLOR_WHITE)
                icon:paintTo(bb, tix, tiy)
                bb:invertRect(tix, tiy, isz_t.w, isz_t.h)
            else
                icon:paintTo(bb, tix, tiy)
            end
        end

        tw_cnt:paintTo(bb, tix + isz_t.w + S(4), tab_draw_y + math.floor((tab_h - csz.h)/2))
        local dim = Geom:new{ x = cur_tab_x, y = tab_draw_y, w = w, h = tab_h }
        cur_tab_x = cur_tab_x + w + S(6)
        return dim
    end

    scrubber._tab_bm_dimen = drawTab("bookmarks", scrubber.icon_tab_bm, #(scrubber:_getAllBookmarks() or {}))
    scrubber._tab_hl_dimen = drawTab("highlights", scrubber.icon_tab_hl, #(scrubber._cached_hl or {}))
    scrubber._tab_note_dimen = drawTab("notes", scrubber.icon_tab_note, #(scrubber._cached_notes or {}))

    -- =========================================================
    -- POLAROID IZQUIERDA (ESCALADO PROPORCIONAL UNIFORME)
    -- =========================================================
    scrubber._split_preview_dimen = Geom:new{ x = card_x, y = card_y, w = card_w, h = card_h }

    paintTopSquareBottomRounded(bb, card_x, card_y, card_w, card_h, box_radius, Blitbuffer.COLOR_BLACK)
    paintTopSquareBottomRounded(bb, card_x + b_thick, card_y + b_thick, card_w - b_thick*2, card_h - b_thick*2, math.max(1, box_radius - b_thick), Blitbuffer.COLOR_WHITE)

    local tile = scrubber._grid_tiles[2] or {}
    if tile.tile_bb then
        local tw, th = tile.tile_bb:getWidth(), tile.tile_bb:getHeight()
        local scale = math.min(max_pr_w / tw, max_pr_h / th)
        local draw_w = math.max(1, math.floor(tw * scale))
        local draw_h = math.max(1, math.floor(th * scale))

        local render_bb = tile.tile_bb
        local must_free = false
        if math.abs(tw - draw_w) > 4 or math.abs(th - draw_h) > 4 then
            local ok, sc = pcall(function() return tile.tile_bb:scale(draw_w, draw_h) end)
            if ok and sc then
                render_bb = sc
                must_free = true
            end
        end

        local ox = card_x + b_thick + math.floor((max_pr_w - draw_w) / 2)
        local oy = card_y + b_thick + math.floor((max_pr_h - draw_h) / 2)
        bb:blitFrom(render_bb, ox, oy, 0, 0, draw_w, draw_h)

        if must_free then
            pcall(function() render_bb:free() end)
        end
    elseif tile.loading then
        bb:paintRect(card_x + math.floor(card_w/2) - 1, card_y + math.floor(max_pr_h/2) - 1, 2, 2, Blitbuffer.COLOR_GRAY)
    end

    local is_cur_bmed = scrubber:_isCurrentPageBookmarked(scrubber._cur_page)
    if is_cur_bmed then
        local rw, rh = S(24), S(40)
        local rx = card_x + card_w - rw - S(12) - b_thick
        local ry = card_y + b_thick
        bb:paintRect(rx - S(2), ry, rw + S(4), S(20), Blitbuffer.COLOR_WHITE)
        drawBookmarkRibbon(bb, rx, ry, rw, rh, Blitbuffer.COLOR_BLACK)
    end

    -- Chin descriptivo inferior de la Polaroid
    local status_y = card_y + card_h - status_h - b_thick

    local active_pol_icon = nil
    local text_str = "—"
    local pd = scrubber._page_data[scrubber._cur_page]

    local function safe_string(str, max_len)
        if string.len(str) > max_len then return string.sub(str, 1, max_len - 3) .. "..." end
        return str
    end

    local function get_specific_style_icon(default_fallback)
        if scrubber._hl_filter ~= nil then
            return default_fallback
        end
        local it_type = scrubber._split_selected_item and scrubber._split_selected_item.type
        if it_type == "invert" then return scrubber.icon_picker_inv
        elseif it_type == "underline" then return scrubber.icon_picker_ul
        elseif it_type == "strikethrough" then return scrubber.icon_picker_st
        elseif it_type == "normal" then return scrubber.icon_picker_hl
        end
        return default_fallback
    end

    if scrubber._active_tab == "highlights" then
        active_pol_icon = get_specific_style_icon(scrubber.icon_pol_hl)
        if scrubber._split_selected_item and scrubber._split_selected_item.page == scrubber._cur_page and scrubber._split_selected_item.text ~= "" then
            text_str = "“" .. safe_string(scrubber._split_selected_item.text, 500) .. "”"
        elseif pd and pd.text then
            text_str = "“" .. safe_string(pd.text, 500) .. "”"
        end
    elseif scrubber._active_tab == "notes" then
        active_pol_icon = get_specific_style_icon(scrubber.icon_pol_note)
        if scrubber._split_selected_item and scrubber._split_selected_item.page == scrubber._cur_page and scrubber._split_selected_item.note ~= "" then
            text_str = safe_string(scrubber._split_selected_item.note, 500)
        elseif pd and pd.note then
            text_str = safe_string(pd.note, 500)
        end
    elseif scrubber._active_tab == "bookmarks" then
        active_pol_icon = scrubber.icon_pol_bm
        local is_bmed = false
        local raw_date = nil
        
        local function find_deep_date()
            local target_p = tonumber(scrubber._cur_page)
            local possible_sources = {
                scrubber.ui.annotation and scrubber.ui.annotation.annotations,
                scrubber.ui.doc_props and scrubber.ui.doc_props.bookmarks,
                scrubber.ui.bookmark and scrubber.ui.bookmark._bookmarks,
                scrubber.ui.bookmark and scrubber.ui.bookmark.bookmarks
            }
            for _, src in ipairs(possible_sources) do
                if type(src) == "table" then
                    for k, v in pairs(src) do
                        if type(v) == "table" then
                            local p = tonumber(v.pageno) or tonumber(v.page) or tonumber(v.pos0)
                            if not p and type(v.page) == "string" and scrubber.ui.document and scrubber.ui.document.getPageFromXPointer then
                                pcall(function() p = scrubber.ui.document:getPageFromXPointer(v.page) end)
                            end
                            if p == target_p then
                                local d = v.datetime or v.time or v.date or v.timestamp
                                if d then return d end
                            end
                        else
                            if tonumber(k) == target_p and (type(v) == "string" or type(v) == "number") then return v end
                        end
                    end
                end
            end
            return nil
        end
        
        raw_date = find_deep_date()
        if raw_date then is_bmed = true end
        if not is_bmed then
            for _, bmp in ipairs(scrubber:_getAllBookmarks()) do
                if tonumber(bmp) == tonumber(scrubber._cur_page) then is_bmed = true; break end
            end
        end
        
        if is_bmed then
            if raw_date then
                local y, m, d
                if type(raw_date) == "number" then
                    y = os.date("%Y", raw_date); m = os.date("%m", raw_date); d = os.date("%d", raw_date)
                else
                    local raw_s = tostring(raw_date)
                    y, m, d = raw_s:match("(%d%d%d%d)[%-%/%.%s_](%d%d)[%-%/%.%s_](%d%d)")
                    if not y then d, m, y = raw_s:match("(%d%d)[%-%/%.%s_](%d%d)[%-%/%.%s_](%d%d%d%d)") end
                end
                if y and m and d then
                    local months = { _("Jan"), _("Feb"), _("Mar"), _("Apr"), _("May"), _("Jun"), _("Jul"), _("Aug"), _("Sep"), _("Oct"), _("Nov"), _("Dec") }
                    text_str = _("Added on") .. " " .. (months[tonumber(m)] or m) .. " " .. tonumber(d) .. ", " .. y
                else
                    text_str = _("Added on") .. " " .. tostring(raw_date)
                end
            else
                text_str = _("Bookmarked")
            end
        end
    end

    local pad_x_chin = S(14)
    local isz_chin = active_pol_icon and active_pol_icon:getSize() or { w = S(20), h = S(20) }
    local cix = card_x + pad_x_chin
    local ciy = status_y + math.floor((status_h - isz_chin.h) / 2)
    if active_pol_icon then active_pol_icon:paintTo(bb, cix, ciy) end

    local ctx = cix + isz_chin.w + S(8)
    if not scrubber._tw_preview_text then
        scrubber._tw_preview_text = TextWidget:new{ text = "", face = Font:getFace("cfont", font_sz_chiquito), bold = true, fgcolor = Blitbuffer.COLOR_BLACK, truncate_with_ellipsis = true }
    end
    scrubber._tw_preview_text.max_width = card_w - (ctx - card_x) - S(14)
    scrubber._tw_preview_text.text = nil
    scrubber._tw_preview_text:setText(text_str:gsub("[\n\r]", " "))
    scrubber._tw_preview_text:paintTo(bb, ctx, status_y + math.floor((status_h - scrubber._tw_preview_text:getSize().h) / 2))

    -- =========================================================
    -- ACCIONES FLOTANTES (ANCLADAS ARRIBA SIN SALTAR)
    -- =========================================================
    scrubber._btn_delete_dimen = nil
    scrubber._btn_confirm_del_dimen = nil
    scrubber._btn_edit_dimen = nil
    scrubber._btn_type_dimen = nil
    scrubber._type_picker_dimens = nil

    local has_item_actions = (scrubber._active_tab ~= "bookmarks") and (scrubber._split_selected_item ~= nil)
    if has_item_actions and not scrubber._hide_action_buttons then
        local bw, bh = S(38), S(38)
        local btn_x = card_x + S(12)
        local btn_rad = S(10)
        local btn_thick = S(2)
        local confirm_h = S(46)

        local btn_top_y = card_y + b_thick + S(8)
        local tbtn_y = btn_top_y
        local ebtn_y = btn_top_y + bh + S(6)
        local btn_y  = ebtn_y + bh + S(6)

        -- 1. Botón Type
        local is_type_act = scrubber._show_type_picker or (scrubber._pressed_btn == "type")
        paintRoundRect(bb, btn_x, tbtn_y, bw, bh, btn_rad, Blitbuffer.COLOR_BLACK)
        if not is_type_act then
            paintRoundRect(bb, btn_x + btn_thick, tbtn_y + btn_thick, bw - btn_thick*2, bh - btn_thick*2, math.max(1, btn_rad - btn_thick), Blitbuffer.COLOR_WHITE)
        end
        if scrubber.icon_btn_type then
            local isz_t = scrubber.icon_btn_type:getSize()
            local tix = btn_x + math.floor((bw - isz_t.w)/2)
            local tiy = tbtn_y + math.floor((bh - isz_t.h)/2)
            if is_type_act then
                bb:paintRect(tix, tiy, isz_t.w, isz_t.h, Blitbuffer.COLOR_WHITE)
                scrubber.icon_btn_type:paintTo(bb, tix, tiy)
                bb:invertRect(tix, tiy, isz_t.w, isz_t.h)
            else
                scrubber.icon_btn_type:paintTo(bb, tix, tiy)
            end
        end
        scrubber._btn_type_dimen = Geom:new{ x = btn_x, y = tbtn_y, w = bw, h = bh }

        -- 2. Botón Edit
        local is_edit_act = (scrubber._pressed_btn == "edit")
        paintRoundRect(bb, btn_x, ebtn_y, bw, bh, btn_rad, Blitbuffer.COLOR_BLACK)
        if not is_edit_act then
            paintRoundRect(bb, btn_x + btn_thick, ebtn_y + btn_thick, bw - btn_thick*2, bh - btn_thick*2, math.max(1, btn_rad - btn_thick), Blitbuffer.COLOR_WHITE)
        end
        if scrubber.icon_btn_edit then
            local isz_e = scrubber.icon_btn_edit:getSize()
            local eix = btn_x + math.floor((bw - isz_e.w)/2)
            local eiy = ebtn_y + math.floor((bh - isz_e.h)/2)
            if is_edit_act then
                bb:paintRect(eix, eiy, isz_e.w, isz_e.h, Blitbuffer.COLOR_WHITE)
                scrubber.icon_btn_edit:paintTo(bb, eix, eiy)
                bb:invertRect(eix, eiy, isz_e.w, isz_e.h)
            else
                scrubber.icon_btn_edit:paintTo(bb, eix, eiy)
            end
        end
        scrubber._btn_edit_dimen = Geom:new{ x = btn_x, y = ebtn_y, w = bw, h = bh }

        -- 3. Botón Trash
        local is_trash_act = scrubber._show_delete_confirm or (scrubber._pressed_btn == "delete")
        paintRoundRect(bb, btn_x, btn_y, bw, bh, btn_rad, Blitbuffer.COLOR_BLACK)
        if not is_trash_act then
            paintRoundRect(bb, btn_x + btn_thick, btn_y + btn_thick, bw - btn_thick*2, bh - btn_thick*2, math.max(1, btn_rad - btn_thick), Blitbuffer.COLOR_WHITE)
        end
        if scrubber.icon_btn_trash then
            local isz_b = scrubber.icon_btn_trash:getSize()
            local bix = btn_x + math.floor((bw - isz_b.w)/2)
            local biy = btn_y + math.floor((bh - isz_b.h)/2)
            if is_trash_act then
                bb:paintRect(bix, biy, isz_b.w, isz_b.h, Blitbuffer.COLOR_WHITE)
                scrubber.icon_btn_trash:paintTo(bb, bix, biy)
                bb:invertRect(bix, biy, isz_b.w, isz_b.h)
            else
                scrubber.icon_btn_trash:paintTo(bb, bix, biy)
            end
        end
        scrubber._btn_delete_dimen = Geom:new{ x = btn_x, y = btn_y, w = bw, h = bh }

        -- Popups emergentes inferiores dentro de la Polaroid
        local popup_x = card_x + S(12)
        local popup_y = status_y - confirm_h - S(8)
        local popup_w = card_w - S(24)

        if scrubber._show_delete_confirm then
            local is_del_pressed = (scrubber._pressed_btn == "confirm_del")
            paintRoundRect(bb, popup_x, popup_y, popup_w, confirm_h, S(12), Blitbuffer.COLOR_BLACK)
            if is_del_pressed then
                paintRoundRect(bb, popup_x + S(3), popup_y + S(3), popup_w - S(6), confirm_h - S(6), S(9), Blitbuffer.COLOR_WHITE)
            end

            local fg_col = is_del_pressed and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
            local ctw = TextWidget:new{ text = _("Delete"), face = scrubber.font_ch, bold = true, fgcolor = fg_col }
            local ctsz = ctw:getSize()
            ctw:paintTo(bb, popup_x + math.floor((popup_w - ctsz.w)/2), popup_y + math.floor((confirm_h - ctsz.h)/2))
            ctw:free()

            scrubber._btn_confirm_del_dimen = Geom:new{ x = popup_x, y = popup_y, w = popup_w, h = confirm_h }
        end

        if scrubber._show_type_picker then
            local b_thick_c = S(3)
            paintRoundRect(bb, popup_x, popup_y, popup_w, confirm_h, S(12), Blitbuffer.COLOR_BLACK)
            paintRoundRect(bb, popup_x + b_thick_c, popup_y + b_thick_c, popup_w - b_thick_c*2, confirm_h - b_thick_c*2, math.max(1, S(12) - b_thick_c), Blitbuffer.COLOR_WHITE)

            local current_drawer = "lighten"
            if scrubber._split_selected_item and scrubber._split_selected_item.annotation then
                current_drawer = scrubber._split_selected_item.annotation.drawer or "lighten"
            else
                local pd_edit = scrubber._page_data[scrubber._cur_page]
                if scrubber._hl_filter then
                    if scrubber._hl_filter == "normal" then current_drawer = "lighten"
                    elseif scrubber._hl_filter == "invert" then current_drawer = "invert"
                    elseif scrubber._hl_filter == "underline" then current_drawer = "underscore"
                    elseif scrubber._hl_filter == "strikethrough" then current_drawer = "strikeout" end
                elseif pd_edit and pd_edit.hl_types then
                    if pd_edit.hl_types["normal"] then current_drawer = "lighten"
                    elseif pd_edit.hl_types["underline"] then current_drawer = "underscore"
                    elseif pd_edit.hl_types["invert"] then current_drawer = "invert"
                    elseif pd_edit.hl_types["strikethrough"] then current_drawer = "strikeout" end
                end
            end

            local type_defs = {
                { key = "lighten",    icon = scrubber.icon_picker_hl },
                { key = "underscore", icon = scrubber.icon_picker_ul },
                { key = "strikeout",  icon = scrubber.icon_picker_st },
                { key = "invert",     icon = scrubber.icon_picker_inv },
            }
            local slot_w = math.floor((popup_w - S(8)) / #type_defs)
            scrubber._type_picker_dimens = {}

            for idx, td in ipairs(type_defs) do
                local slot_x = popup_x + S(4) + (idx - 1) * slot_w
                local is_pressed = (scrubber._pressed_btn == "type_" .. td.key)
                local is_selected = (current_drawer == td.key)

                if td.icon then
                    local tisz = td.icon:getSize()
                    local circle_d = S(34)
                    local circle_x = slot_x + math.floor((slot_w - circle_d) / 2)
                    local circle_y = popup_y + math.floor((confirm_h - circle_d) / 2)

                    if is_pressed then
                        paintRoundRect(bb, circle_x, circle_y, circle_d, circle_d, math.floor(circle_d / 2), Blitbuffer.COLOR_DARK_GRAY)
                    elseif is_selected then
                        paintRoundRect(bb, circle_x, circle_y, circle_d, circle_d, math.floor(circle_d / 2), Blitbuffer.COLOR_LIGHT_GRAY)
                    end

                    local tix = slot_x + math.floor((slot_w - tisz.w) / 2)
                    local tiy = popup_y + math.floor((confirm_h - tisz.h) / 2)
                    td.icon:paintTo(bb, tix, tiy)
                end

                table.insert(scrubber._type_picker_dimens, {
                    key = td.key,
                    dimen = Geom:new{ x = slot_x, y = popup_y, w = slot_w, h = confirm_h }
                })
            end
        end
    end

    -- =========================================================
    -- MENÚ Y LISTA DERECHA (ALINEADA EXACTAMENTE EN ALTURA)
    -- =========================================================
    local list_card_y = tab_draw_y
    local total_side_h = tab_h + tab_sp_y + card_h
    local fx_h = S(46)
    local fx_gap = S(6)
    local list_card_h = total_side_h - fx_h - fx_gap
    local fx_y = list_card_y + list_card_h + fx_gap

    paintRoundRect(bb, menu_x, list_card_y, col_right_w, list_card_h, box_radius, Blitbuffer.COLOR_BLACK)
    paintRoundRect(bb, menu_x + S(2), list_card_y + S(2), col_right_w - S(4), list_card_h - S(4), math.max(1, box_radius - S(2)), Blitbuffer.COLOR_WHITE)

    local header_h = S(28)
    bb:paintRect(menu_x + S(2), list_card_y + header_h, col_right_w - S(4), 1, Blitbuffer.COLOR_BLACK)
    if not scrubber._tw_header_page then
        scrubber._tw_header_page = TextWidget:new{ text = _("Page"), face = Font:getFace("cfont", font_sz_chiquito), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
    end
    local hsz = scrubber._tw_header_page:getSize()
    local htx = menu_x + S(14)
    local hty = list_card_y + math.floor((header_h - hsz.h)/2)
    scrubber._tw_header_page:paintTo(bb, htx, hty)

    scrubber._hl_main_tab_dimen = Geom:new{ x = menu_x, y = list_card_y, w = htx + hsz.w + S(6) - menu_x, h = header_h }
    scrubber._hl_filter_dimens = {}

    -- Filtros de estilos en la cabecera
    local filter_defs = {
        { key = "normal",        icon_on = scrubber.icon_filter_hl_on,  icon_off = scrubber.icon_filter_hl_off },
        { key = "underline",     icon_on = scrubber.icon_filter_ul_on,  icon_off = scrubber.icon_filter_ul_off },
        { key = "invert",        icon_on = scrubber.icon_filter_inv_on, icon_off = scrubber.icon_filter_inv_off },
        { key = "strikethrough", icon_on = scrubber.icon_filter_st_on,  icon_off = scrubber.icon_filter_st_off },
    }
    local present_filters = {}
    local types_source = (scrubber._active_tab == "notes") and scrubber._note_types_present or scrubber._hl_types_present
    if scrubber._active_tab == "highlights" or scrubber._active_tab == "notes" then
        for _, fd in ipairs(filter_defs) do
            if types_source and types_source[fd.key] then table.insert(present_filters, fd) end
        end
    end

    if #present_filters >= 2 then
        local f_h = S(20)
        local f_w = S(18)
        local start_x = htx + hsz.w + S(10)
        local max_w_avail = (menu_x + col_right_w - S(4)) - start_x
        local num_f = #present_filters
        local f_gap = S(4)
        local total_needed = (num_f * f_w) + ((num_f - 1) * f_gap)

        if total_needed > max_w_avail and num_f > 1 then
            f_gap = math.floor((max_w_avail - (num_f * f_w)) / (num_f - 1))
        end

        local curr_f_x = start_x
        local curr_f_y = list_card_y + math.floor((header_h - f_h) / 2)

        for _, fd in ipairs(present_filters) do
            local is_active = (scrubber._hl_filter == fd.key)
            local touch_w = math.max(S(8), f_w + f_gap)
            local f_dimen = Geom:new{ x = curr_f_x, y = list_card_y, w = touch_w, h = header_h }
            table.insert(scrubber._hl_filter_dimens, { key = fd.key, dimen = f_dimen })

            local active_icon = is_active and fd.icon_on or fd.icon_off
            if is_active then
                bb:paintRect(curr_f_x + S(2), list_card_y + header_h - S(3), f_w - S(4), S(3), Blitbuffer.COLOR_BLACK)
            end

            if active_icon then
                local isz_f = active_icon:getSize()
                local ix = curr_f_x + math.floor((f_w - isz_f.w) / 2)
                local iy = curr_f_y + math.floor((f_h - isz_f.h) / 2)
                active_icon:paintTo(bb, ix, iy)
            end

            curr_f_x = curr_f_x + f_w + f_gap
        end
    end

    if not scrubber._tw_row_normal then
        local S_MEDIANO = scrubber.S_BOTTOM_GRAY or S(13)
        scrubber._tw_row_normal = TextWidget:new{ text = "", face = Font:getFace("cfont", S_MEDIANO), fgcolor = Blitbuffer.COLOR_BLACK }
        scrubber._tw_row_bold   = TextWidget:new{ text = "", face = Font:getFace("cfont", S_MEDIANO), bold = true, fgcolor = Blitbuffer.COLOR_WHITE }
        scrubber._tw_row_super_normal = TextWidget:new{ text = "", face = Font:getFace("cfont", font_sz_chiquito), fgcolor = Blitbuffer.COLOR_BLACK }
        scrubber._tw_row_super_bold   = TextWidget:new{ text = "", face = Font:getFace("cfont", font_sz_chiquito), bold = true, fgcolor = Blitbuffer.COLOR_WHITE }
    end

    local row_h = S(42)
    local num_rows = math.max(2, math.floor((list_card_h - header_h) / row_h))
    local needs_pag = #other_items > num_rows
    local items_per_p = needs_pag and (num_rows - 1) or num_rows
    local total_p = math.max(1, math.ceil(#other_items / math.max(1, items_per_p)))

    if scrubber._force_menu_sync then
        local target_idx = nil
        for i, it in ipairs(other_items) do
            if scrubber._active_tab == "bookmarks" then
                if tonumber(it) == tonumber(scrubber._cur_page) then target_idx = i; break end
            else
                if scrubber._split_selected_item and it == scrubber._split_selected_item then
                    target_idx = i; break
                elseif not scrubber._split_selected_item and it.page == scrubber._cur_page then
                    target_idx = i; break
                end
            end
        end
        if target_idx then
            scrubber._split_bm_page = math.ceil(target_idx / items_per_p)
        end
        scrubber._force_menu_sync = false
    end

    local cur_p = math.min(total_p, math.max(1, scrubber._split_bm_page or 1))
    scrubber._split_bm_page = cur_p

    local start_i = (cur_p - 1) * items_per_p + 1
    local end_i = math.min(cur_p * items_per_p, #other_items)

    scrubber._split_rows = {}
    scrubber._split_prev_dimen = nil
    scrubber._split_next_dimen = nil

    local r_y = list_card_y + header_h + 1
    if #other_items == 0 then
        if not scrubber._tw_empty_list then
            scrubber._tw_empty_list = TextWidget:new{ text = "—", face = Font:getFace("cfont", scrubber.S_BOTTOM_GRAY or S(13)), fgcolor = Blitbuffer.COLOR_DARK_GRAY }
        end
        local esz = scrubber._tw_empty_list:getSize()
        scrubber._tw_empty_list:paintTo(bb, menu_x + math.floor((col_right_w - esz.w)/2), list_card_y + header_h + math.floor((list_card_h - header_h - esz.h)/2))
    else
        for i = start_i, end_i do
            local it = other_items[i]
            local p = (type(it) == "table") and it.page or it
            local order = (type(it) == "table") and it.order or nil
            local total_on_page = (type(it) == "table") and it.total_on_page or 1
            local item_obj = (type(it) == "table") and it or nil

            local is_sel = false
            if scrubber._active_tab == "bookmarks" then
                is_sel = (scrubber._cur_page == p)
            else
                if scrubber._split_selected_item then
                    is_sel = (scrubber._split_selected_item == it)
                else
                    is_sel = (scrubber._cur_page == p)
                end
            end

            if is_sel then
                bb:paintRect(menu_x + S(2), r_y, col_right_w - S(4), row_h, Blitbuffer.COLOR_BLACK)
            elseif i < end_i then
                bb:paintRect(menu_x + S(2), r_y + row_h - 1, col_right_w - S(4), 1, Blitbuffer.COLOR_LIGHT_GRAY)
            end

            local tw_p = is_sel and scrubber._tw_row_bold or scrubber._tw_row_normal
            tw_p.fgcolor = is_sel and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
            tw_p:setText(tostring(scrubber:_getDisplayPageInfo(p)))
            local pg_x = menu_x + S(14)
            local pg_y = r_y + math.floor((row_h - tw_p:getSize().h)/2)
            tw_p:paintTo(bb, pg_x, pg_y)

            if total_on_page > 1 and order then
                local tw_sup = is_sel and scrubber._tw_row_super_bold or scrubber._tw_row_super_normal
                tw_sup.fgcolor = is_sel and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
                tw_sup:setText(tostring(order))
                tw_sup:paintTo(bb, pg_x + tw_p:getSize().w + S(2), pg_y - S(2))
            end

            local row_icon = (scrubber._active_tab == "bookmarks") and scrubber.icon_box_minus or scrubber.icon_box_arrow
            local risz = row_icon and row_icon:getSize() or { w = S(22), h = S(22) }
            local rix = menu_x + col_right_w - risz.w - S(14)
            local riy = r_y + math.floor((row_h - risz.h) / 2)

            if row_icon then
                local is_btn_pressed = scrubber._pressed_btn and scrubber._pressed_btn:find("^row_toggle_" .. tostring(p))
                if is_btn_pressed then
                    local pad_btn = S(4)
                    paintRoundRect(bb, rix - pad_btn, riy - pad_btn, risz.w + pad_btn*2, risz.h + pad_btn*2, S(6), is_sel and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK)
                    if not is_sel then
                        bb:paintRect(rix, riy, risz.w, risz.h, Blitbuffer.COLOR_WHITE)
                        row_icon:paintTo(bb, rix, riy)
                        bb:invertRect(rix, riy, risz.w, risz.h)
                    else
                        row_icon:paintTo(bb, rix, riy)
                    end
                elseif is_sel then
                    bb:paintRect(rix, riy, risz.w, risz.h, Blitbuffer.COLOR_WHITE)
                    row_icon:paintTo(bb, rix, riy)
                    bb:invertRect(rix, riy, risz.w, risz.h)
                else
                    row_icon:paintTo(bb, rix, riy)
                end
            end

            local t_dim = Geom:new{ x = rix - S(10), y = r_y, w = risz.w + S(20), h = row_h }
            local r_dim = Geom:new{ x = menu_x, y = r_y, w = (rix - S(10)) - menu_x, h = row_h }
            table.insert(scrubber._split_rows, { dimen = r_dim, toggle_dimen = t_dim, page = p, item = item_obj })

            r_y = r_y + row_h
        end
    end

    if needs_pag then
        local pag_y = list_card_y + list_card_h - row_h
        bb:paintRect(menu_x + S(2), pag_y, col_right_w - S(4), 1, Blitbuffer.COLOR_BLACK)
        if not scrubber._tw_pagination then
            scrubber._tw_pagination = TextWidget:new{ text = "", face = Font:getFace("cfont", font_sz_chiquito), bold = true, fgcolor = Blitbuffer.COLOR_BLACK }
        end
        scrubber._tw_pagination:setText(cur_p .. " / " .. total_p)
        scrubber._tw_pagination:paintTo(bb, menu_x + math.floor((col_right_w - scrubber._tw_pagination:getSize().w)/2), pag_y + math.floor((row_h - scrubber._tw_pagination:getSize().h)/2))

        if cur_p > 1 then
            scrubber._split_prev_dimen = Geom:new{ x = menu_x, y = pag_y, w = S(44), h = row_h }
            if scrubber.icon_chevron_left then
                scrubber.icon_chevron_left:paintTo(bb, menu_x + S(12), pag_y + math.floor((row_h - scrubber.icon_chevron_left:getSize().h)/2))
            end
        end
        if cur_p < total_p then
            scrubber._split_next_dimen = Geom:new{ x = menu_x + col_right_w - S(44), y = pag_y, w = S(44), h = row_h }
            if scrubber.icon_chevron_right then
                scrubber.icon_chevron_right:paintTo(bb, menu_x + col_right_w - S(32), pag_y + math.floor((row_h - scrubber.icon_chevron_right:getSize().h)/2))
            end
        end
    end

    -- Fila fija inferior (Página origen)
    local fixed_p = scrubber._split_fixed_page or scrubber._origin_page
    local is_f_sel = (scrubber._cur_page == fixed_p)
    paintRoundRect(bb, menu_x, fx_y, col_right_w, fx_h, box_radius, Blitbuffer.COLOR_BLACK)
    if not is_f_sel then
        paintRoundRect(bb, menu_x + S(2), fx_y + S(2), col_right_w - S(4), fx_h - S(4), math.max(1, box_radius - S(2)), Blitbuffer.COLOR_WHITE)
    end
    local tw_f = is_f_sel and scrubber._tw_row_bold or scrubber._tw_row_normal
    tw_f.fgcolor = is_f_sel and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    tw_f:setText(tostring(scrubber:_getDisplayPageInfo(fixed_p)))
    tw_f:paintTo(bb, menu_x + S(14), fx_y + math.floor((fx_h - tw_f:getSize().h)/2))

    local is_f_bmed = scrubber:_isCurrentPageBookmarked(fixed_p)
    local fx_icon = is_f_bmed and scrubber.icon_box_minus_fill or scrubber.icon_box_plus
    local fisz = fx_icon and fx_icon:getSize() or { w = S(22), h = S(22) }
    local fix = menu_x + col_right_w - fisz.w - S(14)
    local fiy = fx_y + math.floor((fx_h - fisz.h) / 2)

    if fx_icon then
        if is_f_sel then
            bb:paintRect(fix, fiy, fisz.w, fisz.h, Blitbuffer.COLOR_WHITE)
            fx_icon:paintTo(bb, fix, fiy)
            bb:invertRect(fix, fiy, fisz.w, fisz.h)
        else
            fx_icon:paintTo(bb, fix, fiy)
        end
    end

    scrubber._split_fixed_row_dimen = Geom:new{ x = menu_x, y = fx_y, w = (fix - S(10)) - menu_x, h = fx_h }
    scrubber._split_fixed_toggle_dimen = Geom:new{ x = fix - S(10), y = fx_y, w = col_right_w - (fix - S(10) - menu_x), h = fx_h }

    -- =========================================================
    -- BARRA INFERIOR (2 LÍNEAS): BROWSER Y RETORNO DINÁMICO
    -- =========================================================
    local l1_y = bar_y + bar_pad_y
    local ch_btn_sz = S(34)
    scrubber._prev_ch_dimen = Geom:new{ x = pad_x, y = l1_y + math.floor((l1_h - ch_btn_sz)/2), w = ch_btn_sz, h = ch_btn_sz }
    scrubber._next_ch_dimen = Geom:new{ x = sw - pad_x - ch_btn_sz, y = l1_y + math.floor((l1_h - ch_btn_sz)/2), w = ch_btn_sz, h = ch_btn_sz }

    local function drawBtnWithPress(btn_id, dim, widget, y_off, is_disabled)
        if not dim or not widget then return end
        local is_p = (scrubber._pressed_btn == btn_id and not is_disabled and btn_id ~= "ctrl_mark")
        local wsz = widget:getSize()
        local wx = dim.x + math.floor((dim.w - wsz.w)/2)
        local wy = dim.y + math.floor((dim.h - wsz.h)/2) + (y_off or 0)

        if is_disabled then
            widget.fgcolor = Blitbuffer.COLOR_LIGHT_GRAY
            widget:paintTo(bb, wx, wy)
        elseif is_p then
            local is_bm_ctrl = (btn_id == "ctrl_prev" or btn_id == "ctrl_next")
            local btn_rad = is_bm_ctrl and math.floor(math.min(dim.w, dim.h) / 2) or S(8)
            local bg_y = is_bm_ctrl and (dim.y + (y_off or 0) - S(2)) or dim.y
            paintRoundRect(bb, dim.x, bg_y, dim.w, dim.h, btn_rad, Blitbuffer.COLOR_BLACK)
            if widget.text then
                widget.fgcolor = Blitbuffer.COLOR_WHITE
                widget:paintTo(bb, wx, wy)
                widget.fgcolor = Blitbuffer.COLOR_BLACK
            else
                bb:paintRect(wx, wy, wsz.w, wsz.h, Blitbuffer.COLOR_WHITE)
                widget.fgcolor = Blitbuffer.COLOR_BLACK
                widget:paintTo(bb, wx, wy)
                bb:invertRect(wx, wy, wsz.w, wsz.h)
            end
        else
            widget.fgcolor = Blitbuffer.COLOR_BLACK
            widget:paintTo(bb, wx, wy)
        end
    end

    drawBtnWithPress("ch_l", scrubber._prev_ch_dimen, scrubber.tw_ch_l, -S(1))
    drawBtnWithPress("ch_r", scrubber._next_ch_dimen, scrubber.tw_ch_r, -S(1))

    local slider_x = scrubber._prev_ch_dimen.x + ch_btn_sz + S(12)
    local slider_w = scrubber._next_ch_dimen.x - S(12) - slider_x
    scrubber._slider.width = slider_w
    scrubber._slider.value = scrubber._cur_page
    scrubber._slider:paintTo(bb, slider_x, l1_y + math.floor((l1_h - scrubber._slider:getSize().h)/2))

    -- Línea 2: Controles táctiles del Bookmark Browser
    local l2_y = l1_y + l1_h + bar_gap
    scrubber.ctrl_y_pos = l2_y
    local mark_sz = S(36)
    local side_sz = S(30)
    local ctrl_sp = S(12)
    local total_ctrl_w = side_sz * 2 + mark_sz + ctrl_sp * 2
    local ctrl_x = math.floor((sw - total_ctrl_w) / 2)
    scrubber._ctrl_row_x0 = ctrl_x
    scrubber._ctrl_row_x1 = ctrl_x + total_ctrl_w
    scrubber._ctrl_row_h = mark_sz

    scrubber._ctrl_prev_dimen = Geom:new{ x = ctrl_x, y = l2_y + math.floor((mark_sz - side_sz)/2), w = side_sz, h = side_sz }
    scrubber._ctrl_mark_dimen = Geom:new{ x = ctrl_x + side_sz + ctrl_sp, y = l2_y, w = mark_sz, h = mark_sz }
    scrubber._ctrl_next_dimen = Geom:new{ x = ctrl_x + side_sz + mark_sz + ctrl_sp * 2, y = l2_y + math.floor((mark_sz - side_sz)/2), w = side_sz, h = side_sz }

    local has_prev_bm = scrubber:_findPrevBookmark() ~= nil
    drawBtnWithPress("ctrl_prev", scrubber._ctrl_prev_dimen, scrubber.tw_ctrl_prev, -S(2), not has_prev_bm)

    local is_bmed_page = scrubber:_isCurrentPageBookmarked(scrubber._cur_page)
    scrubber.tw_ctrl_mark = is_bmed_page and scrubber.icon_mark_filled or scrubber.icon_mark_empty
    drawBtnWithPress("ctrl_mark", scrubber._ctrl_mark_dimen, scrubber.tw_ctrl_mark, -S(1), false)

    local has_next_bm = scrubber:_findNextBookmark() ~= nil
    drawBtnWithPress("ctrl_next", scrubber._ctrl_next_dimen, scrubber.tw_ctrl_next, -S(2), not has_next_bm)

    -- Botón volver anclado siempre a la derecha con flecha direccional
    local has_back = math.abs(scrubber._cur_page - scrubber._origin_page) >= 10
    scrubber._grid_back_dimen = nil

    local origin_on_left = scrubber.is_rtl and (scrubber._cur_page < scrubber._origin_page) or (scrubber._cur_page > scrubber._origin_page)
    local isz_info = scrubber.tw_info and scrubber.tw_info:getSize() or { w = 0, h = 0 }
    local info_x = sw - pad_x - isz_info.w

    if has_back then
        local disp_orig = scrubber:_getDisplayPageInfo(scrubber._origin_page)
        local arrow_char = origin_on_left and "‹ " or " ›"
        local back_str = origin_on_left and (arrow_char .. _("Page") .. " " .. tostring(disp_orig))
                                         or (_("Page") .. " " .. tostring(disp_orig) .. arrow_char)

        if not scrubber._tw_lnd_back then
            scrubber._tw_lnd_back = TextWidget:new{ text = back_str, face = Font:getFace("cfont", scrubber.S_BOTTOM_GRAY or S(13)), bold = true, fgcolor = Blitbuffer.COLOR_DARK_GRAY }
        else
            scrubber._tw_lnd_back:setText(back_str)
        end
        local bsz = scrubber._tw_lnd_back:getSize()
        local bw = bsz.w + S(14)
        local is_back_p = (scrubber._pressed_btn == "grid_back")

        local bx = scrubber._ctrl_row_x1 + S(10)
        scrubber._grid_back_dimen = Geom:new{ x = bx, y = l2_y, w = bw, h = mark_sz }

        if is_back_p then
            paintRoundRect(bb, bx, l2_y, bw, mark_sz, S(6), Blitbuffer.COLOR_BLACK)
            scrubber._tw_lnd_back.fgcolor = Blitbuffer.COLOR_WHITE
            scrubber._tw_lnd_back:paintTo(bb, bx + S(7), l2_y + math.floor((mark_sz - bsz.h)/2))
        else
            scrubber._tw_lnd_back.fgcolor = Blitbuffer.COLOR_DARK_GRAY
            paintTripleText(scrubber._tw_lnd_back, bb, bx + S(7), l2_y + math.floor((mark_sz - bsz.h)/2))
        end
    end

    if scrubber.tw_chapter then
        scrubber.tw_chapter.max_width = ctrl_x - pad_x - S(12)
        scrubber.tw_chapter:paintTo(bb, pad_x, l2_y + math.floor((mark_sz - scrubber.tw_chapter:getSize().h)/2))
    end
    if scrubber.tw_info then
        paintTripleText(scrubber.tw_info, bb, info_x, l2_y + math.floor((mark_sz - isz_info.h)/2))
    end
end

return SplitLandscapeView

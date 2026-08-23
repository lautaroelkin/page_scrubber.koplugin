--[[
    page_scrubber.koplugin/menu_view.lua
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")

local MenuView = {}

function MenuView.paint(scrubber, bb, title_strip_y, title_strip_h)
    local gd = scrubber._grid_dimen
    local sw, sh = scrubber._sw, scrubber._sh
    local S = scrubber.S
    
    bb:paintRect(gd.x, gd.y, gd.w, gd.h, Blitbuffer.COLOR_WHITE)
    
    local shadow_offset = S(4)
    local box_radius = S(12)
    local font_sz_chiquito = S(12)
    local S_MEDIANO = S(13)
    local S_CHIQUITO = S(12)
    
    local available_h = gd.h
    local status_h = S(32) 
    local fx_h = S(56)
    local gap_x = S(28)
    local target_gap = S(12)
    
    local max_pr_w_allowed = math.floor((sw - S(40) - gap_x) * 0.65)
    local target_pr_w = max_pr_w_allowed
    local target_pr_h = math.floor(target_pr_w * (sh / sw))
    local max_left_h_allowed = available_h - S(10)
    
    if target_pr_h + status_h > max_left_h_allowed then
        target_pr_h = max_left_h_allowed - status_h
        target_pr_w = math.floor(target_pr_h * (sw / sh))
    end
    
    local pr_w = target_pr_w
    local pr_h = target_pr_h
    local lm_w = math.floor(pr_w * (35 / 65))
    
    scrubber._thumb_req_split_w = pr_w
    scrubber._thumb_req_split_h = pr_h
    
    local left_total_h = pr_h + status_h
    local available_menu_h = left_total_h - target_gap - fx_h
    
    if available_menu_h < S(100) then
        available_menu_h = S(100)
        left_total_h = available_menu_h + target_gap + fx_h
        pr_h = left_total_h - status_h
        pr_w = math.floor(pr_h * (sw / sh))
        lm_w = math.floor(pr_w * (35 / 65))
    end
    
    local header_h = S(30)
    local black_line_thickness = S(0)
    local available_list_h = available_menu_h - header_h - black_line_thickness
    if available_list_h < S(70) then available_list_h = S(70) end
    
    local target_row_h = S(50)
    local num_rows = math.max(2, math.floor(available_list_h / target_row_h + 0.5))
    local row_h = math.floor(available_list_h / num_rows)
    local exact_menu_h = header_h + black_line_thickness + num_rows * row_h
    
    local gap_y = left_total_h - exact_menu_h - fx_h
    local block_total_w = pr_w + gap_x + lm_w
    local pr_x = math.floor((sw - block_total_w) / 2)
    if pr_x < S(12) then pr_x = S(12) end
    
    local lm_x = pr_x + pr_w + gap_x
    scrubber._split_divider_x = lm_x - math.floor(gap_x / 2)

    local total_content_h = exact_menu_h + gap_y + fx_h
    local top_box_y = gd.y + math.floor((available_h - total_content_h) / 2)
    
    local pr_y = top_box_y
    local menu_y = top_box_y
    local fx_y = menu_y + exact_menu_h + gap_y
    
    scrubber._split_preview_dimen = Geom:new{ x = pr_x, y = pr_y, w = pr_w, h = pr_h }

    local bm_count = #(scrubber:_getAllBookmarks() or {})
    local hl_count = #(scrubber._cached_hl or {})
    local note_count = #(scrubber._cached_notes or {})

    local tab_sp = S(6)
    local tab_h = S(32)
    local actual_top_space = top_box_y - title_strip_y
    local ratio = (actual_top_space > tab_h * 1.5) and 0.8 or 0.5
    local tab_draw_y = title_strip_y + math.floor((actual_top_space - tab_h) * ratio)
    
    local current_tab_x = pr_x
    local r = math.floor(tab_h / 2)

    local sort_icon = (scrubber._sort_order == "asc") and "\u{EBBB}" or "\u{EBBC}"
    scrubber._tw_tab_sort:setText(sort_icon)
    local sort_tsz = scrubber._tw_tab_sort:getSize()
    local sort_tab_w = sort_tsz.w + S(16)

    scrubber.paintRoundRect(bb, current_tab_x, tab_draw_y, sort_tab_w, tab_h, r, Blitbuffer.COLOR_BLACK)
    scrubber.paintRoundRect(bb, current_tab_x + S(2), tab_draw_y + S(2), sort_tab_w - S(4), tab_h - S(4), math.max(1, r - S(2)), Blitbuffer.COLOR_WHITE)

    scrubber._tw_tab_sort.fgcolor = Blitbuffer.COLOR_BLACK
    local stx = current_tab_x + math.floor((sort_tab_w - sort_tsz.w) / 2)
    local sty = tab_draw_y + math.floor((tab_h - sort_tsz.h) / 2)

    scrubber._tw_tab_sort:paintTo(bb, stx, sty)
    scrubber._tw_tab_sort:paintTo(bb, stx + 1, sty)
    scrubber._tw_tab_sort:paintTo(bb, stx, sty + 1)
    scrubber._tw_tab_sort:paintTo(bb, stx + 1, sty + 1)

    scrubber._tab_sort_dimen = Geom:new{ x = current_tab_x, y = tab_draw_y, w = sort_tab_w, h = tab_h }
    current_tab_x = current_tab_x + sort_tab_w + tab_sp

    local function drawTabWithShift(id, icon_char, count_num)
        local is_active = (scrubber._active_tab == id)
        local bg = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
        local fg = is_active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK

        local tw_ic = TextWidget:new{ text = icon_char, face = Font:getFace("cfont", S_CHIQUITO), fgcolor = fg }
        local tw_cnt = TextWidget:new{ text = "(" .. tostring(count_num) .. ")", face = Font:getFace("cfont", S_CHIQUITO), fgcolor = fg }
        local isz = tw_ic:getSize()
        local csz = tw_cnt:getSize()
        local gap = S(4)
        local content_w = isz.w + gap + csz.w
        local tab_w = content_w + S(18)

        scrubber.paintRoundRect(bb, current_tab_x, tab_draw_y, tab_w, tab_h, r, Blitbuffer.COLOR_BLACK)
        if not is_active then
            scrubber.paintRoundRect(bb, current_tab_x + S(2), tab_draw_y + S(2), tab_w - S(4), tab_h - S(4), math.max(1, r - S(2)), Blitbuffer.COLOR_WHITE)
        end

        local ix = current_tab_x + math.floor((tab_w - content_w) / 2)
        local cx = ix + isz.w + gap
        local iy = tab_draw_y + math.floor((tab_h - isz.h) / 2)
        local cy = tab_draw_y + math.floor((tab_h - csz.h) / 2) - S(1)

        tw_ic:paintTo(bb, ix, iy)
        tw_ic:paintTo(bb, ix + 1, iy)
        tw_ic:paintTo(bb, ix, iy + 1)
        tw_ic:paintTo(bb, ix + 1, iy + 1)
        tw_ic:free()

        tw_cnt:paintTo(bb, cx, cy)
        tw_cnt:paintTo(bb, cx + 1, cy)
        tw_cnt:paintTo(bb, cx, cy + 1)
        tw_cnt:paintTo(bb, cx + 1, cy + 1)
        tw_cnt:free()

        local dimen = Geom:new{ x = current_tab_x, y = tab_draw_y, w = tab_w, h = tab_h }
        current_tab_x = current_tab_x + tab_w + tab_sp 
        return dimen
    end
    
    scrubber._tab_bm_dimen   = drawTabWithShift("bookmarks", "\u{E7B9}", bm_count)
    scrubber._tab_hl_dimen   = drawTabWithShift("highlights", "\u{E931}", hl_count)
    scrubber._tab_note_dimen = drawTabWithShift("notes", "\u{F075}", note_count)

    local card_x = pr_x
    local card_y = pr_y
    local card_w = pr_w
    local card_h = pr_h + status_h
    
    scrubber.paintTopSquareBottomRounded(bb, card_x + shadow_offset, card_y, card_w, card_h, box_radius, Blitbuffer.COLOR_DARK_GRAY)
    scrubber.paintTopSquareBottomRounded(bb, card_x, card_y, card_w, card_h, box_radius, Blitbuffer.COLOR_BLACK)
    local b_thick = S(2)
    scrubber.paintTopSquareBottomRounded(bb, card_x + b_thick, card_y + b_thick, card_w - b_thick*2, card_h - b_thick*2, math.max(1, box_radius - b_thick), Blitbuffer.COLOR_WHITE)

    local tile = scrubber._grid_tiles[2] or {}
    if tile.tile_bb then
        local target_w = pr_w - b_thick*2
        local target_h = pr_h - b_thick
        local tw, th = tile.tile_bb:getWidth(), tile.tile_bb:getHeight()

        local render_bb = tile.tile_bb
        local must_free_render_bb = false
        if math.abs(tw - target_w) > 6 or math.abs(th - target_h) > 6 then
            local ok, sc = pcall(function() return tile.tile_bb:scale(target_w, target_h) end)
            if ok and sc then
                render_bb = sc
                must_free_render_bb = true
                tw, th = render_bb:getWidth(), render_bb:getHeight()
            end
        end

        local src_x, src_y = 0, 0
        local blit_w, blit_h = tw, th
        
        if blit_w > target_w then
            src_x = math.floor((blit_w - target_w) / 2)
            blit_w = target_w
        end
        if blit_h > target_h then
            src_y = math.floor((blit_h - target_h) / 2)
            blit_h = target_h
        end

        local ox = card_x + b_thick + math.floor((target_w - blit_w) / 2)
        local oy = card_y + b_thick + math.floor((target_h - blit_h) / 2)
        
        if ox < 0 then src_x = src_x - ox; blit_w = blit_w + ox; ox = 0 end
        if oy < 0 then src_y = src_y - oy; blit_h = blit_h + oy; oy = 0 end
        if ox + blit_w > sw then blit_w = sw - ox end
        if oy + blit_h > sh then blit_h = sh - oy end
        
        if blit_w > 0 and blit_h > 0 then
            bb:blitFrom(render_bb, ox, oy, src_x, src_y, blit_w, blit_h)
        end

        if must_free_render_bb then
            pcall(function() render_bb:free() end)
        end
    elseif tile.error then
        local err_tw = TextWidget:new{ text = "!", face = Font:getFace("cfont", S(32)), fgcolor = Blitbuffer.COLOR_BLACK }
        local etsz = err_tw:getSize()
        err_tw:paintTo(bb, card_x + math.floor((card_w - etsz.w) / 2), card_y + math.floor((pr_h - etsz.h) / 2))
        err_tw:free()
    elseif tile.loading then
        bb:paintRect(card_x + math.floor(card_w / 2) - 1, card_y + math.floor(pr_h / 2) - 1, 2, 2, Blitbuffer.COLOR_GRAY)
    end
    
    local icon_char = "\u{F02E}"
    local text_str = "—"
    local pd = scrubber._page_data[scrubber._cur_page]
    
    local function safe_string(str, max_len)
        if string.len(str) > max_len then return string.sub(str, 1, max_len - 3) .. "..." end
        return str
    end

    if scrubber._active_tab == "highlights" then
        icon_char = "\u{ED51}"
        if pd and pd.text then text_str = '“' .. safe_string(pd.text, 500) .. '”' end
    elseif scrubber._active_tab == "notes" then
        icon_char = "\u{F448}"
        if pd and pd.note then text_str = safe_string(pd.note, 500) end
    elseif scrubber._active_tab == "bookmarks" then
        icon_char = "\u{F02E}"
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
                            if tonumber(k) == target_p and (type(v) == "string" or type(v) == "number") then
                                return v
                            end
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
                    local months = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
                    text_str = "Added on " .. (months[tonumber(m)] or m) .. " " .. tonumber(d) .. ", " .. y
                else
                    text_str = "Added on " .. tostring(raw_date)
                end
            else
                text_str = "Bookmarked"
            end
        end
    end

    local icon_sz = S(12)
    local pad_x = S(14)
    local gap = S(8)
    
    local icon_tw = TextWidget:new{ text = icon_char, face = Font:getFace("cfont", icon_sz), fgcolor = Blitbuffer.COLOR_BLACK }
    local isz = icon_tw:getSize()
    
    local text_max_w = card_w - (pad_x * 2) - isz.w - gap
    local clean_str = text_str:gsub("\n", " "):gsub("\r", "")
    
    local measure_tw = TextWidget:new{ text = clean_str, face = Font:getFace("cfont", font_sz_chiquito) }
    local raw_text_w = measure_tw:getSize().w
    measure_tw:free()
    
    local function utf8_sub(s, len)
        local count = 0
        local res = ""
        for uchar in string.gmatch(s, "[%z\1-\127\194-\244][\128-\191]*") do
            res = res .. uchar
            count = count + 1
            if count >= len then break end
        end
        return res
    end
    
    local print_str = clean_str
    if raw_text_w > text_max_w then
        local total_chars = 0
        for _ in string.gmatch(clean_str, "[%z\1-\127\194-\244][\128-\191]*") do total_chars = total_chars + 1 end
        
        local trunc_len = total_chars - 3
        while trunc_len > 0 do
            local test_str = utf8_sub(clean_str, trunc_len) .. "..."
            local temp_tw = TextWidget:new{ text = test_str, face = Font:getFace("cfont", font_sz_chiquito) }
            local test_w = temp_tw:getSize().w
            temp_tw:free()
            if test_w <= text_max_w then
                print_str = test_str
                break
            end
            trunc_len = trunc_len - 2
        end
    end
    
    local ix = card_x + pad_x
    local iy = card_y + pr_h + math.floor((status_h - isz.h) / 2)
    icon_tw:paintTo(bb, ix, iy)
    icon_tw:free()
    
    local tx = ix + isz.w + gap
    local tw_st = TextWidget:new{ text = print_str, face = Font:getFace("cfont", font_sz_chiquito), fgcolor = Blitbuffer.COLOR_BLACK, max_width = text_max_w }
    local tsz = tw_st:getSize()
    local ty = card_y + pr_h + math.floor((status_h - tsz.h) / 2) - S(1)
    
    tw_st:paintTo(bb, tx, ty)
    tw_st:paintTo(bb, tx + 1, ty)
    tw_st:paintTo(bb, tx, ty + 1)
    tw_st:paintTo(bb, tx + 1, ty + 1)
    tw_st:free()

    local fixed_page = scrubber._split_fixed_page or scrubber._origin_page
    local fx_w = lm_w
    local is_f_sel = (scrubber._cur_page == fixed_page)
    local fg_f = is_f_sel and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK

    local is_page_bmed = false
    for _, b in ipairs(scrubber:_getAllBookmarks()) do
        if tonumber(b) == tonumber(fixed_page) then is_page_bmed = true end
    end

    scrubber.paintRoundRect(bb, lm_x + shadow_offset, fx_y, lm_w, fx_h, box_radius, Blitbuffer.COLOR_DARK_GRAY)
    scrubber.paintRoundRect(bb, lm_x, fx_y, lm_w, fx_h, box_radius, Blitbuffer.COLOR_BLACK)
    scrubber.paintRoundRect(bb, lm_x + S(2), fx_y + S(2), lm_w - S(4), fx_h - S(4), math.max(1, box_radius - S(2)), Blitbuffer.COLOR_WHITE)

    if is_f_sel then
        scrubber.paintRoundRect(bb, lm_x + S(4), fx_y + S(4), lm_w - S(8), fx_h - S(8), S(8), Blitbuffer.COLOR_BLACK)
    end
    
    local tw_pg_f = TextWidget:new{ text = tostring(fixed_page), face = Font:getFace("cfont", S_MEDIANO), fgcolor = fg_f }
    local pt_sz = tw_pg_f:getSize()
    local ptx = lm_x + S(15)
    local pty = fx_y + math.floor((fx_h - pt_sz.h) / 2) + S(2)
    
    tw_pg_f:paintTo(bb, ptx, pty)
    if is_f_sel then
        tw_pg_f:paintTo(bb, ptx + 1, pty)
        tw_pg_f:paintTo(bb, ptx, pty + 1)
        tw_pg_f:paintTo(bb, ptx + 1, pty + 1)
    end
    tw_pg_f:free()

    local btn_icon = is_page_bmed and "\u{F146}" or "\u{F196}"
    local tw_btn_f = TextWidget:new{ text = btn_icon, face = Font:getFace("cfont", S(26)), fgcolor = fg_f }
    local bsz_f = tw_btn_f:getSize()
    local btn_xf = lm_x + lm_w - bsz_f.w - S(15)
    tw_btn_f:paintTo(bb, btn_xf, fx_y + math.floor((fx_h - bsz_f.h)/2) + S(1))
    tw_btn_f:free()

    local row_clickable_w = (btn_xf - S(10)) - lm_x
    scrubber._split_fixed_row_dimen = Geom:new{ x = lm_x, y = fx_y, w = row_clickable_w, h = fx_h }
    scrubber._split_fixed_toggle_dimen = Geom:new{ x = btn_xf - S(10), y = fx_y, w = bsz_f.w + S(20), h = fx_h }

    local filter_defs = {
        { key = "normal",    icon = "\u{E932}" },
        { key = "underline", icon = nil }, 
        { key = "invert",    icon = "\u{F043}" },
    }
    local present_filters = {}
    if scrubber._active_tab == "highlights" then
        for _, fd in ipairs(filter_defs) do
            if scrubber._hl_types_present[fd.key] then
                table.insert(present_filters, fd)
            end
        end
    end

    local other_items = scrubber:_getFilteredActiveList()
    local ITEMS_PER_PAGE
    local needs_pagination = false
    
    if #other_items <= num_rows then
        ITEMS_PER_PAGE = num_rows
        needs_pagination = false
    else
        ITEMS_PER_PAGE = num_rows - 1
        needs_pagination = true
    end

    if ITEMS_PER_PAGE < 1 then ITEMS_PER_PAGE = 1 end

    if scrubber._force_menu_sync then
        local target_idx = nil
        for i, p in ipairs(other_items) do
            if tonumber(p) == tonumber(scrubber._cur_page) then
                target_idx = i
                break
            end
        end
        if target_idx then
            local required_page = math.ceil(target_idx / ITEMS_PER_PAGE)
            scrubber._split_bm_page = required_page
        end
        scrubber._force_menu_sync = false
    end
    
    local total_pages = math.max(1, math.ceil(#other_items / ITEMS_PER_PAGE))
    local cur_page = scrubber._split_bm_page or 1
    if cur_page > total_pages then cur_page = total_pages end
    if cur_page < 1 then cur_page = 1 end
    scrubber._split_bm_page = cur_page
    
    local start_idx, end_idx = 1, 0
    if #other_items > 0 then
        start_idx = (cur_page - 1) * ITEMS_PER_PAGE + 1
        end_idx = math.min(cur_page * ITEMS_PER_PAGE, #other_items)
    end

    scrubber._split_rows = {}

    local is_multi_hl = (scrubber._active_tab == "highlights" and #present_filters >= 2)
    local main_label_str = is_multi_hl and "P" or "Pag"

    local tw_hdr = TextWidget:new{ text = main_label_str, face = Font:getFace("cfont", font_sz_chiquito), fgcolor = Blitbuffer.COLOR_BLACK }
    local hsz = tw_hdr:getSize()
    local has_active_filter = (scrubber._active_tab == "highlights" and scrubber._hl_filter ~= nil)

    local hdr_left_pad = is_multi_hl and S(11) or S(10)
    local hdr_right_pad = is_multi_hl and (has_active_filter and S(8) or S(11)) or S(8)

    local active_icon_w = 0
    local active_fd = nil
    if has_active_filter then
        for _, fd in ipairs(filter_defs) do
            if fd.key == scrubber._hl_filter then active_fd = fd; break end
        end
        if active_fd then
            active_icon_w = S(13) + S(4)
        end
    end

    local pag_tab_w = hdr_left_pad + hsz.w + active_icon_w + hdr_right_pad
    local body_y = menu_y + header_h
    local body_h = exact_menu_h - header_h

    bb:paintRect(lm_x, menu_y, pag_tab_w, header_h, Blitbuffer.COLOR_BLACK)

    local inner_r = math.max(1, box_radius - S(2))
    scrubber.paintCornerRect(bb, lm_x + shadow_offset, body_y, lm_w, body_h, box_radius, Blitbuffer.COLOR_DARK_GRAY, false, true, true, true)
    scrubber.paintCornerRect(bb, lm_x, body_y, lm_w, body_h, box_radius, Blitbuffer.COLOR_BLACK, false, true, true, true)

    local list_y = body_y + S(2)
    local list_h = body_h - S(4)
    scrubber.paintCornerRect(bb, lm_x + S(2), list_y, lm_w - S(4), list_h, inner_r, Blitbuffer.COLOR_WHITE, false, true, true, true)

    bb:paintRect(lm_x + S(2), menu_y + S(2), pag_tab_w - S(4), header_h, Blitbuffer.COLOR_WHITE)

    local start_x = lm_x + hdr_left_pad
    local hty = menu_y + S(2) + math.floor((header_h - S(2) - hsz.h) / 2)

    tw_hdr:paintTo(bb, start_x, hty)
    tw_hdr:paintTo(bb, start_x + 1, hty)
    tw_hdr:paintTo(bb, start_x, hty + 1)
    tw_hdr:paintTo(bb, start_x + 1, hty + 1)
    tw_hdr:free()

    scrubber._hl_main_tab_dimen = Geom:new{ x = lm_x, y = menu_y, w = pag_tab_w, h = header_h }

    if active_fd then
        local icon_offset_x = (active_fd.key == "underline") and S(4) or -S(2)
        local icon_x = start_x + hsz.w + icon_offset_x
        if active_fd.key == "underline" then
            local ul_w = S(11)
            local cy = menu_y + S(2) + math.floor((header_h - S(2)) / 2)
            bb:paintRect(icon_x, cy - S(3), ul_w, S(2), Blitbuffer.COLOR_BLACK)
            bb:paintRect(icon_x, cy + S(3), ul_w, S(2), Blitbuffer.COLOR_BLACK)
        else
            local y_extra = (active_fd.key == "normal") and S(3) or S(2)
            local tw_ic = TextWidget:new{ text = active_fd.icon, face = Font:getFace("cfont", S(12)), fgcolor = Blitbuffer.COLOR_BLACK }
            local tw_ic_sz = tw_ic:getSize()
            local icon_y = menu_y + S(2) + math.floor((header_h - S(2) - tw_ic_sz.h) / 2) + y_extra
            tw_ic:paintTo(bb, icon_x, icon_y)
            tw_ic:paintTo(bb, icon_x + 1, icon_y)
            tw_ic:free()
        end
    end

    scrubber._hl_filter_dimens = {}
    if is_multi_hl then
        local unselected_filters = {}
        for _, fd in ipairs(present_filters) do
            if fd.key ~= scrubber._hl_filter then
                table.insert(unselected_filters, fd)
            end
        end

        local num_unselected = #unselected_filters
        if num_unselected > 0 then
            local tab_start_x = lm_x + pag_tab_w + S(6)
            local folder_w = S(27)
            local folder_h = header_h - S(4)
            local folder_r = S(5)
            local folder_gap = S(4)
            local curr_folder_x = tab_start_x
            local curr_folder_y = menu_y + S(4)

            for _, fd in ipairs(unselected_filters) do
                scrubber.paintCornerRect(bb, curr_folder_x, curr_folder_y, folder_w, folder_h, folder_r, Blitbuffer.COLOR_BLACK, true, true, false, false)
                scrubber.paintCornerRect(bb, curr_folder_x + S(2), curr_folder_y + S(2), folder_w - S(4), folder_h - S(2), math.max(1, folder_r - S(2)), Blitbuffer.COLOR_WHITE, true, true, false, false)

                if fd.key == "underline" then
                    local ul_w = S(11)
                    local cx = curr_folder_x + math.floor((folder_w - ul_w) / 2)
                    local cy = curr_folder_y + math.floor(folder_h / 2)
                    bb:paintRect(cx, cy - S(3), ul_w, S(2), Blitbuffer.COLOR_BLACK)
                    bb:paintRect(cx, cy + S(3), ul_w, S(2), Blitbuffer.COLOR_BLACK)
                else
                    local tw_f = TextWidget:new{ text = fd.icon, face = Font:getFace("cfont", S(12)), fgcolor = Blitbuffer.COLOR_BLACK }
                    local tw_f_sz = tw_f:getSize()
                    local paint_x = curr_folder_x + math.floor((folder_w - tw_f_sz.w) / 2)
                    local paint_y = curr_folder_y + math.floor((folder_h - tw_f_sz.h) / 2)
                    tw_f:paintTo(bb, paint_x, paint_y)
                    tw_f:paintTo(bb, paint_x + 1, paint_y)
                    tw_f:free()
                end

                table.insert(scrubber._hl_filter_dimens, {
                    key = fd.key,
                    dimen = Geom:new{ x = curr_folder_x, y = menu_y, w = folder_w, h = header_h }
                })
                curr_folder_x = curr_folder_x + folder_w + folder_gap
            end
        end
    end

    if #other_items == 0 then
        local n_tw = TextWidget:new{ text = "—", face = Font:getFace("cfont", S_MEDIANO), fgcolor = Blitbuffer.COLOR_DARK_GRAY }
        local n_sz = n_tw:getSize()
        n_tw:paintTo(bb, lm_x + math.floor((lm_w - n_sz.w)/2), list_y + math.floor((list_h - n_sz.h)/2))
        n_tw:free()
    else
        local row_y_float = list_y
        for i = start_idx, end_idx do
            local current_row_y = math.floor(row_y_float)
            local p = other_items[i]
            local is_r_sel = (scrubber._cur_page == p)
            local fg_r = is_r_sel and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    
            if is_r_sel then
                scrubber.paintRoundRect(bb, lm_x + S(4), current_row_y + S(4), lm_w - S(8), row_h - S(8), S(8), Blitbuffer.COLOR_BLACK)
            end
            
            if not is_r_sel and i < end_idx then
                bb:paintRect(lm_x + S(15), current_row_y + row_h - 1, lm_w - S(30), 1, Blitbuffer.COLOR_GRAY)
            end
            
            local icon_str = (scrubber._active_tab == "bookmarks") and "\u{F147}" or "\u{F105}" 
            local tw_rm = TextWidget:new{ text = icon_str, face = Font:getFace("cfont", S(24)), fgcolor = fg_r }
            local rm_sz = tw_rm:getSize()
            local rm_x = lm_x + lm_w - rm_sz.w - S(15)
            
            local icon_y_offset = (scrubber._active_tab == "bookmarks") and 0 or S(1)
            tw_rm:paintTo(bb, rm_x, current_row_y + math.floor((row_h - rm_sz.h)/2) - icon_y_offset + S(1))
            tw_rm:free()
            
            local text_max_w_menu = lm_w - rm_sz.w - S(30)

            local tw_pg = TextWidget:new{ text = tostring(p), face = Font:getFace("cfont", S_MEDIANO), fgcolor = fg_r, max_width = text_max_w_menu }
            local tw_pg_sz = tw_pg:getSize()
            local pg_x = lm_x + S(15)
            local pg_y = current_row_y + math.floor((row_h - tw_pg_sz.h) / 2) + S(2)
            
            tw_pg:paintTo(bb, pg_x, pg_y)
            if is_r_sel then
                tw_pg:paintTo(bb, pg_x + 1, pg_y)
                tw_pg:paintTo(bb, pg_x, pg_y + 1)
                tw_pg:paintTo(bb, pg_x + 1, pg_y + 1)
            end
            tw_pg:free()
            
            local t_dim = Geom:new{ x = rm_x - S(10), y = current_row_y, w = rm_sz.w + S(20), h = row_h }
            local dyn_clickable_w = (rm_x - S(10)) - lm_x
            local r_dim = Geom:new{ x = lm_x, y = current_row_y, w = dyn_clickable_w, h = row_h }
            
            table.insert(scrubber._split_rows, { dimen = r_dim, toggle_dimen = t_dim, page = p })
            row_y_float = row_y_float + row_h
        end
        
        scrubber._split_prev_dimen = nil
        scrubber._split_next_dimen = nil
        
        if needs_pagination then
            local pag_h = row_h
            local pag_y = list_y + (num_rows - 1) * row_h
            
            bb:paintRect(lm_x + S(15), pag_y, lm_w - S(30), S(1), Blitbuffer.COLOR_GRAY)
            
            local pag_str = cur_page .. " / " .. total_pages
            local pag_tw = TextWidget:new{ text = pag_str, face = Font:getFace("cfont", S(12)), fgcolor = Blitbuffer.COLOR_DARK_GRAY }
            local pag_sz = pag_tw:getSize()
            
            local text_y = pag_y + math.floor((pag_h - pag_sz.h)/2) + S(2)
            pag_tw:paintTo(bb, lm_x + math.floor((lm_w - pag_sz.w)/2), text_y)
            pag_tw:free()
            
            local btn_w = S(60) 
            if cur_page > 1 then
                scrubber._split_prev_dimen = Geom:new{ x = lm_x, y = pag_y, w = btn_w, h = pag_h }
                local is_pressed = (scrubber._pressed_btn == "split_prev")
                if is_pressed then
                    scrubber.paintRoundRect(bb, scrubber._split_prev_dimen.x + S(4), scrubber._split_prev_dimen.y + S(4), scrubber._split_prev_dimen.w - S(8), scrubber._split_prev_dimen.h - S(8), S(8), Blitbuffer.COLOR_BLACK)
                end
                local fg = is_pressed and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
                local p_tw = TextWidget:new{ text = "‹", face = Font:getFace("cfont", S(20)), fgcolor = fg }
                local p_sz = p_tw:getSize()
                p_tw:paintTo(bb, lm_x + S(20), pag_y + math.floor((pag_h - p_sz.h)/2))
                p_tw:free()
            end
            if cur_page < total_pages then
                scrubber._split_next_dimen = Geom:new{ x = lm_x + lm_w - btn_w, y = pag_y, w = btn_w, h = pag_h }
                local is_pressed = (scrubber._pressed_btn == "split_next")
                if is_pressed then
                    scrubber.paintRoundRect(bb, scrubber._split_next_dimen.x + S(4), scrubber._split_next_dimen.y + S(4), scrubber._split_next_dimen.w - S(8), scrubber._split_next_dimen.h - S(8), S(8), Blitbuffer.COLOR_BLACK)
                end
                local fg = is_pressed and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
                local n_tw = TextWidget:new{ text = "›", face = Font:getFace("cfont", S(20)), fgcolor = fg }
                local n_sz = n_tw:getSize()
                n_tw:paintTo(bb, lm_x + lm_w - n_sz.w - S(20), pag_y + math.floor((pag_h - n_sz.h)/2))
                n_tw:free()
            end
        end
    end
end

return MenuView


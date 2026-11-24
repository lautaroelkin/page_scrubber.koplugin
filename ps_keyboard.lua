-- ps_keyboard.lua — PageScrubber
-- Port of KiKome's keyboard (kobold/ui/keyboard.lua), same public API and same behaviour, so a fix
-- made in one plugin can be copied to the other as it is. The only differences are the helpers it
-- leans on: icons and strings come from PageScrubber's kit (svg_picker.lua), the fonts from KOReader's
-- Font, and the "inverted icon" and the clock are inlined here (KiKome takes them from its widgets.lua).
--
-- A small on-screen keyboard drawn by the plugin, to type text inside any
-- KiKome screen without KOReader's own dialogs. Letters (with ñ and an accent
-- key: tap ´ and then a vowel), numbers and punctuation, shift, a delete key
-- (hold it to delete everything to the left of the caret) and a key that hides the keyboard.
--
-- The screen that owns it only places it and passes it the taps:
--
--   local Keyboard = require("ps_keyboard")
--   local kb = Keyboard.new{
--       on_insert = function(text) end,   -- a character was typed
--       on_delete = function() end,       -- delete: the last character
--       on_clear  = function() end,       -- delete held down: everything left of the caret
--       on_hide   = function() end,       -- the hide key
--       on_move   = function(delta) end,  -- optional: the finger slid over the space bar;
--                                         -- move the caret `delta` letters (negative: left).
--                                         -- Without it, sliding over the space bar does nothing
--       is_empty  = function() return true end,  -- optional: the field is empty
--       multiline = true,                 -- optional: an enter key, which types "\n" through
--                                         -- on_insert (after it the next letter is a capital)
--       on_redraw = function(rects) end,  -- the keys must be drawn again (a pressed
--                                         -- key lets go): rebuild, then refresh
--                                         -- only `rects` (screen Geoms: the keys
--                                         -- that changed), never the whole keyboard
--   }
--   kb:reset(true)            -- a field got the keyboard (true: start with a capital)
--   local widget = kb:build(Screen:getWidth())   -- put it at the bottom: kb:height() tall
--   -- on a tap / hold at `pos`, with `y0` the screen y of the keyboard's top:
--   local handled, text_changed, kb_changed, rects = kb:tap(pos, y0)
--   local handled, text_changed, kb_changed, rects = kb:hold(pos, y0)
--   -- on a swipe (a quick tap that the touch driver read as a short swipe, or a
--   -- finger rolling from one key to the next): same results as tap
--   local handled, text_changed, kb_changed, rects = kb:swipe(ges, y0)
--   -- on a pan / hold_pan (the finger moving), and when it lets go:
--   local handled, moved = kb:pan(ges, y0)    -- moved: the caret moved, redraw the field
--   kb:panEnd()                               -- pan_release / hold_release
--   kb:recentDrag()                           -- true while sliding and just after: eat the swipe
--   Keyboard.moveCaret(text, pos, delta)      -- the new caret (a byte offset), by letters
--   -- redraw what changed, and only that, so the e-ink panel does not flash:
--   --   text_changed  the typed text (refresh just the field)
--   --   kb_changed    the look of the keys changed (shift, 123, accent): refresh
--   --                 the whole keyboard
--   --   rects         (tap only) when kb_changed is false, the few keys that
--   --                 changed their pressed look: refresh only those
--   kb:free()                 -- when the screen closes

local Blitbuffer = require("ffi/blitbuffer")
local Device     = require("device")
local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local UIManager  = require("ui/uimanager")
local Widget     = require("ui/widget/widget")
local Kit        = require("svg_picker").kit
local _          = Kit._

-- What KiKome takes from kobold.ui.option_sheet / kobold.ui.widgets
local OptionSheet = { iconWidget = Kit.iconWidget }
local KoboldWidgets = {}
function KoboldWidgets.face(size) return Font:getFace("cfont", size) end
function KoboldWidgets.secondaryFace(size) return Font:getFace("infofont", size) end

-- A black icon drawn white on a black fill: a white square is painted under the icon, the icon is
-- drawn, and the square is inverted (as KoboldWidgets.inverted does).
local InvertedIcon = Widget:extend{ child = nil }
function InvertedIcon:getSize() return self.child:getSize() end
function InvertedIcon:paintTo(bb, x, y)
    local s = self.child:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = s.w, h = s.h }
    bb:paintRect(x, y, s.w, s.h, Blitbuffer.COLOR_WHITE)
    self.child:paintTo(bb, x, y)
    bb:invertRect(x, y, s.w, s.h)
end
function InvertedIcon:free()
    if self.child and self.child.free then self.child:free() end
end
function KoboldWidgets.inverted(child) return InvertedIcon:new{ child = child } end

-- Wall-clock seconds, with fractions when KOReader's ffi util offers them
local ok_ffiutil, ffiUtil = pcall(require, "ffi/util")
function KoboldWidgets.now()
    if ok_ffiutil and ffiUtil and ffiUtil.getTimestamp then
        local ok, sec, usec = pcall(ffiUtil.getTimestamp)
        if ok and sec then return sec + (usec or 0) / 1e6 end
    end
    return os.time()
end

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local C_KEY         = Blitbuffer.Color8(0xE8)  -- letter keys
local C_SPECIAL     = Blitbuffer.Color8(0xD0)  -- shift, delete, 123, hide
-- shift / accent switched on: black pad with a white label (clear on e-ink)
local C_PRESSED     = Blitbuffer.Color8(0xC0)  -- a key for the moment after it is tapped
local C_PLACEHOLDER = Blitbuffer.Color8(0x77)
local C_RULE        = Blitbuffer.Color8(0xBB)

local function U(n) return Screen:scaleBySize(n) end

local KEY_H, KEY_GAP_X, KEY_GAP_Y, KEY_SIDE, KEY_TOP, KEY_BOTTOM = 48, 6, 8, 6, 10, 10

-- Sliding over the space bar: the caret moves one letter per this much finger
-- travel (dp), as on Android.
local MOVE_STEP = 14

local UPPER = { ["ñ"] = "Ñ" }
local ACCENT = { a = "á", e = "é", i = "í", o = "ó", u = "ú" }
local ACCENT_UPPER = { a = "Á", e = "É", i = "Í", o = "Ó", u = "Ú" }

local function ch(c, w) return { kind = "char", ch = c, w = w } end

local function letters(s)
    local row = {}
    for c in s:gmatch("%S+") do row[#row + 1] = ch(c) end
    return row
end

-- A row from keys and lists of keys.
local function withKeys(...)
    local row = {}
    for _i, part in ipairs({ ... }) do
        if part.kind then row[#row + 1] = part else for _j, k in ipairs(part) do row[#row + 1] = k end end
    end
    return row
end

local ROWS_ABC = {
    letters("q w e r t y u i o p"),
    letters("a s d f g h j k l ñ"),
    withKeys({ kind = "shift", w = 1.5 }, letters("z x c v b n m"), { kind = "back", w = 1.5 }),
    withKeys({ kind = "layer", w = 1.5 }, { kind = "accent" }, { kind = "space", w = 5.5 },
        ch("."), { kind = "hide", w = 1 }),
}

local ROWS_NUM = {
    letters("1 2 3 4 5 6 7 8 9 0"),
    letters("- / : ; ( ) $ & @ \""),
    withKeys(letters(". , ? ! ' ¿ ¡ %"), { kind = "back", w = 2 }),
    withKeys({ kind = "layer", w = 2 }, { kind = "space", w = 7 }, { kind = "hide", w = 1 }),
}

-- The same two layers with an enter key, for fields of several lines (a
-- review): the space bar gives up some width.
local ROWS_ABC_ML = {
    ROWS_ABC[1], ROWS_ABC[2], ROWS_ABC[3],
    withKeys({ kind = "layer", w = 1.5 }, { kind = "accent" }, { kind = "space", w = 4 },
        ch("."), { kind = "enter", w = 1.5 }, { kind = "hide", w = 1 }),
}

local ROWS_NUM_ML = {
    ROWS_NUM[1], ROWS_NUM[2], ROWS_NUM[3],
    withKeys({ kind = "layer", w = 2 }, { kind = "space", w = 5 },
        { kind = "enter", w = 2 }, { kind = "hide", w = 1 }),
}

-- Where each key goes, in the keyboard's own coordinates.
local function layoutKeys(rows, width, key_h, gap_x, gap_y, side, top)
    local out = {}
    for ri, row in ipairs(rows) do
        local total = 0
        for _i, k in ipairs(row) do total = total + (k.w or 1) end
        local unit = (width - 2 * side - (#row - 1) * gap_x) / total
        local x = side
        local y = top + (ri - 1) * (key_h + gap_y)
        for _i, k in ipairs(row) do
            local kw = unit * (k.w or 1)
            out[#out + 1] = {
                kind = k.kind, ch = k.ch,
                rect = { x = math.floor(x), y = y, w = math.floor(kw), h = key_h },
            }
            x = x + kw + gap_x
        end
    end
    return out
end

-- The keys, painted: rounded grey pads with a centred label or icon.
local Pad = Widget:extend{ w = 0, h = 0, keys = nil }

function Pad:getSize() return Geom:new{ w = self.w, h = self.h } end
function Pad:free() end

function Pad:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    bb:paintRect(x, y, self.w, self.h, WHITE)
    bb:paintRect(x, y, self.w, math.max(1, U(1)), C_RULE)
    local radius = U(8)
    for _i, k in ipairs(self.keys or {}) do
        local r = k.rect
        bb:paintRoundedRect(x + r.x, y + r.y, r.w, r.h, k.bg, radius)
        if k.widget then
            local sz = k.widget:getSize()
            k.widget:paintTo(bb, x + r.x + math.floor((r.w - sz.w) / 2),
                y + r.y + math.floor((r.h - sz.h) / 2))
        end
    end
end

local Keyboard = {}

-- The e-ink refresh mode of the text field while typing, and while a finger
-- slides over the space bar (when it lets go the field is drawn once more in
-- "ui"). "fast" is quicker than "ui"; if it ever leaves marks, "ui" here puts
-- it back (the screens read this). The keys are always drawn in "ui": in the
-- fast mode their grey pads come out wrong and the keys seem to vanish.
Keyboard.REFRESH = "fast"
Keyboard.__index = Keyboard

function Keyboard.new(opts)
    local self = setmetatable({}, Keyboard)
    self.on_insert = opts.on_insert
    self.on_delete = opts.on_delete
    self.on_clear = opts.on_clear
    self.on_hide = opts.on_hide
    self.on_move = opts.on_move
    self.is_empty = opts.is_empty
    self.on_redraw = opts.on_redraw
    self.multiline = opts.multiline and true or false
    self.pressed = nil  -- index of the key that was just tapped
    self.pressed_rects = {}  -- screen areas of keys whose pressed look is on screen
    self:reset(false)
    return self
end

-- Total height of the keyboard.
function Keyboard:height()
    return U(KEY_TOP) + 4 * U(KEY_H) + 3 * U(KEY_GAP_Y) + U(KEY_BOTTOM)
end

-- Back to letters, no accent; capital = start the next word with a capital.
function Keyboard:reset(capital)
    self.layer, self.accent = "abc", false
    self.shift = capital and "once" or "off"
    self.pressed = nil
    self.pressed_rects = {}
end

-- The character a letter key types or shows now: accented while the accent
-- key is on, in capitals while shift is.
function Keyboard:display(c)
    if self.layer ~= "abc" then return c end
    local upper = self.shift ~= "off"
    if self.accent and ACCENT[c] then
        return upper and ACCENT_UPPER[c] or ACCENT[c]
    end
    if upper then return UPPER[c] or c:upper() end
    return c
end

function Keyboard:freeWidgets()
    for _i, w in ipairs(self.widgets or {}) do
        if w.free then w:free() end
    end
    self.widgets = nil
end

-- Lets go of everything: the widgets and a pending key release.
function Keyboard:free()
    if self.release then
        UIManager:unschedule(self.release)
        self.release = nil
    end
    self.pressed = nil
    self.pressed_rects = {}
    self.drag = nil
    self:freeWidgets()
end

-- Makes the keyboard's widget for the current state, `width` wide. Call it
-- again after a tap that changed the keys (shift, 123, accent).
function Keyboard:build(width)
    self:freeWidgets()
    local rows
    if self.layer == "num" then
        rows = self.multiline and ROWS_NUM_ML or ROWS_NUM
    else
        rows = self.multiline and ROWS_ABC_ML or ROWS_ABC
    end
    local keys = layoutKeys(rows, width, U(KEY_H), U(KEY_GAP_X), U(KEY_GAP_Y), U(KEY_SIDE), U(KEY_TOP))
    local widgets = {}
    for i, key in ipairs(keys) do
        local k = key.kind
        local bg, w = C_KEY, nil
        key.idx = i
        -- A key that was just tapped shows a little darker for a moment
        -- (see tap).
        local pressed = (self.pressed == i)
        if k == "char" then
            w = TextWidget:new{ text = self:display(key.ch), face = KoboldWidgets.face(22) }
            if pressed then bg = C_PRESSED end
        elseif k == "shift" then
            local on = self.shift ~= "off"
            bg = on and BLACK or C_SPECIAL
            -- switched on: a white icon on the black pad (a tinted icon would
            -- come out black on black), drawn as the play button is
            local icon = OptionSheet.iconWidget("chevron-up", U(26), BLACK)
            w = on and KoboldWidgets.inverted(icon) or icon
        elseif k == "back" then
            bg = pressed and C_PRESSED or C_SPECIAL
            w = OptionSheet.iconWidget("arrow-left", U(26), BLACK)
        elseif k == "layer" then
            bg = C_SPECIAL
            w = TextWidget:new{ text = (self.layer == "num") and "ABC" or "123", face = KoboldWidgets.face(17) }
        elseif k == "accent" then
            bg = self.accent and BLACK or C_SPECIAL
            w = TextWidget:new{ text = "´", face = KoboldWidgets.face(24), fgcolor = self.accent and WHITE or BLACK }
        elseif k == "space" then
            bg = pressed and C_PRESSED or C_KEY
            w = TextWidget:new{ text = _("space"), face = KoboldWidgets.secondaryFace(15), fgcolor = C_PLACEHOLDER }
        elseif k == "enter" then
            bg = pressed and C_PRESSED or C_SPECIAL
            w = OptionSheet.iconWidget("corner-down-left", U(26), BLACK)
        elseif k == "hide" then
            bg = C_SPECIAL
            w = OptionSheet.iconWidget("chevron-down", U(26), BLACK)
        end
        key.bg, key.widget = bg, w
        widgets[#widgets + 1] = w
    end
    self.keys = keys
    self.widgets = widgets
    return Pad:new{ w = width, h = self:height(), keys = keys }
end

-- The key under screen point `pos`, `y0` being the screen y of the top.
function Keyboard:keyAt(pos, y0)
    local ky = pos.y - y0
    for _i, key in ipairs(self.keys or {}) do
        local r = key.rect
        if pos.x >= r.x and pos.x < r.x + r.w and ky >= r.y and ky < r.y + r.h then
            return key
        end
    end
    return nil
end

local function call(fn, ...) if fn then fn(...) end end

-- The screen area of a key (a hair larger, for its rounded corners), `y0`
-- being the screen y of the keyboard's top.
function Keyboard:keyRegion(key, y0)
    local r = key.rect
    return Geom:new{ x = r.x - 1, y = y0 + r.y - 1, w = r.w + 2, h = r.h + 2 }
end

-- The tapped key lets go a moment later and only that key is drawn again.
function Keyboard:pressKeyDown(key, y0)
    self.pressed = key.idx
    local rect = self:keyRegion(key, y0)
    self.pressed_rects[#self.pressed_rects + 1] = rect
    if self.release then UIManager:unschedule(self.release) end
    self.release = function()
        self.release = nil
        if self.pressed then
            self.pressed = nil
            self.pressed_rects = {}
            call(self.on_redraw, { rect })
        end
    end
    UIManager:scheduleIn(0.15, self.release)
end

-- After a delete: an emptied field starts with a capital again.
function Keyboard:capitalAgain()
    if self.is_empty and self.is_empty() and self.layer == "abc" and self.shift == "off" then
        self.shift = "once"
        return true
    end
    return false
end

-- What a tap on `key` does. Returns text_changed (the typed text changed),
-- kb_changed (the keys look different now: shift, 123, accent, capitals) and
-- rects: the screen areas of the keys whose pressed look changed, the one just
-- tapped and the one that was still showing it. When kb_changed is true the
-- whole keyboard is redrawn anyway; when it is false only `rects` need a
-- refresh (a plain letter changes nothing else on the keyboard).
function Keyboard:tapKey(key, y0)
    local k = key.kind
    local text_changed, kb_changed = false, false
    -- The key that was still dark (tapped a moment ago) has to be drawn
    -- normally again: its area goes into the refresh too.
    local rects = self.pressed_rects or {}
    self.pressed_rects = {}
    self.pressed = nil
    if k == "char" then
        call(self.on_insert, self:display(key.ch))
        text_changed = true
        self:pressKeyDown(key, y0)
        if self.accent then self.accent, kb_changed = false, true end
        if self.layer == "abc" and self.shift == "once" then self.shift, kb_changed = "off", true end
    elseif k == "space" then
        call(self.on_insert, " ")
        text_changed = true
        self:pressKeyDown(key, y0)
        if self.accent then self.accent, kb_changed = false, true end
    elseif k == "enter" then
        call(self.on_insert, "\n")
        text_changed = true
        self:pressKeyDown(key, y0)
        if self.accent then self.accent, kb_changed = false, true end
        -- a new line starts with a capital
        if self.layer == "abc" and self.shift == "off" then self.shift, kb_changed = "once", true end
    elseif k == "back" then
        call(self.on_delete)
        text_changed = true
        self:pressKeyDown(key, y0)
        if self:capitalAgain() then kb_changed = true end
    elseif k == "shift" then
        self.shift = (self.shift == "off") and "once" or "off"
        kb_changed = true
    elseif k == "layer" then
        self.layer = (self.layer == "abc") and "num" or "abc"
        self.accent = false
        kb_changed = true
    elseif k == "accent" then
        self.accent = not self.accent
        kb_changed = true
    elseif k == "hide" then
        call(self.on_hide)
    end
    for _i, r in ipairs(self.pressed_rects) do rects[#rects + 1] = r end
    return text_changed, kb_changed, rects
end

-- A tap. Returns handled (it was on the keyboard), then what tapKey returns.
function Keyboard:tap(pos, y0)
    if pos.y < y0 then return false, false, false end
    local key = self:keyAt(pos, y0)
    if not key then return true, false, false end
    local text_changed, kb_changed, rects = self:tapKey(key, y0)
    return true, text_changed, kb_changed, rects
end

-- The keys that type something. Two of them in a row can be tapped by one
-- swipe (see swipe); the others change how the keys look.
local TYPING = { char = true, space = true, back = true, enter = true }

-- A swipe that started on the keyboard. Typing fast, a quick tap is often read
-- by the touch driver as a short swipe, and the letter would be lost; and a
-- finger that rolls from one key to the next is two taps, not one swipe. So:
--   * a finger that went from one typing key to another taps both, in order;
--   * a short swipe (less than half a key) taps the key it started on;
--   * a long one is a real swipe: nothing is typed (handled = false).
-- The swipe that closes a slide on the space bar (see pan) is never a tap.
-- Returns the same as tap.
function Keyboard:swipe(ges, y0)
    local p = ges and ges.pos
    if not p or p.y < y0 then return false, false, false end
    if self:recentDrag() then return true, false, false end
    local start = self:keyAt(p, y0)
    if not start then return false, false, false end
    local e = ges.end_pos
    local stop = (e and e.y >= y0) and self:keyAt(e, y0) or nil
    local r = start.rect
    local dist = ges.distance
    if not dist and e then dist = math.sqrt((e.x - p.x) ^ 2 + (e.y - p.y) ^ 2) end
    local short = (dist or 0) < math.min(r.w, r.h) * 0.5
    if stop and stop ~= start and TYPING[start.kind] and TYPING[stop.kind] then
        local t1, k1, r1 = self:tapKey(start, y0)
        local t2, k2, r2 = self:tapKey(stop, y0)
        for _i, rc in ipairs(r1) do r2[#r2 + 1] = rc end
        return true, t1 or t2, k1 or k2, r2
    end
    if short then
        local t, k, rc = self:tapKey(start, y0)
        return true, t, k, rc
    end
    return false, false, false
end

-- A long press: on the delete key it clears everything left of the caret. On the space bar it
-- does nothing here (that is where the caret slide starts, see pan). On any
-- other key it is a tap that took a little too long, so it types anyway
-- instead of being lost. Returns the same as tap.
function Keyboard:hold(pos, y0)
    if pos.y < y0 then return false, false, false end
    local key = self:keyAt(pos, y0)
    if key and key.kind == "back" then
        call(self.on_clear)
        return true, true, self:capitalAgain()
    end
    if key and key.kind ~= "space" then
        local text_changed, kb_changed, rects = self:tapKey(key, y0)
        return true, text_changed, kb_changed, rects
    end
    return true, false, false
end

-- The caret (a byte offset in `text`, 0 = before the first letter) moved
-- `delta` letters to the right, or to the left when negative. A letter can be
-- several bytes long, so it never lands in the middle of one.
function Keyboard.moveCaret(text, pos, delta)
    pos = math.max(0, math.min(pos or #text, #text))
    local step = (delta > 0) and 1 or -1
    for _i = 1, math.abs(delta) do
        if step < 0 then
            if pos == 0 then break end
            local i = pos
            while i > 1 and text:byte(i) >= 0x80 and text:byte(i) < 0xC0 do i = i - 1 end
            pos = i - 1
        else
            if pos >= #text then break end
            local j = pos + 1
            while j < #text and text:byte(j + 1) >= 0x80 and text:byte(j + 1) < 0xC0 do j = j + 1 end
            pos = j
        end
    end
    return pos
end

-- The finger moving (a "pan", or a "hold_pan" after pressing a moment). It
-- only counts when the finger came down on the space bar: then the caret
-- follows it, one letter per MOVE_STEP of travel, in either direction, until
-- it lets go (panEnd). Returns handled (this is a slide on the space bar, so
-- nobody else should take it) and moved (the caret moved: draw the field).
function Keyboard:pan(ges, y0)
    if not (self.on_move and ges and ges.pos) then return false, false end
    local pos, rel = ges.pos, ges.relative
    if not self.drag then
        -- Where the finger came down is about one step back from where this
        -- first event says it is; the space bar must have it either way.
        local function onSpace(x, y)
            local key = self:keyAt({ x = x, y = y }, y0)
            return key and key.kind == "space"
        end
        if not (onSpace(pos.x, pos.y) or (rel and onSpace(pos.x - rel.x, pos.y - rel.y))) then
            return false, false
        end
        self.drag = { x0 = rel and (pos.x - rel.x) or pos.x, steps = 0 }
    end
    local d = self.drag
    d.stamp = KoboldWidgets.now()
    -- the travel since the finger came down (pos is where it is now)
    local v = (pos.x - d.x0) / U(MOVE_STEP)
    local steps = (v >= 0) and math.floor(v) or math.ceil(v)
    local delta = steps - d.steps
    if delta == 0 then return true, false end
    d.steps = steps
    call(self.on_move, delta)
    return true, true
end

-- The finger let go. True when a slide on the space bar had been going on.
function Keyboard:panEnd()
    local was = self.drag ~= nil
    self.drag = nil
    if was then self.drag_end = KoboldWidgets.now() end
    return was
end

-- True while a slide is going on and for a moment after it: the swipe that
-- can close a quick slide must not do anything (turn a page, close a sheet).
function Keyboard:recentDrag()
    if self.drag then
        -- one that never got its release is dropped, so it can never block swipes
        if KoboldWidgets.now() - (self.drag.stamp or 0) > 3 then self.drag = nil else return true end
    end
    return self.drag_end ~= nil and KoboldWidgets.now() - self.drag_end < 0.4
end

return Keyboard

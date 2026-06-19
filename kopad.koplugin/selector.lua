--[[
Selector — two-layer gamepad text selector for EPUB documents.

Layer 1: Crosshair mode (default when opened)
  D-pad / L-stick moves a crosshair that snaps to the nearest word.
  The containing sentence is softly highlighted.
  A = confirm word → enters structured mode.

Layer 2: Structured mode (after confirming a word)
  Up/Down = move sentence selection
  Left/Right = move word within sentence
  A = action menu
  B = back to crosshair mode
  X = highlight selection
  Y = dictionary lookup

Key mapping (SDL3 gamepad → KOReader key names):
  Up/Down/Left/Right  D-pad or L-stick
  Press               A button (South)
  Back                B button (East)
  ContextMenu         Y button (North)
  RPgBack             Select button — toggle overlay
  RPgFwd              Guide/Home button — page forward
  Menu                Start button — open menu
]]

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Event          = require("ui/event")
local Geom           = require("ui/geometry")
local InfoMessage    = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local util           = require("util")
local _              = require("gettext")
local Screen         = Device.screen

local WordSource = require("wordsource")

local STATUS_FACE = require("ui/font"):getFace("infofont", 14)
local LABEL_FACE  = require("ui/font"):getFace("infofont", 12)

local SEL_RADIUS = 8

local function invert_rounded_rect(bb, ox, oy, x, y, w, h)
    local r = math.min(SEL_RADIUS, math.floor(w / 2), math.floor(h / 2))
    bb:invertRect(ox + x, oy + y, w, h)
    if r < 2 then return end
    for py = 0, r - 1 do
        local dy  = r - py
        local dx  = math.floor(math.sqrt(r * r - dy * dy))
        local ow  = r - dx
        if ow > 0 then
            local ay = y + py
            local by = y + h - 1 - py
            bb:invertRect(ox + x,           oy + ay, ow, 1)
            bb:invertRect(ox + x + w - ow,  oy + ay, ow, 1)
            bb:invertRect(ox + x,           oy + by, ow, 1)
            bb:invertRect(ox + x + w - ow,  oy + by, ow, 1)
        end
    end
end

----------------------------------------------------------------------
-- SelectorOverlay (display widget, no key handling)
----------------------------------------------------------------------

local SelectorOverlay = InputContainer:extend{
    name = "kopad_selector_overlay",
    doc  = nil,
    ui   = nil,
}

function SelectorOverlay:init()
    self.dimen = Geom:new{ x = 0, y = 0,
                           w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = false

    self.mode = "cross"  -- "cross" | "struct" | "walk"

    self.cursor_word = nil   -- index into self.words
    self.cursor_sent = nil   -- index into self.sentences

    self.sel_sent = nil      -- selected sentence index (single / head)
    self.sel_tail = nil      -- sentence tail for multi-sentence selection
    self.sel_word = nil      -- word head index (nil = whole sentence)
    self.sel_word_tail = nil -- word tail for multi-word selection

    self.ww_word = nil       -- current word in walk mode {pos0, pos1, sbox, word}
    self.ww_extend_pos0 = nil -- left boundary xpointer (walk extend)

    self.extend_side = nil   -- nil | "right" | "left"

    self.hl_items = {}       -- on-screen highlights { ann, boxes, sbox }
    self.hl_cur   = 0        -- focused highlight index (0 = none)

    -- RTL: reverse ↔ direction for right-to-left scripts
    local rtl_langs = { ar=true, he=true, fa=true, ur=true }
    local ok_p, props = pcall(function() return self.ui.document:getProps() end)
    local lang_raw = (ok_p and props and props.language) or ""
    local lang_base = lang_raw:lower():match("^([a-z]+)") or ""
    self.is_rtl = rtl_langs[lang_base] or false

    self:_collect()
    self:_collect_highlights()
    if #self.words > 0 then
        self:_snap_to_center()
    end
end

function SelectorOverlay:_collect()
    local screen_h = Screen:getHeight()
    local ok_w, words = pcall(WordSource.collect_words, self.doc, screen_h)
    self.words = (ok_w and words) or {}

    local ok_s, sents = pcall(WordSource.collect_sentences_from_words, self.words)
    self.sentences = (ok_s and sents) or {}

    -- Complete first sentence if page starts mid-sentence.
    if #self.sentences > 0 and #self.words > 0 then
        local ok_clean, page_clean = pcall(
            WordSource.page_starts_at_boundary, self.doc)
        if ok_clean and not page_clean then
            local ok_start, start_xp = pcall(
                WordSource.find_sentence_start, self.doc, self.words[1].xp0)
            if ok_start and start_xp then
                self.sentences[1].xp0 = start_xp
                self.sentences[1]._extends_before = true
            end
        end
    end

    -- Extend last sentence if it continues off-screen.
    if #self.sentences > 0 and #self.words > 0 then
        local lw    = self.words[#self.words]
        local inter = lw.inter or ""
        local has_end = inter:find("[%.!%?]")
                     or inter:find("\xD8\x9F")
                     or inter:find("\xDB\x94")
                     or inter:find("\n")
        if not has_end and lw.next_xp0 then
            local ok, end_xp1 = pcall(
                WordSource.find_sentence_end, self.doc, lw.next_xp0, lw.xp0)
            if ok and end_xp1 then
                self.sentences[#self.sentences].xp1 = end_xp1
                self.sentences[#self.sentences]._extends_after = true
            end
        end
    end

    -- map word xpointer → sentence index for O(1) lookup
    self._xp_to_sent = {}
    for si, sent in ipairs(self.sentences) do
        if sent.word_list then
            for _, witem in ipairs(sent.word_list) do
                self._xp_to_sent[witem.xp0] = si
            end
        end
    end

    -- map each word index → parent sentence index
    self.word_to_sent = {}
    for wi, w in ipairs(self.words) do
        self.word_to_sent[wi] = self._xp_to_sent[w.xp0]
    end
end

function SelectorOverlay:reload()
    self:_collect()
    self:_collect_highlights()
    if #self.words > 0 then
        self:_snap_to_center()
    end
    self:_refresh()
end

function SelectorOverlay:_collect_highlights()
    self.hl_items = {}
    self.hl_cur   = 0
    local anns = self.ui and self.ui.annotation and self.ui.annotation.annotations
    if not anns then return end
    local sh = Screen:getHeight()
    for _, ann in ipairs(anns) do
        if ann.pos0 and ann.pos1 then
            local ok, boxes = pcall(function()
                return self.doc:getScreenBoxesFromPositions(ann.pos0, ann.pos1, true)
            end)
            if ok and boxes and #boxes > 0 then
                local on_screen, min_y, sbox = false, math.huge, nil
                for _, b in ipairs(boxes) do
                    if b.y < sh and b.y + b.h > 0 then
                        on_screen = true
                        if b.y < min_y then min_y = b.y; sbox = b end
                    end
                end
                if on_screen and sbox then
                    table.insert(self.hl_items, { ann = ann, boxes = boxes, sbox = sbox })
                end
            end
        end
    end
    table.sort(self.hl_items, function(a, b) return a.sbox.y < b.sbox.y end)
end

function SelectorOverlay:_snap_to_center()
    local cx = Screen:getWidth() / 2
    local cy = Screen:getHeight() / 2
    self.cursor_word = self:_nearest_word(cx, cy)
    self.cursor_sent = self.word_to_sent[self.cursor_word]
end

function SelectorOverlay:_nearest_word(px, py)
    local best, best_dist = 1, math.huge
    for i, w in ipairs(self.words) do
        if w.sbox then
            local wx = w.sbox.x + w.sbox.w / 2
            local wy = w.sbox.y + w.sbox.h / 2
            local d = (wx - px)^2 + (wy - py)^2
            if d < best_dist then
                best = i; best_dist = d
            end
        end
    end
    return best
end

function SelectorOverlay:_refresh()
    UIManager:setDirty("all", "ui")
end

----------------------------------------------------------------------
-- Crosshair movement
----------------------------------------------------------------------

function SelectorOverlay:move(dx, dy)
    if self.mode == "cross" then
        self:_cross_move(dx, dy)
    else
        self:_struct_move(dx, dy)
    end
end

function SelectorOverlay:_cross_move(dx, dy)
    if #self.words == 0 then return end
    local cur = self.words[self.cursor_word]
    if not cur or not cur.sbox then return end

    local cx = cur.sbox.x + cur.sbox.w / 2
    local cy = cur.sbox.y + cur.sbox.h / 2
    local lh = cur.sbox.h

    if dy ~= 0 and dx == 0 then
        local target_y = cy + dy * lh * 1.2
        local best, best_dist = self.cursor_word, math.huge
        for i, w in ipairs(self.words) do
            if w.sbox then
                local wy = w.sbox.y + w.sbox.h / 2
                if (dy > 0 and wy > cy + lh * 0.5) or
                   (dy < 0 and wy < cy - lh * 0.5) then
                    local d = math.abs(wy - target_y) * 2 + math.abs(w.sbox.x + w.sbox.w/2 - cx)
                    if d < best_dist then
                        best = i; best_dist = d
                    end
                end
            end
        end
        self.cursor_word = best
    elseif dx ~= 0 then
        local new = self.cursor_word + dx
        if new >= 1 and new <= #self.words then
            self.cursor_word = new
        end
    end

    self.cursor_sent = self.word_to_sent[self.cursor_word]
    self:_refresh()
end

----------------------------------------------------------------------
-- Structured movement
----------------------------------------------------------------------

function SelectorOverlay:_struct_move(dx, dy)
    if #self.sentences == 0 then return end

    if dy ~= 0 and self.sel_word == nil then
        local new = self.sel_sent + dy
        if new >= 1 and new <= #self.sentences then
            self.sel_sent = new
        end
    elseif dy ~= 0 and self.sel_word ~= nil then
        local sent = self.sentences[self.sel_sent]
        if not sent or not sent.word_list then return end
        local cur_w = sent.word_list[self.sel_word]
        if not cur_w or not cur_w.sbox then return end
        local cxw = cur_w.sbox.x + cur_w.sbox.w / 2
        local cyw = cur_w.sbox.y + cur_w.sbox.h / 2
        local lhw = cur_w.sbox.h
        local best, best_dist = self.sel_word, math.huge
        for i, w in ipairs(sent.word_list) do
            if w.sbox then
                local wy = w.sbox.y + w.sbox.h / 2
                if (dy > 0 and wy > cyw + lhw * 0.5) or
                   (dy < 0 and wy < cyw - lhw * 0.5) then
                    local d = math.abs(wy - (cyw + dy * lhw)) * 2 + math.abs(w.sbox.x + w.sbox.w/2 - cxw)
                    if d < best_dist then
                        best = i; best_dist = d
                    end
                end
            end
        end
        self.sel_word = best
    elseif dx ~= 0 then
        if self.sel_word == nil then
            local sent = self.sentences[self.sel_sent]
            if sent and sent.word_list and #sent.word_list > 0 then
                self.sel_word = dx > 0 and 1 or #sent.word_list
            end
        else
            local sent = self.sentences[self.sel_sent]
            if not sent or not sent.word_list then return end
            local new = self.sel_word + dx
            if new >= 1 and new <= #sent.word_list then
                self.sel_word = new
            end
        end
    end

    self:_refresh()
end

function SelectorOverlay:para_jump(delta)
    if #self.sentences == 0 then return end
    local cur_para = self.sentences[self.sel_sent] and self.sentences[self.sel_sent].para
    if delta > 0 then
        for j = self.sel_sent + 1, #self.sentences do
            if self.sentences[j].para ~= cur_para then
                self.sel_sent = j; self.sel_word = nil
                self:_refresh(); return
            end
        end
    else
        local j = self.sel_sent - 1
        while j >= 1 and self.sentences[j].para == cur_para do j = j - 1 end
        if j >= 1 then
            local prev_para = self.sentences[j].para
            while j > 1 and self.sentences[j - 1].para == prev_para do j = j - 1 end
            self.sel_sent = j; self.sel_word = nil
            self:_refresh()
        end
    end
end

----------------------------------------------------------------------
-- Word walk navigation
----------------------------------------------------------------------

function SelectorOverlay:_is_split_word(word)
    if not word or not word.pos0 or not word.pos1 then return false end
    if word.segments then
        return #word.segments > 1 and word.segments[1].y ~= word.segments[#word.segments].y
    end
    local ok, segs = pcall(function()
        return self.doc:getScreenBoxesFromPositions(word.pos0, word.pos1, true)
    end)
    if not ok or not segs or #segs == 0 then return false end
    word.segments = segs
    return #segs > 1 and segs[1].y ~= segs[#segs].y
end

-- Determine correct fragment (head/tail) of a split hyphenated word from probe x position.
-- LTR: right side = head (end of line). RTL: right side = tail (start of next line).
-- Returns: word (with is_split_fragment set), eval_y for Y-clamp check.
function SelectorOverlay:_resolve_split_fragment(word, x_pos)
    if not self:_is_split_word(word) then
        return word, word.sbox.y + word.sbox.h * 0.5
    end
    local right_half = x_pos > (word.sbox.x + word.sbox.w * 0.5)
    local is_head = self.is_rtl ~= right_half
    word.is_split_fragment = is_head and "head" or "tail"
    local fbox = is_head and word.segments[1] or word.segments[#word.segments]
    return word, fbox.y + fbox.h * 0.5
end

function SelectorOverlay:_ww_fragment_sbox()
    local w = self.ww_word
    if not w then return nil end
    if w.is_split_fragment and w.segments and #w.segments > 0 then
        if w.is_split_fragment == "head" then return w.segments[1] end
        return w.segments[#w.segments]
    end
    return w.sbox
end

function SelectorOverlay:_ww_word_from_xp(xp)
    local doc = self.doc
    local end_xp = doc:getNextVisibleWordEnd(xp)
    if not end_xp then return nil end
    local ok, boxes = pcall(function()
        return doc:getScreenBoxesFromPositions(xp, end_xp, true)
    end)
    if not ok or not boxes or #boxes == 0 then return nil end
    local sbox = Geom.boundingBox(boxes)
    if not sbox then return nil end
    local ok2, text = pcall(function()
        return doc:getTextFromXPointers(xp, end_xp)
    end)
    return {
        pos0 = xp, pos1 = end_xp, sbox = sbox,
        word = (ok2 and text) or "", segments = boxes,
    }
end

function SelectorOverlay:_ww_snap_first()
    self:_collect()
    if #self.words > 0 then
        self.ww_word = self:_ww_word_from_xp(self.words[1].xp0)
    else
        self.ww_word = nil
    end
end

function SelectorOverlay:_ww_extend()
    if not self.ww_word then return end
    if not self.ww_extend_pos0 then
        self.ww_extend_pos0 = self.ww_word.pos0
    end
    local doc = self.doc
    local next_xp = doc:getNextVisibleWordStart(self.ww_word.pos0)
    if not next_xp or next_xp == self.ww_word.pos0
        or not doc:isXPointerInCurrentPage(next_xp) then
        return
    end
    self.ww_word = self:_ww_word_from_xp(next_xp)
    self:_refresh()
end

function SelectorOverlay:_ww_trim()
    if not self.ww_word or not self.ww_extend_pos0 then return end
    if self.ww_word.pos0 == self.ww_extend_pos0 then
        self.ww_extend_pos0 = nil
        self:_refresh()
        return
    end
    local doc = self.doc
    local prev_xp = doc:getPrevVisibleWordStart(self.ww_word.pos0)
    if not prev_xp or prev_xp == self.ww_word.pos0 then return end
    self.ww_word = self:_ww_word_from_xp(prev_xp)
    self:_refresh()
end

function SelectorOverlay:_ww_move(delta)
    if not self.ww_word then return end
    self.ww_extend_pos0 = nil

    if self:_is_split_word(self.ww_word) and self.ww_word.is_split_fragment then
        if delta > 0 and self.ww_word.is_split_fragment == "head" then
            self.ww_word.is_split_fragment = "tail"
            self:_refresh(); return
        elseif delta < 0 and self.ww_word.is_split_fragment == "tail" then
            self.ww_word.is_split_fragment = "head"
            self:_refresh(); return
        end
    end

    local doc = self.doc
    local cur_xp = self.ww_word.pos0
    if delta > 0 then
        local next_xp = doc:getNextVisibleWordStart(cur_xp)
        if not next_xp or next_xp == cur_xp
            or not doc:isXPointerInCurrentPage(next_xp) then
            self.ui:handleEvent(Event:new("GotoViewRel", 1))
            self:_ww_snap_first()
        else
            self.ww_word = self:_ww_word_from_xp(next_xp)
            if self.ww_word and self:_is_split_word(self.ww_word) then
                self.ww_word.is_split_fragment = "head"
            end
        end
    else
        local prev_xp = doc:getPrevVisibleWordStart(cur_xp)
        if not prev_xp or prev_xp == cur_xp
            or not doc:isXPointerInCurrentPage(prev_xp) then
            return
        end
        self.ww_word = self:_ww_word_from_xp(prev_xp)
        if self.ww_word and self:_is_split_word(self.ww_word) then
            self.ww_word.is_split_fragment = "tail"
        end
    end
    self:_refresh()
end

function SelectorOverlay:_ww_line(delta)
    if not self.ww_word or not self.ww_word.sbox then return end
    self.ww_extend_pos0 = nil
    local doc    = self.doc
    local fsbox  = self:_ww_fragment_sbox() or self.ww_word.sbox
    local target_x = fsbox.x
    local start_y  = fsbox.y + fsbox.h * 0.5
    local line_h   = fsbox.h
    local line_tol = line_h * 0.3

    local current_xp    = self.ww_word.pos0
    local target_line_y = nil
    local fallback_xp   = nil
    for _ = 1, 80 do
        local next_xp = delta > 0
            and doc:getNextVisibleWordStart(current_xp)
            or  doc:getPrevVisibleWordStart(current_xp)
        if not next_xp or next_xp == current_xp then break end
        if not doc:isXPointerInCurrentPage(next_xp) then break end
        current_xp = next_xp
        local sy = doc:getScreenPositionFromXPointer(next_xp)
        if not sy then break end
        if (delta > 0 and sy > start_y + line_tol)
            or (delta < 0 and sy < start_y - line_tol) then
            target_line_y = sy
            fallback_xp   = next_xp
            break
        end
    end
    if not target_line_y then return end

    local ok, probe = pcall(function()
        return doc:getWordFromPosition({x = target_x, y = target_line_y}, true)
    end)
    if ok and probe and probe.pos0 and probe.pos0 ~= self.ww_word.pos0 then
        local ok2, boxes = pcall(function()
            return doc:getScreenBoxesFromPositions(probe.pos0, probe.pos1, true)
        end)
        if ok2 and boxes and #boxes > 0 then
            local sbox = Geom.boundingBox(boxes)
            if sbox then
                probe.sbox = sbox; probe.segments = boxes
                local resolved, eval_y = self:_resolve_split_fragment(probe, target_x)
                if math.abs(eval_y - target_line_y) <= line_tol then
                    self.ww_word = {
                        pos0 = resolved.pos0, pos1 = resolved.pos1,
                        sbox = sbox, word = resolved.word or "",
                        segments = boxes,
                        is_split_fragment = resolved.is_split_fragment,
                    }
                    self:_refresh()
                    return
                end
            end
        end
    end

    if fallback_xp then
        local word = self:_ww_word_from_xp(fallback_xp)
        if word then
            self.ww_word = word
            self:_refresh()
        end
    end
end

----------------------------------------------------------------------
-- Extend mode (RB = right end, LB = left end)
----------------------------------------------------------------------

function SelectorOverlay:enter_extend(side)
    self.extend_side = side
    if self.mode == "walk" and not self.ww_extend_pos0 then
        self.ww_extend_pos0 = self.ww_word and self.ww_word.pos0
    elseif self.mode == "struct" then
        if not self.sel_tail then self.sel_tail = self.sel_sent end
        if self.sel_word and not self.sel_word_tail then
            self.sel_word_tail = self.sel_word
        end
    end
    self:_refresh()
end

function SelectorOverlay:exit_extend()
    self.extend_side = nil
    self:_refresh()
end

function SelectorOverlay:extend_dpad(dx, dy)
    if self.mode == "walk" then
        self:_extend_walk(dx, dy)
    elseif self.mode == "struct" then
        if self.sel_word then
            self:_extend_struct_word(dx, dy)
        else
            self:_extend_struct_sent(dx, dy)
        end
    end
end

function SelectorOverlay:_extend_walk(dx, dy)
    if not self.ww_word or not self.ww_extend_pos0 then return end
    local doc = self.doc
    if self.extend_side == "right" then
        if dx ~= 0 then
            local cur = self.ww_word.pos0
            local next_xp = dx > 0
                and doc:getNextVisibleWordStart(cur)
                or  doc:getPrevVisibleWordStart(cur)
            if next_xp and next_xp ~= cur and doc:isXPointerInCurrentPage(next_xp) then
                self.ww_word = self:_ww_word_from_xp(next_xp)
            end
        elseif dy ~= 0 then
            local new_xp = self:_xp_line_jump(self.ww_word.pos0, dy)
            if new_xp and new_xp ~= self.ww_word.pos0 then
                self.ww_word = self:_ww_word_from_xp(new_xp)
            end
        end
    else
        if dx ~= 0 then
            local cur = self.ww_extend_pos0
            local next_xp = dx < 0
                and doc:getPrevVisibleWordStart(cur)
                or  doc:getNextVisibleWordStart(cur)
            if next_xp and next_xp ~= cur and doc:isXPointerInCurrentPage(next_xp) then
                self.ww_extend_pos0 = next_xp
            end
        elseif dy ~= 0 then
            local new_xp = self:_xp_line_jump(self.ww_extend_pos0, dy)
            if new_xp and new_xp ~= self.ww_extend_pos0 then
                self.ww_extend_pos0 = new_xp
            end
        end
    end
    self:_refresh()
end

function SelectorOverlay:_extend_struct_sent(dx, dy)
    if not self.sel_sent or not self.sel_tail then return end
    if self.extend_side == "right" then
        if dx ~= 0 then
            local new = self.sel_tail + dx
            if new >= self.sel_sent and new <= #self.sentences then
                self.sel_tail = new; self:_refresh()
            end
        elseif dy ~= 0 then
            local cur_para = self.sentences[self.sel_tail]
                and self.sentences[self.sel_tail].para
            if dy > 0 then
                for j = self.sel_tail + 1, #self.sentences do
                    if self.sentences[j].para ~= cur_para then
                        self.sel_tail = j; self:_refresh(); return
                    end
                end
            else
                local j = self.sel_tail - 1
                while j >= self.sel_sent and self.sentences[j].para == cur_para do
                    j = j - 1
                end
                if j >= self.sel_sent then
                    self.sel_tail = j; self:_refresh()
                end
            end
        end
    else
        if dx ~= 0 then
            local new = self.sel_sent + dx
            if new >= 1 and new <= self.sel_tail then
                self.sel_sent = new; self:_refresh()
            end
        elseif dy ~= 0 then
            local cur_para = self.sentences[self.sel_sent]
                and self.sentences[self.sel_sent].para
            if dy < 0 then
                local j = self.sel_sent - 1
                while j >= 1 and self.sentences[j].para == cur_para do
                    j = j - 1
                end
                if j >= 1 then
                    local prev_para = self.sentences[j].para
                    while j > 1 and self.sentences[j-1].para == prev_para do
                        j = j - 1
                    end
                    self.sel_sent = j; self:_refresh()
                end
            else
                for j = self.sel_sent + 1, self.sel_tail do
                    if self.sentences[j].para ~= cur_para then
                        self.sel_sent = j; self:_refresh(); return
                    end
                end
            end
        end
    end
end

function SelectorOverlay:_extend_struct_word(dx, dy)
    local sent = self.sentences[self.sel_sent]
    if not sent or not sent.word_list then return end
    local n = #sent.word_list
    if self.extend_side == "right" then
        if dx ~= 0 then
            local new = (self.sel_word_tail or self.sel_word) + dx
            if new >= self.sel_word and new <= n then
                self.sel_word_tail = new; self:_refresh()
            end
        elseif dy ~= 0 then
            local cur = self.sel_word_tail or self.sel_word
            local target = self:_word_line_jump(sent.word_list, cur, dy)
            if target and target >= self.sel_word then
                self.sel_word_tail = target; self:_refresh()
            end
        end
    else
        if dx ~= 0 then
            local new = self.sel_word + dx
            if new >= 1 and new <= (self.sel_word_tail or self.sel_word) then
                self.sel_word = new; self:_refresh()
            end
        elseif dy ~= 0 then
            local target = self:_word_line_jump(sent.word_list, self.sel_word, dy)
            if target and target <= (self.sel_word_tail or self.sel_word) then
                self.sel_word = target; self:_refresh()
            end
        end
    end
end

function SelectorOverlay:_word_line_jump(word_list, cur_idx, delta)
    local cur_w = word_list[cur_idx]
    if not cur_w or not cur_w.sbox then return nil end
    local cx = cur_w.sbox.x + cur_w.sbox.w / 2
    local cy = cur_w.sbox.y + cur_w.sbox.h / 2
    local lh = cur_w.sbox.h
    local best, best_dist = nil, math.huge
    for i, w in ipairs(word_list) do
        if w.sbox then
            local wy = w.sbox.y + w.sbox.h / 2
            if (delta > 0 and wy > cy + lh * 0.5) or
               (delta < 0 and wy < cy - lh * 0.5) then
                local d = math.abs(wy - (cy + delta * lh)) * 2
                        + math.abs(w.sbox.x + w.sbox.w/2 - cx)
                if d < best_dist then best = i; best_dist = d end
            end
        end
    end
    return best
end

function SelectorOverlay:_xp_line_jump(xp, delta)
    local doc = self.doc
    local sy = doc:getScreenPositionFromXPointer(xp)
    if not sy then return xp end
    local end_xp = doc:getNextVisibleWordEnd(xp)
    if not end_xp then return xp end
    local ok, boxes = pcall(function()
        return doc:getScreenBoxesFromPositions(xp, end_xp, true)
    end)
    if not ok or not boxes or #boxes == 0 then return xp end
    local line_h = boxes[1].h
    local line_tol = line_h * 0.3
    local target_x = boxes[1].x

    local current_xp = xp
    local target_line_y, fallback_xp = nil, nil
    for _ = 1, 80 do
        local next_xp = delta > 0
            and doc:getNextVisibleWordStart(current_xp)
            or  doc:getPrevVisibleWordStart(current_xp)
        if not next_xp or next_xp == current_xp then break end
        if not doc:isXPointerInCurrentPage(next_xp) then break end
        current_xp = next_xp
        local ny = doc:getScreenPositionFromXPointer(next_xp)
        if not ny then break end
        if (delta > 0 and ny > sy + line_tol)
            or (delta < 0 and ny < sy - line_tol) then
            target_line_y = ny; fallback_xp = next_xp; break
        end
    end
    if not fallback_xp then return xp end
    local ok2, probe = pcall(function()
        return doc:getWordFromPosition({x = target_x, y = target_line_y}, true)
    end)
    if ok2 and probe and probe.pos0 then return probe.pos0 end
    return fallback_xp
end

function SelectorOverlay:quick_extend_right()
    if self.mode == "walk" then
        if not self.ww_word then return end
        if not self.ww_extend_pos0 then
            self.ww_extend_pos0 = self.ww_word.pos0
        end
        local doc = self.doc
        local next_xp = doc:getNextVisibleWordStart(self.ww_word.pos0)
        if next_xp and next_xp ~= self.ww_word.pos0
            and doc:isXPointerInCurrentPage(next_xp) then
            self.ww_word = self:_ww_word_from_xp(next_xp)
        end
    elseif self.mode == "struct" then
        if self.sel_word then
            local sent = self.sentences[self.sel_sent]
            if sent and sent.word_list then
                local new = (self.sel_word_tail or self.sel_word) + 1
                if new <= #sent.word_list then self.sel_word_tail = new end
            end
        else
            local new = (self.sel_tail or self.sel_sent) + 1
            if new <= #self.sentences then self.sel_tail = new end
        end
    end
    self:_refresh()
end

function SelectorOverlay:quick_extend_left()
    if self.mode == "walk" then
        if not self.ww_word then return end
        if not self.ww_extend_pos0 then
            self.ww_extend_pos0 = self.ww_word.pos0
        end
        local doc = self.doc
        local prev_xp = doc:getPrevVisibleWordStart(self.ww_extend_pos0)
        if prev_xp and prev_xp ~= self.ww_extend_pos0
            and doc:isXPointerInCurrentPage(prev_xp) then
            self.ww_extend_pos0 = prev_xp
        end
    elseif self.mode == "struct" then
        if self.sel_word then
            local new = self.sel_word - 1
            if new >= 1 then self.sel_word = new end
        else
            local new = self.sel_sent - 1
            if new >= 1 then self.sel_sent = new end
        end
    end
    self:_refresh()
end

----------------------------------------------------------------------
-- Confirm / mode transitions
----------------------------------------------------------------------

function SelectorOverlay:confirm()
    if self.mode == "cross" then
        self.mode = "struct"
        self.sel_sent = self.cursor_sent or 1
        self.sel_word = nil
        if self.cursor_word and self.sel_sent then
            local sent = self.sentences[self.sel_sent]
            if sent and sent.word_list then
                local target_xp = self.words[self.cursor_word] and self.words[self.cursor_word].xp0
                for wi, witem in ipairs(sent.word_list) do
                    if witem.xp0 == target_xp then
                        self.sel_word = wi; break
                    end
                end
            end
        end
        self:_refresh()
    else
        self:action_menu()
    end
end

function SelectorOverlay:to_crosshair()
    self.mode = "cross"
    self.sel_word = nil
    self:_refresh()
end

----------------------------------------------------------------------
-- Action menu (Y button or A in struct mode)
----------------------------------------------------------------------

function SelectorOverlay:action_menu()
    if self.mode ~= "struct" and self.mode ~= "walk" then return end
    local sel = self:_get_selection()
    if not sel then return end

    local ButtonDialog = require("ui/widget/buttondialog")
    local overlay = self

    local dlg
    dlg = ButtonDialog:new{
        buttons = {
            {
                {
                    text = _("Dictionary"),
                    callback = function()
                        UIManager:close(dlg)
                        overlay:_do_dict(sel)
                    end,
                },
                {
                    text = _("Copy"),
                    callback = function()
                        UIManager:close(dlg)
                        overlay:_do_copy(sel)
                    end,
                },
            },
            {
                {
                    text = _("Highlight"),
                    callback = function()
                        UIManager:close(dlg)
                        overlay:_do_highlight(sel)
                    end,
                },
                {
                    text = _("Note"),
                    callback = function()
                        UIManager:close(dlg)
                        overlay:_do_note(sel)
                    end,
                },
            },
            {
                {
                    text = _("AI explain"),
                    callback = function()
                        UIManager:close(dlg)
                        overlay:_do_ai(sel)
                    end,
                },
                {
                    text = _("Vortuyo"),
                    callback = function()
                        UIManager:close(dlg)
                        overlay:_do_vortuyo(sel)
                    end,
                },
            },
        },
    }
    UIManager:show(dlg)
end

----------------------------------------------------------------------
-- Selection helpers
----------------------------------------------------------------------

function SelectorOverlay:_get_selection()
    if self.hl_cur > 0 and self.hl_items[self.hl_cur] then
        local item = self.hl_items[self.hl_cur]
        local ann = item.ann
        local ok, text = pcall(function()
            return self.doc:getTextFromXPointers(ann.pos0, ann.pos1)
        end)
        return { text = (ok and text) or "", pos0 = ann.pos0, pos1 = ann.pos1,
                 sboxes = item.boxes }
    end
    if self.mode == "cross" then
        if not self.cursor_word then return nil end
        local w = self.words[self.cursor_word]
        if not w then return nil end
        local ok, text = pcall(function()
            return self.doc:getTextFromXPointers(w.xp0, w.xp1)
        end)
        if not ok or not text or text == "" then return nil end
        local ok2, boxes = pcall(function()
            return self.doc:getScreenBoxesFromPositions(w.xp0, w.xp1, true)
        end)
        return { text = text, pos0 = w.xp0, pos1 = w.xp1,
                 sboxes = ok2 and boxes or nil }
    end
    if self.mode == "walk" then
        if not self.ww_word then return nil end
        local w = self.ww_word
        local p0 = self.ww_extend_pos0 or w.pos0
        local ok, text = pcall(function()
            return self.doc:getTextFromXPointers(p0, w.pos1)
        end)
        if not ok or not text or text == "" then text = w.word end
        local ok2, boxes = pcall(function()
            return self.doc:getScreenBoxesFromPositions(p0, w.pos1, true)
        end)
        return { text = text, pos0 = p0, pos1 = w.pos1,
                 sboxes = ok2 and boxes or nil }
    end
    if not self.sel_sent then return nil end
    local head = self.sentences[self.sel_sent]
    local tail_idx = self.sel_tail or self.sel_sent
    local tail = self.sentences[tail_idx]
    if not head or not tail then return nil end

    local xp0, xp1
    if self.sel_word and head.word_list and head.word_list[self.sel_word] then
        local wh = head.word_list[self.sel_word]
        local wt_idx = self.sel_word_tail or self.sel_word
        local wt = head.word_list[wt_idx] or wh
        xp0 = wh.xp0
        xp1 = wt.next_xp0 or wt.xp1
    else
        xp0 = head.xp0
        xp1 = tail.xp1
    end

    local ok, text = pcall(function()
        return self.doc:getTextFromXPointers(xp0, xp1)
    end)
    if not ok or not text or text == "" then return nil end
    local ok2, boxes = pcall(function()
        return self.doc:getScreenBoxesFromPositions(xp0, xp1, true)
    end)
    return { text = text, pos0 = xp0, pos1 = xp1,
             sboxes = ok2 and boxes or nil }
end

----------------------------------------------------------------------
-- Actions
----------------------------------------------------------------------

function SelectorOverlay:_do_dict(sel)
    local word = util.cleanupSelectedText(sel.text)
    if word == "" then return end
    local dict = self.ui.dictionary
    if not dict then return end
    dict:onLookupWord(word, false, sel.sboxes, self.ui.highlight)
    self:_hook_dict_widget(sel)
end

-- Inject gamepad handlers onto the DictQuickLookup widget after it is shown.
-- This bypasses the modal-stack routing problem: the dict consumes key events
-- before active_widgets (PadNav) see them, so we patch the widget directly.
function SelectorOverlay:_hook_dict_widget(sel)
    local stack = UIManager._window_stack
    if not stack then return end
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if w and w.name == "DictQuickLookup" then
            if not w.key_events then w.key_events = {} end
            local overlay = self

            -- Y → AI explain (close dict first so AI viewer can open)
            w.key_events.KopadDictAI = { { "ContextMenu" } }
            function w:onKopadDictAI()
                local s = overlay:_get_selection()
                UIManager:close(self)
                if s then overlay:_do_ai(s) end
                return true
            end

            -- RB → next dictionary result
            w.key_events.KopadDictNext = { { "RPgFwd" } }
            function w:onKopadDictNext()
                if self.onSwipe then self:onSwipe(nil, { direction = "west" }) end
                return true
            end

            -- LB → previous dictionary result
            w.key_events.KopadDictPrev = { { "RPgBack" } }
            function w:onKopadDictPrev()
                if self.onSwipe then self:onSwipe(nil, { direction = "east" }) end
                return true
            end

            return
        end
    end
end

function SelectorOverlay:_do_copy(sel)
    if Device.input and Device.input.setClipboardText then
        Device.input.setClipboardText(util.cleanupSelectedText(sel.text))
        UIManager:show(InfoMessage:new{ text = _("Copied"), timeout = 1 })
    end
end

function SelectorOverlay:_do_highlight(sel)
    local rh = self.ui.highlight
    if not rh then return end
    rh.selected_text = sel
    rh:saveHighlight(false)
    rh.selected_text = nil
end

-- X button: add highlight if none exists for this selection, remove if it does.
function SelectorOverlay:_do_toggle_highlight(sel)
    local annots = self.ui.annotation and self.ui.annotation.annotations
    if annots then
        for i, a in ipairs(annots) do
            if a.pos0 == sel.pos0 and a.pos1 == sel.pos1 then
                table.remove(annots, i)
                self.ui:handleEvent(Event:new("AnnotationsModified",
                    { a, nb_highlights_added = -1,
                      nb_notes_added = a.note and -1 or 0 }))
                UIManager:show(InfoMessage:new{ text = _("Highlight removed"), timeout = 1 })
                self:_refresh()
                return
            end
        end
    end
    self:_do_highlight(sel)
end

function SelectorOverlay:_do_note(sel)
    local rh = self.ui.highlight
    if not rh then return end
    rh.selected_text = sel
    local ok, index = pcall(rh.saveHighlight, rh, true)
    rh.selected_text = nil
    if not ok or not index then return end
    local ui = self.ui
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = _("Note"),
        input = "",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dlg) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local note = dlg:getInputText()
                    UIManager:close(dlg)
                    if note == "" then return end
                    local a = ui.annotation.annotations[index]
                    if a then
                        a.note = note
                        ui:handleEvent(Event:new("AnnotationsModified",
                            { a, nb_highlights_added = -1, nb_notes_added = 1 }))
                    end
                end,
            },
        }},
    }
    UIManager:show(dlg)
end

function SelectorOverlay:_do_ai(sel)
    local text = util.cleanupSelectedText(sel.text)
    if text == "" then return end
    local assistant = self.ui and self.ui.assistant
    if not assistant or not assistant.querier then
        UIManager:show(InfoMessage:new{ text = _("AI not available"), timeout = 2 })
        return
    end
    local ok_v, ChatGPTViewer = pcall(require, "assistant_viewer")
    if not ok_v then return end

    local passage = sel.text
    if self.words and #self.words > 0 then
        local ok_p, p = pcall(function()
            return self.doc:getTextFromXPointers(
                self.words[1].xp0, self.words[#self.words].xp1)
        end)
        if ok_p and p and p ~= "" then passage = p end
    end

    local lang = assistant.ui_language or "English"
    local messages = {
        { role = "system",
          content = "You are a concise literary assistant. Be brief and direct." },
        { role = "user",
          content = "Briefly explain this passage. Note difficult words. Answer in "
                 .. lang .. ". 2-4 sentences.\n\nPassage:\n" .. passage },
    }

    local ui = self.ui
    local NetworkMgr = require("ui/network/manager")
    local Trapper    = require("ui/trapper")
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local ret, err = assistant.querier:query(messages, _("Looking up..."))
            if err then assistant.querier:showError(err); return end
            UIManager:show(ChatGPTViewer:new{
                assistant = assistant, ui = ui,
                title = _("AI"), text = (ret or ""),
            })
        end)
    end)
end

function SelectorOverlay:_do_vortuyo(sel)
    local word = util.cleanupSelectedText(sel.text)
    if word == "" then return end
    local vortuyo = self.ui and self.ui.vortuyo
    if not vortuyo then
        UIManager:show(InfoMessage:new{ text = _("Vortuyo not available"), timeout = 2 })
        return
    end
    vortuyo:_vortuyoLookup(word)
end

----------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------

function SelectorOverlay:paintTo(bb, x, y)
    if self.mode == "cross" then
        self:_draw_crosshair(bb, x, y)
    elseif self.mode == "walk" then
        self:_draw_walk(bb, x, y)
    else
        self:_draw_struct(bb, x, y)
        self:_draw_labels(bb, x, y)
        self:_draw_hl_labels(bb, x, y)
    end
    self:_draw_status(bb, x, y)
end

function SelectorOverlay:_draw_walk(bb, ox, oy)
    if self.ww_extend_pos0 and self.ww_word then
        local ok, boxes = pcall(function()
            return self.doc:getScreenBoxesFromPositions(
                self.ww_extend_pos0, self.ww_word.pos1, true)
        end)
        if ok and boxes then
            for _, b in ipairs(boxes) do
                invert_rounded_rect(bb, ox, oy, b.x, b.y, b.w, b.h)
            end
        end
        return
    end
    local s = self:_ww_fragment_sbox()
    if not s then return end
    invert_rounded_rect(bb, ox, oy, s.x, s.y, s.w, s.h)
end

function SelectorOverlay:_draw_crosshair(bb, ox, oy)
    if not self.cursor_word then return end
    local w = self.words[self.cursor_word]
    if not w or not w.sbox then return end

    invert_rounded_rect(bb, ox, oy, w.sbox.x, w.sbox.y, w.sbox.w, w.sbox.h)

    -- crosshair lines with gap around the word
    local cx = ox + w.sbox.x + math.floor(w.sbox.w / 2)
    local cy = oy + w.sbox.y + math.floor(w.sbox.h / 2)
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local gap = math.max(w.sbox.w, w.sbox.h) + 8
    local lw = 2

    if cx - gap > 0 then
        bb:invertRect(ox, cy - 1, cx - gap - ox, lw)
    end
    if cx + gap < sw then
        bb:invertRect(cx + gap, cy - 1, sw - cx - gap, lw)
    end
    if cy - gap > 0 then
        bb:invertRect(cx - 1, oy, lw, cy - gap - oy)
    end
    if cy + gap < sh then
        bb:invertRect(cx - 1, cy + gap, lw, sh - cy - gap)
    end
end

function SelectorOverlay:_draw_struct(bb, ox, oy)
    -- Draw focused highlight if hl_cur is set
    if self.hl_cur > 0 and self.hl_items[self.hl_cur] then
        for _, b in ipairs(self.hl_items[self.hl_cur].boxes) do
            invert_rounded_rect(bb, ox, oy, b.x, b.y, b.w, b.h)
        end
        return
    end

    if not self.sel_sent then return end
    local head = self.sentences[self.sel_sent]
    local tail_idx = self.sel_tail or self.sel_sent
    local tail = self.sentences[tail_idx]
    if not head or not tail then return end

    local ok, boxes = pcall(function()
        return self.doc:getScreenBoxesFromPositions(head.xp0, tail.xp1, true)
    end)

    if self.sel_word then
        if ok and boxes then
            for _, b in ipairs(boxes) do
                bb:paintRect(ox + b.x, oy + b.y + b.h - 2, b.w, 2, Blitbuffer.COLOR_BLACK)
            end
        end
        local sent = self.sentences[self.sel_sent]
        if sent and sent.word_list then
            local wt = self.sel_word_tail or self.sel_word
            for wi = self.sel_word, wt do
                local ww = sent.word_list[wi]
                if ww and ww.sbox then
                    invert_rounded_rect(bb, ox, oy, ww.sbox.x, ww.sbox.y, ww.sbox.w, ww.sbox.h)
                end
            end
        end
    elseif ok and boxes then
        for _, b in ipairs(boxes) do
            invert_rounded_rect(bb, ox, oy, b.x, b.y, b.w, b.h)
        end
    end
end

function SelectorOverlay:_draw_labels(bb, ox, oy)
    if self.sel_word or self.hl_cur > 0 then return end
    local sh = Screen:getHeight()
    local page_left = nil
    for _, sent in ipairs(self.sentences) do
        if sent.sbox and (not page_left or sent.sbox.x < page_left) then
            page_left = sent.sbox.x
        end
    end
    if not page_left or page_left < 8 then return end

    local entries = {}
    for i, sent in ipairs(self.sentences) do
        local sbox = sent.sbox
        if sbox and sbox.y >= 0 and sbox.y < sh then
            local lbl = (#self.sentences > 9 and i < 10) and ("0" .. i) or tostring(i)
            table.insert(entries, {
                idx = i, sbox = sbox, lbl = lbl,
                cy  = oy + sbox.y + math.floor(sbox.h / 2),
            })
        end
    end
    for ei = 2, #entries do
        local prev, cur = entries[ei - 1], entries[ei]
        if math.abs(cur.cy - prev.cy) < prev.sbox.h * 0.6 then
            local off = math.floor(prev.sbox.h * 0.35)
            prev.cy = prev.cy - off
            cur.cy  = cur.cy  + off
        end
    end
    for _, e in ipairs(entries) do
        local active = (e.idx >= (self.sel_sent or 0)
            and e.idx <= (self.sel_tail or self.sel_sent or 0))
        local tw = TextWidget:new{
            text    = e.lbl,
            face    = LABEL_FACE,
            fgcolor = active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
        }
        local sz  = tw:getSize()
        local pad = 4
        local r   = math.min(
            math.floor(math.max(sz.w, sz.h) / 2) + pad,
            math.floor(page_left / 2) - 2)
        if r >= 4 then
            local cx = ox + math.floor(page_left / 2)
            if active then
                bb:paintCircle(cx, e.cy, r, Blitbuffer.COLOR_BLACK, r)
            else
                bb:paintCircle(cx, e.cy, r,     Blitbuffer.COLOR_BLACK, r)
                bb:paintCircle(cx, e.cy, r - 2, Blitbuffer.COLOR_WHITE, r - 2)
            end
            tw:paintTo(bb, cx - math.floor(sz.w / 2), e.cy - math.floor(sz.h / 2))
        end
        tw:free()
    end
end

function SelectorOverlay:_draw_hl_labels(bb, ox, oy)
    if #self.hl_items == 0 then return end
    if self.sel_word then return end
    local sh = Screen:getHeight()
    local sw = Screen:getWidth()
    local page_right = 0
    for _, item in ipairs(self.hl_items) do
        for _, b in ipairs(item.boxes) do
            local edge = b.x + b.w
            if edge > page_right then page_right = edge end
        end
    end
    local margin = sw - page_right
    if margin < 8 then return end

    for i, item in ipairs(self.hl_items) do
        local sbox = item.sbox
        if sbox.y >= 0 and sbox.y < sh then
            local active = (i == self.hl_cur)
            local lbl = (#self.hl_items > 9 and i < 10) and ("0"..i) or tostring(i)
            local tw = TextWidget:new{
                text    = lbl,
                face    = LABEL_FACE,
                fgcolor = active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
            }
            local sz = tw:getSize()
            local r  = math.min(
                math.floor(math.max(sz.w, sz.h) / 2) + 4,
                math.floor(margin / 2) - 2)
            if r >= 4 then
                local cx = ox + page_right + math.floor(margin / 2)
                local cy = oy + sbox.y + math.floor(sbox.h / 2)
                bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_BLACK, r)
                if not active then
                    bb:paintCircle(cx, cy, r - 2, Blitbuffer.COLOR_WHITE, r - 2)
                end
                tw:paintTo(bb, cx - math.floor(sz.w / 2), cy - math.floor(sz.h / 2))
            end
            tw:free()
        end
    end
end

function SelectorOverlay:_draw_status(bb, ox, oy)
    local txt
    if self.mode == "walk" then
        local ext = self.extend_side and (" +" .. self.extend_side:sub(1,1):upper()) or ""
        txt = ("WALK%s \xC2\xB7 Y vort \xC2\xB7 X hl \xC2\xB7 A menu \xC2\xB7 B quit"):format(ext)
    elseif self.mode == "cross" then
        local w = self.cursor_word and self.words[self.cursor_word]
        local word_text = w and w.text or "?"
        if #word_text > 30 then word_text = word_text:sub(1, 27) .. "..." end
        txt = ("CROSS \xC2\xB7 \"%s\" \xC2\xB7 Y vort \xC2\xB7 X hl \xC2\xB7 A struct \xC2\xB7 B quit"):format(word_text)
    elseif self.hl_cur > 0 and self.hl_items[self.hl_cur] then
        local ann = self.hl_items[self.hl_cur].ann
        local note = (ann.note and ann.note ~= "") and " [note]" or ""
        txt = ("HL %d/%d%s \xC2\xB7 X del \xC2\xB7 Y vort \xC2\xB7 A menu \xC2\xB7 B close"):format(
            self.hl_cur, #self.hl_items, note)
    elseif self.sel_word then
        local sent = self.sentences[self.sel_sent]
        local wt = self.sel_word_tail or self.sel_word
        local n_words = sent and sent.word_list and #sent.word_list or 0
        local range = (wt == self.sel_word)
            and tostring(self.sel_word)
            or  (self.sel_word .. "-" .. wt)
        txt = ("WORD %s/%d \xC2\xB7 X hl \xC2\xB7 Y vort \xC2\xB7 A menu \xC2\xB7 B close"):format(
            range, n_words)
    else
        local tail_idx = self.sel_tail or self.sel_sent
        local range
        if tail_idx == self.sel_sent then
            range = tostring(self.sel_sent or 0)
        else
            range = (self.sel_sent or 0) .. "-" .. tail_idx
        end
        local ext = ""
        local hs = self.sentences[self.sel_sent]
        local ts = self.sentences[self.sel_tail or self.sel_sent]
        if hs and hs._extends_before then ext = "\xE2\x86\x91" end
        if ts and ts._extends_after  then ext = ext .. "\xE2\x86\x93" end
        if ext ~= "" then ext = " " .. ext end
        local hl_hint = #self.hl_items > 0 and (" \xC2\xB7 D\xE2\x86\x95 " .. #self.hl_items .. " hl") or ""
        txt = ("SENT %s/%d%s \xC2\xB7 X hl \xC2\xB7 Y vort \xC2\xB7 A menu%s"):format(
            range, #self.sentences, ext, hl_hint)
    end

    local sw      = Screen:getWidth()
    local TOP_PAD = 18
    local BOT_PAD = 7
    local LINE_GAP = 4

    local mode_txt = (txt or ""):match("^(%S+)") or ""
    local rest_txt = (txt or ""):match("^%S+(.*)") or ""
    local segs = { {t=mode_txt, bold=true, italic=true} }
    local buf  = ""
    for i = 1, #rest_txt do
        local c    = rest_txt:sub(i, i)
        local prev = i > 1           and rest_txt:sub(i-1, i-1) or ""
        local nxt  = i < #rest_txt   and rest_txt:sub(i+1, i+1) or ""
        if c:match("[A-Z]") and not prev:match("[a-zA-Z]") and not nxt:match("[a-zA-Z]") then
            if buf ~= "" then table.insert(segs, {t=buf,      bold=false, italic=false}); buf="" end
            table.insert(segs,                   {t=c:lower(), bold=true,  italic=false})
        else
            buf = buf .. c
        end
    end
    if buf ~= "" then table.insert(segs, {t=buf, bold=false, italic=false}) end

    local widgets = {}
    local total_w, total_h = 0, 0
    for _, seg in ipairs(segs) do
        local tw = TextWidget:new{
            text=seg.t, face=STATUS_FACE, bold=seg.bold, italic=seg.italic,
            fgcolor=Blitbuffer.COLOR_BLACK,
        }
        local sz = tw:getSize()
        table.insert(widgets, {tw=tw, w=sz.w, h=sz.h})
        total_w = total_w + sz.w
        if sz.h > total_h then total_h = sz.h end
    end

    local bar_h  = TOP_PAD + total_h + LINE_GAP + 2 + BOT_PAD
    bb:paintRect(ox, oy, sw, bar_h, Blitbuffer.COLOR_WHITE)

    local line_x = ox + math.floor((sw - total_w) / 2)
    local cx     = line_x
    for _, entry in ipairs(widgets) do
        entry.tw:paintTo(bb, cx, oy + TOP_PAD)
        cx = cx + entry.w
        entry.tw:free()
    end

    bb:paintRect(line_x, oy + TOP_PAD + total_h + LINE_GAP, total_w, 2, Blitbuffer.COLOR_BLACK)
end

----------------------------------------------------------------------
-- Selector (controller — key handling, in active_widgets)
----------------------------------------------------------------------

local Selector = InputContainer:extend{
    name        = "kopad_selector",
    overlay     = nil,
    enabled_ref = nil,
}

function Selector:init()
    self.overlay = nil
    self.key_events = {}
end

----------------------------------------------------------------------
-- Open / close (called by padnav)
----------------------------------------------------------------------

function Selector:_open()
    if self.overlay then return end
    if not self.ui or not self.ui.document then return end
    if not self.ui.rolling then return end
    local ok, ov = pcall(SelectorOverlay.new, SelectorOverlay, {
        doc  = self.ui.document,
        ui   = self.ui,
    })
    if not ok then
        UIManager:show(InfoMessage:new{ text = _("kopad error: ") .. tostring(ov) })
        return
    end
    self.overlay = ov
    UIManager:show(ov)
    UIManager:setDirty("all", "ui")
end

function Selector:_open_walk(from_end)
    if self.overlay then return end
    if not self.ui or not self.ui.document then return end
    if not self.ui.rolling then return end
    local ok, ov = pcall(SelectorOverlay.new, SelectorOverlay, {
        doc  = self.ui.document,
        ui   = self.ui,
    })
    if not ok then
        UIManager:show(InfoMessage:new{ text = _("kopad error: ") .. tostring(ov) })
        return
    end
    ov.mode    = "walk"
    if #ov.words > 0 then
        local idx = from_end and #ov.words or 1
        ov.ww_word = ov:_ww_word_from_xp(ov.words[idx].xp0)
    end
    self.overlay = ov
    UIManager:show(ov)
    UIManager:setDirty("all", "ui")
end

function Selector:_close()
    if self.overlay then
        UIManager:close(self.overlay)
        self.overlay = nil
        UIManager:setDirty(self.ui, "ui")
    end
end

function Selector:getMenuItems()
    return {
        {
            text = _("Crosshair selector  [Select]"),
            callback = function() self:_open() end,
        },
    }
end

return Selector

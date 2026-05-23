--[[
Selector — two-layer gamepad text selector for EPUB documents.

Layer 1: Crosshair mode (default when opened)
  D-pad / L-stick moves a crosshair that snaps to the nearest word.
  The containing sentence is softly highlighted.
  A = confirm word → enters structured mode.

Layer 2: Structured mode (after confirming a word)
  Up/Down = move sentence selection
  Left/Right = move word within sentence
  A = action on selection (dictionary / highlight / copy)
  B = back to crosshair mode
  Y = action menu (dictionary, highlight, copy, AI)

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

    self.mode = "cross"  -- "cross" | "struct"

    self.cursor_word = nil   -- index into self.words
    self.cursor_sent = nil   -- index into self.sentences

    self.sel_sent = nil      -- selected sentence index (single / head)
    self.sel_tail = nil      -- sentence tail for multi-sentence selection
    self.sel_word = nil      -- word head index (nil = whole sentence)
    self.sel_word_tail = nil -- word tail for multi-word selection

    self:_collect()
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
    if #self.words > 0 then
        self:_snap_to_center()
    end
    self:_refresh()
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
    if self.mode ~= "struct" then return end
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
            },
        },
    }
    UIManager:show(dlg)
end

----------------------------------------------------------------------
-- Selection helpers
----------------------------------------------------------------------

function SelectorOverlay:_get_selection()
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
    if dict then
        dict:onLookupWord(word, false, sel.sboxes, self.ui.highlight)
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

----------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------

function SelectorOverlay:paintTo(bb, x, y)
    if self.mode == "cross" then
        self:_draw_crosshair(bb, x, y)
    else
        self:_draw_struct(bb, x, y)
    end
    self:_draw_status(bb, x, y)
end

function SelectorOverlay:_draw_crosshair(bb, ox, oy)
    if not self.cursor_word then return end
    local w = self.words[self.cursor_word]
    if not w or not w.sbox then return end

    -- highlight the cursor word
    bb:invertRect(ox + w.sbox.x, oy + w.sbox.y, w.sbox.w, w.sbox.h)

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
    if not self.sel_sent then return end
    local head = self.sentences[self.sel_sent]
    local tail_idx = self.sel_tail or self.sel_sent
    local tail = self.sentences[tail_idx]
    if not head or not tail then return end

    local ok, boxes = pcall(function()
        return self.doc:getScreenBoxesFromPositions(head.xp0, tail.xp1, true)
    end)

    if self.sel_word then
        -- word mode: underline sentence range, invert selected word(s)
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
                    bb:invertRect(ox + ww.sbox.x, oy + ww.sbox.y, ww.sbox.w, ww.sbox.h)
                end
            end
        end
    elseif ok and boxes then
        -- sentence mode: invert whole range
        for _, b in ipairs(boxes) do
            bb:invertRect(ox + b.x, oy + b.y, b.w, b.h)
        end
    end
end

function SelectorOverlay:_draw_status(bb, ox, oy)
    local txt
    if self.mode == "cross" then
        local w = self.cursor_word and self.words[self.cursor_word]
        local word_text = w and w.text or "?"
        if #word_text > 30 then word_text = word_text:sub(1, 27) .. "..." end
        txt = ("CROSS \xC2\xB7 \"%s\" \xC2\xB7 A confirm \xC2\xB7 B quit"):format(word_text)
    elseif self.sel_word then
        local sent = self.sentences[self.sel_sent]
        local wt = self.sel_word_tail or self.sel_word
        local n_words = sent and sent.word_list and #sent.word_list or 0
        local range = (wt == self.sel_word)
            and tostring(self.sel_word)
            or  (self.sel_word .. "-" .. wt)
        local mode = self._rstick_extending and "EXTEND" or "MOVE"
        txt = ("WORD %s/%d [%s] \xC2\xB7 X toggle \xC2\xB7 Y dict \xC2\xB7 A menu \xC2\xB7 B close"):format(
            range, n_words, mode)
    else
        local tail_idx = self.sel_tail or self.sel_sent
        local range
        if tail_idx == self.sel_sent then
            range = tostring(self.sel_sent or 0)
        else
            range = (self.sel_sent or 0) .. "-" .. tail_idx
        end
        local mode = self._lstick_extending and "EXTEND" or "MOVE"
        local ext = ""
        local hs = self.sentences[self.sel_sent]
        local ts = self.sentences[self.sel_tail or self.sel_sent]
        if hs and hs._extends_before then ext = "\xE2\x86\x91" end
        if ts and ts._extends_after  then ext = ext .. "\xE2\x86\x93" end
        if ext ~= "" then ext = " " .. ext end
        txt = ("SENT %s/%d%s [%s] \xC2\xB7 X toggle \xC2\xB7 Y dict \xC2\xB7 A menu \xC2\xB7 B close"):format(
            range, #self.sentences, ext, mode)
    end

    local tw = TextWidget:new{
        text = txt, face = STATUS_FACE,
        fgcolor = Blitbuffer.COLOR_WHITE,
        max_width = Screen:getWidth() - 16,
    }
    local sz  = tw:getSize()
    local pad = 3
    bb:paintRect(ox, oy, Screen:getWidth(), sz.h + 2 * pad, Blitbuffer.COLOR_BLACK)
    tw:paintTo(bb, ox + 8, oy + pad)
    tw:free()
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

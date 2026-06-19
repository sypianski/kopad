--[[
PadNav — gamepad reading controls for KOReader (active when kopad is enabled).

Reading:
  D-pad                   Open word walk
  R-stick                Open crosshair (immediate)
  A                      Open sentence selector
  Y                      Open highlight mode (crosshair if none)
  LB / RB                Page back / forward
  X + D-pad              Combo: ↑menu ↓footer ←hist →files
  X + LB/RB              Combo: LB=TOC  RB=bookmarks

Selection (struct/walk overlay):
  L-stick ←/→           Sentence move    ↑/↓  Paragraph jump
  D-pad                  Word navigation
  R-stick ↑/↓            Cycle highlights (struct, no word)
  R-stick ←/→            Word navigation
  Y                     Vortuyo lookup
  X                     Toggle highlight
  A                     Action menu (dict, AI, copy, note)
  B                     Close overlay
  RB                    Extend selection
  LB                    Trim selection

Dictionary popup:
  LB / RB               Cycle dictionaries
  Y                     AI explain
]]

local Event          = require("ui/event")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager      = require("ui/uimanager")
local logger         = require("logger")

local RTL_LANGS = { ar=true, he=true, fa=true, ur=true }

local PadNav = InputContainer:extend{
    name        = "kopad_padnav",
    enabled_ref = nil,
}

local SUPPRESS_KEYS = {
    "MoveUp", "MoveDown",
    "GotoNextView", "GotoPrevView",
    "Press",
}

function PadNav:init()
    self.key_events = {
        -- L-stick: separate key names injected by 1-lstick-keys.lua userpatch
        -- Falls back to Up/Down/Left/Right if patch not applied (also covers D-pad until patch confirmed)
        KPUp      = { { "LStickUp" } },
        KPDown    = { { "LStickDown" } },
        KPLeft    = { { "LStickLeft" } },
        KPRight   = { { "LStickRight" } },
        KPUp2     = { { "Up" } },
        KPDown2   = { { "Down" } },
        KPLeft2   = { { "Left" } },
        KPRight2  = { { "Right" } },
        -- D-pad: Up/Down/Left/Right pass through to KOReader (menu nav etc.)

        -- R-stick: word navigation / extend-trim (toggled by R3 click)
        KPRStickUp    = { { "F3" } },
        KPRStickDown  = { { "F4" } },
        KPRStickLeft  = { { "F5" } },
        KPRStickRight = { { "F8" } },
        -- face buttons (accent actions)
        KPExtend  = { { "F10" } },        -- X: toggle extend mode
        -- shoulder buttons: page turn
        KPPgBk    = { { "RPgBack" } },    -- LB
        KPPgFwd   = { { "RPgFwd" } },     -- RB
        KPPgBk2   = { { "LPgBack" } },    -- LT (if available)
        KPPgFwd2  = { { "LPgFwd" } },     -- RT (if available)
        KPPgBk3   = { { "ScrollLock" } }, -- L4 back paddle
        KPPgFwd3  = { { "Pause" } },      -- R4 back paddle
        -- face buttons
        KPConfirm = { { "Press" } },      -- A
        KPBack    = { { "Back" } },       -- B
        KPMenu    = { { "ContextMenu" } }, -- Y
    }

    self._saved_keys = nil

    if self.ui and self.ui.active_widgets then
        table.insert(self.ui.active_widgets, 1, self)
    end

    if self:_is_enabled() then
        self:_suppress_reader_keys()
    end
end

function PadNav:_is_enabled()
    if self.ui and self.ui._kokb_overlay then return false end
    return self.enabled_ref and self.enabled_ref.enabled
end

function PadNav:_suppress_reader_keys()
    if self._saved_keys then return end
    self._saved_keys = {}

    local seen = {}
    local targets = {}
    local function add(mod)
        if mod and mod.key_events and not seen[mod] and mod ~= self then
            seen[mod] = true
            table.insert(targets, mod)
        end
    end

    add(self.ui)
    add(self.ui and self.ui.rolling)
    add(self.ui and self.ui.paging)
    add(self.ui and self.ui.view)
    add(self.ui and self.ui.view and self.ui.view.footer)
    add(self.ui and self.ui.footer)
    add(self.ui and self.ui.highlight)
    add(self.ui and self.ui.bookmark)
    -- scan all active_widgets so nothing slips through
    if self.ui and self.ui.active_widgets then
        for _, w in ipairs(self.ui.active_widgets) do
            add(w)
        end
    end

    for _, mod in ipairs(targets) do
        self._saved_keys[mod] = {}
        for _, name in ipairs(SUPPRESS_KEYS) do
            if mod.key_events[name] then
                self._saved_keys[mod][name] = mod.key_events[name]
                mod.key_events[name] = nil
            end
        end
        local to_remove = {}
        for name, binding in pairs(mod.key_events) do
            if type(binding) == "table" and type(binding[1]) == "table" then
                for _, k in ipairs(binding[1]) do
                    if k == "Press" then
                        table.insert(to_remove, name); break
                    end
                end
            end
        end
        for _, name in ipairs(to_remove) do
            self._saved_keys[mod][name] = mod.key_events[name]
            mod.key_events[name] = nil
        end
    end
end

function PadNav:restore_reader_keys()
    if not self._saved_keys then return end
    for mod, keys in pairs(self._saved_keys) do
        if mod and mod.key_events then
            for name, binding in pairs(keys) do
                mod.key_events[name] = binding
            end
        end
    end
    self._saved_keys = nil
end

function PadNav:_selector()
    return self.enabled_ref and self.enabled_ref.subs
        and self.enabled_ref.subs.selector
end

function PadNav:_is_rtl()
    if not self.ui or not self.ui.document then return false end
    local ok, props = pcall(function() return self.ui.document:getProps() end)
    if not ok then return false end
    local lang_raw = (props and props.language) or ""
    local lang_base = lang_raw:lower():match("^([a-z]+)") or ""
    return RTL_LANGS[lang_base] or false
end

function PadNav:_find_dict_widget()
    local stack = UIManager._window_stack
    if not stack then return nil end
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if w and w.name == "DictQuickLookup" then return w end
    end
    return nil
end


function PadNav:_lstick_dir(dx, dy)
    if self:_is_rtl() then dx = -dx end
    local selector = self:_selector()
    if not selector then return end
    if not selector.overlay then
        self:_open_sentence_select(1)
        return
    end
    local ov = selector.overlay
    if ov.mode == "walk" then return end
    if ov.mode ~= "struct" then
        ov.mode = "struct"; ov.sel_sent = 1; ov.sel_tail = 1; ov.sel_word = nil
        ov:_refresh(); return
    end

    ov.hl_cur = 0
    if dy ~= 0 then
        -- ↑↓: paragraph jump
        local cur_para = ov.sentences[ov.sel_sent] and ov.sentences[ov.sel_sent].para
        if dy > 0 then
            for j = ov.sel_sent + 1, #ov.sentences do
                if ov.sentences[j].para ~= cur_para then
                    ov.sel_sent = j; ov.sel_tail = j; ov.sel_word = nil
                    ov:_refresh(); return
                end
            end
        else
            local j = ov.sel_sent - 1
            while j >= 1 and ov.sentences[j].para == cur_para do j = j - 1 end
            if j >= 1 then
                local prev_para = ov.sentences[j].para
                while j > 1 and ov.sentences[j - 1].para == prev_para do j = j - 1 end
                ov.sel_sent = j; ov.sel_tail = j; ov.sel_word = nil
                ov:_refresh()
            end
        end
    else
        -- ←→: move sentence
        local new = ov.sel_sent + dx
        if new >= 1 and new <= #ov.sentences then
            ov.sel_sent = new; ov.sel_tail = new; ov.sel_word = nil
            ov:_refresh()
        end
    end
end

function PadNav:onKPUp()
    if not self:_is_enabled() then return false end
    local selector = self:_selector()
    if selector and selector.overlay then
        if selector.overlay.mode == "walk" then
            self.ui:handleEvent(Event:new("GotoViewRel", 1)); return true
        end
        if selector.overlay.mode == "cross" then
            selector.overlay:_cross_move(0, -1); return true
        end
        self:_lstick_dir(0, -1); return true
    end
    self.ui:handleEvent(Event:new("GotoViewRel", 1)); return true
end
function PadNav:onKPDown()
    if not self:_is_enabled() then return false end
    local selector = self:_selector()
    if selector and selector.overlay then
        if selector.overlay.mode == "walk" then
            self.ui:handleEvent(Event:new("GotoViewRel", -1)); return true
        end
        if selector.overlay.mode == "cross" then
            selector.overlay:_cross_move(0, 1); return true
        end
        self:_lstick_dir(0, 1); return true
    end
    if selector then selector:_open() end
    return true
end
function PadNav:onKPLeft()
    if not self:_is_enabled() then return false end
    local selector = self:_selector()
    if selector and selector.overlay then
        if selector.overlay.mode == "walk" then
            self.ui:handleEvent(Event:new("GotoViewRel", 1)); return true
        end
        if selector.overlay.mode == "cross" then
            selector.overlay:_cross_move(-1, 0); return true
        end
        self:_lstick_dir(-1, 0); return true
    end
    self.ui:handleEvent(Event:new("GotoViewRel", 1)); return true
end
function PadNav:onKPRight()
    if not self:_is_enabled() then return false end
    local selector = self:_selector()
    if selector and selector.overlay then
        if selector.overlay.mode == "walk" then
            self.ui:handleEvent(Event:new("GotoViewRel", -1)); return true
        end
        if selector.overlay.mode == "cross" then
            selector.overlay:_cross_move(1, 0); return true
        end
        self:_lstick_dir(1, 0); return true
    end
    self:_rstick_dir(1, 0); return true
end

-- D-pad: X-mode combos (reading) or word walk (overlay / normal)
function PadNav:_x_combo(action_fn)
    self._x_mode = false
    action_fn()
end

function PadNav:_dpad(dx, dy)
    local selector = self:_selector()
    if selector and selector.overlay then
        if selector.overlay.extend_side then
            if self:_is_rtl() then dx = -dx end
            selector.overlay:extend_dpad(dx, dy); return
        end
        if selector.overlay.mode == "walk" then
            self:_rstick_dir(dx, dy); return
        end
        if selector.overlay.mode == "struct" and not selector.overlay.sel_word then
            self:_lstick_dir(dx, dy); return
        end
        self:_rstick_dir(dx, dy); return
    end
    if not selector then return end
    selector:_open_walk(dy < 0 or dx < 0)
end

function PadNav:onKPUp2()
    if not self:_is_enabled() then return false end
    if self._x_mode then
        self:_x_combo(function() self.ui:handleEvent(Event:new("ShowMenu")) end)
        return true
    end
    self:_dpad(0, -1); return true
end
function PadNav:onKPDown2()
    if not self:_is_enabled() then return false end
    if self._x_mode then
        self:_x_combo(function()
            local footer = self.ui.view and self.ui.view.footer
            if footer then footer:onToggleFooterMode() end
        end)
        return true
    end
    self:_dpad(0, 1); return true
end
function PadNav:onKPLeft2()
    if not self:_is_enabled() then return false end
    if self._x_mode then
        self:_x_combo(function() self.ui:handleEvent(Event:new("ShowHist")) end)
        return true
    end
    self:_dpad(-1, 0); return true
end
function PadNav:onKPRight2()
    if not self:_is_enabled() then return false end
    if self._x_mode then
        self:_x_combo(function() self.ui:handleEvent(Event:new("Home")) end)
        return true
    end
    self:_dpad(1, 0); return true
end

-- Sentence selection: open overlay, navigate, extend/trim
function PadNav:_open_sentence_select(start_idx)
    local selector = self:_selector()
    if not selector then return end
    if not selector.overlay then
        selector:_open()
        if not selector.overlay then return end
        selector.overlay.mode = "struct"
        selector.overlay.sel_sent = start_idx or 1
        selector.overlay.sel_tail = selector.overlay.sel_sent
        selector.overlay.sel_word = nil
        selector.overlay:_refresh()
    end
end

function PadNav:_sent_move(dy)
    local selector = self:_selector()
    if not selector then return end
    if not selector.overlay then
        self:_open_sentence_select(1)
        return
    end
    local ov = selector.overlay
    if ov.mode ~= "struct" then
        ov.mode = "struct"; ov.sel_sent = 1; ov.sel_tail = 1; ov.sel_word = nil
        ov:_refresh(); return
    end
    local new = (ov.sel_sent or 1) + dy
    if new >= 1 and new <= #ov.sentences then
        ov.sel_sent = new; ov.sel_tail = new; ov.sel_word = nil
        ov:_refresh()
    end
end

function PadNav:_sent_extend()
    local selector = self:_selector()
    if not selector or not selector.overlay then return end
    local ov = selector.overlay
    if ov.mode ~= "struct" then return end
    local new_tail = (ov.sel_tail or ov.sel_sent) + 1
    if new_tail <= #ov.sentences then
        ov.sel_tail = new_tail; ov.sel_word = nil
        ov:_refresh()
    end
end

function PadNav:_sent_trim()
    local selector = self:_selector()
    if not selector or not selector.overlay then return end
    local ov = selector.overlay
    if ov.mode ~= "struct" then return end
    local new_tail = (ov.sel_tail or ov.sel_sent) - 1
    if new_tail >= ov.sel_sent then
        ov.sel_tail = new_tail; ov.sel_word = nil
        ov:_refresh()
    end
end

-- R-stick: immediate crosshair — opens crosshair if needed, moves cursor in any mode
function PadNav:_cross_dir(dx, dy)
    if self:_is_rtl() then dx = -dx end
    local selector = self:_selector()
    if not selector then return end
    if not selector.overlay then
        selector:_open()
        if not selector.overlay then return end
    end
    local ov = selector.overlay
    if ov.extend_side then ov:exit_extend() end
    if ov.mode == "cross" then
        ov:_cross_move(dx, dy)
    elseif ov.mode == "walk" then
        if dx ~= 0 then ov:_ww_move(dx) end
        if dy ~= 0 then ov:_ww_line(dy) end
    elseif ov.mode == "struct" then
        -- in struct: HL cycling (↑↓ no word) or word nav
        if not ov.sel_word and #ov.hl_items > 0 and dy ~= 0 then
            if dy > 0 then
                ov.hl_cur = (ov.hl_cur < #ov.hl_items) and ov.hl_cur + 1 or 1
            else
                ov.hl_cur = (ov.hl_cur > 1) and ov.hl_cur - 1 or #ov.hl_items
            end
            ov:_refresh()
        else
            self:_rstick_dir(dx, dy)
        end
    end
end

-- D-pad word handling: walk mode (no overlay) or word-within-sentence (struct)
function PadNav:_rstick_dir(dx, dy)
    if self:_is_rtl() then dx = -dx end
    local selector = self:_selector()
    if not selector then return end
    if not selector.overlay then
        selector:_open_walk()
        if not selector.overlay then return end
    end
    local ov = selector.overlay
    if ov.mode == "walk" then
        if dx ~= 0 then ov:_ww_move(dx) end
        if dy ~= 0 then ov:_ww_line(dy) end
        return
    end
    if ov.mode == "cross" then
        ov:_cross_move(dx, dy); return
    end
    if ov.mode ~= "struct" then return end
    local sent = ov.sentences[ov.sel_sent]
    if not sent or not sent.word_list or #sent.word_list == 0 then return end

    ov.hl_cur = 0
    if not ov.sel_word then
        ov.sel_word = 1
        ov.sel_word_tail = 1
        ov:_refresh()
        return
    end

    local delta
    if dx ~= 0 then
        delta = dx
    else
        local cur_w = sent.word_list[ov.sel_word]
        if cur_w and cur_w.sbox then
            local cx = cur_w.sbox.x + cur_w.sbox.w / 2
            local cy = cur_w.sbox.y + cur_w.sbox.h / 2
            local lh = cur_w.sbox.h
            local best, best_dist = ov.sel_word, math.huge
            for i, w in ipairs(sent.word_list) do
                if w.sbox then
                    local wy = w.sbox.y + w.sbox.h / 2
                    if (dy > 0 and wy > cy + lh * 0.5) or
                       (dy < 0 and wy < cy - lh * 0.5) then
                        local d = math.abs(wy - (cy + dy * lh)) * 2
                                + math.abs(w.sbox.x + w.sbox.w/2 - cx)
                        if d < best_dist then best = i; best_dist = d end
                    end
                end
            end
            ov.sel_word = best
            ov.sel_word_tail = best
            ov:_refresh()
            return
        end
        delta = dy
    end
    local new = ov.sel_word + delta
    if new >= 1 and new <= #sent.word_list then
        ov.sel_word = new
        ov.sel_word_tail = new
    end
    ov:_refresh()
end

function PadNav:onKPRStickUp()
    if not self:_is_enabled() then return false end
    self:_cross_dir(0, -1); return true
end
function PadNav:onKPRStickDown()
    if not self:_is_enabled() then return false end
    self:_cross_dir(0, 1); return true
end
function PadNav:onKPRStickLeft()
    if not self:_is_enabled() then return false end
    self:_cross_dir(-1, 0); return true
end
function PadNav:onKPRStickRight()
    if not self:_is_enabled() then return false end
    self:_cross_dir(1, 0); return true
end

-- X: highlight toggle (overlay) or combo modifier (reading)
function PadNav:onKPExtend()
    if not self:_is_enabled() then return false end
    local selector = self:_selector()
    if selector and selector.overlay then
        if selector.overlay.extend_side then selector.overlay:exit_extend() end
        local sel = selector.overlay:_get_selection()
        if sel then selector.overlay:_do_toggle_highlight(sel) end
        return true
    end
    self._x_mode = not self._x_mode
    return true
end

-- RB: X+RB=bm, enter/quick extend right (overlay), page forward (reading)
function PadNav:onKPPgFwd()
    if not self:_is_enabled() then return false end
    if self._x_mode then
        self:_x_combo(function() self.ui:handleEvent(Event:new("ShowBookmark")) end)
        return true
    end
    local dict_w = self:_find_dict_widget()
    if dict_w then
        dict_w:handleEvent(Event:new("Swipe", nil, {direction = "west"}))
        return true
    end
    local selector = self:_selector()
    if selector and selector.overlay
        and (selector.overlay.mode == "struct" or selector.overlay.mode == "walk") then
        local ov = selector.overlay
        if ov.extend_side == "right" then
            ov:quick_extend_right()
        elseif ov.extend_side == "left" then
            ov.extend_side = "right"; ov:_refresh()
        else
            ov:enter_extend("right")
        end
        return true
    end
    self.ui:handleEvent(Event:new("GotoViewRel", -1)); return true
end

-- LB: X+LB=TOC, enter/quick extend left (overlay), page back (reading)
function PadNav:onKPPgBk()
    if not self:_is_enabled() then return false end
    if self._x_mode then
        self:_x_combo(function() self.ui:handleEvent(Event:new("ShowToc")) end)
        return true
    end
    local dict_w = self:_find_dict_widget()
    if dict_w then
        dict_w:handleEvent(Event:new("Swipe", nil, {direction = "east"}))
        return true
    end
    local selector = self:_selector()
    if selector and selector.overlay
        and (selector.overlay.mode == "struct" or selector.overlay.mode == "walk") then
        local ov = selector.overlay
        if ov.extend_side == "left" then
            ov:quick_extend_left()
        elseif ov.extend_side == "right" then
            ov.extend_side = "left"; ov:_refresh()
        else
            ov:enter_extend("left")
        end
        return true
    end
    self.ui:handleEvent(Event:new("GotoViewRel", 1)); return true
end

function PadNav:onKPPgBk2()  return self:onKPPgBk()  end
function PadNav:onKPPgFwd2() return self:onKPPgFwd() end
function PadNav:onKPPgBk3()  return self:onKPPgBk()  end
function PadNav:onKPPgFwd3() return self:onKPPgFwd() end

-- A: sentence selection (reading), confirm/action menu (overlay)
function PadNav:onKPConfirm()
    if not self:_is_enabled() then return false end

    local selector = self:_selector()
    if selector and selector.overlay then
        selector.overlay:confirm()
        return true
    end
    self:_open_sentence_select(1)
    return true
end

-- B: exit extend mode, or close overlay
function PadNav:onKPBack()
    if not self:_is_enabled() then return false end

    local selector = self:_selector()
    if selector and selector.overlay then
        if selector.overlay.extend_side then
            selector.overlay:exit_extend()
            return true
        end
        selector:_close()
        return true
    end
    return false
end

-- Y: Vortuyo (overlay) or highlight mode / crosshair fallback (reading)
-- When dict is open, Y→AI is handled by _hook_dict_widget on the dict widget itself.
function PadNav:onKPMenu()
    if not self:_is_enabled() then return false end

    local selector = self:_selector()
    if selector and selector.overlay then
        if selector.overlay.extend_side then selector.overlay:exit_extend() end
        local sel = selector.overlay:_get_selection()
        if sel then
            selector.overlay:_do_vortuyo(sel)
            return true
        end
    end

    if not selector then return true end
    selector:_open()
    if not selector.overlay then return true end
    if #selector.overlay.hl_items > 0 then
        selector.overlay.mode = "struct"
        selector.overlay.sel_sent = 1
        selector.overlay.sel_tail = 1
        selector.overlay.sel_word = nil
        selector.overlay.hl_cur = 1
        selector.overlay:_refresh()
    end
    return true
end


function PadNav:getMenuItems()
    return {
        {
            text = _("About kopad"),
            callback = function()
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{
                    text = _("kopad: gamepad control for KOReader.\n\n"
                        .. "Reading:\n"
                        .. "  D-pad: walk  R-stick: crosshair\n"
                        .. "  A: sentence  Y: highlights\n"
                        .. "  LB/RB: page turn\n"
                        .. "  X + D\xE2\x86\x91 menu  X + D\xE2\x86\x93 footer\n"
                        .. "  X + D\xE2\x86\x90 hist  X + D\xE2\x86\x92 files\n"
                        .. "  X + LB TOC  X + RB bookmarks\n\n"
                        .. "Selection:\n"
                        .. "  L-stick: sentence / paragraph\n"
                        .. "  D-pad \xE2\x86\x95: cycle highlights\n"
                        .. "  D-pad / R-stick: word navigation\n"
                        .. "  Y: Vortuyo\n"
                        .. "  X: highlight (toggle)\n"
                        .. "  A: action menu\n"
                        .. "  B: close\n"
                        .. "  RB: extend  \xC2\xB7  LB: trim\n\n"
                        .. "Dictionary:\n"
                        .. "  LB / RB: cycle dictionaries\n"
                        .. "  Y: AI explain"),
                })
            end,
        },
    }
end

return PadNav

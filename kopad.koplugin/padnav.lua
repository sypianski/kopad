--[[
PadNav — gamepad reading controls for KOReader (active when kopad is enabled).

Suppresses default reader key bindings and replaces them with gamepad-optimized ones:
  D-pad Left / Up       Previous page
  D-pad Right / Down    Next page
  Y (ContextMenu)       Open upper menu
  Select (RPgBack)      Open crosshair selector
  R-stick (RPgFwd)      Next page

Keys NOT remapped (KOReader defaults work fine):
  A (Press)             Confirm / tap
  B (Back)              Back / close dialog
  Start (Menu)          Open menu
]]

local Event          = require("ui/event")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager      = require("ui/uimanager")
local logger         = require("logger")

local PadNav = InputContainer:extend{
    name        = "kopad_padnav",
    enabled_ref = nil,
}

local SUPPRESS_KEYS = {
    "MoveUp", "MoveDown",
    "GotoNextView", "GotoPrevView",
}

function PadNav:init()
    self.key_events = {
        -- L-stick: crosshair (analog, pressure-sensitive)
        KPUp      = { { "Up" } },
        KPDown    = { { "Down" } },
        KPLeft    = { { "Left" } },
        KPRight   = { { "Right" } },
        -- D-pad: pass through to KOReader (menu navigation etc.)

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
    local targets = { self.ui and self.ui.rolling, self.ui and self.ui.paging }
    for _, mod in ipairs(targets) do
        if mod and mod.key_events then
            self._saved_keys[mod] = {}
            for _, name in ipairs(SUPPRESS_KEYS) do
                if mod.key_events[name] then
                    self._saved_keys[mod][name] = mod.key_events[name]
                    mod.key_events[name] = nil
                end
            end
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


-- L-stick: move mode (↑↓ = paragraph, ←→ = sentence) vs extend mode (toggled by L3)
function PadNav:_lstick_dir(dx, dy)
    local selector = self:_selector()
    if not selector then return end
    if not selector.overlay then
        self:_open_sentence_select(1)
        return
    end
    local ov = selector.overlay
    if ov.mode ~= "struct" then
        ov.mode = "struct"; ov.sel_sent = 1; ov.sel_tail = 1; ov.sel_word = nil
        ov._lstick_extending = false
        ov:_refresh(); return
    end

    if ov._lstick_extending then
        -- extend/trim: →↓ extend, ←↑ trim
        local delta = dx + dy
        local new_tail = (ov.sel_tail or ov.sel_sent) + delta
        if new_tail >= ov.sel_sent and new_tail <= #ov.sentences then
            ov.sel_tail = new_tail; ov.sel_word = nil
            ov:_refresh()
        end
    else
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
end

function PadNav:onKPUp()
    if not self:_is_enabled() then return false end
    self:_lstick_dir(0, -1); return true
end
function PadNav:onKPDown()
    if not self:_is_enabled() then return false end
    self:_lstick_dir(0, 1); return true
end
function PadNav:onKPLeft()
    if not self:_is_enabled() then return false end
    self:_lstick_dir(-1, 0); return true
end
function PadNav:onKPRight()
    if not self:_is_enabled() then return false end
    self:_lstick_dir(1, 0); return true
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

-- R-stick word handling: move mode vs extend mode (toggled by R3 click)
function PadNav:_rstick_dir(dx, dy)
    local selector = self:_selector()
    if not selector or not selector.overlay then return end
    local ov = selector.overlay
    if ov.mode ~= "struct" then return end
    local sent = ov.sentences[ov.sel_sent]
    if not sent or not sent.word_list or #sent.word_list == 0 then return end

    if not ov.sel_word then
        -- first R-stick input: enter word mode
        ov.sel_word = 1
        ov.sel_word_tail = 1
        ov._rstick_extending = false
        ov:_refresh()
        return
    end

    if ov._rstick_extending then
        -- extend/trim mode: →↓ extend, ←↑ trim
        local delta = dx + dy  -- one of them is 0
        local new_tail = (ov.sel_word_tail or ov.sel_word) + delta
        if new_tail >= ov.sel_word and new_tail <= #sent.word_list then
            ov.sel_word_tail = new_tail
        end
    else
        -- move mode: all directions move the single-word cursor
        local delta
        if dx ~= 0 then
            delta = dx
        else
            -- up/down: jump to word on line above/below (closest x)
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
    end
    ov:_refresh()
end

function PadNav:onKPRStickUp()
    if not self:_is_enabled() then return false end
    self:_rstick_dir(0, -1); return true
end
function PadNav:onKPRStickDown()
    if not self:_is_enabled() then return false end
    self:_rstick_dir(0, 1); return true
end
function PadNav:onKPRStickLeft()
    if not self:_is_enabled() then return false end
    self:_rstick_dir(-1, 0); return true
end
function PadNav:onKPRStickRight()
    if not self:_is_enabled() then return false end
    self:_rstick_dir(1, 0); return true
end

-- X button: toggle extend mode (sentence or word level)
function PadNav:onKPExtend()
    if not self:_is_enabled() then return false end

    local selector = self:_selector()
    if not selector or not selector.overlay then return false end
    local ov = selector.overlay
    if ov.sel_word then
        ov._rstick_extending = not ov._rstick_extending
    else
        ov._lstick_extending = not ov._lstick_extending
    end
    ov:_refresh()
    return true
end

function PadNav:onKPPgFwd()
    if not self:_is_enabled() then return false end

    self.ui:handleEvent(Event:new("GotoViewRel", 1))
    return true
end

function PadNav:onKPPgBk()
    if not self:_is_enabled() then return false end

    self.ui:handleEvent(Event:new("GotoViewRel", -1))
    return true
end

function PadNav:onKPPgBk2()
    return self:onKPPgBk()
end

function PadNav:onKPPgFwd2()
    return self:onKPPgFwd()
end

-- A: action menu (when overlay open)
function PadNav:onKPConfirm()
    if not self:_is_enabled() then return false end

    local selector = self:_selector()
    if selector and selector.overlay then
        selector.overlay:action_menu()
        return true
    end
    return false
end

-- B: cancel / close overlay
function PadNav:onKPBack()
    if not self:_is_enabled() then return false end

    local selector = self:_selector()
    if selector and selector.overlay then
        selector:_close()
        return true
    end
    return false
end

-- Y: dictionary (single word) or AI (multi-word), otherwise open menu
function PadNav:onKPMenu()
    if not self:_is_enabled() then return false end

    local selector = self:_selector()
    if selector and selector.overlay then
        local ov = selector.overlay
        local sel = ov:_get_selection()
        if sel then
            local multi = ov.sel_word and ov.sel_word_tail
                and ov.sel_word_tail > ov.sel_word
            if multi then
                ov:_do_ai(sel)
            else
                ov:_do_dict(sel)
            end
        end
        return true
    end
    self.ui:handleEvent(Event:new("KeyPressShowMenu"))
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
                        .. "  LT / RT: page turn\n"
                        .. "  L-stick: sentence select\n"
                        .. "  R-stick: word select\n"
                        .. "  Y: menu\n\n"
                        .. "Selection:\n"
                        .. "  A: action menu\n"
                        .. "  B: cancel / close\n"
                        .. "  X: toggle extend mode\n"
                        .. "  Y: dictionary lookup"),
                })
            end,
        },
    }
end

return PadNav

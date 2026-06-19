--[[
kopad — gamepad control for KOReader.

When enabled, replaces KOReader's default key bindings with gamepad-optimized ones:

  Reading:
    L-stick ↑/←             Page turn
    L-stick ↓                Open crosshair selector
    L-stick →                Open word walk
    D-pad / R-stick          Word walk (opens walk mode)
    X + D-pad                Combo: menu / footer / bookmarks / TOC
    Y                        Open menu

  Selection (struct/walk):
    L-stick ←/→              Sentence move    ↑/↓  Paragraph jump
    D-pad ↑/↓                Cycle highlights (if any on page)
    D-pad ←/→ / R-stick      Word navigation
    Y                        Vortuyo lookup
    X                        Toggle highlight
    A                        Action menu (dict, AI, copy, note)
    B                        Close overlay
    RB                       Extend selection
    LB                       Trim selection

  Dictionary popup:
    LB / RB                  Cycle dictionaries
    Y                        AI explain

Gamepad buttons arrive from SDL3 as standard key names:
  L-stick          →  LStickUp/Down/Left/Right (via userpatch)
  D-pad            →  Up, Down, Left, Right
  R-stick          →  F3, F4, F5, F8
  A (South)        →  Press
  B (East)         →  Back
  X (West)         →  F10
  Y (North)        →  ContextMenu
  LB / RB          →  RPgBack / RPgFwd
  Start            →  Menu
]]

local DataStorage    = require("datastorage")
local LuaSettings    = require("luasettings")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger          = require("logger")
local _               = require("gettext")

local kopad = WidgetContainer:extend{
    name        = "kopad",
    is_doc_only = false,
}

local function safe_require(modname)
    local ok, mod = pcall(require, modname)
    if not ok then
        logger.warn("kopad: failed to load " .. modname .. ": " .. tostring(mod))
        return nil
    end
    return mod
end

function kopad:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/kopad.lua")
    self.enabled  = self.settings:isTrue("enabled")
    self.subs     = {}

    self:_load_subs()

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function kopad:_load_subs()
    if self.subs.nav then return end

    local Nav = safe_require("padnav")
    if Nav then
        self.subs.nav = Nav:new{ ui = self.ui, enabled_ref = self }
    end

    self:_ensure_selector()
end

function kopad:_ensure_selector()
    if self.subs.selector then return end
    if not self.ui or not self.ui.rolling then return end
    local Selector = safe_require("selector")
    if Selector then
        self.subs.selector = Selector:new{ ui = self.ui, enabled_ref = self }
    end
end

function kopad:onReaderReady()
    self:_ensure_selector()
    if self.enabled and self.subs.nav then
        -- Re-apply suppression now that all reader modules have their key_events set
        self.subs.nav:restore_reader_keys()
        self.subs.nav:_suppress_reader_keys()
    end
end

function kopad:addToMainMenu(menu_items)
    local sub_items = {
        {
            text = _("Enable kopad"),
            checked_func = function() return self.enabled end,
            keep_menu_open = true,
            callback = function()
                self.enabled = not self.enabled
                self.settings:saveSetting("enabled", self.enabled)
                self.settings:flush()
                if self.enabled then
                    if self.subs.nav then
                        self.subs.nav:_suppress_reader_keys()
                    end
                else
                    if self.subs.selector then
                        self.subs.selector:_close()
                    end
                    if self.subs.nav then
                        self.subs.nav:restore_reader_keys()
                    end
                end
            end,
            separator = true,
        },
    }

    for _, sub in pairs(self.subs) do
        if sub.getMenuItems then
            local ok, items = pcall(sub.getMenuItems, sub)
            if ok and items then
                for _, item in ipairs(items) do
                    table.insert(sub_items, item)
                end
            end
        end
    end

    menu_items.kopad = {
        text = _("kopad"),
        sorting_hint = "more_tools",
        sub_item_table = sub_items,
    }
end

function kopad:onFlushSettings()
    self.settings:flush()
end

return kopad

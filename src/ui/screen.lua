--- Base class for screens (a full page of the UI).
--
-- Lifecycle, driven by `ui.navigation`:
--
--   Screen.new(params)          -- cheap, no drawing
--   screen:onMount(context)     -- subscribe to events, fetch initial data
--   screen:layout(x, y, w, h)   -- (re)build components for the content area
--   screen:update()             -- once per frame, refresh component values
--   screen:draw(renderer)
--   screen:handleTouch(x, y)
--   screen:onUnmount()          -- release subscriptions
--
-- Screens receive plain data. They must not call peripherals directly.

local class = require("core.class")

local Screen = class()

function Screen:init(params)
    self.params = params or {}
    self.children = {}
    self.modal = nil
    self.dirty = true
    self.needsLayout = true
    self.title = self.params.title
    self.subtitle = nil
    self.context = nil
    self.cleanups = {}
    -- Content rectangle assigned by navigation.
    self.x, self.y, self.w, self.h = 1, 1, 1, 1
end

---------------------------------------------------------------------------
-- Children
---------------------------------------------------------------------------

function Screen:add(component)
    component.screen = self
    self.children[#self.children + 1] = component
    return component
end

function Screen:clearChildren()
    self.children = {}
    return self
end

--- Mark the screen for a repaint on the next frame.
function Screen:invalidate()
    self.dirty = true
    if self.context and self.context.invalidate then self.context.invalidate() end
end

--- Ask for `layout` to run again before the next paint.
function Screen:requestLayout()
    self.needsLayout = true
    self:invalidate()
end

--- Register a cleanup callback (usually an event unsubscribe).
function Screen:onCleanup(fn)
    self.cleanups[#self.cleanups + 1] = fn
    return fn
end

---------------------------------------------------------------------------
-- Lifecycle hooks (override in subclasses)
---------------------------------------------------------------------------

function Screen:onMount(context) end   -- luacheck: ignore
function Screen:onLayout() end         -- luacheck: ignore
function Screen:update() end           -- luacheck: ignore
function Screen:onEvent(name, ...) end -- luacheck: ignore

function Screen:onUnmount()
    for _, cleanup in ipairs(self.cleanups) do pcall(cleanup) end
    self.cleanups = {}
end

---------------------------------------------------------------------------
-- Driven by navigation
---------------------------------------------------------------------------

--- Assign the content rectangle and rebuild components.
function Screen:layout(x, y, w, h)
    self.x, self.y, self.w, self.h = x, y, w, h
    self.children = {}
    self:onLayout(x, y, w, h)
    self.needsLayout = false
    self.dirty = true
end

function Screen:draw(renderer)
    for _, child in ipairs(self.children) do
        if child.visible then child:draw(renderer) end
    end
    if self.modal then self.modal:draw(renderer) end
end

--- @return boolean true when the touch was consumed
function Screen:handleTouch(px, py)
    if self.modal then return self.modal:handleTouch(px, py) end
    for index = #self.children, 1, -1 do
        if self.children[index]:handleTouch(px, py) then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- The bar of actions along the bottom
---------------------------------------------------------------------------

--- Rows a screen must keep clear for `Screen:actionBar`.
-- A blank row and a rule above the buttons, then the buttons. The gap is the
-- point: without it a list runs straight into the actions, its own pager ends
-- up shoulder to shoulder with them, and touching "the button at the bottom"
-- becomes a guess.
Screen.ACTION_BAR = 5
Screen.ACTION_BUTTONS = 3

--- Lay a row of actions along the bottom of `x, y, w, h`, above a divider.
-- @param actions list of { label, style, run, enabled }
function Screen:actionBar(x, y, w, h, actions)
    if #actions == 0 then return end

    local Button = require("ui.components.button")
    local Label = require("ui.components.label")
    local theme = require("ui.theme")
    local util = require("core.util")

    local barTop = y + h - Screen.ACTION_BAR
    if barTop <= y then return end

    -- A rule rather than blank space alone: on a busy screen the eye needs
    -- something to stop at, and one dim line is cheaper than a panel.
    local divider = Label.new({
        text = string.rep(theme.chars.horizontal, math.max(0, w)),
        fg = "border",
    })
    divider:setBounds(x, barTop + 1, w, 1)
    self:add(divider)

    local buttonsY = barTop + 2
    local slots = self.context.navigation.getRenderer():distribute(x, w, #actions, 2)

    for index, action in ipairs(actions) do
        local button = Button.new({
            label = util.truncate(action.label, slots[index].size),
            style = action.style,
            bracket = false,
            enabled = action.enabled ~= false,
            onPress = action.run,
        })
        button:setBounds(slots[index].offset, buttonsY, slots[index].size,
            Screen.ACTION_BUTTONS)
        self:add(button)
    end
end

---------------------------------------------------------------------------
-- Modals
---------------------------------------------------------------------------

function Screen:openModal(modal)
    modal.screen = self
    self.modal = modal
    modal.onClose = modal.onClose or function() self:closeModal() end
    modal:layout(self.surfaceW or self.w, self.surfaceH or self.h)
    self:invalidate()
    return modal
end

function Screen:closeModal()
    self.modal = nil
    self:invalidate()
end

return Screen

--- Base class for every UI component.
--
-- A component owns an absolute rectangle on the surface, knows how to draw
-- itself and can accept a touch. Components know nothing about modules,
-- peripherals or the domain: screens feed them plain values.
--
-- Sub-classes override `draw(renderer)` and optionally `onTouch(x, y)`.

local class = require("core.class")
local util = require("core.util")

local Component = class()

function Component:init(options)
    options = options or {}
    self.id = options.id
    self.x = options.x or 1
    self.y = options.y or 1
    self.w = options.w or 1
    self.h = options.h or 1
    self.visible = options.visible ~= false
    self.enabled = options.enabled ~= false
    self.data = options.data
    self.screen = nil       -- set by Screen:add
end

function Component:setBounds(x, y, w, h)
    self.x, self.y = math.floor(x), math.floor(y)
    self.w, self.h = math.max(0, math.floor(w)), math.max(0, math.floor(h))
    if self.onResize then self:onResize() end
    return self
end

function Component:bounds() return self.x, self.y, self.w, self.h end

function Component:setVisible(visible)
    self.visible = visible and true or false
    return self
end

function Component:setEnabled(enabled)
    self.enabled = enabled and true or false
    return self
end

--- True when the (absolute) point falls inside this component.
function Component:contains(px, py)
    return px >= self.x and px <= self.x + self.w - 1
        and py >= self.y and py <= self.y + self.h - 1
end

--- Ask the owning screen for a repaint.
function Component:invalidate()
    if self.screen and self.screen.invalidate then self.screen:invalidate() end
end

--- Override in sub-classes.
function Component:draw(renderer) end -- luacheck: ignore

--- Handle a touch at an absolute position.
-- @return boolean true when the touch was consumed
function Component:handleTouch(px, py)
    if not self.visible or not self.enabled then return false end
    if not self:contains(px, py) then return false end
    if self.onTouch then return self:onTouch(px, py) == true end
    return false
end

--- Shorthand used by sub-classes to clip their own text.
function Component:fitText(text, width)
    return util.truncate(text, width or self.w)
end

return Component

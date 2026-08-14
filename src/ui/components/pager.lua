--- Up / position / down control for anything taller than its area.
--
-- Monitors have no scroll wheel, so scrolling needs real buttons. This is the
-- one implementation: `List` uses it for rows, the module detail screen uses it
-- for metrics, and both look and behave the same.
--
--   local pager = Pager.new({ onUp = ..., onDown = ... })
--   pager:setBounds(x, y, w, Pager.HEIGHT)
--   pager:setRange(first, last, total, canUp, canDown)

local class = require("core.class")
local util = require("core.util")
local Component = require("ui.component")
local Button = require("ui.components.button")
local theme = require("ui.theme")

local Pager = class(Component)

--- Rows a pager occupies. Three makes the buttons an easy touch target.
Pager.HEIGHT = 3

function Pager:init(options)
    Component.init(self, options)
    options = options or {}
    self.h = options.h or Pager.HEIGHT
    self.bg = options.bg or "background"

    self.first, self.last, self.total = 0, 0, 0

    self.upButton = Button.new({
        label = theme.chars.arrowUp .. " UP",
        bracket = false,
        onPress = function() if options.onUp then options.onUp() end end,
    })
    self.downButton = Button.new({
        label = "DOWN " .. theme.chars.arrowDown,
        bracket = false,
        onPress = function() if options.onDown then options.onDown() end end,
    })
    self.children = { self.upButton, self.downButton }
end

--- Widest an arrow gets. A third of the monitor each made the pager read as
--- another row of actions, which is exactly what it is not: it moves the list
--- it belongs to. Sized to its label instead, with the readout given the
--- space between.
Pager.BUTTON_WIDTH = 10

--- Left button / readout / right button, derived without the renderer so touch
--- and draw can never disagree about where the buttons are.
function Pager:slots()
    local button = math.min(Pager.BUTTON_WIDTH, math.max(4, math.floor(self.w / 3)))
    return {
        { x = self.x, w = button },
        { x = self.x + button, w = self.w - 2 * button },
        { x = self.x + self.w - button, w = button },
    }
end

--- What is currently on screen, and which directions are available.
function Pager:setRange(first, last, total, canUp, canDown)
    self.first, self.last, self.total = first, last, total
    self.upButton:setEnabled(canUp and true or false)
    self.downButton:setEnabled(canDown and true or false)
    return self
end

function Pager:layoutButtons()
    local slots = self:slots()
    self.upButton.screen = self.screen
    self.downButton.screen = self.screen
    self.upButton:setBounds(slots[1].x, self.y, slots[1].w, self.h)
    self.downButton:setBounds(slots[3].x, self.y, slots[3].w, self.h)
    return slots
end

function Pager:draw(renderer)
    if not self.visible or self.w <= 0 or self.h <= 0 then return end

    local slots = self:layoutButtons()
    self.upButton:draw(renderer)
    self.downButton:draw(renderer)

    renderer:fill(slots[2].x, self.y, slots[2].w, self.h, self.bg, " ")
    renderer:writeCentered(slots[2].x, self.y + math.floor((self.h - 1) / 2), slots[2].w,
        util.truncate(("%d-%d / %d"):format(self.first, self.last, self.total), slots[2].w),
        "textDim", self.bg)
end

function Pager:handleTouch(px, py)
    if not self.visible or not self:contains(px, py) then return false end
    self:layoutButtons()
    if self.upButton:handleTouch(px, py) then return true end
    if self.downButton:handleTouch(px, py) then return true end
    -- The middle is a readout, but swallow the touch: it is inside the control.
    return true
end

return Pager

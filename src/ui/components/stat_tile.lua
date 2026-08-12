--- A headline number: label, value, optional meter and trend.
--
-- The top row of the dashboard. Everything here is at a glance - no borders, no
-- decoration, just the handful of figures worth walking across the base to read.

local class = require("core.class")
local util = require("core.util")
local Component = require("ui.component")
local theme = require("ui.theme")

local StatTile = class(Component)

--- @param options table { label, value, fraction, color, trend, onPress }
function StatTile:init(options)
    Component.init(self, options)
    options = options or {}
    self.label = options.label or ""
    self.value = options.value or "-"
    self.fraction = options.fraction     -- nil: no meter
    self.color = options.color or "text"
    self.trend = options.trend           -- "up" | "down" | nil
    self.onPress = options.onPress
    self.h = options.h or 3
end

function StatTile:set(value, fraction, color, trend)
    self.value = value
    self.fraction = fraction
    self.color = color or self.color
    self.trend = trend
    return self
end

local function trendChar(trend)
    if trend == "up" then return theme.chars.arrowUp end
    if trend == "down" then return theme.chars.arrowDown end
    return nil
end

function StatTile:draw(renderer)
    if not self.visible or self.w <= 0 or self.h <= 0 then return end

    renderer:write(self.x, self.y, util.truncate(self.label:upper(), self.w),
        "textDim", "background")

    local value = util.truncate(tostring(self.value), self.w)
    renderer:write(self.x, self.y + 1, value, self.color, "background")

    local arrow = trendChar(self.trend)
    if arrow and #value + 2 <= self.w then
        renderer:write(self.x + self.w - 1, self.y + 1, arrow, self.color, "background")
    end

    -- The meter is the third row when there is one and room for it.
    if self.fraction and self.h >= 3 and self.w >= 4 then
        renderer:progress(self.x, self.y + 2, self.w, self.fraction, {
            fill = self.color,
            track = "gaugeTrack",
            showPercent = false,
        })
    end
end

function StatTile:onTouch()
    if type(self.onPress) ~= "function" then return false end
    self.onPress()
    return true
end

return StatTile

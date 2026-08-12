--- Miniature bar chart for a metric's recent history.
--
-- CC's font has no partial-block glyphs, so a "line" chart would be a row of
-- dashes. Instead each sample becomes a coloured column: with three rows there
-- are three visible levels, which is enough to read a shape at a glance.
--
--   Sparkline.new({ series = history.series("power.charge") })

local class = require("core.class")
local util = require("core.util")
local Component = require("ui.component")
local theme = require("ui.theme")

local Sparkline = class(Component)

--- @param options table { series, fill, track, min, max, showRange }
function Sparkline:init(options)
    Component.init(self, options)
    options = options or {}
    self.series = options.series
    self.fill = options.fill or "accent"
    self.track = options.track or "surface"
    self.min = options.min          -- nil: taken from the data
    self.max = options.max
    self.showRange = options.showRange ~= false
    self.h = options.h or 3
end

function Sparkline:setSeries(series)
    self.series = series
    self:invalidate()
    return self
end

--- Bounds to scale against: explicit, else the data's own range, widened so a
--- flat line sits in the middle instead of filling or emptying the chart.
function Sparkline:bounds()
    local series = self.series
    local minimum = self.min or (series and series.min) or 0
    local maximum = self.max or (series and series.max) or 1

    if maximum <= minimum then
        local pad = math.max(math.abs(maximum) * 0.1, 1)
        minimum, maximum = minimum - pad, maximum + pad
    end
    return minimum, maximum
end

function Sparkline:draw(renderer)
    if not self.visible or self.w <= 0 or self.h <= 0 then return end

    local series = self.series
    renderer:fill(self.x, self.y, self.w, self.h, self.track, " ")

    if not series or series.count < 2 then
        renderer:writeCentered(self.x, self.y + math.floor((self.h - 1) / 2), self.w,
            util.truncate("collecting history...", self.w), "textDim", self.track)
        return
    end

    -- Room for the range labels on the right, when they fit.
    local labelWidth = 0
    if self.showRange and self.w > 14 then
        labelWidth = math.max(#util.formatNumber(series.max), #util.formatNumber(series.min)) + 1
    end
    local chartWidth = self.w - labelWidth
    if chartWidth < 2 then return end

    local minimum, maximum = self:bounds()
    local range = maximum - minimum
    local fill = theme.get(self.fill)

    -- Show the most recent `chartWidth` samples, one column each.
    local firstIndex = math.max(1, series.count - chartWidth + 1)
    for column = 0, math.min(chartWidth, series.count - firstIndex + 1) - 1 do
        local value = series.values[firstIndex + column]
        local fraction = util.clamp((value - minimum) / range, 0, 1)
        local filled = math.max(1, math.floor(fraction * self.h + 0.5))

        for row = 0, filled - 1 do
            renderer:write(self.x + column, self.y + self.h - 1 - row, " ", fill, fill)
        end
    end

    if labelWidth > 0 then
        local labelX = self.x + chartWidth
        renderer:write(labelX, self.y, util.formatNumber(series.max), "textDim", self.track)
        renderer:write(labelX, self.y + self.h - 1, util.formatNumber(series.min),
            "textDim", self.track)
    end
end

return Sparkline

--- One metric over time: current value, where it is heading, and a chart.
--
-- Reached by touching a metric row on a module's detail screen.

local class = require("core.class")
local util = require("core.util")
local Screen = require("ui.screen")
local Panel = require("ui.components.panel")
local Label = require("ui.components.label")
local Sparkline = require("ui.components.sparkline")
local registry = require("modules.registry")
local history = require("services.history")
local theme = require("ui.theme")

local MetricDetail = class(Screen)

local TREND_TEXT = {
    up = "rising",
    down = "falling",
    flat = "steady",
}

function MetricDetail:init(params)
    Screen.init(self, params)
    self.moduleId = params.moduleId
    self.metricId = params.metricId
    self.seriesId = tostring(self.moduleId) .. "." .. tostring(self.metricId)

    local record = registry.get(self.moduleId)
    self.title = (record and record.name or tostring(self.moduleId))
end

--- The metric as it looks right now, straight from the module.
function MetricDetail:metric()
    local snapshot = registry.snapshot(self.moduleId)
    for _, metric in ipairs((snapshot and snapshot.metrics) or {}) do
        if metric.id == self.metricId then return metric end
    end
    return nil
end

local function trendColor(direction)
    if direction == "up" then return theme.get("statusOk") end
    if direction == "down" then return theme.get("statusWarn") end
    return theme.get("textDim")
end

local function trendArrow(direction)
    if direction == "up" then return theme.chars.arrowUp end
    if direction == "down" then return theme.chars.arrowDown end
    return "-"
end

function MetricDetail:onLayout(x, y, w, h)
    local metric = self:metric()
    self.title = (metric and metric.label) or tostring(self.metricId)

    local panel = Panel.new({ title = self.title, bg = "background", fg = "border" })
    panel:setBounds(x, y, w, h)
    self:add(panel)

    local cx, cy, cw, ch = panel:contentBounds()

    self.valueLabel = Label.new({ text = "", fg = "text" })
    self.valueLabel:setBounds(cx, cy, cw, 1)
    self:add(self.valueLabel)

    self.trendLabel = Label.new({ text = "", fg = "textDim" })
    self.trendLabel:setBounds(cx, cy + 1, cw, 1)
    self:add(self.trendLabel)

    self.statsLabel = Label.new({ text = "", fg = "textDim" })
    self.statsLabel:setBounds(cx, cy + 2, cw, 1)
    self:add(self.statsLabel)

    -- The chart takes whatever is left; below about six rows there is no room
    -- for one, so the numbers stand alone.
    local chartTop = cy + 4
    local chartHeight = (cy + ch - 1) - chartTop + 1
    if chartHeight >= 3 then
        self.chart = Sparkline.new({
            series = history.series(self.seriesId),
            fill = "accent",
            h = math.min(chartHeight, 8),
        })
        self.chart:setBounds(cx, chartTop, cw, math.min(chartHeight, 8))
        self:add(self.chart)

        self.captionLabel = Label.new({ text = "", fg = "textDim" })
        self.captionLabel:setBounds(cx, chartTop + math.min(chartHeight, 8), cw, 1)
        self:add(self.captionLabel)
    end
end

function MetricDetail:update()
    local metric = self:metric()
    local series = history.series(self.seriesId)

    if self.valueLabel then
        self.valueLabel:setText(metric and registry.formatMetric(metric) or "no reading")
    end

    if self.trendLabel then
        local direction, delta = history.trend(self.seriesId)
        self.trendLabel:setText(("%s %s  (%s%s over the window)"):format(
            trendArrow(direction), TREND_TEXT[direction] or "?",
            delta > 0 and "+" or "", util.formatNumber(delta)))
        self.trendLabel:setColor(trendColor(direction))
    end

    if self.statsLabel then
        if series then
            self.statsLabel:setText(("min %s   avg %s   max %s"):format(
                util.formatNumber(series.min),
                util.formatNumber(history.average(self.seriesId) or 0),
                util.formatNumber(series.max)))
        else
            self.statsLabel:setText("no history recorded yet")
        end
    end

    if self.chart then self.chart:setSeries(series) end

    if self.captionLabel then
        self.captionLabel:setText(series
            and (series.count .. " samples") or "")
    end
end

return MetricDetail

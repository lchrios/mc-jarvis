--- Horizontal gauge with an optional caption line.

local class = require("core.class")
local util = require("core.util")
local Component = require("ui.component")
local theme = require("ui.theme")

local ProgressBar = class(Component)

--- @param options table {
---   value = 0..1, label = string, showPercent = bool,
---   thresholds = { warn = 0.5, critical = 0.2 }, invertThresholds = bool,
---   fill = colour name, track = colour name }
function ProgressBar:init(options)
    Component.init(self, options)
    options = options or {}
    self.value = util.clamp(options.value or 0, 0, 1)
    self.label = options.label
    self.text = options.text
    self.showPercent = options.showPercent ~= false
    self.fill = options.fill
    self.track = options.track or "gaugeTrack"
    self.thresholds = options.thresholds
    -- When true a *high* value is the bad one (e.g. buffer fullness).
    self.invertThresholds = options.invertThresholds == true
    self.h = options.h or (options.label and 2 or 1)
end

function ProgressBar:setValue(value)
    value = util.clamp(tonumber(value) or 0, 0, 1)
    if value ~= self.value then
        self.value = value
        self:invalidate()
    end
    return self
end

--- Colour derived from the configured thresholds.
function ProgressBar:fillColor()
    if self.fill then return theme.get(self.fill) end
    if not self.thresholds then return theme.get("gaugeFill") end

    local value = self.invertThresholds and (1 - self.value) or self.value
    local critical = self.thresholds.critical or 0
    local warn = self.thresholds.warn or 0

    if value <= critical then return theme.get("statusError") end
    if value <= warn then return theme.get("statusWarn") end
    return theme.get("statusOk")
end

function ProgressBar:draw(renderer)
    if not self.visible or self.w <= 0 or self.h <= 0 then return end

    local barY = self.y
    if self.label and self.h >= 2 then
        renderer:write(self.x, self.y, self:fitText(self.label), "textDim", "background")
        barY = self.y + 1
    end

    renderer:progress(self.x, barY, self.w, self.value, {
        fill = self:fillColor(),
        track = self.track,
        text = self.text,
        showPercent = self.showPercent,
    })
end

return ProgressBar

--- Semantic colour palette for the UI.
--
-- Screens and components never reference `colors.lime` directly; they ask for
-- `theme.get("statusOk")`. That keeps monochrome monitors working and makes a
-- palette change a one file edit.

local util = require("core.util")

local theme = {}

local PRESETS = {
    dark = {
        background   = colors.black,
        surface      = colors.gray,
        surfaceAlt   = colors.lightGray,
        border       = colors.gray,
        text         = colors.white,
        textDim      = colors.lightGray,
        textInverse  = colors.black,

        headerBg     = colors.blue,
        headerText   = colors.white,
        footerBg     = colors.gray,
        footerText   = colors.white,

        accent       = colors.cyan,
        accentText   = colors.black,

        buttonBg     = colors.lightGray,
        buttonText   = colors.black,
        buttonActive = colors.cyan,
        buttonDisabledBg = colors.gray,
        buttonDisabledText = colors.lightGray,
        buttonDangerBg = colors.red,
        buttonDangerText = colors.white,

        statusOk      = colors.lime,
        statusWarn    = colors.orange,
        statusError   = colors.red,
        statusIdle    = colors.lightGray,
        statusUnknown = colors.gray,

        gaugeFill  = colors.lime,
        gaugeTrack = colors.gray,

        severityInfo     = colors.lightBlue,
        severityWarning  = colors.orange,
        severityCritical = colors.red,
    },

    light = {
        background   = colors.lightGray,
        surface      = colors.white,
        surfaceAlt   = colors.lightGray,
        border       = colors.gray,
        text         = colors.black,
        textDim      = colors.gray,
        textInverse  = colors.white,

        headerBg     = colors.blue,
        headerText   = colors.white,
        footerBg     = colors.gray,
        footerText   = colors.white,

        accent       = colors.blue,
        accentText   = colors.white,

        buttonBg     = colors.gray,
        buttonText   = colors.white,
        buttonActive = colors.blue,
        buttonDisabledBg = colors.lightGray,
        buttonDisabledText = colors.gray,
        buttonDangerBg = colors.red,
        buttonDangerText = colors.white,

        statusOk      = colors.green,
        statusWarn    = colors.orange,
        statusError   = colors.red,
        statusIdle    = colors.gray,
        statusUnknown = colors.gray,

        gaugeFill  = colors.green,
        gaugeTrack = colors.lightGray,

        severityInfo     = colors.blue,
        severityWarning  = colors.orange,
        severityCritical = colors.red,
    },
}

-- Fallback for monitors without colour support: only black and white exist.
local MONOCHROME = {
    background = colors.black, surface = colors.black, surfaceAlt = colors.black,
    border = colors.white, text = colors.white, textDim = colors.white,
    textInverse = colors.black,
    headerBg = colors.white, headerText = colors.black,
    footerBg = colors.white, footerText = colors.black,
    accent = colors.white, accentText = colors.black,
    buttonBg = colors.white, buttonText = colors.black,
    buttonActive = colors.white, buttonDisabledBg = colors.black,
    buttonDisabledText = colors.white,
    buttonDangerBg = colors.white, buttonDangerText = colors.black,
    statusOk = colors.white, statusWarn = colors.white, statusError = colors.white,
    statusIdle = colors.white, statusUnknown = colors.white,
    gaugeFill = colors.white, gaugeTrack = colors.black,
    severityInfo = colors.white, severityWarning = colors.white, severityCritical = colors.white,
}

--- Box drawing characters. ASCII by default so every font renders them.
theme.chars = {
    horizontal = "-",
    vertical = "|",
    cornerTopLeft = "+",
    cornerTopRight = "+",
    cornerBottomLeft = "+",
    cornerBottomRight = "+",
    gaugeFilled = " ",
    gaugeEmpty = " ",
    -- Pipework on the base map, deliberately unlike the box borders.
    linkHorizontal = "=",
    linkVertical = "|",
    linkCorner = "+",
    arrowLeft = "<",
    arrowRight = ">",
    arrowUp = "^",
    arrowDown = "v",
    bullet = "*",
}

local active = util.deepCopy(PRESETS.dark)
local monochrome = false

--- Apply a preset plus optional per-key overrides.
-- @param options table { preset = "dark"|"light", overrides = {...}, monochrome = bool }
function theme.apply(options)
    options = options or {}
    local preset = PRESETS[options.preset or "dark"] or PRESETS.dark
    active = util.deepCopy(preset)
    monochrome = options.monochrome == true
    if type(options.overrides) == "table" then
        for key, value in pairs(options.overrides) do active[key] = value end
    end
    if type(options.chars) == "table" then
        for key, value in pairs(options.chars) do theme.chars[key] = value end
    end
    return theme
end

--- Resolve a semantic colour name. Accepts a raw colour value too.
function theme.get(name, fallback)
    if type(name) == "number" then return name end
    if monochrome then
        return MONOCHROME[name] or fallback or colors.white
    end
    local value = active[name]
    if value == nil then return fallback or colors.white end
    return value
end

--- Colour for a module/zone status string.
function theme.statusColor(status)
    status = tostring(status or "unknown"):lower()
    if status == "running" or status == "online" or status == "ok" or status == "ready" then
        return theme.get("statusOk")
    elseif status == "warning" or status == "degraded" or status == "starting" then
        return theme.get("statusWarn")
    elseif status == "error" or status == "fault" or status == "offline" then
        return theme.get("statusError")
    elseif status == "stopped" or status == "idle" or status == "paused" then
        return theme.get("statusIdle")
    end
    return theme.get("statusUnknown")
end

--- Colour for an alert severity string.
function theme.severityColor(severity)
    severity = tostring(severity or "info"):lower()
    if severity == "critical" then return theme.get("severityCritical") end
    if severity == "warning" then return theme.get("severityWarning") end
    return theme.get("severityInfo")
end

function theme.isMonochrome() return monochrome end

function theme.palette() return util.deepCopy(active) end

theme.PRESETS = PRESETS

return theme

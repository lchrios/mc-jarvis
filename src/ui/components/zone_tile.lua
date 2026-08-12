--- A clickable box on the base map.
--
-- A zone tile is a *view* of a module snapshot. It receives an already
-- flattened table and knows nothing about the module registry:
--
--   { label = "Mob Farm", status = "running", statusText = "RUNNING",
--     lines = { "124 it/m" }, gauge = 0.73, available = true }

local class = require("core.class")
local util = require("core.util")
local Component = require("ui.component")
local theme = require("ui.theme")

local ZoneTile = class(Component)

--- @param options table { zone, snapshot, onPress }
function ZoneTile:init(options)
    Component.init(self, options)
    options = options or {}
    self.zone = options.zone or {}
    self.snapshot = options.snapshot or {}
    self.onPress = options.onPress
end

function ZoneTile:setSnapshot(snapshot)
    self.snapshot = snapshot or {}
    return self
end

function ZoneTile:draw(renderer)
    if not self.visible or self.w < 3 or self.h < 1 then return end

    local snapshot = self.snapshot
    local available = snapshot.available ~= false
    local statusColor = available and theme.statusColor(snapshot.status) or theme.get("statusUnknown")

    local bg = theme.get(self.zone.color or "surface")
    renderer:box(self.x, self.y, self.w, self.h, {
        fg = statusColor,
        bg = bg,
        fill = bg,
    })

    local innerX, innerY = self.x + 1, self.y + 1
    local innerW = self.w - 2
    if innerW <= 0 then return end

    local title = self.zone.label or snapshot.label or self.zone.id or "?"
    if self.zone.icon then title = self.zone.icon .. " " .. title end
    renderer:writeCentered(innerX, innerY, innerW, util.truncate(title, innerW), "text", bg)

    local row = innerY + 1
    local lastRow = self.y + self.h - 2

    if self.h >= 4 then
        local statusText = snapshot.statusText or tostring(snapshot.status or "unknown"):upper()
        if not available then statusText = "N/A" end
        -- An empty status is a deliberate choice (shortcut tiles), not a gap.
        if statusText ~= "" then
            renderer:writeCentered(innerX, row, innerW, util.truncate(statusText, innerW), statusColor, bg)
        end
        row = row + 1
    end

    for _, line in ipairs(snapshot.lines or {}) do
        if row > lastRow then break end
        renderer:writeCentered(innerX, row, innerW, util.truncate(line, innerW), "textDim", bg)
        row = row + 1
    end

    if snapshot.gauge ~= nil and row <= lastRow and innerW >= 4 then
        renderer:progress(innerX, row, innerW, snapshot.gauge, {
            fill = statusColor,
            track = "gaugeTrack",
            showPercent = innerW >= 6,
        })
    end

    -- A tiny corner marker keeps disabled zones obvious on monochrome screens.
    if not available then
        renderer:write(self.x + self.w - 2, self.y, "!", theme.get("statusWarn"), bg)
    end
end

function ZoneTile:onTouch(px, py)
    if type(self.onPress) ~= "function" then return false end
    self.onPress(self.zone, self.snapshot, px, py)
    return true
end

return ZoneTile

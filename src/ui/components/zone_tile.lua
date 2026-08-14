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

--- @param options table { zone, snapshot, onPress, compact }
--
-- `compact` is what the base map uses. A plan is read by its shape - which
-- room is where, and what runs between them - so a tile there carries its name
-- and one word of state and stops. Spelling out "no storage peripherals" in
-- every box turns the plan back into the dashboard it is meant not to be; the
-- detail is one touch away.
function ZoneTile:init(options)
    Component.init(self, options)
    options = options or {}
    self.zone = options.zone or {}
    self.snapshot = options.snapshot or {}
    self.onPress = options.onPress
    self.compact = options.compact == true
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

    local innerX = self.x + 1
    local innerW = self.w - 2
    local innerH = self.h - 2
    if innerW <= 0 or innerH <= 0 then return end

    -- Build the rows first, then centre the block vertically: on a big monitor
    -- a tile is much taller than its contents and top-aligned text looks lost.
    local rows = {}

    local title = self.zone.label or snapshot.label or self.zone.id or "?"
    if self.zone.icon then title = self.zone.icon .. " " .. title end
    rows[#rows + 1] = { text = title, fg = "text" }

    if self.h >= 4 then
        local statusText = snapshot.statusText or tostring(snapshot.status or "unknown"):upper()
        if not available then statusText = "N/A" end

        -- On a plan a half-word like "NO DE..." is worse than no word: the
        -- border is already drawn in the status colour, so the state is there
        -- either way. Say it only when it fits whole.
        local fits = not self.compact or #statusText <= innerW

        -- An empty status is a deliberate choice (shortcut tiles), not a gap.
        if statusText ~= "" and fits then
            rows[#rows + 1] = { text = statusText, fg = statusColor }
        end
    end

    if not self.compact then
        for _, line in ipairs(snapshot.lines or {}) do
            rows[#rows + 1] = { text = line, fg = "textDim" }
        end
    end

    -- The gauge survives compact mode: "how full is it" is a shape, not a
    -- sentence, and it is the one number worth having on a plan.
    local showGauge = snapshot.gauge ~= nil and innerW >= 4
        and (not self.compact or self.h >= 5)
    local needed = #rows + (showGauge and 1 or 0)
    local row = self.y + 1 + math.max(0, math.floor((innerH - needed) / 2))
    local lastRow = self.y + self.h - 2

    for _, entry in ipairs(rows) do
        if row > lastRow then break end
        renderer:writeCentered(innerX, row, innerW, util.truncate(entry.text, innerW), entry.fg, bg)
        row = row + 1
    end

    if showGauge and row <= lastRow then
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

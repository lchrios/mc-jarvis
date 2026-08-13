--- Main screen: headline figures, live systems, recent activity, actions.
--
-- Deliberately not a grid of equal boxes. The layout borrows from the terminal
-- dashboards that read well at a glance: a row of stat tiles with meters (btop),
-- a hotkey bar of actions along the bottom (k9s), and a side feed of what just
-- happened (lazygit). The base plan lives on its own screen now - a plan is for
-- looking at, not for operating from.
--
-- Everything adapts: on a narrow monitor the activity feed is dropped, then the
-- meters, before anything essential is lost.

local class = require("core.class")
local util = require("core.util")
local bus = require("core.event_bus")
local Screen = require("ui.screen")
local Label = require("ui.components.label")
local Button = require("ui.components.button")
local List = require("ui.components.list")
local StatTile = require("ui.components.stat_tile")
local registry = require("modules.registry")
local activity = require("services.activity")
local security = require("services.security")
local alerts = require("services.alerts")
local history = require("services.history")
local state = require("core.state")
local config = require("core.config")
local theme = require("ui.theme")

local Dashboard = class(Screen)

local ACTION_HEIGHT = 3
local STAT_HEIGHT = 3
local STAT_MAX_WIDTH = 18
local FEED_MIN_WIDTH = 30

function Dashboard:init(params)
    Screen.init(self, params)
    self.title = config.get("system.name", "BASE CONTROL")
    self.stats = {}
end

function Dashboard:onMount()
    local relayout = function() self:requestLayout() end
    self:onCleanup(bus.on("module.registered", relayout, { owner = "screen:dashboard" }))
    self:onCleanup(bus.on("module.unregistered", relayout, { owner = "screen:dashboard" }))
    self:onCleanup(bus.on("activity.added", function() self:invalidate() end,
        { owner = "screen:dashboard" }))
end

---------------------------------------------------------------------------
-- Headline figures
---------------------------------------------------------------------------

--- The numbers worth reading from across the room, best first.
-- Built from whatever this base actually has, so a install without a power
-- module does not show an empty POWER tile.
function Dashboard:statSpecs()
    local specs = {}

    local power = registry.get("power")
    if power and power.def and (power.def.capacity or 0) > 0 then
        local fraction = power.def.percentage or 0
        local direction = history.trend("power.charge")
        specs[#specs + 1] = {
            id = "power",
            label = "Power",
            value = util.formatPercent(fraction),
            fraction = fraction,
            color = theme.statusColor(power.status),
            trend = direction ~= "flat" and direction or nil,
            onPress = function() self.context.navigation.push("module_detail", { moduleId = "power" }) end,
        }
    end

    local storage = registry.get("storage")
    if storage and storage.def and (storage.def.totalItems or 0) > 0 then
        specs[#specs + 1] = {
            id = "storage",
            label = "Storage",
            value = util.formatNumber(storage.def.totalItems) .. " items",
            fraction = storage.def.fillLevel,
            color = theme.statusColor(storage.status),
            onPress = function() self.context.navigation.push("module_detail", { moduleId = "storage" }) end,
        }
    end

    local alertCount = alerts.count()
    specs[#specs + 1] = {
        id = "alerts",
        label = "Alerts",
        value = tostring(alertCount),
        color = alertCount > 0 and theme.severityColor(alerts.worstSeverity()) or theme.get("statusOk"),
        onPress = function() self.context.navigation.push("alerts", {}) end,
    }

    local total, online = 0, 0
    for _, node in pairs(state.get("nodes", {})) do
        total = total + 1
        if node.online then online = online + 1 end
    end
    if total > 0 then
        specs[#specs + 1] = {
            id = "nodes",
            label = "Nodes",
            value = online .. "/" .. total,
            fraction = online / total,
            color = online == total and theme.get("statusOk") or theme.get("statusError"),
            onPress = function() self.context.navigation.push("nodes", {}) end,
        }
    else
        specs[#specs + 1] = {
            id = "modules",
            label = "Modules",
            value = tostring(registry.count()),
            color = theme.get("text"),
            onPress = function() self.context.navigation.push("module_list", {}) end,
        }
    end

    return specs
end

---------------------------------------------------------------------------
-- Systems list
---------------------------------------------------------------------------

--- One row per module: name, status, an inline meter and its headline figure.
local function drawSystemRow(renderer, record, index, x, y, width)
    local snapshot = registry.snapshot(record.id) or {}
    local statusColor = snapshot.available == false
        and theme.get("statusUnknown") or theme.statusColor(snapshot.status)

    renderer:fill(x, y, width, 1, "background", " ")

    -- A coloured pip carries the status even where the text is truncated.
    renderer:write(x, y, theme.chars.bullet, statusColor, "background")

    local nameWidth = math.max(8, math.floor(width * 0.34))
    renderer:write(x + 2, y, util.truncate(record.name, nameWidth - 2), "text", "background")

    local statusText = snapshot.statusText or tostring(snapshot.status):upper()
    local statusWidth = math.min(12, math.max(10, math.floor(width * 0.2)))
    -- One column short of the field, so status and value never touch.
    renderer:write(x + nameWidth, y, util.truncate(statusText, statusWidth - 1),
        statusColor, "background")

    local rest = width - nameWidth - statusWidth
    if rest < 6 then return end

    -- A gauge if the module has one, otherwise its first metric.
    local restX = x + nameWidth + statusWidth
    if snapshot.gauge then
        local meterWidth = math.min(12, rest - 5)
        renderer:progress(restX, y, meterWidth, snapshot.gauge, {
            fill = statusColor, track = "gaugeTrack", showPercent = false,
        })
        renderer:write(restX + meterWidth + 1, y,
            util.truncate(util.formatPercent(snapshot.gauge), rest - meterWidth - 1),
            "textDim", "background")
    elseif snapshot.lines and snapshot.lines[1] then
        renderer:write(restX, y, util.truncate(snapshot.lines[1], rest), "textDim", "background")
    end
end

---------------------------------------------------------------------------
-- Activity feed
---------------------------------------------------------------------------

local SEVERITY_COLOR = {
    critical = "statusError",
    warning = "statusWarn",
    ok = "statusOk",
    info = "textDim",
}

local function renderActivity(entry, width)
    local age = util.formatDuration((util.nowMs() - entry.time) / 1000)
    local stamp = util.padLeft(age, 7) .. " "
    return {
        text = stamp .. util.truncate(entry.text, math.max(4, width - #stamp)),
        fg = theme.get(SEVERITY_COLOR[entry.severity] or "textDim"),
    }
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------

function Dashboard:actionSpecs()
    local specs = {
        { label = "MAP", screen = "map" },
        { label = "NODES", screen = "nodes" },
        { label = "ALERTS", screen = "alerts" },
        { label = "DEVICES", screen = "peripherals" },
        { label = "LOGS", screen = "logs" },
    }

    -- Only worth a slot on a base that actually gates anything.
    if security.settings().enabled then
        table.insert(specs, #specs, { label = "ACCESS", screen = "security" })
    end
    return specs
end

function Dashboard:onLayout(x, y, w, h)
    self.stats = {}

    ---------------------------------------------------------------- stats
    local specs = self:statSpecs()
    local statRows = h >= 14 and STAT_HEIGHT or 2

    -- Capped rather than stretched: a two-character number spread over forty
    -- columns reads as a mistake, not as emphasis.
    local gap = 2
    local tileWidth = math.min(STAT_MAX_WIDTH,
        math.floor((w - gap * (#specs - 1)) / math.max(1, #specs)))

    for index, spec in ipairs(specs) do
        local tile = StatTile.new({
            label = spec.label,
            value = spec.value,
            fraction = statRows >= 3 and spec.fraction or nil,
            color = spec.color,
            trend = spec.trend,
            onPress = spec.onPress,
            h = statRows,
        })
        tile:setBounds(x + (index - 1) * (tileWidth + gap), y, tileWidth, statRows)
        self:add(tile)
        self.stats[#self.stats + 1] = { component = tile, id = spec.id }
    end

    ---------------------------------------------------------------- body
    local bodyY = y + statRows + 1
    local bodyHeight = h - statRows - 1 - ACTION_HEIGHT - 1
    if bodyHeight < 3 then bodyHeight = math.max(1, h - statRows - 1) end

    -- The feed is the first thing to go when the monitor is narrow.
    local showFeed = w >= (FEED_MIN_WIDTH * 2)
    local systemsWidth = showFeed and math.floor(w * 0.55) or w

    local systemsHeader = Label.new({ text = "SYSTEMS", fg = "textDim" })
    systemsHeader:setBounds(x, bodyY, systemsWidth, 1)
    self:add(systemsHeader)

    self.systems = List.new({
        items = registry.all(),
        drawItem = drawSystemRow,
        emptyText = "No modules loaded.",
        onSelect = function(record)
            self.context.navigation.push("module_detail", { moduleId = record.id })
        end,
    })
    self.systems:setBounds(x, bodyY + 1, systemsWidth, math.max(1, bodyHeight - 1))
    self:add(self.systems)

    if showFeed then
        local feedX = x + systemsWidth + 2
        local feedWidth = w - systemsWidth - 2

        local feedHeader = Label.new({ text = "ACTIVITY", fg = "textDim" })
        feedHeader:setBounds(feedX, bodyY, feedWidth, 1)
        self:add(feedHeader)

        self.feed = List.new({
            items = activity.recent(30),
            renderItem = function(entry) return renderActivity(entry, feedWidth) end,
            emptyText = "Nothing has happened yet.",
            pager = false,
        })
        self.feed:setBounds(feedX, bodyY + 1, feedWidth, math.max(1, bodyHeight - 1))
        self:add(self.feed)
    else
        self.feed = nil
    end

    ---------------------------------------------------------------- actions
    local actionY = y + h - ACTION_HEIGHT
    if actionY <= bodyY then return end

    local actions = self:actionSpecs()
    local actionSlots = self.context.navigation.getRenderer():distribute(x, w, #actions, 1)

    for index, action in ipairs(actions) do
        local button = Button.new({
            label = action.label,
            bracket = false,
            onPress = function() self.context.navigation.push(action.screen, {}) end,
        })
        button:setBounds(actionSlots[index].offset, actionY, actionSlots[index].size, ACTION_HEIGHT)
        self:add(button)
    end
end

function Dashboard:update()
    -- Stat values change constantly; which stats exist almost never does.
    local specs = {}
    for _, spec in ipairs(self:statSpecs()) do specs[spec.id] = spec end

    for _, stat in ipairs(self.stats) do
        local spec = specs[stat.id]
        if spec then
            stat.component:set(spec.value, spec.fraction, spec.color, spec.trend)
        end
    end

    if self.systems then self.systems:setItems(registry.all()) end
    if self.feed then self.feed:setItems(activity.recent(30)) end
end

return Dashboard

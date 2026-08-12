--- The fixed view a display computer shows.
--
-- A display is a monitor placed anywhere in the base, pinned to one slice of
-- the system: the reactor room screen shows power, the barn screen shows farms.
-- It holds no data of its own - everything arrives as node telemetry - so the
-- view is resolved fresh on every layout and simply waits when nothing has
-- reported yet.
--
--   view = { title = "POWER", modules = "power" }   -- prefix match
--   view = { title = "BASE",  modules = "*" }       -- everything
--   view = { modules = { "power_node.power" } }     -- exact ids

local class = require("core.class")
local util = require("core.util")
local bus = require("core.event_bus")
local Screen = require("ui.screen")
local Label = require("ui.components.label")
local Panel = require("ui.components.panel")
local ZoneTile = require("ui.components.zone_tile")
local ProgressBar = require("ui.components.progress_bar")
local Sparkline = require("ui.components.sparkline")
local registry = require("modules.registry")
local history = require("services.history")
local theme = require("ui.theme")

local DisplayView = class(Screen)

function DisplayView:init(params)
    Screen.init(self, params)
    self.view = params.view or { title = "BASE", modules = "*" }
    self.title = self.view.title or "DISPLAY"
    self.tiles = {}
end

function DisplayView:onMount()
    -- Modules appear as nodes report in, which changes the layout, not just
    -- the values.
    local relayout = function() self:requestLayout() end
    self:onCleanup(bus.on("module.registered", relayout, { owner = "screen:display" }))
    self:onCleanup(bus.on("module.unregistered", relayout, { owner = "screen:display" }))
end

--- Module ids this view should show, in a stable order.
function DisplayView:matchingModules()
    local pattern = self.view.modules or "*"
    local matched = {}

    for _, record in ipairs(registry.all()) do
        local id = record.id
        local keep

        if pattern == "*" then
            keep = true
        elseif type(pattern) == "table" then
            keep = util.contains(pattern, id)
        elseif pattern:find(".", 1, true) then
            -- A dotted pattern addresses a node: "power_node." takes all of it.
            keep = id:sub(1, #pattern) == pattern
        else
            -- A bare pattern matches the module, never the node it runs on:
            -- "power" must not swallow "power_node.storage".
            local bare = id:match("%.(.+)$") or id
            keep = bare:sub(1, #pattern) == pattern
        end

        if keep then matched[#matched + 1] = id end
    end

    table.sort(matched)
    return matched
end

---------------------------------------------------------------------------

function DisplayView:layoutWaiting(x, y, w, h)
    local message = Label.new({
        text = "Waiting for data.\n\nNothing matching '"
            .. tostring(type(self.view.modules) == "table" and "a list" or self.view.modules)
            .. "' has reported yet.\n\nCheck the nodes are running and have a modem.",
        wrap = true, fg = "textDim", align = "center",
    })
    message:setBounds(x + 2, y + math.max(0, math.floor(h / 2) - 3), w - 4, 6)
    self:add(message)
end

--- One module: room for its metrics and a trend chart.
function DisplayView:layoutSingle(id, x, y, w, h)
    local snapshot = registry.snapshot(id)
    local record = registry.get(id)

    local panel = Panel.new({ title = record and record.name or id, bg = "background" })
    panel:setBounds(x, y, w, h)
    self:add(panel)

    local cx, cy, cw, ch = panel:contentBounds()

    local status = Label.new({
        text = snapshot and (snapshot.statusText or tostring(snapshot.status):upper()) or "NO DATA",
        fg = theme.statusColor(snapshot and snapshot.status),
    })
    status:setBounds(cx, cy, cw, 1)
    self:add(status)

    local row = cy + 2
    self.valueRows = {}

    for _, metric in ipairs((snapshot and snapshot.metrics) or {}) do
        if row > cy + ch - 1 then break end
        local label = Label.new({ text = metric.label, fg = "textDim" })
        label:setBounds(cx, row, math.floor(cw / 2), 1)
        self:add(label)

        local value = Label.new({
            text = registry.formatMetric(metric), align = "right", fg = "text",
        })
        value:setBounds(cx + math.floor(cw / 2), row, cw - math.floor(cw / 2), 1)
        self:add(value)
        self.valueRows[#self.valueRows + 1] = { component = value, metric = metric, moduleId = id }
        row = row + 1
    end

    -- A chart of the first thing that has history, if there is room left.
    local remaining = (cy + ch - 1) - row
    if remaining >= 4 then
        for _, metric in ipairs((snapshot and snapshot.metrics) or {}) do
            local seriesId = id .. "." .. metric.id
            if history.has(seriesId) then
                local caption = Label.new({ text = metric.label .. " over time", fg = "textDim" })
                caption:setBounds(cx, row + 1, cw, 1)
                self:add(caption)

                self.chart = Sparkline.new({ series = history.series(seriesId), h = remaining - 2 })
                self.chart:setBounds(cx, row + 2, cw, remaining - 2)
                self.chartSeriesId = seriesId
                self:add(self.chart)
                break
            end
        end
    end
end

--- Several modules: a grid of tiles, like the dashboard but read-only.
function DisplayView:layoutGrid(ids, x, y, w, h)
    local columns = math.min(#ids, math.max(1, math.floor(w / 20)))
    local rows = math.ceil(#ids / columns)

    for index, id in ipairs(ids) do
        local column = (index - 1) % columns
        local rowIndex = math.floor((index - 1) / columns)

        local tileX = x + math.floor(column * w / columns)
        local tileW = math.floor((column + 1) * w / columns) - math.floor(column * w / columns) - 1
        local tileY = y + math.floor(rowIndex * h / rows)
        local tileH = math.floor((rowIndex + 1) * h / rows) - math.floor(rowIndex * h / rows) - 1

        if tileW >= 4 and tileH >= 3 then
            local record = registry.get(id)
            local tile = ZoneTile.new({
                zone = { id = id, label = record and record.name or id },
                snapshot = registry.snapshot(id) or { available = false },
            })
            tile:setBounds(tileX, tileY, tileW, tileH)
            self:add(tile)
            self.tiles[#self.tiles + 1] = { component = tile, moduleId = id }
        end
    end
end

function DisplayView:onLayout(x, y, w, h)
    self.tiles = {}
    self.valueRows = {}
    self.chart = nil

    -- A view can also just pin an existing screen; navigation handles that.
    local ids = self:matchingModules()

    if #ids == 0 then
        self:layoutWaiting(x, y, w, h)
    elseif #ids == 1 then
        self:layoutSingle(ids[1], x, y, w, h)
    else
        self:layoutGrid(ids, x, y, w, h)
    end
end

function DisplayView:update()
    for _, tile in ipairs(self.tiles or {}) do
        tile.component:setSnapshot(registry.snapshot(tile.moduleId) or { available = false })
    end

    for _, row in ipairs(self.valueRows or {}) do
        local snapshot = registry.snapshot(row.moduleId)
        for _, metric in ipairs((snapshot and snapshot.metrics) or {}) do
            if metric.id == row.metric.id then
                row.component:setText(registry.formatMetric(metric))
                break
            end
        end
    end

    if self.chart and self.chartSeriesId then
        self.chart:setSeries(history.series(self.chartSeriesId))
        return
    end

    -- A chart can only be placed once there is history to draw. Ask for one
    -- relayout when the first samples show up, and only one.
    if self.chartRequested then return end
    for _, id in ipairs(self:matchingModules()) do
        local snapshot = registry.snapshot(id)
        for _, metric in ipairs((snapshot and snapshot.metrics) or {}) do
            if history.has(id .. "." .. metric.id) then
                self.chartRequested = true
                self:requestLayout()
                return
            end
        end
    end
end

return DisplayView

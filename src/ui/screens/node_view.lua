--- What a node shows on its own monitor.
--
-- A node has one job - the energy cells, the drives, the farm in front of it -
-- so its screen is that job in full rather than a tile per module. The grid a
-- display draws is the wrong shape here: it summarises several computers, and
-- a node only has itself to talk about.
--
-- Three bands, tallest first when there is room for them:
--
--   totals     the module's gauge and its headline numbers
--   history    the first metric that has samples, as a chart
--   devices    the per-device breakdown, scrollable, touchable
--
-- The breakdown is `snapshot.detail`, the same list the master receives, so
-- the screen standing next to the cells and the screen on the other side of
-- the base are showing the same thing from the same data.

local class = require("core.class")
local util = require("core.util")
local bus = require("core.event_bus")
local Screen = require("ui.screen")
local Label = require("ui.components.label")
local List = require("ui.components.list")
local Modal = require("ui.components.modal")
local ProgressBar = require("ui.components.progress_bar")
local Sparkline = require("ui.components.sparkline")
local registry = require("modules.registry")
local history = require("services.history")
local summary = require("ui.summary")
local theme = require("ui.theme")

local NodeView = class(Screen)

--- Rows the three bands need before the chart is worth drawing at all.
local MIN_LIST_ROWS = 3
local MIN_CHART_ROWS = 3
local MAX_CHART_ROWS = 5

function NodeView:init(params)
    Screen.init(self, params)
    self.title = params.title or "NODE"
    self.moduleIndex = 1
end

function NodeView:onMount()
    -- A module appearing changes the layout, not just the numbers: a cell
    -- plugged in while nobody was looking should show up on its own.
    local relayout = function() self:requestLayout() end
    self:onCleanup(bus.on("module.registered", relayout, { owner = "screen:node_view" }))
    self:onCleanup(bus.on("module.unregistered", relayout, { owner = "screen:node_view" }))
end

---------------------------------------------------------------------------
-- Which module this node is about
---------------------------------------------------------------------------

--- Modules worth putting on the screen, best candidate first.
--
-- `system` is deliberately last: it is true of every computer and is never
-- what somebody walked over to the monitor to read.
function NodeView:candidates()
    local withDetail, withGauge, rest, system = {}, {}, {}, {}

    for _, record in ipairs(registry.all()) do
        local snapshot = registry.snapshot(record.id) or {}
        if record.id == "system" then
            system[#system + 1] = record.id
        elseif snapshot.detail then
            withDetail[#withDetail + 1] = record.id
        elseif snapshot.gauge then
            withGauge[#withGauge + 1] = record.id
        else
            rest[#rest + 1] = record.id
        end
    end

    local ordered = {}
    for _, group in ipairs({ withDetail, withGauge, rest, system }) do
        for _, id in ipairs(group) do ordered[#ordered + 1] = id end
    end
    return ordered
end

function NodeView:moduleId()
    local ordered = self:candidates()
    if #ordered == 0 then return nil end
    if self.moduleIndex > #ordered then self.moduleIndex = 1 end
    return ordered[self.moduleIndex]
end

function NodeView:snapshot()
    local id = self:moduleId()
    return (id and registry.snapshot(id)) or {}
end

function NodeView:rows()
    local snapshot = self:snapshot()
    if snapshot.detail and snapshot.detail.rows then return snapshot.detail.rows end

    -- No breakdown: the metrics themselves are the next best list, so a module
    -- without devices still fills the space with something readable.
    local rows = {}
    for _, metric in ipairs(snapshot.metrics or {}) do
        rows[#rows + 1] = {
            name = metric.label,
            value = registry.formatMetric(metric),
            metricId = metric.id,
        }
    end
    return rows
end

--- The first metric with samples behind it, which is what the chart draws.
function NodeView:series()
    local id = self:moduleId()
    if not id then return nil end

    for _, metric in ipairs(self:snapshot().metrics or {}) do
        local seriesId = id .. "." .. metric.id
        if history.has(seriesId) then
            return seriesId, metric
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

local function rowColor(row)
    if row.status then return theme.statusColor(row.status) end
    if type(row.percent) ~= "number" then return theme.get("text") end
    if row.percent <= 0.10 then return theme.get("statusError") end
    if row.percent <= 0.25 then return theme.get("statusWarn") end
    return theme.get("statusOk")
end

local function renderRow(row, width)
    local percent = type(row.percent) == "number" and util.formatPercent(row.percent) or ""
    local right = util.padLeft(percent, 6) .. util.padLeft(row.value or "", 10)
    local name = util.truncate(row.name or "?", math.max(6, width - #right - 1))

    return {
        text = util.padRight(name, width - #right) .. right,
        fg = rowColor(row),
    }
end

function NodeView:openRow(row)
    -- A metric row leads to its history; a device row has no history of its
    -- own, so it opens what the node knows about that device.
    if row.metricId then
        self.context.navigation.push("metric_detail", {
            moduleId = self:moduleId(), metricId = row.metricId,
        })
        return
    end

    local lines = {}
    for _, field in ipairs(row.fields or {}) do
        lines[#lines + 1] = util.padRight(field.label .. ":", 11) .. tostring(field.value)
    end
    if #lines == 0 then lines[1] = "No detail reported for this device." end

    self:openModal(Modal.new({
        title = util.truncate(row.name or "device", 24),
        message = table.concat(lines, "\n"),
        buttons = { { label = "CLOSE" } },
        onClose = function() self:closeModal() end,
    }))
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------

function NodeView:figuresText(hasGauge)
    return summary.headline(self:snapshot(), {
        hasGauge = hasGauge,
        rowCount = #self:rows(),
        limit = 3,
    })
end

function NodeView:onLayout(x, y, w, h)
    local width = w - 2
    self.listWidth = width
    local id = self:moduleId()

    if not id then
        local waiting = Label.new({
            text = "No modules are running on this computer.\n\n"
                .. "'setup' chooses what this node is, and config/modules.lua\n"
                .. "what a custom one loads.",
            wrap = true, fg = "textDim", align = "center",
        })
        waiting:setBounds(x + 1, y + math.max(0, math.floor(h / 2) - 2), width, 5)
        self:add(waiting)
        return
    end

    local record = registry.get(id)
    local snapshot = self:snapshot()

    -- Buttons cost five rows; on a monitor that small the data matters more.
    local actionRows = h >= 18 and Screen.ACTION_BAR or 0
    local body = h - actionRows

    ------------------------------------------------------------ totals
    self.nameLabel = Label.new({
        text = util.truncate((record and record.name or id):upper(), width - 12),
        fg = "text",
    })
    self.nameLabel:setBounds(x + 1, y, width - 12, 1)
    self:add(self.nameLabel)

    self.statusLabel = Label.new({
        text = snapshot.statusText or tostring(snapshot.status):upper(),
        fg = "text", align = "right",
    })
    self.statusLabel:setBounds(x + 1, y, width, 1)
    self:add(self.statusLabel)

    local gaugeValue = summary.gauge(snapshot)
    local hasGauge = gaugeValue ~= nil
    if hasGauge then
        self.gauge = ProgressBar.new({
            value = gaugeValue,
            thresholds = { warn = 0.25, critical = 0.10 },
        })
        self.gauge:setBounds(x + 1, y + 1, width, 1)
        self:add(self.gauge)
    else
        self.gauge = nil
    end

    self.figures = Label.new({ text = "", fg = "textDim" })
    self.figures:setBounds(x + 1, y + (hasGauge and 2 or 1), width, 1)
    self.figuresHasGauge = hasGauge
    self:add(self.figures)

    ------------------------------------------------------------ bands
    local top = y + (hasGauge and 4 or 3)
    local bottom = y + body - 1
    local available = bottom - top + 1

    -- The chart only earns its rows once the device list still has some.
    local chartRows = 0
    local seriesId, seriesMetric = self:series()
    if seriesId then
        local spare = available - (MIN_LIST_ROWS + 1) - 2
        if spare >= MIN_CHART_ROWS then
            chartRows = math.min(MAX_CHART_ROWS, spare)
        end
    end

    if chartRows > 0 then
        local caption = Label.new({
            text = util.truncate((seriesMetric.label or "value") .. " over time", width),
            fg = "textDim",
        })
        caption:setBounds(x + 1, top, width, 1)
        self:add(caption)

        self.chart = Sparkline.new({ series = history.series(seriesId), h = chartRows })
        self.chart:setBounds(x + 1, top + 1, width, chartRows)
        self.chartSeriesId = seriesId
        self:add(self.chart)

        top = top + chartRows + 2
    else
        self.chart, self.chartSeriesId = nil, nil
    end

    ------------------------------------------------------------ devices
    local listHeight = bottom - top
    if listHeight < 2 then return end

    local columns = (snapshot.detail and snapshot.detail.columns) or {}
    local header = Label.new({
        text = util.padRight(snapshot.detail and "DEVICE" or "METRIC", width - 16)
            .. util.padLeft(columns[1] or "", 6)
            .. util.padLeft(columns[2] or "VALUE", 10),
        fg = "textDim",
    })
    header:setBounds(x + 1, top, width, 1)
    self:add(header)

    self.list = List.new({
        items = self:rows(),
        renderItem = function(row) return renderRow(row, width) end,
        emptyText = "Nothing connected that this module can read.",
        onSelect = function(row) self:openRow(row) end,
    })
    self.list:setBounds(x + 1, top + 1, width, listHeight)
    self:add(self.list)

    ------------------------------------------------------------ actions
    if actionRows == 0 then return end

    local actions = {}
    if #self:candidates() > 1 then
        actions[#actions + 1] = { label = "NEXT", style = "primary", run = function()
            self.moduleIndex = (self.moduleIndex % #self:candidates()) + 1
            self:requestLayout()
        end }
    end
    actions[#actions + 1] = { label = "MODULES", run = function()
        self.context.navigation.push("module_list", {})
    end }
    actions[#actions + 1] = { label = "REDNET", run = function()
        self.context.navigation.push("network", {})
    end }

    self:actionBar(x + 1, y, width, h, actions)
end

function NodeView:update()
    local snapshot = self:snapshot()

    if self.statusLabel then
        self.statusLabel:setText(snapshot.statusText or tostring(snapshot.status):upper())
        self.statusLabel.fg = theme.statusColor(snapshot.status)
    end
    if self.gauge then
        local gaugeValue = summary.gauge(snapshot)
        if gaugeValue then self.gauge:setValue(gaugeValue) end
    end
    if self.figures then
        self.figures:setText(util.truncate(self:figuresText(self.figuresHasGauge),
            self.listWidth or 40))
    end
    if self.list then self.list:setItems(self:rows()) end

    if self.chart and self.chartSeriesId then
        self.chart:setSeries(history.series(self.chartSeriesId))
        return
    end

    -- The chart could not be placed because there was no history yet. Ask for
    -- one relayout when the first samples land, and only one.
    if self.chartRequested then return end
    if self:series() then
        self.chartRequested = true
        self:requestLayout()
    end
end

return NodeView

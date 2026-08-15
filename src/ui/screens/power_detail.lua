--- Totals on top, one scrollable row per device below.
--
-- The generic detail screen renders a flat list of metrics, which turns into a
-- wall of gauges once a base has a dozen cells and reactors. This screen keeps
-- the aggregate visible while the per-device breakdown scrolls underneath.
--
-- Everything is read from the module's snapshot - its metrics for the totals,
-- its `detail` for the devices - and never from the live module object. That is
-- the whole reason a node's cells can be listed on the master: the snapshot is
-- what crosses rednet, so a remote power module lands here with its breakdown
-- intact instead of degrading to four numbers.

local class = require("core.class")
local util = require("core.util")
local Screen = require("ui.screen")
local Panel = require("ui.components.panel")
local Label = require("ui.components.label")
local List = require("ui.components.list")
local Modal = require("ui.components.modal")
local ProgressBar = require("ui.components.progress_bar")
local registry = require("modules.registry")
local theme = require("ui.theme")

local PowerDetail = class(Screen)

local SUMMARY_HEIGHT = 5

function PowerDetail:init(params)
    Screen.init(self, params)
    self.moduleId = params.moduleId or "power"
    local record = registry.get(self.moduleId)
    self.title = record and record.name or "Power"
end

--- The last snapshot: local modules rebuild it on demand, remote ones read the
--- one their node sent.
function PowerDetail:snapshot()
    return registry.snapshot(self.moduleId) or {}
end

function PowerDetail:rows()
    local detail = self:snapshot().detail
    return (detail and detail.rows) or {}
end

--- A named metric out of the snapshot, formatted the way its owner meant it.
function PowerDetail:metric(id)
    for _, metric in ipairs(self:snapshot().metrics or {}) do
        if metric.id == id then return metric end
    end
    return nil
end

function PowerDetail:metricText(id, fallback)
    local metric = self:metric(id)
    if not metric then return fallback end
    return registry.formatMetric(metric)
end

--- The charge to draw on the gauge, as a fraction.
function PowerDetail:charge()
    local metric = self:metric("charge")
    local value = metric and (metric.percent or metric.value) or nil
    if type(value) ~= "number" then return 0 end
    if value > 1 then value = value / 100 end
    return util.clamp(value, 0, 1)
end

local function rowColor(row)
    if row.status then return theme.statusColor(row.status) end
    local percent = row.percent or 0
    if percent <= 0.10 then return theme.get("statusError") end
    if percent <= 0.25 then return theme.get("statusWarn") end
    return theme.get("statusOk")
end

local function renderRow(row, width)
    local percent = row.percent and util.formatPercent(row.percent) or "-"
    local right = util.padLeft(percent, 6) .. util.padLeft(row.value or "", 9)
    local name = util.truncate(row.name or "?", math.max(6, width - #right - 1))

    return {
        text = util.padRight(name, width - #right) .. right,
        fg = rowColor(row),
    }
end

function PowerDetail:showRow(row)
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

function PowerDetail:onLayout(x, y, w, h)
    local detail = self:snapshot().detail

    ---------------------------------------------------------------- summary
    local summary = Panel.new({ title = "Total", bg = "background", fg = "border" })
    summary:setBounds(x, y, w, SUMMARY_HEIGHT)
    self:add(summary)

    local cx, cy, cw = summary:contentBounds()

    self.gauge = ProgressBar.new({
        value = self:charge(),
        thresholds = { warn = 0.25, critical = 0.10 },
    })
    self.gauge:setBounds(cx, cy, cw, 1)
    self:add(self.gauge)

    self.storedLabel = Label.new({ text = "", fg = "textDim" })
    self.storedLabel:setBounds(cx, cy + 1, cw, 1)
    self:add(self.storedLabel)

    self.flowLabel = Label.new({ text = "", fg = "textDim", align = "right" })
    self.flowLabel:setBounds(cx, cy + 2, cw, 1)
    self:add(self.flowLabel)

    ---------------------------------------------------------------- devices
    local listY = y + SUMMARY_HEIGHT
    local listWidth = w - 2
    local listHeight = h - SUMMARY_HEIGHT - 1
    if listHeight < 2 then return end

    local columns = (detail and detail.columns) or {}
    local header = Label.new({
        text = util.padRight("DEVICE", listWidth - 15)
            .. util.padLeft(columns[1] or "CHARGE", 6)
            .. util.padLeft(columns[2] or "STORED", 9),
        fg = "textDim",
    })
    header:setBounds(x + 1, listY, listWidth, 1)
    self:add(header)

    self.list = List.new({
        items = self:rows(),
        renderItem = function(row) return renderRow(row, listWidth) end,
        emptyText = "No devices reported.",
        onSelect = function(row) self:showRow(row) end,
    })
    self.list:setBounds(x + 1, listY + 1, listWidth, listHeight)
    self:add(self.list)
end

function PowerDetail:update()
    if self.gauge then self.gauge:setValue(self:charge()) end

    if self.storedLabel then
        self.storedLabel:setText(("%s / %s  across %d device(s)"):format(
            self:metricText("stored", "?"), self:metricText("capacity", "?"), #self:rows()))
    end

    if self.flowLabel then
        self.flowLabel:setText(self:metric("flow")
            and self:metricText("flow", "")
            or "no flow reported")
    end

    if self.list then self.list:setItems(self:rows()) end
end

return PowerDetail

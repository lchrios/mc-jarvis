--- Power detail: totals on top, one scrollable row per device below.
--
-- The generic detail screen renders a flat list of metrics, which turns into a
-- wall of gauges once a base has a dozen cells and reactors. This screen keeps
-- the aggregate visible while the per-device breakdown scrolls underneath.
--
-- Registered by the power module through `detailScreen`, so nothing in the core
-- knows it exists.

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

--- Live data straight from the module instance.
function PowerDetail:data()
    local record = registry.get(self.moduleId)
    return (record and record.def) or {}
end

local function sourceColor(percentage)
    if percentage <= 0.10 then return theme.get("statusError") end
    if percentage <= 0.25 then return theme.get("statusWarn") end
    return theme.get("statusOk")
end

local function renderSource(source, width)
    local percent = util.formatPercent(source.percentage or 0)
    local stored = util.formatNumber(source.stored or 0)
    local right = util.padLeft(percent, 6) .. util.padLeft(stored, 9)
    local name = util.truncate(source.name or "?", math.max(6, width - #right - 1))

    return {
        text = util.padRight(name, width - #right) .. right,
        fg = sourceColor(source.percentage or 0),
    }
end

function PowerDetail:showSource(source)
    local lines = {
        "Stored:   " .. util.formatNumber(source.stored or 0) .. " FE",
        "Capacity: " .. util.formatNumber(source.capacity or 0) .. " FE",
        "Charge:   " .. util.formatPercent(source.percentage or 0),
    }
    if source.rate then lines[#lines + 1] = "Transfer: " .. util.formatNumber(source.rate) .. " FE/t" end
    if source.generation then
        lines[#lines + 1] = "Output:   " .. util.formatNumber(source.generation) .. " FE/t"
    end
    if source.temperature then lines[#lines + 1] = "Temp:     " .. tostring(source.temperature) end
    if source.fuel then
        lines[#lines + 1] = "Fuel:     " .. util.formatPercent(source.fuel.percentage or 0)
    end
    lines[#lines + 1] = "Adapter:  " .. tostring(source.kind or "energy")

    self:openModal(Modal.new({
        title = util.truncate(source.name or "device", 24),
        message = table.concat(lines, "\n"),
        buttons = { { label = "CLOSE" } },
        onClose = function() self:closeModal() end,
    }))
end

function PowerDetail:onLayout(x, y, w, h)
    local data = self:data()

    ---------------------------------------------------------------- summary
    local summary = Panel.new({ title = "Total", bg = "background", fg = "border" })
    summary:setBounds(x, y, w, SUMMARY_HEIGHT)
    self:add(summary)

    local cx, cy, cw = summary:contentBounds()

    self.gauge = ProgressBar.new({
        value = data.percentage or 0,
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

    local header = Label.new({
        text = util.padRight("DEVICE", listWidth - 15)
            .. util.padLeft("CHARGE", 6) .. util.padLeft("STORED", 9),
        fg = "textDim",
    })
    header:setBounds(x + 1, listY, listWidth, 1)
    self:add(header)

    self.list = List.new({
        items = data.sources or {},
        renderItem = function(source) return renderSource(source, listWidth) end,
        emptyText = "No energy peripherals detected.",
        onSelect = function(source) self:showSource(source) end,
    })
    self.list:setBounds(x + 1, listY + 1, listWidth, listHeight)
    self:add(self.list)
end

function PowerDetail:update()
    local data = self:data()

    if self.gauge then self.gauge:setValue(data.percentage or 0) end

    if self.storedLabel then
        self.storedLabel:setText(("%s / %s FE  across %d device(s)"):format(
            util.formatNumber(data.stored or 0),
            util.formatNumber(data.capacity or 0),
            #(data.sources or {})))
    end

    if self.flowLabel then
        self.flowLabel:setText(data.throughput
            and (util.formatNumber(data.throughput) .. " FE/t")
            or "no flow reported")
    end

    if self.list then self.list:setItems(data.sources or {}) end
end

return PowerDetail

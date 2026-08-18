--- A farm: how fast it is going, how full it is, and what is in it.
--
-- The generic detail screen lists metrics, which for a farm answers the least
-- interesting question. Standing in front of a mob farm the questions are, in
-- order: is it running, is the buffer about to back up, is the rate what it was
-- an hour ago, and is the buffer full of the drop I want or of rotten flesh.
-- This screen is those four, top to bottom.
--
-- Every number comes from the module snapshot, so a farm running on a node
-- looks the same on the master - and START/STOP there is forwarded over rednet
-- by the proxy rather than pressed locally.

local class = require("core.class")
local util = require("core.util")
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

local FarmDetail = class(Screen)

local MIN_LIST_ROWS = 3
local MIN_CHART_ROWS = 3
local MAX_CHART_ROWS = 6

function FarmDetail:init(params)
    Screen.init(self, params)
    self.moduleId = params.moduleId
    local record = registry.get(self.moduleId)
    self.title = record and record.name or tostring(self.moduleId)
end

function FarmDetail:snapshot()
    return registry.snapshot(self.moduleId) or {}
end

function FarmDetail:rows()
    local detail = self:snapshot().detail
    return (detail and detail.rows) or {}
end

--- The rate over time, which is the series a farm is actually judged by.
function FarmDetail:seriesId()
    local rate = tostring(self.moduleId) .. ".rate"
    if history.has(rate) then return rate, "Items/min" end

    local buffer = tostring(self.moduleId) .. ".buffer"
    if history.has(buffer) then return buffer, "Buffer" end
    return nil
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

local function renderRow(row, width)
    local share = type(row.percent) == "number" and util.formatPercent(row.percent) or ""
    local right = util.padLeft(share, 6) .. util.padLeft(row.value or "", 10)
    local name = util.truncate(row.name or "?", math.max(6, width - #right - 1))

    -- An ignored item is dimmed rather than hidden: it is taking up the buffer
    -- either way, and that is worth seeing when the rate looks wrong.
    local colour = row.status == "idle" and theme.get("textDim") or theme.get("text")

    return {
        text = util.padRight(name, width - #right) .. right,
        fg = colour,
    }
end

function FarmDetail:showRow(row)
    local lines = {}
    for _, field in ipairs(row.fields or {}) do
        lines[#lines + 1] = util.padRight(field.label .. ":", 10) .. tostring(field.value)
    end
    if #lines == 0 then lines[1] = "Nothing else is known about this item." end

    self:openModal(Modal.new({
        title = util.truncate(row.name or "item", 24),
        message = table.concat(lines, "\n"),
        buttons = { { label = "CLOSE" } },
        onClose = function() self:closeModal() end,
    }))
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------

function FarmDetail:actionSpecs()
    local specs = {}

    for _, action in ipairs(registry.actions(self.moduleId)) do
        specs[#specs + 1] = {
            label = action.label,
            style = action.style,
            enabled = action.enabled,
            run = function()
                local ok, err = registry.invoke(self.moduleId, action.id)
                if not ok then self:say(tostring(err)) end
                self:requestLayout()
            end,
        }
    end

    -- Only for a farm this computer owns: the editor writes to local storage,
    -- and a farm reported by a node is configured on that node.
    local record = registry.get(self.moduleId)
    if record and not record.def.remote then
        specs[#specs + 1] = { label = "EDIT", run = function()
            self.context.navigation.push("farm_edit", { farmId = self.moduleId })
        end }
    end

    return specs
end

function FarmDetail:say(message)
    self.message = message
    self.messageAt = util.nowMs()
    self:invalidate()
end

function FarmDetail:onLayout(x, y, w, h)
    local width = w - 2
    self.rowWidth = width
    local snapshot = self:snapshot()

    local specs = self:actionSpecs()
    local actionRows = (#specs > 0 and h >= 18) and Screen.ACTION_BAR or 0
    local body = h - actionRows

    ------------------------------------------------------------ header
    self.statusLabel = Label.new({
        text = snapshot.statusText or tostring(snapshot.status):upper(),
        fg = "text",
    })
    self.statusLabel:setBounds(x + 1, y, 14, 1)
    self:add(self.statusLabel)

    self.figures = Label.new({ text = "", fg = "textDim", align = "right" })
    self.figures:setBounds(x + 15, y, width - 14, 1)
    self.figuresWidth = width - 14
    self:add(self.figures)

    self.gauge = ProgressBar.new({
        value = summary.gauge(snapshot) or 0,
        -- A farm buffer is the other way round from a battery: full is bad.
        thresholds = { warn = 0.25, critical = 0.10 },
        invertThresholds = true,
    })
    self.gauge:setBounds(x + 1, y + 1, width, 1)
    self:add(self.gauge)

    self.bufferLabel = Label.new({ text = "", fg = "textDim" })
    self.bufferLabel:setBounds(x + 1, y + 2, width, 1)
    self:add(self.bufferLabel)

    ------------------------------------------------------------ bands
    local top = y + 4
    local bottom = y + body - 1
    local available = bottom - top + 1

    local chartRows = 0
    local seriesId, seriesLabel = self:seriesId()
    if seriesId then
        local spare = available - (MIN_LIST_ROWS + 1) - 2
        if spare >= MIN_CHART_ROWS then chartRows = math.min(MAX_CHART_ROWS, spare) end
    end

    if chartRows > 0 then
        local caption = Label.new({
            text = util.truncate((seriesLabel or "rate") .. " over time", width),
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

    ------------------------------------------------------------ buffer
    local listHeight = bottom - top
    if listHeight < 2 then return end

    local header = Label.new({
        text = util.padRight("IN THE BUFFER", width - 16)
            .. util.padLeft("SHARE", 6) .. util.padLeft("COUNT", 10),
        fg = "textDim",
    })
    header:setBounds(x + 1, top, width, 1)
    self:add(header)

    self.list = List.new({
        items = self:rows(),
        renderItem = function(row) return renderRow(row, width) end,
        emptyText = "The output buffer is empty.",
        onSelect = function(row) self:showRow(row) end,
    })
    self.list:setBounds(x + 1, top + 1, width, listHeight)
    self:add(self.list)

    ------------------------------------------------------------ actions
    if actionRows > 0 then self:actionBar(x + 1, y, width, h, specs) end
end

function FarmDetail:update()
    local snapshot = self:snapshot()

    if self.statusLabel then
        self.statusLabel:setText(snapshot.statusText or tostring(snapshot.status):upper())
        self.statusLabel.fg = theme.statusColor(snapshot.status)
    end

    if self.gauge then self.gauge:setValue(summary.gauge(snapshot) or 0) end

    if self.figures then
        local fresh = self.message and (util.nowMs() - (self.messageAt or 0)) / 1000 < 6
        if not fresh then self.message = nil end
        self.figures:setText(util.truncate(
            self.message or summary.headline(snapshot, { hasGauge = true, limit = 2 }),
            self.figuresWidth or 40))
        self.figures.fg = self.message and "statusWarn" or "textDim"
    end

    if self.bufferLabel then
        local buffer
        for _, metric in ipairs(snapshot.metrics or {}) do
            if metric.id == "slots" then buffer = registry.formatMetric(metric) end
        end
        self.bufferLabel:setText(("buffer %s%s"):format(
            util.formatPercent(summary.gauge(snapshot) or 0),
            buffer and ("   " .. buffer .. " slots") or ""))
    end

    if self.list then self.list:setItems(self:rows()) end

    if self.chart and self.chartSeriesId then
        self.chart:setSeries(history.series(self.chartSeriesId))
        return
    end

    if self.chartRequested then return end
    if self:seriesId() then
        self.chartRequested = true
        self:requestLayout()
    end
end

return FarmDetail

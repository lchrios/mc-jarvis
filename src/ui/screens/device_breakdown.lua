--- Totals on top, one scrollable row per device below.
--
-- The generic detail screen renders a flat list of metrics, which turns into a
-- wall of gauges once a base has a dozen cells or a wall of barrels. This
-- screen keeps the aggregate visible while the per-device breakdown scrolls
-- underneath, and a touch opens what the module knows about one device.
--
-- Everything is read from the module's snapshot - its metrics for the totals,
-- its `detail` for the devices - and never from the live module object. That
-- is what lets a node's cells be listed on the master: the snapshot is what
-- crosses rednet, so a remote module lands here with its breakdown intact
-- instead of degrading to four numbers. It is also why one screen serves
-- power, storage and anything else that reports `detail`.

local class = require("core.class")
local util = require("core.util")
local Screen = require("ui.screen")
local Panel = require("ui.components.panel")
local Label = require("ui.components.label")
local List = require("ui.components.list")
local Modal = require("ui.components.modal")
local ProgressBar = require("ui.components.progress_bar")
local registry = require("modules.registry")
local summary = require("ui.summary")
local theme = require("ui.theme")

local DeviceBreakdown = class(Screen)

local SUMMARY_HEIGHT = 5

function DeviceBreakdown:init(params)
    Screen.init(self, params)
    self.moduleId = params.moduleId or "power"
    local record = registry.get(self.moduleId)
    self.title = record and record.name or self.moduleId
end

--- The last snapshot: local modules rebuild it on demand, remote ones read the
--- one their node sent.
function DeviceBreakdown:snapshot()
    return registry.snapshot(self.moduleId) or {}
end

function DeviceBreakdown:rows()
    local detail = self:snapshot().detail
    return (detail and detail.rows) or {}
end

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

function DeviceBreakdown:showRow(row)
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

--- Say something in place of the figures for a few seconds. A refused action
--- has to land somewhere the eye already is.
function DeviceBreakdown:say(message)
    self.message = message
    self.messageAt = util.nowMs()
    self:invalidate()
end

--- The module's actions, ready for the bar. Empty for most modules.
function DeviceBreakdown:actionSpecs()
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
    return specs
end

function DeviceBreakdown:onLayout(x, y, w, h)
    local snapshot = self:snapshot()
    local detail = snapshot.detail

    ---------------------------------------------------------------- summary
    local panel = Panel.new({ title = "Total", bg = "background", fg = "border" })
    panel:setBounds(x, y, w, SUMMARY_HEIGHT)
    self:add(panel)

    local cx, cy, cw = panel:contentBounds()
    local gauge = summary.gauge(snapshot)
    self.hasGauge = gauge ~= nil

    if self.hasGauge then
        self.gauge = ProgressBar.new({
            value = gauge,
            thresholds = { warn = 0.25, critical = 0.10 },
        })
        self.gauge:setBounds(cx, cy, cw, 1)
        self:add(self.gauge)
    else
        self.gauge = nil
    end

    self.figures = Label.new({ text = "", fg = "textDim" })
    self.figures:setBounds(cx, cy + (self.hasGauge and 1 or 0), cw, 1)
    self.figuresWidth = cw
    self:add(self.figures)

    self.countLabel = Label.new({ text = "", fg = "textDim", align = "right" })
    self.countLabel:setBounds(cx, cy + 2, cw, 1)
    self:add(self.countLabel)

    ---------------------------------------------------------------- devices
    -- A module's own actions belong here too: on a remote farm this is the
    -- screen its buffer is on, and START/STOP with the reason for pressing it
    -- in front of you beats going back out to the generic detail view.
    local specs = self:actionSpecs()
    local actionRows = (#specs > 0 and h >= 18) and Screen.ACTION_BAR or 0

    local listY = y + SUMMARY_HEIGHT
    local listWidth = w - 2
    local listHeight = h - SUMMARY_HEIGHT - 1 - actionRows
    if listHeight < 2 then return end

    local columns = (detail and detail.columns) or {}
    local header = Label.new({
        text = util.padRight("DEVICE", listWidth - 16)
            .. util.padLeft(columns[1] or "", 6)
            .. util.padLeft(columns[2] or "VALUE", 10),
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

    if actionRows > 0 then self:actionBar(x + 1, y, listWidth, h, specs) end
end

function DeviceBreakdown:update()
    local snapshot = self:snapshot()
    local rows = self:rows()

    if self.gauge then
        local gauge = summary.gauge(snapshot)
        if gauge then self.gauge:setValue(gauge) end
    end

    if self.figures then
        local fresh = self.message and (util.nowMs() - (self.messageAt or 0)) / 1000 < 6
        if not fresh then self.message = nil end

        self.figures:setText(util.truncate(self.message or
            summary.headline(snapshot, { hasGauge = self.hasGauge, rowCount = #rows, limit = 3 }),
            self.figuresWidth or 40))
        self.figures.fg = self.message and "statusWarn" or "textDim"
    end

    if self.countLabel then
        self.countLabel:setText(("%d device(s)"):format(#rows))
    end

    if self.list then self.list:setItems(rows) end
end

return DeviceBreakdown

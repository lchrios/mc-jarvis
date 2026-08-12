--- Generic detail view for any module.
--
-- Built entirely from the module snapshot (status, metrics, actions), so a new
-- module gets a working detail screen for free. A module can still supply its
-- own screen through `detailScreen` and the navigator will prefer that.

local class = require("core.class")
local util = require("core.util")
local bus = require("core.event_bus")
local Screen = require("ui.screen")
local Panel = require("ui.components.panel")
local Label = require("ui.components.label")
local Button = require("ui.components.button")
local ProgressBar = require("ui.components.progress_bar")
local Modal = require("ui.components.modal")
local Pager = require("ui.components.pager")
local registry = require("modules.registry")
local theme = require("ui.theme")

local ModuleDetail = class(Screen)

function ModuleDetail:init(params)
    Screen.init(self, params)
    self.moduleId = params.moduleId
    local record = registry.get(self.moduleId)
    self.title = record and record.name or tostring(self.moduleId)
    self.metricRows = {}
    self.gauges = {}
    -- Which page of metrics is showing. Survives the relayouts that follow a
    -- status change, so paging down does not snap back on the next poll.
    self.pageIndex = 1
end

--- Split entries into pages that each fit `available` rows.
-- Entries have different heights (a gauge is two rows), so pages are built by
-- filling until the next entry would not fit rather than by a fixed count.
local function paginate(entries, available)
    local pages = {}
    local index = 1

    while index <= #entries do
        local page = { first = index, last = index - 1 }
        local used = 0
        while index <= #entries and used + entries[index].height <= available do
            used = used + entries[index].height
            page.last = index
            index = index + 1
        end
        -- An entry taller than the whole area would loop forever; show it alone.
        if page.last < page.first then
            page.last = page.first
            index = index + 1
        end
        pages[#pages + 1] = page
    end

    if #pages == 0 then pages[1] = { first = 1, last = 0 } end
    return pages
end

function ModuleDetail:onMount()
    self:onCleanup(bus.on("module.status_changed", function(payload)
        if payload.id == self.moduleId then self:requestLayout() end
    end, { owner = "screen:module_detail" }))
end

--- Percent style metrics get a gauge, everything else a label row.
local function isGauge(metric)
    return metric.kind == "percent" or metric.percent ~= nil
end

local function gaugeFraction(metric)
    local value = metric.percent or metric.value or 0
    if value > 1 then value = value / 100 end
    return util.clamp(value, 0, 1)
end

function ModuleDetail:runAction(action)
    if action.confirm then
        self:openModal(Modal.new({
            title = "Confirm",
            message = type(action.confirm) == "string" and action.confirm
                or ("Run '" .. action.label .. "'?"),
            buttons = {
                { label = "CANCEL" },
                { label = "CONFIRM", style = "danger", onPress = function()
                    registry.invoke(self.moduleId, action.id)
                    self:requestLayout()
                end },
            },
            onClose = function() self:closeModal() end,
        }))
        return
    end

    local ok, err = registry.invoke(self.moduleId, action.id)
    if not ok then
        self:openModal(Modal.new({
            title = "Action failed",
            message = tostring(err),
            buttons = { { label = "CLOSE" } },
            onClose = function() self:closeModal() end,
        }))
    end
    self:requestLayout()
end

--- Move to another page of metrics.
function ModuleDetail:showPage(index)
    self.pageIndex = math.max(1, index)
    self:requestLayout()
end

function ModuleDetail:onLayout(x, y, w, h)
    self.metricRows = {}
    self.gauges = {}

    local record = registry.get(self.moduleId)
    if not record then
        self:add(Label.new({
            text = "Module '" .. tostring(self.moduleId) .. "' is not registered.",
            x = x + 2, y = y + 1, w = w - 4, h = 2, wrap = true, fg = "statusError",
        }))
        return
    end

    local snapshot = registry.snapshot(self.moduleId) or {}
    local actions = registry.actions(self.moduleId)

    -- Three-row buttons are a far easier touch target on a monitor than the
    -- single row they used to be; fall back to one row when space is tight.
    local buttonHeight = (#actions > 0 and h >= 12) and 3 or 1
    local actionRows = #actions > 0 and (buttonHeight + 1) or 0
    local bodyHeight = math.max(3, h - actionRows)

    local body = Panel.new({ title = record.name, bg = "background", fg = "border" })
    body:setBounds(x, y, w, bodyHeight)
    self:add(body)

    local cx, cy, cw = body:contentBounds()
    local row = cy

    -- Status line
    local statusLabel = Label.new({
        text = "Status: " .. (snapshot.statusText or "UNKNOWN"),
        fg = theme.statusColor(snapshot.status), bg = "background",
    })
    statusLabel:setBounds(cx, row, cw, 1)
    self:add(statusLabel)
    row = row + 2

    if snapshot.error then
        local errorLabel = Label.new({ text = "Error: " .. snapshot.error, wrap = true, fg = "statusError" })
        errorLabel:setBounds(cx, row, cw, 2)
        self:add(errorLabel)
        row = row + 3
    elseif not snapshot.available then
        local missing = table.concat(snapshot.missing or {}, ", ")
        local warning = Label.new({
            text = "Unavailable. Missing peripherals: " .. (missing ~= "" and missing or "unknown"),
            wrap = true, fg = "statusWarn",
        })
        warning:setBounds(cx, row, cw, 2)
        self:add(warning)
        row = row + 3
    end

    local lastRow = cy + (bodyHeight - 2) - 1

    -- Metrics are laid out as pageable entries: a module with more of them than
    -- the monitor can show must be scrollable, not silently truncated.
    local entries = {}
    for _, metric in ipairs(snapshot.metrics or {}) do
        local gauge = isGauge(metric) and cw >= 12
        entries[#entries + 1] = {
            metric = metric,
            gauge = gauge,
            height = gauge and 3 or 1,
        }
    end

    local available = lastRow - row + 1
    local totalHeight = 0
    for _, entry in ipairs(entries) do totalHeight = totalHeight + entry.height end

    -- Give up rows for the pager only when there is something to page through.
    local needsPager = totalHeight > available and available > Pager.HEIGHT + 1
    if needsPager then available = available - Pager.HEIGHT end

    local pages = paginate(entries, available)
    self.pageIndex = util.clamp(self.pageIndex, 1, #pages)
    local page = pages[self.pageIndex]

    for index = page.first, page.last do
        local entry = entries[index]
        local metric = entry.metric

        -- Every metric is a way in to its history.
        local function openHistory()
            self.context.navigation.push("metric_detail", {
                moduleId = self.moduleId, metricId = metric.id,
            })
        end

        if entry.gauge then
            local bar = ProgressBar.new({
                label = metric.label,
                value = gaugeFraction(metric),
                fill = metric.color,
            })
            bar:setBounds(cx, row, cw, 2)
            bar.onTouch = openHistory
            self:add(bar)
            self.gauges[#self.gauges + 1] = { component = bar, metric = metric }
        else
            -- A borderless, unfilled panel is just a touch area with children.
            local hotspot = Panel.new({
                border = false, fill = false, onTouch = function() openHistory() return true end,
            })
            hotspot:setBounds(cx, row, cw, 1)
            self:add(hotspot)

            local label = Label.new({ text = metric.label, fg = "textDim" })
            label:setBounds(cx, row, math.floor(cw / 2), 1)
            hotspot:add(label)

            local value = Label.new({
                text = registry.formatMetric(metric),
                align = "right", fg = metric.color or "text",
            })
            value:setBounds(cx + math.floor(cw / 2), row, cw - math.floor(cw / 2), 1)
            hotspot:add(value)

            self.metricRows[#self.metricRows + 1] = { component = value, metric = metric }
        end
        row = row + entry.height
    end

    if needsPager and #pages > 1 then
        local pager = Pager.new({
            onUp = function() self:showPage(self.pageIndex - 1) end,
            onDown = function() self:showPage(self.pageIndex + 1) end,
        })
        pager:setBounds(cx, lastRow - Pager.HEIGHT + 1, cw, Pager.HEIGHT)
        pager:setRange(page.first, page.last, #entries,
            self.pageIndex > 1, self.pageIndex < #pages)
        self:add(pager)
        self.pageCount = #pages
    else
        self.pageCount = 1
    end

    if #entries == 0 then
        local empty = Label.new({ text = "This module publishes no metrics.", fg = "textDim" })
        empty:setBounds(cx, row, cw, 1)
        self:add(empty)
    end

    -- Action row
    if actionRows > 0 then
        local buttonY = y + h - buttonHeight
        local slots = self.context and self.context.navigation
            and self.context.navigation.getRenderer():distribute(x + 1, w - 2, #actions, 1)
            or nil

        for index, action in ipairs(actions) do
            local button = Button.new({
                label = action.label,
                style = action.style,
                enabled = action.enabled and snapshot.available,
                onPress = function() self:runAction(action) end,
            })
            local slot = slots and slots[index]
            if slot then
                button:setBounds(slot.offset, buttonY, slot.size, buttonHeight)
            else
                button:setBounds(x + 1 + (index - 1) * 12, buttonY, 11, buttonHeight)
            end
            self:add(button)
        end
    end
end

function ModuleDetail:update()
    local snapshot = registry.snapshot(self.moduleId)
    if not snapshot then return end

    local metricsById = {}
    for _, metric in ipairs(snapshot.metrics or {}) do metricsById[metric.id] = metric end

    for _, row in ipairs(self.metricRows) do
        local fresh = metricsById[row.metric.id]
        if fresh then row.component:setText(registry.formatMetric(fresh)) end
    end
    for _, gauge in ipairs(self.gauges) do
        local fresh = metricsById[gauge.metric.id]
        if fresh then gauge.component:setValue(gaugeFraction(fresh)) end
    end
end

return ModuleDetail

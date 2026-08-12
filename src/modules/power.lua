--- Power module.
--
-- Aggregates every peripheral that exposes an energy capability (Powah cells,
-- Mekanism induction matrices, Thermal cells, AP Energy Detectors, ...). No
-- peripheral is required: with nothing attached the module reports
-- `unavailable` and the dashboard tile stays grey instead of erroring.
--
-- Nothing here is mod specific - all readings come from `adapters.energy` and
-- `adapters.powah`, so adding a new energy mod means adding an adapter.

local util = require("core.util")

local power = {}

power.id = "power"
power.name = "Power"
power.icon = "P"
power.description = "Aggregated energy storage and throughput"
power.pollInterval = 3

--- Thresholds are configurable per install (config/modules.lua -> settings.power).
local DEFAULTS = {
    lowPercentage = 0.25,
    criticalPercentage = 0.10,
    -- Charge has to climb this far back above a threshold before the alert
    -- clears, so a level sitting on the line does not flap every poll.
    recoverMargin = 0.05,
}

function power.setup(self, ctx)
    self.ctx = ctx
    self.settings = util.deepMerge(DEFAULTS, ctx.config.get("modules.settings.power", {}))
    self.sources = {}
    self.stored = 0
    self.capacity = 0
    self.percentage = 0
    self.throughput = nil
end

--- Collect every energy capable peripheral currently attached.
local function readSources(ctx)
    local readings = {}

    for _, adapter in ipairs(ctx.adapters.allOfKind("powah")) do
        local reading = adapter.read()
        reading.name = adapter.name()
        reading.kind = "powah"
        readings[reading.name] = reading
    end

    for _, adapter in ipairs(ctx.adapters.allOfKind("energy")) do
        local name = adapter.name()
        if not readings[name] then
            local reading = adapter.read()
            reading.name = name
            reading.kind = "energy"
            readings[name] = reading
        end
    end

    local list = {}
    for _, reading in pairs(readings) do list[#list + 1] = reading end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

function power.poll(self)
    local ctx = self.ctx
    if not ctx then return end

    self.sources = readSources(ctx)

    local stored, capacity, throughput = 0, 0, nil
    for _, source in ipairs(self.sources) do
        stored = stored + (source.stored or 0)
        capacity = capacity + (source.capacity or 0)
        if source.rate then throughput = (throughput or 0) + source.rate end
        if source.generation then throughput = (throughput or 0) + source.generation end
    end

    self.stored = stored
    self.capacity = capacity
    self.percentage = capacity > 0 and (stored / capacity) or 0
    self.throughput = throughput

    if #self.sources == 0 then
        ctx.alerts.clear("power.low")
        self.low, self.critical = false, false
        return
    end

    local margin = self.settings.recoverMargin
    local critical = self.percentage <=
        (self.settings.criticalPercentage + (self.critical and margin or 0))
    local low = self.percentage <=
        (self.settings.lowPercentage + (self.low and margin or 0))
    self.low, self.critical = low, critical

    ctx.alerts.toggle(low, {
        id = "power.low",
        source = power.id,
        severity = critical and "critical" or "warning",
        message = string.format("Stored power at %s", util.formatPercent(self.percentage)),
        data = { percentage = self.percentage },
    })

    if low then
        ctx.bus.emit("power.low", { percentage = self.percentage, critical = critical })
    end
end

function power.status(self)
    if #(self.sources or {}) == 0 then return "unavailable", "NO DEVICE" end
    if self.critical then return "error", "CRITICAL" end
    if self.low then return "warning", "LOW" end
    return "running", "OK"
end

function power.metrics(self)
    local metrics = {
        { id = "charge", label = "Charge", kind = "percent", value = self.percentage or 0 },
        { id = "stored", label = "Stored", value = self.stored or 0, unit = "FE" },
        { id = "capacity", label = "Capacity", value = self.capacity or 0, unit = "FE" },
        { id = "sources", label = "Sources", value = #(self.sources or {}) },
    }
    if self.throughput then
        metrics[#metrics + 1] = { id = "flow", label = "Throughput", value = self.throughput, unit = "FE/t" }
    end
    -- The per-device breakdown lives in the detail screen, not here: a dozen
    -- cells would bury the totals under a wall of gauges.
    return metrics
end

--- Custom detail view with a scrollable device breakdown.
function power.detailScreen(params)
    return require("ui.screens.power_detail").new(params)
end

function power.tile(self)
    if #(self.sources or {}) == 0 then
        return { lines = { "no energy", "peripherals" } }
    end
    return {
        lines = { util.formatNumber(self.stored or 0) .. " FE" },
        gauge = self.percentage or 0,
    }
end

return power

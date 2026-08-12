--- Rolling history of numeric metrics.
--
-- "Power is at 60%" matters less than "power is at 60% and falling". Every
-- numeric metric a module publishes is sampled into a fixed size ring buffer,
-- which is what the trend arrows and sparklines read.
--
--   history.series("power.charge")   -> { values = {...}, min, max, ... }
--   history.trend("power.charge")    -> "down", -0.12
--
-- Memory is bounded by design: `capacity` samples per series, oldest dropped.
-- Nothing here writes to disk; `services.snapshot` carries it if it wants to.

local util = require("core.util")
local bus = require("core.event_bus")

local history = {}

local settings = {
    enabled = true,
    capacity = 60,        -- samples kept per series
    minInterval = 1,      -- seconds; ignore samples arriving faster than this
}

local series = {}   -- [id] = { values = {}, times = {}, last = ms }

---------------------------------------------------------------------------

function history.configure(options)
    for key, value in pairs(options or {}) do settings[key] = value end
    return settings
end

function history.isEnabled() return settings.enabled end

--- Record one sample. Silently ignored when disabled or too soon.
function history.record(id, value, timestamp)
    if not settings.enabled then return false end
    if type(value) ~= "number" then return false end

    timestamp = timestamp or util.nowMs()
    local entry = series[id]

    if not entry then
        entry = { values = {}, times = {} }
        series[id] = entry
    elseif entry.last and (timestamp - entry.last) < settings.minInterval * 1000 then
        return false
    end

    entry.values[#entry.values + 1] = value
    entry.times[#entry.times + 1] = timestamp
    entry.last = timestamp

    while #entry.values > settings.capacity do
        table.remove(entry.values, 1)
        table.remove(entry.times, 1)
    end
    return true
end

--- @return table|nil { values, times, min, max, first, last, count }
function history.series(id)
    local entry = series[id]
    if not entry or #entry.values == 0 then return nil end

    local minimum, maximum = entry.values[1], entry.values[1]
    for _, value in ipairs(entry.values) do
        if value < minimum then minimum = value end
        if value > maximum then maximum = value end
    end

    return {
        values = entry.values,
        times = entry.times,
        min = minimum,
        max = maximum,
        first = entry.values[1],
        last = entry.values[#entry.values],
        count = #entry.values,
    }
end

function history.has(id)
    local entry = series[id]
    return entry ~= nil and #entry.values > 1
end

--- Direction of travel over the recorded window.
-- @return "up"|"down"|"flat", delta
function history.trend(id, threshold)
    local entry = history.series(id)
    if not entry or entry.count < 2 then return "flat", 0 end

    local delta = entry.last - entry.first
    -- Relative threshold: a 1 FE change in a million is not a trend.
    local scale = math.max(math.abs(entry.max), math.abs(entry.min), 1)
    if math.abs(delta) < (threshold or 0.02) * scale then return "flat", delta end
    return delta > 0 and "up" or "down", delta
end

function history.average(id)
    local entry = history.series(id)
    if not entry then return nil end
    local total = 0
    for _, value in ipairs(entry.values) do total = total + value end
    return total / entry.count
end

function history.ids()
    return util.sortedKeys(series)
end

--- Series belonging to one module, as { metricId = seriesId }.
function history.forModule(moduleId)
    local prefix = moduleId .. "."
    local found = {}
    for _, id in ipairs(history.ids()) do
        if id:sub(1, #prefix) == prefix then
            found[id:sub(#prefix + 1)] = id
        end
    end
    return found
end

function history.clear(id)
    if id then series[id] = nil else series = {} end
end

---------------------------------------------------------------------------
-- Persistence
---------------------------------------------------------------------------

function history.export() return util.deepCopy(series) end

function history.import(data)
    if type(data) ~= "table" then return false end
    series = {}
    for id, entry in pairs(data) do
        if type(entry) == "table" and type(entry.values) == "table" then
            series[id] = { values = entry.values, times = entry.times or {}, last = entry.last }
        end
    end
    return true
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

--- Sample every numeric metric a module publishes, each time it polls.
function history.start(ctx, options)
    history.configure(options)
    if not settings.enabled then return false end

    bus.on("module.polled", function(payload)
        local snapshot = ctx.modules.snapshot(payload.id)
        if not snapshot then return end

        for _, metric in ipairs(snapshot.metrics or {}) do
            local value = metric.value
            if metric.kind == "percent" and type(metric.percent) == "number" then
                value = metric.percent
            end
            if type(value) == "number" then
                history.record(payload.id .. "." .. metric.id, value)
            end
        end
    end, { owner = "history" })

    return true
end

function history.shutdown()
    bus.offOwner("history")
end

return history

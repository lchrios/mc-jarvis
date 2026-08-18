--- The headline figures of a module, as one line of text.
--
-- Shared by the screens that put a gauge and a device list around it - the
-- node's own view and the breakdown screen - because the rule for what to
-- leave out is the interesting part and it has to be the same in both:
--
--   the gauge already shows the percentage, and
--   the list already shows how many devices there are,
--
-- so a metric repeating either of those is spending width on something the eye
-- has read already. On a 3x2 monitor that is the difference between seeing the
-- throughput and not.

local registry = require("modules.registry")

local summary = {}

--- @param snapshot table a module snapshot
-- @param options table { hasGauge, rowCount, limit }
function summary.headline(snapshot, options)
    options = options or {}
    local limit = options.limit or 3
    local hasDetail = snapshot and snapshot.detail ~= nil

    local parts = {}
    for _, metric in ipairs((snapshot and snapshot.metrics) or {}) do
        local isPercent = metric.kind == "percent" or metric.percent ~= nil
        local isRowCount = hasDetail and options.rowCount ~= nil
            and metric.value == options.rowCount

        if not (options.hasGauge and isPercent) and not isRowCount then
            parts[#parts + 1] = metric.label .. ": " .. registry.formatMetric(metric)
        end
        if #parts >= limit then break end
    end

    return table.concat(parts, "   ")
end

--- The fraction a gauge should show: what the module put on its tile, and
--- failing that the first percentage among its metrics.
function summary.gauge(snapshot)
    if type(snapshot and snapshot.gauge) == "number" then return snapshot.gauge end

    for _, metric in ipairs((snapshot and snapshot.metrics) or {}) do
        local value = metric.percent or (metric.kind == "percent" and metric.value) or nil
        if type(value) == "number" then
            if value > 1 then value = value / 100 end
            return math.max(0, math.min(1, value))
        end
    end
    return nil
end

return summary

--- Alert service.
--
-- An alert is a *condition*, not a log line: raising the same id twice updates
-- the existing entry instead of creating a duplicate.
--
--   alerts.raise({ id = "power.low", source = "power",
--                  severity = "warning", message = "Power below 20%" })
--   alerts.clear("power.low")
--
-- Sinks (chat box, speaker, rednet) subscribe to `alert.raised` / `alert.cleared`
-- so this service stays free of peripheral knowledge.

local util = require("core.util")
local logger = require("core.logger")
local bus = require("core.event_bus")
local state = require("core.state")

local log = logger.scoped("alerts")

local alerts = {}

alerts.SEVERITIES = { info = 1, warning = 2, critical = 3 }

local active = {}     -- [id] = alert
local history = {}    -- most recent first
local historyLimit = 50

local function publish()
    local list = alerts.list()
    state.set("alerts.active", list)
    state.set("alerts.count", #list)
    state.set("alerts.worst", alerts.worstSeverity())
end

local function normaliseSeverity(severity)
    severity = tostring(severity or "info"):lower()
    if alerts.SEVERITIES[severity] then return severity end
    return "info"
end

--- Raise or update an alert.
-- @param alert table { id, source, severity, message, data }
function alerts.raise(alert)
    if type(alert) ~= "table" then error("alerts.raise expects a table", 2) end

    local id = alert.id or (tostring(alert.source or "system") .. "." .. util.slug(alert.message or "alert"))
    local severity = normaliseSeverity(alert.severity)
    local existing = active[id]

    local entry = {
        id = id,
        source = alert.source or "system",
        severity = severity,
        message = tostring(alert.message or id),
        data = alert.data,
        timestamp = existing and existing.timestamp or util.nowMs(),
        updated = util.nowMs(),
        count = existing and (existing.count + 1) or 1,
        active = true,
    }
    active[id] = entry

    if not existing then
        history[#history + 1] = entry
        if #history > historyLimit then table.remove(history, 1) end
        log.warn("[%s] %s", severity, entry.message)
        bus.emit("alert.raised", entry)
    elseif existing.message ~= entry.message or existing.severity ~= entry.severity then
        bus.emit("alert.updated", entry)
    end

    publish()
    return entry
end

--- Clear an alert by id. Safe to call when it is not active.
function alerts.clear(id)
    local entry = active[id]
    if not entry then return false end
    active[id] = nil
    entry.active = false
    entry.clearedAt = util.nowMs()
    log.info("cleared alert '%s'", id)
    bus.emit("alert.cleared", entry)
    publish()
    return true
end

--- Clear every alert raised by a source.
function alerts.clearSource(source)
    local cleared = 0
    for id, entry in pairs(active) do
        if entry.source == source then
            alerts.clear(id)
            cleared = cleared + 1
        end
    end
    return cleared
end

--- Convenience: raise when `condition` is true, clear otherwise.
function alerts.toggle(condition, alert)
    if condition then return alerts.raise(alert) end
    return alerts.clear(alert.id)
end

--- Active alerts, most severe and most recent first.
function alerts.list()
    local list = {}
    for _, entry in pairs(active) do list[#list + 1] = util.deepCopy(entry) end
    table.sort(list, function(a, b)
        local sa, sb = alerts.SEVERITIES[a.severity], alerts.SEVERITIES[b.severity]
        if sa ~= sb then return sa > sb end
        return a.updated > b.updated
    end)
    return list
end

function alerts.get(id) return active[id] end

function alerts.count() return util.count(active) end

--- Count of alerts at or above a severity.
function alerts.countAtLeast(severity)
    local threshold = alerts.SEVERITIES[normaliseSeverity(severity)]
    local total = 0
    for _, entry in pairs(active) do
        if alerts.SEVERITIES[entry.severity] >= threshold then total = total + 1 end
    end
    return total
end

function alerts.worstSeverity()
    local worst = nil
    local worstRank = 0
    for _, entry in pairs(active) do
        local rank = alerts.SEVERITIES[entry.severity]
        if rank > worstRank then worst, worstRank = entry.severity, rank end
    end
    return worst
end

--- Recently raised alerts including cleared ones.
function alerts.history() return util.deepCopy(history) end

function alerts.reset()
    active = {}
    history = {}
    publish()
end

return alerts

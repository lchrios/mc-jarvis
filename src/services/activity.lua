--- Recent notable events, for the dashboard feed.
--
-- The log is a debugging tool: too much, too technical, and mostly noise to
-- anyone standing in front of a monitor. This keeps only what a person would
-- want to see at a glance - things started, stopped, broke or came back.

local util = require("core.util")
local bus = require("core.event_bus")

local activity = {}

local entries = {}
local limit = 40

--- @param severity "info"|"warning"|"critical"|"ok"
function activity.add(text, severity, source)
    entries[#entries + 1] = {
        time = util.nowMs(),
        text = tostring(text),
        severity = severity or "info",
        source = source,
    }
    while #entries > limit do table.remove(entries, 1) end
    bus.emit("activity.added", entries[#entries])
    return entries[#entries]
end

--- Most recent first, which is the order a feed is read in.
function activity.recent(count)
    local result = {}
    for index = #entries, math.max(1, #entries - (count or limit) + 1), -1 do
        result[#result + 1] = entries[index]
    end
    return result
end

function activity.count() return #entries end

function activity.clear() entries = {} end

---------------------------------------------------------------------------

--- Subscribe to the events worth surfacing. Called once during boot.
function activity.start(ctx)
    limit = ctx.config.get("system.activity.limit", 40)

    bus.on("alert.raised", function(alert)
        activity.add(alert.message, alert.severity, alert.source)
    end, { owner = "activity" })

    bus.on("alert.cleared", function(alert)
        activity.add("cleared: " .. tostring(alert.message), "ok", alert.source)
    end, { owner = "activity" })

    bus.on("module.status_changed", function(payload)
        -- Only transitions worth reading; a module settling into `ready` at
        -- boot is not news.
        if payload.previous == nil or payload.previous == "unknown" then return end
        local record = ctx.modules.get(payload.id)
        local name = record and record.name or payload.id
        local severity = (payload.status == "error" and "critical")
            or (payload.status == "warning" and "warning")
            or (payload.status == "running" and "ok")
            or "info"
        activity.add(name .. " -> " .. tostring(payload.text or payload.status),
            severity, payload.id)
    end, { owner = "activity" })

    bus.on("module.action", function(payload)
        activity.add(payload.id .. ": " .. payload.action, "info", payload.id)
    end, { owner = "activity" })

    bus.on("node.offline", function(payload)
        activity.add("node " .. tostring(payload.node) .. " went silent", "warning", "network")
    end, { owner = "activity" })

    bus.on("peripheral.detached", function(payload)
        activity.add("unplugged " .. tostring(payload.name), "warning", "peripherals")
    end, { owner = "activity" })

    bus.on("peripheral.attached", function(payload)
        activity.add("attached " .. tostring(payload.name), "ok", "peripherals")
    end, { owner = "activity" })

    return activity
end

function activity.shutdown()
    bus.offOwner("activity")
end

return activity

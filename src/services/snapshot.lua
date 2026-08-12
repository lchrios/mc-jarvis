--- Periodic on-disk snapshot of what this computer knows.
--
-- Metrics are ephemeral and must not be written on every poll, but losing
-- everything on a chunk reload is worse. A snapshot every `interval` seconds is
-- the compromise: after a reboot the dashboard shows the last known values,
-- clearly marked as not live, instead of an empty screen.
--
-- Restored data is never presented as current: nodes come back marked offline
-- until they report again.

local util = require("core.util")
local logger = require("core.logger")
local state = require("core.state")
local persistence = require("services.persistence")
local history = require("services.history")

local log = logger.scoped("snapshot")

local snapshot = {}

snapshot.NAME = "snapshot"

--- Write the current state to disk. Cheap enough to call by hand.
function snapshot.save(ctx)
    local modules = {}
    for _, record in ipairs(ctx.modules.all()) do
        -- Remote proxies are rebuilt from node data; storing them twice would
        -- resurrect modules for nodes that no longer exist.
        if not record.def.remote then
            modules[record.id] = ctx.modules.snapshot(record.id)
        end
    end

    local ok = persistence.save(snapshot.NAME, {
        savedAt = util.nowMs(),
        version = ctx.version,
        node = ctx.identity and ctx.identity.name or nil,
        nodes = state.get("nodes", {}),
        modules = modules,
        -- Trends are worth keeping: rebuilding a window takes minutes.
        history = history.export(),
    })

    if ok then log.debug("snapshot written") end
    return ok
end

--- Load the last snapshot back into state. Call before modules start polling.
-- @return table|nil the restored record
function snapshot.restore(ctx)
    local record = persistence.load(snapshot.NAME, nil)
    if type(record) ~= "table" then return nil end

    -- Node data is stale by definition: it was written before this boot.
    local nodes = {}
    for name, node in pairs(record.nodes or {}) do
        node.online = false
        node.restored = true
        nodes[name] = node
    end
    state.set("nodes", nodes)
    state.set("system.restoredAt", record.savedAt)
    if record.history then history.import(record.history) end

    local age = record.savedAt and ((util.nowMs() - record.savedAt) / 1000) or nil
    log.info("restored a snapshot from %s ago (%d node(s))",
        age and util.formatDuration(age) or "?", util.count(nodes))
    return record
end

--- Start writing snapshots on a schedule.
function snapshot.start(ctx, interval)
    interval = interval or 60
    if interval <= 0 then
        log.info("snapshots disabled")
        return nil
    end

    return ctx.scheduler.every(interval, function() snapshot.save(ctx) end,
        { name = "snapshot.save", owner = "snapshot" })
end

return snapshot

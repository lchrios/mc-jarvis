--- Live metrics between nodes and the master.
--
-- Nodes own their data: each one polls its own peripherals and publishes a
-- snapshot on an interval. The master never reads a remote peripheral; it
-- listens, keeps the last snapshot per node in `state.nodes`, and exposes each
-- remote module through a proxy so the dashboard cannot tell local from remote.
--
--   node:   telemetry.startPublisher(ctx)
--   master: telemetry.startCollector(ctx)
--
-- Push, not poll: a node broadcasts every `publishInterval` seconds so the
-- master sees live values without asking. `state.request` exists only so a
-- master that just booted does not have to wait for the next tick.

local util = require("core.util")
local logger = require("core.logger")
local bus = require("core.event_bus")
local state = require("core.state")
local protocol = require("network.protocol")

local log = logger.scoped("telemetry")

local telemetry = {}

telemetry.TYPES = {
    METRICS = protocol.TYPES.METRICS,     -- node -> master, the snapshot
    REQUEST = "state.request",            -- master -> node, "publish now"
    COMMAND = protocol.TYPES.COMMAND,     -- master -> node, run a module action
    RESULT = protocol.TYPES.RESULT,       -- node -> master, how it went
}

local settings = {
    publishInterval = 3,
    staleAfter = 15,
}

---------------------------------------------------------------------------
-- Node side
---------------------------------------------------------------------------

--- Everything this computer knows about itself, in one message.
local function buildSnapshot(ctx)
    local modules = {}

    for _, record in ipairs(ctx.modules.all()) do
        local snapshot = ctx.modules.snapshot(record.id)
        if snapshot then
            local actions = {}
            for _, action in ipairs(ctx.modules.actions(record.id)) do
                -- Only the description travels; `run` stays on the node.
                actions[#actions + 1] = {
                    id = action.id,
                    label = action.label,
                    style = action.style,
                    enabled = action.enabled,
                }
            end
            snapshot.actions = actions
            modules[#modules + 1] = snapshot
        end
    end

    return {
        node = ctx.identity.name,
        role = ctx.identity.role,
        profile = ctx.identity.profile,
        version = ctx.version,
        uptime = ctx.app.uptime(),
        alerts = ctx.alerts.list(),
        modules = modules,
    }
end

--- Start publishing this computer's state. Node role only.
function telemetry.startPublisher(ctx, options)
    for key, value in pairs(options or {}) do settings[key] = value end

    if not ctx.network.isReady() then
        log.warn("no network: this node cannot report to a master")
        return false
    end

    local function publish()
        ctx.network.broadcast(telemetry.TYPES.METRICS, buildSnapshot(ctx))
    end

    -- A master that reboots asks everyone to report instead of waiting.
    ctx.network.registerHandler(telemetry.TYPES.REQUEST, function()
        publish()
    end)

    -- Remote control: the master forwards an action, the node runs it locally.
    ctx.network.registerHandler(telemetry.TYPES.COMMAND, function(message)
        local payload = message.payload or {}
        local ok, err = ctx.modules.invoke(payload.module, payload.action)
        log.info("remote action %s.%s -> %s",
            tostring(payload.module), tostring(payload.action), ok and "ok" or tostring(err))
        ctx.network.reply(message, telemetry.TYPES.RESULT, {
            module = payload.module, action = payload.action, ok = ok, error = err,
        })
        publish()
    end)

    ctx.scheduler.every(settings.publishInterval, publish,
        { name = "telemetry.publish", owner = "telemetry", immediate = true })

    log.info("publishing every %.1fs as '%s'", settings.publishInterval, ctx.identity.name)
    return true
end

---------------------------------------------------------------------------
-- Master side
---------------------------------------------------------------------------

--- Register (or refresh) one proxy module per module reported by a node.
local function syncRemoteModules(ctx, snapshot)
    for _, moduleSnapshot in ipairs(snapshot.modules or {}) do
        local id = snapshot.node .. "." .. moduleSnapshot.id

        state.set("nodes." .. snapshot.node .. ".modules." .. moduleSnapshot.id, moduleSnapshot)

        if not ctx.modules.has(id) then
            local template = ctx.require("modules.remote")
            local def = template.create({
                id = id,
                node = snapshot.node,
                moduleId = moduleSnapshot.id,
                name = moduleSnapshot.name or moduleSnapshot.label,
                icon = moduleSnapshot.icon,
            })
            ctx.modules.register(def)
            ctx.modules.setup(id)
            log.info("discovered remote module '%s'", id)
        end
    end
end

--- Start listening for node snapshots. Master role only.
function telemetry.startCollector(ctx, options)
    for key, value in pairs(options or {}) do settings[key] = value end

    if not ctx.network.isReady() then
        log.info("no network: running standalone, only local modules")
        return false
    end

    ctx.network.registerHandler(telemetry.TYPES.METRICS, function(message)
        local snapshot = message.payload
        if type(snapshot) ~= "table" or type(snapshot.node) ~= "string" then return end

        state.patch("nodes." .. snapshot.node, {
            name = snapshot.node,
            role = snapshot.role,
            profile = snapshot.profile,
            version = snapshot.version,
            uptime = snapshot.uptime,
            lastSeen = util.nowMs(),
            online = true,
        })

        syncRemoteModules(ctx, snapshot)
        bus.emit("node.updated", { node = snapshot.node })
    end)

    ctx.network.registerHandler(telemetry.TYPES.RESULT, function(message)
        local payload = message.payload or {}
        if not payload.ok then
            log.warn("remote action %s failed: %s",
                tostring(payload.action), tostring(payload.error))
        end
        bus.emit("node.action_result", payload)
    end)

    -- Mark silent nodes offline rather than showing stale numbers as live.
    ctx.scheduler.every(math.max(2, settings.staleAfter / 3), function()
        local now = util.nowMs()
        for name, node in pairs(state.get("nodes", {})) do
            local silentFor = (now - (node.lastSeen or 0)) / 1000
            if node.online and silentFor > settings.staleAfter then
                state.set("nodes." .. name .. ".online", false)
                log.warn("node '%s' went silent (%.0fs)", name, silentFor)
                ctx.alerts.raise({
                    id = "node.offline." .. name,
                    source = "network",
                    severity = "warning",
                    message = "Node '" .. name .. "' is not reporting",
                })
                bus.emit("node.offline", { node = name })
            elseif node.online then
                ctx.alerts.clear("node.offline." .. name)
            end
        end
    end, { name = "telemetry.staleness", owner = "telemetry" })

    telemetry.requestAll(ctx)
    log.info("collecting node telemetry")
    return true
end

--- Ask every node to publish immediately.
function telemetry.requestAll(ctx)
    if not ctx.network.isReady() then return false end
    return ctx.network.broadcast(telemetry.TYPES.REQUEST, {})
end

--- Forward a module action to the node that owns it.
function telemetry.sendAction(ctx, node, moduleId, actionId)
    if not ctx.network.isReady() then return false, "no network" end
    local sent = ctx.network.send(node, telemetry.TYPES.COMMAND, {
        module = moduleId, action = actionId,
    })
    return sent, sent and nil or ("could not reach node '" .. node .. "'")
end

--- Known nodes, most recently seen first.
function telemetry.nodes()
    local list = {}
    for _, node in pairs(state.get("nodes", {})) do list[#list + 1] = util.deepCopy(node) end
    table.sort(list, function(a, b) return (a.lastSeen or 0) > (b.lastSeen or 0) end)
    return list
end

function telemetry.shutdown()
    bus.offOwner("telemetry")
end

return telemetry

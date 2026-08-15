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
local backup = require("services.backup")
local identity = require("core.identity")

local log = logger.scoped("telemetry")

local telemetry = {}

telemetry.TYPES = {
    METRICS = protocol.TYPES.METRICS,     -- node -> master, the snapshot
    REQUEST = "state.request",            -- master -> node, "publish now"
    COMMAND = protocol.TYPES.COMMAND,     -- master -> node, run a module action
    RESULT = protocol.TYPES.RESULT,       -- node -> master, how it went
    BACKUP = "config.backup",             -- node -> master, keep this for me
    BACKUP_REQUEST = "config.request",    -- anyone -> master, send mine back
    BACKUP_RESTORE = "config.restore",    -- master -> requester, here it is
}

local settings = {
    publishInterval = 3,
    staleAfter = 15,
    -- Seconds between a node pushing its configuration to the master. Config
    -- changes rarely, so this is deliberately slow.
    backupInterval = 300,
    -- Whether to push it at all; see config/network.lua -> backup.share.
    shareBackup = false,
}

--- The peer that says it is the master, if one has introduced itself.
function telemetry.findMaster(ctx)
    for name, peer in pairs(ctx.network.peers()) do
        if peer.role == "master" then return name end
    end
    return nil
end

---------------------------------------------------------------------------
-- Node side
---------------------------------------------------------------------------

--- Methods worth advertising: enough for the master to know what a node can
--- read, without shipping the whole method list of every device.
local CAPABILITY_METHODS = {
    energy = { "getEnergy", "getEnergyStored", "getStoredEnergy" },
    throughput = { "getTransferRate" },
    inventory = { "list" },
    fluid = { "tanks" },
    storageNetwork = { "listItems" },
}

--- What this node can see on its own wired network.
-- The master keeps this as a live cache: it is how the layout editor knows
-- which devices exist and which computer owns them, without anybody writing it
-- down. Note this is *membership*, not topology - CC exposes a block's own
-- capability, never how the mod's cables join two blocks together.
local function describePeripherals(ctx)
    local described = {}

    for _, name in ipairs(ctx.peripherals.names()) do
        local proxy = ctx.peripherals.getByName(name)
        if proxy then
            local capabilities = {}
            for capability, candidates in pairs(CAPABILITY_METHODS) do
                for _, method in ipairs(candidates) do
                    if proxy.hasMethod(method) then
                        capabilities[#capabilities + 1] = capability
                        break
                    end
                end
            end

            described[#described + 1] = {
                name = name,
                types = proxy.types(),
                capabilities = capabilities,
            }
        end
    end

    return described
end

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

            -- A copy with the actions on it: the snapshot is the registry's
            -- cached table now, shared with everything else that asks.
            local outgoing = util.deepCopy(snapshot)
            outgoing.actions = actions

            -- A `format` function cannot cross rednet, so the master used to
            -- show a remote uptime as "8134" where the node showed "2h 15m".
            -- The node renders its own metrics and sends the text.
            for _, metric in ipairs(outgoing.metrics or {}) do
                if metric.format ~= nil then
                    metric.text = ctx.modules.formatMetric(metric)
                    metric.format = nil
                end
            end
            modules[#modules + 1] = outgoing
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
        peripherals = describePeripherals(ctx),
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

    -- Hand the master a copy of this node's configuration, so a replacement
    -- computer can get itself back without anyone carrying a floppy around.
    --
    -- Off unless asked for, and addressed rather than broadcast. That archive
    -- carries `data/security.dat` - the list of who may operate the base - and
    -- rednet is plaintext, so shouting it at everyone in range every five
    -- minutes is not a reasonable default.
    local function pushBackup()
        local master = telemetry.findMaster(ctx)
        if not master then
            log.debug("no master known yet; holding the configuration backup")
            return
        end
        ctx.network.send(master, telemetry.TYPES.BACKUP, {
            node = ctx.identity.name,
            archive = backup.create(ctx),
        })
    end

    if settings.shareBackup then
        ctx.scheduler.every(settings.backupInterval, pushBackup,
            { name = "telemetry.backup", owner = "telemetry", immediate = true })
    else
        log.info("configuration backups stay local (network.backup.share is off)")
    end

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

        -- Remote modules never poll: fresh data arriving is their equivalent,
        -- and history samples on exactly that signal.
        bus.emit("module.polled", { id = id, remote = true })

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

        -- A name with a dot in it would be filed as two nested nodes and could
        -- never be marked offline again. Nodes validate this at setup, but the
        -- master is talking to computers it does not control.
        if not identity.validateName(snapshot.node) then
            log.warn("ignoring a report from '%s': not a usable node name",
                tostring(snapshot.node))
            return
        end

        -- Two computers answering to the same name overwrite each other's
        -- numbers, and the readings just look wrong rather than absent - so it
        -- has to be said out loud.
        local known = state.get("nodes." .. snapshot.node .. ".computerId")
        local sender = message.__senderId
        if known and sender and known ~= sender then
            ctx.alerts.raise({
                id = "node.duplicate." .. snapshot.node,
                source = "network",
                severity = "warning",
                message = ("Two computers call themselves '%s' (#%s and #%s). "):format(
                    snapshot.node, tostring(known), tostring(sender))
                    .. "Run 'setup' on one of them.",
            })
        end

        state.patch("nodes." .. snapshot.node, {
            computerId = sender,
            name = snapshot.node,
            role = snapshot.role,
            profile = snapshot.profile,
            version = snapshot.version,
            uptime = snapshot.uptime,
            lastSeen = util.nowMs(),
            online = true,
        })

        -- Replaced wholesale rather than merged: a device that was unplugged
        -- must disappear, and a patch would keep it alive forever.
        if snapshot.peripherals then
            state.set("nodes." .. snapshot.node .. ".peripherals", snapshot.peripherals)
        end

        syncRemoteModules(ctx, snapshot)
        bus.emit("node.updated", { node = snapshot.node })
    end)

    -- Keep whatever nodes send, and hand it back when one asks for its own.
    ctx.network.registerHandler(telemetry.TYPES.BACKUP, function(message)
        local payload = message.payload or {}
        if payload.node and payload.archive then
            backup.storeRemote(payload.node, payload.archive)
        end
    end)

    ctx.network.registerHandler(telemetry.TYPES.BACKUP_REQUEST, function(message)
        local wanted = (message.payload or {}).node or message.source
        local archive, err = backup.loadRemote(wanted)
        if not archive then
            log.warn("no backup held for '%s'", tostring(wanted))
            ctx.network.reply(message, telemetry.TYPES.BACKUP_RESTORE,
                { node = wanted, error = err })
            return
        end
        log.info("sending the stored backup of '%s'", tostring(wanted))
        ctx.network.reply(message, telemetry.TYPES.BACKUP_RESTORE,
            { node = wanted, archive = archive })
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

--- Every device known across the base: local ones plus everything the nodes
--- have reported. Used by the layout editor and the device tree.
-- @return list of { name, types, capabilities, node }
function telemetry.knownPeripherals(ctx)
    local devices = {}

    for _, name in ipairs(ctx.peripherals.names()) do
        local proxy = ctx.peripherals.getByName(name)
        devices[#devices + 1] = {
            name = name,
            types = proxy and proxy.types() or {},
            node = ctx.identity and ctx.identity.name or "local",
            localDevice = true,
        }
    end

    for nodeName, node in pairs(state.get("nodes", {})) do
        for _, device in ipairs(node.peripherals or {}) do
            devices[#devices + 1] = {
                name = device.name,
                types = device.types or {},
                capabilities = device.capabilities or {},
                node = nodeName,
                online = node.online,
            }
        end
    end

    table.sort(devices, function(a, b)
        if a.node ~= b.node then return a.node < b.node end
        return a.name < b.name
    end)
    return devices
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

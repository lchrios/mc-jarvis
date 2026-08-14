--- Node to node transport.
--
-- Wraps rednet so no module ever touches it directly. Disabled by default:
-- with `network.enabled = false` in config every call is a safe no-op, which
-- is what a single computer install wants.
--
--   network.registerHandler("metrics.update", function(message, sender) ... end)
--   network.send("power_node", "command.execute", { action = "restart" })
--   network.broadcast("node.heartbeat", { status = "ok" })

local util = require("core.util")
local logger = require("core.logger")
local bus = require("core.event_bus")
local state = require("core.state")
local protocol = require("network.protocol")
local auth = require("network.auth")

local log = logger.scoped("network")

local network = {}

local settings = {
    enabled = false,
    protocol = protocol.NAME,
    hostname = nil,
    openAllModems = true,
    modemSide = nil,
    heartbeatInterval = 10,
    peerTimeout = 30,
}

local handlers = {}   -- [type] = { fn, ... }
local peers = {}      -- [name] = { id, lastSeen, role, status }
local openModems = {}
local ready = false

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

local function openModem(side)
    if rednet.isOpen(side) then
        openModems[#openModems + 1] = side
        return true
    end
    local ok, err = pcall(rednet.open, side)
    if ok then
        openModems[#openModems + 1] = side
        log.info("opened modem on %s", side)
        return true
    end
    log.warn("cannot open modem on %s: %s", side, tostring(err))
    return false
end

local function openModems_()
    openModems = {}
    if settings.modemSide then
        return openModem(settings.modemSide)
    end
    if not settings.openAllModems then return false end

    local found = false
    for _, side in ipairs(peripheral.getNames()) do
        local ok, kind = pcall(peripheral.getType, side)
        if ok and kind == "modem" then
            if openModem(side) then found = true end
        end
    end
    return found
end

--- Initialise the transport.
-- @param options table merged over the defaults (see config/network.lua)
function network.init(options)
    for key, value in pairs(options or {}) do settings[key] = value end

    settings.hostname = settings.hostname
        or os.getComputerLabel()
        or ("computer_" .. os.getComputerID())

    auth.configure({
        secret = settings.secret,
        window = settings.authWindow,
    })

    state.set("network.enabled", settings.enabled)
    state.set("network.hostname", settings.hostname)
    state.set("network.authenticated", auth.enabled())

    if not settings.enabled then
        log.info("networking disabled")
        return false
    end

    if not openModems_() then
        log.warn("networking enabled but no modem could be opened")
        state.set("network.status", "no_modem")
        return false
    end

    pcall(rednet.host, settings.protocol, settings.hostname)

    bus.on("rednet_message", function(senderId, message, receivedProtocol)
        network.onMessage(senderId, message, receivedProtocol)
    end, { owner = "network" })

    ready = true
    state.set("network.status", "online")
    log.info("network ready as '%s' on protocol '%s', signing %s",
        settings.hostname, settings.protocol, auth.describe())

    if not auth.enabled() then
        -- Worth saying every boot. Remote actions ride on this protocol, and
        -- on a shared server anybody can send them.
        log.warn("no network secret set: any computer on this protocol can run "
            .. "actions here. Set `secret` in config/network.lua on every "
            .. "computer of the base.")
    end
    return true
end

function network.isAuthenticated() return auth.enabled() end

function network.isReady() return ready end

function network.hostname() return settings.hostname end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

local function transmit(message, targetId)
    if not ready then
        log.debug("dropping '%s': network not ready", message.type)
        return false
    end

    auth.sign(message)

    local ok, err
    if targetId then
        ok, err = pcall(rednet.send, targetId, message, settings.protocol)
    else
        ok, err = pcall(rednet.broadcast, message, settings.protocol)
    end

    if not ok then
        log.error("send failed: %s", tostring(err))
        return false
    end
    return true
end

--- Send to a named node (resolved through the peer table, then rednet.lookup).
function network.send(target, messageType, payload)
    local message = protocol.message(messageType, payload, {
        source = settings.hostname,
        target = target,
    })

    local peer = peers[target]
    local targetId = peer and peer.id or nil

    if not targetId and ready then
        local ok, found = pcall(rednet.lookup, settings.protocol, target)
        if ok and found then targetId = found end
    end

    if not targetId then
        log.warn("unknown node '%s'", tostring(target))
        return false
    end
    return transmit(message, targetId)
end

--- Send directly to a computer id (no name resolution).
function network.sendToId(computerId, messageType, payload)
    return transmit(protocol.message(messageType, payload, {
        source = settings.hostname,
    }), computerId)
end

function network.broadcast(messageType, payload)
    return transmit(protocol.message(messageType, payload, {
        source = settings.hostname,
        target = protocol.BROADCAST,
    }))
end

function network.reply(original, messageType, payload)
    local message = protocol.reply(original, messageType, payload, settings.hostname)
    local peer = peers[original.source]
    return transmit(message, peer and peer.id or original.__senderId)
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

--- Register a handler for a message type. Returns an unregister function.
function network.registerHandler(messageType, fn)
    handlers[messageType] = handlers[messageType] or {}
    local list = handlers[messageType]
    list[#list + 1] = fn
    return function()
        for index, existing in ipairs(list) do
            if existing == fn then table.remove(list, index) return true end
        end
        return false
    end
end

local function touchPeer(name, computerId, message)
    if not name then return end
    local peer = peers[name] or { name = name }
    peer.id = computerId
    peer.lastSeen = util.nowMs()
    if message and message.payload and message.payload.role then
        peer.role = message.payload.role
    end
    peers[name] = peer
    state.set("network.peers", util.deepCopy(peers))
end

local rejected = { count = 0, lastAt = 0 }

--- A message failed its check. Counted, and mentioned at most once a minute:
--- a computer sending garbage in a loop must not become the log.
function network.onRejected(message, senderId, reason)
    rejected.count = rejected.count + 1
    state.set("network.rejected", rejected.count)

    local now = util.nowMs()
    if now - rejected.lastAt < 60000 then return end
    rejected.lastAt = now

    log.warn("refused '%s' from computer #%s (%s); %d refused so far",
        tostring(message.type), tostring(senderId), tostring(reason), rejected.count)
    bus.emit("network.rejected", {
        type = message.type, senderId = senderId,
        reason = reason, total = rejected.count,
    })
end

function network.rejectedCount() return rejected.count end

--- Feed an incoming rednet message in.
function network.onMessage(senderId, message, receivedProtocol)
    if receivedProtocol ~= nil and receivedProtocol ~= settings.protocol then return end

    local ok, reason = protocol.validate(message)
    if not ok then
        log.debug("dropping message from %s: %s", tostring(senderId), tostring(reason))
        return
    end
    if not protocol.isForMe(message, settings.hostname) then return end

    -- Anyone can put a computer on this protocol and send whatever they like,
    -- and one of the things they could send is "stop the farms". A message
    -- that cannot prove it knows the base's secret does not get to be handled.
    local authentic, why = auth.verify(message)
    if not authentic then
        network.onRejected(message, senderId, why)
        return
    end

    message.__senderId = senderId
    touchPeer(message.source, senderId, message)

    bus.emit("network.message", message)
    bus.emit("network.message." .. message.type, message)

    for _, handler in ipairs(handlers[message.type] or {}) do
        local okHandler, err = pcall(handler, message, senderId)
        if not okHandler then
            log.error("handler for '%s' failed: %s", message.type, tostring(err))
        end
    end
end

---------------------------------------------------------------------------
-- Peers
---------------------------------------------------------------------------

function network.peers() return util.deepCopy(peers) end

--- Peers that have not been heard from within the timeout.
function network.stalePeers()
    local stale = {}
    local now = util.nowMs()
    for name, peer in pairs(peers) do
        if now - (peer.lastSeen or 0) > settings.peerTimeout * 1000 then
            stale[#stale + 1] = name
        end
    end
    return stale
end

--- Periodic heartbeat + stale peer detection. Registered by `core.app`.
function network.startHeartbeat(scheduler, role)
    if not ready or not settings.heartbeatInterval or settings.heartbeatInterval <= 0 then
        return nil
    end
    return scheduler.every(settings.heartbeatInterval, function()
        network.broadcast(protocol.TYPES.HEARTBEAT, {
            role = role,
            uptime = os.clock(),
        })
        for _, name in ipairs(network.stalePeers()) do
            bus.emit("network.peer_lost", { name = name })
        end
    end, { name = "network.heartbeat", owner = "network" })
end

function network.shutdown()
    if ready then
        pcall(rednet.unhost, settings.protocol, settings.hostname)
        for _, side in ipairs(openModems) do pcall(rednet.close, side) end
    end
    bus.offOwner("network")
    ready = false
end

return network

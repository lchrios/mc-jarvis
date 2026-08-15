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
    role = nil,
    openAllModems = true,
    modemSide = nil,
    heartbeatInterval = 10,
    peerTimeout = 30,
}

local handlers = {}   -- [type] = { fn, ... }
local peers = {}      -- [name] = { id, lastSeen, role, status }
local openModems = {}
local ready = false

--- What has actually happened on the wire.
--
-- Counters and a short tail of messages, kept because "it should be talking"
-- and "it is talking" are different claims and only one of them can be shown.
-- The network screen is entirely built out of what is below.
local stats = {
    sent = 0,        -- messages handed to rednet
    received = 0,    -- accepted, handler ran
    rejected = 0,    -- failed validation or the signature check
    ignored = 0,     -- valid, but addressed to somebody else
    reasons = {},    -- [reason] = count, why messages were refused
    startedAt = util.nowMs(),
}

--- Recent messages, oldest first. Small on purpose: it lives in RAM on a
--- Minecraft computer and only exists to answer "is anything moving".
local TRAFFIC_LIMIT = 40
local traffic = {}

--- Computers heard on this protocol whose messages were not accepted.
-- Without this a wrong secret looks exactly like an unplugged modem: silence.
local strangers = {}  -- [computerId] = { id, source, reason, count, lastAt }

---------------------------------------------------------------------------
-- Bookkeeping
---------------------------------------------------------------------------

--- Note one message on the wire. `peer` is a name for an outgoing message and
--- whatever the sender called itself for an incoming one.
local function record(direction, messageType, peer, ok, reason)
    traffic[#traffic + 1] = {
        at = util.nowMs(),
        direction = direction,
        type = messageType,
        peer = peer,
        ok = ok ~= false,
        reason = reason,
    }
    while #traffic > TRAFFIC_LIMIT do table.remove(traffic, 1) end
end

local function countReason(reason)
    reason = tostring(reason or "unknown")
    stats.reasons[reason] = (stats.reasons[reason] or 0) + 1
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

--- Every modem attached, whether or not rednet ever opened it.
local function modemNames()
    local names = {}
    for _, side in ipairs(peripheral.getNames()) do
        local ok, kind = pcall(peripheral.getType, side)
        if ok and kind == "modem" then names[#names + 1] = side end
    end
    return names
end

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
    for _, side in ipairs(modemNames()) do
        if openModem(side) then found = true end
    end
    return found
end

--- Every modem on this computer and what it is doing.
--
-- Read here rather than in the screen: a screen must not call peripherals, and
-- this is the one place that already knows which sides rednet was opened on.
-- @return list of { name, wireless, open, remote }
function network.modems()
    local list = {}

    for _, name in ipairs(modemNames()) do
        local entry = { name = name, open = false }

        local okWireless, wireless = pcall(peripheral.call, name, "isWireless")
        entry.wireless = okWireless and wireless or false

        -- rednet.open subscribes the modem to this computer's own id, so an
        -- open channel there is proof rednet came up on *this* modem rather
        -- than merely that a modem exists somewhere.
        local okOpen, open = pcall(peripheral.call, name, "isOpen", os.getComputerID())
        entry.open = (okOpen and open) or false

        if not entry.wireless then
            local okRemote, remote = pcall(peripheral.call, name, "getNamesRemote")
            entry.remote = okRemote and remote and #remote or nil
        end

        list[#list + 1] = entry
    end

    table.sort(list, function(a, b) return a.name < b.name end)
    return list
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
    network.registerInternalHandlers()
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

--- Answer discovery, and time the answers to our own.
--
-- Heartbeats mean waiting up to ten seconds to find out whether a computer is
-- there, which is exactly the wrong length of time to stand in front of a
-- monitor. A discover is the same question asked now, and the reply carries
-- back the timestamp it was asked at, so the round trip can be measured
-- without either computer trusting the other's clock.
function network.registerInternalHandlers()
    network.registerHandler(protocol.TYPES.DISCOVER, function(message)
        network.reply(message, protocol.TYPES.HELLO, {
            role = settings.role,
            uptime = os.clock(),
            -- Echoed, not read: only the asker knows what its own clock said.
            echo = (message.payload or {}).at,
        })
    end)

    network.registerHandler(protocol.TYPES.HELLO, function(message)
        local echo = (message.payload or {}).echo
        local peer = peers[message.source]
        if peer and type(echo) == "number" then
            peer.rtt = math.max(0, util.nowMs() - echo)
            state.set("network.peers", util.deepCopy(peers))
        end
    end)
end

--- Ask every computer on the protocol to identify itself, now.
function network.discover()
    return network.broadcast(protocol.TYPES.DISCOVER, { at = util.nowMs() })
end

function network.isAuthenticated() return auth.enabled() end

function network.isReady() return ready end

function network.hostname() return settings.hostname end

function network.protocolName() return settings.protocol end

function network.role() return settings.role end

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
        stats.lastError = tostring(err)
        record("out", message.type, message.target, false, tostring(err))
        log.error("send failed: %s", tostring(err))
        return false
    end

    stats.sent = stats.sent + 1
    record("out", message.type, message.target)
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
    local peer = peers[name] or { name = name, firstSeen = util.nowMs(), messages = 0 }
    peer.id = computerId
    peer.lastSeen = util.nowMs()
    peer.messages = (peer.messages or 0) + 1
    peer.lastType = message and message.type or peer.lastType
    if message and message.payload and message.payload.role then
        peer.role = message.payload.role
    end
    peers[name] = peer
    state.set("network.peers", util.deepCopy(peers))
end

--- A computer that is talking but is not being listened to.
local function noteStranger(senderId, message, reason)
    local key = tostring(senderId)
    local stranger = strangers[key] or { id = senderId, count = 0 }
    stranger.count = stranger.count + 1
    stranger.reason = reason
    stranger.lastAt = util.nowMs()
    stranger.source = message and message.source or stranger.source
    stranger.type = message and message.type or stranger.type
    strangers[key] = stranger
end

local rejected = { count = 0, lastAt = 0 }

--- A message failed its check. Counted, and mentioned at most once a minute:
--- a computer sending garbage in a loop must not become the log.
function network.onRejected(message, senderId, reason)
    rejected.count = rejected.count + 1
    stats.rejected = stats.rejected + 1
    countReason(reason)
    noteStranger(senderId, message, reason)
    record("in", message and message.type, message and message.source, false, reason)
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
        stats.rejected = stats.rejected + 1
        countReason(reason)
        noteStranger(senderId, type(message) == "table" and message or nil, reason)
        log.debug("dropping message from %s: %s", tostring(senderId), tostring(reason))
        return
    end
    if not protocol.isForMe(message, settings.hostname) then
        -- Somebody else's mail. Counted, never shown as a problem: on a base
        -- with three computers most of the traffic is addressed elsewhere.
        stats.ignored = stats.ignored + 1
        return
    end

    -- Anyone can put a computer on this protocol and send whatever they like,
    -- and one of the things they could send is "stop the farms". A message
    -- that cannot prove it knows the base's secret does not get to be handled.
    local authentic, why = auth.verify(message)
    if not authentic then
        network.onRejected(message, senderId, why)
        return
    end

    message.__senderId = senderId
    stats.received = stats.received + 1
    record("in", message.type, message.source)
    touchPeer(message.source, senderId, message)

    -- It answered properly, so it is no longer a stranger.
    strangers[tostring(senderId)] = nil

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

--- Peers as a list, most recently heard first.
function network.peerList()
    local list = {}
    for _, peer in pairs(peers) do list[#list + 1] = util.deepCopy(peer) end
    table.sort(list, function(a, b) return (a.lastSeen or 0) > (b.lastSeen or 0) end)
    return list
end

--- Computers heard on this protocol that were refused, worst offender first.
function network.strangers()
    local list = {}
    for _, stranger in pairs(strangers) do list[#list + 1] = util.deepCopy(stranger) end
    table.sort(list, function(a, b) return (a.lastAt or 0) > (b.lastAt or 0) end)
    return list
end

function network.traffic() return util.deepCopy(traffic) end

function network.stats() return util.deepCopy(stats) end

--- Everything the network screen and `net` need in one call.
function network.info()
    return {
        enabled = settings.enabled == true,
        ready = ready,
        status = state.get("network.status") or (settings.enabled and "starting" or "off"),
        hostname = settings.hostname,
        protocol = settings.protocol,
        role = settings.role,
        signed = auth.enabled(),
        computerId = os.getComputerID(),
        heartbeatInterval = settings.heartbeatInterval,
        peerTimeout = settings.peerTimeout,
        openModems = util.deepCopy(openModems),
        stats = util.deepCopy(stats),
    }
end

--- Forget the counters and the traffic tail. The peers are left alone: they
--- are facts about the base, not a measurement of it.
function network.resetStats()
    stats.sent, stats.received, stats.rejected, stats.ignored = 0, 0, 0, 0
    stats.reasons = {}
    stats.lastError = nil
    stats.startedAt = util.nowMs()
    rejected.count = 0
    state.set("network.rejected", 0)
    for index = #traffic, 1, -1 do traffic[index] = nil end
    for key in pairs(strangers) do strangers[key] = nil end
    return true
end

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
    settings.role = role or settings.role
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

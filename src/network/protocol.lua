--- Wire format for node to node messages.
--
-- Every BaseOS message is a table with a fixed envelope:
--
--   { version = 1, id = 42, source = "power_node", target = "master",
--     type = "metrics.update", timestamp = 1712345678901, payload = { ... } }
--
-- Keeping the envelope in its own module means the transport (rednet today,
-- maybe websockets later) can change without touching the message schema.

local util = require("core.util")

local protocol = {}

protocol.VERSION = 1
protocol.NAME = "baseos"
protocol.BROADCAST = "*"

--- Well known message types. Modules may define their own namespaced types.
protocol.TYPES = {
    HELLO = "node.hello",
    GOODBYE = "node.goodbye",
    HEARTBEAT = "node.heartbeat",
    METRICS = "metrics.update",
    STATE = "state.update",
    COMMAND = "command.execute",
    RESULT = "command.result",
    ALERT = "alert.raised",
    DISCOVER = "node.discover",
}

local sequence = 0

--- Build an envelope.
function protocol.message(messageType, payload, options)
    options = options or {}
    sequence = sequence + 1
    return {
        version = protocol.VERSION,
        id = sequence,
        source = options.source,
        target = options.target or protocol.BROADCAST,
        type = messageType,
        timestamp = util.nowMs(),
        replyTo = options.replyTo,
        payload = payload,
    }
end

--- Validate an incoming message. Returns ok, reason.
function protocol.validate(message)
    if type(message) ~= "table" then return false, "not a table" end
    if message.version == nil then return false, "missing version" end
    if message.version ~= protocol.VERSION then
        return false, "unsupported version " .. tostring(message.version)
    end
    if type(message.type) ~= "string" then return false, "missing type" end
    return true
end

--- Is this message addressed to us?
function protocol.isForMe(message, myName)
    local target = message.target
    return target == nil or target == protocol.BROADCAST or target == myName
end

--- Build a reply to an incoming message.
function protocol.reply(original, messageType, payload, source)
    return protocol.message(messageType, payload, {
        source = source,
        target = original.source,
        replyTo = original.id,
    })
end

return protocol

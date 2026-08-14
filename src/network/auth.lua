--- Proof that a message came from someone who knows the base's secret.
--
-- Rednet is a public medium. Any computer with a modem can listen on the
-- `baseos` protocol and can send whatever it likes, and BaseOS carries
-- `command.execute` on it - so without this, anybody on the server can stop
-- your farms from a computer they placed in the next chunk over.
--
-- Every outgoing message gets a `tag` computed over its contents and a shared
-- secret; a receiver recomputes it and drops anything that does not match.
--
-- WHAT THIS DOES AND DOES NOT DO
--
--   It does   stop a computer that does not know the secret from forging a
--             message, which is the whole of the realistic threat: somebody
--             placing a computer nearby and sending commands.
--   It does   reject stale and repeated messages, so a captured command cannot
--             be replayed at leisure.
--   It does   NOT hide anything. Rednet is plaintext and this adds no
--             encryption: a listener still reads every message. Do not treat
--             the base as private, and see `network.backup.share`.
--   It is     NOT a cryptographic hash. CC has no crypto library and a Lua
--             SHA-256 per message on a Minecraft-speed computer is a poor
--             trade. This is a keyed mixing function - good enough that
--             guessing a valid tag is not worth anybody's afternoon, and no
--             more than that.
--
-- With no secret configured nothing is signed or checked, which keeps a
-- single-computer base and a trusted private world exactly as they were.

local util = require("core.util")
local logger = require("core.logger")

local log = logger.scoped("auth")

local auth = {}

local secret = nil
local settings = {
    window = 30,        -- seconds a message stays acceptable
    remember = 64,      -- recent message ids kept per sender, against replay
}

local seen = {}         -- [source] = { ids = { [id] = true }, order = { id, ... } }

---------------------------------------------------------------------------
-- Arithmetic the CC sandbox is sure to have
---------------------------------------------------------------------------

-- No bitwise operators and no `bit32`: Lua 5.1, 5.2 and 5.3 disagree about
-- both, and this has to run identically on every CC build. Everything below is
-- plain arithmetic on numbers that stay well inside a double's 53 bits.

local TWO32 = 4294967296

--- (a * b) mod 2^32 without ever exceeding 2^53.
local function mul32(a, b)
    local high = math.floor(a / 65536)
    local low = a % 65536
    return ((high * b % 65536) * 65536 + low * b) % TWO32
end

local function xor8(a, b)
    local result, weight = 0, 1
    for _ = 1, 8 do
        if (a % 2) ~= (b % 2) then result = result + weight end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        weight = weight * 2
    end
    return result
end

--- One FNV-1a style pass over `text`, seeded with `offset`.
local function pass(text, offset, prime)
    local hash = offset
    for index = 1, #text do
        local low = hash % 256
        hash = hash - low + xor8(low, text:byte(index))
        hash = mul32(hash, prime)
    end
    -- A final avalanche so the last byte cannot dominate the result.
    hash = mul32(hash + 2654435769, prime)
    return hash
end

--- 32 hex characters from four independent passes.
function auth.digest(text)
    return ("%08x%08x%08x%08x"):format(
        pass(text, 2166136261, 16777619),
        pass(text, 1099511628, 16777639),
        pass(text, 3141592653, 16777669),
        pass(text, 2718281828, 16777691))
end

---------------------------------------------------------------------------
-- A message, written the same way on both ends
---------------------------------------------------------------------------

--- Deterministic text for a value.
-- `textutils.serialise` walks tables with `pairs`, whose order Lua does not
-- promise, so sender and receiver would produce different text for the same
-- table and every tag would fail. Keys are sorted here instead.
local function canonical(value, depth)
    depth = (depth or 0) + 1
    if depth > 12 then return "..." end

    local kind = type(value)
    if kind ~= "table" then return kind:sub(1, 1) .. ":" .. tostring(value) end

    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = tostring(key) .. "=" .. canonical(value[key], depth)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

auth.canonical = canonical

--- What gets signed: the envelope minus anything added after signing.
local function subject(message)
    return table.concat({
        tostring(message.version),
        tostring(message.id),
        tostring(message.source),
        tostring(message.target),
        tostring(message.type),
        tostring(message.timestamp),
        canonical(message.payload),
    }, "\30")
end

---------------------------------------------------------------------------
-- Signing and checking
---------------------------------------------------------------------------

function auth.configure(options)
    options = options or {}
    if options.secret ~= nil then
        secret = (options.secret ~= "" and options.secret) or nil
    end
    if type(options.window) == "number" then settings.window = options.window end
    if type(options.remember) == "number" then settings.remember = options.remember end
    seen = {}
    return auth.enabled()
end

function auth.enabled() return secret ~= nil end

--- Add a tag to an outgoing message. A no-op with no secret configured.
function auth.sign(message)
    if not secret then return message end
    message.tag = auth.digest(secret .. "\31" .. subject(message))
    return message
end

--- Has this exact message been accepted already?
local function isReplay(source, id)
    local record = seen[source]
    if not record then
        seen[source] = { ids = { [id] = true }, order = { id } }
        return false
    end

    if record.ids[id] then return true end

    record.ids[id] = true
    record.order[#record.order + 1] = id
    while #record.order > settings.remember do
        local oldest = table.remove(record.order, 1)
        record.ids[oldest] = nil
    end
    return false
end

--- Check an incoming message. Returns ok, reason.
function auth.verify(message)
    if not secret then return true end
    if type(message.tag) ~= "string" then return false, "unsigned" end

    local expected = auth.digest(secret .. "\31" .. subject(message))
    if message.tag ~= expected then return false, "bad signature" end

    -- A tag proves who wrote it, not when. Without a freshness window a
    -- captured "stop the farms" could be replayed any time, forever.
    local age = math.abs(util.nowMs() - (tonumber(message.timestamp) or 0)) / 1000
    if age > settings.window then
        return false, ("stale by %.0fs"):format(age)
    end

    if isReplay(tostring(message.source), message.id) then
        return false, "already seen"
    end

    return true
end

--- Forget what has been seen. For tests and for a clean restart.
function auth.reset() seen = {} end

function auth.describe()
    if not secret then return "off" end
    return ("on (window %ds)"):format(settings.window)
end

return auth

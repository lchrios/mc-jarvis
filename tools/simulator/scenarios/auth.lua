-- Signed rednet.
--
-- Anyone can put a computer on the `baseos` protocol and send whatever they
-- like, and one of the things BaseOS carries is "run this action". This drives
-- a node with a secret configured and feeds it messages the way a stranger
-- would: unsigned, wrongly signed, stale, and replayed.

local failures = {}

local function check(condition, message)
    if condition then
        print("  ok: " .. message)
        return true
    end
    failures[#failures + 1] = message
    print("  FAIL: " .. message)
    return false
end

__TEST.setMaxEvents(120)
__TEST.addModem()

__TEST.files["data/node.dat"] = textutils.serialise({
    role = "node", profile = "power", name = "power_node",
    modules = { "system", "demo_farm" },
})

__TEST.files["config/network.lua"] = [[
return {
    enabled = true,
    protocol = "baseos",
    hostname = "power_node",
    secret = "una frase larga que solo esta en mi base",
    authWindow = 30,
    telemetry = { publishInterval = 2, staleAfter = 15 },
}
]]

__TEST.files["config/modules.lua"] = [[
return { enabled = { "system", "demo_farm" }, instances = {}, settings = {} }
]]

local function auth() return BASEOS.loaded["network.auth"] end
local function network() return BASEOS.loaded["network.network"] end
local function registry() return BASEOS.loaded["modules.registry"] end
local function farm()
    local record = registry().get("demo_farm")
    return record and record.def or nil
end

--- A message shaped exactly like the real thing.
local function command(overrides)
    local message = {
        version = 1,
        id = 1000,
        source = "master",
        target = "power_node",
        type = "command.execute",
        timestamp = os.epoch("utc"),
        payload = { module = "demo_farm", action = "stop" },
    }
    for key, value in pairs(overrides or {}) do message[key] = value end
    return message
end

---------------------------------------------------------------- signed on
__TEST.injectAt(12, function()
    check(auth().enabled(), "a configured secret turns signing on")
    check(network().isAuthenticated(), "and the transport says so")

    farm().running = true
end)

------------------------------------------------- a stranger with no secret
__TEST.injectAt(16, function()
    local before = network().rejectedCount()
    network().onMessage(99, command(), "baseos")

    check(farm().running == true,
        "an unsigned command does not run: the farm is still going")
    check(network().rejectedCount() == before + 1, "and it was counted as refused")
end)

------------------------------------------------ a stranger guessing wrong
__TEST.injectAt(20, function()
    local message = command({ id = 1001 })
    message.tag = "00000000000000000000000000000000"
    network().onMessage(99, message, "baseos")

    check(farm().running == true, "nor does a command with a made-up signature")
end)

------------------------------------------ somebody signing with another key
__TEST.injectAt(24, function()
    -- What a stranger who wrote their own BaseOS would produce.
    local message = command({ id = 1002 })
    local theirs = auth().digest("otro secreto\31x")
    message.tag = theirs
    network().onMessage(99, message, "baseos")

    check(farm().running == true, "nor one signed with a different secret")
end)

------------------------------------------------------- the real master
__TEST.injectAt(28, function()
    local message = auth().sign(command({ id = 1003 }))
    network().onMessage(7, message, "baseos")
end)

__TEST.injectAt(32, function()
    check(farm().running == false,
        "a properly signed command from the master does run")
end)

------------------------------------------------------------ replay
__TEST.injectAt(36, function()
    farm().running = true

    -- The same message, captured off the wire and sent again.
    local message = auth().sign(command({ id = 1003 }))
    network().onMessage(99, message, "baseos")

    check(farm().running == true,
        "a captured command replayed verbatim is refused")
end)

------------------------------------------------------------ stale
__TEST.injectAt(40, function()
    local message = auth().sign(command({
        id = 1004,
        timestamp = os.epoch("utc") - 120000,   -- two minutes old
    }))
    network().onMessage(99, message, "baseos")

    check(farm().running == true, "and so is one kept for later")
end)

---------------------------------------------------- tamper with the payload
__TEST.injectAt(44, function()
    local message = auth().sign(command({ id = 1005 }))
    -- Signed for "stop", delivered asking for something else.
    message.payload.action = "start"
    network().onMessage(7, message, "baseos")

    check(farm().running == true,
        "editing the payload after signing invalidates the message")
end)

------------------------------------------------------------- the digest
__TEST.injectAt(48, function()
    local a = auth().digest("hello")
    check(#a == 32, "the digest is 32 hex characters (" .. #a .. ")")
    check(a == auth().digest("hello"), "and is stable for the same input")
    check(a ~= auth().digest("hellp"), "one byte different gives a different digest")

    -- Sender and receiver build the text from their own tables, so key order
    -- must not matter.
    local one = auth().canonical({ b = 2, a = 1, c = { z = 1, y = 2 } })
    local two = auth().canonical({ c = { y = 2, z = 1 }, a = 1, b = 2 })
    check(one == two, "the canonical form does not depend on key order")
end)

--------------------------------------------- with no secret, nothing changes
__TEST.injectAt(52, function()
    auth().configure({ secret = "" })
    check(auth().enabled() == false, "clearing the secret turns signing off")

    local ok = auth().verify(command({ id = 2000 }))
    check(ok, "and then an unsigned message is accepted again, as before")
end)

---------------------------------------------------------------- run
local source = assert(__TEST.files["startup.lua"], "startup.lua not found")
local chunk = assert(load(source, "@startup.lua", "t", _G))
local ok, runError = pcall(chunk)

print("run ok: " .. tostring(ok) .. (ok and "" or (" err=" .. tostring(runError))))

local log = __TEST.files["data/baseos.log"]
if log and log:find("%[ERROR%]") then
    print(log)
    error("log contains ERROR entries", 0)
end
if not ok then error("startup crashed: " .. tostring(runError), 0) end
for _, harnessError in ipairs(__TEST.errors()) do check(false, "harness: " .. harnessError) end

if #failures > 0 then error(#failures .. " assertion(s) failed", 0) end
print("network authentication validated")

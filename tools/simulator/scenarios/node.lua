-- A computer set up as a node: headless, owns its data, pushes it out.
--
-- Only the node side runs here. Its counterpart is driven in master.lua, both
-- against the same wire format - simulating two computers in one Lua state
-- would prove less, not more.

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

---------------------------------------------------------------- identity
__TEST.files["data/node.dat"] = textutils.serialise({
    role = "node",
    profile = "power",
    name = "power_node",
    modules = { "system", "power" },
})

__TEST.addModem("modem_0")
__TEST.addEnergyCells(3)

local telemetryType = "metrics.update"

__TEST.injectAt(25, function()
    local sent = __TEST.lastSent(telemetryType)
    check(sent ~= nil, "the node published a metrics.update")
    if not sent then return end

    check(sent.target == "*", "it is broadcast, not addressed to one computer")
    check(sent.protocol == "baseos", "it uses the baseos protocol")

    local payload = sent.message.payload
    check(payload.node == "power_node", "the payload names the node")
    check(payload.role == "node", "the payload carries the role")

    local byId = {}
    for _, moduleSnapshot in ipairs(payload.modules or {}) do
        byId[moduleSnapshot.id] = moduleSnapshot
    end
    check(byId.power ~= nil, "the power module is in the payload")
    check(byId.system ~= nil, "the system module is in the payload")

    if byId.power then
        check(#(byId.power.metrics or {}) > 0, "module metrics travel with it")
        check(byId.power.status ~= nil, "module status travels with it")
    end

    -- The node keeps the data; the master never touches its peripherals.
    local registry = BASEOS.loaded["modules.registry"]
    local power = registry.get("power")
    check(power ~= nil and power.def.sources ~= nil, "the node holds its own readings")
    check(#(power.def.sources or {}) == 3, "it read all 3 energy devices locally")
end)

---------------------------------------------------------- master asks for data
__TEST.injectAt(30, function()
    __TEST.clearSent()
    -- A master that just booted asks everyone to report now.
    return { "rednet_message", 1, {
        version = 1, id = 1, type = "state.request",
        source = "master", target = "power_node", timestamp = 0, payload = {},
    }, "baseos" }
end)

__TEST.injectAt(34, function()
    check(__TEST.lastSent(telemetryType) ~= nil, "state.request triggers an immediate publish")
end)

---------------------------------------------------------- remote module action
__TEST.injectAt(38, function()
    __TEST.clearSent()
    return { "rednet_message", 1, {
        version = 1, id = 2, type = "command.execute",
        source = "master", target = "power_node", timestamp = 0,
        payload = { module = "system", action = "reboot_disabled" },
    }, "baseos" }
end)

__TEST.injectAt(42, function()
    local result = __TEST.lastSent("command.result")
    check(result ~= nil, "a command gets a result back")
    if result then
        check(result.message.payload.module == "system", "the result names the module")
        check(result.message.payload.ok == false, "an unknown action is reported as failed")
    end
end)

---------------------------------------------------------------- headless
__TEST.injectAt(46, function()
    local app = BASEOS.loaded["core.app"]
    check(app.renderer() == nil, "a node has no renderer")
    local navigation = BASEOS.loaded["ui.navigation"]
    check(navigation.current() == nil, "a node mounts no screens")
end)

---------------------------------------------------------------- run
local source = assert(__TEST.files["startup.lua"], "startup.lua not found")
local chunk = assert(load(source, "@startup.lua", "t", _G))
local ok, runError = pcall(chunk)

print("--- node terminal ---")
print(__TEST.terminal.render())

print("run ok: " .. tostring(ok) .. (ok and "" or (" err=" .. tostring(runError))))

local log = __TEST.files["data/baseos.log"]
if log and log:find("%[ERROR%]") then
    print(log)
    error("log contains ERROR entries", 0)
end
if not ok then error("startup crashed: " .. tostring(runError), 0) end
for _, harnessError in ipairs(__TEST.errors()) do check(false, "harness: " .. harnessError) end

if #failures > 0 then error(#failures .. " assertion(s) failed", 0) end
print("node runtime validated")

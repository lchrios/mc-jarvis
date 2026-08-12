-- A master ingesting node telemetry.
--
-- The node side is driven in node.lua; here the wire format is fed in by hand
-- so the master can be checked in isolation: a remote module has to become
-- indistinguishable from a local one, and a node that goes quiet has to be
-- called out rather than shown as live.

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
-- An explicit identity is what turns networking on.
__TEST.files["data/node.dat"] = textutils.serialise({
    role = "master",
    profile = "master",
    name = "mainframe",
    modules = { "system" },
})

__TEST.addModem("modem_0")

--- One node's telemetry, as it arrives off the wire.
local function snapshotFrom(node, charge, status)
    return {
        version = 1, id = 1, type = "metrics.update",
        source = node, target = "*", timestamp = 0,
        payload = {
            node = node,
            role = "node",
            profile = "power",
            version = "0.5.0",
            uptime = 120,
            modules = {
                {
                    id = "power",
                    name = "Power",
                    icon = "P",
                    status = status or "running",
                    statusText = "OK",
                    available = true,
                    lines = { "842k FE" },
                    gauge = charge,
                    metrics = {
                        { id = "charge", label = "Charge", kind = "percent", value = charge },
                        { id = "stored", label = "Stored", value = 842000, unit = "FE" },
                    },
                    actions = {
                        { id = "balance", label = "BALANCE", enabled = true },
                    },
                },
            },
        },
    }
end

local function registry() return BASEOS.loaded["modules.registry"] end
local function state() return BASEOS.loaded["core.state"] end

---------------------------------------------------------- a node reports in
__TEST.injectAt(20, function()
    check(registry().has("power_node.power") == false, "no remote modules before anything reports")
    return { "rednet_message", 7, snapshotFrom("power_node", 0.82), "baseos" }
end)

__TEST.injectAt(26, function()
    check(registry().has("power_node.power"), "the reported module is registered on the master")

    local snapshot = registry().snapshot("power_node.power")
    check(snapshot ~= nil, "it produces a snapshot like any other module")
    if snapshot then
        check(snapshot.status == "running", "status came from the node")
        check(snapshot.gauge == 0.82, "the tile gauge came from the node")

        local byId = {}
        for _, metric in ipairs(snapshot.metrics or {}) do byId[metric.id] = metric end
        check(byId.charge ~= nil and byId.charge.value == 0.82, "metrics came from the node")
        check(byId._node ~= nil, "the proxy adds which node it lives on")
    end

    local node = state().get("nodes.power_node")
    check(node ~= nil and node.online == true, "the node is tracked as online")

    local actions = registry().actions("power_node.power")
    check(#actions == 1 and actions[1].id == "balance", "the node's actions are offered")
end)

---------------------------------------------------------- a second node
__TEST.injectAt(30, function()
    return { "rednet_message", 8, snapshotFrom("farm_node", 0.30), "baseos" }
end)

__TEST.injectAt(34, function()
    check(registry().has("farm_node.power"), "a second node adds its own modules")
    check(registry().snapshot("power_node.power").gauge == 0.82,
        "nodes do not overwrite each other")
end)

------------------------------------------------- forwarding an action back
__TEST.injectAt(38, function()
    __TEST.clearSent()
    local ok = registry().invoke("power_node.power", "balance")
    check(ok, "invoking a remote action succeeds locally")

    local sent = __TEST.lastSent("command.execute")
    check(sent ~= nil, "it is forwarded to the node as command.execute")
    if sent then
        check(sent.message.payload.module == "power", "addressed to the module on the node")
        check(sent.message.payload.action == "balance", "carrying the action id")
    end
end)

---------------------------------------------------------- the node goes quiet
__TEST.injectAt(44, function()
    -- Backdate the last contact rather than waiting out the real timeout.
    state().set("nodes.power_node.lastSeen", 0)
end)

__TEST.injectAt(70, function()
    local node = state().get("nodes.power_node")
    check(node and node.online == false, "a silent node is marked offline")

    local snapshot = registry().snapshot("power_node.power")
    check(snapshot and snapshot.status == "error", "its modules report an error status")
    check(snapshot and snapshot.statusText == "OFFLINE", "and say OFFLINE rather than stale values")

    local alerts = BASEOS.loaded["services.alerts"]
    check(alerts.get("node.offline.power_node") ~= nil, "an alert is raised for the lost node")

    local actions = registry().actions("power_node.power")
    check(actions[1] and actions[1].enabled == false, "its actions are disabled while offline")
end)

---------------------------------------------------------- the nodes screen
__TEST.injectAt(74, function()
    -- The footer counts nodes; touching that segment opens the list.
    local navigation = BASEOS.loaded["ui.navigation"]
    navigation.push("nodes", {})
end)

__TEST.injectAt(78, function()
    local screen = __TEST.ui.screen()
    check(__TEST.ui.screenName() == "nodes", "the nodes screen opens")

    local list
    for _, child in ipairs(screen and screen.children or {}) do
        if child.items then list = child end
    end
    check(list ~= nil and #list.items == 2, "both nodes are listed")
end)

---------------------------------------------------------------- run
local source = assert(__TEST.files["startup.lua"], "startup.lua not found")
local chunk = assert(load(source, "@startup.lua", "t", _G))
local ok, runError = pcall(chunk)

local snaps = __TEST.snapshots()
print(snaps[#snaps] and snaps[#snaps].screen or "(nothing drawn)")
print("run ok: " .. tostring(ok) .. (ok and "" or (" err=" .. tostring(runError))))

local log = __TEST.files["data/baseos.log"]
if log and log:find("%[ERROR%]") then
    print(log)
    error("log contains ERROR entries", 0)
end
if not ok then error("startup crashed: " .. tostring(runError), 0) end
for _, harnessError in ipairs(__TEST.errors()) do check(false, "harness: " .. harnessError) end

if #failures > 0 then error(#failures .. " assertion(s) failed", 0) end
print("master telemetry validated")

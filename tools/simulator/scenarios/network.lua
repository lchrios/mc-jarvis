-- "Nothing reports and nothing says why."
--
-- The nodes list answers which computers report. When none do, every cause
-- looks the same from there: no modem, wrong protocol, wrong secret, nobody
-- running. This drives the screen that has to tell them apart, and the case it
-- exists for - a computer that is talking and being thrown away - is the one
-- with the most assertions.
--
-- Also covers what the master does with a node's device breakdown, since that
-- only works if the list survives the trip.

local ui = __TEST.ui
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

__TEST.setMaxEvents(140)
__TEST.resizeMonitor(82, 25)
__TEST.addModem("top", true)

__TEST.files["data/node.dat"] = textutils.serialise({
    role = "master", profile = "master", name = "mainframe",
    modules = { "system" },
})

__TEST.files["config/network.lua"] = [[
return {
    enabled = true,
    protocol = "baseos",
    hostname = "mainframe",
    secret = "el secreto de la base",
    telemetry = { publishInterval = 2, staleAfter = 15 },
}
]]

local function auth() return BASEOS.loaded["network.auth"] end

local function rowsOf(screen)
    local text = {}
    for _, row in ipairs(screen:buildRows(70)) do text[#text + 1] = row.text end
    return table.concat(text, "\n")
end

--- A node reporting itself, signed the way a real one would.
local function nodeMessage(id, type_, payload)
    return auth().sign({
        version = 1, id = id, source = "power_node", target = "*",
        type = type_, timestamp = os.epoch("utc"), payload = payload,
    })
end

------------------------------------------------------------ open the screen
__TEST.injectAt(14, function() return ui.touch("NODES") end)
__TEST.injectAt(18, function() return ui.touch("REDNET") end)

__TEST.injectAt(22, function()
    check(ui.screenName() == "network", "NODES -> REDNET opens the network screen")

    local frame = __TEST.monitor.render()
    check(frame:find("mainframe", 1, true) ~= nil, "it says what this computer is called")
    check(frame:find("signed", 1, true) ~= nil, "and that it is signing its messages")

    local rows = rowsOf(ui.screen())
    check(rows:find("MODEMS", 1, true) ~= nil, "the modems are listed")
    check(rows:find("top", 1, true) ~= nil, "including the one on the top face")
    check(rows:find("rednet open", 1, true) ~= nil, "and rednet is open on it")
    check(rows:find("nobody yet", 1, true) ~= nil,
        "nobody has been heard, said as such rather than as an empty list")
end)

--------------------------------------------------------- a signed node lands
__TEST.injectAt(26, function()
    __TEST.receive(12, nodeMessage(1, "node.heartbeat", { role = "node" }))
end)

__TEST.injectAt(30, function()
    local rows = rowsOf(ui.screen())
    check(rows:find("HEARD (1)", 1, true) ~= nil, "a signed computer is counted as heard")
    check(rows:find("power_node", 1, true) ~= nil, "by name")
    check(rows:find("#12", 1, true) ~= nil, "with the computer id it came from")
    check(rows:find("node.heartbeat", 1, true) ~= nil, "and the message shows in the traffic")
end)

------------------------------------------------- ...and a stranger does not
-- The whole point of the screen: this is invisible everywhere else.
__TEST.injectAt(34, function()
    __TEST.receive(9, {
        version = 1, id = 1, source = "intruder", target = "*",
        type = "command.execute", timestamp = os.epoch("utc"),
        payload = { module = "power", action = "stop" },
    })
end)

__TEST.injectAt(38, function()
    local rows = rowsOf(ui.screen())
    check(rows:find("REFUSED", 1, true) ~= nil, "a refused computer gets its own section")
    check(rows:find("computer #9", 1, true) ~= nil, "identified by computer id")
    check(rows:find("unsigned", 1, true) ~= nil, "with the reason it was thrown away")
    check(rows:find("HEARD (1)", 1, true) ~= nil, "and it is not counted as a peer")
end)

------------------------------------------------------------------ ping
__TEST.injectAt(42, function()
    __TEST.clearSent()
    return ui.touch("PING")
end)

__TEST.injectAt(46, function()
    local sent = __TEST.lastSent("node.discover")
    check(sent ~= nil, "PING broadcasts a discover")
    check(sent and sent.message.payload and type(sent.message.payload.at) == "number",
        "carrying the time it was asked, so the reply can be timed")
    check(sent and sent.message.tag ~= nil, "and it is signed like everything else")
end)

--------------------------------------------- the breakdown survives the trip
__TEST.injectAt(50, function()
    __TEST.receive(12, nodeMessage(2, "metrics.update", {
        node = "power_node", role = "node", version = "test", uptime = 120,
        alerts = {}, peripherals = {},
        modules = { {
            id = "power", name = "Power", status = "running", statusText = "OK",
            lines = { "1.5M FE" }, gauge = 0.78,
            metrics = {
                { id = "charge", label = "Charge", kind = "percent", value = 0.78 },
                { id = "stored", label = "Stored", value = 1500000, unit = "FE" },
                { id = "sources", label = "Sources", value = 2 },
            },
            detail = {
                columns = { "CHARGE", "STORED" },
                rows = {
                    { id = "cell_0", name = "powah:energy_cell_nitro_0",
                      percent = 0.78, value = "1.5M",
                      fields = { { label = "Stored", value = "1.5M FE" } } },
                    { id = "cell_1", name = "powah:energy_cell_0",
                      percent = 0.05, value = "12k",
                      fields = { { label = "Stored", value = "12k FE" } } },
                },
            },
        } },
    }))
end)

__TEST.injectAt(56, function()
    local registry = BASEOS.loaded["modules.registry"]
    local record = registry.get("power_node.power")

    check(record ~= nil, "the master registers a proxy for the node's module")
    check(record and record.name == "Power @power_node",
        "named after the node, so two modules called Power are telling apart")

    local snapshot = registry.snapshot("power_node.power")
    check(snapshot and snapshot.detail ~= nil, "the device breakdown arrived with it")
    check(snapshot and snapshot.detail and #snapshot.detail.rows == 2,
        "with a row per cell")

    -- The proxy must offer the breakdown screen, not the generic metric list.
    local factory = registry.detailScreenFactory("power_node.power")
    check(factory ~= nil, "and it offers a detail screen")
    local screen = factory and factory({ moduleId = "power_node.power" })
    check(screen ~= nil, "which builds")
    check(screen and #screen:rows() == 2, "and lists both cells on the master")
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
print("network screen validated")

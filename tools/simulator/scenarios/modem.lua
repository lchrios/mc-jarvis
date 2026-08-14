-- "There is a modem on top and DEVICES tells me nothing."
--
-- A modem is the one peripheral the whole multi-computer side of BaseOS runs
-- on, and it used to fall through every capability check and report "nothing
-- BaseOS understands". This covers the two questions a person actually has in
-- front of the screen: does it know the modem is there, and is it talking to
-- anybody.

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

__TEST.setMaxEvents(90)
__TEST.resizeMonitor(82, 25)

-- A wireless modem on the top face, exactly like the one in the world: CC
-- names a directly attached peripheral after its side.
__TEST.addModem("top", true)
-- ...and a wired one with a cable that reaches two blocks.
__TEST.addModem("modem_1", false, { remote = { "powah:energy_cell_0", "minecraft:barrel_3" } })

__TEST.files["config/network.lua"] = [[
return {
    enabled = true,
    protocol = "baseos",
    hostname = "mainframe",
    secret = "el secreto de la base",
}
]]

local function rowsOf(screen)
    local text = {}
    for _, row in ipairs(screen:buildRows()) do text[#text + 1] = row.text end
    return table.concat(text, "\n")
end

------------------------------------------------------------ the devices tree
__TEST.injectAt(14, function() return ui.touch("DEVICES") end)

__TEST.injectAt(18, function()
    check(ui.screenName() == "peripherals", "DEVICES opens")

    local screen = ui.screen()
    check(rowsOf(screen):find("top", 1, true) ~= nil,
        "the modem on the top face is listed")

    -- Unfold it, the way a finger would.
    screen.expanded["top"] = true
    screen.expanded["modem_1"] = true
    screen:requestLayout()
end)

__TEST.injectAt(22, function()
    local text = rowsOf(ui.screen())

    check(text:find("nothing BaseOS understands", 1, true) == nil,
        "it no longer claims a modem is unreadable")
    check(text:find("wireless modem", 1, true) ~= nil,
        "it says the top one is a wireless modem")
    check(text:find("wired modem", 1, true) ~= nil,
        "and that the other one is wired")
    check(text:find("rednet: open", 1, true) ~= nil,
        "and that rednet actually came up on it")
    check(text:find("2 peripheral(s) on the far side", 1, true) ~= nil,
        "the wired one reports what its cable reaches")
end)

--------------------------------------------------- am I talking to anybody?
__TEST.injectAt(26, function() return ui.back() end)

__TEST.injectAt(30, function() return ui.touch("NODES") end)

__TEST.injectAt(34, function()
    check(ui.screenName() == "nodes", "NODES opens")

    local frame = __TEST.monitor.render()
    check(frame:find("mainframe", 1, true) ~= nil,
        "it says what this computer is called on the network")
    check(frame:find("signed", 1, true) ~= nil, "and that messages are signed")
    -- The distinction that matters: nothing is broken, nobody has spoken.
    check(frame:find("no other computer has been heard", 1, true) ~= nil,
        "and that nobody has answered yet, rather than just an empty list")
end)

------------------------------------------------------- once a node reports
__TEST.injectAt(38, function()
    __TEST.receive(12, {
        version = 1, id = 1, source = "power_node", target = "*",
        type = "node.heartbeat", timestamp = os.epoch("utc"),
        payload = { role = "node" },
    })
end)

__TEST.injectAt(46, function()
    local frame = __TEST.monitor.render()
    -- Unsigned, so it must NOT be counted as a peer: that is the whole point
    -- of the secret. This is the honest outcome, not a failure.
    check(frame:find("no other computer has been heard", 1, true) ~= nil,
        "an unsigned stranger does not count as a peer")
end)

__TEST.injectAt(50, function()
    local auth = BASEOS.loaded["network.auth"]
    __TEST.receive(12, auth.sign({
        version = 1, id = 2, source = "power_node", target = "*",
        type = "node.heartbeat", timestamp = os.epoch("utc"),
        payload = { role = "node" },
    }))
end)

__TEST.injectAt(58, function()
    local frame = __TEST.monitor.render()
    check(frame:find("hearing 1", 1, true) ~= nil,
        "a properly signed one does, and is counted")
    check(frame:find("power_node", 1, true) ~= nil, "by name")
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
print("modem visibility validated")

-- The base map: zones wired together, and lines that react to what happens.
--
-- The point of the pipework is not decoration - a dead node has to be visible
-- as a dead line - so this drives real state changes and checks the routing.

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

__TEST.addEnergyCells(2)

__TEST.files["config/layout.lua"] = [[
return {
    mode = "grid",
    grid = { columns = 12, rows = 6 },
    zones = {
        { id = "power", label = "POWER", module = "power",
          col = 1, row = 1, colSpan = 4, rowSpan = 3,
          links = { { to = "hub", kind = "energy" } } },
        { id = "hub", label = "CENTRAL HUB", module = "system",
          col = 5, row = 1, colSpan = 4, rowSpan = 3 },
        { id = "storage", label = "STORAGE", module = "storage",
          col = 9, row = 1, colSpan = 4, rowSpan = 3,
          -- Declared from both ends on purpose: it is still one pipe.
          links = { { to = "hub" } } },
        { id = "farm", label = "DEMO FARM", module = "demo_farm",
          col = 5, row = 4, colSpan = 4, rowSpan = 3,
          links = { { to = "hub", kind = "items" } } },
    },
}
]]

local function segments()
    local screen = ui.screen()
    return (screen and screen.linkLayer and screen.linkLayer.segments) or {}
end

--- The state of the pipe between two zones, whichever way it was declared.
local function linkState(a, b)
    for _, segment in ipairs(segments()) do
        if (segment.from == a and segment.to == b) or (segment.from == b and segment.to == a) then
            return segment.state
        end
    end
    return nil
end

local function pipeCount(a, b)
    local pairsSeen = {}
    for _, segment in ipairs(segments()) do
        if (segment.from == a and segment.to == b) or (segment.from == b and segment.to == a) then
            pairsSeen[segment.from .. ">" .. segment.to] = true
        end
    end
    local total = 0
    for _ in pairs(pairsSeen) do total = total + 1 end
    return total
end

---------------------------------------------------------------- routed
__TEST.injectAt(22, function()
    check(ui.screenName() == "dashboard", "the map is the dashboard")
    check(#segments() > 0, "links were routed (" .. #segments() .. " cells)")

    check(linkState("power", "hub") ~= nil, "power is wired to the hub")
    check(linkState("farm", "hub") ~= nil, "the farm is wired to the hub")
    check(pipeCount("storage", "hub") == 1,
        "a link declared from both ends is drawn once")

    -- Arrows point into the destination.
    local arrows = 0
    for _, segment in ipairs(segments()) do
        if segment.arrow then arrows = arrows + 1 end
    end
    check(arrows == 3, "each pipe gets one arrowhead (" .. arrows .. ")")
end)

---------------------------------------------------------------- flowing
__TEST.injectAt(28, function()
    check(linkState("power", "hub") == "active",
        "a working source shows an active line (" .. tostring(linkState("power", "hub")) .. ")")
    check(linkState("farm", "hub") == "active", "so does the running farm")
end)

---------------------------------------------------------------- stopped
__TEST.injectAt(32, function() return ui.touch("DEMO FARM") end)
__TEST.injectAt(36, function() return ui.touch("STOP") end)
__TEST.injectAt(40, function() return ui.back() end)

__TEST.injectAt(46, function()
    check(linkState("farm", "hub") == "idle",
        "stopping the farm makes its line idle (" .. tostring(linkState("farm", "hub")) .. ")")
    check(linkState("power", "hub") == "active", "the other lines are unaffected")
end)

---------------------------------------------------------------- broken
__TEST.injectAt(50, function()
    -- Rip the energy cells off the wall: power has nothing left to read.
    __TEST.detach("energy_cell_1")
    __TEST.detach("energy_cell_2")
end)

__TEST.injectAt(62, function()
    local registry = BASEOS.loaded["modules.registry"]
    check(registry.snapshot("power").status == "unavailable",
        "power went unavailable with its devices gone")
    check(linkState("power", "hub") == "broken",
        "and its line turned broken (" .. tostring(linkState("power", "hub")) .. ")")

    for _, segment in ipairs(segments()) do
        if segment.from == "power" or segment.to == "power" then
            check(segment.color == "statusError", "broken lines are drawn in the error colour")
            break
        end
    end
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
print("base map validated")

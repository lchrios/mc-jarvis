-- The `scan` diagnostic against the simulated peripherals.
--
-- This is the tool the user runs in game to prove the computer can actually see
-- their energy blocks, so its output is asserted rather than eyeballed.

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

local remote = __TEST.remote()

--- Run a program with its printed output captured.
local function capture(program, ...)
    local lines = {}
    local realPrint, realPrintError = print, printError
    print = function(...)
        local parts = {}
        for index = 1, select("#", ...) do
            parts[#parts + 1] = tostring((select(index, ...)))
        end
        lines[#lines + 1] = table.concat(parts, " ")
    end
    printError = print

    local chunk = assert(load(assert(remote[program]), "@" .. program, "t", _G))
    local ok, err = pcall(chunk, ...)

    print, printError = realPrint, realPrintError
    if not ok then error(program .. " failed: " .. tostring(err), 0) end
    return table.concat(lines, "\n")
end

---------------------------------------------------------------- no devices
print("[1] a computer with nothing attached")
__TEST.removePeripheral("monitor_0")
__TEST.removePeripheral("minecraft:barrel_0")

local bare = capture("scan.lua")
check(bare:find("No peripherals connected", 1, true) ~= nil, "it says nothing is connected")
check(bare:find("right%-click every modem") ~= nil, "it explains the modem gotcha")

---------------------------------------------------------------- with devices
print("[2] energy cells and a barrel attached")
__TEST.addEnergyCells(4, { powah = true })
__TEST.farmOutput.fill(0.5)
-- Re-attach the barrel the first step removed.
local output = capture("scan.lua")

check(output:find("energy_cell_1", 1, true) ~= nil, "energy cells are listed")
check(output:find("ENERGY", 1, true) ~= nil, "energy readings are shown")
check(output:find("FE", 1, true) ~= nil, "values are labelled in FE")
check(output:find("Energy total", 1, true) ~= nil, "a base-wide total is printed")
check(output:find("no configuration needed", 1, true) ~= nil,
    "it tells the user nothing has to be configured")

print("--- scan output ---")
print(output)

---------------------------------------------------------------- filtered
print("[3] 'scan energy' filters")
local filtered = capture("scan.lua", "energy")
check(filtered:find("energy_cell_1", 1, true) ~= nil, "energy devices survive the filter")

---------------------------------------------------------------- one device
print("[4] 'scan <name>' dumps the methods")
local single = capture("scan.lua", "energy_cell_1")
check(single:find("getEnergy", 1, true) ~= nil, "the raw method list is printed")
check(single:find("method(s)", 1, true) ~= nil, "the method count is printed")

local missing = capture("scan.lua", "does_not_exist")
check(missing:find("No peripheral called", 1, true) ~= nil, "an unknown name is reported")

if #failures > 0 then error(#failures .. " assertion(s) failed", 0) end
print("scan validated")

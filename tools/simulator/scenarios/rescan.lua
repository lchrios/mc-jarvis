-- Automatic rediscovery.
--
-- Attach and detach events cover the easy cases. This covers the ones that
-- arrive with no event at all - a chunk reloading, a modem broken, a block
-- replaced by a different one that reused its name - by adding and removing
-- peripherals behind BaseOS's back and waiting for it to notice on its own.

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

__TEST.setMaxEvents(220)
__TEST.resizeMonitor(82, 25)

__TEST.files["config/modules.lua"] = [[
return { enabled = { "system", "power" }, instances = {}, settings = {} }
]]

-- A short cadence, so a scenario does not have to run for half a minute.
__TEST.files["config/peripherals.lua"] = [[
return {
    aliases = {
        mainMonitor = { type = "monitor", optional = true },
        mainCell    = { type = "modded:energy_cell" },
    },
    rescan = { interval = 3, degradedInterval = 1, deepEvery = 2, minGap = 1 },
}
]]

local function manager() return BASEOS.loaded["peripherals.manager"] end
local function registry() return BASEOS.loaded["modules.registry"] end

local events = { attached = {}, detached = {}, changed = {} }

__TEST.injectAt(6, function()
    local bus = BASEOS.loaded["core.event_bus"]
    bus.on("peripheral.attached", function(p) events.attached[#events.attached + 1] = p end,
        { owner = "scenario" })
    bus.on("peripheral.detached", function(p) events.detached[#events.detached + 1] = p end,
        { owner = "scenario" })
    bus.on("peripheral.changed", function(p) events.changed[#events.changed + 1] = p end,
        { owner = "scenario" })
end)

------------------------------------------------------------- degraded at boot
__TEST.injectAt(10, function()
    local stats = manager().stats()
    check(stats.scans >= 1, "it scanned on boot (" .. stats.scans .. ")")
    check(stats.degraded, "and knows something it was told to expect is missing")
    check(stats.missing[1] == "mainCell",
        "by name: " .. table.concat(stats.missing, ", "))
    check(stats.interval == 1,
        "so it looks again every second, not every 3 (" .. stats.interval .. ")")

    local record = registry().get("power")
    check(record and record.def.status ~= nil, "the power module is loaded")
end)

------------------------------------------------- a peripheral appears silently
__TEST.injectAt(16, function()
    -- No attach event: this is a chunk loading back, or a modem finally
    -- activated while the computer was already running.
    __TEST.addEnergyCells(2)
end)

__TEST.injectAt(30, function()
    check(manager().getByName("energy_cell_1") ~= nil,
        "the rescan found a peripheral that never announced itself")

    local seen = false
    for _, payload in ipairs(events.attached) do
        if payload.name == "energy_cell_1" then
            seen = true
            check(payload.viaScan == true, "and reported it as coming from a scan")
        end
    end
    check(seen, "an attach was published, so the modules heard about it")

    local stats = manager().stats()
    check(stats.degraded == false, "the alias bound, so it is no longer degraded")
    check(stats.interval == 3, "and it goes back to the slow cadence (" .. stats.interval .. ")")
end)

__TEST.injectAt(44, function()
    local snapshot = registry().snapshot("power")
    check(snapshot and snapshot.status ~= "unavailable",
        "power picked the new cells up on its next poll ("
            .. tostring(snapshot and snapshot.status) .. ")")
end)

------------------------------------------------ a peripheral vanishes silently
__TEST.injectAt(48, function()
    -- No detach event either: the chunk went away with the block in it.
    __TEST.removePeripheral("energy_cell_2")
end)

__TEST.injectAt(66, function()
    check(manager().getByName("energy_cell_2") == nil,
        "the rescan dropped a peripheral that vanished without a detach")

    local seen = false
    for _, payload in ipairs(events.detached) do
        if payload.name == "energy_cell_2" then seen = true end
    end
    check(seen, "and published the detach itself")
    check(manager().getByName("energy_cell_1") ~= nil, "the one still there was left alone")
end)

--------------------------------------- a different block behind the same name
__TEST.injectAt(70, function()
    -- Same name, different machine: a bigger cell in the same spot.
    __TEST.replacePeripheral("energy_cell_1", {
        types = { "modded:energy_cell", "modded:big_cell" },
        object = {
            getEnergy = function() return 500000 end,
            getEnergyCapacity = function() return 900000 end,
            getTransferRate = function() return 4000 end,
        },
    })
end)

__TEST.injectAt(120, function()
    local proxy = manager().getByName("energy_cell_1")
    check(proxy ~= nil, "the name is still there")
    check(proxy and proxy.hasMethod("getTransferRate"),
        "the deep pass re-read it and saw the new method")
    check(proxy and proxy.hasType("modded:big_cell"), "and the new type")

    local seen = false
    for _, payload in ipairs(events.changed) do
        if payload.name == "energy_cell_1" then seen = true end
    end
    check(seen, "and said so on the bus")
end)

------------------------------------------ a dead peripheral is dropped on use
__TEST.injectAt(124, function()
    __TEST.removePeripheral("energy_cell_1")

    -- Something calls it before any scheduled scan comes round.
    local proxy = manager().getByName("energy_cell_1")
    if proxy then proxy.call("getEnergy") end
end)

__TEST.injectAt(126, function()
    check(manager().getByName("energy_cell_1") == nil,
        "a call that fails on a peripheral that is gone drops it immediately")
end)

------------------------------------------------------------- the panel button
__TEST.injectAt(132, function() return ui.touch("DEVICES") end)

__TEST.injectAt(136, function()
    check(ui.screenName() == "peripherals", "DEVICES opens the tree")
    __TEST.addEnergyCells(3)
    return ui.touch("RESCAN NOW")
end)

__TEST.injectAt(140, function()
    check(manager().getByName("energy_cell_3") ~= nil,
        "RESCAN NOW picks up a modem you just enabled, without waiting")
end)

---------------------------------------------------------------- run
local source = assert(__TEST.files["startup.lua"], "startup.lua not found")
local chunk = assert(load(source, "@startup.lua", "t", _G))
local ok, runError = pcall(chunk)

local snaps = __TEST.snapshots()
if snaps[#snaps] then print(snaps[#snaps].screen) end
print("run ok: " .. tostring(ok) .. (ok and "" or (" err=" .. tostring(runError))))

local log = __TEST.files["data/baseos.log"]
if log and log:find("%[ERROR%]") then
    print(log)
    error("log contains ERROR entries", 0)
end
if not ok then error("startup crashed: " .. tostring(runError), 0) end
for _, harnessError in ipairs(__TEST.errors()) do check(false, "harness: " .. harnessError) end

if #failures > 0 then error(#failures .. " assertion(s) failed", 0) end
print("automatic rediscovery validated")

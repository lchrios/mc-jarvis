-- Real farm module against a real peripheral.
--
-- Rewrites config/modules.lua with a farm instance, then boots. The simulated
-- barrel only produces while its redstone side is powered, so this exercises
-- the whole chain end to end: config -> template instance -> peripheral alias
-- -> inventory adapter -> rate/buffer metrics -> alert -> UI button -> redstone.

local ui = __TEST.ui
local failures = {}

local function check(condition, message)
    if condition then return true end
    failures[#failures + 1] = message
    print("  FAIL: " .. message)
    return false
end

local function pass(message) print("  ok: " .. message) end

---------------------------------------------------------------- config
__TEST.files["config/modules.lua"] = [[
return {
    enabled = { "system", "storage" },
    instances = {
        {
            id = "mob_farm",
            template = "farm",
            name = "Mob Farm",
            icon = "M",
            pollInterval = 1,
            settings = {
                output  = { type = "minecraft:barrel" },
                control = { kind = "redstone", side = "back" },
                bufferWarn = 0.50,
                bufferClear = 0.30,
                targetRate = 120,
                idleAfter = 30,
            },
        },
    },
    settings = {},
}
]]

__TEST.files["config/layout.lua"] = [[
return {
    mode = "grid",
    grid = { columns = 12, rows = 6 },
    zones = {
        { id = "hub",  label = "CENTRAL HUB", module = "system",   col = 1, row = 1, colSpan = 6, rowSpan = 3 },
        { id = "stor", label = "STORAGE",     module = "storage",  col = 7, row = 1, colSpan = 6, rowSpan = 3 },
        { id = "farm", label = "MOB FARM",    module = "mob_farm", col = 1, row = 4, colSpan = 12, rowSpan = 3 },
    },
}
]]

local function farm()
    local record = BASEOS.loaded["modules.registry"].get("mob_farm")
    return record and record.def or nil
end

---------------------------------------------------------------- assertions
__TEST.injectAt(12, function()
    check(farm() ~= nil, "the farm instance is registered from config")
    if farm() then
        check(farm().running == false, "farm adopts the current redstone state (off) at boot")
        check(farm().available ~= false, "the barrel satisfied the output requirement")
    end
end)

-- Open the farm detail view and start it. Zone tiles live on the map screen,
-- which the dashboard action bar opens.
__TEST.injectAt(16, function() return ui.touch("MAP") end)
__TEST.injectAt(20, function() return ui.touch("MOB FARM") end)
__TEST.injectAt(24, function()
    check(ui.screenName() == "module_detail", "the farm tile opens its detail view")
    return ui.touch("START")
end)
__TEST.injectAt(28, function()
    check(__TEST.redstone("back") == true, "START powers the configured redstone side")
    check(farm().running == true, "the farm reports itself running")
end)

-- Let it produce, then check the measured rate and the buffer alert.
__TEST.injectAt(70, function()
    local instance = farm()
    check((instance.itemCount or 0) > 0, "items measured in the output barrel")
    check((instance.itemsPerMinute or 0) > 0, "a throughput was computed from the buffer delta")
    check((instance.produced or 0) > 0, "produced total accumulates")
    print(("  rate=%.0f/min buffer=%.0f%% items=%d slots=%d/%d"):format(
        instance.itemsPerMinute or 0, (instance.buffer or 0) * 100,
        instance.itemCount or 0, instance.slotsUsed or 0, instance.slotCount or 0))
end)

-- Fill the barrel past the warning threshold and expect an alert.
__TEST.injectAt(76, function() __TEST.farmOutput.fill(0.95) end)
__TEST.injectAt(84, function()
    local alerts = BASEOS.loaded["services.alerts"]
    check(alerts.get("mob_farm.buffer_full") ~= nil, "a full buffer raises an alert")
    check(farm().backedUp == true, "status reflects the backed up buffer")
end)

-- Drain it and expect the alert to clear (hysteresis: below bufferClear).
__TEST.injectAt(88, function() __TEST.farmOutput.drain() end)
__TEST.injectAt(96, function()
    local alerts = BASEOS.loaded["services.alerts"]
    check(alerts.get("mob_farm.buffer_full") == nil, "draining the buffer clears the alert")
end)

-- Stop the farm and confirm production really halts.
local producedAtStop
__TEST.injectAt(100, function() return ui.touch("STOP") end)
__TEST.injectAt(104, function()
    check(__TEST.redstone("back") == false, "STOP cuts the redstone signal")
    producedAtStop = __TEST.farmOutput.produced()
end)
__TEST.injectAt(130, function()
    check(farm().running == false, "the farm stays stopped")
    -- Compare against the level at the moment of the stop: what the farm made
    -- while it was running is not evidence of anything.
    check(__TEST.farmOutput.produced() <= producedAtStop,
        ("a stopped farm produces nothing (was %.0f, now %.0f)")
            :format(producedAtStop or -1, __TEST.farmOutput.produced()))
    check((farm().itemsPerMinute or -1) == 0, "the measured rate falls back to zero")
end)

---------------------------------------------------------------- run
local source = assert(__TEST.files["startup.lua"], "startup.lua not found")
local chunk, parseError = load(source, "@startup.lua", "t", _G)
if not chunk then error("startup.lua does not parse: " .. tostring(parseError)) end

local ok, runError = pcall(chunk)

local snaps = __TEST.snapshots()
for index = math.max(1, #snaps - 1), #snaps do
    if snaps[index] then
        print(("================ SNAPSHOT %d (%s) ================"):format(index, snaps[index].label))
        print(snaps[index].screen)
    end
end

print("run ok: " .. tostring(ok) .. (ok and "" or (" err=" .. tostring(runError))))

local log = __TEST.files["data/baseos.log"]
if log and log:find("%[ERROR%]") then
    print(log)
    error("log contains ERROR entries", 0)
end
if not ok then error("startup crashed: " .. tostring(runError), 0) end
for _, harnessError in ipairs(__TEST.errors()) do check(false, "harness: " .. harnessError) end
check(not __TEST.crashed(), "startup.lua printed its crash banner")

if #failures > 0 then error(#failures .. " assertion(s) failed", 0) end
pass("full farm chain validated")

-- Default scenario: boot on a monitor and walk the UI, asserting the effect of
-- every interaction.
--
-- Touches are located by label at delivery time, never by coordinate, so the
-- walkthrough keeps testing the same buttons after a layout change. They are
-- also spaced out over the event stream so the scheduler polls in between and
-- the snapshots show live data instead of boot values.

local ui = __TEST.ui
local failures = {}

local function check(condition, message)
    if condition then return true end
    failures[#failures + 1] = message
    print("  FAIL: " .. message)
    return false
end

local function farm() return BASEOS.loaded["modules.demo_farm"] end

-- { event index, what to touch, what must be true afterwards }
local steps = {
    { 30, function() return ui.touch("CENTRAL HUB") end },
    { 33, nil, function() check(ui.screenName() == "module_detail", "hub opens the detail screen") end },

    { 36, function() return ui.back() end },
    { 39, nil, function() check(ui.screenName() == "dashboard", "back returns to the dashboard") end },

    { 42, function() return ui.touch("DEMO FARM") end },
    { 45, function() return ui.touch("STOP") end },
    { 48, nil, function() check(farm().running == false, "STOP stops the farm") end },

    { 51, function() return ui.touch("START") end },
    { 54, nil, function() check(farm().running == true, "START restarts the farm") end },

    { 57, function() return ui.back() end },
    { 60, function() return ui.touch("ALERTS") end },
    { 63, nil, function() check(ui.screenName() == "alerts", "the alerts zone opens the alerts screen") end },

    { 66, function() return ui.back() end },
    { 69, function() return ui.touch("ALL MODULES") end },
    { 72, nil, function() check(ui.screenName() == "module_list", "the modules zone opens the list") end },
}

for _, step in ipairs(steps) do
    local index, touch, assertion = step[1], step[2], step[3]
    __TEST.injectAt(index, function()
        if assertion then assertion() end
        return touch and touch() or nil
    end)
end

local source = assert(__TEST.files["startup.lua"], "startup.lua not found")
local chunk, parseError = load(source, "@startup.lua", "t", _G)
if not chunk then error("startup.lua does not parse: " .. tostring(parseError)) end

local ok, runError = pcall(chunk)

local only = tonumber(os.getenv and os.getenv("SNAPSHOT") or nil)
for index, snap in ipairs(__TEST.snapshots()) do
    if not only or only == index then
        print(("================ SNAPSHOT %d (%s) ================"):format(index, snap.label))
        print(snap.screen)
    end
end

print(("events processed: %d, pending: %d"):format(__TEST.processed(), __TEST.pending()))

if BASEOS and BASEOS.loaded["core.scheduler"] then
    print("--- scheduler tasks ---")
    for _, task in ipairs(BASEOS.loaded["core.scheduler"].list()) do
        print(("  %-24s every %.2fs runs=%d failures=%d"):format(
            task.name, task.interval, task.runs, task.failures))
    end
end

print("run ok: " .. tostring(ok) .. (ok and "" or (" err=" .. tostring(runError))))

local log = __TEST.files["data/baseos.log"]
if log and log:find("%[ERROR%]") then
    print(log)
    error("log contains ERROR entries", 0)
end
-- A crashed run must fail the scenario, not just print a line. BaseOS catches
-- its own errors, so check the harness and the crash banner too.
if not ok then error("startup crashed: " .. tostring(runError), 0) end
for _, harnessError in ipairs(__TEST.errors()) do
    check(false, "harness: " .. harnessError)
end
check(not __TEST.crashed(), "startup.lua printed its crash banner")
if #failures > 0 then
    error(#failures .. " UI assertion(s) failed", 0)
end
print("all UI assertions passed")

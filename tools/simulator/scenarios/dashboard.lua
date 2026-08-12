-- The main dashboard: headline figures, live systems, activity, actions.
--
-- Touches are located by label at delivery time, never by coordinate, so the
-- walkthrough keeps testing the same controls after a layout change. They are
-- spaced out over the event stream so the scheduler polls in between and the
-- snapshots show live data instead of boot values.

local ui = __TEST.ui
local failures = {}

local function check(condition, message)
    if condition then return true end
    failures[#failures + 1] = message
    print("  FAIL: " .. message)
    return false
end

local function farm() return BASEOS.loaded["modules.demo_farm"] end
local function screen() return ui.screen() end

--- The systems list, which draws its own rows and so has no findable labels.
local function systemsList()
    for _, child in ipairs(screen() and screen().children or {}) do
        if child.drawItem then return child end
    end
    return nil
end

local steps = {
    { 24, nil, function()
        check(ui.screenName() == "dashboard", "the dashboard is the home screen")
        local list = systemsList()
        check(list ~= nil, "there is a systems list")
        check(list and #list.items == 4, "every module has a row")
    end },

    -- The stat row doubles as navigation.
    { 28, function() return ui.touch("Alerts") end },
    { 32, nil, function() check(ui.screenName() == "alerts", "the ALERTS stat opens the alert list") end },
    { 36, function() return ui.back() end },

    -- Touching a system row opens that module.
    { 40, function()
        local list = systemsList()
        if not list then return nil end
        -- Rows are painted, not components: address one by position.
        return { "monitor_touch", "monitor_0", list.x + 2, list.y }
    end },
    { 44, nil, function()
        check(ui.screenName() == "module_detail", "a system row opens its module")
    end },
    { 48, function() return ui.back() end },

    -- The action bar.
    { 52, function() return ui.touch("MAP") end },
    { 56, nil, function() check(ui.screenName() == "map", "MAP opens the base plan") end },
    { 60, function() return ui.back() end },

    { 64, function() return ui.touch("DEVICES") end },
    { 68, nil, function() check(ui.screenName() == "peripherals", "DEVICES opens the device tree") end },
    { 72, function() return ui.back() end },

    -- Anything notable shows up in the feed.
    { 76, nil, function()
        local activity = BASEOS.loaded["services.activity"]
        check(activity.count() > 0, "the activity feed recorded something")
    end },
    { 80, nil, function()
        check(ui.screenName() == "dashboard", "and we are back on the dashboard")
    end },
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
print("run ok: " .. tostring(ok) .. (ok and "" or (" err=" .. tostring(runError))))

local log = __TEST.files["data/baseos.log"]
if log and log:find("%[ERROR%]") then
    print(log)
    error("log contains ERROR entries", 0)
end
if not ok then error("startup crashed: " .. tostring(runError), 0) end
for _, harnessError in ipairs(__TEST.errors()) do
    check(false, "harness: " .. harnessError)
end
check(not __TEST.crashed(), "startup.lua printed its crash banner")

if #failures > 0 then error(#failures .. " UI assertion(s) failed", 0) end
print("all dashboard assertions passed")

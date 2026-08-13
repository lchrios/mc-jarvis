-- The rules editor: turn a shipped rule on, change it, and add one, all from
-- the monitor.
--
-- The point is that an edit reaches the *running* engine and survives, so this
-- drives the real buttons and then checks the store and the farm, not just the
-- editor's own working copy.

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

__TEST.setMaxEvents(200)
__TEST.resizeMonitor(82, 25)

__TEST.files["config/modules.lua"] = [[
return { enabled = { "system", "demo_farm" }, instances = {}, settings = {} }
]]

-- Two rules exactly as they ship: both turned off.
__TEST.files["config/rules.lua"] = [[
return {
    enabled = true,
    interval = 1,
    rules = {
        {
            id = "backpressure",
            name = "Granja atascada",
            enabled = false,
            when   = { metric = "demo_farm.buffer", op = ">=", value = 0.9 },
            do_    = "demo_farm.stop",
            until_ = { metric = "demo_farm.buffer", op = "<=", value = 0.3 },
            after  = "60s",
            then_  = "demo_farm.start",
        },
        {
            id = "nobody_home",
            name = "Base vacia",
            enabled = false,
            when = { players = { online = 0 } },
            do_  = { alert = { severity = "warning", message = "vacia" } },
        },
    },
}
]]

local function engine() return BASEOS.loaded["services.rules"] end
local function registry() return BASEOS.loaded["modules.registry"] end
local function farm()
    local record = registry().get("demo_farm")
    return record and record.def or nil
end

local function ruleState(id)
    for _, rule in ipairs(engine().list()) do
        if rule.id == id then return rule end
    end
    return nil
end

local function storedRule(id)
    for _, rule in ipairs(engine().current()) do
        if rule.id == id then return rule end
    end
    return nil
end

local function select(id)
    local screen = ui.screen()
    screen.selected = id
    screen:requestLayout()
end

------------------------------------------------------------ shipped off
__TEST.injectAt(14, function()
    check(#engine().list() == 2, "the shipped rules loaded")
    for _, rule in ipairs(engine().list()) do
        check(rule.enabled == false, "'" .. rule.id .. "' ships turned off")
    end
    check(engine().hasOverride() == false, "and nothing has been edited yet")

    farm().buffer = 0.95
    farm().running = true
end)

__TEST.injectAt(22, function()
    check(ruleState("backpressure").phase == "idle",
        "a rule that is off does not act, even with its condition true")
    check(farm().running == true, "so the farm keeps going")
end)

------------------------------------------------------------ turn one on
__TEST.injectAt(26, function() return ui.touch("RULES") end)

__TEST.injectAt(30, function()
    check(ui.screenName() == "rules", "the RULES action opens the list")
    select("backpressure")
end)

__TEST.injectAt(34, function() return ui.touch("TURN ON") end)

__TEST.injectAt(40, function()
    check(ruleState("backpressure").enabled, "the switch turned it on")
    check(engine().hasOverride(), "which was written to data/")
    check(__TEST.files["data/rules.dat"] ~= nil, "as a file")
    check(storedRule("nobody_home").enabled == false, "the other one stayed off")
end)

__TEST.injectAt(48, function()
    check(ruleState("backpressure").phase == "acting",
        "and the running engine picked it up without a reboot")
    check(farm().running == false, "so the farm actually stopped")

    -- Put it back so the rule idles again and the rest of the run is quiet.
    farm().buffer = 0.1
end)

------------------------------------------------------------ edit a field
__TEST.injectAt(56, function()
    check(ruleState("backpressure").phase == "idle", "it left once the buffer drained")
    select("backpressure")
end)

__TEST.injectAt(60, function() return ui.touch("EDIT") end)

__TEST.injectAt(64, function()
    check(ui.screenName() == "rule_edit", "EDIT opens the rule")

    local screen = ui.screen()
    check(screen.draft.id == "backpressure", "with that rule loaded")

    -- The fields read as words, not as Lua.
    local described = screen.describeCondition(screen.draft.when)
    check(described:find("demo_farm.buffer", 1, true) ~= nil,
        "the condition reads back as text (" .. described .. ")")
    check(described:find(">=", 1, true) ~= nil, "including the comparison")
    check(screen.describeAction(screen.draft.do_) == "demo_farm.stop",
        "and so does the action")

    -- Change the threshold, the way the value keyboard would.
    screen.draft.when.value = 0.5
    screen:touch()
    check(screen.edited == true, "changing a field marks the rule as edited")
end)

__TEST.injectAt(68, function() return ui.touch("SAVE") end)

__TEST.injectAt(74, function()
    check(ui.screenName() == "rules", "saving returns to the list")

    local saved = storedRule("backpressure")
    check(saved and saved.when.value == 0.5, "the edited threshold was stored")
    check(saved and saved.enabled == true, "and it is still turned on")

    local stored = textutils.unserialise(__TEST.files["data/rules.dat"])
    check(stored ~= nil and #stored.rules == 2, "both rules are in the override")
    check(__TEST.files["config/rules.lua"]:find("0.9", 1, true) ~= nil,
        "config/rules.lua was left untouched")
end)

------------------------------------------------------------ a new rule
__TEST.injectAt(78, function() return ui.touch("NEW") end)

__TEST.injectAt(82, function()
    check(ui.screenName() == "rule_edit", "NEW opens an empty rule")

    local screen = ui.screen()
    check(screen.draft.enabled == false, "created turned off")
    check(#engine().current() == 3, "and already in the set, so it is not lost")

    -- An unfinished rule must not be saveable.
    screen:save()
    check(ui.screenName() == "rule_edit", "saving an incomplete rule is refused")
end)

__TEST.injectAt(86, function()
    local screen = ui.screen()
    screen.draft.name = "Vaciar buffer"
    screen.draft.when = { metric = "demo_farm.buffer", op = ">=", value = 0.99 }
    screen.draft.do_ = "demo_farm.stop"
    screen:save()
end)

__TEST.injectAt(92, function()
    check(ui.screenName() == "rules", "a complete rule saves and closes")
    local saved = storedRule("rule_3")
    check(saved ~= nil, "the new rule is in the store")
    check(saved and saved.name == "Vaciar buffer", "under the name given to it")
    check(saved and saved.enabled == false, "still off until somebody turns it on")
    check(#engine().list() == 3, "and the engine knows about all three")
end)

------------------------------------------------------------ delete it
__TEST.injectAt(96, function()
    select("rule_3")
end)

__TEST.injectAt(100, function() return ui.touch("EDIT") end)

__TEST.injectAt(104, function() return ui.touch("DELETE") end)

__TEST.injectAt(108, function()
    local screen = ui.screen()
    check(screen.modal ~= nil, "DELETE asks first")
    return ui.touch("DELETE")   -- the modal's button, searched before the screen
end)

__TEST.injectAt(114, function()
    check(ui.screenName() == "rules", "confirming returns to the list")
    check(storedRule("rule_3") == nil, "and the rule is gone")
    check(#engine().list() == 2, "leaving the two shipped ones")
end)

------------------------------------------------------------ back to shipped
__TEST.injectAt(118, function() return ui.touch("RESET") end)

__TEST.injectAt(122, function()
    check(ui.screen().modal ~= nil, "RESET asks first too")
    return ui.touch("DISCARD")
end)

__TEST.injectAt(128, function()
    check(engine().hasOverride() == false, "RESET goes back to the shipped rules")
    check(ruleState("backpressure").enabled == false, "which are off again")
    check(storedRule("backpressure").when.value == 0.9,
        "with the original threshold, because config was never written")
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
print("rule editor validated")

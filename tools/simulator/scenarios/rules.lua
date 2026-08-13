-- The automation engine.
--
-- The case that shaped the design: a rule must leave on its exit *condition* or
-- its timeout, whichever comes first. A fixed timer either wastes production or
-- restarts into a still-full buffer.

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

-- The timeout path needs real simulated seconds to elapse.
__TEST.setMaxEvents(280)

__TEST.addAdvancedPeripheral("player_detector")

__TEST.files["config/modules.lua"] = [[
return { enabled = { "system", "demo_farm" }, instances = {}, settings = {} }
]]

__TEST.files["config/rules.lua"] = [[
return {
    enabled = true,
    interval = 1,
    rules = {
        {
            id = "backpressure",
            name = "Farm backpressure",
            when   = { metric = "demo_farm.buffer", op = ">=", value = 0.9 },
            do_    = "demo_farm.stop",
            until_ = { metric = "demo_farm.buffer", op = "<=", value = 0.3 },
            after  = "20s",
            then_  = "demo_farm.start",
        },
        {
            id = "empty_base",
            name = "Nobody home",
            when = { players = { online = 0 } },
            do_  = { alert = { severity = "warning", message = "base empty" } },
            until_ = { players = { atLeast = 1 } },
            then_  = { clearAlert = true },
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

------------------------------------------------------- loaded and idle
__TEST.injectAt(14, function()
    check(#engine().list() == 2, "both rules loaded from config")
    check(ruleState("backpressure").phase == "idle", "and start idle")

    -- Keep the farm's own drift out of the way; this test drives the buffer.
    farm().buffer = 0.1
    farm().running = true
end)

------------------------------------------------------- entry
__TEST.injectAt(20, function()
    farm().buffer = 0.95
end)

__TEST.injectAt(26, function()
    local rule = ruleState("backpressure")
    check(rule.phase == "acting", "the rule entered when the buffer filled")
    check(farm().running == false, "and stopped the farm")
    check(rule.remaining ~= nil and rule.remaining > 0, "with its timeout counting down")
end)

------------------------------------------- exit by condition, before the timeout
__TEST.injectAt(30, function()
    -- The buffer drains long before the 20s deadline.
    farm().buffer = 0.2
end)

__TEST.injectAt(36, function()
    local rule = ruleState("backpressure")
    check(rule.phase == "idle", "it left as soon as the buffer drained")
    check(rule.lastReason == "condition",
        "by condition, not by timeout (" .. tostring(rule.lastReason) .. ")")
    check(farm().running == true, "and restarted the farm")
end)

------------------------------------------------------- exit by timeout
__TEST.injectAt(40, function()
    -- Fill it and keep it full: only the deadline can end this one.
    farm().buffer = 0.95
end)

__TEST.injectAt(46, function()
    check(ruleState("backpressure").phase == "acting", "it entered again")
    -- Hold the buffer full so the exit condition never fires.
    farm().buffer = 0.95
end)

__TEST.injectAt(190, function()
    local rule = ruleState("backpressure")
    check(rule.phase == "idle", "a stuck buffer still ends the rule")
    check(rule.lastReason == "timeout",
        "by timeout this time (" .. tostring(rule.lastReason) .. ")")
end)

------------------------------------------------------- a human wins
__TEST.injectAt(196, function()
    farm().buffer = 0.95
end)

__TEST.injectAt(202, function()
    check(ruleState("backpressure").phase == "acting", "the rule is acting again")

    -- Somebody presses START on the panel while the rule holds it stopped.
    registry().invoke("demo_farm", "start")
end)

__TEST.injectAt(206, function()
    local rule = ruleState("backpressure")
    check(rule.phase == "idle", "pressing the button released the rule")
    check(rule.yielded, "and it marked itself yielded")
    check(farm().running == true, "the farm stayed as the human left it")
end)

__TEST.injectAt(214, function()
    -- Still full, but the rule must not grab it back.
    farm().buffer = 0.95
    check(ruleState("backpressure").phase == "idle",
        "it does not immediately take over again")
    check(farm().running == true, "so the farm is still running")
end)

__TEST.injectAt(220, function()
    -- The condition falls away, which is what re-arms the rule.
    farm().buffer = 0.1
end)

__TEST.injectAt(228, function()
    check(ruleState("backpressure").yielded == false, "the rule re-arms once the condition clears")
    farm().buffer = 0.95
end)

__TEST.injectAt(236, function()
    check(ruleState("backpressure").phase == "acting", "and acts on the next occurrence")
end)

------------------------------------------------------- other condition kinds
__TEST.injectAt(242, function()
    local alerts = BASEOS.loaded["services.alerts"]
    check(alerts.get("rule.empty_base") ~= nil,
        "a player condition fired with nobody online")

    __TEST.setPlayers({ { name = "lchrios", distance = 2 } })
end)

__TEST.injectAt(252, function()
    local alerts = BASEOS.loaded["services.alerts"]
    check(alerts.get("rule.empty_base") == nil,
        "and cleared when somebody logged in")
end)

---------------------------------------------------------------- run
local source = assert(__TEST.files["startup.lua"], "startup.lua not found")
local chunk = assert(load(source, "@startup.lua", "t", _G))
local ok, runError = pcall(chunk)

print("run ok: " .. tostring(ok) .. (ok and "" or (" err=" .. tostring(runError))))

local log = __TEST.files["data/baseos.log"]
if log and log:find("%[ERROR%]") then
    print(log)
    error("log contains ERROR entries", 0)
end
if not ok then error("startup crashed: " .. tostring(runError), 0) end
for _, harnessError in ipairs(__TEST.errors()) do check(false, "harness: " .. harnessError) end

if #failures > 0 then error(#failures .. " assertion(s) failed", 0) end
print("rules engine validated")

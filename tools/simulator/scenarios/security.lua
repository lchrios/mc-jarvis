-- Security profiles: who may press what.
--
-- Both modes are driven for real, because the difference between them is the
-- whole point: `session` knows who clicked, `proximity` only knows who is
-- standing nearby.

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

__TEST.addAdvancedPeripheral("player_detector")

__TEST.files["config/modules.lua"] = [[
return {
    enabled = { "system", "demo_farm" },
    instances = {},
    settings = {},
}
]]

__TEST.files["config/security.lua"] = [[
return {
    enabled = true,
    mode = "session",
    sessionSeconds = 30,
    enrollSeconds = 30,
    failOpen = false,
    protect = { "*.stop", "*.start" },
    users = {
        { player = "lchrios", role = "admin" },
    },
}
]]

local function registry() return BASEOS.loaded["modules.registry"] end
local function security() return BASEOS.loaded["services.security"] end
local function farm()
    local record = registry().get("demo_farm")
    return record and record.def or nil
end

------------------------------------------------------- protection applies
__TEST.injectAt(14, function()
    check(security().settings().enabled, "security is on")
    check(security().isProtected("demo_farm.stop"), "a protected pattern matches")
    check(security().isProtected("demo_farm.flush") == false,
        "an unprotected action is not guarded")
end)

------------------------------------------------------- nobody identified
__TEST.injectAt(18, function()
    local wasRunning = farm().running
    local ok, err = registry().invoke("demo_farm", "stop")

    check(ok == false, "a protected action is refused with no session")
    check(tostring(err):find("badge in", 1, true) ~= nil,
        "and the reason tells you what to do (" .. tostring(err) .. ")")
    check(farm().running == wasRunning, "the farm really did not stop")

    -- Unprotected ones still work.
    local flushed = registry().invoke("demo_farm", "flush")
    check(flushed, "an unprotected action still runs")
end)

------------------------------------------------------- badging in
__TEST.injectAt(22, function()
    -- Advanced Peripherals fires this when a player right-clicks the detector.
    return { "playerClick", "lchrios" }
end)

__TEST.injectAt(26, function()
    local session = security().session()
    check(session ~= nil, "playerClick opened a session")
    check(session and session.player == "lchrios", "for the player who clicked")
    check(session and session.role == "admin", "matched to their role")

    local ok = registry().invoke("demo_farm", "stop")
    check(ok, "and now the protected action runs")
    check(farm().running == false, "the farm actually stopped")
end)

------------------------------------------------------- profile limits
------------------------------------------------------- enrolling by click
__TEST.injectAt(30, function()
    -- An admin arms listening mode, then somebody else touches the detector.
    local ok, err = security().armEnrollment("operator", "lchrios")
    check(ok, "an admin can arm listening mode (" .. tostring(err) .. ")")
    check(security().enrollment() ~= nil, "and it is armed")
end)

__TEST.injectAt(34, function()
    -- The admin badging in again must not enrol themselves.
    return { "playerClick", "lchrios" }
end)

__TEST.injectAt(38, function()
    check(security().enrollment().candidate == nil,
        "the admin's own clicks are ignored while listening")
    return { "playerClick", "visitante" }
end)

__TEST.injectAt(42, function()
    local request = security().enrollment()
    check(request and request.candidate == "visitante", "the next player is captured")
    check(security().user("visitante") == nil, "but not registered until confirmed")

    local ok = security().confirmEnrollment()
    check(ok, "confirming registers them")
    check(security().roleOf("visitante") == "operator", "with the chosen role")
    check(security().enrollment() == nil, "and listening stops")
end)

------------------------------------------------------- role limits
__TEST.injectAt(46, function()
    return { "playerClick", "visitante" }
end)

__TEST.injectAt(50, function()
    check(security().session().role == "operator", "a second badge in replaces the session")

    local ok = registry().invoke("demo_farm", "start")
    check(ok, "the operator may start")

    check(security().canManage("visitante") == false, "but may not manage users")

    local added, err = security().armEnrollment("admin", "visitante")
    check(added == false, "and cannot arm listening mode")
    check(tostring(err):find("manage", 1, true) ~= nil, "with a reason (" .. tostring(err) .. ")")
end)

------------------------------------------------------- adding by name
__TEST.injectAt(54, function()
    local ok = security().addUser("amigo", "viewer", "lchrios")
    check(ok, "a player can be added by name")
    check(security().roleOf("amigo") == "viewer", "with the role given")
    check(__TEST.files["data/security.dat"] ~= nil, "and it is written to data/")

    local removed = security().removeUser("amigo")
    check(removed, "and removed again")
    check(security().roleOf("amigo") == nil, "leaving no access")

    local protectedUser, reason = security().removeUser("lchrios")
    check(protectedUser == false, "a user declared in config cannot be removed from the panel")
    check(tostring(reason):find("config", 1, true) ~= nil, "and says where to edit it")
end)

------------------------------------------------------- unknown player
__TEST.injectAt(58, function()
    return { "playerClick", "desconocido" }
end)

__TEST.injectAt(62, function()
    -- The previous session is untouched: an unknown player cannot take it over,
    -- but neither does badging in as a stranger grant anything.
    local denials = security().denials()
    local sawUnknown = false
    for _, denial in ipairs(denials) do
        if denial.player == "desconocido" then sawUnknown = true end
    end
    check(sawUnknown, "an unregistered player badging in is recorded as a denial")
end)

------------------------------------------------------- session expiry
__TEST.injectAt(66, function()
    local session = security().session()
    if session then session.expiresAt = 0 end
end)

__TEST.injectAt(70, function()
    check(security().session() == nil, "a session expires")
    local ok = registry().invoke("demo_farm", "stop")
    check(ok == false, "and protection comes back")
end)

------------------------------------------------------- proximity mode
__TEST.injectAt(74, function()
    -- Switch modes in place rather than rebooting the whole scenario.
    local settings = security().settings()
    settings.mode = "proximity"
    security().start(BASEOS.loaded["core.app"].context())
end)

__TEST.injectAt(78, function()
    -- start() re-reads config, so force the mode through the config layer.
    BASEOS.loaded["core.config"].set("security.mode", "proximity")
    security().start(BASEOS.loaded["core.app"].context())
    __TEST.setPlayers({})
end)

__TEST.injectAt(84, function()
    check(security().settings().mode == "proximity", "proximity mode is active")
    local ok, err = registry().invoke("demo_farm", "stop")
    check(ok == false, "with nobody in range the action is refused")
    check(tostring(err):find("range", 1, true) ~= nil,
        "and says so (" .. tostring(err) .. ")")
end)

__TEST.injectAt(88, function()
    __TEST.setPlayers({ { name = "lchrios", distance = 3 } })
end)

__TEST.injectAt(92, function()
    local ok = registry().invoke("demo_farm", "stop")
    check(ok, "an authorised player in range unlocks it")

    __TEST.setPlayers({ { name = "desconocido", distance = 3 } })
    local refused = registry().invoke("demo_farm", "stop")
    check(refused == false, "an unauthorised player in range does not")
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
print("security profiles validated")

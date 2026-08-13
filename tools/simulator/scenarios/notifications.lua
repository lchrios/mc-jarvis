-- Which notifications reach chat.
--
-- The catalogue decides what is worth saying; the notifier decides how it gets
-- there. This drives real events through both and reads the Chat Box log, so a
-- topic that is off has to leave chat silent, not merely record that it was
-- off somewhere.

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

__TEST.setMaxEvents(180)
__TEST.resizeMonitor(82, 25)

__TEST.addAdvancedPeripheral("chat_box")
__TEST.addAdvancedPeripheral("player_detector")

__TEST.files["config/modules.lua"] = [[
return {
    enabled = { "system", "demo_farm", "presence", "notifier" },
    instances = {},
    settings = {
        notifier = { cooldown = 1, maxPerMinute = 60 },
        presence = {
            zones = {
                { id = "door", name = "Front door", radius = 8,
                  output = { kind = "redstone", side = "left" } },
            },
        },
    },
}
]]

-- Deliberately not the shipped defaults: one on, one off, so the test proves
-- the file is read rather than agreeing with the catalogue by accident.
__TEST.files["config/notifications.lua"] = [[
return {
    topics = {
        player_arrived = true,
        farm_toggled   = false,
        rule_message   = true,
        device_found   = false,
    },
}
]]

__TEST.files["config/rules.lua"] = [[
return { enabled = true, interval = 1, rules = {} }
]]

local function service() return BASEOS.loaded["services.notifications"] end
local function registry() return BASEOS.loaded["modules.registry"] end

--- Every line the Chat Box was asked to send.
local function chat() return __TEST.chatLog() end

local function chatHas(text)
    for _, line in ipairs(chat()) do
        if tostring(line.message or line):find(text, 1, true) then return true end
    end
    return false
end

local function topicOf(id)
    for _, topic in ipairs(service().list()) do
        if topic.id == id then return topic end
    end
    return nil
end

------------------------------------------------------------ what config says
__TEST.injectAt(12, function()
    check(#service().list() >= 10,
        "the catalogue loaded (" .. #service().list() .. " topics)")
    check(topicOf("player_arrived").enabled, "config turned 'player arrives' on")
    check(topicOf("farm_toggled").enabled == false, "and left 'farm starts or stops' off")
    check(service().hasOverride() == false, "nothing has been switched by hand yet")

    -- A topic config says nothing about falls back to the catalogue default.
    check(topicOf("node_offline").enabled == true,
        "a topic config does not mention keeps its shipped default")
    check(topicOf("rule_yielded").enabled == false, "which for most of them is off")
end)

--------------------------------------------------- an event that is turned on
__TEST.injectAt(20, function()
    __TEST.setPlayers({ { name = "lchrios", distance = 3 } })
end)

__TEST.injectAt(30, function()
    check(chatHas("lchrios"), "a player walking in reached chat")
    check(chatHas("Front door"), "saying where (" .. tostring((chat()[#chat()] or {}).message) .. ")")

    local topic = topicOf("player_arrived")
    check(topic.fired >= 1, "and the topic counted it (" .. topic.fired .. ")")
    check(topic.announced >= 1, "as announced, not just fired")
end)

-------------------------------------------------- an event that is turned off
__TEST.injectAt(34, function()
    registry().invoke("demo_farm", "stop")
end)

__TEST.injectAt(40, function()
    check(not chatHas("demo_farm is now stopped"),
        "a farm stopping stayed out of chat, because that topic is off")
    check(topicOf("farm_toggled").fired == 0, "the topic did not even count it")
end)

--------------------------------------------- turning one on from the panel
__TEST.injectAt(44, function() return ui.touch("ALERTS") end)

__TEST.injectAt(48, function()
    check(ui.screenName() == "alerts", "ALERTS opens")
    return ui.touch("NOTIFY")
end)

__TEST.injectAt(52, function()
    check(ui.screenName() == "notifications", "NOTIFY opens the catalogue")

    local screen = ui.screen()
    screen.selected = "farm_toggled"
    screen:requestLayout()
end)

__TEST.injectAt(56, function() return ui.touch("ANNOUNCE") end)

__TEST.injectAt(62, function()
    check(topicOf("farm_toggled").enabled, "the switch turned it on")
    check(service().hasOverride(), "and remembered it")
    check(__TEST.files["data/notifications.dat"] ~= nil, "in data/")
    check(__TEST.files["config/notifications.lua"]:find("farm_toggled   = false", 1, true) ~= nil,
        "config/notifications.lua was left untouched")
end)

__TEST.injectAt(66, function()
    registry().invoke("demo_farm", "start")
end)

__TEST.injectAt(72, function()
    check(chatHas("demo_farm is now running"),
        "and now the same event does reach chat, with no reboot")
end)

------------------------------------------------- muting one from the panel
__TEST.injectAt(76, function()
    local screen = ui.screen()
    screen.selected = "player_arrived"
    screen:requestLayout()
end)

__TEST.injectAt(80, function() return ui.touch("MUTE") end)

__TEST.injectAt(84, function()
    check(topicOf("player_arrived").enabled == false, "MUTE turned it off")
    __TEST.setPlayers({})
end)

__TEST.injectAt(92, function()
    __TEST.setPlayers({ { name = "otro", distance = 2 } })
end)

__TEST.injectAt(102, function()
    check(not chatHas("otro"), "and a player walking in no longer says anything")
end)

------------------------------------------------------------ a rule speaking
__TEST.injectAt(106, function()
    -- `say` had no consumer at all before the catalogue existed.
    BASEOS.loaded["core.event_bus"].emit("rules.say",
        { rule = "test", message = "la granja se paro sola" })
end)

__TEST.injectAt(112, function()
    check(chatHas("la granja se paro sola"),
        "a rule's `say` action reaches chat through the catalogue")
end)

--------------------------------------------------------------------- reset
__TEST.injectAt(116, function() return ui.touch("RESET") end)

__TEST.injectAt(120, function()
    check(ui.screen().modal ~= nil, "RESET asks first")
    return ui.touch("DISCARD")
end)

__TEST.injectAt(126, function()
    check(service().hasOverride() == false, "RESET goes back to the configured set")
    check(topicOf("player_arrived").enabled == true, "so the config value is back")
    check(topicOf("farm_toggled").enabled == false, "for both of them")
end)

---------------------------------------------------------------- run
local source = assert(__TEST.files["startup.lua"], "startup.lua not found")
local chunk = assert(load(source, "@startup.lua", "t", _G))
local ok, runError = pcall(chunk)

local snaps = __TEST.snapshots()
if snaps[#snaps] then print(snaps[#snaps].screen) end
print("chat log:")
for _, line in ipairs(chat()) do print("  " .. tostring(line.message or line)) end
print("run ok: " .. tostring(ok) .. (ok and "" or (" err=" .. tostring(runError))))

local log = __TEST.files["data/baseos.log"]
if log and log:find("%[ERROR%]") then
    print(log)
    error("log contains ERROR entries", 0)
end
if not ok then error("startup crashed: " .. tostring(runError), 0) end
for _, harnessError in ipairs(__TEST.errors()) do check(false, "harness: " .. harnessError) end

if #failures > 0 then error(#failures .. " assertion(s) failed", 0) end
print("notification catalogue validated")

-- Proximity triggers and alert announcements.
--
-- Both modules sit on Advanced Peripherals, whose method names are unconfirmed,
-- so what is proven here is the logic on top: radius filtering, the hold timer,
-- manual overrides, severity filtering and rate limiting. Whether the real AP
-- answers to these names is what `probe` is for.

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
__TEST.addAdvancedPeripheral("chat_box")
__TEST.addSpeaker()

__TEST.files["config/modules.lua"] = [[
return {
    enabled = { "system", "presence", "notifier", "demo_farm" },
    instances = {},
    settings = {
        presence = {
            zones = {
                { id = "door", name = "Front door", radius = 5,
                  output = { kind = "redstone", side = "left" }, holdFor = 2 },
                { id = "vault", name = "Vault", radius = 3,
                  players = { "lchrios" },
                  output = { kind = "redstone", side = "right" }, holdFor = 1 },
            },
        },
        notifier = {
            minSeverity = "warning",
            cooldown = 30,
            maxPerMinute = 3,
        },
    },
}
]]

local function presence()
    local record = BASEOS.loaded["modules.registry"].get("presence")
    return record and record.def or nil
end

local function notifier()
    local record = BASEOS.loaded["modules.registry"].get("notifier")
    return record and record.def or nil
end

local function alerts() return BASEOS.loaded["services.alerts"] end

------------------------------------------------------- nobody around
__TEST.injectAt(14, function()
    check(presence() ~= nil, "the presence module loaded")
    check(__TEST.redstone("left") == false, "with nobody around the door output is off")
end)

------------------------------------------------------- someone arrives
__TEST.injectAt(18, function()
    __TEST.setPlayers({ { name = "visitante", distance = 3 } })
end)

__TEST.injectAt(24, function()
    check(__TEST.redstone("left") == true, "a player in range opens the door")
    check(presence().states.door.detected == true, "the zone knows it is occupied")
    -- The vault only cares about a named player.
    check(__TEST.redstone("right") == false, "a zone with a player filter ignores strangers")
end)

------------------------------------------------------- radius matters
__TEST.injectAt(28, function()
    __TEST.setPlayers({ { name = "visitante", distance = 40 } })
end)

__TEST.injectAt(34, function()
    check(presence().states.door.detected == false, "stepping out of range is noticed")
    -- holdFor keeps it powered briefly rather than shutting in your face.
    check(__TEST.redstone("left") == true, "the output holds on just after they leave")
end)

__TEST.injectAt(52, function()
    check(__TEST.redstone("left") == false, "and drops once the hold expires")
end)

------------------------------------------------------- the named player
__TEST.injectAt(56, function()
    __TEST.setPlayers({ { name = "lchrios", distance = 2 } })
end)

__TEST.injectAt(62, function()
    check(__TEST.redstone("right") == true, "the vault opens for the player it names")
end)

------------------------------------------------------- manual override
__TEST.injectAt(66, function()
    __TEST.setPlayers({})
    presence():cycleOverride("door")   -- auto -> on
end)

__TEST.injectAt(72, function()
    check(presence().states.door.override == "on", "the override cycles to ON")
    check(__TEST.redstone("left") == true, "forcing ON powers it with nobody there")

    presence():cycleOverride("door")   -- on -> off
end)

__TEST.injectAt(78, function()
    check(presence().states.door.override == "off", "and then to OFF")
    presence():cycleOverride("door")   -- off -> auto
    check(presence().states.door.override == "auto", "and back to AUTO")
end)

------------------------------------------------------- announcements
__TEST.injectAt(84, function()
    __TEST.clearChatLog()
    check(notifier() ~= nil, "the notifier module loaded")
    check(#notifier().sinks.chat == 1, "it found the chat box")
    check(#notifier().sinks.speaker == 1, "and the speaker")

    -- Below the configured minimum: must stay off chat.
    alerts().raise({ id = "t.info", source = "test", severity = "info", message = "just info" })
end)

__TEST.injectAt(88, function()
    check(#__TEST.chatLog() == 0, "an info alert is not announced")

    alerts().raise({ id = "t.warn", source = "test", severity = "warning", message = "buffer full" })
end)

__TEST.injectAt(92, function()
    local chat = __TEST.chatLog()
    check(#chat == 1, "a warning is announced (" .. #chat .. " message(s))")
    check(chat[1] and chat[1].message:find("buffer full", 1, true) ~= nil,
        "carrying the alert text")
    check(#__TEST.soundLog() == 0, "but no sound: the speaker is set to critical only")

    alerts().raise({ id = "t.crit", source = "test", severity = "critical", message = "reactor hot" })
end)

__TEST.injectAt(96, function()
    check(#__TEST.soundLog() > 0, "a critical alert also makes a noise")
end)

------------------------------------------------------- rate limiting
__TEST.injectAt(100, function()
    __TEST.clearChatLog()
    -- The same alert again, well inside its cooldown.
    alerts().clear("t.warn")
    alerts().raise({ id = "t.warn", source = "test", severity = "warning", message = "buffer full" })
end)

__TEST.injectAt(104, function()
    -- "resolved: buffer full" is the clear notice and is expected; what must
    -- not appear is a second "[WARNING] buffer full".
    local raises, clears = 0, 0
    for _, entry in ipairs(__TEST.chatLog()) do
        if entry.message:find("%[WARNING%]") then raises = raises + 1 end
        if entry.message:find("resolved:", 1, true) then clears = clears + 1 end
    end
    check(clears == 1, "clearing an alert is announced once")
    check(raises == 0, "but re-raising inside its cooldown stays quiet")
    check((notifier().suppressed or 0) > 0, "and it is counted as suppressed")
end)

__TEST.injectAt(108, function()
    __TEST.clearChatLog()
    -- Start the ceiling test from a clean minute, otherwise the earlier alerts
    -- have already spent the budget and the cap proves nothing.
    local instance = notifier()
    for index = #instance.recent, 1, -1 do instance.recent[index] = nil end
    for index = 1, 8 do
        alerts().raise({ id = "flood." .. index, source = "test",
            severity = "warning", message = "flood " .. index })
    end
end)

__TEST.injectAt(112, function()
    local count = #__TEST.chatLog()
    check(count == 3, "a storm is capped at exactly maxPerMinute (" .. count .. " sent)")
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
print("presence and notifier validated")

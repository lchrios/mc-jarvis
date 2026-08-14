-- The four fixes from the static review, pinned so they cannot come back.
--
--   2  writes are atomic, and a torn one does not cost a computer its role
--   3  accented text is folded, one glyph per character
--   4  node names that would break the state tree are refused
--   6  a module snapshot is built once and reused until something changes

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

__TEST.setMaxEvents(80)
__TEST.resizeMonitor(82, 25)

__TEST.files["config/modules.lua"] = [[
return { enabled = { "system", "demo_farm" }, instances = {}, settings = {} }
]]

-- A rule name written the way a Spanish speaker would write it.
__TEST.files["config/rules.lua"] = [[
return { enabled = true, interval = 1, rules = { {
    id = "acentos",
    name = "Energ\195\173a cr\195\173tica de la B\195\179veda",
    enabled = false,
    when = { metric = "demo_farm.buffer", op = ">", value = 9 },
    do_ = "demo_farm.stop",
} } }
]]

local function util() return BASEOS.loaded["core.util"] end
local function identity() return BASEOS.loaded["core.identity"] end
local function persistence() return BASEOS.loaded["services.persistence"] end
local function registry() return BASEOS.loaded["modules.registry"] end

------------------------------------------------------------------ 3. accents
__TEST.injectAt(10, function()
    check(util().ascii("Energ\195\173a") == "Energia", "an accent folds to its plain letter")
    check(util().ascii("Ma\195\177ana") == "Manana", "and so does the enye")
    check(util().ascii("plain text") == "plain text", "ASCII is left alone")

    -- The bug this fixes: padding counted bytes, so an accent ate a column.
    check(#util().padRight("cr\195\173tica", 12) == 12,
        "padRight pads to real glyphs, not bytes")
    check(#util().truncate("Energ\195\173a cr\195\173tica", 10) == 10,
        "and truncate cuts to real glyphs")

    return ui.touch("RULES")
end)

------------------------------------------------------- 2. atomic persistence
__TEST.injectAt(16, function()
    check(ui.screenName() == "rules", "the rules list opened")

    persistence().save("probe", { value = "first" })
    check(__TEST.files["data/probe.dat"] ~= nil, "a save lands in data/")
    check(__TEST.files["data/probe.dat.tmp"] == nil, "and leaves no temporary behind")

    persistence().save("probe", { value = "second" })
    check(__TEST.files["data/probe.dat.bak"] ~= nil, "the second save keeps the first as .bak")

    -- Exactly what an unloaded chunk leaves behind: half a serialised table.
    __TEST.files["data/probe.dat"] = "{ value = \"seco"
    local recovered = persistence().load("probe", { value = "default" })
    check(recovered.value == "first",
        "a torn file falls back to the backup, not to the default ("
            .. tostring(recovered.value) .. ")")

    persistence().delete("probe")
    check(__TEST.files["data/probe.dat.bak"] == nil,
        "deleting takes the backup too, so the old value cannot come back")
end)

--------------------------------------------------- 2b. a role is not lost
__TEST.injectAt(20, function()
    local ok = identity().save({ role = "node", profile = "power", name = "power_node" })
    check(ok, "an identity saves")

    identity().save({ role = "node", profile = "power", name = "power_node_2" })
    check(__TEST.files["data/node.dat.bak"] ~= nil, "and keeps the previous one")

    __TEST.files["data/node.dat"] = "{ role = \"no"
    local record, reason = identity().load()
    check(record ~= nil and record.role == "node",
        "a torn node.dat recovers the role instead of returning nothing")
    check(record and record.name == "power_node",
        "with the name it had (" .. tostring(record and record.name) .. ")")
    check(reason == "recovered", "and says where it came from")

    -- With no backup either, the caller has to be able to tell this apart from
    -- a computer that was simply never set up - assuming master would put a
    -- second master on the network.
    __TEST.files["data/node.dat.bak"] = nil
    local none, why = identity().load()
    check(none == nil and why == "corrupt",
        "an unreadable identity with no backup reports 'corrupt', not 'missing'")

    __TEST.files["data/node.dat"] = nil
    local fresh, freshWhy = identity().load()
    check(fresh == nil and freshWhy == "missing",
        "and a computer that never had one reports 'missing'")
end)

--------------------------------------------------------- 4. node names
__TEST.injectAt(24, function()
    local cases = {
        { "power_node", true,  "a plain name" },
        { "power-node", true,  "a dash" },
        { "power.node", false, "a dot, which would split the state tree" },
        { "",           false, "an empty name" },
        { "   ",        false, "only spaces" },
        { "power node", false, "a space" },
        { "Boveda\195\177", false, "a non-ASCII character" },
        { string.rep("x", 40), false, "something absurdly long" },
    }
    for _, case in ipairs(cases) do
        local ok = identity().validateName(case[1])
        check(ok == case[2], case[3] .. " is " .. (case[2] and "accepted" or "refused"))
    end

    local suggestion = identity().cleanName("power node.1")
    check(suggestion == "power_node1",
        "cleanName suggests something usable (" .. suggestion .. ")")
    check(identity().validateName(suggestion), "and the suggestion itself is valid")

    local saved = identity().save({ role = "node", name = "power.node" })
    check(saved == false, "and a bad name cannot be saved at all")
end)

---------------------------------------------------------- 6. snapshot cache
__TEST.injectAt(30, function()
    local record = registry().get("demo_farm")
    local calls = 0
    local original = record.def.metrics
    record.def.metrics = function(...) calls = calls + 1 return original(...) end

    for _ = 1, 5 do registry().snapshot("demo_farm") end
    check(calls == 1, "five snapshots build the module's metrics once (" .. calls .. ")")

    -- A poll is new data, so the next reader must see it.
    registry().poll("demo_farm")
    registry().snapshot("demo_farm")
    check(calls == 2, "a poll drops the cache (" .. calls .. ")")

    -- So is somebody pressing a button.
    calls = 0
    registry().snapshot("demo_farm")
    registry().snapshot("demo_farm")
    check(calls == 0, "with nothing happening, more reads are free (" .. calls .. ")")

    registry().invoke("demo_farm", "stop")
    registry().snapshot("demo_farm")
    check(calls == 1, "and an action drops the cache exactly once (" .. calls .. ")")

    record.def.metrics = original
end)

------------------------------------------------------------ what got drawn
__TEST.injectAt(40, function() return nil end)

---------------------------------------------------------------- run
local source = assert(__TEST.files["startup.lua"], "startup.lua not found")
local chunk = assert(load(source, "@startup.lua", "t", _G))
local ok, runError = pcall(chunk)

local snaps = __TEST.snapshots()
local frame = (snaps[#snaps] and snaps[#snaps].screen) or ""
print(frame)

check(frame:find("Energia critica de la Boveda", 1, true) ~= nil,
    "the accented rule name is drawn folded")
check(frame:find("\195", 1, true) == nil, "and no raw UTF-8 byte reached the screen")

print("run ok: " .. tostring(ok) .. (ok and "" or (" err=" .. tostring(runError))))

local log = __TEST.files["data/baseos.log"]
if log and log:find("%[ERROR%]") then
    print(log)
    error("log contains ERROR entries", 0)
end
if not ok then error("startup crashed: " .. tostring(runError), 0) end
for _, harnessError in ipairs(__TEST.errors()) do check(false, "harness: " .. harnessError) end

if #failures > 0 then error(#failures .. " assertion(s) failed", 0) end
print("hardening validated")

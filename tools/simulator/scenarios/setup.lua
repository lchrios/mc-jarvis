-- The setup wizard and the factory reset.
--
-- Both are destructive and both are what the user reaches for when a computer
-- is already misbehaving, so their prompts are driven here for real.

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

local remote = __TEST.remote()

local function run(program, ...)
    local chunk = assert(load(assert(remote[program]), "@" .. program, "t", _G))
    local ok, err = pcall(chunk, ...)
    if not ok then error(program .. " failed: " .. tostring(err), 0) end
end

local function identity()
    local raw = __TEST.files["data/node.dat"]
    return raw and textutils.unserialise(raw) or nil
end

---------------------------------------------------------------- first run
print("[1] a computer that was never set up")
__TEST.files["data/node.dat"] = nil

check(identity() == nil, "no identity to begin with")

-- profile from the argument, then: name, reboot?
__TEST.queueInput("power_node", "n")
run("setup.lua", "power")

local me = identity()
check(me ~= nil, "setup wrote an identity")
check(me and me.role == "node", "the power profile is a node")
check(me and me.profile == "power", "the profile is recorded")
check(me and me.name == "power_node", "the name was taken from the prompt")
check(me and me.modules ~= nil and #me.modules == 2, "the profile's modules were copied in")

---------------------------------------------------------------- changing role
print("[2] changing the role keeps or drops the old config")
__TEST.files["config/system.lua"] = "return { name = \"MI BASE\" }\n"

-- change it? -> y, name, delete config? -> n, reboot? -> n
__TEST.queueInput("y", "mainframe", "n", "n")
run("setup.lua", "master")

me = identity()
check(me and me.role == "master", "the role changed to master")
check(me and me.name == "mainframe", "the name changed")
check(__TEST.files["config/system.lua"] ~= nil, "answering 'n' kept the old config")

-- change it? -> y, name, delete config? -> y, reboot? -> n
__TEST.queueInput("y", "power_node", "y", "n")
run("setup.lua", "power")

check(__TEST.files["config/system.lua"] == nil, "answering 'y' cleared the old config")
check(identity().role == "node", "the role changed back")

---------------------------------------------------------------- declining
print("[3] declining leaves everything alone")
__TEST.queueInput("n")
run("setup.lua")
check(identity().name == "power_node", "answering 'n' at 'change it?' changes nothing")

---------------------------------------------------------------- reset
print("[4] reset --keep-setup")
__TEST.files["data/baseos.log"] = "old log\n"
__TEST.files["data/snapshot.dat"] = "{}"

__TEST.queueInput("RESET", "n")
run("reset.lua", "--keep-setup")

check(identity() ~= nil, "--keep-setup keeps the identity")
check(__TEST.files["data/snapshot.dat"] == nil, "cached data is wiped")

print("[5] a wrong confirmation cancels")
__TEST.files["data/snapshot.dat"] = "{}"
__TEST.queueInput("yes")
run("reset.lua")
check(identity() ~= nil, "typing anything but RESET changes nothing")
check(__TEST.files["data/snapshot.dat"] ~= nil, "and leaves the data alone")

print("[6] a full reset")
__TEST.files["config/system.lua"] = "return {}\n"
__TEST.queueInput("RESET", "n")
run("reset.lua")

check(identity() == nil, "a full reset clears the identity")
check(__TEST.files["config/system.lua"] == nil, "and the config")
check(__TEST.files["startup.lua"] ~= nil, "program files are never touched")
check(__TEST.files["src/core/app.lua"] ~= nil, "src/ is never touched")

if #failures > 0 then error(#failures .. " assertion(s) failed", 0) end
print("setup and reset validated")

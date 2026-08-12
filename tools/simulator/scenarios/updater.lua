-- The update cycle, against a fake GitHub whose content can change mid-run.
--
--   1. bare computer -> installer bootstraps the updater and installs
--   2. nothing changed upstream -> no downloads at all
--   3. a file changes upstream -> only that file is fetched
--   4. answering "n" at the prompt changes nothing
--   5. answering "y" applies the update
--   6. local config edits survive every one of those

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
    local source = assert(remote[program], program .. " missing from the repo")
    local chunk = assert(load(source, "@" .. program, "t", _G))
    local ok, err = pcall(chunk, ...)
    if not ok then error(program .. " failed: " .. tostring(err), 0) end
end

local function state()
    local handle = __TEST.files["data/install.dat"]
    return handle and textutils.unserialise(handle) or nil
end

local TARGET = "src/modules/system.lua"

---------------------------------------------------------------- 1. install
print("[1] fresh install")
__TEST.wipeDisk({})
run("installer.lua")

check(__TEST.files["startup.lua"] ~= nil, "startup.lua installed")
check(__TEST.files["updater.lua"] ~= nil, "updater.lua left on the computer")
check(__TEST.files["VERSION"] ~= nil, "VERSION installed")
local installed = state()
check(installed ~= nil, "an install record was written")
check(installed and installed.sha ~= nil, "the record stores the remote tree sha")
check(installed and installed.files ~= nil and installed.files[TARGET] ~= nil,
    "the record stores a sha per file")

---------------------------------------------------------------- 2. no changes
print("[2] nothing changed upstream")
local localEdit = "-- edited by hand\n" .. remote[TARGET]
__TEST.files[TARGET] = localEdit
__TEST.files["config/system.lua"] = "return { name = \"MI BASE\" }\n"

__TEST.resetHttpCalls()
run("updater.lua", "-y")

local calls = __TEST.httpCalls()
check(calls.raw <= 1, "no files downloaded when the tree sha matches (raw=" .. calls.raw .. ")")
check(__TEST.files[TARGET] == localEdit, "an unchanged file is left alone")

---------------------------------------------------------------- 3. check only
print("[3] a file changes upstream")
remote[TARGET] = "-- upstream change\n" .. remote[TARGET]

__TEST.resetHttpCalls()
run("updater.lua", "check")
check(__TEST.files[TARGET] == localEdit, "'check' reports without changing anything")

---------------------------------------------------------------- 4. declined
print("[4] the user declines")
__TEST.queueInput("n")
run("updater.lua")
check(__TEST.files[TARGET] == localEdit, "answering 'n' leaves the file untouched")
check(state().sha == installed.sha, "a declined update does not move the install record")

---------------------------------------------------------------- 5. accepted
print("[5] the user accepts")
__TEST.resetHttpCalls()
__TEST.queueInput("y")
run("updater.lua")

check(__TEST.files[TARGET] == remote[TARGET], "the changed file was updated")
check(__TEST.httpCalls().raw <= 2,
    "only the changed file was downloaded (raw=" .. __TEST.httpCalls().raw .. ")")
check(state().sha ~= installed.sha, "the install record advanced")
check(__TEST.files["config/system.lua"] == "return { name = \"MI BASE\" }\n",
    "the local config edit survived the update")

---------------------------------------------------------------- 6. still boots
print("[6] the updated tree boots")
__TEST.files["config/system.lua"] = remote["config/system.lua"]
local chunk = assert(load(__TEST.files["startup.lua"], "@startup.lua", "t", _G))
local booted = pcall(chunk)
check(booted, "startup.lua runs after the update")
check(not __TEST.crashed(), "no crash banner")

local log = __TEST.files["data/baseos.log"]
if log and log:find("%[ERROR%]") then
    print(log)
    error("log contains ERROR entries", 0)
end
if #failures > 0 then error(#failures .. " assertion(s) failed", 0) end
print("update cycle validated")

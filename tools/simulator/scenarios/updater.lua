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
check(__TEST.files["baseos.version"] ~= nil, "the version file installed")
check(__TEST.files["VERSION"] == nil, "the obsolete VERSION file is not installed")
local installed = state()
check(installed ~= nil, "an install record was written")
check(installed and installed.sha ~= nil, "the record stores the remote tree sha")
check(installed and installed.files ~= nil and installed.files[TARGET] ~= nil,
    "the record stores a sha per file")

---------------------------------------------------------------- 1.b version
print("[1b] the version command")
check(__TEST.files["version.lua"] ~= nil, "version.lua installed")

-- Capture what the program prints so the output is actually asserted.
local captured = {}
local realPrint = print
print = function(...)
    local parts = {}
    for index = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(index, ...)))
    end
    captured[#captured + 1] = table.concat(parts, " ")
end
run("version.lua")
print = realPrint

local printed = table.concat(captured, "\n")
local expected = (remote["baseos.version"]:gsub("%s+", ""))
check(printed:find(expected, 1, true) ~= nil, "it prints the installed version (" .. expected .. ")")
check(printed:find("main", 1, true) ~= nil, "it prints the branch")
check(printed:find("no install record", 1, true) == nil, "it found the install record")

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

---------------------------------------------------------- 2.b obsolete files
-- A file that used to ship (VERSION) shadowed the `version` command on a
-- case-insensitive filesystem, so the updater has to remove it even when
-- everything else is already up to date.
print("[2b] leftovers from an older layout")
__TEST.files["VERSION"] = "0.1.0\n"
run("updater.lua", "-y")
check(__TEST.files["VERSION"] == nil, "an obsolete file is deleted")
check(__TEST.files["baseos.version"] ~= nil, "the current version file stays")

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

------------------------------------------------- 4.b the connection drops
-- The case the staging directory exists for: the updater rewrites startup.lua
-- and itself, so a download that dies halfway used to leave a computer running
-- half of one version and half of another - the one state from which you
-- cannot run the updater again to fix it.
print("[4b] the connection drops mid-update")

-- Two files have to change, or there is no "halfway" to be interrupted at.
local SECOND = "src/modules/power.lua"
remote[SECOND] = "-- upstream change\n" .. remote[SECOND]

local before = {}
for path, contents in pairs(__TEST.files) do before[path] = contents end

__TEST.resetHttpCalls()
-- One raw request is the version check, the next is the first file: so the
-- second file is the one that dies, with a file already downloaded.
__TEST.failDownloadsAfter(2)
__TEST.queueInput("y")
local survived = pcall(function() run("updater.lua") end)
__TEST.failDownloadsAfter(nil)

check(not survived, "the updater stops instead of carrying on")
check(__TEST.httpCalls().raw >= 2,
    "it had already downloaded a file when the connection died (raw="
        .. __TEST.httpCalls().raw .. ")")
-- Which of the two got through first is up to the sort order; neither may be
-- on disk, because a half-applied update is the state with no way out.
check(__TEST.files[TARGET] == before[TARGET], "neither file was installed")
check(__TEST.files[SECOND] == before[SECOND], "not even the one that downloaded")
check(__TEST.files["startup.lua"] == before["startup.lua"],
    "and startup.lua, which it rewrites late in the run, is untouched")
check(state().sha == installed.sha, "the install record did not move")

local leftovers = 0
for path in pairs(__TEST.files) do
    if path:sub(1, 8) == ".update/" then leftovers = leftovers + 1 end
end
check(leftovers == 0, "no staged files were left behind (" .. leftovers .. ")")

---------------------------------------------------------------- 5. accepted
print("[5] the user accepts")
__TEST.resetHttpCalls()
__TEST.queueInput("y")
run("updater.lua")

check(__TEST.files[TARGET] == remote[TARGET], "the changed file was updated")
check(__TEST.files[SECOND] == remote[SECOND], "and so was the second one")
-- Two changed files plus the version check: nothing unchanged was fetched.
check(__TEST.httpCalls().raw <= 3,
    "only the changed files were downloaded (raw=" .. __TEST.httpCalls().raw .. ")")
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

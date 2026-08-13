-- Installs BaseOS onto a wiped computer from a fake GitHub, then boots it.
--
-- Covers the path a real install takes:
--   1. a bare computer with only `installer` on it
--   2. installer pulls the tree and writes every file
--   3. a second run keeps local config edits
--   4. the installed tree actually boots

local LOCAL_EDIT = "-- local edit that must survive an update\nreturn { name = \"MI BASE\" }\n"

local function count(prefix)
    local total = 0
    for path in pairs(__TEST.files) do
        if path:sub(1, #prefix) == prefix then total = total + 1 end
    end
    return total
end

local function runInstaller(...)
    local source = assert(__TEST.remote()["installer.lua"], "installer.lua missing from the repo")
    local chunk = assert(load(source, "@installer.lua", "t", _G))
    return pcall(chunk, ...)
end

---------------------------------------------------------------- fresh install
__TEST.wipeDisk({})
print("[1] bare computer: " .. count("") .. " file(s)")

local ok, err = runInstaller()
if not ok then error("installer failed: " .. tostring(err), 0) end

print("[2] after install: " .. count("") .. " file(s), src/=" .. count("src/")
    .. " config/=" .. count("config/"))
assert(__TEST.files["startup.lua"], "startup.lua was not installed")
assert(count("src/") > 40, "src/ looks incomplete")
-- Counted from the repo rather than hardcoded, so adding a config file does
-- not break this test.
local expectedConfigs = 0
for path in pairs(__TEST.remote()) do
    if path:sub(1, 7) == "config/" then expectedConfigs = expectedConfigs + 1 end
end
assert(count("config/") == expectedConfigs,
    ("config/ looks incomplete: %d of %d"):format(count("config/"), expectedConfigs))
assert(__TEST.files["docs/ARCHITECTURE.md"] == nil, "docs should not be installed")
assert(__TEST.files["tools/simulator/run.js"] == nil, "tools should not be installed")

---------------------------------------------------------- config is preserved
__TEST.files["config/system.lua"] = LOCAL_EDIT
local okUpdate, updateErr = runInstaller()
if not okUpdate then error("update failed: " .. tostring(updateErr), 0) end

if __TEST.files["config/system.lua"] ~= LOCAL_EDIT then
    error("the update overwrote a local config file", 0)
end
print("[3] local config edit survived the update")

-------------------------------------------------------------- the result boots
__TEST.files["config/system.lua"] = __TEST.remote()["config/system.lua"]

local startup = assert(__TEST.files["startup.lua"], "startup.lua missing after install")
local chunk = assert(load(startup, "@startup.lua", "t", _G))
local okBoot, bootErr = pcall(chunk)

local snaps = __TEST.snapshots()
print("[4] booted the installed tree: " .. tostring(okBoot)
    .. (okBoot and "" or (" err=" .. tostring(bootErr))))
print(snaps[#snaps] and snaps[#snaps].screen or "(nothing drawn)")

local log = __TEST.files["data/baseos.log"]
if log and log:find("%[ERROR%]") then
    print(log)
    error("log contains ERROR entries", 0)
end

-- Config backup and restore.
--
-- The disaster this covers: a computer is destroyed. `updater` brings the
-- programs back; this has to bring back everything that made it *that*
-- computer. So the test destroys one and rebuilds it.

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

--- Run a program with its prompts answered and output captured.
local function runQuiet(program, answers, ...)
    __TEST.queueInput(table.unpack(answers or {}))
    local realPrint, realPrintError = print, printError
    local lines = {}
    print = function(...)
        local parts = {}
        for index = 1, select("#", ...) do
            parts[#parts + 1] = tostring((select(index, ...)))
        end
        lines[#lines + 1] = table.concat(parts, " ")
    end
    printError = print
    local arguments = table.pack(...)
    local ok, err = pcall(function()
        run(program, table.unpack(arguments, 1, arguments.n))
    end)
    print, printError = realPrint, realPrintError
    if not ok then error(tostring(err), 0) end
    return table.concat(lines, "\n")
end

__TEST.addAdvancedPeripheral("player_detector")

-- A computer with a personality worth losing.
__TEST.files["data/node.dat"] = textutils.serialise({
    role = "master", profile = "master", name = "mainframe",
})
__TEST.files["config/system.lua"] = 'return { name = "MI BASE" }\n'
__TEST.files["data/layout.dat"] = textutils.serialise({
    zones = { { id = "reactor", label = "REACTOR", col = 1, row = 1 } },
})
__TEST.files["data/security.dat"] = textutils.serialise({
    users = { { player = "lchrios", role = "admin" } },
})

---------------------------------------------------------------- save
print("[1] taking a backup")
local output = runQuiet("backup.lua", {}, "local")
check(output:find("Saved a copy", 1, true) ~= nil, "a local backup is written")
check(__TEST.files["data/backup.dat"] ~= nil, "the archive is on disk")

local archive = textutils.unserialise(__TEST.files["data/backup.dat"])
check(archive.node == "mainframe", "it knows which computer it came from")
check(archive.files["config/system.lua"] ~= nil, "config is included")
check(archive.files["data/node.dat"] ~= nil, "the identity is included")
check(archive.files["data/layout.dat"] ~= nil, "the base plan is included")
check(archive.files["data/security.dat"] ~= nil, "registered users are included")
check(archive.files["data/baseos.log"] == nil, "logs are not: they regenerate")
check(archive.files["data/install.dat"] == nil, "nor the install record")

---------------------------------------------------------------- disaster
print("[2] the computer is destroyed and rebuilt")
local keep = __TEST.files["data/backup.dat"]
__TEST.wipeDisk({})
for path, contents in pairs(remote) do __TEST.files[path] = contents end  -- updater
__TEST.files["data/backup.dat"] = keep                                    -- the floppy

check(__TEST.files["data/node.dat"] == nil, "the rebuilt computer has no identity")
check(__TEST.files["config/system.lua"]:find("MI BASE", 1, true) == nil,
    "and stock config")

---------------------------------------------------------------- restore
print("[3] restoring it")
local restored = runQuiet("backup.lua", { "y", "n" }, "restore", "local")
check(restored:find("Restored", 1, true) ~= nil, "the restore reports success")

check(__TEST.files["config/system.lua"]:find("MI BASE", 1, true) ~= nil,
    "the tuned config is back")
check(__TEST.files["data/node.dat"] ~= nil, "the identity is back")
check(textutils.unserialise(__TEST.files["data/node.dat"]).name == "mainframe",
    "with the same name")
check(textutils.unserialise(__TEST.files["data/layout.dat"]).zones[1].id == "reactor",
    "and the base plan")

---------------------------------------------------------------- cancelling
print("[4] declining changes nothing")
__TEST.files["config/system.lua"] = 'return { name = "OTRO" }\n'
runQuiet("backup.lua", { "n" }, "restore", "local")
check(__TEST.files["config/system.lua"]:find("OTRO", 1, true) ~= nil,
    "answering 'n' leaves the computer alone")

---------------------------------------------------------------- master side
print("[5] a master holding backups for its nodes")
local backupService = BASEOS and BASEOS.loaded["services.backup"]
if not backupService then
    -- Load it directly: BaseOS itself is not running in this scenario.
    local chunk = assert(load(assert(remote["boot.lua"]), "@boot.lua", "t", _G))
    backupService = chunk().require("services.backup")
end

backupService.storeRemote("power_node", {
    version = 1, node = "power_node", role = "node", createdAt = 1, fileCount = 2,
    files = { ["config/system.lua"] = "return {}\n", ["data/node.dat"] = "{}" },
})

local held = backupService.remoteNodes()
check(#held == 1 and held[1].node == "power_node", "the master lists what it holds")

local fetched = backupService.loadRemote("power_node")
check(fetched ~= nil and fetched.node == "power_node", "and can hand it back")

local missing, err = backupService.loadRemote("nunca_existio")
check(missing == nil and tostring(err):find("no backup", 1, true) ~= nil,
    "asking for an unknown node says so")

---------------------------------------------------------------- identity
print("[6] a replacement keeps the name setup gave it")
local written = backupService.apply({
    version = 1, node = "power_node", createdAt = 1,
    files = {
        ["config/system.lua"] = 'return { name = "DESDE EL MASTER" }\n',
        ["data/node.dat"] = textutils.serialise({ role = "node", name = "el_viejo" }),
    },
}, { identity = false })

check(written == 1, "only the config was written")
check(__TEST.files["config/system.lua"]:find("DESDE EL MASTER", 1, true) ~= nil,
    "the config arrived")
check(textutils.unserialise(__TEST.files["data/node.dat"]).name == "mainframe",
    "and the identity was not overwritten")

if #failures > 0 then error(#failures .. " assertion(s) failed", 0) end
print("backup and restore validated")

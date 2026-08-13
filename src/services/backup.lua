--- Config backups: what it takes to rebuild a computer that was destroyed.
--
-- Program files come back with `updater`; what cannot be re-downloaded is what
-- makes a computer *this* computer:
--
--   config/*.lua       how you tuned it
--   data/node.dat      its role and name
--   data/layout.dat    the plan drawn in the editor
--   data/security.dat  who is registered
--
-- Logs, snapshots and the install record are deliberately left out: they
-- regenerate on their own and would only make the archive bigger.
--
-- Two destinations, and they cover different disasters:
--
--   disk     a floppy in a disk drive. Survives anything, including the
--            master burning down. Needs a drive and a floppy.
--   remote   nodes push their archive to the master, which keeps one per
--            node. No extra hardware, and a replacement node can pull its
--            own config back the moment it knows its name.

local util = require("core.util")
local logger = require("core.logger")
local persistence = require("services.persistence")

local log = logger.scoped("backup")

local backup = {}

backup.VERSION = 1

--- Everything worth keeping, in the order it should be restored.
local INCLUDE = {
    { path = "config", directory = true },
    { path = "data/node.dat", identity = true },
    { path = "data/layout.dat" },
    { path = "data/security.dat" },
}

---------------------------------------------------------------------------
-- Files
---------------------------------------------------------------------------

local function readFile(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local contents = handle.readAll()
    handle.close()
    return contents
end

local function writeFile(path, contents)
    local dir = fs.getDir(path)
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local handle = fs.open(path, "w")
    if not handle then return false end
    handle.write(contents)
    handle.close()
    return true
end

local function collectDirectory(path, into)
    if not fs.exists(path) then return into end
    for _, name in ipairs(fs.list(path)) do
        local child = fs.combine(path, name)
        if fs.isDir(child) then
            collectDirectory(child, into)
        else
            into[child] = readFile(child)
        end
    end
    return into
end

---------------------------------------------------------------------------
-- Archives
---------------------------------------------------------------------------

--- Build an archive of this computer's configuration.
-- @param options table { identity = bool } - identity defaults to true
function backup.create(ctx, options)
    options = options or {}
    local includeIdentity = options.identity ~= false

    local files = {}
    for _, entry in ipairs(INCLUDE) do
        if entry.identity and not includeIdentity then
            -- skipped on purpose
        elseif entry.directory then
            collectDirectory(entry.path, files)
        else
            local contents = readFile(entry.path)
            if contents then files[entry.path] = contents end
        end
    end

    local count = 0
    for _ in pairs(files) do count = count + 1 end

    return {
        version = backup.VERSION,
        createdAt = util.nowMs(),
        node = ctx and ctx.identity and ctx.identity.name or os.getComputerLabel(),
        role = ctx and ctx.identity and ctx.identity.role or "master",
        computerId = os.getComputerID(),
        baseosVersion = ctx and ctx.version or nil,
        fileCount = count,
        files = files,
    }
end

--- What an archive holds, without restoring anything.
function backup.describe(archive)
    if type(archive) ~= "table" or type(archive.files) ~= "table" then
        return nil, "not a BaseOS archive"
    end
    if archive.version ~= backup.VERSION then
        return nil, "archive version " .. tostring(archive.version) .. " is not supported"
    end

    local paths = {}
    for path in pairs(archive.files) do paths[#paths + 1] = path end
    table.sort(paths)

    return {
        node = archive.node,
        role = archive.role,
        createdAt = archive.createdAt,
        baseosVersion = archive.baseosVersion,
        paths = paths,
    }
end

--- Write an archive back to disk. Returns written, error.
-- @param options table { identity = bool } - identity defaults to true
function backup.apply(archive, options)
    options = options or {}
    local info, err = backup.describe(archive)
    if not info then return 0, err end

    local written = 0
    for _, path in ipairs(info.paths) do
        local skipIdentity = path == "data/node.dat" and options.identity == false
        if not skipIdentity then
            if writeFile(path, archive.files[path]) then written = written + 1 end
        end
    end

    log.info("restored %d file(s) from a backup of '%s'", written, tostring(info.node))
    return written
end

---------------------------------------------------------------------------
-- Disks
---------------------------------------------------------------------------

backup.DISK_FILE = "baseos-backup.dat"

--- Mount path of the first disk drive holding a floppy, or nil.
function backup.diskPath()
    for _, name in ipairs(peripheral.getNames()) do
        local ok, kind = pcall(peripheral.getType, name)
        if ok and kind == "drive" then
            local present = select(1, pcall(peripheral.call, name, "isDiskPresent"))
                and peripheral.call(name, "isDiskPresent")
            if present then
                local mount = peripheral.call(name, "getMountPath")
                if mount then return mount, name end
            end
        end
    end
    return nil
end

function backup.saveToDisk(archive)
    local mount = backup.diskPath()
    if not mount then return false, "no floppy in a disk drive" end

    local path = fs.combine(mount, backup.DISK_FILE)
    if not writeFile(path, textutils.serialise(archive)) then
        return false, "could not write to the disk"
    end
    return true, path
end

function backup.loadFromDisk()
    local mount = backup.diskPath()
    if not mount then return nil, "no floppy in a disk drive" end

    local contents = readFile(fs.combine(mount, backup.DISK_FILE))
    if not contents then return nil, "no BaseOS backup on that floppy" end

    local ok, archive = pcall(textutils.unserialise, contents)
    if not ok or type(archive) ~= "table" then return nil, "the backup on the floppy is corrupt" end
    return archive
end

---------------------------------------------------------------------------
-- Local copy
---------------------------------------------------------------------------

--- A copy kept on this computer. Useless if the computer is destroyed, but it
--- covers the far commoner accident: a bad edit.
function backup.saveLocal(ctx)
    local archive = backup.create(ctx)
    local ok, err = persistence.save("backup", archive)
    return ok, ok and archive or err
end

function backup.loadLocal()
    return persistence.load("backup", nil)
end

---------------------------------------------------------------------------
-- Remote copies held by the master
---------------------------------------------------------------------------

local function remotePath(node)
    return "data/backups/" .. tostring(node):gsub("[^%w_%-]", "_") .. ".dat"
end

--- Master side: keep a node's archive.
function backup.storeRemote(node, archive)
    if not node or type(archive) ~= "table" then return false end
    if not fs.exists("data/backups") then fs.makeDir("data/backups") end

    writeFile(remotePath(node), textutils.serialise(archive))
    log.info("stored a backup for node '%s'", tostring(node))
    return true
end

function backup.loadRemote(node)
    local contents = readFile(remotePath(node))
    if not contents then return nil, "no backup held for '" .. tostring(node) .. "'" end

    local ok, archive = pcall(textutils.unserialise, contents)
    if not ok or type(archive) ~= "table" then return nil, "that backup is corrupt" end
    return archive
end

--- Which nodes the master is holding backups for.
function backup.remoteNodes()
    if not fs.exists("data/backups") then return {} end

    local nodes = {}
    for _, name in ipairs(fs.list("data/backups")) do
        local archive = readFile(fs.combine("data/backups", name))
        local ok, parsed = pcall(textutils.unserialise, archive or "")
        if ok and type(parsed) == "table" then
            nodes[#nodes + 1] = {
                node = parsed.node or name:gsub("%.dat$", ""),
                role = parsed.role,
                createdAt = parsed.createdAt,
                fileCount = parsed.fileCount,
            }
        end
    end
    table.sort(nodes, function(a, b) return tostring(a.node) < tostring(b.node) end)
    return nodes
end

return backup

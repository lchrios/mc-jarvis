--- Save and restore what makes this computer itself.
--
--   backup                 save to a floppy (or here, if no drive)
--   backup local           save a copy on this computer only
--   backup show            what a floppy holds, without restoring it
--   backup restore         restore from a floppy
--   backup restore local   restore the copy held here
--   backup pull            fetch this computer's config from the master
--   backup list            (on a master) which nodes it holds backups for
--
-- `updater` brings the programs back; this brings back the configuration,
-- the role, the base plan and the registered users. Between the two, a
-- destroyed computer is a five-minute job.

local function bootstrap()
    local handle = fs.open("boot.lua", "r")
    if not handle then
        printError("boot.lua is missing. Run 'updater force' to repair the install.")
        error("", 0)
    end
    local source = handle.readAll()
    handle.close()
    return load(source, "@boot.lua", "t", _ENV or _G)()
end

local BASEOS = bootstrap()
local backup = BASEOS.require("services.backup")
local identity = BASEOS.require("core.identity")
local util = BASEOS.require("core.util")

---------------------------------------------------------------------------

local function confirm(question)
    write(question .. " [y/N] ")
    return tostring(read() or ""):lower():sub(1, 1) == "y"
end

--- Enough context for the archive to name itself.
local function context()
    return {
        identity = identity.load() or identity.default(),
        version = BASEOS.version,
    }
end

local function describe(archive, label)
    local info, err = backup.describe(archive)
    if not info then
        printError(label .. ": " .. tostring(err))
        return nil
    end

    local age = info.createdAt and util.formatDuration((util.nowMs() - info.createdAt) / 1000)
    print(label)
    print("  computer: " .. tostring(info.node) .. "  (" .. tostring(info.role) .. ")")
    print("  taken:    " .. (age and (age .. " ago") or "unknown"))
    print("  BaseOS:   " .. tostring(info.baseosVersion or "?"))
    print("  files:    " .. #info.paths)
    for index = 1, math.min(#info.paths, 8) do
        print("    " .. info.paths[index])
    end
    if #info.paths > 8 then print("    ... and " .. (#info.paths - 8) .. " more") end
    return info
end

---------------------------------------------------------------------------

local function doSave(target)
    local archive = backup.create(context())

    if target == "local" then
        local ok = backup.saveLocal(context())
        if not ok then printError("Could not save.") return end
        print("Saved a copy on this computer (data/backup.dat).")
        print("Note this is lost with the computer; use a floppy for that.")
        return
    end

    local ok, result = backup.saveToDisk(archive)
    if not ok then
        printError(tostring(result))
        print("")
        print("Put a floppy in a disk drive attached to this computer,")
        print("or run 'backup local' to keep a copy here instead.")
        return
    end

    print("Saved " .. archive.fileCount .. " file(s) to " .. tostring(result))
    print("Label the floppy: " .. tostring(archive.node))
end

local function doShow()
    local archive, err = backup.loadFromDisk()
    if not archive then
        printError(tostring(err))
        return
    end
    describe(archive, "On the floppy:")
end

local function doRestore(source)
    local archive, err
    if source == "local" then
        archive = backup.loadLocal()
        err = "no local copy on this computer"
    else
        archive, err = backup.loadFromDisk()
    end

    if not archive then
        printError(tostring(err))
        return
    end

    local info = describe(archive, "About to restore:")
    if not info then return end

    print("")
    print("This overwrites config/ and this computer's role.")
    if not confirm("Restore it?") then
        print("Cancelled. Nothing was changed.")
        return
    end

    local written, applyError = backup.apply(archive)
    if written == 0 then
        printError("Nothing was restored: " .. tostring(applyError))
        return
    end

    print("")
    print("Restored " .. written .. " file(s).")
    print("Run 'reboot' to start with them.")
end

--- A replacement computer asks the master for the config of the name it now
--- has. BaseOS is not running here, so this opens rednet itself.
local function doPull()
    local me = identity.load()
    if not me then
        printError("This computer has no identity yet. Run 'setup' first,")
        print("giving it the same name as the computer it replaces.")
        return
    end

    local opened = false
    for _, side in ipairs(peripheral.getNames()) do
        local ok, kind = pcall(peripheral.getType, side)
        if ok and kind == "modem" and not rednet.isOpen(side) then
            if pcall(rednet.open, side) then opened = true end
        elseif ok and kind == "modem" then
            opened = true
        end
    end

    if not opened then
        printError("No modem on this computer, so it cannot reach the master.")
        return
    end

    print("Asking the master for the config of '" .. tostring(me.name) .. "' ...")
    rednet.broadcast({
        version = 1, id = 1, type = "config.request",
        source = me.name, target = "*", timestamp = 0,
        payload = { node = me.name },
    }, "baseos")

    -- The master answers while BaseOS is running on it.
    local deadline = os.clock() + 5
    while os.clock() < deadline do
        local _, message = rednet.receive("baseos", 1)
        if type(message) == "table" and message.type == "config.restore" then
            local payload = message.payload or {}
            if payload.error then
                printError(tostring(payload.error))
                return
            end

            local info = describe(payload.archive, "The master sent:")
            if not info then return end

            print("")
            if not confirm("Restore it onto this computer?") then
                print("Cancelled.")
                return
            end

            -- Keep the identity this computer was just given by `setup`.
            local written = backup.apply(payload.archive, { identity = false })
            print("")
            print("Restored " .. written .. " file(s). Run 'reboot'.")
            return
        end
    end

    printError("No answer from the master.")
    print("Check that BaseOS is running there, that both have modems, and")
    print("that the name matches the one the old computer used.")
end

local function doList()
    local nodes = backup.remoteNodes()
    if #nodes == 0 then
        print("This computer holds no backups for other nodes.")
        print("Nodes send theirs while BaseOS is running on both.")
        return
    end

    print(#nodes .. " backup(s) held:")
    for _, entry in ipairs(nodes) do
        local age = entry.createdAt
            and util.formatDuration((util.nowMs() - entry.createdAt) / 1000) .. " ago"
            or "unknown"
        print(("  %-16s %-8s %s"):format(
            tostring(entry.node), tostring(entry.role or "?"), age))
    end
end

---------------------------------------------------------------------------

local command, argument = ...

if command == nil then
    doSave("disk")
elseif command == "local" then
    doSave("local")
elseif command == "show" then
    doShow()
elseif command == "restore" then
    doRestore(argument)
elseif command == "pull" then
    doPull()
elseif command == "list" then
    doList()
else
    printError("Unknown command '" .. tostring(command) .. "'.")
    print("")
    print("backup           save to a floppy")
    print("backup local     save a copy here")
    print("backup show      what a floppy holds")
    print("backup restore   restore from a floppy")
    print("backup list      backups this computer holds for nodes")
end

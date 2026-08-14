--- File persistence helpers.
--
-- Everything lives under `data/` (configurable). Only durable things belong
-- here: user settings, module state that must survive a chunk reload, alert
-- acknowledgements. Live metrics stay in `core.state` and are never written.

local util = require("core.util")
local logger = require("core.logger")

local log = logger.scoped("persist")

local persistence = {}

local directory = "data"

--- @param options table { directory = string, root = string }
function persistence.init(options)
    options = options or {}
    directory = options.directory or "data"
    if options.root and options.root ~= "" then
        directory = fs.combine(options.root, directory)
    end
    if not fs.exists(directory) then
        local ok, err = pcall(fs.makeDir, directory)
        if not ok then log.error("cannot create %s: %s", directory, tostring(err)) end
    end
    return persistence
end

function persistence.directory() return directory end

function persistence.path(name)
    if name:sub(-4) ~= ".dat" and name:sub(-5) ~= ".json" then name = name .. ".dat" end
    return fs.combine(directory, name)
end

function persistence.exists(name) return fs.exists(persistence.path(name)) end

--- Read one file and parse it, or nil plus why.
local function readTable(path)
    if not fs.exists(path) then return nil, "missing" end

    local handle = fs.open(path, "r")
    if not handle then return nil, "unreadable" end
    local contents = handle.readAll()
    handle.close()

    local ok, value = pcall(textutils.unserialise, contents)
    if not ok or type(value) ~= "table" then return nil, "corrupt" end
    return value
end

--- Serialise a table to disk. Returns ok, error.
--
-- Written through a temporary file and moved into place, because a computer
-- can stop mid-write at any moment - its chunk unloads, the server stops, the
-- player logs off - and half a serialised table is not a table. The move is the
-- only step that can be interrupted, and it either happened or it did not.
--
-- The previous contents are kept as `.bak`, so even a torn move leaves one good
-- copy on disk.
function persistence.save(name, value)
    local path = persistence.path(name)
    local ok, serialised = pcall(textutils.serialise, value)
    if not ok then
        log.error("cannot serialise '%s': %s", name, tostring(serialised))
        return false, serialised
    end

    local temporary = path .. ".tmp"
    local backup = path .. ".bak"

    local handle, err = fs.open(temporary, "w")
    if not handle then
        log.error("cannot write '%s': %s", temporary, tostring(err))
        return false, err
    end
    handle.write(serialised)
    handle.close()

    local moved, moveError = pcall(function()
        if fs.exists(path) then
            if fs.exists(backup) then fs.delete(backup) end
            fs.move(path, backup)
        end
        fs.move(temporary, path)
    end)

    if not moved then
        log.error("cannot replace '%s': %s", path, tostring(moveError))
        pcall(fs.delete, temporary)
        return false, moveError
    end
    return true
end

--- Read a table from disk, returning `default` when missing or corrupt.
-- A corrupt file falls back to the `.bak` left by the last successful save
-- before it gives up.
function persistence.load(name, default)
    local path = persistence.path(name)

    local value, reason = readTable(path)
    if value then return value end
    if reason == "missing" and not fs.exists(path .. ".bak") then return default end

    local recovered = readTable(path .. ".bak")
    if recovered then
        log.warn("'%s' is %s, recovered the previous version", path, reason)
        return recovered
    end

    log.warn("'%s' is %s and has no usable backup, using the default", path, reason)
    return default
end

function persistence.delete(name)
    local path = persistence.path(name)
    local deleted = false
    -- The backup goes too: leaving it behind would resurrect the old value on
    -- the next load, which is the opposite of what deleting means.
    for _, target in ipairs({ path, path .. ".bak", path .. ".tmp" }) do
        if fs.exists(target) then
            local ok = pcall(fs.delete, target)
            deleted = deleted or ok
        end
    end
    return deleted
end

--- Merge and store a partial update.
function persistence.patch(name, patch)
    local current = persistence.load(name, {})
    return persistence.save(name, util.deepMerge(current, patch))
end

return persistence

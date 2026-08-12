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

--- Serialise a table to disk. Returns ok, error.
function persistence.save(name, value)
    local path = persistence.path(name)
    local ok, serialised = pcall(textutils.serialise, value)
    if not ok then
        log.error("cannot serialise '%s': %s", name, tostring(serialised))
        return false, serialised
    end

    local handle, err = fs.open(path, "w")
    if not handle then
        log.error("cannot write '%s': %s", path, tostring(err))
        return false, err
    end

    handle.write(serialised)
    handle.close()
    return true
end

--- Read a table from disk, returning `default` when missing or corrupt.
function persistence.load(name, default)
    local path = persistence.path(name)
    if not fs.exists(path) then return default end

    local handle = fs.open(path, "r")
    if not handle then return default end
    local contents = handle.readAll()
    handle.close()

    local ok, value = pcall(textutils.unserialise, contents)
    if not ok or type(value) ~= "table" then
        log.warn("'%s' is corrupt, using default", path)
        return default
    end
    return value
end

function persistence.delete(name)
    local path = persistence.path(name)
    if fs.exists(path) then
        return pcall(fs.delete, path)
    end
    return false
end

--- Merge and store a partial update.
function persistence.patch(name, patch)
    local current = persistence.load(name, {})
    return persistence.save(name, util.deepMerge(current, patch))
end

return persistence

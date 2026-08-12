--- What this computer is: its role in the base, and which modules it runs.
--
-- Stored in `data/node.dat`, which lives outside everything the updater
-- touches, so a computer keeps its identity across updates and reboots and is
-- never asked again.
--
--   local identity = require("core.identity")
--   local me = identity.load()      -- nil on a computer that was never set up
--   me.role      -- "master" | "node"
--   me.name      -- unique on the network, e.g. "power_node"
--   me.modules   -- module ids this computer should load
--
-- `setup.lua` writes it, `reset.lua` clears it, and nothing else should.

local util = require("core.util")

local identity = {}

identity.FILE = "data/node.dat"

--- Presets offered by the setup wizard.
-- A profile is only a starting point: `modules` is copied into the identity
-- when it is created, and can be edited afterwards without touching this table.
identity.PROFILES = {
    {
        id = "master",
        role = "master",
        label = "Master",
        description = "Touch UI, aggregates every node",
        modules = { "system", "power", "storage" },
    },
    {
        id = "power",
        role = "node",
        label = "Power node",
        description = "Reads energy storage, reports to the master",
        modules = { "system", "power" },
    },
    {
        id = "storage",
        role = "node",
        label = "Storage node",
        description = "Reads item storage, reports to the master",
        modules = { "system", "storage" },
    },
    {
        id = "farm",
        role = "node",
        label = "Farm node",
        description = "Runs farm instances from config/modules.lua",
        modules = { "system" },
    },
    {
        id = "display",
        role = "display",
        label = "Display",
        description = "A monitor anywhere, showing one fixed view",
        modules = { "system" },
        -- Which view it shows; chosen during setup, edited in data/node.dat.
        view = { title = "BASE", modules = "*" },
    },
    {
        id = "custom",
        role = "node",
        label = "Custom node",
        description = "Modules come from config/modules.lua",
        modules = nil,
    },
}

--- Views a display can be pinned to. `modules` is matched against module ids:
--- "*" is everything, a plain string is a prefix, a list is exact ids.
identity.VIEWS = {
    { id = "all", title = "BASE", modules = "*", description = "Everything reporting" },
    { id = "power", title = "POWER", modules = "power", description = "Energy only" },
    { id = "storage", title = "STORAGE", modules = "storage", description = "Item storage only" },
    { id = "farms", title = "FARMS", modules = "farm", description = "Anything farm-like" },
    { id = "alerts", title = "ALERTS", screen = "alerts", description = "The alert list" },
    { id = "nodes", title = "NODES", screen = "nodes", description = "Node health" },
}

function identity.view(id)
    for _, view in ipairs(identity.VIEWS) do
        if view.id == id then return view end
    end
    return nil
end

function identity.profile(id)
    for _, profile in ipairs(identity.PROFILES) do
        if profile.id == id then return profile end
    end
    return nil
end

--- Absolute path, honouring the install root.
function identity.path(root)
    root = root or (BASEOS and BASEOS.root) or ""
    return (root ~= "") and fs.combine(root, identity.FILE) or identity.FILE
end

--- Read the identity, or nil when this computer was never set up.
function identity.load(root)
    local path = identity.path(root)
    if not fs.exists(path) then return nil end

    local handle = fs.open(path, "r")
    if not handle then return nil end
    local contents = handle.readAll()
    handle.close()

    local ok, value = pcall(textutils.unserialise, contents)
    if not ok or type(value) ~= "table" or type(value.role) ~= "string" then
        return nil
    end
    return value
end

--- Write the identity. Returns ok, error.
function identity.save(record, root)
    if type(record) ~= "table" or type(record.role) ~= "string" then
        return false, "an identity needs a role"
    end

    record.updatedAt = util.nowMs()
    record.createdAt = record.createdAt or record.updatedAt

    local path = identity.path(root)
    local dir = fs.getDir(path)
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end

    local handle, err = fs.open(path, "w")
    if not handle then return false, tostring(err) end
    handle.write(textutils.serialise(record))
    handle.close()
    return true
end

function identity.clear(root)
    local path = identity.path(root)
    if fs.exists(path) then return pcall(fs.delete, path) end
    return false
end

--- The identity a computer without one should assume.
-- Master, so an existing single-computer install keeps working untouched after
-- an update that introduces roles.
function identity.default()
    return {
        role = "master",
        profile = "master",
        name = os.getComputerLabel() or ("computer_" .. os.getComputerID()),
        modules = nil,        -- fall back to config/modules.lua
        implicit = true,      -- not chosen by the user; setup was never run
    }
end

function identity.isMaster(record)
    return (record and record.role or "master") == "master"
end

function identity.isDisplay(record)
    return record ~= nil and record.role == "display"
end

--- Roles that own a monitor and draw screens.
function identity.hasUI(record)
    return identity.isMaster(record) or identity.isDisplay(record)
end

return identity

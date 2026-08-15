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

--- Node names are shown in tables and used as state keys; long ones help nobody.
identity.MAX_NAME = 24

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
    { id = "map", title = "BASE MAP", screen = "map", description = "The base plan and its links" },
    { id = "alerts", title = "ALERTS", screen = "alerts", description = "The alert list" },
    { id = "nodes", title = "NODES", screen = "nodes", description = "Node health" },
    { id = "network", title = "REDNET", screen = "network",
      description = "Modems, peers and traffic" },
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

--- Is this a name a computer can actually carry?
--
-- Telemetry keys the state tree by node name (`nodes.<name>.online`), and that
-- tree is addressed with dotted paths - so a node called "power.node" is filed
-- as a node called "power" containing something called "node", and can never be
-- marked offline again. Rather than escape the name everywhere it is used, the
-- rule is that a name has no dots in it.
--
-- @return boolean ok, string|nil reason
function identity.validateName(name)
    if type(name) ~= "string" then return false, "a name is required" end

    local trimmed = name:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then return false, "the name cannot be empty" end
    if #trimmed > identity.MAX_NAME then
        return false, "keep the name under " .. identity.MAX_NAME .. " characters"
    end
    if trimmed:find("%.") then
        return false, "no dots in the name - they split the state tree"
    end
    if trimmed:find("[^%w_%-]") then
        return false, "letters, digits, '_' and '-' only"
    end
    return true
end

--- Trim and clean a name into something valid, for suggesting a default.
function identity.cleanName(name)
    local cleaned = tostring(name or ""):gsub("%s+", "_"):gsub("[^%w_%-]", "")
    return cleaned:sub(1, identity.MAX_NAME)
end

local function readIdentity(path)
    if not fs.exists(path) then return nil, "missing" end

    local handle = fs.open(path, "r")
    if not handle then return nil, "unreadable" end
    local contents = handle.readAll()
    handle.close()

    local ok, value = pcall(textutils.unserialise, contents)
    if not ok or type(value) ~= "table" or type(value.role) ~= "string" then
        return nil, "corrupt"
    end
    return value
end

--- Read the identity, or nil when this computer was never set up.
--
-- The second return says which of those it was. It matters: a computer with no
-- identity is a fresh install and assuming master is right, but a computer
-- whose identity is unreadable is something that already had a role, and
-- quietly promoting it to master would take a node off the network and put a
-- second master on it. The caller has to be able to tell the two apart.
--
-- @return table|nil identity, string|nil reason ("missing" | "corrupt")
function identity.load(root)
    local path = identity.path(root)

    local value = readIdentity(path)
    if value then return value end

    -- The copy `save` leaves behind. One torn write should not cost a role.
    local recovered, backupReason = readIdentity(path .. ".bak")
    if recovered then return recovered, "recovered" end

    if not fs.exists(path) and backupReason == "missing" then return nil, "missing" end
    return nil, "corrupt"
end

--- Write the identity. Returns ok, error.
-- Through a temporary file and a move, keeping the previous one as `.bak`:
-- this is the file a computer cannot afford to lose.
function identity.save(record, root)
    if type(record) ~= "table" or type(record.role) ~= "string" then
        return false, "an identity needs a role"
    end
    if record.name ~= nil then
        local valid, reason = identity.validateName(record.name)
        if not valid then return false, reason end
    end

    record.updatedAt = util.nowMs()
    record.createdAt = record.createdAt or record.updatedAt

    local path = identity.path(root)
    local dir = fs.getDir(path)
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end

    local temporary, backup = path .. ".tmp", path .. ".bak"

    local handle, err = fs.open(temporary, "w")
    if not handle then return false, tostring(err) end
    handle.write(textutils.serialise(record))
    handle.close()

    local moved, moveError = pcall(function()
        if fs.exists(path) then
            if fs.exists(backup) then fs.delete(backup) end
            fs.move(path, backup)
        end
        fs.move(temporary, path)
    end)

    if not moved then
        pcall(fs.delete, temporary)
        return false, tostring(moveError)
    end
    return true
end

function identity.clear(root)
    local path = identity.path(root)
    local cleared = false
    for _, target in ipairs({ path, path .. ".bak", path .. ".tmp" }) do
        if fs.exists(target) then
            local ok = pcall(fs.delete, target)
            cleared = cleared or ok
        end
    end
    return cleared
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

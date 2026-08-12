--- Configuration loader.
--
-- Configuration lives in `/config/*.lua`, each file returning a plain table.
-- Files are merged over the built-in defaults below, so a user config only has
-- to state what differs. Missing files are not an error.
--
--   config.get("system.name")
--   config.get("ui.refreshInterval", 0.5)
--   config.section("layout")
--
-- Runtime overrides written with `config.set` are kept in memory only unless
-- `config.saveOverrides()` is called (see services.persistence).

local util = require("core.util")
local logger = require("core.logger")

local log = logger.scoped("config")

local config = {}

--- Files loaded from /config, in merge order.
config.FILES = { "system", "peripherals", "layout", "modules", "network", "theme" }

--- Built-in defaults. Anything referenced by the core must have a default here
--- so BaseOS still boots on a computer with an empty /config directory.
local DEFAULTS = {
    system = {
        name = "BASE CONTROL",
        version = "0.1.0",
        nodeRole = "master",   -- master | node
        nodeId = nil,          -- defaults to the computer label / id
        useInGameClock = true,
        logging = {
            level = "INFO",
            toTerminal = true,
            toFile = true,
            filePath = "data/baseos.log",
        },
        ui = {
            refreshInterval = 1.0,   -- seconds between dashboard repaints
            monitorTextScale = 0.5,
            useTerminalFallback = true,
            showFooter = true,
            showHeader = true,
        },
        modules = {
            defaultPollInterval = 2.0,
        },
        persistence = {
            directory = "data",
            autosaveInterval = 60,
        },
    },

    peripherals = {
        -- Logical alias -> matcher. `type` picks the first free peripheral of
        -- that type, `name` pins an exact peripheral name.
        aliases = {
            mainMonitor = { type = "monitor", optional = true },
        },
        rescanInterval = 30,
    },

    layout = {
        mode = "grid",      -- grid | absolute
        grid = { columns = 12, rows = 8 },
        title = nil,        -- defaults to system.name
        zones = {},
    },

    modules = {
        -- Module ids loaded from src/modules/<id>.lua at boot.
        enabled = { "system", "demo_farm" },
        settings = {},
    },

    network = {
        enabled = false,
        protocol = "baseos",
        hostname = nil,
        openAllModems = true,
        modemSide = nil,
        heartbeatInterval = 10,
        peerTimeout = 30,
    },

    theme = {
        preset = "dark",
        overrides = {},
    },
}

local values = util.deepCopy(DEFAULTS)
local overrides = {}
local sourceFiles = {}

local function loadConfigFile(name, root, requireFn)
    local relative = "config/" .. name .. ".lua"
    local path = (root and root ~= "") and fs.combine(root, relative) or relative

    if not fs.exists(path) then return nil end

    local ok, result = pcall(requireFn, "config." .. name)
    if not ok then
        log.error("failed to load %s: %s", relative, tostring(result))
        return nil
    end
    if type(result) ~= "table" then
        log.warn("%s did not return a table, ignoring", relative)
        return nil
    end

    sourceFiles[#sourceFiles + 1] = relative
    return result
end

--- Load every configuration file. Called once during boot.
-- @param options table { root = string, require = function }
function config.load(options)
    options = options or {}
    local requireFn = options.require or require
    local root = options.root or (BASEOS and BASEOS.root) or ""

    values = util.deepCopy(DEFAULTS)
    sourceFiles = {}

    for _, name in ipairs(config.FILES) do
        local loaded = loadConfigFile(name, root, requireFn)
        if loaded then
            values[name] = util.deepMerge(values[name], loaded)
        end
    end

    -- Runtime overrides survive a reload.
    for path, value in pairs(overrides) do
        util.plant(values, path, value)
    end

    return values
end

--- Whole configuration tree (live reference, treat as read-only).
function config.all() return values end

--- One top-level section, e.g. config.section("layout").
function config.section(name) return values[name] or {} end

--- Dotted lookup with a default: config.get("system.ui.refreshInterval", 1)
function config.get(path, default)
    local value = util.dig(values, path)
    if value == nil then return default end
    return value
end

--- Runtime override. Persisted only if saveOverrides is called.
function config.set(path, value)
    overrides[path] = value
    util.plant(values, path, value)
    return value
end

function config.overrides() return util.deepCopy(overrides) end

function config.setOverrides(map)
    overrides = util.deepCopy(map or {})
    for path, value in pairs(overrides) do
        util.plant(values, path, value)
    end
end

--- Which config files were actually found on disk (diagnostics).
function config.sources() return util.deepCopy(sourceFiles) end

config.DEFAULTS = DEFAULTS

return config

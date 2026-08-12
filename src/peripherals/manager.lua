--- Peripheral Manager.
--
-- The single owner of `peripheral.*` in BaseOS. Modules never call
-- `peripheral.find` themselves; they ask for a logical alias or a capability:
--
--   local monitor = manager.get("mainMonitor")
--   local cells   = manager.findByType("energyDetector")
--   local anyInv  = manager.findByMethod("list")
--
-- Everything handed back is a *safe proxy*: calling a method that fails (or a
-- peripheral that has been ripped off the wall) returns nil plus an error
-- string instead of throwing.

local util = require("core.util")
local logger = require("core.logger")
local bus = require("core.event_bus")
local state = require("core.state")

local log = logger.scoped("peripherals")

local manager = {}

local devices = {}    -- [name] = { name, types = {}, methods = {}, proxy }
local aliases = {}    -- [alias] = { matcher = {...}, name = string|nil }
local initialised = false

---------------------------------------------------------------------------
-- Low level helpers
---------------------------------------------------------------------------

-- CC:Tweaked returns one type on older builds and several (generic + specific)
-- on newer ones, so collect the whole vararg.
local function typesOf(name)
    local ok, types = pcall(function() return { peripheral.getType(name) } end)
    if not ok or type(types) ~= "table" then return {} end
    return types
end

local function methodsOf(name)
    local ok, list = pcall(peripheral.getMethods, name)
    if not ok or type(list) ~= "table" then return {} end
    local set = {}
    for _, method in ipairs(list) do set[method] = true end
    return set
end

--- Wrap a peripheral so every call is protected.
local function makeProxy(name)
    local proxy = {
        __name = name,
        __isBaseOSProxy = true,
    }

    function proxy.name() return name end

    function proxy.isValid()
        local device = devices[name]
        if not device then return false end
        local ok, present = pcall(peripheral.isPresent, name)
        return ok and present == true
    end

    function proxy.types()
        local device = devices[name]
        return device and util.deepCopy(device.types) or {}
    end

    function proxy.hasType(wanted)
        local device = devices[name]
        if not device then return false end
        for _, kind in ipairs(device.types) do
            if kind == wanted then return true end
        end
        return false
    end

    function proxy.hasMethod(method)
        local device = devices[name]
        return device ~= nil and device.methods[method] == true
    end

    --- Raw wrapped peripheral. Prefer proxy.call / proxy.<method>.
    function proxy.raw()
        local ok, wrapped = pcall(peripheral.wrap, name)
        return ok and wrapped or nil
    end

    --- Protected call. Returns (value, nil) or (nil, errorMessage).
    function proxy.call(method, ...)
        local device = devices[name]
        if not device then return nil, "peripheral '" .. name .. "' is not connected" end
        if not device.methods[method] then
            return nil, "peripheral '" .. name .. "' has no method '" .. method .. "'"
        end
        local results = table.pack(pcall(peripheral.call, name, method, ...))
        if not results[1] then
            log.debug("call %s.%s failed: %s", name, method, tostring(results[2]))
            return nil, tostring(results[2])
        end
        return table.unpack(results, 2, results.n)
    end

    -- proxy.getEnergy(...) style access, still protected.
    return setmetatable(proxy, {
        __index = function(_, key)
            if type(key) ~= "string" then return nil end
            local device = devices[name]
            if not device or not device.methods[key] then return nil end
            return function(...) return proxy.call(key, ...) end
        end,
        __tostring = function() return "peripheral<" .. name .. ">" end,
    })
end

local function describe(device)
    return {
        name = device.name,
        types = util.deepCopy(device.types),
        methodCount = util.count(device.methods),
    }
end

local function publishState()
    local list = {}
    for name, device in pairs(devices) do
        list[name] = describe(device)
    end
    state.set("peripherals.devices", list)

    local resolved = {}
    for alias, entry in pairs(aliases) do
        resolved[alias] = {
            name = entry.name,
            type = entry.matcher.type,
            optional = entry.matcher.optional ~= false,
            connected = entry.name ~= nil,
        }
    end
    state.set("peripherals.aliases", resolved)
    state.set("peripherals.count", util.count(devices))
end

---------------------------------------------------------------------------
-- Discovery
---------------------------------------------------------------------------

local function addDevice(name)
    local device = {
        name = name,
        types = typesOf(name),
        methods = methodsOf(name),
    }
    device.proxy = makeProxy(name)
    devices[name] = device
    return device
end

--- Which alias (if any) already claimed a peripheral name.
local function claimedBy(name)
    for alias, entry in pairs(aliases) do
        if entry.name == name then return alias end
    end
    return nil
end

local function matches(device, matcher)
    if matcher.name and device.name ~= matcher.name then return false end
    if matcher.type then
        local found = false
        for _, kind in ipairs(device.types) do
            if kind == matcher.type then found = true break end
        end
        if not found then return false end
    end
    if matcher.method and not device.methods[matcher.method] then return false end
    if type(matcher.match) == "function" then
        local ok, result = pcall(matcher.match, device.proxy, device)
        if not ok or not result then return false end
    end
    return true
end

--- (Re)bind every configured alias to a connected peripheral.
function manager.resolveAliases()
    local changes = {}

    for alias, entry in pairs(aliases) do
        local previous = entry.name

        -- Keep the current binding if it is still valid.
        if entry.name and devices[entry.name] and matches(devices[entry.name], entry.matcher) then
            -- nothing to do
        else
            entry.name = nil
            local names = util.sortedKeys(devices)
            for _, name in ipairs(names) do
                local device = devices[name]
                local claimer = claimedBy(name)
                if matches(device, entry.matcher) and (claimer == nil or claimer == alias) then
                    entry.name = name
                    break
                end
            end
        end

        if entry.name ~= previous then
            changes[#changes + 1] = { alias = alias, from = previous, to = entry.name }
        end
    end

    for _, change in ipairs(changes) do
        if change.to then
            log.info("alias '%s' -> %s", change.alias, change.to)
            bus.emit("peripheral.alias_bound", { alias = change.alias, name = change.to })
        else
            log.warn("alias '%s' is unbound (was %s)", change.alias, tostring(change.from))
            bus.emit("peripheral.alias_lost", { alias = change.alias, name = change.from })
        end
    end

    if #changes > 0 then publishState() end
    return changes
end

--- Full rescan of the peripheral network.
function manager.scan()
    local ok, names = pcall(peripheral.getNames)
    if not ok or type(names) ~= "table" then
        log.error("peripheral.getNames failed: %s", tostring(names))
        return {}
    end

    local seen = {}
    for _, name in ipairs(names) do
        seen[name] = true
        if not devices[name] then
            local device = addDevice(name)
            log.debug("found %s (%s)", name, table.concat(device.types, ","))
        end
    end

    for name in pairs(devices) do
        if not seen[name] then
            devices[name] = nil
            log.debug("lost %s", name)
        end
    end

    manager.resolveAliases()
    publishState()
    return names
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Register (or replace) a logical alias at runtime.
-- @param alias string
-- @param matcher table { type = string, name = string, method = string,
--                        match = function(proxy, device), optional = bool }
function manager.registerAlias(alias, matcher)
    if type(matcher) == "string" then matcher = { type = matcher } end
    aliases[alias] = { matcher = matcher or {}, name = nil }
    if initialised then manager.resolveAliases() end
    return aliases[alias]
end

--- Proxy bound to a logical alias, or nil when nothing matched.
function manager.get(alias)
    local entry = aliases[alias]
    if not entry or not entry.name then return nil end
    local device = devices[entry.name]
    return device and device.proxy or nil
end

--- True when the alias currently resolves to a connected peripheral.
function manager.has(alias)
    return manager.get(alias) ~= nil
end

--- Proxy for an exact peripheral name.
function manager.getByName(name)
    local device = devices[name]
    return device and device.proxy or nil
end

--- Every connected peripheral exposing `type`.
function manager.findByType(kind)
    local found = {}
    for _, name in ipairs(util.sortedKeys(devices)) do
        local device = devices[name]
        for _, deviceType in ipairs(device.types) do
            if deviceType == kind then
                found[#found + 1] = device.proxy
                break
            end
        end
    end
    return found
end

--- First peripheral of a type (convenience for singletons).
function manager.firstOfType(kind)
    return manager.findByType(kind)[1]
end

--- Capability lookup: every peripheral implementing a method.
-- Useful for generic adapters ("anything with a `list` method is an inventory").
function manager.findByMethod(method)
    local found = {}
    for _, name in ipairs(util.sortedKeys(devices)) do
        local device = devices[name]
        if device.methods[method] then found[#found + 1] = device.proxy end
    end
    return found
end

--- Every connected peripheral as { name = descriptor }.
function manager.list()
    local result = {}
    for name, device in pairs(devices) do result[name] = describe(device) end
    return result
end

function manager.names() return util.sortedKeys(devices) end

function manager.count() return util.count(devices) end

--- Alias table for diagnostics.
function manager.aliasInfo()
    local result = {}
    for alias, entry in pairs(aliases) do
        result[alias] = {
            name = entry.name,
            matcher = util.deepCopy(entry.matcher),
            connected = entry.name ~= nil,
        }
    end
    return result
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local function onAttach(name)
    if not name then return end
    local device = addDevice(name)
    log.info("attached %s (%s)", name, table.concat(device.types, ","))
    manager.resolveAliases()
    publishState()
    bus.emit("peripheral.attached", { name = name, types = util.deepCopy(device.types) })
end

local function onDetach(name)
    if not name then return end
    local device = devices[name]
    devices[name] = nil
    log.warn("detached %s", name)
    manager.resolveAliases()
    publishState()
    bus.emit("peripheral.detached", {
        name = name,
        types = device and util.deepCopy(device.types) or {},
    })
end

--- Wire the manager up. Call once from `core.app`.
-- @param options table { aliases = table, rescanInterval = number, scheduler = module }
function manager.init(options)
    options = options or {}

    aliases = {}
    for alias, matcher in pairs(options.aliases or {}) do
        manager.registerAlias(alias, matcher)
    end

    bus.on("peripheral", function(name) onAttach(name) end, { owner = "peripheral_manager" })
    bus.on("peripheral_detach", function(name) onDetach(name) end, { owner = "peripheral_manager" })

    initialised = true
    manager.scan()

    -- A periodic rescan catches wired modem topology changes that do not always
    -- surface as attach/detach events on the master computer.
    local interval = options.rescanInterval or 30
    if options.scheduler and interval and interval > 0 then
        options.scheduler.every(interval, function() manager.scan() end,
            { name = "peripherals.rescan", owner = "peripheral_manager" })
    end

    log.info("peripheral manager ready (%d device(s))", manager.count())
    return manager
end

function manager.shutdown()
    bus.offOwner("peripheral_manager")
    initialised = false
end

return manager

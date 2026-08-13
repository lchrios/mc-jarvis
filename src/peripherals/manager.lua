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

--- How often the network is walked again.
-- A base is not static: chunks unload, a modem gets broken by a creeper, a
-- machine is replaced by a bigger one. Attach/detach events cover most of that,
-- but not all of it - a peripheral whose chunk unloads can simply stop
-- answering without ever reporting that it left.
local rescan = {
    interval = 30,          -- seconds between scans when everything is healthy
    degradedInterval = 5,   -- ...and while something required is missing
    deepEvery = 4,          -- one scan in N re-reads types and methods
    minGap = 1,             -- floor between forced scans, so a storm is one scan
}

local lastScanAt = 0
local scanCount = 0
local degradedState = false

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

--- What a peripheral looks like, so a replacement behind the same name shows up.
local function signature(types, methods)
    local names = {}
    for method in pairs(methods or {}) do names[#names + 1] = method end
    table.sort(names)
    return table.concat(types or {}, ",") .. "|" .. table.concat(names, ",")
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
            -- A method can fail for its own reasons; a peripheral that is gone
            -- fails every time. `noteFailure` tells the two apart and, if it
            -- really left, rescans instead of waiting for the next tick.
            manager.noteFailure(name)
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
    state.set("peripherals.lastScan", lastScanAt)
    state.set("peripherals.scans", scanCount)

    -- Single place where this is decided, so an attach, a detach and a new
    -- alias all leave the same answer behind.
    local missing
    degradedState, missing = manager.degraded()
    state.set("peripherals.degraded", degradedState)
    state.set("peripherals.missing", missing)
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

--- Are any non-optional aliases unbound right now?
-- This is what makes the rescan adaptive: a base missing something it was told
-- to expect looks again every few seconds, a healthy one every half minute.
function manager.degraded()
    local missing = {}
    for alias, entry in pairs(aliases) do
        if entry.matcher.optional ~= true and not entry.name then
            missing[#missing + 1] = alias
        end
    end
    table.sort(missing)
    return #missing > 0, missing
end

--- Full rescan of the peripheral network.
-- @param options table { deep = bool } - `deep` re-reads types and methods of
--        peripherals already known, catching a block replaced by another one
--        that reused its name.
function manager.scan(options)
    options = options or {}

    local ok, names = pcall(peripheral.getNames)
    if not ok or type(names) ~= "table" then
        log.error("peripheral.getNames failed: %s", tostring(names))
        return {}
    end

    local found, lost, changed = {}, {}, {}

    local seen = {}
    for _, name in ipairs(names) do
        seen[name] = true
        if not devices[name] then
            local device = addDevice(name)
            found[#found + 1] = device
        elseif options.deep then
            -- Same name, possibly a different block behind it.
            local device = devices[name]
            local types, methods = typesOf(name), methodsOf(name)
            if signature(types, methods) ~= signature(device.types, device.methods) then
                device.types, device.methods = types, methods
                changed[#changed + 1] = device
            end
        end
    end

    -- A peripheral can stop existing without ever saying so: an unloaded chunk
    -- takes it away silently. `getNames` usually drops it, `isPresent` is the
    -- second opinion.
    for name in pairs(devices) do
        if not seen[name] then
            lost[#lost + 1] = devices[name]
        else
            local ok2, present = pcall(peripheral.isPresent, name)
            if ok2 and present == false then lost[#lost + 1] = devices[name] end
        end
    end
    for _, device in ipairs(lost) do devices[device.name] = nil end

    lastScanAt = util.nowMs()
    scanCount = scanCount + 1

    manager.resolveAliases()
    publishState()

    -- Announced after the aliases settle, so a listener that reacts to an
    -- attach already sees it bound.
    for _, device in ipairs(found) do
        log.info("found %s (%s)", device.name, table.concat(device.types, ","))
        bus.emit("peripheral.attached", {
            name = device.name, types = util.deepCopy(device.types), viaScan = true,
        })
    end
    for _, device in ipairs(lost) do
        log.warn("lost %s (no longer present)", device.name)
        bus.emit("peripheral.detached", {
            name = device.name, types = util.deepCopy(device.types), viaScan = true,
        })
    end
    for _, device in ipairs(changed) do
        log.info("%s changed: now %s", device.name, table.concat(device.types, ","))
        bus.emit("peripheral.changed", {
            name = device.name, types = util.deepCopy(device.types),
        })
    end

    return names
end

--- Scan now. Called on boot, from the RESCAN button, and by anything with
--- reason to believe the network moved under it. Always deep: whoever asked
--- did so because something looked wrong.
function manager.rescan(reason)
    if not initialised then return false end

    log.debug("rescan: %s", tostring(reason or "requested"))
    manager.scan({ deep = true })
    return true
end

--- A call against `name` failed. If the peripheral is simply gone, drop it now
--- rather than waiting for the next scheduled scan.
-- A machine that left takes every call with it, so this is rate limited: a
-- module polling ten dead cells causes one scan, not ten.
function manager.noteFailure(name)
    if not initialised or not devices[name] then return end
    if (util.nowMs() - lastScanAt) < rescan.minGap * 1000 then return end

    local ok, present = pcall(peripheral.isPresent, name)
    if ok and present == false then
        manager.rescan("'" .. name .. "' stopped answering")
    end
end

--- Stats for the peripherals screen.
function manager.stats()
    local degraded, missing = manager.degraded()
    return {
        count = util.count(devices),
        scans = scanCount,
        lastScanAt = lastScanAt,
        degraded = degraded,
        missing = missing,
        interval = degraded and rescan.degradedInterval or rescan.interval,
    }
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
-- @param options table { aliases = table, rescan = table, scheduler = module }
function manager.init(options)
    options = options or {}

    -- The old spelling first, so an explicit `rescan` table still wins.
    if type(options.rescanInterval) == "number" then rescan.interval = options.rescanInterval end
    for key, value in pairs(options.rescan or {}) do
        if rescan[key] ~= nil and type(value) == "number" then rescan[key] = value end
    end

    aliases = {}
    for alias, matcher in pairs(options.aliases or {}) do
        manager.registerAlias(alias, matcher)
    end

    bus.on("peripheral", function(name) onAttach(name) end, { owner = "peripheral_manager" })
    bus.on("peripheral_detach", function(name) onDetach(name) end, { owner = "peripheral_manager" })

    initialised = true
    lastScanAt, scanCount = 0, 0
    manager.scan({ deep = true })

    -- The periodic rescan catches what the events miss: wired modem topology
    -- changes, and peripherals that went away with their chunk. The tick runs
    -- at the shorter of the two intervals and decides each time whether a scan
    -- is due, so a base that is missing something looks again sooner without a
    -- second timer.
    local tick = math.max(1, math.min(rescan.interval, rescan.degradedInterval))
    if options.scheduler and rescan.interval > 0 then
        options.scheduler.every(tick, function()
            local due = degradedState and rescan.degradedInterval or rescan.interval
            if (util.nowMs() - lastScanAt) < due * 1000 then return end
            manager.scan({ deep = scanCount % rescan.deepEvery == 0 })
        end, { name = "peripherals.rescan", owner = "peripheral_manager" })
    end

    log.info("peripheral manager ready (%d device(s), rescan every %ds / %ds when degraded)",
        manager.count(), rescan.interval, rescan.degradedInterval)
    return manager
end

function manager.shutdown()
    bus.offOwner("peripheral_manager")
    initialised = false
    lastScanAt, scanCount, degradedState = 0, 0, false
end

return manager

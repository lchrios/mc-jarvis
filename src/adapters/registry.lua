--- Adapter registry.
--
-- Modules ask for an adapter instead of poking a peripheral:
--
--   local storage = adapters.forAlias("meBridge", "ae2")
--   local cells   = adapters.allOfKind("energy")
--
-- Adapters are matched in registration order and the first match wins, so mod
-- specific adapters must register before the generic ones.

local util = require("core.util")
local logger = require("core.logger")

local log = logger.scoped("adapters")

local registry = {}

local adapters = {}     -- ordered list of adapter modules
local byId = {}
local peripherals = nil -- peripherals.manager, injected by core.app

--- Built-in adapters, most specific first.
registry.BUILTIN = {
    "adapters.ae2",
    "adapters.powah",
    "adapters.advanced_peripherals",
    "adapters.inventory",
    "adapters.energy",
    "adapters.fluid",
}

function registry.setPeripheralManager(manager) peripherals = manager end

--- Register an adapter module ({ id, matches(proxy), wrap(proxy) }).
function registry.register(adapter, position)
    if type(adapter) ~= "table" or type(adapter.wrap) ~= "function" then
        error("adapter needs a wrap(proxy) function", 2)
    end
    adapter.id = adapter.id or ("adapter" .. (#adapters + 1))

    if byId[adapter.id] then
        local index = util.indexOf(adapters, byId[adapter.id])
        if index then table.remove(adapters, index) end
    end

    if position then
        table.insert(adapters, position, adapter)
    else
        adapters[#adapters + 1] = adapter
    end
    byId[adapter.id] = adapter
    return adapter
end

--- Load the built-in adapters plus anything listed in configuration.
function registry.load(extra, requireFn)
    requireFn = requireFn or require
    adapters, byId = {}, {}

    local list = {}
    for _, name in ipairs(registry.BUILTIN) do list[#list + 1] = name end
    for _, name in ipairs(extra or {}) do list[#list + 1] = name end

    for _, name in ipairs(list) do
        local ok, adapter = pcall(requireFn, name)
        if ok and type(adapter) == "table" then
            registry.register(adapter)
        else
            log.error("cannot load adapter '%s': %s", name, tostring(adapter))
        end
    end

    log.info("loaded %d adapter(s)", #adapters)
    return registry.ids()
end

function registry.ids()
    local ids = {}
    for _, adapter in ipairs(adapters) do ids[#ids + 1] = adapter.id end
    return ids
end

function registry.get(id) return byId[id] end

--- Best adapter for a peripheral proxy, or nil.
function registry.forProxy(proxy, preferredId)
    if not proxy then return nil end

    if preferredId then
        local adapter = byId[preferredId]
        if adapter then
            local ok, wrapped = pcall(adapter.wrap, proxy)
            if ok and wrapped then return wrapped, adapter.id end
            log.debug("adapter '%s' could not wrap %s", preferredId, tostring(proxy))
            return nil
        end
    end

    for _, adapter in ipairs(adapters) do
        local matches = true
        if type(adapter.matches) == "function" then
            local ok, result = pcall(adapter.matches, proxy)
            matches = ok and result == true
        end
        if matches then
            local ok, wrapped = pcall(adapter.wrap, proxy)
            if ok and wrapped then return wrapped, adapter.id end
        end
    end
    return nil
end

--- Adapter for a peripheral alias registered with the peripheral manager.
function registry.forAlias(alias, preferredId)
    if not peripherals then return nil end
    return registry.forProxy(peripherals.get(alias), preferredId)
end

--- Adapter for an exact peripheral name.
function registry.forName(name, preferredId)
    if not peripherals then return nil end
    return registry.forProxy(peripherals.getByName(name), preferredId)
end

--- Every connected peripheral that a given adapter can wrap.
function registry.allOfKind(adapterId)
    local adapter = byId[adapterId]
    if not adapter or not peripherals then return {} end

    local result = {}
    for _, name in ipairs(peripherals.names()) do
        local proxy = peripherals.getByName(name)
        local matches = true
        if type(adapter.matches) == "function" then
            local ok, value = pcall(adapter.matches, proxy)
            matches = ok and value == true
        end
        if matches then
            local ok, wrapped = pcall(adapter.wrap, proxy)
            if ok and wrapped then result[#result + 1] = wrapped end
        end
    end
    return result
end

return registry

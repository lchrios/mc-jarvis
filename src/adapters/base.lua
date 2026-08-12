--- Shared helpers for adapters.
--
-- An adapter translates one external peripheral API (ME Bridge, Powah cell,
-- a vanilla chest, ...) into BaseOS' internal vocabulary. Rules:
--
--   * never assume a method exists - probe with `has`
--   * never let a peripheral error escape - use `call`
--   * always return internal structures, never the mod's raw tables
--
-- Adapters are created through `adapters.registry`.

local util = require("core.util")
local logger = require("core.logger")

local log = logger.scoped("adapters")

local base = {}

--- True when the proxy exposes `method`.
function base.has(proxy, method)
    if not proxy then return false end
    if type(proxy.hasMethod) == "function" then return proxy.hasMethod(method) end
    return type(proxy[method]) == "function"
end

--- True when the proxy exposes every listed method.
function base.hasAll(proxy, methods)
    for _, method in ipairs(methods) do
        if not base.has(proxy, method) then return false end
    end
    return true
end

--- First method name from `candidates` that the proxy implements.
-- Mods rename methods between versions; this keeps adapters version tolerant.
function base.pick(proxy, candidates)
    for _, method in ipairs(candidates) do
        if base.has(proxy, method) then return method end
    end
    return nil
end

--- Protected call. Returns nil (and logs at debug level) on failure.
function base.call(proxy, method, ...)
    if not base.has(proxy, method) then return nil, "missing method " .. tostring(method) end
    if type(proxy.call) == "function" then
        return proxy.call(method, ...)
    end
    local results = table.pack(pcall(proxy[method], ...))
    if not results[1] then
        log.debug("call %s failed: %s", tostring(method), tostring(results[2]))
        return nil, tostring(results[2])
    end
    return table.unpack(results, 2, results.n)
end

--- Call the first available method from a candidate list.
function base.callAny(proxy, candidates, ...)
    local method = base.pick(proxy, candidates)
    if not method then return nil, "no compatible method" end
    return base.call(proxy, method, ...)
end

--- Numeric result or `fallback`.
function base.number(value, fallback)
    if type(value) == "number" then return value end
    local converted = tonumber(value)
    if converted then return converted end
    return fallback
end

--- Standard shape every energy-ish adapter returns.
function base.energyReading(stored, capacity, extra)
    stored = base.number(stored, 0)
    capacity = base.number(capacity, 0)
    local reading = {
        stored = stored,
        capacity = capacity,
        percentage = capacity > 0 and util.clamp(stored / capacity, 0, 1) or 0,
        unit = "FE",
    }
    for key, value in pairs(extra or {}) do reading[key] = value end
    return reading
end

--- Standard shape for item stacks.
function base.itemStack(raw)
    if type(raw) ~= "table" then return nil end
    return {
        name = raw.name or raw.technicalName or raw.id or "unknown",
        displayName = raw.displayName or raw.label or raw.name,
        count = base.number(raw.count or raw.amount or raw.size, 0),
        nbt = raw.nbt,
        fingerprint = raw.fingerprint,
        craftable = raw.isCraftable or raw.craftable or false,
    }
end

--- Standard shape for fluids.
function base.fluidStack(raw)
    if type(raw) ~= "table" then return nil end
    return {
        name = raw.name or raw.fluid or raw.id or "unknown",
        displayName = raw.displayName or raw.name,
        amount = base.number(raw.amount or raw.count, 0),
        unit = "mB",
    }
end

return base

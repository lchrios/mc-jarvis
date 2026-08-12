--- Powah adapter (reactors, magmators, thermo generators, energy cells).
--
-- STATUS: unverified. Powah blocks are reachable through the CC:Tweaked
-- `energy_storage` capability, which `adapters.energy` already covers; this
-- adapter only adds the extras Powah exposes on top of it (fuel, temperature,
-- generation rate). Every extra is optional and returns nil when absent.
--
-- Confirm with `peripheral.getMethods(name)` in game and extend the candidate
-- lists below - do not guess new method names into the modules.

local base = require("adapters.base")
local energy = require("adapters.energy")

local powah = {}

powah.id = "powah"
powah.label = "Powah"

local GENERATION_METHODS = { "getGenerationRate", "getEnergyGeneration", "getProduction" }
local FUEL_METHODS = { "getFuel", "getFuelStored", "getBurnTime" }
local FUEL_CAP_METHODS = { "getFuelCapacity", "getMaxFuel" }
local TEMPERATURE_METHODS = { "getTemperature", "getHeat" }
local ACTIVE_METHODS = { "isActive", "isRunning", "isBurning" }

--- Powah peripherals are named `powah:<block>`; fall back to a name check when
--- the type list does not say so.
function powah.matches(proxy)
    if not proxy then return false end
    for _, kind in ipairs(proxy.types and proxy.types() or {}) do
        if tostring(kind):find("powah", 1, true) then return true end
    end
    local name = proxy.name and proxy.name() or ""
    return tostring(name):find("powah", 1, true) ~= nil
end

function powah.wrap(proxy)
    local self = energy.wrap(proxy)
    self.kind = "powah"

    --- FE/t currently produced, or nil when the block does not report it.
    function self.generation()
        local method = base.pick(proxy, GENERATION_METHODS)
        if not method then return nil end
        return base.number(base.call(proxy, method), nil)
    end

    --- { amount, capacity, percentage } or nil.
    function self.fuel()
        local method = base.pick(proxy, FUEL_METHODS)
        if not method then return nil end
        local amount = base.number(base.call(proxy, method), 0)
        local capacity = base.number(base.callAny(proxy, FUEL_CAP_METHODS), 0)
        return {
            amount = amount,
            capacity = capacity,
            percentage = capacity > 0 and (amount / capacity) or 0,
        }
    end

    function self.temperature()
        local method = base.pick(proxy, TEMPERATURE_METHODS)
        if not method then return nil end
        return base.number(base.call(proxy, method), nil)
    end

    function self.isActive()
        local method = base.pick(proxy, ACTIVE_METHODS)
        if not method then return nil end
        return base.call(proxy, method) == true
    end

    --- Everything this block can actually tell us.
    function self.read()
        local reading = base.energyReading(self.stored(), self.capacity(), {
            rate = self.rate(),
            generation = self.generation(),
            temperature = self.temperature(),
            active = self.isActive(),
        })
        reading.fuel = self.fuel()
        return reading
    end

    return self
end

return powah

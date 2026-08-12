--- Generic energy storage adapter.
--
-- Covers the CC:Tweaked `energy_storage` generic peripheral (getEnergy /
-- getEnergyCapacity) which most Forge energy blocks expose, and the Advanced
-- Peripherals Energy Detector (getTransferRate).
--
-- Powah, Mekanism, Thermal and friends all surface through this as long as
-- they implement the generic capability; mod specific extras belong in their
-- own adapter file.

local base = require("adapters.base")

local energy = {}

energy.id = "energy"
energy.label = "Energy storage"

local STORED_METHODS = { "getEnergy", "getEnergyStored", "getStoredEnergy" }
local CAPACITY_METHODS = { "getEnergyCapacity", "getMaxEnergyStored", "getCapacity" }
local RATE_METHODS = { "getTransferRate", "getEnergyUsage", "getEnergyTransfer" }

function energy.matches(proxy)
    return base.pick(proxy, STORED_METHODS) ~= nil
end

function energy.wrap(proxy)
    local self = { proxy = proxy, kind = "energy" }

    function self.name() return proxy.name and proxy.name() or "?" end

    function self.stored()
        return base.number(base.callAny(proxy, STORED_METHODS), 0)
    end

    function self.capacity()
        return base.number(base.callAny(proxy, CAPACITY_METHODS), 0)
    end

    --- Instantaneous throughput when the peripheral reports one, else nil.
    function self.rate()
        local method = base.pick(proxy, RATE_METHODS)
        if not method then return nil end
        return base.number(base.call(proxy, method), nil)
    end

    --- { stored, capacity, percentage, rate, unit }
    function self.read()
        return base.energyReading(self.stored(), self.capacity(), { rate = self.rate() })
    end

    return self
end

return energy

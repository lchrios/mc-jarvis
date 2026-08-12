--- Generic tank adapter (CC:Tweaked `fluid_storage` generic peripheral).

local base = require("adapters.base")

local fluid = {}

fluid.id = "fluid"
fluid.label = "Fluid storage"

function fluid.matches(proxy)
    return base.has(proxy, "tanks")
end

function fluid.wrap(proxy)
    local self = { proxy = proxy, kind = "fluid" }

    function self.name() return proxy.name and proxy.name() or "?" end

    --- Normalised list of { name, displayName, amount, capacity, percentage }.
    function self.tanks()
        local raw = base.call(proxy, "tanks")
        local result = {}
        if type(raw) ~= "table" then return result end
        for index, tank in pairs(raw) do
            local entry = base.fluidStack(tank)
            if entry then
                entry.index = index
                entry.capacity = base.number(tank.capacity, 0)
                entry.percentage = entry.capacity > 0 and (entry.amount / entry.capacity) or 0
                result[#result + 1] = entry
            end
        end
        return result
    end

    --- Total millibuckets across every tank.
    function self.total()
        local total = 0
        for _, tank in ipairs(self.tanks()) do total = total + tank.amount end
        return total
    end

    function self.pushTo(targetName, limit, fluidName)
        return base.number(base.call(proxy, "pushFluid", targetName, limit, fluidName), 0)
    end

    return self
end

return fluid

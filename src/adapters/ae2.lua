--- Applied Energistics 2 / Refined Storage bridge adapter.
--
-- STATUS: capability probed, not yet verified in game.
-- Advanced Peripherals renames bridge methods between versions, so every call
-- goes through a candidate list and returns nil when nothing matches. Confirm
-- the real method names in game (`peripheral.getMethods`) before relying on a
-- reading, and tighten the lists here once verified.

local base = require("adapters.base")

local ae2 = {}

ae2.id = "ae2"
ae2.label = "ME / RS Bridge"

local ITEM_METHODS = { "listItems", "getItems", "items" }
local FLUID_METHODS = { "listFluids", "getFluids", "fluids" }
local CRAFTABLE_METHODS = { "listCraftableItems", "getCraftableItems" }
local ENERGY_METHODS = { "getEnergyStorage", "getStoredEnergy", "getEnergy" }
local ENERGY_CAP_METHODS = { "getMaxEnergyStorage", "getEnergyCapacity" }
local USAGE_METHODS = { "getEnergyUsage", "getAverageEnergyUsage" }
local CRAFT_METHODS = { "craftItem", "requestCrafting", "craft" }
local IS_CRAFTING_METHODS = { "isItemCrafting", "isCrafting" }
local CELLS_METHODS = { "listCells", "getCells" }
local ITEM_QUERY_METHODS = { "getItem", "findItem" }

--- A bridge is anything that can list a whole storage network.
function ae2.matches(proxy)
    if proxy.hasType and (proxy.hasType("meBridge") or proxy.hasType("rsBridge")) then
        return true
    end
    return base.pick(proxy, ITEM_METHODS) ~= nil and base.pick(proxy, ENERGY_METHODS) ~= nil
end

function ae2.wrap(proxy)
    local self = { proxy = proxy, kind = "ae2" }

    function self.name() return proxy.name and proxy.name() or "?" end

    function self.isRefinedStorage()
        return proxy.hasType and proxy.hasType("rsBridge") or false
    end

    --- Normalised item list, or nil when the bridge cannot be queried.
    function self.items()
        local raw = base.callAny(proxy, ITEM_METHODS)
        if type(raw) ~= "table" then return nil end
        local result = {}
        for _, stack in ipairs(raw) do
            local item = base.itemStack(stack)
            if item then result[#result + 1] = item end
        end
        return result
    end

    function self.craftableItems()
        local raw = base.callAny(proxy, CRAFTABLE_METHODS)
        if type(raw) ~= "table" then return nil end
        local result = {}
        for _, stack in ipairs(raw) do
            local item = base.itemStack(stack)
            if item then result[#result + 1] = item end
        end
        return result
    end

    function self.fluids()
        local raw = base.callAny(proxy, FLUID_METHODS)
        if type(raw) ~= "table" then return nil end
        local result = {}
        for _, stack in ipairs(raw) do
            local entry = base.fluidStack(stack)
            if entry then result[#result + 1] = entry end
        end
        return result
    end

    --- Look one item up by its registry name, e.g. "minecraft:iron_ingot".
    function self.findItem(name)
        local raw = base.callAny(proxy, ITEM_QUERY_METHODS, { name = name })
        return base.itemStack(raw)
    end

    --- Network energy, in the bridge's own unit.
    function self.energy()
        local stored = base.callAny(proxy, ENERGY_METHODS)
        if stored == nil then return nil end
        return base.energyReading(stored, base.callAny(proxy, ENERGY_CAP_METHODS), {
            usage = base.number(base.callAny(proxy, USAGE_METHODS), nil),
        })
    end

    --- Storage cell summary when the bridge exposes it.
    function self.cells()
        local raw = base.callAny(proxy, CELLS_METHODS)
        return type(raw) == "table" and raw or nil
    end

    --- Request autocrafting. Returns true when the bridge accepted the job.
    function self.requestCraft(name, count)
        local result = base.callAny(proxy, CRAFT_METHODS, { name = name, count = count or 1 })
        return result == true or (type(result) == "table" and result.status ~= nil)
    end

    function self.isCrafting(name)
        return base.callAny(proxy, IS_CRAFTING_METHODS, { name = name }) == true
    end

    --- Which of the optional capabilities this bridge actually has.
    function self.capabilities()
        return {
            items = base.pick(proxy, ITEM_METHODS) ~= nil,
            fluids = base.pick(proxy, FLUID_METHODS) ~= nil,
            craftables = base.pick(proxy, CRAFTABLE_METHODS) ~= nil,
            energy = base.pick(proxy, ENERGY_METHODS) ~= nil,
            crafting = base.pick(proxy, CRAFT_METHODS) ~= nil,
            cells = base.pick(proxy, CELLS_METHODS) ~= nil,
        }
    end

    return self
end

return ae2

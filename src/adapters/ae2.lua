--- Applied Energistics 2 / Refined Storage bridge adapter.
--
-- VERIFIED against AdvancedPeripherals-1.21.1-0.7.62b: method names come from
-- the mod jar's `@LuaFunction` annotations. Both bridges expose the same
-- surface, so one wrapper serves ME and RS alike.
--
-- The earlier guesses here were wrong in a way that would have failed quietly:
-- the methods are `getItems` / `getFluids` / `getCraftableItems`, not the
-- `listX` names, and the type ids are `me_bridge` / `rs_bridge` in snake_case.

local base = require("adapters.base")

local ae2 = {}

ae2.id = "ae2"
ae2.label = "ME / RS Bridge"

local BRIDGE_TYPES = {
    me_bridge = "me", rs_bridge = "rs",
    -- camelCase spellings from older versions.
    meBridge = "me", rsBridge = "rs",
}

local function bridgeFlavour(proxy)
    if not proxy or not proxy.types then return nil end
    for _, kind in ipairs(proxy.types()) do
        if BRIDGE_TYPES[kind] then return BRIDGE_TYPES[kind] end
    end
    return nil
end

--- A bridge is anything that can list a whole storage network.
function ae2.matches(proxy)
    if bridgeFlavour(proxy) then return true end
    -- Fall back to the capability, in case a fork renames the type.
    return base.has(proxy, "getItems") and base.has(proxy, "getStoredEnergy")
end

function ae2.wrap(proxy)
    local self = { proxy = proxy, kind = "ae2" }

    function self.name() return proxy.name and proxy.name() or "?" end

    function self.flavour() return bridgeFlavour(proxy) or "unknown" end

    function self.isRefinedStorage() return bridgeFlavour(proxy) == "rs" end

    ------------------------------------------------------------------ health

    --- Is the bridge actually wired into a network? A disconnected bridge
    --- answers every query with nothing, which reads as "empty base".
    function self.isConnected()
        local connected = base.call(proxy, "isConnected")
        if connected ~= nil then return connected == true end
        return base.call(proxy, "isOnline") == true
    end

    ------------------------------------------------------------------ contents

    local function stackList(method, ...)
        local raw = base.call(proxy, method, ...)
        if type(raw) ~= "table" then return nil end
        local result = {}
        for _, stack in ipairs(raw) do
            local item = base.itemStack(stack)
            if item then result[#result + 1] = item end
        end
        return result
    end

    function self.items() return stackList("getItems") end
    function self.craftableItems() return stackList("getCraftableItems") end

    function self.fluids()
        local raw = base.call(proxy, "getFluids")
        if type(raw) ~= "table" then return nil end
        local result = {}
        for _, stack in ipairs(raw) do
            local entry = base.fluidStack(stack)
            if entry then result[#result + 1] = entry end
        end
        return result
    end

    function self.chemicals()
        local raw = base.call(proxy, "getChemicals")
        return type(raw) == "table" and raw or nil
    end

    --- One item by registry name, e.g. "minecraft:iron_ingot".
    function self.findItem(name)
        return base.itemStack(base.call(proxy, "getItem", { name = name }))
    end

    ------------------------------------------------------------------ capacity

    --- Bytes, not item counts: this is what fills up and stops a base working.
    function self.itemStorage()
        local total = base.number(base.call(proxy, "getTotalItemStorage"), nil)
        if not total then return nil end
        local used = base.number(base.call(proxy, "getUsedItemStorage"), 0)
        return {
            total = total,
            used = used,
            available = base.number(base.call(proxy, "getAvailableItemStorage"), total - used),
            percentage = total > 0 and (used / total) or 0,
        }
    end

    function self.fluidStorage()
        local total = base.number(base.call(proxy, "getTotalFluidStorage"), nil)
        if not total then return nil end
        local used = base.number(base.call(proxy, "getUsedFluidStorage"), 0)
        return {
            total = total, used = used,
            percentage = total > 0 and (used / total) or 0,
        }
    end

    function self.cells()
        local raw = base.call(proxy, "getCells")
        return type(raw) == "table" and raw or nil
    end

    ------------------------------------------------------------------ energy

    function self.energy()
        local stored = base.call(proxy, "getStoredEnergy")
        if stored == nil then return nil end
        return base.energyReading(stored, base.call(proxy, "getEnergyCapacity"), {
            usage = base.number(base.call(proxy, "getEnergyUsage"), nil),
            input = base.number(base.call(proxy, "getAverageEnergyInput"), nil),
        })
    end

    ------------------------------------------------------------------ crafting

    --- Ask the network to craft something. Returns true when it was accepted.
    function self.requestCraft(name, count)
        local result = base.call(proxy, "craftItem", { name = name, count = count or 1 })
        return result == true or (type(result) == "table" and result.status ~= nil)
    end

    function self.isCrafting(name)
        return base.call(proxy, "isCrafting", { name = name }) == true
    end

    function self.isCraftable(name)
        return base.call(proxy, "isCraftable", { name = name }) == true
    end

    function self.craftingTasks()
        local raw = base.call(proxy, "getCraftingTasks")
        return type(raw) == "table" and raw or nil
    end

    function self.cancelCrafting()
        return base.call(proxy, "cancelCraftingTasks") ~= nil
    end

    ------------------------------------------------------------------ probing

    --- Which of the optional capabilities this bridge actually has.
    function self.capabilities()
        return {
            items = base.has(proxy, "getItems"),
            fluids = base.has(proxy, "getFluids"),
            chemicals = base.has(proxy, "getChemicals"),
            craftables = base.has(proxy, "getCraftableItems"),
            energy = base.has(proxy, "getStoredEnergy"),
            crafting = base.has(proxy, "craftItem"),
            cells = base.has(proxy, "getCells"),
            capacity = base.has(proxy, "getTotalItemStorage"),
        }
    end

    return self
end

return ae2

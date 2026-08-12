--- Generic inventory adapter.
--
-- Works with anything exposing the CC:Tweaked `inventory` generic peripheral:
-- chests, barrels, drawers, machine slots, most modded containers.
-- Verified surface: list, size, getItemDetail, pushItems, pullItems.

local base = require("adapters.base")

local inventory = {}

inventory.id = "inventory"
inventory.label = "Inventory"

--- Does this peripheral look like an inventory?
function inventory.matches(proxy)
    return base.has(proxy, "list") and base.has(proxy, "size")
end

--- Build an adapter instance around a peripheral proxy.
function inventory.wrap(proxy)
    local self = { proxy = proxy, kind = "inventory" }

    function self.name() return proxy.name and proxy.name() or "?" end

    function self.slots()
        return base.number(base.call(proxy, "size"), 0)
    end

    --- Item stacks by slot, normalised.
    function self.items()
        local raw = base.call(proxy, "list")
        local result = {}
        if type(raw) ~= "table" then return result end
        for slot, stack in pairs(raw) do
            local item = base.itemStack(stack)
            if item then
                item.slot = slot
                result[#result + 1] = item
            end
        end
        table.sort(result, function(a, b) return (a.slot or 0) < (b.slot or 0) end)
        return result
    end

    --- Total item count across every slot.
    function self.totalItems()
        local total = 0
        for _, item in ipairs(self.items()) do total = total + item.count end
        return total
    end

    --- Rough fill level 0..1 based on occupied slots.
    function self.fillLevel()
        local slots = self.slots()
        if slots == 0 then return 0 end
        local raw = base.call(proxy, "list")
        if type(raw) ~= "table" then return 0 end
        local used = 0
        for _ in pairs(raw) do used = used + 1 end
        return used / slots
    end

    function self.detail(slot)
        return base.itemStack(base.call(proxy, "getItemDetail", slot))
    end

    --- Move items to another inventory (by peripheral name).
    function self.pushTo(targetName, slot, count, targetSlot)
        return base.number(base.call(proxy, "pushItems", targetName, slot, count, targetSlot), 0)
    end

    function self.pullFrom(sourceName, slot, count, targetSlot)
        return base.number(base.call(proxy, "pullItems", sourceName, slot, count, targetSlot), 0)
    end

    return self
end

return inventory

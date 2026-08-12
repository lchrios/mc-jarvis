--- Storage module.
--
-- Prefers a storage network bridge (AE2 ME Bridge / Refined Storage) and falls
-- back to counting plain inventories. Everything goes through adapters, so the
-- module has no idea which mod is installed.
--
-- The bridge readings are marked unverified in `adapters.ae2`; until they are
-- confirmed in game this module simply reports what it managed to read and
-- stays `unavailable` when it read nothing.

local util = require("core.util")

local storage = {}

storage.id = "storage"
storage.name = "Storage"
storage.icon = "S"
storage.description = "Item storage network and local inventories"
storage.pollInterval = 5

function storage.setup(self, ctx)
    self.ctx = ctx
    self.bridge = nil
    self.itemTypes = 0
    self.totalItems = 0
    self.inventoryCount = 0
    self.fillLevel = nil
    self.energy = nil
end

local function readBridge(ctx)
    local bridges = ctx.adapters.allOfKind("ae2")
    return bridges[1]
end

local function readInventories(ctx)
    local inventories = ctx.adapters.allOfKind("inventory")
    local total, fill, counted = 0, 0, 0
    for _, adapter in ipairs(inventories) do
        total = total + adapter.totalItems()
        fill = fill + adapter.fillLevel()
        counted = counted + 1
    end
    return {
        count = counted,
        totalItems = total,
        fillLevel = counted > 0 and (fill / counted) or nil,
    }
end

function storage.poll(self)
    local ctx = self.ctx
    if not ctx then return end

    self.bridge = readBridge(ctx)

    if self.bridge then
        local items = self.bridge.items()
        if items then
            self.itemTypes = #items
            local total = 0
            for _, item in ipairs(items) do total = total + item.count end
            self.totalItems = total
        end
        self.energy = self.bridge.energy()
        self.capabilities = self.bridge.capabilities()
    end

    local inventories = readInventories(ctx)
    self.inventoryCount = inventories.count
    self.fillLevel = inventories.fillLevel
    if not self.bridge then
        self.totalItems = inventories.totalItems
        self.itemTypes = 0
    end
end

function storage.status(self)
    if self.bridge then return "running", "NETWORK" end
    if (self.inventoryCount or 0) > 0 then return "running", "LOCAL" end
    return "unavailable", "NO DEVICE"
end

function storage.metrics(self)
    local metrics = {
        { id = "items", label = "Items stored", value = self.totalItems or 0 },
        { id = "inventories", label = "Inventories", value = self.inventoryCount or 0 },
    }
    if self.bridge then
        metrics[#metrics + 1] = { id = "types", label = "Item types", value = self.itemTypes or 0 }
        if self.energy then
            metrics[#metrics + 1] = { id = "energy", label = "Network energy",
                value = self.energy.stored, unit = "FE" }
        end
    end
    if self.fillLevel then
        metrics[#metrics + 1] = { id = "fill", label = "Average fill",
            kind = "percent", value = self.fillLevel }
    end
    return metrics
end

function storage.tile(self)
    if not self.bridge and (self.inventoryCount or 0) == 0 then
        return { lines = { "no storage", "peripherals" } }
    end
    return {
        lines = {
            util.formatNumber(self.totalItems or 0) .. " items",
            self.bridge and (self.itemTypes .. " types") or (self.inventoryCount .. " inv."),
        },
        gauge = self.fillLevel,
    }
end

return storage

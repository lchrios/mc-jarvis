--- Storage module.
--
-- Prefers a storage network bridge (AE2 ME Bridge / Refined Storage) and falls
-- back to counting plain inventories. Everything goes through adapters, so the
-- module has no idea which mod is installed.
--
-- Bridge readings are verified against Advanced Peripherals 0.7.62b, including
-- the byte capacity of the network - which is what actually fills up and stops
-- a base working, unlike the item count.

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

--- Every plain inventory, one entry each, plus the totals across them.
--
-- One `list` call per inventory: `totalItems` and `fillLevel` each make their
-- own, and on a wall of barrels that doubled the cost of every poll for
-- numbers that come out of the same read.
local function readInventories(ctx)
    local devices = {}
    local total, fill, counted = 0, 0, 0

    for _, adapter in ipairs(ctx.adapters.allOfKind("inventory")) do
        local items = adapter.items()
        local slots = adapter.slots()

        local count = 0
        for _, item in ipairs(items) do count = count + item.count end

        local used = #items
        local level = slots > 0 and (used / slots) or 0

        devices[#devices + 1] = {
            name = adapter.name(),
            items = count,
            slots = slots,
            used = used,
            fill = level,
        }

        total = total + count
        fill = fill + level
        counted = counted + 1
    end

    table.sort(devices, function(a, b) return a.name < b.name end)

    return {
        count = counted,
        totalItems = total,
        fillLevel = counted > 0 and (fill / counted) or nil,
        devices = devices,
    }
end

function storage.poll(self)
    local ctx = self.ctx
    if not ctx then return end

    self.bridge = readBridge(ctx)

    if self.bridge then
        self.connected = self.bridge.isConnected()
        self.bridgeName = self.bridge.name()
        self.bridgeFlavour = self.bridge.flavour()

        local items = self.bridge.items()
        if items then
            self.itemTypes = #items
            local total = 0
            for _, item in ipairs(items) do total = total + item.count end
            self.totalItems = total
        end
        self.energy = self.bridge.energy()
        self.bytes = self.bridge.itemStorage()
        self.capabilities = self.bridge.capabilities()

        -- Cells filling up is worth a warning long before they are full.
        if self.bytes and self.bytes.total > 0 then
            self.ctx.alerts.toggle(self.bytes.percentage >= 0.9, {
                id = "storage.cells_full",
                source = storage.id,
                severity = "warning",
                message = ("Storage cells %d%% full"):format(self.bytes.percentage * 100),
            })
        end
    end

    local inventories = readInventories(ctx)
    self.inventoryCount = inventories.count
    self.fillLevel = inventories.fillLevel
    self.devices = inventories.devices
    if not self.bridge then
        self.totalItems = inventories.totalItems
        self.itemTypes = 0
    end
end

function storage.status(self)
    if self.bridge and self.connected == false then return "error", "DISCONNECTED" end
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
        if self.bytes then
            metrics[#metrics + 1] = { id = "cells", label = "Cell space",
                kind = "percent", value = self.bytes.percentage }
            metrics[#metrics + 1] = { id = "bytes", label = "Bytes used",
                value = self.bytes.used }
        end
        if self.energy then
            metrics[#metrics + 1] = { id = "energy", label = "Network energy",
                value = self.energy.stored, unit = "FE" }
            if self.energy.usage then
                metrics[#metrics + 1] = { id = "draw", label = "Network draw",
                    value = self.energy.usage, unit = "FE/t" }
            end
        end
    end
    if self.fillLevel then
        metrics[#metrics + 1] = { id = "fill", label = "Average fill",
            kind = "percent", value = self.fillLevel }
    end
    return metrics
end

--- What the storage is made of: the bridge, then every plain inventory.
--
-- Formatted here because this is what travels to the master, which never
-- reads a remote peripheral. The bridge goes first: on a base that has one,
-- everything else is a barrel somebody left lying around.
function storage.detail(self)
    local rows = {}

    if self.bridge then
        local fields = {
            { label = "Kind", value = (self.bridgeFlavour or "?"):upper() .. " bridge" },
            { label = "Network", value = self.connected == false and "DISCONNECTED" or "connected" },
            { label = "Items", value = util.formatNumber(self.totalItems or 0) },
            { label = "Types", value = tostring(self.itemTypes or 0) },
        }
        if self.bytes then
            fields[#fields + 1] = { label = "Cells", value = ("%s / %s bytes"):format(
                util.formatNumber(self.bytes.used), util.formatNumber(self.bytes.total)) }
            fields[#fields + 1] = { label = "Free",
                value = util.formatNumber(self.bytes.available) .. " bytes" }
        end
        if self.energy then
            fields[#fields + 1] = { label = "Energy",
                value = util.formatNumber(self.energy.stored) .. " FE" }
            if self.energy.usage then
                fields[#fields + 1] = { label = "Draw",
                    value = util.formatNumber(self.energy.usage) .. " FE/t" }
            end
        end

        rows[#rows + 1] = {
            id = self.bridgeName or "bridge",
            name = self.bridgeName or "storage bridge",
            -- The cells filling up is what actually stops a base working, so
            -- that is the number this row carries.
            percent = self.bytes and self.bytes.percentage or nil,
            value = util.formatNumber(self.totalItems or 0),
            status = self.connected == false and "error" or "running",
            fields = fields,
        }
    end

    for _, device in ipairs(self.devices or {}) do
        rows[#rows + 1] = {
            id = device.name,
            name = device.name,
            percent = device.fill,
            value = util.formatNumber(device.items),
            fields = {
                { label = "Items", value = util.formatNumber(device.items) },
                { label = "Slots", value = ("%d / %d used"):format(device.used, device.slots) },
                { label = "Fill", value = util.formatPercent(device.fill) },
                { label = "Adapter", value = "inventory" },
            },
        }
    end

    return { columns = { "FILL", "ITEMS" }, rows = rows }
end

--- The same scrollable breakdown the power module uses.
function storage.detailScreen(params)
    return require("ui.screens.device_breakdown").new(params)
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

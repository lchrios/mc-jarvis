--- Connected peripherals and how the configured aliases resolved.

local class = require("core.class")
local util = require("core.util")
local bus = require("core.event_bus")
local Screen = require("ui.screen")
local List = require("ui.components.list")
local Modal = require("ui.components.modal")
local manager = require("peripherals.manager")
local theme = require("ui.theme")

local PeripheralsScreen = class(Screen)

function PeripheralsScreen:init(params)
    Screen.init(self, params)
    self.title = "Peripherals"
end

function PeripheralsScreen:onMount()
    local refresh = function() self:requestLayout() end
    self:onCleanup(bus.on("peripheral.attached", refresh, { owner = "screen:peripherals" }))
    self:onCleanup(bus.on("peripheral.detached", refresh, { owner = "screen:peripherals" }))
end

--- One row per alias, then one row per connected peripheral.
local function buildRows()
    local rows = {}

    local aliases = manager.aliasInfo()
    for _, alias in ipairs(util.sortedKeys(aliases)) do
        local entry = aliases[alias]
        rows[#rows + 1] = {
            kind = "alias",
            alias = alias,
            name = entry.name,
            connected = entry.connected,
            matcher = entry.matcher,
        }
    end

    local devices = manager.list()
    for _, name in ipairs(util.sortedKeys(devices)) do
        local device = devices[name]
        rows[#rows + 1] = {
            kind = "device",
            name = name,
            types = device.types,
            methodCount = device.methodCount,
        }
    end

    return rows
end

local function renderRow(row, width)
    if row.kind == "alias" then
        local target = row.connected and row.name or "(unbound)"
        return {
            text = util.padRight("@" .. row.alias, math.max(10, math.floor(width / 2))) .. target,
            fg = row.connected and theme.get("statusOk") or theme.get("statusWarn"),
        }
    end
    return {
        text = util.padRight(row.name, math.max(10, math.floor(width / 2)))
            .. table.concat(row.types or {}, ", "),
        fg = theme.get("text"),
    }
end

function PeripheralsScreen:showDetail(row)
    local lines
    if row.kind == "alias" then
        lines = "Alias: " .. row.alias
            .. "\nBound to: " .. (row.name or "nothing")
            .. "\nWants type: " .. tostring(row.matcher and row.matcher.type or "any")
    else
        lines = "Peripheral: " .. row.name
            .. "\nTypes: " .. table.concat(row.types or {}, ", ")
            .. "\nMethods: " .. tostring(row.methodCount)
    end

    self:openModal(Modal.new({
        title = row.kind == "alias" and "Alias" or "Peripheral",
        message = lines,
        buttons = { { label = "CLOSE" } },
        onClose = function() self:closeModal() end,
    }))
end

function PeripheralsScreen:onLayout(x, y, w, h)
    local width = w - 2
    self.list = List.new({
        items = buildRows(),
        renderItem = function(row) return renderRow(row, width) end,
        emptyText = "No peripherals detected.",
        onSelect = function(row) self:showDetail(row) end,
    })
    self.list:setBounds(x + 1, y, width, h)
    self:add(self.list)
end

function PeripheralsScreen:update()
    if self.list then self.list:setItems(buildRows()) end
end

return PeripheralsScreen

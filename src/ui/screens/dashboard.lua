--- Main screen: the base map.
--
-- Renders the zones declared in `config/layout.lua` as touchable tiles. Each
-- tile is bound to a module id and shows that module's live snapshot; touching
-- one opens its detail view.

local class = require("core.class")
local bus = require("core.event_bus")
local Screen = require("ui.screen")
local ZoneTile = require("ui.components.zone_tile")
local Label = require("ui.components.label")
local baseLayout = require("ui.base_layout")
local registry = require("modules.registry")
local config = require("core.config")

local Dashboard = class(Screen)

function Dashboard:init(params)
    Screen.init(self, params)
    self.title = config.get("system.name", "BASE CONTROL")
    self.tiles = {}
end

function Dashboard:onMount(context)
    -- The set of tiles depends on the registered modules, so rebuild when that
    -- changes. Value updates are handled in `update` without a relayout.
    local relayout = function() self:requestLayout() end
    self:onCleanup(bus.on("module.registered", relayout, { owner = "screen:dashboard" }))
    self:onCleanup(bus.on("module.unregistered", relayout, { owner = "screen:dashboard" }))
    self:onCleanup(bus.on("module.availability_changed", function() self:invalidate() end,
        { owner = "screen:dashboard" }))
end

function Dashboard:openZone(zone)
    if zone.screen then
        self.context.navigation.push(zone.screen, { zone = zone, moduleId = zone.module })
        return
    end
    if zone.module and registry.has(zone.module) then
        self.context.navigation.push("module_detail", { moduleId = zone.module, zone = zone })
        return
    end
    self.context.navigation.push("module_list", { highlight = zone.id })
end

--- Tile contents for a zone.
-- Zones bound to a module show its live snapshot; zones that only open a screen
-- (alerts, module list, ...) render as a plain, always available shortcut.
function Dashboard:snapshotFor(zone)
    if zone.module then
        return registry.snapshot(zone.module) or {
            available = false,
            status = "unknown",
            statusText = "NO MODULE",
        }
    end
    return { available = true, status = "idle", statusText = "" }
end

function Dashboard:onLayout(x, y, w, h)
    self.tiles = {}

    local layoutConfig = config.section("layout")
    local moduleIds = {}
    for _, record in ipairs(registry.all()) do moduleIds[#moduleIds + 1] = record.id end

    local placements = baseLayout.resolve(layoutConfig, { x = x, y = y, w = w, h = h }, moduleIds)

    if #placements == 0 then
        self:add(Label.new({
            text = "No zones configured and no modules registered.",
            x = x + 1, y = y + 1, w = w - 2, h = 2, wrap = true, fg = "textDim",
        }))
        return
    end

    for _, placement in ipairs(placements) do
        local zone = placement.zone
        local tile = ZoneTile.new({
            zone = zone,
            snapshot = self:snapshotFor(zone),
            onPress = function() self:openZone(zone) end,
        })
        tile:setBounds(placement.x, placement.y, placement.w, placement.h)
        self:add(tile)
        self.tiles[#self.tiles + 1] = tile
    end
end

function Dashboard:update()
    for _, tile in ipairs(self.tiles) do
        if tile.zone.module then tile:setSnapshot(self:snapshotFor(tile.zone)) end
    end
end

function Dashboard:onEvent(name)
    if name == "module.status_changed" then self:invalidate() end
end

return Dashboard

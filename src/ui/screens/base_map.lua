--- The base map: a plan of the base with its connections.
--
-- Renders the zones declared in `config/layout.lua` as touchable tiles. Each
-- tile is bound to a module id and shows that module's live snapshot; touching
-- one opens its detail view.

local class = require("core.class")
local bus = require("core.event_bus")
local Screen = require("ui.screen")
local ZoneTile = require("ui.components.zone_tile")
local LinkLayer = require("ui.components.link_layer")
local Label = require("ui.components.label")
local Button = require("ui.components.button")
local baseLayout = require("ui.base_layout")
local baseLinks = require("ui.base_links")
local registry = require("modules.registry")
local layoutStore = require("services.layout_store")

local BaseMap = class(Screen)

function BaseMap:init(params)
    Screen.init(self, params)
    self.title = "BASE MAP"
    self.tiles = {}
end

function BaseMap:onMount(context)
    -- The set of tiles depends on the registered modules, so rebuild when that
    -- changes. Value updates are handled in `update` without a relayout.
    local relayout = function() self:requestLayout() end
    self:onCleanup(bus.on("module.registered", relayout, { owner = "screen:map" }))
    self:onCleanup(bus.on("module.unregistered", relayout, { owner = "screen:map" }))
    self:onCleanup(bus.on("module.availability_changed", function() self:invalidate() end,
        { owner = "screen:map" }))
    -- The editor writes a new plan; pick it up without a reboot.
    self:onCleanup(bus.on("layout.changed", relayout, { owner = "screen:map" }))
end

function BaseMap:openZone(zone)
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
function BaseMap:snapshotFor(zone)
    if zone.module then
        return registry.snapshot(zone.module) or {
            available = false,
            status = "unknown",
            statusText = "NO MODULE",
        }
    end
    return { available = true, status = "idle", statusText = "" }
end

function BaseMap:onLayout(x, y, w, h)
    self.tiles = {}

    local layoutConfig = layoutStore.current()
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

    -- Pipework goes on first so the tiles drawn over it hide the line ends.
    self.placements = placements
    self.linkLayer = LinkLayer.new({
        segments = baseLinks.build(placements, function(zone) return self:snapshotFor(zone) end),
    })
    self.linkLayer:setBounds(x, y, w, h)
    self:add(self.linkLayer)

    -- An EDIT button in the corner: the editor belongs where the plan is.
    if h >= 6 and w >= 20 then
        local edit = Button.new({
            label = "EDIT",
            bracket = false,
            onPress = function() self.context.navigation.push("layout_editor", {}) end,
        })
        edit:setBounds(x + w - 8, y + h - 1, 8, 1)
        self.editButton = edit
    end

    for _, placement in ipairs(placements) do
        local zone = placement.zone
        local tile = ZoneTile.new({
            zone = zone,
            snapshot = self:snapshotFor(zone),
            compact = true,
            onPress = function() self:openZone(zone) end,
        })
        tile:setBounds(placement.x, placement.y, placement.w, placement.h)
        self:add(tile)
        self.tiles[#self.tiles + 1] = tile
    end

    -- Added last so it sits above any tile that reaches the corner.
    if self.editButton then self:add(self.editButton) end
end

function BaseMap:update()
    for _, tile in ipairs(self.tiles) do
        if tile.zone.module then tile:setSnapshot(self:snapshotFor(tile.zone)) end
    end

    -- Line colours track module state, so they are rebuilt with the tiles
    -- rather than only on relayout.
    if self.linkLayer and self.placements then
        self.linkLayer:setSegments(baseLinks.build(self.placements,
            function(zone) return self:snapshotFor(zone) end))
    end
end

function BaseMap:onEvent(name)
    if name == "module.status_changed" then self:invalidate() end
end

return BaseMap

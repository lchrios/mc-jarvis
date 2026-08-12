--- Where the base plan lives.
--
-- Two sources, in order:
--   data/layout.dat     written by the in-game editor, wins when present
--   config/layout.lua   hand written, with your comments intact
--
-- Keeping them separate means the editor never rewrites a file you author, and
-- the plan survives updates because the updater does not touch `data/`.
-- Deleting the override (or `reset`) falls back to config.

local util = require("core.util")
local logger = require("core.logger")
local bus = require("core.event_bus")
local config = require("core.config")
local persistence = require("services.persistence")

local log = logger.scoped("layout")

local layoutStore = {}

layoutStore.NAME = "layout"

local cached = nil

--- The layout in force right now.
function layoutStore.current()
    if cached then return cached end

    local override = persistence.load(layoutStore.NAME, nil)
    if type(override) == "table" and type(override.zones) == "table" then
        cached = override
        cached.source = "editor"
    else
        cached = util.deepCopy(config.section("layout"))
        cached.source = "config"
    end
    return cached
end

function layoutStore.hasOverride()
    return layoutStore.current().source == "editor"
end

--- Persist an edited layout and tell the screens to redraw.
function layoutStore.save(layout)
    if type(layout) ~= "table" or type(layout.zones) ~= "table" then
        return false, "a layout needs a zones list"
    end

    local record = util.deepCopy(layout)
    record.source = nil          -- derived, never stored
    record.savedAt = util.nowMs()

    local ok, err = persistence.save(layoutStore.NAME, record)
    if not ok then
        log.error("could not save the layout: %s", tostring(err))
        return false, err
    end

    cached = nil
    log.info("layout saved (%d zone(s))", #layout.zones)
    bus.emit("layout.changed", { zones = #layout.zones })
    return true
end

--- Throw the override away and go back to config/layout.lua.
function layoutStore.reset()
    persistence.delete(layoutStore.NAME)
    cached = nil
    bus.emit("layout.changed", { reset = true })
    return true
end

--- Forget the cached copy; the next read goes back to disk.
function layoutStore.invalidate() cached = nil end

---------------------------------------------------------------------------

--- Grid dimensions, with the defaults the resolver assumes.
function layoutStore.grid(layout)
    layout = layout or layoutStore.current()
    local grid = layout.grid or {}
    return grid.columns or 12, grid.rows or 6
end

--- Zone ids already on the plan.
function layoutStore.placedModules(layout)
    layout = layout or layoutStore.current()
    local placed = {}
    for _, zone in ipairs(layout.zones or {}) do
        if zone.module then placed[zone.module] = true end
    end
    return placed
end

--- First grid position with room for a new zone of this size, or nil.
function layoutStore.freeSlot(layout, colSpan, rowSpan)
    local columns, rows = layoutStore.grid(layout)
    colSpan, rowSpan = colSpan or 4, rowSpan or 3

    local occupied = {}
    for _, zone in ipairs(layout.zones or {}) do
        local col, row = zone.col or 1, zone.row or 1
        for c = col, col + (zone.colSpan or 1) - 1 do
            for r = row, row + (zone.rowSpan or 1) - 1 do
                occupied[c .. ":" .. r] = true
            end
        end
    end

    for row = 1, rows - rowSpan + 1 do
        for col = 1, columns - colSpan + 1 do
            local free = true
            for c = col, col + colSpan - 1 do
                for r = row, row + rowSpan - 1 do
                    if occupied[c .. ":" .. r] then free = false break end
                end
                if not free then break end
            end
            if free then return col, row end
        end
    end
    return nil
end

return layoutStore

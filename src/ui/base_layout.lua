--- Turns the declarative base layout from `config/layout.lua` into rectangles.
--
-- Two modes:
--   grid     - zones are placed on a virtual grid (col/row/colSpan/rowSpan) and
--              scale to whatever monitor is attached. This is the default.
--   absolute - zones use raw character coordinates (x/y/width/height). Use it
--              when you want a pixel exact plan of the base on a known monitor.
--
-- When no zones are configured an automatic grid is generated from the
-- registered modules, so a fresh install still shows something useful.

local util = require("core.util")

local baseLayout = {}

--- Space between tiles, horizontally and vertically.
--
-- `"auto"` widens the gap on big monitors, where a single character of
-- separation reads as "stuck together", and widens it further when the layout
-- declares links: a pipe needs room to be a line rather than just an arrowhead.
-- Rows are scarcer than columns, so the vertical gap stays smaller.
local function resolveGap(configured, area, hasLinks)
    if type(configured) == "number" then return configured, configured end

    local smallest = math.min(area.w, area.h)
    local base = smallest >= 34 and 2 or 1
    if not hasLinks then return base, base end

    return math.max(base, 3), math.max(base, 2)
end

local function declaresLinks(zones)
    for _, zone in ipairs(zones) do
        if type(zone.links) == "table" and #zone.links > 0 then return true end
    end
    return false
end

local function gridSpan(origin, total, index, span, count)
    local start = origin + math.floor((index - 1) * total / count)
    local finish = origin + math.floor((index - 1 + span) * total / count) - 1
    return start, math.max(start, finish) - start + 1
end

local function normaliseZone(zone, index)
    local normalised = util.deepCopy(zone)
    normalised.id = zone.id or zone.module or ("zone" .. index)
    normalised.label = zone.label or zone.name or normalised.id:upper()
    -- `module` stays nil unless declared: a zone may exist purely to open a
    -- screen, and guessing a module id from the zone id would mark it broken.
    normalised.module = zone.module
    return normalised
end

--- Auto layout used when config/layout.lua declares no zones.
-- @param moduleIds list of module ids
function baseLayout.autoZones(moduleIds, columns)
    columns = columns or 3
    local zones = {}
    for index, id in ipairs(moduleIds) do
        local col = ((index - 1) % columns) + 1
        local row = math.floor((index - 1) / columns) + 1
        zones[#zones + 1] = {
            id = id,
            module = id,
            label = id:gsub("_", " "):upper(),
            col = col,
            row = row,
            colSpan = 1,
            rowSpan = 1,
        }
    end
    return zones, columns, math.max(1, math.ceil(#moduleIds / columns))
end

--- Resolve zones into absolute rectangles inside the given content area.
-- @param layoutConfig table from config.section("layout")
-- @param area table { x, y, w, h }
-- @param fallbackModuleIds list used when no zones are configured
-- @return list of { zone = table, x, y, w, h }
function baseLayout.resolve(layoutConfig, area, fallbackModuleIds)
    layoutConfig = layoutConfig or {}
    local zones = layoutConfig.zones or {}
    local columns = (layoutConfig.grid and layoutConfig.grid.columns) or 12
    local rows = (layoutConfig.grid and layoutConfig.grid.rows) or 8
    local mode = layoutConfig.mode or "grid"

    if #zones == 0 then
        local generated, autoColumns, autoRows = baseLayout.autoZones(fallbackModuleIds or {}, 3)
        zones, columns, rows, mode = generated, autoColumns, autoRows, "grid"
    end

    -- Grid rows must at least cover the highest row actually used.
    if mode == "grid" then
        for _, zone in ipairs(zones) do
            local row = (zone.row or zone.y or 1) + ((zone.rowSpan or zone.height or 1) - 1)
            local col = (zone.col or zone.x or 1) + ((zone.colSpan or zone.width or 1) - 1)
            if row > rows then rows = row end
            if col > columns then columns = col end
        end
    end

    local gapX, gapY = resolveGap(layoutConfig.gap, area, declaresLinks(zones))

    local placed = {}
    for index, rawZone in ipairs(zones) do
        local zone = normaliseZone(rawZone, index)
        local rect

        if mode == "absolute" then
            rect = {
                x = area.x + (zone.x or 1) - 1,
                y = area.y + (zone.y or 1) - 1,
                w = zone.width or zone.w or 10,
                h = zone.height or zone.h or 5,
            }
        else
            local col = zone.col or zone.x or 1
            local row = zone.row or zone.y or 1
            local colSpan = zone.colSpan or zone.width or 1
            local rowSpan = zone.rowSpan or zone.height or 1

            local zx, zw = gridSpan(area.x, area.w, col, colSpan, columns)
            local zy, zh = gridSpan(area.y, area.h, row, rowSpan, rows)
            rect = { x = zx, y = zy, w = zw, h = zh }

            -- Breathing room between tiles, but never at the cost of legibility.
            if gapX > 0 and zw - gapX >= 4 then rect.w = zw - gapX end
            if gapY > 0 and zh - gapY >= 3 then rect.h = zh - gapY end
        end

        -- Clip to the content area so a bad config cannot draw off screen.
        rect.w = math.min(rect.w, area.x + area.w - rect.x)
        rect.h = math.min(rect.h, area.y + area.h - rect.y)

        if rect.w >= 3 and rect.h >= 1 then
            placed[#placed + 1] = {
                zone = zone,
                x = rect.x, y = rect.y, w = rect.w, h = rect.h,
            }
        end
    end

    return placed
end

return baseLayout

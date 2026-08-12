--- Routes the connections between zones on the base map.
--
-- Zones say what they connect to; where the line goes is worked out here, so
-- moving a room in `config/layout.lua` never means redrawing pipework by hand.
--
--   { id = "reactor", col = 1, row = 1,
--     links = { { to = "storage", kind = "energy" } } }
--
-- Routes are orthogonal: out of one box's edge, along, and into the other's.
-- The result is a flat list of cells, which the link layer paints underneath
-- the tiles so the ends tuck neatly under their borders.

local util = require("core.util")
local theme = require("ui.theme")

local baseLinks = {}

--- Flow states a connection can be in, worst first.
baseLinks.STATES = {
    broken = { color = "statusError", char = "x" },
    idle = { color = "statusIdle" },
    active = { color = "statusOk" },
    unknown = { color = "statusUnknown" },
}

local function centre(rect)
    return rect.x + math.floor(rect.w / 2), rect.y + math.floor(rect.h / 2)
end

---------------------------------------------------------------------------
-- Flow state
---------------------------------------------------------------------------

--- Is anything actually moving along this link?
-- Derived from the two endpoints so the common case needs no extra config; a
-- link may name a metric on its source to be more precise than "the module is
-- running".
function baseLinks.state(link, fromSnapshot, toSnapshot)
    if not fromSnapshot or not toSnapshot then return "unknown" end

    local function dead(snapshot)
        return snapshot.available == false
            or snapshot.status == "error"
            or snapshot.status == "unavailable"
    end

    if dead(fromSnapshot) or dead(toSnapshot) then return "broken" end

    if link.metric then
        for _, metric in ipairs(fromSnapshot.metrics or {}) do
            if metric.id == link.metric then
                local value = metric.percent or metric.value
                if type(value) == "number" then
                    return value > 0 and "active" or "idle"
                end
            end
        end
    end

    local status = fromSnapshot.status
    if status == "stopped" or status == "idle" or status == "paused" then return "idle" end
    if status == nil or status == "unknown" then return "unknown" end
    return "active"
end

---------------------------------------------------------------------------
-- Routing
---------------------------------------------------------------------------

local function horizontalRun(cells, x1, x2, y, char)
    local step = x1 <= x2 and 1 or -1
    for x = x1, x2, step do
        cells[#cells + 1] = { x = x, y = y, char = char }
    end
end

local function verticalRun(cells, y1, y2, x, char)
    local step = y1 <= y2 and 1 or -1
    for y = y1, y2, step do
        cells[#cells + 1] = { x = x, y = y, char = char }
    end
end

--- Route mostly-sideways: out of one side, across a midpoint column, back in.
local function routeHorizontal(from, to)
    local cells = {}
    local chars = theme.chars

    local leftRect, rightRect, reversed
    if from.x + from.w <= to.x then
        leftRect, rightRect, reversed = from, to, false
    else
        leftRect, rightRect, reversed = to, from, true
    end

    local startX = leftRect.x + leftRect.w
    local endX = rightRect.x - 1
    if endX < startX then return cells end

    local _, leftY = centre(leftRect)
    local _, rightY = centre(rightRect)
    local midX = startX + math.floor((endX - startX) / 2)

    horizontalRun(cells, startX, midX, leftY, chars.linkHorizontal)
    if leftY ~= rightY then
        verticalRun(cells, leftY, rightY, midX, chars.linkVertical)
        cells[#cells + 1] = { x = midX, y = leftY, char = chars.linkCorner }
        cells[#cells + 1] = { x = midX, y = rightY, char = chars.linkCorner }
    end
    horizontalRun(cells, midX, endX, rightY, chars.linkHorizontal)

    -- The arrow sits at the destination end, pointing into it.
    local arrow = reversed
        and { x = startX, y = leftY, char = chars.arrowLeft }
        or { x = endX, y = rightY, char = chars.arrowRight }
    return cells, arrow
end

--- Route mostly-vertically: out of the top or bottom, across a midpoint row.
local function routeVertical(from, to)
    local cells = {}
    local chars = theme.chars

    local topRect, bottomRect, reversed
    if from.y + from.h <= to.y then
        topRect, bottomRect, reversed = from, to, false
    else
        topRect, bottomRect, reversed = to, from, true
    end

    local startY = topRect.y + topRect.h
    local endY = bottomRect.y - 1
    if endY < startY then return cells end

    local topX = centre(topRect)
    local bottomX = centre(bottomRect)
    local midY = startY + math.floor((endY - startY) / 2)

    verticalRun(cells, startY, midY, topX, chars.linkVertical)
    if topX ~= bottomX then
        horizontalRun(cells, topX, bottomX, midY, chars.linkHorizontal)
        cells[#cells + 1] = { x = topX, y = midY, char = chars.linkCorner }
        cells[#cells + 1] = { x = bottomX, y = midY, char = chars.linkCorner }
    end
    verticalRun(cells, midY, endY, bottomX, chars.linkVertical)

    local arrow = reversed
        and { x = topX, y = startY, char = chars.arrowUp }
        or { x = bottomX, y = endY, char = chars.arrowDown }
    return cells, arrow
end

--- Cells for one connection between two rectangles.
function baseLinks.route(from, to)
    -- Whichever gap is real: two boxes side by side route sideways even when
    -- they are also slightly offset vertically.
    local sideBySide = (from.x + from.w <= to.x) or (to.x + to.w <= from.x)
    local stacked = (from.y + from.h <= to.y) or (to.y + to.h <= from.y)

    if sideBySide and stacked then
        -- Diagonal: pick the axis with more room so the elbow is visible.
        local fromX, fromY = centre(from)
        local toX, toY = centre(to)
        if math.abs(fromX - toX) >= math.abs(fromY - toY) then
            return routeHorizontal(from, to)
        end
        return routeVertical(from, to)
    end
    if sideBySide then return routeHorizontal(from, to) end
    if stacked then return routeVertical(from, to) end

    -- Overlapping boxes: nothing sensible to draw.
    return {}
end

---------------------------------------------------------------------------
-- Building the layer
---------------------------------------------------------------------------

--- Normalise a link declaration: "storage" or { to = "storage", kind = ... }.
local function normalise(link)
    if type(link) == "string" then return { to = link } end
    if type(link) == "table" and link.to then return link end
    return nil
end

--- Every link segment for a laid-out map.
-- @param placements list from `ui.base_layout.resolve`
-- @param snapshotFor function(zone) -> snapshot, for flow state
-- @return list of { x, y, char, color, from, to, state }
function baseLinks.build(placements, snapshotFor)
    local byId = {}
    for _, placement in ipairs(placements) do
        byId[placement.zone.id] = placement
    end

    local segments = {}
    local seen = {}

    for _, placement in ipairs(placements) do
        local zone = placement.zone

        for _, rawLink in ipairs(zone.links or {}) do
            local link = normalise(rawLink)
            local target = link and byId[link.to]

            -- A link declared from both ends is still one pipe.
            local key = link and (zone.id < link.to
                and (zone.id .. ">" .. link.to)
                or (link.to .. ">" .. zone.id))

            if target and not seen[key] then
                seen[key] = true

                local cells, arrow = baseLinks.route(placement, target)
                local state = baseLinks.state(link,
                    snapshotFor and snapshotFor(zone) or nil,
                    snapshotFor and snapshotFor(target.zone) or nil)
                local color = baseLinks.STATES[state].color

                for _, cell in ipairs(cells) do
                    segments[#segments + 1] = {
                        x = cell.x, y = cell.y, char = cell.char,
                        color = color, state = state,
                        from = zone.id, to = link.to, kind = link.kind,
                    }
                end
                if arrow then
                    segments[#segments + 1] = {
                        x = arrow.x, y = arrow.y, char = arrow.char,
                        color = color, state = state,
                        from = zone.id, to = link.to, kind = link.kind, arrow = true,
                    }
                end
            end
        end
    end

    return segments
end

return baseLinks

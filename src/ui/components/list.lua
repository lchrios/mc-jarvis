--- Scrollable list of rows.
--
-- Rows are plain values; the owner supplies `renderItem(item, index)` which
-- returns either a string or { text = ..., fg = ..., bg = ... }.
-- Touching a row calls `onSelect(item, index)`.

local class = require("core.class")
local util = require("core.util")
local Component = require("ui.component")
local Pager = require("ui.components.pager")
local theme = require("ui.theme")
local log = require("core.logger").scoped("ui")

local List = class(Component)

--- Rows reserved at the bottom for the pager buttons.
local PAGER_HEIGHT = Pager.HEIGHT

--- @param options table { items, renderItem, onSelect, emptyText, bg,
---                        showScrollbar, pager }
function List:init(options)
    Component.init(self, options)
    options = options or {}
    self.items = options.items or {}
    self.renderItem = options.renderItem
    self.onSelect = options.onSelect
    self.emptyText = options.emptyText or "(empty)"
    self.bg = options.bg or "background"
    self.selected = options.selected
    self.offset = 0
    self.showScrollbar = options.showScrollbar ~= false
    -- Monitors have no scroll wheel, so an overflowing list gets real buttons
    -- rather than a one-character scrollbar nobody can hit.
    self.pager = options.pager ~= false
    self.pagerControl = Pager.new({
        bg = self.bg,
        onUp = function() self:scroll(-self:visibleRows()) end,
        onDown = function() self:scroll(self:visibleRows()) end,
    })
    -- Exposed as children so the usual component traversal finds the buttons.
    self.children = { self.pagerControl }
end

--- True when the list is tall enough to give up rows for the pager and long
--- enough to need it.
function List:usesPager()
    return self.pager and self.h > PAGER_HEIGHT + 1 and #self.items > self.h
end

function List:visibleRows()
    return self:usesPager() and (self.h - PAGER_HEIGHT) or self.h
end

function List:maxOffset()
    return math.max(0, #self.items - self:visibleRows())
end

--- Position and configure the pager. Called before drawing and before handling
--- a touch, so the two never disagree about where it is.
-- @return boolean whether the pager is active
function List:syncPager()
    local active = self:usesPager()
    self.pagerControl:setVisible(active)
    if not active then return false end

    local rows = self:visibleRows()
    self.pagerControl.screen = self.screen
    self.pagerControl:setBounds(self.x, self.y + self.h - PAGER_HEIGHT, self.w, PAGER_HEIGHT)
    self.pagerControl:setRange(
        self.offset + 1,
        math.min(self.offset + rows, #self.items),
        #self.items,
        self.offset > 0,
        self.offset < self:maxOffset())
    return true
end

function List:setItems(items)
    self.items = items or {}
    self.offset = util.clamp(self.offset, 0, self:maxOffset())
    self:invalidate()
    return self
end

function List:scroll(delta)
    local previous = self.offset
    self.offset = util.clamp(self.offset + delta, 0, self:maxOffset())
    if self.offset ~= previous then self:invalidate() end
    return self.offset
end

function List:scrollToBottom()
    self.offset = self:maxOffset()
    return self
end

local function normaliseRow(rendered)
    if type(rendered) == "table" then return rendered end
    return { text = tostring(rendered) }
end

function List:draw(renderer)
    if not self.visible or self.w <= 0 or self.h <= 0 then return end

    renderer:fill(self.x, self.y, self.w, self.h, self.bg, " ")

    if #self.items == 0 then
        renderer:write(self.x, self.y, self:fitText(self.emptyText), "textDim", self.bg)
        return
    end

    local usePager = self:syncPager()
    local rows = self:visibleRows()
    -- The thin scrollbar is only a fallback for lists too short for a pager.
    local scrollbar = not usePager and self.showScrollbar and #self.items > rows
    local width = self.w - (scrollbar and 1 or 0)

    for row = 1, math.min(rows, #self.items - self.offset) do
        local index = row + self.offset
        local item = self.items[index]

        local rendered
        if type(self.renderItem) == "function" then
            local ok, result = pcall(self.renderItem, item, index)
            rendered = normaliseRow(ok and result or "<render error>")
        else
            rendered = normaliseRow(type(item) == "table" and (item.text or item.label or "?") or item)
        end

        local isSelected = self.selected ~= nil and self.selected == index
        local bg = rendered.bg or (isSelected and theme.get("accent") or self.bg)
        local fg = rendered.fg or (isSelected and theme.get("accentText") or "text")

        renderer:fill(self.x, self.y + row - 1, width, 1, bg, " ")
        renderer:write(self.x, self.y + row - 1, util.truncate(rendered.text, width), fg, bg)
    end

    if scrollbar then
        local barX = self.x + self.w - 1
        renderer:fill(barX, self.y, 1, rows, "surface", " ")
        local span = math.max(1, math.floor(rows * rows / #self.items))
        local maxOffset = self:maxOffset()
        local position = maxOffset > 0 and math.floor((rows - span) * self.offset / maxOffset) or 0
        renderer:fill(barX, self.y + position, 1, span, "accent", " ")
    end

    if usePager then self.pagerControl:draw(renderer) end
end

function List:onTouch(px, py)
    if self:syncPager() and self.pagerControl:handleTouch(px, py) then
        return true
    end

    local rows = self:visibleRows()
    local row = py - self.y + 1
    if row < 1 or row > rows then return false end

    -- Touching the scrollbar column pages up/down.
    if self.showScrollbar and not self:usesPager() and #self.items > rows
        and px == self.x + self.w - 1 then
        self:scroll(row <= math.floor(rows / 2) and -rows or rows)
        return true
    end

    local index = row + self.offset
    local item = self.items[index]
    if item == nil then return false end

    self.selected = index
    self:invalidate()

    if type(self.onSelect) == "function" then
        local ok, err = pcall(self.onSelect, item, index)
        if not ok then log.error("list select failed: %s", tostring(err)) end
        return true
    end
    return true
end

return List

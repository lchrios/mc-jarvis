--- Scrollable list of rows.
--
-- Rows are plain values; the owner supplies `renderItem(item, index)` which
-- returns either a string or { text = ..., fg = ..., bg = ... }.
-- Touching a row calls `onSelect(item, index)`.

local class = require("core.class")
local util = require("core.util")
local Component = require("ui.component")
local Button = require("ui.components.button")
local theme = require("ui.theme")
local log = require("core.logger").scoped("ui")

local List = class(Component)

--- Rows reserved at the bottom for the pager buttons.
local PAGER_HEIGHT = 3

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
    self.upButton = Button.new({
        label = theme.chars.arrowUp .. " UP",
        bracket = false,
        onPress = function() self:scroll(-self:visibleRows()) end,
    })
    self.downButton = Button.new({
        label = "DOWN " .. theme.chars.arrowDown,
        bracket = false,
        onPress = function() self:scroll(self:visibleRows()) end,
    })
    -- Exposed as children so the usual component traversal finds them.
    self.children = { self.upButton, self.downButton }
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

--- Up / position / down areas, derived without needing the renderer so touch
--- and draw always agree.
function List:pagerSlots()
    local third = math.floor(self.w / 3)
    return {
        { x = self.x, w = third },
        { x = self.x + third, w = self.w - 2 * third },
        { x = self.x + self.w - third, w = third },
    }
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

--- Position and enable the pager buttons. Called before drawing and before
--- handling a touch so the two never disagree about where they are.
-- @return boolean whether the pager is active
function List:syncPager()
    local active = self:usesPager()
    self.upButton:setVisible(active)
    self.downButton:setVisible(active)
    if not active then return false end

    local slots = self:pagerSlots()
    local top = self.y + self.h - PAGER_HEIGHT

    self.upButton.screen = self.screen
    self.downButton.screen = self.screen
    self.upButton:setBounds(slots[1].x, top, slots[1].w, PAGER_HEIGHT)
    self.downButton:setBounds(slots[3].x, top, slots[3].w, PAGER_HEIGHT)
    self.upButton:setEnabled(self.offset > 0)
    self.downButton:setEnabled(self.offset < self:maxOffset())
    return true
end

--- Big touch targets: [ ^ UP ]  9-16 / 23  [ DOWN v ]
function List:drawPager(renderer)
    local slots = self:pagerSlots()
    local top = self.y + self.h - PAGER_HEIGHT
    local rows = self:visibleRows()

    self.upButton:draw(renderer)
    self.downButton:draw(renderer)

    local first = self.offset + 1
    local last = math.min(self.offset + rows, #self.items)
    renderer:fill(slots[2].x, top, slots[2].w, PAGER_HEIGHT, self.bg, " ")
    renderer:writeCentered(slots[2].x, top + 1, slots[2].w,
        ("%d-%d / %d"):format(first, last, #self.items), "textDim", self.bg)
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

    if usePager then self:drawPager(renderer) end
end

function List:onTouch(px, py)
    if self:syncPager() and py >= self.y + self.h - PAGER_HEIGHT then
        -- The buttons own the outer thirds; the middle is just a readout.
        if self.upButton:handleTouch(px, py) then return true end
        if self.downButton:handleTouch(px, py) then return true end
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

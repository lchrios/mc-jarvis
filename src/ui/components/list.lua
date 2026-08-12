--- Scrollable list of rows.
--
-- Rows are plain values; the owner supplies `renderItem(item, index)` which
-- returns either a string or { text = ..., fg = ..., bg = ... }.
-- Touching a row calls `onSelect(item, index)`.

local class = require("core.class")
local util = require("core.util")
local Component = require("ui.component")
local theme = require("ui.theme")
local log = require("core.logger").scoped("ui")

local List = class(Component)

--- @param options table { items, renderItem, onSelect, emptyText, bg, showScrollbar }
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
end

function List:setItems(items)
    self.items = items or {}
    if self.offset > math.max(0, #self.items - self.h) then
        self.offset = math.max(0, #self.items - self.h)
    end
    self:invalidate()
    return self
end

function List:visibleRows()
    return self.h
end

function List:maxOffset()
    return math.max(0, #self.items - self:visibleRows())
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

    local scrollbar = self.showScrollbar and #self.items > self.h
    local width = self.w - (scrollbar and 1 or 0)

    for row = 1, math.min(self.h, #self.items - self.offset) do
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
        renderer:fill(barX, self.y, 1, self.h, "surface", " ")
        local span = math.max(1, math.floor(self.h * self.h / #self.items))
        local maxOffset = self:maxOffset()
        local position = maxOffset > 0 and math.floor((self.h - span) * self.offset / maxOffset) or 0
        renderer:fill(barX, self.y + position, 1, span, "accent", " ")
    end
end

function List:onTouch(px, py)
    local row = py - self.y + 1
    if row < 1 or row > self.h then return false end

    -- Touching the scrollbar column pages up/down.
    if self.showScrollbar and #self.items > self.h and px == self.x + self.w - 1 then
        self:scroll(row <= math.floor(self.h / 2) and -self.h or self.h)
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

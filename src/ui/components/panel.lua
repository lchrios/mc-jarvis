--- Container with an optional border and title.
--
-- Children are positioned in absolute coordinates; `Panel:contentBounds()`
-- gives a screen the usable area inside the border so it can lay them out.

local class = require("core.class")
local Component = require("ui.component")

local Panel = class(Component)

--- @param options table { title, border = bool, bg, fg, padding, onTouch }
function Panel:init(options)
    Component.init(self, options)
    options = options or {}
    self.title = options.title
    self.border = options.border ~= false
    self.bg = options.bg or "surface"
    self.fg = options.fg or "border"
    self.titleFg = options.titleFg or "text"
    self.padding = options.padding or 0
    self.fill = options.fill ~= false
    self.children = {}
    self.touchHandler = options.onTouch
end

function Panel:add(child)
    child.screen = self.screen
    self.children[#self.children + 1] = child
    return child
end

function Panel:clear()
    self.children = {}
    return self
end

--- Usable rectangle inside the border and padding.
function Panel:contentBounds()
    local inset = (self.border and 1 or 0) + self.padding
    return self.x + inset,
        self.y + inset,
        math.max(0, self.w - inset * 2),
        math.max(0, self.h - inset * 2)
end

function Panel:setTitle(title)
    self.title = title
    return self
end

function Panel:draw(renderer)
    if not self.visible or self.w <= 0 or self.h <= 0 then return end

    if self.border then
        renderer:box(self.x, self.y, self.w, self.h, {
            title = self.title,
            fg = self.fg,
            bg = self.bg,
            titleFg = self.titleFg,
            fill = self.fill and self.bg or nil,
        })
    elseif self.fill then
        renderer:fill(self.x, self.y, self.w, self.h, self.bg, " ")
        if self.title then
            renderer:write(self.x, self.y, self:fitText(self.title), self.titleFg, self.bg)
        end
    end

    for _, child in ipairs(self.children) do
        if child.visible then child:draw(renderer) end
    end
end

function Panel:handleTouch(px, py)
    if not self.visible or not self.enabled then return false end
    if not self:contains(px, py) then return false end

    -- Topmost child wins.
    for index = #self.children, 1, -1 do
        if self.children[index]:handleTouch(px, py) then return true end
    end

    if type(self.touchHandler) == "function" then
        return self.touchHandler(self, px, py) == true
    end
    return false
end

return Panel

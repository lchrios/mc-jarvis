--- Draws the pipework between zones on the base map.
--
-- Added to the screen before the tiles so the line ends disappear under their
-- borders; the layer itself never handles touches, the tiles own those.

local class = require("core.class")
local Component = require("ui.component")
local theme = require("ui.theme")

local LinkLayer = class(Component)

function LinkLayer:init(options)
    Component.init(self, options)
    options = options or {}
    self.segments = options.segments or {}
    self.bg = options.bg or "background"
end

function LinkLayer:setSegments(segments)
    self.segments = segments or {}
    self:invalidate()
    return self
end

function LinkLayer:draw(renderer)
    if not self.visible then return end
    for _, segment in ipairs(self.segments) do
        renderer:write(segment.x, segment.y, segment.char,
            theme.get(segment.color or "border"), self.bg)
    end
end

--- The layer is decoration; touches belong to whatever is drawn on top.
function LinkLayer:handleTouch()
    return false
end

return LinkLayer

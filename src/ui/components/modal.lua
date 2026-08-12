--- Centred dialog drawn on top of the current screen.
--
-- The screen owns the modal and forwards touches to it first; while a modal is
-- open the rest of the screen must not receive input.

local class = require("core.class")
local Component = require("ui.component")
local Button = require("ui.components.button")
local Label = require("ui.components.label")

local Modal = class(Component)

--- @param options table { title, message, buttons = { { label, style, onPress } }, onClose }
function Modal:init(options)
    Component.init(self, options)
    options = options or {}
    self.title = options.title or "Notice"
    self.message = options.message or ""
    self.onClose = options.onClose
    self.buttonSpecs = options.buttons or { { label = "OK" } }
    self.buttons = {}
    self.body = Label.new({ text = self.message, wrap = true, bg = "surface" })
end

function Modal:close()
    if type(self.onClose) == "function" then pcall(self.onClose, self) end
end

--- Position the dialog inside the given surface size.
function Modal:layout(surfaceWidth, surfaceHeight)
    local width = math.min(surfaceWidth - 4, math.max(24, #self.title + 8))
    local lines = Label.wrapText(self.message, width - 4)
    local height = math.min(surfaceHeight - 2, #lines + 6)

    self:setBounds(
        math.floor((surfaceWidth - width) / 2) + 1,
        math.floor((surfaceHeight - height) / 2) + 1,
        width, height)

    self.body:setBounds(self.x + 2, self.y + 2, self.w - 4, self.h - 5)

    self.buttons = {}
    local count = #self.buttonSpecs
    local slots = math.max(1, count)
    local slotWidth = math.floor((self.w - 4) / slots)
    for index, spec in ipairs(self.buttonSpecs) do
        local button = Button.new({
            label = spec.label or "OK",
            style = spec.style,
            onPress = function()
                if type(spec.onPress) == "function" then spec.onPress(self) end
                if spec.keepOpen ~= true then self:close() end
            end,
        })
        button.screen = self.screen
        button:setBounds(self.x + 2 + (index - 1) * slotWidth, self.y + self.h - 2, slotWidth - 1, 1)
        self.buttons[#self.buttons + 1] = button
    end
    return self
end

function Modal:draw(renderer)
    if not self.visible then return end

    renderer:box(self.x, self.y, self.w, self.h, {
        title = self.title,
        fg = "accent",
        bg = "surface",
        titleFg = "text",
        fill = "surface",
    })
    self.body:draw(renderer)
    for _, button in ipairs(self.buttons) do button:draw(renderer) end
end

function Modal:handleTouch(px, py)
    if not self.visible then return false end
    for _, button in ipairs(self.buttons) do
        if button:handleTouch(px, py) then return true end
    end
    -- Swallow every touch: the modal is exclusive while open.
    return true
end

return Modal

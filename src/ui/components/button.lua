--- Touchable button.
--
-- The button only reports that it was pressed; it never performs domain work
-- itself. Screens wire `onPress` to a module action.

local class = require("core.class")
local util = require("core.util")
local Component = require("ui.component")
local theme = require("ui.theme")
local log = require("core.logger").scoped("ui")

local Button = class(Component)

local STYLES = {
    default = { bg = "buttonBg", fg = "buttonText" },
    primary = { bg = "buttonActive", fg = "textInverse" },
    danger  = { bg = "buttonDangerBg", fg = "buttonDangerText" },
    ghost   = { bg = "background", fg = "text" },
}

--- @param options table { label, onPress, style, toggled, bracket }
function Button:init(options)
    Component.init(self, options)
    options = options or {}
    self.label = options.label or "OK"
    self.onPress = options.onPress
    self.style = options.style or "default"
    self.toggled = options.toggled == true
    self.bracket = options.bracket ~= false   -- draw [ LABEL ] on 1-row buttons
    self.h = options.h or 1
end

function Button:setLabel(label)
    label = tostring(label or "")
    if label ~= self.label then
        self.label = label
        self:invalidate()
    end
    return self
end

function Button:setStyle(style)
    self.style = style or "default"
    return self
end

--- Width needed to render the label comfortably.
function Button:preferredWidth()
    return #self.label + (self.bracket and 4 or 2)
end

function Button:colors()
    if not self.enabled then
        return theme.get("buttonDisabledBg"), theme.get("buttonDisabledText")
    end
    local style = STYLES[self.style] or STYLES.default
    if self.toggled then
        return theme.get("buttonActive"), theme.get("textInverse")
    end
    return theme.get(style.bg), theme.get(style.fg)
end

function Button:draw(renderer)
    if not self.visible or self.w <= 0 or self.h <= 0 then return end

    local bg, fg = self:colors()
    renderer:fill(self.x, self.y, self.w, self.h, bg, " ")

    local text = self.label
    if self.bracket and self.h == 1 and #text + 4 <= self.w then
        text = "[ " .. text .. " ]"
    end
    text = util.truncate(text, self.w)

    local row = self.y + math.floor((self.h - 1) / 2)
    renderer:writeCentered(self.x, row, self.w, text, fg, bg)
end

function Button:onTouch(px, py)
    if not self.enabled or type(self.onPress) ~= "function" then return false end
    local ok, err = pcall(self.onPress, self, px, py)
    if not ok then
        log.error("button '%s' handler failed: %s", tostring(self.label), tostring(err))
    end
    self:invalidate()
    return true
end

Button.STYLES = STYLES

return Button

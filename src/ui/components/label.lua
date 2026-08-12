--- Single line (optionally wrapped) text component.

local class = require("core.class")
local util = require("core.util")
local Component = require("ui.component")

local Label = class(Component)

--- @param options table { text, align = "left"|"center"|"right", fg, bg, wrap }
function Label:init(options)
    Component.init(self, options)
    options = options or {}
    self.text = options.text or ""
    self.align = options.align or "left"
    self.fg = options.fg or "text"
    self.bg = options.bg or "background"
    self.wrap = options.wrap == true
end

function Label:setText(text)
    text = tostring(text or "")
    if text ~= self.text then
        self.text = text
        self:invalidate()
    end
    return self
end

function Label:setColor(fg, bg)
    self.fg = fg or self.fg
    self.bg = bg or self.bg
    return self
end

--- Split text into lines that fit `width`, breaking on spaces where possible.
local function wrapText(text, width)
    local lines = {}
    if width < 1 then return lines end

    text = tostring(text or "")
    local cursor = 1

    while true do
        local newline = text:find("\n", cursor, true)
        local paragraph = newline and text:sub(cursor, newline - 1) or text:sub(cursor)

        if paragraph == "" then
            lines[#lines + 1] = ""
        end
        while #paragraph > 0 do
            if #paragraph <= width then
                lines[#lines + 1] = paragraph
                break
            end
            -- Position just after the last space that still fits.
            local cut = paragraph:sub(1, width + 1):match(".*%s()")
            if not cut or cut < 2 then cut = width + 1 end
            lines[#lines + 1] = (paragraph:sub(1, cut - 1):gsub("%s+$", ""))
            paragraph = (paragraph:sub(cut):gsub("^%s+", ""))
        end

        if not newline then break end
        cursor = newline + 1
    end

    return lines
end

function Label:draw(renderer)
    if not self.visible or self.w <= 0 or self.h <= 0 then return end

    local lines
    if self.wrap then
        lines = wrapText(self.text, self.w)
    else
        lines = { util.truncate(self.text, self.w) }
    end

    for index = 1, math.min(#lines, self.h) do
        local line = lines[index]
        local y = self.y + index - 1
        if self.align == "center" then
            renderer:writeCentered(self.x, y, self.w, line, self.fg, self.bg)
        elseif self.align == "right" then
            renderer:writeRight(self.x, y, self.w, line, self.fg, self.bg)
        else
            renderer:write(self.x, y, line, self.fg, self.bg)
        end
    end
end

Label.wrapText = wrapText

return Label

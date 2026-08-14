--- Drawing surface for a monitor or the computer terminal.
--
-- Wraps the target in a `window` so a whole frame can be composed off-screen
-- and flushed in one go (no flicker on big monitors). Every primitive clips to
-- the surface, so a component that overflows its area cannot throw.
--
--   local r = Renderer.new(monitorProxy)
--   r:beginFrame()
--   r:clear()
--   r:box(1, 1, r:width(), 3, { title = "BASE CONTROL" })
--   r:endFrame()

local class = require("core.class")
local util = require("core.util")
local theme = require("ui.theme")

local Renderer = class()

--- Unwrap a BaseOS peripheral proxy into the raw term-like object.
local function rawDevice(device)
    if type(device) == "table" and device.__isBaseOSProxy and device.raw then
        return device.raw() or device
    end
    return device
end

function Renderer:init(device, options)
    options = options or {}

    self.device = rawDevice(device)
    self.deviceName = options.name or "terminal"
    self.isMonitor = options.isMonitor == true

    if self.isMonitor and options.textScale and self.device.setTextScale then
        pcall(self.device.setTextScale, options.textScale)
    end

    local width, height = self.device.getSize()
    self.w, self.h = width, height

    -- Off-screen buffer. `window` is part of the CC standard library; fall back
    -- to drawing straight onto the device if it is somehow unavailable.
    if window and window.create then
        local ok, created = pcall(window.create, self.device, 1, 1, width, height, false)
        self.buffer = ok and created or self.device
        self.buffered = ok and created ~= nil
    else
        self.buffer = self.device
        self.buffered = false
    end

    self.colorCapable = true
    if self.device.isColour then
        local ok, value = pcall(self.device.isColour)
        if ok then self.colorCapable = value end
    end
end

---------------------------------------------------------------------------
-- Surface
---------------------------------------------------------------------------

function Renderer:size() return self.w, self.h end
function Renderer:width() return self.w end
function Renderer:height() return self.h end
function Renderer:supportsColor() return self.colorCapable end

--- Re-read the device size; returns true when it changed.
function Renderer:refreshSize()
    local ok, width, height = pcall(self.device.getSize)
    if not ok or not width then return false end
    if width == self.w and height == self.h then return false end

    self.w, self.h = width, height
    if self.buffered and self.buffer.reposition then
        pcall(self.buffer.reposition, 1, 1, width, height)
    end
    return true
end

function Renderer:beginFrame()
    if self.buffered and self.buffer.setVisible then
        pcall(self.buffer.setVisible, false)
    end
end

function Renderer:endFrame()
    if self.buffered and self.buffer.setVisible then
        pcall(self.buffer.setVisible, true)
        pcall(self.buffer.setVisible, false)
    end
    if self.buffer.setCursorBlink then pcall(self.buffer.setCursorBlink, false) end
end

---------------------------------------------------------------------------
-- Primitives
---------------------------------------------------------------------------

function Renderer:setColors(fg, bg)
    if fg ~= nil then pcall(self.buffer.setTextColor, theme.get(fg)) end
    if bg ~= nil then pcall(self.buffer.setBackgroundColor, theme.get(bg)) end
end

function Renderer:clear(bg)
    self:setColors("text", bg or "background")
    pcall(self.buffer.clear)
    pcall(self.buffer.setCursorPos, 1, 1)
end

--- Write text at an absolute position, clipped to the surface.
function Renderer:write(x, y, text, fg, bg)
    -- The last gate before the terminal. Most text arrives already folded by
    -- `util.truncate`/`padRight`, but a module that writes its own label should
    -- not be able to put a two-byte character on a one-glyph-per-byte screen.
    text = util.ascii(text)
    if text == "" then return end
    y = math.floor(y)
    x = math.floor(x)
    if y < 1 or y > self.h then return end

    if x < 1 then
        text = text:sub(2 - x)
        x = 1
    end
    if x > self.w then return end
    if x + #text - 1 > self.w then
        text = text:sub(1, self.w - x + 1)
    end
    if text == "" then return end

    self:setColors(fg or "text", bg or "background")
    pcall(self.buffer.setCursorPos, x, y)
    pcall(self.buffer.write, text)
end

--- Write text centred inside [x, x+width-1].
function Renderer:writeCentered(x, y, width, text, fg, bg)
    text = util.truncate(text, width)
    local offset = math.floor((width - #text) / 2)
    self:write(x + offset, y, text, fg, bg)
end

function Renderer:writeRight(x, y, width, text, fg, bg)
    text = util.truncate(text, width)
    self:write(x + width - #text, y, text, fg, bg)
end

--- Fill a rectangle with `char` (space by default).
function Renderer:fill(x, y, width, height, bg, char, fg)
    if width <= 0 or height <= 0 then return end
    local line = string.rep(char or " ", width)
    for row = 0, height - 1 do
        self:write(x, y + row, line, fg or "text", bg or "surface")
    end
end

function Renderer:hline(x, y, width, char, fg, bg)
    self:write(x, y, string.rep(char or theme.chars.horizontal, math.max(0, width)), fg, bg)
end

function Renderer:vline(x, y, height, char, fg, bg)
    for row = 0, height - 1 do
        self:write(x, y + row, char or theme.chars.vertical, fg, bg)
    end
end

--- Draw a bordered box, optionally filled and titled.
-- @param options table { title, fg, bg, fill (bool|color), titleFg }
function Renderer:box(x, y, width, height, options)
    options = options or {}
    if width < 2 or height < 1 then return end

    local fg = options.fg or "border"
    local bg = options.bg or "background"
    local chars = theme.chars

    if options.fill then
        local fillColor = options.fill == true and bg or options.fill
        self:fill(x, y, width, height, fillColor)
    end

    local top = chars.cornerTopLeft .. string.rep(chars.horizontal, width - 2) .. chars.cornerTopRight
    local bottom = chars.cornerBottomLeft .. string.rep(chars.horizontal, width - 2) .. chars.cornerBottomRight

    self:write(x, y, top, fg, bg)
    if height > 1 then
        self:write(x, y + height - 1, bottom, fg, bg)
    end
    for row = 1, height - 2 do
        self:write(x, y + row, chars.vertical, fg, bg)
        self:write(x + width - 1, y + row, chars.vertical, fg, bg)
    end

    if options.title and width > 4 then
        local title = " " .. util.truncate(options.title, width - 4) .. " "
        self:write(x + 1, y, title, options.titleFg or fg, bg)
    end
end

--- Horizontal progress bar. `fraction` is 0..1.
-- @param options table { fill, track, text, textFg, showPercent }
function Renderer:progress(x, y, width, fraction, options)
    options = options or {}
    if width <= 0 then return end

    fraction = util.clamp(tonumber(fraction) or 0, 0, 1)
    local filled = math.floor(width * fraction + 0.5)

    local fillColor = theme.get(options.fill or "gaugeFill")
    local trackColor = theme.get(options.track or "gaugeTrack")

    if filled > 0 then self:fill(x, y, filled, 1, fillColor, " ") end
    if filled < width then self:fill(x + filled, y, width - filled, 1, trackColor, " ") end

    local label = options.text
    if label == nil and options.showPercent ~= false then
        label = util.formatPercent(fraction)
    end
    if label and #label <= width then
        -- Draw the label in two halves so it stays readable across the seam.
        local start = x + math.floor((width - #label) / 2)
        for index = 1, #label do
            local charX = start + index - 1
            local overFill = (charX - x) < filled
            self:write(charX, y, label:sub(index, index),
                options.textFg or (overFill and "textInverse" or "text"),
                overFill and fillColor or trackColor)
        end
    end
end

--- Draw a small status dot / badge, e.g. "[ RUNNING ]".
function Renderer:badge(x, y, text, color, bg)
    local label = "[" .. tostring(text) .. "]"
    self:write(x, y, label, color or "text", bg or "background")
    return #label
end

---------------------------------------------------------------------------
-- Layout helpers
---------------------------------------------------------------------------

--- Split a length into `count` parts with `gap` between them.
-- @return table of { offset = number, size = number }
function Renderer:distribute(start, total, count, gap)
    gap = gap or 1
    local slots = {}
    if count <= 0 then return slots end
    local available = total - gap * (count - 1)
    local size = math.floor(available / count)
    local remainder = available - size * count
    local cursor = start
    for index = 1, count do
        local slotSize = size + (index <= remainder and 1 or 0)
        slots[index] = { offset = cursor, size = slotSize }
        cursor = cursor + slotSize + gap
    end
    return slots
end

--- Rectangle inset by `padding` on every side.
function Renderer.inset(x, y, width, height, padding)
    padding = padding or 1
    return x + padding, y + padding,
        math.max(0, width - padding * 2), math.max(0, height - padding * 2)
end

return Renderer

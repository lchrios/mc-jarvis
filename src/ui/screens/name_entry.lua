--- On-screen keyboard.
--
-- A monitor has no keyboard: `read()` only exists on the computer terminal, so
-- anything typed from the panel has to be tapped out letter by letter.
--
--   navigation.push("name_entry", {
--       title = "Player name",
--       value = "",
--       onDone = function(text) ... end,
--   })
--
-- Deliberately minimal: player names are letters, digits and underscores.

local class = require("core.class")
local util = require("core.util")
local Screen = require("ui.screen")
local Label = require("ui.components.label")
local Button = require("ui.components.button")
local theme = require("ui.theme")

local NameEntry = class(Screen)

-- QWERTY, because that is where the fingers already know the letters are.
-- Alphabetical rows look tidier and are slower to use: nobody has ever hunted
-- for a key by counting from A.
local LETTERS = {
    "QWERTYUIOP",
    "ASDFGHJKL",
    "ZXCVBNM_-",
}

-- ...and the digits as a numpad on the right, in the order a keyboard has
-- them, rather than trailing off the end of the alphabet.
local NUMPAD = {
    "789",
    "456",
    "123",
    "0.",
}

local LETTER_COLUMNS = 10
local NUMPAD_COLUMNS = 3
local PAD_GAP = 1        -- columns of air between the letters and the numpad
local MIN_KEY = 3        -- narrower than this and a key is not a target

local MAX_LENGTH = 24

function NameEntry:init(params)
    Screen.init(self, params)
    self.title = params.title or "Enter a name"
    self.value = params.value or ""
    self.onDone = params.onDone
end

function NameEntry:append(character)
    if #self.value >= MAX_LENGTH then return end
    self.value = self.value .. character
    self:refresh()
end

function NameEntry:backspace()
    self.value = self.value:sub(1, -2)
    self:refresh()
end

function NameEntry:refresh()
    if self.valueLabel then
        self.valueLabel:setText(self.value ~= "" and self.value or "(empty)")
    end
    self:invalidate()
end

function NameEntry:accept()
    local text = self.value:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return end
    if type(self.onDone) == "function" then pcall(self.onDone, text) end
    self.context.navigation.back()
end

function NameEntry:onLayout(x, y, w, h)
    local prompt = Label.new({ text = self.params.prompt or "Tap the name, then OK", fg = "textDim" })
    prompt:setBounds(x, y, w, 1)
    self:add(prompt)

    self.valueLabel = Label.new({
        text = self.value ~= "" and self.value or "(empty)",
        fg = "accent",
    })
    self.valueLabel:setBounds(x, y + 1, w, 1)
    self:add(self.valueLabel)

    -- Does the numpad fit beside the letters, or does it have to go under them?
    local fullColumns = LETTER_COLUMNS + PAD_GAP + NUMPAD_COLUMNS
    local sideBySide = math.floor(w / fullColumns) >= MIN_KEY

    local columns = sideBySide and fullColumns or LETTER_COLUMNS
    local keyWidth = math.max(MIN_KEY, math.floor(w / columns))
    local keyHeight = h >= 16 and 2 or 1
    local top = y + 3

    local function key(character, column, row)
        local button = Button.new({
            label = character,
            bracket = false,
            onPress = function() self:append(character) end,
        })
        button:setBounds(x + column * keyWidth, top + row * keyHeight,
            keyWidth - 1, keyHeight)
        self:add(button)
    end

    for rowIndex, row in ipairs(LETTERS) do
        for index = 1, #row do
            key(row:sub(index, index), index - 1, rowIndex - 1)
        end
    end

    local padColumn = LETTER_COLUMNS + PAD_GAP
    local padRow = 0
    if not sideBySide then
        -- Narrow monitor: the pad drops below the letters, keeping its shape.
        padColumn = 0
        padRow = #LETTERS
    end

    for rowIndex, row in ipairs(NUMPAD) do
        for index = 1, #row do
            key(row:sub(index, index), padColumn + index - 1, padRow + rowIndex - 1)
        end
    end

    -- Controls go under everything, full width, so OK and CANCEL are never a
    -- neighbour of a letter you were aiming for.
    local keyRows = math.max(#LETTERS, padRow + #NUMPAD)
    local controlsY = top + keyRows * keyHeight + 1

    local controls = {
        { label = "DEL", run = function() self:backspace() end },
        { label = "OK", style = "primary", run = function() self:accept() end },
        { label = "CANCEL", style = "danger", run = function()
            self.context.navigation.back()
        end },
    }

    local slots = self.context.navigation.getRenderer():distribute(x, w, #controls, 2)
    for index, control in ipairs(controls) do
        local button = Button.new({
            label = control.label,
            style = control.style,
            bracket = false,
            onPress = control.run,
        })
        button:setBounds(slots[index].offset, controlsY, slots[index].size,
            math.max(1, math.min(keyHeight + 1, y + h - controlsY)))
        self:add(button)
    end
end

return NameEntry

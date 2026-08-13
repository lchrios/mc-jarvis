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

local ROWS = {
    "ABCDEFGHIJ",
    "KLMNOPQRST",
    "UVWXYZ_012",
    "3456789",
}

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

    -- Keys are sized from the widest row so the grid stays square.
    local columns = 10
    local keyWidth = math.max(3, math.floor(w / columns))
    local keyHeight = h >= 16 and 2 or 1
    local top = y + 3

    for rowIndex, row in ipairs(ROWS) do
        for index = 1, #row do
            local character = row:sub(index, index)
            local key = Button.new({
                label = character,
                bracket = false,
                onPress = function() self:append(character) end,
            })
            key:setBounds(x + (index - 1) * keyWidth, top + (rowIndex - 1) * keyHeight,
                keyWidth - 1, keyHeight)
            self:add(key)
        end
    end

    -- Controls sit on the last key row, past the digits.
    local controlsY = top + (#ROWS - 1) * keyHeight
    local controls = {
        { label = "DEL", style = "default", run = function() self:backspace() end },
        { label = "OK", style = "primary", run = function() self:accept() end },
        { label = "CANCEL", style = "danger", run = function()
            self.context.navigation.back()
        end },
    }

    local startColumn = #ROWS[#ROWS] + 1
    for index, control in ipairs(controls) do
        local button = Button.new({
            label = control.label,
            style = control.style,
            bracket = false,
            onPress = control.run,
        })
        local column = startColumn + index - 1
        if column > columns then
            -- Not enough room beside the digits: stack them underneath.
            button:setBounds(x + (index - 1) * math.floor(w / 3),
                controlsY + keyHeight + 1, math.floor(w / 3) - 1, keyHeight)
        else
            button:setBounds(x + (column - 1) * keyWidth, controlsY, keyWidth - 1, keyHeight)
        end
        self:add(button)
    end
end

return NameEntry

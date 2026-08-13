--- Pick one thing from a list.
--
-- The rule editor needs this four times over - module, metric, operator,
-- action - so it is one screen rather than four nearly identical ones. It
-- reuses `List`, which brings the pager with it: a base with thirty metrics
-- pages just like anything else.
--
--   navigation.push("chooser", {
--       title = "Metric",
--       items = { { id = "buffer", label = "Buffer" }, ... },
--       onPick = function(item) ... end,
--   })

local class = require("core.class")
local util = require("core.util")
local Screen = require("ui.screen")
local Label = require("ui.components.label")
local List = require("ui.components.list")
local theme = require("ui.theme")

local Chooser = class(Screen)

function Chooser:init(params)
    Screen.init(self, params)
    self.title = params.title or "Choose"
    self.items = params.items or {}
    self.onPick = params.onPick
    self.hint = params.hint
end

function Chooser:pick(item)
    -- Leave first, so the callback can push another chooser and build a chain
    -- without stacking dead screens behind it.
    self.context.navigation.back()
    if type(self.onPick) == "function" then pcall(self.onPick, item) end
end

function Chooser:onLayout(x, y, w, h)
    local top = y

    if self.hint then
        local hint = Label.new({ text = util.truncate(self.hint, w), fg = "textDim" })
        hint:setBounds(x, top, w, 1)
        self:add(hint)
        top = top + 1
    end

    self.list = List.new({
        items = self.items,
        renderItem = function(item)
            local label = item.label or tostring(item.id or item)
            local note = item.note
            if note then
                label = util.padRight(label, math.max(8, w - #note - 1)) .. note
            end
            return { text = util.truncate(label, w), fg = theme.get(item.color or "text") }
        end,
        emptyText = self.params.emptyText or "Nothing to choose from.",
        onSelect = function(item) self:pick(item) end,
    })
    self.list:setBounds(x, top, w, math.max(1, h - (top - y)))
    self:add(self.list)
end

return Chooser

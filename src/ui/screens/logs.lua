--- Recent log lines, useful when the computer terminal is not reachable.

local class = require("core.class")
local Screen = require("ui.screen")
local List = require("ui.components.list")
local logger = require("core.logger")
local theme = require("ui.theme")

local LogsScreen = class(Screen)

local LEVEL_COLORS = {
    [1] = "textDim",
    [2] = "text",
    [3] = "statusWarn",
    [4] = "statusError",
}

function LogsScreen:init(params)
    Screen.init(self, params)
    self.title = "Logs"
end

function LogsScreen:onLayout(x, y, w, h)
    self.list = List.new({
        items = logger.recent(120),
        renderItem = function(entry)
            return { text = entry.text, fg = theme.get(LEVEL_COLORS[entry.level] or "text") }
        end,
        emptyText = "No log entries yet.",
    })
    self.list:setBounds(x + 1, y, w - 2, h)
    self:add(self.list)
    self.list:scrollToBottom()
end

function LogsScreen:update()
    if not self.list then return end
    local atBottom = self.list.offset >= self.list:maxOffset()
    self.list:setItems(logger.recent(120))
    if atBottom then self.list:scrollToBottom() end
end

return LogsScreen

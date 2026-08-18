--- Recent log lines, useful when the computer terminal is not reachable.
--
-- One row per entry, one line each - which is fine for "peripheral attached"
-- and useless for the errors, whose interesting half is the part that did not
-- fit. Touching a row opens it in full. The level filter is here for the same
-- reason: the line you came to read is usually the only ERROR in a hundred
-- lines of routine INFO.

local class = require("core.class")
local Screen = require("ui.screen")
local List = require("ui.components.list")
local Label = require("ui.components.label")
local logger = require("core.logger")
local theme = require("ui.theme")

local LogsScreen = class(Screen)

local LEVEL_COLORS = {
    [1] = "textDim",
    [2] = "text",
    [3] = "statusWarn",
    [4] = "statusError",
}

--- What the filter button cycles through.
local FILTERS = {
    { label = "ALL", min = 1 },
    { label = "WARN+", min = 3 },
    { label = "ERRORS", min = 4 },
}

function LogsScreen:init(params)
    Screen.init(self, params)
    self.title = "Logs"
    self.filter = 1
end

function LogsScreen:entries()
    local minimum = FILTERS[self.filter].min
    if minimum <= 1 then return logger.recent(120) end

    local kept = {}
    for _, entry in ipairs(logger.recent(120)) do
        if (entry.level or 2) >= minimum then kept[#kept + 1] = entry end
    end
    return kept
end

function LogsScreen:onLayout(x, y, w, h)
    local listHeight = math.max(1, h - 1 - Screen.ACTION_BAR)

    self.header = Label.new({ text = "", fg = "textDim" })
    self.header:setBounds(x + 1, y, w - 2, 1)
    self:add(self.header)

    self.list = List.new({
        items = self:entries(),
        renderItem = function(entry)
            return { text = entry.text, fg = theme.get(LEVEL_COLORS[entry.level] or "text") }
        end,
        emptyText = "No log entries at this level.",
        onSelect = function(entry)
            self.context.navigation.push("log_entry", { entry = entry })
        end,
    })
    self.list:setBounds(x + 1, y + 1, w - 2, listHeight)
    self:add(self.list)
    self.list:scrollToBottom()

    self:actionBar(x + 1, y, w - 2, h, {
        { label = "SHOWING " .. FILTERS[self.filter].label, style = "primary", run = function()
            self.filter = (self.filter % #FILTERS) + 1
            self:requestLayout()
        end },
    })
end

function LogsScreen:update()
    if not self.list then return end

    local entries = self:entries()
    local atBottom = self.list.offset >= self.list:maxOffset()
    self.list:setItems(entries)
    if atBottom then self.list:scrollToBottom() end

    if self.header then
        self.header:setText(("%d line(s)  -  touch one to read it in full"):format(#entries))
    end
end

return LogsScreen

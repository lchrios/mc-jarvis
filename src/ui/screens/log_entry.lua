--- One log line, in full.
--
-- The log list has one row per entry and an entry is one line wide, so the
-- interesting half of an error - the part after "failed:" - was always the
-- half that got cut off. This screen exists to show the whole of it: wrapped
-- to the monitor, scrollable, and with the timestamp, level and subsystem
-- pulled out of the line instead of eating into the width.
--
-- A modal would have been the smaller change and the wrong one: its width is
-- driven by its title, so a long message wraps into more lines than the box
-- can hold and gets clipped exactly like the row it came from.

local class = require("core.class")
local util = require("core.util")
local Screen = require("ui.screen")
local List = require("ui.components.list")
local Label = require("ui.components.label")
local theme = require("ui.theme")

local LogEntryScreen = class(Screen)

local LEVEL_COLORS = {
    [1] = "textDim",
    [2] = "text",
    [3] = "statusWarn",
    [4] = "statusError",
}

function LogEntryScreen:init(params)
    Screen.init(self, params)
    self.entry = params.entry or {}
    self.title = "Log entry"
end

--- Split "[12:04:31] [ERROR] [network] send failed: ..." into its parts.
-- Falls back to the raw line: the format is the logger's, not a contract.
local function parse(text)
    text = tostring(text or "")

    local time, level, rest = text:match("^%[(.-)%] %[(.-)%] (.*)$")
    if not time then return { message = text } end

    local scope, body = rest:match("^%[(.-)%] (.*)$")
    return {
        time = time,
        level = level,
        scope = scope,
        message = body or rest,
    }
end

function LogEntryScreen:onLayout(x, y, w, h)
    local width = w - 2
    local parts = parse(self.entry.text)
    local colour = LEVEL_COLORS[self.entry.level] or "text"

    ---------------------------------------------------------------- header
    local heading = Label.new({
        text = util.truncate(("%s  %s%s"):format(
            parts.level or "LOG",
            parts.time and (parts.time .. "  ") or "",
            parts.scope and ("[" .. parts.scope .. "]") or ""), width),
        fg = colour,
    })
    heading:setBounds(x + 1, y, width, 1)
    self:add(heading)

    if self.entry.time then
        local age = Label.new({
            text = util.formatDuration((util.nowMs() - self.entry.time) / 1000) .. " ago",
            fg = "textDim",
            align = "right",
        })
        age:setBounds(x + 1, y, width, 1)
        self:add(age)
    end

    ---------------------------------------------------------------- body
    -- Wrapped into rows so the list can scroll it: an error long enough to be
    -- worth opening is often longer than the monitor is tall.
    local lines = Label.wrapText(parts.message, width)
    local rows = {}
    for _, line in ipairs(lines) do rows[#rows + 1] = line end

    self.list = List.new({
        items = rows,
        renderItem = function(line) return { text = line, fg = theme.get("text") } end,
        emptyText = "(empty line)",
    })
    self.list:setBounds(x + 1, y + 2, width, math.max(1, h - 2))
    self:add(self.list)
end

return LogEntryScreen

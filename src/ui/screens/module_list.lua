--- Flat list of every registered module.
--
-- Fallback navigation target: reachable from the footer and from zones that do
-- not resolve to a module, so nothing is ever unreachable in the UI.

local class = require("core.class")
local util = require("core.util")
local bus = require("core.event_bus")
local Screen = require("ui.screen")
local List = require("ui.components.list")
local registry = require("modules.registry")
local theme = require("ui.theme")

local ModuleList = class(Screen)

function ModuleList:init(params)
    Screen.init(self, params)
    self.title = "Modules"
end

function ModuleList:onMount()
    local refresh = function() self:invalidate() end
    self:onCleanup(bus.on("module.*", refresh, { owner = "screen:module_list" }))
end

local function renderRecord(record, width)
    local status = record.statusText or tostring(record.status):upper()
    local name = util.padRight(record.name, math.max(8, width - #status - 3))
    return {
        text = name .. " " .. status,
        fg = record.available and theme.statusColor(record.status) or theme.get("statusUnknown"),
    }
end

function ModuleList:onLayout(x, y, w, h)
    local width = w - 2
    self.list = List.new({
        items = registry.all(),
        renderItem = function(record) return renderRecord(record, width) end,
        emptyText = "No modules registered.",
        onSelect = function(record)
            self.context.navigation.push("module_detail", { moduleId = record.id })
        end,
    })
    self.list:setBounds(x + 1, y, width, h)
    self:add(self.list)
end

function ModuleList:update()
    if self.list then self.list:setItems(registry.all()) end
end

return ModuleList

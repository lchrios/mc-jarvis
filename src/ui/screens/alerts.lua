--- Active alerts, newest and most severe first.

local class = require("core.class")
local util = require("core.util")
local bus = require("core.event_bus")
local Screen = require("ui.screen")
local List = require("ui.components.list")
local Label = require("ui.components.label")
local Modal = require("ui.components.modal")
local alerts = require("services.alerts")
local theme = require("ui.theme")

local AlertsScreen = class(Screen)

function AlertsScreen:init(params)
    Screen.init(self, params)
    self.title = "Alerts"
end

function AlertsScreen:onMount()
    local refresh = function() self:invalidate() end
    self:onCleanup(bus.on("alert.*", refresh, { owner = "screen:alerts" }))
end

local function renderAlert(entry)
    local age = util.formatDuration((util.nowMs() - entry.timestamp) / 1000)
    return {
        text = string.format("%-8s %s (%s)", entry.severity:upper(), entry.message, age),
        fg = theme.severityColor(entry.severity),
    }
end

function AlertsScreen:onLayout(x, y, w, h)
    local heading = Label.new({ text = "Active alerts", fg = "textDim" })
    heading:setBounds(x + 1, y, w - 2, 1)
    self:add(heading)

    self.list = List.new({
        items = alerts.list(),
        renderItem = renderAlert,
        emptyText = "No active alerts.",
        onSelect = function(entry) self:showAlert(entry) end,
    })
    self.list:setBounds(x + 1, y + 1, w - 2, math.max(1, h - 1))
    self:add(self.list)
end

function AlertsScreen:showAlert(entry)
    self:openModal(Modal.new({
        title = entry.severity:upper() .. " - " .. entry.source,
        message = entry.message .. "\n\nRaised " ..
            util.formatDuration((util.nowMs() - entry.timestamp) / 1000) .. " ago" ..
            (entry.count > 1 and (", seen " .. entry.count .. " times") or ""),
        buttons = {
            { label = "CLOSE" },
            { label = "DISMISS", style = "danger", onPress = function()
                alerts.clear(entry.id)
                self:requestLayout()
            end },
        },
        onClose = function() self:closeModal() end,
    }))
end

function AlertsScreen:update()
    if self.list then self.list:setItems(alerts.list()) end
end

return AlertsScreen

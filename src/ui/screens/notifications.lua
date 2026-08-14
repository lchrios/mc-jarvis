--- What gets announced in chat, and what does not.
--
-- One row per topic, with what it has done so far next to it: `12 fired` says
-- the thing happened, `12 said` says it reached chat. When those two numbers
-- differ, the rate limiter is doing its job.

local class = require("core.class")
local util = require("core.util")
local bus = require("core.event_bus")
local Screen = require("ui.screen")
local Label = require("ui.components.label")
local List = require("ui.components.list")
local Modal = require("ui.components.modal")
local notifications = require("services.notifications")
local registry = require("modules.registry")
local theme = require("ui.theme")

local NotificationsScreen = class(Screen)

function NotificationsScreen:init(params)
    Screen.init(self, params)
    self.title = "Notifications"
    self.selected = nil
end

function NotificationsScreen:onMount()
    self:onCleanup(bus.on("notifications.changed", function() self:requestLayout() end,
        { owner = "screen:notifications" }))
    self:onCleanup(bus.on("notify", function() self:invalidate() end,
        { owner = "screen:notifications" }))
end

---------------------------------------------------------------------------

local function renderTopic(topic, width, selected)
    local right
    if topic.fired == 0 then
        right = topic.enabled and "on" or "off"
    elseif topic.announced == topic.fired then
        right = topic.fired .. " said"
    else
        right = topic.announced .. "/" .. topic.fired .. " said"
    end
    right = util.padLeft(right, 14)

    local label = util.truncate(topic.label, math.max(6, width - #right - 1))

    local colour = theme.get("textDim")
    if topic.enabled then
        colour = topic.severity == "critical" and theme.get("statusError")
            or theme.get("text")
    end

    return {
        text = util.padRight(label, width - #right) .. right,
        fg = selected and theme.get("accentText") or colour,
        bg = selected and theme.get("accent") or nil,
    }
end

---------------------------------------------------------------------------

function NotificationsScreen:selectedTopic()
    for _, topic in ipairs(notifications.list()) do
        if topic.id == self.selected then return topic end
    end
    return nil
end

function NotificationsScreen:toggleSelected()
    local topic = self:selectedTopic()
    if not topic then return self:say("Pick a notification first.") end

    local ok, err = notifications.setEnabled(topic.id, not topic.enabled)
    if not ok then return self:say("Could not save: " .. tostring(err)) end
    self:requestLayout()
end

--- Send one down the real path, so "is the Chat Box working" has an answer.
function NotificationsScreen:test()
    local record = registry.get("notifier")
    if not record then
        return self:say("The notifier module is not loaded on this computer.")
    end

    local ok, err = registry.invoke("notifier", "test")
    self:say(ok and "Test message sent to every sink."
        or ("Nothing accepted it: " .. tostring(err)))
end

function NotificationsScreen:resetToConfig()
    self:openModal(Modal.new({
        title = "Back to the configured set?",
        message = "Everything switched here is discarded and "
            .. "config/notifications.lua takes over again.",
        buttons = {
            { label = "CANCEL" },
            { label = "DISCARD", style = "danger", onPress = function()
                notifications.resetToConfig()
                self:requestLayout()
            end },
        },
        onClose = function() self:closeModal() end,
    }))
end

function NotificationsScreen:say(message)
    self.message = message
    self:invalidate()
end

---------------------------------------------------------------------------

function NotificationsScreen:onLayout(x, y, w, h)
    local list = notifications.list()

    local on = 0
    for _, topic in ipairs(list) do
        if topic.enabled then on = on + 1 end
    end

    -- The selected topic explains itself here, so the rows can stay short.
    local selected = self:selectedTopic()
    local heading = self.message
        or (selected and selected.description)
        or ("%d of %d on%s"):format(on, #list,
            notifications.hasOverride() and "  (edited)" or "  (from config)")

    local status = Label.new({ text = util.truncate(heading, w), fg = "textDim" })
    status:setBounds(x, y, w, 1)
    self:add(status)
    self.message = nil

    local listHeight = math.max(1, h - Screen.ACTION_BAR - 1)
    self.list = List.new({
        items = list,
        renderItem = function(topic)
            return renderTopic(topic, w, self.selected == topic.id)
        end,
        emptyText = "No notification topics.",
        onSelect = function(topic)
            self.selected = topic.id
            self:requestLayout()
        end,
    })
    self.list:setBounds(x, y + 1, w, listHeight)
    self:add(self.list)

    self:actionBar(x, y, w, h, {
        {
            label = (selected and selected.enabled) and "MUTE" or "ANNOUNCE",
            style = (selected and selected.enabled) and "danger" or "primary",
            run = function() self:toggleSelected() end,
        },
        { label = "TEST", run = function() self:test() end },
        { label = "RESET", run = function() self:resetToConfig() end },
    })
end

function NotificationsScreen:update()
    if self.list then self.list:setItems(notifications.list()) end
end

return NotificationsScreen

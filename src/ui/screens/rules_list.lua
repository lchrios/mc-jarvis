--- Every rule, what it is doing, and the switch that turns it on.
--
-- BaseOS ships a set of rules with `enabled = false`. This is where you turn
-- one on, watch it work, and open it to adjust it to your base.

local class = require("core.class")
local util = require("core.util")
local bus = require("core.event_bus")
local Screen = require("ui.screen")
local Label = require("ui.components.label")
local Button = require("ui.components.button")
local List = require("ui.components.list")
local Modal = require("ui.components.modal")
local rules = require("services.rules")
local theme = require("ui.theme")

local RulesList = class(Screen)

local CONTROLS_HEIGHT = 3

function RulesList:init(params)
    Screen.init(self, params)
    self.title = "Rules"
    self.selected = nil
end

function RulesList:onMount()
    local refresh = function() self:requestLayout() end
    self:onCleanup(bus.on("rules.changed", refresh, { owner = "screen:rules" }))
    self:onCleanup(bus.on("rules.entered", function() self:invalidate() end,
        { owner = "screen:rules" }))
    self:onCleanup(bus.on("rules.left", function() self:invalidate() end,
        { owner = "screen:rules" }))
end

---------------------------------------------------------------------------

--- What a rule is doing right now, in three words.
local function stateOf(rule)
    if not rule.enabled then return "off", theme.get("statusIdle") end
    if rule.error then return "ERROR", theme.get("statusError") end
    if rule.yielded then return "yielded", theme.get("statusWarn") end
    if rule.phase == "acting" then
        local remaining = rule.remaining
            and ("  " .. math.floor(rule.remaining) .. "s") or ""
        return "ACTING" .. remaining, theme.get("statusOk")
    end
    return "waiting", theme.get("textDim")
end

local function renderRule(rule, width, selected)
    local text, colour = stateOf(rule)
    local right = util.padLeft(text, 14)
    local name = util.truncate(rule.name or rule.id, math.max(6, width - #right - 1))

    return {
        text = util.padRight(name, width - #right) .. right,
        fg = selected and theme.get("accentText") or colour,
        bg = selected and theme.get("accent") or nil,
    }
end

---------------------------------------------------------------------------

function RulesList:toggleSelected()
    if not self.selected then return self:say("Pick a rule first.") end

    local current
    for _, rule in ipairs(rules.list()) do
        if rule.id == self.selected then current = rule end
    end
    if not current then return end

    rules.setEnabled(self.selected, not current.enabled)
    self:requestLayout()
end

function RulesList:editSelected()
    if not self.selected then return self:say("Pick a rule first.") end
    self.context.navigation.push("rule_edit", { ruleId = self.selected })
end

function RulesList:createRule()
    local list = rules.current()

    -- A skeleton the editor can fill in; it is disabled until it makes sense.
    local id = "rule_" .. (#list + 1)
    while rules.get(id) do id = id .. "x" end

    list[#list + 1] = {
        id = id,
        name = "New rule",
        enabled = false,
        when = { metric = "", op = ">=", value = 0 },
        do_ = "",
    }
    rules.save(list)

    self.selected = id
    self.context.navigation.push("rule_edit", { ruleId = id })
end

function RulesList:resetToConfig()
    self:openModal(Modal.new({
        title = "Back to the shipped rules?",
        message = "Everything edited here is discarded and config/rules.lua "
            .. "takes over again.",
        buttons = {
            { label = "CANCEL" },
            { label = "DISCARD", style = "danger", onPress = function()
                rules.resetToConfig()
                self.selected = nil
                self:requestLayout()
            end },
        },
        onClose = function() self:closeModal() end,
    }))
end

function RulesList:say(message)
    self.message = message
    self:invalidate()
end

---------------------------------------------------------------------------

function RulesList:onLayout(x, y, w, h)
    local list = rules.list()

    local enabled = 0
    for _, rule in ipairs(list) do
        if rule.enabled then enabled = enabled + 1 end
    end

    local status = Label.new({
        text = util.truncate(self.message
            or (("%d of %d on%s"):format(enabled, #list,
                rules.hasOverride() and "  (edited)" or "  (from config)")), w),
        fg = "textDim",
    })
    status:setBounds(x, y, w, 1)
    self:add(status)
    self.message = nil

    local listHeight = math.max(1, h - CONTROLS_HEIGHT - 1)
    self.list = List.new({
        items = list,
        renderItem = function(rule)
            return renderRule(rule, w, self.selected == rule.id)
        end,
        emptyText = "No rules. Press NEW, or add them in config/rules.lua.",
        onSelect = function(rule)
            self.selected = rule.id
            self:requestLayout()
        end,
    })
    self.list:setBounds(x, y + 1, w, listHeight)
    self:add(self.list)

    local controlsY = y + h - CONTROLS_HEIGHT
    if controlsY <= y + 1 then return end

    local current
    for _, rule in ipairs(list) do
        if rule.id == self.selected then current = rule end
    end

    local actions = {
        {
            label = (current and current.enabled) and "TURN OFF" or "TURN ON",
            style = (current and current.enabled) and "danger" or "primary",
            run = function() self:toggleSelected() end,
        },
        { label = "EDIT", run = function() self:editSelected() end },
        { label = "NEW", run = function() self:createRule() end },
        { label = "RESET", run = function() self:resetToConfig() end },
    }

    local slots = self.context.navigation.getRenderer():distribute(x, w, #actions, 1)
    for index, action in ipairs(actions) do
        local button = Button.new({
            label = action.label,
            style = action.style,
            bracket = false,
            onPress = action.run,
        })
        button:setBounds(slots[index].offset, controlsY, slots[index].size, CONTROLS_HEIGHT)
        self:add(button)
    end
end

function RulesList:update()
    if self.list then self.list:setItems(rules.list()) end
end

return RulesList

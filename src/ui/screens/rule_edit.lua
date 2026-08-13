--- Build a rule by touching, not by typing Lua.
--
-- The five fields are the shape of a rule, in the order it reads:
--
--   WHEN   the entry condition
--   DO     what happens on entry
--   UNTIL  the exit condition
--   AFTER  the deadline, as a safety net for when UNTIL never comes
--   THEN   what happens on exit
--
-- Each field opens a chain of choosers - module, then metric, then operator,
-- then value - so nothing has to be spelled correctly. Numbers come from the
-- same on-screen keyboard the access screen uses.

local class = require("core.class")
local util = require("core.util")
local Screen = require("ui.screen")
local Label = require("ui.components.label")
local Button = require("ui.components.button")
local Panel = require("ui.components.panel")
local Modal = require("ui.components.modal")
local rules = require("services.rules")
local registry = require("modules.registry")
local theme = require("ui.theme")

local RuleEdit = class(Screen)

local CONTROLS_HEIGHT = 5
local OPERATORS = { ">=", ">", "<=", "<", "==", "~=" }
local DURATIONS = { "none", "10s", "30s", "60s", "2m", "5m", "15m", "1h" }

function RuleEdit:init(params)
    Screen.init(self, params)
    self.ruleId = params.ruleId

    -- A working copy: nothing is stored until SAVE.
    self.draft = nil
    for _, rule in ipairs(rules.current()) do
        if rule.id == self.ruleId then self.draft = util.deepCopy(rule) end
    end
    self.draft = self.draft or { id = self.ruleId, name = self.ruleId }
    self.title = self.draft.name or self.ruleId
    self.edited = false
end

---------------------------------------------------------------------------
-- Rendering a rule as words
---------------------------------------------------------------------------

--- A condition table as something a person can read.
local function describeCondition(condition)
    if type(condition) ~= "table" then return "(not set)" end

    if condition.all or condition.any then
        local parts = {}
        for _, child in ipairs(condition.all or condition.any) do
            parts[#parts + 1] = describeCondition(child)
        end
        return table.concat(parts, condition.all and "  AND  " or "  OR  ")
    end
    if condition.metric then
        if condition.metric == "" then return "(pick a metric)" end
        local text = ("%s %s %s"):format(condition.metric,
            condition.op or ">=", tostring(condition.value or 0))
        if condition.for_ then text = text .. " for " .. condition.for_ end
        return text
    end
    if condition.status then
        return ("%s is %s"):format(condition.status,
            condition.is or ("not " .. tostring(condition.isNot)))
    end
    if condition.trend then
        return ("%s %s%s"):format(condition.trend, condition.direction or "down",
            condition.over and (" over " .. condition.over) or "")
    end
    if condition.time then
        return ("between %s and %s"):format(
            tostring(condition.time.from), tostring(condition.time.to))
    end
    if condition.players then
        local players = condition.players
        if players.name then return "player " .. players.name .. " around" end
        if players.online ~= nil then
            return ("%d players online%s"):format(players.online,
                players.for_ and (" for " .. players.for_) or "")
        end
        return "at least " .. tostring(players.atLeast or 1) .. " online"
    end
    if condition.alert then return "alert " .. tostring(condition.alert) .. " active" end
    if condition.severity then return "any " .. condition.severity .. " alert" end
    if condition.node then
        return ("node %s %s"):format(condition.node,
            condition.online == false and "offline" or "online")
    end
    return "(not set)"
end

local function describeAction(action)
    if action == nil or action == "" then return "(nothing)" end
    if type(action) == "string" then return action end
    if type(action) == "table" then
        if #action > 0 then
            local parts = {}
            for _, child in ipairs(action) do parts[#parts + 1] = describeAction(child) end
            return table.concat(parts, ", ")
        end
        if action.alert then return "raise a " .. (action.alert.severity or "warning") end
        if action.clearAlert then return "clear the alert" end
        if action.say then return 'say "' .. tostring(action.say) .. '"' end
    end
    return "(nothing)"
end

RuleEdit.describeCondition = describeCondition
RuleEdit.describeAction = describeAction

---------------------------------------------------------------------------
-- Choosers
---------------------------------------------------------------------------

function RuleEdit:choose(title, items, onPick, hint)
    self.context.navigation.push("chooser", {
        title = title, items = items, onPick = onPick, hint = hint,
    })
end

local function moduleItems()
    local items = {}
    for _, record in ipairs(registry.all()) do
        items[#items + 1] = { id = record.id, label = record.name, note = record.id }
    end
    return items
end

local function metricItems(moduleId)
    local snapshot = registry.snapshot(moduleId)
    local items = {}
    for _, metric in ipairs((snapshot and snapshot.metrics) or {}) do
        if type(metric.value) == "number" or metric.kind == "percent" then
            items[#items + 1] = {
                id = metric.id,
                label = metric.label,
                note = registry.formatMetric(metric),
            }
        end
    end
    return items
end

local function actionItems(moduleId)
    local items = {}
    for _, action in ipairs(registry.actions(moduleId)) do
        items[#items + 1] = { id = action.id, label = action.label }
    end
    return items
end

--- module -> metric -> operator -> value, then hand back a condition.
function RuleEdit:buildCondition(onDone)
    self:choose("Module", moduleItems(), function(moduleItem)
        local metrics = metricItems(moduleItem.id)
        if #metrics == 0 then
            self:say("'" .. moduleItem.label .. "' publishes no numeric metric.")
            return
        end

        self:choose("Metric", metrics, function(metricItem)
            local operators = {}
            for _, op in ipairs(OPERATORS) do operators[#operators + 1] = { id = op, label = op } end

            self:choose("Compare", operators, function(operatorItem)
                self.context.navigation.push("name_entry", {
                    title = "Value",
                    prompt = metricItem.label .. " " .. operatorItem.id .. " ?",
                    onDone = function(text)
                        onDone({
                            metric = moduleItem.id .. "." .. metricItem.id,
                            op = operatorItem.id,
                            value = tonumber(text) or 0,
                        })
                    end,
                })
            end)
        end)
    end)
end

--- module -> action.
function RuleEdit:buildAction(onDone)
    self:choose("Module", moduleItems(), function(moduleItem)
        local actions = actionItems(moduleItem.id)
        if #actions == 0 then
            self:say("'" .. moduleItem.label .. "' offers no actions.")
            return
        end
        self:choose("Action", actions, function(actionItem)
            onDone(moduleItem.id .. "." .. actionItem.id)
        end)
    end)
end

---------------------------------------------------------------------------
-- Fields
---------------------------------------------------------------------------

function RuleEdit:fields()
    return {
        { key = "when", label = "WHEN", value = describeCondition(self.draft.when),
          edit = function()
              self:buildCondition(function(condition)
                  self.draft.when = condition
                  self:touch()
              end)
          end },
        { key = "do_", label = "DO", value = describeAction(self.draft.do_),
          edit = function()
              self:buildAction(function(action)
                  self.draft.do_ = action
                  self:touch()
              end)
          end },
        { key = "until_", label = "UNTIL", value = describeCondition(self.draft.until_),
          edit = function()
              self:buildCondition(function(condition)
                  self.draft.until_ = condition
                  self:touch()
              end)
          end },
        { key = "after", label = "AFTER", value = self.draft.after or "(no deadline)",
          edit = function()
              local items = {}
              for _, duration in ipairs(DURATIONS) do
                  items[#items + 1] = { id = duration, label = duration }
              end
              self:choose("Deadline", items, function(item)
                  self.draft.after = item.id ~= "none" and item.id or nil
                  self:touch()
              end, "The safety net for when UNTIL never arrives")
          end },
        { key = "then_", label = "THEN", value = describeAction(self.draft.then_),
          edit = function()
              self:buildAction(function(action)
                  self.draft.then_ = action
                  self:touch()
              end)
          end },
    }
end

function RuleEdit:touch()
    self.edited = true
    self:requestLayout()
end

function RuleEdit:say(message)
    self.message = message
    self:invalidate()
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

--- What is still missing before this rule can be saved, or nil.
local function incomplete(draft)
    if type(draft.when) ~= "table" then return "WHEN is not set." end
    if draft.when.metric == "" then return "WHEN has no metric yet." end
    if draft.do_ == nil or draft.do_ == "" then return "DO is not set." end
    if draft.then_ ~= nil and draft.then_ ~= "" and not draft.until_ and not draft.after then
        return "THEN never runs without an UNTIL or an AFTER."
    end
    return nil
end

function RuleEdit:save()
    local missing = incomplete(self.draft)
    if missing then return self:say(missing) end

    local list = rules.current()
    local replaced = false
    for index, rule in ipairs(list) do
        if rule.id == self.ruleId then
            list[index] = self.draft
            replaced = true
        end
    end
    if not replaced then list[#list + 1] = self.draft end

    local ok, err = rules.save(list)
    if not ok then return self:say("Could not save: " .. tostring(err)) end

    self.edited = false
    self.context.navigation.back()
end

function RuleEdit:remove()
    self:openModal(Modal.new({
        title = "Delete this rule?",
        message = (self.draft.name or self.ruleId) .. " would be gone.",
        buttons = {
            { label = "CANCEL" },
            { label = "DELETE", style = "danger", onPress = function()
                local list = rules.current()
                for index = #list, 1, -1 do
                    if list[index].id == self.ruleId then table.remove(list, index) end
                end
                rules.save(list)
                self.context.navigation.back()
            end },
        },
        onClose = function() self:closeModal() end,
    }))
end

function RuleEdit:exit()
    if not self.edited then return self.context.navigation.back() end

    self:openModal(Modal.new({
        title = "Discard changes?",
        message = "This rule has unsaved edits.",
        buttons = {
            { label = "KEEP EDITING" },
            { label = "DISCARD", style = "danger",
              onPress = function() self.context.navigation.back() end },
        },
        onClose = function() self:closeModal() end,
    }))
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------

function RuleEdit:onLayout(x, y, w, h)
    local fields = self:fields()

    local bodyHeight = h - CONTROLS_HEIGHT
    local panel = Panel.new({ title = self.draft.name or self.ruleId, bg = "background" })
    panel:setBounds(x, y, w, math.max(3, bodyHeight))
    self:add(panel)

    local cx, cy, cw = panel:contentBounds()
    local row = cy

    if self.message then
        local note = Label.new({ text = util.truncate(self.message, cw), fg = "statusWarn" })
        note:setBounds(cx, row, cw, 1)
        self:add(note)
        row = row + 1
        self.message = nil
    end

    -- Each field is a touchable row: the label, then what it says now.
    for _, field in ipairs(fields) do
        if row >= cy + bodyHeight - 2 then break end

        local hotspot = Panel.new({
            border = false, fill = false,
            onTouch = function() field.edit() return true end,
        })
        hotspot:setBounds(cx, row, cw, 1)
        self:add(hotspot)

        local label = Label.new({ text = field.label, fg = "accent" })
        label:setBounds(cx, row, 7, 1)
        hotspot:add(label)

        local value = Label.new({
            text = util.truncate(field.value, cw - 8),
            fg = field.value:find("^%(") and "textDim" or "text",
        })
        value:setBounds(cx + 8, row, cw - 8, 1)
        hotspot:add(value)

        row = row + 1
    end

    -- Controls
    local controlsY = y + h - CONTROLS_HEIGHT + 1
    local hint = Label.new({
        text = util.truncate("Touch a field to change it", w),
        fg = "textDim",
    })
    hint:setBounds(x, controlsY - 1, w, 1)
    self:add(hint)

    local actions = {
        { label = "SAVE", style = "primary", run = function() self:save() end },
        { label = "DELETE", style = "danger", run = function() self:remove() end },
        { label = "BACK", run = function() self:exit() end },
    }

    local slots = self.context.navigation.getRenderer():distribute(x, w, #actions, 1)
    for index, action in ipairs(actions) do
        local button = Button.new({
            label = action.label,
            style = action.style,
            bracket = false,
            onPress = action.run,
        })
        button:setBounds(slots[index].offset, controlsY, slots[index].size,
            CONTROLS_HEIGHT - 1)
        self:add(button)
    end
end

return RuleEdit

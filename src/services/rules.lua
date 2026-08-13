--- Automation rules: the part that acts, not just watches.
--
-- A rule is a two-state machine, not a timer. It enters when `when` becomes
-- true, and leaves when `until_` becomes true **or** `after` elapses,
-- whichever comes first. That distinction is the whole point: telling a farm
-- to stop "for 30 seconds" wastes production if the buffer drained in 15, and
-- restarts into a still-full buffer if it did not.
--
--   {
--     id = "backpressure",
--     when   = { metric = "mob_farm.buffer", op = ">=", value = 0.9 },
--     do_    = "mob_farm.stop",
--     until_ = { metric = "mob_farm.buffer", op = "<=", value = 0.3 },
--     after  = "60s",
--     then_  = "mob_farm.start",
--   }
--
-- Conditions are tables rather than a string language on purpose: they have to
-- be editable from a monitor, and a parser would make that much harder.
--
-- Being a state machine also makes rules safe across a reboot: nothing is
-- remembered, the conditions are simply evaluated again.
--
-- A human always wins. Pressing a button by hand releases whatever rule was
-- acting on that module, and it stays out until its entry condition goes false
-- and true again - otherwise the rule would just undo you a second later.

local util = require("core.util")
local logger = require("core.logger")
local bus = require("core.event_bus")
local state = require("core.state")
local persistence = require("services.persistence")

local log = logger.scoped("rules")

local rules = {}

--- Rules edited on screen live here; `config/rules.lua` stays hand-editable,
--- exactly like the base plan.
rules.STORE = "rules"

local settings = {
    enabled = true,
    interval = 2,       -- seconds between evaluations
}

local context = nil
local definitions = {}  -- ordered rule definitions
local runtime = {}      -- [id] = { phase, enteredAt, exitAt, yielded, fired }
local acting = false    -- true while the engine is the one invoking an action
local armed = false     -- the tick and the listeners are wired

---------------------------------------------------------------------------
-- Durations
---------------------------------------------------------------------------

--- "90s", "5m", "2h" or a plain number of seconds.
local function seconds(value)
    if type(value) == "number" then return value end
    if type(value) ~= "string" then return nil end

    local amount, unit = value:match("^(%d+%.?%d*)%s*([smh]?)$")
    if not amount then return nil end
    amount = tonumber(amount)

    if unit == "m" then return amount * 60 end
    if unit == "h" then return amount * 3600 end
    return amount
end

rules.seconds = seconds

---------------------------------------------------------------------------
-- Reading the world
---------------------------------------------------------------------------

--- "mob_farm.buffer" -> the numeric value of that metric, or nil.
local function metricValue(path)
    local moduleId, metricId = path:match("^(.-)%.([^%.]+)$")
    if not moduleId then return nil end

    local snapshot = context.modules.snapshot(moduleId)
    if not snapshot then return nil end

    for _, metric in ipairs(snapshot.metrics or {}) do
        if metric.id == metricId then
            local value = metric.value
            if metric.kind == "percent" and type(metric.percent) == "number" then
                value = metric.percent
            end
            return type(value) == "number" and value or nil
        end
    end
    return nil
end

local COMPARISONS = {
    [">"] = function(a, b) return a > b end,
    [">="] = function(a, b) return a >= b end,
    ["<"] = function(a, b) return a < b end,
    ["<="] = function(a, b) return a <= b end,
    ["=="] = function(a, b) return a == b end,
    ["~="] = function(a, b) return a ~= b end,
}

--- In-game hour as a float, so 22:30 is 22.5.
local function gameHour()
    local ok, value = pcall(os.time)
    if not ok or type(value) ~= "number" then return nil end
    return value % 24
end

local function parseHour(text)
    if type(text) == "number" then return text end
    local hours, minutes = tostring(text):match("^(%d+):(%d+)$")
    if not hours then return tonumber(text) end
    return tonumber(hours) + tonumber(minutes) / 60
end

--- Players currently online, from whichever module or peripheral can say.
local function onlinePlayers()
    local presence = context.modules.get("presence")
    if presence and presence.def and presence.def.online then
        return presence.def.online
    end

    local proxy = context.peripherals.get("playerDetector")
        or context.peripherals.firstOfType("player_detector")
    if not proxy then return nil end

    local detector = context.adapters.forProxy(proxy, "advanced_peripherals")
    return detector and detector.online() or nil
end

---------------------------------------------------------------------------
-- Conditions
---------------------------------------------------------------------------

local evaluate

--- How long a condition has continuously held, tracked per rule.
local function heldFor(record, key, holding, required)
    record.timers = record.timers or {}
    local now = util.nowMs()

    if not holding then
        record.timers[key] = nil
        return false
    end

    record.timers[key] = record.timers[key] or now
    return (now - record.timers[key]) >= required * 1000
end

--- Evaluate one condition table. Returns true/false; unknown data is false.
evaluate = function(condition, record)
    if condition == nil then return false end
    if type(condition) == "boolean" then return condition end
    if type(condition) ~= "table" then return false end

    -- Combinators
    if condition.all then
        for _, child in ipairs(condition.all) do
            if not evaluate(child, record) then return false end
        end
        return true
    end
    if condition.any then
        for _, child in ipairs(condition.any) do
            if evaluate(child, record) then return true end
        end
        return false
    end
    if condition.none then
        for _, child in ipairs(condition.none) do
            if evaluate(child, record) then return false end
        end
        return true
    end

    -- A metric against a number.
    if condition.metric then
        local value = metricValue(condition.metric)
        if value == nil then return false end
        local compare = COMPARISONS[condition.op or ">="]
        if not compare then return false end

        local holding = compare(value, condition.value or 0)
        if condition.for_ then
            return heldFor(record, "metric:" .. condition.metric,
                holding, seconds(condition.for_) or 0)
        end
        return holding
    end

    -- A module's status.
    if condition.status then
        local snapshot = context.modules.snapshot(condition.status)
        if not snapshot then return false end
        local actual = tostring(snapshot.status)
        if condition.is then return actual == condition.is end
        if condition.isNot then return actual ~= condition.isNot end
        return false
    end

    -- Where a metric is heading, from the recorded window.
    if condition.trend then
        local direction = context.history.trend(condition.trend)
        local holding = direction == (condition.direction or "down")
        if condition.over then
            return heldFor(record, "trend:" .. condition.trend,
                holding, seconds(condition.over) or 0)
        end
        return holding
    end

    -- In-game clock. A window that wraps midnight is handled.
    if condition.time then
        local hour = gameHour()
        if not hour then return false end
        local from = parseHour(condition.time.from or 0)
        local to = parseHour(condition.time.to or 24)
        if from <= to then return hour >= from and hour < to end
        return hour >= from or hour < to
    end

    -- Who is around.
    if condition.players then
        local players = onlinePlayers()
        if players == nil then return false end

        local wanted = condition.players
        local holding
        if wanted.online ~= nil then
            holding = #players == wanted.online
        elseif wanted.atLeast ~= nil then
            holding = #players >= wanted.atLeast
        elseif wanted.name then
            holding = false
            for _, player in ipairs(players) do
                if tostring(player):lower() == tostring(wanted.name):lower() then
                    holding = true
                end
            end
        else
            holding = #players > 0
        end

        if wanted.for_ then
            return heldFor(record, "players", holding, seconds(wanted.for_) or 0)
        end
        return holding
    end

    -- An active alert, by id or by severity.
    if condition.alert then
        if condition.alert == true or condition.alert == "*" then
            return context.alerts.count() > 0
        end
        return context.alerts.get(condition.alert) ~= nil
    end
    if condition.severity then
        return context.alerts.countAtLeast(condition.severity) > 0
    end

    -- A node being online, or not.
    if condition.node then
        local node = state.get("nodes." .. condition.node)
        local online = node ~= nil and node.online == true
        if condition.online ~= nil then return online == condition.online end
        return online
    end

    return false
end

rules.evaluate = evaluate

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

--- Run whatever `do_`/`then_` asked for. Accepts a string, a list, or a table.
local function perform(rule, action, phase)
    if action == nil then return end

    if type(action) == "string" then
        local moduleId, actionId = action:match("^(.-)%.([^%.]+)$")
        if not moduleId then
            log.warn("rule '%s': '%s' is not a module.action", rule.id, action)
            return
        end

        acting = true
        local ok, err = context.modules.invoke(moduleId, actionId)
        acting = false

        if ok then
            log.info("rule '%s' %s: %s", rule.id, phase, action)
        else
            log.warn("rule '%s' could not run %s: %s", rule.id, action, tostring(err))
        end
        return
    end

    if type(action) ~= "table" then return end

    -- A list of actions.
    if #action > 0 then
        for _, child in ipairs(action) do perform(rule, child, phase) end
        return
    end

    if action.alert then
        context.alerts.raise({
            id = "rule." .. rule.id,
            source = "rules",
            severity = action.alert.severity or "warning",
            message = action.alert.message or ("rule " .. rule.id .. " fired"),
        })
        return
    end

    if action.clearAlert then
        context.alerts.clear("rule." .. rule.id)
        return
    end

    if action.say then
        bus.emit("rules.say", { rule = rule.id, message = action.say })
        return
    end
end

---------------------------------------------------------------------------
-- The engine
---------------------------------------------------------------------------

local function recordFor(id)
    runtime[id] = runtime[id] or { phase = "idle", timers = {} }
    return runtime[id]
end

--- Does the module this action names actually exist?
-- A preset pointed at a machine you do not have would otherwise warn on every
-- tick; better to say it once and skip.
local function actionable(rule, action)
    if type(action) == "string" then
        local moduleId = action:match("^(.-)%.")
        if moduleId and not context.modules.has(moduleId) then
            if not rule.__warned then
                log.warn("rule '%s' refers to '%s', which is not loaded here",
                    rule.id, moduleId)
                rule.__warned = true
            end
            return false
        end
    elseif type(action) == "table" and #action > 0 then
        for _, child in ipairs(action) do
            if not actionable(rule, child) then return false end
        end
    end
    return true
end

--- Which modules a rule touches, so a manual press can release it.
local function modulesOf(action, into)
    into = into or {}
    if type(action) == "string" then
        local moduleId = action:match("^(.-)%.")
        if moduleId then into[moduleId] = true end
    elseif type(action) == "table" then
        for _, child in ipairs(action) do modulesOf(child, into) end
    end
    return into
end

local function enter(rule, record)
    if not actionable(rule, rule.do_) then return end
    record.phase = "acting"
    record.enteredAt = util.nowMs()
    record.fired = (record.fired or 0) + 1
    record.timers = {}

    local after = rule.after and seconds(rule.after)
    record.deadline = after and (record.enteredAt + after * 1000) or nil

    perform(rule, rule.do_, "entered")
    bus.emit("rules.entered", { id = rule.id })
end

local function leave(rule, record, reason)
    record.phase = "idle"
    record.leftAt = util.nowMs()
    record.lastReason = reason
    record.deadline = nil
    record.timers = {}

    perform(rule, rule.then_, "left (" .. reason .. ")")
    bus.emit("rules.left", { id = rule.id, reason = reason })
end

--- One pass over every rule.
function rules.tick()
    if not settings.enabled or not context then return end

    for _, rule in ipairs(definitions) do
        if rule.enabled ~= false then
            local record = recordFor(rule.id)
            local ok, err = pcall(function()
                if record.phase == "acting" then
                    -- Exit on the condition or the deadline, whichever first.
                    if rule.until_ and evaluate(rule.until_, record) then
                        leave(rule, record, "condition")
                    elseif record.deadline and util.nowMs() >= record.deadline then
                        leave(rule, record, "timeout")
                    end
                    return
                end

                local entering = evaluate(rule.when, record)

                -- A rule that a human overrode waits for its condition to fall
                -- away before it is allowed to act again.
                if record.yielded then
                    if not entering then record.yielded = false end
                    return
                end

                if entering then
                    local cooldown = rule.cooldown and seconds(rule.cooldown)
                    if cooldown and record.leftAt
                        and (util.nowMs() - record.leftAt) < cooldown * 1000 then
                        return
                    end
                    enter(rule, record)
                end
            end)

            if not ok then
                log.error("rule '%s' failed: %s", rule.id, tostring(err))
                record.error = tostring(err)
            else
                record.error = nil
            end
        end
    end

    rules.publish()
end

--- A person pressed a button: release any rule acting on that module.
local function onManualAction(payload)
    if acting then return end          -- that was us

    for _, rule in ipairs(definitions) do
        local record = runtime[rule.id]
        if record and record.phase == "acting" then
            if modulesOf(rule.do_)[payload.id] or modulesOf(rule.then_)[payload.id] then
                record.phase = "idle"
                record.yielded = true
                record.deadline = nil
                record.timers = {}
                log.info("rule '%s' released: %s was operated by hand", rule.id, payload.id)
                bus.emit("rules.yielded", { id = rule.id, module = payload.id })
            end
        end
    end
end

--- Wire the tick and the listeners, once.
-- Separate from `start` because a base can boot with no rules at all and then
-- get its first one from the editor; without this the engine would sit there
-- unscheduled until the next reboot.
local function arm()
    if armed or not context or not settings.enabled then return false end
    if #definitions == 0 then return false end

    armed = true
    bus.on("module.action", onManualAction, { owner = "rules" })
    context.scheduler.every(settings.interval, rules.tick,
        { name = "rules.tick", owner = "rules" })

    log.info("rules on: %d rule(s), every %.1fs", #definitions, settings.interval)
    return true
end

---------------------------------------------------------------------------
-- Inspection
---------------------------------------------------------------------------

--- Every rule with its live state, for the UI.
function rules.list()
    local list = {}
    for _, rule in ipairs(definitions) do
        local record = runtime[rule.id] or {}
        list[#list + 1] = {
            id = rule.id,
            name = rule.name or rule.id,
            enabled = rule.enabled ~= false,
            phase = record.phase or "idle",
            yielded = record.yielded == true,
            fired = record.fired or 0,
            enteredAt = record.enteredAt,
            leftAt = record.leftAt,
            lastReason = record.lastReason,
            error = record.error,
            remaining = record.deadline
                and math.max(0, (record.deadline - util.nowMs()) / 1000) or nil,
        }
    end
    return list
end

function rules.publish()
    state.set("rules.list", rules.list())
end

function rules.get(id)
    for _, rule in ipairs(definitions) do
        if rule.id == id then return rule end
    end
    return nil
end

function rules.definitions() return definitions end

--- Turn a rule on or off, and remember it.
function rules.setEnabled(id, enabled)
    local list = rules.current()
    local found = false

    for _, rule in ipairs(list) do
        if rule.id == id then
            rule.enabled = enabled and true or false
            found = true
        end
    end
    if not found then return false end

    if not enabled and runtime[id] then runtime[id].phase = "idle" end
    return rules.save(list)
end

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------

--- The rules in force: the edited set if there is one, else config.
-- A copy, always: the editor mutates what it gets back, and the config table it
-- would otherwise be handed is the live one.
function rules.current()
    local override = persistence.load(rules.STORE, nil)
    if type(override) == "table" and type(override.rules) == "table" then
        return util.deepCopy(override.rules), "editor"
    end
    return util.deepCopy((context and context.config.get("rules.rules", {})) or {}), "config"
end

function rules.hasOverride()
    local _, source = rules.current()
    return source == "editor"
end

--- Persist an edited set and apply it straight away.
function rules.save(list)
    if type(list) ~= "table" then return false, "a rule list is required" end

    local ok, err = persistence.save(rules.STORE, {
        savedAt = util.nowMs(),
        rules = list,
    })
    if not ok then return false, err end

    log.info("saved %d rule(s) from the editor", #list)
    rules.reload()
    bus.emit("rules.changed", { count = #list })
    return true
end

--- Throw the edited set away and go back to config.
function rules.resetToConfig()
    persistence.delete(rules.STORE)
    rules.reload()
    bus.emit("rules.changed", { reset = true })
    return true
end

--- Re-read the rules, keeping the engine running.
function rules.reload()
    if not context then return false end

    local list = rules.current()
    definitions = {}
    for _, rule in ipairs(list) do
        if type(rule) == "table" and rule.id then
            definitions[#definitions + 1] = util.deepCopy(rule)
        end
    end

    -- Drop runtime state for rules that no longer exist.
    for id in pairs(runtime) do
        if not rules.get(id) then runtime[id] = nil end
    end

    arm()
    rules.publish()
    return true
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

function rules.start(ctx, options)
    context = ctx
    for key, value in pairs(options or {}) do settings[key] = value end

    definitions = {}
    runtime = {}
    armed = false
    bus.offOwner("rules")
    state.set("rules.enabled", settings.enabled)

    rules.reload()   -- arms the tick if there is anything to run

    if not armed then
        log.info("rules: %s", settings.enabled and "none configured" or "disabled")
        rules.publish()
        return false
    end

    rules.publish()
    return true
end

function rules.shutdown()
    bus.offOwner("rules")
    armed = false
end

return rules

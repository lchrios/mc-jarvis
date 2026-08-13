--- What is worth telling the player, and what is noise.
--
-- The notifier module owns the *how* - a Chat Box, a Speaker, rate limiting.
-- This owns the *what*: a catalogue of things that happen in the base, each one
-- something you can switch on or off from the panel.
--
-- Every topic names a real event on the bus and turns its payload into one
-- line of chat. Nothing here invents an event: if a topic is listed, something
-- in BaseOS emits it.
--
-- Most ship off. A base that narrates every peripheral it rediscovers is a base
-- nobody reads, and the point of the list is that you choose.

local util = require("core.util")
local logger = require("core.logger")
local bus = require("core.event_bus")
local state = require("core.state")
local persistence = require("services.persistence")

local log = logger.scoped("notifications")

local notifications = {}

--- Choices made on screen live here; `config/notifications.lua` stays
--- hand-editable, the same split the rules and the base plan use.
notifications.STORE = "notifications"

local context = nil
local overrides = nil   -- [topicId] = bool, or nil while unread
local counts = {}       -- [topicId] = { fired, announced }
local started = false

---------------------------------------------------------------------------
-- The catalogue
---------------------------------------------------------------------------

--- A player name out of whatever the detector handed over.
local function firstPlayer(players)
    local first = (players or {})[1]
    if first == nil then return "somebody" end
    if type(first) == "table" then return tostring(first.name or "somebody") end
    return tostring(first)
end

-- `format` returns the line to say, or nil to stay quiet for this payload.
-- That is how a topic filters: `module_error` listens to every status change
-- and only speaks for the ones that are errors.
notifications.CATALOGUE = {
    {
        id = "alerts", label = "Alerts", default = true, severity = "warning",
        description = "Warnings and critical alerts, as they are raised",
        -- Handled inside the notifier, which already has the cooldown and the
        -- clear-announcement logic for these. Listed here so it can be muted
        -- from the same screen as everything else.
        internal = true,
    },
    {
        id = "player_arrived", label = "Player arrives", default = true,
        event = "presence.entered", severity = "info",
        description = "Somebody walks into a zone with a detector",
        format = function(payload)
            return ("%s arrived at %s"):format(
                firstPlayer(payload.players), tostring(payload.name or payload.zone))
        end,
    },
    {
        id = "player_left", label = "Player leaves", default = false,
        event = "presence.left", severity = "info",
        description = "The last player walks out of a zone",
        format = function(payload)
            return ("nobody left at %s"):format(tostring(payload.name or payload.zone))
        end,
    },
    {
        id = "node_offline", label = "Node goes silent", default = true,
        event = "node.offline", severity = "critical",
        description = "Another computer stopped reporting",
        format = function(payload)
            return ("node %s stopped reporting"):format(tostring(payload.node))
        end,
    },
    {
        id = "peer_lost", label = "Peer lost", default = false,
        event = "network.peer_lost", severity = "warning",
        description = "A computer dropped off the rednet",
        format = function(payload)
            return ("lost contact with %s"):format(tostring(payload.name))
        end,
    },
    {
        id = "module_error", label = "Module fails", default = true,
        event = "module.status_changed", severity = "critical",
        description = "A system goes into error",
        format = function(payload)
            if payload.status ~= "error" then return nil end
            return ("%s is in error%s"):format(tostring(payload.id),
                payload.text and (": " .. tostring(payload.text)) or "")
        end,
    },
    {
        id = "module_recovered", label = "Module recovers", default = false,
        event = "module.status_changed", severity = "info",
        description = "A system comes back from an error",
        format = function(payload)
            if payload.previous ~= "error" or payload.status == "error" then return nil end
            return ("%s recovered (%s)"):format(tostring(payload.id), tostring(payload.status))
        end,
    },
    {
        id = "device_lost", label = "Device disappears", default = false,
        event = "peripheral.detached", severity = "warning",
        description = "A peripheral stops answering",
        format = function(payload)
            return ("lost the peripheral %s"):format(tostring(payload.name))
        end,
    },
    {
        id = "device_found", label = "Device appears", default = false,
        event = "peripheral.attached", severity = "info",
        description = "A peripheral joins the network",
        format = function(payload)
            return ("found the peripheral %s"):format(tostring(payload.name))
        end,
    },
    {
        id = "rule_message", label = "Rule messages", default = true,
        event = "rules.say", severity = "info",
        description = 'What a rule with a `say` action wants said',
        format = function(payload) return tostring(payload.message) end,
    },
    {
        id = "rule_fired", label = "Rule acts", default = false,
        event = "rules.entered", severity = "info",
        description = "A rule took control of something",
        format = function(payload) return ("rule %s is acting"):format(tostring(payload.id)) end,
    },
    {
        id = "rule_done", label = "Rule finishes", default = false,
        event = "rules.left", severity = "info",
        description = "A rule let go, and why",
        format = function(payload)
            return ("rule %s finished (%s)"):format(
                tostring(payload.id), tostring(payload.reason))
        end,
    },
    {
        id = "rule_yielded", label = "Rule gives way", default = false,
        event = "rules.yielded", severity = "info",
        description = "Somebody operated by hand what a rule was holding",
        format = function(payload)
            return ("rule %s let go: %s was operated by hand"):format(
                tostring(payload.id), tostring(payload.module))
        end,
    },
    {
        id = "farm_toggled", label = "Farm starts or stops", default = false,
        event = "farm.status_changed", severity = "info",
        description = "A farm is started or stopped, by anyone",
        format = function(payload)
            return ("%s is now %s"):format(tostring(payload.id), tostring(payload.status))
        end,
    },
    {
        id = "access_denied", label = "Access denied", default = true,
        event = "security.denied", severity = "warning",
        description = "Somebody tried a protected action without the rights",
        format = function(payload)
            return ("%s was refused '%s'%s"):format(
                tostring(payload.player or "somebody"), tostring(payload.action),
                payload.reason and (" - " .. tostring(payload.reason)) or "")
        end,
    },
    {
        id = "user_added", label = "User registered", default = true,
        event = "security.user_added", severity = "warning",
        description = "Somebody was given access to the panel",
        format = function(payload)
            return ("%s was registered as %s%s"):format(
                tostring(payload.player), tostring(payload.role),
                payload.addedBy and (" by " .. tostring(payload.addedBy)) or "")
        end,
    },
    {
        id = "session_opened", label = "Badge in", default = false,
        event = "security.session_opened", severity = "info",
        description = "Somebody identified themselves at the detector",
        format = function(payload)
            return ("%s badged in as %s"):format(
                tostring(payload.player), tostring(payload.role))
        end,
    },
}

function notifications.get(id)
    for _, topic in ipairs(notifications.CATALOGUE) do
        if topic.id == id then return topic end
    end
    return nil
end

---------------------------------------------------------------------------
-- Which ones are on
---------------------------------------------------------------------------

local function loadOverrides()
    if overrides then return overrides end
    local stored = persistence.load(notifications.STORE, nil)
    overrides = (type(stored) == "table" and type(stored.topics) == "table")
        and stored.topics or {}
    return overrides
end

function notifications.hasOverride()
    return next(loadOverrides()) ~= nil
end

--- Is this topic on? Panel choice first, then config, then the shipped default.
function notifications.enabled(id)
    local chosen = loadOverrides()[id]
    if chosen ~= nil then return chosen == true end

    local configured = context
        and context.config.get("notifications.topics." .. id, nil)
    if configured ~= nil then return configured == true end

    local topic = notifications.get(id)
    return topic ~= nil and topic.default == true
end

function notifications.setEnabled(id, enabled)
    if not notifications.get(id) then return false, "no such topic" end

    loadOverrides()[id] = enabled and true or false

    local ok, err = persistence.save(notifications.STORE, {
        savedAt = util.nowMs(),
        topics = overrides,
    })
    if not ok then return false, err end

    log.info("%s: %s", id, enabled and "on" or "off")
    notifications.publish()
    bus.emit("notifications.changed", { id = id, enabled = enabled == true })
    return true
end

--- Back to what config says.
function notifications.resetToConfig()
    persistence.delete(notifications.STORE)
    overrides = {}
    notifications.publish()
    bus.emit("notifications.changed", { reset = true })
    return true
end

--- The catalogue with live state, for the screen.
function notifications.list()
    local list = {}
    for _, topic in ipairs(notifications.CATALOGUE) do
        local count = counts[topic.id] or {}
        list[#list + 1] = {
            id = topic.id,
            label = topic.label,
            description = topic.description,
            severity = topic.severity,
            enabled = notifications.enabled(topic.id),
            fired = count.fired or 0,
            announced = count.announced or 0,
        }
    end
    return list
end

function notifications.publish()
    local on = 0
    for _, topic in ipairs(notifications.list()) do
        if topic.enabled then on = on + 1 end
    end
    state.set("notifications.on", on)
    state.set("notifications.total", #notifications.CATALOGUE)
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

--- Announce one topic, if it is on and has something to say.
local function fire(topic, payload)
    if not notifications.enabled(topic.id) then return end

    counts[topic.id] = counts[topic.id] or { fired = 0, announced = 0 }
    counts[topic.id].fired = counts[topic.id].fired + 1

    local ok, message = pcall(topic.format, payload or {})
    if not ok then
        log.warn("topic '%s' could not format its message: %s", topic.id, tostring(message))
        return
    end
    if message == nil or message == "" then return end

    counts[topic.id].announced = counts[topic.id].announced + 1

    -- One normalised event. Whoever can reach the player picks it up; on a
    -- computer with no Chat Box nothing listens and nothing breaks.
    bus.emit("notify", {
        topic = topic.id,
        severity = topic.severity or "info",
        message = message,
    })
end

--- Subscribe the catalogue to the bus. Called once from `core.app`.
function notifications.start(ctx)
    context = ctx
    overrides = nil
    counts = {}

    bus.offOwner("notifications")

    -- One subscription per distinct event, however many topics share it.
    local byEvent = {}
    for _, topic in ipairs(notifications.CATALOGUE) do
        if topic.event and type(topic.format) == "function" then
            byEvent[topic.event] = byEvent[topic.event] or {}
            table.insert(byEvent[topic.event], topic)
        end
    end

    for event, topics in pairs(byEvent) do
        bus.on(event, function(payload)
            for _, topic in ipairs(topics) do fire(topic, payload) end
        end, { owner = "notifications" })
    end

    started = true
    notifications.publish()

    local on = state.get("notifications.on") or 0
    log.info("notifications: %d of %d topics on", on, #notifications.CATALOGUE)
    return true
end

function notifications.shutdown()
    bus.offOwner("notifications")
    started = false
end

function notifications.isStarted() return started end

return notifications

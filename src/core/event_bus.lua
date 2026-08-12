--- In-process publish/subscribe bus.
--
-- Every part of BaseOS talks through this bus instead of calling each other
-- directly. Raw CC events are re-published here by `core.app`, so a module can
-- subscribe to `monitor_touch` exactly like it subscribes to `power.low`.
--
--   bus.on("power.low", function(payload) ... end)
--   bus.emit("power.low", { percentage = 14 })
--
-- Wildcards: subscribing to "power.*" or "*" is allowed. Wildcard handlers
-- receive the event name as their first argument, exact handlers do not.

local logger = require("core.logger")

local log = logger.scoped("events")

local bus = {}

local exact = {}      -- [event] = { subscription, ... }
local wildcards = {}  -- { { prefix = "power.", subscription } , ... }
local nextId = 0

local function newSubscription(event, handler, options)
    nextId = nextId + 1
    return {
        id = nextId,
        event = event,
        handler = handler,
        once = options and options.once or false,
        priority = options and options.priority or 0,
        owner = options and options.owner or nil,
        alive = true,
    }
end

local function insertSorted(list, subscription)
    local index = #list + 1
    for position, existing in ipairs(list) do
        if subscription.priority > existing.priority then
            index = position
            break
        end
    end
    table.insert(list, index, subscription)
end

--- Subscribe to an event.
-- @param event string event name, optionally ending in "*"
-- @param handler function
-- @param options table|nil { once = bool, priority = number, owner = any }
-- @return function unsubscribe
function bus.on(event, handler, options)
    if type(event) ~= "string" then error("event name must be a string", 2) end
    if type(handler) ~= "function" then error("handler must be a function", 2) end

    local subscription = newSubscription(event, handler, options)

    if event == "*" or event:sub(-1) == "*" then
        subscription.prefix = event == "*" and "" or event:sub(1, -2)
        insertSorted(wildcards, subscription)
    else
        exact[event] = exact[event] or {}
        insertSorted(exact[event], subscription)
    end

    return function() bus.off(subscription) end
end

--- Subscribe and automatically unsubscribe after the first call.
function bus.once(event, handler, options)
    options = options or {}
    options.once = true
    return bus.on(event, handler, options)
end

--- Remove a subscription (accepts the handle returned by `on`'s subscription).
function bus.off(subscription)
    if type(subscription) == "function" then
        -- Callers may pass the unsubscribe closure back in; just run it.
        return subscription()
    end
    if type(subscription) ~= "table" then return false end
    subscription.alive = false

    local list = subscription.prefix ~= nil and wildcards or exact[subscription.event]
    if not list then return false end
    for index, existing in ipairs(list) do
        if existing == subscription then
            table.remove(list, index)
            return true
        end
    end
    return false
end

--- Remove every subscription registered with `options.owner == owner`.
function bus.offOwner(owner)
    local removed = 0
    local function sweep(list)
        for index = #list, 1, -1 do
            if list[index].owner == owner then
                list[index].alive = false
                table.remove(list, index)
                removed = removed + 1
            end
        end
    end
    for _, list in pairs(exact) do sweep(list) end
    sweep(wildcards)
    return removed
end

local function invoke(subscription, includeName, event, ...)
    if not subscription.alive then return end
    if subscription.once then bus.off(subscription) end

    local ok, err
    if includeName then
        ok, err = pcall(subscription.handler, event, ...)
    else
        ok, err = pcall(subscription.handler, ...)
    end

    if not ok then
        log.error("handler for '%s' failed: %s", event, tostring(err))
    end
end

--- Publish an event. Handler errors are logged and never propagate.
-- @return number how many handlers were invoked
function bus.emit(event, ...)
    if type(event) ~= "string" then error("event name must be a string", 2) end
    local invoked = 0

    local direct = exact[event]
    if direct then
        -- Iterate a snapshot: handlers are allowed to subscribe/unsubscribe.
        local snapshot = { table.unpack(direct) }
        for _, subscription in ipairs(snapshot) do
            invoke(subscription, false, event, ...)
            invoked = invoked + 1
        end
    end

    if #wildcards > 0 then
        local snapshot = { table.unpack(wildcards) }
        for _, subscription in ipairs(snapshot) do
            if subscription.prefix == "" or event:sub(1, #subscription.prefix) == subscription.prefix then
                invoke(subscription, true, event, ...)
                invoked = invoked + 1
            end
        end
    end

    return invoked
end

--- Diagnostics: number of live subscriptions.
function bus.subscriptionCount()
    local total = #wildcards
    for _, list in pairs(exact) do total = total + #list end
    return total
end

--- Drop every subscription. Used by tests and by a clean shutdown.
function bus.reset()
    exact = {}
    wildcards = {}
end

return bus

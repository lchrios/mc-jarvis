--- Central state store.
--
-- One tree, one way in. Nothing in BaseOS should keep long lived data in
-- globals or module upvalues that other subsystems need to read.
--
--   state.set("modules.demo_farm.status", "running")
--   state.get("modules.demo_farm.status", "unknown")
--   bus.on("state.changed", function(payload) ... end)
--
-- Every write publishes `state.changed` on the event bus with
-- { path = ..., value = ..., previous = ... }. That is the only way to be told
-- about a change: there used to be a second, per-path watcher mechanism here as
-- well, and in the whole project nothing ever registered one. Two ways to do
-- the same thing, one of them dead, is worse than one - so it went. Filter by
-- `payload.path` in a bus handler, or subscribe to `state.*`.

local util = require("core.util")
local bus = require("core.event_bus")

local state = {}

local tree = {
    system = {},      -- computer id, uptime, version, monitor info
    modules = {},     -- per module runtime snapshot
    peripherals = {}, -- discovered peripherals and alias resolution
    network = {},     -- node status
    alerts = {},      -- active alerts (managed by services.alerts)
    ui = {},          -- current screen, dirty flag helpers
}

--- Read a value. `path` is a dotted string; nil returns the whole tree.
function state.get(path, default)
    if path == nil then return tree end
    return util.dig(tree, path, default)
end

--- Read a value and always return a table (creating it when missing).
function state.table(path)
    local value = util.dig(tree, path)
    if type(value) ~= "table" then
        value = {}
        util.plant(tree, path, value)
    end
    return value
end

local function notify(path, value, previous)
    bus.emit("state.changed", { path = path, value = value, previous = previous })
end

--- Write a value. No-ops (and stays silent) when the value did not change.
function state.set(path, value)
    if type(path) ~= "string" or path == "" then error("state.set requires a path", 2) end
    local previous = util.dig(tree, path)
    if previous == value and type(value) ~= "table" then return value end
    util.plant(tree, path, value)
    notify(path, value, previous)
    return value
end

--- Merge a table into an existing node instead of replacing it.
function state.patch(path, patch)
    if type(patch) ~= "table" then return state.set(path, patch) end
    local current = util.dig(tree, path)
    local merged = util.deepMerge(type(current) == "table" and current or {}, patch)
    util.plant(tree, path, merged)
    notify(path, merged, current)
    return merged
end

--- Read-modify-write helper.
function state.update(path, fn)
    local current = util.dig(tree, path)
    local updated = fn(current)
    return state.set(path, updated)
end

function state.delete(path)
    local previous = util.dig(tree, path)
    if previous == nil then return nil end
    util.plant(tree, path, nil)
    notify(path, nil, previous)
    return previous
end

--- Plain copy of a subtree, safe to hand to a UI screen or serialise.
function state.snapshot(path)
    return util.deepCopy(path and util.dig(tree, path) or tree)
end

--- Replace the whole tree. Only used on boot / by tests.
function state.reset(initial)
    tree = initial or {
        system = {}, modules = {}, peripherals = {}, network = {}, alerts = {}, ui = {},
    }
    notify("", tree, nil)
end

return state

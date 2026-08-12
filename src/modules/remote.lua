--- Proxy for a module running on another computer.
--
-- Created by `network.telemetry` when a node reports a module the master has
-- not seen before. It reads the last snapshot out of `core.state` and never
-- talks to a peripheral, so the dashboard, the detail screen and the zone tiles
-- treat remote systems exactly like local ones.
--
-- Actions are forwarded to the owning node; nothing is executed here.

local util = require("core.util")

local template = {}

--- Seconds without an update before a proxy stops claiming its data is live.
local STALE_AFTER = 15

--- @param instance table { id, node, moduleId, name, icon }
function template.create(instance)
    local remote = {
        id = instance.id,
        name = instance.name or instance.moduleId,
        icon = instance.icon,
        description = "Runs on node '" .. instance.node .. "'",
        node = instance.node,
        moduleId = instance.moduleId,
        -- No poll: data arrives by push. The staleness check is cheap enough
        -- to ride along with the status call.
        remote = true,
    }

    local statePath = "nodes." .. instance.node .. ".modules." .. instance.moduleId

    function remote.setup(self, ctx)
        self.ctx = ctx
    end

    --- Last snapshot this node sent for this module.
    function remote.snapshot(self)
        return self.ctx and self.ctx.state.get(statePath) or nil
    end

    function remote.age(self)
        local node = self.ctx and self.ctx.state.get("nodes." .. instance.node) or nil
        if not node or not node.lastSeen then return nil end
        return (util.nowMs() - node.lastSeen) / 1000
    end

    function remote.isStale(self)
        local age = remote.age(self)
        return age == nil or age > STALE_AFTER
    end

    function remote.status(self)
        local snapshot = remote.snapshot(self)
        if not snapshot then return "unknown", "NO DATA" end
        if remote.isStale(self) then return "error", "OFFLINE" end
        return snapshot.status or "unknown", snapshot.statusText
    end

    function remote.metrics(self)
        local snapshot = remote.snapshot(self)
        local metrics = snapshot and util.deepCopy(snapshot.metrics or {}) or {}

        local age = remote.age(self)
        metrics[#metrics + 1] = {
            id = "_node", label = "Node", value = instance.node,
        }
        metrics[#metrics + 1] = {
            id = "_age", label = "Last update", value = age,
            format = function(value)
                if value == nil then return "never" end
                return util.formatDuration(value) .. " ago"
            end,
        }
        return metrics
    end

    function remote.tile(self)
        local snapshot = remote.snapshot(self)
        if not snapshot then return { lines = { "no data" } } end
        if remote.isStale(self) then
            return { lines = { "node offline" }, status = "error", statusText = "OFFLINE" }
        end
        return { lines = snapshot.lines or {}, gauge = snapshot.gauge }
    end

    --- The node described its actions; running one sends it back over rednet.
    function remote.actions(self)
        local snapshot = remote.snapshot(self)
        local stale = remote.isStale(self)
        local actions = {}

        for _, action in ipairs((snapshot and snapshot.actions) or {}) do
            actions[#actions + 1] = {
                id = action.id,
                label = action.label,
                style = action.style,
                enabled = action.enabled ~= false and not stale,
                run = function()
                    local telemetry = self.ctx.require("network.telemetry")
                    local ok, err = telemetry.sendAction(
                        self.ctx, instance.node, instance.moduleId, action.id)
                    if not ok then error(err or "could not reach the node", 0) end
                end,
            }
        end
        return actions
    end

    return remote
end

return template

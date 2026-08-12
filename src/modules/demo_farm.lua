--- Demo farm: a fully simulated module.
--
-- It requires no peripherals, so the whole UI stack (dashboard tiles, detail
-- view, actions, metrics, alerts, events) can be exercised before a single
-- real machine is wired up. Use it as a template - the shape of a real farm
-- module is identical, only `poll` reads a peripheral instead of a random
-- number generator.
--
-- Remove it from `config/modules.lua` once real modules exist.

local util = require("core.util")

local farm = {}

farm.id = "demo_farm"
farm.name = "Demo Farm"
farm.icon = "F"
farm.description = "Simulated farm used to validate the UI and event flow"
farm.pollInterval = 1

-- Hysteresis: raise the alert at 90% but do not clear it until the buffer has
-- actually drained to 80%. Without the gap a value hovering on the threshold
-- raises and clears the alert every poll and floods the log.
local BUFFER_ALERT_ON = 0.90
local BUFFER_ALERT_OFF = 0.80

function farm.setup(self, ctx)
    self.ctx = ctx
    self.running = true
    self.itemsPerMinute = 120
    self.buffer = 0.35
    self.powerUsage = 12400
    self.totalItems = 0
    self.startedAt = util.nowMs()
end

--- Move a value by a random amount, kept inside [min, max].
local function drift(value, amount, minimum, maximum)
    local next_ = value + (math.random() * 2 - 1) * amount
    return util.clamp(next_, minimum, maximum)
end

function farm.poll(self)
    if not self.running then
        self.itemsPerMinute = 0
        self.powerUsage = 0
        -- A stopped farm slowly drains its buffer into the network.
        self.buffer = util.clamp(self.buffer - 0.01, 0, 1)
        return
    end

    self.itemsPerMinute = math.floor(drift(self.itemsPerMinute, 12, 40, 260))
    self.powerUsage = math.floor(drift(self.powerUsage, 900, 4000, 24000))
    self.buffer = drift(self.buffer, 0.05, 0, 1)
    self.totalItems = self.totalItems + self.itemsPerMinute / 60

    if self.buffer >= BUFFER_ALERT_ON then
        self.bufferBackedUp = true
    elseif self.buffer <= BUFFER_ALERT_OFF then
        self.bufferBackedUp = false
    end

    self.ctx.alerts.toggle(self.bufferBackedUp, {
        id = "demo_farm.buffer_full",
        source = farm.id,
        severity = "warning",
        message = "Demo Farm output buffer is nearly full",
    })
end

function farm.status(self)
    if not self.running then return "stopped", "STOPPED" end
    if self.bufferBackedUp then return "warning", "BACKED UP" end
    return "running", "RUNNING"
end

function farm.metrics(self)
    return {
        { id = "rate", label = "Items/min", value = self.itemsPerMinute or 0 },
        { id = "buffer", label = "Buffer", kind = "percent", value = self.buffer or 0 },
        { id = "power", label = "Power", value = self.powerUsage or 0, unit = "FE/t" },
        { id = "produced", label = "Produced", value = math.floor(self.totalItems or 0) },
        { id = "runtime", label = "Runtime", value = (util.nowMs() - (self.startedAt or 0)) / 1000,
          format = function(value) return util.formatDuration(value) end },
    }
end

function farm.tile(self)
    return {
        lines = { (self.itemsPerMinute or 0) .. " it/min" },
        gauge = self.buffer or 0,
    }
end

function farm.setRunning(self, running)
    if self.running == running then return end
    self.running = running
    self.ctx.bus.emit("farm.status_changed", {
        id = farm.id,
        status = running and "running" or "stopped",
    })
end

function farm.actions(self)
    return {
        { id = "start", label = "START", style = self.running and "default" or "primary",
          enabled = not self.running,
          run = function() farm.setRunning(self, true) end },
        { id = "stop", label = "STOP", style = "danger", enabled = self.running,
          run = function() farm.setRunning(self, false) end },
        { id = "flush", label = "FLUSH",
          run = function()
              self.buffer = 0
              self.bufferBackedUp = false
              self.ctx.alerts.clear("demo_farm.buffer_full")
          end },
    }
end

function farm.stop(self)
    -- `stop` can run before `setup` succeeded, so never assume a context.
    if self.ctx then self.ctx.alerts.clear("demo_farm.buffer_full") end
end

return farm

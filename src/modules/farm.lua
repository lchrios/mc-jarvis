--- Generic farm template.
--
-- This file is not a module: it is a *template* that `config/modules.lua`
-- instantiates as many times as you have farms. Adding a real farm is a config
-- entry, not new code:
--
--   instances = {
--     { id = "mob_farm", template = "farm", name = "Mob Farm", icon = "M",
--       settings = {
--         output  = { type = "minecraft:barrel" },
--         control = { kind = "redstone", side = "back" },
--       } },
--   }
--
-- It reads a real output inventory through `adapters.inventory`, so it works
-- with any container any mod exposes as a CC inventory, and drives the farm
-- with either the computer's own redstone or an Advanced Peripherals Redstone
-- Integrator.
--
-- Throughput caveat: the rate is measured from what lands in the output
-- buffer. If a pipe drains the buffer between two polls, that fraction is
-- invisible. Only positive deltas are counted, so an extraction never shows up
-- as negative production, but a farm whose output is pulled instantly will
-- read low. Point the module at the buffer *before* the extraction to get a
-- true reading.

local util = require("core.util")

local template = {}

local DEFAULTS = {
    -- Peripheral matcher for the output container.
    output = { method = "list" },

    -- How the farm is switched on and off.
    --   { kind = "none" }                              read-only monitoring
    --   { kind = "redstone", side = "back" }           the computer's own redstone
    --   { kind = "integrator", side = "top",           an AP Redstone Integrator
    --     match = { type = "redstoneIntegrator" } }
    -- `invert = true` for farms that run when the signal is *off*.
    control = { kind = "none", side = "back", invert = false },

    -- Buffer fill that raises the "backed up" alert, and the lower level it
    -- has to drain to before the alert clears (hysteresis, never equal).
    bufferWarn = 0.90,
    bufferClear = 0.75,

    -- Seconds without a single new item before the farm counts as idle.
    idleAfter = 90,
    alertWhenIdle = false,

    -- Expected items/min. Only used to colour the rate; nil disables it.
    targetRate = nil,

    -- Only count these item names, e.g. { "minecraft:rotten_flesh" }.
    countItems = nil,
}

---------------------------------------------------------------------------
-- Control
---------------------------------------------------------------------------

local function controlSignal(self, wanted)
    return self.settings.control.invert and (not wanted) or wanted
end

--- Read the current on/off state from whatever drives the farm.
local function readControl(self)
    local control = self.settings.control
    if control.kind == "none" then return true end

    local raw
    if control.kind == "integrator" then
        local integrator = self.ctx.peripherals.get(self.id .. ".control")
        if not integrator then return nil end
        raw = integrator.call("getOutput", control.side) == true
    else
        if not redstone then return nil end
        local ok, value = pcall(redstone.getOutput, control.side)
        if not ok then return nil end
        raw = value == true
    end

    return control.invert and (not raw) or raw
end

--- Drive the farm. Returns ok, error.
local function writeControl(self, wanted)
    local control = self.settings.control
    if control.kind == "none" then return false, "this farm has no control configured" end

    local signal = controlSignal(self, wanted)

    if control.kind == "integrator" then
        local integrator = self.ctx.peripherals.get(self.id .. ".control")
        if not integrator then return false, "redstone integrator not connected" end
        local _, err = integrator.call("setOutput", control.side, signal)
        if err then return false, err end
    else
        if not redstone then return false, "no redstone API available" end
        local ok, err = pcall(redstone.setOutput, control.side, signal)
        if not ok then return false, tostring(err) end
    end

    self.running = wanted
    self.ctx.bus.emit("farm.status_changed", {
        id = self.id,
        status = wanted and "running" or "stopped",
    })
    return true
end

---------------------------------------------------------------------------
-- Reading the output buffer
---------------------------------------------------------------------------

local function countMatching(items, filter)
    if not filter then
        local total = 0
        for _, item in ipairs(items) do total = total + item.count end
        return total
    end

    local wanted = {}
    for _, name in ipairs(filter) do wanted[name] = true end

    local total = 0
    for _, item in ipairs(items) do
        if wanted[item.name] then total = total + item.count end
    end
    return total
end

---------------------------------------------------------------------------
-- Template
---------------------------------------------------------------------------

--- Build a module definition for one farm instance.
-- @param instance table { id, name, icon, pollInterval, settings }
function template.create(instance)
    if type(instance) ~= "table" or type(instance.id) ~= "string" then
        error("farm instances need an id", 2)
    end

    local settings = util.deepMerge(DEFAULTS, instance.settings or {})
    if settings.bufferClear >= settings.bufferWarn then
        settings.bufferClear = settings.bufferWarn - 0.1
    end

    local farm = {
        id = instance.id,
        name = instance.name or instance.id,
        icon = instance.icon or "F",
        description = instance.description or "Farm monitored through its output buffer",
        pollInterval = instance.pollInterval or 5,
        settings = settings,
    }

    -- Peripheral requirements are derived from the instance config, so each
    -- farm gets its own aliases and can fail independently.
    local outputMatcher = util.deepCopy(settings.output)
    outputMatcher.alias = farm.id .. ".output"
    outputMatcher.optional = false
    if not outputMatcher.type and not outputMatcher.name then
        outputMatcher.method = outputMatcher.method or "list"
    end
    farm.peripherals = { outputMatcher }

    if settings.control.kind == "integrator" then
        local controlMatcher = util.deepCopy(settings.control.match or { type = "redstoneIntegrator" })
        controlMatcher.alias = farm.id .. ".control"
        controlMatcher.optional = false
        farm.peripherals[#farm.peripherals + 1] = controlMatcher
    end

    function farm.setup(self, ctx)
        self.ctx = ctx
        self.itemsPerMinute = 0
        self.produced = 0
        self.buffer = 0
        self.itemCount = 0
        self.slotsUsed = 0
        self.slotCount = 0
        self.lastCount = nil
        self.lastPollAt = nil
        self.lastProductionAt = util.nowMs()
        self.backedUp = false
        -- Adopt whatever state the farm is already in: a reboot must not
        -- silently start or stop machinery.
        self.running = readControl(self)
    end

    function farm.poll(self)
        local output = self.ctx.adapters.forAlias(self.id .. ".output", "inventory")
        if not output then
            self.available = false
            return
        end

        local items = output.items()
        local now = util.nowMs()

        self.itemCount = countMatching(items, self.settings.countItems)
        self.slotCount = output.slots()
        self.slotsUsed = #items
        self.buffer = self.slotCount > 0 and (self.slotsUsed / self.slotCount) or 0

        -- Only positive deltas count as production; a drained buffer is not
        -- negative output.
        if self.lastCount ~= nil and self.lastPollAt then
            local delta = self.itemCount - self.lastCount
            local minutes = (now - self.lastPollAt) / 60000
            if delta > 0 and minutes > 0 then
                self.produced = self.produced + delta
                self.itemsPerMinute = delta / minutes
                self.lastProductionAt = now
            elseif minutes > 0 then
                self.itemsPerMinute = 0
            end
        end
        self.lastCount = self.itemCount
        self.lastPollAt = now

        self.running = readControl(self)

        if self.buffer >= self.settings.bufferWarn then
            self.backedUp = true
        elseif self.buffer <= self.settings.bufferClear then
            self.backedUp = false
        end

        self.ctx.alerts.toggle(self.backedUp, {
            id = self.id .. ".buffer_full",
            source = self.id,
            severity = "warning",
            message = self.name .. ": output buffer is nearly full",
            data = { buffer = self.buffer },
        })

        if self.settings.alertWhenIdle then
            self.ctx.alerts.toggle(farm.isIdle(self) and self.running ~= false, {
                id = self.id .. ".idle",
                source = self.id,
                severity = "warning",
                message = self.name .. ": no output for " .. util.formatDuration(self.settings.idleAfter),
            })
        end
    end

    function farm.isIdle(self)
        if not self.lastProductionAt then return false end
        return (util.nowMs() - self.lastProductionAt) / 1000 > self.settings.idleAfter
    end

    function farm.status(self)
        if self.running == false then return "stopped", "STOPPED" end
        if self.backedUp then return "warning", "BACKED UP" end
        if farm.isIdle(self) then return "idle", "IDLE" end
        return "running", "RUNNING"
    end

    function farm.metrics(self)
        local metrics = {
            { id = "rate", label = "Items/min", value = math.floor((self.itemsPerMinute or 0) + 0.5) },
            { id = "buffer", label = "Buffer", kind = "percent", value = self.buffer or 0 },
            { id = "items", label = "In buffer", value = self.itemCount or 0 },
            { id = "slots", label = "Slots used",
              value = (self.slotsUsed or 0) .. "/" .. (self.slotCount or 0) },
            { id = "produced", label = "Produced", value = self.produced or 0 },
        }
        if self.settings.targetRate then
            metrics[#metrics + 1] = {
                id = "target", label = "Target", value = self.settings.targetRate, unit = "/min",
            }
        end
        if self.lastProductionAt then
            metrics[#metrics + 1] = {
                id = "last", label = "Last output",
                value = (util.nowMs() - self.lastProductionAt) / 1000,
                format = function(value) return util.formatDuration(value) .. " ago" end,
            }
        end
        return metrics
    end

    function farm.tile(self)
        return {
            lines = { math.floor((self.itemsPerMinute or 0) + 0.5) .. " it/min" },
            gauge = self.buffer,
        }
    end

    function farm.actions(self)
        if self.settings.control.kind == "none" then return {} end
        return {
            { id = "start", label = "START", style = "primary",
              enabled = self.running == false,
              run = function() writeControl(self, true) end },
            { id = "stop", label = "STOP", style = "danger",
              enabled = self.running ~= false,
              run = function() writeControl(self, false) end },
        }
    end

    function farm.stop(self)
        if not self.ctx then return end
        self.ctx.alerts.clear(self.id .. ".buffer_full")
        self.ctx.alerts.clear(self.id .. ".idle")
    end

    return farm
end

return template

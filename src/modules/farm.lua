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

    -- Optional: a Block Reader looking at the spawner that drives the farm.
    --
    --   spawner = { match = { type = "block_reader" } }
    --
    -- Mob farms are built around a spawner and the question in front of the
    -- monitor is always "what is in it and is it running", which no amount of
    -- counting the output answers - an empty buffer looks the same whether the
    -- spawner is a custom one nobody configured or the mobs are simply not
    -- reaching it. What a spawner reports varies by mod and version, so
    -- everything read here is best effort and missing fields are left out
    -- rather than guessed.
    spawner = nil,
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
-- The spawner behind the farm
---------------------------------------------------------------------------

--- Pull a mob id out of whatever shape this version's spawner NBT has.
--
-- Vanilla has moved this twice (`SpawnData.id`, then `SpawnData.entity.id`)
-- and modded spawners add their own; Apotheosis keeps the vanilla layout but
-- may carry several entries in `SpawnPotentials`. Rather than know all of
-- them, look where each has put it and give up quietly.
local function mobFromData(data)
    if type(data) ~= "table" then return nil end

    local spawn = data.SpawnData or data.spawnData
    if type(spawn) == "table" then
        if type(spawn.entity) == "table" and spawn.entity.id then return spawn.entity.id end
        if spawn.id then return spawn.id end
        if type(spawn.data) == "table" and type(spawn.data.entity) == "table" then
            return spawn.data.entity.id
        end
    end

    local potentials = data.SpawnPotentials or data.spawnPotentials
    if type(potentials) == "table" and type(potentials[1]) == "table" then
        local first = potentials[1]
        local entity = first.data and first.data.entity or first.Entity or first.entity
        if type(entity) == "table" and entity.id then return entity.id end
    end

    return nil
end

--- Strip the namespace: "minecraft:zombie" reads as "zombie" on a tile.
local function shortMobName(id)
    if type(id) ~= "string" then return nil end
    return (id:match("([^:]+)$") or id):gsub("_", " ")
end

--- Everything the block reader can say about the spawner, or nil.
local function readSpawner(self)
    if not self.settings.spawner then return nil end

    local reader = self.ctx.peripherals.get(self.id .. ".spawner")
    if not reader then return nil end

    local info = {}

    local blockName = reader.call("getBlockName")
    if type(blockName) == "string" then info.block = blockName end

    local data = reader.call("getBlockData")
    if type(data) == "table" then
        info.mob = mobFromData(data)
        -- Vanilla counts down between spawns; a spawner nobody is standing
        -- near sits at its maximum and never moves.
        local delay = tonumber(data.Delay or data.delay)
        if delay then info.delay = delay end
        local range = tonumber(data.RequiredPlayerRange or data.requiredPlayerRange)
        if range then info.range = range end
        local count = tonumber(data.SpawnCount or data.spawnCount)
        if count then info.count = count end
    end

    if not info.block and not info.mob then return nil end
    return info
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

    -- Optional by definition: a farm whose block reader is missing is still a
    -- farm, and marking it unavailable would hide the output it is producing.
    if settings.spawner then
        local spawnerMatcher = util.deepCopy(settings.spawner.match or { type = "block_reader" })
        spawnerMatcher.alias = farm.id .. ".spawner"
        spawnerMatcher.optional = true
        farm.peripherals[#farm.peripherals + 1] = spawnerMatcher
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

        self.contents = items
        self.spawnerInfo = readSpawner(self)
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

        local spawner = self.spawnerInfo
        if spawner then
            if spawner.mob then
                metrics[#metrics + 1] = { id = "mob", label = "Spawns",
                    value = shortMobName(spawner.mob) }
            end
            if spawner.range then
                metrics[#metrics + 1] = { id = "range", label = "Player range",
                    value = spawner.range, unit = "blocks" }
            end
        elseif self.settings.spawner then
            metrics[#metrics + 1] = { id = "mob", label = "Spawner",
                value = "not readable" }
        end

        return metrics
    end

    --- What is sitting in the output buffer, one row per item.
    --
    -- "412 items" says the farm works; it does not say whether the mob drops
    -- you came for are in there or whether the buffer is 90% rotten flesh. On
    -- a custom spawner that is the whole question, so the answer has to be a
    -- list and not a total.
    function farm.detail(self)
        local totals, order = {}, {}

        for _, item in ipairs(self.contents or {}) do
            local entry = totals[item.name]
            if not entry then
                entry = { name = item.name, label = item.displayName or item.name,
                          count = 0, slots = 0 }
                totals[item.name] = entry
                order[#order + 1] = entry
            end
            entry.count = entry.count + item.count
            entry.slots = entry.slots + 1
        end

        -- Most of it first: the thing filling the buffer is the thing you came
        -- to see, and it is rarely the thing sorted first alphabetically.
        table.sort(order, function(a, b)
            if a.count ~= b.count then return a.count > b.count end
            return a.name < b.name
        end)

        local counted = self.settings.countItems and {} or nil
        for _, name in ipairs(self.settings.countItems or {}) do counted[name] = true end

        local total = 0
        for _, entry in ipairs(order) do total = total + entry.count end

        local rows = {}
        for _, entry in ipairs(order) do
            local fields = {
                { label = "Item", value = entry.name },
                { label = "Count", value = util.formatNumber(entry.count) },
                { label = "Stacks", value = tostring(entry.slots) },
                { label = "Share", value = total > 0
                    and util.formatPercent(entry.count / total) or "-" },
            }
            if counted then
                fields[#fields + 1] = { label = "Counted",
                    value = counted[entry.name] and "yes, this is the rate" or "no, ignored" }
            end

            rows[#rows + 1] = {
                id = entry.name,
                name = entry.label,
                -- Share of the buffer, so the row's colour tracks what is
                -- taking the space rather than how full the barrel is.
                percent = total > 0 and (entry.count / total) or nil,
                value = util.formatNumber(entry.count),
                status = (counted and not counted[entry.name]) and "idle" or nil,
                fields = fields,
            }
        end

        return { columns = { "SHARE", "COUNT" }, rows = rows }
    end

    --- Its own screen: the rate over time, the buffer, and what is in it.
    function farm.detailScreen(params)
        return require("ui.screens.farm_detail").new(params)
    end

    function farm.tile(self)
        local lines = { math.floor((self.itemsPerMinute or 0) + 0.5) .. " it/min" }

        -- Worth the second line on a mob farm: which of the four spawners in
        -- the room this tile is about, without opening it.
        local mob = self.spawnerInfo and shortMobName(self.spawnerInfo.mob)
        if mob then lines[#lines + 1] = mob end

        return { lines = lines, gauge = self.buffer }
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

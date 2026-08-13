--- Module registry: discovery, lifecycle and snapshots.
--
-- A module is a plain table describing one system of the base (power, storage,
-- a farm, ...). See docs/MODULE_DEVELOPMENT.md for the full contract; the short
-- version is:
--
--   return {
--     id = "demo_farm", name = "Demo Farm", icon = "F",
--     peripherals = { { alias = "farmChest", type = "minecraft:chest", optional = true } },
--     pollInterval = 2,
--     setup = function(self, ctx) end,
--     poll = function(self) end,
--     status = function(self) return "running", "RUNNING" end,
--     metrics = function(self) return { { label = "Items/min", value = 124 } } end,
--     actions = function(self) return { { id = "stop", label = "STOP", run = f } } end,
--   }
--
-- The registry never lets a broken module take the system down: every callback
-- runs under pcall and a failing module is flagged `error` in the UI.

local util = require("core.util")
local logger = require("core.logger")
local bus = require("core.event_bus")
local state = require("core.state")

local log = logger.scoped("modules")

local registry = {}

local records = {}      -- [id] = record
local order = {}        -- registration order
local context = nil

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- Normalise whatever `metrics()` returned into an ordered list.
-- Accepts an array of entries or a map of label -> value.
function registry.normaliseMetrics(raw)
    local result = {}
    if type(raw) ~= "table" then return result end

    if #raw > 0 then
        for index, entry in ipairs(raw) do
            if type(entry) == "table" then
                result[#result + 1] = {
                    id = entry.id or entry.label or ("metric" .. index),
                    label = entry.label or entry.id or ("Metric " .. index),
                    value = entry.value,
                    unit = entry.unit,
                    kind = entry.kind or (entry.percent ~= nil and "percent" or nil),
                    percent = entry.percent,
                    color = entry.color,
                    format = entry.format,
                }
            end
        end
        return result
    end

    for _, key in ipairs(util.sortedKeys(raw)) do
        local value = raw[key]
        if type(value) ~= "table" and type(value) ~= "function" then
            result[#result + 1] = { id = key, label = key, value = value }
        end
    end
    return result
end

--- Human readable form of a metric entry.
function registry.formatMetric(metric)
    if metric == nil then return "-" end
    if type(metric.format) == "function" then
        local ok, text = pcall(metric.format, metric.value, metric)
        if ok and text then return tostring(text) end
    end

    local value = metric.value
    if metric.kind == "percent" or (metric.percent ~= nil and value == nil) then
        local fraction = metric.percent or value or 0
        if fraction > 1 then fraction = fraction / 100 end
        return util.formatPercent(fraction)
    end
    if type(value) == "number" then
        return util.formatNumber(value) .. (metric.unit and (" " .. metric.unit) or "")
    end
    if type(value) == "boolean" then return value and "yes" or "no" end
    if value == nil then return "-" end
    return tostring(value) .. (metric.unit and (" " .. metric.unit) or "")
end

local function callModule(record, name, ...)
    local fn = record.def[name]
    if type(fn) ~= "function" then return true, nil end

    local results = table.pack(pcall(fn, record.def, ...))
    if not results[1] then
        record.errorMessage = tostring(results[2])
        record.failures = record.failures + 1
        log.error("module '%s' %s() failed: %s", record.id, name, record.errorMessage)
        registry.setStatus(record.id, "error", "ERROR")
        return false, results[2]
    end
    return true, table.unpack(results, 2, results.n)
end

local function publish(record)
    state.set("modules." .. record.id, {
        id = record.id,
        name = record.name,
        icon = record.icon,
        status = record.status,
        statusText = record.statusText,
        available = record.available,
        error = record.errorMessage,
        lastPoll = record.lastPoll,
    })
end

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

--- Provide the shared service context handed to every module.
function registry.setContext(ctx) context = ctx end

function registry.context() return context end

--- Register a module definition table.
function registry.register(def)
    if type(def) ~= "table" then error("module definition must be a table", 2) end
    if type(def.id) ~= "string" or def.id == "" then error("module needs a string id", 2) end
    if records[def.id] then
        log.warn("module '%s' registered twice, replacing", def.id)
        registry.unregister(def.id)
    end

    local record = {
        id = def.id,
        name = def.name or def.id,
        icon = def.icon,
        def = def,
        status = "unknown",
        statusText = nil,
        available = true,
        errorMessage = nil,
        failures = 0,
        lastPoll = nil,
        pollTaskId = nil,
        missing = {},
    }

    records[def.id] = record
    order[#order + 1] = def.id
    publish(record)
    bus.emit("module.registered", { id = def.id, name = record.name })
    log.info("registered module '%s'", def.id)
    return record
end

function registry.unregister(id)
    local record = records[id]
    if not record then return false end

    callModule(record, "stop")
    if record.pollTaskId and context and context.scheduler then
        context.scheduler.cancel(record.pollTaskId)
    end
    bus.offOwner("module:" .. id)
    if context and context.scheduler then context.scheduler.cancelOwner("module:" .. id) end

    records[id] = nil
    local index = util.indexOf(order, id)
    if index then table.remove(order, index) end
    state.delete("modules." .. id)
    bus.emit("module.unregistered", { id = id })
    return true
end

--- Build a module definition from a template instance.
-- A template is a module file exporting `create(instance)` instead of being a
-- module itself, which is how one implementation (a farm, a reactor) can back
-- any number of configured machines.
local function loadInstance(instance, requireFn)
    local templateName = instance.template
    local ok, template = pcall(requireFn, "modules." .. templateName)
    if not ok then
        log.error("cannot load template '%s': %s", templateName, tostring(template))
        return nil
    end
    if type(template) ~= "table" or type(template.create) ~= "function" then
        log.error("'%s' is not a template: it has no create(instance)", templateName)
        return nil
    end

    local created, def = pcall(template.create, instance)
    if not created then
        log.error("template '%s' failed for '%s': %s",
            templateName, tostring(instance.id), tostring(def))
        return nil
    end

    def.id = instance.id or def.id
    def.template = templateName
    return def
end

local function loadSingle(id, requireFn)
    local ok, def = pcall(requireFn, "modules." .. id)
    if not ok then
        log.error("cannot load module '%s': %s", id, tostring(def))
        return nil
    end
    if type(def) ~= "table" then
        log.error("module '%s' did not return a table", id)
        return nil
    end
    if type(def.create) == "function" and def.id == nil then
        log.error("'%s' is a template; list it under modules.instances, not modules.enabled", id)
        return nil
    end
    def.id = def.id or id
    return def
end

--- Load modules.
-- Entries are either a module id (`"power"`, loaded from
-- `src/modules/power.lua`) or a template instance table
-- (`{ id = "mob_farm", template = "farm", settings = {...} }`).
function registry.load(entries, requireFn)
    requireFn = requireFn or require
    local loaded = {}

    for _, entry in ipairs(entries or {}) do
        local def
        if type(entry) == "string" then
            def = loadSingle(entry, requireFn)
        elseif type(entry) == "table" and entry.template then
            def = loadInstance(entry, requireFn)
        elseif type(entry) == "table" and entry.id then
            def = loadSingle(entry.id, requireFn)
        else
            log.error("invalid module entry: %s", textutils.serialise(entry, { compact = true }))
        end

        if def then
            local okRegister, err = pcall(registry.register, def)
            if okRegister then
                loaded[#loaded + 1] = def.id
            else
                log.error("cannot register module '%s': %s", tostring(def.id), tostring(err))
            end
        end
    end

    return loaded
end

---------------------------------------------------------------------------
-- Lookup
---------------------------------------------------------------------------

function registry.get(id) return records[id] end

function registry.has(id) return records[id] ~= nil end

function registry.ids() return util.deepCopy(order) end

--- Every record in registration order.
function registry.all()
    local result = {}
    for _, id in ipairs(order) do
        if records[id] then result[#result + 1] = records[id] end
    end
    return result
end

function registry.count() return #order end

---------------------------------------------------------------------------
-- Status
---------------------------------------------------------------------------

--- Set a module status and publish the change.
function registry.setStatus(id, status, statusText)
    local record = records[id]
    if not record then return false end
    if record.status == status and record.statusText == statusText then return false end

    local previous = record.status
    record.status = status
    record.statusText = statusText or tostring(status):upper()
    publish(record)
    bus.emit("module.status_changed", {
        id = id, status = status, previous = previous, text = record.statusText,
    })
    return true
end

--- Ask the module for its current status (falls back to the stored one).
local function refreshStatus(record)
    if type(record.def.status) ~= "function" then return end
    local ok, status, text = callModule(record, "status")
    if ok and status then registry.setStatus(record.id, status, text) end
end

---------------------------------------------------------------------------
-- Peripheral requirements
---------------------------------------------------------------------------

local function registerRequirements(record)
    if not context or not context.peripherals then return end
    for _, requirement in ipairs(record.def.peripherals or {}) do
        local alias = requirement.alias or requirement.id
        if alias then
            context.peripherals.registerAlias(alias, requirement)
        end
    end
end

--- Recompute `available` from the module's peripheral requirements.
function registry.checkAvailability(record)
    if not context or not context.peripherals then return true end

    local missing = {}
    for _, requirement in ipairs(record.def.peripherals or {}) do
        local alias = requirement.alias or requirement.id
        if alias and requirement.optional ~= true and not context.peripherals.has(alias) then
            missing[#missing + 1] = alias
        end
    end

    local available = #missing == 0
    if available ~= record.available or #missing ~= #record.missing then
        record.available = available
        record.missing = missing
        if not available then
            registry.setStatus(record.id, "unavailable", "NO DEVICE")
            log.warn("module '%s' unavailable, missing: %s", record.id, table.concat(missing, ", "))
        else
            log.info("module '%s' requirements satisfied", record.id)
            refreshStatus(record)
        end
        publish(record)
        bus.emit("module.availability_changed", { id = record.id, available = available, missing = missing })
    end
    return available
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local function schedulePoll(record)
    if not context or not context.scheduler then return end
    if type(record.def.poll) ~= "function" then return end

    local interval = record.def.pollInterval
        or (context.config and context.config.get("system.modules.defaultPollInterval", 2))
        or 2

    record.pollTaskId = context.scheduler.every(interval, function()
        registry.poll(record.id)
    end, { name = "module." .. record.id .. ".poll", owner = "module:" .. record.id })
end

--- Run `setup` for one module and start polling it.
function registry.setup(id)
    local record = records[id]
    if not record then return false end

    registerRequirements(record)
    registry.checkAvailability(record)

    -- The live context is handed over deliberately: it carries the shared
    -- services (bus, scheduler, peripherals...), not copyable data.
    local ok = callModule(record, "setup", context)
    if not ok then return false end

    if record.status == "unknown" then registry.setStatus(record.id, "ready", "READY") end
    refreshStatus(record)
    schedulePoll(record)
    publish(record)
    return true
end

function registry.setupAll()
    for _, record in ipairs(registry.all()) do registry.setup(record.id) end
end

function registry.startAll()
    for _, record in ipairs(registry.all()) do
        if record.available then callModule(record, "start") end
        refreshStatus(record)
    end
end

function registry.stopAll()
    for _, record in ipairs(registry.all()) do callModule(record, "stop") end
end

--- Refresh one module's data.
function registry.poll(id)
    local record = records[id]
    if not record then return false end
    if not record.available then
        registry.checkAvailability(record)
        if not record.available then return false end
    end

    local ok = callModule(record, "poll")
    record.lastPoll = util.nowMs()
    if ok then
        record.errorMessage = nil
        record.failures = 0
        refreshStatus(record)
        -- Whoever wants to sample this (history, telemetry) subscribes rather
        -- than being called from here.
        bus.emit("module.polled", { id = id })
    end
    publish(record)
    return ok
end

---------------------------------------------------------------------------
-- Views
---------------------------------------------------------------------------

--- Flattened view of a module for the dashboard and detail screen.
function registry.snapshot(id)
    local record = records[id]
    if not record then return nil end

    local snapshot = {
        id = record.id,
        label = record.name,
        name = record.name,
        icon = record.icon,
        status = record.status,
        statusText = record.statusText or tostring(record.status):upper(),
        available = record.available,
        error = record.errorMessage,
        missing = record.missing,
        lines = {},
        metrics = {},
    }

    local ok, tile = callModule(record, "tile")
    if ok and type(tile) == "table" then
        snapshot.lines = tile.lines or {}
        snapshot.gauge = tile.gauge
        if tile.status then snapshot.status = tile.status end
        if tile.statusText then snapshot.statusText = tile.statusText end
    end

    local okMetrics, metrics = callModule(record, "metrics")
    if okMetrics then snapshot.metrics = registry.normaliseMetrics(metrics) end

    -- Fall back to the first two metrics when the module has no custom tile.
    if #snapshot.lines == 0 then
        for index = 1, math.min(2, #snapshot.metrics) do
            local metric = snapshot.metrics[index]
            snapshot.lines[#snapshot.lines + 1] =
                metric.label .. ": " .. registry.formatMetric(metric)
        end
    end

    return snapshot
end

--- Actions offered by a module, normalised to a list.
function registry.actions(id)
    local record = records[id]
    if not record then return {} end

    local raw = record.def.actions
    if type(raw) == "function" then
        local ok, result = callModule(record, "actions")
        raw = ok and result or {}
    end
    if type(raw) ~= "table" then return {} end

    local result = {}
    if #raw > 0 then
        for index, action in ipairs(raw) do
            result[#result + 1] = {
                id = action.id or ("action" .. index),
                label = action.label or action.id or ("Action " .. index),
                style = action.style,
                enabled = action.enabled ~= false,
                confirm = action.confirm,
                run = action.run or action.handler,
            }
        end
    else
        for _, key in ipairs(util.sortedKeys(raw)) do
            if type(raw[key]) == "function" then
                result[#result + 1] = { id = key, label = key:upper(), run = raw[key], enabled = true }
            end
        end
    end
    return result
end

--- Run an action by id. Returns ok, error.
function registry.invoke(id, actionId, ...)
    local record = records[id]
    if not record then return false, "unknown module" end

    -- Every action funnels through here, so this is the only place security
    -- has to be enforced. A node trusts its master: the check belongs where
    -- the click happened, and a node has no idea who clicked.
    if context and context.security and context.hasUI then
        local allowed, reason = context.security.check(id .. "." .. actionId)
        if not allowed then
            log.warn("refused %s.%s: %s", id, actionId, tostring(reason))
            return false, tostring(reason)
        end
    end

    for _, action in ipairs(registry.actions(id)) do
        if action.id == actionId then
            if not action.enabled then return false, "action disabled" end
            if type(action.run) ~= "function" then return false, "action has no handler" end

            local ok, err = pcall(action.run, record.def, ...)
            if not ok then
                log.error("action '%s.%s' failed: %s", id, actionId, tostring(err))
                return false, tostring(err)
            end
            bus.emit("module.action", { id = id, action = actionId })
            refreshStatus(record)
            publish(record)
            return true
        end
    end
    return false, "unknown action '" .. tostring(actionId) .. "'"
end

--- Optional custom detail screen factory declared by a module.
function registry.detailScreenFactory(id)
    local record = records[id]
    if not record then return nil end
    local factory = record.def.detailScreen
    return type(factory) == "function" and factory or nil
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

--- Re-check availability whenever the peripheral topology changes.
function registry.watchPeripherals()
    local function recheck()
        for _, record in ipairs(registry.all()) do registry.checkAvailability(record) end
    end
    bus.on("peripheral.alias_bound", recheck, { owner = "module_registry" })
    bus.on("peripheral.alias_lost", recheck, { owner = "module_registry" })
end

function registry.shutdown()
    registry.stopAll()
    bus.offOwner("module_registry")
    for _, id in ipairs(registry.ids()) do registry.unregister(id) end
end

return registry

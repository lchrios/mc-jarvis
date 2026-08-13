--- Proximity activation: doors and machinery that wake up when someone comes.
--
-- One Player Detector drives any number of trigger zones. Each zone has a
-- radius, an optional list of players it cares about, and an output - a side of
-- this computer, or a side of a Redstone Integrator.
--
--   zones = {
--     { id = "front_door", name = "Front door", radius = 5,
--       output = { kind = "redstone", side = "left" }, holdFor = 3 },
--   }
--
-- `holdFor` is what stops a door slamming in your face: the output stays on for
-- that many seconds after the last player leaves the radius.
--
-- Each zone can be forced ON or OFF from the detail screen; AUTO gives it back
-- to the detector.
--
-- STATUS: the Player Detector method names come from Advanced Peripherals and
-- have not been confirmed in game. The adapter probes several candidates, and
-- this module reports `NO DETECTOR` rather than quietly leaving doors shut.

local util = require("core.util")

local presence = {}

presence.id = "presence"
presence.name = "Presence"
presence.icon = "P"
presence.description = "Player detection and proximity triggers"
presence.pollInterval = 1

presence.peripherals = {
    { alias = "playerDetector", type = "playerDetector", optional = true },
}

local DEFAULTS = {
    zones = {},
    -- Announce arrivals and departures on the event bus (the notifier can pick
    -- them up, and other modules can react).
    emitEvents = true,
    -- Say hello in chat when a player shows up. Off by default: greeting
    -- somebody every time they walk past a detector gets old fast.
    greet = false,
}

---------------------------------------------------------------------------
-- Output
---------------------------------------------------------------------------

--- Drive a zone's output. Returns ok, error.
local function writeOutput(self, zone, on)
    local output = zone.output
    if not output or output.kind == "none" then return true end

    local signal = output.invert and (not on) or on

    if output.kind == "integrator" then
        local integrator = self.ctx.peripherals.get(presence.id .. "." .. zone.id .. ".output")
            or self.ctx.peripherals.firstOfType("redstoneIntegrator")
        if not integrator then return false, "redstone integrator not connected" end
        local _, err = integrator.call("setOutput", output.side or "top", signal)
        return err == nil, err
    end

    if not redstone then return false, "no redstone API" end
    local ok, err = pcall(redstone.setOutput, output.side or "back", signal)
    return ok, ok and nil or tostring(err)
end

---------------------------------------------------------------------------
-- Detection
---------------------------------------------------------------------------

--- Players inside a zone's radius, filtered by its player list.
local function playersIn(self, zone)
    local detector = self.detector
    if not detector then return nil end

    local inRange = detector.inRange(zone.radius or 8)
    if type(inRange) ~= "table" then return nil end

    if not zone.players then return inRange end

    local wanted = {}
    for _, name in ipairs(zone.players) do wanted[name:lower()] = true end

    local matched = {}
    for _, name in ipairs(inRange) do
        if wanted[tostring(name):lower()] then matched[#matched + 1] = name end
    end
    return matched
end

--- Decide a zone's output state and drive it.
local function updateZone(self, zone, state)
    local now = util.nowMs()
    local present = playersIn(self, zone)

    if present == nil then
        state.detected = nil
        return
    end

    local occupied = #present > 0
    if occupied then
        state.lastSeenAt = now
        state.players = present
    end

    -- Hold the output on for a moment after the last player leaves.
    local holdFor = (zone.holdFor or 2) * 1000
    local shouldBeOn = occupied
        or (state.lastSeenAt ~= nil and (now - state.lastSeenAt) < holdFor)

    if state.override == "on" then shouldBeOn = true end
    if state.override == "off" then shouldBeOn = false end

    if occupied ~= (state.detected == true) then
        state.detected = occupied
        if self.settings.emitEvents then
            self.ctx.bus.emit(occupied and "presence.entered" or "presence.left", {
                zone = zone.id,
                name = zone.name or zone.id,
                players = present,
            })
        end
        if occupied and self.settings.greet and #present > 0 then
            self.ctx.bus.emit("presence.greet", {
                zone = zone.id,
                message = tostring(present[1]) .. " arrived at " .. (zone.name or zone.id),
            })
        end
    end

    if shouldBeOn ~= state.on then
        local ok, err = writeOutput(self, zone, shouldBeOn)
        if ok then
            state.on = shouldBeOn
            state.error = nil
            state.changedAt = now
        else
            state.error = err
        end
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function presence.setup(self, ctx)
    self.ctx = ctx
    self.settings = util.deepMerge(DEFAULTS, ctx.config.get("modules.settings.presence", {}))
    self.states = {}
    self.online = {}

    for _, zone in ipairs(self.settings.zones) do
        self.states[zone.id] = { on = false, detected = nil, override = "auto" }

        -- A zone driven by its own integrator gets its own alias, so two doors
        -- can use two different integrators.
        if zone.output and zone.output.kind == "integrator" and zone.output.name then
            ctx.peripherals.registerAlias(presence.id .. "." .. zone.id .. ".output", {
                name = zone.output.name, optional = true,
            })
        end
    end
end

function presence.poll(self)
    local proxy = self.ctx.peripherals.get("playerDetector")
        or self.ctx.peripherals.firstOfType("playerDetector")
    self.detector = proxy and self.ctx.adapters.forProxy(proxy, "advanced_peripherals") or nil

    if not self.detector then
        self.online = {}
        return
    end

    -- Some builds return player tables rather than plain names; keep the
    -- module working either way instead of blowing up in `metrics`.
    self.online = {}
    for _, entry in ipairs(self.detector.online() or {}) do
        self.online[#self.online + 1] = type(entry) == "table"
            and tostring(entry.name or entry.displayName or "?") or tostring(entry)
    end

    for _, zone in ipairs(self.settings.zones) do
        local state = self.states[zone.id]
        if state then updateZone(self, zone, state) end
    end
end

function presence.status(self)
    if not self.detector then return "unavailable", "NO DETECTOR" end
    if #self.settings.zones == 0 then return "idle", "NO ZONES" end

    local active = 0
    for _, state in pairs(self.states) do
        if state.on then active = active + 1 end
    end
    if active > 0 then return "running", active .. " ACTIVE" end
    return "idle", "IDLE"
end

function presence.metrics(self)
    local metrics = {
        { id = "online", label = "Players online", value = #(self.online or {}) },
        { id = "zones", label = "Trigger zones", value = #self.settings.zones },
    }

    for _, zone in ipairs(self.settings.zones) do
        local state = self.states[zone.id] or {}
        local text = state.on and "ON" or "off"
        if state.override ~= "auto" then text = text .. " (" .. state.override .. ")" end
        if state.error then text = "ERROR" end

        metrics[#metrics + 1] = {
            id = "zone." .. zone.id,
            label = zone.name or zone.id,
            value = text,
        }
    end

    if #(self.online or {}) > 0 then
        metrics[#metrics + 1] = {
            id = "who", label = "Online",
            value = util.truncate(table.concat(self.online, ", "), 30),
        }
    end
    return metrics
end

function presence.tile(self)
    if not self.detector then return { lines = { "no player", "detector" } } end

    local active = 0
    for _, state in pairs(self.states) do
        if state.on then active = active + 1 end
    end
    return {
        lines = {
            #(self.online or {}) .. " online",
            active .. "/" .. #self.settings.zones .. " active",
        },
    }
end

--- Cycle a zone between automatic and forced states.
function presence.cycleOverride(self, zoneId)
    local state = self.states[zoneId]
    if not state then return end

    local order = { auto = "on", on = "off", off = "auto" }
    state.override = order[state.override] or "auto"

    -- Apply immediately rather than waiting for the next poll: a door button
    -- that takes a second to respond feels broken.
    for _, zone in ipairs(self.settings.zones) do
        if zone.id == zoneId then updateZone(self, zone, state) end
    end
end

function presence.actions(self)
    local actions = {}
    for _, zone in ipairs(self.settings.zones) do
        local state = self.states[zone.id] or {}
        actions[#actions + 1] = {
            id = "toggle." .. zone.id,
            label = util.truncate((zone.name or zone.id):upper(), 10)
                .. " " .. tostring(state.override or "auto"):upper(),
            run = function() presence.cycleOverride(self, zone.id) end,
        }
    end
    return actions
end

function presence.stop(self)
    -- Leave nothing energised behind us.
    for _, zone in ipairs((self.settings or {}).zones or {}) do
        pcall(writeOutput, self, zone, false)
    end
end

return presence

--- Who is allowed to press what.
--
-- ComputerCraft's `monitor_touch` carries only (side, x, y) - verified in
-- MonitorBlockEntity - so a screen can never tell you who touched it. Two ways
-- around that, both supported:
--
--   mode = "session"    Right-click the Player Detector block to badge in.
--                       Advanced Peripherals fires `playerClick` with the
--                       player's name, which opens a short authenticated
--                       session. This is real identity.
--
--   mode = "proximity"  An authorised player must simply be within range of a
--                       detector. Weaker - anyone standing beside them can
--                       press the button - but needs no extra interaction.
--
-- Off unless `config/security.lua` enables it, and an action nobody protected
-- is always allowed: an update must never lock you out of your own base.

local util = require("core.util")
local logger = require("core.logger")
local bus = require("core.event_bus")
local state = require("core.state")

local log = logger.scoped("security")

local security = {}

local settings = {
    enabled = false,
    mode = "session",
    sessionSeconds = 60,
    detectorRadius = 8,
    profiles = {},
    protect = {},
    -- When the detector is missing, allow or refuse? Refusing is safer but can
    -- strand you; the default keeps the base usable and says so in the log.
    failOpen = true,
}

local context = nil
local session = nil     -- { player, profile, expiresAt, source }
local denials = {}      -- recent refusals, for the UI

---------------------------------------------------------------------------
-- Patterns
---------------------------------------------------------------------------

--- Does `action` ("demo_farm.stop") match `pattern` ("*.stop", "power.*", "*")?
local function matches(action, pattern)
    if pattern == "*" then return true end
    if pattern == action then return true end

    local prefix = pattern:match("^(.-)%.%*$")
    if prefix then return action:sub(1, #prefix + 1) == prefix .. "." end

    local suffix = pattern:match("^%*%.(.+)$")
    if suffix then return action:sub(-(#suffix + 1)) == "." .. suffix end

    return false
end

local function matchesAny(action, patterns)
    for _, pattern in ipairs(patterns or {}) do
        if matches(action, pattern) then return true end
    end
    return false
end

--- Is this action guarded at all?
function security.isProtected(action)
    if not settings.enabled then return false end
    return matchesAny(action, settings.protect)
end

---------------------------------------------------------------------------
-- Profiles
---------------------------------------------------------------------------

--- The profile a player belongs to, or nil.
function security.profileOf(player)
    if not player then return nil end
    local wanted = tostring(player):lower()

    for name, profile in pairs(settings.profiles) do
        for _, candidate in ipairs(profile.players or {}) do
            if tostring(candidate):lower() == wanted then return name, profile end
        end
    end
    return nil
end

--- May this player run this action?
function security.can(player, action)
    local name, profile = security.profileOf(player)
    if not profile then return false, "no profile for '" .. tostring(player) .. "'" end
    if not matchesAny(action, profile.allow) then
        return false, "profile '" .. name .. "' may not run " .. action
    end
    return true
end

function security.players()
    local list = {}
    for name, profile in pairs(settings.profiles) do
        for _, player in ipairs(profile.players or {}) do
            list[#list + 1] = { player = player, profile = name }
        end
    end
    table.sort(list, function(a, b) return a.player < b.player end)
    return list
end

---------------------------------------------------------------------------
-- Sessions
---------------------------------------------------------------------------

--- Open an authenticated session. Called when a known player badges in.
function security.grant(player, source)
    local name, profile = security.profileOf(player)
    if not profile then
        log.warn("'%s' badged in but has no profile", tostring(player))
        security.recordDenial("(badge in)", tostring(player), "no profile")
        return false
    end

    session = {
        player = player,
        profile = name,
        source = source or "playerClick",
        expiresAt = util.nowMs() + settings.sessionSeconds * 1000,
    }
    state.set("security.session", util.deepCopy(session))
    log.info("session opened for '%s' (%s)", tostring(player), name)
    bus.emit("security.session_opened", { player = player, profile = name })
    return true
end

function security.revoke()
    if session then
        bus.emit("security.session_closed", { player = session.player })
    end
    session = nil
    state.set("security.session", nil)
end

--- The live session, or nil when there is none or it has expired.
function security.session()
    if not session then return nil end
    if util.nowMs() > session.expiresAt then
        security.revoke()
        return nil
    end
    return session
end

function security.sessionRemaining()
    local active = security.session()
    if not active then return 0 end
    return math.max(0, (active.expiresAt - util.nowMs()) / 1000)
end

---------------------------------------------------------------------------
-- Proximity
---------------------------------------------------------------------------

--- Authorised players currently within range of a detector.
local function nearbyAuthorised(action)
    if not context then return nil, "security not initialised" end

    local proxy = context.peripherals.get("playerDetector")
        or context.peripherals.firstOfType("player_detector")
    if not proxy then return nil, "no player detector" end

    local detector = context.adapters.forProxy(proxy, "advanced_peripherals")
    if not detector then return nil, "player detector not readable" end

    local players = detector.inRange(settings.detectorRadius) or {}
    for _, player in ipairs(players) do
        local name = type(player) == "table" and player.name or player
        if security.can(name, action) then return name end
    end
    return false, #players == 0 and "nobody in range" or "nobody in range may do that"
end

---------------------------------------------------------------------------
-- The check
---------------------------------------------------------------------------

function security.recordDenial(action, player, reason)
    denials[#denials + 1] = {
        action = action, player = player, reason = reason, time = util.nowMs(),
    }
    while #denials > 20 do table.remove(denials, 1) end
    bus.emit("security.denied", denials[#denials])
end

function security.denials() return util.deepCopy(denials) end

--- May this action run right now? Returns allowed, reason.
function security.check(action)
    if not settings.enabled then return true end
    if not security.isProtected(action) then return true end

    if settings.mode == "proximity" then
        local player, reason = nearbyAuthorised(action)
        if player then return true, player end
        if player == nil and settings.failOpen then
            log.warn("allowing '%s': %s (failOpen)", action, tostring(reason))
            return true
        end
        security.recordDenial(action, nil, reason or "not authorised")
        return false, reason or "not authorised"
    end

    -- Session mode.
    local active = security.session()
    if not active then
        security.recordDenial(action, nil, "no session")
        return false, "badge in at the player detector first"
    end

    local allowed, reason = security.can(active.player, action)
    if not allowed then
        security.recordDenial(action, active.player, reason)
        return false, reason
    end

    -- Using the panel keeps the session alive.
    active.expiresAt = util.nowMs() + settings.sessionSeconds * 1000
    return true, active.player
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

function security.start(ctx)
    context = ctx
    for key, value in pairs(ctx.config.section("security") or {}) do
        settings[key] = value
    end

    state.set("security.enabled", settings.enabled)
    state.set("security.mode", settings.mode)

    if not settings.enabled then
        log.info("security disabled: every action is allowed")
        return false
    end

    -- Advanced Peripherals fires this when a player right-clicks the detector
    -- block. It is the only identified click BaseOS can see.
    bus.on("playerClick", function(player)
        local name = type(player) == "table" and (player.name or player.username) or player
        security.grant(name, "playerClick")
    end, { owner = "security" })

    log.info("security on: %s mode, %d profile(s), %d protected pattern(s)",
        settings.mode, util.count(settings.profiles), #settings.protect)
    return true
end

function security.settings() return util.deepCopy(settings) end

function security.shutdown()
    bus.offOwner("security")
    security.revoke()
end

return security

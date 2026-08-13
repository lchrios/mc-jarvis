--- Who is allowed to press what.
--
-- ComputerCraft's `monitor_touch` carries only (side, x, y) - verified in
-- MonitorBlockEntity - so a screen can never tell you who touched it. The one
-- identified click available is Advanced Peripherals' `playerClick`, fired when
-- a player right-clicks the Player Detector block.
--
--   mode = "session"    Badge in at the detector; the next 60 seconds are
--                       yours. Put the detector beside the monitor and it
--                       behaves like an access card. This is real identity.
--
--   mode = "proximity"  An authorised player merely has to be in range.
--                       Weaker: anyone beside them can press the button.
--
-- Roles carry the permissions; users map a player to a role. Roles come from
-- `config/security.lua`; users may also be added from the panel at runtime and
-- are stored in `data/security.dat`, which the updater never touches.
--
-- Off unless enabled, and an unprotected action is always allowed: an update
-- must never lock anyone out of their own base.

local util = require("core.util")
local logger = require("core.logger")
local bus = require("core.event_bus")
local state = require("core.state")
local persistence = require("services.persistence")

local log = logger.scoped("security")

local security = {}

security.STORE = "security"

--- Roles shipped by default, so a base with `enabled = true` and no config of
--- its own still makes sense.
local DEFAULT_ROLES = {
    admin = {
        label = "Admin",
        description = "Everything, and may manage users",
        allow = { "*" },
        manage = true,
    },
    operator = {
        label = "Operator",
        description = "Start and stop machinery",
        allow = { "*.start", "*.stop", "*.flush" },
    },
    viewer = {
        label = "Viewer",
        description = "Look, do not touch",
        allow = {},
    },
}

local settings = {
    enabled = false,
    mode = "session",
    sessionSeconds = 60,
    detectorRadius = 8,
    enrollSeconds = 30,
    roles = {},
    users = {},          -- seed users from config
    protect = {},
    failOpen = true,
}

local context = nil
local session = nil      -- { player, role, expiresAt, source }
local users = {}         -- [lowercased player] = { player, role, addedBy, addedAt }
local denials = {}
local enrollment = nil   -- { role, requestedBy, expiresAt, candidate }

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

function security.isProtected(action)
    if not settings.enabled then return false end
    return matchesAny(action, settings.protect)
end

---------------------------------------------------------------------------
-- Roles and users
---------------------------------------------------------------------------

function security.roles()
    local list = {}
    for id, role in pairs(settings.roles) do
        list[#list + 1] = {
            id = id,
            label = role.label or id,
            description = role.description,
            allow = role.allow or {},
            manage = role.manage == true,
        }
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

function security.role(id) return settings.roles[id] end

local function key(player) return tostring(player or ""):lower() end

--- Every registered player, alphabetically.
function security.users()
    local list = {}
    for _, user in pairs(users) do list[#list + 1] = util.deepCopy(user) end
    table.sort(list, function(a, b) return a.player:lower() < b.player:lower() end)
    return list
end

function security.user(player) return users[key(player)] end

function security.roleOf(player)
    local user = users[key(player)]
    return user and user.role or nil
end

--- May this player run this action?
function security.can(player, action)
    local roleId = security.roleOf(player)
    if not roleId then return false, "'" .. tostring(player) .. "' is not registered" end

    local role = settings.roles[roleId]
    if not role then return false, "role '" .. roleId .. "' no longer exists" end
    if not matchesAny(action, role.allow) then
        return false, "role '" .. roleId .. "' may not run " .. action
    end
    return true
end

--- May this player add and remove other users?
function security.canManage(player)
    local roleId = security.roleOf(player)
    local role = roleId and settings.roles[roleId]
    return role ~= nil and role.manage == true
end

---------------------------------------------------------------------------
-- Persistence
---------------------------------------------------------------------------

local function publishUsers()
    state.set("security.users", security.users())
end

local function saveUsers()
    -- Only runtime additions are written; config seeds stay in config.
    local stored = {}
    for _, user in pairs(users) do
        if not user.fromConfig then stored[#stored + 1] = user end
    end
    persistence.save(security.STORE, { users = stored })
    publishUsers()
end

--- Register a player. Returns ok, error.
function security.addUser(player, roleId, addedBy)
    player = tostring(player or ""):gsub("%s+", "")
    if player == "" then return false, "a player name is required" end
    if not settings.roles[roleId] then return false, "unknown role '" .. tostring(roleId) .. "'" end

    users[key(player)] = {
        player = player,
        role = roleId,
        addedBy = addedBy,
        addedAt = util.nowMs(),
    }
    saveUsers()

    log.info("'%s' registered as %s by %s", player, roleId, tostring(addedBy or "config"))
    bus.emit("security.user_added", { player = player, role = roleId, addedBy = addedBy })
    return true
end

function security.removeUser(player)
    local user = users[key(player)]
    if not user then return false, "not registered" end
    if user.fromConfig then
        return false, "declared in config/security.lua; remove it there"
    end

    users[key(player)] = nil
    saveUsers()

    -- A removed player must not keep an open session.
    if session and key(session.player) == key(player) then security.revoke() end

    log.info("'%s' removed", tostring(player))
    bus.emit("security.user_removed", { player = user.player })
    return true
end

function security.setRole(player, roleId)
    local user = users[key(player)]
    if not user then return false, "not registered" end
    if not settings.roles[roleId] then return false, "unknown role" end
    if user.fromConfig then return false, "declared in config/security.lua" end

    user.role = roleId
    saveUsers()
    if session and key(session.player) == key(player) then session.role = roleId end
    return true
end

---------------------------------------------------------------------------
-- Sessions
---------------------------------------------------------------------------

function security.grant(player, source)
    local roleId = security.roleOf(player)
    if not roleId then
        log.warn("'%s' badged in but is not registered", tostring(player))
        security.recordDenial("(badge in)", tostring(player), "not registered")
        return false
    end

    session = {
        player = player,
        role = roleId,
        source = source or "playerClick",
        expiresAt = util.nowMs() + settings.sessionSeconds * 1000,
    }
    state.set("security.session", util.deepCopy(session))
    log.info("session opened for '%s' (%s)", tostring(player), roleId)
    bus.emit("security.session_opened", { player = player, role = roleId })
    return true
end

function security.revoke()
    if session then bus.emit("security.session_closed", { player = session.player }) end
    session = nil
    state.set("security.session", nil)
end

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
-- Enrolment
---------------------------------------------------------------------------

--- Arm "the next player to touch the detector is the one I mean".
-- Only somebody who may manage users can arm it, and their own clicks are
-- ignored while it is armed - otherwise the admin enrols themselves.
function security.armEnrollment(roleId, requestedBy)
    if not settings.roles[roleId] then return false, "unknown role" end
    if not security.canManage(requestedBy) then
        return false, "only a role that may manage users can do this"
    end

    enrollment = {
        role = roleId,
        requestedBy = requestedBy,
        expiresAt = util.nowMs() + settings.enrollSeconds * 1000,
        candidate = nil,
    }
    state.set("security.enrolling", { role = roleId, by = requestedBy })
    log.info("listening for a new %s, armed by %s", roleId, tostring(requestedBy))
    bus.emit("security.enroll_armed", { role = roleId, by = requestedBy })
    return true
end

function security.cancelEnrollment()
    enrollment = nil
    state.set("security.enrolling", nil)
    bus.emit("security.enroll_cancelled", {})
end

--- The armed request, or nil when there is none or it expired.
function security.enrollment()
    if not enrollment then return nil end
    if util.nowMs() > enrollment.expiresAt then
        security.cancelEnrollment()
        return nil
    end
    return enrollment
end

--- Accept the captured candidate. Returns ok, error.
function security.confirmEnrollment()
    local request = security.enrollment()
    if not request or not request.candidate then return false, "nobody to confirm" end

    local ok, err = security.addUser(request.candidate, request.role, request.requestedBy)
    security.cancelEnrollment()
    return ok, err
end

---------------------------------------------------------------------------
-- Proximity
---------------------------------------------------------------------------

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

local function loadUsers()
    users = {}

    for _, entry in ipairs(settings.users or {}) do
        if entry.player then
            users[key(entry.player)] = {
                player = entry.player,
                role = entry.role or "viewer",
                addedBy = "config",
                fromConfig = true,
            }
        end
    end

    local stored = persistence.load(security.STORE, nil)
    for _, entry in ipairs((stored and stored.users) or {}) do
        if entry.player and not (users[key(entry.player)] or {}).fromConfig then
            users[key(entry.player)] = entry
        end
    end

    publishUsers()
end

--- A player touched the detector: either enrolling somebody, or badging in.
local function onPlayerClick(player)
    local name = type(player) == "table" and (player.name or player.username) or player
    if not name then return end

    local request = security.enrollment()
    if request then
        -- The admin who armed it keeps badging in as themselves.
        if key(name) ~= key(request.requestedBy) then
            request.candidate = name
            state.set("security.enrolling", {
                role = request.role, by = request.requestedBy, candidate = name,
            })
            log.info("captured '%s' for enrolment as %s", tostring(name), request.role)
            bus.emit("security.enroll_candidate", { player = name, role = request.role })
            return
        end
    end

    security.grant(name, "playerClick")
end

function security.start(ctx)
    context = ctx

    settings.roles = util.deepCopy(DEFAULT_ROLES)
    for key_, value in pairs(ctx.config.section("security") or {}) do
        if key_ == "roles" then
            settings.roles = util.deepMerge(settings.roles, value)
        else
            settings[key_] = value
        end
    end

    loadUsers()
    state.set("security.enabled", settings.enabled)
    state.set("security.mode", settings.mode)

    bus.offOwner("security")

    if not settings.enabled then
        log.info("security disabled: every action is allowed")
        return false
    end

    bus.on("playerClick", onPlayerClick, { owner = "security" })

    log.info("security on: %s mode, %d role(s), %d user(s), %d protected pattern(s)",
        settings.mode, util.count(settings.roles), util.count(users), #settings.protect)
    return true
end

function security.settings() return util.deepCopy(settings) end

function security.shutdown()
    bus.offOwner("security")
    security.revoke()
    security.cancelEnrollment()
end

return security

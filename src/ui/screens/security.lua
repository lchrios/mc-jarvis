--- Manage who may operate the base.
--
-- Adding somebody works two ways, both from the panel:
--
--   LISTEN   an admin badges in, presses LISTEN, and the next player to
--            right-click the detector is captured. The screen asks before
--            registering them - it is a confirmation, not a trap.
--   TYPE     tap the name out on the on-screen keyboard, for somebody who is
--            not standing there.
--
-- Managing users is itself protected: only a role with `manage` can do it, and
-- only while its session is open.

local class = require("core.class")
local util = require("core.util")
local bus = require("core.event_bus")
local Screen = require("ui.screen")
local Label = require("ui.components.label")
local Button = require("ui.components.button")
local List = require("ui.components.list")
local Modal = require("ui.components.modal")
local security = require("services.security")
local theme = require("ui.theme")

local SecurityScreen = class(Screen)

local CONTROLS_HEIGHT = 3

function SecurityScreen:init(params)
    Screen.init(self, params)
    self.title = "Access"
    self.selected = nil       -- player name
    self.pendingRole = nil    -- role chosen for the next enrolment
end

function SecurityScreen:onMount()
    local refresh = function() self:requestLayout() end
    self:onCleanup(bus.on("security.user_added", refresh, { owner = "screen:security" }))
    self:onCleanup(bus.on("security.user_removed", refresh, { owner = "screen:security" }))
    self:onCleanup(bus.on("security.session_opened", refresh, { owner = "screen:security" }))

    -- The whole point of listening mode: ask before registering anybody.
    self:onCleanup(bus.on("security.enroll_candidate", function(payload)
        self:confirmCandidate(payload.player, payload.role)
    end, { owner = "screen:security" }))
end

---------------------------------------------------------------------------
-- Guards
---------------------------------------------------------------------------

--- The player currently allowed to manage users, or nil.
function SecurityScreen:manager()
    local session = security.session()
    if not session then return nil, "badge in at the player detector first" end
    if not security.canManage(session.player) then
        return nil, "'" .. session.player .. "' may not manage users"
    end
    return session.player
end

function SecurityScreen:requireManager()
    local player, reason = self:manager()
    if player then return player end

    self:openModal(Modal.new({
        title = "Not allowed",
        message = reason,
        buttons = { { label = "CLOSE" } },
        onClose = function() self:closeModal() end,
    }))
    return nil
end

---------------------------------------------------------------------------
-- Adding
---------------------------------------------------------------------------

--- Pick which role a new player gets, then how to identify them.
function SecurityScreen:startAdd()
    if not self:requireManager() then return end

    local buttons = {}
    for _, role in ipairs(security.roles()) do
        buttons[#buttons + 1] = {
            label = role.label:upper(),
            onPress = function() self:chooseMethod(role.id) end,
        }
        if #buttons >= 3 then break end
    end
    buttons[#buttons + 1] = { label = "CANCEL" }

    self:openModal(Modal.new({
        title = "Role for the new player",
        message = "Pick what they will be allowed to do.",
        buttons = buttons,
        onClose = function() self:closeModal() end,
    }))
end

function SecurityScreen:chooseMethod(roleId)
    self.pendingRole = roleId
    self:closeModal()

    self:openModal(Modal.new({
        title = "How to identify them",
        message = "LISTEN: the next player to right-click the detector.\n"
            .. "TYPE: tap the name out here.",
        buttons = {
            { label = "LISTEN", style = "primary", onPress = function() self:armListen() end },
            { label = "TYPE", onPress = function() self:typeName() end },
            { label = "CANCEL" },
        },
        onClose = function() self:closeModal() end,
    }))
end

function SecurityScreen:armListen()
    local manager = self:manager()
    if not manager then return end

    local ok, err = security.armEnrollment(self.pendingRole, manager)
    if not ok then
        self:openModal(Modal.new({
            title = "Could not listen",
            message = tostring(err),
            buttons = { { label = "CLOSE" } },
            onClose = function() self:closeModal() end,
        }))
        return
    end
    self:requestLayout()
end

function SecurityScreen:typeName()
    local roleId = self.pendingRole
    self.context.navigation.push("name_entry", {
        title = "New " .. tostring(roleId),
        prompt = "Tap the player's name, then OK",
        onDone = function(name)
            local manager = self:manager()
            if not manager then return end
            local ok, err = security.addUser(name, roleId, manager)
            if not ok then self:say("Could not add: " .. tostring(err)) end
            self:requestLayout()
        end,
    })
end

--- Somebody touched the detector while listening: confirm before registering.
function SecurityScreen:confirmCandidate(player, roleId)
    local role = security.role(roleId)
    self:openModal(Modal.new({
        title = "Register this player?",
        message = ("%s would become %s.\n\n%s"):format(
            tostring(player),
            (role and role.label) or tostring(roleId),
            (role and role.description) or ""),
        buttons = {
            { label = "NO", onPress = function() security.cancelEnrollment() end },
            { label = "YES", style = "primary", onPress = function()
                local ok, err = security.confirmEnrollment()
                if not ok then self:say("Could not add: " .. tostring(err)) end
                self:requestLayout()
            end },
        },
        onClose = function() self:closeModal() end,
    }))
end

---------------------------------------------------------------------------
-- Editing
---------------------------------------------------------------------------

function SecurityScreen:removeSelected()
    if not self:requireManager() then return end
    if not self.selected then return self:say("Pick a player first.") end

    local player = self.selected
    self:openModal(Modal.new({
        title = "Remove access",
        message = player .. " would lose all access.",
        buttons = {
            { label = "CANCEL" },
            { label = "REMOVE", style = "danger", onPress = function()
                local ok, err = security.removeUser(player)
                if not ok then self:say(tostring(err)) end
                self.selected = nil
                self:requestLayout()
            end },
        },
        onClose = function() self:closeModal() end,
    }))
end

--- Cycle the selected player through the available roles.
function SecurityScreen:cycleRole()
    if not self:requireManager() then return end
    if not self.selected then return self:say("Pick a player first.") end

    local roles = security.roles()
    local current = security.roleOf(self.selected)
    local index = 1
    for position, role in ipairs(roles) do
        if role.id == current then index = position end
    end

    local nextRole = roles[(index % #roles) + 1]
    local ok, err = security.setRole(self.selected, nextRole.id)
    if not ok then self:say(tostring(err)) end
    self:requestLayout()
end

function SecurityScreen:say(message)
    self.message = message
    self:invalidate()
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------

local function renderUser(user, width, selected)
    local role = security.role(user.role)
    local label = (role and role.label) or user.role
    local suffix = user.fromConfig and " (config)" or ""
    local right = util.padLeft(label .. suffix, 18)

    return {
        text = util.padRight(util.truncate(user.player, width - #right - 1), width - #right)
            .. right,
        fg = selected and theme.get("accentText") or theme.get("text"),
        bg = selected and theme.get("accent") or nil,
    }
end

function SecurityScreen:statusText()
    if not security.settings().enabled then
        return "Security is off. Enable it in config/security.lua."
    end

    local request = security.enrollment()
    if request then
        return "Listening: the next player to touch the detector becomes "
            .. tostring(request.role)
    end

    local session = security.session()
    if session then
        return ("Session: %s (%s), %ds left"):format(
            session.player, session.role, math.floor(security.sessionRemaining()))
    end
    return "Nobody signed in. Right-click the player detector."
end

function SecurityScreen:onLayout(x, y, w, h)
    local status = Label.new({
        text = util.truncate(self.message or self:statusText(), w),
        fg = security.session() and "statusOk" or "textDim",
    })
    status:setBounds(x, y, w, 1)
    self:add(status)
    self.message = nil

    local header = Label.new({
        text = util.padRight("PLAYER", w - 18) .. util.padLeft("ROLE", 18),
        fg = "textDim",
    })
    header:setBounds(x, y + 1, w, 1)
    self:add(header)

    local listHeight = math.max(1, h - CONTROLS_HEIGHT - 2)
    self.list = List.new({
        items = security.users(),
        renderItem = function(user)
            return renderUser(user, w, self.selected == user.player)
        end,
        emptyText = "Nobody registered yet. Press ADD.",
        onSelect = function(user)
            self.selected = user.player
            self:requestLayout()
        end,
    })
    self.list:setBounds(x, y + 2, w, listHeight)
    self:add(self.list)

    -- Controls
    local controlsY = y + h - CONTROLS_HEIGHT
    if controlsY <= y + 2 then return end

    local request = security.enrollment()
    local actions = {
        { label = "ADD", style = "primary", run = function() self:startAdd() end },
        { label = "ROLE", run = function() self:cycleRole() end },
        { label = "REMOVE", style = "danger", run = function() self:removeSelected() end },
    }
    if request then
        actions = {
            { label = "STOP LISTENING", style = "danger", run = function()
                security.cancelEnrollment()
                self:requestLayout()
            end },
        }
    end

    local slots = self.context.navigation.getRenderer():distribute(x, w, #actions, 1)
    for index, action in ipairs(actions) do
        local button = Button.new({
            label = action.label,
            style = action.style,
            bracket = false,
            onPress = action.run,
        })
        button:setBounds(slots[index].offset, controlsY, slots[index].size, CONTROLS_HEIGHT)
        self:add(button)
    end
end

function SecurityScreen:update()
    if self.list then self.list:setItems(security.users()) end
end

return SecurityScreen

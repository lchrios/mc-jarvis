--- Gets alerts off the screen and to the player.
--
-- Subscribes to the alert service and forwards to whatever sinks are attached:
-- a Chat Box writes to chat, a Speaker makes a noise. Neither is required - the
-- module reports which sinks it found and stays useful with none.
--
-- Rate limited on purpose. An alert that flaps, or a base with twenty warnings,
-- must not turn chat into a wall of text: each alert id has a cooldown, and
-- there is a ceiling per minute across all of them.
--
-- Verified against Advanced Peripherals 0.7.62b: the Chat Box type is
-- `chat_box` and the method is `sendMessage`. It still says NO SINKS rather
-- than pretending it delivered anything, because a device can always be
-- missing or a future version can rename things.

local util = require("core.util")
local notifications = require("services.notifications")

local notifier = {}

notifier.id = "notifier"
notifier.name = "Notifier"
notifier.icon = "!"
notifier.description = "Sends alerts to chat and speakers"
notifier.pollInterval = 5

local DEFAULTS = {
    enabled = true,
    -- Alerts below this never leave the screen.
    minSeverity = "warning",
    -- Seconds before the same alert id may be announced again.
    cooldown = 120,
    -- Ceiling across all alerts, so a storm cannot flood chat.
    maxPerMinute = 6,
    chat = {
        enabled = true,
        prefix = "BaseOS",
        -- Announce when a condition clears, not only when it starts.
        announceClears = true,
    },
    speaker = {
        enabled = true,
        minSeverity = "critical",
    },
}

local SEVERITY_RANK = { info = 1, warning = 2, critical = 3 }

local function rank(severity)
    return SEVERITY_RANK[tostring(severity or "info"):lower()] or 1
end

---------------------------------------------------------------------------
-- Sinks
---------------------------------------------------------------------------

--- Chat Boxes and Speakers currently attached, re-read each poll so plugging
--- one in mid-session just works.
local function findSinks(self)
    local ctx = self.ctx
    local sinks = { chat = {}, speaker = {} }

    for _, proxy in ipairs(ctx.peripherals.findByType("chat_box")) do
        local wrapped = ctx.adapters.forProxy(proxy, "advanced_peripherals")
        if wrapped and wrapped.say then sinks.chat[#sinks.chat + 1] = wrapped end
    end

    for _, wrapped in ipairs(ctx.adapters.allOfKind("speaker")) do
        sinks.speaker[#sinks.speaker + 1] = wrapped
    end

    return sinks
end

--- May this alert be announced right now?
local function allowed(self, alert)
    local now = util.nowMs()

    -- Per-alert cooldown.
    local last = self.lastSent[alert.id]
    if last and (now - last) < self.settings.cooldown * 1000 then
        self.suppressed = (self.suppressed or 0) + 1
        return false
    end

    -- Global ceiling, over a rolling minute.
    for index = #self.recent, 1, -1 do
        if now - self.recent[index] > 60000 then table.remove(self.recent, index) end
    end
    if #self.recent >= self.settings.maxPerMinute then
        self.suppressed = (self.suppressed or 0) + 1
        return false
    end

    return true
end

--- Send one line to every chat sink. Returns how many accepted it.
function notifier.broadcast(self, text, severity)
    local delivered = 0

    if self.settings.chat.enabled then
        for _, chat in ipairs(self.sinks.chat) do
            local ok = chat.say(text, self.settings.chat.prefix)
            if ok then delivered = delivered + 1 end
        end
    end

    if self.settings.speaker.enabled
        and rank(severity) >= rank(self.settings.speaker.minSeverity) then
        for _, speaker in ipairs(self.sinks.speaker) do
            if speaker.alert(severity) then delivered = delivered + 1 end
        end
    end

    if delivered > 0 then
        self.sent = (self.sent or 0) + 1
        self.lastMessage = text
        self.lastSentAt = util.nowMs()
    else
        self.failed = (self.failed or 0) + 1
    end

    return delivered
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function notifier.setup(self, ctx)
    self.ctx = ctx
    self.settings = util.deepMerge(DEFAULTS, ctx.config.get("modules.settings.notifier", {}))
    -- Two separate books: `lastSent` is the cooldown and is never cleared,
    -- `announcedRaise` only remembers whether a clear is worth mentioning.
    -- Wiping the cooldown on clear would let a flapping alert - raise, clear,
    -- raise - bypass rate limiting entirely, which is the case it exists for.
    self.lastSent = {}
    self.announcedRaise = {}
    self.recent = {}
    self.sent, self.failed, self.suppressed = 0, 0, 0
    self.sinks = findSinks(self)

    -- Everything the catalogue decided is worth saying. The service does the
    -- choosing and the wording; this end only knows how to reach the player.
    ctx.bus.on("notify", function(payload)
        if not self.settings.enabled then return end
        if not allowed(self, { id = "topic:" .. tostring(payload.topic) }) then return end

        self.lastSent["topic:" .. tostring(payload.topic)] = util.nowMs()
        self.recent[#self.recent + 1] = util.nowMs()
        notifier.broadcast(self, payload.message, payload.severity)
    end, { owner = "module:notifier" })

    ctx.bus.on("alert.raised", function(alert)
        if not self.settings.enabled then return end
        if not notifications.enabled("alerts") then return end
        if rank(alert.severity) < rank(self.settings.minSeverity) then return end
        if not allowed(self, alert) then return end

        self.lastSent[alert.id] = util.nowMs()
        self.announcedRaise[alert.id] = true
        self.recent[#self.recent + 1] = util.nowMs()
        notifier.broadcast(self, ("[%s] %s"):format(
            tostring(alert.severity):upper(), alert.message), alert.severity)
    end, { owner = "module:notifier" })

    ctx.bus.on("alert.cleared", function(alert)
        if not self.settings.enabled or not self.settings.chat.announceClears then return end
        if not notifications.enabled("alerts") then return end
        -- Only worth saying when the raise was announced in the first place.
        if not self.announcedRaise[alert.id] then return end
        self.announcedRaise[alert.id] = nil

        -- Good news skips the per-alert cooldown but still counts against the
        -- ceiling, so a flapping condition cannot talk its way past it.
        self.recent[#self.recent + 1] = util.nowMs()
        notifier.broadcast(self, "resolved: " .. tostring(alert.message), "ok")
    end, { owner = "module:notifier" })
end

function notifier.poll(self)
    self.sinks = findSinks(self)
end

function notifier.status(self)
    if not self.settings.enabled then return "stopped", "OFF" end
    local total = #self.sinks.chat + #self.sinks.speaker
    if total == 0 then return "unavailable", "NO SINKS" end
    return "running", "READY"
end

function notifier.metrics(self)
    local on = 0
    for _, topic in ipairs(notifications.list()) do
        if topic.enabled then on = on + 1 end
    end

    return {
        { id = "topics", label = "Topics on", value = on },
        { id = "chat", label = "Chat boxes", value = #self.sinks.chat },
        { id = "speakers", label = "Speakers", value = #self.sinks.speaker },
        { id = "sent", label = "Announced", value = self.sent or 0 },
        { id = "suppressed", label = "Rate limited", value = self.suppressed or 0 },
        { id = "failed", label = "Undeliverable", value = self.failed or 0 },
        { id = "min", label = "From severity", value = self.settings.minSeverity },
        { id = "last", label = "Last message",
          value = self.lastMessage and util.truncate(self.lastMessage, 28) or "-" },
    }
end

function notifier.tile(self)
    local total = #self.sinks.chat + #self.sinks.speaker
    if total == 0 then return { lines = { "no chat box", "or speaker" } } end
    return { lines = { total .. " sink(s)", (self.sent or 0) .. " sent" } }
end

function notifier.actions(self)
    return {
        {
            id = "test",
            label = "TEST",
            run = function()
                local delivered = notifier.broadcast(self,
                    "test message from BaseOS", "info")
                if delivered == 0 then
                    error("no sink accepted the message - run 'probe' to see why", 0)
                end
            end,
        },
        {
            id = "toggle",
            label = self.settings.enabled and "MUTE" or "UNMUTE",
            style = self.settings.enabled and "danger" or "primary",
            run = function() self.settings.enabled = not self.settings.enabled end,
        },
    }
end

return notifier

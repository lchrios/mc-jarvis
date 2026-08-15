--- The rednet link itself: modems, who is heard, and what is moving.
--
-- The nodes screen answers "which computers are reporting", which is a
-- question about the base. This one answers the question underneath it - "is
-- this computer able to talk to anybody at all" - and it is the screen to open
-- when the nodes list is empty and nothing explains why.
--
-- Everything here is read out of `network`: modems it opened, peers that got
-- through, computers whose messages were refused, and the last few messages
-- either way. A wrong secret and an unplugged modem produce identical silence
-- on the nodes screen; they look nothing alike here.

local class = require("core.class")
local util = require("core.util")
local bus = require("core.event_bus")
local Screen = require("ui.screen")
local List = require("ui.components.list")
local Label = require("ui.components.label")
local Modal = require("ui.components.modal")
local network = require("network.network")
local theme = require("ui.theme")

local NetworkScreen = class(Screen)

function NetworkScreen:init(params)
    Screen.init(self, params)
    self.title = "Network"
end

function NetworkScreen:onMount()
    -- Traffic is the point of this screen, so it repaints on messages rather
    -- than only on the one second refresh. A repaint, not a relayout: the rows
    -- are rebuilt in `update`, which keeps the scroll position.
    local refresh = function() self:invalidate() end
    self:onCleanup(bus.on("network.message", refresh, { owner = "screen:network" }))
    self:onCleanup(bus.on("network.rejected", refresh, { owner = "screen:network" }))
end

--- Say something in the summary line for a few seconds, then go back to
--- reporting the link. Long enough to read after pressing a button.
local MESSAGE_SECONDS = 6

function NetworkScreen:say(text)
    self.message = text
    self.messageAt = util.nowMs()
    self:invalidate()
end

---------------------------------------------------------------------------
-- The one line that says whether this computer can talk at all
---------------------------------------------------------------------------

local function summaryLine(info)
    if not info.enabled then
        return "Rednet is off. Run 'setup' and pick a role, or set network.enabled "
            .. "in config/network.lua.", "statusWarn"
    end
    if info.status == "no_modem" then
        return "No modem could be opened. Attach one to a face of this computer.",
            "statusError"
    end
    if not info.ready then
        return "Rednet did not come up (" .. tostring(info.status) .. ").", "statusError"
    end

    return ("%s  #%d  protocol '%s'  %s"):format(
        tostring(info.hostname), info.computerId, tostring(info.protocol),
        info.signed and "signed" or "UNSIGNED"),
        info.signed and "statusOk" or "statusWarn"
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

local function ageText(at)
    if not at or at == 0 then return "never" end
    return util.formatDuration((util.nowMs() - at) / 1000) .. " ago"
end

local function header(text)
    return { kind = "header", text = text, fg = theme.get("accent") }
end

--- Two columns that always meet at the right edge, whatever the monitor is.
local function twoColumn(left, right, width)
    local space = math.max(1, width - #right)
    return util.padRight(util.truncate(left, space), space) .. right
end

function NetworkScreen:modemRows(width, rows)
    local modems = network.modems()
    rows[#rows + 1] = header("MODEMS (" .. #modems .. ")")

    if #modems == 0 then
        rows[#rows + 1] = {
            kind = "text",
            text = "  none attached - rednet cannot work without one",
            fg = theme.get("statusError"),
        }
        return
    end

    for _, modem in ipairs(modems) do
        local kind = modem.wireless and "wireless" or "wired"
        if modem.remote then kind = kind .. " (" .. modem.remote .. " on cable)" end

        rows[#rows + 1] = {
            kind = "text",
            text = twoColumn("  " .. modem.name .. "  " .. kind,
                modem.open and "rednet open" or "NOT OPEN", width),
            fg = modem.open and theme.get("statusOk") or theme.get("statusWarn"),
        }
    end
end

function NetworkScreen:peerRows(width, rows)
    local peers = network.peerList()
    rows[#rows + 1] = header("HEARD (" .. #peers .. ")")

    if #peers == 0 then
        rows[#rows + 1] = {
            kind = "text",
            text = "  nobody yet - press PING, then check the other computer",
            fg = theme.get("statusWarn"),
        }
        return
    end

    for _, peer in ipairs(peers) do
        local right = util.padLeft(peer.rtt and (math.floor(peer.rtt) .. "ms") or "-", 7)
            .. util.padLeft(ageText(peer.lastSeen), 11)
        rows[#rows + 1] = {
            kind = "peer",
            peer = peer,
            text = twoColumn(("  %s  #%s  %s"):format(
                tostring(peer.name), tostring(peer.id), tostring(peer.role or "?")),
                right, width),
            fg = theme.get("statusOk"),
        }
    end
end

function NetworkScreen:strangerRows(width, rows)
    local strangers = network.strangers()
    if #strangers == 0 then return end

    -- The most useful section on the screen, and the reason it exists: a
    -- computer whose messages are being thrown away is talking, not silent.
    rows[#rows + 1] = header("REFUSED (" .. #strangers .. ")")

    for _, stranger in ipairs(strangers) do
        rows[#rows + 1] = {
            kind = "stranger",
            stranger = stranger,
            text = twoColumn(("  computer #%s  %s  x%d"):format(
                tostring(stranger.id), tostring(stranger.reason), stranger.count),
                util.padLeft(ageText(stranger.lastAt), 11), width),
            fg = theme.get("statusError"),
        }
    end
end

function NetworkScreen:trafficRows(width, rows)
    local traffic = network.traffic()
    rows[#rows + 1] = header("TRAFFIC (" .. #traffic .. " kept)")

    if #traffic == 0 then
        rows[#rows + 1] = {
            kind = "text",
            text = "  nothing has crossed the wire yet",
            fg = theme.get("textDim"),
        }
        return
    end

    -- Newest first: the bottom of a scrolling list is where the eye is not.
    for index = #traffic, 1, -1 do
        local entry = traffic[index]
        rows[#rows + 1] = {
            kind = "text",
            text = twoColumn(("  %s %-20s %s"):format(
                entry.direction == "out" and ">" or "<",
                util.truncate(tostring(entry.type), 20),
                util.truncate(tostring(entry.peer or "*"), 14)),
                util.padLeft(ageText(entry.at), 11), width),
            fg = entry.ok and theme.get("textDim") or theme.get("statusError"),
        }
    end
end

function NetworkScreen:counterRows(width, rows)
    local info = network.info()
    local stats = info.stats

    rows[#rows + 1] = header("COUNTERS")
    rows[#rows + 1] = {
        kind = "text",
        text = ("  sent %d   received %d   refused %d   not for me %d"):format(
            stats.sent, stats.received, stats.rejected, stats.ignored),
        fg = stats.rejected > 0 and theme.get("statusWarn") or theme.get("textDim"),
    }

    for reason, count in pairs(stats.reasons or {}) do
        rows[#rows + 1] = {
            kind = "text",
            text = twoColumn("    refused: " .. tostring(reason), tostring(count), width),
            fg = theme.get("statusError"),
        }
    end

    if stats.lastError then
        rows[#rows + 1] = {
            kind = "text",
            text = util.truncate("  last send error: " .. stats.lastError, width),
            fg = theme.get("statusError"),
        }
    end

    rows[#rows + 1] = {
        kind = "text",
        text = ("  heartbeat every %ss, a peer is lost after %ss"):format(
            tostring(info.heartbeatInterval), tostring(info.peerTimeout)),
        fg = theme.get("textDim"),
    }
end

function NetworkScreen:buildRows(width)
    local rows = {}
    self:modemRows(width, rows)
    self:peerRows(width, rows)
    self:strangerRows(width, rows)
    self:trafficRows(width, rows)
    self:counterRows(width, rows)
    return rows
end

---------------------------------------------------------------------------
-- Detail
---------------------------------------------------------------------------

function NetworkScreen:showPeer(peer)
    local lines = {
        "Computer: #" .. tostring(peer.id),
        "Role:     " .. tostring(peer.role or "?"),
        "Last:     " .. ageText(peer.lastSeen),
        "Messages: " .. tostring(peer.messages or 0),
    }
    if peer.lastType then lines[#lines + 1] = "Last type: " .. tostring(peer.lastType) end
    if peer.rtt then lines[#lines + 1] = "Round trip: " .. math.floor(peer.rtt) .. "ms" end
    if peer.firstSeen then lines[#lines + 1] = "First seen: " .. ageText(peer.firstSeen) end

    self:openModal(Modal.new({
        title = util.truncate(tostring(peer.name), 24),
        message = table.concat(lines, "\n"),
        buttons = { { label = "CLOSE" } },
        onClose = function() self:closeModal() end,
    }))
end

--- Why a computer is being ignored, and what to do about it.
local ADVICE = {
    unsigned = "It is not signing its messages. Put the same `secret` in "
        .. "config/network.lua on both computers.",
    ["bad signature"] = "Its secret is not the same as this computer's. Copy "
        .. "`secret` from config/network.lua across, character for character.",
    ["already seen"] = "A repeat of a message already handled. Harmless on its "
        .. "own; constant repeats mean two computers share a name.",
}

function NetworkScreen:showStranger(stranger)
    local reason = tostring(stranger.reason)
    local advice = ADVICE[reason]
    if not advice and reason:find("stale") then
        advice = "Its clock is far from this one's, or the message took too long. "
            .. "Raise `authWindow` in config/network.lua if it keeps happening."
    end

    local lines = {
        "Refused:  " .. reason,
        "Times:    " .. tostring(stranger.count),
        "Last:     " .. ageText(stranger.lastAt),
    }
    if stranger.source then lines[#lines + 1] = "Calls itself: " .. tostring(stranger.source) end
    if stranger.type then lines[#lines + 1] = "Sending:  " .. tostring(stranger.type) end
    if advice then
        lines[#lines + 1] = ""
        lines[#lines + 1] = advice
    end

    self:openModal(Modal.new({
        title = "computer #" .. tostring(stranger.id),
        message = table.concat(lines, "\n"),
        buttons = { { label = "CLOSE" } },
        onClose = function() self:closeModal() end,
    }))
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

function NetworkScreen:ping()
    if not network.isReady() then
        self:say("Rednet is not up: nothing to ping with.")
    elseif network.discover() then
        self:say("Asked every computer on '" .. tostring(network.protocolName())
            .. "' to answer.")
    else
        self:say("Could not send: check the modem.")
    end
end

--- Ask the nodes to publish now, rather than waiting for their next tick.
function NetworkScreen:requestData()
    local app = require("core.app")
    local telemetry = require("network.telemetry")
    local context = app.context()

    if context and telemetry.requestAll(context) then
        self:say("Asked every node to report now.")
    else
        self:say("Could not ask: rednet is not up.")
    end
end

function NetworkScreen:onLayout(x, y, w, h)
    local width = w - 2
    self.rowWidth = width

    local text, colour = summaryLine(network.info())
    self.summary = Label.new({ text = util.truncate(text, width), fg = colour })
    self.summary:setBounds(x + 1, y, width, 1)
    self.summaryWidth = width
    self:add(self.summary)

    local listHeight = math.max(1, h - 2 - Screen.ACTION_BAR)

    self.list = List.new({
        items = self:buildRows(width),
        renderItem = function(row)
            return { text = util.truncate(row.text, width), fg = row.fg }
        end,
        emptyText = "Nothing to report.",
        onSelect = function(row)
            if row.kind == "peer" then self:showPeer(row.peer) end
            if row.kind == "stranger" then self:showStranger(row.stranger) end
        end,
    })
    self.list:setBounds(x + 1, y + 2, width, listHeight)
    self:add(self.list)

    self:actionBar(x + 1, y, width, h, {
        { label = "PING", style = "primary", run = function() self:ping() end },
        { label = "REQUEST", run = function() self:requestData() end },
        { label = "RESET COUNTS", run = function()
            network.resetStats()
            self:say("Counters cleared.")
        end },
    })
end

--- Rows are rebuilt at most this often. `update` runs after every event, and
--- building the modem section calls a peripheral per modem.
local REBUILD_SECONDS = 0.5

function NetworkScreen:update()
    if not self.summary then return end

    -- Rebuilt rather than relaid out: `setItems` keeps the scroll offset, so a
    -- list somebody is reading does not jump every time a heartbeat lands.
    local now = util.nowMs()
    if self.list and (now - (self.rebuiltAt or 0)) / 1000 >= REBUILD_SECONDS then
        self.rebuiltAt = now
        self.list:setItems(self:buildRows(self.rowWidth or 40))
    end

    local fresh = self.message
        and (util.nowMs() - (self.messageAt or 0)) / 1000 < MESSAGE_SECONDS
    if not fresh then self.message = nil end

    local text, colour = summaryLine(network.info())
    self.summary:setText(util.truncate(self.message or text, self.summaryWidth or 40))
    self.summary.fg = self.message and "accent" or colour
end

return NetworkScreen

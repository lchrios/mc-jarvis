--- Connected peripherals, as an expandable tree.
--
-- A flat list answered "what is attached"; the question that actually comes up
-- is "why can BaseOS not read this thing". Touching a row unfolds it into what
-- the peripheral reports and which alias claimed it, drawn with tree lines so
-- the detail visibly belongs to the row above it.

local class = require("core.class")
local util = require("core.util")
local bus = require("core.event_bus")
local Screen = require("ui.screen")
local List = require("ui.components.list")
local Label = require("ui.components.label")
local manager = require("peripherals.manager")
local theme = require("ui.theme")

local PeripheralsScreen = class(Screen)

local BRANCH, LAST_BRANCH, INDENT = "+- ", "\\- ", "   "

--- Methods worth calling out, and what having them means.
local CAPABILITIES = {
    { method = "getEnergy", label = "energy storage" },
    { method = "getEnergyStored", label = "energy storage" },
    { method = "getTransferRate", label = "energy throughput" },
    { method = "list", label = "inventory" },
    { method = "tanks", label = "fluid tanks" },
    { method = "listItems", label = "storage network" },
    { method = "craftItem", label = "autocrafting" },
    { method = "getBlockName", label = "block reader" },
    { method = "sendMessage", label = "chat output" },
    { method = "getPlayersInRange", label = "player detection" },
}

--- What a modem is and whether it is actually carrying anything.
--
-- Modems used to fall through every check above and report "nothing BaseOS
-- understands", which is a lie: a modem is the one peripheral the whole
-- multi-computer side of BaseOS runs on. The question people ask of this
-- screen is "does it know my modem is there, and is it talking to anyone" -
-- so answer both.
local function modemLines(proxy)
    if not proxy or not proxy.hasMethod("isWireless") then return nil end

    local lines = {}
    local wireless = proxy.isWireless()
    lines[#lines + 1] = {
        text = "is: " .. (wireless and "wireless modem" or "wired modem"),
        fg = theme.get("statusOk"),
    }

    -- rednet listens on the computer's own id, so an open channel there is
    -- proof that rednet came up on *this* modem rather than merely that a
    -- modem exists.
    local listening = proxy.hasMethod("isOpen") and proxy.isOpen(os.getComputerID())
    lines[#lines + 1] = {
        text = "rednet: " .. (listening and "open, listening" or "not open"),
        fg = listening and theme.get("statusOk") or theme.get("statusWarn"),
    }

    if not wireless and proxy.hasMethod("getNamesRemote") then
        local remote = proxy.getNamesRemote() or {}
        lines[#lines + 1] = {
            text = ("cable: %d peripheral(s) on the far side"):format(#remote),
            fg = #remote > 0 and theme.get("statusOk") or theme.get("textDim"),
        }
    end

    return lines
end

function PeripheralsScreen:init(params)
    Screen.init(self, params)
    self.title = "Devices"
    self.expanded = {}
end

function PeripheralsScreen:onMount()
    local refresh = function() self:requestLayout() end
    self:onCleanup(bus.on("peripheral.attached", refresh, { owner = "screen:peripherals" }))
    self:onCleanup(bus.on("peripheral.detached", refresh, { owner = "screen:peripherals" }))
    self:onCleanup(bus.on("peripheral.changed", refresh, { owner = "screen:peripherals" }))
end

---------------------------------------------------------------------------

--- Which alias, if any, claimed a peripheral.
local function aliasFor(name, aliases)
    for alias, entry in pairs(aliases) do
        if entry.name == name then return alias end
    end
    return nil
end

--- Detail lines for one device, without the tree glyphs.
local function detailLines(name, device, alias)
    local lines = {}

    lines[#lines + 1] = { text = "types: " .. table.concat(device.types or {}, ", ") }
    lines[#lines + 1] = { text = "methods: " .. tostring(device.methodCount) }

    if alias then
        lines[#lines + 1] = { text = "alias: @" .. alias, fg = theme.get("statusOk") }
    end

    local proxy = manager.getByName(name)

    local modem = modemLines(proxy)
    if modem then
        for _, line in ipairs(modem) do lines[#lines + 1] = line end
        return lines
    end

    local found = {}
    for _, capability in ipairs(CAPABILITIES) do
        if proxy and proxy.hasMethod(capability.method) and not found[capability.label] then
            found[capability.label] = true
            lines[#lines + 1] = {
                text = "reads: " .. capability.label,
                fg = theme.get("statusOk"),
            }
        end
    end

    if not next(found) then
        lines[#lines + 1] = {
            text = "nothing BaseOS understands - 'scan " .. name .. "'",
            fg = theme.get("statusWarn"),
        }
    end

    return lines
end

--- Flatten devices (and any expanded detail) into list rows.
function PeripheralsScreen:buildRows()
    local rows = {}
    local aliases = manager.aliasInfo()
    local devices = manager.list()
    local names = util.sortedKeys(devices)

    -- Unbound aliases first: a missing device is the thing you came to see.
    for _, alias in ipairs(util.sortedKeys(aliases)) do
        if not aliases[alias].connected then
            rows[#rows + 1] = {
                kind = "missing",
                text = "@" .. alias .. "  (unbound, wants "
                    .. tostring(aliases[alias].matcher and aliases[alias].matcher.type or "any") .. ")",
                fg = theme.get("statusWarn"),
            }
        end
    end

    for _, name in ipairs(names) do
        local device = devices[name]
        local isOpen = self.expanded[name] == true
        local alias = aliasFor(name, aliases)

        rows[#rows + 1] = {
            kind = "device",
            name = name,
            text = (isOpen and "[-] " or "[+] ") .. name .. (alias and ("  @" .. alias) or ""),
            fg = theme.get("text"),
        }

        if isOpen then
            local lines = detailLines(name, device, alias)
            for index, line in ipairs(lines) do
                local glyph = (index == #lines) and LAST_BRANCH or BRANCH
                rows[#rows + 1] = {
                    kind = "detail",
                    name = name,
                    text = INDENT .. glyph .. line.text,
                    fg = line.fg or theme.get("textDim"),
                }
            end
        end
    end

    return rows
end

--- How long ago the last scan was, in words.
local function sinceScan(stats)
    if not stats.lastScanAt or stats.lastScanAt == 0 then return "never" end
    local seconds = math.floor((util.nowMs() - stats.lastScanAt) / 1000)
    if seconds < 2 then return "just now" end
    if seconds < 60 then return seconds .. "s ago" end
    return math.floor(seconds / 60) .. "m ago"
end

function PeripheralsScreen:rescan()
    manager.rescan("from the panel")
    self.message = "Rescanned: " .. manager.count() .. " device(s)."
    self:requestLayout()
end

function PeripheralsScreen:onLayout(x, y, w, h)
    local width = w - 2
    local stats = manager.stats()

    -- The line says whether it is looking after itself, so "nothing appeared"
    -- can be told apart from "nothing has looked".
    local header = Label.new({
        text = util.truncate(self.message or
            ("%d device(s)  -  scan #%d %s, every %ds%s"):format(
                stats.count, stats.scans, sinceScan(stats), stats.interval,
                stats.degraded and ("  -  MISSING " .. table.concat(stats.missing, ", ")) or ""),
            width),
        fg = stats.degraded and "statusWarn" or "textDim",
    })
    header:setBounds(x + 1, y, width, 1)
    self:add(header)
    self.message = nil

    local listHeight = math.max(1, h - 1 - Screen.ACTION_BAR)

    self.list = List.new({
        items = self:buildRows(),
        renderItem = function(row)
            return { text = util.truncate(row.text, width), fg = row.fg }
        end,
        emptyText = "No peripherals detected. Check the wired modems are enabled.",
        onSelect = function(row)
            if row.kind == "device" or row.kind == "detail" then
                self.expanded[row.name] = not self.expanded[row.name]
                self:requestLayout()
            end
        end,
    })
    self.list:setBounds(x + 1, y + 1, width, listHeight)
    self:add(self.list)

    -- The rescan is automatic; the button is for when you just placed a modem
    -- and do not want to wait for the next pass.
    self:actionBar(x + 1, y, width, h, {
        { label = "RESCAN NOW", style = "primary", run = function() self:rescan() end },
    })
end

function PeripheralsScreen:update()
    -- Rows only change on expand/collapse or attach/detach, both of which
    -- relayout; refreshing the text every frame would fight the scroll offset.
end

return PeripheralsScreen

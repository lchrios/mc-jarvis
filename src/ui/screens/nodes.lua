--- Every computer reporting to this master.
--
-- Module tiles show what a node measures; this shows the node itself - whether
-- it is still talking, when it last did, and what it is running. It is the
-- screen to open when a tile says OFFLINE and the question is why.

local class = require("core.class")
local util = require("core.util")
local bus = require("core.event_bus")
local Screen = require("ui.screen")
local List = require("ui.components.list")
local Label = require("ui.components.label")
local Modal = require("ui.components.modal")
local state = require("core.state")
local theme = require("ui.theme")

local NodesScreen = class(Screen)

function NodesScreen:init(params)
    Screen.init(self, params)
    self.title = "Nodes"
end

function NodesScreen:onMount()
    local refresh = function() self:invalidate() end
    self:onCleanup(bus.on("node.updated", refresh, { owner = "screen:nodes" }))
    self:onCleanup(bus.on("node.offline", refresh, { owner = "screen:nodes" }))
end

local function nodeList()
    local nodes = {}
    for _, node in pairs(state.get("nodes", {})) do nodes[#nodes + 1] = node end
    table.sort(nodes, function(a, b)
        if a.online ~= b.online then return a.online == true end
        return tostring(a.name) < tostring(b.name)
    end)
    return nodes
end

local function moduleCount(node)
    local total = 0
    for _ in pairs(node.modules or {}) do total = total + 1 end
    return total
end

local function ageOf(node)
    if not node.lastSeen or node.lastSeen == 0 then return nil end
    return (util.nowMs() - node.lastSeen) / 1000
end

local function renderNode(node, width)
    local age = ageOf(node)
    local status = node.online and "online" or (node.restored and "restored" or "OFFLINE")
    local right = util.padLeft(status, 9)
        .. util.padLeft(age and (util.formatDuration(age) .. " ago") or "never", 11)
    local name = util.truncate(node.name or "?", math.max(6, width - #right - 1))

    return {
        text = util.padRight(name, width - #right) .. right,
        fg = node.online and theme.get("statusOk") or theme.get("statusError"),
    }
end

function NodesScreen:showNode(node)
    local lines = {
        "Profile:  " .. tostring(node.profile or node.role or "?"),
        "Version:  " .. tostring(node.version or "?"),
        "Modules:  " .. moduleCount(node),
    }

    local age = ageOf(node)
    lines[#lines + 1] = "Last seen: " ..
        (age and (util.formatDuration(age) .. " ago") or "never")
    if node.uptime then
        lines[#lines + 1] = "Uptime:   " .. util.formatDuration(node.uptime)
    end
    if not node.online then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Check the node has a modem and is running."
    end

    self:openModal(Modal.new({
        title = util.truncate(node.name or "node", 24),
        message = table.concat(lines, "\n"),
        buttons = { { label = "CLOSE" } },
        onClose = function() self:closeModal() end,
    }))
end

function NodesScreen:onLayout(x, y, w, h)
    local width = w - 2

    local header = Label.new({
        text = util.padRight("NODE", width - 20) .. util.padLeft("STATUS", 9)
            .. util.padLeft("LAST SEEN", 11),
        fg = "textDim",
    })
    header:setBounds(x + 1, y, width, 1)
    self:add(header)

    self.list = List.new({
        items = nodeList(),
        renderItem = function(node) return renderNode(node, width) end,
        emptyText = "No nodes have reported yet.",
        onSelect = function(node) self:showNode(node) end,
    })
    self.list:setBounds(x + 1, y + 1, width, math.max(1, h - 1))
    self:add(self.list)
end

function NodesScreen:update()
    if self.list then self.list:setItems(nodeList()) end
end

return NodesScreen

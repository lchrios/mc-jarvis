--- System module: information about the computer BaseOS runs on.
--
-- Also the reference implementation of the module contract: no peripherals
-- required, cheap poll, metrics only.

local util = require("core.util")

local system = {}

system.id = "system"
system.name = "System"
system.icon = "#"
system.description = "Computer, peripherals and runtime information"
system.pollInterval = 2

local startedAt = util.nowMs()

function system.setup(self, ctx)
    self.ctx = ctx
    self.bootTime = startedAt
end

function system.poll(self)
    local ctx = self.ctx
    if not ctx then return end

    self.uptime = (util.nowMs() - self.bootTime) / 1000
    self.peripheralCount = ctx.peripherals.count()
    self.moduleCount = ctx.modules.count()
    self.taskCount = ctx.scheduler.count()
    self.alertCount = ctx.alerts.count()

    local renderer = ctx.navigation and ctx.navigation.getRenderer()
    if renderer then
        local width, height = renderer:size()
        self.monitorSize = width .. "x" .. height
        self.monitorName = renderer.deviceName
    end

    local ok, free = pcall(fs.getFreeSpace, "/")
    self.freeSpace = ok and free or nil
end

function system.status(self)
    if self.alertCount and self.alertCount > 0 then return "warning", "ALERTS" end
    return "running", "ONLINE"
end

function system.metrics(self)
    return {
        { id = "computer", label = "Computer ID", value = os.getComputerID() },
        { id = "label", label = "Label", value = os.getComputerLabel() or "(unnamed)" },
        { id = "uptime", label = "Uptime", value = self.uptime or 0,
          format = function(value) return util.formatDuration(value) end },
        { id = "peripherals", label = "Peripherals", value = self.peripheralCount or 0 },
        { id = "modules", label = "Modules", value = self.moduleCount or 0 },
        { id = "tasks", label = "Scheduled tasks", value = self.taskCount or 0 },
        { id = "alerts", label = "Active alerts", value = self.alertCount or 0 },
        { id = "display", label = "Display", value = self.monitorSize or "?" },
        { id = "output", label = "Output device", value = self.monitorName or "?" },
        { id = "free", label = "Free disk", value = self.freeSpace,
          format = function(value)
              if value == nil then return "?" end
              return util.formatNumber(value) .. "B"
          end },
        { id = "version", label = "BaseOS", value = (BASEOS and BASEOS.version) or "?" },
    }
end

function system.tile(self)
    return {
        lines = {
            "ID " .. os.getComputerID(),
            util.formatDuration(self.uptime or 0),
            (self.peripheralCount or 0) .. " periph.",
        },
    }
end

function system.actions(self)
    return {
        {
            id = "peripherals",
            label = "DEVICES",
            run = function()
                if self.ctx and self.ctx.navigation then
                    self.ctx.navigation.push("peripherals", {})
                end
            end,
        },
        {
            id = "logs",
            label = "LOGS",
            run = function()
                if self.ctx and self.ctx.navigation then
                    self.ctx.navigation.push("logs", {})
                end
            end,
        },
        {
            id = "reboot",
            label = "REBOOT",
            style = "danger",
            confirm = "Reboot this computer?",
            run = function() os.reboot() end,
        },
    }
end

return system

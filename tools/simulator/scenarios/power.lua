-- Power breakdown with many devices, and the list pager that makes an
-- overflowing list usable on a touch monitor.

local ui = __TEST.ui
local failures = {}

local function check(condition, message)
    if condition then
        print("  ok: " .. message)
        return true
    end
    failures[#failures + 1] = message
    print("  FAIL: " .. message)
    return false
end

-- The subject here is the pager, which only appears when the list overflows,
-- so the monitor size is pinned rather than inherited.
__TEST.resizeMonitor(82, 25)
__TEST.addEnergyCells(22, { powah = true })

__TEST.files["config/layout.lua"] = [[
return {
    mode = "grid",
    grid = { columns = 12, rows = 6 },
    zones = {
        { id = "power", label = "POWER",   module = "power",  col = 1, row = 1, colSpan = 6, rowSpan = 6 },
        { id = "hub",   label = "CENTRAL HUB", module = "system", col = 7, row = 1, colSpan = 6, rowSpan = 6 },
    },
}
]]

local function power()
    local record = BASEOS.loaded["modules.registry"].get("power")
    return record and record.def or nil
end

local function list()
    local screen = ui.screen()
    for _, child in ipairs(screen and screen.children or {}) do
        if child.items then return child end
    end
    return nil
end

__TEST.injectAt(16, function()
    check(power() ~= nil, "the power module is registered")
    -- Zone tiles live on the map screen now.
    return ui.touch("MAP")
end)

__TEST.injectAt(20, function() return ui.touch("POWER") end)

local firstPage
__TEST.injectAt(30, function()
    -- Asserted after the module has had a poll interval to read its devices.
    local data = power()
    check(#(data.sources or {}) == 22, "all 22 energy devices were discovered")
    check((data.capacity or 0) > 0, "capacities were aggregated")
    check(ui.screenName() == "module_detail", "the power zone opens a detail screen")
    local component = list()
    check(component ~= nil, "the detail screen has a device list")
    if component then
        check(component:usesPager(), "an overflowing list shows the pager")
        check(component.offset == 0, "it starts at the top")
        firstPage = component:visibleRows()
        print(("  showing %d of %d devices"):format(firstPage, #component.items))
    end
    return ui.touch("DOWN v")
end)

__TEST.injectAt(36, function()
    local component = list()
    check(component and component.offset > 0, "DOWN scrolls the list")
    return ui.touch("^ UP")
end)

__TEST.injectAt(42, function()
    local component = list()
    check(component and component.offset == 0, "UP scrolls back to the top")
end)

-- Paging past the end must clamp, not run off into empty rows.
__TEST.injectAt(46, function() return ui.touch("DOWN v") end)
__TEST.injectAt(50, function() return ui.touch("DOWN v") end)
__TEST.injectAt(54, function() return ui.touch("DOWN v") end)
__TEST.injectAt(58, function() return ui.touch("DOWN v") end)
__TEST.injectAt(62, function()
    local component = list()
    check(component and component.offset == component:maxOffset(),
        "paging past the end clamps to the last page")
end)

local source = assert(__TEST.files["startup.lua"], "startup.lua not found")
local chunk = assert(load(source, "@startup.lua", "t", _G))
local ok, runError = pcall(chunk)

local snaps = __TEST.snapshots()
for index = math.max(1, #snaps - 1), #snaps do
    if snaps[index] then
        print(("================ SNAPSHOT %d (%s) ================"):format(index, snaps[index].label))
        print(snaps[index].screen)
    end
end

print("run ok: " .. tostring(ok) .. (ok and "" or (" err=" .. tostring(runError))))

local log = __TEST.files["data/baseos.log"]
if log and log:find("%[ERROR%]") then
    print(log)
    error("log contains ERROR entries", 0)
end
if not ok then error("startup crashed: " .. tostring(runError), 0) end
for _, harnessError in ipairs(__TEST.errors()) do check(false, "harness: " .. harnessError) end
check(not __TEST.crashed(), "no crash banner")

if #failures > 0 then error(#failures .. " assertion(s) failed", 0) end
print("power breakdown and pager validated")

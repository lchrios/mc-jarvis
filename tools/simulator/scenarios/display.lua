-- A display computer: a monitor anywhere in the base, pinned to one view.
--
-- It holds no data of its own, so this also checks it says so while waiting
-- rather than showing an empty screen.

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

__TEST.files["data/node.dat"] = textutils.serialise({
    role = "display",
    profile = "display",
    name = "reactor_screen",
    modules = { "system" },
    view = { id = "power", title = "POWER", modules = "power" },
})

__TEST.addModem("modem_0")

local function snapshotFrom(node, charge)
    return {
        version = 1, id = 1, type = "metrics.update",
        source = node, target = "*", timestamp = 0,
        payload = {
            node = node, role = "node", profile = "power", version = "0.8.0", uptime = 60,
            modules = {
                {
                    id = "power", name = "Power", icon = "P",
                    status = "running", statusText = "OK", available = true,
                    lines = { "842k FE" }, gauge = charge,
                    metrics = {
                        { id = "charge", label = "Charge", kind = "percent", value = charge },
                        { id = "stored", label = "Stored", value = 842000, unit = "FE" },
                    },
                    actions = {},
                },
                {
                    id = "storage", name = "Storage", icon = "S",
                    status = "running", statusText = "NETWORK", available = true,
                    lines = { "12k items" },
                    metrics = { { id = "items", label = "Items", value = 12000 } },
                    actions = {},
                },
            },
        },
    }
end

---------------------------------------------------------------- waiting
__TEST.injectAt(18, function()
    check(ui.screenName() == "display_view", "a display boots into its view, not the dashboard")
    local screen = ui.screen()
    check(screen.title == "POWER", "the header shows the view title")

    local waiting = false
    for _, child in ipairs(screen.children or {}) do
        if child.text and tostring(child.text):find("Waiting for data", 1, true) then
            waiting = true
        end
    end
    check(waiting, "with nothing reported it says it is waiting")
end)

---------------------------------------------------------------- data arrives
__TEST.injectAt(24, function()
    return { "rednet_message", 7, snapshotFrom("power_node", 0.64), "baseos" }
end)

__TEST.injectAt(30, function()
    local registry = BASEOS.loaded["modules.registry"]
    check(registry.has("power_node.power"), "the display collects telemetry like a master")
    check(registry.has("power_node.storage"), "including modules its view does not show")

    local screen = ui.screen()
    local ids = screen:matchingModules()
    check(#ids == 1 and ids[1] == "power_node.power",
        "the view filters to power only (got " .. table.concat(ids, ", ") .. ")")
end)

---------------------------------------------------------------- history
__TEST.injectAt(44, function()
    return { "rednet_message", 7, snapshotFrom("power_node", 0.70), "baseos" }
end)
__TEST.injectAt(64, function()
    return { "rednet_message", 7, snapshotFrom("power_node", 0.55), "baseos" }
end)

__TEST.injectAt(72, function()
    local history = BASEOS.loaded["services.history"]
    local seriesId = "power_node.power.charge"
    check(history.has(seriesId), "the display records history for what it shows")

    local series = history.series(seriesId)
    if series then
        check(series.count >= 2, "several samples were kept (" .. series.count .. ")")
        check(series.max > series.min, "the series has a range to chart")
    end
end)

-------------------------------------------------------------- the chart
__TEST.injectAt(78, function()
    local screen = ui.screen()
    check(screen.chart ~= nil, "a chart appears once there is history to draw")

    if screen.chart then
        -- The chart is drawn with coloured cells, not characters, so the text
        -- dump cannot see it. Check the colours that landed on the monitor.
        local chart = screen.chart
        local colours = __TEST.monitor.coloursIn(chart.x, chart.y, chart.w, chart.h)
        local distinct = 0
        for _ in pairs(colours) do distinct = distinct + 1 end
        check(distinct > 1, "the chart area has bars, not a flat background ("
            .. distinct .. " colours)")
    end
end)

---------------------------------------------------------- returning home
__TEST.injectAt(84, function()
    local navigation = BASEOS.loaded["ui.navigation"]
    navigation.push("nodes", {})
    check(navigation.depth() == 2, "a display can still be navigated by hand")
end)

__TEST.injectAt(88, function()
    -- The return-home task only fires once the idle timeout has passed; make it
    -- immediate rather than waiting a simulated minute.
    BASEOS.loaded["core.app"].startReturnHome(0.001)
end)

__TEST.injectAt(150, function()
    local navigation = BASEOS.loaded["ui.navigation"]
    check(navigation.depth() == 1, "and returns to its view when left alone")
    check(ui.screenName() == "display_view", "back on the pinned view")
end)

---------------------------------------------------------------- run
local source = assert(__TEST.files["startup.lua"], "startup.lua not found")
local chunk = assert(load(source, "@startup.lua", "t", _G))
local ok, runError = pcall(chunk)

local snaps = __TEST.snapshots()
print(snaps[#snaps] and snaps[#snaps].screen or "(nothing drawn)")
print("run ok: " .. tostring(ok) .. (ok and "" or (" err=" .. tostring(runError))))

local log = __TEST.files["data/baseos.log"]
if log and log:find("%[ERROR%]") then
    print(log)
    error("log contains ERROR entries", 0)
end
if not ok then error("startup crashed: " .. tostring(runError), 0) end
for _, harnessError in ipairs(__TEST.errors()) do check(false, "harness: " .. harnessError) end

if #failures > 0 then error(#failures .. " assertion(s) failed", 0) end
print("display role validated")

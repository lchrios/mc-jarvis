-- Paging through a module's metrics when they do not fit.
--
-- The list screens already paged; the generic detail screen silently dropped
-- everything past the last visible row, which is exactly where a module with a
-- dozen readings ends up on a 3x2 monitor.

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

__TEST.files["config/layout.lua"] = [[
return {
    mode = "grid",
    grid = { columns = 12, rows = 6 },
    zones = {
        { id = "hub", label = "CENTRAL HUB", module = "system", col = 1, row = 1, colSpan = 12, rowSpan = 6 },
    },
}
]]

--- Metric ids currently on screen.
local function visibleMetrics()
    local screen = ui.screen()
    if not screen or not screen.metricRows then return {} end
    local ids = {}
    for _, row in ipairs(screen.metricRows) do ids[#ids + 1] = row.metric.id end
    for _, gauge in ipairs(screen.gauges or {}) do ids[#ids + 1] = gauge.metric.id end
    return ids
end

local function contains(list, value)
    for _, item in ipairs(list) do
        if item == value then return true end
    end
    return false
end

local firstPage, secondPage

__TEST.injectAt(20, function() return ui.touch("CENTRAL HUB") end)

__TEST.injectAt(26, function()
    check(ui.screenName() == "module_detail", "the hub opens its detail screen")

    local screen = ui.screen()
    check((screen.pageCount or 1) > 1, "the metrics do not fit, so there is more than one page")

    firstPage = visibleMetrics()
    check(#firstPage > 0, "the first page shows metrics")
    check(contains(firstPage, "computer"), "it starts at the first metric")
    print("  page 1: " .. table.concat(firstPage, ", "))

    return ui.touch("DOWN v")
end)

__TEST.injectAt(32, function()
    secondPage = visibleMetrics()
    check(#secondPage > 0, "the second page shows metrics")
    check(not contains(secondPage, "computer"), "it moved past the first page")
    check(contains(secondPage, "version") or contains(secondPage, "free"),
        "it reached metrics that used to be cut off")
    print("  page 2: " .. table.concat(secondPage, ", "))

    return ui.touch("^ UP")
end)

__TEST.injectAt(38, function()
    local back = visibleMetrics()
    check(contains(back, "computer"), "UP returns to the first page")
    check(#back == #firstPage, "the first page is unchanged")
end)

-- Every metric has to be reachable: none may be stranded between pages.
__TEST.injectAt(42, function() return ui.touch("DOWN v") end)
__TEST.injectAt(46, function() return ui.touch("DOWN v") end)
__TEST.injectAt(50, function() return ui.touch("DOWN v") end)
__TEST.injectAt(54, function()
    local screen = ui.screen()
    check(screen.pageIndex == screen.pageCount, "paging past the end stops at the last page")

    local seen = {}
    for index = 1, screen.pageCount do
        screen.pageIndex = index
        screen:layout(screen.x, screen.y, screen.w, screen.h)
        for _, id in ipairs(visibleMetrics()) do seen[id] = true end
    end

    local registry = BASEOS.loaded["modules.registry"]
    local missing = {}
    for _, metric in ipairs(registry.snapshot("system").metrics) do
        if not seen[metric.id] then missing[#missing + 1] = metric.id end
    end
    check(#missing == 0, "every metric appears on some page (missing: "
        .. table.concat(missing, ", ") .. ")")
end)

------------------------------------------------- a metric opens its history
__TEST.injectAt(60, function()
    local screen = ui.screen()
    screen.pageIndex = 1
    screen:layout(screen.x, screen.y, screen.w, screen.h)
    return ui.touch("Uptime")
end)

__TEST.injectAt(66, function()
    check(ui.screenName() == "metric_detail", "touching a metric opens its history")
    local screen = ui.screen()
    check(screen.metricId == "uptime", "for the metric that was touched")
    check(screen.seriesId == "system.uptime", "reading the right history series")
end)

---------------------------------------------------------------- run
local source = assert(__TEST.files["startup.lua"], "startup.lua not found")
local chunk = assert(load(source, "@startup.lua", "t", _G))
local ok, runError = pcall(chunk)

local snaps = __TEST.snapshots()
for index = 2, math.min(3, #snaps) do
    if snaps[index] then
        print(("================ SNAPSHOT %d ================"):format(index))
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

if #failures > 0 then error(#failures .. " assertion(s) failed", 0) end
print("detail scrolling validated")

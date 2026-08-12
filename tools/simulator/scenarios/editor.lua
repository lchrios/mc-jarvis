-- The layout editor: place zones from the monitor and save without a reboot.
--
-- The point is that edits reach the map and survive, so this drives the real
-- buttons and then checks the store and the map, not just the editor's own
-- working copy.

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

__TEST.resizeMonitor(82, 25)

-- A deliberately sparse plan: demo_farm is registered but not placed.
__TEST.files["config/layout.lua"] = [[
return {
    mode = "grid",
    grid = { columns = 12, rows = 6 },
    zones = {
        { id = "system",  label = "CENTRAL HUB", module = "system",
          col = 1, row = 1, colSpan = 4, rowSpan = 3 },
        { id = "storage", label = "STORAGE", module = "storage",
          col = 9, row = 1, colSpan = 4, rowSpan = 3 },
    },
}
]]

local function editor() return ui.screen() end
local function store() return BASEOS.loaded["services.layout_store"] end

local function zoneOf(layout, id)
    for _, zone in ipairs(layout.zones or {}) do
        if zone.id == id then return zone end
    end
    return nil
end

---------------------------------------------------------------- open it
__TEST.injectAt(16, function() return ui.touch("MAP") end)
__TEST.injectAt(20, function() return ui.touch("EDIT") end)

__TEST.injectAt(24, function()
    check(ui.screenName() == "layout_editor", "EDIT opens the editor")
    local screen = editor()
    check(#screen.plan.zones == 2, "it starts from the current plan")
    check(screen:mode() == "MOVE", "and in MOVE mode")

    -- The list shows every module, placed or not.
    local rows = screen:moduleRows()
    local placed, unplaced = 0, 0
    for _, row in ipairs(rows) do
        if row.placed then placed = placed + 1 else unplaced = unplaced + 1 end
    end
    check(placed == 2, "placed modules are marked (" .. placed .. ")")
    check(unplaced >= 1, "unplaced ones are listed too (" .. unplaced .. ")")
end)

---------------------------------------------------------------- move
__TEST.injectAt(28, function()
    local screen = editor()
    screen:select("system")
    return nil
end)

__TEST.injectAt(32, function()
    local before = zoneOf(editor().plan, "system").col
    editor():nudge(1, 0)
    local after = zoneOf(editor().plan, "system").col
    check(after == before + 1, "the arrows move the selected zone")
    check(editor().edited == true, "and mark the plan as edited")
end)

__TEST.injectAt(36, function()
    -- Moving is clamped to the grid, not allowed to run off it.
    for _ = 1, 20 do editor():nudge(1, 0) end
    local zone = zoneOf(editor().plan, "system")
    local columns = 12
    check(zone.col + zone.colSpan - 1 <= columns,
        "movement stays inside the grid (col " .. zone.col .. " span " .. zone.colSpan .. ")")
    for _ = 1, 20 do editor():nudge(-1, 0) end
    check(zoneOf(editor().plan, "system").col == 1, "and back to the first column")
end)

---------------------------------------------------------------- resize
__TEST.injectAt(40, function()
    local screen = editor()
    screen.modeIndex = 2   -- SIZE
    local before = zoneOf(screen.plan, "system").colSpan
    screen:nudge(1, 0)
    check(zoneOf(screen.plan, "system").colSpan == before + 1, "SIZE mode resizes instead")
    screen:nudge(-1, 0)
end)

---------------------------------------------------------------- add
__TEST.injectAt(44, function()
    local screen = editor()
    screen.selectedModule = "demo_farm"
    screen:addZone()

    local zone = zoneOf(screen.plan, "demo_farm")
    check(zone ~= nil, "ADD puts an unplaced module on the plan")
    check(zone and zone.module == "demo_farm", "bound to that module")
    check(zone and zone.col and zone.row, "in a free slot (" ..
        tostring(zone and zone.col) .. "," .. tostring(zone and zone.row) .. ")")
end)

---------------------------------------------------------------- link
__TEST.injectAt(48, function()
    local screen = editor()
    screen:toggleLink("demo_farm", "storage")

    local from = zoneOf(screen.plan, "demo_farm")
    check(from.links and #from.links == 1, "LINK creates a pipe")
    check(from.links and from.links[1].to == "storage", "pointing at the other zone")

    -- Touching the same pair again removes it.
    screen:toggleLink("demo_farm", "storage")
    check(#(zoneOf(screen.plan, "demo_farm").links or {}) == 0, "and touching again removes it")
    screen:toggleLink("demo_farm", "storage")
end)

---------------------------------------------------------------- delete
__TEST.injectAt(52, function()
    local screen = editor()
    screen:select("storage")
    screen:removeZone()

    check(zoneOf(screen.plan, "storage") == nil, "DEL removes the selected zone")
    local farm = zoneOf(screen.plan, "demo_farm")
    check(#(farm.links or {}) == 0, "and drops the links that pointed at it")
end)

---------------------------------------------------------------- save
__TEST.injectAt(56, function()
    check(store().hasOverride() == false, "nothing was written before SAVE")
    return ui.touch("SAVE")
end)

__TEST.injectAt(62, function()
    check(store().hasOverride(), "SAVE writes the override to data/")
    check(__TEST.files["data/layout.dat"] ~= nil, "the file is on disk")
    check(__TEST.files["config/layout.lua"]:find("CENTRAL HUB", 1, true) ~= nil,
        "config/layout.lua was left untouched")

    local saved = store().current()
    check(zoneOf(saved, "demo_farm") ~= nil, "the added zone survived")
    check(zoneOf(saved, "storage") == nil, "the removed zone stayed removed")

    check(ui.screenName() == "map", "saving returns to the map")
end)

__TEST.injectAt(68, function()
    -- The map has to pick the new plan up without a reboot.
    local screen = ui.screen()
    local ids = {}
    for _, tile in ipairs(screen.tiles or {}) do ids[#ids + 1] = tile.zone.id end
    table.sort(ids)
    check(#ids == 2, "the map redrew with the saved plan (" .. table.concat(ids, ", ") .. ")")

    local hasFarm = false
    for _, id in ipairs(ids) do if id == "demo_farm" then hasFarm = true end end
    check(hasFarm, "including the zone added in the editor")
end)

---------------------------------------------------------------- run
local source = assert(__TEST.files["startup.lua"], "startup.lua not found")
local chunk = assert(load(source, "@startup.lua", "t", _G))
local ok, runError = pcall(chunk)

local snaps = __TEST.snapshots()
for index = math.max(1, #snaps - 1), #snaps do
    if snaps[index] then print(snaps[index].screen) end
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
print("layout editor validated")

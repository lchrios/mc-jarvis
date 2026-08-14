-- The base plan BaseOS actually ships.
--
-- Every other map scenario writes its own config/layout.lua, so the default
-- one - the plan a person sees on their first boot - was covered by nothing.
-- This runs it as shipped, on the smallest supported monitor and on a big one,
-- because those are the two ways a plan goes wrong: names that do not fit, and
-- rooms that inflate to fill whatever they are given.

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

__TEST.setMaxEvents(90)

-- Deliberately NOT overriding config/layout.lua: the shipped one is the
-- subject here.

local function screen() return ui.screen() end

local function tileFor(id)
    for _, tile in ipairs(screen().tiles or {}) do
        if tile.zone.id == id then return tile end
    end
    return nil
end

local function frame() return __TEST.monitor.render() end

---------------------------------------------------- the smallest monitor
__TEST.resizeMonitor(57, 24)

__TEST.injectAt(12, function() return ui.touch("MAP") end)

__TEST.injectAt(18, function()
    check(ui.screenName() == "map", "the shipped plan opens")

    local tiles = screen().tiles or {}
    check(#tiles >= 6, "it places every zone (" .. #tiles .. ")")

    -- A plan is read by its shape. Identical boxes are the dashboard again.
    local widths, heights = {}, {}
    for _, tile in ipairs(tiles) do
        widths[tile.w] = true
        heights[tile.h] = true
    end
    local distinctW, distinctH = 0, 0
    for _ in pairs(widths) do distinctW = distinctW + 1 end
    for _ in pairs(heights) do distinctH = distinctH + 1 end
    check(distinctW >= 2, "with rooms of different widths (" .. distinctW .. ")")
    check(distinctH >= 2, "and different heights (" .. distinctH .. ")")

    -- Pipes are the other half of a plan.
    check(#(screen().linkLayer.segments or {}) > 0, "and pipes drawn between them")
end)

__TEST.injectAt(22, function()
    -- Every shipped label has to survive the minimum monitor whole: a plan
    -- covered in "REACT..." is not a plan.
    local text = frame()
    for _, name in ipairs({ "REACTOR", "BATERIAS", "CONTROL", "ALMACEN",
                            "MOB FARM", "CULTIVOS", "TALLER" }) do
        check(text:find(name, 1, true) ~= nil,
            "'" .. name .. "' fits on a 3x2 monitor uncut")
    end
    check(text:find("%.%.%.") == nil, "nothing on the plan is truncated")
end)

---------------------------------------------------------- a big monitor
__TEST.injectAt(30, function()
    __TEST.resizeMonitor(121, 45)
end)

__TEST.injectAt(40, function()
    local tiles = screen().tiles or {}
    check(#tiles >= 6, "the plan survives the resize (" .. #tiles .. ")")

    -- The complaint this fixes: a taller monitor did not show more base, it
    -- showed the same rooms inflated, with a name floating in the middle.
    local tallest = 0
    local total = 0
    for _, tile in ipairs(tiles) do
        if tile.h > tallest then tallest = tile.h end
        total = total + tile.h
    end
    check(tallest <= 20,
        "no room inflates to fill the screen (tallest " .. tallest .. " of 45)")

    -- ...and it is centred rather than pinned to the top, so the empty space
    -- is shared instead of dangling underneath.
    local top, bottom = math.huge, 0
    for _, tile in ipairs(tiles) do
        if tile.y < top then top = tile.y end
        if tile.y + tile.h > bottom then bottom = tile.y + tile.h end
    end
    local above = top - screen().y
    local below = (screen().y + screen().h) - bottom
    check(above > 0 and below > 0,
        "the plan is centred (" .. above .. " above, " .. below .. " below)")
    check(math.abs(above - below) <= 3, "evenly, give or take a row")
end)

__TEST.injectAt(46, function()
    -- Still touchable where it is drawn, after all that moving about.
    local hub = tileFor("hub")
    check(hub ~= nil, "the control room is still on the plan")
    if hub then
        return { "monitor_touch", "monitor_0",
                 hub.x + math.floor(hub.w / 2), hub.y + math.floor(hub.h / 2) }
    end
end)

__TEST.injectAt(52, function()
    check(ui.screenName() ~= "map", "touching a room still opens it ("
        .. tostring(ui.screenName()) .. ")")
end)

---------------------------------------------------------------- run
local source = assert(__TEST.files["startup.lua"], "startup.lua not found")
local chunk = assert(load(source, "@startup.lua", "t", _G))
local ok, runError = pcall(chunk)

print("run ok: " .. tostring(ok) .. (ok and "" or (" err=" .. tostring(runError))))

local log = __TEST.files["data/baseos.log"]
if log and log:find("%[ERROR%]") then
    print(log)
    error("log contains ERROR entries", 0)
end
if not ok then error("startup crashed: " .. tostring(runError), 0) end
for _, harnessError in ipairs(__TEST.errors()) do check(false, "harness: " .. harnessError) end

if #failures > 0 then error(#failures .. " assertion(s) failed", 0) end
print("shipped base plan validated")

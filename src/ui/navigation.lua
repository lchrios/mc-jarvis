--- Screen registry, navigation stack and window chrome.
--
-- Navigation owns the renderer and draws the persistent header/footer; each
-- screen only ever sees the content rectangle between them.
--
--   navigation.register("dashboard", function(params) return Dashboard.new(params) end)
--   navigation.push("module_detail", { moduleId = "demo_farm" })
--   navigation.back()

local util = require("core.util")
local logger = require("core.logger")
local bus = require("core.event_bus")
local theme = require("ui.theme")

local log = logger.scoped("ui")

local navigation = {}

local factories = {}
local stack = {}
local renderer = nil
local options = {
    title = "BASE CONTROL",
    showHeader = true,
    showFooter = true,
    useInGameClock = true,
    -- Breathing room between the chrome and whatever a screen draws.
    paddingX = 1,
    paddingY = 1,
    -- Below this the UI is not worth drawing; say so instead of rendering mush.
    -- Sized to demand a 3x2 monitor while still allowing the 51x19 computer
    -- terminal, which is the fallback when no monitor is attached.
    minWidth = 45,
    minHeight = 18,
    minHint = "a 3x2 monitor",
}
local statusProvider = nil
local dirty = true
local backHotspot = nil
local footerHotspots = {}

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

function navigation.init(targetRenderer, settings)
    renderer = targetRenderer
    for key, value in pairs(settings or {}) do options[key] = value end
    stack = {}
    dirty = true
    return navigation
end

function navigation.setRenderer(targetRenderer)
    renderer = targetRenderer
    navigation.relayout()
end

function navigation.getRenderer() return renderer end

--- Register a screen factory. `factory(params)` must return a Screen instance.
function navigation.register(name, factory)
    if type(factory) ~= "function" then error("screen factory must be a function", 2) end
    factories[name] = factory
    return navigation
end

function navigation.isRegistered(name) return factories[name] ~= nil end

function navigation.registered() return util.sortedKeys(factories) end

--- Footer segments provider: function() -> { { label, value, color }, ... }
function navigation.setStatusProvider(fn) statusProvider = fn end

---------------------------------------------------------------------------
-- Stack
---------------------------------------------------------------------------

function navigation.current() return stack[#stack] end

function navigation.depth() return #stack end

function navigation.currentName()
    local entry = stack[#stack]
    return entry and entry.name or nil
end

--- The rectangle a screen may draw in: between header and footer, inset by the
--- configured padding. On cramped displays the padding is dropped, because a
--- row of margin is worth less than a row of content.
local function contentRect()
    local width, height = renderer:size()
    local top = options.showHeader and 2 or 1
    local bottom = options.showFooter and (height - 1) or height

    local padX = width >= 40 and (options.paddingX or 0) or 0
    local padY = (bottom - top + 1) >= 14 and (options.paddingY or 0) or 0

    local x = 1 + padX
    local y = top + padY
    return x, y,
        math.max(1, width - padX * 2),
        math.max(1, (bottom - padY) - y + 1)
end

local function mountScreen(entry)
    local screen = entry.screen
    screen.context = {
        invalidate = function() dirty = true end,
        navigation = navigation,
        params = entry.params,
    }

    local ok, err = pcall(screen.onMount, screen, screen.context)
    if not ok then
        log.error("screen '%s' onMount failed: %s", entry.name, tostring(err))
    end

    local x, y, w, h = contentRect()
    screen.surfaceW, screen.surfaceH = renderer:size()
    local okLayout, layoutErr = pcall(screen.layout, screen, x, y, w, h)
    if not okLayout then
        log.error("screen '%s' layout failed: %s", entry.name, tostring(layoutErr))
    end
end

local function unmountScreen(entry)
    if not entry then return end
    local ok, err = pcall(entry.screen.onUnmount, entry.screen)
    if not ok then log.error("screen '%s' onUnmount failed: %s", entry.name, tostring(err)) end
end

local function createScreen(name, params)
    local factory = factories[name]
    if not factory then
        log.error("no screen registered as '%s'", name)
        return nil
    end
    local ok, screen = pcall(factory, params or {})
    if not ok or not screen then
        log.error("screen factory '%s' failed: %s", name, tostring(screen))
        return nil
    end
    return { name = name, params = params or {}, screen = screen }
end

--- Push a new screen on top of the stack.
function navigation.push(name, params)
    local entry = createScreen(name, params)
    if not entry then return nil end

    stack[#stack + 1] = entry
    mountScreen(entry)
    dirty = true
    bus.emit("ui.navigated", { name = name, params = params, depth = #stack })
    log.debug("push %s (depth %d)", name, #stack)
    return entry.screen
end

--- Replace the whole stack with a single screen (used for the home screen).
function navigation.reset(name, params)
    for index = #stack, 1, -1 do
        unmountScreen(stack[index])
        stack[index] = nil
    end
    return navigation.push(name, params)
end

--- Replace only the top of the stack.
function navigation.replace(name, params)
    if #stack > 0 then
        unmountScreen(stack[#stack])
        stack[#stack] = nil
    end
    return navigation.push(name, params)
end

--- Pop the top screen. The root screen is never popped.
function navigation.back()
    if #stack <= 1 then return false end
    unmountScreen(stack[#stack])
    stack[#stack] = nil
    dirty = true

    local entry = stack[#stack]
    bus.emit("ui.navigated", { name = entry.name, params = entry.params, depth = #stack })
    return true
end

function navigation.home()
    while #stack > 1 do
        unmountScreen(stack[#stack])
        stack[#stack] = nil
    end
    dirty = true
    return true
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

function navigation.invalidate() dirty = true end

function navigation.isDirty() return dirty end

--- Re-run layout for the current screen (after a resize or data change).
function navigation.relayout()
    local entry = stack[#stack]
    if not entry or not renderer then return end
    local x, y, w, h = contentRect()
    entry.screen.surfaceW, entry.screen.surfaceH = renderer:size()
    local ok, err = pcall(entry.screen.layout, entry.screen, x, y, w, h)
    if not ok then log.error("relayout failed: %s", tostring(err)) end
    dirty = true
end

local function drawHeader(entry)
    local width = renderer:width()
    local bg, fg = "headerBg", "headerText"
    renderer:fill(1, 1, width, 1, bg, " ")

    backHotspot = nil
    local cursor = 1

    if #stack > 1 then
        local label = " " .. theme.chars.arrowLeft .. " BACK "
        renderer:write(1, 1, label, "textInverse", theme.get("accent"))
        backHotspot = { x1 = 1, x2 = #label }
        cursor = #label + 2
    else
        cursor = 2
    end

    local clock = util.formatClock(options.useInGameClock)
    -- The root screen names itself too: a display pinned to POWER should say so
    -- rather than borrowing the base-wide title.
    local title = entry and (entry.screen.title or entry.name) or options.title

    local available = width - cursor - #clock - 1
    if available > 0 then
        renderer:write(cursor, 1, util.truncate(title:upper(), available), fg, bg)
    end
    renderer:writeRight(1, 1, width - 1, clock, fg, bg)
end

local function drawFooter()
    local width, height = renderer:size()
    renderer:fill(1, height, width, 1, "footerBg", " ")

    local segments = {}
    if type(statusProvider) == "function" then
        local ok, result = pcall(statusProvider)
        if ok and type(result) == "table" then segments = result end
    end

    -- Remember where each segment landed so a touch can name the one it hit.
    footerHotspots = {}

    local cursor = 2
    for _, segment in ipairs(segments) do
        local label = segment.label and (segment.label .. ": ") or ""
        local text = label .. tostring(segment.value)
        if cursor + #text > width then break end
        renderer:write(cursor, height, label, "footerText", "footerBg")
        renderer:write(cursor + #label, height, tostring(segment.value),
            segment.color or "footerText", "footerBg")
        footerHotspots[#footerHotspots + 1] = {
            label = segment.label, x1 = cursor, x2 = cursor + #text - 1,
        }
        cursor = cursor + #text + 2
    end
end

--- Tell the user the display is unusable instead of drawing a broken layout.
local function drawTooSmall()
    local width, height = renderer:size()
    renderer:beginFrame()
    renderer:clear("background")

    local lines = {
        { text = "MONITOR TOO SMALL", fg = "statusError" },
        { text = ("have %dx%d"):format(width, height), fg = "textDim" },
        { text = ("need %dx%d"):format(options.minWidth, options.minHeight), fg = "textDim" },
        { text = options.minHint, fg = "text" },
    }

    local row = math.max(1, math.floor((height - #lines) / 2) + 1)
    for _, line in ipairs(lines) do
        if row > height then break end
        renderer:writeCentered(1, row, width, line.text, line.fg, "background")
        row = row + 1
    end
    renderer:endFrame()
end

--- Draw one frame. Returns false when nothing needed repainting.
function navigation.draw(force)
    if not renderer then return false end
    if not dirty and not force then return false end

    local width, height = renderer:size()
    if width < options.minWidth or height < options.minHeight then
        dirty = false
        drawTooSmall()
        return true
    end

    local entry = stack[#stack]
    dirty = false

    if entry and entry.screen.needsLayout then navigation.relayout() end
    if entry then
        local ok, err = pcall(entry.screen.update, entry.screen)
        if not ok then log.error("screen '%s' update failed: %s", entry.name, tostring(err)) end
    end

    renderer:beginFrame()
    renderer:clear("background")

    if options.showHeader then drawHeader(entry) end

    if entry then
        local ok, err = pcall(entry.screen.draw, entry.screen, renderer)
        if not ok then
            log.error("screen '%s' draw failed: %s", entry.name, tostring(err))
            renderer:write(2, 3, "Screen error: " .. util.truncate(tostring(err), renderer:width() - 16),
                "statusError", "background")
        end
    else
        renderer:writeCentered(1, math.floor(renderer:height() / 2), renderer:width(),
            "No screen loaded", "textDim", "background")
    end

    if options.showFooter then drawFooter() end
    renderer:endFrame()
    return true
end

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------

--- Route a touch/click in surface coordinates.
-- @return boolean true when something handled it
function navigation.handleTouch(px, py)
    if not renderer then return false end

    if options.showHeader and py == 1 then
        if backHotspot and px >= backHotspot.x1 and px <= backHotspot.x2 then
            navigation.back()
            return true
        end
        bus.emit("ui.header_touch", { x = px })
        return true
    end

    local height = renderer:height()
    if options.showFooter and py == height then
        local hit = nil
        for _, hotspot in ipairs(footerHotspots) do
            if px >= hotspot.x1 and px <= hotspot.x2 then hit = hotspot.label break end
        end
        bus.emit("ui.footer_touch", { x = px, label = hit })
        return true
    end

    local entry = stack[#stack]
    if not entry then return false end

    local ok, handled = pcall(entry.screen.handleTouch, entry.screen, px, py)
    if not ok then
        log.error("screen '%s' touch failed: %s", entry.name, tostring(handled))
        return false
    end
    if handled then dirty = true end
    return handled == true
end

--- Forward an application event to the active screen.
function navigation.dispatchEvent(name, ...)
    local entry = stack[#stack]
    if not entry then return end
    local ok, err = pcall(entry.screen.onEvent, entry.screen, name, ...)
    if not ok then log.error("screen '%s' onEvent failed: %s", entry.name, tostring(err)) end
end

--- Handle a monitor/terminal resize.
function navigation.onResize()
    if not renderer then return end
    renderer:refreshSize()
    navigation.relayout()
end

function navigation.shutdown()
    for index = #stack, 1, -1 do
        unmountScreen(stack[index])
        stack[index] = nil
    end
end

return navigation

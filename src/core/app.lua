--- Application lifecycle: boot, event loop, shutdown.
--
-- Boot order matters and is deliberate:
--   config -> logger -> persistence -> state -> peripherals -> adapters ->
--   display -> UI -> modules -> network -> scheduler -> loop
--
-- The event loop is the only place in BaseOS that calls `os.pullEventRaw`.
-- Raw CC events are republished on the event bus under their own name, so any
-- subsystem can listen without owning a loop of its own.

local util = require("core.util")
local config = require("core.config")
local logger = require("core.logger")
local bus = require("core.event_bus")
local state = require("core.state")
local scheduler = require("core.scheduler")

local peripheralManager = require("peripherals.manager")
local adapters = require("adapters.registry")
local persistence = require("services.persistence")
local alerts = require("services.alerts")
local network = require("network.network")
local moduleRegistry = require("modules.registry")

local theme = require("ui.theme")
local Renderer = require("ui.renderer")
local navigation = require("ui.navigation")

local log = logger.scoped("app")

local app = {}

local running = false
local renderer = nil
local displayName = nil
local displayIsTerminal = false
local bootTime = util.nowMs()
local context = nil

---------------------------------------------------------------------------
-- Display
---------------------------------------------------------------------------

--- Pick the output device: the `mainMonitor` alias, then any monitor, then the
--- computer terminal (when `system.ui.useTerminalFallback` allows it).
local function resolveDisplay()
    local monitor = peripheralManager.get("mainMonitor") or peripheralManager.firstOfType("monitor")

    if monitor then
        displayName = monitor.name()
        displayIsTerminal = false
        return Renderer.new(monitor, {
            name = displayName,
            isMonitor = true,
            textScale = config.get("system.ui.monitorTextScale", 0.5),
        })
    end

    if config.get("system.ui.useTerminalFallback", true) then
        displayName = "terminal"
        displayIsTerminal = true
        log.warn("no monitor found, using the computer terminal")
        return Renderer.new(term.native and term.native() or term, { name = "terminal" })
    end

    return nil
end

local function registerScreens()
    navigation.register("dashboard", function(params)
        return require("ui.screens.dashboard").new(params)
    end)
    navigation.register("module_detail", function(params)
        -- A module may ship its own detail screen; fall back to the generic one.
        local factory = moduleRegistry.detailScreenFactory(params.moduleId)
        if factory then
            local ok, screen = pcall(factory, params)
            if ok and screen then return screen end
            log.error("custom detail screen for '%s' failed, using the generic one",
                tostring(params.moduleId))
        end
        return require("ui.screens.module_detail").new(params)
    end)
    navigation.register("module_list", function(params)
        return require("ui.screens.module_list").new(params)
    end)
    navigation.register("alerts", function(params)
        return require("ui.screens.alerts").new(params)
    end)
    navigation.register("peripherals", function(params)
        return require("ui.screens.peripherals").new(params)
    end)
    navigation.register("logs", function(params)
        return require("ui.screens.logs").new(params)
    end)
end

--- Footer segments: overall status, power (when the module exists) and alerts.
local function statusProvider()
    local segments = {}

    local worst = alerts.worstSeverity()
    segments[#segments + 1] = {
        label = "Status",
        value = worst == "critical" and "CRITICAL" or (worst and "WARNING" or "ONLINE"),
        color = worst and theme.severityColor(worst) or theme.get("statusOk"),
    }

    -- Power is only meaningful once the module found something to measure.
    local power = state.get("modules.power")
    local powerRecord = moduleRegistry.get("power")
    local powerData = powerRecord and powerRecord.def
    if power and powerData and powerData.sources and #powerData.sources > 0 then
        segments[#segments + 1] = {
            label = "Power",
            value = util.formatPercent(powerData.percentage or 0),
            color = theme.statusColor(power.status),
        }
    end

    local count = alerts.count()
    segments[#segments + 1] = {
        label = "Alerts",
        value = tostring(count),
        color = count > 0 and theme.severityColor(worst) or theme.get("footerText"),
    }

    segments[#segments + 1] = { label = "Modules", value = tostring(moduleRegistry.count()) }
    return segments
end

---------------------------------------------------------------------------
-- Boot
---------------------------------------------------------------------------

local function buildContext(options)
    return {
        version = options.version or config.get("system.version", "0.1.0"),
        root = options.root or "",
        require = options.require or require,

        config = config,
        logger = logger,
        bus = bus,
        state = state,
        scheduler = scheduler,
        util = util,

        peripherals = peripheralManager,
        adapters = adapters,
        alerts = alerts,
        persistence = persistence,
        network = network,
        navigation = navigation,
        modules = moduleRegistry,
        theme = theme,
        app = app,
    }
end

function app.boot(options)
    options = options or {}
    bootTime = util.nowMs()

    -- 1. Configuration
    config.load(options)

    -- 2. Logging. Terminal output is disabled when the UI owns the terminal.
    local logging = config.get("system.logging", {})
    logger.configure({
        level = logging.level or "INFO",
        toTerminal = logging.toTerminal ~= false,
        toFile = logging.toFile ~= false,
        filePath = logging.filePath or "data/baseos.log",
        root = options.root,
    })
    log.info("BaseOS %s starting on computer %d", tostring(options.version), os.getComputerID())
    if #config.sources() > 0 then
        log.info("configuration: %s", table.concat(config.sources(), ", "))
    else
        log.warn("no configuration files found, using defaults")
    end

    -- 3. Storage + state
    persistence.init({
        directory = config.get("system.persistence.directory", "data"),
        root = options.root,
    })
    state.reset()
    state.set("system", {
        name = config.get("system.name", "BASE CONTROL"),
        version = options.version,
        computerId = os.getComputerID(),
        label = os.getComputerLabel(),
        role = config.get("system.nodeRole", "master"),
        bootTime = bootTime,
    })

    -- 4. Peripherals
    peripheralManager.init({
        aliases = config.get("peripherals.aliases", {}),
        rescanInterval = config.get("peripherals.rescanInterval", 30),
        scheduler = scheduler,
    })

    -- 5. Adapters
    adapters.setPeripheralManager(peripheralManager)
    adapters.load(config.get("adapters.extra", {}), options.require)

    -- 6. Display
    renderer = resolveDisplay()
    if not renderer then
        error("no display available: attach a monitor or enable system.ui.useTerminalFallback", 0)
    end
    if displayIsTerminal then
        -- The renderer owns the terminal now; keep the log off it.
        logger.configure({ toTerminal = false })
    end

    theme.apply({
        preset = config.get("theme.preset", "dark"),
        overrides = config.get("theme.overrides", {}),
        chars = config.get("theme.chars", nil),
        monochrome = not renderer:supportsColor(),
    })

    local width, height = renderer:size()
    state.set("system.display", { name = displayName, width = width, height = height })
    log.info("display: %s (%dx%d)", displayName, width, height)

    -- 7. UI
    navigation.init(renderer, {
        title = config.get("system.name", "BASE CONTROL"),
        showHeader = config.get("system.ui.showHeader", true),
        showFooter = config.get("system.ui.showFooter", true),
        useInGameClock = config.get("system.useInGameClock", true),
        paddingX = config.get("system.ui.paddingX", 1),
        paddingY = config.get("system.ui.paddingY", 1),
        minWidth = config.get("system.ui.minWidth", 45),
        minHeight = config.get("system.ui.minHeight", 18),
    })
    registerScreens()
    navigation.setStatusProvider(statusProvider)

    -- 8. Modules
    context = buildContext(options)
    moduleRegistry.setContext(context)
    moduleRegistry.watchPeripherals()
    -- Plain modules first, then template instances (farms, reactors, ...).
    local moduleEntries = {}
    for _, id in ipairs(config.get("modules.enabled", {})) do
        moduleEntries[#moduleEntries + 1] = id
    end
    for _, instance in ipairs(config.get("modules.instances", {})) do
        moduleEntries[#moduleEntries + 1] = instance
    end
    moduleRegistry.load(moduleEntries, options.require)
    moduleRegistry.setupAll()
    moduleRegistry.startAll()

    -- 9. Network (a no-op unless enabled in config)
    network.init(config.section("network"))
    if network.isReady() then
        network.startHeartbeat(scheduler, config.get("system.nodeRole", "master"))
    end

    -- 10. UI wiring + first paint
    bus.on("ui.footer_touch", function() navigation.push("alerts", {}) end, { owner = "app" })
    bus.on("ui.header_touch", function()
        if navigation.depth() == 1 then navigation.push("module_list", {}) end
    end, { owner = "app" })
    bus.on("alert.raised", function() navigation.invalidate() end, { owner = "app" })

    navigation.reset(config.get("system.ui.homeScreen", "dashboard"), {})

    -- 11. Timers
    scheduler.every(config.get("system.ui.refreshInterval", 1.0), function()
        navigation.invalidate()
    end, { name = "ui.refresh", owner = "app" })
    scheduler.start()

    navigation.draw(true)
    log.info("boot complete in %dms", util.nowMs() - bootTime)
    return true
end

---------------------------------------------------------------------------
-- Event loop
---------------------------------------------------------------------------

--- Route one CC event. Returns false to stop the loop.
function app.handleEvent(event)
    local name = event[1]

    if name == "terminate" then
        log.info("terminate requested")
        return false
    end

    if name == "timer" then
        scheduler.onTimer(event[2])
    end

    -- Every raw event is available on the bus under its own name.
    bus.emit(name, table.unpack(event, 2, event.n))

    if name == "monitor_touch" then
        if not displayIsTerminal and event[2] == displayName then
            navigation.handleTouch(event[3], event[4])
        end
    elseif name == "mouse_click" then
        if displayIsTerminal then navigation.handleTouch(event[3], event[4]) end
    elseif name == "monitor_resize" then
        if not displayIsTerminal and event[2] == displayName then navigation.onResize() end
    elseif name == "term_resize" then
        if displayIsTerminal then navigation.onResize() end
    elseif name == "peripheral" or name == "peripheral_detach" then
        -- The peripheral manager reacts through the bus; the display may have
        -- appeared or vanished, so re-evaluate it.
        app.checkDisplay()
    end

    navigation.dispatchEvent(name, table.unpack(event, 2, event.n))
    return true
end

--- Re-resolve the display after a peripheral change.
function app.checkDisplay()
    local monitor = peripheralManager.get("mainMonitor") or peripheralManager.firstOfType("monitor")

    if monitor and monitor.name() ~= displayName then
        log.info("switching display to %s", monitor.name())
        renderer = Renderer.new(monitor, {
            name = monitor.name(),
            isMonitor = true,
            textScale = config.get("system.ui.monitorTextScale", 0.5),
        })
        displayName = monitor.name()
        displayIsTerminal = false
        theme.apply({
            preset = config.get("theme.preset", "dark"),
            overrides = config.get("theme.overrides", {}),
            monochrome = not renderer:supportsColor(),
        })
        navigation.setRenderer(renderer)
        navigation.draw(true)
    elseif not monitor and not displayIsTerminal then
        log.warn("display '%s' disappeared", tostring(displayName))
        if config.get("system.ui.useTerminalFallback", true) then
            renderer = Renderer.new(term.native and term.native() or term, { name = "terminal" })
            displayName = "terminal"
            displayIsTerminal = true
            logger.configure({ toTerminal = false })
            navigation.setRenderer(renderer)
            navigation.draw(true)
        end
    end
end

function app.loop()
    running = true
    while running do
        local event = table.pack(os.pullEventRaw())

        local ok, keepRunning = pcall(app.handleEvent, event)
        if not ok then
            log.error("event handling failed for '%s': %s", tostring(event[1]), tostring(keepRunning))
        elseif keepRunning == false then
            running = false
        end

        if running then
            local drawn, err = pcall(navigation.draw)
            if not drawn then log.error("draw failed: %s", tostring(err)) end
        end
    end
end

function app.stop() running = false end

function app.isRunning() return running end

function app.context() return context end

function app.renderer() return renderer end

function app.uptime() return (util.nowMs() - bootTime) / 1000 end

---------------------------------------------------------------------------
-- Shutdown
---------------------------------------------------------------------------

function app.shutdown()
    log.info("shutting down")
    pcall(scheduler.stop)
    pcall(moduleRegistry.stopAll)
    pcall(navigation.shutdown)
    pcall(network.shutdown)
    pcall(peripheralManager.shutdown)

    -- Leave the monitor blank rather than frozen on a stale frame.
    if renderer then
        pcall(function()
            renderer:beginFrame()
            renderer:clear("background")
            renderer:writeCentered(1, 1, renderer:width(), "BaseOS stopped", "textDim", "background")
            renderer:endFrame()
        end)
    end

    if term and term.native then pcall(term.redirect, term.native()) end
    logger.shutdown()
end

--- Entry point used by startup.lua.
function app.run(options)
    local ok, err = pcall(app.boot, options)
    if not ok then
        pcall(app.shutdown)
        error(err, 0)
    end

    app.loop()
    app.shutdown()
    return true
end

return app

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
local telemetry = require("network.telemetry")
local moduleRegistry = require("modules.registry")
local identity = require("core.identity")
local snapshot = require("services.snapshot")
local history = require("services.history")
local activity = require("services.activity")
local security = require("services.security")

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
local me = nil          -- this computer's identity
local uiActive = false  -- false on a node: there is no UI to route touches to

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
    navigation.register("nodes", function(params)
        return require("ui.screens.nodes").new(params)
    end)
    navigation.register("metric_detail", function(params)
        return require("ui.screens.metric_detail").new(params)
    end)
    navigation.register("display_view", function(params)
        return require("ui.screens.display_view").new(params)
    end)
    navigation.register("map", function(params)
        return require("ui.screens.base_map").new(params)
    end)
    navigation.register("layout_editor", function(params)
        return require("ui.screens.layout_editor").new(params)
    end)
    navigation.register("security", function(params)
        return require("ui.screens.security").new(params)
    end)
    navigation.register("name_entry", function(params)
        return require("ui.screens.name_entry").new(params)
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

    -- Only worth a slot once this base actually has nodes.
    local total, online = 0, 0
    for _, node in pairs(state.get("nodes", {})) do
        total = total + 1
        if node.online then online = online + 1 end
    end
    if total > 0 then
        segments[#segments + 1] = {
            label = "Nodes",
            value = online .. "/" .. total,
            color = online == total and theme.get("statusOk") or theme.get("statusWarn"),
        }
    end

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
        telemetry = telemetry,
        snapshot = snapshot,
        history = history,
        activity = activity,
        security = security,
        theme = theme,
        app = app,
        identity = me,
        -- Modules must not offer actions that open screens on a headless node.
        hasUI = uiActive,
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

    -- Who am I? Written once by `setup` and never touched by the updater. A
    -- computer that was never set up is a master, so single-computer installs
    -- keep working exactly as they did before roles existed.
    me = identity.load(options.root) or identity.default()
    -- Masters and displays draw screens; nodes are headless.
    uiActive = identity.hasUI(me)
    log.info("identity: %s '%s' (%s)", me.role, tostring(me.name),
        me.implicit and "assumed" or "configured")

    state.set("system", {
        name = config.get("system.name", "BASE CONTROL"),
        version = options.version,
        computerId = os.getComputerID(),
        label = os.getComputerLabel(),
        role = me.role,
        node = me.name,
        profile = me.profile,
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

    -- 6. Display. Nodes are headless: no monitor, no navigation, no touches.
    renderer = uiActive and resolveDisplay() or nil
    if uiActive and not renderer then
        error("no display available: attach a monitor or enable system.ui.useTerminalFallback", 0)
    end
    -- Whoever owns the terminal - the UI fallback, or a node's status display -
    -- must not have the log scribbling over it.
    if (renderer and displayIsTerminal) or not uiActive then
        logger.configure({ toTerminal = false })
    end

    if renderer then
        theme.apply({
            preset = config.get("theme.preset", "dark"),
            overrides = config.get("theme.overrides", {}),
            chars = config.get("theme.chars", nil),
            monochrome = not renderer:supportsColor(),
        })

        local width, height = renderer:size()
        state.set("system.display", { name = displayName, width = width, height = height })
        log.info("display: %s (%dx%d)", displayName, width, height)
    end

    -- 7. UI
    if uiActive then
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
    end

    -- 8. Modules
    context = buildContext(options)
    moduleRegistry.setContext(context)
    moduleRegistry.watchPeripherals()
    -- The identity decides which modules this computer runs; config is the
    -- fallback for a custom node and for installs that never ran `setup`.
    local moduleEntries = {}
    for _, id in ipairs(me.modules or config.get("modules.enabled", {})) do
        moduleEntries[#moduleEntries + 1] = id
    end
    for _, instance in ipairs(config.get("modules.instances", {})) do
        moduleEntries[#moduleEntries + 1] = instance
    end
    moduleRegistry.load(moduleEntries, options.require)

    -- Last known values are back before the first poll, so a reboot shows data
    -- immediately instead of an empty dashboard.
    snapshot.restore(context)
    moduleRegistry.setupAll()
    moduleRegistry.startAll()

    -- 9. Network. A node is useless without it, and a computer whose role was
    -- chosen deliberately belongs to a multi-computer base, so both turn it on.
    -- An install that never ran `setup` keeps the config default (off).
    local networkSettings = util.deepCopy(config.section("network"))
    networkSettings.enabled = networkSettings.enabled or not me.implicit
    networkSettings.hostname = networkSettings.hostname or me.name
    network.init(networkSettings)
    if network.isReady() then
        network.startHeartbeat(scheduler, me.role)
    end

    -- Nodes publish; masters and displays collect. Neither ever reads the
    -- other's peripherals.
    if uiActive then
        telemetry.startCollector(context, config.get("network.telemetry", {}))
    else
        telemetry.startPublisher(context, config.get("network.telemetry", {}))
    end

    -- Trends need samples, and samples come from module polls.
    history.start(context, config.get("system.history", {}))
    activity.start(context)
    security.start(context)

    -- 10. UI wiring + first paint
    if uiActive then
    -- The footer is a set of shortcuts: touching a segment opens what it counts.
    bus.on("ui.footer_touch", function(payload)
        local label = payload and payload.label
        if label == "Nodes" then
            navigation.push("nodes", {})
        elseif label == "Modules" then
            navigation.push("module_list", {})
        else
            navigation.push("alerts", {})
        end
    end, { owner = "app" })
    bus.on("ui.header_touch", function()
        if navigation.depth() == 1 then navigation.push("module_list", {}) end
    end, { owner = "app" })
    bus.on("alert.raised", function() navigation.invalidate() end, { owner = "app" })

    -- A display boots straight into the view it was pinned to; a master gets
    -- the dashboard. Either way that screen is the root of the stack.
    if identity.isDisplay(me) then
        local view = me.view or { title = "BASE", modules = "*" }
        if view.screen then
            navigation.reset(view.screen, { view = view })
        else
            navigation.reset("display_view", { view = view })
        end
        app.startReturnHome(config.get("system.ui.returnHomeAfter", 60))
    else
        navigation.reset(config.get("system.ui.homeScreen", "dashboard"), {})
    end

    scheduler.every(config.get("system.ui.refreshInterval", 1.0), function()
        navigation.invalidate()
    end, { name = "ui.refresh", owner = "app" })
    else
        -- A node still owes an explanation to whoever opens its terminal.
        scheduler.every(3, app.printNodeStatus,
            { name = "node.status", owner = "app", immediate = true })
    end

    -- 11. Timers
    snapshot.start(context, config.get("system.persistence.snapshotInterval", 60))
    scheduler.start()

    if uiActive then navigation.draw(true) end
    log.info("boot complete in %dms", util.nowMs() - bootTime)
    return true
end

---------------------------------------------------------------------------
-- Display behaviour
---------------------------------------------------------------------------

local lastTouchAt = 0

--- A display left on a sub-screen should go back to the view it exists to show,
--- otherwise a passing click strands it there until someone notices.
function app.startReturnHome(seconds)
    if not seconds or seconds <= 0 then return nil end

    return scheduler.every(math.max(5, seconds / 4), function()
        if navigation.depth() <= 1 then return end
        if (util.nowMs() - lastTouchAt) / 1000 < seconds then return end
        log.debug("returning the display to its view")
        navigation.home()
    end, { name = "display.returnHome", owner = "app" })
end

---------------------------------------------------------------------------
-- Node terminal
---------------------------------------------------------------------------

--- A node has no monitor, so its terminal is the only place it can report.
function app.printNodeStatus()
    local target = term.native and term.native() or term
    if not target then return end

    pcall(function()
        target.clear()
        target.setCursorPos(1, 1)

        local lines = {
            "BaseOS node  " .. tostring(context and context.version or "?"),
            "",
            "name:    " .. tostring(me and me.name),
            "profile: " .. tostring(me and me.profile or "custom"),
            "network: " .. (network.isReady()
                and ("online as '" .. tostring(network.hostname()) .. "'")
                or "OFFLINE - attach a modem"),
            "uptime:  " .. util.formatDuration(app.uptime()),
            "",
            "modules:",
        }

        for _, record in ipairs(moduleRegistry.all()) do
            lines[#lines + 1] = ("  %-14s %s"):format(record.id,
                record.statusText or tostring(record.status))
        end

        lines[#lines + 1] = ""
        lines[#lines + 1] = "alerts: " .. alerts.count()
        lines[#lines + 1] = "'setup' changes this computer's role."

        local _, height = target.getSize()
        for index = 1, math.min(#lines, height) do
            target.setCursorPos(1, index)
            target.write(lines[index])
        end
    end)
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

    -- A node has no UI: everything below here is master-only routing.
    if not uiActive then return true end

    if name == "monitor_touch" then
        if not displayIsTerminal and event[2] == displayName then
            lastTouchAt = util.nowMs()
            navigation.handleTouch(event[3], event[4])
        end
    elseif name == "mouse_click" then
        if displayIsTerminal then
            lastTouchAt = util.nowMs()
            navigation.handleTouch(event[3], event[4])
        end
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
    if not uiActive then return end
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

        if running and uiActive then
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
    -- Persist before stopping: a clean shutdown should not lose the last values.
    if context then pcall(snapshot.save, context) end
    pcall(scheduler.stop)
    pcall(moduleRegistry.stopAll)
    pcall(navigation.shutdown)
    pcall(telemetry.shutdown)
    pcall(history.shutdown)
    pcall(activity.shutdown)
    pcall(security.shutdown)
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

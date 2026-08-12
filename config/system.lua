--- Core system settings.
-- Anything omitted here falls back to the defaults in src/core/config.lua.

return {
    -- Shown in the dashboard header.
    name = "BASE CONTROL",

    -- "master" runs the UI and owns the modules. Remote computers use "node".
    nodeRole = "master",

    -- Use the Minecraft clock in the header instead of the real world clock.
    useInGameClock = true,

    logging = {
        level = "INFO",          -- DEBUG | INFO | WARN | ERROR
        toTerminal = true,       -- ignored when the UI runs on the terminal
        toFile = true,
        filePath = "data/baseos.log",
    },

    ui = {
        homeScreen = "dashboard",
        refreshInterval = 1.0,   -- seconds between dashboard repaints
        monitorTextScale = 0.5,  -- 0.5 fits the most information on a monitor
        useTerminalFallback = true,
        showHeader = true,
        showFooter = true,

        -- Margen entre la cabecera/pie y el contenido. Se ignora solo en
        -- pantallas muy pequeñas, donde cada fila cuenta.
        paddingX = 1,
        paddingY = 1,

        -- Por debajo de esto la UI muestra "MONITOR TOO SMALL" en lugar de
        -- dibujar algo ilegible. Tamaño recomendado: monitor de 3x2 o mayor.
        minWidth = 26,
        minHeight = 10,
    },

    modules = {
        defaultPollInterval = 2.0,
    },

    persistence = {
        directory = "data",
    },
}

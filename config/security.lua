--- Quién puede accionar qué.
--
-- IMPORTANTE — lo que se puede y no se puede saber:
--
-- El evento `monitor_touch` de ComputerCraft trae solo (lado, x, y). **No hay
-- forma de saber quién tocó la pantalla.** Verificado en el propio jar.
--
-- Por eso hay dos modos:
--
--   mode = "session"    Clic derecho sobre el bloque Player Detector para
--                       identificarte. Advanced Peripherals emite `playerClick`
--                       con tu nombre y se abre una sesión de unos segundos.
--                       Es identidad real: sabemos exactamente quién.
--
--   mode = "proximity"  Basta con que un jugador autorizado esté dentro del
--                       radio del detector. Más cómodo pero más débil:
--                       cualquiera a su lado puede pulsar el botón.
--
-- Recomendación: pon el Player Detector **junto al monitor**. Con `session`
-- funciona como una tarjeta de acceso — tocas el detector y el panel se
-- desbloquea unos segundos.
--
-- Desactivado por defecto. Sin `protect`, todo está permitido.

return {
    enabled = false,

    mode = "session",        -- session | proximity

    -- Segundos que dura la sesión tras identificarte. Cada acción la renueva.
    sessionSeconds = 60,

    -- Radio en bloques para el modo proximity.
    detectorRadius = 8,

    -- Si no hay Player Detector conectado: true permite igualmente (y lo avisa
    -- en el log), false bloquea. `true` evita quedarte fuera de tu propia base
    -- si el detector se rompe.
    failOpen = true,

    -- Acciones que requieren autorización. El resto siempre están permitidas.
    -- El id de una acción es "<modulo>.<accion>", y admite comodines:
    --     "*"                todo
    --     "demo_farm.*"      cualquier acción de ese módulo
    --     "*.stop"           la acción "stop" de cualquier módulo
    protect = {
        -- "*.stop",
        -- "*.start",
        -- "*.reboot",
        -- "power.*",
    },

    -- Perfiles. Cada uno lista jugadores y qué se les permite.
    profiles = {
        -- admin = {
        --     players = { "lchrios" },
        --     allow = { "*" },
        -- },
        -- operator = {
        --     players = { "amigo1", "amigo2" },
        --     allow = { "*.start", "*.stop" },
        -- },
    },
}

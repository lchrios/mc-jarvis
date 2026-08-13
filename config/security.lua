--- Quién puede accionar qué.
--
-- LO QUE SE PUEDE Y NO SE PUEDE SABER
--
-- El evento `monitor_touch` de ComputerCraft trae solo (lado, x, y).
-- **No hay forma de saber quién tocó la pantalla.** Verificado en el jar.
--
-- La única identidad real disponible es `playerClick`: Advanced Peripherals lo
-- emite con tu nombre cuando haces **clic derecho sobre el bloque Player
-- Detector**. Por eso el modo recomendado es `session`:
--
--     Pon el Player Detector JUNTO AL MONITOR.
--     Clic derecho = iniciar sesión. Los siguientes 60 s puedes accionar.
--
--   mode = "proximity" es la alternativa floja: basta con que un autorizado
--   esté en el radio, así que cualquiera a su lado también acciona.
--
-- Los usuarios se gestionan desde la pantalla ACCESS del panel y se guardan en
-- `data/security.dat`. Lo que declares aquí abajo es la semilla: no se puede
-- borrar desde el panel, que es como te aseguras de no quedarte fuera.
--
-- Desactivado por defecto, y sin `protect` todo está permitido.

return {
    enabled = false,

    mode = "session",        -- session | proximity

    sessionSeconds = 60,     -- lo que dura la sesión; cada acción la renueva
    enrollSeconds = 30,      -- ventana del modo escucha al registrar a alguien
    detectorRadius = 8,      -- solo para mode = "proximity"

    -- Si no hay Player Detector conectado: true permite igual (y lo avisa en el
    -- log), false bloquea. `true` evita que un bloque roto te deje sin control.
    failOpen = true,

    -- Acciones que requieren autorización. El resto siempre están permitidas.
    -- El id es "<modulo>.<accion>" y admite comodines:
    --     "*"              todo
    --     "demo_farm.*"    cualquier acción de ese módulo
    --     "*.stop"         la acción "stop" de cualquier módulo
    protect = {
        -- "*.stop",
        -- "*.start",
        -- "*.reboot",
    },

    -- Roles: qué puede hacer cada categoría. Estos tres vienen de serie y
    -- puedes redefinirlos o añadir los tuyos.
    --
    --   manage = true  ese rol puede registrar y quitar usuarios desde el panel
    roles = {
        -- admin    = { label = "Admin",    allow = { "*" }, manage = true },
        -- operator = { label = "Operator", allow = { "*.start", "*.stop" } },
        -- viewer   = { label = "Viewer",   allow = {} },
    },

    -- Semilla de usuarios. Pon aquí al menos un admin: es tu llave maestra, y
    -- no se puede borrar desde la pantalla.
    users = {
        -- { player = "lchrios", role = "admin" },
    },
}

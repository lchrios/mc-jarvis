--- Automatizaciones.
--
-- Una regla NO es un temporizador. Es una máquina de dos estados: entra cuando
-- `when` se cumple, y sale cuando se cumple `until_` **o** pasa `after`, lo que
-- ocurra primero.
--
-- Esa diferencia es todo el asunto: decirle a una granja "párate 30 segundos"
-- desperdicia producción si el buffer se vació a los 15, y la reenciende contra
-- un buffer todavía lleno si no se vació.
--
-- Si tocas el botón a mano, **tú ganas**: la regla suelta el control y no vuelve
-- a intervenir hasta que su condición de entrada deje de cumplirse y vuelva a
-- cumplirse. Así no te pelea.
--
-- CONDICIONES
--   { metric = "mob_farm.buffer", op = ">=", value = 0.9 }
--   { metric = "power.charge", op = "<", value = 0.2, for_ = "30s" }
--   { status = "power", is = "error" }
--   { trend  = "power.charge", direction = "down", over = "2m" }
--   { time   = { from = "22:00", to = "06:00" } }
--   { players = { online = 0, for_ = "10m" } }
--   { players = { name = "lchrios" } }
--   { alert  = "power.low" }         { severity = "critical" }
--   { node   = "power_node", online = false }
--
--   Se combinan con  { all = {...} }  { any = {...} }  { none = {...} }
--
-- ACCIONES
--   "mob_farm.stop"                        una acción de un módulo
--   { "mob_farm.stop", "lights.on" }       varias
--   { alert = { severity = "warning", message = "..." } }
--   { say = "texto" }                      lo recoge el notifier

return {
    enabled = true,

    -- Cada cuántos segundos se evalúan las reglas.
    interval = 2,

    -- ----------------------------------------------------------------------
    -- SET BASE
    --
    -- Todas vienen APAGADAS. Enciende la que quieras desde la pantalla RULES
    -- del panel, y ajústala ahí mismo: qué módulo, qué métrica, qué umbral.
    -- Los ids de módulo de abajo son ejemplos — cámbialos por los tuyos.
    --
    -- Una regla que apunte a un módulo que no tienes no hace nada y lo avisa
    -- una vez en el log, no en cada ciclo.
    --
    -- OJO CON LOS ACENTOS en `name` y en los mensajes: la pantalla de CC dibuja
    -- un glifo por byte, así que se pliegan a su letra sin tilde al pintarlos
    -- ("Energía" se ve "Energia"). En los comentarios escribe normal.
    -- ----------------------------------------------------------------------
    rules = {
        {
            id = "backpressure",
            name = "Granja atascada",
            enabled = false,
            -- Para la granja cuando el buffer se llena, y arráncala cuando se
            -- haya vaciado DE VERDAD, o al minuto, lo que llegue antes.
            when   = { metric = "demo_farm.buffer", op = ">=", value = 0.9 },
            do_    = "demo_farm.stop",
            until_ = { metric = "demo_farm.buffer", op = "<=", value = 0.3 },
            after  = "60s",
            then_  = "demo_farm.start",
        },

        {
            id = "low_power",
            name = "Energia critica",
            enabled = false,
            -- Baja Y bajando: no reacciona a un pico puntual.
            when = { all = {
                { metric = "power.charge", op = "<", value = 0.2 },
                { trend = "power.charge", direction = "down", over = "1m" },
            } },
            do_ = {
                "demo_farm.stop",
                { alert = { severity = "critical",
                            message = "Energia critica: granjas paradas" } },
            },
            until_ = { metric = "power.charge", op = ">=", value = 0.5 },
            then_  = { "demo_farm.start", { clearAlert = true } },
        },

        {
            id = "nobody_home",
            name = "Base vacia",
            enabled = false,
            -- Nadie conectado un rato: apaga lo prescindible.
            when   = { players = { online = 0, for_ = "10m" } },
            do_    = "demo_farm.stop",
            until_ = { players = { atLeast = 1 } },
            then_  = "demo_farm.start",
        },

        {
            id = "cells_full",
            name = "Celdas AE2 llenas",
            enabled = false,
            -- Antes de que la red se atasque del todo.
            when = { metric = "storage.cells", op = ">=", value = 0.9 },
            do_  = { alert = { severity = "warning",
                               message = "Las celdas de la red estan casi llenas" } },
            until_ = { metric = "storage.cells", op = "<=", value = 0.75 },
            then_  = { clearAlert = true },
        },

        {
            id = "node_down",
            name = "Nodo caido",
            enabled = false,
            -- Cambia "power_node" por el nombre real del tuyo.
            when = { node = "power_node", online = false },
            do_  = { alert = { severity = "critical",
                               message = "El nodo power_node dejo de reportar" } },
            until_ = { node = "power_node", online = true },
            then_  = { clearAlert = true },
        },

        {
            id = "night_shift",
            name = "Turno de noche",
            enabled = false,
            -- Ejemplo de horario: de noche, para lo ruidoso.
            when   = { time = { from = "22:00", to = "06:00" } },
            do_    = "demo_farm.stop",
            until_ = { time = { from = "06:00", to = "22:00" } },
            then_  = "demo_farm.start",
        },

        {
            id = "storage_offline",
            name = "Red de almacenamiento caida",
            enabled = false,
            when = { status = "storage", is = "error" },
            do_  = { alert = { severity = "critical",
                               message = "El bridge perdio la red" } },
            until_ = { status = "storage", isNot = "error" },
            then_  = { clearAlert = true },
        },
    },
}

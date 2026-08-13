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

    rules = {
        -- ------------------------------------------------------------------
        -- El ejemplo que motivó el diseño: para la granja cuando el buffer se
        -- llena, y arráncala cuando se haya vaciado DE VERDAD, o al minuto,
        -- lo que llegue antes.
        -- ------------------------------------------------------------------
        -- {
        --     id = "backpressure",
        --     name = "Mob farm atascada",
        --     when   = { metric = "mob_farm.buffer", op = ">=", value = 0.9 },
        --     do_    = "mob_farm.stop",
        --     until_ = { metric = "mob_farm.buffer", op = "<=", value = 0.3 },
        --     after  = "60s",
        --     then_  = "mob_farm.start",
        -- },

        -- Energía baja y bajando: no reacciona a un pico puntual.
        -- {
        --     id = "low_power",
        --     name = "Energía crítica",
        --     when = { all = {
        --         { metric = "power.charge", op = "<", value = 0.2 },
        --         { trend = "power.charge", direction = "down", over = "1m" },
        --     } },
        --     do_    = { "mob_farm.stop", { alert = { severity = "critical",
        --                message = "Energía crítica: granjas paradas" } } },
        --     until_ = { metric = "power.charge", op = ">=", value = 0.5 },
        --     then_  = { "mob_farm.start", { clearAlert = true } },
        -- },

        -- Nadie conectado: apaga lo prescindible.
        -- {
        --     id = "nobody_home",
        --     name = "Base vacía",
        --     when   = { players = { online = 0, for_ = "10m" } },
        --     do_    = "mob_farm.stop",
        --     until_ = { players = { atLeast = 1 } },
        --     then_  = "mob_farm.start",
        -- },
    },
}

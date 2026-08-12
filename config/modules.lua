--- Qué módulos carga BaseOS.
--
-- `enabled`   módulos sueltos: cada id es src/modules/<id>.lua
-- `instances` instancias de una plantilla: una misma implementación (farm)
--             sirve para todas las granjas que tengas, cambiando solo config.

return {
    enabled = {
        "system",
        "power",
        "storage",
        "demo_farm",   -- quítalo cuando tengas granjas reales
    },

    instances = {
        -- ------------------------------------------------------------------
        -- GRANJAS REALES
        --
        -- Descomenta y ajusta. Para saber qué poner en `output`, en el
        -- ordenador ejecuta:
        --     lua> peripheral.getNames()
        --     lua> peripheral.getType("minecraft:barrel_2")
        --
        -- `output` es el cofre/barril donde cae la producción. Apunta al
        -- buffer ANTES de que las tuberías se lo lleven, o el ritmo saldrá
        -- bajo (solo se ve lo que se queda entre dos lecturas).
        --
        -- `control` es opcional:
        --     { kind = "none" }                          solo monitorizar
        --     { kind = "redstone", side = "back" }        redstone del propio PC
        --     { kind = "integrator", side = "top" }       Redstone Integrator (AP)
        -- Añade invert = true si la granja funciona con la señal apagada.
        -- ------------------------------------------------------------------

        -- {
        --     id = "mob_farm",
        --     template = "farm",
        --     name = "Mob Farm",
        --     icon = "M",
        --     pollInterval = 5,
        --     settings = {
        --         output  = { type = "minecraft:barrel" },
        --         control = { kind = "redstone", side = "back" },
        --         bufferWarn = 0.90,
        --         bufferClear = 0.75,
        --         targetRate = 120,
        --         idleAfter = 120,
        --     },
        -- },

        -- {
        --     id = "tree_farm",
        --     template = "farm",
        --     name = "Tree Farm",
        --     icon = "T",
        --     settings = {
        --         output = { name = "minecraft:chest_4" },
        --         countItems = { "minecraft:oak_log" },
        --     },
        -- },
    },

    -- Configuración libre por módulo, se lee con
    -- ctx.config.get("modules.settings.<id>.<clave>").
    settings = {
        power = {
            lowPercentage = 0.25,
            criticalPercentage = 0.10,
        },
        storage = {},
        demo_farm = {},
    },
}

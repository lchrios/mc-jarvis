--- Which modules to load, and their per-install settings.
--
-- Each id maps to src/modules/<id>.lua. Order matters only for the automatic
-- dashboard layout used when config/layout.lua declares no zones.

return {
    enabled = {
        "system",
        "power",
        "storage",
        "demo_farm",   -- remove once real farm modules exist
    },

    -- Free-form per module configuration, read with
    -- ctx.config.get("modules.settings.<id>.<key>").
    settings = {
        power = {
            lowPercentage = 0.25,
            criticalPercentage = 0.10,
        },
        storage = {},
        demo_farm = {},
    },
}

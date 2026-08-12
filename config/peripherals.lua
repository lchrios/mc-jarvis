--- Logical peripheral aliases.
--
-- The peripheral manager binds each alias to a connected peripheral at boot and
-- rebinds it on attach/detach. Modules ask for the alias, never for a raw name,
-- so moving a machine only means editing this file.
--
-- Matcher fields:
--   type     peripheral type, e.g. "monitor", "meBridge", "minecraft:chest"
--   name     exact peripheral name, e.g. "monitor_1" (wins over `type`)
--   method   require a method to be present, useful for generic capabilities
--   match    function(proxy, device) -> boolean, for anything else
--   optional true when the system should boot fine without it
--
-- Find the real names in game with:
--   lua> peripheral.getNames()
--   lua> peripheral.getType("monitor_1")
--   lua> peripheral.getMethods("meBridge_0")

return {
    aliases = {
        -- The dashboard is drawn here. Without it BaseOS falls back to the
        -- computer terminal.
        mainMonitor = { type = "monitor", optional = true },

        -- Uncomment as the base grows. Everything is optional: a missing
        -- peripheral marks its module unavailable, it never breaks the boot.

        -- mainMonitor      = { name = "monitor_3" },
        -- meBridge         = { type = "meBridge", optional = true },
        -- rsBridge         = { type = "rsBridge", optional = true },
        -- chatBox          = { type = "chatBox", optional = true },
        -- playerDetector   = { type = "playerDetector", optional = true },
        -- environment      = { type = "environmentDetector", optional = true },
        -- energyDetector   = { type = "energyDetector", optional = true },
        -- alarmSpeaker     = { type = "speaker", optional = true },
        -- mainEnergyCell   = { type = "powah:energy_cell_nitro", optional = true },
        -- farmOutput       = { name = "minecraft:barrel_2", optional = true },
    },

    -- Full rescan interval in seconds. Attach/detach events are handled
    -- immediately; this only catches topology changes that go unreported.
    rescanInterval = 30,
}

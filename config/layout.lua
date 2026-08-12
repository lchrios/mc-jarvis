--- Base map: which zones appear on the dashboard and where.
--
-- mode = "grid" (default)
--   Zones are placed on a virtual grid and scale to any monitor size. Use
--   col/row (1-indexed) and colSpan/rowSpan.
--
-- mode = "absolute"
--   Zones use raw character coordinates (x/y/width/height) inside the content
--   area. Use it for a pixel exact plan on a monitor you never resize.
--
-- Zone fields:
--   id        unique id
--   label     text shown on the tile
--   module    module id the tile is bound to (its live status is displayed)
--   screen    open this screen instead of the module detail view
--   icon      one or two characters drawn before the label
--   color     background colour name from ui/theme.lua
--
-- Editing this file is enough to rearrange the base: no code changes.

return {
    mode = "grid",

    -- Separación entre tiles. "auto" usa 1 en monitores pequeños y 2 en los
    -- grandes; pon un número para fijarla.
    gap = "auto",

    grid = { columns = 12, rows = 6 },

    zones = {
        {
            id = "storage",
            label = "STORAGE",
            module = "storage",
            col = 1, row = 1, colSpan = 4, rowSpan = 3,
        },
        {
            id = "hub",
            label = "CENTRAL HUB",
            module = "system",
            col = 5, row = 1, colSpan = 4, rowSpan = 3,
        },
        {
            id = "power",
            label = "POWER",
            module = "power",
            col = 9, row = 1, colSpan = 4, rowSpan = 3,
        },
        {
            id = "farm_demo",
            label = "DEMO FARM",
            module = "demo_farm",
            col = 1, row = 4, colSpan = 4, rowSpan = 3,
        },
        {
            id = "modules",
            label = "ALL MODULES",
            screen = "module_list",
            col = 5, row = 4, colSpan = 4, rowSpan = 3,
        },
        {
            id = "alerts",
            label = "ALERTS",
            screen = "alerts",
            col = 9, row = 4, colSpan = 4, rowSpan = 3,
        },
    },
}

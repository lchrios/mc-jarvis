--- UI colours and box drawing characters.
--
-- `overrides` accepts any key from the palette in src/ui/theme.lua and any
-- value from the CC `colors` table. Monochrome monitors ignore all of this and
-- fall back to black and white automatically.

return {
    preset = "dark",   -- dark | light

    overrides = {
        -- headerBg = colors.purple,
        -- accent   = colors.orange,
    },

    -- Box drawing characters. ASCII by default because it renders identically
    -- on every monitor size and text scale.
    chars = {
        -- horizontal = "\140",
        -- vertical   = "\149",
    },
}

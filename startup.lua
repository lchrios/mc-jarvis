--- BaseOS entry point.
--
-- Bootstraps the shared module loader (boot.lua) and hands control to
-- `core.app`, which decides what to run from this computer's identity: the
-- touch UI on a master, a headless collector on a node.

local function bootstrap()
    local handle = fs.open("boot.lua", "r")
    if not handle then
        error("boot.lua is missing. Run 'updater force' to repair the install.", 0)
    end
    local source = handle.readAll()
    handle.close()

    local chunk, err = load(source, "@boot.lua", "t", _ENV or _G)
    if not chunk then error("boot.lua is corrupt: " .. tostring(err), 0) end
    return chunk()
end

local ok, err = pcall(function()
    local BASEOS = bootstrap()
    local app = BASEOS.require("core.app")
    return app.run({
        root = BASEOS.root,
        require = BASEOS.require,
        version = BASEOS.version,
    })
end)

if not ok then
    -- Make sure a crashed UI never leaves the user with a redirected terminal.
    if term and term.native then
        pcall(term.redirect, term.native())
    end
    if term and term.setBackgroundColor then
        pcall(term.setBackgroundColor, colors.black)
        pcall(term.setTextColor, colors.red)
    end
    print("")
    print("BaseOS stopped with an error:")
    print(tostring(err))
    if term and term.setTextColor then pcall(term.setTextColor, colors.white) end
    print("")
    print("'scan' inspects peripherals, 'setup' changes this computer's role,")
    print("'reset' wipes it back to a clean install.")
end

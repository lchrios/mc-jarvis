--- Factory reset: put a broken computer back to a clean install.
--
--   reset                wipe config/ and data/ (identity included)
--   reset --keep-setup   wipe data but keep this computer's role
--   reset --data         wipe only runtime data (logs, cached metrics)
--
-- The program files themselves are never touched: run `updater force`
-- afterwards to restore anything that was edited by hand.

local TARGETS = {
    config = { "config" },
    -- Everything except the identity, which --keep-setup preserves.
    data = { "data" },
}

local KEEP_ON_SETUP = { "data/node.dat" }

local function confirm(question)
    write(question .. " [y/N] ")
    return tostring(read() or ""):lower():sub(1, 1) == "y"
end

local function listFiles(root, into)
    if not fs.exists(root) then return into end
    if not fs.isDir(root) then
        into[#into + 1] = root
        return into
    end
    for _, name in ipairs(fs.list(root)) do
        listFiles(fs.combine(root, name), into)
    end
    return into
end

local function main(args)
    local keepSetup, dataOnly = false, false
    for _, argument in ipairs(args) do
        if argument == "--keep-setup" then keepSetup = true end
        if argument == "--data" then dataOnly = true keepSetup = true end
    end

    local roots = {}
    if not dataOnly then
        for _, path in ipairs(TARGETS.config) do roots[#roots + 1] = path end
    end
    for _, path in ipairs(TARGETS.data) do roots[#roots + 1] = path end

    local protected = {}
    if keepSetup then
        for _, path in ipairs(KEEP_ON_SETUP) do protected[path] = true end
    end

    local doomed = {}
    for _, root in ipairs(roots) do
        for _, path in ipairs(listFiles(root, {})) do
            if not protected[path] then doomed[#doomed + 1] = path end
        end
    end

    print("BaseOS factory reset")
    print("")

    if #doomed == 0 then
        print("Nothing to remove; this computer is already clean.")
        return
    end

    print("This will permanently delete " .. #doomed .. " file(s):")
    for index = 1, math.min(#doomed, 10) do
        print("  " .. doomed[index])
    end
    if #doomed > 10 then print("  ... and " .. (#doomed - 10) .. " more") end
    print("")

    if keepSetup then
        print("Keeping this computer's role (data/node.dat).")
    else
        print("Including this computer's role: you will be asked again at setup.")
    end
    print("Program files are untouched.")
    print("")

    -- A single "y" is too cheap for something irreversible.
    write("Type RESET to confirm: ")
    if read() ~= "RESET" then
        print("Cancelled. Nothing was changed.")
        return
    end

    local removed = 0
    for _, path in ipairs(doomed) do
        if pcall(fs.delete, path) then removed = removed + 1 end
    end

    print("")
    print("Removed " .. removed .. " file(s).")
    print("Run 'updater force' to restore the default config,")
    if not keepSetup then print("then 'setup' to say what this computer is.") end
    print("")
    if confirm("Reboot now?") then os.reboot() end
end

main({ ... })

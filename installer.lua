--- BaseOS installer / updater.
--
-- Pulls the project straight from GitHub into the computer. Get it once with:
--
--   wget https://raw.githubusercontent.com/lchrios/mc-jarvis/main/installer.lua installer
--
-- then, any time you want the latest code:
--
--   installer            install or update from the default branch
--   installer dev        install from another branch or tag
--   installer main clean wipe src/ first (use after renaming or deleting modules)
--
-- Your `config/` and `data/` are never overwritten: local tuning and logs
-- survive every update.

local REPO = "lchrios/mc-jarvis"
local DEFAULT_REF = "main"

--- Only these paths belong on the computer; docs and tools stay in the repo.
local INCLUDE = { "startup.lua", "installer.lua", "src/", "config/" }

--- Written only when missing, so an update never clobbers local settings.
local PRESERVE = { "config/" }

---------------------------------------------------------------------------

local function fail(message)
    printError(message)
    error("", 0)
end

local function matchesPrefix(path, prefixes)
    for _, prefix in ipairs(prefixes) do
        if path == prefix or path:sub(1, #prefix) == prefix then return true end
    end
    return false
end

local function fetch(url, description)
    -- GitHub rejects requests without a User-Agent.
    local response, err = http.get(url, { ["User-Agent"] = "BaseOS-Installer" })
    if not response then
        fail("Could not fetch " .. description .. ": " .. tostring(err))
    end

    local code = response.getResponseCode and response.getResponseCode() or 200
    local body = response.readAll()
    response.close()

    if code < 200 or code >= 300 then
        fail("Could not fetch " .. description .. ": HTTP " .. tostring(code))
    end
    return body
end

--- Every file in the repository at `ref`, via the git tree API.
-- Using the API instead of a hand written manifest means new modules are
-- picked up automatically.
local function listRepositoryFiles(ref)
    local url = ("https://api.github.com/repos/%s/git/trees/%s?recursive=1"):format(REPO, ref)
    local body = fetch(url, "the file list")

    local tree = textutils.unserialiseJSON(body)
    if type(tree) ~= "table" or type(tree.tree) ~= "table" then
        fail("Unexpected response from GitHub. Is the branch '" .. ref .. "' correct?")
    end
    if tree.truncated then
        print("Warning: GitHub truncated the file list; some files may be missing.")
    end

    local files = {}
    for _, entry in ipairs(tree.tree) do
        if entry.type == "blob" and matchesPrefix(entry.path, INCLUDE) then
            files[#files + 1] = entry.path
        end
    end
    table.sort(files)
    return files
end

local function writeFile(path, contents)
    local dir = fs.getDir(path)
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end

    local handle, err = fs.open(path, "w")
    if not handle then fail("Cannot write " .. path .. ": " .. tostring(err)) end
    handle.write(contents)
    handle.close()
end

---------------------------------------------------------------------------

local function main(args)
    if not http then
        fail("The HTTP API is disabled. Enable it in the CC:Tweaked config and retry.")
    end

    local ref = args[1] or DEFAULT_REF
    local clean = false
    for _, arg in ipairs(args) do
        if arg == "clean" then clean = true end
    end

    print("BaseOS installer")
    print("  repo:   " .. REPO)
    print("  branch: " .. ref)
    print("")

    local files = listRepositoryFiles(ref)
    if #files == 0 then fail("No installable files found at '" .. ref .. "'.") end
    print("Found " .. #files .. " file(s).")

    -- `clean` only touches src/: config and data are always left alone.
    if clean and fs.exists("src") then
        print("Removing the old src/ ...")
        fs.delete("src")
    end

    local written, skipped = 0, 0
    for index, path in ipairs(files) do
        if matchesPrefix(path, PRESERVE) and fs.exists(path) then
            skipped = skipped + 1
        else
            local url = ("https://raw.githubusercontent.com/%s/%s/%s"):format(REPO, ref, path)
            writeFile(path, fetch(url, path))
            written = written + 1
        end
        -- Overwrite one status line instead of scrolling the terminal.
        local _, y = term.getCursorPos()
        term.setCursorPos(1, y)
        term.clearLine()
        term.write(("[%d/%d] %s"):format(index, #files, path:sub(1, 30)))
    end

    print("")
    print("")
    print("Installed " .. written .. " file(s).")
    if skipped > 0 then
        print("Kept " .. skipped .. " existing config file(s).")
    end
    print("")
    print("Run 'reboot' to start BaseOS.")
end

main({ ... })

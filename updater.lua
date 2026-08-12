--- BaseOS updater.
--
--   updater            check GitHub and, if there is anything new, ask before applying
--   updater check      only report what would change
--   updater -y         apply without asking
--   updater force      re-download everything, even unchanged files
--   updater dev        work against another branch or tag
--
-- How it decides whether an update is needed: GitHub's git tree API returns a
-- SHA for the whole repository content plus one per file. The SHA of the last
-- successful install is stored in data/install.dat, so a comparison costs a
-- single request and knows exactly which files changed - only those are
-- downloaded.
--
-- Your `config/` is never overwritten and `data/` is never touched.

local REPO = "lchrios/mc-jarvis"
local DEFAULT_REF = "main"
local STATE_FILE = "data/install.dat"

--- Only these paths belong on the computer; docs and tools stay in the repo.
local INCLUDE = {
    "startup.lua", "installer.lua", "updater.lua", "version.lua", "VERSION",
    "src/", "config/",
}

--- Written only when missing, so an update never clobbers local settings.
local PRESERVE = { "config/" }

--- Files may only be deleted from here when they disappear upstream.
local PRUNABLE = { "src/" }

local COMMANDS = { check = true, force = true, install = true }

---------------------------------------------------------------------------
-- Helpers
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

local function fetch(url, description, optional)
    -- GitHub rejects requests without a User-Agent.
    local response, err = http.get(url, { ["User-Agent"] = "BaseOS-Updater" })
    if not response then
        if optional then return nil end
        fail("Could not fetch " .. description .. ": " .. tostring(err))
    end

    local code = response.getResponseCode and response.getResponseCode() or 200
    local body = response.readAll()
    response.close()

    if code < 200 or code >= 300 then
        if optional then return nil end
        fail("Could not fetch " .. description .. ": HTTP " .. tostring(code))
    end
    return body
end

local function writeFile(path, contents)
    local dir = fs.getDir(path)
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end

    local handle, err = fs.open(path, "w")
    if not handle then fail("Cannot write " .. path .. ": " .. tostring(err)) end
    handle.write(contents)
    handle.close()
end

local function shortSha(sha)
    return sha and sha:sub(1, 7) or "unknown"
end

---------------------------------------------------------------------------
-- Local install record
---------------------------------------------------------------------------

local function readState()
    if not fs.exists(STATE_FILE) then return nil end
    local handle = fs.open(STATE_FILE, "r")
    if not handle then return nil end
    local contents = handle.readAll()
    handle.close()

    local ok, state = pcall(textutils.unserialise, contents)
    if not ok or type(state) ~= "table" then return nil end
    return state
end

local function writeState(state)
    writeFile(STATE_FILE, textutils.serialise(state))
end

local function localVersion()
    if not fs.exists("VERSION") then return nil end
    local handle = fs.open("VERSION", "r")
    if not handle then return nil end
    local text = handle.readAll()
    handle.close()
    return (text:gsub("%s+", ""))
end

---------------------------------------------------------------------------
-- Remote
---------------------------------------------------------------------------

--- The installable files at `ref`, with the SHA of the whole tree.
local function remoteTree(ref)
    local url = ("https://api.github.com/repos/%s/git/trees/%s?recursive=1"):format(REPO, ref)
    local body = fetch(url, "the file list")

    local tree = textutils.unserialiseJSON(body)
    if type(tree) ~= "table" or type(tree.tree) ~= "table" then
        fail("Unexpected response from GitHub. Is the branch '" .. ref .. "' correct?")
    end
    if tree.truncated then
        print("Warning: GitHub truncated the file list; some files may be missing.")
    end

    local files, count = {}, 0
    for _, entry in ipairs(tree.tree) do
        if entry.type == "blob" and matchesPrefix(entry.path, INCLUDE) then
            files[entry.path] = entry.sha
            count = count + 1
        end
    end

    if count == 0 then fail("No installable files found at '" .. ref .. "'.") end
    return { sha = tree.sha, files = files, count = count }
end

local function remoteVersion(ref)
    local url = ("https://raw.githubusercontent.com/%s/%s/VERSION"):format(REPO, ref)
    local body = fetch(url, "VERSION", true)
    return body and (body:gsub("%s+", "")) or nil
end

---------------------------------------------------------------------------
-- Planning
---------------------------------------------------------------------------

--- Work out what an update would do.
-- Without a previous install record every file counts as new: that is the
-- honest answer, since we cannot know what is on disk.
local function plan(state, remote, force)
    local known = (state and state.files) or {}
    local result = { new = {}, changed = {}, removed = {}, kept = {}, unchanged = 0 }

    for path, sha in pairs(remote.files) do
        local isConfig = matchesPrefix(path, PRESERVE)
        if isConfig and fs.exists(path) then
            result.kept[#result.kept + 1] = path
        elseif not fs.exists(path) then
            result.new[#result.new + 1] = path
        elseif force or known[path] ~= sha then
            result.changed[#result.changed + 1] = path
        else
            result.unchanged = result.unchanged + 1
        end
    end

    -- Files that used to be installed and are gone upstream.
    for path in pairs(known) do
        if not remote.files[path] and matchesPrefix(path, PRUNABLE) and fs.exists(path) then
            result.removed[#result.removed + 1] = path
        end
    end

    table.sort(result.new)
    table.sort(result.changed)
    table.sort(result.removed)
    result.total = #result.new + #result.changed + #result.removed
    return result
end

local function printList(label, paths, limit)
    if #paths == 0 then return end
    print("  " .. label .. " (" .. #paths .. "):")
    for index = 1, math.min(#paths, limit) do
        print("    " .. paths[index])
    end
    if #paths > limit then
        print("    ... and " .. (#paths - limit) .. " more")
    end
end

---------------------------------------------------------------------------
-- Applying
---------------------------------------------------------------------------

local function apply(ref, remote, work)
    local written = 0

    local function download(path)
        local url = ("https://raw.githubusercontent.com/%s/%s/%s"):format(REPO, ref, path)
        writeFile(path, fetch(url, path))
        written = written + 1

        -- One status line, rewritten in place, instead of scrolling output.
        local _, y = term.getCursorPos()
        term.setCursorPos(1, y)
        term.clearLine()
        term.write(("[%d/%d] %s"):format(written, work.total, path:sub(1, 30)))
    end

    for _, path in ipairs(work.new) do download(path) end
    for _, path in ipairs(work.changed) do download(path) end

    for _, path in ipairs(work.removed) do
        fs.delete(path)
        written = written + 1
    end

    print("")
    return written
end

---------------------------------------------------------------------------
-- Entry point
---------------------------------------------------------------------------

local function confirm(question)
    write(question .. " [y/N] ")
    local answer = read()
    return tostring(answer or ""):lower():sub(1, 1) == "y"
end

local function main(args)
    if not http then
        fail("The HTTP API is disabled. Enable it in the CC:Tweaked config and retry.")
    end

    local ref, checkOnly, force, assumeYes = DEFAULT_REF, false, false, false
    for _, arg in ipairs(args) do
        if arg == "check" then checkOnly = true
        elseif arg == "force" then force = true
        elseif arg == "install" then assumeYes = true
        elseif arg == "-y" or arg == "--yes" then assumeYes = true
        elseif not COMMANDS[arg] and arg:sub(1, 1) ~= "-" then ref = arg end
    end

    local state = readState()
    local installedVersion = localVersion()

    print("BaseOS updater")
    print("  repo:      " .. REPO .. " (" .. ref .. ")")
    print("  installed: " .. (installedVersion or "unknown")
        .. "  " .. shortSha(state and state.sha))

    local remote = remoteTree(ref)
    local available = remoteVersion(ref)
    print("  available: " .. (available or "unknown") .. "  " .. shortSha(remote.sha))
    print("")

    -- The tree SHA covers the whole repository content: equal means identical.
    if not force and state and state.sha == remote.sha and state.ref == ref then
        print("Already up to date.")
        return
    end

    local work = plan(state, remote, force)

    if work.total == 0 then
        print("No file changes.")
        -- Record the new tree SHA so the next check is a single fast request.
        writeState({
            ref = ref, sha = remote.sha, version = available,
            files = remote.files, installedAt = os.epoch("utc"),
        })
        return
    end

    if state then
        print("Update available.")
    else
        print("No install record found; treating this as a fresh install.")
    end
    printList("new", work.new, 8)
    printList("updated", work.changed, 8)
    printList("removed", work.removed, 8)
    if #work.kept > 0 then
        print("  keeping your " .. #work.kept .. " config file(s)")
    end
    print("")

    if checkOnly then
        print("Run 'updater' to apply.")
        return
    end

    if not assumeYes and not confirm("Apply this update?") then
        print("Cancelled. Nothing was changed.")
        return
    end

    local written = apply(ref, remote, work)

    writeState({
        ref = ref, sha = remote.sha, version = available,
        files = remote.files, installedAt = os.epoch("utc"),
    })

    print("")
    print("Updated " .. written .. " file(s) to " .. (available or shortSha(remote.sha)) .. ".")
    print("Run 'reboot' to restart BaseOS.")
end

main({ ... })

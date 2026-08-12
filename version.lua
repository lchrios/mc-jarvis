--- Print what is installed on this computer. No network, no BaseOS running.
--
--   version
--
-- For a comparison against GitHub use `updater check` instead.

local STATE_FILE = "data/install.dat"

local function readFile(path)
    if not fs.exists(path) then return nil end
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local contents = handle.readAll()
    handle.close()
    return contents
end

local function readState()
    local contents = readFile(STATE_FILE)
    if not contents then return nil end
    local ok, state = pcall(textutils.unserialise, contents)
    if not ok or type(state) ~= "table" then return nil end
    return state
end

local function formatAge(milliseconds)
    local seconds = math.floor((os.epoch("utc") - milliseconds) / 1000)
    if seconds < 60 then return seconds .. "s ago" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m ago" end
    if seconds < 86400 then return math.floor(seconds / 3600) .. "h ago" end
    return math.floor(seconds / 86400) .. "d ago"
end

local function countFiles(state)
    if not state or type(state.files) ~= "table" then return nil end
    local total = 0
    for _ in pairs(state.files) do total = total + 1 end
    return total
end

-- Older installs kept it in "VERSION"; that name shadowed this program on a
-- case-insensitive filesystem, hence the rename.
local version = readFile("baseos.version") or readFile("VERSION")
version = version and version:gsub("%s+", "") or "unknown"

local state = readState()
local label = os.getComputerLabel()

print("BaseOS " .. version)
print("  computer:  " .. os.getComputerID() .. (label and (" (" .. label .. ")") or ""))

if state then
    print("  branch:    " .. tostring(state.ref or "?"))
    print("  commit:    " .. (state.sha and state.sha:sub(1, 7) or "?"))
    if state.installedAt then
        local ok, stamp = pcall(os.date, "%Y-%m-%d %H:%M", math.floor(state.installedAt / 1000))
        print("  updated:   " .. (ok and stamp or "?") .. "  (" .. formatAge(state.installedAt) .. ")")
    end
    local files = countFiles(state)
    if files then print("  files:     " .. files) end
else
    print("  no install record - installed by hand, or never updated")
end

print("")
print("'updater check' compares this with GitHub.")

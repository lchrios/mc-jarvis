--- BaseOS bootstrap installer.
--
--   wget https://raw.githubusercontent.com/lchrios/mc-jarvis/main/installer.lua installer
--   installer
--
-- This file only exists to get `updater.lua` onto a bare computer; the updater
-- does the actual work and is what you run from then on:
--
--   updater            check for updates and ask before applying
--   updater check      report without changing anything
--
-- Keeping one implementation means the install path and the update path cannot
-- drift apart.

local REPO = "lchrios/mc-jarvis"
local DEFAULT_REF = "main"

local ref = ... or DEFAULT_REF

if not http then
    printError("The HTTP API is disabled. Enable it in the CC:Tweaked config and retry.")
    return
end

print("Fetching the BaseOS updater from " .. REPO .. " (" .. ref .. ") ...")

local url = ("https://raw.githubusercontent.com/%s/%s/updater.lua"):format(REPO, ref)
local response, err = http.get(url, { ["User-Agent"] = "BaseOS-Installer" })
if not response then
    printError("Could not download updater.lua: " .. tostring(err))
    return
end

local source = response.readAll()
response.close()

local handle = fs.open("updater.lua", "w")
if not handle then
    printError("Could not write updater.lua")
    return
end
handle.write(source)
handle.close()

local chunk, loadError = load(source, "@updater.lua", "t", _ENV or _G)
if not chunk then
    printError("Downloaded updater.lua is not valid Lua: " .. tostring(loadError))
    return
end

-- `install` skips the confirmation prompt: asking "do you want to install?"
-- right after the user typed `installer` is noise.
chunk("install", ref)

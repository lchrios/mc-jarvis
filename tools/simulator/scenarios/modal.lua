-- Exercises the confirmation modal and the log viewer, which the dashboard
-- walkthrough never reaches.
--
-- Path: dashboard -> CENTRAL HUB -> REBOOT (confirm dialog) -> CANCEL -> LOGS.
-- CANCEL matters: confirming would actually call os.reboot().

local script = {
    { 30, 40, 6,  "CENTRAL HUB tile" },
    { 36, 65, 23, "REBOOT action (opens the confirm modal)" },
    { 42, 35, 15, "CANCEL in the modal" },
    { 48, 40, 23, "LOGS action" },
    { 54, 3, 1,   "< BACK" },
}
for _, step in ipairs(script) do __TEST.touchAt(step[1], step[2], step[3]) end

local source = assert(__TEST.files["startup.lua"], "startup.lua not found")
local chunk, parseError = load(source, "@startup.lua", "t", _G)
if not chunk then error("startup.lua does not parse: " .. tostring(parseError)) end

local ok, runError = pcall(chunk)

for index, snap in ipairs(__TEST.snapshots()) do
    print(("================ SNAPSHOT %d (%s) ================"):format(index, snap.label))
    print(snap.screen)
end

print("run ok: " .. tostring(ok) .. (ok and "" or (" err=" .. tostring(runError))))

local log = __TEST.files["data/baseos.log"]
if log and log:find("%[ERROR%]") then
    print(log)
    error("log contains ERROR entries", 0)
end

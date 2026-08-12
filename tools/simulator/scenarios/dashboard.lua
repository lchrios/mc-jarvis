-- Default scenario: boot on an 82x25 monitor and walk the UI.
--
-- Touches are injected at fixed event indices so the scheduler gets to run in
-- between; each snapshot therefore shows live data rather than boot values.

local script = {
    { 30, 40, 6,  "CENTRAL HUB tile" },
    { 34, 3, 1,   "< BACK" },
    { 38, 10, 18, "DEMO FARM tile" },
    { 42, 30, 23, "STOP action" },
    { 46, 8, 23,  "START action" },
    { 50, 3, 1,   "< BACK" },
    { 54, 70, 18, "ALERTS zone" },
    { 58, 3, 1,   "< BACK" },
    { 62, 40, 18, "ALL MODULES zone" },
    { 66, 5, 3,   "select a module row" },
    { 70, 3, 1,   "< BACK" },
    { 74, 10, 6,  "STORAGE tile" },
}
for _, step in ipairs(script) do __TEST.touchAt(step[1], step[2], step[3]) end

local source = assert(__TEST.files["startup.lua"], "startup.lua not found")
local chunk, parseError = load(source, "@startup.lua", "t", _G)
if not chunk then error("startup.lua does not parse: " .. tostring(parseError)) end

local ok, runError = pcall(chunk)

local only = tonumber(os.getenv and os.getenv("SNAPSHOT") or nil)
for index, snap in ipairs(__TEST.snapshots()) do
    if not only or only == index then
        print(("================ SNAPSHOT %d (%s) ================"):format(index, snap.label))
        print(snap.screen)
    end
end

print(("events processed: %d, pending: %d"):format(__TEST.processed(), __TEST.pending()))

if BASEOS and BASEOS.loaded["core.scheduler"] then
    print("--- scheduler tasks ---")
    for _, task in ipairs(BASEOS.loaded["core.scheduler"].list()) do
        print(("  %-24s every %.2fs runs=%d failures=%d"):format(
            task.name, task.interval, task.runs, task.failures))
    end
end

print("run ok: " .. tostring(ok) .. (ok and "" or (" err=" .. tostring(runError))))

local log = __TEST.files["data/baseos.log"]
if log then
    print("------------------------ LOG ------------------------")
    print(log)
    if log:find("%[ERROR%]") then error("log contains ERROR entries", 0) end
end

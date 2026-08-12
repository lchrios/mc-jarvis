-- Resilience scenario: boot with no monitor at all (terminal fallback) and
-- force the demo farm over its alert threshold.
--
-- Proves that a missing peripheral degrades gracefully instead of crashing.

__TEST.removePeripheral("monitor_0")

__TEST.queueEventAt(20, "baseos_test_force_alert")
__TEST.queueEventAt(40, "baseos_test_check")

local source = assert(__TEST.files["startup.lua"], "startup.lua not found")
local chunk, parseError = load(source, "@startup.lua", "t", _G)
if not chunk then error("startup.lua does not parse: " .. tostring(parseError)) end

-- Intercept the synthetic events before the app loop sees them.
local realPull = os.pullEventRaw
os.pullEventRaw = function()
    local event = table.pack(realPull())
    if event[1] == "baseos_test_force_alert" then
        local farm = BASEOS.loaded["modules.demo_farm"]
        if farm then farm.buffer = 0.97 end
    elseif event[1] == "baseos_test_check" then
        local alerts = BASEOS.loaded["services.alerts"]
        print(("[check] active alerts: %d worst=%s"):format(
            alerts.count(), tostring(alerts.worstSeverity())))
        for _, entry in ipairs(alerts.list()) do
            print("  - " .. entry.severity .. " " .. entry.id .. ": " .. entry.message)
        end
    end
    return table.unpack(event, 1, event.n)
end

local ok, runError = pcall(chunk)

local snaps = __TEST.snapshots()
local last = snaps[#snaps]
print("============ TERMINAL (last frame) ============")
print(last and last.terminal or "(nothing drawn)")
print("===============================================")
print("run ok: " .. tostring(ok) .. (ok and "" or (" err=" .. tostring(runError))))

local log = __TEST.files["data/baseos.log"]
if log then
    print("------------------------ LOG ------------------------")
    print(log)
    if log:find("%[ERROR%]") then error("log contains ERROR entries", 0) end
end

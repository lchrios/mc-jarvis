-- Boots and prints the final frame. Use it to eyeball how the dashboard scales:
--
--   MONITOR_W=57  MONITOR_H=24 node run.js scenarios/render.lua   # 3x2 monitor
--   MONITOR_W=78  MONITOR_H=38 node run.js scenarios/render.lua   # 4x3 monitor
--   MONITOR_W=121 MONITOR_H=52 node run.js scenarios/render.lua   # 6x4 monitor
--   MONITOR_W=20  MONITOR_H=8  node run.js scenarios/render.lua   # below the minimum

local source = assert(__TEST.files["startup.lua"], "startup.lua not found")
local chunk = assert(load(source, "@startup.lua", "t", _G))
local ok, err = pcall(chunk)

local snaps = __TEST.snapshots()
print(snaps[#snaps] and snaps[#snaps].screen or "(nothing drawn)")
print("run ok: " .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))))

local log = __TEST.files["data/baseos.log"]
if log and log:find("%[ERROR%]") then
    print(log)
    error("log contains ERROR entries", 0)
end

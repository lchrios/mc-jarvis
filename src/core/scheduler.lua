--- Central task scheduler.
--
-- There is exactly one `os.startTimer` in flight for the whole system: the
-- scheduler arms it for the next due task, and `core.app` feeds `timer` events
-- back in. Modules must never call `sleep()` in their own loop.
--
--   scheduler.every(5, function() ... end, { name = "power.poll" })
--   scheduler.after(0.5, function() ... end)

local util = require("core.util")
local logger = require("core.logger")

local log = logger.scoped("scheduler")

local scheduler = {}

local MIN_TIMER = 0.05          -- one Minecraft tick
local MAX_CONSECUTIVE_FAILURES = 5

local tasks = {}
local nextId = 0
local activeTimer = nil
local activeDueAt = nil
local running = false

local function schedulerNow() return util.nowMs() end

local function armTimer()
    if not running then return end

    local earliest = nil
    for _, task in pairs(tasks) do
        if not task.paused and (earliest == nil or task.nextAt < earliest) then
            earliest = task.nextAt
        end
    end

    if earliest == nil then
        activeTimer, activeDueAt = nil, nil
        return
    end

    -- Reuse the in-flight timer when it already fires early enough.
    if activeTimer ~= nil and activeDueAt ~= nil and activeDueAt <= earliest then
        return
    end

    local delay = math.max(MIN_TIMER, (earliest - schedulerNow()) / 1000)
    activeTimer = os.startTimer(delay)
    activeDueAt = earliest
end

local function addTask(task)
    nextId = nextId + 1
    task.id = nextId
    task.failures = 0
    task.runs = 0
    task.paused = false
    tasks[task.id] = task
    armTimer()
    return task.id
end

--- Run `fn` every `interval` seconds.
-- @param interval number seconds (minimum one tick)
-- @param fn function
-- @param options table|nil { name = string, immediate = bool, owner = any }
-- @return number task id
function scheduler.every(interval, fn, options)
    if type(fn) ~= "function" then error("scheduler.every expects a function", 2) end
    options = options or {}
    interval = math.max(MIN_TIMER, tonumber(interval) or 1)

    local delayMs = options.immediate and 0 or interval * 1000
    return addTask({
        name = options.name or "task",
        owner = options.owner,
        interval = interval,
        fn = fn,
        once = false,
        nextAt = schedulerNow() + delayMs,
    })
end

--- Run `fn` once after `delay` seconds.
function scheduler.after(delay, fn, options)
    if type(fn) ~= "function" then error("scheduler.after expects a function", 2) end
    options = options or {}
    delay = math.max(0, tonumber(delay) or 0)

    return addTask({
        name = options.name or "delayed",
        owner = options.owner,
        interval = delay,
        fn = fn,
        once = true,
        nextAt = schedulerNow() + delay * 1000,
    })
end

function scheduler.cancel(id)
    if tasks[id] then
        tasks[id] = nil
        return true
    end
    return false
end

--- Cancel every task registered with the given owner (used on module unload).
function scheduler.cancelOwner(owner)
    local removed = 0
    for id, task in pairs(tasks) do
        if task.owner == owner then
            tasks[id] = nil
            removed = removed + 1
        end
    end
    return removed
end

function scheduler.pause(id)
    local task = tasks[id]
    if task then task.paused = true return true end
    return false
end

function scheduler.resume(id)
    local task = tasks[id]
    if task then
        task.paused = false
        task.nextAt = schedulerNow() + task.interval * 1000
        armTimer()
        return true
    end
    return false
end

--- Start accepting timers. Called once by `core.app`.
function scheduler.start()
    running = true
    activeTimer, activeDueAt = nil, nil
    armTimer()
end

function scheduler.stop()
    running = false
    activeTimer, activeDueAt = nil, nil
end

--- Feed a CC `timer` event into the scheduler.
-- @return boolean true when the timer belonged to the scheduler
function scheduler.onTimer(timerId)
    if not running or timerId ~= activeTimer then return false end

    activeTimer, activeDueAt = nil, nil
    local now = schedulerNow()

    -- Collect first: a task callback may add or cancel tasks.
    local due = {}
    for _, task in pairs(tasks) do
        if not task.paused and task.nextAt <= now then due[#due + 1] = task end
    end
    table.sort(due, function(a, b) return a.nextAt < b.nextAt end)

    for _, task in ipairs(due) do
        if tasks[task.id] then
            if task.once then tasks[task.id] = nil end

            local ok, err = pcall(task.fn)
            task.runs = task.runs + 1

            if ok then
                task.failures = 0
            else
                task.failures = task.failures + 1
                log.error("task '%s' failed (%d/%d): %s",
                    task.name, task.failures, MAX_CONSECUTIVE_FAILURES, tostring(err))
                if task.failures >= MAX_CONSECUTIVE_FAILURES then
                    log.error("task '%s' disabled after repeated failures", task.name)
                    tasks[task.id] = nil
                end
            end

            if not task.once and tasks[task.id] then
                -- Schedule relative to now so a slow task cannot build a backlog.
                task.nextAt = schedulerNow() + task.interval * 1000
            end
        end
    end

    armTimer()
    return true
end

--- Snapshot for diagnostics / the system module.
function scheduler.list()
    local result = {}
    for _, task in pairs(tasks) do
        result[#result + 1] = {
            id = task.id,
            name = task.name,
            interval = task.interval,
            runs = task.runs,
            paused = task.paused,
            failures = task.failures,
        }
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

function scheduler.count()
    return util.count(tasks)
end

return scheduler

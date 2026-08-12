--- Levelled logger with optional file output.
--
--   local log = require("core.logger").scoped("power")
--   log.info("Peripheral attached: %s", name)
--
-- The logger never throws: a broken log sink must not take the base down.

local util = require("core.util")

local logger = {}

logger.LEVELS = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }
logger.LEVEL_NAMES = { "DEBUG", "INFO ", "WARN ", "ERROR" }

local settings = {
    level = logger.LEVELS.INFO,
    toTerminal = true,
    toFile = true,
    filePath = "data/baseos.log",
    maxFileBytes = 24 * 1024,
    terminal = nil, -- term object used for terminal output
}

local buffer = {}        -- ring buffer of recent lines, exposed to the UI
local bufferLimit = 120
local fileHandle = nil
local fileBytes = 0

local LEVEL_COLORS = {
    [1] = colors and colors.gray or 128,
    [2] = colors and colors.white or 1,
    [3] = colors and colors.orange or 2,
    [4] = colors and colors.red or 16384,
}

local function levelFromName(name)
    if type(name) == "number" then return name end
    return logger.LEVELS[tostring(name):upper()] or logger.LEVELS.INFO
end

local function closeFile()
    if fileHandle then
        pcall(function() fileHandle.close() end)
        fileHandle = nil
    end
end

local function openFile()
    closeFile()
    if not settings.toFile or not settings.filePath then return end

    local ok = pcall(function()
        local dir = fs.getDir(settings.filePath)
        if dir and dir ~= "" and not fs.exists(dir) then
            fs.makeDir(dir)
        end

        -- Rotate before opening so a long running base does not fill its disk.
        if fs.exists(settings.filePath) and fs.getSize(settings.filePath) > settings.maxFileBytes then
            local old = settings.filePath .. ".old"
            if fs.exists(old) then fs.delete(old) end
            fs.move(settings.filePath, old)
        end

        fileBytes = fs.exists(settings.filePath) and fs.getSize(settings.filePath) or 0
        fileHandle = fs.open(settings.filePath, "a")
    end)

    if not ok then
        fileHandle = nil
        settings.toFile = false
    end
end

--- Configure the logger. Safe to call more than once.
-- @param options table with any of: level, toTerminal, toFile, filePath,
--        maxFileBytes, terminal, root
function logger.configure(options)
    options = options or {}
    if options.level ~= nil then settings.level = levelFromName(options.level) end
    if options.toTerminal ~= nil then settings.toTerminal = options.toTerminal end
    if options.toFile ~= nil then settings.toFile = options.toFile end
    if options.terminal ~= nil then settings.terminal = options.terminal end
    if options.maxFileBytes ~= nil then settings.maxFileBytes = options.maxFileBytes end
    if options.filePath ~= nil then
        settings.filePath = options.filePath
        if options.root and options.root ~= "" then
            settings.filePath = fs.combine(options.root, options.filePath)
        end
    end
    openFile()
end

function logger.getLevel() return settings.level end

function logger.setLevel(level) settings.level = levelFromName(level) end

--- Recent log lines, oldest first. Used by the log viewer screen.
function logger.recent(count)
    count = count or bufferLimit
    local first = math.max(1, #buffer - count + 1)
    local slice = {}
    for index = first, #buffer do slice[#slice + 1] = buffer[index] end
    return slice
end

local function timestamp()
    if os.date then
        local ok, value = pcall(os.date, "%H:%M:%S")
        if ok and value then return value end
    end
    return string.format("%8.2f", os.clock())
end

local function writeTerminal(level, line)
    if not settings.toTerminal then return end
    local target = settings.terminal
    if not target and term then
        target = term.native and term.native() or term
    end
    if not target then return end

    pcall(function()
        local previous = target.getTextColour and target.getTextColour()
        if target.setTextColour and target.isColour and target.isColour() then
            target.setTextColour(LEVEL_COLORS[level] or colors.white)
        end
        target.write(line)
        local _, y = target.getCursorPos()
        local _, height = target.getSize()
        if y >= height then
            target.scroll(1)
            target.setCursorPos(1, height)
        else
            target.setCursorPos(1, y + 1)
        end
        if previous and target.setTextColour then target.setTextColour(previous) end
    end)
end

local function emit(level, scope, message, ...)
    if level < settings.level then return end

    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, tostring(message), ...)
        message = ok and formatted or (tostring(message) .. " " .. textutils.serialise({ ... }, { compact = true }))
    end

    local line = string.format("[%s] [%s] %s%s",
        timestamp(),
        logger.LEVEL_NAMES[level] or "?????",
        scope and ("[" .. scope .. "] ") or "",
        tostring(message))

    buffer[#buffer + 1] = { level = level, text = line, time = util.nowMs() }
    if #buffer > bufferLimit then table.remove(buffer, 1) end

    writeTerminal(level, line)

    if fileHandle then
        local ok = pcall(function()
            fileHandle.write(line .. "\n")
            fileHandle.flush()
        end)
        if ok then
            fileBytes = fileBytes + #line + 1
            if fileBytes > settings.maxFileBytes then openFile() end
        else
            fileHandle = nil
        end
    end
end

function logger.log(level, message, ...) emit(levelFromName(level), nil, message, ...) end
function logger.debug(message, ...) emit(logger.LEVELS.DEBUG, nil, message, ...) end
function logger.info(message, ...) emit(logger.LEVELS.INFO, nil, message, ...) end
function logger.warn(message, ...) emit(logger.LEVELS.WARN, nil, message, ...) end
function logger.error(message, ...) emit(logger.LEVELS.ERROR, nil, message, ...) end

--- A logger bound to a subsystem name, e.g. logger.scoped("peripherals").
function logger.scoped(scope)
    return {
        scope = scope,
        debug = function(message, ...) emit(logger.LEVELS.DEBUG, scope, message, ...) end,
        info = function(message, ...) emit(logger.LEVELS.INFO, scope, message, ...) end,
        warn = function(message, ...) emit(logger.LEVELS.WARN, scope, message, ...) end,
        error = function(message, ...) emit(logger.LEVELS.ERROR, scope, message, ...) end,
    }
end

function logger.shutdown() closeFile() end

return logger

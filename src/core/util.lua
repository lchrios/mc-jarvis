--- Small, dependency free helpers shared across BaseOS.
-- Everything here must work inside the CC:Tweaked Lua sandbox.

local util = {}

--- Current wall clock in milliseconds.
function util.nowMs()
    if os.epoch then
        local ok, value = pcall(os.epoch, "utc")
        if ok and type(value) == "number" then return value end
    end
    return math.floor(os.clock() * 1000)
end

--- Current wall clock in seconds (floating point).
function util.now()
    return util.nowMs() / 1000
end

function util.clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

function util.round(value, decimals)
    local factor = 10 ^ (decimals or 0)
    return math.floor(value * factor + 0.5) / factor
end

function util.isArray(value)
    if type(value) ~= "table" then return false end
    return #value > 0 or next(value) == nil
end

--- Recursive copy. Cycles are not supported (configuration data is a tree).
function util.deepCopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for k, v in pairs(value) do
        copy[k] = util.deepCopy(v)
    end
    return copy
end

--- Merge `override` into a copy of `base`. Arrays are replaced, maps merged.
function util.deepMerge(base, override)
    if type(override) ~= "table" then
        if override == nil then return util.deepCopy(base) end
        return util.deepCopy(override)
    end
    if type(base) ~= "table" then return util.deepCopy(override) end

    -- Arrays are treated as atomic values: replacing is far less surprising
    -- than trying to merge element by element.
    if #base > 0 or #override > 0 then
        return util.deepCopy(override)
    end

    local result = util.deepCopy(base)
    for key, value in pairs(override) do
        result[key] = util.deepMerge(result[key], value)
    end
    return result
end

--- Split "a.b.c" into { "a", "b", "c" }.
function util.splitPath(path, separator)
    separator = separator or "."
    local parts = {}
    for part in tostring(path):gmatch("[^" .. separator .. "]+") do
        parts[#parts + 1] = part
    end
    return parts
end

--- Read a nested value: util.dig(t, "modules.power.status")
function util.dig(root, path, default)
    local node = root
    for _, key in ipairs(util.splitPath(path)) do
        if type(node) ~= "table" then return default end
        node = node[key]
        if node == nil then return default end
    end
    return node
end

--- Write a nested value, creating intermediate tables as needed.
function util.plant(root, path, value)
    local parts = util.splitPath(path)
    local node = root
    for index = 1, #parts - 1 do
        local key = parts[index]
        if type(node[key]) ~= "table" then node[key] = {} end
        node = node[key]
    end
    local previous = node[parts[#parts]]
    node[parts[#parts]] = value
    return previous
end

function util.keys(map)
    local result = {}
    for key in pairs(map) do result[#result + 1] = key end
    return result
end

function util.sortedKeys(map, comparator)
    local result = util.keys(map)
    table.sort(result, comparator)
    return result
end

function util.count(map)
    local total = 0
    for _ in pairs(map) do total = total + 1 end
    return total
end

function util.contains(list, value)
    for _, item in ipairs(list) do
        if item == value then return true end
    end
    return false
end

function util.indexOf(list, value)
    for index, item in ipairs(list) do
        if item == value then return index end
    end
    return nil
end

--- Shorten `text` to `width` characters, adding an ellipsis when it does not fit.
function util.truncate(text, width)
    text = tostring(text or "")
    if width <= 0 then return "" end
    if #text <= width then return text end
    if width <= 3 then return text:sub(1, width) end
    return text:sub(1, width - 3) .. "..."
end

function util.padRight(text, width, fill)
    text = tostring(text or "")
    if #text >= width then return util.truncate(text, width) end
    return text .. string.rep(fill or " ", width - #text)
end

function util.padLeft(text, width, fill)
    text = tostring(text or "")
    if #text >= width then return util.truncate(text, width) end
    return string.rep(fill or " ", width - #text) .. text
end

local SI_SUFFIXES = { "", "k", "M", "G", "T", "P" }

--- Compact number formatting: 12400 -> "12.4k".
function util.formatNumber(value, decimals)
    if type(value) ~= "number" then return tostring(value) end
    decimals = decimals or 1
    local negative = value < 0
    value = math.abs(value)
    local index = 1
    while value >= 1000 and index < #SI_SUFFIXES do
        value = value / 1000
        index = index + 1
    end
    local text
    if index == 1 then
        -- Keep whole numbers whole: "7", not "7.0".
        local rounded = util.round(value, decimals)
        if rounded == math.floor(rounded) then
            text = string.format("%d", math.floor(rounded))
        else
            text = string.format("%." .. decimals .. "f", rounded)
        end
    else
        text = string.format("%." .. decimals .. "f", value)
    end
    return (negative and "-" or "") .. text .. SI_SUFFIXES[index]
end

function util.formatPercent(fraction, decimals)
    return string.format("%." .. (decimals or 0) .. "f%%", (fraction or 0) * 100)
end

--- Human readable duration from a number of seconds.
function util.formatDuration(seconds)
    seconds = math.floor(seconds or 0)
    if seconds < 60 then return seconds .. "s" end
    local minutes = math.floor(seconds / 60)
    local remainder = seconds % 60
    if minutes < 60 then return minutes .. "m " .. remainder .. "s" end
    local hours = math.floor(minutes / 60)
    minutes = minutes % 60
    if hours < 24 then return hours .. "h " .. minutes .. "m" end
    local days = math.floor(hours / 24)
    return days .. "d " .. (hours % 24) .. "h"
end

--- Clock string for the UI header. Uses the in-game time when available.
function util.formatClock(useInGameTime)
    if useInGameTime and os.time then
        local ok, value = pcall(os.time)
        if ok and type(value) == "number" then
            local hours = math.floor(value)
            local minutes = math.floor((value - hours) * 60)
            return string.format("%02d:%02d", hours % 24, minutes)
        end
    end
    if os.date then
        local ok, value = pcall(os.date, "%H:%M:%S")
        if ok and value then return value end
    end
    return util.formatDuration(os.clock())
end

--- pcall wrapper returning (ok, resultOrError) and never throwing.
function util.try(fn, ...)
    if type(fn) ~= "function" then return false, "not a function" end
    return pcall(fn, ...)
end

--- Stable, human readable identifier from arbitrary text.
function util.slug(text)
    return tostring(text or ""):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
end

return util

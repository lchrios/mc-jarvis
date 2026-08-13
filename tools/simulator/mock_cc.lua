-- Minimal ComputerCraft: Tweaked environment mock, enough to boot BaseOS
-- outside Minecraft. Backed by __FILES (path -> contents) injected from Node.

local files = {}
for path, contents in pairs(__FILES) do files[path] = contents end

local dirs = {}
local function markDirs(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do parts[#parts + 1] = part end
    local acc = ""
    for i = 1, #parts - 1 do
        acc = (acc == "" and parts[i]) or (acc .. "/" .. parts[i])
        dirs[acc] = true
    end
end
for path in pairs(files) do markDirs(path) end

---------------------------------------------------------------- fs
local function normalise(path)
    path = tostring(path or ""):gsub("\\", "/")
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            table.remove(parts)
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "/")
end

fs = {}
function fs.combine(...)
    local segments = {}
    for _, segment in ipairs({ ... }) do
        if segment and segment ~= "" then segments[#segments + 1] = tostring(segment) end
    end
    return normalise(table.concat(segments, "/"))
end
function fs.exists(path)
    path = normalise(path)
    return files[path] ~= nil or dirs[path] ~= nil or path == ""
end
function fs.isDir(path)
    path = normalise(path)
    return dirs[path] == true or path == ""
end
function fs.getDir(path)
    path = normalise(path)
    local dir = path:match("^(.*)/[^/]*$")
    return dir or ""
end
function fs.getName(path) return (normalise(path):match("[^/]*$")) end
function fs.getSize(path) return #(files[normalise(path)] or "") end
function fs.makeDir(path)
    dirs[normalise(path)] = true
    return true
end
function fs.delete(path)
    path = normalise(path)
    files[path] = nil
    dirs[path] = nil
    return true
end
function fs.move(from, to)
    from, to = normalise(from), normalise(to)
    files[to] = files[from]
    files[from] = nil
    return true
end
function fs.list(path)
    path = normalise(path)
    local seen, result = {}, {}
    for candidate in pairs(files) do
        local rest = path == "" and candidate or candidate:match("^" .. path:gsub("%p", "%%%0") .. "/(.+)$")
        if rest then
            local head = rest:match("^[^/]+")
            if head and not seen[head] then
                seen[head] = true
                result[#result + 1] = head
            end
        end
    end
    table.sort(result)
    return result
end
function fs.getFreeSpace() return 1000000 end
function fs.open(path, mode)
    path = normalise(path)
    if mode == "r" then
        local contents = files[path]
        if not contents then return nil, "No such file" end
        local position = 1
        return {
            readAll = function() return contents end,
            readLine = function()
                if position > #contents then return nil end
                local nl = contents:find("\n", position, true)
                local line = nl and contents:sub(position, nl - 1) or contents:sub(position)
                position = nl and (nl + 1) or (#contents + 1)
                return line
            end,
            close = function() end,
        }
    elseif mode == "w" or mode == "a" then
        local buffer = (mode == "a" and files[path]) or ""
        markDirs(path)
        return {
            write = function(text) buffer = buffer .. tostring(text) end,
            writeLine = function(text) buffer = buffer .. tostring(text) .. "\n" end,
            flush = function() files[path] = buffer end,
            close = function() files[path] = buffer end,
        }
    end
    return nil, "bad mode"
end

---------------------------------------------------------------- colors
colors = {
    white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16, lime = 32,
    pink = 64, gray = 128, grey = 128, lightGray = 256, lightGrey = 256,
    cyan = 512, purple = 1024, blue = 2048, brown = 4096, green = 8192,
    red = 16384, black = 32768,
}
colours = colors

---------------------------------------------------------------- terminal
local function makeTerm(width, height, name)
    local grid = {}
    local self = {
        __name = name,
        width = width,
        height = height,
        cursorX = 1,
        cursorY = 1,
        fg = colors.white,
        bg = colors.black,
        writes = 0,
        scale = 1,
    }
    local bgGrid = {}
    for y = 1, height do
        grid[y] = string.rep(" ", width)
        bgGrid[y] = string.rep("f", width)   -- "f" = black, the default
    end

    -- Colours are powers of two; map each to one hex digit for a compact dump.
    local function colourSymbol(colour)
        local index = math.floor(math.log(colour or 32768) / math.log(2) + 0.5)
        return ("%x"):format(math.max(0, math.min(15, index)))
    end

    function self.getSize() return self.width, self.height end
    function self.setCursorPos(x, y) self.cursorX, self.cursorY = math.floor(x), math.floor(y) end
    function self.getCursorPos() return self.cursorX, self.cursorY end
    function self.setTextColor(c) self.fg = c end
    function self.setTextColour(c) self.fg = c end
    function self.getTextColor() return self.fg end
    function self.getTextColour() return self.fg end
    function self.setBackgroundColor(c) self.bg = c end
    function self.setBackgroundColour(c) self.bg = c end
    function self.getBackgroundColor() return self.bg end
    function self.getBackgroundColour() return self.bg end
    function self.isColor() return true end
    function self.isColour() return true end
    function self.setCursorBlink() end
    function self.setTextScale(s) self.scale = s end
    function self.getTextScale() return self.scale end
    function self.clear()
        for y = 1, self.height do
            grid[y] = string.rep(" ", self.width)
            bgGrid[y] = string.rep(colourSymbol(self.bg), self.width)
        end
    end
    function self.clearLine() grid[self.cursorY] = string.rep(" ", self.width) end
    function self.scroll() end
    function self.write(text)
        text = tostring(text)
        local x, y = self.cursorX, self.cursorY
        if y < 1 or y > self.height then return end
        if x > self.width then return end
        local line = grid[y] or string.rep(" ", self.width)
        local before = line:sub(1, math.max(0, x - 1))
        if #before < x - 1 then before = before .. string.rep(" ", x - 1 - #before) end
        local after = line:sub(x + #text)
        grid[y] = (before .. text .. after):sub(1, self.width)

        local bgLine = bgGrid[y] or string.rep("f", self.width)
        local bgBefore = bgLine:sub(1, math.max(0, x - 1))
        if #bgBefore < x - 1 then bgBefore = bgBefore .. string.rep("f", x - 1 - #bgBefore) end
        bgGrid[y] = (bgBefore .. string.rep(colourSymbol(self.bg), #text)
            .. bgLine:sub(x + #text)):sub(1, self.width)

        self.cursorX = x + #text
        self.writes = self.writes + 1
    end
    function self.blit(text) self.write(text) end
    function self.render()
        local out = {}
        for y = 1, self.height do out[#out + 1] = grid[y] end
        return table.concat(out, "\n")
    end

    --- Background colours as hex digits, one per cell.
    function self.renderBackground()
        local out = {}
        for y = 1, self.height do out[#out + 1] = bgGrid[y] end
        return table.concat(out, "\n")
    end

    --- Distinct background colours inside a rectangle: { symbol = count }.
    function self.coloursIn(x, y, w, h)
        local seen = {}
        for row = y, math.min(y + h - 1, self.height) do
            for column = x, math.min(x + w - 1, self.width) do
                local symbol = (bgGrid[row] or ""):sub(column, column)
                if symbol ~= "" then seen[symbol] = (seen[symbol] or 0) + 1 end
            end
        end
        return seen
    end

    return self
end

local nativeTerm = makeTerm(51, 19, "terminal")
term = setmetatable({
    native = function() return nativeTerm end,
    redirect = function() return nativeTerm end,
    current = function() return nativeTerm end,
}, { __index = nativeTerm })

---------------------------------------------------------------- window
-- The real `window` buffers and blits; the mock writes straight through to the
-- parent so the test can inspect what ended up on the monitor.
window = {}
function window.create(parent, x, y, w, h, visible)
    local win = makeTerm(w, h, "window")
    win.visible = visible
    win.parent = parent

    local ownWrite = win.write
    function win.write(text)
        ownWrite(text)
        -- Carry the colours through, so what lands on the monitor can be
        -- checked and not just the characters.
        parent.setBackgroundColor(win.bg)
        parent.setTextColor(win.fg)
        parent.setCursorPos(x + win.cursorX - #tostring(text) - 1, y + win.cursorY - 1)
        parent.write(text)
    end
    local ownClear = win.clear
    function win.clear()
        ownClear()
        for row = 0, win.height - 1 do
            parent.setCursorPos(x, y + row)
            parent.write(string.rep(" ", win.width))
        end
    end
    function win.setVisible(value) win.visible = value end
    function win.isVisible() return win.visible end
    function win.reposition(nx, ny, nw, nh)
        if nw then win.width = nw end
        if nh then win.height = nh end
    end
    function win.redraw() end
    return win
end

---------------------------------------------------------------- peripherals
---------------------------------------------------------------- redstone
local redstoneOutputs = {}
redstone = {
    getSides = function() return { "top", "bottom", "left", "right", "front", "back" } end,
    setOutput = function(side, value) redstoneOutputs[side] = value and true or false end,
    getOutput = function(side) return redstoneOutputs[side] == true end,
    getInput = function() return false end,
    setAnalogOutput = function(side, value) redstoneOutputs[side] = (value or 0) > 0 end,
    getAnalogOutput = function(side) return redstoneOutputs[side] and 15 or 0 end,
    getAnalogInput = function() return 0 end,
}
rs = redstone

---------------------------------------------------------------- peripherals
-- An output barrel that actually fills up over time while its control side is
-- powered. This is what lets a scenario exercise the real farm module - read a
-- container, measure a rate, hit the buffer alert - instead of fake numbers.
local function makeFarmOutput(options)
    options = options or {}
    local slots = options.slots or 27
    local capacity = slots * 64
    local produced = 0
    local lastAt = nil

    local function advance()
        local now = os.epoch("utc")
        if not lastAt then lastAt = now return end
        local elapsed = (now - lastAt) / 1000
        lastAt = now
        if elapsed <= 0 then return end
        if redstone.getOutput(options.side or "back") then
            produced = math.min(capacity, produced + (options.rate or 3) * elapsed)
        end
    end

    local object = {}

    function object.size() return slots end

    function object.list()
        advance()
        local remaining = math.floor(produced)
        local contents = {}
        local slot = 1
        while remaining > 0 and slot <= slots do
            local count = math.min(64, remaining)
            contents[slot] = { name = options.item or "minecraft:rotten_flesh", count = count }
            remaining = remaining - count
            slot = slot + 1
        end
        return contents
    end

    function object.getItemDetail(slot)
        local contents = object.list()
        return contents[slot]
    end

    function object.pushItems(_, _, count)
        local moved = math.min(count or 64, math.floor(produced))
        produced = produced - moved
        return moved
    end

    function object.pullItems() return 0 end

    return {
        object = object,
        drain = function() produced = 0 end,
        fill = function(fraction) produced = capacity * fraction end,
        produced = function() return produced end,
    }
end

-- Advanced Peripherals stand-ins. Method names match what the adapters try
-- first; the point is to exercise the modules, not to prove AP's real API,
-- which only `probe` in game can do.
local playersInRange = {}
local chatLog = {}
local soundLog = {}

local function makePlayerDetector()
    return {
        getOnlinePlayers = function()
            -- AP returns plain names; the scenario may carry distances.
            local all = {}
            for _, entry in ipairs(playersInRange) do
                all[#all + 1] = type(entry) == "table" and entry.name or entry
            end
            return all
        end,
        getPlayersInRange = function(range)
            local found = {}
            for _, entry in ipairs(playersInRange) do
                if type(entry) == "string" then
                    found[#found + 1] = entry
                elseif (entry.distance or 0) <= (range or 8) then
                    found[#found + 1] = entry.name
                end
            end
            return found
        end,
        isPlayerInRange = function(range, player)
            for _, entry in ipairs(playersInRange) do
                local name = type(entry) == "string" and entry or entry.name
                if name == player then return true end
            end
            return false
        end,
        getPlayerPos = function() return { x = 0, y = 64, z = 0 } end,
    }
end

local function makeChatBox()
    return {
        sendMessage = function(message, prefix)
            chatLog[#chatLog + 1] = { message = message, prefix = prefix }
            return true
        end,
        sendMessageToPlayer = function(message, player, prefix)
            chatLog[#chatLog + 1] = { message = message, player = player, prefix = prefix }
            return true
        end,
    }
end

local function makeSpeaker()
    return {
        playSound = function(sound, volume, pitch)
            soundLog[#soundLog + 1] = { sound = sound, volume = volume, pitch = pitch }
            return true
        end,
        playNote = function(instrument)
            soundLog[#soundLog + 1] = { note = instrument }
            return true
        end,
    }
end

local function makeRedstoneIntegrator()
    local outputs = {}
    return {
        setOutput = function(side, value) outputs[side] = value and true or false return true end,
        getOutput = function(side) return outputs[side] == true end,
        getInput = function() return false end,
    }
end

-- Monitor size is overridable so scenarios can check how the UI scales.
local monitor = makeTerm(tonumber(__MONITOR_W) or 82, tonumber(__MONITOR_H) or 25, "monitor_0")
local farmOutput = makeFarmOutput({ side = "back", rate = 4 })
local peripherals = {
    monitor_0 = { types = { "monitor" }, object = monitor },
    ["minecraft:barrel_0"] = {
        types = { "inventory", "minecraft:barrel" },
        object = farmOutput.object,
    },
}

peripheral = {}
function peripheral.getNames()
    local names = {}
    for name in pairs(peripherals) do names[#names + 1] = name end
    table.sort(names)
    return names
end
function peripheral.isPresent(name) return peripherals[name] ~= nil end
function peripheral.getType(name)
    local entry = peripherals[name]
    if not entry then return nil end
    return table.unpack(entry.types)
end
function peripheral.hasType(name, wanted)
    local entry = peripherals[name]
    if not entry then return nil end
    for _, kind in ipairs(entry.types) do
        if kind == wanted then return true end
    end
    return false
end
function peripheral.getMethods(name)
    local entry = peripherals[name]
    if not entry then return nil end
    local methods = {}
    for key, value in pairs(entry.object) do
        if type(value) == "function" then methods[#methods + 1] = key end
    end
    table.sort(methods)
    return methods
end
function peripheral.wrap(name)
    local entry = peripherals[name]
    return entry and entry.object or nil
end
function peripheral.call(name, method, ...)
    local entry = peripherals[name]
    if not entry then error("no peripheral " .. tostring(name)) end
    local fn = entry.object[method]
    if not fn then error("no method " .. tostring(method)) end
    return fn(...)
end
function peripheral.find(kind)
    local found = {}
    for name, entry in pairs(peripherals) do
        for _, t in ipairs(entry.types) do
            if t == kind then found[#found + 1] = entry.object end
        end
    end
    return table.unpack(found)
end

---------------------------------------------------------------- os / events
local queue = {}
local processed = 0
local MAX_EVENTS = tonumber(__MAX_EVENTS) or 300
local timerSeq = 0
local startTime = 1700000000000

function os.queueEvent(...) queue[#queue + 1] = { ... } end
function os.startTimer(delay)
    timerSeq = timerSeq + 1
    queue[#queue + 1] = { "timer", timerSeq }
    return timerSeq
end
function os.cancelTimer() end
-- Virtual time advances per *event*, not per call. Advancing on every
-- os.epoch() made the clock run faster whenever a screen happened to ask the
-- time more often, so a UI change could silently retime every scenario.
function os.epoch() return startTime end
function os.time() return 12.5 end
function os.day() return 42 end
function os.getComputerID() return 7 end
function os.getComputerLabel() return "BASE_MASTER" end
function os.setComputerLabel() end
function os.sleep() end
function os.reboot() error("reboot called", 0) end
function os.shutdown() error("shutdown called", 0) end
local snapshots = {}
local lastEvent = nil

-- Snapshot the monitor whenever the previous event was a touch, so the driver
-- can show what each interaction actually painted.
local function snapshot(label)
    snapshots[#snapshots + 1] = {
        label = label,
        screen = monitor.render(),
        terminal = nativeTerm.render(),
    }
end

local injections = {}     -- [eventIndex] = event or producer, instead of the queue
local harnessErrors = {}  -- failures inside scenario hooks

local MS_PER_EVENT = 150

function os.pullEventRaw()
    processed = processed + 1
    startTime = startTime + MS_PER_EVENT
    if lastEvent == "monitor_touch" then snapshot("after touch #" .. #snapshots + 1) end
    if processed > MAX_EVENTS then
        snapshot("final")
        lastEvent = "terminate"
        return "terminate"
    end

    local injected = injections[processed]
    if type(injected) == "function" then
        -- Evaluated at delivery time, so a scenario can look at the live UI
        -- instead of hardcoding coordinates that rot on every layout change.
        -- Failures are recorded rather than raised: BaseOS catches everything
        -- that escapes the event loop, which would hide them.
        local produced
        local okProducer, err = pcall(function() produced = injected() end)
        if not okProducer then
            harnessErrors[#harnessErrors + 1] = tostring(err)
        end
        injected = produced
    end
    if injected then
        lastEvent = injected[1]
        return table.unpack(injected)
    end

    if #queue == 0 then
        snapshot("final")
        lastEvent = "terminate"
        return "terminate"
    end
    local event = table.remove(queue, 1)
    lastEvent = event[1]
    return table.unpack(event)
end
os.pullEvent = os.pullEventRaw
sleep = function() end

---------------------------------------------------------------- textutils
textutils = {}
local function serialise(value, indent)
    indent = indent or ""
    local kind = type(value)
    if kind == "table" then
        local parts = { "{" }
        local nested = indent .. "  "
        for key, item in pairs(value) do
            local keyText
            if type(key) == "string" and key:match("^[%a_][%w_]*$") then
                keyText = key .. " = "
            else
                keyText = "[" .. serialise(key, nested) .. "] = "
            end
            parts[#parts + 1] = nested .. keyText .. serialise(item, nested) .. ","
        end
        parts[#parts + 1] = indent .. "}"
        return table.concat(parts, "\n")
    elseif kind == "string" then
        return string.format("%q", value)
    end
    return tostring(value)
end
textutils.serialise = serialise
textutils.serialize = serialise
function textutils.unserialise(text)
    local chunk = load("return " .. tostring(text), "unserialise", "t", {})
    if not chunk then return nil end
    local ok, value = pcall(chunk)
    return ok and value or nil
end
textutils.unserialize = textutils.unserialise
function textutils.serialiseJSON(value) return serialise(value) end
textutils.serializeJSON = textutils.serialiseJSON

-- A real (small) JSON parser: the installer parses GitHub's API response, so a
-- fake one would not prove anything.
local function parseJSON(text)
    local pos = 1

    local function skipSpace()
        pos = text:find("[^ \t\r\n]", pos) or (#text + 1)
    end

    local parseValue

    local function parseString()
        pos = pos + 1 -- opening quote
        local out = {}
        local escapes = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f",
                          ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
        while true do
            local char = text:sub(pos, pos)
            if char == "" then error("unterminated string in JSON") end
            if char == '"' then
                pos = pos + 1
                break
            elseif char == "\\" then
                local escape = text:sub(pos + 1, pos + 1)
                if escapes[escape] then
                    out[#out + 1] = escapes[escape]
                    pos = pos + 2
                elseif escape == "u" then
                    local code = tonumber(text:sub(pos + 2, pos + 5), 16)
                    out[#out + 1] = (utf8 and code) and utf8.char(code) or "?"
                    pos = pos + 6
                else
                    error("bad escape in JSON: \\" .. escape)
                end
            else
                out[#out + 1] = char
                pos = pos + 1
            end
        end
        return table.concat(out)
    end

    local function parseArray()
        pos = pos + 1
        local out = {}
        skipSpace()
        if text:sub(pos, pos) == "]" then pos = pos + 1 return out end
        while true do
            out[#out + 1] = parseValue()
            skipSpace()
            local char = text:sub(pos, pos)
            pos = pos + 1
            if char == "]" then return out end
            if char ~= "," then error("expected , or ] in JSON at " .. pos) end
            skipSpace()
        end
    end

    local function parseObject()
        pos = pos + 1
        local out = {}
        skipSpace()
        if text:sub(pos, pos) == "}" then pos = pos + 1 return out end
        while true do
            skipSpace()
            local key = parseString()
            skipSpace()
            if text:sub(pos, pos) ~= ":" then error("expected : in JSON at " .. pos) end
            pos = pos + 1
            out[key] = parseValue()
            skipSpace()
            local char = text:sub(pos, pos)
            pos = pos + 1
            if char == "}" then return out end
            if char ~= "," then error("expected , or } in JSON at " .. pos) end
        end
    end

    parseValue = function()
        skipSpace()
        local char = text:sub(pos, pos)
        if char == "{" then return parseObject() end
        if char == "[" then return parseArray() end
        if char == '"' then return parseString() end
        if text:sub(pos, pos + 3) == "true" then pos = pos + 4 return true end
        if text:sub(pos, pos + 4) == "false" then pos = pos + 5 return false end
        if text:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil end
        local number = text:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
        if number then
            pos = pos + #number
            return tonumber(number)
        end
        error("unexpected character in JSON at " .. pos .. ": " .. char)
    end

    local ok, value = pcall(parseValue)
    if not ok then return nil end
    return value
end

function textutils.unserialiseJSON(text) return parseJSON(text) end
textutils.unserializeJSON = textutils.unserialiseJSON

---------------------------------------------------------------- rednet / shell
---------------------------------------------------------------- http
-- Serves a fake GitHub: the git tree API plus raw file downloads. The remote
-- contents default to the project as it exists on disk.
local remote = {}
for path, contents in pairs(files) do remote[path] = contents end

local function jsonEscape(text)
    return (text:gsub('[%c"\\]', function(char)
        local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
        return map[char] or string.format("\\u%04x", char:byte())
    end))
end

-- Not git's SHA-1, just a deterministic content hash. The updater only ever
-- compares these for equality, and a constant would make "is there an update?"
-- untestable.
local function contentHash(text)
    local a, b = 5381, 52711
    for index = 1, #text do
        local byte = text:byte(index)
        a = (a * 33 + byte) % 4294967296
        b = (b * 31 + byte * 7) % 4294967296
    end
    return ("%08x%08x%08x"):format(a, b, #text % 4294967296)
end

local function treeResponse()
    local paths = {}
    for path in pairs(remote) do paths[#paths + 1] = path end
    table.sort(paths)

    local entries = {}
    local fingerprint = {}
    local seenDirs = {}

    for _, path in ipairs(paths) do
        local dir = path:match("^(.*)/[^/]*$")
        if dir and not seenDirs[dir] then
            seenDirs[dir] = true
            entries[#entries + 1] = ('{"path":"%s","type":"tree"}'):format(jsonEscape(dir))
        end
        local sha = contentHash(remote[path])
        entries[#entries + 1] = ('{"path":"%s","type":"blob","sha":"%s","size":%d}')
            :format(jsonEscape(path), sha, #remote[path])
        fingerprint[#fingerprint + 1] = path .. ":" .. sha
    end

    -- The root SHA has to change whenever any file changes, like a real tree.
    return ('{"sha":"%s","truncated":false,"tree":[%s]}')
        :format(contentHash(table.concat(fingerprint, "\n")), table.concat(entries, ","))
end

local httpCalls = { tree = 0, raw = 0 }

http = {}
function http.get(url)
    local body
    if url:find("api.github.com", 1, true) and url:find("/git/trees/", 1, true) then
        httpCalls.tree = httpCalls.tree + 1
        body = treeResponse()
    else
        local path = url:match("raw%.githubusercontent%.com/[^/]+/[^/]+/[^/]+/(.+)$")
        body = path and remote[path]
        if body then httpCalls.raw = httpCalls.raw + 1 end
    end

    if not body then return nil, "404 Not Found" end
    return {
        readAll = function() return body end,
        getResponseCode = function() return 200 end,
        close = function() end,
    }
end
http.checkURL = function() return true end

---------------------------------------------------------------- rednet
-- Records what this computer sent and lets a scenario inject what it would
-- have received. Two computers are never simulated at once: each side is
-- driven against the protocol instead, which is what actually has to hold.
local sent = {}
local rednetOpen = {}

rednet = {
    isOpen = function(side) return rednetOpen[side] == true end,
    open = function(side) rednetOpen[side] = true end,
    close = function(side) rednetOpen[side] = nil end,
    send = function(id, message, protocol)
        sent[#sent + 1] = { target = id, message = message, protocol = protocol }
        return true
    end,
    broadcast = function(message, protocol)
        sent[#sent + 1] = { target = "*", message = message, protocol = protocol }
        return true
    end,
    host = function() end,
    unhost = function() end,
    lookup = function() return nil end,
}

shell = { getRunningProgram = function() return "startup.lua" end }

---------------------------------------------------------------- console input
-- `read` and `write` are CC globals, not Lua ones. Scenarios queue the answers
-- a prompt should receive.
local inputQueue = {}
function read() return table.remove(inputQueue, 1) or "" end
function write(text) io.write(tostring(text)) end

keys = { q = 16, enter = 28 }

function printError(...) print("ERROR:", ...) end

---------------------------------------------------------------- test helpers
__TEST = {
    monitor = monitor,
    terminal = nativeTerm,
    files = files,
    --- The simulated farm output barrel (drain/fill/produced).
    farmOutput = farmOutput,
    --- Current redstone output state, as the farm module left it.
    redstone = function(side) return redstoneOutputs[side] == true end,

    --- Attach an Advanced Peripherals device by type.
    addAdvancedPeripheral = function(kind, name)
        local factories = {
            playerDetector = makePlayerDetector,
            chatBox = makeChatBox,
            redstoneIntegrator = makeRedstoneIntegrator,
        }
        local factory = factories[kind]
        if not factory then error("no mock for " .. tostring(kind), 2) end
        peripherals[name or (kind .. "_0")] = { types = { kind }, object = factory() }
    end,

    addSpeaker = function(name)
        peripherals[name or "speaker_0"] = { types = { "speaker" }, object = makeSpeaker() }
    end,

    --- Who the player detector reports. Entries are names, or
    --- { name = "x", distance = 4 } to test radius filtering.
    setPlayers = function(list) playersInRange = list or {} end,

    --- What the chat box and speaker were asked to emit.
    chatLog = function() return chatLog end,
    soundLog = function() return soundLog end,
    clearChatLog = function()
        for index = #chatLog, 1, -1 do chatLog[index] = nil end
        for index = #soundLog, 1, -1 do soundLog[index] = nil end
    end,

    --- Pin the monitor size, for scenarios whose subject is the layout itself
    --- and which must not change meaning with MONITOR_W/MONITOR_H.
    resizeMonitor = function(width, height)
        monitor.width, monitor.height = width, height
    end,

    --- Attach a modem so networking can come up.
    addModem = function(name, wireless)
        peripherals[name or "modem_0"] = {
            types = { "modem" },
            object = {
                isWireless = function() return wireless == true end,
                open = function() end,
                close = function() end,
                transmit = function() end,
            },
        }
    end,

    --- Everything this computer put on the wire.
    sentMessages = function() return sent end,
    lastSent = function(messageType)
        for index = #sent, 1, -1 do
            local entry = sent[index]
            if not messageType or (entry.message and entry.message.type == messageType) then
                return entry
            end
        end
        return nil
    end,
    clearSent = function() for index = #sent, 1, -1 do sent[index] = nil end end,

    --- Deliver a rednet message as if another computer had sent it.
    receive = function(senderId, message, protocol)
        queue[#queue + 1] = { "rednet_message", senderId, message, protocol or "baseos" }
    end,
    queueTouch = function(x, y) queue[#queue + 1] = { "monitor_touch", "monitor_0", x, y } end,
    --- Deliver a touch as the Nth event, so timers get a chance to run first.
    touchAt = function(index, x, y) injections[index] = { "monitor_touch", "monitor_0", x, y } end,
    pending = function() return #queue end,
    processed = function() return processed end,
    snapshots = function() return snapshots end,
    removePeripheral = function(name) peripherals[name] = nil end,
    detach = function(name)
        peripherals[name] = nil
        queue[#queue + 1] = { "peripheral_detach", name }
    end,
    queueEventAt = function(index, ...) injections[index] = { ... } end,
    --- Deliver whatever `producer()` returns as the Nth event (or nothing).
    injectAt = function(index, producer) injections[index] = producer end,
    --- Errors raised inside scenario hooks, which BaseOS would otherwise hide.
    errors = function() return harnessErrors end,
    --- True when startup.lua printed its crash banner on the terminal.
    crashed = function()
        return nativeTerm.render():find("stopped with an error", 1, true) ~= nil
    end,
    --- What the fake GitHub serves (defaults to the project on disk).
    remote = function() return remote end,
    --- Attach `count` energy peripherals, to exercise the power breakdown and
    --- the list pager. Every third one also reports a transfer rate.
    addEnergyCells = function(count, options)
        options = options or {}
        for index = 1, count do
            local capacity = 1000000 * index
            local stored = capacity * (0.05 + (index % 7) * 0.14)
            local object = {
                getEnergy = function() return math.floor(stored) end,
                getEnergyCapacity = function() return capacity end,
            }
            if index % 3 == 0 then
                object.getTransferRate = function() return 120 * index end
            end
            local isPowah = options.powah and index % 4 == 0
            if isPowah then
                object.getGenerationRate = function() return 80 * index end
            end
            peripherals[(isPowah and "powah:energy_cell_" or "energy_cell_") .. index] = {
                types = { "energy_storage", isPowah and "powah:energy_cell_basic" or "modded:energy_cell" },
                object = object,
            }
        end
    end,

    --- Answers handed to the next `read()` prompts, in order.
    queueInput = function(...)
        for _, answer in ipairs({ ... }) do inputQueue[#inputQueue + 1] = answer end
    end,
    --- How many requests hit the fake GitHub, to prove nothing was downloaded.
    httpCalls = function() return { tree = httpCalls.tree, raw = httpCalls.raw } end,
    resetHttpCalls = function() httpCalls.tree, httpCalls.raw = 0, 0 end,
    --- Drive the UI by what it shows rather than by coordinates.
    ui = {
        --- The screen currently on top of the navigation stack.
        screen = function()
            local nav = BASEOS and BASEOS.loaded["ui.navigation"]
            local entry = nav and nav.current()
            return entry and entry.screen or nil
        end,

        --- Name of the current screen, e.g. "dashboard".
        screenName = function()
            local nav = BASEOS and BASEOS.loaded["ui.navigation"]
            return nav and nav.currentName() or nil
        end,

        --- Centre of the first component whose label matches `text`.
        -- Searches the modal first (it is exclusive while open), then the
        -- screen tree, so buttons and zone tiles are both reachable.
        locate = function(text)
            local screen = __TEST.ui.screen()
            if not screen then return nil end

            local function labelOf(component)
                if component.label then return component.label end
                if component.zone and component.zone.label then return component.zone.label end
                -- Labels keep their text in `text`; metric rows are found this way.
                if type(component.text) == "string" then return component.text end
                return nil
            end

            local function search(components)
                for _, component in ipairs(components or {}) do
                    if labelOf(component) == text and component.visible ~= false then
                        return component.x + math.floor(component.w / 2),
                               component.y + math.floor((component.h - 1) / 2)
                    end
                    if component.children then
                        local x, y = search(component.children)
                        if x then return x, y end
                    end
                end
                return nil
            end

            if screen.modal then
                local x, y = search(screen.modal.buttons)
                if x then return x, y end
            end
            return search(screen.children)
        end,

        --- A touch event on the component labelled `text`. Errors when absent,
        --- so a scenario fails loudly instead of silently touching nothing.
        touch = function(text)
            local x, y = __TEST.ui.locate(text)
            if not x then
                error(("no component labelled '%s' on screen '%s'")
                    :format(text, tostring(__TEST.ui.screenName())), 0)
            end
            return { "monitor_touch", "monitor_0", x, y }
        end,

        --- A touch on the header's back button.
        back = function() return { "monitor_touch", "monitor_0", 3, 1 } end,
    },

    --- Empty the computer's filesystem, keeping the listed paths.
    wipeDisk = function(keep)
        local kept = {}
        for _, path in ipairs(keep or {}) do kept[path] = true end
        for path in pairs(files) do
            if not kept[path] then files[path] = nil end
        end
        for dir in pairs(dirs) do dirs[dir] = nil end
    end,
}

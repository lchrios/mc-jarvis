--- Exercise Advanced Peripherals and report what actually answers.
--
--   probe                  try every AP device attached, read-only
--   probe chat "hola"      send a real chat message (the only writing test)
--   probe <name>           only that peripheral
--
-- `scan` lists what methods exist; this one calls them and shows the result,
-- which is the difference between "the method is there" and "it works". BaseOS
-- guesses AP method names from candidate lists because they change between
-- versions - this is how you find out which guess was right.
--
-- Only read-only methods run unless you ask for `chat`.

local READ_ONLY = {
    playerDetector = {
        { "getOnlinePlayers", {}, "players on the server" },
        { "getPlayersInRange", { 16 }, "players within 16 blocks" },
    },
    environmentDetector = {
        { "getBiome", {}, "biome" },
        { "getTime", {}, "world time" },
        { "getDay", {}, "day" },
        { "isRaining", {}, "raining" },
        { "isThunder", {}, "thunder" },
        { "getMoonName", {}, "moon phase" },
        { "getDimensionName", {}, "dimension" },
        { "getRadiation", {}, "radiation" },
    },
    energyDetector = {
        { "getTransferRate", {}, "FE/t through this block" },
        { "getTransferRateLimit", {}, "configured limit" },
    },
    inventoryManager = {
        { "getOwner", {}, "bound player" },
        { "isPlayerEquipped", {}, "player online and equipped" },
    },
    blockReader = {
        { "getBlockName", {}, "block in front" },
    },
    geoScanner = {
        { "getFuelLevel", {}, "fuel" },
        { "getScanCooldown", {}, "cooldown" },
    },
    redstoneIntegrator = {
        { "getOutput", { "top" }, "output on top" },
        { "getInput", { "top" }, "input on top" },
    },
    meBridge = {
        { "getEnergyStorage", {}, "network energy" },
        { "getEnergyUsage", {}, "network draw" },
    },
    rsBridge = {
        { "getEnergyStorage", {}, "network energy" },
    },
    chatBox = {},   -- writing only; never exercised without being asked
}

local AP_TYPES = {}
for kind in pairs(READ_ONLY) do AP_TYPES[kind] = true end

---------------------------------------------------------------------------

local function typesOf(name)
    local ok, types = pcall(function() return { peripheral.getType(name) } end)
    return (ok and types) or {}
end

local function apKind(name)
    for _, kind in ipairs(typesOf(name)) do
        if AP_TYPES[kind] then return kind end
    end
    return nil
end

local function methodSet(name)
    local ok, list = pcall(peripheral.getMethods, name)
    if not ok or type(list) ~= "table" then return {} end
    local set = {}
    for _, method in ipairs(list) do set[method] = true end
    return set
end

local function show(value)
    if type(value) ~= "table" then return tostring(value) end

    local parts = {}
    for _, item in ipairs(value) do
        parts[#parts + 1] = type(item) == "table" and "{...}" or tostring(item)
        if #parts >= 6 then parts[#parts + 1] = "..." break end
    end
    if #parts == 0 then
        for key in pairs(value) do
            parts[#parts + 1] = tostring(key)
            if #parts >= 6 then break end
        end
        if #parts == 0 then return "(empty table)" end
        return "{ " .. table.concat(parts, ", ") .. " }"
    end
    return "[" .. table.concat(parts, ", ") .. "]  (" .. #value .. ")"
end

--- Call one method and print what came back.
local function tryMethod(name, method, args, description)
    local results = table.pack(pcall(peripheral.call, name, method, table.unpack(args)))

    if not results[1] then
        print(("  x %-24s %s"):format(method, tostring(results[2]):sub(1, 34)))
        return false
    end
    if results.n < 2 then
        print(("  ? %-24s returned nothing"):format(method))
        return false
    end

    print(("  o %-24s %s"):format(method, show(results[2]):sub(1, 34)))
    if description then print(("    %s"):format(description)) end
    return true
end

local function probeOne(name)
    local kind = apKind(name)
    if not kind then
        print(name .. " is not an Advanced Peripherals device.")
        print("Types: " .. table.concat(typesOf(name), ", "))
        return
    end

    print("")
    print(name .. "  (" .. kind .. ")")

    local checks = READ_ONLY[kind] or {}
    if #checks == 0 then
        print("  nothing safe to read; this device only writes.")
        if kind == "chatBox" then
            print("  try:  probe chat \"hola\"")
        end
        return
    end

    local methods = methodSet(name)
    local worked, missing = 0, 0

    for _, check in ipairs(checks) do
        local method, args, description = check[1], check[2], check[3]
        if methods[method] then
            if tryMethod(name, method, args, description) then worked = worked + 1 end
        else
            missing = missing + 1
            print(("  - %-24s not on this version"):format(method))
        end
    end

    print(("  %d worked, %d missing"):format(worked, missing))
end

---------------------------------------------------------------------------

local function probeChat(message)
    local boxes = {}
    for _, name in ipairs(peripheral.getNames()) do
        if apKind(name) == "chatBox" then boxes[#boxes + 1] = name end
    end

    if #boxes == 0 then
        printError("No Chat Box attached.")
        return
    end

    message = message or "test message from BaseOS"

    for _, name in ipairs(boxes) do
        print(name .. ":")
        local methods = methodSet(name)
        local sent = false

        for _, method in ipairs({ "sendMessage", "say" }) do
            if methods[method] and not sent then
                local ok, err = pcall(peripheral.call, name, method, message, "BaseOS")
                if ok then
                    print("  o " .. method .. " accepted it - check chat")
                    sent = true
                else
                    print("  x " .. method .. " -> " .. tostring(err):sub(1, 40))
                end
            end
        end

        if not sent then
            print("  no sending method answered; 'scan " .. name .. "' shows what it has")
        end
    end
end

---------------------------------------------------------------------------

local argument, extra = ...

if argument == "chat" then
    probeChat(extra)
    return
end

if argument then
    if not peripheral.isPresent(argument) then
        printError("No peripheral called '" .. argument .. "'.")
        return
    end
    probeOne(argument)
    return
end

print("Advanced Peripherals probe")

local found = {}
for _, name in ipairs(peripheral.getNames()) do
    if apKind(name) then found[#found + 1] = name end
end
table.sort(found)

if #found == 0 then
    printError("No Advanced Peripherals devices attached.")
    print("")
    print("Attach one next to the computer, or on a wired modem you have")
    print("right-clicked to enable. 'scan' lists everything connected.")
    return
end

print(#found .. " device(s) found.")
for _, name in ipairs(found) do probeOne(name) end

print("")
print("o worked   x errored   - missing on this version")
print("Paste this if something BaseOS expects is not answering.")

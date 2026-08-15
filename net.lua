--- Rednet diagnostics, from the shell.
--
--   net              what this computer is, its modems, then 5s of listening
--   net listen [s]   watch the protocol for s seconds and print every message
--   net ping [s]     ask everyone to identify themselves and wait for answers
--   net hosts        who is registered on the protocol right now
--
-- Runs with BaseOS stopped, which is the point: when the panel will not boot,
-- or when the question is about the computer that has no panel at all. It opens
-- the modems itself and closes the ones it opened on the way out.
--
-- The one thing it can prove that nothing else can: whether the messages
-- arriving are *accepted*. A wrong secret and an unplugged modem produce the
-- same silence upstairs; here they read completely differently.

local function bootstrap()
    local handle = fs.open("boot.lua", "r")
    if not handle then
        printError("boot.lua is missing. Run 'updater force' to repair the install.")
        error("", 0)
    end
    local source = handle.readAll()
    handle.close()
    return load(source, "@boot.lua", "t", _ENV or _G)()
end

local BASEOS = bootstrap()
local config = BASEOS.require("core.config")
local identity = BASEOS.require("core.identity")
local protocol = BASEOS.require("network.protocol")
local auth = BASEOS.require("network.auth")

config.load({ root = BASEOS.root })

local settings = config.section("network") or {}
local PROTOCOL = settings.protocol or protocol.NAME
local me = identity.load(BASEOS.root)
local HOSTNAME = settings.hostname or (me and me.name)
    or os.getComputerLabel() or ("computer_" .. os.getComputerID())

auth.configure({ secret = settings.secret, window = settings.authWindow })

---------------------------------------------------------------------------
-- Modems
---------------------------------------------------------------------------

local opened = {}

local function modems()
    local names = {}
    for _, side in ipairs(peripheral.getNames()) do
        local ok, kind = pcall(peripheral.getType, side)
        if ok and kind == "modem" then names[#names + 1] = side end
    end
    return names
end

local function openAll()
    local found = modems()
    if #found == 0 then return 0 end

    for _, side in ipairs(found) do
        if not rednet.isOpen(side) then
            if pcall(rednet.open, side) then opened[#opened + 1] = side end
        end
    end
    return #found
end

--- Leave the computer as it was found.
local function closeOpened()
    for _, side in ipairs(opened) do pcall(rednet.close, side) end
end

---------------------------------------------------------------------------
-- Report
---------------------------------------------------------------------------

--- A short digest of the secret, so two computers can be compared without
--- either of them printing it. Same secret, same six characters.
local function secretFingerprint()
    if not settings.secret or settings.secret == "" then return nil end
    return auth.digest("fingerprint\31" .. settings.secret):sub(1, 6)
end

local function summary()
    print("BaseOS rednet")
    print(("  computer:  #%d  %s"):format(os.getComputerID(),
        tostring(os.getComputerLabel() or "(unlabelled)")))
    print(("  identity:  %s"):format(me
        and (tostring(me.role) .. " '" .. tostring(me.name) .. "'")
        or "none - run 'setup'"))
    print(("  protocol:  %s   as '%s'"):format(PROTOCOL, HOSTNAME))

    local fingerprint = secretFingerprint()
    if fingerprint then
        print(("  secret:    set (fingerprint %s)"):format(fingerprint))
        print("             it must read the same on every computer")
    else
        print("  secret:    NOT SET - messages are neither signed nor checked")
    end

    local found = modems()
    if #found == 0 then
        printError("  modems:    none. Rednet cannot work without one.")
        return false
    end

    for _, side in ipairs(found) do
        local okWireless, wireless = pcall(peripheral.call, side, "isWireless")
        print(("  modem:     %-10s %s  %s"):format(side,
            (okWireless and wireless) and "wireless" or "wired",
            rednet.isOpen(side) and "open" or "closed"))
    end
    return true
end

---------------------------------------------------------------------------
-- Listening
---------------------------------------------------------------------------

--- Print one message the way it would be judged by BaseOS.
-- Checks it exactly once: `auth.verify` remembers what it has accepted, so
-- asking twice about the same message answers "already seen" the second time.
-- @return boolean whether BaseOS would have handled it
local function describe(senderId, message)
    if type(message) ~= "table" then
        print(("  #%-3s  (not a BaseOS message)"):format(tostring(senderId)))
        return false
    end

    local valid, why = protocol.validate(message)
    local verdict, detail

    if not valid then
        verdict, detail = "REFUSED", why
    else
        local authentic, reason = auth.verify(message)
        if authentic then
            verdict = "ok"
        else
            verdict, detail = "REFUSED", reason
        end
    end

    print(("  #%-3s %-9s %-20s from %s%s"):format(
        tostring(senderId), verdict,
        tostring(message.type):sub(1, 20),
        tostring(message.source),
        detail and ("  <- " .. tostring(detail)) or ""))

    if verdict == "REFUSED" and detail == "unsigned" then
        print("       that computer has no secret set; this one has")
    elseif verdict == "REFUSED" and detail == "bad signature" then
        print("       its secret is different from this computer's")
    end

    return verdict == "ok"
end

local function listen(seconds)
    print("")
    print(("Listening on '%s' for %ds..."):format(PROTOCOL, seconds))

    local deadline = os.startTimer(seconds)
    local heard, refused = 0, 0

    while true do
        local event, first, second, third = os.pullEvent()

        if event == "timer" and first == deadline then break end

        if event == "rednet_message" then
            local senderId, message, receivedProtocol = first, second, third
            if receivedProtocol == nil or receivedProtocol == PROTOCOL then
                heard = heard + 1
                if not describe(senderId, message) then refused = refused + 1 end
            end
        end
    end

    print("")
    if heard == 0 then
        printError(("Nothing at all in %ds."):format(seconds))
        print("Either nobody is running, their modem is not attached, or they")
        print("are on a different protocol. Check 'net' on the other computer.")
    elseif refused > 0 then
        printError(("%d of %d message(s) would be thrown away."):format(refused, heard))
        print("Fix the secret and the other computer appears immediately.")
    else
        print(("%d message(s), all acceptable."):format(heard))
    end
    return heard
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local function ping(seconds)
    local message = {
        version = protocol.VERSION,
        id = os.epoch("utc") % 100000,
        source = HOSTNAME,
        target = protocol.BROADCAST,
        type = protocol.TYPES.DISCOVER,
        timestamp = os.epoch("utc"),
        payload = { at = os.epoch("utc"), from = "net" },
    }
    auth.sign(message)

    print("")
    print("Asking everyone on '" .. PROTOCOL .. "' to answer...")
    rednet.broadcast(message, PROTOCOL)
    return listen(seconds)
end

local function hosts()
    print("")
    print("Registered on '" .. PROTOCOL .. "':")
    local found = table.pack(rednet.lookup(PROTOCOL))

    if found.n == 0 or found[1] == nil then
        printError("  nobody")
        print("  A BaseOS computer registers itself when its network comes up,")
        print("  so an empty list means none of them is running with a modem")
        print("  in range on this protocol.")
        return
    end
    for index = 1, found.n do
        if found[index] then print("  computer #" .. tostring(found[index])) end
    end
end

---------------------------------------------------------------------------

local command, argument = ...
local seconds = tonumber(argument) or 5

local ok, err = pcall(function()
    local hasModem = summary()
    if not hasModem then return end

    openAll()

    if command == "hosts" then
        hosts()
    elseif command == "ping" then
        ping(seconds)
    elseif command == "listen" or command == nil then
        listen(seconds)
    else
        printError("Unknown command '" .. tostring(command) .. "'.")
        print("Try: net | net listen [s] | net ping [s] | net hosts")
    end
end)

closeOpened()

if not ok then printError(tostring(err)) end

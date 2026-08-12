--- Advanced Peripherals helpers.
--
-- STATUS: partially unverified. The peripheral *types* below are stable across
-- AP releases; individual method names are probed, never assumed. Each wrapper
-- returns nil for anything the installed version does not implement.
--
-- Covered: Player Detector, Environment Detector, Chat Box, Energy Detector,
-- Inventory Manager, Redstone Integrator, Block Reader, Geo Scanner.

local base = require("adapters.base")

local ap = {}

ap.id = "advanced_peripherals"
ap.label = "Advanced Peripherals"

--- Canonical peripheral type names as reported by `peripheral.getType`.
ap.TYPES = {
    playerDetector = "playerDetector",
    environmentDetector = "environmentDetector",
    chatBox = "chatBox",
    energyDetector = "energyDetector",
    inventoryManager = "inventoryManager",
    redstoneIntegrator = "redstoneIntegrator",
    blockReader = "blockReader",
    geoScanner = "geoScanner",
    meBridge = "meBridge",
    rsBridge = "rsBridge",
    colonyIntegrator = "colonyIntegrator",
    nbtStorage = "nbtStorage",
}

local function typeOf(proxy)
    if not proxy or not proxy.types then return nil end
    for _, kind in ipairs(proxy.types()) do
        if ap.TYPES[kind] then return kind end
    end
    return nil
end

function ap.matches(proxy)
    return typeOf(proxy) ~= nil
end

---------------------------------------------------------------------------
-- Per-type wrappers
---------------------------------------------------------------------------

local wrappers = {}

function wrappers.playerDetector(proxy)
    return {
        kind = "playerDetector",
        --- Names of players in range, or nil when unsupported.
        online = function()
            local list = base.callAny(proxy, { "getOnlinePlayers", "getPlayers" })
            return type(list) == "table" and list or nil
        end,
        inRange = function(range)
            local list = base.call(proxy, "getPlayersInRange", range or 32)
            return type(list) == "table" and list or {}
        end,
        isInRange = function(range, player)
            return base.call(proxy, "isPlayerInRange", range or 32, player) == true
        end,
        position = function(player)
            local pos = base.call(proxy, "getPlayerPos", player)
            return type(pos) == "table" and pos or nil
        end,
    }
end

function wrappers.environmentDetector(proxy)
    return {
        kind = "environmentDetector",
        time = function() return base.number(base.call(proxy, "getTime"), nil) end,
        day = function() return base.number(base.call(proxy, "getDay"), nil) end,
        biome = function() return base.call(proxy, "getBiome") end,
        dimension = function() return base.callAny(proxy, { "getDimensionName", "getDimension" }) end,
        isRaining = function() return base.call(proxy, "isRaining") == true end,
        isThunder = function() return base.call(proxy, "isThunder") == true end,
        moonPhase = function() return base.callAny(proxy, { "getMoonName", "getMoonId" }) end,
        radiation = function() return base.call(proxy, "getRadiation") end,
    }
end

function wrappers.chatBox(proxy)
    return {
        kind = "chatBox",
        --- Broadcast to everyone. Returns ok, error.
        say = function(message, prefix, brackets, bracketColor)
            local ok, err = base.call(proxy, "sendMessage",
                tostring(message), prefix or "BaseOS", brackets, bracketColor)
            return ok ~= nil, err
        end,
        tell = function(player, message, prefix)
            local ok, err = base.call(proxy, "sendMessageToPlayer",
                tostring(message), player, prefix or "BaseOS")
            return ok ~= nil, err
        end,
    }
end

function wrappers.energyDetector(proxy)
    return {
        kind = "energyDetector",
        rate = function() return base.number(base.call(proxy, "getTransferRate"), 0) end,
        limit = function() return base.number(base.call(proxy, "getTransferRateLimit"), nil) end,
        setLimit = function(value) return base.call(proxy, "setTransferRateLimit", value) end,
    }
end

function wrappers.inventoryManager(proxy)
    return {
        kind = "inventoryManager",
        owner = function() return base.call(proxy, "getOwner") end,
        armor = function() return base.call(proxy, "getArmor") end,
        items = function()
            local raw = base.call(proxy, "getItems")
            if type(raw) ~= "table" then return nil end
            local result = {}
            for _, stack in ipairs(raw) do
                local item = base.itemStack(stack)
                if item then result[#result + 1] = item end
            end
            return result
        end,
        isPlayerEquipped = function() return base.call(proxy, "isPlayerEquipped") == true end,
    }
end

function wrappers.redstoneIntegrator(proxy)
    return {
        kind = "redstoneIntegrator",
        get = function(side) return base.call(proxy, "getOutput", side) end,
        set = function(side, value) return base.call(proxy, "setOutput", side, value) end,
        getAnalog = function(side) return base.number(base.call(proxy, "getAnalogOutput", side), 0) end,
        setAnalog = function(side, value) return base.call(proxy, "setAnalogOutput", side, value) end,
        input = function(side) return base.call(proxy, "getInput", side) == true end,
    }
end

function wrappers.blockReader(proxy)
    return {
        kind = "blockReader",
        blockName = function() return base.call(proxy, "getBlockName") end,
        blockData = function()
            local data = base.call(proxy, "getBlockData")
            return type(data) == "table" and data or nil
        end,
    }
end

function wrappers.geoScanner(proxy)
    return {
        kind = "geoScanner",
        scan = function(radius)
            local result = base.call(proxy, "scan", radius or 8)
            return type(result) == "table" and result or nil
        end,
        fuel = function() return base.number(base.call(proxy, "getFuelLevel"), nil) end,
        cooldown = function() return base.number(base.call(proxy, "getScanCooldown"), nil) end,
    }
end

--- Wrap an Advanced Peripherals device. Returns nil for unknown types.
function ap.wrap(proxy)
    local kind = typeOf(proxy)
    if not kind then return nil end

    local factory = wrappers[kind]
    if not factory then
        -- Known AP peripheral without a dedicated wrapper yet: expose the raw
        -- proxy so a module can still probe it explicitly.
        return { kind = kind, proxy = proxy, raw = true }
    end

    local wrapped = factory(proxy)
    wrapped.proxy = proxy
    wrapped.name = function() return proxy.name and proxy.name() or "?" end
    return wrapped
end

ap.wrappers = wrappers

return ap

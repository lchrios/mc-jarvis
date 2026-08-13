--- Advanced Peripherals.
--
-- VERIFIED against AdvancedPeripherals-1.21.1-0.7.62b: the peripheral type ids
-- and method names below were read out of the mod jar's `@LuaFunction`
-- annotations, not guessed.
--
-- Two things that bite:
--
--   * Type ids are snake_case (`player_detector`), not camelCase. Matching on
--     `playerDetector` silently matches nothing at all.
--   * This version ships **no Redstone Integrator**. The only integrator is the
--     MineColonies one. Remote redstone has to come from a peripheral that
--     exposes `setOutput`, whatever mod provides it - see `redstoneOutput`.
--
-- Anything a future version renames still degrades to nil rather than throwing.

local base = require("adapters.base")

local ap = {}

ap.id = "advanced_peripherals"
ap.label = "Advanced Peripherals"

--- Peripheral type ids as reported by `peripheral.getType`.
ap.TYPES = {
    player_detector = "player_detector",
    environment_detector = "environment_detector",
    chat_box = "chat_box",
    energy_detector = "energy_detector",
    geo_scanner = "geo_scanner",
    block_reader = "block_reader",
    inventory_manager = "inventory_manager",
    me_bridge = "me_bridge",
    rs_bridge = "rs_bridge",
    nbt_storage = "nbt_storage",
    colony_integrator = "colony_integrator",
}

--- Older camelCase spellings, still accepted so a different pack version does
--- not go unrecognised.
local LEGACY_TYPES = {
    playerDetector = "player_detector",
    environmentDetector = "environment_detector",
    chatBox = "chat_box",
    energyDetector = "energy_detector",
    geoScanner = "geo_scanner",
    blockReader = "block_reader",
    inventoryManager = "inventory_manager",
    meBridge = "me_bridge",
    rsBridge = "rs_bridge",
    nbtStorage = "nbt_storage",
    colonyIntegrator = "colony_integrator",
}

local function typeOf(proxy)
    if not proxy or not proxy.types then return nil end
    for _, kind in ipairs(proxy.types()) do
        if ap.TYPES[kind] then return kind end
        if LEGACY_TYPES[kind] then return LEGACY_TYPES[kind] end
    end
    return nil
end

ap.typeOf = typeOf

function ap.matches(proxy)
    return typeOf(proxy) ~= nil
end

---------------------------------------------------------------------------
-- Per-type wrappers
---------------------------------------------------------------------------

local wrappers = {}

function wrappers.player_detector(proxy)
    return {
        kind = "player_detector",
        --- Names of everyone on the server.
        online = function()
            local list = base.call(proxy, "getOnlinePlayers")
            return type(list) == "table" and list or nil
        end,
        --- Names within `range` blocks of the detector.
        inRange = function(range)
            local list = base.call(proxy, "getPlayersInRange", range or 32)
            return type(list) == "table" and list or {}
        end,
        isInRange = function(range, player)
            return base.call(proxy, "isPlayerInRange", range or 32, player) == true
        end,
        --- Anyone inside a box between two corners.
        inCubic = function(x, y, z)
            local list = base.call(proxy, "getPlayersInCubic", x, y, z)
            return type(list) == "table" and list or {}
        end,
        position = function(player)
            local pos = base.call(proxy, "getPlayerPos", player)
            return type(pos) == "table" and pos or nil
        end,
    }
end

function wrappers.environment_detector(proxy)
    return {
        kind = "environment_detector",
        time = function() return base.number(base.call(proxy, "getTime"), nil) end,
        biome = function() return base.call(proxy, "getBiome") end,
        -- `getDimension`, not `getDimensionName`; there is no `getDay`.
        dimension = function() return base.call(proxy, "getDimension") end,
        isRaining = function() return base.call(proxy, "isRaining") == true end,
        isThunder = function() return base.call(proxy, "isThunder") == true end,
        isSunny = function() return base.call(proxy, "isSunny") == true end,
        isSlimeChunk = function() return base.call(proxy, "isSlimeChunk") == true end,
        moonPhase = function() return base.call(proxy, "getMoonName") end,
        skyLight = function() return base.number(base.call(proxy, "getSkyLightLevel"), nil) end,
        blockLight = function() return base.number(base.call(proxy, "getBlockLightLevel"), nil) end,
        canSleep = function() return base.call(proxy, "canSleepHere") == true end,
        --- Entities nearby; costs fuel on the detector.
        scanEntities = function(range)
            local list = base.call(proxy, "scanEntities", range or 8)
            return type(list) == "table" and list or nil
        end,
    }
end

function wrappers.chat_box(proxy)
    return {
        kind = "chat_box",
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
        --- Raw JSON text component, for colours and hover text.
        sayFormatted = function(json, prefix)
            local ok, err = base.call(proxy, "sendFormattedMessage", json, prefix or "BaseOS")
            return ok ~= nil, err
        end,
        --- Corner popup rather than a chat line.
        toast = function(player, title, message)
            local ok, err = base.call(proxy, "sendToastToPlayer",
                tostring(message), tostring(title), player, "BaseOS")
            return ok ~= nil, err
        end,
    }
end

function wrappers.energy_detector(proxy)
    return {
        kind = "energy_detector",
        rate = function() return base.number(base.call(proxy, "getTransferRate"), 0) end,
        limit = function() return base.number(base.call(proxy, "getTransferRateLimit"), nil) end,
        setLimit = function(value) return base.call(proxy, "setTransferRateLimit", value) end,
    }
end

function wrappers.inventory_manager(proxy)
    local function items(method, ...)
        local raw = base.call(proxy, method, ...)
        if type(raw) ~= "table" then return nil end
        local result = {}
        for _, stack in ipairs(raw) do
            local item = base.itemStack(stack)
            if item then result[#result + 1] = item end
        end
        return result
    end

    return {
        kind = "inventory_manager",
        owner = function() return base.call(proxy, "getOwner") end,
        armor = function() return items("getArmor") end,
        items = function() return items("getItems") end,
        chestItems = function() return items("getItemsChest") end,
        inHand = function() return base.itemStack(base.call(proxy, "getItemInHand")) end,
        freeSlots = function() return base.number(base.call(proxy, "getEmptySpace"), nil) end,
        isPlayerEquipped = function() return base.call(proxy, "isPlayerEquipped") == true end,
        isWearing = function(slot) return base.call(proxy, "isWearing", slot) == true end,
        --- Move items between the player and the attached inventory.
        toPlayer = function(count, side, slot, item)
            return base.number(base.call(proxy, "addItemToPlayer", side, {
                count = count, fromSlot = slot, name = item,
            }), 0)
        end,
        fromPlayer = function(count, side, slot, item)
            return base.number(base.call(proxy, "removeItemFromPlayer", side, {
                count = count, toSlot = slot, name = item,
            }), 0)
        end,
    }
end

function wrappers.block_reader(proxy)
    return {
        kind = "block_reader",
        blockName = function() return base.call(proxy, "getBlockName") end,
        blockData = function()
            local data = base.call(proxy, "getBlockData")
            return type(data) == "table" and data or nil
        end,
        blockStates = function()
            local data = base.call(proxy, "getBlockStates")
            return type(data) == "table" and data or nil
        end,
        isTileEntity = function() return base.call(proxy, "isTileEntity") == true end,
    }
end

function wrappers.geo_scanner(proxy)
    return {
        kind = "geo_scanner",
        scan = function(radius)
            local result = base.call(proxy, "scan", radius or 8)
            return type(result) == "table" and result or nil
        end,
        --- Fuel this scan would cost, before spending it.
        cost = function(radius) return base.number(base.call(proxy, "cost", radius or 8), nil) end,
        chunkAnalyze = function()
            local result = base.call(proxy, "chunkAnalyze")
            return type(result) == "table" and result or nil
        end,
        -- Fuel and cooldown come from the shared ability mixins, not the
        -- scanner class itself.
        fuel = function() return base.number(base.call(proxy, "getFuelLevel"), nil) end,
        maxFuel = function() return base.number(base.call(proxy, "getMaxFuelLevel"), nil) end,
        cooldown = function()
            return base.number(base.call(proxy, "getOperationCooldown", "scan"), nil)
        end,
    }
end

---------------------------------------------------------------------------

--- Wrap an Advanced Peripherals device. Returns nil for unknown types.
function ap.wrap(proxy)
    local kind = typeOf(proxy)
    if not kind then return nil end

    local factory = wrappers[kind]
    if not factory then
        -- Known device without a dedicated wrapper (bridges have their own
        -- adapter, colony and nbt storage are not used yet).
        return { kind = kind, proxy = proxy, raw = true }
    end

    local wrapped = factory(proxy)
    wrapped.proxy = proxy
    wrapped.name = function() return proxy.name and proxy.name() or "?" end
    return wrapped
end

---------------------------------------------------------------------------

--- Anything able to drive redstone remotely, whichever mod provides it.
--
-- Advanced Peripherals 0.7.62b has no Redstone Integrator, so this matches on
-- the capability instead of a type name: any peripheral exposing `setOutput`
-- will do.
function ap.redstoneOutput(proxy)
    if not base.has(proxy, "setOutput") then return nil end

    return {
        kind = "redstone_output",
        name = function() return proxy.name and proxy.name() or "?" end,
        set = function(side, value)
            local _, err = base.call(proxy, "setOutput", side or "top", value and true or false)
            return err == nil, err
        end,
        get = function(side) return base.call(proxy, "getOutput", side or "top") == true end,
        input = function(side) return base.call(proxy, "getInput", side or "top") == true end,
    }
end

ap.wrappers = wrappers

return ap

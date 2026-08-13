--- Peripheral diagnostics.
--
--   scan                 what is connected, and what BaseOS can read from it
--   scan <name>          every method one peripheral exposes
--   scan energy          only peripherals that report energy
--
-- Standalone on purpose: it has to work before BaseOS boots, and when BaseOS
-- refuses to boot. The capability guesses below mirror src/adapters/ but the
-- raw method list is always the truth - paste it if something is not detected.

local CATEGORY_METHODS = {
    energy = { "getEnergy", "getEnergyStored", "getStoredEnergy" },
    inventory = { "list" },
    fluid = { "tanks" },
    throughput = { "getTransferRate" },
    crafting = { "craftItem", "requestCrafting" },
}

-- Verified against the AdvancedPeripherals 0.7.62b jar: the type ids are
-- snake_case. The camelCase spellings are what the old wiki shows, kept here
-- only so an older build still gets labelled.
local ADVANCED_PERIPHERALS = {
    me_bridge = true, rs_bridge = true, chat_box = true, player_detector = true,
    environment_detector = true, energy_detector = true, inventory_manager = true,
    block_reader = true, geo_scanner = true, nbt_storage = true,
    colony_integrator = true,

    meBridge = true, rsBridge = true, chatBox = true, playerDetector = true,
    environmentDetector = true, energyDetector = true, inventoryManager = true,
    blockReader = true, geoScanner = true,
}

---------------------------------------------------------------------------

local function typesOf(name)
    local ok, types = pcall(function() return { peripheral.getType(name) } end)
    return (ok and types) or {}
end

local function methodsOf(name)
    local ok, list = pcall(peripheral.getMethods, name)
    if not ok or type(list) ~= "table" then return {}, {} end
    local set = {}
    for _, method in ipairs(list) do set[method] = true end
    table.sort(list)
    return list, set
end

local function firstMethod(set, candidates)
    for _, method in ipairs(candidates) do
        if set[method] then return method end
    end
    return nil
end

local function call(name, method, ...)
    if not method then return nil end
    local ok, value = pcall(peripheral.call, name, method, ...)
    return ok and value or nil
end

local function formatNumber(value)
    if type(value) ~= "number" then return tostring(value) end
    local suffixes = { "", "k", "M", "G", "T" }
    local index = 1
    while value >= 1000 and index < #suffixes do
        value = value / 1000
        index = index + 1
    end
    if index == 1 then return string.format("%d", math.floor(value)) end
    return string.format("%.1f%s", value, suffixes[index])
end

--- What BaseOS would be able to do with this peripheral.
local function describe(name, set)
    local notes = {}

    local stored = firstMethod(set, CATEGORY_METHODS.energy)
    if stored then
        local capacityMethod = firstMethod(set,
            { "getEnergyCapacity", "getMaxEnergyStored", "getCapacity" })
        local value = call(name, stored) or 0
        local capacity = call(name, capacityMethod) or 0
        local percent = capacity > 0 and math.floor(value / capacity * 100) or 0
        notes[#notes + 1] = ("ENERGY  %s / %s FE  (%d%%)")
            :format(formatNumber(value), formatNumber(capacity), percent)
    end

    if set.getTransferRate then
        notes[#notes + 1] = ("FLOW    %s FE/t"):format(formatNumber(call(name, "getTransferRate") or 0))
    end

    if set.list then
        local contents = call(name, "list") or {}
        local used, items = 0, 0
        for _, stack in pairs(contents) do
            used = used + 1
            items = items + (stack.count or 0)
        end
        notes[#notes + 1] = ("INV     %d/%s slots used, %d items")
            :format(used, tostring(call(name, "size") or "?"), items)
    end

    if set.tanks then
        local tanks = call(name, "tanks") or {}
        local count = 0
        for _ in pairs(tanks) do count = count + 1 end
        notes[#notes + 1] = ("FLUID   %d tank(s)"):format(count)
    end

    if firstMethod(set, CATEGORY_METHODS.crafting) then
        notes[#notes + 1] = "CRAFT   autocrafting available"
    end

    return notes
end

---------------------------------------------------------------------------

local function detail(name)
    if not peripheral.isPresent(name) then
        printError("No peripheral called '" .. name .. "'.")
        print("Run 'scan' to list what is connected.")
        return
    end

    local types = typesOf(name)
    local methods = methodsOf(name)

    print(name)
    print("  types: " .. table.concat(types, ", "))
    print("  " .. #methods .. " method(s):")
    for _, method in ipairs(methods) do
        print("    " .. method)
    end
end

local function overview(filter)
    local names = peripheral.getNames()
    table.sort(names)

    if #names == 0 then
        printError("No peripherals connected.")
        print("")
        print("Attach a block directly to the computer, or use a Wired Modem")
        print("plus Networking Cable - and right-click every modem to enable")
        print("it, otherwise the computer cannot see the block.")
        return
    end

    local shown, energyTotal, energyCapacity = 0, 0, 0

    for _, name in ipairs(names) do
        local types = typesOf(name)
        local _, set = methodsOf(name)
        local notes = describe(name, set)

        local isEnergy = firstMethod(set, CATEGORY_METHODS.energy) ~= nil
        if not filter or (filter == "energy" and isEnergy) then
            shown = shown + 1
            print(name)
            print("  types: " .. table.concat(types, ", "))
            for _, note in ipairs(notes) do print("  " .. note) end
            if #notes == 0 then
                print("  (no capability BaseOS understands - 'scan " .. name .. "')")
            end
            for _, kind in ipairs(types) do
                if ADVANCED_PERIPHERALS[kind] then
                    print("  Advanced Peripherals device")
                end
            end
        end

        if isEnergy then
            local storedMethod = firstMethod(set, CATEGORY_METHODS.energy)
            local capacityMethod = firstMethod(set,
                { "getEnergyCapacity", "getMaxEnergyStored", "getCapacity" })
            energyTotal = energyTotal + (call(name, storedMethod) or 0)
            energyCapacity = energyCapacity + (call(name, capacityMethod) or 0)
        end
    end

    print("")
    print(shown .. " of " .. #names .. " peripheral(s) shown.")
    if energyCapacity > 0 then
        print(("Energy total: %s / %s FE  (%d%%)"):format(
            formatNumber(energyTotal), formatNumber(energyCapacity),
            math.floor(energyTotal / energyCapacity * 100)))
        print("The power module reads exactly these; no configuration needed.")
    end
end

---------------------------------------------------------------------------

local argument = ...

if argument == nil then
    overview(nil)
elseif argument == "energy" then
    overview("energy")
else
    detail(argument)
end

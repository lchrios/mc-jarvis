--- Choose what this computer is.
--
--   setup            interactive wizard
--   setup show       print the current identity and exit
--   setup power      pick a profile without the menu
--
-- Writes `data/node.dat`, which the updater never touches, so the answer is
-- given once and survives every update and reboot.

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
local identity = BASEOS.require("core.identity")

---------------------------------------------------------------------------

local function describe(record)
    print("  role:    " .. tostring(record.role))
    print("  name:    " .. tostring(record.name))
    print("  profile: " .. tostring(record.profile or "custom"))
    if record.view then
        print("  view:    " .. tostring(record.view.title or record.view.id))
    end
    if record.modules then
        print("  modules: " .. table.concat(record.modules, ", "))
    else
        print("  modules: from config/modules.lua")
    end
end

local function ask(question, default)
    if default and default ~= "" then
        write(question .. " [" .. default .. "] ")
    else
        write(question .. " ")
    end
    local answer = read()
    if answer == nil or answer == "" then return default end
    return answer
end

local function confirm(question)
    write(question .. " [y/N] ")
    return tostring(read() or ""):lower():sub(1, 1) == "y"
end

local function chooseProfile()
    print("What is this computer?")
    print("")
    for index, profile in ipairs(identity.PROFILES) do
        print(("  %d) %-14s %s"):format(index, profile.label, profile.description))
    end
    print("")

    while true do
        local answer = ask("Number:", "1")
        local index = tonumber(answer)
        if index and identity.PROFILES[index] then
            return identity.PROFILES[index]
        end
        printError("Pick a number between 1 and " .. #identity.PROFILES .. ".")
    end
end

--- A display exists to show one thing; ask which.
local function chooseView(previous)
    print("")
    print("What should this display show?")
    print("")
    for index, view in ipairs(identity.VIEWS) do
        print(("  %d) %-10s %s"):format(index, view.title, view.description))
    end
    print("")

    local default = "1"
    for index, view in ipairs(identity.VIEWS) do
        if previous and previous.view and previous.view.id == view.id then
            default = tostring(index)
        end
    end

    while true do
        local answer = ask("Number:", default)
        local index = tonumber(answer)
        if index and identity.VIEWS[index] then
            return identity.VIEWS[index]
        end
        printError("Pick a number between 1 and " .. #identity.VIEWS .. ".")
    end
end

--- A node name has to be unique on the rednet: it is how the master addresses
--- it, so default to something already unique rather than the profile name.
local function defaultName(profile)
    local label = os.getComputerLabel()
    if label and label ~= "" then
        local cleaned = identity.cleanName(label)
        if cleaned ~= "" then return cleaned end
    end
    return profile.id .. "_" .. os.getComputerID()
end

--- Ask until the answer is a name the rest of BaseOS can actually carry.
-- The computer id is in the default, so two nodes only collide if somebody
-- types the same name into both on purpose.
local function askName(default)
    while true do
        local answer = ask("Name for this computer:", default)
        local ok, reason = identity.validateName(answer)
        if ok then return (answer:gsub("^%s+", ""):gsub("%s+$", "")) end

        printError(reason)
        local suggestion = identity.cleanName(answer)
        if suggestion ~= "" and suggestion ~= answer then
            print("Try '" .. suggestion .. "'.")
            default = suggestion
        end
    end
end

--- Config written for a previous role is usually wrong for the new one.
local function handlePreviousConfig(previous, profile)
    if not previous or previous.profile == profile.id then return end

    print("")
    print("This computer was set up as: " .. tostring(previous.profile or previous.role))
    print("Its config/ may not suit a " .. profile.label .. ".")
    print("")

    if confirm("Delete config/ so the new role starts from defaults?") then
        if fs.exists("config") then
            local kept = 0
            for _, name in ipairs(fs.list("config")) do
                local path = fs.combine("config", name)
                fs.delete(path)
                kept = kept + 1
            end
            print("Removed " .. kept .. " config file(s); defaults will be used.")
            print("Run 'updater force' to restore the shipped defaults.")
        end
    else
        print("Keeping the existing config/.")
    end
end

---------------------------------------------------------------------------

local function main(args)
    local command = args[1]
    local previous = identity.load()

    if command == "show" then
        if not previous then
            print("This computer has no identity yet. Run 'setup'.")
            return
        end
        print("BaseOS identity")
        describe(previous)
        return
    end

    print("BaseOS setup")
    print("")

    if previous then
        print("Current identity:")
        describe(previous)
        print("")
        if not confirm("Change it?") then
            print("Unchanged.")
            return
        end
        print("")
    end

    local profile
    if command then
        profile = identity.profile(command)
        if not profile then
            printError("Unknown profile '" .. command .. "'.")
            print("Known: ")
            for _, candidate in ipairs(identity.PROFILES) do
                print("  " .. candidate.id)
            end
            return
        end
    else
        profile = chooseProfile()
    end

    local view = profile.role == "display" and chooseView(previous) or nil

    print("")
    local name = askName(previous and previous.name or defaultName(profile))

    handlePreviousConfig(previous, profile)

    local record = {
        role = profile.role,
        profile = profile.id,
        name = name,
        modules = profile.modules and { table.unpack(profile.modules) } or nil,
        view = view,
        createdAt = previous and previous.createdAt or nil,
    }

    local ok, err = identity.save(record)
    if not ok then
        printError("Could not save the identity: " .. tostring(err))
        return
    end

    -- The label is what rednet advertises, so keep the two in step.
    pcall(os.setComputerLabel, name)

    print("")
    print("Saved.")
    describe(record)
    print("")
    if profile.role == "node" then
        print("Nodes need a modem to reach the master. Attach a wireless modem,")
        print("or a wired modem plus cable, then reboot.")
    end
    print("")
    if confirm("Reboot now?") then os.reboot() end
end

main({ ... })

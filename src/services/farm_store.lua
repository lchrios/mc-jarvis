--- The farms this computer runs, and where they come from.
--
-- A farm is a `farm` template instance: an id, a name and a table of settings.
-- They started life in `config/modules.lua`, which is fine for the person who
-- wrote the file and no use at all standing in front of a monitor with a new
-- spawner in hand. This owns the same list so the panel can edit it.
--
--   config/modules.lua  ->  the farms you wrote by hand
--   data/farms.dat      ->  the farms the editor owns, once it has been used
--
-- Same rule as the rule engine: the moment the editor saves, the stored list is
-- the whole truth. It is seeded from config, so the first save keeps whatever
-- was there instead of silently dropping it, and `resetToConfig` throws the
-- override away and goes back to the file.

local util = require("core.util")
local logger = require("core.logger")
local bus = require("core.event_bus")
local persistence = require("services.persistence")

local log = logger.scoped("farms")

local farms = {}

farms.STORE = "farms"
farms.TEMPLATE = "farm"

local context = nil

function farms.setContext(ctx) context = ctx end

---------------------------------------------------------------------------
-- The list
---------------------------------------------------------------------------

--- Farm instances written by hand in config/modules.lua.
function farms.fromConfig()
    local instances = (context and context.config.get("modules.instances", {})) or {}
    local list = {}
    for _, instance in ipairs(instances) do
        if type(instance) == "table" and instance.template == farms.TEMPLATE then
            list[#list + 1] = util.deepCopy(instance)
        end
    end
    return list
end

--- Everything in config/modules.lua that is *not* a farm, which the loader
--- still has to be given: this service only owns the farms.
function farms.otherInstances()
    local instances = (context and context.config.get("modules.instances", {})) or {}
    local list = {}
    for _, instance in ipairs(instances) do
        if type(instance) ~= "table" or instance.template ~= farms.TEMPLATE then
            list[#list + 1] = util.deepCopy(instance)
        end
    end
    return list
end

--- The farms in force, and where they came from ("editor" | "config").
function farms.current()
    local override = persistence.load(farms.STORE, nil)
    if type(override) == "table" and type(override.farms) == "table" then
        return util.deepCopy(override.farms), "editor"
    end
    return farms.fromConfig(), "config"
end

function farms.hasOverride()
    local _, source = farms.current()
    return source == "editor"
end

function farms.get(id)
    for _, farm in ipairs(farms.current()) do
        if farm.id == id then return farm end
    end
    return nil
end

--- An id that is free, derived from what the farm is called.
function farms.idFor(name, ignoreId)
    local base = tostring(name or "farm"):lower():gsub("%s+", "_"):gsub("[^%w_]", "")
    if base == "" then base = "farm" end

    local taken = {}
    for _, farm in ipairs(farms.current()) do
        if farm.id ~= ignoreId then taken[farm.id] = true end
    end
    -- Not only against other farms: an id already belongs to a module if any
    -- module answers to it, and registering over it would replace that module.
    if context and context.modules.has(base) and base ~= ignoreId then taken[base] = true end

    if not taken[base] then return base end
    local index = 2
    while taken[base .. index] do index = index + 1 end
    return base .. index
end

---------------------------------------------------------------------------
-- Saving
---------------------------------------------------------------------------

--- Persist the list and rebuild the running farms from it.
function farms.save(list)
    if type(list) ~= "table" then return false, "a farm list is required" end

    local ok, err = persistence.save(farms.STORE, {
        savedAt = util.nowMs(),
        farms = list,
    })
    if not ok then return false, err end

    log.info("saved %d farm(s) from the editor", #list)
    local count = farms.reload()
    bus.emit("farms.changed", { count = #list })
    return true, nil, count
end

function farms.remove(id)
    local list = farms.current()
    for index = #list, 1, -1 do
        if list[index].id == id then table.remove(list, index) end
    end
    return farms.save(list)
end

--- Add or replace one farm, leaving the rest alone.
function farms.put(farm)
    if type(farm) ~= "table" or type(farm.id) ~= "string" then
        return false, "a farm needs an id"
    end
    farm.template = farms.TEMPLATE

    local list = farms.current()
    for index, existing in ipairs(list) do
        if existing.id == farm.id then
            list[index] = farm
            return farms.save(list)
        end
    end

    list[#list + 1] = farm
    return farms.save(list)
end

function farms.resetToConfig()
    persistence.delete(farms.STORE)
    local count = farms.reload()
    bus.emit("farms.changed", { reset = true })
    return true, nil, count
end

---------------------------------------------------------------------------
-- Applying
---------------------------------------------------------------------------

--- Rebuild every farm module from the current list, without a reboot.
--
-- Unregister then load, rather than patching the running module: a farm's
-- peripheral requirements and its poll interval are decided when the template
-- builds it, so an edited output container has to go through `create` again to
-- take effect. `unregister` stops the module and cancels its timers, so the
-- old one leaves nothing behind.
function farms.reload()
    if not context then return 0 end

    for _, id in ipairs(context.modules.ids()) do
        local record = context.modules.get(id)
        if record and record.def.template == farms.TEMPLATE then
            context.modules.unregister(id)
        end
    end

    local loaded = context.modules.load(farms.current(), context.require)
    for _, id in ipairs(loaded) do context.modules.setup(id) end

    log.info("%d farm(s) running", #loaded)
    return #loaded
end

return farms

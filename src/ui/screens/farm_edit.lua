--- Build a farm by touching, not by editing config/modules.lua.
--
-- A farm is six decisions - where the output lands, what switches it on, what
-- counts as a drop, when it is backed up, when it is idle, and which spawner
-- it is - and every one of them is a choice from what is actually connected
-- rather than a name that has to be spelled correctly.
--
-- The spawner field is why this exists. A custom spawner is a farm somebody
-- built by hand, so its output container, its control side and the drop worth
-- counting are all different from the last one, and none of that is knowable
-- when the config file is written.

local class = require("core.class")
local util = require("core.util")
local Screen = require("ui.screen")
local Label = require("ui.components.label")
local Button = require("ui.components.button")
local Panel = require("ui.components.panel")
local Modal = require("ui.components.modal")
local farmStore = require("services.farm_store")
local manager = require("peripherals.manager")
local registry = require("modules.registry")

local FarmEdit = class(Screen)

local CONTROLS_HEIGHT = 5
local SIDES = { "back", "front", "left", "right", "top", "bottom" }
local BUFFER_LEVELS = { 0.70, 0.80, 0.90, 0.95 }
local IDLE_SECONDS = { 30, 60, 90, 300, 900 }

function FarmEdit:init(params)
    Screen.init(self, params)
    self.farmId = params.farmId

    -- A working copy: nothing is stored until SAVE.
    local existing = self.farmId and farmStore.get(self.farmId) or nil
    self.creating = existing == nil

    self.draft = existing and util.deepCopy(existing) or {
        id = nil,
        template = farmStore.TEMPLATE,
        name = "New farm",
        icon = "F",
        settings = {
            output = { method = "list" },
            control = { kind = "none", side = "back" },
            bufferWarn = 0.90,
            bufferClear = 0.75,
            idleAfter = 90,
        },
    }
    self.draft.settings = self.draft.settings or {}
    self.title = self.creating and "New farm" or (self.draft.name or self.farmId)
    self.edited = self.creating
end

function FarmEdit:settings() return self.draft.settings end

---------------------------------------------------------------------------
-- What is connected
---------------------------------------------------------------------------

local function devicesWith(method)
    local names = {}
    for _, name in ipairs(manager.names()) do
        local proxy = manager.getByName(name)
        if proxy and proxy.hasMethod(method) then names[#names + 1] = name end
    end
    return names
end

local function devicesOfType(...)
    local wanted = {}
    for _, kind in ipairs({ ... }) do wanted[kind] = true end

    local names = {}
    for _, name in ipairs(manager.names()) do
        local proxy = manager.getByName(name)
        for _, kind in ipairs((proxy and proxy.types()) or {}) do
            if wanted[kind] then
                names[#names + 1] = name
                break
            end
        end
    end
    return names
end

function FarmEdit:choose(title, items, onPick, hint)
    self.context.navigation.push("chooser", {
        title = title, items = items, onPick = onPick, hint = hint,
        emptyText = "Nothing connected that fits. 'DEVICES' shows what is.",
    })
end

function FarmEdit:touch()
    self.edited = true
    self:requestLayout()
end

function FarmEdit:say(message)
    self.message = message
    self:invalidate()
end

---------------------------------------------------------------------------
-- Field descriptions
---------------------------------------------------------------------------

local function describeOutput(output)
    if type(output) ~= "table" then return "(not set)" end
    if output.name then return output.name end
    if output.type then return "any " .. output.type end
    return "any container (first one found)"
end

local function describeControl(control)
    if type(control) ~= "table" or control.kind == "none" then
        return "(monitor only, cannot start or stop it)"
    end
    local text
    if control.kind == "integrator" then
        text = "Redstone Integrator, " .. tostring(control.side)
    else
        text = "computer redstone, " .. tostring(control.side)
    end
    if control.invert then text = text .. "  (runs when off)" end
    return text
end

local function describeCounted(countItems)
    if not countItems or #countItems == 0 then return "everything that lands in it" end
    if #countItems == 1 then return countItems[1] end
    return #countItems .. " items: " .. table.concat(countItems, ", ")
end

local function describeSpawner(spawner)
    if type(spawner) ~= "table" then return "(none)" end
    if spawner.match and spawner.match.name then return spawner.match.name end
    return "any block reader"
end

---------------------------------------------------------------------------
-- Editing each field
---------------------------------------------------------------------------

function FarmEdit:editName()
    self.context.navigation.push("name_entry", {
        title = "Farm name",
        prompt = "What is this farm called?",
        value = self.draft.name,
        onDone = function(text)
            if text and text ~= "" then
                self.draft.name = text
                self.title = text
                self:touch()
            end
        end,
    })
end

function FarmEdit:editOutput()
    local items = { { id = "@any", label = "any container",
                      note = "the first one found" } }
    for _, name in ipairs(devicesWith("list")) do
        items[#items + 1] = { id = name, label = name }
    end

    self:choose("Output container", items, function(item)
        if item.id == "@any" then
            self:settings().output = { method = "list" }
        else
            self:settings().output = { name = item.id }
        end
        self:touch()
    end, "Where the farm's drops land")
end

function FarmEdit:editControl()
    local items = {
        { id = "none", label = "monitor only", note = "no start/stop" },
        { id = "redstone", label = "computer redstone" },
        { id = "integrator", label = "Redstone Integrator" },
    }

    self:choose("How it switches", items, function(kind)
        if kind.id == "none" then
            self:settings().control = { kind = "none" }
            return self:touch()
        end

        local sides = {}
        for _, side in ipairs(SIDES) do sides[#sides + 1] = { id = side, label = side } end

        self:choose("Which side", sides, function(side)
            local control = { kind = kind.id, side = side.id,
                              invert = self:settings().control and self:settings().control.invert }

            if kind.id == "integrator" then
                local readers = devicesOfType("redstone_integrator", "redstoneIntegrator")
                if #readers == 0 then
                    self:settings().control = control
                    self:touch()
                    return self:say("No Redstone Integrator connected; saved anyway.")
                end

                local items2 = {}
                for _, name in ipairs(readers) do
                    items2[#items2 + 1] = { id = name, label = name }
                end
                return self:choose("Which integrator", items2, function(device)
                    control.match = { name = device.id }
                    self:settings().control = control
                    self:touch()
                end)
            end

            self:settings().control = control
            self:touch()
        end, "The face the signal comes out of")
    end)
end

--- Toggle one item in the counted list, chosen from what is in the buffer now.
function FarmEdit:editCounted()
    local counted = self:settings().countItems or {}
    local chosen = {}
    for _, name in ipairs(counted) do chosen[name] = true end

    local items = { { id = "@all", label = "count everything",
                      note = #counted == 0 and "current" or "" } }

    -- The buffer's own contents: the only list of item names that is certain
    -- to be spelled the way this pack spells them.
    local snapshot = self.farmId and registry.snapshot(self.farmId) or nil
    local seen = {}
    for _, row in ipairs((snapshot and snapshot.detail and snapshot.detail.rows) or {}) do
        seen[row.id] = true
        items[#items + 1] = {
            id = row.id,
            label = row.name,
            note = chosen[row.id] and "counted" or "",
        }
    end
    -- Anything already counted that is not in the buffer right now, so it can
    -- still be removed when the farm has drained.
    for _, name in ipairs(counted) do
        if not seen[name] then
            items[#items + 1] = { id = name, label = name, note = "counted" }
        end
    end

    self:choose("Count as output", items, function(item)
        if item.id == "@all" then
            self:settings().countItems = nil
            return self:touch()
        end

        local list = {}
        local removed = false
        for _, name in ipairs(counted) do
            if name == item.id then removed = true else list[#list + 1] = name end
        end
        if not removed then list[#list + 1] = item.id end

        self:settings().countItems = #list > 0 and list or nil
        self:touch()
    end, "Touch to add or remove; the rate counts only these")
end

function FarmEdit:editBuffer()
    local items = {}
    for _, level in ipairs(BUFFER_LEVELS) do
        items[#items + 1] = {
            id = tostring(level),
            label = util.formatPercent(level) .. " full",
            note = self:settings().bufferWarn == level and "current" or "",
        }
    end

    self:choose("Backed up at", items, function(item)
        local level = tonumber(item.id) or 0.9
        self:settings().bufferWarn = level
        -- Hysteresis, never equal: a buffer sitting on the line would flap.
        self:settings().bufferClear = math.max(0.1, level - 0.15)
        self:touch()
    end, "When to raise the buffer alert")
end

function FarmEdit:editIdle()
    local items = { { id = "off", label = "do not warn when idle" } }
    for _, seconds in ipairs(IDLE_SECONDS) do
        items[#items + 1] = {
            id = tostring(seconds),
            label = "no output for " .. util.formatDuration(seconds),
            note = self:settings().idleAfter == seconds
                and self:settings().alertWhenIdle and "current" or "",
        }
    end

    self:choose("Idle", items, function(item)
        if item.id == "off" then
            self:settings().alertWhenIdle = false
        else
            self:settings().idleAfter = tonumber(item.id) or 90
            self:settings().alertWhenIdle = true
        end
        self:touch()
    end)
end

function FarmEdit:editSpawner()
    local items = { { id = "@none", label = "no spawner",
                      note = self:settings().spawner and "" or "current" } }
    for _, name in ipairs(devicesOfType("block_reader", "blockReader")) do
        items[#items + 1] = { id = name, label = name, note = "block reader" }
    end

    self:choose("Spawner", items, function(item)
        if item.id == "@none" then
            self:settings().spawner = nil
        else
            self:settings().spawner = { match = { name = item.id } }
        end
        self:touch()
    end, "A Block Reader facing the spawner tells you what it holds")
end

function FarmEdit:fields()
    local settings = self:settings()
    return {
        { label = "NAME", value = self.draft.name or "(unnamed)",
          edit = function() self:editName() end },
        { label = "OUTPUT", value = describeOutput(settings.output),
          edit = function() self:editOutput() end },
        { label = "SWITCH", value = describeControl(settings.control),
          edit = function() self:editControl() end },
        { label = "COUNT", value = describeCounted(settings.countItems),
          edit = function() self:editCounted() end },
        { label = "FULL", value = util.formatPercent(settings.bufferWarn or 0.9)
            .. " raises the backed up alert",
          edit = function() self:editBuffer() end },
        { label = "IDLE", value = settings.alertWhenIdle
            and ("warn after " .. util.formatDuration(settings.idleAfter or 90))
            or "(no idle warning)",
          edit = function() self:editIdle() end },
        { label = "SPAWNER", value = describeSpawner(settings.spawner),
          edit = function() self:editSpawner() end },
    }
end

---------------------------------------------------------------------------
-- Save, delete, leave
---------------------------------------------------------------------------

function FarmEdit:save()
    if not self.draft.name or self.draft.name == "" then
        return self:say("Give it a name first.")
    end

    self.draft.id = self.draft.id or farmStore.idFor(self.draft.name)
    self.draft.template = farmStore.TEMPLATE

    local ok, err = farmStore.put(self.draft)
    if not ok then return self:say("Could not save: " .. tostring(err)) end

    self.farmId = self.draft.id
    self.creating = false
    self.edited = false
    self.context.navigation.back()
end

function FarmEdit:remove()
    if self.creating then return self.context.navigation.back() end

    self:openModal(Modal.new({
        title = "Delete this farm?",
        message = (self.draft.name or self.farmId)
            .. " stops being monitored. The machines keep running.",
        buttons = {
            { label = "CANCEL" },
            { label = "DELETE", style = "danger", onPress = function()
                farmStore.remove(self.farmId)
                -- Two screens: this one and the detail of a farm that is gone.
                self.context.navigation.back()
                self.context.navigation.back()
            end },
        },
        onClose = function() self:closeModal() end,
    }))
end

function FarmEdit:exit()
    if not self.edited then return self.context.navigation.back() end

    self:openModal(Modal.new({
        title = "Discard changes?",
        message = "This farm has unsaved edits.",
        buttons = {
            { label = "KEEP EDITING" },
            { label = "DISCARD", style = "danger",
              onPress = function() self.context.navigation.back() end },
        },
        onClose = function() self:closeModal() end,
    }))
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------

function FarmEdit:onLayout(x, y, w, h)
    local fields = self:fields()

    local bodyHeight = h - CONTROLS_HEIGHT
    local panel = Panel.new({ title = self.draft.name or "New farm", bg = "background" })
    panel:setBounds(x, y, w, math.max(3, bodyHeight))
    self:add(panel)

    local cx, cy, cw = panel:contentBounds()
    local row = cy

    if self.message then
        local note = Label.new({ text = util.truncate(self.message, cw), fg = "statusWarn" })
        note:setBounds(cx, row, cw, 1)
        self:add(note)
        row = row + 1
        self.message = nil
    end

    for _, field in ipairs(fields) do
        if row >= cy + bodyHeight - 2 then break end

        local hotspot = Panel.new({
            border = false, fill = false,
            onTouch = function() field.edit() return true end,
        })
        hotspot:setBounds(cx, row, cw, 1)
        self:add(hotspot)

        local label = Label.new({ text = field.label, fg = "accent" })
        label:setBounds(cx, row, 8, 1)
        hotspot:add(label)

        local value = Label.new({
            text = util.truncate(field.value, cw - 9),
            fg = field.value:find("^%(") and "textDim" or "text",
        })
        value:setBounds(cx + 9, row, cw - 9, 1)
        hotspot:add(value)

        row = row + 1
    end

    local controlsY = y + h - CONTROLS_HEIGHT + 1
    local hint = Label.new({
        text = util.truncate("Touch a field to change it", w),
        fg = "textDim",
    })
    hint:setBounds(x, controlsY - 1, w, 1)
    self:add(hint)

    local actions = {
        { label = "SAVE", style = "primary", run = function() self:save() end },
        { label = self.creating and "CANCEL" or "DELETE", style = "danger",
          run = function() self:remove() end },
        { label = "BACK", run = function() self:exit() end },
    }

    local slots = self.context.navigation.getRenderer():distribute(x, w, #actions, 1)
    for index, action in ipairs(actions) do
        local button = Button.new({
            label = action.label,
            style = action.style,
            bracket = false,
            onPress = action.run,
        })
        button:setBounds(slots[index].offset, controlsY, slots[index].size,
            CONTROLS_HEIGHT - 1)
        self:add(button)
    end
end

return FarmEdit

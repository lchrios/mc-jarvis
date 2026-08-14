--- Draw the base plan from the monitor, without opening a file.
--
--   left    every module this base knows about, marked when already placed
--   right   a live preview of the plan; touch a zone to select it
--   bottom  a mode (MOVE / SIZE / LINK) plus four arrows, and the actions
--
-- One mode with four arrows beats twenty buttons: the touch targets stay big
-- enough for a 3x2 monitor.
--
-- Edits go to `data/layout.dat` through `services.layout_store`, so
-- `config/layout.lua` and its comments are never rewritten. Nothing is saved
-- until SAVE: EXIT throws the working copy away.

local class = require("core.class")
local util = require("core.util")
local Screen = require("ui.screen")
local Label = require("ui.components.label")
local Button = require("ui.components.button")
local Panel = require("ui.components.panel")
local List = require("ui.components.list")
local Modal = require("ui.components.modal")
local baseLayout = require("ui.base_layout")
local registry = require("modules.registry")
local layoutStore = require("services.layout_store")
local theme = require("ui.theme")

local LayoutEditor = class(Screen)

local MODES = { "MOVE", "SIZE", "LINK" }
local LIST_WIDTH = 18

-- One status line, then the D-pad: up on its own row, left/down/right under it.
-- Laid out as a cross because that is what the hand expects from four
-- direction keys - in a row they all look alike and you have to read them.
local CONTROLS_HEIGHT = 6
local ARROW_W, ARROW_H = 5, 2

function LayoutEditor:init(params)
    Screen.init(self, params)
    self.title = "Edit layout"

    -- A working copy: nothing on disk changes until SAVE. Named `plan`, not
    -- `layout`: Screen:layout() is a method, and `edited` rather than `dirty`,
    -- which Screen uses for its repaint flag.
    self.plan = util.deepCopy(layoutStore.current())
    self.plan.zones = self.plan.zones or {}
    self.plan.source = nil

    self.modeIndex = 1
    self.selectedZone = nil     -- zone id
    self.selectedModule = nil   -- module id highlighted in the list
    self.linkFrom = nil         -- first end while linking
    self.edited = false
end

function LayoutEditor:mode() return MODES[self.modeIndex] end

---------------------------------------------------------------------------
-- Model helpers
---------------------------------------------------------------------------

function LayoutEditor:zone(id)
    for _, zone in ipairs(self.plan.zones) do
        if zone.id == id then return zone end
    end
    return nil
end

function LayoutEditor:zoneForModule(moduleId)
    for _, zone in ipairs(self.plan.zones) do
        if zone.module == moduleId then return zone end
    end
    return nil
end

--- Left-hand list: every module, whether or not it is on the plan.
function LayoutEditor:moduleRows()
    local placed = layoutStore.placedModules(self.plan)
    local rows = {}
    for _, record in ipairs(registry.all()) do
        rows[#rows + 1] = {
            id = record.id,
            name = record.name,
            placed = placed[record.id] == true,
        }
    end
    return rows
end

function LayoutEditor:select(zoneId)
    self.selectedZone = zoneId
    local zone = zoneId and self:zone(zoneId)
    self.selectedModule = zone and zone.module or self.selectedModule
    self:requestLayout()
end

---------------------------------------------------------------------------
-- Editing
---------------------------------------------------------------------------

--- Move or resize the selected zone, clamped to the grid.
function LayoutEditor:nudge(dx, dy)
    local zone = self.selectedZone and self:zone(self.selectedZone)
    if not zone then return end

    local columns, rows = layoutStore.grid(self.plan)
    zone.col = zone.col or 1
    zone.row = zone.row or 1
    zone.colSpan = zone.colSpan or 1
    zone.rowSpan = zone.rowSpan or 1

    if self:mode() == "SIZE" then
        zone.colSpan = util.clamp(zone.colSpan + dx, 1, columns - zone.col + 1)
        zone.rowSpan = util.clamp(zone.rowSpan + dy, 1, rows - zone.row + 1)
    else
        zone.col = util.clamp(zone.col + dx, 1, columns - zone.colSpan + 1)
        zone.row = util.clamp(zone.row + dy, 1, rows - zone.rowSpan + 1)
    end

    self.edited = true
    self:requestLayout()
end

--- Put the highlighted module on the plan.
function LayoutEditor:addZone()
    local moduleId = self.selectedModule
    if not moduleId then return self:say("Pick a module on the left first.") end
    if self:zoneForModule(moduleId) then return self:say("That module is already on the plan.") end

    local col, row = layoutStore.freeSlot(self.plan, 4, 3)
    if not col then return self:say("No room left on the grid. Shrink a zone first.") end

    local record = registry.get(moduleId)
    local zone = {
        id = moduleId,
        label = (record and record.name or moduleId):upper(),
        module = moduleId,
        col = col, row = row, colSpan = 4, rowSpan = 3,
    }
    self.plan.zones[#self.plan.zones + 1] = zone

    self.edited = true
    self:select(zone.id)
end

function LayoutEditor:removeZone()
    if not self.selectedZone then return self:say("Nothing selected.") end

    for index, zone in ipairs(self.plan.zones) do
        if zone.id == self.selectedZone then
            table.remove(self.plan.zones, index)
            break
        end
    end

    -- Links pointing at it would dangle.
    for _, zone in ipairs(self.plan.zones) do
        for linkIndex = #(zone.links or {}), 1, -1 do
            local link = zone.links[linkIndex]
            local target = type(link) == "table" and link.to or link
            if target == self.selectedZone then table.remove(zone.links, linkIndex) end
        end
    end

    self.selectedZone = nil
    self.edited = true
    self:requestLayout()
end

--- Create or remove the pipe between the two zones picked in LINK mode.
function LayoutEditor:toggleLink(fromId, toId)
    if fromId == toId then return end

    local from, to = self:zone(fromId), self:zone(toId)
    if not from or not to then return end

    local function findLink(zone, targetId)
        for index, link in ipairs(zone.links or {}) do
            local target = type(link) == "table" and link.to or link
            if target == targetId then return index end
        end
        return nil
    end

    -- Declared from either end, it is the same pipe.
    local existing = findLink(from, toId)
    if existing then
        table.remove(from.links, existing)
        self:say("Link removed.")
    else
        local reverse = findLink(to, fromId)
        if reverse then
            table.remove(to.links, reverse)
            self:say("Link removed.")
        else
            from.links = from.links or {}
            from.links[#from.links + 1] = { to = toId }
            self:say("Linked " .. fromId .. " -> " .. toId)
        end
    end

    self.edited = true
    self:requestLayout()
end

function LayoutEditor:say(message)
    self.message = message
    self:invalidate()
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

function LayoutEditor:save()
    local ok, err = layoutStore.save(self.plan)
    if not ok then return self:say("Could not save: " .. tostring(err)) end
    self.edited = false
    self.context.navigation.back()
end

function LayoutEditor:exit()
    if not self.edited then return self.context.navigation.back() end

    self:openModal(Modal.new({
        title = "Discard changes?",
        message = "The plan has unsaved edits.",
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

function LayoutEditor:buildPreview(x, y, w, h)
    local placements = baseLayout.resolve(self.plan, { x = x, y = y, w = w, h = h }, {})

    for _, placement in ipairs(placements) do
        local zone = placement.zone
        local isSelected = zone.id == self.selectedZone
        local isLinkSource = zone.id == self.linkFrom

        local panel = Panel.new({
            title = util.truncate(zone.label or zone.id, math.max(3, placement.w - 4)),
            border = true,
            bg = isSelected and "accent" or "surface",
            fg = isLinkSource and theme.get("statusWarn")
                or (isSelected and theme.get("accentText") or "border"),
            titleFg = isSelected and "textInverse" or "text",
            onTouch = function()
                if self:mode() == "LINK" then
                    if not self.linkFrom then
                        self.linkFrom = zone.id
                        self:say("Now touch the other end.")
                        self:requestLayout()
                    else
                        local from = self.linkFrom
                        self.linkFrom = nil
                        self:toggleLink(from, zone.id)
                    end
                else
                    self:select(zone.id)
                end
                return true
            end,
        })
        panel:setBounds(placement.x, placement.y, placement.w, placement.h)
        self:add(panel)

        -- A marker for each pipe leaving this zone, since the preview is too
        -- small to route them properly.
        if zone.links and #zone.links > 0 and placement.h >= 3 then
            local label = Label.new({
                text = util.truncate(theme.chars.linkHorizontal .. tostring(#zone.links),
                    placement.w - 2),
                fg = "statusOk",
            })
            label:setBounds(placement.x + 1, placement.y + placement.h - 2, placement.w - 2, 1)
            self:add(label)
        end
    end
end

function LayoutEditor:onLayout(x, y, w, h)
    local bodyHeight = h - CONTROLS_HEIGHT
    if bodyHeight < 4 then bodyHeight = h end

    ---------------------------------------------------------------- list
    local listWidth = math.min(LIST_WIDTH, math.floor(w / 3))

    local header = Label.new({ text = "MODULES", fg = "textDim" })
    header:setBounds(x, y, listWidth, 1)
    self:add(header)

    self.list = List.new({
        items = self:moduleRows(),
        renderItem = function(row)
            return {
                text = (row.placed and "* " or "  ") .. util.truncate(row.name, listWidth - 2),
                fg = row.id == self.selectedModule and theme.get("accent")
                    or (row.placed and theme.get("text") or theme.get("textDim")),
            }
        end,
        emptyText = "No modules.",
        onSelect = function(row)
            self.selectedModule = row.id
            local zone = self:zoneForModule(row.id)
            self.selectedZone = zone and zone.id or nil
            self:say(zone and ("Selected " .. row.name)
                or (row.name .. " is not on the plan - press ADD."))
            self:requestLayout()
        end,
    })
    self.list:setBounds(x, y + 1, listWidth, math.max(1, bodyHeight - 1))
    self:add(self.list)

    ---------------------------------------------------------------- preview
    local previewX = x + listWidth + 1
    local previewWidth = w - listWidth - 1
    if previewWidth >= 10 and bodyHeight >= 4 then
        self:buildPreview(previewX, y, previewWidth, bodyHeight)
    end

    ---------------------------------------------------------------- controls
    local controlsY = y + h - CONTROLS_HEIGHT
    if controlsY <= y then return end

    local status = self.message
        or (self.selectedZone and ("Selected: " .. self.selectedZone)
            or "Pick a module on the left.")
    local statusLabel = Label.new({ text = util.truncate(status, w), fg = "textDim" })
    statusLabel:setBounds(x, controlsY, w, 1)
    self:add(statusLabel)

    -- Mode, then the D-pad. The pad occupies two rows: the up arrow sits over
    -- the down arrow, with left and right either side of it.
    local padX = x + 9
    local topRow = controlsY + 1
    local bottomRow = topRow + ARROW_H

    local modeButton = Button.new({
        label = self:mode(),
        style = "primary",
        bracket = false,
        onPress = function()
            self.modeIndex = (self.modeIndex % #MODES) + 1
            self.linkFrom = nil
            self:say(self:mode() == "LINK" and "Touch one zone, then the other."
                or ("Mode: " .. self:mode()))
            self:requestLayout()
        end,
    })
    -- Beside the pad rather than above it, so it reads as what the arrows do.
    modeButton:setBounds(x, bottomRow, 8, ARROW_H)
    self:add(modeButton)

    local movable = self.selectedZone ~= nil and self:mode() ~= "LINK"

    local arrows = {
        { label = theme.chars.arrowUp,    dx = 0,  dy = -1, col = 1, row = topRow },
        { label = theme.chars.arrowLeft,  dx = -1, dy = 0,  col = 0, row = bottomRow },
        { label = theme.chars.arrowDown,  dx = 0,  dy = 1,  col = 1, row = bottomRow },
        { label = theme.chars.arrowRight, dx = 1,  dy = 0,  col = 2, row = bottomRow },
    }
    for _, arrow in ipairs(arrows) do
        local button = Button.new({
            label = arrow.label,
            bracket = false,
            enabled = movable,
            onPress = function() self:nudge(arrow.dx, arrow.dy) end,
        })
        button:setBounds(padX + arrow.col * (ARROW_W + 1), arrow.row, ARROW_W, ARROW_H)
        self:add(button)
    end

    ---------------------------------------------------------------- actions
    -- Far side of the row, with a gutter: these change the plan, the arrows
    -- only move the selection, and hitting the wrong one by a column is the
    -- kind of mistake that costs you a zone.
    local actions = {
        { label = "ADD", run = function() self:addZone() end },
        { label = "DEL", style = "danger", run = function() self:removeZone() end },
        { label = "SAVE", style = "primary", run = function() self:save() end },
        { label = "EXIT", run = function() self:exit() end },
    }

    local padRight = padX + 3 * (ARROW_W + 1)
    local GUTTER = 4
    local actionsX = padRight + GUTTER
    local available = w - (actionsX - x)

    if available >= #actions * 6 then
        -- Room beside the pad: one row of four, level with the pad's centre.
        local slots = self.context.navigation.getRenderer()
            :distribute(actionsX, available, #actions, 1)
        for index, action in ipairs(actions) do
            local button = Button.new({
                label = action.label,
                style = action.style,
                bracket = false,
                onPress = action.run,
            })
            button:setBounds(slots[index].offset, topRow, slots[index].size, ARROW_H * 2)
            self:add(button)
        end
    else
        -- Narrow monitor: two by two, still clear of the pad.
        local columnWidth = math.max(6, math.floor((w - (actionsX - x)) / 2) - 1)
        for index, action in ipairs(actions) do
            local button = Button.new({
                label = action.label,
                style = action.style,
                bracket = false,
                onPress = action.run,
            })
            local column = (index - 1) % 2
            local row = math.floor((index - 1) / 2)
            button:setBounds(actionsX + column * (columnWidth + 1),
                topRow + row * ARROW_H, columnWidth, ARROW_H)
            self:add(button)
        end
    end
end

function LayoutEditor:update()
    if self.list then self.list:setItems(self:moduleRows()) end
end

return LayoutEditor

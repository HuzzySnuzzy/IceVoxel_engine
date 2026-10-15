--!strict
--[[
	The survival inventory's slots (Ui/InventoryScreen): every slot widget, its window slot, how it
	is drawn each frame and what is under a point. One set holds them all, each in a group (the
	section it is in: "craft", "container", "backpack", "equipment", "vanity", "band", "hands"),
	so the block's section can be rebuilt alone (`drop`).

	A widget is an ItemIcon.slot (the 18 x 18 transparent button, a face, the dayz icon, the hover
	outline) and its store and index (Inventory/Types' stores: container, armor, inventory,
	accessory, vanityArmor, vanityAccessory), with:

	  ghost   the slot's silhouette while it is empty (the worn strip's head, chest, legs, feet and
	          accessory; VANITY's fainter, with a small mark in its corner; a machine's upgrade
	          card outline), 14 x 14 at the item's (1, 1)
	  lock    a closed accessory slot (past the open ones: Config.Accessories.ExtraSlotAges): its
	          face shaded, a padlock on it, and it takes nothing ("Opens at the ...")
	  quick   the quickbar band's slots draw their face on the quickbar cell under them, the
	          selected hotbar slot's in the selected colour

	Rules every frame (`draw`, cheap: nothing is built, every write only on a change):

	  * Faces are painted here and only here (Style.Dayz.paintFace): "filled" over a stack,
	    "empty" otherwise, "selected" for the band's selected slot, "locked" for a closed slot.
	  * Outlines: the hovered slot's in the drag feedback colour while a stack is carried (Theme
	    .feedback: green fits, red blocked, blue swaps, orange combines), white otherwise; the
	    slots of a drag in progress white (Style.Dayz.setLit).
	  * A crafting result the recipe gate keeps back (a later Age's, a skill not unlocked) is drawn
	    greyed in the empty result slot (`lockedResult`), matched again only when a grid stack or
	    the progression changed; hovering it says what it needs (Ui/InventoryScreen.tooltipAt).
	  * Only live widgets take part: `assign` gives every widget its window slot for the window's
	    layout, or -1 (with its button hidden and not Selectable) while its section is collapsed or
	    absent, so `targetAt` and gamepad selection never reach it.

	Eyes (`eye`): buttons of their own that hide an armor piece's or an accessory's look (the
	inventory's `hide` action); over one, `targetAt` says nothing, so no slot click happens under
	it. They describe themselves when hovered (Ui/HoverTip, "inventory.eye").

	Silhouettes come from Ui/Silhouettes by name (Style.Dayz.silhouette: drawn once per name; a
	name it does not draw is an empty mask), and the eyes' art from Style.Dayz.Art.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Crafting = require(Shared.Crafting)
local Menu = require(Shared.Inventory.Menu)
local Types = require(Shared.Inventory.Types)

local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local ProgressionState = require(script.Parent.Parent.Player.ProgressionState)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local HoverTip = require(script.Parent.HoverTip)
local InventoryColumns = require(script.Parent.InventoryColumns)
local ItemIcon = require(script.Parent.ItemIcon)
local SlotClicks = require(script.Parent.SlotClicks)
local Style = require(script.Parent.Style)
local Theme = require(script.Parent.Theme)

type Window = Types.Window
type Target = SlotClicks.Target

local Dayz = Style.Dayz

local Size = Theme.Size
local Art = Dayz.Art

export type SlotWidget = {
	view: ItemIcon.Slot,
	store: string,
	-- Index in the store (container 1..n, armor 1..4, inventory 1..36, ...).
	index: number,
	-- Window slot, -1 while not live.
	window: number,
	group: string,
	-- The face painted: the slot's own, or the band's quickbar cell's.
	face: Frame,
	quick: boolean,
	ghost: GuiObject?,
	lock: GuiObject?,
	locked: boolean,
}

-- An eye toggling a look: its button, the open and shut art, the `hide` action's slot.
export type Eye = { button: TextButton, open: Frame, shut: Frame, slot: number, group: string, small: boolean }

export type SlotWidgets = {
	widgets: { SlotWidget },
	eyes: { Eye },
	slot: (
		self: SlotWidgets,
		parent: Instance,
		group: string,
		x: number,
		y: number,
		store: string,
		index: number,
		big: boolean?,
		scaled: Style.Scaled?
	) -> SlotWidget,
	ghost: (self: SlotWidgets, widget: SlotWidget, name: string, vanity: boolean) -> (),
	art: (self: SlotWidgets, widget: SlotWidget, rows: { string }) -> (),
	lock: (self: SlotWidgets, widget: SlotWidget) -> (),
	eye: (self: SlotWidgets, parent: Instance, group: string, slot: number) -> Eye,
	placeEye: (self: SlotWidgets, eye: Eye, rect: InventoryColumns.Rect) -> (),
	drop: (self: SlotWidgets, group: string) -> (),
	assign: (self: SlotWidgets, window: Window, live: { [string]: boolean }, inert: boolean?) -> (),
	draw: (
		self: SlotWidgets,
		window: Window,
		hover: Target?,
		dragged: { [number]: boolean },
		selected: number
	) -> (),
	setFeedback: (self: SlotWidgets, feedback: Theme.Feedback?) -> (),
	lockedResult: (self: SlotWidgets, window: Window) -> (number?, number, string?),
	isResult: (self: SlotWidgets, widget: SlotWidget, window: Window) -> boolean,
	widgetAt: (self: SlotWidgets, point: Vector2) -> SlotWidget?,
	eyeAt: (self: SlotWidgets, point: Vector2) -> Eye?,
	targetOf: (self: SlotWidgets, object: GuiObject) -> Target?,
	first: (self: SlotWidgets, group: string) -> SlotWidget?,
}

type Self = SlotWidgets & {
	byButton: { [GuiObject]: SlotWidget },
	feedback: Theme.Feedback?,
	hovered: SlotWidget?,
	shownHidden: number,
	shownOpen: number,
	-- The locked result's cache (see `lockedResult`).
	lockedGrid: { Types.Stack | false },
	lockedStatus: any,
	lockedItem: number?,
	lockedCount: number,
	lockedText: string?,
}

local SlotWidgets = {}
SlotWidgets.__index = SlotWidgets

--[[ Building ]]

function SlotWidgets.new(): SlotWidgets
	local self = {
		widgets = {},
		eyes = {},
		byButton = {},
		feedback = nil,
		hovered = nil,
		shownHidden = -1,
		shownOpen = -1,
		lockedGrid = {},
		lockedStatus = nil,
		lockedItem = nil,
		lockedCount = 0,
		lockedText = nil,
	}
	return (setmetatable(self, SlotWidgets) :: any) :: SlotWidgets
end

-- A slot for the item at (x, y) of `parent` (its 18 x 18 button one pixel up and left).
function SlotWidgets.slot(
	self: Self,
	parent: Instance,
	group: string,
	x: number,
	y: number,
	store: string,
	index: number,
	big: boolean?,
	scaled: Style.Scaled?
): SlotWidget
	local view = ItemIcon.slot(parent, x, y, nil, big, scaled)
	view.button.Selectable = false
	local widget: SlotWidget = {
		view = view,
		store = store,
		index = index,
		window = -1,
		group = group,
		face = view.face,
		quick = false,
		ghost = nil,
		lock = nil,
		locked = false,
	}
	table.insert(self.widgets, widget)
	self.byButton[view.button] = widget
	return widget
end

-- Gives a worn slot its silhouette `name` (Ui/Silhouettes), shown while it is empty; VANITY's are
-- fainter and marked in the corner.
function SlotWidgets.ghost(_self: Self, widget: SlotWidget, name: string, vanity: boolean)
	local key = if vanity then "GhostVanity" else "Ghost"
	local holder = Instance.new("Frame")
	holder.Name = "Ghost"
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.Size = UDim2.fromScale(1, 1)
	holder.ZIndex = 3
	holder.Parent = widget.view.button
	Dayz.silhouette(
		holder,
		name,
		Size.GHOST_AT,
		Size.GHOST_AT,
		Size.GHOST,
		Size.GHOST,
		Dayz.Colour[key],
		Dayz.Alpha[key],
		1
	)
	if vanity then
		local mark = Style.frame(holder, 1, 1, Size.GHOST_MARK, Size.GHOST_MARK, Dayz.Colour.GhostMark, 2)
		mark.BackgroundTransparency = Dayz.Alpha.GhostMark
	end
	widget.ghost = holder
end

-- Gives a slot a ghost drawn from 16 x 16 rows (MenuLayout's machine upgrade cards: "G" pixels).
function SlotWidgets.art(_self: Self, widget: SlotWidget, rows: { string })
	local holder = Instance.new("Frame")
	holder.Name = "Ghost"
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.Size = UDim2.fromScale(1, 1)
	holder.ZIndex = 3
	holder.Parent = widget.view.button
	Dayz.glyph(holder, 1, 1, rows, Dayz.Colour.Ghost, 1, Dayz.Alpha.Ghost)
	widget.ghost = holder
end

-- Gives an accessory slot its padlock (shown, and the slot locked, past the open accessory slots).
function SlotWidgets.lock(_self: Self, widget: SlotWidget)
	local holder = Instance.new("Frame")
	holder.Name = "Lock"
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.Size = UDim2.fromScale(1, 1)
	holder.ZIndex = 11
	holder.Visible = false
	holder.Parent = widget.view.button
	Dayz.silhouette(
		holder,
		"padlock",
		Size.LOCK_AT,
		Size.LOCK_AT,
		Size.LOCK,
		Size.LOCK,
		Dayz.Colour.Lock,
		Dayz.Alpha.Lock,
		1
	)
	widget.lock = holder
end

-- The eye's art in `button`, `small` (6 x 6) or not (9 x 9), centred.
local function eyeArt(button: TextButton, rows: { string }, colour: Color3, transparency: number): Frame
	local size = #rows
	local holder = Instance.new("Frame")
	holder.Name = "Art"
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromOffset(size, size)
	holder.ZIndex = 1
	holder.Parent = button
	Dayz.glyph(holder, 0, 0, rows, colour, 1, transparency)
	return holder
end

--[[
	An eye button in `parent` hiding the look of `slot` (Types `hidden`: an accessory row, or
	HIDE_ARMOR + an armor piece); placed with `placeEye`.
]]
function SlotWidgets.eye(self: Self, parent: Instance, group: string, slot: number): Eye
	local button = Instance.new("TextButton")
	button.Name = "Eye"
	button.Text = ""
	button.AutoButtonColor = false
	button.BackgroundTransparency = 1
	button.BorderSizePixel = 0
	button.ZIndex = 12
	button.SelectionImageObject = Style.selectionImage
	button.Parent = parent
	local shut = eyeArt(button, Art.smallEyeShut, Dayz.Colour.TextDisabled, Dayz.Alpha.TextDisabled)
	shut.Visible = false
	local eye: Eye = {
		button = button,
		open = eyeArt(button, Art.smallEye, Dayz.Colour.Text, 0),
		shut = shut,
		slot = slot,
		group = group,
		small = true,
	}
	-- (Its tooltip says what a click does now: hide or show, an armor piece or an accessory.)
	HoverTip.attach(button, "inventory.eye", function(): string?
		local what = if slot > Types.HIDE_ARMOR then "Armor" else "Accessory"
		return if eye.shut.Visible then `show{what}` else `hide{what}`
	end)
	button.Activated:Connect(function()
		local hidden = not eye.shut.Visible
		SoundPlayer.click()
		ClientInventory.apply({ kind = "hide", slot = slot, hidden = hidden })
	end)
	table.insert(self.eyes, eye)
	self.shownHidden = -1
	return eye
end

-- Puts an eye at `rect` (its section body's), its art sized to fit (6 x 6 small, else 9 x 9).
function SlotWidgets.placeEye(self: Self, eye: Eye, rect: InventoryColumns.Rect)
	local button = eye.button
	local position, size = UDim2.fromOffset(rect.x, rect.y), UDim2.fromOffset(rect.w, rect.h)
	if button.Position ~= position then
		button.Position = position
	end
	if button.Size ~= size then
		button.Size = size
	end
	local small = math.min(rect.w, rect.h) < #Art.eye
	if small == eye.small then
		return
	end
	eye.small = small
	local wasShut = eye.shut.Visible
	eye.open:Destroy()
	eye.shut:Destroy()
	eye.open = eyeArt(button, if small then Art.smallEye else Art.eye, Dayz.Colour.Text, 0)
	eye.shut = eyeArt(
		button,
		if small then Art.smallEyeShut else Art.eyeShut,
		Dayz.Colour.TextDisabled,
		Dayz.Alpha.TextDisabled
	)
	eye.open.Visible = not wasShut
	eye.shut.Visible = wasShut
	self.shownHidden = -1
end

-- Destroys group `group`'s widgets and eyes (the block's section, rebuilt).
function SlotWidgets.drop(self: Self, group: string)
	local kept: { SlotWidget } = {}
	for _, widget in self.widgets do
		if widget.group == group then
			self.byButton[widget.view.button] = nil
			widget.view.icon:destroy()
			widget.view.button:Destroy()
			if self.hovered == widget then
				self.hovered = nil
			end
		else
			table.insert(kept, widget)
		end
	end
	self.widgets = kept
	local eyes: { Eye } = {}
	for _, eye in self.eyes do
		if eye.group == group then
			eye.button:Destroy()
		else
			table.insert(eyes, eye)
		end
	end
	self.eyes = eyes
end

--[[
	Every widget's window slot for `window`'s layout (only the container's size matters), -1 while
	its group is not `live`; a widget not live is hidden and not Selectable, so neither the pointer
	nor a gamepad reaches it. Eyes follow their group. `inert` (the recipe view over the screen):
	the live ones stay shown but none is Selectable, so a gamepad cannot stop on a slot that takes
	no press.
]]
function SlotWidgets.assign(self: Self, window: Window, live: { [string]: boolean }, inert: boolean?)
	local selectable = inert ~= true
	for _, widget in self.widgets do
		local on = live[widget.group] == true
		local index = if on then Menu.windowIndex(window, widget.store, widget.index) or -1 else -1
		widget.window = index
		local button = widget.view.button
		local shown = index >= 0
		if button.Visible ~= shown then
			button.Visible = shown
		end
		if button.Selectable ~= (shown and selectable) then
			button.Selectable = shown and selectable
		end
	end
	for _, eye in self.eyes do
		local on = live[eye.group] == true
		if eye.button.Visible ~= on then
			eye.button.Visible = on
		end
		if eye.button.Selectable ~= (on and selectable) then
			eye.button.Selectable = on and selectable
		end
	end
end

--[[ Drawing ]]

-- Is `widget` the open crafting grid's result slot?
function SlotWidgets.isResult(_self: Self, widget: SlotWidget, window: Window): boolean
	return widget.store == "container" and widget.index == Types.CRAFT_RESULT and Types.craftWidth(window.container) > 0
end

--[[
	The crafting result the recipe gate keeps back from `window`'s grid (Window `recipes`): what the
	grid matches while the result slot is empty and the gate refuses it. Its item, count and why;
	nil when there is none. Matched again only when a grid stack or the progression changed.
]]
function SlotWidgets.lockedResult(self: Self, window: Window): (number?, number, string?)
	local container = window.container
	local width = Types.craftWidth(container)
	if container == nil or width == 0 or window.recipes == nil or container.slots[Types.CRAFT_RESULT] ~= nil then
		return nil, 0, nil
	end
	local cached = self.lockedGrid
	local same = #cached == width * width and self.lockedStatus == ProgressionState.get()
	for i = 1, width * width do
		local stack = container.slots[Types.CRAFT_RESULT + i]
		if (cached[i] or nil) ~= stack then
			same = false
			cached[i] = stack or false
		end
	end
	for i = width * width + 1, #cached do
		cached[i] = nil
	end
	if not same then
		local grid: { [number]: Types.Stack? } = {}
		for i = 1, width * width do
			grid[i] = container.slots[Types.CRAFT_RESULT + i]
		end
		local result = Crafting.match(grid, width)
		self.lockedStatus = ProgressionState.get()
		self.lockedItem = if result then result.item else nil
		self.lockedCount = if result then result.count else 0
		self.lockedText = if result then ProgressionState.lockText(result.item) else nil
	end
	if self.lockedText == nil then
		return nil, 0, nil
	end
	return self.lockedItem, self.lockedCount, self.lockedText
end

-- The eyes (open or shut by the `hidden` bits) and the closed accessory slots (past `open`).
local function drawEquipment(self: Self, window: Window)
	local inventory = window.inventory
	local hidden = inventory.hidden
	if hidden ~= self.shownHidden then
		self.shownHidden = hidden
		for _, eye in self.eyes do
			local shut = bit32.btest(hidden, bit32.lshift(1, eye.slot - 1))
			eye.open.Visible = not shut
			eye.shut.Visible = shut
		end
	end
	local open = inventory.accessorySlots
	if open ~= self.shownOpen then
		self.shownOpen = open
		for _, widget in self.widgets do
			local lock = widget.lock
			if lock then
				widget.locked = widget.index > open
				lock.Visible = widget.locked
			end
		end
	end
end

--[[
	Draws `window` (see the header): icons, faces, outlines (`hover` in the drag feedback colour,
	the `dragged` slots white), ghosts, the eyes and locks; `selected` is the selected hotbar slot
	(1..9) the band shows. (Section titles count from the window, not from here: a collapsed
	section's widgets are not live, so they draw nothing.)
]]
function SlotWidgets.draw(self: Self, window: Window, hover: Target?, dragged: { [number]: boolean }, selected: number)
	drawEquipment(self, window)
	local hovered = if hover and hover.kind == "slot" then hover.index else -1
	self.hovered = nil
	local feedback: Theme.Feedback? = self.feedback
	for _, widget in self.widgets do
		local index = widget.window
		local icon = widget.view.icon
		local stack = if index >= 0 then Menu.get(window, index) else nil
		if stack == nil and index >= 0 and self:isResult(widget, window) then
			-- (A locked result: greyed, never taken.)
			local item, count = self:lockedResult(window)
			icon:set(item, count)
			icon:setDimmed(item ~= nil)
		else
			icon:set(stack and stack.item, stack and stack.count, stack and stack.damage, stack and stack.data)
			icon:setDimmed(false)
		end
		local state: Theme.FaceState = if widget.locked
			then "locked"
			elseif widget.quick and widget.index == selected then "selected"
			elseif stack then "filled"
			else "empty"
		Dayz.paintFace(widget.face, state)
		local isHovered = index >= 0 and index == hovered
		if isHovered then
			self.hovered = widget
		end
		local lit = index >= 0 and (isHovered or dragged[index] == true)
		local colour: Theme.Feedback? = nil
		if isHovered then
			colour = feedback
		end
		Dayz.setLit(widget.view.hover, lit, colour)
		local ghost = widget.ghost
		if ghost then
			local show = stack == nil and not widget.locked
			if ghost.Visible ~= show then
				ghost.Visible = show
			end
		end
	end
end

-- What a carried stack would do over the hovered slot (Ui/Screens, after `draw`): its outline's
-- colour now, and from the next draw on.
function SlotWidgets.setFeedback(self: Self, feedback: Theme.Feedback?)
	self.feedback = feedback
	local widget = self.hovered
	if widget then
		Dayz.setLit(widget.view.hover, true, feedback)
	end
end

--[[ Hit tests ]]

-- The live widget under `point` (screen pixels), if any.
function SlotWidgets.widgetAt(self: Self, point: Vector2): SlotWidget?
	for _, widget in self.widgets do
		if widget.window >= 0 and Style.contains(widget.view.button, point) then
			return widget
		end
	end
	return nil
end

-- The shown eye under `point`, if any.
function SlotWidgets.eyeAt(self: Self, point: Vector2): Eye?
	for _, eye in self.eyes do
		if Style.contains(eye.button, point) then
			return eye
		end
	end
	return nil
end

-- The target of a (gamepad) selected object, if it is a live slot.
function SlotWidgets.targetOf(self: Self, object: GuiObject): Target?
	local widget = self.byButton[object]
	if widget and widget.window >= 0 then
		return { kind = "slot", index = widget.window }
	end
	return nil
end

-- The first live widget of `group` (gamepad selection's start).
function SlotWidgets.first(self: Self, group: string): SlotWidget?
	for _, widget in self.widgets do
		if widget.group == group and widget.window >= 0 then
			return widget
		end
	end
	return nil
end

return SlotWidgets

--!strict
--[[
	The survival inventory screen (also a creative tab), laid out like Minecraft's 176 x 166
	inventory:

	  * the armor column on the left (head, chest, legs, feet); an empty armor slot shows a faint
	    outline of its piece;
	  * next to it the player, drawn in a ViewportFrame (the character cloned into a WorldModel),
	    facing the viewer and turning a little towards the mouse like Minecraft's;
	  * at the top right the 2 x 2 crafting grid under its "Crafting" label, an arrow and the
	    result slot (window 0's own "inventory" container, slots 2..5 and 1);
	  * the 27 inventory slots and, below them after a small gap, the hotbar row.

	When a block's window is open, its panel sits ABOVE the player panel (Ui/MenuLayout):
	  chest     its name and size / 9 rows of 9 slots
	  crafting  "Crafting": the 3 x 3 grid, an arrow and the result in a large frame
	  furnace   "Furnace": the input over the flame over the fuel, the progress arrow and the output;
	            the flame burns down and the arrow fills from the container's `data`
	The player panel then shows the player's name where the 2 x 2 grid was: that window has no 2 x 2
	grid. In creative mode (with no block open) two tabs above the panel switch between the item
	selection and this screen.

	This module only draws and hit-tests (in screen pixels, the InputObject.Position space): the
	clicks themselves are Ui/SlotClicks, driven by Ui/Screens, and Inventory/Menu applies the rules
	of each slot (results are only taken, crafting happens there). Slots map to window slots by the
	window layout of Inventory/Types (container, armor, inventory 10..36, hotbar).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Items = require(Shared.Items)
local Menu = require(Shared.Inventory.Menu)
local Types = require(Shared.Inventory.Types)

local ItemModels = require(script.Parent.Parent.Rendering.ItemModels)
local ItemIcon = require(script.Parent.ItemIcon)
local MenuLayout = require(script.Parent.MenuLayout)
local SlotClicks = require(script.Parent.SlotClicks)
local Style = require(script.Parent.Style)

type Window = Types.Window
type Target = SlotClicks.Target

local WIDTH = MenuLayout.WIDTH
local PLAYER_HEIGHT = MenuLayout.PLAYER_HEIGHT
-- Gap between the container panel and the player panel.
local GAP = 2
local TAB_HEIGHT = ItemIcon.TAB_HEIGHT
-- The character preview box (Minecraft's: 51 x 72 at (26, 8)).
local PREVIEW_X, PREVIEW_Y, PREVIEW_W, PREVIEW_H = 26, 8, 49, 69
local PREVIEW_FOV = 30
-- The crafting arrows and the furnace's unlit flame are the slot grey; its progress arrow fills
-- white over the grey one, inside the 24 x 16 progress area (one pixel in).
local ARROW_COLOUR = Style.Colour.Slot
local PROGRESS_COLOUR = Color3.new(1, 1, 1)
local PROGRESS_ARROW_W, PROGRESS_ARROW_H = 22, 15
local FIRE_PALETTE: { [string]: Color3 } = {
	R = Color3.fromRGB(214, 78, 0),
	O = Color3.fromRGB(255, 140, 0),
	Y = Color3.fromRGB(255, 214, 40),
	W = Color3.fromRGB(255, 250, 190),
}
local UNLIT_PALETTE: { [string]: Color3 } = { R = ARROW_COLOUR, O = ARROW_COLOUR, Y = ARROW_COLOUR, W = ARROW_COLOUR }

-- Faint outlines in empty armor slots (16 x 16 pixel art).
local ARMOR_GHOSTS: { { string } } = {
	{
		"................",
		"................",
		"................",
		"....GGGGGGGG....",
		"...GGGGGGGGGG...",
		"...GGGGGGGGGG...",
		"...GG......GG...",
		"...GG......GG...",
		"...GG......GG...",
		"...GG......GG...",
	},
	{
		"................",
		"................",
		"...GGG....GGG...",
		"..GGGGG..GGGGG..",
		"..GGGGGGGGGGGG..",
		"..GGGGGGGGGGGG..",
		"..GG.GGGGGG.GG..",
		"..GG.GGGGGG.GG..",
		".....GGGGGG.....",
		".....GGGGGG.....",
		".....GGGGGG.....",
		".....GGGGGG.....",
		".....GGGGGG.....",
	},
	{
		"................",
		"................",
		"................",
		"....GGGGGGGG....",
		"....GGGGGGGG....",
		"....GGG..GGG....",
		"....GGG..GGG....",
		"....GG....GG....",
		"....GG....GG....",
		"....GG....GG....",
		"....GG....GG....",
		"....GG....GG....",
		"....GG....GG....",
	},
	{
		"................",
		"................",
		"................",
		"................",
		"................",
		"................",
		"................",
		"...GG......GG...",
		"...GG......GG...",
		"...GG......GG...",
		"..GGG......GGG..",
		"..GGG......GGG..",
	},
}

type SlotWidget = {
	view: ItemIcon.Slot,
	store: string,
	-- Index in the store (container 1..n, armor 1..4, inventory 1..36).
	index: number,
	-- Window slot (depends on the container's size).
	window: number,
	ghost: Frame?,
}

export type InventoryScreen = {
	root: Frame,
	-- Called when the "Item selection" tab is clicked (creative), and the touch close button.
	onTab: () -> (),
	onClose: () -> (),
	size: (self: InventoryScreen) -> Vector2,
	setLayout: (self: InventoryScreen, container: Types.Container?, tabs: boolean) -> (),
	render: (self: InventoryScreen, window: Window, hover: Target?, dragged: { [number]: boolean }) -> (),
	targetAt: (self: InventoryScreen, point: Vector2) -> Target?,
	targetOf: (self: InventoryScreen, object: GuiObject) -> Target?,
	firstSelectable: (self: InventoryScreen) -> GuiObject?,
	opened: (self: InventoryScreen) -> (),
	closed: (self: InventoryScreen) -> (),
	follow: (self: InventoryScreen, point: Vector2?) -> (),
}

-- A furnace panel's gauge: a clipping frame over `rect` showing part of the lit art (in `holder`).
type Gauge = { clip: Frame, holder: Frame, rect: MenuLayout.Rect, shown: number }

type Self = InventoryScreen & {
	playerPanel: Frame,
	containerPanel: Frame?,
	containerKey: string,
	tabFrames: { GuiObject },
	tabsShown: boolean,
	playerSlots: { SlotWidget },
	containerSlots: { SlotWidget },
	-- The player panel's 2 x 2 crafting area (window 0) and the name shown instead of it.
	gridGroup: Frame,
	gridSlots: { SlotWidget },
	gridShown: boolean,
	nameLabel: TextLabel,
	-- The open furnace's flame (rows shown) and arrow (columns shown).
	flame: Gauge?,
	progress: Gauge?,
	byButton: { [GuiObject]: SlotWidget },
	height: number,
	-- The player panel's touch close button (hidden under a container panel, which has its own).
	playerClose: TextButton,
	preview: ViewportFrame,
	previewCamera: Camera,
	world: WorldModel,
	clone: Model?,
	cloneYaw: number,
	-- Item drawn in the preview's hand (false: not drawn yet) and its model.
	heldItem: number | false | nil,
	heldModel: Model?,
}

local InventoryScreen = {}
InventoryScreen.__index = InventoryScreen

local function itemNamed(name: string): number?
	local ok, id = pcall(function()
		return Items.id[name]
	end)
	return if ok then id else nil
end

-- A crafting arrow filling `rect` (Style pixel art).
local function drawArrow(parent: Instance, rect: MenuLayout.Rect, colour: Color3, z: number)
	Style.pixelArt(parent, rect.x, rect.y, MenuLayout.arrowArt(rect.w, rect.h), { ["#"] = colour }, z)
end

-- The touch close button ("x") at the top right of a panel.
local function closeButton(self: Self, panel: Frame): TextButton
	local button = Style.button(panel, "x", WIDTH - 15, 3, 12, 12, 6)
	button.Visible = UserInputService.TouchEnabled
	button.Activated:Connect(function()
		self.onClose()
	end)
	return button
end

local function newSlot(
	self: Self,
	parent: Frame,
	list: { SlotWidget },
	x: number,
	y: number,
	store: string,
	index: number,
	big: boolean?
)
	local view = ItemIcon.slot(parent, x, y, nil, big)
	local widget: SlotWidget = { view = view, store = store, index = index, window = -1, ghost = nil }
	table.insert(list, widget)
	self.byButton[view.button] = widget
	return widget
end

function InventoryScreen.new(parent: Instance): InventoryScreen
	local root = Instance.new("Frame")
	root.Name = "Inventory"
	root.BackgroundTransparency = 1
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromOffset(WIDTH, PLAYER_HEIGHT)
	root.Visible = false
	root.Parent = parent

	local self = (
		setmetatable({
			root = root,
			onTab = function() end,
			onClose = function() end,
			containerPanel = nil,
			containerKey = "",
			tabsShown = false,
			playerSlots = {},
			containerSlots = {},
			gridSlots = {},
			gridShown = false,
			flame = nil,
			progress = nil,
			byButton = {},
			height = PLAYER_HEIGHT,
			clone = nil,
			cloneYaw = math.huge,
			heldItem = false,
			heldModel = nil,
		}, InventoryScreen) :: any
	) :: Self

	-- Creative tabs: item selection, and this screen (active). Hidden in survival.
	local itemsTab = ItemIcon.tab(root, 0, itemNamed("Grass"), false)
	local thisTab = ItemIcon.tab(root, ItemIcon.TAB_WIDTH + 1, itemNamed("Chest"), true)
	self.tabFrames = table.move(thisTab.frames, 1, #thisTab.frames, #itemsTab.frames + 1, table.clone(itemsTab.frames))
	for _, frame in self.tabFrames do
		frame.Visible = false
	end
	itemsTab.button.Activated:Connect(function()
		self.onTab()
	end)

	local panel = Style.panel(root, 0, 0, WIDTH, PLAYER_HEIGHT)
	panel.Name = "Player"
	self.playerPanel = panel
	self.playerClose = closeButton(self, panel)

	-- Armor column.
	for slot = 1, Types.ARMOR_SIZE do
		local widget = newSlot(self, panel, self.playerSlots, 8, 8 + (slot - 1) * 18, "armor", slot)
		local ghost = Instance.new("Frame")
		ghost.BackgroundTransparency = 1
		ghost.Position = UDim2.fromOffset(1, 1)
		ghost.Size = UDim2.fromOffset(Style.ITEM, Style.ITEM)
		ghost.ZIndex = 3
		ghost.Parent = widget.view.button
		Style.pixelArt(ghost, 0, 0, ARMOR_GHOSTS[slot], { G = Style.Colour.SlotGhost }, 1)
		widget.ghost = ghost
	end

	-- The player, in a black box.
	Style.inset(panel, PREVIEW_X - 1, PREVIEW_Y - 1, PREVIEW_W + 2, PREVIEW_H + 2, 4, Color3.new(0, 0, 0))
	local preview = Instance.new("ViewportFrame")
	preview.BackgroundTransparency = 1
	preview.Position = UDim2.fromOffset(PREVIEW_X, PREVIEW_Y)
	preview.Size = UDim2.fromOffset(PREVIEW_W, PREVIEW_H)
	preview.ZIndex = 5
	preview.Ambient = Color3.fromRGB(170, 170, 170)
	preview.LightColor = Color3.fromRGB(140, 140, 140)
	preview.LightDirection = Vector3.new(-0.4, -1, 0.6)
	preview.Parent = panel
	local camera = Instance.new("Camera")
	camera.FieldOfView = PREVIEW_FOV
	camera.Parent = preview
	preview.CurrentCamera = camera
	local world = Instance.new("WorldModel")
	world.Parent = preview
	self.preview, self.previewCamera, self.world = preview, camera, world

	-- With a block's window open (it has no 2 x 2 grid), the player's name takes the grid's place.
	local name = Style.text(panel, Players.LocalPlayer.DisplayName, 80, 8, 78, 8, Style.Colour.Title, 5)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	self.nameLabel = name

	-- The 2 x 2 crafting area (Minecraft's InventoryScreen), shown with window 0.
	local grid = Instance.new("Frame")
	grid.Name = "Crafting"
	grid.BackgroundTransparency = 1
	grid.Size = UDim2.fromOffset(WIDTH, PLAYER_HEIGHT)
	grid.ZIndex = 4
	grid.Visible = false
	grid.Parent = panel
	self.gridGroup = grid
	local area = MenuLayout.inventoryGrid
	Style.text(grid, area.label.text, area.label.x, area.label.y, 70, 8, Style.Colour.Title, 5)
	for _, spot in area.slots do
		newSlot(self, grid, self.gridSlots, spot.x, spot.y, "container", spot.slot, spot.big)
	end
	drawArrow(grid, area.arrow, ARROW_COLOUR, 5)

	-- Inventory slots 10..36, then the hotbar.
	for row = 0, 2 do
		for column = 0, 8 do
			newSlot(self, panel, self.playerSlots, 8 + column * 18, 84 + row * 18, "inventory", 10 + row * 9 + column)
		end
	end
	for column = 0, 8 do
		newSlot(self, panel, self.playerSlots, 8 + column * 18, 142, "inventory", 1 + column)
	end

	self:setLayout(nil, false)
	return self
end

-- Size of the content in GUI pixels.
function InventoryScreen.size(self: Self): Vector2
	return Vector2.new(WIDTH, self.height)
end

local function assignIndices(self: Self, window: Window)
	for _, widget in self.playerSlots do
		widget.window = Menu.windowIndex(window, widget.store, widget.index) or -1
	end
	for _, widget in self.containerSlots do
		widget.window = Menu.windowIndex(window, widget.store, widget.index) or -1
	end
	-- (The 2 x 2 grid's slots are window 0's container slots: they are nothing in other windows.)
	for _, widget in self.gridSlots do
		widget.window = if self.gridShown then Menu.windowIndex(window, widget.store, widget.index) or -1 else -1
	end
end

--[[
	A furnace gauge: `draw` draws its art grey in the panel, and again lit inside a clipping frame
	that render() grows (from the bottom for the flame, from the left for the arrow).
]]
local function newGauge(panel: Frame, rect: MenuLayout.Rect, draw: (parent: Instance, lit: boolean) -> ()): Gauge
	draw(panel, false)
	local clip = Instance.new("Frame")
	clip.BackgroundTransparency = 1
	clip.ClipsDescendants = true
	clip.Position = UDim2.fromOffset(rect.x, rect.y)
	clip.Size = UDim2.fromOffset(0, 0)
	clip.ZIndex = 6
	clip.Parent = panel
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(rect.w, rect.h)
	holder.ZIndex = 1
	holder.Parent = clip
	draw(holder, true)
	return { clip = clip, holder = holder, rect = rect, shown = 0 }
end

-- A block's panel above the player panel (Ui/MenuLayout.panel).
local function buildPanel(self: Self, container: Types.Container)
	local layout = MenuLayout.panel(container)
	local panel = Style.panel(self.root, 0, 0, WIDTH, layout.height)
	panel.Name = "Container"
	if layout.centred then
		Style.text(panel, layout.title, 0, layout.titleY, WIDTH, 8, Style.Colour.Title, 5, Enum.TextXAlignment.Center)
	else
		Style.text(panel, layout.title, layout.titleX, layout.titleY, 140, 8, Style.Colour.Title, 5)
	end
	for _, spot in layout.slots do
		newSlot(self, panel, self.containerSlots, spot.x, spot.y, "container", spot.slot, spot.big)
	end
	local arrow = layout.arrow
	if arrow then
		drawArrow(panel, arrow, ARROW_COLOUR, 5)
	end
	local flame = layout.flame
	if flame then
		self.flame = newGauge(panel, flame, function(parent: Instance, lit: boolean)
			local x, y = if lit then 0 else flame.x, if lit then 0 else flame.y
			Style.pixelArt(parent, x, y, MenuLayout.FLAME_ART, if lit then FIRE_PALETTE else UNLIT_PALETTE, 5)
		end)
	end
	local progress = layout.progress
	if progress then
		self.progress = newGauge(panel, progress, function(parent: Instance, lit: boolean)
			local x, y = if lit then 1 else progress.x + 1, if lit then 1 else progress.y + 1
			local rect = { x = x, y = y, w = PROGRESS_ARROW_W, h = PROGRESS_ARROW_H }
			drawArrow(parent, rect, if lit then PROGRESS_COLOUR else ARROW_COLOUR, 5)
		end)
	end
	closeButton(self, panel)
	self.containerPanel = panel
end

-- Shows `shown` rows of a flame (from the bottom) or columns of an arrow (from the left).
local function setGauge(gauge: Gauge?, shown: number, vertical: boolean)
	if gauge == nil or gauge.shown == shown then
		return
	end
	gauge.shown = shown
	local rect = gauge.rect
	if vertical then
		gauge.clip.Position = UDim2.fromOffset(rect.x, rect.y + rect.h - shown)
		gauge.clip.Size = UDim2.fromOffset(rect.w, shown)
		gauge.holder.Position = UDim2.fromOffset(0, shown - rect.h)
	else
		gauge.clip.Size = UDim2.fromOffset(shown, rect.h)
	end
end

--[[
	Shows the panels for the window's container and the creative tabs. A block's container gets its
	panel above the player panel (rebuilt only when its kind, block or size changes); window 0's
	"inventory" container is the player panel's 2 x 2 grid and has no panel.
]]
function InventoryScreen.setLayout(self: Self, container: Types.Container?, tabs: boolean)
	local panelContainer = if container and MenuLayout.hasPanel(container) then container else nil
	local key = MenuLayout.panelKey(container)
	if key ~= self.containerKey then
		self.containerKey = key
		local old = self.containerPanel
		if old then
			for _, widget in self.containerSlots do
				self.byButton[widget.view.button] = nil
				widget.view.icon:destroy()
			end
			old:Destroy()
		end
		self.containerSlots = {}
		self.containerPanel = nil
		self.flame = nil
		self.progress = nil
		if panelContainer then
			buildPanel(self, panelContainer)
		end
	end
	-- The 2 x 2 grid only belongs to window 0; other windows show the player's name there.
	local grid = MenuLayout.showsGrid(container)
	if grid ~= self.gridShown then
		self.gridShown = grid
		self.gridGroup.Visible = grid
		self.nameLabel.Visible = not grid
	end
	self.playerClose.Visible = UserInputService.TouchEnabled and panelContainer == nil
	local showTabs = tabs and panelContainer == nil
	self.tabsShown = showTabs
	for _, frame in self.tabFrames do
		frame.Visible = showTabs
	end
	local top = 0
	local panel = self.containerPanel
	if panel then
		top = panel.Size.Y.Offset + GAP
	elseif showTabs then
		top = TAB_HEIGHT
	end
	self.playerPanel.Position = UDim2.fromOffset(0, top)
	self.height = top + PLAYER_HEIGHT
	self.root.Size = UDim2.fromOffset(WIDTH, self.height)
	-- Window slots for this layout (only the container's size matters).
	assignIndices(self, { id = 0, inventory = Types.newInventory(), container = container })
end

-- The open furnace's flame and arrow, from its `data` (MenuLayout.flameRows / arrowColumns).
local function renderGauges(self: Self, window: Window)
	if self.flame == nil and self.progress == nil then
		return
	end
	local container = window.container
	local data = if container and container.kind == "furnace" then container.data else nil
	setGauge(self.flame, MenuLayout.flameRows(data), true)
	-- (Minecraft draws the arrow one column wider than its progress; the art starts one in.)
	local columns = MenuLayout.arrowColumns(data)
	setGauge(self.progress, if columns > 0 then columns + 1 else 0, false)
end

-- Puts the selected item in the preview's hand (rebuilt only when it changes).
local function updateHeld(self: Self, window: Window)
	local inventory = window.inventory
	local stack = inventory.slots[inventory.selected]
	local item = if stack and stack.count > 0 then stack.item else nil
	if item == self.heldItem then
		return
	end
	self.heldItem = item
	local old = self.heldModel
	if old then
		old:Destroy()
		self.heldModel = nil
	end
	local clone = self.clone
	-- Held as Player/HeldItems holds it on characters (tools upright from the fist).
	local at = if clone and item then ItemModels.handPivot(item, clone) else nil
	if clone and at and item then
		local model = ItemModels.build(item, ItemModels.handSize(item))
		model:PivotTo(at)
		-- Inside the clone, so it turns with it.
		model.Parent = clone
		self.heldModel = model
	end
end

-- Draws `window`; `hover` gets the white overlay, so do the slots of a drag in progress.
function InventoryScreen.render(self: Self, window: Window, hover: Target?, dragged: { [number]: boolean })
	updateHeld(self, window)
	local hovered = if hover and hover.kind == "slot" then hover.index else -1
	local function draw(widget: SlotWidget)
		local stack = Menu.get(window, widget.window)
		widget.view.icon:set(stack and stack.item, stack and stack.count, stack and stack.damage)
		local lit = widget.window == hovered or dragged[widget.window] == true
		if widget.view.hover.Visible ~= lit then
			widget.view.hover.Visible = lit
		end
		local ghost = widget.ghost
		if ghost and ghost.Visible ~= (stack == nil) then
			ghost.Visible = stack == nil
		end
	end
	for _, widget in self.containerSlots do
		draw(widget)
	end
	if self.gridShown then
		for _, widget in self.gridSlots do
			draw(widget)
		end
	end
	for _, widget in self.playerSlots do
		draw(widget)
	end
	renderGauges(self, window)
end

-- What is under `point` (screen pixels): a slot, nil over a panel, or outside.
function InventoryScreen.targetAt(self: Self, point: Vector2): Target?
	for _, list in { self.containerSlots, self.gridSlots, self.playerSlots } do
		for _, widget in list do
			if widget.window >= 0 and Style.contains(widget.view.button, point) then
				return { kind = "slot", index = widget.window }
			end
		end
	end
	local container = self.containerPanel
	if Style.contains(self.playerPanel, point) or (container and Style.contains(container, point)) then
		return nil
	end
	for _, frame in self.tabFrames do
		if Style.contains(frame, point) then
			return nil
		end
	end
	return { kind = "outside" }
end

-- The target of a (gamepad) selected object, if it is one of this screen's slots.
function InventoryScreen.targetOf(self: Self, object: GuiObject): Target?
	local widget = self.byButton[object]
	if widget and widget.window >= 0 then
		return { kind = "slot", index = widget.window }
	end
	return nil
end

-- Where gamepad selection starts: the block panel's first slot (a grid's top left, a furnace's
-- input), else the first hotbar slot.
function InventoryScreen.firstSelectable(self: Self): GuiObject?
	local first = self.containerSlots[1]
	if first then
		return first.view.button
	end
	local hotbar = self.playerSlots[#self.playerSlots - Types.HOTBAR_SIZE + 1]
	return if hotbar then hotbar.view.button else nil
end

--[[ Character preview ]]

local function cloneCharacter(): Model?
	local character = Players.LocalPlayer.Character
	if character == nil then
		return nil
	end
	local archivable = character.Archivable
	character.Archivable = true
	local ok, result = pcall(function()
		return character:Clone()
	end)
	character.Archivable = archivable
	if not ok or result == nil then
		return nil
	end
	local clone = result :: Model
	for _, descendant in clone:GetDescendants() do
		if
			descendant:IsA("BaseScript")
			or descendant:IsA("Sound")
			or descendant:IsA("Constraint")
			or descendant:IsA("BodyMover")
			or descendant:IsA("VectorForce")
			or descendant:IsA("ParticleEmitter")
		then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		elseif descendant:IsA("Humanoid") then
			descendant.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
	end
	local root = clone:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		clone.PrimaryPart = root
		root.Transparency = 1
	end
	return clone
end

-- Builds the character preview (when the screen opens).
function InventoryScreen.opened(self: Self)
	self:closed()
	local clone = cloneCharacter()
	if clone == nil then
		return
	end
	-- Upright at the origin facing -Z, the camera in front of it (on the -Z side).
	clone:PivotTo(CFrame.identity)
	clone.Parent = self.world
	local box, size = clone:GetBoundingBox()
	local height = math.max(size.Y, 1)
	local aspect = PREVIEW_W / PREVIEW_H
	local half = math.max(height / 2, size.X / 2 / aspect) / 0.9
	local distance = half / math.tan(math.rad(PREVIEW_FOV / 2)) + size.Z / 2
	local centre = box.Position
	self.previewCamera.CFrame = CFrame.lookAt(centre - Vector3.new(0, 0, distance), centre)
	self.clone = clone
	self.cloneYaw = 0
	self.heldItem = false
end

function InventoryScreen.closed(self: Self)
	local clone = self.clone
	if clone then
		clone:Destroy()
		self.clone = nil
	end
	self.heldModel = nil
	self.heldItem = false
end

--[[
	Turns the player towards the pointer like Minecraft's renderEntityInInventoryFollowsMouse:
	atan(offset / 40 GUI pixels) x 20 degrees.
]]
function InventoryScreen.follow(self: Self, point: Vector2?)
	local clone = self.clone
	if clone == nil then
		return
	end
	local yaw = 0
	if point then
		local position, size = self.preview.AbsolutePosition, self.preview.AbsoluteSize
		local pixels = size.X / PREVIEW_W
		if pixels > 0 then
			local dx = (point.X - (position.X + size.X / 2)) / pixels
			yaw = math.atan(dx / 40) * math.rad(20)
		end
	end
	if math.abs(yaw - self.cloneYaw) > 1e-3 then
		self.cloneYaw = yaw
		clone:PivotTo(CFrame.Angles(0, yaw, 0))
	end
end

return InventoryScreen

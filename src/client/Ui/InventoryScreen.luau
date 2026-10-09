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
	  * the 27 inventory slots and, below them after a small gap, the hotbar row;
	  * Terraria's equipment (window 0 only: the inventory alone, also creative's inventory tab), a
	    panel of its own 84 x 166 docked 2 px right of the player panel (Terraria's is right of
	    its inventory too), so `size` is 262 wide then: the title "Equipment" at (8, 6), seven
	    rows at y = 17 + 18 (r - 1): the vanity armor (x 8, rows 1..4, the armor ghosts tinted
	    violet, a 6 x 6 eye in each slot's top right corner hiding that armor piece's look), the
	    vanity accessories (x 28), the accessories (x 48: rows past the open ones darkened with a
	    padlock, "Opens at the Industrial Age"), and a 9 x 9 eye per accessory row (x 68; a 16 x
	    18 button, so a finger finds it) hiding that accessory's look (Types `hidden`: the
	    inventory's `hide` action, predicted like any other). The preview wears what the
	    character shows (Player/EquipmentLooks.dress, again whenever the equipment changes).

	When a block's window is open, its panel sits ABOVE the player panel (Ui/MenuLayout):
	  chest     its name and size / 9 rows of 9 slots
	  crafting  "Crafting": the 3 x 3 grid, an arrow and the result in a large frame
	  furnace   "Furnace": the input over the flame over the fuel, the progress arrow and the output;
	            the flame burns down and the arrow fills from the container's `data`
	  machine   a Mekanism machine (Shared/Machines): its name, its kind's slots (an empty upgrade
	            slot shows a faint outline of its card), gauges, status line and the lines under it
	            (a battery's input and output), Mekanism's vertical energy bar filling from the
	            bottom, red when nearly empty to green when full, and a fluid gauge per tank (the
	            Heat Generator's lava, the Oil Refinery's oil and fuel, the Combustion Generator's
	            fuel: Mekanism's 18 x 60 GuiFluidGauge, the fluid's colour filling it from the bottom
	            under the gauge's scale marks); hovering the bar shows "stored / capacity", a gauge
	            "Lava: 5,000 mB" and its capacity (`tooltipAt`)
	Machines' items that hold energy (charged batteries, machines broken with energy in them) show
	Mekanism's energy bar where a worn tool's durability bar goes (Ui/ItemIcon).
	The player panel then shows the player's name where the 2 x 2 grid was: that window has no 2 x 2
	grid. In creative mode (with no block open) two tabs above the panel switch between the item
	selection and this screen. A gear button where Minecraft's recipe book button is (20 x 18 at
	104, 61) opens the Options menu (`onSettings`, Ui/Screens).

	A crafting result Progression keeps back (a later Age's, or a skill's not unlocked: the window's
	recipe gate, Shared/Progression) is drawn greyed in the empty result slot, and hovering it
	says what it needs ("Requires the Iron Age"): the grid still matches it (Crafting.match), but
	the server never offers it, so it can't be taken.

	This module only draws and hit-tests (in screen pixels, the InputObject.Position space): the
	clicks themselves are Ui/SlotClicks, driven by Ui/Screens, and Inventory/Menu applies the rules
	of each slot (results are only taken, crafting happens there). Slots map to window slots by the
	window layout of Inventory/Types (container, armor, inventory 10..36, hotbar, equipment). The
	eyes are buttons of their own (Activated): over one, `targetAt` says nothing, so no slot click
	happens under it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Accessories = require(Shared.Items.Accessories)
local Ages = require(Shared.Progression.Ages)
local Config = require(Shared.Config)
local Crafting = require(Shared.Crafting)
local Fluids = require(Shared.Fluids)
local Items = require(Shared.Items)
local Menu = require(Shared.Inventory.Menu)
local Types = require(Shared.Inventory.Types)

local ItemModels = require(script.Parent.Parent.Rendering.ItemModels)
local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local EquipmentLooks = require(script.Parent.Parent.Player.EquipmentLooks)
local ProgressionState = require(script.Parent.Parent.Player.ProgressionState)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
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
-- Terraria's equipment panel: its width (right of the player panel, GAP apart), its rows' first
-- y and the columns: vanity armor, vanity accessories, accessories, the accessories' eyes.
local EQUIP_W = 84
local EQUIP_ROW = 17
local EQUIP_VANITY_X, EQUIP_VANITY_ACC_X, EQUIP_ACC_X, EQUIP_EYE_X = 8, 28, 48, 68
-- The vanity armor slots' ghosts: the armor ones, tinted violet (Terraria's vanity slots).
local VANITY_GHOST = Color3.fromRGB(128, 112, 150)
-- A closed accessory row: dark over the slot, and a padlock.
local LOCK_SHADE = Color3.fromRGB(0, 0, 0)
local LOCK_SHADE_TRANSPARENCY = 0.45
local LOCK_ART = {
	"..###..",
	".#...#.",
	".#...#.",
	"#######",
	"###.###",
	"###.###",
	"#######",
}
-- The eyes: open (shown) and shut (hidden), 9 x 9 for accessories and 6 x 6 for armor.
local EYE_ART = {
	".........",
	"..#####..",
	".#.....#.",
	"#..###..#",
	"#..#W#..#",
	"#..###..#",
	".#.....#.",
	"..#####..",
	".........",
}
local EYE_SHUT_ART = {
	".........",
	".........",
	".........",
	"#.......#",
	".#.....#.",
	"..#####..",
	"..#.#.#..",
	".........",
	".........",
}
local SMALL_EYE_ART = {
	"......",
	".####.",
	"#.WW.#",
	"#.WW.#",
	".####.",
	"......",
}
local SMALL_EYE_SHUT_ART = {
	"......",
	"......",
	"#....#",
	".####.",
	"#.#.#.",
	"......",
}
local EYE_COLOUR = Color3.fromRGB(64, 64, 64)
local EYE_SHUT_COLOUR = Color3.fromRGB(110, 110, 110)
-- The character preview box (Minecraft's: 51 x 72 at (26, 8)).
local PREVIEW_X, PREVIEW_Y, PREVIEW_W, PREVIEW_H = 26, 8, 49, 69
local PREVIEW_FOV = 30
-- The crafting arrows and the furnace's unlit flame are the slot grey; its progress arrow fills
-- white over the grey one, inside the 24 x 16 progress area (one pixel in).
local ARROW_COLOUR = Style.Colour.Slot
local PROGRESS_COLOUR = Color3.new(1, 1, 1)
local PROGRESS_ARROW_W, PROGRESS_ARROW_H = 22, 15
-- A tank gauge's empty inside, and its scale: TANK_MARKS parts, marked over the fluid from the
-- right edge (Mekanism's gauge overlay), dark and see-through.
local TANK_BACK = Color3.fromRGB(64, 64, 64)
local TANK_MARKS = 8
local TANK_MARK_LONG, TANK_MARK_SHORT = 8, 4
local TANK_MARK_COLOUR = Color3.new(0, 0, 0)
local TANK_MARK_TRANSPARENCY = 0.45
local FIRE_PALETTE = Style.FirePalette
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
	-- The lines of a tooltip for what is under `point` that is no item (a machine's energy bar).
	tooltipAt: (self: InventoryScreen, point: Vector2, window: Window) -> { string }?,
	-- Called when the "Item selection" tab is clicked (creative), and the touch close button.
	onTab: () -> (),
	onClose: () -> (),
	-- Called when the gear button is clicked (the Options menu).
	onSettings: () -> (),
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

-- A machine's energy bar: its sunken frame and the fill (rows shown, colour key).
type EnergyBar = { frame: Frame, fill: Frame, rect: MenuLayout.Rect, shown: number, colour: string }
-- A machine's tank gauge: its sunken frame, the fluid filling it (rows and fluid shown).
type TankGauge = { frame: Frame, fill: Frame, spot: MenuLayout.TankSpot, shown: number, fluid: number }

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
	-- A machine's panel: where its gauges read their data, its energy bar and status line, and
	-- the data they last showed (`machineShown`: drawn at all since the panel was built).
	layout: MenuLayout.Panel?,
	energyBar: EnergyBar?,
	statusLabel: TextLabel?,
	-- Its extra lines under the status line (a battery's input and output), one label each.
	lineLabels: { TextLabel },
	tankGauges: { TankGauge },
	machineData: { number }?,
	machineShown: boolean,
	byButton: { [GuiObject]: SlotWidget },
	-- The crafting result the recipe gate keeps back (`lockedResult`): the grid's stacks it was
	-- matched from (stacks are values: a change is a new table), the progression status it was
	-- read with, the result (nil: none) and why.
	lockedGrid: { Types.Stack | false },
	lockedStatus: any,
	lockedItem: number?,
	lockedCount: number,
	lockedText: string?,
	height: number,
	-- The player panel's touch close button (hidden under a container panel, which has its own).
	playerClose: TextButton,
	preview: ViewportFrame,
	previewCamera: Camera,
	world: WorldModel,
	clone: Model?,
	cloneYaw: number,
	-- Item drawn in the preview's hand (false: not drawn yet), its model and the item look
	-- generation it was built with (ItemModels.generation).
	heldItem: number | false | nil,
	heldModel: Model?,
	heldLook: number,
	-- Terraria's equipment panel (window 0 only), its slots, its eyes and the padlocks over the
	-- closed accessory rows; what they last showed (hidden bits, open slots); the root's width.
	equipPanel: Frame,
	equipmentSlots: { SlotWidget },
	equipShown: boolean,
	eyes: { Eye },
	locks: { Frame },
	shownHidden: number,
	shownOpen: number,
	width: number,
	-- The preview's equipment: the stacks and bits it was dressed from (stacks are values: a
	-- change is a new table), the looks text and the pieces' folder (Player/EquipmentLooks.dress).
	looksRefs: { any },
	looksText: string?,
	looksFolder: Folder?,
}

-- An eye toggling a look: its button, the open and shut art, and the `hide` action's slot.
type Eye = { button: TextButton, open: Frame, shut: Frame, slot: number }

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
		SoundPlayer.click()
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

-- Gives a slot the faint outline `art` (16 x 16 pixel art) shown while it is empty (render()).
local function addGhost(widget: SlotWidget, art: { string })
	local ghost = Instance.new("Frame")
	ghost.BackgroundTransparency = 1
	ghost.Position = UDim2.fromOffset(1, 1)
	ghost.Size = UDim2.fromOffset(Style.ITEM, Style.ITEM)
	ghost.ZIndex = 3
	ghost.Parent = widget.view.button
	Style.pixelArt(ghost, 0, 0, art, { G = Style.Colour.SlotGhost }, 1)
	widget.ghost = ghost
end

-- An eye button at (x, y) of `parent`, `w` x `h`, its art (`small`: the armor's 6 x 6) centred.
local function newEye(parent: Instance, x: number, y: number, w: number, h: number, small: boolean, slot: number): Eye
	local button = Instance.new("TextButton")
	button.Text = ""
	button.AutoButtonColor = false
	button.BackgroundTransparency = 1
	button.Position = UDim2.fromOffset(x, y)
	button.Size = UDim2.fromOffset(w, h)
	button.ZIndex = 12
	button.Parent = parent
	local size = if small then 6 else 9
	local function art(rows: { string }, colour: Color3): Frame
		local holder = Instance.new("Frame")
		holder.BackgroundTransparency = 1
		holder.Position = UDim2.fromOffset((w - size) // 2, (h - size) // 2)
		holder.Size = UDim2.fromOffset(size, size)
		holder.ZIndex = 12
		holder.Parent = button
		Style.pixelArt(holder, 0, 0, rows, { ["#"] = colour, W = Color3.new(1, 1, 1) }, 13)
		return holder
	end
	local open = art(if small then SMALL_EYE_ART else EYE_ART, EYE_COLOUR)
	local shut = art(if small then SMALL_EYE_SHUT_ART else EYE_SHUT_ART, EYE_SHUT_COLOUR)
	shut.Visible = false
	local eye: Eye = { button = button, open = open, shut = shut, slot = slot }
	button.Activated:Connect(function()
		local hidden = not shut.Visible
		SoundPlayer.click()
		ClientInventory.apply({ kind = "hide", slot = slot, hidden = hidden })
	end)
	return eye
end

--[[
	Terraria's equipment panel (see the header), right of the player panel: hidden until
	setLayout shows it for window 0.
]]
local function buildEquipment(self: Self, root: Frame)
	local panel = Style.panel(root, WIDTH + GAP, 0, EQUIP_W, PLAYER_HEIGHT)
	panel.Name = "Equipment"
	panel.Visible = false
	self.equipPanel = panel
	Style.text(panel, "Equipment", 8, 6, EQUIP_W - 10, 8, Style.Colour.Title, 5)
	local touch = UserInputService.TouchEnabled
	for row = 1, Types.ACCESSORY_SIZE do
		local y = EQUIP_ROW + (row - 1) * Style.SLOT
		if row <= Types.VANITY_ARMOR_SIZE then
			local widget = newSlot(self, panel, self.equipmentSlots, EQUIP_VANITY_X, y, "vanityArmor", row)
			addGhost(widget, ARMOR_GHOSTS[row])
			for _, frame in (widget.ghost :: Frame):GetDescendants() do
				if frame:IsA("Frame") then
					frame.BackgroundColor3 = VANITY_GHOST
				end
			end
			-- Hiding the armor piece's look: a small eye in the slot's top right corner.
			local reach = if touch then 10 else 6
			table.insert(
				self.eyes,
				newEye(panel, EQUIP_VANITY_X + 16 - reach, y, reach, reach, true, Types.HIDE_ARMOR + row)
			)
		end
		newSlot(self, panel, self.equipmentSlots, EQUIP_VANITY_ACC_X, y, "vanityAccessory", row)
		local accessory = newSlot(self, panel, self.equipmentSlots, EQUIP_ACC_X, y, "accessory", row)
		-- A closed row: dark, with a padlock (shown by render).
		local lock = Style.frame(accessory.view.button, 1, 1, Style.ITEM, Style.ITEM, LOCK_SHADE, 11)
		lock.BackgroundTransparency = LOCK_SHADE_TRANSPARENCY
		lock.Visible = false
		Style.pixelArt(lock, 5, 4, LOCK_ART, { ["#"] = Style.Colour.Panel }, 12)
		table.insert(self.locks, lock)
		-- The accessory's eye: 9 x 9, in a 16 x 18 button on touch screens.
		local w = if touch then 16 else 9
		local h = if touch then 18 else 9
		table.insert(
			self.eyes,
			newEye(panel, EQUIP_EYE_X + (9 - w) // 2 + (if touch then 4 else 0), y + 4 - (h - 9) // 2, w, h, false, row)
		)
	end
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
			onSettings = function() end,
			containerPanel = nil,
			containerKey = "",
			tabsShown = false,
			playerSlots = {},
			containerSlots = {},
			gridSlots = {},
			lockedGrid = {},
			lockedStatus = nil,
			lockedItem = nil,
			lockedCount = 0,
			lockedText = nil,
			gridShown = false,
			flame = nil,
			progress = nil,
			layout = nil,
			energyBar = nil,
			statusLabel = nil,
			lineLabels = {},
			tankGauges = {},
			machineData = nil,
			machineShown = false,
			byButton = {},
			height = PLAYER_HEIGHT,
			clone = nil,
			cloneYaw = math.huge,
			heldItem = false,
			heldModel = nil,
			heldLook = 0,
			equipmentSlots = {},
			equipShown = false,
			eyes = {},
			locks = {},
			shownHidden = -1,
			shownOpen = -1,
			width = WIDTH,
			looksRefs = {},
			looksText = nil,
			looksFolder = nil,
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
		SoundPlayer.click()
		self.onTab()
	end)

	local panel = Style.panel(root, 0, 0, WIDTH, PLAYER_HEIGHT)
	panel.Name = "Player"
	self.playerPanel = panel
	self.playerClose = closeButton(self, panel)

	-- The Options menu's gear, where Minecraft's recipe book button is (this game has JEI).
	local gear = Style.button(panel, "", 104, 61, 20, 18, 6)
	gear.Name = "Settings"
	Style.gear(gear, 4, 3, 5)
	gear.Activated:Connect(function()
		SoundPlayer.click()
		self.onSettings()
	end)

	-- Armor column.
	for slot = 1, Types.ARMOR_SIZE do
		local widget = newSlot(self, panel, self.playerSlots, 8, 8 + (slot - 1) * 18, "armor", slot)
		addGhost(widget, ARMOR_GHOSTS[slot])
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

	buildEquipment(self, root)

	self:setLayout(nil, false)
	return self
end

-- Size of the content in GUI pixels (262 wide with the equipment panel: window 0).
function InventoryScreen.size(self: Self): Vector2
	return Vector2.new(self.width, self.height)
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
	-- (The equipment's only with its panel: window 0.)
	for _, widget in self.equipmentSlots do
		widget.window = if self.equipShown then Menu.windowIndex(window, widget.store, widget.index) or -1 else -1
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
		local widget = newSlot(self, panel, self.containerSlots, spot.x, spot.y, "container", spot.slot, spot.big)
		-- (A machine's upgrade slots show the card's outline while empty.)
		local ghost = spot.ghost
		if ghost then
			addGhost(widget, ghost)
		end
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
	local energy = layout.energy
	if energy then
		-- Mekanism's vertical power bar: a sunken frame, filling from the bottom.
		local frame = Style.inset(panel, energy.x - 1, energy.y - 1, energy.w + 2, energy.h + 2, 5, Color3.new(0, 0, 0))
		local fill = Style.frame(frame, 1, 1 + energy.h, energy.w, 0, Color3.new(0, 1, 0), 3)
		self.energyBar = { frame = frame, fill = fill, rect = energy, shown = -1, colour = "" }
	end
	local status = layout.status
	if status then
		local label = Style.text(panel, "", status.x, status.y, WIDTH - status.x - 16, 8, Style.Colour.Title, 5)
		-- (A long line ends in "..." before the energy bar instead of running under it.)
		label.TextTruncate = Enum.TextTruncate.AtEnd
		self.statusLabel = label
	end
	for _, at in layout.lines do
		local label = Style.text(panel, "", at.x, at.y, WIDTH - at.x - 16, 8, Style.Colour.Title, 5)
		label.TextTruncate = Enum.TextTruncate.AtEnd
		table.insert(self.lineLabels, label)
	end
	for _, spot in layout.tanks do
		-- Mekanism's GuiFluidGauge: a sunken frame, the fluid filling it from the bottom, the
		-- scale's marks over it (a long one every quarter, short ones between).
		local rect = spot.frame
		local frame = Style.inset(panel, rect.x, rect.y, rect.w, rect.h, 5, TANK_BACK)
		local inner = spot.inner
		local fill = Style.frame(frame, 1, 1 + inner.h, inner.w, 0, TANK_BACK, 3)
		for mark = 1, TANK_MARKS - 1 do
			local long = mark % 2 == 0
			local y = 1 + math.floor(inner.h * mark / TANK_MARKS)
			local w = if long then TANK_MARK_LONG else TANK_MARK_SHORT
			local line = Style.frame(frame, 1 + inner.w - w, y, w, 1, TANK_MARK_COLOUR, 4)
			line.BackgroundTransparency = TANK_MARK_TRANSPARENCY
		end
		table.insert(self.tankGauges, { frame = frame, fill = fill, spot = spot, shown = -1, fluid = -1 })
	end
	self.layout = layout
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
		self.layout = nil
		self.energyBar = nil
		self.statusLabel = nil
		self.lineLabels = {}
		self.tankGauges = {}
		self.machineData = nil
		self.machineShown = false
		if panelContainer then
			buildPanel(self, panelContainer)
		end
	end
	-- The 2 x 2 grid only belongs to window 0; other windows show the player's name there. So does
	-- the equipment panel.
	local grid = MenuLayout.showsGrid(container)
	if grid ~= self.gridShown then
		self.gridShown = grid
		self.gridGroup.Visible = grid
		self.nameLabel.Visible = not grid
	end
	if grid ~= self.equipShown then
		self.equipShown = grid
		self.equipPanel.Visible = grid
	end
	self.width = if grid then WIDTH + GAP + EQUIP_W else WIDTH
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
	self.equipPanel.Position = UDim2.fromOffset(WIDTH + GAP, top)
	self.height = top + PLAYER_HEIGHT
	self.root.Size = UDim2.fromOffset(self.width, self.height)
	-- Window slots for this layout (only the container's size matters).
	assignIndices(self, { id = 0, inventory = Types.newInventory(), container = container })
end

-- A machine's tank gauges from its `data` (MenuLayout.tankRows / tankFluid / tankColour).
local function renderTanks(self: Self, data: { number }?)
	for _, gauge in self.tankGauges do
		local spot = gauge.spot
		local rows = MenuLayout.tankRows(data, spot)
		local fluid = MenuLayout.tankFluid(data, spot)
		if rows ~= gauge.shown then
			gauge.shown = rows
			gauge.fill.Position = UDim2.fromOffset(1, 1 + spot.inner.h - rows)
			gauge.fill.Size = UDim2.fromOffset(spot.inner.w, rows)
		end
		if fluid ~= gauge.fluid then
			gauge.fluid = fluid
			local rgb = MenuLayout.tankColour(fluid)
			gauge.fill.BackgroundColor3 = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
			-- (Water and fuel show a little of the gauge's back through them; lava and oil none.)
			local record = Fluids.get(fluid)
			gauge.fill.BackgroundTransparency = if record and record.light == 0 and fluid ~= Fluids.OIL then 0.1 else 0
		end
	end
end

-- A machine's energy bar from its `data` (MenuLayout.energyRows / energyColour).
local function renderEnergy(self: Self, data: { number }?)
	local bar = self.energyBar
	if bar == nil then
		return
	end
	local rect = bar.rect
	local rows = MenuLayout.energyRows(data, rect.h)
	local rgb = MenuLayout.energyColour(MenuLayout.energyFraction(data))
	local colour = `{rgb[1]},{rgb[2]},{rgb[3]}`
	if rows ~= bar.shown then
		bar.shown = rows
		bar.fill.Position = UDim2.fromOffset(1, 1 + rect.h - rows)
		bar.fill.Size = UDim2.fromOffset(rect.w, rows)
	end
	if colour ~= bar.colour then
		bar.colour = colour
		bar.fill.BackgroundColor3 = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
	end
end

--[[
	The open furnace's flame and arrow, from its `data` (MenuLayout.flameRows / arrowColumns), or a
	machine's gauges, energy bar and status line from the fields its panel names.
]]
local function renderGauges(self: Self, window: Window)
	local container = window.container
	local layout = self.layout
	if container and container.kind == "machine" and layout then
		local data = container.data
		-- (Snapshots and replays replace the data table, never change it: the same table shows
		-- the same, so nothing is worked out again every frame.)
		if self.machineShown and data == self.machineData then
			return
		end
		self.machineShown = true
		self.machineData = data
		setGauge(self.flame, MenuLayout.machineFlameRows(data, layout.flameSource), true)
		local columns = MenuLayout.machineArrowColumns(data, layout.progressSource)
		setGauge(self.progress, if columns > 0 then columns + 1 else 0, false)
		renderEnergy(self, data)
		renderTanks(self, data)
		local label = self.statusLabel
		if label then
			local text = MenuLayout.statusText(container)
			if label.Text ~= text then
				label.Text = text
			end
		end
		local labels = self.lineLabels
		if #labels > 0 then
			local texts = MenuLayout.lineTexts(container)
			for i, line in labels do
				local text = texts[i] or ""
				if line.Text ~= text then
					line.Text = text
				end
			end
		end
		return
	end
	if self.flame == nil and self.progress == nil then
		return
	end
	local data = if container and container.kind == "furnace" then container.data else nil
	setGauge(self.flame, MenuLayout.flameRows(data), true)
	-- (Minecraft draws the arrow one column wider than its progress; the art starts one in.)
	local columns = MenuLayout.arrowColumns(data)
	setGauge(self.progress, if columns > 0 then columns + 1 else 0, false)
end

-- Puts the selected item in the preview's hand (rebuilt only when it or item looks change).
local function updateHeld(self: Self, window: Window)
	local inventory = window.inventory
	local stack = inventory.slots[inventory.selected]
	local item = if stack and stack.count > 0 then stack.item else nil
	local look = ItemModels.generation()
	if item == self.heldItem and look == self.heldLook then
		return
	end
	self.heldItem = item
	self.heldLook = look
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

--[[
	The crafting result the recipe gate keeps back from `window`'s grid (Window `recipes`): what the
	grid matches while the result slot is empty and the gate refuses it. Its item, count and why;
	nil when there is none. Matched again only when a grid stack or the progression changed.
]]
local function lockedResult(self: Self, window: Window): (number?, number, string?)
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

-- Is `widget` the open crafting grid's result slot?
local function isResultWidget(widget: SlotWidget, window: Window): boolean
	return widget.store == "container" and widget.index == Types.CRAFT_RESULT and Types.craftWidth(window.container) > 0
end

-- The eyes (open or shut by the `hidden` bits) and the closed accessory rows' padlocks.
local function renderEquipment(self: Self, window: Window)
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
		for row, lock in self.locks do
			lock.Visible = row > open
		end
	end
end

--[[
	Dresses the preview in what the character shows (Player/EquipmentLooks.dress), again only when
	an armor or equipment stack, the hidden bits or the open slots changed (compared by table:
	stacks are values) and the looks text with them.
]]
local function updateLooks(self: Self, window: Window)
	local clone = self.clone
	if clone == nil then
		return
	end
	local inventory = window.inventory
	local refs = self.looksRefs
	local changed = false
	local i = 0
	for slot = 1, Types.ARMOR_SIZE do
		i += 1
		if refs[i] ~= inventory.armor[slot] then
			refs[i], changed = inventory.armor[slot], true
		end
		i += 1
		if refs[i] ~= inventory.vanityArmor[slot] then
			refs[i], changed = inventory.vanityArmor[slot], true
		end
	end
	for slot = 1, Types.ACCESSORY_SIZE do
		i += 1
		if refs[i] ~= inventory.accessories[slot] then
			refs[i], changed = inventory.accessories[slot], true
		end
		i += 1
		if refs[i] ~= inventory.vanityAccessories[slot] then
			refs[i], changed = inventory.vanityAccessories[slot], true
		end
	end
	i += 1
	if refs[i] ~= inventory.hidden then
		refs[i], changed = inventory.hidden, true
	end
	i += 1
	if refs[i] ~= inventory.accessorySlots then
		refs[i], changed = inventory.accessorySlots, true
	end
	if not changed and self.looksText ~= nil then
		return
	end
	local looks = Accessories.looks(inventory)
	if looks == self.looksText then
		return
	end
	self.looksText = looks
	local old = self.looksFolder
	if old then
		old:Destroy()
	end
	self.looksFolder = EquipmentLooks.dress(clone, looks)
end

-- Draws `window`; `hover` gets the white overlay, so do the slots of a drag in progress.
function InventoryScreen.render(self: Self, window: Window, hover: Target?, dragged: { [number]: boolean })
	updateHeld(self, window)
	local hovered = if hover and hover.kind == "slot" then hover.index else -1
	local function draw(widget: SlotWidget)
		local stack = Menu.get(window, widget.window)
		if stack == nil and widget.window >= 0 and isResultWidget(widget, window) then
			-- (A locked result: greyed, never taken.)
			local item, count = lockedResult(self, window)
			widget.view.icon:set(item, count)
			widget.view.icon:setDimmed(item ~= nil)
		else
			widget.view.icon:set(
				stack and stack.item,
				stack and stack.count,
				stack and stack.damage,
				stack and stack.data
			)
			widget.view.icon:setDimmed(false)
		end
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
	if self.equipShown then
		for _, widget in self.equipmentSlots do
			draw(widget)
		end
		renderEquipment(self, window)
	end
	updateLooks(self, window)
	renderGauges(self, window)
end

-- What is under `point` (screen pixels): a slot, nil over a panel, or outside.
function InventoryScreen.targetAt(self: Self, point: Vector2): Target?
	-- (An eye is a button of its own: no slot click under it.)
	if self.equipShown then
		for _, eye in self.eyes do
			if Style.contains(eye.button, point) then
				return nil
			end
		end
	end
	for _, list in { self.containerSlots, self.gridSlots, self.playerSlots, self.equipmentSlots } do
		for _, widget in list do
			if widget.window >= 0 and Style.contains(widget.view.button, point) then
				return { kind = "slot", index = widget.window }
			end
		end
	end
	local container = self.containerPanel
	if
		Style.contains(self.playerPanel, point)
		or (container and Style.contains(container, point))
		or Style.contains(self.equipPanel, point)
	then
		return nil
	end
	for _, frame in self.tabFrames do
		if Style.contains(frame, point) then
			return nil
		end
	end
	return { kind = "outside" }
end

--[[
	A tooltip for what is under `point` besides items: a locked crafting result ("Iron Pickaxe",
	"Requires the Iron Age"), a machine's energy bar ("1.2 kJ / 20 kJ"), a tank gauge ("Lava:
	5,000 mB", "Capacity: 24,000 mB").
]]
function InventoryScreen.tooltipAt(self: Self, point: Vector2, window: Window): { string }?
	-- A locked crafting result: its name and what it needs.
	for _, list in { self.containerSlots, self.gridSlots } do
		for _, widget in list do
			if widget.window >= 0 and isResultWidget(widget, window) and Style.contains(widget.view.button, point) then
				local item, _, text = lockedResult(self, window)
				if item and text then
					return { Items.displayName(item), text }
				end
			end
		end
	end
	-- The equipment: a closed accessory row says when it opens; an eye what it does.
	if self.equipShown then
		for row, lock in self.locks do
			if lock.Visible and Style.contains(lock, point) then
				local age = Ages.byId(Config.Accessories.ExtraSlotAges[row - Types.BASE_ACCESSORY_SLOTS] or "")
				return { if age then `Opens at the {age.name}` else "Closed" }
			end
		end
		for _, eye in self.eyes do
			if Style.contains(eye.button, point) then
				local what = if eye.slot > Types.HIDE_ARMOR then "armor piece" else "accessory"
				return { if eye.shut.Visible then `Show this {what}` else `Hide this {what}` }
			end
		end
	end
	local bar = self.energyBar
	local container = window.container
	if bar and container and Style.contains(bar.frame, point) then
		return { MenuLayout.energyTooltip(container.data) }
	end
	if container then
		for _, gauge in self.tankGauges do
			if Style.contains(gauge.frame, point) then
				return MenuLayout.tankTooltip(container.data, gauge.spot)
			end
		end
	end
	return nil
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
	-- (Dressed by the next render.)
	table.clear(self.looksRefs)
	self.looksText = nil
	self.looksFolder = nil
end

function InventoryScreen.closed(self: Self)
	local clone = self.clone
	if clone then
		clone:Destroy()
		self.clone = nil
	end
	self.heldModel = nil
	self.heldItem = false
	self.looksFolder = nil
	self.looksText = nil
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

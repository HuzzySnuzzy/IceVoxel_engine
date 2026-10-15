--!strict
--[[
	The survival inventory screen (also creative's inventory tab), in the inventory family's dark
	survival look (Ui/Theme, Style.Dayz). Ui/InventoryColumns lays it out and picks its scale; this
	module builds the pieces once, places them when the layout changes, draws the window every
	frame and hit-tests (screen pixels, the InputObject.Position space). Wide, three columns over a
	band; narrow (small screens), the two side columns:

	  VICINITY   (left) a grey top header (with the creative "items" button while the creative tabs
	             are shown), the GROUND strip (Ui/GroundStrip: dropped items nearby; the only place
	             inside the screen that throws), then CRAFTING (window 0's 2 x 2 grid, a chevron,
	             its result) or the open block's section (Ui/ContainerPanel: a chest's "CHEST
	             (n/27)", a crafting table, a furnace, a machine, its picture the block's icon),
	             then ITEMS: JEI's list docked in its body (`jeiDock`; Ui/Jei)
	  centre     (wide) the player, unboxed (Ui/PlayerPreview, turning towards the pointer), over
	             HANDS: a grey header, the held item's name on a black bar with its condition dot,
	             the item large (a slot of its own: the selected hotbar slot), its condition word
	             and one detail line (Theme.handsLines: durability, sips, a stack's count, energy;
	             a firearm's or a magazine's rounds, Shared/Weapons/WeaponState.detail). A held
	             firearm shows what is in it as chips beside the item (the weapons design's 9.5):
	             MAG and OPTIC left of it, MUZZLE and LIGHT right of it, each only while that
	             part is in, named by the part when its name fits the chip (else by the slot),
	             with its condition dot when it wears (the magazine, a suppressor). A click on a
	             chip takes the part off (Inventory action "weapon" op 6, detach, on the held
	             slot: Shared/Weapons/Loading puts it onto the cursor when that is empty, else
	             into the inventory) with the item.firearm.unload sound; resting on one shows
	             its name and condition (`tooltipAt`)
	  EQUIPMENT  (right) a grey top header with the gear (the Options menu) and, on touch, the
	             close button; a strip of the worn armor over the accessories (window 0; other
	             windows the armor alone), each empty one showing its silhouette, closed accessory
	             slots shaded under a padlock, an eye per accessory hiding its look (in the slot's
	             corner on a mouse, a finger's button under it on touch); BACKPACK (n/27): the 27
	             inventory slots; VANITY (window 0): the vanity armor (an eye each) and vanity
	             accessories, fainter silhouettes with a corner mark
	  band       the window's nine hotbar slots as the quickbar (Style.Dayz quick cells, each slot
	             inside its cell under the number box (Style.Dayz.quickSlot), the selected one olive
	             under an outline, number boxes from the Hotbar Slot key bindings: hidden on touch
	             and while too small to read), the status icons docked at its right (`statusRect`,
	             Ui/StatusDock; survival-like modes only)

	Behind the side columns (wide) two dark strips run from the screen's edges to 3 GUI pixels
	past them. Every root of the family is marked for the look (Ui/Screens), so button tooltips
	here draw the dark box.

	Sections: CRAFTING, the block's, ITEMS, BACKPACK and VANITY collapse to their bar when it is
	clicked (Ui/HoverTip "inventory.section" says what a click does), per section for the
	session; VANITY starts collapsed on touch screens. A collapsed or absent section's slots are not
	live (SlotWidgets: window -1, hidden, not Selectable): no click or gamepad selection reaches
	them, and the layout gives their room to ITEMS and the character. A collapsed section still
	counts what it holds in its title ("BACKPACK (12/27)": InventoryColumns.used reads the window,
	not the drawn slots), and a collapsed block's gauges say nothing (their frames stay where the
	body was, over ITEMS).

	Slots are Ui/SlotWidgets (faces, outlines, ghosts, locks, eyes, the locked crafting result):
	clicks are Ui/SlotClicks, driven by Ui/Screens, and Inventory/Menu applies the rules of each
	slot; slots map to window slots by the window layout of Inventory/Types. While a stack is
	carried the hovered slot's outline takes the drag feedback colour (`setFeedback`, from
	Theme.feedback) and the GROUND strip is outlined as the drop place.

	What is under a point (`targetAt`): a live slot; over the GROUND strip (its items included) or
	outside the screen's root, `outside` (a carried stack is thrown); anywhere else inside the root
	(headers, buttons, eyes, section bodies, gauges, gaps, the character, the band) nothing.
	`tooltipAt` covers what is no item: a locked crafting result ("Requires the Iron Age"), a closed
	accessory slot ("Opens at the Industrial Age"), a machine's energy bar and tanks (only while the
	block's section is open), a ground item (its name, count and "Walk over it to pick it up").

	Ui/Screens' layout hooks (each optional on the type, all here):

	  place       lays the screen out for the screens GUI's size (InventoryColumns.place and
	              arrange), positions the root (its UIScale is Screens'), rebuilds what the layout
	              changed, re-scales strokes and text weights; returns the GUI scale. Nothing is
	              built while the view, the block, the collapsed sections, the equipment and the
	              recipe view are what they were (one compare, no allocation).
	  jeiDock     ITEMS' body for JEI's list (x, y screen pixels; w, h GUI pixels), the same table
	              until the layout changes; false while ITEMS is collapsed.
	  jeiViewX    the recipe view's centre: over the centre and right columns (narrow: the right).
	  statusRect  the band's status place (absolute screen pixels) and the scale.
	  effectsRect the band's effect icons' place (absolute screen pixels) and the scale: Ui/EffectHud
	              draws every running effect there while the inventory shows (Ui/Screens.
	              effectsDock), as a side list would not fit beside the screen. Under the recipe
	              view it is the band's row under the VICINITY column (InventoryColumns'
	              viewEffects), left of the view, so the effects stay in sight while browsing.
	  setViewing  the recipe view opened: the centre, the right column, the band and the strips
	              hide; the VICINITY column stays, drawn every frame (Screens keeps calling
	              `render`, with no hover) but inert: Screens routes no clicks under the view, and
	              its section bars, "items" button, GROUND strip and slots take no click of their
	              own and no gamepad selection (and, not Active, the bars and the button show no
	              Ui/HoverTip tooltip).
	  setFeedback the drag feedback for the hovered slot (every frame while carrying, nil after).
	  inDropZone  over the GROUND strip (a touch tap there does not close the screen).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Ages = require(Shared.Progression.Ages)
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Menu = require(Shared.Inventory.Menu)
local Types = require(Shared.Inventory.Types)
local Weapons = require(Shared.Weapons)
local Loading = require(Shared.Weapons.Loading)
local WeaponState = require(Shared.Weapons.WeaponState)

local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local Keybinds = require(script.Parent.Parent.Settings.Keybinds)
local ContainerPanel = require(script.Parent.ContainerPanel)
local GroundStrip = require(script.Parent.GroundStrip)
local HoverTip = require(script.Parent.HoverTip)
local HudLayout = require(script.Parent.HudLayout)
local InventoryColumns = require(script.Parent.InventoryColumns)
local ItemIcon = require(script.Parent.ItemIcon)
local MenuLayout = require(script.Parent.MenuLayout)
local PlayerPreview = require(script.Parent.PlayerPreview)
local SlotClicks = require(script.Parent.SlotClicks)
local SlotWidgets = require(script.Parent.SlotWidgets)
local Style = require(script.Parent.Style)
local Theme = require(script.Parent.Theme)

type Window = Types.Window
type Target = SlotClicks.Target
type Arrangement = InventoryColumns.Arrangement
type Kind = InventoryColumns.Kind

local Dayz = Style.Dayz
local Size = Theme.Size
local BIT = InventoryColumns.BIT

-- The worn slots' silhouettes (Ui/Silhouettes names), armor 1..4 and every accessory.
local ARMOR_GHOSTS = { "head", "chest", "legs", "feet" }
local ACCESSORY_GHOST = "accessory"

--[[
	Where the screens' GUI is, for `place` (Ui/Screens keeps one table and updates its fields): its
	AbsoluteSize (screen pixels, the device's safe area), Roblox's top bar (GuiService:GetGuiInset().Y),
	the GUI scale (UiScale.base) and whether the screen is a touch screen (UiScale.touch).
]]
export type View = { w: number, h: number, top: number, base: number, touch: boolean }
-- A rectangle: x, y and w, h (see each member for its units).
export type Rect = { x: number, y: number, w: number, h: number }

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

	--[[
		The survival look's members (Ui/Screens uses each only when it is there):

		  place       lays the screen out for `view` and positions the root (Screens keeps
		              setting the root's UIScale to what it returns); returns the GUI scale.
		              Cheap when nothing changed.
		  jeiDock     where JEI's item list goes: x, y the top left in screen pixels, w, h GUI
		              pixels; false while ITEMS is collapsed or too small. The same table until
		              the layout changes.
		  jeiViewX    the recipe view's centre x (screen pixels), nil for the default.
		  statusRect  where the status icons dock (absolute screen pixels) and the GUI scale, or
		              nil (Ui/StatusDock).
		  effectsRect where the effect icons go (absolute screen pixels) and the GUI scale, or nil
		              (Ui/Screens.effectsDock, read by Ui/EffectHud).
		  setViewing  the recipe view opened (true) or closed: the screen hides what it covers.
		  setFeedback what the carried stack would do over the hovered target (Theme.feedback),
		              every frame while carrying and once with nil after.
		  inDropZone  is `point` (screen pixels) over the place items are thrown? A touch tap
		              there with nothing carried does not close the screen.
	]]
	place: ((self: InventoryScreen, view: View) -> number)?,
	jeiDock: ((self: InventoryScreen) -> Rect | false)?,
	jeiViewX: ((self: InventoryScreen) -> number?)?,
	statusRect: ((self: InventoryScreen) -> (Rect?, number))?,
	effectsRect: ((self: InventoryScreen) -> (Rect?, number))?,
	setViewing: ((self: InventoryScreen, viewing: boolean) -> ())?,
	setFeedback: ((self: InventoryScreen, feedback: Theme.Feedback?) -> ())?,
	inDropZone: ((self: InventoryScreen, point: Vector2) -> boolean)?,
}

--[[
	HANDS' chips (see the header): which detach part (Shared/Weapons/Loading.Part) each one takes
	off, the held firearm's data that holds it, and the slot's name it shows when the part's own
	name does not fit.
]]
type ChipSpec = { part: number, key: string, label: string }
local CHIPS: { ChipSpec } = {
	{ part = Loading.Part.Magazine, key = "mag", label = "MAG" },
	{ part = Loading.Part.Optic, key = "optic", label = "OPTIC" },
	{ part = Loading.Part.Muzzle, key = "muzzle", label = "MUZZLE" },
	{ part = Loading.Part.Light, key = "light", label = "LIGHT" },
}
-- A chip's height, its gap from the item and the HANDS edge, and between its two rows (GUI pixels).
local CHIP_H = 10
local CHIP_GAP = 2

-- A chip: its button, condition dot and text, the part it shows (nil: hidden) and that part's
-- wear, and the width it was placed at.
type Chip = {
	spec: ChipSpec,
	button: TextButton,
	dot: Frame,
	text: TextLabel,
	item: number?,
	wear: number,
	width: number,
}

-- HANDS' texts and its item.
type Hands = {
	header: Style.TopHeader,
	section: Style.Section,
	bar: Frame,
	dot: Frame,
	name: TextLabel,
	condition: TextLabel,
	detail: TextLabel,
	holder: Frame,
	widget: SlotWidgets.SlotWidget,
	-- A held firearm's parts (MAG, OPTIC, MUZZLE, LIGHT).
	chips: { Chip },
	-- The held stack its texts show (compared by value: a drag preview copies stacks).
	item: number?,
	count: number,
	damage: number?,
	data: any,
}

-- The band: its quick cells and slot widgets (hotbar 1..9), the selection outline.
type Band = {
	frame: Frame,
	cells: { Style.QuickCell },
	widgets: { SlotWidgets.SlotWidget },
	selection: Frame,
	numbers: { string },
	selected: number,
}

type Self = InventoryScreen & {
	scaled: Style.Scaled,
	handsScaled: Style.Scaled,
	widgets: SlotWidgets.SlotWidgets,
	left: Style.TopHeader,
	right: Style.TopHeader,
	itemsButton: TextButton,
	gear: TextButton,
	close: TextButton,
	-- The sections by InventoryColumns kind (the block's while one is open).
	sections: { [string]: Style.Section },
	hands: Hands,
	ground: GroundStrip.GroundStrip,
	preview: PlayerPreview.PlayerPreview,
	band: Band,
	strips: { Frame },
	-- The eyes of the worn strip's accessories and of VANITY's armor, in slot order.
	accessoryEyes: { SlotWidgets.Eye },
	vanityEyes: { SlotWidgets.Eye },
	-- The open block: its panel, picture icon, key and MenuLayout panel; its slot count shown.
	panel: ContainerPanel.ContainerPanel?,
	picture: ItemIcon.ItemIcon?,
	panelKey: string,
	containerSize: number,
	containerCount: number,
	backpackCount: number,
	-- The window's layout the widgets' slots are numbered by (only its container's size matters).
	layoutWindow: Window,
	gridShown: boolean,
	equipShown: boolean,
	tabsShown: boolean,
	viewing: boolean,
	collapsed: number,
	-- Whether VANITY was opened or closed by hand (else it follows the input: closed on touch).
	vanityChosen: boolean,
	touch: boolean,
	-- The layout and what it was made for (place's key).
	arrangement: Arrangement?,
	scale: number,
	keyW: number,
	keyH: number,
	keyTop: number,
	keyBase: number,
	keyTouch: boolean,
	keyPanel: string,
	keyCollapsed: number,
	keyEquip: boolean,
	keyViewing: boolean,
	wide: InventoryColumns.Input,
	narrow: InventoryColumns.Input,
	-- Which widget groups are live (SlotWidgets.assign), kept and updated.
	live: { [string]: boolean },
	dock: Rect | false,
	viewX: number?,
	status: Rect?,
	effects: Rect?,
	viewEffects: Rect?,
	width: number,
	height: number,
	lastPoint: Vector2?,
}

local InventoryScreen = {}
InventoryScreen.__index = InventoryScreen

-- The quickbar number box text of hotbar slot `i`: its key binding's name when short enough
-- (HudLayout.quickKey, as the HUD's quickbar shows it).
local function numberOf(i: number): string
	return HudLayout.quickKey(Keybinds.name(`hotbar{i}`))
end

-- Makes `section` collapse (its `bit`) when its bar is clicked; its tooltip says what a click does.
local function collapsible(self: Self, section: Style.Section, bit: number)
	section.header.Activated:Connect(function()
		-- (Under the recipe view the VICINITY column takes nothing.)
		if self.viewing then
			return
		end
		SoundPlayer.click()
		if bit == BIT.vanity then
			self.vanityChosen = true
		end
		self.collapsed = bit32.bxor(self.collapsed, bit)
	end)
	HoverTip.attach(section.header, "inventory.section", function(): string?
		return if section.collapsed then "expand" else "collapse"
	end)
end

-- A section of the screen (see Style.Dayz.section) registered by `kind`.
local function newSection(self: Self, kind: Kind, title: string, options: Style.SectionOptions): Style.Section
	options.scaled = self.scaled
	local section = Dayz.section(self.root, title, options)
	self.sections[kind] = section
	local bit = (BIT :: any)[kind]
	if options.collapsible and bit then
		collapsible(self, section, bit)
	end
	return section
end

-- Grid lines and slots for `spots` (InventoryColumns) in `body`, in widget group `group`.
local function addSlots(self: Self, body: Frame, group: string, spots: { InventoryColumns.Spot }, lines: boolean)
	if lines then
		Dayz.lines(body, InventoryColumns.gridLines(spots), 1)
	end
	local made: { SlotWidgets.SlotWidget } = {}
	for _, spot in spots do
		table.insert(made, self.widgets:slot(body, group, spot.x, spot.y, spot.store, spot.slot, spot.big, self.scaled))
	end
	return made
end

-- The worn strip and VANITY (built once; window 0 shows the accessories and VANITY).
local function buildEquipment(self: Self)
	local input = { equipment = true, touch = false } :: any
	local strip = newSection(self, "equipment", "", { face = "strip" })
	for _, spot in InventoryColumns.spots("equipment", input) do
		local group = if spot.store == "armor" then "equipment" else "accessories"
		local widget = self.widgets:slot(strip.body, group, spot.x, spot.y, spot.store, spot.slot, false, self.scaled)
		if spot.store == "armor" then
			self.widgets:ghost(widget, ARMOR_GHOSTS[spot.slot], false)
		else
			self.widgets:ghost(widget, ACCESSORY_GHOST, false)
			self.widgets:lock(widget)
			table.insert(self.accessoryEyes, self.widgets:eye(strip.body, "accessories", spot.slot))
		end
	end
	local vanity = newSection(self, "vanity", "Vanity", { face = "strip", collapsible = true, glyph = "vanity" })
	for _, spot in InventoryColumns.spots("vanity", input) do
		local widget =
			self.widgets:slot(vanity.body, "vanity", spot.x, spot.y, spot.store, spot.slot, false, self.scaled)
		if spot.store == "vanityArmor" then
			self.widgets:ghost(widget, ARMOR_GHOSTS[spot.slot], true)
			table.insert(self.vanityEyes, self.widgets:eye(vanity.body, "vanity", Types.HIDE_ARMOR + spot.slot))
		else
			self.widgets:ghost(widget, ACCESSORY_GHOST, true)
		end
	end
end

-- HANDS: the grey header over the body (its name bar, the item, its condition and detail).
local function buildHands(self: Self): Hands
	local header = Dayz.topHeader(self.root, "Hands", 3, self.scaled)
	local section = Dayz.section(self.root, "", { face = "hands", scaled = self.scaled })
	local body = section.body
	local bar = Style.frame(body, 0, 0, 0, Size.SECTION_HEADER, Dayz.Colour.SectionHeader, 2)
	bar.Name = "NameBar"
	bar.BackgroundTransparency = Dayz.Alpha.SectionHeader
	local dot = Dayz.dot(bar, 0, 0, Size.DOT, 3)
	dot.Visible = false
	local name = Dayz.label(
		bar,
		"",
		0,
		0,
		0,
		Size.SECTION_HEADER,
		"body",
		Dayz.Colour.Text,
		3,
		Enum.TextXAlignment.Center,
		self.scaled
	)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	local condition =
		Dayz.label(body, "", 0, 0, 0, 0, "small", Dayz.Colour.Text, 3, Enum.TextXAlignment.Center, self.scaled)
	local detail =
		Dayz.label(body, "", 0, 0, 0, 0, "small", Dayz.Colour.TextSoft, 3, Enum.TextXAlignment.Center, self.scaled)
	-- The item: a 16 px slot blown up to the item's size by its own UIScale.
	local holder = Instance.new("Frame")
	holder.Name = "Held"
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.Size = UDim2.fromOffset(Style.ITEM, Style.ITEM)
	holder.ZIndex = 3
	holder.Parent = body
	local scale = Instance.new("UIScale")
	scale.Scale = Size.BIG_FACE / Style.ITEM
	scale.Parent = holder
	local widget = self.widgets:slot(holder, "hands", 0, 0, "inventory", 1, false, self.handsScaled)
	-- A held firearm's chips (placed with the layout, shown with the parts that are in).
	local chips: { Chip } = {}
	for _, spec in CHIPS do
		local button = Dayz.button(body, "", 0, 0, 0, CHIP_H, 4, self.scaled)
		button.Name = "Chip"
		button.Visible = false
		local chipDot = Dayz.dot(button, 2, (CHIP_H - Size.DOT) // 2, Size.DOT, 3)
		chipDot.Visible = false
		local text = Dayz.label(
			button,
			spec.label,
			0,
			0,
			0,
			CHIP_H,
			"tiny",
			Dayz.Colour.TextSoft,
			3,
			Enum.TextXAlignment.Center,
			self.scaled
		)
		text.TextTruncate = Enum.TextTruncate.AtEnd
		local chip: Chip = {
			spec = spec,
			button = button,
			dot = chipDot,
			text = text,
			item = nil,
			wear = 0,
			width = 0,
		}
		button.Activated:Connect(function()
			if self.viewing or chip.item == nil then
				return
			end
			-- (The held gun by its window slot: Weapons/Loading's detach.)
			local window = ClientInventory.window()
			local slot = Menu.windowIndex(window, "inventory", window.inventory.selected)
			local action: Types.Action =
				{ kind = "weapon", op = Loading.Op.Detach, slot = slot or -1, part = spec.part }
			if slot and ClientInventory.allows(action) then
				SoundPlayer.playFlat("item.firearm.unload")
				ClientInventory.apply(action)
			end
		end)
		table.insert(chips, chip)
	end
	return {
		header = header,
		section = section,
		bar = bar,
		dot = dot,
		name = name,
		condition = condition,
		detail = detail,
		holder = holder,
		widget = widget,
		chips = chips,
		item = nil,
		count = 0,
		damage = nil,
		data = nil,
	}
end

-- The condition of a chip's part (nil: the part doesn't wear: an optic, the light).
local function chipCondition(chip: Chip): Theme.Condition?
	local item = chip.item
	local def = if item then Items.get(item) else nil
	if item == nil or def == nil or def.durability == nil then
		return nil
	end
	return Theme.condition(WeaponState.fraction(item, chip.wear))
end

-- A shown chip's dot and text: the part's name when it fits beside the dot, else the slot's.
local function paintChip(chip: Chip)
	local item = chip.item
	if item == nil then
		return
	end
	local condition = chipCondition(chip)
	chip.dot.Visible = condition ~= nil
	if condition then
		chip.dot.BackgroundColor3 = Color3.fromRGB(condition.rgb[1], condition.rgb[2], condition.rgb[3])
	end
	local left = if condition then Size.DOT + 3 else 1
	local room = math.max(0, chip.width - left - 1)
	local name = Items.displayName(item)
	chip.text.Text = if Dayz.measure(name, Theme.Text.tiny) <= room then name else chip.spec.label
	chip.text.Position = UDim2.fromOffset(left, 0)
	chip.text.Size = UDim2.fromOffset(room, CHIP_H)
end

--[[
	Places HANDS' chips beside its item (`parts`: InventoryColumns.hands): MAG and OPTIC in two
	rows left of it, MUZZLE and LIGHT right of it, each as wide as the room between the item and
	the edge.
]]
local function placeChips(hands: Hands, parts: InventoryColumns.HandsLayout)
	local item = parts.item
	local width = math.max(0, item.x - 2 * CHIP_GAP)
	for index, chip in hands.chips do
		local row = (index - 1) % 2
		local x = if index <= 2 then CHIP_GAP else item.x + item.w + CHIP_GAP
		chip.width = width
		chip.button.Position = UDim2.fromOffset(x, item.y + 1 + row * (CHIP_H + CHIP_GAP))
		chip.button.Size = UDim2.fromOffset(width, CHIP_H)
		paintChip(chip)
	end
end

-- The chips of the held `stack` (all hidden for anything that is no firearm).
local function renderChips(hands: Hands, stack: Types.Stack?)
	local gun = stack ~= nil and Weapons.firearm(stack.item) ~= nil
	for _, chip in hands.chips do
		local item: number?, wear = nil, 0
		if gun and stack then
			local key = chip.spec.key
			if key == "mag" then
				item, wear = WeaponState.magazine(stack)
			elseif key == "optic" or key == "muzzle" or key == "light" then
				item, wear = WeaponState.attachment(stack, key)
			end
		end
		chip.item, chip.wear = item, wear
		chip.button.Visible = item ~= nil
		paintChip(chip)
	end
end

-- The band: nine quick cells with the hotbar's slots over them, and the selection outline.
local function buildBand(self: Self): Band
	local frame = Instance.new("Frame")
	frame.Name = "Quickbar"
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.ZIndex = 2
	frame.Parent = self.root
	local cells: { Style.QuickCell } = {}
	local made: { SlotWidgets.SlotWidget } = {}
	local numbers: { string } = {}
	for i = 1, Types.HOTBAR_SIZE do
		local cell = Dayz.quickCell(frame, 0, 0, 2, self.scaled)
		-- The slot inside its cell, at the cell's layers (Style.Dayz.quickSlot): its picture over
		-- the face and under the number box, its hover outline over the box. (Made beside the
		-- cells, the slot's picture would draw over the whole cell, number box included.)
		local widget = self.widgets:slot(cell.base, "band", 1, 1, "inventory", i, false, self.scaled)
		Dayz.quickSlot(cell, widget.view.button, widget.view.hover)
		widget.quick = true
		widget.face = cell.face
		table.insert(cells, cell)
		table.insert(made, widget)
		table.insert(numbers, numberOf(i))
	end
	local selection = Instance.new("Frame")
	selection.Name = "Selected"
	selection.BackgroundTransparency = 1
	selection.BorderSizePixel = 0
	selection.Size = UDim2.fromOffset(Size.PITCH, Size.PITCH)
	selection.ZIndex = 9
	selection.Parent = frame
	Dayz.outline(selection, nil, nil, self.scaled)
	return { frame = frame, cells = cells, widgets = made, selection = selection, numbers = numbers, selected = 0 }
end

function InventoryScreen.new(parent: Instance): InventoryScreen
	local root = Instance.new("Frame")
	root.Name = "Inventory"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.AnchorPoint = Vector2.zero
	root.Size = UDim2.fromOffset(InventoryColumns.LEFT_W, InventoryColumns.MAX_HEIGHT)
	root.Visible = false
	root.Parent = parent

	local function input(mode: InventoryColumns.Mode): InventoryColumns.Input
		return {
			mode = mode,
			touch = false,
			top = Size.TOP_HEADER,
			container = nil,
			panel = nil,
			equipment = true,
			collapsed = 0,
			height = nil,
			centreW = nil,
		}
	end

	local self = (
		setmetatable({
			root = root,
			onTab = function() end,
			onClose = function() end,
			onSettings = function() end,
			scaled = Dayz.scaled(),
			handsScaled = Dayz.scaled(),
			widgets = SlotWidgets.new(),
			sections = {},
			strips = {},
			accessoryEyes = {},
			vanityEyes = {},
			panel = nil,
			picture = nil,
			panelKey = "",
			containerSize = 0,
			containerCount = -1,
			backpackCount = -1,
			layoutWindow = Types.newWindow(Types.newInventory()),
			gridShown = true,
			equipShown = true,
			tabsShown = false,
			viewing = false,
			collapsed = 0,
			vanityChosen = false,
			touch = false,
			arrangement = nil,
			scale = 1,
			keyW = -1,
			keyH = -1,
			keyTop = -1,
			keyBase = -1,
			keyTouch = false,
			keyPanel = "",
			keyCollapsed = -1,
			keyEquip = false,
			keyViewing = false,
			wide = input("wide"),
			narrow = input("narrow"),
			live = {},
			dock = false,
			viewX = nil,
			status = nil,
			effects = nil,
			viewEffects = nil,
			width = InventoryColumns.LEFT_W,
			height = InventoryColumns.MAX_HEIGHT,
			lastPoint = nil,
		}, InventoryScreen) :: any
	) :: Self

	-- The dark strips behind the side columns (wide), from the screen's edges.
	for _ = 1, 2 do
		local strip = Style.frame(root, 0, 0, 0, 0, Dayz.Colour.SideStrip, 0)
		strip.Name = "SideStrip"
		strip.BackgroundTransparency = Dayz.Alpha.SideStrip
		strip.Visible = false
		table.insert(self.strips, strip)
	end

	-- The top headers and their buttons.
	self.left = Dayz.topHeader(root, "Vicinity", 3, self.scaled)
	self.right = Dayz.topHeader(root, "Equipment", 3, self.scaled)
	local items = self.left:button("items", 1, Size.HEADER_BUTTON)
	items.Visible = false
	items.Activated:Connect(function()
		if self.viewing then
			return
		end
		SoundPlayer.click()
		self.onTab()
	end)
	HoverTip.attach(items, "inventory.itemsTab")
	self.itemsButton = items
	local gear = self.right:button("gear", 1, Size.HEADER_BUTTON)
	gear.Activated:Connect(function()
		SoundPlayer.click()
		self.onSettings()
	end)
	HoverTip.attach(gear, "inventory.options")
	self.gear = gear
	local close = self.right:button("close", 1, Size.HEADER_BUTTON)
	close.Visible = false
	close.Activated:Connect(function()
		SoundPlayer.click()
		self.onClose()
	end)
	HoverTip.attach(close, "inventory.close")
	self.close = close

	-- VICINITY: the GROUND strip, CRAFTING, ITEMS (the block's section comes with setLayout).
	local ground = newSection(self, "ground", "", { face = "ground" })
	self.ground = GroundStrip.new(ground.body, self.scaled)
	local craft = newSection(self, "craft", "Crafting", { face = "grid", collapsible = true, glyph = "crafting" })
	addSlots(self, craft.body, "craft", InventoryColumns.spots("craft", self.wide), true)
	local arrow, chevron = InventoryColumns.CRAFT_ARROW, Size.CHEVRON
	Dayz.silhouette(
		craft.body,
		"chevron",
		arrow.x + (arrow.w - chevron) // 2,
		arrow.y + (arrow.h - chevron) // 2,
		chevron,
		chevron,
		Dayz.Colour.Chevron,
		Dayz.Alpha.Chevron,
		3
	)
	newSection(self, "jei", "Items", { face = "panel", collapsible = true })

	-- The centre: the player over HANDS.
	local character = newSection(self, "character", "", { face = "none" })
	self.preview = PlayerPreview.new(character.body, 2)
	self.hands = buildHands(self)
	self.sections.hands = self.hands.section

	-- EQUIPMENT: the worn strip, BACKPACK, VANITY.
	buildEquipment(self)
	local backpack = newSection(self, "backpack", "Backpack", { face = "grid", collapsible = true, glyph = "backpack" })
	addSlots(self, backpack.body, "backpack", InventoryColumns.spots("backpack", self.wide), true)

	self.band = buildBand(self)
	Keybinds.changed:Connect(function()
		for i = 1, Types.HOTBAR_SIZE do
			self.band.numbers[i] = numberOf(i)
		end
	end)

	self:setLayout(nil, false)
	return self
end

-- Size of the content in GUI pixels (the arrangement's).
function InventoryScreen.size(self: Self): Vector2
	return Vector2.new(self.width, self.height)
end

--[[ Layout ]]

-- Which widget groups are live for the arrangement and the window's layout, then the slots.
local function refreshLive(self: Self)
	local a = self.arrangement
	local live = self.live
	local function on(kind: Kind): boolean
		return a ~= nil and InventoryColumns.live(a, kind)
	end
	live.craft = self.gridShown and on("craft")
	live.container = self.panel ~= nil and on("container")
	live.backpack = on("backpack")
	live.equipment = on("equipment")
	live.accessories = self.equipShown and on("equipment")
	live.vanity = self.equipShown and on("vanity")
	live.hands = on("hands")
	live.band = a ~= nil
	self.widgets:assign(self.layoutWindow, live, self.viewing)
end

--[[
	Shows the open block's section (rebuilt only when its kind, block or size changes; window 0's
	2 x 2 grid is CRAFTING) and the creative "items" button (`tabs`, without a block).
]]
function InventoryScreen.setLayout(self: Self, container: Types.Container?, tabs: boolean)
	local panelContainer = if container and MenuLayout.hasPanel(container) then container else nil
	local key = MenuLayout.panelKey(container)
	local grid = MenuLayout.showsGrid(container)
	self.tabsShown = tabs and panelContainer == nil
	if self.itemsButton.Visible ~= self.tabsShown then
		self.itemsButton.Visible = self.tabsShown
	end
	-- (Called on every inventory change: nothing more unless the window's layout changed.)
	if key == self.panelKey and grid == self.gridShown then
		return
	end
	if key ~= self.panelKey then
		self.panelKey = key
		self.widgets:drop("container")
		local old = self.panel
		if old then
			old:destroy()
			self.panel = nil
		end
		local picture = self.picture
		if picture then
			picture:destroy()
			self.picture = nil
		end
		local section = self.sections.container
		if section then
			section:destroy()
			self.sections.container = nil :: any
		end
		self.containerCount = -1
		if panelContainer then
			local layout = MenuLayout.panel(panelContainer)
			local built = newSection(self, "container", layout.title, { face = "grid", collapsible = true })
			-- Its picture: the block's icon, at the bar's picture size.
			local holder = Instance.new("Frame")
			holder.Name = "Block"
			holder.BackgroundTransparency = 1
			holder.BorderSizePixel = 0
			holder.Size = UDim2.fromOffset(Style.ITEM, Style.ITEM)
			holder.Parent = built.picture
			local scale = Instance.new("UIScale")
			scale.Scale = Dayz.PICTURE_SCALE
			scale.Parent = holder
			local icon = ItemIcon.new(holder, 0, 0, 1, "dayz", self.scaled)
			icon:set(if Items.isValid(panelContainer.block) then panelContainer.block else nil, 1)
			self.picture = icon
			self.containerSize = panelContainer.size
			self.panel = ContainerPanel.new(built.body, layout, self.widgets, self.scaled)
		end
	end
	self.gridShown = grid
	self.equipShown = grid
	-- Window slots for this layout (only the container's size matters); no slot is live until the
	-- next `place` lays the new layout out.
	self.layoutWindow = { id = 0, inventory = Types.newInventory(), container = container }
	self.arrangement = nil
	refreshLive(self)
end

-- Makes `button` take clicks and a gamepad's selection (`on`) or not.
local function setTakes(button: GuiButton, on: boolean)
	if button.Selectable ~= on then
		button.Selectable = on
	end
	if button.Active ~= on then
		button.Active = on
	end
end

--[[
	Shows what the arrangement has (and, while the recipe view is open, only the VICINITY column,
	inert: its section bars, the "items" button and the GROUND strip take no click and no gamepad
	selection, nor show a tooltip (Ui/HoverTip says nothing for a button that is not Active), and
	its slots are not Selectable (refreshLive), since Ui/Screens routes nothing under the view).
]]
local function refreshVisibility(self: Self)
	local a = self.arrangement
	if a == nil then
		return
	end
	local viewing = self.viewing
	for kind, section in self.sections do
		local placed = a.byKind[kind :: Kind]
		local shown = placed ~= nil and (placed.column == 1 or not viewing)
		if section.root.Visible ~= shown then
			section.root.Visible = shown
		end
	end
	local hands = a.byKind.hands
	self.hands.header.root.Visible = hands ~= nil and not viewing
	self.right.root.Visible = not viewing
	self.band.frame.Visible = not viewing
	local wide = a.mode == "wide"
	for _, strip in self.strips do
		strip.Visible = wide and not viewing
	end
	for kind, section in self.sections do
		if (BIT :: any)[kind] ~= nil then
			setTakes(section.header, not viewing)
		end
	end
	setTakes(self.itemsButton, not viewing)
	setTakes(self.ground.button, not viewing)
end

-- Sizes a top header's button `button` (`size` square, `fromRight` from its right end).
local function placeButton(button: TextButton, fromRight: number, size: number)
	local position, extent = UDim2.new(1, -fromRight, 0.5, 0), UDim2.fromOffset(size, size)
	if button.Position ~= position then
		button.Position = position
	end
	if button.Size ~= extent then
		button.Size = extent
	end
end

-- Places every piece for a new arrangement `a` at placement `p` on `view`.
local function apply(
	self: Self,
	a: Arrangement,
	p: InventoryColumns.Placement,
	view: View,
	input: InventoryColumns.Input
)
	local scale = p.scale
	local root = self.root
	root.Position = UDim2.fromOffset(p.x, p.y)
	root.Size = UDim2.fromOffset(a.width, a.height)
	self.width, self.height = a.width, a.height

	-- Top headers and their buttons (touch: the header's height square, close at the far right).
	local top = input.top
	self.left:place(a.tops[1].x, a.tops[1].y, a.tops[1].w, a.tops[1].h)
	self.right:place(a.tops[2].x, a.tops[2].y, a.tops[2].w, a.tops[2].h)
	local touch = view.touch
	local size = if touch then top else Size.HEADER_BUTTON
	local inset = if touch then 0 else 1
	placeButton(self.itemsButton, inset, size)
	self.close.Visible = touch
	placeButton(self.close, inset, size)
	placeButton(self.gear, if touch then inset + size + 1 else inset, size)

	-- Sections.
	for _, placed in a.sections do
		local section = self.sections[placed.kind]
		if section then
			if placed.kind == "hands" then
				self.hands.header:place(placed.x, placed.y, placed.w, placed.header)
				section:place(placed.x, placed.y + placed.header, placed.w, 0, placed.body)
			else
				section:place(placed.x, placed.y, placed.w, placed.header, placed.body)
			end
			section:setCollapsed(placed.collapsed)
		end
	end

	-- The character and HANDS' parts.
	local character = a.byKind.character
	if character then
		self.preview:setRect(0, 0, character.w, character.body)
	end
	local handsPlaced = a.byKind.hands
	if handsPlaced then
		local parts = InventoryColumns.hands(handsPlaced.w)
		local hands = self.hands
		hands.bar.Size = UDim2.fromOffset(parts.bar.w, parts.bar.h)
		hands.dot.Position = UDim2.fromOffset(parts.dot.x, parts.dot.y)
		local room = parts.dot.x + parts.dot.w + 2
		hands.name.Position = UDim2.fromOffset(room, 0)
		hands.name.Size = UDim2.fromOffset(math.max(0, parts.bar.w - 2 * room), parts.bar.h)
		hands.holder.Position = UDim2.fromOffset(parts.item.x, parts.item.y)
		hands.condition.Position = UDim2.fromOffset(parts.condition.x, parts.condition.y)
		hands.condition.Size = UDim2.fromOffset(parts.condition.w, parts.condition.h)
		hands.detail.Position = UDim2.fromOffset(parts.detail.x, parts.detail.y)
		hands.detail.Size = UDim2.fromOffset(parts.detail.w, parts.detail.h)
		placeChips(hands, parts)
	end

	-- Eyes (a mouse's in the slots' corners, a finger's larger).
	for i, rect in InventoryColumns.eyes("equipment", input) do
		local eye = self.accessoryEyes[i]
		if eye then
			self.widgets:placeEye(eye, rect)
		end
	end
	for i, rect in InventoryColumns.eyes("vanity", input) do
		local eye = self.vanityEyes[i]
		if eye then
			self.widgets:placeEye(eye, rect)
		end
	end

	-- The band: the quickbar's cells (their slots inside), at HudLayout's cell maths from the bar.
	local band = self.band
	band.frame.Position = UDim2.fromOffset(a.band.x, a.band.y)
	band.frame.Size = UDim2.fromOffset(a.band.w, a.band.h)
	local barX, barY = a.quickbar.x, a.quickbar.y - a.band.y
	for i, cell in band.cells do
		local at = HudLayout.quickCell(i, 0)
		cell.base.Position = UDim2.fromOffset(barX + at.x, barY + at.y)
	end
	band.selected = 0

	-- The side strips (wide), from the screen's edges to Theme's STRIP_REACH past the side columns.
	local left, right = self.strips[1], self.strips[2]
	if a.mode == "wide" then
		local x0, y0 = -p.x / scale, -p.y / scale
		local height = view.h / scale
		local leftEnd = a.columns[1].x + a.columns[1].w + Size.STRIP_REACH
		local rightStart = a.columns[3].x - Size.STRIP_REACH
		left.Position = UDim2.fromOffset(x0, y0)
		left.Size = UDim2.fromOffset(leftEnd - x0, height)
		right.Position = UDim2.fromOffset(rightStart, y0)
		right.Size = UDim2.fromOffset((view.w - p.x) / scale - rightStart, height)
	end

	-- JEI's dock, the recipe view's centre and the status icons' place (screen pixels).
	local jei = a.jei
	self.dock = if jei then { x = p.x + jei.x * scale, y = p.y + jei.y * scale, w = jei.w, h = jei.h } else false
	self.viewX = p.x + InventoryColumns.viewCentre(a) * scale
	local parent = root.Parent
	local origin = if parent and parent:IsA("GuiBase2d") then parent.AbsolutePosition else Vector2.zero
	local function onScreen(r: Rect?): Rect?
		return if r
			then {
				x = origin.X + p.x + r.x * scale,
				y = origin.Y + p.y + r.y * scale,
				w = r.w * scale,
				h = r.h * scale,
			}
			else nil
	end
	self.status = onScreen(a.status)
	self.effects = onScreen(a.effects)
	self.viewEffects = onScreen(a.viewEffects)

	refreshVisibility(self)
	refreshLive(self)
end

--[[
	Lays the screen out for `view` (see the header) and returns the GUI scale; nothing is built or
	written while the view and what the screen shows are unchanged.
]]
function InventoryScreen.place(self: Self, view: View): number
	-- (VANITY starts closed on touch screens, until opened or closed by hand.)
	if not self.vanityChosen then
		local closed = bit32.btest(self.collapsed, BIT.vanity)
		if closed ~= view.touch then
			self.collapsed = bit32.bxor(self.collapsed, BIT.vanity)
		end
	end
	if
		self.arrangement ~= nil
		and view.w == self.keyW
		and view.h == self.keyH
		and view.top == self.keyTop
		and view.base == self.keyBase
		and view.touch == self.keyTouch
		and self.panelKey == self.keyPanel
		and self.collapsed == self.keyCollapsed
		and self.equipShown == self.keyEquip
		and self.viewing == self.keyViewing
	then
		return self.scale
	end
	self.keyW, self.keyH, self.keyTop, self.keyBase, self.keyTouch = view.w, view.h, view.top, view.base, view.touch
	self.keyPanel, self.keyCollapsed, self.keyEquip, self.keyViewing =
		self.panelKey, self.collapsed, self.equipShown, self.viewing
	self.touch = view.touch
	local panel = self.panel
	local layout = if panel then panel.layout else nil
	for _, input in { self.wide, self.narrow } do
		input.container = if layout then layout.height else nil
		input.panel = layout
		input.equipment = self.equipShown
		input.collapsed = self.collapsed
	end
	local p = InventoryColumns.place(view, self.wide, self.narrow)
	local input = if p.mode == "wide" then self.wide else self.narrow
	input.height, input.centreW = p.height, p.centreW
	local a = InventoryColumns.arrange(input)
	self.arrangement, self.scale = a, p.scale
	apply(self, a, p, view, input)
	self.scaled:setScale(p.scale)
	self.handsScaled:setScale(p.scale * Size.BIG_FACE / Style.ITEM)
	return p.scale
end

function InventoryScreen.jeiDock(self: Self): Rect | false
	return self.dock
end

function InventoryScreen.jeiViewX(self: Self): number?
	return self.viewX
end

-- The band's status place (absolute screen pixels) and the scale, while a survival-like player
-- sees the band.
function InventoryScreen.statusRect(self: Self): (Rect?, number)
	if self.viewing or not GameMode.isSurvivalLike(ClientInventory.mode()) then
		return nil, self.scale
	end
	return self.status, self.scale
end

-- The effect icons' place (absolute screen pixels) and the scale: beside the band's quickbar, or
-- under the recipe view (which hides the bar) the band's row under the VICINITY column.
function InventoryScreen.effectsRect(self: Self): (Rect?, number)
	if self.viewing then
		return self.viewEffects, self.scale
	end
	return self.effects, self.scale
end

function InventoryScreen.setViewing(self: Self, viewing: boolean)
	if viewing == self.viewing then
		return
	end
	self.viewing = viewing
	refreshVisibility(self)
	refreshLive(self)
end

function InventoryScreen.setFeedback(self: Self, feedback: Theme.Feedback?)
	self.widgets:setFeedback(feedback)
end

function InventoryScreen.inDropZone(self: Self, point: Vector2): boolean
	return self.ground:covers(point)
end

--[[ Drawing ]]

-- HANDS' texts for the held `stack` (only when it changed).
local function renderHands(self: Self, stack: Types.Stack?)
	local hands = self.hands
	local item = if stack and stack.count > 0 then stack.item else nil
	local count = if stack then stack.count else 0
	local damage = if stack then stack.damage else nil
	local data = if stack then stack.data else nil
	if item == hands.item and count == hands.count and damage == hands.damage and data == hands.data then
		return
	end
	hands.item, hands.count, hands.damage, hands.data = item, count, damage, data
	local lines = if item then Theme.handsLines(stack) else nil
	local condition = lines and lines.condition
	hands.name.Text = if lines then lines.name else ""
	hands.condition.Text = if condition then condition.name else ""
	hands.detail.Text = if lines then lines.detail or "" else ""
	hands.dot.Visible = condition ~= nil
	if condition then
		hands.dot.BackgroundColor3 = Color3.fromRGB(condition.rgb[1], condition.rgb[2], condition.rgb[3])
		hands.dot.BackgroundTransparency = Theme.DOT_T
	end
	renderChips(hands, if item then stack else nil)
end

-- The band's number boxes and selection outline.
local function renderBand(self: Self, inventory: Types.Inventory, selected: number)
	local band = self.band
	local show = Theme.numbersShown(self.scale, self.touch)
	for i, cell in band.cells do
		Dayz.paintNumber(cell, if show then band.numbers[i] else "", inventory.slots[i] ~= nil)
	end
	if selected ~= band.selected then
		band.selected = selected
		local cell = band.cells[selected]
		band.selection.Visible = cell ~= nil
		if cell then
			band.selection.Position = cell.base.Position
		end
	end
end

-- Draws `window` (the hovered slot outlined, so are the slots of a drag in progress).
function InventoryScreen.render(self: Self, window: Window, hover: Target?, dragged: { [number]: boolean })
	if self.arrangement == nil then
		return
	end
	local inventory = window.inventory
	local selected = inventory.selected
	-- HANDS is the selected hotbar slot.
	local held = self.hands.widget
	held.index = selected
	held.window = if self.live.hands then Menu.windowIndex(window, "inventory", selected) or -1 else -1
	self.widgets:draw(window, hover, dragged, selected)
	-- Section titles with their counts (from the window: a collapsed section draws no slots).
	local packed = InventoryColumns.used(inventory.slots, Types.HOTBAR_SIZE + 1, Types.INVENTORY_SIZE)
	if packed ~= self.backpackCount then
		self.backpackCount = packed
		self.sections.backpack:setTitle(
			Theme.sectionTitle("Backpack", packed, Types.INVENTORY_SIZE - Types.HOTBAR_SIZE)
		)
	end
	local panel = self.panel
	if panel then
		local section = self.sections.container
		local layout = panel.layout
		local container = window.container
		if section and container and layout.kind == "chest" then
			local used = InventoryColumns.used(container.slots, 1, self.containerSize)
			if used ~= self.containerCount then
				self.containerCount = used
				section:setTitle(Theme.sectionTitle(layout.title, used, self.containerSize))
			end
		end
		panel:render(window)
	end
	renderHands(self, inventory.slots[selected])
	renderBand(self, inventory, selected)
	local point = self.lastPoint
	self.ground:render(os.clock(), inventory.cursor ~= nil, point ~= nil and self.ground:covers(point))
	self.preview:update(window)
end

--[[ Hit tests ]]

-- What is under `point` (screen pixels): a slot, outside (the GROUND strip, or off the screen's
-- root), or nothing.
function InventoryScreen.targetAt(self: Self, point: Vector2): Target?
	-- (An eye is a button of its own: no slot click under it.)
	if self.widgets:eyeAt(point) then
		return nil
	end
	local widget = self.widgets:widgetAt(point)
	if widget then
		return { kind = "slot", index = widget.window }
	end
	if self.ground:covers(point) or not Style.contains(self.root, point) then
		return { kind = "outside" }
	end
	return nil
end

--[[
	A tooltip for what is under `point` besides items: a locked crafting result ("Iron Pickaxe",
	"Requires the Iron Age"), a closed accessory slot ("Opens at the Industrial Age"), a machine's
	energy bar ("1.2 kJ / 20 kJ") or tank ("Lava: 5,000 mB"), a ground item, a HANDS chip
	("Suppressor", "Worn", "Click to take it off").
]]
function InventoryScreen.tooltipAt(self: Self, point: Vector2, window: Window): { string }?
	for _, chip in self.hands.chips do
		local item = chip.item
		if item and not self.viewing and Style.shown(chip.button) and Style.contains(chip.button, point) then
			local condition = chipCondition(chip)
			local lines = { Items.displayName(item) }
			if condition then
				table.insert(lines, condition.name)
			end
			table.insert(lines, "Click to take it off")
			return lines
		end
	end
	local widget = self.widgets:widgetAt(point)
	if widget then
		if self.widgets:isResult(widget, window) then
			local item, _, text = self.widgets:lockedResult(window)
			if item and text then
				return { Items.displayName(item), text }
			end
		end
		if widget.locked then
			local age = Ages.byId(Config.Accessories.ExtraSlotAges[widget.index - Types.BASE_ACCESSORY_SLOTS] or "")
			return { if age then `Opens at the {age.name}` else "Closed" }
		end
		return nil
	end
	-- (A collapsed block section's gauges keep their frames where its body was: over ITEMS.)
	local panel = self.panel
	if panel and self.live.container then
		local lines = panel:tooltipAt(point, window)
		if lines then
			return lines
		end
	end
	return self.ground:tooltipAt(point)
end

-- The target of a (gamepad) selected object: a live slot, or the GROUND strip (outside).
function InventoryScreen.targetOf(self: Self, object: GuiObject): Target?
	if object == self.ground.button then
		return { kind = "outside" }
	end
	return self.widgets:targetOf(object)
end

-- Where gamepad selection starts: the block's first slot (a grid's top left, a furnace's input),
-- else the first hotbar slot.
function InventoryScreen.firstSelectable(self: Self): GuiObject?
	local first = self.widgets:first("container") or self.widgets:first("band")
	return if first then first.view.button else nil
end

--[[ Opening and the character ]]

function InventoryScreen.opened(self: Self)
	self.preview:opened()
	self.ground:reset()
end

function InventoryScreen.closed(self: Self)
	self.preview:closed()
	self.ground:reset()
	self.lastPoint = nil
end

-- Turns the player towards the pointer (Ui/PlayerPreview); the pointer is kept for the GROUND
-- strip's outline.
function InventoryScreen.follow(self: Self, point: Vector2?)
	self.lastPoint = point
	self.preview:follow(point)
end

return InventoryScreen

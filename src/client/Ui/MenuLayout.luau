--!strict
--[[
	Where the inventory screens put things, and the numbers behind their gauges, in Minecraft's GUI
	pixels (the player panel is 176 x 166). Pure: no Roblox APIs, so the tests check the layouts.

	  player panel  Minecraft's InventoryScreen: the 2 x 2 crafting grid (container slots 2..5 of
	                window 0's "inventory" container) with the "Crafting" label above it, an arrow
	                and the result (slot 1) at the top right
	  panels        what sits above the player panel while a block's window is open:
	                  chest     rows of 9 under the block's name
	                  crafting  CraftingScreen's top half: the 3 x 3 grid (slots 2..10), an arrow
	                            and the result (slot 1) in a large 26 x 26 frame
	                  furnace   AbstractFurnaceScreen: the input (1) over the flame over the fuel
	                            (2), the progress arrow and the output (3) in a large frame
	                  machine   a Mekanism machine's (Shared/Machines.panel): its kind's slots where
	                            it puts them (with the outline of what goes in while empty: upgrade
	                            cards), Mekanism's vertical energy bar (GuiVerticalPowerBar, right
	                            edge), a fluid gauge per tank (GuiFluidGauge: Machines.gauges, the
	                            Heat Generator's lava, the Oil Refinery's oil and fuel, the
	                            Combustion Generator's fuel), optionally an arrow, a flame, a status
	                            line and more lines under it (a battery's input and output)
	  gauges        the furnace's flame and arrow (AbstractFurnaceMenu.getLitProgress /
	                getBurnProgress), a machine's (from the data fields its panel names), the
	                energy bar (stored over capacity, red when empty to green when full, "x / y"
	                on hover), a tank gauge (its fluid's colour filling round(amount / capacity x
	                rows) of its inside from the bottom, Machines.gaugeLevel; "Lava: 5,000 mB"
	                on hover, Machines.tankLine), the durability bar under worn tools
	                (ItemStack.getBarWidth /
	                getBarColor) and Mekanism's energy bar in its place on items that hold energy
	                (batteries)

	A slot's (x, y) is its item's top left corner, as in Minecraft's menus: the 18 x 18 slot frame
	(and the hit area) is one pixel up and left of it, a large frame five.

	  armor eye     the button hiding a vanity armor slot's armor look (Ui/InventoryScreen's
	                equipment panel): its 6 x 6 art in the item's top right corner, and the button
	                that size too, or on touch screens 8 x 8 out to the frame's corner; never over
	                the item's middle, so a tap on the slot still reaches the slot.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Fluids = require(Shared.Fluids)
local Items = require(Shared.Items)
local Machines = require(Shared.Machines)
local Types = require(Shared.Inventory.Types)

type Container = Types.Container

-- A slot: container slot `slot` with its item at (x, y); `big` draws Minecraft's 26 x 26 result frame,
-- and `ghost` (16 x 16 pixel art, "G" pixels) an outline while the slot is empty (machines' slots).
export type Spot = { slot: number, x: number, y: number, big: boolean, ghost: { string }? }
export type Rect = { x: number, y: number, w: number, h: number }
-- Where a machine's gauge reads its data: `value` over `total` (data indices) or over `fixed`.
export type Source = { value: number, total: number?, fixed: number? }
--[[
	A machine's tank gauge (Machines.gauges): its frame and the inside the fluid fills, the data
	index of its amount (mB) over its capacity, and its fluid (`fluid`, or the id at data index
	`fluidIndex` for a tank taking several).
]]
export type TankSpot = {
	frame: Rect,
	inner: Rect,
	amount: number,
	capacity: number,
	fluid: number,
	fluidIndex: number?,
}

-- The player panel's crafting area (window 0 only).
export type Grid = {
	label: { x: number, y: number, text: string },
	slots: { Spot },
	arrow: Rect,
}

-- A container panel above the player panel.
export type Panel = {
	kind: string,
	width: number,
	height: number,
	title: string,
	-- Title position; `centred` puts it in the middle of the panel instead (x is then ignored).
	titleX: number,
	titleY: number,
	centred: boolean,
	-- In the order gamepad selection should meet them (the grid or input before the result).
	slots: { Spot },
	-- The grey crafting arrow.
	arrow: Rect?,
	-- The furnace: its progress arrow (filling left to right) and flame (filling from the bottom).
	progress: Rect?,
	flame: Rect?,
	-- Machines: where their arrow and flame read their data (nil: the furnace's indices), the
	-- energy bar and the status line.
	progressSource: Source?,
	flameSource: Source?,
	energy: Rect?,
	status: { x: number, y: number }?,
	-- Where the machine's extra lines go (Machines.lines), one position per line that fits.
	lines: { { x: number, y: number } },
	-- Its tanks' gauges (none for other panels).
	tanks: { TankSpot },
}

local MenuLayout = {}

MenuLayout.WIDTH = 176
MenuLayout.PLAYER_HEIGHT = 166
-- Minecraft's large result frame (26 x 26, five pixels around the item).
MenuLayout.BIG_FRAME = 26
MenuLayout.BIG_INSET = 5
-- The durability bar: 13 pixels wide at (2, 13) of the 16 x 16 item, two high (the top one coloured).
MenuLayout.BAR_X, MenuLayout.BAR_Y, MenuLayout.BAR_WIDTH, MenuLayout.BAR_HEIGHT = 2, 13, 13, 2
-- The furnace's flame (14 x 14) and arrow (24 x 16) sprites, and the smelting time with no data.
MenuLayout.FLAME_SIZE = 14
MenuLayout.ARROW_WIDTH, MenuLayout.ARROW_HEIGHT = 24, 16
-- A machine's extra lines: pixels from one to the next, a line's text height, and the room kept
-- under the last one (the panel's border).
MenuLayout.LINE_HEIGHT = 12
MenuLayout.LINE_TEXT = 8
MenuLayout.LINE_MARGIN = 4
local DEFAULT_BURN = 200

--[[ The player panel's 2 x 2 crafting area ]]

-- InventoryMenu's slots: the result at (154, 28), the grid at (98 + 18 column, 18 + 18 row).
MenuLayout.inventoryGrid = {
	label = { x = 97, y = 8, text = "Crafting" },
	slots = {
		{ slot = 2, x = 98, y = 18, big = false },
		{ slot = 3, x = 116, y = 18, big = false },
		{ slot = 4, x = 98, y = 36, big = false },
		{ slot = 5, x = 116, y = 36, big = false },
		{ slot = Types.CRAFT_RESULT, x = 154, y = 28, big = false },
	},
	arrow = { x = 135, y = 29, w = 16, h = 13 },
} :: Grid

--[[
	Is `container` one with a panel of its own (a block's window)? Window 0's own 2 x 2 grid
	("inventory") lives in the player panel, so it is not.
]]
function MenuLayout.hasPanel(container: Container?): boolean
	return container ~= nil and container.kind ~= "inventory"
end

-- Does the player panel show the 2 x 2 grid for this container (window 0's, well formed)?
function MenuLayout.showsGrid(container: Container?): boolean
	return container ~= nil and container.kind == "inventory" and container.size == Types.CRAFT_RESULT + 4
end

-- The name a block's panel shows: its item's name ("Chest"), else its block name.
local function blockTitle(block: number): string
	if Items.isValid(block) then
		return Items.displayName(block)
	elseif Blocks.isValid(block) then
		local def = Blocks.get(block)
		return def.displayName or def.name
	end
	return "Container"
end

local function chestPanel(container: Container): Panel
	local slots: { Spot } = {}
	for slot = 1, container.size do
		local row, column = (slot - 1) // 9, (slot - 1) % 9
		table.insert(slots, { slot = slot, x = 8 + column * 18, y = 18 + row * 18, big = false })
	end
	return {
		kind = container.kind,
		width = MenuLayout.WIDTH,
		height = 24 + math.ceil(container.size / 9) * 18,
		title = blockTitle(container.block),
		titleX = 8,
		titleY = 6,
		centred = false,
		slots = slots,
		arrow = nil,
		progress = nil,
		flame = nil,
		progressSource = nil,
		flameSource = nil,
		energy = nil,
		status = nil,
		lines = {},
		tanks = {},
	}
end

-- CraftingMenu: the grid at (30 + 18 column, 17 + 18 row), the result at (124, 35).
local function craftingPanel(container: Container): Panel
	local slots: { Spot } = {}
	for i = 1, 9 do
		local row, column = (i - 1) // 3, (i - 1) % 3
		table.insert(slots, { slot = Types.CRAFT_RESULT + i, x = 30 + column * 18, y = 17 + row * 18, big = false })
	end
	table.insert(slots, { slot = Types.CRAFT_RESULT, x = 124, y = 35, big = true })
	return {
		kind = container.kind,
		width = MenuLayout.WIDTH,
		height = 78,
		title = "Crafting",
		titleX = 29,
		titleY = 6,
		centred = false,
		slots = slots,
		arrow = { x = 90, y = 35, w = 22, h = 15 },
		progress = nil,
		flame = nil,
		progressSource = nil,
		flameSource = nil,
		energy = nil,
		status = nil,
		lines = {},
		tanks = {},
	}
end

-- AbstractFurnaceMenu: input (56, 17), fuel (56, 53), output (116, 35); the title centred.
local function furnacePanel(container: Container): Panel
	return {
		kind = container.kind,
		width = MenuLayout.WIDTH,
		height = 78,
		title = "Furnace",
		titleX = 8,
		titleY = 6,
		centred = true,
		slots = {
			{ slot = Types.FURNACE_INPUT, x = 56, y = 17, big = false },
			{ slot = Types.FURNACE_FUEL, x = 56, y = 53, big = false },
			{ slot = Types.FURNACE_OUTPUT, x = 116, y = 35, big = true },
		},
		arrow = nil,
		progress = { x = 79, y = 34, w = MenuLayout.ARROW_WIDTH, h = MenuLayout.ARROW_HEIGHT },
		flame = { x = 56, y = 36, w = MenuLayout.FLAME_SIZE, h = MenuLayout.FLAME_SIZE },
		progressSource = nil,
		flameSource = nil,
		energy = nil,
		status = nil,
		lines = {},
		tanks = {},
	}
end

-- Where a machine's gauge (Machines.Gauge) reads its data, from its kind's field names.
local function sourceOf(block: number, gauge: Machines.Gauge): Source?
	local value = Machines.field(block, gauge.value)
	if value == nil then
		return nil
	end
	local total = gauge.total
	if type(total) == "number" then
		return { value = value, total = nil, fixed = total }
	end
	local index = Machines.field(block, total)
	return if index then { value = value, total = index, fixed = nil } else nil
end

-- The tank gauges of machine `block` (Machines.gauges): a 1 pixel frame around the fluid.
local function tankSpots(block: number): { TankSpot }
	local spots: { TankSpot } = {}
	for _, gauge in Machines.gauges(block) do
		table.insert(spots, {
			frame = { x = gauge.x, y = gauge.y, w = gauge.w, h = gauge.h },
			inner = { x = gauge.x + 1, y = gauge.y + 1, w = gauge.w - 2, h = gauge.h - 2 },
			amount = gauge.amount,
			capacity = gauge.capacity,
			fluid = gauge.fluid,
			fluidIndex = gauge.fluidIndex,
		})
	end
	return spots
end

--[[
	A Mekanism machine's panel (Shared/Machines.panel): its kind's slots at their places, the
	title centred, the energy bar (Mekanism's GuiVerticalPowerBar at (164, 15) unless the kind puts
	it elsewhere), a gauge per tank, the arrow, flame and status line the kind asks for.
]]
local function machinePanel(container: Container): Panel
	local block = container.block
	local spec: Machines.PanelSpec = Machines.panel(block) or {}
	local kind = Machines.kindOf(block)
	local slots: { Spot } = {}
	if kind then
		for slot, slotSpec in kind.slots do
			if slot <= container.size then
				table.insert(
					slots,
					{ slot = slot, x = slotSpec.x, y = slotSpec.y, big = slotSpec.big == true, ghost = slotSpec.ghost }
				)
			end
		end
	end
	local bar = Machines.ENERGY_BAR
	local at = spec.energy
	local progress, flame = spec.progress, spec.flame
	local height = spec.height or Machines.PANEL_HEIGHT
	-- (As many lines as fit above the panel's bottom border.)
	local lines: { { x: number, y: number } } = {}
	local first = spec.lines
	if first then
		for i = 1, Machines.MAX_LINES do
			local y = first.y + (i - 1) * MenuLayout.LINE_HEIGHT
			if y + MenuLayout.LINE_TEXT > height - MenuLayout.LINE_MARGIN then
				break
			end
			table.insert(lines, { x = first.x, y = y })
		end
	end
	return {
		kind = container.kind,
		width = MenuLayout.WIDTH,
		height = height,
		title = spec.title or blockTitle(block),
		titleX = 8,
		titleY = 6,
		centred = true,
		slots = slots,
		arrow = nil,
		progress = if progress
			then { x = progress.x, y = progress.y, w = MenuLayout.ARROW_WIDTH, h = MenuLayout.ARROW_HEIGHT }
			else nil,
		flame = if flame
			then { x = flame.x, y = flame.y, w = MenuLayout.FLAME_SIZE, h = MenuLayout.FLAME_SIZE }
			else nil,
		progressSource = if progress then sourceOf(block, progress) else nil,
		flameSource = if flame then sourceOf(block, flame) else nil,
		energy = { x = if at then at.x else bar.x, y = if at then at.y else bar.y, w = bar.w, h = bar.h },
		status = spec.status,
		lines = lines,
		tanks = tankSpots(block),
	}
end

--[[
	The panel for a block's container (see hasPanel). Kinds that don't fit their layout (a
	crafting or furnace container of another size) fall back to rows of 9, so every slot can still
	be reached.
]]
function MenuLayout.panel(container: Container): Panel
	if container.kind == "crafting" and container.size == Types.CRAFT_RESULT + 9 then
		return craftingPanel(container)
	elseif container.kind == "furnace" and container.size == Types.FURNACE_OUTPUT then
		return furnacePanel(container)
	elseif Machines.isContainer(container) and Machines.containerSize(container.block) == container.size then
		return machinePanel(container)
	end
	return chestPanel(container)
end

-- The key the screen rebuilds a panel on (a different kind, block or size); "" without one.
function MenuLayout.panelKey(container: Container?): string
	if container == nil or not MenuLayout.hasPanel(container) then
		return ""
	end
	return `{container.kind}:{container.block}:{container.size}`
end

--[[ The equipment panel ]]

-- The armor eye's button for the slot whose item is at (x, y) (see the header).
function MenuLayout.armorEye(x: number, y: number, touch: boolean): Rect
	if touch then
		return { x = x + 9, y = y - 1, w = 8, h = 8 }
	end
	return { x = x + 10, y = y, w = 6, h = 6 }
end

--[[ Furnace gauges ]]

local function value(data: { number }?, index: number): number
	local v = if data then data[index] else nil
	if type(v) ~= "number" or v ~= v then
		return 0
	end
	return v
end

--[[
	Rows of the flame shown (from the bottom, 1..14), or 0 while the furnace is out:
	getLitProgress = litTime * 13 / litDuration (200 when unknown), drawn one row taller.
]]
function MenuLayout.flameRows(data: { number }?): number
	local litTime, litDuration = value(data, 1), value(data, 2)
	if litTime <= 0 then
		return 0
	end
	local duration = if litDuration > 0 then litDuration else DEFAULT_BURN
	local progress = math.clamp(math.floor(litTime * 13 / duration), 0, 13)
	return progress + 1
end

--[[
	Columns of the arrow filled (0..24): getBurnProgress = cookingProgress * 24 / cookingTotalTime,
	nothing while either is 0.
]]
function MenuLayout.arrowColumns(data: { number }?): number
	local progress, total = value(data, 3), value(data, 4)
	if progress <= 0 or total <= 0 then
		return 0
	end
	return math.clamp(math.floor(progress * MenuLayout.ARROW_WIDTH / total), 0, MenuLayout.ARROW_WIDTH)
end

--[[ Machine gauges ]]

-- How full a machine's gauge is (0..1): its value over its total (or fixed total), 0 without one.
function MenuLayout.gaugeFraction(data: { number }?, source: Source?): number
	if source == nil then
		return 0
	end
	local amount = value(data, source.value)
	local total = if source.fixed then source.fixed else value(data, source.total or 0)
	if amount <= 0 or total <= 0 then
		return 0
	end
	return math.clamp(amount / total, 0, 1)
end

-- A machine's flame rows (as the furnace's: 0 while out, else value * 13 / total + 1).
function MenuLayout.machineFlameRows(data: { number }?, source: Source?): number
	local fraction = MenuLayout.gaugeFraction(data, source)
	if fraction <= 0 then
		return 0
	end
	return math.clamp(math.floor(fraction * 13), 0, 13) + 1
end

-- A machine's arrow columns (0..24, as the furnace's).
function MenuLayout.machineArrowColumns(data: { number }?, source: Source?): number
	local fraction = MenuLayout.gaugeFraction(data, source)
	return math.clamp(math.floor(fraction * MenuLayout.ARROW_WIDTH), 0, MenuLayout.ARROW_WIDTH)
end

--[[ The energy bar (Mekanism's GuiVerticalPowerBar) ]]

-- A machine's stored energy over its capacity (0..1; the creative cube is full).
function MenuLayout.energyFraction(data: { number }?): number
	local energy, capacity = value(data, Machines.ENERGY), value(data, Machines.CAPACITY)
	if capacity == math.huge then
		return 1
	elseif energy <= 0 or capacity <= 0 then
		return 0
	end
	return math.clamp(energy / capacity, 0, 1)
end

--[[
	Rows of the energy bar filled (from the bottom, 0..height): Mekanism's (int) (level * height),
	so it only looks full when it is, but never empty while it holds any.
]]
function MenuLayout.energyRows(data: { number }?, height: number): number
	local fraction = MenuLayout.energyFraction(data)
	if fraction <= 0 then
		return 0
	end
	return math.clamp(math.floor(fraction * height), 1, height)
end

--[[ Tank gauges (Mekanism's GuiFluidGauge) ]]

-- The fluid a tank gauge shows (Shared/Fluids id, 0: none), from the window's `data`.
function MenuLayout.tankFluid(data: { number }?, tank: TankSpot): number
	local index = tank.fluidIndex
	local fluid = if index then value(data, index) else tank.fluid
	return if Fluids.isValid(fluid) then fluid else 0
end

-- How many mB a tank gauge's tank holds, from the window's `data` (whole, 0..capacity).
function MenuLayout.tankAmount(data: { number }?, tank: TankSpot): number
	return math.clamp(math.floor(value(data, tank.amount)), 0, tank.capacity)
end

-- Rows of a tank gauge's inside its fluid fills, from the bottom (Machines.gaugeLevel).
function MenuLayout.tankRows(data: { number }?, tank: TankSpot): number
	if MenuLayout.tankFluid(data, tank) == 0 then
		return 0
	end
	return Machines.gaugeLevel(MenuLayout.tankAmount(data, tank), tank.capacity, tank.inner.h)
end

-- The colour a tank gauge fills with (the fluid's: Fluids `color`), grey for none.
function MenuLayout.tankColour(fluid: number): { number }
	local record = Fluids.get(fluid)
	return if record then record.color else { 139, 139, 139 }
end

-- A tank gauge's tooltip: "Lava: 5,000 mB" or "Empty" (Machines.tankLine), then its capacity.
function MenuLayout.tankTooltip(data: { number }?, tank: TankSpot): { string }
	local fluid = MenuLayout.tankFluid(data, tank)
	return {
		Machines.tankLine(fluid, if fluid ~= 0 then MenuLayout.tankAmount(data, tank) else 0),
		`Capacity: {Items.formatFluid(tank.capacity)}`,
	}
end

-- The bar's colour for a fill of `fraction`: red when empty, through yellow, to green when full
-- (Machines.energyColour, which items' energy bars and batteries' gauges share).
MenuLayout.energyColour = Machines.energyColour

-- The bar's tooltip, Mekanism's "stored / capacity": "1.2 kJ / 20 kJ" ("Infinite" for creative).
function MenuLayout.energyTooltip(data: { number }?): string
	local energy, capacity = value(data, Machines.ENERGY), value(data, Machines.CAPACITY)
	if capacity == math.huge then
		return "Infinite"
	end
	return `{Items.formatEnergy(energy)} / {Items.formatEnergy(capacity)}`
end

-- A machine container's header as a View, read as it is (Machines.view would fill in missing
-- data: the client's window is read only).
local function viewOf(container: Container): Machines.View
	local data = container.data
	return {
		block = container.block,
		energy = value(data, Machines.ENERGY),
		capacity = value(data, Machines.CAPACITY),
		input = value(data, Machines.INPUT),
		output = value(data, Machines.OUTPUT),
		rate = value(data, Machines.RATE),
		active = value(data, Machines.ACTIVE) ~= 0,
		state = Machines.state(container),
	}
end

-- A machine's status line from its container's data (Machines.status), "" when it has none.
function MenuLayout.statusText(container: Container?): string
	if container == nil or not Machines.isContainer(container) then
		return ""
	end
	return Machines.status(container.block, viewOf(container)) or ""
end

-- A machine's extra panel lines from its container's data (Machines.lines), none for others.
function MenuLayout.lineTexts(container: Container?): { string }
	if container == nil or not Machines.isContainer(container) then
		return {}
	end
	return Machines.lines(container.block, viewOf(container))
end

--[[ Durability bar ]]

--[[
	Minecraft's durability bar for a stack of `item` worn by `damage`: shown once the item has a
	durability and some wear. Returns the coloured width in pixels (0..13, Math.round(13 - damage x
	13 / max)) and its hue (HSV, full saturation and value: max(0, (max - damage) / max) / 3, green
	when new, red when nearly broken); nil when there is no bar.
]]
function MenuLayout.durabilityBar(item: number?, damage: number?): (number?, number)
	if item == nil or damage == nil or damage ~= damage or damage <= 0 then
		return nil, 0
	end
	local def = Items.get(item)
	local max = def and def.durability
	if max == nil or max <= 0 then
		return nil, 0
	end
	local width = math.clamp(math.floor(13 - damage * 13 / max + 0.5), 0, MenuLayout.BAR_WIDTH)
	local hue = math.max(0, (max - damage) / max) / 3
	return width, hue
end

--[[
	Mekanism's energy bar on an item (StorageUtils' energy bar), where the durability bar goes: on
	the item of a machine whose data holds energy (sustained data, "energy": a charged Battery, a
	generator broken with energy in it). Returns the coloured width in pixels (1..13: the energy
	over the block's capacity, like the panels' bar full only when full and never empty while it
	holds any) and its colour ({ r, g, b }, Machines.energyColour); nil when there is no bar (no
	energy in the data, no machine's item, the creative cube's infinite store). (Mekanism rounds
	13 x the fraction to the nearest pixel, colours it 0x3CFE9A and draws it on every Energy Cube,
	empty ones too, and on no other machine's item.)
]]
function MenuLayout.energyItemBar(item: number?, data: Items.Data?): (number?, { number })
	local def = if item then Items.get(item) else nil
	local block = def and def.block
	local energy = if block then Machines.energyOf(block) else nil
	local stored = Items.dataNumber(data, "energy")
	if energy == nil or stored == nil or stored ~= stored or stored <= 0 then
		return nil, Machines.energyColour(0)
	elseif energy.capacity == math.huge or energy.capacity <= 0 then
		return nil, Machines.energyColour(0)
	end
	local fraction = math.min(stored / energy.capacity, 1)
	local width = math.clamp(math.floor(fraction * MenuLayout.BAR_WIDTH), 1, MenuLayout.BAR_WIDTH)
	return width, Machines.energyColour(fraction)
end

--[[ Pixel art ]]

--[[
	A right-pointing arrow `width` x `height` pixels as Style.pixelArt rows ("#" = arrow): a shaft
	about a third of the height, centred, and a head as tall as the arrow.
]]
function MenuLayout.arrowArt(width: number, height: number): { string }
	local headColumns = math.ceil(height / 2)
	local shaft = height // 3
	if (height - shaft) % 2 == 1 then
		shaft += 1
	end
	local shaftTop = (height - shaft) // 2
	local rows: { string } = {}
	for row = 0, height - 1 do
		local line = table.create(width, ".")
		for column = 0, width - 1 do
			local head = column - (width - headColumns)
			local filled
			if head < 0 then
				filled = row >= shaftTop and row < shaftTop + shaft
			else
				filled = row >= head and row <= height - 1 - head
			end
			if filled then
				line[column + 1] = "#"
			end
		end
		table.insert(rows, table.concat(line))
	end
	return rows
end

-- The furnace's flame, 14 x 14: R red edge, O orange, Y yellow, W the white-hot core.
MenuLayout.FLAME_ART = {
	"......R.......",
	"......RR......",
	".....ROR......",
	".....ROOR.....",
	"....ROOOR..R..",
	"....ROYOOR.R..",
	"...ROOYYOR.RR.",
	"..R.ROYYOOR.R.",
	"..RROYYWYOORR.",
	".RROOYWWYYOOR.",
	".ROOYYWWWYYOR.",
	".ROOYWWWWWYOR.",
	"..ROYYWWWYOR..",
	"...RROOOORR...",
} :: { string }

return MenuLayout

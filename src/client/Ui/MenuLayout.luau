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
	  gauges        the furnace's flame and arrow (AbstractFurnaceMenu.getLitProgress /
	                getBurnProgress) and the durability bar under worn tools (ItemStack.getBarWidth
	                / getBarColor)

	A slot's (x, y) is its item's top left corner, as in Minecraft's menus: the 18 x 18 slot frame
	(and the hit area) is one pixel up and left of it, a large frame five.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Items = require(Shared.Items)
local Types = require(Shared.Inventory.Types)

type Container = Types.Container

-- A slot: container slot `slot` with its item at (x, y); `big` draws Minecraft's 26 x 26 result frame.
export type Spot = { slot: number, x: number, y: number, big: boolean }
export type Rect = { x: number, y: number, w: number, h: number }

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

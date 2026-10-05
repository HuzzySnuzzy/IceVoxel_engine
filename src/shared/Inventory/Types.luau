--!strict
--[[
	Shapes shared by the inventory logic (Inventory/Menu), the protocol and both sides.

	A player's inventory is Minecraft's: 36 slots (1-9 the hotbar, 10-36 the rest), 4 armor slots
	(head, chest, legs, feet), the stack carried by the mouse while a screen is open, and the
	selected hotbar slot.

	A window is what a screen shows: the inventory plus the panel above or beside it, its container.
	Clicks address window slots, numbered from 0:

	    [0, n)            the container's n slots
	    [n, n + 4)        armor: head, chest, legs, feet
	    [n + 4, n + 31)   inventory slots 10..36 (the three rows above the hotbar)
	    [n + 31, n + 40)  the hotbar, inventory slots 1..9

	Containers by kind (slot numbers within the container, 1-based):

	    inventory  the inventory screen's own 2 x 2 crafting grid: 1 result, 2..5 the grid (window 0)
	    crafting   a crafting table: 1 result, 2..10 the 3 x 3 grid (personal, emptied on close)
	    chest      a chest's 27 slots (shared by everyone who opens it)
	    furnace    1 input, 2 fuel, 3 output, plus `data` (Crafting/Smelting; shared)

	A container's `data` is a list of up to MAX_CONTAINER_DATA numbers its screen shows (Minecraft's
	ContainerData): a furnace's flame and arrow (Crafting/Smelting, indices 1..5). The protocol
	sends them as f64, so machines may keep energy far beyond 16 bits there.

	Stacks keep their item data (Items.Stack `data`) wherever they go: every copy, click and move
	carries it, and stacks with different data never merge (Inventory/Menu).

	Window 0 is the inventory screen (its container the 2 x 2 grid); the others get ids 1..255.
]]

local Items = require(script.Parent.Parent.Items)

export type Stack = Items.Stack

export type Inventory = {
	-- 1..36: 1-9 the hotbar, 10-36 the rest. nil = empty.
	slots: { [number]: Stack? },
	-- 1..4: head, chest, legs, feet.
	armor: { [number]: Stack? },
	-- Carried by the mouse in an open screen.
	cursor: Stack?,
	-- Hotbar slot in hand, 1..9.
	selected: number,
}

export type Container = {
	-- "inventory", "crafting", "chest" or "furnace" (see above).
	kind: string,
	-- The block it belongs to (e.g. Blocks.id.Chest), for its name; 0 for the inventory's grid.
	block: number,
	size: number,
	slots: { [number]: Stack? },
	-- Numbers the screen shows (at most MAX_CONTAINER_DATA). Furnace: litTime, litDuration,
	-- cookingProgress, cookingTotalTime, cookingItem (ticks, item).
	data: { number }?,
}

export type Window = {
	-- 0 = the inventory screen (its container the 2 x 2 grid, Types.newWindow).
	id: number,
	inventory: Inventory,
	container: Container?,
}

--[[
	Everything a player does to their inventory. Clients send these (numbered, see Protocol) and
	predict them; the server applies them in order with Inventory/Menu.apply.

	  click     a window slot (or OUTSIDE) with a click type (Menu.ClickType) and button
	  drag      spread the carried stack over slots (mode 0 evenly, 1 one each, 2 creative: full)
	  select    hotbar slot 1..9
	  drop      throw the held item (one, or the whole stack)
	  place     one of the held item is used up placing a block (survival)
	  creative  creative inventory: put a stack (count 0 = nothing; with its wear and item data, as
	            Minecraft's creative slot packet sends whole stacks) in a window slot or, with slot
	            CURSOR, on the cursor
	  close     close the window (the carried stack goes back into the inventory)
]]
export type Action =
	{ kind: "click", window: number, slot: number, clickType: number, button: number }
	| { kind: "drag", window: number, mode: number, slots: { number } }
	| { kind: "select", slot: number }
	| { kind: "drop", all: boolean }
	| { kind: "place", item: number }
	| {
		kind: "creative",
		window: number,
		slot: number,
		item: number,
		count: number,
		damage: number?,
		data: Items.Data?,
	}
	| { kind: "close", window: number }

-- The server's state of a player's inventory, after the player's action number `ack`.
export type Snapshot = {
	ack: number,
	inventory: Inventory,
	-- Open window (0 = the inventory screen) and its container.
	window: number,
	container: Container?,
}

local Types = {}

Types.INVENTORY_SIZE = 36
Types.HOTBAR_SIZE = 9
Types.ARMOR_SIZE = 4
-- Window slots besides the container's.
Types.PLAYER_SLOTS = 40
-- Clicking outside the window (drops the carried stack).
Types.OUTSIDE = -999
-- `creative` action slot meaning the cursor.
Types.CURSOR = -1
-- Most slots a drag can cover / a container can have.
Types.MAX_DRAG = 64
Types.MAX_CONTAINER = 54
-- Most numbers in a container's `data`.
Types.MAX_CONTAINER_DATA = 16
-- Container kinds, and their numbers on the wire.
Types.KINDS = { "inventory", "crafting", "chest", "furnace" }
-- Slot of a crafting container's result; its grid follows (width x width, row by row).
Types.CRAFT_RESULT = 1
-- A furnace's slots.
Types.FURNACE_INPUT = 1
Types.FURNACE_FUEL = 2
Types.FURNACE_OUTPUT = 3

-- Player attribute with the item id in the player's hand (0 = nothing), set by the server so every
-- client can draw it in the character's hand.
Types.HELD_ATTRIBUTE = "IceVoxelHeldItem"

function Types.newInventory(): Inventory
	return { slots = {}, armor = {}, cursor = nil, selected = 1 }
end

-- A crafting container: the inventory's 2 x 2 grid ("inventory") or a crafting table's 3 x 3
-- ("crafting", for `block`).
function Types.newCrafting(kind: string, block: number?): Container
	local width = if kind == "crafting" then 3 else 2
	return { kind = kind, block = block or 0, size = 1 + width * width, slots = {}, data = nil }
end

-- The inventory screen's window: id 0, the inventory and its own 2 x 2 crafting grid.
function Types.newWindow(inventory: Inventory): Window
	return { id = 0, inventory = inventory, container = Types.newCrafting("inventory") }
end

-- Grid width of a crafting container (0 for other kinds).
function Types.craftWidth(container: Container?): number
	if container == nil then
		return 0
	elseif container.kind == "inventory" then
		return 2
	elseif container.kind == "crafting" then
		return 3
	end
	return 0
end

-- Number of window slots with a container of `containerSize` slots.
function Types.windowSize(containerSize: number): number
	return containerSize + Types.PLAYER_SLOTS
end

return Types

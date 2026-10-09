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
	    machine    a Mekanism machine (Shared/Machines): its kind's slots (0 or more) and `data`,
	               energy first (shared); its block says which kind

	A container's `data` is a list of up to MAX_CONTAINER_DATA numbers its screen shows (Minecraft's
	ContainerData): a furnace's flame and arrow (Crafting/Smelting, indices 1..5), a machine's
	energy and gauges (Shared/Machines, energy always at 1). The protocol sends them as f64, so
	machines keep energy far beyond 16 bits there.

	Stacks keep their item data (Items.Stack `data`) wherever they go: every copy, click and move
	carries it, and stacks with different data never merge (Inventory/Menu).

	Window 0 is the inventory screen (its container the 2 x 2 grid); the others get ids 1..255.

	Terraria's equipment (Config.Accessories, Items/Accessories) is in the inventory too:
	ACCESSORY_SIZE accessory slots (`accessorySlots` of them open: Config.Accessories.Slots, one
	more at each of its Ages; the server sets it, it is never saved), 4 vanity armor slots (the look
	over each armor piece), ACCESSORY_SIZE vanity accessory slots (the look over each accessory),
	and `hidden`, a bit per accessory slot (bit i - 1) and per armor slot (bit HIDE_ARMOR + i - 1)
	whose look is not drawn (it still works). In window slot numbers they come after the hotbar,
	so every slot above keeps its number:

	    [n + 40, n + 47)  accessories 1..7          (ACCESSORY_START)
	    [n + 47, n + 51)  vanity armor 1..4         (VANITY_ARMOR_START)
	    [n + 51, n + 58)  vanity accessories 1..7   (VANITY_ACCESSORY_START; EQUIPMENT_END)

	(Inventory/Menu numbers windows with PLAYER_SLOTS = 40 until these slots work; then
	PLAYER_SLOTS becomes EQUIPMENT_END.) Saved records number a player's stacks by PLACE_*: 1..36
	the slots, 37..40 armor, 41 the cursor, 42..48 accessories, 49..52 vanity armor, 53..59 vanity
	accessories.
]]

local Config = require(script.Parent.Parent.Config)
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
	-- 1..ACCESSORY_SIZE: Terraria's accessories (only the first `accessorySlots` work).
	accessories: { [number]: Stack? },
	-- 1..4: vanity armor, the look over armor slot 1..4.
	vanityArmor: { [number]: Stack? },
	-- 1..ACCESSORY_SIZE: vanity accessories, the look over accessory slot 1..7.
	vanityAccessories: { [number]: Stack? },
	-- Looks not drawn: bit i - 1 accessory slot i, bit HIDE_ARMOR + i - 1 armor slot i.
	hidden: number,
	-- Accessory slots open (Config.Accessories: the server sets it from the Age; not saved).
	accessorySlots: number,
}

-- What a character wears besides armor (a saved record's equipment, Inventories.restoreEquipment).
export type Equipment = {
	accessories: { [number]: Stack? },
	vanityArmor: { [number]: Stack? },
	vanityAccessories: { [number]: Stack? },
	hidden: number,
}

export type Container = {
	-- "inventory", "crafting", "chest", "furnace" or "machine" (see above).
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
	-- Progression's recipe gate (Shared/Progression.allows for the window's player; nil: every
	-- result): a crafting result it refuses stays empty (Minecraft's doLimitedCrafting), and a
	-- furnace's input or a machine takes nothing that smelts into one (Inventory/Menu). The
	-- server sets it on each player's window, the client on its prediction.
	recipes: ((item: number) -> boolean)?,
	-- Server only: told about each crafting result taken ("craft", the result) and each stack
	-- taken out of a furnace's or machine's output ("smelt"): Minecraft's ResultSlot and
	-- FurnaceResultSlot checkTakeAchievements, for Progression's knowledge.
	onTake: ((kind: string, stack: Stack) -> ())?,
}

--[[
	Everything a player does to their inventory. Clients send these (numbered, see Protocol) and
	predict them; the server applies them in order with Inventory/Menu.apply (spectators' only
	where Menu.allows: select and close).

	  click     a window slot (or OUTSIDE) with a click type (Menu.ClickType) and button
	  drag      spread the carried stack over slots (mode 0 evenly, 1 one each, 2 creative: full)
	  select    hotbar slot 1..9
	  drop      throw the held item (one, or the whole stack)
	  place     one of the held item is used up placing a block (survival; creative keeps it)
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
Types.KINDS = { "inventory", "crafting", "chest", "furnace", "machine" }
-- Slot of a crafting container's result; its grid follows (width x width, row by row).
Types.CRAFT_RESULT = 1
-- A furnace's slots.
Types.FURNACE_INPUT = 1
Types.FURNACE_FUEL = 2
Types.FURNACE_OUTPUT = 3

-- Player attribute with the item id in the player's hand (0 = nothing), set by the server so every
-- client can draw it in the character's hand.
Types.HELD_ATTRIBUTE = "IceVoxelHeldItem"
-- Player attribute with what the character shows (comma separated item ids, 0 none: head, chest,
-- legs, feet, then the accessories drawn), set by the server so every client can draw it.
Types.LOOKS_ATTRIBUTE = "IceVoxelLooks"

--[[ Terraria's equipment (see the header) ]]

-- Accessory slots a character has (open or not), vanity armor and vanity accessory slots.
Types.ACCESSORY_SIZE = 7
Types.VANITY_ARMOR_SIZE = 4
Types.VANITY_ACCESSORY_SIZE = 7
Types.EQUIPMENT_SIZE = Types.ACCESSORY_SIZE + Types.VANITY_ARMOR_SIZE + Types.VANITY_ACCESSORY_SIZE
-- Window offsets past the container (after the 40 slots above).
Types.ACCESSORY_START = 40
Types.VANITY_ARMOR_START = Types.ACCESSORY_START + Types.ACCESSORY_SIZE -- 47
Types.VANITY_ACCESSORY_START = Types.VANITY_ARMOR_START + Types.VANITY_ARMOR_SIZE -- 51
Types.EQUIPMENT_END = Types.VANITY_ACCESSORY_START + Types.VANITY_ACCESSORY_SIZE -- 58
-- `hidden`'s first armor bit (accessory slot i is bit i - 1).
Types.HIDE_ARMOR = 8
-- Saved records' places of a player's stacks (Save/PlayerCodec, Save/CharacterCodec).
Types.PLACE_ARMOR = Types.INVENTORY_SIZE + 1 -- 37..40
Types.PLACE_CURSOR = Types.INVENTORY_SIZE + Types.ARMOR_SIZE + 1 -- 41
Types.PLACE_ACCESSORY = Types.PLACE_CURSOR + 1 -- 42..48
Types.PLACE_VANITY_ARMOR = Types.PLACE_ACCESSORY + Types.ACCESSORY_SIZE -- 49..52
Types.PLACE_VANITY_ACCESSORY = Types.PLACE_VANITY_ARMOR + Types.VANITY_ARMOR_SIZE -- 53..59
Types.PLACE_END = Types.PLACE_VANITY_ACCESSORY + Types.VANITY_ACCESSORY_SIZE - 1 -- 59

-- Accessory slots open to a character before any Age adds one.
Types.BASE_ACCESSORY_SLOTS = math.clamp(math.floor(Config.Accessories.Slots), 0, Types.ACCESSORY_SIZE)

function Types.newInventory(): Inventory
	return {
		slots = {},
		armor = {},
		cursor = nil,
		selected = 1,
		accessories = {},
		vanityArmor = {},
		vanityAccessories = {},
		hidden = 0,
		accessorySlots = Types.BASE_ACCESSORY_SLOTS,
	}
end

-- No equipment: nothing worn, nothing hidden.
function Types.newEquipment(): Equipment
	return { accessories = {}, vanityArmor = {}, vanityAccessories = {}, hidden = 0 }
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

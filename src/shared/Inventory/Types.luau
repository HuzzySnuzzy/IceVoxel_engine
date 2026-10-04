--!strict
--[[
	Shapes shared by the inventory logic (Inventory/Menu), the protocol and both sides.

	A player's inventory is Minecraft's: 36 slots (1-9 the hotbar, 10-36 the rest), 4 armor slots
	(head, chest, legs, feet), the stack carried by the mouse while a screen is open, and the
	selected hotbar slot.

	A window is what a screen shows: the inventory, plus a container (chest) when one is open.
	Clicks address window slots, numbered from 0:

	    [0, n)            the container's n slots (none without a container)
	    [n, n + 4)        armor: head, chest, legs, feet
	    [n + 4, n + 31)   inventory slots 10..36 (the three rows above the hotbar)
	    [n + 31, n + 40)  the hotbar, inventory slots 1..9

	Window 0 is the inventory alone; containers get ids 1..255.
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
	-- The container block (e.g. Blocks.id.Chest), for its name.
	block: number,
	size: number,
	slots: { [number]: Stack? },
}

export type Window = {
	-- 0 = the inventory alone.
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
	  creative  creative inventory: put a stack (count 0 = nothing) in a window slot or, with slot
	            CURSOR, on the cursor
	  close     close the window (the carried stack goes back into the inventory)
]]
export type Action =
	{ kind: "click", window: number, slot: number, clickType: number, button: number }
	| { kind: "drag", window: number, mode: number, slots: { number } }
	| { kind: "select", slot: number }
	| { kind: "drop", all: boolean }
	| { kind: "place", item: number }
	| { kind: "creative", window: number, slot: number, item: number, count: number }
	| { kind: "close", window: number }

-- The server's state of a player's inventory, after the player's action number `ack`.
export type Snapshot = {
	ack: number,
	inventory: Inventory,
	-- Open window (0 = none / the inventory alone) and its container.
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

function Types.newInventory(): Inventory
	return { slots = {}, armor = {}, cursor = nil, selected = 1 }
end

-- Number of window slots with a container of `containerSize` slots.
function Types.windowSize(containerSize: number): number
	return containerSize + Types.PLAYER_SLOTS
end

return Types

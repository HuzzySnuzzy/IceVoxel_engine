--!strict
--[[
	Every player's authoritative inventory on the server, without the Roblox parts (those are in
	Players/Inventories), so the tests can run it.

	Per player (any key; Players in the game):
	  window   Types.Window: id 0, the inventory screen with its own 2 x 2 crafting grid
	           (Types.newWindow), or a block's window (ids 1..255, cycling, never 0): a chest or a
	           furnace shares the container's table with its other viewers (Containers); a crafting
	           table's 3 x 3 grid is the player's own, made on opening and emptied back into the
	           inventory on closing
	  ack      the number of the player's last inventory action handled. Clients number their
	           actions (Protocol) and predict them; a snapshot says which ones it includes, so the
	           client drops those and replays the rest on top of it
	  dirty    something changed (or an action was handled): send a snapshot. Many changes in one
	           frame make one snapshot (`takeDirty`)

	Actions run through Inventory/Menu in arrival order. Invalid ones change nothing but are still
	acknowledged, so the client's prediction of them is undone. So are the ones the player's game
	mode does not allow (`applyAs`, Menu.allows): a spectator only selects hotbar slots and closes
	windows (Minecraft's handleContainerClick resends the menu to spectators and changes nothing),
	and only creative players use the creative actions. Spectators open containers without being
	their openers (`open`'s `quiet`: no chest lid). A change to a shared container
	marks its other viewers dirty too. Crafting results are derived from their grids
	(Menu.updateCraft), so every snapshot carries the right one.

	A saved world's returning player gets their inventory back with `restore` (World/WorldSave).

	Terraria's equipment (Inventory/Types, Inventory/Menu's rules): `restoreEquipment` puts a saved
	character's back, and `setAccessorySlots` opens the accessory slots the player's Age gives
	(Items/Accessories.slotsForAge, never saved; a snapshot carries it to the client).

	Tools wear through `wearHeld` (the server's mining calls it); `heldStack` is what is in hand.
	Using an item on a block (a bucket filling or emptying: Players/ItemUse) replaces what is in
	hand with `setHeld` and hands stacks over with `give` (Inventory.add; the rest comes back);
	`has` is Minecraft's Inventory.contains.

	Functions that take stacks out of the world (throws, close leftovers, deaths) return them; the
	caller turns them into item entities. Stacks keep their item data (Items `data`) through all of
	it; `place` hands back the stack a block was placed from, data included, so whatever kept the
	block's contents in its item (a Fluid Tank's water) can put them back.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Machines = require(Shared.Machines)
local Menu = require(Shared.Inventory.Menu)
local Types = require(Shared.Inventory.Types)

local Containers = require(script.Parent.Containers)

type Stack = Types.Stack
type Window = Types.Window
type Action = Types.Action

-- Window ids cycle through 1..MAX_WINDOW (they travel as a u8; 0 is the inventory alone).
local MAX_WINDOW = 255

export type PlayerState = {
	window: Window,
	ack: number,
	dirty: boolean,
	-- Last container window id given out.
	lastWindow: number,
	-- Block position of the open block window (chest, furnace or crafting table).
	open: { x: number, y: number, z: number }?,
}

-- Stacks left over for one player (e.g. the cursor of a viewer whose chest was broken).
export type Leftovers = { key: any, stacks: { Stack } }

export type InventoryState = {
	players: { [any]: PlayerState },
	containers: Containers.Store,

	join: (self: InventoryState, key: any) -> PlayerState,
	leave: (self: InventoryState, key: any) -> (),
	get: (self: InventoryState, key: any) -> PlayerState?,
	window: (self: InventoryState, key: any) -> Window?,
	snapshot: (self: InventoryState, key: any) -> Types.Snapshot?,
	apply: (self: InventoryState, key: any, seq: number, action: Action, creative: boolean) -> { Stack },
	applyAs: (self: InventoryState, key: any, seq: number, action: Action, mode: string) -> { Stack },
	place: (self: InventoryState, key: any, block: number, seq: number, creative: boolean) -> (boolean, Stack?),
	acknowledge: (self: InventoryState, key: any, seq: number) -> (),
	open: (
		self: InventoryState,
		key: any,
		x: number,
		y: number,
		z: number,
		block: number,
		quiet: boolean?
	) -> { Stack },
	close: (self: InventoryState, key: any) -> { Stack },
	openPosition: (self: InventoryState, key: any) -> (number?, number, number),
	removeContainer: (self: InventoryState, x: number, y: number, z: number) -> ({ Stack }, { Leftovers }),
	pickup: (self: InventoryState, key: any, stack: Stack) -> number,
	heldStack: (self: InventoryState, key: any) -> Stack?,
	setHeld: (self: InventoryState, key: any, stack: Stack?) -> (),
	give: (self: InventoryState, key: any, stack: Stack) -> Stack?,
	has: (self: InventoryState, key: any, item: number) -> boolean,
	wearHeld: (self: InventoryState, key: any, amount: number) -> boolean,
	die: (self: InventoryState, key: any, keepInventory: boolean) -> { Stack },
	markDirty: (self: InventoryState, key: any) -> (),
	takeDirty: (self: InventoryState) -> { any },
	restore: (
		self: InventoryState,
		key: any,
		slots: { [number]: Stack? },
		armor: { [number]: Stack? },
		selected: number,
		cursor: Stack?
	) -> { Stack },
	restoreEquipment: (self: InventoryState, key: any, equipment: Types.Equipment) -> (),
	setAccessorySlots: (self: InventoryState, key: any, slots: number) -> boolean,
}

local InventoryState = {}
InventoryState.__index = InventoryState

-- `containers` defaults to a store of its own.
function InventoryState.new(containers: Containers.Store?): InventoryState
	local self = { players = {}, containers = containers or Containers.new() }
	return (setmetatable(self, InventoryState) :: any) :: InventoryState
end

-- Starts a player's session with an empty inventory (a snapshot is due).
function InventoryState.join(self: InventoryState, key: any): PlayerState
	local existing = self.players[key]
	if existing then
		return existing
	end
	local player: PlayerState = {
		window = Types.newWindow(Types.newInventory()),
		ack = 0,
		dirty = true,
		lastWindow = 0,
		open = nil,
	}
	self.players[key] = player
	return player
end

-- Ends a player's session: closes their container (the session's items go with them).
function InventoryState.leave(self: InventoryState, key: any)
	if self.players[key] then
		self:close(key)
		self.players[key] = nil
	end
end

function InventoryState.get(self: InventoryState, key: any): PlayerState?
	return self.players[key]
end

function InventoryState.window(self: InventoryState, key: any): Window?
	local player = self.players[key]
	return if player then player.window else nil
end

-- The state to send to the player (it shares tables with the live state: encode it at once).
function InventoryState.snapshot(self: InventoryState, key: any): Types.Snapshot?
	local player = self.players[key]
	if player == nil then
		return nil
	end
	local window = player.window
	return { ack = player.ack, inventory = window.inventory, window = window.id, container = window.container }
end

-- Seq 0 is never used by clients; it must not move `ack` back (their pending actions would replay twice).
local function acknowledge(player: PlayerState, seq: number)
	if seq > 0 then
		player.ack = seq
	end
	player.dirty = true
end

-- Is the container one that other players can have open too (a chest or a furnace)? Crafting
-- grids (the inventory's and a crafting table's) belong to one player.
local function isShared(container: Types.Container?): boolean
	return container ~= nil and Types.craftWidth(container) == 0
end

local function markViewers(self: InventoryState, key: any, player: PlayerState)
	local open = player.open
	if open == nil or not isShared(player.window.container) then
		return
	end
	for _, viewer in self.containers:viewers(open.x, open.y, open.z) do
		local other = self.players[viewer]
		if other and viewer ~= key then
			other.dirty = true
		end
	end
end

--[[
	Handles the player's inventory action number `seq` (Menu.apply). Returns the stacks thrown out
	(to drop in front of the player). A valid `close` also closes the container window. `creative`:
	the instabuild ability (GameMode.instabuild); `applyAs` checks the game mode first.
]]
function InventoryState.apply(self: InventoryState, key: any, seq: number, action: Action, creative: boolean): { Stack }
	local player = self.players[key]
	if player == nil or type(action) ~= "table" then
		return {}
	end
	acknowledge(player, seq)
	local window = player.window
	if action.kind == "place" then
		-- Placing travels in Edit messages and goes through `place`, after the block checks.
		return {}
	elseif action.kind == "close" then
		if action.window ~= window.id then
			-- A late close for a window the server already closed (or never opened).
			return {}
		end
		return self:close(key)
	end
	local thrown = Menu.apply(window, action, creative)
	local kind = action.kind
	if kind == "click" or kind == "drag" or kind == "creative" then
		-- Other viewers of the same chest see the change.
		markViewers(self, key, player)
	end
	return thrown
end

--[[
	Handles action `seq` of a player in game mode `mode` (Players/Inventories): what the mode does
	not allow (Menu.allows: everything but selecting a hotbar slot and closing for spectators, the
	creative actions outside creative) changes nothing and is acknowledged, so the snapshot undoes
	the client's prediction; the rest is `apply` with the mode's instabuild ability.
]]
function InventoryState.applyAs(self: InventoryState, key: any, seq: number, action: Action, mode: string): { Stack }
	if type(action) ~= "table" or not Menu.allows(action, mode) then
		self:acknowledge(key, seq)
		return {}
	end
	return self:apply(key, seq, action, GameMode.instabuild(mode))
end

--[[
	A block placement (inventory action `seq`), after the edit passed every other check. Survival:
	the held stack must be the block's item, and one is used up. Creative: nothing is used.
	Acknowledges `seq` either way. false = refuse the placement. The second result is the stack
	the block came from, as it was before placing used one up (a copy, its data intact: Mekanism's
	sustained data comes back from it); nil when the hand does not hold the block's item (creative
	players may place anything).
]]
function InventoryState.place(
	self: InventoryState,
	key: any,
	block: number,
	seq: number,
	creative: boolean
): (boolean, Stack?)
	local player = self.players[key]
	if player == nil then
		return false, nil
	end
	acknowledge(player, seq)
	local item = Items.ofBlock(block)
	local inventory = player.window.inventory
	local held = inventory.slots[inventory.selected]
	local from = if item ~= nil
			and held ~= nil
			and held.item == item
			and held.count >= 1
		then Items.copyStack(held)
		else nil
	if creative then
		return true, from
	end
	if item == nil or from == nil then
		return false, nil
	end
	Menu.apply(player.window, { kind = "place", item = item }, false)
	return true, from
end

-- Acknowledges action `seq` without changing anything (a refused placement: undoes the prediction).
function InventoryState.acknowledge(self: InventoryState, key: any, seq: number)
	local player = self.players[key]
	if player then
		acknowledge(player, seq)
	end
end

--[[
	Opens the block `block` at (x, y, z) for the player in a new window, closing what was open
	(the cursor and the 2 x 2 grid go back into the inventory). A crafting table (menu "Crafting")
	gets a 3 x 3 grid of the player's own; a chest, a furnace or a machine (even one without
	slots: its panel shows its energy) is the shared container there (Containers). Returns the
	stacks that did not fit back. Blocks with no window open nothing. A `quiet` viewer (a
	spectator) sees the container without being one of its openers (Containers.addViewer).
]]
function InventoryState.open(
	self: InventoryState,
	key: any,
	x: number,
	y: number,
	z: number,
	block: number,
	quiet: boolean?
): { Stack }
	local player = self.players[key]
	if player == nil or not Blocks.isValid(block) then
		return {}
	end
	local def = Blocks.get(block)
	local personal = def.menu == "Crafting"
	if not personal and Machines.containerSize(block) <= 0 and not Machines.isMachine(block) then
		return {}
	end
	local thrown = self:close(key)
	local container: Types.Container
	if personal then
		container = Types.newCrafting("crafting", block)
	else
		container = self.containers:get(x, y, z, block)
		self.containers:addViewer(x, y, z, key, quiet)
	end
	local window = player.window
	player.lastWindow = player.lastWindow % MAX_WINDOW + 1
	window.id = player.lastWindow
	window.container = container
	player.open = { x = x, y = y, z = z }
	Menu.updateCraft(window)
	player.dirty = true
	return thrown
end

--[[
	Closes the player's screen (Menu.close: the cursor, then a crafting grid's items, go back into
	the inventory) and returns what did not fit back. A block's window becomes the inventory
	screen's window again (id 0, a fresh 2 x 2 grid); closing window 0 itself keeps it.
]]
function InventoryState.close(self: InventoryState, key: any): { Stack }
	local player = self.players[key]
	if player == nil then
		return {}
	end
	local window = player.window
	local thrown = Menu.close(window)
	local open = player.open
	if open then
		player.open = nil
		if isShared(window.container) then
			self.containers:removeViewer(open.x, open.y, open.z, key)
		end
	end
	local container = window.container
	if window.id ~= 0 or container == nil or container.kind ~= "inventory" then
		window.id = 0
		window.container = Types.newCrafting("inventory")
	end
	player.dirty = true
	return thrown
end

-- Block position of the player's open block window, or nil.
function InventoryState.openPosition(self: InventoryState, key: any): (number?, number, number)
	local player = self.players[key]
	local open = player and player.open
	if open == nil then
		return nil, 0, 0
	end
	return open.x, open.y, open.z
end

--[[
	The block at (x, y, z) with a window is gone: removes a shared container there and closes that
	window for every player who has it open (a chest's or furnace's viewers and the players at a
	crafting table there; their cursors and grids go back into their inventories). Returns its
	contents (to drop where it was) and the players' leftovers (what did not fit back into their
	inventories).
]]
function InventoryState.removeContainer(
	self: InventoryState,
	x: number,
	y: number,
	z: number
): ({ Stack }, { Leftovers })
	-- Taken first, so closing its viewers' windows no longer finds it: a broken chest's lid makes
	-- no closing sound (Containers' onOpeners; Minecraft's ChestBlockEntity.stopOpen ignores a
	-- removed chest). take also forgets viewers who are gone.
	local container = self.containers:take(x, y, z)
	local leftovers: { Leftovers } = {}
	for key, player in self.players do
		local open = player.open
		if open and open.x == x and open.y == y and open.z == z then
			local stacks = self:close(key)
			if #stacks > 0 then
				table.insert(leftovers, { key = key, stacks = stacks })
			end
		end
	end
	local contents: { Stack } = {}
	if container then
		for slot = 1, container.size do
			local stack = container.slots[slot]
			local copied = Items.copyStack(stack)
			if copied then
				table.insert(contents, copied)
			end
		end
	end
	return contents, leftovers
end

-- An item entity touched the player: adds what fits (Inventory.add) and returns how many.
function InventoryState.pickup(self: InventoryState, key: any, stack: Stack): number
	local player = self.players[key]
	if player == nil or stack.count < 1 then
		return 0
	end
	local left = Menu.add(player.window.inventory, stack)
	local taken = stack.count - (if left then left.count else 0)
	if taken > 0 then
		player.dirty = true
	end
	return taken
end

-- The stack in the player's hand (the selected hotbar slot), or nil. Read only.
function InventoryState.heldStack(self: InventoryState, key: any): Stack?
	local player = self.players[key]
	if player == nil then
		return nil
	end
	local inventory = player.window.inventory
	local held = inventory.slots[inventory.selected]
	if held == nil or held.count < 1 then
		return nil
	end
	return held
end

--[[
	Replaces the stack in the player's hand (the selected hotbar slot) with `stack` (nil or a
	count below 1 empties it; its wear and data kept): a bucket filled or emptied
	(Players/ItemUse). A snapshot is due.
]]
function InventoryState.setHeld(self: InventoryState, key: any, stack: Stack?)
	local player = self.players[key]
	if player == nil then
		return
	end
	local inventory = player.window.inventory
	local count = if stack then stack.count else 0
	if
		stack
		and type(count) == "number"
		and count >= 1
		and count == math.floor(count)
		and Items.isValid(stack.item)
	then
		inventory.slots[inventory.selected] = Items.withCount(stack, count)
	else
		inventory.slots[inventory.selected] = nil
	end
	player.dirty = true
end

--[[
	Puts `stack` into the player's inventory (Minecraft's Inventory.add, Menu.add: the held slot,
	then stacks of the same item, then empty slots) and returns what did not fit (nil: all of it
	went in; the whole stack for a player who is not there). `stack` itself is not changed.
]]
function InventoryState.give(self: InventoryState, key: any, stack: Stack): Stack?
	local player = self.players[key]
	if player == nil then
		return Items.copyStack(stack)
	end
	local left = Menu.add(player.window.inventory, stack)
	player.dirty = true
	return left
end

-- Does `store` (slots 1..`size`) hold `item`?
local function holds(store: { [number]: Stack? }, size: number, item: number): boolean
	for slot = 1, size do
		local stack = store[slot]
		if stack and stack.item == item and stack.count >= 1 then
			return true
		end
	end
	return false
end

-- Does the player have `item` in their inventory, armor or equipment (Minecraft's
-- Inventory.contains, which looks at every compartment)?
function InventoryState.has(self: InventoryState, key: any, item: number): boolean
	local player = self.players[key]
	if player == nil then
		return false
	end
	local inventory = player.window.inventory
	return holds(inventory.slots, Types.INVENTORY_SIZE, item)
		or holds(inventory.armor, Types.ARMOR_SIZE, item)
		or holds(inventory.accessories, Types.ACCESSORY_SIZE, item)
		or holds(inventory.vanityArmor, Types.VANITY_ARMOR_SIZE, item)
		or holds(inventory.vanityAccessories, Types.VANITY_ACCESSORY_SIZE, item)
end

--[[
	The tool in the player's hand was used (Minecraft's ItemStack.hurtAndBreak): its damage grows by
	`amount` and at its item's durability it breaks (the slot empties). Returns true when it broke.
	Nothing happens (false) for an amount below 1 or a held stack that does not wear.
]]
function InventoryState.wearHeld(self: InventoryState, key: any, amount: number): boolean
	local player = self.players[key]
	if player == nil or type(amount) ~= "number" or not (amount >= 1) or amount == math.huge then
		return false
	end
	local inventory = player.window.inventory
	local selected = inventory.selected
	local held = inventory.slots[selected]
	local def = if held and held.count >= 1 then Items.get(held.item) else nil
	local durability = if def then def.durability else nil
	if held == nil or durability == nil then
		return false
	end
	local damage = (held.damage or 0) + math.floor(amount)
	player.dirty = true
	if damage >= durability then
		inventory.slots[selected] = nil
		return true
	end
	inventory.slots[selected] = Items.newStack(held.item, held.count, damage, held.data)
	return false
end

--[[
	The player died: their screen closes (the cursor and a crafting grid go back into the
	inventory), and unless `keepInventory` everything they had (armor and cursor too) is returned,
	to scatter where they died.
]]
function InventoryState.die(self: InventoryState, key: any, keepInventory: boolean): { Stack }
	local player = self.players[key]
	if player == nil then
		return {}
	end
	local stacks = self:close(key)
	if not keepInventory then
		for _, stack in Menu.clear(player.window.inventory) do
			table.insert(stacks, stack)
		end
	end
	player.dirty = true
	return stacks
end

function InventoryState.markDirty(self: InventoryState, key: any)
	local player = self.players[key]
	if player then
		player.dirty = true
	end
end

--[[
	A saved player's inventory (World/WorldSave): replaces what they hold (slots 1..36, armor 1..4,
	the selected hotbar slot), copies of the saved stacks; a saved cursor goes into the inventory
	(Inventory.add). Returns what did not fit (none for a record this inventory wrote). A snapshot
	is due.
]]
function InventoryState.restore(
	self: InventoryState,
	key: any,
	slots: { [number]: Stack? },
	armor: { [number]: Stack? },
	selected: number,
	cursor: Stack?
): { Stack }
	local player = self.players[key]
	if player == nil then
		return {}
	end
	local thrown = self:close(key)
	local inventory = player.window.inventory
	table.clear(inventory.slots)
	table.clear(inventory.armor)
	inventory.cursor = nil
	for slot = 1, Types.INVENTORY_SIZE do
		inventory.slots[slot] = Items.copyStack(slots[slot])
	end
	for slot = 1, Types.ARMOR_SIZE do
		inventory.armor[slot] = Items.copyStack(armor[slot])
	end
	if selected >= 1 and selected <= Types.HOTBAR_SIZE and selected == math.floor(selected) then
		inventory.selected = selected
	end
	if cursor and cursor.count >= 1 then
		local left = Menu.add(inventory, cursor)
		if left then
			table.insert(thrown, left)
		end
	end
	player.dirty = true
	return thrown
end

--[[
	A saved character's equipment (Terraria's accessories, vanity armor and vanity accessories and
	the hidden looks: Inventory/Types): replaces what the player wears there with copies of the
	saved stacks, and the hidden bits. Nothing is checked or thrown here (the record was written
	from a window); what the slots allow is Inventory/Menu's. A snapshot is due.
]]
function InventoryState.restoreEquipment(self: InventoryState, key: any, equipment: Types.Equipment)
	local player = self.players[key]
	if player == nil then
		return
	end
	local inventory = player.window.inventory
	local function copyInto(into: { [number]: Stack? }, from: { [number]: Stack? }, size: number)
		table.clear(into)
		for slot = 1, size do
			into[slot] = Items.copyStack(from[slot])
		end
	end
	copyInto(inventory.accessories, equipment.accessories, Types.ACCESSORY_SIZE)
	copyInto(inventory.vanityArmor, equipment.vanityArmor, Types.VANITY_ARMOR_SIZE)
	copyInto(inventory.vanityAccessories, equipment.vanityAccessories, Types.VANITY_ACCESSORY_SIZE)
	-- (Only the bits a snapshot may carry: Types.HIDDEN_MASK; the client refuses any other.)
	local hidden = equipment.hidden
	inventory.hidden = if hidden == hidden and hidden >= 0
		then bit32.band(math.floor(hidden) % 65536, Types.HIDDEN_MASK)
		else 0
	player.dirty = true
end

--[[
	The player has `slots` accessory slots open (their Age's: Items/Accessories.slotsForAge; kept
	within 0..Types.ACCESSORY_SIZE). What the closed ones hold stays (Inventory/Menu: it can be
	taken out and does nothing). Returns whether it changed (a snapshot is then due).
]]
function InventoryState.setAccessorySlots(self: InventoryState, key: any, slots: number): boolean
	local player = self.players[key]
	if player == nil or slots ~= slots then
		return false
	end
	local open = math.clamp(math.floor(slots), 0, Types.ACCESSORY_SIZE)
	local inventory = player.window.inventory
	if inventory.accessorySlots == open then
		return false
	end
	inventory.accessorySlots = open
	player.dirty = true
	return true
end

-- The players due a snapshot (clears their flags).
function InventoryState.takeDirty(self: InventoryState): { any }
	local keys = {}
	for key, player in self.players do
		if player.dirty then
			player.dirty = false
			table.insert(keys, key)
		end
	end
	return keys
end

return InventoryState

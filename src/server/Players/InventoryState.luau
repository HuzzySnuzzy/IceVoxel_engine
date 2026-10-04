--!strict
--[[
	Every player's authoritative inventory on the server, without the Roblox parts (those are in
	Players/Inventories), so the tests can run it.

	Per player (any key; Players in the game):
	  window   Types.Window: id 0 with the inventory alone, or a container window (ids 1..255,
	           cycling, never 0) sharing the container's table with its other viewers (Containers)
	  ack      the number of the player's last inventory action handled. Clients number their
	           actions (Protocol) and predict them; a snapshot says which ones it includes, so the
	           client drops those and replays the rest on top of it
	  dirty    something changed (or an action was handled): send a snapshot. Many changes in one
	           frame make one snapshot (`takeDirty`)

	Actions run through Inventory/Menu in arrival order. Invalid ones change nothing but are still
	acknowledged, so the client's prediction of them is undone. A change to a shared container
	marks its other viewers dirty too.

	Functions that take stacks out of the world (throws, close leftovers, deaths) return them; the
	caller turns them into item entities.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Items = require(Shared.Items)
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
	-- Block position of the open container.
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
	place: (self: InventoryState, key: any, block: number, seq: number, creative: boolean) -> boolean,
	acknowledge: (self: InventoryState, key: any, seq: number) -> (),
	open: (self: InventoryState, key: any, x: number, y: number, z: number, block: number) -> { Stack },
	close: (self: InventoryState, key: any) -> { Stack },
	openPosition: (self: InventoryState, key: any) -> (number?, number, number),
	removeContainer: (self: InventoryState, x: number, y: number, z: number) -> ({ Stack }, { Leftovers }),
	pickup: (self: InventoryState, key: any, stack: Stack) -> number,
	die: (self: InventoryState, key: any, keepInventory: boolean) -> { Stack },
	markDirty: (self: InventoryState, key: any) -> (),
	takeDirty: (self: InventoryState) -> { any },
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
		window = { id = 0, inventory = Types.newInventory(), container = nil },
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

local function markViewers(self: InventoryState, key: any, player: PlayerState)
	local open = player.open
	if open == nil then
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
	(to drop in front of the player). A valid `close` also closes the container window.
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
	A block placement (inventory action `seq`), after the edit passed every other check. Survival:
	the held stack must be the block's item, and one is used up. Creative: nothing is used.
	Acknowledges `seq` either way. false = refuse the placement.
]]
function InventoryState.place(self: InventoryState, key: any, block: number, seq: number, creative: boolean): boolean
	local player = self.players[key]
	if player == nil then
		return false
	end
	acknowledge(player, seq)
	if creative then
		return true
	end
	local item = Items.ofBlock(block)
	local inventory = player.window.inventory
	local held = inventory.slots[inventory.selected]
	if item == nil or held == nil or held.item ~= item or held.count < 1 then
		return false
	end
	Menu.apply(player.window, { kind = "place", item = item }, false)
	return true
end

-- Acknowledges action `seq` without changing anything (a refused placement: undoes the prediction).
function InventoryState.acknowledge(self: InventoryState, key: any, seq: number)
	local player = self.players[key]
	if player then
		acknowledge(player, seq)
	end
end

--[[
	Opens the container block `block` at (x, y, z) for the player in a new window, closing what
	was open (the cursor goes back into the inventory). Returns the stacks that did not fit back.
]]
function InventoryState.open(self: InventoryState, key: any, x: number, y: number, z: number, block: number): { Stack }
	local player = self.players[key]
	if player == nil then
		return {}
	end
	local thrown = self:close(key)
	local container = self.containers:get(x, y, z, block)
	self.containers:addViewer(x, y, z, key)
	player.lastWindow = player.lastWindow % MAX_WINDOW + 1
	player.window.id = player.lastWindow
	player.window.container = container
	player.open = { x = x, y = y, z = z }
	player.dirty = true
	return thrown
end

--[[
	Closes the player's screen: the cursor goes back into the inventory and an open container
	window becomes the inventory alone (id 0). Returns what did not fit back.
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
		self.containers:removeViewer(open.x, open.y, open.z, key)
	end
	window.id = 0
	window.container = nil
	player.dirty = true
	return thrown
end

-- Block position of the player's open container, or nil.
function InventoryState.openPosition(self: InventoryState, key: any): (number?, number, number)
	local player = self.players[key]
	local open = player and player.open
	if open == nil then
		return nil, 0, 0
	end
	return open.x, open.y, open.z
end

--[[
	The container block at (x, y, z) is gone: closes it for everyone who has it open and removes
	it. Returns its contents (to drop where it was) and the viewers' leftovers (cursor stacks that
	did not fit back into their inventories).
]]
function InventoryState.removeContainer(
	self: InventoryState,
	x: number,
	y: number,
	z: number
): ({ Stack }, { Leftovers })
	local leftovers: { Leftovers } = {}
	for _, viewer in self.containers:viewers(x, y, z) do
		local player = self.players[viewer]
		local open = player and player.open
		if open and open.x == x and open.y == y and open.z == z then
			local stacks = self:close(viewer)
			if #stacks > 0 then
				table.insert(leftovers, { key = viewer, stacks = stacks })
			end
		else
			self.containers:removeViewer(x, y, z, viewer)
		end
	end
	local contents: { Stack } = {}
	local container = self.containers:take(x, y, z)
	if container then
		for slot = 1, container.size do
			local stack = container.slots[slot]
			if stack and stack.count > 0 then
				table.insert(contents, { item = stack.item, count = stack.count })
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

--[[
	The player died: their screen closes, and unless `keepInventory` everything they had (armor and
	cursor too) is returned, to scatter where they died.
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

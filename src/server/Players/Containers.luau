--!strict
--[[
	The contents of container blocks (chests, furnaces and Mekanism machines), by block position,
	for the session. (Crafting tables hold nothing: their grids belong to the players using them,
	InventoryState.)

	A container is created empty the first time someone opens it (with the block's `container`
	slot count, Blocks; kind "furnace" with fresh smelting data for menu "Furnace" blocks, else
	"chest"), or for a machine (Shared/Machines) by server/Machines when the block appears: kind
	"machine" with its kind's slots and fresh data (Machines.newContainer). It is shared by
	everyone who has it open: every viewer's window holds the same Types.Container table, so a
	click by one viewer changes what the others see (Players/Inventories sends them a new
	snapshot). When the block goes (broken, replaced), `take` removes the contents so they can
	drop as items.

	Viewers are tracked per container (any keys; Players in the game). A container that is empty
	(and, for a furnace, neither burning nor cooking) and open by nobody is forgotten: opening it
	again creates it again, empty, which is the same thing, and keeps the table as small as the
	number of containers in use. A machine's is never forgotten while its block stands (it holds
	energy and its machine ticks it): only `take` removes it. A store's `onOpeners` hears when a
	container gets its first viewer and loses its last (Minecraft's ContainerOpenersCounter: the
	chest lid sounds, set by Players/Inventories); a container taken away (its block broken)
	closes silently.

	Furnaces cook whether anyone looks or not: `tickFurnaces` runs one Crafting/Smelting tick (20
	per second, Minecraft's AbstractFurnaceBlockEntity.serverTick) on every active furnace and says
	which ones changed. Only furnaces marked active (`markActive`, after a viewer changed one) are
	ticked; one whose tick changes nothing stays that way until someone changes it again (the tick
	only depends on the furnace), so it leaves the set and idle furnaces cost nothing.
	Furnaces push their results out on their own (Mekanism's ejector, Transmitters/Eject): the
	ones whose output holds something are kept in a set of their own (`ejectingFurnaces`), filled
	when a tick or a change leaves results in the output and emptied as the outputs are.

	Generated structures' chests (Structures, Generation): a store may be given `generated`, the
	contents the world generator put in a container. A container there gets them the first time
	it is needed: opened or read (`get`, `peek`: windows, pipes, a structure block's SAVE), or just
	before its block changes (`materialize`, called by the server script before anything else
	hears of the change, so a generated chest broken unopened drops what it held). Each position
	is asked once per session (`sourced`): emptied, broken or replaced, a generated chest never
	fills again, and a chest placed there later starts empty. Chests only ever came from edits
	before; generated ones are read without generating terrain, so the pipes see them where the
	chunk is loaded.

	Pure Luau (no Roblox APIs) so the tests can run it. `Containers.new()` makes a store; the
	module's own functions (`Containers.get`, `Containers.take`...) use the server's store.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Items = require(Shared.Items)
local Machines = require(Shared.Machines)
local Types = require(Shared.Inventory.Types)
local Smelting = require(Shared.Crafting.Smelting)

type Container = Types.Container

export type Entry = {
	x: number,
	y: number,
	z: number,
	container: Container,
	viewers: { [any]: boolean },
	viewerCount: number,
}

-- A furnace that changed in a tick: where, and whether its slots changed (else only its data:
-- the flame and the progress arrow).
export type FurnaceChange = { x: number, y: number, z: number, slots: boolean }

-- What the world generator put in containers (generated structures' chests).
export type Generated = {
	-- The block at (x, y, z) without generating terrain (nil: its chunk is not loaded).
	blockAt: (x: number, y: number, z: number) -> number?,
	-- What the container block `block` at (x, y, z) held when it was generated (slot -> stack;
	-- nil or empty: nothing, or no generated container there).
	contents: (x: number, y: number, z: number, block: number) -> { [number]: Types.Stack }?,
}

export type Store = {
	entries: { [string]: Entry },
	count: number,
	-- Keys of the furnaces to tick.
	active: { [string]: boolean },
	-- Keys of the furnaces whose output may hold results to push out (Transmitters/Eject).
	ejecting: { [string]: boolean },
	-- Called when a container gets its first viewer (opened = true) or loses its last (false).
	onOpeners: ((x: number, y: number, z: number, container: Container, opened: boolean) -> ())?,
	-- Generated containers' contents (nil: none), and the positions already asked about.
	generated: Generated?,
	sourced: { [string]: boolean },

	get: (self: Store, x: number, y: number, z: number, block: number) -> Container,
	peek: (self: Store, x: number, y: number, z: number) -> Container?,
	materialize: (self: Store, x: number, y: number, z: number, block: number) -> (),
	take: (self: Store, x: number, y: number, z: number) -> (Container?, { any }),
	addViewer: (self: Store, x: number, y: number, z: number, viewer: any) -> (),
	removeViewer: (self: Store, x: number, y: number, z: number, viewer: any) -> (),
	viewers: (self: Store, x: number, y: number, z: number) -> { any },
	markActive: (self: Store, x: number, y: number, z: number) -> (),
	tickFurnaces: (self: Store) -> { FurnaceChange },
	ejectingFurnaces: (self: Store) -> { Entry },
}

local Store = {}
Store.__index = Store

local function keyOf(x: number, y: number, z: number): string
	return `{x},{y},{z}`
end

-- Does a furnace's output hold anything (results to push out)?
local function hasResults(container: Container): boolean
	local output = container.slots[Types.FURNACE_OUTPUT]
	return output ~= nil and output.count > 0
end

-- Nothing in it worth keeping: no items and, for a furnace, no fire or cooking progress. A
-- machine's always is worth keeping (its energy, its place in an energy network).
local function isEmpty(container: Container): boolean
	if container.kind == Machines.CONTAINER_KIND then
		return false
	end
	for slot = 1, container.size do
		local stack = container.slots[slot]
		if stack and stack.count > 0 then
			return false
		end
	end
	local data = container.data
	return data == nil or (data[1] <= 0 and data[3] <= 0)
end

-- Slot count of a container block (a machine's kind's; 0 for other blocks).
local function sizeOf(block: number): number
	return math.clamp(Machines.containerSize(block), 0, Types.MAX_CONTAINER)
end

--[[
	What the generator put in the container block `block` at (x, y, z), asked once per position
	(chests and furnaces only: machines come from edits). nil when there is nothing, it was asked
	before, or the store has no generator.
]]
local function source(
	self: Store,
	key: string,
	x: number,
	y: number,
	z: number,
	block: number
): { [number]: Types.Stack }?
	local generated = self.generated
	if generated == nil or self.sourced[key] or Machines.isMachine(block) then
		return nil
	end
	self.sourced[key] = true
	local ok, contents = pcall(generated.contents, x, y, z, block)
	if not ok or type(contents) ~= "table" then
		return nil
	end
	return contents
end

-- Puts `contents` (slot -> stack) into a fresh container, slots within its size only.
local function fill(container: Container, contents: { [number]: Types.Stack })
	for slot, stack in contents do
		if type(slot) == "number" and slot >= 1 and slot <= container.size and slot == math.floor(slot) then
			container.slots[slot] = Items.copyStack(stack)
		end
	end
end

--[[
	The container at block (x, y, z), created empty if there is none. `block` is the container
	block there (its slot count and name). A stored container of a different block is stale (its
	block was replaced without `take`) and starts afresh.
]]
function Store.get(self: Store, x: number, y: number, z: number, block: number): Container
	local key = keyOf(x, y, z)
	local entry = self.entries[key]
	if entry and entry.container.block == block then
		return entry.container
	end
	local container: Container
	if Machines.isMachine(block) then
		container = Machines.newContainer(block)
	else
		local size = sizeOf(block)
		assert(size > 0, `Block {block} is not a container`)
		local furnace = Blocks.get(block).menu == "Furnace"
		container = {
			kind = if furnace then "furnace" else "chest",
			block = block,
			size = size,
			slots = {},
			data = if furnace then Smelting.newData() else nil,
		}
	end
	if entry then
		entry.container = container
	else
		-- (A fresh container where a generated one stood gets what the generator put there.)
		local contents = source(self, key, x, y, z, block)
		if contents then
			fill(container, contents)
		end
		self.entries[key] = {
			x = x,
			y = y,
			z = z,
			container = container,
			viewers = {},
			viewerCount = 0,
		}
		self.count += 1
	end
	return container
end

--[[
	The container at (x, y, z) if one is stored. It never creates an empty one, but a generated
	container not yet asked about gets its contents now (when its chunk is loaded).
]]
function Store.peek(self: Store, x: number, y: number, z: number): Container?
	local key = keyOf(x, y, z)
	local entry = self.entries[key]
	if entry then
		return entry.container
	end
	local generated = self.generated
	if generated == nil or self.sourced[key] then
		return nil
	end
	local block = generated.blockAt(x, y, z)
	if block ~= nil and sizeOf(block) > 0 and not Machines.isMachine(block) then
		Store.materialize(self, x, y, z, block)
		local made = self.entries[key]
		return if made then made.container else nil
	end
	return nil
end

--[[
	The container block `block` is (or was, just now) at (x, y, z): if the generator put contents
	there that nobody has asked for yet, the container is created with them. The server script
	calls it with the old block before anything else hears of a block change, so a generated chest
	broken or replaced unopened still drops what it held.
]]
function Store.materialize(self: Store, x: number, y: number, z: number, block: number)
	-- (Every block change in the world comes through: most are no container.)
	if self.generated == nil or sizeOf(block) <= 0 or Machines.isMachine(block) then
		return
	end
	local key = keyOf(x, y, z)
	if self.entries[key] or self.sourced[key] then
		return
	end
	local contents = source(self, key, x, y, z, block)
	if contents and next(contents) ~= nil then
		-- (`get` would ask again: the position is marked asked, so it makes it empty, then fills it.)
		local container = Store.get(self, x, y, z, block)
		fill(container, contents)
	end
end

--[[
	Removes the container at (x, y, z) (its block is gone) and returns it with the players who
	still had it open. Callers close those viewers' windows (Players/Inventories does).
]]
function Store.take(self: Store, x: number, y: number, z: number): (Container?, { any })
	local key = keyOf(x, y, z)
	local entry = self.entries[key]
	if entry == nil then
		return nil, {}
	end
	self.entries[key] = nil
	self.count -= 1
	self.active[key] = nil
	self.ejecting[key] = nil
	local viewers = {}
	for viewer in entry.viewers do
		table.insert(viewers, viewer)
	end
	return entry.container, viewers
end

-- Records that `viewer` has the container at (x, y, z) open (it must exist: `get` first).
function Store.addViewer(self: Store, x: number, y: number, z: number, viewer: any)
	local entry = self.entries[keyOf(x, y, z)]
	if entry and not entry.viewers[viewer] then
		entry.viewers[viewer] = true
		entry.viewerCount += 1
		local onOpeners = self.onOpeners
		if entry.viewerCount == 1 and onOpeners then
			onOpeners(x, y, z, entry.container, true)
		end
	end
end

-- `viewer` closed the container; an empty container nobody looks at is forgotten.
function Store.removeViewer(self: Store, x: number, y: number, z: number, viewer: any)
	local key = keyOf(x, y, z)
	local entry = self.entries[key]
	if entry == nil or not entry.viewers[viewer] then
		return
	end
	entry.viewers[viewer] = nil
	entry.viewerCount -= 1
	local onOpeners = self.onOpeners
	if entry.viewerCount == 0 and onOpeners then
		onOpeners(x, y, z, entry.container, false)
	end
	if entry.viewerCount == 0 and isEmpty(entry.container) then
		self.entries[key] = nil
		self.count -= 1
		self.active[key] = nil
		self.ejecting[key] = nil
	end
end

-- Everyone who has the container at (x, y, z) open (a new list).
function Store.viewers(self: Store, x: number, y: number, z: number): { any }
	local list = {}
	local entry = self.entries[keyOf(x, y, z)]
	if entry then
		for viewer in entry.viewers do
			table.insert(list, viewer)
		end
	end
	return list
end

--[[
	Something may have changed the furnace at (x, y, z) (a viewer's click, a transporter): it is
	ticked from now on until it settles, and pushes out what its output holds. Does nothing where
	there is no furnace.
]]
function Store.markActive(self: Store, x: number, y: number, z: number)
	local key = keyOf(x, y, z)
	local entry = self.entries[key]
	if entry and entry.container.kind == "furnace" then
		self.active[key] = true
		if hasResults(entry.container) then
			self.ejecting[key] = true
		end
	end
end

--[[
	One furnace tick (Crafting/Smelting.tick) for every active furnace, viewed or not. Returns the
	furnaces that changed. A furnace that settles (nothing to burn or cook, or nothing changed)
	leaves the active set, and is forgotten if it is also empty and nobody has it open.
]]
function Store.tickFurnaces(self: Store): { FurnaceChange }
	local changes: { FurnaceChange } = {}
	for key in self.active do
		local entry = self.entries[key]
		local furnace = if entry then entry.container else nil
		if entry == nil or furnace == nil or furnace.kind ~= "furnace" then
			self.active[key] = nil
			continue
		end
		local slots = furnace.slots
		local input, fuel, output = slots[1], slots[2], slots[3]
		if Smelting.active(furnace) and Smelting.tick(furnace) then
			-- (Smelting replaces stack tables rather than changing them.)
			local slotsChanged = slots[1] ~= input or slots[2] ~= fuel or slots[3] ~= output
			table.insert(changes, { x = entry.x, y = entry.y, z = entry.z, slots = slotsChanged })
			if slots[3] ~= output and hasResults(furnace) then
				self.ejecting[key] = true
			end
		else
			self.active[key] = nil
			if entry.viewerCount == 0 and isEmpty(furnace) then
				self.entries[key] = nil
				self.count -= 1
				self.ejecting[key] = nil
			end
		end
	end
	return changes
end

--[[
	The furnaces whose output holds results to push out (Transmitters/Eject runs them every 10
	ticks); furnaces whose output is empty, or that are gone, leave the set.
]]
function Store.ejectingFurnaces(self: Store): { Entry }
	local list: { Entry } = {}
	for key in self.ejecting do
		local entry = self.entries[key]
		if entry and entry.container.kind == "furnace" and hasResults(entry.container) then
			table.insert(list, entry)
		else
			self.ejecting[key] = nil
		end
	end
	return list
end

local Containers = {}

-- A new, empty store (the tests make their own; the game uses `Containers.default`).
function Containers.new(): Store
	return (setmetatable({ entries = {}, count = 0, active = {}, ejecting = {}, sourced = {} }, Store) :: any) :: Store
end

-- The server's containers.
Containers.default = Containers.new()

function Containers.get(x: number, y: number, z: number, block: number): Container
	return Containers.default:get(x, y, z, block)
end

function Containers.peek(x: number, y: number, z: number): Container?
	return Containers.default:peek(x, y, z)
end

function Containers.take(x: number, y: number, z: number): (Container?, { any })
	return Containers.default:take(x, y, z)
end

function Containers.materialize(x: number, y: number, z: number, block: number)
	Containers.default:materialize(x, y, z, block)
end

function Containers.viewers(x: number, y: number, z: number): { any }
	return Containers.default:viewers(x, y, z)
end

return Containers

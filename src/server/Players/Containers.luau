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

	Pure Luau (no Roblox APIs) so the tests can run it. `Containers.new()` makes a store; the
	module's own functions (`Containers.get`, `Containers.take`...) use the server's store.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
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

export type Store = {
	entries: { [string]: Entry },
	count: number,
	-- Keys of the furnaces to tick.
	active: { [string]: boolean },
	-- Called when a container gets its first viewer (opened = true) or loses its last (false).
	onOpeners: ((x: number, y: number, z: number, container: Container, opened: boolean) -> ())?,

	get: (self: Store, x: number, y: number, z: number, block: number) -> Container,
	peek: (self: Store, x: number, y: number, z: number) -> Container?,
	take: (self: Store, x: number, y: number, z: number) -> (Container?, { any }),
	addViewer: (self: Store, x: number, y: number, z: number, viewer: any) -> (),
	removeViewer: (self: Store, x: number, y: number, z: number, viewer: any) -> (),
	viewers: (self: Store, x: number, y: number, z: number) -> { any },
	markActive: (self: Store, x: number, y: number, z: number) -> (),
	tickFurnaces: (self: Store) -> { FurnaceChange },
}

local Store = {}
Store.__index = Store

local function keyOf(x: number, y: number, z: number): string
	return `{x},{y},{z}`
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

-- The container at (x, y, z) if one is stored (never creates one).
function Store.peek(self: Store, x: number, y: number, z: number): Container?
	local entry = self.entries[keyOf(x, y, z)]
	return if entry then entry.container else nil
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
	Something may have changed the furnace at (x, y, z) (a viewer's click): it is ticked from now
	on until it settles. Does nothing where there is no furnace.
]]
function Store.markActive(self: Store, x: number, y: number, z: number)
	local key = keyOf(x, y, z)
	local entry = self.entries[key]
	if entry and entry.container.kind == "furnace" then
		self.active[key] = true
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
		else
			self.active[key] = nil
			if entry.viewerCount == 0 and isEmpty(furnace) then
				self.entries[key] = nil
				self.count -= 1
			end
		end
	end
	return changes
end

local Containers = {}

-- A new, empty store (the tests make their own; the game uses `Containers.default`).
function Containers.new(): Store
	return (setmetatable({ entries = {}, count = 0, active = {} }, Store) :: any) :: Store
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

function Containers.viewers(x: number, y: number, z: number): { any }
	return Containers.default:viewers(x, y, z)
end

return Containers

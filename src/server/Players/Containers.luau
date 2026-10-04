--!strict
--[[
	The contents of container blocks (chests), by block position, for the session.

	A container is created empty the first time someone opens it (with the block's `container`
	slot count, Blocks) and is shared by everyone who has it open: every viewer's window holds the
	same Types.Container table, so a click by one viewer changes what the others see
	(Players/Inventories sends them a new snapshot). When the block goes (broken, replaced), `take`
	removes the contents so they can drop as items.

	Viewers are tracked per container (any keys; Players in the game). A container that is empty
	and open by nobody is forgotten: opening it again creates it again, empty, which is the same
	thing, and keeps the table as small as the number of chests in use.

	Pure Luau (no Roblox APIs) so the tests can run it. `Containers.new()` makes a store; the
	module's own functions (`Containers.get`, `Containers.take`...) use the server's store.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Types = require(Shared.Inventory.Types)

type Container = Types.Container

export type Entry = {
	x: number,
	y: number,
	z: number,
	container: Container,
	viewers: { [any]: boolean },
	viewerCount: number,
}

export type Store = {
	entries: { [string]: Entry },
	count: number,

	get: (self: Store, x: number, y: number, z: number, block: number) -> Container,
	peek: (self: Store, x: number, y: number, z: number) -> Container?,
	take: (self: Store, x: number, y: number, z: number) -> (Container?, { any }),
	addViewer: (self: Store, x: number, y: number, z: number, viewer: any) -> (),
	removeViewer: (self: Store, x: number, y: number, z: number, viewer: any) -> (),
	viewers: (self: Store, x: number, y: number, z: number) -> { any },
}

local Store = {}
Store.__index = Store

local function keyOf(x: number, y: number, z: number): string
	return `{x},{y},{z}`
end

local function isEmpty(container: Container): boolean
	for slot = 1, container.size do
		local stack = container.slots[slot]
		if stack and stack.count > 0 then
			return false
		end
	end
	return true
end

-- Slot count of a container block (0 for other blocks).
local function sizeOf(block: number): number
	local def = if Blocks.isValid(block) then Blocks.get(block) else nil
	return if def then math.clamp(def.container, 0, Types.MAX_CONTAINER) else 0
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
	local size = sizeOf(block)
	assert(size > 0, `Block {block} is not a container`)
	local container: Container = { block = block, size = size, slots = {} }
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
	if entry.viewerCount == 0 and isEmpty(entry.container) then
		self.entries[key] = nil
		self.count -= 1
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

local Containers = {}

-- A new, empty store (the tests make their own; the game uses `Containers.default`).
function Containers.new(): Store
	return (setmetatable({ entries = {}, count = 0 }, Store) :: any) :: Store
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

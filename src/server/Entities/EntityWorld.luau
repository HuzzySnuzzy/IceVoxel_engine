--!strict
--[[
	Dropped items on the server: Minecraft Java Edition 1.20.1's ItemEntity rules, without any
	Roblox APIs so tests can run them (Entities is the Roblox side: players, replication).

	Each tick, in entity id order (oldest first):
	  physics    ItemPhysics.tick (frozen while the item's block is not loaded);
	  pickup     the pickup delay counts down (10 ticks for block drops, 40 for thrown items);
	  merging    every 2 ticks while the item moved to another block this tick, else every 40: it
	             merges with items of the same kind (and the same damage: a tool's wear) whose
	             boxes touch its box grown by 0.5 sideways. Both must hold less than a full stack
	             and their sum must fit one; the smaller merges into the larger (on a tie, the
	             item checking merges into the other), which keeps the longer pickup delay and the
	             younger age (ItemEntity.mergeWithNeighbours / tryToMerge). Merging runs after
	             every item has moved, rather than in the middle of the tick as in Minecraft;
	  despawn    after `lifetimeTicks` of age (Minecraft: 6000, 5 minutes).
	Then players pick items up: a player's box (0.6 x 1.8 at the feet) grown by (1, 0.5, 1)
	touching an item whose pickup delay is over (Player.aiStep / ItemEntity.playerTouch).
	`tryPickup` answers how many it took; the item keeps the rest.

	Items carry their stack's `damage` (a tool's wear; nil when new) from spawning to pickup.

	At most `maxItems` items exist; spawning more removes the oldest first.

	Changes for replication pile up until `takeChanges`: spawned items, items to resync (at most
	every 20 ticks while moving, ServerEntity's update interval for items, plus once when they come
	to rest: 4 ticks without moving), count changes and removals (with the collecting player's key,
	nil otherwise).

	Positions are in blocks: an item's position is the bottom centre of its 0.25 block box.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Items = require(Shared.Items)
local ItemPhysics = require(Shared.Entities.ItemPhysics)

type Body = ItemPhysics.Body

export type Entity = {
	id: number,
	item: number,
	count: number,
	-- A tool's wear (Items.Stack.damage), nil when new.
	damage: number?,
	body: Body,
	-- Ticks until players can pick it up.
	pickupDelay: number,
	-- Ticks towards despawning (Minecraft's ItemEntity.age; merging keeps the younger one's).
	age: number,
	-- Bookkeeping: removed from the world, ticks since the last sync, moved since the last sync,
	-- ticks without moving.
	removed: boolean,
	sinceSync: number,
	unsynced: boolean,
	still: number,
}

export type PlayerBox = { key: any, x: number, y: number, z: number }

-- How many of `count` items (`damage`: a tool's wear) player `key` takes.
export type TryPickup = (key: any, item: number, count: number, damage: number?) -> number

export type Changes = {
	spawned: { number },
	moved: { number },
	counts: { number },
	removed: { { id: number, collector: any } },
	-- Partial pickups: `count` items of entity `id` went to `collector` (the entity keeps the rest).
	taken: { { id: number, count: number, collector: any } },
}

export type Options = {
	maxItems: number,
	lifetimeTicks: number,
	-- Picks the velocity of items spawned without one (math.random when absent).
	random: Random?,
}

export type EntityWorld = {
	getBlock: ItemPhysics.GetBlock,
	options: Options,
	nextId: number,
	byId: { [number]: Entity },
	-- Every entity in id order; removed ones linger until the end of the next tick.
	order: { Entity },
	-- First index of `order` that may hold a live entity.
	head: number,
	live: number,
	spawnedSet: { [number]: boolean },
	movedSet: { [number]: boolean },
	countSet: { [number]: boolean },
	removedList: { { id: number, collector: any } },
	takenList: { { id: number, count: number, collector: any } },

	spawnItem: (
		self: EntityWorld,
		item: number,
		count: number,
		x: number,
		y: number,
		z: number,
		vx: number?,
		vy: number?,
		vz: number?,
		pickupDelay: number?,
		damage: number?
	) -> number,
	tick: (self: EntityWorld, players: { PlayerBox }, tryPickup: TryPickup) -> (),
	takeChanges: (self: EntityWorld) -> Changes,
	get: (self: EntityWorld, id: number) -> Entity?,
	count: (self: EntityWorld) -> number,
	remove: (self: EntityWorld, id: number) -> (),
	each: (self: EntityWorld) -> { Entity },
}

local EntityWorld = {}
EntityWorld.__index = EntityWorld

-- Minecraft's numbers.
EntityWorld.DEFAULT_PICKUP_DELAY = 10
EntityWorld.THROWN_PICKUP_DELAY = 40
EntityWorld.SYNC_INTERVAL = 20
-- An item is at rest after this many ticks without moving (resting items move every fourth tick,
-- and may creep a little on those).
EntityWorld.REST_TICKS = 4
local MERGE_MOVING = 2
local MERGE_RESTING = 40
-- Merging looks this far sideways; pickups this far around the player's box.
local MERGE_REACH = 0.5
local PICKUP_REACH_XZ = 1
local PICKUP_REACH_Y = 0.5
local PLAYER_WIDTH = 0.6
local PLAYER_HEIGHT = 1.8

local WIDTH = ItemPhysics.WIDTH
local HEIGHT = ItemPhysics.HEIGHT
local HALF = WIDTH / 2

local floor = math.floor

function EntityWorld.new(getBlock: ItemPhysics.GetBlock, options: Options): EntityWorld
	local self = {
		getBlock = getBlock,
		options = options,
		nextId = 1,
		byId = {},
		order = {},
		head = 1,
		live = 0,
		spawnedSet = {},
		movedSet = {},
		countSet = {},
		removedList = {},
		takenList = {},
	}
	return (setmetatable(self, EntityWorld) :: any) :: EntityWorld
end

local function randomUnit(self: EntityWorld): number
	local random = self.options.random
	return if random then random:NextNumber() else math.random()
end

local function removeEntity(self: EntityWorld, entity: Entity, collector: any)
	if entity.removed then
		return
	end
	entity.removed = true
	self.byId[entity.id] = nil
	self.live -= 1
	table.insert(self.removedList, { id = entity.id, collector = collector })
end

--[[
	Adds an item entity and returns its id (ids only grow). Without a velocity it gets
	Minecraft's default: (random +-0.1, 0.2, random +-0.1). The pickup delay defaults to 10 ticks.
	`damage` is the stack's wear (a whole number; 0, nil or nonsense mean new).
]]
function EntityWorld.spawnItem(
	self: EntityWorld,
	item: number,
	count: number,
	x: number,
	y: number,
	z: number,
	vx: number?,
	vy: number?,
	vz: number?,
	pickupDelay: number?,
	damage: number?
): number
	local id = self.nextId
	self.nextId += 1
	local body =
		ItemPhysics.new(x, y, z, vx or randomUnit(self) * 0.2 - 0.1, vy or 0.2, vz or randomUnit(self) * 0.2 - 0.1)
	local entity: Entity = {
		id = id,
		item = item,
		count = count,
		damage = if type(damage) == "number" and damage >= 1 and damage < math.huge then floor(damage) else nil,
		body = body,
		pickupDelay = pickupDelay or EntityWorld.DEFAULT_PICKUP_DELAY,
		age = 0,
		removed = false,
		sinceSync = 0,
		unsynced = false,
		still = 0,
	}
	self.byId[id] = entity
	table.insert(self.order, entity)
	self.live += 1
	self.spawnedSet[id] = true

	-- Over the cap: the oldest go first.
	local order = self.order
	while self.live > self.options.maxItems do
		local oldest = order[self.head]
		self.head += 1
		if not oldest.removed then
			removeEntity(self, oldest, nil)
		end
	end
	return id
end

function EntityWorld.get(self: EntityWorld, id: number): Entity?
	return self.byId[id]
end

function EntityWorld.count(self: EntityWorld): number
	return self.live
end

-- Removes an item without anyone collecting it (e.g. /kill-like cleanups).
function EntityWorld.remove(self: EntityWorld, id: number)
	local entity = self.byId[id]
	if entity then
		removeEntity(self, entity, nil)
	end
end

-- The live entities in id order (a new list).
function EntityWorld.each(self: EntityWorld): { Entity }
	local list = table.create(self.live)
	for i = self.head, #self.order do
		local entity = self.order[i]
		if not entity.removed then
			table.insert(list, entity)
		end
	end
	return list
end

--[[ Spatial lookup: entities by block column, rebuilt every tick ]]

type Grid = { [number]: { Entity } }

local function columnKey(x: number, z: number): number
	-- Unique for |z| < 2^23 (far beyond Protocol.MAX_COORDINATE).
	return x * 16777216 + z
end

local function buildGrid(entities: { Entity }): Grid
	local grid: Grid = {}
	for _, entity in entities do
		local key = columnKey(floor(entity.body.x), floor(entity.body.z))
		local cell = grid[key]
		if cell then
			table.insert(cell, entity)
		else
			grid[key] = { entity }
		end
	end
	return grid
end

-- Calls `visit` for every live entity whose column lies within [x0, x1] x [z0, z1] (blocks).
-- (Loops over a bounded number of columns, so no position, however far out, can make it run long.)
local MAX_COLUMNS = 8
local function forColumns(grid: Grid, x0: number, x1: number, z0: number, z1: number, visit: (Entity) -> boolean?)
	local bx, bz = floor(x0), floor(z0)
	if bx ~= bx or bz ~= bz or bx == math.huge or bx == -math.huge or bz == math.huge or bz == -math.huge then
		return
	end
	for i = 0, math.min(floor(x1) - bx, MAX_COLUMNS) do
		for j = 0, math.min(floor(z1) - bz, MAX_COLUMNS) do
			local cell = grid[columnKey(bx + i, bz + j)]
			if cell then
				for _, entity in cell do
					if not entity.removed and visit(entity) then
						return
					end
				end
			end
		end
	end
end

--[[ Merging (ItemEntity.isMergable / tryToMerge / merge) ]]

local function mergeable(self: EntityWorld, entity: Entity): boolean
	return not entity.removed and entity.age < self.options.lifetimeTicks and entity.count < Items.maxStack(entity.item)
end

-- Moves `from` into `into` (the caller checked that it all fits).
local function merge(self: EntityWorld, into: Entity, from: Entity)
	into.count += from.count
	into.pickupDelay = math.max(into.pickupDelay, from.pickupDelay)
	into.age = math.min(into.age, from.age)
	self.countSet[into.id] = true
	removeEntity(self, from, nil)
end

local function tryToMerge(self: EntityWorld, entity: Entity, other: Entity)
	-- (ItemStack.isSameItemSameTags: worn tools only merge with equally worn ones.)
	if
		other.item ~= entity.item
		or (other.damage or 0) ~= (entity.damage or 0)
		or other.count + entity.count > Items.maxStack(entity.item)
	then
		return
	end
	if other.count < entity.count then
		merge(self, entity, other)
	else
		merge(self, other, entity)
	end
end

local function mergeWithNeighbours(self: EntityWorld, entity: Entity, grid: Grid)
	local body = entity.body
	local minX, maxX = body.x - HALF - MERGE_REACH, body.x + HALF + MERGE_REACH
	local minY, maxY = body.y, body.y + HEIGHT
	local minZ, maxZ = body.z - HALF - MERGE_REACH, body.z + HALF + MERGE_REACH
	-- Neighbouring boxes reach HALF beyond their columns.
	forColumns(grid, minX - HALF, maxX + HALF, minZ - HALF, maxZ + HALF, function(other)
		if other == entity or not mergeable(self, other) then
			return false
		end
		local o = other.body
		if
			o.x - HALF < maxX
			and o.x + HALF > minX
			and o.y < maxY
			and o.y + HEIGHT > minY
			and o.z - HALF < maxZ
			and o.z + HALF > minZ
		then
			tryToMerge(self, entity, other)
		end
		-- Stop once this entity merged away.
		return entity.removed
	end)
end

--[[
	One server tick. `players` are the living players that may pick items up (feet positions in
	blocks); `tryPickup(key, item, count, damage)` returns how many of the items the player took.
]]
function EntityWorld.tick(self: EntityWorld, players: { PlayerBox }, tryPickup: TryPickup)
	local getBlock = self.getBlock
	local entities = EntityWorld.each(self)

	-- Physics and the merge schedule. Frozen items (in unloaded blocks) skip the whole tick.
	local ticked: { [Entity]: boolean } = {}
	local mergeDue: { [Entity]: boolean } = {}
	for _, entity in entities do
		local body = entity.body
		local ox, oy, oz = body.x, body.y, body.z
		if ItemPhysics.tick(body, entity.id, getBlock) then
			ticked[entity] = true
			if entity.pickupDelay > 0 then
				entity.pickupDelay -= 1
			end
			local crossed = floor(ox) ~= floor(body.x) or floor(oy) ~= floor(body.y) or floor(oz) ~= floor(body.z)
			if body.age % (if crossed then MERGE_MOVING else MERGE_RESTING) == 0 then
				mergeDue[entity] = true
			end

			-- Replication: resync while moving, at most every SYNC_INTERVAL ticks, and once at rest.
			entity.sinceSync += 1
			local sync = false
			if ox ~= body.x or oy ~= body.y or oz ~= body.z then
				entity.unsynced = true
				entity.still = 0
				sync = entity.sinceSync >= EntityWorld.SYNC_INTERVAL
			elseif entity.unsynced then
				entity.still += 1
				sync = entity.still >= EntityWorld.REST_TICKS
			end
			if sync then
				self.movedSet[entity.id] = true
				entity.sinceSync = 0
				entity.unsynced = false
			end
		end
	end

	local grid = buildGrid(entities)

	-- Merging, then ageing and despawning.
	for _, entity in entities do
		if mergeDue[entity] and mergeable(self, entity) then
			mergeWithNeighbours(self, entity, grid)
		end
	end
	local lifetime = self.options.lifetimeTicks
	for _, entity in entities do
		if ticked[entity] and not entity.removed then
			entity.age += 1
			if entity.age >= lifetime then
				removeEntity(self, entity, nil)
			end
		end
	end

	-- Pickups.
	for _, player in players do
		local half = PLAYER_WIDTH / 2 + PICKUP_REACH_XZ
		local minX, maxX = player.x - half, player.x + half
		local minY, maxY = player.y - PICKUP_REACH_Y, player.y + PLAYER_HEIGHT + PICKUP_REACH_Y
		local minZ, maxZ = player.z - half, player.z + half
		forColumns(grid, minX - HALF, maxX + HALF, minZ - HALF, maxZ + HALF, function(entity)
			local b = entity.body
			if
				entity.pickupDelay == 0
				and b.x - HALF < maxX
				and b.x + HALF > minX
				and b.y < maxY
				and b.y + HEIGHT > minY
				and b.z - HALF < maxZ
				and b.z + HALF > minZ
			then
				local taken = tryPickup(player.key, entity.item, entity.count, entity.damage)
				taken = if type(taken) == "number" and taken == taken
					then math.clamp(floor(taken), 0, entity.count)
					else 0
				if taken > 0 then
					entity.count -= taken
					if entity.count == 0 then
						removeEntity(self, entity, player.key)
					else
						self.countSet[entity.id] = true
						table.insert(self.takenList, { id = entity.id, count = taken, collector = player.key })
					end
				end
			end
			return false
		end)
	end

	-- Drop removed entities from the id order.
	local kept = table.create(self.live)
	for i = self.head, #self.order do
		local entity = self.order[i]
		if not entity.removed then
			table.insert(kept, entity)
		end
	end
	self.order = kept
	self.head = 1
end

local function sortedLive(self: EntityWorld, set: { [number]: boolean }): { number }
	local list = {}
	for id in set do
		if self.byId[id] then
			table.insert(list, id)
		end
	end
	table.sort(list)
	return list
end

-- The changes since the last call, ids in increasing order (only live ones, except `removed`).
function EntityWorld.takeChanges(self: EntityWorld): Changes
	local changes: Changes = {
		spawned = sortedLive(self, self.spawnedSet),
		moved = sortedLive(self, self.movedSet),
		counts = sortedLive(self, self.countSet),
		removed = self.removedList,
		taken = self.takenList,
	}
	self.spawnedSet = {}
	self.movedSet = {}
	self.countSet = {}
	self.removedList = {}
	self.takenList = {}
	return changes
end

return EntityWorld

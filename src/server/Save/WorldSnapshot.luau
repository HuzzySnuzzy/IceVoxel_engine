--!strict
--[[
	The world's state in regions and back (Save/RegionCodec's Region): what World/WorldSave writes
	at a save and puts back at a load, read from and written to the server's pure systems, so the
	specs run a whole round trip without Roblox (World/WorldServer, Players/Containers,
	Transmitters/TransmitterWorld, Machines/MachineWorld, Structures/StructureStore,
	Entities/EntityWorld, Mobs/MobWorld, World/BlockTicker).

	  collect    builds the regions a save writes, in one go (one frame: nothing changes between
	             two systems' reads, so a chest broken in the middle of a save can't be saved both
	             as a chest and as its dropped items): every region holding state now (containers,
	             generated chests asked about, structure blocks, pipes, tanks, items in
	             transporters, dropped items, farm animals, block updates due, those a load
	             gave back that wait for their chunk to generate: `pending`), every region that
	             held some at the last save (`previous`: what moved or went away must be written
	             out of it too, even when it is empty now) and every region whose edits changed
	             (`dirty`), each with all of its chunks' edits (the edit tables themselves, read
	             only: encode them at once). Returns those regions and the set of regions holding
	             state now (the next save's `previous`).
	  applyEdits the loaded regions' edits become the world's edit lists before anything else
	             starts: WorldServer overlays them on every chunk it generates, so nothing else is
	             needed for terrain.
	  restore    after every system started, before the world is published (no player is in it
	             yet): generated chests asked about, containers (the block's fresh container with
	             the saved slots and data copied in: a furnace's cooking resumes, a machine keeps
	             its energy, tanks and slots), then the edits' transmitters, tanks and the blocks
	             next to them (TransmitterWorld.blockChanged from air), machines
	             (MachineWorld.blockChanged: each finds its restored container) and structure
	             blocks and jigsaws (StructureStore.blockChanged, then their saved settings), the
	             pipes' saved state (TransmitterWorld.restoreState), dropped items (their age, so
	             they still despawn on time; frozen until their chunk loads, as any item) and farm
	             animals. Block updates that were due come back by chunk (`ticks`): World/WorldSave
	             schedules each chunk's when the server generates that chunk.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local ChunkLayout = require(Shared.World.ChunkLayout)
local Coords = require(Shared.World.Coords)
local Items = require(Shared.Items)
local Machines = require(Shared.Machines)
local MobList = require(Shared.Entities.MobList)
local Transmitters = require(Shared.Transmitters)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local BlockTicker = require(script.Parent.Parent.World.BlockTicker)
local Containers = require(script.Parent.Parent.Players.Containers)
local TransmitterWorld = require(script.Parent.Parent.Transmitters.TransmitterWorld)
local MachineWorld = require(script.Parent.Parent.Machines.MachineWorld)
local StructureStore = require(script.Parent.Parent.Structures.StructureStore)
local EntityWorld = require(script.Parent.Parent.Entities.EntityWorld)
local MobWorld = require(script.Parent.Parent.Mobs.MobWorld)
local RegionCodec = require(script.Parent.RegionCodec)

type Region = RegionCodec.Region

export type Systems = {
	world: WorldServer.World,
	containers: Containers.Store?,
	transmitters: TransmitterWorld.World?,
	machines: MachineWorld.World?,
	structures: StructureStore.Store?,
	items: EntityWorld.EntityWorld?,
	mobs: MobWorld.MobWorld?,
	ticker: BlockTicker.Ticker?,
}

export type Restored = {
	containers: number,
	pipes: number,
	machines: number,
	structures: number,
	items: number,
	mobs: number,
	-- Block updates due, by chunk key: World/WorldSave schedules them when the chunk generates.
	ticks: { [number]: { RegionCodec.TickRecord } },
}

local WorldSnapshot = {}

local SIZE = ChunkLayout.SIZE
local AIR = Blocks.AIR

local function regionFor(regions: { [string]: Region }, x: number, z: number): Region
	local rx, rz = RegionCodec.regionOfBlock(math.floor(x), math.floor(z))
	local name = RegionCodec.name(rx, rz)
	local region = regions[name]
	if region == nil then
		region = RegionCodec.new(rx, rz)
		regions[name] = region
	end
	return region
end

-- The "x,y,z" key Players/Containers files a position under, as numbers.
local function parseKey(key: string): (number?, number?, number?)
	local x, y, z = string.match(key, "^(%-?%d+),(%-?%d+),(%-?%d+)$")
	return tonumber(x), tonumber(y), tonumber(z)
end

--[[ Saving ]]

--[[
	The regions a save writes (see the header): `dirty` and `previous` are sets of region names
	(RegionCodec.name). `items` / `mobs` false leave dropped items / farm animals out. `pending`:
	loaded block updates not scheduled yet (Restored.ticks, what is left of it: their chunks were
	not generated since), saved again as they were (frozen, as in an unloaded chunk).
]]
function WorldSnapshot.collect(
	systems: Systems,
	dirty: { [string]: boolean }?,
	previous: { [string]: boolean }?,
	items: boolean?,
	mobs: boolean?,
	pending: { [number]: { RegionCodec.TickRecord } }?
): ({ [string]: Region }, { [string]: boolean })
	local regions: { [string]: Region } = {}

	local store = systems.containers
	if store then
		for _, entry in store.entries do
			table.insert(regionFor(regions, entry.x, entry.z).containers, {
				x = entry.x,
				y = entry.y,
				z = entry.z,
				container = entry.container,
			})
		end
		for key in store.sourced do
			local x, y, z = parseKey(key)
			if x and y and z then
				table.insert(regionFor(regions, x, z).sourced, Coords.posKey(x, y, z))
			end
		end
	end
	local structures = systems.structures
	if structures then
		for key, settings in structures.structures do
			local x, y, z = Coords.decodePosKey(key)
			table.insert(regionFor(regions, x, z).structures, { x = x, y = y, z = z, settings = settings })
		end
		for key, settings in structures.jigsaws do
			local x, y, z = Coords.decodePosKey(key)
			table.insert(regionFor(regions, x, z).jigsaws, { x = x, y = y, z = z, settings = settings })
		end
	end
	local pipes = systems.transmitters
	if pipes then
		local nodes, tanks, transport = TransmitterWorld.saveState(pipes)
		for _, node in nodes do
			table.insert(regionFor(regions, node.x, node.z).pipes, node)
		end
		for _, tank in tanks do
			table.insert(regionFor(regions, tank.x, tank.z).tanks, tank)
		end
		for _, item in transport do
			table.insert(regionFor(regions, item.x, item.z).transport, item)
		end
	end
	local entities = systems.items
	if entities and items ~= false then
		for _, entity in entities:each() do
			local stack = Items.newStack(entity.item, entity.count, entity.damage, entity.data)
			local body = entity.body
			if stack and not entity.removed then
				table.insert(regionFor(regions, body.x, body.z).items, {
					x = body.x,
					y = body.y,
					z = body.z,
					stack = stack,
					age = entity.age,
					pickupDelay = entity.pickupDelay,
				})
			end
		end
	end
	local animals = systems.mobs
	if animals and mobs ~= false then
		for _, mob in animals:each() do
			if not mob.dead and not mob.removed and not mob.kind.hostile then
				local body = mob.body
				table.insert(regionFor(regions, body.x, body.z).mobs, {
					kind = mob.kind.id,
					variant = mob.variant,
					x = body.x,
					y = body.y,
					z = body.z,
					yaw = body.yaw,
					health = mob.health,
				})
			end
		end
	end
	local ticker = systems.ticker
	if ticker then
		for key, due in ticker.scheduled do
			local x, y, z = Coords.decodePosKey(key)
			table.insert(
				regionFor(regions, x, z).ticks,
				{ x = x, y = y, z = z, delay = math.max(1, due - ticker.tick) }
			)
		end
	end
	if pending then
		for _, list in pending do
			for _, tick in list do
				table.insert(
					regionFor(regions, tick.x, tick.z).ticks,
					{ x = tick.x, y = tick.y, z = tick.z, delay = tick.delay }
				)
			end
		end
	end

	local live: { [string]: boolean } = {}
	for name in regions do
		live[name] = true
	end
	-- Every region written gets all of its edits; regions that held state and hold none now are
	-- written too (empty, or with their edits).
	local wanted: { [string]: boolean } = table.clone(live)
	if dirty then
		for name in dirty do
			wanted[name] = true
		end
	end
	if previous then
		for name in previous do
			wanted[name] = true
		end
	end
	for key, edits in systems.world.edits do
		local cx, cz = Coords.decodeChunkKey(key)
		local rx, rz = RegionCodec.regionOf(cx, cz)
		local name = RegionCodec.name(rx, rz)
		if wanted[name] and next(edits) ~= nil then
			local region = regions[name]
			if region == nil then
				region = RegionCodec.new(rx, rz)
				regions[name] = region
			end
			region.chunks[key] = edits
		end
	end
	for name in wanted do
		if regions[name] == nil then
			local rx, rz = RegionCodec.parseName(name)
			if rx and rz then
				regions[name] = RegionCodec.new(rx, rz)
			end
		end
	end
	return regions, live
end

-- The names of every region with edits (a whole world's `dirty`: a first save).
function WorldSnapshot.editedRegions(world: WorldServer.World): { [string]: boolean }
	local names: { [string]: boolean } = {}
	for key, edits in world.edits do
		if next(edits) ~= nil then
			local cx, cz = Coords.decodeChunkKey(key)
			names[RegionCodec.name(RegionCodec.regionOf(cx, cz))] = true
		end
	end
	return names
end

-- The region name of block (x, z) (what an edit there dirties).
function WorldSnapshot.regionName(x: number, z: number): string
	return RegionCodec.name(RegionCodec.regionOfBlock(x, z))
end

--[[ Loading ]]

-- The loaded regions' edits become the world's (before any chunk is generated).
function WorldSnapshot.applyEdits(world: WorldServer.World, regions: { Region })
	for _, region in regions do
		for key, edits in region.chunks do
			local existing = world.edits[key]
			if existing then
				for index, block in edits do
					existing[index] = block
				end
			else
				world.edits[key] = edits
			end
		end
	end
end

-- Puts a saved container into `store` (see the header). Whether it took.
local function restoreContainer(store: Containers.Store, entry: RegionCodec.ContainerRecord): boolean
	local saved = entry.container
	local block = saved.block
	if not (Machines.isMachine(block) or Machines.containerSize(block) > 0) then
		return false
	end
	local x, y, z = entry.x, entry.y, entry.z
	-- (Asked about: a generated chest here was filled already, its contents are these.)
	store.sourced[`{x},{y},{z}`] = true
	local container = store:get(x, y, z, block)
	table.clear(container.slots)
	for slot, stack in saved.slots do
		if slot >= 1 and slot <= container.size then
			container.slots[slot] = Items.copyStack(stack)
		end
	end
	local data, savedData = container.data, saved.data
	if data and savedData and container.kind == saved.kind then
		for i = 1, math.min(#data, #savedData) do
			data[i] = savedData[i]
		end
	end
	if container.kind == "furnace" then
		store:markActive(x, y, z)
	end
	return true
end

--[[
	Puts the loaded regions' state into the started systems (see the header). Their edits must be
	the world's already (`applyEdits`).
]]
function WorldSnapshot.restore(systems: Systems, regions: { Region }): Restored
	local report: Restored =
		{ containers = 0, pipes = 0, machines = 0, structures = 0, items = 0, mobs = 0, ticks = {} }
	local store = systems.containers
	if store then
		for _, region in regions do
			for _, key in region.sourced do
				local x, y, z = Coords.decodePosKey(key)
				store.sourced[`{x},{y},{z}`] = true
			end
		end
		for _, region in regions do
			for _, entry in region.containers do
				if restoreContainer(store, entry) then
					report.containers += 1
				end
			end
		end
	end

	-- The edits' blocks the systems follow, as if each had just been placed.
	local pipeBlocks: { { number } } = {}
	local machineBlocks: { { number } } = {}
	local structureBlocks: { { number } } = {}
	local special: { [number]: number } = {}
	for _, region in regions do
		for key, edits in region.chunks do
			local cx, cz = Coords.decodeChunkKey(key)
			for index, block in edits do
				local kind = special[block]
				if kind == nil then
					kind = 0
					if Blocks.isValid(block) then
						if
							Transmitters.isTransmitter(block)
							or Transmitters.isTank(block)
							or Transmitters.isItemAcceptor(block)
							or Transmitters.isEnergyAcceptor(block)
						then
							kind += 1
						end
						if Machines.isMachine(block) then
							kind += 2
						end
						if Blocks.structureMode(block) ~= nil or Blocks.isJigsaw(block) then
							kind += 4
						end
					end
					special[block] = kind
				end
				if kind ~= 0 then
					local lx, y, lz = ChunkLayout.fromLocalIndex(index)
					local cell = { cx * SIZE + lx, y, cz * SIZE + lz, block }
					if bit32.btest(kind, 1) then
						table.insert(pipeBlocks, cell)
					end
					if bit32.btest(kind, 2) then
						table.insert(machineBlocks, cell)
					end
					if bit32.btest(kind, 4) then
						table.insert(structureBlocks, cell)
					end
				end
			end
		end
	end

	local pipes = systems.transmitters
	if pipes then
		for _, cell in pipeBlocks do
			TransmitterWorld.blockChanged(pipes, cell[1], cell[2], cell[3], AIR, cell[4])
		end
		local nodes: { TransmitterWorld.SavedNode } = {}
		local tanks: { TransmitterWorld.SavedTank } = {}
		local transport: { TransmitterWorld.SavedItem } = {}
		for _, region in regions do
			table.move(region.pipes, 1, #region.pipes, #nodes + 1, nodes)
			table.move(region.tanks, 1, #region.tanks, #tanks + 1, tanks)
			table.move(region.transport, 1, #region.transport, #transport + 1, transport)
		end
		report.pipes = TransmitterWorld.restoreState(pipes, nodes, tanks, transport)
	end
	local machines = systems.machines
	if machines then
		for _, cell in machineBlocks do
			MachineWorld.blockChanged(machines, cell[1], cell[2], cell[3], AIR, cell[4])
			report.machines += 1
		end
	end
	local structures = systems.structures
	if structures then
		for _, cell in structureBlocks do
			structures:blockChanged(cell[1], cell[2], cell[3], AIR, cell[4])
		end
		for _, region in regions do
			for _, entry in region.structures do
				if structures:setStructure(entry.x, entry.y, entry.z, entry.settings) then
					report.structures += 1
				end
			end
			for _, entry in region.jigsaws do
				if structures:setJigsaw(entry.x, entry.y, entry.z, entry.settings) then
					report.structures += 1
				end
			end
		end
	end
	local entities = systems.items
	if entities then
		for _, region in regions do
			for _, item in region.items do
				local stack = item.stack
				local id = entities:spawnItem(
					stack.item,
					stack.count,
					item.x,
					item.y,
					item.z,
					0,
					0,
					0,
					item.pickupDelay,
					stack.damage,
					stack.data
				)
				local entity = entities:get(id)
				if entity then
					entity.age = item.age
					report.items += 1
				end
			end
		end
	end
	local animals = systems.mobs
	if animals then
		for _, region in regions do
			for _, saved in region.mobs do
				local kind = MobList.get(saved.kind)
				if kind and not kind.hostile then
					local id = animals:spawn(saved.kind, saved.x, saved.y, saved.z, saved.variant, saved.yaw)
					local mob = animals:get(id)
					if mob then
						mob.health = math.clamp(saved.health, 0.5, kind.health)
						report.mobs += 1
					end
				end
			end
		end
	end
	for _, region in regions do
		for _, tick in region.ticks do
			local key = Coords.chunkKey(tick.x // SIZE, tick.z // SIZE)
			local list = report.ticks[key]
			if list == nil then
				list = {}
				report.ticks[key] = list
			end
			table.insert(list, tick)
		end
	end
	return report
end

-- Schedules a generated chunk's saved block updates (`Restored.ticks[key]`).
function WorldSnapshot.scheduleTicks(ticker: BlockTicker.Ticker, ticks: { RegionCodec.TickRecord })
	for _, tick in ticks do
		ticker:schedule(tick.x, tick.y, tick.z, tick.delay)
	end
end

return WorldSnapshot

--!strict
--[[
	Explosions in the server's world, and fuel setting them off (Minecraft's Explosion on the
	server, with World/FuelBlast's plans). Pure Luau on WorldServer, so the tests run it.

	  Ignitions  `ignite(world, x, y, z)` (Behaviours/Fluid, when fuel touches fire or lava; or
	             a blast reaching fuel no plan holds yet, as TNT hit by a blast is primed)
	             queues the cell; `step` measures and plans its body (FuelBlast.measure / plan)
	             and claims every cell of it for the blast it belongs to, so fire and blasts
	             reaching claimed fuel change nothing: it goes off on its own schedule.
	  Fuses      `fuse(world, x, y, z)` (Behaviours/Fluid, when fire or lava touches flowing fuel:
	             any level but the source) turns the cell into Fire Config.Explosions.FuseTicks
	             (4) ticks later, if it is still flowing fuel no plan holds. That fire lights the
	             flowing cells next to it in turn (BlockList makes them flammable too), so the
	             flame runs up a trail of spilt fuel at 5 blocks a second to its source, which
	             goes off (`ignite`): lay a trail and light its end.
	  Blasts     `explode(world, x, y, z, power, fiery)` queues one directly (Api, tests). At its
	             tick a fuel blast first consumes its cells (air, released), then
	               1. Explosion.affected: the cells its 1352 rays reach;
	               2. the handler (`setHandler`, the boot script: item entities, players' damage
	                  and knockback, the clients' effects) before any block goes, as Minecraft
	                  hurts entities in explode() before finalizeExplosion drops anything;
	               3. Minecraft's explosion sound (entity.generic.explode, Audio/Sounds);
	               4. every affected non-air block becomes air, dropping its items (leaves their
	                  sapling or sticks, Items.leafDrop) with chance 1 / power (Behaviours/Drops;
	                  containers drop their contents through Inventories as for any change);
	                  unclaimed fuel among them is ignited instead (it is the explosive);
	               5. a fiery blast (every fuel blast) sets Fire on one in three of its air
	                  cells over an opaque block (Explosion.fireSpots), which lights the fuel
	                  next to it in turn: bodies larger than FuelBlast's cap burn on in chains.
	             A flash (a plan's blast with power 0: thin fuel) just consumes its cells and
	             sets fire to them the same way.
	  Costs      per `step` (one server tick): at most Config.Explosions.MaxIgnitionsPerTick
	             ignitions planned (each a flood fill of at most MaxCells), at most
	             MaxBlastsPerTick blasts, and no new blast once their rays have read RayBudget
	             blocks (the first always goes); the rest wait for the next tick. Unloaded chunks
	             stop rays and flood fills, and are never generated.

	State is kept per world (weakly), so tests with worlds of their own never share it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)
local Explosion = require(Shared.World.Explosion)
local Items = require(Shared.Items)
local SharedSounds = require(Shared.Sounds)

local Sounds = require(script.Parent.Parent.Audio.Sounds)
local Drops = require(script.Parent.Parent.Behaviours.Drops)
local FuelBlast = require(script.Parent.FuelBlast)
local WorldServer = require(script.Parent.WorldServer)

type World = WorldServer.World

-- What a blast does beyond blocks (entities, players, the clients' effects): its centre (blocks)
-- and power, with the world's loaded blocks.
export type Handler = (x: number, y: number, z: number, power: number, getBlock: Explosion.GetBlock) -> ()

-- A blast waiting for its tick (`cells`: the fuel it consumes, claimed until then).
type Pending = {
	due: number,
	order: number,
	x: number,
	y: number,
	z: number,
	power: number,
	fiery: boolean,
	cells: { number }?,
}

type State = {
	tick: number,
	order: number,
	ignitions: { number },
	queued: { [number]: boolean },
	blasts: { Pending },
	sorted: boolean,
	claimed: { [number]: Pending },
	-- Flowing fuel burning along like a fuse: its cells (Coords.posKey) and the tick each catches.
	fuses: { { key: number, due: number } },
	fusing: { [number]: boolean },
	random: () -> number,
	getBlock: Explosion.GetBlock,
}

local Settings = Config.Explosions
local AIR, CAVE_AIR = Blocks.AIR, Blocks.CAVE_AIR
local FIRE = Blocks.find("Fire")
-- Minecraft's explosion sound (nil until Shared/Sounds has it).
local EXPLODE = SharedSounds.find("entity.generic.explode")

local Explosions = {}

local states: { [World]: State } = setmetatable({}, { __mode = "k" }) :: any
local handler: Handler? = nil

local function stateOf(world: World): State
	local state = states[world]
	if state == nil then
		state = {
			tick = 0,
			order = 0,
			ignitions = {},
			queued = {},
			blasts = {},
			sorted = true,
			claimed = {},
			fuses = {},
			fusing = {},
			random = math.random,
			getBlock = function(x: number, y: number, z: number): number?
				return world:peekBlock(x, y, z)
			end,
		}
		states[world] = state
	end
	return state
end

-- Sets (or clears) what blasts do to entities and players and how clients see them.
function Explosions.setHandler(fn: Handler?)
	handler = fn
end

-- Sets the world's random (rolls in [0, 1); default math.random): the tests' fixed rolls.
function Explosions.setRandom(world: World, random: () -> number)
	stateOf(world).random = random
end

-- Queues the fuel at (x, y, z) to go off (nothing happens if it is no fuel by then or a plan
-- already holds it).
function Explosions.ignite(world: World, x: number, y: number, z: number)
	local state = stateOf(world)
	local key = Coords.posKey(x, y, z)
	if state.queued[key] or state.claimed[key] then
		return
	end
	state.queued[key] = true
	table.insert(state.ignitions, key)
end

--[[
	Lights the flowing fuel at (x, y, z) like a fuse (Behaviours/Fluid, when fire or lava touches
	it): Config.Explosions.FuseTicks later it turns into Fire, if it is still flowing fuel no blast
	holds, which lights the flowing fuel next to it in turn, and so on up the trail to its source,
	which explodes (`ignite`).
]]
function Explosions.fuse(world: World, x: number, y: number, z: number)
	local state = stateOf(world)
	local key = Coords.posKey(x, y, z)
	if state.fusing[key] or state.claimed[key] then
		return
	end
	state.fusing[key] = true
	table.insert(state.fuses, { key = key, due = state.tick + Settings.FuseTicks })
end

local function enqueue(state: State, pending: Pending)
	state.order += 1
	pending.order = state.order
	table.insert(state.blasts, pending)
	state.sorted = false
end

-- Queues a blast of `power` at (x, y, z) (blocks) for the next step; `fiery` sets fire.
function Explosions.explode(world: World, x: number, y: number, z: number, power: number, fiery: boolean?)
	local state = stateOf(world)
	enqueue(state, { due = state.tick + 1, order = 0, x = x, y = y, z = z, power = power, fiery = fiery == true })
end

-- Is the fuel at (x, y, z) part of a blast waiting to go off?
function Explosions.isClaimed(world: World, x: number, y: number, z: number): boolean
	return stateOf(world).claimed[Coords.posKey(x, y, z)] ~= nil
end

-- Ignitions and blasts waiting.
function Explosions.pending(world: World): number
	local state = stateOf(world)
	return #state.ignitions + #state.blasts + #state.fuses
end

-- Measures and plans the body of fuel at `key`, claiming its cells.
local function plan(state: State, key: number)
	state.queued[key] = nil
	if state.claimed[key] then
		return
	end
	local x, y, z = Coords.decodePosKey(key)
	local body = FuelBlast.measure(state.getBlock, x, y, z, state.claimed)
	if #body.cells == 0 then
		return
	end
	for _, blast in FuelBlast.plan(body, x, y, z) do
		local pending: Pending = {
			due = state.tick + blast.delay,
			order = 0,
			x = blast.x,
			y = blast.y,
			z = blast.z,
			power = blast.power,
			fiery = true,
			cells = blast.cells,
		}
		for _, cell in blast.cells do
			state.claimed[cell] = pending
		end
		enqueue(state, pending)
	end
end

-- Sets fire on `spots` (Coords.posKey).
local function setFire(world: World, spots: { number })
	if FIRE == nil then
		return
	end
	for _, key in spots do
		local x, y, z = Coords.decodePosKey(key)
		world:setBlock(x, y, z, FIRE)
	end
end

-- Sets one blast off; returns the block reads its rays took.
local function detonate(world: World, state: State, pending: Pending): number
	local random = state.random
	local cells = pending.cells
	if cells then
		-- The fuel burns up (only what still is fuel: it may have flowed away meanwhile).
		for _, key in cells do
			if state.claimed[key] == pending then
				state.claimed[key] = nil
			end
		end
		for _, key in cells do
			local x, y, z = Coords.decodePosKey(key)
			if FuelBlast.isFuel(world:peekBlock(x, y, z)) then
				world:setBlock(x, y, z, AIR)
			end
		end
	end
	local x, y, z, power = pending.x, pending.y, pending.z, pending.power
	if power <= 0 then
		-- A flash: thin fuel burns away into fire.
		if cells and pending.fiery then
			setFire(world, Explosion.fireSpots(state.getBlock, cells, random))
		end
		return 0
	end

	local affected, reads = Explosion.affected(state.getBlock, x, y, z, power, random)
	local onBlast = handler
	if onBlast then
		onBlast(x, y, z, power, state.getBlock)
	end
	if EXPLODE then
		Sounds.play(EXPLODE, x, y, z)
	end

	local chance = Explosion.dropChance(power)
	for _, key in affected do
		local bx, by, bz = Coords.decodePosKey(key)
		local block = world:peekBlock(bx, by, bz)
		if block == nil or block == AIR or block == CAVE_AIR then
			continue
		end
		if FuelBlast.isFuel(block) then
			-- Fuel is the explosive: it goes off (later, from where the blast reached it)
			-- instead of just vanishing; claimed fuel goes off with its own blast.
			if state.claimed[key] == nil then
				Explosions.ignite(world, bx, by, bz)
			end
			continue
		end
		if world:setBlock(bx, by, bz, AIR) and random() < chance then
			local stack = Items.leafDrop(block, random) or Items.blockDrops(block)
			if stack then
				Drops.stack(bx, by, bz, stack)
			end
		end
	end
	if pending.fiery then
		setFire(world, Explosion.fireSpots(state.getBlock, affected, random))
	end
	return reads
end

--[[
	One server tick (after the block ticker's): plans queued ignitions and sets off the blasts
	that are due, within the cost bounds (see the header). Returns the blasts set off (flashes
	included).
]]
function Explosions.step(world: World): number
	local state = states[world]
	if state == nil then
		return 0
	end
	state.tick += 1

	-- Fuses due (queued in order: every one waits the same FuseTicks).
	local fuses = state.fuses
	local burnt = 0
	while burnt < #fuses and fuses[burnt + 1].due <= state.tick do
		burnt += 1
		local key = fuses[burnt].key
		state.fusing[key] = nil
		local bx, by, bz = Coords.decodePosKey(key)
		local block = world:peekBlock(bx, by, bz)
		if FIRE and state.claimed[key] == nil and FuelBlast.isFuel(block) and not FuelBlast.isSource(block) then
			world:setBlock(bx, by, bz, FIRE)
		end
	end
	if burnt > 0 then
		state.fuses = table.move(fuses, burnt + 1, #fuses, 1, {})
	end

	local ignitions = state.ignitions
	local planned = math.min(#ignitions, Settings.MaxIgnitionsPerTick)
	if planned > 0 then
		local now = table.move(ignitions, 1, planned, 1, {})
		state.ignitions = table.move(ignitions, planned + 1, #ignitions, 1, {})
		for _, key in now do
			plan(state, key)
		end
	end

	if not state.sorted then
		table.sort(state.blasts, function(a, b)
			if a.due ~= b.due then
				return a.due < b.due
			end
			return a.order < b.order
		end)
		state.sorted = true
	end
	local blasts = state.blasts
	local done, reads = 0, 0
	while
		done < #blasts
		and blasts[done + 1].due <= state.tick
		and done < Settings.MaxBlastsPerTick
		and (done == 0 or reads < Settings.RayBudget)
	do
		done += 1
		reads += detonate(world, state, blasts[done])
	end
	if done > 0 then
		-- (Blasts queued while these went off were appended after them.)
		state.blasts = table.move(state.blasts, done + 1, #state.blasts, 1, {})
	end
	return done
end

return Explosions

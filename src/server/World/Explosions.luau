--!strict
--[[
	Explosions in the server's world, and fuel setting them off (Minecraft's Explosion on the
	server, with World/FuelBlast's plans). Pure Luau on WorldServer, so the tests run it.

	  Ignitions  `ignite(world, x, y, z)` (Behaviours/Fluid, when fuel touches fire or lava; or
	             a blast reaching fuel) queues the cell; `step` measures its body and plans what
	             it does (FuelBlast.measure / plan: flames over its surface as the front reaches
	             them, and the blast of the vapour in a closed space over it). Every cell of the
	             body is then "burning" for Config.Explosions.BurningMemory ticks, refreshed each
	             time fire or lava touches it again: a burning body catches nothing more (its
	             flames are already on it), and its vapour burns off as it rises, so it never
	             explodes again while it burns (FuelBlast.plan's `burning`).
	  Flames     at their tick, Fire on every planned cell still empty (air or cave air): the
	             pool fire, which Behaviours/Fire keeps burning (fuel is flammable: BlockList).
	  Blasts     `explode(world, x, y, z, power, fiery)` queues one directly (Api, tests); a
	             closed space's vapour blast is queued a tick after catching. At its tick:
	               1. Explosion.affected: the cells its 1352 rays reach;
	               2. the handler (`setHandler`, the boot script: item entities, players' damage
	                  and knockback, the clients' effects) before any block goes, as Minecraft
	                  hurts entities in explode() before finalizeExplosion drops anything;
	               3. Minecraft's explosion sound (entity.generic.explode, Audio/Sounds);
	               4. every affected non-air block becomes air, dropping its items (leaves their
	                  sapling or sticks, Items.leafDrop) with chance 1 / power (Behaviours/Drops;
	                  containers drop their contents through Inventories as for any change);
	                  fuel among them (fluids resist blasts, so only at the very edge) catches
	                  instead;
	               5. a vapour blast throws out the walls its pressure beats (FuelBlast.plan),
	                  with the same drops;
	               6. a fiery blast (every vapour blast) sets Fire on one in three of its air
	                  cells over an opaque block (Explosion.fireSpots), the space's included: the
	                  room is a fireball.
	  Costs      per `step` (one server tick): at most Config.Explosions.MaxIgnitionsPerTick
	             ignitions planned (a flood fill of at most MaxCells fuel cells and one of at
	             most PocketCells air cells each), at most MaxBlastsPerTick blasts, and no new
	             blast once their rays have read RayBudget blocks (the first always goes); the
	             rest wait for the next tick. Unloaded chunks stop rays and flood fills, and are
	             never generated.

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

-- A blast or flames waiting for their tick: a blast (`power` > 0) at (x, y, z), with the walls
-- its pressure throws out and the space its fire fills; flames (`power` 0): Fire on `flames`.
type Pending = {
	due: number,
	order: number,
	x: number,
	y: number,
	z: number,
	power: number,
	fiery: boolean,
	walls: { number }?,
	pocket: { number }?,
	flames: { number }?,
}

type State = {
	tick: number,
	order: number,
	ignitions: { number },
	queued: { [number]: boolean },
	blasts: { Pending },
	sorted: boolean,
	-- Fuel cells (Coords.posKey) burning, until the tick given.
	burning: { [number]: number },
	burningCount: number,
	random: () -> number,
	getBlock: Explosion.GetBlock,
}

local Settings = Config.Explosions
local AIR, CAVE_AIR = Blocks.AIR, Blocks.CAVE_AIR
local FIRE = Blocks.find("Fire")
-- Minecraft's explosion sound (nil until Shared/Sounds has it).
local EXPLODE = SharedSounds.find("entity.generic.explode")
-- Burning marks kept per world beyond which the stale ones are swept out.
local SWEEP_AT = 16384

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
			burning = {},
			burningCount = 0,
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

local function isBurning(state: State, key: number): boolean
	local until_ = state.burning[key]
	return until_ ~= nil and until_ > state.tick
end

local function markBurning(state: State, key: number)
	if state.burning[key] == nil then
		state.burningCount += 1
	end
	state.burning[key] = state.tick + Settings.BurningMemory
end

-- Drops the burning marks that ran out, once there are many.
local function sweep(state: State)
	if state.burningCount < SWEEP_AT then
		return
	end
	local kept = 0
	for key, until_ in state.burning do
		if until_ <= state.tick then
			state.burning[key] = nil
		else
			kept += 1
		end
	end
	state.burningCount = kept
end

-- Queues the fuel at (x, y, z) to catch (a burning cell only stays burning longer).
function Explosions.ignite(world: World, x: number, y: number, z: number)
	local state = stateOf(world)
	local key = Coords.posKey(x, y, z)
	if isBurning(state, key) then
		markBurning(state, key)
		return
	end
	if state.queued[key] then
		return
	end
	state.queued[key] = true
	table.insert(state.ignitions, key)
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

-- Is the fuel at (x, y, z) burning (it caught within Config.Explosions.BurningMemory ticks)?
function Explosions.isBurning(world: World, x: number, y: number, z: number): boolean
	return isBurning(stateOf(world), Coords.posKey(x, y, z))
end

-- Ignitions, blasts and flames waiting.
function Explosions.pending(world: World): number
	local state = stateOf(world)
	return #state.ignitions + #state.blasts
end

-- Measures the body of fuel at `key` and plans what it does (see the header).
local function plan(state: State, key: number)
	state.queued[key] = nil
	if isBurning(state, key) then
		return
	end
	local x, y, z = Coords.decodePosKey(key)
	local body = FuelBlast.measure(state.getBlock, x, y, z)
	if #body.cells == 0 then
		return
	end
	local burning = false
	for _, cell in body.cells do
		if isBurning(state, cell) then
			burning = true
		end
		markBurning(state, cell)
	end
	local result = FuelBlast.plan(state.getBlock, body, burning)
	-- Flames, a batch per tick of the front.
	local byDelay: { [number]: { number } } = {}
	local delays: { number } = {}
	for _, flame in result.flames do
		local batch = byDelay[flame.delay]
		if batch == nil then
			batch = {}
			byDelay[flame.delay] = batch
			table.insert(delays, flame.delay)
		end
		table.insert(batch, flame.key)
	end
	table.sort(delays)
	for _, delay in delays do
		enqueue(state, {
			due = state.tick + delay,
			order = 0,
			x = 0,
			y = 0,
			z = 0,
			power = 0,
			fiery = true,
			flames = byDelay[delay],
		})
	end
	local blast = result.blast
	if blast then
		enqueue(state, {
			due = state.tick + 1,
			order = 0,
			x = blast.x,
			y = blast.y,
			z = blast.z,
			power = blast.power,
			fiery = true,
			walls = blast.walls,
			pocket = blast.pocket,
		})
	end
end

-- Sets fire on `spots` (Coords.posKey) that are still empty.
local function setFire(world: World, spots: { number })
	if FIRE == nil then
		return
	end
	for _, key in spots do
		local x, y, z = Coords.decodePosKey(key)
		local block = world:peekBlock(x, y, z)
		if block == AIR or block == CAVE_AIR then
			world:setBlock(x, y, z, FIRE)
		end
	end
end

-- Breaks the block at `key` (not air, not fuel) with the blast's drop chance.
local function shatter(world: World, key: number, chance: number, random: () -> number)
	local x, y, z = Coords.decodePosKey(key)
	local block = world:peekBlock(x, y, z)
	if block == nil or block == AIR or block == CAVE_AIR then
		return
	end
	if world:setBlock(x, y, z, AIR) and random() < chance then
		local stack = Items.leafDrop(block, random) or Items.blockDrops(block)
		if stack then
			Drops.stack(x, y, z, stack)
		end
	end
end

-- Sets one blast (or flames) off; returns the block reads its rays took.
local function detonate(world: World, state: State, pending: Pending): number
	local random = state.random
	if pending.flames then
		setFire(world, pending.flames)
		return 0
	end
	local x, y, z, power = pending.x, pending.y, pending.z, pending.power
	if power <= 0 then
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
		if FuelBlast.isFuel(block) then
			-- (Fuel is a liquid: a blast lights it rather than blowing it away.)
			Explosions.ignite(world, bx, by, bz)
		else
			shatter(world, key, chance, random)
		end
	end
	if pending.walls then
		for _, key in pending.walls do
			shatter(world, key, chance, random)
		end
	end
	if pending.fiery then
		setFire(world, Explosion.fireSpots(state.getBlock, affected, random))
		if pending.pocket then
			setFire(world, Explosion.fireSpots(state.getBlock, pending.pocket, random))
		end
	end
	return reads
end

--[[
	One server tick (after the block ticker's): plans queued ignitions and sets off the blasts
	that are due, within the cost bounds (see the header). Returns the blasts set off (flames
	included).
]]
function Explosions.step(world: World): number
	local state = states[world]
	if state == nil then
		return 0
	end
	state.tick += 1
	sweep(state)

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

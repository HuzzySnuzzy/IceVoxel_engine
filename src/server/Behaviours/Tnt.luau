--!strict
--[[
	TNT and the Nuke: Minecraft 1.20.1's TntBlock and its PrimedTnt entity, the Nuke lit the same
	way (BlockList Tnt, LitTnt, Nuke, LitNuke; Config.Tnt, Config.Nuke). The behaviour of the lit
	blocks; `prime` lights an unlit one.

	  Lighting  (TntBlock.explode / onCaughtFire / use / wasExploded) TNT or a Nuke becomes its lit
	            block (`prime`) with the hiss (entity.tnt.primed, Audio/Sounds):
	              * flint and steel used on it (Players/ItemUse; TntBlock.use: the tool wears by
	                1, no fire is lit);
	              * fire burning it away (Behaviours/Fire's checkBurnOut; lava lights fire next to
	                flammable blocks, so lava lights it too): it is lit instead of burning;
	              * a blast reaching it (World/Explosions' primer, World/Nuke's crater): silently,
	                with a short fuse, rand(fuse / 4) + fuse / 8 (TNT 10..29 ticks), so a pile
	                goes off in a ripple rather than at once. Lit ones a blast reaches stay as
	                they are, as no blast removes Minecraft's primed entity.
	  Lit       Minecraft's PrimedTnt is an entity: it falls, flashes and explodes where it is
	            when its fuse runs out. Here it is a block (LitTnt, LitNuke) so it needs no entity
	            kind, renderer or message of its own: the world's edits carry it. Its state, by
	            position (per world, never sent): the tick its fuse runs out, its fall speed and
	            what it fell into. A lit block always has its next scheduled tick waiting (each
	            tick schedules the next), and runs PrimedTnt.tick each tick:
	              1. the fuse: when it runs out the block goes back to what it fell into (air,
	                 water...) and TNT explodes there with Config.Tnt.Power (4, no fire;
	                 World/Explosions, at the entity's getY(0.0625)), the Nuke digs its crater
	                 (World/Nuke);
	              2. the Nuke's alarm every Config.Nuke.AlarmTicks (entity.nuke.alarm);
	              3. gravity: while the cell below is loaded and replaceable (air, fire, fluids,
	                 plants) it falls as an entity does (speed + 0.04 a tick, then x 0.98: 0.04,
	                 0.079... blocks a tick), a whole cell at a time, giving back what it passes
	                 through (water stays water: TNT that sinks into it explodes in it and, as in
	                 Minecraft, breaks nothing). Landing stops it.
	            Minecraft's little hop when it is lit (0.2 up, 0.02 sideways) is left out: a block
	            can't hop. Lit blocks can't be broken (BlockList), so a lit fuse can't be put out.
	            A lit block placed by anything else (the Api) starts its full fuse (a record that
	            has not run for STALE_TICKS is of a lit block replaced by other means). Random
	            ticks restart a fuse whose tick was lost with its chunk.
	The client draws lit blocks glowing (BlockList `light`) and flashing (Rendering/FuseView).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)
local SharedSounds = require(Shared.Sounds)

local Sounds = require(script.Parent.Parent.Audio.Sounds)
local Explosions = require(script.Parent.Parent.World.Explosions)
local Nuke = require(script.Parent.Parent.World.Nuke)

local B = Blocks.id
local AIR = Blocks.AIR
local TNT, LIT_TNT = B.Tnt, B.LitTnt
local NUKE, LIT_NUKE = B.Nuke, B.LitNuke
-- (nil until Shared/Sounds has them.)
local PRIMED = SharedSounds.find("entity.tnt.primed")
local ALARM = SharedSounds.find("entity.nuke.alarm")
-- Records kept per world beyond which the ones of lit blocks that are gone are swept out.
local SWEEP_AT = 1024
-- Ticks after which a record that did not run belongs to a lit block that is gone.
local STALE_TICKS = 20

-- An unlit explosive's lit block, and a lit block's full fuse (ticks).
local LIT_OF: { [number]: number } = { [TNT] = LIT_TNT, [NUKE] = LIT_NUKE }
local FUSE_OF: { [number]: number } = { [LIT_TNT] = Config.Tnt.FuseTicks, [LIT_NUKE] = Config.Nuke.FuseTicks }

-- A lit block's state: the tick its fuse runs out, the last tick it ran, the Nuke's next beep,
-- its fall (speed in blocks a tick, and how far into the next cell) and what it fell into.
type Record = {
	due: number,
	last: number,
	alarm: number,
	vy: number,
	drop: number,
	under: number,
}

-- What `prime` and a fall hand to the lit block they place (read by its onNeighborChanged).
type Placing = { fuse: number, vy: number, drop: number, under: number }

type State = {
	records: { [number]: Record },
	count: number,
	placing: { [number]: Placing },
}

local Tnt = {}

-- PrimedTnt's gravity (blocks a tick, a tick) and drag (kept a tick).
Tnt.GRAVITY = 0.04
Tnt.DRAG = 0.98

local states: { [any]: State } = setmetatable({}, { __mode = "k" }) :: any

local function stateOf(world: any): State
	local state = states[world]
	if state == nil then
		state = { records = {}, count = 0, placing = {} }
		states[world] = state
	end
	return state
end

-- Java's random.nextInt(n): 0 .. n - 1, from a roll in [0, 1).
local function nextInt(random: () -> number, n: number): number
	return math.min(n - 1, math.floor(random() * n))
end

-- Is `block` TNT or a Nuke that is not lit (what fire, flint and steel and blasts light)?
function Tnt.isExplosive(block: number?): boolean
	return block ~= nil and LIT_OF[block] ~= nil
end

-- Is `block` lit TNT or a lit Nuke?
function Tnt.isLit(block: number?): boolean
	return block ~= nil and FUSE_OF[block] ~= nil
end

-- The full fuse (ticks) of `block`, lit or not (nil for anything else).
function Tnt.fuseOf(block: number): number?
	local lit = LIT_OF[block] or block
	return FUSE_OF[lit]
end

-- TntBlock.wasExploded's fuse for a blast-lit one: rand(fuse / 4) + fuse / 8.
function Tnt.shortFuse(fuse: number, random: () -> number): number
	return nextInt(random, math.max(1, fuse // 4)) + fuse // 8
end

--[[
	Lights the TNT or Nuke at (x, y, z): it becomes its lit block with `fuse` ticks to go (default
	its full fuse), hissing unless `quiet`. Returns whether it was lit (false for anything else).
]]
function Tnt.prime(world: any, x: number, y: number, z: number, fuse: number?, quiet: boolean?): boolean
	local block = world:peekBlock(x, y, z)
	local lit = if block then LIT_OF[block] else nil
	if lit == nil then
		return false
	end
	local state = stateOf(world)
	local key = Coords.posKey(x, y, z)
	state.placing[key] = { fuse = fuse or FUSE_OF[lit], vy = 0, drop = 0, under = AIR }
	local changed = world:setBlock(x, y, z, lit)
	state.placing[key] = nil
	if changed and not quiet and PRIMED then
		Sounds.play(PRIMED, x + 0.5, y + 0.5, z + 0.5)
	end
	return changed
end

-- Ticks left on the fuse of the lit block at (x, y, z) (nil when there is none), with `ticker`.
function Tnt.fuseLeft(world: any, ticker: any, x: number, y: number, z: number): number?
	local block = world:peekBlock(x, y, z)
	local record = stateOf(world).records[Coords.posKey(x, y, z)]
	if record == nil or not Tnt.isLit(block) then
		return nil
	end
	return math.max(0, record.due - ticker.tick)
end

-- Drops the records of lit blocks that are gone (replaced by the Api) or stopped long ago.
local function sweep(world: any, state: State, now: number)
	local kept = 0
	for key, record in state.records do
		local x, y, z = Coords.decodePosKey(key)
		local block = world:peekBlock(x, y, z)
		if (block ~= nil and not Tnt.isLit(block)) or now - record.last > 1200 then
			state.records[key] = nil
		else
			kept += 1
		end
	end
	state.count = kept
end

local function register(world: any, state: State, ticker: any, key: number, block: number, placing: Placing?)
	local now = ticker.tick
	local fuse = if placing then placing.fuse else FUSE_OF[block]
	if state.records[key] == nil then
		state.count += 1
		if state.count > SWEEP_AT then
			sweep(world, state, now)
			state.count += 1
		end
	end
	state.records[key] = {
		due = now + fuse,
		last = now,
		alarm = now,
		vy = if placing then placing.vy else 0,
		drop = if placing then placing.drop else 0,
		under = if placing then placing.under else AIR,
	}
end

--[[
	A lit block placed (by `prime`, a fall, or anything else: the full fuse) or a neighbour
	changed. Runs inside world:setBlock.
]]
function Tnt.onNeighborChanged(world: any, ticker: any, x: number, y: number, z: number, block: number)
	local state = stateOf(world)
	local key = Coords.posKey(x, y, z)
	local placing = state.placing[key]
	local record = state.records[key]
	-- (A live record ran within the last ticks, even with the ticker over its budget; an old one
	-- is of a lit block replaced by other means.)
	if placing or record == nil or ticker.tick - record.last > STALE_TICKS then
		state.placing[key] = nil
		register(world, state, ticker, key, block, placing)
	end
	ticker:schedule(x, y, z, 1)
end

-- Can a lit block fall into `block` (loaded, replaceable: air, fire, fluids, plants)?
local function fallsInto(block: number?): boolean
	return block ~= nil and Blocks.isReplaceable(block) and not Tnt.isLit(block)
end

-- The fuse ran out: what it fell into comes back, and it goes off there.
local function detonate(
	world: any,
	state: State,
	key: number,
	record: Record,
	x: number,
	y: number,
	z: number,
	block: number
)
	state.records[key] = nil
	state.count -= 1
	world:setBlock(x, y, z, record.under)
	if block == LIT_NUKE then
		Nuke.detonate(world, x + 0.5, y + 0.5, z + 0.5)
	else
		-- (PrimedTnt.explode: at getY(0.0625), its feet a sixteenth up.)
		Explosions.explode(world, x + 0.5, y + 0.0625, z + 0.5, Config.Tnt.Power, false)
	end
end

-- PrimedTnt.tick for the lit block at (x, y, z) (see the header).
function Tnt.onTick(world: any, ticker: any, x: number, y: number, z: number, block: number)
	local state = stateOf(world)
	local key = Coords.posKey(x, y, z)
	local record = state.records[key]
	if record == nil then
		register(world, state, ticker, key, block, nil)
		record = state.records[key]
	end
	local now = ticker.tick
	record.last = now
	if now >= record.due then
		detonate(world, state, key, record, x, y, z, block)
		return
	end
	if block == LIT_NUKE and now >= record.alarm then
		record.alarm = now + Config.Nuke.AlarmTicks
		if ALARM then
			Sounds.play(ALARM, x + 0.5, y + 0.5, z + 0.5)
		end
	end

	-- Gravity: fall a cell at a time while the cell below lets it.
	local below = if y > 0 then world:peekBlock(x, y - 1, z) else nil
	if not fallsInto(below) then
		record.vy, record.drop = 0, 0
		ticker:schedule(x, y, z, 1)
		return
	end
	record.vy += Tnt.GRAVITY
	record.drop += record.vy
	record.vy *= Tnt.DRAG
	local ny = y
	while record.drop >= 1 do
		local under = if ny > 0 then world:peekBlock(x, ny - 1, z) else nil
		if not fallsInto(under) then
			record.vy, record.drop = 0, 0
			break
		end
		ny -= 1
		record.drop -= 1
	end
	if ny == y then
		ticker:schedule(x, y, z, 1)
		return
	end
	-- Moving: what it passed through comes back behind it, and the new cell takes the record.
	local into = world:peekBlock(x, ny, z) :: number
	state.records[key] = nil
	state.count -= 1
	world:setBlock(x, y, z, record.under)
	local newKey = Coords.posKey(x, ny, z)
	state.placing[newKey] = { fuse = math.max(1, record.due - now), vy = record.vy, drop = record.drop, under = into }
	world:setBlock(x, ny, z, block)
	state.placing[newKey] = nil
	local moved = state.records[newKey]
	if moved then
		moved.alarm = record.alarm
	end
end

-- A random tick: a lit block whose tick was lost (its chunk unloaded) ticks again.
function Tnt.onRandomTick(
	world: any,
	ticker: any,
	x: number,
	y: number,
	z: number,
	_block: number,
	_random: () -> number
)
	if ticker.scheduled[Coords.posKey(x, y, z)] == nil then
		ticker:schedule(x, y, z, 1)
	end
end

--[[
	What a blast (World/Explosions, World/Nuke) does to explosive blocks: TNT and Nukes are lit
	with the short fuse, quietly (TntBlock.wasExploded); lit ones stay. Anything else: false.
]]
function Tnt.blasted(world: any, x: number, y: number, z: number, block: number, random: () -> number): boolean
	if FUSE_OF[block] then
		return true
	end
	local lit = LIT_OF[block]
	if lit == nil then
		return false
	end
	Tnt.prime(world, x, y, z, Tnt.shortFuse(FUSE_OF[lit], random), true)
	return true
end

Explosions.setPrimer(Tnt.blasted)

return Tnt

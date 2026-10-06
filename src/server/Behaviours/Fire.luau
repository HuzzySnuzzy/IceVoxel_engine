--!strict
--[[
	Fire (BlockList Fire), Minecraft 1.20.1's FireBlock on the server, with the shared rules of
	Shared/Fire (survival, ignite odds) and each block's odds (BlockList `flammable`).

	  Age      0..15, as Minecraft's AGE property, but kept here by position (per world) and never
	           sent: the block stays the single Fire id, so an age change costs no edit and no
	           remesh (Minecraft sets it with flag 4, no client update, for the same reason: only
	           the server uses it). A new fire takes the age its spreader gave it (`ignite`), 0
	           when anything else placed it (flint and steel, lava, explosions: world:setBlock).
	           New fires are told apart from neighbour changes by their first scheduled tick: a
	           burning fire always has one waiting (Minecraft's onPlace schedules it).
	  Placed   (BaseFireBlock.onPlace) out where it can't survive (Fire.canSurvive), on the next
	           tick (Minecraft: at once; a tick later its neighbours have seen it, so fuel a
	           fiery blast puts fire on still catches: World/FuelBlast), else its first tick in
	           30 + rand(10) ticks (FireBlock.getFireTickDelay).
	  Shape    (FireBlock.updateShape) a neighbour change that leaves it unable to survive puts it
	           out at once; one that can't be told (an unloaded neighbour) leaves it be.
	  Tick     (FireBlock.tick, with doFireTick: Config.Server.Fire.Tick) the next tick is
	           scheduled first, then:
	             1. it goes out if it can't survive;
	             2. it ages by rand(3) / 2 (0 or 1, one time in three 1);
	             3. off a flammable neighbour, it goes out unless it stands on a sturdy block and is
	                at most 3 old; at age 15 it goes out one time in 4 unless the block below
	                burns;
	             4. each neighbour burns away by its burn odds (checkBurnOut: rand(300) sideways,
	                rand(250) above and below, < odds), into fire one time in (age + 10) / 5
	                (rand(age + 10) < 5, with the age plus rand(5) / 4), else into air, with no
	                drop (Minecraft's removeBlock); a tall plant's other half goes with it;
	             5. it spreads into the air around it, 1 block sideways, 1 below and up to 4 above:
	                each empty cell with a flammable neighbour (Fire.igniteOddsAt) catches when
	                rand(100 + 100 x (dy - 1) above 1) <= (odds + 40 + difficulty x 7) / (age + 30),
	                at the age plus rand(5) / 4.
	           Rain, humid biomes and infiniburn blocks (netherrack) don't exist here. Unloaded
	           blocks burn nothing and catch nothing; updates never generate chunks.
	  Random   a random tick of a fire with no tick waiting (its chunk unloaded and back) starts its
	           ticks again.

	  Lava     `lavaTick` (Behaviours/Fluid on lava's random ticks: LavaFluid.randomTick): with
	           doFireTick, two times in three it climbs 1 or 2 steps, each 1 up and up to 1 to a
	           side, and lights the first empty cell next to a flammable block (Minecraft's
	           ignitedByLava, here `flammable`), stopping at a solid block; else it tries 3 cells
	           around it at its level and lights the empty cell above each flammable one.
	  Flint    `light` (flint and steel, Players/ItemUse: FlintAndSteelItem.useOn): fire in the
	           cell in front of the clicked face when Fire.canPlaceAt.

	API for other modules (fiery explosions, mods): `ignite(world, x, y, z, age?)` puts fire
	there now (any age, no checks: world:setBlock does the same with age 0), `age`, `canSurvive`
	(Shared/Fire). Players put fire out by breaking it (instant, no drop, block.fire.extinguish:
	Shared/Sounds), water washes it away (BlockList `brokenByFluid`), and a block placed into it
	replaces it (`replaceable`).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)
local SharedFire = require(Shared.Fire)

local FIRE = SharedFire.BLOCK
local AIR = Blocks.AIR
local MAX_AGE = SharedFire.MAX_AGE
-- Ages kept per world beyond which the ones of fires that are gone are swept out.
local SWEEP_AT = 4096

-- The checkBurnOut neighbours and their chance (FireBlock.tick's order: east, west, below,
-- above, north, south).
local BURN_OUT: { { number } } = {
	{ 1, 0, 0, 300 },
	{ -1, 0, 0, 300 },
	{ 0, -1, 0, 250 },
	{ 0, 1, 0, 250 },
	{ 0, 0, -1, 300 },
	{ 0, 0, 1, 300 },
}

export type Random = () -> number

type State = {
	-- Age of each burning fire, by position (Coords.posKey).
	ages: { [number]: number },
	count: number,
	-- Ages kept before the next sweep.
	sweepAt: number,
	-- The age `ignite` gives the fire it is placing (read by its onNeighborChanged).
	placing: { [number]: number },
}

local Fire = {}

Fire.canSurvive = SharedFire.canSurvive

local states: { [any]: State } = setmetatable({}, { __mode = "k" }) :: any

local function stateOf(world: any): State
	local state = states[world]
	if state == nil then
		state = { ages = {}, count = 0, sweepAt = SWEEP_AT, placing = {} }
		states[world] = state
	end
	return state
end

-- Java's random.nextInt(n): 0 .. n - 1, from a roll in [0, 1).
local function nextInt(random: Random, n: number): number
	return math.min(n - 1, math.floor(random() * n))
end

-- FireBlock.getFireTickDelay: 30 + rand(10) ticks.
function Fire.tickDelay(random: Random): number
	return 30 + nextInt(random, 10)
end

local function getter(world: any): SharedFire.GetBlock
	return function(x: number, y: number, z: number): number?
		return world:peekBlock(x, y, z)
	end
end

-- Drops the ages of fires that are gone (put out by players, water, blocks placed into them).
local function sweep(world: any, state: State)
	local kept = 0
	for key in state.ages do
		local x, y, z = Coords.decodePosKey(key)
		if world:peekBlock(x, y, z) == FIRE then
			kept += 1
		else
			state.ages[key] = nil
		end
	end
	state.count = kept
	state.sweepAt = math.max(SWEEP_AT, kept * 2)
end

local function setAge(world: any, state: State, key: number, age: number)
	if state.ages[key] == nil then
		state.count += 1
	end
	state.ages[key] = age
	if state.count > state.sweepAt then
		sweep(world, state)
	end
end

-- The age of the fire at (x, y, z) (0 when it was never given one); nil when there is no fire.
function Fire.age(world: any, x: number, y: number, z: number): number?
	if world:peekBlock(x, y, z) ~= FIRE then
		return nil
	end
	return stateOf(world).ages[Coords.posKey(x, y, z)] or 0
end

--[[
	Puts fire at (x, y, z) now with `age` (default 0; Minecraft's getStateWithAge and setBlock),
	whatever is there. Like any new fire it goes out on the next tick where it can't survive. Returns
	whether the block changed.
]]
function Fire.ignite(world: any, x: number, y: number, z: number, age: number?): boolean
	local state = stateOf(world)
	local key = Coords.posKey(x, y, z)
	state.placing[key] = math.clamp(age or 0, 0, MAX_AGE)
	local changed = world:setBlock(x, y, z, FIRE)
	state.placing[key] = nil
	return changed
end

-- Puts the fire at (x, y, z) out (Minecraft's removeBlock: air).
local function remove(world: any, x: number, y: number, z: number)
	local state = stateOf(world)
	local key = Coords.posKey(x, y, z)
	if state.ages[key] ~= nil then
		state.ages[key] = nil
		state.count -= 1
	end
	world:setBlock(x, y, z, AIR)
end

--[[
	BaseFireBlock.onPlace for a new fire, FireBlock.updateShape for a neighbour change (see the
	header). Runs inside world:setBlock; it only ever sets this cell.
]]
function Fire.onNeighborChanged(world: any, ticker: any, x: number, y: number, z: number, _block: number)
	local state = stateOf(world)
	local key = Coords.posKey(x, y, z)
	local placed = state.placing[key]
	local new = placed ~= nil or ticker.scheduled[key] == nil
	if new then
		state.placing[key] = nil
		setAge(world, state, key, placed or 0)
	end
	local survives = SharedFire.canSurvive(getter(world), x, y, z)
	if new then
		-- (A new fire that can't stay goes out on the next tick rather than inside its own
		-- placement, so what it touched still saw it: fuel under a blast's fire catches.)
		ticker:schedule(x, y, z, if survives == false then 1 else Fire.tickDelay(math.random))
	elseif survives == false then
		remove(world, x, y, z)
	end
end

-- A random tick: a fire whose tick was lost (its chunk unloaded) starts ticking again.
function Fire.onRandomTick(
	world: any,
	ticker: any,
	x: number,
	y: number,
	z: number,
	_block: number,
	random: () -> number
)
	if ticker.scheduled[Coords.posKey(x, y, z)] == nil then
		ticker:schedule(x, y, z, Fire.tickDelay(random))
	end
end

-- A tall plant's other half, when `block` is one half of it at (x, y, z) (nil otherwise).
local function otherHalf(world: any, block: number, x: number, y: number, z: number): number?
	local dy = Blocks.otherHalf(block)
	if dy == nil then
		return nil
	end
	local other = world:peekBlock(x, y + dy, z)
	local expected = if dy > 0 then Blocks.plantTop(block) else Blocks.plantBottom(block)
	return if other ~= nil and other == expected then y + dy else nil
end

-- FireBlock.checkBurnOut: the block at (x, y, z) burns away by its burn odds (see the header).
local function checkBurnOut(world: any, x: number, y: number, z: number, chance: number, random: Random, age: number)
	local block = world:peekBlock(x, y, z)
	local odds = if block == nil then 0 else Blocks.burnOdds(block)
	if nextInt(random, chance) < odds then
		local half = otherHalf(world, block :: number, x, y, z)
		if nextInt(random, age + 10) < 5 then
			Fire.ignite(world, x, y, z, math.min(age + nextInt(random, 5) // 4, MAX_AGE))
		else
			world:setBlock(x, y, z, AIR)
		end
		-- (Minecraft's DoublePlantBlock.updateShape: the other half goes too, with no drop.)
		if half and world:peekBlock(x, half, z) ~= nil then
			world:setBlock(x, half, z, AIR)
		end
	end
end

--[[
	One fire tick (FireBlock.tick, see the header) of the fire at (x, y, z), with `random` rolls in
	[0, 1). Scheduled ticks run it with math.random.
]]
function Fire.tick(world: any, ticker: any, x: number, y: number, z: number, random: Random)
	ticker:schedule(x, y, z, Fire.tickDelay(random))
	local rules = Config.Server.Fire
	if not rules.Tick then
		return
	end
	local getBlock = getter(world)
	local survives = SharedFire.canSurvive(getBlock, x, y, z)
	if survives == nil then
		return
	elseif not survives then
		remove(world, x, y, z)
		return
	end
	local state = stateOf(world)
	local key = Coords.posKey(x, y, z)
	-- (Minecraft keeps the age it started with for the rest of the tick.)
	local age = state.ages[key] or 0
	local aged = math.min(MAX_AGE, age + nextInt(random, 3) // 2)
	if aged ~= age then
		setAge(world, state, key, aged)
	end
	local valid = SharedFire.isValidLocation(getBlock, x, y, z)
	if valid == nil then
		return
	elseif not valid then
		local below = getBlock(x, y - 1, z)
		if below == nil or not Blocks.isSturdy(below) or age > 3 then
			remove(world, x, y, z)
		end
		return
	end
	if age == MAX_AGE and nextInt(random, 4) == 0 and not SharedFire.canBurn(getBlock(x, y - 1, z)) then
		remove(world, x, y, z)
		return
	end
	for _, n in BURN_OUT do
		checkBurnOut(world, x + n[1], y + n[2], z + n[3], n[4], random, age)
	end
	local boost = 40 + rules.Difficulty * 7
	for dx = -1, 1 do
		for dz = -1, 1 do
			for dy = -1, 4 do
				if dx ~= 0 or dy ~= 0 or dz ~= 0 then
					local limit = if dy > 1 then 100 + (dy - 1) * 100 else 100
					local odds = SharedFire.igniteOddsAt(getBlock, x + dx, y + dy, z + dz)
					if odds > 0 then
						local chance = (odds + boost) // (age + 30)
						if chance > 0 and nextInt(random, limit) <= chance then
							Fire.ignite(world, x + dx, y + dy, z + dz, math.min(MAX_AGE, age + nextInt(random, 5) // 4))
						end
					end
				end
			end
		end
	end
end

function Fire.onTick(world: any, ticker: any, x: number, y: number, z: number, _block: number)
	-- (A fire's own tick; anything else at this cell has its own behaviour.)
	Fire.tick(world, ticker, x, y, z, math.random)
end

--[[ Lava ]]

-- Is (x, y, z) loaded and flammable (LavaFluid.isFlammable: ignitedByLava)?
local function lavaLights(world: any, x: number, y: number, z: number): boolean
	return SharedFire.canBurn(world:peekBlock(x, y, z))
end

--[[
	LavaFluid.randomTick for the lava (any level, its cave twin too) at (x, y, z), `random` rolling
	in [0, 1) (see the header). Returns where it lit a fire, if anywhere (the last one).
]]
function Fire.lavaTick(world: any, x: number, y: number, z: number, random: Random): (number?, number?, number?)
	if not Config.Server.Fire.Tick then
		return nil, nil, nil
	end
	local steps = nextInt(random, 3)
	if steps > 0 then
		local bx, by, bz = x, y, z
		for _ = 1, steps do
			bx, by, bz = bx + nextInt(random, 3) - 1, by + 1, bz + nextInt(random, 3) - 1
			local block = world:peekBlock(bx, by, bz)
			if block == nil then
				return nil, nil, nil
			end
			if SharedFire.isEmpty(block) then
				for _, d in SharedFire.NEIGHBOURS do
					if lavaLights(world, bx + d[1], by + d[2], bz + d[3]) then
						Fire.ignite(world, bx, by, bz, 0)
						return bx, by, bz
					end
				end
			elseif Blocks.isSolid(block) or Blocks.obstruction(block) ~= nil then
				return nil, nil, nil
			end
		end
		return nil, nil, nil
	end
	local lit: { number }? = nil
	for _ = 1, 3 do
		local bx, bz = x + nextInt(random, 3) - 1, z + nextInt(random, 3) - 1
		local block = world:peekBlock(bx, y, bz)
		if block == nil then
			break
		end
		if SharedFire.isEmpty(world:peekBlock(bx, y + 1, bz)) and lavaLights(world, bx, y, bz) then
			Fire.ignite(world, bx, y + 1, bz, 0)
			lit = { bx, y + 1, bz }
		end
	end
	if lit then
		return lit[1], lit[2], lit[3]
	end
	return nil, nil, nil
end

--[[ Flint and steel ]]

--[[
	Flint and steel used on face (nx, ny, nz) of block (x, y, z) (FlintAndSteelItem.useOn): fire in
	the cell in front of it when fire may go there (Fire.canPlaceAt: empty, and it survives).
	Returns that cell, or nil when nothing was lit.
]]
function Fire.light(
	world: any,
	x: number,
	y: number,
	z: number,
	nx: number,
	ny: number,
	nz: number
): (number?, number?, number?)
	local tx, ty, tz = x + nx, y + ny, z + nz
	if ty < 0 or ty >= Config.WorldHeight or not SharedFire.canPlaceAt(getter(world), tx, ty, tz) then
		return nil, nil, nil
	end
	if not Fire.ignite(world, tx, ty, tz, 0) then
		return nil, nil, nil
	end
	return tx, ty, tz
end

return Fire

--!strict
--[[
	Lightning: Minecraft 1.20.1's thunderstorm strikes (ServerLevel.tickChunk's lightning,
	findLightningTargetAround, LightningBolt), pure over a view of the world with injected
	randomness so the tests run it; World/WeatherServer plays it out near players.

	  Rate     Minecraft rolls 1 in 100000 a tick for every loaded chunk in a thunderstorm, which
	           would be rare near a player here: instead every player (not a spectator) rolls once
	           a second, `chance`: the thunder at their feet (0..1) / Config.Weather.Lightning
	           .MeanSeconds, a strike every 20 s on average under a full thunderstorm (10 to 40 s
	           apart most of the time), none where it doesn't thunder.
	  Where    a column picked evenly within Config.Weather.Lightning.Radius blocks of the player
	           (`pick`), struck at its top (`target`: World/WeatherRules.top, Minecraft's
	           MOTION_BLOCKING heightmap: a tree's crown, a roof, the ground), or, when living
	           things that see the sky stand within 3 blocks of that column at or above 3 below
	           its top, at one of them picked at random (findLightningTargetAround). Then only
	           where it is raining (Level.isRainingAt: no strikes in snow or deserts, nor under a
	           roof a living thing hides under). A column whose chunk isn't loaded is struck at the
	           generator's height, as a sight and a sound only (nothing there to burn or hurt).
	  Fire     with doFireTick (Config.Server.Fire.Tick), LightningBolt.spawnFire: fire in the
	           struck cell when it is air and fire can stay there (Shared/Fire.canSurvive: on a
	           sturdy block or by something that burns), and on normal and hard difficulty
	           (Config.Server.Fire.Difficulty 2 and 3) in 4 more cells picked at random among the
	           27 around it, by the same rule (`fireCells`).
	  Hurt     living things whose box meets x +- 3, y - 3 .. y + 9, z +- 3 around the bolt
	           (`hits`: LightningBolt's entity search) take Config.Weather.Lightning.Damage half
	           hearts (Minecraft's Entity.thunderHit: 5, through armor) and burn for BurnSeconds
	           (8; a burning one only burns on).
	  Bolt     the clients within Config.Weather.Lightning.Distance get a Lightning message
	           (Protocol): where, the bolt's shape seed and Minecraft's 1 to 3 flashes; they draw
	           the bolt and the flash and play the thunder later the farther they are
	           (Shared/Weather.thunderDelay).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local SharedFire = require(Shared.Fire)

local AIR = Blocks.AIR

-- What `target` reads of the world.
export type View = {
	-- The first cell above the highest rain-stopping block of column (x, z), and whether its chunk
	-- is loaded (World/WeatherRules.top, or the generator's height when not).
	top: (x: number, z: number) -> (number, boolean),
	-- Living things (feet in blocks, box size) whose feet are within `radius` blocks of (x, y, z).
	living: (x: number, y: number, z: number, radius: number) -> { Living },
	-- Does cell (x, y, z) see the sky (World/Skylight.clear: Minecraft's canSeeSky)?
	skyOpen: (x: number, y: number, z: number) -> boolean,
	-- Is it raining on cell (x, y, z) (World/WeatherRules.rainingAt)?
	raining: (x: number, y: number, z: number) -> boolean,
}

export type Living = { x: number, y: number, z: number, width: number, height: number, key: any? }

export type Random = () -> number

local Lightning = {}

-- findLightningTargetAround's reach around the column, how far from the column's top living
-- things are looked for (its box keeps those within reach of the column), and the bolt's reach
-- (LightningBolt).
Lightning.SEARCH = 3
Lightning.LIVING_RADIUS = 12
Lightning.REACH = 3
Lightning.REACH_UP = 9
-- LightningBolt.spawnFire(4) on normal and hard difficulty: 4 more cells.
Lightning.EXTRA_FIRES = 4
Lightning.FIRE_DIFFICULTY = 2

-- Java's random.nextInt(n): 0 .. n - 1, from a roll in [0, 1).
local function nextInt(random: Random, n: number): number
	return math.min(n - 1, math.floor(random() * n))
end

-- The chance of a strike near a player in `seconds` with `thunder` (0..1) at their feet.
function Lightning.chance(thunder: number, meanSeconds: number, seconds: number): number
	if not (thunder > 0) or not (meanSeconds > 0) then
		return 0
	end
	return math.clamp(math.min(thunder, 1) * seconds / meanSeconds, 0, 1)
end

-- An offset picked evenly within a disc of `radius` blocks.
function Lightning.pick(random: Random, radius: number): (number, number)
	local r = radius * math.sqrt(random())
	local angle = random() * 2 * math.pi
	return r * math.cos(angle), r * math.sin(angle)
end

--[[
	Where a strike aimed at column (x, z) lands (see the header): the cell (x, y, z) and whether its
	chunk is loaded; nil when it doesn't strike (no rain there).
]]
function Lightning.target(view: View, x: number, z: number, random: Random): (number?, number?, number?, boolean)
	local top, loaded = view.top(x, z)
	local tx, ty, tz = x, top, z
	if loaded then
		-- (Minecraft's box: the column from 3 below its top up, 3 blocks wider each way.)
		local search = Lightning.SEARCH
		local found: { { number } } = {}
		for _, living in view.living(x + 0.5, top, z + 0.5, Lightning.LIVING_RADIUS) do
			local half = living.width / 2
			if
				living.x + half >= x - search
				and living.x - half <= x + 1 + search
				and living.z + half >= z - search
				and living.z - half <= z + 1 + search
				and living.y + living.height >= top - search
			then
				local fx, fy, fz = math.floor(living.x), math.floor(living.y), math.floor(living.z)
				if view.skyOpen(fx, fy, fz) then
					table.insert(found, { fx, fy, fz })
				end
			end
		end
		if #found > 0 then
			local pickedCell = found[nextInt(random, #found) + 1]
			tx, ty, tz = pickedCell[1], pickedCell[2], pickedCell[3]
		end
	end
	if not view.raining(tx, ty, tz) then
		return nil, nil, nil, loaded
	end
	return tx, ty, tz, loaded
end

--[[
	The cells a bolt at (x, y, z) sets on fire on `difficulty` (LightningBolt.spawnFire, see the
	header), read through `getBlock` (nil: not loaded). The caller checks doFireTick.
]]
function Lightning.fireCells(
	getBlock: SharedFire.GetBlock,
	x: number,
	y: number,
	z: number,
	difficulty: number,
	random: Random
): { { number } }
	local cells: { { number } } = {}
	local function try(cx: number, cy: number, cz: number)
		if getBlock(cx, cy, cz) == AIR and SharedFire.canSurvive(getBlock, cx, cy, cz) == true then
			for _, cell in cells do
				if cell[1] == cx and cell[2] == cy and cell[3] == cz then
					return
				end
			end
			table.insert(cells, { cx, cy, cz })
		end
	end
	try(x, y, z)
	if difficulty >= Lightning.FIRE_DIFFICULTY then
		for _ = 1, Lightning.EXTRA_FIRES do
			try(x + nextInt(random, 3) - 1, y + nextInt(random, 3) - 1, z + nextInt(random, 3) - 1)
		end
	end
	return cells
end

--[[
	Does a bolt at (bx, by, bz) (blocks: the bottom centre of the struck cell) reach a living thing
	with feet at (x, y, z) and a box `width` wide and `height` tall (see the header)?
]]
function Lightning.hits(
	bx: number,
	by: number,
	bz: number,
	x: number,
	y: number,
	z: number,
	width: number,
	height: number
): boolean
	local half = width / 2
	local reach = Lightning.REACH
	return x + half >= bx - reach
		and x - half <= bx + reach
		and z + half >= bz - reach
		and z - half <= bz + reach
		and y + height >= by - reach
		and y <= by + Lightning.REACH_UP
end

-- The bolt's 1 to 3 flashes (LightningBolt: flashes = rand(3) + 1) and its shape's seed.
function Lightning.bolt(random: Random): (number, number)
	return nextInt(random, 3) + 1, nextInt(random, 4294967296)
end

return Lightning

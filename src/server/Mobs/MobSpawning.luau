--!strict
--!native
--[[
	Natural mob spawning (pure; Mobs/Mobs runs it every tick): Minecraft 1.20.1's NaturalSpawner
	cut down to a bounded number of tries around each player.

	  When      monsters every HostileInterval ticks (a second), creatures every PassiveInterval
	            (400 ticks: Minecraft's spawnPersistent animals), for each living player who is
	            not a spectator (Minecraft leaves spectators out), each player on a tick of their
	            own within the interval (so the costs spread out), while that category has room:
	            fewer than PassiveCap creatures / HostileCap monsters within 128 blocks of the
	            player (monsters only in the chunks that tick: `census`), and fewer than
	            MaxPassive / MaxHostile (and the world's MaxMobs) in all.
	  Where     `Attempts` packs a player per round, each in a random direction SpawnDistance
	            (24..44) blocks out, inside the chunks that tick (World/Simulation), never in a
	            chunk that isn't loaded (nothing is generated) and never within 24 blocks of any
	            player (Minecraft's 24 block rule). A pack's centre is the first spot down a
	            column (creatures from 20 above the player's feet, monsters from a random height
	            within 16 of them); its members, one kind (picked by spawn weight: sheep 12, pig 10,
	            chicken 10, cow 8; zombie 100, runner 25, crawler 12, screamer 5, brute 4,
	            construction 4, soldier 3, doctor 2: MobList `spawn`; in a city, `context.cityAt`
	            0.5 or more at the pack's centre, the zombies' `cityWeight`s: zombie 100, runner
	            30, police 12, crawler 12, construction 8, firefighter 6, brute 6, screamer 6,
	            doctor 5, soldier 1), spread up to 4 blocks around it, `group` of them (2-4
	            creatures; 1-5 zombies, by kind), each on a spot of its own found within 3 blocks up
	            or down (`spawnPack`, which a blood moon's waves use too: Mobs/ZombieDirector). In
	            a city a monster pack keeps to floors at most GROUND_ABOVE (MobAI.MAX_FALL, 3)
	            above the generator's ground (`context.ground`: the plateau): never on the upper
	            floors and roofs a zombie could never come down from (it drops at most 3 and
	            takes no ladder down), so none fills the city's cap stranded up there. A floor
	            found higher, the column scan goes on down below it (a building's ground floor, the
	            street); a member higher than its pack's ceiling must be within it of its own
	            column's ground.
	  Caps      a player's monster cap is `context.hostileCap(player)` when given (the zombie
	            apocalypse's: by day, at night, in a city, in a blood moon: Mobs/ZombieDirector),
	            else Settings.HostileCap; while `context.hostilePaused` (a blood moon) no monster
	            spawns naturally at all (the waves bring them).
	  A spot    a solid, opaque, sturdy floor (not leaves, glass, a chest...) with the mob's whole
	            box free above it (no solid block, no fluid, no fire: Burning.touching), no rail
	            in its cell or the one above (Minecraft's #prevent_mob_spawning_inside, so a
	            mineshaft's track stays clear; a cobweb does not stop a spawn, as in Minecraft:
	            NaturalSpawner.isValidEmptySpawnBlock), and:
	              creatures  grass (or savanna grass) under it and a raw brightness above 8
	                         (Animal.checkAnimalSpawnRules: the sky light, or a torch): open
	                         ground by day or night, never deserts, beaches, snow or mycelium;
	              monsters   no block light at all and dark enough by Minecraft's rolls
	                         (Shared/World/LightEstimate.darkForMonsters: at night about half the
	                         open ground, by day only out of the sky's reach: caves, deep
	                         overhangs);
	              zombies    by day (`context.daySpawn`: Apocalypse.Zombies.DaySpawning) on a
	                         floor under the open sky the darkness rolls are skipped, but the
	                         block light must still be 0 (searched over DayLightBudget, 2048
	                         cells: as far as a torch's light reaches on open ground, 13 blocks),
	                         so torches keep a courtyard clear; under a roof or underground they
	                         need the dark as any monster;
	              waves      (`spawnPack`'s "wave" light: a blood moon's) under the open sky, in any
	                         light: never inside a roofed base or a bunker.
	            The light is Shared/World/LightEstimate's estimate from the loaded blocks (the
	            server keeps no light map; the sky is World/Skylight.open), the same estimate the
	            client's WAILA shows.
	  Costs     per round at most players x Attempts packs x 5 members, each spot a short column
	            scan and one sky search of 48 cells, and for a monster whose light rolls pass (or
	            a zombie by day) a block light search of up to LightEstimate.SPAWN_BUDGET (2048)
	            cells, so torches keep monsters out of a room as far as their light reaches (13
	            blocks), however big the room (a creature's: 256 cells). A pack's members share
	            one search (`dark`: from all their cells at once, which costs about two members'
	            searches for a pack of five, since their reaches overlap); only where it finds
	            light does each member search on its own (LightEstimate.blockLight), so the
	            answer is the same as one search each.

	Config.Mobs.Spawning = false turns natural spawning off (/summon still works).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local ChunkLayout = require(Shared.World.ChunkLayout)
local Config = require(Shared.Config)
local DayCycle = require(Shared.DayCycle)
local GameMode = require(Shared.GameMode)
local Hull = require(Shared.Movement.Hull)
local Shapes = require(Shared.Blocks.Shapes)
local LightEstimate = require(Shared.World.LightEstimate)
local MobList = require(Shared.Entities.MobList)

local Burning = require(script.Parent.Parent.Players.Burning)
local MobAI = require(script.Parent.MobAI)
local MobWorld = require(script.Parent.MobWorld)

local Apocalypse = Config.Apocalypse

export type Settings = {
	Spawning: boolean,
	PassiveCap: number,
	HostileCap: number,
	MaxPassive: number,
	MaxHostile: number,
	PassiveInterval: number,
	HostileInterval: number,
	Attempts: number,
	SpawnDistance: { number },
}

export type Context = {
	players: { MobWorld.PlayerView },
	dayTime: number,
	skyOpen: (x: number, y: number, z: number) -> boolean?,
	active: (cx: number, cz: number) -> boolean,
	-- (The zombie apocalypse; all optional.) How much a column is in a city (1 inside, 0 outside:
	-- the generator's cityAt), a player's monster cap, whether zombies spawn by day on open
	-- ground, and whether natural monster spawning is paused (a blood moon).
	cityAt: ((x: number, z: number) -> number)?,
	hostileCap: ((player: MobWorld.PlayerView) -> number)?,
	daySpawn: boolean?,
	hostilePaused: boolean?,
	-- The generator's ground at a column (its height: the first air above the terrain, a city's
	-- plateau, no building): blood moon waves keep off what stands above it (ZombieDirector).
	ground: ((x: number, z: number) -> number)?,
}

-- How a spot's light is judged (see the header): "dark" (monsters: Minecraft's rolls), "day"
-- (zombies on an open floor by day: block light 0 only), "wave" (open sky, any light),
-- "animal" (creatures: bright enough). nil: by the kind and the context.
export type Light = "dark" | "day" | "wave" | "animal"

-- Which weights pick a zombie kind: the wild's, a city's, a blood moon's waves'.
export type Weights = "wild" | "city" | "horde"

export type State = { tick: number }

local MobSpawning = {}

-- No spawn this close to a player (blocks).
MobSpawning.MIN_PLAYER_DISTANCE = 24
-- Mobs within this many blocks count against a player's caps.
MobSpawning.CAP_DISTANCE = 128
-- A pack's members spread this far around its centre, each looking this far up and down.
MobSpawning.PACK_SPREAD = 4
MobSpawning.PACK_SEARCH = 3
-- A pack's centre: creatures look down a column from this far above the player's feet over
-- PASSIVE_SCAN blocks, monsters from a random height within HOSTILE_HEIGHT over HOSTILE_SCAN.
MobSpawning.PASSIVE_HEIGHT = 20
MobSpawning.PASSIVE_SCAN = 48
MobSpawning.HOSTILE_HEIGHT = 16
MobSpawning.HOSTILE_SCAN = 24
-- In a city a monster's floor is at most this far above the generator's ground (see the header).
MobSpawning.GROUND_ABOVE = MobAI.MAX_FALL

local floor = math.floor
local CHUNK = ChunkLayout.SIZE
local GRASS = Blocks.find("Grass")
local DRY_GRASS = Blocks.find("DryGrass")
-- Nothing spawns inside these (Minecraft's #prevent_mob_spawning_inside: the rails).
local PREVENT_INSIDE: { [number]: boolean } = {}
for _, name in { "Rail", "RailEastWest", "CaveRail", "CaveRailEastWest" } do
	PREVENT_INSIDE[Blocks.find(name) :: number] = true
end

function MobSpawning.new(): State
	return { tick = 0 }
end

-- A kind's spawn weight by `weights` in blood moon `moon` (1, 2...; the horde's growth).
function MobSpawning.weight(kind: MobList.Kind, weights: Weights?, moon: number?): number
	local spawn = kind.spawn
	if weights == "city" then
		return spawn.cityWeight or spawn.weight
	elseif weights == "horde" then
		local base = spawn.hordeWeight or spawn.weight
		return base * (1 + (spawn.hordeGrowth or 0) * math.max(0, (moon or 1) - 1))
	end
	return spawn.weight
end

-- The kinds of a category (hostile or not) with a weight by `weights`, and their total.
local function kindsOf(hostile: boolean, weights: Weights?): ({ MobList.Kind }, number)
	local kinds, total = {}, 0
	for _, kind in MobList.kinds do
		local weight = MobSpawning.weight(kind, weights, 1)
		if kind.hostile == hostile and weight > 0 then
			table.insert(kinds, kind)
			total += weight
		end
	end
	return kinds, total
end
local HOSTILE_KINDS, HOSTILE_WEIGHT = kindsOf(true, "wild")
local CITY_KINDS, CITY_WEIGHT = kindsOf(true, "city")
local PASSIVE_KINDS, PASSIVE_WEIGHT = kindsOf(false, "wild")
local ZOMBIE_KINDS: { MobList.Kind } = {}
for _, kind in MobList.kinds do
	if kind.zombie then
		table.insert(ZOMBIE_KINDS, kind)
	end
end

--[[
	A kind of the category, by spawn weight (WeightedRandom): monsters by `weights` ("wild" by
	default; "horde" grows with blood moon `moon`), creatures by their own.
]]
function MobSpawning.pickKind(hostile: boolean, random: () -> number, weights: Weights?, moon: number?): MobList.Kind
	if hostile and weights == "horde" then
		local total = 0
		for _, kind in ZOMBIE_KINDS do
			total += MobSpawning.weight(kind, "horde", moon)
		end
		local pick = random() * total
		for _, kind in ZOMBIE_KINDS do
			pick -= MobSpawning.weight(kind, "horde", moon)
			if pick < 0 then
				return kind
			end
		end
		return ZOMBIE_KINDS[1]
	end
	local kinds, total = PASSIVE_KINDS, PASSIVE_WEIGHT
	if hostile then
		kinds, total = HOSTILE_KINDS, HOSTILE_WEIGHT
		if weights == "city" then
			kinds, total = CITY_KINDS, CITY_WEIGHT
		end
	end
	local pick = random() * total
	for _, kind in kinds do
		pick -= MobSpawning.weight(kind, if hostile then weights or "wild" else "wild", 1)
		if pick < 0 then
			return kind
		end
	end
	return kinds[#kinds]
end
local pickKind = MobSpawning.pickKind

-- Is block cell (x, y, z) at least MIN_PLAYER_DISTANCE from every player?
local function awayFromPlayers(players: { MobWorld.PlayerView }, x: number, y: number, z: number): boolean
	local limit = MobSpawning.MIN_PLAYER_DISTANCE * MobSpawning.MIN_PLAYER_DISTANCE
	for _, player in players do
		local dx, dy, dz = player.x - (x + 0.5), player.y - y, player.z - (z + 0.5)
		if dx * dx + dy * dy + dz * dz < limit then
			return false
		end
	end
	return true
end

--[[
	validSpot's rules but the block light's (see validSpot): false, or true and nil (the spot will
	do), or true and the budget of the block light search that must find no light for it to do.
]]
local function spotRules(
	getBlock: (x: number, y: number, z: number) -> number?,
	context: Context,
	kind: MobList.Kind,
	x: number,
	y: number,
	z: number,
	nextInt: (n: number) -> number,
	light: Light?
): (boolean, number?)
	if not context.active(x // CHUNK, z // CHUNK) then
		return false
	end
	local below = getBlock(x, y - 1, z)
	if below == nil or not Blocks.isSolid(below) or not Blocks.isOpaque(below) or not Blocks.isSturdy(below) then
		return false
	end
	if kind.hostile == false and below ~= GRASS and below ~= DRY_GRASS then
		return false
	end
	if light == "wave" and context.skyOpen(x, y, z) ~= true then
		-- (A wave comes in under the open sky only.)
		return false
	end
	-- The whole box free: no solid block, nothing unloaded, no fluid, no fire.
	local box = Hull.box(x + 0.5, y, z + 0.5, kind.width, kind.height)
	local function solidAt(bx: number, by: number, bz: number): boolean | Hull.Shape
		local block = getBlock(bx, by, bz)
		return block == nil or Shapes.collisionAt(getBlock, bx, by, bz, block)
	end
	if not Hull.noCollision(solidAt, box) then
		return false
	end
	local feet, head = getBlock(x, y, z), getBlock(x, y + 1, z)
	if (feet and PREVENT_INSIDE[feet]) or (head and PREVENT_INSIDE[head]) then
		return false
	end
	if Burning.touching(getBlock, box.minX, box.minY, box.minZ, box.maxX, box.maxY, box.maxZ) ~= 0 then
		return false
	end
	if not awayFromPlayers(context.players, x, y, z) then
		return false
	end
	if light == "wave" then
		return true
	end
	if
		light == "day"
		or (
			light == nil
			and context.daySpawn == true
			and kind.zombie == true
			and DayCycle.isDay(context.dayTime)
			and context.skyOpen(x, y, z) == true
		)
	then
		-- (A zombie on an open floor by day: no darkness rolls, but no block light either.)
		return true, Apocalypse.Zombies.DayLightBudget
	end
	local sky = LightEstimate.skyLight(getBlock, context.skyOpen, x, y, z)
	if kind.hostile and light ~= "animal" then
		-- The sky's rolls first (as with no block light), then the block light, which must be 0:
		-- the same odds, but the costly search (every cell a torch could light: SPAWN_BUDGET)
		-- only for spots the rolls let through.
		if not LightEstimate.darkForMonsters(sky, 0, DayCycle.skyDarken(context.dayTime), nextInt) then
			return false
		end
		return true, LightEstimate.SPAWN_BUDGET
	end
	if LightEstimate.brightForAnimals(sky, 0) then
		return true
	end
	return LightEstimate.brightForAnimals(sky, LightEstimate.blockLight(getBlock, x, y, z))
end

--[[
	May a mob of `kind` spawn standing in block cell (x, y, z) (its feet at the cell's bottom
	centre)? See the header. `nextInt` rolls Minecraft's light tests; `light` says how the light
	is judged (nil: by the kind and the context).
]]
function MobSpawning.validSpot(
	getBlock: (x: number, y: number, z: number) -> number?,
	context: Context,
	kind: MobList.Kind,
	x: number,
	y: number,
	z: number,
	nextInt: (n: number) -> number,
	light: Light?
): boolean
	local ok, budget = spotRules(getBlock, context, kind, x, y, z, nextInt, light)
	if ok and budget then
		return LightEstimate.blockLight(getBlock, x, y, z, budget, 1) == 0
	end
	return ok
end

-- Per block: its light (Blocks.light, the low 4 bits) and 16 when it is opaque (light stops).
local LIGHT_INFO = buffer.create(Blocks.count)
for id = 0, Blocks.count - 1 do
	buffer.writeu8(LIGHT_INFO, id, Blocks.light(id) + (if Blocks.isOpaque(id) then 16 else 0))
end
local BLOCK_COUNT = Blocks.count
local MAX_LIGHT = LightEstimate.MAX
-- `dark`'s scratch, reused (as LightEstimate's): a visited stamp per cell offset from the first
-- cell (within REACH each way), and the frontiers as flat offset lists.
local REACH = 31
local SPAN = REACH * 2 + 2
local darkSeen = buffer.create(SPAN * SPAN * SPAN * 2)
local darkStamp = 0
local darkFront: { number } = {}
local darkNext: { number } = {}
local STEP_X = { 1, -1, 0, 0, 0, 0 }
local STEP_Y = { 0, 0, 1, -1, 0, 0 }
local STEP_Z = { 0, 0, 0, 0, 1, -1 }

--[[
	Is the block light 0 in every one of `cells` (flat x, y, z lists of block cells)? One breadth
	first search from all of them at once, as LightEstimate.blockLight searches from one: through
	cells that aren't opaque, a source of light L at d steps from the nearest of them lighting it
	when L > d, at most `budget` cells. true: no light reaches any of them; false: light reaches at
	least one (which, `dark` doesn't say); nil: it can't tell (the budget ran out, or the cells lie
	too far apart for one search).
]]
function MobSpawning.dark(
	getBlock: (x: number, y: number, z: number) -> number?,
	cells: { number },
	budget: number
): boolean?
	local n = #cells
	if n == 0 then
		return true
	end
	darkStamp += 1
	if darkStamp > 65535 then
		buffer.fill(darkSeen, 0, 0)
		darkStamp = 1
	end
	local stamp = darkStamp
	local ox, oy, oz = cells[1], cells[2], cells[3]
	-- (Every cell the search may reach, MAX_LIGHT - 1 steps from a start, within REACH.)
	local spread = REACH - (MAX_LIGHT - 1)
	local front, nextFront = darkFront, darkNext
	table.clear(front)
	local count = 0
	for i = 1, n, 3 do
		local x, y, z = cells[i], cells[i + 1], cells[i + 2]
		local dx, dy, dz = x - ox, y - oy, z - oz
		if dx < -spread or dx > spread or dy < -spread or dy > spread or dz < -spread or dz > spread then
			return nil
		end
		local key = (((dx + REACH) * SPAN + (dy + REACH)) * SPAN + (dz + REACH)) * 2
		if buffer.readu16(darkSeen, key) ~= stamp then
			buffer.writeu16(darkSeen, key, stamp)
			local block = getBlock(x, y, z)
			if block ~= nil and block >= 0 and block < BLOCK_COUNT then
				local info = buffer.readu8(LIGHT_INFO, block)
				if info % 16 > 0 then
					return false
				end
				-- (An opaque cell has its own light only.)
				if info < 16 then
					local m = #front
					front[m + 1], front[m + 2], front[m + 3] = dx, dy, dz
					count += 1
				end
			end
		end
	end
	local exhausted = false
	local distance = 0
	-- (Light from d + 1 steps away reaches a start only from a source brighter than d + 1.)
	while #front > 0 and distance + 1 < MAX_LIGHT do
		local steps = distance + 1
		table.clear(nextFront)
		for i = 1, #front, 3 do
			local cx, cy, cz = front[i], front[i + 1], front[i + 2]
			for side = 1, 6 do
				local nx, ny, nz = cx + STEP_X[side], cy + STEP_Y[side], cz + STEP_Z[side]
				if nx >= -REACH and nx <= REACH and ny >= -REACH and ny <= REACH and nz >= -REACH and nz <= REACH then
					local key = (((nx + REACH) * SPAN + (ny + REACH)) * SPAN + (nz + REACH)) * 2
					if buffer.readu16(darkSeen, key) ~= stamp then
						buffer.writeu16(darkSeen, key, stamp)
						local block = getBlock(ox + nx, oy + ny, oz + nz)
						if block ~= nil and block >= 0 and block < BLOCK_COUNT then
							local info = buffer.readu8(LIGHT_INFO, block)
							if info % 16 > steps then
								return false
							end
							-- (Cells of the last step are only looked at: nothing lies beyond.)
							if info < 16 and steps + 1 < MAX_LIGHT then
								if count < budget then
									count += 1
									local m = #nextFront
									nextFront[m + 1], nextFront[m + 2], nextFront[m + 3] = nx, ny, nz
								else
									exhausted = true
								end
							end
						end
					end
				end
			end
		end
		front, nextFront = nextFront, front
		distance = steps
	end
	return if exhausted then nil else true
end

-- The first cell going down from (x, y, z) over `scan` cells whose floor is solid with room for
-- `kind` above it, or nil (an unloaded cell ends the search).
function MobSpawning.findFloor(
	getBlock: (x: number, y: number, z: number) -> number?,
	kind: MobList.Kind,
	x: number,
	y: number,
	z: number,
	scan: number
): number?
	local clear = 0
	local need = math.ceil(kind.height)
	for cy = y, y - scan, -1 do
		local block = getBlock(x, cy, z)
		if block == nil then
			return nil
		end
		if Blocks.isSolid(block) then
			if clear >= need then
				return cy + 1
			end
			clear = 0
		else
			clear += 1
		end
	end
	return nil
end
local findFloor = MobSpawning.findFloor

--[[
	Spawns up to `count` mobs of `kind` around the pack centre (x, y, z) (a cell: its floor
	found), the first there and each other within PACK_SPREAD blocks on a floor of its own within
	PACK_SEARCH up or down, each on a valid spot (`light`: see validSpot) and, given a `ceiling`,
	at most that high unless within GROUND_ABOVE of its own column's `context.ground` (see the
	header). The members that need no block light are judged together (`dark`, see the header)
	and spawn after the rest. Returns their ids.
]]
function MobSpawning.spawnPack(
	world: MobWorld.MobWorld,
	context: Context,
	kind: MobList.Kind,
	x: number,
	y: number,
	z: number,
	count: number,
	nextInt: (n: number) -> number,
	light: Light?,
	ceiling: number?
): { number }
	local getBlock = world.getBlock
	local ground = context.ground
	local ids = {}
	-- (The members waiting on the block light: their cells, flat, and their search budgets.)
	local waiting: { number }? = nil
	local budgets: { number } = {}
	local total = 0
	for member = 1, count do
		local mx, mz = x, z
		if member > 1 then
			mx += nextInt(MobSpawning.PACK_SPREAD * 2 + 1) - MobSpawning.PACK_SPREAD
			mz += nextInt(MobSpawning.PACK_SPREAD * 2 + 1) - MobSpawning.PACK_SPREAD
		end
		local my = findFloor(getBlock, kind, mx, y + MobSpawning.PACK_SEARCH, mz, MobSpawning.PACK_SEARCH * 2)
		if my and ceiling and my > ceiling and (ground == nil or my > ground(mx, mz) + MobSpawning.GROUND_ABOVE) then
			my = nil
		end
		if my then
			local ok, budget = spotRules(getBlock, context, kind, mx, my, mz, nextInt, light)
			if ok and budget then
				local list = waiting or {}
				waiting = list
				local m = #list
				list[m + 1], list[m + 2], list[m + 3] = mx, my, mz
				table.insert(budgets, budget)
				total += budget
			elseif ok then
				local id = world:spawn(kind.id, mx + 0.5, my, mz + 0.5)
				if id ~= 0 then
					table.insert(ids, id)
				end
			end
		end
	end
	if waiting then
		local allDark = MobSpawning.dark(getBlock, waiting, total)
		-- (Light somewhere among several, or no answer: whose, each one's own search says. A lone
		-- member the search found light at is lit.)
		local each = allDark == nil or (allDark == false and #waiting > 3)
		for i = 1, #waiting, 3 do
			local mx, my, mz = waiting[i], waiting[i + 1], waiting[i + 2]
			if
				allDark == true
				or (each and LightEstimate.blockLight(getBlock, mx, my, mz, budgets[(i + 2) // 3], 1) == 0)
			then
				local id = world:spawn(kind.id, mx + 0.5, my, mz + 0.5)
				if id ~= 0 then
					table.insert(ids, id)
				end
			end
		end
	end
	return ids
end

-- Tries one pack of `hostile` mobs around `player`; returns how many spawned.
local function tryPack(
	world: MobWorld.MobWorld,
	context: Context,
	settings: Settings,
	player: MobWorld.PlayerView,
	hostile: boolean,
	room: number
): number
	local random = world.random
	local function nextInt(n: number): number
		return floor(random() * n)
	end
	local getBlock = world.getBlock
	-- (The kind's roll first, its weights once the pack's centre is known.)
	local kindRoll = random()
	local near, far = settings.SpawnDistance[1], settings.SpawnDistance[2]
	local angle = random() * math.pi * 2
	local distance = near + random() * (far - near)
	local cx = floor(player.x + math.cos(angle) * distance)
	local cz = floor(player.z + math.sin(angle) * distance)
	if not context.active(cx // CHUNK, cz // CHUNK) then
		return 0
	end
	local cityAt = context.cityAt
	local weights: Weights = if hostile and cityAt and cityAt(cx + 0.5, cz + 0.5) >= 0.5 then "city" else "wild"
	local kind = pickKind(hostile, function(): number
		return kindRoll
	end, weights)
	local startY, scan
	if hostile then
		startY = floor(player.y) + nextInt(MobSpawning.HOSTILE_HEIGHT * 2 + 1) - MobSpawning.HOSTILE_HEIGHT
		scan = MobSpawning.HOSTILE_SCAN
	else
		startY = floor(player.y) + MobSpawning.PASSIVE_HEIGHT
		scan = MobSpawning.PASSIVE_SCAN
	end
	local cy = findFloor(getBlock, kind, cx, startY, cz, scan)
	local ceiling: number? = nil
	local ground = context.ground
	if hostile and weights == "city" and ground ~= nil then
		-- (Never on a city floor it couldn't come down from: on down the column, see the header.)
		local top = ground(cx, cz) + MobSpawning.GROUND_ABOVE
		ceiling = top
		local bottom = startY - scan
		while cy ~= nil and cy > top do
			cy = findFloor(getBlock, kind, cx, cy - 2, cz, cy - 2 - bottom)
		end
	end
	if cy == nil then
		return 0
	end
	local group = kind.spawn.group
	local size = math.min(group[1] + nextInt(group[2] - group[1] + 1), room)
	return #MobSpawning.spawnPack(world, context, kind, cx, cy, cz, size, nextInt, nil, ceiling)
end

--[[
	Mobs of each category (hostile, creatures) in the world, or around (x, y, z): within
	CAP_DISTANCE of it, monsters only where they tick (not `frozen`). The chunks that tick reach
	about 56 blocks (Config.Server.SimulationRadius 3), half the 128 of the caps: monsters left
	frozen farther out would fill a player's cap while none are about them (they idle away,
	MobWorld's despawning). Creatures stay for good, so all of them count.
]]
local function census(world: MobWorld.MobWorld, x: number?, y: number?, z: number?): (number, number)
	local hostile, passive = 0, 0
	local limit = MobSpawning.CAP_DISTANCE * MobSpawning.CAP_DISTANCE
	for _, mob in world.order do
		if not mob.removed then
			local body = mob.body
			local counted = true
			if x and y and z then
				local dx, dy, dz = body.x - x, body.y - y, body.z - z
				counted = dx * dx + dy * dy + dz * dz <= limit and not (mob.frozen and mob.kind.hostile)
			end
			if counted then
				if mob.kind.hostile then
					hostile += 1
				else
					passive += 1
				end
			end
		end
	end
	return hostile, passive
end
MobSpawning.census = census

--[[
	One server tick of natural spawning (see the header). Returns how many mobs spawned.
]]
function MobSpawning.step(world: MobWorld.MobWorld, state: State, context: Context, settings: Settings): number
	state.tick += 1
	if not settings.Spawning then
		return 0
	end
	local hostileInterval = math.max(1, settings.HostileInterval)
	local passiveInterval = math.max(1, settings.PassiveInterval)
	local spawned = 0
	local totalHostile, totalPassive = -1, -1
	for index, player in context.players do
		-- (Each player's round on a tick of its own: the cost spreads over the interval.)
		local hostileDue = (state.tick + index) % hostileInterval == 0
		local passiveDue = (state.tick + index) % passiveInterval == 0
		if not (hostileDue or passiveDue) or not player.alive or GameMode.isSpectator(player.mode) then
			continue
		end
		if totalHostile < 0 then
			totalHostile, totalPassive = census(world)
		end
		local localHostile, localPassive = census(world, player.x, player.y, player.z)
		local cap = if context.hostileCap then context.hostileCap(player) else settings.HostileCap
		for _ = 1, settings.Attempts do
			if world.live >= world.options.maxMobs then
				return spawned
			end
			if hostileDue and not context.hostilePaused then
				local room = math.min(cap - localHostile, settings.MaxHostile - totalHostile)
				if room > 0 then
					local n = tryPack(world, context, settings, player, true, room)
					localHostile += n
					totalHostile += n
					spawned += n
				end
			end
			if passiveDue then
				local room = math.min(settings.PassiveCap - localPassive, settings.MaxPassive - totalPassive)
				if room > 0 then
					local n = tryPack(world, context, settings, player, false, room)
					localPassive += n
					totalPassive += n
					spawned += n
				end
			end
		end
	end
	return spawned
end

return MobSpawning

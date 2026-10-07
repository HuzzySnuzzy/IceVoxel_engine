--!strict
--[[
	Natural mob spawning (pure; Mobs/Mobs runs it every tick): Minecraft 1.20.1's NaturalSpawner
	cut down to a bounded number of tries around each player.

	  When      monsters every HostileInterval ticks (a second), creatures every PassiveInterval
	            (400 ticks: Minecraft's spawnPersistent animals), for each living player who is
	            not a spectator (Minecraft leaves spectators out), each player on a tick of their
	            own within the interval (so the costs spread out), while that category has room:
	            fewer than PassiveCap creatures / HostileCap monsters within 128 blocks of the
	            player, and fewer than MaxPassive / MaxHostile (and the world's MaxMobs) in all.
	  Where     `Attempts` packs a player per round, each in a random direction SpawnDistance
	            (24..44) blocks out, inside the chunks that tick (World/Simulation), never in a
	            chunk that isn't loaded (nothing is generated) and never within 24 blocks of any
	            player (Minecraft's 24 block rule). A pack's centre is the first spot down a
	            column (creatures from 20 above the player's feet, monsters from a random height
	            within 16 of them); its members, one kind (picked by spawn weight: sheep 12, pig 10,
	            chicken 10, cow 8; spider 100, zombie 95, skeleton 100, creeper 100), spread up to
	            4 blocks around it, `group` of them (2-4 creatures, 1-4 monsters), each on a spot
	            of its own found within 3 blocks up or down.
	  A spot    a solid, opaque, sturdy floor (not leaves, glass, a chest...) with the mob's whole
	            box free above it (no solid block, no fluid, no fire: Burning.touching), and:
	              creatures  grass (or savanna grass) under it and a raw brightness above 8
	                         (Animal.checkAnimalSpawnRules: the sky light, or a torch): open
	                         ground by day or night, never deserts, beaches, snow or mycelium;
	              monsters   no block light at all and dark enough by Minecraft's rolls
	                         (Shared/World/LightEstimate.darkForMonsters: at night about half the
	                         open ground, by day only out of the sky's reach: caves, deep
	                         overhangs).
	            The light is Shared/World/LightEstimate's estimate from the loaded blocks (the
	            server keeps no light map; the sky is World/Skylight.open), the same estimate the
	            client's WAILA shows.
	  Costs     per round at most players x Attempts packs x 4 members, each spot a short column
	            scan and at most one block light search of 256 cells and one sky search of 48.

	Config.Mobs.Spawning = false turns natural spawning off (/summon still works).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local ChunkLayout = require(Shared.World.ChunkLayout)
local DayCycle = require(Shared.DayCycle)
local GameMode = require(Shared.GameMode)
local Hull = require(Shared.Movement.Hull)
local LightEstimate = require(Shared.World.LightEstimate)
local MobList = require(Shared.Entities.MobList)

local Burning = require(script.Parent.Parent.Players.Burning)
local MobWorld = require(script.Parent.MobWorld)

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
}

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

local floor = math.floor
local CHUNK = ChunkLayout.SIZE
local GRASS = Blocks.find("Grass")
local DRY_GRASS = Blocks.find("DryGrass")

function MobSpawning.new(): State
	return { tick = 0 }
end

-- The kinds of a category (hostile or not) and their total spawn weight.
local function kindsOf(hostile: boolean): ({ MobList.Kind }, number)
	local kinds, total = {}, 0
	for _, kind in MobList.kinds do
		if kind.hostile == hostile and kind.spawn.weight > 0 then
			table.insert(kinds, kind)
			total += kind.spawn.weight
		end
	end
	return kinds, total
end
local HOSTILE_KINDS, HOSTILE_WEIGHT = kindsOf(true)
local PASSIVE_KINDS, PASSIVE_WEIGHT = kindsOf(false)

-- A kind of the category, by spawn weight (WeightedRandom).
local function pickKind(hostile: boolean, random: () -> number): MobList.Kind
	local kinds = if hostile then HOSTILE_KINDS else PASSIVE_KINDS
	local pick = random() * (if hostile then HOSTILE_WEIGHT else PASSIVE_WEIGHT)
	for _, kind in kinds do
		pick -= kind.spawn.weight
		if pick < 0 then
			return kind
		end
	end
	return kinds[#kinds]
end

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
	May a mob of `kind` spawn standing in block cell (x, y, z) (its feet at the cell's bottom
	centre)? See the header. `nextInt` rolls Minecraft's light tests.
]]
function MobSpawning.validSpot(
	getBlock: (x: number, y: number, z: number) -> number?,
	context: Context,
	kind: MobList.Kind,
	x: number,
	y: number,
	z: number,
	nextInt: (n: number) -> number
): boolean
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
	-- The whole box free: no solid block, nothing unloaded, no fluid, no fire.
	local box = Hull.box(x + 0.5, y, z + 0.5, kind.width, kind.height)
	local function solidAt(bx: number, by: number, bz: number): boolean
		local block = getBlock(bx, by, bz)
		return block == nil or Blocks.isSolid(block)
	end
	if not Hull.noCollision(solidAt, box) then
		return false
	end
	if Burning.touching(getBlock, box.minX, box.minY, box.minZ, box.maxX, box.maxY, box.maxZ) ~= 0 then
		return false
	end
	if not awayFromPlayers(context.players, x, y, z) then
		return false
	end
	local sky = LightEstimate.skyLight(getBlock, context.skyOpen, x, y, z)
	if kind.hostile then
		local block = LightEstimate.blockLight(getBlock, x, y, z)
		return LightEstimate.darkForMonsters(sky, block, DayCycle.skyDarken(context.dayTime), nextInt)
	end
	if LightEstimate.brightForAnimals(sky, 0) then
		return true
	end
	return LightEstimate.brightForAnimals(sky, LightEstimate.blockLight(getBlock, x, y, z))
end

-- The first cell going down from (x, y, z) over `scan` cells whose floor is solid with room for
-- `kind` above it, or nil (an unloaded cell ends the search).
local function findFloor(
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
	local kind = pickKind(hostile, random)
	local near, far = settings.SpawnDistance[1], settings.SpawnDistance[2]
	local angle = random() * math.pi * 2
	local distance = near + random() * (far - near)
	local cx = floor(player.x + math.cos(angle) * distance)
	local cz = floor(player.z + math.sin(angle) * distance)
	if not context.active(cx // CHUNK, cz // CHUNK) then
		return 0
	end
	local startY, scan
	if hostile then
		startY = floor(player.y) + nextInt(MobSpawning.HOSTILE_HEIGHT * 2 + 1) - MobSpawning.HOSTILE_HEIGHT
		scan = MobSpawning.HOSTILE_SCAN
	else
		startY = floor(player.y) + MobSpawning.PASSIVE_HEIGHT
		scan = MobSpawning.PASSIVE_SCAN
	end
	local cy = findFloor(getBlock, kind, cx, startY, cz, scan)
	if cy == nil then
		return 0
	end
	local group = kind.spawn.group
	local size = math.min(group[1] + nextInt(group[2] - group[1] + 1), room)
	local spawned = 0
	for member = 1, size do
		local x, z = cx, cz
		if member > 1 then
			x += nextInt(MobSpawning.PACK_SPREAD * 2 + 1) - MobSpawning.PACK_SPREAD
			z += nextInt(MobSpawning.PACK_SPREAD * 2 + 1) - MobSpawning.PACK_SPREAD
		end
		local y = findFloor(getBlock, kind, x, cy + MobSpawning.PACK_SEARCH, z, MobSpawning.PACK_SEARCH * 2)
		if y and MobSpawning.validSpot(getBlock, context, kind, x, y, z, nextInt) then
			if world:spawn(kind.id, x + 0.5, y, z + 0.5) ~= 0 then
				spawned += 1
			end
		end
	end
	return spawned
end

-- Mobs of each category (hostile, creatures) in the world, and within CAP_DISTANCE of (x, y, z).
local function census(world: MobWorld.MobWorld, x: number?, y: number?, z: number?): (number, number)
	local hostile, passive = 0, 0
	local limit = MobSpawning.CAP_DISTANCE * MobSpawning.CAP_DISTANCE
	for _, mob in world.order do
		if not mob.removed then
			local body = mob.body
			local counted = true
			if x and y and z then
				local dx, dy, dz = body.x - x, body.y - y, body.z - z
				counted = dx * dx + dy * dy + dz * dz <= limit
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
		for _ = 1, settings.Attempts do
			if world.live >= world.options.maxMobs then
				return spawned
			end
			if hostileDue then
				local room = math.min(settings.HostileCap - localHostile, settings.MaxHostile - totalHostile)
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

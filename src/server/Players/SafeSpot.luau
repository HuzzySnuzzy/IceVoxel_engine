--!strict
--[[
	Finds a safe place to put a character near a target column (spawning, teleporting).

	Rules come from SpawnUnsafeBlocks. The search checks the target column first, then rings of
	columns further and further away, and within each column the highest safe spot that is not
	below the natural terrain surface. Uses the real world data (player builds included), and may
	generate chunks on the server while searching.

	Columns in chunks nobody edited are exactly what the generator made, so for those the scan
	starts just above the tallest structure and open water is skipped without loading the chunk.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Biomes = require(Shared.Biomes)
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local SpawnUnsafeBlocks = require(script.Parent.SpawnUnsafeBlocks)

type World = WorldServer.World

local HEIGHT = Config.WorldHeight
local SEA = Config.SeaLevel
local CHUNK = Config.ChunkSize
-- Generated structures (trees) never reach higher than this above the terrain surface.
local STRUCTURE_CLEARANCE = 20
local SIDES = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- Turns block / fluid group names into a set of block ids.
local function resolve(names: { string }): { [number]: boolean }
	local set: { [number]: boolean } = {}
	for _, name in names do
		local found = false
		for id, def in Blocks.defs do
			if def.name == name or (def.fluid and def.fluid.group == name) then
				set[id] = true
				found = true
			end
		end
		assert(found, `SpawnUnsafeBlocks: unknown block '{name}'`)
	end
	return set
end

local unsafeFloor = resolve(SpawnUnsafeBlocks.Floor)
local unsafeBody = resolve(SpawnUnsafeBlocks.Body)
local hazards = resolve(SpawnUnsafeBlocks.Hazards)
local headroom = SpawnUnsafeBlocks.Headroom
local water = resolve({ "Water" })

local SafeSpot = {}

-- Can a character stand with its feet in block (x, y, z)?
function SafeSpot.isSafe(world: World, x: number, y: number, z: number): boolean
	if y < 1 or y + headroom > HEIGHT then
		return false
	end
	local floor = world:getBlock(x, y - 1, z)
	if not Blocks.isSolid(floor) or unsafeFloor[floor] then
		return false
	end
	for dy = 0, headroom - 1 do
		local body = world:getBlock(x, y + dy, z)
		if Blocks.isSolid(body) or unsafeBody[body] then
			return false
		end
		for _, side in SIDES do
			if hazards[world:getBlock(x + side[1], y + dy, z + side[2])] then
				return false
			end
		end
	end
	for _, side in SIDES do
		if hazards[world:getBlock(x + side[1], y - 1, z + side[2])] then
			return false
		end
	end
	return true
end

-- Highest safe feet position in a column that is not below the natural surface, or nil.
function SafeSpot.column(world: World, x: number, z: number): number?
	local surface, biome = world.generator.column(x, z)
	-- (The world type's sea: a superflat world's water layers, none in a void.)
	local sea = world.generator.seaLevel or SEA
	local top
	if world:chunkEdits(x // CHUNK, z // CHUNK) then
		top = world:topBlock(x, z) + 1
	else
		if surface < sea and not Biomes.list[biome].frozen then
			return nil -- open water
		end
		top = math.min(math.max(surface, sea) + STRUCTURE_CLEARANCE, HEIGHT - headroom)
	end
	for y = top, math.max(surface, 1), -1 do
		if SafeSpot.isSafe(world, x, y, z) then
			return y
		end
	end
	return nil
end

--[[
	Where a character floats in open water in column (x, z): the feet in the top water block with
	only air above it (the eyes, 1.62 blocks up, are out of the water), or nil when the column's
	top isn't water. Not safe ground (SafeSpot.isSafe wants a floor), but a swimmer's place: for a
	teleport with no dry spot near (Players/TeleportCommand), better than the seabed.
]]
function SafeSpot.waterSurface(world: World, x: number, z: number): number?
	local y = world:topBlock(x, z)
	if y < 0 or not water[world:getBlock(x, y, z)] then
		return nil
	end
	return y
end

--[[
	Safe feet position (block coordinates) closest to column (x, z), searching up to `radius`
	blocks away (default SpawnUnsafeBlocks.SearchRadius). Returns nil if there is none.
]]
function SafeSpot.find(world: World, x: number, z: number, radius: number?): (number?, number, number)
	local maxRadius = radius or SpawnUnsafeBlocks.SearchRadius
	for ring = 0, maxRadius do
		-- Far rings are sampled every other block; spots are plentiful once we get there.
		local stride = if ring > 8 then 2 else 1
		for dz = -ring, ring, stride do
			for dx = -ring, ring, stride do
				if math.max(math.abs(dx), math.abs(dz)) == ring then
					local y = SafeSpot.column(world, x + dx, z + dz)
					if y then
						return x + dx, y, z + dz
					end
				end
			end
		end
	end
	return nil, 0, 0
end

return SafeSpot

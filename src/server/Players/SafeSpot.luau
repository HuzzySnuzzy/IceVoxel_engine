--!strict
--[[
	Finds a safe place to put a character near a target column (spawning, teleporting).

	Rules come from SpawnUnsafeBlocks. The search checks the target column first, then rings of
	columns further and further away, and within each column the highest safe spot that is not
	below the natural terrain surface. Uses the real world data (player builds included), and may
	generate chunks on the server while searching.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local SpawnUnsafeBlocks = require(script.Parent.SpawnUnsafeBlocks)

type World = WorldServer.World

local HEIGHT = Config.WorldHeight
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
	local surface = world.generator.column(x, z)
	for y = world:topBlock(x, z) + 1, math.max(surface, 1), -1 do
		if SafeSpot.isSafe(world, x, y, z) then
			return y
		end
	end
	return nil
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

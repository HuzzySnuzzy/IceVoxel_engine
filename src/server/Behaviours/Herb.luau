--!strict
--[[
	Herbs (BlockList: Mint, WildGinger; Tough As Nails' water and teas), plants that spread slowly
	the way Minecraft's MushroomBlock.randomTick spreads mushrooms:

	  Support  a plant like any other (Behaviours/Plant): it pops off with its herb item when its
	           soil goes.
	  Spread   on a random tick (World/RandomTicker), with chance Config.Server.HerbSpread (1/8;
	           Minecraft's mushrooms 1/25, as herbs are the player's crop here): unless MAX_NEARBY
	           (5) of the same herb already grow in the 9 x 3 x 9 blocks around it (itself
	           included), it walks up to four random steps of one block sideways and up to one up
	           or down (each step taken only onto air where the herb could stand), and grows a new
	           one at the last spot when that is air on its soil (Blocks.canSurvive: the dirt set).
	           Any one block gets a random tick about every 68 s, so a herb tries every 9 minutes
	           or so, and a lone plant becomes a small patch within an hour.
	Nothing needs light: there is no block light here, and herbs grow where their soil is (under
	trees, by water). A block in an unloaded chunk is no room to grow into.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)

local Plant = require(script.Parent.Plant)

local AIR, CAVE_AIR = Blocks.AIR, Blocks.CAVE_AIR

local Herb = {}

Herb.tickDelay = Plant.tickDelay
Herb.onTick = Plant.onTick
-- Most of one herb within 4 blocks sideways and 1 up or down before it stops spreading
-- (MushroomBlock's 5, itself included).
Herb.MAX_NEARBY = 5
-- Steps of the walk to the new spot (MushroomBlock's 4).
Herb.STEPS = 4

-- How many of `block` grow in the 9 x 3 x 9 blocks around (x, y, z), stopping at `most`.
local function nearby(world: any, block: number, x: number, y: number, z: number, most: number): number
	local found = 0
	for dy = -1, 1 do
		for dz = -4, 4 do
			for dx = -4, 4 do
				if world:peekBlock(x + dx, y + dy, z + dz) == block then
					found += 1
					if found >= most then
						return found
					end
				end
			end
		end
	end
	return found
end

-- Could the herb `block` grow at (x, y, z): air (not an unloaded block) over its soil, in the world?
local function room(world: any, block: number, x: number, y: number, z: number): boolean
	if y < 1 or y >= Config.WorldHeight then
		return false
	end
	local here = world:peekBlock(x, y, z)
	if here ~= AIR and here ~= CAVE_AIR then
		return false
	end
	return Blocks.canSurvive(block, function(bx: number, by: number, bz: number): number?
		return world:peekBlock(bx, by, bz)
	end, x, y, z)
end

-- One random step from (x, y, z): -1..1 sideways on each axis, -1..1 up (MushroomBlock's
-- nextInt(3) - 1 and nextInt(2) - nextInt(2)).
local function step(x: number, y: number, z: number, random: () -> number): (number, number, number)
	local dx = math.floor(random() * 3) - 1
	local dy = math.floor(random() * 2) - math.floor(random() * 2)
	local dz = math.floor(random() * 3) - 1
	return x + dx, y + dy, z + dz
end

--[[
	Spreads the herb `block` at (x, y, z) once, if it can (the roll aside): returns the spot it
	grew at, or nil when nothing grew (too many around, or no room at the walk's end).
]]
function Herb.spread(
	world: any,
	x: number,
	y: number,
	z: number,
	block: number,
	random: () -> number
): (number?, number?, number?)
	if nearby(world, block, x, y, z, Herb.MAX_NEARBY) >= Herb.MAX_NEARBY then
		return nil, nil, nil
	end
	local fromX, fromY, fromZ = x, y, z
	local toX, toY, toZ = step(fromX, fromY, fromZ, random)
	for _ = 1, Herb.STEPS do
		if room(world, block, toX, toY, toZ) then
			fromX, fromY, fromZ = toX, toY, toZ
		end
		toX, toY, toZ = step(fromX, fromY, fromZ, random)
	end
	if not room(world, block, toX, toY, toZ) then
		return nil, nil, nil
	end
	if not world:setBlock(toX, toY, toZ, block) then
		return nil, nil, nil
	end
	return toX, toY, toZ
end

function Herb.onRandomTick(
	world: any,
	_ticker: any,
	x: number,
	y: number,
	z: number,
	block: number,
	random: () -> number
)
	if random() >= Config.Server.HerbSpread then
		return
	end
	Herb.spread(world, x, y, z, block, random)
end

return Herb

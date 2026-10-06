--!strict
--[[
	Saplings (BlockList: OakSapling, BirchSapling, SpruceSapling, AcaciaSapling, JungleSapling),
	Minecraft's SaplingBlock:

	  Support  a plant like any other (Behaviours/Plant): it pops off with its drop when its soil
	           goes.
	  Growth   on a random tick (World/RandomTicker), under the open sky (World/Skylight, the
	           server's stand-in for Minecraft's light 9), with chance Config.Server.SaplingGrowth
	           (1/14: Minecraft's 1/7 for each of its two stages), it grows into its wood's tree:
	           the same builders as the world's trees (Generation/Structures/Trees), with a fresh
	           random size. The tree needs room: every block its trunk takes must be air, a plant
	           or leaves (the sapling itself too); if not, it waits for a later tick, as Minecraft's
	           does. Leaves only go where there is air.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Hash = require(Shared.Util.Hash)
local Trees = require(Shared.Generation.Structures.Trees)

local Plant = require(script.Parent.Plant)
local Skylight = require(script.Parent.Parent.World.Skylight)

local AIR, CAVE_AIR = Blocks.AIR, Blocks.CAVE_AIR

type Builder = (w: any, x: number, y: number, z: number, rng: Hash.Rng) -> ()

-- Each sapling's tree.
local BUILDERS: { [number]: Builder } = {
	[Blocks.id.OakSapling] = Trees.oak,
	[Blocks.id.BirchSapling] = Trees.birch,
	[Blocks.id.SpruceSapling] = Trees.spruce,
	[Blocks.id.AcaciaSapling] = Trees.acacia,
	[Blocks.id.JungleSapling] = Trees.jungle,
}

local Sapling = {}

Sapling.tickDelay = Plant.tickDelay
Sapling.onTick = Plant.onTick
Sapling.BUILDERS = BUILDERS

-- Can a trunk take this block (air, a plant, leaves)?
local function clear(block: number?): boolean
	if block == nil then
		return false
	end
	if block == AIR or block == CAVE_AIR then
		return true
	end
	local def = Blocks.get(block)
	return def.plant ~= nil or string.sub(def.name, -6) == "Leaves"
end

--[[
	Grows the sapling `block` at (x, y, z) into its tree now, with `seed` choosing its size.
	Returns whether it grew (false: no room, or not a sapling).
]]
function Sapling.grow(world: any, x: number, y: number, z: number, block: number, seed: number): boolean
	local builder = BUILDERS[block]
	if builder == nil then
		return false
	end
	-- Record the tree first, then place it only if its trunk has room.
	local forced: { { number } } = {}
	local placed: { { number } } = {}
	local top = y
	local writer = {
		set = function(bx: number, by: number, bz: number, id: number)
			table.insert(placed, { bx, by, bz, id })
			top = math.max(top, by + 1)
		end,
		force = function(bx: number, by: number, bz: number, id: number)
			table.insert(forced, { bx, by, bz, id })
			top = math.max(top, by + 1)
		end,
		get = function(bx: number, by: number, bz: number): number?
			return world:peekBlock(bx, by, bz)
		end,
		top = function(): number
			return top
		end,
	}
	builder(writer, x, y, z, Hash.rng(seed))
	for _, cell in forced do
		if
			not (cell[1] == x and cell[2] == y and cell[3] == z)
			and not clear(world:peekBlock(cell[1], cell[2], cell[3]))
		then
			return false
		end
	end
	for _, cell in forced do
		world:setBlock(cell[1], cell[2], cell[3], cell[4])
	end
	for _, cell in placed do
		local here = world:peekBlock(cell[1], cell[2], cell[3])
		if here == AIR or here == CAVE_AIR then
			world:setBlock(cell[1], cell[2], cell[3], cell[4])
		end
	end
	return true
end

function Sapling.onRandomTick(
	world: any,
	_ticker: any,
	x: number,
	y: number,
	z: number,
	block: number,
	random: () -> number
)
	if random() >= Config.Server.SaplingGrowth or Skylight.open(world, x, y + 1, z) ~= true then
		return
	end
	Sapling.grow(world, x, y, z, block, math.floor(random() * 2 ^ 31))
end

return Sapling

--!strict
--[[
	Saplings (the blocks with behaviour "Sapling": the Minecraft pack's oak, birch, spruce, acacia
	and jungle saplings), Minecraft's SaplingBlock:

	  Support  a plant like any other (Behaviours/Plant): it pops off with its drop when its soil
	           goes.
	  Growth   on a random tick (World/RandomTicker), under the open sky (World/Skylight, the
	           server's stand-in for Minecraft's light 9), with chance Config.Server.SaplingGrowth
	           (1/14: Minecraft's 1/7 for each of its two stages) times the season's growth
	           (server Seasons/SnowWorld.growth: Autumn 0.5, Winter 0, dormant, Spring 1.5,
	           Summer 1; 1 with the calendar off), it grows into its tree (its entry's `tree`):
	           the same builders as the world's trees (Generation/Structures' registry), with a
	           fresh random size. The tree needs room: every block its trunk takes must be air, a
	           plant or leaves (the packs' `leaves` tag; the sapling itself too); if not, it waits
	           for a later tick, as Minecraft's does. Leaves only go where there is air.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local BlockList = require(Shared.Blocks.BlockList)
local Config = require(Shared.Config)
local Content = require(Shared.Content)
local Hash = require(Shared.Util.Hash)
local Structures = require(Shared.Generation.Structures)

local Plant = require(script.Parent.Plant)
local Skylight = require(script.Parent.Parent.World.Skylight)
local SnowWorld = require(script.Parent.Parent.Seasons.SnowWorld)

local AIR, CAVE_AIR = Blocks.AIR, Blocks.CAVE_AIR

type Builder = (w: any, x: number, y: number, z: number, rng: Hash.Rng) -> ()

-- Each sapling's tree: its entry's `tree`, a builder of Generation/Structures' registry (which
-- checks the names as the game loads). A sapling growing none is an error, naming its pack.
local BUILDERS: { [number]: Builder } = {}
for id = 0, Blocks.count - 1 do
	local spec = BlockList[id + 1]
	if spec.tree then
		BUILDERS[id] = Structures.registry[spec.tree].build
	elseif spec.behaviour == "Sapling" then
		error(`Sapling: {Content.default.where("block", spec.name)} grows no tree (its \`tree\`)`, 0)
	end
end

local Sapling = {}

Sapling.tickDelay = Plant.tickDelay
Sapling.onTick = Plant.onTick
Sapling.BUILDERS = BUILDERS

-- The leaves a trunk may take the place of (the `leaves` tag).
local LEAVES = Blocks.tagged("leaves", "Behaviours/Sapling (what a trunk may replace)")

-- Can a trunk take this block (air, a plant, leaves)?
local function clear(block: number?): boolean
	if block == nil then
		return false
	end
	if block == AIR or block == CAVE_AIR then
		return true
	end
	return Blocks.get(block).plant ~= nil or LEAVES[block] == true
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
	if random() >= Config.Server.SaplingGrowth * SnowWorld.growth() or Skylight.open(world, x, y + 1, z) ~= true then
		return
	end
	Sapling.grow(world, x, y, z, block, math.floor(random() * 2 ^ 31))
end

return Sapling

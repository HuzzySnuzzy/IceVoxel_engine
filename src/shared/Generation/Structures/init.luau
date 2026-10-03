--!strict
--[[
	Structure placement.

	Placement is stateless: the world is divided into a grid of SPACING x SPACING cells and each cell
	holds at most one "spot" at a hashed position inside it. Whether a spot grows something depends
	only on the seed, the spot position and the terrain there, so any chunk can recompute every
	structure that reaches into it without talking to other chunks (or to other worker actors).

	To add a structure:
	  1. write a builder `(writer, x, y, z, rng) -> ()` (see Trees.luau),
	  2. register it in `Structures.registry` with the surface blocks it may grow on,
	  3. reference it by name from a biome's `features` list in Biomes/BiomeList.luau.

	Large structures (villages, dungeons...) can use the same idea with a bigger spacing: add another
	layer with its own SPACING / RADIUS and pick pieces from the spot's RNG.
]]

local Blocks = require(script.Parent.Parent.Blocks)
local Biomes = require(script.Parent.Parent.Biomes)
local Hash = require(script.Parent.Parent.Util.Hash)
local Trees = require(script.Trees)
local Writer = require(script.Writer)

type Writer = Writer.Writer
type Rng = Hash.Rng

export type Builder = (w: Writer, x: number, y: number, z: number, rng: Rng) -> ()
export type Structure = { build: Builder, soil: { [number]: boolean } }

-- (x, z) -> height, biome index, vegetation chance, surface block (see TerrainGenerator.column)
export type ColumnSampler = (x: number, z: number) -> (number, number, number, number)

local id = Blocks.id

local Structures = {}

-- Grid spacing of vegetation spots (blocks) and the furthest any vegetation reaches from its spot.
Structures.SPACING = 5
Structures.RADIUS = 5

local TREE_SOIL = { [id.Grass] = true, [id.DryGrass] = true, [id.Dirt] = true, [id.Snow] = true }

Structures.registry = {
	OakTree = { build = Trees.oak, soil = TREE_SOIL },
	BirchTree = { build = Trees.birch, soil = TREE_SOIL },
	SpruceTree = { build = Trees.spruce, soil = TREE_SOIL },
	AcaciaTree = { build = Trees.acacia, soil = TREE_SOIL },
	JungleTree = { build = Trees.jungle, soil = TREE_SOIL },
	Cactus = { build = Trees.cactus, soil = { [id.Sand] = true } },
} :: { [string]: Structure }

-- Fail early on typos in BiomeList, and find the highest vegetation chance for early rejection.
local maxVegetation = 0
for _, biome in Biomes.list do
	maxVegetation = math.max(maxVegetation, biome.vegetation)
	for _, feature in biome.features do
		assert(Structures.registry[feature.structure], `Biome {biome.name} uses unknown structure {feature.structure}`)
	end
end

local function pickFeature(biomeIndex: number, rng: Rng): Structure?
	local biome = Biomes.list[biomeIndex]
	if biome.featureWeight <= 0 then
		return nil
	end
	local roll = rng:float() * biome.featureWeight
	for _, feature in biome.features do
		roll -= feature.weight
		if roll < 0 then
			return Structures.registry[feature.structure]
		end
	end
	return Structures.registry[biome.features[#biome.features].structure]
end

--[[
	Runs every vegetation spot whose structure could reach the block rectangle
	[minX, maxX] x [minZ, maxZ] (inclusive).
]]
function Structures.populate(
	seed: number,
	column: ColumnSampler,
	w: Writer,
	minX: number,
	minZ: number,
	maxX: number,
	maxZ: number
)
	local spacing = Structures.SPACING
	local radius = Structures.RADIUS
	local salt = Hash.hash2(seed, 0x7EE5, 0x5EED)

	for gz = (minZ - radius) // spacing, (maxZ + radius) // spacing do
		for gx = (minX - radius) // spacing, (maxX + radius) // spacing do
			local h = Hash.hash2(salt, gx, gz)
			local x = gx * spacing + h % (spacing - 1)
			local z = gz * spacing + (h // 8) % (spacing - 1)
			if x >= minX - radius and x <= maxX + radius and z >= minZ - radius and z <= maxZ + radius then
				local roll = (h // 65536) / 65536
				-- Sampling the terrain is the expensive part; most spots can be rejected without it.
				local height, biome, vegetation, surface
				if roll < maxVegetation then
					height, biome, vegetation, surface = column(x, z)
				end
				if vegetation and roll < vegetation then
					local rng = Hash.rng(h)
					local structure = pickFeature(biome, rng)
					if structure and structure.soil[surface] then
						structure.build(w, x, height, z, rng)
					end
				end
			end
		end
	end
end

return Structures

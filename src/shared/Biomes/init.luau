--!strict
--[[
	Biome registry: resolves the block names in BiomeList to ids and exposes flat arrays that the
	terrain generator reads in its inner loops.
]]

local Blocks = require(script.Parent.Blocks)
local BiomeList = require(script.BiomeList)

export type Feature = { structure: string, weight: number }

export type Biome = {
	index: number,
	name: string,
	-- Band indices (see Biomes.bands).
	bands: { number },
	temperature: number,
	humidity: number,
	vegetation: number,
	top: number,
	filler: number,
	fillerDepth: number,
	-- Patch block and cover (0 = none).
	patch: number,
	patchCover: number,
	steep: number,
	-- nil: the generator's default.
	steepSlope: number?,
	underwater: number,
	beach: number,
	frozen: boolean,
	features: { Feature },
	featureWeight: number,
}

export type Band = BiomeList.Band

local Biomes = {}

local bands = BiomeList.bands
local bandIndex: { [string]: number } = {}
for i, band in bands do
	bandIndex[band.name] = i
end

local function block(name: string): number
	local id = Blocks.id[name]
	assert(id, `BiomeList uses unknown block {name}`)
	return id
end

local list: { Biome } = {}
local byName: { [string]: Biome } = {}
-- Biome indices of every band.
local inBand: { { number } } = {}
for i in bands do
	inBand[i] = {}
end

for index, spec in BiomeList.list do
	local features: { Feature } = {}
	local total = 0
	for _, entry in spec.features do
		local feature = { structure = entry[1] :: string, weight = entry[2] :: number }
		total += feature.weight
		table.insert(features, feature)
	end

	local biomeBands = {}
	for _, name in spec.bands do
		local b = bandIndex[name]
		assert(b, `Biome {spec.name} uses unknown band {name}`)
		table.insert(biomeBands, b)
		table.insert(inBand[b], index)
	end

	local patches = spec.patches
	local biome: Biome = {
		index = index,
		name = spec.name,
		bands = biomeBands,
		temperature = spec.temperature,
		humidity = spec.humidity,
		vegetation = spec.vegetation,
		top = block(spec.top),
		filler = block(spec.filler),
		fillerDepth = spec.fillerDepth,
		patch = if patches then block(patches.block) else 0,
		patchCover = if patches then patches.cover else 0,
		steep = block(spec.steep or "Stone"),
		steepSlope = spec.steepSlope,
		underwater = block(spec.underwater),
		beach = block(spec.beach),
		frozen = spec.frozen == true,
		features = features,
		featureWeight = total,
	}
	table.insert(list, biome)
	byName[spec.name] = biome
end

for i, band in bands do
	assert(#inBand[i] > 0, `No biome in band {band.name}`)
end

Biomes.list = list
Biomes.count = #list
Biomes.bands = bands
-- `Biomes.inBand[band]` lists the indices of the biomes of that band.
Biomes.inBand = inBand

function Biomes.get(index: number): Biome
	return list[index]
end

function Biomes.byName(name: string): Biome?
	return byName[name]
end

-- Band index of a terrain height (blocks).
function Biomes.bandAt(height: number): number
	local band = 1
	for i = 2, #bands do
		if height >= bands[i].from then
			band = i
		else
			break
		end
	end
	return band
end

return Biomes

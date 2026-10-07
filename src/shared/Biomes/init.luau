--!strict
--[[
	Biome registry: resolves the block names in BiomeList to ids and exposes flat arrays that the
	terrain generator reads in its inner loops. A biome's `foliage` (Generation/Foliage) becomes
	weighted block id lists; its plants must be single plants or lower halves of tall ones.
]]

local Blocks = require(script.Parent.Blocks)
local BiomeList = require(script.BiomeList)

export type Feature = { structure: string, weight: number }

-- A weighted list of plant blocks (single plants or lower halves) and its total weight.
export type PlantList = { blocks: { number }, weights: { number }, total: number }

-- Ground plants (BiomeList `foliage`): average chance per soil column and share of the ground in
-- patches, for grass-like plants, for flowers (`flowers` nil: none) and for herbs (`herbs` nil:
-- none).
export type Foliage = {
	density: number,
	cover: number,
	plants: PlantList,
	flowerChance: number,
	flowerCover: number,
	flowers: PlantList?,
	herbChance: number,
	herbCover: number,
	herbs: PlantList?,
}

export type Biome = {
	index: number,
	name: string,
	-- Band indices (see Biomes.bands).
	bands: { number },
	temperature: number,
	humidity: number,
	-- Minecraft's biome temperature and has_precipitation (BiomeList `weather`; Shared/Weather).
	weatherTemperature: number,
	precipitation: boolean,
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
	foliage: Foliage?,
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

-- A { { blockName, weight } } list of plants to grow (see BiomeList `foliage`).
local function plantList(biome: string, entries: { { any } }): PlantList
	local out: PlantList = { blocks = {}, weights = {}, total = 0 }
	for _, entry in entries do
		local id = block(entry[1] :: string)
		local weight = entry[2] :: number
		assert(
			Blocks.isPlant(id) and Blocks.plantBottom(id) == nil,
			`Biome {biome} grows {entry[1]}, which is no plant (or the upper half of one)`
		)
		assert(weight > 0, `Biome {biome} gives {entry[1]} no weight`)
		table.insert(out.blocks, id)
		table.insert(out.weights, weight)
		out.total += weight
	end
	assert(#out.blocks > 0, `Biome {biome} has an empty plant list`)
	return out
end

local function share(biome: string, what: string, value: number): number
	assert(value >= 0 and value <= 1, `Biome {biome} has a bad foliage {what} {value}`)
	return value
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
	local foliage: Foliage? = nil
	local foliageSpec = spec.foliage
	if foliageSpec then
		local flowers = foliageSpec.flowers
		local herbs = foliageSpec.herbs
		foliage = {
			density = share(spec.name, "density", foliageSpec.density),
			cover = share(spec.name, "cover", foliageSpec.cover or 0.5),
			plants = plantList(spec.name, foliageSpec.plants),
			flowerChance = if flowers then share(spec.name, "flower chance", flowers.chance) else 0,
			flowerCover = if flowers then share(spec.name, "flower cover", flowers.cover or 0.3) else 0.3,
			flowers = if flowers then plantList(spec.name, flowers.species) else nil,
			herbChance = if herbs then share(spec.name, "herb chance", herbs.chance) else 0,
			herbCover = if herbs then share(spec.name, "herb cover", herbs.cover or 0.04) else 0.04,
			herbs = if herbs then plantList(spec.name, herbs.species) else nil,
		}
	end
	local weather = spec.weather
	local biome: Biome = {
		index = index,
		name = spec.name,
		bands = biomeBands,
		temperature = spec.temperature,
		humidity = spec.humidity,
		weatherTemperature = if weather then weather.temperature elseif spec.frozen then 0 else 0.8,
		precipitation = weather == nil or weather.precipitation ~= false,
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
		foliage = foliage,
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

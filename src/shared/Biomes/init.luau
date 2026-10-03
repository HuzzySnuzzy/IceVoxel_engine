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
	temperature: number,
	humidity: number,
	heightOffset: number,
	hilliness: number,
	vegetation: number,
	top: number,
	filler: number,
	fillerDepth: number,
	underwater: number,
	beach: number,
	frozen: boolean,
	features: { Feature },
	featureWeight: number,
}

local Biomes = {}

local list: { Biome } = {}
local byName: { [string]: Biome } = {}

for index, spec in BiomeList do
	local features: { Feature } = {}
	local total = 0
	for _, entry in spec.features do
		local feature = { structure = entry[1] :: string, weight = entry[2] :: number }
		total += feature.weight
		table.insert(features, feature)
	end

	local biome: Biome = {
		index = index,
		name = spec.name,
		temperature = spec.temperature,
		humidity = spec.humidity,
		heightOffset = spec.heightOffset,
		hilliness = spec.hilliness,
		vegetation = spec.vegetation,
		top = Blocks.id[spec.top],
		filler = Blocks.id[spec.filler],
		fillerDepth = spec.fillerDepth,
		underwater = Blocks.id[spec.underwater],
		beach = Blocks.id[spec.beach],
		frozen = spec.frozen == true,
		features = features,
		featureWeight = total,
	}
	table.insert(list, biome)
	byName[spec.name] = biome
end

Biomes.list = list
Biomes.count = #list

function Biomes.get(index: number): Biome
	return list[index]
end

function Biomes.byName(name: string): Biome?
	return byName[name]
end

return Biomes

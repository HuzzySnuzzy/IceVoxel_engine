--!strict
--[[
	Biome registry: the content packs' biomes (Shared/Content's `biomes`; Content/Schema's
	BIOME_FIELDS says what each field does) with their block names resolved to ids, as flat records
	the terrain generator reads in its inner loops. A biome's `foliage` (Generation/Foliage) becomes
	weighted block id lists. A biome's index is its place among every pack's biomes (the Minecraft
	pack's in their order, then any later pack's), the same on every machine; it lives in memory
	only (saves, Single Biome and /locate name biomes), but the generator's per-biome arrays and
	climate picks go by it: a pack loading after the Minecraft pack adds its biomes after the
	vanilla ones, which keep their places.

	Biomes are picked by altitude first, as in JJThunder To The Max: the terrain's height (before
	rivers are dug, so a river bed belongs to its banks) falls into one of the BANDS below, and the
	biome is the one of that band closest to the column's climate (temperature, humidity, both
	roughly in [-1, 1]). Band borders and climate borders are dithered a little so they look natural.
	Islands in the middle of some seas are mushroom fields instead (see TerrainGenerator).

	The bands are the generator's rules, not a pack's data: each is a slice of the terrain's
	height (the datapack's biome altitudes put through Generation/Relief's scaling), so they move
	with the relief and not with any biome, and between them they cover every height, so a pack
	adding or moving one would re-slice where every other pack's biomes grow. A biome names the
	bands it appears in (`bands`), checked here as the packs load, and every band needs a biome.

	  list, count, get(index), byName(name)   the biomes, by index or by name
	  need(name, who)    the biome named `name`, which `who` needs (TerrainGenerator's mushroom
	                     fields, the Plains of the void, Single Biome and the debug worlds): an
	                     error naming both as the game loads when no pack makes it
	  where(name)        where a biome came from ("pack Minecraft (patched by Survival), biome
	                     Taiga"), for messages
	  bands, inBand, bandAt(height)   the altitude bands, the biomes of each, a height's band
]]

local Blocks = require(script.Parent.Blocks)
local Content = require(script.Parent.Content)
local Schema = require(script.Parent.Content.Schema)

export type Feature = { structure: string, weight: number }

-- A weighted list of plant blocks (single plants or lower halves) and its total weight.
export type PlantList = { blocks: { number }, weights: { number }, total: number }

-- Ground plants (a biome's `foliage`): average chance per soil column and share of the ground in
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
	-- Minecraft's biome temperature and has_precipitation (its `weather`; Shared/Weather).
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
	-- Minecraft's biome tags it is in ("is_forest"; Generation/Locate).
	tags: { string },
	-- How the seasons treat it (Seasons/SeasonClimate's class: its `seasonClass`, else
	-- "temperate").
	seasonClass: string,
	-- Its own chances of an oil well and a puddle and its lakes' weight (nil: Config's, see
	-- Generation/OilWells and Generation/Lakes).
	oilWells: number?,
	lakes: number?,
	puddles: number?,
}

export type Band = { name: string, from: number }

local Biomes = {}

local content = Content.default

local function fail(text: string): never
	error(`Biomes: {text}`, 0)
end

--[[
	Altitude bands, by the lowest height (blocks) each starts at. These are the datapack's biome
	altitudes scaled like the terrain (Generation/Relief): 64 + 0.43 (y - 63).
]]
local bands: { Band } = {
	{ name = "Lowland", from = -math.huge },
	{ name = "Forest", from = 190 },
	{ name = "Highland", from = 312 },
	{ name = "Meadow", from = 467 },
	{ name = "Alpine", from = 553 },
	{ name = "Slopes", from = 639 },
	{ name = "Peaks", from = 725 },
}
local bandIndex: { [string]: number } = {}
for i, band in bands do
	bandIndex[band.name] = i
end

-- (Content checked every block a biome names, and that its plants are plants.)
local function block(name: string): number
	return Blocks.id[name]
end

-- A { { blockName, weight } } list of plants to grow (a biome's `foliage`).
local function plantList(entries: { Schema.Weighted }): PlantList
	local out: PlantList = { blocks = {}, weights = {}, total = 0 }
	for _, entry in entries do
		local weight = entry[2] :: number
		table.insert(out.blocks, block(entry[1] :: string))
		table.insert(out.weights, weight)
		out.total += weight
	end
	return out
end

local list: { Biome } = {}
local byName: { [string]: Biome } = {}
-- Biome indices of every band.
local inBand: { { number } } = {}
for i in bands do
	inBand[i] = {}
end

for index, spec in content.biomes do
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
		if b == nil then
			local near = Schema.suggest(name, bandIndex)
			fail(
				`{content.where("biome", spec.name)}: bands names unknown band {name}{if near
					then ` (did you mean {near}?)`
					else ""}`
			)
		end
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
			density = foliageSpec.density,
			cover = foliageSpec.cover or 0.5,
			plants = plantList(foliageSpec.plants),
			flowerChance = if flowers then flowers.chance else 0,
			flowerCover = if flowers then flowers.cover or 0.3 else 0.3,
			flowers = if flowers then plantList(flowers.species) else nil,
			herbChance = if herbs then herbs.chance else 0,
			herbCover = if herbs then herbs.cover or 0.04 else 0.04,
			herbs = if herbs then plantList(herbs.species) else nil,
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
		tags = spec.tags or {},
		seasonClass = spec.seasonClass or "temperate",
		oilWells = spec.oilWells,
		lakes = spec.lakes,
		puddles = spec.puddles,
	}
	table.insert(list, biome)
	byName[spec.name] = biome
end

for i, band in bands do
	if #inBand[i] == 0 then
		fail(`no biome is in band {band.name} (every band needs one: a biome's \`bands\`)`)
	end
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

--[[
	The biome named `name`, which `who` needs ("TerrainGenerator (its mushroom islands)"): for code
	that looks a biome up as it loads, so a pack without it fails there, naming both, instead of a
	nil index later.
]]
function Biomes.need(name: string, who: string): Biome
	local biome = byName[name]
	if biome == nil then
		local near = Schema.suggest(name, byName)
		fail(`{who} needs a biome named {name}, which no pack makes{if near then ` (did you mean {near}?)` else ""}`)
	end
	return biome :: Biome
end

-- Where biome `name` came from: "pack Minecraft (patched by Survival), biome Taiga".
function Biomes.where(name: string): string
	return content.where("biome", name)
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

--!strict
--[[
	Biome definitions.

	Biomes are picked by altitude first, as in JJThunder To The Max: the terrain's height (before
	rivers are dug, so a river bed belongs to its banks) falls into one of the BANDS below, and the
	biome is the one of that band closest to the column's climate (temperature, humidity, both
	roughly in [-1, 1]). Band borders and climate borders are dithered a little so they look natural.
	Islands in the middle of some seas are mushroom fields instead (see TerrainGenerator).

	  bands          Altitude bands the biome appears in (names from BANDS).
	  temperature, humidity
	                 Its place in climate space.
	  vegetation     Chance (0-1) that a vegetation spot (one per 5x5 blocks) grows something.
	  top / filler / fillerDepth
	                 Surface block, blocks below it and how deep they go.
	  patches        Optional { block =, cover = }: `cover` (0-1) of the surface is `block` instead of
	                 `top`, in blotches a few blocks wide (stone in windswept hills...).
	  steep          Optional block for slopes steeper than `steepSlope` (blocks per block;
	                 default Stone and TerrainGenerator's CLIFF_SLOPE).
	  underwater     Surface block below sea level.
	  beach          Surface block just above sea level, on coasts and river banks.
	  frozen         Water freezes to ice at the surface.
	  features       { { structureName, weight } } picked when vegetation succeeds.
	  foliage        Optional ground plants (Generation/Foliage; full detail chunks only), Minecraft's
	                 vegetal decoration. A column grows at most one plant, on its surface block, when
	                 that block is in the plant's soil set and the block above is air:
	                   density   Share (0-1) of the biome's soil columns growing a plant, on average.
	                             They grow in patches: `cover` (0-1, default 0.5) of the ground is
	                             patches, where the chance is about density / cover, and the rest is
	                             clearings (a low-frequency noise, like Minecraft's random patches).
	                   plants    { { blockName, weight } }: what grows. A two block tall plant
	                             without air above its top falls back to its single form (tall
	                             grass to short grass, a large fern to a fern) or to nothing.
	                   flowers   Optional { chance =, cover =, species = { { blockName, weight } } }:
	                             flowers in their own patches (`chance` and `cover` as density and
	                             cover above, cover default 0.3). The species follows another
	                             low-frequency noise, so a patch is one or two species.
	                 Every box of a plant is a Part: tests/spec/FoliageGeneration keeps the Parts per
	                 soil column within budget (0.6 in jungles and meadows, 0.45 on plains and
	                 savannas, 0.35 elsewhere).
]]

export type BiomeSpec = {
	name: string,
	bands: { string },
	temperature: number,
	humidity: number,
	vegetation: number,
	top: string,
	filler: string,
	fillerDepth: number,
	patches: { block: string, cover: number }?,
	steep: string?,
	steepSlope: number?,
	underwater: string,
	beach: string,
	frozen: boolean?,
	features: { { any } },
	foliage: FoliageSpec?,
}

-- Ground plants (see the header): { blockName, weight } lists.
export type FoliageSpec = {
	density: number,
	cover: number?,
	plants: { { any } },
	flowers: { chance: number, cover: number?, species: { { any } } }?,
}

export type Band = { name: string, from: number }

--[[
	Altitude bands, by the lowest height (blocks) each starts at. These are the datapack's biome
	altitudes scaled like the terrain (Generation/Relief): 64 + 0.43 (y - 63).
]]
local BANDS: { Band } = {
	{ name = "Lowland", from = -math.huge },
	{ name = "Forest", from = 190 },
	{ name = "Highland", from = 312 },
	{ name = "Meadow", from = 467 },
	{ name = "Alpine", from = 553 },
	{ name = "Slopes", from = 639 },
	{ name = "Peaks", from = 725 },
}

-- Forest flowers (Minecraft's forest: dandelions and poppies, lilies of the valley and the tall
-- forest flowers).
local FOREST_FLOWERS: { { any } } = {
	{ "Dandelion", 2 },
	{ "Poppy", 2 },
	{ "LilyOfTheValley", 1 },
	{ "Lilac", 1 },
	{ "RoseBush", 1 },
	{ "Peony", 1 },
}

local list: { BiomeSpec } = {
	{
		name = "Tundra",
		bands = { "Lowland", "Forest" },
		temperature = -0.75,
		humidity = 0,
		vegetation = 0.025,
		top = "Snow",
		filler = "Dirt",
		fillerDepth = 3,
		underwater = "Gravel",
		beach = "Gravel",
		frozen = true,
		features = { { "SpruceTree", 1 } },
	},
	{
		name = "Taiga",
		bands = { "Lowland", "Forest", "Highland" },
		temperature = -0.35,
		humidity = 0.3,
		vegetation = 0.32,
		top = "Grass",
		filler = "Dirt",
		fillerDepth = 3,
		underwater = "Gravel",
		beach = "Gravel",
		features = { { "SpruceTree", 1 } },
		-- Minecraft's taiga: ferns over grass, large ferns, rare mushrooms, a rare dandelion or poppy.
		foliage = {
			density = 0.085,
			cover = 0.55,
			plants = {
				{ "Fern", 4 },
				{ "ShortGrass", 2 },
				{ "LargeFern", 1 },
				{ "BrownMushroom", 0.12 },
				{ "RedMushroom", 0.06 },
			},
			flowers = { chance = 0.002, species = { { "Dandelion", 1 }, { "Poppy", 1 } } },
		},
	},
	{
		name = "Plains",
		bands = { "Lowland" },
		temperature = 0.1,
		humidity = -0.25,
		vegetation = 0.012,
		top = "Grass",
		filler = "Dirt",
		fillerDepth = 3,
		underwater = "Sand",
		beach = "Sand",
		features = { { "OakTree", 1 } },
		-- Lots of short grass and some tall grass; plains flowers, tulips side by side, a rare
		-- patch of sunflowers.
		foliage = {
			density = 0.09,
			cover = 0.6,
			plants = { { "ShortGrass", 7 }, { "TallGrass", 2 } },
			flowers = {
				chance = 0.012,
				species = {
					{ "Dandelion", 3 },
					{ "Poppy", 2 },
					{ "AzureBluet", 2 },
					{ "OxeyeDaisy", 2 },
					{ "Cornflower", 2 },
					{ "RedTulip", 1 },
					{ "OrangeTulip", 1 },
					{ "WhiteTulip", 1 },
					{ "PinkTulip", 1 },
					{ "Sunflower", 0.4 },
				},
			},
		},
	},
	{
		name = "Forest",
		bands = { "Lowland", "Forest", "Highland" },
		temperature = 0.1,
		humidity = 0.3,
		vegetation = 0.45,
		top = "Grass",
		filler = "Dirt",
		fillerDepth = 3,
		underwater = "Dirt",
		beach = "Sand",
		features = { { "OakTree", 3 }, { "BirchTree", 1 } },
		-- Some grass; dandelions, poppies, lilies of the valley and the tall forest flowers.
		foliage = {
			density = 0.07,
			plants = { { "ShortGrass", 1 } },
			flowers = { chance = 0.014, species = FOREST_FLOWERS },
		},
	},
	{
		name = "BirchForest",
		bands = { "Forest" },
		temperature = -0.1,
		humidity = 0.65,
		vegetation = 0.4,
		top = "Grass",
		filler = "Dirt",
		fillerDepth = 3,
		underwater = "Dirt",
		beach = "Sand",
		features = { { "BirchTree", 1 } },
		foliage = {
			density = 0.07,
			plants = { { "ShortGrass", 1 } },
			flowers = { chance = 0.014, species = FOREST_FLOWERS },
		},
	},
	{
		name = "Savanna",
		bands = { "Lowland", "Forest" },
		temperature = 0.5,
		humidity = -0.3,
		vegetation = 0.05,
		top = "DryGrass",
		filler = "Dirt",
		fillerDepth = 3,
		underwater = "Sand",
		beach = "Sand",
		features = { { "AcaciaTree", 1 } },
		-- Lots of grass and tall grass (tinted dry by DryGrass), a rare dandelion or poppy.
		foliage = {
			density = 0.095,
			cover = 0.65,
			plants = { { "ShortGrass", 3 }, { "TallGrass", 1 } },
			flowers = { chance = 0.004, species = { { "Dandelion", 1 }, { "Poppy", 1 } } },
		},
	},
	{
		name = "Desert",
		bands = { "Lowland" },
		temperature = 0.8,
		humidity = -0.7,
		vegetation = 0.03,
		top = "Sand",
		filler = "Sandstone",
		fillerDepth = 5,
		underwater = "Sand",
		beach = "Sand",
		features = { { "Cactus", 1 } },
		-- Sparse dead bushes.
		foliage = { density = 0.015, cover = 0.8, plants = { { "DeadBush", 1 } } },
	},
	{
		name = "Jungle",
		bands = { "Lowland", "Forest", "Highland" },
		temperature = 0.65,
		humidity = 0.55,
		vegetation = 0.55,
		top = "Grass",
		filler = "Dirt",
		fillerDepth = 3,
		underwater = "Dirt",
		beach = "Sand",
		features = { { "JungleTree", 2 }, { "OakTree", 1 } },
		-- Dense grass and ferns, some tall grass and large ferns. Blue orchids grow in swamps in
		-- Minecraft; there are none here, so they share the jungle's flowers.
		foliage = {
			density = 0.13,
			cover = 0.8,
			plants = { { "ShortGrass", 6 }, { "Fern", 3 }, { "TallGrass", 1 }, { "LargeFern", 1 } },
			flowers = { chance = 0.008, species = { { "Dandelion", 2 }, { "Poppy", 2 }, { "BlueOrchid", 1 } } },
		},
	},
	{
		name = "WindsweptHills",
		bands = { "Highland" },
		temperature = -0.15,
		humidity = -0.35,
		vegetation = 0.04,
		top = "Grass",
		filler = "Dirt",
		fillerDepth = 2,
		patches = { block = "Stone", cover = 0.3 },
		underwater = "Gravel",
		beach = "Gravel",
		features = { { "SpruceTree", 2 }, { "OakTree", 1 } },
		foliage = {
			density = 0.06,
			plants = { { "ShortGrass", 1 } },
			flowers = { chance = 0.002, species = { { "Dandelion", 1 }, { "Poppy", 1 } } },
		},
	},
	{
		name = "OldGrowthTaiga",
		bands = { "Highland", "Meadow" },
		temperature = -0.45,
		humidity = 0.45,
		vegetation = 0.42,
		top = "Podzol",
		filler = "Dirt",
		fillerDepth = 3,
		patches = { block = "CoarseDirt", cover = 0.25 },
		underwater = "Gravel",
		beach = "Gravel",
		features = { { "SpruceTree", 1 } },
		-- Ferns and large ferns on podzol, some dead bushes, more mushrooms.
		foliage = {
			density = 0.075,
			cover = 0.55,
			plants = {
				{ "Fern", 4 },
				{ "LargeFern", 2 },
				{ "ShortGrass", 1 },
				{ "DeadBush", 0.4 },
				{ "BrownMushroom", 0.5 },
				{ "RedMushroom", 0.3 },
			},
		},
	},
	{
		name = "WindsweptSavanna",
		bands = { "Highland" },
		temperature = 0.65,
		humidity = -0.5,
		vegetation = 0.03,
		top = "DryGrass",
		filler = "Dirt",
		fillerDepth = 2,
		patches = { block = "CoarseDirt", cover = 0.3 },
		underwater = "Sand",
		beach = "Sand",
		features = { { "AcaciaTree", 1 } },
		foliage = {
			density = 0.075,
			cover = 0.6,
			plants = { { "ShortGrass", 3 }, { "TallGrass", 1 } },
			flowers = { chance = 0.004, species = { { "Dandelion", 1 }, { "Poppy", 1 } } },
		},
	},
	{
		name = "Meadow",
		bands = { "Meadow" },
		temperature = 0.15,
		humidity = 0,
		vegetation = 0.012,
		top = "Grass",
		filler = "Dirt",
		fillerDepth = 3,
		underwater = "Gravel",
		beach = "Gravel",
		features = { { "BirchTree", 1 }, { "OakTree", 1 } },
		-- Dense grass and tall grass, and many flowers.
		foliage = {
			density = 0.09,
			cover = 0.75,
			plants = { { "ShortGrass", 3 }, { "TallGrass", 2 } },
			flowers = {
				chance = 0.03,
				cover = 0.5,
				species = {
					{ "Allium", 1 },
					{ "AzureBluet", 1 },
					{ "Dandelion", 1 },
					{ "Cornflower", 1 },
					{ "OxeyeDaisy", 1 },
					{ "Poppy", 1 },
				},
			},
		},
	},
	{
		name = "Grove",
		bands = { "Alpine" },
		temperature = -0.3,
		humidity = 0.2,
		vegetation = 0.2,
		top = "Snow",
		filler = "Dirt",
		fillerDepth = 3,
		underwater = "Gravel",
		beach = "Gravel",
		frozen = true,
		features = { { "SpruceTree", 1 } },
	},
	{
		name = "StonyPeaks",
		bands = { "Alpine" },
		temperature = 0.45,
		humidity = 0,
		vegetation = 0,
		top = "Stone",
		filler = "Stone",
		fillerDepth = 3,
		patches = { block = "Calcite", cover = 0.25 },
		underwater = "Gravel",
		beach = "Gravel",
		features = {},
	},
	{
		name = "SnowySlopes",
		bands = { "Slopes" },
		temperature = 0,
		humidity = 0,
		vegetation = 0,
		top = "Snow",
		filler = "Snow",
		fillerDepth = 2,
		steepSlope = 1.1,
		underwater = "Gravel",
		beach = "Gravel",
		frozen = true,
		features = {},
	},
	{
		name = "JaggedPeaks",
		bands = { "Peaks" },
		temperature = 0.2,
		humidity = 0,
		vegetation = 0,
		top = "Snow",
		filler = "Snow",
		fillerDepth = 2,
		steepSlope = 1.1,
		underwater = "Gravel",
		beach = "Gravel",
		frozen = true,
		features = {},
	},
	{
		name = "FrozenPeaks",
		bands = { "Peaks" },
		temperature = -0.4,
		humidity = 0,
		vegetation = 0,
		top = "Snow",
		filler = "Snow",
		fillerDepth = 2,
		patches = { block = "PackedIce", cover = 0.35 },
		steep = "PackedIce",
		steepSlope = 1.1,
		underwater = "Gravel",
		beach = "Gravel",
		frozen = true,
		features = {},
	},
	{
		-- Islands far out in some seas (TerrainGenerator picks it; it belongs to no band).
		name = "MushroomFields",
		bands = {},
		temperature = 0.3,
		humidity = 0.6,
		vegetation = 0,
		top = "Mycelium",
		filler = "Dirt",
		fillerDepth = 3,
		underwater = "Sand",
		beach = "Mycelium",
		features = {},
		foliage = {
			density = 0.045,
			plants = { { "BrownMushroom", 1 }, { "RedMushroom", 1 } },
		},
	},
}

return {
	bands = BANDS,
	list = list,
}

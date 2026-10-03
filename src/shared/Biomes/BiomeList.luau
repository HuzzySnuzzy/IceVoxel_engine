--!strict
--[[
	Biome definitions.

	Biomes live in a 2D climate space (temperature, humidity), both roughly in [-1, 1]. Every column
	samples the climate noise and weighs every biome by its distance in that space, so biome terrain
	properties blend smoothly into each other instead of producing walls at borders.

	Blended (weighted average of nearby biomes):
	  heightOffset   Blocks added to the base terrain height on land.
	  hilliness      Amplitude (blocks) of the rolling hills noise on land.
	  vegetation     Chance (0-1) that a vegetation spot (one per 5x5 blocks) grows something.

	Taken from the dominant biome only (with a little noise on the border so it looks natural):
	  top / filler / fillerDepth   Surface block, blocks below it and how deep they go.
	  underwater                   Surface block below sea level.
	  beach                        Surface block near sea level on coasts.
	  frozen                       Sea surface freezes to ice.
	  features                     { { structureName, weight } } picked when vegetation succeeds.
]]

export type BiomeSpec = {
	name: string,
	temperature: number,
	humidity: number,
	heightOffset: number,
	hilliness: number,
	vegetation: number,
	top: string,
	filler: string,
	fillerDepth: number,
	underwater: string,
	beach: string,
	frozen: boolean?,
	features: { { any } },
}

local list: { BiomeSpec } = {
	{
		name = "Tundra",
		temperature = -0.75,
		humidity = 0,
		heightOffset = 3,
		hilliness = 7,
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
		temperature = -0.35,
		humidity = 0.3,
		heightOffset = 8,
		hilliness = 16,
		vegetation = 0.32,
		top = "Grass",
		filler = "Dirt",
		fillerDepth = 3,
		underwater = "Gravel",
		beach = "Gravel",
		features = { { "SpruceTree", 1 } },
	},
	{
		name = "Plains",
		temperature = 0.1,
		humidity = -0.25,
		heightOffset = 3,
		hilliness = 6,
		vegetation = 0.012,
		top = "Grass",
		filler = "Dirt",
		fillerDepth = 3,
		underwater = "Sand",
		beach = "Sand",
		features = { { "OakTree", 1 } },
	},
	{
		name = "Forest",
		temperature = 0.1,
		humidity = 0.3,
		heightOffset = 6,
		hilliness = 12,
		vegetation = 0.45,
		top = "Grass",
		filler = "Dirt",
		fillerDepth = 3,
		underwater = "Dirt",
		beach = "Sand",
		features = { { "OakTree", 3 }, { "BirchTree", 1 } },
	},
	{
		name = "BirchForest",
		temperature = -0.1,
		humidity = 0.65,
		heightOffset = 6,
		hilliness = 10,
		vegetation = 0.4,
		top = "Grass",
		filler = "Dirt",
		fillerDepth = 3,
		underwater = "Dirt",
		beach = "Sand",
		features = { { "BirchTree", 1 } },
	},
	{
		name = "Savanna",
		temperature = 0.5,
		humidity = -0.3,
		heightOffset = 5,
		hilliness = 8,
		vegetation = 0.05,
		top = "DryGrass",
		filler = "Dirt",
		fillerDepth = 3,
		underwater = "Sand",
		beach = "Sand",
		features = { { "AcaciaTree", 1 } },
	},
	{
		name = "Desert",
		temperature = 0.8,
		humidity = -0.7,
		heightOffset = 3,
		hilliness = 5,
		vegetation = 0.03,
		top = "Sand",
		filler = "Sandstone",
		fillerDepth = 5,
		underwater = "Sand",
		beach = "Sand",
		features = { { "Cactus", 1 } },
	},
	{
		name = "Jungle",
		temperature = 0.65,
		humidity = 0.55,
		heightOffset = 7,
		hilliness = 14,
		vegetation = 0.55,
		top = "Grass",
		filler = "Dirt",
		fillerDepth = 3,
		underwater = "Dirt",
		beach = "Sand",
		features = { { "JungleTree", 2 }, { "OakTree", 1 } },
	},
}

return list

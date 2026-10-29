return {
	{
		name = "FixtureMarsh",
		bands = { "Lowland" },
		temperature = 0.4,
		humidity = 0.9,
		weather = { temperature = 0.8 },
		vegetation = 0.2,
		top = "Grass",
		filler = "Dirt",
		fillerDepth = 2,
		patches = { block = "CoarseDirt", cover = 0.2 },
		underwater = "Dirt",
		beach = "Dirt",
		features = { { "OakTree", 1 } },
		foliage = {
			density = 0.1,
			plants = { { "ShortGrass", 3 }, { "Fern", 1 } },
			flowers = { chance = 0.01, species = { { "BlueOrchid", 1 } } },
		},
		tags = { "is_forest", "is_fixture_wet" },
	},
	-- (A list is replaced whole: the plains' flowers are these two now, the rest of their foliage
	-- kept, the Survival pack's mint too.)
	{
		name = "Plains",
		override = true,
		foliage = { flowers = { species = { { "Poppy", 1 }, { "Allium", 1 } } } },
	},
}

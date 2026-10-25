return {
	-- (A table of fields patched field by field: the dunes keep their dry weather; a list replaced.)
	{
		name = "BetaDunes",
		override = true,
		weather = { temperature = 1.5 },
		features = { { "OakTree", 2 } },
		tags = { "is_fixture", "is_patched" },
	},
	{
		name = "GammaGlade",
		bands = { "Forest" },
		temperature = 0.1,
		humidity = 0.3,
		vegetation = 0.2,
		top = "AlphaStone",
		filler = "BetaStone",
		fillerDepth = 3,
		patches = { block = "GammaGlass", cover = 0.2 },
		underwater = "BetaStone",
		beach = "BetaStone",
		features = {},
	},
}

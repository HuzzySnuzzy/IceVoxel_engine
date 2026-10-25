return function(define)
	return {
		define.shaped({ "GG", "GG" }, { G = "FixtureGem" }, "FixtureOre"),
		define.smelting("FixtureOre", "FixtureGem", 2),
		define.shapeless({ "FixtureGem", "#fixture_tag" }, "FixtureHelmet"),
	}
end

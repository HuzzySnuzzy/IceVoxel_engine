return function(define)
	return {
		define.shaped({ "GG", "GG" }, { G = "FixtureGem" }, "FixtureOre"),
		define.smelting("FixtureOre", "FixtureGem", 2),
		define.shapeless({ "FixtureGem", "#fixture_tag" }, "FixtureHelmet"),
		-- (A food a furnace makes into a food: a burning mob's drop cooks the same, Foods.COOKED.)
		define.smelting("FixtureSnack", "FixtureSalve"),
	}
end

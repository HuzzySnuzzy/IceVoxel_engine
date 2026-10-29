return {
	-- (The Electric Age's row 2 is free: Demolition's line runs straight along it.)
	{
		id = "fixture_blasting",
		name = "Fixture Blasting",
		description = "Unlocks the Fixture Blast Charge",
		row = 2,
		icon = "Tnt",
		age = "electric",
		cost = 4,
		requires = { "demolition" },
		perk = { kind = "none" },
	},
	-- A pack retuning a node: its cost and line, the rest Core's.
	{ id = "forager", override = true, cost = 2, description = "+10% knowledge from discoveries, dearer" },
}

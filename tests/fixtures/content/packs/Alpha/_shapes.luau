-- A helper of the pack's own (its name starts with "_", so the loader leaves it alone).
return {
	-- The Alpha Fixium metal, for Define.metal.
	FIXIUM = {
		name = "Fixium",
		level = 1,
		colors = {
			ore = { 200, 100, 50 },
			block = { 210, 110, 60 },
			rawBlock = { 180, 90, 40 },
			raw = { 190, 95, 45 },
			ingot = { 220, 120, 70 },
			light = { 240, 160, 120 },
			dark = { 100, 50, 20 },
		},
		oreBlock = { lore = "Gives Raw Fixium.", knowledge = { mine = 2 } },
		ingotItem = { age = "beta_age" },
	},
	-- A wand's model.
	WAND = {
		{ size = { 1, 12, 1 }, offset = { 0, 0, 0 } },
		{ size = { 3, 3, 3 }, offset = { 0, 6, 0 }, color = { 255, 220, 120 } },
	},
}

return {
	-- No lore, no texture faces, and nothing in survival gives it.
	{ name = "FixtureLintBare", color = { 120, 120, 128 }, material = "Slate", hardness = 1 },
	-- Clean: found in the world (the pack's ore feature), with lore and its own texture.
	{
		name = "FixtureLintClean",
		color = { 140, 140, 150 },
		material = "Slate",
		hardness = 1,
		lore = "A fixture block with nothing against it.",
		texture = { All = "fixture lint clean" },
	},
	-- Drops FixtureLintRaw, but no ore feature places it: out of reach.
	{
		name = "FixtureLintOre",
		color = { 150, 140, 120 },
		material = "Slate",
		hardness = 1,
		drops = "FixtureLintRaw",
		lore = "A fixture ore the world never makes.",
		texture = { All = "fixture lint clean" },
	},
}

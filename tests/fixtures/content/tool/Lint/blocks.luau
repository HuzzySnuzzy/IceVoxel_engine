return {
	-- No lore, no texture faces, and nothing in survival gives it.
	{ name = "LintBare", color = { 120, 120, 128 }, material = "Slate", hardness = 1 },
	-- Clean: found in the world (the pack's ore feature), with lore and its own texture.
	{
		name = "LintClean",
		color = { 140, 140, 150 },
		material = "Slate",
		hardness = 1,
		lore = "A fixture block with nothing against it.",
		texture = { All = "lint clean" },
	},
}

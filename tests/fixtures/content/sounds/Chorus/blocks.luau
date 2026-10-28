-- The Chorus fixture pack's blocks (tests/spec/Content): one of its own sound type, and the
-- Electric Furnace humming its hum.
return {
	{
		name = "ChorusBlock",
		color = { 200, 180, 240 },
		material = "Marble",
		sound = "chime",
		texture = { All = "stone" },
		lore = "Rings when walked on.",
	},
	{ name = "ElectricFurnace", override = true, workSound = "block.chorus.hum" },
}

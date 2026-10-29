-- The FixtureChorus fixture pack's blocks (tests/spec/Content): one of its own sound type, and the
-- Electric Furnace humming its hum.
return {
	{
		name = "FixtureChorusBlock",
		color = { 200, 180, 240 },
		material = "Marble",
		sound = "fixture_chime",
		texture = { All = "stone" },
		lore = "Rings when walked on.",
	},
	{ name = "ElectricFurnace", override = true, workSound = "block.fixture_chorus.hum" },
}

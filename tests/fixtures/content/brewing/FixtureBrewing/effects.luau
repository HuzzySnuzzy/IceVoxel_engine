return {
	-- Minecraft's Luck (MobEffects.LUCK, its colour) under a fixture's name, which nothing in the
	-- game gives but this pack's potion.
	{
		name = "FixtureLuck",
		command = "fixture_luck",
		color = { 51, 153, 0 },
		category = "beneficial",
		icon = "star",
	},
	-- The Minecraft pack's Speed in another colour: its potions' liquid follows.
	{ name = "Speed", override = true, color = { 10, 20, 30 } },
}

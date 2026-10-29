return {
	{
		name = "FixtureLuck",
		ingredient = "Emerald",
		effect = "FixtureLuck",
		seconds = 300,
		long = 600,
		lore = {
			base = "Brewed from an emerald. Feel lucky.",
			long = "Brewed longer with coal. Feel lucky for longer.",
		},
		icon = { base = "rbxassetid://777" },
		age = { base = "iron", long = "industrial" },
	},
	-- The Minecraft pack's Swiftness lasting 4:00, its line patched (its strong and long variants
	-- keep theirs only if this gives them: `lore` is one field).
	{
		name = "Swiftness",
		override = true,
		seconds = 240,
		lore = {
			base = "Patched by FixtureBrewing. Run faster for longer.",
			strong = "Brewed stronger with Glow Dust. Run much faster.",
			long = "Brewed longer with coal. Run faster.",
		},
	},
}

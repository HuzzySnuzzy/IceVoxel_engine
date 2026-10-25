return function(define)
	return {
		{
			name = "FixtureGem",
			color = { 150, 60, 160 },
			material = "Glass",
			model = define.nugget({ 150, 60, 160 }),
			lore = "Every item field there is.",
			icon = "rbxassetid://12345",
			age = "iron",
			skill = "demolition",
			knowledge = { smelt = 2 },
			radiation = 0.2,
			fuel = 120,
			tags = { "fixture_tag", "coals" },
		},
		{
			name = "FixtureHelmet",
			maxStack = 1,
			armor = { slot = "Head", defense = 1, toughness = 0 },
			color = { 150, 60, 160 },
			material = "Metal",
			model = define.HELMET,
			shielding = 0.5,
			equipSound = "item.armor.equip_gold",
		},
	}
end

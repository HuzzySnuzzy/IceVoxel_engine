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
		-- Food and drink (Items/Foods, ToughAsNails/Drinks): every field of each.
		{
			name = "FixtureSnack",
			model = define.nugget({ 200, 160, 90 }),
			food = {
				heal = 2,
				nutrition = 3,
				saturation = 0.5,
				effect = { kind = "thirst", chance = 0.25, ticks = 100 },
				useTicks = 20,
				effects = { { effect = "Speed", ticks = 60, amplifier = 1 } },
			},
		},
		{
			name = "FixtureSalve",
			model = define.nugget({ 220, 220, 220 }),
			food = {
				heal = 1,
				useTicks = 30,
				cures = { "Bleeding", "Infection" },
				aftermath = { effect = "Weakness", ticks = 40, stage = 2 },
				setback = true,
				sound = "item.bandage.apply",
				burp = false,
			},
		},
		{
			name = "FixtureTonic",
			model = define.bottle({ 90, 200, 120 }),
			drink = {
				thirst = 3,
				hydration = 0.5,
				chance = 0.25,
				effectTicks = 100,
				warmth = 60,
				chill = 30,
				effects = { { effect = "Speed", ticks = 80 } },
				mana = 5,
				empty = "GlassBottle",
			},
		},
		-- (Purified water's drink, in sips: alike drinks are one.)
		{
			name = "FixtureFlask",
			durability = 2,
			model = define.bottle({ 64, 140, 236 }),
			drink = { thirst = 6, hydration = 0.4, empty = "FixtureGem", sips = true },
		},
	}
end

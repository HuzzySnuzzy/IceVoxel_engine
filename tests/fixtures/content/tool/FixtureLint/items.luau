local BOX = { { size = { 4, 4, 4 }, offset = { 0, 0, 0 } } }

return {
	-- No icon entry (smelted from FixtureLintClean).
	{ name = "FixtureLintNoIcon", model = BOX, lore = "A fixture item without an icon." },
	-- The Iron Age's, made from FixtureLintClean; eaten (`show` prints what eating it does).
	{
		name = "FixtureLintPart",
		model = BOX,
		lore = "A fixture part.",
		icon = "",
		age = "iron",
		food = { heal = 2, nutrition = 4, saturation = 0.25, effect = { kind = "hunger", chance = 0.5, ticks = 100 } },
	},
	-- No Age, though only FixtureLintPart (the Iron Age's) makes it; drunk (and what drinking it does).
	{
		name = "FixtureLintLate",
		model = BOX,
		lore = "A fixture result of the Iron Age.",
		icon = "",
		drink = {
			thirst = 3,
			hydration = 0.5,
			effects = { { effect = "Speed", ticks = 40, amplifier = 1 } },
			empty = "FixtureLintPart",
		},
	},
	-- Nothing gives it.
	{ name = "FixtureLintLost", model = BOX, lore = "A fixture item out of reach.", icon = "" },
	-- Two results of one grid: the first recipe wins.
	{ name = "FixtureLintFirst", model = BOX, lore = "A fixture item crafted.", icon = "" },
	{ name = "FixtureLintSecond", model = BOX, lore = "A fixture item never crafted.", icon = "" },
	-- FixtureLintOre's drop, and what it makes (and is made from): a loop with no way in.
	{ name = "FixtureLintRaw", model = BOX, lore = "A fixture ore's drop.", icon = "" },
	{ name = "FixtureLintNugget", model = BOX, lore = "A fixture nugget.", icon = "" },
}

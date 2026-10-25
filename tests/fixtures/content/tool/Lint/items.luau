local BOX = { { size = { 4, 4, 4 }, offset = { 0, 0, 0 } } }

return {
	-- No icon entry (smelted from LintClean).
	{ name = "LintNoIcon", model = BOX, lore = "A fixture item without an icon." },
	-- The Iron Age's, made from LintClean; eaten (`show` prints what eating it does).
	{
		name = "LintPart",
		model = BOX,
		lore = "A fixture part.",
		icon = "",
		age = "iron",
		food = { heal = 2, nutrition = 4, saturation = 0.25, effect = { kind = "hunger", chance = 0.5, ticks = 100 } },
	},
	-- No Age, though only LintPart (the Iron Age's) makes it; drunk (and what drinking it does).
	{
		name = "LintLate",
		model = BOX,
		lore = "A fixture result of the Iron Age.",
		icon = "",
		drink = {
			thirst = 3,
			hydration = 0.5,
			effects = { { effect = "Speed", ticks = 40, amplifier = 1 } },
			empty = "LintPart",
		},
	},
	-- Nothing gives it.
	{ name = "LintLost", model = BOX, lore = "A fixture item out of reach.", icon = "" },
	-- Two results of one grid: the first recipe wins.
	{ name = "LintFirst", model = BOX, lore = "A fixture item crafted.", icon = "" },
	{ name = "LintSecond", model = BOX, lore = "A fixture item never crafted.", icon = "" },
}

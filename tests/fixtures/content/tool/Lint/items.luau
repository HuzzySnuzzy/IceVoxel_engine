local BOX = { { size = { 4, 4, 4 }, offset = { 0, 0, 0 } } }

return {
	-- No icon entry (smelted from LintClean).
	{ name = "LintNoIcon", model = BOX, lore = "A fixture item without an icon." },
	-- The Iron Age's, made from LintClean.
	{ name = "LintPart", model = BOX, lore = "A fixture part.", icon = "", age = "iron" },
	-- No Age, though only LintPart (the Iron Age's) makes it.
	{ name = "LintLate", model = BOX, lore = "A fixture result of the Iron Age.", icon = "" },
	-- Nothing gives it.
	{ name = "LintLost", model = BOX, lore = "A fixture item out of reach.", icon = "" },
	-- Two results of one grid: the first recipe wins.
	{ name = "LintFirst", model = BOX, lore = "A fixture item crafted.", icon = "" },
	{ name = "LintSecond", model = BOX, lore = "A fixture item never crafted.", icon = "" },
}

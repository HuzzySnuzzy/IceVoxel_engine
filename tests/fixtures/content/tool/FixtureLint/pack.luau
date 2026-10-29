--[[
	A fixture pack with one of each thing the content tool warns about (tests/spec/ContentTool
	grafts it into Content/Packs, after the game's own packs, and runs the check):
	FixtureLintBare has no lore and no texture faces and nothing gives it, FixtureLintNoIcon no
	icon, "fixture lint unused" no block, FixtureLintLate no Age though only an Iron Age part makes
	it, FixtureLintSecond's grid makes FixtureLintFirst, nothing rolls the loot table
	fixture_lint_unused, FixtureLintLate's drink gives the Minecraft pack's Speed though the pack
	requires only Core, and nothing gives FixtureLintLost. Only breaking FixtureLintOre, which the
	world never makes, gives FixtureLintRaw, and FixtureLintNugget is made from it (and it back
	from two): out of reach, for that one reason. FixtureLintClean, FixtureLintPart,
	FixtureLintFirst and the "fixture lint clean" texture have nothing to say against them.
]]
return {
	order = 900,
	description = "One of each content tool finding, for tests/spec/ContentTool.",
	requires = { "Core" },
}

--[[
	A fixture pack with one of each thing the content tool warns about (tests/spec/ContentTool
	grafts it into Content/Packs, after the game's own packs, and runs the check): LintBare has
	no lore and no texture faces and nothing gives it, LintNoIcon no icon, "lint unused" no block,
	LintLate no Age though only an Iron Age part makes it, LintSecond's grid makes LintFirst, and
	nothing gives LintLost. LintClean, LintPart, LintFirst and the "lint clean" texture have
	nothing to say against them.
]]
return {
	order = 900,
	description = "One of each content tool finding, for tests/spec/ContentTool.",
	requires = { "Core" },
}

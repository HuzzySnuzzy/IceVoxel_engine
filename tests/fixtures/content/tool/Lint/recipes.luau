return {
	{ type = "smelting", input = "LintClean", result = "LintNoIcon" },
	{ type = "shapeless", ingredients = { "LintClean" }, result = "LintPart" },
	{ type = "shapeless", ingredients = { "LintPart", "LintPart" }, result = "LintLate" },
	{ type = "shaped", pattern = { "C", "C" }, key = { C = "LintClean" }, result = "LintFirst" },
	-- (The same grid: LintFirst's recipe fits it first.)
	{ type = "shaped", pattern = { "C", "C" }, key = { C = "LintClean" }, result = "LintSecond" },
}

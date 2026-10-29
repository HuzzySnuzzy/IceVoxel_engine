return {
	{ type = "smelting", input = "FixtureLintClean", result = "FixtureLintNoIcon" },
	{ type = "shapeless", ingredients = { "FixtureLintClean" }, result = "FixtureLintPart" },
	{ type = "shapeless", ingredients = { "FixtureLintPart", "FixtureLintPart" }, result = "FixtureLintLate" },
	{ type = "shaped", pattern = { "C", "C" }, key = { C = "FixtureLintClean" }, result = "FixtureLintFirst" },
	-- (The same grid: FixtureLintFirst's recipe fits it first.)
	{ type = "shaped", pattern = { "C", "C" }, key = { C = "FixtureLintClean" }, result = "FixtureLintSecond" },
	{ type = "shapeless", ingredients = { "FixtureLintRaw" }, result = "FixtureLintNugget", count = 2 },
	{ type = "shapeless", ingredients = { "FixtureLintNugget", "FixtureLintNugget" }, result = "FixtureLintRaw" },
}

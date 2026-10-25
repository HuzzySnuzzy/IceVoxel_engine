-- The Luau fixture pack (tests/spec/Content): function-form modules, Define's helpers, a "_"
-- helper module of its own, and a pack it requires (Beta, the JSON one, which loads first).
return {
	order = 20,
	description = "The Luau fixture pack.",
	requires = { "Beta" },
}

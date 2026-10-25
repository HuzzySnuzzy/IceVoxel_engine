-- The overriding fixture pack (tests/spec/Content): the same order as Alpha, after it by name.
return {
	order = 20,
	description = "Patches Alpha's stone, Beta's gem and a texture; adds a block.",
	requires = { "Alpha", "Beta" },
}

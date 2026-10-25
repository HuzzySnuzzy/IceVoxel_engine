-- The overriding fixture pack (tests/spec/Content): the same order as Alpha, after it by name.
return {
	order = 20,
	description = "Patches Alpha's stone, pool and structure, Beta's gem, a texture, Beta's biome and an effect; adds a block, a biome and a template.",
	requires = { "Alpha", "Beta" },
}

-- The overriding fixture pack (tests/spec/Content): the same order as Alpha, after it by name.
return {
	order = 20,
	description = "Patches Alpha's stone, Beta's gem, a texture, Beta's biome and an effect; adds a block and a biome.",
	requires = { "Alpha", "Beta" },
}

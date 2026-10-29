--[[
	A fixture pack adding a status effect and a potion of it, and patching one of each of the
	Minecraft pack's (tests/spec/Content grafts it into Content/Packs, after the game's own packs):
	the potion's items, their recipes, lore lines and tooltips come from its entry alone, with
	nothing written in the Minecraft pack.
]]
return {
	order = 900,
	description = "Fixture Luck and its potion, Speed in another colour and Swiftness lasting longer, for tests/spec/Content.",
	requires = { "Core", "Minecraft", "Survival" },
}

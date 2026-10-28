--[[
	A fixture pack of the skills kind (tests/spec/Content grafts it into Content/Packs, after the
	game's own packs): a node needing the Minecraft pack's Demolition, an item its recipe makes that
	the node gates, and an override of Core's Forager.
]]
return {
	order = 900,
	description = "A skill tree node and an override, for tests/spec/Content.",
	requires = { "Core", "Minecraft" },
}

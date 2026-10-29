--[[
	A fixture pack of sounds and music (tests/spec/Content grafts it into Content/Packs, after the
	game's own packs): a block sound type of its own and a block of that type, events (one with a
	limit and a fallback, one a machine's work sound, one an armor piece's), a track and a cave mood;
	and overrides of the Minecraft pack's ui.button.click, its first surface track, the Electric
	Furnace's work sound and the Iron Helmet's equip sound.
]]
return {
	order = 900,
	description = "Sounds and music, for tests/spec/Content.",
	requires = { "Core", "Minecraft", "Mekanism" },
}

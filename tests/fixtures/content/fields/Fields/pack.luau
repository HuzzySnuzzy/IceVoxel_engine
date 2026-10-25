--[[
	A fixture pack with every per-entry field (tests/spec/Content grafts it into Content/Packs, after
	the game's own packs, and checks that each field reaches its registry).
]]
return {
	order = 900,
	description = "Every per-entry field, for tests/spec/Content.",
	requires = { "Core", "Minecraft" },
}

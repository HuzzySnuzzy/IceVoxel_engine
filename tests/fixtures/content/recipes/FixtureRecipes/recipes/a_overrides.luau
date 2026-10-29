-- The Minecraft pack's recipes, by name: Torch's replaced (by its result's name, its own), its
-- smelting of raw iron replaced (by the name it gives), Ladder's taken away.
return {
	{
		type = "shaped",
		override = true,
		pattern = { "X", "#" },
		key = { X = "#coals", ["#"] = "Stick" },
		result = "Torch",
		count = 8,
	},
	{
		type = "smelting",
		name = "IronIngotFromRawIron",
		override = true,
		input = "RawIron",
		result = "IronIngot",
		count = 2,
	},
	{ name = "Ladder", remove = true },
}

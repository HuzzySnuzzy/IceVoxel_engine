--!strict
--[[
	The structures this pack's generation places: Minecraft's jigsaw structures, with their
	random_spread placement (Content/Schema has the fields; Structures/Library fills in the
	defaults).
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	-- The example: a watchtower (or its ruin) with paths, huts, a storehouse (a chest of supplies)
	-- and a forge (templates/outpost, built by tests/build_structures; pools). Rare: at most one
	-- per 56 x 56 chunks (896 x 896 blocks), in grassland and forests.
	{
		name = "outpost",
		startPool = "outpost/centres",
		size = 3,
		maxDistance = 48,
		biomes = { "Plains", "Savanna", "Meadow", "Forest" },
		spacing = 56,
		separation = 14,
	},
} :: { Schema.StructureSpec }

--!strict
--[[
	Mekanism's osmium ore features (Generation/Ores' header says how each was mapped from
	Mekanism's; `block` is the block's name). The middle feature's 4 per 128 blocks over its 192 are
	Mekanism's 6 veins per chunk.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	{ name = "osmium_small", block = "OsmiumOre", veins = 3, size = 4, minY = 5, maxY = math.huge },
	{
		name = "osmium_middle",
		block = "OsmiumOre",
		veins = 4,
		size = 9,
		minY = 5,
		maxY = 197,
		shape = "trapezoid",
	},
	{ name = "osmium_upper", block = "OsmiumOre", veins = 2, size = 7, minY = 197, maxY = math.huge },
} :: { Schema.OreFeature }

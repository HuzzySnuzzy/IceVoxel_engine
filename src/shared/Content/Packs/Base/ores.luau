--!strict
--[[
	The Base pack's ore features (Generation/Ores' list, moved here unchanged, but for the new ores',
	which are the Ores pack's): the stone varieties, Minecraft's ores and Mekanism's osmium, in
	placement order. Generation/Ores' header says what each field does and where the numbers come
	from; `block` is the block's name.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	{ name = "diorite", block = "Diorite", veins = 1.5, size = 40, minY = 5, maxY = 200 },
	{ name = "andesite", block = "Andesite", veins = 1.5, size = 40, minY = 200, maxY = 370 },
	{ name = "granite", block = "Granite", veins = 1.5, size = 40, minY = 370, maxY = 540 },
	{ name = "coal", block = "CoalOre", veins = 12, size = 10, minY = 5, maxY = math.huge },
	{ name = "iron", block = "IronOre", veins = 7, size = 7, minY = 5, maxY = math.huge },
	{ name = "gold", block = "GoldOre", veins = 3, size = 6, minY = 48, maxY = math.huge },
	{ name = "diamond", block = "DiamondOre", veins = 4, size = 5, minY = 5, maxY = 30 },
	{ name = "emerald", block = "EmeraldOre", veins = 4, size = 3, minY = 600, maxY = math.huge },
	-- Mekanism's osmium (Generation/Ores' header). The middle feature's 4 per 128 blocks over its 192
	-- are Mekanism's 6 veins per chunk.
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

--!strict
--[[
	The Minecraft pack's ores and their storage blocks: coal, iron, gold, diamond and emerald ore
	(the pack's `ores` places them), and the blocks of coal, iron, gold, diamond, emerald, raw iron
	and raw gold (nine of the item each, Crafting's storage recipes). The ores drop their item
	(raw iron, raw gold) with a pickaxe of their tier. blastResistance 6 for every storage block
	(Minecraft's metal and gem blocks); the Block of Coal burns as Minecraft's (5 / 5). Zombies
	break none of them.
]]

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type BlockSpec = Schema.BlockSpec

return {
	{
		name = "CoalOre",
		color = { 58, 58, 62 },
		material = "Rock",
		hardness = 3,
		tool = "pickaxe",
		toolLevel = 0,
		drops = "Coal" :: string,
	},
	{
		name = "IronOre",
		color = { 176, 142, 118 },
		material = "Rock",
		hardness = 3,
		tool = "pickaxe",
		toolLevel = 1,
		drops = "RawIron" :: string,
	},
	{
		name = "GoldOre",
		color = { 222, 190, 72 },
		material = "Rock",
		hardness = 3,
		tool = "pickaxe",
		toolLevel = 2,
		drops = "RawGold" :: string,
	},
	{
		name = "DiamondOre",
		color = { 92, 202, 212 },
		material = "Rock",
		hardness = 3,
		tool = "pickaxe",
		toolLevel = 2,
		drops = "Diamond" :: string,
	},
	{
		name = "EmeraldOre",
		color = { 62, 168, 94 },
		material = "Rock",
		hardness = 3,
		tool = "pickaxe",
		toolLevel = 2,
		drops = "Emerald" :: string,
	},
	{
		name = "CoalBlock",
		displayName = "Block of Coal",
		color = { 22, 22, 26 },
		material = "Slate",
		hardness = 5,
		blastResistance = 6,
		tool = "pickaxe",
		toolLevel = 0,
		flammable = { ignite = 5, burn = 5 },
	},
	{
		name = "IronBlock",
		displayName = "Block of Iron",
		color = { 220, 220, 222 },
		material = "Metal",
		hardness = 5,
		blastResistance = 6,
		tool = "pickaxe",
		toolLevel = 1,
	},
	{
		name = "GoldBlock",
		displayName = "Block of Gold",
		color = { 246, 208, 61 },
		material = "Metal",
		hardness = 3,
		blastResistance = 6,
		tool = "pickaxe",
		toolLevel = 2,
	},
	{
		name = "DiamondBlock",
		displayName = "Block of Diamond",
		color = { 98, 237, 228 },
		material = "Metal",
		hardness = 5,
		blastResistance = 6,
		tool = "pickaxe",
		toolLevel = 2,
	},
	{
		name = "EmeraldBlock",
		displayName = "Block of Emerald",
		color = { 42, 203, 88 },
		material = "Metal",
		hardness = 5,
		blastResistance = 6,
		tool = "pickaxe",
		toolLevel = 2,
	},
	{
		name = "RawIronBlock",
		displayName = "Block of Raw Iron",
		color = { 166, 135, 107 },
		material = "Rock",
		hardness = 5,
		blastResistance = 6,
		tool = "pickaxe",
		toolLevel = 1,
	},
	{
		name = "RawGoldBlock",
		displayName = "Block of Raw Gold",
		color = { 221, 169, 46 },
		material = "Rock",
		hardness = 5,
		blastResistance = 6,
		tool = "pickaxe",
		toolLevel = 2,
	},
} :: { BlockSpec }

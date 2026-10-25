--!strict
--[[
	Mekanism's osmium (Mekanism 10.4): Osmium Ore, the Block of Osmium and the Block of Raw Osmium.
	The pack's `ores` places the ore, its recipes smelt it and pack the storage blocks, and its
	items are Raw Osmium, the Osmium Ingot and the Osmium Nugget.

	  * Osmium Ore is stone with bluish-white specks: Granite's speckled material in a blue-grey.
	    Mekanism's numbers: hardness 3 (Minecraft's ores), a stone pickaxe or better to drop
	    anything (its needs_stone_tool tag), and it drops one Raw Osmium.
	  * Both storage blocks have Mekanism's hardness 7.5 and need a stone pickaxe too. The Block of
	    Osmium is bluish silver metal and sounds like the game's other metal blocks (Mekanism
	    leaves its resource blocks on the default stone sound); the raw block is rock.
]]

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return {
	{
		name = "OsmiumOre",
		color = { 138, 156, 184 },
		material = "Granite",
		hardness = 3,
		tool = "pickaxe",
		toolLevel = 1,
		drops = "RawOsmium" :: string,
	},
	{
		name = "OsmiumBlock",
		displayName = "Block of Osmium",
		color = { 166, 188, 212 },
		material = "Metal",
		hardness = 7.5,
		tool = "pickaxe",
		toolLevel = 1,
	},
	{
		name = "RawOsmiumBlock",
		displayName = "Block of Raw Osmium",
		color = { 118, 144, 176 },
		material = "Rock",
		hardness = 7.5,
		tool = "pickaxe",
		toolLevel = 1,
	},
} :: { Schema.BlockSpec }

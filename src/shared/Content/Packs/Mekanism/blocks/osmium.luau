--!strict
--[[
	Mekanism's osmium (Mekanism 10.4): Osmium Ore, the Block of Osmium and the Block of Raw Osmium.
	The pack's `ores` places the ore, its recipes smelt it and pack the storage blocks, and its
	items are Raw Osmium, the Osmium Ingot and the Osmium Nugget.

	  * Osmium Ore is stone with bluish-white specks: Granite's speckled material in a blue-grey.
	    Mekanism's numbers: hardness 3 (Minecraft's ores), a stone pickaxe or better to drop
	    anything (its needs_stone_tool tag), and it drops one Raw Osmium. Mined in any Age; mining
	    it again gives iron's knowledge (2), and the Metal Miner copies it as iron (400 ticks an
	    item at 200 J a tick).
	  * Both storage blocks have Mekanism's hardness 7.5 and need a stone pickaxe too. The Block of
	    Osmium is bluish silver metal and sounds like the game's other metal blocks (Mekanism
	    leaves its resource blocks on the default stone sound); the raw block is rock. Both are
	    the Industrial Age's.
	  * Each block's texture is the pack's own (textures), blank until made.
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
		texture = { All = "osmium ore" },
		lore = "Gives Raw Osmium, Mekanism's machine metal.",
		knowledge = { mine = 2 },
		miner = { ticks = 400, joules = 200 },
		-- (The `ores` block tag: a tool's tooltip lists it first.)
		tags = { "ores" },
	},
	{
		name = "OsmiumBlock",
		displayName = "Block of Osmium",
		color = { 166, 188, 212 },
		material = "Metal",
		hardness = 7.5,
		tool = "pickaxe",
		toolLevel = 1,
		texture = { All = "osmium block" },
		lore = "Nine osmium ingots in one block.",
		age = "industrial",
	},
	{
		name = "RawOsmiumBlock",
		displayName = "Block of Raw Osmium",
		color = { 118, 144, 176 },
		material = "Rock",
		hardness = 7.5,
		tool = "pickaxe",
		toolLevel = 1,
		texture = { All = "raw osmium block" },
		lore = "Nine Raw Osmium, kept compact.",
		age = "industrial",
	},
} :: { Schema.BlockSpec }

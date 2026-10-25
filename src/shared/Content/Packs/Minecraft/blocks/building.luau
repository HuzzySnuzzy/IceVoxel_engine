--!strict
--[[
	The Minecraft pack's building blocks, which recipes and smelting make: bricks and glass, stone
	bricks and their cracked form, smooth stone, the polished stones, cut and smooth sandstone, and
	blue ice (nine packed ice).

	  * blastResistance: Minecraft 1.20.1's where it differs from the hardness (the stone family
	    and bricks 6: a TNT blast barely scratches them); the rest keep their hardness.
	  * zombieBreak: glass shatters at once (60 ticks), stone and brick take two minutes (2400).
]]

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type BlockSpec = Schema.BlockSpec

return {
	{
		name = "Brick",
		color = { 160, 82, 62 },
		material = "Brick",
		hardness = 2,
		blastResistance = 6,
		tool = "pickaxe",
		toolLevel = 0,
		displayName = "Bricks",
		zombieBreak = 2400,
	},
	{
		name = "Glass",
		render = "Transparent",
		color = { 210, 235, 245 },
		material = "Glass",
		transparency = 0.6,
		hardness = 0.3,
		drops = false,
		zombieBreak = 60,
	},
	{
		name = "StoneBricks",
		color = { 122, 121, 122 },
		material = "Brick",
		hardness = 1.5,
		blastResistance = 6,
		tool = "pickaxe",
		toolLevel = 0,
		zombieBreak = 2400,
	},
	{
		name = "CrackedStoneBricks",
		color = { 118, 117, 118 },
		material = "Brick",
		hardness = 1.5,
		blastResistance = 6,
		tool = "pickaxe",
		toolLevel = 0,
		zombieBreak = 2400,
	},
	{
		name = "SmoothStone",
		color = { 158, 158, 158 },
		material = "Concrete",
		hardness = 2,
		blastResistance = 6,
		tool = "pickaxe",
		toolLevel = 0,
		zombieBreak = 2400,
	},
	{
		name = "PolishedAndesite",
		color = { 132, 135, 134 },
		material = "Concrete",
		hardness = 1.5,
		blastResistance = 6,
		tool = "pickaxe",
		toolLevel = 0,
	},
	{
		name = "PolishedDiorite",
		color = { 192, 193, 194 },
		material = "Marble",
		hardness = 1.5,
		blastResistance = 6,
		tool = "pickaxe",
		toolLevel = 0,
	},
	{
		name = "PolishedGranite",
		color = { 154, 106, 89 },
		material = "Concrete",
		hardness = 1.5,
		blastResistance = 6,
		tool = "pickaxe",
		toolLevel = 0,
	},
	{
		name = "CutSandstone",
		color = { 217, 206, 159 },
		material = "Sandstone",
		hardness = 0.8,
		tool = "pickaxe",
		toolLevel = 0,
		zombieBreak = 2400,
	},
	{
		name = "SmoothSandstone",
		color = { 223, 214, 170 },
		material = "Sandstone",
		hardness = 2,
		blastResistance = 6,
		tool = "pickaxe",
		toolLevel = 0,
		zombieBreak = 2400,
	},
	{
		name = "BlueIce",
		color = { 116, 167, 253 },
		material = "Ice",
		friction = 0.989,
		hardness = 2.8,
		tool = "pickaxe",
		drops = false,
	},
} :: { BlockSpec }

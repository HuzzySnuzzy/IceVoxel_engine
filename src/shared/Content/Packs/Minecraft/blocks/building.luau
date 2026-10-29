--!strict
--[[
	The Minecraft pack's building blocks, which recipes and smelting make: bricks and glass, stone
	bricks and their cracked form, smooth stone, the polished stones, cut and smooth sandstone, and
	blue ice (nine packed ice).

	  * Blue ice drops itself with a pickaxe, as packed ice does (blocks/terrain: the stand-in for
	    Minecraft's Silk Touch, `toolLevel` 0: by hand 14 s and nothing, Minecraft's 4.2 s; a blast
	    gives nothing, `silkTouch`), and chills a player near it (`cools`, Tough As Nails).
	  * knowledge: smelting glass or smooth stone gives Minecraft's furnace experience, 0.1.
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
		texture = { All = "bricks" },
		lore = "Sturdy fired bricks.",
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
		texture = { All = "glass" },
		lore = "Clear as air. Breaks into nothing.",
		knowledge = { smelt = 0.1 },
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
		texture = { All = "stone bricks" },
		lore = "Neatly cut stone for walls and halls.",
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
		texture = { All = "cracked stone bricks" },
		lore = "Stone bricks cracked by a furnace's heat.",
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
		texture = { All = "smooth stone" },
		lore = "Stone smelted smooth.",
		knowledge = { smelt = 0.1 },
	},
	{
		name = "PolishedAndesite",
		color = { 132, 135, 134 },
		material = "Concrete",
		hardness = 1.5,
		blastResistance = 6,
		tool = "pickaxe",
		toolLevel = 0,
		texture = { All = "polished andesite" },
		lore = "Polished andesite tiles.",
	},
	{
		name = "PolishedDiorite",
		color = { 192, 193, 194 },
		material = "Marble",
		hardness = 1.5,
		blastResistance = 6,
		tool = "pickaxe",
		toolLevel = 0,
		texture = { All = "polished diorite" },
		lore = "Polished diorite tiles.",
	},
	{
		name = "PolishedGranite",
		color = { 154, 106, 89 },
		material = "Concrete",
		hardness = 1.5,
		blastResistance = 6,
		tool = "pickaxe",
		toolLevel = 0,
		texture = { All = "polished granite" },
		lore = "Polished granite tiles.",
	},
	{
		name = "CutSandstone",
		color = { 217, 206, 159 },
		material = "Sandstone",
		hardness = 0.8,
		tool = "pickaxe",
		toolLevel = 0,
		zombieBreak = 2400,
		texture = { Top = "sandstone top", Sides = "cut sandstone" },
		lore = "Sandstone cut into a clean face.",
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
		-- (Minecraft's smooth sandstone is the sandstone top on every face.)
		texture = { All = "sandstone top" },
		lore = "Sandstone smelted smooth.",
	},
	{
		name = "BlueIce",
		color = { 116, 167, 253 },
		material = "Ice",
		friction = 0.989,
		hardness = 2.8,
		tool = "pickaxe",
		-- (A pickaxe for Silk Touch: see the header.)
		toolLevel = 0,
		silkTouch = true,
		texture = { All = "blue ice" },
		lore = "The slipperiest ice there is. Mine it with a pickaxe to keep it.",
		cools = true,
	},
} :: { BlockSpec }

--!strict
--[[
	The Minecraft pack's wood: the five trees' logs and leaves, and their planks (the planks
	recipes and the doors, fences and tools are made of; tags "logs", "planks" and "leaves" are
	Core's).

	  * Leaves hold up no torches or lanterns (Minecraft's LeavesBlock has no support shape), and
	    no spawn or teleport lands on them (a tree top: `spawnUnsafe` "on", server Players/SafeSpot).
	    Shears harvest them, as in Minecraft; otherwise they drop a sapling or sticks now and then
	    (their `loot`, `leafLoot`: Items.lootDrop, also when they decay or a blast takes them), and
	    they decay once their tree has no log left (server Behaviours/Leaves).
	  * flammable (Minecraft 1.20.1's FireBlock.bootStrap): logs 5 / 5, planks 5 / 20, leaves 30 /
	    60. blastResistance: planks 3 (Minecraft's), logs and leaves their hardness.
	  * Logs and planks burn 300 ticks in a furnace, as Minecraft's #logs and #planks: by Core's
	    tags (Crafting/Recipes' fuel), so another pack's planks in the tag burn too.
	  * zombieBreak: leaves 120 ticks, logs and planks 600 (half a minute).
]]

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type BlockSpec = Schema.BlockSpec
type Pool = Schema.Pool

-- Minecraft's leaves loot table without Shears or Fortune: the tree's sapling one time in `odds`
-- (20; jungle leaves 40), else 1 or 2 sticks one time in 50.
local function leafLoot(sapling: string, odds: number): { Pool }
	return {
		{ rolls = { 1, 1 }, entries = { { sapling, 1, 1, 1 }, { false, odds - 1, 0, 0 } } },
		{ rolls = { 1, 1 }, entries = { { "Stick", 1, 1, 2 }, { false, 49, 0, 0 } } },
	}
end

return {
	{
		name = "OakLog",
		color = { 106, 82, 52 },
		material = "Wood",
		hardness = 2,
		tool = "axe",
		flammable = { ignite = 5, burn = 5 },
		zombieBreak = 600,
		texture = { Sides = "log", Top = "log top", Bottom = "log top" },
		lore = "Wood from an oak. Makes planks and charcoal.",
	},
	{
		name = "OakLeaves",
		behaviour = "Leaves",
		color = { 68, 128, 46 },
		material = "LeafyGrass",
		hardness = 0.2,
		drops = false,
		tool = "hoe",
		sturdy = false,
		shearDrops = true,
		flammable = { ignite = 30, burn = 60 },
		zombieBreak = 120,
		texture = { All = "leaves" },
		lore = "Drops saplings and sticks now and then. Shears keep the leaves.",
		loot = leafLoot("OakSapling", 20),
		spawnUnsafe = "on",
	},
	{
		name = "BirchLog",
		color = { 216, 212, 198 },
		material = "Wood",
		hardness = 2,
		tool = "axe",
		flammable = { ignite = 5, burn = 5 },
		zombieBreak = 600,
		texture = { Sides = "log", Top = "log top", Bottom = "log top" },
		lore = "Pale wood from a birch. Makes planks and charcoal.",
	},
	{
		name = "BirchLeaves",
		behaviour = "Leaves",
		color = { 112, 150, 68 },
		material = "LeafyGrass",
		hardness = 0.2,
		drops = false,
		tool = "hoe",
		sturdy = false,
		shearDrops = true,
		flammable = { ignite = 30, burn = 60 },
		zombieBreak = 120,
		texture = { All = "leaves" },
		lore = "Drops saplings and sticks now and then. Shears keep the leaves.",
		loot = leafLoot("BirchSapling", 20),
		spawnUnsafe = "on",
	},
	{
		name = "SpruceLog",
		color = { 74, 54, 34 },
		material = "Wood",
		hardness = 2,
		tool = "axe",
		flammable = { ignite = 5, burn = 5 },
		zombieBreak = 600,
		texture = { Sides = "log", Top = "log top", Bottom = "log top" },
		lore = "Dark wood from a spruce. Makes planks and charcoal.",
	},
	{
		name = "SpruceLeaves",
		behaviour = "Leaves",
		color = { 44, 88, 56 },
		material = "LeafyGrass",
		hardness = 0.2,
		drops = false,
		tool = "hoe",
		sturdy = false,
		shearDrops = true,
		flammable = { ignite = 30, burn = 60 },
		zombieBreak = 120,
		texture = { All = "leaves" },
		lore = "Drops saplings and sticks now and then. Shears keep the leaves.",
		loot = leafLoot("SpruceSapling", 20),
		spawnUnsafe = "on",
	},
	{
		name = "AcaciaLog",
		color = { 118, 108, 98 },
		material = "Wood",
		hardness = 2,
		tool = "axe",
		flammable = { ignite = 5, burn = 5 },
		zombieBreak = 600,
		texture = { Sides = "log", Top = "log top", Bottom = "log top" },
		lore = "Orange wood from an acacia. Makes planks and charcoal.",
	},
	{
		name = "AcaciaLeaves",
		behaviour = "Leaves",
		color = { 108, 138, 40 },
		material = "LeafyGrass",
		hardness = 0.2,
		drops = false,
		tool = "hoe",
		sturdy = false,
		shearDrops = true,
		flammable = { ignite = 30, burn = 60 },
		zombieBreak = 120,
		texture = { All = "leaves" },
		lore = "Drops saplings and sticks now and then. Shears keep the leaves.",
		loot = leafLoot("AcaciaSapling", 20),
		spawnUnsafe = "on",
	},
	{
		name = "JungleLog",
		color = { 96, 76, 44 },
		material = "Wood",
		hardness = 2,
		tool = "axe",
		flammable = { ignite = 5, burn = 5 },
		zombieBreak = 600,
		texture = { Sides = "log", Top = "log top", Bottom = "log top" },
		lore = "Wood from a jungle tree. Makes planks and charcoal.",
	},
	{
		name = "JungleLeaves",
		behaviour = "Leaves",
		color = { 40, 120, 30 },
		material = "LeafyGrass",
		hardness = 0.2,
		drops = false,
		tool = "hoe",
		sturdy = false,
		shearDrops = true,
		flammable = { ignite = 30, burn = 60 },
		zombieBreak = 120,
		texture = { All = "leaves" },
		lore = "Drops saplings and sticks now and then. Shears keep the leaves.",
		loot = leafLoot("JungleSapling", 40),
		spawnUnsafe = "on",
	},
	{
		name = "Planks",
		color = { 170, 134, 84 },
		material = "WoodPlanks",
		hardness = 2,
		blastResistance = 3,
		tool = "axe",
		displayName = "Oak Planks",
		flammable = { ignite = 5, burn = 20 },
		zombieBreak = 600,
		texture = { All = "planks" },
		lore = "Oak boards for building, sticks, tables and chests.",
	},
	{
		name = "BirchPlanks",
		color = { 196, 178, 123 },
		material = "WoodPlanks",
		hardness = 2,
		blastResistance = 3,
		tool = "axe",
		flammable = { ignite = 5, burn = 20 },
		zombieBreak = 600,
		texture = { All = "planks" },
		lore = "Birch boards for building, sticks, tables and chests.",
	},
	{
		name = "SprucePlanks",
		color = { 114, 84, 48 },
		material = "WoodPlanks",
		hardness = 2,
		blastResistance = 3,
		tool = "axe",
		flammable = { ignite = 5, burn = 20 },
		zombieBreak = 600,
		texture = { All = "planks" },
		lore = "Spruce boards for building, sticks, tables and chests.",
	},
	{
		name = "AcaciaPlanks",
		color = { 168, 90, 50 },
		material = "WoodPlanks",
		hardness = 2,
		blastResistance = 3,
		tool = "axe",
		flammable = { ignite = 5, burn = 20 },
		zombieBreak = 600,
		texture = { All = "planks" },
		lore = "Acacia boards for building, sticks, tables and chests.",
	},
	{
		name = "JunglePlanks",
		color = { 160, 115, 80 },
		material = "WoodPlanks",
		hardness = 2,
		blastResistance = 3,
		tool = "axe",
		flammable = { ignite = 5, burn = 20 },
		zombieBreak = 600,
		texture = { All = "planks" },
		lore = "Jungle boards for building, sticks, tables and chests.",
	},
} :: { BlockSpec }

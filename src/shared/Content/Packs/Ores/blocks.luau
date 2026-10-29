--!strict
--[[
	The new ores' blocks, in this order: copper (the ore, the Block of Copper, the Block of Raw
	Copper), lead, zinc, the Block of Brass, Sulfur Ore, Saltpetre Ore, uranium (_metals says what
	each metal's are). Sulfur Ore (yellow crusts) and Saltpetre Ore (white ones, on Limestone's
	material) drop by any pickaxe, as Coal Ore does: one Sulfur, one Saltpetre; the Metal Miner
	copies them at 600 ticks an item (gunpowder can be automated), mining them again gives coal's
	knowledge.
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)
local metals = require(script.Parent._metals)

return function(define: Define.Context): { Schema.BlockSpec }
	local list: { Schema.BlockSpec } = {}
	for _, name in { "Copper", "Lead", "Zinc", "Brass" } do
		define.append(list, define.metal(metals[name]).blocks)
	end
	table.insert(list, {
		name = "SulfurOre",
		color = { 178, 170, 104 },
		material = "Granite",
		hardness = 3,
		tool = "pickaxe",
		toolLevel = 0,
		drops = "Sulfur" :: string,
		texture = { All = "sulfur ore" },
		lore = "Yellow crusts near lava and oil. Gives Sulfur.",
		knowledge = { mine = 1 },
		miner = { ticks = 600, joules = 200 },
		tags = { "ores" },
	})
	table.insert(list, {
		name = "SaltpetreOre",
		color = { 198, 194, 182 },
		material = "Limestone",
		hardness = 3,
		tool = "pickaxe",
		toolLevel = 0,
		drops = "Saltpetre" :: string,
		texture = { All = "saltpetre ore" },
		lore = "White crusts of dry lands. Gives Saltpetre.",
		knowledge = { mine = 1 },
		miner = { ticks = 600, joules = 200 },
		tags = { "ores" },
	})
	define.append(list, define.metal(metals.Uranium).blocks)
	return list
end

--!strict
--[[
	Minecraft's tools: wooden, stone, iron, golden and diamond swords, shovels, pickaxes, axes and
	hoes (Content/Define's `toolSet`: Minecraft's tiers' speed, harvest level and durability, the
	tools' shapes), and the Shears.

	  * Hitting mobs (Shared/Entities/Combat): Minecraft 1.20.1's attack damage (half hearts, the
	    hand's 1 included: the tool's base + its tier's bonus, wood and gold 0, stone 1, iron 2,
	    diamond 3) and attack speed (full strength hits a second) by shape and tier. Axes hit
	    hardest and slowest, swords fastest of the weapons; a hoe hits like the hand, faster with
	    the tier.
	  * Minecraft's Shears: 238 uses, a tool of their own kind (Shared/Mining: 15 on leaves, worn by
	    every block broken, instant ones too) that harvests grass, ferns, dead bushes and leaves
	    (Schema's `shearDrops`; Items.drops). Two grey blades crossing at a rivet over two darker
	    handle loops, modelled upright like the tools (blades up) and tilted the same way (the
	    pack's _models).
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)
local models = require(script.Parent.Parent._models)

-- The tiers, and each shape's { damage, speed } in each.
local TIERS: { Define.ToolTier } = {
	{
		name = "Wooden",
		speed = 2,
		level = 0,
		durability = 59,
		color = { 156, 121, 72 },
		material = "WoodPlanks",
		attack = { Sword = { 4, 1.6 }, Shovel = { 2.5, 1 }, Pickaxe = { 2, 1.2 }, Axe = { 7, 0.8 }, Hoe = { 1, 1 } },
	},
	{
		name = "Stone",
		speed = 4,
		level = 1,
		durability = 131,
		color = { 128, 128, 130 },
		material = "Slate",
		attack = { Sword = { 5, 1.6 }, Shovel = { 3.5, 1 }, Pickaxe = { 3, 1.2 }, Axe = { 9, 0.8 }, Hoe = { 1, 2 } },
	},
	{
		name = "Iron",
		speed = 6,
		level = 2,
		durability = 250,
		color = { 222, 222, 224 },
		material = "Metal",
		attack = { Sword = { 6, 1.6 }, Shovel = { 4.5, 1 }, Pickaxe = { 4, 1.2 }, Axe = { 9, 0.9 }, Hoe = { 1, 3 } },
	},
	{
		name = "Golden",
		speed = 12,
		level = 0,
		durability = 32,
		color = { 250, 213, 58 },
		material = "Metal",
		attack = { Sword = { 4, 1.6 }, Shovel = { 2.5, 1 }, Pickaxe = { 2, 1.2 }, Axe = { 7, 1 }, Hoe = { 1, 1 } },
	},
	{
		name = "Diamond",
		speed = 8,
		level = 3,
		durability = 1561,
		color = { 90, 236, 227 },
		material = "Metal",
		attack = { Sword = { 7, 1.6 }, Shovel = { 5.5, 1 }, Pickaxe = { 5, 1.2 }, Axe = { 9, 1 }, Hoe = { 1, 4 } },
	},
}

return function(define: Define.Context): { Schema.ItemSpec }
	local list: { Schema.ItemSpec } = {}
	for _, tier in TIERS do
		define.append(list, define.toolSet(tier))
	end
	table.insert(list, {
		name = "Shears",
		durability = 238,
		tool = { kind = "shears", speed = 15, level = 0 },
		color = { 204, 206, 210 },
		material = "Metal",
		model = models.shears(),
		tilt = -45,
	})
	return list
end

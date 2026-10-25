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

	Each tier names its tools' lore lines and icons (blank), by shape, and the Age opening their
	recipes: iron and golden tools and the Shears the Iron Age's, diamond ones the Industrial
	Age's (wooden and stone ones the first Age's). Wooden tools burn 200 ticks in a furnace, as
	Minecraft's.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)
local models = require(script.Parent.Parent._models)

-- The tiers, and each shape's { damage, speed }, lore line and icon in each.
local TIERS: { Define.ToolTier } = {
	{
		name = "Wooden",
		speed = 2,
		level = 0,
		durability = 59,
		color = { 156, 121, 72 },
		material = "WoodPlanks",
		attack = { Sword = { 4, 1.6 }, Shovel = { 2.5, 1 }, Pickaxe = { 2, 1.2 }, Axe = { 7, 0.8 }, Hoe = { 1, 1 } },
		lore = {
			Sword = "A first weapon, carved from planks.",
			Shovel = "Digs dirt, sand and gravel faster.",
			Pickaxe = "Mines stone and coal. Your first pickaxe.",
			Axe = "Chops wood faster. Hits hard, but slowly.",
			Hoe = "Clears leaves and moss quickly.",
		},
		icons = { Sword = "", Shovel = "", Pickaxe = "", Axe = "", Hoe = "" },
		fuel = 200,
	},
	{
		name = "Stone",
		speed = 4,
		level = 1,
		durability = 131,
		color = { 128, 128, 130 },
		material = "Slate",
		attack = { Sword = { 5, 1.6 }, Shovel = { 3.5, 1 }, Pickaxe = { 3, 1.2 }, Axe = { 9, 0.8 }, Hoe = { 1, 2 } },
		lore = {
			Sword = "A sharper edge of stone.",
			Shovel = "Digs dirt, sand and gravel faster.",
			Pickaxe = "Mines iron, osmium, copper, lead and zinc ore.",
			Axe = "Chops wood faster. Hits hard, but slowly.",
			Hoe = "Clears leaves and moss quickly.",
		},
		icons = { Sword = "", Shovel = "", Pickaxe = "", Axe = "", Hoe = "" },
	},
	{
		name = "Iron",
		speed = 6,
		level = 2,
		durability = 250,
		color = { 222, 222, 224 },
		material = "Metal",
		attack = { Sword = { 6, 1.6 }, Shovel = { 4.5, 1 }, Pickaxe = { 4, 1.2 }, Axe = { 9, 0.9 }, Hoe = { 1, 3 } },
		lore = {
			Sword = "A dependable iron blade.",
			Shovel = "Digs dirt, sand and gravel faster.",
			Pickaxe = "Mines gold, diamond, emerald and uranium ore.",
			Axe = "Chops wood faster. Hits hard, but slowly.",
			Hoe = "Clears leaves and moss quickly.",
		},
		icons = { Sword = "", Shovel = "", Pickaxe = "", Axe = "", Hoe = "" },
		age = "iron",
	},
	{
		name = "Golden",
		speed = 12,
		level = 0,
		durability = 32,
		color = { 250, 213, 58 },
		material = "Metal",
		attack = { Sword = { 4, 1.6 }, Shovel = { 2.5, 1 }, Pickaxe = { 2, 1.2 }, Axe = { 7, 1 }, Hoe = { 1, 1 } },
		lore = {
			Sword = "Pretty, but it breaks quickly.",
			Shovel = "Digs very fast, but breaks quickly.",
			Pickaxe = "Mines very fast, but only what wood can.",
			Axe = "Chops very fast, but breaks quickly.",
			Hoe = "Clears leaves very fast, but breaks quickly.",
		},
		icons = { Sword = "", Shovel = "", Pickaxe = "", Axe = "", Hoe = "" },
		age = "iron",
	},
	{
		name = "Diamond",
		speed = 8,
		level = 3,
		durability = 1561,
		color = { 90, 236, 227 },
		material = "Metal",
		attack = { Sword = { 7, 1.6 }, Shovel = { 5.5, 1 }, Pickaxe = { 5, 1.2 }, Axe = { 9, 1 }, Hoe = { 1, 4 } },
		lore = {
			Sword = "The sharpest blade there is.",
			Shovel = "Digs dirt, sand and gravel faster.",
			Pickaxe = "Mines anything, even obsidian.",
			Axe = "Chops wood faster. Hits hard, but slowly.",
			Hoe = "Clears leaves and moss quickly.",
		},
		icons = { Sword = "", Shovel = "", Pickaxe = "", Axe = "", Hoe = "" },
		age = "industrial",
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
		icon = "",
		lore = "Harvests leaves, grass and cobwebs as they are.",
		age = "iron",
	})
	return list
end

--!strict
--[[
	Tough As Nails' gear for the cold and the heat (Shared/ToughAsNails/Temperature; the Campfire is
	a block, blocks/campfire).

	  * Straw: what Short Grass and Tall Grass give when broken without Shears now and then
	    (Items.strawDrop: Minecraft's grass drops wheat seeds there, and the game has no wheat), a
	    golden bundle tied in the middle, modelled upright and tilted like a stick.
	  * Straw and Leaf armor (Content/Define's `armorSet`): insulation for the climate (`tan`), with
	    leather's armor points (1 / 3 / 2 / 1, no toughness; this game's armor doesn't wear, so it
	    has no durability either). Straw (crafted from Straw in the armor shapes) warms a step a
	    piece, so a full set holds the coldest target (-10, a tundra day or night, the clamp of the
	    scale) at -6, cold but out of ICY, and three pieces at -7; Leaf armor (from any leaves, which
	    Shears harvest) cools a step a piece, so a desert's 9 by day becomes 5, warm, and the
	    hottest target (10, sprinting by lava) 6. Neither is freeze immune (leather is) and neither
	    does anything on the other side of neutral (insulation only pulls towards 0). They sound
	    like leather when put on (`equipSound`).
	  * Thermometer (TAN's): while it is the held item, the HUD reads out the body temperature and
	    where it is going in the item-in-hands box over the quickbar (client Ui/Hud). A glass tube
	    on an iron plate with a red bulb; an iron nugget over glass over glow dust (the game's
	    redstone) makes it, from the Iron Age.
	Their icons are blank, so each look is one id to paste.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

local STRAW = { 214, 184, 98 }
local IRON = { 222, 222, 224 }
local THERMOMETER_RED = { 222, 52, 40 }

local INSULATING_ARMOR: { Define.ArmorMaterial } = {
	{
		name = "Straw",
		color = STRAW,
		material = "Fabric",
		points = { 1, 3, 2, 1 },
		toughness = 0,
		tan = { warmth = 1 },
		lore = "Woven straw: warm, but flimsy.",
		icon = "",
		equipSound = "item.armor.equip_leather",
	},
	{
		name = "Leaf",
		color = { 64, 128, 46 },
		material = "LeafyGrass",
		points = { 1, 3, 2, 1 },
		toughness = 0,
		tan = { cooling = 1 },
		lore = "Woven leaves keep you cool in the heat.",
		icon = "",
		equipSound = "item.armor.equip_leather",
	},
}

return function(define: Define.Context): { Schema.ItemSpec }
	local shade = define.shade
	local list: { Schema.ItemSpec } = {
		{
			name = "Straw",
			color = STRAW,
			material = "Fabric",
			model = {
				{ size = { 6, 13, 3 }, offset = { 0, -0.5, 0 } },
				{ size = { 1, 14, 3.2 }, offset = { -2, 0, 0 }, color = shade(STRAW, 1.15) },
				{ size = { 1, 14, 3.2 }, offset = { 1.5, 0, 0 }, color = shade(STRAW, 0.82) },
				{ size = { 1.2, 5, 2.6 }, offset = { -3.6, 6.2, 0 }, rotation = 22 },
				{ size = { 1.2, 5, 2.6 }, offset = { 3.6, 6.2, 0 }, rotation = -22, color = shade(STRAW, 0.9) },
				{ size = { 7, 2, 3.6 }, offset = { 0, -1, 0 }, color = { 142, 104, 52 } },
			},
			tilt = -45,
			icon = "",
			lore = "From grass broken by hand. Makes straw armor and rope.",
		},
	}
	for _, armor in INSULATING_ARMOR do
		define.append(list, define.armorSet(armor))
	end
	table.insert(list, {
		name = "Thermometer",
		maxStack = 1,
		color = THERMOMETER_RED,
		material = "Glass",
		model = {
			{ size = { 5, 15, 1 }, offset = { 0, 0.5, -0.8 }, color = IRON, material = "Metal" },
			{ size = { 2.4, 11, 2 }, offset = { 0, 2, 0.4 }, color = define.GLASS },
			{ size = { 1, 7, 0.4 }, offset = { 0, 0, 1.5 }, material = "Neon" },
			{ size = { 4.5, 4.5, 4.5 }, offset = { 0, -5, 0.4 }, shape = "Ball" },
			{ size = { 2.8, 1.2, 2.4 }, offset = { 0, 7.8, 0.4 }, color = IRON, material = "Metal" },
			{ size = { 1.2, 0.5, 0.4 }, offset = { -1.9, 5, -0.1 }, color = { 60, 60, 66 } },
			{ size = { 1.2, 0.5, 0.4 }, offset = { -1.9, 2.5, -0.1 }, color = { 60, 60, 66 } },
			{ size = { 1.2, 0.5, 0.4 }, offset = { -1.9, 0, -0.1 }, color = { 60, 60, 66 } },
		},
		icon = "",
		lore = "Hold it to read the temperature around you.",
		age = "iron",
	})
	return list
end

--!strict
--[[
	Minecraft's crafting materials: the stick, coal and charcoal, raw iron and raw gold (what their
	ores drop), the iron and gold ingots and nuggets, diamonds, emeralds and snowballs (what snow
	drops: four make a block of it). Pixel boxes in their colours (Content/Define's lump, ingot and
	nugget for the ores' and metals').
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

local COAL = { 34, 34, 38 }
local CHARCOAL = { 58, 46, 36 }
local RAW_IRON = { 196, 160, 128 }
local RAW_GOLD = { 232, 180, 50 }
local IRON = { 222, 222, 224 }
local GOLD = { 250, 213, 58 }
local DIAMOND = { 90, 236, 227 }
local EMERALD = { 40, 210, 90 }

return function(define: Define.Context): { Schema.ItemSpec }
	local shade, lump, ingot, nugget = define.shade, define.lump, define.ingot, define.nugget
	return {
		{
			name = "Stick",
			color = define.HANDLE,
			material = "Wood",
			model = {
				{ size = { 1.5, 16, 1.5 }, offset = { 0, 0, 0 } },
				{ size = { 0.5, 15, 1.6 }, offset = { -0.45, 0.25, 0 }, color = shade(define.HANDLE, 1.3) },
			},
			tilt = -45,
		},
		{
			name = "Coal",
			color = COAL,
			material = "Slate",
			model = lump(COAL, { 82, 82, 88 }, { 14, 14, 16 }),
		},
		{
			name = "Charcoal",
			color = CHARCOAL,
			material = "Slate",
			model = lump(CHARCOAL, { 102, 84, 66 }, { 30, 24, 18 }),
		},
		{
			name = "RawIron",
			color = RAW_IRON,
			material = "Rock",
			model = lump(RAW_IRON, { 228, 200, 174 }, { 146, 112, 86 }),
		},
		{
			name = "RawGold",
			color = RAW_GOLD,
			material = "Rock",
			model = lump(RAW_GOLD, { 252, 228, 122 }, { 180, 126, 28 }),
		},
		{ name = "IronIngot", color = IRON, material = "Metal", model = ingot(IRON), tilt = 25 },
		{ name = "GoldIngot", color = GOLD, material = "Metal", model = ingot(GOLD), tilt = 25 },
		{ name = "IronNugget", color = IRON, material = "Metal", model = nugget(IRON) },
		{ name = "GoldNugget", color = GOLD, material = "Metal", model = nugget(GOLD) },
		-- A cut gem: a wide crown with its table, a pointed pavilion and a glint.
		{
			name = "Diamond",
			color = DIAMOND,
			material = "Glass",
			model = {
				{ size = { 10, 3, 3 }, offset = { 0, 2.5, 0 } },
				{ size = { 6, 1, 2.5 }, offset = { 0, 4.5, 0 }, color = shade(DIAMOND, 1.15) },
				{ size = { 7.07, 7.07, 3 }, offset = { 0, -0.5, 0 }, rotation = 45, color = shade(DIAMOND, 0.75) },
				{ size = { 2, 2, 0.5 }, offset = { -2.5, 2.5, 1.6 }, color = { 225, 255, 252 } },
			},
		},
		-- An upright octagonal gem with darker bevels and a light centre.
		{
			name = "Emerald",
			color = EMERALD,
			material = "Glass",
			model = {
				{ size = { 6, 9, 3 }, offset = { 0, 0, 0 } },
				{ size = { 4, 1, 3 }, offset = { 0, 5, 0 } },
				{ size = { 4, 1, 3 }, offset = { 0, -5, 0 } },
				{ size = { 1, 7, 3 }, offset = { -3.5, 0, 0 }, color = shade(EMERALD, 0.7) },
				{ size = { 1, 7, 3 }, offset = { 3.5, 0, 0 }, color = shade(EMERALD, 0.7) },
				{ size = { 2, 6, 0.5 }, offset = { -0.5, 0.5, 1.6 }, color = { 150, 250, 172 } },
			},
		},
		{
			name = "Snowball",
			maxStack = 16,
			color = { 240, 245, 250 },
			material = "Snow",
			model = {
				{ size = { 8, 8, 8 }, offset = { 0, 0, 0 }, shape = "Ball" },
				{ size = { 4, 4, 4 }, offset = { 1.75, 1.75, 1.5 }, shape = "Ball", color = { 255, 255, 255 } },
			},
		},
	}
end

--!strict
--[[
	The mineshafts' chests' loot table (mineshaft; Generation/Mineshafts rolls it, ScavengeLoot's
	format: pools of { rolls = { min, max }, entries = { { item | false, weight, fewest, most } } }).

	Minecraft's chests/abandoned_mineshaft on this game's items. Pool 1: the golden apples, name tag
	and enchanted book are left out (nothing). Pool 2: redstone -> raw iron, lapis -> raw gold, bread
	-> cooked porkchop, glow berries -> glow dust, the three seeds -> mint leaves, ginger root and
	straw (the Survival pack's). Pool 3: the powered, detector and activator rails -> nothing, and
	Supplementaries' rope. Pool 4 is Terraria's underground chest find (one roll, after the others
	so they roll as before; the items are the Terraria pack's, the table one): an accessory in
	about 3 chests of 10 (Hermes Boots, Cloud in a Bottle, Band of Regeneration, Shiny Red Balloon,
	Lucky Horseshoe, Flipper, Cobalt Shield), a Wand of Sparking or Water Bolt, or Lesser Mana
	Potions; nothing in more than half.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	mineshaft = {
		{ rolls = { 1, 1 }, entries = { { "IronPickaxe", 5, 1, 1 }, { false, 66, 0, 0 } } },
		{
			rolls = { 2, 4 },
			entries = {
				{ "IronIngot", 10, 1, 5 },
				{ "GoldIngot", 5, 1, 3 },
				{ "RawIron", 5, 2, 5 },
				{ "RawGold", 5, 1, 3 },
				{ "Diamond", 3, 1, 2 },
				{ "Coal", 10, 3, 8 },
				{ "CookedPorkchop", 15, 1, 3 },
				{ "GlowDust", 15, 2, 4 },
				{ "MintLeaves", 10, 2, 4 },
				{ "GingerRoot", 10, 2, 4 },
				{ "Straw", 10, 2, 4 },
			},
		},
		{
			rolls = { 3, 3 },
			entries = { { "Rail", 20, 4, 8 }, { "Torch", 15, 1, 16 }, { "Rope", 10, 4, 8 }, { false, 15, 0, 0 } },
		},
		{
			rolls = { 1, 1 },
			entries = {
				{ false, 60, 0, 0 },
				{ "HermesBoots", 6, 1, 1 },
				{ "CloudInABottle", 7, 1, 1 },
				{ "BandOfRegeneration", 6, 1, 1 },
				{ "ShinyRedBalloon", 3, 1, 1 },
				{ "LuckyHorseshoe", 3, 1, 1 },
				{ "Flipper", 4, 1, 1 },
				{ "CobaltShield", 2, 1, 1 },
				{ "WandOfSparking", 6, 1, 1 },
				{ "WaterBolt", 2, 1, 1 },
				{ "LesserManaPotion", 6, 1, 2 },
			},
		},
	},
} :: { [string]: { Schema.Pool } }

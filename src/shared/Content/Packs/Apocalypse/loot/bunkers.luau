--!strict
--[[
	The bunkers' loot tables (Generation/Bunkers fills their rooms with them, by name:
	bunker_storage, bunker_medical, bunker_armory, bunker_generator; ScavengeLoot's format and
	rolls). Antibiotics are in the medical room; the armory holds the bunkers' firearms (worn),
	ammunition and magazines, the storerooms more ammunition.
]]

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return {
	bunker_storage = {
		{
			rolls = { 3, 6 },
			entries = {
				{ "CannedBeans", 12, 2, 4 },
				{ "MilitaryRation", 10, 1, 3 },
				{ "BottledWater", 12, 2, 4 },
				{ "PurifiedWaterCanteen", 3, 1, 1 },
				{ "Torch", 6, 4, 8 },
				{ "Coal", 6, 4, 8 },
				{ "Gunpowder", 6, 2, 6 },
				{ "Rope", 4, 2, 6 },
				{ "DuctTape", 4, 1, 2 },
				{ "Nails", 4, 4, 12 },
				{ "IronIngot", 4, 1, 3 },
				{ "Rounds9mm", 4, 6, 20 },
				{ "Rounds556", 3, 6, 20 },
				{ "Buckshot", 3, 4, 10 },
				{ "Rounds22", 3, 10, 30 },
				{ false, 6, 0, 0 },
			},
		},
	},
	bunker_medical = {
		{
			rolls = { 2, 4 },
			entries = {
				{ "Medkit", 8, 1, 2 },
				{ "Bandage", 12, 2, 4 },
				{ "Antibiotics", 8, 1, 2 },
				{ "Painkillers", 10, 1, 3 },
				{ "PotionOfHealing", 2, 1, 1 },
				{ "PotionOfRegeneration", 1, 1, 1 },
				{ false, 6, 0, 0 },
			},
		},
	},
	bunker_armory = {
		{
			rolls = { 2, 4 },
			entries = {
				{ "Machete", 6, 1, 1 },
				{ "FireAxe", 3, 1, 1 },
				{ "Crowbar", 4, 1, 1 },
				{ "IronSword", 4, 1, 1 },
				{ "IronHelmet", 3, 1, 1 },
				{ "IronChestplate", 3, 1, 1 },
				{ "IronLeggings", 3, 1, 1 },
				{ "IronBoots", 3, 1, 1 },
				{ "Gunpowder", 10, 4, 10 },
				{ "Tnt", 3, 1, 2 },
				{ "CobaltShield", 1, 1, 1 },
				{ "FeralClaws", 2, 1, 1 },
				{ false, 6, 0, 0 },
			},
		},
		{
			rolls = { 1, 3 },
			entries = {
				{ "AssaultRifle", 3, 1, 1, { 0.1, 0.5 } },
				{ "RifleMagazine", 6, 1, 1 },
				{ "Rounds556", 10, 10, 30 },
				{ "Smg", 3, 1, 1, { 0.1, 0.5 } },
				{ "SmgMagazine", 4, 1, 1 },
				{ "Rounds9mm", 6, 10, 30 },
				{ "BoltActionRifle", 2, 1, 1, { 0.1, 0.5 } },
				{ "SemiAutoRifle", 2, 1, 1, { 0.1, 0.5 } },
				{ "Rounds762", 6, 5, 20 },
				{ "HuntingRifle", 1, 1, 1, { 0.1, 0.4 } },
				{ "HuntingMagazine", 2, 1, 1 },
				{ "Rounds308", 3, 5, 15 },
				{ "Suppressor", 2, 1, 1 },
				{ "RedDotSight", 3, 1, 1 },
				{ "RifleScope", 2, 1, 1 },
				{ "WeaponFlashlight", 2, 1, 1 },
				{ "Slugs", 2, 3, 8 },
				{ false, 8, 0, 0 },
			},
		},
	},
	bunker_generator = {
		{
			rolls = { 2, 4 },
			entries = {
				{ "Coal", 10, 4, 12 },
				{ "CoalBlock", 2, 1, 1 },
				{ "FuelBucket", 3, 1, 1 },
				{ "OilBucket", 2, 1, 1 },
				{ "ScrapMetal", 8, 2, 5 },
				{ "IronIngot", 4, 1, 2 },
				{ "Bucket", 3, 1, 1 },
				{ false, 6, 0, 0 },
			},
		},
	},
} :: { [string]: { Schema.Pool } }

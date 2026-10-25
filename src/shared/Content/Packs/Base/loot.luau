--!strict
--[[
	The Base pack's loot tables (ScavengeLoot's and the mineshafts', moved here unchanged): table
	name -> pools of { rolls = { min, max }, entries = { { item | false, weight, min, max, wear? } } }
	(Generation/ScavengeLoot's header says how they roll). The ruins' and the bunkers' (house,
	grocery, pharmacy, medicine_cabinet, hardware, police, fire_station, office, car;
	bunker_storage, bunker_medical, bunker_armory, bunker_generator), whose names their generators
	give, and the mineshafts' chests' (mineshaft).

	The ruins and bunkers: antibiotics are in the pharmacy, medicine cabinet, house (rare) and bunker
	medical tables; Gunpowder, String, Bone and Feral Claws, which the removed monsters once dropped,
	are here too. Weapons (Shared/Weapons, in the manner of DayZ): firearms are rare (the police's
	own pool, the bunker armory's, and a few hunting and home-defence guns in houses) and come worn,
	ammunition and magazines are commoner (houses, cars, police, bunker storerooms and armories),
	melee weapons common (houses, groceries, hardware, fire stations, cars). Guns and magazines come
	empty (no item data): no magazine in, no rounds. Nothing makes a gun or a round but the
	crossbow's bolts.

	The mineshafts' (mineshaft):
	Minecraft's chests/abandoned_mineshaft on this game's items: { item (false: nothing), weight,
	fewest, most } per entry. Pool 1: the golden apples, name tag and enchanted book are left out
	(nothing). Pool 2: redstone -> raw iron, lapis -> raw gold, bread -> cooked porkchop, glow
	berries -> glow dust, the three seeds -> mint leaves, ginger root and straw. Pool 3: the
	powered, detector and activator rails -> nothing, and Supplementaries' rope. Pool 4 is
	Terraria's underground chest find (one roll, after the others so they roll as before): an
	accessory in about 3 chests of 10 (Hermes Boots, Cloud in a Bottle, Band of Regeneration,
	Shiny Red Balloon, Lucky Horseshoe, Flipper, Cobalt Shield), a Wand of Sparking or Water Bolt,
	or Lesser Mana Potions; nothing in more than half.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	house = {
		{
			rolls = { 1, 3 },
			entries = {
				{ "CannedBeans", 10, 1, 2 },
				{ "CannedPeaches", 8, 1, 2 },
				{ "Crackers", 10, 1, 3 },
				{ "ChocolateBar", 6, 1, 2 },
				{ "BottledWater", 8, 1, 2 },
				{ "SodaCan", 6, 1, 2 },
				{ "RottenFlesh", 4, 1, 3 },
				{ false, 20, 0, 0 },
			},
		},
		{
			rolls = { 0, 2 },
			entries = {
				{ "Rag", 10, 1, 4 },
				{ "String", 6, 1, 3 },
				{ "Torch", 8, 2, 6 },
				{ "Bandage", 5, 1, 2 },
				{ "Painkillers", 2, 1, 1 },
				{ "Nails", 4, 2, 8 },
				{ "DuctTape", 3, 1, 1 },
				{ "Coal", 4, 1, 4 },
				{ "Stick", 6, 2, 6 },
				{ "GlassBottle", 4, 1, 2 },
				{ "Rounds9mm", 2, 3, 8 },
				{ "Buckshot", 2, 2, 6 },
				{ "Rounds22", 2, 5, 15 },
				{ "CrossbowBolt", 1, 2, 6 },
				{ false, 20, 0, 0 },
			},
		},
		{
			rolls = { 0, 1 },
			entries = {
				{ "Antibiotics", 2, 1, 1 },
				{ "BaseballBat", 2, 1, 1 },
				{ "Crowbar", 1, 1, 1 },
				{ "IronIngot", 2, 1, 2 },
				{ "Bone", 3, 1, 3 },
				{ "FeralClaws", 1, 1, 1 },
				{ "KitchenKnife", 4, 1, 1, { 0, 0.5 } },
				{ "HuntingKnife", 1, 1, 1 },
				{ "DoubleBarrelShotgun", 1, 1, 1, { 0.2, 0.7 } },
				{ "SmallBoreRifle", 1, 1, 1, { 0.2, 0.7 } },
				{ "Revolver", 1, 1, 1, { 0.2, 0.7 } },
				{ "Crossbow", 1, 1, 1, { 0.1, 0.6 } },
				{ false, 40, 0, 0 },
			},
		},
	},
	grocery = {
		{
			rolls = { 2, 5 },
			entries = {
				{ "CannedBeans", 12, 1, 3 },
				{ "CannedPeaches", 10, 1, 2 },
				{ "Crackers", 12, 1, 4 },
				{ "ChocolateBar", 10, 1, 3 },
				{ "BottledWater", 12, 1, 3 },
				{ "SodaCan", 10, 1, 3 },
				{ false, 10, 0, 0 },
			},
		},
		{
			rolls = { 0, 1 },
			entries = { { "Rag", 4, 1, 2 }, { "Torch", 4, 2, 4 }, { "KitchenKnife", 1, 1, 1 }, { false, 12, 0, 0 } },
		},
	},
	pharmacy = {
		{
			rolls = { 2, 4 },
			entries = {
				{ "Bandage", 12, 1, 3 },
				{ "Painkillers", 10, 1, 2 },
				{ "Antibiotics", 5, 1, 1 },
				{ "Medkit", 3, 1, 1 },
				{ "Rag", 6, 1, 3 },
				{ "BottledWater", 4, 1, 2 },
				{ "PotionOfHealing", 1, 1, 1 },
				{ false, 10, 0, 0 },
			},
		},
	},
	medicine_cabinet = {
		{
			rolls = { 1, 3 },
			entries = {
				{ "Bandage", 10, 1, 2 },
				{ "Painkillers", 8, 1, 1 },
				{ "Antibiotics", 2, 1, 1 },
				{ "Rag", 6, 1, 2 },
				{ false, 20, 0, 0 },
			},
		},
	},
	hardware = {
		{
			rolls = { 2, 5 },
			entries = {
				{ "Nails", 12, 4, 12 },
				{ "DuctTape", 8, 1, 2 },
				{ "ScrapMetal", 8, 1, 4 },
				{ "IronNugget", 6, 2, 6 },
				{ "Crowbar", 3, 1, 1 },
				{ "IronAxe", 2, 1, 1 },
				{ "IronShovel", 2, 1, 1 },
				{ "Planks", 6, 4, 16 },
				{ "Glass", 4, 2, 8 },
				{ "Torch", 6, 2, 6 },
				{ "Lantern", 2, 1, 1 },
				{ "Rope", 4, 2, 6 },
				{ "Ladder", 3, 2, 6 },
				{ "Barricade", 3, 1, 2 },
				{ "PipeWrench", 3, 1, 1 },
				{ "Sledgehammer", 2, 1, 1 },
				{ "HuntingKnife", 2, 1, 1 },
				{ false, 8, 0, 0 },
			},
		},
	},
	police = {
		{
			rolls = { 1, 3 },
			entries = {
				{ "BaseballBat", 4, 1, 1 },
				{ "Crowbar", 3, 1, 1 },
				{ "Machete", 2, 1, 1 },
				{ "Gunpowder", 6, 1, 4 },
				{ "IronIngot", 4, 1, 3 },
				{ "Bandage", 6, 1, 2 },
				{ "Medkit", 2, 1, 1 },
				{ "IronHelmet", 1, 1, 1 },
				{ "ChainmailChestplate", 1, 1, 1 },
				{ "CobaltShield", 1, 1, 1 },
				{ "FeralClaws", 1, 1, 1 },
				{ false, 10, 0, 0 },
			},
		},
		{
			rolls = { 0, 2 },
			entries = {
				{ "Pistol", 4, 1, 1, { 0.1, 0.6 } },
				{ "PistolMagazine", 5, 1, 1 },
				{ "Rounds9mm", 10, 6, 20 },
				{ "Revolver", 2, 1, 1, { 0.1, 0.6 } },
				{ "Rounds357", 4, 4, 12 },
				{ "PumpShotgun", 2, 1, 1, { 0.1, 0.6 } },
				{ "Buckshot", 6, 4, 10 },
				{ "Slugs", 3, 3, 8 },
				{ "WeaponFlashlight", 2, 1, 1 },
				{ false, 18, 0, 0 },
			},
		},
	},
	fire_station = {
		{
			rolls = { 1, 3 },
			entries = {
				{ "FireAxe", 4, 1, 1 },
				{ "Bandage", 6, 1, 2 },
				{ "Medkit", 3, 1, 1 },
				{ "BottledWater", 6, 1, 3 },
				{ "LeatherBoots", 2, 1, 1 },
				{ "Rope", 4, 2, 6 },
				{ "WaterBucket", 2, 1, 1 },
				{ "Sledgehammer", 2, 1, 1 },
				{ false, 10, 0, 0 },
			},
		},
	},
	office = {
		{
			rolls = { 1, 2 },
			entries = {
				{ "Crackers", 6, 1, 2 },
				{ "ChocolateBar", 6, 1, 2 },
				{ "SodaCan", 6, 1, 2 },
				{ "Rag", 4, 1, 2 },
				{ "DuctTape", 2, 1, 1 },
				{ "String", 3, 1, 2 },
				{ false, 20, 0, 0 },
			},
		},
	},
	car = {
		{
			rolls = { 1, 2 },
			entries = {
				{ "Rag", 6, 1, 2 },
				{ "SodaCan", 6, 1, 2 },
				{ "Crackers", 5, 1, 2 },
				{ "ChocolateBar", 5, 1, 2 },
				{ "ScrapMetal", 6, 1, 3 },
				{ "Bandage", 3, 1, 1 },
				{ "Painkillers", 2, 1, 1 },
				{ "BottledWater", 4, 1, 1 },
				{ "FuelBucket", 1, 1, 1 },
				{ "Rounds9mm", 2, 2, 6 },
				{ "PipeWrench", 1, 1, 1 },
				{ false, 15, 0, 0 },
			},
		},
	},
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

--!strict
--[[
	The ruins' loot tables (Generation/ScavengeLoot rolls them into the cities' crates, cabinets and
	cars, by the names their generators give: house, grocery, pharmacy, medicine_cabinet, hardware,
	police, fire_station, office, car): pools of { rolls = { min, max }, entries = { { item | false,
	weight, min, max, wear? } } } (ScavengeLoot's header says how they roll).

	Antibiotics are in the pharmacy, the medicine cabinet and (rarely) houses; Gunpowder, String,
	Bone and Feral Claws (the Terraria pack's), which the removed monsters once dropped, are here
	too. Weapons (in the manner of DayZ): firearms are rare (the police's own pool, and a few
	hunting and home-defence guns in houses) and come worn, ammunition and magazines are commoner
	(houses, cars, police), melee weapons common (houses, groceries, hardware, fire stations, cars).
	Guns and magazines come empty (no item data): no magazine in, no rounds. Nothing makes a gun or
	a round but the crossbow's bolts.
]]

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

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
} :: { [string]: { Schema.Pool } }

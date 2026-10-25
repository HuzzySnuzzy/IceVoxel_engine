--!strict
--[[
	Turrets, the Metal Miner and the Ammo Press (Shared/Turrets, Config.Turrets / Miner / AmmoPress;
	their entries' Ages: the parts, the Laser Sight, the Basic, Advanced and Elite turrets, the
	Metal Miner and the Ammo Press are the Electric Age's, the Ultimate turrets the Atomic Age's).
	Each feature's recipes are left out when its `Enabled` is false (its blocks and items stay
	registered, with no Age), the Servo Motor's only when neither turrets nor the press take it:
	  Servo Motor       iron over osmium round a Universal Cable, iron below: two
	  Belt Feeder       leather over iron nuggets round an iron ingot
	  Receiver          iron over an osmium ingot, Nails and Scrap Metal
	  Targeting Module  glass over glow dust round an osmium ingot, a Universal Cable below
	  Barrels           SMG three iron; rifle three iron over three osmium; sniper three osmium
	                    over diamonds round an iron ingot
	  Laser Sight       iron, glow dust and glass over three iron nuggets
	  Turrets           the Basic of a type from its barrel over a servo, a receiver and a belt
	                    feeder over osmium round a targeting module; each next tier round the one
	                    below (Mekanism's tier shape): the alloys (gold, diamond, emerald, as the
	                    transmitters' upgrades) in the corners, a barrel over it, servos beside it,
	                    a targeting module under it, keeping its data (`keep`: its energy and its
	                    Lure, as a Battery keeps its charge)
	  Metal Miner       osmium round a Universal Cable over iron blocks round an Electric Furnace
	                    over diamonds round a Diamond Pickaxe
	  Ammo Press        iron round a servo over osmium round an Electric Furnace over iron round
	                    a Block of Iron
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)

local TIER_NAMES = { "Basic", "Advanced", "Elite", "Ultimate" }
local ALLOYS = { "GoldIngot", "Diamond", "Emerald" }

return function(define: Define.Context): { Schema.Recipe }
	local Config = define.Config
	local shaped = define.shaped
	local list: { Schema.Recipe } = {}
	local function add(recipe: Schema.Recipe)
		table.insert(list, recipe)
	end
	local turrets = Config.Turrets.Enabled
	if turrets or Config.AmmoPress.Enabled then
		add(
			shaped(
				{ " I ", "OCO", " I " },
				{ I = "IronIngot", O = "OsmiumIngot", C = "BasicUniversalCable" },
				"ServoMotor",
				2
			)
		)
	end
	if turrets then
		add(shaped({ "LLL", "NIN" }, { L = "Leather", N = "IronNugget", I = "IronIngot" }, "BeltFeeder"))
		add(shaped({ "III", "ONS" }, { I = "IronIngot", O = "OsmiumIngot", N = "Nails", S = "ScrapMetal" }, "Receiver"))
		add(
			shaped(
				{ " G ", "DOD", " C " },
				{ G = "Glass", D = "GlowDust", O = "OsmiumIngot", C = "BasicUniversalCable" },
				"TargetingModule"
			)
		)
		add(shaped({ "III" }, { I = "IronIngot" }, "SmgBarrel"))
		add(shaped({ "III", "OOO" }, { I = "IronIngot", O = "OsmiumIngot" }, "RifleBarrel"))
		add(shaped({ "OOO", "DID" }, { O = "OsmiumIngot", D = "Diamond", I = "IronIngot" }, "SniperBarrel"))
		add(shaped({ "IDG", "NNN" }, { I = "IronIngot", D = "GlowDust", G = "Glass", N = "IronNugget" }, "LaserSight"))
		for _, kind in { "Smg", "Rifle", "Sniper" } do
			local barrel = `{kind}Barrel`
			add(shaped({ " K ", "SRF", "OMO" }, {
				K = barrel,
				S = "ServoMotor",
				R = "Receiver",
				F = "BeltFeeder",
				O = "OsmiumIngot",
				M = "TargetingModule",
			}, `Basic{kind}Turret`))
			for tier = 2, 4 do
				add(shaped({ "AKA", "STS", "AMA" }, {
					A = ALLOYS[tier - 1],
					K = barrel,
					S = "ServoMotor",
					T = `{TIER_NAMES[tier - 1]}{kind}Turret`,
					M = "TargetingModule",
				}, `{TIER_NAMES[tier]}{kind}Turret`, 1, "T"))
			end
		end
	end
	if Config.Miner.Enabled then
		add(shaped({ "OCO", "IEI", "DPD" }, {
			O = "OsmiumIngot",
			C = "BasicUniversalCable",
			I = "IronBlock",
			E = "ElectricFurnace",
			D = "Diamond",
			P = "DiamondPickaxe",
		}, "MetalMiner"))
	end
	if Config.AmmoPress.Enabled then
		add(
			shaped(
				{ "ISI", "OEO", "IBI" },
				{ I = "IronIngot", S = "ServoMotor", O = "OsmiumIngot", E = "ElectricFurnace", B = "IronBlock" },
				"AmmoPress"
			)
		)
	end
	return list
end

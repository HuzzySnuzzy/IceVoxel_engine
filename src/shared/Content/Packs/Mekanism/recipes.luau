--!strict
--[[
	Mekanism's recipes: osmium's storage blocks and smelting as Mekanism has them, and its
	transmitters, fluid tanks, Configurator, Universal Cables, machines, upgrade cards and energy
	cubes adapted to the game's materials, and the Oil Refinery and Combustion Generator
	(BuildCraft's machines made Mekanism's). Mekanism's own recipes need steel, control circuits
	(osmium infused with redstone) and alloys, made in machines this game does not have, so they
	are adapted:

	  * Basic Logistical Transporter x 8: iron, glass, iron in a row (Mekanism: steel, a basic
	    control circuit, steel).
	  * Basic Mechanical Pipe x 8: iron, a bucket, iron (Mekanism: steel, a bucket, steel).
	  * Restrictive Transporter x 2: a basic transporter between two iron ingots (Mekanism: between
	    two iron bars).
	  * Upgrades, Mekanism's shape: 8 transporters or pipes around an alloy make 8 of the next
	    tier. A gold ingot stands for the infused alloy (Advanced), a diamond for the reinforced
	    alloy (Elite) and an emerald for the atomic alloy (Ultimate).
	  * Basic Fluid Tank: iron at the corners, glass at the sides and an empty middle (Mekanism's
	    needs a control circuit and alloys). The next tiers put the tank below them in the middle
	    of 4 gold ingots / diamonds / emeralds, standing for the alloys again.
	  * Configurator: glow dust over a stick between two iron ingots, a stick below, after
	    Mekanism's " L ", "AEA", " S " (lapis lazuli over an energy tablet between two infused
	    alloys, a stick below).
	  * Universal Cables: Mekanism makes 8 Basic Universal Cables from steel, redstone and steel in
	    a row; osmium ingots stand for the steel (Mekanism's steel is made with osmium's help) and
	    glow dust for the redstone, which the game has neither of. The upgrades are Mekanism's
	    shape, as for transporters and pipes: 8 cables around an alloy make 8 of the next tier.
	  * Mekanism Generators' Heat Generator, in Mekanism's shape: three iron ingots over planks, an
	    osmium ingot and planks, over copper, a furnace and copper ("III", "WOW", "CFC"); iron
	    ingots stand for the copper (the Ores pack's copper came later).
	  * Mekanism's Energized Smelter (the Electric Furnace), in Mekanism's shape: redstone, a basic
	    control circuit and redstone, over glass, a steel casing and glass, over redstone, a circuit
	    and redstone ("RCR", "GSG", "RCR"). Glow dust stands for the redstone (as in the cables),
	    osmium ingots for the circuits (Mekanism's are osmium and redstone) and a furnace for the
	    casing, the machine it builds on.
	  * Mekanism's upgrade cards, in Mekanism's shape: glass over an alloy, a dust and an alloy,
	    over glass (" G ", "ADA", " G "), the dust osmium's for the Speed Upgrade and gold's for the
	    Energy Upgrade. The game has neither dusts nor Mekanism's infused alloy, so the ingots stand
	    for the dusts and gold ingots for the alloy (as in the transmitter upgrades).
	  * Mekanism Generators' Solar Generator (the Solar Panel), in Mekanism's shape: three solar
	    panels over an alloy, an iron ingot and an alloy, over osmium dust, an energy tablet and
	    osmium dust ("SSS", "AIA", "PEP"). Glass stands for the solar panels, gold ingots for the
	    infused alloy, osmium ingots for the dust and glow dust for the energy tablet.
	  * Mekanism's Energy Cubes (the Batteries), in Mekanism's shape: an alloy, an energy tablet and
	    an alloy, over an ingot, the casing or the tier below and an ingot, over the top row again
	    ("ATA", "IPI", "ATA"; redstone for the Basic's alloy). Glow dust stands for the redstone,
	    the Glow Block for the energy tablet, a block of iron for the steel casing, and gold
	    ingots, diamonds and emeralds for the alloys; the ingots are Mekanism's: iron, osmium, gold
	    and a diamond. A tier crafted around the tier below keeps its charge (`keep`, Mekanism's
	    MekDataShapedRecipe).
	  * The Oil Refinery, Mekanism's machine shape around BuildCraft's refinery: iron, glass and
	    iron (its sight glass) over osmium, a furnace and osmium (the heater in a casing) over iron,
	    a bucket and iron (its fluid outlet) ("IGI", "OFO", "IBI").
	  * The Combustion Generator, Mekanism's generator shape around BuildCraft's combustion engine:
	    osmium, a bucket (the fuel inlet) and osmium, over iron, a furnace (the combustion chamber)
	    and iron, over osmium, glow dust and osmium (the power out) ("OBO", "IFI", "ODO").
	  * Osmium: 9 nuggets <-> an ingot, 9 ingots <-> a block, 9 raw <-> a raw block; Raw Osmium and
	    Osmium Ore smelt into an ingot (OsmiumIngotFromRawOsmium, OsmiumIngotFromOsmiumOre: a
	    recipe's name is its result's unless it gives one, and the nuggets' recipe has the ingot's).
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)

local TIER_NAMES = { "Basic", "Advanced", "Elite", "Ultimate" }
local ALLOYS = { "GoldIngot", "Diamond", "Emerald" }
local BATTERY_INGOTS = { "OsmiumIngot", "GoldIngot", "Diamond" }

return function(define: Define.Context): { Schema.Recipe }
	local shaped, smelting = define.shaped, define.smelting
	local list: { Schema.Recipe } = {}
	local function add(recipe: Schema.Recipe)
		table.insert(list, recipe)
	end

	-- Osmium's storage blocks.
	define.append(list, define.storage("OsmiumNugget", "OsmiumIngot"))
	define.append(list, define.storage("OsmiumIngot", "OsmiumBlock"))
	define.append(list, define.storage("RawOsmium", "RawOsmiumBlock"))

	-- Pipes, transporters and tanks.
	add(shaped({ "IGI" }, { I = "IronIngot", G = "Glass" }, "BasicLogisticalTransporter", 8))
	add(shaped({ "IBI" }, { I = "IronIngot", B = "Bucket" }, "BasicMechanicalPipe", 8))
	add(shaped({ "ITI" }, { I = "IronIngot", T = "BasicLogisticalTransporter" }, "RestrictiveTransporter", 2))
	add(shaped({ "IGI", "G G", "IGI" }, { I = "IronIngot", G = "Glass" }, "BasicFluidTank"))
	for tier = 2, 4 do
		local lower, name, alloy = TIER_NAMES[tier - 1], TIER_NAMES[tier], ALLOYS[tier - 1]
		for _, kind in { "LogisticalTransporter", "MechanicalPipe" } do
			add(shaped({ "TTT", "TAT", "TTT" }, { T = lower .. kind, A = alloy }, name .. kind, 8))
		end
		add(shaped({ " A ", "ATA", " A " }, { T = lower .. "FluidTank", A = alloy }, name .. "FluidTank"))
	end
	add(shaped({ " G ", "ISI", " S " }, { G = "GlowDust", I = "IronIngot", S = "Stick" }, "Configurator"))

	-- Universal Cables.
	add(shaped({ "OGO" }, { O = "OsmiumIngot", G = "GlowDust" }, "BasicUniversalCable", 8))
	for tier = 2, 4 do
		local lower, name, alloy = TIER_NAMES[tier - 1], TIER_NAMES[tier], ALLOYS[tier - 1]
		add(shaped({ "CCC", "CAC", "CCC" }, { C = lower .. "UniversalCable", A = alloy }, name .. "UniversalCable", 8))
	end

	-- Machines, upgrade cards and generators.
	add(
		shaped(
			{ "III", "WOW", "IFI" },
			{ I = "IronIngot", W = "#planks", O = "OsmiumIngot", F = "Furnace" },
			"HeatGenerator"
		)
	)
	add(
		shaped(
			{ "DOD", "GFG", "DOD" },
			{ D = "GlowDust", O = "OsmiumIngot", G = "Glass", F = "Furnace" },
			"ElectricFurnace"
		)
	)
	add(shaped({ " G ", "AOA", " G " }, { G = "Glass", A = "GoldIngot", O = "OsmiumIngot" }, "SpeedUpgrade"))
	add(shaped({ " G ", "AUA", " G " }, { G = "Glass", A = "GoldIngot", U = "GoldIngot" }, "EnergyUpgrade"))
	add(
		shaped(
			{ "GGG", "AIA", "ODO" },
			{ G = "Glass", A = "GoldIngot", I = "IronIngot", O = "OsmiumIngot", D = "GlowDust" },
			"SolarPanel"
		)
	)

	-- Batteries.
	add(
		shaped(
			{ "DTD", "ICI", "DTD" },
			{ D = "GlowDust", T = "GlowBlock", I = "IronIngot", C = "IronBlock" },
			"BasicBattery"
		)
	)
	for tier = 2, 4 do
		add(shaped({ "ATA", "IBI", "ATA" }, {
			A = ALLOYS[tier - 1],
			T = "GlowBlock",
			I = BATTERY_INGOTS[tier - 1],
			B = TIER_NAMES[tier - 1] .. "Battery",
		}, TIER_NAMES[tier] .. "Battery", 1, "B"))
	end

	-- Oil and fuel.
	add(
		shaped(
			{ "IGI", "OFO", "IBI" },
			{ I = "IronIngot", G = "Glass", O = "OsmiumIngot", F = "Furnace", B = "Bucket" },
			"OilRefinery"
		)
	)
	add(
		shaped(
			{ "OBO", "IFI", "ODO" },
			{ I = "IronIngot", B = "Bucket", O = "OsmiumIngot", F = "Furnace", D = "GlowDust" },
			"CombustionGenerator"
		)
	)

	-- Smelting osmium (named: the nuggets' recipe is "OsmiumIngot").
	add(define.named("OsmiumIngotFromRawOsmium", smelting("RawOsmium", "OsmiumIngot")))
	add(define.named("OsmiumIngotFromOsmiumOre", smelting("OsmiumOre", "OsmiumIngot")))
	return list
end

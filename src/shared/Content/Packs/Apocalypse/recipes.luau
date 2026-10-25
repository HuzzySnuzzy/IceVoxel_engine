--!strict
--[[
	The apocalypse's recipes (the pack's loot hides the rest in the ruins and bunkers: no recipe for
	the roads' asphalt and lines, rusty metal, the medicine cabinet, antibiotics, painkillers, duct
	tape, the canned and bottled food and drink, or the Fire Axe):
	  Rag                   White Wool torn into three
	  Bandage               two Rags make two
	  Medkit                two Bandages, Painkillers and Duct Tape
	  Herbal Poultice       Mint Leaves, a Ginger Root and a Rag: the renewable answer to a bite
	                        (it sets an infection back a stage; only Antibiotics cure it)
	  Nails                 two Iron Nuggets make four (an ingot is already nine nuggets)
	  Barricade             three planks over Nails make four (a barricade beats the planks it
	                        costs: zombies take 900 ticks for one, 600 for a plank)
	  Reinforced Barricade  a Barricade, two Scrap Metal and Nails
	  Baseball Bat          two logs over a Stick (logs: no clash with the wooden sword)
	  Spiked Bat            a Baseball Bat and three Nails
	  Machete               two Iron Ingots on the diagonal over a Stick
	  Crowbar               four Iron Ingots in a hook
	  Supply Crate          planks and Sticks in a ring
	  Ceiling Lamp          three Iron Nuggets round Glow Dust make two
	  Bunker Hatch          four Iron Ingots (Minecraft's iron trapdoor)
	  Concrete              Gravel and Sand on the diagonals make four
	  Mossy Concrete, Mossy Bricks   Concrete or Bricks with a Vine
	Smelting: Concrete cracks into Cracked Concrete, Bricks into Cracked Bricks, and Scrap Metal
	melts into an Iron Nugget. Progression/Ages keeps the iron ones (and the hatch and lamp) for
	the Iron Age and concrete for the Industrial Age.

	Weapons (Shared/Weapons; DayZ makes no gun, magazine or round: the ruins and bunkers hide them;
	the Turrets pack's Ammo Press presses rounds from iron and gunpowder):
	  Improvised Suppressor  a Glass Bottle and Duct Tape (it muffles a few dozen shots)
	  Crossbow Bolt          an Iron Nugget over a Stick over a Feather make four (the Iron Age's)
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)

return function(define: Define.Context): { Schema.Recipe }
	local shaped, shapeless, smelting = define.shaped, define.shapeless, define.smelting
	return {
		shapeless({ "WhiteWool" }, "Rag", 3),
		shapeless({ "Rag", "Rag" }, "Bandage", 2),
		shapeless({ "Bandage", "Bandage", "Painkillers", "DuctTape" }, "Medkit"),
		shapeless({ "MintLeaves", "GingerRoot", "Rag" }, "HerbalPoultice"),
		shapeless({ "IronNugget", "IronNugget" }, "Nails", 4),
		shaped({ "PPP", " N " }, { P = "#planks", N = "Nails" }, "Barricade", 4),
		shapeless({ "Barricade", "ScrapMetal", "ScrapMetal", "Nails" }, "ReinforcedBarricade"),
		shaped({ "L", "L", "S" }, { L = "#logs", S = "Stick" }, "BaseballBat"),
		shapeless({ "BaseballBat", "Nails", "Nails", "Nails" }, "SpikedBat"),
		shaped({ "  I", " I ", "S  " }, { I = "IronIngot", S = "Stick" }, "Machete"),
		shaped({ "II", " I", " I" }, { I = "IronIngot" }, "Crowbar"),
		shaped({ "SPS", "P P", "SPS" }, { S = "Stick", P = "#planks" }, "SupplyCrate"),
		shaped({ " N ", "NGN" }, { N = "IronNugget", G = "GlowDust" }, "CeilingLamp", 2),
		shaped({ "II", "II" }, { I = "IronIngot" }, "BunkerHatch"),
		shaped({ "GS", "SG" }, { G = "Gravel", S = "Sand" }, "Concrete", 4),
		shapeless({ "Concrete", "Vine" }, "MossyConcrete"),
		shapeless({ "Brick", "Vine" }, "MossyBricks"),
		smelting("Concrete", "CrackedConcrete"),
		smelting("Brick", "CrackedBricks"),
		smelting("ScrapMetal", "IronNugget"),
		-- Weapons.
		shapeless({ "GlassBottle", "DuctTape" }, "ImprovisedSuppressor"),
		shaped({ "N", "S", "F" }, { N = "IronNugget", S = "Stick", F = "Feather" }, "CrossbowBolt", 4),
	}
end

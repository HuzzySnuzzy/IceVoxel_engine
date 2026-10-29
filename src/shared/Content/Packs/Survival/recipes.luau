--!strict
--[[
	The Survival pack's recipes.

	Tough As Nails' water (Shared/ToughAsNails/Drinks). The Glass Bottle is Minecraft's (three glass
	in a V make three). TAN's leather canteen is made of iron here, as the game has no leather: an
	iron nugget for the stopper over three iron ingots in a cup (the Bucket's shape, which the
	nugget's row keeps apart from it). Dirty water is purified by smelting it, TAN's original way
	(its later Water Purifier is a machine of its own): a Dirty Water Bottle into a Purified Water
	Bottle, a Dirty Water Canteen into a full Purified Water Canteen (filling a canteen at water
	fills it anyway, so nothing is gained).

	Herbs, bowls and teas. The Bowl is Minecraft's: three planks of any wood in a V make four. A
	Dirty Water Bowl smelts into a Purified Water Bowl like the bottle. Mint cures dirty water
	without a fire: a dirty bottle, bowl or canteen with Mint Leaves in any slots (shapeless) makes
	its purified twin, in the inventory's own 2 x 2 grid too. The water keeps its wear (`keep`): a
	part-drunk dirty canteen comes out with the sips it had, as from a campfire
	(ToughAsNails/Boiling), so a mint leaf cures water and never makes more of it far from any;
	these are named by the mint ("PurifiedWaterBottleFromMintLeaves"), as the smelting recipe has
	the twin's name (a recipe's is its result's unless it gives one). A Purified Water Bowl brews a tea with a herb: Mint Leaves make Mint Tea (Internal Chill), Ginger
	Root Ginger Tea (Internal Warmth), both Herbal Tea. A bowl burns 100 ticks as fuel
	(Minecraft's; the Bowl's `fuel`).

	Tough As Nails' gear for the cold and the heat. The Campfire is Minecraft's: a stick on top and
	one each side of a coal or charcoal, over three logs of any wood (" S ", "SCS", "LLL"). Straw
	and Leaf armor take the armor shapes with Straw (grass broken by hand gives it) or any leaves
	(Shears harvest them): 24 for a set, as leather. The Thermometer (TAN's) is an iron nugget over
	glass over glow dust, the game's redstone (TAN's own uses copper and redstone).

	The seasons (Shared/Seasons; their entries' `age`: the Snow Layer and Insulated Planks are the
	Stone Age's, the Wood Stove, Insulated Glass and Insulated Door the Iron Age's, the Oil Heater
	the Industrial Age's, the Electric Heater, Air Conditioner and Electric Fan the Electric Age's):
	  Snow Layer       three Snow blocks in a row make six (Minecraft's)
	  Insulated Planks planks and White Wool in a checker make four
	  Insulated Glass  glass between Iron Nuggets makes two
	  Insulated Door   an Oak Door padded with two White Wool
	  Wood Stove       iron round a Furnace, an iron chimney on top
	  Oil Heater       a Furnace and a Bucket in iron over osmium and glass
	  Electric Heater  iron round Glow Dust and a Universal Cable
	  Air Conditioner  Packed Ice over cables and Glow Dust in iron
	  Electric Fan     iron blades round a Universal Cable
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)

return function(define: Define.Context): { Schema.Recipe }
	local shaped, shapeless, smelting = define.shaped, define.shapeless, define.smelting
	local list: { Schema.Recipe } = {
		-- Tough As Nails' water.
		shaped({ "G G", " G " }, { G = "Glass" }, "GlassBottle", 3),
		shaped({ " N ", "I I", " I " }, { N = "IronNugget", I = "IronIngot" }, "Canteen"),
		smelting("DirtyWaterBottle", "PurifiedWaterBottle"),
		smelting("DirtyWaterCanteen", "PurifiedWaterCanteen"),
		-- Herbs, bowls and teas.
		shaped({ "# #", " # " }, { ["#"] = "#planks" }, "Bowl", 4),
		smelting("DirtyWaterBowl", "PurifiedWaterBowl"),
	}
	for _, water in { "Bottle", "Bowl", "Canteen" } do
		table.insert(
			list,
			define.named(
				`PurifiedWater{water}FromMintLeaves`,
				shapeless({ "DirtyWater" .. water, "MintLeaves" }, "PurifiedWater" .. water, nil, "DirtyWater" .. water)
			)
		)
	end
	define.append(list, {
		shapeless({ "PurifiedWaterBowl", "MintLeaves" }, "MintTea"),
		shapeless({ "PurifiedWaterBowl", "GingerRoot" }, "GingerTea"),
		shapeless({ "PurifiedWaterBowl", "MintLeaves", "GingerRoot" }, "HerbalTea"),
		-- Tough As Nails' gear.
		shaped({ " S ", "SCS", "LLL" }, { S = "Stick", C = "#coals", L = "#logs" }, "Campfire"),
	})
	for _, material in { { "Straw", "Straw" }, { "Leaf", "#leaves" } } do
		local key = { X = material[2] }
		table.insert(list, shaped({ "XXX", "X X" }, key, material[1] .. "Helmet"))
		table.insert(list, shaped({ "X X", "XXX", "XXX" }, key, material[1] .. "Chestplate"))
		table.insert(list, shaped({ "XXX", "X X", "X X" }, key, material[1] .. "Leggings"))
		table.insert(list, shaped({ "X X", "X X" }, key, material[1] .. "Boots"))
	end
	define.append(list, {
		shaped({ "N", "G", "D" }, { N = "IronNugget", G = "Glass", D = "GlowDust" }, "Thermometer"),
		-- The seasons.
		shaped({ "SSS" }, { S = "Snow" }, "SnowLayer1", 6),
		shaped({ "PW", "WP" }, { P = "#planks", W = "WhiteWool" }, "InsulatedPlanks", 4),
		shaped({ "NGN", "NGN" }, { N = "IronNugget", G = "Glass" }, "InsulatedGlass", 2),
		shapeless({ "OakDoor", "WhiteWool", "WhiteWool" }, "InsulatedDoor"),
		shaped({ " I ", "IFI", "III" }, { I = "IronIngot", F = "Furnace" }, "WoodStove"),
		shaped(
			{ "IBI", "IFI", "OGO" },
			{ I = "IronIngot", B = "Bucket", F = "Furnace", O = "OsmiumIngot", G = "Glass" },
			"OilHeater"
		),
		shaped(
			{ "ICI", "IDI", "III" },
			{ I = "IronIngot", C = "BasicUniversalCable", D = "GlowDust" },
			"ElectricHeater"
		),
		shaped(
			{ "IPI", "CDC", "III" },
			{ I = "IronIngot", P = "PackedIce", C = "BasicUniversalCable", D = "GlowDust" },
			"AirConditioner"
		),
		shaped({ "I I", " C ", "I I" }, { I = "IronIngot", C = "BasicUniversalCable" }, "ElectricFan"),
	})
	return list
end

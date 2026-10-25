--!strict
--[[
	The new ores' recipes: each metal's storage (9 nuggets <-> an ingot, 9 ingots <-> a block, 9 raw
	<-> a raw block) and smelting (the ore and the raw lump into an ingot), brass (three copper
	ingots and a zinc ingot in any slots: four brass ingots), Sulfur and Saltpetre smelted from
	their ores, and what they are for:
	  * black powder: saltpetre, charcoal and sulfur (75, 15 and 10 parts): two Saltpetre, a Sulfur
	    and a coal or charcoal in any slots make four Gunpowder (Thermal's niter recipe);
	  * the Nuke (this game's, a mod's toy): eight TNT around a Block of Uranium, so a crater costs
	    40 gunpowder, 32 sand and nine uranium ingots;
	  * the Hazmat suit (Mekanism's, Shared/Radiation): lead sheet in White Wool padding, each piece
	    in its armor shape (the mask with a glass visor): 12 lead ingots, 12 wool and a glass for
	    the suit.
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)
local metals = require(script.Parent._metals)

return function(define: Define.Context): { Schema.Recipe }
	local list: { Schema.Recipe } = {}
	for _, name in { "Copper", "Lead", "Zinc", "Brass", "Uranium" } do
		define.append(list, define.metal(metals[name]).recipes)
	end
	local shaped, shapeless, smelting = define.shaped, define.shapeless, define.smelting
	table.insert(list, shapeless({ "CopperIngot", "CopperIngot", "CopperIngot", "ZincIngot" }, "BrassIngot", 4))
	table.insert(list, smelting("SulfurOre", "Sulfur"))
	table.insert(list, smelting("SaltpetreOre", "Saltpetre"))
	table.insert(list, shapeless({ "Saltpetre", "Saltpetre", "Sulfur", "#coals" }, "Gunpowder", 4))
	table.insert(list, shaped({ "TTT", "TUT", "TTT" }, { T = "Tnt", U = "UraniumBlock" }, "Nuke"))
	local key = { L = "LeadIngot", W = "WhiteWool", G = "Glass" }
	table.insert(list, shaped({ "WLW", "LGL" }, key, "HazmatHelmet"))
	table.insert(list, shaped({ "L L", "WLW", "WLW" }, key, "HazmatChestplate"))
	table.insert(list, shaped({ "WLW", "L L", "W W" }, key, "HazmatLeggings"))
	table.insert(list, shaped({ "L L", "W W" }, key, "HazmatBoots"))
	return list
end

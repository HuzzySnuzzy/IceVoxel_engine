--!strict
--[[
	Terraria's things, made from what this game has (Config.Accessories, Mana). Terraria finds most
	early accessories in chests (here the Minecraft pack's mineshaft loot, its fourth pool, and the
	Apocalypse pack's ruins' and bunkers' loot for Feral Claws); the ones made here:
	  Aglet               a Leather and two Iron Nuggets (the lace's leather, its metal tip)
	  Anklet of the Wind  three Feathers, a String and an Emerald (Terraria's jungle find)
	  Band of Starpower   four Gold Ingots around a Fallen Star (" G ", "GSG", " G ")
	  Obsidian Skull      six Obsidian in a skull ("OOO", "O O", " O "; Terraria's 20 at a
	                      furnace: obsidian needs a diamond pickaxe here, which is gate enough)
	Mana (Shared/Mana): five Fallen Stars make a Mana Crystal (Terraria's, by hand: here in a
	crafting table, five don't fit the 2 x 2); two Purified Water Bottles with a Fallen Star and Glow
	Dust brew two Lesser Mana Potions, and two of those with Glow Lichen (Terraria's glowing
	mushroom) two Mana Potions. The Emerald Staff: three Emeralds at the head of two Sticks on the
	diagonal (Terraria's gem staves). Vanity clothes: a Top Hat of five Leather (" L ", " L ",
	"LLL": crown and brim), a Tuxedo Shirt of two White Wool, two Leather and a String, Tuxedo
	Pants of three Leather and a String. The ones of iron, gold and emerald are the Iron Age's (the
	items' `age`).
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)

return function(define: Define.Context): { Schema.Recipe }
	local shaped, shapeless = define.shaped, define.shapeless
	return {
		shapeless({ "Leather", "IronNugget", "IronNugget" }, "Aglet"),
		shapeless({ "Feather", "Feather", "Feather", "String", "Emerald" }, "AnkletOfTheWind"),
		shaped({ " G ", "GSG", " G " }, { G = "GoldIngot", S = "FallenStar" }, "BandOfStarpower"),
		shaped({ "OOO", "O O", " O " }, { O = "Obsidian" }, "ObsidianSkull"),
		shapeless({ "FallenStar", "FallenStar", "FallenStar", "FallenStar", "FallenStar" }, "ManaCrystal"),
		shapeless({ "PurifiedWaterBottle", "PurifiedWaterBottle", "FallenStar", "GlowDust" }, "LesserManaPotion", 2),
		shapeless({ "LesserManaPotion", "LesserManaPotion", "GlowLichen" }, "ManaPotion", 2),
		shaped({ " EE", " SE", "S  " }, { E = "Emerald", S = "Stick" }, "EmeraldStaff"),
		shaped({ " L ", " L ", "LLL" }, { L = "Leather" }, "TopHat"),
		shapeless({ "WhiteWool", "WhiteWool", "Leather", "Leather", "String" }, "TuxedoShirt"),
		shapeless({ "Leather", "Leather", "Leather", "String" }, "TuxedoPants"),
	}
end

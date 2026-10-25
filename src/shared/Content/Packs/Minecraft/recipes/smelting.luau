--!strict
--[[
	Minecraft's smelting (200 ticks, as everything here): the ores and raw metals into their
	ingots and gems, sand into glass, cobblestone into stone, stone into smooth stone, sandstone
	into smooth sandstone, stone bricks into cracked ones, any log into charcoal, and iron and gold
	tools and armor (chainmail too) back into nuggets.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return function(define: Define.Context): { Schema.Recipe }
	local smelting = define.smelting
	local list: { Schema.Recipe } = {
		smelting("RawIron", "IronIngot"),
		smelting("RawGold", "GoldIngot"),
		smelting("IronOre", "IronIngot"),
		smelting("GoldOre", "GoldIngot"),
		smelting("CoalOre", "Coal"),
		smelting("DiamondOre", "Diamond"),
		smelting("EmeraldOre", "Emerald"),
		smelting("Sand", "Glass"),
		smelting("Cobblestone", "Stone"),
		smelting("Stone", "SmoothStone"),
		smelting("Sandstone", "SmoothSandstone"),
		smelting("StoneBricks", "CrackedStoneBricks"),
		smelting("#logs", "Charcoal"),
	}
	-- Iron and gold tools and armor melt back into nuggets.
	for _, piece in { "Pickaxe", "Axe", "Shovel", "Hoe", "Sword" } do
		table.insert(list, smelting("Iron" .. piece, "IronNugget"))
		table.insert(list, smelting("Golden" .. piece, "GoldNugget"))
	end
	for _, piece in { "Helmet", "Chestplate", "Leggings", "Boots" } do
		table.insert(list, smelting("Iron" .. piece, "IronNugget"))
		table.insert(list, smelting("Chainmail" .. piece, "IronNugget"))
		table.insert(list, smelting("Gold" .. piece, "GoldNugget"))
	end
	return list
end

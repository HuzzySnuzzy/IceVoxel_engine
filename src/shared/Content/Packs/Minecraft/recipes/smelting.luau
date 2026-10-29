--!strict
--[[
	Minecraft's smelting (200 ticks, as everything here): the ores and raw metals into their
	ingots and gems, sand into glass, cobblestone into stone, stone into smooth stone, sandstone
	into smooth sandstone, stone bricks into cracked ones, any log into charcoal, and iron and gold
	tools and armor (chainmail too) back into nuggets.

	A recipe is named by its result unless it gives a name (Content/Schema's Recipe). The ingots
	and nuggets have recipes of their own already (recipes/minerals: nine nuggets make the ingot,
	"IronIngot"), so these are named by what they smelt, as Minecraft's
	iron_ingot_from_smelting_raw_iron: "IronIngotFromRawIron", "IronNuggetFromIronPickaxe".
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return function(define: Define.Context): { Schema.Recipe }
	local smelting = define.smelting
	-- `input` smelted into `result`, named "<result>From<input>".
	local function melt(input: string, result: string): Schema.Recipe
		return define.named(`{result}From{input}`, smelting(input, result))
	end
	local list: { Schema.Recipe } = {
		melt("RawIron", "IronIngot"),
		melt("RawGold", "GoldIngot"),
		melt("IronOre", "IronIngot"),
		melt("GoldOre", "GoldIngot"),
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
		table.insert(list, melt("Iron" .. piece, "IronNugget"))
		table.insert(list, melt("Golden" .. piece, "GoldNugget"))
	end
	for _, piece in { "Helmet", "Chestplate", "Leggings", "Boots" } do
		table.insert(list, melt("Iron" .. piece, "IronNugget"))
		table.insert(list, melt("Chainmail" .. piece, "IronNugget"))
		table.insert(list, melt("Gold" .. piece, "GoldNugget"))
	end
	return list
end

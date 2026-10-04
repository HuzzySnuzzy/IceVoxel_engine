--!strict
--[[
	Every crafting and smelting recipe, by item name: Minecraft Java 1.20's recipes for the items
	this game has (the ones needing items it doesn't have, such as leather, clay or wool, are left
	out).

	  shaped     `pattern` rows of single characters (" " = empty), `key` maps each character to an
	             ingredient; it may sit anywhere in a big enough grid, and mirrored (Minecraft's
	             ShapedRecipe).
	  shapeless  `ingredients` in any slots.
	  smelting   furnace recipes: one `input` cooks into `result` (200 ticks).
	  fuel       burn time in ticks of furnace fuel.

	An ingredient is an item name or "#tag" (a list in `tags`, like Minecraft's item tags).
	Shared/Crafting compiles these into ids and matches them.
]]

export type Shaped = { pattern: { string }, key: { [string]: string }, result: string, count: number? }
export type Shapeless = { ingredients: { string }, result: string, count: number? }
export type Smelting = { input: string, result: string, count: number? }

local Recipes = {}

Recipes.tags = {
	planks = { "Planks", "BirchPlanks", "SprucePlanks", "AcaciaPlanks", "JunglePlanks" },
	logs = { "OakLog", "BirchLog", "SpruceLog", "AcaciaLog", "JungleLog" },
	stone_tool_materials = { "Cobblestone" },
	stone_crafting_materials = { "Cobblestone" },
}

local shaped: { Shaped } = {}
local shapeless: { Shapeless } = {}
local smelting: { Smelting } = {}

local function shape(pattern: { string }, key: { [string]: string }, result: string, count: number?)
	table.insert(shaped, { pattern = pattern, key = key, result = result, count = count })
end
local function mix(ingredients: { string }, result: string, count: number?)
	table.insert(shapeless, { ingredients = ingredients, result = result, count = count })
end
local function smelt(input: string, result: string)
	table.insert(smelting, { input = input, result = result })
end
-- A 3 x 3 of `item` packs into `block`, which unpacks into 9 again.
local function storage(item: string, block: string)
	shape({ "###", "###", "###" }, { ["#"] = item }, block)
	mix({ block }, item, 9)
end

--[[ Wood ]]

mix({ "OakLog" }, "Planks", 4)
mix({ "BirchLog" }, "BirchPlanks", 4)
mix({ "SpruceLog" }, "SprucePlanks", 4)
mix({ "AcaciaLog" }, "AcaciaPlanks", 4)
mix({ "JungleLog" }, "JunglePlanks", 4)
shape({ "#", "#" }, { ["#"] = "#planks" }, "Stick", 4)
shape({ "##", "##" }, { ["#"] = "#planks" }, "CraftingTable")
shape({ "###", "# #", "###" }, { ["#"] = "#planks" }, "Chest")

--[[ Stone ]]

shape({ "###", "# #", "###" }, { ["#"] = "#stone_crafting_materials" }, "Furnace")
shape({ "##", "##" }, { ["#"] = "Stone" }, "StoneBricks", 4)
shape({ "##", "##" }, { ["#"] = "Andesite" }, "PolishedAndesite", 4)
shape({ "##", "##" }, { ["#"] = "Diorite" }, "PolishedDiorite", 4)
shape({ "##", "##" }, { ["#"] = "Granite" }, "PolishedGranite", 4)
mix({ "Diorite", "Cobblestone" }, "Andesite", 2)
shape({ "##", "##" }, { ["#"] = "Sand" }, "Sandstone")
shape({ "##", "##" }, { ["#"] = "Sandstone" }, "CutSandstone", 4)
shape({ "DG", "GD" }, { D = "Dirt", G = "Gravel" }, "CoarseDirt", 4)

--[[ Ice and snow ]]

mix({ "Ice", "Ice", "Ice", "Ice", "Ice", "Ice", "Ice", "Ice", "Ice" }, "PackedIce")
mix({
	"PackedIce",
	"PackedIce",
	"PackedIce",
	"PackedIce",
	"PackedIce",
	"PackedIce",
	"PackedIce",
	"PackedIce",
	"PackedIce",
}, "BlueIce")
shape({ "##", "##" }, { ["#"] = "Snowball" }, "Snow")

--[[ Minerals ]]

storage("Coal", "CoalBlock")
storage("IronIngot", "IronBlock")
storage("GoldIngot", "GoldBlock")
storage("Diamond", "DiamondBlock")
storage("Emerald", "EmeraldBlock")
storage("RawIron", "RawIronBlock")
storage("RawGold", "RawGoldBlock")
storage("IronNugget", "IronIngot")
storage("GoldNugget", "GoldIngot")

--[[ Tools: wood, stone, iron, gold and diamond ]]

local TOOL_MATERIALS = {
	{ "Wooden", "#planks" },
	{ "Stone", "#stone_tool_materials" },
	{ "Iron", "IronIngot" },
	{ "Golden", "GoldIngot" },
	{ "Diamond", "Diamond" },
}
for _, material in TOOL_MATERIALS do
	local tier, x = material[1], material[2]
	local key = { X = x, ["#"] = "Stick" }
	shape({ "XXX", " # ", " # " }, key, tier .. "Pickaxe")
	shape({ "XX", "X#", " #" }, key, tier .. "Axe")
	shape({ "X", "#", "#" }, key, tier .. "Shovel")
	shape({ "XX", " #", " #" }, key, tier .. "Hoe")
	shape({ "X", "X", "#" }, key, tier .. "Sword")
end

--[[ Armor: iron, gold and diamond (leather needs leather; chainmail is not craftable, but smelts) ]]

for _, material in { { "Iron", "IronIngot" }, { "Gold", "GoldIngot" }, { "Diamond", "Diamond" } } do
	local key = { X = material[2] }
	shape({ "XXX", "X X" }, key, material[1] .. "Helmet")
	shape({ "X X", "XXX", "XXX" }, key, material[1] .. "Chestplate")
	shape({ "XXX", "X X", "X X" }, key, material[1] .. "Leggings")
	shape({ "X X", "X X" }, key, material[1] .. "Boots")
end

--[[ Smelting ]]

smelt("RawIron", "IronIngot")
smelt("RawGold", "GoldIngot")
smelt("IronOre", "IronIngot")
smelt("GoldOre", "GoldIngot")
smelt("CoalOre", "Coal")
smelt("DiamondOre", "Diamond")
smelt("EmeraldOre", "Emerald")
smelt("Sand", "Glass")
smelt("Cobblestone", "Stone")
smelt("Stone", "SmoothStone")
smelt("Sandstone", "SmoothSandstone")
smelt("StoneBricks", "CrackedStoneBricks")
smelt("#logs", "Charcoal")
-- Iron and gold tools and armor melt back into nuggets.
for _, piece in { "Pickaxe", "Axe", "Shovel", "Hoe", "Sword" } do
	smelt("Iron" .. piece, "IronNugget")
	smelt("Golden" .. piece, "GoldNugget")
end
for _, piece in { "Helmet", "Chestplate", "Leggings", "Boots" } do
	smelt("Iron" .. piece, "IronNugget")
	smelt("Chainmail" .. piece, "IronNugget")
	smelt("Gold" .. piece, "GoldNugget")
end

-- Burn time (ticks) of furnace fuel (Minecraft's AbstractFurnaceBlockEntity.getFuel).
Recipes.fuel = {
	Coal = 1600,
	Charcoal = 1600,
	CoalBlock = 16000,
	["#logs"] = 300,
	["#planks"] = 300,
	CraftingTable = 300,
	Chest = 300,
	Stick = 100,
	WoodenPickaxe = 200,
	WoodenAxe = 200,
	WoodenShovel = 200,
	WoodenHoe = 200,
	WoodenSword = 200,
}

Recipes.shaped = shaped
Recipes.shapeless = shapeless
Recipes.smelting = smelting

return Recipes

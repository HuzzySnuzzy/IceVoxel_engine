--!strict
--[[
	Every crafting and smelting recipe, by item name: Minecraft Java 1.20's recipes for the items
	this game has (the ones needing items it doesn't have, such as leather, clay or wool, are left
	out), and Mekanism's: osmium's storage blocks and smelting as Mekanism has them, and its
	transmitters, fluid tanks, Configurator and Universal Cables adapted to the game's materials
	(see "Mekanism pipes and buckets" and "Universal Cables" below).

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
	coals = { "Coal", "Charcoal" },
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
-- Mekanism's osmium: 9 nuggets <-> an ingot, 9 ingots <-> a block, 9 raw <-> a raw block.
storage("OsmiumNugget", "OsmiumIngot")
storage("OsmiumIngot", "OsmiumBlock")
storage("RawOsmium", "RawOsmiumBlock")

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

--[[ Light ]]

shape({ "X", "#" }, { X = "#coals", ["#"] = "Stick" }, "Torch", 4)
shape({ "XXX", "X#X", "XXX" }, { X = "IronNugget", ["#"] = "Torch" }, "Lantern")
shape({ "##", "##" }, { ["#"] = "GlowstoneDust" }, "Glowstone")

--[[
	Mekanism pipes and buckets. The bucket is Minecraft's. Mekanism's own recipes need steel,
	control circuits (osmium infused with redstone) and alloys, made in machines this game does not
	have, so they are adapted:
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
	  * Configurator: glowstone dust over a stick between two iron ingots, a stick below, after
	    Mekanism's " L ", "AEA", " S " (lapis lazuli over an energy tablet between two infused
	    alloys, a stick below).
]]
shape({ "I I", " I " }, { I = "IronIngot" }, "Bucket")
shape({ "IGI" }, { I = "IronIngot", G = "Glass" }, "BasicLogisticalTransporter", 8)
shape({ "IBI" }, { I = "IronIngot", B = "Bucket" }, "BasicMechanicalPipe", 8)
shape({ "ITI" }, { I = "IronIngot", T = "BasicLogisticalTransporter" }, "RestrictiveTransporter", 2)
shape({ "IGI", "G G", "IGI" }, { I = "IronIngot", G = "Glass" }, "BasicFluidTank")
local TIER_NAMES = { "Basic", "Advanced", "Elite", "Ultimate" }
local ALLOYS = { "GoldIngot", "Diamond", "Emerald" }
for tier = 2, 4 do
	local lower, name, alloy = TIER_NAMES[tier - 1], TIER_NAMES[tier], ALLOYS[tier - 1]
	for _, kind in { "LogisticalTransporter", "MechanicalPipe" } do
		shape({ "TTT", "TAT", "TTT" }, { T = lower .. kind, A = alloy }, name .. kind, 8)
	end
	shape({ " A ", "ATA", " A " }, { T = lower .. "FluidTank", A = alloy }, name .. "FluidTank")
end
shape({ " G ", "ISI", " S " }, { G = "GlowstoneDust", I = "IronIngot", S = "Stick" }, "Configurator")

--[[
	Mekanism's Universal Cables. Mekanism makes 8 Basic Universal Cables from steel, redstone and
	steel in a row; osmium ingots stand for the steel (Mekanism's steel is made with osmium's
	help) and glowstone dust for the redstone, which the game has neither of. The upgrades are
	Mekanism's shape, as for transporters and pipes: 8 cables around an alloy (gold, diamond,
	emerald) make 8 of the next tier.
]]
shape({ "OGO" }, { O = "OsmiumIngot", G = "GlowstoneDust" }, "BasicUniversalCable", 8)
for tier = 2, 4 do
	local lower, name, alloy = TIER_NAMES[tier - 1], TIER_NAMES[tier], ALLOYS[tier - 1]
	shape({ "CCC", "CAC", "CCC" }, { C = lower .. "UniversalCable", A = alloy }, name .. "UniversalCable", 8)
end

--[[ Smelting ]]

smelt("RawIron", "IronIngot")
smelt("RawGold", "GoldIngot")
smelt("IronOre", "IronIngot")
smelt("GoldOre", "GoldIngot")
smelt("CoalOre", "Coal")
smelt("DiamondOre", "Diamond")
smelt("EmeraldOre", "Emerald")
smelt("RawOsmium", "OsmiumIngot")
smelt("OsmiumOre", "OsmiumIngot")
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

--!strict
--[[
	Every crafting and smelting recipe, by item name: the content packs' `recipes` (Shared/Content;
	the Base pack's are Minecraft's, Mekanism's and the rest the game had, the Ores pack's its
	metals'), merged in load order, split by type, each type in that order:

	  shaped     `pattern` rows of single characters (" " = empty), `key` maps each character to an
	             ingredient; it may sit anywhere in a big enough grid, and mirrored (Minecraft's
	             ShapedRecipe). `keep`, a key character used once in the pattern: the result takes
	             that ingredient's item data (Mekanism's MekDataShapedRecipe: a Battery crafted into
	             the next tier keeps its charge), and its wear when the result wears too (Items
	             `durability`); other results carry none.
	  shapeless  `ingredients` in any slots. `keep`, an ingredient listed once: the result takes
	             its data and wear the same way (mint curing a part-drunk canteen).
	  smelting   furnace recipes: one `input` cooks into `result` (200 ticks).
	  tags       the packs' tags (Core's base tags and every pack's, each a union).
	  fuel       burn time in ticks of furnace fuel: an entry's `fuel`, and LEGACY_FUEL below (by
	             item name or "#tag") for what has none yet; an item in both is an error.

	An ingredient is an item name or "#tag" (Minecraft's item tags). Shared/Crafting compiles these
	into ids and matches them.
]]

local Content = require(script.Parent.Parent.Content)
local Schema = require(script.Parent.Parent.Content.Schema)

export type Shaped = {
	pattern: { string },
	key: { [string]: string },
	result: string,
	count: number?,
	keep: string?,
}
export type Shapeless = { ingredients: { string }, result: string, count: number?, keep: string? }
export type Smelting = { input: string, result: string, count: number? }

local Recipes = {}

local content = Content.default

Recipes.tags = content.tags

local shaped: { Shaped } = {}
local shapeless: { Shapeless } = {}
local smelting: { Smelting } = {}
for _, recipe: Schema.Recipe in content.recipes do
	if recipe.type == "shaped" then
		table.insert(shaped, {
			pattern = recipe.pattern :: { string },
			key = recipe.key :: { [string]: string },
			result = recipe.result,
			count = recipe.count,
			keep = recipe.keep,
		})
	elseif recipe.type == "shapeless" then
		table.insert(shapeless, {
			ingredients = recipe.ingredients :: { string },
			result = recipe.result,
			count = recipe.count,
			keep = recipe.keep,
		})
	else
		table.insert(smelting, { input = recipe.input :: string, result = recipe.result, count = recipe.count })
	end
end
Recipes.shaped = shaped
Recipes.shapeless = shapeless
Recipes.smelting = smelting

-- Burn time (ticks) of furnace fuel (Minecraft's AbstractFurnaceBlockEntity.getFuel), by item name
-- or "#tag": the side table, for what has no `fuel` on its entry yet.
local LEGACY_FUEL: { [string]: number } = {
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
	Bowl = 100,
	WhiteWool = 100,
	Ladder = 300,
	OakFence = 300,
	-- (Minecraft's ItemTags.WOODEN_DOORS.)
	OakDoor = 200,
	SpruceDoor = 200,
	BirchDoor = 200,
	JungleDoor = 200,
	AcaciaDoor = 200,
}

-- Every fuel: the side table's, and every entry's `fuel` (an entry the side table burns, by name or
-- through a tag, may not have one).
local fuel: { [string]: number } = table.clone(LEGACY_FUEL)
do
	local legacy: { [string]: string } = {}
	for name in LEGACY_FUEL do
		local tag = if string.sub(name, 1, 1) == "#" then content.tags[string.sub(name, 2)] else nil
		for _, member in (tag or { name }) :: { string } do
			legacy[member] = name
		end
	end
	for _, entry in content.entries do
		local ticks = entry.fuel
		if ticks then
			local kind = if content.block(entry.name) then "block" else "item"
			assert(
				legacy[entry.name] == nil,
				`Recipes: {content.where(kind, entry.name)} has its fuel both on its entry and in LEGACY_FUEL ({legacy[entry.name]})`
			)
			assert(ticks > 0, `Recipes: {content.where(kind, entry.name)} burns for {ticks} ticks`)
			fuel[entry.name] = ticks
		end
	end
end
Recipes.fuel = fuel

return Recipes

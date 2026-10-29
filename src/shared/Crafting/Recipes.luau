--!strict
--[[
	Every crafting and smelting recipe, by item name: the content packs' `recipes` (Shared/Content:
	each feature pack's, Minecraft's, Mekanism's, Survival's... the Ores pack's its metals'), merged
	in load order, split by type, each type in that order (Crafting.match answers the first that
	matches, and a furnace smelts an input by the first recipe taking it: tests/spec/CraftingGrids
	checks no recipe hides another). Each says where it is from (`from`, Content's `where`: "pack
	Minecraft, recipes/tools, recipe #3 (WoodenPickaxe)"), for Crafting's and Smelting's messages.

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
	  fuel       burn time in ticks of furnace fuel, by item name or "#tag": the packs' `fuel` (by
	             tag: Core's logs and planks) and every entry's own `fuel`, which beats its tag's
	             (Shared/Crafting/Smelting burns the tags' first).

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
	from: string,
}
export type Shapeless = { ingredients: { string }, result: string, count: number?, keep: string?, from: string }
export type Smelting = { input: string, result: string, count: number?, from: string }

local Recipes = {}

local content = Content.default

Recipes.tags = content.tags

local shaped: { Shaped } = {}
local shapeless: { Shapeless } = {}
local smelting: { Smelting } = {}
for index, recipe: Schema.Recipe in content.recipes do
	local from = content.where("recipe", index)
	if recipe.type == "shaped" then
		table.insert(shaped, {
			pattern = recipe.pattern :: { string },
			key = recipe.key :: { [string]: string },
			result = recipe.result,
			count = recipe.count,
			keep = recipe.keep,
			from = from,
		})
	elseif recipe.type == "shapeless" then
		table.insert(shapeless, {
			ingredients = recipe.ingredients :: { string },
			result = recipe.result,
			count = recipe.count,
			keep = recipe.keep,
			from = from,
		})
	else
		table.insert(
			smelting,
			{ input = recipe.input :: string, result = recipe.result, count = recipe.count, from = from }
		)
	end
end
Recipes.shaped = shaped
Recipes.shapeless = shapeless
Recipes.smelting = smelting

-- Burn time (ticks) of furnace fuel (Minecraft's AbstractFurnaceBlockEntity.getFuel), by item name
-- or "#tag": the packs' fuel tags, then every entry's own `fuel`.
local fuel: { [string]: number } = {}
for tag, ticks in content.fuel do
	fuel[`#{tag}`] = ticks
end
for _, entry in content.entries do
	local ticks = entry.fuel
	if ticks then
		local kind = if content.block(entry.name) then "block" else "item"
		assert(ticks > 0, `Recipes: {content.where(kind, entry.name)} burns for {ticks} ticks`)
		fuel[entry.name] = ticks
	end
end
Recipes.fuel = fuel

return Recipes

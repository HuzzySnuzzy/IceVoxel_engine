--!strict
--[[
	Content/Define's recipe records (Content/Schema's Recipe; Content/Define lists them): a shaped,
	shapeless or smelting recipe from its parts, one with a name of its own, and a storage block's
	pair.

	A recipe's name is its result's unless it gives one (Content), so a second recipe for a result
	takes `named` ("IronIngotFromRawIron", as Minecraft's recipe ids). A storage pair names its
	unpacking recipe so, after the block it unpacks ("IronIngotFromIronBlock": Minecraft's
	iron_ingot_from_iron_block), the block's recipe keeping the block's name: two pairs sharing an
	item (nuggets into an ingot, the ingot into a block) never take one name.
]]

local Schema = require(script.Parent.Parent.Schema)

type Recipe = Schema.Recipe

local Recipes = {}

function Recipes.shaped(
	pattern: { string },
	key: { [string]: string },
	result: string,
	count: number?,
	keep: string?
): Recipe
	return { type = "shaped", pattern = pattern, key = key, result = result, count = count, keep = keep }
end

function Recipes.shapeless(ingredients: { string }, result: string, count: number?, keep: string?): Recipe
	return { type = "shapeless", ingredients = ingredients, result = result, count = count, keep = keep }
end

function Recipes.smelting(input: string, result: string, count: number?): Recipe
	return { type = "smelting", input = input, result = result, count = count }
end

-- `recipe` named `name` (a new table): a second recipe for its result.
function Recipes.named(name: string, recipe: Recipe): Recipe
	local copy = table.clone(recipe)
	copy.name = name
	return copy
end

-- A 3 x 3 of `item` packs into `block` (named `block`), which unpacks into 9 again (named
-- "<item>From<block>").
function Recipes.storage(item: string, block: string): { Recipe }
	return {
		Recipes.shaped({ "###", "###", "###" }, { ["#"] = item }, block),
		Recipes.named(`{item}From{block}`, Recipes.shapeless({ block }, item, 9)),
	}
end

return Recipes

--!strict
--[[
	Content/Define's recipe records (Content/Schema's Recipe; Content/Define lists them): a shaped,
	shapeless or smelting recipe from its parts, and a storage block's pair.
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

-- A 3 x 3 of `item` packs into `block`, which unpacks into 9 again.
function Recipes.storage(item: string, block: string): { Recipe }
	return {
		Recipes.shaped({ "###", "###", "###" }, { ["#"] = item }, block),
		Recipes.shapeless({ block }, item, 9),
	}
end

return Recipes

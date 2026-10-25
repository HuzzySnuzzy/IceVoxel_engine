--[[
	Every recipe of the content packs crafts its own result from its own grid. Crafting.match
	answers the first recipe that matches, and the packs' recipes merge in load order (Shared/
	Content), so a recipe a later pack adds could be shadowed by an earlier one with the same
	grid, or shadow it: this builds each written recipe's grid (Crafting/Recipes, by name) and
	checks what it makes.

	  shaped     the pattern at the top left of a 3 x 3 grid, one item in each keyed cell
	  shapeless  one of each ingredient, in the first slots
	  smelting   the input in a lit furnace, cooked for a whole smelt
	An ingredient that is a tag ("#planks") takes the tag's first name. Each must make the recipe's
	result, as many as it says.
]]

return function(t, shared, require)
	local Items = require(shared.Items)
	local Crafting = require(shared.Crafting)
	local Recipes = require(shared.Crafting.Recipes)
	local Smelting = require(shared.Crafting.Smelting)

	-- An ingredient's item id: the item, or a tag's first name.
	local function itemOf(ingredient: string): number
		if string.sub(ingredient, 1, 1) == "#" then
			local tag = (Recipes.tags :: any)[string.sub(ingredient, 2)]
			assert(tag and tag[1], `no tag {ingredient}`)
			return Items.id[tag[1]]
		end
		return Items.id[ingredient]
	end

	local function stack(item: number)
		return { item = item, count = 1 }
	end

	-- Every failure of a test at once (a shadowed recipe names what it made instead).
	local function report(failures: { string }, what: string)
		t.ok(#failures == 0, `{what}: {table.concat(failures, "; ")}`)
	end

	-- "X x2" for a stack, "nothing" for nil.
	local function describe(made): string
		if made == nil then
			return "nothing"
		end
		local def = Items.get(made.item)
		return `{if def then def.name else made.item} x{made.count}`
	end

	t.test("crafting grids: every shaped recipe makes its own result", function()
		local failures = {}
		for index, recipe in Recipes.shaped do
			local grid = {}
			for y, row in recipe.pattern do
				for x = 1, #row do
					local char = string.sub(row, x, x)
					if char ~= " " then
						grid[(y - 1) * 3 + x] = stack(itemOf(recipe.key[char]))
					end
				end
			end
			local made = Crafting.match(grid, 3)
			local want = recipe.count or 1
			if made == nil or made.item ~= Items.id[recipe.result] or made.count ~= want then
				table.insert(failures, `shaped #{index} ({recipe.result} x{want}) makes {describe(made)}`)
			end
		end
		report(failures, "shadowed shaped recipes")
	end)

	t.test("crafting grids: every shapeless recipe makes its own result", function()
		local failures = {}
		for index, recipe in Recipes.shapeless do
			local grid = {}
			for slot, ingredient in recipe.ingredients do
				grid[slot] = stack(itemOf(ingredient))
			end
			local made = Crafting.match(grid, 3)
			local want = recipe.count or 1
			if made == nil or made.item ~= Items.id[recipe.result] or made.count ~= want then
				table.insert(failures, `shapeless #{index} ({recipe.result} x{want}) makes {describe(made)}`)
			end
		end
		report(failures, "shadowed shapeless recipes")
	end)

	t.test("crafting grids: every smelting recipe cooks its own result in a furnace", function()
		local failures = {}
		for index, recipe in Recipes.smelting do
			local furnace = {
				slots = { [1] = stack(itemOf(recipe.input)), [2] = stack(Items.id.Coal) },
				data = Smelting.newData(),
			}
			for _ = 1, Smelting.COOK_TIME do
				Smelting.tick(furnace)
			end
			local made = furnace.slots[3]
			local want = recipe.count or 1
			if made == nil or made.item ~= Items.id[recipe.result] or made.count ~= want then
				table.insert(
					failures,
					`smelting #{index} ({recipe.input} -> {recipe.result} x{want}) makes {describe(made)}`
				)
			end
		end
		report(failures, "smelting recipes cooking something else")
	end)
end

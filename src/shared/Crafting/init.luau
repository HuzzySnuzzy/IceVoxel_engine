--!strict
--[[
	Crafting: what a crafting grid makes (Minecraft's CraftingManager and recipes, for the recipes in
	Crafting/Recipes).

	  `match(grid, width)`   the result of the items in a width x width grid (slots 1..width^2, row
	                         by row), or nil. Shaped recipes fit anywhere inside the grid with
	                         nothing around them, as written or mirrored; shapeless ones take their
	                         ingredients in any slots; two worn tools of a kind repair into one
	                         (Minecraft's RepairItemRecipe: their durability left plus 5%).
	  `consume(grid, width)` takes one item from every used slot after a craft (the result was
	                         taken), returning the grid's new contents. (No recipe here leaves
	                         anything behind, like Minecraft's empty buckets.)

	Ingredients match by item whatever their data (Items `data`); results carry none, a repaired
	tool's included (Minecraft's RepairItemRecipe makes a fresh stack). What stays in the grid after
	a craft keeps its wear and data.

	Pure and deterministic: the server crafts with it and clients predict with it.
]]

local Items = require(script.Parent.Items)
local Recipes = require(script.Recipes)

type Stack = Items.Stack
-- A set of item ids an ingredient accepts.
type Ingredient = { [number]: boolean }

export type Recipe = {
	kind: "shaped" | "shapeless",
	width: number,
	height: number,
	-- Shaped: row by row, `width` x `height`, false = must be empty. Shapeless: every ingredient.
	cells: { Ingredient | false },
	result: number,
	count: number,
}

local Crafting = {}

local function itemId(name: string): number
	local ok, id = pcall(function()
		return Items.id[name]
	end)
	assert(ok, `Crafting: unknown item '{name}'`)
	return id
end

-- The item ids an ingredient string accepts.
local function ingredient(name: string): Ingredient
	local set: Ingredient = {}
	if string.sub(name, 1, 1) == "#" then
		local tag = (Recipes.tags :: any)[string.sub(name, 2)]
		assert(tag, `Crafting: unknown tag '{name}'`)
		for _, item in tag do
			set[itemId(item)] = true
		end
	else
		set[itemId(name)] = true
	end
	return set
end

local recipes: { Recipe } = {}
for _, spec in Recipes.shaped do
	local height = #spec.pattern
	local width = 0
	for _, row in spec.pattern do
		width = math.max(width, #row)
	end
	local cells: { Ingredient | false } = {}
	for y = 1, height do
		local row = spec.pattern[y]
		for x = 1, width do
			local char = string.sub(row, x, x)
			if char == "" or char == " " then
				table.insert(cells, false)
			else
				local key = spec.key[char]
				assert(key, `Crafting: no key for '{char}' in the {spec.result} recipe`)
				table.insert(cells, ingredient(key))
			end
		end
	end
	table.insert(recipes, {
		kind = "shaped",
		width = width,
		height = height,
		cells = cells,
		result = itemId(spec.result),
		count = spec.count or 1,
	})
end
for _, spec in Recipes.shapeless do
	local cells: { Ingredient | false } = {}
	for _, name in spec.ingredients do
		table.insert(cells, ingredient(name))
	end
	table.insert(recipes, {
		kind = "shapeless",
		width = #cells,
		height = 1,
		cells = cells,
		result = itemId(spec.result),
		count = spec.count or 1,
	})
end

-- Every recipe, compiled (for tests and recipe lists).
Crafting.recipes = recipes

-- Does the shaped recipe sit at (dx, dy) in the grid (mirrored or not), with nothing else around?
local function shapedAt(
	recipe: Recipe,
	grid: { [number]: Stack? },
	size: number,
	dx: number,
	dy: number,
	mirror: boolean
): boolean
	for y = 0, size - 1 do
		for x = 0, size - 1 do
			local stack = grid[y * size + x + 1]
			local rx, ry = x - dx, y - dy
			local want: Ingredient | false = false
			if rx >= 0 and ry >= 0 and rx < recipe.width and ry < recipe.height then
				local column = if mirror then recipe.width - 1 - rx else rx
				want = recipe.cells[ry * recipe.width + column + 1]
			end
			if want then
				if stack == nil or not want[stack.item] then
					return false
				end
			elseif stack ~= nil then
				return false
			end
		end
	end
	return true
end

local function matchesShaped(recipe: Recipe, grid: { [number]: Stack? }, size: number): boolean
	if recipe.width > size or recipe.height > size then
		return false
	end
	for dy = 0, size - recipe.height do
		for dx = 0, size - recipe.width do
			if shapedAt(recipe, grid, size, dx, dy, false) or shapedAt(recipe, grid, size, dx, dy, true) then
				return true
			end
		end
	end
	return false
end

--[[
	Finds a cell for stack `i`, moving earlier stacks to other cells if needed (an augmenting path
	of Kuhn's bipartite matching: polynomial, where trying every assignment would take 9! steps on
	a grid that almost matches a nine ingredient recipe).
]]
local function augment(
	stacks: { Stack },
	cells: { Ingredient | false },
	i: number,
	seen: { boolean },
	owner: { [number]: number }
): boolean
	local item = stacks[i].item
	for j, cell in cells do
		if not seen[j] and cell ~= false and (cell :: Ingredient)[item] then
			seen[j] = true
			local other = owner[j]
			if other == nil or augment(stacks, cells, other, seen, owner) then
				owner[j] = i
				return true
			end
		end
	end
	return false
end

-- Can every stack take a different ingredient (a perfect matching)?
local function matchesShapeless(recipe: Recipe, stacks: { Stack }): boolean
	if #stacks ~= #recipe.cells then
		return false
	end
	local owner: { [number]: number } = {}
	for i = 1, #stacks do
		if not augment(stacks, recipe.cells, i, {}, owner) then
			return false
		end
	end
	return true
end

-- Minecraft's tool repair: exactly two of the same wearing item, durability left added + 5% (a
-- fresh stack: no data).
local function repair(stacks: { Stack }): Stack?
	if #stacks ~= 2 then
		return nil
	end
	local a, b = stacks[1], stacks[2]
	local def = Items.get(a.item)
	if a.item ~= b.item or def == nil or def.durability == nil or a.count ~= 1 or b.count ~= 1 then
		return nil
	end
	local max = def.durability
	local left = (max - (a.damage or 0)) + (max - (b.damage or 0)) + max * 5 // 100
	local damage = math.max(max - left, 0)
	return { item = a.item, count = 1, damage = if damage > 0 then damage else nil }
end

-- The result of a width x width grid (slots 1..width^2, row by row), or nil.
function Crafting.match(grid: { [number]: Stack? }, width: number): Stack?
	local stacks: { Stack } = {}
	for slot = 1, width * width do
		local stack = grid[slot]
		if stack then
			table.insert(stacks, stack)
		end
	end
	if #stacks == 0 then
		return nil
	end
	for _, recipe in recipes do
		local ok = if recipe.kind == "shaped"
			then matchesShaped(recipe, grid, width)
			else matchesShapeless(recipe, stacks)
		if ok then
			return { item = recipe.result, count = recipe.count }
		end
	end
	return repair(stacks)
end

-- The grid after one craft: one item less in every used slot (new stack tables, wear and data
-- kept).
function Crafting.consume(grid: { [number]: Stack? }, width: number): { [number]: Stack? }
	local after: { [number]: Stack? } = {}
	for slot = 1, width * width do
		local stack = grid[slot]
		if stack and stack.count > 1 then
			after[slot] = Items.withCount(stack, stack.count - 1)
		end
	end
	return after
end

return Crafting

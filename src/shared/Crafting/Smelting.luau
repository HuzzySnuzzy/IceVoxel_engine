--!strict
--[[
	Furnaces: Minecraft's smelting recipes, fuel and the furnace tick (AbstractFurnaceBlockEntity.
	serverTick), for the server to run and the UI to show.

	A furnace is a container of kind "furnace" with slots 1 input, 2 fuel, 3 output and
	`data = { litTime, litDuration, cookingProgress, cookingTotalTime, cookingItem }`:
	  * while lit (litTime > 0) it burns down one tick at a time;
	  * when it is out and there is something to smelt that fits the output, it lights by using one
	    fuel item (litTime = that fuel's burn time);
	  * while lit with something to smelt, the progress counts up to 200 ticks, then one input item
	    becomes the recipe's result in the output;
	  * with nothing to smelt the progress resets; going out, it falls back 2 per tick;
	  * a different item in the input starts its progress over (`cookingItem`).
]]

local Items = require(script.Parent.Parent.Items)
local Recipes = require(script.Parent.Recipes)

type Stack = Items.Stack

local Smelting = {}

-- Ticks to smelt one item.
Smelting.COOK_TIME = 200

local results: { [number]: Stack } = {}
local fuels: { [number]: number } = {}

-- Item ids named by an ingredient string (an item or "#tag").
local function namesOf(name: string): { number }
	local names = { name }
	if string.sub(name, 1, 1) == "#" then
		names = (Recipes.tags :: any)[string.sub(name, 2)]
		assert(names, `Smelting: unknown tag '{name}'`)
	end
	local ids = {}
	for _, item in names do
		local ok, id = pcall(function()
			return Items.id[item]
		end)
		assert(ok, `Smelting: unknown item '{item}'`)
		table.insert(ids, id)
	end
	return ids
end

for _, recipe in Recipes.smelting do
	local result = namesOf(recipe.result)[1]
	for _, input in namesOf(recipe.input) do
		results[input] = { item = result, count = recipe.count or 1 }
	end
end
for name, ticks in Recipes.fuel :: { [string]: number } do
	for _, id in namesOf(name) do
		fuels[id] = ticks
	end
end

-- What smelting one `item` makes, or nil.
function Smelting.result(item: number): Stack?
	local result = results[item]
	return if result then { item = result.item, count = result.count } else nil
end

-- Burn time (ticks) of `item` as fuel, 0 if it doesn't burn.
function Smelting.fuel(item: number): number
	return fuels[item] or 0
end

-- A furnace's data, fresh.
function Smelting.newData(): { number }
	return { 0, 0, 0, Smelting.COOK_TIME, 0 }
end

-- Can the furnace smelt its input now (a recipe, and room in the output)?
local function canBurn(input: Stack?, output: Stack?): Stack?
	if input == nil then
		return nil
	end
	local result = Smelting.result(input.item)
	if result == nil then
		return nil
	end
	if output == nil then
		return result
	end
	if output.item ~= result.item or output.count + result.count > Items.maxStack(output.item) then
		return nil
	end
	return result
end

--[[
	One furnace tick. `furnace` is a container of kind "furnace" (slots and data are replaced with
	new stack tables, never changed in place). Returns whether anything changed.
]]
function Smelting.tick(furnace: { slots: { [number]: Stack? }, data: { number }? }): boolean
	local data = furnace.data
	if data == nil then
		data = Smelting.newData()
		furnace.data = data
	end
	assert(data, "furnace data")
	local slots = furnace.slots
	local input, fuel, output = slots[1], slots[2], slots[3]
	local changed = false

	-- Another item in the input starts over.
	local cooking = if input then input.item else 0
	if cooking ~= data[5] then
		data[5] = cooking
		data[3] = 0
		data[4] = Smelting.COOK_TIME
		changed = true
	end

	if data[1] > 0 then
		data[1] -= 1
		changed = true
	end
	if data[1] > 0 or (fuel ~= nil and input ~= nil) then
		local result = canBurn(input, output)
		if data[1] <= 0 and result and fuel then
			local burn = Smelting.fuel(fuel.item)
			if burn > 0 then
				data[1], data[2] = burn, burn
				slots[2] = if fuel.count > 1 then { item = fuel.item, count = fuel.count - 1 } else nil
				changed = true
			end
		end
		if data[1] > 0 and result and input then
			data[3] += 1
			changed = true
			if data[3] >= data[4] then
				data[3] = 0
				data[4] = Smelting.COOK_TIME
				slots[3] = if output
					then { item = output.item, count = output.count + result.count }
					else { item = result.item, count = result.count }
				slots[1] = if input.count > 1 then { item = input.item, count = input.count - 1 } else nil
			end
		elseif data[3] ~= 0 then
			data[3] = 0
			changed = true
		end
	elseif data[3] > 0 then
		data[3] = math.clamp(data[3] - 2, 0, data[4])
		changed = true
	end
	return changed
end

-- Is the furnace doing anything (worth ticking)?
function Smelting.active(furnace: { slots: { [number]: Stack? }, data: { number }? }): boolean
	local data = furnace.data
	if data and (data[1] > 0 or data[3] > 0) then
		return true
	end
	local slots = furnace.slots
	return slots[1] ~= nil and slots[2] ~= nil
end

return Smelting

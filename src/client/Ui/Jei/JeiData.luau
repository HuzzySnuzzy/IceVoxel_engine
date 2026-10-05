--!strict
--[[
	JEI's data ("Just Enough Items"): every recipe the game knows, indexed by what it makes and by
	what it uses, for the recipe view (Ui/Jei/RecipeView). Pure: no Roblox APIs, so the tests check
	it.

	Entries come in three categories, in this order (JEI's tabs):

	  crafting  Crafting.recipes (the same compiled recipes the grids match): `inputs` is the 3 x 3
	            display, cells 1..9 row by row, laid out like JEI's CraftingGridHelper (a recipe one
	            wide sits in the middle column, one high in the middle row, a shapeless one fills a
	            1 x 1, 2 x 2 or 3 x 3 square), each cell the items it accepts in creative order;
	  smelting  Smelting.recipes(): `inputs[1]` the items it smelts (a tag's items cycle), `ticks`
	            the cooking time (200);
	  fuel      Smelting.fuels(): `inputs[1]` the fuel, `ticks` its burn time.

	`recipes(item)` lists the entries that make an item (crafting and smelting), `uses(item)` those
	that take it: as an ingredient (tags included), as a smelting input or as a fuel. A catalyst
	(CATALYSTS: the block a category's recipes are made in) also uses every entry of its
	categories, after its own uses, as JEI's "Show uses" on a crafting table or furnace lists them.
	Both return groups by category, only the categories that have entries.

	The index is built once, on first use.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Crafting = require(Shared.Crafting)
local Items = require(Shared.Items)
local Recipes = require(Shared.Crafting.Recipes)
local Smelting = require(Shared.Crafting.Smelting)

type Stack = Items.Stack

export type Category = "crafting" | "smelting" | "fuel"
export type Mode = "recipes" | "uses"

export type Entry = {
	category: Category,
	-- Crafting: the compiled recipe (what JeiTransfer moves into a grid).
	recipe: Crafting.Recipe?,
	-- Display cells: crafting 1..9 (nil = empty), smelting and fuel 1. Each is the item ids the
	-- cell accepts, in creative order (several cycle).
	inputs: { [number]: { number } },
	-- What it makes (nil for fuel).
	output: Stack?,
	shapeless: boolean,
	-- Smelting: ticks to cook one; fuel: burn ticks; crafting: 0.
	ticks: number,
}

export type Group = { category: Category, entries: { Entry } }

local JeiData = {}

JeiData.CATEGORIES = { "crafting", "smelting", "fuel" } :: { Category }
JeiData.TITLES = { crafting = "Crafting", smelting = "Smelting", fuel = "Fuel" } :: { [Category]: string }
-- The item each category's tab shows (Minecraft's catalysts).
JeiData.TAB_ITEMS = { crafting = "CraftingTable", smelting = "Furnace", fuel = "Coal" } :: { [Category]: string }
-- The items each category's recipes are made in (JEI's recipe catalysts), whose uses list them all.
JeiData.CATALYSTS = {
	crafting = { "CraftingTable" },
	-- (Mekanism's Energized Smelter, the Electric Furnace, smelts the same recipes.)
	smelting = { "Furnace", "ElectricFurnace" },
	-- (Mekanism Generators' Heat Generator burns the same fuel.)
	fuel = { "Furnace", "HeatGenerator" },
} :: { [Category]: { string } }
-- JEI's ingredient cycle: one item per second.
JeiData.CYCLE_SECONDS = 1
-- A furnace's smelting time in ticks (one item per 200 ticks: what "burns N items" counts in).
JeiData.SMELT_TICKS = Smelting.COOK_TIME

--[[
	JEI's CraftingGridHelper.getCraftingIndex: where recipe cell `i` (0-based, row by row) of a
	`width` x `height` recipe goes in the 3 x 3 display (0-based).
]]
local function craftingIndex(i: number, width: number, height: number): number
	if width == 1 then
		if height == 3 or height == 2 then
			return i * 3 + 1
		end
		return 4
	elseif height == 1 then
		return i + 3
	elseif width == 2 then
		local index = i
		if i > 1 then
			index += 1
			if i > 3 then
				index += 1
			end
		end
		return index
	elseif height == 2 then
		return i + 3
	end
	return i
end

-- JEI's square for a shapeless recipe of `count` ingredients: 1, 2 or 3 wide.
local function shapelessSize(count: number): number
	if count > 4 then
		return 3
	elseif count > 1 then
		return 2
	end
	return 1
end

-- The item ids of an ingredient set, in creative order (ids grow along Items.list).
local function options(set: { [number]: boolean }): { number }
	local list: { number } = {}
	for item in set do
		if Items.isValid(item) then
			table.insert(list, item)
		end
	end
	table.sort(list)
	return list
end

--[[
	The 3 x 3 display of a crafting recipe: cells 1..9 (row by row) -> the items each accepts, as
	JEI lays them out (see craftingIndex). Empty cells are nil.
]]
function JeiData.craftingGrid(recipe: Crafting.Recipe): { [number]: { number } }
	local grid: { [number]: { number } } = {}
	local width, height = recipe.width, recipe.height
	if recipe.kind == "shapeless" then
		local size = shapelessSize(#recipe.cells)
		width, height = size, size
	end
	for i, cell in recipe.cells do
		if cell then
			local index = craftingIndex(i - 1, width, height)
			if index >= 0 and index < 9 then
				grid[index + 1] = options(cell :: { [number]: boolean })
			end
		end
	end
	return grid
end

--[[ The index ]]

local built = false
local all: { Entry } = {}
-- item -> entries making it / using it (each entry once per item; a catalyst's uses end with the
-- entries of its categories).
local byOutput: { [number]: { Entry } } = {}
local byInput: { [number]: { Entry } } = {}
-- Sorted item lists of Recipes.tags, keyed by the joined ids (to name a tag ingredient).
local tagNames: { [string]: string } = {}

local function keyOf(items: { number }): string
	local parts = table.create(#items)
	for i, item in items do
		parts[i] = tostring(item)
	end
	return table.concat(parts, ",")
end

local function index(map: { [number]: { Entry } }, item: number, entry: Entry)
	local list = map[item]
	if list == nil then
		list = {}
		map[item] = list
	end
	if list[#list] ~= entry then
		table.insert(list, entry)
	end
end

local function add(entry: Entry)
	table.insert(all, entry)
	local output = entry.output
	if output then
		index(byOutput, output.item, entry)
	end
	local seen: { [number]: boolean } = {}
	for cell = 1, 9 do
		local items = entry.inputs[cell]
		if items then
			for _, item in items do
				if not seen[item] then
					seen[item] = true
					index(byInput, item, entry)
				end
			end
		end
	end
end

local function build()
	if built then
		return
	end
	built = true
	for _, recipe in Crafting.recipes do
		add({
			category = "crafting",
			recipe = recipe,
			inputs = JeiData.craftingGrid(recipe),
			output = { item = recipe.result, count = recipe.count },
			shapeless = recipe.kind == "shapeless",
			ticks = 0,
		})
	end
	for _, recipe in Smelting.recipes() do
		local inputs = table.clone(recipe.inputs)
		table.sort(inputs)
		add({
			category = "smelting",
			recipe = nil,
			inputs = { inputs },
			output = recipe.result,
			shapeless = false,
			ticks = Smelting.COOK_TIME,
		})
	end
	for _, fuel in Smelting.fuels() do
		add({
			category = "fuel",
			recipe = nil,
			inputs = { { fuel.item } },
			output = nil,
			shapeless = false,
			ticks = fuel.ticks,
		})
	end
	for name, members in Recipes.tags :: { [string]: { string } } do
		local ids: { number } = {}
		for _, member in members do
			local id = rawget(Items.id :: any, member)
			if id then
				table.insert(ids, id)
			end
		end
		table.sort(ids)
		if #ids > 1 then
			tagNames[keyOf(ids)] = `#{name}`
		end
	end
	-- Catalysts, after everything that takes them (so their own uses come first in each group).
	for category, names in JeiData.CATALYSTS do
		for _, name in names do
			local item = Items.id[name]
			local list: { Entry } = byInput[item] or {}
			byInput[item] = list
			local listed: { [Entry]: boolean } = {}
			for _, entry in list do
				listed[entry] = true
			end
			for _, entry in all do
				if entry.category == category and not listed[entry] then
					table.insert(list, entry)
				end
			end
		end
	end
end

-- Every entry: crafting recipes, then smelting, then fuels.
function JeiData.entries(): { Entry }
	build()
	return all
end

-- Splits entries into groups by category (JeiData.CATEGORIES order), leaving out empty ones.
local function grouped(entries: { Entry }?): { Group }
	local groups: { Group } = {}
	if entries == nil then
		return groups
	end
	for _, category in JeiData.CATEGORIES do
		local list: { Entry } = {}
		for _, entry in entries do
			if entry.category == category then
				table.insert(list, entry)
			end
		end
		if #list > 0 then
			local group: Group = { category = category :: Category, entries = list }
			table.insert(groups, group)
		end
	end
	return groups
end

-- What makes `item`: crafting and smelting recipes (JEI's "Show recipes", R).
function JeiData.recipes(item: number): { Group }
	build()
	return grouped(byOutput[item])
end

-- What takes `item`: recipes using it (tags included), smelting it, burning it, and for a catalyst
-- every entry of its categories (JEI's "Show uses", U).
function JeiData.uses(item: number): { Group }
	build()
	return grouped(byInput[item])
end

function JeiData.lookup(mode: Mode, item: number): { Group }
	return if mode == "recipes" then JeiData.recipes(item) else JeiData.uses(item)
end

-- Does `item` have anything to show in that mode?
function JeiData.has(mode: Mode, item: number): boolean
	build()
	local list = if mode == "recipes" then byOutput[item] else byInput[item]
	return list ~= nil and #list > 0
end

--[[ Showing entries ]]

--[[
	The item a cell shows at `time` (seconds): its only item, the `focus` item when the cell takes it
	(JEI shows the looked-up item in its slots), else the next of its options every second.
]]
function JeiData.shown(items: { number }?, time: number, focus: number?): number?
	if items == nil or #items == 0 then
		return nil
	end
	if #items == 1 then
		return items[1]
	end
	if focus and table.find(items, focus) then
		return focus
	end
	local step = math.floor(time / JeiData.CYCLE_SECONDS)
	return items[step % #items + 1]
end

-- The tag a cell's items are ("#planks"), or nil for a single item or an unnamed set.
function JeiData.tagOf(items: { number }?): string?
	if items == nil or #items < 2 then
		return nil
	end
	build()
	return tagNames[keyOf(items)]
end

-- A number of seconds or items the way the recipe view writes it: 10, 1.5, 0.5.
local function amount(value: number): string
	local rounded = math.floor(value * 10 + 0.5) / 10
	if rounded == math.floor(rounded) then
		return tostring(math.floor(rounded))
	end
	return string.format("%.1f", rounded)
end

-- A smelting recipe's time: "10 s" (ticks at 20 per second).
function JeiData.smeltText(ticks: number): string
	return `{amount(ticks / 20)} s`
end

-- A fuel's worth: "Burns 8 items", "Burns 1.5 items", "Burns 1 item" (burn ticks / 200).
function JeiData.fuelText(ticks: number): string
	local items = ticks / JeiData.SMELT_TICKS
	local text = amount(items)
	return `Burns {text} item{if text == "1" then "" else "s"}`
end

--[[ Pages ]]

-- How many pages `count` things take at `perPage` a page (at least 1).
function JeiData.pageCount(count: number, perPage: number): number
	if perPage < 1 then
		return 1
	end
	return math.max(1, math.ceil(count / perPage))
end

-- A page number moved by `delta`, wrapping around like JEI's arrows (pages 1..count).
function JeiData.turn(page: number, delta: number, count: number): number
	if count < 1 then
		return 1
	end
	return (page - 1 + delta) % count + 1
end

-- The items the item list shows for a search text: Items.search, in creative order.
function JeiData.filter(query: string): { Items.ItemDef }
	return Items.search(query)
end

return JeiData

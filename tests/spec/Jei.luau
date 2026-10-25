--[[
	JEI's pure parts: the recipe index (Ui/Jei/JeiData: recipes, uses, the 3 x 3 display, tags,
	texts), the smelting and fuel enumerations it reads (Crafting/Smelting), the layouts
	(Ui/Jei/JeiLayout: the list beside a panel, and docked in every ITEMS body the survival
	inventory makes, Ui/InventoryColumns; cells told from placement) and the recipe transfer
	(Ui/Jei/JeiTransfer), whose plans are applied with Inventory/Menu and must leave exactly the
	recipe in the grid without losing anything. The machines' categories: the Metal Miner's
	Duplicating and the Ammo Press's Pressing (their entries from Machines.info, catalysts, texts,
	layouts and pages, and their Config switches), and every lookup's tabs fitting over the view.
]]

local Loader = require("../lib/Loader")

return function(t, shared, require, _server, client)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Types = require(shared.Inventory.Types)
	local Menu = require(shared.Inventory.Menu)
	local Crafting = require(shared.Crafting)
	local Recipes = require(shared.Crafting.Recipes)
	local Smelting = require(shared.Crafting.Smelting)
	local JeiData = require(client.Ui.Jei.JeiData)
	local JeiLayout = require(client.Ui.Jei.JeiLayout)
	local JeiTransfer = require(client.Ui.Jei.JeiTransfer)
	local Theme = require(client.Ui.Theme)

	local id = Items.id

	local function S(item: number, count: number, damage: number?)
		return { item = item, count = count, damage = damage }
	end

	-- The crafting recipe making `result` (the first one, or the one `pick` accepts).
	local function recipeFor(result: number, pick: ((any) -> boolean)?)
		for _, recipe in Crafting.recipes do
			if recipe.result == result and (pick == nil or pick(recipe)) then
				return recipe
			end
		end
		error(`no recipe for {Items.displayName(result)}`)
	end

	-- The display cells (1..9) of a recipe that hold something.
	local function cellsOf(recipe): { number }
		local cells = {}
		for cell = 1, 9 do
			if JeiData.craftingGrid(recipe)[cell] then
				table.insert(cells, cell)
			end
		end
		return cells
	end

	local function same(a: { number }, b: { number }, what: string)
		t.eq(#a, #b, `{what}: count`)
		for i = 1, #b do
			t.eq(a[i], b[i], `{what}: [{i}]`)
		end
	end

	local function categories(groups): { string }
		local list = {}
		for _, group in groups do
			table.insert(list, group.category)
		end
		return list
	end

	local function find(groups, category: string, test: (any) -> boolean): boolean
		for _, group in groups do
			if group.category == category then
				for _, entry in group.entries do
					if test(entry) then
						return true
					end
				end
			end
		end
		return false
	end

	local function makes(item: number)
		return function(entry)
			return entry.output ~= nil and entry.output.item == item
		end
	end

	--[[ Smelting and fuel enumerations ]]

	t.test("jei: Smelting.recipes and fuels list what the furnace does", function()
		local recipes = Smelting.recipes()
		t.eq(#recipes, #Recipes.smelting, "one per Recipes.smelting line")
		for _, recipe in recipes do
			t.ok(#recipe.inputs >= 1, "inputs")
			for _, input in recipe.inputs do
				local result = Smelting.result(input)
				t.ok(result ~= nil, `{Items.displayName(input)} smelts`)
				t.eq(result.item, recipe.result.item, `{Items.displayName(input)} result`)
			end
		end
		local logs = 0
		for _, recipe in recipes do
			if recipe.result.item == id.Charcoal then
				logs = #recipe.inputs
			end
		end
		t.eq(logs, #Recipes.tags.logs, "#logs stays one recipe with every log")
		-- New tables: changing them changes nothing.
		recipes[1].inputs[1] = id.Dirt
		t.ok(Smelting.recipes()[1].inputs[1] ~= id.Dirt, "copies")

		local fuels = Smelting.fuels()
		local last = -1
		for _, fuel in fuels do
			t.ok(fuel.item > last, "fuels in id order")
			last = fuel.item
			t.eq(Smelting.fuel(fuel.item), fuel.ticks, `{Items.displayName(fuel.item)} burn time`)
		end
		local count = 0
		for _, def in Items.list do
			if Smelting.fuel(def.id) > 0 then
				count += 1
			end
		end
		t.eq(#fuels, count, "every fuel listed")
	end)

	--[[ The index ]]

	t.test("jei: every recipe, smelting recipe and fuel is an entry", function()
		local counts = { crafting = 0, smelting = 0, fuel = 0 }
		for _, entry in JeiData.entries() do
			counts[entry.category] = (counts[entry.category] or 0) + 1
		end
		t.eq(counts.crafting, #Crafting.recipes, "crafting")
		t.eq(counts.smelting, #Smelting.recipes(), "smelting")
		t.eq(counts.fuel, #Smelting.fuels(), "fuel")
		-- Every crafting recipe is found among the recipes of its result, and its display keeps
		-- every ingredient (no two in one cell).
		for _, recipe in Crafting.recipes do
			local ingredients = 0
			for _, cell in recipe.cells do
				if cell then
					ingredients += 1
				end
			end
			t.eq(#cellsOf(recipe), ingredients, `{Items.displayName(recipe.result)}: every ingredient drawn`)
			t.ok(
				find(JeiData.recipes(recipe.result), "crafting", function(entry)
					return entry.recipe == recipe
				end),
				`{Items.displayName(recipe.result)} recipe listed`
			)
		end
	end)

	t.test("jei: the 3 x 3 display follows JEI's crafting grid", function()
		-- Sticks (1 x 2) and torches go in the middle column; a 2 x 2 at the top left.
		same(cellsOf(recipeFor(id.Stick)), { 2, 5 }, "stick")
		same(cellsOf(recipeFor(id.Torch)), { 2, 5 }, "torch")
		same(cellsOf(recipeFor(id.CraftingTable)), { 1, 2, 4, 5 }, "crafting table")
		-- A swordlike 1 x 3 down the middle; a full 3 x 3 with a hole.
		same(cellsOf(recipeFor(id.WoodenSword)), { 2, 5, 8 }, "sword")
		same(cellsOf(recipeFor(id.Furnace)), { 1, 2, 3, 4, 6, 7, 8, 9 }, "furnace")
		-- Three wide and two high: the lower two rows (helmet "XXX","X X", boots "X X","X X").
		same(cellsOf(recipeFor(id.IronHelmet)), { 4, 5, 6, 7, 9 }, "helmet")
		same(cellsOf(recipeFor(id.IronBoots)), { 4, 6, 7, 9 }, "boots")
		-- Shapeless: one in the middle, two to four in a 2 x 2, more in the 3 x 3.
		same(cellsOf(recipeFor(id.Planks)), { 5 }, "planks")
		same(cellsOf(recipeFor(id.Andesite)), { 1, 2 }, "andesite")
		same(cellsOf(recipeFor(id.PackedIce)), { 1, 2, 3, 4, 5, 6, 7, 8, 9 }, "packed ice")
		t.ok(JeiData.entries()[1].category == "crafting", "crafting first")
		-- A tag cell holds every item of the tag, in creative order.
		local grid = JeiData.craftingGrid(recipeFor(id.Stick))
		t.eq(#grid[2], #Recipes.tags.planks, "#planks options")
		for i = 2, #grid[2] do
			t.ok(grid[2][i] > grid[2][i - 1], "creative order")
		end
		t.eq(JeiData.tagOf(grid[2]), "#planks", "tag name")
		t.eq(JeiData.tagOf({ id.Stick }), nil, "a single item is no tag")
		t.eq(JeiData.tagOf(nil), nil, "empty cell")
	end)

	t.test("jei: recipes of an item, by category", function()
		local iron = JeiData.recipes(id.IronIngot)
		same(categories(iron) :: any, { "crafting", "smelting" } :: any, "iron ingot categories")
		t.ok(
			find(iron, "crafting", function(entry)
				return table.find(entry.inputs[1] or {}, id.IronNugget) ~= nil
			end),
			"from nuggets"
		)
		t.ok(
			find(iron, "crafting", function(entry)
				return entry.inputs[5] ~= nil and table.find(entry.inputs[5], id.IronBlock) ~= nil
			end),
			"from a block"
		)
		t.ok(
			find(iron, "smelting", function(entry)
				return table.find(entry.inputs[1], id.RawIron) ~= nil
			end),
			"smelted raw iron"
		)
		local charcoal = JeiData.recipes(id.Charcoal)
		same(categories(charcoal) :: any, { "smelting" } :: any, "charcoal")
		t.eq(#charcoal[1].entries[1].inputs[1], #Recipes.tags.logs, "any log")
		t.eq(#JeiData.recipes(id.Dirt), 0, "dirt has no recipe")
		t.ok(not JeiData.has("recipes", id.Dirt), "has: dirt")
		t.ok(JeiData.has("recipes", id.Torch), "has: torch")
		-- Every result of a lookup makes that item (a fluid entry: the fluid it stands for).
		for _, def in Items.list do
			for _, group in JeiData.recipes(def.id) do
				for _, entry in group.entries do
					local output = entry.output
					local fluid = entry.fluidOutput
					local made = (output ~= nil and output.item == def.id)
						or (fluid ~= nil and table.find(JeiData.fluidItems(fluid.fluid), def.id) ~= nil)
					t.ok(made, `{def.name}: entry makes it`)
				end
			end
		end
	end)

	t.test("jei: uses of an item: ingredients (tags too), smelting, fuel", function()
		local birch = JeiData.uses(id.BirchPlanks)
		same(categories(birch) :: any, { "crafting", "fuel" } :: any, "birch planks categories")
		for _, item in { id.Stick, id.CraftingTable, id.Chest, id.WoodenPickaxe } do
			t.ok(find(birch, "crafting", makes(item)), `birch planks make {Items.displayName(item)}`)
		end
		t.eq(birch[2].entries[1].ticks, 300, "planks burn 300 ticks")
		local log = JeiData.uses(id.OakLog)
		same(categories(log) :: any, { "crafting", "smelting", "fuel" } :: any, "oak log categories")
		t.ok(find(log, "crafting", makes(id.Planks)), "log -> planks")
		t.ok(find(log, "smelting", makes(id.Charcoal)), "log -> charcoal")
		local coal = JeiData.uses(id.Coal)
		t.ok(find(coal, "crafting", makes(id.Torch)), "coal -> torches (#coals)")
		t.ok(find(coal, "crafting", makes(id.CoalBlock)), "coal -> block")
		t.ok(
			find(coal, "fuel", function(entry)
				return entry.ticks == 1600
			end),
			"coal burns 1600"
		)
		t.ok(find(JeiData.uses(id.IronPickaxe), "smelting", makes(id.IronNugget)), "pickaxe melts")
		t.eq(#JeiData.uses(id.Lantern), 0, "nothing uses a lantern")
		-- Every use really takes the item (or the item is its category's catalyst), and lists it once.
		for _, def in Items.list do
			for _, group in JeiData.uses(def.id) do
				local seen = {}
				local catalyst = table.find(JeiData.CATALYSTS[group.category], def.name) ~= nil
				for _, entry in group.entries do
					t.ok(not seen[entry], `{def.name}: entry listed once`)
					seen[entry] = true
					local takes = false
					for cell = 1, 9 do
						if entry.inputs[cell] and table.find(entry.inputs[cell], def.id) then
							takes = true
						end
					end
					-- (A fluid stack takes its bucket and its block.)
					for _, stack in entry.fluidInputs or {} do
						if table.find(JeiData.fluidItems(stack.fluid), def.id) then
							takes = true
						end
					end
					t.ok(takes or catalyst, `{def.name}: the entry takes it`)
				end
			end
		end
	end)

	t.test("jei: uses of a catalyst list every recipe of its categories, its own uses first", function()
		local counts = {}
		for _, entry in JeiData.entries() do
			counts[entry.category] = (counts[entry.category] or 0) + 1
		end
		t.eq(counts.crafting, #Crafting.recipes, "every crafting recipe is an entry")
		t.eq(counts.fuel, #Smelting.fuels(), "every fuel is an entry")

		local furnace = JeiData.uses(id.Furnace)
		-- (A furnace goes into the Heat Generator: its own crafting use comes first.)
		same(categories(furnace) :: any, { "crafting", "smelting", "fuel" } :: any, "furnace categories")
		t.ok(find(furnace, "crafting", makes(id.HeatGenerator)), "furnace: into a Heat Generator")
		t.eq(#furnace[2].entries, counts.smelting, "furnace: every smelting recipe")
		t.eq(#furnace[3].entries, counts.fuel, "furnace: every fuel")
		t.ok(find(furnace, "smelting", makes(id.IronIngot)), "furnace: iron ore -> ingot")
		t.ok(JeiData.has("uses", id.Furnace), "has: furnace")
		-- Mekanism Generators' Heat Generator burns the same fuel, and lava.
		local generator = JeiData.uses(id.HeatGenerator)
		same(categories(generator) :: any, { "fuel", "heating" } :: any, "heat generator categories")
		t.eq(#generator[1].entries, counts.fuel, "heat generator: every fuel")
		t.eq(#generator[2].entries, 1, "heat generator: lava")

		local workbench = JeiData.uses(id.CraftingTable)
		same(categories(workbench) :: any, { "crafting", "fuel" } :: any, "crafting table categories")
		t.eq(#workbench[1].entries, counts.crafting, "crafting table: every crafting recipe")
		t.ok(find(workbench, "crafting", makes(id.Furnace)), "crafting table: furnace recipe")
		-- Its own use (as a fuel) is still there, once: the catalyst adds nothing to that category.
		t.eq(#workbench[2].entries, 1, "crafting table: burns")
		t.ok(table.find(workbench[2].entries[1].inputs[1], id.CraftingTable) ~= nil, "the fuel entry is the table")

		-- In a catalyst's own categories, the entries that take it come before the rest.
		for category, names in JeiData.CATALYSTS do
			for _, name in names do
				local item = id[name]
				for _, group in JeiData.uses(item) do
					if group.category == category then
						local catalysed = false
						for _, entry in group.entries do
							local takes = false
							for cell = 1, 9 do
								if entry.inputs[cell] and table.find(entry.inputs[cell], item) then
									takes = true
								end
							end
							t.ok(not (takes and catalysed), `{name}: own {category} uses come first`)
							catalysed = catalysed or not takes
						end
					end
				end
			end
		end
	end)

	t.test("jei: cycling cells, focus, texts and pages", function()
		local options = { 10, 20, 30 }
		t.eq(JeiData.shown(options, 0), 10, "t = 0")
		t.eq(JeiData.shown(options, 0.99), 10, "same second")
		t.eq(JeiData.shown(options, 1), 20, "next second")
		t.eq(JeiData.shown(options, 3.5), 10, "wraps")
		t.eq(JeiData.shown(options, 2, 20), 20, "the looked-up item stays")
		t.eq(JeiData.shown(options, 2, 99), 30, "focus elsewhere cycles")
		t.eq(JeiData.shown({ 7 }, 5), 7, "single")
		t.eq(JeiData.shown(nil, 5), nil, "empty")
		t.eq(JeiData.smeltText(200), "10 s", "smelting time")
		t.eq(JeiData.fuelText(1600), "Burns 8 items", "coal")
		t.eq(JeiData.fuelText(300), "Burns 1.5 items", "planks")
		t.eq(JeiData.fuelText(200), "Burns 1 item", "wooden tools")
		t.eq(JeiData.fuelText(100), "Burns 0.5 items", "stick")
		t.eq(JeiData.fuelText(16000), "Burns 80 items", "coal block")
		t.eq(JeiData.pageCount(0, 10), 1, "no items: one page")
		t.eq(JeiData.pageCount(20, 10), 2, "exact")
		t.eq(JeiData.pageCount(21, 10), 3, "rounded up")
		t.eq(JeiData.turn(1, -1, 3), 3, "wraps back")
		t.eq(JeiData.turn(3, 1, 3), 1, "wraps forward")
		t.eq(JeiData.turn(2, 1, 3), 3, "next")
		t.eq(#JeiData.filter(""), #Items.list, "empty search: everything")
		t.ok(#JeiData.filter("plank") >= 5, "search by name")
	end)

	--[[ Layouts ]]

	type Box = { x: number, y: number, w: number, h: number, what: string }

	local function overlaps(a: Box, b: Box): boolean
		return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
	end

	-- The drawn boxes of an entry (slot frames, gauges, buttons, text) at its origin.
	local function entryBoxes(category: string, ox: number, oy: number): { Box }
		local layout = JeiLayout.entry(category)
		local boxes: { Box } = {}
		local function add(r, what)
			table.insert(boxes, { x = ox + r.x, y = oy + r.y, w = r.w, h = r.h, what = what })
		end
		for i, spot in layout.inputs do
			add({ x = spot.x - 1, y = spot.y - 1, w = 18, h = 18 }, `input {i}`)
		end
		local out = layout.output
		if out then
			local inset = if out.big then 5 else 1
			local size = if out.big then 26 else 18
			add({ x = out.x - inset, y = out.y - inset, w = size, h = size }, "output")
		end
		-- (Fluid stacks are drawn in a slot's 18 x 18 frame.)
		for i, spot in layout.fluidInputs do
			add({ x = spot.x - 1, y = spot.y - 1, w = 18, h = 18 }, `fluid input {i}`)
		end
		local fluidOut = layout.fluidOutput
		if fluidOut then
			add({ x = fluidOut.x - 1, y = fluidOut.y - 1, w = 18, h = 18 }, "fluid output")
		end
		for _, name in { "arrow", "flame", "plus", "shapeless" } do
			local r = (layout :: any)[name]
			if r then
				add(r, name)
			end
		end
		for i, r in layout.texts do
			add(r, `text {i}`)
		end
		return boxes
	end

	t.test("jei: recipe view pages fit the panel without overlaps", function()
		for _, category in JeiData.CATEGORIES do
			local layout = JeiLayout.entry(category)
			local per = JeiLayout.perPage(category)
			t.ok(per >= 2, `{category}: at least two a page`)
			-- Each part inside its entry, none over another.
			local parts = entryBoxes(category, 0, 0)
			for i, a in parts do
				t.ok(
					a.x >= 0 and a.y >= 0 and a.x + a.w <= layout.w and a.y + a.h <= layout.h,
					`{category}: {a.what} inside`
				)
				for j = i + 1, #parts do
					t.ok(not overlaps(a, parts[j]), `{category}: {a.what} overlaps {parts[j].what}`)
				end
			end
			-- Full pages and short ones: inside the recipe area, apart.
			for shown = 1, per do
				local boxes: { Box } = {}
				for i = 1, shown do
					local x, y = JeiLayout.entryOrigin(category, i, shown)
					table.insert(boxes, { x = x, y = y, w = layout.w, h = layout.h, what = `recipe {i}` })
				end
				for i, a in boxes do
					t.ok(a.x >= 3 and a.x + a.w <= JeiLayout.VIEW_WIDTH - 3, `{category}: {a.what} inside horizontally`)
					t.ok(
						a.y >= JeiLayout.AREA_TOP and a.y + a.h <= JeiLayout.AREA_BOTTOM,
						`{category}: {a.what} of {shown} inside vertically`
					)
					for j = i + 1, #boxes do
						t.ok(not overlaps(a, boxes[j]), `{category}: {a.what} overlaps {boxes[j].what}`)
					end
				end
			end
		end
		-- The header's buttons and rows.
		local header = {
			{ x = JeiLayout.BACK.x, y = JeiLayout.BACK.y, w = JeiLayout.BACK.w, h = JeiLayout.BACK.h, what = "back" },
			{
				x = JeiLayout.CLOSE.x,
				y = JeiLayout.CLOSE.y,
				w = JeiLayout.CLOSE.w,
				h = JeiLayout.CLOSE.h,
				what = "close",
			},
			{ x = JeiLayout.PREV.x, y = JeiLayout.PREV.y, w = JeiLayout.PREV.w, h = JeiLayout.PREV.h, what = "prev" },
			{ x = JeiLayout.NEXT.x, y = JeiLayout.NEXT.y, w = JeiLayout.NEXT.w, h = JeiLayout.NEXT.h, what = "next" },
		}
		for i, a in header do
			t.ok(a.x >= 3 and a.x + a.w <= JeiLayout.VIEW_WIDTH - 3 and a.y >= 3, `{a.what} inside`)
			t.ok(a.y + a.h <= JeiLayout.AREA_TOP, `{a.what} above the recipes`)
			for j = i + 1, #header do
				t.ok(not overlaps(a, header[j]), `{a.what} overlaps {header[j].what}`)
			end
		end
		-- The title bar (a section bar, Theme's SECTION_HEADER tall) across the panel holds Back
		-- and the close button, and stays above the page row.
		local bar = JeiLayout.TITLE_BAR
		t.eq(bar.h, Theme.Size.SECTION_HEADER, "the title bar is a section bar's height")
		t.ok(bar.x == 0 and bar.w == JeiLayout.VIEW_WIDTH, "the title bar spans the panel")
		for _, button in { JeiLayout.BACK, JeiLayout.CLOSE } do
			t.ok(
				button.x >= bar.x
					and button.y >= bar.y
					and button.x + button.w <= bar.x + bar.w
					and button.y + button.h <= bar.y + bar.h,
				`a button at {button.x} inside the title bar`
			)
		end
		t.ok(bar.y + bar.h <= JeiLayout.PREV.y, "the title bar above the page row")
	end)

	t.test("jei: the item list fits right of the inventory, collapses, hides", function()
		local function check(width: number, height: number, scale: number, top: number)
			local guiRight = width / 2 + 88 * scale
			local layout = JeiLayout.list(width, top, height, guiRight, scale)
			if layout == nil then
				return nil
			end
			t.ok(layout.columns >= JeiLayout.MIN_COLUMNS and layout.columns <= JeiLayout.MAX_COLUMNS, "columns")
			t.ok(layout.x >= guiRight + JeiLayout.GAP * scale - 1e-6, `{width}: clear of the inventory`)
			t.ok(layout.x + layout.width * scale <= width - JeiLayout.MARGIN * scale + 1e-6, `{width}: on screen`)
			t.ok(layout.y >= top, `{width}: below the top bar`)
			t.ok(layout.y + layout.height * scale <= height + 1e-6, `{width}: above the bottom`)
			t.eq(layout.height, JeiLayout.NAV_HEIGHT + layout.rows * JeiLayout.SLOT + JeiLayout.SEARCH_HEIGHT, "height")
			local parts = JeiLayout.listParts(layout)
			t.ok(not overlaps(parts.prev :: any, parts.next :: any), "arrows apart")
			t.ok(parts.search.y >= parts.grid.y + parts.grid.h, "search under the grid")
			t.ok(parts.search.y + parts.search.h <= layout.height, "search inside")
			return layout
		end
		local big = check(1920, 1080, 3, 36)
		t.ok(big ~= nil and big.columns == JeiLayout.MAX_COLUMNS, "a wide screen gets every column")
		t.ok(big ~= nil and big.rows >= 10, "and many rows")
		local huge = check(3840, 2160, 3, 36)
		t.ok(huge ~= nil and huge.rows == JeiLayout.MAX_ROWS, "rows capped on tall screens")
		local phone = check(800, 400, 2, 36)
		t.ok(
			phone ~= nil and phone.columns >= 3 and phone.columns < JeiLayout.MAX_COLUMNS,
			"a phone gets fewer columns"
		)
		t.eq(check(420, 400, 2, 36), nil, "too narrow: hidden")
		t.eq(check(1920, 60, 3, 36), nil, "too low: hidden")
		-- Room for two columns is not enough (at least three, or none); three are kept.
		t.eq(JeiLayout.MIN_COLUMNS, 3, "at least three columns")
		t.eq(check(560, 400, 2, 36), nil, "two columns' room: hidden")
		local three = check(620, 400, 2, 36)
		t.ok(three ~= nil and three.columns == 3, "three columns' room: shown")
	end)

	t.test("jei: the list's page text fits its row", function()
		-- 8 GUI pixels a character, like the pixel font.
		local function measure(text: string): number
			return #text * 8
		end
		local function room(columns: number): number
			local layout = {
				columns = columns,
				rows = 4,
				x = 0,
				y = 0,
				width = columns * JeiLayout.SLOT,
				height = 0,
				scale = 1,
			}
			return JeiLayout.listParts(layout).page.w
		end
		t.eq(JeiLayout.pageText(3, 12, room(9), measure), "3 / 12", "wide: n / m")
		t.eq(JeiLayout.pageText(3, 12, room(3), measure), "3", "narrow: just the page")
		for columns = JeiLayout.MIN_COLUMNS, JeiLayout.MAX_COLUMNS do
			local text = JeiLayout.pageText(12, 12, room(columns), measure)
			t.ok(measure(text) <= room(columns), `{columns} columns: "{text}" fits`)
		end
	end)

	t.test("jei: the docked list fills the inventory's ITEMS body", function()
		local SLOT, PAD = JeiLayout.SLOT, JeiLayout.DOCK_PAD
		local function check(w: number, h: number, scale: number)
			local layout = JeiLayout.docked(40, 70, w, h, scale)
			if layout == nil then
				return nil
			end
			t.ok(layout.docked == true, "docked")
			t.eq(layout.x, 40, "its top left as given")
			t.eq(layout.y, 70)
			t.eq(layout.width, w, "the whole rect")
			t.eq(layout.height, h)
			t.eq(layout.scale, scale)
			t.ok(layout.columns >= JeiLayout.MIN_COLUMNS and layout.columns <= JeiLayout.MAX_COLUMNS, "columns")
			t.ok(layout.rows >= 1 and layout.rows <= JeiLayout.MAX_ROWS, "rows")
			t.ok(layout.columns * SLOT + 2 * PAD <= w, `{w}: the columns fit`)
			t.ok(
				JeiLayout.NAV_HEIGHT + layout.rows * SLOT + JeiLayout.SEARCH_HEIGHT + 2 * PAD <= h,
				`{h}: the rows fit`
			)
			t.ok(
				layout.columns == JeiLayout.MAX_COLUMNS or (layout.columns + 1) * SLOT + 2 * PAD > w,
				`{w}: as many columns as fit`
			)
			t.ok(
				layout.rows == JeiLayout.MAX_ROWS
					or JeiLayout.NAV_HEIGHT + (layout.rows + 1) * SLOT + JeiLayout.SEARCH_HEIGHT + 2 * PAD > h,
				`{h}: as many rows as fit`
			)
			local parts = JeiLayout.listParts(layout)
			for name, part in parts :: any do
				t.ok(
					part.x >= PAD and part.y >= PAD and part.x + part.w <= w - PAD and part.y + part.h <= h - PAD,
					`{name} inside the dock's padding`
				)
			end
			t.eq(parts.grid.w, layout.columns * SLOT, "the grid is its cells")
			t.ok(math.abs(parts.grid.x + parts.grid.w / 2 - w / 2) <= 1, "the grid centred in the width")
			t.ok(not overlaps(parts.prev :: any, parts.next :: any), "arrows apart")
			t.ok(parts.search.y >= parts.grid.y + parts.grid.h, "search under the grid")
			return layout
		end
		local full = check(176, 52, 4)
		t.ok(full ~= nil and full.columns == 9 and full.rows == 1, "ITEMS at its least: nine columns, one row")
		t.eq(check(176, 51, 4), nil, "no room for a row: hidden")
		t.eq(check(55, 200, 2), nil, "under three columns: hidden")
		local three = check(56, 200, 2)
		t.ok(three ~= nil and three.columns == 3, "three columns' room: shown")
		local tall = check(176, 2000, 1)
		t.ok(tall ~= nil and tall.rows == JeiLayout.MAX_ROWS, "rows capped")
		t.eq(JeiLayout.docked(0, 0, 176, 200, 0), nil, "no scale: hidden")
		-- Every ITEMS body the inventory makes holds nine columns.
		local Blocks = require(shared.Blocks)
		local Machines = require(shared.Machines)
		local InventoryColumns = require(client.Ui.InventoryColumns)
		local MenuLayout = require(client.Ui.MenuLayout)
		local containers: { any } = {
			false,
			{ kind = "chest", block = Blocks.id.Chest, size = 27, slots = {} },
			{ kind = "chest", block = Blocks.id.Chest, size = 54, slots = {} },
			Types.newCrafting("crafting", Blocks.id.CraftingTable),
			{ kind = "furnace", block = Blocks.id.Furnace, size = 3, slots = {} },
		}
		for block = 0, Blocks.count - 1 do
			if Machines.isMachine(block) then
				table.insert(containers, Machines.newContainer(block))
			end
		end
		local count = 0
		for _, container in containers do
			local panel = if container then MenuLayout.panel(container) else nil
			for _, mode in { "wide", "narrow" } do
				for _, input in { { false, 14 }, { true, 22 }, { true, 26 } } do
					for collapsed = 0, 31 do
						if not bit32.btest(collapsed, InventoryColumns.BIT.jei) then
							local layoutInput: any = {
								mode = mode,
								touch = input[1],
								top = input[2],
								container = if panel then panel.height else nil,
								panel = panel,
								equipment = container == false,
								collapsed = collapsed,
							}
							local _, least = InventoryColumns.minimum(layoutInput)
							for _, height in { least, least + 37, InventoryColumns.MAX_HEIGHT } do
								layoutInput.height = height
								local body = InventoryColumns.arrange(layoutInput).jei :: any
								t.ok(body ~= nil, "ITEMS open has a body")
								local docked = JeiLayout.docked(0, 0, body.w, body.h, 2)
								t.ok(docked ~= nil and docked.columns == 9, `{body.w} x {body.h}: nine columns`)
								count += 1
							end
						end
					end
				end
			end
		end
		t.ok(count > 1000, `{count} ITEMS bodies`)
	end)

	t.test("jei: layouts tell their cells from their placement", function()
		local docked = JeiLayout.docked(100, 100, 176, 2 + 32 + 4 * 18, 3) :: any
		t.ok(docked ~= nil and docked.rows == 4, "four rows docked")
		local list = {
			columns = docked.columns,
			rows = docked.rows,
			x = 100,
			y = 100,
			width = docked.columns * JeiLayout.SLOT,
			height = JeiLayout.NAV_HEIGHT + docked.rows * JeiLayout.SLOT + JeiLayout.SEARCH_HEIGHT,
			scale = 3,
			docked = false,
		}
		t.ok(JeiLayout.sameCells(docked, list), "equal columns and rows: the same cells")
		t.ok(not JeiLayout.samePlacement(docked, list), "but not the same placement")
		t.ok(JeiLayout.sameCells(docked, docked) and JeiLayout.samePlacement(docked, docked), "itself")
		local again = JeiLayout.docked(100, 100, 176, 2 + 32 + 4 * 18, 3) :: any
		t.ok(JeiLayout.samePlacement(docked, again), "the same dock: the same placement")
		-- A taller dock with its rows capped: the same cells, not the same placement.
		local capped = JeiLayout.docked(100, 100, 176, 2000, 3) :: any
		local taller = JeiLayout.docked(100, 100, 176, 2400, 3) :: any
		t.eq(capped.rows, JeiLayout.MAX_ROWS)
		t.ok(JeiLayout.sameCells(capped, taller), "capped rows: the same cells")
		t.ok(not JeiLayout.samePlacement(capped, taller), "taller: placed again")
		-- Moved, scaled: placed again, cells kept.
		local moved = JeiLayout.docked(101, 100, 176, 2000, 3) :: any
		t.ok(JeiLayout.sameCells(capped, moved) and not JeiLayout.samePlacement(capped, moved), "moved")
		local scaled = JeiLayout.docked(100, 100, 176, 2000, 4) :: any
		t.ok(JeiLayout.sameCells(capped, scaled) and not JeiLayout.samePlacement(capped, scaled), "scaled")
		-- The list beside a panel says it is not docked.
		local beside = JeiLayout.list(1920, 36, 1080, 1100, 3) :: any
		t.ok(beside ~= nil and beside.docked == false, "list: not docked")
		local parts = JeiLayout.listParts(beside)
		t.eq(parts.prev.x, 0, "a list's parts start at its edge")
		t.eq(parts.grid.w, beside.width)
	end)

	--[[ Transfer ]]

	local function window0(stacks: { [number]: any }, grid: { [number]: any }?, cursor: any?)
		local inventory = Types.newInventory()
		for slot, stack in stacks do
			inventory.slots[slot] = stack
		end
		inventory.cursor = cursor
		local window = Types.newWindow(inventory)
		for i, stack in grid or {} do
			window.container.slots[1 + i] = stack
		end
		Menu.updateCraft(window)
		return window
	end

	local function tableWindow(stacks: { [number]: any }, grid: { [number]: any }?, cursor: any?)
		local window = window0(stacks, nil, cursor)
		window.id = 3
		window.container = Types.newCrafting("crafting", Blocks.id.CraftingTable)
		for i, stack in grid or {} do
			window.container.slots[1 + i] = stack
		end
		Menu.updateCraft(window)
		return window
	end

	local function totals(window): { [string]: number }
		local out = {}
		local function note(stack)
			if stack then
				local key = `{stack.item}:{stack.damage or 0}`
				out[key] = (out[key] or 0) + stack.count
			end
		end
		for slot = 0, Menu.size(window) - 1 do
			if not Menu.isCraftResult(window, slot) then
				note(Menu.get(window, slot))
			end
		end
		note(window.inventory.cursor)
		return out
	end

	local function sameTotals(a, b, what: string)
		for key, n in a do
			t.eq(b[key] or 0, n, `{what}: {key} kept`)
		end
		for key, n in b do
			t.eq(a[key] or 0, n, `{what}: {key} not made up`)
		end
	end

	-- Plans, applies with Menu and checks: the grid holds the recipe `sets` deep, the result is the
	-- recipe's, nothing thrown or lost, the cursor empty. Returns the window after.
	local function transfer(window, recipe, all: boolean?, what: string)
		local before = totals(window)
		local actions, reason = JeiTransfer.plan(window, recipe, all)
		t.ok(actions ~= nil, `{what}: planned ({reason})`)
		local sets = if all then JeiTransfer.sets(window, recipe) else 1
		for _, action in actions do
			local thrown = Menu.apply(window, action, false)
			t.eq(#thrown, 0, `{what}: nothing thrown`)
		end
		local width = JeiTransfer.gridWidth(window)
		local targets = JeiTransfer.targets(recipe, width)
		local grid = JeiData.craftingGrid(recipe)
		local used = {}
		for cell, slot in targets do
			used[slot] = true
			local stack = Menu.get(window, slot)
			t.ok(stack ~= nil, `{what}: cell {cell} filled`)
			t.ok(table.find(grid[cell], stack.item) ~= nil, `{what}: cell {cell} takes it`)
			t.eq(stack.count, sets, `{what}: cell {cell} count`)
		end
		for slot = 1, width * width do
			if not used[slot] then
				t.eq(Menu.get(window, slot), nil, `{what}: grid slot {slot} empty`)
			end
		end
		local result = Menu.get(window, 0)
		t.ok(result ~= nil and result.item == recipe.result, `{what}: result`)
		t.eq(window.inventory.cursor, nil, `{what}: cursor empty`)
		sameTotals(before, totals(window), what)
		return window
	end

	t.test("transfer: a crafting table in the 2 x 2 grid, one set and all", function()
		local recipe = recipeFor(id.CraftingTable)
		local window = transfer(window0({ [1] = S(id.Planks, 64) }), recipe, false, "one set")
		t.eq(window.inventory.slots[1].count, 60, "four planks used")
		-- Shift: as many as there are (64 / 4 = 16 each).
		local all = transfer(window0({ [1] = S(id.Planks, 64) }), recipe, true, "all")
		t.eq(Menu.get(all, 1).count, 16, "16 in each")
		t.eq(all.inventory.slots[1], nil, "every plank in the grid")
		-- Up to a stack: 300 planks give 64 sets.
		local many = window0({
			[1] = S(id.Planks, 64),
			[2] = S(id.Planks, 64),
			[3] = S(id.Planks, 64),
			[4] = S(id.Planks, 64),
			[5] = S(id.Planks, 44),
		})
		t.eq(JeiTransfer.sets(many, recipe), 64, "sets capped at a stack")
		transfer(many, recipe, true, "64 sets")
	end)

	t.test("transfer: tags take any of their items; the grid's items count", function()
		local recipe = recipeFor(id.CraftingTable)
		local window = transfer(
			window0({ [1] = S(id.Planks, 2), [7] = S(id.BirchPlanks, 2) }),
			recipe,
			false,
			"two kinds of planks"
		)
		t.eq(window.inventory.slots[1], nil, "oak used up")
		t.eq(window.inventory.slots[7], nil, "birch used up")
		-- Planks already in the grid (somewhere else) are used too.
		transfer(
			window0({ [4] = S(id.SprucePlanks, 1) }, { [1] = S(id.SprucePlanks, 3) }),
			recipe,
			false,
			"from the grid"
		)
	end)

	t.test("transfer: recipes go where the view draws them", function()
		-- A torch (1 x 2) in the 2 x 2: the right column; planks (one log) bottom right.
		local torch =
			transfer(window0({ [1] = S(id.Coal, 5), [2] = S(id.Stick, 5) }), recipeFor(id.Torch), false, "torch")
		t.eq(Menu.get(torch, 2).item, id.Coal, "coal top right")
		t.eq(Menu.get(torch, 4).item, id.Stick, "stick bottom right")
		t.eq(Menu.get(torch, 0).count, 4, "four torches")
		local planks = transfer(window0({ [9] = S(id.OakLog, 3) }), recipeFor(id.Planks), false, "planks")
		t.eq(Menu.get(planks, 4).item, id.OakLog, "the log bottom right")
		-- A pickaxe on a crafting table, cell for cell.
		local pickaxe = transfer(
			tableWindow({ [1] = S(id.Cobblestone, 3), [20] = S(id.Stick, 2) }),
			recipeFor(id.StonePickaxe),
			false,
			"stone pickaxe"
		)
		for _, slot in { 1, 2, 3 } do
			t.eq(Menu.get(pickaxe, slot).item, id.Cobblestone, `cobblestone in {slot}`)
		end
		t.eq(Menu.get(pickaxe, 5).item, id.Stick, "stick in the middle")
		t.eq(Menu.get(pickaxe, 8).item, id.Stick, "stick at the bottom")
	end)

	t.test("transfer: too large, missing items, no grid", function()
		local pickaxe = recipeFor(id.StonePickaxe)
		local small = window0({ [1] = S(id.Cobblestone, 3), [2] = S(id.Stick, 2) })
		local status = JeiTransfer.check(small, pickaxe)
		t.ok(not status.ok, "3 x 3 in the 2 x 2")
		t.eq(status.reason, JeiTransfer.TOO_LARGE, "reason")
		local actions, reason = JeiTransfer.plan(small, pickaxe)
		t.eq(actions, nil, "no plan")
		t.eq(reason, JeiTransfer.TOO_LARGE, "plan reason")
		-- Every recipe that fits a 2 x 2 is accepted there, the others are not.
		for _, recipe in Crafting.recipes do
			local fits = recipe.width <= 2 and recipe.height <= 2
			if recipe.kind == "shapeless" then
				fits = #recipe.cells <= 4
			end
			t.eq(JeiTransfer.targets(recipe, 2) ~= nil, fits, `{Items.displayName(recipe.result)} fits 2 x 2`)
			t.ok(JeiTransfer.targets(recipe, 3) ~= nil, `{Items.displayName(recipe.result)} fits 3 x 3`)
		end

		local short = tableWindow({ [1] = S(id.Cobblestone, 2), [2] = S(id.Stick, 1) })
		local missing = JeiTransfer.check(short, pickaxe)
		t.ok(not missing.ok, "missing")
		t.eq(missing.reason, JeiTransfer.MISSING, "missing reason")
		-- Allocation goes cell by cell: the third cobblestone and the second stick are missing.
		t.ok(missing.missing[3] and missing.missing[8], "cells 3 and 8 red")
		t.ok(not missing.missing[1] and not missing.missing[2] and not missing.missing[5], "others fine")
		t.eq(JeiTransfer.plan(short, pickaxe), nil, "no plan when missing")
		t.eq(JeiTransfer.sets(short, pickaxe), 0, "no sets")

		local chest = window0({ [1] = S(id.Cobblestone, 3) })
		chest.id = 2
		chest.container = { kind = "chest", block = Blocks.id.Chest, size = 27, slots = {} }
		t.eq(JeiTransfer.gridWidth(chest), 0, "a chest has no grid")
		t.eq(JeiTransfer.check(chest, pickaxe).reason, JeiTransfer.NO_GRID, "no grid")
	end)

	t.test("transfer: the button is lit only when the move can be made", function()
		local stick = recipeFor(id.Stick)
		local fine = window0({ [1] = S(id.Planks, 4) })
		local status = JeiTransfer.status(fine, stick)
		t.ok(status.ok and status.reason == nil, "planks: lit")
		-- Everything there, but the grid's dirt has nowhere to go: check passes, the plan cannot.
		local stacks = {}
		for slot = 1, 36 do
			stacks[slot] = S(if slot == 1 then id.Planks else id.Cobblestone, if slot == 1 then 2 else 64)
		end
		local full = window0(stacks, { [3] = S(id.Dirt, 1) })
		t.ok(JeiTransfer.check(full, stick).ok, "check alone passes")
		local blocked = JeiTransfer.status(full, stick)
		t.ok(not blocked.ok, "full inventory: greyed out")
		t.eq(blocked.reason, JeiTransfer.NO_ROOM, "says why")
		-- The same with a carried stack that fits nowhere.
		local carrying = window0(stacks, nil, S(id.Dirt, 1))
		t.eq(JeiTransfer.status(carrying, stick).reason, JeiTransfer.NO_ROOM, "carried dirt: no room")
		-- Missing and too large keep check's answer (and its red cells).
		local short = JeiTransfer.status(window0({ [1] = S(id.Planks, 1) }), stick)
		t.eq(short.reason, JeiTransfer.MISSING, "missing")
		t.ok(short.missing[5] == true, "the second plank cell red")
		t.eq(
			JeiTransfer.status(window0({ [1] = S(id.Cobblestone, 3) }), recipeFor(id.StonePickaxe)).reason,
			JeiTransfer.TOO_LARGE,
			"too large"
		)
		-- The status asks a copy: the window is untouched.
		t.eq(fine.inventory.slots[1].count, 4, "nothing moved by asking")
		t.eq(Menu.get(fine, 2), nil, "grid untouched")
	end)

	t.test("transfer: a recipe's cells take the same items or none in common", function()
		-- The allocation gives each cell the kind with the most left, cell by cell: that finds a
		-- way whenever there is one only while no two cells accept overlapping, different sets.
		for _, recipe in Crafting.recipes do
			local grid = JeiData.craftingGrid(recipe)
			for a = 1, 9 do
				for b = a + 1, 9 do
					local x, y = grid[a], grid[b]
					if x and y then
						local shared = 0
						for _, item in x do
							if table.find(y, item) then
								shared += 1
							end
						end
						t.ok(
							shared == 0 or (shared == #x and shared == #y),
							`{Items.displayName(recipe.result)}: cells {a} and {b}`
						)
					end
				end
			end
		end
	end)

	t.test("transfer: the carried stack and the grid's contents go back first", function()
		local recipe = recipeFor(id.Stick)
		local window = transfer(
			window0(
				{ [1] = S(id.Planks, 10), [2] = S(id.Dirt, 60) },
				{ [1] = S(id.Dirt, 3), [3] = S(id.Stone, 1) },
				S(id.Dirt, 5)
			),
			recipe,
			false,
			"junk around"
		)
		t.eq(Menu.get(window, 2).item, id.Planks, "planks top right")
		t.eq(Menu.get(window, 4).item, id.Planks, "planks bottom right")
		-- A full inventory that cannot take the grid's junk: no plan.
		local stacks = {}
		for slot = 1, 36 do
			stacks[slot] = S(if slot == 1 then id.Planks else id.Cobblestone, if slot == 1 then 2 else 64)
		end
		local full = window0(stacks, { [3] = S(id.Dirt, 1) })
		local actions, reason = JeiTransfer.plan(full, recipe)
		t.eq(actions, nil, "no room for the dirt")
		t.eq(reason, JeiTransfer.NO_ROOM, "reason")
		-- Snowballs stack to 16: at most 16 sets of snow.
		local snow = recipeFor(id.Snow)
		local balls = window0({
			[1] = S(id.Snowball, 16),
			[2] = S(id.Snowball, 16),
			[3] = S(id.Snowball, 16),
			[4] = S(id.Snowball, 16),
			[5] = S(id.Snowball, 16),
		})
		t.eq(JeiTransfer.sets(balls, snow), 16, "snowball sets")
		transfer(balls, snow, true, "snow")
	end)

	t.test("transfer: random inventories never lose items and always fill the grid", function()
		local seed = 12345
		local function random(n: number): number
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed % n + 1
		end
		-- Ingredients of every recipe, plus some junk.
		local pool: { number } = { id.Dirt, id.Stone, id.Glass, id.IronHelmet }
		for _, recipe in Crafting.recipes do
			for _, cell in recipe.cells do
				if cell then
					for item in cell do
						if not table.find(pool, item) then
							table.insert(pool, item)
						end
					end
				end
			end
		end
		local planned, refused = 0, 0
		-- (Most rounds are refused: many recipes need the 3 x 3 grid, or 8 of a transmitter.)
		for round = 1, 600 do
			local recipe = Crafting.recipes[random(#Crafting.recipes)]
			local stacks = {}
			for _ = 1, random(20) do
				local item = pool[random(#pool)]
				stacks[random(36)] = S(item, random(Items.maxStack(item)))
			end
			-- Mostly the recipe's own ingredients, in random amounts and places.
			for _, cell in recipe.cells do
				if cell and random(6) > 1 then
					local options = {}
					for item in cell do
						table.insert(options, item)
					end
					table.sort(options)
					local item = options[random(#options)]
					stacks[random(36)] = S(item, random(Items.maxStack(item)))
				end
			end
			local grid = {}
			if random(3) == 1 then
				local item = pool[random(#pool)]
				grid[random(4)] = S(item, random(Items.maxStack(item)))
			end
			local cursor = nil
			if random(4) == 1 then
				local item = pool[random(#pool)]
				cursor = S(item, random(Items.maxStack(item)))
			end
			local onTable = random(2) == 1
			local window = if onTable then tableWindow(stacks, grid, cursor) else window0(stacks, grid, cursor)
			local all = random(2) == 1
			local status = JeiTransfer.check(window, recipe)
			local lit = JeiTransfer.status(window, recipe).ok
			if lit then
				t.ok(
					JeiTransfer.plan(window, recipe, not all) ~= nil,
					`round {round}: a lit button moves one set and every set`
				)
			end
			local actions, reason = JeiTransfer.plan(Menu.copyWindow(window), recipe, all)
			if actions then
				planned += 1
				t.ok(status.ok, `round {round}: planned only when the check passes`)
				t.ok(lit, `round {round}: planned only when the button is lit`)
				transfer(window, recipe, all, `round {round}`)
			else
				refused += 1
				t.ok(reason ~= JeiTransfer.FAILED, `round {round}: a plan never fails its own check`)
				if status.ok then
					t.eq(reason, JeiTransfer.NO_ROOM, `round {round}: only room stops a checked recipe`)
				end
			end
		end
		t.ok(planned > 100, `enough transfers tried ({planned} planned, {refused} refused)`)
	end)

	t.test("jei: boiling on the Campfire (Tough As Nails), its catalyst", function()
		local Drinks = require(shared.ToughAsNails.Drinks)
		local twins = 0
		for _ in Drinks.PURIFIED_OF do
			twins += 1
		end
		local count = 0
		for _, entry in JeiData.entries() do
			if entry.category == "boiling" then
				count += 1
				t.eq(#entry.inputs[1], 1, "one dirty water")
				t.eq(entry.output and entry.output.item, Drinks.purifiedOf(entry.inputs[1][1]), "into its twin")
			end
		end
		t.eq(count, twins, "one per Drinks.PURIFIED_OF pair")
		same(
			categories(JeiData.recipes(id.PurifiedWaterBottle)) :: any,
			{ "crafting", "smelting", "boiling" } :: any,
			"purified water: the mint cure, smelting and boiling"
		)
		local dirty = JeiData.uses(id.DirtyWaterCanteen)
		t.ok(find(dirty, "boiling", makes(id.PurifiedWaterCanteen)), "a dirty canteen boils")
		local campfire = JeiData.uses(id.Campfire)
		same(categories(campfire) :: any, { "boiling" } :: any, "the campfire's uses: every boiling")
		t.eq(#campfire[1].entries, twins)
		same(
			categories(JeiData.recipes(id.Campfire)) :: any,
			{ "crafting" } :: any,
			"the campfire is crafted (Minecraft's recipe)"
		)
		t.eq(JeiData.TITLES.boiling, "Campfire")
		t.eq(JeiLayout.entry("boiling"), JeiLayout.entry("smelting"), "drawn as smelting")
	end)

	--[[ The machines' categories: the Metal Miner and the Ammo Press ]]

	local function entriesOf(category: string, from: { any }?): { any }
		local list = {}
		for _, entry in from or JeiData.entries() do
			if entry.category == category then
				table.insert(list, entry)
			end
		end
		return list
	end

	local function groupOf(groups, category: string)
		for _, group in groups do
			if group.category == category then
				return group
			end
		end
		return nil
	end

	t.test("jei: Duplicating: the Metal Miner copies each ore into its drop, with its time and energy", function()
		local Machines = require(shared.Machines)
		local MinerRules = require(shared.Machines.MinerRules)
		local info = Machines.info(Blocks.id.MetalMiner)
		local entries = entriesOf("duplicating")
		t.eq(#entries, #MinerRules.ORES, "one per ore")
		-- (By ore name, not by place in ORES: content may add ores anywhere.)
		local drops = {
			CoalOre = "Coal",
			IronOre = "RawIron",
			OsmiumOre = "RawOsmium",
			GoldOre = "RawGold",
			EmeraldOre = "Emerald",
			DiamondOre = "Diamond",
			CopperOre = "RawCopper",
			LeadOre = "RawLead",
			ZincOre = "RawZinc",
			SulfurOre = "Sulfur",
			SaltpetreOre = "Saltpetre",
			UraniumOre = "RawUranium",
		}
		local function entryOf(name: string): any
			return entries[(MinerRules.ore(id[name]) :: MinerRules.Ore).index]
		end
		for name in drops do
			t.ok(MinerRules.ore(id[name]) ~= nil, `{name} is the miner's`)
		end
		local Content = require(shared.Content)
		for index, ore in MinerRules.ORES do
			local drop = drops[ore.name] or Items.get(ore.drop).name
			local entry = entries[index]
			-- (The ore's own entry's `miner`.)
			local numbers = (Content.default.block(ore.name) :: any).miner
			t.eq(#entry.inputs[1], 1, `{ore.name}: one input`)
			t.eq(entry.inputs[1][1], id[ore.name], `{ore.name}: the ore block, in MinerRules' order`)
			t.eq(entry.inputs[2], nil)
			t.eq(entry.output and entry.output.item, id[drop], `{ore.name} gives its drop`)
			t.eq(entry.output and entry.output.count, 1, "one at a time")
			t.eq(entry.ticks, numbers.ticks, `{ore.name}: its entry's ticks`)
			t.eq(entry.ticks, info[`{ore.name}Ticks`], "as its info says")
			t.eq(entry.power, numbers.joules, `{ore.name}: J a tick`)
			t.eq(entry.energy, math.max(numbers.ticks * numbers.joules, numbers.floor or 0), `{ore.name}: J an item`)
			t.eq(entry.recipe, nil)
			t.eq(JeiData.lockText(entry, nil), nil, "no lock: the miner's Age opens it")
			t.ok(
				find(JeiData.recipes(ore.drop), "duplicating", function(e)
					return e == entry
				end),
				`{drop}'s recipes`
			)
			t.ok(
				find(JeiData.uses(ore.block), "duplicating", function(e)
					return e == entry
				end),
				`{ore.name}'s uses`
			)
		end
		-- The texts: the time and J an item, J a tick.
		same(JeiData.machineTexts(entryOf("DiamondOre")) :: any, { "240 s, 3.84 MJ", "800 J/t" } :: any, "a diamond")
		same(JeiData.machineTexts(entryOf("CoalOre")) :: any, { "30 s, 480 kJ", "800 J/t" } :: any, "a coal")
		same(JeiData.machineTexts(entryOf("IronOre")) :: any, { "20 s, 80 kJ", "200 J/t" } :: any, "a raw iron")
		t.ok(entryOf("CoalOre").energy >= 400000, "coal never under its 400 kJ floor")
		-- Its catalyst, title, tab and layout.
		same(JeiData.CATALYSTS.duplicating :: any, { "MetalMiner" } :: any, "the miner is its catalyst")
		t.eq(JeiData.TITLES.duplicating, "Duplicating")
		t.eq(JeiData.TAB_ITEMS.duplicating, "MetalMiner")
		local miner = JeiData.uses(id.MetalMiner)
		same(categories(miner) :: any, { "duplicating" } :: any, "the miner's uses: every ore")
		t.eq(#miner[1].entries, #MinerRules.ORES)
		same(categories(JeiData.recipes(id.Diamond)) :: any, { "crafting", "smelting", "duplicating" } :: any)
		same(categories(JeiData.uses(id.DiamondOre)) :: any, { "smelting", "duplicating" } :: any)
		local layout = JeiLayout.entry("duplicating")
		t.eq(#layout.inputs, 1, "the ore")
		t.ok(layout.output ~= nil and layout.arrow ~= nil and #layout.texts == 2, "its drop, the arrow, two lines")
		t.eq(JeiLayout.perPage("duplicating"), 3, "three a page")
		t.eq(JeiData.pageCount(#entries, JeiLayout.perPage("duplicating")), 4, "twelve ores on four pages")
	end)

	t.test("jei: Pressing: the Ammo Press makes each calibre's rounds of a brass, a lead and a gunpowder", function()
		local Machines = require(shared.Machines)
		local info = Machines.info(Blocks.id.AmmoPress)
		local entries = entriesOf("pressing")
		local rounds = { { id.Rounds9mm, 16 }, { id.Rounds556, 10 }, { id.Rounds308, 5 } }
		t.eq(#entries, #rounds, "one per calibre")
		for index, round in rounds do
			local entry = entries[index]
			-- (Three inputs since lead and brass: the press's panel order.)
			same(entry.inputs[1], { id.BrassIngot }, "a Brass Ingot")
			same(entry.inputs[2], { id.LeadIngot }, "a Lead Ingot")
			same(entry.inputs[3], { id.Gunpowder }, "and a Gunpowder")
			t.eq(entry.inputs[4], nil)
			t.eq(entry.output and entry.output.item, round[1], `calibre {index}, in item order`)
			t.eq(entry.output and entry.output.count, round[2], `{round[2]} rounds`)
			t.eq(entry.output and entry.output.count, info[Items.get(round[1]).name], "its info's count")
			t.eq(entry.ticks, info.ticks)
			t.eq(entry.ticks, 200)
			t.eq(entry.energy, 10000, "10 kJ an operation")
			t.eq(entry.power, 50)
			t.eq(JeiData.lockText(entry, nil), nil)
			same(JeiData.machineTexts(entry) :: any, { "10 s, 10 kJ", "50 J/t" } :: any, "its texts")
			same(categories(JeiData.recipes(round[1])) :: any, { "pressing" } :: any, "rounds: only pressed")
		end
		-- Every calibre is among the uses of the three inputs and of the press (its catalyst); iron
		-- presses nothing now.
		for _, item in { id.BrassIngot, id.LeadIngot, id.Gunpowder, id.AmmoPress } do
			local group = groupOf(JeiData.uses(item), "pressing")
			t.eq(group and #group.entries, #rounds, `{Items.displayName(item)}: every pressing`)
		end
		t.eq(groupOf(JeiData.uses(id.IronIngot), "pressing"), nil, "no pressing of iron")
		same(categories(JeiData.uses(id.AmmoPress)) :: any, { "pressing" } :: any)
		same(categories(JeiData.uses(id.LeadIngot)) :: any, { "crafting", "pressing" } :: any, "lead: crafted, pressed")
		same(categories(JeiData.recipes(id.IronIngot)) :: any, { "crafting", "smelting" } :: any, "made as before")
		same(JeiData.CATALYSTS.pressing :: any, { "AmmoPress" } :: any)
		t.eq(JeiData.TITLES.pressing, "Pressing")
		t.eq(JeiData.TAB_ITEMS.pressing, "AmmoPress")
		-- The layout: the brass over the lead, the gunpowder beside them in the arrow's row, then the
		-- arrow, the rounds and the texts (wide enough for its longest, the time and the energy).
		local layout = JeiLayout.entry("pressing")
		t.eq(#layout.inputs, 3, "a cell for each input")
		local brass, lead, powder = layout.inputs[1], layout.inputs[2], layout.inputs[3]
		t.ok(brass.x == lead.x and brass.y + 18 == lead.y, "the brass over the lead")
		t.ok(powder.x == brass.x + 18 and powder.y == layout.output.y, "the gunpowder beside them, in the output's row")
		t.ok(powder.y > brass.y and powder.y < lead.y, "between the two")
		t.ok(layout.arrow ~= nil and layout.arrow.x >= powder.x + 17, "the arrow after the inputs")
		t.ok(layout.output ~= nil and layout.output.x > layout.arrow.x + layout.arrow.w, "then the rounds")
		t.eq(#layout.texts, 2)
		for _, r in layout.texts do
			t.ok(r.x > layout.output.x + 17 and r.w >= 54, "the texts after them")
		end
		t.eq(JeiLayout.perPage("pressing"), 3, "three a page, as before")
		t.eq(JeiData.pageCount(#entries, JeiLayout.perPage("pressing")), 1, "the three calibres on one page")
	end)

	t.test("jei: every category's tab item exists, and every lookup's tabs fit over the view", function()
		-- (RecipeView: a tab per category present, ItemIcon.TAB_WIDTH 28 and a pixel apart.)
		local TAB_SPAN = 29
		local fit = math.floor((JeiLayout.VIEW_WIDTH + 1) / TAB_SPAN)
		t.eq(#JeiData.CATEGORIES, 9)
		for _, category in JeiData.CATEGORIES do
			t.ok(rawget(id :: any, JeiData.TAB_ITEMS[category]) ~= nil, `{category}'s tab item`)
			t.ok(type(JeiData.TITLES[category]) == "string", `{category}'s title`)
			for _, name in JeiData.CATALYSTS[category] do
				t.ok(rawget(id :: any, name) ~= nil, `{category}'s catalyst {name}`)
			end
		end
		local most = 0
		for _, def in Items.list do
			most = math.max(most, #JeiData.recipes(def.id), #JeiData.uses(def.id))
		end
		t.ok(most <= fit, `at most {fit} tabs fit: the most an item has is {most}`)
	end)

	t.test("jei: the machines' categories follow their Config switches", function()
		-- Fresh modules with a switch off (JeiData builds its index once).
		local function fresh(miner: boolean, press: boolean)
			local env = Loader.new()
			local root = env.mount("src/shared", "ReplicatedStorage", "IceVoxel")
			local clientRoot = env.mount("src/client", "StarterPlayerScripts", "IceVoxel")
			local OffConfig = env.require(root.Config)
			OffConfig.Miner.Enabled = miner
			OffConfig.AmmoPress.Enabled = press
			return env.require(clientRoot.Ui.Jei.JeiData), env.require(root.Items)
		end
		local NoMiner, NoMinerItems = fresh(false, true)
		t.eq(#entriesOf("duplicating", NoMiner.entries()), 0, "the miner off: no Duplicating")
		t.eq(#entriesOf("pressing", NoMiner.entries()), 3, "the press still presses")
		t.eq(groupOf(NoMiner.uses(NoMinerItems.id.MetalMiner), "duplicating"), nil, "no tab on the miner")
		t.eq(groupOf(NoMiner.recipes(NoMinerItems.id.Diamond), "duplicating"), nil)
		local NoPress, NoPressItems = fresh(true, false)
		t.eq(#entriesOf("pressing", NoPress.entries()), 0, "the press off: no Pressing")
		t.eq(#entriesOf("duplicating", NoPress.entries()), 12, "the miner still copies")
		t.eq(#NoPress.recipes(NoPressItems.id.Rounds9mm), 0, "rounds come from loot alone again")
		t.eq(groupOf(NoPress.uses(NoPressItems.id.Gunpowder), "pressing"), nil)
		t.eq(groupOf(NoPress.uses(NoPressItems.id.AmmoPress), "pressing"), nil)
	end)
end

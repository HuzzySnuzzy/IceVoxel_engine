--[[
	The crafting UI's pure parts: the panel layouts and gauges of Ui/MenuLayout (the 2 x 2 grid in
	the player panel, the crafting table, furnace and chest panels, the furnace's flame and arrow,
	the durability bar) and the screens' click logic around results and worn tools (Ui/SlotClicks).
]]

return function(t, shared, require, _server, client)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Types = require(shared.Inventory.Types)
	local Menu = require(shared.Inventory.Menu)
	local Smelting = require(shared.Crafting.Smelting)
	local MenuLayout = require(client.Ui.MenuLayout)
	local SlotClicks = require(client.Ui.SlotClicks)

	local id = Items.id
	local Click = Menu.ClickType
	local LEFT = 0

	local function S(item: number, count: number, damage: number?)
		return { item = item, count = count, damage = damage }
	end

	local function is(stack, item: number?, count: number?, what: string)
		if item == nil then
			t.ok(stack == nil, `{what}: expected empty, got {stack and `{stack.item} x{stack.count}` or "nil"}`)
		else
			t.ok(stack ~= nil, `{what}: expected {item} x{count}, got empty`)
			t.eq(stack.item, item, `{what} item`)
			t.eq(stack.count, count, `{what} count`)
		end
	end

	local function chest()
		return { kind = "chest", block = Blocks.id.Chest, size = 27, slots = {} }
	end
	local function furnace()
		return { kind = "furnace", block = Blocks.id.Furnace, size = 3, slots = {}, data = Smelting.newData() }
	end
	local function table3()
		return Types.newCrafting("crafting", Blocks.id.CraftingTable)
	end

	--[[ Layouts ]]

	type Box = { x: number, y: number, w: number, h: number, what: string }

	-- Every drawn thing of a layout as a rectangle: slot frames (18 or 26 px), arrows, gauges.
	local function boxes(slots, extra): { Box }
		local out: { Box } = {}
		for _, spot in slots do
			local inset = if spot.big then MenuLayout.BIG_INSET else 1
			local size = if spot.big then MenuLayout.BIG_FRAME else 18
			table.insert(out, { x = spot.x - inset, y = spot.y - inset, w = size, h = size, what = `slot {spot.slot}` })
		end
		for what, rect in extra do
			table.insert(out, { x = rect.x, y = rect.y, w = rect.w, h = rect.h, what = what })
		end
		return out
	end

	local function overlaps(a: Box, b: Box): boolean
		return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
	end

	-- Nothing overlaps, everything is inside the panel's bevel (3 px) and below its title row.
	local function checkLayout(list: { Box }, width: number, height: number, top: number, what: string)
		for i, a in list do
			t.ok(a.x >= 3 and a.x + a.w <= width - 3, `{what}: {a.what} inside horizontally`)
			t.ok(a.y >= top and a.y + a.h <= height - 3, `{what}: {a.what} inside vertically`)
			for j = i + 1, #list do
				t.ok(not overlaps(a, list[j]), `{what}: {a.what} overlaps {list[j].what}`)
			end
		end
	end

	-- Each container slot 1..size exactly once.
	local function checkSlots(slots, size: number, what: string)
		local seen = {}
		for _, spot in slots do
			t.ok(spot.slot >= 1 and spot.slot <= size, `{what}: slot {spot.slot} in range`)
			t.ok(not seen[spot.slot], `{what}: slot {spot.slot} once`)
			seen[spot.slot] = true
		end
		t.eq(#slots, size, `{what}: every slot`)
	end

	t.test("layout: the 2 x 2 grid sits where Minecraft's inventory screen has it", function()
		local grid = MenuLayout.inventoryGrid
		checkSlots(grid.slots, 5, "2 x 2")
		t.eq(grid.label.text, "Crafting", "label")
		t.eq(grid.label.x, 97, "label x")
		t.eq(grid.label.y, 8, "label y")
		local at = {}
		for _, spot in grid.slots do
			at[spot.slot] = spot
		end
		-- InventoryMenu: the result at (154, 28), the grid at (98 + 18 column, 18 + 18 row).
		t.eq(at[1].x, 154, "result x")
		t.eq(at[1].y, 28, "result y")
		for i = 1, 4 do
			local row, column = (i - 1) // 2, (i - 1) % 2
			t.eq(at[1 + i].x, 98 + column * 18, `grid {i} x`)
			t.eq(at[1 + i].y, 18 + row * 18, `grid {i} y`)
		end
		local list = boxes(grid.slots, { arrow = grid.arrow })
		checkLayout(list, MenuLayout.WIDTH, MenuLayout.PLAYER_HEIGHT, 16, "2 x 2")
		-- Clear of the player preview (26..75 x 8..77, with its border) and the inventory rows.
		for _, box in list do
			t.ok(box.x >= 77, `{box.what} right of the preview`)
			t.ok(box.y + box.h <= 83, `{box.what} above the inventory`)
		end
		-- Window 0 numbers them like InventoryMenu: 0 the result, 1..4 the grid.
		local window = Types.newWindow(Types.newInventory())
		for _, spot in grid.slots do
			t.eq(Menu.windowIndex(window, "container", spot.slot), spot.slot - 1, `window slot of {spot.slot}`)
		end
		t.ok(Menu.isCraftResult(window, 0), "window slot 0 is the result")
	end)

	t.test("layout: the crafting table panel is CraftingScreen's top half", function()
		local panel = MenuLayout.panel(table3())
		t.eq(panel.title, "Crafting", "title")
		t.eq(panel.titleX, 29, "title x")
		checkSlots(panel.slots, 10, "crafting")
		local at = {}
		for _, spot in panel.slots do
			at[spot.slot] = spot
		end
		t.eq(at[1].x, 124, "result x")
		t.eq(at[1].y, 35, "result y")
		t.ok(at[1].big, "large result frame")
		for i = 1, 9 do
			local row, column = (i - 1) // 3, (i - 1) % 3
			t.eq(at[1 + i].x, 30 + column * 18, `grid {i} x`)
			t.eq(at[1 + i].y, 17 + row * 18, `grid {i} y`)
			t.ok(not at[1 + i].big, `grid {i} normal frame`)
		end
		-- Gamepad selection starts at the grid's top left.
		t.eq(panel.slots[1].slot, 2, "grid first")
		t.ok(panel.arrow ~= nil, "an arrow")
		checkLayout(boxes(panel.slots, { arrow = panel.arrow }), panel.width, panel.height, 15, "crafting")
		t.ok(panel.height >= 76 and panel.height <= 84, "about 80 pixels tall")
	end)

	t.test("layout: the furnace panel is AbstractFurnaceScreen's", function()
		local panel = MenuLayout.panel(furnace())
		t.eq(panel.title, "Furnace", "title")
		t.ok(panel.centred, "centred title")
		checkSlots(panel.slots, 3, "furnace")
		local at = {}
		for _, spot in panel.slots do
			at[spot.slot] = spot
		end
		t.eq(at[Types.FURNACE_INPUT].x, 56, "input x")
		t.eq(at[Types.FURNACE_INPUT].y, 17, "input y")
		t.eq(at[Types.FURNACE_FUEL].x, 56, "fuel x")
		t.eq(at[Types.FURNACE_FUEL].y, 53, "fuel y")
		t.eq(at[Types.FURNACE_OUTPUT].x, 116, "output x")
		t.eq(at[Types.FURNACE_OUTPUT].y, 35, "output y")
		t.ok(at[Types.FURNACE_OUTPUT].big, "large output frame")
		local flame, progress = panel.flame, panel.progress
		assert(flame and progress, "gauges")
		t.eq(flame.x, 56, "flame x")
		t.eq(flame.y, 36, "flame y")
		t.eq(flame.w, 14, "flame w")
		t.eq(progress.x, 79, "arrow x")
		t.eq(progress.y, 34, "arrow y")
		t.eq(progress.w, 24, "arrow w")
		t.eq(progress.h, 16, "arrow h")
		t.eq(panel.slots[1].slot, Types.FURNACE_INPUT, "input first")
		checkLayout(
			boxes(panel.slots, { flame = flame, progress = progress }),
			panel.width,
			panel.height,
			15,
			"furnace"
		)
	end)

	t.test("layout: chests keep rows of 9 under their name; odd containers fall back to rows", function()
		local panel = MenuLayout.panel(chest())
		t.eq(panel.title, "Chest", "title")
		t.eq(panel.height, 24 + 3 * 18, "three rows")
		checkSlots(panel.slots, 27, "chest")
		t.eq(panel.slots[10].x, 8, "row 2 starts at the left")
		t.eq(panel.slots[10].y, 36, "row 2")
		checkLayout(boxes(panel.slots, {}), panel.width, panel.height, 15, "chest")
		-- A furnace or crafting container of the wrong size still shows all its slots.
		local odd = { kind = "furnace", block = Blocks.id.Furnace, size = 5, slots = {} }
		checkSlots(MenuLayout.panel(odd).slots, 5, "odd furnace")
		local large = { kind = "chest", block = Blocks.id.Chest, size = 54, slots = {} }
		local big = MenuLayout.panel(large)
		checkSlots(big.slots, 54, "large chest")
		t.eq(big.height, 24 + 6 * 18, "six rows")
	end)

	t.test("layout: only blocks' containers get a panel; window 0's grid lives in the player panel", function()
		local inventory = Types.newCrafting("inventory")
		t.ok(not MenuLayout.hasPanel(nil), "nothing")
		t.ok(not MenuLayout.hasPanel(inventory), "window 0's grid")
		t.ok(MenuLayout.hasPanel(chest()), "chest")
		t.ok(MenuLayout.hasPanel(table3()), "crafting table")
		t.ok(MenuLayout.hasPanel(furnace()), "furnace")
		t.ok(MenuLayout.showsGrid(inventory), "2 x 2 shown with window 0")
		t.ok(not MenuLayout.showsGrid(nil), "not without a container")
		t.ok(not MenuLayout.showsGrid(table3()), "not with a crafting table")
		t.ok(not MenuLayout.showsGrid(chest()), "not with a chest")
		t.eq(MenuLayout.panelKey(inventory), "", "no panel key")
		t.eq(MenuLayout.panelKey(nil), "", "no panel key without a container")
		t.eq(MenuLayout.panelKey(chest()), `chest:{Blocks.id.Chest}:27`, "chest key")
		t.ok(MenuLayout.panelKey(table3()) ~= MenuLayout.panelKey(furnace()), "kinds differ")
	end)

	t.test("layout: arrows point right and the flame is 14 x 14", function()
		for _, size in { { 16, 13 }, { 22, 15 }, { 24, 16 } } do
			local w, h = size[1], size[2]
			local art = MenuLayout.arrowArt(w, h)
			t.eq(#art, h, `{w} x {h}: rows`)
			for row, line in art do
				t.eq(#line, w, `{w} x {h}: row {row} width`)
				-- Symmetric about the middle row.
				t.eq(line, art[h + 1 - row], `{w} x {h}: row {row} mirrors`)
			end
			-- The tip: the last column only in the middle row(s); the head's back is full height.
			local middle = art[(h + 1) // 2]
			t.eq(string.sub(middle, w, w), "#", `{w} x {h}: tip`)
			t.eq(string.sub(art[1], w, w), ".", `{w} x {h}: no tip at the top`)
			t.eq(string.sub(art[1], w - math.ceil(h / 2) + 1, w - math.ceil(h / 2) + 1), "#", `{w} x {h}: head`)
			-- The shaft starts at the left edge, in the middle only.
			t.eq(string.sub(middle, 1, 1), "#", `{w} x {h}: shaft`)
			t.eq(string.sub(art[1], 1, 1), ".", `{w} x {h}: shaft is thin`)
		end
		t.eq(#MenuLayout.FLAME_ART, 14, "flame rows")
		for row, line in MenuLayout.FLAME_ART do
			t.eq(#line, 14, `flame row {row}`)
		end
	end)

	--[[ Gauges ]]

	t.test("gauges: the flame shows litTime / litDuration, out at 0 (getLitProgress)", function()
		t.eq(MenuLayout.flameRows(nil), 0, "no data")
		t.eq(MenuLayout.flameRows(Smelting.newData()), 0, "out")
		-- 1 + litTime * 13 / litDuration rows.
		t.eq(MenuLayout.flameRows({ 1600, 1600, 0, 200 }), 14, "just lit: all of it")
		t.eq(MenuLayout.flameRows({ 800, 1600, 0, 200 }), 7, "half burnt")
		t.eq(MenuLayout.flameRows({ 1, 1600, 0, 200 }), 1, "nearly out")
		-- An unknown duration counts as 200 ticks.
		t.eq(MenuLayout.flameRows({ 100, 0, 0, 200 }), 7, "duration 0")
		t.eq(MenuLayout.flameRows({ 5000, 100, 0, 200 }), 14, "clamped")
	end)

	t.test("gauges: the arrow fills with cookingProgress / cookingTotalTime (getBurnProgress)", function()
		t.eq(MenuLayout.arrowColumns(nil), 0, "no data")
		t.eq(MenuLayout.arrowColumns({ 0, 0, 0, 200 }), 0, "not cooking")
		t.eq(MenuLayout.arrowColumns({ 10, 100, 100, 200 }), 12, "half way")
		t.eq(MenuLayout.arrowColumns({ 10, 100, 199, 200 }), 23, "nearly done")
		t.eq(MenuLayout.arrowColumns({ 10, 100, 50, 0 }), 0, "no total")
		t.eq(MenuLayout.arrowColumns({ 10, 100, 500, 200 }), 24, "clamped")
	end)

	t.test("gauges: the durability bar is Minecraft's getBarWidth / getBarColor", function()
		local pickaxe, diamond = id.WoodenPickaxe, id.DiamondPickaxe
		t.eq(Items.get(pickaxe).durability, 59, "wooden durability")
		-- New tools, other items and junk have no bar.
		t.eq((MenuLayout.durabilityBar(pickaxe, nil)), nil, "new (nil)")
		t.eq((MenuLayout.durabilityBar(pickaxe, 0)), nil, "new (0)")
		t.eq((MenuLayout.durabilityBar(id.Dirt, 5)), nil, "not a tool")
		t.eq((MenuLayout.durabilityBar(nil, 5)), nil, "no item")
		t.eq((MenuLayout.durabilityBar(pickaxe, 0 / 0)), nil, "NaN")
		-- round(13 - damage * 13 / max), hue (max - damage) / max / 3.
		local width, hue = MenuLayout.durabilityBar(pickaxe, 1)
		t.eq(width, 13, "one use: full width")
		t.near(hue, 58 / 59 / 3, 1e-9, "one use: green")
		width, hue = MenuLayout.durabilityBar(pickaxe, 30)
		t.eq(width, 6, "half used")
		t.near(hue, 29 / 59 / 3, 1e-9, "half used: yellow")
		width, hue = MenuLayout.durabilityBar(pickaxe, 58)
		t.eq(width, 0, "last use")
		t.near(hue, 1 / 59 / 3, 1e-9, "last use: red")
		width = MenuLayout.durabilityBar(diamond, 780)
		t.eq(width, 7, "diamond half used (6.504 rounds up)")
		width, hue = MenuLayout.durabilityBar(pickaxe, 100)
		t.eq(width, 0, "over-worn: empty")
		t.eq(hue, 0, "over-worn: red")
	end)

	--[[ Clicks around results and worn tools ]]

	-- A host that applies actions straight to `window` with Menu (what ClientInventory does).
	local function newHost(window, isCreative: boolean?)
		local log = { actions = {}, thrown = {} }
		local host = {
			window = function()
				return window
			end,
			creative = function()
				return isCreative == true
			end,
			apply = function(action)
				table.insert(log.actions, action)
				for _, stack in Menu.apply(window, action, isCreative == true) do
					table.insert(log.thrown, stack)
				end
			end,
		}
		return host, log
	end

	local function slot(index: number)
		return { kind = "slot", index = index }
	end

	local function inv(w, i: number): number
		return Menu.windowIndex(w, "inventory", i) :: number
	end

	t.test("clicks: a double click on a crafting result crafts twice (no gathering)", function()
		local w = Types.newWindow(Types.newInventory())
		Menu.set(w, 1, S(id.OakLog, 2))
		Menu.updateCraft(w)
		is(Menu.get(w, 0), id.Planks, 4, "result")
		local host, log = newHost(w)
		local clicks = SlotClicks.new(host)
		clicks:press(slot(0), LEFT, false, 0)
		clicks:release(slot(0), LEFT, false, 0.05)
		is(w.inventory.cursor, id.Planks, 4, "first craft")
		clicks:press(slot(0), LEFT, false, 0.1)
		clicks:release(slot(0), LEFT, false, 0.15)
		t.eq(#log.actions, 2, "two clicks")
		t.eq(log.actions[2].clickType, Click.Pickup, "the second is a pickup, not pickup all")
		is(w.inventory.cursor, id.Planks, 8, "second craft")
		is(Menu.get(w, 1), nil, nil, "logs used up")
		is(Menu.get(w, 0), nil, nil, "no result left")
	end)

	t.test("clicks: a shift double click never quick moves a crafting result", function()
		-- (A logging host: the result is set by hand to look like the grid's item.)
		local w = Types.newWindow(Types.newInventory())
		local container = w.container :: Types.Container
		container.slots[1] = S(id.Planks, 4)
		container.slots[2] = S(id.Planks, 5)
		container.slots[3] = S(id.Planks, 6)
		local actions = {}
		local clicks = SlotClicks.new({
			window = function()
				return w
			end,
			creative = function()
				return false
			end,
			apply = function(action)
				table.insert(actions, action)
			end,
		})
		clicks:press(slot(1), LEFT, true, 0)
		clicks:release(slot(1), LEFT, true, 0.05)
		clicks:press(slot(1), LEFT, true, 0.1)
		clicks:release(slot(1), LEFT, true, 0.15)
		local moved = {}
		for _, action in actions do
			t.eq(action.clickType, Click.QuickMove, "quick moves only")
			moved[action.slot] = true
		end
		t.ok(moved[1] and moved[2], "the grid's planks")
		t.ok(not moved[0], "never the result")
		-- A shift double click on the result itself is two shift clicks, nothing more.
		table.clear(actions)
		clicks:press(slot(0), LEFT, true, 5)
		clicks:release(slot(0), LEFT, true, 5.05)
		clicks:press(slot(0), LEFT, true, 5.1)
		clicks:release(slot(0), LEFT, true, 5.15)
		t.eq(#actions, 2, "two clicks")
		t.eq(actions[1].slot, 0, "on the result")
		t.eq(actions[2].slot, 0, "on the result again")
	end)

	t.test("clicks: shift click on a crafting table's result crafts into the inventory", function()
		local w = Types.newWindow(Types.newInventory())
		w.id = 4
		w.container = table3()
		-- A wooden pickaxe: three planks over two sticks.
		for _, s in { 2, 3, 4 } do
			w.container.slots[s] = S(id.Planks, 1)
		end
		w.container.slots[6] = S(id.Stick, 1)
		w.container.slots[9] = S(id.Stick, 1)
		Menu.updateCraft(w)
		is(Menu.get(w, 0), id.WoodenPickaxe, 1, "result")
		local clicks = SlotClicks.new((newHost(w)))
		clicks:click(slot(0), LEFT, true, 0)
		-- Minecraft's moveItemStackTo(..., true): the hotbar's last slot first.
		is(w.inventory.slots[9], id.WoodenPickaxe, 1, "crafted into hotbar 9")
		is(Menu.get(w, 0), nil, nil, "grid used up")
	end)

	t.test("clicks: drags only cover slots whose wear matches the carried tool", function()
		local w = Types.newWindow(Types.newInventory())
		w.inventory.slots[10] = S(id.WoodenPickaxe, 1, 0)
		w.inventory.cursor = S(id.WoodenPickaxe, 1, 5)
		local clicks = SlotClicks.new((newHost(w)))
		clicks:press(slot(inv(w, 10)), LEFT, false, 0)
		clicks:move(slot(inv(w, 10)))
		local _, dragged = clicks:dragging()
		t.eq(#dragged, 0, "a new pickaxe is not the same as a worn one")
		clicks:move(slot(inv(w, 11)))
		_, dragged = clicks:dragging()
		t.eq(#dragged, 1, "the empty slot joins")
		clicks:release(slot(inv(w, 11)), LEFT, false, 0.3)
		is(w.inventory.slots[11], id.WoodenPickaxe, 1, "placed in the empty slot")
		t.eq(w.inventory.slots[11].damage, 5, "wear kept")
		t.eq(w.inventory.slots[10].damage or 0, 0, "the new one untouched")
		-- Results never join a drag either.
		local cw = Types.newWindow(Types.newInventory())
		cw.inventory.cursor = S(id.Dirt, 10)
		local craftClicks = SlotClicks.new((newHost(cw)))
		craftClicks:press(slot(0), LEFT, false, 0)
		craftClicks:move(slot(0))
		craftClicks:move(slot(1))
		craftClicks:move(slot(2))
		local _, slots = craftClicks:dragging()
		t.eq(#slots, 2, "two grid slots, not the result")
		t.ok(table.find(slots, 0) == nil, "result left out")
	end)

	t.test("clicks: a shift double click gathers only tools worn alike", function()
		local w = Types.newWindow(Types.newInventory())
		w.id = 2
		w.container = chest()
		w.inventory.slots[10] = S(id.WoodenPickaxe, 1)
		w.inventory.slots[11] = S(id.WoodenPickaxe, 1)
		w.inventory.slots[12] = S(id.WoodenPickaxe, 1, 7)
		-- (Minecraft's shift double click works with something carried: with an empty cursor the
		-- second press finds the slot already empty.)
		w.inventory.cursor = S(id.Dirt, 1)
		local clicks = SlotClicks.new((newHost(w)))
		clicks:press(slot(inv(w, 10)), LEFT, true, 0)
		clicks:release(slot(inv(w, 10)), LEFT, true, 0.05)
		clicks:press(slot(inv(w, 10)), LEFT, true, 0.1)
		clicks:release(slot(inv(w, 10)), LEFT, true, 0.15)
		is(w.inventory.slots[10], nil, nil, "slot 10 moved")
		is(w.inventory.slots[11], nil, nil, "slot 11 moved (same wear)")
		is(w.inventory.slots[12], id.WoodenPickaxe, 1, "the worn one stays")
		is(w.container.slots[1], id.WoodenPickaxe, 1, "chest slot 1")
		is(w.container.slots[2], id.WoodenPickaxe, 1, "chest slot 2")
		is(w.container.slots[3], nil, nil, "nothing else")
		is(w.inventory.cursor, id.Dirt, 1, "still carried")
	end)

	t.test("clicks: furnace slots follow the furnace's rules through the screen", function()
		local w = Types.newWindow(Types.newInventory())
		w.id = 6
		w.container = furnace()
		w.inventory.slots[10] = S(id.Dirt, 5)
		w.inventory.slots[11] = S(id.Coal, 3)
		local clicks = SlotClicks.new((newHost(w)))
		-- Dirt does not burn: a drag over the fuel slot skips it.
		clicks:press(slot(inv(w, 10)), LEFT, false, 0)
		clicks:release(slot(inv(w, 10)), LEFT, false, 0.05)
		clicks:press(slot(Types.FURNACE_FUEL - 1), LEFT, false, 1)
		clicks:move(slot(Types.FURNACE_FUEL - 1))
		clicks:move(slot(Types.FURNACE_INPUT - 1))
		clicks:move(slot(Types.FURNACE_OUTPUT - 1))
		local _, dragged = clicks:dragging()
		t.eq(#dragged, 1, "only the input takes it")
		t.eq(dragged[1], Types.FURNACE_INPUT - 1, "the input")
		clicks:release(slot(Types.FURNACE_INPUT - 1), LEFT, false, 1.2)
		is(w.container.slots[Types.FURNACE_INPUT], id.Dirt, 5, "dirt in the input")
		is(w.container.slots[Types.FURNACE_FUEL], nil, nil, "no dirt as fuel")
		-- Coal shift clicks into the fuel slot.
		clicks:click(slot(inv(w, 11)), LEFT, true, 3)
		is(w.container.slots[Types.FURNACE_FUEL], id.Coal, 3, "coal as fuel")
	end)
end

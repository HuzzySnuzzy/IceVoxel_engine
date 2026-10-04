--[[
	Inventory/Menu: Minecraft 1.20.1 container clicks on the window layout (container, armor,
	inventory 10..36, hotbar), quick moves, drags, double clicks, Inventory.add, pick block,
	creative actions, invalid input and a conservation fuzz.
]]

return function(t, shared, require)
	local Items = require(shared.Items)
	local Types = require(shared.Inventory.Types)
	local Menu = require(shared.Inventory.Menu)
	local Protocol = require(shared.Net.Protocol)

	local DIRT, STONE, COBBLE, PLANKS = Items.id.Dirt, Items.id.Stone, Items.id.Cobblestone, Items.id.Planks
	local HELMET, CHESTPLATE, LEGGINGS, BOOTS =
		Items.id.IronHelmet, Items.id.IronChestplate, Items.id.IronLeggings, Items.id.IronBoots
	local GOLD_HELMET = Items.id.GoldHelmet
	local Click = Menu.ClickType
	local Drag = Menu.DragMode
	local OUTSIDE, CURSOR = Types.OUTSIDE, Types.CURSOR
	local UNKNOWN = 60000

	local function S(item: number, count: number)
		return { item = item, count = count }
	end

	-- Window 0 (inventory alone), or window 1 with a container of `size` slots.
	local function newWindow(size: number?)
		local window = { id = 0, inventory = Types.newInventory(), container = nil }
		if size then
			window.id = 1
			window.container = { block = Items.id.Chest, size = size, slots = {} }
		end
		return window
	end

	-- Window slot of inventory slot i (1-9 hotbar, 10-36), armor slot a, container slot c.
	local function inv(window, i: number): number
		return Menu.windowIndex(window, "inventory", i)
	end
	local function arm(window, a: number): number
		return Menu.windowIndex(window, "armor", a)
	end
	local function con(window, c: number): number
		return Menu.windowIndex(window, "container", c)
	end

	local function click(window, slot: number, clickType: number, button: number, creative: boolean?)
		return Menu.apply(
			window,
			{ kind = "click", window = window.id, slot = slot, clickType = clickType, button = button },
			creative == true
		)
	end
	local function drag(window, mode: number, slots, creative: boolean?)
		return Menu.apply(window, { kind = "drag", window = window.id, mode = mode, slots = slots }, creative == true)
	end

	local function is(stack, item: number?, count: number?, what: string)
		if item == nil then
			if stack ~= nil then
				error(`{what}: expected empty, got {stack.item} x {stack.count}`, 2)
			end
			return
		end
		if stack == nil then
			error(`{what}: expected {item} x {count}, got empty`, 2)
		end
		if stack.item ~= item or stack.count ~= count then
			error(`{what}: expected {item} x {count}, got {stack.item} x {stack.count}`, 2)
		end
	end

	local function stackText(stack): string
		return if stack then `{stack.item}x{stack.count}` else "-"
	end

	-- Everything about a window as text, to compare states.
	local function dump(window): string
		local parts = { `id{window.id}` }
		local container = window.container
		if container then
			table.insert(parts, `c{container.block}/{container.size}`)
			for i = 1, container.size do
				table.insert(parts, stackText(container.slots[i]))
			end
		end
		local inventory = window.inventory
		table.insert(parts, "|")
		for i = 1, 4 do
			table.insert(parts, stackText(inventory.armor[i]))
		end
		table.insert(parts, "|")
		for i = 1, 36 do
			table.insert(parts, stackText(inventory.slots[i]))
		end
		table.insert(parts, `| cursor {stackText(inventory.cursor)} sel {inventory.selected}`)
		return table.concat(parts, " ")
	end

	-- Item -> count over the window, cursor and `extra` stacks.
	local function totals(window, extra): { [number]: number }
		local sums = {}
		local function add(stack)
			if stack then
				sums[stack.item] = (sums[stack.item] or 0) + stack.count
			end
		end
		local container = window.container
		if container then
			for i = 1, container.size do
				add(container.slots[i])
			end
		end
		for i = 1, 4 do
			add(window.inventory.armor[i])
		end
		for i = 1, 36 do
			add(window.inventory.slots[i])
		end
		add(window.inventory.cursor)
		for _, stack in extra or {} do
			add(stack)
		end
		return sums
	end

	local function sameTotals(a, b): (boolean, string)
		for item, count in a do
			if (b[item] or 0) ~= count then
				return false, `item {item}: {count} before, {b[item] or 0} after`
			end
		end
		for item, count in b do
			if (a[item] or 0) ~= count then
				return false, `item {item}: {a[item] or 0} before, {count} after`
			end
		end
		return true, ""
	end

	-- Fills every inventory slot 1..36 with full stacks of `item`.
	local function fillInventory(window, item: number)
		for i = 1, 36 do
			window.inventory.slots[i] = S(item, Items.maxStack(item))
		end
	end

	-- Asserts that `action` changes nothing and throws nothing.
	local function unchanged(window, action, creative: boolean, what: string)
		local before = dump(window)
		local ok, thrown = pcall(Menu.apply, window, action, creative)
		if not ok then
			error(`{what}: errored: {thrown}`, 2)
		end
		if #thrown ~= 0 then
			error(`{what}: threw {#thrown} stacks`, 2)
		end
		if dump(window) ~= before then
			error(`{what}: changed the window\n  before {before}\n  after  {dump(window)}`, 2)
		end
	end

	--[[ Layout ]]

	t.test("inventory menu: window layout, locate and windowIndex", function()
		local w = newWindow()
		t.eq(Menu.size(w), 40)
		local store, i = Menu.locate(w, 0)
		t.eq(store, "armor")
		t.eq(i, 1)
		store, i = Menu.locate(w, 3)
		t.eq(store, "armor")
		t.eq(i, 4)
		store, i = Menu.locate(w, 4)
		t.eq(store, "inventory")
		t.eq(i, 10, "window slot 4 is inventory slot 10")
		store, i = Menu.locate(w, 30)
		t.eq(i, 36)
		store, i = Menu.locate(w, 31)
		t.eq(store, "inventory")
		t.eq(i, 1, "window slot 31 is hotbar slot 1")
		store, i = Menu.locate(w, 39)
		t.eq(i, 9)
		t.eq((Menu.locate(w, 40)), nil)
		t.eq((Menu.locate(w, -1)), nil)
		t.eq((Menu.locate(w, OUTSIDE)), nil)
		t.eq((Menu.locate(w, 1.5)), nil)
		t.eq((Menu.locate(w, 0 / 0)), nil)

		local c = newWindow(27)
		t.eq(Menu.size(c), 67)
		store, i = Menu.locate(c, 0)
		t.eq(store, "container")
		t.eq(i, 1)
		store, i = Menu.locate(c, 26)
		t.eq(i, 27)
		store, i = Menu.locate(c, 27)
		t.eq(store, "armor")
		t.eq(i, 1)
		store, i = Menu.locate(c, 31)
		t.eq(store, "inventory")
		t.eq(i, 10)
		store, i = Menu.locate(c, 58)
		t.eq(i, 1)
		t.eq((Menu.locate(c, 67)), nil)

		-- windowIndex is locate's inverse, for both layouts.
		for _, window in { w, c } do
			for index = 0, Menu.size(window) - 1 do
				local s, n = Menu.locate(window, index)
				t.eq(Menu.windowIndex(window, s, n), index, `round trip of {index}`)
			end
		end
		t.eq(Menu.windowIndex(w, "container", 1), nil)
		t.eq(Menu.windowIndex(w, "inventory", 37), nil)
		t.eq(Menu.windowIndex(w, "armor", 0), nil)
	end)

	t.test("inventory menu: get and set reach the right store", function()
		local w = newWindow(9)
		Menu.set(w, con(w, 3), S(DIRT, 5))
		Menu.set(w, arm(w, 2), S(CHESTPLATE, 1))
		Menu.set(w, inv(w, 12), S(STONE, 7))
		Menu.set(w, inv(w, 9), S(PLANKS, 2))
		is(w.container.slots[3], DIRT, 5, "container slot 3")
		is(w.inventory.armor[2], CHESTPLATE, 1, "chest slot")
		is(w.inventory.slots[12], STONE, 7, "inventory slot 12")
		is(w.inventory.slots[9], PLANKS, 2, "hotbar slot 9")
		is(Menu.get(w, inv(w, 12)), STONE, 7, "get")
		t.eq(Menu.get(w, 999), nil)
		t.eq(Menu.get(w, OUTSIDE), nil)
		Menu.set(w, inv(w, 12), nil)
		t.eq(w.inventory.slots[12], nil)
		Menu.set(w, inv(w, 13), S(STONE, 0))
		t.eq(w.inventory.slots[13], nil, "a count of 0 empties the slot")
		Menu.set(w, 999, S(STONE, 1)) -- ignored
		Menu.set(w, -5, S(STONE, 1))
	end)

	t.test("inventory menu: armor slots take only armor of their slot, one item", function()
		local w = newWindow()
		t.ok(Menu.mayPlace(w, arm(w, 1), HELMET))
		t.ok(Menu.mayPlace(w, arm(w, 1), GOLD_HELMET))
		t.ok(not Menu.mayPlace(w, arm(w, 1), BOOTS))
		t.ok(not Menu.mayPlace(w, arm(w, 1), DIRT))
		t.ok(Menu.mayPlace(w, arm(w, 2), CHESTPLATE))
		t.ok(Menu.mayPlace(w, arm(w, 3), LEGGINGS))
		t.ok(Menu.mayPlace(w, arm(w, 4), BOOTS))
		t.ok(not Menu.mayPlace(w, arm(w, 4), LEGGINGS))
		t.ok(Menu.mayPlace(w, inv(w, 10), HELMET), "armor may go anywhere else")
		t.ok(Menu.mayPlace(w, inv(w, 1), DIRT))
		t.ok(not Menu.mayPlace(w, inv(w, 1), UNKNOWN), "unknown items go nowhere")
		t.ok(not Menu.mayPlace(w, 40, DIRT), "out of range")
		t.ok(not Menu.mayPlace(w, OUTSIDE, DIRT))
		t.eq(Menu.maxStackFor(w, inv(w, 1), DIRT), 64)
		t.eq(Menu.maxStackFor(w, inv(w, 1), HELMET), 1)
		t.eq(Menu.maxStackFor(w, arm(w, 1), HELMET), 1)
		t.eq(Menu.maxStackFor(w, arm(w, 1), DIRT), 1, "armor slots hold one item")
		t.eq(Menu.maxStackFor(w, 40, DIRT), 0)
		local c = newWindow(27)
		t.ok(Menu.mayPlace(c, con(c, 1), DIRT))
		t.ok(Menu.mayPlace(c, arm(c, 1), HELMET))
		t.ok(not Menu.mayPlace(c, arm(c, 1), DIRT))
		t.eq(Menu.maxStackFor(c, con(c, 27), DIRT), 64)
	end)

	--[[ PICKUP ]]

	t.test("pickup: clicking an empty slot puts down all (left) or one (right)", function()
		local w = newWindow()
		w.inventory.cursor = S(DIRT, 10)
		t.eq(#click(w, inv(w, 10), Click.Pickup, 0), 0)
		is(w.inventory.slots[10], DIRT, 10, "left: all")
		t.eq(w.inventory.cursor, nil)

		w.inventory.cursor = S(DIRT, 10)
		click(w, inv(w, 11), Click.Pickup, 1)
		is(w.inventory.slots[11], DIRT, 1, "right: one")
		is(w.inventory.cursor, DIRT, 9, "cursor")

		w.inventory.cursor = S(DIRT, 1)
		click(w, inv(w, 12), Click.Pickup, 1)
		is(w.inventory.slots[12], DIRT, 1, "right with one")
		t.eq(w.inventory.cursor, nil, "the last item leaves the cursor")

		-- Empty cursor on an empty slot: nothing.
		local before = dump(w)
		click(w, inv(w, 20), Click.Pickup, 0)
		t.eq(dump(w), before)
	end)

	t.test("pickup: taking all (left) or half rounded up (right)", function()
		local w = newWindow()
		w.inventory.slots[1] = S(DIRT, 5)
		click(w, inv(w, 1), Click.Pickup, 0)
		is(w.inventory.cursor, DIRT, 5, "left takes all")
		t.eq(w.inventory.slots[1], nil)

		w.inventory.cursor = nil
		w.inventory.slots[1] = S(DIRT, 5)
		click(w, inv(w, 1), Click.Pickup, 1)
		is(w.inventory.cursor, DIRT, 3, "right takes (5 + 1) // 2")
		is(w.inventory.slots[1], DIRT, 2, "slot keeps the rest")

		w.inventory.cursor = nil
		w.inventory.slots[1] = S(DIRT, 64)
		click(w, inv(w, 1), Click.Pickup, 1)
		is(w.inventory.cursor, DIRT, 32, "64 halves")
		is(w.inventory.slots[1], DIRT, 32, "64 halves")

		w.inventory.cursor = nil
		w.inventory.slots[1] = S(DIRT, 1)
		click(w, inv(w, 1), Click.Pickup, 1)
		is(w.inventory.cursor, DIRT, 1, "right on one takes it")
		t.eq(w.inventory.slots[1], nil)
	end)

	t.test("pickup: the same item merges up to the max stack", function()
		local w = newWindow()
		w.inventory.slots[12] = S(DIRT, 60)
		w.inventory.cursor = S(DIRT, 10)
		click(w, inv(w, 12), Click.Pickup, 0)
		is(w.inventory.slots[12], DIRT, 64, "left fills up")
		is(w.inventory.cursor, DIRT, 6, "the rest stays carried")

		w.inventory.slots[12] = S(DIRT, 60)
		w.inventory.cursor = S(DIRT, 10)
		click(w, inv(w, 12), Click.Pickup, 1)
		is(w.inventory.slots[12], DIRT, 61, "right adds one")
		is(w.inventory.cursor, DIRT, 9, "cursor")

		w.inventory.slots[12] = S(DIRT, 64)
		w.inventory.cursor = S(DIRT, 10)
		local before = dump(w)
		click(w, inv(w, 12), Click.Pickup, 0)
		click(w, inv(w, 12), Click.Pickup, 1)
		t.eq(dump(w), before, "a full stack takes nothing")

		w.inventory.slots[12] = S(DIRT, 20)
		w.inventory.cursor = S(DIRT, 10)
		click(w, inv(w, 12), Click.Pickup, 0)
		is(w.inventory.slots[12], DIRT, 30, "all fits")
		t.eq(w.inventory.cursor, nil)
	end)

	t.test("pickup: different items swap, into fresh tables", function()
		local w = newWindow()
		w.inventory.slots[3] = S(STONE, 5)
		w.inventory.cursor = S(DIRT, 10)
		click(w, inv(w, 3), Click.Pickup, 0)
		is(w.inventory.slots[3], DIRT, 10, "slot")
		is(w.inventory.cursor, STONE, 5, "cursor")
		click(w, inv(w, 3), Click.Pickup, 1)
		is(w.inventory.slots[3], STONE, 5, "right click swaps too")
		is(w.inventory.cursor, DIRT, 10, "cursor")
		t.ok(w.inventory.cursor ~= w.inventory.slots[3])
	end)

	t.test("pickup: armor slots only take their armor and hold one", function()
		local w = newWindow()
		w.inventory.cursor = S(HELMET, 1)
		click(w, arm(w, 2), Click.Pickup, 0)
		t.eq(w.inventory.armor[2], nil, "a helmet is not a chestplate")
		is(w.inventory.cursor, HELMET, 1, "still carried")
		click(w, arm(w, 1), Click.Pickup, 0)
		is(w.inventory.armor[1], HELMET, 1, "head slot")
		t.eq(w.inventory.cursor, nil)

		-- Dirt neither goes in nor swaps with the helmet.
		w.inventory.cursor = S(DIRT, 1)
		local before = dump(w)
		click(w, arm(w, 1), Click.Pickup, 0)
		click(w, arm(w, 4), Click.Pickup, 0)
		t.eq(dump(w), before, "dirt is not armor")

		-- Another helmet swaps.
		w.inventory.cursor = S(GOLD_HELMET, 1)
		click(w, arm(w, 1), Click.Pickup, 0)
		is(w.inventory.armor[1], GOLD_HELMET, 1, "swapped in")
		is(w.inventory.cursor, HELMET, 1, "swapped out")

		-- Taking armor off with a right click takes the one item.
		w.inventory.cursor = nil
		click(w, arm(w, 1), Click.Pickup, 1)
		is(w.inventory.cursor, GOLD_HELMET, 1, "taken")
		t.eq(w.inventory.armor[1], nil)

		-- A (malformed) carried stack of two helmets: one goes in; no swap since 2 > 1.
		w.inventory.cursor = S(HELMET, 2)
		click(w, arm(w, 1), Click.Pickup, 0)
		is(w.inventory.armor[1], HELMET, 1, "one fits")
		is(w.inventory.cursor, HELMET, 1, "one left")
		w.inventory.cursor = S(GOLD_HELMET, 2)
		before = dump(w)
		click(w, arm(w, 1), Click.Pickup, 0)
		t.eq(dump(w), before, "a carried count above the slot's max does not swap")
	end)

	t.test("pickup: clicking outside throws all (left) or one (right)", function()
		local w = newWindow()
		w.inventory.cursor = S(DIRT, 10)
		local thrown = click(w, OUTSIDE, Click.Pickup, 1)
		t.eq(#thrown, 1)
		is(thrown[1], DIRT, 1, "right throws one")
		is(w.inventory.cursor, DIRT, 9, "cursor")
		thrown = click(w, OUTSIDE, Click.Pickup, 0)
		t.eq(#thrown, 1)
		is(thrown[1], DIRT, 9, "left throws all")
		t.eq(w.inventory.cursor, nil)
		t.eq(#click(w, OUTSIDE, Click.Pickup, 0), 0, "nothing carried, nothing thrown")

		-- Minecraft checks OUTSIDE before the click type, so a shift click outside throws too.
		w.inventory.cursor = S(STONE, 3)
		thrown = click(w, OUTSIDE, Click.QuickMove, 0)
		is(thrown[1], STONE, 3, "shift click outside")
		t.eq(w.inventory.cursor, nil)

		-- The thrown stack is a new table.
		local carried = S(STONE, 3)
		w.inventory.cursor = carried
		thrown = click(w, OUTSIDE, Click.Pickup, 0)
		t.ok(thrown[1] ~= carried)
		t.eq(carried.count, 3, "the old cursor table is not changed")

		-- In a container window too.
		local c = newWindow(27)
		c.inventory.cursor = S(DIRT, 2)
		thrown = click(c, OUTSIDE, Click.Pickup, 0)
		is(thrown[1], DIRT, 2, "container window")
	end)

	--[[ QUICK_MOVE without a container ]]

	t.test("quick move (inventory): hotbar -> slots 10..36, merging first, then the first empty slot", function()
		local w = newWindow()
		w.inventory.slots[10] = S(STONE, 5)
		w.inventory.slots[12] = S(DIRT, 60)
		w.inventory.slots[20] = S(DIRT, 63)
		w.inventory.slots[3] = S(DIRT, 64)
		click(w, inv(w, 3), Click.QuickMove, 0)
		is(w.inventory.slots[12], DIRT, 64, "merged into 12")
		is(w.inventory.slots[20], DIRT, 64, "merged into 20")
		is(w.inventory.slots[11], DIRT, 59, "the rest in the first empty slot")
		is(w.inventory.slots[10], STONE, 5, "other items untouched")
		t.eq(w.inventory.slots[3], nil, "hotbar slot emptied")
		t.eq(w.inventory.slots[13], nil, "only one empty slot used")
		t.eq(w.inventory.cursor, nil)
	end)

	t.test("quick move (inventory): slots 10..36 -> hotbar", function()
		local w = newWindow()
		w.inventory.slots[15] = S(DIRT, 30)
		w.inventory.slots[4] = S(DIRT, 50)
		w.inventory.slots[1] = S(STONE, 1)
		click(w, inv(w, 15), Click.QuickMove, 1)
		is(w.inventory.slots[4], DIRT, 64, "merged into hotbar 4")
		is(w.inventory.slots[2], DIRT, 16, "rest in the first empty hotbar slot")
		t.eq(w.inventory.slots[15], nil)

		-- Never into other inventory slots, even when the hotbar is full.
		for i = 1, 9 do
			w.inventory.slots[i] = S(STONE, 64)
		end
		w.inventory.slots[15] = S(DIRT, 30)
		local before = dump(w)
		click(w, inv(w, 15), Click.QuickMove, 0)
		t.eq(dump(w), before, "full hotbar: nothing moves")

		-- And the hotbar goes only into 10..36.
		fillInventory(w, STONE)
		w.inventory.slots[2] = S(DIRT, 5)
		w.inventory.slots[3] = nil
		before = dump(w)
		click(w, inv(w, 2), Click.QuickMove, 0)
		t.eq(dump(w), before, "slots 10..36 full: nothing moves (not even within the hotbar)")
	end)

	t.test("quick move (inventory): partial moves when the target has little room", function()
		local w = newWindow()
		fillInventory(w, STONE)
		w.inventory.slots[25] = S(DIRT, 50)
		w.inventory.slots[5] = S(DIRT, 30)
		click(w, inv(w, 5), Click.QuickMove, 0)
		is(w.inventory.slots[25], DIRT, 64, "filled")
		is(w.inventory.slots[5], DIRT, 16, "the rest stays")
	end)

	t.test("quick move (inventory): armor goes to slots 10..36, then the hotbar", function()
		local w = newWindow()
		w.inventory.armor[1] = S(HELMET, 1)
		click(w, arm(w, 1), Click.QuickMove, 0)
		is(w.inventory.slots[10], HELMET, 1, "first inventory slot")
		t.eq(w.inventory.armor[1], nil)

		w = newWindow()
		for i = 10, 36 do
			w.inventory.slots[i] = S(STONE, 64)
		end
		w.inventory.slots[1] = S(STONE, 64)
		w.inventory.armor[4] = S(BOOTS, 1)
		click(w, arm(w, 4), Click.QuickMove, 0)
		is(w.inventory.slots[2], BOOTS, 1, "inventory full: the hotbar")

		fillInventory(w, STONE)
		w.inventory.armor[3] = S(LEGGINGS, 1)
		local before = dump(w)
		click(w, arm(w, 3), Click.QuickMove, 0)
		t.eq(dump(w), before, "everything full: stays on")
	end)

	t.test("quick move (inventory): armor items go to their empty armor slot", function()
		local w = newWindow()
		w.inventory.slots[1] = S(HELMET, 1)
		w.inventory.slots[20] = S(LEGGINGS, 1)
		w.inventory.slots[36] = S(CHESTPLATE, 1)
		w.inventory.slots[9] = S(BOOTS, 1)
		click(w, inv(w, 1), Click.QuickMove, 0)
		click(w, inv(w, 20), Click.QuickMove, 0)
		click(w, inv(w, 36), Click.QuickMove, 0)
		click(w, inv(w, 9), Click.QuickMove, 0)
		is(w.inventory.armor[1], HELMET, 1, "head")
		is(w.inventory.armor[2], CHESTPLATE, 1, "chest")
		is(w.inventory.armor[3], LEGGINGS, 1, "legs")
		is(w.inventory.armor[4], BOOTS, 1, "feet")
		for i = 1, 36 do
			t.eq(w.inventory.slots[i], nil, `slot {i} emptied`)
		end

		-- Armor slot taken: the usual hotbar <-> inventory move.
		w.inventory.slots[1] = S(GOLD_HELMET, 1)
		click(w, inv(w, 1), Click.QuickMove, 0)
		is(w.inventory.armor[1], HELMET, 1, "worn helmet stays")
		is(w.inventory.slots[10], GOLD_HELMET, 1, "hotbar -> inventory")
		click(w, inv(w, 10), Click.QuickMove, 0)
		is(w.inventory.slots[1], GOLD_HELMET, 1, "inventory -> hotbar")
	end)

	t.test("quick move: an empty slot does nothing", function()
		local w = newWindow()
		w.inventory.slots[2] = S(DIRT, 3)
		unchanged(
			w,
			{ kind = "click", window = 0, slot = inv(w, 10), clickType = Click.QuickMove, button = 0 },
			false,
			"empty"
		)
		local c = newWindow(27)
		unchanged(
			c,
			{ kind = "click", window = 1, slot = con(c, 1), clickType = Click.QuickMove, button = 0 },
			false,
			"empty"
		)
	end)

	--[[ QUICK_MOVE with a container ]]

	t.test("quick move (container): container -> inventory backwards, hotbar's right end first", function()
		local c = newWindow(27)
		c.container.slots[1] = S(DIRT, 20)
		c.inventory.slots[2] = S(DIRT, 50)
		c.inventory.slots[15] = S(DIRT, 60)
		click(c, con(c, 1), Click.QuickMove, 0)
		is(c.inventory.slots[2], DIRT, 64, "hotbar 2 merged first")
		is(c.inventory.slots[15], DIRT, 64, "then slot 15")
		is(c.inventory.slots[9], DIRT, 2, "the rest in hotbar 9")
		t.eq(c.container.slots[1], nil)

		c.container.slots[5] = S(STONE, 10)
		click(c, con(c, 5), Click.QuickMove, 1)
		is(c.inventory.slots[8], STONE, 10, "next empty going backwards: hotbar 8")

		-- Full hotbar: the last empty slot of 10..36.
		for i = 1, 9 do
			c.inventory.slots[i] = S(PLANKS, 64)
		end
		c.container.slots[6] = S(COBBLE, 4)
		click(c, con(c, 6), Click.QuickMove, 0)
		is(c.inventory.slots[36], COBBLE, 4, "slot 36")
	end)

	t.test("quick move (container): container items never go into armor slots", function()
		local c = newWindow(27)
		fillInventory(c, STONE)
		c.container.slots[1] = S(HELMET, 1)
		local before = dump(c)
		click(c, con(c, 1), Click.QuickMove, 0)
		t.eq(dump(c), before, "the empty head slot is not a target")
	end)

	t.test("quick move (container): inventory, hotbar and armor -> container, forwards", function()
		local c = newWindow(27)
		c.container.slots[1] = S(STONE, 64)
		c.container.slots[3] = S(DIRT, 60)
		c.inventory.slots[1] = S(DIRT, 10)
		click(c, inv(c, 1), Click.QuickMove, 0)
		is(c.container.slots[3], DIRT, 64, "merged")
		is(c.container.slots[2], DIRT, 6, "first empty container slot")
		t.eq(c.inventory.slots[1], nil)

		c.inventory.slots[30] = S(PLANKS, 33)
		click(c, inv(c, 30), Click.QuickMove, 0)
		is(c.container.slots[4], PLANKS, 33, "from slots 10..36")

		c.inventory.armor[2] = S(CHESTPLATE, 1)
		click(c, arm(c, 2), Click.QuickMove, 0)
		is(c.container.slots[5], CHESTPLATE, 1, "from armor")
		t.eq(c.inventory.armor[2], nil)

		-- An armor item in the inventory goes to the container, not to its armor slot.
		c.inventory.slots[20] = S(BOOTS, 1)
		click(c, inv(c, 20), Click.QuickMove, 0)
		is(c.container.slots[6], BOOTS, 1, "boots into the chest")
		t.eq(c.inventory.armor[4], nil)
	end)

	t.test("quick move (container): a full container takes nothing (no hotbar toggle)", function()
		local c = newWindow(9)
		for i = 1, 9 do
			c.container.slots[i] = S(STONE, 64)
		end
		c.inventory.slots[1] = S(DIRT, 10)
		c.inventory.slots[20] = S(DIRT, 10)
		local before = dump(c)
		click(c, inv(c, 1), Click.QuickMove, 0)
		click(c, inv(c, 20), Click.QuickMove, 0)
		t.eq(dump(c), before)

		c.container.slots[9] = S(DIRT, 60)
		click(c, inv(c, 20), Click.QuickMove, 0)
		is(c.container.slots[9], DIRT, 64, "partial merge")
		is(c.inventory.slots[20], DIRT, 6, "the rest stays")
	end)

	--[[ SWAP ]]

	t.test("swap: number keys exchange a slot with a hotbar slot", function()
		local w = newWindow()
		w.inventory.slots[10] = S(DIRT, 5)
		click(w, inv(w, 10), Click.Swap, 0)
		is(w.inventory.slots[1], DIRT, 5, "into the empty hotbar slot")
		t.eq(w.inventory.slots[10], nil)

		w.inventory.slots[3] = S(STONE, 7)
		click(w, inv(w, 10), Click.Swap, 2)
		is(w.inventory.slots[10], STONE, 7, "out of the hotbar into the empty slot")
		t.eq(w.inventory.slots[3], nil)

		click(w, inv(w, 10), Click.Swap, 0)
		is(w.inventory.slots[10], DIRT, 5, "exchanged")
		is(w.inventory.slots[1], STONE, 7, "exchanged")

		-- Hotbar to hotbar.
		click(w, inv(w, 1), Click.Swap, 8)
		is(w.inventory.slots[9], STONE, 7, "hotbar 1 -> 9")
		t.eq(w.inventory.slots[1], nil)

		-- A slot with itself.
		local before = dump(w)
		click(w, inv(w, 9), Click.Swap, 8)
		t.eq(dump(w), before, "itself")

		-- Both empty.
		click(w, inv(w, 20), Click.Swap, 4)
		t.eq(dump(w), before, "both empty")
	end)

	t.test("swap: armor slots follow mayPlace", function()
		local w = newWindow()
		w.inventory.slots[1] = S(DIRT, 5)
		local before = dump(w)
		click(w, arm(w, 1), Click.Swap, 0)
		t.eq(dump(w), before, "dirt can't be worn")

		w.inventory.slots[1] = S(HELMET, 1)
		click(w, arm(w, 1), Click.Swap, 0)
		is(w.inventory.armor[1], HELMET, 1, "helmet worn")
		t.eq(w.inventory.slots[1], nil)

		w.inventory.slots[1] = S(BOOTS, 1)
		before = dump(w)
		click(w, arm(w, 1), Click.Swap, 0)
		t.eq(dump(w), before, "boots don't swap with a helmet")

		w.inventory.slots[1] = S(GOLD_HELMET, 1)
		click(w, arm(w, 1), Click.Swap, 0)
		is(w.inventory.armor[1], GOLD_HELMET, 1, "helmets exchange")
		is(w.inventory.slots[1], HELMET, 1, "helmets exchange")

		w.inventory.slots[2] = nil
		click(w, arm(w, 1), Click.Swap, 1)
		is(w.inventory.slots[2], GOLD_HELMET, 1, "taken off into an empty hotbar slot")
		t.eq(w.inventory.armor[1], nil)
	end)

	t.test("swap: container slots", function()
		local c = newWindow(27)
		c.container.slots[4] = S(PLANKS, 12)
		c.inventory.slots[5] = S(DIRT, 3)
		click(c, con(c, 4), Click.Swap, 4)
		is(c.container.slots[4], DIRT, 3, "container")
		is(c.inventory.slots[5], PLANKS, 12, "hotbar 5")
		-- The hotbar is the window's hotbar, at its own window slots.
		click(c, inv(c, 5), Click.Swap, 0)
		is(c.inventory.slots[1], PLANKS, 12, "hotbar 5 -> 1")
	end)

	--[[ CLONE ]]

	t.test("clone: creative middle click puts a full stack on the empty cursor", function()
		local w = newWindow()
		w.inventory.slots[10] = S(STONE, 5)
		w.inventory.armor[1] = S(HELMET, 1)
		unchanged(
			w,
			{ kind = "click", window = 0, slot = inv(w, 10), clickType = Click.Clone, button = 2 },
			false,
			"survival"
		)
		click(w, inv(w, 10), Click.Clone, 2, true)
		is(w.inventory.cursor, STONE, 64, "full stack")
		is(w.inventory.slots[10], STONE, 5, "slot untouched")
		unchanged(
			w,
			{ kind = "click", window = 0, slot = arm(w, 1), clickType = Click.Clone, button = 2 },
			true,
			"cursor busy"
		)
		w.inventory.cursor = nil
		click(w, arm(w, 1), Click.Clone, 2, true)
		is(w.inventory.cursor, HELMET, 1, "armor stacks to one")
		w.inventory.cursor = nil
		unchanged(
			w,
			{ kind = "click", window = 0, slot = inv(w, 11), clickType = Click.Clone, button = 2 },
			true,
			"empty slot"
		)
	end)

	--[[ THROW ]]

	t.test("throw: Q throws one, Ctrl+Q the stack, only with an empty cursor", function()
		local w = newWindow()
		w.inventory.slots[10] = S(DIRT, 10)
		local thrown = click(w, inv(w, 10), Click.Throw, 0)
		t.eq(#thrown, 1)
		is(thrown[1], DIRT, 1, "one")
		is(w.inventory.slots[10], DIRT, 9, "slot")
		thrown = click(w, inv(w, 10), Click.Throw, 1)
		is(thrown[1], DIRT, 9, "the stack")
		t.eq(w.inventory.slots[10], nil)
		t.eq(#click(w, inv(w, 10), Click.Throw, 0), 0, "empty slot")

		w.inventory.slots[11] = S(DIRT, 10)
		w.inventory.cursor = S(STONE, 1)
		unchanged(
			w,
			{ kind = "click", window = 0, slot = inv(w, 11), clickType = Click.Throw, button = 1 },
			false,
			"cursor busy"
		)
		w.inventory.cursor = nil

		w.inventory.armor[2] = S(CHESTPLATE, 1)
		thrown = click(w, arm(w, 2), Click.Throw, 0)
		is(thrown[1], CHESTPLATE, 1, "from an armor slot")
		t.eq(w.inventory.armor[2], nil)

		local c = newWindow(27)
		c.container.slots[1] = S(PLANKS, 3)
		thrown = click(c, con(c, 1), Click.Throw, 1)
		is(thrown[1], PLANKS, 3, "from a container")
	end)

	--[[ PICKUP_ALL ]]

	t.test("pickup all: double click gathers the carried item, full stacks last", function()
		local w = newWindow()
		w.inventory.cursor = S(DIRT, 1)
		w.inventory.slots[1] = S(DIRT, 64)
		w.inventory.slots[10] = S(DIRT, 10)
		w.inventory.slots[20] = S(DIRT, 20)
		w.inventory.slots[5] = S(DIRT, 40)
		w.inventory.slots[6] = S(STONE, 5)
		click(w, inv(w, 11), Click.PickupAll, 0)
		-- Window order: slots 10..36 come before the hotbar.
		is(w.inventory.cursor, DIRT, 64, "cursor full")
		t.eq(w.inventory.slots[10], nil, "slot 10 taken")
		t.eq(w.inventory.slots[20], nil, "slot 20 taken")
		is(w.inventory.slots[5], DIRT, 7, "hotbar 5 gave 33")
		is(w.inventory.slots[1], DIRT, 64, "the full stack is left alone")
		is(w.inventory.slots[6], STONE, 5, "other items stay")
	end)

	t.test("pickup all: the second pass takes from full stacks", function()
		local w = newWindow()
		w.inventory.cursor = S(DIRT, 1)
		w.inventory.slots[1] = S(DIRT, 64)
		w.inventory.slots[2] = S(DIRT, 64)
		click(w, inv(w, 30), Click.PickupAll, 0)
		is(w.inventory.cursor, DIRT, 64, "cursor")
		is(w.inventory.slots[1], DIRT, 1, "first full stack gave 63")
		is(w.inventory.slots[2], DIRT, 64, "second untouched")
	end)

	t.test("pickup all: only on an empty slot, backwards with button 1, containers included", function()
		local w = newWindow()
		w.inventory.cursor = S(DIRT, 1)
		w.inventory.slots[10] = S(DIRT, 10)
		w.inventory.slots[11] = S(DIRT, 10)
		unchanged(
			w,
			{ kind = "click", window = 0, slot = inv(w, 11), clickType = Click.PickupAll, button = 0 },
			false,
			"slot not empty"
		)

		w = newWindow()
		w.inventory.cursor = S(DIRT, 1)
		w.inventory.slots[10] = S(DIRT, 40)
		w.inventory.slots[9] = S(DIRT, 40)
		click(w, inv(w, 30), Click.PickupAll, 1)
		t.eq(w.inventory.slots[9], nil, "hotbar 9 first going backwards")
		is(w.inventory.slots[10], DIRT, 17, "then slot 10")
		is(w.inventory.cursor, DIRT, 64, "cursor")

		local c = newWindow(27)
		c.inventory.cursor = S(DIRT, 1)
		c.container.slots[27] = S(DIRT, 30)
		c.inventory.slots[10] = S(DIRT, 40)
		click(c, con(c, 1), Click.PickupAll, 0)
		t.eq(c.container.slots[27], nil, "container slots come first")
		is(c.inventory.slots[10], DIRT, 7, "then the inventory")
		is(c.inventory.cursor, DIRT, 64, "cursor")

		-- Nothing carried: nothing happens.
		local e = newWindow()
		e.inventory.slots[10] = S(DIRT, 10)
		unchanged(
			e,
			{ kind = "click", window = 0, slot = inv(e, 11), clickType = Click.PickupAll, button = 0 },
			false,
			"no cursor"
		)

		-- Armor (max 1) is never gathered: the cursor is already full.
		local a = newWindow()
		a.inventory.cursor = S(HELMET, 1)
		a.inventory.slots[10] = S(HELMET, 1)
		unchanged(
			a,
			{ kind = "click", window = 0, slot = inv(a, 11), clickType = Click.PickupAll, button = 0 },
			false,
			"armor"
		)
	end)

	--[[ Drags (quick craft) ]]

	t.test("drag: split spreads evenly, the rest stays carried", function()
		local w = newWindow()
		w.inventory.cursor = S(DIRT, 64)
		drag(w, Drag.Split, { inv(w, 10), inv(w, 11), inv(w, 12) })
		is(w.inventory.slots[10], DIRT, 21, "10")
		is(w.inventory.slots[11], DIRT, 21, "11")
		is(w.inventory.slots[12], DIRT, 21, "12")
		is(w.inventory.cursor, DIRT, 1, "remainder")
	end)

	t.test("drag: one each", function()
		local w = newWindow()
		w.inventory.cursor = S(DIRT, 64)
		drag(w, Drag.One, { inv(w, 1), inv(w, 2), inv(w, 3) })
		is(w.inventory.slots[1], DIRT, 1, "1")
		is(w.inventory.slots[2], DIRT, 1, "2")
		is(w.inventory.slots[3], DIRT, 1, "3")
		is(w.inventory.cursor, DIRT, 61, "cursor")

		w.inventory.cursor = S(STONE, 3)
		drag(w, Drag.One, { inv(w, 10), inv(w, 11), inv(w, 12), inv(w, 13), inv(w, 14) })
		is(w.inventory.slots[12], STONE, 1, "third")
		t.eq(w.inventory.slots[13], nil, "no items left for the fourth")
		t.eq(w.inventory.cursor, nil, "all used")
	end)

	t.test("drag: slots with the same item fill up to the max, others don't count", function()
		local w = newWindow()
		w.inventory.cursor = S(DIRT, 30)
		w.inventory.slots[10] = S(DIRT, 60)
		drag(w, Drag.Split, { inv(w, 10), inv(w, 11) })
		is(w.inventory.slots[10], DIRT, 64, "capped at 64")
		is(w.inventory.slots[11], DIRT, 15, "half")
		is(w.inventory.cursor, DIRT, 11, "what did not fit stays")

		-- A different item is skipped and does not count for the split.
		w = newWindow()
		w.inventory.cursor = S(DIRT, 10)
		w.inventory.slots[11] = S(STONE, 1)
		drag(w, Drag.Split, { inv(w, 10), inv(w, 11), inv(w, 12) })
		is(w.inventory.slots[10], DIRT, 5, "10")
		is(w.inventory.slots[11], STONE, 1, "11 untouched")
		is(w.inventory.slots[12], DIRT, 5, "12")
		t.eq(w.inventory.cursor, nil)

		-- Armor slots don't take dirt.
		w = newWindow()
		w.inventory.cursor = S(DIRT, 9)
		drag(w, Drag.Split, { arm(w, 1), inv(w, 10), inv(w, 11) })
		t.eq(w.inventory.armor[1], nil, "head")
		is(w.inventory.slots[10], DIRT, 4, "10")
		is(w.inventory.slots[11], DIRT, 4, "11")
		is(w.inventory.cursor, DIRT, 1, "cursor")

		-- Minecraft's canItemQuickReplace ignores the carried count: a full stack of the same item
		-- still counts as a drag slot (it takes nothing, its share stays carried).
		w = newWindow()
		w.inventory.cursor = S(DIRT, 10)
		w.inventory.slots[11] = S(DIRT, 64)
		drag(w, Drag.Split, { inv(w, 10), inv(w, 11) })
		is(w.inventory.slots[10], DIRT, 5, "half of 10")
		is(w.inventory.slots[11], DIRT, 64, "full")
		is(w.inventory.cursor, DIRT, 5, "the full slot's share")
	end)

	t.test("drag: no more slots than carried items (modes 0 and 1)", function()
		local w = newWindow()
		w.inventory.cursor = S(DIRT, 2)
		drag(w, Drag.Split, { inv(w, 10), inv(w, 11), inv(w, 12), inv(w, 13) })
		is(w.inventory.slots[10], DIRT, 1, "10")
		is(w.inventory.slots[11], DIRT, 1, "11")
		t.eq(w.inventory.slots[12], nil, "12 never added")
		t.eq(w.inventory.slots[13], nil, "13 never added")
		t.eq(w.inventory.cursor, nil)
	end)

	t.test("drag: one slot (or duplicates of it) is a click with button = mode", function()
		local w = newWindow()
		w.inventory.cursor = S(DIRT, 10)
		drag(w, Drag.Split, { inv(w, 10) })
		is(w.inventory.slots[10], DIRT, 10, "split on one slot places all")
		t.eq(w.inventory.cursor, nil)

		w.inventory.cursor = S(DIRT, 10)
		drag(w, Drag.One, { inv(w, 11), inv(w, 11), inv(w, 11) })
		is(w.inventory.slots[11], DIRT, 1, "one, once")
		is(w.inventory.cursor, DIRT, 9, "cursor")

		-- A slot with another item never joins a drag, so it is not a click (no swap).
		w.inventory.slots[12] = S(STONE, 4)
		unchanged(w, { kind = "drag", window = 0, mode = Drag.Split, slots = { inv(w, 12) } }, false, "other item")

		-- A one-slot drag onto the same item merges, like a click.
		w.inventory.slots[13] = S(DIRT, 60)
		drag(w, Drag.Split, { inv(w, 13) })
		is(w.inventory.slots[13], DIRT, 64, "merged")
		is(w.inventory.cursor, DIRT, 5, "cursor")

		-- Duplicates count once when spreading.
		w = newWindow()
		w.inventory.cursor = S(DIRT, 10)
		drag(w, Drag.Split, { inv(w, 10), inv(w, 11), inv(w, 10), inv(w, 11) })
		is(w.inventory.slots[10], DIRT, 5, "10")
		is(w.inventory.slots[11], DIRT, 5, "11")
		t.eq(w.inventory.cursor, nil)

		-- One helmet over two slots: only the first is added, then it is a click.
		w = newWindow()
		w.inventory.cursor = S(HELMET, 1)
		drag(w, Drag.Split, { arm(w, 1), inv(w, 10) })
		is(w.inventory.armor[1], HELMET, 1, "worn")
		t.eq(w.inventory.slots[10], nil)
	end)

	t.test("drag: nothing happens without slots or a carried stack", function()
		local w = newWindow()
		w.inventory.cursor = S(DIRT, 10)
		w.inventory.slots[10] = S(STONE, 1)
		unchanged(w, { kind = "drag", window = 0, mode = Drag.Split, slots = {} }, false, "no slots")
		unchanged(w, { kind = "drag", window = 0, mode = Drag.Split, slots = { inv(w, 10) } }, false, "no usable slot")
		w.inventory.cursor = nil
		unchanged(
			w,
			{ kind = "drag", window = 0, mode = Drag.Split, slots = { inv(w, 11), inv(w, 12) } },
			false,
			"no cursor"
		)
	end)

	t.test("drag: clone mode is creative only and gives full stacks", function()
		local w = newWindow()
		w.inventory.cursor = S(DIRT, 10)
		w.inventory.slots[11] = S(DIRT, 20)
		local action = { kind = "drag", window = 0, mode = Drag.Clone, slots = { inv(w, 10), inv(w, 11) } }
		unchanged(w, action, false, "survival")
		Menu.apply(w, action, true)
		is(w.inventory.slots[10], DIRT, 64, "full stack")
		is(w.inventory.slots[11], DIRT, 64, "filled up")
		-- Minecraft subtracts the made items from the carried count: 10 - 64 - 44 < 0.
		t.eq(w.inventory.cursor, nil, "carried count used up")

		-- More slots than carried items is fine in clone mode.
		w = newWindow()
		w.inventory.cursor = S(STONE, 1)
		drag(w, Drag.Clone, { inv(w, 1), inv(w, 2), inv(w, 3) }, true)
		is(w.inventory.slots[3], STONE, 64, "third slot")

		-- One slot: a PICKUP click with button 2, which does nothing.
		w = newWindow()
		w.inventory.cursor = S(STONE, 5)
		unchanged(w, { kind = "drag", window = 0, mode = Drag.Clone, slots = { inv(w, 1) } }, true, "one slot")
	end)

	t.test("drag: broken rules make the whole drag invalid", function()
		local w = newWindow()
		w.inventory.cursor = S(DIRT, 10)
		local good = { inv(w, 10), inv(w, 11) }
		unchanged(w, { kind = "drag", window = 0, mode = 3, slots = good }, true, "mode 3")
		unchanged(w, { kind = "drag", window = 1, mode = 0, slots = good }, false, "wrong window")
		unchanged(w, { kind = "drag", window = 0, mode = 0, slots = { inv(w, 10), 40 } }, false, "slot out of range")
		unchanged(w, { kind = "drag", window = 0, mode = 0, slots = { inv(w, 10), OUTSIDE } }, false, "outside")
		unchanged(w, { kind = "drag", window = 0, mode = 0, slots = { inv(w, 10), 1.5 } }, false, "fraction")
		unchanged(w, { kind = "drag", window = 0, mode = 0, slots = { inv(w, 10), "x" } }, false, "string")
		unchanged(w, { kind = "drag", window = 0, mode = 0, slots = nil }, false, "no list")
		local many = {}
		for i = 1, Types.MAX_DRAG + 1 do
			many[i] = inv(w, 10 + i % 27)
		end
		unchanged(w, { kind = "drag", window = 0, mode = 0, slots = many }, false, "too many slots")

		-- Only the array part counts.
		drag(w, Drag.Split, { inv(w, 10), inv(w, 11), extra = "x", [0.5] = 99 } :: any)
		is(w.inventory.slots[10], DIRT, 5, "10")
		is(w.inventory.slots[11], DIRT, 5, "11")
	end)

	t.test("drag: container windows", function()
		local c = newWindow(27)
		c.inventory.cursor = S(PLANKS, 30)
		drag(c, Drag.Split, { con(c, 1), con(c, 2), inv(c, 1) })
		is(c.container.slots[1], PLANKS, 10, "container 1")
		is(c.container.slots[2], PLANKS, 10, "container 2")
		is(c.inventory.slots[1], PLANKS, 10, "hotbar 1")
		t.eq(c.inventory.cursor, nil)
	end)

	--[[ select / drop / place ]]

	t.test("select: hotbar slots 1..9 only", function()
		local w = newWindow()
		Menu.apply(w, { kind = "select", slot = 5 }, false)
		t.eq(w.inventory.selected, 5)
		Menu.apply(w, { kind = "select", slot = 9 }, true)
		t.eq(w.inventory.selected, 9)
		for _, bad in { 0, 10, -1, 2.5, 0 / 0, math.huge } do
			unchanged(w, { kind = "select", slot = bad }, false, `slot {bad}`)
		end
	end)

	t.test("drop: one or all of the selected stack", function()
		local w = newWindow()
		w.inventory.selected = 3
		w.inventory.slots[3] = S(DIRT, 10)
		local thrown = Menu.apply(w, { kind = "drop", all = false }, false)
		is(thrown[1], DIRT, 1, "one")
		is(w.inventory.slots[3], DIRT, 9, "slot")
		thrown = Menu.apply(w, { kind = "drop", all = true }, true)
		is(thrown[1], DIRT, 9, "all")
		t.eq(w.inventory.slots[3], nil)
		unchanged(w, { kind = "drop", all = true }, false, "empty hand")
	end)

	t.test("place: survival uses one of the held item, creative none", function()
		local w = newWindow()
		w.inventory.selected = 2
		w.inventory.slots[2] = S(DIRT, 2)
		t.eq(#Menu.apply(w, { kind = "place", item = DIRT }, false), 0)
		is(w.inventory.slots[2], DIRT, 1, "one used")
		unchanged(w, { kind = "place", item = STONE }, false, "other item")
		unchanged(w, { kind = "place", item = DIRT }, true, "creative")
		unchanged(w, { kind = "place", item = UNKNOWN }, false, "unknown")
		Menu.apply(w, { kind = "place", item = DIRT }, false)
		t.eq(w.inventory.slots[2], nil, "the last one")
		unchanged(w, { kind = "place", item = DIRT }, false, "nothing held")
	end)

	--[[ creative ]]

	t.test("creative: sets the cursor or a slot, within the rules", function()
		local w = newWindow()
		local function creative(slot, item, count)
			return { kind = "creative", window = w.id, slot = slot, item = item, count = count }
		end
		unchanged(w, creative(CURSOR, STONE, 64), false, "survival")
		Menu.apply(w, creative(CURSOR, STONE, 64), true)
		is(w.inventory.cursor, STONE, 64, "cursor")
		Menu.apply(w, creative(CURSOR, 0, 0), true)
		t.eq(w.inventory.cursor, nil, "count 0 clears (any item)")

		Menu.apply(w, creative(inv(w, 5), PLANKS, 30), true)
		is(w.inventory.slots[5], PLANKS, 30, "slot")
		Menu.apply(w, creative(inv(w, 5), PLANKS, 0), true)
		t.eq(w.inventory.slots[5], nil, "cleared")

		Menu.apply(w, creative(arm(w, 1), HELMET, 1), true)
		is(w.inventory.armor[1], HELMET, 1, "head")
		unchanged(w, creative(arm(w, 1), DIRT, 1), true, "dirt on the head")
		unchanged(w, creative(arm(w, 2), BOOTS, 1), true, "boots on the chest")
		unchanged(w, creative(inv(w, 1), HELMET, 2), true, "two helmets")
		unchanged(w, creative(CURSOR, HELMET, 2), true, "two helmets on the cursor")
		unchanged(w, creative(inv(w, 1), DIRT, 65), true, "65 dirt")
		unchanged(w, creative(inv(w, 1), UNKNOWN, 1), true, "unknown item")
		unchanged(w, creative(CURSOR, UNKNOWN, 1), true, "unknown item on the cursor")
		unchanged(w, creative(inv(w, 1), DIRT, -1), true, "negative count")
		unchanged(w, creative(inv(w, 1), DIRT, 1.5), true, "fractional count")
		unchanged(w, creative(40, DIRT, 1), true, "out of range")
		unchanged(w, creative(-2, DIRT, 1), true, "negative slot")
		unchanged(w, creative(OUTSIDE, DIRT, 1), true, "outside")
		unchanged(w, { kind = "creative", window = 3, slot = 0, item = HELMET, count = 1 }, true, "wrong window")

		local c = newWindow(27)
		Menu.apply(c, { kind = "creative", window = 1, slot = con(c, 27), item = DIRT, count = 64 }, true)
		is(c.container.slots[27], DIRT, 64, "container slot")
	end)

	--[[ close ]]

	t.test("close: the carried stack goes back into the inventory", function()
		local w = newWindow()
		w.inventory.selected = 1
		w.inventory.slots[1] = S(DIRT, 60)
		w.inventory.slots[20] = S(DIRT, 30)
		w.inventory.cursor = S(DIRT, 10)
		local thrown = Menu.apply(w, { kind = "close", window = 0 }, false)
		t.eq(#thrown, 0)
		t.eq(w.inventory.cursor, nil)
		is(w.inventory.slots[1], DIRT, 64, "selected slot first")
		is(w.inventory.slots[20], DIRT, 36, "then slot 20")

		fillInventory(w, STONE)
		w.inventory.cursor = S(DIRT, 10)
		thrown = Menu.apply(w, { kind = "close", window = 0 }, false)
		is(thrown[1], DIRT, 10, "a full inventory throws it")
		t.eq(w.inventory.cursor, nil)

		w.inventory.cursor = S(DIRT, 10)
		unchanged(w, { kind = "close", window = 2 }, false, "another window")

		-- In a container window; the caller resets the window afterwards.
		local c = newWindow(27)
		c.container.slots[1] = S(STONE, 1)
		c.inventory.cursor = S(DIRT, 3)
		thrown = Menu.apply(c, { kind = "close", window = 1 }, false)
		t.eq(#thrown, 0)
		is(c.inventory.slots[1], DIRT, 3, "back in the hotbar")
		t.ok(c.container ~= nil, "the container is the caller's business")

		-- Menu.close directly.
		local d = newWindow()
		d.inventory.cursor = S(PLANKS, 5)
		t.eq(#Menu.close(d), 0)
		is(d.inventory.slots[1], PLANKS, 5, "Menu.close")
		t.eq(#Menu.close(d), 0, "nothing carried")
	end)

	--[[ add ]]

	t.test("add: the selected slot first, then same-item slots, then the first empty slot", function()
		local inventory = Types.newInventory()
		inventory.selected = 3
		inventory.slots[1] = S(DIRT, 10)
		inventory.slots[3] = S(DIRT, 10)
		t.eq(Menu.add(inventory, S(DIRT, 5)), nil, "all fitted")
		is(inventory.slots[3], DIRT, 15, "selected")
		is(inventory.slots[1], DIRT, 10, "not hotbar 1")

		inventory.slots[3] = S(DIRT, 64)
		Menu.add(inventory, S(DIRT, 5))
		is(inventory.slots[1], DIRT, 15, "selected full: first same-item slot")

		inventory.slots[3] = S(STONE, 1)
		inventory.slots[1] = nil
		inventory.slots[25] = S(DIRT, 1)
		Menu.add(inventory, S(DIRT, 5))
		is(inventory.slots[25], DIRT, 6, "same item beats an empty hotbar slot")
		t.eq(inventory.slots[1], nil)

		Menu.add(inventory, S(PLANKS, 5))
		is(inventory.slots[1], PLANKS, 5, "first empty slot (the hotbar first)")

		-- Spilling over.
		inventory = Types.newInventory()
		inventory.slots[1] = S(DIRT, 60)
		inventory.slots[2] = S(STONE, 1)
		inventory.slots[30] = S(DIRT, 62)
		Menu.add(inventory, S(DIRT, 64))
		is(inventory.slots[1], DIRT, 64, "first")
		is(inventory.slots[30], DIRT, 64, "second")
		is(inventory.slots[3], DIRT, 58, "then an empty slot")
	end)

	t.test("add: armor does not stack, leftovers come back, the stack is not changed", function()
		local inventory = Types.newInventory()
		inventory.slots[1] = S(HELMET, 1)
		local stack = S(HELMET, 1)
		t.eq(Menu.add(inventory, stack), nil)
		is(inventory.slots[2], HELMET, 1, "next empty slot")
		t.ok(inventory.slots[2] ~= stack, "copied in")

		inventory = Types.newInventory()
		for i = 1, 36 do
			inventory.slots[i] = S(STONE, 64)
		end
		inventory.slots[5] = S(DIRT, 60)
		stack = S(DIRT, 10)
		local left = Menu.add(inventory, stack)
		is(left, DIRT, 6, "leftover")
		is(stack, DIRT, 10, "argument untouched")
		is(inventory.slots[5], DIRT, 64, "filled")
		left = Menu.add(inventory, stack)
		is(left, DIRT, 10, "nothing fits")
		t.ok(left ~= stack, "a new table")

		t.eq(Menu.add(Types.newInventory(), S(DIRT, 0)), nil, "nothing to add")
		local empty = Types.newInventory()
		is(Menu.add(empty, S(UNKNOWN, 3)), UNKNOWN, 3, "unknown items don't go in")
		t.eq(empty.slots[1], nil)
	end)

	--[[ clear / copies ]]

	t.test("clear: everything comes out (death drops)", function()
		local inventory = Types.newInventory()
		inventory.slots[1] = S(DIRT, 10)
		inventory.slots[36] = S(STONE, 3)
		inventory.armor[2] = S(CHESTPLATE, 1)
		inventory.cursor = S(PLANKS, 7)
		local stacks = Menu.clear(inventory)
		t.eq(#stacks, 4)
		local sums = {}
		for _, stack in stacks do
			sums[stack.item] = (sums[stack.item] or 0) + stack.count
		end
		t.eq(sums[DIRT], 10)
		t.eq(sums[STONE], 3)
		t.eq(sums[CHESTPLATE], 1)
		t.eq(sums[PLANKS], 7)
		t.eq(inventory.slots[1], nil)
		t.eq(inventory.slots[36], nil)
		t.eq(inventory.armor[2], nil)
		t.eq(inventory.cursor, nil)
		t.eq(#Menu.clear(inventory), 0)
	end)

	t.test("copies are deep", function()
		local c = newWindow(9)
		c.container.slots[2] = S(DIRT, 5)
		c.inventory.slots[3] = S(STONE, 6)
		c.inventory.armor[1] = S(HELMET, 1)
		c.inventory.cursor = S(PLANKS, 2)
		c.inventory.selected = 4
		local copy = Menu.copyWindow(c)
		t.eq(dump(copy), dump(c))
		t.ok(copy.container ~= c.container and copy.container.slots[2] ~= c.container.slots[2])
		t.ok(copy.inventory ~= c.inventory and copy.inventory.slots[3] ~= c.inventory.slots[3])
		t.ok(copy.inventory.armor[1] ~= c.inventory.armor[1])
		t.ok(copy.inventory.cursor ~= c.inventory.cursor)
		copy.container.slots[2].count = 1
		copy.inventory.slots[3].count = 1
		copy.inventory.selected = 9
		is(c.container.slots[2], DIRT, 5, "original container")
		is(c.inventory.slots[3], STONE, 6, "original inventory")
		t.eq(c.inventory.selected, 4)

		local inventory = Menu.copyInventory(c.inventory)
		t.ok(inventory.slots[3] ~= c.inventory.slots[3])
		is(inventory.slots[3], STONE, 6, "copyInventory")
		is(inventory.cursor, PLANKS, 2, "copyInventory cursor")
		t.eq(Menu.copyWindow(newWindow()).container, nil)
	end)

	t.test("apply never shares a table between two slots or changes old stacks", function()
		local w = newWindow()
		local held = S(DIRT, 64)
		w.inventory.cursor = held
		drag(w, Drag.Split, { inv(w, 10), inv(w, 11) })
		is(held, DIRT, 64, "the old cursor table is untouched")
		t.ok(w.inventory.slots[10] ~= w.inventory.slots[11])
		local slotTable = w.inventory.slots[10]
		click(w, inv(w, 10), Click.Pickup, 1)
		is(slotTable, DIRT, 32, "the old slot table is untouched")
	end)

	--[[ pick block ]]

	local function applyAll(window, actions, creative)
		for _, action in actions do
			local before = dump(window)
			Menu.apply(window, action, creative)
			t.ok(dump(window) ~= before or action.kind == "select", `{action.kind} action did something`)
		end
	end

	t.test("pick block (survival): select it in the hotbar, or swap it in", function()
		local inventory = Types.newInventory()
		inventory.slots[4] = S(DIRT, 3)
		inventory.slots[20] = S(DIRT, 9)
		local actions = Menu.pickBlock(inventory, DIRT, false)
		t.eq(#actions, 1)
		t.eq(actions[1].kind, "select")
		t.eq(actions[1].slot, 4)

		-- In slots 10..36: swap into the first empty hotbar slot from the selected one.
		inventory = Types.newInventory()
		inventory.selected = 1
		inventory.slots[1] = S(STONE, 1)
		inventory.slots[20] = S(DIRT, 9)
		actions = Menu.pickBlock(inventory, DIRT, false)
		t.eq(#actions, 2)
		t.eq(actions[1].kind, "click")
		t.eq(actions[1].window, 0)
		t.eq(actions[1].clickType, Click.Swap)
		t.eq(actions[1].button, 1)
		t.eq(actions[1].slot, 14, "window slot of inventory slot 20")
		t.eq(actions[2].kind, "select")
		t.eq(actions[2].slot, 2)
		local w = { id = 0, inventory = inventory, container = nil }
		applyAll(w, actions, false)
		is(inventory.slots[2], DIRT, 9, "in hotbar 2")
		t.eq(inventory.slots[20], nil)
		t.eq(inventory.selected, 2)

		-- Wraps around from the selected slot.
		inventory = Types.newInventory()
		inventory.selected = 8
		inventory.slots[8] = S(STONE, 1)
		inventory.slots[9] = S(STONE, 1)
		inventory.slots[1] = S(STONE, 1)
		inventory.slots[30] = S(DIRT, 9)
		actions = Menu.pickBlock(inventory, DIRT, false)
		t.eq(actions[#actions].slot, 2, "8 -> 9 -> 1 -> 2")

		-- Full hotbar: exchanged with the selected slot.
		inventory = Types.newInventory()
		for i = 1, 9 do
			inventory.slots[i] = S(STONE, i)
		end
		inventory.selected = 3
		inventory.slots[25] = S(DIRT, 9)
		w = { id = 0, inventory = inventory, container = nil }
		applyAll(w, Menu.pickBlock(inventory, DIRT, false), false)
		is(inventory.slots[3], DIRT, 9, "into the selected slot")
		is(inventory.slots[25], STONE, 3, "the old stack where the dirt was")
		t.eq(inventory.selected, 3)

		-- Not there: nothing.
		t.eq(#Menu.pickBlock(Types.newInventory(), DIRT, false), 0)
		t.eq(#Menu.pickBlock(Types.newInventory(), UNKNOWN, true), 0, "not an item")
	end)

	t.test("pick block (creative): a full stack when the inventory has none", function()
		local inventory = Types.newInventory()
		inventory.selected = 5
		inventory.slots[5] = S(STONE, 1)
		local actions = Menu.pickBlock(inventory, DIRT, true)
		t.eq(#actions, 2)
		t.eq(actions[1].kind, "creative")
		t.eq(actions[1].window, 0)
		t.eq(actions[1].count, 64)
		t.eq(actions[2].slot, 6)
		local w = { id = 0, inventory = inventory, container = nil }
		applyAll(w, actions, true)
		is(inventory.slots[6], DIRT, 64, "hotbar 6")
		t.eq(inventory.selected, 6)
		is(inventory.slots[5], STONE, 1, "untouched")

		-- Full hotbar: the selected stack moves to a free slot first (Inventory.setPickedItem).
		inventory = Types.newInventory()
		for i = 1, 9 do
			inventory.slots[i] = S(STONE, i)
		end
		inventory.slots[10] = S(PLANKS, 1)
		inventory.selected = 4
		w = { id = 0, inventory = inventory, container = nil }
		actions = Menu.pickBlock(inventory, HELMET, true)
		t.eq(#actions, 3)
		applyAll(w, actions, true)
		is(inventory.slots[4], HELMET, 1, "a full stack of helmets is one")
		is(inventory.slots[11], STONE, 4, "the old stack moved to the first free slot")
		t.eq(inventory.selected, 4)

		-- Everything full: the selected stack is replaced (creative).
		inventory = Types.newInventory()
		for i = 1, 36 do
			inventory.slots[i] = S(STONE, 64)
		end
		w = { id = 0, inventory = inventory, container = nil }
		applyAll(w, Menu.pickBlock(inventory, DIRT, true), true)
		is(inventory.slots[1], DIRT, 64, "replaced")

		-- In the inventory already: the same swap as survival.
		inventory = Types.newInventory()
		inventory.slots[15] = S(DIRT, 2)
		actions = Menu.pickBlock(inventory, DIRT, true)
		t.eq(actions[1].clickType, Click.Swap)
		w = { id = 0, inventory = inventory, container = nil }
		applyAll(w, actions, true)
		is(inventory.slots[1], DIRT, 2, "swapped, not a new stack")

		-- In the hotbar: just select.
		actions = Menu.pickBlock(inventory, DIRT, true)
		t.eq(#actions, 1)
		t.eq(actions[1].kind, "select")
	end)

	--[[ Invalid input ]]

	t.test("invalid actions change nothing and throw nothing", function()
		local w = newWindow()
		w.inventory.slots[1] = S(DIRT, 10)
		w.inventory.slots[10] = S(STONE, 10)
		w.inventory.armor[1] = S(HELMET, 1)
		w.inventory.cursor = S(DIRT, 5)
		local function c(slot, clickType, button, window)
			return { kind = "click", window = window or 0, slot = slot, clickType = clickType, button = button }
		end
		local cases = {
			{ c(inv(w, 1), Click.Pickup, 0, 1), "wrong window" },
			{ c(40, Click.Pickup, 0), "slot = size" },
			{ c(-2, Click.Pickup, 0), "slot -2" },
			{ c(CURSOR, Click.Pickup, 0), "slot -1" },
			{ c(1.5, Click.Pickup, 0), "fractional slot" },
			{ c(0 / 0, Click.Pickup, 0), "NaN slot" },
			{ c(math.huge, Click.Pickup, 0), "infinite slot" },
			{ c("1", Click.Pickup, 0), "string slot" },
			{ c(nil, Click.Pickup, 0), "no slot" },
			{ c(inv(w, 1), 6, 0), "click type 6" },
			{ c(inv(w, 1), -1, 0), "click type -1" },
			{ c(inv(w, 1), Click.Pickup, 2), "pickup button 2" },
			{ c(inv(w, 1), Click.QuickMove, 2), "quick move button 2" },
			{ c(OUTSIDE, Click.Pickup, 5), "outside button 5" },
			{ c(inv(w, 10), Click.Swap, 9), "swap button 9" },
			{ c(inv(w, 10), Click.Swap, -1), "swap button -1" },
			{ c(OUTSIDE, Click.Swap, 0), "swap outside" },
			{ c(OUTSIDE, Click.Throw, 0), "throw outside" },
			{ c(OUTSIDE, Click.PickupAll, 0), "pick up all outside" },
			{ c(inv(w, 20), Click.PickupAll, 2), "pick up all button 2" },
			{ c(inv(w, 1), Click.Clone, 2), "clone in survival" },
			{ { kind = "creative", window = 0, slot = CURSOR, item = STONE, count = 1 }, "creative in survival" },
			{ { kind = "drag", window = 0, mode = Drag.Clone, slots = { inv(w, 20), inv(w, 21) } }, "clone drag" },
			{ { kind = "select", slot = nil }, "select nothing" },
			{ { kind = "close", window = 7 }, "close another window" },
			{ { kind = "place", item = STONE }, "place what is not held" },
			{ { kind = "explode" }, "unknown kind" },
			{ {}, "empty table" },
		}
		for _, case in cases do
			unchanged(w, case[1], false, case[2])
		end
		unchanged(w, nil :: any, false, "nil action")
		unchanged(w, "click" :: any, true, "string action")

		-- The same window with a container: other ranges.
		local k = newWindow(27)
		k.container.slots[1] = S(DIRT, 3)
		k.inventory.cursor = S(DIRT, 5)
		unchanged(k, c(67, Click.Pickup, 0, 1), false, "container window: slot = size")
		unchanged(k, c(con(k, 1), Click.Pickup, 0, 0), false, "container window: window 0")
	end)

	--[[ Fuzz ]]

	-- Park-Miller: deterministic and exact in doubles.
	local seed = 20230612
	local function rand(n: number): number
		seed = (seed * 16807) % 2147483647
		return seed % n
	end

	local POOL = { DIRT, STONE, COBBLE, PLANKS, HELMET, CHESTPLATE, LEGGINGS, BOOTS, GOLD_HELMET }
	local ARMOR_OF = { HELMET, CHESTPLATE, LEGGINGS, BOOTS }

	local function randomWindow()
		local w = newWindow(if rand(2) == 0 then nil else 9 * (1 + rand(6)))
		local function stack()
			if rand(3) == 0 then
				return nil
			end
			local item = POOL[1 + rand(#POOL)]
			return S(item, 1 + rand(Items.maxStack(item)))
		end
		if w.container then
			for i = 1, w.container.size do
				w.container.slots[i] = stack()
			end
		end
		for i = 1, 36 do
			w.inventory.slots[i] = stack()
		end
		for i = 1, 4 do
			if rand(2) == 0 then
				w.inventory.armor[i] = S(ARMOR_OF[i], 1)
			end
		end
		w.inventory.cursor = stack()
		w.inventory.selected = 1 + rand(9)
		return w
	end

	local function randomSlot(w): any
		local r = rand(20)
		if r == 0 then
			return OUTSIDE
		elseif r == 1 then
			return Menu.size(w) + rand(5)
		elseif r == 2 then
			return -1 - rand(3)
		elseif r == 3 then
			return rand(65536) - 32768
		end
		return rand(Menu.size(w))
	end

	local function randomAction(w): any
		local r = rand(100)
		local window = if rand(10) == 0 then rand(3) else w.id
		if r < 50 then
			return {
				kind = "click",
				window = window,
				slot = randomSlot(w),
				clickType = rand(8),
				button = if rand(4) == 0 then rand(12) else rand(2),
			}
		elseif r < 65 then
			local slots = {}
			for i = 1, rand(7) do
				slots[i] = if rand(15) == 0 then randomSlot(w) else rand(Menu.size(w))
			end
			return { kind = "drag", window = window, mode = rand(4), slots = slots }
		elseif r < 70 then
			return { kind = "select", slot = rand(11) }
		elseif r < 75 then
			return { kind = "drop", all = rand(2) == 0 }
		elseif r < 80 then
			return { kind = "place", item = POOL[1 + rand(#POOL)] }
		elseif r < 88 then
			local item = if rand(10) == 0 then rand(70000) else POOL[1 + rand(#POOL)]
			return {
				kind = "creative",
				window = window,
				slot = if rand(3) == 0 then CURSOR else randomSlot(w),
				item = item,
				count = rand(66),
			}
		elseif r < 93 then
			return { kind = "close", window = window }
		end
		-- Garbage.
		local junk = { "click", "drag", "select", "creative", "close", "drop", "place", "nope" }
		return {
			kind = junk[1 + rand(#junk)],
			window = if rand(2) == 0 then "0" else 0 / 0,
			slot = if rand(2) == 0 then 0.5 else nil,
			clickType = "x",
			button = {},
			mode = nil,
			slots = if rand(2) == 0 then { 0.25, "a" } else "slots",
			item = -1,
			count = 0 / 0,
			all = "yes",
		}
	end

	-- Every stored stack is valid where it is, and no table is stored twice.
	local function checkInvariants(w, context: string)
		local seen = {}
		local function check(stack, where: string, max: number)
			if stack == nil then
				return
			end
			if seen[stack] then
				error(`{context}: {where} shares a table with {seen[stack]}`)
			end
			seen[stack] = where
			if not Items.isValid(stack.item) then
				error(`{context}: {where} holds unknown item {stack.item}`)
			end
			if stack.count ~= math.floor(stack.count) or stack.count < 1 or stack.count > max then
				error(`{context}: {where} holds {stack.count} of {stack.item} (max {max})`)
			end
		end
		for index = 0, Menu.size(w) - 1 do
			local store, i = Menu.locate(w, index)
			local raw = if store == "container"
				then w.container.slots[i]
				elseif store == "armor" then w.inventory.armor[i]
				else w.inventory.slots[i]
			if raw then
				check(raw, `slot {index}`, Menu.maxStackFor(w, index, raw.item))
				if store == "armor" and Items.armorSlot(raw.item) ~= i then
					error(`{context}: armor slot {i} holds {raw.item}`)
				end
			end
		end
		local cursor = w.inventory.cursor
		if cursor then
			check(cursor, "cursor", Items.maxStack(cursor.item))
		end
		local selected = w.inventory.selected
		if selected < 1 or selected > 9 or selected ~= math.floor(selected) then
			error(`{context}: selected {selected}`)
		end
	end

	t.test("fuzz (survival): counts are conserved, nothing errors, invariants hold", function()
		local applied = 0
		for round = 1, 150 do
			local w = randomWindow()
			for step = 1, 60 do
				local action = randomAction(w)
				local before = totals(w)
				local selected = w.inventory.slots[w.inventory.selected]
				local text = dump(w)
				local ok, thrown = pcall(Menu.apply, w, action, false)
				if not ok then
					error(`round {round} step {step}: {thrown}\n  state {text}`)
				end
				local after = totals(w, thrown)
				if type(action) == "table" and action.kind == "place" and selected and selected.item == action.item then
					-- Placing uses one up.
					after[action.item] = (after[action.item] or 0) + 1
				end
				local same, why = sameTotals(before, after)
				if not same then
					error(`round {round} step {step} ({action.kind}): {why}\n  state {text}`)
				end
				for _, stack in thrown do
					t.ok(stack.count >= 1 and Items.isValid(stack.item), "thrown stacks are real")
				end
				checkInvariants(w, `round {round} step {step} ({action.kind})`)
				applied += 1
			end
		end
		t.eq(applied, 150 * 60)
	end)

	t.test("fuzz (creative): nothing errors, invariants hold", function()
		for round = 1, 150 do
			local w = randomWindow()
			for step = 1, 60 do
				local action = randomAction(w)
				local text = dump(w)
				local ok, err = pcall(Menu.apply, w, action, true)
				if not ok then
					error(`round {round} step {step}: {err}\n  state {text}`)
				end
				checkInvariants(w, `round {round} step {step} ({action.kind})`)
			end
		end
	end)

	t.test("fuzz: decoded network actions never make apply error", function()
		local buffers = 0
		for round = 1, 3000 do
			-- Mostly the right length for a random kind (so most decode), sometimes any length.
			local kind = 1 + rand(6)
			local count = rand(8)
			local lengths = { 10, 8 + count * 2, 6, 6, 11, 6 }
			local length = if rand(5) == 0 then 4 + rand(20) else lengths[kind]
			local b = buffer.create(length)
			for i = 0, length - 1 do
				buffer.writeu8(b, i, rand(256))
			end
			if length > 7 and rand(5) ~= 0 then
				buffer.writeu8(b, 4, kind)
				if kind == 2 then
					buffer.writeu8(b, 7, count)
				end
			end
			local okDecode, seq, action = pcall(Protocol.decodeInventoryAction, b)
			t.ok(okDecode, "decode never errors")
			if seq ~= nil and action ~= nil then
				buffers += 1
				local w = randomWindow()
				local ok, err = pcall(Menu.apply, w, action, rand(2) == 0)
				if not ok then
					error(`apply errored on a decoded {action.kind}: {err}`)
				end
				checkInvariants(w, `decoded {action.kind}`)
			end
		end
		t.ok(buffers > 1000, `enough buffers decoded ({buffers})`)

		-- Actions whose fields fit the wire format apply the same after a round trip.
		local function byte(value): boolean
			return type(value) == "number" and value == math.floor(value) and value >= 0 and value < 256
		end
		local function fits(action): boolean
			if action.kind == "click" then
				return byte(action.window)
					and byte(action.clickType)
					and byte(action.button)
					and type(action.slot) == "number"
					and action.slot == math.floor(action.slot)
					and action.slot >= -32768
					and action.slot < 32768
			elseif action.kind == "select" then
				return byte(action.slot)
			elseif action.kind == "drop" then
				return type(action.all) == "boolean"
			elseif action.kind == "close" then
				return byte(action.window)
			end
			return false
		end
		local compared = 0
		for _ = 1, 600 do
			local w = randomWindow()
			local action = randomAction(w)
			if fits(action) then
				local _, decoded = Protocol.decodeInventoryAction(Protocol.encodeInventoryAction(7, action))
				local copy = Menu.copyWindow(w)
				local thrownA = Menu.apply(w, action, false)
				local thrownB = Menu.apply(copy, decoded, false)
				t.eq(dump(copy), dump(w), `{action.kind} round trip`)
				t.eq(#thrownB, #thrownA, `{action.kind} round trip throws`)
				compared += 1
			end
		end
		t.ok(compared > 200, `enough round trips ({compared})`)
	end)

	t.test("prediction: replaying the same actions on a copy gives the same state", function()
		for _ = 1, 40 do
			local server = randomWindow()
			local client = Menu.copyWindow(server)
			local creative = rand(2) == 0
			for _ = 1, 50 do
				local action = randomAction(server)
				local thrownServer = Menu.apply(server, action, creative)
				local thrownClient = Menu.apply(client, action, creative)
				t.eq(dump(client), dump(server), "same state")
				t.eq(#thrownClient, #thrownServer, "same throws")
			end
		end
	end)
end

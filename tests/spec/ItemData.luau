--[[
	Item data (Minecraft's item NBT, flat; Items `data`): validation, matching and merging, menu
	clicks and crafting keeping it, the protocol (stacks with and without data, creative stacks,
	f64 container data, malformed buffers), item entities, transporters' sided inventories,
	tooltips and their formatting, JEI's transfer, and Mekanism's sustained data: a Fluid Tank
	broken with water drops an item that puts the water back when placed (TransmitterWorld's hooks
	through ServerNet's EditRules registry, InventoryState, item entities and snapshots).
]]

return function(t, shared, require, server, client)
	local Blocks = require(shared.Blocks)
	local Coords = require(shared.World.Coords)
	local Crafting = require(shared.Crafting)
	local Items = require(shared.Items)
	local Menu = require(shared.Inventory.Menu)
	local Protocol = require(shared.Net.Protocol)
	local Transmitters = require(shared.Transmitters)
	local Types = require(shared.Inventory.Types)
	local Containers = require(server.Players.Containers)
	local EditRules = require(server.Network.EditRules)
	local EntityWorld = require(server.Entities.EntityWorld)
	local InventoryState = require(server.Players.InventoryState)
	local TransmitterWorld = require(server.Transmitters.TransmitterWorld)
	local UseRules = require(server.Transmitters.UseRules)
	local Prediction = require(client.Inventory.Prediction)
	local SlotClicks = require(client.Ui.SlotClicks)
	local JeiTransfer = require(client.Ui.Jei.JeiTransfer)

	local B, I = Blocks.id, Items.id
	local AIR = Blocks.AIR
	local TANK, TANK2 = B.BasicFluidTank, B.AdvancedFluidTank
	local DIRT, STICK, PLANKS, PICKAXE = I.Dirt, I.Stick, I.Planks, I.IronPickaxe
	local WATER = Transmitters.FLUIDS.WATER
	local Click = Menu.ClickType
	local Y = 10

	local function S(item: number, count: number, data: any?, damage: number?)
		return { item = item, count = count, damage = damage, data = if data then Items.cleanData(data) else nil }
	end

	local function water(amount: number)
		return Items.cleanData({ fluid = WATER, amount = amount })
	end

	local function is(stack, item: number?, count: number?, amount: number?, what: string)
		if item == nil then
			t.ok(stack == nil, `{what}: expected empty`)
			return
		end
		t.ok(stack ~= nil, `{what}: expected a stack, got empty`)
		t.eq(stack.item, item, `{what} item`)
		t.eq(stack.count, count, `{what} count`)
		local got = if stack.data then stack.data.amount else nil
		t.eq(got, amount, `{what} water`)
	end

	local function inv(window, i: number): number
		return Menu.windowIndex(window, "inventory", i)
	end

	local function window(slots: { [number]: any }?)
		local w = Types.newWindow(Types.newInventory())
		for slot, stack in slots or {} do
			w.inventory.slots[slot] = stack
		end
		return w
	end

	local function click(w, slot: number, clickType: number, button: number, creative: boolean?)
		return Menu.apply(
			w,
			{ kind = "click", window = w.id, slot = slot, clickType = clickType, button = button },
			creative == true
		)
	end

	--[[ Validation ]]

	t.test("item data: validation (keys, values, sizes; no data is nil, never empty)", function()
		t.ok(Items.validData(nil), "no data")
		t.ok(Items.validData({ fluid = 1, amount = 12000 }), "numbers")
		t.ok(Items.validData({ name = "Steve", locked = true, energy_2 = -1.5 }), "strings, booleans, signs")
		t.ok(not Items.validData({}), "empty data is nil, not a table")
		t.ok(not Items.validData(5), "a number")
		t.ok(not Items.validData("x"), "a string")
		t.ok(not Items.validData({ 1, 2 }), "array keys")
		t.ok(not Items.validData({ [""] = 1 }), "empty key")
		t.ok(not Items.validData({ ["a b"] = 1 }), "a space")
		t.ok(not Items.validData({ ["é"] = 1 }), "not ASCII")
		t.ok(not Items.validData({ ["a.b"] = 1 }), "punctuation")
		t.ok(Items.validData({ [string.rep("k", 32)] = 1 }), "32 characters")
		t.ok(not Items.validData({ [string.rep("k", 33)] = 1 }), "33 characters")
		t.ok(Items.validData({ s = string.rep("x", 64) }), "64 byte string")
		t.ok(not Items.validData({ s = string.rep("x", 65) }), "65 byte string")
		t.ok(not Items.validData({ n = 0 / 0 }), "NaN")
		t.ok(not Items.validData({ n = math.huge }), "infinity")
		t.ok(not Items.validData({ n = -math.huge }), "-infinity")
		t.ok(not Items.validData({ t = {} }), "nesting")
		t.ok(not Items.validData({ f = print }), "a function")
		local sixteen, seventeen = {}, {}
		for i = 1, 17 do
			seventeen[`k{i}`] = i
			if i <= 16 then
				sixteen[`k{i}`] = i
			end
		end
		t.ok(Items.validData(sixteen), "16 keys")
		t.ok(not Items.validData(seventeen), "17 keys")
	end)

	t.test("item data: cleanData makes frozen copies, sameData and dataKey compare it", function()
		local raw = { amount = 5, fluid = 1 }
		local clean = Items.cleanData(raw)
		assert(clean)
		t.ok(clean ~= raw, "a copy")
		t.ok(table.isfrozen(clean), "frozen")
		t.ok(not table.isfrozen(raw), "the input is left alone")
		t.eq(Items.cleanData(clean), clean, "a clean table is kept")
		t.eq(Items.cleanData({}), nil, "empty")
		t.eq(Items.cleanData({ bad = 0 / 0 }), nil, "invalid")
		t.eq(Items.cleanData(nil), nil)
		t.ok(Items.sameData(nil, nil))
		t.ok(Items.sameData(clean, { fluid = 1, amount = 5 }), "same keys and values, any order")
		t.ok(not Items.sameData(clean, nil))
		t.ok(not Items.sameData(nil, clean))
		t.ok(not Items.sameData(clean, { fluid = 1, amount = 6 }), "another value")
		t.ok(not Items.sameData(clean, { fluid = 1 }), "a key fewer")
		t.ok(not Items.sameData(clean, { fluid = 1, amount = 5, more = true }), "a key more")
		t.ok(not Items.sameData({ a = 1 }, { a = "1" }), "a number is no string")
		t.eq(Items.dataNumber(clean, "amount"), 5)
		t.eq(Items.dataNumber(clean, "missing"), nil)
		t.eq(Items.dataNumber({ s = "5" }, "s"), nil, "a string is no number")
		t.eq(Items.dataNumber(nil, "amount"), nil)
		t.eq(Items.dataKey(nil), "")
		t.eq(Items.dataKey({ fluid = 1, amount = 5 }), Items.dataKey({ amount = 5, fluid = 1 }), "order free")
		t.ok(Items.dataKey({ a = 1 }) ~= Items.dataKey({ a = "1" }), "types differ")
		t.ok(Items.dataKey({ a = true }) ~= Items.dataKey({ a = "true" }), "booleans differ from strings")
		t.ok(Items.dataKey({ a = 0.1 }) ~= Items.dataKey({ a = 0.10000000000000002 }), "every bit of a number")
		-- Equal data (sameData) always has the same key: -0 is 0.
		t.ok(Items.sameData({ a = -0 }, { a = 0 }))
		t.eq(Items.dataKey({ a = -0 }), Items.dataKey({ a = 0 }), "-0 and 0 alike")
	end)

	t.test("item data: stack helpers keep wear and data, stacksMatch compares all three", function()
		local tank = S(TANK, 3, { fluid = 1, amount = 500 })
		local copy = Items.copyStack(tank) :: any
		t.ok(copy ~= tank, "a new table")
		t.eq(copy.data, tank.data, "the same (frozen) data")
		local two = Items.withCount(tank, 2) :: any
		t.eq(two.count, 2)
		t.eq(two.data.amount, 500)
		t.eq(Items.withCount(tank, 0), nil, "none left")
		local worn = Items.newStack(PICKAXE, 1, 17, nil) :: any
		t.eq(worn.damage, 17)
		t.eq((Items.newStack(PICKAXE, 1, 0.5) :: any).damage, nil, "junk wear reads as new")
		local plain = Items.withData(tank, nil)
		t.eq(plain.data, nil, "data cleared")
		t.eq(Items.withData(tank, {}).data, nil, "empty data is none")
		t.eq(Items.withData(tank, { amount = 0 / 0 }).data, nil, "invalid data is none")
		t.ok(Items.stacksMatch(tank, S(TANK, 64, { amount = 500, fluid = 1 })), "counts do not matter")
		t.ok(not Items.stacksMatch(tank, S(TANK, 3)), "data against none")
		t.ok(not Items.stacksMatch(tank, S(TANK, 3, { fluid = 1, amount = 501 })), "other data")
		t.ok(not Items.stacksMatch(S(PICKAXE, 1, nil, 3), S(PICKAXE, 1)), "other wear")
		t.ok(Menu.stacksMatch(tank, S(TANK, 1, { fluid = 1, amount = 500 })), "Menu agrees")
	end)

	--[[ Menus ]]

	t.test("menus: stacks with different data never merge, clicks keep data", function()
		local full, empty = water(1000), nil
		local w = window({ [10] = S(TANK, 1, full), [11] = S(TANK, 1, empty) })
		-- Pick up the tank with water and click the empty one: they swap instead of stacking.
		click(w, inv(w, 10), Click.Pickup, 0)
		is(w.inventory.cursor, TANK, 1, 1000, "picked up with its water")
		click(w, inv(w, 11), Click.Pickup, 0)
		is(w.inventory.slots[11], TANK, 1, 1000, "swapped in")
		is(w.inventory.cursor, TANK, 1, nil, "the empty one on the cursor")
		-- Put the empty one down, then stack an equal tank onto the full one.
		click(w, inv(w, 10), Click.Pickup, 0)
		w.inventory.cursor = S(TANK, 2, full)
		click(w, inv(w, 11), Click.Pickup, 0)
		is(w.inventory.slots[11], TANK, 3, 1000, "equal data stacks")
		t.eq(w.inventory.cursor, nil)
		-- Right click takes half, which keeps the data; right click puts one back.
		click(w, inv(w, 11), Click.Pickup, 1)
		is(w.inventory.cursor, TANK, 2, 1000, "half (rounded up)")
		is(w.inventory.slots[11], TANK, 1, 1000, "the rest")
		click(w, inv(w, 12), Click.Pickup, 1)
		is(w.inventory.slots[12], TANK, 1, 1000, "one put down")
		-- A drag spreads it with its data, and never onto the empty tank.
		local dragged =
			Menu.apply(w, { kind = "drag", window = 0, mode = 1, slots = { inv(w, 10), inv(w, 13) } }, false)
		t.eq(#dragged, 0)
		is(w.inventory.slots[10], TANK, 1, nil, "the empty tank is skipped")
		is(w.inventory.slots[13], TANK, 1, 1000, "one dragged")
		t.eq(w.inventory.cursor, nil, "all placed")
		-- Throws keep the data.
		local thrown = click(w, inv(w, 13), Click.Throw, 0)
		is(thrown[1], TANK, 1, 1000, "thrown one")
		-- Number key swap keeps it.
		click(w, inv(w, 11), Click.Swap, 0)
		is(w.inventory.slots[1], TANK, 1, 1000, "swapped into the hotbar")
		-- Q keeps it.
		w.inventory.selected = 1
		local dropped = Menu.apply(w, { kind = "drop", all = false }, false)
		is(dropped[1], TANK, 1, 1000, "dropped with Q")
	end)

	t.test("menus: shift-click, Inventory.add and double click respect data", function()
		local full = water(4000)
		local w = window({
			[1] = S(TANK, 1, nil),
			[2] = S(TANK, 5, full),
			[20] = S(TANK, 3, full),
		})
		-- Inventory.add: onto the stack with the same data, not the selected empty one.
		w.inventory.selected = 1
		local left = Menu.add(w.inventory, S(TANK, 2, full))
		t.eq(left, nil)
		is(w.inventory.slots[1], TANK, 1, nil, "the empty tank stays as it was")
		is(w.inventory.slots[2], TANK, 7, 4000, "merged into the same data")
		local leftEmpty = Menu.add(w.inventory, S(TANK, 1, nil))
		t.eq(leftEmpty, nil)
		is(w.inventory.slots[1], TANK, 2, nil, "an empty one onto the empty one")
		-- Shift-click 10..36 -> hotbar: merges into the same data only.
		click(w, inv(w, 20), Click.QuickMove, 0)
		is(w.inventory.slots[2], TANK, 10, 4000, "moved onto its own kind")
		is(w.inventory.slots[1], TANK, 2, nil, "not onto the empty tanks")
		t.eq(w.inventory.slots[20], nil)
		-- Double click gathers only the same data.
		w.inventory.cursor = S(TANK, 1, full)
		w.inventory.slots[30] = S(TANK, 4, full)
		click(w, inv(w, 31), Click.PickupAll, 0)
		is(w.inventory.cursor, TANK, 15, 4000, "gathered its own kind")
		is(w.inventory.slots[1], TANK, 2, nil, "the empty tanks stay")
	end)

	t.test("menus: middle click clones data, creative stacks carry valid data and wear only", function()
		local w = window({ [10] = S(TANK, 1, water(250)) })
		click(w, inv(w, 10), Click.Clone, 0, true)
		is(w.inventory.cursor, TANK, 64, 250, "a full stack with the data (creative)")
		local survival = window({ [10] = S(TANK, 1, water(250)) })
		click(survival, inv(survival, 10), Click.Clone, 0, false)
		t.eq(survival.inventory.cursor, nil, "not in survival")

		local c = window()
		local function creative(action)
			action.kind = "creative"
			action.window = 0
			Menu.apply(c, action, true)
		end
		creative({ slot = Types.CURSOR, item = TANK, count = 2, data = { fluid = 1, amount = 7 } })
		is(c.inventory.cursor, TANK, 2, 7, "a creative stack with data")
		t.ok(table.isfrozen(c.inventory.cursor.data), "stored clean")
		creative({ slot = inv(c, 3), item = PICKAXE, count = 1, damage = 100 })
		t.eq(c.inventory.slots[3].damage, 100, "creative wear")
		creative({ slot = inv(c, 4), item = PICKAXE, count = 1, damage = 250 })
		t.eq(c.inventory.slots[4], nil, "worn out is no stack")
		creative({ slot = inv(c, 4), item = DIRT, count = 1, damage = 3 })
		t.eq(c.inventory.slots[4], nil, "dirt does not wear")
		creative({ slot = inv(c, 4), item = DIRT, count = 1, data = { ["bad key"] = 1 } })
		t.eq(c.inventory.slots[4], nil, "invalid data refused")
		creative({ slot = inv(c, 4), item = DIRT, count = 1, data = {} })
		t.eq(c.inventory.slots[4], nil, "an empty table is no data (none is nil)")
		creative({ slot = inv(c, 4), item = DIRT, count = 1 })
		t.ok(c.inventory.slots[4] ~= nil and c.inventory.slots[4].data == nil, "no data")
		-- The creative grid's right click keeps the rest's data (SlotClicks).
		local host = {
			window = function()
				return c
			end,
			creative = function()
				return true
			end,
			apply = function(action)
				Menu.apply(c, action, true)
			end,
		}
		local clicks = SlotClicks.new(host)
		clicks:click({ kind = "grid", item = DIRT }, 1, false, 0)
		is(c.inventory.cursor, TANK, 1, 7, "one deleted, the water kept")
	end)

	t.test("menus: pick block takes plain stacks only (Minecraft's isSameItemSameTags)", function()
		local inventory = Types.newInventory()
		inventory.slots[2] = S(TANK, 1, water(500))
		inventory.slots[20] = S(TANK, 3)
		local actions = Menu.pickBlock(inventory, TANK, false)
		t.eq(#actions, 2, "the plain tanks are swapped in, the one with water is passed over")
		t.eq(actions[1].kind, "click")
		t.eq(actions[1].slot, inv(window(), 20))
		inventory.slots[20] = nil
		t.eq(#Menu.pickBlock(inventory, TANK, false), 0, "survival: only a tank with water, nothing")
		local creative = Menu.pickBlock(inventory, TANK, true)
		local last = creative[#creative - 1]
		t.eq(last.kind, "creative", "creative: a new plain stack")
		t.eq(last.data, nil)
		local w = Types.newWindow(inventory)
		for _, action in creative do
			Menu.apply(w, action, true)
		end
		is(inventory.slots[2], TANK, 1, 500, "the tank with water stays")
		is(inventory.slots[inventory.selected], TANK, 64, nil, "picked")
	end)

	t.test("furnaces: what is left of the input and fuel keeps its data", function()
		local Smelting = require(shared.Crafting.Smelting)
		local furnace = {
			kind = "furnace",
			block = B.Furnace,
			size = 3,
			slots = { [1] = S(I.RawIron, 3, { tag = "in" }), [2] = S(I.Coal, 2, { tag = "fuel" }) },
			data = Smelting.newData(),
		}
		for _ = 1, Smelting.COOK_TIME + 1 do
			Smelting.tick(furnace)
		end
		local input, fuel, output = furnace.slots[1], furnace.slots[2], furnace.slots[3]
		t.eq(input.count, 2)
		t.eq(input.data.tag, "in", "the input left")
		t.eq(fuel.count, 1)
		t.eq(fuel.data.tag, "fuel", "the fuel left")
		t.eq(output.item, I.IronIngot)
		t.eq(output.data, nil, "results carry no data")
	end)

	t.test("crafting: results carry no data, the grid keeps its data", function()
		-- A Basic Fluid Tank with water upgraded: the result is a fresh Advanced tank (no data).
		local window = Types.newWindow(Types.newInventory())
		window.id = 1
		window.container = Types.newCrafting("crafting", B.CraftingTable)
		local recipe = nil
		for _, candidate in Crafting.recipes do
			if candidate.result == TANK2 then
				recipe = candidate
			end
		end
		assert(recipe, "the Advanced Fluid Tank's recipe")
		local cells = recipe.cells
		for i, cell in cells do
			if cell then
				local item = next(cell) :: number
				local slot = Types.CRAFT_RESULT + i
				window.container.slots[slot] = if item == TANK then S(TANK, 2, water(9000)) else S(item, 2)
			end
		end
		Menu.updateCraft(window)
		local result = window.container.slots[Types.CRAFT_RESULT]
		assert(result, "the recipe matches whatever the tank holds")
		t.eq(result.item, TANK2)
		t.eq(result.data, nil, "no data on the result")
		click(window, Types.CRAFT_RESULT - 1, Click.Pickup, 0)
		t.eq(window.inventory.cursor.item, TANK2)
		local kept = 0
		for _, stack in window.container.slots do
			if stack and stack.item == TANK then
				kept += 1
				t.eq(stack.count, 1)
				t.eq(stack.data.amount, 9000, "the tank left in the grid keeps its water")
			end
		end
		t.eq(kept, 1)
		-- Repairing tools gives a fresh stack.
		local repaired = Crafting.match({ S(PICKAXE, 1, { owner = "a" }, 200), S(PICKAXE, 1, nil, 200) }, 2)
		assert(repaired)
		t.eq(repaired.data, nil, "repair drops data")
		-- consume keeps wear and data.
		local after = Crafting.consume({ S(STICK, 3, { tag = "x" }) }, 2)
		t.eq(after[1].count, 2)
		t.eq(after[1].data.tag, "x")
	end)

	--[[ Protocol ]]

	t.test("protocol: snapshots round trip stacks with and without data", function()
		local inventory = Types.newInventory()
		inventory.selected = 3
		inventory.slots[1] = S(TANK, 2, { fluid = 1, amount = 12000 })
		inventory.slots[2] = S(DIRT, 64)
		inventory.slots[36] = S(PICKAXE, 1, { name = "Digger", fast = true, bonus = -0.25 }, 17)
		inventory.armor[1] = S(I.IronHelmet, 1)
		inventory.cursor = S(STICK, 5, { k = "" })
		local snapshot = Protocol.decodeInventory(
			Protocol.encodeInventory({ ack = 5, inventory = inventory, window = 0, container = nil })
		)
		assert(snapshot)
		t.eq(snapshot.ack, 5)
		t.eq(snapshot.inventory.selected, 3)
		is(snapshot.inventory.slots[1], TANK, 2, 12000, "tank")
		t.eq(snapshot.inventory.slots[1].data.fluid, 1)
		t.ok(table.isfrozen(snapshot.inventory.slots[1].data), "decoded data is frozen")
		is(snapshot.inventory.slots[2], DIRT, 64, nil, "dirt")
		t.eq(snapshot.inventory.slots[2].data, nil, "no data stays none")
		local tool = snapshot.inventory.slots[36]
		t.eq(tool.damage, 17)
		t.eq(tool.data.name, "Digger")
		t.eq(tool.data.fast, true)
		t.eq(tool.data.bonus, -0.25)
		t.eq(snapshot.inventory.armor[1].item, I.IronHelmet)
		t.eq(snapshot.inventory.cursor.data.k, "", "an empty string")
		t.eq(snapshot.inventory.slots[3], nil)
		t.eq(snapshot.container, nil)
		-- Equal data encodes alike, whatever order its keys were made in.
		local a = Protocol.encodeInventory({ ack = 1, inventory = inventory, window = 0, container = nil })
		inventory.slots[1] = S(TANK, 2, { amount = 12000, fluid = 1 })
		local b = Protocol.encodeInventory({ ack = 1, inventory = inventory, window = 0, container = nil })
		t.eq(buffer.tostring(a), buffer.tostring(b), "deterministic bytes")
	end)

	t.test("protocol: container data is f64 (energy beyond 16 bits), at most 16 values", function()
		local inventory = Types.newInventory()
		local values = {}
		for i = 1, 16 do
			values[i] = (i - 8) * 123456789.5
		end
		values[1] = 256000000
		values[2] = math.huge
		local machine = {
			kind = "chest",
			block = B.Chest,
			size = 27,
			slots = { [5] = S(TANK, 1, water(3)) },
			data = values,
		}
		local decoded = Protocol.decodeInventory(
			Protocol.encodeInventory({ ack = 9, inventory = inventory, window = 4, container = machine })
		)
		assert(decoded and decoded.container and decoded.container.data)
		t.eq(#decoded.container.data, 16)
		for i = 1, 16 do
			t.eq(decoded.container.data[i], values[i], `value {i}`)
		end
		is(decoded.container.slots[5], TANK, 1, 3, "container stacks keep data")
		-- A furnace's five values travel as they are (index 5 too); a chest's none.
		local furnace =
			{ kind = "furnace", block = B.Furnace, size = 3, slots = {}, data = { 1500, 1600, 120, 200, DIRT } }
		local hot = Protocol.decodeInventory(
			Protocol.encodeInventory({ ack = 1, inventory = inventory, window = 2, container = furnace })
		)
		assert(hot and hot.container and hot.container.data)
		t.eq(#hot.container.data, 5)
		t.eq(hot.container.data[5], DIRT)
		local chest = { kind = "chest", block = B.Chest, size = 27, slots = {} }
		local cold = Protocol.decodeInventory(
			Protocol.encodeInventory({ ack = 1, inventory = inventory, window = 2, container = chest })
		)
		assert(cold and cold.container)
		t.eq(cold.container.data, nil, "no data")
		-- More than 16 are cut, NaN is sent as 0 (the decoder refuses NaN).
		local many = table.clone(values)
		many[17] = 1
		many[3] = 0 / 0
		machine.data = many
		local cut = Protocol.decodeInventory(
			Protocol.encodeInventory({ ack = 1, inventory = inventory, window = 2, container = machine })
		)
		assert(cut and cut.container and cut.container.data)
		t.eq(#cut.container.data, 16)
		t.eq(cut.container.data[3], 0)
	end)

	t.test("protocol: a container of a kind the wire does not know travels as none", function()
		local inventory = Types.newInventory()
		inventory.slots[1] = S(TANK, 1, water(5))
		local unknown = {
			kind = "machine_from_the_future",
			block = B.Chest,
			size = 4,
			slots = { [1] = S(DIRT, 1) },
			data = { 1, 2, 3 },
		}
		local decoded = Protocol.decodeInventory(
			Protocol.encodeInventory({ ack = 3, inventory = inventory, window = 5, container = unknown } :: any)
		)
		assert(decoded, "still a snapshot")
		t.eq(decoded.container, nil)
		t.eq(decoded.window, 5)
		is(decoded.inventory.slots[1], TANK, 1, 5, "the inventory arrives")
	end)

	-- Offset of the container header (window byte) in a snapshot whose stacks are all empty.
	local HEADER = 5 + 41 * 3

	t.test("protocol: malformed snapshots decode to nil", function()
		local inventory = Types.newInventory()
		inventory.slots[1] = S(TANK, 1, { fluid = 1, amount = 5 })
		local good = Protocol.encodeInventory({ ack = 1, inventory = inventory, window = 0, container = nil })
		t.ok(Protocol.decodeInventory(good) ~= nil, "the good one decodes")
		local function patched(at: number, value: number, write: string?): buffer
			local b = buffer.create(buffer.len(good))
			buffer.copy(b, 0, good)
			if write == "f64" then
				buffer.writef64(b, at, value)
			else
				buffer.writeu8(b, at, value)
			end
			return b
		end
		local function truncated(n: number): buffer
			local b = buffer.create(n)
			buffer.copy(b, 0, good, 0, n)
			return b
		end
		for n = 0, buffer.len(good) - 1, 7 do
			t.eq(Protocol.decodeInventory(truncated(n)), nil, `cut to {n} bytes`)
		end
		local longer = buffer.create(buffer.len(good) + 1)
		buffer.copy(longer, 0, good)
		t.eq(Protocol.decodeInventory(longer), nil, "trailing bytes")
		t.eq(Protocol.decodeInventory(patched(4, 0)), nil, "selected slot 0")
		t.eq(Protocol.decodeInventory(patched(4, 10)), nil, "selected slot 10")
		-- Slot 1 (after armor, 4 x 3 bytes): u16 item, u8 count, u16 damage, then its data at 22.
		local dataAt = 5 + 4 * 3 + 5
		t.eq(buffer.readu8(good, dataAt), 2, "two entries")
		t.eq(Protocol.decodeInventory(patched(dataAt, 17)), nil, "17 entries")
		t.eq(Protocol.decodeInventory(patched(dataAt, 3)), nil, "more entries than there are")
		-- Entries sorted: "amount" first (key length 6), its type byte, its f64.
		t.eq(buffer.readu8(good, dataAt + 1), 6)
		t.eq(Protocol.decodeInventory(patched(dataAt + 1, 0)), nil, "an empty key")
		t.eq(Protocol.decodeInventory(patched(dataAt + 1, 40)), nil, "a key too long")
		t.eq(Protocol.decodeInventory(patched(dataAt + 2, string.byte(" "))), nil, "a space in the key")
		t.eq(Protocol.decodeInventory(patched(dataAt + 8, 3)), nil, "an unknown value type")
		t.eq(Protocol.decodeInventory(patched(dataAt + 9, 0 / 0, "f64")), nil, "NaN")
		t.eq(Protocol.decodeInventory(patched(dataAt + 9, math.huge, "f64")), nil, "infinity")
		-- The second key renamed to the first: a duplicate.
		inventory.slots[1] = S(TANK, 1, { aa = 1, ab = 2 })
		local pair = Protocol.encodeInventory({ ack = 1, inventory = inventory, window = 0, container = nil })
		local second = dataAt + 1 + 1 + 2 + 1 + 8
		t.eq(buffer.readu8(pair, second), 2, "ab's length")
		local duplicate = buffer.create(buffer.len(pair))
		buffer.copy(duplicate, 0, pair)
		buffer.writestring(duplicate, second + 1, "aa")
		t.eq(Protocol.decodeInventory(duplicate), nil, "a duplicate key")
		buffer.writestring(duplicate, second + 1, "ac")
		t.ok(Protocol.decodeInventory(duplicate) ~= nil, "a different key is fine")

		-- A string too long and a bad boolean.
		inventory.slots[1] = S(STICK, 1, { s = "abc", b = true })
		local strings = Protocol.encodeInventory({ ack = 1, inventory = inventory, window = 0, container = nil })
		local function patch(source: buffer, at: number, value: number): buffer
			local b = buffer.create(buffer.len(source))
			buffer.copy(b, 0, source)
			buffer.writeu8(b, at, value)
			return b
		end
		-- "b" first: key length 1, "b", type 2, value at dataAt + 4; then "s": length, "s", type 1, length.
		t.eq(buffer.readu8(strings, dataAt + 3), 2, "boolean type")
		t.eq(Protocol.decodeInventory(patch(strings, dataAt + 4, 2)), nil, "a boolean of 2")
		local sLength = dataAt + 5 + 3
		t.eq(buffer.readu8(strings, sLength), 3, "string length")
		t.eq(Protocol.decodeInventory(patch(strings, sLength, 65)), nil, "a string too long")
		t.eq(Protocol.decodeInventory(patch(strings, sLength, 4)), nil, "a string past the end")

		-- Container header: an unknown kind, slots without a kind, too much data, NaN data.
		inventory.slots[1] = nil
		local furnace = { kind = "furnace", block = B.Furnace, size = 3, slots = {}, data = { 1, 2, 3, 4, 5 } }
		local open = Protocol.encodeInventory({ ack = 1, inventory = inventory, window = 2, container = furnace })
		t.ok(Protocol.decodeInventory(open) ~= nil)
		t.eq(Protocol.decodeInventory(patch(open, HEADER + 1, 99)), nil, "an unknown kind")
		local noKind = Protocol.encodeInventory({ ack = 1, inventory = inventory, window = 0, container = nil })
		t.eq(Protocol.decodeInventory(patch(noKind, HEADER + 4, 1)), nil, "slots without a container")
		t.eq(Protocol.decodeInventory(patch(open, HEADER + 5, 17)), nil, "17 data values")
		local nan = buffer.create(buffer.len(open))
		buffer.copy(nan, 0, open)
		buffer.writef64(nan, HEADER + 6, 0 / 0)
		t.eq(Protocol.decodeInventory(nan), nil, "NaN data")
		local big = Types.newCrafting("inventory")
		t.ok(Protocol.decodeInventory(patch(open, HEADER + 4, Types.MAX_CONTAINER + 1)) == nil, "too many slots")
		t.ok(big ~= nil)
	end)

	t.test("protocol: creative actions carry the whole stack; bad data is malformed", function()
		local action = {
			kind = "creative",
			window = 0,
			slot = 12,
			item = PICKAXE,
			count = 1,
			damage = 77,
			data = Items.cleanData({ name = "Pick", tier = 3, shiny = false }),
		}
		local seq, decoded = Protocol.decodeInventoryAction(Protocol.encodeInventoryAction(42, action))
		t.eq(seq, 42)
		assert(decoded and decoded.kind == "creative")
		t.eq(decoded.item, PICKAXE)
		t.eq(decoded.damage, 77)
		t.ok(Items.sameData(decoded.data, action.data), "data round trips")
		local plain = { kind = "creative", window = 0, slot = Types.CURSOR, item = DIRT, count = 64 }
		local _, back = Protocol.decodeInventoryAction(Protocol.encodeInventoryAction(1, plain))
		assert(back and back.kind == "creative")
		t.eq(back.damage, nil)
		t.eq(back.data, nil)
		t.eq(back.count, 64)
		-- Old-style 11 byte creative actions are malformed now, as are trailing bytes and bad data.
		local encoded = Protocol.encodeInventoryAction(1, action)
		local short = buffer.create(11)
		buffer.copy(short, 0, encoded, 0, 11)
		t.eq((Protocol.decodeInventoryAction(short)), nil, "too short")
		local long = buffer.create(buffer.len(encoded) + 1)
		buffer.copy(long, 0, encoded)
		t.eq((Protocol.decodeInventoryAction(long)), nil, "trailing bytes")
		local bad = buffer.create(buffer.len(encoded))
		buffer.copy(bad, 0, encoded)
		buffer.writeu8(bad, 13, 20)
		t.eq((Protocol.decodeInventoryAction(bad)), nil, "20 entries")
		-- Invalid data on the way out travels as none.
		local _, cleaned = Protocol.decodeInventoryAction(
			Protocol.encodeInventoryAction(
				1,
				{ kind = "creative", window = 0, slot = 1, item = DIRT, count = 1, data = { [""] = 1 } } :: any
			)
		)
		assert(cleaned and cleaned.kind == "creative")
		t.eq(cleaned.data, nil)
		-- Fuzz: random bytes after a valid header never error.
		local seed = 12345
		local function random(n: number): number
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed % n
		end
		for _ = 1, 500 do
			local size = 13 + random(40)
			local b = buffer.create(size)
			buffer.copy(b, 0, encoded, 0, 13)
			for i = 13, size - 1 do
				buffer.writeu8(b, i, random(256))
			end
			local ok, _, result = pcall(Protocol.decodeInventoryAction, b)
			t.ok(ok, "never errors")
			if result and result.kind == "creative" then
				t.ok(Items.validData(result.data), "only valid data gets through")
			end
		end
	end)

	t.test("protocol: a creative stack with data goes client -> server -> client unchanged", function()
		local state = InventoryState.new(Containers.new())
		state:join("p")
		local prediction = Prediction.new()
		local function sync()
			local snapshot = Protocol.decodeInventory(Protocol.encodeInventory(state:snapshot("p") :: any))
			assert(snapshot, "decodes")
			prediction:receive(snapshot, true)
		end
		sync()
		local action = {
			kind = "creative",
			window = 0,
			slot = inv(prediction:window(), 5),
			item = TANK,
			count = 3,
			data = water(900),
		} :: any
		local seq = prediction:push(action, true)
		is(prediction:window().inventory.slots[5], TANK, 3, 900, "predicted")
		local got, decoded = Protocol.decodeInventoryAction(Protocol.encodeInventoryAction(seq, action))
		assert(got and decoded, "decodes")
		t.eq(#state:apply("p", got, decoded, false), 0)
		t.eq(state:window("p").inventory.slots[5], nil, "survival players cannot")
		state:apply("p", got, decoded, true)
		is(state:window("p").inventory.slots[5], TANK, 3, 900, "the server's stack")
		sync()
		is(prediction:window().inventory.slots[5], TANK, 3, 900, "the client agrees after the ack")
		-- A worn tool with data too; wear beyond the durability is refused on both sides.
		local tool =
			{ kind = "creative", window = 0, slot = inv(prediction:window(), 6), item = PICKAXE, count = 1 } :: any
		tool.damage, tool.data = 9, Items.cleanData({ name = "Old" })
		local toolSeq = prediction:push(tool, true)
		local _, toolAction = Protocol.decodeInventoryAction(Protocol.encodeInventoryAction(toolSeq, tool))
		state:apply("p", toolSeq, toolAction :: any, true)
		local held = state:window("p").inventory.slots[6] :: any
		t.eq(held.damage, 9)
		t.eq(held.data.name, "Old")
		tool.damage = 60000
		local wornSeq = prediction:push(tool, true)
		local _, worn = Protocol.decodeInventoryAction(Protocol.encodeInventoryAction(wornSeq, tool))
		state:apply("p", wornSeq, worn :: any, true)
		t.eq((state:window("p").inventory.slots[6] :: any).damage, 9, "refused: the old stack stays")
		sync()
		t.eq((prediction:window().inventory.slots[6] :: any).damage, 9, "and the client agrees")
	end)

	t.test("protocol: random snapshots never error and only decode valid data", function()
		local inventory = Types.newInventory()
		inventory.slots[1] = S(TANK, 1, { fluid = 1, amount = 5, name = "a" })
		local good = Protocol.encodeInventory({ ack = 1, inventory = inventory, window = 0, container = nil })
		local seed = 99
		local function random(n: number): number
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed % n
		end
		for _ = 1, 400 do
			local b = buffer.create(buffer.len(good))
			buffer.copy(b, 0, good)
			for _ = 1, 1 + random(3) do
				buffer.writeu8(b, random(buffer.len(good)), random(256))
			end
			local ok, snapshot = pcall(Protocol.decodeInventory, b)
			t.ok(ok, "never errors")
			if snapshot then
				for slot = 1, Types.INVENTORY_SIZE do
					local stack = snapshot.inventory.slots[slot]
					t.ok(stack == nil or Items.validData(stack.data), "valid data")
				end
			end
		end
	end)

	--[[ Server: entities, inventories, transporters ]]

	local function flat(_x: number, y: number, _z: number): number?
		return if y < 1 then B.Stone else AIR
	end

	t.test("entities: items keep their data from spawn to pickup, only equal data merges", function()
		local world = EntityWorld.new(flat, { maxItems = 100, lifetimeTicks = 6000 })
		local full = water(8000)
		local a = world:spawnItem(TANK, 1, 0.5, 1, 0.5, 0, 0, 0, 0, nil, full)
		local b = world:spawnItem(TANK, 1, 0.6, 1, 0.5, 0, 0, 0, 0, nil, nil)
		local c = world:spawnItem(TANK, 2, 0.7, 1, 0.5, 0, 0, 0, 0, nil, { amount = 8000, fluid = 1 })
		t.eq(world:get(a).data.amount, 8000)
		t.eq(world:get(b).data, nil)
		t.ok(table.isfrozen(world:get(c).data), "kept clean")
		world:spawnItem(TANK, 1, 0.5, 1, 0.5, 0, 0, 0, 0, nil, { bad = 0 / 0 })
		t.eq(world:get(4).data, nil, "invalid data is none")
		for _ = 1, 45 do
			world:tick({}, function()
				return 0
			end)
		end
		-- a and c merged (equal data), b and the fourth (no data) merged; never across.
		local tanks = world:each()
		t.eq(#tanks, 2, "two piles")
		local withWater, without = 0, 0
		for _, entity in tanks do
			if entity.data then
				withWater += entity.count
				t.eq(entity.data.amount, 8000)
			else
				without += entity.count
			end
		end
		t.eq(withWater, 3)
		t.eq(without, 2)
		-- Pickups hand the data over.
		local got = {}
		world:tick({ { key = "p", x = 0.6, y = 1, z = 0.5 } }, function(_key, item, count, _damage, _x, _y, _z, data)
			table.insert(got, { item = item, count = count, data = data })
			return count
		end)
		t.eq(#got, 2)
		local sawWater = false
		for _, stack in got do
			if stack.data then
				sawWater = true
				t.eq(stack.data.amount, 8000)
				t.eq(stack.count, 3)
			end
		end
		t.ok(sawWater, "the water arrived")
		t.eq(world:count(), 0)
	end)

	t.test("server inventories: pickups, give, held stacks, wear and containers keep data", function()
		local state = InventoryState.new(Containers.new())
		state:join("p")
		t.eq(state:pickup("p", S(TANK, 1, water(10))), 1)
		t.eq(state:pickup("p", S(TANK, 1, nil)), 1)
		local slots = state:window("p").inventory.slots
		is(slots[1], TANK, 1, 10, "first")
		is(slots[2], TANK, 1, nil, "not merged")
		t.eq(state:give("p", S(TANK, 1, water(10))), nil)
		is(slots[1], TANK, 2, 10, "given onto the same data")
		state:setHeld("p", S(TANK, 5, water(20)))
		is(state:heldStack("p"), TANK, 5, 20, "held")
		state:setHeld("p", S(PICKAXE, 1, { name = "x" }, 10))
		state:wearHeld("p", 1)
		local held = state:heldStack("p") :: any
		t.eq(held.damage, 11)
		t.eq(held.data.name, "x", "wear keeps data")
		-- A broken chest gives its stacks back with their data.
		local store = state.containers
		local chest = store:get(4, 5, 6, B.Chest)
		chest.slots[3] = S(TANK, 2, water(30))
		local contents = state:removeContainer(4, 5, 6)
		is(contents[1], TANK, 2, 30, "chest contents")
		-- Bucket rules keep a stack's data (copy).
		local left = UseRules.emptied(S(I.WaterBucket, 2, { tag = "w" }), false)
		t.eq(left and left.data and left.data.tag, "w")
	end)

	t.test("transporters: sided inventories keep data and never merge different data", function()
		local full = water(500)
		local slots = { [1] = S(TANK, 3, nil) }
		local out, left = Transmitters.insert(B.Chest, 1, slots, S(TANK, 2, full))
		t.eq(left, nil)
		is(out[1], TANK, 3, nil, "the empty tanks are left alone")
		is(out[2], TANK, 2, 500, "into an empty slot instead")
		t.eq(
			Transmitters.room(B.Chest, 1, { [1] = S(TANK, 63, nil) }, S(TANK, 5000, full)),
			26 * 64,
			"only empty slots"
		)
		t.eq(
			Transmitters.room(B.Chest, 1, { [1] = S(TANK, 63, full) }, S(TANK, 5000, full)),
			26 * 64 + 1,
			"and its kind"
		)
		local types = Transmitters.available(B.Chest, 1, out)
		t.eq(#types, 2, "two kinds")
		is(types[2], TANK, 2, 500, "the water kind")
		local after, taken = Transmitters.extract(B.Chest, 1, out, 64, types[2])
		is(taken, TANK, 2, 500, "taken with its data")
		t.eq(after[2], nil)
		is(after[1], TANK, 3, nil, "the others stay")
		local _, first = Transmitters.extract(B.Chest, 1, out, 1)
		is(first, TANK, 1, nil, "the first kind")
	end)

	t.test("transporters: stacks ride a line of transporters with their data and drop with it", function()
		local blocks: { [number]: number } = {}
		local containers = Containers.new()
		local drops = {}
		local world = TransmitterWorld.new({
			getBlock = function(x: number, y: number, z: number): number?
				return blocks[Coords.posKey(x, y, z)] or AIR
			end,
			containers = containers,
			inventoryChanged = function() end,
			drop = function(_x: number, _y: number, _z: number, stack)
				table.insert(drops, stack)
			end,
		})
		local function set(x: number, block: number)
			local key = Coords.posKey(x, Y, 0)
			local old = blocks[key] or AIR
			blocks[key] = if block == AIR then nil else block
			TransmitterWorld.blockChanged(world, x, Y, 0, old, block)
		end
		-- Chest, three Basic transporters pulling from it (west side of the first), chest.
		set(0, B.Chest)
		for x = 1, 3 do
			set(x, B.BasicLogisticalTransporter)
		end
		set(4, B.Chest)
		t.ok(TransmitterWorld.setMode(world, 1, Y, 0, 4, Transmitters.MODES.PULL), "PULL side set")
		local source = containers:get(0, Y, 0, B.Chest).slots
		source[1] = S(TANK, 2, water(500))
		source[2] = S(TANK, 3, nil)
		local target = containers:get(4, Y, 0, B.Chest).slots
		local function arrived(): number
			local n = 0
			for _, stack in target do
				n += stack.count
			end
			return n
		end
		for _ = 1, 1000 do
			TransmitterWorld.step(world)
			if arrived() == 5 and world.itemCount == 0 then
				break
			end
		end
		t.eq(arrived(), 5, "everything arrived")
		local withWater, plain = nil, nil
		for _, stack in target do
			if stack.data then
				withWater = stack
			else
				plain = stack
			end
		end
		is(withWater, TANK, 2, 500, "the tanks with water, apart")
		is(plain, TANK, 3, nil, "the empty tanks")

		-- An item in transit drops with its data when its transporters go.
		source[1] = S(TANK, 1, water(700))
		for _ = 1, 100 do
			TransmitterWorld.step(world)
			if world.itemCount > 0 then
				break
			end
		end
		t.eq(world.itemCount, 1, "on its way")
		for x = 1, 3 do
			set(x, AIR)
		end
		t.eq(#drops, 1, "dropped")
		is(drops[1], TANK, 1, 700, "the drop keeps the water")
	end)

	--[[ Tooltips ]]

	t.test("tooltips: Mekanism's energy and fluid formats", function()
		local cases: { { any } } = {
			{ 0, "0 J" },
			{ 1, "1 J" },
			{ 400, "400 J" },
			{ 999.999, "999.99 J" },
			{ 1000, "1 kJ" },
			{ 1200, "1.2 kJ" },
			{ 1234, "1.23 kJ" },
			{ 1205, "1.2 kJ" },
			{ 19999, "19.99 kJ" },
			{ 20000, "20 kJ" },
			{ 160000, "160 kJ" },
			{ 999999, "999.99 kJ" },
			{ 1000000, "1 MJ" },
			{ 1200000, "1.2 MJ" },
			{ 4000000, "4 MJ" },
			{ 256000000, "256 MJ" },
			{ 1.5e9, "1.5 GJ" },
			{ 2e12, "2000 GJ" },
			{ -1500, "-1.5 kJ" },
			{ 0.001, "0 J" },
			{ math.huge, "Infinite" },
			{ 0 / 0, "0 J" },
		}
		for _, case in cases do
			t.eq(Items.formatEnergy(case[1]), case[2], `{case[1]} J`)
		end
		t.eq(Items.formatFluid(0), "0 mB")
		t.eq(Items.formatFluid(1000), "1,000 mB")
		t.eq(Items.formatFluid(12000), "12,000 mB")
		t.eq(Items.formatFluid(256000), "256,000 mB")
		t.eq(Items.thousands(1234567), "1,234,567")
		t.eq(Items.thousands(-1000), "-1,000")
	end)

	t.test("tooltips: describe lines by data key, in order; describers are added and replaced", function()
		t.eq(#Items.describe(nil), 0)
		t.eq(#Items.describe(S(DIRT, 1)), 0, "no data, no lines")
		local tank = Items.describe(S(TANK, 1, water(12000)))
		t.eq(#tank, 1)
		t.eq(tank[1], "Water: 12,000 mB")
		t.eq(#Items.describe(S(TANK, 1, { fluid = 9, amount = 1 })), 0, "an unknown fluid shows nothing")
		t.eq(#Items.describe(S(TANK, 1, { fluid = 1, amount = 0 })), 0, "nothing in it")
		t.eq(Items.describe(S(TANK, 1, { energy = 1200000 }))[1], "Energy: 1.2 MJ")
		t.eq(#Items.describe(S(TANK, 1, { secret = 5 })), 0, "keys without a describer are hidden")
		-- A new key's line comes after the built-in ones; replacing keeps its place.
		Items.addDescriber("item_data_test", function(data)
			return `Test: {data.item_data_test}`
		end)
		local lines = Items.describe(S(TANK, 1, { item_data_test = 3, energy = 5, fluid = 1, amount = 7 }))
		t.eq(#lines, 3)
		t.eq(lines[1], "Water: 7 mB")
		t.eq(lines[2], "Energy: 5 J")
		t.eq(lines[3], "Test: 3")
		Items.addDescriber("item_data_test", function()
			return nil
		end)
		t.eq(#Items.describe(S(TANK, 1, { item_data_test = 3 })), 0, "replaced")
		Items.addDescriber("item_data_test", function()
			error("broken")
		end)
		t.eq(#Items.describe(S(TANK, 1, { item_data_test = 3, energy = 1 })), 1, "a failing describer is skipped")
		t.ok(not pcall(Items.addDescriber, "bad key", function()
			return nil
		end), "keys are data keys")
		-- Items' fluid names are the pipes'.
		t.eq(#Items.FLUID_NAMES, #Transmitters.FLUID_NAMES)
		for i, name in Transmitters.FLUID_NAMES do
			t.eq(Items.FLUID_NAMES[i], name)
		end
	end)

	--[[ JEI ]]

	t.test("jei transfer: kinds by data, plain stacks first", function()
		local recipe = nil
		for _, candidate in Crafting.recipes do
			if candidate.result == TANK2 then
				recipe = candidate
			end
		end
		assert(recipe)
		local w = Types.newWindow(Types.newInventory())
		w.id = 1
		w.container = Types.newCrafting("crafting", B.CraftingTable)
		-- Every other ingredient, plus a tank with water and an empty one.
		local slot = 1
		for _, cell in recipe.cells do
			if cell then
				local item = next(cell) :: number
				if item ~= TANK then
					w.inventory.slots[10 + slot] = S(item, 1)
					slot += 1
				end
			end
		end
		w.inventory.slots[1] = S(TANK, 1, water(5000))
		w.inventory.slots[2] = S(TANK, 1, nil)
		local actions = JeiTransfer.plan(w, recipe, false, false)
		assert(actions, "a plan")
		for _, action in actions do
			Menu.apply(w, action, false)
		end
		is(w.inventory.slots[1], TANK, 1, 5000, "the tank with water stays")
		t.eq(w.inventory.slots[2], nil, "the empty one went into the grid")
		t.eq(w.container.slots[Types.CRAFT_RESULT].item, TANK2)
		-- Only the one with water: it is used.
		local w2 = Menu.copyWindow(w)
		Menu.close(w2)
		w2.container = Types.newCrafting("crafting", B.CraftingTable)
		w2.id = 1
		for i = 1, Types.INVENTORY_SIZE do
			local stack = w2.inventory.slots[i]
			if stack and stack.item == TANK and stack.data == nil then
				w2.inventory.slots[i] = nil
			end
		end
		t.ok(JeiTransfer.check(w2, recipe).ok, "a tank with water will do")
	end)

	--[[ Mekanism's sustained data: a tank keeps its water ]]

	local function tankWorld()
		local blocks: { [number]: number } = {}
		local world = TransmitterWorld.new({
			getBlock = function(x: number, y: number, z: number): number?
				return blocks[Coords.posKey(x, y, z)] or AIR
			end,
			containers = Containers.new(),
		})
		local function set(x: number, y: number, z: number, block: number)
			local key = Coords.posKey(x, y, z)
			local old = blocks[key] or AIR
			blocks[key] = if block == AIR then nil else block
			TransmitterWorld.blockChanged(world, x, y, z, old, block)
		end
		local registry = EditRules.newBlockData()
		registry:add(TransmitterWorld.blockDataHooks(world))
		return world, set, registry
	end

	t.test("tanks: tankData and restoreTank", function()
		local world, set = tankWorld()
		set(0, Y, 0, TANK)
		t.eq(TransmitterWorld.tankData(world, 0, Y, 0), nil, "empty: no data")
		t.eq(TransmitterWorld.tankData(world, 5, Y, 0), nil, "no tank")
		TransmitterWorld.fillTank(world, 0, Y, 0, WATER, 12000)
		local data = TransmitterWorld.tankData(world, 0, Y, 0) :: any
		t.eq(data.fluid, WATER)
		t.eq(data.amount, 12000)
		t.ok(Items.validData(data))
		set(1, Y, 0, TANK)
		t.ok(TransmitterWorld.restoreTank(world, 1, Y, 0, data))
		local tank = TransmitterWorld.tank(world, 1, Y, 0) :: any
		t.eq(tank.amount, 12000)
		t.eq(tank.fluid, WATER)
		t.ok(TransmitterWorld.restoreTank(world, 1, Y, 0, { fluid = WATER, amount = 999999.7 }))
		t.eq(tank.amount, 32000, "cut to the tank's capacity")
		t.ok(TransmitterWorld.restoreTank(world, 1, Y, 0, { fluid = WATER, amount = 2.9 }))
		t.eq(tank.amount, 2, "whole mB")
		t.ok(not TransmitterWorld.restoreTank(world, 1, Y, 0, { fluid = 7, amount = 5 }), "unknown fluid")
		t.ok(not TransmitterWorld.restoreTank(world, 1, Y, 0, { fluid = WATER, amount = 0 }), "nothing")
		t.ok(not TransmitterWorld.restoreTank(world, 1, Y, 0, { fluid = WATER, amount = "5" } :: any), "a string")
		t.ok(not TransmitterWorld.restoreTank(world, 1, Y, 0, { energy = 5 }), "something else's data")
		t.ok(not TransmitterWorld.restoreTank(world, 1, Y, 0, nil))
		t.ok(not TransmitterWorld.restoreTank(world, 9, Y, 0, data), "no tank there")
		t.eq(tank.amount, 2, "unchanged by the refusals")
		-- The restored contents replicate.
		TransmitterWorld.step(world)
		local _, records = TransmitterWorld.takeRecords(world)
		local found = false
		for _, record in records do
			if record.x == 1 and record.amount == 2 then
				found = true
			end
		end
		t.ok(found, "a Tanks record for the restored tank")
	end)

	t.test("tanks: break with water, carry the item, place it again (the whole round trip)", function()
		local world, set, registry = tankWorld()
		set(0, Y, 0, TANK)
		TransmitterWorld.fillTank(world, 0, Y, 0, WATER, 12000)

		-- A survival break, as ServerNet.performBreak does it: the drop with its data, read before
		-- the block goes, then the block goes (and the tank with it).
		t.eq(EditRules.breakDrop(registry, 0, Y, 0, TANK, true, nil), nil, "creative breaks drop nothing")
		local drop = EditRules.breakDrop(registry, 0, Y, 0, TANK, false, nil)
		assert(drop, "a tank drops itself by hand")
		set(0, Y, 0, AIR)
		is(drop, TANK, 1, 12000, "the drop")
		t.eq(TransmitterWorld.tank(world, 0, Y, 0), nil, "the tank is gone")
		local late = EditRules.breakDrop(registry, 0, Y, 0, TANK, false, nil)
		t.eq(late and late.data, nil, "read after the tank went: nothing kept")
		t.eq(
			EditRules.breakDrop(registry, 0, Y, 0, B.IronOre, false, I.StonePickaxe).item,
			I.RawIron,
			"ores drop plain"
		)

		-- It lies on the ground, a player picks it up.
		local entities = EntityWorld.new(flat, { maxItems = 100, lifetimeTicks = 6000 })
		entities:spawnItem(drop.item, drop.count, 0.5, 1, 0.5, 0, 0, 0, 0, drop.damage, drop.data)
		local state = InventoryState.new(Containers.new())
		state:join("p")
		entities:tick({ { key = "p", x = 0.5, y = 1, z = 0.5 } }, function(key, item, count, damage, _x, _y, _z, data)
			return state:pickup(key, { item = item, count = count, damage = damage, data = data })
		end)
		local inventory = state:window("p").inventory
		is(inventory.slots[1], TANK, 1, 12000, "in the hotbar")

		-- The client sees it, with its tooltip.
		local snapshot = Protocol.decodeInventory(Protocol.encodeInventory(state:snapshot("p") :: any))
		assert(snapshot)
		is(snapshot.inventory.slots[1], TANK, 1, 12000, "in the snapshot")
		t.eq(Items.describe(snapshot.inventory.slots[1])[1], "Water: 12,000 mB")
		local prediction = Prediction.new()
		prediction:receive(snapshot, false)
		is(prediction:window().inventory.slots[1], TANK, 1, 12000, "predicted")
		prediction:push({ kind = "place", item = TANK }, false)
		t.eq(prediction:window().inventory.slots[1], nil, "the client predicts it used up")

		-- Placed again: the stack comes back from `place` before it is used up, and the hook
		-- restores the water into the new tank.
		local ok, from = state:place("p", TANK, 1, false)
		t.ok(ok, "placed")
		is(from, TANK, 1, 12000, "the stack it came from")
		t.eq(inventory.slots[1], nil, "used up")
		set(3, Y, 0, TANK)
		registry:placed("p", 3, Y, 0, TANK, from)
		local tank = TransmitterWorld.tank(world, 3, Y, 0) :: any
		t.eq(tank.amount, 12000, "the water is back")
		t.eq(tank.fluid, WATER)

		-- An empty tank breaks into a plain item, which stacks with new ones.
		set(4, Y, 0, TANK)
		local plain = EditRules.breakDrop(registry, 4, Y, 0, TANK, false, nil)
		t.eq(plain and plain.data, nil, "no data")
		t.ok(Items.stacksMatch(plain :: any, { item = TANK, count = 1 }))

		-- Creative: placing from an item with data restores it too; placing with a hand holding
		-- something else gives no stack.
		inventory.slots[1] = S(TANK, 1, water(500))
		local creativeOk, creativeFrom = state:place("p", TANK, 2, true)
		t.ok(creativeOk)
		is(creativeFrom, TANK, 1, 500, "creative stack")
		is(inventory.slots[1], TANK, 1, 500, "creative keeps it")
		set(5, Y, 0, TANK)
		registry:placed("p", 5, Y, 0, TANK, creativeFrom)
		t.eq((TransmitterWorld.tank(world, 5, Y, 0) :: any).amount, 500)
		inventory.slots[1] = S(DIRT, 1)
		local _, none = state:place("p", TANK, 3, true)
		t.eq(none, nil, "creative, another item in hand")
		local refused, nothing = state:place("p", TANK, 4, false)
		t.ok(not refused, "survival needs the item")
		t.eq(nothing, nil)

		-- Data only goes on a block's own item, and other blocks keep none.
		t.eq(EditRules.dropWithData({ item = I.RawIron, count = 1 }, B.IronOre, water(5)).data, nil, "ore drops plain")
		t.eq(registry:save(9, Y, 9, B.Chest), nil, "not the tanks' business")
		t.eq(EditRules.dropWithData(nil, TANK, water(5)), nil)
	end)

	t.test("sustained data registry: hooks' data merges, placed reaches every hook, errors are skipped", function()
		local registry = EditRules.newBlockData()
		local calls = {}
		registry:add({
			save = function(x)
				return if x == 1 then { a = 1, shared = "first" } else nil
			end,
			placed = function(player, x)
				table.insert(calls, `first {player} {x}`)
			end,
		})
		registry:add({
			save = function()
				return { b = 2, shared = "second" }
			end,
		})
		registry:add({
			save = function()
				error("a broken part")
			end,
			placed = function()
				error("a broken part")
			end,
		})
		registry:add({
			placed = function(player, x, _y, _z, _block, stack)
				table.insert(calls, `fourth {player} {x} {stack and stack.count or 0}`)
			end,
		})
		local both = registry:save(1, 0, 0, DIRT) :: any
		t.eq(both.a, 1)
		t.eq(both.b, 2, "every part's keys")
		t.eq(both.shared, "first", "the earlier part wins a shared key")
		t.ok(table.isfrozen(both), "clean")
		local only = registry:save(2, 0, 0, DIRT) :: any
		t.eq(only.a, nil)
		t.eq(only.b, 2, "the part that keeps something")
		registry:placed("p", 7, 0, 0, DIRT, S(DIRT, 3))
		t.eq(#calls, 2, "a failing hook does not stop the others")
		t.eq(calls[1], "first p 7")
		t.eq(calls[2], "fourth p 7 3")
		local invalid = EditRules.newBlockData()
		invalid:add({
			save = function()
				return { ["no good"] = 1 }
			end,
		})
		t.eq(invalid:save(0, 0, 0, DIRT), nil, "invalid data is none")
		t.eq(EditRules.newBlockData():save(0, 0, 0, DIRT), nil, "no parts, no data")
		-- At most 16 keys survive a merge (the earlier parts' first).
		local crowded = EditRules.newBlockData()
		for part = 1, 2 do
			crowded:add({
				save = function()
					local data = {}
					for i = 1, 10 do
						data[`p{part}_{i}`] = i
					end
					return data
				end,
			})
		end
		local capped = crowded:save(0, 0, 0, DIRT) :: any
		local n = 0
		for _ in capped do
			n += 1
		end
		t.eq(n, Items.MAX_DATA_KEYS)
		t.eq(capped.p1_10, 10, "the first part whole")
		t.ok(PLANKS ~= nil)
	end)
end

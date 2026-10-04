--[[
	Server gameplay rules: container storage (Players/Containers), the authoritative inventories
	(Players/InventoryState: acks, chests, crafting tables, the 2 x 2 grid, pickups, deaths, tool
	wear), the /gamemode command and its permissions (Players/GameModeCommand) and the edit rules of
	each game mode (Network/EditRules).
]]

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local GameMode = require(shared.GameMode)
	local Protocol = require(shared.Net.Protocol)
	local Types = require(shared.Inventory.Types)
	local Menu = require(shared.Inventory.Menu)
	local Containers = require(server.Players.Containers)
	local InventoryState = require(server.Players.InventoryState)
	local GameModeCommand = require(server.Players.GameModeCommand)
	local EditRules = require(server.Network.EditRules)

	local CHEST, TABLE, FURNACE = Blocks.id.Chest, Blocks.id.CraftingTable, Blocks.id.Furnace
	local STONE, DIRT = Items.id.Stone, Items.id.Dirt
	local LOG, PLANKS, PICKAXE = Items.id.OakLog, Items.id.Planks, Items.id.WoodenPickaxe
	local QUICK_MOVE, PICKUP = Menu.ClickType.QuickMove, Menu.ClickType.Pickup
	-- Window slot of hotbar slot `slot` in `window`.
	local function hotbar(window, slot: number): number
		return Menu.windowIndex(window, "inventory", slot)
	end

	local function count(inventory, item: number): number
		local total = 0
		for slot = 1, Types.INVENTORY_SIZE do
			local stack = inventory.slots[slot]
			if stack and stack.item == item then
				total += stack.count
			end
		end
		return total
	end

	--[[ Containers ]]

	t.test("containers: created empty on first use, then the same table", function()
		local store = Containers.new()
		t.eq(store:peek(1, 2, 3), nil)
		local chest = store:get(1, 2, 3, CHEST)
		t.eq(chest.size, 27)
		t.eq(chest.block, CHEST)
		t.eq(next(chest.slots), nil, "empty")
		t.eq(store:get(1, 2, 3, CHEST), chest, "same container on the second use")
		t.eq(store:peek(1, 2, 3), chest)
		t.eq(store.count, 1)
		t.ok(store:get(1, 2, 4, CHEST) ~= chest, "positions are separate")
		t.ok(not pcall(store.get, store, 5, 5, 5, Blocks.id.Stone), "stone is not a container")
	end)

	t.test("containers: a furnace is a 3 slot container with fresh smelting data", function()
		local store = Containers.new()
		local furnace = store:get(0, 1, 0, FURNACE)
		t.eq(furnace.kind, "furnace")
		t.eq(furnace.size, 3)
		t.eq(furnace.block, FURNACE)
		t.ok(furnace.data ~= nil, "data")
		t.eq(furnace.data[1], 0, "not burning")
		t.eq(store:get(0, 2, 0, CHEST).kind, "chest")
		t.eq(store:get(0, 2, 0, CHEST).data, nil)
		t.ok(not pcall(store.get, store, 0, 3, 0, TABLE), "a crafting table has no stored container")
	end)

	t.test("containers: viewers; an empty chest nobody looks at is forgotten", function()
		local store = Containers.new()
		store:get(0, 0, 0, CHEST)
		store:addViewer(0, 0, 0, "a")
		store:addViewer(0, 0, 0, "b")
		store:addViewer(0, 0, 0, "b")
		t.eq(#store:viewers(0, 0, 0), 2)
		store:removeViewer(0, 0, 0, "a")
		t.eq(#store:viewers(0, 0, 0), 1)
		t.ok(store:peek(0, 0, 0) ~= nil, "still open by b")
		store:removeViewer(0, 0, 0, "b")
		t.eq(store:peek(0, 0, 0), nil, "empty and closed: forgotten")
		t.eq(store.count, 0)

		local chest = store:get(0, 0, 0, CHEST)
		store:addViewer(0, 0, 0, "a")
		chest.slots[5] = { item = STONE, count = 3 }
		store:removeViewer(0, 0, 0, "a")
		t.eq(store:peek(0, 0, 0), chest, "items keep it")
		store:removeViewer(0, 0, 0, "nobody")
		t.eq(store.count, 1)
	end)

	t.test("containers: take removes the contents and names the viewers", function()
		local store = Containers.new()
		local chest = store:get(7, 8, 9, CHEST)
		chest.slots[1] = { item = DIRT, count = 10 }
		store:addViewer(7, 8, 9, "a")
		local taken, viewers = store:take(7, 8, 9)
		t.eq(taken, chest)
		t.eq(#viewers, 1)
		t.eq(viewers[1], "a")
		t.eq(store:peek(7, 8, 9), nil)
		t.eq(store.count, 0)
		local none, nobody = store:take(7, 8, 9)
		t.eq(none, nil)
		t.eq(#nobody, 0)
		t.eq(store:get(7, 8, 9, CHEST).slots[1], nil, "a new chest there starts empty")
	end)

	t.test("containers: the module functions use the server's store", function()
		local chest = Containers.get(-100, 5, 100, CHEST)
		t.eq(Containers.peek(-100, 5, 100), chest)
		t.eq(Containers.default:peek(-100, 5, 100), chest)
		t.eq(Containers.take(-100, 5, 100), chest)
		t.eq(Containers.peek(-100, 5, 100), nil)
	end)

	--[[ Inventories ]]

	local function newState()
		local state = InventoryState.new()
		state:join("a")
		state:join("b")
		state:takeDirty()
		return state
	end

	t.test("inventories: joining sends a snapshot of an empty inventory", function()
		local state = InventoryState.new()
		state:join("a")
		local dirty = state:takeDirty()
		t.eq(#dirty, 1)
		t.eq(dirty[1], "a")
		t.eq(#state:takeDirty(), 0, "flags cleared")
		local snapshot = state:snapshot("a")
		t.eq(snapshot.ack, 0)
		t.eq(snapshot.window, 0)
		t.eq(snapshot.container.kind, "inventory", "window 0's 2 x 2 grid")
		t.eq(snapshot.container.size, 5)
		t.eq(snapshot.inventory.selected, 1)
		t.eq(state:snapshot("nobody"), nil)
		t.eq(state:window("nobody"), nil)
	end)

	t.test("inventories: every action is acknowledged, valid or not", function()
		local state = newState()
		state:apply("a", 1, { kind = "select", slot = 4 }, false)
		t.eq(state:snapshot("a").ack, 1)
		t.eq(state:window("a").inventory.selected, 4)
		t.eq(state:takeDirty()[1], "a")

		-- Out of range slot, wrong window, creative action in survival: nothing changes.
		state:window("a").inventory.slots[1] = { item = STONE, count = 5 }
		state:apply("a", 2, { kind = "click", window = 0, slot = 999, clickType = PICKUP, button = 0 }, false)
		state:apply(
			"a",
			3,
			{ kind = "click", window = 9, slot = hotbar(state:window("a"), 1), clickType = PICKUP, button = 0 },
			false
		)
		state:apply("a", 4, { kind = "creative", window = 0, slot = Types.CURSOR, item = DIRT, count = 64 }, false)
		t.eq(state:snapshot("a").ack, 4)
		t.eq(state:window("a").inventory.cursor, nil)
		t.eq(state:window("a").inventory.slots[1].count, 5)
		t.eq(#state:takeDirty(), 1, "the invalid actions still answer")

		-- Seq 0 (never used by clients) does not move the ack back.
		state:apply("a", 0, { kind = "select", slot = 2 }, false)
		t.eq(state:snapshot("a").ack, 4)
		-- Placing only travels in Edit messages.
		state:window("a").inventory.selected = 1
		state:apply("a", 5, { kind = "place", item = STONE }, false)
		t.eq(state:window("a").inventory.slots[1].count, 5)
		t.eq(state:snapshot("a").ack, 5)
	end)

	t.test("inventories: thrown stacks come back to the caller", function()
		local state = newState()
		local inventory = state:window("a").inventory
		inventory.slots[1] = { item = DIRT, count = 10 }
		local thrown = state:apply("a", 1, { kind = "drop", all = false }, false)
		t.eq(#thrown, 1)
		t.eq(thrown[1].item, DIRT)
		t.eq(thrown[1].count, 1)
		thrown = state:apply("a", 2, { kind = "drop", all = true }, false)
		t.eq(thrown[1].count, 9)
		t.eq(inventory.slots[1], nil)
		-- Clicking outside with a stack on the cursor throws it.
		inventory.cursor = { item = STONE, count = 3 }
		thrown = state:apply(
			"a",
			3,
			{ kind = "click", window = 0, slot = Types.OUTSIDE, clickType = PICKUP, button = 0 },
			false
		)
		t.eq(thrown[1].count, 3)
		t.eq(inventory.cursor, nil)
	end)

	t.test("inventories: survival placing uses up the held block item", function()
		local state = newState()
		local inventory = state:window("a").inventory
		inventory.slots[1] = { item = STONE, count = 2 }
		t.ok(state:place("a", Blocks.id.Stone, 7, false))
		t.eq(inventory.slots[1].count, 1)
		t.eq(state:snapshot("a").ack, 7)
		t.ok(state:place("a", Blocks.id.Stone, 8, false))
		t.eq(inventory.slots[1], nil, "the last one")
		t.ok(not state:place("a", Blocks.id.Stone, 9, false), "nothing left")
		t.eq(state:snapshot("a").ack, 9, "refused placements are acknowledged too")

		inventory.slots[2] = { item = DIRT, count = 5 }
		inventory.selected = 2
		t.ok(not state:place("a", Blocks.id.Stone, 10, false), "holding dirt, not stone")
		t.ok(not state:place("a", Blocks.id.Bedrock, 11, false), "bedrock is no item")
		t.eq(inventory.slots[2].count, 5)
		t.ok(not state:place("nobody", Blocks.id.Dirt, 1, false))
	end)

	t.test("inventories: creative placing uses nothing; acknowledge answers refused edits", function()
		local state = newState()
		local inventory = state:window("a").inventory
		t.ok(state:place("a", Blocks.id.Stone, 3, true), "creative: any block, empty hands")
		inventory.slots[1] = { item = STONE, count = 2 }
		t.ok(state:place("a", Blocks.id.Stone, 4, true))
		t.eq(inventory.slots[1].count, 2)
		t.eq(state:snapshot("a").ack, 4)
		state:takeDirty()
		state:acknowledge("a", 5)
		t.eq(state:snapshot("a").ack, 5)
		t.eq(state:takeDirty()[1], "a")
		state:acknowledge("a", 0)
		t.eq(state:snapshot("a").ack, 5)
	end)

	t.test("inventories: opening a chest gives a new window with the shared container", function()
		local state = newState()
		local thrown = state:open("a", 10, 20, 30, CHEST)
		t.eq(#thrown, 0)
		local window = state:window("a")
		t.eq(window.id, 1)
		t.eq(window.container.size, 27)
		t.eq(window.container, state.containers:peek(10, 20, 30))
		local x, y, z = state:openPosition("a")
		t.eq(x, 10)
		t.eq(y, 20)
		t.eq(z, 30)
		t.eq(state:snapshot("a").window, 1)
		t.eq(state:snapshot("a").container, window.container)
		t.eq(state:takeDirty()[1], "a")

		-- Opening another closes the first; the cursor goes back into the inventory.
		window.inventory.cursor = { item = DIRT, count = 4 }
		state:open("a", 11, 20, 30, CHEST)
		t.eq(window.id, 2)
		t.eq(window.inventory.cursor, nil)
		t.eq(count(window.inventory, DIRT), 4)
		t.eq(#state.containers:viewers(10, 20, 30), 0)
		t.eq(state.containers:peek(10, 20, 30), nil, "the empty first chest is forgotten")
		t.eq(#state.containers:viewers(11, 20, 30), 1)

		-- Window ids cycle through 1..255, never 0.
		state:get("a").lastWindow = 254
		state:open("a", 11, 20, 30, CHEST)
		t.eq(window.id, 255)
		state:open("a", 11, 20, 30, CHEST)
		t.eq(window.id, 1)
	end)

	t.test("inventories: two viewers of one chest see each other's changes", function()
		local state = newState()
		state:open("a", 0, 0, 0, CHEST)
		state:open("b", 0, 0, 0, CHEST)
		local a, b = state:window("a"), state:window("b")
		t.eq(a.container, b.container)
		state:takeDirty()

		a.inventory.slots[1] = { item = STONE, count = 20 }
		state:apply(
			"a",
			1,
			{ kind = "click", window = a.id, slot = hotbar(a, 1), clickType = QUICK_MOVE, button = 0 },
			false
		)
		t.eq(b.container.slots[1].item, STONE, "b's window shows a's shift click")
		t.eq(b.container.slots[1].count, 20)
		local dirty = state:takeDirty()
		table.sort(dirty)
		t.eq(#dirty, 2, "both get a snapshot")

		-- b takes it out; a hears about it. Selecting a hotbar slot touches no chest.
		state:apply("b", 1, { kind = "click", window = b.id, slot = 0, clickType = QUICK_MOVE, button = 0 }, false)
		t.eq(a.container.slots[1], nil)
		t.eq(count(b.inventory, STONE), 20)
		t.eq(#state:takeDirty(), 2)
		state:apply("b", 2, { kind = "select", slot = 3 }, false)
		t.eq(#state:takeDirty(), 1)
	end)

	t.test("inventories: closing returns to the inventory window; late closes are ignored", function()
		local state = newState()
		state:open("a", 0, 0, 0, CHEST)
		local window = state:window("a")
		local id = window.id
		window.container.slots[1] = { item = DIRT, count = 1 }

		state:apply("a", 1, { kind = "close", window = id + 1 }, false)
		t.eq(window.id, id, "a close for another window changes nothing")
		t.eq(state:snapshot("a").ack, 1)

		window.inventory.cursor = { item = STONE, count = 2 }
		local thrown = state:apply("a", 2, { kind = "close", window = id }, false)
		t.eq(#thrown, 0)
		t.eq(window.id, 0)
		t.eq(window.container.kind, "inventory", "window 0 with a fresh 2 x 2 grid")
		t.eq(window.inventory.cursor, nil)
		t.eq(count(window.inventory, STONE), 2)
		t.eq(state:openPosition("a"), nil)
		t.eq(#state.containers:viewers(0, 0, 0), 0)
		t.ok(state.containers:peek(0, 0, 0) ~= nil, "the chest keeps its dirt")

		-- Closing the inventory window (0) puts the cursor back too.
		window.inventory.cursor = { item = STONE, count = 1 }
		state:apply("a", 3, { kind = "close", window = 0 }, false)
		t.eq(window.inventory.cursor, nil)
		t.eq(count(window.inventory, STONE), 3)
	end)

	t.test("inventories: a broken chest drops its contents and closes for its viewers", function()
		local state = newState()
		state:open("a", 4, 5, 6, CHEST)
		state:open("b", 4, 5, 6, CHEST)
		local a, b = state:window("a"), state:window("b")
		a.container.slots[1] = { item = DIRT, count = 30 }
		a.container.slots[27] = { item = Items.id.IronHelmet, count = 1 }
		-- b's inventory is full of stone, so b's cursor cannot go back.
		for slot = 1, Types.INVENTORY_SIZE do
			b.inventory.slots[slot] = { item = STONE, count = 64 }
		end
		b.inventory.cursor = { item = DIRT, count = 5 }
		state:takeDirty()

		local contents, leftovers = state:removeContainer(4, 5, 6)
		t.eq(#contents, 2)
		t.eq(contents[1].item, DIRT)
		t.eq(contents[1].count, 30)
		t.eq(contents[2].item, Items.id.IronHelmet)
		t.eq(#leftovers, 1)
		t.eq(leftovers[1].key, "b")
		t.eq(leftovers[1].stacks[1].count, 5)
		t.eq(a.id, 0)
		t.eq(b.id, 0)
		t.eq(a.container.kind, "inventory")
		t.eq(state.containers.count, 0)
		t.eq(#state:takeDirty(), 2)

		local none, nothing = state:removeContainer(4, 5, 6)
		t.eq(#none, 0, "twice is harmless")
		t.eq(#nothing, 0)
	end)

	t.test("inventories: pickups fill the inventory like Minecraft's Inventory.add", function()
		local state = newState()
		local inventory = state:window("a").inventory
		inventory.slots[3] = { item = DIRT, count = 60 }
		t.eq(state:pickup("a", { item = DIRT, count = 10 }), 10)
		t.eq(inventory.slots[3].count, 64)
		t.eq(inventory.slots[1].count, 6, "the rest in the first empty slot")
		t.eq(state:takeDirty()[1], "a")

		for slot = 1, Types.INVENTORY_SIZE do
			inventory.slots[slot] = { item = STONE, count = if slot == 36 then 60 else 64 }
		end
		t.eq(state:pickup("a", { item = STONE, count = 10 }), 4, "partly")
		t.eq(state:pickup("a", { item = DIRT, count = 1 }), 0, "full")
		state:takeDirty()
		t.eq(state:pickup("a", { item = DIRT, count = 1 }), 0)
		t.eq(#state:takeDirty(), 0, "nothing taken, nothing to send")
		t.eq(state:pickup("nobody", { item = DIRT, count = 1 }), 0)
	end)

	t.test("inventories: dying drops everything unless keepInventory", function()
		local state = newState()
		state:open("a", 0, 0, 0, CHEST)
		local window = state:window("a")
		local inventory = window.inventory
		inventory.slots[1] = { item = DIRT, count = 10 }
		inventory.slots[20] = { item = STONE, count = 3 }
		inventory.armor[1] = { item = Items.id.IronHelmet, count = 1 }
		inventory.cursor = { item = STONE, count = 2 }

		local kept = InventoryState.new()
		kept:join("a")
		kept:window("a").inventory.slots[1] = { item = DIRT, count = 10 }
		t.eq(#kept:die("a", true), 0, "keepInventory: nothing drops")
		t.eq(kept:window("a").inventory.slots[1].count, 10)

		local dropped = state:die("a", false)
		local total = 0
		for _, stack in dropped do
			total += stack.count
		end
		t.eq(total, 16, "inventory, armor and cursor")
		t.eq(window.id, 0, "the chest closes")
		t.eq(inventory.slots[1], nil)
		t.eq(inventory.armor[1], nil)
		t.eq(inventory.cursor, nil)
	end)

	t.test("inventories: leaving closes the chest", function()
		local state = newState()
		state:open("a", 1, 1, 1, CHEST)
		state:window("a").container.slots[2] = { item = DIRT, count = 1 }
		state:open("b", 2, 2, 2, CHEST)
		state:leave("a")
		state:leave("b")
		t.eq(state:get("a"), nil)
		t.eq(#state.containers:viewers(1, 1, 1), 0)
		t.ok(state.containers:peek(1, 1, 1) ~= nil, "items stay in the chest")
		t.eq(state.containers:peek(2, 2, 2), nil, "an empty chest is forgotten")
		t.eq(#state:takeDirty(), 0)
	end)

	t.test("inventories: snapshots survive the network", function()
		local state = newState()
		state:open("a", 0, 0, 0, CHEST)
		state:apply("a", 41, { kind = "select", slot = 6 }, false)
		local window = state:window("a")
		window.inventory.slots[36] = { item = DIRT, count = 12 }
		window.inventory.armor[4] = { item = Items.id.DiamondBoots, count = 1 }
		window.container.slots[27] = { item = STONE, count = 64 }
		local decoded = Protocol.decodeInventory(Protocol.encodeInventory(state:snapshot("a")))
		t.eq(decoded.ack, 41)
		t.eq(decoded.window, window.id)
		t.eq(decoded.inventory.selected, 6)
		t.eq(decoded.inventory.slots[36].count, 12)
		t.eq(decoded.inventory.armor[4].item, Items.id.DiamondBoots)
		t.eq(decoded.container.block, CHEST)
		t.eq(decoded.container.size, 27)
		t.eq(decoded.container.slots[27].count, 64)
	end)

	t.test("inventories: the 2 x 2 grid crafts, its result travels in snapshots, closing empties it", function()
		local state = newState()
		local window = state:window("a")
		window.inventory.slots[1] = { item = LOG, count = 2 }
		local log = Menu.windowIndex(window, "inventory", 1)
		local cell = Menu.windowIndex(window, "container", 2)
		state:apply("a", 1, { kind = "click", window = 0, slot = log, clickType = PICKUP, button = 0 }, false)
		state:apply("a", 2, { kind = "click", window = 0, slot = cell, clickType = PICKUP, button = 0 }, false)
		t.eq(window.container.slots[1].item, PLANKS, "the result is derived")
		local decoded = Protocol.decodeInventory(Protocol.encodeInventory(state:snapshot("a")))
		t.eq(decoded.container.kind, "inventory")
		t.eq(decoded.container.slots[1].item, PLANKS, "the snapshot carries the result")
		t.eq(decoded.container.slots[1].count, 4)
		t.eq(decoded.container.slots[2].item, LOG)

		-- Closing window 0 (the inventory screen shutting) puts the grid back and keeps id 0.
		local thrown = state:apply("a", 3, { kind = "close", window = 0 }, false)
		t.eq(#thrown, 0)
		t.eq(window.id, 0)
		t.eq(window.container.kind, "inventory")
		t.eq(window.container.slots[1], nil, "no result")
		t.eq(window.container.slots[2], nil, "the grid is empty")
		t.eq(count(window.inventory, LOG), 2, "the logs are back")
	end)

	t.test("inventories: opening a crafting table gives a personal 3 x 3 grid", function()
		local state = newState()
		state:window("a").inventory.slots[1] = { item = DIRT, count = 1 }
		local thrown = state:open("a", 5, 6, 7, TABLE)
		t.eq(#thrown, 0)
		state:open("b", 5, 6, 7, TABLE)
		local a, b = state:window("a"), state:window("b")
		t.eq(a.id, 1)
		t.eq(a.container.kind, "crafting")
		t.eq(a.container.size, 10)
		t.eq(a.container.block, TABLE)
		t.ok(a.container ~= b.container, "each player has their own grid")
		t.eq(state.containers:peek(5, 6, 7), nil, "nothing stored for the table")
		t.eq(#state.containers:viewers(5, 6, 7), 0, "and no viewers")
		local x, y, z = state:openPosition("a")
		t.eq(x, 5)
		t.eq(y, 6)
		t.eq(z, 7)
		local snapshot = state:snapshot("a")
		t.eq(snapshot.window, 1)
		t.eq(snapshot.container.kind, "crafting")

		-- a's clicks don't touch b.
		state:takeDirty()
		local dirt = Menu.windowIndex(a, "inventory", 1)
		state:apply("a", 1, { kind = "click", window = a.id, slot = dirt, clickType = QUICK_MOVE, button = 0 }, false)
		t.eq(a.container.slots[2].item, DIRT, "shift click into a's grid")
		t.eq(b.container.slots[2], nil, "not b's")
		local dirty = state:takeDirty()
		t.eq(#dirty, 1, "only a hears about it")

		-- Closing returns the grid to the inventory and makes window 0 again.
		thrown = state:close("a")
		t.eq(#thrown, 0)
		t.eq(a.id, 0)
		t.eq(a.container.kind, "inventory")
		t.eq(count(a.inventory, DIRT), 1, "the dirt is back")
		t.eq(state:openPosition("a"), nil)

		-- A block with no window opens nothing (and closes nothing).
		state:open("a", 0, 0, 0, CHEST)
		t.eq(#state:open("a", 9, 9, 9, Blocks.id.Stone), 0)
		t.eq(a.container.kind, "chest", "still the chest")
	end)

	t.test("inventories: a crafting table that goes closes its users' grids, items back", function()
		local state = newState()
		state:open("a", 1, 1, 1, TABLE)
		state:open("b", 2, 2, 2, TABLE)
		local a, b = state:window("a"), state:window("b")
		a.container.slots[2] = { item = LOG, count = 3 }
		a.container.slots[6] = { item = DIRT, count = 10 }
		a.inventory.cursor = { item = STONE, count = 2 }
		Menu.updateCraft(a)
		-- Only room for the cursor and the logs.
		for slot = 3, Types.INVENTORY_SIZE do
			a.inventory.slots[slot] = { item = STONE, count = 64 }
		end
		state:takeDirty()

		local contents, leftovers = state:removeContainer(1, 1, 1)
		t.eq(#contents, 0, "a table holds nothing itself")
		t.eq(#leftovers, 1)
		t.eq(leftovers[1].key, "a")
		t.eq(#leftovers[1].stacks, 1)
		t.eq(leftovers[1].stacks[1].item, DIRT, "what did not fit")
		t.eq(leftovers[1].stacks[1].count, 10)
		t.eq(a.id, 0)
		t.eq(a.container.kind, "inventory")
		t.eq(count(a.inventory, LOG), 3, "the logs came back")
		t.eq(count(a.inventory, STONE), 34 * 64 + 2, "the cursor came back")
		t.eq(b.container.kind, "crafting", "b's table elsewhere stays open")
		t.eq(#state:takeDirty(), 1)
	end)

	t.test("inventories: dying at a crafting table puts the grid back first, then drops it all", function()
		local state = newState()
		state:open("a", 1, 1, 1, TABLE)
		local window = state:window("a")
		window.container.slots[2] = { item = LOG, count = 3 }
		window.inventory.slots[1] = { item = DIRT, count = 5 }
		local dropped = state:die("a", false)
		local total = 0
		for _, stack in dropped do
			total += stack.count
		end
		t.eq(total, 8, "the grid's logs and the dirt")
		t.eq(window.id, 0)
		t.eq(next(window.container.slots), nil)

		local kept = newState()
		kept:open("a", 1, 1, 1, TABLE)
		kept:window("a").container.slots[2] = { item = LOG, count = 3 }
		t.eq(#kept:die("a", true), 0, "keepInventory")
		t.eq(count(kept:window("a").inventory, LOG), 3, "the logs are kept in the inventory")
	end)

	t.test("inventories: the held stack, and tools wearing until they break", function()
		local state = newState()
		local inventory = state:window("a").inventory
		t.eq(state:heldStack("a"), nil, "empty hand")
		t.eq(state:heldStack("nobody"), nil)
		inventory.slots[1] = { item = PICKAXE, count = 1 }
		t.eq(state:heldStack("a").item, PICKAXE)
		state:takeDirty()

		local durability = Items.get(PICKAXE).durability
		t.eq(durability, 59)
		t.ok(not state:wearHeld("a", 1), "one use")
		t.eq(inventory.slots[1].damage, 1)
		t.eq(#state:takeDirty(), 1, "a snapshot is due")
		local before = inventory.slots[1]
		t.ok(not state:wearHeld("a", 2), "a sword's two")
		t.eq(inventory.slots[1].damage, 3)
		t.eq(before.damage, 1, "a new stack table, the old one unchanged")
		t.ok(not state:wearHeld("a", 0), "nothing")
		t.ok(not state:wearHeld("a", -3), "nothing")
		t.ok(not state:wearHeld("a", 0 / 0), "nothing")
		t.eq(inventory.slots[1].damage, 3)
		inventory.slots[1] = { item = PICKAXE, count = 1, damage = durability - 2 }
		t.ok(not state:wearHeld("a", 1), "one use left")
		t.eq(inventory.slots[1].damage, durability - 1)
		t.ok(state:wearHeld("a", 1), "broken")
		t.eq(inventory.slots[1], nil, "gone")

		-- Only the selected slot, and only what wears.
		inventory.slots[2] = { item = PICKAXE, count = 1, damage = 4 }
		inventory.slots[1] = { item = DIRT, count = 5 }
		state:takeDirty()
		t.ok(not state:wearHeld("a", 1), "dirt does not wear")
		t.eq(inventory.slots[1].damage, nil)
		t.eq(#state:takeDirty(), 0, "nothing changed")
		inventory.selected = 2
		t.ok(state:wearHeld("a", 100), "a big hit breaks it")
		t.eq(inventory.slots[2], nil)
		t.ok(not state:wearHeld("nobody", 1))
	end)

	--[[ /gamemode ]]

	t.test("gamemode: permissions (command rule, admins, owner, Studio)", function()
		local allowed, isAdmin = GameModeCommand.allowed, GameModeCommand.isAdmin
		t.ok(allowed(5, true, false, false))
		t.ok(not allowed(5, false, false, false))
		t.ok(allowed(5, { 4, 5 }, false, false))
		t.ok(not allowed(6, { 4, 5 }, false, false))
		t.ok(allowed(6, false, true, false), "the owner always may")
		t.ok(allowed(6, false, false, true), "Studio always may")
		t.ok(isAdmin(5, { 5 }, false, false))
		t.ok(not isAdmin(5, {}, false, false))
		t.ok(isAdmin(5, {}, true, false))
		t.ok(isAdmin(5, {}, false, true))
	end)

	t.test("gamemode: only /gamemode and /gm are the command", function()
		t.ok(GameModeCommand.matches("/gamemode creative"))
		t.ok(GameModeCommand.matches("/GameMode 1"))
		t.ok(GameModeCommand.matches("/gm"))
		t.ok(GameModeCommand.matches("  /gm s"))
		t.ok(not GameModeCommand.matches("/gamemodes c"))
		t.ok(not GameModeCommand.matches("hello /gm c"))
		t.ok(not GameModeCommand.matches(""))
	end)

	local function players()
		local modes =
			{ alice = GameMode.SURVIVAL, alfred = GameMode.SURVIVAL, bob = GameMode.CREATIVE, al = GameMode.SURVIVAL }
		local list = {
			{ key = "alice", name = "Alice", displayName = "Ally" },
			{ key = "alfred", name = "Alfred", displayName = "Fred" },
			{ key = "bob", name = "Bob", displayName = "Builder" },
			{ key = "al", name = "Al", displayName = "Al" },
		}
		local function context(source: number, mayUse: boolean, mayTarget: boolean)
			return {
				source = list[source],
				players = list,
				mayUse = mayUse,
				mayTarget = mayTarget,
				modeOf = function(key)
					return modes[key]
				end,
			}
		end
		return context, modes
	end

	t.test("gamemode: changing your own game mode", function()
		local context = players()
		t.eq(GameModeCommand.run("hello", context(1, true, false)), nil, "ordinary chat")
		local result = GameModeCommand.run("/gamemode creative", context(1, true, false))
		t.eq(#result.changes, 1)
		t.eq(result.changes[1].key, "alice")
		t.eq(result.changes[1].mode, GameMode.CREATIVE)
		t.eq(result.feedback[1], "Set own game mode to Creative Mode")
		t.eq(#result.notices, 0)
		for _, word in { "c", "1", "CREATIVE" } do
			t.eq(GameModeCommand.run(`/gm {word}`, context(1, true, false)).changes[1].mode, GameMode.CREATIVE, word)
		end
		for _, word in { "s", "0", "survival" } do
			t.eq(GameModeCommand.run(`/gm {word}`, context(3, true, false)).changes[1].mode, GameMode.SURVIVAL, word)
		end
		result = GameModeCommand.run("/gm s", context(1, true, false))
		t.eq(#result.changes, 0)
		t.eq(result.feedback[1], "Your game mode is already Survival Mode")
	end)

	t.test("gamemode: refusals and mistakes", function()
		local context = players()
		local function says(text: string, ctx): string
			local result = GameModeCommand.run(text, ctx)
			t.eq(#result.changes, 0, text)
			return result.feedback[1]
		end
		t.eq(says("/gamemode creative", context(1, false, false)), GameModeCommand.DENIED)
		t.eq(says("/gamemode", context(1, true, false)), GameModeCommand.USAGE)
		t.eq(says("/gamemode creative Bob extra", context(1, true, true)), GameModeCommand.USAGE)
		t.ok(
			string.find(says("/gamemode adventure", context(1, true, false)), "Unknown game mode 'adventure'", 1, true)
		)
		t.eq(says("/gm c Bob", context(1, true, false)), GameModeCommand.DENIED_OTHERS)
		t.eq(says("/gm c @a", context(1, true, false)), GameModeCommand.DENIED_OTHERS)
		t.eq(says("/gm c zed", context(1, true, true)), GameModeCommand.NO_PLAYER)
		t.eq(says("/gm c alf zz", context(1, true, true)), GameModeCommand.USAGE)
		-- Admins may change their own mode where the command is off for everyone else.
		t.eq(#GameModeCommand.run("/gm c", context(1, false, true)).changes, 1)
		-- Naming yourself is not changing someone else.
		t.eq(#GameModeCommand.run("/gm c alice", context(1, true, false)).changes, 1)
		t.eq(#GameModeCommand.run("/gm c @s", context(1, true, false)).changes, 1)
	end)

	t.test("gamemode: admins change other players, found by name, display name or prefix", function()
		local context = players()
		local result = GameModeCommand.run("/gamemode survival bob", context(1, true, true))
		t.eq(result.changes[1].key, "bob")
		t.eq(result.changes[1].mode, GameMode.SURVIVAL)
		t.eq(result.feedback[1], "Set Builder's game mode to Survival Mode")
		t.eq(result.notices[1].key, "bob")
		t.eq(result.notices[1].text, "Your game mode has been updated to Survival Mode")

		t.eq(GameModeCommand.run("/gm s builder", context(1, true, true)).changes[1].key, "bob", "display name")
		t.eq(GameModeCommand.run("/gm c FRE", context(1, true, true)).changes[1].key, "alfred", "display name prefix")
		t.eq(GameModeCommand.run("/gm c alf", context(1, true, true)).changes[1].key, "alfred", "name prefix")
		t.eq(GameModeCommand.run("/gm c al", context(1, true, true)).changes[1].key, "al", "an exact name wins")
		local ambiguous = GameModeCommand.run("/gm c ali", context(3, true, true))
		t.eq(ambiguous.changes[1].key, "alice")
		ambiguous = GameModeCommand.run("/gm c a", context(3, true, true))
		t.eq(#ambiguous.changes, 0)
		t.eq(ambiguous.feedback[1], "'a' matches more than one player: Al, Alfred, Alice")

		local everyone = GameModeCommand.run("/gm creative @a", context(1, false, true))
		t.eq(#everyone.changes, 3, "bob already is creative")
		t.eq(#everyone.notices, 2, "the others hear about it")
		t.eq(everyone.feedback[1], "Set own game mode to Creative Mode")
		local nobody = GameModeCommand.run(
			"/gm 1 @a",
			(function()
				local ctx, modes = players()
				for key in modes do
					modes[key] = GameMode.CREATIVE
				end
				return ctx(1, true, true)
			end)()
		)
		t.eq(nobody.feedback[1], "Everyone is already in Creative Mode")
		t.eq(
			GameModeCommand.run("/gm s bob", context(1, true, true)).feedback[1],
			"Set Builder's game mode to Survival Mode"
		)
	end)

	--[[ Edits by game mode ]]

	t.test("edits: survival breaks need a Mine start on that block, long enough ago, with the tool", function()
		local stone, ironOre, dirt = Blocks.id.Stone, Blocks.id.IronOre, Blocks.id.Dirt
		local mine = { x = 1, y = 2, z = 3, startedAt = 100 }
		-- May a survival player who started mining (1, 2, 3) at 100 break `block` there at `now`?
		local function breaks(block: number, now: number, tool: number?): boolean
			return EditRules.mayBreak(block, false, mine, 1, 2, 3, now, tool)
		end
		local id = Items.id
		t.ok(not EditRules.mayBreak(stone, false, nil, 1, 2, 3, 200, id.WoodenPickaxe), "never started")
		t.ok(not EditRules.mayBreak(stone, false, mine, 1, 2, 4, 200, id.WoodenPickaxe), "another block")
		t.ok(not breaks(stone, 100, id.WoodenPickaxe), "just started")
		-- A wooden pickaxe (speed 2) on stone (hardness 1.5, harvested: / 30) takes 22.5 ticks; the
		-- server accepts 70% of that: 15 ticks, 0.75 s.
		t.ok(not breaks(stone, 100.7, id.WoodenPickaxe))
		t.ok(breaks(stone, 100.75, id.WoodenPickaxe))
		-- By hand stone is not harvested (/ 100): 150 ticks, accepted after 104 (5.2 s).
		t.ok(not breaks(stone, 101.55), "the old bare-handed time is too soon")
		t.ok(not breaks(stone, 105.15))
		t.ok(breaks(stone, 105.25))
		-- The wrong kind of tool is no better than a hand; better tiers are faster.
		t.ok(not breaks(stone, 105.15, id.DiamondAxe), "an axe")
		t.ok(not breaks(stone, 100.1, id.DiamondPickaxe))
		t.ok(breaks(stone, 100.15, id.DiamondPickaxe), "diamond: 3 ticks")
		t.ok(not breaks(stone, 100.05, id.GoldenPickaxe))
		t.ok(breaks(stone, 100.1, id.GoldenPickaxe), "gold: 2 ticks")
		-- Iron ore with a wooden pickaxe: mined at the tool's speed but not harvested (/ 100).
		t.ok(not breaks(ironOre, 103, id.WoodenPickaxe))
		t.ok(breaks(ironOre, 105.25, id.WoodenPickaxe), "105 ticks")
		-- A stone pickaxe (speed 4, harvested) on iron ore (hardness 3): 22.5 ticks, 15 accepted.
		t.ok(not breaks(ironOre, 100.7, id.StonePickaxe))
		t.ok(breaks(ironOre, 100.75, id.StonePickaxe))

		t.ok(not breaks(Blocks.id.Bedrock, 1e9), "bedrock never")
		t.ok(not EditRules.mayBreak(Blocks.id.Bedrock, true, nil, 1, 2, 3, 0), "not even in creative")
		t.ok(EditRules.mayBreak(stone, true, nil, 1, 2, 3, 0), "creative: at once")
		t.ok(EditRules.mayBreak(stone, true, nil, 1, 2, 3, 0, id.Stick), "whatever is in hand")
		t.ok(not EditRules.mayBreak(9999, true, nil, 1, 2, 3, 0), "unknown block")
		-- Dirt (0.5, no tool needed) by hand takes 15 ticks: 10 + 1 >= 10.5 after 10 ticks; a
		-- wooden shovel halves it (5 ticks).
		t.ok(not breaks(dirt, 100.45))
		t.ok(breaks(dirt, 100.5))
		t.ok(not breaks(dirt, 100.2, id.WoodenShovel))
		t.ok(breaks(dirt, 100.25, id.WoodenShovel))
		t.ok(not breaks(dirt, 100.45, id.Dirt), "a block in hand is a hand")
		-- Blocks without hardness break as soon as mining starts.
		for block = 0, Blocks.count - 1 do
			local def = Blocks.get(block)
			if def.breakable and def.hardness == 0 then
				t.ok(breaks(block, 100), def.name)
			end
		end
	end)

	t.test("edits: placing, drops by tool, and blocks with windows", function()
		local AIR = Blocks.AIR
		local water = Blocks.fluidId("Water", 0)
		t.ok(EditRules.mayPlace(Blocks.id.Stone, AIR))
		t.ok(EditRules.mayPlace(water, AIR), "water can be placed (creative)")
		t.ok(EditRules.mayPlace(Blocks.id.Stone, water), "into water")
		t.ok(not EditRules.mayPlace(Blocks.id.Stone, Blocks.id.Dirt), "not into a solid block")
		t.ok(not EditRules.mayPlace(water, water), "not the same block")
		t.ok(not EditRules.mayPlace(Blocks.id.Bedrock, AIR), "bedrock is not placeable")
		t.ok(not EditRules.mayPlace(9999, AIR))

		local function drop(block: number, tool: number?): (number?, number?)
			local stack = EditRules.drops(block, false, tool)
			return if stack then stack.item else nil, if stack then stack.count else nil
		end
		t.eq(drop(Blocks.id.Stone), nil, "stone by hand drops nothing")
		t.eq(drop(Blocks.id.Stone, Items.id.WoodenPickaxe), Items.id.Cobblestone)
		t.eq(drop(Blocks.id.Stone, Items.id.WoodenShovel), nil, "the wrong tool")
		t.eq(drop(Blocks.id.Stone, Items.id.Cobblestone), nil, "a block in hand")
		t.eq(drop(Blocks.id.IronOre, Items.id.WoodenPickaxe), nil, "iron needs a stone pickaxe")
		t.eq(drop(Blocks.id.IronOre, Items.id.GoldenPickaxe), nil, "gold is wood's tier")
		t.eq(drop(Blocks.id.IronOre, Items.id.StonePickaxe), Items.id.RawIron)
		t.eq(drop(Blocks.id.DiamondOre, Items.id.StonePickaxe), nil)
		t.eq(drop(Blocks.id.DiamondOre, Items.id.IronPickaxe), Items.id.Diamond)
		t.eq(drop(Blocks.id.CoalOre, Items.id.WoodenPickaxe), Items.id.Coal)
		t.eq(drop(Blocks.id.Dirt), Items.id.Dirt, "dirt needs no tool")
		t.eq(drop(Blocks.id.OakLog, Items.id.DiamondSword), Items.id.OakLog, "nor do logs")
		t.eq(drop(Blocks.id.Glass, Items.id.DiamondPickaxe), nil, "glass drops nothing")
		t.eq(drop(Blocks.id.Furnace), nil, "a furnace needs a pickaxe")
		t.eq(drop(Blocks.id.Furnace, Items.id.WoodenPickaxe), Items.id.Furnace)
		t.eq(drop(CHEST), Items.id.Chest, "chests and tables come off by hand")
		t.eq(drop(TABLE), Items.id.CraftingTable)
		t.eq(EditRules.drops(Blocks.id.Stone, true, Items.id.DiamondPickaxe), nil, "creative: no drops")

		-- Windows close when their block goes; only containers hold items to drop.
		t.ok(EditRules.hasMenu(CHEST))
		t.ok(EditRules.hasMenu(FURNACE))
		t.ok(EditRules.hasMenu(TABLE), "a crafting table has a window")
		t.ok(not EditRules.hasMenu(Blocks.id.Stone))
		t.ok(not EditRules.hasMenu(9999))
		t.ok(EditRules.isContainer(CHEST))
		t.ok(EditRules.isContainer(FURNACE))
		t.ok(not EditRules.isContainer(TABLE), "but holds nothing")
		t.ok(not EditRules.isContainer(Blocks.id.Stone))
		t.ok(not EditRules.isContainer(9999))
	end)

	t.test("edits: survival breaks wear the tool in hand, creative ones never", function()
		local stone = Blocks.id.Stone
		t.eq(EditRules.wear(stone, false, Items.id.WoodenPickaxe), 1)
		t.eq(EditRules.wear(Blocks.id.Dirt, false, PICKAXE), 1, "the wrong tool wears too")
		t.eq(EditRules.wear(stone, false, Items.id.IronSword), 2, "swords take two")
		t.eq(EditRules.wear(Blocks.id.OakLeaves, false, Items.id.WoodenHoe), 1)
		t.eq(EditRules.wear(stone, false, nil), 0, "a hand")
		t.eq(EditRules.wear(stone, false, Items.id.Dirt), 0, "a block")
		t.eq(EditRules.wear(stone, true, Items.id.WoodenPickaxe), 0, "creative")
		t.eq(EditRules.wear(9999, false, Items.id.WoodenPickaxe), 0, "unknown block")
		for id = 0, Blocks.count - 1 do
			local def = Blocks.get(id)
			if def.breakable and def.hardness == 0 then
				t.eq(EditRules.wear(id, false, Items.id.DiamondPickaxe), 0, `{def.name} breaks at once`)
			end
		end

		-- With the inventory: a wooden pickaxe lasts 59 stone blocks.
		local state = InventoryState.new()
		state:join("a")
		local inventory = state:window("a").inventory
		inventory.slots[1] = { item = PICKAXE, count = 1 }
		local broken, uses = false, 0
		while not broken and uses < 100 do
			local held = state:heldStack("a")
			local wear = EditRules.wear(stone, false, held and held.item)
			local drop = EditRules.drops(stone, false, held and held.item)
			t.eq(drop and drop.item, Items.id.Cobblestone, "harvested")
			broken = state:wearHeld("a", wear)
			uses += 1
		end
		t.eq(uses, 59)
		t.eq(state:heldStack("a"), nil, "broken: an empty hand")
		t.eq(EditRules.drops(stone, false, nil), nil, "and stone drops nothing now")
	end)
end

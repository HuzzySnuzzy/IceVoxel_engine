--[[
	Client inventory: prediction by replay (Inventory/Prediction) and the screens' Minecraft click
	logic (Ui/SlotClicks): clicks, drags, double clicks, keys, throws and the creative grid.
]]

return function(t, shared, require, _server, client)
	local Items = require(shared.Items)
	local Types = require(shared.Inventory.Types)
	local Menu = require(shared.Inventory.Menu)
	local Prediction = require(client.Inventory.Prediction)
	local SlotClicks = require(client.Ui.SlotClicks)

	local DIRT, STONE, PLANKS = Items.id.Dirt, Items.id.Stone, Items.id.Planks
	local HELMET = Items.id.IronHelmet
	local Click = Menu.ClickType
	local LEFT, RIGHT, MIDDLE = 0, 1, 2

	local function S(item: number, count: number)
		return { item = item, count = count }
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

	local function snapshot(ack: number, slots, extra)
		local inventory = Types.newInventory()
		for slot, stack in slots do
			inventory.slots[slot] = stack
		end
		local snap = { ack = ack, inventory = inventory, window = 0, container = nil }
		if extra then
			for key, value in extra do
				snap[key] = value
			end
		end
		return snap
	end

	-- Window slot of inventory slot i (1-9 hotbar, 10-36) in window `w`.
	local function inv(w, i: number): number
		return Menu.windowIndex(w, "inventory", i)
	end

	--[[ Prediction ]]

	t.test("prediction: local actions are numbered from 1 and show at once", function()
		local p = Prediction.new()
		p:receive(snapshot(0, { [1] = S(DIRT, 10) }), false)
		local w = p:window()
		local seq =
			p:push({ kind = "click", window = 0, slot = inv(w, 1), clickType = Click.Pickup, button = 0 }, false)
		t.eq(seq, 1, "first seq")
		is(p:window().inventory.cursor, DIRT, 10, "cursor")
		is(p:window().inventory.slots[1], nil, nil, "slot 1")
		t.eq(p:push({ kind = "select", slot = 3 }, false), 2, "second seq")
		t.eq(p:window().inventory.selected, 3, "selected")
		t.eq(#p.pending, 2, "pending")
	end)

	t.test("prediction: snapshots drop acknowledged actions and replay the rest", function()
		local p = Prediction.new()
		p:receive(snapshot(0, { [1] = S(DIRT, 10) }), false)
		local w = p:window()
		p:push({ kind = "click", window = 0, slot = inv(w, 1), clickType = Click.Pickup, button = 0 }, false)
		p:push({ kind = "click", window = 0, slot = inv(w, 2), clickType = Click.Pickup, button = 1 }, false)
		is(p:window().inventory.slots[2], DIRT, 1, "predicted slot 2")
		-- The server has done the first click only (and something else gave a stone).
		local inventory = { [2] = nil, [5] = S(STONE, 3) }
		local snap = snapshot(1, inventory)
		snap.inventory.cursor = S(DIRT, 10)
		p:receive(snap, false)
		t.eq(#p.pending, 1, "one pending left")
		is(p:window().inventory.slots[2], DIRT, 1, "replayed right click")
		is(p:window().inventory.cursor, DIRT, 9, "cursor after replay")
		is(p:window().inventory.slots[5], STONE, 3, "server's change kept")
		-- Everything acknowledged: the prediction is the snapshot.
		local final = snapshot(2, { [2] = S(DIRT, 1) })
		final.inventory.cursor = S(DIRT, 9)
		p:receive(final, false)
		t.eq(#p.pending, 0, "nothing pending")
		is(p:window().inventory.slots[2], DIRT, 1, "slot 2")
	end)

	t.test("prediction: the server's answer wins when it refused an action", function()
		local p = Prediction.new()
		p:receive(snapshot(0, { [1] = S(DIRT, 5) }), false)
		p:push({ kind = "place", item = DIRT }, false)
		is(p:window().inventory.slots[1], DIRT, 4, "predicted use")
		-- The placement was rejected: the server acknowledges it without using the item.
		p:receive(snapshot(1, { [1] = S(DIRT, 5) }), false)
		is(p:window().inventory.slots[1], DIRT, 5, "undone")
	end)

	t.test("prediction: snapshots never mutate and copies are independent", function()
		local p = Prediction.new()
		local snap = snapshot(0, { [1] = S(DIRT, 5) })
		p:receive(snap, false)
		p:push({ kind = "drop", all = true }, false)
		is(snap.inventory.slots[1], DIRT, 5, "snapshot untouched")
		is(p:window().inventory.slots[1], nil, nil, "dropped in the prediction")
	end)

	t.test("prediction: place uses one up in survival only", function()
		local p = Prediction.new()
		p:receive(snapshot(0, { [1] = S(PLANKS, 2) }), true)
		p:push({ kind = "place", item = PLANKS }, true)
		is(p:window().inventory.slots[1], PLANKS, 2, "creative keeps it")
		p:replay(false)
		is(p:window().inventory.slots[1], PLANKS, 1, "survival replay uses one")
	end)

	t.test("prediction: container windows and closing", function()
		local p = Prediction.new()
		local snap = snapshot(0, { [1] = S(DIRT, 8) }, {
			window = 7,
			container = { block = Items.id.Chest, size = 27, slots = { [1] = S(STONE, 4) } },
		})
		p:receive(snap, false)
		local w = p:window()
		t.eq(w.id, 7, "window id from the snapshot")
		-- Shift click the chest's stone into the inventory.
		p:push({ kind = "click", window = 7, slot = 0, clickType = Click.QuickMove, button = 0 }, false)
		is(p:window().container.slots[1], nil, nil, "chest slot emptied")
		local found = false
		for slot = 1, 36 do
			local stack = p:window().inventory.slots[slot]
			if stack and stack.item == STONE and stack.count == 4 then
				found = true
			end
		end
		t.ok(found, "stone moved into the inventory")
		-- Closing resets the prediction to window 0, even when a snapshot from before the close
		-- still shows the chest open.
		p:push({ kind = "close", window = 7 }, false)
		t.eq(p:window().id, 0, "closed")
		t.ok(p:window().container == nil, "no container")
		p:receive(snapshot(1, { [1] = S(DIRT, 8) }, { window = 7, container = snap.container }), false)
		t.eq(p:window().id, 0, "still closed after an older snapshot")
		-- A click for the old window does nothing on window 0.
		p:push({ kind = "click", window = 7, slot = 0, clickType = Click.Pickup, button = 0 }, false)
		is(p:window().inventory.cursor, nil, nil, "stale window click ignored")
	end)

	t.test("prediction: sequence numbers never repeat what the server saw", function()
		local p = Prediction.new()
		p:receive(snapshot(41, {}), false)
		t.eq(p:push({ kind = "select", slot = 2 }, false), 42, "continues after the ack")
	end)

	t.test("prediction: creative actions replay with the current game mode", function()
		local p = Prediction.new()
		p:receive(snapshot(0, {}), true)
		p:push({ kind = "creative", window = 0, slot = Types.CURSOR, item = STONE, count = 64 }, true)
		is(p:window().inventory.cursor, STONE, 64, "creative cursor")
		p:replay(false)
		is(p:window().inventory.cursor, nil, nil, "not in survival")
	end)

	--[[ Slot clicks ]]

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

	local function newWindow(slots, size: number?)
		local window = { id = 0, inventory = Types.newInventory(), container = nil }
		for slot, stack in slots do
			window.inventory.slots[slot] = stack
		end
		if size then
			window.id = 3
			window.container = { block = Items.id.Chest, size = size, slots = {} }
		end
		return window
	end

	local function slot(index: number)
		return { kind = "slot", index = index }
	end
	local OUT = { kind = "outside" }

	t.test("clicks: left press takes the stack at once and the release does nothing", function()
		local w = newWindow({ [10] = S(DIRT, 20) })
		local host, log = newHost(w)
		local clicks = SlotClicks.new(host)
		clicks:press(slot(inv(w, 10)), LEFT, false, 0)
		is(w.inventory.cursor, DIRT, 20, "cursor")
		clicks:release(slot(inv(w, 11)), LEFT, false, 0.1)
		t.eq(#log.actions, 1, "one action")
		is(w.inventory.slots[11], nil, nil, "nothing placed on release")
	end)

	t.test("clicks: right press takes half, rounded up", function()
		local w = newWindow({ [10] = S(DIRT, 5) })
		local clicks = SlotClicks.new((newHost(w)))
		clicks:click(slot(inv(w, 10)), RIGHT, false, 0)
		is(w.inventory.cursor, DIRT, 3, "cursor")
		is(w.inventory.slots[10], DIRT, 2, "left behind")
	end)

	t.test("clicks: a carried stack is placed on release (all, or one with right)", function()
		local w = newWindow({})
		w.inventory.cursor = S(DIRT, 10)
		local clicks = SlotClicks.new((newHost(w)))
		clicks:press(slot(inv(w, 12)), RIGHT, false, 0)
		is(w.inventory.slots[12], nil, nil, "nothing on press")
		clicks:release(slot(inv(w, 12)), RIGHT, false, 0.05)
		is(w.inventory.slots[12], DIRT, 1, "one placed")
		clicks:click(slot(inv(w, 13)), LEFT, false, 1)
		is(w.inventory.slots[13], DIRT, 9, "rest placed")
		is(w.inventory.cursor, nil, nil, "cursor empty")
	end)

	t.test("clicks: dragging splits the stack evenly, the rest stays carried", function()
		local w = newWindow({ [12] = S(DIRT, 3) })
		w.inventory.cursor = S(DIRT, 64)
		local host, log = newHost(w)
		local clicks = SlotClicks.new(host)
		clicks:press(slot(inv(w, 10)), LEFT, false, 0)
		clicks:move(slot(inv(w, 10)))
		clicks:move(slot(inv(w, 11)))
		clicks:move(slot(inv(w, 11)))
		clicks:move(nil)
		clicks:move(slot(inv(w, 12)))
		local mode, dragged = clicks:dragging()
		t.eq(mode, 0, "split mode")
		t.eq(#dragged, 3, "three slots")
		clicks:release(slot(inv(w, 12)), LEFT, false, 0.5)
		t.eq(log.actions[1].kind, "drag", "one drag action")
		is(w.inventory.slots[10], DIRT, 21, "slot 10")
		is(w.inventory.slots[11], DIRT, 21, "slot 11")
		is(w.inventory.slots[12], DIRT, 24, "slot 12 (had 3)")
		is(w.inventory.cursor, DIRT, 1, "remainder")
	end)

	t.test("clicks: right drag puts one in each slot and stops when the stack runs out", function()
		local w = newWindow({ [11] = S(STONE, 1) })
		w.inventory.cursor = S(DIRT, 2)
		local clicks = SlotClicks.new((newHost(w)))
		clicks:press(slot(inv(w, 10)), RIGHT, false, 0)
		clicks:move(slot(inv(w, 10)))
		clicks:move(slot(inv(w, 11))) -- another item: skipped
		clicks:move(slot(inv(w, 12)))
		clicks:move(slot(inv(w, 13))) -- only 2 items: no third slot
		local _, dragged = clicks:dragging()
		t.eq(#dragged, 2, "two slots")
		clicks:release(slot(inv(w, 13)), RIGHT, false, 0.5)
		is(w.inventory.slots[10], DIRT, 1, "slot 10")
		is(w.inventory.slots[12], DIRT, 1, "slot 12")
		is(w.inventory.slots[13], nil, nil, "slot 13")
		is(w.inventory.cursor, nil, nil, "cursor used up")
	end)

	t.test("clicks: armor slots only join a drag with their armor", function()
		local w = newWindow({})
		w.inventory.cursor = S(DIRT, 10)
		local clicks = SlotClicks.new((newHost(w)))
		clicks:press(slot(0), LEFT, false, 0)
		clicks:move(slot(0)) -- head slot
		clicks:move(slot(inv(w, 10)))
		local _, dragged = clicks:dragging()
		t.eq(#dragged, 1, "armor slot refused")
	end)

	t.test("clicks: a drag over one slot is a plain click; another button cancels it", function()
		local w = newWindow({})
		w.inventory.cursor = S(DIRT, 10)
		local clicks = SlotClicks.new((newHost(w)))
		clicks:press(slot(inv(w, 10)), LEFT, false, 0)
		clicks:move(slot(inv(w, 10)))
		clicks:release(slot(inv(w, 10)), LEFT, false, 0.3)
		is(w.inventory.slots[10], DIRT, 10, "all placed")
		w.inventory.cursor = S(STONE, 4)
		clicks:press(slot(inv(w, 11)), LEFT, false, 1)
		clicks:move(slot(inv(w, 11)))
		clicks:move(slot(inv(w, 12)))
		clicks:press(slot(inv(w, 12)), RIGHT, false, 1.1)
		clicks:release(slot(inv(w, 12)), RIGHT, false, 1.2)
		is(w.inventory.cursor, STONE, 4, "cancelled")
		is(w.inventory.slots[11], nil, nil, "slot 11 untouched")
		clicks:release(slot(inv(w, 12)), LEFT, false, 1.3)
		is(w.inventory.cursor, STONE, 4, "left release skipped")
	end)

	t.test("clicks: double click gathers the item onto the cursor", function()
		local w = newWindow({ [10] = S(DIRT, 10), [20] = S(DIRT, 30), [30] = S(DIRT, 64), [5] = S(DIRT, 5) })
		local host, log = newHost(w)
		local clicks = SlotClicks.new(host)
		clicks:press(slot(inv(w, 10)), LEFT, false, 0)
		clicks:release(slot(inv(w, 10)), LEFT, false, 0.05)
		clicks:press(slot(inv(w, 10)), LEFT, false, 0.15)
		clicks:release(slot(inv(w, 10)), LEFT, false, 0.2)
		t.eq(log.actions[2].clickType, Click.PickupAll, "pickup all")
		-- 10 + 30 + 5 (full stacks are skipped in the first pass), then 19 from the full stack.
		is(w.inventory.cursor, DIRT, 64, "cursor full")
		is(w.inventory.slots[30], DIRT, 45, "full stack used last")
	end)

	t.test("clicks: slow second clicks or other slots are not double clicks", function()
		local w = newWindow({ [10] = S(DIRT, 10), [20] = S(DIRT, 30) })
		local host, log = newHost(w)
		local clicks = SlotClicks.new(host)
		clicks:click(slot(inv(w, 10)), LEFT, false, 0)
		clicks:click(slot(inv(w, 10)), LEFT, false, 0.6)
		t.eq(#log.actions, 2, "two clicks")
		t.eq(log.actions[2].clickType, Click.Pickup, "second is a pickup")
		is(w.inventory.slots[10], DIRT, 10, "put back")
	end)

	t.test("clicks: shift click quick moves; shift double click with a carried stack moves them all", function()
		local w = newWindow({ [10] = S(DIRT, 10), [11] = S(DIRT, 7), [12] = S(STONE, 1) }, 27)
		local clicks = SlotClicks.new((newHost(w)))
		clicks:click(slot(inv(w, 12)), LEFT, true, 0)
		is(w.container.slots[1], STONE, 1, "stone into the chest")
		w.inventory.cursor = S(DIRT, 1)
		clicks:press(slot(inv(w, 10)), LEFT, true, 1)
		clicks:release(slot(inv(w, 10)), LEFT, true, 1.05)
		clicks:press(slot(inv(w, 10)), LEFT, true, 1.1)
		clicks:release(slot(inv(w, 10)), LEFT, true, 1.15)
		is(w.inventory.slots[10], nil, nil, "slot 10 moved")
		is(w.inventory.slots[11], nil, nil, "slot 11 moved")
		is(w.container.slots[2], DIRT, 17, "both in the chest")
	end)

	t.test("clicks: releasing outside throws the carried stack", function()
		local w = newWindow({})
		w.inventory.cursor = S(DIRT, 10)
		local host, log = newHost(w)
		local clicks = SlotClicks.new(host)
		clicks:click(OUT, RIGHT, false, 0)
		is(w.inventory.cursor, DIRT, 9, "one thrown")
		clicks:click(OUT, LEFT, false, 1)
		is(w.inventory.cursor, nil, nil, "all thrown")
		t.eq(#log.thrown, 2, "two throws")
		t.eq(log.thrown[2].count, 9, "the rest")
		-- On a panel (no slot) nothing happens.
		w.inventory.cursor = S(DIRT, 3)
		clicks:click(nil, LEFT, false, 2)
		is(w.inventory.cursor, DIRT, 3, "kept")
		-- Outside with nothing carried does nothing either.
		w.inventory.cursor = nil
		local before = #log.actions
		clicks:click(OUT, LEFT, false, 3)
		t.eq(#log.actions, before, "no action")
	end)

	t.test("clicks: number keys swap, Q throws one, Ctrl+Q the stack", function()
		local w = newWindow({ [15] = S(DIRT, 10), [3] = S(STONE, 2) })
		local host, log = newHost(w)
		local clicks = SlotClicks.new(host)
		clicks:hotbarKey(slot(inv(w, 15)), 3)
		is(w.inventory.slots[3], DIRT, 10, "dirt in hotbar 3")
		is(w.inventory.slots[15], STONE, 2, "stone in slot 15")
		clicks:throwKey(slot(inv(w, 3)), false)
		is(w.inventory.slots[3], DIRT, 9, "one thrown")
		clicks:throwKey(slot(inv(w, 3)), true)
		is(w.inventory.slots[3], nil, nil, "stack thrown")
		t.eq(#log.thrown, 2, "two throws")
		-- Not with a carried stack.
		w.inventory.cursor = S(PLANKS, 1)
		local before = #log.actions
		clicks:hotbarKey(slot(inv(w, 15)), 1)
		clicks:throwKey(slot(inv(w, 15)), false)
		t.eq(#log.actions, before, "ignored")
	end)

	t.test("clicks: middle click clones in creative only", function()
		local w = newWindow({ [10] = S(DIRT, 1) })
		local host, log = newHost(w, false)
		local clicks = SlotClicks.new(host)
		clicks:click(slot(inv(w, 10)), MIDDLE, false, 0)
		t.eq(#log.actions, 0, "survival: nothing sent")
		local cw = newWindow({ [10] = S(DIRT, 1) })
		local creativeClicks = SlotClicks.new((newHost(cw, true)))
		creativeClicks:click(slot(inv(cw, 10)), MIDDLE, false, 0)
		is(cw.inventory.cursor, DIRT, 64, "full stack")
	end)

	t.test("clicks: the creative grid gives full stacks and deletes carried ones", function()
		local w = newWindow({})
		w.inventory.selected = 4
		local host, log = newHost(w, true)
		local clicks = SlotClicks.new(host)
		local grid = { kind = "grid", item = STONE }
		clicks:click(grid, LEFT, false, 0)
		is(w.inventory.cursor, STONE, 64, "full stack on the cursor")
		clicks:click(grid, RIGHT, false, 1)
		is(w.inventory.cursor, STONE, 63, "right click deletes one")
		clicks:click({ kind = "grid", item = DIRT }, LEFT, false, 2)
		is(w.inventory.cursor, nil, nil, "left click deletes it")
		clicks:click(grid, LEFT, true, 3)
		is(w.inventory.slots[4], STONE, 64, "shift: into the selected hotbar slot")
		is(w.inventory.cursor, nil, nil, "cursor still empty")
		clicks:hotbarKey({ kind = "grid", item = HELMET }, 9)
		is(w.inventory.slots[9], HELMET, 1, "number key: into that hotbar slot")
		clicks:throwKey(grid, true)
		t.eq(#log.thrown, 1, "thrown")
		is(log.thrown[1], STONE, 64, "a full stack thrown")
		is(w.inventory.cursor, nil, nil, "cursor empty after the throw")
		-- Double clicks never gather from the grid.
		clicks:press(grid, LEFT, false, 10)
		clicks:release(grid, LEFT, false, 10.01)
		clicks:press(grid, LEFT, false, 10.1)
		clicks:release(grid, LEFT, false, 10.11)
		is(w.inventory.cursor, nil, nil, "second click deleted the stack")
	end)

	t.test("clicks: the creative grid does nothing in survival", function()
		local w = newWindow({})
		local host, log = newHost(w, false)
		local clicks = SlotClicks.new(host)
		clicks:click({ kind = "grid", item = STONE }, LEFT, false, 0)
		clicks:hotbarKey({ kind = "grid", item = STONE }, 1)
		clicks:throwKey({ kind = "grid", item = STONE }, false)
		t.eq(#log.actions, 0, "no actions")
	end)

	t.test("clicks: a fuzz of random input never errors and conserves items", function()
		-- A small deterministic generator (Lune has no Random).
		local seed = 7
		local function nextNumber(): number
			seed = (seed * 16807) % 2147483647
			return seed / 2147483647
		end
		local function nextInteger(low: number, high: number): number
			return low + math.floor(nextNumber() * (high - low + 1))
		end
		local function total(w)
			local n = 0
			for i = 1, 36 do
				local stack = w.inventory.slots[i]
				n += if stack then stack.count else 0
			end
			for i = 1, 4 do
				local stack = w.inventory.armor[i]
				n += if stack then stack.count else 0
			end
			if w.container then
				for i = 1, w.container.size do
					local stack = w.container.slots[i]
					n += if stack then stack.count else 0
				end
			end
			local cursor = w.inventory.cursor
			return n + (if cursor then cursor.count else 0)
		end
		local items = { DIRT, STONE, PLANKS, HELMET }
		for round = 1, 30 do
			local w = newWindow({}, if round % 2 == 0 then 27 else nil)
			for i = 1, 36 do
				if nextNumber() < 0.5 then
					local item = items[nextInteger(1, #items)]
					w.inventory.slots[i] = S(item, nextInteger(1, Items.maxStack(item)))
				end
			end
			local host, log = newHost(w, false)
			local clicks = SlotClicks.new(host)
			local start = total(w)
			local now = 0
			local function randomTarget()
				local r = nextNumber()
				if r < 0.05 then
					return nil
				elseif r < 0.1 then
					return OUT
				end
				return slot(nextInteger(0, Menu.size(w) - 1))
			end
			for _ = 1, 300 do
				now += nextNumber() * 0.3
				local r = nextNumber()
				local button = nextInteger(0, 2)
				local shift = nextNumber() < 0.2
				if r < 0.3 then
					clicks:press(randomTarget(), button, shift, now)
				elseif r < 0.6 then
					clicks:move(randomTarget())
				elseif r < 0.85 then
					clicks:release(randomTarget(), button, shift, now)
				elseif r < 0.95 then
					clicks:hotbarKey(randomTarget(), nextInteger(1, 9))
				else
					clicks:throwKey(randomTarget(), nextNumber() < 0.5)
				end
			end
			local thrown = 0
			for _, stack in log.thrown do
				thrown += stack.count
			end
			t.eq(total(w) + thrown, start, `round {round}: items conserved`)
		end
	end)
end

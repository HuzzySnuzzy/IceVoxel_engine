--[[
	The client side of Mekanism's machines and Universal Cables, beyond tests/spec/Machines and
	Energy: the energy bar only looks full when it is (Mekanism's rounding down), a panel's status
	line reads the window's data without changing it, WAILA tells a cable side set to push or pull
	that it acts as normal, and F3's menu line counts a machine's slots (its kind's).
]]

local FakeMachines = require("../lib/FakeMachines")

return function(t, shared, require, _server, client)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local Smelting = require(shared.Crafting.Smelting)
	local Transmitters = require(shared.Transmitters)
	local MenuLayout = require(client.Ui.MenuLayout)
	local WailaInfo = require(client.Ui.WailaInfo)

	local B = Blocks.id
	local M = Transmitters.MODES
	local WEST, EAST = 4, 5
	local CABLE = B.BasicUniversalCable
	local PIPE = B.BasicMechanicalPipe
	local FURNACE_BLOCK = B.DiamondBlock
	FakeMachines.define(Machines, Items, Smelting)

	local function bit(side: number): number
		return bit32.lshift(1, side)
	end

	t.test("energy bar: full only when full, a sliver while it holds any", function()
		local function rows(energy: number, capacity: number): number
			return MenuLayout.energyRows({ energy, capacity, 0, 0, 0, 0 }, 52)
		end
		t.eq(rows(999, 1000), 51, "99.9 %: not full yet")
		t.eq(rows(1000, 1000), 52, "full")
		t.eq(rows(1, 52), 1, "one row's worth")
		t.eq(rows(1, 53), 1, "less than a row: still a sliver")
		t.eq(rows(26, 52), 26)
		t.eq(rows(0, 1000), 0, "empty")
		t.eq(rows(2000, 1000), 52, "over capacity: full")
		t.eq(rows(math.huge, math.huge), 52, "creative: full")
	end)

	t.test("panels: the status line reads the window's data and never writes it", function()
		FakeMachines.bind(
			Machines,
			{ { FURNACE_BLOCK, "test_furnace", { capacity = 20000, input = 20000 } } },
			function()
				-- (A window as the client holds it: read only, possibly without data.)
				local bare = { kind = "machine", block = FURNACE_BLOCK, size = 3, slots = {}, data = nil }
				t.eq(MenuLayout.statusText(bare :: any), "Idle")
				t.eq(bare.data, nil, "no data written into the client's window")
				local data = Machines.newData(FURNACE_BLOCK)
				local copy = table.clone(data)
				local container = { kind = "machine", block = FURNACE_BLOCK, size = 3, slots = {}, data = data }
				t.eq(MenuLayout.statusText(container :: any), "Idle")
				t.ok(container.data == data, "the same table")
				for i, v in copy do
					t.eq(data[i], v, `data[{i}] unchanged`)
				end
			end
		)
		-- The creative cube's own status line.
		local cube = { kind = "machine", block = B.CreativeEnergyCube, size = 0, slots = {}, data = nil }
		t.eq(MenuLayout.statusText(cube :: any), "Infinite energy")
		t.eq(cube.data, nil)
	end)

	t.test("waila: a cable's push and pull sides say they act as normal", function()
		local function sideText(block: number, mode: number): string?
			local facts = {
				modes = Transmitters.withMode(0, EAST, mode),
				colour = 0,
				fluid = 0,
				side = EAST,
				items = 0,
				stacks = 0,
				transmitters = bit(WEST),
				acceptors = 0,
				networkSize = 1,
				networkCapacity = 0,
				networkComplete = true,
			}
			for _, text in WailaInfo.texts(WailaInfo.block(block, nil, 0, 64, 0, false, { transmitter = facts })) do
				if string.sub(text, 1, 6) == "Side: " then
					return text
				end
			end
			return nil
		end
		t.eq(sideText(CABLE, M.PUSH), "Side: Push (as Normal)")
		t.eq(sideText(CABLE, M.PULL), "Side: Pull (as Normal)")
		t.eq(sideText(CABLE, M.NORMAL), "Side: Normal")
		t.eq(sideText(CABLE, M.NONE), "Side: None", "NONE cuts a cable as it does a pipe")
		t.eq(sideText(PIPE, M.PUSH), "Side: Push", "pipes push")
	end)

	t.test("waila: F3's menu line counts a machine's slots (its kind's)", function()
		local function menuLine(block: number): string?
			for _, text in WailaInfo.texts(WailaInfo.block(block, nil, 0, 64, 0, true, nil)) do
				if string.sub(text, 1, 5) == "Menu " then
					return text
				end
			end
			return nil
		end
		-- (The count is Machines.containerSize: a kind's slots, else BlockList's `container`. The
		-- only machine block so far, the creative cube, has none; later phases' machines do.)
		t.eq(menuLine(B.CreativeEnergyCube), "Menu Machine", "no slots")
		t.eq(menuLine(B.Chest), "Menu Chest, 27 slots", "chests unchanged")
		t.eq(menuLine(B.Furnace), "Menu Furnace, 3 slots", "furnaces unchanged")
		t.eq(menuLine(B.Stone), nil, "no menu")
	end)
end

--[[
	Item pipes and furnaces / machines: Mekanism's machine rules (Transmitters/Inventories,
	server Transmitters/Transport and Transmitters/Eject), run on the real TransmitterWorld,
	MachineWorld and Containers with furnaces cooking as Players/Inventories ticks them.

	A transporter pulling from a furnace only takes its results (never the fuel or ore a player
	put in, the report that started this), an empty bucket leaves the fuel slot, furnaces push
	their results out on their own (into chests next to them, into NORMAL and PULL transporter
	sides, never through PUSH or NONE, never straight into another furnace or machine, never
	without a destination, with the transporter's colour), the Electric Furnace in and out through
	any face with its upgrade cards out of reach, the Heat Generator as before, the push into chests
	reading only blocks the server knows, a chest and a transporter sharing one furnace, and a
	conservation fuzz.
]]

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Coords = require(shared.World.Coords)
	local Hash = require(shared.Util.Hash)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local Menu = require(shared.Inventory.Menu)
	local Protocol = require(shared.Net.Protocol)
	local Smelting = require(shared.Crafting.Smelting)
	local Transmitters = require(shared.Transmitters)
	local Types = require(shared.Inventory.Types)
	local Containers = require(server.Players.Containers)
	local Eject = require(server.Transmitters.Eject)
	local MachineWorld = require(server.Machines.MachineWorld)
	local TransmitterWorld = require(server.Transmitters.TransmitterWorld)

	local B, I = Blocks.id, Items.id
	local AIR = Blocks.AIR
	local M = Transmitters.MODES
	local DOWN, UP, NORTH, SOUTH, WEST, EAST = 0, 1, 2, 3, 4, 5
	local Y = 64
	local FURNACE, CHEST = B.Furnace, B.Chest
	local ELECTRIC, GENERATOR, CUBE = B.ElectricFurnace, B.HeatGenerator, B.CreativeEnergyCube
	local T = {
		B.BasicLogisticalTransporter,
		B.AdvancedLogisticalTransporter,
		B.EliteLogisticalTransporter,
		B.UltimateLogisticalTransporter,
	}
	-- Furnace slots.
	local INPUT, FUEL, OUTPUT = 1, 2, 3
	local COOK = Smelting.COOK_TIME

	local function S(item: number, count: number)
		return { item = item, count = count }
	end

	--[[
		Chests, furnaces, machines and transporters in a world of blocks (air elsewhere), stepped as
		the server does: the furnace loop (Containers.tickFurnaces, Eject.furnaces every
		Eject.INTERVAL ticks), the pipes, the machines. A changed inventory is counted (its viewers'
		snapshot) and a furnace marked active, as Players/Inventories.containerChanged does.
	]]
	local function sim()
		local blocks: { [number]: number } = {}
		local containers = Containers.new()
		local changed: { [number]: number } = {}
		local drops: { any } = {}
		local function getBlock(x: number, y: number, z: number): number?
			return blocks[Coords.posKey(x, y, z)] or AIR
		end
		local function inventoryChanged(x: number, y: number, z: number)
			local key = Coords.posKey(x, y, z)
			changed[key] = (changed[key] or 0) + 1
			containers:markActive(x, y, z)
		end
		-- Results that left a furnace's or machine's output on their own, per item (Players/
		-- Inventories.resultsTaken: smelted, for its last user).
		local taken: { [number]: number } = {}
		local function resultsTaken(_x: number, _y: number, _z: number, _container: any, stack: any)
			taken[stack.item] = (taken[stack.item] or 0) + stack.count
		end
		local pipes = TransmitterWorld.new({
			getBlock = getBlock,
			containers = containers,
			inventoryChanged = inventoryChanged,
			resultsTaken = resultsTaken,
			drop = function(_x: number, _y: number, _z: number, stack: any)
				table.insert(drops, stack)
			end,
		})
		local machines = MachineWorld.new({
			getBlock = getBlock,
			containers = containers,
			inventoryChanged = inventoryChanged,
			resultsTaken = resultsTaken,
			transmitters = pipes,
			dayTime = function()
				return 6000
			end,
		})
		local eject = {
			getBlock = getBlock,
			containers = containers,
			inventoryChanged = inventoryChanged,
			resultsTaken = resultsTaken,
		}
		local s: any = {
			taken = taken,
			pipes = pipes,
			machines = machines,
			containers = containers,
			changed = changed,
			drops = drops,
			ticks = 0,
			-- Fuel burnt by furnaces, per item, and items furnaces pushed into chests.
			burnt = {},
			ejected = 0,
		}
		function s.block(x: number, y: number, z: number): number
			return getBlock(x, y, z) :: number
		end
		-- Puts `block` at (x, y, z); what a container there held is taken and returned (Players/
		-- Inventories drops it when a block goes).
		function s.set(x: number, y: number, z: number, block: number): { any }
			local key = Coords.posKey(x, y, z)
			local old = blocks[key] or AIR
			local removed = {}
			if old ~= block then
				local container = containers:take(x, y, z)
				if container then
					for _, stack in container.slots do
						table.insert(removed, stack)
					end
				end
			end
			blocks[key] = if block == AIR then nil else block
			TransmitterWorld.blockChanged(pipes, x, y, z, old, block)
			MachineWorld.blockChanged(machines, x, y, z, old, block)
			return removed
		end
		-- The slots of the inventory at (x, y, z) (the same table its container keeps).
		function s.slots(x: number, y: number, z: number): { [number]: any }
			return containers:get(x, y, z, s.block(x, y, z)).slots
		end
		-- Puts `stack` into a furnace's `slot` as a window click would (it is ticked again).
		function s.put(x: number, y: number, z: number, slot: number, stack: any)
			s.slots(x, y, z)[slot] = stack
			containers:markActive(x, y, z)
		end
		-- What `slot` of the inventory at (x, y, z) holds now (nil: nothing, or no container: an
		-- empty furnace nobody has open is forgotten, Players/Containers).
		function s.at(x: number, y: number, z: number, slot: number): any
			local container = containers:peek(x, y, z)
			return if container then container.slots[slot] else nil
		end
		function s.mode(x: number, y: number, z: number, side: number, mode: number)
			assert(TransmitterWorld.setMode(pipes, x, y, z, side, mode), "no transporter")
		end
		-- Items (of `item`, or all) in the inventory at (x, y, z).
		function s.count(x: number, y: number, z: number, item: number?): number
			local container = containers:peek(x, y, z)
			local total = 0
			if container then
				for _, stack in container.slots do
					if stack and (item == nil or stack.item == item) then
						total += stack.count
					end
				end
			end
			return total
		end
		function s.step(n: number?)
			for _ = 1, n or 1 do
				s.ticks += 1
				-- (Players/Inventories' furnace loop; furnaces only burn fuel here.)
				if s.ticks % Eject.INTERVAL == 0 then
					s.ejected += Eject.furnaces(eject)
				end
				local fuel: { [any]: any } = {}
				for _, entry in containers.entries do
					if entry.container.kind == "furnace" then
						fuel[entry.container] = entry.container.slots[FUEL]
					end
				end
				containers:tickFurnaces()
				for container, before in fuel do
					local after = container.slots[FUEL]
					local left = if after and after.item == before.item then after.count else 0
					if before.count > left then
						s.burnt[before.item] = (s.burnt[before.item] or 0) + before.count - left
					end
				end
				TransmitterWorld.step(pipes)
				MachineWorld.step(machines)
			end
		end
		-- The items in transit (one, the last seen: tests that send one stack).
		function s.inTransit(): any
			local found = nil
			for _, item in pipes.items do
				found = item
			end
			return found
		end
		return s
	end

	--[[ Furnaces: transporters only take the results ]]

	t.test("machine rules: a PULL transporter on a furnace's side or top takes only its results", function()
		local s = sim()
		-- A: fuel and results, nothing to smelt (it never lights); pulled through its east side.
		s.set(0, Y, 0, FURNACE)
		s.set(1, Y, 0, T[2])
		s.set(2, Y, 0, T[2])
		s.set(3, Y, 0, CHEST)
		s.mode(1, Y, 0, WEST, M.PULL)
		local a = s.slots(0, Y, 0)
		a[FUEL] = S(I.Coal, 3)
		a[OUTPUT] = S(I.IronIngot, 4)
		-- B: ore and results, no fuel; pulled through its top.
		s.set(0, Y, 5, FURNACE)
		s.set(0, Y + 1, 5, T[2])
		s.set(1, Y + 1, 5, T[2])
		s.set(2, Y + 1, 5, CHEST)
		s.mode(0, Y + 1, 5, DOWN, M.PULL)
		local b = s.slots(0, Y, 5)
		b[INPUT] = S(I.RawIron, 5)
		b[OUTPUT] = S(I.IronIngot, 2)
		s.step(200)
		t.eq(s.count(3, Y, 0, I.IronIngot), 4, "the side gave the results")
		t.eq(s.count(3, Y, 0, I.Coal), 0, "never the fuel")
		t.eq(a[FUEL] and a[FUEL].count, 3, "the coal stays")
		t.eq(a[OUTPUT], nil)
		t.eq(s.count(2, Y + 1, 5, I.IronIngot), 2, "the top gave the results")
		t.eq(s.count(2, Y + 1, 5, I.RawIron), 0, "never the input")
		t.eq(b[INPUT] and b[INPUT].count, 5, "the ore stays")
		t.eq(s.pipes.itemCount, 0, "nothing else on its way")
		t.eq(s.taken[I.IronIngot], 6, "the results pulled are told (smelted, for the last user)")
		t.eq(s.taken[I.Coal], nil, "the fuel never")
	end)

	t.test("machine rules: fuel and ore put in by hand stay in a furnace a transporter pulls from", function()
		local s = sim()
		s.set(0, Y, 0, FURNACE)
		s.set(1, Y, 0, T[1])
		s.set(2, Y, 0, CHEST)
		s.mode(1, Y, 0, WEST, M.PULL)
		-- Shift-clicked in through the furnace's window, as a player does.
		local furnace = s.containers:get(0, Y, 0, FURNACE)
		local inventory = Types.newInventory()
		local window: any = { id = 1, inventory = inventory, container = furnace }
		inventory.slots[1] = S(I.Coal, 8)
		inventory.slots[2] = S(I.RawIron, 2)
		for slot = 1, 2 do
			local index = Menu.windowIndex(window, "inventory", slot) :: number
			Menu.apply(window, { kind = "click", window = 1, slot = index, clickType = 1, button = 0 }, false)
		end
		s.containers:markActive(0, Y, 0)
		t.eq(furnace.slots[FUEL] and furnace.slots[FUEL].count, 8, "the coal is in the fuel slot")
		t.eq(furnace.slots[INPUT] and furnace.slots[INPUT].count, 2, "the ore in the input")
		s.step(20)
		t.eq(furnace.slots[FUEL] and furnace.slots[FUEL].count, 7, "one coal lit; the rest stays")
		t.eq(furnace.slots[INPUT] and furnace.slots[INPUT].count, 2, "the ore stays")
		t.eq(s.pipes.itemCount, 0, "nothing was taken out")
		s.step(2 * COOK + 40)
		t.eq(s.count(2, Y, 0, I.IronIngot), 2, "the ingots were taken out")
		t.eq(s.count(2, Y, 0, I.Coal), 0, "never the coal")
		t.eq(furnace.slots[FUEL] and furnace.slots[FUEL].count, 7, "the coal is still there")
		t.eq(furnace.slots[INPUT], nil, "all of the ore smelted")
	end)

	t.test("machine rules: an empty bucket leaves a furnace's fuel slot, pulled; never pushed", function()
		local s = sim()
		s.set(0, Y, 0, FURNACE)
		s.set(1, Y, 0, T[2])
		s.set(2, Y, 0, CHEST)
		local slots = s.slots(0, Y, 0)
		slots[FUEL] = S(I.Bucket, 1)
		-- A NORMAL side takes only what the furnace pushes out: its output.
		s.step(100)
		t.eq(slots[FUEL] and slots[FUEL].item, I.Bucket, "the bucket stays")
		t.eq(s.count(2, Y, 0), 0)
		s.mode(1, Y, 0, WEST, M.PULL)
		s.step(100)
		t.eq(slots[FUEL], nil, "pulled out")
		t.eq(s.count(2, Y, 0, I.Bucket), 1)
		t.eq(s.taken[I.Bucket], nil, "not a result: nothing smelted")
	end)

	--[[ Furnaces push their results out ]]

	t.test("ejection: a furnace pushes its results into the chests next to it", function()
		local s = sim()
		s.set(0, Y, 0, FURNACE)
		s.set(0, Y - 1, 0, CHEST)
		s.set(1, Y, 0, CHEST)
		s.put(0, Y, 0, INPUT, S(I.RawIron, 3))
		s.put(0, Y, 0, FUEL, S(I.Coal, 1))
		s.step(3 * COOK + 20)
		t.eq(s.count(0, Y - 1, 0, I.IronIngot), 3, "into the chest below (Down first)")
		t.eq(s.count(1, Y, 0), 0, "the other chest wasn't needed")
		t.eq(s.at(0, Y, 0, OUTPUT), nil, "the output is empty")
		t.eq(s.at(0, Y, 0, INPUT), nil)
		t.ok((s.changed[Coords.posKey(0, Y - 1, 0)] or 0) >= 3, "the chest's viewers heard of each")
		t.ok((s.changed[Coords.posKey(0, Y, 0)] or 0) >= 3, "and the furnace's")
		t.eq(s.ejected, 3)
		t.eq(s.taken[I.IronIngot], 3, "what left on its own is told (smelted, for the last user)")
		-- The chest below full: the next ones go east.
		local below = s.slots(0, Y - 1, 0)
		for slot = 1, 27 do
			below[slot] = S(I.Dirt, 64)
		end
		s.put(0, Y, 0, INPUT, S(I.RawIron, 2))
		s.step(2 * COOK + 20)
		t.eq(s.count(1, Y, 0, I.IronIngot), 2, "into the chest east")
		t.eq(s.count(0, Y - 1, 0, I.IronIngot), 0)
		-- Both full: they stay in the output and the furnace goes on smelting into it.
		local east = s.slots(1, Y, 0)
		for slot = 1, 27 do
			east[slot] = S(I.Dirt, 64)
		end
		s.put(0, Y, 0, INPUT, S(I.RawIron, 2))
		s.step(2 * COOK + 20)
		local output = s.at(0, Y, 0, OUTPUT)
		t.eq(output and output.count, 2, "nowhere to go: they stay")
		-- Room again: out they go, a stack at most each time.
		east[5] = nil
		s.step(Eject.INTERVAL)
		t.eq(s.at(0, Y, 0, OUTPUT), nil)
		t.eq(east[5] and east[5].count, 2)
	end)

	t.test("ejection: into a NORMAL transporter and down the line, in its colour, never back", function()
		local s = sim()
		s.set(0, Y, 0, FURNACE)
		for x = 1, 3 do
			s.set(x, Y, 0, T[1])
		end
		s.set(4, Y, 0, CHEST)
		t.ok(TransmitterWorld.setColour(s.pipes, 1, Y, 0, 5))
		s.slots(0, Y, 0)[OUTPUT] = S(I.IronIngot, 20)
		s.step()
		local item = s.inTransit()
		t.ok(item ~= nil, "pushed out at once")
		t.eq(item and item.stack.count, 20, "a stack, not a Basic transporter's 1")
		t.eq(item and item.colour, 5, "in the transporter's colour")
		t.eq(item and item.home, nil, "results never go back in")
		t.eq(s.at(0, Y, 0, OUTPUT), nil)
		-- The add the clients get: in the first transporter, at its start.
		local ops = TransmitterWorld.takeTransport(s.pipes)
		t.eq(#ops, 1)
		t.eq(ops[1].op, "add")
		t.eq(ops[1].x, 1)
		t.eq(ops[1].progress, 0)
		s.step(100)
		t.eq(s.count(4, Y, 0, I.IronIngot), 20, "down the line into the chest")
		t.eq(s.pipes.itemCount, 0)
		TransmitterWorld.takeTransport(s.pipes)
		-- Room for 20 of 30: 20 go (as many as the destination takes), the rest stays. The chest
		-- fills up while they are on their way: they wait in the line rather than going back.
		local chest = s.slots(4, Y, 0)
		for slot = 1, 27 do
			chest[slot] = chest[slot] or S(I.Dirt, 64)
		end
		chest[1] = S(I.IronIngot, 44)
		local furnace = s.slots(0, Y, 0)
		furnace[OUTPUT] = S(I.IronIngot, 30)
		for _ = 1, 10 do
			s.step()
			if s.pipes.itemCount > 0 then
				break
			end
		end
		t.eq(furnace[OUTPUT] and furnace[OUTPUT].count, 10, "as many as fit there")
		chest[1] = S(I.IronIngot, 64)
		s.step(100)
		t.eq(s.pipes.itemCount, 1, "it waits in the transporters")
		local waiting = s.inTransit()
		t.eq(waiting and waiting.target, nil)
		t.eq(waiting and waiting.stack.count, 20)
		t.eq(furnace[OUTPUT] and furnace[OUTPUT].count, 10, "it never went back into the furnace")
		local seen = 0
		for _, op in TransmitterWorld.takeTransport(s.pipes) do
			if op.op == "remove" and op.reason == Protocol.TransportRemoveReason.Arrived then
				seen += 1
			end
		end
		t.eq(seen, 0, "nothing arrived anywhere")
		-- Room again: it goes on, and the rest follows.
		chest[2] = nil
		s.step(100)
		t.eq(s.count(4, Y, 0, I.IronIngot), 64 + 30)
		t.eq(s.at(0, Y, 0, OUTPUT), nil)
	end)

	t.test("ejection: never through a PUSH or NONE side; NORMAL and PULL sides take it", function()
		local s = sim()
		s.set(0, Y, 0, FURNACE)
		s.set(1, Y, 0, T[2])
		s.set(2, Y, 0, CHEST)
		s.slots(0, Y, 0)[OUTPUT] = S(I.IronIngot, 5)
		local node = TransmitterWorld.node(s.pipes, 1, Y, 0) :: any
		t.ok(s.pipes.pullers[node.key] ~= nil, "a NORMAL side on a furnace takes its results")
		for _, mode in { M.PUSH, M.NONE } do
			s.mode(1, Y, 0, WEST, mode)
			t.eq(s.pipes.pullers[node.key], nil, `{Transmitters.modeName(mode)}: nothing to take`)
			s.step(100)
			t.eq(s.count(0, Y, 0, I.IronIngot), 5, `not through {Transmitters.modeName(mode)}`)
			t.eq(s.count(2, Y, 0), 0)
			t.eq(s.pipes.itemCount, 0)
		end
		s.mode(1, Y, 0, WEST, M.NORMAL)
		s.step(20)
		t.eq(s.at(0, Y, 0, OUTPUT), nil, "NORMAL takes them")
		s.step(40)
		t.eq(s.count(2, Y, 0, I.IronIngot), 5)
		s.slots(0, Y, 0)[OUTPUT] = S(I.IronIngot, 7)
		s.mode(1, Y, 0, WEST, M.PULL)
		s.step(60)
		t.eq(s.count(2, Y, 0, I.IronIngot), 12, "PULL too: one pass, a stack at once")
		t.eq(s.at(0, Y, 0, OUTPUT), nil)
		-- Next to a chest a NORMAL side takes nothing (chests push nothing out).
		s.set(5, Y, 0, CHEST)
		s.set(6, Y, 0, T[2])
		s.set(7, Y, 0, CHEST)
		s.slots(5, Y, 0)[1] = S(I.Dirt, 3)
		local lone = TransmitterWorld.node(s.pipes, 6, Y, 0) :: any
		t.eq(s.pipes.pullers[lone.key], nil)
		s.step(60)
		t.eq(s.count(5, Y, 0), 3, "the dirt stays")
	end)

	t.test("ejection: never straight into another furnace or machine; transporters lead there", function()
		local s = sim()
		s.set(0, Y, 0, FURNACE)
		s.set(1, Y, 0, FURNACE)
		s.set(0, Y + 1, 0, ELECTRIC)
		s.set(0, Y, 1, GENERATOR)
		local a = s.slots(0, Y, 0)
		-- Stone smelts again (into smooth stone): a surprise chain if it went in.
		a[OUTPUT] = S(I.Stone, 8)
		s.containers:markActive(0, Y, 0)
		s.step(100)
		t.eq(a[OUTPUT] and a[OUTPUT].count, 8, "it stays")
		t.eq(s.count(1, Y, 0), 0, "not into the furnace next to it")
		t.eq(s.count(0, Y + 1, 0), 0, "not into the Electric Furnace")
		t.eq(s.count(0, Y, 1), 0, "not into the Heat Generator")
		-- Two transporters on their north sides lead from one furnace to the other.
		s.set(0, Y, -1, T[2])
		s.set(1, Y, -1, T[2])
		s.step(100)
		t.eq(a[OUTPUT], nil, "through the transporters")
		local b = s.slots(1, Y, 0)
		t.eq(b[INPUT] and b[INPUT].item, I.Stone, "into the other furnace's input")
		t.eq(b[INPUT] and b[INPUT].count, 8)
	end)

	t.test("ejection: results with nowhere to go stay in the furnace", function()
		local s = sim()
		s.set(0, Y, 0, FURNACE)
		s.set(1, Y, 0, T[3])
		s.set(2, Y, 0, T[3])
		s.set(3, Y, 0, CHEST)
		local chest = s.slots(3, Y, 0)
		for slot = 1, 27 do
			chest[slot] = S(I.Dirt, 64)
		end
		s.slots(0, Y, 0)[OUTPUT] = S(I.IronIngot, 6)
		s.step(200)
		t.eq(s.count(0, Y, 0, I.IronIngot), 6, "nowhere to go: they stay")
		t.eq(s.pipes.itemCount, 0, "none waits in the transporters")
		-- A line to nothing at all.
		s.set(3, Y, 0, AIR)
		s.step(200)
		t.eq(s.count(0, Y, 0, I.IronIngot), 6)
		t.eq(s.pipes.itemCount, 0)
		-- Room: out they go (after the backoff, at most 40 ticks).
		s.set(3, Y, 0, CHEST)
		s.step(60)
		t.eq(s.at(0, Y, 0, OUTPUT), nil)
		t.eq(s.count(3, Y, 0, I.IronIngot), 6)
	end)

	--[[ Machines ]]

	t.test("electric furnace: ore in through any face, results out into a chest and a transporter", function()
		local s = sim()
		s.set(0, Y, 0, ELECTRIC)
		s.set(0, Y + 1, 0, CUBE)
		-- Ore from a chest east of a transporter under it, through its bottom face.
		s.set(2, Y - 1, 0, CHEST)
		s.set(1, Y - 1, 0, T[2])
		s.set(0, Y - 1, 0, T[2])
		s.mode(1, Y - 1, 0, EAST, M.PULL)
		local source = s.slots(2, Y - 1, 0)
		source[1] = S(I.RawIron, 5)
		source[2] = S(I.Coal, 4)
		-- The results go into the chest on its west side on their own.
		s.set(-1, Y, 0, CHEST)
		local smelter = s.slots(0, Y, 0)
		smelter[3] = S(I.SpeedUpgrade, 8)
		smelter[4] = S(I.EnergyUpgrade, 1)
		s.step(500)
		t.eq(s.count(2, Y - 1, 0, I.RawIron), 0, "all the ore went in through its bottom")
		t.eq(s.count(2, Y - 1, 0, I.Coal), 4, "coal doesn't smelt: it stays")
		t.eq(s.count(-1, Y, 0, I.IronIngot), 5, "every ingot was pushed into the chest")
		t.eq(s.taken[I.IronIngot], 5, "and told (smelted, for the machine's last user)")
		t.eq(smelter[1], nil)
		t.eq(smelter[2], nil)
		-- Without the chest, a transporter pulling from its north side takes them.
		s.set(-1, Y, 0, AIR)
		s.set(0, Y, -1, T[2])
		s.set(0, Y, -2, T[2])
		s.set(0, Y, -3, CHEST)
		s.mode(0, Y, -1, SOUTH, M.PULL)
		source[1] = S(I.RawIron, 5)
		s.step(500)
		t.eq(s.count(0, Y, -3, I.IronIngot), 5, "pulled through its north side")
		t.eq(s.taken[I.IronIngot], 10, "told too")
		t.eq(s.taken[I.SpeedUpgrade], nil, "never its cards")
		t.eq(smelter[1], nil)
		t.eq(smelter[2], nil)
		-- Never its cards.
		t.eq(smelter[3] and smelter[3].count, 8, "the Speed Upgrades stay")
		t.eq(smelter[4] and smelter[4].count, 1, "the Energy Upgrade stays")
		t.eq(s.count(0, Y, -3, I.SpeedUpgrade) + s.count(0, Y, -3, I.EnergyUpgrade), 0)
		t.eq(s.pipes.itemCount, 0)
	end)

	t.test("heat generator: fuel in through any face, nothing out, nothing pushed out", function()
		t.ok(not Transmitters.ejects(GENERATOR), "no output slots")
		t.eq(#Machines.outputSlots(GENERATOR), 0)
		local s = sim()
		s.set(0, Y, 0, GENERATOR)
		s.set(1, Y, 0, T[2])
		s.set(2, Y, 0, CHEST)
		s.mode(1, Y, 0, EAST, M.PULL)
		s.slots(2, Y, 0)[1] = S(I.Coal, 10)
		s.slots(2, Y, 0)[2] = S(I.Dirt, 3)
		s.step(100)
		local generator = s.slots(0, Y, 0)
		t.eq(s.count(2, Y, 0, I.Coal), 0, "the coal went in through its side")
		t.eq(generator[1] and generator[1].count, 9, "one lit, nine wait")
		t.eq(s.count(2, Y, 0, I.Dirt), 3, "dirt doesn't burn")
		-- A transporter pulling from its top gets nothing, and a NORMAL one beside it isn't asked.
		s.set(0, Y + 1, 0, T[2])
		s.set(0, Y + 2, 0, CHEST)
		s.mode(0, Y + 1, 0, DOWN, M.PULL)
		s.set(0, Y, 1, T[2])
		local beside = TransmitterWorld.node(s.pipes, 0, Y, 1) :: any
		t.eq(s.pipes.pullers[beside.key], nil, "nothing is pushed out of it")
		s.step(200)
		t.eq(generator[1] and generator[1].count, 9, "the fuel stays")
		t.eq(s.count(0, Y + 2, 0), 0)
		t.eq(s.pipes.itemCount, 0)
	end)

	--[[ Conservation ]]

	t.test("machine rules: no item is lost or made with furnaces cooking and pushing (fuzz)", function()
		local rng = Hash.rng(2024)
		-- Smelting turns one item into one of the same family; fuel burns away (counted).
		local family: { [number]: string } = {
			[I.RawIron] = "iron",
			[I.IronIngot] = "iron",
			[I.Cobblestone] = "stone",
			[I.Stone] = "stone",
			[I.SmoothStone] = "stone",
			[I.OakLog] = "wood",
			[I.Charcoal] = "wood",
			[I.Coal] = "coal",
			[I.Dirt] = "dirt",
			[I.Bucket] = "bucket",
		}
		local pool = { I.RawIron, I.IronIngot, I.Cobblestone, I.Stone, I.OakLog, I.Coal, I.Dirt, I.Bucket }
		local inputs = { I.RawIron, I.Cobblestone, I.Stone, I.OakLog }
		local fuels = { I.Coal, I.OakLog, I.Bucket }
		local results = { I.IronIngot, I.Stone, I.SmoothStone, I.Charcoal }
		local blocks = { T[1], T[2], T[3], T[4], CHEST, CHEST, FURNACE, FURNACE, ELECTRIC, CUBE, AIR, AIR }
		local cooked, arrived, pushed = 0, 0, 0
		for round = 1, 24 do
			local s = sim()
			local initial: { [string]: number } = {}
			local removed: { [string]: number } = {}
			local function add(into: { [string]: number }, stack: any)
				local name = family[stack.item]
				assert(name, `an item of no family: {stack.item}`)
				into[name] = (into[name] or 0) + stack.count
			end
			local function seed(x: number, y: number, z: number, slot: number, list: { number })
				if rng:float() < 0.6 then
					local item = list[rng:int(1, #list)]
					local stack = S(item, rng:int(1, math.min(Items.maxStack(item), 64)))
					s.slots(x, y, z)[slot] = stack
					add(initial, stack)
				end
			end
			local function place(x: number, y: number, z: number, block: number)
				for _, stack in s.set(x, y, z, block) do
					add(removed, stack)
				end
			end
			for x = 0, 4 do
				for y = Y, Y + 2 do
					for z = 0, 2 do
						place(x, y, z, blocks[rng:int(1, #blocks)])
					end
				end
			end
			for x = 0, 4 do
				for y = Y, Y + 2 do
					for z = 0, 2 do
						local block = s.block(x, y, z)
						if block == CHEST then
							for slot = 1, 5 do
								seed(x, y, z, slot, pool)
							end
						elseif block == FURNACE then
							seed(x, y, z, INPUT, inputs)
							seed(x, y, z, FUEL, fuels)
							seed(x, y, z, OUTPUT, results)
							s.containers:markActive(x, y, z)
						elseif block == ELECTRIC then
							seed(x, y, z, 1, inputs)
							seed(x, y, z, 2, results)
						elseif Transmitters.isTransmitter(block) then
							for side = 0, 5 do
								if rng:float() < 0.3 then
									TransmitterWorld.setMode(s.pipes, x, y, z, side, rng:int(0, 3))
								end
							end
							if rng:float() < 0.2 then
								TransmitterWorld.setColour(s.pipes, x, y, z, rng:int(0, 2))
							end
						end
					end
				end
			end
			local function totals(): { [string]: number }
				local out: { [string]: number } = {}
				for _, entry in s.containers.entries do
					for _, stack in entry.container.slots do
						if stack then
							add(out, stack)
						end
					end
				end
				for _, item in s.pipes.items do
					add(out, item.stack)
				end
				for _, stack in s.drops do
					add(out, stack)
				end
				for item, count in s.burnt do
					add(out, S(item, count))
				end
				for name, count in removed do
					out[name] = (out[name] or 0) + count
				end
				return out
			end
			for _ = 1, 25 do
				s.step(rng:int(1, 60))
				for _, op in TransmitterWorld.takeTransport(s.pipes) do
					if op.op == "remove" and op.reason == Protocol.TransportRemoveReason.Arrived then
						arrived += 1
					end
				end
				local now = totals()
				for name, count in initial do
					t.eq(now[name] or 0, count, `round {round}: {name} conserved`)
				end
				for name in now do
					t.ok(initial[name] ~= nil, `round {round}: no {name} made`)
				end
				-- Inputs only ever hold what smelts, fuel slots fuel (or the buckets seeded there).
				for _, entry in s.containers.entries do
					local container = entry.container
					if container.kind == "furnace" then
						local input, fuel = container.slots[INPUT], container.slots[FUEL]
						t.ok(input == nil or Smelting.result(input.item) ~= nil, "a furnace's input smelts")
						t.ok(fuel == nil or Smelting.fuel(fuel.item) > 0 or fuel.item == I.Bucket, "its fuel burns")
					end
				end
				local x, y, z = rng:int(0, 4), rng:int(Y, Y + 2), rng:int(0, 2)
				local roll = rng:float()
				if roll < 0.3 then
					place(x, y, z, blocks[rng:int(1, #blocks)])
				elseif roll < 0.7 and Transmitters.isTransmitter(s.block(x, y, z)) then
					TransmitterWorld.cycleMode(s.pipes, x, y, z, rng:int(0, 5))
				elseif Transmitters.isTransmitter(s.block(x, y, z)) then
					TransmitterWorld.cycleColour(s.pipes, x, y, z)
				end
			end
			for _, n in s.burnt do
				cooked += n
			end
			pushed += s.ejected
			for _, item in s.pipes.items do
				t.ok(item.stack.count >= 1 and item.stack.count <= Items.maxStack(item.stack.item), "a stack at most")
			end
		end
		-- (The fuzz did move things: fuel burnt, deliveries, results pushed into chests.)
		t.ok(cooked > 20, `fuel burnt ({cooked})`)
		t.ok(arrived > 200, `items arrived ({arrived})`)
		t.ok(pushed > 100, `results pushed into chests ({pushed})`)
	end)

	t.test("ejection: reads only blocks it knows, skips furnaces that are gone, forgets empty outputs", function()
		local s = sim()
		s.set(0, Y, 0, FURNACE)
		s.set(1, Y, 0, CHEST)
		s.put(0, Y, 0, OUTPUT, S(I.IronIngot, 5))
		local key = "0," .. Y .. ",0"
		t.ok(s.containers.ejecting[key], "a furnace with results waits to push them out")
		-- Blocks the server doesn't know (a chunk it hasn't generated, no edits there) are no chest:
		-- nothing is read past them, nothing moves.
		local unknown = {
			getBlock = function(x: number, y: number, z: number): number?
				return if x == 0 and y == Y and z == 0 then FURNACE else nil
			end,
			containers = s.containers,
		}
		t.eq(Eject.furnaces(unknown), 0)
		-- The furnace's block gone, its container not taken yet: skipped.
		local gone = {
			getBlock = function(x: number, y: number, z: number): number?
				return if x == 0 and y == Y and z == 0 then AIR else s.block(x, y, z)
			end,
			containers = s.containers,
		}
		t.eq(Eject.furnaces(gone), 0)
		t.eq(s.count(1, Y, 0), 0, "nothing moved")
		t.eq(s.count(0, Y, 0, I.IronIngot), 5)
		t.ok(s.containers.ejecting[key], "still waiting")
		-- Known: out they go, and the furnace leaves the set once its output is empty.
		t.eq(Eject.furnaces({ getBlock = s.block, containers = s.containers }), 5)
		t.eq(s.count(1, Y, 0, I.IronIngot), 5)
		t.eq(#s.containers:ejectingFurnaces(), 0)
		t.eq(s.containers.ejecting[key], nil)
		-- A broken furnace leaves it at once.
		s.put(0, Y, 0, OUTPUT, S(I.IronIngot, 2))
		t.ok(s.containers.ejecting[key])
		local removed = s.set(0, Y, 0, AIR)
		t.eq(#removed, 1)
		t.eq(s.containers.ejecting[key], nil)
		t.eq(#s.containers:ejectingFurnaces(), 0)
	end)

	t.test("ejection: a chest and a transporter on the same furnace share its results, none lost", function()
		local s = sim()
		s.set(0, Y, 0, FURNACE)
		s.set(-1, Y, 0, CHEST)
		-- The transporter's line leads nowhere at first (its chest comes half way through).
		s.set(1, Y, 0, T[1])
		s.set(2, Y, 0, T[1])
		s.put(0, Y, 0, INPUT, S(I.RawIron, 12))
		s.put(0, Y, 0, FUEL, S(I.Coal, 2))
		local function total(): number
			local n = s.count(-1, Y, 0, I.IronIngot) + s.count(3, Y, 0, I.IronIngot)
			n += s.count(0, Y, 0, I.IronIngot)
			for _, item in s.pipes.items do
				n += item.stack.count
			end
			return n
		end
		local cooked = 0
		for tick = 1, 12 * COOK + 200 do
			if tick == 6 * COOK + 100 then
				s.set(3, Y, 0, CHEST)
			end
			s.step()
			local input = s.at(0, Y, 0, INPUT)
			cooked = 12 - (if input then input.count else 0)
			t.eq(total(), cooked, "every ingot is somewhere, once")
		end
		t.eq(cooked, 12)
		t.eq(s.count(-1, Y, 0, I.IronIngot) + s.count(3, Y, 0, I.IronIngot), 12, "all in the chests")
		t.ok(s.count(-1, Y, 0, I.IronIngot) >= 5, "the chest next to it got the first ones")
		t.ok(s.count(3, Y, 0, I.IronIngot) >= 5, "the transporter most of the rest")
		t.eq(s.at(0, Y, 0, OUTPUT), nil)
		t.eq(s.pipes.itemCount, 0)
	end)
end

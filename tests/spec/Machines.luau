--[[
	Mekanism's machine framework, the shared and client parts: kinds and their containers, the data
	layout, energy maths (quantised, Mekanism's even split), slot rules, shift-click routing
	through Inventory/Menu, sided slots for transporters, status lines, sustained data, the
	Machines protocol message, panels and the energy bar (Ui/MenuLayout) and WAILA's machine lines.
	The kinds are test-only fakes (tests/lib/FakeMachines) bound to spare blocks, as later phases
	bind theirs through BlockList; the Creative Energy Cube is the one real machine.
]]

local FakeMachines = require("../lib/FakeMachines")

return function(t, shared, require, _server, client)
	local Blocks = require(shared.Blocks)
	local Hash = require(shared.Util.Hash)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local Menu = require(shared.Inventory.Menu)
	local Protocol = require(shared.Net.Protocol)
	local Smelting = require(shared.Crafting.Smelting)
	local Transmitters = require(shared.Transmitters)
	local Types = require(shared.Inventory.Types)
	local MenuLayout = require(client.Ui.MenuLayout)
	local WailaInfo = require(client.Ui.WailaInfo)

	local B = Blocks.id
	local I = Items.id
	local Q = Machines.QUANTUM
	local kinds = FakeMachines.define(Machines, Items, Smelting)
	-- Spare blocks the fake kinds are bound to (none is a container, transmitter or tank).
	local FURNACE_BLOCK = B.DiamondBlock
	local PRODUCER_BLOCK = B.OsmiumBlock

	local function withFurnace(fn: () -> ())
		FakeMachines.bind(Machines, { { FURNACE_BLOCK, "test_furnace", { capacity = 20000, input = 20000 } } }, fn)
	end

	local function S(item: number, count: number)
		return { item = item, count = count }
	end

	--[[ Kinds and blocks ]]

	t.test("machines: the header layout and the container kind", function()
		t.eq(Machines.ENERGY, 1, "energy is always data[1]")
		t.eq(Machines.CAPACITY, 2)
		t.eq(Machines.INPUT, 3)
		t.eq(Machines.OUTPUT, 4)
		t.eq(Machines.RATE, 5)
		t.eq(Machines.ACTIVE, 6)
		t.eq(Machines.HEADER, 6)
		t.ok(table.find(Types.KINDS, "machine") ~= nil, "a container kind on the wire")
		t.eq(Machines.CONTAINER_KIND, "machine")
		local furnace = kinds.furnace
		t.eq(furnace.index.energy, 1)
		t.eq(furnace.index.progress, 7, "fields follow the header")
		t.eq(furnace.index.cost, 11)
		t.eq(furnace.size, 11)
		t.ok(table.isfrozen(furnace) and table.isfrozen(furnace.slots), "kinds are read only")
	end)

	t.test("machines: define refuses bad kinds", function()
		t.ok(not pcall(Machines.define, "test_producer", {}), "a name twice")
		t.ok(not pcall(Machines.define, "", {}), "no name")
		t.ok(not pcall(Machines.define, "test_bad_field", { fields = { "bad key!" } }), "a field that is no data key")
		t.ok(not pcall(Machines.define, "test_header", { fields = { "energy" } }), "a header name")
		t.ok(not pcall(Machines.define, "test_keep", { fields = { "a" }, keep = { "b" } }), "keeping a non-field")
		local many = {}
		for i = 1, Types.MAX_CONTAINER_DATA - Machines.HEADER + 1 do
			table.insert(many, `f{i}`)
		end
		t.ok(not pcall(Machines.define, "test_many", { fields = many }), "more data than a container sends")
		t.ok(not pcall(Machines.define, "test_slot", { slots = { { y = 3 } } }), "a slot without a place")
		t.ok(not pcall(Machines.bind, B.Stone, "no_such_kind", { capacity = 1 }), "an unknown kind")
		t.ok(not pcall(Machines.bind, B.Stone, "test_battery", nil), "a machine needs energy")
	end)

	t.test("machines: the Creative Energy Cube is a real machine (creative, infinite)", function()
		local cube = B.CreativeEnergyCube
		t.ok(Machines.isMachine(cube) and Machines.hasEnergy(cube))
		t.eq((Machines.kindOf(cube) :: any).name, "creative")
		t.eq(Machines.role(cube), "producer")
		local energy = Machines.energyOf(cube) :: any
		t.eq(energy.capacity, math.huge)
		t.eq(energy.output, math.huge)
		local def = Blocks.get(cube)
		t.eq(def.menu, "Machine", "machines open a panel")
		t.eq(def.container, 0, "its slots are its kind's")
		t.eq(def.decor, "CreativeEnergyCube")
		t.eq(Machines.containerSize(cube), 0)
		t.eq(Items.displayName(cube), "Creative Energy Cube")
		local container = Machines.newContainer(cube)
		t.eq(container.kind, "machine")
		t.eq(container.size, 0)
		t.eq(Machines.energy(container), math.huge, "always full")
		t.eq(Machines.save(container), nil, "keeps nothing")
		t.ok(not Machines.restore(container, { energy = 5 }))
		-- Its tick keeps it full whatever happens.
		local values = container.data :: any
		values[1] = 5
		Machines.tick(container, {
			block = cube,
			x = 0,
			y = 0,
			z = 0,
			energy = energy,
			tick = 1,
			dayTime = 0,
			getBlock = function()
				return nil
			end,
		})
		t.eq(Machines.energy(container), math.huge)
		t.ok(Machines.use(container, 1e12), "infinite energy to use")
		t.eq(Machines.energy(container), math.huge)
		-- Every other block: no machine.
		for _, block in { B.Stone, B.Chest, B.Furnace, B.BasicUniversalCable, B.BasicFluidTank } do
			t.ok(not Machines.isMachine(block), `{Blocks.get(block).name} is no machine`)
			t.eq(Machines.kindOf(block), nil)
			t.eq(Machines.role(block), nil)
		end
		t.eq(Machines.containerSize(B.Chest), 27, "chests keep BlockList's size")
		t.eq(Machines.containerSize(B.Furnace), 3)
	end)

	t.test("machines: roles come from the energy spec; bind and unbind at run time", function()
		FakeMachines.bind(Machines, {
			{ B.OsmiumBlock, "test_producer", { capacity = 1000, output = 100 } },
			{ B.IronBlock, "test_consumer", { capacity = 1000, input = 100 } },
			{ B.GoldBlock, "test_battery", { capacity = 1000, input = 100, output = 100 } },
			{ B.EmeraldBlock, "test_battery", { capacity = 1000 } },
		}, function()
			t.eq(Machines.role(B.OsmiumBlock), "producer")
			t.eq(Machines.role(B.IronBlock), "consumer")
			t.eq(Machines.role(B.GoldBlock), "storage")
			t.eq(Machines.role(B.EmeraldBlock), nil, "no rates: no flows")
			t.ok(Transmitters.isEnergyAcceptor(B.GoldBlock), "cables reach it")
		end)
		t.ok(not Machines.isMachine(B.OsmiumBlock), "unbound again")
		t.ok(not Transmitters.isEnergyAcceptor(B.GoldBlock))
		-- A failing test still unbinds.
		t.ok(not pcall(FakeMachines.bind, Machines, { { B.IronBlock, "test_battery", { capacity = 1 } } }, function()
			error("boom")
		end))
		t.ok(not Machines.isMachine(B.IronBlock))
	end)

	--[[ Energy maths ]]

	t.test("energy maths: quantised to 1/1024 J, never up when producing, up when using", function()
		t.eq(Machines.quantise(1.5), 1.5)
		t.eq(Machines.quantise(Q * 3.7), Q * 3)
		t.eq(Machines.quantiseUp(Q * 3.2), Q * 4)
		t.eq(Machines.quantise(-5), 0)
		t.eq(Machines.quantise(0 / 0), 0)
		t.eq(Machines.quantise(math.huge), math.huge)
		t.eq(Machines.quantiseUp(0), 0)
		local cube = Machines.newContainer(B.CreativeEnergyCube)
		t.eq(Machines.room(cube), 0, "a full infinite store has no room")
		FakeMachines.bind(
			Machines,
			{ { PRODUCER_BLOCK, "test_producer", { capacity = 1000, output = 100 } } },
			function()
				local c = Machines.newContainer(PRODUCER_BLOCK)
				t.eq(Machines.capacity(c), 1000)
				t.eq(Machines.produce(c, 400.3), 400.3 - (400.3 % Q), "quantised down")
				local room = Machines.room(c)
				t.eq(Machines.produce(c, 10000), room, "only its room")
				t.eq(Machines.energy(c), 1000)
				t.eq(Machines.produce(c, 5), 0, "full")
				t.ok(Machines.use(c, 999.9), "uses quantised up")
				t.eq(Machines.energy(c), 1000 - Machines.quantiseUp(999.9))
				t.ok(not Machines.use(c, 1), "not enough: nothing taken")
				t.eq(Machines.energy(c), 1000 - Machines.quantiseUp(999.9))
				local input, output = Machines.rates(c)
				t.eq(input, 0)
				t.eq(output, 100)
			end
		)
	end)

	t.test("energy maths: Mekanism's even split, exact in quanta", function()
		local function total(list: { number }): number
			local sum = 0
			for _, value in list do
				sum += value
			end
			return sum
		end
		local gives = Machines.share(300, { 1000, 1000, 1000 })
		t.eq(gives[1], 100)
		t.eq(gives[2], 100)
		t.eq(gives[3], 100)
		-- Small limits take all they can; the rest is shared again.
		gives = Machines.share(300, { 10, 1000, 1000 })
		t.eq(gives[1], 10)
		t.eq(gives[2], 145)
		t.eq(gives[3], 145)
		-- More than they take: each gets its limit.
		gives = Machines.share(10000, { 10, 20, 30 })
		t.eq(total(gives), 60)
		t.eq(gives[3], 30)
		-- Nothing, nobody, nonsense.
		t.eq(total(Machines.share(0, { 5, 5 })), 0)
		t.eq(#Machines.share(5, {}), 0)
		t.eq(total(Machines.share(0 / 0, { 5 })), 0)
		t.eq(total(Machines.share(5, { -1, 0 / 0 })), 0)
		-- Infinite limits (a creative cube) are fine; an infinite amount fills every finite limit.
		gives = Machines.share(50, { math.huge, 20 })
		t.eq(gives[2], 20)
		t.eq(gives[1], 30)
		t.eq(total(Machines.share(math.huge, { 7, 9 })), 16)
		-- Fuzz: always min(amount, sum of limits), within limits, in quanta, fair within a quantum.
		local rng = Hash.rng(711)
		for _ = 1, 400 do
			local n = rng:int(1, 8)
			local limits = {}
			for i = 1, n do
				limits[i] = if rng:float() < 0.2 then 0 else rng:float() * rng:int(1, 5000)
			end
			local amount = rng:float() * rng:int(1, 20000)
			local result = Machines.share(amount, limits)
			local expect = math.min(Machines.quantise(amount), 0)
			local sumLimits = 0
			for i = 1, n do
				sumLimits += Machines.quantise(limits[i])
			end
			expect = math.min(Machines.quantise(amount), sumLimits)
			t.eq(total(result), expect, "the split gives exactly what it can")
			local smallest, largest = math.huge, -math.huge
			for i = 1, n do
				t.ok(result[i] >= 0 and result[i] <= limits[i] + 1e-9, "within its limit")
				t.eq(result[i] % Q, 0, "whole quanta")
				if result[i] < Machines.quantise(limits[i]) then
					-- Not filled: it got the fair share (at most a quantum below the others).
					smallest = math.min(smallest, result[i])
				end
				largest = math.max(largest, result[i])
			end
			if smallest < math.huge then
				t.ok(largest - smallest <= Q + 1e-12, "fair within a quantum")
			end
		end
	end)

	--[[ Slots ]]

	t.test("slots: what each slot of a kind takes, outputs take nothing, limits", function()
		withFurnace(function()
			local block = FURNACE_BLOCK
			t.eq(Machines.containerSize(block), 3)
			t.ok(Machines.mayPlace(block, 1, I.RawIron), "smeltable into the input")
			t.ok(not Machines.mayPlace(block, 1, I.Stick), "not smeltable")
			t.ok(Machines.mayPlace(block, 2, I.Coal), "fuel into the fuel slot")
			t.ok(not Machines.mayPlace(block, 2, I.RawIron), "not fuel")
			t.ok(not Machines.mayPlace(block, 3, I.IronIngot), "outputs take nothing")
			t.ok(not Machines.mayPlace(block, 4, I.Coal), "no slot 4")
			t.ok(not Machines.mayPlace(block, 1, 99999), "unknown items")
			t.ok(Machines.isOutput(block, 3) and not Machines.isOutput(block, 1))
			t.eq(Machines.slotLimit(block, 2, I.Coal), 16, "the slot's own limit")
			t.eq(Machines.slotLimit(block, 1, I.RawIron), 64)
			t.eq(Machines.slotLimit(block, 1, I.Snowball), 16, "the item's max stack")
			t.eq(table.concat(Machines.quickMoveTargets(block, I.RawIron), ","), "1")
			t.eq(table.concat(Machines.quickMoveTargets(block, I.Coal), ","), "2")
			t.eq(table.concat(Machines.quickMoveTargets(block, I.OakLog), ","), "1,2", "logs smelt and burn")
			t.eq(#Machines.quickMoveTargets(block, I.Stick), 1, "sticks burn")
			t.eq(#Machines.quickMoveTargets(block, I.Diamond), 0, "nowhere")
			-- Sided slots: inputs every face, the fuel only from the sides, the output out of the
			-- bottom only.
			t.eq(table.concat(Machines.insertSlots(block, 1), ","), "1")
			t.eq(table.concat(Machines.insertSlots(block, 4), ","), "1,2")
			t.eq(table.concat(Machines.extractSlots(block, 0), ","), "3")
			t.eq(#Machines.extractSlots(block, 1), 0)
			t.eq(#Machines.insertSlots(block, 9), 0, "a bad face")
		end)
		t.ok(not Machines.mayPlace(FURNACE_BLOCK, 1, I.RawIron), "unbound: nothing")
	end)

	t.test("slots: Inventory/Menu follows the kind (clicks, shift-click, outputs, limits)", function()
		withFurnace(function()
			local container = Machines.newContainer(FURNACE_BLOCK)
			local inventory = Types.newInventory()
			local window: any = { id = 1, inventory = inventory, container = container }
			local n = container.size
			local function slotOf(index: number): number
				return Menu.windowIndex(window, "inventory", index) :: number
			end
			inventory.slots[1] = S(I.RawIron, 10)
			inventory.slots[2] = S(I.Coal, 40)
			inventory.slots[3] = S(I.Diamond, 5)
			-- Shift-click from the hotbar: ore into the input, coal into the fuel slot (16 at most).
			Menu.apply(window, { kind = "click", window = 1, slot = slotOf(1), clickType = 1, button = 0 }, false)
			t.eq(container.slots[1].count, 10)
			t.eq(inventory.slots[1], nil)
			Menu.apply(window, { kind = "click", window = 1, slot = slotOf(2), clickType = 1, button = 0 }, false)
			t.eq(container.slots[2].count, 16, "the fuel slot's limit")
			t.eq(inventory.slots[2].count, 24, "the rest stays (Mekanism: one pass)")
			-- Again: the fuel slot is full, nothing went in, so it moves to the main inventory.
			Menu.apply(window, { kind = "click", window = 1, slot = slotOf(2), clickType = 1, button = 0 }, false)
			t.eq(inventory.slots[2], nil)
			t.eq(inventory.slots[10].count, 24)
			-- Diamonds go nowhere in the machine: hotbar -> the inventory above it.
			Menu.apply(window, { kind = "click", window = 1, slot = slotOf(3), clickType = 1, button = 0 }, false)
			t.eq(inventory.slots[3], nil)
			t.eq(inventory.slots[11].count, 5, "moved to the main inventory")
			-- A click can't put anything into the output; carrying diamonds into the input is refused.
			inventory.cursor = S(I.Diamond, 1)
			Menu.apply(window, { kind = "click", window = 1, slot = 2, clickType = 0, button = 0 }, false)
			t.eq(container.slots[3], nil, "nothing into the output")
			Menu.apply(window, { kind = "click", window = 1, slot = 0, clickType = 0, button = 0 }, false)
			t.eq(container.slots[1].item, I.RawIron, "the input kept its ore")
			t.eq(inventory.cursor.item, I.Diamond)
			inventory.cursor = nil
			-- Outputs give like a furnace's (a right click half), shift-clicked to the hotbar's end
			-- first; carried items of the same kind only join with all of the output.
			container.slots[3] = S(I.IronIngot, 7)
			t.ok(Menu.isResultSlot(window, 2), "an output")
			t.ok(not Menu.isResultSlot(window, 0))
			Menu.apply(window, { kind = "click", window = 1, slot = 2, clickType = 0, button = 1 }, false)
			t.eq(inventory.cursor and inventory.cursor.count, 4, "a right click takes half")
			inventory.cursor = S(I.IronIngot, 62)
			Menu.apply(window, { kind = "click", window = 1, slot = 2, clickType = 0, button = 0 }, false)
			t.eq(container.slots[3].count, 3, "3 more do not fit 62: nothing joins")
			t.eq(inventory.cursor.count, 62)
			inventory.cursor = nil
			container.slots[3] = S(I.IronIngot, 7)
			Menu.apply(window, { kind = "click", window = 1, slot = 2, clickType = 1, button = 0 }, false)
			t.eq(container.slots[3], nil)
			t.eq(inventory.slots[9].count, 7, "the hotbar's right end first")
			-- Creative can't put into an output either, nor beyond a slot's limit.
			Menu.apply(window, { kind = "creative", window = 1, slot = 2, item = I.IronIngot, count = 1 }, true)
			t.eq(container.slots[3], nil)
			Menu.apply(window, { kind = "creative", window = 1, slot = 1, item = I.Coal, count = 17 }, true)
			t.eq(container.slots[2].count, 16, "unchanged")
			-- Window slots: the machine's first, then armor and the inventory as always.
			t.eq(Menu.size(window), n + Types.PLAYER_SLOTS)
		end)
	end)

	t.test("slots: transporters reach a machine through its kind's faces", function()
		withFurnace(function()
			local block = FURNACE_BLOCK
			t.ok(Transmitters.isItemAcceptor(block), "a machine with slots is an inventory")
			local slots = {}
			local after, left = Transmitters.insert(block, 1, slots, S(I.RawIron, 70))
			t.eq(after[1].count, 64, "into the input from the top")
			t.eq(left and left.count, 6)
			after, left = Transmitters.insert(block, 1, slots, S(I.Coal, 5))
			t.eq(after[2], nil, "fuel only through the sides")
			t.eq(left and left.count, 5)
			after, left = Transmitters.insert(block, 4, slots, S(I.Coal, 40))
			t.eq(after[2].count, 16, "the fuel slot's limit")
			t.eq(Transmitters.room(block, 4, slots, S(I.Coal, 40)), 16)
			t.eq(Transmitters.room(block, 1, slots, S(I.Diamond, 1)), 0)
			local full = { [3] = S(I.IronIngot, 9), [1] = S(I.RawIron, 3) }
			t.eq(#Transmitters.available(block, 1, full), 0, "nothing out of the top")
			local out, taken = Transmitters.extract(block, 0, full, 64)
			t.eq(taken and taken.item, I.IronIngot, "the output from the bottom")
			t.eq(taken and taken.count, 9)
			t.eq(out[1].count, 3, "the input stays")
		end)
		t.ok(not Transmitters.isItemAcceptor(FURNACE_BLOCK), "unbound: a plain block again")
		t.ok(not Transmitters.isItemAcceptor(B.CreativeEnergyCube), "a machine without slots is no inventory")
	end)

	--[[ Status, sustained data, protocol ]]

	t.test("status lines: the kind's, else from the rate (Producing, Using, Charging)", function()
		FakeMachines.bind(Machines, {
			{ B.OsmiumBlock, "test_producer", { capacity = 1000, output = 100 } },
			{ B.GoldBlock, "test_battery", { capacity = 1000, input = 100, output = 100 } },
		}, function()
			local function view(block: number, rate: number, input: number, output: number)
				return {
					block = block,
					energy = 0,
					capacity = 1,
					input = input,
					output = output,
					rate = rate,
					active = rate ~= 0,
				}
			end
			t.eq(Machines.status(B.OsmiumBlock, view(B.OsmiumBlock, 200, 0, 0)), "Producing 200 J/t")
			t.eq(Machines.status(B.OsmiumBlock, view(B.OsmiumBlock, -50, 0, 0)), "Using 50 J/t")
			t.eq(Machines.status(B.OsmiumBlock, view(B.OsmiumBlock, 0, 0, 0)), nil)
			t.eq(Machines.status(B.GoldBlock, view(B.GoldBlock, 0, 1500, 0)), "Charging 1.5 kJ/t")
			t.eq(Machines.status(B.GoldBlock, view(B.GoldBlock, 0, 0, 400)), "Discharging 400 J/t")
			t.eq(Machines.status(B.Stone, view(B.Stone, 5, 0, 0)), nil, "no machine")
		end)
		withFurnace(function()
			local v = Machines.view(Machines.newContainer(FURNACE_BLOCK))
			t.eq(Machines.status(FURNACE_BLOCK, v), "Idle", "the kind's own")
		end)
	end)

	t.test("sustained data: energy and kept fields into the item and back", function()
		FakeMachines.bind(
			Machines,
			{ { PRODUCER_BLOCK, "test_producer", { capacity = 5000, output = 100 } } },
			function()
				local c = Machines.newContainer(PRODUCER_BLOCK)
				t.eq(Machines.save(c), nil, "empty: a plain item")
				Machines.produce(c, 1234.5)
				Machines.set(c, "power", 40)
				Machines.set(c, "rate", 40)
				local data = Machines.save(c) :: any
				t.eq(data.energy, 1234.5)
				t.eq(data.power, 40, "a kept field")
				t.eq(data.rate, nil, "the header is not kept")
				t.ok(Items.validData(data) and table.isfrozen(data))
				t.eq(Items.describe({ item = PRODUCER_BLOCK, count = 1, data = data })[1], "Energy: 1.23 kJ")
				local fresh = Machines.newContainer(PRODUCER_BLOCK)
				t.ok(Machines.restore(fresh, data))
				t.eq(Machines.energy(fresh), 1234.5)
				t.eq(Machines.get(fresh, "power"), 40)
				-- More than it holds is cut to its capacity; nonsense is refused.
				t.ok(Machines.restore(fresh, { energy = 1e9 }))
				t.eq(Machines.energy(fresh), 5000)
				t.ok(not Machines.restore(fresh, { energy = -5 }))
				t.ok(not Machines.restore(fresh, { fluid = 1, amount = 5 }), "a tank's data")
				t.ok(not Machines.restore(fresh, nil))
				t.eq(Machines.energy(fresh), 5000, "unchanged by the refusals")
			end
		)
	end)

	t.test("protocol: Machines records round trip, malformed ones are refused", function()
		local records = {
			{
				x = -5,
				y = 70,
				z = 12,
				energy = 1234.5,
				capacity = 20000,
				input = 50,
				output = 0,
				rate = -50,
				active = true,
			},
			{
				x = 3,
				y = 0,
				z = -9,
				energy = math.huge,
				capacity = math.huge,
				input = 0,
				output = 8000,
				rate = 0,
				active = false,
			},
		}
		local decoded = Protocol.decodeMachines(Protocol.encodeMachines(records)) :: any
		t.eq(#decoded, 2)
		for i, record in records do
			for key, value in record do
				t.eq(decoded[i][key], value, `record {i} {key}`)
			end
		end
		t.eq(#(Protocol.decodeMachines(Protocol.encodeMachines({})) :: any), 0)
		t.eq(Protocol.decodeMachines(buffer.create(3)), nil, "too short")
		local b = Protocol.encodeMachines({ records[1] })
		t.eq(Protocol.decodeMachines(buffer.fromstring(buffer.tostring(b) .. "x")), nil, "a byte too many")
		local nan = buffer.fromstring(buffer.tostring(b))
		buffer.writef64(nan, 4 + 10, 0 / 0)
		t.eq(Protocol.decodeMachines(nan), nil, "NaN energy")
		local flags = buffer.fromstring(buffer.tostring(b))
		buffer.writeu8(flags, 4 + 38, 2)
		t.eq(Protocol.decodeMachines(flags), nil, "unknown flags")
		-- NaN is never sent.
		local sent = Protocol.decodeMachines(Protocol.encodeMachines({
			{ x = 0, y = 0, z = 0, energy = 0 / 0, capacity = 1, input = 0 / 0, output = 0, rate = 0, active = false },
		})) :: any
		t.eq(sent[1].energy, 0)
		t.eq(sent[1].input, 0)
		t.eq(Protocol.ServerMessage.Machines, 11)
	end)

	t.test("protocol: a machine's window travels with its kind, block and f64 data", function()
		withFurnace(function()
			local container = Machines.newContainer(FURNACE_BLOCK)
			container.slots[1] = S(I.RawIron, 3)
			Machines.produce(container, 12345.75)
			Machines.set(container, "progress", 7)
			local snapshot = { ack = 4, inventory = Types.newInventory(), window = 2, container = container }
			local decoded = Protocol.decodeInventory(Protocol.encodeInventory(snapshot :: any)) :: any
			t.eq(decoded.container.kind, "machine")
			t.eq(decoded.container.block, FURNACE_BLOCK)
			t.eq(decoded.container.size, 3)
			t.eq(decoded.container.slots[1].count, 3)
			t.eq(decoded.container.data[Machines.ENERGY], 12345.75)
			t.eq(decoded.container.data[Machines.CAPACITY], 20000)
			t.eq(decoded.container.data[kinds.furnace.index.progress], 7)
		end)
		local cube = Machines.newContainer(B.CreativeEnergyCube)
		local snapshot = { ack = 1, inventory = Types.newInventory(), window = 3, container = cube }
		local decoded = Protocol.decodeInventory(Protocol.encodeInventory(snapshot :: any)) :: any
		t.eq(decoded.container.data[1], math.huge, "infinity travels")
		t.eq(decoded.container.size, 0)
	end)

	--[[ Client: panels, the energy bar, WAILA ]]

	t.test("panels: a machine's panel is its kind's (slots, gauges, energy bar, status)", function()
		withFurnace(function()
			local container = Machines.newContainer(FURNACE_BLOCK)
			t.ok(MenuLayout.hasPanel(container))
			local panel = MenuLayout.panel(container)
			t.eq(panel.title, "Test Furnace")
			t.ok(panel.centred)
			t.eq(panel.height, 78)
			t.eq(#panel.slots, 3)
			t.eq(panel.slots[1].x, 56)
			t.eq(panel.slots[1].y, 17)
			t.ok(panel.slots[3].big, "the output's large frame")
			local energy = panel.energy :: any
			t.eq(energy.x, 164, "Mekanism's GuiVerticalPowerBar")
			t.eq(energy.y, 15)
			t.eq(energy.w, 6)
			t.eq(energy.h, 52)
			t.ok(energy.x + energy.w + 1 <= MenuLayout.WIDTH - 3, "inside the panel's bevel")
			t.eq((panel.progress :: any).w, MenuLayout.ARROW_WIDTH)
			t.eq((panel.flame :: any).w, MenuLayout.FLAME_SIZE)
			t.eq((panel.status :: any).y, 66)
			-- The gauges read the fields the kind names.
			local data = container.data :: any
			data[kinds.furnace.index.progress] = 10
			data[kinds.furnace.index.total] = 20
			t.eq(MenuLayout.machineArrowColumns(data, panel.progressSource), 12)
			data[kinds.furnace.index.burn] = 50
			t.eq(MenuLayout.machineFlameRows(data, panel.flameSource), 7, "a fixed total of 100")
			data[kinds.furnace.index.burn] = 0
			t.eq(MenuLayout.machineFlameRows(data, panel.flameSource), 0, "out")
			t.eq(MenuLayout.statusText(container), "Idle")
			t.eq(MenuLayout.panelKey(container), `machine:{FURNACE_BLOCK}:3`)
		end)
		-- The creative cube: no slots, the bar and its status line.
		local cube = Machines.newContainer(B.CreativeEnergyCube)
		local panel = MenuLayout.panel(cube)
		t.eq(panel.title, "Creative Energy Cube")
		t.eq(#panel.slots, 0)
		t.ok(panel.energy ~= nil and panel.status ~= nil)
		t.eq(MenuLayout.statusText(cube), "Infinite energy")
		local cubeData = cube.data :: any
		cubeData[Machines.OUTPUT] = 400
		t.eq(MenuLayout.statusText(cube), "Giving 400 J/t")
		t.eq(MenuLayout.statusText(nil), "")
		-- A machine container of a block the client does not know as a machine falls back to rows.
		local odd = { kind = "machine", block = B.Stone, size = 2, slots = {}, data = { 1, 2 } }
		t.eq(#MenuLayout.panel(odd :: any).slots, 2)
	end)

	t.test("energy bar: fill, Mekanism's red to green, never empty while it holds any", function()
		local function data(energy: number, capacity: number): { number }
			return { energy, capacity, 0, 0, 0, 0 }
		end
		t.eq(MenuLayout.energyRows(data(0, 1000), 52), 0)
		t.eq(MenuLayout.energyRows(data(1, 1000000), 52), 1, "a sliver")
		t.eq(MenuLayout.energyRows(data(500, 1000), 52), 26)
		t.eq(MenuLayout.energyRows(data(1000, 1000), 52), 52)
		t.eq(MenuLayout.energyRows(data(math.huge, math.huge), 52), 52, "creative: full")
		t.eq(MenuLayout.energyRows(nil, 52), 0)
		t.eq(MenuLayout.energyRows({ 0 / 0, 5 }, 52), 0, "NaN: empty")
		local red, green, half = MenuLayout.energyColour(0), MenuLayout.energyColour(1), MenuLayout.energyColour(0.5)
		t.ok(red[1] == 255 and red[2] == 0 and red[3] == 0, "empty: red")
		t.ok(green[1] == 0 and green[2] == 255 and green[3] == 0, "full: green")
		t.ok(half[1] == 255 and half[2] == 255, "half: yellow")
		t.eq(MenuLayout.energyTooltip(data(1200, 20000)), "1.2 kJ / 20 kJ")
		t.eq(MenuLayout.energyTooltip(data(math.huge, math.huge)), "Infinite")
		t.eq(MenuLayout.energyTooltip(nil), "0 J / 0 J")
	end)

	t.test("waila: a machine's energy and status, the creative cube, F3 details", function()
		FakeMachines.bind(
			Machines,
			{ { PRODUCER_BLOCK, "test_producer", { capacity = 20000, output = 400 } } },
			function()
				local facts = { energy = 1200, capacity = 20000, input = 0, output = 400, rate = 200, active = true }
				local info = WailaInfo.block(PRODUCER_BLOCK, nil, 1, 2, 3, false, { machine = facts })
				local texts = WailaInfo.texts(info)
				t.ok(table.find(texts, "Energy: 1.2 kJ / 20 kJ") ~= nil, "the energy line")
				t.ok(table.find(texts, "Producing 200 J/t") ~= nil, "the status line")
				t.eq(texts[#texts], "IceVoxel")
				local extended =
					WailaInfo.texts(WailaInfo.block(PRODUCER_BLOCK, nil, 1, 2, 3, true, { machine = facts }))
				t.ok(table.find(extended, "Machine test_producer (producer)") ~= nil, "kind and role")
				t.ok(table.find(extended, "Holds 20 kJ, in none, out 400 J/t") ~= nil, "the block's numbers")
				t.ok(table.find(extended, "Last tick: in 0 J, out 400 J") ~= nil, "flows")
				t.ok(table.find(extended, "Rate 200 J/t, active") ~= nil)
				-- Without a record: empty and idle at the block's capacity.
				local defaults = WailaInfo.machineDefaults(PRODUCER_BLOCK)
				t.eq(defaults.energy, 0)
				t.eq(defaults.capacity, 20000)
				t.eq(WailaInfo.text(WailaInfo.machineLines(PRODUCER_BLOCK, defaults)[1]), "Energy: 0 J / 20 kJ")
				t.eq(#WailaInfo.machineLines(PRODUCER_BLOCK, defaults), 1, "no status while idle")
			end
		)
		local cube = B.CreativeEnergyCube
		local lines = WailaInfo.machineLines(cube, WailaInfo.machineDefaults(cube))
		t.eq(WailaInfo.text(lines[1]), "Energy: Infinite")
		t.eq(WailaInfo.text(lines[2]), "Infinite energy")
		-- The context only counts for machines.
		local stone = WailaInfo.texts(WailaInfo.block(B.Stone, nil, 0, 0, 0, false, {
			machine = WailaInfo.machineDefaults(cube),
		}))
		t.eq(table.find(stone, "Energy: Infinite"), nil)
	end)
end

--[[
	Mekanism Generators' Heat Generator (Shared/Machines/Kinds/Generator, BlockList HeatGenerator):
	the block and Mekanism's numbers, the fuel slot's rules (hand, shift-click, transporters), the
	burning maths (a fuel item's furnace burn time at 200 J a tick, the next item lit without a gap,
	nothing burnt while full, part ticks when nearly full that waste nothing, item data clamped),
	feeding a network through the server's machines (MachineWorld, EnergyNet) at up to 400 J/t, a
	slow machine getting a whole coal's energy, sustained data, the recipe, the panel, WAILA's
	lines, the decor and
	the glowing window (TransmitterModel.machineBoxes), and its crackle (SoundRules).
]]

local FakeMachines = require("../lib/FakeMachines")

return function(t, shared, require, server, client)
	local Blocks = require(shared.Blocks)
	local Coords = require(shared.World.Coords)
	local Crafting = require(shared.Crafting)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local Menu = require(shared.Inventory.Menu)
	local Smelting = require(shared.Crafting.Smelting)
	local Transmitters = require(shared.Transmitters)
	local Types = require(shared.Inventory.Types)
	local Containers = require(server.Players.Containers)
	local EditRules = require(server.Network.EditRules)
	local MachineWorld = require(server.Machines.MachineWorld)
	local TransmitterWorld = require(server.Transmitters.TransmitterWorld)
	local BlockDecor = require(client.Rendering.BlockDecor)
	local TransmitterModel = require(client.Rendering.TransmitterModel)
	local SoundRules = require(client.Audio.SoundRules)
	local MenuLayout = require(client.Ui.MenuLayout)
	local WailaInfo = require(client.Ui.WailaInfo)

	local B = Blocks.id
	local I = Items.id
	local AIR = B.Air
	local Y = 64
	local GENERATOR = B.HeatGenerator
	local ENERGY = Machines.ENERGY
	-- Mekanism's numbers: heatGeneration, the storage and the output (twice what it makes).
	local MAKES, CAPACITY, OUTPUT = 200, 160000, 400
	FakeMachines.define(Machines, Items, Smelting)

	local function S(item: number, count: number)
		return { item = item, count = count }
	end

	local function ctx(): any
		return {
			block = GENERATOR,
			x = 0,
			y = Y,
			z = 0,
			energy = Machines.energyOf(GENERATOR),
			tick = 1,
			dayTime = 6000,
			getBlock = function()
				return nil
			end,
		}
	end

	local function tick(container: any, n: number?)
		for _ = 1, n or 1 do
			Machines.tick(container, ctx())
		end
	end

	local function field(container: any, name: string): number
		return Machines.get(container, name)
	end

	--[[ The block ]]

	t.test("heat generator: the block, its kind and Mekanism's numbers", function()
		local def = Blocks.get(GENERATOR)
		t.eq(Items.displayName(GENERATOR), "Heat Generator")
		t.eq(def.hardness, 3.5, "Mekanism's machines")
		t.eq(def.tool, "pickaxe")
		t.eq(def.toolLevel, 0, "any pickaxe")
		t.eq(def.sound, "metal")
		t.eq(def.decor, "HeatGenerator")
		t.eq(def.menu, "Machine", "right click opens its panel")
		t.eq(def.container, 0, "its slots are its kind's")
		t.ok(Machines.isMachine(GENERATOR))
		t.eq((Machines.kindOf(GENERATOR) :: any).name, "generator")
		t.eq(Machines.role(GENERATOR), "producer", "output only")
		local energy = Machines.energyOf(GENERATOR) :: any
		t.eq(energy.capacity, CAPACITY)
		t.eq(energy.output, OUTPUT)
		t.eq(energy.input, nil, "takes nothing from a network")
		t.eq(Machines.containerSize(GENERATOR), 1, "one fuel slot")
		t.ok(Transmitters.isEnergyAcceptor(GENERATOR), "cables connect to it")
		t.ok(Transmitters.isItemAcceptor(GENERATOR), "transporters too")
		t.eq(Items.drops(GENERATOR, nil), nil, "a pickaxe is needed for it to drop")
		t.eq((Items.drops(GENERATOR, I.WoodenPickaxe) :: any).item, GENERATOR)
		-- A fresh one: empty, out.
		local container = Machines.newContainer(GENERATOR)
		t.eq(container.size, 1)
		t.eq(Machines.energy(container), 0)
		t.eq(Machines.capacity(container), CAPACITY)
		t.eq(field(container, "burnTime"), 0)
		t.eq(field(container, "burnTotal"), 0)
		local input, output = Machines.rates(container)
		t.eq(input, 0)
		t.eq(output, OUTPUT)
	end)

	t.test("heat generator: Mekanism's recipe with iron for the copper", function()
		local function craft(rows: { { number? } }): any
			local stacks = {}
			for row = 1, 3 do
				for column = 1, 3 do
					local item = rows[row][column]
					if item then
						stacks[(row - 1) * 3 + column] = S(item, 1)
					end
				end
			end
			return Crafting.match(stacks, 3)
		end
		local Fe, O, F = I.IronIngot, I.OsmiumIngot, I.Furnace
		for _, planks in { I.Planks, I.BirchPlanks, I.JunglePlanks } do
			local made = craft({ { Fe, Fe, Fe }, { planks, O, planks }, { Fe, F, Fe } })
			t.eq(made and made.item, GENERATOR, "any planks")
			t.eq(made and made.count, 1)
			t.eq(made and made.data, nil, "a crafted generator carries no data")
		end
		local P = I.Planks
		t.eq(craft({ { Fe, Fe, Fe }, { P, Fe, P }, { Fe, F, Fe } }), nil, "osmium in the middle")
		t.eq(craft({ { Fe, Fe, Fe }, { P, O, P }, { Fe, I.Cobblestone, Fe } }), nil, "a furnace below it")
	end)

	--[[ The fuel slot ]]

	t.test("heat generator: the fuel slot takes what burns in a furnace, by hand and shift-click", function()
		for _, item in { I.Coal, I.Charcoal, I.CoalBlock, I.OakLog, I.Planks, I.Stick, I.WoodenPickaxe, I.Chest } do
			t.ok(Machines.mayPlace(GENERATOR, 1, item), `{Items.displayName(item)} burns`)
			t.eq(table.concat(Machines.quickMoveTargets(GENERATOR, item), ","), "1")
		end
		for _, item in { I.Cobblestone, I.IronIngot, I.Diamond, I.RawOsmium, I.Bucket, I.WaterBucket } do
			t.ok(not Machines.mayPlace(GENERATOR, 1, item), `{Items.displayName(item)} doesn't`)
			t.eq(#Machines.quickMoveTargets(GENERATOR, item), 0)
		end
		t.ok(not Machines.isOutput(GENERATOR, 1))
		t.eq(Machines.slotLimit(GENERATOR, 1, I.Coal), 64)
		t.eq(Machines.slotLimit(GENERATOR, 1, I.WoodenPickaxe), 1, "a tool stacks to 1")

		-- Through Inventory/Menu, as the client predicts and the server runs it.
		local container = Machines.newContainer(GENERATOR)
		local inventory = Types.newInventory()
		local window: any = { id = 1, inventory = inventory, container = container }
		local function slotOf(index: number): number
			return Menu.windowIndex(window, "inventory", index) :: number
		end
		inventory.slots[1] = S(I.Coal, 40)
		inventory.slots[2] = S(I.Diamond, 3)
		Menu.apply(window, { kind = "click", window = 1, slot = slotOf(1), clickType = 1, button = 0 }, false)
		t.eq(container.slots[1] and container.slots[1].count, 40, "coal into the fuel slot")
		t.eq(inventory.slots[1], nil)
		Menu.apply(window, { kind = "click", window = 1, slot = slotOf(2), clickType = 1, button = 0 }, false)
		t.eq(container.slots[1].item, I.Coal, "diamonds don't burn")
		t.eq(inventory.slots[2], nil)
		t.eq(inventory.slots[10] and inventory.slots[10].count, 3, "to the main inventory instead")
		inventory.cursor = S(I.Diamond, 1)
		container.slots[1] = nil
		Menu.apply(window, { kind = "click", window = 1, slot = 0, clickType = 0, button = 0 }, false)
		t.eq(container.slots[1], nil, "a click can't put a diamond in")
		t.eq(inventory.cursor and inventory.cursor.item, I.Diamond)
		-- Taking the fuel back out by hand works.
		inventory.cursor = nil
		container.slots[1] = S(I.Coal, 5)
		Menu.apply(window, { kind = "click", window = 1, slot = 0, clickType = 0, button = 0 }, false)
		t.eq(inventory.cursor and inventory.cursor.count, 5)
		t.eq(container.slots[1], nil)
	end)

	t.test("heat generator: transporters put fuel in through every face and take nothing out", function()
		for face = 0, 5 do
			t.eq(table.concat(Machines.insertSlots(GENERATOR, face), ","), "1", `face {face} takes fuel`)
			t.eq(#Machines.extractSlots(GENERATOR, face), 0, `face {face} gives nothing`)
		end
		local slots = {}
		local after, left = Transmitters.insert(GENERATOR, 3, slots, S(I.Coal, 70))
		t.eq(after[1].count, 64)
		t.eq(left and left.count, 6)
		t.eq(Transmitters.room(GENERATOR, 1, {}, S(I.Cobblestone, 5)), 0, "only fuel")
		t.eq(#Transmitters.available(GENERATOR, 0, { [1] = S(I.Coal, 3) }), 0, "nothing to pull")
	end)

	--[[ Burning ]]

	t.test("heat generator: a fuel item burns for its furnace time at 200 J a tick, no gap between items", function()
		local container: any = Machines.newContainer(GENERATOR)
		container.slots[1] = S(I.Coal, 2)
		local coal = Smelting.fuel(I.Coal)
		t.eq(coal, 1600)
		local made = 0
		for i = 1, 2 * coal do
			tick(container)
			made += Machines.energy(container)
			-- (The network takes everything at once: it never fills.)
			container.data[ENERGY] = 0
			t.eq(field(container, "rate"), MAKES, `tick {i}: 200 J`)
			t.eq(field(container, "active"), 1)
			if i < 2 * coal then
				t.ok(field(container, "burnTime") > 0, `tick {i}: the flame never goes out`)
				t.eq(field(container, "burnTotal"), coal)
			end
			if i == 1 then
				t.eq(container.slots[1].count, 1, "an item is used up when it lights")
				t.eq(field(container, "burnTime"), coal - 1)
			elseif i == coal then
				t.eq(container.slots[1], nil, "the next lights the tick the first runs out")
				t.eq(field(container, "burnTime"), coal)
			end
		end
		t.eq(made, 2 * coal * MAKES, "a coal is 320 kJ")
		t.eq(field(container, "burnTime"), 0)
		t.eq(field(container, "burnTotal"), 0, "out: no flame")
		tick(container)
		t.eq(Machines.energy(container), 0)
		t.eq(field(container, "rate"), 0)
		t.eq(field(container, "active"), 0)
		t.eq(Machines.status(GENERATOR, Machines.view(container)), "Idle")
		-- Other fuels: their furnace burn times.
		for _, item in { I.Stick, I.Planks, I.CoalBlock } do
			local c: any = Machines.newContainer(GENERATOR)
			c.slots[1] = S(item, 1)
			local ticks = 0
			repeat
				tick(c)
				ticks += 1
				c.data[ENERGY] = 0
			until field(c, "rate") == 0 or ticks > 20000
			t.eq(ticks - 1, Smelting.fuel(item), `{Items.displayName(item)} burns its furnace time`)
		end
		-- A damaged wooden tool burns too; nothing is left of it.
		local tool: any = Machines.newContainer(GENERATOR)
		tool.slots[1] = { item = I.WoodenPickaxe, count = 1, damage = 30 }
		tick(tool)
		t.eq(tool.slots[1], nil)
		t.eq(field(tool, "burnTime"), Smelting.fuel(I.WoodenPickaxe) - 1)
	end)

	t.test("heat generator: nothing burns while it is full; it goes on when the network takes some", function()
		local container: any = Machines.newContainer(GENERATOR)
		container.slots[1] = S(I.Coal, 3)
		container.data[ENERGY] = CAPACITY - 50
		tick(container)
		t.eq(Machines.energy(container), CAPACITY, "the last 50 J")
		t.eq(field(container, "rate"), 50)
		t.eq(field(container, "active"), 1)
		t.eq(field(container, "burnTime"), 1599.75, "a quarter of a tick burnt for them: nothing wasted")
		t.eq(container.slots[1].count, 2)
		t.eq(Machines.status(GENERATOR, Machines.view(container)), "Producing 50 J/t")
		tick(container, 100)
		t.eq(field(container, "burnTime"), 1599.75, "full: the item waits")
		t.eq(field(container, "rate"), 0)
		t.eq(field(container, "active"), 0)
		t.eq(field(container, "burnTotal"), 1600, "the flame stays")
		t.eq(container.slots[1].count, 2, "and nothing new lights")
		t.eq(Machines.status(GENERATOR, Machines.view(container)), "Idle")
		container.data[ENERGY] = CAPACITY - OUTPUT
		tick(container)
		t.eq(Machines.energy(container), CAPACITY - OUTPUT + MAKES)
		t.eq(field(container, "burnTime"), 1598.75)
		t.eq(Machines.status(GENERATOR, Machines.view(container)), "Producing 200 J/t")
		-- Out of burn time while full: the next item waits in its slot.
		local waiting: any = Machines.newContainer(GENERATOR)
		waiting.slots[1] = S(I.Coal, 1)
		waiting.data[ENERGY] = CAPACITY
		tick(waiting, 10)
		t.eq(waiting.slots[1].count, 1, "no room: nothing lights")
		t.eq(field(waiting, "burnTime"), 0)
		t.eq(field(waiting, "burnTotal"), 0)
		waiting.data[ENERGY] = 0
		tick(waiting)
		t.eq(waiting.slots[1], nil)
		t.eq(Machines.energy(waiting), MAKES)
		-- No fuel: nothing; non-fuel that got in somehow: nothing either.
		local junk: any = Machines.newContainer(GENERATOR)
		junk.slots[1] = S(I.Cobblestone, 4)
		tick(junk, 5)
		t.eq(junk.slots[1].count, 4)
		t.eq(Machines.energy(junk), 0)
	end)

	t.test("heat generator: part ticks are exact, and the next item makes the rest of a tick", function()
		-- Two sticks (100 ticks, 20 kJ each), the first started with 50 J of room.
		local container: any = Machines.newContainer(GENERATOR)
		container.slots[1] = S(I.Stick, 2)
		container.data[ENERGY] = CAPACITY - 50
		tick(container)
		local made = 50
		t.eq(field(container, "burnTime"), 99.75)
		for i = 1, 99 do
			container.data[ENERGY] = 0
			tick(container)
			made += Machines.energy(container)
			t.eq(field(container, "rate"), MAKES, `tick {i}`)
		end
		t.eq(field(container, "burnTime"), 0.75, "three quarters of a tick left")
		t.eq(container.slots[1].count, 1)
		container.data[ENERGY] = 0
		tick(container)
		made += Machines.energy(container)
		t.eq(field(container, "rate"), MAKES, "150 J from the first stick and 50 J from the second")
		t.eq(container.slots[1], nil, "the second lit in the same tick")
		t.eq(field(container, "burnTime"), 99.75)
		t.eq(field(container, "burnTotal"), 100)
		repeat
			container.data[ENERGY] = 0
			tick(container)
			made += Machines.energy(container)
		until field(container, "rate") == 0
		t.eq(made, 2 * 100 * MAKES, "two sticks' energy, exactly")
		t.eq(field(container, "burnTime"), 0)
		t.eq(field(container, "burnTotal"), 0)

		-- Odd amounts of room (a network taking 1/1024 J steps) never make or lose anything.
		local odd: any = Machines.newContainer(GENERATOR)
		odd.slots[1] = S(I.Stick, 1)
		local total, steps = 0, 0
		repeat
			steps += 1
			local room = 1 + (steps * 37 % 199) + (steps % 7) * Machines.QUANTUM
			odd.data[ENERGY] = CAPACITY - room
			tick(odd)
			local got = Machines.energy(odd) - (CAPACITY - room)
			t.ok(got <= room, "within its room")
			total += got
		until field(odd, "rate") == 0 or steps > 100000
		t.eq(total, 100 * MAKES, "a stick's energy, to the quantum")
	end)

	t.test("heat generator: burn fields from an item's data are kept sane", function()
		-- Item data comes from anywhere a stack can (creative's slot packet): clamp it.
		local longest = 0
		for _, fuel in Smelting.fuels() do
			longest = math.max(longest, fuel.ticks)
		end
		local forged: any = Machines.newContainer(GENERATOR)
		t.ok(Machines.restore(forged, { burnTime = 1e300, burnTotal = 5 }))
		tick(forged)
		t.eq(field(forged, "burnTime"), longest - 1, "no longer than the longest fuel")
		t.eq(field(forged, "burnTotal"), longest - 1, "the flame never more than full")
		local negative: any = Machines.newContainer(GENERATOR)
		Machines.restore(negative, { burnTime = -40, burnTotal = 1600 })
		tick(negative)
		t.eq(field(negative, "burnTime"), 0)
		t.eq(field(negative, "burnTotal"), 0, "out")
		t.eq(field(negative, "rate"), 0)
		-- Less than a quantum of energy left: out, and the next item lights.
		local crumb: any = Machines.newContainer(GENERATOR)
		crumb.slots[1] = S(I.Stick, 1)
		Machines.restore(crumb, { burnTime = 1e-9, burnTotal = 100 })
		tick(crumb)
		t.eq(crumb.slots[1], nil)
		t.eq(field(crumb, "burnTime"), 99)
		t.eq(field(crumb, "rate"), MAKES)
	end)

	--[[ On the server ]]

	-- Machines in a world of blocks, ticked as the server does (cables, machines, networks).
	local function sim()
		local blocks: { [number]: number } = {}
		local containers = Containers.new()
		local function getBlock(x: number, y: number, z: number): number?
			return blocks[Coords.posKey(x, y, z)] or AIR
		end
		local cables = TransmitterWorld.new({ getBlock = getBlock, containers = containers })
		local world = MachineWorld.new({
			getBlock = getBlock,
			containers = containers,
			transmitters = cables,
			dayTime = function()
				return 6000
			end,
		})
		local self = {}
		function self.set(x: number, y: number, z: number, block: number)
			local key = Coords.posKey(x, y, z)
			local old = blocks[key] or AIR
			blocks[key] = if block == AIR then nil else block
			TransmitterWorld.blockChanged(cables, x, y, z, old, block)
			MachineWorld.blockChanged(world, x, y, z, old, block)
		end
		function self.step(n: number?)
			for _ = 1, n or 1 do
				TransmitterWorld.step(cables)
				MachineWorld.step(world)
			end
		end
		function self.container(x: number, y: number, z: number): any
			local machine = MachineWorld.machine(world, x, y, z)
			assert(machine, "no machine")
			return machine.container
		end
		self.world = world
		self.cables = cables
		return self
	end

	t.test("heat generator: feeds machines by cable or touching, at most 400 J/t", function()
		FakeMachines.bind(Machines, {
			-- A machine that stores whatever it gets (uses nothing).
			{ B.IronBlock, "test_consumer", { capacity = 1e7, input = 1000 } },
		}, function()
			local s = sim()
			s.set(0, Y, 0, GENERATOR)
			s.set(1, Y, 0, B.BasicUniversalCable)
			s.set(2, Y, 0, B.IronBlock)
			local generator, consumer = s.container(0, Y, 0), s.container(2, Y, 0)
			generator.slots[1] = S(I.Coal, 1)
			generator.data[ENERGY] = 10000
			s.step()
			-- It made 200, then gave its output rate.
			t.eq(Machines.energy(consumer), OUTPUT, "400 J/t out, twice what it makes")
			t.eq(Machines.energy(generator), 10000 + MAKES - OUTPUT)
			t.eq(generator.data[Machines.OUTPUT], OUTPUT)
			s.step(4)
			t.eq(Machines.energy(consumer), 5 * OUTPUT)
			-- With nothing stored, what it makes goes straight on: 200 J/t.
			generator.data[ENERGY] = 0
			local before = Machines.energy(consumer)
			s.step()
			t.eq(Machines.energy(consumer) - before, MAKES)
			t.eq(Machines.energy(generator), 0)
			-- A record tells players near it that it burns.
			local records = MachineWorld.takeRecords(s.world)
			local found = nil
			for _, record in records do
				if record.x == 0 and record.y == Y and record.z == 0 then
					found = record
				end
			end
			t.ok(found and found.active and found.rate == MAKES, "the generator's record: active, 200 J/t")
			-- Touching, without a cable.
			local u = sim()
			u.set(0, Y, 0, GENERATOR)
			u.set(0, Y + 1, 0, B.IronBlock)
			u.container(0, Y, 0).slots[1] = S(I.Stick, 1)
			u.step(3)
			t.eq(Machines.energy(u.container(0, Y + 1, 0)), 3 * MAKES)
		end)
	end)

	t.test("heat generator: a stick's worth of energy, exactly, through the network", function()
		FakeMachines.bind(Machines, {
			{ B.IronBlock, "test_consumer", { capacity = 1e7, input = 1000 } },
		}, function()
			local s = sim()
			s.set(0, Y, 0, GENERATOR)
			s.set(1, Y, 0, B.IronBlock)
			s.container(0, Y, 0).slots[1] = S(I.Stick, 3)
			s.step(1000)
			t.eq(Machines.energy(s.container(1, Y, 0)), 3 * Smelting.fuel(I.Stick) * MAKES, "never made or lost")
			t.eq(Machines.energy(s.container(0, Y, 0)), 0)
			t.eq(s.container(0, Y, 0).slots[1], nil)
		end)
	end)

	t.test("heat generator: a slow machine gets all of a coal's energy, none wasted", function()
		FakeMachines.bind(Machines, {
			-- Takes 50 J/t (an electric furnace's use), less than the generator makes.
			{ B.IronBlock, "test_consumer", { capacity = 1e7, input = 50 } },
		}, function()
			local s = sim()
			s.set(0, Y, 0, GENERATOR)
			s.set(1, Y, 0, B.IronBlock)
			local generator, consumer = s.container(0, Y, 0), s.container(1, Y, 0)
			generator.slots[1] = S(I.Coal, 1)
			-- (It fills its store at 150 J/t, then burns a quarter of a tick each tick.)
			s.step(1100)
			t.eq(Machines.energy(generator), CAPACITY - 50, "full, less what the machine just took")
			t.eq(Machines.get(generator, "rate"), 50, "making what the machine takes")
			t.eq(Machines.get(generator, "active"), 1)
			s.step(2200)
			t.eq(Machines.get(generator, "burnTime"), 0, "the coal is burnt")
			t.eq(Machines.get(generator, "rate"), 0)
			t.eq(Machines.energy(generator) + Machines.energy(consumer), Smelting.fuel(I.Coal) * MAKES, "320 kJ")
		end)
	end)

	t.test("heat generator: keeps its energy and what is left burning in its item", function()
		local s = sim()
		local registry = EditRules.newBlockData()
		registry:add(TransmitterWorld.blockDataHooks(s.cables))
		registry:add(MachineWorld.blockDataHooks(s.world))
		s.set(0, Y, 0, GENERATOR)
		local container = s.container(0, Y, 0)
		container.slots[1] = S(I.Coal, 5)
		s.step(400)
		t.eq(Machines.energy(container), 400 * MAKES)
		t.eq(Machines.get(container, "burnTime"), 1200)
		local drop = EditRules.breakDrop(registry, 0, Y, 0, GENERATOR, false, I.IronPickaxe) :: any
		s.set(0, Y, 0, AIR)
		t.eq(drop.item, GENERATOR)
		t.eq(drop.data.energy, 80000)
		t.eq(drop.data.burnTime, 1200)
		t.eq(drop.data.burnTotal, 1600)
		local lines = Items.describe(drop)
		t.eq(lines[1], "Energy: 80 kJ")
		t.eq(lines[2], "Fuel: 60 s", "1 200 ticks")
		-- Placed again it burns on from there.
		s.set(3, Y, 0, GENERATOR)
		registry:placed("p", 3, Y, 0, GENERATOR, drop)
		local placed = s.container(3, Y, 0)
		t.eq(Machines.energy(placed), 80000)
		t.eq(Machines.get(placed, "burnTime"), 1200)
		s.step()
		t.eq(Machines.energy(placed), 80000 + MAKES)
		t.eq(Machines.get(placed, "burnTime"), 1199)
		-- One that is out and empty drops a plain item (it stacks with new ones).
		s.set(5, Y, 0, GENERATOR)
		local plain = EditRules.breakDrop(registry, 5, Y, 0, GENERATOR, false, I.IronPickaxe) :: any
		t.eq(plain.data, nil)
		t.eq(#Items.describe(plain), 0)
	end)

	--[[ What players see ]]

	t.test("heat generator: its panel, status line and WAILA lines", function()
		local container: any = Machines.newContainer(GENERATOR)
		local panel = MenuLayout.panel(container)
		t.eq(panel.title, "Heat Generator")
		t.eq(#panel.slots, 1)
		t.eq(panel.slots[1].x, 80)
		t.eq(panel.slots[1].y, 53)
		local flame = panel.flame :: any
		t.eq(flame.x, 80)
		t.eq(flame.y, 36, "over the slot, Minecraft's spacing")
		local energy = panel.energy :: any
		t.eq(energy.x, 164, "Mekanism's power bar")
		local status = panel.status :: any
		t.eq(status.x, 8)
		t.eq(status.y, 20)
		t.ok(status.y + 8 <= flame.y, "the status line clears the flame")
		-- The flame shows the burn time left.
		t.eq(MenuLayout.machineFlameRows(container.data, panel.flameSource), 0, "out")
		container.slots[1] = S(I.Coal, 1)
		tick(container)
		t.eq(MenuLayout.machineFlameRows(container.data, panel.flameSource), 12 + 1, "1 599 of 1 600 left")
		Machines.set(container, "burnTime", 1600)
		t.eq(MenuLayout.machineFlameRows(container.data, panel.flameSource), 13 + 1, "full")
		Machines.set(container, "burnTime", 800)
		t.eq(MenuLayout.machineFlameRows(container.data, panel.flameSource), 6 + 1, "half")
		t.eq(MenuLayout.statusText(container), "Producing 200 J/t")
		-- WAILA: energy and the status, from the record.
		local facts = WailaInfo.machineDefaults(GENERATOR)
		local lines = WailaInfo.machineLines(GENERATOR, facts)
		t.eq(WailaInfo.text(lines[1]), "Energy: 0 J / 160 kJ")
		t.eq(WailaInfo.text(lines[2]), "Idle")
		facts.energy, facts.rate, facts.active, facts.output = 12345, MAKES, true, 400
		lines = WailaInfo.machineLines(GENERATOR, facts)
		t.eq(WailaInfo.text(lines[1]), "Energy: 12.34 kJ / 160 kJ")
		t.eq(WailaInfo.text(lines[2]), "Producing 200 J/t")
		facts.rate = 50
		t.eq(WailaInfo.text(WailaInfo.machineLines(GENERATOR, facts)[2]), "Producing 50 J/t", "nearly full")
		local details = WailaInfo.machineDetails(GENERATOR, facts)
		t.eq(WailaInfo.text(details[1]), "Machine generator (producer)")
		t.eq(WailaInfo.text(details[2]), "Holds 160 kJ, in none, out 400 J/t")
	end)

	t.test("heat generator: decor with a dark window that glows while it burns", function()
		local faces = BlockDecor.faces("HeatGenerator") :: any
		t.ok(faces ~= nil)
		local window = BlockDecor.GENERATOR_WINDOW
		for _, face in { "Front", "Back", "Left", "Right" } do
			local found = false
			for _, r in faces[face] do
				if r.x == window.x and r.y == window.y and r.w == window.w and r.h == window.h then
					found = true
				end
			end
			t.ok(found, `{face}: the fuel window`)
		end
		local parts = BlockDecor.partCount("HeatGenerator")
		t.ok(parts > 0 and parts < 40, `item model slabs: {parts}`)
		-- The glow: a cell of TransmitterRenderer's, lit only while its record says it works.
		t.ok(TransmitterModel.hasMachineBoxes(GENERATOR))
		t.ok(not TransmitterModel.hasMachineBoxes(B.CreativeEnergyCube), "the cube shows nothing more")
		t.ok(not TransmitterModel.hasMachineBoxes(B.Furnace), "no machine")
		t.ok(not TransmitterModel.hasMachineBoxes(B.Stone))
		local none, unlit = TransmitterModel.machineBoxes(GENERATOR, nil)
		t.eq(#none, 0, "no record: out")
		local idle, idleSignature =
			TransmitterModel.machineBoxes(GENERATOR, { active = false, energy = 5, capacity = 9 })
		t.eq(#idle, 0)
		t.eq(idleSignature, unlit, "out either way")
		local boxes, lit = TransmitterModel.machineBoxes(GENERATOR, { active = true, energy = 0, capacity = 9 })
		t.ok(lit ~= unlit, "lit looks different")
		t.eq(#boxes, 4, "a pane on each side")
		local depth = TransmitterModel.GLOW_DEPTH
		local sides: { [string]: boolean } = {}
		for _, box in boxes do
			t.eq(box.kind, "glow")
			t.eq(table.concat(box.colour, ","), table.concat(TransmitterModel.GLOW_COLOUR, ","))
			-- Just outside one side face, over the window.
			t.eq(box.size[2], window.h)
			t.eq(box.offset[2], 8 - (window.y + window.h / 2))
			local normalAxis = if box.size[1] == depth then 1 else 3
			local acrossAxis = 4 - normalAxis
			t.eq(box.size[normalAxis], depth)
			t.eq(box.size[acrossAxis], window.w)
			t.eq(math.abs(box.offset[normalAxis]), 8 + depth / 2, "out of the face")
			t.eq(box.offset[acrossAxis], 0, "the window is centred")
			sides[`{normalAxis}{if box.offset[normalAxis] > 0 then "+" else "-"}`] = true
		end
		t.ok(sides["1+"] and sides["1-"] and sides["3+"] and sides["3-"], "all four sides")
		t.eq(#TransmitterModel.machineBoxes(B.Stone, { active = true, energy = 0, capacity = 1 }), 0)
	end)

	t.test("heat generator: crackles like a lit furnace while it burns", function()
		t.ok(SoundRules.crackles(GENERATOR))
		t.ok(not SoundRules.crackles(B.CreativeEnergyCube))
		t.ok(not SoundRules.crackles(B.Stone))
		t.ok(not SoundRules.crackles(-1), "no block")
		t.eq(SoundRules.CRACKLE_RANGE, 16, "Minecraft's animateTick reach")
	end)
end

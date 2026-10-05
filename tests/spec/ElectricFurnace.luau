--[[
	Mekanism's Energized Smelter, named the Electric Furnace (Shared/Machines/Kinds/Smelter,
	BlockList ElectricFurnace): the block and Mekanism's numbers, the recipe, the slots' rules
	(hand, shift-click, transporters through their sides), smelting (200 ticks at 50 J a tick, an
	item at a time), the power cut (the progress waits), a full output and another item, data
	from elsewhere, the server's machines (a Heat Generator feeding it by cable, the creative cube
	filling it in a tick, records with its state), sustained energy, the panel, the status line
	and WAILA's lines, the decor and glowing window, and JEI's smelting catalyst.
]]

return function(t, shared, require, server, client)
	local Blocks = require(shared.Blocks)
	local Coords = require(shared.World.Coords)
	local Crafting = require(shared.Crafting)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local Menu = require(shared.Inventory.Menu)
	local Protocol = require(shared.Net.Protocol)
	local Smelting = require(shared.Crafting.Smelting)
	local Transmitters = require(shared.Transmitters)
	local Types = require(shared.Inventory.Types)
	local Containers = require(server.Players.Containers)
	local EditRules = require(server.Network.EditRules)
	local MachineWorld = require(server.Machines.MachineWorld)
	local TransmitterWorld = require(server.Transmitters.TransmitterWorld)
	local BlockDecor = require(client.Rendering.BlockDecor)
	local TransmitterModel = require(client.Rendering.TransmitterModel)
	local JeiData = require(client.Ui.Jei.JeiData)
	local MenuLayout = require(client.Ui.MenuLayout)
	local WailaInfo = require(client.Ui.WailaInfo)

	local B = Blocks.id
	local I = Items.id
	local AIR = B.Air
	local Y = 64
	local FURNACE = B.ElectricFurnace
	local ENERGY = Machines.ENERGY
	-- Mekanism's Energized Smelter: J a tick of work, ticks an item, the storage.
	local USE, TICKS, CAPACITY = 50, 200, 20000
	-- Slots and faces.
	local INPUT, OUTPUT = 1, 2
	local DOWN, UP = 0, 1

	local function S(item: number, count: number)
		return { item = item, count = count }
	end

	local function ctx(): any
		return {
			block = FURNACE,
			x = 0,
			y = Y,
			z = 0,
			energy = Machines.energyOf(FURNACE),
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

	local function status(container: any): string?
		return Machines.status(FURNACE, Machines.view(container))
	end

	-- A fresh furnace holding `energy` J with `input` in its input slot.
	local function furnace(energy: number, input: any?): any
		local container: any = Machines.newContainer(FURNACE)
		container.data[ENERGY] = energy
		container.slots[INPUT] = input
		return container
	end

	--[[ The block ]]

	t.test("electric furnace: the block, its kind and Mekanism's numbers", function()
		local def = Blocks.get(FURNACE)
		t.eq(Items.displayName(FURNACE), "Electric Furnace")
		t.eq(def.hardness, 3.5, "Mekanism's machines")
		t.eq(def.tool, "pickaxe")
		t.eq(def.toolLevel, 0, "any pickaxe")
		t.eq(def.sound, "metal")
		t.eq(def.decor, "ElectricFurnace")
		t.eq(def.menu, "Machine", "right click opens its panel")
		t.eq(def.container, 0, "its slots are its kind's")
		t.ok(Machines.isMachine(FURNACE))
		t.eq((Machines.kindOf(FURNACE) :: any).name, "smelter")
		t.eq(Machines.role(FURNACE), "consumer", "input only")
		local energy = Machines.energyOf(FURNACE) :: any
		t.eq(energy.capacity, CAPACITY)
		t.eq(energy.input, CAPACITY, "up to its storage a tick")
		t.eq(energy.output, nil, "gives nothing to a network")
		t.eq(Machines.containerSize(FURNACE), 2, "input and output (upgrades come later)")
		t.ok(Transmitters.isEnergyAcceptor(FURNACE), "cables connect to it")
		t.ok(Transmitters.isItemAcceptor(FURNACE), "transporters too")
		t.eq(Items.drops(FURNACE, nil), nil, "a pickaxe is needed for it to drop")
		t.eq((Items.drops(FURNACE, I.WoodenPickaxe) :: any).item, FURNACE)
		-- The data layout: the shared header, then its fields (room left for 4 more values).
		local kind = Machines.kindOf(FURNACE) :: any
		t.eq(kind.index.progress, Machines.HEADER + 1)
		t.eq(kind.index.ticksRequired, Machines.HEADER + 2)
		t.eq(kind.index.energyPerTick, Machines.HEADER + 3)
		t.eq(kind.index.smelting, Machines.HEADER + 4)
		t.eq(kind.index.state, Machines.HEADER + 5)
		t.eq(kind.index.activeDelay, Machines.HEADER + 6)
		t.eq(kind.size, 12)
		t.ok(kind.size <= Types.MAX_CONTAINER_DATA)
		t.eq(#kind.keep, 0, "only its energy goes into its item")
		-- A fresh one: empty, idle; the first tick sets its numbers.
		local container = Machines.newContainer(FURNACE)
		t.eq(container.size, 2)
		t.eq(Machines.energy(container), 0)
		t.eq(Machines.capacity(container), CAPACITY)
		tick(container)
		t.eq(field(container, "ticksRequired"), TICKS)
		t.eq(field(container, "energyPerTick"), USE)
		t.eq(Machines.capacity(container), CAPACITY)
		t.eq(field(container, "progress"), 0)
		t.eq(status(container), "Idle")
		local input, output = Machines.rates(container)
		t.eq(input, CAPACITY, "Mekanism's machines take any amount: up to their capacity")
		t.eq(output, 0)
	end)

	t.test("electric furnace: Mekanism's recipe with glowstone, osmium and a furnace", function()
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
		local D, O, G, F = I.GlowstoneDust, I.OsmiumIngot, I.Glass, I.Furnace
		local made = craft({ { D, O, D }, { G, F, G }, { D, O, D } })
		t.eq(made and made.item, FURNACE)
		t.eq(made and made.count, 1)
		t.eq(made and made.data, nil, "a crafted furnace carries no data")
		t.eq(craft({ { D, O, D }, { G, I.Cobblestone, G }, { D, O, D } }), nil, "a furnace in the middle")
		t.eq(craft({ { D, I.IronIngot, D }, { G, F, G }, { D, O, D } }), nil, "osmium for the circuits")
		t.eq(craft({ { D, O, D }, { I.Sand, F, I.Sand }, { D, O, D } }), nil, "glass at the sides")
	end)

	--[[ Slots ]]

	t.test("electric furnace: the input takes what smelts; the output only gives", function()
		for _, item in { I.RawIron, I.IronOre, I.RawOsmium, I.Sand, I.Cobblestone, I.OakLog, I.IronPickaxe } do
			t.ok(Machines.mayPlace(FURNACE, INPUT, item), `{Items.displayName(item)} smelts`)
			t.eq(table.concat(Machines.quickMoveTargets(FURNACE, item), ","), "1")
		end
		for _, item in { I.Coal, I.Dirt, I.Diamond, I.Stick, I.IronIngot, I.Glass } do
			t.ok(not Machines.mayPlace(FURNACE, INPUT, item), `{Items.displayName(item)} doesn't`)
			t.eq(#Machines.quickMoveTargets(FURNACE, item), 0)
		end
		t.ok(not Machines.isOutput(FURNACE, INPUT))
		t.ok(Machines.isOutput(FURNACE, OUTPUT))
		t.ok(not Machines.mayPlace(FURNACE, OUTPUT, I.IronIngot), "nothing goes into the output")
		t.ok(not Machines.mayPlace(FURNACE, 3, I.RawIron), "no slot 3 yet")
		t.eq(Machines.slotLimit(FURNACE, INPUT, I.RawIron), 64)
		t.eq(Machines.slotLimit(FURNACE, INPUT, I.IronPickaxe), 1, "a tool stacks to 1")

		-- Through Inventory/Menu, as the client predicts and the server runs it.
		local container = Machines.newContainer(FURNACE)
		local inventory = Types.newInventory()
		local window: any = { id = 1, inventory = inventory, container = container }
		local function slotOf(index: number): number
			return Menu.windowIndex(window, "inventory", index) :: number
		end
		inventory.slots[1] = S(I.RawIron, 40)
		inventory.slots[2] = S(I.Diamond, 3)
		Menu.apply(window, { kind = "click", window = 1, slot = slotOf(1), clickType = 1, button = 0 }, false)
		t.eq(container.slots[INPUT] and container.slots[INPUT].count, 40, "raw iron into the input")
		t.eq(inventory.slots[1], nil)
		Menu.apply(window, { kind = "click", window = 1, slot = slotOf(2), clickType = 1, button = 0 }, false)
		t.eq(container.slots[OUTPUT], nil, "diamonds don't smelt")
		t.eq(inventory.slots[2], nil)
		t.eq(inventory.slots[10] and inventory.slots[10].count, 3, "to the main inventory instead")
		inventory.cursor = S(I.RawIron, 1)
		Menu.apply(window, { kind = "click", window = 1, slot = OUTPUT - 1, clickType = 0, button = 0 }, false)
		t.eq(container.slots[OUTPUT], nil, "a click can't put anything into the output")
		-- Results come out by hand and by shift-click.
		inventory.cursor = nil
		container.slots[OUTPUT] = S(I.IronIngot, 5)
		Menu.apply(window, { kind = "click", window = 1, slot = OUTPUT - 1, clickType = 1, button = 0 }, false)
		t.eq(container.slots[OUTPUT], nil)
		local ingots = 0
		for _, stack in inventory.slots do
			if stack and stack.item == I.IronIngot then
				ingots += stack.count
			end
		end
		t.eq(ingots, 5, "shift-clicked into the inventory")
	end)

	t.test("electric furnace: transporters fill it from above and the sides, empty it below", function()
		t.eq(#Machines.insertSlots(FURNACE, DOWN), 0, "nothing goes in through the bottom")
		t.eq(table.concat(Machines.extractSlots(FURNACE, DOWN), ","), "2", "results come out of the bottom")
		for face = 1, 5 do
			t.eq(table.concat(Machines.insertSlots(FURNACE, face), ","), "1", `face {face} takes what smelts`)
			t.eq(#Machines.extractSlots(FURNACE, face), 0, `face {face} gives nothing`)
		end
		-- Through Shared/Transmitters, as the server's transporters use it.
		local after, left = Transmitters.insert(FURNACE, UP, {}, S(I.RawIron, 70))
		t.eq(after[INPUT].count, 64)
		t.eq(after[OUTPUT], nil)
		t.eq(left and left.count, 6)
		local _, refused = Transmitters.insert(FURNACE, DOWN, {}, S(I.RawIron, 5))
		t.eq(refused and refused.count, 5, "the bottom takes nothing")
		t.eq(Transmitters.room(FURNACE, 4, {}, S(I.Cobblestone, 3)), 3, "a side takes cobblestone")
		t.eq(Transmitters.room(FURNACE, 4, {}, S(I.Diamond, 3)), 0, "only what smelts")
		local slots = { [INPUT] = S(I.RawIron, 9), [OUTPUT] = S(I.IronIngot, 4) }
		t.eq(#Transmitters.available(FURNACE, UP, slots), 0, "the top gives nothing")
		local below = Transmitters.available(FURNACE, DOWN, slots)
		t.eq(#below, 1)
		t.eq(below[1].item, I.IronIngot, "only the results come out")
		local rest, taken = Transmitters.extract(FURNACE, DOWN, slots, 64)
		t.eq(taken and taken.count, 4)
		t.eq(rest[OUTPUT], nil)
		t.eq(rest[INPUT].count, 9, "the input stays")
		t.ok(not Transmitters.canExtract(FURNACE, DOWN, INPUT, I.RawIron))
		t.ok(Transmitters.canInsert(FURNACE, 2, INPUT, I.Sand))
	end)

	--[[ Smelting ]]

	t.test("electric furnace: 200 ticks at 50 J a tick smelt an item, 10 kJ each", function()
		local container = furnace(CAPACITY, S(I.RawIron, 3))
		for i = 1, TICKS - 1 do
			tick(container)
			t.eq(field(container, "progress"), i)
			t.eq(field(container, "rate"), -USE, `tick {i}: 50 J`)
			t.eq(field(container, "active"), 1)
		end
		t.eq(container.slots[OUTPUT], nil, "not yet")
		t.eq(Machines.energy(container), CAPACITY - (TICKS - 1) * USE)
		t.eq(status(container), "Using 50 J/t")
		tick(container)
		t.eq(container.slots[OUTPUT] and container.slots[OUTPUT].item, I.IronIngot, "the 200th tick smelts it")
		t.eq(container.slots[OUTPUT].count, 1)
		t.eq(container.slots[OUTPUT].data, nil)
		t.eq(container.slots[INPUT].count, 2)
		t.eq(field(container, "progress"), 0)
		t.eq(Machines.energy(container), CAPACITY - TICKS * USE, "10 kJ an item")
		-- The next starts at once: no tick without work between items.
		container.data[ENERGY] = CAPACITY
		tick(container)
		t.eq(field(container, "progress"), 1)
		t.eq(field(container, "active"), 1)
		tick(container, 2 * TICKS - 1)
		t.eq(container.slots[OUTPUT].count, 3)
		t.eq(container.slots[INPUT], nil, "all smelted")
		t.eq(Machines.energy(container), CAPACITY - 2 * TICKS * USE)
		tick(container)
		t.eq(field(container, "rate"), 0)
		t.eq(field(container, "active"), 0)
		t.eq(field(container, "progress"), 0)
		t.eq(Machines.energy(container), CAPACITY - 2 * TICKS * USE, "idle: nothing used")
		t.eq(status(container), "Idle")
		-- Other recipes: Smelting.result, as the furnace's.
		for _, case in { { I.Sand, I.Glass }, { I.Cobblestone, I.Stone }, { I.BirchLog, I.Charcoal } } do
			local c = furnace(CAPACITY, S(case[1], 1))
			tick(c, TICKS)
			t.eq(c.slots[OUTPUT] and c.slots[OUTPUT].item, case[2], `{Items.displayName(case[1])}`)
			t.eq(c.slots[INPUT], nil)
		end
		-- A worn iron tool melts into a nugget; nothing is left of it.
		local tool = furnace(CAPACITY, { item = I.IronPickaxe, count = 1, damage = 40 })
		tick(tool, TICKS)
		t.eq(tool.slots[OUTPUT] and tool.slots[OUTPUT].item, I.IronNugget)
		t.eq(tool.slots[OUTPUT].damage, nil)
		t.eq(tool.slots[INPUT], nil)
	end)

	t.test("electric furnace: without power the progress waits, and goes on when energy comes", function()
		local container = furnace(2 * USE + 20, S(I.RawIron, 2))
		tick(container, 2)
		t.eq(field(container, "progress"), 2)
		t.eq(Machines.energy(container), 20)
		tick(container, 30)
		t.eq(field(container, "progress"), 2, "20 J is less than a tick's work: it waits")
		t.eq(Machines.energy(container), 20, "and uses nothing")
		t.eq(field(container, "rate"), 0)
		t.eq(field(container, "active"), 0)
		t.eq(status(container), "No power")
		t.eq(Machines.view(container).state, 1)
		container.data[ENERGY] = 20 + USE
		tick(container)
		t.eq(field(container, "progress"), 3, "on from where it stopped")
		t.eq(Machines.energy(container), 20)
		t.eq(status(container), "Using 50 J/t")
		-- An empty furnace is idle, powered or not.
		local empty = furnace(0, nil)
		tick(empty)
		t.eq(status(empty), "Idle")
		t.eq(Machines.view(empty).state, 0)
		-- Taking the input out starts over.
		container.slots[INPUT] = nil
		tick(container)
		t.eq(field(container, "progress"), 0)
		t.eq(status(container), "Idle")
		t.eq(Machines.energy(container), 20)
	end)

	t.test("electric furnace: on too little power it glows steadily (Mekanism's deactivation delay)", function()
		-- 25 J/t: a tick's 50 J every other tick, so it works every other tick.
		local container = furnace(0, S(I.RawIron, 64))
		local function feed(n: number, every: number)
			for i = 1, n do
				if i % every == 1 or every == 1 then
					container.data[ENERGY] += USE
				end
				tick(container)
			end
		end
		feed(1, 2)
		t.eq(field(container, "active"), 1, "on as soon as it works")
		tick(container)
		t.eq(field(container, "rate"), 0)
		t.eq(field(container, "active"), 0, "the first stop shows at once")
		t.eq(field(container, "activeDelay"), 60, "and starts the delay")
		local dark = 0
		for _ = 1, 200 do
			feed(1, 1)
			dark += if field(container, "active") == 0 then 1 else 0
			t.eq(field(container, "rate"), -USE)
			tick(container)
			dark += if field(container, "active") == 0 then 1 else 0
			t.eq(field(container, "rate"), 0, "it does stop")
			t.eq(status(container), "No power", "its status says so at once")
		end
		t.eq(dark, 0, "but the block keeps glowing through the short stops")
		-- (201 ticks of work: an item and one tick of the next.)
		t.eq(container.slots[OUTPUT] and container.slots[OUTPUT].count, 1, "a tick of work every other tick")
		t.eq(field(container, "progress"), 1)
		-- For good: it goes dark DEACTIVATION_DELAY ticks after its last stop.
		for i = 1, 59 do
			tick(container)
			t.eq(field(container, "active"), 1, `tick {i} of the delay`)
		end
		tick(container)
		t.eq(field(container, "active"), 0, "dark after 60 ticks without work")
		t.eq(field(container, "activeDelay"), 0)
		t.eq(Machines.view(container).active, false)
		-- Rested, the next stop shows at once again.
		feed(1, 1)
		t.eq(field(container, "active"), 1)
		tick(container)
		t.eq(field(container, "active"), 0)
		-- A delay from elsewhere is at most 60 ticks.
		Machines.set(container, "activeDelay", 1e9)
		tick(container)
		t.ok(field(container, "activeDelay") < 60)
		Machines.set(container, "activeDelay", -5.5)
		tick(container)
		t.eq(field(container, "activeDelay"), 0)
	end)

	t.test("electric furnace: a full output pauses it; another item starts over", function()
		local full = furnace(CAPACITY, S(I.RawIron, 4))
		full.slots[OUTPUT] = S(I.IronIngot, 64)
		tick(full, 10)
		t.eq(field(full, "progress"), 0)
		t.eq(Machines.energy(full), CAPACITY, "no energy used while it can't smelt")
		t.eq(status(full), "Output full")
		t.eq(field(full, "active"), 0)
		-- Room for one more: it finishes into it.
		full.slots[OUTPUT] = S(I.IronIngot, 63)
		tick(full, TICKS)
		t.eq(full.slots[OUTPUT].count, 64)
		t.eq(full.slots[INPUT].count, 3)
		tick(full)
		t.eq(status(full), "Output full")
		-- Something else in the output: it waits too, keeping its progress.
		local other = furnace(CAPACITY, S(I.RawIron, 1))
		tick(other, 50)
		other.slots[OUTPUT] = S(I.GoldIngot, 1)
		tick(other, 5)
		t.eq(field(other, "progress"), 50, "paused, not reset")
		t.eq(status(other), "Output full")
		other.slots[OUTPUT] = { item = I.IronIngot, count = 1, data = { note = "x" } }
		tick(other)
		t.eq(status(other), "Output full", "ingots with other data don't stack")
		other.slots[OUTPUT] = nil
		tick(other, TICKS - 50)
		t.eq(other.slots[OUTPUT] and other.slots[OUTPUT].item, I.IronIngot, "it goes on from 50")
		-- Another item in the input starts over.
		local swap = furnace(CAPACITY, S(I.RawIron, 1))
		tick(swap, 120)
		swap.slots[INPUT] = S(I.RawGold, 1)
		tick(swap)
		t.eq(field(swap, "progress"), 1, "raw gold starts at the beginning")
		t.eq(field(swap, "smelting"), I.RawGold)
		tick(swap, TICKS - 1)
		t.eq(swap.slots[OUTPUT] and swap.slots[OUTPUT].item, I.GoldIngot)
		-- More of the same item keeps its progress (input data and wear stay on what is left).
		local more = furnace(CAPACITY, { item = I.RawIron, count = 1, data = { tag = 1 } })
		tick(more, 100)
		more.slots[INPUT] = { item = I.RawIron, count = 2, data = { tag = 1 } }
		tick(more)
		t.eq(field(more, "progress"), 101)
		tick(more, TICKS - 101)
		t.eq(more.slots[INPUT].count, 1)
		t.eq(more.slots[INPUT].data and more.slots[INPUT].data.tag, 1, "what is left keeps its data")
		t.eq(more.slots[OUTPUT].data, nil, "the result carries none")
	end)

	t.test("electric furnace: progress and numbers from elsewhere are kept sane", function()
		local forged = furnace(CAPACITY, S(I.RawIron, 2))
		Machines.set(forged, "smelting", I.RawIron)
		Machines.set(forged, "progress", 1e12)
		tick(forged)
		t.eq(forged.slots[OUTPUT] and forged.slots[OUTPUT].count, 1, "a full arrow finishes on the next tick")
		t.eq(field(forged, "progress"), 0)
		local negative = furnace(CAPACITY, S(I.RawIron, 1))
		Machines.set(negative, "smelting", I.RawIron)
		Machines.set(negative, "progress", -40.5)
		tick(negative)
		t.eq(field(negative, "progress"), 1)
		-- Its numbers are its own every tick, whatever the data said.
		Machines.set(negative, "ticksRequired", 1)
		Machines.set(negative, "energyPerTick", 0)
		Machines.set(negative, "capacity", 1e9)
		negative.data[ENERGY] = CAPACITY
		tick(negative)
		t.eq(field(negative, "ticksRequired"), TICKS)
		t.eq(field(negative, "energyPerTick"), USE)
		t.eq(Machines.capacity(negative), CAPACITY)
		t.eq(Machines.energy(negative), CAPACITY - USE)
		-- A state code is a small whole number.
		Machines.set(negative, "state", 7.5)
		t.eq(Machines.view(negative).state, 0)
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
		function self.record(x: number, y: number, z: number): any
			local machine = MachineWorld.machine(world, x, y, z)
			assert(machine, "no machine")
			return MachineWorld.record(machine)
		end
		self.world = world
		self.cables = cables
		return self
	end

	t.test("electric furnace: a Heat Generator runs it through a cable; the records tell WAILA", function()
		local s = sim()
		s.set(0, Y, 0, B.HeatGenerator)
		s.set(1, Y, 0, B.BasicUniversalCable)
		s.set(2, Y, 0, FURNACE)
		local generator, smelter = s.container(0, Y, 0), s.container(2, Y, 0)
		smelter.slots[INPUT] = S(I.RawOsmium, 2)
		s.step(5)
		t.eq(Machines.view(smelter).state, 1, "no fuel: no power")
		local record = s.record(2, Y, 0)
		t.eq(record.state, 1)
		t.eq(record.active, false)
		t.eq(record.energy, 0, "only its state tells it from a fresh one")
		local function has(records: { any }): boolean
			for _, r in records do
				if r.x == 2 and r.y == Y and r.z == 0 and r.state == 1 then
					return true
				end
			end
			return false
		end
		t.ok(has(MachineWorld.takeRecords(s.world)), "a changed state is sent")
		t.ok(has(MachineWorld.chunkRecords(s.world, 0, 0)), "and with its chunk: not the default")
		-- Over the wire and into WAILA's lines.
		local sent = (Protocol.decodeMachines(Protocol.encodeMachines({ record })) :: any)[1]
		t.eq(sent.state, 1, "the state code travels")
		local facts = {
			energy = sent.energy,
			capacity = sent.capacity,
			input = sent.input,
			output = sent.output,
			rate = sent.rate,
			active = sent.active,
			state = sent.state,
		}
		t.eq(WailaInfo.text(WailaInfo.machineLines(FURNACE, facts)[2]), "No power")
		-- A coal: 200 J/t made, of which the furnace takes what it has room for and uses 50 J/t.
		generator.slots[1] = S(I.Coal, 1)
		local made, used = 0, 0
		for _ = 1, 2 * TICKS + 6 do
			s.step()
			made += Machines.get(generator, "rate")
			used -= Machines.get(smelter, "rate")
		end
		t.eq(smelter.slots[OUTPUT] and smelter.slots[OUTPUT].item, I.OsmiumIngot)
		t.eq(smelter.slots[OUTPUT].count, 2, "both smelted")
		t.eq(smelter.slots[INPUT], nil)
		t.eq(used, 2 * TICKS * USE, "10 kJ an item")
		-- No energy made or lost: what the coal gave is in the two machines or was used.
		t.eq(Machines.energy(generator) + Machines.energy(smelter) + used, made, "made = stored + used")
		-- Sand with osmium in the output: no room for glass.
		smelter.slots[INPUT] = S(I.Sand, 1)
		s.step()
		t.eq(s.record(2, Y, 0).state, 2, "output full")
		-- While it smelts the record says so (WAILA, the glow).
		smelter.slots[OUTPUT] = nil
		s.step()
		record = s.record(2, Y, 0)
		t.eq(record.active, true)
		t.eq(record.rate, -USE)
		t.eq(record.state, 0)
	end)

	t.test("electric furnace: five on one Heat Generator share its 200 J/t and glow steadily", function()
		local s = sim()
		s.set(0, Y, 0, B.HeatGenerator)
		local furnaces = {}
		for x = 1, 5 do
			s.set(x, Y, 0, B.BasicUniversalCable)
			s.set(x, Y + 1, 0, FURNACE)
			local container = s.container(x, Y + 1, 0)
			container.slots[INPUT] = S(I.Cobblestone, 64)
			table.insert(furnaces, container)
		end
		local generator = s.container(0, Y, 0)
		generator.slots[1] = S(I.Coal, 1)
		local made, used, dark = 0, 0, 0
		for i = 1, 1000 do
			s.step()
			made += Machines.get(generator, "rate")
			for _, container in furnaces do
				used -= Machines.get(container, "rate")
			end
			for _, record in MachineWorld.takeRecords(s.world) do
				if record.y == Y + 1 and not record.active and i > 20 then
					dark += 1
				end
			end
		end
		-- 250 J/t wanted, 200 J/t made: each works 4 ticks in 5.
		t.eq(made, 1000 * 200)
		local stored = Machines.energy(generator)
		for _, container in furnaces do
			stored += Machines.energy(container)
		end
		t.eq(made, stored + used, "made = stored + used")
		t.ok(used >= 1000 * 200 - 5 * USE, "all of it used, but for what each is holding")
		t.eq(dark, 0, "no furnace's record blinked off")
	end)

	t.test("electric furnace: transporters feed it from a chest and take its results to another", function()
		local s = sim()
		local M = Transmitters.MODES
		local WEST = 4
		-- A chest -> two transporters -> the furnace's west side; the creative cube on top powers it.
		s.set(0, Y, 0, B.Chest)
		s.set(1, Y, 0, B.AdvancedLogisticalTransporter)
		s.set(2, Y, 0, B.AdvancedLogisticalTransporter)
		s.set(3, Y, 0, FURNACE)
		s.set(3, Y + 1, 0, B.CreativeEnergyCube)
		-- Under it a transporter pulls from its bottom into a second chest.
		s.set(3, Y - 1, 0, B.AdvancedLogisticalTransporter)
		s.set(4, Y - 1, 0, B.AdvancedLogisticalTransporter)
		s.set(5, Y - 1, 0, B.Chest)
		t.ok(TransmitterWorld.setMode(s.cables, 1, Y, 0, WEST, M.PULL))
		t.ok(TransmitterWorld.setMode(s.cables, 3, Y - 1, 0, UP, M.PULL))
		local function chest(x: number, y: number): { [number]: any }
			local container = s.cables.env.containers:get(x, y, 0, B.Chest)
			return container.slots
		end
		local function count(slots: { [number]: any }, item: number): number
			local total = 0
			for _, stack in slots do
				if stack and stack.item == item then
					total += stack.count
				end
			end
			return total
		end
		local source = chest(0, Y)
		source[1] = S(I.RawIron, 3)
		source[2] = S(I.Coal, 4)
		source[3] = S(I.Cobblestone, 2)
		local smelter = s.container(3, Y, 0)
		s.step(100)
		t.eq(smelter.slots[INPUT] and smelter.slots[INPUT].item, I.RawIron, "ore into the input through a side")
		t.eq(count(source, I.Cobblestone), 2, "one input slot: the cobblestone waits")
		t.eq(count(source, I.Coal), 4, "coal doesn't smelt: it stays")
		-- 3 raw iron, then the 2 cobblestone, 200 ticks each, and the trips.
		s.step(6 * TICKS)
		local results = chest(5, Y - 1)
		t.eq(count(results, I.IronIngot), 3, "the ingots came out of the bottom")
		t.eq(count(results, I.Stone), 2, "then the stone")
		t.eq(smelter.slots[INPUT], nil)
		t.eq(smelter.slots[OUTPUT], nil)
		t.eq(count(source, I.Coal), 4)
		t.eq(s.cables.itemCount, 0, "nothing left on the way")
	end)

	t.test("electric furnace: Mekanism's machines fill in a tick (the creative cube, touching)", function()
		local s = sim()
		s.set(0, Y, 0, B.CreativeEnergyCube)
		s.set(0, Y + 1, 0, FURNACE)
		local smelter = s.container(0, Y + 1, 0)
		s.step()
		t.eq(Machines.energy(smelter), CAPACITY, "its whole storage in one tick")
		t.eq(smelter.data[Machines.INPUT], CAPACITY)
		smelter.slots[INPUT] = S(I.Cobblestone, 1)
		s.step()
		t.eq(Machines.energy(smelter), CAPACITY, "what it used is put back at once")
		t.eq(smelter.data[Machines.INPUT], USE)
		t.eq(Machines.get(smelter, "progress"), 1)
	end)

	t.test("electric furnace: keeps its energy in its item, not its progress", function()
		local s = sim()
		local registry = EditRules.newBlockData()
		registry:add(TransmitterWorld.blockDataHooks(s.cables))
		registry:add(MachineWorld.blockDataHooks(s.world))
		s.set(0, Y, 0, FURNACE)
		local container = s.container(0, Y, 0)
		container.data[ENERGY] = 12345
		container.slots[INPUT] = S(I.RawIron, 3)
		s.step(10)
		t.eq(Machines.get(container, "progress"), 10)
		local drop = EditRules.breakDrop(registry, 0, Y, 0, FURNACE, false, I.IronPickaxe) :: any
		s.set(0, Y, 0, AIR)
		t.eq(drop.item, FURNACE)
		t.eq(drop.data.energy, 12345 - 10 * USE)
		t.eq(drop.data.progress, nil, "its slots drop, so its progress goes")
		t.eq(Items.describe(drop)[1], "Energy: 11.84 kJ")
		s.set(3, Y, 0, FURNACE)
		registry:placed("p", 3, Y, 0, FURNACE, drop)
		local placed = s.container(3, Y, 0)
		t.eq(Machines.energy(placed), 12345 - 10 * USE)
		t.eq(Machines.get(placed, "progress"), 0)
		-- More than it holds is cut to its capacity.
		s.set(5, Y, 0, FURNACE)
		registry:placed("p", 5, Y, 0, FURNACE, { item = FURNACE, count = 1, data = { energy = 1e7 } })
		t.eq(Machines.energy(s.container(5, Y, 0)), CAPACITY)
	end)

	--[[ What players see ]]

	t.test("electric furnace: its panel, status line and WAILA lines", function()
		local container: any = furnace(CAPACITY, S(I.RawIron, 1))
		local panel = MenuLayout.panel(container)
		t.eq(panel.title, "Electric Furnace")
		t.eq(#panel.slots, 2)
		t.eq(panel.slots[1].x, 56)
		t.eq(panel.slots[1].y, 35)
		t.eq(panel.slots[2].x, 116)
		t.eq(panel.slots[2].y, 35)
		local progress = panel.progress :: any
		t.eq(progress.x, 79, "the furnace's arrow between them")
		t.eq(progress.y, 34)
		t.eq(panel.flame, nil, "no fuel, no flame")
		local energy = panel.energy :: any
		t.eq(energy.x, 164, "Mekanism's power bar")
		local line = panel.status :: any
		t.eq(line.x, 8)
		t.eq(line.y, 20)
		t.ok(line.y + 8 <= progress.y and line.y + 8 <= 31, "the status line clears the row")
		-- The lower left stays free for the upgrade slots (8, 53) and (26, 53).
		for _, slot in panel.slots do
			t.ok(slot.x >= 44 or slot.y + 17 < 52, "nothing where the upgrades will go")
		end
		-- The arrow fills over the 200 ticks.
		t.eq(MenuLayout.machineArrowColumns(container.data, panel.progressSource), 0)
		tick(container, 100)
		t.eq(MenuLayout.machineArrowColumns(container.data, panel.progressSource), 12, "half way")
		tick(container, 99)
		t.eq(MenuLayout.machineArrowColumns(container.data, panel.progressSource), 23)
		t.eq(MenuLayout.statusText(container), "Using 50 J/t")
		container.data[ENERGY] = 0
		tick(container)
		t.eq(MenuLayout.statusText(container), "No power")
		-- WAILA: energy and the status, from the record.
		local facts = WailaInfo.machineDefaults(FURNACE)
		t.eq(facts.state, 0)
		local lines = WailaInfo.machineLines(FURNACE, facts)
		t.eq(WailaInfo.text(lines[1]), "Energy: 0 J / 20 kJ")
		t.eq(WailaInfo.text(lines[2]), "Idle")
		facts.energy, facts.rate, facts.active, facts.input = 19950, -USE, true, USE
		t.eq(WailaInfo.text(WailaInfo.machineLines(FURNACE, facts)[2]), "Using 50 J/t")
		facts.rate, facts.active, facts.state = 0, false, 1
		t.eq(WailaInfo.text(WailaInfo.machineLines(FURNACE, facts)[2]), "No power")
		facts.state = 2
		t.eq(WailaInfo.text(WailaInfo.machineLines(FURNACE, facts)[2]), "Output full")
		local details = WailaInfo.machineDetails(FURNACE, facts)
		t.eq(WailaInfo.text(details[1]), "Machine smelter (consumer)")
		t.eq(WailaInfo.text(details[2]), "Holds 20 kJ, in 20 kJ/t, out none")
	end)

	t.test("electric furnace: decor with a heating chamber that glows while it smelts", function()
		local faces = BlockDecor.faces("ElectricFurnace") :: any
		t.ok(faces ~= nil)
		local window = BlockDecor.ELECTRIC_FURNACE_WINDOW
		for _, face in { "Front", "Back", "Left", "Right" } do
			local found = false
			for _, r in faces[face] do
				if r.x == window.x and r.y == window.y and r.w == window.w and r.h == window.h then
					found = true
				end
			end
			t.ok(found, `{face}: the chamber window`)
		end
		local parts = BlockDecor.partCount("ElectricFurnace")
		t.ok(parts > 0 and parts < 40, `item model slabs: {parts}`)
		t.ok(TransmitterModel.hasMachineBoxes(FURNACE))
		local none = TransmitterModel.machineBoxes(FURNACE, nil)
		t.eq(#none, 0, "no record: off")
		local idle = TransmitterModel.machineBoxes(FURNACE, { active = false, energy = 5, capacity = 9 })
		t.eq(#idle, 0)
		local boxes, lit = TransmitterModel.machineBoxes(FURNACE, { active = true, energy = 0, capacity = 9 })
		t.eq(#boxes, 4, "a pane on each side")
		local _, generatorLit =
			TransmitterModel.machineBoxes(B.HeatGenerator, { active = true, energy = 0, capacity = 9 })
		t.ok(lit ~= generatorLit, "its own signature")
		local depth = TransmitterModel.GLOW_DEPTH
		for _, box in boxes do
			t.eq(box.kind, "glow")
			t.eq(box.size[2], window.h)
			t.eq(box.offset[2], 8 - (window.y + window.h / 2), "over the chamber")
			local normalAxis = if box.size[1] == depth then 1 else 3
			t.eq(box.size[4 - normalAxis], window.w)
			t.eq(math.abs(box.offset[normalAxis]), 8 + depth / 2, "out of the face")
		end
	end)

	t.test("electric furnace: JEI lists it as a smelting catalyst", function()
		t.ok(table.find(JeiData.CATALYSTS.smelting, "ElectricFurnace") ~= nil)
		local smelting = #Smelting.recipes()
		local uses = JeiData.uses(FURNACE)
		t.eq(#uses, 1)
		t.eq(uses[1].category, "smelting")
		t.eq(#uses[1].entries, smelting, "every smelting recipe")
		t.ok(JeiData.has("uses", FURNACE))
		local recipes = JeiData.recipes(FURNACE)
		t.eq(recipes[1] and recipes[1].category, "crafting", "its own recipe")
		-- The furnace goes into it.
		local found = false
		for _, group in JeiData.uses(I.Furnace) do
			for _, entry in group.entries do
				if group.category == "crafting" and entry.output and entry.output.item == FURNACE then
					found = true
				end
			end
		end
		t.ok(found, "furnace: into an Electric Furnace")
	end)
end

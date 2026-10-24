--[[
	The Ammo Press (Shared/Machines/Kinds/AmmoPress, kind "press", BlockList AmmoPress,
	Config.AmmoPress): the block and its numbers, the slots (hand, shift-click, transporters
	through any face, never the cards), an operation of each calibre (an Iron Ingot and a
	Gunpowder into 16 9mm, 10 5.56 or 5 .308 rounds in 200 ticks at 50 J a tick), Mekanism's
	upgrade maths at every card count, the Calibre button and its choice kept in the item, a
	missing input, a full output and no power, data from elsewhere, the real server worlds
	(transporters feeding it, its rounds pushed into a chest, the records WAILA reads, the item
	keeping its energy and calibre), switched off, and the panel, its line and WAILA's lines.
]]

return function(t, shared, require, server, client)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local Coords = require(shared.World.Coords)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local Menu = require(shared.Inventory.Menu)
	local Protocol = require(shared.Net.Protocol)
	local Transmitters = require(shared.Transmitters)
	local Types = require(shared.Inventory.Types)
	local Upgrades = require(shared.Machines.Upgrades)
	local Containers = require(server.Players.Containers)
	local EditRules = require(server.Network.EditRules)
	local MachineWorld = require(server.Machines.MachineWorld)
	local TransmitterWorld = require(server.Transmitters.TransmitterWorld)
	local MenuLayout = require(client.Ui.MenuLayout)
	local WailaInfo = require(client.Ui.WailaInfo)

	local B = Blocks.id
	local I = Items.id
	local AIR = B.Air
	local Y = 64
	local PRESS = B.AmmoPress
	local ENERGY = Machines.ENERGY
	-- An operation: ticks, J a tick, the store.
	local TICKS, USE, CAPACITY = 200, 50, 20000
	-- Slots and states.
	local INGOT, GUNPOWDER, OUTPUT, SPEED, CARDS = 1, 2, 3, 4, 5
	local IDLE, NO_POWER, OUTPUT_FULL, NO_INPUT = 0, 1, 2, 3
	local UP = 1
	-- Each calibre: its round, the rounds an operation makes, the panel's line.
	local CALIBRES = {
		{ round = I.Rounds9mm, count = 16, line = "16 9mm Rounds" },
		{ round = I.Rounds556, count = 10, line = "10 5.56 Rounds" },
		{ round = I.Rounds308, count = 5, line = "5 .308 Rounds" },
	}

	local function S(item: number, count: number)
		return { item = item, count = count }
	end

	local function ctx(): any
		return {
			block = PRESS,
			x = 0,
			y = Y,
			z = 0,
			energy = Machines.energyOf(PRESS),
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
		return Machines.status(PRESS, Machines.view(container))
	end

	-- A fresh press holding `energy` J, `ingots` Iron Ingots and `powder` Gunpowder, pressing
	-- calibre `calibre` (1 when nil).
	local function press(energy: number, ingots: number, powder: number, calibre: number?): any
		local container: any = Machines.newContainer(PRESS)
		container.data[ENERGY] = energy
		container.slots[INGOT] = if ingots > 0 then S(I.IronIngot, ingots) else nil
		container.slots[GUNPOWDER] = if powder > 0 then S(I.Gunpowder, powder) else nil
		Machines.set(container, "calibre", calibre or 1)
		return container
	end

	-- Runs `container` with its store refilled before every tick until an operation finishes (at
	-- most `limit` ticks): the ticks it took and the J it used.
	local function operation(container: any, limit: number): (number, number)
		local used = 0
		for i = 1, limit do
			container.data[ENERGY] = Machines.quantise(Machines.capacity(container))
			local before = Machines.energy(container)
			tick(container)
			used += before - Machines.energy(container)
			if container.slots[OUTPUT] then
				return i, used
			end
		end
		return math.huge, used
	end

	--[[ The block ]]

	t.test("ammo press: the block, its kind, Config's numbers and its info", function()
		local def = Blocks.get(PRESS)
		t.eq(Items.displayName(PRESS), "Ammo Press")
		t.eq(def.menu, "Machine", "right click opens its panel")
		t.eq(def.decor, "AmmoPress")
		t.ok(Machines.isMachine(PRESS))
		t.eq((Machines.kindOf(PRESS) :: any).name, "press")
		t.eq(Machines.role(PRESS), "consumer", "input only")
		local energy = Machines.energyOf(PRESS) :: any
		t.eq(energy.capacity, CAPACITY)
		t.eq(energy.input, CAPACITY, "up to its store a tick")
		t.eq(Machines.containerSize(PRESS), 5, "ingot, gunpowder, output and the two cards")
		t.ok(Transmitters.isItemAcceptor(PRESS) and Transmitters.isEnergyAcceptor(PRESS))
		-- Config's numbers (the design's), and `info` (JEI's Pressing reads it).
		local settings = Config.AmmoPress
		t.ok(settings.Enabled, "on by default")
		t.eq(settings.Ticks, TICKS)
		t.eq(settings.Joules, USE)
		t.eq(settings.Capacity, CAPACITY)
		t.eq(#settings.Calibres, #CALIBRES)
		local info = Machines.info(PRESS)
		t.eq(info.ticks, TICKS)
		t.eq(info.joules, USE)
		t.eq(info.capacity, CAPACITY)
		for index, calibre in CALIBRES do
			local name = (Items.get(calibre.round) :: any).name
			t.eq(settings.Calibres[index].ammo, name, `calibre {index}'s round`)
			t.eq(info[name], calibre.count, `{name}: {calibre.count} an operation`)
		end
		-- A fresh one: empty and idle; its first tick sets its numbers and uses nothing.
		local container = Machines.newContainer(PRESS)
		container.data[ENERGY] = 1000
		tick(container)
		t.eq(field(container, "ticksRequired"), TICKS)
		t.eq(field(container, "energyPerTick"), USE)
		t.eq(Machines.capacity(container), CAPACITY)
		t.eq(field(container, "calibre"), 1, "9mm")
		t.eq(Machines.state(container), IDLE)
		t.eq(status(container), "Idle")
		t.eq(Machines.energy(container), 1000, "nothing used")
		local input, output = Machines.rates(container)
		t.eq(input, CAPACITY, "Mekanism's machines take any amount: up to their capacity")
		t.eq(output, 0)
	end)

	--[[ Slots ]]

	t.test("ammo press: iron ingots and gunpowder in, rounds out; the cards by hand only", function()
		t.ok(Machines.mayPlace(PRESS, INGOT, I.IronIngot))
		t.ok(Machines.mayPlace(PRESS, GUNPOWDER, I.Gunpowder))
		for _, item in { I.GoldIngot, I.RawIron, I.Coal, I.Rounds9mm, I.Gunpowder } do
			t.ok(not Machines.mayPlace(PRESS, INGOT, item), `no {Items.displayName(item)} for the ingot`)
		end
		for _, item in { I.IronIngot, I.Coal, I.Flint, I.Rounds556 } do
			t.ok(not Machines.mayPlace(PRESS, GUNPOWDER, item), `no {Items.displayName(item)} for the powder`)
		end
		t.ok(Machines.isOutput(PRESS, OUTPUT))
		t.ok(not Machines.mayPlace(PRESS, OUTPUT, I.Rounds9mm), "nothing goes into the output")
		t.eq(table.concat(Machines.quickMoveTargets(PRESS, I.IronIngot), ","), "1")
		t.eq(table.concat(Machines.quickMoveTargets(PRESS, I.Gunpowder), ","), "2")
		t.eq(table.concat(Machines.quickMoveTargets(PRESS, I.SpeedUpgrade), ","), "4")
		t.eq(table.concat(Machines.quickMoveTargets(PRESS, I.EnergyUpgrade), ","), "5")
		t.eq(#Machines.quickMoveTargets(PRESS, I.Rounds9mm), 0)
		t.eq(Machines.slotLimit(PRESS, SPEED, I.SpeedUpgrade), Upgrades.MAX)
		-- Shift-clicks through Inventory/Menu, as the client predicts and the server runs them.
		local container = Machines.newContainer(PRESS)
		local inventory = Types.newInventory()
		local window: any = { id = 1, inventory = inventory, container = container }
		local function slotOf(index: number): number
			return Menu.windowIndex(window, "inventory", index) :: number
		end
		inventory.slots[1] = S(I.IronIngot, 20)
		inventory.slots[2] = S(I.Gunpowder, 7)
		inventory.slots[3] = S(I.SpeedUpgrade, 3)
		for slot = 1, 3 do
			Menu.apply(window, { kind = "click", window = 1, slot = slotOf(slot), clickType = 1, button = 0 }, false)
		end
		t.eq(container.slots[INGOT] and container.slots[INGOT].count, 20, "the ingots")
		t.eq(container.slots[GUNPOWDER] and container.slots[GUNPOWDER].count, 7, "the gunpowder")
		t.eq(container.slots[SPEED] and container.slots[SPEED].count, 3, "the cards")
		-- Transporters: both inputs through every face, the rounds out through every face, never
		-- the cards.
		for face = 0, 5 do
			t.eq(table.concat(Machines.insertSlots(PRESS, face), ","), "1,2", `face {face} takes both inputs`)
			t.eq(table.concat(Machines.extractSlots(PRESS, face), ","), "3", `face {face} gives the rounds`)
			t.ok(not Transmitters.canInsert(PRESS, face, SPEED, I.SpeedUpgrade), "no cards in")
			t.ok(not Transmitters.canExtract(PRESS, face, INGOT, I.IronIngot), "the inputs stay")
		end
		t.eq(table.concat(Machines.outputSlots(PRESS), ","), "3", "it pushes its rounds out")
		t.ok(Transmitters.ejects(PRESS))
		local after = Transmitters.insert(PRESS, 4, {}, S(I.Gunpowder, 3))
		t.eq(after[GUNPOWDER] and after[GUNPOWDER].count, 3, "gunpowder through a side")
		t.eq(Transmitters.room(PRESS, UP, {}, S(I.Rounds9mm, 3)), 0, "no rounds in")
	end)

	--[[ Pressing ]]

	t.test("ammo press: an ingot and a gunpowder make each calibre's rounds, 200 ticks at 50 J a tick", function()
		for index, calibre in CALIBRES do
			local container = press(CAPACITY, 2, 2, index)
			for i = 1, TICKS - 1 do
				tick(container)
				t.eq(field(container, "progress"), i)
				t.eq(field(container, "rate"), -USE, `calibre {index}, tick {i}: 50 J`)
			end
			t.eq(container.slots[OUTPUT], nil, "not yet")
			t.eq(field(container, "active"), 1, "it works")
			t.eq(status(container), "Using 50 J/t")
			tick(container)
			local output = container.slots[OUTPUT]
			t.eq(output and output.item, calibre.round, `the 200th tick presses {calibre.line}`)
			t.eq(output and output.count, calibre.count)
			t.eq(output and output.data, nil, "no data on the rounds")
			t.eq(container.slots[INGOT].count, 1, "one ingot")
			t.eq(container.slots[GUNPOWDER].count, 1, "and one gunpowder an operation")
			t.eq(field(container, "progress"), 0)
			t.eq(Machines.energy(container), CAPACITY - TICKS * USE, "10 kJ an operation")
			-- The next starts at once, then it runs out of inputs.
			container.data[ENERGY] = CAPACITY
			tick(container, TICKS)
			t.eq(container.slots[OUTPUT].count, 2 * calibre.count, "a second operation")
			t.eq(container.slots[INGOT], nil, "all used")
			t.eq(container.slots[GUNPOWDER], nil)
			t.eq(Machines.energy(container), CAPACITY - TICKS * USE)
			tick(container)
			t.eq(field(container, "rate"), 0)
			t.eq(Machines.state(container), IDLE)
			t.eq(status(container), "Idle")
			t.eq(Machines.energy(container), CAPACITY - TICKS * USE, "idle: nothing used")
		end
		-- What is left of an input keeps its data.
		local tagged = press(CAPACITY, 0, 0)
		tagged.slots[INGOT] = { item = I.IronIngot, count = 3, data = { tag = 1 } }
		tagged.slots[GUNPOWDER] = S(I.Gunpowder, 3)
		tick(tagged, TICKS)
		t.eq(tagged.slots[INGOT].count, 2)
		t.eq(tagged.slots[INGOT].data and tagged.slots[INGOT].data.tag, 1, "the ingots keep their data")
	end)

	t.test("ammo press: Speed and Energy Upgrades follow Mekanism's maths at every card count", function()
		for speed = 0, Upgrades.MAX do
			for energy = 0, Upgrades.MAX do
				local container = press(0, 1, 1)
				container.slots[SPEED] = if speed > 0 then S(I.SpeedUpgrade, speed) else nil
				container.slots[CARDS] = if energy > 0 then S(I.EnergyUpgrade, energy) else nil
				local ticks = Upgrades.ticks(TICKS, speed)
				local perTick = Upgrades.energyPerTick(USE, speed, energy)
				local capacity = Upgrades.capacity(CAPACITY, energy)
				local took, used = operation(container, TICKS + 1)
				local what = `{speed} speed, {energy} energy`
				t.eq(field(container, "ticksRequired"), ticks, `{what}: ticks`)
				t.eq(field(container, "energyPerTick"), perTick, `{what}: J a tick`)
				t.eq(Machines.capacity(container), capacity, `{what}: capacity`)
				t.eq(took, ticks, `{what}: an operation in {ticks} ticks`)
				t.eq(used, ticks * Machines.quantiseUp(perTick), `{what}: J used`)
				t.eq(container.slots[OUTPUT] and container.slots[OUTPUT].count, 16)
			end
		end
		-- Mekanism's numbers, spelt out.
		t.eq(Upgrades.ticks(TICKS, 1), 149, "one card: 149 ticks")
		t.eq(Upgrades.ticks(TICKS, 8), 20, "8: a second")
		t.near(Upgrades.energyPerTick(USE, 8, 0), 5000, 1e-9, "8 speed: 5 kJ/t, 100 kJ an operation")
		t.near(Upgrades.energyPerTick(USE, 8, 8), 500, 1e-9, "8 and 8: 10 kJ an operation again")
		t.near(Upgrades.capacity(CAPACITY, 8), 200000, 1e-6, "8 energy cards: a 200 kJ store")
		-- Taking the cards out applies at once: energy over the smaller store is lost.
		local container = press(0, 1, 1)
		container.slots[CARDS] = S(I.EnergyUpgrade, 8)
		tick(container)
		container.data[ENERGY] = 150000
		container.slots[CARDS] = nil
		tick(container)
		t.eq(Machines.capacity(container), CAPACITY)
		t.eq(Machines.energy(container), CAPACITY - USE, "cut to 20 kJ, then a tick's work")
	end)

	--[[ The Calibre button ]]

	t.test("ammo press: the Calibre button cycles 9mm, 5.56, .308, kept in the item", function()
		local container = Machines.newContainer(PRESS)
		local buttons = Machines.buttons(PRESS)
		t.eq(#buttons, 1)
		t.eq(buttons[1].id, 0)
		t.eq(buttons[1].label, "Calibre")
		t.eq(field(container, "calibre"), 1, "9mm when fresh")
		t.eq(MenuLayout.lineTexts(container)[1], CALIBRES[1].line)
		t.eq(Machines.save(container), nil, "the first calibre is a fresh one's: nothing kept")
		for _, expected in { 2, 3, 1, 2 } do
			t.ok(Machines.button(container, PRESS, 0))
			t.eq(field(container, "calibre"), expected, `then calibre {expected}`)
			t.eq(MenuLayout.lineTexts(container)[1], CALIBRES[expected].line)
		end
		t.ok(not Machines.button(container, PRESS, 1), "no button 1")
		t.eq(field(container, "calibre"), 2)
		local kept = Machines.save(container) :: any
		t.eq(kept and kept.calibre, 2, "kept in the item")
		local placed = Machines.newContainer(PRESS)
		t.ok(Machines.restore(placed, kept))
		t.eq(field(placed, "calibre"), 2, "and back in the placed press")
		-- It presses what it is set to.
		placed.data[ENERGY] = CAPACITY
		placed.slots[INGOT] = S(I.IronIngot, 1)
		placed.slots[GUNPOWDER] = S(I.Gunpowder, 1)
		tick(placed, TICKS)
		t.eq(placed.slots[OUTPUT] and placed.slots[OUTPUT].item, I.Rounds556)
		-- Every calibre costs the same: switching keeps the progress, and what comes out is the
		-- calibre chosen when it finishes.
		local switched = press(CAPACITY, 1, 1)
		tick(switched, 120)
		Machines.button(switched, PRESS, 0)
		Machines.button(switched, PRESS, 0)
		tick(switched)
		t.eq(field(switched, "progress"), 121, "kept")
		tick(switched, TICKS - 121)
		t.eq(switched.slots[OUTPUT] and switched.slots[OUTPUT].item, I.Rounds308)
		t.eq(switched.slots[OUTPUT].count, 5)
		t.eq(Machines.energy(switched), CAPACITY - TICKS * USE, "one operation's energy")
		-- A calibre from elsewhere reads as the first, and the tick keeps it so.
		for _, bad in { 0, 4, 2.5, -1, 0 / 0, 1e9 } do
			local odd = press(CAPACITY, 1, 1)
			Machines.set(odd, "calibre", bad)
			t.eq(MenuLayout.lineTexts(odd)[1], CALIBRES[1].line, `calibre {bad}: 9mm`)
			tick(odd)
			t.eq(field(odd, "calibre"), 1)
		end
	end)

	--[[ Why it waits ]]

	t.test("ammo press: a missing input, a full output and no power", function()
		-- One input without the other: "No input", nothing used; empty: "Idle".
		for _, case in { { 4, 0 }, { 0, 4 } } do
			local container = press(CAPACITY, case[1], case[2])
			tick(container, 10)
			t.eq(Machines.state(container), NO_INPUT)
			t.eq(status(container), "No input")
			t.eq(field(container, "progress"), 0)
			t.eq(Machines.energy(container), CAPACITY, "nothing used")
			t.eq(field(container, "active"), 0)
		end
		local empty = press(CAPACITY, 0, 0)
		tick(empty)
		t.eq(Machines.state(empty), IDLE)
		t.eq(status(empty), "Idle")
		-- Taking an input away starts over.
		local taken = press(CAPACITY, 1, 1)
		tick(taken, 80)
		taken.slots[GUNPOWDER] = nil
		tick(taken)
		t.eq(field(taken, "progress"), 0, "the progress goes")
		t.eq(status(taken), "No input")
		taken.slots[GUNPOWDER] = S(I.Gunpowder, 1)
		tick(taken)
		t.eq(field(taken, "progress"), 1, "from the start")

		-- A full output: all of an operation's rounds must fit (9mm stack to 60, .308 to 40).
		t.eq(Items.maxStack(I.Rounds9mm), 60)
		t.eq(Items.maxStack(I.Rounds308), 40)
		local full = press(CAPACITY, 1, 1)
		tick(full, 50)
		full.slots[OUTPUT] = S(I.Rounds9mm, 45)
		tick(full, 10)
		t.eq(Machines.state(full), OUTPUT_FULL, "45 + 16 is more than a stack")
		t.eq(status(full), "Output full")
		t.eq(field(full, "progress"), 50, "paused, not reset")
		t.eq(Machines.energy(full), CAPACITY - 50 * USE, "no energy used while it can't press")
		t.eq(field(full, "rate"), 0)
		full.slots[OUTPUT] = S(I.Rounds9mm, 44)
		tick(full, TICKS - 50)
		t.eq(full.slots[OUTPUT].count, 60, "44 + 16 fits: a full stack")
		local other = press(CAPACITY, 1, 1)
		other.slots[OUTPUT] = S(I.Rounds556, 1)
		tick(other)
		t.eq(status(other), "Output full", "5.56 rounds in the output: no room for 9mm")
		Machines.button(other, PRESS, 0)
		tick(other)
		t.eq(field(other, "progress"), 1, "set to 5.56 it presses onto them")
		local marked = press(CAPACITY, 1, 1)
		marked.slots[OUTPUT] = { item = I.Rounds9mm, count = 1, data = { note = "x" } }
		tick(marked)
		t.eq(status(marked), "Output full", "rounds with other data don't stack")
		local sniper = press(CAPACITY, 2, 2, 3)
		sniper.slots[OUTPUT] = S(I.Rounds308, 35)
		tick(sniper, TICKS)
		t.eq(sniper.slots[OUTPUT].count, 40, "35 + 5 .308")
		tick(sniper)
		t.eq(status(sniper), "Output full")

		-- No power: the progress waits, and goes on when energy comes.
		local starved = press(2 * USE + 20, 1, 1)
		tick(starved, 2)
		t.eq(field(starved, "progress"), 2)
		tick(starved, 30)
		t.eq(field(starved, "progress"), 2, "20 J is less than a tick's work")
		t.eq(Machines.energy(starved), 20, "and it uses nothing")
		t.eq(Machines.state(starved), NO_POWER)
		t.eq(status(starved), "No power")
		t.eq(field(starved, "rate"), 0)
		starved.data[ENERGY] = 20 + USE
		tick(starved)
		t.eq(field(starved, "progress"), 3, "on from where it stopped")
		t.eq(status(starved), "Using 50 J/t")
		-- (A full output comes before power: an empty, full press says "Output full".)
		local both = press(0, 1, 1)
		both.slots[OUTPUT] = S(I.Rounds9mm, 60)
		tick(both)
		t.eq(status(both), "Output full")
	end)

	t.test("ammo press: progress, numbers and inputs from elsewhere are kept sane", function()
		local forged = press(CAPACITY, 1, 1)
		Machines.set(forged, "progress", 1e12)
		tick(forged)
		t.eq(forged.slots[OUTPUT] and forged.slots[OUTPUT].count, 16, "a full arrow finishes on the next tick")
		t.eq(field(forged, "progress"), 0)
		local negative = press(CAPACITY, 1, 1)
		Machines.set(negative, "progress", -40.5)
		tick(negative)
		t.eq(field(negative, "progress"), 1)
		Machines.set(negative, "ticksRequired", 1)
		Machines.set(negative, "energyPerTick", 0)
		Machines.set(negative, "capacity", 1e9)
		negative.data[ENERGY] = CAPACITY
		tick(negative)
		t.eq(field(negative, "ticksRequired"), TICKS, "its numbers are its own every tick")
		t.eq(field(negative, "energyPerTick"), USE)
		t.eq(Machines.capacity(negative), CAPACITY)
		t.eq(Machines.energy(negative), CAPACITY - USE)
		-- Anything else in an input slot (data from elsewhere) is no input.
		local wrong = press(CAPACITY, 0, 0)
		wrong.slots[INGOT] = S(I.GoldIngot, 5)
		wrong.slots[GUNPOWDER] = S(I.Gunpowder, 5)
		tick(wrong, TICKS)
		t.eq(wrong.slots[OUTPUT], nil, "gold presses nothing")
		t.eq(status(wrong), "No input")
		t.eq(Machines.energy(wrong), CAPACITY)
		Machines.set(wrong, "state", 7.5)
		t.eq(Machines.view(wrong).state, 0, "a state is a small whole number")
	end)

	--[[ Switched off ]]

	t.test("ammo press: switched off it is inert, and goes on where it was when on again", function()
		local container = press(CAPACITY, 3, 3)
		tick(container, 50)
		t.eq(field(container, "progress"), 50)
		Config.AmmoPress.Enabled = false
		local ok, err = pcall(function()
			tick(container, 2 * TICKS)
			t.eq(container.slots[OUTPUT], nil, "nothing made")
			t.eq(Machines.energy(container), CAPACITY - 50 * USE, "nothing used")
			t.eq(field(container, "progress"), 50, "the progress kept")
			t.eq(field(container, "rate"), 0)
			t.eq(Machines.state(container), IDLE)
			t.eq(status(container), "Idle")
			t.eq(container.slots[INGOT].count, 3, "the inputs stay")
		end)
		Config.AmmoPress.Enabled = true
		if not ok then
			error(err, 0)
		end
		tick(container, TICKS - 50)
		t.eq(container.slots[OUTPUT] and container.slots[OUTPUT].count, 16, "on again: it finishes")
	end)

	--[[ On the server ]]

	-- Machines in a world of blocks, ticked as the server does (transporters, machines, networks).
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
		function self.chest(x: number, y: number, z: number): { [number]: any }
			return containers:get(x, y, z, B.Chest).slots
		end
		self.world = world
		self.cables = cables
		return self
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

	t.test("ammo press: transporters feed it and it pushes its rounds into a chest", function()
		local s = sim()
		local WEST = 4
		-- A chest -> an Advanced transporter -> the press; the creative cube on top powers it and
		-- a chest on its east side takes the rounds it pushes out.
		s.set(0, Y, 0, B.Chest)
		s.set(1, Y, 0, B.AdvancedLogisticalTransporter)
		s.set(2, Y, 0, PRESS)
		s.set(2, Y + 1, 0, B.CreativeEnergyCube)
		s.set(3, Y, 0, B.Chest)
		t.ok(TransmitterWorld.setMode(s.cables, 1, Y, 0, WEST, Transmitters.MODES.PULL))
		local source, results = s.chest(0, Y, 0), s.chest(3, Y, 0)
		source[1] = S(I.IronIngot, 3)
		source[2] = S(I.Gunpowder, 3)
		source[3] = S(I.Coal, 2)
		local machine = s.container(2, Y, 0)
		s.step(60)
		t.eq(machine.slots[INGOT] and machine.slots[INGOT].item, I.IronIngot, "ingots in through a side")
		t.eq(machine.slots[GUNPOWDER] and machine.slots[GUNPOWDER].item, I.Gunpowder, "and the gunpowder")
		t.eq(count(source, I.Coal), 2, "coal: nowhere to go")
		local record = s.record(2, Y, 0)
		t.eq(record.active, true, "the record says it works (its window, its stamp)")
		t.eq(record.rate, -USE)
		s.step(3 * TICKS + 20)
		t.eq(count(results, I.Rounds9mm), 48, "three operations' rounds in the chest")
		t.eq(machine.slots[OUTPUT], nil, "pushed out of the output")
		t.eq(machine.slots[INGOT], nil)
		t.eq(count(source, I.IronIngot) + count(source, I.Gunpowder), 0, "everything pressed")
		t.eq(s.cables.itemCount, 0, "no round went into the transporter: it has nowhere to take them")
		-- Set to .308 while it is fed again.
		source[1] = S(I.IronIngot, 1)
		source[2] = S(I.Gunpowder, 1)
		Machines.button(machine, PRESS, 0)
		Machines.button(machine, PRESS, 0)
		s.step(TICKS + 80)
		t.eq(count(results, I.Rounds308), 5, ".308 too")
		-- One input without the other: its record says why, as WAILA shows it.
		source[1] = S(I.IronIngot, 1)
		s.step(40)
		record = s.record(2, Y, 0)
		t.eq(record.state, NO_INPUT)
		local sent = (Protocol.decodeMachines(Protocol.encodeMachines({ record })) :: any)[1]
		local facts = WailaInfo.machineDefaults(PRESS)
		facts.energy, facts.capacity, facts.rate, facts.active, facts.state =
			sent.energy, sent.capacity, sent.rate, sent.active, sent.state
		t.eq(WailaInfo.text(WailaInfo.machineLines(PRESS, facts)[2]), "No input")
	end)

	t.test("ammo press: a transporter under it takes its rounds to a chest", function()
		local s = sim()
		s.set(0, Y, 0, PRESS)
		s.set(0, Y + 1, 0, B.CreativeEnergyCube)
		s.set(0, Y - 1, 0, B.BasicLogisticalTransporter)
		s.set(1, Y - 1, 0, B.BasicLogisticalTransporter)
		s.set(2, Y - 1, 0, B.Chest)
		t.ok(TransmitterWorld.setMode(s.cables, 0, Y - 1, 0, UP, Transmitters.MODES.PULL))
		local machine = s.container(0, Y, 0)
		machine.slots[INGOT] = S(I.IronIngot, 2)
		machine.slots[GUNPOWDER] = S(I.Gunpowder, 2)
		Machines.button(machine, PRESS, 0)
		s.step(2 * TICKS + 120)
		t.eq(count(s.chest(2, Y - 1, 0), I.Rounds556), 20, "two operations of 5.56 down the line")
		t.eq(machine.slots[OUTPUT], nil)
		t.eq(s.cables.itemCount, 0)
	end)

	t.test("ammo press: keeps its energy and calibre in its item, not its progress", function()
		local s = sim()
		local registry = EditRules.newBlockData()
		registry:add(TransmitterWorld.blockDataHooks(s.cables))
		registry:add(MachineWorld.blockDataHooks(s.world))
		s.set(0, Y, 0, PRESS)
		local container = s.container(0, Y, 0)
		container.data[ENERGY] = 12345
		container.slots[INGOT] = S(I.IronIngot, 3)
		container.slots[GUNPOWDER] = S(I.Gunpowder, 3)
		Machines.button(container, PRESS, 0)
		Machines.button(container, PRESS, 0)
		s.step(10)
		t.eq(Machines.get(container, "progress"), 10)
		local drop = EditRules.breakDrop(registry, 0, Y, 0, PRESS, false, I.IronPickaxe) :: any
		s.set(0, Y, 0, AIR)
		t.eq(drop.item, PRESS)
		t.eq(drop.data.energy, 12345 - 10 * USE)
		t.eq(drop.data.calibre, 3, "the calibre goes with it")
		t.eq(drop.data.progress, nil, "its slots drop, so its progress goes")
		s.set(4, Y, 0, PRESS)
		registry:placed("p", 4, Y, 0, PRESS, drop)
		local placed = s.container(4, Y, 0)
		t.eq(Machines.energy(placed), 12345 - 10 * USE)
		t.eq(Machines.get(placed, "calibre"), 3, "placed again: .308")
		t.eq(Machines.get(placed, "progress"), 0)
		t.eq(MenuLayout.lineTexts(placed)[1], "5 .308 Rounds")
	end)

	--[[ What players see ]]

	t.test("ammo press: its panel, status line, line and WAILA lines", function()
		local container: any = press(CAPACITY, 1, 1)
		local panel = MenuLayout.panel(container)
		t.eq(panel.title, "Ammo Press")
		t.eq(#panel.slots, 5)
		local spots = { { 38, 35 }, { 56, 35 }, { 116, 35 }, { 8, 53 }, { 26, 53 } }
		for i, spot in spots do
			t.eq(panel.slots[i].x, spot[1], `slot {i} x`)
			t.eq(panel.slots[i].y, spot[2], `slot {i} y`)
		end
		local progress = panel.progress :: any
		t.ok(progress.x == 79 and progress.y == 34, "the arrow between the inputs and the output")
		local line = panel.status :: any
		t.ok(line.x == 8 and line.y == 20, "the status line above the row")
		t.eq(#panel.buttons, 1)
		local button = panel.buttons[1]
		t.ok(button.x == 52 and button.y == 56 and button.w == 44 and button.h == 14, "the Calibre button")
		t.eq(#panel.lines, 1, "one line")
		t.ok(panel.lines[1].x == 100 and panel.lines[1].y == 60, "right of the button")
		t.eq(MenuLayout.lineTexts(container)[1], "16 9mm Rounds")
		-- The arrow fills over the 200 ticks.
		t.eq(MenuLayout.machineArrowColumns(container.data, panel.progressSource), 0)
		tick(container, 100)
		t.eq(MenuLayout.machineArrowColumns(container.data, panel.progressSource), 12, "half way")
		tick(container, 99)
		t.eq(MenuLayout.machineArrowColumns(container.data, panel.progressSource), 23)
		t.eq(MenuLayout.statusText(container), "Using 50 J/t")
		-- Without the window's data (WAILA) there is no line.
		t.eq(#Machines.lines(PRESS, Machines.view(container), nil), 0)
		-- WAILA: energy and the status, from the record.
		local facts = WailaInfo.machineDefaults(PRESS)
		local lines = WailaInfo.machineLines(PRESS, facts)
		t.eq(WailaInfo.text(lines[1]), "Energy: 0 J / 20 kJ")
		t.eq(WailaInfo.text(lines[2]), "Idle")
		for state, text in { [NO_POWER] = "No power", [OUTPUT_FULL] = "Output full", [NO_INPUT] = "No input" } do
			facts.state = state
			t.eq(WailaInfo.text(WailaInfo.machineLines(PRESS, facts)[2]), text)
		end
		facts.state, facts.rate, facts.active = IDLE, -USE, true
		t.eq(WailaInfo.text(WailaInfo.machineLines(PRESS, facts)[2]), "Using 50 J/t")
		t.eq(WailaInfo.text(WailaInfo.machineDetails(PRESS, facts)[1]), "Machine press (consumer)")
	end)
end

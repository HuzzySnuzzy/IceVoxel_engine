--[[
	The Ammo Press (Shared/Machines/Kinds/AmmoPress, kind "press", BlockList AmmoPress,
	Config.AmmoPress): the block and its numbers, the slots (brass, gunpowder, the output, the
	cards and lead appended as 6th: hand, shift-click, transporters through any face filling each
	input by what it takes, never the cards), an operation of each calibre (a Brass Ingot, a Lead
	Ingot and a Gunpowder into 16 9mm, 10 5.56 or 5 .308 rounds in 200 ticks at 50 J a tick),
	Mekanism's upgrade maths at every card count, cards swapped mid-operation (its share kept), the
	Calibre button and its choice kept in the item, every combination of missing inputs (each
	named), a full output and no power, data from elsewhere, the real server worlds (transporters
	feeding all three inputs, its rounds pushed into a chest, the records WAILA reads, the item
	keeping its energy and calibre), a press saved with five slots and Iron Ingots loading into six,
	switched off, and the panel, its line and WAILA's lines.
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
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Containers = require(server.Players.Containers)
	local EditRules = require(server.Network.EditRules)
	local MachineWorld = require(server.Machines.MachineWorld)
	local TransmitterWorld = require(server.Transmitters.TransmitterWorld)
	local RegionCodec = require(server.Save.RegionCodec)
	local WorldSnapshot = require(server.Save.WorldSnapshot)
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
	-- Slots (lead appended after the cards) and states (NO_INPUT + 4 x the missing inputs' bits: 1
	-- brass, 2 lead, 4 gunpowder).
	local BRASS, GUNPOWDER, OUTPUT, SPEED, CARDS, LEAD = 1, 2, 3, 4, 5, 6
	local IDLE, NO_POWER, OUTPUT_FULL, NO_INPUT = 0, 1, 2, 3
	local function noInput(missing: number): number
		return NO_INPUT + 4 * missing
	end
	-- The three inputs: their slots and items, in the panel's order.
	local INPUTS = {
		{ slot = BRASS, item = I.BrassIngot },
		{ slot = LEAD, item = I.LeadIngot },
		{ slot = GUNPOWDER, item = I.Gunpowder },
	}
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

	-- Puts `brass` Brass Ingots, `lead` Lead Ingots and `powder` Gunpowder into a press's inputs
	-- (0: empty).
	local function fill(container: any, brass: number, lead: number, powder: number)
		for i, n in { brass, lead, powder } do
			local input = INPUTS[i]
			container.slots[input.slot] = if n > 0 then S(input.item, n) else nil
		end
	end

	-- A fresh press holding `energy` J and `sets` of each input, pressing calibre `calibre` (1
	-- when nil).
	local function press(energy: number, sets: number, calibre: number?): any
		local container: any = Machines.newContainer(PRESS)
		container.data[ENERGY] = energy
		fill(container, sets, sets, sets)
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
		t.eq(Machines.containerSize(PRESS), 6, "brass, gunpowder, output, the two cards and lead")
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

	t.test("ammo press: brass, lead and gunpowder in, rounds out; the cards by hand only", function()
		t.ok(Machines.mayPlace(PRESS, BRASS, I.BrassIngot))
		t.ok(Machines.mayPlace(PRESS, LEAD, I.LeadIngot))
		t.ok(Machines.mayPlace(PRESS, GUNPOWDER, I.Gunpowder))
		-- (Iron Ingots, which it took before lead and brass, go in nowhere now.)
		for _, item in { I.IronIngot, I.LeadIngot, I.CopperIngot, I.GoldIngot, I.Rounds9mm, I.Gunpowder } do
			t.ok(not Machines.mayPlace(PRESS, BRASS, item), `no {Items.displayName(item)} for the brass`)
		end
		for _, item in { I.IronIngot, I.BrassIngot, I.RawLead, I.LeadNugget, I.Gunpowder } do
			t.ok(not Machines.mayPlace(PRESS, LEAD, item), `no {Items.displayName(item)} for the lead`)
		end
		for _, item in { I.IronIngot, I.BrassIngot, I.LeadIngot, I.Coal, I.Flint, I.Sulfur, I.Rounds556 } do
			t.ok(not Machines.mayPlace(PRESS, GUNPOWDER, item), `no {Items.displayName(item)} for the powder`)
		end
		t.ok(Machines.isOutput(PRESS, OUTPUT))
		t.ok(not Machines.isOutput(PRESS, LEAD), "the lead slot is an input")
		t.ok(not Machines.mayPlace(PRESS, OUTPUT, I.Rounds9mm), "nothing goes into the output")
		t.eq(table.concat(Machines.quickMoveTargets(PRESS, I.BrassIngot), ","), "1")
		t.eq(table.concat(Machines.quickMoveTargets(PRESS, I.LeadIngot), ","), "6")
		t.eq(table.concat(Machines.quickMoveTargets(PRESS, I.Gunpowder), ","), "2")
		t.eq(table.concat(Machines.quickMoveTargets(PRESS, I.SpeedUpgrade), ","), "4")
		t.eq(table.concat(Machines.quickMoveTargets(PRESS, I.EnergyUpgrade), ","), "5")
		t.eq(#Machines.quickMoveTargets(PRESS, I.Rounds9mm), 0)
		t.eq(#Machines.quickMoveTargets(PRESS, I.IronIngot), 0, "iron: between the inventory and the hotbar")
		t.eq(Machines.slotLimit(PRESS, SPEED, I.SpeedUpgrade), Upgrades.MAX)
		t.eq(Machines.slotLimit(PRESS, LEAD, I.LeadIngot), 64, "a stack of lead")
		-- Shift-clicks through Inventory/Menu, as the client predicts and the server runs them.
		local container = Machines.newContainer(PRESS)
		local inventory = Types.newInventory()
		local window: any = { id = 1, inventory = inventory, container = container }
		local function slotOf(index: number): number
			return Menu.windowIndex(window, "inventory", index) :: number
		end
		inventory.slots[1] = S(I.BrassIngot, 20)
		inventory.slots[2] = S(I.LeadIngot, 12)
		inventory.slots[3] = S(I.Gunpowder, 7)
		inventory.slots[4] = S(I.SpeedUpgrade, 3)
		for slot = 1, 4 do
			Menu.apply(window, { kind = "click", window = 1, slot = slotOf(slot), clickType = 1, button = 0 }, false)
		end
		t.eq(container.slots[BRASS] and container.slots[BRASS].count, 20, "the brass")
		t.eq(container.slots[LEAD] and container.slots[LEAD].count, 12, "the lead, into slot 6")
		t.eq(container.slots[GUNPOWDER] and container.slots[GUNPOWDER].count, 7, "the gunpowder")
		t.eq(container.slots[SPEED] and container.slots[SPEED].count, 3, "the cards")
		for slot = 1, 4 do
			t.eq(inventory.slots[slot], nil, `inventory slot {slot} emptied`)
		end
		-- And back out: shift-clicking the lead slot puts it into the inventory.
		local leadSlot = Menu.windowIndex(window, "container", LEAD) :: number
		Menu.apply(window, { kind = "click", window = 1, slot = leadSlot, clickType = 1, button = 0 }, false)
		t.eq(container.slots[LEAD], nil, "the lead out")
		local back = 0
		for _, stack in inventory.slots do
			if stack and stack.item == I.LeadIngot then
				back += stack.count
			end
		end
		t.eq(back, 12, "all of it in the inventory")
		-- Transporters: the three inputs through every face, each item into the slot that takes
		-- it, the rounds out through every face, never the cards.
		for face = 0, 5 do
			t.eq(table.concat(Machines.insertSlots(PRESS, face), ","), "1,2,6", `face {face} takes the three inputs`)
			t.eq(table.concat(Machines.extractSlots(PRESS, face), ","), "3", `face {face} gives the rounds`)
			t.ok(not Transmitters.canInsert(PRESS, face, SPEED, I.SpeedUpgrade), "no cards in")
			t.ok(Transmitters.canInsert(PRESS, face, LEAD, I.LeadIngot), "lead in")
			t.ok(not Transmitters.canInsert(PRESS, face, LEAD, I.BrassIngot), "no brass into the lead's slot")
			for _, input in INPUTS do
				t.ok(not Transmitters.canExtract(PRESS, face, input.slot, input.item), "the inputs stay")
			end
		end
		t.eq(table.concat(Machines.outputSlots(PRESS), ","), "3", "it pushes its rounds out")
		t.ok(Transmitters.ejects(PRESS))
		local slots: any = {}
		for face, input in { [4] = INPUTS[3], [0] = INPUTS[2], [1] = INPUTS[1] } do
			local left
			slots, left = Transmitters.insert(PRESS, face, slots, S(input.item, 3))
			t.eq(left, nil, `{Items.displayName(input.item)} through face {face}`)
			t.eq(slots[input.slot] and slots[input.slot].item, input.item, `into slot {input.slot}`)
			t.eq(slots[input.slot] and slots[input.slot].count, 3)
		end
		t.eq(Transmitters.room(PRESS, UP, slots, S(I.LeadIngot, 64)), 61, "room for a stack of lead")
		t.eq(Transmitters.room(PRESS, UP, {}, S(I.Rounds9mm, 3)), 0, "no rounds in")
		t.eq(Transmitters.room(PRESS, UP, {}, S(I.IronIngot, 3)), 0, "no iron in")
	end)

	--[[ Pressing ]]

	t.test(
		"ammo press: a brass, a lead and a gunpowder make each calibre's rounds, 200 ticks at 50 J a tick",
		function()
			for index, calibre in CALIBRES do
				local container = press(CAPACITY, 2, index)
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
				t.eq(container.slots[BRASS].count, 1, "one brass")
				t.eq(container.slots[LEAD].count, 1, "one lead")
				t.eq(container.slots[GUNPOWDER].count, 1, "and one gunpowder an operation")
				t.eq(field(container, "progress"), 0)
				t.eq(Machines.energy(container), CAPACITY - TICKS * USE, "10 kJ an operation")
				-- The next starts at once, then it runs out of inputs.
				container.data[ENERGY] = CAPACITY
				tick(container, TICKS)
				t.eq(container.slots[OUTPUT].count, 2 * calibre.count, "a second operation")
				t.eq(container.slots[BRASS], nil, "all used")
				t.eq(container.slots[LEAD], nil)
				t.eq(container.slots[GUNPOWDER], nil)
				t.eq(Machines.energy(container), CAPACITY - TICKS * USE)
				tick(container)
				t.eq(field(container, "rate"), 0)
				t.eq(Machines.state(container), IDLE)
				t.eq(status(container), "Idle")
				t.eq(Machines.energy(container), CAPACITY - TICKS * USE, "idle: nothing used")
			end
			-- What is left of an input keeps its data.
			local tagged = press(CAPACITY, 3)
			tagged.slots[LEAD] = { item = I.LeadIngot, count = 3, data = { tag = 1 } }
			tick(tagged, TICKS)
			t.eq(tagged.slots[LEAD].count, 2)
			t.eq(tagged.slots[LEAD].data and tagged.slots[LEAD].data.tag, 1, "the ingots keep their data")
			t.eq(tagged.slots[BRASS].count, 2)
			-- Uneven stacks: it presses until the first runs out, then waits for it.
			local uneven = press(CAPACITY, 0)
			fill(uneven, 3, 1, 2)
			tick(uneven, TICKS)
			t.eq(uneven.slots[OUTPUT] and uneven.slots[OUTPUT].count, 16)
			t.ok(uneven.slots[BRASS].count == 2 and uneven.slots[LEAD] == nil and uneven.slots[GUNPOWDER].count == 1)
			uneven.data[ENERGY] = CAPACITY
			tick(uneven, TICKS)
			t.eq(uneven.slots[OUTPUT].count, 16, "no lead: no second operation")
			t.eq(Machines.state(uneven), noInput(2))
			t.eq(status(uneven), "No lead")
		end
	)

	t.test("ammo press: Speed and Energy Upgrades follow Mekanism's maths at every card count", function()
		for speed = 0, Upgrades.MAX do
			for energy = 0, Upgrades.MAX do
				local container = press(0, 1)
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
		local container = press(0, 1)
		container.slots[CARDS] = S(I.EnergyUpgrade, 8)
		tick(container)
		container.data[ENERGY] = 150000
		container.slots[CARDS] = nil
		tick(container)
		t.eq(Machines.capacity(container), CAPACITY)
		t.eq(Machines.energy(container), CAPACITY - USE, "cut to 20 kJ, then a tick's work")
	end)

	t.test("ammo press: cards in or out mid-operation keep its share of the work, none skipped", function()
		-- Half of the 200 ticks at 50 J/t, then 8 Speed Upgrades: half of the 20 at 5 kJ/t.
		local container = press(CAPACITY, 3)
		tick(container, TICKS / 2)
		container.slots[SPEED] = S(I.SpeedUpgrade, 8)
		local took, used = operation(container, TICKS)
		t.eq(took, 10, "100 of 200 ticks are 10 of 20")
		t.eq(used, 10 * Machines.quantiseUp(Upgrades.energyPerTick(USE, 8, 0)), "half of 100 kJ")
		-- Halfway through the next the cards come out: 10 of 20 ticks are 100 of 200.
		container.slots[OUTPUT] = nil
		for _ = 1, 10 do
			container.data[ENERGY] = Machines.quantise(Machines.capacity(container))
			tick(container)
		end
		t.eq(field(container, "progress"), 10)
		container.slots[SPEED] = nil
		took, used = operation(container, TICKS)
		t.eq(took, 100, "the other half at 200 ticks")
		t.eq(used, 100 * USE)
		-- Rounded down, never ahead: 7 of 200 ticks are none of 20.
		container.slots[OUTPUT] = nil
		tick(container, 7)
		container.slots[SPEED] = S(I.SpeedUpgrade, 8)
		took = operation(container, TICKS)
		t.eq(took, 20)
		t.eq(container.slots[OUTPUT] and container.slots[OUTPUT].count, 16)
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
		fill(placed, 1, 1, 1)
		tick(placed, TICKS)
		t.eq(placed.slots[OUTPUT] and placed.slots[OUTPUT].item, I.Rounds556)
		-- Every calibre costs the same: switching keeps the progress, and what comes out is the
		-- calibre chosen when it finishes.
		local switched = press(CAPACITY, 1)
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
			local odd = press(CAPACITY, 1)
			Machines.set(odd, "calibre", bad)
			t.eq(MenuLayout.lineTexts(odd)[1], CALIBRES[1].line, `calibre {bad}: 9mm`)
			tick(odd)
			t.eq(field(odd, "calibre"), 1)
		end
	end)

	--[[ Why it waits ]]

	t.test("ammo press: every combination of missing inputs, a full output and no power", function()
		-- One or two of the three without the rest: NO_INPUT naming what is missing (its bits on
		-- top of the code), nothing used; none of them: "Idle".
		local texts = {
			[1] = "No brass",
			[2] = "No lead",
			[3] = "No brass or lead",
			[4] = "No gunpowder",
			[5] = "No brass or gunpowder",
			[6] = "No lead or gunpowder",
		}
		for missing = 0, 7 do
			local container = press(CAPACITY, 0)
			fill(
				container,
				if bit32.btest(missing, 1) then 0 else 4,
				if bit32.btest(missing, 2) then 0 else 4,
				if bit32.btest(missing, 4) then 0 else 4
			)
			tick(container, 10)
			local what = `missing {missing}`
			if missing == 0 then
				t.eq(field(container, "progress"), 10, "all three: it presses")
				continue
			end
			if missing == 7 then
				t.eq(Machines.state(container), IDLE, "none of them: idle")
				t.eq(status(container), "Idle")
			else
				t.eq(Machines.state(container), noInput(missing), what)
				t.eq(Machines.state(container) % 4, NO_INPUT, `{what}: the code is NO_INPUT`)
				t.eq(status(container), texts[missing], what)
			end
			t.eq(field(container, "progress"), 0, what)
			t.eq(Machines.energy(container), CAPACITY, `{what}: nothing used`)
			t.eq(field(container, "active"), 0)
			t.eq(field(container, "rate"), 0)
			t.eq(container.slots[OUTPUT], nil)
		end
		-- (A state saved before lead, the bare code, and odd bits read "No input".)
		local view = Machines.view(press(0, 0))
		for _, state in { NO_INPUT, noInput(8), noInput(40) } do
			view.state = state
			t.eq(Machines.status(PRESS, view), "No input", `state {state}`)
		end
		view.state = noInput(7)
		t.eq(Machines.status(PRESS, view), "No brass, lead or gunpowder", "every bit (data from elsewhere)")
		-- Taking any input away starts over.
		for _, input in INPUTS do
			local taken = press(CAPACITY, 1)
			tick(taken, 80)
			local stack = taken.slots[input.slot]
			taken.slots[input.slot] = nil
			tick(taken)
			t.eq(field(taken, "progress"), 0, `{Items.displayName(input.item)} out: the progress goes`)
			t.eq(Machines.state(taken) % 4, NO_INPUT)
			taken.slots[input.slot] = stack
			tick(taken)
			t.eq(field(taken, "progress"), 1, "from the start")
			t.eq(Machines.energy(taken), CAPACITY - 81 * USE, "the energy of 81 ticks' work")
		end

		-- A full output: all of an operation's rounds must fit (9mm stack to 60, .308 to 40).
		t.eq(Items.maxStack(I.Rounds9mm), 60)
		t.eq(Items.maxStack(I.Rounds308), 40)
		local full = press(CAPACITY, 1)
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
		local other = press(CAPACITY, 1)
		other.slots[OUTPUT] = S(I.Rounds556, 1)
		tick(other)
		t.eq(status(other), "Output full", "5.56 rounds in the output: no room for 9mm")
		Machines.button(other, PRESS, 0)
		tick(other)
		t.eq(field(other, "progress"), 1, "set to 5.56 it presses onto them")
		local marked = press(CAPACITY, 1)
		marked.slots[OUTPUT] = { item = I.Rounds9mm, count = 1, data = { note = "x" } }
		tick(marked)
		t.eq(status(marked), "Output full", "rounds with other data don't stack")
		local sniper = press(CAPACITY, 2, 3)
		sniper.slots[OUTPUT] = S(I.Rounds308, 35)
		tick(sniper, TICKS)
		t.eq(sniper.slots[OUTPUT].count, 40, "35 + 5 .308")
		tick(sniper)
		t.eq(status(sniper), "Output full")

		-- No power: the progress waits, and goes on when energy comes.
		local starved = press(2 * USE + 20, 1)
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
		local both = press(0, 1)
		both.slots[OUTPUT] = S(I.Rounds9mm, 60)
		tick(both)
		t.eq(status(both), "Output full")
	end)

	t.test("ammo press: progress, numbers and inputs from elsewhere are kept sane", function()
		local forged = press(CAPACITY, 1)
		Machines.set(forged, "progress", 1e12)
		tick(forged)
		t.eq(forged.slots[OUTPUT] and forged.slots[OUTPUT].count, 16, "a full arrow finishes on the next tick")
		t.eq(field(forged, "progress"), 0)
		local negative = press(CAPACITY, 1)
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
		local wrong = press(CAPACITY, 5)
		wrong.slots[BRASS] = S(I.GoldIngot, 5)
		wrong.slots[LEAD] = S(I.BrassIngot, 5)
		tick(wrong, TICKS)
		t.eq(wrong.slots[OUTPUT], nil, "gold and brass in the wrong slots press nothing")
		t.eq(status(wrong), "No brass or lead")
		t.eq(Machines.energy(wrong), CAPACITY)
		Machines.set(wrong, "state", 7.5)
		t.eq(Machines.view(wrong).state, 0, "a state is a small whole number")
	end)

	--[[ Switched off ]]

	t.test("ammo press: switched off it is inert, and goes on where it was when on again", function()
		local container = press(CAPACITY, 3)
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
			t.eq(container.slots[BRASS].count, 3, "the inputs stay")
			t.eq(container.slots[LEAD].count, 3)
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
		self.containers = containers
		self.blocks = blocks
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

	t.test("ammo press: transporters feed all three inputs and it pushes its rounds into a chest", function()
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
		source[1] = S(I.Coal, 2)
		source[2] = S(I.BrassIngot, 3)
		source[3] = S(I.IronIngot, 2)
		source[4] = S(I.LeadIngot, 3)
		source[5] = S(I.Gunpowder, 3)
		local machine = s.container(2, Y, 0)
		s.step(80)
		-- (Each into the slot that takes it, through the same side.)
		for _, input in INPUTS do
			local stack = machine.slots[input.slot]
			t.eq(stack and stack.item, input.item, `{Items.displayName(input.item)} into slot {input.slot}`)
		end
		t.eq(count(source, I.Coal), 2, "coal: nowhere to go")
		t.eq(count(source, I.IronIngot), 2, "nor iron")
		local record = s.record(2, Y, 0)
		t.eq(record.active, true, "the record says it works (its window, its stamp)")
		t.eq(record.rate, -USE)
		s.step(3 * TICKS + 20)
		t.eq(count(results, I.Rounds9mm), 48, "three operations' rounds in the chest")
		t.eq(machine.slots[OUTPUT], nil, "pushed out of the output")
		for _, input in INPUTS do
			t.eq(machine.slots[input.slot], nil, "every input used")
			t.eq(count(source, input.item), 0, "everything pressed")
		end
		t.eq(s.cables.itemCount, 0, "no round went into the transporter: it has nowhere to take them")
		-- Set to .308 while it is fed again.
		source[2] = S(I.BrassIngot, 1)
		source[4] = S(I.LeadIngot, 1)
		source[5] = S(I.Gunpowder, 1)
		Machines.button(machine, PRESS, 0)
		Machines.button(machine, PRESS, 0)
		s.step(TICKS + 80)
		t.eq(count(results, I.Rounds308), 5, ".308 too")
		-- Brass and lead without gunpowder: its record says why, as WAILA shows it.
		source[2] = S(I.BrassIngot, 1)
		source[4] = S(I.LeadIngot, 1)
		s.step(60)
		record = s.record(2, Y, 0)
		t.eq(record.state, noInput(4))
		local sent = (Protocol.decodeMachines(Protocol.encodeMachines({ record })) :: any)[1]
		local facts = WailaInfo.machineDefaults(PRESS)
		facts.energy, facts.capacity, facts.rate, facts.active, facts.state =
			sent.energy, sent.capacity, sent.rate, sent.active, sent.state
		t.eq(WailaInfo.text(WailaInfo.machineLines(PRESS, facts)[2]), "No gunpowder")
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
		fill(machine, 2, 2, 2)
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
		fill(container, 3, 3, 3)
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

	t.test("ammo press: a press saved with five slots, Iron Ingots in the first, loads into six", function()
		-- A region as a build before lead saved it: the press's edit and its container record of
		-- five slots (Iron Ingots, gunpowder, 5.56 rounds, the cards) with its data, pressing then
		-- (120 ticks into an operation, at 50 J a tick).
		local x, z = 3, 5
		local cx, cz, lx, lz = Coords.blockToChunk(x, z)
		local region = RegionCodec.new(0, 0)
		region.chunks[Coords.chunkKey(cx, cz)] = { [ChunkLayout.localIndex(lx, Y, lz)] = PRESS }
		local saved = {
			[1] = S(I.IronIngot, 3),
			[2] = S(I.Gunpowder, 2),
			[3] = S(I.Rounds556, 10),
			[4] = S(I.SpeedUpgrade, 2),
			[5] = S(I.EnergyUpgrade, 1),
		}
		local data = Machines.newData(PRESS)
		data[ENERGY] = 5000
		local old: any = { block = PRESS, data = data }
		Machines.set(old, "progress", 120)
		Machines.set(old, "calibre", 2)
		Machines.set(old, "rate", -USE)
		Machines.set(old, "active", 1)
		table.insert(region.containers, {
			x = x,
			y = Y,
			z = z,
			container = { kind = Machines.CONTAINER_KIND, block = PRESS, size = 5, slots = saved, data = data },
		})
		local loaded = RegionCodec.decode(RegionCodec.encode(region), 0, 0)
		t.eq(loaded.containers[1].container.size, 5, "five slots in the save")

		-- Loaded as World/WorldSave loads it: the block's fresh container, the saved slots and data
		-- copied in.
		local s = sim()
		s.blocks[Coords.posKey(x, Y, z)] = PRESS
		local report = WorldSnapshot.restore(
			{ containers = s.containers, transmitters = s.cables, machines = s.world } :: any,
			{ loaded }
		)
		t.eq(report.containers, 1)
		t.eq(report.machines, 1)
		local container = s.container(x, Y, z)
		t.eq(container, s.containers:peek(x, Y, z), "the machine took the restored container")
		t.eq(container.size, 6, "the block's six slots")
		for slot, stack in saved do
			local now = container.slots[slot]
			t.ok(now and now.item == stack.item and now.count == stack.count, `slot {slot} kept`)
		end
		t.eq(container.slots[LEAD], nil, "the lead's slot empty")
		t.eq(Machines.energy(container), 5000)
		t.eq(field(container, "calibre"), 2)
		t.eq(status(container), "Using 50 J/t", "as saved")
		t.eq(field(container, "progress"), 120)
		t.eq(#MenuLayout.panel(container).slots, 6, "its panel shows the six")

		-- Its first tick: Iron Ingots are no brass, so with the gunpowder it says what is missing;
		-- the operation starts over and nothing is used or made.
		s.step()
		t.eq(Machines.state(container), noInput(1 + 2))
		t.eq(status(container), "No brass or lead")
		t.eq(field(container, "progress"), 0, "the half operation is gone")
		t.eq(Machines.energy(container), 5000, "nothing used")
		t.eq(container.slots[OUTPUT].count, 10, "nothing made")
		t.eq(container.slots[BRASS].item, I.IronIngot, "the iron stays")
		t.eq(container.slots[BRASS].count, 3)
		-- No transporter takes it out (inputs stay), and the ejector pushes only the rounds.
		for face = 0, 5 do
			t.ok(not Transmitters.canExtract(PRESS, face, BRASS, I.IronIngot), `face {face}: the iron stays`)
		end
		t.eq(table.concat(Machines.outputSlots(PRESS), ","), "3")
		-- By hand: a click takes it, another can't put it back.
		local inventory = Types.newInventory()
		local window: any = { id = 1, inventory = inventory, container = container }
		local brassSlot = Menu.windowIndex(window, "container", BRASS) :: number
		Menu.apply(window, { kind = "click", window = 1, slot = brassSlot, clickType = 0, button = 0 }, false)
		t.eq(container.slots[BRASS], nil, "taken")
		t.ok(inventory.cursor and inventory.cursor.item == I.IronIngot and inventory.cursor.count == 3, "on the cursor")
		Menu.apply(window, { kind = "click", window = 1, slot = brassSlot, clickType = 0, button = 0 }, false)
		t.eq(container.slots[BRASS], nil, "it doesn't go back in")
		t.eq(inventory.cursor and inventory.cursor.count, 3)
		-- Shift-click: out into the inventory, and from there never into the press.
		container.slots[BRASS] = inventory.cursor
		inventory.cursor = nil
		Menu.apply(window, { kind = "click", window = 1, slot = brassSlot, clickType = 1, button = 0 }, false)
		t.eq(container.slots[BRASS], nil, "shift-clicked out")
		local at: number? = nil
		for index, stack in inventory.slots do
			if stack and stack.item == I.IronIngot then
				at = index
			end
		end
		t.ok(at ~= nil, "into the inventory")
		Menu.apply(window, {
			kind = "click",
			window = 1,
			slot = Menu.windowIndex(window, "inventory", at :: number) :: number,
			clickType = 1,
			button = 0,
		}, false)
		t.eq(container.slots[BRASS], nil, "and not back")

		-- With brass and lead it presses on: two Speed and an Energy card, calibre 2.
		s.set(x, Y + 1, z, B.CreativeEnergyCube)
		container.slots[BRASS] = S(I.BrassIngot, 2)
		container.slots[LEAD] = S(I.LeadIngot, 2)
		local ticks = Upgrades.ticks(TICKS, 2)
		s.step(ticks + 1)
		t.eq(container.slots[OUTPUT] and container.slots[OUTPUT].count, 20, "an operation's 5.56 onto the saved")
		t.ok(
			container.slots[BRASS].count == 1
				and container.slots[LEAD].count == 1
				and container.slots[GUNPOWDER].count == 1
		)

		-- Saved again: six slots, the lead's with them.
		local again = RegionCodec.new(0, 0)
		table.insert(again.containers, { x = x, y = Y, z = z, container = container })
		local back = RegionCodec.decode(RegionCodec.encode(again), 0, 0).containers[1].container
		t.eq(back.size, 6)
		t.ok(
			back.slots[LEAD] and back.slots[LEAD].item == I.LeadIngot and back.slots[LEAD].count == 1,
			"the lead saved"
		)
	end)

	--[[ What players see ]]

	t.test("ammo press: its panel, status line, line and WAILA lines", function()
		local container: any = press(CAPACITY, 1)
		local panel = MenuLayout.panel(container)
		t.eq(panel.title, "Ammo Press")
		t.eq(#panel.slots, 6)
		-- Brass, gunpowder, the output, the cards, and lead between the brass and the gunpowder: the
		-- row reads brass, lead, gunpowder, 18 apart.
		local spots = { { 20, 35 }, { 56, 35 }, { 116, 35 }, { 8, 53 }, { 26, 53 }, { 38, 35 } }
		for i, spot in spots do
			t.eq(panel.slots[i].slot, i)
			t.eq(panel.slots[i].x, spot[1], `slot {i} x`)
			t.eq(panel.slots[i].y, spot[2], `slot {i} y`)
		end
		local progress = panel.progress :: any
		t.ok(progress.x == 79 and progress.y == 34, "the arrow between the inputs and the output")
		-- (No two slot frames over each other, the inputs left of the arrow, all clear of the status
		-- line, the button and the energy bar.)
		local function frame(spot: any): (number, number, number, number)
			local inset, size = if spot.big then 5 else 1, if spot.big then 26 else 18
			return spot.x - inset, spot.y - inset, size, size
		end
		local function apart(ax, ay, aw, ah, bx, by, bw, bh): boolean
			return ax + aw <= bx or bx + bw <= ax or ay + ah <= by or by + bh <= ay
		end
		local button = panel.buttons[1]
		local bar = panel.energy :: any
		for i, a in panel.slots do
			local ax, ay, aw, ah = frame(a)
			for j = i + 1, #panel.slots do
				local bx, by, bw, bh = frame(panel.slots[j])
				t.ok(apart(ax, ay, aw, ah, bx, by, bw, bh), `slots {i} and {j} apart`)
			end
			t.ok(apart(ax, ay, aw, ah, button.x, button.y, button.w, button.h), `slot {i} clear of the button`)
			t.ok(apart(ax, ay, aw, ah, progress.x, progress.y, progress.w, progress.h), `slot {i} clear of the arrow`)
			t.ok(ax + aw <= bar.x, `slot {i} left of the energy bar`)
			t.ok(ay > (panel.status :: any).y + 8, `slot {i} below the status line`)
			t.ok(ay + ah <= panel.height, `slot {i} inside the panel`)
		end
		for _, input in INPUTS do
			t.ok(spots[input.slot][1] + 17 < progress.x, "the inputs before the arrow")
		end
		local line = panel.status :: any
		t.ok(line.x == 8 and line.y == 20, "the status line above the row")
		t.eq(#panel.buttons, 1)
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
		local states = {
			[NO_POWER] = "No power",
			[OUTPUT_FULL] = "Output full",
			[NO_INPUT] = "No input",
			[noInput(1)] = "No brass",
			[noInput(2)] = "No lead",
			[noInput(4)] = "No gunpowder",
			[noInput(6)] = "No lead or gunpowder",
		}
		for state, text in states do
			facts.state = state
			t.eq(WailaInfo.text(WailaInfo.machineLines(PRESS, facts)[2]), text)
		end
		facts.state, facts.rate, facts.active = IDLE, -USE, true
		t.eq(WailaInfo.text(WailaInfo.machineLines(PRESS, facts)[2]), "Using 50 J/t")
		t.eq(WailaInfo.text(WailaInfo.machineDetails(PRESS, facts)[1]), "Machine press (consumer)")
		-- The panel's status line says the same as WAILA.
		fill(container, 2, 0, 0)
		tick(container)
		t.eq(MenuLayout.statusText(container), "No lead or gunpowder")
		-- F3's menu line counts the six slots.
		local menu: string? = nil
		for _, text in WailaInfo.texts(WailaInfo.block(PRESS, nil, 0, 64, 0, true, nil)) do
			if string.sub(text, 1, 5) == "Menu " then
				menu = text
			end
		end
		t.eq(menu, "Menu Machine, 6 slots")
	end)
end

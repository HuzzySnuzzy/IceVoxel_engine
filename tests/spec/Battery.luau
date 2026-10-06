--[[
	Mekanism's Energy Cubes, named Batteries (Shared/Machines/Kinds/Battery, BlockList
	BasicBattery .. UltimateBattery): the blocks and Mekanism's EnergyCubeTier numbers, stacking to
	one, the recipes and a tier upgrade keeping the charge (Crafting `keep`), backup power end to
	end through the server's machines (a Heat Generator running out of fuel and a Solar Panel at
	night, an Electric Furnace kept smelting, the battery charging again when power returns, energy
	conserved to the quantum, and the same worlds without the battery stopping), the charge limits
	(rates in and out, capacity, cables' throughput, batteries never charging each other), the
	charge kept in the item (break, tooltip, the item's energy bar, place, tier upgrade), the
	status, panel lines and WAILA, and the decor with its charge gauges.
]]

return function(t, shared, require, server, client)
	local Blocks = require(shared.Blocks)
	local Coords = require(shared.World.Coords)
	local Crafting = require(shared.Crafting)
	local DayCycle = require(shared.DayCycle)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local Menu = require(shared.Inventory.Menu)
	local Protocol = require(shared.Net.Protocol)
	local Transmitters = require(shared.Transmitters)
	local Types = require(shared.Inventory.Types)
	local Containers = require(server.Players.Containers)
	local EditRules = require(server.Network.EditRules)
	local MachineWorld = require(server.Machines.MachineWorld)
	local TransmitterWorld = require(server.Transmitters.TransmitterWorld)
	local BlockDecor = require(client.Rendering.BlockDecor)
	local TransmitterModel = require(client.Rendering.TransmitterModel)
	local MenuLayout = require(client.Ui.MenuLayout)
	local WailaInfo = require(client.Ui.WailaInfo)

	local B = Blocks.id
	local I = Items.id
	local AIR = B.Air
	local Y = 64
	local ENERGY, INPUT, OUTPUT, RATE = Machines.ENERGY, Machines.INPUT, Machines.OUTPUT, Machines.RATE
	local TIER_NAMES = { "Basic", "Advanced", "Elite", "Ultimate" }
	local BATTERIES = {}
	for tier, name in TIER_NAMES do
		BATTERIES[tier] = B[`{name}Battery`]
	end
	local BASIC = BATTERIES[1]
	local FURNACE = B.ElectricFurnace
	-- Mekanism's EnergyCubeTier: J stored and J/t in and out.
	local CAPACITY = { 4e6, 16e6, 64e6, 256e6 }
	local RATES = { 4000, 16000, 64000, 256000 }
	-- An Electric Furnace's numbers: J a tick of work, its store, ticks an item.
	local USE, FURNACE_STORE, ITEM_TICKS = 50, 20000, 200

	local function S(item: number, count: number, data: any?)
		return { item = item, count = count, data = data }
	end

	local function charged(joules: number)
		return table.freeze({ energy = joules })
	end

	-- Machines in a world of blocks, ticked as the server does, at the day time `self.time`.
	local function sim()
		local blocks: { [number]: number } = {}
		local containers = Containers.new()
		local function getBlock(x: number, y: number, z: number): number?
			return blocks[Coords.posKey(x, y, z)] or AIR
		end
		local self: any = { time = 6000 }
		local cables = TransmitterWorld.new({ getBlock = getBlock, containers = containers })
		local world = MachineWorld.new({
			getBlock = getBlock,
			containers = containers,
			transmitters = cables,
			dayTime = function()
				return self.time
			end,
		})
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

	local function status(container: any): string?
		return Machines.status(container.block, Machines.view(container))
	end

	-- WAILA's status line of a machine from its record, after the record crossed the wire.
	local function wailaStatus(block: number, record: any): string
		local sent = (Protocol.decodeMachines(Protocol.encodeMachines({ record })) :: any)[1]
		local facts: WailaInfo.MachineFacts = {
			energy = sent.energy,
			capacity = sent.capacity,
			input = sent.input,
			output = sent.output,
			rate = sent.rate,
			active = sent.active,
			state = sent.state,
		}
		return WailaInfo.text(WailaInfo.machineLines(block, facts)[2])
	end

	--[[ The blocks ]]

	t.test("battery: four tiers with Mekanism's Energy Cube numbers, storage that stacks to one", function()
		for tier, block in BATTERIES do
			local name = TIER_NAMES[tier]
			local def = Blocks.get(block)
			t.eq(Items.displayName(block), `{name} Battery`)
			t.eq(def.hardness, 3.5, "Mekanism's machine blocks'")
			t.eq(def.tool, "pickaxe")
			t.eq(def.toolLevel, 0)
			t.eq(def.sound, "metal")
			t.eq(def.menu, "Machine")
			t.eq(def.decor, `{name}Battery`)
			t.eq(Items.drops(block, nil), nil, "a pickaxe is needed for it to drop")
			t.eq((Items.drops(block, I.WoodenPickaxe) :: any).item, block)
			t.eq(Items.maxStack(block), 1, "its charge is in each item")
			t.eq(def.maxStack, 1)
			t.ok(Machines.isMachine(block))
			t.eq((Machines.kindOf(block) :: any).name, "battery")
			t.eq(Machines.role(block), "storage", "the backup")
			local energy = Machines.energyOf(block) :: any
			t.eq(energy.capacity, CAPACITY[tier])
			t.eq(energy.input, RATES[tier], "in as fast as out")
			t.eq(energy.output, RATES[tier])
			t.eq(Transmitters.TIERS[tier].batteryCapacity, CAPACITY[tier])
			t.eq(Transmitters.TIERS[tier].batteryRate, RATES[tier])
			t.eq(Machines.containerSize(block), 0, "no slots")
			t.ok(Transmitters.isEnergyAcceptor(block), "cables connect to it")
			t.ok(not Transmitters.isItemAcceptor(block), "transporters don't")
			local container = Machines.newContainer(block)
			t.eq(Machines.capacity(container), CAPACITY[tier])
			t.eq(Machines.energy(container), 0)
			local input, output = Machines.rates(container)
			t.eq(input, RATES[tier])
			t.eq(output, RATES[tier])
		end
		-- Other blocks still stack to 64.
		t.eq(Items.maxStack(B.Dirt), 64)
		t.eq(Items.maxStack(B.HeatGenerator), 64)
		t.eq(Blocks.get(B.Dirt).maxStack, 64)
		-- Two batteries with different charges never stack, as any data.
		t.ok(not Items.stacksMatch(S(BASIC, 1, charged(5)), S(BASIC, 1, charged(6))))
		t.ok(not Items.stacksMatch(S(BASIC, 1, charged(5)), S(BASIC, 1)))
		t.ok(Items.stacksMatch(S(BASIC, 1, charged(5)), S(BASIC, 1, charged(5))))
		-- Menu holds one a slot.
		local w = Types.newWindow(Types.newInventory())
		t.eq(Menu.maxStackFor(w, Menu.windowIndex(w, "inventory", 1), BASIC), 1)
	end)

	--[[ Recipes ]]

	local function grid(rows: { { number } }, centre: any?): { [number]: any }
		local cells = {}
		for row = 1, 3 do
			for column = 1, 3 do
				local item = rows[row][column]
				local slot = (row - 1) * 3 + column
				cells[slot] = if slot == 5 and centre then centre else S(item, 1)
			end
		end
		return cells
	end

	t.test("battery: Mekanism's energy cube recipes; a tier upgrade keeps the charge", function()
		local D, T, Fe, Au, Os = I.GlowDust, I.GlowBlock, I.IronIngot, I.GoldIngot, I.OsmiumIngot
		local basic = Crafting.match(grid({ { D, T, D }, { Fe, I.IronBlock, Fe }, { D, T, D } }), 3) :: any
		t.eq(basic.item, BASIC)
		t.eq(basic.count, 1)
		t.eq(basic.data, nil, "a new battery is empty")
		local tiers = {
			{ alloy = Au, ingot = Os },
			{ alloy = I.Diamond, ingot = Au },
			{ alloy = I.Emerald, ingot = I.Diamond },
		}
		for i, parts in tiers do
			local below, result = BATTERIES[i], BATTERIES[i + 1]
			local A, In = parts.alloy, parts.ingot
			local rows = { { A, T, A }, { In, below, In }, { A, T, A } }
			local empty = Crafting.match(grid(rows), 3) :: any
			t.eq(empty.item, result, `{TIER_NAMES[i + 1]} from a {TIER_NAMES[i]}`)
			t.eq(empty.data, nil, "an empty battery makes an empty one")
			local full = Crafting.match(grid(rows, S(below, 1, charged(CAPACITY[i]))), 3) :: any
			t.eq(full.item, result)
			t.eq(full.data.energy, CAPACITY[i], "the charge goes with it (Mekanism's MekDataShapedRecipe)")
			t.ok(table.isfrozen(full.data), "the result's data is a value")
		end
		-- In a 3 x 3 window: taking the result crafts it, with the charge, onto the cursor.
		local window = Types.newWindow(Types.newInventory())
		window.id = 1
		window.container = Types.newCrafting("crafting", B.CraftingTable)
		local rows = { { Au, T, Au }, { Os, BASIC, Os }, { Au, T, Au } }
		for slot, stack in grid(rows, S(BASIC, 1, charged(1234567))) do
			window.container.slots[Types.CRAFT_RESULT + slot] = stack
		end
		Menu.updateCraft(window)
		local result = window.container.slots[Types.CRAFT_RESULT] :: any
		t.eq(result.item, BATTERIES[2])
		t.eq(result.data.energy, 1234567)
		Menu.apply(
			window,
			{ kind = "click", window = 1, slot = Types.CRAFT_RESULT - 1, clickType = Menu.ClickType.Pickup, button = 0 },
			false
		)
		local cursor = window.inventory.cursor :: any
		t.eq(cursor.item, BATTERIES[2])
		t.eq(cursor.data.energy, 1234567, "taken with its charge")
		t.eq(window.container.slots[Types.CRAFT_RESULT + 5], nil, "the basic battery went into it")
		-- Other recipes still give no data, whatever their ingredients hold.
		local generator = Crafting.match({
			S(Fe, 1),
			S(Fe, 1),
			S(Fe, 1),
			S(B.Planks, 1),
			S(Os, 1),
			S(B.Planks, 1),
			S(Fe, 1),
			S(B.Furnace, 1, table.freeze({ tag = "x" })),
			S(Fe, 1),
		}, 3) :: any
		t.eq(generator.item, B.HeatGenerator)
		t.eq(generator.data, nil, "no keep: no data")
		-- Recipes compile with the kept cell where the pattern has it (shapeless: where the
		-- ingredient is listed, Tough As Nails' mint cures keeping the dirty water's wear).
		local kept, mixed = 0, 0
		for _, recipe in Crafting.recipes do
			if recipe.keep and recipe.kind == "shaped" then
				kept += 1
				t.eq(recipe.keep, 5, "the centre")
			elseif recipe.keep then
				mixed += 1
				t.eq(recipe.keep, 1, "the dirty water, listed first")
			end
		end
		t.eq(kept, 3, "the three tier upgrades")
		t.eq(mixed, 3, "the three mint cures (bottle, bowl, canteen)")
	end)

	t.test("battery: a tier upgrade keeps the charge however the result is taken", function()
		-- Shift click (crafts into the inventory), Q (throws it) and a number key (into the
		-- hotbar): each is a copy of the result, so each keeps the charge, and the battery in
		-- the grid is used up: one battery in, one out.
		local Au, Os, T = I.GoldIngot, I.OsmiumIngot, I.GlowBlock
		local rows = { { Au, T, Au }, { Os, BASIC, Os }, { Au, T, Au } }
		local function table3(energy: number)
			local window = Types.newWindow(Types.newInventory())
			window.id = 1
			window.container = Types.newCrafting("crafting", B.CraftingTable)
			for slot, stack in grid(rows, S(BASIC, 1, charged(energy))) do
				window.container.slots[Types.CRAFT_RESULT + slot] = stack
			end
			Menu.updateCraft(window)
			return window
		end
		local function click(window: any, clickType: number, button: number): { any }
			return Menu.apply(
				window,
				{ kind = "click", window = 1, slot = Types.CRAFT_RESULT - 1, clickType = clickType, button = button },
				false
			)
		end
		local function advanced(window: any): { any }
			local found = {}
			for _, stack in window.inventory.slots do
				if stack and stack.item == BATTERIES[2] then
					table.insert(found, stack)
				end
			end
			return found
		end
		local shifted = table3(4321)
		t.eq(#click(shifted, Menu.ClickType.QuickMove, 0), 0, "nothing thrown")
		local moved = advanced(shifted)
		t.eq(#moved, 1, "one Advanced Battery from one Basic Battery")
		t.eq(moved[1].count, 1)
		t.eq(moved[1].data.energy, 4321, "shift click keeps the charge")
		t.eq(shifted.container.slots[Types.CRAFT_RESULT + 5], nil, "the Basic Battery went into it")
		t.eq(shifted.container.slots[Types.CRAFT_RESULT], nil, "no second result")
		local thrown = click(table3(8765), Menu.ClickType.Throw, 0)
		t.eq(#thrown, 1)
		t.eq(thrown[1].item, BATTERIES[2])
		t.eq(thrown[1].data.energy, 8765, "Q keeps the charge")
		local swapped = table3(2468)
		click(swapped, Menu.ClickType.Swap, 0)
		local hotbar = swapped.inventory.slots[1] :: any
		t.eq(hotbar.item, BATTERIES[2])
		t.eq(hotbar.data.energy, 2468, "a number key keeps the charge")
	end)

	--[[ Backup power, end to end ]]

	t.test("battery: a Heat Generator runs out of fuel, the battery keeps an Electric Furnace going", function()
		-- Generator - cable - Electric Furnace, a Basic Battery on the cable. One coal, 64
		-- cobblestone.
		local function build(withBattery: boolean)
			local s = sim()
			s.set(0, Y, 0, B.HeatGenerator)
			s.set(1, Y, 0, B.BasicUniversalCable)
			s.set(2, Y, 0, FURNACE)
			if withBattery then
				s.set(1, Y, 1, BASIC)
			end
			s.container(0, Y, 0).slots[1] = S(I.Coal, 1)
			s.container(2, Y, 0).slots[1] = S(B.Cobblestone, 64)
			return s
		end
		local s = build(true)
		local generator, furnace, battery = s.container(0, Y, 0), s.container(2, Y, 0), s.container(1, Y, 1)
		local worked = 0
		local function step(n: number)
			for _ = 1, n do
				s.step()
				if furnace.data[RATE] < 0 then
					worked += 1
				end
			end
		end
		local function total(): number
			return Machines.energy(generator) + Machines.energy(furnace) + Machines.energy(battery)
		end
		-- The coal burns for 1 600 ticks at 200 J/t: the furnace fills first, then takes its 50 J/t
		-- and the other 150 J/t charge the battery, so the generator never fills and never slows.
		step(200)
		t.eq(Machines.energy(furnace), FURNACE_STORE, "the furnace filled first")
		t.eq(status(battery), "Charging 150 J/t", "the surplus charges the battery")
		t.eq(wailaStatus(BASIC, s.record(1, Y, 1)), "Charging 150 J/t", "WAILA says so from the record")
		t.eq(Machines.energy(generator), 0, "it gives all it makes")
		step(1400)
		t.eq(Machines.get(generator, "burnTime"), 0, "the coal is burnt out")
		t.eq(generator.slots[1], nil)
		local made = 1600 * 200
		t.eq(worked, 1599, "the furnace worked every tick from the second")
		t.eq(total() + worked * USE, made, "energy made = stored + used, exactly")
		t.eq(Machines.energy(battery), made - FURNACE_STORE - worked * USE, "the rest is in the battery")
		local stored = Machines.energy(battery)
		-- The outage: no fuel. For 2 000 ticks (five times what the furnace's own store lasts) the
		-- battery covers the furnace's 50 J/t; it never stops.
		local stops = 0
		for _ = 1, 2000 do
			step(1)
			if status(furnace) ~= "Using 50 J/t" then
				stops += 1
			end
		end
		t.eq(stops, 0, "the furnace never stopped")
		t.eq(status(generator), "Idle")
		t.eq(Machines.energy(generator), 0)
		t.eq(Machines.energy(furnace), FURNACE_STORE, "topped up every tick")
		t.eq(Machines.energy(battery), stored - 2000 * USE, "on the battery, 50 J/t")
		t.eq(status(battery), "Discharging 50 J/t")
		t.eq(battery.data[OUTPUT], USE)
		t.eq(wailaStatus(BASIC, s.record(1, Y, 1)), "Discharging 50 J/t")
		t.eq(wailaStatus(FURNACE, s.record(2, Y, 0)), "Using 50 J/t")
		t.eq(worked, 3599)
		t.eq((furnace.slots[2] :: any).count, worked // ITEM_TICKS, "17 smelted")
		t.eq(Machines.get(furnace, "progress"), worked % ITEM_TICKS)
		-- Power returns: another coal. The battery charges again at once, the furnace goes on.
		local low = Machines.energy(battery)
		generator.slots[1] = S(I.Coal, 1)
		step(100)
		t.eq(Machines.energy(battery), low + 100 * 150, "charging 150 J/t again")
		t.eq(status(battery), "Charging 150 J/t")
		t.eq(battery.data[INPUT], 150)
		t.eq(status(furnace), "Using 50 J/t")
		t.eq(total() + worked * USE, 2 * made - 1500 * 200, "still exact, 100 ticks into the second coal")
		-- The same world without the battery: once the coal is out, the furnace's own 20 kJ last
		-- 400 ticks and it stops.
		local u = build(true)
		u.step(1600)
		u.set(1, Y, 1, AIR)
		local alone = u.container(2, Y, 0)
		u.step(400)
		t.eq(Machines.status(FURNACE, Machines.view(alone)), "Using 50 J/t", "its last 50 J")
		t.eq(Machines.energy(alone), 0)
		u.step()
		t.eq(Machines.status(FURNACE, Machines.view(alone)), "No power", "without the battery it stops")
	end)

	t.test("battery: a Solar Panel charges it by day, it runs an Electric Furnace through the night", function()
		-- A panel with 8 Speed Upgrades (500 J/t in full sun) - cable - Electric Furnace, a Basic
		-- Battery on the cable, from mid afternoon to the next morning. The furnace is kept fed and
		-- emptied, as a player or transporters would.
		-- (Minecraft's day, DayCycle.isDay: up to tick 12 540 and from 23 460; the night between.)
		local START, DUSK, MIDNIGHT, SUNRISE, MORNING = 9000, 12540, 18000, 23460, 24000 + 2000
		local function build(withBattery: boolean)
			local s = sim()
			s.time = START
			s.set(0, Y, 0, B.SolarPanel)
			s.set(1, Y, 0, B.BasicUniversalCable)
			s.set(2, Y, 0, FURNACE)
			if withBattery then
				s.set(1, Y, 1, BASIC)
			end
			s.container(0, Y, 0).slots[1] = S(I.SpeedUpgrade, 8)
			return s
		end
		local function run(s: any, stop: number, each: ((number) -> ())?): (number, number)
			local panel, furnace = s.container(0, Y, 0), s.container(2, Y, 0)
			local made, used = 0, 0
			while s.time < stop do
				s.time += 1
				-- (Minecraft's day time wraps at 24 000.)
				local saved = s.time
				s.time = saved % DayCycle.TICKS_PER_DAY
				s.step()
				s.time = saved
				made += panel.data[RATE]
				used -= furnace.data[RATE]
				if furnace.slots[2] then
					furnace.slots[2] = nil
				end
				local input = furnace.slots[1]
				if input == nil or input.count < 32 then
					furnace.slots[1] = S(B.Cobblestone, 64)
				end
				if each then
					each(s.time)
				end
			end
			return made, used
		end
		local s = build(true)
		local panel, furnace, battery = s.container(0, Y, 0), s.container(2, Y, 0), s.container(1, Y, 1)
		local made, used = run(s, DUSK)
		local low = Machines.quantise(500 * DayCycle.sunBrightness(DUSK))
		t.ok(low < 250, "the sun is low")
		t.eq(status(panel), `Producing {Items.formatEnergy(low)}/t`)
		local atDusk = Machines.energy(battery)
		t.ok(atDusk > 1e6, `the battery charged by day: {atDusk}`)
		t.eq(status(furnace), "Using 50 J/t")
		-- The night: the panel makes nothing, the battery runs the furnace.
		local stops = 0
		local function watch()
			if status(furnace) ~= "Using 50 J/t" then
				stops += 1
			end
		end
		local nightMade, nightUsed = run(s, MIDNIGHT, watch)
		t.eq(status(panel), "Night")
		t.eq(status(battery), "Discharging 50 J/t")
		t.eq(wailaStatus(BASIC, s.record(1, Y, 1)), "Discharging 50 J/t")
		local lateMade, lateUsed = run(s, SUNRISE - 1, watch)
		t.ok(not DayCycle.isDay(SUNRISE - 1) and DayCycle.isDay(SUNRISE), "the last tick of the night")
		t.eq(nightMade + lateMade, 0, "nothing made all night")
		t.eq(stops, 0, "the furnace never stopped all night")
		local nightTicks = SUNRISE - 1 - DUSK
		t.eq(nightTicks, 10919)
		t.eq(nightUsed + lateUsed, nightTicks * USE)
		t.eq(Machines.energy(furnace), FURNACE_STORE, "kept full")
		local atDawn = Machines.energy(battery)
		t.eq(atDawn, atDusk - nightTicks * USE, "the battery gave exactly what the furnace used")
		made += nightMade + lateMade
		used += nightUsed + lateUsed
		-- Morning: the sun charges the battery again (the panel makes 500 J/t in full sun from
		-- tick 730; the furnace takes 50).
		local dawnMade, dawnUsed = run(s, MORNING, watch)
		made += dawnMade
		used += dawnUsed
		t.eq(stops, 0)
		t.eq(status(panel), "Producing 500 J/t")
		t.eq(status(battery), "Charging 450 J/t")
		t.eq(battery.data[INPUT], 450)
		t.ok(Machines.energy(battery) > atDawn + 500000, "charging again")
		local total = Machines.energy(panel) + Machines.energy(furnace) + Machines.energy(battery)
		t.eq(total + used, made, "energy made = stored + used, exactly")
		-- Without the battery the furnace runs out in the night (the panel's and its own stores
		-- last a little over two thousand ticks).
		local u = build(false)
		run(u, MIDNIGHT)
		t.eq(status(u.container(2, Y, 0)), "No power", "without the battery it stops")
		t.eq(Machines.energy(u.container(0, Y, 0)), 0)
	end)

	--[[ Limits ]]

	t.test("battery: at most its rate in and out a tick, never over its capacity", function()
		-- A Creative Energy Cube fills a Basic Battery at 4 kJ/t, to 4 MJ exactly.
		local s = sim()
		s.set(0, Y, 0, B.CreativeEnergyCube)
		s.set(1, Y, 0, BASIC)
		local battery = s.container(1, Y, 0)
		s.step()
		t.eq(Machines.energy(battery), 4000, "its input rate")
		t.eq(battery.data[INPUT], 4000)
		t.eq(status(battery), "Charging 4 kJ/t")
		s.step(999)
		t.eq(Machines.energy(battery), 4e6, "full")
		s.step(10)
		t.eq(Machines.energy(battery), 4e6, "and no more")
		t.eq(battery.data[INPUT], 0)
		t.eq(status(battery), "Full")
		-- Every tier's rate, by touching.
		for tier = 2, 4 do
			local c = sim()
			c.set(0, Y, 0, B.CreativeEnergyCube)
			c.set(0, Y + 1, 0, BATTERIES[tier])
			c.step()
			t.eq(Machines.energy(c.container(0, Y + 1, 0)), RATES[tier], `{TIER_NAMES[tier]}: {RATES[tier]} J/t`)
		end
		-- Behind a Basic Universal Cable an Ultimate Battery charges at the cable's 8 kJ/t.
		local d = sim()
		d.set(0, Y, 0, B.CreativeEnergyCube)
		d.set(1, Y, 0, B.BasicUniversalCable)
		d.set(2, Y, 0, BATTERIES[4])
		d.step()
		t.eq(Machines.energy(d.container(2, Y, 0)), 8000, "the cable's throughput")
		-- A full battery gives at most its rate, shared evenly between three furnaces.
		local e = sim()
		e.set(0, Y, 0, BASIC)
		e.set(1, Y, 0, FURNACE)
		e.set(-1, Y, 0, FURNACE)
		e.set(0, Y, 1, FURNACE)
		local full = e.container(0, Y, 0)
		full.data[ENERGY] = 4e6
		e.step()
		t.eq(Machines.energy(full), 4e6 - 4000, "4 kJ/t out")
		local given = 0
		for _, at in { { 1, 0 }, { -1, 0 }, { 0, 1 } } do
			local got = Machines.energy(e.container(at[1], Y, at[2]))
			t.ok(math.abs(got - 4000 / 3) <= Machines.QUANTUM, `an even share: {got}`)
			given += got
		end
		t.eq(given, 4000, "exactly what it gave")
		t.eq(status(full), "Discharging 4 kJ/t")
		-- Batteries never charge each other.
		local f = sim()
		f.set(0, Y, 0, BASIC)
		f.set(1, Y, 0, BASIC)
		f.container(0, Y, 0).data[ENERGY] = 1e6
		f.step(5)
		t.eq(Machines.energy(f.container(0, Y, 0)), 1e6)
		t.eq(Machines.energy(f.container(1, Y, 0)), 0)
		t.eq(status(f.container(1, Y, 0)), "Empty")
		t.eq(status(f.container(0, Y, 0)), "Idle")
	end)

	--[[ The item keeps the charge ]]

	t.test("battery: keeps its charge in its item: tooltip, energy bar, placing, tier upgrade", function()
		local s = sim()
		local registry = EditRules.newBlockData()
		registry:add(TransmitterWorld.blockDataHooks(s.cables))
		registry:add(MachineWorld.blockDataHooks(s.world))
		s.set(0, Y, 0, BASIC)
		s.container(0, Y, 0).data[ENERGY] = 1234567
		local drop = EditRules.breakDrop(registry, 0, Y, 0, BASIC, false, I.IronPickaxe) :: any
		s.set(0, Y, 0, AIR)
		t.eq(drop.item, BASIC)
		t.eq(drop.count, 1)
		t.eq(drop.data.energy, 1234567)
		t.eq(Items.describe(drop)[1], "Energy: 1.23 MJ")
		t.eq(EditRules.breakDrop(registry, 0, Y, 0, BASIC, true, I.IronPickaxe), nil, "creative drops nothing")
		-- The item's energy bar, where a tool's durability bar goes.
		local width, colour = MenuLayout.energyItemBar(BASIC, drop.data)
		t.eq(width, 4, "13 x 1.23 / 4 pixels")
		t.eq(table.concat(colour, ","), table.concat(Machines.energyColour(1234567 / 4e6), ","))
		t.eq((MenuLayout.energyItemBar(BASIC, charged(4e6))), 13, "full")
		t.eq((MenuLayout.energyItemBar(BASIC, charged(4e6 - 1))), 12, "full only when full")
		t.eq((MenuLayout.energyItemBar(BASIC, charged(1))), 1, "never empty while it holds any")
		t.eq((MenuLayout.energyItemBar(BASIC, nil)), nil, "an empty battery shows no bar")
		t.eq((MenuLayout.energyItemBar(BASIC, charged(0))), nil)
		t.eq((MenuLayout.energyItemBar(B.HeatGenerator, charged(80000))), 6, "other machines' items too")
		t.eq((MenuLayout.energyItemBar(B.HeatGenerator, nil)), nil, "but only with energy")
		t.eq((MenuLayout.energyItemBar(B.CreativeEnergyCube, nil)), nil)
		t.eq((MenuLayout.energyItemBar(B.Stone, nil)), nil)
		t.eq((MenuLayout.energyItemBar(I.IronPickaxe, nil)), nil)
		t.eq((MenuLayout.energyItemBar(nil, nil)), nil)
		t.eq(MenuLayout.energyColour, Machines.energyColour, "the panels' bar's colours")
		-- Placed again it has its charge back, and works.
		s.set(3, Y, 0, BASIC)
		registry:placed("p", 3, Y, 0, BASIC, drop)
		local placed = s.container(3, Y, 0)
		t.eq(Machines.energy(placed), 1234567)
		s.set(4, Y, 0, FURNACE)
		s.step()
		t.eq(Machines.energy(placed), 1234567 - 4000, "covering the furnace's store at its rate")
		-- At most its capacity (creative may give an item any valid data).
		s.set(5, Y, 5, BASIC)
		registry:placed("p", 5, Y, 5, BASIC, S(BASIC, 1, charged(1e12)))
		t.eq(Machines.energy(s.container(5, Y, 5)), 4e6)
		-- An empty one drops a plain item.
		s.set(6, Y, 6, BASIC)
		local plain = EditRules.breakDrop(registry, 6, Y, 6, BASIC, false, I.IronPickaxe) :: any
		t.eq(plain.data, nil)
		t.eq(#Items.describe(plain), 0)
		-- Broken, crafted into an Advanced Battery and placed: the same charge.
		local rows = {
			{ I.GoldIngot, I.GlowBlock, I.GoldIngot },
			{ I.OsmiumIngot, BASIC, I.OsmiumIngot },
			{ I.GoldIngot, I.GlowBlock, I.GoldIngot },
		}
		local upgraded = Crafting.match(grid(rows, drop), 3) :: any
		t.eq(upgraded.item, BATTERIES[2])
		s.set(7, Y, 7, BATTERIES[2])
		registry:placed("p", 7, Y, 7, BATTERIES[2], upgraded)
		t.eq(Machines.energy(s.container(7, Y, 7)), 1234567, "kept through the upgrade")
		t.eq((MenuLayout.energyItemBar(BATTERIES[2], upgraded.data)), 1, "a small share of 16 MJ")
	end)

	--[[ What players see ]]

	t.test("battery: its status, panel lines and WAILA lines", function()
		local container: any = Machines.newContainer(BASIC)
		local function lines(): string
			return table.concat(MenuLayout.lineTexts(container), " | ")
		end
		t.eq(status(container), "Empty")
		t.eq(MenuLayout.statusText(container), "Empty")
		t.eq(lines(), "Input: 0 J/t | Output: 0 J/t | Max rate: 4 kJ/t")
		container.data[ENERGY] = 2e6
		t.eq(status(container), "Idle")
		container.data[INPUT] = 150
		t.eq(status(container), "Charging 150 J/t")
		t.eq(lines(), "Input: 150 J/t | Output: 0 J/t | Max rate: 4 kJ/t")
		container.data[INPUT], container.data[OUTPUT] = 0, 1200
		t.eq(status(container), "Discharging 1.2 kJ/t")
		t.eq(lines(), "Input: 0 J/t | Output: 1.2 kJ/t | Max rate: 4 kJ/t")
		container.data[OUTPUT] = 0
		container.data[ENERGY] = 4e6
		t.eq(status(container), "Full")
		local ultimate: any = Machines.newContainer(BATTERIES[4])
		t.eq(MenuLayout.lineTexts(ultimate)[3], "Max rate: 256 kJ/t")
		-- Other machines have no lines.
		t.eq(#MenuLayout.lineTexts(Machines.newContainer(B.HeatGenerator)), 0)
		t.eq(#MenuLayout.lineTexts(nil), 0)
		-- The panel: no slots, the status line, the lines under it and the energy bar.
		local panel = MenuLayout.panel(container)
		t.eq(panel.title, "Basic Battery")
		t.eq(#panel.slots, 0)
		local at = panel.status :: any
		t.eq(at.x, 8)
		t.eq(at.y, 20)
		t.eq(#panel.lines, 3, "as many as fit the panel")
		t.eq(panel.lines[1].x, 8)
		t.eq(panel.lines[1].y, 34)
		t.eq(panel.lines[2].y, 34 + MenuLayout.LINE_HEIGHT)
		t.ok(panel.lines[3].y + MenuLayout.LINE_TEXT <= panel.height - MenuLayout.LINE_MARGIN, "inside it")
		local energy = panel.energy :: any
		t.eq(energy.x, 164, "Mekanism's power bar")
		t.eq(MenuLayout.energyTooltip(container.data), "4 MJ / 4 MJ")
		t.eq(#MenuLayout.panel(Machines.newContainer(B.HeatGenerator)).lines, 0, "no lines: no labels")
		-- WAILA: energy and the status, from the record (no window needed).
		local facts = WailaInfo.machineDefaults(BASIC)
		t.eq(WailaInfo.text(WailaInfo.machineLines(BASIC, facts)[1]), "Energy: 0 J / 4 MJ")
		t.eq(WailaInfo.text(WailaInfo.machineLines(BASIC, facts)[2]), "Empty", "no record yet")
		facts.energy, facts.output = 3.5e6, 300
		t.eq(WailaInfo.text(WailaInfo.machineLines(BASIC, facts)[1]), "Energy: 3.5 MJ / 4 MJ")
		t.eq(WailaInfo.text(WailaInfo.machineLines(BASIC, facts)[2]), "Discharging 300 J/t")
		local details = WailaInfo.machineDetails(BASIC, facts)
		t.eq(WailaInfo.text(details[1]), "Machine battery (storage)")
		t.eq(WailaInfo.text(details[2]), "Holds 4 MJ, in 4 kJ/t, out 4 kJ/t")
		-- A kind's lines are kept to MAX_LINES strings, and a failing one gives none.
		local many = Machines.kind("test_many_lines")
			or Machines.define("test_many_lines", {
				lines = function(): { string }
					return { "a", "", "b", "c", "d", "e" }
				end,
			})
		local failing = Machines.kind("test_failing_lines")
			or Machines.define("test_failing_lines", {
				lines = function(): { string }
					error("no lines")
				end,
			})
		t.ok(many and failing)
		local undo = Machines.bind(B.IronBlock, "test_many_lines", { capacity = 10, input = 1 })
		local ok, err = pcall(function()
			local view = Machines.view(Machines.newContainer(B.IronBlock))
			t.eq(table.concat(Machines.lines(B.IronBlock, view), ""), "abcd", "empty lines dropped, at most 4")
			local undoFailing = Machines.bind(B.IronBlock, "test_failing_lines", { capacity = 10, input = 1 })
			t.eq(#Machines.lines(B.IronBlock, view), 0)
			undoFailing()
		end)
		undo()
		assert(ok, err)
	end)

	t.test("battery: tier-coloured corners, and gauges that fill with its charge", function()
		local gauge = BlockDecor.BATTERY_GAUGE
		for tier, block in BATTERIES do
			local faces = BlockDecor.faces(`{TIER_NAMES[tier]}Battery`) :: any
			t.ok(faces ~= nil, "decor")
			local colour = table.concat(Transmitters.TIERS[tier].colour, ",")
			for _, face in BlockDecor.FACES do
				local corners = 0
				for _, r in faces[face] do
					if table.concat(r.colour, ",") == colour and r.w == 3 and r.h == 3 then
						corners += 1
					end
				end
				t.eq(corners, 4, `{face}: corners in the tier's colour`)
			end
			for _, face in { "Front", "Back", "Left", "Right" } do
				local found = false
				for _, r in faces[face] do
					if r.x == gauge.x and r.y == gauge.y and r.w == gauge.w and r.h == gauge.h then
						found = true
					end
				end
				t.ok(found, `{face}: the gauge`)
			end
			local parts = BlockDecor.partCount(`{TIER_NAMES[tier]}Battery`)
			t.ok(parts > 0 and parts < 40, `item model slabs: {parts}`)
			t.ok(TransmitterModel.hasMachineBoxes(block), "a cell of TransmitterRenderer's")
		end
		-- Empty or no record: dark gauges.
		local none, empty = TransmitterModel.machineBoxes(BASIC, nil)
		t.eq(#none, 0)
		local zero, zeroSignature = TransmitterModel.machineBoxes(BASIC, { active = false, energy = 0, capacity = 4e6 })
		t.eq(#zero, 0)
		t.eq(zeroSignature, empty)
		-- Rows: never empty while it holds any, full only when full.
		local function rows(energy: number): number
			return TransmitterModel.chargeRows({ active = false, energy = energy, capacity = 4e6 }, gauge.h)
		end
		t.eq(rows(1), 1)
		t.eq(rows(2e6), 5)
		t.eq(rows(4e6 - 1), 9)
		t.eq(rows(4e6), 10)
		t.eq(rows(9e9), 10)
		t.eq(TransmitterModel.chargeRows(nil, gauge.h), 0)
		t.eq(TransmitterModel.chargeRows({ active = false, energy = 0 / 0, capacity = 4e6 }, gauge.h), 0)
		-- Half full: a pane on each side over the gauge's lower half, in the energy bar's colour.
		local boxes, half = TransmitterModel.machineBoxes(BASIC, { active = false, energy = 2e6, capacity = 4e6 })
		t.eq(#boxes, 4, "a pane on each side")
		local depth = TransmitterModel.GLOW_DEPTH
		local sides: { [string]: boolean } = {}
		for _, box in boxes do
			t.eq(box.kind, "glow")
			t.eq(table.concat(box.colour, ","), table.concat(Machines.energyColour(0.5), ","))
			t.eq(box.size[2], 5, "five of ten rows")
			t.eq(box.offset[2], 8 - (gauge.y + gauge.h - 5 / 2), "from the gauge's bottom")
			local normalAxis = if box.size[1] == depth then 1 else 3
			local acrossAxis = 4 - normalAxis
			t.eq(box.size[acrossAxis], gauge.w)
			t.eq(math.abs(box.offset[normalAxis]), 8 + depth / 2, "out of the face")
			t.eq(box.offset[acrossAxis], 0, "the gauge is centred")
			sides[`{normalAxis}{if box.offset[normalAxis] > 0 then "+" else "-"}`] = true
		end
		t.ok(sides["1+"] and sides["1-"] and sides["3+"] and sides["3-"], "all four sides")
		-- The boxes change only when a whole row does.
		local _, nearlyHalf = TransmitterModel.machineBoxes(BASIC, { active = false, energy = 2.3e6, capacity = 4e6 })
		t.eq(nearlyHalf, half, "the same row: nothing to redraw")
		local fullBoxes, full = TransmitterModel.machineBoxes(BASIC, { active = true, energy = 4e6, capacity = 4e6 })
		t.ok(full ~= half)
		t.eq(fullBoxes[1].size[2], gauge.h)
		t.eq(table.concat(fullBoxes[1].colour, ","), "0,255,0", "green when full")
		local lowBoxes = TransmitterModel.machineBoxes(BASIC, { active = false, energy = 1, capacity = 4e6 })
		t.eq(table.concat(lowBoxes[1].colour, ","), table.concat(Machines.energyColour(0.1), ","), "red-ish")
		-- Records of charged batteries go with their chunk (not the default state), empty ones
		-- don't.
		local s = sim()
		s.set(0, Y, 0, BASIC)
		s.set(1, Y, 1, BASIC)
		s.container(0, Y, 0).data[ENERGY] = 1e6
		local records = MachineWorld.chunkRecords(s.world, 0, 0)
		t.eq(#records, 1)
		t.eq(records[1].energy, 1e6)
		t.eq(records[1].capacity, 4e6)
		-- The other machines' windows still light as before.
		t.ok(TransmitterModel.hasMachineBoxes(B.HeatGenerator))
		t.ok(not TransmitterModel.hasMachineBoxes(B.CreativeEnergyCube))
	end)
end

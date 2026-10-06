--[[
	The Oil Refinery (Shared/Machines/Kinds/Refinery, BlockList OilRefinery): the block and its
	numbers, its tanks (oil in, fuel out) under Mekanism's pipe and bucket rules, refining 10 mB a
	tick for 200 J (a bucket in 100 ticks for 20 kJ), what stops it (no oil, no room, no power) and
	what it does when it is short (refines what it can for that share of the energy), Speed and
	Energy Upgrades with Mekanism's maths, its active state held through short stops, sustained
	data, a creative cube powering it through the server's machines, its panel (gauges, arrow,
	status line, upgrade slots), WAILA's lines, the decor and the recipe.
]]

local FakeMachines = require("../lib/FakeMachines")

return function(t, shared, require, server, client)
	local Blocks = require(shared.Blocks)
	local Coords = require(shared.World.Coords)
	local Crafting = require(shared.Crafting)
	local Fluids = require(shared.Fluids)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local Smelting = require(shared.Crafting.Smelting)
	local Transmitters = require(shared.Transmitters)
	local Upgrades = require(shared.Machines.Upgrades)
	local Containers = require(server.Players.Containers)
	local MachineWorld = require(server.Machines.MachineWorld)
	local TransmitterWorld = require(server.Transmitters.TransmitterWorld)
	local BlockDecor = require(client.Rendering.BlockDecor)
	local MenuLayout = require(client.Ui.MenuLayout)
	local WailaInfo = require(client.Ui.WailaInfo)

	local B = Blocks.id
	local I = Items.id
	local AIR = B.Air
	local Y = 64
	local REFINERY = B.OilRefinery
	local ENERGY = Machines.ENERGY
	-- The contract's numbers: 10 mB a tick for 200 J, 10 000 mB tanks, a 40 kJ store.
	local RATE, USE, TANK, CAPACITY = 10, 200, 10000, 40000
	local OIL, FUEL = Fluids.OIL, Fluids.FUEL
	FakeMachines.define(Machines, Items, Smelting)

	local function S(item: number, count: number)
		return { item = item, count = count }
	end

	local function ctx(): any
		return {
			block = REFINERY,
			x = 0,
			y = Y,
			z = 0,
			energy = Machines.energyOf(REFINERY),
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

	-- A refinery with `oil` mB of oil and a full store.
	local function refinery(oil: number): any
		local c: any = Machines.newContainer(REFINERY)
		Machines.tankInsert(c, "oil", OIL, oil)
		c.data[ENERGY] = CAPACITY
		return c
	end

	local function status(c: any): string?
		return Machines.status(REFINERY, Machines.view(c))
	end

	--[[ The block ]]

	t.test("oil refinery: the block, its kind, its tanks and numbers", function()
		local def = Blocks.get(REFINERY)
		t.eq(Items.displayName(REFINERY), "Oil Refinery")
		t.eq(def.hardness, 3.5, "Mekanism's machines")
		t.eq(def.tool, "pickaxe")
		t.eq(def.toolLevel, 0)
		t.eq(def.sound, "metal")
		t.eq(def.decor, "OilRefinery")
		t.eq(def.menu, "Machine")
		t.eq(Items.drops(REFINERY, nil), nil, "a pickaxe is needed for it to drop")
		t.eq((Items.drops(REFINERY, I.WoodenPickaxe) :: any).item, REFINERY)
		t.ok(Machines.isMachine(REFINERY))
		t.eq((Machines.kindOf(REFINERY) :: any).name, "refinery")
		t.eq(Machines.role(REFINERY), "consumer")
		local energy = Machines.energyOf(REFINERY) :: any
		t.eq(energy.capacity, CAPACITY)
		t.eq(energy.input, CAPACITY)
		t.eq(energy.output, nil)
		t.ok(Transmitters.isEnergyAcceptor(REFINERY), "cables connect to it")
		t.ok(not Transmitters.isItemAcceptor(REFINERY), "only upgrade slots: no transporter")
		t.eq(Machines.containerSize(REFINERY), 2)
		t.ok(Machines.mayPlace(REFINERY, 1, I.SpeedUpgrade))
		t.ok(Machines.mayPlace(REFINERY, 2, I.EnergyUpgrade))
		t.ok(not Machines.mayPlace(REFINERY, 1, I.OilBucket), "no bucket slot: buckets go on the block")
		-- Tanks: oil in, fuel out, 10 000 mB each.
		local tanks = Machines.tanks(REFINERY)
		t.eq(#tanks, 2)
		t.eq(tanks[1].name, "oil")
		t.eq(tanks[1].role, "input")
		t.eq(tanks[1].capacity, TANK)
		t.eq(tanks[1].fluid, OIL)
		t.eq(tanks[2].name, "fuel")
		t.eq(tanks[2].role, "output")
		t.eq(tanks[2].capacity, TANK)
		t.eq(tanks[2].fluid, FUEL)
		t.ok(Machines.takesFluid(REFINERY, OIL))
		t.ok(not Machines.takesFluid(REFINERY, FUEL), "fuel only comes out")
		t.ok(not Machines.takesFluid(REFINERY, Fluids.WATER))
		t.ok(Machines.givesFluid(REFINERY))
		local fresh: any = Machines.newContainer(REFINERY)
		t.eq(Machines.capacity(fresh), CAPACITY)
		t.eq(field(fresh, "oil"), 0)
		t.eq(field(fresh, "fuel"), 0)
		local input, output = Machines.rates(fresh)
		t.eq(input, CAPACITY, "Mekanism's machines take any amount")
		t.eq(output, 0)
		local info = Machines.info(REFINERY)
		t.eq(info.ticksPerBucket, 100)
		t.eq(info.energyPerTick, USE)
		t.eq(info.fuelPerOil, 1)
	end)

	--[[ Refining ]]

	t.test("oil refinery: 10 mB a tick for 200 J, a bucket in 100 ticks for 20 kJ", function()
		local c = refinery(1000)
		for i = 1, 100 do
			tick(c)
			t.eq(field(c, "rate"), -USE, `tick {i}: 200 J`)
			t.eq(Machines.tankAmount(c, "fuel"), i * RATE, `tick {i}: 10 mB more fuel`)
			if i == 50 then
				t.eq(field(c, "progress"), 500, "halfway through the bucket")
				t.eq(status(c), "Using 200 J/t")
				t.eq(field(c, "active"), 1)
			end
		end
		t.eq(Machines.tankAmount(c, "oil"), 0)
		t.eq(Machines.tankAmount(c, "fuel"), 1000, "oil into fuel, 1:1")
		t.eq(Machines.energy(c), CAPACITY - 20000, "20 kJ a bucket")
		t.eq(field(c, "progress"), 0, "the bucket is done")
		t.eq(field(c, "ticksRequired"), 100)
		t.eq(field(c, "energyPerTick"), USE)
		tick(c)
		t.eq(field(c, "rate"), 0)
		t.eq(field(c, "state"), 0, "idle")
		t.eq(status(c), "Idle")
		t.eq(Machines.energy(c), CAPACITY - 20000, "idle uses nothing")
	end)

	t.test("oil refinery: no power, a full fuel tank and no oil stop it; short, it refines what it can", function()
		-- Less than a tick's energy: nothing moves (Mekanism pauses).
		local weak = refinery(500)
		weak.data[ENERGY] = USE - 1
		tick(weak, 5)
		t.eq(Machines.tankAmount(weak, "oil"), 500)
		t.eq(Machines.tankAmount(weak, "fuel"), 0)
		t.eq(field(weak, "state"), 1)
		t.eq(status(weak), "No power")
		t.eq(Machines.state(weak), 1, "WAILA gets it from the record")
		-- A full fuel tank: output full.
		local full = refinery(500)
		Machines.tankInsert(full, "fuel", FUEL, TANK)
		tick(full)
		t.eq(Machines.tankAmount(full, "oil"), 500)
		t.eq(status(full), "Output full")
		t.eq(Machines.energy(full), CAPACITY)
		-- Room for 4 mB: refines 4 for 4/10 of a tick's energy.
		local roomy = refinery(500)
		Machines.tankInsert(roomy, "fuel", FUEL, TANK - 4)
		tick(roomy)
		t.eq(Machines.tankAmount(roomy, "fuel"), TANK)
		t.eq(Machines.tankAmount(roomy, "oil"), 496)
		t.eq(Machines.energy(roomy), CAPACITY - 80)
		t.eq(field(roomy, "rate"), -80)
		-- 3 mB of oil: all of it, for 60 J; nothing is stuck below a tick's share.
		local short = refinery(3)
		tick(short)
		t.eq(Machines.tankAmount(short, "oil"), 0)
		t.eq(Machines.tankAmount(short, "fuel"), 3)
		t.eq(Machines.energy(short), CAPACITY - 60)
		-- Out of oil, the bucket starts over.
		tick(short)
		t.eq(field(short, "progress"), 0)
		t.eq(status(short), "Idle")
		-- Item data from elsewhere can't push the progress past a bucket.
		local forged = refinery(100)
		Machines.set(forged, "progress", 1e9)
		tick(forged)
		t.ok(field(forged, "progress") < 1000, "within a bucket")
		t.eq(Machines.tankAmount(forged, "fuel"), RATE)
	end)

	t.test("oil refinery: Speed and Energy Upgrades with Mekanism's maths", function()
		local function with(speed: number, energyCards: number, oil: number): any
			local c = refinery(oil)
			if speed > 0 then
				c.slots[1] = S(I.SpeedUpgrade, speed)
			end
			if energyCards > 0 then
				c.slots[2] = S(I.EnergyUpgrade, energyCards)
			end
			return c
		end
		-- One Speed Upgrade: 74 ticks a bucket (getTicks), 200 x 10^(2/8) J a tick.
		local one = with(1, 0, 10000)
		tick(one)
		t.eq(field(one, "ticksRequired"), 74)
		t.eq(field(one, "energyPerTick"), Upgrades.energyPerTick(USE, 1, 0))
		local refined = Machines.tankAmount(one, "fuel")
		t.ok(refined == 13 or refined == 14, `1000 / 74 mB a tick: {refined}`)
		for _ = 2, 74 do
			one.data[ENERGY] = CAPACITY
			tick(one)
		end
		local bucket = Machines.tankAmount(one, "fuel")
		t.ok(bucket >= 999 and bucket <= 1000, `a bucket in 74 ticks: {bucket}`)
		t.eq(Machines.tankAmount(one, "oil") + bucket, 10000, "nothing made or lost")
		-- Eight: a bucket in 10 ticks, 100 mB a tick, at ten times ten the energy (20 kJ a tick).
		local eight = with(8, 0, 10000)
		tick(eight)
		t.eq(field(eight, "ticksRequired"), 10)
		t.eq(Machines.tankAmount(eight, "fuel"), 100)
		t.eq(field(eight, "rate"), -20000)
		tick(eight)
		tick(eight)
		t.eq(Machines.tankAmount(eight, "fuel"), 200, "40 kJ holds two such ticks")
		t.eq(status(eight), "No power")
		-- Energy Upgrades: a bigger store, cheaper work; with 8 of each, 100 mB a tick for 2 kJ.
		local both = with(8, 8, 1000)
		both.data[ENERGY] = 0
		tick(both)
		t.eq(Machines.capacity(both), CAPACITY * 10)
		t.eq(field(both, "energyPerTick"), USE * 10)
		both.data[ENERGY] = Machines.capacity(both)
		tick(both, 10)
		t.eq(Machines.tankAmount(both, "fuel"), 1000)
		t.eq(Machines.energy(both), CAPACITY * 10 - 10 * USE * 10)
		local thrifty = with(0, 8, 100)
		tick(thrifty)
		t.eq(field(thrifty, "energyPerTick"), USE / 10, "20 J a tick")
		-- Taking the Energy Upgrades out cuts the store at once (Mekanism's setMaxEnergy).
		both.slots[2] = nil
		both.data[ENERGY] = CAPACITY * 10
		tick(both)
		t.eq(Machines.capacity(both), CAPACITY)
		t.ok(Machines.energy(both) <= CAPACITY)
	end)

	t.test("oil refinery: ACTIVE holds through short stops (Mekanism's deactivation delay)", function()
		local c = refinery(5000)
		c.data[ENERGY] = 0
		for i = 1, 40 do
			-- Power for every other tick.
			if i % 2 == 1 then
				c.data[ENERGY] = USE
			end
			tick(c)
			-- (Its first stop shows at once; every stop within 60 ticks of one doesn't.)
			if i > 2 then
				t.eq(field(c, "active"), 1, `tick {i}: steady`)
			end
		end
		-- One that finishes its oil goes dark at once (its first stop).
		local done = refinery(10)
		tick(done)
		t.eq(field(done, "active"), 1)
		tick(done)
		t.eq(field(done, "active"), 0, "a finished refinery goes dark at once")
	end)

	--[[ Pipes, buckets and the item ]]

	t.test("oil refinery: pipes fill its oil and drain its fuel; buckets too", function()
		local c: any = Machines.newContainer(REFINERY)
		t.eq(Machines.insertFluid(c, FUEL, 500), 0, "fuel doesn't go in")
		t.eq(Machines.insertFluid(c, Fluids.WATER, 500), 0)
		t.eq(Machines.insertFluid(c, OIL, 12000), TANK, "oil up to 10 000 mB")
		t.ok(not Machines.pourBucket(c, OIL), "full")
		local fluid, amount = Machines.extractFluid(c, 100)
		t.eq(amount, 0, "the oil never comes out through pipes")
		Machines.tankInsert(c, "fuel", FUEL, 2500)
		fluid, amount = Machines.extractFluid(c, 100, OIL)
		t.eq(amount, 0, "a pipe of oil takes no fuel")
		fluid, amount = Machines.extractFluid(c, 100)
		t.eq(fluid, FUEL)
		t.eq(amount, 100)
		-- An empty bucket takes fuel first, then oil when the fuel is short of a bucket.
		t.eq(Machines.fillBucket(c), FUEL)
		t.eq(Machines.tankAmount(c, "fuel"), 1400)
		t.eq(Machines.fillBucket(c), FUEL)
		t.eq(Machines.fillBucket(c), OIL, "400 mB of fuel is no bucket")
		t.eq(Machines.tankAmount(c, "oil"), TANK - 1000)
		t.ok(Machines.pourBucket(c, OIL), "an Oil Bucket fits again")
		t.ok(not Machines.pourBucket(c, FUEL), "a Fuel Bucket doesn't go in")
	end)

	t.test("oil refinery: its item keeps its energy and both tanks", function()
		local c = refinery(2000)
		Machines.tankInsert(c, "fuel", FUEL, 3000)
		c.slots[1] = S(I.SpeedUpgrade, 2)
		local data = Machines.save(c) :: any
		t.eq(data.energy, CAPACITY)
		t.eq(data.oil, 2000)
		t.eq(data.fuel, 3000)
		local lines = Items.describe({ item = REFINERY, count = 1, data = data })
		t.eq(lines[1], "Energy: 40 kJ")
		t.ok(table.find(lines, "Oil: 2,000 mB") ~= nil)
		t.ok(table.find(lines, "Fuel: 3,000 mB") ~= nil)
		local placed: any = Machines.newContainer(REFINERY)
		t.ok(Machines.restore(placed, data))
		t.eq(Machines.tankAmount(placed, "oil"), 2000)
		t.eq(Machines.tankAmount(placed, "fuel"), 3000)
		t.eq(Machines.energy(placed), CAPACITY)
		t.eq(placed.slots[1], nil, "the cards drop instead")
	end)

	--[[ On the server ]]

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
		return self
	end

	t.test("oil refinery: a creative cube powers it through a cable; its record says it works", function()
		local s = sim()
		s.set(0, Y, 0, REFINERY)
		s.set(1, Y, 0, B.BasicUniversalCable)
		s.set(2, Y, 0, B.CreativeEnergyCube)
		local c = s.container(0, Y, 0)
		Machines.tankInsert(c, "oil", OIL, 2000)
		s.step(2)
		t.ok(Machines.tankAmount(c, "fuel") >= RATE, "it works on the network's energy")
		s.step(250)
		t.eq(Machines.tankAmount(c, "fuel"), 2000, "two buckets refined")
		t.eq(Machines.tankAmount(c, "oil"), 0)
		local records = MachineWorld.takeRecords(s.world)
		local found = nil
		for _, record in records do
			if record.x == 0 and record.y == Y and record.z == 0 then
				found = record
			end
		end
		t.ok(found ~= nil, "a record for players near it")
	end)

	--[[ What players see ]]

	t.test("oil refinery: its panel: oil gauge, arrow, fuel gauge, status, upgrades, energy bar", function()
		local c = refinery(1000)
		local panel = MenuLayout.panel(c)
		t.eq(panel.title, "Oil Refinery")
		t.eq(#panel.slots, 2)
		t.eq(panel.slots[1].x, 82)
		t.eq(panel.slots[1].y, 53)
		t.ok(panel.slots[1].ghost ~= nil and panel.slots[2].ghost ~= nil, "the cards' outlines")
		local gauges = Machines.gauges(REFINERY)
		t.eq(#gauges, 2)
		t.eq(gauges[1].name, "oil")
		t.eq(gauges[2].name, "fuel")
		local arrow = panel.progress :: any
		local energy = panel.energy :: any
		local statusAt = panel.status :: any
		-- Nothing overlaps: gauges, the arrow, the slots' frames, the status line, the energy bar.
		local boxes = {
			{ "oil gauge", gauges[1].x, gauges[1].y, gauges[1].w, gauges[1].h },
			{ "fuel gauge", gauges[2].x, gauges[2].y, gauges[2].w, gauges[2].h },
			{ "arrow", arrow.x, arrow.y, arrow.w, arrow.h },
			{ "speed slot", panel.slots[1].x - 1, panel.slots[1].y - 1, 18, 18 },
			{ "energy slot", panel.slots[2].x - 1, panel.slots[2].y - 1, 18, 18 },
			{ "status", statusAt.x, statusAt.y, energy.x - 2 - statusAt.x, 8 },
			{ "energy bar", energy.x - 1, energy.y - 1, energy.w + 2, energy.h + 2 },
		}
		for i, a in boxes do
			t.ok(a[2] >= 4 and a[3] >= 4 and a[2] + a[4] <= 172 and a[3] + a[5] <= panel.height - 4, `{a[1]} inside`)
			for j = i + 1, #boxes do
				local b = boxes[j]
				local apart = a[2] + a[4] <= b[2] or b[2] + b[4] <= a[2] or a[3] + a[5] <= b[3] or b[3] + b[5] <= a[3]
				t.ok(apart, `{a[1]} and {b[1]} apart`)
			end
		end
		t.ok(gauges[1].x + gauges[1].w <= arrow.x and arrow.x + arrow.w <= gauges[2].x, "oil, arrow, fuel in a row")
		-- The arrow fills once a bucket.
		tick(c, 50)
		t.eq(MenuLayout.machineArrowColumns(c.data, panel.progressSource), 12, "half a bucket")
		t.eq(MenuLayout.statusText(c), "Using 200 J/t")
		-- The gauges read the window's data.
		t.eq(c.data[gauges[1].amount], 500)
		t.eq(c.data[gauges[2].amount], 500)
		t.eq(Machines.gaugeLevel(c.data[gauges[2].amount], gauges[2].capacity, gauges[2].h - 2), 3)
		-- WAILA: energy and the status from the record.
		local facts = WailaInfo.machineDefaults(REFINERY)
		local lines = WailaInfo.machineLines(REFINERY, facts)
		t.eq(WailaInfo.text(lines[1]), "Energy: 0 J / 40 kJ")
		t.eq(WailaInfo.text(lines[2]), "Idle")
		facts.rate, facts.active = -USE, true
		t.eq(WailaInfo.text(WailaInfo.machineLines(REFINERY, facts)[2]), "Using 200 J/t")
	end)

	t.test("oil refinery: decor, a light steel machine with its sight glasses", function()
		local faces = BlockDecor.faces("OilRefinery") :: any
		t.ok(faces ~= nil)
		local window = BlockDecor.REFINERY_WINDOW
		for _, face in { "Front", "Back", "Left", "Right" } do
			local found = false
			for _, r in faces[face] do
				if r.x == window.x and r.y == window.y and r.w == window.w and r.h == window.h then
					found = true
				end
			end
			t.ok(found, `{face}: the heater's window`)
		end
		local parts = BlockDecor.partCount("OilRefinery")
		t.ok(parts > 0 and parts < 40, `item model slabs: {parts}`)
		-- Item model tops look the same turned by a quarter (see the Meshing spec).
		for _, face in { "Top", "Bottom" } do
			local cells = {}
			for _, r in faces[face] do
				if not r.surfaceOnly then
					for y = r.y, r.y + r.h - 1 do
						for x = r.x, r.x + r.w - 1 do
							cells[y * 16 + x] = table.concat(r.colour, ",")
						end
					end
				end
			end
			for y = 0, 15 do
				for x = 0, 15 do
					t.eq(cells[y * 16 + x], cells[x * 16 + (15 - y)], `{face} at {x},{y}`)
				end
			end
		end
		-- Its recipe: Mekanism's machine shape (Crafting spec has the details).
		local found = false
		for _, recipe in Crafting.recipes do
			if recipe.result == REFINERY then
				found = true
			end
		end
		t.ok(found, "craftable")
	end)
end

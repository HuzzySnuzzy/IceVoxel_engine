--[[
	Mekanism Generators' Solar Generator, named the Solar Panel (Shared/Machines/Kinds/Solar,
	BlockList SolarPanel): the block and Mekanism's numbers, the recipe, the day (Minecraft's isDay
	and Mekanism's sun brightness, on the server's clock), the sky (nothing opaque above it: the
	server's cached look, refreshed by block changes above, and SkyCheck over loaded chunks, edits
	and generated terrain without generating any), a full store, the upgrade cards (Speed raises
	what it makes, Energy its store), a whole day's energy to the quantum, an Electric Furnace run
	by it, records and WAILA's lines with the Night / No sky state codes, sustained energy and
	its panel.
]]

return function(t, shared, require, server, client)
	local Blocks = require(shared.Blocks)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Config = require(shared.Config)
	local Coords = require(shared.World.Coords)
	local Crafting = require(shared.Crafting)
	local DayCycle = require(shared.DayCycle)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local Upgrades = require(shared.Machines.Upgrades)
	local Protocol = require(shared.Net.Protocol)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local Transmitters = require(shared.Transmitters)
	local Types = require(shared.Inventory.Types)
	local Containers = require(server.Players.Containers)
	local EditRules = require(server.Network.EditRules)
	local MachineWorld = require(server.Machines.MachineWorld)
	local SkyCheck = require(server.Machines.SkyCheck)
	local TransmitterWorld = require(server.Transmitters.TransmitterWorld)
	local WorldServer = require(server.World.WorldServer)
	local MenuLayout = require(client.Ui.MenuLayout)
	local WailaInfo = require(client.Ui.WailaInfo)

	local B = Blocks.id
	local I = Items.id
	local AIR = B.Air
	local SOLAR = B.SolarPanel
	local ENERGY = Machines.ENERGY
	local HEIGHT = Config.WorldHeight
	local Y = 64
	-- Mekanism's Solar Generator: J/t in full sun, its store and what it gives out.
	local PEAK, CAPACITY, OUTPUT = 50, 96000, 100
	local NOON, MIDNIGHT = 6000, 18000
	-- Slots and state codes.
	local SPEED_SLOT, ENERGY_SLOT = 1, 2
	local PRODUCING, NIGHT, NO_SKY, FULL = 0, 1, 2, 3

	local function S(item: number, count: number)
		return { item = item, count = count }
	end

	-- A tick context at `dayTime` whose sky is `open` (nil: no sky function, as in tests).
	local function ctx(dayTime: number?, open: boolean?): any
		return {
			block = SOLAR,
			x = 3,
			y = Y,
			z = -7,
			energy = Machines.energyOf(SOLAR),
			tick = 1,
			dayTime = dayTime or NOON,
			getBlock = function()
				return nil
			end,
			sky = if open == nil
				then nil
				else function(x: number, y: number, z: number): boolean
					assert(x == 3 and y == Y and z == -7, "it asks about its own cell")
					return open
				end,
		}
	end

	local function tick(container: any, dayTime: number?, open: boolean?, n: number?)
		for _ = 1, n or 1 do
			Machines.tick(container, ctx(dayTime, open))
		end
	end

	local function status(container: any): string?
		return Machines.status(SOLAR, Machines.view(container))
	end

	local function field(container: any, name: string): number
		return Machines.get(container, name)
	end

	--[[ The block ]]

	t.test("solar panel: the block, its kind and Mekanism's numbers", function()
		local def = Blocks.get(SOLAR)
		t.eq(Items.displayName(SOLAR), "Solar Panel")
		t.eq(def.hardness, 3.5, "Mekanism's machines")
		t.eq(def.tool, "pickaxe")
		t.eq(def.toolLevel, 0)
		t.eq(def.sound, "metal")
		t.eq(def.menu, "Machine")
		t.eq(def.container, 0)
		t.eq(Items.drops(SOLAR, nil), nil, "a pickaxe is needed for it to drop")
		t.eq((Items.drops(SOLAR, I.StonePickaxe) :: any).item, SOLAR)
		-- Mekanism's shape: no full cube, a thin panel on a post.
		t.ok(def.shape ~= nil and #(def.shape :: any) <= Blocks.MAX_SHAPE_BOXES)
		t.eq(def.bounds.max[2], 9, "9 pixels tall")
		t.eq(def.bounds.min[2], 0)
		t.eq(def.bounds.max[1] - def.bounds.min[1], 16, "the panel spans its cell")
		t.ok(not Blocks.isOpaque(SOLAR), "no opaque block: the panels of a stack all see the sky")
		t.ok(not def.solid and def.obstructs and def.placeable)
		-- The machine.
		t.ok(Machines.isMachine(SOLAR))
		local kind = Machines.kindOf(SOLAR) :: any
		t.eq(kind.name, "solar")
		t.eq(Machines.role(SOLAR), "producer")
		local energy = Machines.energyOf(SOLAR) :: any
		t.eq(energy.capacity, CAPACITY)
		t.eq(energy.output, OUTPUT, "twice what it makes")
		t.eq(energy.input, nil)
		t.eq(Machines.containerSize(SOLAR), 2, "its two upgrade slots")
		t.eq(kind.index.state, Machines.HEADER + 1)
		t.eq(kind.size, Machines.HEADER + 1)
		t.eq(kind.state, kind.index.state, "its state code travels in records")
		t.eq(#kind.keep, 0, "only its energy goes into its item")
		t.ok(Transmitters.isEnergyAcceptor(SOLAR), "cables connect to it")
		t.ok(not Transmitters.isItemAcceptor(SOLAR), "transporters don't: nothing they could reach")
		-- A fresh one.
		local container = Machines.newContainer(SOLAR)
		t.eq(container.size, 2)
		t.eq(Machines.capacity(container), CAPACITY)
		t.eq(status(container), "Idle", "not ticked yet")
		local input, output = Machines.rates(container)
		t.eq(input, 0)
		t.eq(output, OUTPUT)
	end)

	t.test("solar panel: Mekanism's recipe with glass, gold, iron, osmium and glowstone", function()
		local function craft(rows: { { number } }): any
			local stacks = {}
			for row = 1, 3 do
				for column = 1, 3 do
					stacks[(row - 1) * 3 + column] = S(rows[row][column], 1)
				end
			end
			return Crafting.match(stacks, 3)
		end
		local G, A, Fe, O, D = I.Glass, I.GoldIngot, I.IronIngot, I.OsmiumIngot, I.GlowDust
		local made = craft({ { G, G, G }, { A, Fe, A }, { O, D, O } })
		t.eq(made and made.item, SOLAR)
		t.eq(made and made.count, 1)
		t.eq(made and made.data, nil)
		t.eq(craft({ { G, G, G }, { A, Fe, A }, { O, O, O } }), nil, "glowstone for the energy tablet")
		t.eq(craft({ { G, I.Sand, G }, { A, Fe, A }, { O, D, O } }), nil, "three glass cells")
	end)

	--[[ The sun ]]

	t.test("solar panel: Minecraft's day and Mekanism's sun brightness", function()
		t.ok(DayCycle.isDay(NOON) and DayCycle.isDay(0) and DayCycle.isDay(12000))
		t.ok(not DayCycle.isDay(13000) and not DayCycle.isDay(MIDNIGHT))
		-- Level.isDay: the sky darkens by less than 4.
		t.ok(DayCycle.isDay(12540) and not DayCycle.isDay(12541), "dusk")
		t.ok(not DayCycle.isDay(23459) and DayCycle.isDay(23460), "dawn")
		t.ok(DayCycle.isDay(24000 + NOON), "the clock counts past a day")
		local day = 0
		for time = 0, DayCycle.TICKS_PER_DAY - 1 do
			day += if DayCycle.isDay(time) then 1 else 0
			t.eq(DayCycle.isDay(time), DayCycle.skyDarken(time) < 4)
		end
		t.eq(day, 13081, "a little more than half the day")
		-- getSunBrightness: skyBrightness mapped to 0.2..1.
		t.eq(DayCycle.sunBrightness(NOON), 1)
		t.eq(DayCycle.sunBrightness(MIDNIGHT), 0.2)
		t.eq(DayCycle.sunBrightness(1000), 1, "full sun from mid morning")
		t.near(DayCycle.sunBrightness(12540), 0.469, 1e-3, "under half when it stops")
		for _, time in { 0, 500, 3000, 11500, 12500, 20000 } do
			t.near(DayCycle.sunBrightness(time), DayCycle.skyBrightness(time) * 0.8 + 0.2, 1e-12)
		end
	end)

	t.test("solar panel: 50 J/t in full sun, less while the sun is low, nothing at night", function()
		local container = Machines.newContainer(SOLAR)
		tick(container, NOON, true)
		t.eq(Machines.energy(container), PEAK)
		t.eq(field(container, "rate"), PEAK)
		t.eq(field(container, "active"), 1)
		t.eq(Machines.view(container).state, PRODUCING)
		t.eq(status(container), "Producing 50 J/t")
		tick(container, NOON, true, 9)
		t.eq(Machines.energy(container), 10 * PEAK)
		-- Sunrise (tick 0): the sun is low.
		local low = Machines.quantise(PEAK * DayCycle.sunBrightness(0))
		tick(container, 0, true)
		t.eq(field(container, "rate"), low)
		t.ok(low > 34 and low < 36, "about 35 J/t at sunrise")
		t.eq(Machines.energy(container), 10 * PEAK + low)
		-- Just before dusk it still makes under half; then nothing.
		tick(container, 12540, true)
		t.near(field(container, "rate"), 23.46, 0.03)
		local before = Machines.energy(container)
		tick(container, 12541, true)
		t.eq(field(container, "rate"), 0)
		t.eq(field(container, "active"), 0)
		t.eq(Machines.energy(container), before, "night: nothing made")
		t.eq(Machines.view(container).state, NIGHT)
		t.eq(status(container), "Night")
		tick(container, MIDNIGHT, true)
		t.eq(status(container), "Night")
		-- Without a sky function (no world) the sky counts as open.
		tick(container, NOON, nil)
		t.eq(field(container, "rate"), PEAK)
	end)

	t.test("solar panel: under a roof it makes nothing, day or night", function()
		local container = Machines.newContainer(SOLAR)
		tick(container, NOON, false)
		t.eq(Machines.energy(container), 0)
		t.eq(field(container, "rate"), 0)
		t.eq(field(container, "active"), 0)
		t.eq(Machines.view(container).state, NO_SKY)
		t.eq(status(container), "No sky")
		tick(container, MIDNIGHT, false)
		t.eq(status(container), "No sky", "the roof is what the player can change")
		tick(container, NOON, true)
		t.eq(status(container), "Producing 50 J/t", "roof gone")
	end)

	t.test("solar panel: a full store waits, a nearly full one takes what fits", function()
		local container: any = Machines.newContainer(SOLAR)
		container.data[ENERGY] = CAPACITY - 20
		tick(container, NOON, true)
		t.eq(Machines.energy(container), CAPACITY)
		t.eq(field(container, "rate"), 20, "only its room")
		t.eq(status(container), "Producing 20 J/t")
		tick(container, NOON, true)
		t.eq(field(container, "rate"), 0)
		t.eq(field(container, "active"), 0)
		t.eq(Machines.view(container).state, FULL)
		t.eq(status(container), "Full")
		t.eq(Machines.energy(container), CAPACITY)
	end)

	t.test("solar panel: Speed Upgrades raise what it makes, Energy Upgrades its store", function()
		local container: any = Machines.newContainer(SOLAR)
		container.slots[SPEED_SLOT] = S(I.SpeedUpgrade, 8)
		tick(container, NOON, true)
		t.eq(field(container, "rate"), 500, "8 cards: 500 J/t in full sun")
		t.eq(status(container), "Producing 500 J/t")
		local _, output = Machines.rates(container)
		t.eq(output, 1000, "and twice that out")
		container.slots[SPEED_SLOT] = S(I.SpeedUpgrade, 4)
		tick(container, NOON, true)
		t.eq(field(container, "rate"), Machines.quantise(Upgrades.production(PEAK, 4)))
		t.near(field(container, "rate"), 158.11, 0.01)
		_, output = Machines.rates(container)
		t.eq(output, Machines.quantise(Upgrades.production(OUTPUT, 4)))
		-- Low sun scales the upgraded production too.
		container.slots[SPEED_SLOT] = S(I.SpeedUpgrade, 8)
		tick(container, 0, true)
		t.eq(field(container, "rate"), Machines.quantise(500 * DayCycle.sunBrightness(0)))
		-- Energy Upgrades: ten times the store with 8.
		local store: any = Machines.newContainer(SOLAR)
		store.slots[ENERGY_SLOT] = S(I.EnergyUpgrade, 8)
		tick(store, MIDNIGHT, true)
		t.eq(Machines.capacity(store), 960000)
		store.data[ENERGY] = 900000
		tick(store, MIDNIGHT, true)
		t.eq(Machines.energy(store), 900000)
		_, output = Machines.rates(store)
		t.eq(output, OUTPUT, "energy cards don't change what it gives out")
		-- Taking them out cuts the store back at once.
		store.slots[ENERGY_SLOT] = nil
		tick(store, MIDNIGHT, true)
		t.eq(Machines.capacity(store), CAPACITY)
		t.eq(Machines.energy(store), CAPACITY)
		-- Wrong cards do nothing.
		local wrong: any = Machines.newContainer(SOLAR)
		wrong.slots[SPEED_SLOT] = S(I.EnergyUpgrade, 8)
		wrong.slots[ENERGY_SLOT] = S(I.SpeedUpgrade, 8)
		tick(wrong, NOON, true)
		t.eq(field(wrong, "rate"), PEAK)
		t.eq(Machines.capacity(wrong), CAPACITY)
	end)

	t.test("solar panel: a whole day's energy, to the quantum", function()
		-- 8 Energy Upgrades: a day's energy fits in its store, so nothing is lost to a full store.
		local container: any = Machines.newContainer(SOLAR)
		container.slots[ENERGY_SLOT] = S(I.EnergyUpgrade, 8)
		local expected, producing = 0, 0
		for time = 0, DayCycle.TICKS_PER_DAY - 1 do
			Machines.tick(container, ctx(time, true))
			if DayCycle.isDay(time) then
				expected += Machines.quantise(PEAK * DayCycle.sunBrightness(time))
				producing += 1
			end
		end
		t.eq(Machines.energy(container), expected, "exactly what the sun gave")
		t.eq(producing, 13081)
		t.ok(expected > 600000 and expected < 640000, `about 620 kJ a day: {expected}`)
	end)

	--[[ On the server ]]

	-- Machines in a world of blocks, ticked as the server does, with the day time `clock.time`
	-- and a counted sky look (`looks`); `withSky` false leaves the look to MachineWorld.
	local function sim(withSky: boolean?)
		local blocks: { [number]: number } = {}
		local containers = Containers.new()
		local function getBlock(x: number, y: number, z: number): number?
			return blocks[Coords.posKey(x, y, z)] or AIR
		end
		local self: any = { looks = 0, time = NOON }
		local function sky(x: number, y: number, z: number): boolean
			self.looks += 1
			for cy = y + 1, HEIGHT - 1 do
				if Blocks.isOpaque(getBlock(x, cy, z) :: number) then
					return false
				end
			end
			return true
		end
		local cables = TransmitterWorld.new({ getBlock = getBlock, containers = containers })
		local world = MachineWorld.new({
			getBlock = getBlock,
			containers = containers,
			transmitters = cables,
			dayTime = function()
				return self.time
			end,
			sky = if withSky == false then nil else sky,
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

	t.test("solar panel: the server's sky look is cached and follows the blocks above", function()
		local s = sim()
		s.set(0, Y, 0, SOLAR)
		local panel = s.container(0, Y, 0)
		s.step()
		t.eq(Machines.view(panel).rate, PEAK)
		t.eq(s.looks, 1, "looked once")
		s.step(20)
		t.eq(s.looks, 1, "then cached")
		t.eq(Machines.energy(panel), 21 * PEAK)
		-- Stone far above covers it at once, without looking again.
		s.set(0, Y + 40, 0, B.Stone)
		s.step()
		t.eq(s.looks, 1)
		t.eq(Machines.view(panel).state, NO_SKY)
		t.eq(status(panel), "No sky")
		t.eq(s.record(0, Y, 0).state, NO_SKY, "WAILA's record carries it")
		-- Glass and other non-opaque blocks change nothing.
		s.set(0, Y + 3, 0, B.Glass)
		s.set(0, Y + 2, 0, B.BasicUniversalCable)
		s.set(0, Y + 1, 0, SOLAR)
		s.step()
		t.eq(s.looks, 2, "only the new panel above looked")
		t.eq(Machines.view(panel).state, NO_SKY)
		-- The stone goes: it looks again and sees the sky through the glass, cable and panel.
		s.set(0, Y + 40, 0, AIR)
		s.step()
		t.eq(s.looks, 4, "both panels looked again")
		t.eq(Machines.view(panel).state, PRODUCING)
		t.eq(Machines.view(panel).rate, PEAK)
		t.eq(Machines.view(s.container(0, Y + 1, 0)).rate, PEAK, "the panel above too")
		-- Leaves (and ice) cover it, as in Minecraft.
		s.set(0, Y + 10, 0, B.OakLeaves)
		s.step()
		t.eq(status(panel), "No sky")
		s.set(0, Y + 10, 0, B.Ice)
		s.step()
		t.eq(status(panel), "No sky")
		s.set(0, Y + 10, 0, B.Water)
		s.step()
		t.eq(status(panel), "Producing 50 J/t", "water lets the sun through")
		local looks = s.looks
		-- Blocks elsewhere, below it or beside it change nothing and cost no look.
		s.set(1, Y + 5, 0, B.Stone)
		s.set(0, Y - 1, 0, B.Stone)
		s.set(0, Y + 5, 1, B.Stone)
		s.step(5)
		t.eq(s.looks, looks)
		t.eq(status(panel), "Producing 50 J/t")
		-- Broken, its answer goes with it.
		local cells = s.world.skyCells
		s.set(0, Y + 1, 0, AIR)
		t.eq(s.world.skyCells, cells - 1)
		s.set(0, Y, 0, AIR)
		t.eq(s.world.skyCells, cells - 2)
		t.eq(next(s.world.sky), nil, "nothing left")
		-- A full cache starts over, and answers stay right.
		local max = MachineWorld.MAX_SKY_CELLS
		MachineWorld.MAX_SKY_CELLS = 2
		s.set(9, Y + 3, 9, B.Stone)
		local ok, err = pcall(function()
			t.ok(MachineWorld.seesSky(s.world, 7, Y, 7))
			t.ok(MachineWorld.seesSky(s.world, 8, Y, 7))
			t.eq(s.world.skyCells, 2)
			t.ok(not MachineWorld.seesSky(s.world, 9, Y, 9), "a third: the cache starts over")
			t.eq(s.world.skyCells, 1)
			t.ok(MachineWorld.seesSky(s.world, 7, Y, 7), "looked again")
			t.ok(not MachineWorld.seesSky(s.world, 9, Y, 9), "still cached")
			t.ok(MachineWorld.seesSky(s.world, 9, Y + 3, 9), "on the stone")
			t.ok(MachineWorld.seesSky(s.world, 9, HEIGHT + 2, 9), "outside the world: no cache, open")
		end)
		MachineWorld.MAX_SKY_CELLS = max
		assert(ok, err)
	end)

	t.test("solar panel: under two roofs, one swapped or taken away, the lower one still covers", function()
		local s = sim()
		s.set(0, Y, 0, SOLAR)
		s.set(0, Y + 20, 0, SOLAR)
		s.set(0, Y + 3, 0, B.Stone)
		s.set(0, Y + 9, 0, B.Stone)
		s.step()
		local panel, upper = s.container(0, Y, 0), s.container(0, Y + 20, 0)
		t.eq(s.looks, 2, "each panel looked once")
		t.eq(status(panel), "No sky")
		t.eq(status(upper), "Producing 50 J/t", "the roofs are below the upper panel")
		-- A roof swapped for another opaque block: still covered, without a look.
		s.set(0, Y + 9, 0, B.Dirt)
		s.step()
		t.eq(s.looks, 2)
		t.eq(status(panel), "No sky")
		-- The upper roof goes: it looks again (once) and still finds the lower one.
		s.set(0, Y + 9, 0, AIR)
		s.step(3)
		t.eq(s.looks, 3, "only the covered panel looked again")
		t.eq(status(panel), "No sky")
		t.eq(status(upper), "Producing 50 J/t")
		-- The lower one goes too: the sky.
		s.set(0, Y + 3, 0, AIR)
		s.step()
		t.eq(s.looks, 4)
		t.eq(status(panel), "Producing 50 J/t")
		-- A roof over both covers both at once.
		s.set(0, Y + 30, 0, B.Stone)
		s.step()
		t.eq(s.looks, 4)
		t.eq(status(panel), "No sky")
		t.eq(status(upper), "No sky")
		t.eq(s.world.skyCells, 2, "one answer per panel")
	end)

	t.test("solar panel: the server's clock decides day and night; records tell WAILA", function()
		local s = sim()
		s.set(0, Y, 0, SOLAR)
		s.time = MIDNIGHT
		s.step(10)
		local record = s.record(0, Y, 0)
		t.eq(record.state, NIGHT)
		t.eq(record.rate, 0)
		t.eq(record.active, false)
		local function has(records: { any }, state: number): boolean
			for _, r in records do
				if r.x == 0 and r.y == Y and r.z == 0 and r.state == state then
					return true
				end
			end
			return false
		end
		t.ok(has(MachineWorld.takeRecords(s.world), NIGHT), "a changed state is sent")
		t.ok(has(MachineWorld.chunkRecords(s.world, 0, 0), NIGHT), "and with its chunk: not the default")
		-- Over the wire and into WAILA's lines.
		local sent = (Protocol.decodeMachines(Protocol.encodeMachines({ record })) :: any)[1]
		t.eq(sent.state, NIGHT)
		local facts: WailaInfo.MachineFacts = {
			energy = sent.energy,
			capacity = sent.capacity,
			input = sent.input,
			output = sent.output,
			rate = sent.rate,
			active = sent.active,
			state = sent.state,
		}
		local function line(n: number): string
			return WailaInfo.text(WailaInfo.machineLines(SOLAR, facts)[n])
		end
		t.eq(line(1), "Energy: 0 J / 96 kJ")
		t.eq(line(2), "Night")
		facts.state = NO_SKY
		t.eq(line(2), "No sky")
		facts.state = FULL
		t.eq(line(2), "Full")
		facts.state, facts.rate = PRODUCING, 37.5
		t.eq(line(2), "Producing 37.5 J/t")
		local defaults = WailaInfo.machineDefaults(SOLAR)
		t.eq(WailaInfo.text(WailaInfo.machineLines(SOLAR, defaults)[2]), "Idle", "no record yet")
		-- Morning comes.
		s.time = NOON
		s.step()
		t.eq(s.record(0, Y, 0).state, PRODUCING)
		t.eq(s.record(0, Y, 0).rate, PEAK)
		t.eq(s.record(0, Y, 0).active, true)
		-- Without the game's look, the cells above are read with getBlock.
		local plain = sim(false)
		plain.set(4, Y, 4, SOLAR)
		plain.set(4, Y + 7, 4, B.Stone)
		plain.step()
		t.eq(status(plain.container(4, Y, 4)), "No sky")
		plain.set(4, Y + 7, 4, AIR)
		plain.step()
		t.eq(status(plain.container(4, Y, 4)), "Producing 50 J/t")
	end)

	t.test("solar panel: runs an Electric Furnace through a cable by day, not by night", function()
		local s = sim()
		s.set(0, Y, 0, SOLAR)
		s.set(1, Y, 0, B.BasicUniversalCable)
		s.set(2, Y, 0, B.ElectricFurnace)
		local panel, furnace = s.container(0, Y, 0), s.container(2, Y, 0)
		furnace.slots[1] = S(I.RawIron, 3)
		s.step(401)
		-- 50 J/t made, 50 J/t used: an item every 200 ticks (it waits for the first tick's energy).
		t.eq(furnace.slots[2] and furnace.slots[2].count, 2, "two ingots in 401 ticks")
		t.eq(Machines.status(B.ElectricFurnace, Machines.view(furnace)), "Using 50 J/t")
		t.eq(Machines.energy(panel), 0, "everything it makes goes to the furnace")
		local made = 401 * PEAK
		t.eq(made, 400 * 50 + Machines.energy(furnace), "energy made = used + stored, exactly")
		-- Night: the furnace runs out.
		s.time = MIDNIGHT
		s.step(3)
		t.eq(Machines.status(B.ElectricFurnace, Machines.view(furnace)), "No power")
		t.eq(status(panel), "Night")
		-- Sustained energy: only the energy goes into its item; capped at its base store.
		local registry = EditRules.newBlockData()
		registry:add(MachineWorld.blockDataHooks(s.world))
		panel.data[ENERGY] = 12345
		panel.slots[SPEED_SLOT] = S(I.SpeedUpgrade, 2)
		local drop = EditRules.breakDrop(registry, 0, Y, 0, SOLAR, false, I.IronPickaxe) :: any
		t.eq(drop.item, SOLAR)
		t.eq(drop.data.energy, 12345)
		t.eq(drop.data.state, nil, "its state stays behind")
		t.eq(Items.describe(drop)[1], "Energy: 12.34 kJ")
		s.set(0, Y, 0, AIR)
		s.set(5, Y, 5, SOLAR)
		registry:placed("p", 5, Y, 5, SOLAR, drop)
		t.eq(Machines.energy(s.container(5, Y, 5)), 12345)
		s.set(6, Y, 6, SOLAR)
		registry:placed("p", 6, Y, 6, SOLAR, { item = SOLAR, count = 1, data = { energy = 1e7 } })
		t.eq(Machines.energy(s.container(6, Y, 6)), CAPACITY, "at most its base store")
		t.eq(Machines.energy(s.container(6, Y, 6)), CAPACITY)
		-- Its upgrade cards are slots like any other (they drop when it is broken, as a chest's).
		t.eq(Machines.save(Machines.newContainer(SOLAR)), nil, "a fresh one keeps nothing")
	end)

	--[[ SkyCheck: the server's uncached look ]]

	local FLOOR = 10
	local CROP = 32
	local STONE = B.Stone
	local flat = {
		generate = function(level: number, nx: number, nz: number)
			local data = ChunkLayout.create(CROP)
			for y = 0, FLOOR - 1 do
				for i = 0, ChunkLayout.LAYER - 1 do
					buffer.writeu16(data, (y * ChunkLayout.LAYER + i) * 2, STONE)
				end
			end
			return {
				data = data,
				level = level,
				nx = nx,
				nz = nz,
				height = CROP,
				solidBelow = FLOOR,
				emptyAbove = FLOOR,
			}
		end,
		column = function()
			return FLOOR, 1, 0, STONE
		end,
		findSpawn = function()
			return 0, FLOOR, 0
		end,
	}

	local function unload(world: any)
		world:evict(function()
			return false
		end, 0)
		t.eq(world.chunkCount, 0)
	end

	t.test("sky check: loaded chunks are read, others from their edits over the ground", function()
		local world = WorldServer.new(flat :: any)
		-- Nothing loaded: the generator's ground height, and no chunk is generated.
		t.ok(SkyCheck.open(world, 0, FLOOR, 0), "on the ground")
		t.ok(SkyCheck.open(world, 0, FLOOR + 50, 0), "in the air")
		t.ok(SkyCheck.open(world, 0, FLOOR - 1, 0), "set into the surface")
		t.ok(not SkyCheck.open(world, 0, FLOOR - 2, 0), "in the ground")
		t.ok(not SkyCheck.open(world, 0, 2, 0), "deep down")
		t.ok(SkyCheck.open(world, 0, HEIGHT - 1, 0), "the top of the world")
		t.ok(SkyCheck.open(world, 0, HEIGHT + 5, 0), "above it")
		t.eq(world.chunkCount, 0, "never generated")
		-- A roof, loaded and not.
		world:setBlock(0, FLOOR + 4, 0, STONE)
		t.eq(world.chunkCount, 1)
		t.ok(not SkyCheck.open(world, 0, FLOOR, 0), "under the roof (loaded)")
		t.ok(SkyCheck.open(world, 0, FLOOR + 4, 0), "on the roof")
		t.ok(SkyCheck.open(world, 1, FLOOR, 0), "beside it")
		unload(world)
		t.ok(not SkyCheck.open(world, 0, FLOOR, 0), "under the roof (its edit)")
		t.ok(SkyCheck.open(world, 0, FLOOR + 4, 0))
		t.ok(SkyCheck.open(world, 1, FLOOR, 0))
		t.eq(world.chunkCount, 0)
		-- A shaft dug down to the sky, loaded and not.
		for y = FLOOR - 3, FLOOR - 1 do
			world:setBlock(5, y, 5, AIR)
		end
		t.ok(SkyCheck.open(world, 5, FLOOR - 4, 5), "at the bottom of the shaft (loaded)")
		t.ok(not SkyCheck.open(world, 6, FLOOR - 4, 5), "beside it, in the rock")
		unload(world)
		t.ok(SkyCheck.open(world, 5, FLOOR - 4, 5), "at the bottom of the shaft (its edits)")
		t.ok(SkyCheck.open(world, 5, FLOOR - 2, 5))
		t.ok(not SkyCheck.open(world, 5, FLOOR - 5, 5), "under the shaft's floor")
		t.ok(not SkyCheck.open(world, 6, FLOOR - 4, 5))
		-- Glass lets the sun through, leaves don't.
		world:setBlock(8, FLOOR + 2, 8, B.Glass)
		world:setBlock(9, FLOOR + 9, 8, B.OakLeaves)
		t.ok(SkyCheck.open(world, 8, FLOOR, 8), "under glass")
		t.ok(not SkyCheck.open(world, 9, FLOOR, 8), "under leaves")
		unload(world)
		t.ok(SkyCheck.open(world, 8, FLOOR, 8))
		t.ok(not SkyCheck.open(world, 9, FLOOR, 8))
		-- A roof edited above the loaded crop height grows the chunk; read either way.
		world:setBlock(12, 200, 12, STONE)
		t.ok(not SkyCheck.open(world, 12, FLOOR, 12))
		t.ok(SkyCheck.open(world, 12, 200, 12))
		unload(world)
		t.ok(not SkyCheck.open(world, 12, FLOOR, 12))
		-- Negative coordinates.
		world:setBlock(-3, FLOOR + 1, -20, STONE)
		unload(world)
		t.ok(not SkyCheck.open(world, -3, FLOOR, -20))
		t.ok(SkyCheck.open(world, -4, FLOOR, -20))
		t.eq(world.chunkCount, 0, "still nothing generated")
	end)

	t.test("sky check: generated terrain, loaded or not, differs only by trees and ice", function()
		local world = WorldServer.new(TerrainGenerator.new(12345))
		-- (A chunk of plains with a few oak trees.)
		local cx, cz = -8, -8
		local size = ChunkLayout.SIZE
		local unloaded: { [number]: boolean } = {}
		local below: { [number]: boolean } = {}
		local grounds: { [number]: number } = {}
		for lx = 0, size - 1 do
			for lz = 0, size - 1 do
				local x, z = cx * size + lx, cz * size + lz
				local ground = world.generator.column(x, z)
				grounds[lx * size + lz] = ground
				unloaded[lx * size + lz] = SkyCheck.open(world, x, ground, z)
				below[lx * size + lz] = SkyCheck.open(world, x, ground - 2, z)
			end
		end
		t.eq(world.chunkCount, 0, "the column heights generated no chunk")
		world:getChunk(cx, cz)
		local same, trees = 0, 0
		for lx = 0, size - 1 do
			for lz = 0, size - 1 do
				local i = lx * size + lz
				local x, z, ground = cx * size + lx, cz * size + lz, grounds[i]
				t.ok(unloaded[i], "nothing edited: the ground is open")
				t.ok(not below[i], "and under it is covered")
				t.ok(not SkyCheck.open(world, x, ground - 2, z), "loaded too")
				if SkyCheck.open(world, x, ground, z) then
					same += 1
				else
					-- Only a structure (or sea ice) covers the ground of a loaded chunk.
					local roof
					for y = ground, HEIGHT - 1 do
						local block = world:peekBlock(x, y, z) :: number
						if Blocks.isOpaque(block) then
							roof = Blocks.get(block).name
							break
						end
					end
					local name = roof or "?"
					t.ok(
						string.find(name, "Log") ~= nil
							or string.find(name, "Leaves") ~= nil
							or string.find(name, "Ice") ~= nil
							or name == "Cactus",
						`only trees and ice: {name}`
					)
					trees += 1
				end
			end
		end
		t.eq(same + trees, size * size)
		t.ok(same > size * size / 2, "most of the chunk sees the sky")
		t.ok(trees > 0, "trees cover some of it, once the chunk is loaded")
	end)

	--[[ What players see ]]

	t.test("solar panel: its panel: the status line, the upgrade slots and the energy bar", function()
		local container: any = Machines.newContainer(SOLAR)
		local panel = MenuLayout.panel(container)
		t.eq(panel.title, "Solar Panel")
		t.eq(#panel.slots, 2)
		t.eq(panel.slots[1].x, 8)
		t.eq(panel.slots[1].y, 53)
		t.eq(panel.slots[1].ghost, Upgrades.SPEED_GHOST)
		t.eq(panel.slots[2].x, 26)
		t.eq(panel.slots[2].y, 53)
		t.eq(panel.slots[2].ghost, Upgrades.ENERGY_GHOST)
		t.eq(panel.progress, nil)
		t.eq(panel.flame, nil)
		t.eq((panel.energy :: any).x, 164, "Mekanism's power bar")
		t.eq((panel.status :: any).x, 8)
		t.eq((panel.status :: any).y, 20)
		t.eq(MenuLayout.statusText(container), "Idle")
		tick(container, NOON, true)
		t.eq(MenuLayout.statusText(container), "Producing 50 J/t")
		tick(container, MIDNIGHT, true)
		t.eq(MenuLayout.statusText(container), "Night")
		t.eq(MenuLayout.panelKey(container), `machine:{SOLAR}:2`)
		-- The F3 lines name its kind.
		local details = WailaInfo.machineDetails(SOLAR, WailaInfo.machineDefaults(SOLAR))
		t.eq(WailaInfo.text(details[1]), "Machine solar (producer)")
		t.ok(Types.MAX_CONTAINER_DATA >= Machines.HEADER + 1)
	end)
end

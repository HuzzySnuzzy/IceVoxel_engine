--[[
	The Metal Miner (Shared/Machines/Kinds/Miner, Machines/MinerRules; BlockList MetalMiner): the
	block, its frozen layout and `info`; every ore's drop, time and energy; Mekanism's card maths
	with the floor at every card count (coal never pays: measured against the real Heat
	Generator's coal and Block of Coal, and in a closed loop on the real worlds); no ore, another
	block, an ore mined away or replaced mid-cycle; an unknown (unloaded) cell below keeps it
	mining; a full output stops it; energy starvation (the progress waits, a Heat Generator's
	200 J/t runs a diamond miner a tick in four and it glows steadily); its drops pushed into a
	chest and taken by a transporter on the real MachineWorld and TransmitterWorld; its energy
	kept in its item; switched off it is inert; its panel lines, status and WAILA; the client's
	glow and drill loop (and the Ammo Press's window and stamp).
]]

local Loader = require("../lib/Loader")

return function(t, shared, require, server, client)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local Coords = require(shared.World.Coords)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local MinerRules = require(shared.Machines.MinerRules)
	local Upgrades = require(shared.Machines.Upgrades)
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
	local MenuLayout = require(client.Ui.MenuLayout)
	local WailaInfo = require(client.Ui.WailaInfo)

	local B, I = Blocks.id, Items.id
	local AIR = Blocks.AIR
	local Y = 64
	local MINER = B.MetalMiner
	local ENERGY, ACTIVE = Machines.ENERGY, Machines.ACTIVE
	local STATE = MinerRules.STATE
	local CAPACITY = Config.Miner.Capacity
	local QUANTUM = Machines.QUANTUM
	-- Slots.
	local OUTPUT, SPEED, ENERGY_CARDS = 1, 2, 3

	-- The design's table (turrets design §9): drop, ticks, J a tick, floor, an item every.
	local TABLE = {
		CoalOre = { drop = I.Coal, ticks = 600, joules = 800, floor = 400000, every = "0:30" },
		IronOre = { drop = I.RawIron, ticks = 400, joules = 200, floor = 0, every = "0:20" },
		OsmiumOre = { drop = I.RawOsmium, ticks = 400, joules = 200, floor = 0, every = "0:20" },
		GoldOre = { drop = I.RawGold, ticks = 800, joules = 300, floor = 0, every = "0:40" },
		EmeraldOre = { drop = I.Emerald, ticks = 3600, joules = 800, floor = 0, every = "3:00" },
		DiamondOre = { drop = I.Diamond, ticks = 4800, joules = 800, floor = 0, every = "4:00" },
	}

	local function S(item: number, count: number)
		return { item = item, count = count }
	end

	-- The cell under a miner at (0, Y, 0): `cell.block` (nil: unknown, an unloaded chunk's).
	type Cell = { block: number? }

	local function ctx(cell: Cell): any
		return {
			block = MINER,
			x = 0,
			y = Y,
			z = 0,
			energy = Machines.energyOf(MINER),
			tick = 1,
			dayTime = 6000,
			getBlock = function(x: number, y: number, z: number): number?
				if x == 0 and y == Y - 1 and z == 0 then
					return cell.block
				end
				return AIR
			end,
		}
	end

	local function tick(container: any, cell: Cell, n: number?)
		for _ = 1, n or 1 do
			Machines.tick(container, ctx(cell))
		end
	end

	local function field(container: any, name: string): number
		return Machines.get(container, name)
	end

	local function status(container: any): string?
		return Machines.status(MINER, Machines.view(container))
	end

	-- A fresh miner holding `energy` J, with `speed` and `energy` cards.
	local function miner(energy: number, speed: number?, cards: number?): any
		local container: any = Machines.newContainer(MINER)
		container.data[ENERGY] = energy
		if speed and speed > 0 then
			container.slots[SPEED] = S(I.SpeedUpgrade, speed)
		end
		if cards and cards > 0 then
			container.slots[ENERGY_CARDS] = S(I.EnergyUpgrade, cards)
		end
		return container
	end

	--[[
		Ticks a miner kept full (a creative cube's way) until an item comes out, at most `limit`
		ticks: (ticks it took, J it used).
	]]
	local function untilItem(container: any, cell: Cell, limit: number): (number, number)
		local before = if container.slots[OUTPUT] then container.slots[OUTPUT].count else 0
		local ticks, used = 0, 0
		repeat
			container.data[ENERGY] = Machines.capacity(container)
			local had = Machines.energy(container)
			tick(container, cell)
			ticks += 1
			t.eq(had - Machines.energy(container), -field(container, "rate"), "RATE is what it used")
			used -= field(container, "rate")
			local now = if container.slots[OUTPUT] then container.slots[OUTPUT].count else 0
		until now > before or ticks >= limit
		return ticks, used
	end

	--[[ The block ]]

	t.test("miner: the block, its kind, the frozen layout and info", function()
		local def = Blocks.get(MINER)
		t.eq(Items.displayName(MINER), "Metal Miner")
		t.eq(def.decor, "MetalMiner")
		t.eq(def.menu, "Machine", "right click opens its panel")
		t.ok(Machines.isMachine(MINER))
		t.eq((Machines.kindOf(MINER) :: any).name, "miner")
		t.eq(Machines.role(MINER), "consumer", "input only")
		local energy = Machines.energyOf(MINER) :: any
		t.eq(energy.capacity, CAPACITY, "200 kJ")
		t.eq(energy.input, CAPACITY)
		t.eq(Machines.containerSize(MINER), 3, "the output and two card slots")
		t.ok(Transmitters.isEnergyAcceptor(MINER), "cables connect to it")
		t.ok(Transmitters.isItemAcceptor(MINER), "transporters too")
		local kind = Machines.kindOf(MINER) :: any
		local names = { "progress", "ticksRequired", "energyPerTick", "mining", "state", "activeDelay" }
		for i, name in names do
			t.eq(kind.index[name], Machines.HEADER + i, `{name} is field {Machines.HEADER + i}`)
		end
		t.eq(kind.size, 12)
		t.ok(kind.size <= Types.MAX_CONTAINER_DATA)
		t.eq(#kind.keep, 0, "only its energy goes into its item")
		t.eq(kind.state, Machines.HEADER + 5)
		-- Transporters take the output through every face and never reach the cards.
		for face = 0, 5 do
			t.eq(table.concat(Machines.extractSlots(MINER, face), ","), "1", `face {face}: the output`)
			t.eq(#Machines.insertSlots(MINER, face), 0, `face {face}: nothing goes in`)
		end
		t.ok(not Machines.mayPlace(MINER, OUTPUT, I.Diamond), "the output is only taken from")
		t.ok(
			Machines.mayPlace(MINER, SPEED, I.SpeedUpgrade) and Machines.mayPlace(MINER, ENERGY_CARDS, I.EnergyUpgrade)
		)
		t.ok(not Machines.mayPlace(MINER, SPEED, I.EnergyUpgrade), "each card its own slot")
		-- JEI's Duplicating reads these.
		local info = Machines.info(MINER)
		t.eq(info.capacity, CAPACITY)
		for _, ore in MinerRules.ORES do
			local row = TABLE[ore.name]
			t.eq(ore.drop, row.drop, `{ore.name}'s drop`)
			t.eq(Items.blockDrops(ore.block).item, ore.drop, `{ore.name}: Items.blockDrops`)
			t.eq(info[`{ore.name}Ticks`], row.ticks)
			t.eq(info[`{ore.name}Joules`], row.joules)
			t.eq(info[`{ore.name}Floor`], row.floor)
		end
		-- A fresh one: nothing seen yet; the first tick over nothing says so.
		local container = Machines.newContainer(MINER)
		t.eq(status(container), "Idle")
		t.eq(Machines.energy(container), 0)
		t.eq(Machines.capacity(container), CAPACITY)
		local input, output = Machines.rates(container)
		t.eq(input, CAPACITY, "Mekanism's machines take up to their capacity a tick")
		t.eq(output, 0)
	end)

	--[[ Mining ]]

	t.test("miner: every ore's drop, time and energy (one item each, its ore's numbers)", function()
		for _, ore in MinerRules.ORES do
			local row = TABLE[ore.name]
			local container = miner(0)
			local cell = { block = ore.block }
			local ticks, used = untilItem(container, cell, row.ticks + 10)
			t.eq(ticks, row.ticks, `{ore.name}: {row.ticks} ticks an item`)
			t.eq(used, row.ticks * row.joules, `{ore.name}: {row.joules} J a tick`)
			local out = container.slots[OUTPUT]
			t.ok(out and out.item == row.drop and out.count == 1, `{ore.name} gives one {Items.displayName(row.drop)}`)
			t.ok(out.item ~= ore.block, "its drop, never the ore")
			t.eq(field(container, "progress"), 0, "and starts the next")
			t.eq(field(container, "mining"), ore.block)
			t.eq(field(container, "ticksRequired"), row.ticks)
			t.eq(field(container, "energyPerTick"), row.joules)
			t.eq(Machines.view(container).state, MinerRules.packState(STATE.MINING, ore.index))
			t.eq(status(container), `Mining {Items.displayName(ore.block)}`)
			t.eq(container.data[ACTIVE], 1, "its grille glows")
			local lines = MenuLayout.lineTexts(container)
			t.eq(#lines, 2)
			t.eq(lines[1], `Makes {Items.displayName(row.drop)}`)
			t.eq(lines[2], `{row.every} an item`, `{ore.name}: the design's "an item every"`)
			-- The next one takes as long.
			local again, usedAgain = untilItem(container, cell, row.ticks + 10)
			t.eq(again, row.ticks)
			t.eq(usedAgain, used)
			t.eq(container.slots[OUTPUT].count, 2)
		end
		t.eq(#MinerRules.ORES, 6, "every ore block BlockList has")
	end)

	t.test("miner: Mekanism's card maths at every count, never under an ore's floor", function()
		local floored = 0
		for _, ore in MinerRules.ORES do
			for speed = 0, Upgrades.MAX do
				for energy = 0, Upgrades.MAX do
					local ticks, ept, capacity = MinerRules.settings(ore, speed, energy, CAPACITY)
					local raw = Upgrades.energyPerTick(ore.joules, speed, energy)
					t.eq(ticks, Upgrades.ticks(ore.ticks, speed), "Upgrades.ticks")
					t.eq(capacity, Upgrades.capacity(CAPACITY, energy), "Upgrades.capacity")
					-- What an item really costs: the J a tick rounded up, as Core.use takes it.
					local item = ticks * Machines.quantiseUp(ept)
					if ore.floor > 0 and raw * ticks < ore.floor then
						floored += 1
						t.eq(ept, Machines.quantiseUp(ore.floor / ticks), "the floor over its ticks, whole quanta")
						t.ok(item >= ore.floor, `{ore.name} {speed}/{energy}: {item} J an item, at least its floor`)
						t.ok(item < ore.floor + ticks * QUANTUM, "and at most a quantum a tick more")
					else
						t.eq(ept, raw, "Upgrades.energyPerTick")
					end
					t.ok(item >= ore.floor, `{ore.name} {speed}/{energy}: never under {ore.floor} J`)
					t.ok(ept <= capacity, "a tick's energy fits its store")
				end
			end
		end
		t.eq(floored, 36, "coal's floor holds wherever Energy Upgrades outnumber Speed Upgrades")
		-- The design's examples: 8 Speed and 8 Energy Upgrades on diamond, 8 Speed alone.
		local diamond = MinerRules.ORES[6]
		local ticks, ept, capacity = MinerRules.settings(diamond, 8, 8, CAPACITY)
		t.eq(ticks, 480, "a diamond every 24 s")
		t.near(ept, 8000, 1e-9, "at 8 kJ/t")
		t.near(ticks * ept, 3840000, 1e-6, "the same 3.84 MJ an item")
		t.near(capacity, 2000000, 1e-6, "a 2 MJ store")
		local _, fast = MinerRules.settings(diamond, 8, 0, CAPACITY)
		t.near(fast, 80000, 1e-9, "8 Speed alone: 80 kJ/t")
		t.ok(fast <= CAPACITY, "within the 200 kJ store")
		-- Iron for the Ammo Press: one Heat Generator's 200 J/t, 3 Raw Iron a minute.
		local iron = MinerRules.ORES[2]
		local ironTicks, ironJoules = MinerRules.settings(iron, 0, 0, CAPACITY)
		t.eq(ironJoules, 200)
		t.eq(60 * 20 / ironTicks, 3)
	end)

	t.test("miner: the cards on a real tick run; taking them out applies at once", function()
		local cell = { block = B.DiamondOre }
		local container = miner(0, 8, 8)
		local ticks, used = untilItem(container, cell, 5000)
		t.eq(ticks, 480, "8 Speed and 8 Energy Upgrades: 480 ticks")
		t.eq(used, 480 * 8000, "3.84 MJ")
		t.near(Machines.capacity(container), 2000000, 1e-6)
		t.eq(field(container, "energyPerTick"), Upgrades.energyPerTick(800, 8, 8))
		t.eq(MenuLayout.lineTexts(container)[2], "0:24 an item")
		-- 300 ticks into the next, the speed cards come out: 4800 ticks again, at 80 J/t.
		for _ = 1, 300 do
			container.data[ENERGY] = Machines.capacity(container)
			tick(container, cell)
		end
		t.eq(field(container, "progress"), 300)
		container.slots[SPEED] = nil
		container.data[ENERGY] = Machines.capacity(container)
		tick(container, cell)
		t.eq(field(container, "ticksRequired"), 4800)
		t.eq(field(container, "progress"), 301, "the progress goes on")
		t.eq(field(container, "rate"), -Machines.quantiseUp(Upgrades.energyPerTick(800, 0, 8)))
		-- The energy cards out: the store is 200 kJ again, what was over it lost (setMaxEnergy).
		container.slots[ENERGY_CARDS] = nil
		container.data[ENERGY] = 1500000
		tick(container, cell)
		t.eq(Machines.capacity(container), CAPACITY)
		t.eq(Machines.energy(container), CAPACITY - 800, "cut to 200 kJ before the tick's 800 J")
		-- A full arrow (more cards took the ticks below the progress) finishes on the next tick.
		local quick = miner(CAPACITY)
		tick(quick, { block = B.IronOre }, 300)
		quick.slots[SPEED] = S(I.SpeedUpgrade, 8)
		tick(quick, { block = B.IronOre })
		t.eq(quick.slots[OUTPUT] and quick.slots[OUTPUT].item, I.RawIron, "300 is past 40: done")
		t.eq(field(quick, "progress"), 0)
		-- One card: 299 ticks (Upgrades.ticks truncates), shown in tenths.
		local one = miner(CAPACITY, 1)
		tick(one, { block = B.IronOre })
		t.eq(field(one, "ticksRequired"), 299)
		t.eq(MenuLayout.lineTexts(one)[2], "0:14.9 an item")
	end)

	--[[ Coal never pays ]]

	-- J the real Heat Generator makes from one `item` (taken out as it is made).
	local function generatorJoules(item: number): number
		local generator: any = Machines.newContainer(B.HeatGenerator)
		generator.slots[1] = S(item, 1)
		local made, ticks = 0, 0
		local gctx = {
			block = B.HeatGenerator,
			x = 10,
			y = Y,
			z = 10,
			energy = Machines.energyOf(B.HeatGenerator),
			tick = 1,
			dayTime = 6000,
			getBlock = function(): number?
				return AIR
			end,
		}
		repeat
			Machines.tick(generator, gctx :: any)
			made += field(generator, "rate")
			generator.data[ENERGY] = 0
			ticks += 1
		until field(generator, "rate") == 0 or ticks > 40000
		return made
	end

	t.test("miner: coal never pays: a coal costs more than the Heat Generator makes of it", function()
		local coal = generatorJoules(I.Coal)
		t.eq(coal, 320000, "a coal is 320 kJ in a Heat Generator")
		local block = generatorJoules(I.CoalBlock)
		t.eq(block, Smelting.fuel(I.CoalBlock) * 200, "a Block of Coal 3.2 MJ")
		local perCoal = block / 9
		t.ok(perCoal > coal, "nine coal burn better as a block")
		-- The cheapest coal the miner makes, at any card count.
		local cheapest = math.huge
		local ore = MinerRules.ore(B.CoalOre) :: any
		for speed = 0, 8 do
			for energy = 0, 8 do
				local ticks, ept = MinerRules.settings(ore, speed, energy, CAPACITY)
				cheapest = math.min(cheapest, ticks * Machines.quantiseUp(ept))
			end
		end
		t.eq(cheapest, 400000, "the floor: 400 kJ a coal")
		t.ok(cheapest > perCoal, `400 kJ > {perCoal} J a coal in a block`)
		t.ok(cheapest * 9 >= 1.125 * block and cheapest >= 1.25 * coal, "12.5 % over the block, 25 % over a coal")
		-- The Combustion Generator burns only the refinery's fuel: no slot takes a coal.
		t.eq(Machines.containerSize(B.CombustionGenerator), 0, "no slots")
		t.eq(#Machines.insertSlots(B.CombustionGenerator, 1), 0)
	end)

	--[[ On the server ]]

	--[[
		Machines, chests and transporters in a world of blocks (air elsewhere, nil in `unknown`
		cells: an unloaded chunk's), stepped as the server does.
	]]
	local function sim()
		local blocks: { [number]: number } = {}
		local unknown: { [number]: boolean } = {}
		local containers = Containers.new()
		local function getBlock(x: number, y: number, z: number): number?
			local key = Coords.posKey(x, y, z)
			if unknown[key] then
				return nil
			end
			return blocks[key] or AIR
		end
		local pipes = TransmitterWorld.new({ getBlock = getBlock, containers = containers })
		local world = MachineWorld.new({
			getBlock = getBlock,
			containers = containers,
			transmitters = pipes,
			dayTime = function()
				return 6000
			end,
		})
		local self: any = { pipes = pipes, world = world, containers = containers }
		function self.set(x: number, y: number, z: number, block: number)
			local key = Coords.posKey(x, y, z)
			local old = blocks[key] or AIR
			blocks[key] = if block == AIR then nil else block
			TransmitterWorld.blockChanged(pipes, x, y, z, old, block)
			MachineWorld.blockChanged(world, x, y, z, old, block)
		end
		-- The cell's chunk unloads (nil to the machines) or loads again.
		function self.unload(x: number, y: number, z: number, gone: boolean)
			unknown[Coords.posKey(x, y, z)] = if gone then true else nil
		end
		function self.step(n: number?)
			for _ = 1, n or 1 do
				TransmitterWorld.step(pipes)
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
		function self.count(x: number, y: number, z: number, item: number): number
			local container = containers:peek(x, y, z)
			local total = 0
			if container then
				for _, stack in container.slots do
					if stack and stack.item == item then
						total += stack.count
					end
				end
			end
			return total
		end
		return self
	end

	t.test("miner: a Heat Generator burning coal into a coal miner gets less coal back", function()
		local s = sim()
		s.set(0, Y - 1, 0, B.CoalOre)
		s.set(0, Y, 0, MINER)
		s.set(1, Y, 0, B.BasicUniversalCable)
		s.set(2, Y, 0, B.HeatGenerator)
		local container, generator = s.container(0, Y, 0), s.container(2, Y, 0)
		-- The cheapest coal there is: 7 Speed and 8 Energy Upgrades, 80 ticks at 5 kJ a tick.
		container.slots[SPEED] = S(I.SpeedUpgrade, 7)
		container.slots[ENERGY_CARDS] = S(I.EnergyUpgrade, 8)
		generator.slots[1] = S(I.Coal, 64)
		local ticks = 32000
		local made = 0
		for _ = 1, ticks do
			s.step()
			made += field(generator, "rate")
		end
		local burnt = 64 - generator.slots[1].count
		local mined = s.count(0, Y, 0, I.Coal)
		t.eq(made, ticks * 200, "the generator never stopped")
		t.eq(burnt, 21, "20 coal burnt and the 21st lit")
		t.eq(field(container, "ticksRequired"), 80)
		t.eq(field(container, "energyPerTick"), 5000)
		t.ok(mined <= made / 400000, `{mined} coal mined: at most a coal for 400 kJ`)
		t.eq(mined, 15, "15 coal back for 20 burnt (the 16th on its way)")
		t.ok(mined < burnt * 320000 / 400000, "less coal back than burnt, at its best")
	end)

	t.test("miner: no ore, another block, an ore mined away or replaced mid-cycle", function()
		for _, block in { AIR, B.Stone, B.CoalBlock, B.IronBlock, MINER, B.Chest } do
			local container = miner(CAPACITY)
			tick(container, { block = block }, 5)
			t.eq(Machines.energy(container), CAPACITY, `{Items.displayName(block)}: nothing used`)
			t.eq(Machines.view(container).state, MinerRules.packState(STATE.NO_ORE, 0))
			t.eq(status(container), "No ore below")
			t.eq(field(container, "progress"), 0)
			t.eq(field(container, "mining"), 0)
			t.eq(field(container, "ticksRequired"), 0, "no arrow")
			t.eq(container.slots[OUTPUT], nil)
			t.eq(container.data[ACTIVE], 0)
			t.eq(#MenuLayout.lineTexts(container), 0, "no lines")
		end
		-- Mined away 100 ticks in: it stops at once and starts over.
		local cell = { block = B.IronOre }
		local container = miner(CAPACITY)
		tick(container, cell, 100)
		t.eq(field(container, "progress"), 100)
		cell.block = AIR
		local before = Machines.energy(container)
		tick(container, cell)
		t.eq(Machines.energy(container), before, "nothing used")
		t.eq(field(container, "progress"), 0)
		t.eq(field(container, "mining"), 0)
		t.eq(status(container), "No ore below")
		cell.block = B.IronOre
		tick(container, cell)
		t.eq(field(container, "progress"), 1, "back on it: from the start")
		-- Replaced by another ore mid-cycle: starts over on the new one at its numbers.
		tick(container, cell, 200)
		t.eq(field(container, "progress"), 201)
		cell.block = B.GoldOre
		before = Machines.energy(container)
		tick(container, cell)
		t.eq(field(container, "progress"), 1)
		t.eq(field(container, "mining"), B.GoldOre)
		t.eq(field(container, "ticksRequired"), 800)
		t.eq(before - Machines.energy(container), 300, "gold's 300 J a tick")
		t.eq(status(container), "Mining Gold Ore")
		container.data[ENERGY] = CAPACITY
		local ticks = untilItem(container, cell, 1000)
		t.eq(ticks, 799, "800 in all")
		t.eq(container.slots[OUTPUT].item, I.RawGold)
		-- Data from elsewhere: a progress past the end finishes, a forged ore seen is ignored.
		local forged = miner(CAPACITY)
		Machines.set(forged, "mining", B.DiamondOre)
		Machines.set(forged, "progress", 1e12)
		tick(forged, { block = B.DiamondOre })
		t.eq(forged.slots[OUTPUT] and forged.slots[OUTPUT].item, I.Diamond, "a full arrow finishes on the next tick")
		local garbage = miner(CAPACITY)
		Machines.set(garbage, "mining", 12345.5)
		Machines.set(garbage, "progress", -40.5)
		tick(garbage, { block = nil })
		t.eq(status(garbage), "No ore below", "nothing it knows")
		t.eq(field(garbage, "mining"), 0)
	end)

	t.test("miner: an unknown (unloaded) cell below keeps it mining what it mined", function()
		local cell: Cell = { block = B.IronOre }
		local container = miner(CAPACITY)
		tick(container, cell)
		cell.block = nil
		local ticks = untilItem(container, cell, 1000)
		t.eq(ticks, 399, "on the ore it saw: 400 ticks in all")
		t.eq(container.slots[OUTPUT].item, I.RawIron)
		t.eq(field(container, "mining"), B.IronOre)
		t.eq(status(container), "Mining Iron Ore")
		-- A fresh one over an unknown cell has seen nothing.
		local fresh = miner(CAPACITY)
		tick(fresh, { block = nil }, 3)
		t.eq(status(fresh), "No ore below")
		t.eq(Machines.energy(fresh), CAPACITY)
		-- On the server: the chunk unloads with nobody near and the miner goes on into its chest.
		local s = sim()
		s.set(0, Y - 1, 0, B.DiamondOre)
		s.set(0, Y, 0, MINER)
		s.set(0, Y + 1, 0, B.CreativeEnergyCube)
		s.set(1, Y, 0, B.Chest)
		local server = s.container(0, Y, 0)
		server.slots[SPEED] = S(I.SpeedUpgrade, 8)
		server.slots[ENERGY_CARDS] = S(I.EnergyUpgrade, 8)
		s.step(10)
		s.unload(0, Y - 1, 0, true)
		-- (Its first tick had no energy yet: diamonds at 481, 961 and 1441, pushed at 1450.)
		s.step(480 * 3)
		t.eq(s.count(1, Y, 0, I.Diamond), 3, "three diamonds while the ore was out of sight")
		t.eq(s.record(0, Y, 0).state, MinerRules.packState(STATE.MINING, 6))
		-- An edit there is always known: mined out, it stops.
		s.unload(0, Y - 1, 0, false)
		s.set(0, Y - 1, 0, AIR)
		s.step(5)
		t.eq(s.record(0, Y, 0).state, MinerRules.packState(STATE.NO_ORE, 0))
		t.eq(s.record(0, Y, 0).active, false, "dark at once: it stopped for good")
	end)

	t.test("miner: a full output stops it, nothing used; with room it goes on", function()
		local cell = { block = B.DiamondOre }
		local container = miner(CAPACITY)
		tick(container, cell, 10)
		container.slots[OUTPUT] = S(I.Diamond, 64)
		local before = Machines.energy(container)
		tick(container, cell, 20)
		t.eq(Machines.energy(container), before, "nothing used")
		t.eq(field(container, "progress"), 10, "the progress waits")
		t.eq(Machines.view(container).state, MinerRules.packState(STATE.OUTPUT_FULL, 6))
		t.eq(status(container), "Output full")
		t.eq(field(container, "rate"), 0)
		-- Something else in the output (coal from the ore it mined before): full too.
		container.slots[OUTPUT] = S(I.Coal, 1)
		tick(container, cell)
		t.eq(status(container), "Output full")
		-- 63: one more fits, then it is full.
		container.slots[OUTPUT] = S(I.Diamond, 63)
		Machines.set(container, "progress", 4799)
		tick(container, cell)
		t.eq(container.slots[OUTPUT].count, 64)
		tick(container, cell)
		t.eq(status(container), "Output full")
		t.eq(field(container, "progress"), 0)
		-- Taken out: on it goes.
		container.slots[OUTPUT] = nil
		tick(container, cell)
		t.eq(status(container), "Mining Diamond Ore")
		t.eq(field(container, "progress"), 1)
	end)

	t.test("miner: without power the progress waits; a 200 J/t generator runs it a tick in four", function()
		local cell = { block = B.DiamondOre }
		local container = miner(2000)
		tick(container, cell, 5)
		t.eq(field(container, "progress"), 2, "two ticks of 800 J")
		t.eq(Machines.energy(container), 400, "the rest waits: all or nothing")
		t.eq(Machines.view(container).state, MinerRules.packState(STATE.NO_POWER, 6))
		t.eq(status(container), "No power")
		t.eq(#MenuLayout.lineTexts(container), 2, "it still says what it makes")
		container.data[ENERGY] = 800
		tick(container, cell)
		t.eq(field(container, "progress"), 3, "and goes on when energy comes")
		-- A Heat Generator's 200 J/t through a cable: 800 J/t wanted, a tick in four, glowing steadily.
		local s = sim()
		s.set(0, Y - 1, 0, B.DiamondOre)
		s.set(0, Y, 0, MINER)
		s.set(1, Y, 0, B.BasicUniversalCable)
		s.set(2, Y, 0, B.HeatGenerator)
		local server, generator = s.container(0, Y, 0), s.container(2, Y, 0)
		generator.slots[1] = S(I.Coal, 4)
		local made, used, dark = 0, 0, 0
		for i = 1, 2000 do
			s.step()
			made += field(generator, "rate")
			used -= field(server, "rate")
			for _, record in MachineWorld.takeRecords(s.world) do
				if record.x == 0 and record.y == Y and not record.active and i > 10 then
					dark += 1
				end
			end
		end
		t.eq(made, 2000 * 200)
		t.eq(made, used + Machines.energy(server) + Machines.energy(generator), "made = used + stored")
		t.ok(math.abs(field(server, "progress") - 500) <= 1, `a tick in four: {field(server, "progress")}`)
		t.eq(dark, 0, "its record never blinked off")
		t.eq(s.record(0, Y, 0).active, true)
	end)

	t.test("miner: its drops go into a chest next to it and down a transporter line", function()
		-- Into a chest beside it (Mekanism's ejector, every 10 ticks).
		local s = sim()
		s.set(0, Y - 1, 0, B.IronOre)
		s.set(0, Y, 0, MINER)
		s.set(0, Y + 1, 0, B.CreativeEnergyCube)
		s.set(1, Y, 0, B.Chest)
		local container = s.container(0, Y, 0)
		container.slots[SPEED] = S(I.SpeedUpgrade, 8)
		container.slots[ENERGY_CARDS] = S(I.EnergyUpgrade, 8)
		-- (Its first tick had no energy yet: items at 41, 81 ... 401, pushed at 410.)
		s.step(410)
		t.eq(s.count(1, Y, 0, I.RawIron), 10, "an item every 40 ticks, all pushed out")
		t.eq(container.slots[OUTPUT], nil)
		t.eq(s.count(1, Y, 0, I.SpeedUpgrade) + s.count(1, Y, 0, I.EnergyUpgrade), 0, "never its cards")
		t.eq(container.slots[SPEED].count, 8)
		-- Down two Basic transporters into a chest (their NORMAL side takes what it makes).
		local p = sim()
		p.set(0, Y - 1, 0, B.IronOre)
		p.set(0, Y, 0, MINER)
		p.set(0, Y + 1, 0, B.CreativeEnergyCube)
		p.set(-1, Y, 0, B.BasicLogisticalTransporter)
		p.set(-2, Y, 0, B.BasicLogisticalTransporter)
		p.set(-3, Y, 0, B.Chest)
		local piped = p.container(0, Y, 0)
		piped.slots[SPEED] = S(I.SpeedUpgrade, 8)
		piped.slots[ENERGY_CARDS] = S(I.EnergyUpgrade, 8)
		p.step(610)
		local arrived = p.count(-3, Y, 0, I.RawIron)
		local left = if piped.slots[OUTPUT] then piped.slots[OUTPUT].count else 0
		t.eq(arrived + left + p.pipes.itemCount, 15, "15 made: arrived, waiting or on the way")
		t.ok(arrived >= 13, `{arrived} arrived`)
		-- The ore mined away: what it made all arrives.
		p.set(0, Y - 1, 0, AIR)
		p.step(200)
		t.eq(p.count(-3, Y, 0, I.RawIron), 15)
		t.eq(p.pipes.itemCount, 0, "nothing left on the way")
		t.eq(piped.slots[OUTPUT], nil)
	end)

	t.test("miner: keeps its energy in its item, not its progress or the ore it saw", function()
		local s = sim()
		local registry = EditRules.newBlockData()
		registry:add(TransmitterWorld.blockDataHooks(s.pipes))
		registry:add(MachineWorld.blockDataHooks(s.world))
		s.set(0, Y - 1, 0, B.DiamondOre)
		s.set(0, Y, 0, MINER)
		local container = s.container(0, Y, 0)
		container.data[ENERGY] = 150000
		s.step(10)
		t.eq(field(container, "progress"), 10)
		local drop = EditRules.breakDrop(registry, 0, Y, 0, MINER, false, I.IronPickaxe) :: any
		s.set(0, Y, 0, AIR)
		t.eq(drop.item, MINER)
		t.eq(drop.data.energy, 150000 - 10 * 800)
		t.eq(drop.data.progress, nil, "its slots drop, so its progress goes")
		t.eq(drop.data.mining, nil)
		s.set(5, Y - 1, 0, B.GoldOre)
		s.set(5, Y, 0, MINER)
		registry:placed("p", 5, Y, 0, MINER, drop)
		local placed = s.container(5, Y, 0)
		t.eq(Machines.energy(placed), 150000 - 10 * 800)
		s.step()
		t.eq(field(placed, "progress"), 1, "a new start on what is under it now")
		t.eq(field(placed, "mining"), B.GoldOre)
		-- With Energy Upgrades it held more than a bare one holds: cut to 200 kJ when placed.
		s.set(7, Y, 0, MINER)
		registry:placed("p", 7, Y, 0, MINER, { item = MINER, count = 1, data = { energy = 1.5e6 } })
		t.eq(Machines.energy(s.container(7, Y, 0)), CAPACITY)
	end)

	t.test("miner: switched off it is inert (nothing used or made)", function()
		local env = Loader.new()
		local root = env.mount("src/shared", "ReplicatedStorage", "IceVoxel")
		local OffConfig = env.require(root.Config)
		OffConfig.Miner.Enabled = false
		local OffMachines = env.require(root.Machines)
		local OffBlocks = env.require(root.Blocks)
		local OffItems = env.require(root.Items)
		local block = OffBlocks.id.MetalMiner
		local container: any = OffMachines.newContainer(block)
		container.data[ENERGY] = 100000
		container.slots[SPEED] = { item = OffItems.id.SpeedUpgrade, count = 8 }
		local offCtx = {
			block = block,
			x = 0,
			y = Y,
			z = 0,
			energy = OffMachines.energyOf(block),
			tick = 1,
			dayTime = 6000,
			getBlock = function(): number?
				return OffBlocks.id.DiamondOre
			end,
		}
		for _ = 1, 1000 do
			OffMachines.tick(container, offCtx :: any)
		end
		t.eq(OffMachines.energy(container), 100000, "nothing used")
		t.eq(container.slots[OUTPUT], nil, "nothing made")
		t.eq(OffMachines.state(container), 0)
		t.eq(OffMachines.status(block, OffMachines.view(container)), "Idle")
		t.eq(OffMachines.get(container, "rate"), 0)
		t.eq(container.data[ACTIVE], 0, "dark")
		t.eq(OffMachines.isMachine(block), true, "the block stays a machine")
	end)

	--[[ What players see ]]

	t.test("miner: its panel, status line, two short lines and WAILA", function()
		local container = miner(CAPACITY)
		local panel = MenuLayout.panel(container)
		t.eq(panel.title, "Metal Miner")
		t.eq(#panel.slots, 3)
		t.ok(panel.slots[1].x == 116 and panel.slots[1].y == 35, "the output in its result frame")
		t.ok(panel.slots[2].x == 8 and panel.slots[2].y == 53, "the Speed Upgrades")
		t.ok(panel.slots[3].x == 26 and panel.slots[3].y == 53, "the Energy Upgrades")
		local progress = panel.progress :: any
		t.ok(progress.x == 79 and progress.y == 34, "the arrow")
		t.ok(panel.status.x == 8 and panel.status.y == 20)
		t.ok(panel.lines[1].x == 8 and panel.lines[1].y == 32, "the lines under the status")
		local second = panel.lines[2]
		t.ok(second.y + MenuLayout.LINE_TEXT <= panel.slots[2].y, "the second clears the cards")
		local third = panel.lines[3]
		t.ok(third == nil or third.y + MenuLayout.LINE_TEXT > panel.slots[2].y, "a third would be over them")
		-- Every line it can show is short (16 characters: about 64 pixels at the panel's small text,
		-- from x = 8, before the arrow at 79), and never more than two.
		local cell = { block = B.Stone }
		for _, ore in MinerRules.ORES do
			for speed = 0, 8 do
				local c = miner(CAPACITY, speed, 8)
				cell.block = ore.block
				tick(c, cell)
				local lines = MenuLayout.lineTexts(c)
				t.eq(#lines, 2, `{ore.name} with {speed} cards: two lines`)
				for _, line in lines do
					t.ok(utf8.len(line) <= 16, `"{line}" is short`)
				end
			end
		end
		-- The arrow fills over the item's ticks.
		cell.block = B.IronOre
		tick(container, cell, 200)
		t.eq(MenuLayout.machineArrowColumns(container.data, panel.progressSource), 12, "half way")
		t.eq(MenuLayout.statusText(container), "Mining Iron Ore")
		t.eq(table.concat(MenuLayout.lineTexts(container), " | "), "Makes Raw Iron | 0:20 an item")
		-- Without the window's data (no ticks known) only what it makes.
		local view = Machines.view(container)
		t.eq(table.concat(Machines.lines(MINER, view, nil), " | "), "Makes Raw Iron")
		-- WAILA: energy and the status, from the record.
		local facts = WailaInfo.machineDefaults(MINER)
		t.eq(WailaInfo.text(WailaInfo.machineLines(MINER, facts)[1]), "Energy: 0 J / 200 kJ")
		t.eq(WailaInfo.text(WailaInfo.machineLines(MINER, facts)[2]), "Idle")
		local states = {
			[MinerRules.packState(STATE.MINING, 6)] = "Mining Diamond Ore",
			[MinerRules.packState(STATE.MINING, 1)] = "Mining Coal Ore",
			[MinerRules.packState(STATE.NO_POWER, 6)] = "No power",
			[MinerRules.packState(STATE.OUTPUT_FULL, 3)] = "Output full",
			[MinerRules.packState(STATE.NO_ORE, 0)] = "No ore below",
		}
		for state, text in states do
			facts.state = state
			t.eq(WailaInfo.text(WailaInfo.machineLines(MINER, facts)[2]), text)
		end
		t.eq(WailaInfo.text(WailaInfo.machineDetails(MINER, facts)[1]), "Machine miner (consumer)")
		-- The state travels in Machines records (a byte: at most 3 + 8 x 6).
		local s = sim()
		s.set(0, Y - 1, 0, B.EmeraldOre)
		s.set(0, Y, 0, MINER)
		s.set(0, Y + 1, 0, B.CreativeEnergyCube)
		s.step(3)
		local record = s.record(0, Y, 0)
		local sent = (Protocol.decodeMachines(Protocol.encodeMachines({ record })) :: any)[1]
		t.eq(sent.state, MinerRules.packState(STATE.MINING, 5))
		t.eq(sent.active, true)
		t.eq(sent.rate, -800)
		t.ok(MinerRules.packState(STATE.NO_ORE, #MinerRules.ORES) <= Machines.MAX_STATE)
	end)

	t.test("miner: the client lights its grille and drills; the press lights its window and stamps", function()
		for name, window in { MetalMiner = BlockDecor.MINER_WINDOW, AmmoPress = BlockDecor.PRESS_WINDOW } do
			local block = B[name]
			t.ok(TransmitterModel.hasMachineBoxes(block), `{name}: a cell for its window`)
			local none, unlit = TransmitterModel.machineBoxes(block, nil)
			t.eq(#none, 0, `{name}: no record, dark`)
			local idle = TransmitterModel.machineBoxes(block, { active = false, energy = 5, capacity = 9 })
			t.eq(#idle, 0, `{name}: idle, dark`)
			local boxes, lit = TransmitterModel.machineBoxes(block, { active = true, energy = 0, capacity = 9 })
			t.eq(#boxes, 4, `{name}: a pane on each side`)
			t.ok(lit ~= unlit, "its signature changes")
			local depth = TransmitterModel.GLOW_DEPTH
			for _, box in boxes do
				t.eq(box.kind, "glow")
				t.eq(box.colour, TransmitterModel.glowColour(block))
				t.eq(box.size[2], window.h)
				t.eq(box.offset[2], 8 - (window.y + window.h / 2), "over its window")
				local normalAxis = if box.size[1] == depth then 1 else 3
				t.eq(box.size[4 - normalAxis], window.w)
				t.eq(math.abs(box.offset[normalAxis]), 8 + depth / 2, "out of the face")
			end
			t.eq(TransmitterModel.machineLight(block, { active = true, energy = 0, capacity = 9 }), nil, "no light")
		end
		-- The miner's grille yellow-orange, the press's die the furnace's orange.
		local yellow = TransmitterModel.glowColour(MINER)
		t.ok(yellow[1] == 255 and yellow[2] > TransmitterModel.GLOW_COLOUR[2] and yellow[3] < 100, "yellow-orange")
		t.eq(TransmitterModel.glowColour(B.AmmoPress), TransmitterModel.GLOW_COLOUR)
		-- The loops, while the record says it works (Audio/Ambience).
		t.eq(TransmitterModel.machineLoop(MINER), "block.metal_miner.drill")
		t.eq(TransmitterModel.machineLoop(B.AmmoPress), "block.ammo_press.stamp")
		t.eq(TransmitterModel.machineLoop(B.DiamondOre), nil)
		-- A working miner's own record lights it: the record's ACTIVE (its kind's showActive).
		local container = miner(CAPACITY)
		tick(container, { block = B.DiamondOre })
		local view = Machines.view(container)
		t.eq(#TransmitterModel.machineBoxes(MINER, view), 4, "mining: lit")
		local stopped = miner(CAPACITY)
		tick(stopped, { block = B.Stone })
		t.eq(#TransmitterModel.machineBoxes(MINER, Machines.view(stopped)), 0, "no ore: dark")
	end)
end

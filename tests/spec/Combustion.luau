--[[
	The Combustion Generator (Shared/Machines/Kinds/Combustion, BlockList CombustionGenerator): the
	block and its numbers, its fuel tank (fuel only, in through pipes and buckets, nothing out),
	making 2 500 J a tick with a mB burning for 4 ticks (a bucket is 10 MJ: 2.5 Lava Buckets or about
	31 coal in a Heat Generator), burning only what it has room for (part mB carried over, never a joule made or lost), sustained data,
	feeding a machine through the server's energy networks at up to 5 kJ/t, its panel, WAILA's
	lines, the decor and the recipe.
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
	local GENERATOR = B.CombustionGenerator
	local ENERGY = Machines.ENERGY
	-- 2 500 J a tick, a mB burning for 4 ticks (10 kJ), a 10 000 mB tank, 1 MJ stored, 5 kJ/t out.
	local MAKES, PER_MB, TANK, CAPACITY, OUTPUT = 2500, 10000, 10000, 1000000, 5000
	local FUEL = Fluids.FUEL
	FakeMachines.define(Machines, Items, Smelting)

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

	local function fuelled(mB: number): any
		local c: any = Machines.newContainer(GENERATOR)
		Machines.tankInsert(c, "fuel", FUEL, mB)
		return c
	end

	local function status(c: any): string?
		return Machines.status(GENERATOR, Machines.view(c))
	end

	t.test("combustion generator: the block, its kind, its fuel tank and numbers", function()
		local def = Blocks.get(GENERATOR)
		t.eq(Items.displayName(GENERATOR), "Combustion Generator")
		t.eq(def.hardness, 3.5)
		t.eq(def.tool, "pickaxe")
		t.eq(def.toolLevel, 0)
		t.eq(def.sound, "metal")
		t.eq(def.decor, "CombustionGenerator")
		t.eq(def.menu, "Machine")
		t.eq((Items.drops(GENERATOR, I.WoodenPickaxe) :: any).item, GENERATOR)
		t.eq((Machines.kindOf(GENERATOR) :: any).name, "combustion")
		t.eq(Machines.role(GENERATOR), "producer")
		local energy = Machines.energyOf(GENERATOR) :: any
		t.eq(energy.capacity, CAPACITY)
		t.eq(energy.output, OUTPUT, "twice what it makes")
		t.eq(energy.input, nil)
		t.eq(Machines.containerSize(GENERATOR), 0, "no slots")
		t.ok(Transmitters.isEnergyAcceptor(GENERATOR))
		t.ok(not Transmitters.isItemAcceptor(GENERATOR))
		local tanks = Machines.tanks(GENERATOR)
		t.eq(#tanks, 1)
		t.eq(tanks[1].name, "fuel")
		t.eq(tanks[1].role, "input")
		t.eq(tanks[1].capacity, TANK)
		t.eq(tanks[1].fluid, FUEL)
		t.ok(Machines.takesFluid(GENERATOR, FUEL))
		t.ok(not Machines.takesFluid(GENERATOR, Fluids.OIL), "oil must be refined first")
		t.ok(not Machines.takesFluid(GENERATOR, Fluids.LAVA))
		t.ok(not Machines.givesFluid(GENERATOR))
		t.eq(Machines.info(GENERATOR).fuelPerTick, 0.25)
		t.eq(Machines.info(GENERATOR).energyPerMb, PER_MB)
	end)

	t.test("combustion generator: 2.5 kJ/t, a mB every 4 ticks, a bucket is 10 MJ (2.5 lava, 31 coal)", function()
		local c = fuelled(1000)
		local made, ticks = 0, 0
		repeat
			tick(c)
			made += Machines.energy(c)
			c.data[ENERGY] = 0
			ticks += 1
			if ticks == 1 then
				t.eq(field(c, "rate"), MAKES)
				t.eq(field(c, "active"), 1)
				t.eq(status(c), "Producing 2.5 kJ/t")
				t.eq(Machines.tankAmount(c, "fuel"), 999)
			end
			if ticks <= 4 then
				t.eq(Machines.tankAmount(c, "fuel"), 999, `tick {ticks}: one mB burning`)
			elseif ticks == 5 then
				t.eq(Machines.tankAmount(c, "fuel"), 998, "the next mB")
			end
		until field(c, "rate") == 0 or ticks > 20000
		t.eq(ticks - 1, 4000, "a bucket burns for 4 000 ticks")
		t.eq(made, 10000000, "10 MJ")
		local heat = Machines.info(B.HeatGenerator)
		local coal = Smelting.fuel(I.Coal) * heat.heatGeneration
		local lava = 1000 / heat.lavaPerTick * heat.heatGeneration
		t.ok(math.abs(made / lava - 2.5) < 1e-9, `{made / lava} Lava Buckets in a Heat Generator`)
		t.ok(made / coal > 31 and made / coal < 31.5, `{made / coal} coal in a Heat Generator`)
		t.eq(field(c, "active"), 0)
		t.eq(status(c), "Idle")
	end)

	t.test("combustion generator: burns only what it has room for, never a joule lost", function()
		local c = fuelled(10)
		c.data[ENERGY] = CAPACITY - 1000
		tick(c)
		t.eq(Machines.energy(c), CAPACITY)
		t.eq(field(c, "rate"), 1000)
		t.eq(field(c, "burning"), 0.9, "a tenth of a mB burnt, the rest burns on")
		t.eq(Machines.tankAmount(c, "fuel"), 9)
		tick(c, 50)
		t.eq(Machines.tankAmount(c, "fuel"), 9, "full: no more is taken")
		t.eq(field(c, "rate"), 0)
		t.eq(field(c, "active"), 0)
		t.eq(field(c, "burning"), 0.9)
		c.data[ENERGY] = 0
		tick(c)
		t.eq(Machines.energy(c), MAKES, "a quarter of a mB a tick")
		t.eq(Machines.tankAmount(c, "fuel"), 9)
		t.eq(field(c, "burning"), 0.65)
		tick(c, 2)
		t.eq(field(c, "burning"), 0.15)
		c.data[ENERGY] = 0
		tick(c)
		t.eq(Machines.energy(c), MAKES, "the rest of the mB and part of the next")
		t.eq(Machines.tankAmount(c, "fuel"), 8)
		t.eq(field(c, "burning"), 0.9)
		-- Odd amounts of room, as a slow network takes it: exactly 10 kJ a mB in the end.
		local odd = fuelled(20)
		local total, steps = 0, 0
		repeat
			steps += 1
			local room = 1 + (steps * 337 % 3001) + (steps % 7) * Machines.QUANTUM
			odd.data[ENERGY] = CAPACITY - room
			tick(odd)
			local got = Machines.energy(odd) - (CAPACITY - room)
			t.ok(got <= room and got <= MAKES, "within its room and a tick")
			total += got
		until (field(odd, "rate") == 0 and Machines.tankAmount(odd, "fuel") == 0) or steps > 100000
		t.eq(total, 20 * PER_MB, "20 mB's energy, to the quantum")
		-- Data from elsewhere: at most one mB burning.
		local forged = fuelled(0)
		t.ok(Machines.restore(forged, { burning = 1e9 }))
		local made = 0
		repeat
			forged.data[ENERGY] = 0
			tick(forged)
			made += Machines.energy(forged)
		until field(forged, "rate") == 0
		t.eq(made, PER_MB, "one mB's worth")
		t.eq(field(forged, "burning"), 0)
	end)

	t.test("combustion generator: fuel comes in by pipe and bucket; nothing comes out", function()
		local c: any = Machines.newContainer(GENERATOR)
		t.eq(Machines.insertFluid(c, Fluids.OIL, 500), 0)
		t.eq(Machines.insertFluid(c, FUEL, 12000), TANK)
		t.ok(not Machines.pourBucket(c, FUEL), "full")
		local _, amount = Machines.extractFluid(c, 100)
		t.eq(amount, 0, "an input tank gives pipes nothing")
		t.eq(Machines.fillBucket(c), FUEL, "a player may take a bucket back")
		t.ok(Machines.pourBucket(c, FUEL))
		t.ok(not Machines.pourBucket(c, Fluids.WATER))
	end)

	t.test("combustion generator: its item keeps its energy, fuel and what is burning", function()
		local c = fuelled(3000)
		c.data[ENERGY] = CAPACITY - 1000
		tick(c)
		local data = Machines.save(c) :: any
		t.eq(data.energy, CAPACITY)
		t.eq(data.fuel, 2999)
		t.eq(data.burning, 0.9)
		local lines = Items.describe({ item = GENERATOR, count = 1, data = data })
		t.eq(lines[1], "Energy: 1 MJ")
		t.eq(lines[2], "Fuel: 2,999 mB")
		local placed: any = Machines.newContainer(GENERATOR)
		t.ok(Machines.restore(placed, data))
		t.eq(Machines.tankAmount(placed, "fuel"), 2999)
		t.eq(field(placed, "burning"), 0.9)
		t.eq(Machines.save(Machines.newContainer(GENERATOR)), nil, "a new one is a plain item")
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
		return self
	end

	t.test("combustion generator: feeds a machine through a cable at up to 5 kJ/t", function()
		FakeMachines.bind(Machines, {
			{ B.IronBlock, "test_consumer", { capacity = 1e8, input = 1e6 } },
		}, function()
			local s = sim()
			s.set(0, Y, 0, GENERATOR)
			s.set(1, Y, 0, B.BasicUniversalCable)
			s.set(2, Y, 0, B.IronBlock)
			local generator, consumer = s.container(0, Y, 0), s.container(2, Y, 0)
			Machines.tankInsert(generator, "fuel", FUEL, 1000)
			generator.data[ENERGY] = 100000
			s.step()
			t.eq(Machines.energy(consumer), OUTPUT, "5 kJ/t out of its store")
			t.eq(Machines.energy(generator), 100000 + MAKES - OUTPUT)
			-- With nothing stored, what it makes goes straight on.
			generator.data[ENERGY] = 0
			local before = Machines.energy(consumer)
			s.step()
			t.eq(Machines.energy(consumer) - before, MAKES)
			-- The whole bucket arrives, exactly.
			generator.data[ENERGY] = 0
			before = Machines.energy(consumer)
			s.step(4100)
			t.eq(Machines.energy(consumer) - before, 1000 * PER_MB - 2 * MAKES, "the rest of the bucket")
			t.eq(Machines.tankAmount(generator, "fuel"), 0)
		end)
	end)

	--[[ What players see ]]

	t.test("combustion generator: its panel (fuel gauge, status, energy bar) and WAILA", function()
		local c = fuelled(5000)
		local panel = MenuLayout.panel(c)
		t.eq(panel.title, "Combustion Generator")
		t.eq(#panel.slots, 0)
		local gauges = Machines.gauges(GENERATOR)
		t.eq(#gauges, 1)
		t.eq(gauges[1].name, "fuel")
		t.eq(gauges[1].x, 7)
		t.eq(gauges[1].y, 13)
		local statusAt = panel.status :: any
		t.ok(gauges[1].x + gauges[1].w < statusAt.x, "the status line right of the gauge")
		t.ok(gauges[1].y + gauges[1].h <= panel.height - 4)
		t.eq(Machines.gaugeLevel(c.data[gauges[1].amount], gauges[1].capacity, gauges[1].h - 2), 29, "half")
		tick(c)
		t.eq(MenuLayout.statusText(c), "Producing 2.5 kJ/t")
		local facts = WailaInfo.machineDefaults(GENERATOR)
		local lines = WailaInfo.machineLines(GENERATOR, facts)
		t.eq(WailaInfo.text(lines[1]), "Energy: 0 J / 1 MJ")
		t.eq(WailaInfo.text(lines[2]), "Idle")
		facts.rate, facts.active = MAKES, true
		t.eq(WailaInfo.text(WailaInfo.machineLines(GENERATOR, facts)[2]), "Producing 2.5 kJ/t")
	end)

	t.test("combustion generator: decor and recipe", function()
		local faces = BlockDecor.faces("CombustionGenerator") :: any
		t.ok(faces ~= nil)
		local window = BlockDecor.COMBUSTION_WINDOW
		for _, face in { "Front", "Back", "Left", "Right" } do
			local found = false
			for _, r in faces[face] do
				if r.x == window.x and r.y == window.y and r.w == window.w and r.h == window.h then
					found = true
				end
			end
			t.ok(found, `{face}: the combustion chamber's window`)
		end
		local parts = BlockDecor.partCount("CombustionGenerator")
		t.ok(parts > 0 and parts < 40, `item model slabs: {parts}`)
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
		local found = false
		for _, recipe in Crafting.recipes do
			if recipe.result == GENERATOR then
				found = true
			end
		end
		t.ok(found, "craftable")
	end)
end

--[[
	Electricity: Mekanism's Universal Cables (tiers, blocks, recipes, the connection rule with
	energy blocks, the client's thinner arms and WAILA lines) and the server's machines and energy
	networks (Machines/MachineWorld, EnergyNet): network building, Mekanism's even split, the
	cables' throughput, energy blocks touching without cables, exact conservation, batteries as
	backup (charge order, discharge), determinism, records, containers and sustained data.

	Machines here are test-only kinds (tests/lib/FakeMachines) bound to spare blocks: a producer,
	a consumer, a battery and an electric furnace with slots.
]]

local FakeMachines = require("../lib/FakeMachines")

return function(t, shared, require, server, client)
	local Blocks = require(shared.Blocks)
	local Coords = require(shared.World.Coords)
	local Crafting = require(shared.Crafting)
	local Hash = require(shared.Util.Hash)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local Protocol = require(shared.Net.Protocol)
	local Smelting = require(shared.Crafting.Smelting)
	local Transmitters = require(shared.Transmitters)
	local Types = require(shared.Inventory.Types)
	local Containers = require(server.Players.Containers)
	local InventoryState = require(server.Players.InventoryState)
	local EditRules = require(server.Network.EditRules)
	local TransmitterWorld = require(server.Transmitters.TransmitterWorld)
	local MachineWorld = require(server.Machines.MachineWorld)
	local EnergyNet = require(server.Machines.EnergyNet)
	local TransmitterModel = require(client.Rendering.TransmitterModel)
	local WailaInfo = require(client.Ui.WailaInfo)

	local B = Blocks.id
	local I = Items.id
	local AIR = B.Air
	local Y = 64
	local M = Transmitters.MODES
	local DOWN, UP, NORTH, SOUTH, WEST, EAST = 0, 1, 2, 3, 4, 5
	local TIER_NAMES = { "Basic", "Advanced", "Elite", "Ultimate" }
	local CABLES = {}
	for tier, name in TIER_NAMES do
		CABLES[tier] = B[`{name}UniversalCable`]
	end
	local CABLE = CABLES[1]
	local ENERGY, INPUT, OUTPUT = Machines.ENERGY, Machines.INPUT, Machines.OUTPUT
	local kinds = FakeMachines.define(Machines, Items, Smelting)

	-- Spare blocks for the fake kinds.
	local PRODUCER, CONSUMER, BATTERY, FURNACE, BROKEN =
		B.OsmiumBlock, B.IronBlock, B.GoldBlock, B.DiamondBlock, B.EmeraldBlock
	local DEFAULT_BINDINGS = {
		{ PRODUCER, "test_producer", { capacity = 100000, output = 400 } },
		{ CONSUMER, "test_consumer", { capacity = 1000, input = 300 } },
		{ BATTERY, "test_battery", { capacity = 100000, input = 500, output = 500 } },
		{ FURNACE, "test_furnace", { capacity = 20000, input = 20000 } },
		{ BROKEN, "test_broken", { capacity = 10, input = 1 } },
	}
	local function withMachines(fn: () -> (), bindings: { { any } }?)
		FakeMachines.bind(Machines, bindings or DEFAULT_BINDINGS, fn)
	end

	-- A world of blocks with pipes (cables) and machines, as the server runs them.
	type Sim = {
		blocks: { [number]: number },
		containers: any,
		cables: any,
		world: any,
		set: (x: number, y: number, z: number, block: number) -> (),
		step: (n: number?) -> (),
		machine: (x: number, y: number, z: number) -> any,
		energy: (x: number, y: number, z: number) -> number,
		setEnergy: (x: number, y: number, z: number, joules: number) -> (),
		field: (x: number, y: number, z: number, name: string, value: number) -> (),
		total: () -> number,
	}
	local function sim(): Sim
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
		local self: Sim
		self = {
			blocks = blocks,
			containers = containers,
			cables = cables,
			world = world,
			set = function(x: number, y: number, z: number, block: number)
				local key = Coords.posKey(x, y, z)
				local old = blocks[key] or AIR
				blocks[key] = if block == AIR then nil else block
				TransmitterWorld.blockChanged(cables, x, y, z, old, block)
				MachineWorld.blockChanged(world, x, y, z, old, block)
			end,
			step = function(n: number?)
				for _ = 1, n or 1 do
					TransmitterWorld.step(cables)
					MachineWorld.step(world)
				end
			end,
			machine = function(x: number, y: number, z: number): any
				return MachineWorld.machine(world, x, y, z)
			end,
			energy = function(x: number, y: number, z: number): number
				local machine = MachineWorld.machine(world, x, y, z)
				assert(machine, `no machine at {x}, {y}, {z}`)
				return Machines.energy(machine.container)
			end,
			setEnergy = function(x: number, y: number, z: number, joules: number)
				local machine = MachineWorld.machine(world, x, y, z)
				assert(machine, "no machine")
				machine.container.data[ENERGY] = joules
			end,
			field = function(x: number, y: number, z: number, name: string, value: number)
				local machine = MachineWorld.machine(world, x, y, z)
				assert(machine, "no machine")
				Machines.set(machine.container, name, value)
			end,
			total = function(): number
				local sum = 0
				for _, machine in world.machines do
					sum += Machines.energy(machine.container)
				end
				return sum
			end,
		}
		return self
	end

	local function bit(side: number): number
		return bit32.lshift(1, side)
	end

	--[[ Cables ]]

	t.test("cables: Mekanism's CableTier capacities, four blocks, small transmitters", function()
		local expected = { 8000, 128000, 1024000, 8192000 }
		for tier, capacity in expected do
			local cable = CABLES[tier]
			t.eq(Transmitters.TIERS[tier].cableCapacity, capacity, `{TIER_NAMES[tier]} capacity`)
			t.eq(Transmitters.cableCapacity(cable), capacity)
			t.eq(Transmitters.capacity(cable), capacity)
			t.eq(Transmitters.kindOf(cable), "energy")
			t.eq(Transmitters.tierOf(cable), tier)
			t.eq(Items.displayName(cable), `{TIER_NAMES[tier]} Universal Cable`)
			local def = Blocks.get(cable)
			t.ok(not def.solid and def.obstructs, "walked through, but not placed into players")
			t.eq(def.hardness, 1)
			t.eq(def.tool, "pickaxe")
			t.eq(def.sound, "metal")
			t.eq(Items.drops(cable, nil).item, cable, "drops itself by hand")
			t.ok(def.shape and #def.shape == 13, "a conductor and twelve frame edges")
			-- Mekanism's small transmitter: the core stays within 5..11 pixels.
			for _, box in def.shape :: any do
				for k = 1, 3 do
					t.ok(math.abs(box.offset[k]) + box.size[k] / 2 <= 3 + 1e-9, "inside the 6 pixel core")
				end
			end
			t.ok(def.icon and #def.icon == 17, "the item: the core and two arms")
			t.eq(Transmitters.pipeCapacity(cable), 0)
			t.eq(Transmitters.speed(cable), 0)
			t.eq(Transmitters.pullAmount(cable), 0)
		end
		t.eq(Transmitters.cableCapacity(B.BasicMechanicalPipe), 0)
		t.eq(Transmitters.capacity(B.BasicMechanicalPipe), 2000, "a pipe's mB")
		t.eq(Transmitters.cableCapacity(B.Stone), 0)
	end)

	t.test("cables: recipes from osmium and glowstone dust, upgrades around alloys", function()
		local function craft(grid: { [number]: number? }): any
			local stacks = {}
			for slot, item in grid do
				stacks[slot] = { item = item, count = 1 }
			end
			return Crafting.match(stacks, 3)
		end
		local O, G = I.OsmiumIngot, I.GlowstoneDust
		local basic = craft({ [4] = O, [5] = G, [6] = O })
		t.eq(basic and basic.item, CABLE)
		t.eq(basic and basic.count, 8)
		for tier, alloy in { I.GoldIngot, I.Diamond, I.Emerald } do
			local lower = CABLES[tier]
			local grid = {}
			for slot = 1, 9 do
				grid[slot] = if slot == 5 then alloy else lower
			end
			local made = craft(grid)
			t.eq(made and made.item, CABLES[tier + 1], `{TIER_NAMES[tier + 1]} cable`)
			t.eq(made and made.count, 8)
		end
		t.eq(craft({ [4] = I.IronIngot, [5] = G, [6] = I.IronIngot }), nil, "osmium, not iron")
	end)

	t.test("cables: connect to cables of any tier and to energy blocks, NONE cuts", function()
		withMachines(function()
			local cube = B.CreativeEnergyCube
			t.eq(Transmitters.connects(CABLE, M.NORMAL, 0, CABLES[4], M.NORMAL, 0), "transmitter", "any tier")
			t.eq(Transmitters.connects(CABLE, M.NORMAL, 0, cube), "acceptor", "the creative cube")
			t.eq(Transmitters.connects(CABLE, M.PULL, 0, PRODUCER), "acceptor", "PULL acts as NORMAL")
			t.eq(Transmitters.connects(CABLE, M.PUSH, 0, CONSUMER), "acceptor", "PUSH acts as NORMAL")
			t.eq(Transmitters.connects(CABLE, M.NONE, 0, PRODUCER), nil, "NONE cuts")
			t.eq(Transmitters.connects(CABLE, M.NORMAL, 0, CABLE, M.NONE, 0), nil, "NONE on the other end")
			t.eq(Transmitters.connects(CABLE, M.NORMAL, 0, B.Chest), nil, "inventories are no energy blocks")
			t.eq(Transmitters.connects(CABLE, M.NORMAL, 0, B.BasicFluidTank), nil)
			t.eq(Transmitters.connects(CABLE, M.NORMAL, 0, B.BasicMechanicalPipe, M.NORMAL, 0), nil, "other kinds")
			t.eq(Transmitters.connects(B.BasicLogisticalTransporter, M.NORMAL, 0, CABLE, M.NORMAL, 0), nil)
			t.eq(Transmitters.connects(B.BasicMechanicalPipe, M.NORMAL, 0, cube), nil, "pipes ignore machines")
			t.eq(Transmitters.connects(CABLE, M.NORMAL, 3, CABLE, M.NORMAL, 9), "transmitter", "cables have no colour")
			-- All six sides at once.
			local blocks = {
				[Coords.posKey(1, Y, 0)] = PRODUCER,
				[Coords.posKey(-1, Y, 0)] = CABLES[2],
				[Coords.posKey(0, Y + 1, 0)] = B.Chest,
				[Coords.posKey(0, Y - 1, 0)] = cube,
			}
			local links, acceptors = Transmitters.connections(CABLE, 0, 0, 0, Y, 0, function(x, y, z)
				return blocks[Coords.posKey(x, y, z)] or AIR
			end, function()
				return 0, 0
			end)
			t.eq(links, bit(WEST))
			t.eq(acceptors, bit(EAST) + bit(DOWN))
		end)
		t.eq(Transmitters.connects(CABLE, M.NORMAL, 0, PRODUCER), nil, "an unbound block is nothing")
	end)

	t.test("cables: TransmitterWorld keeps them as nodes and flags their links for the networks", function()
		withMachines(function()
			local s = sim()
			s.set(0, Y, 0, CABLE)
			local node = TransmitterWorld.node(s.cables, 0, Y, 0) :: any
			t.eq(node.kind, "energy")
			t.eq(node.network, nil, "no fluid network")
			t.ok(s.cables.energyDirty[node.key], "a new cable is flagged")
			table.clear(s.cables.energyDirty)
			s.set(1, Y, 0, PRODUCER)
			t.eq(node.acceptors, bit(EAST), "an energy block next to it")
			t.ok(s.cables.energyDirty[node.key], "relinked")
			table.clear(s.cables.energyDirty)
			TransmitterWorld.setMode(s.cables, 0, Y, 0, EAST, M.NONE)
			t.eq(node.acceptors, 0, "NONE cuts it")
			t.ok(s.cables.energyDirty[node.key])
			-- Configurator cycles work as on every transmitter; nothing pulls or fills.
			t.eq(TransmitterWorld.cycleMode(s.cables, 0, Y, 0, EAST), M.NORMAL)
			t.eq(TransmitterWorld.cycleColour(s.cables, 0, Y, 0), nil, "cables have no colour")
			t.eq(s.cables.pullers[node.key], nil)
			s.step(3)
			t.eq(next(s.cables.items), nil)
			s.set(0, Y, 0, AIR)
			t.eq(TransmitterWorld.node(s.cables, 0, Y, 0), nil)
		end)
	end)

	--[[ Networks ]]

	t.test("networks: cables and machines join, touching machines join without a cable", function()
		withMachines(function()
			local s = sim()
			s.set(0, Y, 0, PRODUCER)
			s.set(1, Y, 0, CABLE)
			s.set(2, Y, 0, CABLES[3])
			s.set(3, Y, 0, CONSUMER)
			s.set(3, Y + 1, 0, CONSUMER) -- touches the consumer below
			s.set(10, Y, 0, PRODUCER) -- alone
			s.step()
			local network = MachineWorld.network(s.world, 1, Y, 0) :: any
			t.ok(network ~= nil, "a network")
			t.eq(#network.machines, 3)
			t.eq(network.cables, 2)
			t.eq(network.throughput, 8000 + 1024000, "the cables' capacities summed")
			t.eq(MachineWorld.network(s.world, 3, Y + 1, 0), network, "joined by touching")
			t.eq(MachineWorld.network(s.world, 0, Y, 0), network)
			local alone = MachineWorld.network(s.world, 10, Y, 0) :: any
			t.ok(alone ~= nil and alone ~= network and #alone.machines == 1)
			t.eq(alone.throughput, math.huge, "no cables: unlimited")
			t.eq(MachineWorld.network(s.world, 5, Y, 0), nil, "air")
			-- Breaking a cable splits it; placing it again joins.
			s.set(2, Y, 0, AIR)
			s.step()
			local left = MachineWorld.network(s.world, 0, Y, 0) :: any
			local right = MachineWorld.network(s.world, 3, Y, 0) :: any
			t.ok(left ~= right, "split")
			t.eq(#left.machines, 1)
			t.eq(#right.machines, 2)
			s.set(2, Y, 0, CABLE)
			s.step()
			t.eq(MachineWorld.network(s.world, 0, Y, 0), MachineWorld.network(s.world, 3, Y, 0), "joined again")
			-- A NONE side cuts the cable from the machine.
			TransmitterWorld.setMode(s.cables, 1, Y, 0, WEST, M.NONE)
			s.step()
			t.ok(MachineWorld.network(s.world, 0, Y, 0) ~= MachineWorld.network(s.world, 1, Y, 0), "cut")
		end)
	end)

	t.test("networks: rebuilding is budgeted and carries over", function()
		withMachines(function()
			local s = sim()
			for x = 0, 40 do
				s.set(x, Y, 0, if x == 0 or x == 40 then PRODUCER else CABLE)
			end
			s.world.dirty = s.world.dirty -- (marked by the placements)
			EnergyNet.rebuild(s.world, 10)
			t.ok(EnergyNet.rebuilding(s.world), "not done in 10 visits")
			t.eq(MachineWorld.network(s.world, 20, Y, 0), nil, "no network while it is worked out")
			for _ = 1, 10 do
				EnergyNet.rebuild(s.world, 10)
			end
			t.ok(not EnergyNet.rebuilding(s.world), "done")
			local network = MachineWorld.network(s.world, 20, Y, 0) :: any
			t.eq(#network.machines, 2)
			t.eq(network.cables, 39)
			-- A change during a fill starts it over, and the result is the same.
			s.set(20, Y, 0, CABLES[2])
			EnergyNet.rebuild(s.world, 5)
			s.set(21, Y, 0, CABLES[2])
			for _ = 1, 20 do
				EnergyNet.rebuild(s.world, 5)
			end
			network = MachineWorld.network(s.world, 0, Y, 0) :: any
			t.eq(network.throughput, 37 * 8000 + 2 * 128000)
			t.eq(MachineWorld.network(s.world, 40, Y, 0), network)
		end)
	end)

	t.test("networks: changes far from a fill in progress never starve it; changes next to it count", function()
		withMachines(function()
			-- A producer, 60 cables and a consumer in a line.
			local function line(): Sim
				local s = sim()
				for x = 0, 61 do
					s.set(x, Y, 0, if x == 0 then PRODUCER elseif x == 61 then CONSUMER else CABLE)
				end
				return s
			end
			-- A cable placed and broken far away before every call (players building elsewhere):
			-- the fill (62 positions, 10 a call) still finishes.
			local s = line()
			for call = 1, 12 do
				s.set(300, Y, 300, if call % 2 == 1 then CABLE else AIR)
				EnergyNet.rebuild(s.world, 10)
			end
			local network = MachineWorld.network(s.world, 30, Y, 0) :: any
			t.ok(network ~= nil, "built despite a change every call")
			t.eq(#network.machines, 2)
			t.eq(network.cables, 60)
			-- A cable and a consumer joined to a part of the line the fill has not reached yet: the
			-- fill goes on (not started over) and takes them in.
			local u = line()
			EnergyNet.rebuild(u.world, 10)
			local job = u.world.job :: any
			t.ok(job ~= nil, "a fill in progress")
			local free: number? = nil
			for x = 2, 59 do
				local near = false
				for dx = -1, 1 do
					if job.visited[Coords.posKey(x + dx, Y, 0)] then
						near = true
					end
				end
				if not near then
					free = x
					break
				end
			end
			assert(free, "a part of the line not visited yet")
			u.set(free, Y, 1, CABLE)
			u.set(free, Y, 2, CONSUMER)
			EnergyNet.rebuild(u.world, 10)
			t.eq(u.world.job, job, "the same fill goes on")
			for _ = 1, 20 do
				EnergyNet.rebuild(u.world, 10)
			end
			t.ok(not EnergyNet.rebuilding(u.world))
			network = MachineWorld.network(u.world, 0, Y, 0) :: any
			t.eq(#network.machines, 3, "the new consumer joined")
			t.eq(network.cables, 61)
			t.eq(MachineWorld.network(u.world, free, Y, 2), network)
			-- A cable broken where the fill has been: it starts over and the line splits.
			local v = line()
			EnergyNet.rebuild(v.world, 10)
			local visited = (v.world.job :: any).visited
			local cut: number? = nil
			for x = 1, 60 do
				if visited[Coords.posKey(x, Y, 0)] then
					cut = x
					break
				end
			end
			assert(cut, "a visited cable")
			v.set(cut, Y, 0, AIR)
			for _ = 1, 20 do
				EnergyNet.rebuild(v.world, 10)
			end
			t.ok(not EnergyNet.rebuilding(v.world))
			local left = MachineWorld.network(v.world, 0, Y, 0) :: any
			local right = MachineWorld.network(v.world, 61, Y, 0) :: any
			t.ok(left ~= nil and right ~= nil and left ~= right, "split")
			t.eq(left.cables + right.cables, 59)
			t.eq(#left.machines + #right.machines, 2)
		end)
	end)

	--[[ Moving energy ]]

	t.test("energy: producers feed consumers at their rates, directly or by cable", function()
		withMachines(function()
			local s = sim()
			s.set(0, Y, 0, PRODUCER)
			s.set(1, Y, 0, CONSUMER)
			s.setEnergy(0, Y, 0, 10000)
			s.step()
			t.eq(s.energy(1, Y, 0), 300, "the consumer's input rate")
			t.eq(s.energy(0, Y, 0), 9700)
			local consumer = s.machine(1, Y, 0)
			t.eq(consumer.container.data[INPUT], 300, "INPUT records it")
			t.eq(s.machine(0, Y, 0).container.data[OUTPUT], 300, "OUTPUT too")
			s.step(5)
			t.eq(s.energy(1, Y, 0), 1000, "full")
			t.eq(s.energy(0, Y, 0), 9000)
			s.step()
			t.eq(consumer.container.data[INPUT], 0, "nothing more")
			-- The producer's output rate limits it too.
			local t2 = sim()
			t2.set(0, Y, 0, PRODUCER)
			t2.set(0, Y, 1, CABLE)
			t2.set(0, Y, 2, BATTERY)
			t2.setEnergy(0, Y, 0, 10000)
			t2.step()
			t.eq(t2.energy(0, Y, 2), 400, "the producer's 400 J/t (the battery takes 500)")
		end)
	end)

	t.test("energy: Mekanism's even split between consumers and between producers", function()
		withMachines(function()
			local s = sim()
			-- One producer (400 J/t) in the middle of three consumers, one nearly full.
			s.set(0, Y, 0, PRODUCER)
			s.set(1, Y, 0, CONSUMER)
			s.set(-1, Y, 0, CONSUMER)
			s.set(0, Y, 1, CONSUMER)
			s.setEnergy(0, Y, 0, 50000)
			s.setEnergy(0, Y, 1, 950)
			s.step()
			t.eq(s.energy(0, Y, 1), 1000, "the nearly full one takes its 50")
			t.eq(s.energy(1, Y, 0), 175, "the rest shared evenly")
			t.eq(s.energy(-1, Y, 0), 175)
			t.eq(s.energy(0, Y, 0), 50000 - 400)
			-- Two producers, one consumer: both give the same.
			local u = sim()
			u.set(0, Y, 0, PRODUCER)
			u.set(1, Y, 0, CONSUMER)
			u.set(2, Y, 0, PRODUCER)
			u.setEnergy(0, Y, 0, 5000)
			u.setEnergy(2, Y, 0, 5000)
			u.step()
			t.eq(u.energy(1, Y, 0), 300)
			t.eq(u.energy(0, Y, 0), 4850, "half each")
			t.eq(u.energy(2, Y, 0), 4850)
			-- A producer with little left gives all it has, the other the rest.
			u.setEnergy(0, Y, 0, 20)
			u.setEnergy(1, Y, 0, 0)
			u.step()
			t.eq(u.energy(0, Y, 0), 0)
			t.eq(u.energy(2, Y, 0), 4850 - 280)
			t.eq(u.energy(1, Y, 0), 300)
		end)
	end)

	t.test("energy: a network moves at most its cables' capacity per tick", function()
		withMachines(function()
			-- A big producer and a big consumer, joined by one Basic cable (8 000 J/t).
			local bindings = {
				{ PRODUCER, "test_producer", { capacity = 1e9, output = 1e6 } },
				{ CONSUMER, "test_consumer", { capacity = 1e9, input = 1e6 } },
			}
			FakeMachines.bind(Machines, bindings, function()
				local s = sim()
				s.set(0, Y, 0, PRODUCER)
				s.set(1, Y, 0, CABLE)
				s.set(2, Y, 0, CONSUMER)
				s.setEnergy(0, Y, 0, 1e8)
				s.step()
				t.eq(s.energy(2, Y, 0), 8000, "a Basic cable's 8 000 J/t")
				-- A second cable alongside adds its capacity to the same network.
				s.set(1, Y, 1, CABLES[2])
				s.set(0, Y, 1, CABLE)
				s.set(2, Y, 1, CABLE)
				s.step()
				t.eq(s.energy(2, Y, 0), 8000 + 8000 * 3 + 128000)
				-- Without a cable, touching: unlimited (only the rates).
				local d = sim()
				d.set(0, Y, 0, PRODUCER)
				d.set(1, Y, 0, CONSUMER)
				d.setEnergy(0, Y, 0, 1e8)
				d.step()
				t.eq(d.energy(1, Y, 0), 1e6)
			end)
		end)
	end)

	t.test("energy: batteries take the surplus after the consumers, and cover the shortfall", function()
		withMachines(function()
			local s = sim()
			s.set(0, Y, 0, PRODUCER) -- 400 J/t out
			s.set(1, Y, 0, CONSUMER) -- 300 J/t in
			s.set(2, Y, 0, BATTERY) -- 500 J/t in and out
			s.setEnergy(0, Y, 0, 100000)
			s.step()
			t.eq(s.energy(1, Y, 0), 300, "consumers first")
			t.eq(s.energy(2, Y, 0), 100, "the surplus charges the battery")
			t.eq(s.energy(0, Y, 0), 100000 - 400)
			t.eq(s.machine(2, Y, 0).container.data[INPUT], 100)
			-- The producer runs dry: the battery covers what the consumer needs.
			s.setEnergy(0, Y, 0, 0)
			s.setEnergy(1, Y, 0, 0)
			s.setEnergy(2, Y, 0, 50000)
			s.step()
			t.eq(s.energy(1, Y, 0), 300, "the battery is the backup")
			t.eq(s.energy(2, Y, 0), 50000 - 300)
			t.eq(s.machine(2, Y, 0).container.data[OUTPUT], 300)
			t.eq(Machines.status(BATTERY, Machines.view(s.machine(2, Y, 0).container)), "Discharging 300 J/t")
			-- A producer with only a little: it gives what it has, the battery the rest.
			s.setEnergy(0, Y, 0, 120)
			s.setEnergy(1, Y, 0, 0)
			s.step()
			t.eq(s.energy(1, Y, 0), 300)
			t.eq(s.energy(0, Y, 0), 0)
			t.eq(s.energy(2, Y, 0), 50000 - 300 - 180)
			-- Batteries never charge each other.
			local b = sim()
			b.set(0, Y, 0, BATTERY)
			b.set(1, Y, 0, BATTERY)
			b.setEnergy(0, Y, 0, 1000)
			b.step(3)
			t.eq(b.energy(0, Y, 0), 1000)
			t.eq(b.energy(1, Y, 0), 0)
		end)
		-- The battery's output rate limits the backup.
		FakeMachines.bind(Machines, {
			{ CONSUMER, "test_consumer", { capacity = 10000, input = 1000 } },
			{ BATTERY, "test_battery", { capacity = 10000, input = 150, output = 150 } },
		}, function()
			local s = sim()
			s.set(0, Y, 0, CONSUMER)
			s.set(1, Y, 0, BATTERY)
			s.set(-1, Y, 0, BATTERY)
			s.setEnergy(1, Y, 0, 5000)
			s.setEnergy(-1, Y, 0, 5000)
			s.step()
			t.eq(s.energy(0, Y, 0), 300, "two batteries' 150 each")
			t.eq(s.energy(1, Y, 0), 4850)
			t.eq(s.energy(-1, Y, 0), 4850)
		end)
	end)

	t.test("energy: backup power keeps a working machine running when its generator stops", function()
		withMachines(function()
			local s = sim()
			s.set(0, Y, 0, PRODUCER)
			s.set(1, Y, 0, CABLE)
			s.set(2, Y, 0, CONSUMER)
			s.set(1, Y, 1, BATTERY)
			s.field(0, Y, 0, "power", 400) -- makes 400 J a tick
			s.field(2, Y, 0, "use", 200) -- uses 200 J a tick
			s.step(40)
			local consumer = s.machine(2, Y, 0)
			t.eq(consumer.container.data[Machines.ACTIVE], 1, "working")
			local stored = s.energy(1, Y, 1)
			t.ok(stored > 0, "the battery charged from the surplus")
			-- The generator stops: the battery keeps the machine going.
			s.field(0, Y, 0, "power", 0)
			s.setEnergy(0, Y, 0, 0)
			s.step(20)
			t.eq(consumer.container.data[Machines.ACTIVE], 1, "still working")
			t.ok(s.energy(1, Y, 1) < stored, "on the battery")
			-- Until the battery runs dry too.
			s.setEnergy(1, Y, 1, 0)
			s.step(10)
			t.eq(consumer.container.data[Machines.ACTIVE], 0, "stopped")
		end)
	end)

	t.test("energy: the Creative Energy Cube gives without limit and never runs dry", function()
		withMachines(function()
			local s = sim()
			s.set(0, Y, 0, B.CreativeEnergyCube)
			s.set(1, Y, 0, CONSUMER)
			s.set(0, Y, 1, BATTERY)
			s.step()
			t.eq(s.energy(1, Y, 0), 300)
			t.eq(s.energy(0, Y, 1), 500, "the surplus charges batteries")
			t.eq(s.energy(0, Y, 0), math.huge)
			s.step(400)
			t.eq(s.energy(0, Y, 0), math.huge)
			t.eq(s.energy(0, Y, 1), 100000, "full")
			local record = MachineWorld.record(s.machine(0, Y, 0))
			t.eq(record.capacity, math.huge)
		end)
	end)

	t.test("energy: random networks never make or lose energy (exactly), never overfill", function()
		withMachines(function()
			local rng = Hash.rng(2024)
			for _ = 1, 25 do
				local s = sim()
				local choices = { PRODUCER, CONSUMER, BATTERY, CABLE, CABLES[2], CABLES[4], AIR, AIR }
				for x = 0, 5 do
					for z = 0, 5 do
						local block = choices[rng:int(1, #choices)]
						if block ~= AIR then
							s.set(x, Y, z, block)
							local machine = s.machine(x, Y, z)
							if machine then
								local capacity = Machines.capacity(machine.container)
								s.setEnergy(x, Y, z, Machines.quantise(rng:float() * capacity))
								if block == PRODUCER then
									s.field(x, Y, z, "power", rng:float() * 600)
								elseif block == CONSUMER then
									s.field(x, Y, z, "use", rng:float() * 400)
								end
							elseif rng:float() < 0.3 then
								TransmitterWorld.setMode(s.cables, x, Y, z, rng:int(0, 5), M.NONE)
							end
						end
					end
				end
				for _ = 1, 30 do
					local before = s.total()
					s.step()
					local made, used = 0, 0
					for _, machine in s.world.machines do
						local rate = machine.container.data[Machines.RATE]
						if rate > 0 then
							made += rate
						else
							used -= rate
						end
						local energy = Machines.energy(machine.container)
						t.ok(energy >= 0 and energy <= Machines.capacity(machine.container), "within 0..capacity")
						t.eq(energy % Machines.QUANTUM, 0, "whole quanta")
						-- Each part moves energy one way only: producers give, consumers take, and
						-- storage either charges or discharges in a tick, never both.
						local data = machine.container.data
						if machine.role == "producer" then
							t.eq(data[INPUT], 0, "producers take nothing")
						elseif machine.role == "consumer" then
							t.eq(data[OUTPUT], 0, "consumers give nothing")
						else
							t.ok(data[INPUT] == 0 or data[OUTPUT] == 0, "storage charges or discharges")
						end
					end
					t.eq(s.total(), before + made - used, "energy is conserved exactly")
					-- Per network: what went in came out, and at most its cables' throughput.
					for component in s.world.components do
						local into, outOf = 0, 0
						for _, machine in component.machines do
							into += machine.container.data[INPUT]
							outOf += machine.container.data[OUTPUT]
						end
						t.eq(into, outOf, "taken = given in each network")
						t.ok(into <= component.throughput, "within the throughput")
					end
				end
			end
		end)
	end)

	t.test("energy: the throughput left after the consumers bounds charging and backup", function()
		FakeMachines.bind(Machines, {
			{ PRODUCER, "test_producer", { capacity = 1e6, output = 10000 } },
			{ CONSUMER, "test_consumer", { capacity = 1e6, input = 6000 } },
			{ BATTERY, "test_battery", { capacity = 1e6, input = 5000, output = 10000 } },
		}, function()
			-- One Basic cable (8 000 J/t) between them all.
			local s = sim()
			s.set(1, Y, 0, CABLE)
			s.set(0, Y, 0, PRODUCER)
			s.set(2, Y, 0, CONSUMER)
			s.set(1, Y, 1, BATTERY)
			s.setEnergy(0, Y, 0, 500000)
			s.step()
			t.eq(s.energy(2, Y, 0), 6000, "the consumer first")
			t.eq(s.energy(1, Y, 1), 2000, "the battery gets what the cable has left, not its 5 000")
			t.eq(s.energy(0, Y, 0), 500000 - 8000)
			-- The producer gives only 1 000: the battery covers the consumer's other 5 000 (the cable
			-- still has room for them).
			s.setEnergy(0, Y, 0, 1000)
			s.setEnergy(2, Y, 0, 0)
			s.setEnergy(1, Y, 1, 500000)
			s.step()
			t.eq(s.energy(2, Y, 0), 6000)
			t.eq(s.energy(0, Y, 0), 0)
			t.eq(s.energy(1, Y, 1), 500000 - 5000)
			local battery = s.machine(1, Y, 1).container.data
			t.eq(battery[OUTPUT], 5000)
			t.eq(battery[INPUT], 0, "no charging in the same tick")
		end)
	end)

	t.test("energy: deterministic, whatever order the blocks were placed in", function()
		withMachines(function()
			local layout = {
				{ 0, 0, PRODUCER },
				{ 1, 0, CABLE },
				{ 2, 0, CONSUMER },
				{ 1, 1, CABLE },
				{ 1, 2, CONSUMER },
				{ 0, 2, BATTERY },
				{ 2, 2, PRODUCER },
				{ 3, 2, CONSUMER },
			}
			local function run(order: { number }): { string }
				local s = sim()
				for _, i in order do
					local entry = layout[i]
					s.set(entry[1], Y, entry[2], entry[3])
				end
				for _, entry in layout do
					local machine = s.machine(entry[1], Y, entry[2])
					if machine then
						s.setEnergy(entry[1], Y, entry[2], if entry[3] == PRODUCER then 3333 else 77)
						if entry[3] == PRODUCER then
							s.field(entry[1], Y, entry[2], "power", 123.456)
						elseif entry[3] == CONSUMER then
							s.field(entry[1], Y, entry[2], "use", 99.9)
						end
					end
				end
				s.step(50)
				local out = {}
				for _, entry in layout do
					local machine = s.machine(entry[1], Y, entry[2])
					if machine then
						table.insert(out, table.concat(machine.container.data, ","))
					end
				end
				return out
			end
			local forward = run({ 1, 2, 3, 4, 5, 6, 7, 8 })
			local backward = run({ 8, 7, 6, 5, 4, 3, 2, 1 })
			local mixed = run({ 3, 6, 1, 8, 2, 5, 7, 4 })
			for i = 1, #forward do
				t.eq(backward[i], forward[i], `machine {i} the same backwards`)
				t.eq(mixed[i], forward[i], `machine {i} the same mixed`)
			end
		end)
	end)

	--[[ Machines on the server ]]

	t.test("machines: containers per position, never forgotten, gone with their block", function()
		withMachines(function()
			local s = sim()
			s.set(0, Y, 0, FURNACE)
			local machine = s.machine(0, Y, 0)
			local container = s.containers:peek(0, Y, 0)
			t.eq(container, machine.container, "the store's own table")
			t.eq(container.kind, "machine")
			t.eq(container.size, 3)
			-- A viewer opening and closing it does not forget it, though it is empty.
			local state = InventoryState.new(s.containers)
			state:join("p")
			state:open("p", 0, Y, 0, FURNACE)
			t.eq(state:window("p").container, container, "the window holds the same table")
			state:close("p")
			t.eq(s.containers:peek(0, Y, 0), container, "kept")
			-- A machine without slots opens too (its panel shows its energy).
			s.set(5, Y, 0, B.CreativeEnergyCube)
			state:open("p", 5, Y, 0, B.CreativeEnergyCube)
			local window = state:window("p")
			t.eq(window.container.kind, "machine")
			t.eq(window.container.size, 0)
			t.ok(window.id ~= 0)
			state:close("p")
			-- Breaking it: the slots drop (Inventories' removeContainer), the machine goes.
			container.slots[1] = { item = I.RawIron, count = 5 }
			local contents = state:removeContainer(0, Y, 0)
			t.eq(#contents, 1)
			s.set(0, Y, 0, AIR)
			t.eq(s.machine(0, Y, 0), nil)
			t.eq(s.containers:peek(0, Y, 0), nil)
			t.eq(s.world.count, 1)
			-- Without Inventories (the tests' worlds) the machine tidies its container away itself.
			s.set(5, Y, 0, AIR)
			t.eq(s.containers:peek(5, Y, 0), nil)
			t.eq(s.world.count, 0)
			-- Breaking a container with slots costs creative players their budget (EditRules).
			t.ok(EditRules.isContainer(FURNACE))
			t.ok(not EditRules.isContainer(B.CreativeEnergyCube))
		end)
	end)

	t.test("machines: kinds tick on the server, slots and data changes are reported", function()
		withMachines(function()
			local s = sim()
			s.set(0, Y, 0, FURNACE)
			s.set(1, Y, 0, B.CreativeEnergyCube)
			local machine = s.machine(0, Y, 0)
			local container = machine.container
			s.field(0, Y, 0, "total", 3)
			s.field(0, Y, 0, "cost", 10)
			container.slots[1] = { item = I.RawIron, count = 2 }
			s.step()
			local slots, data = MachineWorld.takeChanges(s.world)
			t.ok(data[machine.key] ~= nil, "energy came in: data changed")
			t.eq(slots[machine.key], nil, "no slot changed yet")
			s.step()
			t.eq(Machines.get(container, "progress"), 1, "working once it had energy")
			t.eq(Machines.status(FURNACE, Machines.view(container)), "Smelting")
			s.step(2)
			slots = MachineWorld.takeChanges(s.world)
			t.ok(slots[machine.key] ~= nil, "an item smelted: slots changed")
			t.eq(container.slots[3].item, I.IronIngot)
			t.eq(container.slots[1].count, 1)
			-- A failing kind is skipped (reported once), the others go on.
			s.set(3, Y, 0, BROKEN)
			s.step(3)
			t.ok(s.world.failed.test_broken, "reported")
			t.eq(Machines.get(container, "progress") >= 0, true)
		end)
	end)

	t.test("machines: a kind that fails keeps the rules (energy in 0..capacity, no NaN)", function()
		local MESSY, BAD_RATES, SHUFFLER = B.CoalBlock, B.RawIronBlock, B.RawGoldBlock
		withMachines(function()
			local s = sim()
			-- A messy kind next to a consumer: its tick overfills, writes NaN and errors.
			s.set(0, Y, 0, MESSY)
			s.set(1, Y, 0, CONSUMER)
			s.step()
			local messy = s.machine(0, Y, 0).container.data
			t.ok(s.world.failed.test_messy, "reported")
			t.eq(messy[ENERGY], 400 - 300, "clamped to its capacity, then 300 J went to the consumer")
			t.eq(s.energy(1, Y, 0), 300)
			t.eq(messy[Machines.RATE], 0, "NaN cleared")
			for _, value in messy do
				t.ok(value == value, "no NaN in its data")
			end
			local record = MachineWorld.record(s.machine(0, Y, 0))
			t.ok(record.rate == record.rate)
			-- Storage whose rates fail moves nothing; the network around it still works.
			local u = sim()
			u.set(0, Y, 0, PRODUCER)
			u.set(1, Y, 0, CONSUMER)
			u.set(2, Y, 0, BAD_RATES)
			u.setEnergy(0, Y, 0, 10000)
			u.setEnergy(2, Y, 0, 5000)
			u.step()
			t.eq(u.energy(1, Y, 0), 300, "the consumer is fed")
			t.eq(u.energy(2, Y, 0), 5000, "the broken storage neither charges nor discharges")
			t.eq(u.energy(0, Y, 0), 10000 - 300)
			-- A kind that replaces its whole slots table still tells its viewers.
			local v = sim()
			v.set(0, Y, 0, SHUFFLER)
			local machine = v.machine(0, Y, 0)
			machine.container.slots[1] = { item = I.Stick, count = 3 }
			v.step()
			local slots = MachineWorld.takeChanges(v.world)
			t.ok(slots[machine.key] ~= nil, "a slot change")
			t.eq(machine.container.slots[2].count, 3)
		end, {
			{ MESSY, "test_messy", { capacity = 400, output = 1000 } },
			{ CONSUMER, "test_consumer", { capacity = 1000, input = 300 } },
			{ PRODUCER, "test_producer", { capacity = 100000, output = 400 } },
			{ BAD_RATES, "test_bad_rates", { capacity = 100000, input = 500, output = 500 } },
			{ SHUFFLER, "test_shuffler", { capacity = 10 } },
		})
	end)

	t.test("machines: records at most 4 a second, chunk records only when not default", function()
		withMachines(function()
			local s = sim()
			s.set(0, Y, 0, PRODUCER)
			s.set(1, Y, 0, CONSUMER)
			s.set(40, Y, 0, CONSUMER) -- idle, empty: default
			t.eq(#MachineWorld.takeRecords(s.world), 0, "new machines are in the default state")
			s.setEnergy(0, Y, 0, 10000)
			s.step()
			local records = MachineWorld.takeRecords(s.world)
			t.eq(#records, 2, "producer and consumer changed")
			s.step()
			t.eq(#MachineWorld.takeRecords(s.world), 0, "within RECORD_INTERVAL: wait")
			s.step(MachineWorld.RECORD_INTERVAL)
			records = MachineWorld.takeRecords(s.world)
			t.eq(#records, 2, "then the latest state")
			local consumer = nil
			for _, record in records do
				if record.x == 1 then
					consumer = record
				end
			end
			t.eq(consumer and consumer.energy, s.energy(1, Y, 0), "the energy now")
			t.eq(consumer and consumer.input, s.machine(1, Y, 0).container.data[INPUT], "the last tick's input")
			-- What a chunk's edit list brings: the producer and consumer, not the idle one.
			local chunk = MachineWorld.chunkRecords(s.world, 0, 0)
			t.eq(#chunk, 2)
			t.eq(#MachineWorld.chunkRecords(s.world, 2, 0), 0, "x = 40 is in chunk 2: default")
			local decoded = Protocol.decodeMachines(Protocol.encodeMachines(chunk)) :: any
			t.eq(#decoded, 2)
		end)
	end)

	t.test("sustained data: a machine keeps its energy in its item and gets it back", function()
		withMachines(function()
			local s = sim()
			local registry = EditRules.newBlockData()
			registry:add(TransmitterWorld.blockDataHooks(s.cables))
			registry:add(MachineWorld.blockDataHooks(s.world))
			s.set(0, Y, 0, PRODUCER)
			s.setEnergy(0, Y, 0, 54321.5)
			s.field(0, Y, 0, "power", 12)
			-- A survival break: the drop carries the energy, read before the block goes.
			local pick = I.IronPickaxe
			t.eq(EditRules.breakDrop(registry, 0, Y, 0, PRODUCER, true, pick), nil, "creative drops nothing")
			local drop = EditRules.breakDrop(registry, 0, Y, 0, PRODUCER, false, pick) :: any
			s.set(0, Y, 0, AIR)
			t.eq(drop.item, PRODUCER)
			t.eq(drop.data.energy, 54321.5)
			t.eq(drop.data.power, 12)
			t.eq(Items.describe(drop)[1], "Energy: 54.32 kJ")
			-- It travels in a snapshot like any item data.
			local inventory = Types.newInventory()
			inventory.slots[1] = drop
			local snapshot = Protocol.decodeInventory(Protocol.encodeInventory({
				ack = 1,
				inventory = inventory,
				window = 0,
				container = nil,
			} :: any)) :: any
			t.eq(snapshot.inventory.slots[1].data.energy, 54321.5)
			-- Placed again: the placement's stack (data intact) fills the new machine.
			s.set(4, Y, 0, PRODUCER)
			registry:placed("p", 4, Y, 0, PRODUCER, drop)
			t.eq(s.energy(4, Y, 0), 54321.5)
			t.eq(Machines.get(s.machine(4, Y, 0).container, "power"), 12)
			t.eq(#MachineWorld.takeRecords(s.world), 1, "its record goes out")
			-- An empty machine drops a plain item; the creative cube keeps nothing.
			s.set(5, Y, 0, CONSUMER)
			local plain = EditRules.breakDrop(registry, 5, Y, 0, CONSUMER, false, pick) :: any
			t.eq(plain.data, nil)
			s.set(6, Y, 0, B.CreativeEnergyCube)
			local cube = EditRules.breakDrop(registry, 6, Y, 0, B.CreativeEnergyCube, false, nil) :: any
			t.eq(cube.item, B.CreativeEnergyCube)
			t.eq(cube.data, nil)
			-- Another block's data does nothing to a machine; a machine's data nothing to a tank.
			s.set(7, Y, 0, CONSUMER)
			registry:placed("p", 7, Y, 0, CONSUMER, { item = CONSUMER, count = 1, data = { fluid = 1, amount = 5 } })
			t.eq(s.energy(7, Y, 0), 0)
			s.set(8, Y, 0, B.BasicFluidTank)
			registry:placed(
				"p",
				8,
				Y,
				0,
				B.BasicFluidTank,
				{ item = B.BasicFluidTank, count = 1, data = { energy = 5 } }
			)
			t.eq((TransmitterWorld.tank(s.cables, 8, Y, 0) :: any).amount, 0)
		end)
	end)

	--[[ The client ]]

	t.test("cables on the client: thinner opaque arms, collars and plates, no bands", function()
		local function ofKind(boxes, kind: string)
			local found = {}
			for _, box in boxes do
				if box.kind == kind then
					table.insert(found, box)
				end
			end
			return found
		end
		local sizes = TransmitterModel.sizes(CABLE)
		t.eq(sizes.core, 3, "Mekanism's 6 pixel core")
		t.eq(sizes.arm, 4)
		t.eq(sizes.collar, 5)
		t.eq(sizes.plate, 8)
		t.eq(TransmitterModel.sizes(B.BasicMechanicalPipe).core, 4)
		t.eq(TransmitterModel.sizes(nil).core, 4)
		local pull = Transmitters.withMode(0, EAST, M.PULL)
		local boxes = TransmitterModel.transmitterBoxes(CABLE, pull, 0, 0, bit(WEST), bit(EAST))
		local arms = ofKind(boxes, "cable")
		t.eq(#arms, 2, "two arms")
		t.eq(#ofKind(boxes, "glass"), 0, "no glass")
		t.eq(#ofKind(boxes, "band"), 0, "PULL acts as NORMAL: no band")
		t.eq(#ofKind(boxes, "water"), 0)
		t.eq(#ofKind(boxes, "tint"), 0)
		for _, arm in arms do
			t.eq(arm.size[2], 4, "4 pixels across")
			t.eq(arm.size[3], 4)
			t.ok(math.abs(arm.offset[1]) - arm.size[1] / 2 >= 3 - 1e-9, "from the core out")
		end
		local frames = ofKind(boxes, "frame")
		t.eq(#frames, 2)
		local collar, plate = frames[1], frames[2]
		if collar.offset[1] > 0 then
			collar, plate = plate, collar
		end
		t.eq(collar.size[2], 5, "a collar to the cable west")
		t.eq(plate.size[2], 8, "a plate on the machine east")
		-- The Configurator aims at a cable's smaller core: a ray 3.5 pixels off centre misses it
		-- (but hits a pipe's).
		local off = 3.5 / 16
		local function aim(block: number): number?
			return TransmitterModel.pickSide(0.5, 0.5 + off, -2, 0, 0, 1, 0, 0, 0, 0, 0, block)
		end
		t.eq(aim(CABLE), nil, "beside a cable's core")
		t.eq(aim(B.BasicMechanicalPipe), NORTH, "a pipe's core face")
		t.eq(TransmitterModel.pickSide(0.5, 0.5, -2, 0, 0, 1, 0, 0, 0, 0, 0, CABLE), NORTH, "dead centre")
		t.eq(
			TransmitterModel.pickSide(0.5, 0.5 + 0.1, -2, 0, 0, 1, 0, 0, 0, bit(NORTH), 0, CABLE),
			NORTH,
			"its arm north"
		)
		t.eq(UP, 1)
		t.eq(SOUTH, 3)
	end)

	t.test("cables in WAILA: capacity, F3 tier and the network's throughput", function()
		local facts = {
			modes = 0,
			colour = 0,
			fluid = 0,
			side = EAST,
			items = 0,
			stacks = 0,
			transmitters = bit(WEST),
			acceptors = 0,
			networkSize = 3,
			networkCapacity = 8000 + 128000 * 2,
			networkComplete = true,
		}
		local texts = WailaInfo.texts(WailaInfo.block(CABLE, nil, 0, Y, 0, false, { transmitter = facts }))
		t.ok(table.find(texts, "Side: Normal") ~= nil)
		t.ok(table.find(texts, "Capacity: 8 kJ/t") ~= nil, "Mekanism's cable tooltip")
		t.eq(table.find(texts, "Colour: None"), nil, "cables have no colour")
		local extended = WailaInfo.texts(WailaInfo.block(CABLES[4], nil, 0, Y, 0, true, { transmitter = facts }))
		t.ok(table.find(extended, "Cable tier 4 (Ultimate), 8,192,000 J/t") ~= nil)
		t.ok(table.find(extended, "Network 3 transmitters, 264,000 J/t") ~= nil)
	end)
end

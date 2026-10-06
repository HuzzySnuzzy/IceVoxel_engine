--[[
	Lava, oil and fuel on the server: lava hurting and burning players (Players/Burning: Minecraft's
	4 every 10 ticks, 15 s of burning at 1 every 20 ticks, water putting it out, creative and
	spectator immune) and burning dropped items (Entities/EntityWorld); Mechanical Pipes and Fluid
	Tanks carrying every fluid without mixing them (Transmitters/Fluids, TransmitterWorld), and
	their records' fluid ids; machines' fluid tanks through pipes (input tanks filled, output tanks
	drained, through any side), the ejector pushing output tanks into pipes and Fluid Tanks (never
	into the empty supply tank of the refinery's own oil line), the Heat Generator fed lava and its
	empty Buckets taken out by transporters, the Oil Refinery and the Combustion Generator in a
	chain; buckets of every fluid on sources, cave twins, Fluid Tanks and machines
	(Transmitters/UseRules), the furnace giving the Lava Bucket's bucket back, machine viewers
	hearing of tank changes, unsafe spawns in lava and oil, and a conservation fuzz with two fluids.
]]

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Coords = require(shared.World.Coords)
	local Fluids = require(shared.Fluids)
	local GameMode = require(shared.GameMode)
	local Hash = require(shared.Util.Hash)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local Protocol = require(shared.Net.Protocol)
	local Smelting = require(shared.Crafting.Smelting)
	local SharedSounds = require(shared.Sounds)
	local Transmitters = require(shared.Transmitters)
	local Burning = require(server.Players.Burning)
	local Containers = require(server.Players.Containers)
	local Drops = require(server.Behaviours.Drops)
	local EntityWorld = require(server.Entities.EntityWorld)
	local MachineWorld = require(server.Machines.MachineWorld)
	local SafeSpot = require(server.Players.SafeSpot)
	local TransmitterWorld = require(server.Transmitters.TransmitterWorld)
	local UseRules = require(server.Transmitters.UseRules)
	local WorldServer = require(server.World.WorldServer)

	local B, I = Blocks.id, Items.id
	local AIR, STONE = Blocks.AIR, B.Stone
	local M = Transmitters.MODES
	local DOWN, UP, NORTH, SOUTH, WEST, EAST = 0, 1, 2, 3, 4, 5
	local _ = { DOWN, NORTH, SOUTH }
	local WATER, LAVA, OIL, FUEL = Fluids.WATER, Fluids.LAVA, Fluids.OIL, Fluids.FUEL
	local SOURCE = {
		[WATER] = Blocks.fluidId("Water", 0),
		[LAVA] = Blocks.fluidId("Lava", 0),
		[OIL] = Blocks.fluidId("Oil", 0),
		[FUEL] = Blocks.fluidId("Fuel", 0),
	}
	local PIPE, ULTIMATE_PIPE = B.BasicMechanicalPipe, B.UltimateMechanicalPipe
	local TANK, BIG_TANK = B.BasicFluidTank, B.UltimateFluidTank
	local GENERATOR, REFINERY, COMBUSTION = B.HeatGenerator, B.OilRefinery, B.CombustionGenerator
	local CUBE = B.CreativeEnergyCube
	local ENERGY = Machines.ENERGY
	local Y = 64
	local SURVIVAL, CREATIVE, ADVENTURE, SPECTATOR =
		GameMode.SURVIVAL, GameMode.CREATIVE, GameMode.ADVENTURE, GameMode.SPECTATOR
	local PULL_BASIC = Transmitters.TIERS[1].pipePull

	local function S(item: number, count: number)
		return { item = item, count = count }
	end

	-- A world of blocks in a table (air elsewhere; `false`: not loaded).
	local function cells(list: { [string]: number | false }): (x: number, y: number, z: number) -> number?
		return function(x: number, y: number, z: number): number?
			local block = list[`{x},{y},{z}`]
			if block == false then
				return nil
			end
			return block or AIR
		end
	end

	--[[ Pipes and machines in a world of blocks, stepped as the server does ]]

	local function sim()
		local blocks: { [number]: number } = {}
		local containers = Containers.new()
		local function getBlock(x: number, y: number, z: number): number?
			return blocks[Coords.posKey(x, y, z)] or AIR
		end
		local pipes = TransmitterWorld.new({ getBlock = getBlock, containers = containers })
		local machines = MachineWorld.new({
			getBlock = getBlock,
			containers = containers,
			transmitters = pipes,
			dayTime = function()
				return 6000
			end,
		})
		local s: any = { pipes = pipes, machines = machines, containers = containers }
		function s.set(x: number, y: number, z: number, block: number)
			local key = Coords.posKey(x, y, z)
			local old = blocks[key] or AIR
			if old ~= block then
				containers:take(x, y, z)
			end
			blocks[key] = if block == AIR then nil else block
			TransmitterWorld.blockChanged(pipes, x, y, z, old, block)
			MachineWorld.blockChanged(machines, x, y, z, old, block)
		end
		-- A Fluid Tank block with `amount` mB of `fluid`.
		function s.tank(x: number, y: number, z: number, block: number, fluid: number, amount: number)
			s.set(x, y, z, block)
			if amount > 0 then
				t.eq(TransmitterWorld.fillTank(pipes, x, y, z, fluid, amount), amount, "tank filled")
			end
		end
		function s.amount(x: number, y: number, z: number): number
			local tank = TransmitterWorld.tank(pipes, x, y, z)
			return if tank then tank.amount else -1
		end
		function s.fluid(x: number, y: number, z: number): number
			local tank = TransmitterWorld.tank(pipes, x, y, z)
			return if tank then tank.fluid else -1
		end
		function s.machine(x: number, y: number, z: number): any
			return containers:peek(x, y, z)
		end
		function s.mode(x: number, y: number, z: number, side: number, mode: number)
			assert(TransmitterWorld.setMode(pipes, x, y, z, side, mode), "no pipe")
		end
		function s.network(x: number, y: number, z: number): any
			return TransmitterWorld.network(pipes, x, y, z)
		end
		function s.step(n: number?)
			for _ = 1, n or 1 do
				TransmitterWorld.step(pipes)
				MachineWorld.step(machines)
			end
		end
		-- mB of `fluid` in tanks, buffers and machines' tanks.
		function s.total(fluid: number): number
			local total = 0
			for _, tank in pipes.tanks do
				if tank.fluid == fluid then
					total += tank.amount
				end
			end
			for network in pipes.networks do
				if network.fluid == fluid then
					total += network.amount
				end
			end
			for _, machine in machines.machines do
				for _, contents in Machines.tankContents(machine.container) do
					if contents.fluid == fluid then
						total += contents.amount
					end
				end
			end
			return total
		end
		return s
	end

	--[[ Lava and burning: what touches a body ]]

	t.test("burning: lava touches a box that reaches below its surface (Minecraft's fluid height)", function()
		local lava = SOURCE[LAVA]
		local get = cells({ ["0,10,0"] = lava, ["5,10,0"] = B.LavaFalling, ["8,10,0"] = SOURCE[WATER] })
		local function at(x: number, y: number, z: number): number
			return Burning.touchingAt(get, x, y, z, 0.6, 1.8)
		end
		t.ok(Burning.has(at(0.5, 10, 0.5), LAVA), "standing in a source")
		t.ok(Burning.has(at(0.5, 10.85, 0.5), LAVA), "feet under its surface (8 / 9)")
		t.eq(at(0.5, 10.95, 0.5), 0, "feet above a source's surface")
		t.eq(at(0.5, 11, 0.5), 0, "standing on top")
		t.ok(Burning.has(at(5.5, 10.95, 0.5), LAVA), "falling lava fills its cell")
		-- A box overlapping the cell from the side touches it; 0.3 is half a player's width.
		t.ok(Burning.has(at(1.29, 10, 0.5), LAVA), "the box reaches into the lava's cell")
		t.eq(at(1.31, 10, 0.5), 0, "beside it")
		t.ok(Burning.has(at(8.5, 10, 0.5), WATER) and not Burning.has(at(8.5, 10, 0.5), LAVA), "water")
		-- Lava above makes the cell below full.
		local stacked = cells({ ["0,10,0"] = lava, ["0,11,0"] = lava })
		t.ok(Burning.has(Burning.touchingAt(stacked, 0.5, 10.95, 0.5, 0.6, 1.8), LAVA), "full under lava")
		-- Cave twins are lava; unknown cells touch nothing.
		local twin = cells({ ["0,10,0"] = B.CaveLava })
		t.ok(Burning.has(Burning.touchingAt(twin, 0.5, 10, 0.5, 0.6, 1.8), LAVA), "CaveLava burns too")
		local unknown = cells({ ["0,10,0"] = false })
		t.eq(Burning.touchingAt(unknown, 0.5, 10, 0.5, 0.6, 1.8), 0, "an unloaded cell")
		t.eq(Burning.touchingAt(get, 0 / 0, 10, 0.5, 0.6, 1.8), 0, "no place")
		-- Oil and fuel touch but neither hurts nor puts burning out.
		local oily = cells({ ["0,10,0"] = SOURCE[OIL], ["1,10,0"] = SOURCE[FUEL] })
		t.ok(Burning.has(Burning.touchingAt(oily, 0.5, 10, 0.5, 0.6, 1.8), OIL))
		t.ok(Burning.has(Burning.touchingAt(oily, 1.5, 10, 0.5, 0.6, 1.8), FUEL))
	end)

	--[[ Lava and burning: players ]]

	local LAVA_MASK = bit32.lshift(1, LAVA)
	local WATER_MASK = bit32.lshift(1, WATER)

	-- Ticks a player through `ticks` ticks touching `mask`; the half hearts lost and the ticks they
	-- were lost on.
	local function run(state: any, mode: string, mask: number, ticks: number): (number, { number })
		local total, when = 0, {}
		for tick = 1, ticks do
			local damage = Burning.tickPlayer(state, mode, mask)
			if damage > 0 then
				total += damage
				table.insert(when, tick)
			end
		end
		return total, when
	end

	t.test("burning: lava takes 4 every 10 ticks, then burning 1 every 20 ticks for 15 s", function()
		local state = Burning.newPlayer()
		local lava, when = run(state, SURVIVAL, LAVA_MASK, 100)
		t.eq(lava, 40, "ten hurts of 4 in 100 ticks")
		t.eq(when[1], 1, "at once")
		t.eq(when[2] - when[1], 10, "every 10 ticks (the hurt cooldown)")
		t.ok(Burning.onFire(state), "burning")
		t.eq(state.fire, 300, "15 s of burning, kept topped up in the lava")
		local burnt, burns = run(state, SURVIVAL, 0, 400)
		t.eq(burnt, 15, "15 half hearts of burning")
		t.eq(burns[2] - burns[1], 20, "one every 20 ticks")
		t.eq(burns[#burns], 281, "the last one 14 s after the first")
		t.ok(not Burning.onFire(state), "burnt out after 15 s")
		t.eq(run(state, SURVIVAL, 0, 100), 0, "nothing more")
		-- Adventure players burn as survival ones do.
		t.eq(run(Burning.newPlayer(), ADVENTURE, LAVA_MASK, 100), 40)
		-- Armor softens lava (CombatRules.getDamageAfterAbsorb), not burning: full diamond (20
		-- points, toughness 8) takes 4 down to 0.96.
		local armored = Burning.newPlayer()
		local first = Burning.tickPlayer(armored, SURVIVAL, LAVA_MASK, 20, 8)
		t.near(first, 4 * (1 - 19 / 25), 1e-9, "lava through diamond")
		t.near(first, Items.damageAfterArmor(4, 20, 8), 1e-12)
		for _ = 1, 9 do
			Burning.tickPlayer(armored, SURVIVAL, LAVA_MASK, 20, 8)
		end
		local burn = 0
		for _ = 1, 400 do
			burn += Burning.tickPlayer(armored, SURVIVAL, 0, 20, 8)
		end
		t.eq(burn, 15, "burning goes through armor")
	end)

	t.test("burning: water puts it out; creative and spectator players never burn", function()
		local state = Burning.newPlayer()
		run(state, SURVIVAL, LAVA_MASK, 1)
		t.ok(Burning.onFire(state))
		local damage, extinguished = Burning.tickPlayer(state, SURVIVAL, WATER_MASK)
		t.eq(damage, 0)
		t.ok(extinguished, "put out (the extinguish sound)")
		t.ok(not Burning.onFire(state))
		t.eq(run(state, SURVIVAL, 0, 400), 0, "no burning left")
		local _, again = Burning.tickPlayer(state, SURVIVAL, WATER_MASK)
		t.ok(not again, "nothing to put out")
		-- In lava and water at once (lava flowing into a pool): it burns, water or not.
		local both = Burning.newPlayer()
		t.eq(run(both, SURVIVAL, bit32.bor(LAVA_MASK, WATER_MASK), 20), 8)
		t.ok(Burning.onFire(both))
		-- Oil and fuel neither hurt nor put burning out.
		local oily = Burning.newPlayer()
		run(oily, SURVIVAL, LAVA_MASK, 1)
		local oil = bit32.bor(bit32.lshift(1, OIL), bit32.lshift(1, FUEL))
		-- (The first burn comes under the lava hurt's cooldown, as in Minecraft: 14 of 15 land.)
		t.eq(run(oily, SURVIVAL, oil, 400), 14, "burning on in oil and fuel")
		-- Creative and spectator: no hurt, no burning; a player who switches to creative is put out.
		for _, mode in { CREATIVE, SPECTATOR } do
			local immune = Burning.newPlayer()
			t.eq(run(immune, mode, LAVA_MASK, 200), 0, `{mode}: lava`)
			t.ok(not Burning.onFire(immune), `{mode}: never burning`)
		end
		local switched = Burning.newPlayer()
		run(switched, SURVIVAL, LAVA_MASK, 5)
		run(switched, CREATIVE, 0, 1)
		t.ok(not Burning.onFire(switched), "creative puts it out")
		t.eq(run(switched, SURVIVAL, 0, 400), 0)
	end)

	--[[ Lava and burning: dropped items ]]

	t.test("burning: dropped items burn away in lava (ItemEntity's 5 health), not in water", function()
		-- Direct: one tick in lava, gone the next tick; water in between saves it.
		local item = Burning.newItem()
		local gone, hurt = Burning.tickItem(item, LAVA_MASK)
		t.ok(not gone and hurt, "5 - 4")
		t.eq(item.health, 1)
		gone = Burning.tickItem(item, 0)
		t.ok(gone, "burning finishes it off")
		local saved = Burning.newItem()
		Burning.tickItem(saved, LAVA_MASK)
		gone = Burning.tickItem(saved, WATER_MASK)
		t.ok(not gone and saved.fire == 0, "water puts it out")
		for _ = 1, 400 do
			t.ok(not Burning.tickItem(saved, 0))
		end
		-- In EntityWorld: an item dropped into a lava pool is gone two ticks after it touches it.
		local lava = SOURCE[LAVA]
		local function world(fluid: number): (x: number, y: number, z: number) -> number?
			return function(x: number, y: number, z: number): number?
				if y <= 0 then
					return STONE
				elseif y == 1 and x >= -2 and x <= 2 and z >= -2 and z <= 2 then
					return fluid
				end
				return AIR
			end
		end
		local entities = EntityWorld.new(world(lava), { maxItems = 100, lifetimeTicks = 6000 })
		local id = entities:spawnItem(I.Dirt, 3, 0.5, 2.5, 0.5, 0, 0, 0)
		local burntAt, ticks = nil, 0
		local burnt = 0
		while entities:get(id) and ticks < 100 do
			ticks += 1
			entities:tick({}, function()
				return 0
			end)
			local changes = entities:takeChanges()
			burnt += #changes.burnt
			for _, removal in changes.removed do
				if removal.id == id then
					burntAt = ticks
					t.eq(removal.collector, nil, "nobody collected it")
				end
			end
		end
		t.ok(burntAt ~= nil, "burnt away")
		t.ok(burnt >= 1 and burnt <= 2, `a burn sound per lava hurt ({burnt})`)
		local touched = 0
		for tick = 1, 100 do
			local probe = EntityWorld.new(world(lava), { maxItems = 100, lifetimeTicks = 6000 })
			local pid = probe:spawnItem(I.Dirt, 1, 0.5, 2.5, 0.5, 0, 0, 0)
			for _ = 1, tick do
				probe:tick({}, function()
					return 0
				end)
			end
			local entity = probe:get(pid)
			if entity == nil or entity.health < Burning.ITEM_HEALTH then
				touched = tick
				break
			end
		end
		t.eq(burntAt, touched + 1, "gone the tick after lava first hurt it")
		-- The same pool of water keeps it.
		local wet = EntityWorld.new(world(SOURCE[WATER]), { maxItems = 100, lifetimeTicks = 6000 })
		local wid = wet:spawnItem(I.Dirt, 3, 0.5, 2.5, 0.5, 0, 0, 0)
		for _ = 1, 100 do
			wet:tick({}, function()
				return 0
			end)
		end
		t.ok(wet:get(wid) ~= nil, "water keeps it")
		t.eq(#wet:takeChanges().burnt, 0)
	end)

	--[[ Pipes and Fluid Tanks with every fluid ]]

	t.test("pipes: every fluid moves between Fluid Tanks; a tank holds one fluid", function()
		for fluid = 1, Fluids.COUNT do
			local s = sim()
			s.tank(0, Y, 0, BIG_TANK, fluid, 10000)
			s.set(1, Y, 0, PIPE)
			s.tank(2, Y, 0, TANK, 0, 0)
			s.mode(1, Y, 0, WEST, M.PULL)
			s.step(4)
			t.eq(s.amount(2, Y, 0), 4 * PULL_BASIC, `{Fluids.name(fluid)}: pulled and pushed`)
			t.eq(s.fluid(2, Y, 0), fluid)
			t.eq(s.network(1, Y, 0).amount, 0, "the buffer passed it all on")
		end
		-- A tank holding water takes no lava; the lava waits in the pipe.
		local s = sim()
		s.tank(0, Y, 0, BIG_TANK, LAVA, 10000)
		s.set(1, Y, 0, PIPE)
		s.tank(2, Y, 0, TANK, WATER, 1000)
		s.mode(1, Y, 0, WEST, M.PULL)
		s.step(3)
		t.eq(s.amount(2, Y, 0), 1000, "the water tank took nothing")
		t.eq(s.fluid(2, Y, 0), WATER)
		t.eq(s.network(1, Y, 0).fluid, LAVA, "lava in the pipe")
		t.eq(s.network(1, Y, 0).amount, 3 * PULL_BASIC)
		-- A tank of another fluid is not pulled from while the pipe holds lava.
		s.set(0, Y, 0, AIR)
		s.tank(0, Y, 0, BIG_TANK, OIL, 5000)
		s.step(2)
		t.eq(s.amount(0, Y, 0), 5000, "the oil stays put")
		-- Fluids.carriable: no fluid 0 or unknown ids in tanks.
		t.eq(TransmitterWorld.fillTank(s.pipes, 2, Y, 0, 0, 1000), 0)
		t.eq(TransmitterWorld.fillTank(s.pipes, 2, Y, 0, Fluids.COUNT + 1, 1000), 0)
	end)
	t.test("pipes: networks holding different fluids stay apart; nothing is mixed or lost", function()
		local s = sim()
		-- Water west, lava east, each pulled into two pipes of its own.
		s.tank(0, Y, 0, BIG_TANK, WATER, 10000)
		s.set(1, Y, 0, PIPE)
		s.set(2, Y, 0, PIPE)
		s.tank(6, Y, 0, BIG_TANK, LAVA, 10000)
		s.set(5, Y, 0, PIPE)
		s.set(4, Y, 0, PIPE)
		s.mode(1, Y, 0, WEST, M.PULL)
		s.mode(5, Y, 0, EAST, M.PULL)
		s.step(10)
		t.eq(s.network(1, Y, 0).fluid, WATER)
		t.eq(s.network(4, Y, 0).fluid, LAVA)
		-- A pipe between them: it joins one; the other stays apart.
		s.set(3, Y, 0, PIPE)
		s.step(5)
		local west, east = s.network(2, Y, 0), s.network(4, Y, 0)
		t.ok(west ~= east, "two networks")
		t.ok(s.network(3, Y, 0) == west or s.network(3, Y, 0) == east, "the new pipe joined one")
		t.eq(west.fluid, WATER)
		t.eq(east.fluid, LAVA)
		t.eq(s.total(WATER), 10000, "all the water")
		t.eq(s.total(LAVA), 10000, "all the lava")
		t.eq(s.pipes.lost, 0)
		-- Once the lava network is empty (its tank gone, its buffer pushed into a new tank), the
		-- next fill joins it to the water.
		s.set(6, Y, 0, AIR)
		local lavaLeft = s.total(LAVA)
		s.mode(5, Y, 0, EAST, M.NORMAL)
		s.tank(6, Y, 0, BIG_TANK, 0, 0)
		s.step(3)
		t.eq(east.amount, 0, "the lava went into the tank")
		t.eq(s.fluid(6, Y, 0), LAVA)
		s.set(3, Y, 0, AIR)
		s.set(3, Y, 0, PIPE)
		s.step(3)
		t.eq(s.network(1, Y, 0), s.network(5, Y, 0), "one network now")
		t.eq(s.total(LAVA), lavaLeft, "the lava tank kept its lava")
		t.eq(s.fluid(6, Y, 0), LAVA, "no water pushed into the lava tank")
	end)

	t.test("pipes: records carry the network's fluid id (Protocol fluidId), chunk records too", function()
		local s = sim()
		s.tank(0, Y, 0, BIG_TANK, LAVA, 10000)
		s.set(1, Y, 0, PIPE)
		s.mode(1, Y, 0, WEST, M.PULL)
		s.step(TransmitterWorld.FILL_INTERVAL)
		local records = TransmitterWorld.takeRecords(s.pipes)
		local record = nil
		for _, r in records do
			if r.x == 1 then
				record = r
			end
		end
		assert(record, "a record for the pipe")
		t.eq(record.fluidId, LAVA)
		t.ok(record.fluid > 0, "its fill byte")
		local decoded = Protocol.decodeTransmitters(Protocol.encodeTransmitters({ record }))
		t.eq(decoded and decoded[1].fluidId, LAVA, "through the protocol")
		local chunk = TransmitterWorld.chunkRecords(s.pipes, 0, 0)
		t.eq(#chunk, 1)
		t.eq(chunk[1].fluidId, LAVA)
		-- Emptied: fluid id 0 with the fill; then oil.
		s.set(0, Y, 0, AIR)
		s.mode(1, Y, 0, WEST, M.NORMAL)
		s.tank(0, Y, 0, BIG_TANK, 0, 0)
		s.step(TransmitterWorld.FILL_INTERVAL * 2)
		local emptied = TransmitterWorld.takeRecords(s.pipes)
		t.eq(#emptied, 1)
		t.eq(emptied[1].fluidId, 0, "empty: no fluid")
		t.eq(emptied[1].fluid, 0)
		t.eq(#TransmitterWorld.chunkRecords(s.pipes, 0, 0), 0, "the emptied pipe is in the default state")
		s.set(0, Y, 0, AIR)
		s.tank(0, Y, 0, BIG_TANK, OIL, 10000)
		s.mode(1, Y, 0, WEST, M.PULL)
		s.step(TransmitterWorld.FILL_INTERVAL)
		local oil = TransmitterWorld.takeRecords(s.pipes)
		t.eq(#oil, 1)
		t.eq(oil[1].fluidId, OIL)
		-- Tank records carry the id too, and a tank's item keeps its lava.
		local tanks = select(2, TransmitterWorld.chunkRecords(s.pipes, 0, 0))
		t.eq(tanks[1].fluid, OIL)
		local data = TransmitterWorld.tankData(s.pipes, 0, Y, 0)
		t.eq(data and data.fluid, OIL)
		s.set(3, Y, 3, TANK)
		t.ok(TransmitterWorld.restoreTank(s.pipes, 3, Y, 3, { fluid = LAVA, amount = 5000 }))
		t.eq(s.fluid(3, Y, 3), LAVA)
		t.eq(s.amount(3, Y, 3), 5000)
		t.ok(not TransmitterWorld.restoreTank(s.pipes, 3, Y, 3, { fluid = 0, amount = 5000 }), "no fluid")
		t.ok(not TransmitterWorld.restoreTank(s.pipes, 3, Y, 3, { fluid = 9, amount = 5000 }), "unknown")
	end)

	--[[ Machines' fluid tanks through pipes ]]

	t.test("machines: pipes connect to machines with fluid tanks, through every side", function()
		for _, block in { GENERATOR, REFINERY, COMBUSTION } do
			t.ok(Transmitters.isFluidAcceptor(block), `{Blocks.get(block).name} takes pipes`)
			t.ok(Transmitters.isAcceptor("fluid", block))
			t.ok(Transmitters.isEnergyAcceptor(block), "and cables")
		end
		for _, block in { B.ElectricFurnace, B.SolarPanel, B.BasicBattery, CUBE, B.Chest, B.Furnace } do
			t.ok(not Transmitters.isFluidAcceptor(block), `{Blocks.get(block).name}: no tanks`)
		end
		local around: { [string]: number } = {}
		local sides = { { 0, -1, 0 }, { 0, 1, 0 }, { 0, 0, -1 }, { 0, 0, 1 }, { -1, 0, 0 }, { 1, 0, 0 } }
		for side, d in sides do
			around[`{d[1]},{d[2]},{d[3]}`] = if side % 2 == 0 then GENERATOR else REFINERY
		end
		local links, acceptors = Transmitters.connections(PIPE, 0, 0, 0, 0, 0, cells(around), function()
			return 0, 0
		end)
		t.eq(links, 0)
		t.eq(acceptors, 63, "every side")
		-- NONE cuts a side.
		local _, cut = Transmitters.connections(
			PIPE,
			Transmitters.withMode(0, UP, M.NONE),
			0,
			0,
			0,
			0,
			cells(around),
			function()
				return 0, 0
			end
		)
		t.eq(cut, 63 - 2)
	end)

	t.test("machines: the Heat Generator burns lava piped in; its input tank gives pipes nothing", function()
		local s = sim()
		s.tank(0, Y, 0, BIG_TANK, LAVA, 24000)
		s.set(1, Y, 0, PIPE)
		s.set(2, Y, 0, GENERATOR)
		s.mode(1, Y, 0, WEST, M.PULL)
		s.step(10)
		local generator = s.machine(2, Y, 0)
		t.eq(s.amount(0, Y, 0), 24000 - 10 * PULL_BASIC, "the pipe pulled 250 mB a tick")
		-- (Lava arrived in the first tick and a mB lit: it burns for 20 ticks, so one mB in 10.)
		t.eq(Machines.tankAmount(generator, "lava"), 10 * PULL_BASIC - 1, "a mB burning")
		t.eq(generator.data[ENERGY], 10 * 200, "200 J a tick")
		t.eq(Machines.get(generator, "rate"), 200)
		t.eq(Machines.get(generator, "active"), 1)
		t.eq(s.total(LAVA) + 1, 24000, "lava conserved")
		-- A PULL side on the generator takes nothing: input tanks never give to pipes.
		local p = sim()
		p.set(0, Y, 0, GENERATOR)
		Machines.tankInsert(p.machine(0, Y, 0), "lava", LAVA, 5000)
		p.machine(0, Y, 0).data[ENERGY] = 160000
		p.set(1, Y, 0, PIPE)
		p.tank(2, Y, 0, TANK, 0, 0)
		p.mode(1, Y, 0, WEST, M.PULL)
		p.step(5)
		t.eq(Machines.tankAmount(p.machine(0, Y, 0), "lava"), 5000, "full of energy: nothing burnt, nothing taken")
		t.eq(p.amount(2, Y, 0), 0)
		-- Water piped at it goes nowhere: its tank takes lava only.
		local w = sim()
		w.tank(0, Y, 0, BIG_TANK, WATER, 5000)
		w.set(1, Y, 0, PIPE)
		w.set(2, Y, 0, GENERATOR)
		w.mode(1, Y, 0, WEST, M.PULL)
		w.step(3)
		t.eq(Machines.tankAmount(w.machine(2, Y, 0), "lava"), 0)
		t.eq(w.network(1, Y, 0).amount, 3 * PULL_BASIC, "the water waits in the pipe")
	end)

	t.test("machines: oil piped into the Oil Refinery, its fuel ejected into a tank and burnt", function()
		local s = sim()
		-- Oil tank -> pipe -> refinery (powered by a creative cube touching it) -> fuel tank.
		s.tank(0, Y, 0, BIG_TANK, OIL, 10000)
		s.set(1, Y, 0, PIPE)
		s.mode(1, Y, 0, WEST, M.PULL)
		s.set(2, Y, 0, REFINERY)
		s.set(2, Y + 1, 0, CUBE)
		s.tank(3, Y, 0, TANK, 0, 0)
		s.step(300)
		local refinery = s.machine(2, Y, 0)
		local fuel = s.amount(3, Y, 0)
		t.eq(s.fluid(3, Y, 0), FUEL, "fuel pushed into the tank next to it")
		t.ok(fuel >= 2800 and fuel <= 3000, `10 mB a tick refined ({fuel} mB in 300 ticks)`)
		t.eq(Machines.tankAmount(refinery, "fuel"), 0, "its output tank pushed out every tick")
		t.eq(s.total(OIL) + s.total(FUEL), 10000, "oil becomes fuel 1:1")
		t.eq(s.amount(0, Y, 0), 0, "the pipe emptied the oil tank")
		-- The fuel tank feeds a Combustion Generator through a pipe: 2.5 kJ a tick, a mB every 4.
		s.set(4, Y, 0, PIPE)
		s.mode(4, Y, 0, WEST, M.PULL)
		s.set(5, Y, 0, COMBUSTION)
		local before = s.total(FUEL)
		s.step(100)
		local combustion = s.machine(5, Y, 0)
		t.ok(Machines.tankAmount(combustion, "fuel") > 0, "fuel in the generator's tank")
		t.eq(Machines.get(combustion, "rate"), 2500)
		t.ok(combustion.data[ENERGY] >= 99 * 2500, "about 100 ticks of 2.5 kJ")
		-- 100 ticks of refining in, 25 mB burnt (give or take the mB burning now).
		local burnt = before + 100 * 10 - s.total(FUEL)
		t.ok(burnt >= 24 and burnt <= 26, `about a mB every 4 ticks burnt ({burnt})`)
	end)

	t.test("machines: the ejector pushes through NORMAL and PULL pipe sides that lead somewhere", function()
		-- A refinery with fuel, a pipe east of it (its side facing it in `mode`) and a Fluid Tank
		-- beyond: somewhere for the fuel to go.
		local function setup(mode: number): any
			local s = sim()
			s.set(0, Y, 0, REFINERY)
			Machines.tankInsert(s.machine(0, Y, 0), "fuel", FUEL, 5000)
			s.set(1, Y, 0, ULTIMATE_PIPE)
			s.mode(1, Y, 0, WEST, mode)
			s.tank(2, Y, 0, TANK, 0, 0)
			return s
		end
		local expected = { [M.NORMAL] = Machines.FLUID_EJECT_RATE, [M.PULL] = Machines.FLUID_EJECT_RATE }
		for _, mode in { M.NORMAL, M.PUSH, M.PULL, M.NONE } do
			local s = setup(mode)
			local refinery = s.machine(0, Y, 0)
			local sent = TransmitterWorld.ejectFluid(s.pipes, 0, Y, 0, refinery)
			t.eq(sent, expected[mode] or 0, `{Transmitters.modeName(mode)}: the ejector`)
			t.eq(Machines.tankAmount(refinery, "fuel"), 5000 - sent)
			t.eq(s.network(1, Y, 0).amount, sent)
		end
		-- Not into a pipe that leads nowhere for fuel (the pipe feeding it oil), nor one whose only
		-- tank holds water.
		local feed = sim()
		feed.tank(2, Y, 0, BIG_TANK, OIL, 5000)
		feed.set(1, Y, 0, PIPE)
		feed.mode(1, Y, 0, EAST, M.PULL)
		feed.set(0, Y, 0, REFINERY)
		Machines.tankInsert(feed.machine(0, Y, 0), "fuel", FUEL, 5000)
		t.eq(TransmitterWorld.ejectFluid(feed.pipes, 0, Y, 0, feed.machine(0, Y, 0)), 0, "the oil line")
		feed.step(10)
		t.ok(feed.network(1, Y, 0).fluid ~= FUEL, "no fuel in the oil line")
		t.eq(Machines.tankAmount(feed.machine(0, Y, 0), "oil"), 10 * PULL_BASIC, "the oil keeps coming")
		local wet = sim()
		wet.set(0, Y, 0, REFINERY)
		Machines.tankInsert(wet.machine(0, Y, 0), "fuel", FUEL, 5000)
		wet.set(1, Y, 0, PIPE)
		wet.tank(2, Y, 0, TANK, WATER, 1000)
		t.eq(TransmitterWorld.ejectFluid(wet.pipes, 0, Y, 0, wet.machine(0, Y, 0)), 0, "only water beyond")
		-- At most the pipe's room, and not into a pipe holding another fluid.
		local small = sim()
		small.set(0, Y, 0, REFINERY)
		Machines.tankInsert(small.machine(0, Y, 0), "fuel", FUEL, 5000)
		small.set(1, Y, 0, PIPE)
		small.tank(2, Y, 0, TANK, FUEL, Transmitters.tankCapacity(TANK))
		t.eq(TransmitterWorld.ejectFluid(small.pipes, 0, Y, 0, small.machine(0, Y, 0)), 1024)
		t.eq(TransmitterWorld.ejectFluid(small.pipes, 0, Y, 0, small.machine(0, Y, 0)), 2000 - 1024, "full")
		local other = sim()
		other.tank(2, Y, 0, BIG_TANK, WATER, 1000)
		other.set(1, Y, 0, PIPE)
		other.mode(1, Y, 0, EAST, M.PULL)
		other.step(1)
		other.set(0, Y, 0, REFINERY)
		Machines.tankInsert(other.machine(0, Y, 0), "fuel", FUEL, 5000)
		t.eq(TransmitterWorld.ejectFluid(other.pipes, 0, Y, 0, other.machine(0, Y, 0)), 0, "water in the pipe")
		-- Split evenly between a Fluid Tank and a pipe; never into another machine.
		local split = sim()
		split.set(0, Y, 0, REFINERY)
		Machines.tankInsert(split.machine(0, Y, 0), "fuel", FUEL, 5000)
		split.tank(0, Y + 1, 0, TANK, 0, 0)
		split.set(1, Y, 0, ULTIMATE_PIPE)
		split.tank(2, Y, 0, TANK, 0, 0)
		split.set(-1, Y, 0, COMBUSTION)
		t.eq(TransmitterWorld.ejectFluid(split.pipes, 0, Y, 0, split.machine(0, Y, 0)), 1024)
		t.eq(split.amount(0, Y + 1, 0), 512, "half into the tank")
		t.eq(split.network(1, Y, 0).amount, 512, "half into the pipe")
		t.eq(Machines.tankAmount(split.machine(-1, Y, 0), "fuel"), 0, "none straight into a machine")
		-- The Heat Generator has no output tank: nothing to push.
		local heat = sim()
		heat.set(0, Y, 0, GENERATOR)
		Machines.tankInsert(heat.machine(0, Y, 0), "lava", LAVA, 5000)
		heat.tank(1, Y, 0, TANK, 0, 0)
		t.eq(TransmitterWorld.ejectFluid(heat.pipes, 0, Y, 0, heat.machine(0, Y, 0)), 0)
		heat.step(5)
		t.eq(heat.amount(1, Y, 0), 0)
	end)

	t.test("machines: the ejector never fills the oil tank its supply line pulls from, even empty", function()
		-- A compact refinery: its oil Fluid Tank right next to it, a pipe over each (the one over
		-- the tank pulling from it), a creative cube for power and a Fluid Tank under it for fuel.
		local s = sim()
		s.tank(0, Y, 0, TANK, OIL, 3000)
		s.set(1, Y, 0, REFINERY)
		s.set(2, Y, 0, CUBE)
		s.set(0, Y + 1, 0, PIPE)
		s.set(1, Y + 1, 0, PIPE)
		s.mode(0, Y + 1, 0, DOWN, M.PULL)
		s.tank(1, Y - 1, 0, TANK, 0, 0)
		s.step(600)
		t.eq(s.amount(0, Y, 0), 0, "the oil tank ran dry")
		t.eq(s.fluid(0, Y, 0), Fluids.NONE, "and took no fuel once empty")
		t.eq(s.network(0, Y + 1, 0).amount, 0, "no fuel in the oil line")
		t.eq(s.fluid(1, Y - 1, 0), FUEL)
		t.eq(s.amount(1, Y - 1, 0), 3000, "every mB refined into the fuel tank")
		-- Refilled, the oil line carries oil again.
		t.eq(TransmitterWorld.fillTank(s.pipes, 0, Y, 0, OIL, 3000), 3000, "the oil tank takes oil")
		s.step(600)
		t.eq(s.amount(0, Y, 0), 0, "drained again")
		t.eq(s.amount(1, Y - 1, 0), 6000, "and refined")
		t.eq(s.total(OIL) + s.total(FUEL), 6000, "nothing lost")
		-- (A tank that its pipe's network leads fuel to is no supply line: the ejector fills it.)
		local fed = sim()
		fed.set(0, Y, 0, REFINERY)
		Machines.tankInsert(fed.machine(0, Y, 0), "fuel", FUEL, 1000)
		fed.tank(1, Y, 0, TANK, 0, 0)
		fed.set(1, Y + 1, 0, PIPE)
		fed.mode(1, Y + 1, 0, DOWN, M.PULL)
		fed.set(1, Y + 2, 0, COMBUSTION)
		t.eq(TransmitterWorld.ejectFluid(fed.pipes, 0, Y, 0, fed.machine(0, Y, 0)), 1000, "into the tank")
		t.eq(fed.amount(1, Y, 0), 1000)
	end)

	t.test("machines: a PULL side drains output tanks; viewers hear of tank changes between steps", function()
		local s = sim()
		s.set(0, Y, 0, REFINERY)
		Machines.tankInsert(s.machine(0, Y, 0), "fuel", FUEL, 3000)
		Machines.tankInsert(s.machine(0, Y, 0), "oil", OIL, 3000)
		s.set(1, Y, 0, PIPE)
		s.mode(1, Y, 0, WEST, M.PULL)
		s.tank(2, Y, 0, TANK, 0, 0)
		-- (The ejector and the PULL side both take fuel; the oil never leaves.)
		s.step(20)
		t.eq(Machines.tankAmount(s.machine(0, Y, 0), "fuel"), 0, "all the fuel out")
		t.eq(Machines.tankAmount(s.machine(0, Y, 0), "oil"), 3000, "the oil stays")
		t.eq(s.amount(2, Y, 0) + s.network(1, Y, 0).amount, 3000)
		-- A full generator changes nothing in its tick; a bucket's lava poured between steps still
		-- reaches its viewers (MachineWorld compares with the last step).
		local g = sim()
		g.set(0, Y, 0, GENERATOR)
		local generator = g.machine(0, Y, 0)
		generator.data[ENERGY] = 160000
		g.step(3)
		g.step(1)
		local _, quiet = MachineWorld.takeChanges(g.machines)
		t.eq(next(quiet), nil, "nothing changes while it is full")
		t.ok(Machines.pourBucket(generator, LAVA))
		g.step(1)
		local _, data = MachineWorld.takeChanges(g.machines)
		t.ok(data[Coords.posKey(0, Y, 0)] ~= nil, "the poured lava is a change")
	end)

	t.test("machines: transporters take the Heat Generator's empty Buckets out, so its feed never jams", function()
		-- Chest -> transporter (PULL) -> Heat Generator -> transporter (PULL) -> chest.
		local s = sim()
		local TRANSPORTER = B.BasicLogisticalTransporter
		s.set(0, Y, 0, B.Chest)
		s.set(1, Y, 0, TRANSPORTER)
		s.set(2, Y, 0, GENERATOR)
		s.set(3, Y, 0, TRANSPORTER)
		s.set(4, Y, 0, B.Chest)
		t.ok(TransmitterWorld.setMode(s.pipes, 1, Y, 0, WEST, M.PULL), "the feed pulls from the chest")
		t.ok(TransmitterWorld.setMode(s.pipes, 3, Y, 0, WEST, M.PULL), "the other pulls from the generator")
		local source = s.containers:get(0, Y, 0, B.Chest)
		local sink = s.containers:get(4, Y, 0, B.Chest)
		source.slots[1] = S(I.LavaBucket, 1)
		source.slots[2] = S(I.LavaBucket, 1)
		source.slots[3] = S(I.Coal, 8)
		local function count(container: any, item: number): number
			local total = 0
			for _, stack in container.slots do
				if stack and stack.item == item then
					total += stack.count
				end
			end
			return total
		end
		s.step(400)
		local generator = s.machine(2, Y, 0)
		-- Both Lava Buckets poured (what burnt so far: one mB in 20 ticks), their Buckets pulled out
		-- and the coal fed in after them.
		t.eq(count(sink, I.Bucket), 2, "both empty Buckets taken out")
		local lava = Machines.tankAmount(generator, "lava")
		t.ok(lava >= 2000 - 20 and lava < 2000, `both buckets poured ({lava} mB left)`)
		t.eq(generator.slots[1] and generator.slots[1].item, I.Coal, "then the coal went in")
		t.eq(generator.slots[1] and generator.slots[1].count, 8, "all of it (the lava burns first)")
		t.eq(count(source, I.Coal) + count(source, I.LavaBucket), 0, "the chest emptied")
		-- Never the fuel back out.
		t.eq(count(sink, I.Coal) + count(sink, I.LavaBucket), 0, "no fuel pulled out")
		t.eq(s.pipes.itemCount, 0, "nothing left in transit")
	end)

	t.test("machines: records carry the tanks for WAILA; a tank change alone resends one", function()
		-- A full Heat Generator does nothing in its tick: only the lava poured into it changes.
		local g = sim()
		g.set(0, Y, 0, GENERATOR)
		local generator = g.machine(0, Y, 0)
		generator.data[ENERGY] = 160000
		g.step(MachineWorld.RECORD_INTERVAL + 1)
		local first = MachineWorld.takeRecords(g.machines)
		t.eq(#first, 1, "its energy went")
		local empty = first[1].tanks
		t.eq(empty and #empty, 1, "one tank")
		t.eq(empty and empty[1].fluid, 0, "empty")
		g.step(MachineWorld.RECORD_INTERVAL + 1)
		t.eq(#MachineWorld.takeRecords(g.machines), 0, "nothing new while it is full")
		t.ok(Machines.pourBucket(generator, LAVA))
		g.step(MachineWorld.RECORD_INTERVAL + 1)
		local records = MachineWorld.takeRecords(g.machines)
		t.eq(#records, 1, "the poured lava resends the record")
		local decoded = Protocol.decodeMachines(Protocol.encodeMachines(records))
		local tanks = decoded and decoded[1].tanks
		t.eq(tanks and #tanks, 1)
		t.eq(tanks and tanks[1].fluid, LAVA)
		t.eq(tanks and tanks[1].amount, 1000)
		t.eq(tanks and tanks[1].capacity, 24000)
		-- A refinery holding only oil is not in the default state: its chunk's edit list sends it.
		local r = sim()
		r.set(0, Y, 0, REFINERY)
		t.eq(#MachineWorld.chunkRecords(r.machines, 0, 0), 0, "an empty refinery needs no record")
		Machines.tankInsert(r.machine(0, Y, 0), "oil", OIL, 3000)
		local chunk = MachineWorld.chunkRecords(r.machines, 0, 0)
		t.eq(#chunk, 1, "its oil alone sends it")
		local oil = chunk[1].tanks
		t.eq(oil and #oil, 2, "oil and fuel")
		t.eq(oil and oil[1].fluid, OIL)
		t.eq(oil and oil[1].amount, 3000)
		t.eq(oil and oil[1].capacity, 10000)
		t.eq(oil and oil[2].fluid, 0, "no fuel yet")
		-- Kinds without tanks send none.
		r.set(2, Y, 0, CUBE)
		local cube = MachineWorld.record(MachineWorld.machine(r.machines, 2, Y, 0) :: any)
		t.eq(cube.tanks, nil)
	end)

	--[[ Buckets ]]

	local FLOOR = 10
	local CROP = 32
	local flat = {
		generate = function(level: number, nx: number, nz: number)
			local data = ChunkLayout.create(CROP)
			for y = 0, FLOOR - 1 do
				local block = if y == FLOOR - 1 then B.Grass else STONE
				for i = 0, ChunkLayout.LAYER - 1 do
					buffer.writeu16(data, (y * ChunkLayout.LAYER + i) * 2, block)
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
			return FLOOR, 1, 0, B.Grass
		end,
		findSpawn = function()
			return 0, FLOOR, 0
		end,
	}

	-- A flat world with pipes and machines following its changes, and a bucket env for it.
	local function bucketWorld(creative: boolean?, owned: { [number]: boolean }?)
		local world = WorldServer.new(flat :: any)
		local containers = Containers.new()
		local function peek(x: number, y: number, z: number): number?
			return world:peekBlock(x, y, z)
		end
		local pipes = TransmitterWorld.new({ getBlock = peek, containers = containers })
		local machines = MachineWorld.new({ getBlock = peek, containers = containers, transmitters = pipes })
		world.onChanged = function(x, y, z, old, new)
			if old ~= new then
				containers:take(x, y, z)
			end
			TransmitterWorld.blockChanged(pipes, x, y, z, old, new)
			MachineWorld.blockChanged(machines, x, y, z, old, new)
		end
		for cx = -1, 1 do
			for cz = -1, 1 do
				world:getChunk(cx, cz)
			end
		end
		local env = {
			world = world,
			pipes = pipes,
			containers = containers,
			creative = creative == true,
			hasItem = function(item: number): boolean
				return owned ~= nil and owned[item] == true
			end,
		}
		return env, world, pipes, containers
	end

	t.test("buckets: an empty bucket takes any fluid's source, cave twins too, never flowing fluid", function()
		local env, world = bucketWorld()
		for fluid = 1, Fluids.COUNT do
			local x = fluid * 2
			world:setBlock(x, FLOOR, 0, SOURCE[fluid])
			local done = UseRules.fillBucket(env, S(I.Bucket, 1), SOURCE[fluid], x, FLOOR, 0, false)
			assert(done, Fluids.name(fluid))
			t.eq(done.held and done.held.item, Fluids.bucketOf(fluid), `{Fluids.name(fluid)} Bucket`)
			t.eq(done.give, nil)
			t.eq(world:getBlock(x, FLOOR, 0), AIR, "the source is gone")
			t.ok(done.atPlayer, "the sound at the player")
			t.eq(done.sound, UseRules.bucketSound(fluid, true))
		end
		-- The cave twins fill the same buckets; a stack keeps the rest and hands the bucket over.
		for _, twin in { B.CaveLava, B.CaveOil } do
			world:setBlock(0, FLOOR, 4, twin)
			local done = UseRules.fillBucket(env, S(I.Bucket, 3), twin, 0, FLOOR, 4, false)
			assert(done, "twin")
			t.eq(done.held and done.held.count, 2)
			t.eq(done.give and done.give.item, Fluids.bucketOf(Fluids.ofBlock(twin)))
			t.eq(world:getBlock(0, FLOOR, 4), AIR)
		end
		-- Flowing lava, stone: nothing.
		local flowing = Blocks.fluidId("Lava", 2)
		world:setBlock(0, FLOOR, 6, flowing)
		t.eq(UseRules.fillBucket(env, S(I.Bucket, 1), flowing, 0, FLOOR, 6, false), nil)
		t.eq(world:getBlock(0, FLOOR, 6), flowing)
		t.eq(UseRules.fillBucket(env, S(I.Bucket, 1), STONE, 0, FLOOR - 2, 6, false), nil)
		-- Creative: keeps the bucket, gets a full one only without one already.
		local creative = bucketWorld(true, { [I.LavaBucket] = true })
		creative.world:setBlock(0, FLOOR, 0, SOURCE[LAVA])
		local kept = UseRules.fillBucket(creative, S(I.Bucket, 1), SOURCE[LAVA], 0, FLOOR, 0, false)
		assert(kept, "creative")
		t.eq(kept.held and kept.held.item, I.Bucket)
		t.eq(kept.give, nil, "has a Lava Bucket already")
		creative.world:setBlock(0, FLOOR, 0, SOURCE[OIL])
		local oil = UseRules.fillBucket(creative, S(I.Bucket, 1), SOURCE[OIL], 0, FLOOR, 0, false)
		t.eq(oil and oil.give and oil.give.item, I.OilBucket, "no Oil Bucket yet")
		-- The sounds: the fluid's own once Shared/Sounds has it, else the plain bucket's.
		local fill = SharedSounds.find("item.bucket.fill_lava") or SharedSounds.find("item.bucket.fill")
		t.eq(UseRules.bucketSound(LAVA, true), fill)
		t.ok(UseRules.bucketSound(WATER, false) == SharedSounds.find("item.bucket.empty"))
	end)

	t.test("buckets: a full bucket pours its source (never a twin) and destroys a plant with drops", function()
		local env, world = bucketWorld()
		local dropped = {}
		Drops.set(function(_x, _y, _z, stack)
			table.insert(dropped, stack.item)
		end)
		for fluid = 1, Fluids.COUNT do
			local x = fluid * 3
			local done =
				UseRules.emptyBucket(env, S(Fluids.bucketOf(fluid) :: number, 1), B.Grass, x, FLOOR - 1, 0, UP, false)
			assert(done, Fluids.name(fluid))
			t.eq(done.held and done.held.item, I.Bucket, "an empty bucket back")
			t.eq(world:getBlock(x, FLOOR, 0), SOURCE[fluid], "on top of the clicked block")
			t.eq(done.sound, UseRules.bucketSound(fluid, false))
		end
		-- Lava poured over a dead bush destroys it with its drop (BucketItem.emptyContents).
		world:setBlock(0, FLOOR - 1, 8, B.Sand)
		world:setBlock(0, FLOOR, 8, B.DeadBush)
		local done = UseRules.emptyBucket(env, S(I.LavaBucket, 1), B.DeadBush, 0, FLOOR, 8, UP, false)
		t.ok(done ~= nil)
		t.eq(world:getBlock(0, FLOOR, 8), SOURCE[LAVA])
		t.eq(#dropped, 1)
		t.eq(dropped[1], I.Stick)
		-- Into lava's own source: nothing changes, the bucket still empties. Into a cave twin: an
		-- ordinary source.
		local again = UseRules.emptyBucket(env, S(I.LavaBucket, 1), SOURCE[LAVA], 0, FLOOR, 8, UP, false)
		t.eq(again and again.held and again.held.item, I.Bucket)
		world:setBlock(5, FLOOR, 8, B.CaveOil)
		UseRules.emptyBucket(env, S(I.OilBucket, 1), B.CaveOil, 5, FLOOR, 8, UP, false)
		t.eq(world:getBlock(5, FLOOR, 8), SOURCE[OIL])
		-- Creative keeps the full bucket; other items do nothing.
		local creative = bucketWorld(true)
		local kept = UseRules.emptyBucket(creative, S(I.FuelBucket, 1), B.Grass, 0, FLOOR - 1, 0, UP, false)
		t.eq(kept and kept.held and kept.held.item, I.FuelBucket)
		t.eq(UseRules.emptyBucket(env, S(I.Stone, 1), B.Grass, 0, FLOOR - 1, 0, UP, false), nil)
		t.eq(UseRules.bucketFluid(I.Bucket), 0)
		t.eq(UseRules.bucketFluid(I.LavaBucket), LAVA)
		Drops.set(nil)
	end)

	t.test("buckets: Fluid Tanks and machines take and give whole buckets; sneaking skips them", function()
		local env, world, pipes, containers = bucketWorld()
		local function tankAt(x: number): any
			return TransmitterWorld.tank(pipes, x, FLOOR, 0)
		end
		-- A Fluid Tank: lava in, water refused, lava out.
		world:setBlock(0, FLOOR, 0, TANK)
		local done = UseRules.emptyBucket(env, S(I.LavaBucket, 1), TANK, 0, FLOOR, 0, UP, false)
		t.eq(done and done.held and done.held.item, I.Bucket)
		t.eq(tankAt(0).amount, 1000)
		t.eq(tankAt(0).fluid, LAVA)
		t.eq(UseRules.emptyBucket(env, S(I.WaterBucket, 1), TANK, 0, FLOOR, 0, UP, false), nil, "another fluid")
		local filled = UseRules.fillBucket(env, S(I.Bucket, 1), TANK, 0, FLOOR, 0, false)
		t.eq(filled and filled.held and filled.held.item, I.LavaBucket)
		t.eq(tankAt(0).amount, 0)
		t.eq(UseRules.fillBucket(env, S(I.Bucket, 1), TANK, 0, FLOOR, 0, false), nil, "empty")
		-- Sneaking pours beside it instead.
		local sneaked = UseRules.emptyBucket(env, S(I.OilBucket, 1), TANK, 0, FLOOR, 0, UP, true)
		t.ok(sneaked ~= nil)
		t.eq(world:getBlock(0, FLOOR + 1, 0), SOURCE[OIL], "on top of the tank")
		t.eq(tankAt(0).amount, 0)
		-- The Heat Generator takes Lava Buckets into its tank, not water; an empty bucket takes
		-- its lava back.
		world:setBlock(3, FLOOR, 0, GENERATOR)
		local generator = containers:peek(3, FLOOR, 0)
		local lava = UseRules.emptyBucket(env, S(I.LavaBucket, 1), GENERATOR, 3, FLOOR, 0, UP, false)
		t.eq(lava and lava.held and lava.held.item, I.Bucket)
		t.eq(Machines.tankAmount(generator, "lava"), 1000)
		t.eq(UseRules.emptyBucket(env, S(I.WaterBucket, 1), GENERATOR, 3, FLOOR, 0, UP, false), nil)
		t.eq(world:getBlock(3, FLOOR + 1, 0), AIR, "no water poured beside it either")
		local back = UseRules.fillBucket(env, S(I.Bucket, 1), GENERATOR, 3, FLOOR, 0, false)
		t.eq(back and back.held and back.held.item, I.LavaBucket)
		t.eq(Machines.tankAmount(generator, "lava"), 0)
		-- The Oil Refinery: oil in; an empty bucket takes fuel first (output), then oil (input).
		world:setBlock(6, FLOOR, 0, REFINERY)
		local refinery = containers:peek(6, FLOOR, 0)
		t.ok(UseRules.emptyBucket(env, S(I.OilBucket, 1), REFINERY, 6, FLOOR, 0, UP, false) ~= nil)
		t.eq(Machines.tankAmount(refinery, "oil"), 1000)
		t.eq(UseRules.emptyBucket(env, S(I.FuelBucket, 1), REFINERY, 6, FLOOR, 0, UP, false), nil, "no fuel in")
		Machines.tankInsert(refinery, "fuel", FUEL, 1500)
		local fuel = UseRules.fillBucket(env, S(I.Bucket, 1), REFINERY, 6, FLOOR, 0, false)
		t.eq(fuel and fuel.held and fuel.held.item, I.FuelBucket, "the output first")
		local oil = UseRules.fillBucket(env, S(I.Bucket, 1), REFINERY, 6, FLOOR, 0, false)
		t.eq(oil and oil.held and oil.held.item, I.OilBucket, "then the input")
		t.eq(UseRules.fillBucket(env, S(I.Bucket, 1), REFINERY, 6, FLOOR, 0, false), nil, "500 mB is no bucket")
		-- The Combustion Generator takes Fuel Buckets.
		world:setBlock(9, FLOOR, 0, COMBUSTION)
		t.ok(UseRules.emptyBucket(env, S(I.FuelBucket, 1), COMBUSTION, 9, FLOOR, 0, UP, false) ~= nil)
		t.eq(Machines.tankAmount(containers:peek(9, FLOOR, 0), "fuel"), 1000)
		-- Creative: the tank loses its bucket, the player gets nothing (Mekanism).
		local creative, cworld, _, ccontainers = bucketWorld(true)
		cworld:setBlock(0, FLOOR, 0, GENERATOR)
		Machines.tankInsert(ccontainers:peek(0, FLOOR, 0), "lava", LAVA, 2000)
		local taken = UseRules.fillBucket(creative, S(I.Bucket, 1), GENERATOR, 0, FLOOR, 0, false)
		t.eq(taken and taken.held and taken.held.item, I.Bucket)
		t.eq(taken and taken.give, nil)
		t.eq(Machines.tankAmount(ccontainers:peek(0, FLOOR, 0), "lava"), 1000)
	end)

	--[[ Furnaces, spawns ]]

	t.test("furnaces: a Lava Bucket burns 20 000 ticks and leaves the empty Bucket in the fuel slot", function()
		local containers = Containers.new()
		local furnace = containers:get(0, Y, 0, B.Furnace)
		t.ok(Smelting.result(I.Cobblestone) ~= nil, "cobblestone smelts")
		furnace.slots[1] = S(I.Cobblestone, 2)
		furnace.slots[2] = S(I.LavaBucket, 1)
		containers:markActive(0, Y, 0)
		containers:tickFurnaces()
		t.eq(furnace.slots[2] and furnace.slots[2].item, I.Bucket, "the bucket stays")
		t.eq(furnace.data[2], 20000)
		for _ = 1, 2 * Smelting.COOK_TIME do
			containers:tickFurnaces()
		end
		t.eq(furnace.slots[3] and furnace.slots[3].count, 2, "smelted on lava")
		t.ok(containers:peek(0, Y, 0) ~= nil, "kept (the bucket and the fire)")
	end)

	t.test("spawns: never in lava, oil or fuel, nor next to lava", function()
		local world = WorldServer.new(flat :: any)
		t.ok(SafeSpot.isSafe(world, 0, FLOOR, 0), "the flat ground")
		for _, block in { SOURCE[LAVA], SOURCE[OIL], SOURCE[FUEL], B.CaveLava, B.CaveOil } do
			world:setBlock(0, FLOOR, 0, block)
			t.ok(not SafeSpot.isSafe(world, 0, FLOOR, 0), `in {Blocks.get(block).name}`)
			world:setBlock(0, FLOOR, 0, AIR)
		end
		world:setBlock(1, FLOOR, 0, SOURCE[LAVA])
		t.ok(not SafeSpot.isSafe(world, 0, FLOOR, 0), "next to lava")
		world:setBlock(1, FLOOR, 0, SOURCE[OIL])
		t.ok(SafeSpot.isSafe(world, 0, FLOOR, 0), "next to oil is fine")
	end)

	--[[ Conservation ]]

	t.test("pipes: water and lava are never lost, made or mixed (fuzz)", function()
		local rng = Hash.rng(4242)
		local blocks = { PIPE, ULTIMATE_PIPE, PIPE, TANK, BIG_TANK, AIR }
		for round = 1, 20 do
			local s = sim()
			local start = { [WATER] = 0, [LAVA] = 0 }
			local function place(x: number, y: number, z: number)
				local block = blocks[rng:int(1, #blocks)]
				local tank = TransmitterWorld.tank(s.pipes, x, y, z)
				if tank and tank.amount > 0 and tank.block ~= block then
					-- (Replacing a tank loses its contents: count it out of the start.)
					start[tank.fluid] -= tank.amount
					s.pipes.lost -= tank.amount
				end
				s.set(x, y, z, block)
				if Transmitters.isTank(block) then
					local fluid = if rng:float() < 0.5 then WATER else LAVA
					start[fluid] += TransmitterWorld.fillTank(s.pipes, x, y, z, fluid, rng:int(0, 20) * 1000)
				elseif Transmitters.isTransmitter(block) then
					for side = 0, 5 do
						if rng:float() < 0.3 then
							TransmitterWorld.setMode(s.pipes, x, y, z, side, rng:int(0, 3))
						end
					end
				end
			end
			for x = 0, 4 do
				for y = Y, Y + 2 do
					for z = 0, 2 do
						place(x, y, z)
					end
				end
			end
			for _ = 1, 25 do
				s.step(rng:int(1, 20))
				local x, y, z = rng:int(0, 4), rng:int(Y, Y + 2), rng:int(0, 2)
				if rng:float() < 0.5 then
					place(x, y, z)
				elseif TransmitterWorld.node(s.pipes, x, y, z) then
					TransmitterWorld.cycleMode(s.pipes, x, y, z, rng:int(0, 5))
				end
				local water, lava = s.total(WATER), s.total(LAVA)
				t.ok(water <= start[WATER] and lava <= start[LAVA], `round {round}: no fluid turns into another`)
				t.eq(water + lava + s.pipes.lost, start[WATER] + start[LAVA], `round {round}: conserved`)
			end
		end
	end)
end

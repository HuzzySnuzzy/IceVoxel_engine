--[[
	Mekanism pipes on the server, water: Mechanical Pipe networks and Fluid Tanks in
	Transmitters/TransmitterWorld and Fluids on a fake world. Pull and push rates per tier, the
	even split, capacity limits, networks merging and splitting (buffers by capacity, a broken
	pipe's share lost), network work spread over ticks, the fill records, and a conservation fuzz.
]]

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Coords = require(shared.World.Coords)
	local Hash = require(shared.Util.Hash)
	local Transmitters = require(shared.Transmitters)
	local Containers = require(server.Players.Containers)
	local Fluids = require(server.Transmitters.Fluids)
	local TransmitterWorld = require(server.Transmitters.TransmitterWorld)

	local B = Blocks.id
	local AIR = Blocks.AIR
	local M = Transmitters.MODES
	local WATER = Transmitters.FLUIDS.WATER
	local DOWN, UP, NORTH, SOUTH, WEST, EAST = 0, 1, 2, 3, 4, 5
	local Y = 10
	local TIER_NAMES = { "Basic", "Advanced", "Elite", "Ultimate" }
	local PIPES, TANKS = {}, {}
	for tier, name in TIER_NAMES do
		PIPES[tier] = B[`{name}MechanicalPipe`]
		TANKS[tier] = B[`{name}FluidTank`]
	end

	local function newWorld()
		local blocks: { [number]: number } = {}
		local world = TransmitterWorld.new({
			getBlock = function(x: number, y: number, z: number): number?
				return blocks[Coords.posKey(x, y, z)] or AIR
			end,
			containers = Containers.new(),
		})
		local w = { world = world }
		function w.block(x: number, y: number, z: number): number
			return blocks[Coords.posKey(x, y, z)] or AIR
		end
		function w.set(x: number, y: number, z: number, block: number)
			local key = Coords.posKey(x, y, z)
			local old = blocks[key] or AIR
			blocks[key] = if block == AIR then nil else block
			TransmitterWorld.blockChanged(world, x, y, z, old, block)
		end
		function w.step(n: number?)
			for _ = 1, n or 1 do
				TransmitterWorld.step(world)
			end
		end
		-- A tank with `amount` mB of water.
		function w.tank(x: number, y: number, z: number, block: number, amount: number)
			w.set(x, y, z, block)
			if amount > 0 then
				t.eq(TransmitterWorld.fillTank(world, x, y, z, WATER, amount), amount, "tank filled")
			end
		end
		function w.amount(x: number, y: number, z: number): number
			local tank = TransmitterWorld.tank(world, x, y, z)
			return if tank then tank.amount else -1
		end
		function w.buffer(x: number, y: number, z: number): number
			local network = TransmitterWorld.network(world, x, y, z)
			return if network then network.amount else -1
		end
		-- All the water: in tanks, in buffers, and lost with broken pipes and tanks.
		function w.total(): number
			local total = world.lost
			for _, tank in world.tanks do
				total += tank.amount
			end
			for network in world.networks do
				total += network.amount
			end
			return total
		end
		return w
	end

	t.test("fluids: pipes pull and push at Mekanism's rates per tier", function()
		for tier = 1, 4 do
			local w = newWorld()
			w.tank(0, Y, 0, TANKS[4], 200000)
			w.set(1, Y, 0, PIPES[tier])
			w.set(2, Y, 0, PIPES[tier])
			w.tank(3, Y, 0, TANKS[4], 0)
			TransmitterWorld.setMode(w.world, 1, Y, 0, WEST, M.PULL)
			local pull = Transmitters.TIERS[tier].pipePull
			w.step()
			t.eq(w.amount(3, Y, 0), pull, `{TIER_NAMES[tier]}: one tick's pull, pushed on at once`)
			t.eq(w.amount(0, Y, 0), 200000 - pull)
			t.eq(w.buffer(1, Y, 0), 0, "the buffer passed it all on")
			w.step(2)
			t.eq(w.amount(3, Y, 0), 3 * pull)
			-- The network holds both pipes' capacity.
			local network = TransmitterWorld.network(w.world, 2, Y, 0)
			t.ok(network and network == TransmitterWorld.network(w.world, 1, Y, 0), "one network")
			t.eq(network and network.capacity, 2 * Transmitters.TIERS[tier].pipeCapacity, "capacity adds up")
			t.eq(w.total(), 200000, "conserved")
		end
		-- A PULL side never gives, and a tank on it is not filled; NONE cuts it off.
		local w = newWorld()
		w.tank(0, Y, 0, TANKS[1], 0)
		w.set(1, Y, 0, PIPES[1])
		w.tank(2, Y, 0, TANKS[1], 5000)
		TransmitterWorld.setMode(w.world, 1, Y, 0, EAST, M.PULL)
		TransmitterWorld.setMode(w.world, 1, Y, 0, WEST, M.PUSH)
		w.step(4)
		t.eq(w.amount(0, Y, 0), 1000, "pushed through the PUSH side")
		t.eq(w.amount(2, Y, 0), 4000, "pulled through the PULL side")
		TransmitterWorld.setMode(w.world, 1, Y, 0, WEST, M.NONE)
		w.step(4)
		t.eq(w.amount(0, Y, 0), 1000, "NONE: nothing more")
		t.eq(w.buffer(1, Y, 0), 1000, "it waits in the pipe")
	end)

	t.test("fluids: the buffer is split evenly over the tanks with room", function()
		local given = Fluids.split(1000, { 100, 5000, 5000 })
		t.eq(given[1], 100, "a tank with little room takes what it can")
		t.eq(given[2], 450, "the rest is shared")
		t.eq(given[3], 450)
		given = Fluids.split(10, { 5, 5, 5 })
		t.eq(given[1] + given[2] + given[3], 10, "whole mB, none lost")
		t.ok(math.max(given[1], given[2], given[3]) - math.min(given[1], given[2], given[3]) <= 1, "even")
		given = Fluids.split(100, { 10, 20 })
		t.eq(given[1] + given[2], 30, "what nobody takes stays")

		local w = newWorld()
		w.tank(0, Y - 1, 0, TANKS[4], 100000)
		w.set(0, Y, 0, PIPES[1])
		TransmitterWorld.setMode(w.world, 0, Y, 0, DOWN, M.PULL)
		w.tank(1, Y, 0, TANKS[1], 0)
		w.tank(-1, Y, 0, TANKS[1], 0)
		w.tank(0, Y + 1, 0, TANKS[1], 31900)
		w.step(12)
		t.eq(w.amount(0, Y + 1, 0), 32000, "the nearly full tank filled up")
		local a, b = w.amount(1, Y, 0), w.amount(-1, Y, 0)
		t.eq(a + b, 12 * 250 - 100, "the others got the rest")
		t.ok(math.abs(a - b) <= 12, "evenly")
		t.eq(w.total(), 100000 + 31900, "conserved")
	end)

	t.test("fluids: buffers and tanks never go beyond their capacity", function()
		local w = newWorld()
		w.tank(0, Y, 0, TANKS[4], 10000)
		w.set(1, Y, 0, PIPES[1])
		TransmitterWorld.setMode(w.world, 1, Y, 0, WEST, M.PULL)
		w.step(20)
		t.eq(w.buffer(1, Y, 0), 2000, "one basic pipe holds 2000 mB")
		t.eq(w.amount(0, Y, 0), 8000, "the rest stays in the tank")
		local network = TransmitterWorld.network(w.world, 1, Y, 0)
		t.eq(network and network.fluid, WATER)
		-- A tank with room for 300 mB.
		w.tank(2, Y, 0, TANKS[1], 31700)
		w.step(5)
		t.eq(w.amount(2, Y, 0), 32000, "full")
		t.eq(w.buffer(1, Y, 0), 2000, "topped up again from the source")
		t.eq(w.amount(0, Y, 0), 7700)
		t.eq(TransmitterWorld.fillTank(w.world, 2, Y, 0, WATER, 1000, true), 0, "a full tank takes nothing")
		t.eq(w.total(), 10000 + 31700)
	end)

	t.test("fluids: networks merge and split by capacity; a broken pipe loses its share", function()
		local w = newWorld()
		w.tank(-1, Y, 0, TANKS[1], 4000)
		w.set(0, Y, 0, PIPES[1])
		w.set(1, Y, 0, PIPES[1])
		w.set(3, Y, 0, PIPES[1])
		w.set(4, Y, 0, PIPES[1])
		w.tank(5, Y, 0, TANKS[1], 4000)
		TransmitterWorld.setMode(w.world, 0, Y, 0, WEST, M.PULL)
		TransmitterWorld.setMode(w.world, 4, Y, 0, EAST, M.PULL)
		w.step(30)
		t.eq(w.buffer(0, Y, 0), 4000, "left network full")
		t.eq(w.buffer(4, Y, 0), 4000, "right network full")
		t.eq(w.amount(-1, Y, 0), 0, "sources empty")
		t.ok(TransmitterWorld.network(w.world, 0, Y, 0) ~= TransmitterWorld.network(w.world, 4, Y, 0), "two networks")

		-- A pipe between them: one network, buffers added up.
		w.set(2, Y, 0, PIPES[1])
		w.step()
		local merged = TransmitterWorld.network(w.world, 2, Y, 0)
		t.ok(merged ~= nil and merged == TransmitterWorld.network(w.world, 0, Y, 0), "merged")
		t.ok(merged == TransmitterWorld.network(w.world, 4, Y, 0))
		t.eq(merged and merged.amount, 8000, "buffers add up")
		t.eq(merged and merged.capacity, 10000)
		t.eq(merged and merged.size, 5)

		-- Broken again: its share (2000 of 10000) is lost, the rest split by capacity.
		w.set(2, Y, 0, AIR)
		t.eq(w.world.lost, 1600, "the broken pipe's share")
		w.step()
		t.eq(w.buffer(0, Y, 0), 3200, "left half")
		t.eq(w.buffer(4, Y, 0), 3200, "right half")
		t.ok(TransmitterWorld.network(w.world, 0, Y, 0) ~= TransmitterWorld.network(w.world, 4, Y, 0), "split")
		t.eq(w.total(), 8000, "conserved, with the loss counted")

		-- A pipe cut off by NONE splits too, keeping its share.
		TransmitterWorld.setMode(w.world, 1, Y, 0, WEST, M.NONE)
		w.step()
		t.eq(w.buffer(0, Y, 0) + w.buffer(1, Y, 0), 3200, "both halves together")
		t.eq(w.buffer(1, Y, 0), 1600, "by capacity")
		-- A broken tank loses its water.
		w.tank(0, Y + 1, 0, TANKS[1], 5000)
		w.set(0, Y + 1, 0, AIR)
		t.eq(w.world.lost, 1600 + 5000)
		t.eq(w.total(), 8000 + 5000)
	end)

	t.test("fluids: network work is spread over ticks and carried over", function()
		local w = newWorld()
		for x = 0, 9 do
			w.set(x, Y, 0, PIPES[2])
		end
		t.ok(TransmitterWorld.rebuilding(w.world), "queued")
		TransmitterWorld.rebuild(w.world, 4)
		t.ok(w.world.job ~= nil, "a flood fill in progress")
		t.ok(TransmitterWorld.network(w.world, 0, Y, 0) ~= TransmitterWorld.network(w.world, 9, Y, 0), "not joined yet")
		for _ = 1, 3 do
			TransmitterWorld.rebuild(w.world, 4)
		end
		t.ok(not TransmitterWorld.rebuilding(w.world), "done")
		local network = TransmitterWorld.network(w.world, 0, Y, 0)
		t.ok(network ~= nil and network == TransmitterWorld.network(w.world, 9, Y, 0), "one network")
		t.eq(network and network.size, 10)
		local count = 0
		for _ in w.world.networks do
			count += 1
		end
		t.eq(count, 1, "the lone pipes' networks are gone")
	end)

	t.test("fluids: pipe fills and tank contents are replicated at most 4 times a second", function()
		local w = newWorld()
		w.tank(0, Y, 0, TANKS[4], 100000)
		w.set(1, Y, 0, PIPES[1])
		w.set(2, Y, 0, PIPES[1])
		TransmitterWorld.setMode(w.world, 1, Y, 0, WEST, M.PULL)
		local records, tanks = TransmitterWorld.takeRecords(w.world)
		t.eq(#tanks, 1, "the filled tank at once")
		t.eq(tanks[1].amount, 100000)
		w.step()
		records, tanks = TransmitterWorld.takeRecords(w.world)
		t.eq(#records, 2, "both pipes")
		t.eq(records[1].fluid, Transmitters.fillLevel(250, 4000))
		t.eq(#tanks, 0, "the tank waits: it was sent a tick ago")
		w.step()
		records, tanks = TransmitterWorld.takeRecords(w.world)
		t.eq(#records, 0, "not again within 5 ticks")
		t.eq(#tanks, 0)
		w.step(4)
		records, tanks = TransmitterWorld.takeRecords(w.world)
		t.eq(#records, 2, "5 ticks later")
		t.eq(records[1].fluid, Transmitters.fillLevel(250 * 6, 4000))
		t.eq(#tanks, 1)
		t.eq(tanks[1].amount, 100000 - 250 * 6)
		-- The chunk's records hold the fill and the tank.
		local chunk, chunkTanks = TransmitterWorld.chunkRecords(w.world, 0, 0)
		t.eq(#chunk, 2)
		t.eq(#chunkTanks, 1)
		t.eq(chunkTanks[1].fluid, WATER)
	end)

	t.test("fluids: no water is lost or made (fuzz)", function()
		local rng = Hash.rng(99)
		local blocks = { PIPES[1], PIPES[2], PIPES[3], PIPES[4], PIPES[1], TANKS[1], TANKS[2], AIR }
		for round = 1, 30 do
			local w = newWorld()
			local added = 0
			local function place(x: number, y: number, z: number)
				local block = blocks[rng:int(1, #blocks)]
				w.set(x, y, z, block)
				if Transmitters.isTank(block) then
					local amount = rng:int(0, 20) * 1000
					added += TransmitterWorld.fillTank(w.world, x, y, z, WATER, amount)
				end
			end
			for x = 0, 4 do
				for y = Y, Y + 2 do
					for z = 0, 2 do
						place(x, y, z)
						if Transmitters.isTransmitter(w.block(x, y, z)) then
							for side = 0, 5 do
								if rng:float() < 0.3 then
									TransmitterWorld.setMode(w.world, x, y, z, side, rng:int(0, 3))
								end
							end
						end
					end
				end
			end
			for _ = 1, 25 do
				w.step(rng:int(1, 30))
				local x, y, z = rng:int(0, 4), rng:int(Y, Y + 2), rng:int(0, 2)
				if rng:float() < 0.5 then
					place(x, y, z)
				elseif Transmitters.isTransmitter(w.block(x, y, z)) then
					TransmitterWorld.cycleMode(w.world, x, y, z, rng:int(0, 5))
				end
				t.eq(w.total(), added, `round {round}: water conserved`)
				for network in w.world.networks do
					t.ok(network.amount >= 0 and network.amount <= network.capacity, "a buffer within capacity")
					t.eq(network.amount, math.floor(network.amount), "whole mB")
				end
				for _, tank in w.world.tanks do
					t.ok(tank.amount >= 0 and tank.amount <= tank.capacity, "a tank within capacity")
				end
			end
			-- Settled, the networks are exactly the joined pipes.
			TransmitterWorld.rebuild(w.world, math.huge)
			for _, node in w.world.nodes do
				local network = node.network
				t.ok(network ~= nil and network.nodes[node.key] == node, "every pipe in its network")
				for side = 0, 5 do
					if bit32.btest(node.links, bit32.lshift(1, side)) then
						local dx, dy, dz = Transmitters.offset(side)
						t.eq(
							TransmitterWorld.network(w.world, node.x + dx, node.y + dy, node.z + dz),
							network,
							"joined pipes share a network"
						)
					end
				end
			end
			for network in w.world.networks do
				local size, capacity = 0, 0
				for _, node in network.nodes do
					size += 1
					capacity += Transmitters.pipeCapacity(node.block)
				end
				t.eq(network.size, size, "size")
				t.eq(network.capacity, capacity, "capacity")
			end
		end
	end)
end

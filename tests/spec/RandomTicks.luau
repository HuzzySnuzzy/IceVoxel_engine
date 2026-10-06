--[[
	Random ticks (server World/RandomTicker: Minecraft's randomTickSpeed per section) and what they
	drive: grass spreading onto dirt under the open sky (Behaviours/Grass), fast leaf decay once a
	tree has no log within 6 blocks (Behaviours/Leaves; leaves players placed stay), leaves' drops
	(Items.leafDrop) and saplings growing into their trees (Behaviours/Sapling), on a flat world
	with a generated tree.
]]

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local WorldServer = require(server.World.WorldServer)
	local BlockTicker = require(server.World.BlockTicker)
	local RandomTicker = require(server.World.RandomTicker)
	local Behaviours = require(server.Behaviours)
	local Grass = require(server.Behaviours.Grass)
	local Leaves = require(server.Behaviours.Leaves)
	local Sapling = require(server.Behaviours.Sapling)
	local Drops = require(server.Behaviours.Drops)
	local EditRules = require(server.Network.EditRules)

	local B, I = Blocks.id, Items.id
	local AIR, STONE, GRASS, DIRT = Blocks.AIR, B.Stone, B.Grass, B.Dirt
	local FLOOR = 10
	local CROP = 32
	-- A generated oak in chunk (0, 0): trunk at (4, FLOOR..FLOOR+4, 4), leaves of radius 2 at
	-- FLOOR+3 and FLOOR+4, radius 1 at FLOOR+5.
	local TX, TZ = 4, 4

	local function set(data: buffer, x: number, y: number, z: number, block: number)
		buffer.writeu16(data, ((y * ChunkLayout.PADDED + z + 1) * ChunkLayout.PADDED + x + 1) * 2, block)
	end

	local generator = {
		generate = function(level: number, nx: number, nz: number)
			local data = ChunkLayout.create(CROP)
			for y = 0, FLOOR - 1 do
				local block = if y == FLOOR - 1 then GRASS else STONE
				for i = 0, ChunkLayout.LAYER - 1 do
					buffer.writeu16(data, (y * ChunkLayout.LAYER + i) * 2, block)
				end
			end
			if nx == 0 and nz == 0 then
				for dy = 3, 5 do
					local r = if dy == 5 then 1 else 2
					for dx = -r, r do
						for dz = -r, r do
							set(data, TX + dx, FLOOR + dy, TZ + dz, B.OakLeaves)
						end
					end
				end
				for dy = 0, 4 do
					set(data, TX, FLOOR + dy, TZ, B.OakLog)
				end
			end
			return {
				data = data,
				level = level,
				nx = nx,
				nz = nz,
				height = CROP,
				solidBelow = FLOOR,
				emptyAbove = FLOOR + 6,
			}
		end,
		column = function()
			return FLOOR, 1, 0, GRASS
		end,
		findSpawn = function()
			return 0, FLOOR, 0
		end,
	}

	local function newWorld()
		local world = WorldServer.new(generator :: any)
		local ticker = BlockTicker.new(world, Behaviours.byId, 100000)
		world.onChanged = function(x, y, z)
			ticker:blockChanged(x, y, z)
		end
		local dropped = {}
		Drops.set(function(_x, _y, _z, stack)
			table.insert(dropped, stack)
		end)
		for cx = -1, 1 do
			for cz = -1, 1 do
				world:getChunk(cx, cz)
			end
		end
		return world, ticker, dropped
	end

	-- A random cycling through `values`.
	local function cycle(values: { number }): () -> number
		local i = 0
		return function(): number
			i += 1
			return values[(i - 1) % #values + 1]
		end
	end

	local function count(world: any, block: number): number
		local n = 0
		for x = -8, 24 do
			for z = -8, 24 do
				for y = FLOOR, FLOOR + 8 do
					if world:peekBlock(x, y, z) == block then
						n += 1
					end
				end
			end
		end
		return n
	end

	t.test("random ticks: Minecraft's 3 picks per 16-block section of chunks near players", function()
		local world, ticker = newWorld()
		local hits = 0
		local fake = {
			[STONE] = {
				onRandomTick = function()
					hits += 1
				end,
			},
		}
		local random = RandomTicker.new(world, BlockTicker.new(world, fake :: any, 10))
		local chunk = world:getChunk(0, 0)
		-- (CROP 32: two sections; picks below FLOOR - 1 land on stone.)
		local seed = 1
		local function rand(): number
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed / 2147483648
		end
		local given = RandomTicker.step(random, { chunk }, 3, rand)
		t.eq(given, hits)
		t.ok(hits >= 1 and hits <= 6, `at most 3 a section ({hits})`)
		t.eq(RandomTicker.step(random, { chunk }, 0, rand), 0, "speed 0: off")
		-- The real behaviours: grass, leaves and saplings tick at random; stone doesn't.
		local real = RandomTicker.new(world, ticker)
		t.ok(real.ticking[GRASS] ~= nil and real.ticking[B.OakLeaves] ~= nil and real.ticking[B.OakSapling] ~= nil)
		t.eq(real.ticking[STONE], nil)
	end)

	t.test("grass: spreads onto lit dirt next to it, never under a roof; dies under a block", function()
		local world, ticker = newWorld()
		world:setBlock(1, FLOOR - 1, 12, DIRT)
		-- Picks: dx +1, dy 0, dz 0.
		Grass.onRandomTick(world, ticker, 0, FLOOR - 1, 12, GRASS, cycle({ 0.9, 0.7, 0.5 }))
		t.eq(world:getBlock(1, FLOOR - 1, 12), GRASS, "spread")
		-- Dirt under a roof (stone 3 above) stays dirt.
		world:setBlock(1, FLOOR - 1, 14, DIRT)
		world:setBlock(1, FLOOR + 3, 14, STONE)
		Grass.onRandomTick(world, ticker, 0, FLOOR - 1, 14, GRASS, cycle({ 0.9, 0.7, 0.5 }))
		t.eq(world:getBlock(1, FLOOR - 1, 14), DIRT, "no sky, no grass")
		t.ok(not Grass.takes(world, 1, FLOOR - 1, 14))
		-- Dirt with a block on it doesn't take it.
		world:setBlock(1, FLOOR - 1, 16, DIRT)
		world:setBlock(1, FLOOR, 16, STONE)
		t.ok(not Grass.takes(world, 1, FLOOR - 1, 16))
		-- Dry grass spreads as dry grass; podzol never spreads.
		world:setBlock(0, FLOOR - 1, 18, B.DryGrass)
		world:setBlock(1, FLOOR - 1, 18, DIRT)
		Grass.onRandomTick(world, ticker, 0, FLOOR - 1, 18, B.DryGrass, cycle({ 0.9, 0.7, 0.5 }))
		t.eq(world:getBlock(1, FLOOR - 1, 18), B.DryGrass)
		world:setBlock(0, FLOOR - 1, 20, B.Podzol)
		world:setBlock(1, FLOOR - 1, 20, DIRT)
		Grass.onRandomTick(world, ticker, 0, FLOOR - 1, 20, B.Podzol, cycle({ 0.9, 0.7, 0.5 }))
		t.eq(world:getBlock(1, FLOOR - 1, 20), DIRT)
		-- Covered: dirt.
		world:setBlock(0, FLOOR, 22, STONE)
		Grass.onRandomTick(world, ticker, 0, FLOOR - 1, 22, GRASS, cycle({ 0.5 }))
		t.eq(world:getBlock(0, FLOOR - 1, 22), DIRT)
		-- Over many random ticks a patch of dirt in a lawn turns green.
		for x = 10, 12 do
			world:setBlock(x, FLOOR - 1, 10, DIRT)
		end
		local seed = 7
		local function rand(): number
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed / 2147483648
		end
		for _ = 1, 400 do
			for x = 9, 13 do
				for z = 9, 11 do
					local block = world:getBlock(x, FLOOR - 1, z)
					if block == GRASS then
						Grass.onRandomTick(world, ticker, x, FLOOR - 1, z, block, rand)
					end
				end
			end
		end
		for x = 10, 12 do
			t.eq(world:getBlock(x, FLOOR - 1, 10), GRASS, `({x}) grew over`)
		end
	end)

	t.test("leaves: held by a log within 6 through leaves; unloaded blocks hold them", function()
		local function sparse(blocks: { [string]: number | false })
			return function(x: number, y: number, z: number): number?
				local b = blocks[`{x},{y},{z}`]
				if b == false then
					return nil
				end
				return b or AIR
			end
		end
		local line: { [string]: number | false } = { ["0,0,0"] = B.OakLog }
		for x = 1, 7 do
			line[`{x},0,0`] = B.BirchLeaves
		end
		t.ok(Leaves.supported(sparse(line), 1, 0, 0), "next to the log")
		t.ok(Leaves.supported(sparse(line), 6, 0, 0), "6 away")
		t.ok(not Leaves.supported(sparse(line), 7, 0, 0), "7 away: decays")
		line["8,0,0"] = false
		t.ok(Leaves.supported(sparse(line), 7, 0, 0), "an unloaded neighbour may be a log")
	end)

	t.test("leaves: a felled tree's canopy decays within seconds; placed leaves stay", function()
		local world, ticker, dropped = newWorld()
		local before = count(world, B.OakLeaves)
		t.eq(before, (25 - 1) * 2 + 9, "the trunk takes a leaf on each of its top two layers")
		-- Placed leaves far from any log.
		world:setBlock(20, FLOOR, 20, B.OakLeaves)
		for y = FLOOR, FLOOR + 4 do
			world:setBlock(TX, y, TZ, AIR)
		end
		local ticks = 0
		repeat
			ticker:step()
			ticks += 1
		until ticker:pendingCount() == 0 or ticks > 2000
		t.eq(count(world, B.OakLeaves), 1, "only the placed leaf is left")
		t.eq(world:getBlock(20, FLOOR, 20), B.OakLeaves)
		t.ok(ticks < 200, `gone in {ticks} ticks ({ticks / 20} s)`)
		t.ok(#dropped <= before, "at most a drop a leaf")
		-- With its trunk the tree stays, whatever ticks.
		local world2, ticker2 = newWorld()
		world2:setBlock(TX + 2, FLOOR + 3, TZ + 2, AIR)
		for _ = 1, 100 do
			ticker2:step()
		end
		Leaves.onRandomTick(world2, ticker2, TX + 2, FLOOR + 4, TZ + 2, B.OakLeaves, math.random)
		t.eq(count(world2, B.OakLeaves), before - 1)
	end)

	t.test("leaves drop a sapling one time in 20 (jungle 40) or sticks one in 50, by hand too", function()
		t.eq((Items.leafDrop(B.OakLeaves, cycle({ 0 })) :: any).item, I.OakSapling)
		t.eq((Items.leafDrop(B.SpruceLeaves, cycle({ 0.049 })) :: any).item, I.SpruceSapling)
		t.eq(Items.leafDrop(B.JungleLeaves, cycle({ 0.03, 0.5 })), nil, "jungle: 1 in 40")
		local sticks = Items.leafDrop(B.OakLeaves, cycle({ 0.5, 0.01, 0.9 })) :: any
		t.eq(sticks.item, I.Stick)
		t.eq(sticks.count, 2)
		t.eq(Items.leafDrop(B.OakLeaves, cycle({ 0.5 })), nil)
		t.eq(Items.leafDrop(STONE, cycle({ 0 })), nil, "not leaves")
		local saplings = 0
		for _ = 1, 4000 do
			local stack = EditRules.drops(B.OakLeaves, false, nil)
			if stack and stack.item == I.OakSapling then
				saplings += 1
			end
		end
		t.ok(saplings > 120 and saplings < 290, `about 200 saplings from 4000 leaves by hand ({saplings})`)
		t.eq((EditRules.drops(B.OakLeaves, false, I.Shears) :: any).item, I.OakLeaves, "Shears: the leaves")
		t.eq(EditRules.drops(B.OakLeaves, true, nil), nil, "creative: nothing")
	end)

	t.test("saplings: grow into their tree under the sky when it has room", function()
		for block, _ in Sapling.BUILDERS do
			t.ok(Blocks.isPlant(block), `{Blocks.get(block).name} is a plant`)
			t.ok(Items.ofBlock(block) ~= nil, "and an item")
		end
		local world, ticker = newWorld()
		world:setBlock(12, FLOOR, 12, B.BirchSapling)
		t.ok(Sapling.grow(world, 12, FLOOR, 12, B.BirchSapling, 42))
		t.eq(world:getBlock(12, FLOOR, 12), B.BirchLog, "the trunk where the sapling was")
		t.eq(world:getBlock(12, FLOOR + 3, 12), B.BirchLog)
		t.ok(count(world, B.BirchLeaves) > 20, "a canopy")
		-- No room: stone in the trunk's way.
		world:setBlock(16, FLOOR, 16, B.OakSapling)
		world:setBlock(16, FLOOR + 2, 16, STONE)
		t.ok(not Sapling.grow(world, 16, FLOOR, 16, B.OakSapling, 42))
		t.eq(world:getBlock(16, FLOOR, 16), B.OakSapling)
		-- A random tick grows it only on a winning roll and under the sky.
		world:setBlock(16, FLOOR + 2, 16, AIR)
		Sapling.onRandomTick(world, ticker, 16, FLOOR, 16, B.OakSapling, cycle({ 0.5 }))
		t.eq(world:getBlock(16, FLOOR, 16), B.OakSapling, "lost the roll")
		Sapling.onRandomTick(world, ticker, 16, FLOOR, 16, B.OakSapling, cycle({ 0, 0.3 }))
		t.eq(world:getBlock(16, FLOOR, 16), B.OakLog, "grew")
		-- It pops off without its soil, like any plant.
		world:setBlock(20, FLOOR, 12, B.OakSapling)
		world:setBlock(20, FLOOR - 1, 12, AIR)
		for _ = 1, 5 do
			ticker:step()
		end
		t.eq(world:getBlock(20, FLOOR, 12), AIR)
	end)
end

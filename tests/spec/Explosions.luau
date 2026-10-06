--[[
	Explosions and burning fuel: Minecraft's Explosion maths (Shared/World/Explosion: the 1352
	rays, blast resistance, seen percent, damage and knockback, drops and fire), BlockList's
	blast resistances, fuel catching from lava and fire and blowing up harder the more of it is
	connected (server World/FuelBlast: measuring, power, chained blasts; World/Explosions running
	them in a world with Behaviours/Fluid), what blasts do to items (Entities/EntityWorld) and
	players (Players/Burning.hurtPlayer, PlayerPhysics.knockback), the Explosion message and the
	client's camera shake.
]]

return function(t, shared, require, server, client)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Config = require(shared.Config)
	local Coords = require(shared.World.Coords)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Explosion = require(shared.World.Explosion)
	local GameMode = require(shared.GameMode)
	local PlayerPhysics = require(shared.Movement.PlayerPhysics)
	local Protocol = require(shared.Net.Protocol)
	local SharedSounds = require(shared.Sounds)
	local WorldServer = require(server.World.WorldServer)
	local BlockTicker = require(server.World.BlockTicker)
	local Behaviours = require(server.Behaviours)
	local Drops = require(server.Behaviours.Drops)
	local FuelBlast = require(server.World.FuelBlast)
	local Explosions = require(server.World.Explosions)
	local Burning = require(server.Players.Burning)
	local EntityWorld = require(server.Entities.EntityWorld)
	local ExplosionView = require(client.Rendering.ExplosionView)

	local B = Blocks.id
	local AIR, STONE = Blocks.AIR, B.Stone
	local FUEL, LAVA, FIRE = B.Fuel, B.Lava, B.Fire
	local Settings = Config.Explosions
	local FLOOR = 20
	local CROP = 48

	-- A deterministic random in [0, 1) (a small LCG).
	local function lcg(seed: number): () -> number
		local state = seed
		return function(): number
			state = (state * 1103515245 + 12345) % 2147483648
			return state / 2147483648
		end
	end
	local function constant(value: number): () -> number
		return function(): number
			return value
		end
	end

	-- A pure block field: `blocks` by Coords.posKey, else `default` (nil: not loaded).
	local function field(blocks: { [number]: number }, default: number?)
		return function(x: number, y: number, z: number): number?
			local block = blocks[Coords.posKey(x, y, z)]
			if block ~= nil then
				return block
			end
			return default
		end
	end

	local function has(cells: { number }, x: number, y: number, z: number): boolean
		return table.find(cells, Coords.posKey(x, y, z)) ~= nil
	end

	-- A flat world: stone below FLOOR, air above.
	local generator = {
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
			return FLOOR - 1, 1, 0, STONE
		end,
		findSpawn = function()
			return 0, FLOOR, 0
		end,
	}

	type Call = { tick: number, x: number, y: number, z: number, power: number }

	local function newWorld(seed: number?)
		local world = WorldServer.new(generator :: any)
		local ticker = BlockTicker.new(world, Behaviours.byId, 100000)
		world.onChanged = function(x, y, z)
			ticker:blockChanged(x, y, z)
		end
		for cx = -2, 2 do
			for cz = -2, 2 do
				world:getChunk(cx, cz)
			end
		end
		Explosions.setRandom(world, lcg(seed or 7))
		local calls: { Call } = {}
		local tick = 0
		Explosions.setHandler(function(x, y, z, power, getBlock)
			assert(type(getBlock) == "function", "the handler gets the blocks")
			table.insert(calls, { tick = tick, x = x, y = y, z = z, power = power })
		end)
		local function run(ticks: number)
			for _ = 1, ticks do
				tick += 1
				ticker:step()
				Explosions.step(world)
			end
		end
		return world, ticker, calls, run
	end

	local function countIn(
		world: any,
		test: (number) -> boolean,
		x0: number,
		x1: number,
		y0: number,
		y1: number,
		z0: number,
		z1: number
	): number
		local n = 0
		for x = x0, x1 do
			for y = y0, y1 do
				for z = z0, z1 do
					local block = world:peekBlock(x, y, z)
					if block and test(block) then
						n += 1
					end
				end
			end
		end
		return n
	end

	t.test("explosion: Minecraft's 1352 rays from the faces of a 16 x 16 x 16 cube, all unit length", function()
		t.eq(Explosion.RAY_COUNT, 1352, "rays")
		t.eq(#Explosion.RAYS, 1352 * 3, "flat directions")
		local sx, sy, sz = 0, 0, 0
		for i = 0, Explosion.RAY_COUNT - 1 do
			local x, y, z = Explosion.RAYS[i * 3 + 1], Explosion.RAYS[i * 3 + 2], Explosion.RAYS[i * 3 + 3]
			t.near(math.sqrt(x * x + y * y + z * z), 1, 1e-9, "unit")
			sx += x
			sy += y
			sz += z
		end
		t.near(sx, 0, 1e-6, "symmetric x")
		t.near(sy, 0, 1e-6, "symmetric y")
		t.near(sz, 0, 1e-6, "symmetric z")
		-- (The first ray is the cube's corner (-1, -1, -1).)
		t.near(Explosion.RAYS[1], -1 / math.sqrt(3), 1e-9, "Minecraft's order")
	end)

	t.test("blast resistance: Minecraft's numbers, hardness by default, fluids 100, fuel 0", function()
		local function resistance(name: string): number
			return Blocks.get(B[name]).blastResistance
		end
		t.eq(resistance("Stone"), 6)
		t.eq(resistance("Cobblestone"), 6)
		t.eq(resistance("Dirt"), 0.5)
		t.eq(resistance("Planks"), 3)
		t.eq(resistance("OakLog"), 2)
		t.eq(resistance("Glass"), 0.3)
		t.eq(resistance("Obsidian"), 1200)
		t.eq(resistance("Bedrock"), 3600000)
		t.eq(resistance("StructureBlock"), 3600000, "creative only")
		t.eq(resistance("Water"), 100)
		t.eq(resistance("WaterFlow3"), 100)
		t.eq(resistance("Lava"), 100)
		t.eq(resistance("CaveLava"), 100)
		t.eq(resistance("Oil"), 100, "crude oil is no explosive")
		t.eq(resistance("Fuel"), 0)
		t.eq(resistance("FuelFlow5"), 0)
		t.eq(resistance("FuelFalling"), 0)
		t.eq(resistance("Air"), 0)
		t.eq(resistance("Fire"), 0)
		t.eq(buffer.readf32(Blocks.blastResistanceLut, STONE * 4), 6, "the lookup table")
	end)

	t.test("explosion: TNT breaks dirt 4.5 blocks away but not stone, which it breaks 1.5 away", function()
		local x, y, z = 0.5, 64.5, 0.5
		local dirt = field({ [Coords.posKey(5, 64, 0)] = B.Dirt }, AIR)
		local stone = field({ [Coords.posKey(5, 64, 0)] = STONE }, AIR)
		local near = field({ [Coords.posKey(2, 64, 0)] = STONE }, AIR)
		t.ok(has((Explosion.affected(dirt, x, y, z, 4, constant(0.5))), 5, 64, 0), "dirt goes")
		t.ok(
			not has((Explosion.affected(stone, x, y, z, 4, constant(0.999))), 5, 64, 0),
			"stone stays, even for the strongest rays"
		)
		t.ok(has((Explosion.affected(near, x, y, z, 4, constant(0.5))), 2, 64, 0), "stone close by goes")
		local obsidian = field({ [Coords.posKey(1, 64, 0)] = B.Obsidian }, AIR)
		t.ok(not has((Explosion.affected(obsidian, x, y, z, 12, constant(0.999))), 1, 64, 0), "obsidian holds")
		-- Air cells are affected too (fire lands there), and rays run about 1.73 x power in air.
		local open, reads = Explosion.affected(field({}, AIR), x, y, z, 4, constant(0.5))
		t.ok(has(open, 3, 64, 0), "air 3 blocks away")
		t.ok(not has(open, 6, 64, 0), "but not 6 at average intensity")
		t.ok(reads > 1352, "reads counted")
	end)

	t.test("explosion: in water nothing breaks; fuel does not shield; unloaded blocks stop rays", function()
		local water = field({}, B.Water)
		t.eq(#(Explosion.affected(water, 0.5, 64.5, 0.5, 4, constant(0.999))), 0, "water swallows TNT")
		local fuel = field({}, FUEL)
		t.ok(#(Explosion.affected(fuel, 0.5, 64.5, 0.5, 4, constant(0.5))) > 100, "fuel lets it through")
		local edge = function(bx: number, _by: number, _bz: number): number?
			return if bx >= 3 then nil else AIR
		end
		local cells = Explosion.affected(edge, 0.5, 64.5, 0.5, 4, constant(0.999))
		for _, key in cells do
			local cx = Coords.decodePosKey(key)
			t.ok(cx < 3, "never past an unloaded block")
		end
		-- Rays stop at the world's floor.
		for _, key in Explosion.affected(field({}, AIR), 0.5, 1.5, 0.5, 4, constant(0.5)) do
			local _, cy = Coords.decodePosKey(key)
			t.ok(cy >= 0, "inside the world")
		end
	end)

	t.test("explosion: Minecraft's damage and knockback (TNT 57 at the centre, 22 at 4 blocks)", function()
		t.eq(Explosion.damage(4, 1), 57, "TNT, fully exposed, at the centre")
		t.eq(Explosion.damage(6, 1), 85, "a charged creeper")
		t.eq(Explosion.damage(4, 0), 1, "in reach behind a wall")
		local damage, kx, ky, kz = Explosion.hit(0, 0, 0, 4, 4, 0, 0, 1.62, 1)
		t.eq(damage, 22, "half the reach away")
		t.near(math.sqrt(kx * kx + ky * ky + kz * kz), 0.5, 1e-9, "pushed by the impact")
		t.ok(kx > 0 and ky > 0 and kz == 0, "away from the centre, aimed at the eyes")
		t.eq((Explosion.hit(0, 0, 0, 4, 8.01, 0, 0, 1.62, 1)), nil, "beyond 2 x power")
		local behind, bx = Explosion.hit(0, 0, 0, 4, 2, 0, 0, 1.62, 0)
		t.eq(behind, 1, "a wall between: 1")
		t.eq(bx, 0, "and no push")
		t.eq(Explosion.dropChance(4), 0.25, "drops 1 / power")
		t.eq(Explosion.dropChance(0.5), 1)
	end)

	t.test("explosion: seen percent samples the body box (3 x 5 x 3 for a player)", function()
		local open = field({}, AIR)
		t.eq(Explosion.seenPercent(open, 0.5, 64.5, 0.5, 2.7, 64, 0.2, 3.3, 65.8, 0.8), 1, "in the open")
		local walled: { [number]: number } = {}
		for wy = 55, 75 do
			for wz = -10, 10 do
				walled[Coords.posKey(2, wy, wz)] = STONE
			end
		end
		t.eq(
			Explosion.seenPercent(field(walled, AIR), 0.5, 64.5, 0.5, 3.2, 64, 0.2, 3.8, 65.8, 0.8),
			0,
			"behind a wall"
		)
		local low: { [number]: number } = {}
		for wz = -10, 10 do
			low[Coords.posKey(2, 64, wz)] = STONE
		end
		local half = Explosion.seenPercent(field(low, AIR), 0.5, 64.5, 0.5, 3.2, 64, 0.2, 3.8, 65.8, 0.8)
		t.ok(half > 0 and half < 1, `half covered: {half}`)
		t.near(half * 45, math.round(half * 45), 1e-9, "a share of 45 points")
	end)

	t.test("fuel: what catches it and what each cell counts", function()
		t.ok(FuelBlast.isFuel(FUEL) and FuelBlast.isFuel(B.FuelFlow4) and FuelBlast.isFuel(B.FuelFalling), "fuel")
		t.ok(not FuelBlast.isFuel(B.Oil) and not FuelBlast.isFuel(B.Water), "oil and water are not")
		t.ok(FuelBlast.isHot(FIRE) and FuelBlast.isHot(LAVA), "fire and lava")
		t.ok(FuelBlast.isHot(B.LavaFlow6) and FuelBlast.isHot(B.CaveLava), "flowing lava and the cave twin")
		t.ok(not FuelBlast.isHot(B.Torch) and not FuelBlast.isHot(B.Oil) and not FuelBlast.isHot(nil), "not torches")
		t.eq(FuelBlast.weight(FUEL), 1, "a source is a bucket")
		t.eq(FuelBlast.weight(B.FuelFlow1), 7 / 8 * Settings.FlowingShare)
		t.eq(FuelBlast.weight(B.FuelFlow7), 1 / 8 * Settings.FlowingShare)
		t.eq(FuelBlast.weight(B.FuelFalling), Settings.FlowingShare)
		t.eq(FuelBlast.weight(B.Water), 0)
		local blocks = { [Coords.posKey(0, 10, 0)] = FUEL, [Coords.posKey(1, 10, 0)] = LAVA }
		t.ok(FuelBlast.exposed(field(blocks, AIR), 0, 10, 0), "lava beside")
		t.ok(not FuelBlast.exposed(field({ [Coords.posKey(0, 10, 0)] = FUEL }, AIR), 0, 10, 0), "nothing hot")
	end)

	t.test("fuel: power grows with the cube root of the buckets (a bucket is TNT), capped", function()
		t.near(FuelBlast.power(1), 4, 1e-9, "a bucket: TNT")
		t.near(FuelBlast.power(8), 8, 1e-9)
		t.near(FuelBlast.power(4), 4 * 4 ^ (1 / 3), 1e-9, "a 2 x 2 puddle: a charged creeper")
		t.near(FuelBlast.power(27), 12, 1e-9)
		t.eq(FuelBlast.power(1000), Settings.MaxPower, "capped")
		t.eq(FuelBlast.power(1e-6), Settings.MinPower, "at least")
		t.eq(FuelBlast.power(0), 0, "nothing")
		-- A bucket poured on flat ground: a source and 112 flowing cells.
		local puddle: { [number]: number } = {}
		for dx = -7, 7 do
			for dz = -7, 7 do
				local d = math.abs(dx) + math.abs(dz)
				if d <= 7 then
					puddle[Coords.posKey(dx, 10, dz)] = if d == 0 then FUEL else B["FuelFlow" .. d]
				end
			end
		end
		local body = FuelBlast.measure(field(puddle, AIR), 0, 10, 0)
		t.eq(#body.cells, 113, "every cell")
		t.near(body.volume, 1 + 42 * Settings.FlowingShare, 1e-9, "about 3.6 buckets")
		local blasts = FuelBlast.plan(body, 0, 10, 0)
		t.eq(blasts[1].delay, 0, "where it caught goes at once")
		t.ok(blasts[1].power >= 4, "the source's blast")
		local real, flashes = 0, 0
		for _, blast in blasts do
			if blast.power > 0 then
				real += 1
			else
				flashes += 1
			end
		end
		t.eq(real, 1, "one blast")
		t.ok(flashes > 0, "the thin edge flashes into fire")
	end)

	t.test("fuel: measuring follows connected fuel, at most MaxCells, never claimed or unloaded cells", function()
		local line: { [number]: number } = {}
		for x = 0, 99 do
			line[Coords.posKey(x, 10, 0)] = FUEL
		end
		local get = field(line, AIR)
		t.eq(#FuelBlast.measure(get, 0, 10, 0, nil, 10).cells, 10, "capped")
		local body = FuelBlast.measure(get, 50, 10, 0)
		t.eq(#body.cells, 100, "both ways")
		t.eq(body.volume, 100)
		t.eq(body.distances[#body.distances], 50, "distance through the fuel")
		local claimed = { [Coords.posKey(60, 10, 0)] = true }
		t.eq(#FuelBlast.measure(get, 50, 10, 0, claimed).cells, 60, "stops at claimed fuel")
		t.eq(#FuelBlast.measure(get, 60, 10, 0, claimed).cells, 0, "claimed: nothing")
		local cut = function(x: number, y: number, z: number): number?
			if x >= 20 then
				return nil
			end
			return get(x, y, z)
		end
		t.eq(#FuelBlast.measure(cut, 0, 10, 0).cells, 20, "stops at unloaded chunks")
		t.eq(#FuelBlast.measure(get, 0, 11, 0).cells, 0, "no fuel there")
	end)

	t.test("fuel: a big body is planned as several staggered blasts, each cell in one", function()
		local pool: { [number]: number } = {}
		for x = 0, 11 do
			for z = 0, 11 do
				for y = 10, 11 do
					pool[Coords.posKey(x, y, z)] = FUEL
				end
			end
		end
		local body = FuelBlast.measure(field(pool, STONE), 0, 11, 0)
		t.eq(#body.cells, 288)
		t.eq(body.volume, 288)
		local blasts = FuelBlast.plan(body, 0, 11, 0)
		t.eq(#blasts, 16, "4 x 4 cubes")
		local seen: { [number]: boolean } = {}
		local last = -1
		local delays: { [number]: boolean } = {}
		for _, blast in blasts do
			t.ok(blast.delay >= last, "in order")
			last = blast.delay
			delays[blast.delay] = true
			t.ok(blast.power > 4 and blast.power <= Settings.MaxPower, "big blasts")
			for _, key in blast.cells do
				t.ok(not seen[key], "each cell once")
				seen[key] = true
			end
		end
		local distinct = 0
		for _ in delays do
			distinct += 1
		end
		t.ok(distinct >= 5, `staggered over several ticks ({distinct})`)
		t.eq(blasts[1].delay, 0)
		t.ok(blasts[#blasts].delay >= 10, "the far corner a while later")
		local one =
			FuelBlast.plan(FuelBlast.measure(field({ [Coords.posKey(0, 10, 0)] = FUEL }, AIR), 0, 10, 0), 0, 10, 0)
		t.eq(#one, 1, "a bucket: one blast")
		t.near(one[1].power, 4, 1e-9)
		t.eq(one[1].x, 0.5, "at the fuel's centre")
	end)

	t.test("world: fuel next to lava explodes like TNT, consumed, the lava stays", function()
		local world, _, calls, run = newWorld()
		local y = FLOOR - 1
		world:setBlock(8, y, 8, FUEL)
		run(3)
		t.eq(#calls, 0, "nothing hot yet")
		world:setBlock(9, y, 8, LAVA)
		run(2)
		t.eq(#calls, 1, "one blast")
		t.near(calls[1].power, 4, 1e-9, "a bucket's")
		t.eq(calls[1].x, 8.5)
		t.ok(world:peekBlock(8, y, 8) ~= FUEL, "the fuel burnt up")
		t.eq(world:peekBlock(9, y, 8), LAVA, "lava resists")
		t.eq(world:peekBlock(7, y, 8), AIR, "the stone beside it is gone")
		t.eq(world:peekBlock(8, y - 6, 8), STONE, "deep stone stays")
		t.eq(Explosions.pending(world), 0)
	end)

	t.test("world: fuel next to fire explodes; fuel flowing next to lava catches", function()
		local world, _, calls, run = newWorld()
		local y = FLOOR - 1
		world:setBlock(8, y, 8, FUEL)
		world:setBlock(8, y + 1, 8, FIRE)
		run(2)
		t.eq(#calls, 1, "fire above")

		local world2, _, calls2, run2 = newWorld()
		world2:setBlock(8, y, 8, LAVA)
		world2:setBlock(13, FLOOR, 8, FUEL)
		run2(60)
		t.ok(#calls2 >= 1, "the flowing fuel reached the lava and went off")
		t.ok(world2:peekBlock(13, FLOOR, 8) ~= FUEL, "its source with it")
	end)

	t.test("world: a pool chains into staggered blasts that consume it all", function()
		local world, _, calls, run = newWorld(11)
		for x = 4, 15 do
			for z = 4, 15 do
				for y = FLOOR - 2, FLOOR - 1 do
					world:setBlock(x, y, z, FUEL)
				end
			end
		end
		run(2)
		t.eq(#calls, 0, "fuel alone is calm")
		world:setBlock(3, FLOOR - 1, 4, LAVA)
		run(1)
		t.ok(#calls >= 1, "the near corner goes at once")
		t.ok(Explosions.isClaimed(world, 15, FLOOR - 1, 15), "the far corner is waiting")
		t.eq(world:peekBlock(15, FLOOR - 1, 15), FUEL, "untouched by the first blasts")
		run(60)
		t.ok(#calls >= 16, `one blast per cube ({#calls})`)
		local ticks: { [number]: number } = {}
		local maxPower = 0
		for _, call in calls do
			ticks[call.tick] = (ticks[call.tick] or 0) + 1
			maxPower = math.max(maxPower, call.power)
		end
		local distinct = 0
		for _, n in ticks do
			distinct += 1
			t.ok(n <= Settings.MaxBlastsPerTick, "per tick bound")
		end
		t.ok(distinct >= 5, `spread over ticks ({distinct})`)
		t.eq(maxPower, Settings.MaxPower, "the middle of the pool hits the cap")
		run(200)
		t.eq(countIn(world, FuelBlast.isFuel, -4, 24, FLOOR - 10, FLOOR + 4, -4, 24), 0, "no fuel left")
		t.ok(not Explosions.isClaimed(world, 15, FLOOR - 1, 15), "claims released")
		t.eq(Explosions.pending(world), 0, "nothing waiting")
	end)

	t.test("world: fiery blasts set fire over opaque blocks; plain ones don't; drops 1 / power", function()
		local world, _, _, run = newWorld(3)
		Explosions.explode(world, 8.5, FLOOR + 0.5, 8.5, 4, true)
		run(1)
		local fires = 0
		for x = -2, 18 do
			for z = -2, 18 do
				for y = FLOOR - 8, FLOOR + 8 do
					if world:peekBlock(x, y, z) == FIRE then
						fires += 1
						t.ok(Blocks.isOpaque(world:peekBlock(x, y - 1, z) :: number), "on an opaque block")
					end
				end
			end
		end
		t.ok(fires > 0, `fire set ({fires})`)

		local plain = newWorld(3)
		Explosions.explode(plain, 8.5, FLOOR + 0.5, 8.5, 4)
		Explosions.step(plain)
		t.eq(
			countIn(plain, function(b)
				return b == FIRE
			end, -2, 18, FLOOR - 8, FLOOR + 8, -2, 18),
			0,
			"no fire"
		)

		local dropped = {}
		Drops.set(function(_x, _y, _z, stack)
			table.insert(dropped, stack)
		end)
		local drops = newWorld(5)
		drops:setBlock(8, FLOOR, 8, B.Dirt)
		Explosions.explode(drops, 8.5, FLOOR + 0.5, 8.5, 1)
		Explosions.step(drops)
		Drops.set(nil)
		t.eq(drops:peekBlock(8, FLOOR, 8), AIR, "the dirt is gone")
		local dirt = 0
		for _, stack in dropped do
			if stack.item == Items.id.Dirt then
				dirt += 1
			end
		end
		t.eq(dirt, 1, "and dropped (power 1: always)")
	end)

	t.test("world: blasts within the per-tick ray budget, the first always goes", function()
		local world = newWorld(9)
		for i = 1, 12 do
			Explosions.explode(world, 8.5 + i, FLOOR + 0.5, 8.5, Settings.MaxPower)
		end
		local first = Explosions.step(world)
		t.ok(first >= 1 and first < 12, `some wait ({first})`)
		local total = first
		for _ = 1, 20 do
			total += Explosions.step(world)
		end
		t.eq(total, 12, "all go in the end")
	end)

	t.test(
		"players: explosion hurts share the hurt cooldown, armor softens them, invulnerable modes take none",
		function()
			local state = Burning.newPlayer()
			t.eq(Burning.hurtPlayer(state, GameMode.SURVIVAL, 22), 22, "lands")
			t.eq(Burning.hurtPlayer(state, GameMode.SURVIVAL, 10), 0, "a smaller one under the cooldown")
			t.eq(Burning.hurtPlayer(state, GameMode.SURVIVAL, 30), 8, "a bigger one by the difference")
			local armored = Burning.newPlayer()
			t.near(
				Burning.hurtPlayer(armored, GameMode.ADVENTURE, 22, 20, 8),
				Items.damageAfterArmor(22, 20, 8),
				1e-9,
				"armor"
			)
			t.eq(Burning.hurtPlayer(Burning.newPlayer(), GameMode.CREATIVE, 57), 0, "creative")
			t.eq(Burning.hurtPlayer(Burning.newPlayer(), GameMode.SPECTATOR, 57), 0, "spectator")
			-- The cooldown runs out with the ticks.
			local later = Burning.newPlayer()
			Burning.hurtPlayer(later, GameMode.SURVIVAL, 10)
			for _ = 1, Burning.HURT_COOLDOWN do
				Burning.tickPlayer(later, GameMode.SURVIVAL, 0)
			end
			t.eq(Burning.hurtPlayer(later, GameMode.SURVIVAL, 5), 5, "after the cooldown")
		end
	)

	t.test("players: knockback adds to the hull's velocity, not for spectators or creative flight", function()
		local state = PlayerPhysics.new(0, FLOOR, 0)
		t.ok(PlayerPhysics.knockback(state, 0.3, 0.2, -0.1), "applied")
		t.eq(state.vx, 0.3)
		t.eq(state.vy, 0.2)
		t.eq(state.vz, -0.1)
		local spectator = PlayerPhysics.new(0, FLOOR, 0)
		PlayerPhysics.setGameMode(spectator, GameMode.SPECTATOR)
		t.ok(not PlayerPhysics.knockback(spectator, 0.3, 0.2, 0), "spectator")
		local creative = PlayerPhysics.new(0, FLOOR, 0)
		PlayerPhysics.setGameMode(creative, GameMode.CREATIVE)
		t.ok(PlayerPhysics.knockback(creative, 0.3, 0, 0), "creative on foot")
		creative.flying = true
		t.ok(not PlayerPhysics.knockback(creative, 0.3, 0, 0), "creative flying")
		t.ok(not PlayerPhysics.knockback(state, 0 / 0, 0, 0), "nonsense")
	end)

	t.test("items: a blast destroys items near it and pushes the rest away", function()
		local get = function(_x: number, y: number, _z: number): number?
			return if y < FLOOR then STONE else AIR
		end
		local items = EntityWorld.new(get, { maxItems = 100, lifetimeTicks = 6000 })
		local near = items:spawnItem(Items.id.Dirt, 1, 8.5, FLOOR, 8.5, 0, 0, 0)
		local far = items:spawnItem(Items.id.Dirt, 1, 16, FLOOR, 8.5, 0, 0, 0)
		local out = items:spawnItem(Items.id.Dirt, 1, 30, FLOOR, 8.5, 0, 0, 0)
		items:takeChanges()
		t.eq(items:explode(8.5, FLOOR + 0.5, 8.5, 4), 1, "one destroyed")
		t.eq(items:get(near), nil, "the near one")
		local pushed = items:get(far)
		t.ok(pushed ~= nil, "the far one survives (7.5 blocks: 2 damage)")
		local entity = pushed :: any
		t.eq(entity.health, Burning.ITEM_HEALTH - 2)
		t.ok(entity.body.vx > 0, "pushed away")
		t.eq((items:get(out) :: any).body.vx, 0, "out of reach")
		local changes = items:takeChanges()
		t.eq(#changes.removed, 1)
		t.ok(table.find(changes.moved, far) ~= nil, "resynced at once")
	end)

	t.test("Explosion message: round trip and malformed payloads", function()
		local effect = { x = 1.5, y = 20.25, z = -3, power = 12, kx = 0.5, ky = 0.25, kz = -0.125 }
		local decoded = Protocol.decodeExplosion(Protocol.encodeExplosion(effect)) :: any
		t.ok(decoded ~= nil, "decodes")
		for key, value in effect do
			t.eq(decoded[key], value, key)
		end
		t.eq(Protocol.EXPLOSION_BYTES, 28)
		t.eq(Protocol.decodeExplosion(buffer.create(27)), nil, "short")
		local bad = table.clone(effect)
		bad.power = 0 / 0
		t.eq(Protocol.decodeExplosion(Protocol.encodeExplosion(bad)), nil, "NaN")
		bad.power = Protocol.MAX_EXPLOSION_POWER + 1
		t.eq(Protocol.decodeExplosion(Protocol.encodeExplosion(bad)), nil, "too powerful")
		local push = table.clone(effect)
		push.kx = Protocol.MAX_KNOCKBACK + 1
		t.eq(Protocol.decodeExplosion(Protocol.encodeExplosion(push)), nil, "too hard a push")
		t.ok(Protocol.ServerMessage.Explosion ~= nil, "a server message")
	end)

	t.test("client: the sound is Minecraft's, the shake fades with distance", function()
		local event = SharedSounds.get("entity.generic.explode") :: any
		t.ok(event ~= nil, "entity.generic.explode")
		t.eq(event.side, "server")
		t.eq(event.maxDistance, 64, "heard 64 blocks away")
		t.eq(ExplosionView.shake(0, 4), 1, "TNT at the centre")
		t.eq(ExplosionView.shake(0, 1), 0.25, "a small blast")
		t.eq(ExplosionView.shake(Settings.ShakeDistance * 4, 4), 0, "out of reach")
		t.near(ExplosionView.shake(Settings.ShakeDistance * 2, 4), 0.5, 1e-9, "half way")
		t.eq(ExplosionView.shake(0, 0), 0)
	end)
end

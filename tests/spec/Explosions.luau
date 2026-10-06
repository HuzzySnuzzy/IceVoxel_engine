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

	t.test("blast resistance: Minecraft's numbers, hardness by default, fluids 100 (fuel too)", function()
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
		t.eq(resistance("Fuel"), 100, "liquid petrol is no explosive")
		t.eq(resistance("FuelFlow5"), 100)
		t.eq(resistance("FuelFalling"), 100)
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

	t.test("explosion: in water (or fuel) nothing breaks; unloaded blocks stop rays", function()
		local water = field({}, B.Water)
		t.eq(#(Explosion.affected(water, 0.5, 64.5, 0.5, 4, constant(0.999))), 0, "water swallows TNT")
		local fuel = field({}, FUEL)
		t.eq(#(Explosion.affected(fuel, 0.5, 64.5, 0.5, 4, constant(0.999))), 0, "so does fuel")
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

	t.test("fuel: what catches it; it is flammable", function()
		t.ok(FuelBlast.isFuel(FUEL) and FuelBlast.isFuel(B.FuelFlow4) and FuelBlast.isFuel(B.FuelFalling), "fuel")
		t.ok(not FuelBlast.isFuel(B.Oil) and not FuelBlast.isFuel(B.Water), "oil and water are not")
		t.ok(FuelBlast.isHot(FIRE) and FuelBlast.isHot(LAVA), "fire and lava")
		t.ok(FuelBlast.isHot(B.LavaFlow6) and FuelBlast.isHot(B.CaveLava), "flowing lava and the cave twin")
		t.ok(not FuelBlast.isHot(B.Torch) and not FuelBlast.isHot(B.Oil) and not FuelBlast.isHot(nil), "not torches")
		local blocks = { [Coords.posKey(0, 10, 0)] = FUEL, [Coords.posKey(1, 10, 0)] = LAVA }
		t.ok(FuelBlast.exposed(field(blocks, AIR), 0, 10, 0), "lava beside")
		t.ok(not FuelBlast.exposed(field({ [Coords.posKey(0, 10, 0)] = FUEL }, AIR), 0, 10, 0), "nothing hot")
		for _, name in { "Fuel", "FuelFlow3", "FuelFalling" } do
			t.ok(Blocks.isFlammable(B[name]), `{name} burns`)
			t.eq(Blocks.burnOdds(B[name]), 7, "about a minute a block under a fire")
		end
		t.ok(not Blocks.isFlammable(B.Oil), "crude oil doesn't")
		t.ok(FuelBlast.isOpen(AIR) and FuelBlast.isOpen(FIRE) and FuelBlast.isOpen(B.Torch), "vapour passes")
		t.ok(not FuelBlast.isOpen(STONE) and not FuelBlast.isOpen(FUEL) and not FuelBlast.isOpen(B.Water))
	end)

	t.test("fuel: a closed space's vapour blast from its energy (a room 1.2, a hall 5.4)", function()
		-- 48 m3 of mix: 48 x 3.5 MJ x 0.2 / 4.6 MJ = 7.3 kg of TNT; 250 kg is Minecraft's TNT (4).
		local mix, power, tnt, fill = FuelBlast.vapour(4, 48)
		t.eq(mix, 48, "4 m2 fill up to 64 m3")
		t.near(tnt, 48 * 3.5 * 0.2 / 4.6, 1e-9)
		t.near(power, 4 * (tnt / 250) ^ (1 / 3), 1e-9)
		t.ok(power > 1.1 and power < 1.4, `a room: a small blast ({power})`)
		t.eq(fill, 1, "full")
		local thin, _, _, part = FuelBlast.vapour(1, 48)
		t.eq(thin, 16, "a square metre of puddle fills 16 m3")
		t.near(part, 1 / 3, 1e-9)
		local _, hall = FuelBlast.vapour(256, 4096)
		t.ok(hall > 5.3 and hall < 5.5, `a 16 x 16 x 16 hall over a 16 x 16 pool: a big TNT blast ({hall})`)
		t.ok(hall <= Settings.MaxPower)
		t.eq(select(2, FuelBlast.vapour(0, 48)), 0, "no surface, no vapour")
		t.eq(select(2, FuelBlast.vapour(4, 0)), 0)
	end)

	t.test("fuel: measuring follows connected fuel, at most MaxCells, never skipped or unloaded cells", function()
		local line: { [number]: number } = {}
		for x = 0, 99 do
			line[Coords.posKey(x, 10, 0)] = FUEL
		end
		local get = field(line, AIR)
		t.eq(#FuelBlast.measure(get, 0, 10, 0, nil, 10).cells, 10, "capped")
		local body = FuelBlast.measure(get, 50, 10, 0)
		t.eq(#body.cells, 100, "both ways")
		t.eq(body.distances[#body.distances], 50, "distance through the fuel")
		local skip = { [Coords.posKey(60, 10, 0)] = true }
		t.eq(#FuelBlast.measure(get, 50, 10, 0, skip).cells, 60, "stops at skipped fuel")
		t.eq(#FuelBlast.measure(get, 60, 10, 0, skip).cells, 0, "skipped: nothing")
		local cut = function(x: number, y: number, z: number): number?
			if x >= 20 then
				return nil
			end
			return get(x, y, z)
		end
		t.eq(#FuelBlast.measure(cut, 0, 10, 0).cells, 20, "stops at unloaded chunks")
		t.eq(#FuelBlast.measure(get, 0, 11, 0).cells, 0, "no fuel there")
	end)

	-- A 4 x 4 room, 2 high, in stone, with a 2 x 2 pool of fuel in its floor and a glass east wall.
	local function room(open: boolean?): { [number]: number }
		local blocks: { [number]: number } = {}
		for x = 0, 3 do
			for z = 0, 3 do
				for y = 11, 12 do
					blocks[Coords.posKey(x, y, z)] = AIR
				end
			end
		end
		for x = 0, 1 do
			for z = 0, 1 do
				blocks[Coords.posKey(x, 10, z)] = FUEL
			end
		end
		for z = 0, 3 do
			for y = 11, 12 do
				blocks[Coords.posKey(4, y, z)] = B.Glass
			end
		end
		if open then
			-- A shaft up through the roof, out to the sky.
			for y = 13, 40 do
				blocks[Coords.posKey(3, y, 3)] = AIR
			end
		end
		return blocks
	end

	-- Stone up to y 40 where `blocks` says nothing, the open sky above.
	local function underSky(blocks: { [number]: number })
		local get = field(blocks, STONE)
		return function(x: number, y: number, z: number): number?
			if y > 40 and blocks[Coords.posKey(x, y, z)] == nil then
				return AIR
			end
			return get(x, y, z)
		end
	end

	t.test("fuel: the space over it is closed by solid blocks, open through a shaft or past loaded blocks", function()
		local get = field(room(), STONE)
		local body = FuelBlast.measure(get, 0, 10, 0)
		t.eq(#body.cells, 4)
		local above = FuelBlast.surface(get, body)
		t.eq(#above, 4, "the air over each cell")
		local pocket = FuelBlast.pocket(get, above)
		t.ok(pocket.sealed, "closed")
		t.eq(#pocket.cells, 32, "the room's air")
		local glass = 0
		for _, key in pocket.walls do
			if get(Coords.decodePosKey(key)) == B.Glass then
				glass += 1
			end
		end
		t.eq(glass, 8, "the glass wall bounds it")
		local shaft = underSky(room(true))
		local shaftAbove = FuelBlast.surface(shaft, FuelBlast.measure(shaft, 0, 10, 0))
		t.ok(not FuelBlast.pocket(shaft, shaftAbove).sealed, "a shaft to the sky")
		local edge = field(room(), nil)
		t.ok(not FuelBlast.pocket(edge, above).sealed, "unloaded blocks around: not known closed")
		t.ok(not FuelBlast.pocket(field({}, AIR), { Coords.posKey(0, 11, 0) }).sealed, "the open air: too big")
		t.ok(not FuelBlast.pocket(field({}, STONE), {}).sealed, "nothing over it")
	end)

	t.test("fuel: flames run over the surface at 3 m/s; a blast only from vapour closed in", function()
		local get = field(room(), STONE)
		local plan = FuelBlast.plan(get, FuelBlast.measure(get, 0, 10, 0))
		t.eq(#plan.flames, 4, "a flame over each cell")
		local delays = {}
		for _, flame in plan.flames do
			delays[flame.delay] = (delays[flame.delay] or 0) + 1
		end
		t.eq(delays[0], 1, "where it caught at once")
		t.eq(delays[math.floor(1 / Settings.FlameSpeed)], 2, "a block on, a third of a second later")
		local blast = plan.blast :: FuelBlast.Blast
		t.ok(blast ~= nil, "closed in: it explodes")
		t.near(blast.power, select(2, FuelBlast.vapour(4, 32)), 1e-9)
		t.eq(blast.fill, 1)
		t.eq(#blast.walls, 8, "the glass gives, the stone holds")
		t.near(blast.x, 2, 1e-9, "the room's centre")
		t.eq(#blast.pocket, 32)
		t.eq(FuelBlast.plan(get, FuelBlast.measure(get, 0, 10, 0), true).blast, nil, "burning: no blast")
		local open = underSky(room(true))
		local burn = FuelBlast.plan(open, FuelBlast.measure(open, 0, 10, 0))
		t.eq(burn.blast, nil, "open: it only burns")
		t.eq(#burn.flames, 4)
	end)

	t.test("world: a pool in the open catches from lava and burns, with no blast; the fire eats it", function()
		local world, _, calls, run = newWorld()
		local y = FLOOR - 1
		for x = 6, 11 do
			for z = 6, 11 do
				world:setBlock(x, y, z, FUEL)
			end
		end
		run(3)
		t.eq(
			countIn(world, function(b)
				return b == FIRE
			end, 0, 20, y, y + 2, 0, 20),
			0,
			"fuel alone is calm"
		)
		world:setBlock(5, y, 6, LAVA)
		run(1)
		t.ok(Explosions.isBurning(world, 6, y, 6), "it caught")
		t.ok(Explosions.isBurning(world, 11, y, 11), "the whole pool")
		run(2)
		t.eq(world:peekBlock(6, y + 1, 6), FIRE, "flames where it caught")
		t.ok(world:peekBlock(11, y + 1, 11) ~= FIRE, "not yet at the far corner")
		run(80)
		t.eq(#calls, 0, "no blast in the open")
		local flames = countIn(world, function(b)
			return b == FIRE
		end, 6, 11, y + 1, y + 1, 6, 11)
		t.ok(flames >= 30, `the surface burns ({flames} of 36)`)
		run(3000)
		-- (Burnt sources fill with flowing fuel from the rest, which burns too.)
		local left = countIn(world, function(b)
			return b == FUEL
		end, 0, 20, y - 2, y + 2, 0, 20)
		t.ok(left < 30, `the fire eats the fuel ({left} of 36 sources left after 150 s)`)
		t.eq(#calls, 0, "and never explodes")
	end)

	t.test("world: fuel in a closed room explodes: glass and planks blown out, stone holds, fire inside", function()
		local world, _, calls, run = newWorld(5)
		local y = FLOOR
		-- A 4 x 4 x 3 room on the stone floor: planks on two sides and the roof, stone on two.
		for x = 7, 12 do
			for z = 7, 12 do
				for dy = 0, 4 do
					local edge = x == 7 or x == 12 or z == 7 or z == 12 or dy == 4
					if edge then
						local wall = if dy == 4 or x == 12 or z == 12 then B.Planks else STONE
						world:setBlock(x, y + dy, z, wall)
					end
				end
			end
		end
		for x = 8, 9 do
			for z = 8, 9 do
				world:setBlock(x, y, z, FUEL)
			end
		end
		run(3)
		t.eq(#calls, 0, "calm")
		world:setBlock(8, y - 1, 8, LAVA)
		run(3)
		t.eq(#calls, 1, "one blast")
		local expected = select(2, FuelBlast.vapour(4, 4 * 4 * 4 - 4))
		t.near(calls[1].power, expected, 1e-9, `the room's vapour ({expected})`)
		t.ok(calls[1].power < 2, "a gas explosion, not a bomb")
		t.eq(world:peekBlock(12, y + 2, 10), AIR, "the planks wall is gone")
		t.eq(world:peekBlock(10, y + 4, 10), AIR, "the roof too")
		t.eq(world:peekBlock(7, y + 2, 10), STONE, "the stone wall holds")
		t.ok(countIn(world, FuelBlast.isFuel, 8, 9, y, y, 8, 9) == 4, "the fuel is still there: it burns")
		run(40)
		t.eq(#calls, 1, "a burning pool doesn't go off again")
		t.ok(countIn(world, function(b)
			return b == FIRE
		end, 7, 12, y, y + 4, 7, 12) > 0, "fire in the room")
	end)

	t.test("world: fire over fuel catches it; fuel flowing next to lava catches; burning only refreshes", function()
		local world, _, calls, run = newWorld()
		local y = FLOOR - 1
		world:setBlock(8, y, 8, FUEL)
		world:setBlock(8, y + 1, 8, FIRE)
		run(2)
		t.ok(Explosions.isBurning(world, 8, y, 8), "fire above")
		t.eq(#calls, 0, "in the open: no blast")

		local world2, _, calls2, run2 = newWorld()
		world2:setBlock(8, y, 8, LAVA)
		world2:setBlock(13, FLOOR, 8, FUEL)
		run2(60)
		t.ok(Explosions.isBurning(world2, 13, FLOOR, 8), "the flowing fuel reached the lava and its source caught")
		t.eq(#calls2, 0)
		run2(200)
		t.eq(Explosions.pending(world2), 0, "the flame front is through, nothing piling up")
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

--[[
	TNT and the Nuke: the blocks (BlockList Tnt, LitTnt, Nuke, LitNuke), gunpowder and the
	recipes, lighting (Behaviours/Tnt.prime: flint and steel's path in Players/ItemUse, fire
	burning it in Behaviours/Fire, lava lighting that fire, a blast's short fuse through
	World/Explosions' primer), the fuse, falling, blowing up with power 4, chain reactions, the
	Nuke's fuse and crater (World/Nuke: radius, the resistance threshold, the ragged edge and its
	determinism, obsidian and fluids holding, scorching, fire, explosives lit, the per-tick edit and
	read budgets, unloaded chunks), what the client shows (ExplosionView's nuke look, BlockDecor's
	faces, WAILA) and the sounds.
]]

return function(t, shared, require, server, client)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Config = require(shared.Config)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Crafting = require(shared.Crafting)
	local SharedSounds = require(shared.Sounds)
	local WorldServer = require(server.World.WorldServer)
	local BlockTicker = require(server.World.BlockTicker)
	local Behaviours = require(server.Behaviours)
	local Explosions = require(server.World.Explosions)
	local Nuke = require(server.World.Nuke)
	local Fire = require(server.Behaviours.Fire)
	local Tnt = require(server.Behaviours.Tnt)
	local ExplosionView = require(client.Rendering.ExplosionView)
	local BlockDecor = require(client.Rendering.BlockDecor)
	local WailaInfo = require(client.Ui.WailaInfo)

	local B, I = Blocks.id, Items.id
	local AIR, STONE, FIRE = Blocks.AIR, B.Stone, B.Fire
	local TNT, LIT_TNT, NUKE, LIT_NUKE = B.Tnt, B.LitTnt, B.Nuke, B.LitNuke
	local WATER = Blocks.fluidId("Water", 0)
	local LAVA = Blocks.fluidId("Lava", 0)
	local FLOOR = 32
	local CROP = 80
	local FUSE = Config.Tnt.FuseTicks
	local NukeSettings = Config.Nuke

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

	type Call = { tick: number, x: number, y: number, z: number, power: number, range: number? }

	-- A world of (2 x chunks + 1)^2 loaded chunks with a ticker, explosions and nukes running.
	local function newWorld(chunks: number?, seed: number?)
		local world = WorldServer.new(generator :: any)
		local ticker = BlockTicker.new(world, Behaviours.byId, 100000)
		world.onChanged = function(x, y, z)
			ticker:blockChanged(x, y, z)
		end
		local n = chunks or 2
		for cx = -n, n do
			for cz = -n, n do
				world:getChunk(cx, cz)
			end
		end
		Explosions.setRandom(world, lcg(seed or 7))
		local calls: { Call } = {}
		local tick = 0
		Explosions.setHandler(function(x, y, z, power, getBlock, range)
			assert(type(getBlock) == "function", "the handler gets the blocks")
			table.insert(calls, { tick = tick, x = x, y = y, z = z, power = power, range = range })
		end)
		local function run(ticks: number)
			for _ = 1, ticks do
				tick += 1
				ticker:step()
				Explosions.step(world)
				Nuke.step(world)
			end
		end
		return world, ticker, calls, run
	end

	local function count(
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

	--[[ Blocks, items, recipes ]]

	t.test("blocks: TNT breaks at once, burns 15 / 100, resists nothing; lit ones are no items", function()
		local tnt = Blocks.get(TNT)
		t.eq(tnt.hardness, 0)
		t.eq(tnt.blastResistance, 0)
		t.eq(Blocks.burnOdds(TNT), 100, "burn")
		t.ok(Blocks.isFlammable(TNT), "ignite 15")
		t.eq(tnt.decor, "Tnt")
		t.eq(WailaInfo.blockName(TNT), "TNT")
		t.ok(Blocks.isFlammable(NUKE) and Blocks.get(NUKE).blastResistance == 0, "the Nuke too")
		for _, lit in { LIT_TNT, LIT_NUKE } do
			local def = Blocks.get(lit)
			t.eq(def.breakable, false, `{def.name} can't be broken`)
			t.eq(def.placeable, false, `{def.name} is no item`)
			t.eq(def.blastResistance, 0, `{def.name}: blasts run through it`)
			t.ok(not Blocks.isFlammable(lit), `{def.name} doesn't burn`)
			t.ok(def.light > 0, `{def.name} glows`)
			t.eq(Items.drops(lit), nil, `{def.name} drops nothing`)
		end
		t.eq(Items.ofBlock(LIT_TNT), I.Tnt, "lit TNT shows as TNT")
		t.eq(Items.ofBlock(LIT_NUKE), I.Nuke)
		t.ok(Tnt.isExplosive(TNT) and Tnt.isExplosive(NUKE), "explosives")
		t.ok(not Tnt.isExplosive(LIT_TNT) and not Tnt.isExplosive(STONE) and not Tnt.isExplosive(nil))
		t.ok(Tnt.isLit(LIT_TNT) and Tnt.isLit(LIT_NUKE) and not Tnt.isLit(TNT))
		t.eq(Tnt.fuseOf(TNT), 80, "Minecraft's 80 ticks")
		t.eq(Tnt.fuseOf(LIT_NUKE), NukeSettings.FuseTicks)
	end)

	t.test("recipes: gunpowder from coal or charcoal and flint; Minecraft's TNT; the Nuke", function()
		local function grid(cells: { [number]: number })
			local out = {}
			for slot, item in cells do
				out[slot] = { item = item, count = 1 }
			end
			return out
		end
		local powder = Crafting.match(grid({ [1] = I.Coal, [4] = I.Flint }), 2) :: any
		t.ok(powder ~= nil, "coal and flint")
		t.eq(powder.item, I.Gunpowder)
		t.eq(powder.count, 2)
		t.eq((Crafting.match(grid({ [2] = I.Charcoal, [3] = I.Flint }), 2) :: any).item, I.Gunpowder, "charcoal")
		local G, S = I.Gunpowder, I.Sand
		local tnt = Crafting.match(grid({ G, S, G, S, G, S, G, S, G }), 3) :: any
		t.ok(tnt ~= nil, "gunpowder in an X, sand between")
		t.eq(tnt.item, I.Tnt)
		t.eq(tnt.count, 1)
		t.eq(Crafting.match(grid({ S, G, S, G, S, G, S, G, S }), 3), nil, "the other way round is nothing")
		local T, D = I.Tnt, I.DiamondBlock
		local nuke = Crafting.match(grid({ T, T, T, T, D, T, T, T, T }), 3) :: any
		t.ok(nuke ~= nil, "eight TNT around a diamond block")
		t.eq(nuke.item, I.Nuke)
		t.eq(Items.list[#Items.list].name, "Gunpowder", "the newest item")
	end)

	--[[ Lighting ]]

	t.test("lighting: flint and steel's path lights TNT and the Nuke, nothing else, with the full fuse", function()
		local world, ticker = newWorld(1)
		world:setBlock(4, FLOOR, 4, TNT)
		world:setBlock(6, FLOOR, 4, NUKE)
		t.ok(Tnt.prime(world, 4, FLOOR, 4), "TNT lit")
		t.eq(world:peekBlock(4, FLOOR, 4), LIT_TNT)
		t.eq(Tnt.fuseLeft(world, ticker, 4, FLOOR, 4), FUSE, "80 ticks to go")
		t.ok(Tnt.prime(world, 6, FLOOR, 4), "the Nuke lit")
		t.eq(world:peekBlock(6, FLOOR, 4), LIT_NUKE)
		t.eq(Tnt.fuseLeft(world, ticker, 6, FLOOR, 4), NukeSettings.FuseTicks)
		t.ok(not Tnt.prime(world, 4, FLOOR, 4), "lit already")
		t.ok(not Tnt.prime(world, 4, FLOOR - 1, 4), "stone isn't lit")
		t.eq(world:peekBlock(4, FLOOR - 1, 4), STONE)
		-- A lit block placed by anything else starts the full fuse.
		world:setBlock(8, FLOOR, 4, LIT_TNT)
		t.eq(Tnt.fuseLeft(world, ticker, 8, FLOOR, 4), FUSE, "placed lit")
	end)

	t.test("lighting: fire burning TNT lights it instead (FireBlock.checkBurnOut); lava lights that fire", function()
		local world, ticker = newWorld(1)
		world:setBlock(8, FLOOR, 8, FIRE)
		world:setBlock(9, FLOOR, 8, TNT)
		-- (Every roll 0: the east neighbour, first in Minecraft's order, burns.)
		Fire.tick(world, ticker, 8, FLOOR, 8, constant(0))
		t.eq(world:peekBlock(9, FLOOR, 8), LIT_TNT, "lit, no fire in its place")
		t.eq(Tnt.fuseLeft(world, ticker, 9, FLOOR, 8), FUSE)

		-- Lava lights the air over a flammable block next to it; that fire lights the TNT below.
		local world2, ticker2 = newWorld(1)
		world2:setBlock(8, FLOOR - 1, 8, LAVA)
		world2:setBlock(7, FLOOR - 1, 7, TNT)
		local fx, fy, fz = Fire.lavaTick(world2, 8, FLOOR - 1, 8, constant(0))
		t.eq(fx, 7, "lava lit the air over the TNT")
		t.eq(fy, FLOOR)
		t.eq(fz, 7)
		t.eq(world2:peekBlock(7, FLOOR, 7), FIRE)
		Fire.tick(world2, ticker2, 7, FLOOR, 7, constant(0))
		t.eq(world2:peekBlock(7, FLOOR - 1, 7), LIT_TNT, "the fire lit the TNT under it")
	end)

	t.test("lighting: a blast lights TNT with a short fuse, rand(20) + 10, quietly; lit ones stay", function()
		t.eq(Tnt.shortFuse(80, constant(0)), 10, "at least 10")
		t.eq(Tnt.shortFuse(80, constant(0.999)), 29, "at most 29")
		t.eq(Tnt.shortFuse(200, constant(0)), 25, "the Nuke's: 25..74")
		t.eq(Tnt.shortFuse(200, constant(0.999)), 74)
		local fuses: { [number]: boolean } = {}
		for seed = 1, 6 do
			local world, ticker = newWorld(1, seed)
			world:setBlock(11, FLOOR, 8, TNT)
			world:setBlock(8, FLOOR, 11, LIT_TNT)
			local before = Tnt.fuseLeft(world, ticker, 8, FLOOR, 11)
			Explosions.explode(world, 8.5, FLOOR + 0.5, 8.5, 4)
			Explosions.step(world)
			t.eq(world:peekBlock(11, FLOOR, 8), LIT_TNT, "lit, not blown away")
			local left = Tnt.fuseLeft(world, ticker, 11, FLOOR, 8) :: number
			t.ok(left >= 10 and left <= 29, `short fuse ({left})`)
			fuses[left] = true
			t.eq(world:peekBlock(8, FLOOR, 11), LIT_TNT, "a lit one stays")
			t.eq(Tnt.fuseLeft(world, ticker, 8, FLOOR, 11), before, "its fuse untouched")
		end
		local distinct = 0
		for _ in fuses do
			distinct += 1
		end
		t.ok(distinct >= 2, "the fuse is random")
	end)

	--[[ Lit TNT ]]

	t.test("lit TNT: explodes with power 4, no fire, 80 ticks after lighting, at its feet", function()
		local world, _, calls, run = newWorld(2)
		world:setBlock(8, FLOOR, 8, TNT)
		Tnt.prime(world, 8, FLOOR, 8)
		run(FUSE - 1)
		t.eq(#calls, 0, "not yet")
		t.eq(world:peekBlock(8, FLOOR, 8), LIT_TNT)
		run(1)
		t.eq(#calls, 1, "after 80 ticks")
		local call = calls[1]
		t.eq(call.power, Config.Tnt.Power)
		t.eq(call.power, 4)
		t.eq(call.x, 8.5)
		t.eq(call.y, FLOOR + 0.0625, "PrimedTnt's getY(0.0625)")
		t.eq(call.z, 8.5)
		t.eq(world:peekBlock(8, FLOOR, 8), AIR, "gone")
		t.eq(world:peekBlock(8, FLOOR - 1, 8), AIR, "the stone under it with it")
		t.eq(world:peekBlock(8, FLOOR - 7, 8), STONE, "not deep stone")
		t.eq(
			count(world, function(b)
				return b == FIRE
			end, -8, 24, FLOOR - 8, FLOOR + 8, -8, 24),
			0,
			"TNT sets no fire"
		)
		run(2)
		t.eq(#calls, 1, "once")
	end)

	t.test("lit TNT: falls like Minecraft's entity, lands, and goes off where it landed", function()
		local world, ticker, calls, run = newWorld(1)
		local y = FLOOR + 10
		world:setBlock(8, y, 8, TNT)
		Tnt.prime(world, 8, y, 8)
		run(5)
		t.eq(world:peekBlock(8, y, 8), LIT_TNT, "speed builds slowly (0.04, 0.079, ...)")
		run(10)
		t.eq(world:peekBlock(8, y, 8), AIR, "it fell")
		t.eq(count(world, Tnt.isLit, 8, 8, FLOOR, y, 8, 8), 1, "one lit block on the way down")
		run(15)
		t.eq(world:peekBlock(8, FLOOR, 8), LIT_TNT, "landed on the floor")
		t.ok((Tnt.fuseLeft(world, ticker, 8, FLOOR, 8) :: number) == FUSE - 30, "the fuse kept burning")
		run(FUSE - 30)
		t.eq(#calls, 1)
		t.eq(calls[1].y, FLOOR + 0.0625, "on the floor")

		-- Into water: the water comes back and the blast in it breaks nothing.
		local wet, _, wetCalls, runWet = newWorld(1)
		wet:setBlock(8, FLOOR - 1, 8, WATER)
		wet:setBlock(8, FLOOR + 2, 8, TNT)
		Tnt.prime(wet, 8, FLOOR + 2, 8)
		runWet(30)
		t.eq(wet:peekBlock(8, FLOOR - 1, 8), LIT_TNT, "sank into the water")
		t.eq(wet:peekBlock(8, FLOOR + 2, 8), AIR)
		runWet(FUSE)
		t.eq(#wetCalls, 1, "went off")
		t.eq(wet:peekBlock(8, FLOOR - 1, 8), WATER, "in water")
		t.eq(wet:peekBlock(9, FLOOR - 1, 8), STONE, "which shields the stone")
		t.eq(wet:peekBlock(8, FLOOR - 2, 8), STONE)
	end)

	t.test("lit TNT: a pile goes off in a chain, each lit by the last blast", function()
		local world, _, calls, run = newWorld(2, 3)
		for i = 0, 4 do
			world:setBlock(2 + i * 3, FLOOR, 8, TNT)
		end
		Tnt.prime(world, 2, FLOOR, 8)
		run(FUSE)
		t.eq(#calls, 1, "the first")
		run(200)
		t.eq(#calls, 5, "every one")
		for _, call in calls do
			t.eq(call.power, 4)
		end
		local ticks: { [number]: boolean } = {}
		for _, call in calls do
			ticks[call.tick] = true
		end
		local distinct = 0
		for _ in ticks do
			distinct += 1
		end
		t.ok(distinct >= 3, `rippling over several ticks ({distinct})`)
		t.eq(
			count(world, function(b)
				return b == TNT or Tnt.isLit(b)
			end, -8, 24, FLOOR - 10, FLOOR + 4, 0, 16),
			0,
			"none left"
		)
	end)

	--[[ The Nuke ]]

	t.test("nuke: wails for its 10 s fuse, then the blast (power, range) and the crater", function()
		local world, _, calls, run = newWorld(1)
		world:setBlock(8, FLOOR, 8, NUKE)
		Tnt.prime(world, 8, FLOOR, 8)
		run(NukeSettings.FuseTicks - 1)
		t.eq(#calls, 0, "10 seconds")
		t.eq(world:peekBlock(8, FLOOR, 8), LIT_NUKE)
		run(1)
		t.eq(#calls, 1, "gone off")
		t.eq(calls[1].power, NukeSettings.Power, "players and items: Minecraft's formula at its power")
		t.eq(calls[1].range, NukeSettings.EffectDistance, "seen far away")
		t.eq(calls[1].y, FLOOR + 0.5)
		t.ok(Nuke.pending(world) == 1 or world:peekBlock(8, FLOOR - 4, 8) == AIR, "digging")
		run(200)
		t.eq(Nuke.pending(world), 0, "dug")
		t.eq(world:peekBlock(8, FLOOR - 4, 8), AIR, "the crater")
	end)

	t.test("nuke: the crater's edge is ragged, the same for the same place, and within its bounds", function()
		local a = Nuke.crater(100.5, 40.5, -20.5)
		local b = Nuke.crater(100.5, 40.5, -20.5)
		local c = Nuke.crater(140.5, 40.5, -20.5)
		local low, high, differs = math.huge, -math.huge, 0
		for i = 0, 63 do
			local angle = i / 64 * math.pi * 2
			local x = math.floor(100 + math.cos(angle) * 24)
			local z = math.floor(-21 + math.sin(angle) * 24)
			local r = Nuke.radiusAt(a, x, 40, z)
			t.eq(r, Nuke.radiusAt(b, x, 40, z), "deterministic")
			if math.abs(Nuke.radiusAt(c, x + 40, 40, z) - r) > 1e-9 then
				differs += 1
			end
			low = math.min(low, r)
			high = math.max(high, r)
			t.ok(r >= Nuke.minRadius() and r <= Nuke.maxRadius(), `within bounds ({r})`)
		end
		t.ok(high - low >= 3, `ragged: {low} .. {high}`)
		t.ok(differs > 32, "another place, another edge")
		-- The threshold: Strength x (1 - d / r).
		local centre = Nuke.crater(0.5, 40.5, 0.5)
		t.eq(Nuke.fate(centre, 0, 30, 0, STONE), AIR, "stone near the centre goes")
		t.eq(Nuke.fate(centre, 0, 30, 0, B.Obsidian), nil, "obsidian stays")
		t.eq(Nuke.fate(centre, 0, 30, 0, B.Bedrock), nil, "bedrock stays")
		t.eq(Nuke.fate(centre, 0, 30, 0, WATER), nil, "water stays (resistance 100)")
		t.eq(Nuke.fate(centre, 0, 30, 0, B.Fuel), AIR, "fuel is vaporised")
		t.eq(Nuke.fate(centre, 0, 40, 0, AIR), nil, "air is air")
		local rim = math.floor(Nuke.minRadius()) - 1
		t.eq(Nuke.fate(centre, rim, 40, 0, B.Dirt), AIR, "dirt to the rim")
		local outside = math.ceil(Nuke.maxRadius()) + 1
		t.eq(Nuke.fate(centre, outside, 40, 0, STONE), nil, "stone beyond the crater stays")
		local scorched = Nuke.fate(centre, outside, 40, 0, B.Grass)
		t.ok(scorched == B.Dirt or scorched == B.CoarseDirt, "grass scorched")
		t.eq(Nuke.fate(centre, outside, 40, 0, B.OakLeaves), AIR, "leaves blown away")
		t.eq(Nuke.fate(centre, outside, 40, 0, B.ShortGrass), AIR, "plants too")
		t.eq(Nuke.fate(centre, outside, 40, 0, B.OakLog), nil, "logs stand")
		t.eq(Nuke.fate(centre, outside, 40, 0, WATER), nil, "water stays")
	end)

	t.test("nuke: digs the crater within the edit and read budgets, nearest first, no generation", function()
		local world, _, calls = newWorld(4)
		local cy = FLOOR
		world:setBlock(8, cy - 3, 8, B.Obsidian)
		world:setBlock(12, cy - 2, 8, B.Bedrock)
		world:setBlock(4, cy - 2, 8, WATER)
		world:setBlock(13, cy, 8, TNT)
		world:setBlock(8, cy, 13, LIT_TNT)
		world:setBlock(8 + 35, cy - 1, 8, B.Grass)
		world:setBlock(8 - 35, cy, 8, B.OakLeaves)
		world:setBlock(8, cy, 8 + 35, B.OakLog)
		local chunks = world.chunkCount
		world:takePending()
		Nuke.detonate(world, 8.5, cy + 0.5, 8.5)
		t.eq(#calls, 1, "the effects at once")
		t.eq(calls[1].power, NukeSettings.Power)
		local ticks, edits, reads = 0, 0, 0
		local firstAir: number? = nil
		while Nuke.pending(world) > 0 and ticks < 1000 do
			local e, r = Nuke.step(world)
			ticks += 1
			edits += e
			reads += r
			t.ok(e <= NukeSettings.EditsPerTick, `edit budget ({e})`)
			t.ok(r <= NukeSettings.ReadsPerTick + 1, `read budget ({r})`)
			local pending = #world:takePending() // 4
			t.ok(pending <= NukeSettings.EditsPerTick, `replicated edits per tick ({pending})`)
			if firstAir == nil and world:peekBlock(8, cy - 1, 8) == AIR then
				firstAir = ticks
			end
		end
		t.eq(Nuke.pending(world), 0, "done")
		t.ok(ticks > 10, `spread over ticks ({ticks})`)
		t.eq(firstAir, 1, "the centre first")
		t.ok(edits > 10000, `a big crater ({edits} edits, {reads} reads)`)
		t.eq(world.chunkCount, chunks, "no chunk generated")
		-- The crater.
		t.eq(world:peekBlock(8, cy - 1, 8), AIR, "the centre is gone")
		t.eq(world:peekBlock(8, cy - 12, 8), AIR, "deep")
		t.eq(world:peekBlock(8 + 12, cy - 6, 8 - 6), AIR, "wide")
		t.eq(world:peekBlock(8, cy - 3, 8), B.Obsidian, "obsidian holds")
		t.eq(world:peekBlock(12, cy - 2, 8), B.Bedrock, "bedrock holds")
		t.eq(world:peekBlock(4, cy - 2, 8), WATER, "water holds (and will pour in)")
		t.eq(world:peekBlock(8 + 31, cy - 1, 8), STONE, "beyond the rim")
		t.eq(world:peekBlock(8, cy - 32, 8), STONE, "below it")
		-- Explosives lit, not dug away.
		t.eq(world:peekBlock(13, cy, 8), LIT_TNT, "TNT in the crater is lit")
		t.eq(world:peekBlock(8, cy, 13), LIT_TNT, "lit TNT stays")
		-- Scorched around it.
		local grass = world:peekBlock(8 + 35, cy - 1, 8)
		t.ok(grass == B.Dirt or grass == B.CoarseDirt, "grass scorched to dirt")
		t.eq(world:peekBlock(8 - 35, cy, 8), AIR, "leaves blown away")
		t.eq(world:peekBlock(8, cy, 8 + 35), B.OakLog, "logs stand")
		local fires = count(world, function(b)
			return b == FIRE
		end, 8 - 40, 8 + 40, 0, cy + 2, 8 - 40, 8 + 40)
		t.ok(fires > 100, `fire around ({fires})`)
		-- The rim is ragged: the crater's reach at the surface differs by direction.
		local low, high = math.huge, 0
		for i = 0, 31 do
			local angle = i / 32 * math.pi * 2
			local reach = 0
			for d = 1, 34 do
				local x, z = 8 + math.round(math.cos(angle) * d), 8 + math.round(math.sin(angle) * d)
				if world:peekBlock(x, cy - 1, z) ~= STONE then
					reach = d
				end
			end
			low = math.min(low, reach)
			high = math.max(high, reach)
		end
		t.ok(high - low >= 3, `a ragged rim ({low} .. {high} blocks)`)
		t.ok(low >= Nuke.minRadius() * 0.85 and high <= Nuke.maxRadius() + 1, "about the radius")
	end)

	t.test("nuke: the same place digs the same crater; unloaded chunks are left alone", function()
		local one = newWorld(4)
		local two = newWorld(4)
		for _, world in { one, two } do
			Nuke.detonate(world, 20.5, FLOOR + 0.5, -10.5)
			while Nuke.pending(world) > 0 do
				Nuke.step(world)
			end
		end
		local same, total = true, 0
		for key, edits in one.edits do
			local other = two.edits[key]
			for index, block in edits do
				total += 1
				if other == nil or other[index] ~= block then
					same = false
				end
			end
		end
		t.ok(same and total > 10000, `identical ({total} edits)`)

		-- At the edge of the loaded world: nothing generated, nothing beyond touched.
		local edge = newWorld(2)
		local chunks = edge.chunkCount
		Nuke.detonate(edge, 40.5, FLOOR + 0.5, 8.5)
		while Nuke.pending(edge) > 0 do
			Nuke.step(edge)
		end
		t.eq(edge.chunkCount, chunks, "no chunk generated")
		t.eq(edge:peekBlock(80, FLOOR - 1, 8), nil, "unloaded stays unloaded")
		t.eq(edge:peekBlock(47, FLOOR - 1, 8), AIR, "the loaded side is dug")
	end)

	t.test("nuke: a blast lights it with the short fuse; chain reactions between nukes", function()
		local world, ticker, calls, run = newWorld(4, 5)
		world:setBlock(8, FLOOR, 8, NUKE)
		world:setBlock(20, FLOOR, 8, NUKE)
		Explosions.explode(world, 10.5, FLOOR + 0.5, 8.5, 4)
		run(1)
		t.eq(world:peekBlock(8, FLOOR, 8), LIT_NUKE, "lit by TNT's blast")
		local left = Tnt.fuseLeft(world, ticker, 8, FLOOR, 8) :: number
		t.ok(left >= 25 and left <= 74, `short fuse ({left})`)
		run(left)
		local nukes = 0
		for _, call in calls do
			if call.power == NukeSettings.Power then
				nukes += 1
			end
		end
		t.eq(nukes, 1, "the first went off")
		run(150)
		t.eq(world:peekBlock(20, FLOOR, 8) == NUKE, false, "the crater lit the second")
		run(150)
		nukes = 0
		for _, call in calls do
			if call.power == NukeSettings.Power then
				nukes += 1
			end
		end
		t.eq(nukes, 2, "and it went off too")
	end)

	--[[ The client and the sounds ]]

	t.test("client: the nuke's look (power from LookPower), its flash by distance", function()
		t.ok(ExplosionView.isNuke(NukeSettings.Power), "the Nuke's blast")
		t.ok(
			not ExplosionView.isNuke(4) and not ExplosionView.isNuke(Config.Explosions.MaxPower),
			"TNT and fuel aren't"
		)
		t.eq(ExplosionView.flash(0), 1, "blinding at the centre")
		t.eq(ExplosionView.flash(NukeSettings.EffectDistance / 4), 1)
		t.near(ExplosionView.flash(NukeSettings.EffectDistance * 5 / 8), 0.5, 1e-9, "half way out")
		t.eq(ExplosionView.flash(NukeSettings.EffectDistance), 0, "none at the edge")
		t.ok(ExplosionView.shake(100, NukeSettings.Power) > 0, "felt 100 blocks away")
		t.ok(NukeSettings.Power * 2 <= 64 and NukeSettings.Power <= 64, "within the Explosion message's bounds")
	end)

	t.test("client: TNT and Nuke faces (red and white with TNT; hazard stripes and the sign)", function()
		for _, decor in { "Tnt", "Nuke" } do
			local faces = BlockDecor.faces(decor) :: any
			t.ok(faces ~= nil, decor)
			for _, face in BlockDecor.FACES do
				t.ok(faces[face] ~= nil, `{decor} {face}`)
				for _, r in faces[face] do
					t.ok(r.x >= 0 and r.y >= 0 and r.x + r.w <= 16 and r.y + r.h <= 16, `{decor} {face} in the face`)
				end
			end
			local parts = BlockDecor.partCount(decor)
			t.ok(parts > 0 and parts < 40, `{decor} item model: {parts} parts`)
		end
		t.eq(Blocks.get(LIT_TNT).decor, "Tnt", "lit TNT looks like TNT (and glows)")
		t.eq(Blocks.get(LIT_NUKE).decor, "Nuke")
	end)

	t.test("client: WAILA says what is explosive and what is lit", function()
		local tnt = WailaInfo.texts(WailaInfo.block(TNT, nil, 0, 0, 0, false))
		t.eq(tnt[1], "TNT")
		t.ok(table.find(tnt, "Explosive: power 4") ~= nil, "power")
		local nuke = WailaInfo.texts(WailaInfo.block(NUKE, nil, 0, 0, 0, false))
		t.eq(nuke[1], "Nuke")
		t.ok(table.find(nuke, `Explosive: {NukeSettings.Radius} block crater`) ~= nil, "crater")
		local lit = WailaInfo.texts(WailaInfo.block(LIT_TNT, nil, 0, 0, 0, false))
		t.eq(lit[1], "Lit TNT")
		t.ok(table.find(lit, "Lit: stand back!") ~= nil, "lit")
		t.ok(table.find(lit, "Unbreakable") == nil, "not 'Unbreakable'")
		t.eq(WailaInfo.explosiveLine(STONE), nil)
	end)

	t.test("sounds: the hiss, the alarm and the boom, from the server", function()
		for _, name in { "entity.tnt.primed", "entity.nuke.alarm", "entity.nuke.explode" } do
			local event = SharedSounds.get(name) :: any
			t.ok(event ~= nil, name)
			t.eq(event.side, "server", name)
		end
		t.eq((SharedSounds.get("entity.nuke.explode") :: any).maxDistance, 256, "heard far away")
	end)
end

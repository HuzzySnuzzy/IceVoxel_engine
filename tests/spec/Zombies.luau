--[[
	The zombie apocalypse's zombies on the server (Mobs/MobAI's zombie rules, Mobs/MobWorld's
	block damage, crowds and leaving, Mobs/MobSpawning's day spawning, Mobs/ZombieDirector's caps,
	blood moon waves, hunts and leave rounds, Mobs/MobCrowd, Mobs/MobTracking, and Mobs/Mobs, the
	glue, run against fakes of Roblox and the rest of the server):

	   1  day spawning: zombies on open grass at noon; not on torch-lit open ground (torches 6 or
	      12 apart: as far as a torch's light reaches); not under a roof by day (the darkness roll
	      still holds there); a pack's shared light search, each member's own where it finds
	      light (a pack on a torch's edge; random packs against each member's own spot test)
	   2  no zombie burns in the sun
	   3  noise: a break heard 10 blocks off brings an idle zombie to it; a hearing 0.8 one ignores
	      it at 9 blocks; a zombie that hears one and can see a player targets them that tick; the
	      glue's night factor
	   4  breaking: a closed door (240 ticks, a brute 80, two zombies half), glass, planks,
	      barricades, decay, what never breaks, both door halves and no drops, the reach and level
	      rules, an investigating zombie
	   5  the brute through an open door (13/16) and up a 1 x 1 ladder shaft
	   6  the screamer's shriek and its cooldown, and its end when it is sent away or thinned
	      mid-shriek
	   7  blood moons: waves within the cap (none where nothing spawns), hunts without sight, the
	      end of the hunt, a sealed player outlasting a moon
	   8  leave rounds at dawn: the furthest go, each only far and unseen
	   9  separation in a crowd (the hash keeps only the cells in use)
	  10  thinning never walks a zombie off a ledge
	  11  Peaceful: nothing, waves included
	  12  the glue: Mobs.playerHit, a door broken (both halves, its noise), spawning by day, in a
	      city and in a blood moon
	  13  caps by day, night, city and moon; the world's limits follow the day time (/time set)
	plus the chase speeds, fire immunity and knockback resistance, replication (op 6 baselines,
	op 2 on a jump, hysteresis, the message's size) and the costs (§5 of the design; see the cost
	test's comment for the measured numbers).
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

-- (Native code unless NOCODEGEN is set: the budgets differ.)
local NATIVE = process.env.NOCODEGEN == nil

-- A module's source with `globals` declared as locals taken from the chunk's arguments.
local function withHeader(source: string, globals: string): string
	local lines = string.split(source, "\n")
	local i = 1
	while lines[i] and string.sub(lines[i], 1, 3) == "--!" do
		i += 1
	end
	lines[i] = `local {globals} = ...; ` .. (lines[i] or "")
	return table.concat(lines, "\n")
end

local function fakeSignal(): any
	local handlers = {}
	return {
		Connect = function(_, fn)
			table.insert(handlers, fn)
			return { Disconnect = function() end }
		end,
		fire = function(...)
			for _, fn in handlers do
				fn(...)
			end
		end,
	}
end

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local Coords = require(shared.World.Coords)
	local DayCycle = require(shared.DayCycle)
	local GameMode = require(shared.GameMode)
	local MobList = require(shared.Entities.MobList)
	local Protocol = require(shared.Net.Protocol)
	local SharedSounds = require(shared.Sounds)
	local BloodMoon = require(shared.Apocalypse.BloodMoon)
	local MobWorld = require(server.Mobs.MobWorld)
	local MobAI = require(server.Mobs.MobAI)
	local MobSpawning = require(server.Mobs.MobSpawning)
	local MobCrowd = require(server.Mobs.MobCrowd)
	local MobTracking = require(server.Mobs.MobTracking)
	local ZombieDirector = require(server.Mobs.ZombieDirector)
	local NoiseBus = require(server.Apocalypse.NoiseBus)
	local Skylight = require(server.World.Skylight)
	local LightEstimate = require(shared.World.LightEstimate)

	local B = Blocks.id
	local AIR, STONE, GRASS = Blocks.AIR, B.Stone, B.Grass
	local FLOOR = 20
	local TOP = 64
	local DAY = 24000
	local NOON, MIDNIGHT = 6000, 18000
	local Apocalypse = Config.Apocalypse
	local Zombies = Apocalypse.Zombies
	local Moon = Apocalypse.BloodMoon
	-- Midnight of the first blood moon (night 3: day 2), and of the third (day 8).
	local MOON1 = 2 * DAY + MIDNIGHT
	local MOON3 = 8 * DAY + MIDNIGHT

	local function kindId(name: string): number
		return MobList.find(name) :: number
	end
	local ZOMBIE, RUNNER, BRUTE = kindId("Zombie"), kindId("ZombieRunner"), kindId("ZombieBrute")
	local CRAWLER, SCREAMER, FIREFIGHTER =
		kindId("ZombieCrawler"), kindId("ZombieScreamer"), kindId("ZombieFirefighter")

	-- A deterministic random in [0, 1) (a small LCG).
	local function lcg(seed: number): () -> number
		local state = seed
		return function(): number
			state = (state * 1103515245 + 12345) % 2147483648
			return state / 2147483648
		end
	end

	--[[
		A flat world: `floor` (grass) at FLOOR - 1 over stone, air above (`set` overrides cells),
		loaded within `radius` blocks of the origin.
	]]
	local function flat(radius: number?, floor: number?)
		local cells: { [number]: number } = {}
		local limit = radius or 200
		local top = floor or GRASS
		local function getBlock(x: number, y: number, z: number): number?
			if x > limit or x < -limit or z > limit or z < -limit or y < 0 then
				return nil
			end
			local block = cells[Coords.posKey(x, y, z)]
			if block ~= nil then
				return block
			end
			if y < FLOOR - 1 then
				return STONE
			elseif y == FLOOR - 1 then
				return top
			end
			return AIR
		end
		local function set(x: number, y: number, z: number, block: number)
			cells[Coords.posKey(x, y, z)] = block
		end
		local function skyOpen(x: number, y: number, z: number): boolean?
			if getBlock(x, y, z) == nil then
				return nil
			end
			for cy = y, TOP do
				local block = getBlock(x, cy, z)
				if block and Blocks.isOpaque(block) then
					return false
				end
			end
			return true
		end
		local view = {
			peekChunk = function(_self, _cx: number, _cz: number)
				return { height = TOP + 1 }
			end,
			peekBlock = function(_self, x: number, y: number, z: number): number?
				return getBlock(x, y, z)
			end,
		}
		local function skyClear(x: number, y: number, z: number): boolean?
			if getBlock(x, y, z) == nil then
				return nil
			end
			return Skylight.clear(view, x, y, z)
		end
		return getBlock, set, skyOpen, skyClear
	end

	local function box(set, x0: number, y0: number, z0: number, x1: number, y1: number, z1: number, block: number)
		for x = x0, x1 do
			for y = y0, y1 do
				for z = z0, z1 do
					set(x, y, z, block)
				end
			end
		end
	end

	local function newWorld(getBlock, seed: number?, maxMobs: number?)
		return MobWorld.new(getBlock, { maxMobs = maxMobs or 400, forgetTicks = 6000, random = lcg(seed or 7) })
	end

	local function player(key: any, x: number, y: number, z: number, mode: string?): MobWorld.PlayerView
		return { key = key, x = x, y = y, z = z, eye = 1.62, mode = mode or GameMode.SURVIVAL, alive = true }
	end

	-- The context of a tick with the zombie apocalypse's fields (`extra` adds or overrides).
	local function context(players: { MobWorld.PlayerView }, skyOpen, dayTime: number?, extra: { [string]: any }?): any
		local time = dayTime or MIDNIGHT
		local ctx: { [string]: any } = {
			players = players,
			dayTime = time,
			skyOpen = skyOpen,
			skyClear = skyOpen,
			active = function()
				return true
			end,
			night = not DayCycle.isDay(time),
			breaking = true,
		}
		for key, value in extra or {} do
			ctx[key] = value
		end
		return ctx
	end

	-- What the glue does with a tick's breaks (Mobs/Mobs): the block goes, a door's two halves.
	local function applyBreaks(changes: MobWorld.Changes, getBlock, set)
		for _, broken in changes.breaks do
			local x, y, z, block = broken.x, broken.y, broken.z, broken.block
			if getBlock(x, y, z) == block then
				set(x, y, z, AIR)
				local dy = Blocks.otherHalf(block)
				if dy and Blocks.isDoor(block) then
					local partner = if dy > 0 then Blocks.plantTop(block) else Blocks.plantBottom(block)
					if getBlock(x, y + dy, z) == partner then
						set(x, y + dy, z, AIR)
					end
				end
			end
		end
	end

	local function run(world, ctx, ticks: number, getBlock, set)
		for _ = 1, ticks do
			world:tick(ctx)
			local changes = world:takeChanges()
			if set then
				applyBreaks(changes, getBlock, set)
			end
		end
	end

	-- A closed (or open) oak door at (x, y, z) and (x, y + 1, z).
	local function door(set, x: number, y: number, z: number, open: boolean?)
		set(x, y, z, Blocks.doorVariant(B.OakDoor, "North", "Left", open == true, false) :: number)
		set(x, y + 1, z, Blocks.doorVariant(B.OakDoor, "North", "Left", open == true, true) :: number)
	end

	--[[
		A stone wall 4 high across x -5..5 at z = 3 with a doorway at x = 0 (y FLOOR, FLOOR + 1):
		`fill` puts a door, or the block in both cells.
	]]
	local function wall(set, fill: number | string)
		box(set, -5, FLOOR, 3, 5, FLOOR + 3, 3, STONE)
		if fill == "door" then
			door(set, 0, FLOOR, 3)
		elseif fill == "open" then
			door(set, 0, FLOOR, 3, true)
		else
			set(0, FLOOR, 3, fill :: number)
			set(0, FLOOR + 1, 3, fill :: number)
		end
	end

	--[[
		A zombie of `kind` against the wall's doorway (from z 2.3) with its target behind it at
		(0.5, `py`, `pz`): ticks until the doorway's first block breaks (nil: not within `limit`),
		the ticks it spent breaking, whether it ever saw the player, and everything it broke.
	]]
	local function breakThrough(
		fill: number | string,
		kind: number,
		pz: number?,
		py: number?,
		limit: number?,
		others: number?
	)
		local getBlock, set, skyOpen = flat()
		wall(set, fill)
		local world = newWorld(getBlock)
		local target = player("p", 0.5, py or FLOOR, pz or 6.5)
		if py and py > FLOOR then
			-- (A platform under the player.)
			box(set, -2, FLOOR, 5, 2, py - 1, 8, STONE)
		end
		local ids = {}
		for i = 0, others or 0 do
			local id = world:spawn(kind, 0.5 + (i - (others or 0) / 2) * 0.5, FLOOR, 2.3, nil, 0)
			local mob = world:get(id) :: MobWorld.Mob
			mob.ai.target = "p"
			mob.ai.goal = "chase"
			table.insert(ids, id)
		end
		local ctx = context({ target }, skyOpen)
		local started: number? = nil
		local seen = false
		local broken = {}
		local drops = 0
		for tick = 1, limit or 4000 do
			world:tick(ctx)
			for _, id in ids do
				local mob = world:get(id)
				if mob then
					if mob.ai.bx ~= nil and started == nil then
						started = tick
					end
					seen = seen or mob.ai.visible
				end
			end
			local changes = world:takeChanges()
			drops += #changes.drops
			for _, record in changes.breaks do
				table.insert(broken, record)
			end
			applyBreaks(changes, getBlock, set)
			if #broken > 0 then
				return tick, tick - (started or tick) + 1, seen, broken, drops, getBlock, world
			end
		end
		return nil, if started then (limit or 4000) - started + 1 else 0, seen, broken, drops, getBlock, world
	end

	--[[ 1. Day spawning ]]

	local SETTINGS = {
		Spawning = true,
		PassiveCap = 10,
		HostileCap = 20,
		MaxPassive = 120,
		MaxHostile = 200,
		PassiveInterval = 100000,
		HostileInterval = 1,
		Attempts = 4,
		SpawnDistance = { 24, 44 },
	}

	t.test("zombies: by day on open grass, never on torch-lit ground, under a roof only in the dark", function()
		local getBlock, _, skyOpen = flat()
		local world = newWorld(getBlock, 21)
		local state = MobSpawning.new()
		local p = player("p", 0.5, FLOOR, 0.5)
		local day = context({ p }, skyOpen, NOON, { daySpawn = true })
		for _ = 1, 300 do
			MobSpawning.step(world, state, day, SETTINGS)
		end
		local hostile = MobSpawning.census(world)
		t.eq(hostile, SETTINGS.HostileCap, "zombies on the open ground at noon, up to the cap")
		for _, mob in world:each() do
			t.ok(mob.kind.zombie, `a zombie ({mob.kind.name})`)
			t.eq(skyOpen(math.floor(mob.body.x), math.floor(mob.body.y), math.floor(mob.body.z)), true, "in the open")
		end
		-- Not without day spawning (the old rule: monsters only in the dark).
		local old = newWorld(getBlock, 21)
		for _ = 1, 300 do
			MobSpawning.step(old, MobSpawning.new(), context({ p }, skyOpen, NOON), SETTINGS)
		end
		t.eq(old:count(), 0, "no daySpawn: nothing at noon")
		-- Torches every 6 blocks keep the open ground clear by day too.
		local getLit, setLit, litSky = flat()
		for x = -60, 60, 6 do
			for z = -60, 60, 6 do
				setLit(x, FLOOR, z, B.Torch)
			end
		end
		local lit = newWorld(getLit, 8)
		local litState = MobSpawning.new()
		for _ = 1, 300 do
			MobSpawning.step(lit, litState, context({ p }, litSky, NOON, { daySpawn = true }), SETTINGS)
		end
		t.eq(lit:count(), 0, "not where torches light the ground")
		-- Torches 12 apart: the ground between is lit 2 at the least (a torch's 14 less the 12
		-- steps to the middle of a square), so no zombie by day either: the day's search reaches
		-- as far as a torch's light (13 blocks on open ground), as the night's.
		local getSparse, setSparse, sparseSky = flat()
		for x = -72, 72, 12 do
			for z = -72, 72, 12 do
				setSparse(x, FLOOR, z, B.Torch)
			end
		end
		local sparse = newWorld(getSparse, 8)
		local sparseState = MobSpawning.new()
		for _ = 1, 300 do
			MobSpawning.step(sparse, sparseState, context({ p }, sparseSky, NOON, { daySpawn = true }), SETTINGS)
		end
		t.eq(sparse:count(), 0, "torches 12 apart keep it clear too")
		local zombieKind = MobList.get(ZOMBIE) :: MobList.Kind
		local noon = context({}, sparseSky, NOON, { daySpawn = true })
		for _, cell in { { 30, 30 }, { 31, 31 }, { 32, 30 }, { 41, 41 } } do
			t.ok(
				not MobSpawning.validSpot(getSparse, noon, zombieKind, cell[1], FLOOR, cell[2], function(): number
					return 0
				end),
				`({cell[1]}, {cell[2]}): {12 - math.abs(cell[1] % 12 - 6) - math.abs(cell[2] % 12 - 6)} steps from a torch`
			)
		end
		-- The pack's shared search (MobSpawning.dark) and each member's own agree.
		local getOne, setOne, oneSky = flat()
		setOne(0, FLOOR, 0, B.Torch)
		for d = 3, 16 do
			local own = LightEstimate.blockLight(getOne, d, FLOOR, 0, LightEstimate.SPAWN_BUDGET, 1)
			t.eq(MobSpawning.dark(getOne, { d, FLOOR, 0 }, LightEstimate.SPAWN_BUDGET), own == 0, `{d} from a torch`)
			t.eq(
				MobSpawning.dark(
					getOne,
					{ d + 8, FLOOR, 4, d, FLOOR, 0, d + 4, FLOOR, -4 },
					3 * LightEstimate.SPAWN_BUDGET
				),
				own == 0,
				`a pack whose nearest is {d} from it`
			)
		end
		t.eq(MobSpawning.dark(getOne, { 40, FLOOR, 0, 0, FLOOR, 60 }, 4096), nil, "too far apart for one search")
		t.eq(MobSpawning.dark(getOne, { 40, FLOOR, 0 }, 100), nil, "the budget ran out: no answer")
		-- A pack straddling the torch's reach at noon: the shared search finds light, so each
		-- member asks its own; the one 10 from the torch (light 4) stays out, the two 14 off
		-- (light 0) come.
		local edge = newWorld(getOne, 3)
		local rolls = { 8, 4, 8, 5 } -- (the second member at +4, 0; the third at +4, +1)
		local roll = 0
		local edgeIds = MobSpawning.spawnPack(
			edge,
			context({}, oneSky, NOON, { daySpawn = true }),
			zombieKind,
			10,
			FLOOR,
			0,
			3,
			function(_n: number): number
				roll += 1
				return rolls[roll] or 0
			end
		)
		t.eq(#edgeIds, 2, "the two dark members of three")
		for _, id in edgeIds do
			t.ok((edge:get(id) :: MobWorld.Mob).body.x >= 14, "only those 14 or more from the torch")
		end
		-- And at random: packs among lights (torches, glow blocks, lanterns, lamps, lichen), walls
		-- and roofs, at noon, each spawning exactly the members whose own spot test (validSpot,
		-- its own light search) passes.
		local LIGHTS = { B.Torch, B.GlowBlock, B.Lantern, B.CeilingLamp, B.GlowLichen }
		local rand = lcg(2024)
		local function int(a: number, b: number): number
			return a + math.floor(rand() * (b - a + 1))
		end
		local spread = MobSpawning.PACK_SPREAD * 2 + 1
		local packs, members, mixed, mismatches = 0, 0, 0, 0
		for _ = 1, 40 do
			local getRandom, setRandom, randomSky = flat(80)
			for _ = 1, int(0, 12) do
				local x, z = int(-30, 30), int(-30, 30)
				box(setRandom, x, FLOOR, z, x + int(0, 6), FLOOR + int(0, 2), z + int(0, 1), STONE)
			end
			for _ = 1, int(0, 4) do
				local x, z = int(-30, 30), int(-30, 30)
				box(setRandom, x, FLOOR + int(2, 3), z, x + int(2, 8), FLOOR + 3, z + int(2, 8), STONE)
			end
			for _ = 1, int(1, 24) do
				local x, z = int(-34, 34), int(-34, 34)
				local y = FLOOR
				while getRandom(x, y, z) ~= AIR and y < FLOOR + 4 do
					y += 1
				end
				setRandom(x, y, z, LIGHTS[int(1, #LIGHTS)])
			end
			local noonRandom = context({}, randomSky, NOON, { daySpawn = true })
			for _ = 1, 8 do
				local cx, cz, count = int(-20, 20), int(-20, 20), int(1, 4)
				-- (The offsets come from rolls of PACK_SPREAD * 2 + 1; every other roll, the light
				-- rolls under a roof, is the darkest, the same for both.)
				local offsets = {}
				for i = 1, (count - 1) * 2 do
					offsets[i] = int(0, spread - 1)
				end
				local function nextInt(n: number): number
					if n == spread then
						return table.remove(offsets, 1) :: number
					end
					return n - 1
				end
				local expected = {}
				local index, floors = 0, 0
				for member = 1, count do
					local mx, mz = cx, cz
					if member > 1 then
						mx += offsets[index + 1] - MobSpawning.PACK_SPREAD
						mz += offsets[index + 2] - MobSpawning.PACK_SPREAD
						index += 2
					end
					local my = MobSpawning.findFloor(
						getRandom,
						zombieKind,
						mx,
						FLOOR + MobSpawning.PACK_SEARCH,
						mz,
						MobSpawning.PACK_SEARCH * 2
					)
					floors += if my then 1 else 0
					if my and MobSpawning.validSpot(getRandom, noonRandom, zombieKind, mx, my, mz, nextInt) then
						table.insert(expected, `{mx},{my},{mz}`)
					end
				end
				local packWorld = newWorld(getRandom, 5)
				local got = {}
				for _, id in MobSpawning.spawnPack(packWorld, noonRandom, zombieKind, cx, FLOOR, cz, count, nextInt) do
					local body = (packWorld:get(id) :: MobWorld.Mob).body
					table.insert(got, `{body.x - 0.5},{body.y},{body.z - 0.5}`)
				end
				table.sort(expected)
				table.sort(got)
				packs += 1
				members += count
				mixed += if #expected > 0 and #expected < floors then 1 else 0
				if table.concat(expected, " ") ~= table.concat(got, " ") then
					mismatches += 1
				end
			end
		end
		print(
			`         {packs} random packs ({members} members; {mixed} with some members in and some out): {mismatches} differ from each member's own test`
		)
		t.eq(mismatches, 0, "every pack spawns the members whose own test passes")
		-- Under a roof by day it needs the dark: near its edge (sky light 14) no, deep under it
		-- (sky light 0) when the rolls allow, as any monster.
		local getRoof, setRoof, roofSky = flat()
		box(setRoof, 20, FLOOR + 2, -10, 40, FLOOR + 2, 10, STONE)
		local kind = MobList.get(ZOMBIE) :: MobList.Kind
		local function darkest(n: number): number
			return n - 1
		end
		local function brightest(_n: number): number
			return 0
		end
		local ctx = context({}, roofSky, NOON, { daySpawn = true })
		t.ok(MobSpawning.validSpot(getRoof, ctx, kind, 50, FLOOR, 0, brightest), "the open ground: no roll needed")
		t.ok(not MobSpawning.validSpot(getRoof, ctx, kind, 20, FLOOR, 0, darkest), "under the roof's edge: too bright")
		t.ok(MobSpawning.validSpot(getRoof, ctx, kind, 30, FLOOR, 0, darkest), "deep under it: dark enough")
		t.ok(
			not MobSpawning.validSpot(getRoof, ctx, kind, 21, FLOOR, 0, brightest),
			"a block in from the edge (sky light 13): the rolls say no"
		)
		-- Creatures keep their own rule; a cow is no zombie.
		t.ok(
			not MobSpawning.validSpot(getRoof, ctx, MobList.get(kindId("Cow")) :: MobList.Kind, 30, FLOOR, 0, darkest),
			"no cow in the dark"
		)
	end)

	--[[ 2. No sun burning ]]

	t.test("zombies: none burns in the noon sun", function()
		local getBlock, _, skyOpen, skyClear = flat()
		local world = newWorld(getBlock)
		local ids = {}
		for kind = ZOMBIE, MobList.COUNT do
			table.insert(ids, world:spawn(kind, (kind - ZOMBIE) * 6 + 0.5, FLOOR, 0.5))
		end
		local ctx = context({}, skyOpen, NOON)
		ctx.skyClear = skyClear
		run(world, ctx, 400)
		for _, id in ids do
			local mob = world:get(id) :: MobWorld.Mob
			t.eq(mob.health, mob.kind.health, `{mob.kind.name} unhurt`)
			t.eq(mob.burn.fire, 0, `{mob.kind.name} not alight`)
		end
	end)

	--[[ 3. Noise ]]

	local function noise(x: number, y: number, z: number, radius: number): { MobAI.Noise }
		return { { x = x, y = y, z = z, radius = radius } }
	end

	t.test("zombies: a noise brings them to look; hearing; a zombie that hears looks for players at once", function()
		local getBlock, _, skyOpen = flat(nil, STONE)
		local world = newWorld(getBlock, 3)
		local id = world:spawn(ZOMBIE, 0.5, FLOOR, 0.5, nil, 0)
		local mob = world:get(id) :: MobWorld.Mob
		-- (Nobody about: a zombie far from every player is thinned, which a noise overrides.)
		local quiet = context({}, skyOpen, NOON)
		run(world, quiet, 3)
		local heard = context({}, skyOpen, NOON, { noises = noise(10.5, FLOOR, 0.5, Apocalypse.Noise.Break) })
		world:tick(heard)
		t.eq(mob.ai.goal, "investigate", "it heard a break 10 blocks away")
		local nearest = math.huge
		for _ = 1, 400 do
			world:tick(quiet)
			local dx, dz = mob.body.x - 10.5, mob.body.z - 0.5
			nearest = math.min(nearest, math.sqrt(dx * dx + dz * dz))
		end
		t.ok(nearest <= 3, `it came within 3 blocks of it ({nearest})`)
		-- Hearing 0.8 (the brute): a radius-10 noise reaches 8 blocks, not 9.
		local deaf = newWorld(getBlock, 3)
		local brute = deaf:spawn(BRUTE, 0.5, FLOOR, 0.5)
		local zombie = deaf:spawn(ZOMBIE, 0.5, FLOOR, 20.5)
		deaf:tick(context({}, skyOpen, NOON, { noises = noise(9.5, FLOOR, 0.5, 10) }))
		t.ok((deaf:get(brute) :: MobWorld.Mob).ai.goal ~= "investigate", "a brute ignores it at 9 blocks")
		deaf:tick(context({}, skyOpen, NOON, { noises = noise(9.5, FLOOR, 20.5, 10) }))
		t.eq((deaf:get(zombie) :: MobWorld.Mob).ai.goal, "investigate", "a zombie hears it at 9")
		-- A zombie that hears a noise and can see a player 12 blocks away targets them that tick
		-- (not waiting for its every-10-ticks look).
		local sight = newWorld(getBlock, 3)
		local p = player("p", 12.5, FLOOR, 0.5)
		local looker = sight:spawn(ZOMBIE, 0.5, FLOOR, 0.5)
		local m = sight:get(looker) :: MobWorld.Mob
		-- (A tick on which it would not look: (age + id) % 10 ~= 0.)
		m.age = 4
		sight:tick(context({ p }, skyOpen, NOON))
		t.eq(m.ai.target, nil, "it hasn't looked yet")
		sight:tick(context({ p }, skyOpen, NOON, { noises = noise(-5.5, FLOOR, 0.5, 10) }))
		t.eq(m.ai.target, "p", "the noise made it look: the player is seen")
		-- The night's and the rain's factors (ZombieDirector.hear, applied by the glue).
		local loud = ZombieDirector.hear(noise(0, 0, 0, 10), true, nil, Apocalypse.Noise)
		t.near(loud[1].radius, 12.5, 1e-9, "x 1.25 at night")
		local wet = ZombieDirector.hear(noise(0, 0, 0, 10), false, function()
			return true
		end, Apocalypse.Noise)
		t.near(wet[1].radius, 7, 1e-9, "x 0.7 in the rain")
	end)

	--[[ 4. Breaking ]]

	t.test("zombies: break a closed door in 240 ticks (a brute 80, two zombies about 120), unseen", function()
		local total, breaking, seen, broken, drops, getBlock = breakThrough("door", ZOMBIE)
		t.ok(total ~= nil, "the door broke")
		t.near(total :: number, 240, 25, `from the first tick: {total}`)
		t.near(breaking, 240, 2, "of which breaking")
		t.ok(not seen, "the player behind the door was never seen")
		t.eq(#broken, 1, "one break for the door")
		t.ok(Blocks.isDoor(broken[1].block), "the door")
		t.eq(drops, 0, "nothing dropped")
		t.eq(getBlock(0, FLOOR, 3), AIR, "the lower half gone")
		t.eq(getBlock(0, FLOOR + 1, 3), AIR, "and the upper half")
		local bruteTotal, bruteBreaking, bruteSeen = breakThrough("door", BRUTE)
		t.near(bruteBreaking, 80, 2, `a brute's breakPower 3: {bruteBreaking} ticks breaking`)
		-- (From the first tick: its slower walk of 1.1 blocks into the doorway, 19 ticks, and the
		-- 10 blocked ticks before it starts: 109.)
		t.ok((bruteTotal :: number) <= 80 + 30, `{bruteTotal} from the first tick`)
		t.ok(not bruteSeen, "the brute never saw the player either")
		local _, pairBreaking, _, pairBroken = breakThrough("door", ZOMBIE, nil, nil, nil, 1)
		t.near(pairBreaking, 120, 15, `two zombies share the damage: {pairBreaking}`)
		t.eq(#pairBroken, 1, "and it breaks once")
	end)

	t.test("zombies: glass 60, planks 600, a barricade 900, a reinforced one 3000 (a brute a third)", function()
		for _, case in
			{
				{ B.Glass, 60 },
				{ B.Planks, 600 },
				{ B.Barricade, 900 },
				{ B.ReinforcedBarricade, 3000 },
			}
		do
			local block, ticks = case[1], case[2]
			t.eq(Blocks.zombieBreak(block), ticks, `{Blocks.get(block).name}'s zombieBreak`)
			local _, breaking, _, broken = breakThrough(block, ZOMBIE)
			t.near(breaking, ticks, 2, `{Blocks.get(block).name}: a zombie ({breaking})`)
			t.eq(broken[1].block, block)
			local _, bruteBreaking = breakThrough(block, BRUTE)
			t.near(bruteBreaking, ticks / 3, 2, `{Blocks.get(block).name}: a brute ({bruteBreaking})`)
		end
	end)

	t.test("zombies: damage decays after 100 idle ticks; iron, chests and hatches never break", function()
		local getBlock, set, skyOpen = flat()
		wall(set, B.Planks)
		local world = newWorld(getBlock)
		local p = player("p", 0.5, FLOOR, 6.5)
		local id = world:spawn(ZOMBIE, 0.5, FLOOR, 2.3, nil, 0)
		local mob = world:get(id) :: MobWorld.Mob
		mob.ai.target, mob.ai.goal = "p", "chase"
		local ctx = context({ p }, skyOpen)
		local started = 0
		for tick = 1, 400 do
			world:tick(ctx)
			world:takeChanges()
			if mob.ai.bx ~= nil then
				started += 1
				if started == 100 then
					break
				end
			end
		end
		t.eq(started, 100, "100 ticks of breaking")
		t.near(world:blockDamage(0, FLOOR, 3), 100, 1, "100 damage on the planks")
		-- The player goes creative: the zombie gives up, the damage stays for 100 ticks.
		p.mode = GameMode.CREATIVE
		run(world, ctx, 2)
		t.eq(mob.ai.bx, nil, "it stopped")
		run(world, ctx, 90)
		t.near(world:blockDamage(0, FLOOR, 3), 100, 1, "still there 92 ticks later")
		run(world, ctx, 20)
		t.eq(world:blockDamage(0, FLOOR, 3), 0, "gone after 100 idle ticks")
		-- Iron, chests, the open hatch: nothing breaks, however long.
		for _, block in { B.IronBlock, B.Chest, B.BunkerHatchOpen } do
			local total, breaking, _, broken, _, cells = breakThrough(block, ZOMBIE, nil, nil, 600)
			t.eq(total, nil, `{Blocks.get(block).name} never breaks`)
			t.eq(breaking, 0, "nor is it hit")
			t.eq(#broken, 0)
			t.eq(cells(0, FLOOR, 3), block, "it is still there")
		end
		-- A zombie standing on a shut hatch over its player never digs down.
		local getHatch, setHatch, hatchSky = flat()
		setHatch(0, FLOOR - 1, 0, B.BunkerHatch)
		box(setHatch, 0, FLOOR - 5, 0, 0, FLOOR - 2, 0, AIR)
		local below = newWorld(getHatch)
		local digger = below:spawn(ZOMBIE, 0.5, FLOOR, 0.5)
		local hunter = below:get(digger) :: MobWorld.Mob
		hunter.ai.hunt = "p"
		run(below, context({ player("p", 0.5, FLOOR - 5, 0.5) }, hatchSky), 600, getHatch, setHatch)
		t.eq(getHatch(0, FLOOR - 1, 0), B.BunkerHatch, "the hatch holds")
	end)

	t.test("zombies: break only near and level with what they go for; an investigation breaks in", function()
		-- 9 blocks off horizontally: no; 3 blocks up: no.
		local far, farBreaking = breakThrough("door", ZOMBIE, 2.7 + 9.2, nil, 500)
		t.eq(far, nil, "the target 9 blocks away: the door holds")
		t.eq(farBreaking, 0, "never hit")
		local high, highBreaking = breakThrough("door", ZOMBIE, 6.5, FLOOR + 3, 500)
		t.eq(high, nil, "the target 3 blocks up: the door holds")
		t.eq(highBreaking, 0, "never hit")
		-- 2 up is still level enough.
		local up = breakThrough("door", ZOMBIE, 6.5, FLOOR + 2, 500)
		t.ok(up ~= nil, "2 blocks up: it breaks in")
		-- A noise behind the door 4 blocks off: the zombie goes to look and breaks the door.
		local getBlock, set, skyOpen = flat()
		wall(set, "door")
		local world = newWorld(getBlock)
		local id = world:spawn(ZOMBIE, 0.5, FLOOR, 1.5, nil, 0)
		local mob = world:get(id) :: MobWorld.Mob
		world:tick(context({}, skyOpen, NOON, { noises = noise(0.5, FLOOR, 5.5, 10) }))
		t.eq(mob.ai.goal, "investigate")
		run(world, context({}, skyOpen, NOON), 400, getBlock, set)
		t.eq(getBlock(0, FLOOR, 3), AIR, "it broke the door to look")
		t.ok(mob.body.z > 3, `and went through ({mob.body.z})`)
	end)

	--[[ 5. The brute ]]

	t.test("zombies: the brute walks through an open door and climbs a 1 x 1 ladder shaft", function()
		local getBlock, set, skyOpen = flat()
		wall(set, "open")
		local world = newWorld(getBlock)
		local id = world:spawn(BRUTE, 0.5, FLOOR, 0.5, nil, 0)
		local mob = world:get(id) :: MobWorld.Mob
		local p = player("p", 0.5, FLOOR, 8.5)
		run(world, context({ p }, skyOpen), 200, getBlock, set)
		t.ok(mob.body.z > 4, `through the open door ({mob.body.z})`)
		t.ok(Blocks.isDoor(getBlock(0, FLOOR, 3) :: number), "without breaking it")
		-- A shaft 5 blocks deep (stone round a 1 x 1 hole, a ladder on its south wall), the player
		-- at the top beside it: the hunting brute climbs out.
		local getShaft, setShaft, shaftSky = flat()
		box(setShaft, -1, FLOOR, -1, 1, FLOOR + 4, 1, STONE)
		box(setShaft, 0, FLOOR, 0, 0, FLOOR + 4, 0, B.Ladder)
		local shaft = newWorld(getShaft)
		local climber = shaft:spawn(BRUTE, 0.5, FLOOR, 0.45, nil, 0)
		local brute = shaft:get(climber) :: MobWorld.Mob
		brute.ai.hunt = "p"
		brute.persistent = true
		local top = 0
		local ctx = context({ player("p", 0.5, FLOOR + 5, 2.5) }, shaftSky)
		for _ = 1, 400 do
			shaft:tick(ctx)
			shaft:takeChanges()
			top = math.max(top, brute.body.y)
		end
		t.ok(top >= FLOOR + 5 - 1e-6, `it climbed out ({top})`)
		t.eq(brute.ai.bx, nil, "breaking nothing")
	end)

	--[[ 6. The screamer ]]

	t.test("zombies: a screamer that spots a player shrieks (a noise of 48), at most every 400 ticks", function()
		local getBlock, _, skyOpen = flat()
		local world = newWorld(getBlock)
		local id = world:spawn(SCREAMER, 0.5, FLOOR, 0.5, nil, 0)
		local mob = world:get(id) :: MobWorld.Mob
		local p = player("p", 10.5, FLOOR, 0.5)
		local ctx = context({ p }, skyOpen)
		local screams, sounds = {}, 0
		local function step(n: number)
			for _ = 1, n do
				world:tick(ctx)
				local changes = world:takeChanges()
				for _, made in changes.noises do
					table.insert(screams, made)
				end
				for _, cue in changes.sounds do
					if cue.name == "entity.zombie_screamer.scream" then
						sounds += 1
					end
				end
			end
		end
		step(12)
		t.eq(mob.ai.target, "p", "it spotted the player")
		t.eq(#screams, 1, "one shriek")
		t.eq(screams[1].radius, 48, "a noise of 48")
		t.eq(sounds, 1, "and its sound")
		local x = mob.body.x
		step(20)
		t.near(mob.body.x, x, 0.05, "it stands while it shrieks")
		-- Lost and found again within the cooldown: no second shriek.
		p.mode = GameMode.CREATIVE
		step(2)
		t.eq(mob.ai.target, nil)
		p.mode = GameMode.SURVIVAL
		step(20)
		t.eq(mob.ai.target, "p")
		t.eq(#screams, 1, "the cooldown holds")
		p.mode = GameMode.CREATIVE
		step(400)
		p.mode = GameMode.SURVIVAL
		step(20)
		t.eq(#screams, 2, "after it, a second shriek")
		-- The next tick the others hear it (the glue's NoiseBus): a zombie 40 blocks off goes to look.
		local other = world:spawn(ZOMBIE, -39.5, FLOOR, 0.5)
		world:tick(context({ p }, skyOpen, nil, { noises = { screams[1] } }))
		t.eq((world:get(other) :: MobWorld.Mob).ai.goal, "investigate", "it heard the shriek")
		-- Sent away mid-shriek (a leave round: the player hid): the shriek still ends on time, so
		-- the Screaming flag shows no longer than a shriek and it walks off at once.
		local getAway, _, awaySky = flat()
		local away = newWorld(getAway, 3)
		local hider = player("p", 0.5, FLOOR, 0.5)
		local shrieker = away:get(away:spawn(SCREAMER, 10.5, FLOOR, 0.5)) :: MobWorld.Mob
		for i = 1, 8 do
			away:spawn(ZOMBIE, 0.5 + i, FLOOR, 5.5)
		end
		local noon = context({ hider }, awaySky, NOON)
		for _ = 1, 40 do
			if shrieker.ai.scream > 0 then
				break
			end
			away:tick(noon)
			away:takeChanges()
		end
		t.ok(shrieker.ai.scream > 0, "it shrieked")
		hider.mode = GameMode.CREATIVE
		away:tick(noon)
		away:takeChanges()
		ZombieDirector.leaveRound(away, ZombieDirector.new(), noon, Config.Mobs, Apocalypse, true)
		t.ok(shrieker.ai.leave > 0, "sent away")
		local flagged = 0
		local x0, z0 = shrieker.body.x, shrieker.body.z
		for _ = 1, 300 do
			away:tick(noon)
			away:takeChanges()
			if bit32.band(MobTracking.flags(shrieker), Protocol.MobFlag.Screaming) ~= 0 then
				flagged += 1
			end
		end
		t.ok(flagged <= MobAI.SCREAM_TICKS, `the Screaming flag for {flagged} ticks of the walk`)
		local walked = math.sqrt((shrieker.body.x - x0) ^ 2 + (shrieker.body.z - z0) ^ 2)
		t.ok(walked > 5, `it walked off ({walked})`)
		-- Thinned mid-shriek (its player gone 60 blocks off: past its follow range, 32, and with
		-- no player within ThinDistance it thinks only every 4th tick): the shriek still ends on
		-- time, so the flag shows no longer than a shriek (the old countdown, after the thinning's
		-- early return, showed it about 150 ticks).
		local getThin, _, thinSky = flat()
		local thinWorld = newWorld(getThin, 3)
		local leaver = player("p", 0.5, FLOOR, 0.5)
		local thinned = thinWorld:get(thinWorld:spawn(SCREAMER, 10.5, FLOOR, 0.5)) :: MobWorld.Mob
		local night = context({ leaver }, thinSky, MIDNIGHT)
		for _ = 1, 60 do
			if thinned.ai.scream > 0 then
				break
			end
			thinWorld:tick(night)
			thinWorld:takeChanges()
		end
		t.ok(thinned.ai.scream > 0, "it shrieked at night")
		leaver.x = 70.5
		local shown = 0
		for _ = 1, 300 do
			thinWorld:tick(night)
			thinWorld:takeChanges()
			if bit32.band(MobTracking.flags(thinned), Protocol.MobFlag.Screaming) ~= 0 then
				shown += 1
			end
		end
		t.eq(thinned.ai.target, nil, "it lost its player")
		t.ok(Zombies.ThinDistance < 60, "and is thinned")
		t.ok(shown <= MobAI.SCREAM_TICKS, `the Screaming flag for {shown} ticks once thinned`)
	end)

	--[[ 7. Blood moons ]]

	local function moonContext(players, skyOpen, dayTime: number, extra: { [string]: any }?): any
		local ctx = context(players, skyOpen, dayTime, extra)
		local moonUp, moon = ZombieDirector.moon(Apocalypse, dayTime)
		ctx.hostilePaused = moonUp
		ctx.daySpawn = true
		ctx.hostileCap = function(view: MobWorld.PlayerView): number
			return ZombieDirector.cap(Config.Mobs, Apocalypse, ctx.night, 0, moon)
		end
		return ctx
	end

	t.test("zombies: a blood moon's waves (8 a player at k = 1, within the cap of 28), no natural spawns", function()
		t.ok(BloodMoon.active(MOON1, Moon), "midnight of day 2 is a blood moon's")
		t.eq(BloodMoon.number(2, Moon), 1, "the first")
		local getBlock, _, skyOpen = flat()
		local world = newWorld(getBlock, 5, 1000)
		local p = player("p", 0.5, FLOOR, 0.5)
		local ctx = moonContext({ p }, skyOpen, MOON1)
		local state = ZombieDirector.new()
		local spawnState = MobSpawning.new()
		ZombieDirector.step(world, state, ctx, Config.Mobs, Apocalypse)
		t.eq(state.lastWave, 8, "a wave of 8 at once")
		for _, mob in world:each() do
			t.eq(mob.ai.hunt, "p", "each hunts the player")
			t.ok(mob.persistent, "and stays")
			local d = math.sqrt((mob.body.x - p.x) ^ 2 + (mob.body.z - p.z) ^ 2)
			t.ok(d >= 24 and d <= 44 + 5, `28-44 blocks out ({d})`)
		end
		-- Natural spawning is paused (a round a tick here, which would fill the cap at once): the
		-- 8 stay 8 until the next wave, 600 ticks on; waves fill the cap of 28.
		local settings = table.clone(SETTINGS)
		for tick = 1, 2400 do
			MobSpawning.step(world, spawnState, ctx, settings)
			ZombieDirector.step(world, state, ctx, Config.Mobs, Apocalypse)
			if tick == 590 then
				t.eq(MobSpawning.census(world), 8, "no natural spawns between waves")
			end
		end
		t.eq(MobSpawning.census(world), 28, "the cap of 28 (k = 1)")
		t.eq(ZombieDirector.capOf(Config.Mobs, Apocalypse, ctx, p), 28)
		for _, mob in world:each() do
			t.eq(mob.ai.hunt, "p", "every one a wave's, hunting")
		end
		-- No waves where nothing spawns (Config.Mobs.Spawning false: the void and the debug
		-- worlds, World/WorldInfo).
		local off = table.clone(Config.Mobs)
		off.Spawning = false
		local quiet = newWorld(getBlock, 5, 1000)
		local quietState = ZombieDirector.new()
		local offSettings = table.clone(SETTINGS)
		offSettings.Spawning = false
		for _ = 1, 1300 do
			MobSpawning.step(quiet, MobSpawning.new(), ctx, offSettings)
			ZombieDirector.step(quiet, quietState, ctx, off, Apocalypse)
		end
		t.eq(quiet:count(), 0, "Spawning false: no wave through a blood moon")
		-- Under a roof no wave comes in: only onto open floors (here the roof's top).
		local getRoof, setRoof, roofSky = flat()
		box(setRoof, -60, FLOOR + 3, -60, 60, FLOOR + 3, 60, STONE)
		local roofed = newWorld(getRoof, 5, 1000)
		ZombieDirector.step(roofed, ZombieDirector.new(), moonContext({ p }, roofSky, MOON1), Config.Mobs, Apocalypse)
		for _, mob in roofed:each() do
			t.eq(mob.body.y, FLOOR + 4, "on the roof, not under it")
		end
		-- With the roof's top out of reach (a deep room, the wave's floor search from 24 above the
		-- player), nothing.
		local getDeep, setDeep, deepSky = flat()
		box(setDeep, -60, FLOOR, -60, 60, FLOOR + 30, 60, STONE)
		box(setDeep, -50, FLOOR, -50, 50, FLOOR + 3, 50, AIR)
		local deep = newWorld(getDeep, 5, 1000)
		ZombieDirector.step(deep, ZombieDirector.new(), moonContext({ p }, deepSky, MOON1), Config.Mobs, Apocalypse)
		t.eq(deep:count(), 0, "no wave in a hall under 27 blocks of stone")
	end)

	t.test("zombies: hunters close in without sight; the hunt ends with the moon", function()
		local getBlock, set, skyOpen = flat()
		-- The player in a pen of 4 high walls (radius 3): not seen from outside, even jumping.
		box(set, -3, FLOOR, -3, 3, FLOOR + 3, 3, STONE)
		box(set, -2, FLOOR, -2, 2, FLOOR + 3, 2, AIR)
		local world = newWorld(getBlock)
		local p = player("p", 0.5, FLOOR, 0.5)
		local id = world:spawn(ZOMBIE, 30.5, FLOOR, 0.5)
		local mob = world:get(id) :: MobWorld.Mob
		local state = ZombieDirector.new()
		local ctx = moonContext({ p }, skyOpen, MOON1)
		local saw = false
		for _ = 1, 400 do
			world:tick(ctx)
			world:takeChanges()
			ZombieDirector.step(world, state, ctx, Config.Mobs, Apocalypse)
			saw = saw or mob.ai.target ~= nil
		end
		t.eq(mob.ai.hunt, "p", "hunting the player within 44 blocks")
		t.ok(mob.persistent, "persistent")
		t.ok(not saw, "never seeing them")
		t.ok(math.abs(mob.body.x - 0.5) < 5, `it closed in (x {mob.body.x})`)
		-- At End the hunt ends.
		local over = moonContext({ p }, skyOpen, 2 * DAY + Moon.End + 1)
		t.ok(not BloodMoon.active(over.dayTime, Moon), "the moon has set")
		ZombieDirector.step(world, state, over, Config.Mobs, Apocalypse)
		t.eq(mob.ai.hunt, nil, "no more hunt")
		t.ok(not mob.persistent, "nor persistence")
	end)

	t.test("zombies: a player sealed underground through a k = 3 moon sees the crowd thin to 7", function()
		t.eq(BloodMoon.number(8, Moon), 3, "day 8's is the third")
		local getBlock, set, skyOpen = flat()
		-- A room 3 x 2 x 3 four blocks under the grass, sealed.
		box(set, -1, FLOOR - 5, -1, 1, FLOOR - 4, 1, AIR)
		local world = newWorld(getBlock, 9, 1000)
		local p = player("p", 0.5, FLOOR - 5, 0.5)
		local state = ZombieDirector.new()
		local spawnState = MobSpawning.new()
		local settings = table.clone(SETTINGS)
		settings.HostileInterval = 20
		settings.Attempts = 3
		local function nearby(): number
			local n = 0
			for _, mob in world:each() do
				local dx, dy, dz = mob.body.x - p.x, mob.body.y - p.y, mob.body.z - p.z
				if not mob.dead and dx * dx + dy * dy + dz * dz <= 32 * 32 then
					n += 1
				end
			end
			return n
		end
		local peak = 0
		local endTime = 8 * DAY + Moon.End
		for time = MOON3, endTime + 1200 do
			local ctx = moonContext({ p }, skyOpen, time)
			world:tick(ctx)
			world:takeChanges()
			MobSpawning.step(world, spawnState, ctx, settings)
			ZombieDirector.step(world, state, ctx, Config.Mobs, Apocalypse)
			peak = math.max(peak, nearby())
			if time == endTime - 1 then
				t.ok(nearby() > 7, `a crowd above the room through the moon ({nearby()}, at most {peak})`)
			end
		end
		t.ok(peak >= 20, `the moon brought a crowd ({peak})`)
		t.ok(nearby() <= 7, `within 1200 ticks of its end, at most 7 within 32 blocks ({nearby()})`)
	end)

	--[[ 8. Leave rounds ]]

	t.test("zombies: at dawn the surplus round a player leaves, the furthest first, out of sight", function()
		local getBlock, set, skyOpen = flat()
		-- The player in a pen of 3 high walls (radius 4) with a gap on the east side.
		box(set, -4, FLOOR, -4, 4, FLOOR + 2, 4, STONE)
		box(set, -3, FLOOR, -3, 3, FLOOR + 2, 3, AIR)
		box(set, 4, FLOOR, 0, 4, FLOOR + 1, 0, AIR)
		local world = newWorld(getBlock, 13)
		local p = player("p", 0.5, FLOOR, 0.5, GameMode.CREATIVE)
		local ids = {}
		for i = 1, 20 do
			local angle = i / 20 * math.pi * 2
			local distance = 6 + i * 0.6
			table.insert(
				ids,
				world:spawn(ZOMBIE, 0.5 + math.cos(angle) * distance, FLOOR, 0.5 + math.sin(angle) * distance)
			)
		end
		local state = ZombieDirector.new()
		-- Night turning to day (DayCycle.isDay) between 23000 and 23500.
		local time = 23000
		local ctx = context({ p }, skyOpen, time)
		ZombieDirector.step(world, state, ctx, Config.Mobs, Apocalypse)
		local leavers: { [number]: boolean } = {}
		local removedAt: { [number]: number } = {}
		local before = world:each()
		local roundChecked = false
		for _ = 1, 1500 do
			time += 1
			ctx = context({ p }, skyOpen, time)
			world:tick(ctx)
			local changes = world:takeChanges()
			for _, gone in changes.removed do
				local mob = nil
				for _, candidate in before do
					if candidate.id == gone then
						mob = candidate
					end
				end
				local body = (mob :: MobWorld.Mob).body
				local d = math.sqrt((body.x - p.x) ^ 2 + (body.z - p.z) ^ 2)
				t.ok(d >= Zombies.Leave.Distance, `removed only 24 blocks away ({d})`)
				t.ok(
					d > 64
						or not MobAI.canSee(
							getBlock,
							p.x,
							p.y + p.eye,
							p.z,
							body.x,
							body.y + (mob :: any).kind.eye,
							body.z
						),
					"and out of sight"
				)
				removedAt[gone] = time
			end
			ZombieDirector.step(world, state, ctx, Config.Mobs, Apocalypse)
			local nearestLeaver, furthestStayer = math.huge, 0
			for _, mob in world:each() do
				local d = math.sqrt((mob.body.x - p.x) ^ 2 + (mob.body.y - p.y) ^ 2 + (mob.body.z - p.z) ^ 2)
				if mob.ai.leave > 0 then
					leavers[mob.id] = true
					nearestLeaver = math.min(nearestLeaver, d)
				else
					furthestStayer = math.max(furthestStayer, d)
				end
			end
			if not roundChecked and nearestLeaver < math.huge then
				-- (The round itself: the leavers are the furthest.)
				roundChecked = true
				t.ok(DayCycle.isDay(time), `at dawn ({time})`)
				t.ok(nearestLeaver >= furthestStayer, `the furthest go ({nearestLeaver} >= {furthestStayer})`)
			end
		end
		t.ok(roundChecked, "a leave round at dawn")
		local count = 0
		for _ in leavers do
			count += 1
		end
		t.eq(count, 13, "13 sent away (20 against the day cap of 7)")
		t.eq(#ids, 20)
		local near = 0
		for _, mob in world:each() do
			if math.sqrt((mob.body.x - p.x) ^ 2 + (mob.body.z - p.z) ^ 2) <= 32 then
				near += 1
			end
		end
		t.eq(near, 7, "the day cap of 7 stays near")
		local gone = 0
		for _ in removedAt do
			gone += 1
		end
		t.ok(gone >= 10, `most of the leavers are gone already ({gone})`)
	end)

	--[[ 9. Separation ]]

	t.test("zombies: a crowd of 12 on one player keeps its room (at least 0.4 apart)", function()
		local getBlock, _, skyOpen = flat()
		local world = newWorld(getBlock)
		local p = player("p", 0.5, FLOOR, 0.5)
		for i = 1, 12 do
			local angle = i / 12 * math.pi * 2
			local id = world:spawn(ZOMBIE, 0.5 + math.cos(angle) * 8, FLOOR, 0.5 + math.sin(angle) * 8)
			local mob = world:get(id) :: MobWorld.Mob
			mob.ai.target, mob.ai.goal = "p", "chase"
		end
		local ctx = context({ p }, skyOpen)
		run(world, ctx, 100)
		local closest = math.huge
		for _ = 1, 300 do
			world:tick(ctx)
			world:takeChanges()
			local mobs = world:each()
			for i = 1, #mobs do
				for j = i + 1, #mobs do
					local a, b = mobs[i].body, mobs[j].body
					closest = math.min(closest, math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2))
				end
			end
		end
		print(string.format("         12 zombies round a player: %.3f blocks apart at the closest", closest))
		t.ok(closest >= 0.4, `the closest two: {closest}`)
		-- The crowd pass on its own: two in one spot are pushed apart, away from each other.
		local crowd = MobCrowd.new()
		local zombie = MobList.get(ZOMBIE) :: MobList.Kind
		local a = {
			id = 1,
			kind = zombie,
			body = { x = 0, z = 0, vx = 0, vz = 0 },
			removed = false,
			dead = false,
			frozen = false,
		}
		local b = {
			id = 2,
			kind = zombie,
			body = { x = 0.3, z = 0, vx = 0, vz = 0 },
			removed = false,
			dead = false,
			frozen = false,
		}
		MobCrowd.build(crowd, { a, b } :: any, Zombies.Separation)
		t.eq(MobCrowd.push(crowd, a :: any), 1)
		t.near(a.body.vx, -MobCrowd.PUSH * (0.6 + Zombies.Separation - 0.3), 1e-9, "pushed away by PUSH x the overlap")
		t.eq(MobCrowd.push(crowd, b :: any), 1)
		t.near(b.body.vx, -a.body.vx, 1e-9, "and the other the other way")
		-- Two in the very same spot go apart, opposite ways; one in the next cell over is found too.
		local c = {
			id = 3,
			kind = zombie,
			body = { x = 3.9, z = 5, vx = 0, vz = 0 },
			removed = false,
			dead = false,
			frozen = false,
		}
		local d = {
			id = 4,
			kind = zombie,
			body = { x = 3.9, z = 5, vx = 0, vz = 0 },
			removed = false,
			dead = false,
			frozen = false,
		}
		local e = {
			id = 5,
			kind = zombie,
			body = { x = 5.0, z = 5, vx = 0, vz = 0 },
			removed = false,
			dead = false,
			frozen = false,
		}
		MobCrowd.build(crowd, { c, d, e } :: any, Zombies.Separation)
		MobCrowd.push(crowd, c :: any)
		MobCrowd.push(crowd, d :: any)
		t.near(math.sqrt(c.body.vx ^ 2 + c.body.vz ^ 2), MobCrowd.PUSH * 0.7, 1e-9, "the full overlap")
		t.near(c.body.vx, -d.body.vx, 1e-9, "opposite ways")
		t.near(c.body.vz, -d.body.vz, 1e-9)
		t.eq(MobCrowd.push(crowd, e :: any), 0, "1.1 apart: no push")
		e.body.x = 4.55
		MobCrowd.build(crowd, { c, d, e } :: any, Zombies.Separation)
		t.eq(MobCrowd.push(crowd, e :: any), 2, "0.65 apart across a cell's edge: both push")
		-- 40 zombies walking 4000 blocks: the hash keeps only the cells in use (no list kept for
		-- every cell a zombie ever stood in).
		local walkers = {}
		for i = 1, 40 do
			table.insert(walkers, {
				id = 10 + i,
				kind = zombie,
				body = { x = 0, z = i * 3, vx = 0, vz = 0 },
				removed = false,
				dead = false,
				frozen = false,
			})
		end
		local most = 0
		for step = 0, 2000 do
			for _, walker in walkers do
				walker.body.x = step * 2
			end
			MobCrowd.build(crowd, walkers :: any, Zombies.Separation)
			local kept = 0
			for _ in crowd.cells do
				kept += 1
			end
			most = math.max(most, kept)
		end
		t.eq(most, 40, "40 cells kept at most, those in use")
		t.ok(#crowd.pool <= 40, `the spare lists ({#crowd.pool})`)
	end)

	--[[ 10. Thinning ]]

	t.test("zombies: a thinned zombie (no player within 32) never strolls off a 4 block drop", function()
		local getBlock, set, skyOpen = flat()
		box(set, 3, FLOOR - 4, -5, 12, FLOOR - 1, 5, AIR)
		local world = newWorld(getBlock, 17)
		local id = world:spawn(ZOMBIE, 0.5, FLOOR, 0.5, nil, math.pi / 2)
		local mob = world:get(id) :: MobWorld.Mob
		local ctx = context({ player("p", -40.5, FLOOR, 0.5, GameMode.CREATIVE) }, skyOpen, NOON)
		local lowest = FLOOR
		for _ = 1, 30 do
			mob.ai.goal = "wander"
			mob.ai.tx, mob.ai.tz, mob.ai.timer = 8.5, 0.5, 200
			for _ = 1, 100 do
				world:tick(ctx)
				world:takeChanges()
				lowest = math.min(lowest, mob.body.y)
			end
		end
		t.eq(lowest, FLOOR, "it never fell")
		t.ok(mob.body.x > 1.5 and mob.body.x < 3, `it stands at the edge ({mob.body.x})`)
	end)

	--[[ 11. Peaceful ]]

	t.test("zombies: Peaceful (HostileCap 0) spawns none, waves included", function()
		local peaceful = table.clone(Config.Mobs)
		peaceful.HostileCap = 0
		local getBlock, _, skyOpen = flat()
		local world = newWorld(getBlock, 3, 1000)
		local p = player("p", 0.5, FLOOR, 0.5)
		local settings = table.clone(SETTINGS)
		settings.HostileCap = 0
		for _, time in { MIDNIGHT, NOON, MOON1 } do
			local ctx = moonContext({ p }, skyOpen, time)
			local _, moon = ZombieDirector.moon(Apocalypse, time)
			ctx.hostileCap = function(view: MobWorld.PlayerView): number
				return ZombieDirector.cap(peaceful, Apocalypse, ctx.night, 0, moon)
			end
			local state = ZombieDirector.new()
			for _ = 1, 1300 do
				MobSpawning.step(world, MobSpawning.new(), ctx, settings)
				ZombieDirector.step(world, state, ctx, peaceful, Apocalypse)
			end
		end
		t.eq(MobSpawning.census(world), 0, "no zombie, day, night or blood moon")
		t.eq(ZombieDirector.cap(peaceful, Apocalypse, true, 1, 3), 0, "every cap 0")
	end)

	--[[ 13. Caps ]]

	t.test("zombies: caps by night, day, city and moon; the world's limits follow the day time", function()
		local mobs = Config.Mobs
		t.eq(ZombieDirector.cap(mobs, Apocalypse, true, 0, 0), 20, "night 20")
		t.eq(ZombieDirector.cap(mobs, Apocalypse, false, 0, 0), 7, "day 7")
		t.eq(ZombieDirector.cap(mobs, Apocalypse, true, 1, 0), 35, "a city's night 35 (x 1.75)")
		t.eq(ZombieDirector.cap(mobs, Apocalypse, false, 0.6, 0), 12, "a city's day 12")
		t.eq(ZombieDirector.cap(mobs, Apocalypse, true, 0.4, 0), 20, "the margin below 0.5: no city")
		t.eq(ZombieDirector.cap(mobs, Apocalypse, true, 0, 1), 28, "blood moon k = 1: 28")
		t.eq(ZombieDirector.cap(mobs, Apocalypse, true, 1, 1), 49, "in a city 49")
		t.eq(ZombieDirector.cap(mobs, Apocalypse, true, 0, 2), 32)
		t.eq(ZombieDirector.cap(mobs, Apocalypse, true, 0, 9), 60, "k = 9: 60")
		t.eq(ZombieDirector.cap(mobs, Apocalypse, true, 1, 3), 60, "at most 60")
		t.eq(select(2, ZombieDirector.moon(Apocalypse, MOON1)), 1)
		local maxMobs, maxHostile = ZombieDirector.limits(mobs, Apocalypse, MOON1)
		t.eq(maxMobs, 360, "a blood moon's world limit")
		t.eq(maxHostile, 260)
		maxMobs, maxHostile = ZombieDirector.limits(mobs, Apocalypse, MOON1 + DAY / 2)
		t.eq(maxMobs, 320, "back by day (worked out from the time, not restored)")
		t.eq(maxHostile, 200)
		-- With the apocalypse off: HostileCap, no moon.
		local off = table.clone(Apocalypse)
		off.Enabled = false
		t.eq(ZombieDirector.cap(mobs, off, false, 1, 0), 20, "off: HostileCap")
		t.eq(select(1, ZombieDirector.moon(off, MOON1)), false, "off: no moon")
	end)

	--[[ Speeds, fire, knockback ]]

	t.test("zombies: chase speeds (a walking player outpaces the slow ones; a runner only a sprint)", function()
		local getBlock, _, skyOpen = flat(400, STONE)
		local function chase(kind: number): number
			local world = newWorld(getBlock)
			local id = world:spawn(kind, 0.5, FLOOR, 0.5, nil, math.pi / 2)
			local mob = world:get(id) :: MobWorld.Mob
			-- (Hunting: the target kept to HuntKeep, 56 blocks.)
			local p = player("p", 50.5, FLOOR, 0.5)
			mob.ai.target, mob.ai.hunt, mob.ai.goal = "p", "p", "chase"
			mob.ai.visible = true
			local ctx = context({ p }, skyOpen)
			run(world, ctx, 40)
			local x0 = mob.body.x
			run(world, ctx, 40)
			return (mob.body.x - x0) / 2
		end
		local WALK, SPRINT = 4.317, 5.612
		local speeds = {}
		for _, kind in { ZOMBIE, BRUTE, CRAWLER, RUNNER, SCREAMER } do
			local speed = chase(kind)
			speeds[kind] = speed
			print(string.format("         %s chases at %.2f blocks a second", (MobList.get(kind) :: any).name, speed))
		end
		for _, kind in { ZOMBIE, BRUTE, CRAWLER, SCREAMER } do
			t.ok(speeds[kind] < WALK, `a walking player outpaces the {(MobList.get(kind) :: any).name}`)
		end
		t.ok(
			speeds[RUNNER] > WALK and speeds[RUNNER] < SPRINT,
			`a runner: between a walk and a sprint ({speeds[RUNNER]})`
		)
	end)

	t.test("zombies: the firefighter doesn't burn; the brute shrugs off knockback", function()
		local getBlock, set, skyOpen = flat()
		box(set, 0, FLOOR - 1, 0, 0, FLOOR - 1, 0, B.Lava)
		set(4, FLOOR, 0, B.Fire)
		local world = newWorld(getBlock)
		local ff = world:spawn(FIREFIGHTER, 0.5, FLOOR, 0.5)
		local zombie = world:spawn(ZOMBIE, 4.5, FLOOR, 0.5)
		local ctx = context({}, skyOpen, NOON)
		for _ = 1, 200 do
			for _, id in { ff, zombie } do
				local mob = world:get(id)
				if mob then
					mob.ai.goal = "idle"
					mob.body.x = if id == ff then 0.5 else 4.5
					mob.body.z = 0.5
				end
			end
			world:tick(ctx)
			world:takeChanges()
		end
		local firefighter = world:get(ff) :: MobWorld.Mob
		t.eq(firefighter.health, firefighter.kind.health, "lava doesn't hurt a firefighter")
		t.eq(firefighter.burn.fire, 0, "nor light it")
		local burnt = world:get(zombie)
		t.ok(burnt == nil or burnt.health < burnt.kind.health, "a zombie in fire burns")
		t.eq(world:lightning(0.5, FLOOR, 0.5, 0, 100), 1)
		t.eq(firefighter.burn.fire, 0, "lightning doesn't light it either")
		-- Knockback: 0.4 x (1 - 0.8) for a brute.
		local w2 = newWorld(getBlock)
		local brute = w2:spawn(BRUTE, 10.5, FLOOR, 0.5)
		local plain = w2:spawn(ZOMBIE, 20.5, FLOOR, 0.5)
		run(w2, ctx, 5)
		w2:hurt(brute, 1, { player = "p", x = 8.5, z = 0.5, knockback = 0.4 })
		w2:hurt(plain, 1, { player = "p", x = 18.5, z = 0.5, knockback = 0.4 })
		local vb = (w2:get(brute) :: MobWorld.Mob).body.vx
		local vz = (w2:get(plain) :: MobWorld.Mob).body.vx
		t.ok(vb > 0 and vb < vz * 0.35, `a brute takes a fifth of it ({vb} against {vz})`)
	end)

	--[[ Replication ]]

	t.test("zombies: tracking sends moves from the last sent position, with hysteresis at the edge", function()
		local getBlock, _, skyOpen = flat()
		local world = newWorld(getBlock)
		local p = player("p", 0.5, FLOOR, 0.5)
		local ids = {}
		for i = 1, 60 do
			local angle = i / 60 * math.pi * 2
			local id = world:spawn(ZOMBIE, 0.5 + math.cos(angle) * 20, FLOOR, 0.5 + math.sin(angle) * 20)
			table.insert(ids, id)
		end
		local ctx = context({ p }, skyOpen)
		local seen = {}
		-- The client's side: each mob's position as decoded, deltas added (Protocol.decodeMobs).
		local client: { [number]: { number } } = {}
		local biggest = 0
		local sizes = {}
		for sync = 1, 40 do
			run(world, ctx, 2)
			local all = world:each()
			local states = {}
			for _, mob in all do
				states[mob.id] = MobTracking.snapshot(mob)
			end
			local ops = {}
			MobTracking.ops(ops, seen, all, states, p.x, p.y, p.z, Config.Mobs.TrackingDistance, sync)
			local message = Protocol.encodeMobs(ops)
			if sync > 1 then
				biggest = math.max(biggest, buffer.len(message))
				table.insert(sizes, buffer.len(message))
			end
			for _, op in Protocol.decodeMobs(message, MobList.COUNT) :: { any } do
				if op.op == "spawn" or op.op == "state" then
					client[op.id] = { op.x, op.y, op.z }
				elseif op.op == "move" then
					local at = client[op.id]
					at[1] += op.dx
					at[2] += op.dy
					at[3] += op.dz
				elseif op.op == "remove" then
					client[op.id] = nil
				end
			end
			for _, mob in all do
				local at = client[mob.id]
				local now = states[mob.id]
				t.ok(at ~= nil, "every mob tracked")
				t.eq(at[1] * 32, now.x, "x matches the server's exactly (no drift)")
				t.eq(at[3] * 32, now.z)
			end
		end
		table.sort(sizes)
		print(
			string.format(
				"         60 zombies on the move: %d bytes a sync at the most (median %d; budget 1024)",
				biggest,
				sizes[#sizes // 2]
			)
		)
		t.ok(biggest <= 1024, `60 moving zombies under 1 KB a sync ({biggest})`)
		t.eq(MobTracking.flags(world:get(ids[1]) :: MobWorld.Mob) % 16 >= 8, true, "the Aggressive flag")
		-- Hysteresis: spawned within 64, kept to 72, removed beyond.
		local edge = newWorld(getBlock)
		local id = edge:spawn(ZOMBIE, 63.5, FLOOR, 0.5)
		local mob = edge:get(id) :: MobWorld.Mob
		local view = {}
		local function sync(n: number): { any }
			local states = { [id] = MobTracking.snapshot(mob) }
			local ops = {}
			MobTracking.ops(ops, view, { mob }, states, 0, FLOOR, 0, 64, n)
			return ops
		end
		t.eq(sync(0)[1].op, "spawn", "within 64: spawned")
		mob.body.x = 70
		local ops = sync(0)
		t.ok(#ops == 0 or ops[1].op ~= "remove", "at 70: kept")
		mob.body.x = 73
		t.eq(sync(0)[1].op, "remove", "beyond 72: removed")
		mob.body.x = 70
		t.eq(#sync(0), 0, "back to 70: not spawned again until within 64")
		mob.body.x = 60
		t.eq(sync(0)[1].op, "spawn")
		-- A step too big for an i16 (over 1023 blocks: a teleport) goes as a state, with the
		-- new position, to a viewer who still has it in view.
		mob.body.x = 60 + 2000
		local states = { [id] = MobTracking.snapshot(mob) }
		local jumped = {}
		MobTracking.ops(jumped, view, { mob }, states, mob.body.x, FLOOR, 0, 64, 0)
		t.eq(#jumped, 1)
		t.eq(jumped[1].op, "state", "a state, not a move")
		t.eq(jumped[1].x, states[id].x / 32, "at the new quantised position")
		t.eq(jumped[1].x, 2060)
		local decoded = (Protocol.decodeMobs(Protocol.encodeMobs(jumped), MobList.COUNT) :: { any })[1]
		t.eq(decoded.op, "state")
		t.eq(decoded.x, 2060, "and it decodes there")
		-- Far from the viewer at the origin, it leaves their view.
		mob.body.x = 60 + 4000
		t.eq(sync(0)[1].op, "remove", "(out of range)")
	end)

	--[[
		Costs (design §5; Lune on the flat world, `ms` a server tick, the median of 3 runs, native
		code unless NOCODEGEN=1). Measured on this shared 4 core machine (load 0.7-1.1), three
		runs of the spec each, native / NOCODEGEN=1 (the middle of the three, then the range):
		  200 zombies chasing one player              1.49 (1.41-1.62) / 5.46 (5.05-5.74) ms  (3 / 8)
		  200 zombies idle round a creative player    0.81 (0.80-1.05) / 2.89 (2.86-3.41) ms  (1.5 / 4)
		  a wave tick (k = 3), 1 player, 24 hunters   0.36 (0.31-0.43) / 1.03 (0.92-1.10) ms  (4 native)
		  the same for 4 players and 96 hunters       0.82 (0.71-1.06) / 2.75 (2.56-2.93) ms  (4 native)
		  a daytime spawning round, one player        0.96 (0.95-1.08) / 4.51 (4.16-4.62) ms  (3 native)
		  blood moon k = 3, 4 players, 144 zombies    1.10 (1.03-1.11) / 3.92 (3.67-4.04) ms  (5 native)
		  60 zombies on the move: 842 bytes a sync    (1 KB; the tracking test)
		Measured again with the code unchanged at load 1.3-1.8 (other builders' runs alongside),
		the middle of three runs, native / NOCODEGEN=1: chasing 1.95 (1.52-1.98) / 5.74, idle 1.05
		(0.80-1.05) / 3.15, the wave tick 0.47 / 1.13 (1 player) and 0.87 / 2.76 (4), the daytime
		round 1.13 (1.04-1.65) / 5.02, the moon 1.41 (1.05-1.54) / 4.22 ms; 842 bytes.
		The daytime round searches as far as a torch's light reaches (DayLightBudget 2048), its
		packs sharing one search (MobSpawning.dark). Each is held to its budget and 15% (a miss is
		measured again, the median of 5, first); without native code the native-only ones have no
		figure of their own and are held to twice it, a sanity bound.
	]]

	local function median(runs: { number }): number
		table.sort(runs)
		return runs[(#runs + 1) // 2]
	end

	-- ms a tick of `ticks` calls of `step`, after `setup()` (fresh each run), the median of `runs`.
	local function cost(setup: () -> () -> (), ticks: number, runs: number): number
		local times = {}
		for _ = 1, runs do
			local step = setup()
			local start = os.clock()
			for _ = 1, ticks do
				step()
			end
			table.insert(times, (os.clock() - start) / ticks * 1000)
		end
		return median(times)
	end

	-- A measurement: the median of 3 runs, and how to measure again (the median of 5).
	type Measure = { ms: number, again: () -> number }
	local function measured(setup: () -> () -> (), ticks: number): Measure
		return {
			ms = cost(setup, ticks, 3),
			again = function(): number
				return cost(setup, ticks, 5)
			end,
		}
	end

	-- What a measurement may come to: the budget and 15% for the machine's noise.
	local TOLERANCE = 1.15
	-- Without native code a native-only budget has no figure of its own: twice it, a sanity bound.
	local NOCODEGEN_SANITY = 2

	--[[
		Prints a measurement and holds it to `budget` (ms; `nativeOnly`: a native code budget):
		over it, it is measured again (the median of 5, the better of the two counting) before it
		fails, so a moment's load on a shared machine doesn't fail the suite.
	]]
	local function report(label: string, measure: Measure, budget: number, nativeOnly: boolean?)
		local enforced = NATIVE or not nativeOnly
		local limit = budget * (if enforced then TOLERANCE else NOCODEGEN_SANITY)
		local ms = measure.ms
		local again = ""
		if ms > limit then
			ms = math.min(ms, measure.again())
			again = ", measured again"
		end
		print(
			string.format(
				"         %s: %.3f ms (budget %.1f%s, %s%s)",
				label,
				ms,
				budget,
				if enforced then "" else " native only",
				if NATIVE then "native" else "NOCODEGEN",
				again
			)
		)
		t.ok(ms <= limit, `{label}: {ms} ms (at most {limit})`)
	end

	t.test("cost: 200 zombies chasing and idle; waves; a day's spawning round; a k = 3 moon's 144", function()
		local getBlock, _, skyOpen = flat()
		local function crowd(n: number, chasing: boolean): () -> ()
			local world = newWorld(getBlock, 3, 1000)
			local p = player("p", 0.5, FLOOR, 0.5, if chasing then GameMode.SURVIVAL else GameMode.CREATIVE)
			for i = 1, n do
				local kind = ZOMBIE + (i - 1) % (MobList.COUNT - ZOMBIE + 1)
				local angle = i * 2.399
				local distance = if chasing then 6 + (i % 25) else 6 + (i % 55)
				local id = world:spawn(kind, 0.5 + math.cos(angle) * distance, FLOOR, 0.5 + math.sin(angle) * distance)
				local mob = world:get(id) :: MobWorld.Mob
				if chasing then
					mob.ai.target, mob.ai.goal, mob.ai.visible = "p", "chase", true
				end
			end
			local ctx = context({ p }, skyOpen)
			run(world, ctx, 20)
			return function()
				world:tick(ctx)
				world:takeChanges()
			end
		end
		report(
			"200 zombies chasing",
			measured(function()
				return crowd(200, true)
			end, 200),
			if NATIVE then 3 else 8
		)
		report(
			"200 zombies idle",
			measured(function()
				return crowd(200, false)
			end, 200),
			if NATIVE then 1.5 else 4
		)
		--[[
			A blood moon's wave tick (k = 3: 12 zombies a player), for 1 and 4 players 120 blocks
			apart with 24 zombies hunting each already: the whole server tick a wave comes on (the
			mobs, natural spawning (paused), the director and its wave), the wave's zombies taken
			out after it, so every tick measured is a wave's.
		]]
		local waved = 0
		for _, count in { 1, 4 } do
			report(
				`a wave tick, {count} player{if count > 1 then "s" else ""}`,
				measured(function()
					local world = newWorld(getBlock, 5, 1000)
					local players = {}
					local hunters: { [number]: boolean } = {}
					for i = 1, count do
						local p = player(i, (i - 1) % 2 * 120 - 59.5, FLOOR, (i - 1) // 2 * 120 - 59.5)
						table.insert(players, p)
						for j = 1, 24 do
							local angle = j * 2.399
							local distance = 8 + j % 20
							local id = world:spawn(
								ZOMBIE + (j - 1) % (MobList.COUNT - ZOMBIE + 1),
								p.x + math.cos(angle) * distance,
								FLOOR,
								p.z + math.sin(angle) * distance
							)
							local mob = world:get(id) :: MobWorld.Mob
							mob.ai.hunt, mob.persistent = i, true
							hunters[id] = true
						end
					end
					local ctx = moonContext(players, skyOpen, MOON3)
					local state = ZombieDirector.new()
					local spawnState = MobSpawning.new()
					return function()
						state.waveTimer = 0
						world:tick(ctx)
						world:takeChanges()
						MobSpawning.step(world, spawnState, ctx, Config.Mobs)
						ZombieDirector.step(world, state, ctx, Config.Mobs, Apocalypse)
						waved += state.lastWave
						for _, mob in world:each() do
							if not hunters[mob.id] then
								world:remove(mob.id)
							end
						end
					end
				end, 50),
				4,
				true
			)
		end
		t.ok(waved > 0, `the waves came ({waved} zombies)`)
		-- A daytime spawning round (the monsters' 3 packs) for one player.
		local settings = table.clone(SETTINGS)
		settings.Attempts = Config.Mobs.Attempts
		local day = context({ player("p", 0.5, FLOOR, 0.5) }, skyOpen, NOON, { daySpawn = true })
		report(
			"a daytime spawning round",
			measured(function()
				local world = newWorld(getBlock, 5, 100000)
				local state = MobSpawning.new()
				return function()
					MobSpawning.step(world, state, day, settings)
					for _, mob in world:each() do
						world:remove(mob.id)
					end
				end
			end, 200),
			3,
			true
		)
		-- A k = 3 blood moon: 4 players 120 blocks apart, 36 zombies hunting each.
		report(
			"blood moon k = 3, 4 players, 144 zombies",
			measured(function()
				local world = newWorld(getBlock, 5, 1000)
				local players = {}
				for i = 1, 4 do
					local p = player(i, (i - 1) % 2 * 120 - 59.5, FLOOR, (i - 1) // 2 * 120 - 59.5)
					table.insert(players, p)
					for j = 1, 36 do
						local angle = j * 2.399
						local distance = 8 + j % 22
						local id = world:spawn(
							ZOMBIE + (j - 1) % (MobList.COUNT - ZOMBIE + 1),
							p.x + math.cos(angle) * distance,
							FLOOR,
							p.z + math.sin(angle) * distance
						)
						local mob = world:get(id) :: MobWorld.Mob
						mob.ai.hunt, mob.persistent = i, true
					end
				end
				local state = ZombieDirector.new()
				local spawnState = MobSpawning.new()
				local time = MOON3
				return function()
					time += 1
					local ctx = moonContext(players, skyOpen, time)
					world:tick(ctx)
					world:takeChanges()
					MobSpawning.step(world, spawnState, ctx, Config.Mobs)
					ZombieDirector.step(world, state, ctx, Config.Mobs, Apocalypse)
				end
			end, 200),
			5,
			true
		)
	end)

	--[[ 12. The glue: Mobs/Mobs against fakes ]]

	--[[
		Mobs/Mobs with fakes of Roblox (Players, RunService, Instance, Random) and the server modules
		it uses, on a flat world: `harness.tick(n)` runs n server ticks, `harness.join(x, y, z, mode)`
		adds a player.
	]]
	local function glue(getBlock, set, skyOpen)
		local h = {
			time = MIDNIGHT,
			raining = false,
			city = 0,
			sounds = {},
			drops = {},
			sent = {},
			players = {},
		}
		local heartbeat = fakeSignal()
		local playersService = {
			PlayerRemoving = fakeSignal(),
			PlayerAdded = fakeSignal(),
			GetPlayers = function(_self)
				return h.players
			end,
		}
		local services = {
			Players = playersService,
			ReplicatedStorage = shared.Parent,
			RunService = { Heartbeat = heartbeat },
			TextChatService = { ChatVersion = "TextChatService" },
		}
		local fakeGame = {
			GetService = function(_, name: string)
				return assert(services[name], `no fake {name}`)
			end,
		}
		local fakeEnum = { ChatVersion = { LegacyChatService = "LegacyChatService" } }
		local fakeInstance = {
			new = function(class: string): any
				if class == "BindableEvent" then
					local signal = fakeSignal()
					return {
						Event = signal,
						Fire = function(_, ...)
							signal.fire(...)
						end,
					}
				end
				assert(class == "TextChatCommand", `no fake {class}`)
				return { Triggered = fakeSignal(), SetAttribute = function() end }
			end,
		}
		local fakeRandom = {
			new = function()
				local roll = lcg(23)
				return {
					NextNumber = function(_)
						return roll()
					end,
				}
			end,
		}
		local function fakeTypeof(value: any): string
			if type(value) == "table" and rawget(value, "__player") then
				return "Instance"
			end
			return type(value)
		end
		local function stub(module: any): any
			return { __stub = module }
		end
		local root = {
			World = {
				WorldServer = stub({}),
				Simulation = stub({
					activeChunks = function()
						local chunks = {}
						for cx = -6, 6 do
							for cz = -6, 6 do
								table.insert(chunks, { cx = cx, cz = cz })
							end
						end
						return chunks
					end,
				}),
				Skylight = stub({
					open = function(_, x: number, y: number, z: number)
						return skyOpen(x, y, z)
					end,
					clear = function(_, x: number, y: number, z: number)
						return skyOpen(x, y, z)
					end,
				}),
				TimeOfDay = stub({
					get = function()
						return h.time
					end,
				}),
				WeatherServer = stub({
					rainingAt = function()
						return h.raining
					end,
					isDayAt = function(_x: number, _z: number, dayTime: number)
						return DayCycle.isDay(dayTime)
					end,
				}),
			},
			Audio = {
				Sounds = stub({
					play = function(sound: any, x: number, y: number, z: number)
						table.insert(h.sounds, { name = sound, x = x, y = y, z = z })
					end,
					playBlock = function(block: number, action: string, x: number, y: number, z: number)
						table.insert(h.sounds, { name = `{Blocks.get(block).name} {action}`, x = x, y = y, z = z })
					end,
					allow = function()
						return true
					end,
				}),
			},
			Entities = {
				Entities = stub({
					spawnItem = function(stack: any)
						table.insert(h.drops, stack)
					end,
				}),
			},
			Players = {
				Characters = stub({
					hurt = function(_player: any, amount: number)
						return amount, true
					end,
					knockbackShare = function()
						return 1
					end,
					knockedBack = function() end,
				}),
				Effects = stub({
					levels = function()
						return nil
					end,
				}),
				Operators = stub({
					permitted = function()
						return true
					end,
				}),
				Inventories = stub({
					heldTool = function()
						return nil
					end,
					accessories = function()
						return { attackSpeed = 0 }
					end,
					wearTool = function() end,
				}),
				PlayerPositions = stub({
					feet = function(p: any)
						return p.x, p.y, p.z
					end,
				}),
			},
			Apocalypse = { NoiseBus = server.Apocalypse.NoiseBus },
		}
		local folder = {
			Parent = root,
			MobWorld = server.Mobs.MobWorld,
			MobSpawning = server.Mobs.MobSpawning,
			MobTracking = server.Mobs.MobTracking,
			SummonCommand = server.Mobs.SummonCommand,
			ZombieDirector = server.Mobs.ZombieDirector,
		}
		local function glueRequire(node: any): any
			local module = if type(node) == "table" then rawget(node, "__stub") else nil
			if module then
				return module
			end
			return require(node)
		end
		local chunk = luau.load(
			withHeader(
				fs.readFile("src/server/Mobs/Mobs.luau"),
				"script, require, game, Instance, Random, Enum, typeof"
			),
			{ debugName = "Mobs" }
		)
		local Mobs = chunk({ Parent = folder }, glueRequire, fakeGame, fakeInstance, fakeRandom, fakeEnum, fakeTypeof)
		local fakeWorld = {
			generator = {
				cityAt = function()
					return h.city
				end,
			},
			peekBlock = function(_, x: number, y: number, z: number)
				return getBlock(x, y, z)
			end,
			setBlock = function(_, x: number, y: number, z: number, block: number)
				set(x, y, z, block)
				return true
			end,
		}
		local net = {
			send = function(to: any, kind: number, payload: buffer)
				table.insert(h.sent, { player = to, kind = kind, payload = payload })
			end,
			on = function() end,
		}
		NoiseBus.take()
		Mobs.start(net, fakeWorld)
		h.Mobs = Mobs
		function h.tick(n: number)
			for _ = 1, n do
				heartbeat.fire(1 / 20)
			end
		end
		function h.join(x: number, y: number, z: number, mode: string?): any
			local attributes = { [GameMode.ATTRIBUTE] = mode or GameMode.SURVIVAL }
			local fake = {
				__player = true,
				Name = `player{#h.players + 1}`,
				Parent = playersService,
				x = x,
				y = y,
				z = z,
				Character = {
					FindFirstChildOfClass = function()
						return { Health = 20 }
					end,
				},
				IsA = function(_, class: string)
					return class == "Player"
				end,
				GetAttribute = function(_, name: string)
					return attributes[name]
				end,
			}
			table.insert(h.players, fake)
			return fake
		end
		return h
	end

	t.test("zombies: the glue fires playerHit with the kind, removes both door halves, drops nothing", function()
		local getBlock, set, skyOpen = flat()
		local h = glue(getBlock, set, skyOpen)
		local Mobs = h.Mobs
		local hits = {}
		Mobs.playerHit:Connect(function(who: any, kind: string, damage: number, fresh: boolean, id: number)
			table.insert(hits, { player = who, kind = kind, damage = damage, fresh = fresh, id = id })
		end)
		local p = h.join(0.5, FLOOR, 0.5)
		local id = Mobs.spawn("zombie_brute", 2.5, FLOOR, 0.5)
		t.ok(id ~= 0, "summoned by its snake case name")
		h.tick(40)
		t.ok(#hits >= 1, "the brute's hit landed")
		t.eq(hits[1].player, p)
		t.eq(hits[1].kind, "ZombieBrute", "with the kind's name")
		t.eq(hits[1].damage, 7, "its 7")
		t.ok(hits[1].fresh, "a fresh hurt")
		t.eq(hits[1].id, id, "and the mob's id")
		-- A door between a zombie and the player: both halves go, the door's sounds, no drops.
		local getDoor, setDoor, doorSky = flat()
		wall(setDoor, "door")
		local d = glue(getDoor, setDoor, doorSky)
		d.join(0.5, FLOOR, 6.5)
		local zid = d.Mobs.spawn("Zombie", 0.5, FLOOR, 2.3)
		local mob = (d.Mobs.world() :: any):get(zid)
		mob.ai.target = d.players[1]
		mob.ai.goal = "chase"
		-- (Tick by tick, to catch the noise the break makes: heard on the next tick.)
		local heard: { NoiseBus.Noise }? = nil
		for _ = 1, 300 do
			d.tick(1)
			if heard == nil and getDoor(0, FLOOR, 3) == AIR then
				heard = NoiseBus.take()
			end
		end
		t.ok(heard ~= nil, "the door broke")
		local doorNoise = nil
		for _, made in heard or {} do
			if math.abs(made.x - 0.5) < 1e-9 and math.abs(made.z - 3.5) < 1e-9 then
				doorNoise = made
			end
		end
		t.ok(doorNoise ~= nil, "breaking it made a noise at the door")
		t.eq(doorNoise and doorNoise.radius, Apocalypse.Noise.Break, "of a block broken (10)")
		t.eq(getDoor(0, FLOOR, 3), AIR, "the lower half gone")
		t.eq(getDoor(0, FLOOR + 1, 3), AIR, "and the upper")
		t.eq(#d.drops, 0, "nothing dropped")
		local thuds, crash = 0, 0
		for _, cue in d.sounds do
			if cue.name == "entity.zombie.attack_wooden_door" then
				thuds += 1
			elseif cue.name == "entity.zombie.break_wooden_door" then
				crash += 1
			end
		end
		t.near(thuds, 240 / Apocalypse.Breaking.HitInterval, 1, `a thud every 20 ticks ({thuds})`)
		t.eq(crash, 1, "the door's crash once")
		-- Glass shatters with its own sounds.
		local getGlass, setGlass, glassSky = flat()
		wall(setGlass, B.Glass)
		local g = glue(getGlass, setGlass, glassSky)
		g.join(0.5, FLOOR, 6.5)
		local gid = g.Mobs.spawn("Zombie", 0.5, FLOOR, 2.3)
		local glassMob = (g.Mobs.world() :: any):get(gid)
		glassMob.ai.target, glassMob.ai.goal = g.players[1], "chase"
		g.tick(100)
		t.eq(getGlass(0, FLOOR, 3), AIR, "the glass broke")
		local hit, shatter = false, false
		for _, cue in g.sounds do
			hit = hit or cue.name == SharedSounds.id["block.glass.hit"]
			shatter = shatter or cue.name == "Glass break"
		end
		t.ok(hit, "glass hits sound like glass")
		t.ok(shatter, "and it breaks with its own sound")
	end)

	t.test("zombies: the glue's limits follow the day time; noises are louder at night; it replicates", function()
		local getBlock, set, skyOpen = flat()
		local h = glue(getBlock, set, skyOpen)
		h.join(0.5, FLOOR, 0.5, GameMode.CREATIVE)
		h.time = MOON1
		h.tick(1)
		local world = h.Mobs.world() :: any
		t.eq(world.options.maxMobs, 360, "a blood moon: 360")
		h.time = NOON
		h.tick(1)
		t.eq(world.options.maxMobs, 320, "/time set day: back to 320 at once")
		h.time = MOON1
		h.tick(1)
		t.eq(world.options.maxMobs, 360, "/time set into a moon: raised again")
		-- A zombie 11.5 blocks from a radius-10 noise hears it only at night (x 1.25).
		h.time = NOON
		local id = h.Mobs.spawn("Zombie", 11.5, FLOOR, 30.5)
		local mob = world:get(id)
		h.tick(1)
		NoiseBus.emit(0.5, FLOOR, 30.5, 10)
		h.tick(1)
		t.ok(mob.ai.goal ~= "investigate", "by day it doesn't hear it")
		h.time = MIDNIGHT
		NoiseBus.emit(0.5, FLOOR, 30.5, 10)
		h.tick(1)
		t.eq(mob.ai.goal, "investigate", "at night it does")
		-- What the player's client got: Mobs messages that decode, the zombie spawned and moving.
		local spawned, moved = false, false
		for _, message in h.sent do
			if message.kind == Protocol.ServerMessage.Mobs then
				local ops = Protocol.decodeMobs(message.payload, MobList.COUNT)
				t.ok(ops ~= nil, "a well formed message")
				for _, op in ops :: { any } do
					spawned = spawned or (op.op == "spawn" and op.id == id)
					moved = moved or (op.op == "move" and op.id == id)
				end
			end
		end
		t.ok(spawned, "the zombie spawned on the client")
		h.tick(20)
		for _, message in h.sent do
			for _, op in Protocol.decodeMobs(message.payload, MobList.COUNT) :: { any } do
				moved = moved or (op.op == "move" and op.id == id)
			end
		end
		t.ok(moved, "and its steps went as moves")
	end)

	t.test("zombies: the glue's spawning: by day 7 on open ground (12 in a city), in a moon only waves", function()
		-- The zombies in the glue's world (creatures spawn too, by their own rules).
		local function zombies(world: any): { MobWorld.Mob }
			local list = {}
			for _, mob in world:each() do
				if mob.kind.zombie then
					table.insert(list, mob)
				end
			end
			return list
		end
		-- The most zombies at once round a survival player by noon on open grass.
		local function noon(city: number): number
			local getBlock, set, skyOpen = flat()
			local h = glue(getBlock, set, skyOpen)
			h.time = NOON
			h.city = city
			h.join(0.5, FLOOR, 0.5)
			local most = 0
			for _ = 1, 30 do
				h.tick(20)
				most = math.max(most, #zombies(h.Mobs.world()))
			end
			return most
		end
		t.eq(noon(0), 7, "by day, zombies on the open ground up to the day cap of 7")
		t.eq(noon(1), 12, "in a city (cityAt 1) up to 12")
		-- A blood moon (k = 1): no natural spawning, the waves only: 8 at once, each hunting, and
		-- no more until the next wave 600 ticks on.
		local getBlock, set, skyOpen = flat()
		local h = glue(getBlock, set, skyOpen)
		h.time = MOON1
		local p = h.join(0.5, FLOOR, 0.5)
		local world = h.Mobs.world() :: any
		local counts = {}
		local strays = 0
		for tick = 1, 1300 do
			h.tick(1)
			local now = zombies(world)
			for _, mob in now do
				if mob.ai.hunt ~= p then
					strays += 1
				end
			end
			if tick == 1 or tick == 590 or tick == 1300 then
				counts[tick] = #now
			end
		end
		t.eq(strays, 0, "every zombie a wave's, hunting the player")
		t.eq(counts[1], 8, "a wave of 8 at once")
		t.eq(counts[590], 8, "nothing more between waves")
		t.eq(counts[1300], 24, "three waves by 1300 ticks")
	end)
end

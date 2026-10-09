--[[
	Mobs: the kinds (Shared/Entities/MobList), their movement (Shared/Entities/MobPhysics: falls,
	collisions, stepping up by jumping, never off a cliff), what they do (server Mobs/MobAI: wander,
	panic, targets, melee, a creeper's fuse, a skeleton's bow, daylight), what happens to them
	(Mobs/MobWorld: hurts and their cooldown, knockback, death and loot, blasts, despawning,
	players' attacks: reach, sight, game modes, attack strength), natural spawning
	(Mobs/MobSpawning: light, ground, caps, distances, never in chunks that don't tick), the light
	estimate it uses (Shared/World/LightEstimate), /summon and /kill (Mobs/SummonCommand), the
	Mobs, Attack and Eat messages, food (Shared/Items/Foods) and what ticking costs.
]]

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Coords = require(shared.World.Coords)
	local GameMode = require(shared.GameMode)
	local MobList = require(shared.Entities.MobList)
	local MobPhysics = require(shared.Entities.MobPhysics)
	local Combat = require(shared.Entities.Combat)
	local LightEstimate = require(shared.World.LightEstimate)
	local Foods = require(shared.Items.Foods)
	local Protocol = require(shared.Net.Protocol)
	local Crafting = require(shared.Crafting)
	local Smelting = require(shared.Crafting.Smelting)
	local MobWorld = require(server.Mobs.MobWorld)
	local MobAI = require(server.Mobs.MobAI)
	local MobSpawning = require(server.Mobs.MobSpawning)
	local SummonCommand = require(server.Mobs.SummonCommand)
	local Skylight = require(server.World.Skylight)

	local B, I = Blocks.id, Items.id
	local AIR, STONE, GRASS = Blocks.AIR, B.Stone, B.Grass
	local FLOOR = 20
	local TOP = 64
	local NOON, MIDNIGHT = 6000, 18000

	local function kindId(name: string): number
		return MobList.find(name) :: number
	end
	local COW, SHEEP, PIG, CHICKEN = kindId("Cow"), kindId("Sheep"), kindId("Pig"), kindId("Chicken")
	local ZOMBIE, SKELETON, CREEPER, SPIDER = kindId("Zombie"), kindId("Skeleton"), kindId("Creeper"), kindId("Spider")

	-- A deterministic random in [0, 1) (a small LCG).
	local function lcg(seed: number): () -> number
		local state = seed
		return function(): number
			state = (state * 1103515245 + 12345) % 2147483648
			return state / 2147483648
		end
	end

	--[[
		A flat world: grass at FLOOR - 1 over stone, air above (`blocks` overrides cells by
		Coords.posKey), loaded within `radius` blocks of the origin (else nil, not loaded).
	]]
	local function flat(blocks: { [number]: number }?, radius: number?)
		local cells = blocks or {}
		local limit = radius or 200
		local function getBlock(x: number, y: number, z: number): number?
			if math.abs(x) > limit or math.abs(z) > limit or y < 0 then
				return nil
			end
			local block = cells[Coords.posKey(x, y, z)]
			if block ~= nil then
				return block
			end
			if y < FLOOR - 1 then
				return STONE
			elseif y == FLOOR - 1 then
				return GRASS
			end
			return AIR
		end
		local function set(x: number, y: number, z: number, block: number)
			cells[Coords.posKey(x, y, z)] = block
		end
		-- (World/Skylight.open: nothing opaque above the cell up to TOP.)
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
		-- (World/Skylight.clear itself, on the flat world: leaves and fluids shade too.)
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

	local function newWorld(getBlock, seed: number?, maxMobs: number?)
		return MobWorld.new(getBlock, { maxMobs = maxMobs or 300, forgetTicks = 6000, random = lcg(seed or 7) })
	end

	local function player(key: any, x: number, y: number, z: number, mode: string?): MobWorld.PlayerView
		return { key = key, x = x, y = y, z = z, eye = 1.62, mode = mode or GameMode.SURVIVAL, alive = true }
	end

	-- (`skyClear`, the sun's test: the open sky unless a test needs the leaves' shade.)
	local function context(
		players: { MobWorld.PlayerView },
		skyOpen,
		dayTime: number?,
		skyClear: any?
	): MobWorld.Context
		return {
			players = players,
			dayTime = dayTime or MIDNIGHT,
			skyOpen = skyOpen,
			skyClear = skyClear or skyOpen,
			active = function()
				return true
			end,
		}
	end

	local function run(world, ctx, ticks: number)
		for _ = 1, ticks do
			world:tick(ctx)
		end
	end

	--[[ The kinds ]]

	t.test("mobs: Minecraft's eight kinds, their boxes, health and drops", function()
		t.eq(MobList.COUNT, 8, "cow, sheep, pig, chicken, zombie, skeleton, creeper, spider")
		local expect = {
			{ "Cow", 0.9, 1.4, 10, false },
			{ "Sheep", 0.9, 1.3, 8, false },
			{ "Pig", 0.9, 0.9, 10, false },
			{ "Chicken", 0.4, 0.7, 4, false },
			{ "Zombie", 0.6, 1.95, 20, true },
			{ "Skeleton", 0.6, 1.99, 20, true },
			{ "Creeper", 0.6, 1.7, 20, true },
			{ "Spider", 1.4, 0.9, 16, true },
		}
		for id, row in expect do
			local kind = MobList.get(id) :: MobList.Kind
			t.eq(kind.name, row[1], `kind {id}`)
			t.eq(kind.width, row[2], `{row[1]} width`)
			t.eq(kind.height, row[3], `{row[1]} height`)
			t.eq(kind.health, row[4], `{row[1]} health`)
			t.eq(kind.hostile, row[5], `{row[1]} category`)
			t.ok(kind.eye < kind.height, `{row[1]} eyes in its box`)
			t.ok(#kind.parts <= MobList.MAX_PARTS, `{row[1]} parts`)
		end
		t.eq(MobList.find("zombie"), ZOMBIE, "any case")
		t.eq(MobList.find("minecraft:creeper"), CREEPER, "Minecraft's namespace")
		t.eq(MobList.find("wither"), nil, "unknown")
		local zombie = MobList.get(ZOMBIE) :: MobList.Kind
		t.eq(zombie.attack, 3, "a zombie hits 3")
		t.eq(zombie.armor, 2, "and has 2 armor")
		t.ok(zombie.burnsInDaylight and (MobList.get(SKELETON) :: MobList.Kind).burnsInDaylight, "the undead burn")
		t.eq((MobList.get(SPIDER) :: MobList.Kind).attack, 2, "a spider hits 2")
		t.eq(((MobList.get(CREEPER) :: MobList.Kind).fuse :: MobList.Fuse).ticks, 30, "a creeper's 30 tick fuse")
		t.eq(((MobList.get(CREEPER) :: MobList.Kind).fuse :: MobList.Fuse).power, 3, "of power 3")
		-- Drops resolve to items.
		local cow = MobList.get(COW) :: MobList.Kind
		t.eq(cow.kindDrops[1].item, I.Leather)
		t.eq(cow.kindDrops[2].item, I.RawBeef)
		t.eq((MobList.get(SHEEP) :: MobList.Kind).kindDrops[1].item, B.WhiteWool, "sheep drop wool")
		t.eq((MobList.get(CREEPER) :: MobList.Kind).kindDrops[1].item, I.Gunpowder, "creepers gunpowder")
		-- Sheep colours by Minecraft's odds: mostly white.
		local sheep = MobList.get(SHEEP) :: MobList.Kind
		local random = lcg(3)
		local white = 0
		for _ = 1, 2000 do
			if MobList.randomVariant(sheep, random) == 1 then
				white += 1
			end
		end
		t.ok(white > 1500 and white < 1780, `about 82% white sheep ({white} of 2000)`)
		t.eq(MobList.randomVariant(cow, random), 1, "kinds without variants")
	end)

	t.test("mobs: drops cook, leather armor and wool are crafted, wool burns", function()
		t.eq(Foods.COOKED[I.RawBeef], I.CookedBeef)
		t.eq(Items.get(I.CookedBeef).displayName, "Steak")
		local function smelts(input: number): number?
			local result = Smelting.result(input)
			return if result then result.item else nil
		end
		t.eq(smelts(I.RawBeef), I.CookedBeef, "beef cooks")
		t.eq(smelts(I.RawMutton), I.CookedMutton, "mutton cooks")
		t.eq(smelts(I.RawPorkchop), I.CookedPorkchop, "porkchop cooks")
		t.eq(smelts(I.RawChicken), I.CookedChicken, "chicken cooks")
		local function craft(cells: { [number]: number }): number?
			local grid = {}
			for slot, item in cells do
				grid[slot] = { item = item, count = 1 }
			end
			local made = Crafting.match(grid, 3)
			return if made then made.item else nil
		end
		local L = I.Leather
		t.eq(craft({ [1] = L, [2] = L, [3] = L, [4] = L, [6] = L }), I.LeatherHelmet, "a leather helmet")
		t.eq(craft({ [1] = L, [3] = L, [4] = L, [6] = L }), I.LeatherBoots, "leather boots")
		local S = I.String
		t.eq(craft({ [1] = S, [2] = S, [4] = S, [5] = S }), B.WhiteWool, "four string make wool")
		t.ok(Blocks.isFlammable(B.WhiteWool), "wool burns")
		t.eq(Blocks.get(B.WhiteWool).hardness, 0.8)
		t.eq(Smelting.fuel(B.WhiteWool), 100, "and is fuel")
	end)

	--[[ Movement ]]

	t.test("mob physics: falls, lands, takes fall damage (chickens don't), collides", function()
		local getBlock, set, skyOpen = flat()
		local world = newWorld(getBlock)
		local zombie = world:spawn(ZOMBIE, 0.5, FLOOR + 10, 0.5)
		local chicken = world:spawn(CHICKEN, 5.5, FLOOR + 10, 0.5)
		local ctx = context({}, skyOpen, MIDNIGHT)
		run(world, ctx, 60)
		local z = world:get(zombie) :: MobWorld.Mob
		local c = world:get(chicken) :: MobWorld.Mob
		t.near(z.body.y, FLOOR, 1e-6, "the zombie landed on the ground")
		t.ok(z.body.onGround, "and stands")
		t.eq(z.health, 20 - math.ceil(10 - 3) + 0, "ceil(10 - 3) of fall damage, through no armor")
		t.eq(c.health, 4, "a chicken takes none")
		-- A chicken falls slowly.
		local world2 = newWorld(getBlock)
		local slow = world2:spawn(CHICKEN, 0.5, FLOOR + 10, 0.5)
		local fast = world2:spawn(PIG, 3.5, FLOOR + 10, 0.5)
		run(world2, ctx, 12)
		t.ok(
			(world2:get(slow) :: MobWorld.Mob).body.y > (world2:get(fast) :: MobWorld.Mob).body.y + 3,
			"chickens flap down slowly"
		)
		-- Walls stop a mob.
		local body = MobPhysics.new(0.5, FLOOR, 0.5, 0)
		for y = FLOOR, FLOOR + 3 do
			set(-1, y, 3, STONE)
			set(0, y, 3, STONE)
			set(1, y, 3, STONE)
		end
		local zombieKind = MobList.get(ZOMBIE) :: MobList.Kind
		for _ = 1, 40 do
			MobPhysics.tick(body, zombieKind, 0.23 * 0.98, false, getBlock)
		end
		t.near(body.z, 3 - 0.3, 1e-6, "it walks up to the wall (yaw 0: +Z) and stops")
		t.ok(body.horizontalCollision, "against it")
		-- Walking speed: Minecraft's 2.3 blocks a second for a zombie.
		local walker = MobPhysics.new(0.5, FLOOR, 0.5, math.pi / 2)
		walker.onGround = true
		for _ = 1, 40 do
			MobPhysics.tick(walker, zombieKind, 0.23 * 0.98, false, getBlock)
		end
		local x0 = walker.x
		for _ = 1, 20 do
			MobPhysics.tick(walker, zombieKind, 0.23 * 0.98, false, getBlock)
		end
		t.near(walker.x - x0, 2.28, 0.05, "a zombie walks 2.3 blocks a second")
	end)

	t.test("mob physics: steps up a block by jumping, never walks off a cliff, swims up", function()
		local getBlock, set, skyOpen = flat()
		-- A one block step at z = 3, and a 6 deep pit from x = 10.
		for x = -2, 2 do
			for z = 3, 8 do
				set(x, FLOOR, z, STONE)
			end
		end
		local world = newWorld(getBlock)
		local cow = world:spawn(COW, 0.5, FLOOR, 0.5, nil, 0)
		local mob = world:get(cow) :: MobWorld.Mob
		mob.ai.goal = "wander"
		mob.ai.tx, mob.ai.tz, mob.ai.timer = 0.5, 6.5, 200
		local ctx = context({}, skyOpen, NOON)
		run(world, ctx, 120)
		t.near(mob.body.y, FLOOR + 1, 1e-6, "it jumped up the step")
		t.ok(mob.body.z > 4, `and walked on ({mob.body.z})`)
		-- A cliff: 6 deep.
		for x = 10, 20 do
			for z = -5, 5 do
				for y = FLOOR - 6, FLOOR - 1 do
					set(x, y, z, AIR)
				end
			end
		end
		local pig = world:spawn(PIG, 8.5, FLOOR, 0.5, nil, math.pi / 2)
		local edge = world:get(pig) :: MobWorld.Mob
		edge.ai.goal = "wander"
		edge.ai.tx, edge.ai.tz, edge.ai.timer = 15.5, 0.5, 200
		run(world, ctx, 100)
		t.eq(edge.body.y, FLOOR, "the pig won't walk off a 6 block drop")
		t.ok(edge.body.x < 10, `and stays on the edge ({edge.body.x})`)
		-- A 2 block drop is fine.
		for x = 10, 20 do
			for z = -5, 5 do
				for y = FLOOR - 6, FLOOR - 3 do
					set(x, y, z, STONE)
				end
			end
		end
		edge.ai.goal = "wander"
		edge.ai.tx, edge.ai.tz, edge.ai.timer = 15.5, 0.5, 200
		run(world, ctx, 100)
		t.near(edge.body.y, FLOOR - 2, 1e-6, "but goes down 2")
		t.eq(edge.health, 10, "unhurt")
		-- Water: a mob in a pool swims up to the surface.
		for x = 30, 34 do
			for z = 0, 4 do
				for y = FLOOR - 5, FLOOR - 1 do
					set(x, y, z, B.Water)
				end
			end
		end
		local swimmer = world:spawn(SHEEP, 32.5, FLOOR - 5, 2.5)
		run(world, ctx, 80)
		local wet = world:get(swimmer) :: MobWorld.Mob
		t.ok(wet.body.y > FLOOR - 2, `it swam up ({wet.body.y})`)
	end)

	t.test("mob AI: lava, fire and fuel are avoided", function()
		local getBlock, set, skyOpen = flat()
		for x = 4, 6 do
			for z = -2, 2 do
				set(x, FLOOR - 1, z, B.Lava)
			end
		end
		set(0, FLOOR, 4, B.Fire)
		local world = newWorld(getBlock)
		local id = world:spawn(COW, 0.5, FLOOR, 0.5)
		local mob = world:get(id) :: MobWorld.Mob
		local ctx = context({}, skyOpen, NOON)
		for _ = 1, 4 do
			mob.ai.goal = "wander"
			mob.ai.tx, mob.ai.tz, mob.ai.timer = 10.5, 0.5, 100
			run(world, ctx, 100)
		end
		t.ok(mob.body.x < 4, `the cow stops before lava ({mob.body.x})`)
		t.eq(mob.health, 10, "unhurt")
		t.ok(MobAI.hazard(B.Fire) and MobAI.hazard(B.Lava) and MobAI.hazard(B.Fuel) and MobAI.hazard(B.Oil), "hazards")
		t.ok(not MobAI.hazard(B.Water) and not MobAI.hazard(AIR), "water and air are fine")
	end)

	--[[ What monsters do ]]

	t.test("mob AI: monsters hunt the nearest survival player they see within 16 blocks", function()
		local getBlock, set, skyOpen = flat()
		local world = newWorld(getBlock)
		local id = world:spawn(ZOMBIE, 0.5, FLOOR, 0.5)
		local mob = world:get(id) :: MobWorld.Mob
		local near = player("near", 6.5, FLOOR, 0.5)
		local far = player("far", -10.5, FLOOR, 0.5)
		local ctx = context({ far, near }, skyOpen)
		run(world, ctx, 10)
		t.eq(mob.ai.target, "near", "the nearest")
		-- Creative and spectator players are never hunted.
		local world2 = newWorld(getBlock)
		local id2 = world2:spawn(ZOMBIE, 0.5, FLOOR, 0.5)
		run(
			world2,
			context(
				{ player("c", 4.5, FLOOR, 0.5, GameMode.CREATIVE), player("s", 3.5, FLOOR, 0.5, GameMode.SPECTATOR) },
				skyOpen
			),
			20
		)
		t.eq((world2:get(id2) :: MobWorld.Mob).ai.target, nil, "not in creative or spectator")
		run(world2, context({ player("a", 4.5, FLOOR, 0.5, GameMode.ADVENTURE) }, skyOpen), 10)
		t.eq((world2:get(id2) :: MobWorld.Mob).ai.target, "a", "adventure players are")
		-- Too far, or behind a wall.
		local world3 = newWorld(getBlock)
		local id3 = world3:spawn(ZOMBIE, 0.5, FLOOR, 0.5)
		run(world3, context({ player("p", 17.5, FLOOR, 0.5) }, skyOpen), 20)
		t.eq((world3:get(id3) :: MobWorld.Mob).ai.target, nil, "17 blocks away: no")
		for y = FLOOR, FLOOR + 4 do
			for z = -3, 3 do
				set(3, y, z, STONE)
			end
		end
		run(world3, context({ player("p", 6.5, FLOOR, 0.5) }, skyOpen), 20)
		t.eq((world3:get(id3) :: MobWorld.Mob).ai.target, nil, "behind a wall: no")
	end)

	t.test("mob AI: zombies close in and hit every 20 ticks with a 0.4 knockback", function()
		local getBlock, _, skyOpen = flat()
		local world = newWorld(getBlock)
		local id = world:spawn(ZOMBIE, 0.5, FLOOR, 0.5)
		local target = player("p", 8.5, FLOOR, 0.5)
		local ctx = context({ target }, skyOpen)
		local hits = {}
		for _ = 1, 140 do
			world:tick(ctx)
			for _, hit in world:takeChanges().hits do
				table.insert(hits, hit)
			end
		end
		local mob = world:get(id) :: MobWorld.Mob
		t.ok(mob.body.x > 6, `it walked up to the player ({mob.body.x})`)
		t.ok(#hits >= 3 and #hits <= 6, `hits every 20 ticks ({#hits} in 140)`)
		local hit = hits[1]
		t.eq(hit.key, "p")
		t.eq(hit.damage, 3, "a zombie's 3")
		t.near(math.sqrt(hit.kx * hit.kx + hit.kz * hit.kz), 0.4, 1e-6, "knocked back 0.4")
		t.ok(hit.kx > 0, "away from the zombie")
		-- Reach: Minecraft's sqrt((2 x 0.6)^2 + 0.6) = 1.43 blocks between them.
		local dx = target.x - mob.body.x
		t.ok(dx <= 1.43 + 0.3, `in reach when hitting ({dx})`)
	end)

	t.test("mob AI: a creeper hisses within 3 blocks and explodes 30 ticks later, unless left", function()
		local getBlock, _, skyOpen = flat()
		local world = newWorld(getBlock)
		local id = world:spawn(CREEPER, 0.5, FLOOR, 0.5)
		local target = player("p", 2.5, FLOOR, 0.5)
		local ctx = context({ target }, skyOpen)
		local explosions, sounds = {}, {}
		local ticks = 0
		while #explosions == 0 and ticks < 100 do
			world:tick(ctx)
			ticks += 1
			local changes = world:takeChanges()
			for _, blast in changes.explosions do
				table.insert(explosions, blast)
			end
			for _, cue in changes.sounds do
				table.insert(sounds, cue.name)
			end
		end
		t.eq(#explosions, 1, "it went off")
		t.eq(explosions[1].power, 3, "with power 3")
		t.ok(ticks >= 30 and ticks <= 45, `about 30 ticks after noticing the player ({ticks})`)
		t.ok(table.find(sounds, "entity.creeper.primed") ~= nil, "after hissing")
		t.eq(world:get(id), nil, "and is gone")
		-- Getting away cancels it.
		local world2 = newWorld(getBlock)
		local id2 = world2:spawn(CREEPER, 0.5, FLOOR, 0.5)
		local runner = player("p", 2.5, FLOOR, 0.5)
		local ctx2 = context({ runner }, skyOpen)
		run(world2, ctx2, 20)
		local creeper = world2:get(id2) :: MobWorld.Mob
		t.ok(creeper.ai.swell > 0, `the fuse burns ({creeper.ai.swell})`)
		runner.x = 12.5
		run(world2, ctx2, 3)
		local swell = creeper.ai.swell
		run(world2, ctx2, 5)
		t.ok(creeper.ai.swell < swell, "and cools once the player is 7 blocks away")
		local blasts = 0
		for _ = 1, 60 do
			world2:tick(ctx2)
			blasts += #world2:takeChanges().explosions
			runner.x = creeper.body.x + 12
		end
		t.eq(blasts, 0, "no blast while the player keeps away")
	end)

	t.test("mob AI: skeletons shoot every 60 ticks within 15 blocks", function()
		local getBlock, _, skyOpen = flat()
		local world = newWorld(getBlock, 11)
		world:spawn(SKELETON, 0.5, FLOOR, 0.5)
		local ctx = context({ player("p", 8.5, FLOOR, 0.5) }, skyOpen)
		local arrows, hits = 0, 0
		for _ = 1, 400 do
			world:tick(ctx)
			local changes = world:takeChanges()
			arrows += #changes.arrows
			hits += #changes.hits
			for _, hit in changes.hits do
				t.ok(hit.damage >= 3 and hit.damage <= 5, "3-5 an arrow")
			end
		end
		t.ok(arrows >= 5 and arrows <= 8, `a shot every 3 s ({arrows} in 20 s)`)
		t.ok(hits >= 2, `most hit at 8 blocks ({hits} of {arrows})`)
	end)

	t.test("mob AI: spiders hunt in the dark, not by day; creatures panic when hurt", function()
		local getBlock, _, skyOpen = flat()
		local world = newWorld(getBlock)
		local id = world:spawn(SPIDER, 0.5, FLOOR, 0.5)
		run(world, context({ player("p", 6.5, FLOOR, 0.5) }, skyOpen, NOON), 20)
		t.eq((world:get(id) :: MobWorld.Mob).ai.target, nil, "neutral in daylight")
		run(world, context({ player("p", 6.5, FLOOR, 0.5) }, skyOpen, MIDNIGHT), 20)
		t.eq((world:get(id) :: MobWorld.Mob).ai.target, "p", "hunts at night")
		-- Hurt by day, it hits back.
		local world2 = newWorld(getBlock)
		local id2 = world2:spawn(SPIDER, 0.5, FLOOR, 0.5)
		world2:hurt(id2, 1, { player = "p", x = 6.5, z = 0.5 })
		run(world2, context({ player("p", 6.5, FLOOR, 0.5) }, skyOpen, NOON), 2)
		t.eq((world2:get(id2) :: MobWorld.Mob).ai.target, "p", "revenge")
		-- A cow runs from whoever hurt it.
		local cow = world2:spawn(COW, 20.5, FLOOR, 0.5)
		world2:hurt(cow, 1, { player = "p", x = 18.5, z = 0.5, knockback = 0.4 })
		local mob = world2:get(cow) :: MobWorld.Mob
		t.eq(mob.ai.goal, "panic", "it panics")
		t.ok(mob.ai.tx > 20.5, "away from the attacker")
		run(world2, context({}, skyOpen, NOON), 40)
		t.ok(mob.body.x > 22, `and runs ({mob.body.x})`)
	end)

	t.test("mobs: zombies and skeletons burn in daylight under the open sky", function()
		local getBlock, set, skyOpen, skyClear = flat()
		local world = newWorld(getBlock)
		local open = world:spawn(ZOMBIE, 0.5, FLOOR, 0.5)
		local roofed = world:spawn(SKELETON, 20.5, FLOOR, 0.5)
		for x = 18, 23 do
			for z = -3, 3 do
				set(x, FLOOR + 3, z, STONE)
			end
		end
		-- Under a tree's leaves (Level.canSeeSky: sky light 14 there) and under glass (15).
		local shaded = world:spawn(ZOMBIE, 40.5, FLOOR, 0.5)
		local glazed = world:spawn(ZOMBIE, 60.5, FLOOR, 0.5)
		for x = 38, 43 do
			for z = -3, 3 do
				set(x, FLOOR + 4, z, B.OakLeaves)
				set(x + 20, FLOOR + 4, z, B.Glass)
			end
		end
		local cow = world:spawn(COW, -20.5, FLOOR, 0.5)
		local ctx = context({}, skyOpen, NOON, skyClear)
		local home = { [open] = 0.5, [roofed] = 20.5, [shaded] = 40.5, [glazed] = 60.5, [cow] = -20.5 }
		-- (Keep them in place.)
		for _ = 1, 100 do
			for id, x in home do
				local mob = world:get(id)
				if mob then
					mob.ai.goal = "idle"
					mob.body.x = x
				end
			end
			world:tick(ctx)
		end
		local zombie = world:get(open) :: MobWorld.Mob
		t.ok(zombie.health < 20, `the zombie in the sun burns ({zombie.health})`)
		t.eq((world:get(roofed) :: MobWorld.Mob).health, 20, "the skeleton under a roof doesn't")
		t.eq((world:get(shaded) :: MobWorld.Mob).health, 20, "nor a zombie in a tree's shade")
		t.ok((world:get(glazed) :: MobWorld.Mob).health < 20, "glass doesn't shade")
		t.eq((world:get(cow) :: MobWorld.Mob).health, 10, "nor does a cow")
		-- Not at night.
		local night = newWorld(getBlock)
		local id = night:spawn(ZOMBIE, 0.5, FLOOR, 0.5)
		run(night, context({}, skyOpen, MIDNIGHT), 100)
		t.eq((night:get(id) :: MobWorld.Mob).health, 20, "not at night")
	end)

	--[[ Hurts, death and loot ]]

	t.test("mobs: hurts land through the 10 tick cooldown, knock back and flash", function()
		local getBlock, _, skyOpen = flat()
		local world = newWorld(getBlock)
		local id = world:spawn(PIG, 0.5, FLOOR, 0.5)
		local ctx = context({}, skyOpen, NOON)
		run(world, ctx, 5)
		local mob = world:get(id) :: MobWorld.Mob
		t.eq(world:hurt(id, 3, { player = "p", x = -2, z = 0.5, knockback = 0.4 }), 3, "a hit lands")
		t.eq(mob.health, 7)
		t.eq(mob.hurtTime, MobWorld.HURT_TIME, "it flashes red")
		t.ok(mob.body.vx > 0.3 and mob.body.vy > 0, "and is knocked away and up")
		t.eq(world:hurt(id, 2, { player = "p" }), 0, "a smaller hit within 10 ticks doesn't land")
		t.eq(world:hurt(id, 5, { player = "p" }), 2, "a bigger one only by the difference")
		t.eq(mob.health, 5)
		run(world, ctx, 10)
		t.eq(world:hurt(id, 2, { player = "p" }), 2, "after 10 ticks it lands again")
		-- Armor: a zombie's 2 points soften a hit, falls bypass it.
		local zid = world:spawn(ZOMBIE, 10.5, FLOOR, 0.5)
		t.near(world:hurt(zid, 10, {}), Items.damageAfterArmor(10, 2, 0), 1e-9, "armor softens")
		-- A magic projectile keeps its own immunity (Mobs.magicDamage): a Wand of Sparking's
		-- 9 tick casts on one mob all land, and each starts the cooldown for the rest.
		local target = world:spawn(PIG, 20.5, FLOOR, 0.5)
		local pig = world:get(target) :: MobWorld.Mob
		pig.health = 1000
		local landed = 0
		for cast = 1, 20 do
			if world:hurt(target, 3, { player = "p", ownImmunity = true }) > 0 then
				landed += 1
			end
			if cast == 1 then
				t.eq(world:hurt(target, 2, { player = "p" }), 0, "a melee hit right after: the cooldown")
			end
			run(world, ctx, 9)
		end
		t.eq(landed, 20, "every cast lands")
	end)

	t.test("mobs: death, the killer and the loot 20 ticks later (cooked when burning)", function()
		local getBlock, _, skyOpen = flat()
		local world = newWorld(getBlock, 5)
		local id = world:spawn(COW, 0.5, FLOOR, 0.5)
		local ctx = context({}, skyOpen, NOON)
		world:hurt(id, 4, { player = "steve", x = 0, z = 0 })
		run(world, ctx, 11)
		world:hurt(id, 6, {})
		local changes = world:takeChanges()
		t.eq(#changes.deaths, 1, "it died")
		t.eq(changes.deaths[1].kind, "Cow")
		t.eq(changes.deaths[1].killer, "steve", "the last player to hit it within 100 ticks gets the kill")
		t.ok(table.find(
			(function()
				local names = {}
				for _, cue in changes.sounds do
					table.insert(names, cue.name)
				end
				return names
			end)(),
			"entity.cow.death"
		) ~= nil, "its death sound")
		local mob = world:get(id) :: MobWorld.Mob
		t.ok(mob.dead, "it lies dying")
		t.eq(world:hurt(id, 5, {}), 0, "the dead take no hurts")
		run(world, ctx, 19)
		t.ok(world:get(id) ~= nil, "for 20 ticks")
		run(world, ctx, 1)
		t.eq(world:get(id), nil, "then it is gone")
		local drops = world:takeChanges().drops
		local beef, leather = 0, 0
		for _, drop in drops do
			if drop.item == I.RawBeef then
				beef += drop.count
			elseif drop.item == I.Leather then
				leather += drop.count
			end
		end
		t.ok(beef >= 1 and beef <= 3, `1-3 beef ({beef})`)
		t.ok(leather <= 2, `0-2 leather ({leather})`)
		-- Burning: cooked.
		local cooked = 0
		for seed = 1, 10 do
			local w = newWorld(getBlock, seed)
			local c = w:spawn(COW, 0.5, FLOOR, 0.5)
			local m = w:get(c) :: MobWorld.Mob
			m.burn.fire = 100
			w:hurt(c, 100, {})
			run(w, ctx, 20)
			for _, drop in w:takeChanges().drops do
				t.ok(drop.item ~= I.RawBeef, "no raw beef from a burning cow")
				if drop.item == I.CookedBeef then
					cooked += drop.count
				end
			end
		end
		t.ok(cooked >= 10, "steak instead")
		-- Zombies' iron only when a player killed them.
		local iron = 0
		for seed = 1, 400 do
			local w = newWorld(getBlock, seed)
			local z = w:spawn(ZOMBIE, 0.5, FLOOR, 0.5)
			w:hurt(z, 100, {})
			run(w, ctx, 20)
			for _, drop in w:takeChanges().drops do
				if drop.item == I.IronIngot then
					iron += 1
				end
			end
		end
		t.eq(iron, 0, "no iron without a player's kill")
		-- /kill: a death without a killer.
		local w = newWorld(getBlock)
		local s = w:spawn(SHEEP, 0.5, FLOOR, 0.5)
		t.ok(w:kill(s), "killed")
		t.eq(w:takeChanges().deaths[1].killer, nil)
	end)

	t.test("mobs: blasts hurt and push them, a creeper's too", function()
		local getBlock, _, skyOpen = flat()
		local world = newWorld(getBlock)
		local near = world:spawn(ZOMBIE, 2.5, FLOOR, 0.5)
		local far = world:spawn(ZOMBIE, 30.5, FLOOR, 0.5)
		local killed = world:explode(0.5, FLOOR, 0.5, 4)
		local mob = world:get(near) :: MobWorld.Mob
		t.ok(mob.dead or mob.health < 20, "the near one is hurt")
		t.ok(mob.body.vx > 0, "and pushed away")
		t.eq((world:get(far) :: MobWorld.Mob).health, 20, "the far one isn't")
		t.ok(killed >= 0)
		local chickens = 0
		for i = 1, 5 do
			world:spawn(CHICKEN, i - 0.5, FLOOR, 2.5)
			chickens += 1
		end
		t.ok(world:explode(2.5, FLOOR, 2.5, 4) >= 4, "chickens next to TNT die")
		run(world, context({}, skyOpen), 1)
	end)

	--[[ Despawning ]]

	t.test("mobs: monsters despawn far from players, creatures are forgotten after a while", function()
		local getBlock, _, skyOpen = flat(nil, 400)
		local world = newWorld(getBlock)
		local far = world:spawn(ZOMBIE, 150.5, FLOOR, 0.5)
		local near = world:spawn(ZOMBIE, 10.5, FLOOR, 0.5)
		local cow = world:spawn(COW, 150.5, FLOOR, 10.5)
		local ctx = context({ player("p", 0.5, FLOOR, 0.5, GameMode.CREATIVE) }, skyOpen)
		run(world, ctx, 20)
		t.eq(world:get(far), nil, "a monster 150 blocks away goes")
		t.ok(world:get(near) ~= nil, "one 10 blocks away stays")
		t.ok(world:get(cow) ~= nil, "a cow stays")
		-- (Its chunk frozen, as one 150 blocks from every player is.)
		local away = {
			players = ctx.players,
			dayTime = ctx.dayTime,
			skyOpen = skyOpen,
			active = function(cx: number)
				return cx < 5
			end,
		}
		run(world, away, 5900)
		t.ok(world:get(cow) ~= nil, "still there after 4.9 minutes")
		run(world, away, 100)
		t.eq(world:get(cow), nil, "gone once nobody came near it for 5 minutes")
		-- Nobody in the world: nothing goes.
		local empty = newWorld(getBlock)
		local alone = empty:spawn(ZOMBIE, 300.5, FLOOR, 0.5)
		run(empty, context({}, skyOpen), 40)
		t.ok(empty:get(alone) ~= nil, "nothing despawns without players")
		-- Monsters 32-128 blocks away go at random after 30 s of nothing happening.
		local world2 = newWorld(getBlock, 9)
		for i = 1, 20 do
			world2:spawn(ZOMBIE, 60.5, FLOOR, i * 2 + 0.5)
		end
		local ctx2 = context({ player("p", 0.5, FLOOR, 0.5, GameMode.CREATIVE) }, skyOpen)
		local frozen = {
			players = ctx2.players,
			dayTime = ctx2.dayTime,
			skyOpen = skyOpen,
			active = function()
				return false
			end,
		}
		run(world2, frozen, 600)
		t.eq(world2:count(), 20, "none before 30 s of nothing happening")
		for _, mob in world2:each() do
			mob.idle = 700
		end
		run(world2, frozen, 400)
		t.ok(world2:count() < 20 and world2:count() > 0, `a few at a time ({world2:count()} left)`)
		-- Frozen ones too (their chunks don't tick; Minecraft's would, out to 128 blocks): left
		-- behind, they don't stay for good.
		run(world2, frozen, 6000)
		t.eq(world2:count(), 0, "frozen monsters idle away too")
		-- A frozen mob that dies (/kill) still goes 20 ticks later, with its loot.
		local world3 = newWorld(getBlock, 5)
		local doomed = world3:spawn(COW, 60.5, FLOOR, 0.5)
		run(world3, frozen, 1)
		world3:takeChanges()
		t.ok(world3:kill(doomed), "killed")
		run(world3, frozen, MobWorld.DEATH_TIME - 1)
		t.ok(world3:get(doomed) ~= nil, "lies dying")
		run(world3, frozen, 1)
		t.eq(world3:get(doomed), nil, "then gone, though its chunk doesn't tick")
		local changes = world3:takeChanges()
		t.eq(#changes.deaths, 1, "one death")
		t.eq(changes.removed[1], doomed, "removed")
		t.ok(#changes.drops > 0, "its beef dropped")
		-- The cap.
		local small = newWorld(getBlock, 1, 3)
		for _ = 1, 5 do
			small:spawn(PIG, 0.5, FLOOR, 0.5)
		end
		t.eq(small:count(), 3, "at most maxMobs")
	end)

	--[[ Attacks ]]

	local function attacker(
		key: any,
		x: number,
		z: number,
		mode: string?,
		item: number?,
		ticks: number?
	): MobWorld.Attacker
		return {
			key = key,
			x = x,
			y = FLOOR,
			z = z,
			eye = 1.62,
			mode = mode or GameMode.SURVIVAL,
			alive = true,
			item = item,
			ticks = ticks or 100,
		}
	end

	t.test("attacks: reach by game mode, sight, spectators, attack strength and weapons", function()
		local getBlock, set, skyOpen = flat()
		local world = newWorld(getBlock)
		local id = world:spawn(PIG, 4.5, FLOOR, 0.5)
		local pig = world:get(id) :: MobWorld.Mob
		-- (Back where it was, calm, its cooldown over.)
		local function reset()
			run(world, context({}, skyOpen), 11)
			pig.body.x, pig.body.z, pig.body.vx, pig.body.vz = 4.5, 0.5, 0, 0
			pig.ai.goal = "idle"
		end
		reset()
		-- The pig's box starts at x 4.05: 3.55 from a player at x 0.5.
		local landed, why = world:attack(id, attacker("p", 0.5, 0.5))
		t.eq(landed, 1, "a survival player's fist in reach (3 + leeway)")
		t.eq(why, true, "a strong hit")
		reset()
		local tooFar, reason = world:attack(id, attacker("p", -1.0, 0.5))
		t.eq(tooFar, nil, "5 blocks: out of a survival player's reach")
		t.eq(reason, "reach")
		local creative = world:attack(id, attacker("c", -1.0, 0.5, GameMode.CREATIVE))
		t.eq(creative, 1, "in creative's 6")
		reset()
		local spectator, sreason = world:attack(id, attacker("s", 3.5, 0.5, GameMode.SPECTATOR))
		t.eq(spectator, nil, "spectators hit nothing")
		t.eq(sreason, "mode")
		local dead, dreason = world:attack(
			id,
			{ key = "d", x = 3.5, y = FLOOR, z = 0.5, eye = 1.62, mode = GameMode.SURVIVAL, alive = false, ticks = 100 }
		)
		t.eq(dead, nil, "nor do the dead")
		t.eq(dreason, "dead")
		-- A wall between.
		for y = FLOOR, FLOOR + 3 do
			for z = -2, 2 do
				set(2, y, z, STONE)
			end
		end
		local hidden, hreason = world:attack(id, attacker("p", 0.5, 0.5, GameMode.CREATIVE))
		t.eq(hidden, nil, "not through a wall")
		t.eq(hreason, "sight")
		-- Weapons and strength.
		local w2 = newWorld(getBlock)
		local z = w2:spawn(ZOMBIE, -3.5, FLOOR, 0.5)
		local full = w2:attack(z, attacker("p", -5.5, 0.5, nil, I.DiamondSword, 20))
		t.near(full :: number, Items.damageAfterArmor(7, 2, 0), 1e-9, "a diamond sword's 7, through a zombie's armor")
		run(w2, context({}, skyOpen), 10)
		local weak, strong = w2:attack(z, attacker("p", -5.5, 0.5, nil, I.DiamondSword, 0))
		t.eq(strong, false, "right after a swing: weak")
		t.near(
			weak :: number,
			Items.damageAfterArmor(Combat.damage(7, Combat.strength(0, 1.6)), 2, 0),
			1e-9,
			"x (0.2 + strength^2 x 0.8)"
		)
		t.eq(Combat.reach(GameMode.SURVIVAL), 3)
		t.eq(Combat.reach(GameMode.ADVENTURE), 3, "adventure players fight")
		t.eq(Combat.reach(GameMode.CREATIVE), 6)
		t.eq(Combat.reach(GameMode.SPECTATOR), 0)
		t.eq((Combat.attackOf(nil)), 1, "the hand")
		t.eq((Combat.attackOf(I.WoodenSword)), 4, "swords 4..7")
		t.eq((Combat.attackOf(I.DiamondAxe)), 9, "axes hit hard")
		t.eq(select(2, Combat.attackOf(I.DiamondAxe)), 1, "and slowly")
		t.eq((Combat.attackOf(I.Dirt)), 1, "a block hits like the hand")
		t.eq(Combat.wear(I.IronSword), 1, "swords wear 1 a hit")
		t.eq(Combat.wear(I.IronPickaxe), 2, "other tools 2")
		t.eq(Combat.wear(I.Dirt), 0)
		t.eq(Combat.strength(12, 1.6), 1, "a sword recovers in 12.5 ticks")
		t.ok(Combat.strength(5, 1.6) < 0.5)
	end)

	--[[ Spawning ]]

	local SETTINGS = {
		Spawning = true,
		PassiveCap = 10,
		HostileCap = 15,
		MaxPassive = 120,
		MaxHostile = 160,
		PassiveInterval = 1,
		HostileInterval = 1,
		Attempts = 4,
		SpawnDistance = { 24, 44 },
	}

	t.test("spawning: creatures on grass in the light, monsters in the dark, capped", function()
		local getBlock, set, skyOpen = flat()
		local world = newWorld(getBlock, 21)
		local state = MobSpawning.new()
		local p = player("p", 0.5, FLOOR, 0.5)
		local ctx = context({ p }, skyOpen, NOON)
		for _ = 1, 200 do
			MobSpawning.step(world, state, ctx, SETTINGS)
		end
		local hostile, passive = MobSpawning.census(world)
		t.eq(hostile, 0, "no monsters on the open ground at noon")
		t.eq(passive, 10, "creatures up to the player's cap of 10")
		for _, mob in world:each() do
			local body = mob.body
			local d = math.sqrt((body.x - p.x) ^ 2 + (body.z - p.z) ^ 2)
			t.ok(d >= 24 - 4.5 and d <= 44 + 4.5, `24-44 blocks away (and the pack's spread): {d}`)
			t.eq(getBlock(math.floor(body.x), math.floor(body.y) - 1, math.floor(body.z)), GRASS, "on grass")
			t.eq(body.y, FLOOR, "standing on it")
		end
		-- At night, monsters too, up to 15.
		local night = context({ p }, skyOpen, MIDNIGHT)
		for _ = 1, 400 do
			MobSpawning.step(world, state, night, SETTINGS)
		end
		hostile = MobSpawning.census(world)
		t.eq(hostile, 15, "monsters up to the cap of 15 at night")
		-- On stone, no creatures; torches keep monsters off.
		local stoneWorld = newWorld(getBlock, 4)
		local getStone, setStone, stoneSky = flat()
		for x = -60, 60 do
			for z = -60, 60 do
				setStone(x, FLOOR - 1, z, STONE)
			end
		end
		local onStone = newWorld(getStone, 4)
		local stoneState = MobSpawning.new()
		for _ = 1, 100 do
			MobSpawning.step(onStone, stoneState, context({ p }, stoneSky, NOON), SETTINGS)
		end
		t.eq(onStone:count(), 0, "no creatures on stone")
		local _ = stoneWorld
		local getLit, setLit, litSky = flat()
		for x = -60, 60, 6 do
			for z = -60, 60, 6 do
				setLit(x, FLOOR, z, B.Torch)
			end
		end
		local lit = newWorld(getLit, 8)
		local litState = MobSpawning.new()
		local litSettings = table.clone(SETTINGS)
		litSettings.PassiveInterval = 100000
		for _ = 1, 200 do
			MobSpawning.step(lit, litState, context({ p }, litSky, MIDNIGHT), litSettings)
		end
		t.eq(lit:count(), 0, "no monsters where torches light the ground")
	end)

	t.test("spawning: never near a player, in chunks that don't tick, or in blocks; global caps", function()
		local getBlock, _, skyOpen = flat()
		local world = newWorld(getBlock, 2)
		local state = MobSpawning.new()
		local p = player("p", 0.5, FLOOR, 0.5)
		local ctx = context({ p, player("q", 30.5, FLOOR, 0.5) }, skyOpen, MIDNIGHT)
		for _ = 1, 300 do
			MobSpawning.step(world, state, ctx, SETTINGS)
		end
		t.ok(world:count() > 0)
		for _, mob in world:each() do
			for _, other in ctx.players do
				local d = math.sqrt((mob.body.x - other.x) ^ 2 + (mob.body.z - other.z) ^ 2)
				t.ok(d >= 23.9, `never within 24 blocks of a player ({d})`)
			end
		end
		-- Chunks that don't tick: nothing.
		local quiet = newWorld(getBlock, 2)
		local inactive = {
			players = { p },
			dayTime = MIDNIGHT,
			skyOpen = skyOpen,
			active = function()
				return false
			end,
		}
		for _ = 1, 200 do
			MobSpawning.step(quiet, MobSpawning.new(), inactive, SETTINGS)
		end
		t.eq(quiet:count(), 0, "never in a chunk that doesn't tick")
		-- Unloaded: a world loaded only within 10 blocks.
		local getSmall, _, smallSky = flat(nil, 10)
		local tiny = newWorld(getSmall, 2)
		for _ = 1, 200 do
			MobSpawning.step(tiny, MobSpawning.new(), context({ p }, smallSky, MIDNIGHT), SETTINGS)
		end
		t.eq(tiny:count(), 0, "never where blocks aren't loaded")
		-- The world's cap.
		local capped = newWorld(getBlock, 2, 5)
		for _ = 1, 200 do
			MobSpawning.step(capped, MobSpawning.new(), ctx, SETTINGS)
		end
		t.eq(capped:count(), 5, "never past maxMobs")
		-- Spectators don't spawn anything; spawning off.
		local none = newWorld(getBlock, 2)
		for _ = 1, 100 do
			MobSpawning.step(
				none,
				MobSpawning.new(),
				context({ player("s", 0.5, FLOOR, 0.5, GameMode.SPECTATOR) }, skyOpen, MIDNIGHT),
				SETTINGS
			)
		end
		t.eq(none:count(), 0, "not around spectators")
		local off = table.clone(SETTINGS)
		off.Spawning = false
		for _ = 1, 100 do
			MobSpawning.step(none, MobSpawning.new(), ctx, off)
		end
		t.eq(none:count(), 0, "Config.Mobs.Spawning = false")
		-- A spot inside a block is refused.
		local kind = MobList.get(ZOMBIE) :: MobList.Kind
		-- (The darkest rolls: the sky test and the brightness test both pass when they can.)
		local function nextInt(n: number): number
			return n - 1
		end
		t.ok(
			MobSpawning.validSpot(getBlock, context({}, skyOpen, MIDNIGHT), kind, 40, FLOOR, 0, nextInt),
			"open ground at night"
		)
		t.ok(
			not MobSpawning.validSpot(getBlock, context({}, skyOpen, MIDNIGHT), kind, 40, FLOOR - 2, 0, nextInt),
			"not in stone"
		)
		t.ok(
			not MobSpawning.validSpot(getBlock, context({}, skyOpen, NOON), kind, 40, FLOOR, 0, nextInt),
			"not in the sun"
		)
		t.ok(
			not MobSpawning.validSpot(getBlock, context({}, skyOpen, MIDNIGHT), kind, 40, FLOOR + 1, 0, nextInt),
			"not in the air"
		)
		-- Nothing spawns inside a rail (a mineshaft's track: #prevent_mob_spawning_inside); a
		-- cobweb doesn't stop it (NaturalSpawner.isValidEmptySpawnBlock).
		for _, name in { "Rail", "RailEastWest", "CaveRail", "CaveRailEastWest", "Cobweb", "CaveCobweb" } do
			local inside = Blocks.find(name) :: number
			local function getWith(x: number, y: number, z: number): number?
				if x == 40 and y == FLOOR and z == 0 then
					return inside
				end
				return getBlock(x, y, z)
			end
			local web = string.find(name, "Cobweb") ~= nil
			t.eq(
				MobSpawning.validSpot(getWith, context({}, skyOpen, MIDNIGHT), kind, 40, FLOOR, 0, nextInt),
				web,
				`{name}: {if web then "spawns" else "no spawn inside"}`
			)
		end
	end)

	t.test("spawning: monsters frozen beyond the chunks that tick don't fill a player's cap", function()
		local getBlock, _, skyOpen = flat()
		local world = newWorld(getBlock, 31)
		local p = player("p", 0.5, FLOOR, 0.5)
		-- Ticking: chunks within 3 of the player's (Config.Server.SimulationRadius), about 56 blocks.
		local ticking = {
			players = { p },
			dayTime = MIDNIGHT,
			skyOpen = skyOpen,
			skyClear = skyOpen,
			active = function(cx: number, cz: number): boolean
				return math.abs(cx) <= 3 and math.abs(cz) <= 3
			end,
		}
		-- A full cap of monsters left 80 blocks behind (within the cap's 128), frozen there.
		for i = 1, 15 do
			world:spawn(ZOMBIE, 80.5, FLOOR, i - 7.5)
		end
		world:tick(ticking)
		local frozen = 0
		for _, mob in world:each() do
			if mob.frozen then
				frozen += 1
			end
		end
		t.eq(frozen, 15, "frozen out there")
		t.eq(MobSpawning.census(world, p.x, p.y, p.z), 0, "they don't count against the player's cap")
		local settings = table.clone(SETTINGS)
		settings.PassiveInterval = 100000
		local state = MobSpawning.new()
		for _ = 1, 400 do
			MobSpawning.step(world, state, ticking, settings)
		end
		local near = MobSpawning.census(world, p.x, p.y, p.z)
		t.eq(near, 15, "monsters still spawn around the player, up to the cap")
		t.eq((MobSpawning.census(world)), 30, "the frozen ones are still there, until they idle away")
	end)

	t.test("mobs: no block is placed inside one (Level.isUnobstructed)", function()
		local getBlock = flat()
		local world = newWorld(getBlock)
		local id = world:spawn(ZOMBIE, 2.5, FLOOR, 0.5)
		local function cell(x: number, y: number, z: number): boolean
			return world:overlaps(x, y, z, x + 1, y + 1, z + 1)
		end
		t.ok(cell(2, FLOOR + 1, 0), "its head's cell")
		t.ok(cell(2, FLOOR, 0), "its feet's")
		t.ok(not cell(3, FLOOR + 1, 0), "the cell beside it (0.6 wide: 2.2 to 2.8)")
		t.ok(not cell(2, FLOOR + 2, 0), "above its 1.95 tall box")
		t.ok(not cell(2, FLOOR - 1, 0), "the floor it stands on (touching)")
		-- A lantern's outline beside its box: no; a torch has none (Blocks.obstruction).
		t.ok(not world:overlaps(2.8, FLOOR, 0.3, 3.2, FLOOR + 0.5, 0.7), "a box that only touches")
		world:kill(id)
		t.ok(cell(2, FLOOR + 1, 0), "a dying body too")
		run(world, context({}, nil), MobWorld.DEATH_TIME)
		t.ok(not cell(2, FLOOR + 1, 0), "nothing once it is gone")
	end)

	t.test("light estimate: block light, sky light and Minecraft's spawn tests", function()
		local getBlock, set, skyOpen = flat()
		set(0, FLOOR, 0, B.Torch)
		t.eq(LightEstimate.blockLight(getBlock, 0, FLOOR, 0), 14, "a torch's 14")
		t.eq(LightEstimate.blockLight(getBlock, 3, FLOOR, 0), 11, "one less a block")
		t.eq(LightEstimate.blockLight(getBlock, 20, FLOOR, 0), 0, "dark far away")
		-- A torch lights a room as far as its light goes, whatever the room's height (a spawn
		-- check's search: SPAWN_BUDGET), so torches 12 apart keep a hall free of monsters.
		for _, height in { 2, 3, 6 } do
			local getHall, setHall = flat()
			for x = -40, 40 do
				for z = -40, 40 do
					setHall(x, FLOOR + height, z, STONE)
				end
			end
			setHall(13, FLOOR, 0, B.Torch)
			t.eq(
				LightEstimate.blockLight(getHall, 1, FLOOR, 0, LightEstimate.SPAWN_BUDGET),
				2,
				`12 away, {height} high`
			)
			t.eq(LightEstimate.blockLight(getHall, 0, FLOOR, 0, LightEstimate.SPAWN_BUDGET), 1, `13 away`)
			t.eq(LightEstimate.blockLight(getHall, -1, FLOOR, 0, LightEstimate.SPAWN_BUDGET), 0, `14 away: dark`)
			t.eq(LightEstimate.blockLight(getHall, 1, FLOOR, 0, LightEstimate.SPAWN_BUDGET, 1), 2, "stops at a light")
			local kind = MobList.get(ZOMBIE) :: MobList.Kind
			local function darkest(n: number): number
				return n - 1
			end
			local inside = context({}, function()
				return false
			end, MIDNIGHT)
			t.ok(
				not MobSpawning.validSpot(getHall, inside, kind, 1, FLOOR, 0, darkest),
				`no monster 12 blocks from a torch in a {height} high hall`
			)
			t.ok(MobSpawning.validSpot(getHall, inside, kind, -1, FLOOR, 0, darkest), "14 blocks away: dark")
		end
		t.eq(LightEstimate.skyLight(getBlock, skyOpen, 10, FLOOR, 0), 15, "the open sky")
		-- A roof: 1 block under its edge 14, deep under it 0.
		for x = 20, 40 do
			for z = -10, 10 do
				set(x, FLOOR + 2, z, STONE)
			end
		end
		t.eq(LightEstimate.skyLight(getBlock, skyOpen, 20, FLOOR, 0), 14, "under the edge")
		t.eq(LightEstimate.skyLight(getBlock, skyOpen, 30, FLOOR, 0), 0, "deep under it")
		t.eq(LightEstimate.skyLight(getBlock, skyOpen, 30, FLOOR - 3, 0), 0, "in rock")
		local function rolls(values: { number })
			local i = 0
			return function(_n: number): number
				i += 1
				return values[i]
			end
		end
		t.ok(not LightEstimate.darkForMonsters(15, 1, 11, rolls({ 31, 7 })), "any block light: no")
		t.ok(LightEstimate.darkForMonsters(15, 0, 11, rolls({ 20, 4 })), "the open night: when the rolls allow")
		t.ok(not LightEstimate.darkForMonsters(15, 0, 11, rolls({ 20, 3 })), "or not")
		t.ok(not LightEstimate.darkForMonsters(15, 0, 0, rolls({ 31, 7 })), "the open day: never")
		t.ok(LightEstimate.darkForMonsters(0, 0, 0, rolls({ 0, 0 })), "a cave by day")
		t.ok(LightEstimate.brightForAnimals(15, 0) and not LightEstimate.brightForAnimals(8, 0), "animals: above 8")
	end)

	--[[ Commands ]]

	t.test("commands: /summon and /kill", function()
		local ctx = { mayUse = true, enabled = true, x = 10, y = FLOOR, z = -5 }
		local result = SummonCommand.run("/summon zombie", ctx) :: SummonCommand.Result
		t.eq((result.summon :: any).kind, ZOMBIE)
		t.eq((result.summon :: any).x, 10, "at the player's feet")
		t.eq(result.feedback[1], "Summoned new Zombie")
		local at = SummonCommand.run("/summon minecraft:creeper ~2 ~ 7", ctx) :: SummonCommand.Result
		t.eq((at.summon :: any).x, 12, "~2")
		t.eq((at.summon :: any).y, FLOOR, "~")
		t.eq((at.summon :: any).z, 7, "absolute")
		t.eq((SummonCommand.run("/summon wither", ctx) :: SummonCommand.Result).summon, nil, "unknown kinds")
		t.eq((SummonCommand.run("/summon cow 1 2", ctx) :: SummonCommand.Result).summon, nil, "two coordinates")
		t.eq((SummonCommand.run("/summon cow 99999 2 0", ctx) :: SummonCommand.Result).summon, nil, "too far")
		local denied = SummonCommand.run("/summon cow", { mayUse = false, enabled = true, x = 0, y = 0, z = 0 })
		t.eq((denied :: SummonCommand.Result).feedback[1], SummonCommand.DENIED)
		t.eq((denied :: SummonCommand.Result).summon, nil)
		local kill = SummonCommand.run("/kill @e[type=minecraft:zombie]", ctx) :: SummonCommand.Result
		t.eq((kill.kill :: any).kind, ZOMBIE)
		local all = SummonCommand.run("/kill @e", ctx) :: SummonCommand.Result
		t.ok(all.kill ~= nil and (all.kill :: any).kind == nil, "every mob")
		t.eq((SummonCommand.run("/kill @p", ctx) :: SummonCommand.Result).kill, nil, "players are not ours to kill")
		t.eq(SummonCommand.run("/say hi", ctx), nil, "other commands")
		t.eq(SummonCommand.killed(3), "Killed 3 entities")
		t.eq(SummonCommand.killed(1), "Killed 1 entity")
	end)

	--[[ The wire ]]

	t.test("protocol: Mobs, Attack and Eat round trips; malformed messages", function()
		local ops: { Protocol.MobOp } = {
			{
				op = "spawn",
				id = 7,
				kind = SHEEP,
				variant = 3,
				x = 10.5,
				y = FLOOR,
				z = -3.25,
				yaw = math.pi / 2,
				health = 8,
				flags = Protocol.MobFlag.Hurt + Protocol.MobFlag.Burning,
				fuse = 0,
			},
			{ op = "state", id = 9, x = -100.03125, y = 64.5, z = 2, yaw = 0, health = 20, flags = 8, fuse = 12 },
			{ op = "remove", id = 3 },
			{ op = "arrow", id = 4, x = 1, y = 2, z = 3, tx = 4.5, ty = 5.5, tz = -6.5 },
			{ op = "push", id = 5, kx = 0.4, ky = 0.4, kz = -0.1 },
		}
		local decoded = Protocol.decodeMobs(Protocol.encodeMobs(ops), MobList.COUNT) :: { Protocol.MobOp }
		t.eq(#decoded, 5)
		local spawn = decoded[1] :: any
		t.eq(spawn.op, "spawn")
		t.eq(spawn.kind, SHEEP)
		t.eq(spawn.variant, 3)
		t.eq(spawn.x, 10.5)
		t.eq(spawn.z, -3.25)
		t.near(spawn.yaw, math.pi / 2, 1e-9, "yaw in 1/256 turns")
		t.eq(spawn.health, 8)
		t.eq(spawn.flags, 3)
		local state = decoded[2] :: any
		t.eq(state.x, -100.03125, "1/32 block")
		t.eq(state.fuse, 12)
		t.eq((decoded[3] :: any).op, "remove")
		local arrow = decoded[4] :: any
		t.eq(arrow.tz, -6.5)
		local push = decoded[5] :: any
		t.near(push.kx, 0.4, 1e-6)
		t.near(push.kz, -0.1, 1e-6)
		-- Malformed.
		local bad = Protocol.encodeMobs({
			{
				op = "spawn",
				id = 1,
				kind = 200,
				variant = 0,
				x = 0,
				y = 0,
				z = 0,
				yaw = 0,
				health = 0,
				flags = 0,
				fuse = 0,
			},
		})
		t.eq(Protocol.decodeMobs(bad, MobList.COUNT), nil, "an unknown kind")
		local good = Protocol.encodeMobs(ops)
		local cut = buffer.create(buffer.len(good) - 1)
		buffer.copy(cut, 0, good, 0, buffer.len(cut))
		t.eq(Protocol.decodeMobs(cut, MobList.COUNT), nil, "cut short")
		local long = buffer.create(buffer.len(good) + 1)
		buffer.copy(long, 0, good, 0)
		t.eq(Protocol.decodeMobs(long, MobList.COUNT), nil, "too long")
		local strong = Protocol.encodeMobs({ { op = "push", id = 1, kx = 50, ky = 0, kz = 0 } })
		t.eq(Protocol.decodeMobs(strong, MobList.COUNT), nil, "a push too strong")
		t.eq(Protocol.decodeAttack(Protocol.encodeAttack(123456)), 123456)
		t.eq(Protocol.decodeAttack(buffer.create(3)), nil)
		t.eq(Protocol.decodeEat(Protocol.encodeEat(Protocol.EatAction.Finish)), Protocol.EatAction.Finish)
		t.eq(Protocol.decodeEat(Protocol.encodeEat(9)), nil)
		t.eq(Protocol.ClientMessage.Attack, 18)
		t.eq(Protocol.ClientMessage.Eat, 19)
		t.eq(Protocol.ServerMessage.Mobs, 18)
	end)

	--[[ Food ]]

	t.test("food: cooked meat heals more, raw chicken and rotten flesh may bring the Thirst effect", function()
		local function heal(item: number): number
			return (Foods.eat(Foods.of(item) :: Foods.Food, function()
				return 0.99
			end))
		end
		t.eq(heal(I.CookedBeef), 4)
		t.eq(heal(I.CookedPorkchop), 4)
		t.eq(heal(I.CookedMutton), 3)
		t.eq(heal(I.CookedChicken), 3)
		t.eq(heal(I.RawBeef), 2)
		t.eq(heal(I.RawMutton), 1)
		t.eq(heal(I.RottenFlesh), 2)
		local _, none = Foods.eat(Foods.of(I.RottenFlesh) :: Foods.Food, function()
			return 0.9
		end)
		t.eq(none, 0, "rotten flesh: 20% nothing")
		local _, ticks = Foods.eat(Foods.of(I.RottenFlesh) :: Foods.Food, function()
			return 0.5
		end)
		t.eq(ticks, 600, "80%: 30 s of the Thirst effect")
		local _, chicken = Foods.eat(Foods.of(I.RawChicken) :: Foods.Food, function()
			return 0.5
		end)
		t.eq(chicken, 0, "raw chicken: 30%")
		t.eq(Foods.of(I.Dirt), nil, "not food")
		t.ok(Foods.canEat(10, 20, GameMode.SURVIVAL), "a hurt player eats")
		t.ok(not Foods.canEat(20, 20, GameMode.SURVIVAL), "a full one doesn't")
		t.ok(Foods.canEat(20, 20, GameMode.CREATIVE), "creative eats whenever")
		t.ok(not Foods.canEat(10, 20, GameMode.SPECTATOR), "spectators never")
		t.eq(Foods.USE_TICKS, 32)
	end)

	--[[ Cost ]]

	t.test("cost: ticking mobs (ms per server tick)", function()
		local getBlock, _, skyOpen = flat()
		for _, n in { 50, 150, 300 } do
			local world = newWorld(getBlock, 3)
			local players = { player("p", 0.5, FLOOR, 0.5) }
			for i = 1, n do
				local kind = (i - 1) % MobList.COUNT + 1
				world:spawn(kind, ((i * 7) % 60) - 30 + 0.5, FLOOR, ((i * 13) % 60) - 30 + 0.5)
			end
			local ctx = context(players, skyOpen, MIDNIGHT)
			run(world, ctx, 20)
			local start = os.clock()
			local ticks = 100
			for _ = 1, ticks do
				world:tick(ctx)
				world:takeChanges()
			end
			local ms = (os.clock() - start) / ticks * 1000
			print(string.format("         %d mobs: %.3f ms a tick (%d left)", n, ms, world:count()))
			t.ok(ms < 20, `{n} mobs cost under 20 ms a tick ({ms})`)
		end
		-- A spawning round (both categories due, 3 packs each) for one player at night, with
		-- caves under the ground for the monsters' column scans to find.
		local getCave, setCave, caveSky = flat()
		for x = -60, 60 do
			for z = -60, 60 do
				if (x + z) % 7 == 0 then
					for y = FLOOR - 8, FLOOR - 6 do
						setCave(x, y, z, AIR)
					end
				end
			end
		end
		local settings = table.clone(SETTINGS)
		settings.Attempts = 3
		local rounds = 200
		local world = newWorld(getCave, 5, 100000)
		local state = MobSpawning.new()
		local ctx = context({ player("p", 0.5, FLOOR, 0.5) }, caveSky, MIDNIGHT)
		local start = os.clock()
		for _ = 1, rounds do
			MobSpawning.step(world, state, ctx, settings)
			for _, mob in world:each() do
				world:remove(mob.id)
			end
		end
		local ms = (os.clock() - start) / rounds * 1000
		print(string.format("         a spawning round (one player, 3 packs a category): %.3f ms", ms))
		t.ok(ms < 10, `a spawning round costs under 10 ms ({ms})`)
	end)
end

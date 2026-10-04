--[[
	Item entities: Minecraft's item physics (Shared/Entities/ItemPhysics) and the server's item
	rules (Entities/EntityWorld: pickup delay, pickups, merging, despawning, the cap, changes).
]]

-- (Modules come from the test loader's require, so their types are restated here.)
type GetBlock = (x: number, y: number, z: number) -> number?
type Body = { x: number, y: number, z: number, vx: number, vy: number, vz: number, onGround: boolean, age: number }

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Hull = require(shared.Movement.Hull)
	local ItemPhysics = require(shared.Entities.ItemPhysics)
	local EntityWorld = require(server.Entities.EntityWorld)

	local STONE, ICE, AIR = Blocks.id.Stone, Blocks.id.Ice, Blocks.AIR
	local WATER = Blocks.fluidId("Water", 0)
	local DIRT, SAND = Items.id.Dirt, Items.id.Sand

	-- A world from a function of (x, y, z) -> block?; stone up to y = 0 (its top at y = 1) by
	-- default, air above.
	local function blocks(f: ((x: number, y: number, z: number) -> number?)?): GetBlock
		return function(x: number, y: number, z: number): number?
			local block = if f then f(x, y, z) else nil
			if block then
				return block
			end
			return if y <= 0 then STONE else AIR
		end
	end
	local flat = blocks()

	local function run(body: Body, id: number, getBlock: GetBlock, ticks: number)
		for _ = 1, ticks do
			ItemPhysics.tick(body, id, getBlock)
		end
	end

	--[[ ItemPhysics ]]

	t.test("item physics: falls with Minecraft's gravity and drag, lands and rests on the block", function()
		local body = ItemPhysics.new(0.5, 5, 0.5)
		ItemPhysics.tick(body, 1, flat)
		-- vy = (0 - 0.04) * 0.98 after the first tick, and it moved by -0.04.
		t.near(body.y, 4.96, 1e-12, "first tick")
		t.near(body.vy, -0.0392, 1e-12, "first tick speed")
		local landedAfter = nil
		for tick = 2, 100 do
			ItemPhysics.tick(body, 1, flat)
			if body.onGround and landedAfter == nil then
				landedAfter = tick
			end
		end
		t.ok(landedAfter ~= nil and landedAfter < 20, `landed after {landedAfter} ticks`)
		t.eq(body.y, 1, "rests on top of the stone")
		-- Between its moves (every fourth tick) a resting item gathers up to 3 ticks of gravity.
		t.ok(body.vy <= 0 and body.vy >= -0.12 - 1e-12, `no speed left: {body.vy}`)
		t.ok(body.onGround, "on the ground")
		t.eq(body.age, 100, "age counts ticks")
		-- Resting items stay put, whichever tick they move on.
		run(body, 1, flat, 37)
		t.eq(body.y, 1, "still resting")
		t.eq(body.x, 0.5)
	end)

	t.test("item physics: a popped item rises, lands without bouncing; ceilings stop it", function()
		-- Block.popResource's velocity: 0.2 up.
		local body = ItemPhysics.new(0.5, 1, 0.5, 0, 0.2, 0)
		local top, landed, bouncedAfterLanding = 1, false, false
		for _ = 1, 60 do
			ItemPhysics.tick(body, 1, flat)
			top = math.max(top, body.y)
			if landed and body.y > 1 then
				bouncedAfterLanding = true
			end
			landed = landed or (body.onGround and body.y == 1)
		end
		t.ok(top > 1.25 and top < 1.6, `rose to {top}`)
		t.ok(landed, "came back down")
		t.ok(not bouncedAfterLanding, "landing zeroes the fall speed (Block.updateEntityAfterFallOn)")

		-- A ceiling block at y = 2: the box (0.25 tall) stops under it and the rise ends.
		local ceiling = blocks(function(x, y, z)
			return if y == 2 then STONE else nil
		end)
		local thrown = ItemPhysics.new(0.5, 1, 0.5, 0, 0.5, 0)
		ItemPhysics.tick(thrown, 1, ceiling)
		t.near(thrown.y, 1.46, 1e-9, "first tick: 0.5 - 0.04 up")
		ItemPhysics.tick(thrown, 1, ceiling)
		t.near(thrown.y, 1.75, 1e-9, "stopped under the ceiling")
		t.eq(thrown.vy, 0, "the rise stopped")
		t.ok(not thrown.onGround, "a ceiling is not ground")
	end)

	t.test("item physics: slides much farther on ice than on stone", function()
		local function slide(ground: number): number
			local world = blocks(function(x, y, z)
				return if y == 0 then ground else nil
			end)
			local body = ItemPhysics.new(0.5, 1, 0.5, 0.3, 0, 0)
			body.onGround = true
			run(body, 1, world, 200)
			return body.x - 0.5
		end
		local stone, ice = slide(STONE), slide(ICE)
		-- Ground drag: 0.6 x 0.98 (stone) and 0.98 x 0.98 (ice) per tick: 0.3 / (1 - f) - ish.
		t.ok(stone > 0.6 and stone < 0.8, `stone: {stone}`)
		t.ok(ice > 6 and ice < 8, `ice: {ice}`)
	end)

	t.test("item physics: stops at walls", function()
		local wall = blocks(function(x, y, z)
			return if x == 3 and (y == 1 or y == 2) then STONE else nil
		end)
		local body = ItemPhysics.new(0.5, 1, 0.5, 1, 0, 0)
		body.onGround = true
		run(body, 1, wall, 40)
		t.near(body.x, 3 - ItemPhysics.WIDTH / 2, 1e-9, "against the wall's face")
		t.eq(body.vx, 0, "the wall stopped it")
		t.ok(
			Hull.noCollision(function(x, y, z)
				local block = wall(x, y, z)
				return block == nil or Blocks.isSolid(block)
			end, ItemPhysics.box(body)),
			"not inside the wall"
		)
	end)

	-- A pool of still water (sources) at y = 1..5 inside |x|, |z| <= 3.
	local pool = blocks(function(x, y, z)
		if y >= 1 and y <= 5 and math.abs(x) <= 3 and math.abs(z) <= 3 then
			return WATER
		end
		return nil
	end)

	t.test("item physics: floats up in water and stays near the surface", function()
		local body = ItemPhysics.new(0.5, 1.5, 0.5)
		local top = 0
		for tick = 1, 600 do
			ItemPhysics.tick(body, 7, pool)
			if tick > 400 then
				top = math.max(top, body.y)
				-- The surface is at 5 + 8/9; floating needs 0.1014 of water above the box bottom.
				t.ok(body.y > 4.5 and body.y < 5.9, `bobbing at the surface: {body.y} at tick {tick}`)
			end
		end
		t.ok(top > 5.5, `reached the surface: {top}`)
		t.near(body.x, 0.5, 1e-9, "still water does not push")
		t.near(body.z, 0.5, 1e-9, "still water does not push")
	end)

	t.test("item physics: water currents carry items", function()
		-- Flowing water at y = 1 getting lower towards +x (level 1 at x <= 0, then 2, 3...).
		local stream = blocks(function(x, y, z)
			if y == 1 and z >= -2 and z <= 2 and x >= -4 and x <= 6 then
				return Blocks.fluidId("Water", math.clamp(x + 1, 1, 7))
			end
			return nil
		end)
		local body = ItemPhysics.new(0.5, 1, 0.5)
		run(body, 1, stream, 40)
		t.ok(body.x > 1.5, `carried downstream to x = {body.x}`)
		t.near(body.z, 0.5, 1e-9, "straight along the flow")
	end)

	t.test("item physics: an item inside a block moves out to the nearest open side", function()
		-- A block placed on a resting item: every side is open; north (-z) is the first of the
		-- nearest ones.
		local placed = blocks(function(x, y, z)
			return if x == 0 and y == 1 and z == 0 then STONE else nil
		end)
		local solidAt = function(x: number, y: number, z: number): boolean
			local block = placed(x, y, z)
			return block == nil or Blocks.isSolid(block)
		end
		local body = ItemPhysics.new(0.5, 1, 0.5)
		body.onGround = true
		run(body, 1, placed, 40)
		t.ok(Hull.noCollision(solidAt, ItemPhysics.box(body)), `free at {body.x}, {body.y}, {body.z}`)
		t.ok(body.z < -0.1, `left through the north side: z = {body.z}`)
		t.eq(body.y, 1, "back on the ground")

		-- Walled in on all four sides: it rises out of the top.
		local walled = blocks(function(x, y, z)
			if y == 1 and math.abs(x) <= 1 and math.abs(z) <= 1 then
				return STONE
			end
			return nil
		end)
		local trapped = ItemPhysics.new(0.5, 1, 0.5)
		trapped.onGround = true
		run(trapped, 1, walled, 120)
		t.eq(trapped.y, 2, `on top of the block: {trapped.y}`)
	end)

	t.test("item physics: frozen where blocks are not loaded; unloaded neighbours are solid", function()
		local unloaded = function(x: number, y: number, z: number): number?
			return nil
		end
		local body = ItemPhysics.new(0.5, 5, 0.5, 0.1, 0.1, 0.1)
		t.eq(ItemPhysics.tick(body, 1, unloaded), false)
		t.eq(body.y, 5)
		t.eq(body.vy, 0.1)
		t.eq(body.age, 0, "no tick happened")

		-- Unloaded chunk to the east: the item stops at its border as at a wall.
		local edge = function(x: number, y: number, z: number): number?
			if x >= 2 then
				return nil
			end
			return flat(x, y, z)
		end
		local sliding = ItemPhysics.new(0.5, 1, 0.5, 1, 0, 0)
		sliding.onGround = true
		run(sliding, 1, edge, 20)
		t.near(sliding.x, 2 - ItemPhysics.WIDTH / 2, 1e-9, "stopped at the unloaded border")
	end)

	t.test("item physics: deterministic", function()
		local function scenario(): { number }
			local world = blocks(function(x, y, z)
				if x == 4 and y >= 1 and y <= 3 then
					return STONE
				elseif y == 1 and x >= -1 and x <= 1 then
					return WATER
				elseif y == 0 and z > 1 then
					return ICE
				end
				return nil
			end)
			local out = {}
			for id = 1, 6 do
				local body = ItemPhysics.new(0.5 + id * 0.1, 3, 0.5, 0.05 * id, 0.2, 0.03 * (3 - id))
				run(body, id, world, 150)
				table.insert(out, body.x)
				table.insert(out, body.y)
				table.insert(out, body.z)
				table.insert(out, body.vx)
				table.insert(out, body.vy)
				table.insert(out, body.vz)
			end
			return out
		end
		local a, b = scenario(), scenario()
		for i = 1, #a do
			t.eq(a[i], b[i], `value {i}`)
		end
	end)

	--[[ EntityWorld ]]

	local function newWorld(options: { [string]: any }?): any
		local o = options or {}
		return EntityWorld.new(o.getBlock or flat, {
			maxItems = o.maxItems or 1000,
			lifetimeTicks = o.lifetimeTicks or 6000,
		})
	end
	local function noPickup(): number
		return 0
	end
	local function tickN(world: any, n: number, players: { any }?, pickup: any?)
		for _ = 1, n do
			world:tick(players or {}, pickup or noPickup)
		end
	end

	t.test("entity world: spawning gives increasing ids, Minecraft's default velocity and delay", function()
		local world = newWorld()
		local a = world:spawnItem(DIRT, 3, 0.5, 1, 0.5, 0, 0, 0)
		local b = world:spawnItem(DIRT, 1, 2.5, 1, 0.5)
		t.eq(a, 1)
		t.eq(b, 2)
		t.eq(world:count(), 2)
		local entity = world:get(b)
		t.eq(entity.pickupDelay, 10, "default pickup delay")
		t.eq(entity.body.vy, 0.2, "popped up")
		t.ok(math.abs(entity.body.vx) <= 0.1 and math.abs(entity.body.vz) <= 0.1, "a little sideways")
		t.eq(world:spawnItem(DIRT, 1, 0.5, 1, 0.5, 0, 0, 0, 40), 3)
		t.eq(world:get(3).pickupDelay, 40)
	end)

	t.test("entity world: the pickup delay counts down before players can take items", function()
		local world = newWorld()
		local id = world:spawnItem(DIRT, 5, 0.5, 1, 0.5, 0, 0, 0)
		local calls = 0
		local function take(key: any, item: number, count: number): number
			calls += 1
			t.eq(key, "steve")
			t.eq(item, DIRT)
			return count
		end
		local players = { { key = "steve", x = 1.2, y = 1, z = 0.5 } }
		tickN(world, 9, players, take)
		t.eq(calls, 0, "not during the 10 tick delay")
		tickN(world, 1, players, take)
		t.eq(calls, 1, "taken on the tick the delay ends")
		t.eq(world:get(id), nil, "gone")
		t.eq(world:count(), 0)
		local changes = world:takeChanges()
		t.eq(#changes.removed, 1)
		t.eq(changes.removed[1].id, id)
		t.eq(changes.removed[1].collector, "steve", "the collector is reported")
	end)

	t.test("entity world: pickup reach is the player's box grown by (1, 0.5, 1)", function()
		local function reaches(px: number, py: number, pz: number): boolean
			local world = newWorld()
			world:spawnItem(DIRT, 1, 0.5, 1, 0.5, 0, 0, 0, 0)
			local taken = false
			world:tick({ { key = 1, x = px, y = py, z = pz } }, function()
				taken = true
				return 1
			end)
			return taken
		end
		-- Item box x: [0.375, 0.625]; player box grown: [px - 1.3, px + 1.3].
		t.ok(reaches(1.9, 1, 0.5), "1.4 away sideways")
		t.ok(not reaches(2, 1, 0.5), "1.5 away sideways")
		-- Item box y: [1, 1.25]; player box grown: [py - 0.5, py + 2.3].
		t.ok(reaches(0.5, 1.7, 0.5), "feet 0.45 above the item's top")
		t.ok(not reaches(0.5, 1.8, 0.5), "feet 0.55 above the item's top")
		t.ok(reaches(0.5, -1.25, 0.5), "player 2.25 below the item")
		t.ok(not reaches(0.5, -1.35, 0.5), "player 2.35 below")
	end)

	t.test("entity world: partial pickups keep the rest, full ones remove the item", function()
		local world = newWorld()
		local id = world:spawnItem(SAND, 10, 0.5, 1, 0.5, 0, 0, 0, 0)
		world:takeChanges()
		local players = { { key = "alex", x = 0.5, y = 1, z = 0.5 } }
		world:tick(players, function(_, _, count)
			t.eq(count, 10)
			return 3
		end)
		t.eq(world:get(id).count, 7, "7 left")
		local changes = world:takeChanges()
		t.eq(#changes.counts, 1)
		t.eq(changes.counts[1], id)
		t.eq(#changes.removed, 0)
		t.eq(#changes.taken, 1, "the partial pickup is reported for its flight")
		t.eq(changes.taken[1].count, 3)
		t.eq(changes.taken[1].collector, "alex")
		-- Handlers returning nonsense take nothing (or at most everything).
		world:tick(players, function()
			return -5
		end)
		t.eq(world:get(id).count, 7)
		world:tick(players, function()
			return 100
		end)
		t.eq(world:get(id), nil, "all taken")
		changes = world:takeChanges()
		t.eq(changes.removed[1].collector, "alex")
	end)

	t.test("entity world: same items close together merge, the smaller into the larger", function()
		local world = newWorld()
		local small = world:spawnItem(DIRT, 3, 0.5, 1, 0.5, 0, 0, 0, 5)
		local large = world:spawnItem(DIRT, 5, 1.1, 1, 0.5, 0, 0, 0, 30)
		world:get(small).age = 100
		world:get(large).age = 300
		world:takeChanges()
		-- At rest they check every 40 ticks.
		tickN(world, 39)
		t.ok(world:get(small) ~= nil and world:get(large) ~= nil, "not before the 40th tick")
		tickN(world, 1)
		t.eq(world:get(small), nil, "the smaller one merged away")
		local merged = world:get(large)
		t.eq(merged.count, 8)
		-- The younger age (100 + 39 when they merged), then this tick's.
		t.eq(merged.age, 100 + 40, "the younger age")
		local changes = world:takeChanges()
		t.eq(changes.counts[1], large)
		t.eq(changes.removed[1].id, small)
		t.eq(changes.removed[1].collector, nil, "nobody collected it")
	end)

	t.test("entity world: merging keeps the longer pickup delay; ties merge into the other item", function()
		local world = newWorld()
		local a = world:spawnItem(DIRT, 4, 0.5, 1, 0.5, 0, 0, 0, 100)
		local b = world:spawnItem(DIRT, 4, 0.9, 1, 0.5, 0, 0, 0, 0)
		tickN(world, 40)
		-- Both are due on the same tick; `a` checks first and, being no larger, merges into `b`.
		t.eq(world:get(a), nil)
		t.eq(world:get(b).count, 8)
		t.eq(world:get(b).pickupDelay, 100 - 40, "a's longer delay (counted down for 40 ticks)")
	end)

	t.test("entity world: what does not merge", function()
		-- Two items resting on the floor `dx` apart (one on a step `dy` higher), after 40 ticks.
		local function merges(
			item1: number,
			count1: number,
			item2: number,
			count2: number,
			dx: number,
			dy: number?
		): boolean
			local rise = dy or 0
			local world = newWorld({
				getBlock = blocks(function(x, y, z)
					-- A slab-free step: the second item stands on a block raised by `rise` (0 or 1).
					return if rise > 0 and x == 2 and y == 1 then STONE else nil
				end),
			})
			world:spawnItem(item1, count1, 1.9, 1, 0.5, 0, 0, 0)
			world:spawnItem(item2, count2, 1.9 + dx, 1 + rise, 0.5, 0, 0, 0)
			tickN(world, 40)
			return world:count() == 1
		end
		t.ok(merges(DIRT, 1, DIRT, 1, 0.7), "0.7 apart: their boxes touch the grown box")
		t.ok(not merges(DIRT, 1, DIRT, 1, 0.8), "0.8 apart: too far")
		t.ok(not merges(DIRT, 1, DIRT, 1, 0.3, 1), "a block higher: merging does not reach up")
		t.ok(not merges(DIRT, 1, SAND, 1, 0.2), "different items")
		t.ok(not merges(DIRT, 40, DIRT, 30, 0.2), "the sum does not fit a stack")
		t.ok(merges(DIRT, 40, DIRT, 24, 0.2), "exactly a full stack")
		t.ok(not merges(DIRT, 64, DIRT, 1, 0.2), "a full stack never merges")
		t.ok(not merges(Items.id.IronHelmet, 1, Items.id.IronHelmet, 1, 0.2), "unstackable items")
	end)

	t.test("entity world: moving items check for merges every 2 ticks", function()
		local world = newWorld()
		-- Two items falling side by side cross block boundaries while falling.
		local a = world:spawnItem(DIRT, 2, 0.5, 20, 0.5, 0, 0, 0)
		local b = world:spawnItem(DIRT, 1, 0.9, 20, 0.5, 0, 0, 0)
		local mergedAt = nil
		for tick = 1, 40 do
			world:tick({}, noPickup)
			if world:count() == 1 and mergedAt == nil then
				mergedAt = tick
			end
		end
		t.ok(mergedAt ~= nil and mergedAt < 40, `merged while falling, at tick {mergedAt}`)
		t.ok(world:get(a) ~= nil and world:get(b) == nil)
	end)

	t.test("entity world: items despawn after their lifetime", function()
		local world = newWorld({ lifetimeTicks = 50 })
		local id = world:spawnItem(DIRT, 1, 0.5, 1, 0.5, 0, 0, 0)
		tickN(world, 49)
		t.ok(world:get(id) ~= nil, "alive at 49 ticks")
		tickN(world, 1)
		t.eq(world:get(id), nil, "gone at 50")
		local changes = world:takeChanges()
		t.eq(changes.removed[1].id, id)
		t.eq(changes.removed[1].collector, nil)
		-- Items in unloaded blocks are frozen: they neither move nor age.
		local frozen = newWorld({
			lifetimeTicks = 50,
			getBlock = function(x: number, y: number, z: number): number?
				return nil
			end,
		})
		local f = frozen:spawnItem(DIRT, 1, 0.5, 1, 0.5)
		tickN(frozen, 100)
		t.ok(frozen:get(f) ~= nil, "a frozen item does not age")
		t.eq(frozen:get(f).body.y, 1)
	end)

	t.test("entity world: at most maxItems items, the oldest go first", function()
		local world = newWorld({ maxItems = 3 })
		for i = 1, 5 do
			world:spawnItem(DIRT, 1, i * 3 + 0.5, 1, 0.5, 0, 0, 0)
		end
		t.eq(world:count(), 3)
		t.eq(world:get(1), nil)
		t.eq(world:get(2), nil)
		t.ok(world:get(3) ~= nil and world:get(5) ~= nil)
		local changes = world:takeChanges()
		t.eq(#changes.removed, 2)
		t.eq(changes.removed[1].id, 1)
		t.eq(changes.removed[2].id, 2)
		t.eq(#changes.spawned, 3, "only live spawns are reported")
		-- Removed ones elsewhere in the list do not confuse the cap.
		world:remove(4)
		world:spawnItem(DIRT, 1, 30.5, 1, 0.5, 0, 0, 0)
		t.eq(world:count(), 3)
		t.ok(world:get(3) ~= nil, "a free place was left")
		world:spawnItem(DIRT, 1, 33.5, 1, 0.5, 0, 0, 0)
		t.eq(world:get(3), nil, "now the oldest goes")
		t.eq(world:count(), 3)
	end)

	t.test("entity world: changes for replication", function()
		local world = newWorld()
		local falling = world:spawnItem(DIRT, 1, 0.5, 30, 0.5, 0, 0, 0)
		local resting = world:spawnItem(SAND, 1, 5.5, 1, 0.5, 0, 0, 0)
		local changes = world:takeChanges()
		t.eq(#changes.spawned, 2)
		t.eq(changes.spawned[1], falling)
		t.eq(#changes.moved, 0)
		t.eq(#world:takeChanges().spawned, 0, "taken once")

		local syncs: { number } = {}
		for tick = 1, 120 do
			world:tick({}, noPickup)
			for _, id in world:takeChanges().moved do
				t.eq(id, falling, "the resting item is never resynced")
				table.insert(syncs, tick)
			end
		end
		-- Falls 29 blocks in ~ 50 ticks: resynced at 20 and 40, then once when it lands.
		t.ok(#syncs == 3, `synced at ticks {table.concat(syncs, ", ")}`)
		t.eq(syncs[1], 20)
		t.eq(syncs[2], 40)
		t.ok(syncs[3] > 44 and syncs[3] < 60, "once at rest (4 ticks without moving)")
		t.eq(world:get(falling).body.y, 1)
		t.ok(world:get(resting) ~= nil)
	end)
	t.test("entity world: players at absurd positions cannot stall the tick", function()
		-- Characters belong to their clients, so the server may see any position (even 1e16 blocks
		-- out, where a float loop over columns would never end, or inf / nan).
		local world = newWorld()
		world:spawnItem(Items.id.Dirt, 1, 0.5, 1, 0.5, 0, 0, 0, 0)
		for _, x in { 1e16, -3e16, math.huge, -math.huge, 0 / 0 } do
			tickN(world, 3, { { key = "far", x = x, y = 1, z = x } })
		end
		t.ok(world:count() >= 1, "the tick returned and the item is untouched")
	end)
end

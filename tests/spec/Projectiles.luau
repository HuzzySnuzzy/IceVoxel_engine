--[[
	Magic projectiles (Shared/Magic/Projectiles): the kinds by index and the weapons that cast them,
	how far each flies in the open (the spark's arc about 18 blocks, the bolt 30, the water bolt
	36), the spark ending on a wall and coming down on the ground, the water bolt bouncing five
	times between two walls and ending at the sixth, mob boxes hit by the slab test (nearest first,
	never behind a wall, the water bolt going through one to hit a second), and determinism: a
	client flying the spawn op it was sent follows the server's path exactly, bounces and all.
	Casting (Shared/Magic/Casting): the server's checks on a HeldUse (spectators, the dead, the
	slot, the item in hand; creative casts for free) and the cadence (a use time between casts,
	a tick of slack, late arrivals credited, never faster over a run).
]]

return function(t, shared, require)
	local Blocks = require(shared.Blocks)
	local GameMode = require(shared.GameMode)
	local Items = require(shared.Items)
	local Casting = require(shared.Magic.Casting)
	local MagicSync = require(shared.Net.MagicSync)
	local Projectiles = require(shared.Magic.Projectiles)

	local STONE = Blocks.id.Stone
	local SPARK, BOLT, WATER = Projectiles.kind("spark"), Projectiles.kind("bolt"), Projectiles.kind("water")

	-- Blocks from a set of "x,y,z" keys (everything else air).
	local function world(solid: { [string]: boolean }): (number, number, number) -> number?
		return function(x: number, y: number, z: number): number?
			return if solid[`{x},{y},{z}`] then STONE else Blocks.AIR
		end
	end
	local function open(_x: number, _y: number, _z: number): number?
		return Blocks.AIR
	end

	-- Flies `p` until it ends (at most `ticks`): the events in order.
	local function fly(p, getBlock, targets, ticks: number?): { string }
		local events = {}
		for _ = 1, ticks or 400 do
			local event = Projectiles.step(p, getBlock, targets)
			if event then
				table.insert(events, event)
			end
			if p.dead then
				break
			end
		end
		return events
	end

	t.test("projectiles: the kinds by index, and the weapons casting them", function()
		t.eq(SPARK, 1)
		t.eq(BOLT, 2)
		t.eq(WATER, 3)
		t.eq(Projectiles.COUNT, 3)
		t.eq(Projectiles.kind("fireball"), nil)
		t.eq(Projectiles.kind((Items.magic(Items.id.WandOfSparking) :: Items.MagicSpec).projectile), SPARK)
		t.eq(Projectiles.kind((Items.magic(Items.id.EmeraldStaff) :: Items.MagicSpec).projectile), BOLT)
		t.eq(Projectiles.kind((Items.magic(Items.id.WaterBolt) :: Items.MagicSpec).projectile), WATER)
		for _, kind in Projectiles.KINDS do
			t.ok(kind.speed <= MagicSync.MAX_SPEED, `{kind.name} within the wire's speed`)
		end
		local p = Projectiles.launch(BOLT, 0, 0, 0, 3, 0, 4)
		t.near(math.sqrt(p.vx ^ 2 + p.vy ^ 2 + p.vz ^ 2), 1.5, 1e-6, "launched at the kind's speed")
	end)

	t.test("projectiles: reach in the open (spark ~18 blocks in an arc, bolt 30, water 36)", function()
		local spark = Projectiles.launch(SPARK, 0, 100, 0, 1, 0, 0)
		local events = fly(spark, open, nil)
		t.eq(events[#events], "expired")
		t.eq(spark.reason, MagicSync.Reason.Expired)
		t.eq(spark.age, 20, "20 ticks")
		t.near(spark.x, (1 - 0.99 ^ 20) / 0.01, 1e-3, "drag: 18.2 blocks")
		t.ok(spark.x > 17 and spark.x < 19.5, `about 18 ({spark.x})`)
		t.ok(spark.y < 100 - 4 and spark.y > 100 - 7, `it falls in an arc ({100 - spark.y} blocks)`)
		local bolt = Projectiles.launch(BOLT, 0, 100, 0, 0, 0, -1)
		fly(bolt, open, nil)
		t.near(bolt.z, -30, 1e-3, "the staff's bolt: 30 blocks, straight")
		t.near(bolt.y, 100, 1e-6, "no gravity")
		local water = Projectiles.launch(WATER, 0, 100, 0, 1, 0, 0)
		fly(water, open, nil)
		t.near(water.x, 36, 1e-3, "the water bolt: 36 blocks")
		t.eq(water.age, 60)
	end)

	t.test("projectiles: a spark ends on a wall, and comes down onto the ground", function()
		local wall: { [string]: boolean } = {}
		for y = 95, 105 do
			wall[`5,{y},0`] = true
		end
		local spark = Projectiles.launch(SPARK, 0.5, 100.5, 0.5, 1, 0, 0)
		local events = fly(spark, world(wall), nil)
		t.eq(events[#events], "block")
		t.eq(spark.reason, MagicSync.Reason.Block)
		t.near(spark.x, 5, 0.01, "at the wall's face")
		-- Fired level from eye height over flat ground: it lands about 10 blocks out.
		local ground: { [string]: boolean } = {}
		for x = -2, 30 do
			ground[`{x},0,0`] = true
		end
		local low = Projectiles.launch(SPARK, 0.5, 2.62, 0.5, 1, 0, 0)
		events = fly(low, world(ground), nil)
		t.eq(events[#events], "block")
		t.near(low.y, 1, 0.01, "on the ground's top")
		t.ok(low.x > 8 and low.x < 13, `about 10 blocks out ({low.x})`)
		-- Started inside a block: it ends at once.
		local inside = Projectiles.launch(SPARK, 5.5, 100.5, 0.5, 1, 0, 0)
		t.eq(Projectiles.step(inside, world(wall)), "block")
	end)

	-- A corridor along x between walls at x = -1 and x = 4 (and nothing else).
	local function corridor(): { [string]: boolean }
		local walls: { [string]: boolean } = {}
		for y = 95, 105 do
			for z = -3, 3 do
				walls[`-1,{y},{z}`] = true
				walls[`4,{y},{z}`] = true
			end
		end
		return walls
	end

	t.test("projectiles: the water bolt bounces five times off walls, and ends at the sixth", function()
		local water = Projectiles.launch(WATER, 1.5, 100.5, 0.5, 1, 0, 0)
		local getBlock = world(corridor())
		local events = fly(water, getBlock, nil)
		local bounces = 0
		for i, event in events do
			if event == "bounce" then
				bounces += 1
			else
				t.eq(i, #events, "only the last is an end")
			end
		end
		t.eq(bounces, 5, "five bounces")
		t.eq(events[#events], "block", "the sixth wall ends it")
		t.eq(water.bounces, 5)
		t.ok(water.x > -0.01 and water.x < 4.01, `inside the corridor ({water.x})`)
		t.ok(water.age < 60, "before it expires")
		-- A bounce turns the velocity across the face round, nothing else.
		local one = Projectiles.launch(WATER, 3.8, 100.5, 0.5, 1, 0, 1)
		local vx, vz = one.vx, one.vz
		t.eq(Projectiles.step(one, getBlock), "bounce")
		t.eq(one.vx, -vx)
		t.eq(one.vz, vz)
		t.near(one.x, 4 - Projectiles.BOUNCE_GAP, 1e-6, "left just off the face (an f32)")
		-- The spark and the bolt never bounce.
		local bolt = Projectiles.launch(BOLT, 1.5, 100.5, 0.5, 1, 0, 0)
		t.eq(fly(bolt, getBlock, nil)[1], "block")
	end)

	t.test("projectiles: far from spawn a bounce keeps off its wall in f32 (the sync op's numbers)", function()
		-- Past 32768 blocks an f32 step is more than the gap: rounded, the bolt must stay out.
		for _, base in { 0, 1000, 40000, 100000, 500000, 999000 } do
			for _, dir in { 1, -1 } do
				local wallX = if dir > 0 then base + 5 else base - 6
				local getBlock = function(x: number, _y: number, _z: number): number?
					return if x == wallX then Blocks.id.Stone else Blocks.AIR
				end
				local p = Projectiles.launch(WATER, base + 0.5, 64.5, 0.5, dir, 0, 0.05)
				local bounced, after = false, nil
				for _ = 1, 30 do
					local event = Projectiles.step(p, getBlock, nil)
					if event == "bounce" then
						-- (The server's sync rounding.)
						Projectiles.round(p)
						bounced = true
						t.ok((p.x - (if dir > 0 then wallX else wallX + 1)) * -dir > 0, `off the face at {base}`)
					elseif bounced and after == nil then
						after = event or "flying"
					end
					if p.dead then
						break
					end
				end
				t.ok(bounced, `bounced at {base} ({dir})`)
				t.eq(after, "flying", `and flies back at {base} ({dir})`)
				t.ok(if dir > 0 then p.x < wallX - 1 else p.x > wallX + 2, `away from the wall ({p.x})`)
			end
		end
	end)

	t.test("projectiles: mob boxes (slab test, nearest first, not through walls, pierce)", function()
		local zombie = { id = 7, x = 6, y = 100, z = 0.5, width = 0.6, height = 1.95 }
		local cow = { id = 8, x = 10, y = 100, z = 0.5, width = 0.9, height = 1.4 }
		local hits = {}
		local bolt = Projectiles.launch(BOLT, 0.5, 101, 0.5, 1, 0, 0)
		local event = nil
		for _ = 1, 20 do
			event = Projectiles.step(bolt, open, { cow, zombie }, hits)
			if bolt.dead then
				break
			end
		end
		t.eq(event, "mob")
		t.eq(bolt.reason, MagicSync.Reason.Mob)
		t.eq(#hits, 1)
		t.eq(hits[1].id, 7, "the nearer mob")
		t.near(bolt.x, 6 - 0.3 - Projectiles.MOB_MARGIN, 1e-6, "at its grown box")
		-- Over its head: a miss.
		local high = Projectiles.launch(BOLT, 0.5, 103, 0.5, 1, 0, 0)
		t.eq(fly(high, open, { zombie })[1], "expired")
		-- Behind a wall: the wall takes it.
		local wall: { [string]: boolean } = {}
		for y = 99, 103 do
			wall[`3,{y},0`] = true
		end
		local blocked = Projectiles.launch(BOLT, 0.5, 101, 0.5, 1, 0, 0)
		t.eq(fly(blocked, world(wall), { zombie })[1], "block")
		t.eq(blocked.hits, 0)
		-- The water bolt goes through the first and ends in the second, each hit once.
		local water = Projectiles.launch(WATER, 0.5, 101, 0.5, 1, 0, 0)
		local struck: { number } = {}
		for _ = 1, 60 do
			local result = Projectiles.step(water, open, { zombie, cow }, hits)
			for _, target in hits do
				table.insert(struck, target.id)
			end
			if result then
				t.eq(result, "mob")
				break
			end
		end
		t.eq(#struck, 2, "two mobs")
		t.eq(struck[1], 7)
		t.eq(struck[2], 8)
		t.ok(water.dead and water.reason == MagicSync.Reason.Mob)
		-- A dead projectile does nothing more.
		t.eq(Projectiles.step(water, open, { zombie, cow }, hits), nil)
		t.eq(#hits, 0)
	end)

	t.test("projectiles: a client flying the sent spawn follows the server exactly", function()
		local getBlock = world(corridor())
		-- The server: cast from doubles, then flown.
		local server = Projectiles.launch(WATER, 1.123456789, 100.987654321, 0.333333333, 0.8, 0.1, 0.35)
		-- The client: the spawn op as the wire carries it.
		local ops = MagicSync.decodeProjectiles(
			MagicSync.encodeProjectiles({
				{
					op = "spawn",
					id = 1,
					kind = server.kind,
					owner = 1,
					seq = 1,
					x = server.x,
					y = server.y,
					z = server.z,
					vx = server.vx,
					vy = server.vy,
					vz = server.vz,
				},
			}),
			Projectiles.COUNT
		) :: { MagicSync.ProjectileOp }
		local op = ops[1]
		local client =
			Projectiles.new(op.kind :: number, op.x, op.y, op.z, op.vx :: number, op.vy :: number, op.vz :: number)
		local bounces = 0
		for _ = 1, 60 do
			local a = Projectiles.step(server, getBlock)
			local b = Projectiles.step(client, getBlock)
			t.eq(a, b, "the same event")
			t.ok(server.x == client.x and server.y == client.y and server.z == client.z, "the same place, to the bit")
			if a == "bounce" then
				bounces += 1
			end
			if server.dead then
				break
			end
		end
		t.ok(bounces >= 2, `it bounced on the way ({bounces})`)
		-- A sync after a bounce carries the f32 state: rounding it first changes nothing more.
		local p = Projectiles.launch(SPARK, 0.1, 0.2, 0.3, 1, 0, 0)
		local x = p.x
		Projectiles.round(p)
		t.eq(p.x, x, "the start is f32 already")
	end)

	--[[ Casting (Shared/Magic/Casting: the server's checks, the cadence) ]]

	t.test("casting: who may use what (spectators, the dead, the slot, the item, creative)", function()
		local wand, crystal = Items.id.WandOfSparking, Items.id.ManaCrystal
		local S, C, A, X = GameMode.SURVIVAL, GameMode.CREATIVE, GameMode.ADVENTURE, GameMode.SPECTATOR
		t.eq(Casting.check(S, true, 3, wand, 3, wand), "cast")
		t.eq(Casting.check(A, true, 3, wand, 3, wand), "cast", "adventure casts")
		t.eq(Casting.check(C, true, 3, wand, 3, wand), "cast")
		t.eq(Casting.check(S, true, 1, crystal, 1, crystal), "crystal")
		local function why(...): string?
			local use, reason = Casting.check(...)
			t.eq(use, nil)
			return reason
		end
		t.eq(why(X, true, 3, wand, 3, wand), "spectator")
		t.eq(why(S, false, 3, wand, 3, wand), "dead")
		t.eq(why(S, true, 2, wand, 3, wand), "slot", "another slot than the selected one")
		t.eq(why(S, true, 3, Items.id.EmeraldStaff, 3, wand), "item", "the hand holds something else")
		t.eq(why(S, true, 3, nil, 3, wand), "item", "an empty hand")
		t.eq(why(S, true, 3, Items.id.Stick, 3, Items.id.Stick), "use", "a stick casts nothing")
		t.ok(Casting.free(C) and not Casting.free(S) and not Casting.free(A), "creative casts for free")
		t.ok(Casting.handles(wand) and Casting.handles(crystal) and not Casting.handles(Items.id.Stick))
		t.ok(not Casting.handles(nil))
	end)

	t.test("casting: one cast per use time, a tick of slack, jitter credited, never faster", function()
		local use = (Items.magic(Items.id.WandOfSparking) :: Items.MagicSpec).useTicks
		local tick = Casting.TICK
		t.ok(Casting.ready(nil, 0, use), "the first")
		t.ok(not Casting.ready(10, 10 + (use - 2) * tick, use), "two ticks early")
		t.ok(Casting.ready(10, 10 + (use - 1) * tick, use), "a tick early: the slack")
		t.eq(Casting.after(nil, 5, use), 5)
		-- A late arrival counts from when it was due, so the next on-time one passes.
		local last = 10
		local late = 10 + use * tick + 0.08
		t.ok(Casting.ready(last, late, use))
		last = Casting.after(last, late, use)
		t.near(last, 10 + use * tick, 1e-9, "credited")
		t.ok(Casting.ready(last, 10 + 2 * use * tick, use), "the next on time")
		-- After a pause: from the arrival.
		t.eq(Casting.after(10, 30, use), 30)
		-- A client sending as fast as the slack allows still casts no faster than one a use time.
		local at, casts = 0, 0
		last = nil
		for step = 0, 2000 do
			local now = step * tick / 4
			if Casting.ready(last, now, use) then
				last = Casting.after(last, now, use)
				casts += 1
				at = now
			end
		end
		t.ok(casts <= math.floor(at / (use * tick)) + 2, `{casts} casts in {at} s`)
	end)
end

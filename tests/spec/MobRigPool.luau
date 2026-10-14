--[[
	The zombies' rig tiers and pools (client Entities/MobRigPool) over a fake part factory: a mob
	changes tier only past the hysteresis, there are never more than 16 full rigs and 40 rigs
	(464 rig parts moved a frame), no part is made once 60 zombies have been walking round a
	player for a while, rigs go back to their pools and are re-sized and re-coloured when reused,
	the hurt red repaints a rig once, a burning mob's flames always hang on its rig and never on
	a part that is destroyed, and what a frame of renderer bookkeeping and posing costs.
]]

local process = require("@lune/process")

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local MobList = require(shared.Entities.MobList)
	local MobModel = require(client.Entities.MobModel)
	local MobRig = require(client.Entities.MobRig)
	local MobRigPool = require(client.Entities.MobRigPool)
	local ZombieLooks = require(client.Entities.ZombieLooks)
	local ZombieVoices = require(client.Entities.ZombieVoices)

	local NATIVE = process.env.NOCODEGEN == nil
	local S = Config.Mobs.Rig
	local ZOMBIE = MobList.get(MobList.find("Zombie") :: number) :: MobList.Kind
	local BRUTE = MobList.get(MobList.find("ZombieBrute") :: number) :: MobList.Kind
	local COW = MobList.get(MobList.find("Cow") :: number) :: MobList.Kind
	-- The listener at a zombie's mid height, so distances are horizontal.
	local EAR = ZOMBIE.height / 2

	type Part = { size: { number }, colour: number, shadow: boolean, shown: boolean, dead: boolean }
	-- A burning mob's flames, as Roblox's Fire: destroying the part they hang on destroys them.
	type Flames = { parent: Part?, dead: boolean }
	type Fake = MobRigPool.Factory<Part> & {
		created: number,
		destroyed: number,
		paints: number,
		resizes: number,
		flames: { Flames },
	}

	local function factory(): Fake
		local f = { created = 0, destroyed = 0, paints = 0, resizes = 0, flames = {} } :: any
		f.create = function(sx: number, sy: number, sz: number, colour: number, shadow: boolean): Part
			f.created += 1
			return { size = { sx, sy, sz }, colour = colour, shadow = shadow, shown = false, dead = false }
		end
		f.resize = function(part: Part, sx: number, sy: number, sz: number)
			assert(not part.dead, "a destroyed part is reused")
			part.size = { sx, sy, sz }
			f.resizes += 1
		end
		f.paint = function(part: Part, colour: number)
			part.colour = colour
			f.paints += 1
		end
		f.park = function(part: Part)
			assert(part.shown, "parked twice")
			part.shown = false
		end
		f.show = function(part: Part)
			assert(not part.shown and not part.dead, "shown twice")
			part.shown = true
		end
		f.destroy = function(part: Part)
			assert(not part.shown, "a part destroyed in the scene")
			part.dead = true
			f.destroyed += 1
			for _, flames in f.flames do
				if flames.parent == part then
					flames.dead = true
				end
			end
		end
		f.attach = function(flames: Flames, part: Part?)
			-- (Roblox: "The Parent property of Fire is locked" once it was destroyed.)
			assert(not flames.dead, "destroyed flames moved")
			assert(part == nil or not part.dead, "flames hung on a destroyed part")
			flames.parent = part
		end
		return f :: Fake
	end

	-- New flames for mob `id`, as MobRenderer makes them when it starts burning.
	local function ignite(f: Fake, pool: MobRigPool.Pool<Part>, id: number): Flames
		local flames: Flames = { parent = nil, dead = false }
		table.insert(f.flames, flames)
		MobRigPool.setFlames(pool, id, flames)
		return flames
	end

	local function mobAt(id: number, kind: MobList.Kind, x: number, z: number, variant: number?): MobModel.Mob
		return MobModel.new(id, kind, variant or 1, { x = x, y = 0, z = z, yaw = 0, health = 20, flags = 0 }, 0)
	end

	-- Puts a mob at (x, z) at once (no glide).
	local function put(mob: MobModel.Mob, x: number, z: number)
		mob.x, mob.z, mob.fx, mob.fz = x, z, x, z
		mob.duration = 0
	end

	local function tierOf(pool: MobRigPool.Pool<Part>, id: number): number
		local entry = pool.entries[id]
		local rig = entry and entry.rig
		return if rig then rig.tier else 0
	end

	-- Parts of rigs (not impostors) in this frame's list.
	local function rigParts(pool: MobRigPool.Pool<Part>): number
		local n = 0
		for _, entry in pool.entries do
			local rig = entry.rig
			if rig and rig.tier ~= MobRig.IMPOSTOR then
				n += MobRig.drawn(rig.shape)
			end
		end
		return n
	end

	t.test("rig pool: a mob changes tier only past the hysteresis", function()
		local pool = MobRigPool.new(factory())
		local mob = mobAt(1, ZOMBIE, 10, 0)
		MobRigPool.add(pool, mob)
		local now = 0
		local changes = {}
		local last = 0
		local function walkTo(x: number)
			put(mob, x, 0)
			now += 1 / 60
			MobRigPool.frame(pool, now, 0, EAR, 0, 0, 0)
			local tier = tierOf(pool, 1)
			if tier ~= last then
				table.insert(changes, { from = last, to = tier, at = x })
				last = tier
			end
		end
		walkTo(10)
		t.eq(last, MobRig.FULL, "near: a full rig")
		-- Out to 50 and back in steps of a quarter block.
		for x = 10, 50, 0.25 do
			walkTo(x)
		end
		for x = 50, 10, -0.25 do
			walkTo(x)
		end
		local H = S.Hysteresis
		local seen = {}
		for _, change in changes do
			local key = `{change.from}>{change.to}`
			seen[key] = change.at
		end
		t.eq(seen["1>2"], S.FullDistance + H + 0.25, "full to reduced once past FullDistance + Hysteresis")
		t.eq(seen["2>3"], S.ReducedDistance + H + 0.25, "reduced to impostor past ReducedDistance + Hysteresis")
		t.eq(seen["3>2"], S.ReducedDistance, "back to reduced at ReducedDistance")
		t.eq(seen["2>1"], S.FullDistance, "back to full at FullDistance")
		t.eq(#changes, 5, "no other change (the first rig, then four)")
		-- Hovering round an edge changes nothing.
		local before = #changes
		for i = 1, 200 do
			walkTo(S.FullDistance + 0.5 + math.sin(i) * 1.4)
		end
		t.eq(#changes, before, "a full rig hovering at 16 +- 1.4 stays full")
		walkTo(S.FullDistance + H + 1)
		for i = 1, 200 do
			walkTo(S.FullDistance + 2 + math.sin(i) * 1.9)
		end
		t.eq(#changes, before + 1, "a reduced rig hovering at 18 +- 1.9 stays reduced")
	end)

	t.test("rig pool: at most 16 full rigs and 40 rigs; other kinds keep their boxes", function()
		local f = factory()
		local pool = MobRigPool.new(f)
		for i = 1, 60 do
			local angle = i * 2.4
			local d = 2 + i * 0.12
			MobRigPool.add(
				pool,
				mobAt(i, ZOMBIE, math.cos(angle) * d, math.sin(angle) * d, MobList.lookVariant(i % 11 + 1, 1))
			)
		end
		MobRigPool.add(pool, mobAt(100, COW, 1, 1))
		MobRigPool.frame(pool, 1, 0, EAR, 0, 0, 0)
		t.eq(pool.fullRigs, S.MaxFull, "16 full")
		t.eq(pool.reducedRigs, S.MaxRigs - S.MaxFull, "24 reduced")
		local full, reduced, impostor = 0, 0, 0
		for id = 1, 60 do
			local tier = tierOf(pool, id)
			if tier == MobRig.FULL then
				full += 1
				t.ok(id <= 16, `the 16 nearest are full ({id})`)
			elseif tier == MobRig.REDUCED then
				reduced += 1
				t.ok(id > 16 and id <= 40, `the next 24 reduced ({id})`)
			else
				impostor += 1
			end
		end
		t.eq(full, 16)
		t.eq(reduced, 24)
		t.eq(impostor, 20, "the rest as their two boxes")
		t.eq(tierOf(pool, 100), MobRig.IMPOSTOR, "a cow is always its boxes")
		local rig = rigParts(pool)
		t.ok(rig <= 16 * 17 + 24 * 8, `at most 464 rig parts ({rig})`)
		t.eq(pool.count, rig + 2 * 20 + 2, "every drawn part listed once, impostors' too")
		t.eq(#pool.matrices >= 12 * pool.count, true, "a frame a part")
		-- Only the head and torso parts cast shadows.
		for _, entry in pool.entries do
			local r = entry.rig :: MobRigPool.Rig<Part>
			for slot, part in r.parts do
				local expected = if r.tier == MobRig.IMPOSTOR
					then true
					else slot <= r.shape.body and r.shape.shadow[slot] == true
				t.eq(part.shadow, expected, `tier {r.tier} slot {slot}: its shadow`)
			end
		end
	end)

	-- 60 zombies walking round a player at the origin: circles of radius 3..62 blocks breathing
	-- in and out by 12 blocks, at different speeds both ways round, so zombies keep crossing
	-- every tier's edge. Updates (10 a second, as the server syncs) glide them.
	local function horde(pool: MobRigPool.Pool<Part>)
		local mobs = {}
		local zombieKinds = {}
		for _, kind in MobList.kinds do
			if kind.zombie then
				table.insert(zombieKinds, kind)
			end
		end
		local function at(i: number, time: number): (number, number)
			local radius = 3 + (i - 1) + 12 * math.sin(0.3 * time + i)
			radius = math.max(radius, 1.5)
			local angle = i * 0.7 + (if i % 2 == 0 then 1 else -1) * time * (0.05 + (i % 7) * 0.02)
			return math.cos(angle) * radius, math.sin(angle) * radius
		end
		for i = 1, 60 do
			local kind = zombieKinds[(i - 1) % #zombieKinds + 1]
			local variant = MobList.randomVariant(kind, function()
				return ((i * 53) % 97) / 97
			end)
			local x, z = at(i, 0)
			local mob = mobAt(i, kind, x, z, variant)
			mobs[i] = mob
			MobRigPool.add(pool, mob)
		end
		local sync = 0
		-- Advances the horde to `now` (sending the server's updates that are due); `mobs[i]` may be
		-- replaced (a zombie dies, another takes its walk).
		return function(now: number)
			while sync <= now do
				for i, mob in mobs do
					local x, z = at(i, sync)
					local yaw = math.atan2(x - mob.x, z - mob.z)
					local flags = if i % 5 == 0 then MobModel.AGGRESSIVE else 0
					MobModel.apply(mob, { x = x, y = 0, z = z, yaw = yaw, health = 20, flags = flags }, sync)
				end
				sync += 0.1
			end
		end,
			mobs
	end

	t.test("rig pool: no part is made once 60 zombies have walked round a player a while", function()
		local f = factory()
		local pool = MobRigPool.new(f)
		local advance = horde(pool)
		local changes = 0
		local tiers = {}
		local worstRigParts, worstFull, worstRigs = 0, 0, 0
		local createdAfterWarmUp, destroyedAfterWarmUp = 0, 0
		local warmFrames = 30 * 60
		for frame = 1, warmFrames + 60 * 60 do
			local now = frame / 60
			advance(now)
			MobRigPool.frame(pool, now, 0, EAR, 0, 0, 0)
			if frame == warmFrames then
				createdAfterWarmUp, destroyedAfterWarmUp = f.created, f.destroyed
			end
			if frame > warmFrames then
				worstRigParts = math.max(worstRigParts, rigParts(pool))
				worstFull = math.max(worstFull, pool.fullRigs)
				worstRigs = math.max(worstRigs, pool.fullRigs + pool.reducedRigs)
				for id = 1, 60 do
					local tier = tierOf(pool, id)
					if tiers[id] and tiers[id] ~= tier then
						changes += 1
					end
					tiers[id] = tier
				end
			end
		end
		print(
			string.format(
				"         60 s after a 30 s warm-up: %d tier changes, %d parts made (%d in the warm-up), at most %d rig parts moved",
				changes,
				f.created - createdAfterWarmUp,
				createdAfterWarmUp,
				worstRigParts
			)
		)
		t.ok(changes > 100, `the zombies kept changing tier ({changes})`)
		t.eq(f.created, createdAfterWarmUp, "no part made after the warm-up")
		t.eq(f.destroyed, destroyedAfterWarmUp, "none destroyed either")
		t.ok(worstFull <= 16, `at most 16 full rigs ({worstFull})`)
		t.ok(worstRigs <= 40, `at most 40 rigs ({worstRigs})`)
		t.ok(worstRigParts <= 464, `at most 464 rig parts moved a frame ({worstRigParts})`)
	end)

	t.test("rig pool: rigs go back to their pools, re-sized and re-coloured on reuse", function()
		local f = factory()
		local pool = MobRigPool.new(f)
		local zombie = mobAt(1, ZOMBIE, 5, 0, MobList.lookVariant(11, 1)) -- the beanie: one extra
		MobRigPool.add(pool, zombie)
		MobRigPool.frame(pool, 1, 0, EAR, 0, 0, 0)
		local rig = pool.entries[1].rig :: MobRigPool.Rig<Part>
		t.eq(rig.tier, MobRig.FULL)
		t.eq(#rig.parts, MobRig.FULL_SLOTS, "a full rig has every slot")
		local shown = 0
		for _, part in rig.parts do
			if part.shown then
				shown += 1
			end
		end
		t.eq(shown, 16, "the body and the beanie; the spare extra slot parked")
		local made = f.created
		MobRigPool.remove(pool, 1)
		t.eq(#pool.spare[MobRig.FULL], 1, "back in the full pool")
		for _, part in rig.parts do
			t.eq(part.shown, false, "parked")
		end
		-- A brute (a bigger scale, another look) takes the same rig.
		local brute = mobAt(2, BRUTE, 5, 0, MobList.lookVariant(2, 3)) -- the mechanic: a vest
		MobRigPool.add(pool, brute)
		MobRigPool.frame(pool, 2, 0, EAR, 0, 0, 0)
		local reused = pool.entries[2].rig :: MobRigPool.Rig<Part>
		t.eq(reused, rig, "the same rig")
		t.eq(f.created, made, "no part made")
		local shape = MobRig.build(BRUTE, brute.variant).full :: MobRig.Shape
		local colours = ZombieLooks.paint(BRUTE, brute.variant, 2).full
		for slot = 1, shape.count do
			local part = reused.parts[slot]
			local k = slot * 3
			t.eq(part.size[2], shape.size[k - 1], `slot {slot}: re-sized`)
			t.eq(part.colour, colours[slot], `slot {slot}: re-coloured`)
			t.eq(part.shown, true)
		end
		-- The spares are capped: the rest of the rigs are destroyed.
		for i = 10, 39 do
			MobRigPool.add(pool, mobAt(i, ZOMBIE, 3 + i * 0.1, 0))
		end
		MobRigPool.frame(pool, 3, 0, EAR, 0, 0, 0)
		local rigs = pool.fullRigs + pool.reducedRigs
		t.eq(rigs, 31, "31 rigs")
		local destroyed = f.destroyed
		MobRigPool.clear(pool)
		t.eq(#pool.spare[MobRig.FULL], S.SpareFull, "SpareFull full rigs kept")
		t.eq(#pool.spare[MobRig.REDUCED], 15, "the 15 reduced rigs kept (SpareReduced 16)")
		t.eq(f.destroyed - destroyed, (16 - S.SpareFull) * MobRig.FULL_SLOTS, "the other full rigs destroyed")
		t.eq(pool.count, 0)
		MobRigPool.frame(pool, 4, 0, EAR, 0, 0, 0)
		t.eq(pool.count, 0, "nothing left to draw")
	end)

	t.test("rig pool: the hurt red repaints a rig once as it starts and once as it ends", function()
		local f = factory()
		local pool = MobRigPool.new(f)
		local mob = mobAt(1, ZOMBIE, 4, 0)
		MobRigPool.add(pool, mob)
		MobRigPool.frame(pool, 1, 0, EAR, 0, 0, 0)
		local rig = pool.entries[1].rig :: MobRigPool.Rig<Part>
		local drawn = MobRig.drawn(rig.shape)
		local colours = ZombieLooks.paint(ZOMBIE, 1, 1).full
		local paints = f.paints
		local function update(flags: number, now: number)
			MobModel.apply(mob, { x = 4, y = 0, z = 0, yaw = 0, health = 20, flags = flags }, now)
			MobRigPool.frame(pool, now, 0, EAR, 0, 0, 0)
		end
		update(MobModel.HURT, 2)
		t.eq(f.paints - paints, drawn, "every part reddened once")
		t.eq(rig.parts[MobRig.HEAD].colour, ZombieLooks.hurt(colours[MobRig.HEAD]), "red")
		paints = f.paints
		update(MobModel.HURT, 2.1)
		MobRigPool.frame(pool, 2.2, 0, EAR, 0, 0, 0)
		t.eq(f.paints, paints, "no repaint while it stays hurt")
		update(0, 2.5)
		t.eq(f.paints - paints, drawn, "and once back")
		t.eq(rig.parts[MobRig.HEAD].colour, colours[MobRig.HEAD])
	end)

	t.test("rig pool: flames move with a burning mob's tier, never destroyed with a rig let go", function()
		local f = factory()
		local pool = MobRigPool.new(f)
		-- Thirteen zombies by the player; twelve die, and their full rigs fill the spares.
		local mobs = {}
		for i = 1, 13 do
			mobs[i] = mobAt(i, ZOMBIE, 2 + i * 0.5, 0)
			MobRigPool.add(pool, mobs[i])
		end
		local flames = ignite(f, pool, 13)
		local now = 1
		local function step()
			now += 1 / 60
			MobRigPool.frame(pool, now, 0, EAR, 0, 0, 0)
			local entry = pool.entries[13]
			t.eq(flames.dead, false, "the flames live")
			t.eq(flames.parent, MobRigPool.anchor(entry), "on the part its tier burns on")
		end
		step()
		t.eq(tierOf(pool, 13), MobRig.FULL)
		t.eq(flames.parent, (pool.entries[13].rig :: MobRigPool.Rig<Part>).parts[MobRig.UPPER_TORSO], "the upper torso")
		for i = 1, 12 do
			MobRigPool.remove(pool, i)
		end
		t.eq(#pool.spare[MobRig.FULL], S.SpareFull, "the full spares are full")
		-- It walks off to the reduced tier (its full rig is destroyed), the boxes, and back.
		local destroyed = f.destroyed
		for _, x in { 25, 60, 30, 5 } do
			put(mobs[13], x, 0)
			step()
			step()
		end
		t.ok(f.destroyed > destroyed, "rigs were destroyed on the way")
		t.eq(tierOf(pool, 13), MobRig.FULL, "full again")
		-- Put out: the flames come off; lit again, they hang on at the next frame.
		MobRigPool.setFlames(pool, 13, nil)
		t.eq(flames.parent, nil, "taken off when it stops burning")
		local again = ignite(f, pool, 13)
		MobRigPool.frame(pool, now + 1, 0, EAR, 0, 0, 0)
		t.eq(again.parent, MobRigPool.anchor(pool.entries[13]), "relit")
		MobRigPool.remove(pool, 13)
		t.eq(again.parent, nil, "taken off when the mob goes")
		t.eq(again.dead, false, "(the renderer destroys them itself)")
	end)

	t.test("rig pool: 60 zombies coming and going, a third of them burning", function()
		local f = factory()
		-- (Two spares a tier, so rigs let go are often destroyed.)
		local settings = table.clone(S)
		settings.SpareFull, settings.SpareReduced = 2, 2
		local pool = MobRigPool.new(f, settings)
		local advance, mobs = horde(pool)
		local burning: { [number]: Flames } = {}
		local nextId = 1000
		for i = 1, 60, 3 do
			burning[i] = ignite(f, pool, i)
		end
		local checks, moves = 0, 0
		local last: { [number]: Part? } = {}
		for frame = 1, 60 * 60 do
			local now = frame / 60
			advance(now)
			-- Twice a second a zombie dies (its rig to the spares, or destroyed) and another takes
			-- its walk, burning every other time.
			if frame % 30 == 0 then
				local i = (frame // 30 * 7) % 60 + 1
				local victim = mobs[i]
				MobRigPool.remove(pool, victim.id)
				local flames = burning[victim.id]
				if flames then
					t.eq(flames.parent, nil, "a dead mob's flames come off")
					burning[victim.id] = nil
				end
				nextId += 1
				local newcomer = mobAt(nextId, victim.kind, victim.x, victim.z, victim.variant)
				mobs[i] = newcomer
				MobRigPool.add(pool, newcomer)
				if nextId % 2 == 0 then
					burning[nextId] = ignite(f, pool, nextId)
				end
			end
			MobRigPool.frame(pool, now, 0, EAR, 0, 0, 0)
			for id, flames in burning do
				local entry = pool.entries[id]
				assert(not flames.dead, `zombie {id}: its flames destroyed`)
				assert(flames.parent == MobRigPool.anchor(entry), `zombie {id}: flames off its rig`)
				if last[id] ~= flames.parent then
					moves += 1
				end
				last[id] = flames.parent
				checks += 1
			end
		end
		print(
			string.format(
				"         %d burning zombie frames, flames moved %d times, %d parts destroyed",
				checks,
				moves,
				f.destroyed
			)
		)
		t.ok(f.destroyed > 0, `rigs were destroyed ({f.destroyed})`)
		t.ok(moves > 50, `the flames changed parts ({moves})`)
		for _, flames in f.flames do
			t.ok(not flames.dead, "no flames destroyed with a part")
		end
	end)

	t.test("rig pool: in game no box of a rig moves more than 0.3 studs a frame", function()
		-- A runner (walk 1) and a zombie at their chasing paces circling the player, one 8 and
		-- one 28 blocks out (a full and a reduced rig), as the renderer draws them: every rig is
		-- posed every frame (REDUCED_EVERY), so a reduced rig's limbs never sit still a frame and
		-- then catch up.
		t.eq(MobRigPool.REDUCED_EVERY, 1, "reduced rigs posed every frame")
		local pool = MobRigPool.new(factory())
		local RUNNER = MobList.get(MobList.find("ZombieRunner") :: number) :: MobList.Kind
		local walkers = {}
		for i, case in { { RUNNER, 8 }, { RUNNER, 28 }, { ZOMBIE, 8 }, { ZOMBIE, 28 } } do
			local kind, radius = case[1], case[2]
			local pace = kind.speed * kind.speed * (kind.chase or 1) * 0.98 / (1 - 0.6 * 0.91)
			local mob = mobAt(i, kind, radius, 0, MobList.lookVariant(1, 2))
			MobRigPool.add(pool, mob)
			walkers[i] = { mob = mob, radius = radius, speed = pace * 20 / radius }
		end
		local function flagsAt(time: number): number
			local flags = if time % 4 >= 1 then MobModel.AGGRESSIVE else 0
			if time % 2 >= 1.5 and time % 2 < 1.8 then
				flags += MobModel.ATTACK
			end
			if time % 6 >= 4 and time % 6 < 5 then
				flags += MobModel.BREAKING
			end
			return flags
		end
		local last: { [number]: { number } } = {}
		local worst = { 0, 0 }
		local sync = 0
		for frame = 1, 60 * 12 do
			local now = frame / 60
			while sync <= now do
				for _, w in walkers do
					local angle = w.speed * sync
					local x, z = math.cos(angle) * w.radius, math.sin(angle) * w.radius
					local state = { x = x, y = 0, z = z, yaw = -angle, health = 20, flags = flagsAt(sync) }
					MobModel.apply(w.mob, state, sync)
				end
				sync += 0.1
			end
			MobRigPool.frame(pool, now, 0, EAR, 0, 0, 0)
			for i in walkers do
				local entry = pool.entries[i]
				local rig = entry.rig :: MobRigPool.Rig<Part>
				local shape = rig.shape
				t.eq(rig.tier, if walkers[i].radius < 16 then MobRig.FULL else MobRig.REDUCED)
				local points = {}
				for slot = 1, shape.count do
					if not shape.hidden[slot] then
						local r, k = (slot - 1) * 12, slot * 3
						local rel = entry.rel
						for _, c in
							{
								{ -1, -1, -1 },
								{ 1, -1, -1 },
								{ -1, 1, -1 },
								{ 1, 1, -1 },
								{ -1, -1, 1 },
								{ 1, -1, 1 },
								{ -1, 1, 1 },
								{ 1, 1, 1 },
							}
						do
							local x, y, z =
								c[1] * shape.size[k - 2] / 2, c[2] * shape.size[k - 1] / 2, c[3] * shape.size[k] / 2
							table.insert(points, rel[r + 1] + rel[r + 4] * x + rel[r + 5] * y + rel[r + 6] * z)
							table.insert(points, rel[r + 2] + rel[r + 7] * x + rel[r + 8] * y + rel[r + 9] * z)
							table.insert(points, rel[r + 3] + rel[r + 10] * x + rel[r + 11] * y + rel[r + 12] * z)
						end
					end
				end
				local before = last[i]
				if before and frame > 30 then
					for p = 1, #points, 3 do
						local dx, dy, dz =
							points[p] - before[p], points[p + 1] - before[p + 1], points[p + 2] - before[p + 2]
						worst[rig.tier] = math.max(worst[rig.tier], math.sqrt(dx * dx + dy * dy + dz * dz))
					end
				end
				last[i] = points
			end
		end
		print(
			string.format(
				"         in game: full rigs %.3f, reduced rigs %.3f studs a frame at most",
				worst[1],
				worst[2]
			)
		)
		t.ok(worst[MobRig.FULL] <= 0.3, `full rigs ({worst[1]})`)
		t.ok(worst[MobRig.REDUCED] <= 0.3, `reduced rigs ({worst[2]})`)
	end)

	t.test("cost: renderer bookkeeping and posing for 40 rigs a frame", function()
		local f = factory()
		local pool = MobRigPool.new(f)
		local advance = horde(pool)
		local voices = ZombieVoices.new()
		local times = {}
		local warm = 600
		local parts = 0
		for frame = 1, warm + 1200 do
			local now = frame / 60
			local start = os.clock()
			advance(now)
			MobRigPool.frame(pool, now, 0, EAR, 0, 0, 0)
			ZombieVoices.step(voices, now, pool.zombies, pool.zombieIds, pool.zombieDistances, 16)
			local ms = (os.clock() - start) * 1000
			if frame > warm then
				table.insert(times, ms)
				parts = math.max(parts, pool.count)
			end
		end
		table.sort(times)
		local median, p90 = times[#times // 2], times[math.floor(#times * 0.9)]
		print(
			string.format(
				"         60 zombies, 16 full + 24 reduced rigs (%s): median %.3f ms, p90 %.3f ms a frame, %d parts listed",
				if NATIVE then "native" else "interpreted",
				median,
				p90,
				parts
			)
		)
		local budget = if NATIVE then 1.2 else 1.5
		t.ok(median <= budget, `a frame within {budget} ms ({median})`)
	end)
end

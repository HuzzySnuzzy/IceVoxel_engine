--[[
	The server's turret simulation (server Turrets/TurretWorld, the turrets design's builder A) on
	fakes of the game and the real shared rules (Shared/Turrets, TurretRules, Weapons/Ballistics,
	World/VoxelRaycast, Blocks/Shapes, server Weapons/FireRules), then the game's glue
	(server Turrets/Turrets with server Mobs/Mobs, Mobs/MobWorld and Apocalypse/NoiseBus real
	under fakes of Roblox):

	   targets     hostiles only (an animal or a frozen zombie never, an animal in the line never
	               hit); the aim points (Ballistics.mobBoxes' centres); nearest first with the
	               turning score; at most MaxSightChecks looked at, the next scan further down
	               (a breach, a cave: hidden ones never hide one in sight for long); sight through
	               blocks, glass and leaves stopped, torches and water not, the turret's own cell
	               air; the pitch limits' dead zone; MinRange; every type and tier's range and the
	               scope's; a mob killed in a tick gone for its later shots and scans
	   tracking    sticky; the turn rate (the short way across +-pi); lost after LoseTicks
	               unseen, at once dead, gone or out of range; no power holds still and keeps
	               it; blocked drops it; idle eases level, the yaw held; the status precedence
	   firing      the settle gate; the cadence under the feeder rule through the real kind
	               (Machines/Kinds/Turret); hand-filled its buffer then No ammo; MaxShotsPerTick
	               (a shot over it waits a tick, none lost, every turret its share); the spread
	               with and without the Laser Sight and a Suppressor (the cone's edge, the
	               design's hit rates); damage per type, the scoped sniper's head shots and a
	               helmet's share; knockback; glass never shattered
	   noise       each type's radius, suppressors' shares, the cooldown, the impact's noise; the
	               lure (night only, its cell's cap, its interval, its button, armed and idle
	               only, Lure.Enabled)
	   scans       ScanTicks, a Laser Sight's 5, staggered by cell, MaxScansPerTick (the longest
	               waiting first: none starves)
	   records     when they go (a change, RecordAngle, RecordRefresh, RecordTicks; idling sends
	               nothing), chunk records, a turret broken forgotten, the codec's round trip;
	               Shots records (shooter 0, the stand-in gun, the counter, the muzzle, plain)
	               through WeaponSync's codec
	   cost        50 turrets and 100 zombies in a fight and a siege, 150 and 260 in a siege (the
	               blood moon's), against the design's budget; nothing allocated while tracking
	   the glue    Mobs.hostiles and Mobs.target (reused tables, monsters only, never frozen),
	               Mobs.weaponDamage with no player (no kill credit), records to players within
	               RecordRange (every chunk a client keeps; where a player was last seen while its
	               feet are unknown), shots within ShotBroadcast, chunk records, the lure's night,
	               the NoiseBus, switched off nothing at all
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

-- A random number generator of its own (deterministic).
local function rng(seed: number): () -> number
	local state = seed
	return function(): number
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
end

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local Coords = require(shared.World.Coords)
	local DayCycle = require(shared.DayCycle)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local MobList = require(shared.Entities.MobList)
	local Protocol = require(shared.Net.Protocol)
	local WeaponSync = require(shared.Net.WeaponSync)
	local Turrets = require(shared.Turrets)
	local TurretRules = require(shared.Turrets.TurretRules)
	local Weapons = require(shared.Weapons)
	local Ballistics = require(shared.Weapons.Ballistics)
	local FireRules = require(server.Weapons.FireRules)
	local NoiseBus = require(server.Apocalypse.NoiseBus)
	local TurretWorld = require(server.Turrets.TurretWorld)

	local B, I = Blocks.id, Items.id
	local AIR, STONE = Blocks.AIR, B.Stone
	local STATUS = Turrets.STATUS
	local SLOT = Turrets.SLOT
	local Flag = Protocol.TurretFlag
	local CREDIT = TurretRules.CREDIT
	local S = Config.Turrets
	local W = Config.Weapons
	local ENERGY = Machines.ENERGY

	local ZOMBIE = MobList.kinds[MobList.find("Zombie") :: number]
	local BRUTE = MobList.kinds[MobList.find("ZombieBrute") :: number]
	local COW = MobList.kinds[MobList.find("Cow") :: number]
	-- A zombie look wearing a helmet, a hard hat or a fire helmet (FireRules.helmet), and one bare.
	local HELMETED, HELMET_VARIANT, BARE_VARIANT = nil :: any, 0, 0
	for _, kind in MobList.kinds do
		if MobList.isZombie(kind) and HELMETED == nil then
			for variant = 0, 255 do
				if FireRules.helmet(kind, variant) then
					HELMETED, HELMET_VARIANT = kind, variant
					break
				end
			end
		end
	end
	for variant = 0, 255 do
		if not FireRules.helmet(ZOMBIE, variant) then
			BARE_VARIANT = variant
			break
		end
	end
	assert(HELMETED, "a helmeted zombie look")

	-- The turret under test stands on the ground (stone below y 64) at T.
	local TX, TY, TZ = 0, 64, 0
	local FLOOR = 64
	local PX, PY, PZ = TurretRules.pivot(TX, TY, TZ)

	--[[ Fakes: the blocks, the mobs and the rest of the game ]]

	--[[
		A fake game for an Env: blocks (`set`), mobs (`add`: hostile by their kind, `frozen`,
		`health`), what was hurt, heard and asked. `e.env` is the Env.
	]]
	local function newGame(): any
		local e: any = {
			blocks = {},
			mobs = {},
			byId = {},
			nextId = 1,
			hurts = {},
			noises = {},
			night = false,
			feed = 0,
			feeds = 0,
			lureAsks = 0,
		}
		function e.set(x: number, y: number, z: number, block: number)
			e.blocks[Coords.posKey(x, y, z)] = block
		end
		local function getBlock(x: number, y: number, z: number): number?
			if y < 0 or y >= 1024 then
				return nil
			end
			local block = e.blocks[Coords.posKey(x, y, z)]
			if block then
				return block
			end
			return if y < FLOOR then STONE else AIR
		end
		e.getBlock = getBlock
		function e.add(kind: any, x: number, y: number, z: number, fields: any?): any
			local mob = {
				id = e.nextId,
				kind = kind,
				variant = BARE_VARIANT,
				x = x,
				y = y,
				z = z,
				yaw = 0,
				health = 1e9,
				dead = false,
				frozen = false,
			}
			for key, value in fields or {} do
				mob[key] = value
			end
			e.nextId += 1
			table.insert(e.mobs, mob)
			e.byId[mob.id] = mob
			return mob
		end
		function e.remove(mob: any)
			e.byId[mob.id] = nil
			table.remove(e.mobs, table.find(e.mobs, mob))
		end
		local function live(mob: any): boolean
			return mob.kind.hostile and not mob.dead and not mob.frozen
		end
		e.env = {
			getBlock = getBlock,
			hostiles = function(into: { any }): number
				local n = 0
				for _, mob in e.mobs do
					if live(mob) then
						n += 1
						local entry = into[n]
						if entry == nil then
							entry = {}
							into[n] = entry
						end
						entry.id, entry.kind, entry.variant = mob.id, mob.kind, mob.variant
						entry.x, entry.y, entry.z, entry.yaw = mob.x, mob.y, mob.z, mob.yaw
					end
				end
				return n
			end,
			mob = function(id: number): any
				local mob = e.byId[id]
				return if mob and live(mob) then mob else nil
			end,
			hurt = function(
				id: number,
				amount: number,
				ox: number,
				oz: number,
				knockback: number,
				head: boolean
			): number
				table.insert(
					e.hurts,
					{ id = id, amount = amount, ox = ox, oz = oz, knockback = knockback, head = head }
				)
				local mob = e.byId[id]
				if mob then
					mob.health -= amount
					if mob.health <= 0 then
						mob.dead = true
					end
				end
				return amount
			end,
			noise = function(x: number, y: number, z: number, radius: number)
				table.insert(e.noises, { x = x, y = y, z = z, radius = radius })
			end,
			lureTime = function(): boolean
				e.lureAsks += 1
				return e.night
			end,
			feed = function(_x: number, _y: number, _z: number): number
				e.feeds += 1
				return e.feed
			end,
			random = rng(7),
			settings = TurretWorld.settings(),
		}
		return e
	end

	-- A turret's order (Shared/Turrets/Types), as the kind fills it: powered, armed, full.
	local function newOrder(spec: Turrets.Spec, x: number?, y: number?, z: number?): any
		local ox, oy, oz = x or TX, y or TY, z or TZ
		return {
			tick = 0,
			key = Coords.posKey(ox, oy, oz),
			x = ox,
			y = oy,
			z = oz,
			block = spec.block,
			powered = true,
			blocked = false,
			armed = true,
			ready = false,
			optic = 0,
			muzzle = 0,
			muzzleFraction = 1,
			ammo = spec.buffer,
			held = spec.buffer,
			lure = false,
		}
	end

	--[[
		A simulation over a fake game: `add(spec, x, y, z, fields)` a turret (its order; `auto`
		keeps the kind's cadence: ready from its credit and the feeder rule, credit kept),
		`step(n)` n machine ticks (`each(tick)` first each tick), each turret's last Outcome in
		`o.out`, shots counted in `o.shots`, the shots taken each tick into `r.shots` when
		`r.keepShots`.
	]]
	local function newSim(e: any): any
		local r: any = { world = TurretWorld.new(e.env), tick = 0, turrets = {}, shots = {}, keepShots = false }
		function r.add(spec: Turrets.Spec, x: number?, y: number?, z: number?, fields: any?): any
			local o = newOrder(spec, x, y, z)
			for key, value in fields or {} do
				o[key] = value
			end
			o.spec = nil
			local entry = {
				order = o,
				spec = spec,
				auto = (fields or {}).auto == true,
				credit = 0,
				feed = 0,
				shots = 0,
				out = { status = STATUS.NO_TARGET, fired = false, tracking = false, feed = 0 },
			}
			o.auto = nil
			table.insert(r.turrets, entry)
			return entry
		end
		function r.step(n: number?)
			for _ = 1, n or 1 do
				r.tick += 1
				if r.each then
					r.each(r.tick)
				end
				for _, entry in r.turrets do
					local o = entry.order
					o.tick = r.tick
					local rpm = 0
					if entry.auto then
						rpm = if o.powered then Turrets.rpm(entry.spec, entry.feed) else 0
						o.ready = entry.credit + rpm >= CREDIT
					end
					local out = entry.out
					out.status, out.fired, out.tracking, out.feed = STATUS.NO_TARGET, false, false, 0
					TurretWorld.step(r.world, o, out)
					local fired = out.fired and o.ready and o.armed and o.powered and not o.blocked
					if entry.auto then
						entry.credit = TurretRules.cadence(entry.credit, rpm, fired)
						entry.feed = out.feed
					end
					if fired then
						entry.shots += 1
					end
				end
				local taken = TurretWorld.takeShots(r.world)
				if r.keepShots then
					for _, shot in taken do
						-- (The world's records are lent: copied.)
						local copy = table.clone(shot)
						copy.pellets = { table.clone(shot.pellets[1]) }
						table.insert(r.shots, copy)
					end
				end
			end
		end
		function r.state(entry: any): any
			return (r.world :: any).turrets[entry.order.key]
		end
		return r
	end

	--[[ Aim points ]]

	t.test(
		"turret world: aim points are mobBoxes' centres; a shot's pooled targets are FireRules.mobTarget's",
		function()
			for _, kind in MobList.kinds do
				for _, yaw in { 0, 0.7, math.pi / 2, 2.5, -2.1 } do
					local mob = { id = 1, kind = kind, variant = 0, x = 3.25, y = 70, z = -8.5, yaw = yaw }
					local body, head = Ballistics.mobBoxes(kind, mob.x, mob.y, mob.z, yaw)
					local bx, by, bz = TurretWorld.aimPoint(mob, false)
					local hx, hy, hz = TurretWorld.aimPoint(mob, true)
					t.near(bx, (body[1] + body[4]) / 2, 1e-9, `{kind.name} body x`)
					t.near(by, (body[2] + body[5]) / 2, 1e-9, `{kind.name} body y`)
					t.near(bz, (body[3] + body[6]) / 2, 1e-9, `{kind.name} body z`)
					t.near(hx, (head[1] + head[4]) / 2, 1e-9, `{kind.name} head x`)
					t.near(hy, (head[2] + head[5]) / 2, 1e-9, `{kind.name} head y`)
					t.near(hz, (head[3] + head[6]) / 2, 1e-9, `{kind.name} head z`)
					-- A shot's pooled target is FireRules.mobTarget's.
					for _, variant in { 0, 1, 9, HELMET_VARIANT } do
						mob.variant = variant
						local want = FireRules.mobTarget(mob :: any, W)
						local got: any = { kind = "mob", key = 0, body = table.create(6, 0), head = table.create(6, 0) }
						TurretWorld.fillTarget(got, mob)
						t.eq(got.key, want.key)
						t.eq(got.kind, want.kind)
						t.eq(got.zombie, want.zombie, `{kind.name} zombie`)
						t.eq(got.helmet, want.helmet, `{kind.name} {variant} helmet`)
						for i = 1, 6 do
							t.near(got.body[i], want.body[i], 1e-9, `{kind.name} body {i}`)
							t.near(got.head[i], want.head[i], 1e-9, `{kind.name} head {i}`)
						end
					end
				end
			end
		end
	)

	--[[ Targets ]]

	t.test("turret world: hostiles only: a cow nearer or in the line, a frozen zombie, never", function()
		local spec = Turrets.of("rifle", 1)
		local e = newGame()
		e.set(TX, TY, TZ, spec.block)
		local cow = e.add(COW, 0.5, FLOOR, 4.5)
		local frozen = e.add(ZOMBIE, 0.5, FLOOR, 6.5, { frozen = true })
		local zombie = e.add(ZOMBIE, 0.5, FLOOR, 12.5)
		local r = newSim(e)
		local turret = r.add(spec, nil, nil, nil, { ready = true })
		r.step(12)
		t.eq(r.state(turret).target, zombie.id, "the live zombie, past the cow and the frozen one")
		t.ok(#e.hurts > 0, "it fired")
		for _, hurt in e.hurts do
			t.eq(hurt.id, zombie.id, "only the zombie was hurt: the cow and the frozen one stand in the line")
		end
		t.eq(cow.health, 1e9)
		t.eq(frozen.health, 1e9)
		-- Only animals and sleepers: nothing, ever.
		local e2 = newGame()
		e2.add(COW, 0.5, FLOOR, 4.5)
		e2.add(ZOMBIE, 0.5, FLOOR, 8.5, { frozen = true })
		local r2 = newSim(e2)
		local idle = r2.add(spec, nil, nil, nil, { ready = true })
		r2.step(40)
		t.eq(r2.state(idle).target, 0, "no target")
		t.eq(idle.out.status, STATUS.NO_TARGET)
		t.eq(#e2.hurts, 0, "nothing hurt")
		t.eq(idle.shots, 0)
		-- A zombie that freezes is let go at once (env.mob nil).
		frozen.frozen = false
		local r3 = newSim(e)
		e.remove(zombie)
		e.remove(cow)
		local third = r3.add(spec)
		r3.step(10)
		t.eq(r3.state(third).target, frozen.id)
		frozen.frozen = true
		r3.step(1)
		t.eq(r3.state(third).target, 0, "frozen: dropped")
	end)

	t.test("turret world: nearest first, 0.05 a degree of turning: two blocks nearer but behind loses", function()
		local spec = Turrets.of("smg", 4)
		local function pick(a: { number }, b: { number }): number
			local e = newGame()
			local first = e.add(ZOMBIE, a[1], FLOOR, a[2])
			local second = e.add(ZOMBIE, b[1], FLOOR, b[2])
			local r = newSim(e)
			local turret = r.add(spec)
			r.step(10)
			local target = r.state(turret).target
			return if target == first.id then 1 elseif target == second.id then 2 else 0
		end
		-- (The gun faces +Z at first.)
		t.eq(pick({ 0.5, 10.5 }, { 0.5, 12.5 }), 1, "both ahead: the nearer")
		t.eq(pick({ 0.5, -9.5 }, { 0.5, 12.5 }), 2, "10 behind (180 degrees: +9) loses to 12 ahead")
		t.eq(pick({ 0.5, -9.5 }, { 0.5, 20.5 }), 1, "but not to 20 ahead")
		t.eq(pick({ 10.5, 0.5 }, { 0.5, 13.5 }), 2, "10 to the side (90 degrees: +4.5) loses to 13 ahead")
		t.eq(pick({ 10.5, 0.5 }, { 0.5, 15.5 }), 1, "but not to 15")
		t.eq(TurretRules.score(10, math.pi), 19, "the score")
	end)

	t.test("turret world: at most MaxSightChecks candidates are looked at a scan, best first", function()
		local spec = Turrets.of("rifle", 4)
		local function run(walled: number): (number, number, number)
			local e = newGame()
			-- A wall along z = 3 from x -10 to 10, two high: the walled ones stand behind it.
			for x = -10, 10 do
				e.set(x, FLOOR, 3, STONE)
				e.set(x, FLOOR + 1, 3, STONE)
				e.set(x, FLOOR + 2, 3, STONE)
			end
			for i = 1, walled do
				e.add(ZOMBIE, -6.5 + i, FLOOR, 5.5)
			end
			local open = e.add(ZOMBIE, 0.5, FLOOR, -20.5)
			local r = newSim(e)
			local turret = r.add(spec)
			-- (The sight checks of its first scan's tick.)
			local sights = 0
			for _ = 1, S.ScanTicks do
				r.step(1)
				local stats = TurretWorld.stats(r.world)
				if stats.scans > 0 then
					sights = stats.sights
					break
				end
			end
			local first = if r.state(turret).target == open.id then 1 else 0
			-- (And by its next scan.)
			r.step(S.ScanTicks)
			return first, sights, if r.state(turret).target == open.id then 1 else 0
		end
		local got, sights = run(5)
		t.eq(got, 1, "5 walled, the 6th in sight: taken")
		t.eq(sights, 6, "six looks")
		local next
		got, sights, next = run(6)
		t.eq(got, 0, "6 walled: the one in sight is not looked at by the first scan")
		t.eq(sights, S.MaxSightChecks, "MaxSightChecks looks")
		t.eq(next, 1, "the next scan looks past the six: taken")
	end)

	t.test("turret world: hidden ones ranked first never hide one in sight for long: a breach, a cave", function()
		-- A base's wall in front of the gun (z 4, three high) with `waiting` zombies pressing on it,
		-- and one come in through a gap 14 blocks behind the gun, in plain sight.
		local function breach(waiting: number): (number, boolean)
			local e = newGame()
			for x = -16, 16 do
				for y = FLOOR, FLOOR + 2 do
					e.set(x, y, 4, STONE)
				end
			end
			for i = 1, waiting do
				e.add(ZOMBIE, -9.5 + (i - 1) % 20, FLOOR, 5.5 + (i - 1) // 20)
			end
			local inside = e.add(ZOMBIE, 0.5, FLOOR, -13.5)
			local r = newSim(e)
			local turret = r.add(Turrets.of("rifle", 2))
			local scans = 0
			repeat
				r.step(1)
				scans += TurretWorld.stats(r.world).scans
			until r.state(turret).target == inside.id or r.tick >= 400
			return scans, r.state(turret).target == inside.id
		end
		-- (The best two every scan, the walk the rest: the k-th of a fresh walk by scan
		-- ceil((k - 2) / (MaxSightChecks - 2)).)
		for _, waiting in { 6, 10, 30 } do
			local scans, got = breach(waiting)
			local most = math.ceil((waiting + 1 - 2) / (S.MaxSightChecks - 2))
			t.ok(got and scans <= most, `{waiting} at the wall: the one inside taken by scan {scans} (at most {most})`)
		end
		-- A cave under the base (8 down, 12 out: within the pitch limits) with 8 zombies in it, and
		-- one walking in on the ground from 46 blocks, 2 blocks a second: taken as it comes in reach
		-- (two scans: the eight hidden ones first), not once it is nearer than they are.
		local e = newGame()
		for x = -16, 16 do
			for z = -16, 16 do
				for y = FLOOR - 8, FLOOR - 6 do
					e.set(x, y, z, AIR)
				end
			end
		end
		local below = {}
		for i = 1, 8 do
			local angle = i * math.pi / 4
			table.insert(below, e.add(ZOMBIE, 0.5 + math.sin(angle) * 12, FLOOR - 8, 0.5 + math.cos(angle) * 12))
		end
		local _, cavePitch = TurretRules.aim(PX, PY, PZ, TurretWorld.aimPoint(below[1], false))
		t.ok(TurretRules.inPitch(cavePitch, Turrets.of("rifle", 4)), "the cave's zombies are within the pitch limits")
		local walker = e.add(ZOMBIE, 0.5, FLOOR, 46.5)
		local r = newSim(e)
		local turret = r.add(Turrets.of("rifle", 4))
		r.each = function()
			walker.z -= 0.1
		end
		repeat
			r.step(1)
		until r.state(turret).target == walker.id or walker.z <= 3
		local least = 46 - 0.1 * (2 * S.ScanTicks)
		t.ok(walker.z - 0.5 >= least, `the walker taken at {walker.z - 0.5} blocks (at least {least})`)
		for _, mob in below do
			t.ok(r.state(turret).target ~= mob.id, "none in the cave")
		end
	end)

	t.test("turret world: every scan looks at the best two: one in sight by the gun is taken next, mid-walk", function()
		-- A base's wall in front of the gun (z 4, three high) with 30 zombies pressing on it, one in
		-- sight far behind the gun (the ranking's last), and, while the scans walk down the hidden
		-- crowd, one come in 2 blocks in front of the gun (the best): taken at the next scan, before
		-- the far one.
		local spec = Turrets.of("rifle", 2)
		local tried = 0
		for delay = 1, 80, 3 do
			local e = newGame()
			for x = -20, 20 do
				for y = FLOOR, FLOOR + 2 do
					e.set(x, y, 4, STONE)
				end
			end
			for i = 1, 30 do
				e.add(ZOMBIE, -9.5 + (i - 1) % 20, FLOOR, 5.5 + (i - 1) // 20)
			end
			e.add(ZOMBIE, 0.5, FLOOR, -18.5)
			local r = newSim(e)
			local turret = r.add(spec)
			r.step(delay)
			if r.state(turret).target == 0 then
				tried += 1
				local near = e.add(ZOMBIE, 0.5, FLOOR, 2.5)
				local scans = 0
				repeat
					r.step(1)
					scans += TurretWorld.stats(r.world).scans
				until scans >= 1
				t.eq(r.state(turret).target, near.id, `come at tick {delay}: taken at the next scan`)
			end
		end
		t.ok(tried >= 20, `mid-walk arrivals ({tried})`)
	end)

	t.test("turret world: sight is the shot's line from the pivot, through a cell's corner too", function()
		-- A zombie at a block's centre on the turret's diagonal (the line from the pivot runs exactly
		-- through cells' edges), a stone in one of the two cells the line touches there: the scan
		-- decides as a cast from the pivot does, whichever side the stone is on.
		local seen = {}
		for _, case in { { 0, 1 }, { 1, 0 } } do
			local e = newGame()
			local zombie = e.add(ZOMBIE, TX + 3.5, FLOOR, TZ + 3.5)
			local ax, ay, az = TurretWorld.aimPoint(zombie, false)
			local cy = math.floor(PY + (ay - PY) / 3)
			e.set(TX + case[1], cy, TZ + case[2], STONE)
			local blocked = FireRules.wallBetween(e.getBlock, PX, PY, PZ, ax, ay, az)
			local r = newSim(e)
			local turret = r.add(Turrets.of("rifle", 2), nil, nil, nil, { ready = true })
			r.step(60)
			local taken = r.state(turret).target == zombie.id
			t.eq(
				taken,
				not blocked,
				`stone at ({case[1]}, {cy}, {case[2]}): taken {taken}, from the pivot blocked {blocked}`
			)
			t.eq(#e.hurts > 0, taken, "shot only when seen")
			seen[blocked] = true
		end
		t.ok(seen[true] and seen[false], "one side blocks the line, the other doesn't")
	end)

	t.test("turret world: a cell the server does not hold stops its sight, so no round goes into it", function()
		for _, unloaded in { false, true } do
			local spec = Turrets.of("rifle", 2)
			local e = newGame()
			local getBlock = e.env.getBlock
			-- (Its chunk the machines read from its edit list alone: the turret, nil around it.)
			e.env.getBlock = function(x: number, y: number, z: number): number?
				if unloaded and x >= 0 and x < 16 and z >= 0 and z < 16 then
					return if x == TX and y == TY and z == TZ then spec.block else nil
				end
				return getBlock(x, y, z)
			end
			-- A zombie in the next chunk, in plain sight on open ground.
			local zombie = e.add(ZOMBIE, 0.5, FLOOR, 24.5)
			local r = newSim(e)
			local turret = r.add(spec, nil, nil, nil, { auto = true })
			r.step(200)
			if unloaded then
				t.eq(r.state(turret).target, 0, "unknown cells between: not seen")
				t.eq(turret.shots, 0, "no round spent")
				t.eq(#e.noises, 0, "no noise made")
			else
				t.eq(r.state(turret).target, zombie.id, "known: seen")
				t.ok(turret.shots > 0 and #e.hurts > 0, "and shot")
			end
		end
		-- Its own cell is air even when unknown.
		local e = newGame()
		local getBlock = e.env.getBlock
		e.env.getBlock = function(x: number, y: number, z: number): number?
			return if x == TX and y == TY and z == TZ then nil else getBlock(x, y, z)
		end
		local world = TurretWorld.new(e.env)
		t.ok(not TurretWorld.sightBlocked(world, TX, TY, TZ, PX, PY, PZ, PX + 0.4, TY + 0.2, PZ - 0.3), "its own cell")
		t.ok(TurretWorld.sightBlocked(world, 7, 70, 7, PX, PY, PZ, PX + 0.4, TY + 0.2, PZ - 0.3), "another's: unknown")
	end)

	t.test("turret world: sight stopped by blocks, glass and leaves; torches and water let it by", function()
		local spec = Turrets.of("rifle", 2)
		for _, case in
			{
				{ "Stone", false },
				{ "Glass", false },
				{ "OakLeaves", false },
				{ "Torch", true },
				{ "Water", true },
			}
		do
			local e = newGame()
			-- (Between the pivot and the zombie's body: the cells the line crosses at z 4.)
			for y = FLOOR, FLOOR + 2 do
				e.set(0, y, 4, B[case[1]])
			end
			local zombie = e.add(ZOMBIE, 0.5, FLOOR, 8.5)
			local r = newSim(e)
			local turret = r.add(spec)
			r.step(10)
			t.eq(r.state(turret).target == zombie.id, case[2], `{case[1]}: seen {case[2]}`)
		end
	end)

	t.test("turret world: its sight check is FireRules.wallBetween's, allocating nothing", function()
		-- A clutter of blocks about: stone, glass, leaves, torches, water, fences, cables, pipes.
		local e = newGame()
		local roll = rng(5)
		local names = {
			"Stone",
			"Glass",
			"OakLeaves",
			"Torch",
			"Water",
			"OakFence",
			"Planks",
			"BasicUniversalCable",
			"BasicLogisticalTransporter",
		}
		for _ = 1, 400 do
			local block = B[names[math.floor(roll() * #names) + 1]]
			e.set(math.floor(roll() * 24) - 12, FLOOR + math.floor(roll() * 4), math.floor(roll() * 24) - 12, block)
		end
		local world = TurretWorld.new(e.env)
		local differ, blocked = 0, 0
		for _ = 1, 3000 do
			local ax, ay, az = roll() * 24 - 12, FLOOR + roll() * 4, roll() * 24 - 12
			local bx, by, bz = roll() * 24 - 12, FLOOR + roll() * 4, roll() * 24 - 12
			local want = FireRules.wallBetween(e.getBlock, ax, ay, az, bx, by, bz)
			-- (No own cell here: one far away.)
			if TurretWorld.sightBlocked(world, 9999, 0, 9999, ax, ay, az, bx, by, bz) ~= want then
				differ += 1
			end
			if want then
				blocked += 1
			end
		end
		t.eq(differ, 0, "the same answers")
		t.ok(blocked > 300 and blocked < 2700, `both answers met ({blocked} of 3000 blocked)`)
		local before = collectgarbage("count")
		for _ = 1, 2000 do
			TurretWorld.sightBlocked(world, 9999, 0, 9999, -11.5, FLOOR + 0.5, -11.5, 11.5, FLOOR + 3.5, 11.5)
		end
		t.ok(collectgarbage("count") - before < 1, "nothing allocated, blocked or not")
	end)

	t.test(
		"turret world: its own cell is air (it fires down past its edge); below its lowest pitch a dead zone",
		function()
			local spec = Turrets.of("smg", 1)
			local e = newGame()
			-- On a pillar: the turret at y 64 over a pit (air under and around below it).
			local base = FLOOR
			for x = -6, 6 do
				for z = -6, 6 do
					for y = base - 4, base - 1 do
						if not (x == 0 and z == 0) then
							e.set(x, y, z, AIR)
						end
					end
				end
			end
			e.set(TX, TY, TZ, spec.block)
			e.set(TX, TY - 1, TZ, STONE)
			-- Down beside the pillar, along the diagonal: the line to it passes through the turret's
			-- own cell, by its corner (from the pivot 0.82 over the top only a line steeper than
			-- about -49 degrees does, and the SMG's lowest pitch is -60).
			local zombie = e.add(ZOMBIE, 2.5, base - 2.4, 2.5)
			local _, wantPitch = TurretRules.aim(PX, PY, PZ, TurretWorld.aimPoint(zombie, false))
			t.ok(TurretRules.inPitch(wantPitch, spec), "within the pitch limits")
			-- (The line enters the turret's own cell: x and z 0..1, y 64..65.)
			local r = newSim(e)
			local turret = r.add(spec, nil, nil, nil, { ready = true })
			r.step(30)
			t.eq(r.state(turret).target, zombie.id, "seen through its own cell")
			t.ok(#e.hurts > 0, "and shot")
			-- Hugging the pillar's foot: steeper than -60 degrees, never.
			local e2 = newGame()
			e2.blocks = e.blocks
			local hugging = e2.add(ZOMBIE, 1.4, base - 4, 0.5)
			local _, steep = TurretRules.aim(PX, PY, PZ, TurretWorld.aimPoint(hugging, false))
			t.ok(not TurretRules.inPitch(steep, spec), `the pitch {math.deg(steep)} is beyond the limits`)
			local r2 = newSim(e2)
			local second = r2.add(spec)
			r2.step(30)
			t.eq(r2.state(second).target, 0, "the dead zone")
		end
	)

	t.test("turret world: each type's own lowest pitch: at a wall's foot an SMG and a rifle reach lower", function()
		-- A turret on a 2-high wall, a zombie on the ground outside, `out` blocks from the pivot
		-- sideways: 1.5 out 64 degrees down (none), 2.0 out 57 (an SMG's and a rifle's -60, not a
		-- sniper's -51), 2.5 out 51 (every type).
		local function taken(spec: Turrets.Spec, out: number): (boolean, number)
			local e = newGame()
			for x = -3, 3 do
				for y = FLOOR, FLOOR + 1 do
					e.set(x, y, 0, STONE)
				end
			end
			local ty = FLOOR + 2
			e.set(0, ty, 0, spec.block)
			local zombie = e.add(ZOMBIE, 0.5, FLOOR, 0.5 + out)
			local r = newSim(e)
			local turret = r.add(spec, 0, ty, 0, { ready = true })
			r.step(40)
			local px, py, pz = TurretRules.pivot(0, ty, 0)
			local _, pitch = TurretRules.aim(px, py, pz, TurretWorld.aimPoint(zombie, false))
			return r.state(turret).target == zombie.id and #e.hurts > 0, math.deg(pitch)
		end
		for _, case in { { 1.5, false, false }, { 2.0, true, false }, { 2.5, true, true } } do
			for _, turretType in Turrets.TYPES do
				local spec = Turrets.of(turretType, 4)
				local got, pitch = taken(spec, case[1])
				local want = if turretType == "sniper" then case[3] else case[2]
				t.eq(got, want, `{spec.name}, the zombie {case[1]} out ({pitch} degrees): shot {want}`)
			end
		end
	end)

	t.test("turret world: every type and tier's range, MinRange, and a scope's on rifles and snipers", function()
		for _, spec in Turrets.SPECS do
			for _, optic in { 0, I.RifleScope, I.LaserSight } do
				local range = TurretRules.range(spec, optic)
				if optic == I.RifleScope and spec.type ~= "smg" then
					t.near(range, math.min(spec.range * 1.25, S.MaxRange), 1e-9, `{spec.name} scoped`)
				else
					t.eq(range, spec.range, `{spec.name} with {optic}`)
				end
				for _, case in { { range - 0.3, true }, { range + 0.3, false } } do
					local e = newGame()
					-- (The body's centre at the pivot's height: exactly the distance.)
					local zombie = e.add(ZOMBIE, 0.5, PY - 0.75, 0.5 + case[1])
					local r = newSim(e)
					local turret = r.add(spec, nil, nil, nil, { optic = optic })
					r.step(10)
					t.eq(r.state(turret).target == zombie.id, case[2], `{spec.name} optic {optic} at {case[1]}`)
				end
			end
		end
		local e = newGame()
		e.add(ZOMBIE, 0.5, PY - 0.75, 0.5 + S.MinRange - 0.2)
		local r = newSim(e)
		local turret = r.add(Turrets.of("smg", 1))
		r.step(10)
		t.eq(r.state(turret).target, 0, "nearer than MinRange: never")
	end)

	--[[ Tracking ]]

	t.test("turret world: the turn rate, the short way round, the settle before the first shot", function()
		local spec = Turrets.of("smg", 1)
		local step = spec.turn / 20
		local e = newGame()
		-- Due east (+X): yaw 90 degrees from the start's 0, at the pivot's height.
		local zombie = e.add(ZOMBIE, 10.5, PY - 0.75, 0.5)
		local r = newSim(e)
		local turret = r.add(spec, nil, nil, nil, { ready = true })
		local yaws = {}
		local firstShot = nil
		r.each = function(tick: number)
			if tick > 1 then
				local state = r.state(turret)
				table.insert(yaws, math.deg(state.yaw))
				if firstShot == nil and #e.hurts > 0 then
					firstShot = tick - 1
				end
			end
		end
		r.step(30)
		-- (It scans on its phase's tick, then turns 9 degrees a tick.)
		local moving = {}
		for i = 2, #yaws do
			local moved = yaws[i] - yaws[i - 1]
			t.ok(moved <= step + 1e-6, `never more than {step} degrees a tick ({moved})`)
			if moved > 1e-6 then
				table.insert(moving, moved)
			end
		end
		t.eq(#moving, math.ceil(90 / step), "90 degrees in 10 ticks")
		t.near(yaws[#yaws], 90, 1e-6, "on it")
		t.ok(firstShot ~= nil, "it fired")
		local state = r.state(turret)
		t.eq(state.target, zombie.id)
		-- The first shot only within `settle` degrees.
		local at = table.find(yaws, 90) or #yaws
		t.ok(firstShot >= at - 1, `not before it settled ({firstShot}, settled {at})`)
		-- The short way across +-pi: from 170 degrees to -170 is 20 degrees.
		local yaw, _ = TurretRules.turn(math.rad(170), 0, math.rad(-170), 0, math.rad(9))
		t.near(math.deg(yaw), 179, 1e-6, "through 180")
	end)

	t.test("turret world: sticky targets; lost after LoseTicks unseen, at once dead or out of range", function()
		local spec = Turrets.of("rifle", 3)
		local e = newGame()
		local far = e.add(ZOMBIE, 0.5, FLOOR, 12.5)
		local r = newSim(e)
		local turret = r.add(spec)
		r.step(10)
		t.eq(r.state(turret).target, far.id)
		local near = e.add(ZOMBIE, 0.5, FLOOR, 4.5)
		r.step(30)
		t.eq(r.state(turret).target, far.id, "sticky: never the nearer newcomer")
		-- Behind a wall: kept while unseen less than LoseTicks.
		e.remove(near)
		for x = -2, 2 do
			for y = FLOOR, FLOOR + 3 do
				e.set(x, y, 8, STONE)
			end
		end
		local kept = 0
		for _ = 1, 30 do
			r.step(1)
			if r.state(turret).target == far.id then
				kept += 1
			else
				break
			end
		end
		t.ok(
			kept >= S.LoseTicks - S.SightTicks and kept <= S.LoseTicks + S.SightTicks,
			`lost after about LoseTicks unseen ({kept})`
		)
		-- Out of range: at once.
		for x = -2, 2 do
			for y = FLOOR, FLOOR + 3 do
				e.set(x, y, 8, AIR)
			end
		end
		r.step(10)
		t.eq(r.state(turret).target, far.id, "seen again: taken again")
		far.z = 0.5 + spec.range + 2
		r.step(1)
		t.eq(r.state(turret).target, 0, "out of range: dropped at once")
		far.z = 12.5
		r.step(10)
		t.eq(r.state(turret).target, far.id)
		far.dead = true
		r.step(1)
		t.eq(r.state(turret).target, 0, "dead: dropped at once")
		t.eq(TurretWorld.stats(r.world).tracking, 0, "nothing tracked")
	end)

	t.test("turret world: no power holds still and keeps the target, blocked drops it, idle eases level", function()
		local spec = Turrets.of("sniper", 2)
		local e = newGame()
		-- Up a hill: a pitch to ease back.
		local zombie = e.add(ZOMBIE, 8.5, FLOOR + 6, 0.5)
		local r = newSim(e)
		local turret = r.add(spec)
		r.step(40)
		local state = r.state(turret)
		t.eq(state.target, zombie.id)
		t.eq(turret.out.status, STATUS.TARGETING, "armed, not firing: Targeting")
		t.ok(turret.out.tracking, "tracking")
		local yaw, pitch = state.yaw, state.pitch
		t.ok(pitch > 0.3, "aimed up the hill")
		-- No power: still, the target kept.
		turret.order.powered = false
		zombie.x = -8.5
		r.step(20)
		t.eq(turret.out.status, STATUS.NO_POWER)
		t.eq(state.target, zombie.id, "kept")
		t.eq(state.yaw, yaw, "held still")
		t.eq(state.pitch, pitch)
		t.ok(not turret.out.tracking, "no tracking energy asked while it cannot turn")
		turret.order.powered = true
		r.step(1)
		t.ok(state.yaw ~= yaw, "turning again")
		-- Blocked: dropped.
		turret.order.blocked = true
		r.step(1)
		t.eq(turret.out.status, STATUS.BLOCKED)
		t.eq(state.target, 0, "dropped")
		-- Idle: the pitch eases back level at the turn rate, the yaw held.
		turret.order.blocked = false
		zombie.dead = true
		r.step(1)
		local heldYaw, eased = state.yaw, state.pitch
		r.step(1)
		t.near(eased - state.pitch, math.rad(spec.turn) / 20, 1e-9, "a tick's turn")
		r.step(60)
		t.eq(state.pitch, 0, "level")
		t.eq(state.yaw, heldYaw, "the yaw held")
		t.eq(turret.out.status, STATUS.NO_TARGET)
		turret.order.ammo, turret.order.armed = 0, false
		r.step(1)
		t.eq(turret.out.status, STATUS.NO_AMMO, "no round, no target: No ammo")
	end)

	t.test("turret world: the status precedence: Firing after a shot, No ammo unarmed and ready, Targeting", function()
		local spec = Turrets.of("rifle", 1)
		local e = newGame()
		e.add(ZOMBIE, 0.5, FLOOR, 10.5)
		local r = newSim(e)
		local turret = r.add(spec)
		r.step(30)
		t.eq(turret.out.status, STATUS.TARGETING)
		turret.order.ready = true
		r.step(1)
		t.ok(turret.out.fired, "a shot")
		t.eq(turret.out.status, STATUS.FIRING)
		turret.order.ready = false
		turret.order.armed, turret.order.ammo = false, 0
		r.step(S.FiringTicks - 1)
		t.eq(turret.out.status, STATUS.FIRING, "Firing within FiringTicks of it, unarmed or not")
		local function flags(): number
			return r.state(turret).flags
		end
		r.step(1)
		-- Waiting on its cadence with no round (its next round on its way): Targeting.
		t.eq(turret.out.status, STATUS.TARGETING, "then, the cadence not ready, Targeting")
		t.ok(not bit32.btest(flags(), Flag.Dry), "not dry")
		turret.order.ready = true
		r.step(1)
		t.eq(turret.out.status, STATUS.NO_AMMO, "it would fire now: No ammo, the target still held")
		t.ok(turret.out.tracking)
		t.ok(bit32.btest(flags(), Flag.Dry), "dry: no round")
		-- A round but no shot's energy: No ammo, not dry.
		turret.order.ammo = 1
		r.step(1)
		t.eq(turret.out.status, STATUS.NO_AMMO)
		t.ok(not bit32.btest(flags(), Flag.Dry), "a round held: not dry")
		turret.order.armed = true
		r.step(1)
		t.ok(turret.out.fired, "armed and ready: it fires")
		turret.order.ready = false
		r.step(S.FiringTicks)
		t.eq(turret.out.status, STATUS.TARGETING)
		-- Unpowered and blocked come first whatever.
		turret.order.powered, turret.order.blocked = false, true
		r.step(1)
		t.eq(turret.out.status, STATUS.NO_POWER)
		turret.order.powered = true
		r.step(1)
		t.eq(turret.out.status, STATUS.BLOCKED)
	end)

	--[[ Firing ]]

	-- The real kind (Machines/Kinds/Turret) on a TurretWorld over `e`: `tick(n)`, the rounds kept
	-- at `keep` (refilled before each tick) when set.
	local function kindRig(spec: Turrets.Spec, e: any): any
		local container = Machines.newContainer(spec.block)
		container.data[ENERGY] = spec.capacity
		local world = TurretWorld.new(e.env)
		local r: any = { container = container, world = world, keep = nil, shots = 0 }
		r.ctx = {
			block = spec.block,
			x = TX,
			y = TY,
			z = TZ,
			energy = assert(Machines.energyOf(spec.block)),
			tick = 0,
			dayTime = 6000,
			getBlock = e.getBlock,
			turret = function(order: any, out: any): any
				return TurretWorld.step(world, order, out)
			end,
		}
		function r.tick(n: number?)
			for _ = 1, n or 1 do
				if r.keep then
					container.slots[SLOT.AMMO] = Items.newStack(spec.ammo, r.keep)
				end
				-- (Power as from a cable.)
				container.data[ENERGY] = spec.capacity
				r.ctx.tick += 1
				local before = container.slots[SLOT.AMMO]
				local count = if before then before.count else 0
				Machines.tick(container, r.ctx)
				local after = container.slots[SLOT.AMMO]
				if (if after then after.count else 0) < count then
					r.shots += 1
				end
				TurretWorld.takeShots(world)
			end
		end
		function r.state(): (number, number, boolean, boolean)
			return Turrets.unpackState(Machines.get(container, "state"))
		end
		return r
	end

	t.test("turret world: the cadence under the feeder rule through the real kind; by hand its buffer", function()
		local spec = Turrets.of("smg", 4)
		for feed = 0, 4 do
			local e = newGame()
			e.feed = feed
			e.add(ZOMBIE, 0.5, FLOOR, 10.5)
			local r = kindRig(spec, e)
			r.keep = spec.buffer
			r.tick(60)
			r.shots = 0
			r.tick(1200)
			local rpm = Turrets.rpm(spec, feed)
			t.ok(math.abs(r.shots - rpm) <= 1, `fed by tier {feed}: {r.shots} shots a minute, its rate {rpm}`)
			local _, packedFeed = r.state()
			t.eq(packedFeed, feed, "the feed in its state")
		end
		-- A change of feeder is seen within FeedTicks.
		local e = newGame()
		e.feed = 4
		local r = kindRig(spec, e)
		r.tick(1)
		local asked = e.feeds
		t.eq(asked, 1, "asked at its first tick")
		e.feed = 2
		r.tick(S.FeedTicks)
		local _, feed = r.state()
		t.eq(feed, 2, "seen within FeedTicks")
		t.eq(e.feeds, asked + 1, "asked once in FeedTicks")
		-- Hand-filled (no transporter feeds it): its own rate until the buffer is empty.
		local e2 = newGame()
		e2.add(ZOMBIE, 0.5, FLOOR, 10.5)
		local hand = kindRig(spec, e2)
		hand.container.slots[SLOT.AMMO] = Items.newStack(spec.ammo, spec.buffer)
		hand.tick(400)
		t.eq(hand.shots, spec.buffer, "its buffer")
		local status, byHand = hand.state()
		t.eq(status, STATUS.NO_AMMO, "then No ammo")
		t.eq(byHand, 0, "fed by hand")
	end)

	t.test("turret world: MaxShotsPerTick: a shot over it waits a tick, none lost", function()
		local spec = Turrets.of("rifle", 4)
		local e = newGame()
		local r = newSim(e)
		local entries = {}
		-- 40 turrets in a row, each with its zombie straight ahead, all ready on the same tick.
		for i = 1, 40 do
			local x = (i - 1) * 3
			e.add(ZOMBIE, x + 0.5, FLOOR, 10.5)
			table.insert(entries, r.add(spec, x, TY, TZ))
		end
		r.step(40)
		for _, entry in entries do
			t.ok(r.state(entry).target ~= 0, "each has its zombie")
			entry.order.ready = true
		end
		r.step(1)
		t.eq(TurretWorld.stats(r.world).shots, S.MaxShotsPerTick, "32 fired")
		local waited = {}
		for _, entry in entries do
			if not entry.out.fired then
				table.insert(waited, entry)
			end
			entry.order.ready = entry.out.fired == false
		end
		t.eq(#waited, 40 - S.MaxShotsPerTick, "8 waited")
		r.step(1)
		for _, entry in waited do
			t.ok(entry.out.fired, "fired the tick after")
		end
		-- Through the cadence: none lost over a minute, whatever the budget.
		local e2 = newGame()
		local r2 = newSim(e2)
		local list = {}
		for i = 1, 40 do
			local x = (i - 1) * 3
			e2.add(ZOMBIE, x + 0.5, FLOOR, 10.5)
			table.insert(list, r2.add(Turrets.of("smg", 4), x, TY, TZ, { auto = true }))
		end
		r2.step(40)
		for _, entry in list do
			entry.shots = 0
		end
		r2.step(1200)
		for _, entry in list do
			t.ok(math.abs(entry.shots - 360) <= 2, `each fired its rate ({entry.shots})`)
		end
	end)

	t.test("turret world: a mob killed in a tick is gone for that tick's later shots and scans", function()
		-- The fake's hurt as the mobs': a dead mob takes nothing.
		local function game(): any
			local e = newGame()
			local hurt = e.env.hurt
			e.env.hurt = function(id: number, ...): number
				local mob = e.byId[id]
				if mob and mob.dead then
					table.insert(e.hurts, { id = id, amount = 0 })
					return 0
				end
				return hurt(id, ...)
			end
			return e
		end
		-- A shot: the second turret's bullet at B flies through A, killed this tick by the first.
		local e = game()
		local b = e.add(ZOMBIE, 0.5, FLOOR, 12.5)
		local r = newSim(e)
		local second = r.add(Turrets.of("rifle", 1), 0, TY, -6)
		r.step(12)
		t.eq(r.state(second).target, b.id, "the second tracks B")
		local a = e.add(ZOMBIE, 0.5, FLOOR, 4.5, { health = 1 })
		local first = r.add(Turrets.of("smg", 1), 5, TY, 4)
		-- (The first ticks first.)
		table.remove(r.turrets)
		table.insert(r.turrets, 1, first)
		r.step(20)
		t.eq(r.state(first).target, a.id, "the first tracks A, in the second's line")
		t.eq(r.state(second).target, b.id)
		e.hurts = {}
		first.order.ready, second.order.ready = true, true
		r.step(1)
		t.eq(#e.hurts, 2, "two hits")
		t.ok(e.hurts[1].id == a.id and a.dead, "A killed")
		t.eq(e.hurts[2].id, b.id, "the second's bullet through A's body into B")
		-- A scan: one due in the tick of a kill takes the live one, not the one just killed.
		local e2 = game()
		local dying = e2.add(ZOMBIE, 0.5, FLOOR, 5.5, { health = 1 })
		local live = e2.add(ZOMBIE, 0.5, FLOOR, 9.5)
		local r2 = newSim(e2)
		local killer = r2.add(Turrets.of("smg", 4))
		r2.step(12)
		t.eq(r2.state(killer).target, dying.id)
		-- (Beside it, its first scan due on the tick of the kill, ticked after the killer.)
		local x = 2
		local due = r2.tick + 1
		while (due + (x + 7 * TY) % 997) % S.ScanTicks ~= 0 do
			due += 1
		end
		r2.step(due - 1 - r2.tick)
		local scanner = r2.add(Turrets.of("smg", 4), x, TY, TZ)
		killer.order.ready = true
		r2.step(1)
		t.ok(dying.dead, "killed")
		t.eq(TurretWorld.stats(r2.world).scans, 1, "the other's scan in the same tick")
		t.eq(r2.state(scanner).target, live.id, "it took the live one")
	end)

	-- The angle (degrees) between where a shot ended and the aim point, from the pivot.
	local function angleOff(shot: any, ax: number, ay: number, az: number): number
		local p = shot.pellets[1]
		local dx, dy, dz = p.x - PX, p.y - PY, p.z - PZ
		local ex, ey, ez = ax - PX, ay - PY, az - PZ
		local a = math.sqrt(dx * dx + dy * dy + dz * dz)
		local b = math.sqrt(ex * ex + ey * ey + ez * ez)
		return math.deg(math.acos(math.clamp((dx * ex + dy * ey + dz * ez) / (a * b), -1, 1)))
	end

	t.test("turret world: the spread: the cone's edge, a Laser Sight's half, a Suppressor's 0.9; hit rates", function()
		local spec = Turrets.of("smg", 1)
		local function fire(optic: number, muzzle: number, shots: number): (number, number)
			local e = newGame()
			-- At the range's edge, a wall just behind it.
			local zombie = e.add(ZOMBIE, 0.5, FLOOR, 0.5 + 15.4)
			for x = -6, 6 do
				for y = FLOOR, FLOOR + 6 do
					e.set(x, y, 17, STONE)
				end
			end
			local r = newSim(e)
			r.keepShots = true
			local turret = r.add(spec, nil, nil, nil, { optic = optic, muzzle = muzzle, ready = true })
			r.step(20)
			table.clear(r.shots)
			table.clear(e.hurts)
			turret.shots = 0
			r.step(shots)
			local ax, ay, az = TurretWorld.aimPoint(zombie, false)
			local widest, hits = 0, 0
			for _, shot in r.shots do
				widest = math.max(widest, angleOff(shot, ax, ay, az))
				if shot.pellets[1].hit == WeaponSync.Hit.Mob then
					hits += 1
				end
			end
			t.eq(#r.shots, shots, "a shot a tick")
			t.eq(#e.hurts, hits, "every hit hurt")
			t.eq(turret.shots, shots)
			return widest, hits / shots
		end
		local cone = spec.spread
		local widest, rate = fire(0, 0, 400)
		t.ok(widest <= cone + 0.05 and widest >= 0.85 * cone, `the cone {cone}: {widest}`)
		t.ok(rate > 0.65 and rate < 0.95, `the Basic SMG hits {rate} at its range's edge (the design: 0.84)`)
		widest, rate = fire(I.LaserSight, 0, 400)
		t.ok(widest <= cone / 2 + 0.05 and widest >= 0.85 * cone / 2, `a Laser Sight halves it: {widest}`)
		t.eq(rate, 1, "and every shot hits")
		widest = fire(0, I.Suppressor, 400)
		t.ok(widest <= cone * 0.9 + 0.05 and widest >= 0.85 * cone * 0.9, `a Suppressor's 0.9: {widest}`)
		t.near(TurretRules.spread(spec, I.LaserSight, I.Suppressor, 1), cone * 0.45, 1e-9, "both")
	end)

	t.test("turret world: damage per type, the scoped sniper's head shots, a helmet's share, knockback", function()
		local function hurts(spec: Turrets.Spec, optic: number, kind: any, variant: number): { any }
			local e = newGame()
			e.add(kind, 0.5, FLOOR, 12.5, { variant = variant })
			local r = newSim(e)
			r.add(spec, nil, nil, nil, { optic = optic, ready = true })
			r.step(60)
			return e.hurts
		end
		local round = {
			smg = (Weapons.ammo(I.Rounds9mm) :: any).damage,
			rifle = (Weapons.ammo(I.Rounds556) :: any).damage,
			sniper = (Weapons.ammo(I.Rounds308) :: any).damage,
		}
		for _, spec in { Turrets.of("smg", 1), Turrets.of("rifle", 2), Turrets.of("sniper", 1) } do
			local list = hurts(spec, 0, ZOMBIE, BARE_VARIANT)
			t.ok(#list > 0, `{spec.name} hit`)
			local hit = list[1]
			t.near(hit.amount, round[spec.type] * spec.damageScale, 1e-9, `{spec.name}'s damage`)
			t.eq(hit.head, false, "the body")
			t.eq(hit.knockback, W.BulletKnockback, "the bullet's knockback")
			t.near(hit.ox, PX, 1e-9, "from the turret")
			t.near(hit.oz, PZ, 1e-9)
		end
		t.near(round.smg * 0.85, 5.95, 1e-9, "the SMG's 5.95")
		-- A scoped sniper aims at heads: x ZombieHead through no armour (`head`), x HelmetShare under
		-- a helmet; a scoped rifle does not.
		local sniper = Turrets.of("sniper", 4)
		local list = hurts(sniper, I.RifleScope, ZOMBIE, BARE_VARIANT)
		t.ok(#list > 0)
		for _, hit in list do
			t.eq(hit.head, true, "a head shot")
			t.near(hit.amount, 24 * W.ZombieHead, 1e-9, "72")
		end
		list = hurts(sniper, I.RifleScope, HELMETED, HELMET_VARIANT)
		t.ok(#list > 0)
		t.eq(list[1].head, true)
		t.near(list[1].amount, 24 * W.ZombieHead * W.HelmetShare, 1e-9, "a helmet's share")
		list = hurts(Turrets.of("rifle", 4), I.RifleScope, ZOMBIE, BARE_VARIANT)
		t.ok(#list > 0 and list[1].head == false, "a scoped rifle: the body")
		-- A brute is tall: its body's centre, still the body.
		list = hurts(Turrets.of("rifle", 1), 0, BRUTE, 0)
		t.ok(#list > 0 and list[1].head == false, "the brute's body")
	end)

	t.test("turret world: glass is never shattered: a pane put in the line stops the shot as a block", function()
		local spec = Turrets.of("rifle", 1)
		local e = newGame()
		local zombie = e.add(ZOMBIE, 0.5, FLOOR, 10.5)
		local r = newSim(e)
		r.keepShots = true
		local turret = r.add(spec)
		r.step(20)
		t.eq(r.state(turret).target, zombie.id)
		t.eq((r.world :: any).rules.shatter, false, "its block rules shatter nothing")
		-- A pane put up between: seen until the next sight check, the shot stops in it.
		for y = FLOOR, FLOOR + 2 do
			e.set(0, y, 5, B.Glass)
		end
		turret.order.ready = true
		r.step(1)
		t.ok(turret.out.fired, "fired before it saw the pane")
		t.eq(#e.hurts, 0, "the pane took it")
		t.eq(r.shots[1].pellets[1].hit, WeaponSync.Hit.Block, "a block's hit: nothing shattered")
		t.eq(e.getBlock(0, FLOOR + 1, 5), B.Glass, "the pane stands")
	end)

	--[[ Noise ]]

	t.test("turret world: gunfire noise per type and muzzle device, once every ShotNoiseTicks, the impact's", function()
		local expected = {
			smg = { [0] = 36, [I.Suppressor] = 9, [I.ImprovisedSuppressor] = 48 * 0.45 * 0.75 },
			rifle = { [0] = 60, [I.Suppressor] = 15, [I.ImprovisedSuppressor] = 80 * 0.45 * 0.75 },
			sniper = { [0] = 72, [I.Suppressor] = 18, [I.ImprovisedSuppressor] = 96 * 0.45 * 0.75 },
		}
		for turretType, byMuzzle in expected do
			for muzzle, radius in byMuzzle do
				local spec = Turrets.of(turretType :: any, 4)
				local e = newGame()
				e.add(ZOMBIE, 0.5, FLOOR, 12.5)
				local r = newSim(e)
				local turret = r.add(spec, nil, nil, nil, { muzzle = muzzle, ready = true })
				r.step(20)
				table.clear(e.noises)
				local shots = turret.shots
				r.step(200)
				local fired = turret.shots - shots
				t.ok(fired >= 100, `{spec.name} fired ({fired})`)
				local loud, impacts = 0, 0
				for _, noise in e.noises do
					if noise.radius == W.ImpactNoise then
						impacts += 1
					else
						loud += 1
						t.near(noise.radius, radius, 1e-9, `{spec.name}'s noise with {muzzle}`)
					end
				end
				t.eq(loud, 200 // S.ShotNoiseTicks, "once every ShotNoiseTicks")
				t.eq(impacts, loud, "with its impact's (12 blocks off: farther than ImpactNoise)")
			end
		end
		-- A Ruined suppressor muffles nothing.
		local spec = Turrets.of("smg", 2)
		t.eq(TurretRules.shotNoise(spec, I.Suppressor, 0.1), 36, "ruined")
	end)

	t.test("turret world: the lure: night, armed, idle, its Lure on, one a cell an interval", function()
		local spec = Turrets.of("smg", 2)
		local lure = S.Lure
		local function lures(setup: (e: any, r: any) -> (), ticks: number): (number, any)
			local e = newGame()
			e.night = true
			local r = newSim(e)
			setup(e, r)
			r.step(ticks)
			local count = 0
			for _, noise in e.noises do
				t.eq(noise.radius, lure.Noise, "Lure.Noise (the director makes it 30 at night)")
				count += 1
			end
			return count, e
		end
		local function one(fields: any?): (e: any, r: any) -> ()
			return function(_e: any, r: any)
				local base = { lure = true }
				for key, value in fields or {} do
					base[key] = value
				end
				r.add(spec, nil, nil, nil, base)
			end
		end
		t.eq((lures(one(), lure.Ticks * 3)), 3, "every Lure.Ticks")
		t.eq((lures(one({ lure = false }), lure.Ticks * 3)), 0, "the Lure off")
		t.eq((lures(one({ armed = false, ammo = 0 }), lure.Ticks * 3)), 0, "unarmed")
		t.eq((lures(one({ powered = false }), lure.Ticks * 3)), 0, "unpowered")
		t.eq((lures(one({ blocked = true }), lure.Ticks * 3)), 0, "blocked")
		t.eq((lures(one({ muzzle = I.Suppressor }), lure.Ticks * 3)), 3, "a suppressor never quiets it")
		local count, e = lures(function(e: any, r: any)
			e.night = false
			r.add(spec, nil, nil, nil, { lure = true })
		end, lure.Ticks * 3)
		t.eq(count, 0, "by day: none")
		t.ok(e.lureAsks <= 3, "the time asked only when one is due")
		-- Tracking: none.
		t.eq((lures(function(e: any, r: any)
			e.add(ZOMBIE, 0.5, FLOOR, 10.5)
			r.add(spec, nil, nil, nil, { lure = true })
		end, lure.Ticks * 3)), 0, "a turret with a target lures nothing")
		-- Four turrets in one cell: one lure an interval; in four cells: four.
		t.eq((lures(function(_e: any, r: any)
			for i = 0, 3 do
				r.add(spec, i * 3, TY, 5, { lure = true })
			end
		end, lure.Ticks * 3)), 3, "one a cell an interval")
		t.eq((lures(function(_e: any, r: any)
			for i = 0, 3 do
				r.add(spec, i * lure.Cell + 2, TY, 5, { lure = true })
			end
		end, lure.Ticks * 3)), 12, "one in each cell")
		lure.Enabled = false
		local ok, result = pcall(lures, one(), lure.Ticks * 3)
		lure.Enabled = true
		assert(ok, result)
		t.eq(result, 0, "Lure.Enabled false: none")
	end)

	--[[ Scans and their budget ]]

	t.test("turret world: scans every ScanTicks, a Laser Sight's 5, staggered by cell; MaxScansPerTick", function()
		local spec = Turrets.of("rifle", 1)
		local function scans(optic: number): number
			local e = newGame()
			local r = newSim(e)
			r.add(spec, nil, nil, nil, { optic = optic })
			local total = 0
			for _ = 1, 100 do
				r.step(1)
				total += TurretWorld.stats(r.world).scans
			end
			return total
		end
		t.eq(scans(0), 100 // S.ScanTicks, "every ScanTicks")
		t.eq(scans(I.LaserSight), 100 // 5, "every 5 with a Laser Sight")
		-- Neighbours scan on different ticks.
		local e = newGame()
		local r = newSim(e)
		for x = 0, 9 do
			r.add(spec, x, TY, TZ)
		end
		local most = 0
		for _ = 1, 20 do
			r.step(1)
			most = math.max(most, TurretWorld.stats(r.world).scans)
		end
		t.eq(most, 1, "ten in a row: one a tick")
		-- 40 on the same phase (10 apart): 16, then 16, then 8.
		local e2 = newGame()
		local r2 = newSim(e2)
		for i = 0, 39 do
			r2.add(spec, i * 10, TY, TZ)
		end
		local counts = {}
		for _ = 1, 10 do
			r2.step(1)
			local n = TurretWorld.stats(r2.world).scans
			if n > 0 then
				table.insert(counts, n)
			end
		end
		t.eq(table.concat(counts, " "), `{S.MaxScansPerTick} {S.MaxScansPerTick} 8`, "the budget, the rest next tick")
	end)

	t.test("turret world: MaxScansPerTick: the longest waiting first, so none starves however late it ticks", function()
		-- 200 idle turrets 60 apart (no two reach the same zombie): 20 scans come due a tick, more
		-- than the budget. A zombie in front of each of the 20 the machines tick last: each is taken
		-- within ScanTicks and ceil(200 / MaxScansPerTick) ticks.
		local spec = Turrets.of("rifle", 1)
		local e = newGame()
		local r = newSim(e)
		local n, late = 200, 20
		local entries = {}
		for i = 0, n - 1 do
			entries[i + 1] = r.add(spec, i * 60, TY, 0)
		end
		r.step(40)
		for i = n - late, n - 1 do
			e.add(ZOMBIE, i * 60 + 0.5, FLOOR, 10.5)
		end
		local within = S.ScanTicks + math.ceil(n / S.MaxScansPerTick)
		local most = 0
		for _ = 1, within do
			r.step(1)
			most = math.max(most, TurretWorld.stats(r.world).scans)
		end
		local got = 0
		for i = n - late + 1, n do
			if r.state(entries[i]).target ~= 0 then
				got += 1
			end
		end
		t.eq(got, late, `all {late} taken within {within} ticks`)
		t.eq(most, S.MaxScansPerTick, "never more than the budget a tick")
	end)

	t.test("turret world: MaxShotsPerTick: every turret its share, whenever the machines tick it", function()
		-- 130 Ultimate SMGs, each with a zombie of its own, rounds without end: 39 shots wanted a
		-- tick, 32 allowed. Each fires as often as the others, the budget used every tick.
		local spec = Turrets.of("smg", 4)
		local e = newGame()
		local r = newSim(e)
		local n, ticks = 130, 600
		local entries = {}
		for i = 0, n - 1 do
			entries[i + 1] = r.add(spec, i * 60, TY, 0, { auto = true })
			e.add(ZOMBIE, i * 60 + 0.5, FLOOR, 8.5)
		end
		r.step(60)
		for _, entry in entries do
			entry.shots = 0
		end
		local total, over = 0, 0
		for _ = 1, ticks do
			r.step(1)
			local shots = TurretWorld.stats(r.world).shots
			total += shots
			if shots > S.MaxShotsPerTick then
				over += 1
			end
		end
		local least, most = math.huge, 0
		for _, entry in entries do
			least, most = math.min(least, entry.shots), math.max(most, entry.shots)
		end
		local share = S.MaxShotsPerTick * ticks / n
		t.eq(over, 0, "never more than the budget a tick")
		t.eq(total, S.MaxShotsPerTick * ticks, "the budget used every tick")
		t.ok(least >= share * 0.97 and most <= share * 1.03, `each its share of {share}: {least} to {most}`)
	end)

	--[[ Records and shots ]]

	-- A record as the client gets it (through the codec).
	local function wire(records: { any }): { any }
		return Protocol.decodeTurrets(Protocol.encodeTurrets(records)) :: { any }
	end

	t.test(
		"turret world: records when the target, flags or rounds change or the aim moves; idling sends none",
		function()
			local spec = Turrets.of("smg", 1)
			local e = newGame()
			local r = newSim(e)
			local turret = r.add(spec, nil, nil, nil, { optic = I.LaserSight, muzzle = I.Suppressor })
			r.step(1)
			local records = TurretWorld.takeRecords(r.world)
			t.eq(#records, 1, "a new turret: powered, mounted, holding rounds")
			local got = wire(records)[1]
			t.eq(got.x, TX)
			t.eq(got.y, TY)
			t.eq(got.z, TZ)
			t.eq(got.target, 0)
			t.eq(got.flags, Flag.Powered + Flag.Laser + Flag.Suppressor)
			t.eq(got.ammo, spec.buffer)
			r.step(30)
			t.eq(#TurretWorld.takeRecords(r.world), 0, "idle: nothing")
			-- A zombie: tracked, turning: records as the aim moves, at most every RecordTicks.
			local zombie = e.add(ZOMBIE, 10.5, FLOOR, 0.5)
			local sentAt = {}
			local last = nil
			for tick = 1, 40 do
				r.step(1)
				local list = TurretWorld.takeRecords(r.world)
				if #list > 0 then
					table.insert(sentAt, tick)
					last = wire(list)[1]
				end
			end
			t.ok(#sentAt >= 3, `records while it turned ({#sentAt})`)
			for i = 2, #sentAt do
				t.ok(sentAt[i] - sentAt[i - 1] >= S.RecordTicks, "at most every RecordTicks")
			end
			assert(last)
			t.eq(last.target, zombie.id, "the target")
			t.eq(bit32.band(last.flags, Flag.Tracking), Flag.Tracking, "tracking")
			t.near(last.yaw, math.pi / 2, 2 * math.pi / 65536 + 1e-6, "aimed east")
			-- Still, tracking: refreshed every RecordRefresh.
			local refreshes = 0
			for _ = 1, 100 do
				r.step(1)
				refreshes += #TurretWorld.takeRecords(r.world)
			end
			t.eq(refreshes, 100 // S.RecordRefresh, "every RecordRefresh")
			-- Its rounds change.
			turret.order.ammo = 1
			r.step(1)
			local list = wire(TurretWorld.takeRecords(r.world))
			t.eq(#list, 1)
			t.eq(list[1].ammo, 1)
			-- The target gone: the record says so (RecordTicks after the last); the easing after it
			-- sends nothing.
			e.remove(zombie)
			r.step(S.RecordTicks)
			list = wire(TurretWorld.takeRecords(r.world))
			t.eq(#list, 1)
			t.eq(list[1].target, 0, "no target")
			local more = 0
			for _ = 1, 40 do
				r.step(1)
				more += #TurretWorld.takeRecords(r.world)
			end
			t.eq(more, 0, "idling sends nothing (the client eases the same)")
		end
	)

	t.test("turret world: chunk records of turrets not idle; a broken turret forgotten", function()
		local spec = Turrets.of("rifle", 1)
		local e = newGame()
		local r = newSim(e)
		local working = r.add(spec, 1, TY, 1)
		-- A cold one (unpowered, empty) beside it, another in the next chunk but one.
		r.add(spec, 3, TY, 1, { powered = false, armed = false, ammo = 0 })
		r.add(spec, 40, TY, 1)
		r.step(2)
		local found = TurretWorld.chunkRecords(r.world, 0, 0)
		t.eq(#found, 1, "the cold one is idle: none for it")
		t.eq(found[1].x, 1)
		t.eq(#TurretWorld.chunkRecords(r.world, 2, 0), 1, "the other chunk's")
		t.eq(#TurretWorld.chunkRecords(r.world, 5, 5), 0)
		t.eq(TurretWorld.stats(r.world).turrets, 3)
		local got = wire(found)[1]
		t.eq(got.flags, Flag.Powered)
		t.eq(got.ammo, spec.buffer)
		-- Broken: forgotten, nothing more about it.
		TurretWorld.takeRecords(r.world)
		working.order.ammo = 0
		r.step(1)
		TurretWorld.blockChanged(r.world, 1, TY, 1, spec.block, AIR)
		t.eq(#TurretWorld.takeRecords(r.world), 0, "a broken turret's change is never sent")
		t.eq(TurretWorld.stats(r.world).turrets, 2)
		t.eq(#TurretWorld.chunkRecords(r.world, 0, 0), 0)
	end)

	t.test("turret world: Shots records: shooter 0, the stand-in gun, its counter, from the muzzle, plain", function()
		local function shots(spec: Turrets.Spec, muzzle: number, fraction: number): { any }
			local e = newGame()
			e.add(ZOMBIE, 0.5, FLOOR, 10.5)
			local r = newSim(e)
			r.keepShots = true
			r.add(spec, nil, nil, nil, { muzzle = muzzle, muzzleFraction = fraction, ready = true })
			local seen = {}
			r.each = function()
				local state = (r.world :: any).turrets[Coords.posKey(TX, TY, TZ)]
				if state then
					seen.yaw, seen.pitch = state.yaw, state.pitch
				end
			end
			r.step(40)
			local list = r.shots
			t.ok(#list > 3, "fired")
			return list
		end
		local spec = Turrets.of("smg", 3)
		local list = shots(spec, 0, 1)
		local decoded = WeaponSync.decodeShots(WeaponSync.encodeShots(list)) :: { any }
		t.eq(#decoded, #list, "the codec's round trip")
		for i, shot in decoded do
			t.eq(shot.shooter, 0, "no player")
			t.eq(shot.item, spec.firearm, "the stand-in gun")
			t.eq(shot.shot, i, "its own counter")
			t.eq(shot.suppressed, false)
			t.eq(shot.plain, false)
			t.eq(shot.refused, false)
			t.eq(#shot.pellets, 1)
			t.eq(shot.pellets[1].hit, WeaponSync.Hit.Mob)
			-- From the muzzle: the barrel's length out from the pivot.
			local dx, dy, dz = shot.ox - PX, shot.oy - PY, shot.oz - PZ
			t.near(math.sqrt(dx * dx + dy * dy + dz * dz), spec.barrel, 1e-4, "the muzzle")
			t.ok(dz > 0.6, "towards the zombie")
		end
		local suppressed = shots(spec, I.Suppressor, 1)[1]
		t.ok(suppressed.suppressed and suppressed.plain, "a Suppressor: suppressed, plain (no glow)")
		local improvised = shots(spec, I.ImprovisedSuppressor, 1)[1]
		t.ok(improvised.suppressed and not improvised.plain, "improvised: suppressed, its tracer glows")
		local ruined = shots(spec, I.Suppressor, 0.1)[1]
		t.ok(not ruined.suppressed and not ruined.plain, "a Ruined one: neither")
		local round = WeaponSync.decodeShots(WeaponSync.encodeShots({ suppressed })) :: { any }
		t.eq(round[1].plain, true, "plain on the wire")
	end)

	--[[ Cost ]]

	local function median(runs: { number }): number
		table.sort(runs)
		return runs[(#runs + 1) // 2]
	end

	--[[
		A fight: 50 turrets (every type and tier, a few with optics and suppressors) in a 10 x 5
		block of a base, 3 apart, and 100 zombies (every kind) walking in from 14 to 40 blocks
		out, a zombie killed coming back at the edge; the kind's cadence kept for each turret.
		`walled`: a siege instead, a ring of stone three high 17 blocks round the base with the
		zombies held outside it, so every turret scans and every sight check fails. `columns` x
		`lines` turrets and `count` zombies another size (the ring 2 blocks past the base's
		corners). Returns the step (one machine tick of every turret and the zombies' walk) and the
		simulation.
	]]
	local function fight(walled: boolean?, columns: number?, lines: number?, count: number?): (() -> (), any)
		local e = newGame()
		local roll = rng(99)
		local zombies = {}
		local kinds = {}
		for _, kind in MobList.kinds do
			if MobList.isZombie(kind) then
				table.insert(kinds, kind)
			end
		end
		local wide, deep = columns or 10, lines or 5
		local cx, cz = (wide - 1) * 1.5, (deep - 1) * 1.5 + 0.5
		local ring = math.ceil(math.sqrt(cx * cx + cz * cz) + 2)
		local stop = if walled then ring + 1.5 else ring - 5
		if walled then
			for x = math.floor(cx) - ring - 2, math.ceil(cx) + ring + 2 do
				for z = math.floor(cz) - ring - 2, math.ceil(cz) + ring + 2 do
					local d = math.sqrt((x + 0.5 - cx) ^ 2 + (z + 0.5 - cz) ^ 2)
					if d >= ring and d < ring + 1 then
						for y = FLOOR, FLOOR + 3 do
							e.set(x, y, z, STONE)
						end
					end
				end
			end
		end
		local function place(mob: any, i: number)
			local angle = i * 2.399 + roll()
			local distance = (if walled then ring + 2 else ring - 3) + (i % 27)
			mob.x, mob.z = cx + math.cos(angle) * distance, cz + math.sin(angle) * distance
			mob.y = FLOOR
			mob.health = 40
			mob.dead = false
		end
		for i = 1, count or 100 do
			local mob = e.add(kinds[(i - 1) % #kinds + 1], 0, FLOOR, 0)
			place(mob, i)
			zombies[i] = mob
		end
		local r = newSim(e)
		local optics = { 0, 0, I.LaserSight, 0, I.RifleScope }
		local muzzles = { 0, I.Suppressor, 0, I.ImprovisedSuppressor }
		local n = 0
		for gx = 0, wide - 1 do
			for gz = 0, deep - 1 do
				n += 1
				local spec = Turrets.SPECS[(n - 1) % #Turrets.SPECS + 1]
				local optic = optics[n % #optics + 1]
				if not spec.optics[optic] then
					optic = 0
				end
				r.add(spec, gx * 3, TY, gz * 3, { auto = true, optic = optic, muzzle = muzzles[n % #muzzles + 1] })
			end
		end
		r.each = function()
			-- They walk in a little a tick; the dead come back at the edge.
			for i, mob in zombies do
				if mob.dead then
					place(mob, i + r.tick)
				else
					local dx, dz = cx - mob.x, cz - mob.z
					local d = math.sqrt(dx * dx + dz * dz)
					if d > stop then
						mob.x += dx / d * 0.1
						mob.z += dz / d * 0.1
					end
					mob.yaw = math.atan2(dx, dz)
				end
			end
		end
		r.step(40)
		return function()
			r.step(1)
		end, r
	end

	--[[
		Costs (the design's budget for 50 turrets and 100 zombies in a fight: 1.5 ms native, 4
		interpreted, a machine tick, held to the siege and to the blood moon's siege too: 150
		turrets, 260 zombies; Lune, the median of 3 runs of 200 ticks, the budget and 15%, a miss
		measured again with the median of 5). Measured on this shared 4 core machine (load 2,
		other builders' runs alongside), native / NOCODEGEN=1:
		  the fight   0.38-0.57 / 0.85 ms (0.8 scans, 12 sight checks, 4.3 shots, 46 tracking a tick)
		  the siege   see the spec's print (every turret scanning, every sight check failing)
		Allocated: nothing a tick while tracking, nothing in the siege (scans, sight checks
		blocked); 4.8 KB a tick in the fight (the trace's impacts: about 1.1 KB a shot).
	]]
	t.test(
		"turret world: cost: 50 turrets and 100 zombies in a fight and a siege, the blood moon's siege; nothing allocated",
		function()
			-- ms a machine tick (every turret's step and the fakes' walk), the median of `runs`.
			local function cost(case: any, ticks: number, runs: number): (number, any)
				local times, last = {}, nil
				for _ = 1, runs do
					local step, r = fight(case.walled, case.columns, case.lines, case.count)
					local start = os.clock()
					for _ = 1, ticks do
						step()
					end
					table.insert(times, (os.clock() - start) / ticks * 1000)
					last = r
				end
				return median(times), last
			end
			local budget = if NATIVE then 1.5 else 4
			local limit = budget * 1.15
			local r: any, siege: any = nil, nil
			for _, case in
				{
					{ label = "50 turrets, 100 zombies, a fight", walled = false },
					{ label = "50 turrets, 100 zombies, a siege", walled = true },
					{
						label = "150 turrets, 260 zombies, a siege",
						walled = true,
						columns = 15,
						lines = 10,
						count = 260,
					},
				}
			do
				local walled, label = case.walled, case.label
				local ms, last = cost(case, 200, 3)
				local again = ""
				if ms > limit then
					ms = math.min(ms, (cost(case, 200, 5)))
					again = ", measured again"
				end
				-- What a tick does (the last run's next 100 ticks).
				local scans, sights, shots, tracking = 0, 0, 0, 0
				for _ = 1, 100 do
					last.step(1)
					local stats = TurretWorld.stats(last.world)
					scans += stats.scans
					sights += stats.sights
					shots += stats.shots
					tracking += stats.tracking
				end
				print(
					string.format(
						"         %s: %.3f ms a tick (budget %.1f, %s%s); a tick %.1f scans, %.1f sight checks, %.1f shots, %.1f tracking",
						label,
						ms,
						budget,
						if NATIVE then "native" else "NOCODEGEN",
						again,
						scans / 100,
						sights / 100,
						shots / 100,
						tracking / 100
					)
				)
				t.ok(ms <= limit, `{label}: {ms} ms (at most {limit})`)
				if walled then
					t.eq(shots, 0, "the siege: nothing seen, nothing fired")
					t.ok(sights >= scans * 5, "every scan looks at its best few")
					siege = siege or last
				else
					t.ok(shots > 100, "a fight: shots every tick")
					r = last
				end
			end
			-- Allocation: tracking and scanning without shots (none ready), then firing.
			for _, entry in r.turrets do
				entry.auto = false
				entry.order.ready = false
			end
			r.step(20)
			local before = collectgarbage("count")
			r.step(200)
			local idle = (collectgarbage("count") - before) / 200
			for _, entry in r.turrets do
				entry.auto = true
			end
			r.step(20)
			-- (Tick by tick, the median: a collection in between doesn't count.)
			local deltas = {}
			for _ = 1, 100 do
				before = collectgarbage("count")
				r.step(1)
				table.insert(deltas, collectgarbage("count") - before)
			end
			local firing = median(deltas)
			before = collectgarbage("count")
			siege.step(200)
			local scanning = (collectgarbage("count") - before) / 200
			print(
				string.format(
					"         allocated: %.3f KB a tick tracking without shots, %.3f KB a tick in the siege, %.2f KB a tick in the fight",
					idle,
					scanning,
					firing
				)
			)
			t.ok(idle < 0.5, `nothing allocated tracking ({idle} KB a tick)`)
			t.ok(scanning < 0.5, `nothing allocated scanning and failing sight checks ({scanning} KB a tick)`)
		end
	)

	--[[ The glue: server Turrets/Turrets and Mobs/Mobs on fakes of Roblox ]]

	--[[
		Mobs/Mobs (real, with MobWorld, MobSpawning, MobTracking, the director and NoiseBus) and
		Turrets/Turrets (real, with TurretWorld) under fakes of Roblox and of the server modules
		that are Roblox glue; a flat world. `h.tick(n)` runs n mob ticks (Heartbeat), `h.join(x, y,
		z)` adds a player, `h.order(spec)` the order of a turret at T, `h.serve(order)` asks the
		service the glue registered.
	]]
	local function glue(enabled: boolean?): any
		local h: any = { time = 18000, players = {}, sent = {}, service = nil, chunks = {} }
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
				return { Triggered = fakeSignal(), SetAttribute = function() end }
			end,
		}
		local fakeRandom = {
			new = function()
				local roll = rng(23)
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
		local function getBlock(_x: number, y: number, _z: number): number?
			if y < 0 or y >= 1024 then
				return nil
			end
			return if y < FLOOR then STONE else AIR
		end
		local positions = stub({
			feet = function(p: any)
				return p.x, p.y, p.z
			end,
			networked = function()
				return true
			end,
		})
		local timeOfDay = stub({
			get = function()
				return h.time
			end,
		})
		local root = {
			World = {
				WorldServer = stub({}),
				Simulation = stub({
					activeChunks = function()
						local chunks = {}
						for cx = -2, 2 do
							for cz = -2, 2 do
								table.insert(chunks, { cx = cx, cz = cz })
							end
						end
						return chunks
					end,
				}),
				Skylight = stub({
					open = function()
						return true
					end,
					clear = function()
						return true
					end,
				}),
				TimeOfDay = timeOfDay,
				WeatherServer = stub({
					rainingAt = function()
						return false
					end,
					isDayAt = function(_x: number, _z: number, dayTime: number)
						return DayCycle.isDay(dayTime)
					end,
				}),
			},
			Audio = {
				Sounds = stub({
					play = function() end,
					playBlock = function() end,
					allow = function()
						return true
					end,
				}),
			},
			Entities = {
				Entities = stub({
					spawnItem = function(stack: any)
						h.drops = (h.drops or 0) + stack.count
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
				PlayerPositions = positions,
				ToughAsNails = stub({
					attacked = function() end,
				}),
			},
			Apocalypse = { NoiseBus = server.Apocalypse.NoiseBus },
			Machines = {
				Machines = stub({
					knownBlock = getBlock,
					setTurretService = function(service: any)
						h.service = service
					end,
				}),
			},
			Transmitters = {
				Transmitters = stub({
					world = function()
						return nil
					end,
				}),
				TransmitterWorld = server.Transmitters.TransmitterWorld,
			},
		}
		local function glueRequire(node: any): any
			local module = if type(node) == "table" then rawget(node, "__stub") else nil
			if module then
				return module
			end
			return require(node)
		end
		local mobsFolder = {
			Parent = root,
			MobWorld = server.Mobs.MobWorld,
			MobSpawning = server.Mobs.MobSpawning,
			MobTracking = server.Mobs.MobTracking,
			SummonCommand = server.Mobs.SummonCommand,
			ZombieDirector = server.Mobs.ZombieDirector,
		}
		local mobsChunk = luau.load(
			withHeader(
				fs.readFile("src/server/Mobs/Mobs.luau"),
				"script, require, game, Instance, Random, Enum, typeof"
			),
			{ debugName = "Mobs" }
		)
		local Mobs =
			mobsChunk({ Parent = mobsFolder }, glueRequire, fakeGame, fakeInstance, fakeRandom, fakeEnum, fakeTypeof)
		root.Mobs = { Mobs = stub(Mobs) }
		local turretsFolder = { Parent = root, TurretWorld = server.Turrets.TurretWorld }
		local turretsChunk = luau.load(
			withHeader(fs.readFile("src/server/Turrets/Turrets.luau"), "script, require, game, Random"),
			{ debugName = "Turrets" }
		)
		local Glue = turretsChunk({ Parent = turretsFolder }, glueRequire, fakeGame, fakeRandom)
		local fakeWorld = {
			generator = {
				cityAt = function()
					return 0
				end,
			},
			peekBlock = function(_, x: number, y: number, z: number)
				return getBlock(x, y, z)
			end,
			setBlock = function()
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
		local was = Config.Turrets.Enabled
		if enabled == false then
			Config.Turrets.Enabled = false
		end
		local ok, err = pcall(Glue.start, net, fakeWorld)
		Config.Turrets.Enabled = was
		assert(ok, err)
		h.Mobs, h.Glue = Mobs, Glue
		-- (No natural spawning: only the specs' mobs.)
		function h.tick(n: number)
			local spawning = Config.Mobs.Spawning
			Config.Mobs.Spawning = false
			local ok, err = pcall(function()
				for _ = 1, n do
					heartbeat.fire(1 / 20)
				end
			end)
			Config.Mobs.Spawning = spawning
			assert(ok, err)
		end
		function h.join(x: number, y: number, z: number): any
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
				GetAttribute = function()
					return nil
				end,
			}
			table.insert(h.players, fake)
			return fake
		end
		h.machineTick = 0
		function h.serve(order: any): any
			h.machineTick += 1
			order.tick = h.machineTick
			return h.service(order, { status = STATUS.NO_TARGET, fired = false, tracking = false, feed = 0 })
		end
		-- The messages of `kind` sent to `player` since the last look, taken.
		function h.take(player: any, kind: number): { buffer }
			local found, rest = {}, {}
			for _, message in h.sent do
				if message.player == player and message.kind == kind then
					table.insert(found, message.payload)
				else
					table.insert(rest, message)
				end
			end
			h.sent = rest
			return found
		end
		return h
	end

	t.test("turret glue: Mobs.hostiles and Mobs.target: monsters only, awake, the tables reused", function()
		local h = glue()
		local Mobs = h.Mobs
		h.join(0.5, FLOOR, 0.5)
		local zombie = Mobs.spawn("Zombie", 4.5, FLOOR, 0.5)
		local cow = Mobs.spawn("Cow", 6.5, FLOOR, 0.5)
		-- Far beyond the ticking chunks: frozen after a tick.
		local sleeper = Mobs.spawn("Zombie", 300.5, FLOOR, 0.5)
		t.ok(zombie ~= 0 and cow ~= 0 and sleeper ~= 0, "spawned")
		h.tick(2)
		local list = {}
		local n = Mobs.hostiles(list)
		t.eq(n, 1, "the zombie only: not the cow, not the frozen one")
		t.eq(list[1].id, zombie)
		t.eq(list[1].kind.name, "Zombie")
		local entry = list[1]
		t.eq(Mobs.hostiles(list), 1)
		t.eq(list[1], entry, "the same table again")
		local before = collectgarbage("count")
		for _ = 1, 1000 do
			Mobs.hostiles(list)
		end
		t.ok(collectgarbage("count") - before < 4, "nothing allocated")
		local into = {}
		t.eq(Mobs.target(zombie, into), into, "filled into the table given")
		t.eq(into.id, zombie)
		t.eq(Mobs.target(cow), nil, "a cow is no target")
		t.eq(Mobs.target(sleeper), nil, "a frozen zombie is none")
		t.eq(Mobs.target(9999), nil)
		local fresh = Mobs.target(zombie)
		t.ok(fresh ~= nil and fresh ~= into, "a new table without one")
	end)

	t.test(
		"turret glue: a shot hurts through Mobs.weaponDamage crediting nobody; records and shots to the near",
		function()
			local h = glue()
			local Mobs = h.Mobs
			local near = h.join(4.5, FLOOR, 4.5)
			local inRecords = h.join(TX + 0.5 + S.RecordRange - 1, FLOOR, 0.5)
			local far = h.join(TX + 0.5 + math.max(W.ShotBroadcast, S.RecordRange) + 10, FLOOR, 0.5)
			-- A player standing in the line of fire: never a target, never hit.
			local inLine = h.join(0.5, FLOOR, 5.5)
			local id = Mobs.spawn("Zombie", 0.5, FLOOR, 10.5)
			h.tick(2)
			local deaths = {}
			Mobs.died:Connect(function(killer: any, kind: string)
				table.insert(deaths, { killer = killer, kind = kind })
			end)
			local spec = Turrets.of("sniper", 4)
			local order = newOrder(spec)
			order.optic = I.RifleScope
			local mob = (Mobs.world() :: any):get(id)
			local health = mob.health
			local fired = 0
			for _ = 1, 60 do
				order.ready = true
				local out = h.serve(order)
				if out.fired then
					fired += 1
					break
				end
			end
			t.eq(fired, 1, "it fired")
			t.ok(mob.health < health or mob.dead, "the zombie was hurt")
			t.eq(mob.attacker, nil, "nobody credited")
			h.tick(30)
			t.eq(#deaths, 1, "a head shot of a .308 kills a zombie")
			t.eq(deaths[1].killer, nil, "no killer")
			-- The NoiseBus hears the next shot (the mobs' tick takes it: none runs here), the
			-- turret's noise cooldown over.
			Mobs.spawn("Zombie", 0.5, FLOOR, 12.5)
			h.tick(1)
			order.ready = false
			for _ = 1, S.ShotNoiseTicks do
				h.serve(order)
			end
			NoiseBus.take()
			order.ready = true
			order.optic = 0
			for _ = 1, 60 do
				local out = h.serve(order)
				if out.fired then
					break
				end
			end
			local heard = NoiseBus.take()
			t.ok(#heard >= 1, "the shot's noise on the NoiseBus")
			local loud = false
			for _, noise in heard do
				if noise.radius == TurretRules.shotNoise(spec, 0, 1) then
					loud = true
				end
			end
			t.ok(loud, "its radius: the sniper's 72")
			-- update: records within RecordRange, shots within ShotBroadcast (what came before sent).
			h.Glue.update(1 / 20)
			h.sent = {}
			Mobs.spawn("Zombie", 0.5, FLOOR, 12.5)
			h.tick(1)
			order.ready = true
			local shotFired = false
			for _ = 1, 60 do
				local out = h.serve(order)
				if out.fired then
					shotFired = true
					break
				end
			end
			t.ok(shotFired, "another shot")
			h.Glue.update(1 / 20)
			local shots = h.take(near, Protocol.ServerMessage.Shots)
			t.eq(#shots, 1, "the near player gets the shot")
			local decoded = WeaponSync.decodeShots(shots[1]) :: { any }
			t.eq(#decoded, 1, "this frame's shot")
			t.eq(decoded[1].shooter, 0)
			t.eq(decoded[1].item, spec.firearm)
			t.eq(decoded[1].pellets[1].hit, WeaponSync.Hit.Mob, "through the player in the line, into the zombie")
			t.ok(decoded[1].pellets[1].z > 11, "beyond the player")
			t.eq(#h.take(inLine, Protocol.ServerMessage.Shots), 1, "who sees it")
			t.eq(#h.take(far, Protocol.ServerMessage.Shots), 0, "beyond ShotBroadcast: none")
			t.eq(#h.take(inRecords, Protocol.ServerMessage.Shots), 1, "within ShotBroadcast")
			local records = h.take(near, Protocol.ServerMessage.Turrets)
			t.eq(#records, 1, "the near player gets the records")
			local got = (Protocol.decodeTurrets(records[1]) :: { any })[1]
			t.eq(got.x, TX)
			t.ok(bit32.band(got.flags, Flag.Powered) ~= 0)
			t.eq(#h.take(inRecords, Protocol.ServerMessage.Turrets), 1, "within RecordRange")
			t.eq(#h.take(far, Protocol.ServerMessage.Turrets), 0, "beyond: none")
			-- A chunk's edit list: its records.
			h.Glue.sendChunks(far, { { 0, 0 }, { 3, 3 } })
			local chunk = h.take(far, Protocol.ServerMessage.Turrets)
			t.eq(#chunk, 1, "the chunk's records")
			t.eq(#(Protocol.decodeTurrets(chunk[1]) :: { any }), 1)
			h.Glue.sendChunks(far, { { 3, 3 } })
			t.eq(#h.take(far, Protocol.ServerMessage.Turrets), 0, "none where none stands")
			-- Broken: forgotten.
			h.Glue.blockChanged(TX, TY, TZ, spec.block, AIR)
			t.eq(TurretWorld.stats(h.Glue.world()).turrets, 0, "forgotten")
		end
	)

	t.test(
		"turret glue: records reach every chunk a client keeps them for, and a player whose feet are unknown",
		function()
			local h = glue()
			local spec = Turrets.of("smg", 1)
			local order = newOrder(spec)
			order.optic = I.LaserSight
			local function serve(ticks: number)
				for _ = 1, ticks do
					h.serve(order)
					h.Glue.update(1 / 20)
				end
			end
			local function flags(player: any): { number }
				local found = {}
				for _, payload in h.take(player, Protocol.ServerMessage.Turrets) do
					for _, record in Protocol.decodeTurrets(payload) :: { any } do
						table.insert(found, record.flags)
					end
				end
				return found
			end
			-- A client keeps a chunk's records while it holds its data or its edit list: its full
			-- detail chunks' and their neighbours' (Streaming/ChunkStreamer, around its feet). The
			-- farthest such turret (sideways) at the highest Full Detail, Detail Falloff and Cave
			-- View: within RecordRange, and one sent its records from there gets the changes.
			local LodTree = require(shared.World.LodTree)
			local PlayerSettings = require(shared.PlayerSettings)
			local highest: any = {}
			for _, entry in PlayerSettings.ENTRIES do
				highest[entry.key] = entry.max
			end
			LodTree.configure(PlayerSettings.lod(highest))
			local reach = 0
			for _, underground in { false, true } do
				for key, level in LodTree.select(0.5, 0.5, nil, underground) do
					if level == 0 then
						local _, nx, nz = Coords.decodeNodeKey(key)
						for _, cell in { (nx - 1) * 16, (nx + 2) * 16 - 1, (nz - 1) * 16, (nz + 2) * 16 - 1 } do
							reach = math.max(reach, math.abs(cell))
						end
					end
				end
			end
			local lod = Config.Lod
			LodTree.configure(lod.ViewDistance, lod.SplitDistance, lod.SplitDistanceL1, lod.UndergroundSplitDistanceL1)
			t.ok(reach > 96 and S.RecordRange >= reach, `a kept record {reach} blocks off, within {S.RecordRange}`)
			local away = h.join(TX + 0.5 + reach, FLOOR, 0.5)
			-- Another near, then dying: its feet unknown while it respawns.
			local near = h.join(4.5, FLOOR, 4.5)
			serve(4)
			h.Glue.sendChunks(away, { { 0, 0 } })
			local sent = flags(away)
			t.ok(#sent >= 1 and bit32.btest(sent[#sent], Flag.Powered), "the chunk's record: powered")
			t.ok(#flags(near) >= 1, "the near one's")
			near.x = nil
			order.powered = false
			order.ammo, order.held, order.armed = 0, 0, false
			serve(10)
			local after = flags(away)
			t.ok(#after >= 1 and not bit32.btest(after[#after], Flag.Powered), `{reach} blocks off: the change came`)
			local respawning = flags(near)
			t.ok(
				#respawning >= 1 and not bit32.btest(respawning[#respawning], Flag.Powered),
				"feet unknown: sent by where it was last seen"
			)
		end
	)

	t.test("turret glue: the lure's time is night or a blood moon; switched off nothing starts", function()
		local h = glue()
		local spec = Turrets.of("smg", 1)
		local order = newOrder(spec)
		order.lure = true
		NoiseBus.take()
		-- Night (18000: midnight): a lure within Lure.Ticks.
		for _ = 1, S.Lure.Ticks do
			h.serve(order)
		end
		local heard = NoiseBus.take()
		t.eq(#heard, 1, "one lure")
		t.eq(heard[1].radius, S.Lure.Noise)
		-- Noon: none.
		h.time = 6000
		for _ = 1, S.Lure.Ticks * 2 do
			h.serve(order)
		end
		t.eq(#NoiseBus.take(), 0, "by day: none")
		-- Off: no service, no world, nothing sent.
		local off = glue(false)
		t.eq(off.service, nil, "no service")
		t.eq(off.Glue.world(), nil, "no simulation")
		local player = off.join(0.5, FLOOR, 0.5)
		off.Glue.update(1 / 20)
		off.Glue.sendChunks(player, { { 0, 0 } })
		t.eq(#off.sent, 0, "nothing sent")
	end)
end

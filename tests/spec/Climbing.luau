--[[
	Climbing and cobwebs, tick for tick against Minecraft 1.20.1 (Shared/Movement/PlayerPhysics,
	Shared/Entities/MobPhysics): LivingEntity.onClimbable / handleOnClimbable /
	handleRelativeFrictionAndCalculateMovement on ladders and vines (0.1176 blocks a tick up
	pushing into the wall or holding jump, 0.15 down, 0.15 sideways, sneaking holds), Supplementaries'
	rope (a free-fall slide that never hurts, jump to climb it), climbing out of water, spectators
	and flight, the top of a ladder, Entity.makeStuckInBlock in cobwebs (x 0.25 / x 0.05 for one
	move, the velocity zeroed, the fall forgotten), and mobs: they climb a ladder they walk into,
	cobwebs slow them, but not spiders.
]]

return function(t, shared, require)
	local Blocks = require(shared.Blocks)
	local PlayerPhysics = require(shared.Movement.PlayerPhysics)
	local MobList = require(shared.Entities.MobList)
	local MobPhysics = require(shared.Entities.MobPhysics)
	local GameMode = require(shared.GameMode)

	local B = Blocks.id
	local STONE, AIR = B.Stone, Blocks.AIR
	local LADDER, VINE, ROPE, COBWEB = B.Ladder, B.Vine, B.Rope, B.Cobweb
	local WATER = Blocks.fluidId("Water", 0)

	-- Minecraft's numbers: 0.2 after the move, minus gravity, times the vertical drag.
	local CLIMB_UP = (0.2 - 0.08) * 0.98
	local SLIDE = 0.15000000596046448 -- 0.15F

	-- A world from a function of (x, y, z) -> block; stone below y = 1 by default.
	local function physicsWorld(f: ((x: number, y: number, z: number) -> number?)?): PlayerPhysics.World
		return {
			getBlock = function(x: number, y: number, z: number): number?
				local block = if f then f(x, y, z) else nil
				if block then
					return block
				end
				return if y <= 0 then STONE else AIR
			end,
		}
	end
	local function input(moveX: number, moveZ: number, options: { [string]: any }?): PlayerPhysics.Input
		local o = options or {}
		local length = math.sqrt(moveX * moveX + moveZ * moveZ)
		return {
			moveX = moveX,
			moveZ = moveZ,
			forward = if o.forward ~= nil then o.forward else length,
			facingX = if length > 0 then moveX / length else 0,
			facingZ = if length > 0 then moveZ / length else 1,
			lookY = o.lookY or 0,
			jump = o.jump == true,
			sneak = o.sneak == true,
			sprint = o.sprint == true,
		}
	end

	--[[
		A wall of stone at z = 3 (x -2..2, y 1..top) with `block` hanging on it at x = 0, z = 2 for
		y 1..climbTop (a Ladder or a Vine faces north: its wall is to its south, +Z).
	]]
	local function wallWorld(block: number, top: number, climbTop: number): PlayerPhysics.World
		return physicsWorld(function(x, y, z)
			if z == 3 and x >= -2 and x <= 2 and y >= 1 and y <= top then
				return STONE
			end
			if x == 0 and z == 2 and y >= 1 and y <= climbTop then
				return block
			end
			return nil
		end)
	end
	-- A rope hanging at (0, 1..bottom.., 0) from a stone ceiling at y = top + 1.
	local function ropeWorld(top: number): PlayerPhysics.World
		return physicsWorld(function(x, y, z)
			if x == 0 and z == 0 then
				if y == top + 1 then
					return STONE
				elseif y >= 1 and y <= top then
					return ROPE
				end
			end
			return nil
		end)
	end

	t.test("climbing: pushing into a ladder climbs at a steady 0.1176 blocks a tick (2.35 m/s)", function()
		local world = wallWorld(LADDER, 20, 19)
		local state = PlayerPhysics.new(0.5, 1, 2.5)
		state.onGround = true
		local push = input(0, 1)
		local ys = {}
		for tick = 1, 60 do
			PlayerPhysics.tick(state, push, world)
			ys[tick] = state.y
			t.eq(state.fallDistance, 0, `no fall while climbing (tick {tick})`)
		end
		t.ok(state.climbing, "climbing")
		t.near(state.z, 3 - 0.3, 1e-9, "pressed against the wall")
		for tick = 10, 60 do
			t.near(ys[tick] - ys[tick - 1], CLIMB_UP, 1e-9, `0.1176 up at tick {tick}`)
		end
		local perSecond = (ys[60] - ys[40]) / 20 * PlayerPhysics.TICK_RATE
		t.near(perSecond, 2.352, 1e-6, "2.352 blocks a second")
		t.near(state.vy, CLIMB_UP, 1e-9, "the speed carried into the next tick")
	end)

	t.test("climbing: holding jump climbs a free-hanging rope", function()
		local world = ropeWorld(30)
		local state = PlayerPhysics.new(0.5, 1, 0.5)
		state.onGround = true
		local jump = input(0, 0, { jump = true })
		local ys = {}
		for tick = 1, 60 do
			local events = PlayerPhysics.tick(state, jump, world)
			ys[tick] = state.y
			if tick == 1 then
				t.ok(events.jumped, "jumps off the floor first (0.42)")
				t.near(state.y, 1.42, 1e-9, "the jump's own rise")
			end
		end
		for tick = 5, 60 do
			t.near(ys[tick] - ys[tick - 1], CLIMB_UP, 1e-9, `0.1176 up at tick {tick}`)
		end
		t.ok(state.climbing and not state.horizontalCollision, "no wall to push: jump alone climbs")
		-- Let go: down it slides in free fall.
		local free = PlayerPhysics.new(0.5, 1, 0.5)
		free.onGround = true
		for _ = 1, 60 do
			PlayerPhysics.tick(free, input(0, 0), world)
		end
		t.eq(free.y, 1, "without jump nothing climbs")
	end)

	t.test("climbing: a ladder slide is held to 0.15 blocks a tick, and so is a vine's", function()
		for _, block in { LADDER, VINE } do
			local world = wallWorld(block, 20, 19)
			local state = PlayerPhysics.new(0.5, 15, 2.7)
			local ys = {}
			for tick = 1, 30 do
				PlayerPhysics.tick(state, input(0, 0), world)
				ys[tick] = state.y
				t.ok(state.fallDistance <= SLIDE + 1e-9, "the fall distance never gathers")
			end
			for tick = 3, 30 do
				t.near(ys[tick] - ys[tick - 1], -SLIDE, 1e-9, `{Blocks.get(block).name}: -0.15 at tick {tick}`)
			end
			-- And down to the floor: no damage at all.
			local landed = false
			for _ = 1, 200 do
				local events = PlayerPhysics.tick(state, input(0, 0), world)
				t.eq(events.damage, 0, "no fall damage")
				landed = landed or state.onGround
			end
			t.ok(landed and state.y == 1, "slid down to the floor")
		end
	end)

	t.test("climbing: vines climb like ladders", function()
		local world = wallWorld(VINE, 20, 19)
		local state = PlayerPhysics.new(0.5, 1, 2.5)
		state.onGround = true
		local last = state.y
		for tick = 1, 40 do
			PlayerPhysics.tick(state, input(0, 1), world)
			if tick > 10 then
				t.near(state.y - last, CLIMB_UP, 1e-9, `0.1176 up at tick {tick}`)
			end
			last = state.y
		end
		t.ok(state.climbing, "climbing a vine")
	end)

	t.test("climbing: sneaking holds still on a ladder and on a rope", function()
		local ladder = wallWorld(LADDER, 20, 19)
		local rope = ropeWorld(30)
		for _, case in { { ladder, 0.5, 2.7 }, { rope, 0.5, 0.5 } } do
			local world, x, z = case[1] :: PlayerPhysics.World, case[2] :: number, case[3] :: number
			local state = PlayerPhysics.new(x, 8, z)
			state.vy = -0.5
			for _ = 1, 40 do
				local events = PlayerPhysics.tick(state, input(0, 0, { sneak = true }), world)
				t.eq(events.damage, 0, "no damage")
			end
			local held = state.y
			for _ = 1, 40 do
				PlayerPhysics.tick(state, input(0, 0, { sneak = true }), world)
			end
			t.eq(state.y, held, "held still")
			t.ok(state.y > 7, `stopped near where it caught ({state.y})`)
			t.ok(state.climbing and state.pose == "crouching", "crouched on it")
		end
		-- Sneaking while pushing into the ladder still climbs (Minecraft's too).
		local state = PlayerPhysics.new(0.5, 5, 2.7)
		local start = state.y
		for _ = 1, 20 do
			PlayerPhysics.tick(state, input(0, 1, { sneak = true }), ladder)
		end
		t.ok(state.y > start + 1.5, "pushing climbs even sneaking")
	end)

	t.test("climbing: a 40 block rope slide is a free fall that lands unhurt", function()
		local world = ropeWorld(60)
		local open = physicsWorld()
		local onRope = PlayerPhysics.new(0.5, 41, 0.5)
		local inAir = PlayerPhysics.new(2.5, 41, 2.5)
		local ticks, damage, fallDamage = 0, 0, 0
		for tick = 1, 200 do
			local events = PlayerPhysics.tick(onRope, input(0, 0), world)
			local free = PlayerPhysics.tick(inAir, input(0, 0), open)
			damage += events.damage
			fallDamage += free.damage
			if not onRope.onGround then
				t.near(onRope.y, inAir.y, 1e-9, `the slide falls as fast as a free fall (tick {tick})`)
				-- (The fall distance is cleared before every move: at most one tick's fall.)
				t.ok(onRope.fallDistance < 4, `the fall never gathers ({onRope.fallDistance})`)
			elseif ticks == 0 then
				ticks = tick
			end
		end
		t.ok(ticks > 0 and onRope.y == 1, "landed on the floor")
		t.eq(damage, 0, "unhurt")
		t.eq(fallDamage, 37, "the same fall without the rope: ceil(40 - 3)")
		t.ok(ticks < 40, `in free fall time ({ticks} ticks), not the ladder's 267`)
	end)

	t.test("climbing: the sideways speed on a climbable is held to 0.15 a tick", function()
		local world = ropeWorld(30)
		local state = PlayerPhysics.new(0.5, 10, 0.5)
		state.vx, state.vz = 0.5, -0.7
		PlayerPhysics.tick(state, input(0, 0), world)
		t.near(state.x - 0.5, SLIDE, 1e-9, "0.15 along x")
		t.near(state.z - 0.5, -SLIDE, 1e-9, "-0.15 along z")
		-- In the air the same push goes much further.
		local air = PlayerPhysics.new(5.5, 10, 5.5)
		air.vx = 0.5
		PlayerPhysics.tick(air, input(0, 0), world)
		t.near(air.x - 5.5, 0.5, 1e-9, "unheld off the rope")
	end)

	t.test("climbing: pushing into a ladder climbs out of water, not without one", function()
		-- Water two deep at x = 1 beside a ladder at x = 0 (the hull at x = 0.9 is in both).
		local function pool(ladder: boolean)
			return physicsWorld(function(x, y, z)
				if z == 3 and y >= 1 and y <= 20 then
					return STONE
				end
				if ladder and x == 0 and z == 2 and y >= 1 and y <= 19 then
					return LADDER
				end
				if x >= 1 and x <= 3 and z >= 0 and z <= 2 and y >= 1 and y <= 2 then
					return WATER
				end
				return nil
			end)
		end
		local state = PlayerPhysics.new(0.9, 1, 2.5)
		state.onGround = true
		local waterClimbs = 0
		for _ = 1, 80 do
			PlayerPhysics.tick(state, input(0, 1), pool(true))
			-- 0.2 x the water's 0.8F, less a sixteenth of gravity (at the surface the hop out,
			-- 0.3, takes over).
			if state.inWater and math.abs(state.vy - (0.2 * 0.800000011920929 - 0.005)) < 1e-9 then
				waterClimbs += 1
			end
		end
		t.ok(waterClimbs >= 3, `climbed in the water ({waterClimbs} ticks)`)
		t.ok(state.y > 5 and state.climbing, `up the ladder out of the water ({state.y})`)
		local stuck = PlayerPhysics.new(0.9, 1, 2.5)
		stuck.onGround = true
		for _ = 1, 80 do
			PlayerPhysics.tick(stuck, input(0, 1), pool(false))
		end
		t.ok(stuck.y < 2, `no ladder: still in the water ({stuck.y})`)
	end)

	t.test("climbing: spectators never climb, creative flight keeps its own vertical speed", function()
		local world = wallWorld(LADDER, 20, 19)
		local spectator = PlayerPhysics.new(0.5, 5, 2.5)
		PlayerPhysics.setGameMode(spectator, GameMode.SPECTATOR)
		for _ = 1, 10 do
			PlayerPhysics.tick(spectator, input(0, 0), world)
			t.ok(not spectator.climbing, "a spectator does not climb")
		end
		t.eq(spectator.y, 5, "hovers")
		-- Flying up through a ladder column rises as in the open air.
		local flyer = PlayerPhysics.new(0.5, 5, 2.5)
		local open = PlayerPhysics.new(0.5, 5, 2.5)
		for _, s in { flyer, open } do
			PlayerPhysics.setGameMode(s, GameMode.CREATIVE)
			s.flying = true
		end
		for _ = 1, 20 do
			PlayerPhysics.tick(flyer, input(0, 0, { jump = true }), world)
			PlayerPhysics.tick(open, input(0, 0, { jump = true }), physicsWorld())
			t.near(flyer.y, open.y, 1e-9, "the same rise")
		end
		t.ok(flyer.flying, "still flying")
	end)

	t.test("climbing: at the top of a ladder the player steps off onto the ledge", function()
		-- A cliff 4 high (its top at y = 5), the ladder all the way up.
		local world = physicsWorld(function(x, y, z)
			if z >= 3 and z <= 40 and x >= -2 and x <= 2 and y >= 1 and y <= 4 then
				return STONE
			end
			return if x == 0 and z == 2 and y >= 1 and y <= 4 then LADDER else nil
		end)
		local state = PlayerPhysics.new(0.5, 1, 2.5)
		state.onGround = true
		local damage = 0
		for _ = 1, 80 do
			local events = PlayerPhysics.tick(state, input(0, 1), world)
			damage += events.damage
		end
		t.ok(state.onGround, "standing")
		t.eq(state.y, 5, "on top of the wall")
		t.ok(state.z > 3.5, `walked on over it ({state.z})`)
		t.eq(damage, 0, "unhurt")
		t.ok(not state.climbing, "no longer climbing")
	end)

	t.test("cobwebs: x 0.25 and x 0.05 for one move, the velocity zeroed, the fall forgotten", function()
		-- Webs 4 deep (y 1..4) under a 30 block drop.
		local world = physicsWorld(function(x, y, z)
			if x >= -1 and x <= 1 and z >= -1 and z <= 1 and y >= 1 and y <= 4 then
				return COBWEB
			end
			return nil
		end)
		local state = PlayerPhysics.new(0.5, 31, 0.5)
		local caught = false
		local damage = 0
		for _ = 1, 1200 do
			local before = state.vy
			local wasStuck = state.stuck
			local y0 = state.y
			local events = PlayerPhysics.tick(state, input(0, 0), world)
			damage += events.damage
			if wasStuck and not state.onGround then
				t.near(state.y - y0, before * 0.05, 1e-9, "the move is x 0.05")
				-- The velocity was zeroed: only this tick's gravity remains.
				t.near(state.vy, (0 - 0.08) * 0.98, 1e-9, "the velocity was zeroed")
			end
			if state.stuck and not caught then
				caught = true
				t.eq(state.fallDistance, 0, "the fall is forgotten in a web")
				t.ok(before < -1, `caught falling fast ({before})`)
			end
		end
		t.ok(caught, "the web caught the fall")
		-- (The last step, shorter than Entity.move's 1e-7 squared, is not taken: Minecraft's too.)
		t.ok(state.onGround and math.abs(state.y - 1) < 1e-3, `sank to the floor ({state.y})`)
		t.eq(damage, 0, "no fall damage")
		t.eq(state.stuck, Blocks.stuckIn(COBWEB), "still in the web")

		-- Walking through webs on the ground: 0.1 x 0.98 a tick, x 0.25 = 0.49 m/s.
		local row = physicsWorld(function(x, y, z)
			if x >= 2 and x <= 40 and y == 1 and z == 0 then
				return COBWEB
			end
			return nil
		end)
		local walker = PlayerPhysics.new(2.5, 1, 0.5)
		walker.onGround = true
		local x0 = 0
		for tick = 1, 80 do
			PlayerPhysics.tick(walker, input(1, 0), row)
			if tick == 40 then
				x0 = walker.x
			end
		end
		t.near((walker.x - x0) / 40 * PlayerPhysics.TICK_RATE, 0.49, 1e-6, "0.49 m/s through webs")
		-- The cave twin slows the same.
		local twin = Blocks.stuckIn(B.CaveCobweb) :: { number }
		t.ok(twin[1] == 0.25 and twin[2] == 0.05 and twin[3] == 0.25, "twins slow alike")
	end)

	t.test("mobs: climb a ladder they walk into, not a bare wall; webs slow them but not spiders", function()
		local zombie = MobList.get(MobList.find("Zombie") :: number) :: MobList.Kind
		local spider = MobList.get(MobList.find("Spider") :: number) :: MobList.Kind
		local function getter(world: PlayerPhysics.World): MobPhysics.GetBlock
			return world.getBlock
		end
		local forward = 0.23 * 0.98
		-- Yaw 0 walks +Z, into the wall at z = 3.
		local climber = MobPhysics.new(0.5, 1, 0.5, 0)
		climber.onGround = true
		local ladder = getter(wallWorld(LADDER, 20, 19))
		local last = climber.y
		local landed = 0
		for tick = 1, 60 do
			landed += MobPhysics.tick(climber, zombie, forward, false, ladder)
			if tick > 30 then
				-- (MobPhysics keeps Minecraft's 0.98F drag.)
				t.near(climber.y - last, CLIMB_UP, 1e-8, `0.1176 a tick up (tick {tick})`)
			end
			last = climber.y
		end
		t.ok(climber.y > 4, `the zombie climbed ({climber.y})`)
		t.eq(climber.fallDistance, 0, "no fall on a ladder")
		-- And slides down at 0.15 when it stops pushing.
		local y0 = climber.y
		for _ = 1, 6 do
			MobPhysics.tick(climber, zombie, 0, false, ladder)
		end
		local y1 = climber.y
		MobPhysics.tick(climber, zombie, 0, false, ladder)
		t.near(climber.y - y1, -SLIDE, 1e-8, "slides at 0.15")
		t.ok(y1 < y0, "down")
		local bare = MobPhysics.new(0.5, 1, 0.5, 0)
		bare.onGround = true
		local wall = getter(wallWorld(STONE, 20, 0))
		for _ = 1, 60 do
			MobPhysics.tick(bare, zombie, forward, false, wall)
		end
		t.eq(bare.y, 1, "a bare wall stops a zombie")

		-- Through a row of webs: a zombie crawls, a spider walks on.
		local webs = getter(physicsWorld(function(x, y, z)
			if z >= 2 and z <= 30 and y >= 1 and y <= 2 and x >= -1 and x <= 1 then
				return COBWEB
			end
			return nil
		end))
		local open = getter(physicsWorld())
		-- Blocks walked over ticks 21..40.
		local function walked(kind: MobList.Kind, getBlock: MobPhysics.GetBlock): number
			local body = MobPhysics.new(0.5, 1, 3.5, 0)
			body.onGround = true
			local z0 = 0
			for tick = 1, 40 do
				MobPhysics.tick(body, kind, forward, false, getBlock)
				if tick == 20 then
					z0 = body.z
				end
			end
			return body.z - z0
		end
		-- In a web the velocity never builds up: each tick moves a quarter of one tick's push.
		local slowed = walked(zombie, webs)
		t.near(slowed / 20, forward * zombie.speed * 0.25, 1e-6, "a zombie crawls through webs")
		t.ok(slowed < walked(zombie, open) * 0.15, "far slower than in the open")
		t.near(walked(spider, webs), walked(spider, open), 1e-9, "a spider is not slowed")
	end)
end

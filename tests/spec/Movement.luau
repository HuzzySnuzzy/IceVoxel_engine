return function(t, shared, require)
	local Blocks = require(shared.Blocks)
	local Hull = require(shared.Movement.Hull)
	local PlayerPhysics = require(shared.Movement.PlayerPhysics)

	-- A little block world: `solid["x,y,z"] = true`, everything else air.
	local function world(cells: { { number } }): Hull.SolidAt
		local solid: { [string]: boolean } = {}
		-- (+ 0 turns -0 into 0, so both name the same cell.)
		for _, c in cells do
			solid[`{c[1] + 0},{c[2] + 0},{c[3] + 0}`] = true
		end
		return function(x: number, y: number, z: number): boolean
			return solid[`{x + 0},{y + 0},{z + 0}`] == true
		end
	end
	-- A floor of blocks at y = 0 over [-r, r] x [-r, r], plus extra cells.
	local function floorWorld(r: number, extra: { { number } }?): Hull.SolidAt
		local cells = table.clone(extra or {})
		for x = -r, r do
			for z = -r, r do
				table.insert(cells, { x, 0, z })
			end
		end
		return world(cells)
	end
	local function near(a: number, b: number, tolerance: number?): boolean
		return math.abs(a - b) <= (tolerance or 1e-9)
	end

	t.test("hull: falling lands on the floor, walls stop it, touching faces do not", function()
		local solidAt = floorWorld(4, { { 2, 1, 0 } })
		local box = Hull.box(0.5, 1.5, 0.5, 0.6, 1.8)
		local _, dy = Hull.collideBox(solidAt, box, 0, -2, 0)
		t.ok(near(dy, -0.5), `landed after {dy}`)

		-- Standing on the floor (bottom exactly on its top face): sideways is free.
		local standing = Hull.box(0.5, 1, 0.5, 0.6, 1.8)
		local dx = Hull.collideBox(solidAt, standing, 0.3, 0, 0)
		t.ok(near(dx, 0.3), "the floor does not block sideways movement")
		-- The wall block at x = 2: the box's +X face is at 0.8, so it can move 1.2.
		dx = Hull.collideBox(solidAt, standing, 5, 0, 0)
		t.ok(near(dx, 1.2), `stopped at the wall after {dx}`)
		dx = Hull.collideBox(solidAt, standing, -5, 0, 0)
		t.ok(near(dx, -5), "nothing the other way")
		t.ok(Hull.noCollision(solidAt, standing), "standing on a floor is no collision")
		t.ok(not Hull.noCollision(solidAt, Hull.offset(standing, 0, -0.01, 0)), "sinking into it is")
	end)

	t.test("hull: blocks already overlapped do not hold the box, corners resolve per axis", function()
		local solidAt = world({ { 0, 0, 0 } })
		-- A box stuck halfway in the block can leave in any direction.
		local stuck = Hull.box(0.5, 0.5, 0.5, 0.6, 1.8)
		local _, up = Hull.collideBox(solidAt, stuck, 0, 1, 0)
		t.ok(near(up, 1), "up")
		local sideways = Hull.collideBox(solidAt, stuck, 2, 0, 0)
		t.ok(near(sideways, 2), "sideways")

		-- Inner corner: walls at x = 2 and z = 2; a diagonal move stops at both.
		local corner = world({ { 2, 0, 0 }, { 2, 0, 1 }, { 0, 0, 2 }, { 1, 0, 2 }, { 2, 0, 2 } })
		local box = Hull.box(1, 0, 1, 0.6, 0.9)
		local dx, _, dz = Hull.collideBox(corner, box, 0.7, 0, 0.5)
		t.ok(near(dx, 0.7) and near(dz, 0.5), "short of the walls: free")
		dx, _, dz = Hull.collideBox(corner, box, 3, 0, 2)
		t.ok(near(dx, 0.7) and near(dz, 0.7), `stopped by both walls: {dx}, {dz}`)
	end)

	t.test("hull: a 0.6 wide box fits a 1 wide corridor, not a gap between blocks", function()
		local cells = {}
		for z = -3, 3 do
			table.insert(cells, { -1, 1, z })
			table.insert(cells, { 1, 1, z })
			table.insert(cells, { -1, 2, z })
			table.insert(cells, { 1, 2, z })
		end
		local solidAt = floorWorld(4, cells)
		local box = Hull.box(0.5, 1, -2.5, 0.6, 1.8)
		local _, _, dz = Hull.collideBox(solidAt, box, 0, 0, 5)
		t.ok(near(dz, 5), "walks down the corridor")
		local dx = Hull.collideBox(solidAt, box, 0.5, 0, 0)
		t.ok(near(dx, 0.2), `the corridor wall stops it after {dx}`)
	end)

	t.test("hull: stepping up only reaches 0.6 blocks", function()
		local solidAt = floorWorld(4, { { 2, 1, 0 } })
		-- On the ground in front of a full block: no stepping onto it.
		local standing = Hull.box(1.5, 1, 0.5, 0.6, 1.8)
		local dx, dy = Hull.collide(solidAt, standing, 0.5, -0.08, 0, 0.6, true)
		t.ok(near(dx, 0.2) and near(dy, 0), `blocked by the full block: {dx}, {dy}`)

		-- Landing this tick (the vertical move hits the floor) 0.45 below the block's top, e.g. at
		-- the end of a jump: steps up onto it.
		local falling = Hull.box(1.5, 1.45, 0.5, 0.6, 1.8)
		dx, dy = Hull.collide(solidAt, falling, 0.5, -0.5, 0, 0.6, false)
		t.ok(near(dx, 0.5), `stepped over: {dx}`)
		t.ok(near(1.45 + dy, 2), `stands on the block top: {1.45 + dy}`)
		-- Still in the air (the floor is not reached this tick): no step.
		dx = Hull.collide(solidAt, falling, 0.5, -0.1, 0, 0.6, false)
		t.ok(near(dx, 0.2), `no step in mid-air: {dx}`)

		-- Landing 0.7 below the top: too far to step.
		local low = Hull.box(1.5, 1.3, 0.5, 0.6, 1.8)
		dx = Hull.collide(solidAt, low, 0.5, -0.5, 0, 0.6, false)
		t.ok(near(dx, 0.2), `no step from 0.7 below: {dx}`)
	end)

	t.test("hull: sneaking stops at edges", function()
		-- A one block pillar at (0, 0, 0) with nothing around it.
		local solidAt = world({ { 0, 0, 0 } })
		local box = Hull.box(0.5, 1, 0.5, 0.6, 1.8)
		-- Supported until the box's -X face passes the pillar's +X face (a move of 0.8).
		local dx, dz = Hull.backOffFromEdge(solidAt, box, 1, 0, 0.6)
		t.ok(dx < 0.8 and dx > 0.7 - 1e-9, `stops with the box still over the pillar: {dx}`)
		t.ok(not Hull.noCollision(solidAt, Hull.offset(box, dx, -0.6, dz)), "still supported")
		dx, dz = Hull.backOffFromEdge(solidAt, box, 0.2, 0.2, 0.6)
		t.ok(near(dx, 0.2) and near(dz, 0.2), "moves freely while supported")
		dx, dz = Hull.backOffFromEdge(solidAt, box, -1, -1, 0.6)
		t.ok(dx <= 0 and dz <= 0 and dx > -0.85 and dz > -0.85, `diagonal off the corner: {dx}, {dz}`)
		t.ok(not Hull.noCollision(solidAt, Hull.offset(box, dx, -0.6, dz)), "still supported diagonally")
	end)

	--[[ PlayerPhysics: Minecraft's numbers ]]

	local STONE, ICE, AIR = Blocks.id.Stone, Blocks.id.Ice, Blocks.AIR
	local WATER = Blocks.fluidId("Water", 0)

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
	-- Average speed (blocks per second) over ticks `from`..`to` of walking in +X.
	local function speedOver(world: PlayerPhysics.World, i: PlayerPhysics.Input, from: number, to: number): number
		local state = PlayerPhysics.new(0.5, 1, 0.5)
		state.onGround = true
		local x0 = 0
		for tick = 1, to do
			PlayerPhysics.tick(state, i, world)
			if tick == from then
				x0 = state.x
			end
		end
		return (state.x - x0) / (to - from) * PlayerPhysics.TICK_RATE
	end

	t.test("physics: walking, sprinting and sneaking speeds", function()
		local flat = physicsWorld()
		local walk = speedOver(flat, input(1, 0), 40, 100)
		t.ok(near(walk, 4.317, 0.002), `walk {walk} m/s`)
		local sprint = speedOver(flat, input(1, 0, { sprint = true }), 40, 100)
		t.ok(near(sprint, 5.612, 0.002), `sprint {sprint} m/s`)
		local sneak = speedOver(flat, input(1, 0, { sneak = true }), 40, 100)
		t.ok(near(sneak, 1.295, 0.002), `sneak {sneak} m/s`)
		-- Diagonal input of length 1 is as fast as straight input.
		local diagonal = speedOver(flat, input(math.sqrt(0.5), math.sqrt(0.5)), 40, 100) * math.sqrt(2)
		t.ok(near(diagonal, 4.317, 0.002), `diagonal {diagonal} m/s`)
	end)

	t.test("physics: a jump peaks at 1.2522 blocks and lands after 12 ticks", function()
		local flat = physicsWorld()
		local state = PlayerPhysics.new(0.5, 1, 0.5)
		state.onGround = true
		local peak, landedAt = 0, nil
		for tick = 1, 40 do
			local events = PlayerPhysics.tick(state, input(0, 0, { jump = tick == 1 }), flat)
			if tick == 1 then
				t.ok(events.jumped, "jumped")
			end
			peak = math.max(peak, state.y - 1)
			if landedAt == nil and tick > 1 and state.onGround then
				landedAt = tick
			end
		end
		t.ok(near(peak, 1.2522, 0.0005), `peak {peak}`)
		t.eq(landedAt, 12, "ticks in the air")
		t.ok(near(state.y, 1), "back on the floor")
	end)

	t.test("physics: holding jump bunny hops; sprint jumping is faster than sprinting", function()
		local flat = physicsWorld()
		local state = PlayerPhysics.new(0.5, 1, 0.5)
		state.onGround = true
		local jumps = 0
		for _ = 1, 200 do
			local events = PlayerPhysics.tick(state, input(1, 0, { jump = true, sprint = true }), flat)
			if events.jumped then
				jumps += 1
			end
		end
		t.ok(jumps >= 15, `{jumps} jumps in 10 s while holding jump`)
		local hop = speedOver(flat, input(1, 0, { jump = true, sprint = true }), 60, 200)
		t.ok(hop > 6.9 and hop < 7.4, `sprint jumping {hop} m/s (Minecraft ~7.1)`)
	end)

	t.test("physics: falling, terminal velocity and fall damage", function()
		local flat = physicsWorld()
		local void = physicsWorld(function(_x, y, _z)
			return if y > -100000 then AIR else nil
		end)
		local state = PlayerPhysics.new(0.5, 400, 0.5)
		for _ = 1, 300 do
			PlayerPhysics.tick(state, input(0, 0), void)
		end
		t.ok(near(state.vy, -3.92, 0.01), `terminal velocity {state.vy}`)

		local function drop(height: number): (number, number)
			local s = PlayerPhysics.new(0.5, 1 + height, 0.5)
			for _ = 1, 100 do
				local events = PlayerPhysics.tick(s, input(0, 0), flat)
				if events.landed then
					return events.fallDistance, events.damage
				end
			end
			return -1, -1
		end
		-- (The landing tick's own movement is not counted, as in Minecraft.)
		local distance, damage = drop(3)
		t.ok(distance > 2 and distance < 3 and damage == 0, `3 blocks: {distance}, {damage}`)
		distance, damage = drop(4)
		t.ok(distance > 3 and distance < 4 and damage == 1, `4 blocks: {distance}, {damage}`)
		distance, damage = drop(24)
		t.ok(damage >= 19 and damage <= 21, `24 blocks: {distance}, {damage} half hearts`)

		-- Water breaks the fall.
		local pool = physicsWorld(function(_x, y, _z)
			return if y >= 1 and y <= 3 then WATER else nil
		end)
		local s = PlayerPhysics.new(0.5, 30, 0.5)
		local hurt = false
		for _ = 1, 200 do
			local events = PlayerPhysics.tick(s, input(0, 0), pool)
			hurt = hurt or events.damage > 0
		end
		t.ok(not hurt, "no damage landing in water")
	end)

	t.test("physics: walls stop the player, a full block is too high to step onto", function()
		local wall = physicsWorld(function(x, y, _z)
			return if x == 3 and y == 1 then STONE else nil
		end)
		local state = PlayerPhysics.new(0.5, 1, 0.5)
		state.onGround = true
		for _ = 1, 60 do
			PlayerPhysics.tick(state, input(1, 0), wall)
		end
		t.ok(near(state.x, 2.7, 1e-6) and near(state.y, 1), `stopped at {state.x}, {state.y}`)
		-- Jumping gets over it.
		for _ = 1, 30 do
			PlayerPhysics.tick(state, input(1, 0, { jump = true }), wall)
		end
		t.ok(state.x > 3.5, `jumped onto / over the block: {state.x}`)
	end)

	t.test("physics: sprinting stops head on into a wall, not sliding along it", function()
		local wall = physicsWorld(function(x, y, _z)
			return if x == 3 and (y == 1 or y == 2) then STONE else nil
		end)
		local state = PlayerPhysics.new(0.5, 1, 0.5)
		state.onGround = true
		for _ = 1, 40 do
			PlayerPhysics.tick(state, input(1, 0, { sprint = true }), wall)
		end
		t.ok(not state.sprinting, "head on: sprint stops")

		-- Running along the wall, 5 degrees into it.
		local slide = PlayerPhysics.new(2.6, 1, 0.5)
		slide.onGround = true
		local a = math.rad(5)
		for tick = 1, 60 do
			PlayerPhysics.tick(slide, input(math.sin(a), math.cos(a), { sprint = true }), wall)
			if tick == 59 then
				t.ok(slide.horizontalCollision, "sliding along the wall")
			end
		end
		t.ok(slide.sprinting, "a 5 degree slide keeps sprinting")
	end)

	t.test("physics: sneaking never walks off an edge", function()
		-- A 3 x 3 platform at y = 10 over nothing.
		local platform = physicsWorld(function(x, y, z)
			if y == 10 and x >= 0 and x <= 2 and z >= 0 and z <= 2 then
				return STONE
			end
			return if y <= 0 then STONE else AIR
		end)
		local state = PlayerPhysics.new(1.5, 11, 1.5)
		state.onGround = true
		for _ = 1, 100 do
			PlayerPhysics.tick(state, input(1, 0, { sneak = true }), platform)
		end
		t.ok(near(state.y, 11), `still on the platform at y {state.y}`)
		t.ok(state.x > 3.2 and state.x < 3.3, `as far as the edge allows: x {state.x}`)
		for _ = 1, 20 do
			PlayerPhysics.tick(state, input(1, 0), platform)
		end
		t.ok(state.y < 11, "without sneaking it walks off")
	end)

	t.test("physics: ice is slippery", function()
		local function slide(floorBlock: number): number
			local w = physicsWorld(function(_x, y, _z)
				return if y == 0 then floorBlock else nil
			end)
			local state = PlayerPhysics.new(0.5, 1, 0.5)
			state.onGround = true
			for _ = 1, 40 do
				PlayerPhysics.tick(state, input(1, 0), w)
			end
			local x0 = state.x
			for _ = 1, 100 do
				PlayerPhysics.tick(state, input(0, 0), w)
			end
			return state.x - x0
		end
		local stone, ice = slide(STONE), slide(ICE)
		t.ok(stone < 0.5, `stops quickly on stone ({stone})`)
		t.ok(ice > 1.5, `slides on ice ({ice})`)
	end)

	t.test("physics: water slows, sinks gently, swims up and hops out onto ledges", function()
		local deep = physicsWorld(function(_x, y, _z)
			return if y >= 1 and y <= 20 then WATER else nil
		end)
		local state = PlayerPhysics.new(0.5, 10, 0.5)
		for _ = 1, 100 do
			PlayerPhysics.tick(state, input(0, 0), deep)
		end
		t.ok(state.inWater and state.underWater, "in water, eyes under")
		t.ok(state.vy < 0 and state.vy > -0.05, `sinks slowly: {state.vy}`)
		local diver = PlayerPhysics.new(0.5, 3, 0.5)
		for _ = 1, 30 do
			PlayerPhysics.tick(diver, input(0, 0, { jump = true }), deep)
		end
		t.ok(diver.vy > 0.1 and diver.y > 5, `holding jump swims up: {diver.vy} at {diver.y}`)
		local swim = speedOver(deep, input(1, 0), 40, 100)
		t.ok(swim > 0.5 and swim < 2.5, `swimming is slow: {swim} m/s`)

		-- Water up to y = 3, a ledge (stone up to y = 3) at x >= 3: swimming at it hops out.
		local shore = physicsWorld(function(x, y, _z)
			if x >= 3 then
				return if y <= 3 then STONE else AIR
			end
			return if y >= 1 and y <= 3 then WATER else nil
		end)
		local swimmer = PlayerPhysics.new(1.5, 3.4, 0.5)
		for _ = 1, 120 do
			PlayerPhysics.tick(swimmer, input(1, 0, { jump = true }), shore)
		end
		t.ok(swimmer.x > 3 and swimmer.y >= 4 - 1e-6, `climbed out onto the ledge: {swimmer.x}, {swimmer.y}`)
	end)

	t.test("physics: poses crouch when sneaking and crawl under a 1 block ceiling", function()
		local tunnel = physicsWorld(function(x, y, _z)
			return if y == 2 and x >= 3 then STONE else nil
		end)
		local state = PlayerPhysics.new(0.5, 1, 0.5)
		state.onGround = true
		PlayerPhysics.tick(state, input(0, 0, { sneak = true }), tunnel)
		t.eq(state.pose, "crouching", "sneaking crouches")
		t.ok(near(PlayerPhysics.box(state).maxY - state.y, 1.5), "1.5 tall")
		PlayerPhysics.tick(state, input(0, 0), tunnel)
		t.eq(state.pose, "standing", "stands up again")
		-- Into a tunnel one block high: blocked standing, the player would have to crawl in, which
		-- Minecraft does not do by walking; placing the player inside makes it crawl.
		local inside = PlayerPhysics.new(4.5, 1, 0.5)
		inside.onGround = true
		PlayerPhysics.tick(inside, input(0, 0), tunnel)
		t.eq(inside.pose, "crawling", "no room to stand or crouch")
	end)

	t.test("physics: the same inputs give the same path", function()
		local world = physicsWorld(function(x, y, z)
			return if y == 1 and (x + z) % 7 == 0 then STONE else nil
		end)
		local function run(): string
			local state = PlayerPhysics.new(0.5, 1, 0.5)
			for tick = 1, 300 do
				local a = tick * 0.05
				PlayerPhysics.tick(
					state,
					input(math.cos(a), math.sin(a), { jump = tick % 13 == 0, sprint = tick > 100 }),
					world
				)
			end
			return `{state.x},{state.y},{state.z},{state.vx},{state.vy},{state.vz}`
		end
		t.eq(run(), run())
	end)

	t.test("physics: tick by tick like Minecraft (walk ramp, jump arc, ice, sprint jumping)", function()
		local flat = physicsWorld()
		-- Walking from rest: x after each tick (Minecraft 1.20.1, float32 re-implementation).
		local walker = PlayerPhysics.new(0, 1, 0)
		walker.onGround = true
		walker.vy = -0.0784
		for _, want in { 0.098, 0.249508, 0.430231, 0.626906, 0.832291, 1.042431, 1.255167, 1.469321 } do
			PlayerPhysics.tick(walker, input(1, 0), flat)
			t.ok(near(walker.x, want, 2e-4), `walk ramp {walker.x} vs {want}`)
		end
		-- Jump heights per tick.
		local jumper = PlayerPhysics.new(0.5, 1, 0.5)
		jumper.onGround = true
		local heights = { 0.42, 0.7532, 1.00134, 1.16611, 1.24919, 1.2522, 1.17676, 1.02442, 0.79674, 0.4952, 0.1213 }
		for tick, want in heights do
			PlayerPhysics.tick(jumper, input(0, 0, { jump = tick == 1 }), flat)
			t.ok(near(jumper.y - 1, want, 2e-4), `jump tick {tick}: {jumper.y - 1} vs {want}`)
		end
		-- Ice: walk 4.1572 m/s, sprint 5.4044 m/s.
		local ice = physicsWorld(function(_x, y, _z)
			return if y == 0 then ICE else nil
		end)
		local walk = speedOver(ice, input(1, 0), 150, 250)
		t.ok(near(walk, 4.1572, 0.003), `walking on ice {walk}`)
		local sprint = speedOver(ice, input(1, 0, { sprint = true }), 150, 250)
		t.ok(near(sprint, 5.4044, 0.003), `sprinting on ice {sprint}`)
		-- Sprint jumping averages 7.1268 m/s over whole 12 tick jumps.
		local hop = speedOver(flat, input(1, 0, { jump = true, sprint = true }), 49, 241)
		t.ok(near(hop, 7.1268, 0.01), `sprint jumping {hop}`)
	end)

	t.test("physics: sprint and sneak interplay (1.20), shift sinks in water", function()
		local flat = physicsWorld()
		-- Crouching keeps an existing sprint (sprint-sneaking: 0.13 speed with 0.3 input).
		local state = PlayerPhysics.new(0.5, 1, 0.5)
		state.onGround = true
		for _ = 1, 20 do
			PlayerPhysics.tick(state, input(1, 0, { sprint = true }), flat)
		end
		t.ok(state.sprinting, "sprinting")
		for _ = 1, 40 do
			PlayerPhysics.tick(state, input(1, 0, { sprint = true, sneak = true }), flat)
		end
		local x0 = state.x
		for _ = 1, 40 do
			PlayerPhysics.tick(state, input(1, 0, { sprint = true, sneak = true }), flat)
		end
		t.ok(state.sprinting, "still sprinting while sneaking")
		-- 0.13 * 0.3 * 0.98 / (1 - 0.546) blocks per tick.
		local speed = (state.x - x0) / 40 * 20
		t.ok(near(speed, 1.684, 0.003), `sprint-sneaking at {speed} m/s`)
		-- But a crouching player cannot start one.
		local sneaker = PlayerPhysics.new(0.5, 1, 0.5)
		sneaker.onGround = true
		for _ = 1, 5 do
			PlayerPhysics.tick(sneaker, input(1, 0, { sneak = true }), flat)
		end
		for _ = 1, 20 do
			PlayerPhysics.tick(sneaker, input(1, 0, { sprint = true, sneak = true }), flat)
		end
		t.ok(not sneaker.sprinting, "sneaking does not start a sprint")
		-- Double tap forward starts one.
		local tapper = PlayerPhysics.new(0.5, 1, 0.5)
		tapper.onGround = true
		for tick = 1, 12 do
			local pressed = tick <= 2 or tick >= 5
			PlayerPhysics.tick(tapper, input(if pressed then 1 else 0, 0), flat)
		end
		t.ok(tapper.sprinting, "double tap sprints")

		local deep = physicsWorld(function(_x, y, _z)
			return if y >= 1 and y <= 20 then WATER else nil
		end)
		local floater = PlayerPhysics.new(0.5, 10, 0.5)
		local diver = PlayerPhysics.new(0.5, 10, 0.5)
		for _ = 1, 20 do
			PlayerPhysics.tick(floater, input(0, 0), deep)
			PlayerPhysics.tick(diver, input(0, 0, { sneak = true }), deep)
		end
		t.ok(diver.y < floater.y - 1, `shift sinks faster: {diver.y} vs {floater.y}`)
	end)

	t.test("physics: a step height over one block walks up blocks, sneaking still stops at edges", function()
		-- Stairs of full blocks going up in +X (column x is x blocks tall), then a plateau 6 high.
		local stairs = physicsWorld(function(x, y, _z)
			if x >= 1 and y >= 1 and y <= math.min(x, 6) then
				return STONE
			end
			return nil
		end)
		local climber = PlayerPhysics.new(0.5, 1, 0.5)
		climber.stepHeight = 1.0625
		climber.onGround = true
		local stepped = 0
		for _ = 1, 80 do
			local events = PlayerPhysics.tick(climber, input(1, 0), stairs)
			if events.stepUp > 0 then
				stepped += 1
				t.ok(near(events.stepUp, 1, 1e-6), `stepped {events.stepUp}`)
			end
		end
		t.ok(near(climber.y, 7) and climber.x > 6, `walked up the stairs to {climber.x}, {climber.y}`)
		t.eq(stepped, 6, "one step per block")

		-- Minecraft's 0.6 cannot.
		local walker = PlayerPhysics.new(0.5, 1, 0.5)
		walker.onGround = true
		for _ = 1, 80 do
			PlayerPhysics.tick(walker, input(1, 0), stairs)
		end
		t.ok(near(walker.y, 1) and walker.x < 1, `stopped at the first step: {walker.x}, {walker.y}`)

		-- A two block wall is still a wall.
		local wall = physicsWorld(function(x, y, _z)
			return if x == 3 and (y == 1 or y == 2) then STONE else nil
		end)
		local blocked = PlayerPhysics.new(0.5, 1, 0.5)
		blocked.stepHeight = 1.0625
		blocked.onGround = true
		for _ = 1, 60 do
			PlayerPhysics.tick(blocked, input(1, 0), wall)
		end
		t.ok(near(blocked.x, 2.7, 1e-6) and near(blocked.y, 1), "two blocks are too high")

		-- Sneaking at the edge of a one block drop still stops.
		local ledge = physicsWorld(function(x, y, _z)
			return if y == 1 and x <= 2 then STONE else nil
		end)
		local sneaker = PlayerPhysics.new(1.5, 2, 0.5)
		sneaker.stepHeight = 1.0625
		sneaker.onGround = true
		for _ = 1, 60 do
			PlayerPhysics.tick(sneaker, input(1, 0, { sneak = true }), ledge)
		end
		t.ok(near(sneaker.y, 2) and sneaker.x < 3.3, `sneaking stops at the one block drop: {sneaker.x}, {sneaker.y}`)
	end)

	t.test("physics: sprinting under water swims, steered by the view", function()
		local deep = physicsWorld(function(_x, y, _z)
			return if y >= 1 and y <= 30 then WATER else nil
		end)
		local state = PlayerPhysics.new(0.5, 10, 0.5)
		for _ = 1, 3 do
			PlayerPhysics.tick(state, input(0, 0), deep)
		end
		t.ok(state.underWater, "under water")
		for _ = 1, 10 do
			PlayerPhysics.tick(state, input(1, 0, { sprint = true, lookY = -0.5 }), deep)
		end
		t.ok(state.sprinting and state.swimming, "sprinting under water swims")
		t.eq(state.pose, "crawling", "0.6 tall")
		local y0 = state.y
		for _ = 1, 20 do
			PlayerPhysics.tick(state, input(1, 0, { sprint = true, lookY = -0.5 }), deep)
		end
		t.ok(state.y < y0 - 1, `dives where the view points: {y0} -> {state.y}`)
		local swim = speedOver(deep, input(1, 0, { sprint = true }), 60, 120)
		t.ok(swim > 2.5, `swimming is faster than walking in water: {swim} m/s`)
		for _ = 1, 5 do
			PlayerPhysics.tick(state, input(0, 0), deep)
		end
		t.ok(not state.sprinting and not state.swimming, "stopping ends the swim")
	end)
	t.test("physics: a player stuck in a block is pushed out towards the nearest free side", function()
		-- Blocks fill x = 0 at the body's height; x = 1 and beyond are free. The hull is near the
		-- east side of its block, so east is the closest way out.
		local walled = physicsWorld(function(x, y, _z)
			if x == 0 and (y == 1 or y == 2) then
				return STONE
			end
			return nil
		end)
		local state = PlayerPhysics.new(0.7, 1, 0.5)
		local pose = state.pose
		PlayerPhysics.tick(state, input(0, 0), walled)
		t.eq(state.pose, pose, "stuck: the pose stays (Minecraft keeps it when nothing fits)")
		for _ = 1, 20 do
			PlayerPhysics.tick(state, input(0, 0), walled)
		end
		t.ok(state.x - 0.3 >= 1 - 1e-6, `pushed out east to x = {state.x}`)
		t.eq(state.pose, "standing")
	end)

	--[[ Creative flight (Minecraft 1.20.1: LocalPlayer.aiStep, Player.travel) ]]

	-- A player who may fly, flying in the air at (x, y, z).
	local function flyer(x: number, y: number, z: number): PlayerPhysics.State
		local state = PlayerPhysics.new(x, y, z)
		state.mayFly = true
		state.flying = true
		return state
	end
	-- Average speed (blocks per second) over ticks `from`..`to` of flying with input `i`, high up.
	local function flyingSpeed(i: PlayerPhysics.Input, from: number, to: number): number
		local flat = physicsWorld()
		local state = flyer(0.5, 100, 0.5)
		local x0 = 0
		for tick = 1, to do
			PlayerPhysics.tick(state, i, flat)
			if tick == from then
				x0 = state.x
			end
		end
		t.ok(state.flying, "still flying")
		return (state.x - x0) / (to - from) * PlayerPhysics.TICK_RATE
	end
	-- Ticks 1..n of jump input from a list of the ticks it is held; returns the state afterwards.
	local function jumpPattern(state: PlayerPhysics.State, held: { [number]: boolean }, n: number)
		local flat = physicsWorld()
		for tick = 1, n do
			PlayerPhysics.tick(state, input(0, 0, { jump = held[tick] == true }), flat)
		end
	end

	t.test("flight: a second jump press within 7 ticks of the first toggles flying", function()
		-- First press at tick 1; the second press can come at ticks 3..7 (the key must be released
		-- in between), not at tick 8.
		for second = 3, 8 do
			local state = PlayerPhysics.new(0.5, 1, 0.5)
			state.onGround = true
			state.mayFly = true
			jumpPattern(state, { [1] = true, [second] = true }, second)
			t.eq(state.flying, second <= 7, `second press at tick {second}`)
			t.eq(state.jumpTriggerTime, if second <= 7 then 0 else 6, `trigger time after tick {second}`)
		end
		-- A late second press arms a new double tap instead.
		local late = PlayerPhysics.new(0.5, 1, 0.5)
		late.onGround = true
		late.mayFly = true
		jumpPattern(late, { [1] = true, [8] = true, [10] = true }, 10)
		t.ok(late.flying, "the press after a late one toggles")

		-- Holding jump is one press; without mayFly nothing toggles.
		local holder = PlayerPhysics.new(0.5, 1, 0.5)
		holder.onGround = true
		holder.mayFly = true
		local held = {}
		for tick = 1, 40 do
			held[tick] = true
		end
		jumpPattern(holder, held, 40)
		t.ok(not holder.flying, "holding jump does not fly")
		local walker = PlayerPhysics.new(0.5, 1, 0.5)
		walker.onGround = true
		jumpPattern(walker, { [1] = true, [3] = true }, 3)
		t.ok(not walker.flying, "survival players can't fly")

		-- Double tapping again while flying stops flying; the player falls and lands.
		local state = flyer(0.5, 5, 0.5)
		jumpPattern(state, { [1] = true, [4] = true }, 4)
		t.ok(not state.flying, "double tap while flying stops it")
		jumpPattern(state, {}, 40)
		t.ok(state.onGround and near(state.y, 1), `fell to the floor: {state.y}`)
	end)

	t.test("flight: tick by tick from a double tapped jump", function()
		-- Jump at tick 1, press again at tick 3: Minecraft's numbers.
		local state = PlayerPhysics.new(0.5, 1, 0.5)
		state.onGround = true
		state.mayFly = true
		local flat = physicsWorld()
		-- (y above the floor after each tick.)
		local expected = {}
		local y, vy = 0.42, (0.42 - 0.08) * 0.98 -- tick 1: the jump
		expected[1] = y
		y += vy -- tick 2: still a normal jump
		vy = (vy - 0.08) * 0.98
		expected[2] = y
		vy += 0.15000000596046448 -- tick 3: flying, jump held: +0.15, then the vertical drag 0.6
		y += vy
		vy *= 0.6
		expected[3] = y
		for tick = 4, 8 do -- released: no gravity, 0.6 of the speed each tick
			y += vy
			vy *= 0.6
			expected[tick] = y
		end
		for tick = 1, 8 do
			PlayerPhysics.tick(state, input(0, 0, { jump = tick == 1 or tick == 3 }), flat)
			t.ok(near(state.y - 1, expected[tick], 1e-6), `tick {tick}: {state.y - 1} vs {expected[tick]}`)
			t.eq(state.flying, tick >= 3, `flying at tick {tick}`)
		end
		-- Hovering: the speed decays to nothing and the height stays.
		for _ = 1, 40 do
			PlayerPhysics.tick(state, input(0, 0), flat)
		end
		local hover = state.y
		for _ = 1, 20 do
			PlayerPhysics.tick(state, input(0, 0), flat)
		end
		t.ok(state.vy == 0 and state.y == hover and state.flying, `hovers at {state.y}`)
		t.eq(state.fallDistance, 0, "no fall distance while flying")
	end)

	t.test("flight: 10.89 m/s flying, 21.78 m/s sprint flying", function()
		local fly = flyingSpeed(input(1, 0), 150, 250)
		t.ok(near(fly, 10.8889, 0.0005), `flying {fly} m/s`)
		local sprint = flyingSpeed(input(1, 0, { sprint = true }), 150, 250)
		t.ok(near(sprint, 21.7778, 0.0005), `sprint flying {sprint} m/s`)
		-- Holding sneak and jump together: no vertical movement and no sneaking slowdown.
		local both = flyingSpeed(input(1, 0, { jump = true, sneak = true }), 150, 250)
		t.ok(near(both, 10.8889, 0.0005), `sneak + jump {both} m/s`)
		-- The horizontal ramp: a = 0.05 * 0.98, then 0.91 drag each tick.
		local state = flyer(0.5, 100, 0.5)
		local flat = physicsWorld()
		local x, vx = 0.5, 0
		for tick = 1, 6 do
			vx += 0.05000000074505806 * 0.98
			x += vx
			vx *= 0.91
			PlayerPhysics.tick(state, input(1, 0), flat)
			t.ok(near(state.x, x, 1e-9), `flying ramp tick {tick}: {state.x} vs {x}`)
			t.eq(state.y, 100, "level")
		end
	end)

	t.test("flight: jump rises and sneak sinks 0.375 blocks per tick at most", function()
		local flat = physicsWorld()
		local up = flyer(0.5, 100, 0.5)
		local y0 = up.y
		local steps = { 0.15, 0.24, 0.294, 0.3264 }
		for tick, step in steps do
			PlayerPhysics.tick(up, input(0, 0, { jump = true }), flat)
			t.ok(near(up.y - y0, step, 1e-6), `rise at tick {tick}: {up.y - y0} vs {step}`)
			y0 = up.y
		end
		for _ = 1, 40 do
			PlayerPhysics.tick(up, input(0, 0, { jump = true }), flat)
		end
		y0 = up.y
		PlayerPhysics.tick(up, input(0, 0, { jump = true }), flat)
		t.ok(near(up.y - y0, 0.375, 1e-6), `rising {up.y - y0} blocks per tick`)
		t.ok(up.flying, "holding jump keeps flying")

		local down = flyer(0.5, 200, 0.5)
		for _ = 1, 40 do
			PlayerPhysics.tick(down, input(0, 0, { sneak = true }), flat)
		end
		y0 = down.y
		PlayerPhysics.tick(down, input(0, 0, { sneak = true }), flat)
		t.ok(near(down.y - y0, -0.375, 1e-6), `sinking {down.y - y0} blocks per tick`)
		t.eq(down.pose, "standing", "no crouching pose while flying")
		t.ok(not down.crouching, "not crouching")
		t.eq(down.fallDistance, 0, "flying never builds a fall distance")
	end)

	t.test("flight: landing stops flying, then sneaking crouches", function()
		local flat = physicsWorld()
		local state = flyer(0.5, 4, 0.5)
		local landedAt = nil
		for tick = 1, 30 do
			local events = PlayerPhysics.tick(state, input(0, 0, { sneak = true }), flat)
			t.ok(events.damage == 0, "no damage")
			if landedAt == nil and state.onGround then
				landedAt = tick
				t.ok(not state.flying, "touching the ground stops flying")
			end
		end
		t.ok(landedAt ~= nil and near(state.y, 1), `landed on the floor: {state.y}`)
		t.eq(state.pose, "crouching", "sneaking on the ground crouches again")
	end)

	t.test("flight: no edge back-off, no swimming; toggling needs mayFly and no swimming", function()
		-- A 3 x 3 platform at y = 10 over nothing: flying 0.3 above it with sneak + jump held (no
		-- vertical movement, but sneaking) goes past the edge.
		local platform = physicsWorld(function(x, y, z)
			if y == 10 and x >= 0 and x <= 2 and z >= 0 and z <= 2 then
				return STONE
			end
			return if y <= 0 then STONE else AIR
		end)
		local state = flyer(1.5, 11.3, 1.5)
		for _ = 1, 30 do
			PlayerPhysics.tick(state, input(1, 0, { sneak = true, jump = true }), platform)
		end
		t.ok(state.x > 6 and near(state.y, 11.3) and state.flying, `flew past the edge: {state.x}, {state.y}`)

		-- Flying under water with sprint never swims.
		local deep = physicsWorld(function(_x, y, _z)
			return if y >= 1 and y <= 30 then WATER else nil
		end)
		local diver = flyer(0.5, 10, 0.5)
		for _ = 1, 20 do
			PlayerPhysics.tick(diver, input(1, 0, { sprint = true, lookY = -0.5 }), deep)
			t.ok(not diver.swimming, "no swimming while flying")
		end
		t.ok(diver.flying and diver.underWater, "flying under water")
		-- Water does not slow flight (Player.isAffectedByFluids is false while flying).
		local wet = flyer(0.5, 10, 0.5)
		local x0 = 0
		for tick = 1, 100 do
			PlayerPhysics.tick(wet, input(1, 0), deep)
			if tick == 80 then
				x0 = wet.x
			end
		end
		t.ok(wet.flying and wet.inWater, "still flying in the water")
		t.near((wet.x - x0) / 20 * PlayerPhysics.TICK_RATE, 10.8889, 0.01, "full flying speed under water")
		local riser = flyer(0.5, 5, 0.5)
		for _ = 1, 20 do
			PlayerPhysics.tick(riser, input(0, 0, { jump = true }), deep)
		end
		local y0 = riser.y
		PlayerPhysics.tick(riser, input(0, 0, { jump = true }), deep)
		t.near(riser.y - y0, 0.375, 1e-4, "rises at the flying speed in water")

		-- A swimming player cannot start flying.
		local swimmer = PlayerPhysics.new(0.5, 10, 0.5)
		swimmer.mayFly = true
		for _ = 1, 3 do
			PlayerPhysics.tick(swimmer, input(0, 0), deep)
		end
		for _ = 1, 10 do
			PlayerPhysics.tick(swimmer, input(1, 0, { sprint = true, lookY = -0.5 }), deep)
		end
		t.ok(swimmer.swimming, "swimming")
		for tick = 1, 4 do
			PlayerPhysics.tick(
				swimmer,
				input(1, 0, { sprint = true, lookY = -0.5, jump = tick == 1 or tick == 3 }),
				deep
			)
		end
		t.ok(not swimmer.flying, "double tapping jump while swimming does not fly")

		-- Losing mayFly (switching to survival) stops flying at once; the player falls.
		local lost = flyer(0.5, 20, 0.5)
		PlayerPhysics.tick(lost, input(0, 0), physicsWorld())
		lost.mayFly = false
		PlayerPhysics.tick(lost, input(0, 0), physicsWorld())
		t.ok(not lost.flying and lost.vy < 0, `falls after losing mayFly: vy {lost.vy}`)
	end)

	t.test("flight: players who may fly take no fall damage but still report landings", function()
		local flat = physicsWorld()
		local function drop(height: number, mayFly: boolean): (number, number)
			local s = PlayerPhysics.new(0.5, 1 + height, 0.5)
			s.mayFly = mayFly
			for _ = 1, 100 do
				local events = PlayerPhysics.tick(s, input(0, 0), flat)
				if events.landed then
					return events.fallDistance, events.damage
				end
			end
			return -1, -1
		end
		local distance, damage = drop(24, true)
		t.ok(distance > 22 and damage == 0, `24 blocks with mayFly: {distance}, {damage}`)
		distance, damage = drop(24, false)
		t.ok(damage >= 19, `24 blocks without: {distance}, {damage}`)
	end)

	t.test("flight: the same double tap and flight give the same path", function()
		local world = physicsWorld(function(x, y, z)
			return if y == 1 and (x + z) % 7 == 0 then STONE else nil
		end)
		local function run(): string
			local state = PlayerPhysics.new(0.5, 1, 0.5)
			state.mayFly = true
			for tick = 1, 300 do
				local a = tick * 0.05
				PlayerPhysics.tick(
					state,
					input(math.cos(a), math.sin(a), {
						jump = tick == 1 or tick == 4 or (tick > 100 and tick < 140),
						sneak = tick > 200,
						sprint = tick > 50,
					}),
					world
				)
			end
			return `{state.x},{state.y},{state.z},{state.vx},{state.vy},{state.vz},{state.flying}`
		end
		t.eq(run(), run())
	end)
end

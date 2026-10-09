--[[
	How fast the server lets a player move (server Players/MoveCheck, pure): the limits per game
	mode; the buckets' refill and cap (Config.Players.MoveSlack seconds); real Movement/
	PlayerPhysics runs of 30 s in every mode (sprint-jumping on ice with Speed II, creative
	sprint-flying, the fastest spectator flight up and down, a long fall) sent at 20 a second with
	jittery latency are never refused; teleport-like jumps and sustained over-speed are; a 10 block
	a tick explosion push passes with its grant; the mode-switch grace; NaN and bounds; Terraria's
	accessories' speed factor (`setFactor`: the fastest of them sprinting passes, a minute of it
	without the factor and anything faster do not; a lowered factor waits the grace; nonsense
	counts as 1).
]]

return function(t, shared, require, server, _client)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local GameMode = require(shared.GameMode)
	local PlayerPhysics = require(shared.Movement.PlayerPhysics)
	local Protocol = require(shared.Net.Protocol)
	local MoveCheck = require(server.Players.MoveCheck)

	local SURVIVAL, CREATIVE, ADVENTURE, SPECTATOR =
		GameMode.SURVIVAL, GameMode.CREATIVE, GameMode.ADVENTURE, GameMode.SPECTATOR
	local SLACK = Config.Players.MoveSlack
	local TICK = 1 / PlayerPhysics.TICK_RATE

	-- A flat world of `floor` at y <= 0 (nil: nothing anywhere: falling forever).
	local function flat(floor: number?): PlayerPhysics.World
		return {
			getBlock = function(_x: number, y: number, _z: number): number?
				return if floor and y <= 0 then floor else Blocks.AIR
			end,
		}
	end

	local function input(moveX: number, moveZ: number, options: { [string]: any }?): PlayerPhysics.Input
		local o = options or {}
		local length = math.sqrt(moveX * moveX + moveZ * moveZ)
		return {
			moveX = moveX,
			moveZ = moveZ,
			forward = length,
			facingX = if length > 0 then moveX / length else 0,
			facingZ = if length > 0 then moveZ / length else 1,
			lookY = o.lookY or 0,
			jump = o.jump == true,
			sneak = o.sneak == true,
			sprint = o.sprint == true,
		}
	end

	--[[
		Runs `state` for `seconds` with `input` in `world` (a move after every tick, sent at the tick's
		time and arriving 50-250 ms later, so arrivals bunch and overtake: an overtaken move is dropped
		as PositionStore drops older sequence numbers), checking each against `bucket` from the last
		accepted place. Returns the refusals and the blocks travelled sideways.
	]]
	local function replay(
		state: PlayerPhysics.State,
		bucket: MoveCheck.Bucket,
		world: PlayerPhysics.World,
		i: PlayerPhysics.Input,
		seconds: number,
		seed: number
	): (number, number)
		-- (A deterministic pseudo-random latency: no math.random state shared with other specs.)
		local s = seed
		local sent: { { number } } = {}
		for tick = 1, math.floor(seconds / TICK) do
			PlayerPhysics.tick(state, i, world)
			s = (s * 1103515245 + 12345) % 2147483648
			table.insert(sent, { tick * TICK + 0.05 + s / 2147483648 * 0.2, tick, state.x, state.y, state.z })
		end
		table.sort(sent, function(a, b)
			return a[1] < b[1]
		end)
		local refused = 0
		local lastTick = 0
		local x, y, z = sent[1][3], sent[1][4], sent[1][5]
		local x0, z0 = x, z
		for _, move in sent do
			if move[2] > lastTick then
				lastTick = move[2]
				if MoveCheck.check(bucket, move[3] - x, move[4] - y, move[5] - z, move[1]) then
					x, y, z = move[3], move[4], move[5]
				else
					refused += 1
				end
			end
		end
		return refused, math.sqrt((x - x0) ^ 2 + (z - z0) ^ 2)
	end

	t.test("move check: limits per game mode come from Config", function()
		for _, mode in { SURVIVAL, CREATIVE, ADVENTURE, SPECTATOR } do
			local want = (Config.Players.MoveLimits :: any)[mode]
			local got = MoveCheck.limits(mode)
			t.eq(got.horizontal, want.horizontal, `{mode} horizontal`)
			t.eq(got.up, want.up, `{mode} up`)
			t.eq(got.down, want.down, `{mode} down`)
		end
		t.ok(MoveCheck.limits(CREATIVE).horizontal > MoveCheck.limits(SURVIVAL).horizontal, "creative is faster")
		t.ok(MoveCheck.limits(SPECTATOR).horizontal > MoveCheck.limits(CREATIVE).horizontal, "spectators fastest")
		t.eq(MoveCheck.limits("Nonsense").horizontal, MoveCheck.limits(SURVIVAL).horizontal, "unknown: survival's")
	end)

	t.test("move check: buckets refill in server time up to their cap", function()
		local limits = MoveCheck.limits(SURVIVAL)
		local cap = limits.horizontal * SLACK
		local bucket = MoveCheck.new(SURVIVAL, 100)
		t.ok(MoveCheck.check(bucket, cap - 0.01, 0, 0, 100), "a full bucket pays its cap")
		t.ok(not MoveCheck.check(bucket, 0.5, 0, 0, 100), "then it is empty")
		t.ok(MoveCheck.check(bucket, limits.horizontal - 0.1, 0, 0, 101), "a second refills a second's limit")
		t.ok(not MoveCheck.check(bucket, 1, 0, 0, 101), "and no more")
		-- Ten idle seconds still hold only the cap.
		t.ok(not MoveCheck.check(bucket, cap + 0.1, 0, 0, 111), "never above the cap")
		t.ok(MoveCheck.check(bucket, cap - 0.1, 0, 0, 111), "the cap")
		-- A refused move costs nothing.
		local fresh = MoveCheck.new(SURVIVAL, 0)
		t.ok(not MoveCheck.check(fresh, cap * 3, 0, 0, 0), "too far")
		t.ok(MoveCheck.check(fresh, cap - 0.1, 0, 0, 0), "the refused move took nothing")
		-- Up and down are buckets of their own, horizontal is the X/Z distance.
		local b = MoveCheck.new(SURVIVAL, 0)
		t.ok(MoveCheck.check(b, 3, 4, 4, 0), "5 sideways, 4 up")
		t.near(b.horizontal, cap - 5, 1e-9, "the X/Z distance")
		t.near(b.up, limits.up * SLACK - 4, 1e-9, "up")
		t.near(b.down, limits.down * SLACK, 1e-9, "down untouched")
		t.ok(not MoveCheck.check(b, 0, limits.up * SLACK, 0, 0), "up overdrawn")
		t.ok(MoveCheck.check(b, 0, -limits.down * SLACK + 1, 0, 0), "a long way down")
		-- Server time going backwards refills nothing.
		local back = MoveCheck.new(SURVIVAL, 10)
		t.ok(MoveCheck.check(back, cap - 0.1, 0, 0, 10), "emptied")
		t.ok(not MoveCheck.check(back, 1, 0, 0, 5), "an earlier time refills nothing")
		-- A reset (teleport) fills them.
		MoveCheck.reset(back, 10)
		t.ok(MoveCheck.check(back, cap - 0.1, 0, 0, 10), "full again after a reset")
	end)

	t.test("move check: 30 s of real movement in every mode is never refused", function()
		-- Survival: sprint-jumping on ice with Speed II (about 10 blocks a second).
		local runner = PlayerPhysics.new(0.5, 1, 0.5)
		runner.onGround = true
		runner.speedFactor = 1.4
		PlayerPhysics.setGameMode(runner, SURVIVAL)
		local refused, travelled = replay(
			runner,
			MoveCheck.new(SURVIVAL, 0),
			flat(Blocks.id.Ice),
			input(1, 0, { sprint = true, jump = true }),
			30,
			1
		)
		t.eq(refused, 0, "survival sprint-jumping on ice with Speed II")
		t.ok(travelled / 30 > 8, `it went fast: {travelled / 30} blocks a second`)

		-- Creative: sprint-flying (21.8 blocks a second), with Speed on top.
		local flyer = PlayerPhysics.new(0.5, 50, 0.5)
		PlayerPhysics.setGameMode(flyer, CREATIVE)
		flyer.flying = true
		flyer.speedFactor = 1.4
		refused, travelled =
			replay(flyer, MoveCheck.new(CREATIVE, 0), flat(Blocks.id.Stone), input(0.6, 0.8, { sprint = true }), 30, 2)
		t.eq(refused, 0, "creative sprint-flying")
		t.ok(travelled / 30 > 20, `sprint-flying: {travelled / 30} blocks a second`)
		-- Climbing and diving at full speed.
		refused = replay(flyer, MoveCheck.new(CREATIVE, 0), flat(), input(1, 0, { sprint = true, jump = true }), 10, 3)
		t.eq(refused, 0, "creative climbing")
		refused = replay(flyer, MoveCheck.new(CREATIVE, 0), flat(), input(1, 0, { sprint = true, sneak = true }), 10, 4)
		t.eq(refused, 0, "creative diving")

		-- Spectator: the fastest flight (scrolled to 0.2, sprinting), level, up and down.
		local ghost = PlayerPhysics.new(0.5, 500, 0.5)
		PlayerPhysics.setGameMode(ghost, SPECTATOR)
		ghost.flyingSpeed = PlayerPhysics.MAX_FLYING_SPEED
		refused, travelled = replay(ghost, MoveCheck.new(SPECTATOR, 0), flat(), input(1, 0, { sprint = true }), 30, 5)
		t.eq(refused, 0, "spectator at full speed")
		t.ok(travelled / 30 > 70, `spectating: {travelled / 30} blocks a second`)
		refused = replay(ghost, MoveCheck.new(SPECTATOR, 0), flat(), input(1, 0, { sprint = true, jump = true }), 10, 6)
		t.eq(refused, 0, "spectator rising")
		refused =
			replay(ghost, MoveCheck.new(SPECTATOR, 0), flat(), input(1, 0, { sprint = true, sneak = true }), 10, 7)
		t.eq(refused, 0, "spectator sinking")

		-- Adventure: a fall from 2000 blocks at terminal speed (3.92 a tick), then landing.
		local faller = PlayerPhysics.new(0.5, 2000, 0.5)
		PlayerPhysics.setGameMode(faller, ADVENTURE)
		refused = replay(faller, MoveCheck.new(ADVENTURE, 0), flat(Blocks.id.Stone), input(0, 0), 30, 8)
		t.eq(refused, 0, "a long fall")
		t.near(faller.y, 1, 1e-6, "it landed")
	end)

	t.test("move check: teleport-like jumps and sustained over-speed are refused", function()
		local bucket = MoveCheck.new(SURVIVAL, 0)
		t.ok(not MoveCheck.check(bucket, 50, 0, 0, 0.05), "50 blocks at once")
		t.ok(not MoveCheck.check(bucket, 0, 40, 0, 0.05), "40 up at once")
		-- Running at 30 blocks a second (a speed hack) is caught within a few seconds.
		local refusedAt = nil
		local x = 0
		local survival = MoveCheck.new(SURVIVAL, 0)
		for tick = 1, 200 do
			if MoveCheck.check(survival, 1.5, 0, 0, tick * TICK) then
				x += 1.5
			elseif refusedAt == nil then
				refusedAt = tick * TICK
			end
		end
		t.ok(refusedAt ~= nil and refusedAt < 3, `refused after {refusedAt} s`)
		t.ok(x / 10 < MoveCheck.limits(SURVIVAL).horizontal + 3, `kept to the limit: {x / 10} blocks a second`)
		-- Flying up in survival (a fly hack).
		local floating = MoveCheck.new(SURVIVAL, 0)
		local up = 0
		for tick = 1, 200 do
			if MoveCheck.check(floating, 0, 1, 0, tick * TICK) then
				up += 1
			end
		end
		t.ok(up / 10 < MoveCheck.limits(SURVIVAL).up + 3, `rising kept to the limit: {up / 10} a second`)
	end)

	t.test("move check: an explosion's push passes with its grant", function()
		-- The strongest push (Protocol.MAX_KNOCKBACK blocks a tick), up and away, over ice.
		local k = Protocol.MAX_KNOCKBACK
		local kx, ky = k * 0.995, k * 0.0998
		local state = PlayerPhysics.new(0.5, 1, 0.5)
		state.onGround = true
		PlayerPhysics.setGameMode(state, SURVIVAL)
		t.ok(PlayerPhysics.knockback(state, kx, ky, 0), "pushed")
		local without = MoveCheck.new(SURVIVAL, 0)
		local with = MoveCheck.new(SURVIVAL, 0)
		MoveCheck.grant(with, 12 * math.sqrt(kx * kx + ky * ky), 0)
		local refusedWithout, refusedWith = 0, 0
		local x, y = state.x, state.y
		local wx, wy = x, y
		local world = flat(Blocks.id.Ice)
		for tick = 1, 100 do
			PlayerPhysics.tick(state, input(0, 0), world)
			local now = tick * TICK
			if MoveCheck.check(without, state.x - x, state.y - y, 0, now) then
				x, y = state.x, state.y
			else
				refusedWithout += 1
			end
			if MoveCheck.check(with, state.x - wx, state.y - wy, 0, now) then
				wx, wy = state.x, state.y
			else
				refusedWith += 1
			end
		end
		t.ok(state.x - 0.5 > 60, `it flew {state.x - 0.5} blocks`)
		t.ok(refusedWithout > 0, "without the grant it is refused")
		t.eq(refusedWith, 0, "with the grant it passes")
		-- A grant fades: two seconds later the cap is the cap again.
		local b = MoveCheck.new(SURVIVAL, 0)
		MoveCheck.grant(b, 100, 0)
		t.ok(b.horizontal > MoveCheck.limits(SURVIVAL).horizontal * SLACK, "over the cap")
		t.ok(not MoveCheck.check(b, 100, 0, 0, MoveCheck.GRACE + 0.5), "spent after the grace")
		MoveCheck.grant(b, 0 / 0, 3)
		MoveCheck.grant(b, -5, 3)
		MoveCheck.grant(b, math.huge, 3)
		t.ok(b.horizontal == b.horizontal and b.horizontal < math.huge, "NaN, negative and infinite grants: none")
	end)

	t.test("move check: a game mode change gives the larger limits for a while", function()
		-- A creative sprint-flyer switched to survival keeps going for the grace.
		local bucket = MoveCheck.new(CREATIVE, 0)
		local step = 21.8 * TICK
		for tick = 1, 40 do
			t.ok(MoveCheck.check(bucket, step, 0, 0, tick * TICK), "creative flight")
		end
		MoveCheck.setMode(bucket, SURVIVAL, 2)
		local refusedAt = nil
		for tick = 41, 400 do
			if not MoveCheck.check(bucket, step, 0, 0, tick * TICK) and refusedAt == nil then
				refusedAt = tick * TICK
			end
		end
		t.ok(refusedAt ~= nil, "refused once the grace is over")
		t.ok((refusedAt :: number) > 2 + MoveCheck.GRACE, `not during the grace: {refusedAt}`)
		-- Survival switched to spectator may fly at once (the larger is the new one).
		local walker = MoveCheck.new(SURVIVAL, 0)
		MoveCheck.setMode(walker, SPECTATOR, 0)
		t.ok(MoveCheck.check(walker, 0, 0, 0, 1), "nothing moved")
		for tick = 1, 20 do
			t.ok(MoveCheck.check(walker, 80 * TICK, 0, 0, 1 + tick * TICK), "spectator speed at once")
		end
		-- The same mode again changes nothing.
		local same = MoveCheck.new(SURVIVAL, 0)
		MoveCheck.setMode(same, SURVIVAL, 0)
		t.eq(same.previous, nil, "no previous mode")
	end)

	t.test("move check: the accessories' factor lets the fastest of them through, and no more", function()
		-- The fastest worn: Aglet and Anklet of the Wind (x 1.15) with Hermes Boots built up
		-- (x 1.4) and Speed II (x 1.4), sprinting on stone (12.65 blocks a second, the fastest
		-- they go: sprint-jumping is slower, its air acceleration is not sped up): the factor
		-- the server sets for them is (1 + 0.15) x (1 + 0.4) = 1.61.
		local factor = (1 + 0.15) * (1 + 0.4)
		local function runner(): PlayerPhysics.State
			local state = PlayerPhysics.new(0.5, 1, 0.5)
			state.onGround = true
			PlayerPhysics.setGameMode(state, SURVIVAL)
			state.speedFactor = 1.4 * 1.15
			state.runBoost = 0.4
			return state
		end
		local sprint = input(1, 0, { sprint = true })
		local bucket = MoveCheck.new(SURVIVAL, 0)
		MoveCheck.setFactor(bucket, factor, 0)
		local refused, travelled = replay(runner(), bucket, flat(Blocks.id.Stone), sprint, 60, 11)
		t.eq(refused, 0, "Hermes Boots, two speed accessories and Speed II sprinting")
		local speed = travelled / 60
		t.ok(speed > MoveCheck.limits(SURVIVAL).horizontal, `faster than survival's limit: {speed} blocks a second`)
		t.ok(speed < MoveCheck.limits(SURVIVAL).horizontal * factor, `within the factor's: {speed}`)
		-- Sprint-jumping on ice with all of it passes too.
		local hops = MoveCheck.new(SURVIVAL, 0)
		MoveCheck.setFactor(hops, factor, 0)
		refused = replay(runner(), hops, flat(Blocks.id.Ice), input(1, 0, { sprint = true, jump = true }), 30, 12)
		t.eq(refused, 0, "sprint-jumping on ice")
		-- Without the factor the sprint is refused (0.65 blocks a second over 12 overdraws the
		-- 2 s of slack within a minute).
		refused = replay(runner(), MoveCheck.new(SURVIVAL, 0), flat(Blocks.id.Stone), sprint, 60, 11)
		t.ok(refused > 0, `refused without it ({refused})`)
		-- Beyond the factor's limit (a speed hack at 25 blocks a second) is refused within seconds.
		local hacked = MoveCheck.new(SURVIVAL, 0)
		MoveCheck.setFactor(hacked, factor, 0)
		local refusedAt = nil
		for tick = 1, 200 do
			if not MoveCheck.check(hacked, 25 * TICK, 0, 0, tick * TICK) and refusedAt == nil then
				refusedAt = tick * TICK
			end
		end
		t.ok(refusedAt ~= nil and (refusedAt :: number) < 6, `25 blocks a second refused after {refusedAt} s`)
		-- Up keeps its limit: the factor is sideways only.
		local up = MoveCheck.new(SURVIVAL, 0)
		MoveCheck.setFactor(up, factor, 0)
		t.near(up.up, MoveCheck.limits(SURVIVAL).up * SLACK, 1e-9, "up unchanged")
		t.ok(not MoveCheck.check(up, 0, MoveCheck.limits(SURVIVAL).up * SLACK + 1, 0, 0), "up's cap")
	end)

	t.test("move check: a lower factor waits out the grace; nonsense counts as 1", function()
		local bucket = MoveCheck.new(SURVIVAL, 0)
		local h = MoveCheck.limits(SURVIVAL).horizontal
		MoveCheck.setFactor(bucket, 1.5, 0)
		t.eq(bucket.factor, 1.5)
		-- At 1.5 x the limit for 4 s: fine while worn.
		for tick = 1, 80 do
			t.ok(MoveCheck.check(bucket, h * 1.45 * TICK, 0, 0, tick * TICK), "worn")
		end
		-- Taken off at 4 s: the client may still be fast for a moment (the grace), then not.
		MoveCheck.setFactor(bucket, 1, 4)
		local refusedAt = nil
		for tick = 81, 400 do
			if not MoveCheck.check(bucket, h * 1.45 * TICK, 0, 0, tick * TICK) and refusedAt == nil then
				refusedAt = tick * TICK
			end
		end
		t.ok(refusedAt ~= nil and (refusedAt :: number) > 4 + MoveCheck.GRACE, `after the grace: {refusedAt}`)
		for _, bad in { 0 / 0, -2, 0.5, math.huge } do
			local b = MoveCheck.new(SURVIVAL, 0)
			MoveCheck.setFactor(b, bad, 0)
			t.eq(b.factor, 1, `factor {bad}`)
		end
	end)
	t.test("move check: NaN and out of bounds", function()
		local bucket = MoveCheck.new(SPECTATOR, 0)
		t.ok(not MoveCheck.check(bucket, 0 / 0, 0, 0, 0), "NaN x")
		t.ok(not MoveCheck.check(bucket, 0, 0 / 0, 0, 0), "NaN y")
		t.ok(not MoveCheck.check(bucket, 0, 0, math.huge, 0), "infinite z")
		t.ok(MoveCheck.inBounds(0, 64, 0), "the spawn")
		t.ok(MoveCheck.inBounds(Protocol.MAX_COORDINATE, -256, -Protocol.MAX_COORDINATE), "the corners")
		t.ok(not MoveCheck.inBounds(Protocol.MAX_COORDINATE + 1, 64, 0), "beyond x")
		t.ok(not MoveCheck.inBounds(0, 64, -Protocol.MAX_COORDINATE - 1), "beyond z")
		t.ok(not MoveCheck.inBounds(0, -257, 0), "too deep")
		t.ok(not MoveCheck.inBounds(0, 4097, 0), "too high")
		t.ok(not MoveCheck.inBounds(0 / 0, 0, 0), "NaN")
		t.ok(not MoveCheck.inBounds(0, 0, math.huge), "infinite")
	end)
end

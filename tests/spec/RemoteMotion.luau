--[[
	Other players drawn between the server's poses (client Player/RemoteMotion, pure): the feet
	glide between two snapshots (doubles, exact far from 0), the yaw the short way round across 0 /
	2 pi, flags switch half way; before the oldest the oldest; after the newest carried on along the
	last velocity for at most 0.1 s, then held; a jump of more than 8 blocks is a teleport (no
	glide); snapshots not newer than the newest are ignored and the ring keeps the newest; a track's
	pose with no time is held until the first pose's. The server clock: u16 ticks unwrapped across
	the wrap and for late messages, the estimate following the fastest message under jitter (never
	ahead of the server), forgetting a slow spell within 2 s, nothing before the first message; the
	playback delay.
]]

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local PlayerSync = require(shared.Net.PlayerSync)
	local RemoteMotion = require(client.Player.RemoteMotion)

	local TICK = RemoteMotion.TICK
	local DELAY = Config.Interest.InterpolationDelay
	local TWO_PI = 2 * math.pi

	local function pose(x: number, y: number, z: number, yaw: number?, flags: number?): any
		return {
			x = x,
			y = y,
			z = z,
			yaw = yaw or 0,
			pitch = 0,
			tilt = 0,
			flags = flags or 0,
			speed = 0,
			climb = 0,
		}
	end

	local function sampled(motion: any, at: number): any
		local out = pose(0, 0, 0)
		t.ok(RemoteMotion.sample(motion, at, out), `a pose at {at}`)
		return out
	end

	local function angle(a: number, b: number): number
		local d = (a - b) % TWO_PI
		return math.min(d, TWO_PI - d)
	end

	t.test("remote motion: nothing to draw before the first pose", function()
		local motion = RemoteMotion.new()
		t.eq(RemoteMotion.sample(motion, 0, pose(0, 0, 0)), false)
		t.eq(RemoteMotion.newest(motion), nil)
	end)

	t.test("remote motion: feet glide between two snapshots, in doubles far from 0", function()
		local motion = RemoteMotion.new()
		local far = 999999.25
		RemoteMotion.push(motion, 10, pose(far, 64, -far))
		RemoteMotion.push(motion, 10.05, pose(far + 0.5, 64.25, -far - 1))
		local half = sampled(motion, 10.025)
		t.near(half.x, far + 0.25, 1e-9, "x half way")
		t.near(half.y, 64.125, 1e-9, "y half way")
		t.near(half.z, -far - 0.5, 1e-9, "z half way")
		local quarter = sampled(motion, 10.0125)
		t.near(quarter.x, far + 0.125, 1e-9, "x a quarter of the way")
		-- Before the oldest: the oldest.
		local before = sampled(motion, 9)
		t.eq(before.x, far)
		t.eq(before.y, 64)
	end)

	t.test("remote motion: the yaw turns the short way round across 0 and 2 pi", function()
		local motion = RemoteMotion.new()
		RemoteMotion.push(motion, 1, pose(0, 0, 0, TWO_PI - 0.2))
		RemoteMotion.push(motion, 2, pose(0, 0, 0, 0.2))
		t.ok(angle(sampled(motion, 1.5).yaw, 0) < 1e-9, "through 0, not round the back")
		t.ok(angle(sampled(motion, 1.25).yaw, TWO_PI - 0.1) < 1e-9, "a quarter of the way")
		local yaw = sampled(motion, 1.75).yaw
		t.ok(yaw >= 0 and yaw < TWO_PI, "kept in [0, 2 pi)")
		t.near(RemoteMotion.lerpYaw(3, -3, 0.5), math.pi, 1e-9, "3 to -3 the short way passes pi")
	end)

	t.test("remote motion: flags switch half way; pitch, tilt, speed and climb lerp", function()
		local motion = RemoteMotion.new()
		local a = pose(0, 0, 0, 0, PlayerSync.Flag.OnGround)
		local b = pose(1, 0, 0, 0, PlayerSync.Flag.Sneaking)
		b.pitch, b.tilt, b.speed, b.climb = 1, 1, 4, -2
		RemoteMotion.push(motion, 0, a)
		RemoteMotion.push(motion, 1, b)
		local early = sampled(motion, 0.4)
		t.eq(early.flags, PlayerSync.Flag.OnGround)
		t.near(early.pitch, 0.4, 1e-9)
		t.near(early.tilt, 0.4, 1e-9)
		t.near(early.speed, 1.6, 1e-9)
		t.near(early.climb, -0.8, 1e-9)
		t.eq(sampled(motion, 0.6).flags, PlayerSync.Flag.Sneaking)
	end)

	t.test("remote motion: extrapolated for at most 0.1 s past the newest, then held", function()
		local motion = RemoteMotion.new()
		-- 5 blocks a second along X.
		RemoteMotion.push(motion, 0, pose(0, 10, 0))
		RemoteMotion.push(motion, 0.05, pose(0.25, 10, 0))
		t.near(sampled(motion, 0.05).x, 0.25, 1e-9, "at the newest")
		t.near(sampled(motion, 0.1).x, 0.5, 1e-9, "carried on 0.05 s")
		t.near(sampled(motion, 0.15).x, 0.75, 1e-9, "carried on 0.1 s")
		t.near(sampled(motion, 0.5).x, 0.75, 1e-9, "then held")
		t.near(sampled(motion, 100).x, 0.75, 1e-9, "held for good")
		t.eq(sampled(motion, 100).y, 10)
		-- One snapshot alone is held.
		local alone = RemoteMotion.new()
		RemoteMotion.push(alone, 3, pose(7, 8, 9))
		t.eq(sampled(alone, 4).x, 7)
	end)

	t.test("remote motion: a jump of more than 8 blocks is a teleport, no glide", function()
		local motion = RemoteMotion.new()
		RemoteMotion.push(motion, 0, pose(0, 64, 0))
		RemoteMotion.push(motion, 0.05, pose(100, 64, 0))
		t.eq(sampled(motion, 0.01).x, 0, "still at the start before the jump's time")
		t.eq(sampled(motion, 0.049).x, 0)
		t.eq(sampled(motion, 0.05).x, 100, "there at its time")
		t.eq(sampled(motion, 0.12).x, 100, "and not carried on along the jump")
		-- 8 blocks exactly still glides.
		local walk = RemoteMotion.new()
		RemoteMotion.push(walk, 0, pose(0, 0, 0))
		RemoteMotion.push(walk, 1, pose(8, 0, 0))
		t.near(sampled(walk, 0.5).x, 4, 1e-9)
	end)

	t.test("remote motion: snapshots out of order or repeated are ignored; the ring keeps the newest", function()
		local motion = RemoteMotion.new()
		t.eq(RemoteMotion.push(motion, 1, pose(1, 0, 0)), true)
		t.eq(RemoteMotion.push(motion, 2, pose(2, 0, 0)), true)
		t.eq(RemoteMotion.push(motion, 1.5, pose(50, 0, 0)), false, "late")
		t.eq(RemoteMotion.push(motion, 2, pose(60, 0, 0)), false, "repeated")
		t.near(sampled(motion, 1.5).x, 1.5, 1e-9, "the late one changed nothing")
		for i = 3, 3 + RemoteMotion.SNAPSHOTS * 2 do
			t.ok(RemoteMotion.push(motion, i, pose(i, 0, 0)), `pose {i}`)
		end
		local newest = 3 + RemoteMotion.SNAPSHOTS * 2
		t.eq(RemoteMotion.newest(motion), newest)
		t.eq(motion.count, RemoteMotion.SNAPSHOTS)
		-- The oldest kept is SNAPSHOTS back; earlier times give it.
		t.eq(sampled(motion, 0).x, newest - RemoteMotion.SNAPSHOTS + 1)
		t.near(sampled(motion, newest - 0.5).x, newest - 0.5, 1e-9)
	end)

	t.test("remote motion: a track with no time is held until the first pose's time", function()
		local motion = RemoteMotion.new()
		RemoteMotion.place(motion, -math.huge, pose(5, 5, 5))
		t.eq(sampled(motion, 123).x, 5, "held")
		RemoteMotion.push(motion, 200, pose(6, 5, 5))
		t.eq(sampled(motion, 150).x, 5, "no glide from no time")
		t.eq(sampled(motion, 200).x, 6)
		t.eq(sampled(motion, 200.2).x, 6, "and no velocity from it")
		-- A track with a time glides on into the next pose.
		RemoteMotion.place(motion, 10, pose(0, 0, 0))
		t.eq(motion.count, 1)
		RemoteMotion.push(motion, 11, pose(2, 0, 0))
		t.near(sampled(motion, 10.5).x, 1, 1e-9)
	end)

	t.test("remote clock: ticks unwrap across the u16 wrap and for late messages", function()
		local clock = RemoteMotion.newClock()
		t.eq(RemoteMotion.serverNow(clock, 0), nil, "nothing before the first message")
		t.eq(RemoteMotion.playback(clock, 0), nil)
		local first = RemoteMotion.observe(clock, 65534, 0)
		t.near(first, 65534 * TICK, 1e-9)
		t.near(RemoteMotion.observe(clock, 65535, TICK), 65535 * TICK, 1e-9)
		t.near(RemoteMotion.observe(clock, 0, 2 * TICK), 65536 * TICK, 1e-9, "across the wrap")
		t.near(RemoteMotion.observe(clock, 3, 5 * TICK), 65539 * TICK, 1e-9)
		t.near(RemoteMotion.observe(clock, 65535, 5.5 * TICK), 65535 * TICK, 1e-9, "a late one back over it")
		t.near(RemoteMotion.observe(clock, 4, 6 * TICK), 65540 * TICK, 1e-9, "and forward again")
	end)

	t.test("remote clock: the estimate follows the fastest message under jitter", function()
		local clock = RemoteMotion.newClock()
		-- The server's tick n at server time n * TICK; the local clock is 1000 s ahead, latency 40
		-- ms plus up to 80 ms of jitter.
		local seed = 12345
		local function jitter(): number
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed / 2147483648 * 0.08
		end
		local least, most = math.huge, -math.huge
		for n = 1, 400 do
			local arrival = 1000 + n * TICK + 0.04 + jitter()
			RemoteMotion.observe(clock, n % 65536, arrival)
			local server = RemoteMotion.serverNow(clock, arrival) :: number
			-- The message's own tick is never in the estimate's future (it was sent already).
			t.ok(server >= n * TICK - 1e-9, `not behind the tick at {n}`)
			if n > 40 then
				least = math.min(least, server - n * TICK)
				most = math.max(most, server - n * TICK)
			end
		end
		-- Once warm the estimate is each tick's time plus at most the jitter (the least latency is
		-- the part no client can see).
		t.ok(least >= -1e-9 and most <= 0.08 + 1e-9, `within the jitter: {least} .. {most}`)
		local playback = RemoteMotion.playback(clock, 1000 + 400 * TICK + 0.04) :: number
		t.near(playback, RemoteMotion.serverNow(clock, 1000 + 400 * TICK + 0.04) :: number - DELAY, 1e-9)
	end)

	t.test("remote clock: a slower network is followed within 2 s, a faster one at once", function()
		local clock = RemoteMotion.newClock()
		local n = 0
		local function message(latency: number, at: number)
			n += 1
			RemoteMotion.observe(clock, n % 65536, at)
			return at - latency
		end
		local now = 0
		for _ = 1, 40 do
			now += TICK
			message(0.02, now)
		end
		-- Server time = arrival - 0.02 so far; the offset is now - n * TICK.
		local fast = RemoteMotion.serverNow(clock, now) :: number
		t.near(fast, n * TICK, 1e-9, "the fast network")
		-- Latency rises by 0.2 s for good: within 2 s the estimate is the slower one.
		local shift = 0.2
		for _ = 1, 50 do
			now += TICK
			n += 1
			RemoteMotion.observe(clock, n % 65536, now + shift)
		end
		local slow = RemoteMotion.serverNow(clock, now + shift) :: number
		t.near(slow, n * TICK, 1e-9, "followed the slower network")
		-- A faster message is taken at once.
		n += 1
		now += TICK
		RemoteMotion.observe(clock, n % 65536, now)
		t.near(RemoteMotion.serverNow(clock, now) :: number, n * TICK, 1e-9, "a faster one at once")
		-- After a silence the old estimate is dropped.
		n += 100
		now += 100 * TICK + 0.3
		RemoteMotion.observe(clock, n % 65536, now)
		t.near(RemoteMotion.serverNow(clock, now) :: number, n * TICK, 1e-9, "after a silence")
	end)
end

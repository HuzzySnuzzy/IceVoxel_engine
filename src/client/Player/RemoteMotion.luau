--!strict
--[[
	Where another player is drawn this frame, from the poses the server relays (Player/RemotePlayers'
	networked backend, Config.Players.ServerPositions): pure, so tests/spec/RemoteMotion runs it.
	Minecraft moves other players towards each new position over 3 ticks (lerpSteps); this draws
	them a fixed delay behind the server instead, between the two poses around that moment (the
	Source engine's entity interpolation), which hides the unreliable remote's jitter and losses.

	Server time (a Clock, one per server). The relay stamps every Poses message with its tick
	(u16, 1 / Config.Interest.RelayRate s, wrapping after 65,536 ticks: 54 minutes at 20 a second).
	`observe` unwraps it against the previous one (the nearer way round, so a late message lands
	before it) into server seconds, and keeps the smallest `arrival - server seconds` seen over the
	last 1 to 2 s (two one-second windows): the offset of the fastest message. `serverNow(now)` is
	`now` minus that offset, the server's clock as the quickest message showed it; it follows a
	slower network within 2 s and a faster one at once. Playback is serverNow - InterpolationDelay
	(Config.Interest, 0.1 s: two relay ticks), so a message may come 0.1 s later than the fastest
	and still be in time.

	Snapshots (a Motion, one per tracked player; a ring of SNAPSHOTS reused records): `push`es come
	in tick order; one not newer than the newest is ignored (the unreliable remote may reorder or
	repeat). `sample(motion, t, out)` writes the pose at server time `t` into `out`:
	  before the oldest   the oldest
	  between a and b     feet lerped (doubles), yaw the short way round, look pitch, tilt, speed
	                      and climb lerped, flags of the nearer of the two; a jump of more than
	                      SNAP_DISTANCE (8 blocks) between them is a teleport: a until b's time, then
	                      b, never a glide through the world
	  after the newest    carried on along the last two snapshots' velocity for at most
	                      EXTRAPOLATE (0.1 s), then held (a lost message, a player who stopped:
	                      their keepalives come every Interest.KeepAliveSeconds)
	`place` starts again from one snapshot (a track: the Players message's whole pose; with no
	clock yet its time is -inf, held until the first pose comes).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

local RemoteMotion = {}

-- Snapshots kept per player (0.4 s at 20 a second: twice the delay and the extrapolation).
RemoteMotion.SNAPSHOTS = 8
-- A move longer than this (blocks) between two snapshots is a teleport: no glide.
RemoteMotion.SNAP_DISTANCE = 8
-- Seconds past the newest snapshot a player is carried on along their velocity, then held.
RemoteMotion.EXTRAPOLATE = 0.1
-- Seconds a relay tick lasts.
RemoteMotion.TICK = 1 / math.max(1, Config.Interest.RelayRate)
-- Seconds of a window of the server clock's smallest offset (the estimate covers the last two).
RemoteMotion.WINDOW = 1

local TWO_PI = 2 * math.pi
local SNAP_SQUARED = RemoteMotion.SNAP_DISTANCE * RemoteMotion.SNAP_DISTANCE

-- A pose: feet (world blocks, doubles), yaw and look pitch (radians), tilt (0..1), PlayerSync.Flag
-- bits, horizontal and vertical speed (blocks a second). Remote records have these fields too.
export type Pose = {
	x: number,
	y: number,
	z: number,
	yaw: number,
	pitch: number,
	tilt: number,
	flags: number,
	speed: number,
	climb: number,
}

type Snapshot = Pose & { t: number }

export type Motion = {
	-- The ring and where its oldest snapshot is (1-based), and how many it holds.
	ring: { Snapshot },
	first: number,
	count: number,
}

export type Clock = {
	-- The last tick seen (nil: none yet) and its unwrapped count.
	tick: number?,
	ticks: number,
	-- The smallest arrival - server seconds of this window and the one before, and when this one
	-- started (os.clock seconds).
	current: number,
	previous: number,
	windowAt: number,
}

--[[ Server time ]]

function RemoteMotion.newClock(): Clock
	return { tick = nil, ticks = 0, current = math.huge, previous = math.huge, windowAt = -math.huge }
end

--[[
	A Poses message of relay tick `tick` (u16) arrived at `arrival` (os.clock seconds): returns its
	server time (seconds, unwrapped) and updates the clock's estimate.
]]
function RemoteMotion.observe(clock: Clock, tick: number, arrival: number): number
	local last = clock.tick
	if last == nil then
		clock.ticks = tick
	else
		-- (The nearer way round: within half the range ahead or behind.)
		clock.ticks += (tick - last + 32768) % 65536 - 32768
	end
	clock.tick = tick
	local seconds = clock.ticks * RemoteMotion.TICK
	local since = arrival - clock.windowAt
	if since >= 2 * RemoteMotion.WINDOW then
		-- (Nothing came for a while: what was seen then says nothing about now.)
		clock.previous, clock.current, clock.windowAt = math.huge, math.huge, arrival
	elseif since >= RemoteMotion.WINDOW then
		clock.previous, clock.current, clock.windowAt = clock.current, math.huge, arrival
	end
	local offset = arrival - seconds
	if offset < clock.current then
		clock.current = offset
	end
	return seconds
end

-- The server's time (seconds) at local time `now` as the fastest recent message showed it; nil
-- before any message.
function RemoteMotion.serverNow(clock: Clock, now: number): number?
	local offset = math.min(clock.current, clock.previous)
	if offset == math.huge then
		return nil
	end
	return now - offset
end

-- The server time other players are drawn at for local time `now` (serverNow - the delay), nil
-- before any message.
function RemoteMotion.playback(clock: Clock, now: number): number?
	local server = RemoteMotion.serverNow(clock, now)
	if server == nil then
		return nil
	end
	return server - Config.Interest.InterpolationDelay
end

--[[ Snapshots ]]

local function newSnapshot(): Snapshot
	return { t = -math.huge, x = 0, y = 0, z = 0, yaw = 0, pitch = 0, tilt = 0, flags = 0, speed = 0, climb = 0 }
end

function RemoteMotion.new(): Motion
	local ring: { Snapshot } = table.create(RemoteMotion.SNAPSHOTS)
	for i = 1, RemoteMotion.SNAPSHOTS do
		ring[i] = newSnapshot()
	end
	return { ring = ring, first = 1, count = 0 }
end

-- The i-th snapshot from the oldest (1-based).
local function at(motion: Motion, i: number): Snapshot
	return motion.ring[(motion.first + i - 2) % RemoteMotion.SNAPSHOTS + 1]
end

local function copy(into: Snapshot, t: number, pose: Pose)
	into.t = t
	into.x, into.y, into.z = pose.x, pose.y, pose.z
	into.yaw, into.pitch, into.tilt = pose.yaw, pose.pitch, pose.tilt
	into.flags, into.speed, into.climb = pose.flags, pose.speed, pose.climb
end

-- Adds the pose of server time `t`; false (ignored) when it is not newer than the newest.
function RemoteMotion.push(motion: Motion, t: number, pose: Pose): boolean
	local count = motion.count
	if count > 0 and t <= at(motion, count).t then
		return false
	end
	if count == RemoteMotion.SNAPSHOTS then
		motion.first = motion.first % RemoteMotion.SNAPSHOTS + 1
		count -= 1
	end
	motion.count = count + 1
	copy(at(motion, count + 1), t, pose)
	return true
end

-- Starts again from `pose` alone at server time `t` (a track; -math.huge: held until the next).
function RemoteMotion.place(motion: Motion, t: number, pose: Pose)
	motion.first, motion.count = 1, 1
	copy(motion.ring[1], t, pose)
end

-- The newest snapshot's server time, nil when there is none.
function RemoteMotion.newest(motion: Motion): number?
	if motion.count == 0 then
		return nil
	end
	return at(motion, motion.count).t
end

local function write(out: Pose, s: Snapshot)
	out.x, out.y, out.z = s.x, s.y, s.z
	out.yaw, out.pitch, out.tilt = s.yaw, s.pitch, s.tilt
	out.flags, out.speed, out.climb = s.flags, s.speed, s.climb
end

-- Is the step from `a` to `b` a teleport (or has `a` no time to glide from)?
local function snaps(a: Snapshot, b: Snapshot): boolean
	local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
	return dx * dx + dy * dy + dz * dz > SNAP_SQUARED or a.t == -math.huge
end

-- The yaw `alpha` of the way from `a` to `b` the short way round, in [0, 2 pi).
function RemoteMotion.lerpYaw(a: number, b: number, alpha: number): number
	local turn = (b - a + math.pi) % TWO_PI - math.pi
	return (a + turn * alpha) % TWO_PI
end

-- Writes the pose at server time `t` into `out` (see the header); false when there is none.
function RemoteMotion.sample(motion: Motion, t: number, out: Pose): boolean
	local count = motion.count
	if count == 0 then
		return false
	end
	local newest = at(motion, count)
	if t >= newest.t then
		write(out, newest)
		if count >= 2 and t > newest.t then
			local before = at(motion, count - 1)
			local span = newest.t - before.t
			if span > 0 and not snaps(before, newest) then
				local ahead = math.min(t - newest.t, RemoteMotion.EXTRAPOLATE) / span
				out.x = newest.x + (newest.x - before.x) * ahead
				out.y = newest.y + (newest.y - before.y) * ahead
				out.z = newest.z + (newest.z - before.z) * ahead
			end
		end
		return true
	end
	local oldest = at(motion, 1)
	if t <= oldest.t then
		write(out, oldest)
		return true
	end
	-- (Few snapshots: look back from the newest for the pair around t.)
	local b = newest
	for i = count - 1, 1, -1 do
		local a = at(motion, i)
		if a.t <= t then
			if snaps(a, b) then
				write(out, a)
				return true
			end
			local alpha = (t - a.t) / (b.t - a.t)
			out.x = a.x + (b.x - a.x) * alpha
			out.y = a.y + (b.y - a.y) * alpha
			out.z = a.z + (b.z - a.z) * alpha
			out.yaw = RemoteMotion.lerpYaw(a.yaw, b.yaw, alpha)
			out.pitch = a.pitch + (b.pitch - a.pitch) * alpha
			out.tilt = a.tilt + (b.tilt - a.tilt) * alpha
			out.speed = a.speed + (b.speed - a.speed) * alpha
			out.climb = a.climb + (b.climb - a.climb) * alpha
			out.flags = if alpha < 0.5 then a.flags else b.flags
			return true
		end
		b = a
	end
	write(out, oldest)
	return true
end

return RemoteMotion

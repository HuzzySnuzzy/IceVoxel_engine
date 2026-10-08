--!strict
--[[
	How fast a player may move, for the server's own player positions (Config.Players
	.ServerPositions: a client says where its player is in Move messages, Players/PositionStore
	keeps it). Pure, so the tests replay real Movement/PlayerPhysics runs through it. The Roblox
	docs' advice for client-owned movement (leaky buckets, X/Z apart, teleports exempt) and
	Minecraft's ServerGamePacketListenerImpl.handleMovePlayer ("moved too quickly") in one:

	  buckets    three per player: horizontal (the X/Z distance), up and down (Y). Each refills at
	             its limit for the player's game mode (Config.Players.MoveLimits, blocks a
	             second) up to MoveSlack (2) seconds of it, in server time, so moves that arrive
	             late and bunched (latency, a hitch) are paid by the time that passed. A move costs
	             its displacement; one that would overdraw any bucket is refused (and costs
	             nothing: the next one is measured from the last accepted place).
	  limits     survival and adventure 12 / 12 / 80 (sprint-jumping on ice with Speed II is
	             about 10 a second, a step up 1.06 a tick, falling at most 3.92 a tick = 78),
	             creative 30 / 30 / 80 (sprint-flying 21.8, plus Speed), spectator 100 each
	             (the fastest flight, 0.2 sprinting, about 87): generous, since a false refusal
	             rubber-bands an honest player.
	  modes      for GRACE seconds after a game mode change the larger of the old and the new
	             limits applies, so a creative flyer switched to survival may fall and one whose
	             client hasn't heard of the change yet isn't refused.
	  grants     knockback the server gave (an explosion's push, a mob's hit: `grant`, blocks)
	             adds to all three buckets and may take them over their cap for GRACE seconds.
	  teleports  `reset` fills the buckets (the server moved the player itself).
	  bounds     `inBounds`: finite, |x| and |z| within Protocol.MAX_COORDINATE, y within
	             -256 .. 4096 (Net/PlayerSync's decoders refuse the rest already).

	Not checked (client-trusted as before): collisions and noClip, fall distance (the Fall
	message), exertion. A later step can re-run PlayerPhysics against the server's blocks.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local PlayerSync = require(Shared.Net.PlayerSync)
local Protocol = require(Shared.Net.Protocol)

local MoveCheck = {}

-- Seconds a game mode change (the larger limits) and a grant (over the cap) last.
MoveCheck.GRACE = 2

export type Limits = { horizontal: number, up: number, down: number }

-- One player's buckets (blocks they may still move each way).
export type Bucket = {
	horizontal: number,
	up: number,
	down: number,
	-- Server time (seconds) the buckets were last refilled.
	last: number,
	mode: string,
	-- The mode before the last change, whose limits still count until `modeGrace`.
	previous: string?,
	modeGrace: number,
	-- Until then the buckets may hold more than their cap (a grant).
	grantGrace: number,
}

-- (A mode Config doesn't list moves at the slowest's limits.)
local FALLBACK: Limits = { horizontal = 12, up = 12, down = 80 }

-- The limits (blocks a second) of game mode `mode`.
function MoveCheck.limits(mode: string): Limits
	local limits = (Config.Players.MoveLimits :: { [string]: Limits })[mode]
	return limits or FALLBACK
end

-- The limits that apply to `bucket` at `now`: its mode's, or the larger of the old and the new
-- mode's during the grace after a change.
local function current(bucket: Bucket, now: number): (number, number, number)
	local limits = MoveCheck.limits(bucket.mode)
	local h, u, d = limits.horizontal, limits.up, limits.down
	local previous = bucket.previous
	if previous and now < bucket.modeGrace then
		local old = MoveCheck.limits(previous)
		h, u, d = math.max(h, old.horizontal), math.max(u, old.up), math.max(d, old.down)
	end
	return h, u, d
end

-- New, full buckets for a player in `mode` at server time `now`.
function MoveCheck.new(mode: string, now: number): Bucket
	local limits = MoveCheck.limits(mode)
	local slack = Config.Players.MoveSlack
	return {
		horizontal = limits.horizontal * slack,
		up = limits.up * slack,
		down = limits.down * slack,
		last = now,
		mode = mode,
		previous = nil,
		modeGrace = -math.huge,
		grantGrace = -math.huge,
	}
end

-- Fills the buckets (a teleport: the server put the player where they are).
function MoveCheck.reset(bucket: Bucket, now: number)
	local h, u, d = current(bucket, now)
	local slack = Config.Players.MoveSlack
	bucket.horizontal, bucket.up, bucket.down = h * slack, u * slack, d * slack
	bucket.last = now
	bucket.grantGrace = -math.huge
end

-- A bucket holding `value` after `elapsed` seconds at `rate` a second: up to `rate` x MoveSlack,
-- or kept above that while `granted`.
local function fill(value: number, rate: number, elapsed: number, granted: boolean): number
	local cap = rate * Config.Players.MoveSlack
	if value >= cap then
		return if granted then value else cap
	end
	return math.min(cap, value + rate * elapsed)
end

-- Refills the buckets for the time since the last refill.
local function refill(bucket: Bucket, now: number)
	local elapsed = math.max(0, now - bucket.last)
	bucket.last = math.max(bucket.last, now)
	local h, u, d = current(bucket, now)
	local granted = now < bucket.grantGrace
	bucket.horizontal = fill(bucket.horizontal, h, elapsed, granted)
	bucket.up = fill(bucket.up, u, elapsed, granted)
	bucket.down = fill(bucket.down, d, elapsed, granted)
end

-- The player's game mode changed to `mode` at `now` (the larger limits for GRACE seconds).
function MoveCheck.setMode(bucket: Bucket, mode: string, now: number)
	if mode == bucket.mode then
		return
	end
	refill(bucket, now)
	bucket.previous = bucket.mode
	bucket.mode = mode
	bucket.modeGrace = now + MoveCheck.GRACE
end

-- Knockback the server gave: `blocks` more each way, over the cap for GRACE seconds.
function MoveCheck.grant(bucket: Bucket, blocks: number, now: number)
	if not (blocks > 0) or blocks == math.huge then
		return
	end
	refill(bucket, now)
	bucket.horizontal += blocks
	bucket.up += blocks
	bucket.down += blocks
	bucket.grantGrace = now + MoveCheck.GRACE
end

--[[
	May the player move by (dx, dy, dz) blocks at server time `now`? Yes takes the move out of the
	buckets; no leaves them as they were (refilled).
]]
function MoveCheck.check(bucket: Bucket, dx: number, dy: number, dz: number, now: number): boolean
	if not (dx == dx and dy == dy and dz == dz) then
		return false
	end
	refill(bucket, now)
	local horizontal = math.sqrt(dx * dx + dz * dz)
	local up = math.max(0, dy)
	local down = math.max(0, -dy)
	if horizontal > bucket.horizontal or up > bucket.up or down > bucket.down then
		return false
	end
	bucket.horizontal -= horizontal
	bucket.up -= up
	bucket.down -= down
	return true
end

-- A feet position any player may have: finite, within the world's coordinates and heights.
function MoveCheck.inBounds(x: number, y: number, z: number): boolean
	return x == x
		and y == y
		and z == z
		and math.abs(x) <= Protocol.MAX_COORDINATE
		and math.abs(z) <= Protocol.MAX_COORDINATE
		and y >= PlayerSync.MIN_Y
		and y <= PlayerSync.MAX_Y
end

return MoveCheck

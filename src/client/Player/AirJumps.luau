--!strict
--[[
	Other players' air jumps (Terraria's Cloud in a Bottle: Movement/PlayerPhysics' `airJumped`),
	told from what this client sees of them, pure (no Roblox APIs: tests/spec/Accessories runs it),
	for Player/EquipmentLooks' puff of cloud and entity.player.double_jump. Nothing is sent for it:
	the poses relayed already say enough (Net/PlayerSync's flags, the feet's height drawn each
	frame by Player/RemotePlayers).

	An air jump is the vertical speed jumping up in mid-air: in one frame it rises by more than
	RISE blocks a second to more than UP, after the player has been off the ground, out of fluids,
	off ladders and not flying for at least AIRBORNE seconds (a jump from the ground rises the same
	way, but OnGround was just set). The heights are lerped between poses 20 times a second, so the
	speed is a step function: a jump's rise shows in one frame (0.36 blocks a tick is 7.2 a second,
	from about 0 at the top of a jump or below 0 falling). That rise counts when the pose says
	Jumped (within 0.31 s of a jump) at most WINDOW seconds later, the speed still above UP:
	Player/RemoteMotion takes the flags of the nearer of the two poses, so the jump's own flag
	shows half a pose after its rise starts (the ground jump's may still be on, then at once). One
	at most every COOLDOWN seconds. Knockback lifting a player who jumped a moment ago can look the
	same; it is rare and only a puff.

	  new()                           a player's watch
	  step(watch, flags, y, now)      one frame (flags: PlayerSync.Flag bits; y: feet, blocks;
	                                  now: seconds): true when this frame shows an air jump
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local PlayerSync = require(Shared.Net.PlayerSync)

local Flag = PlayerSync.Flag
-- Pose flags that mean the player can't be air jumping (refill the jump or need none).
local GROUNDED = bit32.bor(Flag.OnGround, Flag.InWater, Flag.Climbing, Flag.Flying)

local AirJumps = {}

-- Seconds off the ground first, the rise (blocks a second, in one frame) and the speed upwards
-- that make an air jump, the seconds its Jumped flag may come after the rise, and the seconds
-- before another counts.
AirJumps.AIRBORNE = 0.15
AirJumps.RISE = 3
AirJumps.UP = 3
AirJumps.WINDOW = 0.1
AirJumps.COOLDOWN = 0.25

export type Watch = {
	-- The last frame's height and time (nil: none yet), vertical speed (blocks a second), when
	-- the player was last grounded, the last rise seen in the air, and the last air jump.
	y: number?,
	at: number,
	vy: number,
	groundedAt: number,
	risenAt: number,
	jumpedAt: number,
}

function AirJumps.new(): Watch
	return { y = nil, at = 0, vy = 0, groundedAt = -math.huge, risenAt = -math.huge, jumpedAt = -math.huge }
end

-- One frame of a player (see the header): does it show an air jump?
function AirJumps.step(watch: Watch, flags: number, y: number, now: number): boolean
	local lastY, lastAt, lastVy = watch.y, watch.at, watch.vy
	watch.y, watch.at = y, now
	if lastY == nil or not (now > lastAt) or y ~= y then
		watch.vy = 0
		return false
	end
	local vy = (y - lastY) / (now - lastAt)
	watch.vy = vy
	if bit32.btest(flags, GROUNDED) then
		watch.groundedAt = now
		watch.risenAt = -math.huge
		return false
	end
	if vy > AirJumps.UP and vy - lastVy > AirJumps.RISE and now - watch.groundedAt >= AirJumps.AIRBORNE then
		watch.risenAt = now
	end
	if
		bit32.btest(flags, Flag.Jumped)
		and vy > AirJumps.UP
		and now - watch.risenAt <= AirJumps.WINDOW
		and now - watch.jumpedAt >= AirJumps.COOLDOWN
	then
		watch.jumpedAt = now
		watch.risenAt = -math.huge
		return true
	end
	return false
end

return AirJumps

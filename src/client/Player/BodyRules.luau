--!strict
--[[
	How a body turns as it moves, in the manner of DayZ (pure: Player/BodyTwist and
	Player/CharacterAnimator draw every character by it, tests/spec/BodyRules checks it). Angles in
	radians in Roblox's senses (a yaw turns as CFrame.Angles(0, yaw, 0): positive is left, the body
	looks down -Z at yaw 0), speeds in blocks a second. Scalars in and out: nothing allocates.

	  Legs     the way the feet move, from the body's facing (`moveAngle`: 0 ahead, +pi/2 to the
	           left, pi behind). Moving (MOVING, Config.Camera.IdleTurnSpeed, or faster) the legs
	           turn towards it at the hips, folded into the front half and at most LEG_YAW, so a
	           pure strafe is 45 degrees and a straight backpedal none (`legYaw`); the back half
	           walks backwards (`walkSign`: the walk and run animations played reversed). `legs`
	           is `legYaw` with BACK_BAND of hysteresis each side of the strafe, so a strafe
	           wavering about 90 degrees doesn't flip the legs and the walk every frame; `fold`
	           the twist for a way of walking already known (another player's replicated walk).
	  Shuffle  turning on the spot faster than SHUFFLE_RATE on the ground plays the walk at
	           SHUFFLE_SHARE of the turn rate, at most SHUFFLE_MAX (`shuffle`): the feet step
	           round, as DayZ's turn steps.
	  Waist    the upper body's yaw on the pelvis (`waist`): the local idle lead (the aim ahead of
	           the lagging body, at most LEAD) plus freelook's yaw beyond the neck's NECK_YAW (at
	           most WAIST_YAW: `neck` is the head's share), less the pelvis' share of the legs'
	           twist (PELVIS, none: the hips turn the legs alone, the pelvis stays with the root).
	`ease` brings a drawn angle to its target exponentially (frame-rate independent).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

local BodyRules = {}

local TAU = 2 * math.pi
local HALF = math.pi / 2

-- The legs' twist at most (a pure strafe).
BodyRules.LEG_YAW = math.rad(45)
-- Slower than this (blocks a second) the body stands: no twist, no backpedal (an idle turn may
-- shuffle).
BodyRules.MOVING = Config.Camera.IdleTurnSpeed
-- The hysteresis each side of a pure strafe before the walk turns round (`legs`).
BodyRules.BACK_BAND = math.rad(20)
-- An idle turn faster than this (radians a second) shuffles, the walk played at this share of the
-- rate, at most this fast.
BodyRules.SHUFFLE_RATE = 1.2
BodyRules.SHUFFLE_SHARE = 0.25
BodyRules.SHUFFLE_MAX = 0.6
-- The upper body's lead on an idle turn at most; the neck's share of freelook's yaw, then the
-- waist's (DayZ's first-person freelook: 100 degrees in all).
BodyRules.LEAD = math.rad(45)
BodyRules.NECK_YAW = math.rad(70)
BodyRules.WAIST_YAW = math.rad(30)
-- The share of the legs' twist the pelvis takes (turned back at the waist): none, the hips turn
-- the legs alone (the pelvis hangs on the root, LowerTorso.Root, Player/MovementController's).
BodyRules.PELVIS = 0

-- `angle` into (-pi, pi].
local function wrap(angle: number): number
	angle = angle % TAU
	if angle > math.pi then
		angle -= TAU
	end
	return angle
end
BodyRules.wrap = wrap

--[[
	The way a body facing `yaw` moves when its feet go (dx, dz) (world blocks; any length): 0
	ahead, positive to its left, pi behind; 0 when they don't move.
]]
function BodyRules.moveAngle(dx: number, dz: number, yaw: number): number
	if dx * dx + dz * dz < 1e-18 then
		return 0
	end
	return wrap(math.atan2(-dx, -dz) - yaw)
end

-- Does a move at `angle` (`moveAngle`) walk backwards: -1 in the back half, else 1.
function BodyRules.walkSign(angle: number): number
	return if math.abs(wrap(angle)) > HALF then -1 else 1
end

--[[
	The legs' twist (radians, positive left) for a move at `angle` (`moveAngle`) walked forwards, or
	(`backwards`) backwards: the legs face the move, or away from it, within LEG_YAW.
]]
function BodyRules.fold(angle: number, backwards: boolean): number
	local facing = if backwards then wrap(angle - math.pi) else wrap(angle)
	return math.clamp(facing, -BodyRules.LEG_YAW, BodyRules.LEG_YAW)
end

--[[
	The legs' twist at the hips (radians, positive left) for a move at `angle` (`moveAngle`) at
	`speed` (blocks a second), and whether it walks backwards: 0, false under MOVING.
]]
function BodyRules.legYaw(angle: number, speed: number): (number, boolean)
	if speed < BodyRules.MOVING then
		return 0, false
	end
	local backwards = BodyRules.walkSign(angle) < 0
	return BodyRules.fold(angle, backwards), backwards
end

--[[
	`legYaw` with hysteresis: a body that walked backwards (`wasBackwards`) keeps doing so until the
	move comes BACK_BAND in front of a pure strafe, and one walking forwards until it goes as far
	behind.
]]
function BodyRules.legs(angle: number, speed: number, wasBackwards: boolean): (number, boolean)
	if speed < BodyRules.MOVING then
		return 0, false
	end
	local off = math.abs(wrap(angle))
	local backwards = if wasBackwards then off > HALF - BodyRules.BACK_BAND else off > HALF + BodyRules.BACK_BAND
	return BodyRules.fold(angle, backwards), backwards
end

--[[
	The walk's playback speed for a body turning on the spot at `turnRate` (radians a second, either
	way), moving at `speed` (blocks a second): SHUFFLE_SHARE x the rate, at most SHUFFLE_MAX, when it
	is on the ground, standing (under MOVING) and turning faster than SHUFFLE_RATE; else 0.
]]
function BodyRules.shuffle(turnRate: number, speed: number, onGround: boolean): number
	local rate = math.abs(turnRate)
	if not onGround or speed >= BodyRules.MOVING or rate <= BodyRules.SHUFFLE_RATE then
		return 0
	end
	return math.min(BodyRules.SHUFFLE_SHARE * rate, BodyRules.SHUFFLE_MAX)
end

-- The head's share of freelook's yaw (radians; the camera's turn from the aim): at most NECK_YAW.
function BodyRules.neck(freelookYaw: number): number
	return math.clamp(freelookYaw, -BodyRules.NECK_YAW, BodyRules.NECK_YAW)
end

--[[
	The upper body's yaw at the waist (radians, positive left): the idle `lead` (the aim's yaw less
	the body's) within LEAD, plus freelook's yaw (`freelookYaw`) beyond the neck's share, within
	WAIST_YAW, less PELVIS x the legs' twist (`legYaw`).
]]
function BodyRules.waist(lead: number, legYaw: number, freelookYaw: number): number
	local beyond = freelookYaw - BodyRules.neck(freelookYaw)
	return math.clamp(wrap(lead), -BodyRules.LEAD, BodyRules.LEAD)
		+ math.clamp(beyond, -BodyRules.WAIST_YAW, BodyRules.WAIST_YAW)
		- BodyRules.PELVIS * legYaw
end

--[[
	`current` brought towards `target` over `dt` seconds with a time constant of `seconds`
	(exponentially: frame-rate independent); `target` at once when `seconds` is not positive.
]]
function BodyRules.ease(current: number, target: number, seconds: number, dt: number): number
	if seconds <= 0 then
		return target
	end
	return target + (current - target) * math.exp(-math.max(dt, 0) / seconds)
end

return BodyRules

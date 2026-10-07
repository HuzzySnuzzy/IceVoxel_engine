--!strict
--[[
	The camera's walking bob and hurt tilt, Minecraft 1.20.1's GameRenderer.bobView and bobHurt
	(pure; Player/MovementController moves the camera by them, tests/spec/Keybinds checks them).

	  Bob    the walk distance grows by 0.6 x the blocks walked (Entity.move's walkDist) and the bob
	         amount eases 0.4 a tick towards the horizontal speed in blocks a tick, at most 0.1,
	         while on the ground and not swimming (Player.aiStep's bob; 0 in the air, flying or
	         swimming): `advance` does both for a frame. `bobView` gives what Minecraft does to the
	         view for them: shifted sin(g pi) x bob x 0.5 blocks sideways and |cos(g pi) x bob|
	         blocks down, rolled sin(g pi) x bob x 3 degrees and pitched |cos(g pi - 0.2) x bob| x 5
	         degrees, g = -walk. Walking (0.216 blocks a tick, bob 0.1): 0.05 blocks sideways,
	         0.1 down, 0.3 degrees of roll and 0.5 of pitch, one sway every 3.3 blocks. The
	         camera moves by the inverse (the view is the world seen from it).
	  Hurt   for 10 ticks after a hit (LivingEntity.hurtDuration) the view rolls by
	         -sin(t^4 pi) x 14 degrees, t = ticks left / 10 (at most 14 degrees about 0.08 s after
	         the hit), times the Damage Tilt setting (`hurtRoll`). Minecraft 1.20's hurt
	         direction is left out: this game's damage carries none to the client.
]]

local ViewBob = {}

ViewBob.TICKS_PER_SECOND = 20
-- Entity.move: walkDist grows by 0.6 per block walked.
ViewBob.WALK_SCALE = 0.6
-- Player.aiStep: the bob amount eases 0.4 a tick towards the speed, at most 0.1.
ViewBob.MAX_BOB = 0.1
ViewBob.BOB_EASE = 0.4
-- LivingEntity.hurtDuration (ticks) and GameRenderer.bobHurt's 14 degrees.
ViewBob.HURT_TICKS = 10
ViewBob.HURT_DEGREES = 14

--[[
	One frame of `dt` seconds: the walk distance and the bob amount after moving at `speed` blocks
	a second horizontally, `bobbing` (on the ground, not swimming or flying) or not.
]]
function ViewBob.advance(walk: number, bob: number, speed: number, bobbing: boolean, dt: number): (number, number)
	walk += speed * dt * ViewBob.WALK_SCALE
	local target = if bobbing then math.min(ViewBob.MAX_BOB, speed / ViewBob.TICKS_PER_SECOND) else 0
	local share = 1 - (1 - ViewBob.BOB_EASE) ^ (dt * ViewBob.TICKS_PER_SECOND)
	bob += (target - bob) * share
	if bob < 1e-5 and target == 0 then
		bob = 0
	end
	return walk, bob
end

--[[
	GameRenderer.bobView: how the view is moved (blocks: right, up) and turned (degrees: roll
	about the view axis, pitch about its right axis) for walk distance `walk` and bob `bob`.
]]
function ViewBob.bobView(walk: number, bob: number): (number, number, number, number)
	local g = -walk * math.pi
	local s, c = math.sin(g), math.cos(g)
	return s * bob * 0.5, -math.abs(c * bob), s * bob * 3, math.abs(math.cos(g - 0.2) * bob) * 5
end

-- GameRenderer.bobHurt: the roll (degrees) `age` ticks after a hit, scaled by `strength` (0..1).
function ViewBob.hurtRoll(age: number, strength: number): number
	if age < 0 or age >= ViewBob.HURT_TICKS or strength <= 0 then
		return 0
	end
	local t = (ViewBob.HURT_TICKS - age) / ViewBob.HURT_TICKS
	return -math.sin(t ^ 4 * math.pi) * ViewBob.HURT_DEGREES * strength
end

return ViewBob

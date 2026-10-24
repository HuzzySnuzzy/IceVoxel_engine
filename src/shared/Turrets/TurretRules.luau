--!strict
--[[
	A turret's maths, pure, the one rule both sides keep (the server aims and fires with it,
	server Turrets/TurretWorld; the client draws the gun turning with it, Rendering/TurretView):

	  Pivot      the gun turns about (x + 0.5, y + PIVOT, z + 0.5) of its block: 0.82 over the
	             base's top, on the post the client draws up from its turntable, so the gun held
	             level stays in the cell above (under its top) and at its type's lowest pitch no
	             part of it, nor the muzzle, goes into its own block (Rendering/TurretModel; the
	             specs sweep it)
	  Angles     radians. Yaw 0 faces +Z and grows towards +X: facing (sin yaw, cos yaw), as mobs'
	             bodies (Entities/MobPhysics); pitch up from the horizontal. `direction` is the
	             unit vector, `aim` the angles and distance from the pivot to a point, `muzzle`
	             the barrel's end
	  Turning    `turn` moves each axis at most `step` towards the angles wanted, the short way
	             round (across +-pi) and never past them; `offAngle` is how far the aim is from
	             them (the firing gate's settle). The pitch stays within the Spec's `pitchMin`
	             .. Config.Turrets.PitchMax (`pitchLimits`, `inPitch`): below its type's lowest
	             (the lowest its gun clears its own block at, every tier, mount and yaw, never
	             under PitchMin: SMG and rifle -60 degrees, sniper -51) is a dead zone
	  Cadence    an exact whole credit: every powered tick `credit` + rpm; with CREDIT (1200: the
	             ticks of a minute) or more and leave to fire it fires and loses CREDIT, else it is
	             held at CREDIT at most. So a rate of r rounds a minute fires exactly r x 10 shots in
	             12 000 ticks (a float credit, rate / 20 a tick, fires every 11 ticks at 2 a second;
	             capping before taking the shot's away fires every 14 ticks at 90 a minute)
	  Spread     the cone (degrees) times a Laser Sight's factor and a working muzzle device's
	             (Weapons/Handling.muzzleWorks: a Ruined one does nothing)
	  Range      the turret's times a scope's, at most Config.Turrets.MaxRange
	  Noise      the stand-in gun's (Weapons/Handling.noise: its muzzle device, at least
	             SuppressedMinNoise suppressed) times Config.Turrets.NoiseScale
	  Score      a candidate's rank: its distance plus 0.05 a degree the gun must turn to it,
	             lowest first (a zombie two blocks nearer but behind the gun loses)
	  Feed rate  the panel's "In: x/s": rounds arriving, an average over FeedRateTicks ticks

	Signatures are frozen (both sides and the specs call them). Config.Turrets is read on each
	call, so the tests may tune it.
]]

local Config = require(script.Parent.Parent.Config)
local Weapons = require(script.Parent.Parent.Weapons)
local Handling = require(script.Parent.Parent.Weapons.Handling)
local Turrets = require(script.Parent)

type Spec = Turrets.Spec

local TurretRules = {}

-- The pivot's height over the block's bottom (blocks; see the header).
TurretRules.PIVOT = 1.82
-- The cadence's credit a shot costs: the ticks of a minute (rates are rounds a minute).
TurretRules.CREDIT = 1200
-- Ticks a second.
TurretRules.TICK_RATE = 20
-- A degree's weight in `score` (blocks).
TurretRules.SCORE_PER_DEGREE = 0.05

local TAU = 2 * math.pi

-- `angle` (radians) brought into (-pi, pi].
local function wrap(angle: number): number
	local a = angle % TAU
	if a > math.pi then
		a -= TAU
	end
	return a
end
TurretRules.wrap = wrap

--[[ Geometry ]]

-- The pivot of the turret in block (x, y, z).
function TurretRules.pivot(x: number, y: number, z: number): (number, number, number)
	return x + 0.5, y + TurretRules.PIVOT, z + 0.5
end

-- The unit vector the gun points along at `yaw`, `pitch`.
function TurretRules.direction(yaw: number, pitch: number): (number, number, number)
	local c = math.cos(pitch)
	return math.sin(yaw) * c, math.sin(pitch), math.cos(yaw) * c
end

--[[
	The yaw and pitch from (px, py, pz) towards (tx, ty, tz), and the distance. A point straight
	above or below gives yaw 0; the same point gives (0, 0, 0).
]]
function TurretRules.aim(
	px: number,
	py: number,
	pz: number,
	tx: number,
	ty: number,
	tz: number
): (number, number, number)
	local dx, dy, dz = tx - px, ty - py, tz - pz
	local flat = math.sqrt(dx * dx + dz * dz)
	local distance = math.sqrt(flat * flat + dy * dy)
	if distance == 0 then
		return 0, 0, 0
	end
	local yaw = if flat > 0 then math.atan2(dx, dz) else 0
	return yaw, math.atan2(dy, flat), distance
end

--[[
	The aim one tick (or frame) later: each axis moved at most `step` radians towards `wantYaw`,
	`wantPitch`, the yaw the short way round, neither past what is wanted (reaching it exactly).
	The yaw comes back in (-pi, pi].
]]
function TurretRules.turn(
	yaw: number,
	pitch: number,
	wantYaw: number,
	wantPitch: number,
	step: number
): (number, number)
	local reach = math.max(step, 0)
	local dyaw = wrap(wantYaw - yaw)
	local newYaw = if math.abs(dyaw) <= reach then wantYaw else yaw + math.sign(dyaw) * reach
	local dpitch = wantPitch - pitch
	local newPitch = if math.abs(dpitch) <= reach then wantPitch else pitch + math.sign(dpitch) * reach
	return wrap(newYaw), newPitch
end

-- The angle (radians, 0..pi) between the aim at `yaw`, `pitch` and the one at `wantYaw`, `wantPitch`.
function TurretRules.offAngle(yaw: number, pitch: number, wantYaw: number, wantPitch: number): number
	local ax, ay, az = TurretRules.direction(yaw, pitch)
	local bx, by, bz = TurretRules.direction(wantYaw, wantPitch)
	return math.acos(math.clamp(ax * bx + ay * by + az * bz, -1, 1))
end

-- The muzzle of the turret in block (x, y, z) aimed at `yaw`, `pitch`: `barrel` blocks out from
-- its pivot.
function TurretRules.muzzle(
	x: number,
	y: number,
	z: number,
	yaw: number,
	pitch: number,
	barrel: number
): (number, number, number)
	local px, py, pz = TurretRules.pivot(x, y, z)
	local dx, dy, dz = TurretRules.direction(yaw, pitch)
	return px + dx * barrel, py + dy * barrel, pz + dz * barrel
end

-- The pitch limits (radians) of `spec`: its `pitchMin` .. Config.Turrets.PitchMax (without a
-- spec PitchMin, the lowest any type aims at).
function TurretRules.pitchLimits(spec: Spec?): (number, number)
	local settings = Config.Turrets
	return math.rad(if spec then spec.pitchMin else settings.PitchMin), math.rad(settings.PitchMax)
end

-- Is `pitch` (radians) within `spec`'s pitch limits (`pitchLimits`; without a spec, any type's)?
function TurretRules.inPitch(pitch: number, spec: Spec?): boolean
	local low, high = TurretRules.pitchLimits(spec)
	return pitch >= low - 1e-9 and pitch <= high + 1e-9
end

--[[ Firing ]]

--[[
	One powered tick of the cadence (see the header): the credit after it and whether a shot goes,
	with leave to fire (`canFire`). An unpowered tick adds nothing: pass a rate of 0.
]]
function TurretRules.cadence(credit: number, rpm: number, canFire: boolean): (number, boolean)
	local after = credit + rpm
	if after >= TurretRules.CREDIT and canFire then
		return after - TurretRules.CREDIT, true
	end
	return math.min(after, TurretRules.CREDIT), false
end

--[[
	The cone's half angle (degrees) of `spec`'s shots with the optic `optic` and the muzzle device
	`muzzle` (item ids, 0 or nil: none) with `muzzleFraction` of its durability left.
]]
function TurretRules.spread(spec: Spec, optic: number?, muzzle: number?, muzzleFraction: number?): number
	local cone = spec.spread * Turrets.optic(spec, optic).spread
	if muzzle and spec.muzzles[muzzle] and Handling.muzzleWorks(muzzle, muzzleFraction) then
		cone *= (Weapons.attachment(muzzle) :: Weapons.AttachmentSpec).spread
	end
	return cone
end

-- `spec`'s range (blocks) with the optic `optic` (0 or nil: none), at most Config.Turrets.MaxRange.
function TurretRules.range(spec: Spec, optic: number?): number
	return math.min(spec.range * Turrets.optic(spec, optic).range, Config.Turrets.MaxRange)
end

--[[
	The blocks a shot of `spec` is heard from with the muzzle device `muzzle` (0 or nil: none) and
	`muzzleFraction` of its durability left: its stand-in gun's noise times NoiseScale.
]]
function TurretRules.shotNoise(spec: Spec, muzzle: number?, muzzleFraction: number?): number
	local gun = Weapons.firearm(spec.firearm) :: Weapons.FirearmSpec
	local device = if muzzle and spec.muzzles[muzzle] then muzzle else nil
	return Handling.noise(gun, device, muzzleFraction) * Config.Turrets.NoiseScale
end

--[[ Targets ]]

-- A candidate's rank (see the header): `distance` (blocks) and how far the gun must turn
-- (`offAngle`, radians); lowest first.
function TurretRules.score(distance: number, offAngle: number): number
	return distance + TurretRules.SCORE_PER_DEGREE * math.deg(offAngle)
end

--[[
	The panel's feed rate (rounds a second) after a tick in which `arrivals` rounds came: an
	exponential average over Config.Turrets.FeedRateTicks ticks.
]]
function TurretRules.feedRate(rate: number, arrivals: number): number
	local ticks = math.max(Config.Turrets.FeedRateTicks, 1)
	local was = if rate == rate then rate else 0
	local came = if arrivals == arrivals then math.max(arrivals, 0) else 0
	return was + (came * TurretRules.TICK_RATE - was) / ticks
end

return table.freeze(TurretRules)

--!strict
--[[
	Handling a firearm, pure (both sides use the same numbers: server Weapons/ checks a shot with
	them, client Interaction/Firearms paces, kicks and sways with them; Config.Weapons tunes them):

	  Cadence    a mode's shot time (`shotTicks`: 1200 / its rpm, ticks of 1/20 s); `ready` allows
	             a shot when the last was at least one shot time ago, with one tick of slack (at
	             most half a shot) for the two clocks; `after` is when an accepted shot counts from:
	             when it was due if it came early within the slack or late by up to 2 ticks (a late
	             one doesn't push the next out), else (the first, or after a pause) its arrival. So
	             a run of shots never comes faster than the rate but for the slack (as
	             Shared/Magic/Casting's casts).
	  Spread     the cone's half angle (degrees) a shot leaves in: the gun's, times ShoulderSpread
	             out of the sights (raised in third person), MovingSpread while moving,
	             CrouchSpread crouching, and a working muzzle device's `spread` (a suppressor 0.9).
	  Recoil     the camera's kick (degrees), deterministic from a seed and the shot counter: the
	             gun's recoil times CrouchRecoil crouching and ShoulderRecoil out of the sights;
	             pitch k x (0.9 + 0.2 r1), yaw k x recoilYaw x (2 r2 - 1). RecoilRecover of the
	             pitch comes back, exponentially over RecoilRecoverSeconds (`recoverStep`), so
	             automatic fire climbs.
	  Sway       a slow figure eight (degrees): amplitude A = the gun's sway times MovingSway,
	             CrouchSway, HurtSway (under half health), ShoulderSway out of the sights and the
	             breath's factor; yaw A sin(2 pi 0.31 t), pitch 0.6 A sin(2 pi 0.47 t + 1.1).
	  Breath     holding it (the sprint key in the sights) for HoldBreathSeconds steadies the aim
	             (HoldBreathSway), then the player is out of breath for OutOfBreathSeconds
	             (OutOfBreathSway, no holding); letting go early goes back to normal at once.
	  Condition  Weapons.level: 1 Pristine .. 5 Ruined (never fires).
	  Jams       a shot's jam chance: JamChance by the gun's condition level plus the attached
	             magazine's, at most 1; 0 for guns that never jam.
	  Noise      the blocks the infected hear a shot from: the gun's noise times a working muzzle
	             device's (a Ruined one muffles nothing), at least SuppressedMinNoise when
	             suppressed.
	  Reload     a magazine swap's ticks, plus chambering when it chambers.
	  Zoom       field of view divided by this in the sights: a built-in scope's, else the
	             optic's, else IronSightsZoom.

	Muzzle devices, optics and lights are given as item ids (nil: none) with their durability left
	(0..1, Weapons/WeaponState.fraction).
]]

local Config = require(script.Parent.Parent.Config)
local Hash = require(script.Parent.Parent.Util.Hash)
local Weapons = require(script.Parent)

-- How the shooter stands for spread and recoil (each optional: false): in the sights, moving,
-- crouching. A decoded Fire message (Net/WeaponSync.Fire) is one.
export type Stance = { sights: boolean?, moving: boolean?, crouching: boolean? }

-- How the shooter stands for sway: the same, and `hurt` (under half health).
export type SwayStance = { sights: boolean?, moving: boolean?, crouching: boolean?, hurt: boolean? }

-- Holding breath: "normal", "holding" (steady) or "out" (out of breath), and seconds in it.
export type Breath = { phase: "normal" | "holding" | "out", time: number }

local Handling = {}

Handling.TICK = 1 / 20
-- Ticks of slack a shot may come early (at most half a shot), and of credit a late one keeps.
Handling.SLACK_TICKS = 1
Handling.CREDIT_TICKS = 2

local function settings(): typeof(Config.Weapons)
	return Config.Weapons
end

--[[ Cadence ]]

-- The fire mode `mode` (an index into the gun's modes, or "semi" / "auto") of `spec`; the first
-- when it has none such.
local function modeOf(spec: Weapons.FirearmSpec, mode: number | string): Weapons.FireMode
	if type(mode) == "number" then
		return spec.modes[mode] or spec.modes[1]
	end
	for _, entry in spec.modes do
		if entry.kind == mode then
			return entry
		end
	end
	return spec.modes[1]
end

-- Ticks between shots in fire mode `mode` (an index or "semi" / "auto"): 1200 / rpm.
function Handling.shotTicks(spec: Weapons.FirearmSpec, mode: number | string): number
	return 1200 / modeOf(spec, mode).rpm
end

-- Slack (ticks) a shot of `ticks` may come early: one tick, at most half a shot.
function Handling.slack(ticks: number): number
	return math.min(Handling.SLACK_TICKS, 0.5 * ticks)
end

-- May a shot of `ticks` go at `now` (seconds) after the last at `last` (nil: never)?
function Handling.ready(last: number?, now: number, ticks: number): boolean
	return last == nil or now - last >= (ticks - Handling.slack(ticks)) * Handling.TICK - 1e-9
end

-- The time a shot accepted at `now` counts from (see the header).
function Handling.after(last: number?, now: number, ticks: number): number
	if last == nil then
		return now
	end
	local due = last + ticks * Handling.TICK
	if now <= due + Handling.CREDIT_TICKS * Handling.TICK then
		return due
	end
	return now
end

--[[ Muzzle devices and optics ]]

-- Does the muzzle device `muzzle` (nil: none), `fraction` of its durability left, still work (not
-- Ruined)?
function Handling.muzzleWorks(muzzle: number?, fraction: number?): boolean
	local spec = Weapons.attachment(muzzle)
	return spec ~= nil and spec.slot == "muzzle" and Weapons.level(fraction or 1) < Weapons.RUINED
end

-- Is a shot through `muzzle` suppressed (the suppressed sound, no flash)?
function Handling.suppressed(muzzle: number?, fraction: number?): boolean
	local spec = Weapons.attachment(muzzle)
	return spec ~= nil and spec.suppressed and Handling.muzzleWorks(muzzle, fraction)
end

--[[ Spread ]]

-- The shot's cone half angle in degrees (see the header).
function Handling.spread(spec: Weapons.FirearmSpec, stance: Stance, muzzle: number?, muzzleFraction: number?): number
	local s = settings()
	local cone = spec.spread
	if not stance.sights then
		cone *= s.ShoulderSpread
	end
	if stance.moving then
		cone *= s.MovingSpread
	end
	if stance.crouching then
		cone *= s.CrouchSpread
	end
	if Handling.muzzleWorks(muzzle, muzzleFraction) then
		cone *= (Weapons.attachment(muzzle) :: Weapons.AttachmentSpec).spread
	end
	return cone
end

--[[ Recoil ]]

-- The kick of shot `counter` (degrees: pitch up, yaw right), from `seed` (see the header).
function Handling.recoil(spec: Weapons.FirearmSpec, stance: Stance, seed: number, counter: number): (number, number)
	local s = settings()
	local k = spec.recoil
	if stance.crouching then
		k *= s.CrouchRecoil
	end
	if not stance.sights then
		k *= s.ShoulderRecoil
	end
	local rng = Hash.rng(Hash.hash2(seed, counter, 0))
	local r1, r2 = rng:float(), rng:float()
	return k * (0.9 + 0.2 * r1), k * spec.recoilYaw * (2 * r2 - 1)
end

-- The share of a kick's pitch that comes back (RecoilRecover).
function Handling.recoverable(pitch: number): number
	return pitch * settings().RecoilRecover
end

--[[
	The share of what is still to come back that comes back in `dt` seconds: exponential, 95% of it
	within RecoilRecoverSeconds.
]]
function Handling.recoverStep(dt: number): number
	local seconds = settings().RecoilRecoverSeconds
	if not (seconds > 0) then
		return 1
	end
	return 1 - math.exp(-3 * math.max(dt, 0) / seconds)
end

--[[ Sway and breath ]]

-- The sway's amplitude (degrees) for `stance` with the breath's `factor` (see the header).
function Handling.swayAmplitude(spec: Weapons.FirearmSpec, stance: SwayStance, factor: number?): number
	local s = settings()
	local a = spec.sway * (factor or 1)
	if stance.moving then
		a *= s.MovingSway
	end
	if stance.crouching then
		a *= s.CrouchSway
	end
	if stance.hurt then
		a *= s.HurtSway
	end
	if not stance.sights then
		a *= s.ShoulderSway
	end
	return a
end

-- The sway at `t` seconds (degrees: yaw, pitch) for `stance` and the breath's `factor`.
function Handling.sway(spec: Weapons.FirearmSpec, stance: SwayStance, t: number, factor: number?): (number, number)
	local a = Handling.swayAmplitude(spec, stance, factor)
	return a * math.sin(2 * math.pi * 0.31 * t), 0.6 * a * math.sin(2 * math.pi * 0.47 * t + 1.1)
end

function Handling.newBreath(): Breath
	return { phase = "normal", time = 0 }
end

-- The sway factor of the breath's phase.
function Handling.breathFactor(breath: Breath): number
	local s = settings()
	if breath.phase == "holding" then
		return s.HoldBreathSway
	elseif breath.phase == "out" then
		return s.OutOfBreathSway
	end
	return 1
end

--[[
	Steps the breath `dt` seconds with the sprint key held in the sights (`holding`) or not (see
	the header); changes it in place and returns its sway factor.
]]
function Handling.breathStep(breath: Breath, holding: boolean, dt: number): number
	local s = settings()
	breath.time += math.max(dt, 0)
	if breath.phase == "normal" then
		if holding then
			breath.phase, breath.time = "holding", 0
		end
	elseif breath.phase == "holding" then
		if not holding then
			breath.phase, breath.time = "normal", 0
		elseif breath.time >= s.HoldBreathSeconds then
			breath.phase, breath.time = "out", 0
		end
	elseif breath.time >= s.OutOfBreathSeconds then
		breath.phase, breath.time = "normal", 0
	end
	return Handling.breathFactor(breath)
end

--[[ Condition and jams ]]

-- The condition level (1 Pristine .. 5 Ruined) of `fraction` of durability left.
function Handling.level(fraction: number): number
	return Weapons.level(fraction)
end

-- Does a gun at `fraction` fire at all (not Ruined)?
function Handling.usable(fraction: number): boolean
	return Weapons.level(fraction) < Weapons.RUINED
end

-- A shot's jam chance: the gun's condition's and the attached magazine's (nil: none), at most 1.
function Handling.jamChance(spec: Weapons.FirearmSpec, weaponFraction: number, magFraction: number?): number
	if not spec.jams then
		return 0
	end
	local table_ = settings().JamChance
	local chance = table_[Weapons.level(weaponFraction)] or 1
	if magFraction ~= nil then
		chance += table_[Weapons.level(magFraction)] or 1
	end
	return math.min(1, chance)
end

--[[ Noise, reloading, zoom ]]

-- The blocks a shot is heard from (see the header).
function Handling.noise(spec: Weapons.FirearmSpec, muzzle: number?, muzzleFraction: number?): number
	local noise = spec.noise
	if Handling.muzzleWorks(muzzle, muzzleFraction) then
		local device = Weapons.attachment(muzzle) :: Weapons.AttachmentSpec
		noise *= device.noise
		if device.suppressed then
			noise = math.max(noise, settings().SuppressedMinNoise)
		end
	end
	return noise
end

-- Ticks of a magazine swap, plus chambering when `chambered` (it chambers a round).
function Handling.reloadTicks(spec: Weapons.FirearmSpec, chambered: boolean): number
	return spec.reloadTicks + (if chambered then spec.chamberTicks else 0)
end

-- The sights' zoom: a built-in scope's, else the optic's (`optic` an item; nil: none), else iron
-- sights'.
function Handling.zoom(spec: Weapons.FirearmSpec, optic: number?): number
	if spec.scope then
		return spec.scope
	end
	local part = Weapons.attachment(optic)
	if part and part.zoom then
		return part.zoom
	end
	return settings().IronSightsZoom
end

return Handling

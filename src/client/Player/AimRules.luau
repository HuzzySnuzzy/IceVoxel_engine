--!strict
--[[
	How a firearm in this player's hand is held and fired, in the manner of DayZ (pure: no Roblox
	API, numbers in and numbers out; Interaction/Firearms runs it, Player/AimCamera, Player/
	WeaponPoses, Player/HeldItems and Ui/WeaponHud draw what it says, tests/spec/WeaponClient
	checks it).

	  Posture   "lowered" (the default: it bashes, it never fires), "raised" (the raise control
	            held: third person over the shoulder) or "sights" (raised in first person, or V
	            in third person: down the sights). `step` moves it every frame from what holds it
	            up: a firearm in hand, the raise control (the use button, L2, the touch AIM
	            toggle), nothing lowering it (a screen open, dead, spectating, swimming, climbing,
	            lying down; the caller says `blocked`). Raising and lowering are what the server
	            hears (the Weapon message's raise and lower: `step`'s answer), V's toggle is reset
	            by lowering, and a raised gun fires only once it has been up RaiseTicks (+ one tick
	            of margin for the two clocks: `settled`).
	  Trigger   `pull` says what the trigger does this frame: "fire" when the gun is settled, no
	            timed action runs (`busy`), it may fire (WeaponState.canFire) and its cadence
	            allows (Handling.shotTicks, no slack on the client; a shot counts from when it was
	            due, Handling.after, so automatic fire keeps its rate over uneven frames); a
	            semi-automatic fires once a press (a press made too early waits for its turn), an
	            automatic one while held. An empty gun clicks dry, a jammed or Ruined one with the
	            jam click, once a press. `stop` ends automatic fire until the trigger is let go (the
	            server refused a shot, or said the gun jammed).
	  Busy      a timed weapon action (Inventory action "weapon", the server locks the gun as
	            long): `lockTicks` is its length as the server times it (a magazine swap
	            Handling.reloadTicks, plus chambering when it chambered; a round loaded by hand
	            its roundTicks; clearing a jam UnjamTicks; the fire mode ModeTicks; the light
	            none), `startBusy` / `busy` / `progress` follow it. An internal magazine loads
	            round by round while `loading` (`wantsRound`: until it holds its rounds and the
	            chambered one).
	  Speed     `speed`: RaisedSpeed raised, SightsSpeed in the sights, no sprinting in either
	            (Player/MovementController.setAimSlow); GuardSpeed for a melee guard.
	  View      `zoom`: 1 unless in the sights, then Handling.zoom (a built-in scope's, an
	            optic's, else IronSightsZoom); `scoped` from SCOPE_ZOOM (the scope overlay
	            instead of the model); `fov` the field of view it gives; `sensitivity` the mouse's
	            share (1 / zoom); `ease` eases zoom and the shoulder in and out. The crosshair
	            hides while raised (`hidesCrosshair`), the shoulder dot shows only raised in third
	            person (`showsDot`).
	  Recoil    a kick (Handling.recoil: degrees up and right) waits in `Recoil` until the camera
	            takes it (`takeKick`, Player/MouseLook through Roblox's camera input); the share
	            that comes back (Handling.recoverable) returns over RecoilRecoverSeconds
	            (`recover`, Handling.recoverStep), so automatic fire climbs. The model in the
	            first-person view kicks back KICK_BACK studs and up KICK_UP degrees, gone after
	            KICK_SECONDS (`modelKick`).
	  Sway      Handling.sway (a slow figure eight) times `swayBlend`, which grows from 0 as the
	            gun is raised.
	  Poses     the first-person model's place in the camera's space (`hipPose`: low right, its
	            barrel towards the screen's centre AIM_DEPTH studs ahead; the sights put the sight
	            line on the view axis SIGHTS_DEPTH ahead: ItemModels.firearmPivot), and the third-
	            person arms (`armPose`: the shoulders' turns in the torso's axes, pitch forward
	            first, then yaw inward) and the gun's direction (`gunAngles`) for every character:
	            raised, both arms along the look; lowered, a long gun across the body, a handgun
	            down at the side. `longGun`: everything but pistols and revolvers. A melee weapon
	            (the melee rework: Interaction/MeleeInput) is held across the chest while guarding
	            and drawn back over the shoulder as a heavy attack winds up (`meleeArms`; the
	            first-person tool's own shift for both: `meleeView`).

	Times are os.clock() seconds, ticks 1/20 s, angles in degrees unless named radians.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Handling = require(Shared.Weapons.Handling)
local Items = require(Shared.Items)
local WeaponState = require(Shared.Weapons.WeaponState)
local Weapons = require(Shared.Weapons)

export type Posture = "lowered" | "raised" | "sights"

-- What holds the gun up this frame (see the header).
export type Input = {
	-- A firearm is in hand.
	held: boolean,
	-- Something lowers it: a screen open, dead, spectating, swimming, climbing, lying down.
	blocked: boolean,
	-- The raise control is held (or the touch AIM toggle is on).
	raise: boolean,
	-- The camera is in first person.
	firstPerson: boolean,
}

export type BusyKind = "reload" | "round" | "unjam" | "mode"

export type Aim = {
	posture: Posture,
	-- os.clock() when it was raised (nil: lowered).
	raisedAt: number?,
	-- V's sights in third person (reset when lowered).
	sights: boolean,
	-- When the last shot counts from (Handling.after; nil: none yet).
	lastShot: number?,
	-- The trigger did its thing this press (a semi-automatic shot, a click, or `stop`).
	spent: boolean,
	-- A timed weapon action: what, from when, until when (busyKind nil: none).
	busyKind: BusyKind?,
	busyFrom: number,
	busyEnds: number,
	-- An internal magazine loading round by round.
	loading: boolean,
}

-- A kick not yet given to the camera (degrees: up, right) and the pitch still to come back.
export type Recoil = { pitch: number, yaw: number, back: number }

export type Pull = "fire" | "dry" | "jam"

local AimRules = {}

AimRules.TICK = Handling.TICK
-- Ticks of margin on the server's RaiseTicks before the first shot (the raise and the shot cross
-- the network apart).
AimRules.RAISE_MARGIN_TICKS = 1
-- From this zoom on, the sights are a scope: an overlay instead of the model.
AimRules.SCOPE_ZOOM = 3
-- The first-person model's kick: studs back, degrees up, seconds to settle.
AimRules.KICK_BACK = 0.15
AimRules.KICK_UP = 4
AimRules.KICK_SECONDS = 0.12
-- Studs ahead of the camera: the sight line's rear in the sights, the point the hip pose's
-- barrel aims at, and the hip pose's grip (right, down, ahead).
AimRules.SIGHTS_DEPTH = 1.5
AimRules.AIM_DEPTH = 40
AimRules.HIP = table.freeze({ 0.62, -0.62, -1.5 })
-- Seconds the sway takes to grow in after raising.
AimRules.SWAY_IN = 0.4
-- The field of view's limits (Roblox's camera).
AimRules.MIN_FOV = 1
AimRules.MAX_FOV = 120

local function settings(): typeof(Config.Weapons)
	return Config.Weapons
end

--[[ Posture ]]

function AimRules.new(): Aim
	return {
		posture = "lowered",
		raisedAt = nil,
		sights = false,
		lastShot = nil,
		spent = false,
		busyKind = nil,
		busyFrom = 0,
		busyEnds = 0,
		loading = false,
	}
end

--[[
	Moves the posture for this frame's `input` at `now` (see the header). Returns the Weapon
	message's op to send: "raise" when it went up, "lower" when it came down, nil otherwise.
]]
function AimRules.step(aim: Aim, input: Input, now: number): ("raise" | "lower")?
	local up = input.held and not input.blocked and input.raise
	if not up then
		if aim.posture == "lowered" then
			return nil
		end
		aim.posture = "lowered"
		aim.raisedAt = nil
		aim.sights = false
		aim.spent = false
		return "lower"
	end
	local op: ("raise" | "lower")? = nil
	if aim.posture == "lowered" then
		aim.raisedAt = now
		op = "raise"
	end
	aim.posture = if input.firstPerson or aim.sights then "sights" else "raised"
	return op
end

-- V (or R3): the sights in third person, on or off. Only while raised; false when nothing changed.
function AimRules.toggleSights(aim: Aim): boolean
	if aim.posture == "lowered" then
		return false
	end
	aim.sights = not aim.sights
	return true
end

-- Has the gun been up long enough to fire (RaiseTicks and the margin)?
function AimRules.settled(aim: Aim, now: number): boolean
	local at = aim.raisedAt
	return at ~= nil and now - at >= (settings().RaiseTicks + AimRules.RAISE_MARGIN_TICKS) * AimRules.TICK - 1e-9
end

-- How far raised (0 lowered .. 1 settled), for the HUD's raise bar.
function AimRules.raiseProgress(aim: Aim, now: number): number
	local at = aim.raisedAt
	if at == nil then
		return 0
	end
	local seconds = (settings().RaiseTicks + AimRules.RAISE_MARGIN_TICKS) * AimRules.TICK
	return math.clamp((now - at) / seconds, 0, 1)
end

--[[ Trigger and cadence ]]

-- May a shot of `ticks` go at `now` (the client keeps the whole shot time: no slack)?
function AimRules.ready(aim: Aim, now: number, ticks: number): boolean
	local last = aim.lastShot
	return last == nil or now - last >= ticks * AimRules.TICK - 1e-9
end

--[[
	What the trigger does this frame (see the header): `held` the trigger is down, `auto` the fire
	mode is automatic, `ticks` its shot time, `canFire` / `reason` WeaponState.canFire's answer.
	"fire" records the shot.
]]
function AimRules.pull(
	aim: Aim,
	now: number,
	held: boolean,
	auto: boolean,
	ticks: number,
	canFire: boolean,
	reason: string?
): Pull?
	if not held then
		aim.spent = false
		return nil
	end
	if aim.spent or aim.posture == "lowered" or not AimRules.settled(aim, now) or AimRules.busy(aim, now) then
		return nil
	end
	if not canFire then
		aim.spent = true
		return if reason == WeaponState.EMPTY then "dry" else "jam"
	end
	if not AimRules.ready(aim, now, ticks) then
		return nil
	end
	if not auto then
		aim.spent = true
	end
	aim.lastShot = Handling.after(aim.lastShot, now, ticks)
	return "fire"
end

-- Ends automatic fire (and a waiting press) until the trigger is let go.
function AimRules.stop(aim: Aim)
	aim.spent = true
end

--[[ Timed weapon actions ]]

--[[
	Ticks the server locks the gun for after weapon op `op` (Shared/Weapons/Loading: 1 reload, 2
	load a round, 3 clear a jam, 4 fire mode, 5 light) that did something; `chambered`: a reload
	that chambered a round.
]]
function AimRules.lockTicks(spec: Weapons.FirearmSpec, op: number, chambered: boolean): number
	if op == 1 then
		return if spec.magazine ~= nil then Handling.reloadTicks(spec, chambered) else spec.roundTicks
	elseif op == 2 then
		return spec.roundTicks
	elseif op == 3 then
		return settings().UnjamTicks
	elseif op == 4 then
		return settings().ModeTicks
	end
	return 0
end

-- What a weapon op did to the held stack: whether it changed at all, and whether it chambered a
-- round (the chamber was empty before and holds one after).
function AimRules.outcome(before: Items.Stack?, after: Items.Stack?): (boolean, boolean)
	if before == nil or after == nil then
		return before ~= after, false
	end
	local changed = before.item ~= after.item
		or before.count ~= after.count
		or (before.damage or 0) ~= (after.damage or 0)
		or not Items.sameData(before.data, after.data)
	local chambered = WeaponState.chamber(before) == nil and WeaponState.chamber(after) ~= nil
	return changed, chambered
end

-- Starts a timed action of `ticks` at `now` (0 ticks: nothing).
function AimRules.startBusy(aim: Aim, kind: BusyKind, now: number, ticks: number)
	if ticks <= 0 then
		return
	end
	aim.busyKind = kind
	aim.busyFrom = now
	aim.busyEnds = now + ticks * AimRules.TICK
end

-- Is a timed action running at `now`?
function AimRules.busy(aim: Aim, now: number): boolean
	return aim.busyKind ~= nil and now < aim.busyEnds
end

--[[
	The running action's progress (0..1) and kind, nil when none runs. An action that ended is
	cleared here and its kind returned once as `finished` (for its closing sound).
]]
function AimRules.progress(aim: Aim, now: number): (number?, BusyKind?, BusyKind?)
	local kind: BusyKind? = aim.busyKind
	if kind == nil then
		return nil, nil, nil
	end
	if now >= aim.busyEnds then
		aim.busyKind = nil
		return nil, nil, kind
	end
	local length = aim.busyEnds - aim.busyFrom
	return if length > 0 then math.clamp((now - aim.busyFrom) / length, 0, 1) else 1, kind, nil
end

-- Does an internal magazine want another round (it holds fewer than its rounds and a chambered
-- one)? false for a detachable feed and a jammed gun.
function AimRules.wantsRound(stack: Items.Stack?): boolean
	local spec = if stack then Weapons.firearm(stack.item) else nil
	if stack == nil or spec == nil or spec.magazine ~= nil or WeaponState.jammed(stack) then
		return false
	end
	local n = WeaponState.rounds(stack)
	local chambered = if WeaponState.chamber(stack) then 1 else 0
	return n + chambered < spec.internal + 1
end

--[[ Speed and view ]]

-- The speed factor and whether sprinting is barred for a posture (Player/MovementController
-- .setAimSlow); `guard` for a melee weapon's guard.
function AimRules.speed(posture: Posture, guard: boolean?): (number, boolean)
	local s = settings()
	if guard then
		-- (Config.Weapons.GuardSpeed: guarding with a melee weapon, Interaction/MeleeInput.)
		return s.GuardSpeed, true
	elseif posture == "raised" then
		return s.RaisedSpeed, true
	elseif posture == "sights" then
		return s.SightsSpeed, true
	end
	return 1, false
end

-- Does Minecraft's crosshair hide (a raised gun has its own dot or the sights)?
function AimRules.hidesCrosshair(posture: Posture): boolean
	return posture ~= "lowered"
end

-- Does the shoulder dot show (raised over the shoulder, Config.Weapons.ShoulderDot)?
function AimRules.showsDot(posture: Posture): boolean
	return posture == "raised" and settings().ShoulderDot == true
end

-- The zoom for `posture` with gun `spec` and optic item `optic` (nil: none).
function AimRules.zoom(posture: Posture, spec: Weapons.FirearmSpec?, optic: number?): number
	if posture ~= "sights" or spec == nil then
		return 1
	end
	return Handling.zoom(spec, optic)
end

-- Is `zoom` a scope's (the overlay instead of the model)?
function AimRules.scoped(zoom: number): boolean
	return zoom >= AimRules.SCOPE_ZOOM - 1e-9
end

-- The field of view (degrees) of `base` at `zoom`, within Roblox's limits.
function AimRules.fov(base: number, zoom: number): number
	return math.clamp(base / math.max(zoom, 1e-3), AimRules.MIN_FOV, AimRules.MAX_FOV)
end

-- The mouse's (and stick's) share at `zoom`: the view turns as fast on the screen however zoomed.
function AimRules.sensitivity(zoom: number): number
	return 1 / math.max(zoom, 1e-3)
end

-- `current` eased towards `target` over `dt` seconds at `rate` (per second; it snaps within 1e-3).
function AimRules.ease(current: number, target: number, dt: number, rate: number): number
	local value = current + (target - current) * (1 - math.exp(-rate * math.max(dt, 0)))
	if math.abs(target - value) < 1e-3 then
		return target
	end
	return value
end

--[[ Recoil, the model's kick, sway ]]

function AimRules.newRecoil(): Recoil
	return { pitch = 0, yaw = 0, back = 0 }
end

-- A shot's kick (degrees up and right): waits for the camera, and its share comes back later.
function AimRules.kick(recoil: Recoil, pitch: number, yaw: number)
	recoil.pitch += pitch
	recoil.yaw += yaw
	recoil.back += Handling.recoverable(pitch)
end

-- The kick waiting for the camera (degrees up, right), taken away.
function AimRules.takeKick(recoil: Recoil): (number, number)
	local pitch, yaw = recoil.pitch, recoil.yaw
	recoil.pitch, recoil.yaw = 0, 0
	return pitch, yaw
end

-- Degrees of pitch coming back down over `dt` seconds.
function AimRules.recover(recoil: Recoil, dt: number): number
	local back = recoil.back
	if back <= 0 then
		return 0
	end
	local step = back * Handling.recoverStep(dt)
	if back - step < 1e-4 then
		step = back
	end
	recoil.back = back - step
	return step
end

-- Forgets every kick (the gun was lowered or changed).
function AimRules.clearRecoil(recoil: Recoil)
	recoil.pitch, recoil.yaw, recoil.back = 0, 0, 0
end

-- The first-person model's kick `since` seconds after a shot: studs back, degrees up.
function AimRules.modelKick(since: number): (number, number)
	if since < 0 or since >= AimRules.KICK_SECONDS then
		return 0, 0
	end
	local left = 1 - since / AimRules.KICK_SECONDS
	local share = left * left
	return AimRules.KICK_BACK * share, AimRules.KICK_UP * share
end

-- How much of the sway shows (0 .. 1), growing in over SWAY_IN after raising.
function AimRules.swayBlend(aim: Aim, now: number): number
	local at = aim.raisedAt
	if at == nil then
		return 0
	end
	return math.clamp((now - at) / AimRules.SWAY_IN, 0, 1)
end

--[[ Poses ]]

-- Is `spec` a long gun (held with both hands at the shoulder): not a pistol or a revolver?
function AimRules.longGun(spec: Weapons.FirearmSpec?): boolean
	return spec ~= nil and spec.class ~= "pistol" and spec.class ~= "revolver"
end

--[[
	The first-person hip pose in the camera's space (studs: right, up, ahead negative) and the
	barrel's turn (radians: yaw left, pitch up) that points it at the screen's centre AIM_DEPTH
	studs ahead.
]]
function AimRules.hipPose(): (number, number, number, number, number)
	local x, y, z = AimRules.HIP[1], AimRules.HIP[2], AimRules.HIP[3]
	local depth = AimRules.AIM_DEPTH + z
	-- (From the grip to (0, 0, -AIM_DEPTH): left by x, up by -y, ahead by depth.)
	local yaw = math.atan2(x, depth)
	local pitch = math.atan2(-y, math.sqrt(depth * depth + x * x))
	return x, y, z, yaw, pitch
end

--[[
	The third-person arms for a gun held in `posture` with the look's `pitch` (radians, up
	positive): each shoulder's turn in the torso's axes (radians: rx forward, then ry inward for
	the right arm and outward for the left, then rz), whether the left arm is posed (a lowered
	handgun leaves it to the animation), and the head's pitch (nil: left alone).
]]
function AimRules.armPose(
	posture: Posture,
	pitch: number,
	long: boolean
): (number, number, number, number, number, number, boolean, number?)
	local half = math.pi / 2
	if posture ~= "lowered" then
		if long then
			-- Right hand at the grip, left forward under the barrel.
			return half + pitch, 0.25, 0, half + pitch + 0.15, -0.65, 0, true, pitch * 0.8
		end
		-- Both hands together on the grip.
		return half + pitch, 0.3, 0, half + pitch, -0.5, 0, true, pitch * 0.8
	end
	if long then
		-- Across the body, the muzzle low and to the left.
		return 0.55, 0.45, 0, 1.05, -0.75, 0, true, nil
	end
	-- A handgun down at the side, a little forward.
	return 0.3, 0.1, 0, 0, 0, 0, false, nil
end

--[[
	The third-person arms for a melee weapon (as `armPose`), guarding (`guard`: across the chest,
	both hands on it) or winding a heavy attack up (`charge` 0..1: the right arm drawn up and back
	over the shoulder, the left left to the animation); nil when neither (the animation's own arms).
]]
function AimRules.meleeArms(guard: boolean, charge: number): (number?, number, number, number, number, number, boolean)
	if guard then
		return 1.75, 0.55, 0, 1.45, -0.7, 0, true
	end
	if charge > 0 then
		local c = math.clamp(charge, 0, 1)
		return 2.5 * c, -0.2 * c, 0, 0, 0, 0, false
	end
	return nil, 0, 0, 0, 0, 0, false
end

--[[
	The first-person melee weapon's shift (studs: right, up, back; degrees: roll left, tip back) for a guard
	share `guard` (0..1, eased) and a wind-up `charge` (0..1): guarding brings it across to the
	middle and lays it over, winding up lifts it and draws it back.
]]
function AimRules.meleeView(guard: number, charge: number): (number, number, number, number, number)
	local g, c = math.clamp(guard, 0, 1), math.clamp(charge, 0, 1)
	return -0.35 * g + 0.1 * c, 0.15 * g + 0.2 * c, 0.3 * c, 55 * g, 30 * c
end

--[[
	Which way the gun points in third person (radians): the yaw left of the body's facing and the
	pitch (up positive). Raised: along the look; lowered: a long gun down and across the body, a
	handgun down.
]]
function AimRules.gunAngles(posture: Posture, pitch: number, long: boolean): (number, number)
	if posture ~= "lowered" then
		return 0, pitch
	end
	if long then
		return 0.55, -0.6
	end
	return 0.05, -1.2
end

--[[ The aim ]]

--[[
	Where the ray from (ox, oy, oz) along the unit (dx, dy, dz) enters the box (x0, y0, z0)..(x1, y1,
	z1): its distance (0 when it starts inside), nil when it misses or the box is behind. (The aim
	stops at other players' hulls as at blocks and mobs.)
]]
function AimRules.rayBox(
	ox: number,
	oy: number,
	oz: number,
	dx: number,
	dy: number,
	dz: number,
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): number?
	local near, far = -math.huge, math.huge
	for axis = 1, 3 do
		local o = if axis == 1 then ox elseif axis == 2 then oy else oz
		local d = if axis == 1 then dx elseif axis == 2 then dy else dz
		local lo = if axis == 1 then x0 elseif axis == 2 then y0 else z0
		local hi = if axis == 1 then x1 elseif axis == 2 then y1 else z1
		if math.abs(d) < 1e-12 then
			if o < lo or o > hi then
				return nil
			end
		else
			local t1, t2 = (lo - o) / d, (hi - o) / d
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			near = math.max(near, t1)
			far = math.min(far, t2)
			if near > far then
				return nil
			end
		end
	end
	if far < 0 then
		return nil
	end
	return math.max(near, 0)
end

-- Turns a little closer than this (cosine) and the aim from the eyes falls back to the camera's
-- direction (a point behind the eyes: Interaction/Casting's rule).
AimRules.FRONT = 0.2

--[[
	The unit direction from the eyes (ex, ey, ez) towards (tx, ty, tz), what the camera's ray
	(along the unit (dx, dy, dz)) points at; the camera's direction itself when that point is not
	in front of the eyes (AimRules.FRONT).
]]
function AimRules.aimFrom(
	ex: number,
	ey: number,
	ez: number,
	tx: number,
	ty: number,
	tz: number,
	dx: number,
	dy: number,
	dz: number
): (number, number, number)
	local ax, ay, az = tx - ex, ty - ey, tz - ez
	local length = math.sqrt(ax * ax + ay * ay + az * az)
	if length > 1e-6 then
		ax, ay, az = ax / length, ay / length, az / length
		if ax * dx + ay * dy + az * dz >= AimRules.FRONT then
			return ax, ay, az
		end
	end
	return dx, dy, dz
end

--[[ The Fire message's stance ]]

-- Moving for the spread and the sway: faster than this (blocks a second, horizontal).
AimRules.MOVING_SPEED = 0.5

-- Does a horizontal speed of `speed` blocks a second count as moving?
function AimRules.moving(speed: number): boolean
	return speed > AimRules.MOVING_SPEED
end

return AimRules

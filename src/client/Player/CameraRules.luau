--!strict
--[[
	The camera's rules in the manner of DayZ (pure; Player/CameraRig drives Roblox's camera by them,
	tests/spec/CameraRules checks them). Numbers come from Config.Camera and DayZ's own camera
	scripts (dayzplayercamera3rdperson.c, dayzplayercameras.c, dayzplayercamera_base.c,
	dayzplayerimplement.c). Scalars in and out: lengths in studs, angles in radians (Roblox's
	senses: a yaw turns as CFrame.Angles(0, yaw, 0), so a positive one turns left, and the body
	looks down -Z at yaw 0; a pitch is up positive) unless a name says degrees. Nothing here
	allocates per frame: a Rig and a Look are made once and changed in place.

	  Views      `chosen` is "third" or "first" (the Camera setting, then the Toggle Perspective
	             key: `toggle`, refused while a weapon is raised, as DayZ's camChange, and for
	             spectators). The view drawn (`view`) is "first" for spectators and in first
	             person, "sights" for the sights from third person (the camera goes to the eyes,
	             as DayZ's third-person aiming does), else "third". `bobShare`: Minecraft's view
	             bob in first person and the sights only.
	  Rig        third person: a pivot over the shoulder in the body's frame (`pivot`: up by
	             `height` from the hull's eyes, `side` x `shoulder` to the right, `forward` ahead)
	             and the camera `distance` behind it along the view. Each stance has a Profile
	             (`profileKey`, Config.Camera.Profiles); a change of profile eases every part of
	             the rig (`easeRig`) with DayZ's SmoothCD (`smoothCD`) over a smooth time of 0.3 x
	             DayZ's blend time (`transition`); the shoulder's side (right +1, left -1) eases at
	             DayZ's 0.14. In the air the pivot's height lags (`jumpLag`: none of the rise for
	             0.15 s, then a quarter of it; `heightLag` every frame: continuous across a hop
	             after a landing, and eased back to 0 on landing). Collision (`collide`, on a ray
	             cast the rig gives it) keeps Roblox's near plane out of blocks, sized every frame
	             from the camera itself (a Lens, `setLens`: |NearPlaneZ|, the field of view and the
	             viewport's aspect, as Roblox's Popper sizes its checks; the near plane is 0.1 studs
	             ahead on a computer and up to 0.5 on a phone): the pivot keeps `clip` of the way
	             from the eyes to it, then moves off blocks beside it until the near plane's half
	             width and half height fit there, and the boom is cast backwards from it and from
	             the near plane's four corners; it pulls in at once and eases back out (`boom`;
	             `boomStep`: the rig's own length while nothing pulled it in). A body that moved
	             far in a frame (`movedFar`) starts it afresh.
	  Eyes       first person and the sights look from the hull's eyes pushed ahead
	             (`firstPersonEye`: Config.Camera.FirstForward, more looking down, past the front of
	             the chest, so its edge, the legs and the feet show instead of the torso's top),
	             pulled back towards Roblox's own first-person camera where a block would cut the
	             near plane (`firstPersonClear`); in at once, out of the sights to the shoulder over
	             DayZ's 0.2 s (`eyeShare`). Targeting skips what lies between the camera and the
	             eyes' plane (`eyePlaneSkip`: 0 in first person).
	  Freelook   a Look (`newLook`): held (or toggled) Freelook freezes the aim while the camera
	             turns, up to Config.Camera.FreelookYaw each way (FreelookYawFirst in first
	             person; `clampRoom` gives the room left, which MouseLook's hook clamps the turn
	             to); let go, the camera's offset from the aim comes back by SmoothCD over
	             SnapBackSeconds (`snapStep`: the turn to queue on Roblox's camera input) while
	             input still moves the aim, and freelook ends below SNAP_END radians. Targeting
	             and presses wait while it `suspends`: freelooking, and swinging back until the
	             camera is within SNAP_READY of the aim. Every frame, in this order: `freelook`
	             (the key's edges), `aim` (the aim this frame), `suspends`, then `snapStep` while
	             snapping and `clampRoom`.
	  Body       the body's yaw follows the aim (`followYaw`): at once when flagged
	             (`turnsAtOnce`: moving, raised, first person...), else by SmoothCD over
	             Config.Camera.IdleTurnSeconds, never more than IdleTurnMaxLag behind.
	  Focus      DayZ's eye zoom (`focusFov`): FocusFov, FocusSprintFov sprinting, never wider than
	             the FOV setting, nothing while raised.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

-- The chosen view (the setting and the Toggle Perspective key) and the view drawn.
export type Chosen = "third" | "first"
export type View = "third" | "first" | "sights"
-- A raised firearm's posture (Player/AimRules.Posture).
export type Posture = "lowered" | "raised" | "sights"

-- What the body does, for the rig's profile and the body's turn.
export type Stance = {
	sprinting: boolean,
	sneaking: boolean,
	-- How far the body lies down: 0 upright .. 1 crawling or swimming (MovementController's tilt).
	tilt: number,
	-- On a ladder, vine or rope, off the ground.
	climbing: boolean,
	swimming: boolean,
	flying: boolean,
	onGround: boolean,
}

--[[
	The local body as Player/MovementController draws it this frame, pushed to the rig
	(CameraRig.setBody) before Roblox's camera updates. Render studs for the eyes (Shared/World/
	Origin's frame: only this frame's values are used, so a move of the origin needs nothing).
]]
export type Body = {
	-- The hull's eyes (the eased eye height), render studs.
	eyeX: number,
	eyeY: number,
	eyeZ: number,
	-- The body's yaw (radians, CFrame.Angles(0, yaw, 0)).
	yaw: number,
	-- Horizontal speed (blocks a second).
	speed: number,
	-- Seconds since the feet left the ground (0 on it), and how far the eyes rose since (studs).
	airborne: number,
	rise: number,
	-- Moves through blocks (a spectator): the camera skips collision.
	noClip: boolean,
	stance: Stance,
}

-- A rig's shape (studs): Config.Camera.Profiles' rows.
export type Profile = {
	distance: number,
	shoulder: number,
	height: number,
	forward: number,
}

-- The rig as drawn, eased towards a Profile, with SmoothCD's velocities.
export type Rig = {
	distance: number,
	shoulder: number,
	height: number,
	forward: number,
	-- The shoulder's side: +1 right .. -1 left.
	side: number,
	-- The jump's lag of the pivot's height (studs, down negative).
	lag: number,
	distanceVel: number,
	shoulderVel: number,
	heightVel: number,
	forwardVel: number,
	sideVel: number,
	lagVel: number,
}

-- Freelook's state.
export type Look = {
	-- Freelooking: the aim stays at (aimYaw, aimPitch) while the camera turns.
	active: boolean,
	-- Coming back: the camera's offset from the aim returns to 0.
	snapping: boolean,
	-- Toggle mode: on until the next press.
	toggled: boolean,
	-- The aim (radians), kept by `aim`.
	aimYaw: number,
	aimPitch: number,
	-- The camera's offset from the aim (radians, the camera's yaw and pitch less the aim's) and
	-- SmoothCD's velocities while it comes back.
	yaw: number,
	pitch: number,
	yawVel: number,
	pitchVel: number,
}

--[[
	The camera this frame, for the collision (`setLens` fills one in place every frame): the view's
	unit look, right and up, how far ahead of the camera Roblox's near plane is (studs) and its half
	width and half height there.
]]
export type Lens = {
	lx: number,
	ly: number,
	lz: number,
	rx: number,
	ry: number,
	rz: number,
	ux: number,
	uy: number,
	uz: number,
	near: number,
	halfWidth: number,
	halfHeight: number,
}

--[[
	A ray cast for the collision (`collide`): how far (studs) a ray from (ox, oy, oz) along
	(dx, dy, dz) (render studs, any length) goes before a block stops it, looking `max` studs far;
	math.huge when nothing does (Player/CameraRig: Shared/World/VoxelRaycast.distance).
]]
export type Cast = (ox: number, oy: number, oz: number, dx: number, dy: number, dz: number, max: number) -> number

local CameraRules = {}

local CAMERA = Config.Camera
local TAU = 2 * math.pi

-- DayZ's blend time (seconds) when no pair in TRANSITIONS matches.
CameraRules.DEFAULT_TRANSITION = 0.3
-- A blend of `seconds` eases with SmoothCD over this share of it.
CameraRules.BLEND_SHARE = 0.3
-- The shoulder's side eases over this smooth time (DayZ: SmoothCD(..., 0.14)).
CameraRules.SIDE_SECONDS = 0.14
-- The jump (DayZ's 3rd Jump camera): the pivot keeps its height this long after leaving the
-- ground, then follows all but JUMP_DAMP of the rise, eased over JUMP_SMOOTH.
CameraRules.JUMP_HOLD = 0.15
CameraRules.JUMP_DAMP = 0.25
CameraRules.JUMP_SMOOTH = 0.3
-- Freelook ends when the camera is back within this of the aim (radians, each way).
CameraRules.SNAP_END = 0.002
-- How far freelook may look up or down from the aim (DayZ's CONST_UD; Roblox's camera keeps
-- the pitch within 80 degrees of level besides).
CameraRules.FREELOOK_PITCH = math.rad(85)
-- The body counts as lying (the `lying` rig) past this tilt.
CameraRules.LYING_TILT = 0.5
-- Landing: the jump's lag goes back to 0 over DayZ's blend from the Jump camera (seconds, eased
-- over BLEND_SHARE of it).
CameraRules.LAND_SECONDS = 0.3
-- Leaving the sights from third person for the shoulder: DayZ's Erc <-> Raised blend (seconds).
CameraRules.SIGHTS_OUT_SECONDS = 0.2
-- The body moved this far (studs) in one frame: a teleport or a respawn; the camera starts afresh.
CameraRules.MOVED_FAR = 16
-- The near plane keeps this far (studs) from blocks beside it (`collide`, `firstPersonClear`).
CameraRules.SIDE_GAP = 0.05
-- Roblox's near plane is "between 0.1 and 0.5 studs ahead, varying across platforms" (Camera.
-- NearPlaneZ): a camera that reports none counts as the farthest.
CameraRules.NEAR_FALLBACK = 0.5
-- While the camera swings back from freelook, targeting and presses come back once it is within
-- this of the aim each way (radians): the crosshair, the camera's centre, is then where the hands
-- point, as near as the eye can tell (`suspends`).
CameraRules.SNAP_READY = math.rad(2)

--[[
	DayZ's blend times between rigs (dayzplayercameras.c), "from>to" -> seconds: Erc <-> Raised 0.2,
	Erc -> Sprint 0.6, Sprint -> Erc 0.3, Erc <-> Crouch 0.4, Erc -> Prone 0.8, Prone -> Erc 0.9,
	Crouch <-> CrouchRaised 0.2. The rest take DEFAULT_TRANSITION.
]]
CameraRules.TRANSITIONS = table.freeze({
	["standing>raised"] = 0.2,
	["raised>standing"] = 0.2,
	["standing>raisedHands"] = 0.2,
	["raisedHands>standing"] = 0.2,
	["standing>sprinting"] = 0.6,
	["sprinting>standing"] = 0.3,
	["standing>crouching"] = 0.4,
	["crouching>standing"] = 0.4,
	["standing>lying"] = 0.8,
	["lying>standing"] = 0.9,
	["crouching>crouchRaised"] = 0.2,
	["crouchRaised>crouching"] = 0.2,
} :: { [string]: number })

-- Config.Camera.Profiles as Profiles, by key.
local PROFILES: { [string]: Profile } = {}
for key, row in (CAMERA.Profiles :: any) :: { [string]: { number } } do
	PROFILES[key] = table.freeze({ distance = row[1], shoulder = row[2], height = row[3], forward = row[4] })
end
CameraRules.PROFILES = table.freeze(PROFILES)

-- `angle` within (-pi, pi].
local function wrap(angle: number): number
	angle = angle % TAU
	if angle > math.pi then
		angle -= TAU
	end
	return angle
end
CameraRules.wrap = wrap

--[[ Views ]]

-- The view drawn: spectators see from the eyes; the sights from third person go to the eyes.
function CameraRules.view(chosen: Chosen, posture: Posture, spectator: boolean): View
	if spectator or chosen == "first" then
		return "first"
	elseif posture == "sights" then
		return "sights"
	end
	return "third"
end

--[[
	The chosen view after a Toggle Perspective press: unchanged while a firearm is raised or a melee
	guard is up (`guard`: DayZ's camChange is false while anything is raised) or spectating.
]]
function CameraRules.toggle(chosen: Chosen, posture: Posture, spectator: boolean, guard: boolean?): Chosen
	if spectator or posture ~= "lowered" or guard == true then
		return chosen
	end
	return if chosen == "first" then "third" else "first"
end

-- Minecraft's view bob shows in first person and the sights, not over the shoulder (DayZ).
function CameraRules.bobShare(view: View): number
	return if view == "third" then 0 else 1
end

--[[ The third-person rig ]]

--[[
	The rig for what the body does: lying (crawling, swimming), climbing and flying first, then a
	raised firearm (crouched or not), a melee guard, sprinting, sneaking, standing.
]]
function CameraRules.profileKey(stance: Stance, posture: Posture, guard: boolean): string
	if stance.tilt > CameraRules.LYING_TILT then
		return "lying"
	elseif stance.climbing then
		return "climbing"
	elseif stance.flying then
		return "flying"
	elseif posture ~= "lowered" then
		return if stance.sneaking then "crouchRaised" else "raised"
	elseif guard then
		return "raisedHands"
	elseif stance.sprinting then
		return "sprinting"
	elseif stance.sneaking then
		return "crouching"
	end
	return "standing"
end

-- The Profile of `key` (standing's for an unknown key).
function CameraRules.profile(key: string): Profile
	return PROFILES[key] or PROFILES.standing
end

-- DayZ's blend time (seconds) from rig `from` to rig `to` (0 for the same rig).
function CameraRules.transition(from: string, to: string): number
	if from == to then
		return 0
	end
	return CameraRules.TRANSITIONS[from .. ">" .. to] or CameraRules.DEFAULT_TRANSITION
end

--[[
	Enforce's Math.SmoothCD (DayZ), the critically damped ease of Game Programming Gems 4
	("Critically Damped Ease-In/Ease-Out Smoothing"): `cur` towards `target` with velocity `vel`
	over `smoothTime` seconds, a frame of `dt`. Returns the new value and velocity. (DayZ's
	maxVelocity, 1000 wherever its cameras call it, never binds here and is left out.) A smooth
	time of 0 or less arrives at once.
]]
function CameraRules.smoothCD(
	cur: number,
	target: number,
	vel: number,
	smoothTime: number,
	dt: number
): (number, number)
	if smoothTime <= 0 then
		return target, 0
	end
	if dt <= 0 then
		return cur, vel
	end
	local omega = 2 / smoothTime
	local x = omega * dt
	local exp = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
	local change = cur - target
	local temp = (vel + omega * change) * dt
	return target + (change + temp) * exp, (vel - omega * temp) * exp
end

local smoothCD = CameraRules.smoothCD

-- A rig at `profile` on `side` (+1 right, -1 left), at rest.
function CameraRules.newRig(profile: Profile, side: number): Rig
	return {
		distance = profile.distance,
		shoulder = profile.shoulder,
		height = profile.height,
		forward = profile.forward,
		side = side,
		lag = 0,
		distanceVel = 0,
		shoulderVel = 0,
		heightVel = 0,
		forwardVel = 0,
		sideVel = 0,
		lagVel = 0,
	}
end

--[[
	Eases `rig` (in place) a frame of `dt` towards `target` over a blend of `seconds` (smooth time
	BLEND_SHARE x seconds; 0: at once), its side towards `side` over SIDE_SECONDS.
]]
function CameraRules.easeRig(rig: Rig, target: Profile, side: number, dt: number, seconds: number)
	local smooth = math.max(seconds, 0) * CameraRules.BLEND_SHARE
	rig.distance, rig.distanceVel = smoothCD(rig.distance, target.distance, rig.distanceVel, smooth, dt)
	rig.shoulder, rig.shoulderVel = smoothCD(rig.shoulder, target.shoulder, rig.shoulderVel, smooth, dt)
	rig.height, rig.heightVel = smoothCD(rig.height, target.height, rig.heightVel, smooth, dt)
	rig.forward, rig.forwardVel = smoothCD(rig.forward, target.forward, rig.forwardVel, smooth, dt)
	rig.side, rig.sideVel = smoothCD(rig.side, side, rig.sideVel, CameraRules.SIDE_SECONDS, dt)
end

--[[
	The pivot (render studs) for eyes (ex, ey, ez) and body yaw `yaw`: up by the rig's height and
	jump lag, `side` x `shoulder` along the body's right, `forward` along its facing.
]]
function CameraRules.pivot(ex: number, ey: number, ez: number, yaw: number, rig: Rig): (number, number, number)
	local s, c = math.sin(yaw), math.cos(yaw)
	local across = rig.side * rig.shoulder
	local ahead = rig.forward
	-- (Right: (cos, 0, -sin); facing: (-sin, 0, -cos).)
	return ex + c * across - s * ahead, ey + rig.height + rig.lag, ez - s * across - c * ahead
end

--[[
	The jump's lag of the pivot's height (studs, down negative) and its velocity, a frame of `dt`
	`airborne` seconds after the feet left the ground, the eyes `rise` studs above where they left
	it: none of the rise for JUMP_HOLD seconds, then all but JUMP_DAMP of it, eased over
	JUMP_SMOOTH (DayZ's 3rd Jump camera). Falling below the take-off lags nothing. On the ground
	(`airborne` 0) it is 0.
]]
function CameraRules.jumpLag(lag: number, vel: number, rise: number, airborne: number, dt: number): (number, number)
	if airborne <= 0 then
		return 0, 0
	end
	local up = math.max(rise, 0)
	if airborne < CameraRules.JUMP_HOLD then
		return -up, 0
	end
	return smoothCD(lag, -CameraRules.JUMP_DAMP * up, vel, CameraRules.JUMP_SMOOTH, dt)
end

--[[
	The rig's height lag a frame of `dt` on, for every frame, as `jumpLag` in the air but continuous.
	`rise` is how far the eyes are above where they were when the feet last left the ground (on
	the ground too, until the lag is back to 0; 0 when they never left), `takeoff` the lag then
	(not always 0: one jump may follow a landing). The hold keeps the pivot where it was at the
	take-off; the pivot never sinks below that height afterwards (the lag's ease would otherwise
	trail the fall and drop the camera under the standing height as the feet land), and on the
	ground the lag goes back to 0 over LAND_SECONDS (DayZ's blend from the Jump camera) instead of
	at once. Returns the lag (studs, down negative) and its velocity.
]]
function CameraRules.heightLag(
	lag: number,
	vel: number,
	rise: number,
	airborne: number,
	takeoff: number,
	dt: number
): (number, number)
	local floor = math.min(0, takeoff - math.max(rise, 0))
	local value, velocity
	if airborne > 0 then
		if airborne < CameraRules.JUMP_HOLD then
			return floor, 0
		end
		value, velocity = CameraRules.jumpLag(lag, vel, rise, airborne, dt)
	else
		if lag == 0 and vel == 0 then
			return 0, 0
		end
		value, velocity = smoothCD(lag, 0, vel, CameraRules.LAND_SECONDS * CameraRules.BLEND_SHARE, dt)
		if math.abs(value) < 1e-3 and math.abs(velocity) < 1e-2 then
			return 0, 0
		end
	end
	if value < floor then
		return floor, 0
	end
	return value, velocity
end

--[[
	How much of the way `wanted` (studs, eyes to pivot) to keep when a ray along it is free for
	`free` studs (math.huge: nothing there): `margin` short of what it hit, never below 0.
]]
function CameraRules.clip(free: number, wanted: number, margin: number): number
	return math.clamp(math.min(wanted, free - margin), 0, wanted)
end

--[[ The near plane ]]

function CameraRules.newLens(): Lens
	return {
		lx = 0,
		ly = 0,
		lz = -1,
		rx = 1,
		ry = 0,
		rz = 0,
		ux = 0,
		uy = 1,
		uz = 0,
		near = CameraRules.NEAR_FALLBACK,
		halfWidth = 0,
		halfHeight = 0,
	}
end

--[[
	The size of Roblox's near plane (studs) for a camera whose Camera.NearPlaneZ is `nearPlaneZ`
	(negative), whose vertical field of view is `fov` degrees and whose viewport is `aspect` (width
	over height): how far ahead of the camera it is, and its half width and half height there
	(Roblox's Popper sizes its own checks from the same three).
]]
function CameraRules.nearPlane(nearPlaneZ: number, fov: number, aspect: number): (number, number, number)
	local near = math.abs(nearPlaneZ)
	if near ~= near or near <= 0 then
		near = CameraRules.NEAR_FALLBACK
	end
	if not (fov > 0) then
		fov = 70
	end
	if not (aspect > 0) then
		aspect = 1
	end
	local halfHeight = near * math.tan(math.rad(math.min(fov, 179)) / 2)
	return near, halfHeight * aspect, halfHeight
end

--[[
	Fills `lens` (in place) for this frame: the camera's rotation (CFrame:GetComponents() r00 .. r22),
	and its near plane (`nearPlane`).
]]
function CameraRules.setLens(
	lens: Lens,
	r00: number,
	r01: number,
	r02: number,
	r10: number,
	r11: number,
	r12: number,
	r20: number,
	r21: number,
	r22: number,
	nearPlaneZ: number,
	fov: number,
	aspect: number
)
	lens.lx, lens.ly, lens.lz = -r02, -r12, -r22
	lens.rx, lens.ry, lens.rz = r00, r10, r20
	lens.ux, lens.uy, lens.uz = r01, r11, r21
	lens.near, lens.halfWidth, lens.halfHeight = CameraRules.nearPlane(nearPlaneZ, fov, aspect)
end

--[[
	Moves the point (px, py, pz) along the unit axis (ax, ay, az) until `need` studs are free of
	blocks on both sides of it along the axis (as little as it takes; midway where the gap is
	narrower than twice `need`). Two casts of 2 x `need`.
]]
local function room(
	px: number,
	py: number,
	pz: number,
	ax: number,
	ay: number,
	az: number,
	need: number,
	cast: Cast
): (number, number, number)
	if need <= 0 then
		return px, py, pz
	end
	local span = 2 * need
	local plus = math.min(cast(px, py, pz, ax, ay, az, span), span)
	local minus = math.min(cast(px, py, pz, -ax, -ay, -az, span), span)
	-- (Where along the axis the point keeps `need` both ways, from where it is.)
	local low, high = need - minus, plus - need
	local shift = if low <= high then math.clamp(0, low, high) else (plus - minus) / 2
	if shift == 0 then
		return px, py, pz
	end
	return px + ax * shift, py + ay * shift, pz + az * shift
end

--[[
	The shoulder rig's collision with blocks, for eyes (ex, ey, ez), pivot (px, py, pz), a boom
	`distance` long and the camera's `lens` (its axes and near plane: `setLens`):
	  1. the eyes to the pivot: the pivot keeps `clip` of the way (Config.Camera.Margin short of a
	     block), so it is never inside a wall beside the head;
	  2. room beside it: the pivot moves off blocks along the view's right and up (`room`) until
	     the near plane's half width and half height (and SIDE_GAP) are free each way, so a wall
	     beside the camera (a 1 x 2 tunnel, walking along a wall) never cuts the near plane;
	  3. the boom from that pivot backwards (-look) as five rays: the centre, and one from each of
	     the near plane's corners (right x +-half width, up x +-half height, each first cast out
	     from the pivot and kept SIDE_GAP short of a block), as Roblox's Popper sweeps its corners.
	Returns the pivot kept and how long the boom may be: math.huge with nothing in the way, else the
	nearest block's distance along the boom less the margin (`boomStep` / `boom` take it). At most
	fourteen casts of a few studs, the longest `distance` + the margin.
]]
function CameraRules.collide(
	ex: number,
	ey: number,
	ez: number,
	px: number,
	py: number,
	pz: number,
	distance: number,
	lens: Lens,
	cast: Cast
): (number, number, number, number)
	local margin, gap = CAMERA.Margin, CameraRules.SIDE_GAP
	local wx, wy, wz = px - ex, py - ey, pz - ez
	local wanted = math.sqrt(wx * wx + wy * wy + wz * wz)
	if wanted > 1e-6 then
		local share = CameraRules.clip(cast(ex, ey, ez, wx, wy, wz, wanted + margin), wanted, margin) / wanted
		px, py, pz = ex + wx * share, ey + wy * share, ez + wz * share
	end
	local halfWidth, halfHeight = lens.halfWidth, lens.halfHeight
	local rx, ry, rz = lens.rx, lens.ry, lens.rz
	local ux, uy, uz = lens.ux, lens.uy, lens.uz
	px, py, pz = room(px, py, pz, rx, ry, rz, halfWidth + gap, cast)
	px, py, pz = room(px, py, pz, ux, uy, uz, halfHeight + gap, cast)
	local free = math.huge
	if distance <= 0 then
		return px, py, pz, free
	end
	local bx, by, bz = -lens.lx, -lens.ly, -lens.lz
	local corner = math.sqrt(halfWidth * halfWidth + halfHeight * halfHeight)
	for ray = 0, 4 do
		local sx, sy, sz = px, py, pz
		if ray > 0 and corner > 0 then
			-- (A corner: out from the pivot, short of a block.)
			local across = if ray <= 2 then halfWidth else -halfWidth
			local along = if ray % 2 == 1 then halfHeight else -halfHeight
			local ox, oy, oz = rx * across + ux * along, ry * across + uy * along, rz * across + uz * along
			local hit = cast(px, py, pz, ox, oy, oz, corner)
			local share = if hit == math.huge then 1 else math.max(0, hit - gap) / corner
			sx, sy, sz = px + ox * share, py + oy * share, pz + oz * share
		end
		local hit = cast(sx, sy, sz, bx, by, bz, distance + margin)
		if hit ~= math.huge then
			free = math.min(free, hit - margin)
		end
	end
	return px, py, pz, free
end

--[[
	The boom's length a frame of `dt` on: `free` is how far it may reach now (the rig's distance,
	or less where blocks are: their distance less the margin). Shorter pulls in at once; longer
	eases out at Config.Camera.EaseOut a second (the remaining way's share 1 - e^(-EaseOut dt)), as
	Roblox's Popper lets its zoom spring back.
]]
function CameraRules.boom(current: number, free: number, dt: number): number
	free = math.max(free, 0)
	if free <= current then
		return free
	end
	local length = current + (free - current) * (1 - math.exp(-CAMERA.EaseOut * math.max(dt, 0)))
	return if free - length < 1e-3 then free else length
end

--[[
	The boom's length this frame for a rig `distance` long now (`before`: last frame's) where blocks
	leave `free` studs (math.huge: none; the nearest block less the margin): while the boom isn't
	pulled in (it was the rig's length) and nothing is in the way, it is the rig's length, which
	eases by the rig's own blend; otherwise `boom` (in at once, out at EaseOut).
]]
function CameraRules.boomStep(current: number, distance: number, before: number, free: number, dt: number): number
	if free >= distance and current >= before - 1e-6 then
		return distance
	end
	return CameraRules.boom(current, math.min(free, distance), dt)
end

--[[
	The share of the way from the shoulder to the eye point the camera is at (1: at the eyes), and
	its velocity, a frame of `dt` on in `view` (`previous`: last frame's): at once into first
	person and the sights, at once from first person to the shoulder (Toggle Perspective is
	instant, as in DayZ), eased over SIGHTS_OUT_SECONDS from the sights to the shoulder.
]]
function CameraRules.eyeShare(share: number, vel: number, view: View, previous: View, dt: number): (number, number)
	if view ~= "third" then
		return 1, 0
	elseif previous == "first" or share <= 0 then
		return 0, 0
	end
	local value, velocity = smoothCD(share, 0, vel, CameraRules.SIGHTS_OUT_SECONDS * CameraRules.BLEND_SHARE, dt)
	if value < 1e-3 then
		return 0, 0
	end
	return value, velocity
end

-- Did the body move so far since last frame (render studs) that the camera should start afresh?
function CameraRules.movedFar(ax: number, ay: number, az: number, bx: number, by: number, bz: number): boolean
	local dx, dy, dz = bx - ax, by - ay, bz - az
	return dx * dx + dy * dy + dz * dz > CameraRules.MOVED_FAR * CameraRules.MOVED_FAR
end

--[[ First person ]]

--[[
	The first-person (and sights) eye point: the hull's eyes (ex, ey, ez) pushed FirstForward ahead
	along the body's facing `yaw`, FirstDownPush more x the downward sine of `pitch`.
]]
function CameraRules.firstPersonEye(
	ex: number,
	ey: number,
	ez: number,
	yaw: number,
	pitch: number
): (number, number, number)
	local push = CAMERA.FirstForward + CAMERA.FirstDownPush * math.max(0, -math.sin(pitch))
	return ex - math.sin(yaw) * push, ey, ez - math.cos(yaw) * push
end

--[[
	The first-person (and sights) camera for the eye point (dx, dy, dz) (`firstPersonEye`) of the
	hull's eyes (ex, ey, ez), keeping the camera's near plane (`lens`) out of blocks: the eye point
	itself where its near plane is clear, else as far along the way to it as stays clear from Roblox's
	own first-person camera, `near` behind the eyes along the look, whose near plane is centred on
	the eyes, inside the hull, which keeps 0.3 blocks from every block beside it (wider than the near
	plane's half width on any screen). The near plane's centre and four corners are cast along that
	way and each stops SIDE_GAP short of a block. Five casts of under two studs.
]]
function CameraRules.firstPersonClear(
	ex: number,
	ey: number,
	ez: number,
	dx: number,
	dy: number,
	dz: number,
	lens: Lens,
	cast: Cast
): (number, number, number)
	local near = lens.near
	local lx, ly, lz = lens.lx, lens.ly, lens.lz
	-- (Roblox's first-person camera, and the way from it to the eye point.)
	local sx, sy, sz = ex - lx * near, ey - ly * near, ez - lz * near
	local wx, wy, wz = dx - sx, dy - sy, dz - sz
	local way = math.sqrt(wx * wx + wy * wy + wz * wz)
	if way < 1e-6 then
		return dx, dy, dz
	end
	local gap = CameraRules.SIDE_GAP
	local halfWidth, halfHeight = lens.halfWidth, lens.halfHeight
	local share = 1
	for point = 0, 4 do
		-- (The near plane's centre, then its corners: from that camera they lie around the eyes.)
		local across = if point == 0 then 0 elseif point <= 2 then halfWidth else -halfWidth
		local along = if point == 0 then 0 elseif point % 2 == 1 then halfHeight else -halfHeight
		local ox = lx * near + lens.rx * across + lens.ux * along
		local oy = ly * near + lens.ry * across + lens.uy * along
		local oz = lz * near + lens.rz * across + lens.uz * along
		local hit = cast(sx + ox, sy + oy, sz + oz, wx, wy, wz, way + gap)
		if hit ~= math.huge then
			share = math.min(share, math.max(0, hit - gap) / way)
		end
	end
	if share >= 1 then
		return dx, dy, dz
	end
	return sx + wx * share, sy + wy * share, sz + wz * share
end

--[[
	How far along the targeting ray (from the camera (cx, cy, cz), unit direction (dx, dy, dz)) the
	eyes' plane lies, the eyes at (ex, ey, ez): the ray starts there, so nothing between the camera
	and the player is aimed at. 0 when the eyes are behind the camera (first person).
]]
function CameraRules.eyePlaneSkip(
	cx: number,
	cy: number,
	cz: number,
	dx: number,
	dy: number,
	dz: number,
	ex: number,
	ey: number,
	ez: number
): number
	return math.max(0, (ex - cx) * dx + (ey - cy) * dy + (ez - cz) * dz)
end

--[[
	The camera's heading on the ground (unit x, z: where forward input walks) from its rotation's
	components (CFrame:GetComponents() r00, r01, r02, r12, r22), as Roblox's control scripts take
	it (ControlModule calculateRawMoveVector): the up vector's when looking straight up or down.
]]
function CameraRules.heading(r00: number, r01: number, r02: number, r12: number, r22: number): (number, number)
	local c, s = r22, r02
	if r12 >= 1 or r12 <= -1 then
		c, s = r00, -r01 * math.sign(r12)
	end
	local norm = math.sqrt(c * c + s * s)
	if norm < 1e-6 then
		return 0, -1
	end
	return -s / norm, -c / norm
end

-- The yaw (CFrame.Angles(0, yaw, 0)) that faces ground direction (x, z).
function CameraRules.yawOf(x: number, z: number): number
	return math.atan2(-x, -z)
end

--[[ Freelook ]]

function CameraRules.newLook(): Look
	return {
		active = false,
		snapping = false,
		toggled = false,
		aimYaw = 0,
		aimPitch = 0,
		yaw = 0,
		pitch = 0,
		yawVel = 0,
		pitchVel = 0,
	}
end

--[[
	The Freelook key this frame: `held` (down now), `pressed` (went down this frame), in toggle
	mode or not; `allowed` false (the sights, a spectator, no camera hook, a screen, death,
	spectating someone, a view toggle) ends it. Starting freezes the aim where `aim` last left it;
	ending starts the snap back from the offset then. Returns whether it started and whether it
	ended this frame.
]]
function CameraRules.freelook(
	look: Look,
	held: boolean,
	allowed: boolean,
	toggleMode: boolean,
	pressed: boolean
): (boolean, boolean)
	local want = false
	if not allowed then
		look.toggled = false
	elseif toggleMode then
		if pressed then
			look.toggled = not look.toggled
		end
		want = look.toggled
	else
		look.toggled = false
		want = held
	end
	if want and not look.active then
		look.active = true
		look.snapping = false
		look.yawVel, look.pitchVel = 0, 0
		return true, false
	elseif not want and look.active then
		look.active = false
		look.snapping = look.yaw ~= 0 or look.pitch ~= 0
		look.yawVel, look.pitchVel = 0, 0
		return false, true
	end
	return false, false
end

--[[
	The aim this frame (yaw, pitch) from the camera's (radians): the camera itself, frozen while
	freelooking, the camera less the offset still coming back while snapping. Keeps the Look's aim
	and offset.
]]
function CameraRules.aim(look: Look, camYaw: number, camPitch: number): (number, number)
	if look.active then
		look.yaw = wrap(camYaw - look.aimYaw)
		look.pitch = camPitch - look.aimPitch
	elseif look.snapping then
		look.aimYaw = wrap(camYaw - look.yaw)
		look.aimPitch = camPitch - look.pitch
	else
		look.aimYaw, look.aimPitch = wrap(camYaw), camPitch
		look.yaw, look.pitch = 0, 0
	end
	return look.aimYaw, look.aimPitch
end

--[[
	Does freelook hold targeting and presses back now (after `aim` this frame: the camera's offset
	from the aim as it is now)? While freelooking, and while the camera swings back until it is
	within SNAP_READY of the aim each way: from then on the camera's own ray, which the crosshair
	shows, is where the hands point, as near as the eye can tell.
]]
function CameraRules.suspends(look: Look): boolean
	if look.active then
		return true
	end
	local ready = CameraRules.SNAP_READY
	return look.snapping and (math.abs(look.yaw) > ready or math.abs(look.pitch) > ready)
end

--[[
	The room the camera has left to turn while freelooking (radians: left, right, up, down) before
	FreelookYaw (FreelookYawFirst in "first") and FREELOOK_PITCH from the aim; math.huge each way
	when not freelooking.
]]
function CameraRules.clampRoom(
	look: Look,
	camYaw: number,
	camPitch: number,
	view: View
): (number, number, number, number)
	if not look.active then
		return math.huge, math.huge, math.huge, math.huge
	end
	local limit = math.rad(if view == "third" then CAMERA.FreelookYaw else CAMERA.FreelookYawFirst)
	local yaw = wrap(camYaw - look.aimYaw)
	local pitch = camPitch - look.aimPitch
	local pitchLimit = CameraRules.FREELOOK_PITCH
	return math.max(0, limit - yaw),
		math.max(0, limit + yaw),
		math.max(0, pitchLimit - pitch),
		math.max(0, pitchLimit + pitch)
end

--[[
	One frame of the snap back: the camera's offset from the aim eases to 0 by SmoothCD over
	Config.Camera.SnapBackSeconds, and ends (the rest at once) once both parts are within
	SNAP_END. Returns the turn to queue on Roblox's camera input (MouseLook: radians, x right,
	y down), which its next update adds; input meanwhile moves the aim. (0, 0) when not snapping.
]]
function CameraRules.snapStep(look: Look, camYaw: number, camPitch: number, dt: number): (number, number)
	if not look.snapping then
		return 0, 0
	end
	look.aimYaw = wrap(camYaw - look.yaw)
	look.aimPitch = camPitch - look.pitch
	local seconds = CAMERA.SnapBackSeconds
	local yaw, yawVel = smoothCD(look.yaw, 0, look.yawVel, seconds, dt)
	local pitch, pitchVel = smoothCD(look.pitch, 0, look.pitchVel, seconds, dt)
	if math.abs(yaw) < CameraRules.SNAP_END and math.abs(pitch) < CameraRules.SNAP_END then
		yaw, pitch, yawVel, pitchVel = 0, 0, 0, 0
		look.snapping = false
	end
	-- (A smaller yaw offset turns the camera right; a smaller pitch offset turns it down.)
	local dx, dy = look.yaw - yaw, look.pitch - pitch
	look.yaw, look.pitch, look.yawVel, look.pitchVel = yaw, pitch, yawVel, pitchVel
	return dx, dy
end

--[[ The body ]]

--[[
	Does the body turn to the aim at once this frame (else it lags while standing: `followYaw`)?
	Moving (`moving`: move input, or faster than Config.Camera.IdleTurnSpeed blocks a second),
	raised or guarding, in first person or the sights, swimming, climbing or flying.
]]
function CameraRules.turnsAtOnce(
	speed: number,
	moving: boolean,
	raised: boolean,
	view: View,
	swimming: boolean,
	climbing: boolean,
	flying: boolean
): boolean
	return moving or speed > CAMERA.IdleTurnSpeed or raised or view ~= "third" or swimming or climbing or flying
end

--[[
	The body's yaw a frame of `dt` on, turning to `aim` (radians), and its velocity: at once when
	`instant`, else SmoothCD over Config.Camera.IdleTurnSeconds, never more than IdleTurnMaxLag
	behind. Returns a yaw within (-pi, pi].
]]
function CameraRules.followYaw(body: number, aim: number, vel: number, dt: number, instant: boolean): (number, number)
	if instant then
		return wrap(aim), 0
	end
	local target = body + wrap(aim - body)
	local yaw, yawVel = smoothCD(body, target, vel, CAMERA.IdleTurnSeconds, dt)
	local maxLag = math.rad(CAMERA.IdleTurnMaxLag)
	local behind = wrap(aim - yaw)
	if behind > maxLag then
		yaw = aim - maxLag
	elseif behind < -maxLag then
		yaw = aim + maxLag
	end
	return wrap(yaw), yawVel
end

--[[ Field of view ]]

--[[
	DayZ's eye focus: the field of view (degrees) while the Focus key is `held`: FocusFov, or
	FocusSprintFov `sprinting`, never wider than `base` (the FOV setting's); `base` when not held or
	while `raised` (the sights have their own zoom).
]]
function CameraRules.focusFov(base: number, sprinting: boolean, held: boolean, raised: boolean): number
	if not held or raised then
		return base
	end
	return math.min(base, if sprinting then CAMERA.FocusSprintFov else CAMERA.FocusFov)
end

return CameraRules

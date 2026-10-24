--!strict
--[[
	A turret's gun as the client draws it (Shared/Turrets), and the rules of drawing it. Plain
	numbers only (no Roblox APIs), so the tests check it; Rendering/TurretView turns the boxes into
	pooled parts and moves them.

	The base is the block itself (Rendering/BlockDecor "<Tier><Type>Turret": the housing, the
	tier's bands, the belt intake, the turntable's ring painted on top). Over its top, turning about
	the pivot (Shared/Turrets/TurretRules.pivot: 0.82 block over the top, the block's centre):
	  base frame (turns with the yaw only)
	    turntable  a steel plate on the block's top
	    post       the mount up from the turntable to the gun's trunnions
	  gun frame (the yaw and the pitch)
	    receiver   the body, in the block's steel
	    barrel     the type's: an SMG's short and thick, a rifle's long, a sniper's longest; its
	               bore through the pivot along the aim, its end (the muzzle) exactly Spec.barrel
	               from the pivot (TurretRules.muzzle: where the server's shots start)
	    tip        a flash hider (SMG, rifle) or a muzzle brake (sniper); with a suppressor of
	               either kind (Protocol.TurretFlag.Suppressor) its can in the tip's place, the
	               can's front the muzzle
	    feeder     the belt feeder's box on the receiver's left, the belt's stub of brass rounds
	               on its left
	    tier       bands round the receiver in the tier's colour (Transmitters/Tiers): one at
	               Basic, two from Advanced; a heat shroud on the barrel from Elite; the targeting
	               module's glowing eye at Ultimate
	    laser      a Laser Sight's emitter under the receiver's front (TurretFlag.Laser): the beam
	               (Rendering/TurretView) starts at its front and runs along the aim
	    scope      a Rifle Scope's tube on top (TurretFlag.Scope; the types that take one)
	At most MAX_PARTS boxes (an Ultimate sniper with all three mounted has 13), plus the beam. Held
	level the gun stays under the top of the cell above (the scope's top 0.005 under it); at every
	yaw and pitch within its type's limits (Spec `pitchMin`, Config.Turrets.Types: the lowest
	whole degree that holds for every tier and mount, never under PitchMin) no box goes into the
	turret's own block: a sniper's can is the nearest, a degree under its -51 it would; the SMG's
	and the rifle's clear it at PitchMin, -60 (the rifle's can would go in at -69.4).

	Frames. Every box is given in its frame's axes, in blocks from the pivot: `right`, `up` and
	`forward` (along the aim). At yaw, pitch (TurretRules' angles: yaw 0 faces +Z, growing towards
	+X; the pitch up from level) the gun frame's axes are (`basis`)
	  forward  (sin yaw cos pitch, sin pitch, cos yaw cos pitch)   TurretRules.direction
	  up       (-sin yaw sin pitch, cos pitch, -cos yaw sin pitch)
	  right    (-cos yaw, 0, sin yaw)                              right x up = back
	and the base frame's are the same at pitch 0. `place` gives each box's centre (world blocks)
	and its rotation as the twelve numbers of CFrame.new(x, y, z, R00 .. R22): the columns right,
	up and back (-forward), so a part's LookVector is the aim and its Size is (across, up, along).
	No part is turned half a turn (an earlier bug held guns backwards) and no Model pivot is used
	(Model.WorldPivot is ignored once a model has a PrimaryPart: a model's pivot is
	PrimaryPart.CFrame * PivotOffset): the parts are placed one by one.

	The view's rules (pure, so the specs check them; Rendering/TurretView keeps the turrets):
	  want     where a drawn gun turns to: at the target the client draws (Entities/MobRenderer
	           .aimPoint: its body's centre, a scoped sniper's head: Shared/Turrets.optic), within
	           its type's pitch limits (TurretRules.pitchLimits), while the record says it tracks
	           it with power; else the record's
	           yaw and pitch while it tracks one the client does not draw, or has no power (it
	           holds still); idle, the record's yaw held and the pitch back to level, as the server
	           eases it (nothing is sent for that); without a record yaw 0, level (Protocol: a
	           turret without one is idle)
	  step     the drawn aim a frame later: TurretRules.turn at the Spec's turn rate (each axis,
	           the short way round across +-pi, never past)
	  idle     a record that says nothing: what a turret without one is
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Items = require(Shared.Items)
local Protocol = require(Shared.Net.Protocol)
local Tiers = require(Shared.Transmitters.Tiers)
local Turrets = require(Shared.Turrets)
local TurretRules = require(Shared.Turrets.TurretRules)

type Spec = Turrets.Spec

export type Frame = "base" | "gun"
export type Material = "metal" | "plastic" | "neon"

-- One box: its name, frame, look, size (across, up, along) and centre (right, up, forward), blocks.
export type Box = {
	name: string,
	frame: Frame,
	material: Material,
	colour: { number },
	size: { number },
	offset: { number },
}

-- What a turret looks like with what is mounted on it (`look`, shared and frozen): its boxes, how
-- far forward its muzzle is, where the laser's beam starts (nil: no Laser Sight), and the look's
-- key (type, tier and what is mounted).
export type Look = {
	key: number,
	spec: Spec,
	boxes: { Box },
	muzzle: number,
	laser: { number }?,
	scope: boolean,
	suppressor: boolean,
}

local TurretModel = {}

-- Boxes a turret's gun has at most (the beam not counted).
TurretModel.MAX_PARTS = 14
-- Numbers `place` writes for each box.
TurretModel.STRIDE = 12

local Flag = Protocol.TurretFlag
-- The flags that change the look.
local LOOK_FLAGS = Flag.Laser + Flag.Scope + Flag.Suppressor

--[[ Colours ]]

local STEEL = table.freeze({ 112, 116, 124 })
local RING = table.freeze({ 96, 100, 108 })
local POST = table.freeze({ 58, 60, 66 })
local BARREL = table.freeze({ 44, 46, 50 })
local TIP = table.freeze({ 36, 36, 40 })
local CAN = table.freeze({ 30, 30, 32 })
local FEEDER = table.freeze({ 66, 68, 60 })
local BRASS = table.freeze({ 196, 160, 70 })
local SHROUD = table.freeze({ 54, 56, 60 })
local EMITTER = table.freeze({ 26, 26, 28 })
local SCOPE = table.freeze({ 28, 28, 30 })
-- The laser's beam (TurretView draws it).
TurretModel.BEAM_COLOUR = table.freeze({ 255, 36, 36 })

--[[ Sizes (blocks) ]]

-- The turntable and the post (base frame).
local TABLE_SIZE, TABLE_HEIGHT = 0.62, 0.06
local POST_SIZE = 0.12
-- The block's top under the pivot, and how far over it the turntable sits (no face shared).
local TOP = -TurretRules.PIVOT + 1
local LIFT = 0.004

-- Each type's receiver (across, up, along; its centre forward of the pivot), barrel (across) and
-- tip (across, up, along), and its suppressor's can (across, along).
type Build = {
	receiver: { number },
	centre: number,
	bore: number,
	tip: { number },
	can: { number },
}
local BUILDS: { [string]: Build } = {
	smg = { receiver = { 0.26, 0.22, 0.4 }, centre = 0.02, bore = 0.1, tip = { 0.13, 0.13, 0.07 }, can = { 0.16, 0.3 } },
	rifle = {
		receiver = { 0.24, 0.2, 0.44 },
		centre = 0.02,
		bore = 0.07,
		tip = { 0.1, 0.1, 0.09 },
		can = { 0.14, 0.32 },
	},
	sniper = {
		receiver = { 0.22, 0.2, 0.48 },
		centre = 0.02,
		bore = 0.06,
		tip = { 0.13, 0.09, 0.11 },
		can = { 0.13, 0.34 },
	},
}
-- The feeder's box (across, up, along) and the belt's stub.
local FEEDER_SIZE = { 0.1, 0.14, 0.18 }
local BELT_SIZE = { 0.03, 0.1, 0.1 }
-- A band round the receiver: how much wider, and along.
local BAND_OVER, BAND_ALONG, BAND_IN = 0.03, 0.04, 0.06
-- The shroud: wider than the bore by, along.
local SHROUD_OVER, SHROUD_ALONG = 0.05, 0.22
-- The emitter (across, up, along) under the receiver's front, its centre this far under the
-- receiver's bottom (its top a little inside).
local EMITTER_SIZE = { 0.06, 0.06, 0.16 }
local EMITTER_DROP = 0.025
-- The scope's tube (across, up, along), forward of the pivot.
local SCOPE_SIZE = { 0.08, 0.08, 0.34 }
local SCOPE_CENTRE = -0.02
-- How far a part reaches into the next so no two faces lie in one plane.
local INSIDE = 0.01

local function box(
	name: string,
	frame: Frame,
	material: Material,
	colour: { number },
	size: { number },
	offset: { number }
): Box
	return table.freeze({
		name = name,
		frame = frame,
		material = material,
		colour = colour,
		size = table.freeze(size),
		offset = table.freeze(offset),
	})
end

local RIFLE_SCOPE = Items.id.RifleScope

-- Does `spec` take a Rifle Scope (so the Scope flag is its)?
local function takesScope(spec: Spec): boolean
	return spec.optics[RIFLE_SCOPE] == true
end

-- The boxes of `spec` with a laser, a scope and a suppressor mounted or not.
local function build(spec: Spec, laser: boolean, scope: boolean, suppressor: boolean): Look
	local shape = BUILDS[spec.type]
	assert(shape, `TurretModel: no build for {spec.type}`)
	local w, h, l = shape.receiver[1], shape.receiver[2], shape.receiver[3]
	local front, rear = shape.centre + l / 2, shape.centre - l / 2
	local muzzle = spec.barrel
	local tierColour = Tiers.TIERS[spec.tier].colour
	local boxes: { Box } = {}
	local function add(made: Box)
		table.insert(boxes, made)
	end
	-- The base frame: the turntable on the block's top, the post up to the receiver.
	local tableUp = TOP + LIFT + TABLE_HEIGHT / 2
	add(box("Turntable", "base", "metal", RING, { TABLE_SIZE, TABLE_HEIGHT, TABLE_SIZE }, { 0, tableUp, 0 }))
	local postBottom, postTop = tableUp + TABLE_HEIGHT / 2 - INSIDE, -h / 2 + INSIDE
	add(
		box(
			"Post",
			"base",
			"metal",
			POST,
			{ POST_SIZE, postTop - postBottom, POST_SIZE },
			{ 0, (postBottom + postTop) / 2, 0 }
		)
	)
	-- The gun: receiver, barrel, the tip or the can.
	add(box("Receiver", "gun", "metal", STEEL, { w, h, l }, { 0, 0, shape.centre }))
	local tipLength = if suppressor then shape.can[2] else shape.tip[3]
	local barrelFrom, barrelTo = front - INSIDE * 2, muzzle - tipLength + INSIDE
	add(
		box(
			"Barrel",
			"gun",
			"metal",
			BARREL,
			{ shape.bore, shape.bore, barrelTo - barrelFrom },
			{ 0, 0, (barrelFrom + barrelTo) / 2 }
		)
	)
	if suppressor then
		local d = shape.can[1]
		add(box("Suppressor", "gun", "plastic", CAN, { d, d, tipLength }, { 0, 0, muzzle - tipLength / 2 }))
	else
		local name = if spec.type == "sniper" then "MuzzleBrake" else "FlashHider"
		add(box(name, "gun", "metal", TIP, { shape.tip[1], shape.tip[2], tipLength }, { 0, 0, muzzle - tipLength / 2 }))
	end
	-- The belt feeder on the left, its belt's stub further left.
	local feederRight = -(w / 2 + FEEDER_SIZE[1] / 2)
	add(box("Feeder", "gun", "metal", FEEDER, table.clone(FEEDER_SIZE), { feederRight, -0.02, shape.centre }))
	add(
		box(
			"Belt",
			"gun",
			"plastic",
			BRASS,
			table.clone(BELT_SIZE),
			{ feederRight - FEEDER_SIZE[1] / 2 - BELT_SIZE[1] / 2, -0.04, shape.centre }
		)
	)
	-- The tier: bands, a shroud, the module's eye.
	local band = { w + BAND_OVER, h + BAND_OVER, BAND_ALONG }
	add(box("Band", "gun", "plastic", tierColour, band, { 0, 0, front - BAND_IN }))
	if spec.tier >= 2 then
		add(box("RearBand", "gun", "plastic", tierColour, table.clone(band), { 0, 0, rear + BAND_IN }))
	end
	if spec.tier >= 3 then
		local across = shape.bore + SHROUD_OVER
		add(
			box(
				"Shroud",
				"gun",
				"metal",
				SHROUD,
				{ across, across, SHROUD_ALONG },
				{ 0, 0, front + SHROUD_ALONG / 2 - INSIDE }
			)
		)
	end
	if spec.tier >= 4 then
		add(box("Eye", "gun", "neon", tierColour, { 0.04, 0.06, 0.06 }, { w / 2 + 0.02 - INSIDE, 0.03, front - 0.12 }))
	end
	-- What is mounted.
	local beam: { number }? = nil
	if laser then
		local up = -(h / 2 + EMITTER_DROP)
		add(box("Laser", "gun", "plastic", EMITTER, table.clone(EMITTER_SIZE), { 0, up, front - EMITTER_SIZE[3] / 2 }))
		beam = table.freeze({ 0, up, front })
	end
	if scope then
		add(
			box(
				"Scope",
				"gun",
				"plastic",
				SCOPE,
				table.clone(SCOPE_SIZE),
				{ 0, h / 2 + SCOPE_SIZE[2] / 2 - INSIDE / 2, SCOPE_CENTRE }
			)
		)
	end
	assert(#boxes <= TurretModel.MAX_PARTS, `TurretModel: {spec.name} has {#boxes} boxes`)
	return table.freeze({
		key = spec.block * 8 + (if laser then 1 else 0) + (if scope then 2 else 0) + (if suppressor then 4 else 0),
		spec = spec,
		boxes = table.freeze(boxes),
		muzzle = muzzle,
		laser = beam,
		scope = scope,
		suppressor = suppressor,
	})
end

-- Every look, by Look `key` (made as this loads: 12 turrets x 8).
local looks: { [number]: Look } = {}
for _, spec in Turrets.SPECS do
	for bits = 0, 7 do
		local laser, scope, suppressor = bits % 2 == 1, (bits // 2) % 2 == 1, bits >= 4
		if not scope or takesScope(spec) then
			local look = build(spec, laser, scope, suppressor)
			looks[look.key] = look
		end
	end
end

-- The flags (Protocol.TurretFlag) that change `spec`'s look, the others cleared (a Scope flag on a
-- type that takes no scope too).
function TurretModel.lookFlags(spec: Spec, flags: number): number
	local bits = bit32.band(flags, LOOK_FLAGS)
	if not takesScope(spec) then
		bits = bit32.band(bits, bit32.bnot(Flag.Scope))
	end
	return bits
end

-- `spec`'s look with what the record's `flags` say is mounted (0: nothing).
function TurretModel.look(spec: Spec, flags: number): Look
	local bits = TurretModel.lookFlags(spec, flags)
	local key = spec.block * 8
		+ (if bit32.btest(bits, Flag.Laser) then 1 else 0)
		+ (if bit32.btest(bits, Flag.Scope) then 2 else 0)
		+ (if bit32.btest(bits, Flag.Suppressor) then 4 else 0)
	return looks[key]
end

--[[ Frames ]]

--[[
	The gun frame's axes at `yaw`, `pitch` (see the header): right, up and forward, three numbers
	each (the base frame's: pitch 0).
]]
function TurretModel.basis(
	yaw: number,
	pitch: number
): (number, number, number, number, number, number, number, number, number)
	local sy, cy = math.sin(yaw), math.cos(yaw)
	local sp, cp = math.sin(pitch), math.cos(pitch)
	return -cy, 0, sy, -sy * sp, cp, -cy * sp, sy * cp, sp, cy * cp
end

-- The point (`right`, `up`, `forward`) of the gun frame (world blocks) of the turret in block
-- (x, y, z) aimed at `yaw`, `pitch`.
function TurretModel.point(
	x: number,
	y: number,
	z: number,
	yaw: number,
	pitch: number,
	right: number,
	up: number,
	forward: number
): (number, number, number)
	local px, py, pz = TurretRules.pivot(x, y, z)
	local rx, ry, rz, ux, uy, uz, fx, fy, fz = TurretModel.basis(yaw, pitch)
	return px + rx * right + ux * up + fx * forward,
		py + ry * right + uy * up + fy * forward,
		pz + rz * right + uz * up + fz * forward
end

-- The drawn muzzle (world blocks) of the turret in block (x, y, z) with `look`, aimed at `yaw`,
-- `pitch`: TurretRules.muzzle with its Spec's barrel.
function TurretModel.muzzle(
	look: Look,
	x: number,
	y: number,
	z: number,
	yaw: number,
	pitch: number
): (number, number, number)
	return TurretModel.point(x, y, z, yaw, pitch, 0, 0, look.muzzle)
end

-- Where the laser's beam starts (world blocks), nil without a Laser Sight.
function TurretModel.laserStart(
	look: Look,
	x: number,
	y: number,
	z: number,
	yaw: number,
	pitch: number
): (number?, number?, number?)
	local start = look.laser
	if start == nil then
		return nil, nil, nil
	end
	return TurretModel.point(x, y, z, yaw, pitch, start[1], start[2], start[3])
end

--[[
	Writes every box of `look` on the turret in block (x, y, z) aimed at `yaw`, `pitch` into `out`
	from index `at` (1 when nil): STRIDE numbers a box, its centre (world blocks) and its rotation
	R00, R01, R02, R10, R11, R12, R20, R21, R22 (CFrame.new's order: the columns right, up, back).
	Returns how many boxes.
]]
function TurretModel.place(
	look: Look,
	x: number,
	y: number,
	z: number,
	yaw: number,
	pitch: number,
	out: { number },
	at: number?
): number
	local px, py, pz = TurretRules.pivot(x, y, z)
	local sy, cy = math.sin(yaw), math.cos(yaw)
	local sp, cp = math.sin(pitch), math.cos(pitch)
	-- Right (both frames), the gun's up and forward, the base's up (0, 1, 0) and forward.
	local rx, rz = -cy, sy
	local ux, uy, uz = -sy * sp, cp, -cy * sp
	local fx, fy, fz = sy * cp, sp, cy * cp
	local i = (at or 1) - 1
	local boxes = look.boxes
	for _, part in boxes do
		local o = part.offset
		local right, up, forward = o[1], o[2], o[3]
		if part.frame == "base" then
			out[i + 1] = px + rx * right + sy * forward
			out[i + 2] = py + up
			out[i + 3] = pz + rz * right + cy * forward
			out[i + 4], out[i + 5], out[i + 6] = rx, 0, -sy
			out[i + 7], out[i + 8], out[i + 9] = 0, 1, 0
			out[i + 10], out[i + 11], out[i + 12] = rz, 0, -cy
		else
			out[i + 1] = px + rx * right + ux * up + fx * forward
			out[i + 2] = py + uy * up + fy * forward
			out[i + 3] = pz + rz * right + uz * up + fz * forward
			out[i + 4], out[i + 5], out[i + 6] = rx, ux, -fx
			out[i + 7], out[i + 8], out[i + 9] = 0, uy, -fy
			out[i + 10], out[i + 11], out[i + 12] = rz, uz, -fz
		end
		i += TurretModel.STRIDE
	end
	return #boxes
end

--[[ The view's rules ]]

-- Does the turret `spec` with the record's `flags` aim at heads (a scoped sniper: Shared/Turrets
-- .optic)?
function TurretModel.aimsAtHead(spec: Spec, flags: number): boolean
	return bit32.btest(TurretModel.lookFlags(spec, flags), Flag.Scope) and Turrets.optic(spec, RIFLE_SCOPE).head
end

-- Does `record` say nothing (what a turret without one is: idle, yaw 0, level, nothing held or
-- mounted)?
function TurretModel.idle(record: Protocol.TurretRecord): boolean
	return record.flags == 0 and record.target == 0 and record.ammo == 0 and record.yaw == 0 and record.pitch == 0
end

--[[
	Where the drawn gun of the turret in block (x, y, z) turns to (see the header): the yaw and pitch.
	`record` is its last (nil: none); (ax, ay, az) where the client draws its target's aim point
	(nil: not drawn); `spec` the turret's, whose pitch limits hold (TurretRules.pitchLimits; nil:
	the lowest any type aims at).
]]
function TurretModel.want(
	record: Protocol.TurretRecord?,
	x: number,
	y: number,
	z: number,
	ax: number?,
	ay: number?,
	az: number?,
	spec: Spec?
): (number, number)
	if record == nil then
		return 0, 0
	end
	local powered = bit32.btest(record.flags, Flag.Powered)
	if record.target ~= 0 and powered and ax and ay and az then
		local px, py, pz = TurretRules.pivot(x, y, z)
		local yaw, pitch, distance = TurretRules.aim(px, py, pz, ax, ay, az)
		if distance > 0 then
			local low, high = TurretRules.pitchLimits(spec)
			return yaw, math.clamp(pitch, low, high)
		end
	end
	if record.target ~= 0 or not powered or bit32.btest(record.flags, Flag.Tracking) then
		return record.yaw, record.pitch
	end
	return record.yaw, 0
end

-- The drawn aim of `spec` `dt` seconds later, turning from (yaw, pitch) towards (wantYaw,
-- wantPitch) at its turn rate (TurretRules.turn: the yaw back in (-pi, pi]).
function TurretModel.step(
	spec: Spec,
	yaw: number,
	pitch: number,
	wantYaw: number,
	wantPitch: number,
	dt: number
): (number, number)
	local seconds = if dt == dt then math.max(dt, 0) else 0
	return TurretRules.turn(yaw, pitch, wantYaw, wantPitch, math.rad(spec.turn) * seconds)
end

return table.freeze(TurretModel)

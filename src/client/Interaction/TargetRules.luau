--!strict
--[[
	Where the crosshair may aim, now that the camera can look over the shoulder (pure:
	Interaction/BlockInteraction asks, tests/spec/TargetRules checks). Lengths in blocks, the
	targeting ray's direction a unit vector; the camera's ray and the eyes (Player/CameraRig.eyes)
	are given in world blocks.

	  Start   the ray from the camera through the pointer starts where it passes the eyes' plane
	          (`skip`: Player/CameraRules.eyePlaneSkip), so nothing between the camera and the
	          player is aimed at; 0 when the eyes are at or behind the camera (first person, and
	          the camera's own aim before the rig), and a skip under SKIP_EPSILON is none, so a
	          camera at the eyes casts exactly the ray it always did.
	  Sight   over the shoulder the crosshair may only pick what the eyes can see: from the eyes
	          to the point the ray found (a block's face, a mob, or the end of the ray), the first
	          block the same test stops at more than SIGHT_SLACK sooner is what is aimed at, with
	          its own face, along the eyes' ray (`hidden`). A mob whose point the eyes can't see is
	          behind cover. Nothing is checked when the eyes look along the ray itself (`alongRay`:
	          on its line, at or behind its start), so a camera at the eyes aims as before.
	The reach is the caller's (still measured from the body: the server needs no change).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local VoxelRaycast = require(Shared.World.VoxelRaycast)

local CameraRules = require(script.Parent.Parent.Player.CameraRules)

local TargetRules = {}

-- A skip shorter than this (blocks) is rounding: the ray starts at the camera.
TargetRules.SKIP_EPSILON = 1e-6
-- The eyes this close (blocks) to the ray's line look along it.
TargetRules.LINE_EPSILON = 1e-3
-- A block the eyes reach this much (blocks) sooner than the ray's point hides it.
TargetRules.SIGHT_SLACK = 1e-3

--[[
	How far (blocks) the targeting ray from the camera (cx, cy, cz) along the unit (dx, dy, dz)
	moves its start, to the plane of the eyes (ex, ey, ez): CameraRules.eyePlaneSkip, 0 under
	SKIP_EPSILON.
]]
function TargetRules.skip(
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
	local skip = CameraRules.eyePlaneSkip(cx, cy, cz, dx, dy, dz, ex, ey, ez)
	return if skip < TargetRules.SKIP_EPSILON then 0 else skip
end

--[[
	Do the eyes (ex, ey, ez) look along the ray from (sx, sy, sz) along the unit (dx, dy, dz): on
	its line (within LINE_EPSILON) and not ahead of its start? Then they see whatever it hits.
]]
function TargetRules.alongRay(
	sx: number,
	sy: number,
	sz: number,
	dx: number,
	dy: number,
	dz: number,
	ex: number,
	ey: number,
	ez: number
): boolean
	local ox, oy, oz = ex - sx, ey - sy, ez - sz
	local ahead = ox * dx + oy * dy + oz * dz
	if ahead > TargetRules.LINE_EPSILON then
		return false
	end
	local px, py, pz = ox - dx * ahead, oy - dy * ahead, oz - dz * ahead
	return px * px + py * py + pz * pz <= TargetRules.LINE_EPSILON * TargetRules.LINE_EPSILON
end

--[[
	The block that hides the point `t` along the ray from (sx, sy, sz) along the unit (dx, dy, dz)
	from the eyes (ex, ey, ez): the first block `isTarget` stops (VoxelRaycast's `getBlock` and
	`outline`) on the way from the eyes to the point, more than SIGHT_SLACK before it, as
	VoxelRaycast.cast reports it from the eyes (its face, its distance along the eyes' ray); and
	the eyes' ray's unit direction (0, 0, 0 when unchecked). nil when the eyes see the point, or
	look along the ray (`alongRay`). Casts once when the eyes see it, twice when they don't.
]]
function TargetRules.hidden(
	sx: number,
	sy: number,
	sz: number,
	dx: number,
	dy: number,
	dz: number,
	t: number,
	ex: number,
	ey: number,
	ez: number,
	getBlock: (x: number, y: number, z: number) -> number?,
	isTarget: (id: number) -> boolean,
	outline: ((id: number, x: number, y: number, z: number) -> { number }?)?
): (VoxelRaycast.Hit?, number, number, number)
	if TargetRules.alongRay(sx, sy, sz, dx, dy, dz, ex, ey, ez) then
		return nil, 0, 0, 0
	end
	local ux, uy, uz = sx + dx * t - ex, sy + dy * t - ey, sz + dz * t - ez
	local length = math.sqrt(ux * ux + uy * uy + uz * uz)
	if length < TargetRules.LINE_EPSILON then
		return nil, 0, 0, 0
	end
	ux, uy, uz = ux / length, uy / length, uz / length
	local seen = VoxelRaycast.distance(ex, ey, ez, ux, uy, uz, length, getBlock, isTarget, outline)
	if seen == nil or seen >= length - TargetRules.SIGHT_SLACK then
		return nil, ux, uy, uz
	end
	return VoxelRaycast.cast(ex, ey, ez, ux, uy, uz, length, getBlock, isTarget, outline), ux, uy, uz
end

return TargetRules

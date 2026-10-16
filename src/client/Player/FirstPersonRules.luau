--!strict
--[[
	The rules of the local body seen in true first person (pure: numbers and names in, numbers out;
	Player/FirstPersonBody and Player/HeldItems draw what they say, tests/spec/FirstPerson checks
	them). Studs and the camera's space (x right, y up, ahead negative), radians unless named.

	  Roles      `roleOf` sorts what a character is drawn with: the head ("head": the Head and what
	             is on it, the face; and what is on the root part, ROOT_PART, as a burning
	             player's Fire, kept out of the eyes), what is worn on it ("headWorn": an Accessory joined to the
	             Head by its weld, or whose handle's attachment is one of the Head's (Hat, Hair,
	             FaceFront, FaceCenter), or whose AccessoryType is worn on the head or the neck:
	             rigid accessories, welded, and layered ones (WrapLayer), sorted by type or
	             attachment alike), the arms ("arm": the upper and lower arms and hands, and
	             accessories joined to them) and the rest ("body": the torso, the legs, back,
	             waist, front and shoulder accessories, layered clothing).
	  Hidden     `hidden`: third person hides only what is near the camera; first person and the
	             sights also hide the head and what is worn on it, and a scope's view the arms
	             (DayZ's HideClothing); First-Person Body off hides everything (Minecraft's hand
	             instead). Near: where the camera's near plane would cut a part in view (`clips`:
	             the near plane's distance and CLIP_MARGIN, CAMERA_SLACK more for what the view bob
	             and the sway still move, within the view's edges): a camera in the head, a tall
	             body's chest under a camera looking down; never a part beside or behind the camera
	             out of view. An arm is one piece (`armSide`): near when any of it is, so a hand is
	             never drawn without its arm.
	  Arms       `twoBone`: the elbow of a two-bone arm (upper `a`, lower `b`) reaching from the
	             shoulder to a wrist target, bent towards a pole point; out of reach it goes
	             straight towards the target, and says where the wrist got. `POLE`: the elbow down,
	             out and back from the shoulder (and POLE_AWAY from the camera). `leftHand`: which
	             holds put the left hand on the item (a long gun's fore end, a melee guard's
	             handle). `slide`: how far a target moves along a line to come in reach (a gun
	             along the view towards the eyes, its sight line kept, until the right wrist is
	             within COMFORT of the arm's reach, its grip GRIP_CLEAR past the near plane; a long
	             gun's left hand back along the barrel, at least FORE_MIN ahead of the right).
	  Poses      `handPose`: where the right hand holds a tool, a block (or any other item) or a
	             bare fist in the camera's space (the grip's frame: looking where the fingers
	             point, up the thumb), with the swing's dip (Player/HeldItems.swing: sin(pi t)),
	             a melee guard and a heavy wind-up (Player/AimRules.meleeView's shifts). Firearms
	             keep Player/AimRules' hip and sights frames (ItemModels.firearmPivot).
	  Walls      `obstruction`: an item reaching into a block is pulled back (up to PULL studs),
	             then its far end lifted (up to LIFT): DayZ's weapon lift.
]]

local AimRules = require(script.Parent.AimRules)

export type Role = "head" | "headWorn" | "arm" | "body"
export type View = "third" | "first" | "sights"
export type HandKind = "tool" | "block" | "empty"

--[[
	An Accessory as `roleOf` sees it: its AccessoryType's name (nil: none, an old Hat), the body
	part its handle is joined to (by its weld or rigid constraint; nil: not joined yet) and the
	names of the attachments in its handle.
]]
export type AccessoryInfo = {
	kind: string?,
	joinedTo: string?,
	attachments: { string }?,
}

local FirstPersonRules = {}

-- The arms' parts (R15, then R6's).
FirstPersonRules.ARM_PARTS = table.freeze({
	LeftUpperArm = true,
	LeftLowerArm = true,
	LeftHand = true,
	RightUpperArm = true,
	RightLowerArm = true,
	RightHand = true,
	["Left Arm"] = true,
	["Right Arm"] = true,
} :: { [string]: boolean })
-- AccessoryTypes worn on the head or at the neck, under the camera (Roblox's Enum.AccessoryType).
FirstPersonRules.HEAD_KINDS = table.freeze({
	Hat = true,
	Hair = true,
	Face = true,
	Eyebrow = true,
	Eyelash = true,
	Neck = true,
} :: { [string]: boolean })
-- The body part effects on the root are in (a burning player's Fire): drawn like the head.
FirstPersonRules.ROOT_PART = "HumanoidRootPart"
-- The elbow's pole from the shoulder, in the torso's axes (studs: out to the arm's side, up, ahead),
-- and how much more the elbow leans away from the camera (`pose`'s share of the camera's side).
FirstPersonRules.POLE = table.freeze({ 0.5, -1, -0.3 })
FirstPersonRules.POLE_AWAY = 1
-- The arms and a held gun are hidden where the camera's near plane would cut them in view
-- (`clips`): within this far past it (studs), the view's edges taken this much wider.
FirstPersonRules.CLIP_MARGIN = 0.05
FirstPersonRules.CLIP_WIDEN = 1.1
-- What is decided before the view bob and the sway still move the camera (Player/
-- FirstPersonBody's Camera + 2; the arms are settled again after them) takes this much more depth.
FirstPersonRules.CAMERA_SLACK = 0.1
-- A gun held from the eyes slides along the view towards them until the right wrist is within this
-- share of the arm's reach (`slide`; the sight line stays on the view's axis), its grip at least
-- GRIP_CLEAR studs past the near plane's margin; a long gun's left hand slides back along the
-- barrel until in reach, at least FORE_MIN studs ahead of the right (else the animation has it).
FirstPersonRules.COMFORT = 0.95
FirstPersonRules.GRIP_CLEAR = 0.45
FirstPersonRules.FORE_MIN = 0.3
-- An item reaching into a wall: pulled back up to this far (studs), then lifted up to LIFT over
-- LIFT_SPAN more studs of overlap.
FirstPersonRules.PULL = 0.8
FirstPersonRules.LIFT = math.rad(60)
FirstPersonRules.LIFT_SPAN = 0.6
-- How far past the grip a tool and a block (or other item) reach ahead (studs), for the wall.
FirstPersonRules.TOOL_REACH = 1.2
FirstPersonRules.BLOCK_REACH = 0.9

--[[
	The right hand's grips (camera space; studs, then degrees: pitch, yaw, roll), at rest and the
	change at the bottom of a swing (dip 1). A tool rises from the bottom right towards the middle,
	leaning left, tipped away and turned to show its face, and chops forward and down; a block
	sits low on the right, turned to show two sides, and dips towards the middle. Its head and its
	corners stay off the crosshair at 70 degrees of field of view (a 1.8 stud tool, a 1.2 stud
	block: ItemModels.handSize). A bare fist punches from low at the side to ahead of the
	middle.
]]
local TOOL = { x = 1.0, y = -0.95, z = -1.5, pitch = -35, yaw = -15, roll = 20 }
local TOOL_DIP = { x = -0.25, y = -0.1, z = 0, pitch = -55 }
local BLOCK = { x = 1.13, y = -0.83, z = -1.73, pitch = -15, yaw = 40, roll = 5 }
local BLOCK_DIP = { x = -0.25, y = -0.15, z = 0, pitch = -40 }
local PUNCH_FROM = { x = 0.5, y = -0.9, z = -0.8 }
local PUNCH_TO = { x = 0.15, y = -0.35, z = -1.6, yaw = 10 }

local EPSILON = 1e-6

--[[ Roles and hiding ]]

-- Is `name` one of the head's own attachments that accessories go on (not its rig attachment)?
local function headPlace(name: string, headAttachments: { [string]: boolean }): boolean
	return headAttachments[name] == true and string.sub(name, -13) ~= "RigAttachment"
end

--[[
	What an object of a character is (see the header): `partName` the body part it is drawn with
	(itself, or the part a decal or effect is on; for an accessory, its handle), `accessory` the
	Accessory it is in (nil: none), `headAttachments` the names of the Head's attachments.
]]
function FirstPersonRules.roleOf(
	partName: string,
	accessory: AccessoryInfo?,
	headAttachments: { [string]: boolean }
): Role
	if accessory == nil then
		if partName == "Head" or partName == FirstPersonRules.ROOT_PART then
			return "head"
		elseif FirstPersonRules.ARM_PARTS[partName] then
			return "arm"
		end
		return "body"
	end
	local joined = accessory.joinedTo
	if joined == "Head" then
		return "headWorn"
	end
	local names = accessory.attachments
	if names then
		for _, name in names do
			if headPlace(name, headAttachments) then
				return "headWorn"
			end
		end
	end
	local kind = accessory.kind
	if kind and FirstPersonRules.HEAD_KINDS[kind] then
		return "headWorn"
	end
	if joined and FirstPersonRules.ARM_PARTS[joined] then
		return "arm"
	end
	return "body"
end

--[[
	Is an object of `role` hidden in `view`, with First-Person Body `bodyOn` (and an R15 body), a
	scope's view (`scoped`) and its part `near` the camera (cut by the near plane in view:
	`clips`; for an arm, any of its side)? See the header.
]]
function FirstPersonRules.hidden(role: Role, view: View, bodyOn: boolean, scoped: boolean, near: boolean): boolean
	if view == "third" then
		return near
	elseif not bodyOn then
		return true
	elseif role == "head" or role == "headWorn" then
		return true
	elseif role == "arm" then
		return scoped or near
	end
	return near
end

--[[
	Does `hidden` need to know whether the part is near the camera (it does in third person, and
	for the arms and the body in first person with the body on, unless a scope hides the arms)?
	The near test is skipped otherwise.
]]
function FirstPersonRules.needsNear(role: Role, view: View, bodyOn: boolean, scoped: boolean): boolean
	if view == "third" then
		return true
	elseif not bodyOn or role == "head" or role == "headWorn" then
		return false
	end
	return not (role == "arm" and scoped)
end

--[[
	Which arm a body part (or the part an accessory is joined to) is of: 1 the right, -1 the left, 0
	none. An arm is shown or hidden whole (`hidden`'s `near` for an arm is its side's: a hand is
	never drawn without its arm).
]]
function FirstPersonRules.armSide(partName: string?): number
	if partName == nil or not FirstPersonRules.ARM_PARTS[partName] then
		return 0
	end
	return if string.sub(partName, 1, 5) == "Right" then 1 else -1
end

-- Is the interval [lo, hi] apart from the box's projection on the axis (nx, ny, nz)?
local function apart(
	nx: number,
	ny: number,
	nz: number,
	cx: number,
	cy: number,
	cz: number,
	ux: number,
	uy: number,
	uz: number,
	vx: number,
	vy: number,
	vz: number,
	wx: number,
	wy: number,
	wz: number,
	lo: number,
	hi: number
): boolean
	local centre = cx * nx + cy * ny + cz * nz
	local radius = math.abs(ux * nx + uy * ny + uz * nz)
		+ math.abs(vx * nx + vy * ny + vz * nz)
		+ math.abs(wx * nx + wy * ny + wz * nz)
	return centre - radius > hi or centre + radius < lo
end

-- The near view's projection on the axis (nx, ny, nz): its apex at the camera and its far corners
-- (+-tx depth, +-ty depth, -depth).
local function nearSpan(nx: number, ny: number, nz: number, depth: number, tx: number, ty: number): (number, number)
	local middle = -depth * nz
	local spread = depth * (tx * math.abs(nx) + ty * math.abs(ny))
	return math.min(0, middle - spread), math.max(0, middle + spread)
end

--[[
	Would the camera's near plane cut a box where the view sees it? The box in the camera's space
	(x right, y up, looking down -z): its centre (cx, cy, cz) and its half axes u, v, w (each its
	half size along one of its own axes). The near view: the view's first `depth` studs (the near
	plane's distance and CLIP_MARGIN), within its edges (tx, ty: the tangents of half the field of
	view across and up, CLIP_WIDEN wider). Separating axes (the box's three faces, the near view's
	five, and across each pair of their edges): exact, so a box beside or behind the camera
	outside the view doesn't count.
]]
function FirstPersonRules.clips(
	cx: number,
	cy: number,
	cz: number,
	ux: number,
	uy: number,
	uz: number,
	vx: number,
	vy: number,
	vz: number,
	wx: number,
	wy: number,
	wz: number,
	depth: number,
	tx: number,
	ty: number
): boolean
	-- The near view's faces: its far end (and the camera's plane), then its four sides.
	local lo, hi = -depth, 0
	if apart(0, 0, 1, cx, cy, cz, ux, uy, uz, vx, vy, vz, wx, wy, wz, lo, hi) then
		return false
	end
	for i = 1, 4 do
		local nx = if i == 1 then 1 elseif i == 2 then -1 else 0
		local ny = if i == 3 then 1 elseif i == 4 then -1 else 0
		local nz = if i <= 2 then tx else ty
		lo, hi = nearSpan(nx, ny, nz, depth, tx, ty)
		if apart(nx, ny, nz, cx, cy, cz, ux, uy, uz, vx, vy, vz, wx, wy, wz, lo, hi) then
			return false
		end
	end
	for i = 1, 3 do
		local ex = if i == 1 then ux elseif i == 2 then vx else wx
		local ey = if i == 1 then uy elseif i == 2 then vy else wy
		local ez = if i == 1 then uz elseif i == 2 then vz else wz
		-- The box's own face, then across each of its edges and each of the near view's (its four
		-- sides' from the camera, its far end's two).
		lo, hi = nearSpan(ex, ey, ez, depth, tx, ty)
		if apart(ex, ey, ez, cx, cy, cz, ux, uy, uz, vx, vy, vz, wx, wy, wz, lo, hi) then
			return false
		end
		for j = 1, 6 do
			local fx = if j == 5 then 1 elseif j == 6 then 0 elseif j % 2 == 1 then tx else -tx
			local fy = if j == 5 then 0 elseif j == 6 then 1 elseif j <= 2 then ty else -ty
			local fz = if j >= 5 then 0 else -1
			local nx, ny, nz = ey * fz - ez * fy, ez * fx - ex * fz, ex * fy - ey * fx
			if nx * nx + ny * ny + nz * nz > EPSILON then
				lo, hi = nearSpan(nx, ny, nz, depth, tx, ty)
				if apart(nx, ny, nz, cx, cy, cz, ux, uy, uz, vx, vy, vz, wx, wy, wz, lo, hi) then
					return false
				end
			end
		end
	end
	return true
end

--[[
	How far (studs) a target at W (wx, wy, wz) moves along the unit direction (dx, dy, dz) to come
	within `reach` of S (sx, sy, sz): the least t in [0, limit] that does (0: within already); nil
	when none does. A gun sliding towards the eyes until the right wrist is in reach, a long gun's
	left hand sliding back along the barrel.
]]
function FirstPersonRules.slide(
	sx: number,
	sy: number,
	sz: number,
	wx: number,
	wy: number,
	wz: number,
	dx: number,
	dy: number,
	dz: number,
	reach: number,
	limit: number
): number?
	local px, py, pz = wx - sx, wy - sy, wz - sz
	local c = px * px + py * py + pz * pz - reach * reach
	if c <= 0 then
		return 0
	end
	local b = px * dx + py * dy + pz * dz
	local disc = b * b - c
	if disc < 0 then
		return nil
	end
	local root = math.sqrt(disc)
	if -b + root < 0 then
		-- (In reach only behind where it starts.)
		return nil
	end
	local t = math.max(-b - root, 0)
	return if t <= limit then t else nil
end

--[[ Arms ]]

--[[
	The elbow of an arm from the shoulder S (sx, sy, sz) to the wrist target W (wx, wy, wz), upper
	length `a`, lower `b`, bent towards the pole point (px, py, pz): the elbow (ex, ey, ez), whether
	the target is reached, and where the wrist goes (rx, ry, rz): W itself, or out of reach the
	point straight towards W the arm gets to (too close: as close as it folds). |E - S| = a and
	|R - E| = b always; a target at the shoulder folds towards the pole (no NaN).
]]
function FirstPersonRules.twoBone(
	sx: number,
	sy: number,
	sz: number,
	wx: number,
	wy: number,
	wz: number,
	px: number,
	py: number,
	pz: number,
	a: number,
	b: number
): (number, number, number, boolean, number, number, number)
	local dx, dy, dz = wx - sx, wy - sy, wz - sz
	local d = math.sqrt(dx * dx + dy * dy + dz * dz)
	-- The pole from the shoulder.
	local qx, qy, qz = px - sx, py - sy, pz - sz
	-- The reach's direction (towards the pole, else down, for a target at the shoulder).
	local ux, uy, uz
	if d > EPSILON then
		ux, uy, uz = dx / d, dy / d, dz / d
	else
		local q = math.sqrt(qx * qx + qy * qy + qz * qz)
		if q > EPSILON then
			ux, uy, uz = qx / q, qy / q, qz / q
		else
			ux, uy, uz = 0, -1, 0
		end
		d = 0
	end
	-- The pole's part across the reach: the side the elbow goes to.
	local along = qx * ux + qy * uy + qz * uz
	local nx, ny, nz = qx - ux * along, qy - uy * along, qz - uz * along
	local n = math.sqrt(nx * nx + ny * ny + nz * nz)
	if n > EPSILON then
		nx, ny, nz = nx / n, ny / n, nz / n
	else
		-- (A pole on the reach's line: any side across it.)
		if math.abs(uy) < 0.9 then
			-- (up x u, normalised)
			nx, ny, nz = uz, 0, -ux
		else
			nx, ny, nz = 0, -uz, uy
		end
		n = math.sqrt(nx * nx + ny * ny + nz * nz)
		nx, ny, nz = nx / n, ny / n, nz / n
	end
	local reach = a + b
	local fold = math.abs(a - b)
	local reached = true
	local c = d
	if c > reach then
		c, reached = reach, false
	elseif c < fold then
		c, reached = fold, false
	end
	local ex, ey, ez
	if c < EPSILON then
		-- (Folded flat on itself at the shoulder: the elbow out towards the pole.)
		ex, ey, ez = sx + ux * a, sy + uy * a, sz + uz * a
	else
		local x = (a * a - b * b + c * c) / (2 * c)
		local h = math.sqrt(math.max(a * a - x * x, 0))
		ex, ey, ez = sx + ux * x + nx * h, sy + uy * x + ny * h, sz + uz * x + nz * h
	end
	return ex, ey, ez, reached, sx + ux * c, sy + uy * c, sz + uz * c
end

--[[
	Does the left hand go on the item (`leftHand`): a long gun's fore end, a melee weapon's handle
	while guarding; otherwise it is left to the animation.
]]
function FirstPersonRules.leftHand(kind: string, long: boolean, guard: boolean): boolean
	if kind == "firearm" then
		return long
	elseif kind == "tool" then
		return guard
	end
	return false
end

--[[ Poses ]]

--[[
	Where the right hand holds an item of `kind` in the camera's space (see the header): its grip
	(x, y, z, studs) and turn (pitch, yaw, roll, radians: CFrame.new(x, y, z) * CFrame.Angles(pitch,
	yaw, roll), the frame looking where the fingers point, up the thumb; for a tool, the handle's
	upright view space at its grip: ItemModels.holdPivot's pose). `dip` is the swing (0..1),
	`guard` a melee guard's eased share (0..1) and `charge` a heavy attack's wind-up (0..1), both
	AimRules.meleeView's shift (a tool only).
]]
function FirstPersonRules.handPose(
	kind: HandKind,
	dip: number,
	guard: number,
	charge: number
): (number, number, number, number, number, number)
	local d = math.clamp(dip, 0, 1)
	if kind == "tool" then
		local sx, sy, sz, roll, tip = AimRules.meleeView(guard, charge)
		return TOOL.x + TOOL_DIP.x * d + sx,
			TOOL.y + TOOL_DIP.y * d + sy,
			TOOL.z + TOOL_DIP.z * d + sz,
			math.rad(TOOL.pitch + TOOL_DIP.pitch * d + tip),
			math.rad(TOOL.yaw),
			math.rad(TOOL.roll + roll)
	elseif kind == "block" then
		return BLOCK.x + BLOCK_DIP.x * d,
			BLOCK.y + BLOCK_DIP.y * d,
			BLOCK.z + BLOCK_DIP.z * d,
			math.rad(BLOCK.pitch + BLOCK_DIP.pitch * d),
			math.rad(BLOCK.yaw),
			math.rad(BLOCK.roll)
	end
	-- A punch: from low at the side to ahead of the middle, turning in.
	return PUNCH_FROM.x + (PUNCH_TO.x - PUNCH_FROM.x) * d,
		PUNCH_FROM.y + (PUNCH_TO.y - PUNCH_FROM.y) * d,
		PUNCH_FROM.z + (PUNCH_TO.z - PUNCH_FROM.z) * d,
		0,
		math.rad(PUNCH_TO.yaw * d),
		0
end

--[[
	An item reaching `depth` studs ahead of the eyes along the view, with `free` studs free before a
	block (math.huge: none): how far to pull it back (studs) and how far to lift its far end
	(radians) — nothing while it fits, then the pull, then the lift.
]]
function FirstPersonRules.obstruction(free: number, depth: number): (number, number)
	if free >= depth then
		return 0, 0
	end
	local over = depth - free
	local pull = math.min(over, FirstPersonRules.PULL)
	local lift = FirstPersonRules.LIFT * math.clamp((over - FirstPersonRules.PULL) / FirstPersonRules.LIFT_SPAN, 0, 1)
	return pull, lift
end

return FirstPersonRules

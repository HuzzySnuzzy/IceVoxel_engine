--!strict
--[[
	The rules of the local body seen in true first person (pure: numbers and names in, numbers out;
	Player/FirstPersonBody and Player/HeldItems draw what they say, tests/spec/FirstPerson checks
	them). Studs and the camera's space (x right, y up, ahead negative), radians unless named.

	  Roles      `roleOf` sorts what a character is drawn with: the head ("head": the Head and what
	             is on it, the face), what is worn on it ("headWorn": an Accessory joined to the
	             Head by its weld, or whose handle's attachment is one of the Head's (Hat, Hair,
	             FaceFront, FaceCenter), or whose AccessoryType is worn on the head or the neck:
	             rigid accessories, welded, and layered ones (WrapLayer), sorted by type or
	             attachment alike), the arms ("arm": the upper and lower arms and hands, and
	             accessories joined to them) and the rest ("body": the torso, the legs, back,
	             waist, front and shoulder accessories, layered clothing).
	  Hidden     `hidden`: third person hides only what is near the camera (`nearBox`: within
	             Config.Camera.NearClear of its box, for the near plane, tall bodies and a camera
	             pulled into the head); first person and the sights also hide the head and what
	             is worn on it, and a scope's view the arms (DayZ's HideClothing); First-Person
	             Body off hides everything (Minecraft's hand instead).
	  Arms       `twoBone`: the elbow of a two-bone arm (upper `a`, lower `b`) reaching from the
	             shoulder to a wrist target, bent towards a pole point; out of reach it goes
	             straight towards the target, and says where the wrist got. `POLE`: the elbow down,
	             out and back from the shoulder. `leftHand`: which holds put the left hand on the
	             item (a long gun's fore end, a melee guard's handle).
	  Poses      `handPose`: where the right hand holds a tool, a block (or any other item) or a
	             bare fist in the camera's space (the grip's frame: looking where the fingers
	             point, up the thumb), with the swing's dip (Player/HeldItems.swing: sin(pi t)),
	             a melee guard and a heavy wind-up (Player/AimRules.meleeView's shifts). Firearms
	             keep Player/AimRules' hip and sights frames (ItemModels.firearmPivot).
	  Walls      `obstruction`: an item reaching into a block is pulled back (up to PULL studs),
	             then its far end lifted (up to LIFT): DayZ's weapon lift.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

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

-- A body part this close to the camera (studs from its box) is hidden, in every view.
FirstPersonRules.NEAR_CLEAR = Config.Camera.NearClear
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
-- The elbow's pole from the shoulder, in the torso's axes (studs: out to the arm's side, up, ahead).
FirstPersonRules.POLE = table.freeze({ 0.5, -1, -0.3 })
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
		if partName == "Head" then
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
	scope's view (`scoped`) and its part `near` the camera (`nearBox`)? See the header.
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
	Is the camera at (cx, cy, cz) within `margin` studs of a box of half sizes (hx, hy, hz) (the
	camera in the box's own space: its centre at the origin)? On the margin counts.
]]
function FirstPersonRules.nearBox(
	cx: number,
	cy: number,
	cz: number,
	hx: number,
	hy: number,
	hz: number,
	margin: number
): boolean
	local dx = math.max(math.abs(cx) - hx, 0)
	local dy = math.max(math.abs(cy) - hy, 0)
	local dz = math.max(math.abs(cz) - hz, 0)
	return dx * dx + dy * dy + dz * dz <= margin * margin
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

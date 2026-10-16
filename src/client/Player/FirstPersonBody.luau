--!strict
--[[
	The local player's body seen in true first person (the First-Person Body setting), in the manner
	of DayZ: the body is drawn, the head and what is worn on it are not, and both hands hold the
	item. Player/FirstPersonRules has the rules and numbers.

	  Visibility  at Camera + 2, after Roblox's camera faded the character (its
	              TransparencyController fades every part while its camera is at the eyes, again on
	              every new part), the one writer of the local character's LocalTransparencyModifier
	              while Player/CameraRig places the camera (`active`) and the player is not a
	              spectator: every object a character is drawn with (SpectatorRules.HIDDEN_CLASSES,
	              listed once and again when the character's descendants change) gets
	              FirstPersonRules.hidden's value for its role (`roleOf`: the head and what is on it
	              or on the root part (a burning player's Fire), what is worn on the head, the arms,
	              the rest) in the rig's view, written only when it differs (the controller's fade is
	              undone the same frame; with the controller held off, a write per change).
	              Third person hides only what the camera's near plane would cut in view
	              (FirstPersonRules.clips: the camera's NearPlaneZ, CLIP_MARGIN and CAMERA_SLACK; a
	              camera pulled into the head, a tall body's chest under a camera looking down);
	              first person and the sights also the head and what is worn on it (rigid and
	              layered accessories alike), and a scope's view the arms; First-Person Body off (or
	              an R6 body) hides it all, for Minecraft's hand (Player/HeldItems' first-person
	              view). An arm (its upper and lower arm, its hand and what is joined to them) is
	              shown or hidden whole: hidden where the near plane would cut any of it in view, so
	              a hand is never drawn without its arm. A dead body
	              is drawn as in third person while it tips over (the camera holds it).
	              Player/SpectatorView (Camera + 3) raises what this wrote for spectating and a body
	              gone after death; spectators and a player spectating someone (the rig inactive)
	              are left to it and to Roblox's camera, everything this hid given back first.
	              `hides(part)` and `hidesHeadWorn()` tell Player/EquipmentLooks which drawn pieces
	              go with them. In true first person the arms are settled again at Camera + 7
	              (`settleArms`, Player/HeldItems), where they were just posed, with the final camera
	              (the bob, the sway) and this frame's scope: a scope hides the arms in the frame it
	              hides the gun.
	  Held item   Player/HeldItems places the world model of what the local player holds in the
	              camera's space (`trueFirstPerson`), pushes what it holds (`setHeld`: the kind, a
	              scope's view, the sights' share) and then puts the hands on it (`poseArms`).
	  Arms        two-bone IK on the R15 shoulders, elbows and wrists (FirstPersonRules.twoBone,
	              the lengths from the joints' own C0 and C1, so scaled bodies work; the elbow
	              down and out, FirstPersonRules.POLE, and away from the camera, POLE_AWAY), written
	              to the Motor6Ds' C0 with the animation's Transform taken out, in the render step
	              that draws the frame: the Animator's Transform read there is the one that frame
	              renders, so the hand lands exactly on the item (IKControl solves in the animation
	              step from targets set a step earlier, a frame behind the camera: the hands would
	              trail the item). The hand turns with the grip so the palm wraps it; a grip out of
	              reach is held where the arm gets to (`reach`: Player/HeldItems moves a tool or a
	              block there). A gun never moves off its sight line: `gripSlide` says how far it
	              slides along the view towards the eyes for the right hand to take it, and
	              `foreHold` where a long gun's left hand takes the fore end (slid back along the
	              barrel towards the right hand until in reach; none: the animation has the arm);
	              `armClips` whether an arm holding a grip would be cut by the near plane (then it
	              lets go instead of being hidden).
	              `release` puts the joints back (Player/WeaponPoses poses them in third person).
	              R6 bodies get no IK.

	Nothing is created per frame (the lists are rebuilt only when the character changes).
	Requires only Player/CameraRig, Player/FirstPersonRules, Player/SpectatorRules and Shared:
	Player/EquipmentLooks requires this, and Player/MovementController requires EquipmentLooks.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)

local CameraRig = require(script.Parent.CameraRig)
local FirstPersonRules = require(script.Parent.FirstPersonRules)
local SpectatorRules = require(script.Parent.SpectatorRules)

-- After Roblox's camera (and its fade) and the rig (Camera + 1), before Player/SpectatorView (+ 3).
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 2
local RENDER_STEP = "IceVoxelFirstPersonBody"
-- The hand's turn from a grip's frame (looking along the fingers, up the thumb): the hand's
-- fingers along its -Y, its thumb side -Z, its palm -X (right hand; +X left).
local HAND_TURN = CFrame.Angles(math.pi / 2, 0, 0)
-- An arm turned by less than this (radians) counts as straight.
local STRAIGHT = 1e-4

--[[
	What the local player holds, as Player/HeldItems draws it (`setHeld`, every frame): the kind of
	grip ("empty": the bare hand; "firearm"; "tool": tools and melee weapons; "block": blocks and
	other items), whether a scope's view hides the gun and the arms (`scoped`), the share of the
	way from the hip to the sights (`sightsShare`, 0..1), a long gun (the left hand on its fore end)
	and a melee guard (the left hand on the handle).
]]
export type HeldKind = "empty" | "firearm" | "tool" | "block"
export type HeldState = {
	kind: HeldKind,
	scoped: boolean,
	sightsShare: number,
	long: boolean?,
	guard: boolean?,
}

local FirstPersonBody = {}

local started = false
local enabled = Config.Camera.FirstPersonBody
local held: HeldState = { kind = "empty", scoped = false, sightsShare = 0 }

--[[ The near plane ]]

--[[
	The camera's near view for FirstPersonRules.clips: how deep it is (the near plane's distance and
	CLIP_MARGIN, studs) and the tangents of its edges (across, up; CLIP_WIDEN wider).
]]
function FirstPersonBody.nearView(camera: Camera): (number, number, number)
	local depth = math.abs(camera.NearPlaneZ) + FirstPersonRules.CLIP_MARGIN
	local ty = math.tan(math.rad(camera.FieldOfView) / 2) * FirstPersonRules.CLIP_WIDEN
	local size = camera.ViewportSize
	local tx = if size.Y > 0 then ty * size.X / size.Y else ty * 2
	return depth, tx, ty
end

--[[
	Would the near plane of a camera at `view` (its near view: `nearView`'s depth and edges) cut a
	box of `size` at `frame` (world) where it sees it?
]]
function FirstPersonBody.clipped(
	view: CFrame,
	frame: CFrame,
	size: Vector3,
	depth: number,
	tx: number,
	ty: number
): boolean
	-- (Its bounding ball first: most boxes are far from the near view, no turn worked out.)
	if (frame.Position - view.Position).Magnitude > depth * math.sqrt(1 + tx * tx + ty * ty) + size.Magnitude / 2 then
		return false
	end
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = view:ToObjectSpace(frame):GetComponents()
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
	return FirstPersonRules.clips(
		x,
		y,
		z,
		r00 * hx,
		r10 * hx,
		r20 * hx,
		r01 * hy,
		r11 * hy,
		r21 * hy,
		r02 * hz,
		r12 * hz,
		r22 * hz,
		depth,
		tx,
		ty
	)
end

--[[ Arms (their joints; the IK is below) ]]

-- A joint of an arm: its Motor6D, its Part0's rig attachment (its own C0, also after the body was
-- scaled) and its C0 as found (without one).
type Joint = { motor: Motor6D, attachment: Attachment?, base: CFrame }

type Arm = {
	shoulder: Joint,
	elbow: Joint,
	wrist: Joint,
	upper: BasePart,
	lower: BasePart,
	hand: BasePart,
	grip: Attachment?,
	-- +1 right, -1 left.
	side: number,
	posed: boolean,
	-- Where the posed parts are (world; while `posed`).
	upperAt: CFrame,
	lowerAt: CFrame,
	handAt: CFrame,
}

type Rig = { character: Model, torso: BasePart, right: Arm, left: Arm }

local rig: Rig? = nil

-- Where `part` is drawn: as the IK posed it this frame, else its own frame.
local function frameOf(part: BasePart): CFrame
	local arms = rig
	if arms then
		for side = 1, 2 do
			local arm = if side == 1 then arms.right else arms.left
			if arm.posed then
				if part == arm.upper then
					return arm.upperAt
				elseif part == arm.lower then
					return arm.lowerAt
				elseif part == arm.hand then
					return arm.handAt
				end
			end
		end
	end
	return part.CFrame
end

--[[ Visibility ]]

-- The local character's objects: each with the part it is drawn with, its role and its arm's side
-- (FirstPersonRules.armSide), and the arms' objects; listed again when `dirty` (a descendant came
-- or went). `r15`: an R15 body (IK, the body drawn).
type Cover = {
	character: Model,
	objects: { Instance },
	parts: { BasePart },
	roles: { FirstPersonRules.Role },
	sides: { number },
	arms: { number },
	r15: boolean,
	dirty: boolean,
	connections: { RBXScriptConnection },
}

local cover: Cover? = nil
-- This module writes the local character's transparency this frame (`drawing`), in this view;
-- whether it is true first person (the body ON, R15, alive, first person or the sights).
local writing = false
local shownView: FirstPersonRules.View = "third"
local shownBody = false
local trueFirstPerson = false
-- The character's parts hidden by this module now (`hides`), written when it changes.
local hiding: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- Whether objects of a class are hidden with their character (SpectatorRules.hidden), by ClassName.
local hiddenClasses: { [string]: boolean } = {}

local function hideable(object: Instance): boolean
	local known = hiddenClasses[object.ClassName]
	if known == nil then
		known = SpectatorRules.hidden(function(class: string): boolean
			return object:IsA(class)
		end)
		hiddenClasses[object.ClassName] = known
	end
	return known == true
end

-- (Every hideable class has a LocalTransparencyModifier; the types know it per class only.)
local function transparencyOf(object: Instance): number
	return (object :: any).LocalTransparencyModifier
end

local function setTransparency(object: Instance, value: number)
	(object :: any).LocalTransparencyModifier = value
end

-- The part an object is drawn with: itself, or the part it is on (a decal, an effect).
local function partOf(object: Instance): BasePart?
	if object:IsA("BasePart") then
		return object
	end
	return object:FindFirstAncestorWhichIsA("BasePart")
end

-- The body part `joint` joins `handle` to (a weld's or a rigid constraint's other side), if any.
local function otherSide(joint: Instance, handle: BasePart): BasePart?
	local a: Instance?, b: Instance? = nil, nil
	if joint:IsA("JointInstance") or joint:IsA("WeldConstraint") then
		local welded = joint :: any
		a, b = welded.Part0, welded.Part1
	elseif joint:IsA("RigidConstraint") then
		local a0, a1 = joint.Attachment0, joint.Attachment1
		a = if a0 then a0.Parent else nil
		b = if a1 then a1.Parent else nil
	else
		return nil
	end
	local other = if a == handle then b else a
	return if other and other:IsA("BasePart") then other else nil
end

-- What FirstPersonRules.roleOf needs of `accessory` (see FirstPersonRules.AccessoryInfo).
local function accessoryInfo(accessory: Accessory): FirstPersonRules.AccessoryInfo
	local info: FirstPersonRules.AccessoryInfo =
		{ kind = accessory.AccessoryType.Name, joinedTo = nil, attachments = {} }
	local handle = accessory:FindFirstChild("Handle")
	if handle and handle:IsA("BasePart") then
		local names = info.attachments :: { string }
		local weld = handle:FindFirstChild("AccessoryWeld")
		local joined = if weld then otherSide(weld, handle) else nil
		for _, child in handle:GetChildren() do
			if child:IsA("Attachment") then
				table.insert(names, child.Name)
			elseif joined == nil then
				joined = otherSide(child, handle)
			end
		end
		info.joinedTo = if joined then joined.Name else nil
	end
	return info
end

-- Lists `character`'s objects again (when its descendants changed).
local function list(made: Cover)
	local character = made.character
	table.clear(made.objects)
	table.clear(made.parts)
	table.clear(made.roles)
	table.clear(made.sides)
	table.clear(made.arms)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	made.r15 = humanoid ~= nil and humanoid.RigType == Enum.HumanoidRigType.R15
	local headAttachments: { [string]: boolean } = {}
	local head = character:FindFirstChild("Head")
	if head then
		for _, child in head:GetChildren() do
			if child:IsA("Attachment") then
				headAttachments[child.Name] = true
			end
		end
	end
	local infos: { [Instance]: FirstPersonRules.AccessoryInfo } = {}
	for _, object in character:GetDescendants() do
		if hideable(object) and object.Name ~= FirstPersonRules.ROOT_PART then
			local part = partOf(object)
			-- (A Tool's parts are its own: Roblox's camera leaves them alone too.)
			if part and part:FindFirstAncestorWhichIsA("Tool") == nil then
				local accessory = part:FindFirstAncestorWhichIsA("Accessory")
				local info: FirstPersonRules.AccessoryInfo? = nil
				if accessory then
					local known = infos[accessory]
					if known == nil then
						known = accessoryInfo(accessory)
						infos[accessory] = known
					end
					info = known
				end
				local role = FirstPersonRules.roleOf(part.Name, info, headAttachments)
				table.insert(made.objects, object)
				table.insert(made.parts, part)
				table.insert(made.roles, role)
				local side = 0
				if role == "arm" then
					side = FirstPersonRules.armSide(if info then info.joinedTo else part.Name)
					table.insert(made.arms, #made.objects)
				end
				table.insert(made.sides, side)
			end
		end
	end
end

-- Lets go of the listed character (its connections).
local function forget()
	local current = cover
	if current then
		for _, connection in current.connections do
			connection:Disconnect()
		end
		cover = nil
	end
end

local function coverOf(character: Model): Cover
	local current = cover
	if current == nil or current.character ~= character then
		forget()
		local made: Cover = {
			character = character,
			objects = {},
			parts = {},
			roles = {},
			sides = {},
			arms = {},
			r15 = false,
			dirty = true,
			connections = {},
		}
		local function changed()
			made.dirty = true
		end
		table.insert(made.connections, character.DescendantAdded:Connect(changed))
		table.insert(made.connections, character.DescendantRemoving:Connect(changed))
		cover = made
		current = made
	end
	assert(current, "cover")
	if current.dirty then
		current.dirty = false
		list(current)
	end
	return current
end

-- Stops writing: what this hid is given back (Roblox's camera and SpectatorView take over).
local function stop()
	trueFirstPerson = false
	if not writing then
		return
	end
	writing = false
	local current = cover
	if current then
		for _, object in current.objects do
			if object.Parent ~= nil and transparencyOf(object) ~= 0 then
				setTransparency(object, 0)
			end
		end
	end
	table.clear(hiding)
end

--[[
	Which arms the near plane of `camera` cuts in view (right, left): any of an arm's objects (its
	parts where they are drawn, `frameOf`; what is joined to them), when the rules need to know.
]]
local function armsNear(
	current: Cover,
	camera: Camera,
	view: FirstPersonRules.View,
	bodyOn: boolean,
	scoped: boolean
): (boolean, boolean)
	if not FirstPersonRules.needsNear("arm", view, bodyOn, scoped) then
		return false, false
	end
	local eye = camera.CFrame
	local depth, tx, ty = FirstPersonBody.nearView(camera)
	local right, left = false, false
	local parts, sides = current.parts, current.sides
	for _, i in current.arms do
		local side = sides[i]
		if (side == 1 and not right) or (side == -1 and not left) then
			local part = parts[i]
			if FirstPersonBody.clipped(eye, frameOf(part), part.Size, depth, tx, ty) then
				if side == 1 then
					right = true
				else
					left = true
				end
			end
		end
	end
	return right, left
end

-- Writes object `i`'s hiding (`hide`), when it differs.
local function show(current: Cover, i: number, hide: boolean)
	local object = current.objects[i]
	local want = if hide then 1 else 0
	if transparencyOf(object) ~= want then
		setTransparency(object, want)
	end
	local part = current.parts[i]
	if object == part and hiding[part] ~= hide then
		hiding[part] = hide
	end
end

local function step()
	local player = Players.LocalPlayer
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local camera = workspace.CurrentCamera
	if
		not CameraRig.active()
		or character == nil
		or humanoid == nil
		or camera == nil
		or GameMode.isSpectator(GameMode.of(player))
	then
		stop()
		if character == nil then
			forget()
		end
		return
	end
	local current = coverOf(character)
	-- (A dead body tips over in view, as in third person.)
	local alive = humanoid.Health > 0 and not CameraRig.holding()
	local view: FirstPersonRules.View = if alive then CameraRig.view() else "third"
	local bodyOn = enabled and current.r15
	trueFirstPerson = alive and bodyOn and view ~= "third"
	shownView = view
	shownBody = bodyOn
	writing = true
	local scoped = trueFirstPerson and held.scoped
	local eye = camera.CFrame
	local rightNear, leftNear = armsNear(current, camera, view, bodyOn, scoped)
	-- (The rest is not settled again at + 7: a little more depth for the view bob and the sway
	-- still to move the camera.)
	local depth, tx, ty = FirstPersonBody.nearView(camera)
	depth += FirstPersonRules.CAMERA_SLACK
	local eyeAt = eye.Position
	local reach = depth * math.sqrt(1 + tx * tx + ty * ty)
	local roles: { FirstPersonRules.Role } = current.roles
	local parts, sides = current.parts, current.sides
	for i in current.objects do
		local role: FirstPersonRules.Role = roles[i]
		local near = false
		if role == "arm" then
			local side = sides[i]
			near = (side == 1 and rightNear) or (side == -1 and leftNear)
		elseif FirstPersonRules.needsNear(role, view, bodyOn, scoped) then
			-- (Its bounding ball first: most parts are far from the camera, no CFrame read.)
			local part = parts[i]
			local size = part.Size
			if (part.Position - eyeAt).Magnitude <= reach + size.Magnitude / 2 then
				near = FirstPersonBody.clipped(eye, part.CFrame, size, depth, tx, ty)
			end
		end
		show(current, i, FirstPersonRules.hidden(role, view, bodyOn, scoped, near))
	end
end

function FirstPersonBody.start()
	if started then
		return
	end
	started = true
	RunService:BindToRenderStep(RENDER_STEP, RENDER_PRIORITY, step)
end

-- The First-Person Body setting (false: Minecraft's hand).
function FirstPersonBody.setEnabled(on: boolean)
	enabled = on
end

-- The First-Person Body setting as last set.
function FirstPersonBody.enabled(): boolean
	return enabled
end

--[[
	Is the local body drawn in true first person now (the rig in first person or the sights, the
	setting ON, an R15 body, alive)? HeldItems then places the world model in camera space instead
	of its first-person view. (Measured at Camera + 2 this frame.)
]]
function FirstPersonBody.trueFirstPerson(): boolean
	return trueFirstPerson
end

-- Does this module write the local character's visibility this frame (the rig active, not a
-- spectator)? Otherwise Roblox's camera fades it (Player/EquipmentLooks then follows the head).
function FirstPersonBody.drawing(): boolean
	return writing
end

--[[
	Is `part` of the local character hidden by this module now (Player/EquipmentLooks hides a piece
	whose anchor part is)?
]]
function FirstPersonBody.hides(part: Instance): boolean
	return writing and hiding[part] == true
end

-- Are things worn on the head (and at the neck) hidden now: first person or the sights?
function FirstPersonBody.hidesHeadWorn(): boolean
	return writing and shownView ~= "third"
end

-- What the local player holds this frame (Player/HeldItems).
function FirstPersonBody.setHeld(state: HeldState)
	held = state
end

-- What the local player holds, as last set.
function FirstPersonBody.held(): HeldState
	return held
end

--[[
	The arms shown or hidden again where Player/HeldItems just posed them (Camera + 7, after
	`setHeld`), in true first person: `camera` as this frame draws it (after the view bob and the
	sway) and this frame's scope, so the arms hide and show in the frame the gun does.
]]
function FirstPersonBody.settleArms(camera: Camera)
	local current = cover
	if current == nil or not (writing and trueFirstPerson) then
		return
	end
	local scoped = held.scoped
	local rightNear, leftNear = armsNear(current, camera, shownView, shownBody, scoped)
	local sides = current.sides
	for _, i in current.arms do
		local side = sides[i]
		local near = (side == 1 and rightNear) or (side == -1 and leftNear)
		show(current, i, FirstPersonRules.hidden("arm", shownView, shownBody, scoped, near))
	end
end

--[[ Arms ]]

-- How far the right hand's grip got from where it was sent (`reach`).
local miss = Vector3.zero

-- The joint `name` in `part1` (R15 keeps an arm's joints in their Part1).
local function jointOf(part1: Instance?, name: string): Joint?
	local motor = if part1 then part1:FindFirstChild(name) else nil
	if motor == nil or not motor:IsA("Motor6D") or motor.Part0 == nil then
		return nil
	end
	local part0 = motor.Part0 :: BasePart
	local found = part0:FindFirstChild(name .. "RigAttachment")
	local attachment = if found and found:IsA("Attachment") then found else nil
	return { motor = motor, attachment = attachment, base = motor.C0 }
end

local function armOf(character: Model, prefix: string, side: number): Arm?
	local upper = character:FindFirstChild(prefix .. "UpperArm")
	local lower = character:FindFirstChild(prefix .. "LowerArm")
	local hand = character:FindFirstChild(prefix .. "Hand")
	if
		hand == nil
		or not hand:IsA("BasePart")
		or upper == nil
		or not upper:IsA("BasePart")
		or lower == nil
		or not lower:IsA("BasePart")
	then
		return nil
	end
	local shoulder = jointOf(upper, prefix .. "Shoulder")
	local elbow = jointOf(lower, prefix .. "Elbow")
	local wrist = jointOf(hand, prefix .. "Wrist")
	if shoulder == nil or elbow == nil or wrist == nil then
		return nil
	end
	local found = hand:FindFirstChild(prefix .. "GripAttachment")
	return {
		shoulder = shoulder,
		elbow = elbow,
		wrist = wrist,
		upper = upper,
		lower = lower,
		hand = hand,
		grip = if found and found:IsA("Attachment") then found else nil,
		side = side,
		posed = false,
		upperAt = CFrame.identity,
		lowerAt = CFrame.identity,
		handAt = CFrame.identity,
	}
end

local function intact(arm: Arm): boolean
	return arm.shoulder.motor.Parent ~= nil and arm.elbow.motor.Parent ~= nil and arm.wrist.motor.Parent ~= nil
end

-- `character`'s arms (R15 only; nil for R6 or a body without its joints).
local function rigOf(character: Model): Rig?
	local current = rig
	if current and current.character == character and intact(current.right) and intact(current.left) then
		return current
	end
	local torso = character:FindFirstChild("UpperTorso")
	local right = armOf(character, "Right", 1)
	local left = armOf(character, "Left", -1)
	if torso == nil or not torso:IsA("BasePart") or right == nil or left == nil then
		rig = nil
		return nil
	end
	local made: Rig = { character = character, torso = torso, right = right, left = left }
	rig = made
	return made
end

-- A joint's own C0 (its rig attachment's frame; as found without one).
local function baseOf(joint: Joint): CFrame
	local attachment = joint.attachment
	if attachment and attachment.Parent ~= nil then
		return attachment.CFrame
	end
	return joint.base
end

local function restore(joint: Joint)
	if joint.motor.Parent ~= nil then
		joint.motor.C0 = baseOf(joint)
	end
end

local function letGo(arm: Arm)
	if not arm.posed then
		return
	end
	arm.posed = false
	restore(arm.shoulder)
	restore(arm.elbow)
	restore(arm.wrist)
end

-- The turn taking the bone's own direction `along` (its part's space) to -Y (identity when it is).
local function boneTurn(along: Vector3): CFrame
	local axis = along:Cross(-Vector3.yAxis)
	local s = axis.Magnitude
	local c = -along.Y
	if s < STRAIGHT then
		return if c > 0 then CFrame.identity else CFrame.Angles(math.pi, 0, 0)
	end
	return CFrame.fromAxisAngle(axis / s, math.atan2(s, c))
end

-- A bone's world frame: from its joint at `from` along `dir` (unit), its hinge axis `hinge`
-- (unit, across `dir`), turned by `turn` (boneTurn) and placed so `joint` (its part's space) is at
-- `from`.
local function boneFrame(from: Vector3, dir: Vector3, hinge: Vector3, turn: CFrame, joint: Vector3): CFrame
	local y = -dir
	local z = hinge:Cross(y)
	return CFrame.fromMatrix(from, hinge, y, z) * turn * CFrame.new(-joint)
end

--[[
	`arm`'s reach for a grip at `target` (world): its shoulder (world), where its wrist goes for the
	hand to hold the grip (world), the hand's turn, the hand's grip point (its own space) and the
	bones' lengths (shoulder to elbow, elbow to wrist).
]]
local function reachOf(arm: Arm, torso: BasePart, target: CFrame): (Vector3, Vector3, CFrame, Vector3, number, number)
	local shoulder, elbow, wrist = arm.shoulder, arm.elbow, arm.wrist
	local upperBone = baseOf(elbow).Position - shoulder.motor.C1.Position
	local lowerBone = baseOf(wrist).Position - elbow.motor.C1.Position
	local handTurn = target.Rotation * HAND_TURN
	local grip = arm.grip
	local gripAt = if grip and grip.Parent ~= nil then grip.Position else Vector3.new(0, -arm.hand.Size.Y / 2, 0)
	local wristAt = target.Position + handTurn:VectorToWorldSpace(wrist.motor.C1.Position - gripAt)
	local s = torso.CFrame * baseOf(shoulder).Position
	return s, wristAt, handTurn, gripAt, upperBone.Magnitude, lowerBone.Magnitude
end

--[[
	The IK for `arm`'s hand on `target` (a grip's world frame), its elbow away from a camera at
	`eye` (nil: down and out only): the upper arm's, the lower arm's and the hand's world frames and
	the hand's grip point (its own space); nil for an arm without bones.
]]
local function solve(arm: Arm, torso: BasePart, target: CFrame, eye: Vector3?): (CFrame?, CFrame, CFrame, Vector3)
	local shoulder, elbow, wrist = arm.shoulder, arm.elbow, arm.wrist
	local elbowC0, wristC0 = baseOf(elbow), baseOf(wrist)
	local shoulderC1, elbowC1, wristC1 = shoulder.motor.C1, elbow.motor.C1, wrist.motor.C1
	-- The bones (each part's space): shoulder to elbow, elbow to wrist.
	local upperBone = elbowC0.Position - shoulderC1.Position
	local lowerBone = wristC0.Position - elbowC1.Position
	local s, wristAt, handTurn, gripAt, a, b = reachOf(arm, torso, target)
	if a < STRAIGHT or b < STRAIGHT then
		return nil, target, target, gripAt
	end
	-- The elbow's pole: down and out (the torso's axes), and away from the camera.
	local poleOffset = FirstPersonRules.POLE
	local p = s + torso.CFrame:VectorToWorldSpace(Vector3.new(poleOffset[1] * arm.side, poleOffset[2], -poleOffset[3]))
	if eye then
		local away = s - eye
		if away.Magnitude > STRAIGHT then
			p += away.Unit * FirstPersonRules.POLE_AWAY
		end
	end
	local ex, ey, ez, _, rx, ry, rz =
		FirstPersonRules.twoBone(s.X, s.Y, s.Z, wristAt.X, wristAt.Y, wristAt.Z, p.X, p.Y, p.Z, a, b)
	local e = Vector3.new(ex, ey, ez)
	local r = Vector3.new(rx, ry, rz)
	local up = (e - s).Unit
	local hinge = up:Cross((r - e).Unit)
	if hinge.Magnitude < STRAIGHT then
		-- (Straight: the hinge across the pole; any axis across the arm on the pole's line.)
		local toPole = p - s
		hinge = (toPole - up * toPole:Dot(up)):Cross(up)
		if hinge.Magnitude < STRAIGHT then
			hinge = Vector3.xAxis:Cross(up)
			if hinge.Magnitude < STRAIGHT then
				hinge = Vector3.zAxis:Cross(up)
			end
		end
	end
	hinge = hinge.Unit
	local upper = boneFrame(s, up, hinge, boneTurn(upperBone.Unit), shoulderC1.Position)
	local elbowAt = upper * elbowC0.Position
	local down = r - elbowAt
	down = if down.Magnitude > STRAIGHT then down.Unit else up
	local lowerHinge = hinge - down * hinge:Dot(down)
	lowerHinge = if lowerHinge.Magnitude > STRAIGHT then lowerHinge.Unit else hinge
	local lower = boneFrame(elbowAt, down, lowerHinge, boneTurn(lowerBone.Unit), elbowC1.Position)
	local hand = CFrame.new(lower * wristC0.Position) * handTurn * CFrame.new(-wristC1.Position)
	return upper, lower, hand, gripAt
end

--[[
	Puts `arm`'s hand on `target` (a grip's world frame), `weight` of the way from the animation
	(1: on it), its elbow away from a camera at `eye` (`solve`). Returns where its grip got to
	(world).
]]
local function pose(arm: Arm, torso: BasePart, target: CFrame, weight: number, eye: Vector3?): Vector3
	local upper, lower, hand, gripAt = solve(arm, torso, target, eye)
	if upper == nil then
		return target.Position
	end
	local shoulder, elbow, wrist = arm.shoulder, arm.elbow, arm.wrist
	local shoulderC1, elbowC1, wristC1 = shoulder.motor.C1, elbow.motor.C1, wrist.motor.C1
	local torsoFrame = torso.CFrame
	local shoulderT, elbowT, wristT = shoulder.motor.Transform, elbow.motor.Transform, wrist.motor.Transform
	local shoulderIk = torsoFrame:Inverse() * upper * shoulderC1 * shoulderT:Inverse()
	local elbowIk = upper:Inverse() * lower * elbowC1 * elbowT:Inverse()
	local wristIk = lower:Inverse() * hand * wristC1 * wristT:Inverse()
	if weight < 1 then
		shoulderIk = baseOf(shoulder):Lerp(shoulderIk, weight)
		elbowIk = baseOf(elbow):Lerp(elbowIk, weight)
		wristIk = baseOf(wrist):Lerp(wristIk, weight)
		-- (Where the weighted joints put the parts.)
		upper = torsoFrame * shoulderIk * shoulderT * shoulderC1:Inverse()
		lower = upper * elbowIk * elbowT * elbowC1:Inverse()
		hand = lower * wristIk * wristT * wristC1:Inverse()
	end
	shoulder.motor.C0 = shoulderIk
	elbow.motor.C0 = elbowIk
	wrist.motor.C0 = wristIk
	arm.posed = true
	arm.upperAt, arm.lowerAt, arm.handAt = upper, lower, hand
	return hand * gripAt
end

--[[
	Puts the local character's hands on the held item (right on `right`, left on `left`: world
	CFrames of the grips; nil leaves that arm to the animation), by two-bone IK on the shoulders,
	elbows and wrists (C0 only), right after Player/HeldItems placed the item this frame; the
	elbows away from a camera at `eye` (nil: down and out only).
]]
function FirstPersonBody.poseArms(character: Model, right: CFrame?, left: CFrame?, eye: Vector3?)
	FirstPersonBody.poseArmsWeighted(character, right, left, 1, 1, eye)
end

--[[
	`poseArms`, each arm `weight` of the way from the animation to the grip (0..1: a punch eases in
	and out, a hand lets go of a gun out of reach). A right grip out of reach is held where the arm
	gets to (`reach`), and the left grip moves with it (the item follows the right hand).
]]
function FirstPersonBody.poseArmsWeighted(
	character: Model,
	right: CFrame?,
	left: CFrame?,
	rightWeight: number,
	leftWeight: number,
	eye: Vector3?
)
	miss = Vector3.zero
	local arms = rigOf(character)
	if arms == nil then
		return
	end
	if right and rightWeight > 0 then
		local got = pose(arms.right, arms.torso, right, math.min(rightWeight, 1), eye)
		if rightWeight >= 1 then
			miss = got - right.Position
		end
	else
		letGo(arms.right)
	end
	if left and leftWeight > 0 then
		local moved = if miss.Magnitude > 0 then left + miss else left
		pose(arms.left, arms.torso, moved, math.min(leftWeight, 1), eye)
	else
		letGo(arms.left)
	end
end

--[[
	How far (studs) a gun whose right grip is at `right` (world) slides along `along` (a unit
	direction: the view's, towards the eyes) for the right wrist to come within `share` of the arm's
	reach (FirstPersonRules.slide; FirstPersonRules.COMFORT, or 1 for anywhere in reach), at most
	`limit`; nil when it can't (or no R15 arms).
]]
function FirstPersonBody.gripSlide(
	character: Model,
	right: CFrame,
	along: Vector3,
	limit: number,
	share: number
): number?
	local arms = rigOf(character)
	if arms == nil then
		return nil
	end
	local s, w, _, _, a, b = reachOf(arms.right, arms.torso, right)
	return FirstPersonRules.slide(s.X, s.Y, s.Z, w.X, w.Y, w.Z, along.X, along.Y, along.Z, (a + b) * share, limit)
end

--[[
	Where the left hand takes a long gun whose fore end is at `fore` (the grip's world frame) and
	whose right grip is at `grip` (world): `fore` slid back along the barrel towards `grip` until the
	left wrist is in reach (comfortably, else at all), at least FirstPersonRules.FORE_MIN ahead of
	`grip`; nil when it can't (the animation keeps the left arm), or no R15 arms.
]]
function FirstPersonBody.foreHold(character: Model, fore: CFrame, grip: Vector3): CFrame?
	local arms = rigOf(character)
	if arms == nil then
		return nil
	end
	local back = grip - fore.Position
	local span = back.Magnitude
	if span < STRAIGHT then
		return nil
	end
	local d = back / span
	local limit = math.max(span - FirstPersonRules.FORE_MIN, 0)
	local s, w, _, _, a, b = reachOf(arms.left, arms.torso, fore)
	local t = FirstPersonRules.slide(
		s.X,
		s.Y,
		s.Z,
		w.X,
		w.Y,
		w.Z,
		d.X,
		d.Y,
		d.Z,
		(a + b) * FirstPersonRules.COMFORT,
		limit
	) or FirstPersonRules.slide(s.X, s.Y, s.Z, w.X, w.Y, w.Z, d.X, d.Y, d.Z, a + b, limit)
	if t == nil then
		return nil
	end
	return fore + d * t
end

--[[
	Would the near plane of `camera` cut the right (`right`) or the left arm in view, its hand on
	`target` (the grip's world frame; the elbow away from the camera, as `poseArms` puts it)? With
	`slack` (studs) less of the near view counts: a hand holding on keeps holding a little further
	in than it takes hold. False without R15 arms.
]]
function FirstPersonBody.armClips(
	character: Model,
	right: boolean,
	target: CFrame,
	camera: Camera,
	slack: number
): boolean
	local arms = rigOf(character)
	if arms == nil then
		return false
	end
	local arm = if right then arms.right else arms.left
	local view = camera.CFrame
	local upper, lower, hand = solve(arm, arms.torso, target, view.Position)
	if upper == nil then
		return false
	end
	local depth, tx, ty = FirstPersonBody.nearView(camera)
	depth = math.max(depth - slack, 0)
	return FirstPersonBody.clipped(view, upper, arm.upper.Size, depth, tx, ty)
		or FirstPersonBody.clipped(view, lower, arm.lower.Size, depth, tx, ty)
		or FirstPersonBody.clipped(view, hand, arm.hand.Size, depth, tx, ty)
end

--[[
	How far the right hand's grip got from where `poseArms` sent it this frame (studs, world; zero
	when it reached it): Player/HeldItems moves a tool or a block by it, so the hand never leaves it.
]]
function FirstPersonBody.reach(): Vector3
	return miss
end

-- Puts `character`'s arms back to the animation (out of true first person, or holding nothing).
function FirstPersonBody.release(character: Model)
	local current = rig
	if current and current.character == character then
		letGo(current.right)
		letGo(current.left)
	end
	miss = Vector3.zero
end

return FirstPersonBody

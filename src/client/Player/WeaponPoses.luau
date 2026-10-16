--!strict
--[[
	How every character holds a firearm in third person (Shared/Weapons), in the manner of DayZ:
	lowered (a long gun across the body, the muzzle low and to the left; a handgun down at the
	side) or raised (both arms forward along the look, the head turned with it). Player/HeldItems
	calls it every frame for each character holding a gun, before it places the gun at the right
	hand, so the gun follows the arms:

	  apply     turns the shoulders' (and the neck's) Motor6D C0 by Player/AimRules.armPose: a turn
	            about the joint in the torso's axes (pitch forward, then yaw inward), and the
	            animation's own turn of that joint (its Transform, which the Animator writes and
	            this never does) taken back out, so a walk's arm swing doesn't throw a raised gun
	            about; the left arm of a lowered handgun and the head of a lowered gun are left to
	            the animation. The joints' own C0 are kept and put back (`release`) as soon as the
	            character holds no gun, or dies.
	  gunFrame  where the gun goes and which way it points: at the right hand's grip
	            (RightGripAttachment, else the hand's bottom), its barrel along AimRules.gunAngles
	            from the body's facing (the root part's) and the look's pitch; the frame's right
	            vector is the barrel and its up the gun's top (ItemModels.firearmPivot "hand").
	  applyMelee  a melee weapon (the melee rework) across the chest while guarding, or drawn
	            up and back over the shoulder as a heavy attack winds up (AimRules.meleeArms);
	            the animation's arms otherwise.

	  applyLook  the local player's head turned with the camera while freelooking (Player/
	            CameraRig.freelookOffset: yaw within NECK_YAW, pitch within NECK_PITCH; the waist
	            takes the rest, Player/BodyTwist), on top of a raised gun's head pitch. Freelook
	            isn't sent, so only the local character's head turns, on this client.

	Whose pose: the local player's from Player/AimCamera at once (raised or in the sights) and from
	Interaction/MeleeInput (guarding, the heavy wind-up), every other player's from the player
	attribute Types.AIM_ATTRIBUTE ("raised", "guard"; a wind-up isn't sent) the server sets; the
	pitch from Player/MovementController (local) or Player/RemotePlayers (the others' last pose).
	In true first person (Player/FirstPersonBody) the local character is released here: its arms
	are Player/FirstPersonBody's (IK on the item in the camera's space), and its head is hidden;
	Player/HeldItems releases one before the other writes the shoulders.
	Rigs are R15 (RightUpperArm.RightShoulder, LeftUpperArm.LeftShoulder, Head.Neck) or R6 (the
	Torso's Right Shoulder, Left Shoulder and Neck); one without the joints is left as it is. C0 is
	set on every client for every character (it doesn't replicate), and nothing is created per
	frame.
]]

local AimRules = require(script.Parent.AimRules)

local WeaponPoses = {}

-- The freelook head's reach (radians): the neck's own turn; the waist takes the rest.
WeaponPoses.NECK_YAW = math.rad(70)
WeaponPoses.NECK_PITCH = math.rad(60)

type Joint = { motor: Motor6D, base: CFrame }

--[[
	A character's joints and whether they are turned now; the head's pitch a gun wants this frame
	(nil: none) and the freelook turn (`applyLook`).
]]
type Rig = {
	right: Joint?,
	left: Joint?,
	neck: Joint?,
	posed: boolean,
	leftPosed: boolean,
	neckPosed: boolean,
	head: number?,
	lookYaw: number,
	lookPitch: number,
}

local rigs: { [Model]: Rig } = setmetatable({}, { __mode = "k" }) :: any

local function joint(parent: Instance?, name: string): Joint?
	local motor = if parent then parent:FindFirstChild(name) else nil
	if motor and motor:IsA("Motor6D") then
		return { motor = motor, base = motor.C0 }
	end
	return nil
end

local function rigOf(character: Model): Rig
	local rig = rigs[character]
	if rig then
		return rig
	end
	local torso = character:FindFirstChild("Torso")
	local new: Rig
	if torso then
		new = {
			right = joint(torso, "Right Shoulder"),
			left = joint(torso, "Left Shoulder"),
			neck = joint(torso, "Neck"),
			posed = false,
			leftPosed = false,
			neckPosed = false,
			head = nil,
			lookYaw = 0,
			lookPitch = 0,
		}
	else
		new = {
			right = joint(character:FindFirstChild("RightUpperArm"), "RightShoulder"),
			left = joint(character:FindFirstChild("LeftUpperArm"), "LeftShoulder"),
			neck = joint(character:FindFirstChild("Head"), "Neck"),
			posed = false,
			leftPosed = false,
			neckPosed = false,
			head = nil,
			lookYaw = 0,
			lookPitch = 0,
		}
	end
	rigs[character] = new
	return new
end

-- Turns `j` by (rx, ry, rz) about its joint in its Part0's axes, the animation taken out.
local function turn(j: Joint?, rx: number, ry: number, rz: number)
	if j == nil or j.motor.Parent == nil then
		return
	end
	local base = j.base
	j.motor.C0 = CFrame.new(base.Position)
		* CFrame.fromEulerAnglesYXZ(rx, ry, rz)
		* base.Rotation
		* j.motor.Transform:Inverse()
end

local function restore(j: Joint?)
	if j and j.motor.Parent ~= nil then
		j.motor.C0 = j.base
	end
end

-- The neck: a gun's head pitch (`rig.head`) and the freelook turn on top, else as it was.
local function neckStep(rig: Rig)
	local head = rig.head
	if head == nil and rig.lookYaw == 0 and rig.lookPitch == 0 then
		if rig.neckPosed then
			restore(rig.neck)
			rig.neckPosed = false
		end
		return
	end
	turn(rig.neck, (head or 0) + rig.lookPitch, rig.lookYaw, 0)
	rig.neckPosed = true
end

--[[
	Poses `character`'s arms (and head) for a firearm held in `posture` with the look's `pitch`
	(radians, up positive); `long` a long gun (AimRules.longGun). See the header.
]]
function WeaponPoses.apply(character: Model, posture: AimRules.Posture, pitch: number, long: boolean)
	local rig = rigOf(character)
	local rx, ry, rz, lx, ly, lz, leftPinned, head = AimRules.armPose(posture, pitch, long)
	turn(rig.right, rx, ry, rz)
	rig.posed = true
	if leftPinned then
		turn(rig.left, lx, ly, lz)
		rig.leftPosed = true
	elseif rig.leftPosed then
		restore(rig.left)
		rig.leftPosed = false
	end
	rig.head = head
	neckStep(rig)
end

--[[
	Poses `character`'s arms for a melee weapon: guarding, or winding a heavy attack up (`charge`
	0..1); neither puts them back (see the header).
]]
function WeaponPoses.applyMelee(character: Model, guard: boolean, charge: number)
	local rx, ry, rz, lx, ly, lz, leftPinned = AimRules.meleeArms(guard, charge)
	if rx == nil then
		WeaponPoses.release(character)
		return
	end
	local rig = rigOf(character)
	turn(rig.right, rx, ry, rz)
	rig.posed = true
	if leftPinned then
		turn(rig.left, lx, ly, lz)
		rig.leftPosed = true
	elseif rig.leftPosed then
		restore(rig.left)
		rig.leftPosed = false
	end
	rig.head = nil
	neckStep(rig)
end

--[[
	Puts `character`'s arms back as they were (it holds no gun any more) and its head, but for the
	freelook turn (`applyLook`; none: all of it).
]]
function WeaponPoses.release(character: Model)
	local rig = rigs[character]
	if rig == nil or not (rig.posed or rig.neckPosed) then
		return
	end
	if rig.posed then
		restore(rig.right)
		restore(rig.left)
		rig.posed, rig.leftPosed = false, false
	end
	rig.head = nil
	neckStep(rig)
end

--[[
	Turns the local `character`'s head with the camera while freelooking (Player/CameraRig
	.freelookOffset: radians, `yaw` left and `pitch` up of the aim; 0, 0 puts it back), within the
	neck's reach (NECK_YAW, NECK_PITCH), on top of a raised gun's head pitch. Call it after this
	frame's `apply` / `applyMelee` / `release` (they turn the head with the last look given).
]]
function WeaponPoses.applyLook(character: Model, yaw: number, pitch: number)
	local y = math.clamp(yaw, -WeaponPoses.NECK_YAW, WeaponPoses.NECK_YAW)
	local p = math.clamp(pitch, -WeaponPoses.NECK_PITCH, WeaponPoses.NECK_PITCH)
	local rig = rigs[character]
	if rig == nil then
		if y == 0 and p == 0 then
			return
		end
		rig = rigOf(character)
	end
	assert(rig, "rig")
	if rig.lookYaw == y and rig.lookPitch == p then
		-- (Already turned this frame by the arms' call.)
		return
	end
	rig.lookYaw, rig.lookPitch = y, p
	neckStep(rig)
end

--[[
	The frame a gun held by `character` in `posture` goes on (see the header): at the right hand's
	grip, its right vector the barrel, its up the gun's top. nil without a hand or a root part.
]]
function WeaponPoses.gunFrame(character: Model, posture: AimRules.Posture, pitch: number, long: boolean): CFrame?
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	local root = character:FindFirstChild("HumanoidRootPart")
	if hand == nil or not hand:IsA("BasePart") or root == nil or not root:IsA("BasePart") then
		return nil
	end
	local grip = hand:FindFirstChild("RightGripAttachment")
	local position = if grip and grip:IsA("Attachment")
		then grip.WorldPosition
		else (hand.CFrame * CFrame.new(0, -hand.Size.Y / 2, 0)).Position
	local frame = root.CFrame
	local look = frame.LookVector
	local forward = Vector3.new(look.X, 0, look.Z)
	if forward.Magnitude < 1e-3 then
		-- (Lying face down: the body's up is its facing.)
		local up = frame.UpVector
		forward = Vector3.new(-up.X, 0, -up.Z)
		if forward.Magnitude < 1e-3 then
			forward = Vector3.new(0, 0, -1)
		end
	end
	forward = forward.Unit
	local left = Vector3.new(forward.Z, 0, -forward.X)
	local yaw, gunPitch = AimRules.gunAngles(posture, pitch, long)
	local heading = forward * math.cos(yaw) + left * math.sin(yaw)
	local barrel = heading * math.cos(gunPitch) + Vector3.yAxis * math.sin(gunPitch)
	local top = Vector3.yAxis * math.cos(gunPitch) - heading * math.sin(gunPitch)
	return CFrame.fromMatrix(position, barrel, top)
end

return WeaponPoses

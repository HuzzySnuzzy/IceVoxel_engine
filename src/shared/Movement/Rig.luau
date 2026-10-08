--!strict
--[[
	Where a player's movement hull is relative to their (purely cosmetic) Roblox character, for code
	on the server and the client that only has the character.

	The client's MovementController moves a Minecraft-style hull (Movement/PlayerPhysics) and places
	the character so its feet are on the hull's bottom: the HumanoidRootPart's centre is
	`rootOffset` studs above the feet. The server teleports characters through `teleport`-style
	attributes (see Players/Characters) so the client can move its hull exactly.

	`rootCFrame` is that placement from feet in render studs (Shared/World/Origin), for the local
	character and, once characters stand parked on the server (Config.Players.ServerPositions),
	every remote one; `deathCFrame` is Minecraft's death roll and `yaw` reads a placed root's yaw
	back at any body pitch.
]]

local Config = require(script.Parent.Parent.Config)
local PlayerPhysics = require(script.Parent.PlayerPhysics)

local BLOCK = Config.BlockSize

local Rig = {}

-- Collision group of characters: collides with nothing (the hull does the colliding).
Rig.COLLISION_GROUP = "IceVoxelCharacters"
-- Feet position (blocks, Vector3) the server last teleported the character to, and a counter that
-- changes on every teleport (so teleporting to the same place twice is noticed too).
Rig.TELEPORT_FEET = "IceVoxelFeet"
Rig.TELEPORT_COUNT = "IceVoxelTeleports"
-- With Config.Players.ServerPositions: the character's life (a counter, +1 for each new
-- character of a player, Players/Characters.park); the Teleport message (Net/PlayerSync) that
-- carries the same life is the one that placed this character.
Rig.LIFE = "IceVoxelLife"

-- Studs from the character's feet to the centre of its HumanoidRootPart, standing.
function Rig.rootOffset(character: Model): number
	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local half = if root and root:IsA("BasePart") then root.Size.Y / 2 else 1
	if humanoid and humanoid.RigType == Enum.HumanoidRigType.R15 then
		return humanoid.HipHeight + half
	end
	-- R6: the legs hang below the torso.
	local leg = character:FindFirstChild("Left Leg")
	return half + (if leg and leg:IsA("BasePart") then leg.Size.Y else 2)
end

-- Height (studs) of the root part above the feet when lying down (swimming / crawling): the
-- middle of the crawling hull.
Rig.LYING_ROOT = PlayerPhysics.dimensions("crawling").height / 2 * BLOCK

-- Root height above the feet for a body `tilt` of the way (0..1) into the lying pose.
function Rig.rootHeight(character: Model, tilt: number): number
	local standing = Rig.rootOffset(character)
	return standing + (Rig.LYING_ROOT - standing) * tilt
end

--[[
	Feet position (blocks) of a character, from its root part. A lying body (MovementController
	pitches the root forward) has its root lower; how far it lies is read from the root's pitch
	(exact for crawling, close for swimming, whose pitch follows the view).
]]
function Rig.feet(character: Model): Vector3?
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return nil
	end
	local pitch = math.acos(math.clamp(root.CFrame.UpVector.Y, -1, 1))
	local tilt = math.clamp(pitch / (math.pi / 2), 0, 1)
	return (root.Position - Vector3.new(0, Rig.rootHeight(character, tilt), 0)) / BLOCK
end

-- The standing hull of a character (blocks): min and max corners.
function Rig.hull(character: Model): (Vector3?, Vector3?)
	local feet = Rig.feet(character)
	if feet == nil then
		return nil, nil
	end
	local standing = PlayerPhysics.STANDING
	local half = standing.width / 2
	return feet - Vector3.new(half, 0, half), feet + Vector3.new(half, standing.height, half)
end

--[[
	Where a character's root part goes for feet at `renderFeet` (render studs: Shared/World/Origin),
	facing `yaw`, lying `tilt` of the way (0..1) with the body pitched `bodyPitch` (radians: pi / 2
	face down when crawling, along the view when swimming): the root `Rig.rootHeight` above the feet,
	turned, then pitched forward (MovementController's placement, and every remote character's).
]]
function Rig.rootCFrame(character: Model, renderFeet: Vector3, yaw: number, tilt: number, bodyPitch: number): CFrame
	return CFrame.new(renderFeet + Vector3.new(0, Rig.rootHeight(character, tilt), 0))
		* CFrame.Angles(0, yaw, 0)
		* CFrame.Angles(-bodyPitch * tilt, 0, 0)
end

-- The yaw a root CFrame was placed with (`rootCFrame`), at any body pitch (from its right vector,
-- which the pitch leaves level; ToOrientation's yaw is lost when the body lies flat).
function Rig.yaw(root: CFrame): number
	local right = root.RightVector
	return math.atan2(-right.Z, right.X)
end

--[[
	A dying body falling over (Minecraft's LivingEntityRenderer.setupRotations): rolled about its
	forward axis by 90 degrees x min(1, sqrt(1.6 x progress)), progress = (deathTime + partial tick
	- 1) / 20 (so it lies on its side after 13.5 ticks). `base` is the root's CFrame alive;
	`height` (studs: the root above the feet, Rig.rootOffset) makes it turn about the feet, as
	Minecraft's model does (nil: about the root's centre).
]]
function Rig.deathCFrame(base: CFrame, progress: number, height: number?): CFrame
	local roll = math.min(1, math.sqrt(math.max(0, progress) * 1.6)) * (math.pi / 2)
	if height == nil or height == 0 then
		return base * CFrame.Angles(0, 0, roll)
	end
	return base * CFrame.new(0, -height, 0) * CFrame.Angles(0, 0, roll) * CFrame.new(0, height, 0)
end

return Rig

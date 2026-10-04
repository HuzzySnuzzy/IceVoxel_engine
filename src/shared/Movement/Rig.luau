--!strict
--[[
	Where a player's movement hull is relative to their (purely cosmetic) Roblox character, for code
	on the server and the client that only has the character.

	The client's MovementController moves a Minecraft-style hull (Movement/PlayerPhysics) and places
	the character so its feet are on the hull's bottom: the HumanoidRootPart's centre is
	`rootOffset` studs above the feet. The server teleports characters through `teleport`-style
	attributes (see Players/Characters) so the client can move its hull exactly.
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

return Rig

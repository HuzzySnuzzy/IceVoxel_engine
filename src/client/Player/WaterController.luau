--!strict
--[[
	Swimming and currents for the local character in IceVoxel water.

	Water blocks are drawn with non-colliding parts, so Roblox's own swimming (which only knows
	Terrain water) never starts. Instead, every physics step this checks the client's block data at
	the character's feet, waist and head, and while the character is in water:

	  * a VectorForce cancels most of gravity (sinks slowly; floats up when fully under water),
	  * the same force pushes along the current (Shared/World/FluidFlow, Minecraft's flow rule):
	    flowing water carries you downstream and over edges, still water does not move you,
	  * holding Jump swims upwards, falling speed is capped, walking is slower.

	The client owns its character's physics, so all of this is local and replicates as movement.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Blocks = require(Shared.Blocks)
local FluidFlow = require(Shared.World.FluidFlow)

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)

local BLOCK = Config.BlockSize
local Water = Config.Water

local WaterController = {}

local function isFluid(block: number?): boolean
	return block ~= nil and Blocks.get(block).fluid ~= nil
end

function WaterController.start(world: ClientWorld.ClientWorld)
	local function getBlock(x: number, y: number, z: number): number?
		return world:getBlock(x, y, z)
	end

	local root: BasePart? = nil
	local humanoid: Humanoid? = nil
	local force: VectorForce? = nil
	local baseWalkSpeed = 16
	local swimming = false

	local function onCharacter(character: Model)
		local r = character:WaitForChild("HumanoidRootPart", 10)
		local h = character:WaitForChild("Humanoid", 10)
		if r == nil or h == nil or not r:IsA("BasePart") or not h:IsA("Humanoid") then
			return
		end
		local attachment = Instance.new("Attachment")
		attachment.Name = "IceVoxelWater"
		attachment.Parent = r
		local f = Instance.new("VectorForce")
		f.Name = "IceVoxelWater"
		f.Attachment0 = attachment
		f.RelativeTo = Enum.ActuatorRelativeTo.World
		f.ApplyAtCenterOfMass = true
		f.Force = Vector3.zero
		f.Enabled = false
		f.Parent = r
		root, humanoid, force = r, h, f
		baseWalkSpeed = h.WalkSpeed
		swimming = false
	end

	local function stopSwimming()
		if swimming then
			swimming = false
			if force then
				force.Enabled = false
			end
			if humanoid then
				humanoid.WalkSpeed = baseWalkSpeed
			end
		end
	end

	local function wantsUp(h: Humanoid): boolean
		return h.Jump
			or UserInputService:IsKeyDown(Enum.KeyCode.Space)
			or UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonA)
	end

	RunService.PreSimulation:Connect(function()
		local r, h, f = root, humanoid, force
		if r == nil or h == nil or f == nil or r.Parent == nil or r.Anchored then
			stopSwimming()
			return
		end

		local p = r.Position
		local bx, bz = math.floor(p.X / BLOCK), math.floor(p.Z / BLOCK)
		local feetY = math.floor((p.Y - 2.5) / BLOCK)
		local waistY = math.floor(p.Y / BLOCK)
		local headY = math.floor((p.Y + 1.5) / BLOCK)
		local feet = isFluid(getBlock(bx, feetY, bz))
		local waist = isFluid(getBlock(bx, waistY, bz))
		if not feet and not waist then
			stopSwimming()
			return
		end
		local submerged = waist and isFluid(getBlock(bx, headY, bz))

		if not swimming then
			swimming = true
			baseWalkSpeed = h.WalkSpeed
			h.WalkSpeed = baseWalkSpeed * Water.WalkSpeedFactor
			f.Enabled = true
		end

		local mass = r.AssemblyMass
		local lift = if submerged then Water.SubmergedBuoyancy elseif waist then Water.Buoyancy else 0
		local fx, fy, fz = FluidFlow.at(getBlock, bx, if waist then waistY else feetY, bz)
		local current = Vector3.new(fx, fy * 0.5, fz) * Water.CurrentAcceleration
		f.Force = (Vector3.new(0, workspace.Gravity * lift, 0) + current) * mass

		-- Vertical control: swim up while Jump is held, otherwise sink no faster than SinkSpeed.
		local v = r.AssemblyLinearVelocity
		local vy = v.Y
		if waist and wantsUp(h) then
			vy = math.max(vy, Water.SwimUpSpeed)
		elseif vy < -Water.SinkSpeed then
			vy = -Water.SinkSpeed
		end
		if vy ~= v.Y then
			r.AssemblyLinearVelocity = Vector3.new(v.X, vy, v.Z)
		end
	end)

	local player = Players.LocalPlayer
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
end

return WaterController

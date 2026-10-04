--!strict
--[[
	Swimming and currents for the local character in IceVoxel water.

	Water blocks are drawn with non-colliding parts, so Roblox's own swimming (which only knows
	Terrain water) never starts. Instead, every physics step this measures how much of the
	character is under water (using the lowered surfaces of flowing water) and sets one VectorForce
	on the root part (force = mass * acceleration; velocity is never written directly):

	  * buoyancy cancels most of gravity in proportion to how deep you are, and vertical drag
	    limits sinking speed: you sink slowly and bob at the surface while holding Jump,
	  * holding Jump with the waist under water swims upwards,
	  * the current (Shared/World/FluidFlow, Minecraft's flow rule) pushes along the flow until you
	    move at Config.Water.CurrentSpeed; it never slows you down, and still water does not push,
	  * walking is slower.

	The Humanoid stays in its normal states (forcing Swimming outside Terrain water makes it pitch
	over and steer with the camera). The client owns its character's physics, so this is all local
	and replicates as movement.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Blocks = require(Shared.Blocks)
local FluidFlow = require(Shared.World.FluidFlow)

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)

local BLOCK = Config.BlockSize
local FLUID_FULL = Blocks.FLUID_FULL
local FLUID_HEIGHT = Blocks.fluidHeightLut
-- Studs from the top of the root part to the top of the head (default avatars).
local HEAD = 1.5
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

	-- Highest water surface (studs) reaching into the body between block rows y0 and y1, or nil.
	local function waterTop(bx: number, y0: number, y1: number, bz: number): (number?, number)
		local top, first = nil, y0
		for y = y0, y1 do
			local block = getBlock(bx, y, bz)
			if isFluid(block) then
				if top == nil then
					first = y
				end
				top = (y + buffer.readu8(FLUID_HEIGHT, block :: number) / FLUID_FULL) * BLOCK
			elseif top then
				break
			end
		end
		return top, first
	end

	RunService.PreSimulation:Connect(function()
		local r, h, f = root, humanoid, force
		if r == nil or h == nil or f == nil or r.Parent == nil or r.Anchored then
			stopSwimming()
			return
		end
		local mass = r.AssemblyMass
		if mass ~= mass or mass == math.huge then
			-- Welded to something anchored (e.g. held during a teleport).
			stopSwimming()
			return
		end

		-- How much of the body is under water (0..1), from the real (lowered) water surface.
		local p = r.Position
		local legs = if h.RigType == Enum.HumanoidRigType.R15 then h.HipHeight else 2
		local bottom = p.Y - r.Size.Y / 2 - legs
		local height = r.Size.Y + legs + HEAD
		local bx, bz = math.floor(p.X / BLOCK), math.floor(p.Z / BLOCK)
		local top, flowY = waterTop(bx, math.floor(bottom / BLOCK), math.floor((bottom + height) / BLOCK), bz)
		local submerged = if top then math.clamp((top - bottom) / height, 0, 1) else 0
		if submerged <= 0 then
			stopSwimming()
			return
		end

		if not swimming then
			swimming = true
			baseWalkSpeed = h.WalkSpeed
			h.WalkSpeed = baseWalkSpeed * Water.WalkSpeedFactor
			f.Enabled = true
		end

		local v = r.AssemblyLinearVelocity
		local accel = Vector3.zero

		-- Current: push along the flow until moving at the current's speed; never brakes.
		local waistY = math.floor(p.Y / BLOCK)
		if isFluid(getBlock(bx, waistY, bz)) then
			flowY = waistY
		end
		local fx, fy, fz = FluidFlow.at(getBlock, bx, flowY, bz)
		local flow = Vector3.new(fx, fy, fz)
		local strength = flow.Magnitude
		if strength > 1e-3 then
			local direction = flow / strength
			local cap = if h.FloorMaterial ~= Enum.Material.Air
				then Water.CurrentMaxAccelerationGrounded
				else Water.CurrentMaxAcceleration
			local target = Water.CurrentSpeed * math.min(strength, 1)
			accel += direction * math.clamp(Water.CurrentGain * (target - v:Dot(direction)), 0, cap)
		end

		-- Buoyancy and drag grow with how deep you are, so holding Jump bobs at the surface.
		-- Humanoid.Jump is set every frame by the default controls (keyboard, gamepad and touch).
		local g = workspace.Gravity
		local ay = (g * Water.Buoyancy - Water.Drag * v.Y) * submerged
		if h.Jump and top and top >= p.Y then
			ay += Water.SwimUpAcceleration
		end
		accel += Vector3.new(0, ay, 0)

		f.Force = accel * mass
	end)

	local player = Players.LocalPlayer
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
end

return WaterController

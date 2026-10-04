--!strict
--[[
	Swimming and currents for the local character in IceVoxel water.

	Water blocks are drawn with non-colliding parts, so Roblox's own swimming (which only knows
	Terrain water) never starts. Instead, every physics step this measures how much of the
	character is under water (using the lowered surfaces of flowing water) and sets one VectorForce
	on the root part (force = mass * acceleration; velocity is never written directly):

	  * buoyancy cancels most of gravity in proportion to how deep you are, and vertical drag
	    limits sinking speed: you sink slowly and bob at the surface while holding Jump,
	  * holding Jump with the waist under water swims upwards; holding Jump while swimming towards a
	    ledge with room above it lifts the character out onto it (like Minecraft),
	  * the current (Shared/World/FluidFlow, Minecraft's flow rule) pushes along the flow until you
	    move at Config.Water.CurrentSpeed; it never slows you down, and still water does not push,
	  * walking is slower. A WalkSpeed another script assigns while the character swims becomes its
	    new normal speed (slowed while in water, kept afterwards). Assign absolute values: relative
	    changes (`+=`, `*=`) would be applied to the slowed speed.

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

local function fluidGroup(block: number?): string?
	local fluid = if block then Blocks.get(block).fluid else nil
	return if fluid then fluid.group else nil
end

function WaterController.start(world: ClientWorld.ClientWorld)
	local function getBlock(x: number, y: number, z: number): number?
		return world:getBlock(x, y, z)
	end

	local root: BasePart? = nil
	local humanoid: Humanoid? = nil
	local force: VectorForce? = nil
	local baseWalkSpeed = 16
	-- WalkSpeed as read back after writing the slowed value (it is stored as a float32).
	local appliedWalkSpeed = 0
	local swimming = false
	-- Top (studs) of the ledge being climbed onto, and when to give up.
	local exitLedge: number? = nil
	local exitUntil = 0
	-- After a climb gave up, no new one starts until Jump is released.
	local exitBlocked = false

	local function isSolidAt(x: number, y: number, z: number): boolean
		local block = getBlock(x, y, z)
		return block ~= nil and Blocks.isSolid(block)
	end

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
		exitLedge = nil
	end

	local function stopSwimming()
		exitLedge = nil
		if swimming then
			swimming = false
			if force then
				force.Enabled = false
			end
			-- Restore the walk speed unless another script changed it meanwhile.
			local h = humanoid
			if h and math.abs(h.WalkSpeed - appliedWalkSpeed) < 1e-3 then
				h.WalkSpeed = baseWalkSpeed
			end
		end
	end

	local function slowDown(h: Humanoid)
		baseWalkSpeed = h.WalkSpeed
		h.WalkSpeed = baseWalkSpeed * Water.WalkSpeedFactor
		appliedWalkSpeed = h.WalkSpeed
	end

	-- Top (studs) of a block the character swims against and could climb onto, or nil. The block
	-- needs two free blocks above it, and the character room above its own head to rise.
	local function ledgeAhead(h: Humanoid, p: Vector3, r: BasePart, bottom: number, height: number): number?
		local move = Vector3.new(h.MoveDirection.X, 0, h.MoveDirection.Z)
		if move.Magnitude < 0.1 then
			return nil
		end
		local ahead = p + move.Unit * (r.Size.X / 2 + 1)
		local ax, az = math.floor(ahead.X / BLOCK), math.floor(ahead.Z / BLOCK)
		for y = math.floor((p.Y + r.Size.Y / 2) / BLOCK), math.floor(bottom / BLOCK), -1 do
			if isSolidAt(ax, y, az) then
				if isSolidAt(ax, y + 1, az) or isSolidAt(ax, y + 2, az) then
					return nil -- no room to stand
				end
				local ledge = (y + 1) * BLOCK
				local bx, bz = math.floor(p.X / BLOCK), math.floor(p.Z / BLOCK)
				for above = math.floor((bottom + height) / BLOCK), math.floor((ledge + height) / BLOCK) do
					if isSolidAt(bx, above, bz) then
						return nil -- something overhead
					end
				end
				return ledge
			end
		end
		return nil
	end

	-- Highest water surface (studs) reaching into the body between block rows y0 and y1, or nil.
	-- A fluid block is lowered to its level's height only when the same fluid is not above it.
	local function waterTop(bx: number, y0: number, y1: number, bz: number): (number?, number)
		local top, first = nil, y0
		for y = y0, y1 do
			local block = getBlock(bx, y, bz)
			if isFluid(block) then
				if top == nil then
					first = y
				end
				if fluidGroup(getBlock(bx, y + 1, bz)) == fluidGroup(block) then
					top = (y + 1) * BLOCK
				else
					top = (y + buffer.readu8(FLUID_HEIGHT, block :: number) / FLUID_FULL) * BLOCK
				end
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
		local g = workspace.Gravity
		local v = r.AssemblyLinearVelocity

		-- Climbing out onto a ledge continues (briefly) after leaving the water, until the feet
		-- are above it.
		if not h.Jump then
			exitBlocked = false
		end
		if exitLedge and (bottom >= exitLedge or os.clock() > exitUntil or not h.Jump) then
			exitBlocked = os.clock() > exitUntil
			exitLedge = nil
		end
		if submerged > 0 and top and h.Jump and exitLedge == nil and not exitBlocked then
			local ledge = ledgeAhead(h, p, r, bottom, height)
			-- At most one block above the water's top row, however high a jump carried the body.
			if ledge and bottom < ledge and ledge <= (math.ceil(top / BLOCK) + 1) * BLOCK then
				exitLedge, exitUntil = ledge, os.clock() + 1.5
			end
		end
		if submerged <= 0 and exitLedge == nil then
			stopSwimming()
			return
		end

		if not swimming then
			swimming = true
			slowDown(h)
			f.Enabled = true
		elseif math.abs(h.WalkSpeed - appliedWalkSpeed) >= 1e-3 then
			-- Another script set a new walk speed: treat it as the new normal speed.
			slowDown(h)
		end

		if exitLedge then
			-- Rise at ClimbOutSpeed regardless of how deep the character is.
			local ay = g + (Water.ClimbOutSpeed - v.Y) * 8
			f.Force = Vector3.new(0, ay, 0) * mass
			return
		end

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

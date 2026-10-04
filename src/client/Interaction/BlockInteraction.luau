--!strict
--[[
	Breaking and placing blocks.

	  Mouse:    left = break, right click (without dragging the camera) = place
	  Gamepad:  R2 = break, L2 = place (aims at the screen centre, shown by a crosshair)
	  Touch:    tap = break, long press = place
	Holding a button repeats every Config.Interaction.RepeatInterval seconds.

	Targeting uses a voxel raycast on the client's block data, so it is exact and independent of
	the parts. Edits are predicted locally and confirmed / corrected by the server.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Blocks = require(Shared.Blocks)
local VoxelRaycast = require(Shared.World.VoxelRaycast)

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local Hotbar = require(script.Parent.Hotbar)

local BLOCK = Config.BlockSize
local REACH = Config.Interaction.Reach
local CLICK_TIME = 0.3
local CLICK_MOVE = 8

local BlockInteraction = {}

function BlockInteraction.start(world: ClientWorld.ClientWorld)
	local player = Players.LocalPlayer
	local hotbar = Hotbar.new()

	local highlight = Instance.new("Part")
	highlight.Name = "IceVoxelSelection"
	highlight.Anchored = true
	highlight.CanCollide = false
	highlight.CanQuery = false
	highlight.CanTouch = false
	highlight.Transparency = 1
	highlight.Size = Vector3.one * (BLOCK + 0.05)
	local selection = Instance.new("SelectionBox")
	selection.Adornee = highlight
	selection.LineThickness = 0.04
	selection.Color3 = Color3.new(0.1, 0.1, 0.1)
	selection.SurfaceTransparency = 1
	selection.Parent = highlight
	highlight.Parent = workspace.CurrentCamera

	local crosshairGui = Instance.new("ScreenGui")
	crosshairGui.Name = "IceVoxelCrosshair"
	crosshairGui.IgnoreGuiInset = true
	crosshairGui.ResetOnSpawn = false
	local crosshair = Instance.new("Frame")
	crosshair.AnchorPoint = Vector2.new(0.5, 0.5)
	crosshair.Position = UDim2.fromScale(0.5, 0.5)
	crosshair.Size = UDim2.fromOffset(6, 6)
	crosshair.BackgroundColor3 = Color3.new(1, 1, 1)
	crosshair.Visible = false
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = crosshair
	local outline = Instance.new("UIStroke")
	outline.Parent = crosshair
	crosshair.Parent = crosshairGui
	crosshairGui.Parent = player:WaitForChild("PlayerGui")

	local function getBlock(x: number, y: number, z: number): number?
		return world:getBlock(x, y, z)
	end

	local function rootPart(): BasePart?
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			return root
		end
		return nil
	end

	-- Block under a viewport position (or a GUI position when `gui` is set), within reach.
	local function targetAt(point: Vector2, gui: boolean?): VoxelRaycast.Hit?
		local root = rootPart()
		if root == nil then
			return nil
		end
		local camera = workspace.CurrentCamera
		local ray = if gui
			then camera:ScreenPointToRay(point.X, point.Y)
			else camera:ViewportPointToRay(point.X, point.Y)
		local origin = ray.Origin / BLOCK
		local maxDistance = (ray.Origin - root.Position).Magnitude / BLOCK + REACH
		local hit = VoxelRaycast.cast(
			origin.X,
			origin.Y,
			origin.Z,
			ray.Direction.X,
			ray.Direction.Y,
			ray.Direction.Z,
			maxDistance,
			getBlock,
			Blocks.isTargetable
		)
		if hit then
			local center = Vector3.new(hit.x + 0.5, hit.y + 0.5, hit.z + 0.5) * BLOCK
			if (center - root.Position).Magnitude > REACH * BLOCK then
				return nil
			end
		end
		return hit
	end

	-- Where the player aims, in viewport coordinates: the mouse while it is the active input and
	-- free, otherwise the screen centre. (A PC with a controller still has a mouse, so
	-- MouseEnabled alone would aim at wherever the hidden cursor was left.)
	local function pointer(): Vector2
		local preferred = UserInputService.PreferredInput
		crosshair.Visible = preferred == Enum.PreferredInput.Gamepad or preferred == Enum.PreferredInput.MicroGamepad
		if
			preferred == Enum.PreferredInput.KeyboardAndMouse
			and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter
		then
			-- GetMouseLocation ignores the GUI inset, i.e. it is in viewport coordinates.
			return UserInputService:GetMouseLocation()
		end
		local size = workspace.CurrentCamera.ViewportSize
		return Vector2.new(size.X / 2, size.Y / 2)
	end

	-- Would a solid block at (x, y, z) overlap the local character?
	local function blocksCharacter(x: number, y: number, z: number): boolean
		local root = rootPart()
		if root == nil then
			return false
		end
		local p = root.Position
		local minX, minY, minZ = x * BLOCK, y * BLOCK, z * BLOCK
		return p.X + 0.9 > minX
			and p.X - 0.9 < minX + BLOCK
			and p.Z + 0.9 > minZ
			and p.Z - 0.9 < minZ + BLOCK
			and p.Y + 2.2 > minY
			and p.Y - 2.9 < minY + BLOCK
	end

	local function breakAt(hit: VoxelRaycast.Hit?)
		if hit and Blocks.get(hit.block).breakable then
			world:breakBlock(hit.x, hit.y, hit.z)
		end
	end

	local function placeAt(hit: VoxelRaycast.Hit?)
		if hit == nil then
			return
		end
		local x, y, z = hit.x + hit.nx, hit.y + hit.ny, hit.z + hit.nz
		local block = hotbar.selected()
		local current = world:getBlock(x, y, z)
		if current == nil or not Blocks.isReplaceable(current) then
			return
		end
		if Blocks.isSolid(block) and blocksCharacter(x, y, z) then
			return
		end
		world:placeBlock(x, y, z, block)
	end

	local target: VoxelRaycast.Hit? = nil
	local breaking, placing = false, false
	local lastAction = 0
	local rightDownAt, rightDownPos = 0, Vector2.zero

	RunService.RenderStepped:Connect(function()
		target = targetAt(pointer())
		if target then
			highlight.CFrame = CFrame.new((target.x + 0.5) * BLOCK, (target.y + 0.5) * BLOCK, (target.z + 0.5) * BLOCK)
			selection.Visible = true
		else
			selection.Visible = false
		end

		local now = os.clock()
		if (breaking or placing) and now - lastAction >= Config.Interaction.RepeatInterval then
			lastAction = now
			if breaking then
				breakAt(target)
			else
				placeAt(target)
			end
		end
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		local kind, key = input.UserInputType, input.KeyCode
		if kind == Enum.UserInputType.MouseButton1 or key == Enum.KeyCode.ButtonR2 then
			breaking = true
			lastAction = os.clock()
			breakAt(target)
		elseif key == Enum.KeyCode.ButtonL2 then
			placing = true
			lastAction = os.clock()
			placeAt(target)
		elseif kind == Enum.UserInputType.MouseButton2 then
			rightDownAt = os.clock()
			rightDownPos = Vector2.new(input.Position.X, input.Position.Y)
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		local kind, key = input.UserInputType, input.KeyCode
		if kind == Enum.UserInputType.MouseButton1 or key == Enum.KeyCode.ButtonR2 then
			breaking = false
		elseif key == Enum.KeyCode.ButtonL2 then
			placing = false
		elseif kind == Enum.UserInputType.MouseButton2 then
			-- Right drag rotates the camera; only a short click places.
			local moved = (Vector2.new(input.Position.X, input.Position.Y) - rightDownPos).Magnitude
			if os.clock() - rightDownAt < CLICK_TIME and moved < CLICK_MOVE then
				placeAt(target)
			end
		end
	end)

	UserInputService.TouchTap:Connect(function(positions, processed)
		if not processed and positions[1] then
			breakAt(targetAt(positions[1], true))
		end
	end)

	UserInputService.TouchLongPress:Connect(function(positions, state, processed)
		if not processed and state == Enum.UserInputState.Begin and positions[1] then
			placeAt(targetAt(positions[1], true))
		end
	end)
end

return BlockInteraction

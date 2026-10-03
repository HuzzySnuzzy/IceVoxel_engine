--!strict
--[[
	Minimap in the top right corner: terrain around the player (north up), the player's heading,
	waypoints (pinned to the edge when off the map) and other players. Click it to open the world
	map; `-` / `=` zoom out / in.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

local MapLayer = require(script.Parent.MapLayer)
local MapView = require(script.Parent.MapView)
local Waypoints = require(script.Parent.Waypoints)

local BLOCK = Config.BlockSize
local MAX_ZOOM = 16

export type Minimap = {
	view: MapView.MapView,
	update: () -> (),
}

local Minimap = {}

-- Root part of a player's character, if any.
local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function dot(parent: Instance, size: number, zIndex: number): Frame
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Size = UDim2.fromOffset(size, size)
	frame.BorderSizePixel = 0
	frame.ZIndex = zIndex
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1
	stroke.Parent = frame
	frame.Parent = parent
	return frame
end

function Minimap.new(
	gui: ScreenGui,
	layer: MapLayer.MapLayer,
	waypoints: Waypoints.Waypoints,
	openMap: () -> ()
): Minimap
	local size = Config.Map.MinimapSize

	local holder = Instance.new("Frame")
	holder.Name = "Minimap"
	holder.AnchorPoint = Vector2.new(1, 0)
	holder.Position = UDim2.new(1, -16, 0, 16)
	holder.Size = UDim2.fromOffset(size, size)
	holder.BackgroundColor3 = Color3.fromRGB(24, 28, 34)
	holder.ClipsDescendants = true
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(12, 14, 18)
	stroke.Parent = holder
	holder.Parent = gui

	local view = MapView.new(holder, layer, size)

	local arrow = Instance.new("TextLabel")
	arrow.AnchorPoint = Vector2.new(0.5, 0.5)
	arrow.Position = UDim2.fromScale(0.5, 0.5)
	arrow.Size = UDim2.fromOffset(18, 18)
	arrow.BackgroundTransparency = 1
	arrow.Font = Enum.Font.GothamBold
	arrow.TextSize = 18
	arrow.Text = "▲"
	arrow.TextColor3 = Color3.new(1, 1, 1)
	arrow.TextStrokeTransparency = 0
	arrow.ZIndex = 6
	arrow.Parent = holder

	local info = Instance.new("TextLabel")
	info.AnchorPoint = Vector2.new(1, 0)
	info.Position = UDim2.new(1, -16, 0, 20 + size)
	info.Size = UDim2.fromOffset(size, 18)
	info.BackgroundTransparency = 1
	info.Font = Enum.Font.Code
	info.TextSize = 14
	info.TextXAlignment = Enum.TextXAlignment.Right
	info.TextColor3 = Color3.new(1, 1, 1)
	info.TextStrokeTransparency = 0.4
	info.Parent = gui

	if not layer.available then
		local note = Instance.new("TextLabel")
		note.Size = UDim2.fromScale(1, 1)
		note.BackgroundTransparency = 1
		note.Font = Enum.Font.Gotham
		note.TextSize = 12
		note.TextWrapped = true
		note.TextColor3 = Color3.fromRGB(150, 155, 165)
		note.Text = "Map images unavailable\n(enable Mesh / Image APIs)"
		note.ZIndex = 2
		note.Parent = holder
	end

	local open = Instance.new("TextButton")
	open.Text = ""
	open.BackgroundTransparency = 1
	open.Size = UDim2.fromScale(1, 1)
	open.ZIndex = 10
	open.Activated:Connect(openMap)
	open.Parent = holder

	local waypointDots: { Frame } = {}
	local playerDots: { [Player]: Frame } = {}

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Minus and layer.scale < MAX_ZOOM then
			layer:setScale(layer.scale * 2)
		elseif input.KeyCode == Enum.KeyCode.Equals and layer.scale > 1 then
			layer:setScale(layer.scale // 2)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		local frame = playerDots[player]
		if frame then
			frame:Destroy()
			playerDots[player] = nil
		end
	end)

	local function update()
		local camera = workspace.CurrentCamera
		local me = rootOf(Players.LocalPlayer)
		local position = if me then me.Position else camera.CFrame.Position
		view:render(position.X / BLOCK, position.Z / BLOCK)

		local look = camera.CFrame.LookVector
		arrow.Rotation = math.deg(math.atan2(look.X, -look.Z))
		info.Text = string.format(
			"%d, %d, %d   1:%d",
			math.floor(position.X / BLOCK),
			math.floor(position.Y / BLOCK),
			math.floor(position.Z / BLOCK),
			layer.scale
		)

		-- Waypoints, pinned to the border when outside.
		for i, waypoint in waypoints.list do
			local marker = waypointDots[i] or dot(holder, 8, 4)
			waypointDots[i] = marker
			local p = view:toFrame(waypoint.x + 0.5, waypoint.z + 0.5)
			marker.Position = UDim2.fromOffset(math.clamp(p.X, 4, size - 4), math.clamp(p.Y, 4, size - 4))
			marker.BackgroundColor3 = Color3.fromRGB(waypoint.color[1], waypoint.color[2], waypoint.color[3])
			marker.Visible = true
		end
		for i = #waypoints.list + 1, #waypointDots do
			waypointDots[i].Visible = false
		end

		for _, player in Players:GetPlayers() do
			local root = if player ~= Players.LocalPlayer then rootOf(player) else nil
			local existing: Frame? = playerDots[player]
			if root then
				local marker = existing or dot(holder, 6, 5)
				marker.BackgroundColor3 = Color3.new(1, 1, 1)
				playerDots[player] = marker
				local p = view:toFrame(root.Position.X / BLOCK, root.Position.Z / BLOCK)
				marker.Position = UDim2.fromOffset(p.X, p.Y)
				marker.Visible = p.X >= 0 and p.Y >= 0 and p.X <= size and p.Y <= size
			elseif existing then
				existing.Visible = false
			end
		end
	end

	return { view = view, update = update }
end

return Minimap

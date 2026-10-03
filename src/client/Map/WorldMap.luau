--!strict
--[[
	Full screen world map (toggle with M or by clicking the minimap).

	  drag            move the map            scroll / + -    zoom around the cursor
	  right click     menu: add / remove waypoint, teleport here (if allowed), center here
	  (long press on touch, R3 on gamepad also open the menu)

	The map paints straight from the terrain generator, so it can show any part of the world,
	explored or not.
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Protocol = require(Shared.Net.Protocol)
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local ContextMenu = require(script.Parent.ContextMenu)
local MapLayer = require(script.Parent.MapLayer)
local MapView = require(script.Parent.MapView)
local Waypoints = require(script.Parent.Waypoints)

local BLOCK = Config.BlockSize
local ZOOMS = Config.Map.ZoomLevels
-- Image pixels across the map at most (the layer must be at least this + one tile wide).
local MAX_PIXELS = 768
local MIN_PIXELS = 256
local ZOOM_ACTION = "IceVoxelMapZoom"

export type WorldMap = {
	isOpen: () -> boolean,
	toggle: () -> (),
	update: () -> (),
}

local WorldMap = {}

WorldMap.MAX_PIXELS = MAX_PIXELS

local function canTeleport(): boolean
	local rule = Config.Map.Teleport
	if type(rule) == "table" then
		return table.find(rule, Players.LocalPlayer.UserId) ~= nil
	end
	return rule == true
end

local function button(parent: Instance, text: string, x: number): TextButton
	local b = Instance.new("TextButton")
	b.AnchorPoint = Vector2.new(1, 0)
	b.Position = UDim2.new(1, x, 0, 6)
	b.Size = UDim2.fromOffset(40, 28)
	b.BackgroundColor3 = Color3.fromRGB(44, 48, 58)
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamBold
	b.TextSize = 16
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Text = text
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = b
	b.Parent = parent
	return b
end

function WorldMap.new(
	gui: ScreenGui,
	layer: MapLayer.MapLayer,
	waypoints: Waypoints.Waypoints,
	generator: TerrainGenerator.Generator
): WorldMap
	local zoom = math.clamp(table.find(ZOOMS, 4) or 1, 1, #ZOOMS)
	local centerX, centerZ = 0, 0
	local following = true
	local open = false
	local dragging: Vector2? = nil

	local backdrop = Instance.new("Frame")
	backdrop.Name = "WorldMap"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	backdrop.BackgroundTransparency = 0.4
	backdrop.Visible = false
	backdrop.ZIndex = 20
	backdrop.Parent = gui

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.52)
	panel.Size = UDim2.fromScale(0.86, 0.86)
	panel.BackgroundColor3 = Color3.fromRGB(24, 28, 34)
	panel.ClipsDescendants = true
	panel.ZIndex = 21
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1
	aspect.Parent = panel
	panel.Parent = backdrop

	local view = MapView.new(panel, layer, MAX_PIXELS)
	for _, label in view.labels do
		label.ZIndex = 22
	end

	local markers = Instance.new("Frame")
	markers.Size = UDim2.fromScale(1, 1)
	markers.BackgroundTransparency = 1
	markers.ZIndex = 23
	markers.Parent = panel

	local player = Instance.new("TextLabel")
	player.AnchorPoint = Vector2.new(0.5, 0.5)
	player.Size = UDim2.fromOffset(22, 22)
	player.BackgroundTransparency = 1
	player.Font = Enum.Font.GothamBold
	player.TextSize = 22
	player.Text = "▲"
	player.TextColor3 = Color3.new(1, 1, 1)
	player.TextStrokeTransparency = 0
	player.ZIndex = 26
	player.Parent = markers

	-- Input catcher on top of the map. Modal frees the mouse in first person.
	local catcher = Instance.new("TextButton")
	catcher.Text = ""
	catcher.BackgroundTransparency = 1
	catcher.Size = UDim2.fromScale(1, 1)
	catcher.Modal = true
	catcher.ZIndex = 30
	catcher.Parent = panel

	local bar = Instance.new("Frame")
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.BackgroundTransparency = 1
	bar.ZIndex = 31
	bar.Parent = backdrop

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(0, 6)
	title.Size = UDim2.new(1, -200, 0, 28)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextStrokeTransparency = 0.5
	title.ZIndex = 31
	title.Parent = bar

	local close = button(bar, "✕", 0)
	local me = button(bar, "◎", -46)
	local zoomIn = button(bar, "+", -92)
	local zoomOut = button(bar, "−", -138)
	for _, b in { close, me, zoomIn, zoomOut } do
		b.ZIndex = 32
	end

	local waypointMarkers: { Frame } = {}

	local function newWaypointMarker(): Frame
		local marker = Instance.new("Frame")
		marker.AnchorPoint = Vector2.new(0.5, 0.5)
		marker.Size = UDim2.fromOffset(10, 10)
		marker.BorderSizePixel = 0
		marker.ZIndex = 24
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = marker
		local stroke = Instance.new("UIStroke")
		stroke.Parent = marker
		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.AnchorPoint = Vector2.new(0.5, 1)
		label.Position = UDim2.new(0.5, 0, 0, -2)
		label.Size = UDim2.fromOffset(160, 16)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextSize = 13
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextStrokeTransparency = 0.3
		label.ZIndex = 25
		label.Parent = marker
		marker.Parent = markers
		return marker
	end

	local function setZoom(index: number, around: Vector2?)
		index = math.clamp(index, 1, #ZOOMS)
		if index == zoom then
			return
		end
		-- Keep the world point under the cursor where it is.
		if around then
			local wx, wz = view:toWorld(around)
			local ratio = ZOOMS[index] / ZOOMS[zoom]
			centerX = wx + (centerX - wx) * ratio
			centerZ = wz + (centerZ - wz) * ratio
		end
		zoom = index
		layer:setScale(ZOOMS[zoom])
	end

	local function mouseInPanel(): Vector2
		local inset = GuiService:GetGuiInset()
		return UserInputService:GetMouseLocation() - inset - panel.AbsolutePosition
	end

	local function setOpen(value: boolean)
		if value == open then
			return
		end
		open = value
		backdrop.Visible = value
		dragging = nil
		ContextMenu.close()
		if value then
			following = true
			layer:setScale(ZOOMS[zoom])
			ContextActionService:BindActionAtPriority(ZOOM_ACTION, function(_, state, input)
				if state == Enum.UserInputState.Change then
					setZoom(zoom + (if input.Position.Z > 0 then -1 else 1), mouseInPanel())
				end
				return Enum.ContextActionResult.Sink
			end, false, Enum.ContextActionPriority.High.Value, Enum.UserInputType.MouseWheel)
		else
			ContextActionService:UnbindAction(ZOOM_ACTION)
		end
	end

	close.Activated:Connect(function()
		setOpen(false)
	end)
	me.Activated:Connect(function()
		following = true
	end)
	zoomIn.Activated:Connect(function()
		setZoom(zoom - 1, panel.AbsoluteSize / 2)
	end)
	zoomOut.Activated:Connect(function()
		setZoom(zoom + 1, panel.AbsoluteSize / 2)
	end)

	catcher.InputBegan:Connect(function(input)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
			dragging = Vector2.new(input.Position.X, input.Position.Y)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		local last = dragging
		local kind = input.UserInputType
		if last and (kind == Enum.UserInputType.MouseMovement or kind == Enum.UserInputType.Touch) then
			local now = Vector2.new(input.Position.X, input.Position.Y)
			local delta = now - last
			dragging = now
			if delta.Magnitude > 0 then
				following = false
				local blocksPerPixel = view.pixels * layer.scale / panel.AbsoluteSize.X
				centerX -= delta.X * blocksPerPixel
				centerZ -= delta.Y * blocksPerPixel
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
			dragging = nil
		end
	end)

	catcher.SecondaryActivated:Connect(function(input)
		dragging = nil
		local screen = Vector2.new(input.Position.X, input.Position.Y)
		local wx, wz = view:toWorld(screen - panel.AbsolutePosition)
		local x, z = math.floor(wx), math.floor(wz)
		local items: { ContextMenu.Item } = {
			{
				text = "Add waypoint here",
				action = function()
					ContextMenu.prompt(gui, "New waypoint", `Waypoint {#waypoints.list + 1}`, function(name)
						if name then
							waypoints:add(name, x, generator.column(x, z), z)
						end
					end)
				end,
			},
		}
		local radius = 10 * view.pixels * layer.scale / panel.AbsoluteSize.X
		local nearest = waypoints:nearest(wx, wz, radius)
		if nearest then
			local name = waypoints.list[nearest].name
			table.insert(items, {
				text = `Remove "{name}"`,
				action = function()
					waypoints:remove(nearest)
				end,
			})
		end
		if canTeleport() then
			table.insert(items, {
				text = "Teleport here",
				action = function()
					ClientNet.send(Protocol.ClientMessage.Teleport, Protocol.encodeTeleport(x, z))
					setOpen(false)
				end,
			})
		end
		table.insert(items, {
			text = "Center here",
			action = function()
				following = false
				centerX, centerZ = wx, wz
			end,
		})
		ContextMenu.show(gui, screen, items)
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.M then
			setOpen(not open)
		end
	end)

	local function update()
		if not open then
			return
		end
		-- Show as many image pixels as there are screen pixels (within limits) for a crisp map.
		view.pixels = math.clamp(math.floor(panel.AbsoluteSize.X / 2) * 2, MIN_PIXELS, MAX_PIXELS)

		local camera = workspace.CurrentCamera
		local character = Players.LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local position = if root and root:IsA("BasePart") then root.Position else camera.CFrame.Position
		if following then
			centerX, centerZ = position.X / BLOCK, position.Z / BLOCK
		end
		view:render(centerX, centerZ)

		local size = panel.AbsoluteSize
		bar.Position = UDim2.new(0.5, 0, 0.52, -size.Y / 2 - 4)
		bar.Size = UDim2.fromOffset(size.X, 40)

		local p = view:toFrame(position.X / BLOCK, position.Z / BLOCK)
		player.Position = UDim2.fromOffset(p.X, p.Y)
		local look = camera.CFrame.LookVector
		player.Rotation = math.deg(math.atan2(look.X, -look.Z))

		for i, waypoint in waypoints.list do
			local frame = waypointMarkers[i] or newWaypointMarker()
			waypointMarkers[i] = frame
			local q = view:toFrame(waypoint.x + 0.5, waypoint.z + 0.5)
			frame.Position = UDim2.fromOffset(q.X, q.Y)
			frame.BackgroundColor3 = Color3.fromRGB(waypoint.color[1], waypoint.color[2], waypoint.color[3])
			frame.Visible = true
			local label = frame:FindFirstChild("Label") :: TextLabel
			label.Text = waypoint.name
		end
		for i = #waypoints.list + 1, #waypointMarkers do
			waypointMarkers[i].Visible = false
		end

		local mouse = mouseInPanel()
		local hint = "drag to move · scroll to zoom · right click for options"
		if mouse.X >= 0 and mouse.Y >= 0 and mouse.X <= size.X and mouse.Y <= size.Y then
			local wx, wz = view:toWorld(mouse)
			title.Text = string.format("X %d   Z %d   1:%d   %s", math.floor(wx), math.floor(wz), layer.scale, hint)
		else
			title.Text = string.format("1:%d   %s", layer.scale, hint)
		end
		if not layer.available then
			title.Text = "Map images unavailable (enable Mesh / Image APIs) · right click still works"
		end
	end

	return {
		isOpen = function()
			return open
		end,
		toggle = function()
			setOpen(not open)
		end,
		update = update,
	}
end

return WorldMap

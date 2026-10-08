--!strict
--[[
	Minimap in the top right corner: terrain around the player (north up), the player's heading,
	waypoints (pinned to the edge when off the map) and other players (not spectators, unless this
	player spectates too: Player/SpectatorRules). Click it to open the world map; `-` / `=` zoom
	out / in (the Minimap Zoom Out / In key bindings, Settings/Keybinds). The cloud button in its
	bottom left corner (or the Weather Map key, B) shows the weather over it (Map/WeatherLayer:
	rain, snow, thunder and clouds, with the forecast step the world map picked and the wind in
	its top left corner). `setVisible` (the
	Minimap setting) hides it with its coordinates line; Map/init then
	stops updating it and painting its tiles. Hidden on a touch screen, a small "Map" button takes
	its corner: tapping the minimap is the only way to the world map there (M is a key).

	The centre and the coordinates line are where the player is in true world coordinates (the
	character, read through the render origin: Shared/World/Origin), the dots the other players
	Player/RemotePlayers knows of: with the server's own positions only those this client is sent
	(within Config.Interest.PlayerDistance), nobody beyond.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Origin = require(Shared.World.Origin)

local RemotePlayers = require(script.Parent.Parent.Player.RemotePlayers)
local SpectatorRules = require(script.Parent.Parent.Player.SpectatorRules)
local Keybinds = require(script.Parent.Parent.Settings.Keybinds)
local MapLayer = require(script.Parent.MapLayer)
local MapView = require(script.Parent.MapView)
local Waypoints = require(script.Parent.Waypoints)
local WeatherLayer = require(script.Parent.WeatherLayer)

local MAX_ZOOM = 16
-- Seconds between updates of the weather caption (the wind turns slowly).
local CAPTION_SECONDS = 0.5

export type Minimap = {
	view: MapView.MapView,
	update: () -> (),
	setVisible: (visible: boolean) -> (),
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
	-- The weather over the terrain, under the markers.
	local weather = WeatherLayer.new(view, Config.Weather.Map.MiniCells, 2)

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

	-- The world map's way in on touch screens while the minimap is hidden.
	local mapButton = Instance.new("TextButton")
	mapButton.Name = "MapButton"
	mapButton.AnchorPoint = Vector2.new(1, 0)
	mapButton.Position = UDim2.new(1, -16, 0, 16)
	mapButton.Size = UDim2.fromOffset(52, 32)
	mapButton.BackgroundColor3 = Color3.fromRGB(24, 28, 34)
	mapButton.BackgroundTransparency = 0.2
	mapButton.BorderSizePixel = 0
	mapButton.Font = Enum.Font.GothamBold
	mapButton.TextSize = 14
	mapButton.TextColor3 = Color3.new(1, 1, 1)
	mapButton.Text = "Map"
	mapButton.Visible = false
	local buttonStroke = Instance.new("UIStroke")
	buttonStroke.Thickness = 2
	buttonStroke.Color = Color3.fromRGB(12, 14, 18)
	buttonStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	buttonStroke.Parent = mapButton
	mapButton.Activated:Connect(openMap)
	mapButton.Parent = gui

	-- The weather mode's switch (bottom left, over the click that opens the world map) and its
	-- caption: the forecast step and the wind, with an arrow where it blows.
	local weatherButton = Instance.new("TextButton")
	weatherButton.Name = "WeatherButton"
	weatherButton.AnchorPoint = Vector2.new(0, 1)
	weatherButton.Position = UDim2.new(0, 4, 1, -4)
	weatherButton.Size = UDim2.fromOffset(24, 24)
	weatherButton.BackgroundColor3 = Color3.fromRGB(24, 28, 34)
	weatherButton.BackgroundTransparency = 0.25
	weatherButton.BorderSizePixel = 0
	weatherButton.Font = Enum.Font.GothamBold
	weatherButton.TextSize = 14
	weatherButton.TextColor3 = Color3.new(1, 1, 1)
	weatherButton.Text = "☁"
	weatherButton.ZIndex = 11
	weatherButton.Activated:Connect(WeatherLayer.toggle)
	weatherButton.Parent = holder
	local caption = Instance.new("TextLabel")
	caption.Name = "WeatherCaption"
	caption.Position = UDim2.fromOffset(24, 4)
	caption.Size = UDim2.new(1, -28, 0, 14)
	caption.BackgroundTransparency = 1
	caption.Font = Enum.Font.Code
	caption.TextSize = 12
	caption.TextXAlignment = Enum.TextXAlignment.Left
	caption.TextColor3 = Color3.new(1, 1, 1)
	caption.TextStrokeTransparency = 0.3
	caption.ZIndex = 7
	caption.Visible = false
	caption.Parent = holder
	local windArrow = Instance.new("TextLabel")
	windArrow.Name = "Wind"
	windArrow.Position = UDim2.fromOffset(6, 3)
	windArrow.Size = UDim2.fromOffset(16, 16)
	windArrow.BackgroundTransparency = 1
	windArrow.Font = Enum.Font.GothamBold
	windArrow.TextSize = 14
	windArrow.Text = "↑"
	windArrow.TextColor3 = Color3.fromRGB(180, 220, 255)
	windArrow.TextStrokeTransparency = 0.3
	windArrow.ZIndex = 7
	windArrow.Visible = false
	windArrow.Parent = holder
	local captionAt = -math.huge
	-- (A new step or the mode switched: the caption and the buttons follow at once.)
	WeatherLayer.changed:Connect(function()
		captionAt = -math.huge
	end)

	local waypointDots: { Frame } = {}
	local playerDots: { [Player]: Frame } = {}
	-- The players dotted this update (reused).
	local dotted: { [Player]: boolean } = {}

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not holder.Visible then
			return
		end
		if Keybinds.matches("zoomOut", input) and layer.scale < MAX_ZOOM then
			layer:setScale(layer.scale * 2)
		elseif Keybinds.matches("zoomIn", input) and layer.scale > 1 then
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
		-- (World blocks, doubles: the character or the camera, through the render origin.)
		local px, py, pz = Origin.renderToBlocks(if me then me.Position else camera.CFrame.Position)
		view:render(px, pz)
		weather:update()
		local weatherOn = WeatherLayer.isOn()
		caption.Visible = weatherOn
		windArrow.Visible = weatherOn
		weatherButton.BackgroundColor3 = if weatherOn then Color3.fromRGB(60, 96, 160) else Color3.fromRGB(24, 28, 34)
		if weatherOn and os.clock() - captionAt >= CAPTION_SECONDS then
			captionAt = os.clock()
			local stepText, windText, angle = WeatherLayer.caption()
			caption.Text = `{stepText}  {windText}`
			windArrow.Rotation = angle
		end

		local look = camera.CFrame.LookVector
		arrow.Rotation = math.deg(math.atan2(look.X, -look.Z))
		info.Text = string.format("%d, %d, %d   1:%d", math.floor(px), math.floor(py), math.floor(pz), layer.scale)

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

		local viewer = GameMode.of(Players.LocalPlayer)
		table.clear(dotted)
		for player, remote in RemotePlayers.each() do
			if SpectatorRules.sees(viewer, GameMode.of(player)) then
				local marker = playerDots[player] or dot(holder, 6, 5)
				marker.BackgroundColor3 = Color3.new(1, 1, 1)
				playerDots[player] = marker
				local p = view:toFrame(remote.x, remote.z)
				marker.Position = UDim2.fromOffset(p.X, p.Y)
				marker.Visible = p.X >= 0 and p.Y >= 0 and p.X <= size and p.Y <= size
				dotted[player] = true
			end
		end
		-- (Players no longer known of, or not seen, lose their dot.)
		for player, marker in playerDots do
			if not dotted[player] then
				marker.Visible = false
			end
		end
	end

	local function setVisible(visible: boolean)
		holder.Visible = visible
		info.Visible = visible
		mapButton.Visible = not visible and UserInputService.TouchEnabled
	end

	return { view = view, update = update, setVisible = setVisible }
end

return Minimap

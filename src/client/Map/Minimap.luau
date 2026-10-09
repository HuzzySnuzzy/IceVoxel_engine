--!strict
--[[
	Minimap in the top right corner: terrain around the player (north up), the player's heading,
	waypoints (pinned to the edge when off the map) and other players (not spectators, unless this
	player spectates too: Player/SpectatorRules). Click it to open the world map; `-` / `=` zoom
	out / in (the Minimap Zoom Out / In key bindings, Settings/Keybinds; the zoom shows in its
	bottom right corner). The cloud button in its bottom left corner (or the Weather Map key, B;
	on touch screens a tap anywhere in a finger-sized square there: HudLayout.touchSide) shows the
	weather over it (Map/WeatherLayer: rain, snow, thunder and clouds, with the forecast
	step the world map picked and the wind in its top left corner). `setVisible` (the Minimap
	setting) hides it with its coordinates line; Map/init then stops updating it and painting its
	tiles. Hidden on a touch screen, a small "Map" button takes its corner: tapping the minimap is
	the only way to the world map there (M is a key).

	It follows the GUI scale like the HUD: the map is Config.UiScale.Minimap (56) GUI pixels square
	(224 screen pixels at 1920 x 1080's Auto 4, 84 on a phone at 1.5) under a UIScale, its image
	still Config.Map.MinimapSize map pixels across (the same 384 blocks at 1:2), drawn Pixelated
	while magnified and smoothed while shrunk (MapView.setResample). The markers are placed as
	shares of the map (MapView.toFraction), so the UIScale never scales their places twice. The
	coordinates line under it is the HUD's pixel font with its shadow, right aligned; its width
	goes to Ui/UiScale (the toasts, effect icons and WAILA keep clear of it). Where everything goes
	is Ui/HudLayout's (through UiScale.hud, screen pixels: this draws in Map/init's whole-screen
	corner gui).

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
local Style = require(script.Parent.Parent.Ui.Style)
local UiScale = require(script.Parent.Parent.Ui.UiScale)
local HudLayout = require(script.Parent.Parent.Ui.HudLayout)
local HoverTip = require(script.Parent.Parent.Ui.HoverTip)
local MapLayer = require(script.Parent.MapLayer)
local MapView = require(script.Parent.MapView)
local Waypoints = require(script.Parent.Waypoints)
local WeatherLayer = require(script.Parent.WeatherLayer)

local MAX_ZOOM = 16
-- Seconds between updates of the weather caption (the wind turns slowly).
local CAPTION_SECONDS = 0.5
-- GUI pixels: the map's side, the arrow, the dots (waypoints, players), the weather button, the
-- small text (Code: the zoom, the weather caption, the "unavailable" note).
local SIZE = HudLayout.MINIMAP
local ARROW = 6
local WAYPOINT_DOT = 3
local PLAYER_DOT = 2
local WEATHER_BUTTON = 9
local SMALL_TEXT = 5
-- The coordinates line's width is rounded up to this many GUI pixels (the corner moves only when
-- the line grows past it).
local COORDS_STEP = 16

local BACKGROUND = Color3.fromRGB(24, 28, 34)
local OUTLINE = Color3.fromRGB(12, 14, 18)
local WEATHER_ON = Color3.fromRGB(60, 96, 160)

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
	stroke.Thickness = 0.5
	stroke.Parent = frame
	frame.Parent = parent
	return frame
end

-- A frame of `w` x `h` GUI pixels under a UIScale (placed by `place` from UiScale.hud).
local function scaled(parent: Instance, name: string, w: number, h: number): (Frame, UIScale)
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromOffset(w, h)
	local scale = Instance.new("UIScale")
	scale.Parent = frame
	frame.Parent = parent
	return frame, scale
end

local function smallText(parent: Instance, name: string, zIndex: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Code
	label.TextSize = SMALL_TEXT
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.3
	label.ZIndex = zIndex
	label.Parent = parent
	return label
end

function Minimap.new(
	gui: ScreenGui,
	layer: MapLayer.MapLayer,
	waypoints: Waypoints.Waypoints,
	openMap: () -> ()
): Minimap
	local holder, holderScale = scaled(gui, "Minimap", SIZE, SIZE)
	holder.BackgroundTransparency = 0
	holder.BackgroundColor3 = BACKGROUND
	holder.ClipsDescendants = true
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 0.5
	stroke.Color = OUTLINE
	stroke.Parent = holder

	local view = MapView.new(holder, layer, Config.Map.MinimapSize)
	-- The weather over the terrain, under the markers.
	local weather = WeatherLayer.new(view, Config.Weather.Map.MiniCells, 2)

	local arrow = Instance.new("TextLabel")
	arrow.AnchorPoint = Vector2.new(0.5, 0.5)
	arrow.Position = UDim2.fromScale(0.5, 0.5)
	arrow.Size = UDim2.fromOffset(ARROW, ARROW)
	arrow.BackgroundTransparency = 1
	arrow.Font = Enum.Font.GothamBold
	arrow.TextSize = ARROW
	arrow.Text = "▲"
	arrow.TextColor3 = Color3.new(1, 1, 1)
	arrow.TextStrokeTransparency = 0
	arrow.ZIndex = 6
	arrow.Parent = holder

	-- The zoom, bottom right inside the map.
	local zoom = smallText(holder, "Zoom", 7)
	zoom.AnchorPoint = Vector2.new(1, 1)
	zoom.Position = UDim2.new(1, -1, 1, 0)
	zoom.Size = UDim2.fromOffset(20, SMALL_TEXT + 1)
	zoom.TextXAlignment = Enum.TextXAlignment.Right

	-- The coordinates line (the HUD's pixel font), right aligned under the map.
	local coordsWidth = SIZE
	local coords, coordsScale = scaled(gui, "Coordinates", coordsWidth, HudLayout.COORDS_HEIGHT)
	local info, infoShadow = Style.shadowText(
		coords,
		"",
		0,
		1,
		coordsWidth,
		Style.TEXT_SIZE,
		Style.Colour.Text,
		1,
		Enum.TextXAlignment.Right
	)
	-- The text's length when its width was last measured.
	local measuredLength = -1

	if not layer.available then
		local note = smallText(holder, "Unavailable", 2)
		note.Size = UDim2.fromScale(1, 1)
		note.Font = Enum.Font.Gotham
		note.TextWrapped = true
		note.TextColor3 = Color3.fromRGB(150, 155, 165)
		note.TextStrokeTransparency = 1
		note.Text = "Map images unavailable\n(enable Mesh / Image APIs)"
	end

	local open = Instance.new("TextButton")
	open.Text = ""
	open.BackgroundTransparency = 1
	open.Size = UDim2.fromScale(1, 1)
	open.ZIndex = 10
	open.Activated:Connect(openMap)
	open.Parent = holder
	HoverTip.attach(open, "map.open")

	-- The world map's way in on touch screens while the minimap is hidden.
	local mapButton = Instance.new("TextButton")
	mapButton.Name = "MapButton"
	mapButton.Size = UDim2.fromOffset(HudLayout.MAP_BUTTON_WIDTH, HudLayout.MAP_BUTTON_HEIGHT)
	mapButton.BackgroundColor3 = BACKGROUND
	mapButton.BackgroundTransparency = 0.2
	mapButton.BorderSizePixel = 0
	mapButton.Font = Enum.Font.GothamBold
	mapButton.TextSize = 8
	mapButton.TextColor3 = Color3.new(1, 1, 1)
	mapButton.Text = "Map"
	mapButton.Visible = false
	local mapButtonScale = Instance.new("UIScale")
	mapButtonScale.Parent = mapButton
	local buttonStroke = Instance.new("UIStroke")
	buttonStroke.Thickness = 0.5
	buttonStroke.Color = OUTLINE
	buttonStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	buttonStroke.Parent = mapButton
	mapButton.Activated:Connect(openMap)
	mapButton.Parent = gui
	HoverTip.attach(mapButton, "map.open")

	-- The weather mode's switch (bottom left, over the click that opens the world map) and its
	-- caption: the forecast step and the wind, with an arrow where it blows. The switch drawn is
	-- WEATHER_BUTTON square; what a tap hits is a finger's size on touch screens
	-- (HudLayout.touchSide: `place`), so a tap meant for it doesn't open the world map.
	local weatherHit = Instance.new("TextButton")
	weatherHit.Name = "WeatherButton"
	weatherHit.Text = ""
	weatherHit.AutoButtonColor = false
	weatherHit.BackgroundTransparency = 1
	weatherHit.AnchorPoint = Vector2.new(0, 1)
	weatherHit.Position = UDim2.fromScale(0, 1)
	weatherHit.Size = UDim2.fromOffset(WEATHER_BUTTON + 2, WEATHER_BUTTON + 2)
	weatherHit.ZIndex = 11
	weatherHit.Activated:Connect(WeatherLayer.toggle)
	weatherHit.Parent = holder
	HoverTip.attach(weatherHit, "map.weather")
	local weatherButton = Instance.new("TextLabel")
	weatherButton.Name = "Cloud"
	weatherButton.AnchorPoint = Vector2.new(0, 1)
	weatherButton.Position = UDim2.new(0, 1, 1, -1)
	weatherButton.Size = UDim2.fromOffset(WEATHER_BUTTON, WEATHER_BUTTON)
	weatherButton.BackgroundColor3 = BACKGROUND
	weatherButton.BackgroundTransparency = 0.25
	weatherButton.BorderSizePixel = 0
	weatherButton.Font = Enum.Font.GothamBold
	weatherButton.TextSize = WEATHER_BUTTON - 3
	weatherButton.TextColor3 = Color3.new(1, 1, 1)
	weatherButton.Text = "☁"
	weatherButton.ZIndex = 11
	weatherButton.Parent = weatherHit
	local caption = smallText(holder, "WeatherCaption", 7)
	caption.Position = UDim2.fromOffset(8, 1)
	caption.Size = UDim2.new(1, -9, 0, SMALL_TEXT + 1)
	caption.TextXAlignment = Enum.TextXAlignment.Left
	caption.Visible = false
	local windArrow = smallText(holder, "Wind", 7)
	windArrow.Font = Enum.Font.GothamBold
	windArrow.Position = UDim2.fromOffset(1, 1)
	windArrow.Size = UDim2.fromOffset(SMALL_TEXT + 1, SMALL_TEXT + 1)
	windArrow.Text = "↑"
	windArrow.TextColor3 = Color3.fromRGB(180, 220, 255)
	windArrow.Visible = false
	local captionAt = -math.huge
	-- (A new step or the mode switched: the caption and the buttons follow at once.)
	WeatherLayer.changed:Connect(function()
		captionAt = -math.huge
	end)

	local waypointDots: { Frame } = {}
	local playerDots: { [Player]: Frame } = {}
	-- The players dotted this update (reused).
	local dotted: { [Player]: boolean } = {}
	local visible = true
	local shownZoom = 0

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

	-- Where Ui/HudLayout puts the map, its line and the Map button (screen pixels), at its scale.
	local function place()
		local layout = UiScale.hud()
		local scale = layout.scale
		local map, line, button = layout.minimap, layout.coords, layout.mapButton
		holder.Visible = visible and map ~= nil
		coords.Visible = visible and line ~= nil
		mapButton.Visible = button ~= nil
		for _, piece in { holderScale, coordsScale, mapButtonScale } do
			if piece.Scale ~= scale then
				piece.Scale = scale
			end
		end
		-- (Touch: the buttons a finger's size, HudLayout.mapButtonSize / touchSide.)
		local hitSide = WEATHER_BUTTON + 2
		if UiScale.touch() then
			hitSide = HudLayout.touchSide(hitSide, scale)
		end
		if weatherHit.Size.X.Offset ~= hitSide then
			weatherHit.Size = UDim2.fromOffset(hitSide, hitSide)
		end
		if button then
			local size = UDim2.fromOffset(button.w / scale, button.h / scale)
			if mapButton.Size ~= size then
				mapButton.Size = size
			end
		end
		if map then
			holder.Position = UDim2.fromOffset(map.x, map.y)
			view:setResample(map.w)
		end
		if line then
			coords.Position = UDim2.fromOffset(line.x, line.y)
		end
		if button then
			mapButton.Position = UDim2.fromOffset(button.x, button.y)
		end
	end
	UiScale.hudChanged:Connect(place)

	-- The coordinates line's text, and its width to Ui/UiScale when its length changed.
	local function setCoordinates(text: string)
		if text == info.Text then
			return
		end
		info.Text, infoShadow.Text = text, text
		if #text ~= measuredLength then
			measuredLength = #text
			local width = math.max(SIZE, math.ceil((Style.textWidth(text) + 1) / COORDS_STEP) * COORDS_STEP)
			if width ~= coordsWidth then
				coordsWidth = width
				coords.Size = UDim2.fromOffset(width, HudLayout.COORDS_HEIGHT)
				info.Size = UDim2.fromOffset(width, Style.TEXT_SIZE)
				infoShadow.Size = UDim2.fromOffset(width, Style.TEXT_SIZE)
				UiScale.setMinimap(visible, coordsWidth)
			end
		end
	end

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
		weatherButton.BackgroundColor3 = if weatherOn then WEATHER_ON else BACKGROUND
		if weatherOn and os.clock() - captionAt >= CAPTION_SECONDS then
			captionAt = os.clock()
			local stepText, windText, angle = WeatherLayer.caption()
			caption.Text = `{stepText}  {windText}`
			windArrow.Rotation = angle
		end

		local look = camera.CFrame.LookVector
		arrow.Rotation = math.deg(math.atan2(look.X, -look.Z))
		setCoordinates(string.format("%d, %d, %d", math.floor(px), math.floor(py), math.floor(pz)))
		if layer.scale ~= shownZoom then
			shownZoom = layer.scale
			zoom.Text = `1:{shownZoom}`
		end

		-- Waypoints, pinned to the border when outside (shares of the map: see the header).
		local edge = (WAYPOINT_DOT / 2 + 0.5) / SIZE
		for i, waypoint in waypoints.list do
			local marker = waypointDots[i] or dot(holder, WAYPOINT_DOT, 4)
			waypointDots[i] = marker
			local u, v = view:toFraction(waypoint.x + 0.5, waypoint.z + 0.5)
			marker.Position = UDim2.fromScale(math.clamp(u, edge, 1 - edge), math.clamp(v, edge, 1 - edge))
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
				local marker = playerDots[player] or dot(holder, PLAYER_DOT, 5)
				marker.BackgroundColor3 = Color3.new(1, 1, 1)
				playerDots[player] = marker
				local u, v = view:toFraction(remote.x, remote.z)
				marker.Position = UDim2.fromScale(u, v)
				marker.Visible = u >= 0 and v >= 0 and u <= 1 and v <= 1
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

	local function setVisible(value: boolean)
		visible = value
		UiScale.setMinimap(value, coordsWidth)
		place()
	end

	place()
	return { view = view, update = update, setVisible = setVisible }
end

return Minimap

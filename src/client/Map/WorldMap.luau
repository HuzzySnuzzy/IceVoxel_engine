--!strict
--[[
	Full screen world map (toggle with M, the World Map key binding, or by clicking the minimap).

	  drag            move the map            scroll / + -    zoom around the cursor
	  right click     menu: add / remove waypoint, teleport here (if allowed), center here
	  (long press on touch, R3 on gamepad also open the menu)
	  ☁ / B           the weather over the map (Map/WeatherLayer: rain blue, snow white, thunder
	                  purple with yellow lightning, clouds grey), with the forecast buttons (Now,
	                  +2, +5, +10, +20 minutes), the wind and a legend along the bottom

	The bar's buttons and the forecast steps say what they do when hovered or long pressed
	(Ui/HoverTip, Ui/ButtonHelp's "map.*").

	The map paints straight from the terrain generator, so it can show any part of the world,
	explored or not. Its centre and the player's arrow are in true world coordinates (the
	character, read through the render origin: Shared/World/Origin). While it is open the screen
	hides a move of the render origin (Rendering/Rebase.setHidden "map").

	The panel and its image are a share of the screen (86 % of its height, square); the chrome
	around them (the bar with its title and buttons, the weather bar, the player's arrow, the
	waypoints' dots and names, the right-click menu: Map/ContextMenu) is drawn in pixels of
	1080p's Auto and scaled by Ui/UiScale.reference (the GUI scale / 4, at least 0.75), so it grows
	on a 4K screen and stays readable on a phone. Markers are placed as shares of the panel
	(MapView.toFraction).
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Origin = require(Shared.World.Origin)
local Protocol = require(Shared.Net.Protocol)
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local Rebase = require(script.Parent.Parent.Rendering.Rebase)
local ContextMenu = require(script.Parent.ContextMenu)
local MapLayer = require(script.Parent.MapLayer)
local MapView = require(script.Parent.MapView)
local Waypoints = require(script.Parent.Waypoints)
local WeatherLayer = require(script.Parent.WeatherLayer)
local WeatherMap = require(script.Parent.WeatherMap)
local Screens = require(script.Parent.Parent.Ui.Screens)
local HoverTip = require(script.Parent.Parent.Ui.HoverTip)
local Hud = require(script.Parent.Parent.Ui.Hud)
local UiScale = require(script.Parent.Parent.Ui.UiScale)
local Keybinds = require(script.Parent.Parent.Settings.Keybinds)

local ZOOMS = Config.Map.ZoomLevels
-- Image pixels across the map at most (the layer must be at least this + one tile wide).
local MAX_PIXELS = 768
local MIN_PIXELS = 256
-- The weather mode's wind arrow, by where the wind blows (north first, clockwise).
local WIND_ARROWS = { "↑", "↗", "→", "↘", "↓", "↙", "←", "↖" }
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
	-- Where the drag was last seen, and the input moving it (the touch, or nil for the mouse).
	local dragging: Vector2? = nil
	local dragInput: InputObject? = nil

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
	-- The weather over the terrain, under the markers.
	local weather = WeatherLayer.new(view, Config.Weather.Map.WorldCells, 23)

	local markers = Instance.new("Frame")
	markers.Size = UDim2.fromScale(1, 1)
	markers.BackgroundTransparency = 1
	markers.ZIndex = 24
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
	-- The chrome's scales (UiScale.reference), set by `restyle`.
	local chromeScales: { UIScale } = {}
	local function chromeScale(object: GuiObject)
		local scale = Instance.new("UIScale")
		scale.Scale = UiScale.reference()
		scale.Parent = object
		table.insert(chromeScales, scale)
	end
	chromeScale(player)

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
	chromeScale(bar)

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(0, 6)
	title.Size = UDim2.new(1, -246, 0, 28)
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
	local cloud = button(bar, "☁", -184)
	for _, b in { close, me, zoomIn, zoomOut, cloud } do
		b.ZIndex = 32
	end
	HoverTip.attach(close, "map.close")
	HoverTip.attach(me, "map.centre")
	HoverTip.attach(zoomIn, "map.zoomIn")
	HoverTip.attach(zoomOut, "map.zoomOut")
	HoverTip.attach(cloud, "map.weather")
	cloud.Activated:Connect(WeatherLayer.toggle)

	-- The weather mode's bar along the bottom of the map, two rows sized by the map's width (so it
	-- fits a phone's): the forecast steps, then the wind and the legend (over the input catcher, so
	-- its buttons get the clicks).
	local weatherBar = Instance.new("Frame")
	weatherBar.Name = "WeatherBar"
	weatherBar.AnchorPoint = Vector2.new(0, 1)
	weatherBar.Position = UDim2.new(0, 6, 1, -6)
	-- (As wide as the panel less 6 on each side, in GUI pixels under its scale: `restyle`.)
	weatherBar.Size = UDim2.fromOffset(0, 52)
	weatherBar.BackgroundColor3 = Color3.fromRGB(24, 28, 34)
	weatherBar.BackgroundTransparency = 0.25
	weatherBar.BorderSizePixel = 0
	weatherBar.ZIndex = 31
	weatherBar.Visible = false
	weatherBar.Parent = panel
	chromeScale(weatherBar)
	local function row(top: number): Frame
		local frame = Instance.new("Frame")
		frame.BackgroundTransparency = 1
		frame.Position = UDim2.fromOffset(2, top)
		frame.Size = UDim2.new(1, -4, 0, 22)
		frame.ZIndex = 32
		frame.Parent = weatherBar
		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.Padding = UDim.new(0, 4)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = frame
		return frame
	end
	-- (Fixed sizes under the bar's UIScale; a label too long for its share is cut with "...".)
	local function fit(text: GuiObject, size: number)
		(text :: any).TextSize = size;
		(text :: any).TextTruncate = Enum.TextTruncate.AtEnd
	end
	local stepsRow = row(3)
	local infoRow = row(27)
	local stepButtons: { TextButton } = {}
	local steps = #WeatherMap.LABELS
	for index, text in WeatherMap.LABELS do
		local stepButton = Instance.new("TextButton")
		stepButton.LayoutOrder = index
		stepButton.Size = UDim2.new(1 / steps, -4, 1, 0)
		stepButton.BackgroundColor3 = Color3.fromRGB(44, 48, 58)
		stepButton.BorderSizePixel = 0
		stepButton.Font = Enum.Font.GothamBold
		stepButton.TextColor3 = Color3.new(1, 1, 1)
		stepButton.Text = text
		stepButton.ZIndex = 33
		fit(stepButton, 12)
		stepButton.Activated:Connect(function()
			WeatherLayer.setStep(index)
		end)
		stepButton.Parent = stepsRow
		stepButtons[index] = stepButton
		HoverTip.attach(stepButton, "map.forecast", tostring(index))
	end
	local windLabel = Instance.new("TextLabel")
	windLabel.LayoutOrder = 0
	windLabel.Size = UDim2.new(0.32, -4, 1, 0)
	windLabel.BackgroundTransparency = 1
	windLabel.Font = Enum.Font.Code
	windLabel.TextColor3 = Color3.fromRGB(180, 220, 255)
	windLabel.TextXAlignment = Enum.TextXAlignment.Left
	windLabel.ZIndex = 33
	fit(windLabel, 13)
	windLabel.Parent = infoRow
	for index, entry in WeatherMap.LEGEND do
		local swatch = Instance.new("TextLabel")
		swatch.LayoutOrder = index
		swatch.Size = UDim2.new(0.68 / #WeatherMap.LEGEND, -4, 1, 0)
		swatch.BackgroundTransparency = 1
		swatch.Font = Enum.Font.Gotham
		swatch.TextColor3 = Color3.fromRGB(entry.colour[1], entry.colour[2], entry.colour[3])
		swatch.TextStrokeTransparency = 0.4
		swatch.Text = `■ {entry.name}`
		swatch.ZIndex = 33
		fit(swatch, 12)
		swatch.Parent = infoRow
	end
	local captionAt = -math.huge
	-- (A new step or the mode switched: the caption and the buttons follow at once.)
	WeatherLayer.changed:Connect(function()
		captionAt = -math.huge
	end)

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
		chromeScale(marker)
		marker.Parent = markers
		return marker
	end

	-- Zooms keeping the world point at `around` (frame pixels) in place; nil keeps the center.
	local function setZoom(index: number, around: Vector2?)
		index = math.clamp(index, 1, #ZOOMS)
		if index == zoom then
			return
		end
		if around then
			local wx, wz = view:toWorld(around)
			local ratio = ZOOMS[index] / ZOOMS[zoom]
			centerX = wx + (centerX - wx) * ratio
			centerZ = wz + (centerZ - wz) * ratio
			following = false
		end
		zoom = index
		layer:setScale(ZOOMS[zoom])
		-- Keep toWorld right for input arriving before the next render.
		view:setCenter(centerX, centerZ)
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
		-- The map and the HUD / inventory screens are never on screen together.
		Hud.setVisible(not value)
		-- (It covers the screen: the render origin may move meanwhile.)
		Rebase.setHidden("map", value)
		dragging, dragInput = nil, nil
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
	Screens.changed:Connect(function(isOpen: boolean)
		if isOpen then
			setOpen(false)
		end
	end)

	close.Activated:Connect(function()
		setOpen(false)
	end)
	me.Activated:Connect(function()
		following = true
	end)
	zoomIn.Activated:Connect(function()
		setZoom(zoom - 1)
	end)
	zoomOut.Activated:Connect(function()
		setZoom(zoom + 1)
	end)

	catcher.InputBegan:Connect(function(input: InputObject)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseButton1 or (kind == Enum.UserInputType.Touch and dragInput == nil) then
			dragging = Vector2.new(input.Position.X, input.Position.Y)
			dragInput = if kind == Enum.UserInputType.Touch then input else nil
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		local last = dragging
		if last == nil then
			return
		end
		local moved = if dragInput then input == dragInput else input.UserInputType == Enum.UserInputType.MouseMovement
		if moved then
			local now = Vector2.new(input.Position.X, input.Position.Y)
			local delta = now - last
			dragging = now
			if delta.Magnitude > 0 then
				following = false
				local blocksPerPixel = view.pixels * layer.scale / panel.AbsoluteSize.X
				centerX -= delta.X * blocksPerPixel
				centerZ -= delta.Y * blocksPerPixel
				view:setCenter(centerX, centerZ)
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		local ended = if dragInput then input == dragInput else input.UserInputType == Enum.UserInputType.MouseButton1
		if ended then
			dragging, dragInput = nil, nil
		end
	end)

	catcher.SecondaryActivated:Connect(function(input)
		dragging, dragInput = nil, nil
		-- A gamepad has no pointer here: use the middle of the map.
		local screen = if input.UserInputType.Name:sub(1, 7) == "Gamepad"
			then panel.AbsolutePosition + panel.AbsoluteSize / 2
			else Vector2.new(input.Position.X, input.Position.Y)
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
				view:setCenter(centerX, centerZ)
			end,
		})
		ContextMenu.show(gui, screen, items)
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		-- (The World Map key binding, M by default.)
		if not processed and Keybinds.matches("worldMap", input) and not Screens.isOpen() then
			setOpen(not open)
		end
	end)

	-- The chrome at UiScale.reference: its scales, and the bars as wide as the panel on screen.
	local chromeFor = Vector2.zero
	local function restyle()
		local reference = UiScale.reference()
		for _, scale in chromeScales do
			if scale.Scale ~= reference then
				scale.Scale = reference
			end
		end
		local size = panel.AbsoluteSize
		bar.Position = UDim2.new(0.5, 0, 0.52, -size.Y / 2 - 4)
		bar.Size = UDim2.fromOffset(size.X / reference, 40)
		weatherBar.Size = UDim2.fromOffset((size.X - 12) / reference, 52)
		view:setResample(size.X)
	end
	UiScale.follow(restyle)

	local function update()
		if not open then
			return
		end
		-- Show as many image pixels as there are screen pixels (within limits) for a crisp map.
		view.pixels = math.clamp(math.floor(panel.AbsoluteSize.X / 2) * 2, MIN_PIXELS, MAX_PIXELS)

		local camera = workspace.CurrentCamera
		local character = Players.LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		-- (World blocks, doubles: the character or the camera, through the render origin.)
		local px, _, pz =
			Origin.renderToBlocks(if root and root:IsA("BasePart") then root.Position else camera.CFrame.Position)
		if following then
			centerX, centerZ = px, pz
		end
		view:render(centerX, centerZ)
		weather:update()
		local weatherOn = WeatherLayer.isOn()
		weatherBar.Visible = weatherOn
		cloud.BackgroundColor3 = if weatherOn then Color3.fromRGB(60, 96, 160) else Color3.fromRGB(44, 48, 58)
		if weatherOn and os.clock() - captionAt >= 0.5 then
			captionAt = os.clock()
			local _, windText, angle = WeatherLayer.caption()
			windLabel.Text = `{WIND_ARROWS[math.floor(angle / 45 + 0.5) % 8 + 1]} wind {windText}`
			for index, stepButton in stepButtons do
				stepButton.BackgroundColor3 = if index == WeatherLayer.step()
					then Color3.fromRGB(60, 96, 160)
					else Color3.fromRGB(44, 48, 58)
			end
		end

		local size = panel.AbsoluteSize
		if size ~= chromeFor then
			chromeFor = size
			restyle()
		end

		local u, v = view:toFraction(px, pz)
		player.Position = UDim2.fromScale(u, v)
		local look = camera.CFrame.LookVector
		player.Rotation = math.deg(math.atan2(look.X, -look.Z))

		for i, waypoint in waypoints.list do
			local frame = waypointMarkers[i] or newWaypointMarker()
			waypointMarkers[i] = frame
			local wu, wv = view:toFraction(waypoint.x + 0.5, waypoint.z + 0.5)
			frame.Position = UDim2.fromScale(wu, wv)
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
			-- (Never over an inventory screen, like the M key.)
			if open or not Screens.isOpen() then
				setOpen(not open)
			end
		end,
		update = update,
	}
end

return WorldMap

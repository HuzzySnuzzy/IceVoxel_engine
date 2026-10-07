--!strict
--[[
	The title screen (Minecraft's TitleScreen) and its Create World screen (CreateWorldScreen,
	simplified), in this game's UI style (Ui/Style, Ui/FormWidgets). Shown when the player joins,
	over everything, until they enter the world; the client boot waits on `run` (Config.MainMenu
	.Enabled; off, it returns at once). The rules: Ui/TitleRules, Ui/CreateWorldForm,
	Shared/WorldSettings; the server's side: Players/WorldMenu.

	  Why first  nothing of the game starts behind the title screen: the boot holds every module
	             (streaming, the HUD, the inventory, interaction, the camera's controls) until
	             `run` returns, so no key reaches them and no terrain loads. Entering is Minecraft
	             joining a server: "Join World" (or a created world) starts the client, the server
	             loads the character, and the terrain loads around the spawn as on any join
	             (the movement waits for the ground). The server holds the character until then
	             (Players/WorldMenu), so a player on the title screen is nowhere in the world.
	  Title      the logo ("ICEVOXEL" in pixel blocks: an icy face over a dark blue extrusion,
	             LOGO_PIXEL GUI pixels a block, as Minecraft's stone letters), the edition line, a
	             yellow splash turned -20 degrees and pulsing (TitleRules), and Minecraft's
	             column of 200 x 20 buttons from a quarter down + 48: Join World (once the world
	             exists), Create World (operators, while there is none), Load World (disabled:
	             worlds aren't saved yet, coming later), Options... (the Options menu,
	             Ui/SettingsScreen.showIn, Done comes back here); the status line under them
	             (waiting for the operator, being created, ready); Config.MainMenu.Version
	             bottom left and Credits bottom right.
	  Panorama   there is no world to turn around yet, so the background is a moving sky:
	             Minecraft's day sky blue, blocky clouds drifting, far snow-capped mountains and
	             near grass hills sliding by at different speeds (parallax), each layer two
	             screens wide holding its pattern twice, so moving it by one screen loops it.
	             Three positions change a frame; nothing is built after the screen is.
	  Create     two tabs (Game: World Name, Game Mode, Difficulty, Allow Commands; World: World
	             Type with its description and Customize when the type declares settings, the
	             seed, Generate Structures), then Create New World / Cancel. Creating shows
	             "Creating the world..." until the server answers (CreateWorldResult): the world
	             is entered, or the screen comes back with the server's reason in red.
	  Customize  one widget per setting the world type declares (WorldTypes.Setting), drawn
	             generically: toggles and choices are buttons that cycle, text a field.
	  Sub-screens (Create, Customize, Options, creating) sit on Minecraft's options background:
	             the dirt texture (TexturePack "dirt") tiled 32 GUI pixels a tile at a quarter of
	             its brightness (Minecraft's 64 / 255), or plain dark brown without one.
	  Input      mouse, touch, gamepad (A presses, the selection starts on the first button);
	             Escape / B go back a screen. The GUI scale is Minecraft's (Style.guiScale for 320
	             x 240), laid out again when the window changes.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Protocol = require(Shared.Net.Protocol)
local TexturePack = require(Shared.TexturePack)
local WorldSettings = require(Shared.WorldSettings)
local WorldTypes = require(Shared.Generation.WorldTypes)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local CreateWorldForm = require(script.Parent.CreateWorldForm)
local FormWidgets = require(script.Parent.FormWidgets)
local SettingsScreen = require(script.Parent.SettingsScreen)
local Style = require(script.Parent.Style)
local TitleRules = require(script.Parent.TitleRules)

-- Over everything else (the HUD and screens are 1..20).
local DISPLAY_ORDER = 100
-- GUI pixels a block of the logo, and its extrusion.
local LOGO_PIXEL = 5
local LOGO_DEPTH = 3
-- Minecraft's buttons: 200 x 20, a row every 24.
local BUTTON_W = 200
local BUTTON_H = 20
local ROW = 24
-- Columns of the panorama's hills per screen, and how fast each layer slides (screens a second).
local COLUMNS = 48
local FAR_SPEED = 0.004
local NEAR_SPEED = 0.01
local CLOUD_SPEED = 0.006
-- Minecraft's options background: the dirt at 64 / 255.
local DIRT_DARKEN = 64 / 255
local DIRT_TILE = 32

-- Colours: Minecraft's day sky and fog, BlockList's Grass and Dirt, far rock and snow.
local SKY_TOP = Color3.fromRGB(120, 167, 255)
local SKY_BOTTOM = Color3.fromRGB(192, 216, 255)
local GRASS = Color3.fromRGB(92, 158, 62)
local GRASS_LIGHT = Color3.fromRGB(118, 182, 80)
local DIRT = Color3.fromRGB(121, 85, 58)
local FAR_ROCK = Color3.fromRGB(128, 146, 178)
local FAR_SNOW = Color3.fromRGB(232, 238, 250)
local SUN = Color3.fromRGB(255, 250, 200)
local LOGO_COLOURS = {
	W = Color3.fromRGB(245, 252, 255),
	F = Color3.fromRGB(190, 228, 250),
	S = Color3.fromRGB(128, 186, 228),
	D = Color3.fromRGB(28, 52, 92),
}
local WHITE = Color3.fromRGB(255, 255, 255)
local GRAY = Color3.fromRGB(160, 160, 160)

-- The logo's letters (5 to 6 blocks wide, 7 tall; "#" a block).
local LETTERS: { [string]: { string } } = {
	I = { "####", ".##.", ".##.", ".##.", ".##.", ".##.", "####" },
	C = { ".#####", "##....", "##....", "##....", "##....", "##....", ".#####" },
	E = { "######", "##....", "##....", "#####.", "##....", "##....", "######" },
	V = { "##..##", "##..##", "##..##", "##..##", ".####.", ".####.", "..##.." },
	O = { ".####.", "##..##", "##..##", "##..##", "##..##", "##..##", ".####." },
	X = { "##..##", "##..##", ".####.", "..##..", ".####.", "##..##", "##..##" },
	L = { "##....", "##....", "##....", "##....", "##....", "##....", "######" },
}
local LOGO_TEXT = "ICEVOXEL"
local EDITION = "ROBLOX EDITION"

type Page = "title" | "create" | "customize" | "options" | "creating"

local MainMenu = {}

local entered = false
local enteredEvent = Instance.new("BindableEvent")

-- Is the title screen up (between `run` starting and the player entering)?
local shown = false
function MainMenu.isShown(): boolean
	return shown
end

--[[ Building blocks ]]

-- A frame placed by scale and offset (the pages' columns follow the scaled screen's size).
local function place(parent: Instance, position: UDim2, size: UDim2, z: number?): Frame
	local frame = Instance.new("Frame")
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Position = position
	frame.Size = size
	frame.ZIndex = z or 1
	frame.Parent = parent
	return frame
end

-- Wrapped centred text with Minecraft's shadow, `lines` lines tall; returns its setter.
local function infoText(parent: Instance, x: number, y: number, w: number, lines: number): (string, Color3?) -> ()
	local h = lines * (Style.TEXT_SIZE + 2)
	local label, shadow = Style.shadowText(parent, "", x, y, w, h, GRAY, 5, Enum.TextXAlignment.Center, Style.TEXT_SIZE)
	label.TextWrapped = true
	shadow.TextWrapped = true
	return function(text: string, colour: Color3?)
		label.Text = text
		shadow.Text = text
		if colour then
			label.TextColor3 = colour
			shadow.TextColor3 = Style.shadowOf(colour)
		end
	end
end

-- The logo, its top left at (x, y) of `parent`; returns its width and height (GUI pixels).
local function buildLogo(parent: Instance, x: number, y: number): (number, number)
	local cursor = x
	for i = 1, #LOGO_TEXT do
		local rows = LETTERS[string.sub(LOGO_TEXT, i, i)]
		local depth: { string } = {}
		local face: { string } = {}
		for row, line in rows do
			-- Lit top, the face, a shaded bottom: Minecraft's letters catch the light from above.
			local shade = if row == 1 then "W" elseif row <= 4 then "F" else "S"
			table.insert(depth, (string.gsub(line, "#", "D")))
			table.insert(face, (string.gsub(line, "#", shade)))
		end
		Style.pixelArt(parent, cursor + LOGO_DEPTH, y + LOGO_DEPTH, depth, LOGO_COLOURS, 6, LOGO_PIXEL)
		Style.pixelArt(parent, cursor, y, face, LOGO_COLOURS, 7, LOGO_PIXEL)
		cursor += (#rows[1] + 1) * LOGO_PIXEL
	end
	return cursor - x - LOGO_PIXEL + LOGO_DEPTH, 7 * LOGO_PIXEL + LOGO_DEPTH
end

-- Heights (0..1, in steps of 1 / `steps`) of COLUMNS columns from whole-period waves, so the
-- pattern's end joins its start.
local function profile(waves: { { number } }, base: number, steps: number): { number }
	local heights = {}
	for i = 0, COLUMNS - 1 do
		local h = base
		for _, wave in waves do
			h += wave[2] * math.sin(2 * math.pi * wave[1] * i / COLUMNS + wave[3])
		end
		heights[i + 1] = math.clamp(math.floor(h * steps + 0.5) / steps, 0, 1)
	end
	return heights
end

-- One panorama layer: two screens wide, `heights` drawn twice (runs of equal columns merged).
local function hills(parent: Instance, heights: { number }, top: Color3, body: Color3, cap: number, z: number): Frame
	local layer = place(parent, UDim2.fromScale(0, 0), UDim2.fromScale(2, 1), z)
	local width = 1 / (2 * COLUMNS)
	for copy = 0, 1 do
		local i = 1
		while i <= COLUMNS do
			local run = 1
			while i + run <= COLUMNS and heights[i + run] == heights[i] do
				run += 1
			end
			local h = heights[i]
			local x = (copy * COLUMNS + i - 1) * width
			local column = place(layer, UDim2.fromScale(x, 1 - h), UDim2.fromScale(run * width + 0.0005, h), z)
			column.BackgroundTransparency = 0
			column.BackgroundColor3 = body
			local capFrame = place(column, UDim2.fromScale(0, 0), UDim2.new(1, 0, 0, cap), z + 1)
			capFrame.BackgroundTransparency = 0
			capFrame.BackgroundColor3 = top
			i += run
		end
	end
	return layer
end

-- Blocky clouds: flat white boxes, two screens wide like the hills.
local function clouds(parent: Instance, z: number): Frame
	local layer = place(parent, UDim2.fromScale(0, 0.04), UDim2.fromScale(2, 0.3), z)
	-- { x, y, width, height } in a screen.
	local boxes = {
		{ 0.02, 0.10, 0.14, 0.12 },
		{ 0.08, 0.02, 0.06, 0.10 },
		{ 0.24, 0.40, 0.10, 0.10 },
		{ 0.38, 0.16, 0.16, 0.12 },
		{ 0.44, 0.08, 0.06, 0.10 },
		{ 0.60, 0.50, 0.12, 0.10 },
		{ 0.74, 0.20, 0.18, 0.12 },
		{ 0.80, 0.10, 0.08, 0.12 },
		{ 0.92, 0.62, 0.07, 0.08 },
	}
	for copy = 0, 1 do
		for _, box in boxes do
			local cloud =
				place(layer, UDim2.fromScale((copy + box[1]) / 2, box[2]), UDim2.fromScale(box[3] / 2, box[4] * 2), z)
			cloud.BackgroundTransparency = 0.15
			cloud.BackgroundColor3 = WHITE
		end
	end
	return layer
end

--[[ The screen ]]

--[[
	Shows the title screen and waits until the player enters the world (Join World, or the world
	they created). Returns at once when Config.MainMenu.Enabled is off. Call after Settings.start
	and SoundPlayer.start, before the rest of the client starts.
]]
function MainMenu.run()
	if not Config.MainMenu.Enabled or entered then
		return
	end
	shown = true
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	-- (The Options menu is built now: the title screen shows it itself.)
	SettingsScreen.start()

	-- The server's MenuState (nil until the first arrives) and this player's part.
	local state: number? = nil
	local operatorName = ""
	local worldName = ""
	local function isOperator(): boolean
		return player:GetAttribute(WorldSettings.OPERATOR_ATTRIBUTE) == true
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "IceVoxelMainMenu"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = DISPLAY_ORDER

	-- Backgrounds: the moving sky (the title) and the dirt (the other screens).
	local sky = place(gui, UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), 0)
	sky.BackgroundTransparency = 0
	sky.BackgroundColor3 = WHITE
	sky.ClipsDescendants = true
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(SKY_TOP, SKY_BOTTOM)
	gradient.Rotation = 90
	gradient.Parent = sky
	local sun = place(sky, UDim2.fromScale(0.16, 0.12), UDim2.fromScale(0.05, 0.05), 1)
	sun.BackgroundTransparency = 0
	sun.BackgroundColor3 = SUN
	local sunAspect = Instance.new("UIAspectRatioConstraint")
	sunAspect.Parent = sun
	local cloudLayer = clouds(sky, 2)
	local farLayer = hills(
		sky,
		profile({ { 2, 0.10, 0.3 }, { 5, 0.05, 1.7 }, { 9, 0.02, 0.4 } }, 0.42, 60),
		FAR_SNOW,
		FAR_ROCK,
		6,
		3
	)
	local nearLayer =
		hills(sky, profile({ { 1, 0.05, 2.1 }, { 3, 0.04, 0.2 }, { 7, 0.015, 1.1 } }, 0.2, 40), GRASS, DIRT, 8, 5)
	-- The near hills' lighter grass edge.
	for _, child in nearLayer:GetChildren() do
		local cap = child:FindFirstChildOfClass("Frame")
		if cap then
			local edge = place(cap, UDim2.fromScale(0, 0), UDim2.new(1, 0, 0, 2), 7)
			edge.BackgroundTransparency = 0
			edge.BackgroundColor3 = GRASS_LIGHT
		end
	end
	-- Minecraft darkens the panorama's edges a little for the text.
	local vignette = place(sky, UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), 8)
	vignette.BackgroundTransparency = 0
	vignette.BackgroundColor3 = Color3.new(0, 0, 0)
	local fade = Instance.new("UIGradient")
	fade.Rotation = 90
	fade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(0.35, 0.95),
		NumberSequenceKeypoint.new(0.7, 0.9),
		NumberSequenceKeypoint.new(1, 0.5),
	})
	fade.Parent = vignette

	local dirt = Instance.new("ImageLabel")
	dirt.Name = "OptionsBackground"
	dirt.BorderSizePixel = 0
	dirt.Size = UDim2.fromScale(1, 1)
	dirt.ZIndex = 0
	dirt.BackgroundColor3 =
		Color3.new(DIRT.R * DIRT_DARKEN * 0.8, DIRT.G * DIRT_DARKEN * 0.8, DIRT.B * DIRT_DARKEN * 0.8)
	local dirtTexture = TexturePack.Textures.dirt
	if dirtTexture and dirtTexture.Color ~= "" then
		dirt.Image = dirtTexture.Color
		dirt.ScaleType = Enum.ScaleType.Tile
		dirt.ImageColor3 = Color3.new(DIRT.R * DIRT_DARKEN, DIRT.G * DIRT_DARKEN, DIRT.B * DIRT_DARKEN)
	end
	dirt.Visible = false
	dirt.Parent = gui

	-- Visible and Modal: Roblox frees the mouse while it is shown.
	local modal = Instance.new("TextButton")
	modal.Name = "Modal"
	modal.Text = ""
	modal.BackgroundTransparency = 1
	modal.AutoButtonColor = false
	modal.Selectable = false
	modal.Modal = true
	modal.Size = UDim2.fromScale(1, 1)
	modal.ZIndex = 0
	modal.Parent = gui

	-- Everything else in GUI pixels: the scaled screen (laid out in `layout`).
	local content = place(gui, UDim2.fromScale(0, 0), UDim2.fromOffset(320, 240), 2)
	local scale = Instance.new("UIScale")
	scale.Parent = content

	local function newPage(name: Page): Frame
		local frame = place(content, UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), 2)
		frame.Name = name
		frame.Visible = false
		return frame
	end
	local pages = {
		title = newPage("title"),
		create = newPage("create"),
		customize = newPage("customize"),
		options = newPage("options"),
		creating = newPage("creating"),
	}

	--[[ Title ]]

	local title = pages.title
	local logo = place(title, UDim2.new(0.5, 0, 0, 30), UDim2.fromOffset(0, 0), 5)
	local logoW, logoH = buildLogo(logo, 0, 0)
	logo.Size = UDim2.fromOffset(logoW, logoH)
	logo.Position = UDim2.new(0.5, -math.floor(logoW / 2), 0, 30)
	local edition = place(logo, UDim2.new(0, 0, 0, logoH + 4), UDim2.fromOffset(logoW, Style.TEXT_SIZE), 5)
	Style.shadowText(edition, EDITION, 0, 0, logoW, Style.TEXT_SIZE, WHITE, 6, Enum.TextXAlignment.Center)

	local now = DateTime.now():ToLocalTime() :: any
	local splashText = TitleRules.splash(now.Month, now.Day, math.random(1, #TitleRules.SPLASHES))
	local splashWidth = Style.textWidth(splashText)
	local splash = place(title, UDim2.new(0.5, 90, 0, 70), UDim2.fromOffset(splashWidth, Style.TEXT_SIZE), 9)
	splash.AnchorPoint = Vector2.new(0.5, 0.5)
	splash.Rotation = -20
	Style.shadowText(
		splash,
		splashText,
		0,
		0,
		splashWidth,
		Style.TEXT_SIZE,
		Style.Colour.Yellow,
		9,
		Enum.TextXAlignment.Center
	)
	local splashScale = Instance.new("UIScale")
	splashScale.Parent = splash

	local column = place(title, UDim2.new(0.5, -BUTTON_W / 2, 0.25, 48), UDim2.fromOffset(BUTTON_W, 5 * ROW), 5)
	local joinButton = FormWidgets.button(column, "Join World", 0, 0, BUTTON_W, BUTTON_H)
	local createButton = FormWidgets.button(column, "Create World", 0, ROW, BUTTON_W, BUTTON_H)
	local loadButton = FormWidgets.button(column, "Load World (Coming soon)", 0, 2 * ROW, BUTTON_W, BUTTON_H)
	loadButton:setEnabled(false)
	local optionsButton = FormWidgets.button(column, "Options...", 0, 3 * ROW + 12, BUTTON_W, BUTTON_H)
	local statusLine = FormWidgets.label(column, "", -60, 4 * ROW + 16, BUTTON_W + 120, GRAY, "centre")
	local titleOrder: { GuiObject } = { joinButton.button, createButton.button, optionsButton.button }
	for i, object in titleOrder do
		object.NextSelectionDown = titleOrder[i + 1] or titleOrder[1]
		object.NextSelectionUp = titleOrder[i - 1] or titleOrder[#titleOrder]
	end

	local corner = place(title, UDim2.new(0, 2, 1, -10), UDim2.new(1, -4, 0, Style.TEXT_SIZE), 5)
	local version, versionShadow =
		Style.shadowText(corner, Config.MainMenu.Version, 0, 0, 0, Style.TEXT_SIZE, WHITE, 5, Enum.TextXAlignment.Left)
	version.Size = UDim2.fromScale(1, 1)
	versionShadow.Size = UDim2.fromScale(1, 1)
	local credits, creditsShadow =
		Style.shadowText(corner, Config.MainMenu.Credits, 0, 0, 0, Style.TEXT_SIZE, WHITE, 5, Enum.TextXAlignment.Right)
	credits.Size = UDim2.fromScale(1, 1)
	creditsShadow.Size = UDim2.fromScale(1, 1)

	--[[ Create World ]]

	local form = CreateWorldForm.new()
	local create = pages.create
	-- Tabs: Game and World (Minecraft's header), a white line under the shown one.
	local tabs = place(create, UDim2.new(0.5, -105, 0, 4), UDim2.fromOffset(210, 22), 5)
	local gameTab = FormWidgets.button(tabs, "Game", 0, 0, 100, BUTTON_H)
	local worldTab = FormWidgets.button(tabs, "World", 110, 0, 100, BUTTON_H)
	local underline = Style.frame(tabs, 0, BUTTON_H + 1, 100, 1, WHITE, 6)
	local separator = place(create, UDim2.new(0, 0, 0, 28), UDim2.new(1, 0, 0, 1), 5)
	separator.BackgroundTransparency = 0.4
	separator.BackgroundColor3 = Color3.new(0, 0, 0)

	local gamePane = place(create, UDim2.new(0.5, -105, 0, 36), UDim2.fromOffset(210, 160), 5)
	FormWidgets.label(gamePane, "World Name", 1, 0, 208, GRAY)
	local nameBox = FormWidgets.editBox(gamePane, 1, 11, 208, BUTTON_H, 5, function(text: string): string
		return if utf8.len(text) and (utf8.len(text) :: number) > WorldSettings.MAX_NAME
			then string.sub(text, 1, (utf8.offset(text, WorldSettings.MAX_NAME + 1) :: number) - 1)
			else text
	end)
	nameBox:setText(form.name)
	local modeButton = FormWidgets.button(gamePane, "", 0, 38, 210, BUTTON_H)
	local setModeInfo = infoText(gamePane, -40, 60, 290, 1)
	local difficultyButton = FormWidgets.button(gamePane, "", 0, 76, 210, BUTTON_H)
	local setDifficultyInfo = infoText(gamePane, -40, 98, 290, 1)
	local commandsButton = FormWidgets.button(gamePane, "", 0, 114, 210, BUTTON_H)
	local setCommandsInfo = infoText(gamePane, -40, 136, 290, 1)

	local worldPane = place(create, UDim2.new(0.5, -155, 0, 36), UDim2.fromOffset(310, 160), 5)
	local typeButton = FormWidgets.button(worldPane, "", 0, 0, 150, BUTTON_H)
	local customizeButton = FormWidgets.button(worldPane, "Customize", 160, 0, 150, BUTTON_H)
	local setTypeInfo = infoText(worldPane, 0, 23, 310, 2)
	FormWidgets.label(worldPane, "Seed for the world generator", 2, 48, 306, GRAY)
	local seedBox = FormWidgets.editBox(worldPane, 2, 59, 306, BUTTON_H, 5, function(text: string): string
		return if utf8.len(text) and (utf8.len(text) :: number) > WorldSettings.MAX_SEED
			then string.sub(text, 1, (utf8.offset(text, WorldSettings.MAX_SEED + 1) :: number) - 1)
			else text
	end)
	seedBox:setText(form.seed)
	local setSeedInfo = infoText(worldPane, 0, 83, 310, 1)
	setSeedInfo("Leave blank for a random seed")
	local structuresButton = FormWidgets.button(worldPane, "", 50, 100, 210, BUTTON_H)

	local footer = place(create, UDim2.new(0.5, -155, 1, -28), UDim2.fromOffset(310, BUTTON_H), 5)
	local createNow = FormWidgets.button(footer, "Create New World", 0, 0, 150, BUTTON_H)
	local cancel = FormWidgets.button(footer, "Cancel", 160, 0, 150, BUTTON_H)
	local errorHolder = place(create, UDim2.new(0.5, -160, 1, -50), UDim2.fromOffset(320, 20), 5)
	local setError = infoText(errorHolder, 0, 0, 320, 2)

	--[[ Customize ]]

	local customize = pages.customize
	local customizeTitle = FormWidgets.label(customize, "", 0, 12, 320, WHITE, "centre")
	customizeTitle.frame.Position = UDim2.new(0.5, -160, 0, 12)
	local customizeList = Instance.new("ScrollingFrame")
	customizeList.BackgroundTransparency = 1
	customizeList.BorderSizePixel = 0
	customizeList.Position = UDim2.new(0.5, -160, 0, 30)
	customizeList.Size = UDim2.new(0, 320, 1, -64)
	customizeList.ScrollBarThickness = 4
	customizeList.ScrollingDirection = Enum.ScrollingDirection.Y
	customizeList.ZIndex = 5
	customizeList.Parent = customize
	local customizeDone = place(customize, UDim2.new(0.5, -100, 1, -28), UDim2.fromOffset(BUTTON_W, BUTTON_H), 5)
	local doneButton = FormWidgets.button(customizeDone, "Done", 0, 0, BUTTON_W, BUTTON_H)

	--[[ Creating, Options ]]

	local creating = pages.creating
	local creatingTitle = FormWidgets.label(creating, "Creating the world...", 0, 0, 320, WHITE, "centre")
	creatingTitle.frame.Position = UDim2.new(0.5, -160, 0.5, -12)
	local creatingLine = FormWidgets.label(creating, "", 0, 0, 320, GRAY, "centre")
	creatingLine.frame.Position = UDim2.new(0.5, -160, 0.5, 2)
	-- (The Options menu's frame centres itself in its parent.)
	local optionsHost = pages.options
	local closeOptions: (() -> ())? = nil

	--[[ Behaviour ]]

	local page: Page = "title"

	local function gamepadUser(): boolean
		local last = UserInputService:GetLastInputType()
		return GuiService.SelectedObject ~= nil
			or last == Enum.UserInputType.Gamepad1
			or last == Enum.UserInputType.Gamepad2
	end

	local function selectObject(object: GuiObject?)
		if object and gamepadUser() then
			GuiService.SelectedObject = object
		end
	end

	local function refreshTitle()
		local buttons = TitleRules.buttons(state, isOperator())
		joinButton:setEnabled(buttons.join)
		createButton:setEnabled(buttons.create)
		optionsButton:setEnabled(buttons.options)
		local text, kind = TitleRules.status(state, isOperator(), operatorName, worldName)
		statusLine:setText(
			text,
			if kind == "news" then Style.Colour.Yellow elseif kind == "warning" then Style.Colour.Red else GRAY
		)
	end

	local function refreshCreate()
		local onGame = form.tab == "game"
		gamePane.Visible = onGame
		worldPane.Visible = not onGame
		underline.Position = UDim2.fromOffset(if onGame then 0 else 110, BUTTON_H + 1)
		modeButton:setText(CreateWorldForm.gameModeLabel(form))
		setModeInfo(CreateWorldForm.gameModeInfo(form))
		difficultyButton:setText(CreateWorldForm.difficultyLabel(form))
		setDifficultyInfo(CreateWorldForm.difficultyInfo(form))
		commandsButton:setText(CreateWorldForm.commandsLabel(form))
		setCommandsInfo(CreateWorldForm.commandsInfo(form))
		typeButton:setText(CreateWorldForm.worldTypeLabel(form))
		customizeButton:setEnabled(CreateWorldForm.customizable(form))
		setTypeInfo(CreateWorldForm.worldType(form).description)
		structuresButton:setText(CreateWorldForm.structuresLabel(form))
		createNow:setEnabled(isOperator() and state == Protocol.MenuState.Waiting)
	end

	local function showPage(name: Page)
		if closeOptions and name ~= "options" then
			local close = closeOptions
			closeOptions = nil
			close()
		end
		page = name
		for id, frame in pages :: { [string]: Frame } do
			frame.Visible = id == name
		end
		sky.Visible = name == "title"
		dirt.Visible = name ~= "title"
		if name == "title" then
			refreshTitle()
			selectObject(if joinButton.enabled then joinButton.button else optionsButton.button)
		elseif name == "create" then
			refreshCreate()
			selectObject(if form.tab == "game" then modeButton.button else typeButton.button)
		elseif name == "customize" then
			selectObject(doneButton.button)
		end
	end

	local function enter()
		if entered then
			return
		end
		entered = true
		shown = false
		ClientNet.send(Protocol.ClientMessage.EnterWorld, buffer.create(0))
		if closeOptions then
			local close = closeOptions
			closeOptions = nil
			close()
		end
		local selected = GuiService.SelectedObject
		if selected and selected:IsDescendantOf(gui) then
			GuiService.SelectedObject = nil
		end
		gui:Destroy()
		enteredEvent:Fire()
	end

	local function buildCustomize()
		for _, child in customizeList:GetChildren() do
			child:Destroy()
		end
		local worldType = CreateWorldForm.worldType(form)
		customizeTitle:setText(`Customize: {worldType.name}`)
		local y = 0
		local settings: { WorldTypes.Setting } = worldType.settings or {}
		for _, setting in settings do
			local row = place(customizeList, UDim2.fromOffset(0, y), UDim2.fromOffset(320, 40), 5)
			if setting.kind == "text" then
				FormWidgets.label(row, setting.name, 56, 0, 208, GRAY)
				local box = FormWidgets.editBox(row, 56, 11, 208, BUTTON_H, 5, function(text: string): string
					return WorldSettings.cleanText(text, setting.maxLength)
				end)
				box:setText(tostring(CreateWorldForm.settingValue(form, setting)))
				box.changed = function(text: string)
					CreateWorldForm.setSetting(form, setting, text)
				end
				y += 34
			else
				local button =
					FormWidgets.button(row, CreateWorldForm.settingLabel(form, setting), 55, 0, 210, BUTTON_H)
				button.clicked = function()
					SoundPlayer.click()
					CreateWorldForm.cycleSetting(form, setting)
					button:setText(CreateWorldForm.settingLabel(form, setting))
				end
				y += 23
			end
			local description = setting.description
			if description and description ~= "" then
				local set = infoText(customizeList, 0, y, 320, 2)
				set(description)
				y += 2 * (Style.TEXT_SIZE + 2)
			end
			y += 6
		end
		customizeList.CanvasSize = UDim2.fromOffset(0, y)
	end

	local function sendCreate()
		form.name = nameBox:text()
		form.seed = seedBox:text()
		if not isOperator() then
			setError("Only the operator can create the world", Style.Colour.Red)
			return
		end
		setError("")
		creatingLine:setText(`"{WorldSettings.cleanName(form.name)}"`)
		showPage("creating")
		ClientNet.send(Protocol.ClientMessage.CreateWorld, Protocol.encodeCreateWorld(CreateWorldForm.request(form)))
	end

	-- Escape and gamepad B: back a screen.
	local function back()
		if page == "create" then
			form.name = nameBox:text()
			form.seed = seedBox:text()
			showPage("title")
		elseif page == "customize" then
			showPage("create")
		elseif page == "options" then
			showPage("title")
		end
	end

	local function clickThen(fn: () -> ()): () -> ()
		return function()
			SoundPlayer.click()
			fn()
		end
	end

	joinButton.clicked = clickThen(function()
		if state == Protocol.MenuState.Ready then
			enter()
		end
	end)
	createButton.clicked = clickThen(function()
		setError("")
		showPage("create")
	end)
	optionsButton.clicked = clickThen(function()
		showPage("options")
		closeOptions = SettingsScreen.showIn(optionsHost, function()
			closeOptions = nil
			if not entered then
				showPage("title")
			end
		end)
	end)
	gameTab.clicked = clickThen(function()
		form.tab = "game"
		refreshCreate()
	end)
	worldTab.clicked = clickThen(function()
		form.tab = "world"
		refreshCreate()
	end)
	modeButton.clicked = clickThen(function()
		CreateWorldForm.cycleGameMode(form)
		refreshCreate()
	end)
	difficultyButton.clicked = clickThen(function()
		CreateWorldForm.cycleDifficulty(form)
		refreshCreate()
	end)
	commandsButton.clicked = clickThen(function()
		CreateWorldForm.toggleCommands(form)
		refreshCreate()
	end)
	typeButton.clicked = clickThen(function()
		CreateWorldForm.cycleWorldType(form)
		refreshCreate()
	end)
	customizeButton.clicked = clickThen(function()
		buildCustomize()
		showPage("customize")
	end)
	structuresButton.clicked = clickThen(function()
		CreateWorldForm.toggleStructures(form)
		refreshCreate()
	end)
	createNow.clicked = clickThen(sendCreate)
	cancel.clicked = clickThen(back)
	doneButton.clicked = clickThen(back)

	--[[ The server ]]

	ClientNet.on(Protocol.ServerMessage.MenuState, function(payload: buffer)
		local newState, operator, world = Protocol.decodeMenuState(payload)
		if newState == nil or entered then
			return
		end
		state, operatorName, worldName = newState, operator, world
		if page == "title" then
			refreshTitle()
		elseif page == "create" then
			refreshCreate()
		end
		-- Someone else made the world (or it failed) while this screen was open: back to the title.
		if
			(page == "create" or page == "customize") and newState ~= Protocol.MenuState.Waiting
			or page == "creating" and newState == Protocol.MenuState.Failed
		then
			showPage("title")
		end
	end)
	ClientNet.on(Protocol.ServerMessage.CreateWorldResult, function(payload: buffer)
		local ok, message = Protocol.decodeCreateWorldResult(payload)
		if ok == nil or entered then
			return
		elseif ok then
			enter()
		elseif page == "creating" then
			showPage("create")
			setError(message, Style.Colour.Red)
		end
	end)
	--[[ Layout, input, animation ]]

	local function layout()
		local camera = workspace.CurrentCamera
		local viewport = if camera then camera.ViewportSize else Vector2.new(1280, 720)
		local size = Style.guiScale(viewport, 320, 240, UserInputService.TouchEnabled)
		scale.Scale = size
		content.Size = UDim2.fromOffset(math.floor(viewport.X / size), math.floor(viewport.Y / size))
		dirt.TileSize = UDim2.fromOffset(DIRT_TILE * size, DIRT_TILE * size)
	end
	layout()
	local connections: { RBXScriptConnection } = {}
	table.insert(
		connections,
		player:GetAttributeChangedSignal(WorldSettings.OPERATOR_ATTRIBUTE):Connect(function()
			if page == "title" then
				refreshTitle()
			elseif page == "create" then
				refreshCreate()
			end
		end)
	)
	local function watchCamera()
		local camera = workspace.CurrentCamera
		if camera then
			table.insert(connections, camera:GetPropertyChangedSignal("ViewportSize"):Connect(layout))
		end
	end
	watchCamera()
	table.insert(
		connections,
		workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
			watchCamera()
			layout()
		end)
	)
	table.insert(connections, Style.scaleChanged:Connect(layout))
	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if processed then
				return
			end
			if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then
				back()
			end
		end)
	)
	local started = os.clock()
	table.insert(
		connections,
		RunService.RenderStepped:Connect(function()
			if page ~= "title" then
				return
			end
			local t = os.clock() - started
			splashScale.Scale = TitleRules.splashScale(t, splashWidth)
			cloudLayer.Position = UDim2.fromScale(-((t * CLOUD_SPEED) % 1), 0.04)
			farLayer.Position = UDim2.fromScale(-((t * FAR_SPEED) % 1), 0)
			nearLayer.Position = UDim2.fromScale(-((t * NEAR_SPEED) % 1), 0)
		end)
	)

	gui.Parent = playerGui
	showPage("title")

	while not entered do
		enteredEvent.Event:Wait()
	end
	for _, connection in connections do
		connection:Disconnect()
	end
end

return MainMenu

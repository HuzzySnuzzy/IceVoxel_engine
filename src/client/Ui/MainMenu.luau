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
	             exists), Create World and Load World (operators, while there is none; Load
	             World where worlds can be saved: the server's WorldSave state, Ui/SaveIndicator),
	             Options... (the Options menu, Ui/SettingsScreen.showIn, Done comes back here);
	             the status line under them (waiting for the operator, being created or loaded:
	             "Loading world: 12 / 40", ready) and, in red, why worlds can't be saved here
	             (Studio without API access); Config.MainMenu.Version bottom left and Credits
	             bottom right.
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
	  Load       Minecraft's Select World screen: the saved worlds (the server's WorldList, last
	             played first), three lines each (Ui/WorldListRules: name; type and when last
	             played; game mode and size), one selected (click; double click plays it), then
	             Play Selected World (WorldAction load: "Loading the world..." with the count of
	             keys read, then the world is entered, or the screen comes back with why not in
	             red), Rename (a name box: the server filters it), Delete (Minecraft's "Are you
	             sure you want to delete this world?" first) and Cancel. Each answer lists the
	             worlds again with how it went.
	  Characters with Config.Characters on (Terraria's player select before its world select):
	             the title has Play and Options...; Play opens the character list
	             (Ui/CharacterSelect: the user's characters, a preview of the highlighted one,
	             Play Selected Character, Create New Character, Rename, Delete with Minecraft's
	             confirmation, Back), Create New Character the avatar editor (Ui/AvatarEditor: an
	             R15 look from the player's own avatar, the name and the difficulty), and a
	             character chosen (or made) leads to the world page: "Playing as <name>" over
	             the buttons the title had (Join World, Create World, Load World, as TitleRules
	             says) and Back. Entering sends the character's id (Net/CharacterSync
	             .encodeEnter); the server's list (ServerMessage.Characters) says what each
	             request did. The rules: Ui/CharacterRules; the server's side:
	             Players/CharacterStore.
	  Customize  one widget per setting the world type declares (WorldTypes.Setting), drawn
	             generically: toggles and choices are buttons that cycle, text a field with what
	             its `check` finds wrong under it in red and its `presets` on a button that cycles
	             them (superflat: Minecraft's flat presets); Create New World refuses a text that
	             fails its check (CreateWorldForm.problem).
	  Sub-screens (Create, Customize, Options, creating) sit on Minecraft's options background:
	             the dirt texture (TexturePack "dirt") tiled 32 GUI pixels a tile at a quarter of
	             its brightness (Minecraft's 64 / 255), or plain dark brown without one.
	  Input      mouse, touch, gamepad (A presses, the selection starts on the first button, the
	             Options menu's too); Escape / B go back a screen. Roblox opens its menu on Escape
	             (MenuOpened) and the key may reach InputBegan too, before, after or not at all,
	             as Ui/Screens handles it: whichever comes first goes back (or makes the Key Binds
	             key waiting "Not Bound") and the other, right after, is ignored, as is the Escape
	             that closes Roblox's menu. The GUI scale is Minecraft's (Style.guiScale for 320 x
	             240, or the GUI Scale setting: the boot script's Style.setScaleOverride), laid
	             out again when the window or the setting changes.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local CharacterSync = require(Shared.Net.CharacterSync)
local Characters = require(Shared.Characters)
local Config = require(Shared.Config)
local Protocol = require(Shared.Net.Protocol)
local TexturePack = require(Shared.TexturePack)
local WorldSettings = require(Shared.WorldSettings)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local AvatarEditor = require(script.Parent.AvatarEditor)
local CharacterRules = require(script.Parent.CharacterRules)
local CharacterSelect = require(script.Parent.CharacterSelect)
local CreateWorldForm = require(script.Parent.CreateWorldForm)
local FormWidgets = require(script.Parent.FormWidgets)
local SaveIndicator = require(script.Parent.SaveIndicator)
local SettingsScreen = require(script.Parent.SettingsScreen)
local Style = require(script.Parent.Style)
local TitleRules = require(script.Parent.TitleRules)
local WorldListRules = require(script.Parent.WorldListRules)
local SaveText = require(Shared.SaveText)

-- Over everything else (the HUD and screens are 1..20).
local DISPLAY_ORDER = 100
-- Seconds within which a second Escape (InputBegan and MenuOpened for one press) is the same one.
local ESCAPE_REPEAT = 0.3
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

type Page =
	"title"
	| "create"
	| "customize"
	| "options"
	| "creating"
	| "load"
	| "confirm"
	| "rename"
	| "characters"
	| "editor"
	| "world"

-- Characters (Config.Characters): a character is chosen before the world.
local CHARACTERS = Config.Characters.Enabled == true

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
		load = newPage("load"),
		confirm = newPage("confirm"),
		rename = newPage("rename"),
		characters = newPage("characters"),
		editor = newPage("editor"),
		world = newPage("world"),
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

	local column = place(title, UDim2.new(0.5, -BUTTON_W / 2, 0.25, 48), UDim2.fromOffset(BUTTON_W, 6 * ROW), 5)
	local joinButton = FormWidgets.button(column, "Join World", 0, 0, BUTTON_W, BUTTON_H)
	local createButton = FormWidgets.button(column, "Create World", 0, ROW, BUTTON_W, BUTTON_H)
	local loadButton = FormWidgets.button(column, "Load World", 0, 2 * ROW, BUTTON_W, BUTTON_H)
	loadButton:setEnabled(false)
	local optionsButton = FormWidgets.button(column, "Options...", 0, 3 * ROW + 12, BUTTON_W, BUTTON_H)
	local statusLine = FormWidgets.label(column, "", -60, 4 * ROW + 16, BUTTON_W + 120, GRAY, "centre")
	-- (Why worlds can't be saved here, in red: Studio without API access.)
	local setSaveNote = infoText(column, -60, 4 * ROW + 28, BUTTON_W + 120, 3)
	local titleOrder: { GuiObject } =
		{ joinButton.button, createButton.button, loadButton.button, optionsButton.button }
	-- With characters the title has Play and Options...; the buttons above move to the world page
	-- (the character is chosen first), Options... giving way to Back.
	local charactersButton: FormWidgets.Button? = nil
	local titleOptions: FormWidgets.Button? = nil
	local worldBack: FormWidgets.Button? = nil
	local playingAs: FormWidgets.Label? = nil
	if CHARACTERS then
		local titleColumn =
			place(title, UDim2.new(0.5, -BUTTON_W / 2, 0.25, 48), UDim2.fromOffset(BUTTON_W, 2 * ROW + 12), 5)
		local play = FormWidgets.button(titleColumn, "Play", 0, 0, BUTTON_W, BUTTON_H)
		local options = FormWidgets.button(titleColumn, "Options...", 0, ROW + 12, BUTTON_W, BUTTON_H)
		play.button.NextSelectionDown, play.button.NextSelectionUp = options.button, options.button
		options.button.NextSelectionDown, options.button.NextSelectionUp = play.button, play.button
		charactersButton, titleOptions = play, options
		column.Parent = pages.world
		optionsButton:setVisible(false)
		local back = FormWidgets.button(column, "Back", 0, 3 * ROW + 12, BUTTON_W, BUTTON_H)
		worldBack = back
		titleOrder = { joinButton.button, createButton.button, loadButton.button, back.button }
		local label = FormWidgets.label(pages.world, "", 0, 0, 320, WHITE, "centre", 5)
		label.frame.Position = UDim2.new(0.5, -160, 0.25, 30)
		playingAs = label
	end
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

	--[[ Load World, its delete confirmation and rename ]]

	local load = pages.load
	local loadTitle = FormWidgets.label(load, "Select World", 0, 0, 320, WHITE, "centre")
	loadTitle.frame.Position = UDim2.new(0.5, -160, 0, 8)
	local worldList = Instance.new("ScrollingFrame")
	worldList.BackgroundTransparency = 0.5
	worldList.BackgroundColor3 = Color3.new(0, 0, 0)
	worldList.BorderSizePixel = 0
	worldList.Position = UDim2.new(0.5, -140, 0, 24)
	worldList.Size = UDim2.new(0, 280, 1, -24 - 84)
	worldList.ScrollBarThickness = 4
	worldList.ScrollingDirection = Enum.ScrollingDirection.Y
	worldList.ZIndex = 5
	worldList.Parent = load
	local noteHolder = place(load, UDim2.new(0.5, -160, 1, -80), UDim2.fromOffset(320, 22), 5)
	local setLoadNote = infoText(noteHolder, 0, 0, 320, 2)
	local loadFooter = place(load, UDim2.new(0.5, -155, 1, -52), UDim2.fromOffset(310, ROW + BUTTON_H), 5)
	local playButton = FormWidgets.button(loadFooter, "Play Selected World", 0, 0, 150, BUTTON_H)
	local renameButton = FormWidgets.button(loadFooter, "Rename", 160, 0, 150, BUTTON_H)
	local deleteButton = FormWidgets.button(loadFooter, "Delete", 0, ROW, 150, BUTTON_H)
	local loadCancel = FormWidgets.button(loadFooter, "Cancel", 160, ROW, 150, BUTTON_H)

	local confirm = pages.confirm
	local confirmHolder = place(confirm, UDim2.new(0.5, -160, 0.5, -44), UDim2.fromOffset(320, 88), 5)
	local setQuestion = infoText(confirmHolder, 0, 0, 320, 1)
	local setWarning = infoText(confirmHolder, 0, 16, 320, 2)
	local confirmDelete = FormWidgets.button(confirmHolder, "Delete", 5, 52, 150, BUTTON_H)
	local confirmCancel = FormWidgets.button(confirmHolder, "Cancel", 165, 52, 150, BUTTON_H)

	local renamePage = pages.rename
	local renameHolder = place(renamePage, UDim2.new(0.5, -105, 0.5, -40), UDim2.fromOffset(210, 80), 5)
	local renameLabel = FormWidgets.label(renameHolder, "World Name", 1, 0, 208, GRAY)
	local renameBox = FormWidgets.editBox(renameHolder, 1, 11, 208, BUTTON_H, 5, function(text: string): string
		return if utf8.len(text) and (utf8.len(text) :: number) > WorldSettings.MAX_NAME
			then string.sub(text, 1, (utf8.offset(text, WorldSettings.MAX_NAME + 1) :: number) - 1)
			else text
	end)
	local renameNow = FormWidgets.button(renameHolder, "Rename", 0, 40, 100, BUTTON_H)
	local renameCancel = FormWidgets.button(renameHolder, "Cancel", 110, 40, 100, BUTTON_H)

	-- The saved worlds (the server's WorldList), the one picked, a request out.
	local worlds: { Protocol.WorldEntry } = {}
	local selectedId: string? = nil
	local listBusy = false
	-- What the creating page waits for ("create" or "load"), and a load's progress line.
	local pending: string? = nil
	local loadingText: string? = nil

	--[[ Characters (Config.Characters) ]]

	local characterPage = if CHARACTERS then CharacterSelect.new(pages.characters) else nil
	local editor = if CHARACTERS then AvatarEditor.new(pages.editor) else nil
	-- The server's last list (nil until one came), a request out ("select" of `id`, "create"
	-- while `previous` was selected, or another change), what the shared rename and confirm
	-- pages are open for and the character they are about.
	local characterList: CharacterSync.List? = nil
	local characterPending: { kind: string, id: number, previous: number }? = nil
	local dialogFor = "world"
	local dialogCharacter: Characters.Summary? = nil
	-- Where the world's own pages go back to: the world page with characters, else the title.
	local worldHome: Page = if CHARACTERS then "world" else "title"

	--[[ Behaviour ]]

	local page: Page = "title"
	local connections: { RBXScriptConnection } = {}

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
		local saveState, saveWhy = SaveIndicator.state()
		local saves = saveState == Protocol.SaveState.On or saveState == Protocol.SaveState.Off
		local buttons = TitleRules.buttons(state, isOperator(), saves)
		joinButton:setEnabled(buttons.join)
		createButton:setEnabled(buttons.create)
		loadButton:setEnabled(buttons.load)
		optionsButton:setEnabled(buttons.options)
		local text, kind = TitleRules.status(state, isOperator(), operatorName, worldName, loadingText)
		statusLine:setText(
			text,
			if kind == "news" then Style.Colour.Yellow elseif kind == "warning" then Style.Colour.Red else GRAY
		)
		local note = if saveState ~= nil and saveState == Protocol.SaveState.Unavailable
			then SaveText.state(saveState, saveWhy)
			else nil
		setSaveNote(note or "", Style.Colour.Red)
	end

	local function selectedEntry(): Protocol.WorldEntry?
		for _, entry in worlds do
			if entry.id == selectedId then
				return entry
			end
		end
		return nil
	end

	local function refreshLoad()
		local buttons = WorldListRules.buttons(selectedEntry() ~= nil, listBusy)
		playButton:setEnabled(buttons.play)
		renameButton:setEnabled(buttons.rename)
		deleteButton:setEnabled(buttons.delete)
		loadCancel:setEnabled(buttons.cancel)
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
		structuresButton:setEnabled(CreateWorldForm.hasStructures(form))
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
		sky.Visible = name == "title" or name == "world"
		dirt.Visible = not sky.Visible
		if name == "title" and charactersButton then
			selectObject(charactersButton.button)
		elseif name == "title" then
			refreshTitle()
			selectObject(if joinButton.enabled then joinButton.button else optionsButton.button)
		elseif name == "world" then
			refreshTitle()
			local list = characterList
			local chosen = if list then CharacterRules.find(list.characters, list.selected) else nil
			if playingAs then
				playingAs:setText(if chosen then `Playing as {chosen.name}` else "")
			end
			selectObject(if joinButton.enabled then joinButton.button elseif worldBack then worldBack.button else nil)
		elseif name == "characters" then
			if characterPage then
				characterPage:opened(gamepadUser())
			end
		elseif name == "create" then
			refreshCreate()
			selectObject(if form.tab == "game" then modeButton.button else typeButton.button)
		elseif name == "customize" then
			selectObject(doneButton.button)
		elseif name == "load" then
			refreshLoad()
			selectObject(loadCancel.button)
		elseif name == "confirm" then
			selectObject(confirmCancel.button)
		elseif name == "rename" then
			selectObject(renameCancel.button)
		end
	end

	local play: () -> () = function() end
	local lastClick = { id = "", at = -math.huge }
	-- The list's rows: name, then two gray lines; the picked one framed in white.
	local function buildRows()
		for _, child in worldList:GetChildren() do
			if not child:IsA("UIComponent") then
				child:Destroy()
			end
		end
		local y = 2
		for _, entry in worlds do
			local date = os.date("*t", math.floor(entry.lastPlayed))
			local line1, line2, line3 = WorldListRules.row(entry, date :: any)
			local row = Instance.new("TextButton")
			row.Name = entry.id
			row.Text = ""
			row.AutoButtonColor = false
			row.BackgroundTransparency = if entry.id == selectedId then 0 else 1
			row.BackgroundColor3 = WHITE
			row.BorderSizePixel = 0
			row.Position = UDim2.fromOffset(4, y)
			row.Size = UDim2.fromOffset(268, 36)
			row.ZIndex = 6
			row.Parent = worldList
			local inside = Style.frame(row, 1, 1, 266, 34, Color3.new(0, 0, 0), 6)
			inside.BackgroundTransparency = if entry.id == selectedId then 0 else 1
			Style.shadowText(row, line1, 4, 3, 260, 10, WHITE, 7)
			Style.shadowText(row, line2, 4, 13, 260, 10, GRAY, 7)
			Style.shadowText(row, line3, 4, 23, 260, 10, GRAY, 7)
			row.Activated:Connect(function()
				local now = os.clock()
				local again = lastClick.id == entry.id and now - lastClick.at < 0.4
				lastClick.id, lastClick.at = entry.id, now
				if selectedId ~= entry.id then
					SoundPlayer.click()
					selectedId = entry.id
					buildRows()
					refreshLoad()
				elseif again then
					play()
				end
			end)
			y += 38
		end
		worldList.CanvasSize = UDim2.fromOffset(0, y + 2)
	end

	-- A request is out (its answer is the list again): the buttons wait.
	local function waitForList(note: string)
		listBusy = true
		setLoadNote(note, GRAY)
		refreshLoad()
	end

	local function requestList()
		waitForList("Reading the saved worlds...")
		ClientNet.send(Protocol.ClientMessage.WorldAction, Protocol.encodeWorldAction(Protocol.WorldAction.List))
	end

	play = function()
		local entry = selectedEntry()
		if entry == nil or listBusy or not isOperator() then
			return
		end
		pending = "load"
		creatingTitle:setText("Loading the world...")
		creatingLine:setText(`"{entry.name}"`)
		showPage("creating")
		ClientNet.send(
			Protocol.ClientMessage.WorldAction,
			Protocol.encodeWorldAction(Protocol.WorldAction.Load, entry.id)
		)
	end

	local function enter()
		if entered then
			return
		end
		local list = characterList
		if CHARACTERS and (list == nil or list.selected == 0) then
			-- (No character chosen: choose one first.)
			showPage("characters")
			return
		end
		entered = true
		shown = false
		ClientNet.send(
			Protocol.ClientMessage.EnterWorld,
			if CHARACTERS and list then CharacterSync.encodeEnter(list.selected) else buffer.create(0)
		)
		if closeOptions then
			local close = closeOptions
			closeOptions = nil
			close()
		end
		local selected = GuiService.SelectedObject
		if selected and selected:IsDescendantOf(gui) then
			GuiService.SelectedObject = nil
		end
		if characterPage then
			characterPage:destroy()
		end
		if editor then
			editor:destroy()
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
		for _, setting in CreateWorldForm.customSettings(form) do
			if setting.kind == "text" then
				-- The code typed in full width, what its check says is wrong under it (red), then
				-- the presets cycled on a button (superflat's: Minecraft's flat presets).
				local presets = setting.presets
				local hasPresets = presets ~= nil and #presets > 0
				local height = if hasPresets then 68 else 46
				local row = place(customizeList, UDim2.fromOffset(0, y), UDim2.fromOffset(320, height), 5)
				FormWidgets.label(row, setting.name, 2, 0, 316, GRAY)
				local box = FormWidgets.editBox(row, 2, 11, 316, BUTTON_H, 5, function(text: string): string
					return WorldSettings.cleanText(text, setting.maxLength)
				end)
				local setProblem = infoText(row, 0, 34, 320, 1)
				local presetButton = if hasPresets then FormWidgets.button(row, "", 55, 48, 210, BUTTON_H) else nil
				local function refreshText()
					setProblem(CreateWorldForm.settingProblem(form, setting) or "", Style.Colour.Red)
					if presetButton then
						presetButton:setText(`{setting.name}: {CreateWorldForm.presetLabel(form, setting)}`)
					end
				end
				box:setText(tostring(CreateWorldForm.settingValue(form, setting)))
				box.changed = function(text: string)
					CreateWorldForm.setSetting(form, setting, text)
					refreshText()
				end
				if presetButton then
					presetButton.clicked = function()
						SoundPlayer.click()
						CreateWorldForm.cyclePreset(form, setting)
						box:setText(tostring(CreateWorldForm.settingValue(form, setting)))
						refreshText()
					end
				end
				refreshText()
				y += height
			else
				local row = place(customizeList, UDim2.fromOffset(0, y), UDim2.fromOffset(320, 40), 5)
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
		-- (A bad superflat preset would make Classic Flat: say so instead.)
		local problem = CreateWorldForm.problem(form)
		if problem then
			setError(problem, Style.Colour.Red)
			return
		end
		setError("")
		pending = "create"
		creatingTitle:setText("Creating the world...")
		creatingLine:setText(`"{WorldSettings.cleanName(form.name)}"`)
		showPage("creating")
		ClientNet.send(Protocol.ClientMessage.CreateWorld, Protocol.encodeCreateWorld(CreateWorldForm.request(form)))
	end

	-- Escape and gamepad B: back a screen (`escaped`: Escape, which makes the Key Binds key waiting
	-- "Not Bound").
	local function back(escaped: boolean?)
		if page == "create" then
			form.name = nameBox:text()
			form.seed = seedBox:text()
			showPage(worldHome)
		elseif page == "customize" then
			showPage("create")
		elseif page == "load" then
			showPage(worldHome)
		elseif page == "confirm" or page == "rename" or page == "characters" or page == "editor" or page == "world" then
			showPage((CharacterRules.back(page, dialogFor) or "title") :: Page)
		elseif page == "options" then
			-- (A sub-page goes back a page; Key Binds waiting for a key takes the press.)
			if not SettingsScreen.back(escaped) then
				showPage("title")
			end
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
	loadButton.clicked = clickThen(function()
		showPage("load")
		requestList()
	end)
	playButton.clicked = clickThen(play)
	loadCancel.clicked = clickThen(function()
		showPage(worldHome)
	end)
	deleteButton.clicked = clickThen(function()
		local entry = selectedEntry()
		if entry then
			dialogFor = "world"
			local question, warning = WorldListRules.deleteQuestion(entry.name)
			setQuestion(question, WHITE)
			setWarning(warning, GRAY)
			showPage("confirm")
		end
	end)
	confirmDelete.clicked = clickThen(function()
		local character = dialogCharacter
		if dialogFor == "character" then
			showPage("characters")
			if character and characterPage then
				characterPending = { kind = "delete", id = character.id, previous = 0 }
				characterPage:setBusy(true)
				characterPage:setMessage("Deleting...")
				ClientNet.send(
					Protocol.ClientMessage.CharacterAction,
					CharacterSync.encodeAction({ action = CharacterSync.Action.Delete, id = character.id })
				)
			end
			return
		end
		local entry = selectedEntry()
		showPage("load")
		if entry then
			waitForList("Deleting...")
			ClientNet.send(
				Protocol.ClientMessage.WorldAction,
				Protocol.encodeWorldAction(Protocol.WorldAction.Delete, entry.id)
			)
		end
	end)
	confirmCancel.clicked = clickThen(function()
		showPage(if dialogFor == "character" then "characters" else "load")
	end)
	renameButton.clicked = clickThen(function()
		local entry = selectedEntry()
		if entry then
			dialogFor = "world"
			renameLabel:setText("World Name")
			renameBox:setText(entry.name)
			showPage("rename")
		end
	end)
	renameNow.clicked = clickThen(function()
		local character = dialogCharacter
		if dialogFor == "character" then
			showPage("characters")
			local name = Characters.cleanName(renameBox:text())
			if character and characterPage and name == nil then
				characterPage:setMessage(CharacterRules.nameProblem(renameBox:text()) or "", Style.Colour.Red)
			elseif character and characterPage and name then
				characterPending = { kind = "rename", id = character.id, previous = 0 }
				characterPage:setBusy(true)
				characterPage:setMessage("Renaming...")
				ClientNet.send(
					Protocol.ClientMessage.CharacterAction,
					CharacterSync.encodeAction({ action = CharacterSync.Action.Rename, id = character.id, name = name })
				)
			end
			return
		end
		local entry = selectedEntry()
		showPage("load")
		if entry then
			waitForList("Renaming...")
			ClientNet.send(
				Protocol.ClientMessage.WorldAction,
				Protocol.encodeWorldAction(Protocol.WorldAction.Rename, entry.id, renameBox:text())
			)
		end
	end)
	renameCancel.clicked = clickThen(function()
		showPage(if dialogFor == "character" then "characters" else "load")
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

	-- The character pages.
	local function sendCharacters(request: CharacterSync.Request)
		ClientNet.send(Protocol.ClientMessage.CharacterAction, CharacterSync.encodeAction(request))
	end
	local function openOptions()
		showPage("options")
		closeOptions = SettingsScreen.showIn(optionsHost, function()
			closeOptions = nil
			if not entered then
				showPage("title")
			end
		end)
	end
	if charactersButton and titleOptions then
		charactersButton.clicked = clickThen(function()
			showPage("characters")
			if characterList == nil and characterPage then
				-- (The server sends it once it read it: asked again in case it came before.)
				characterPage:setBusy(true)
				characterPage:setMessage("Loading your characters...")
				sendCharacters({ action = CharacterSync.Action.List })
			end
		end)
		titleOptions.clicked = clickThen(openOptions)
	end
	if worldBack then
		worldBack.clicked = clickThen(function()
			showPage("characters")
		end)
	end
	if characterPage then
		characterPage.onPlay = function(summary: Characters.Summary)
			local list = characterList
			if list and list.selected == summary.id then
				showPage("world")
				return
			end
			characterPending = { kind = "select", id = summary.id, previous = 0 }
			characterPage:setBusy(true)
			characterPage:setMessage(`Loading {summary.name}...`)
			sendCharacters({ action = CharacterSync.Action.Select, id = summary.id })
		end
		characterPage.onCreate = function()
			showPage("editor")
			if editor then
				editor:open(gamepadUser())
			end
		end
		characterPage.onRename = function(summary: Characters.Summary)
			dialogFor, dialogCharacter = "character", summary
			renameLabel:setText("Character Name")
			renameBox:setText(summary.name)
			showPage("rename")
		end
		characterPage.onDelete = function(summary: Characters.Summary)
			dialogFor, dialogCharacter = "character", summary
			local question, warning = CharacterRules.deleteQuestion(summary.name)
			setQuestion(question, WHITE)
			setWarning(warning, GRAY)
			showPage("confirm")
		end
		characterPage.onBack = function()
			showPage("title")
		end
	end
	if editor then
		editor.onCreate = function(name: string, difficulty: number, look)
			local list = characterList
			characterPending = { kind = "create", id = 0, previous = if list then list.selected else 0 }
			editor:setBusy(true)
			sendCharacters({
				action = CharacterSync.Action.Create,
				name = name,
				difficulty = difficulty,
				appearance = look,
			})
		end
		editor.onCancel = function()
			showPage("characters")
		end
	end

	--[[ The server ]]

	ClientNet.on(Protocol.ServerMessage.MenuState, function(payload: buffer)
		local newState, operator, world = Protocol.decodeMenuState(payload)
		if newState == nil or entered then
			return
		end
		state, operatorName, worldName = newState, operator, world
		if newState ~= Protocol.MenuState.Creating then
			loadingText = nil
		end
		if page == "title" or page == "world" then
			refreshTitle()
		elseif page == "create" then
			refreshCreate()
		end
		-- Someone else made the world (or it failed) while this screen was open: back to the title
		-- (the world page with characters).
		local choosing = page == "create"
			or page == "customize"
			or page == "load"
			or (page == "confirm" or page == "rename") and dialogFor == "world"
		if
			choosing and newState ~= Protocol.MenuState.Waiting and not listBusy
			or page == "creating" and newState == Protocol.MenuState.Failed
		then
			showPage(worldHome)
		end
	end)
	ClientNet.on(Protocol.ServerMessage.CreateWorldResult, function(payload: buffer)
		local ok, message = Protocol.decodeCreateWorldResult(payload)
		if ok == nil or entered then
			return
		elseif ok then
			enter()
		elseif page == "creating" and pending == "load" then
			showPage("load")
			setLoadNote(message, Style.Colour.Red)
		elseif page == "creating" then
			showPage("create")
			setError(message, Style.Colour.Red)
		end
	end)
	-- The user's characters and what the last request did (Players/CharacterStore).
	ClientNet.on(Protocol.ServerMessage.Characters, function(payload: buffer)
		local list = CharacterSync.decodeCharacters(payload)
		if list == nil or entered or characterPage == nil then
			return
		end
		characterList = list
		local request = characterPending
		local done = request ~= nil and not list.busy
		if done then
			characterPending = nil
		end
		characterPage:setList(list, list.busy or (request ~= nil and not done))
		local failed = false
		if done and request then
			if request.kind == "select" then
				failed = list.selected ~= request.id
				if not failed and page == "characters" then
					showPage("world")
				end
			elseif request.kind == "create" then
				failed = list.selected == 0 or list.selected == request.previous
				if editor then
					editor:setBusy(false)
				end
				if editor and page == "editor" then
					if failed then
						editor:setError(list.message)
					else
						showPage("world")
					end
				end
			end
		end
		characterPage:setMessage(list.message, if failed then Style.Colour.Red else GRAY)
		if page == "world" and playingAs then
			local chosen = CharacterRules.find(list.characters, list.selected)
			playingAs:setText(if chosen then `Playing as {chosen.name}` else "")
		end
	end)
	-- The user's own avatar for the editor.
	ClientNet.on(Protocol.ServerMessage.Avatar, function(payload: buffer)
		local purpose, look = CharacterSync.decodeAvatar(payload)
		if purpose == nil or look == nil or entered or editor == nil or page ~= "editor" then
			return
		end
		editor:setSnapshot(look)
	end)
	ClientNet.on(Protocol.ServerMessage.WorldList, function(payload: buffer)
		local list, _, message = Protocol.decodeWorldList(payload)
		if list == nil or entered then
			return
		end
		worlds = list
		selectedId = WorldListRules.keepSelection(worlds, selectedId)
		listBusy = false
		if #worlds == 0 and message == "" then
			message = "No worlds are saved yet: create one"
		end
		setLoadNote(message, GRAY)
		buildRows()
		refreshLoad()
	end)
	-- Whether worlds can be saved here, and a load's progress (Ui/SaveIndicator hears them).
	table.insert(
		connections,
		SaveIndicator.stateChanged:Connect(function()
			if page == "title" or page == "world" then
				refreshTitle()
			end
		end)
	)
	table.insert(
		connections,
		SaveIndicator.loading:Connect(function(done: number, total: number)
			local line = WorldListRules.loading(done, total)
			loadingText = line
			if page == "creating" and pending == "load" then
				creatingLine:setText(line)
			elseif page == "title" or page == "world" then
				refreshTitle()
			end
		end)
	)
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
	table.insert(
		connections,
		player:GetAttributeChangedSignal(WorldSettings.OPERATOR_ATTRIBUTE):Connect(function()
			if page == "title" or page == "world" then
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
	-- Escape (see the header): the key or Roblox's menu opening, whichever comes first.
	local lastEscape = -math.huge
	local function escape()
		local now = os.clock()
		if now - lastEscape < ESCAPE_REPEAT then
			return
		end
		lastEscape = now
		back(true)
	end
	table.insert(connections, GuiService.MenuOpened:Connect(escape))
	table.insert(
		connections,
		GuiService.MenuClosed:Connect(function()
			lastEscape = os.clock()
		end)
	)
	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if input.KeyCode == Enum.KeyCode.Escape then
				-- (Processed or not: Roblox's menu may have claimed the key.)
				if not GuiService.MenuIsOpen then
					escape()
				end
			elseif input.KeyCode == Enum.KeyCode.ButtonB and not processed then
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

--!strict
--[[
	The in-game HUD, Minecraft's:

	  hotbar     9 slots at the bottom centre with the selection frame, item icons, counts and the
	             durability bars of worn tools.
	             Click or tap a slot to select it; the Hotbar Slot key bindings (1-9: Settings/
	             Keybinds), the mouse wheel (down = next slot, with the Scroll Wheel setting on
	             Hotbar: `setWheelSelects`, by default Config.Interaction.ScrollWheelHotbar) and
	             gamepad L1 / R1 select too. The wheel is bound through ContextActionService at
	             High priority and sunk, so the camera does not zoom; its turns add up as
	             Minecraft's MouseHandler.onScroll does (Scroll Sensitivity, Discrete Scrolling:
	             `setScrolling`, PlayerSettings.scroll), one slot a whole step, and open screens
	             get the scaled turn. The attack indicator's square sits right of the hotbar
	             (`setAttackIndicator`, Ui/AttackIndicator).
	  item name  the held item's name above the hotbar for 2 s after the selection changes,
	             fading over the last half second
	  hearts     survival and adventure only (GameMode.isSurvivalLike, Minecraft's canHurtPlayer):
	             10 hearts (the Humanoid's health as 20 half hearts) and, above them, 10 armor icons
	             when armor is worn (Items.armorPoints). Drawn as pixel art from Frames. Low health
	             makes them shake; damage makes their outline blink.
	  knowledge  survival and adventure only (Minecraft's hasExperience), with Config.Progression on:
	             Minecraft's experience bar, 182 x 5 just above the hotbar (KNOWLEDGE_Y, where
	             Minecraft's layout already leaves it room: no row moved for it), filling green with
	             the progress into the level (Shared/Progression/Knowledge.progress), and the level
	             in green with a black outline over its middle, between the hearts and the
	             droplets (shown from level 1, Minecraft's). From Player/ProgressionState.
	  survival   Tough As Nails (Ui/SurvivalHud, survival and adventure only too): the thirst
	             droplets on the right level with the hearts, the temperature thermometer above
	             them (level with the armor), Climate Clemency's time left and the warmth and
	             chill effects a row above the item name's (a long centred name reaches the
	             right side, where they are), the numbers a held Thermometer reads above those,
	             and frost or heat closing in from the screen's edges.
	  touch      a "..." button at the end of the hotbar opens the inventory (for spectators it is
	             the spectator menu's middle click), a gear at its start the Options menu, and a
	             skill tree button over the gear the skill tree (Ui/SkillTreeScreen; with
	             Config.Progression on)

	Game modes (Shared/GameMode): creative has no hearts and its item name sits lower. Spectators
	(no showsHud) get neither the hotbar nor its item name, hearts or armor: their number keys,
	middle click (Interaction/BlockInteraction), gamepad L1 / R1 / DPad up and the "..." button
	open the spectator menu in the hotbar's place instead (Ui/SpectatorGui), and their wheel moves
	its selection, or the flying speed while it is closed.

	Roblox's own health bar and backpack are turned off.

	The screens (Ui/Screens) set the mode: "play" (input above), "creative" (the creative screen is
	open: the hotbar stays, it is that screen's hotbar row, and the screens handle its clicks and
	hover) or "hidden" (the survival inventory has its own hotbar row). While the game mode switcher
	is open (Ui/GameModeSwitcher, `setInputTaken`) the keys and the wheel do nothing here, as no
	key mapping works while a Minecraft Screen is open; the hotbar stays drawn.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Knowledge = require(Shared.Progression.Knowledge)
local PlayerSettings = require(Shared.PlayerSettings)
local Types = require(Shared.Inventory.Types)

local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local Keybinds = require(script.Parent.Parent.Settings.Keybinds)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local ProgressionState = require(script.Parent.Parent.Player.ProgressionState)
local ItemIcon = require(script.Parent.ItemIcon)
local SpectatorGui = require(script.Parent.SpectatorGui)
local SurvivalHud = require(script.Parent.SurvivalHud)
local Style = require(script.Parent.Style)

export type Mode = "play" | "creative" | "hidden"

local HOTBAR = Types.HOTBAR_SIZE
-- Layout (GUI pixels): Minecraft's hotbar is 182 x 22, hearts 17 px above its top, armor 10
-- above them, the item name 37 above (23 without hearts).
local WIDTH = 182
local TOUCH_BUTTON = 22
local HEIGHT = 70
local BAR_Y = HEIGHT - 22
local HEARTS_Y = BAR_Y - 17
local ARMOR_Y = HEARTS_Y - 10
local NAME_Y_SURVIVAL = BAR_Y - 37
local NAME_Y_CREATIVE = BAR_Y - 23
-- Minecraft's experience bar: 182 x 5, 7 above the hotbar's top (its y is height - 29); the level
-- 13 above it (height - 35), centred, over the gap between the hearts and the droplets.
local KNOWLEDGE_Y = BAR_Y - 7
local KNOWLEDGE_H = 5
local LEVEL_Y = BAR_Y - 13
local LEVEL_GREEN = Color3.fromRGB(128, 255, 32)
local KNOWLEDGE_EMPTY = Color3.fromRGB(30, 42, 20)
local KNOWLEDGE_FILL = Color3.fromRGB(110, 220, 40)
local KNOWLEDGE_SHINE = Color3.fromRGB(170, 255, 90)
-- The touch skill tree button's art (11 x 10): three nodes joined, G the nodes, # the lines.
local SKILLS_ART = {
	"....GGG....",
	"....GGG....",
	".....#.....",
	".#########.",
	".#.......#.",
	"GGG.....GGG",
	"GGG.....GGG",
	".#.......#.",
	".#.......#.",
	"GGG.....GGG",
}
-- The spectator menu's label: 35 pixels above the screen's bottom (SpectatorGui.renderTooltip).
local SPECTATOR_LABEL_Y = HEIGHT - 35
-- The name shows this long (Minecraft: 40 ticks), fading over the last part (10 ticks).
local NAME_TIME = 2
local NAME_FADE = 0.5
-- Hearts blink this long after damage, and shake at this many half hearts or less.
local BLINK_TIME = 1
local SHAKE_AT = 4
local TICK = 0.05

--[[
	9 x 8 pixel art. K outline, L / R the left / right half of the fill, H a highlight (left half).
	The half sprites show the left half filled, like Minecraft's.
]]
local HEART = {
	".KK...KK.",
	"KHLK.KRRK",
	"KHLLKRRRK",
	"KLLLLRRRK",
	".KLLLRRK.",
	"..KLLRK..",
	"...KLK...",
	"....K....",
}
local ARMOR = {
	".KK...KK.",
	"KHLK.KRRK",
	"KHLLKRRRK",
	".KLLLRRK.",
	".KLLLRRK.",
	".KLLLRRK.",
	".KLLLRRK.",
	".KKKKKKK.",
}

local HEART_RED = Color3.fromRGB(219, 21, 21)
local HEART_SHINE = Color3.fromRGB(255, 170, 170)
local HEART_EMPTY = Color3.fromRGB(46, 30, 30)
local HEART_EMPTY_SHINE = Color3.fromRGB(70, 52, 52)
local ARMOR_FULL = Color3.fromRGB(200, 200, 205)
local ARMOR_SHINE = Color3.fromRGB(255, 255, 255)
local ARMOR_EMPTY = Color3.fromRGB(50, 50, 52)
local OUTLINE = Color3.fromRGB(16, 16, 16)
local BLINK_OUTLINE = Color3.fromRGB(255, 255, 255)

type Icon = { frame: Frame, parts: { [string]: { Frame } }, state: number }

local Hud = {}

local mode: Mode = "play"
local started = false
local hudGui: ScreenGui? = nil
local hudVisible = true
local wheelHandler: ((delta: number) -> ())? = nil
-- Something over the game that is not a screen has the keys (the game mode switcher).
local inputTaken = false
local inventoryHandler: (() -> ())? = nil
local settingsHandler: (() -> ())? = nil
local skillsHandler: (() -> ())? = nil
-- The wheel selects hotbar slots (else it zooms the camera).
local wheelSelects = Config.Interaction.ScrollWheelHotbar
-- The Mouse Settings' scrolling (PlayerSettings.scroll): the settings values and the rest of the
-- wheel's turns not yet a whole step.
local scrollValues: PlayerSettings.Values? = nil
local scrolled = 0
-- The attack indicator beside the hotbar (Ui/AttackIndicator): its frame, fill and progress.
local attackSlot: Frame? = nil
local attackFill: Frame? = nil
local attackProgress: number? = nil
local previewWindow: Types.Window? = nil
local dirty = true

local cells: { TextButton } = {}
-- The hotbar and the touch button (for Hud.covers).
local coverage: { GuiObject } = {}
local icons: { ItemIcon.ItemIcon } = {}
local hovers: { Frame } = {}

-- What the screens show while open in creative ("creative") or survival ("hidden"); "play" else.
function Hud.setMode(value: Mode)
	if value ~= mode then
		mode = value
		dirty = true
		-- Gamepads can reach the hotbar from the creative grid.
		for _, cell in cells do
			cell.Selectable = value == "creative"
		end
	end
end

-- While true, the hotbar's (or the spectator menu's) keys and the wheel do nothing: the game mode
-- switcher (Ui/GameModeSwitcher, which Screens and so this can't require) is open.
function Hud.setInputTaken(value: boolean)
	inputTaken = value
end

-- Shows or hides the whole HUD (the world map hides it while open).
function Hud.setVisible(value: boolean)
	hudVisible = value
	if hudGui then
		hudGui.Enabled = value
	end
end

function Hud.mode(): Mode
	return mode
end

-- The mouse wheel while a screen is open goes to `handler` (e.g. scrolling the creative grid).
function Hud.onScreenWheel(handler: (delta: number) -> ())
	wheelHandler = handler
end

-- The touch "..." button calls `handler` (the screens open the inventory).
function Hud.onInventoryButton(handler: () -> ())
	inventoryHandler = handler
end

-- The touch gear button calls `handler` (the Options menu).
function Hud.onSettingsButton(handler: () -> ())
	settingsHandler = handler
end

-- The touch skill tree button calls `handler` (Ui/SkillTreeScreen).
function Hud.onSkillsButton(handler: () -> ())
	skillsHandler = handler
end

-- The Scroll Wheel setting: the wheel selects hotbar slots (true) or zooms the camera.
function Hud.setWheelSelects(value: boolean)
	wheelSelects = value
end

-- The settings values whose Scroll Sensitivity and Discrete Scrolling the wheel follows.
function Hud.setScrolling(values: PlayerSettings.Values)
	scrollValues = values
	scrolled = 0
end

--[[
	The hotbar attack indicator (Ui/AttackIndicator): the weapon's recovery 0..1 fills an 18 x 18
	square right of the hotbar from the bottom (Minecraft's hotbar_attack_indicator); nil hides it.
]]
function Hud.setAttackIndicator(progress: number?)
	-- (Filled pixels of the 16 inside the outline.)
	local shown = if progress then math.clamp(math.floor(progress * 16), 0, 16) else nil
	if shown == attackProgress then
		return
	end
	attackProgress = shown
	local slot, fill = attackSlot, attackFill
	if slot and fill then
		slot.Visible = shown ~= nil
		if shown then
			fill.Size = UDim2.fromOffset(16, shown)
			fill.Position = UDim2.fromOffset(1, 17 - shown)
		end
	end
end

-- The on-screen area of hotbar slot 1..9 (the creative screen clicks it like a window slot).
function Hud.hotbarCell(slot: number): GuiObject
	return cells[slot]
end

-- Is `point` (screen pixels) on the hotbar or the touch inventory button?
function Hud.covers(point: Vector2): boolean
	for _, object in coverage do
		if Style.contains(object, point) and Style.shown(object) then
			return true
		end
	end
	return false
end

-- The hover overlay of hotbar slot 1..9 (nil: none).
function Hud.setHover(slot: number?)
	for i, hover in hovers do
		local on = i == slot
		if hover.Visible ~= on then
			hover.Visible = on
		end
	end
end

-- Draws the hotbar from this window (a drag preview) instead of the inventory; nil = the inventory.
function Hud.setPreview(window: Types.Window?)
	previewWindow = window
	dirty = true
end

local function disableCoreGui()
	task.spawn(function()
		for _ = 1, 30 do
			local ok = pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
			end)
			if ok then
				return
			end
			task.wait(0.5)
		end
	end)
end

-- The hotbar's bar at (x, y): translucent black, a dark outline, and each cell's light and dark rim.
local function drawBar(parent: Instance, x: number, y: number): Frame
	local bar = Style.frame(parent, x, y, WIDTH, 22, Color3.new(0, 0, 0), 1)
	bar.BackgroundTransparency = 0.55
	Style.border(bar, 0, 0, WIDTH, 22, 1, Color3.fromRGB(20, 20, 20), 2)
	for i = 1, HOTBAR do
		local cellX = 1 + (i - 1) * 20
		-- Each cell has a light rim top-left and a darker one bottom-right.
		local rim = Style.border(bar, cellX, 1, 20, 20, 2, Color3.fromRGB(150, 150, 150), 3)
		rim[2].BackgroundColor3 = Color3.fromRGB(96, 96, 96)
		rim[4].BackgroundColor3 = Color3.fromRGB(96, 96, 96)
		for _, frame in rim do
			frame.BackgroundTransparency = 0.15
		end
	end
	return bar
end

-- The selection frame, 24 x 24 around a cell (placed by the caller).
local function drawSelection(parent: Instance): Frame
	local selection = Instance.new("Frame")
	selection.BackgroundTransparency = 1
	selection.Size = UDim2.fromOffset(24, 24)
	selection.ZIndex = 6
	selection.Parent = parent
	Style.border(selection, 0, 0, 24, 24, 1, Color3.new(0, 0, 0), 1)
	Style.border(selection, 1, 1, 22, 22, 2, Color3.new(1, 1, 1), 2)
	Style.border(selection, 3, 3, 18, 18, 1, Color3.fromRGB(40, 40, 40), 2)
	return selection
end

local function newIcon(parent: Instance, x: number, art: { string }): Icon
	local frame = Instance.new("Frame")
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromOffset(9, 9)
	frame.Position = UDim2.fromOffset(x, 0)
	frame.Parent = parent
	local parts = Style.pixelArt(frame, 0, 0, art, { K = OUTLINE, L = OUTLINE, R = OUTLINE, H = OUTLINE }, 1)
	return { frame = frame, parts = parts, state = -1 }
end

-- state: 0 empty, 1 half, 2 full.
local function paintIcon(icon: Icon, state: number, fill: Color3, shine: Color3, empty: Color3, emptyShine: Color3)
	if icon.state == state then
		return
	end
	icon.state = state
	Style.paint(icon.parts.L, if state >= 1 then fill else empty)
	Style.paint(icon.parts.H, if state >= 1 then shine else emptyShine)
	Style.paint(icon.parts.R, if state >= 2 then fill else empty)
end

function Hud.start()
	if started then
		return
	end
	started = true
	disableCoreGui()

	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "IceVoxelHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 10
	gui.Enabled = hudVisible
	hudGui = gui

	local canvas = Instance.new("Frame")
	canvas.Name = "Hud"
	canvas.BackgroundTransparency = 1
	canvas.AnchorPoint = Vector2.new(0.5, 1)
	canvas.Position = UDim2.new(0.5, 0, 1, -1)
	canvas.Size = UDim2.fromOffset(WIDTH, HEIGHT)
	canvas.Parent = gui
	local scale = Instance.new("UIScale")
	scale.Parent = canvas

	--[[ Hotbar (hidden for spectators, who get the spectator menu in its place) ]]

	local hotbar = Instance.new("Frame")
	hotbar.Name = "Hotbar"
	hotbar.BackgroundTransparency = 1
	hotbar.Size = UDim2.fromScale(1, 1)
	hotbar.Parent = canvas
	local bar = drawBar(hotbar, 0, BAR_Y)
	table.insert(coverage, bar)
	for i = 1, HOTBAR do
		local x = 1 + (i - 1) * 20
		local cell = Instance.new("TextButton")
		cell.Name = `Slot{i}`
		cell.Text = ""
		cell.BackgroundTransparency = 1
		cell.AutoButtonColor = false
		cell.Position = UDim2.fromOffset(x, BAR_Y + 1)
		cell.Size = UDim2.fromOffset(20, 20)
		cell.ZIndex = 4
		cell.Selectable = false
		cell.Parent = hotbar
		cell.Activated:Connect(function()
			if mode == "play" then
				ClientInventory.select(i)
			end
		end)
		cells[i] = cell
		icons[i] = ItemIcon.new(hotbar, x + 2, BAR_Y + 3, 5)
		hovers[i] = Style.hover(hotbar, x + 2, BAR_Y + 3, 7)
	end

	-- The selection frame, 24 x 24 around the selected cell.
	local selection = drawSelection(hotbar)

	-- The attack indicator's square right of the hotbar (Ui/AttackIndicator; placed by
	-- updateScale: beside the touch button on touch screens), hidden while the weapon is ready.
	local attack = Style.frame(hotbar, WIDTH + 6, BAR_Y + 2, 18, 18, Color3.new(0, 0, 0), 1)
	attack.Name = "AttackIndicator"
	attack.BackgroundTransparency = 0.55
	attack.Visible = false
	Style.border(attack, 0, 0, 18, 18, 1, Color3.fromRGB(20, 20, 20), 2)
	attackFill = Style.frame(attack, 1, 17, 16, 0, Color3.fromRGB(200, 200, 200), 3)
	attackSlot = attack

	-- The spectator menu, in the hotbar's place.
	SpectatorGui.build(canvas, 0, BAR_Y, SPECTATOR_LABEL_Y, drawBar, drawSelection)

	-- The touch "..." button opens the inventory.
	local more = Style.frame(canvas, WIDTH + 2, BAR_Y, TOUCH_BUTTON, 22, Color3.new(0, 0, 0), 1)
	more.BackgroundTransparency = 0.55
	table.insert(coverage, more)
	Style.border(more, 0, 0, TOUCH_BUTTON, 22, 1, Color3.fromRGB(20, 20, 20), 2)
	Style.border(more, 1, 1, TOUCH_BUTTON - 2, 20, 2, Color3.fromRGB(150, 150, 150), 3)
	for dot = 0, 2 do
		Style.frame(more, 5 + dot * 5, 10, 2, 2, Color3.new(1, 1, 1), 4)
	end
	local moreButton = Instance.new("TextButton")
	moreButton.Text = ""
	moreButton.BackgroundTransparency = 1
	moreButton.Size = UDim2.fromScale(1, 1)
	moreButton.ZIndex = 5
	moreButton.Parent = more
	moreButton.Activated:Connect(function()
		if mode == "play" and GameMode.isSpectator(ClientInventory.mode()) then
			-- (Spectators have no inventory: the button is their middle click.)
			SpectatorGui.middleClick()
		elseif inventoryHandler then
			SoundPlayer.click()
			inventoryHandler()
		end
	end)

	-- The touch gear at the hotbar's other end opens the Options menu (the space both buttons
	-- take is kept free on touch screens, so the hotbar stays centred).
	local gear = Style.frame(canvas, -(TOUCH_BUTTON + 2), BAR_Y, TOUCH_BUTTON, 22, Color3.new(0, 0, 0), 1)
	gear.BackgroundTransparency = 0.55
	table.insert(coverage, gear)
	Style.border(gear, 0, 0, TOUCH_BUTTON, 22, 1, Color3.fromRGB(20, 20, 20), 2)
	Style.border(gear, 1, 1, TOUCH_BUTTON - 2, 20, 2, Color3.fromRGB(150, 150, 150), 3)
	Style.gear(gear, 5, 5, 4)
	local gearButton = Instance.new("TextButton")
	gearButton.Text = ""
	gearButton.BackgroundTransparency = 1
	gearButton.Size = UDim2.fromScale(1, 1)
	gearButton.ZIndex = 6
	gearButton.Parent = gear
	gearButton.Activated:Connect(function()
		if settingsHandler then
			SoundPlayer.click()
			settingsHandler()
		end
	end)

	-- The touch skill tree button over the gear (progression on).
	local skills = Style.frame(canvas, -(TOUCH_BUTTON + 2), BAR_Y - 24, TOUCH_BUTTON, 22, Color3.new(0, 0, 0), 1)
	skills.BackgroundTransparency = 0.55
	table.insert(coverage, skills)
	Style.border(skills, 0, 0, TOUCH_BUTTON, 22, 1, Color3.fromRGB(20, 20, 20), 2)
	Style.border(skills, 1, 1, TOUCH_BUTTON - 2, 20, 2, Color3.fromRGB(150, 150, 150), 3)
	Style.pixelArt(skills, 6, 6, SKILLS_ART, { G = LEVEL_GREEN, ["#"] = Style.Colour.Text }, 4)
	local skillsButton = Instance.new("TextButton")
	skillsButton.Text = ""
	skillsButton.BackgroundTransparency = 1
	skillsButton.Size = UDim2.fromScale(1, 1)
	skillsButton.ZIndex = 6
	skillsButton.Parent = skills
	skillsButton.Activated:Connect(function()
		if skillsHandler then
			SoundPlayer.click()
			skillsHandler()
		end
	end)

	--[[ Knowledge (Minecraft's experience bar) ]]

	local knowledge = Instance.new("Frame")
	knowledge.Name = "Knowledge"
	knowledge.BackgroundTransparency = 1
	knowledge.Size = UDim2.fromScale(1, 1)
	knowledge.Visible = false
	knowledge.Parent = canvas
	local knowledgeBar = Style.frame(knowledge, 0, KNOWLEDGE_Y, WIDTH, KNOWLEDGE_H, Color3.new(0, 0, 0), 2)
	Style.frame(knowledgeBar, 1, 1, WIDTH - 2, KNOWLEDGE_H - 2, KNOWLEDGE_EMPTY, 3)
	local knowledgeFill = Style.frame(knowledgeBar, 1, 1, 0, KNOWLEDGE_H - 2, KNOWLEDGE_FILL, 4)
	Style.frame(knowledgeFill, 0, 0, WIDTH, 1, KNOWLEDGE_SHINE, 5)
	knowledgeFill.ClipsDescendants = true
	-- The level: green over a black outline (Minecraft draws it four times offset in black first).
	local levelOutline: { TextLabel } = {}
	for _, offset in { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } } do
		local label = Style.text(
			knowledge,
			"",
			offset[1],
			LEVEL_Y + offset[2],
			WIDTH,
			8,
			Color3.new(0, 0, 0),
			6,
			Enum.TextXAlignment.Center
		)
		table.insert(levelOutline, label)
	end
	local levelLabel = Style.text(knowledge, "", 0, LEVEL_Y, WIDTH, 8, LEVEL_GREEN, 7, Enum.TextXAlignment.Center)
	local knowledgeDirty = true
	ProgressionState.changed:Connect(function()
		knowledgeDirty = true
	end)

	--[[ Hearts and armor ]]

	local hearts: { Icon } = {}
	local armor: { Icon } = {}
	local heartRow = Instance.new("Frame")
	heartRow.BackgroundTransparency = 1
	heartRow.Position = UDim2.fromOffset(0, HEARTS_Y)
	heartRow.Size = UDim2.fromOffset(81, 9)
	heartRow.ZIndex = 2
	heartRow.Parent = canvas
	local armorRow = Instance.new("Frame")
	armorRow.BackgroundTransparency = 1
	armorRow.Position = UDim2.fromOffset(0, ARMOR_Y)
	armorRow.Size = UDim2.fromOffset(81, 9)
	armorRow.ZIndex = 2
	armorRow.Parent = canvas
	for i = 1, 10 do
		hearts[i] = newIcon(heartRow, (i - 1) * 8, HEART)
		armor[i] = newIcon(armorRow, (i - 1) * 8, ARMOR)
	end
	-- Thirst and temperature (the droplets level with the hearts, the thermometer level with the
	-- armor, the clemency and effects above the item name's row, which long names fill across,
	-- all on the right).
	SurvivalHud.build(canvas, { width = WIDTH, rowY = HEARTS_Y, gaugeY = ARMOR_Y, statusY = NAME_Y_SURVIVAL - 10 })

	--[[ Held item name ]]

	local name, nameShadow =
		Style.shadowText(hotbar, "", 0, NAME_Y_SURVIVAL, WIDTH, 8, Style.Colour.Text, 8, Enum.TextXAlignment.Center)

	local function updateScale()
		local touch = UserInputService.TouchEnabled
		more.Visible = touch
		gear.Visible = touch
		skills.Visible = touch and ProgressionState.enabled()
		local width = if touch then WIDTH + 2 * (TOUCH_BUTTON + 2) else WIDTH
		scale.Scale = Style.guiScale(gui.AbsoluteSize, width, HEIGHT, touch)
		attack.Position = UDim2.fromOffset(WIDTH + 6 + (if touch then TOUCH_BUTTON + 2 else 0), BAR_Y + 2)
	end
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateScale)
	Style.scaleChanged:Connect(updateScale)
	gui.Parent = player:WaitForChild("PlayerGui")
	updateScale()

	ClientInventory.changed:Connect(function()
		dirty = true
	end)

	--[[ Every frame ]]

	local lastSlot, lastItem = 0, -1
	local nameUntil = 0
	local lastHalves = -1
	local blinkUntil = 0
	local blinking = false
	local nextShake = 0
	local lastPoints = -1
	local shown = true

	RunService.RenderStepped:Connect(function()
		local now = os.clock()
		local visible = mode ~= "hidden"
		if visible ~= shown then
			shown = visible
			canvas.Visible = visible
		end
		local gameMode = ClientInventory.mode()
		SpectatorGui.render(now, visible and mode == "play" and GameMode.isSpectator(gameMode))
		if not visible then
			return
		end
		local showsHud = GameMode.showsHud(gameMode)
		if hotbar.Visible ~= showsHud then
			hotbar.Visible = showsHud
		end
		local window = previewWindow or ClientInventory.window()
		local inventory = window.inventory
		-- Hearts, armor and the higher item name: Minecraft's canHurtPlayer (survival, adventure).
		local survival = GameMode.isSurvivalLike(gameMode)

		if dirty then
			dirty = false
			for i = 1, HOTBAR do
				local stack = inventory.slots[i]
				icons[i]:set(stack and stack.item, stack and stack.count, stack and stack.damage, stack and stack.data)
			end
			selection.Position = UDim2.fromOffset(-1 + (inventory.selected - 1) * 20, BAR_Y - 1)
		end

		-- The held item's name, shown when the selection or the item in it changes.
		local held = ClientInventory.selectedStack()
		local item = if held then held.item else 0
		if ClientInventory.selected() ~= lastSlot or item ~= lastItem then
			lastSlot, lastItem = ClientInventory.selected(), item
			if held then
				name.Text = Items.displayName(item)
				nameShadow.Text = name.Text
				nameUntil = now + NAME_TIME
			else
				nameUntil = 0
			end
		end
		local remaining = nameUntil - now
		-- (Not over an open screen.)
		local alpha = if mode == "play" then math.clamp(remaining / NAME_FADE, 0, 1) else 0
		name.Visible = alpha > 0
		nameShadow.Visible = alpha > 0
		if alpha > 0 then
			name.TextTransparency = 1 - alpha
			nameShadow.TextTransparency = 1 - alpha
			local y = if survival then NAME_Y_SURVIVAL else NAME_Y_CREATIVE
			name.Position = UDim2.fromOffset(0, y)
			nameShadow.Position = UDim2.fromOffset(1, y + 1)
		end

		-- Hearts and armor (survival).
		local points = if survival then Items.armorPoints(inventory.armor) else 0
		if heartRow.Visible ~= survival then
			heartRow.Visible = survival
		end
		if armorRow.Visible ~= (points > 0) then
			armorRow.Visible = points > 0
		end
		SurvivalHud.render(now, survival, if held then held.item else nil)

		-- Knowledge (survival and adventure, once the server sent it).
		local status = ProgressionState.get()
		local knows = survival and status ~= nil
		if knowledge.Visible ~= knows then
			knowledge.Visible = knows
		end
		if knows and status and knowledgeDirty then
			knowledgeDirty = false
			local level, into, needed = Knowledge.progress(status.points)
			knowledgeFill.Size = UDim2.fromOffset(math.floor(into / math.max(needed, 1) * (WIDTH - 2)), KNOWLEDGE_H - 2)
			local text = if level > 0 then tostring(level) else ""
			levelLabel.Text = text
			for _, label in levelOutline do
				label.Text = text
			end
		end
		if not survival then
			return
		end
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local halves = 0
		if humanoid and humanoid.MaxHealth > 0 then
			halves = math.clamp(math.ceil(humanoid.Health / humanoid.MaxHealth * 20 - 1e-6), 0, 20)
		end
		if halves < lastHalves then
			blinkUntil = now + BLINK_TIME
		end
		lastHalves = halves
		local blink = now < blinkUntil and math.floor((blinkUntil - now) / 0.15) % 2 == 0
		local shake = halves <= SHAKE_AT and now >= nextShake
		if shake then
			nextShake = now + TICK
		end
		local repaintOutline = blink ~= blinking
		blinking = blink
		for i, heart in hearts do
			local state = math.clamp(halves - (i - 1) * 2, 0, 2)
			paintIcon(heart, state, HEART_RED, HEART_SHINE, HEART_EMPTY, HEART_EMPTY_SHINE)
			if repaintOutline then
				Style.paint(heart.parts.K, if blink then BLINK_OUTLINE else OUTLINE)
			end
			if shake then
				heart.frame.Position = UDim2.fromOffset((i - 1) * 8, math.random(0, 1))
			elseif halves > SHAKE_AT and heart.frame.Position.Y.Offset ~= 0 then
				heart.frame.Position = UDim2.fromOffset((i - 1) * 8, 0)
			end
		end
		if points ~= lastPoints then
			lastPoints = points
			for i, icon in armor do
				local state = math.clamp(points - (i - 1) * 2, 0, 2)
				paintIcon(icon, state, ARMOR_FULL, ARMOR_SHINE, ARMOR_EMPTY, ARMOR_EMPTY)
			end
		end
	end)

	--[[ Input ]]

	local function step(delta: number)
		local slot = (ClientInventory.selected() - 1 + delta) % HOTBAR + 1
		ClientInventory.select(slot)
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or mode ~= "play" or inputTaken then
			return
		end
		-- (The Hotbar Slot key bindings: 1-9 by default.)
		local slot = Keybinds.hotbarSlot(input)
		local spectator = GameMode.isSpectator(ClientInventory.mode())
		if slot then
			if spectator then
				SpectatorGui.hotbarKey(slot)
			else
				ClientInventory.select(slot)
			end
		elseif input.KeyCode == Enum.KeyCode.ButtonR1 then
			if spectator then
				SpectatorGui.step(1)
			else
				step(1)
			end
		elseif input.KeyCode == Enum.KeyCode.ButtonL1 then
			if spectator then
				SpectatorGui.step(-1)
			else
				step(-1)
			end
		elseif input.KeyCode == Enum.KeyCode.DPadUp and spectator then
			-- (A gamepad's middle click: uses the selected slot.)
			SpectatorGui.middleClick()
		end
	end)

	-- The wheel picks hotbar slots (down = next, like Minecraft) instead of zooming the camera,
	-- and scrolls the screens while one is open.
	ContextActionService:BindActionAtPriority("IceVoxelHotbarWheel", function(_, state, input)
		if state ~= Enum.UserInputState.Change then
			return Enum.ContextActionResult.Pass
		end
		local raw = input.Position.Z
		if inputTaken then
			-- (Sunk all the same: the camera does not zoom either.)
			return Enum.ContextActionResult.Sink
		end
		local spectator = mode == "play" and GameMode.isSpectator(ClientInventory.mode())
		if mode == "play" and not spectator and not wheelSelects then
			-- (The Scroll Wheel setting on Zoom: the camera's.)
			return Enum.ContextActionResult.Pass
		end
		-- Minecraft's MouseHandler.onScroll: the Scroll Sensitivity and Discrete Scrolling
		-- settings; an open screen gets the scaled turn, else whole steps come out of the turns
		-- added up (PlayerSettings.scrollTurn / scroll).
		local values = scrollValues
		if mode ~= "play" then
			local turn = if values and raw ~= 0 then PlayerSettings.scrollTurn(raw, values) else raw
			if wheelHandler and turn ~= 0 then
				wheelHandler(turn)
			end
			return Enum.ContextActionResult.Sink
		end
		local steps = raw
		if values and raw ~= 0 then
			steps, scrolled = PlayerSettings.scroll(scrolled, raw, values)
		end
		if steps == 0 then
			return Enum.ContextActionResult.Sink
		end
		if spectator then
			-- The spectator menu's selection, or the flying speed (MouseHandler.onScroll).
			SpectatorGui.wheel(steps)
			return Enum.ContextActionResult.Sink
		end
		-- (Inventory.swapPaint: one slot a step, whatever its size.)
		step(if steps < 0 then 1 else -1)
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.UserInputType.MouseWheel)
end

return Hud

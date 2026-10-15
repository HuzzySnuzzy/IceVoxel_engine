--!strict
--[[
	The in-game HUD in the survival look: a survival game's quickbar at the bottom centre, its
	status icons at the bottom right, and Minecraft's controls behind them.

	  canvas     HudLayout.CANVAS (182 x 46 GUI pixels; the touch buttons beside the bar make it
	             230 wide on touch screens), centred at the bottom of the safe area, one pixel and
	             HudLayout.lift (5 % of the screen's height on a PC, none on touch) above it, at the
	             GUI scale fitted to the screen. Marked for the survival look (Style.Dayz.mark), so
	             the touch buttons' tooltips come in the dark box.
	  quickbar   Ui/Quickbar at HudLayout.QUICK.bar: nine cells, the selected one olive under its
	             item with a white outline, the key numbers, the items in the survival look; it
	             never fades unless Config.Ui.QuickbarFadeAfter says so. Click or tap a slot to
	             select it (the Slot1..9 buttons on HudLayout.quickHit, which the creative screen
	             clicks and hovers as its hotbar row); the Hotbar Slot key bindings (1-9:
	             Settings/Keybinds), the mouse wheel (down = next slot, with the Scroll Wheel
	             setting on Hotbar: `setWheelSelects`, by default
	             Config.Interaction.ScrollWheelHotbar) and gamepad L1 / R1 select too. The wheel is
	             bound through ContextActionService at High priority and sunk, so the camera does not
	             zoom; its turns add up as Minecraft's MouseHandler.onScroll does (Scroll
	             Sensitivity, Discrete Scrolling: `setScrolling`, PlayerSettings.scroll), one slot a
	             whole step, and open screens get the scaled turn.
	  in hands   the held item's box over the bar (HudLayout.QUICK.name, Theme.Size.NAME_H tall,
	             StripBody grey, centred, as wide as its text): its condition's dot and its name
	             (Theme.handsLines, made only when the held stack changes) for Theme.Time.NAME
	             seconds after the selection or the item in it changes, fading over
	             Theme.Time.NAME_FADE; held while a Thermometer is the held item (with Tough As
	             Nails' temperature on, survival and adventure), with its reading after the name:
	             the body temperature and its target, each in its zone's colour (Theme.Zone), an
	             arrow between them in the way it is going (warming orange, cooling blue, white on
	             target). The text has a faint dark outline for bright skies. Held too while a
	             firearm or a magazine is the held item (Shared/Weapons): as in DayZ no rounds are
	             counted there; Ui/WeaponHud draws its small raise, reload and jam indicator and
	             the reload bar on the box's weapon anchor (`weaponAnchor`: a frame over the box,
	             its size, made with it).
	  attack     the attack indicator's square (Ui/AttackIndicator, the Hotbar setting): a quickbar
	             cell beside the bar (HudLayout.attackX: right of the "..." button on touch screens,
	             left of the bar otherwise, as the bottom right is the status icons') filling white
	             from the bottom as the weapon recovers (`setAttackIndicator`).
	  status     Ui/StatusCluster (built here, in this ScreenGui): the survival notifiers, badges and
	             knowledge bar where HudLayout puts them, or in the open inventory's band (Ui/
	             StatusDock); drawn every frame before the open-screen check, so they show while an
	             inventory is open. The frost and heat at the screen's edges (Ui/SurvivalHud) are
	             drawn every frame too.
	  touch      a "..." button at the end of the bar opens the inventory (for spectators it is the
	             spectator menu's middle click), a gear at its start the Options menu, a skill tree
	             button over the gear the skill tree (Ui/SkillTreeScreen; with Config.Progression
	             on), and a speech bubble over the "..." the chat (Ui/Chat, while it runs): quickbar
	             cells with white glyphs.

	Game modes (Shared/GameMode): spectators (no showsHud) get neither the quickbar nor the item
	box: their number keys, middle click (Interaction/BlockInteraction), gamepad L1 / R1 / DPad up
	and the "..." button open the spectator menu in the quickbar's place instead (Ui/SpectatorGui,
	drawn with Quickbar.drawBar and drawSelection), and their wheel moves its selection, or the
	flying speed while it is closed. The status icons show in survival and adventure only.

	Roblox's own health bar and backpack are turned off.

	The screens (Ui/Screens) set the mode: "play" (input above), "creative" (the creative screen is
	open: the quickbar stays, it is that screen's hotbar row, and the screens handle its clicks and
	hover) or "hidden" (the survival inventory has its own quickbar band; the status icons dock in
	it). While the game mode switcher is open (Ui/GameModeSwitcher, `setInputTaken`) the keys and
	the wheel do nothing here, as no key mapping works while a Minecraft Screen is open; the
	quickbar stays drawn.

	Nothing is made per frame: every frame compares what it would draw with what is drawn.
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
local PlayerSettings = require(Shared.PlayerSettings)
local Temperature = require(Shared.ToughAsNails.Temperature)
local Types = require(Shared.Inventory.Types)
local Weapons = require(Shared.Weapons)

local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local Keybinds = require(script.Parent.Parent.Settings.Keybinds)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local ProgressionState = require(script.Parent.Parent.Player.ProgressionState)
local SurvivalState = require(script.Parent.Parent.Player.SurvivalState)
local HoverTip = require(script.Parent.HoverTip)
local HudLayout = require(script.Parent.HudLayout)
local Quickbar = require(script.Parent.Quickbar)
local SpectatorGui = require(script.Parent.SpectatorGui)
local StatusCluster = require(script.Parent.StatusCluster)
local StatusLayout = require(script.Parent.StatusLayout)
local Style = require(script.Parent.Style)
local SurvivalHud = require(script.Parent.SurvivalHud)
local Theme = require(script.Parent.Theme)
local UiScale = require(script.Parent.UiScale)

export type Mode = "play" | "creative" | "hidden"

local HOTBAR = Types.HOTBAR_SIZE
-- Layout (GUI pixels, Ui/HudLayout): the canvas, the quickbar's top and the item box's.
local WIDTH = HudLayout.CANVAS.width
local HEIGHT = HudLayout.CANVAS.height
local BAR_Y = HudLayout.QUICK.bar
local NAME_Y = HudLayout.QUICK.name
local TOUCH_BUTTON = 22
-- The spectator menu's label: in the item box's row (SpectatorGui.renderTooltip).
local SPECTATOR_LABEL_Y = NAME_Y
-- The item that reads the temperature out.
local THERMOMETER = Items.id.Thermometer

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
local chatHandler: (() -> ())? = nil
-- Shows the touch buttons that have something to do (set by start).
local refreshButtons: () -> () = function() end
-- The wheel selects hotbar slots (else it zooms the camera).
local wheelSelects = Config.Interaction.ScrollWheelHotbar
-- The Mouse Settings' scrolling (PlayerSettings.scroll): the settings values and the rest of the
-- wheel's turns not yet a whole step.
local scrollValues: PlayerSettings.Values? = nil
local scrolled = 0
-- The attack indicator beside the bar (Ui/AttackIndicator): its cell, fill and progress.
local attackSlot: Frame? = nil
local attackFill: Frame? = nil
local attackProgress: number? = nil
local previewWindow: Types.Window? = nil
-- The item box's weapon anchor (Ui/WeaponHud) and the text scaling its labels follow.
local weaponFrame: Frame? = nil
local weaponScaled: Style.Scaled? = nil

local cells: { TextButton } = {}
-- The quickbar's bar and the touch buttons (for Hud.covers).
local coverage: { GuiObject } = {}
local quickbar: Quickbar.Quickbar? = nil

-- What the screens show while open in creative ("creative") or survival ("hidden"); "play" else.
function Hud.setMode(value: Mode)
	if value ~= mode then
		mode = value
		-- Gamepads can reach the quickbar from the creative grid.
		for _, cell in cells do
			cell.Selectable = value == "creative"
		end
	end
end

-- While true, the quickbar's (or the spectator menu's) keys and the wheel do nothing: the game
-- mode switcher (Ui/GameModeSwitcher, which Screens and so this can't require) is open.
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

-- The touch chat button calls `handler` (Ui/Chat); without one the button stays hidden.
function Hud.onChatButton(handler: () -> ())
	chatHandler = handler
	refreshButtons()
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
	The hotbar attack indicator (Ui/AttackIndicator): the weapon's recovery 0..1 fills the square
	beside the bar from the bottom (Minecraft's hotbar_attack_indicator); nil hides it.
]]
function Hud.setAttackIndicator(progress: number?)
	-- (Filled pixels of the 16 inside the cell.)
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

--[[
	The held item's box's weapon anchor (Ui/WeaponHud's indicator and reload bar): a transparent
	frame over the box, its size, shown and faded with it, and the text scaling its labels follow.
	nil before `start`.
]]
function Hud.weaponAnchor(): (Frame?, Style.Scaled?)
	return weaponFrame, weaponScaled
end

-- The on-screen area of hotbar slot 1..9 (the creative screen clicks it like a window slot).
function Hud.hotbarCell(slot: number): GuiObject
	return cells[slot]
end

-- Is `point` (screen pixels) on the quickbar or a touch button?
function Hud.covers(point: Vector2): boolean
	for _, object in coverage do
		if Style.contains(object, point) and Style.shown(object) then
			return true
		end
	end
	return false
end

-- The hover outline of hotbar slot 1..9 (nil: none).
function Hud.setHover(slot: number?)
	local bar = quickbar
	if bar then
		bar:setHover(slot)
	end
end

-- Draws the quickbar from this window (a drag preview) instead of the inventory; nil = the inventory.
function Hud.setPreview(window: Types.Window?)
	previewWindow = window
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

--[[
	A touch button (a quickbar cell's look, 22 x 22) at (x, y) with `art` in white centred, calling
	`pressed`; its frame and its button (the caller attaches the tooltip).
]]
local function touchButton(
	canvas: Frame,
	name: string,
	x: number,
	y: number,
	art: { string },
	pressed: () -> ()
): (Frame, TextButton)
	local Dayz = Style.Dayz
	local frame = Style.frame(canvas, x, y, TOUCH_BUTTON, TOUCH_BUTTON, Dayz.Colour.QuickCell, 3)
	frame.Name = name
	frame.BackgroundTransparency = Dayz.Alpha.QuickCell
	local w, h = #art[1], #art
	Dayz.glyph(frame, (TOUCH_BUTTON - w) // 2, (TOUCH_BUTTON - h) // 2, art, Dayz.Colour.Text, 2)
	local button = Instance.new("TextButton")
	button.Text = ""
	button.BackgroundTransparency = 1
	button.Size = UDim2.fromScale(1, 1)
	button.ZIndex = 6
	button.Parent = frame
	button.Activated:Connect(pressed)
	table.insert(coverage, frame)
	return frame, button
end

-- The held item's box (see the header): its parts.
type NameBox = {
	root: Frame,
	dot: Frame,
	name: TextLabel,
	value: TextLabel,
	arrow: Frame,
	target: TextLabel,
	-- (The texts and the arrow's frames, for the fade.)
	labels: { TextLabel },
	arrowParts: { Frame },
}

local function nameLabel(parent: Instance, scaled: Style.Scaled): TextLabel
	local label = Style.Dayz.label(parent, "", 0, 0, 0, 0, "body", Style.Dayz.Colour.Text, 3, nil, scaled)
	Style.Dayz.textStroke(label, "TextStrokeSoft")
	label.TextTruncate = Enum.TextTruncate.AtEnd
	return label
end

local function buildNameBox(hotbar: Frame, scaled: Style.Scaled): NameBox
	local Dayz = Style.Dayz
	local NAME_H = Theme.Size.NAME_H
	local root = Style.frame(hotbar, 0, NAME_Y, WIDTH, NAME_H, Dayz.Colour.StripBody, 8)
	root.Name = "InHands"
	root.BackgroundTransparency = Dayz.Alpha.StripBody
	root.Visible = false
	local DOT = Theme.Size.DOT
	local dot = Dayz.dot(root, Theme.Size.NAME_PAD, (NAME_H - DOT) / 2, DOT, 2)
	local arrow = Instance.new("Frame")
	arrow.Name = "Trend"
	arrow.BackgroundTransparency = 1
	arrow.Size = UDim2.fromOffset(3, 5)
	arrow.ZIndex = 3
	arrow.Parent = root
	local arrowParts = Dayz.glyph(arrow, 0, 0, Dayz.Art.readingArrow, Dayz.Colour.Text, 1)
	local name, value, target = nameLabel(root, scaled), nameLabel(root, scaled), nameLabel(root, scaled)
	-- The weapon anchor (see `weaponAnchor`).
	local anchor = Instance.new("Frame")
	anchor.Name = "Weapon"
	anchor.BackgroundTransparency = 1
	anchor.BorderSizePixel = 0
	anchor.Size = UDim2.fromScale(1, 1)
	anchor.ZIndex = 4
	anchor.Parent = root
	weaponFrame, weaponScaled = anchor, scaled
	return {
		root = root,
		dot = dot,
		name = name,
		value = value,
		arrow = arrow,
		target = target,
		labels = { name, value, target },
		arrowParts = arrowParts,
	}
end

-- The text's width in the box (Roboto, body size).
local function measure(text: string): number
	return math.ceil(Style.textWidth(text, Style.Dayz.Text.body, Style.Dayz.FONT))
end

local function place(object: GuiObject, x: number, w: number, h: number)
	object.Position = UDim2.fromOffset(x, (Theme.Size.NAME_H - h) / 2)
	object.Size = UDim2.fromOffset(w, h)
end

--[[
	Lays the item box out for `lines` (Theme.handsLines; nil: nothing held) and a Thermometer's
	reading (`reading`: the body temperature and its target, rounded; nil: none).
]]
local function layoutNameBox(box: NameBox, lines: Theme.HandsLines?, reading: { number }?)
	local Size = Theme.Size
	local NAME_H = Size.NAME_H
	local x = Size.NAME_PAD
	local condition = lines and lines.condition
	box.dot.Visible = condition ~= nil
	if condition then
		box.dot.BackgroundColor3 = Style.Dayz.Condition[condition.name]
		x += Size.DOT + Size.NAME_DOT_GAP
	end
	local text = if lines then lines.name else ""
	box.name.Text = text
	local nameW = math.min(measure(text), WIDTH - 2 * Size.NAME_PAD)
	place(box.name, x, nameW + 1, NAME_H)
	x += nameW
	box.value.Visible = reading ~= nil
	box.arrow.Visible = reading ~= nil
	box.target.Visible = reading ~= nil
	if reading then
		local value, target = reading[1], reading[2]
		local valueText = StatusLayout.valueText("temperature", value)
		local targetText = StatusLayout.valueText("temperature", target)
		x += Size.READING_GAP
		local w = measure(valueText)
		box.value.Text = valueText
		box.value.TextColor3 = Style.Dayz.Zone[Temperature.zone(value)]
		place(box.value, x, w + 1, NAME_H)
		x += w + Size.READING_ARROW_GAP
		box.arrow.Position = UDim2.fromOffset(x, (NAME_H - 5) / 2)
		local trend = if target > value then Style.Dayz.Zone[1] elseif target < value then Style.Dayz.Zone[-1] else nil
		Style.Dayz.tint(box.arrow, trend or Style.Dayz.Colour.Text)
		x += 3 + Size.READING_ARROW_GAP
		w = measure(targetText)
		box.target.Text = targetText
		box.target.TextColor3 = Style.Dayz.Zone[Temperature.zone(target)]
		place(box.target, x, w + 1, NAME_H)
		x += w
	end
	local width = math.min(x + Size.NAME_PAD, WIDTH)
	box.root.Size = UDim2.fromOffset(width, NAME_H)
	box.root.Position = UDim2.fromOffset((WIDTH - width) / 2, NAME_Y)
end

-- Fades the item box (alpha 1 shown .. 0 gone).
local function fadeNameBox(box: NameBox, alpha: number)
	local Dayz = Style.Dayz
	local gone = 1 - alpha
	box.root.BackgroundTransparency = 1 - (1 - Dayz.Alpha.StripBody) * alpha
	box.dot.BackgroundTransparency = 1 - (1 - Theme.DOT_T) * alpha
	for _, label in box.labels do
		label.TextTransparency = gone
		label.TextStrokeTransparency = 1 - (1 - Dayz.Alpha.TextStrokeSoft) * alpha
	end
	for _, part in box.arrowParts do
		part.BackgroundTransparency = gone
	end
end

function Hud.start()
	if started then
		return
	end
	started = true
	disableCoreGui()

	local player = Players.LocalPlayer
	-- (From the screen's top, inside the safe area: the canvas sits at its bottom.)
	local gui = UiScale.screenGui("IceVoxelHud", "Hud", { inset = true, kind = "scaled", enabled = hudVisible })
	hudGui = gui

	local canvas = Instance.new("Frame")
	canvas.Name = "Hud"
	canvas.BackgroundTransparency = 1
	canvas.AnchorPoint = Vector2.new(0.5, 1)
	canvas.Position = UDim2.new(0.5, 0, 1, -1)
	canvas.Size = UDim2.fromOffset(WIDTH, HEIGHT)
	canvas.Parent = gui
	Style.Dayz.mark(canvas)
	local scale = Instance.new("UIScale")
	scale.Parent = canvas
	-- (Strokes, text weights and count boxes follow the canvas' scale.)
	local scaled = Style.Dayz.scaled()

	--[[ The quickbar (hidden for spectators, who get the spectator menu in its place) ]]

	local hotbar = Instance.new("Frame")
	hotbar.Name = "Hotbar"
	hotbar.BackgroundTransparency = 1
	hotbar.Size = UDim2.fromScale(1, 1)
	hotbar.Parent = canvas
	local bar = Quickbar.build(hotbar, BAR_Y, scaled)
	quickbar = bar
	table.insert(coverage, bar.bar)
	for i = 1, HOTBAR do
		local hit = HudLayout.quickHit(i, BAR_Y)
		local cell = Instance.new("TextButton")
		cell.Name = `Slot{i}`
		cell.Text = ""
		cell.BackgroundTransparency = 1
		cell.AutoButtonColor = false
		cell.Position = UDim2.fromOffset(hit.x, hit.y)
		cell.Size = UDim2.fromOffset(hit.w, hit.h)
		cell.ZIndex = 4
		cell.Selectable = false
		cell.Parent = hotbar
		cell.Activated:Connect(function()
			if mode == "play" then
				ClientInventory.select(i)
			end
		end)
		cells[i] = cell
	end

	-- The attack indicator's square beside the bar (placed by updateScale), hidden while the
	-- weapon is ready.
	local attack = Style.Dayz.quickCell(hotbar, HudLayout.attackX(false), BAR_Y + 2, 3, scaled)
	attack.base.Name = "AttackIndicator"
	attack.base.Visible = false
	local fill = Style.frame(attack.base, 1, 17, 16, 0, Style.Dayz.Colour.AttackFill, 4)
	fill.BackgroundTransparency = Style.Dayz.Alpha.AttackFill
	attackSlot, attackFill = attack.base, fill

	-- The spectator menu, in the quickbar's place.
	SpectatorGui.build(canvas, 0, BAR_Y, SPECTATOR_LABEL_Y, function(parent: Instance, x: number, y: number)
		return Quickbar.drawBar(parent, x, y, scaled)
	end, function(parent: Instance): Frame
		return Quickbar.drawSelection(parent, scaled)
	end)

	--[[ Touch buttons ]]

	-- The "..." button opens the inventory (for spectators it is the middle click).
	local more, moreButton = touchButton(canvas, "More", WIDTH + 2, BAR_Y, Style.Dayz.Art.more, function()
		if mode == "play" and GameMode.isSpectator(ClientInventory.mode()) then
			-- (Spectators have no inventory: the button is their middle click.)
			SpectatorGui.middleClick()
		elseif inventoryHandler then
			SoundPlayer.click()
			inventoryHandler()
		end
	end)
	HoverTip.attach(moreButton, "hud.inventory")
	-- The gear at the bar's other end opens the Options menu (the space both buttons take is kept
	-- free on touch screens, so the quickbar stays centred).
	local gear, gearButton = touchButton(canvas, "Options", -(TOUCH_BUTTON + 2), BAR_Y, Style.GEAR_ART, function()
		if settingsHandler then
			SoundPlayer.click()
			settingsHandler()
		end
	end)
	HoverTip.attach(gearButton, "hud.options")
	-- The skill tree over the gear (progression on).
	local skills, skillsButton = touchButton(
		canvas,
		"Skills",
		-(TOUCH_BUTTON + 2),
		BAR_Y - 24,
		Style.Dayz.Art.skills,
		function()
			if skillsHandler then
				SoundPlayer.click()
				skillsHandler()
			end
		end
	)
	HoverTip.attach(skillsButton, "hud.skills")
	-- The chat over the "..." button (Ui/Chat).
	local chat, chatButton = touchButton(canvas, "Chat", WIDTH + 2, BAR_Y - 24, Style.Dayz.Art.chat, function()
		if chatHandler then
			SoundPlayer.click()
			chatHandler()
		end
	end)
	HoverTip.attach(chatButton, "hud.chat")

	--[[ The held item's box, the status icons, the frost and heat ]]

	local nameBox = buildNameBox(hotbar, scaled)
	StatusCluster.build(gui)
	SurvivalHud.buildEdges()
	-- (Nothing reaches above the canvas any more.)
	UiScale.setHudRaise(0)

	local function updateScale()
		-- (Ui/UiScale's touch flag: a touch screen played by touch, not with a mouse or a gamepad.)
		local touch = UiScale.touch()
		more.Visible = touch
		gear.Visible = touch
		skills.Visible = touch and ProgressionState.enabled()
		chat.Visible = touch and chatHandler ~= nil
		local width = if touch then HudLayout.CANVAS.touchWidth else WIDTH
		local lift = HudLayout.lift(UiScale.viewport().Y, touch)
		canvas.Position = UDim2.new(0.5, 0, 1, -1 - lift)
		-- (The GUI scale, shrunk to fit this GUI's own area above the lift: the device's safe area.)
		local area = gui.AbsoluteSize
		scale.Scale = UiScale.fit(width, HEIGHT, Vector2.new(area.X, math.max(area.Y - lift, 2)))
		scaled:setScale(scale.Scale)
		attack.base.Position = UDim2.fromOffset(HudLayout.attackX(touch), BAR_Y + 2)
	end
	refreshButtons = updateScale
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateScale)
	UiScale.screenChanged:Connect(updateScale)
	gui.Parent = player:WaitForChild("PlayerGui")
	updateScale()

	--[[ Every frame ]]

	local lastSlot, lastItem = 0, -1
	local nameUntil = 0
	local shownAlpha = -1
	-- The held stack the box was laid out for, and the reading shown (-99: none).
	local boxItem: number? = nil
	local boxCount, boxDamage = -1, -1
	local boxData: Items.Data? = nil
	local boxValue, boxTarget = -99, -99
	local reading = { 0, 0 }
	local lines: Theme.HandsLines? = nil
	local shown = true

	RunService.RenderStepped:Connect(function()
		local now = os.clock()
		local gameMode = ClientInventory.mode()
		local survival = GameMode.isSurvivalLike(gameMode)
		-- (Before the open-screen check: the status icons dock in the open inventory, and the
		-- edges keep up.)
		StatusCluster.render(now, mode)
		local status = if survival then SurvivalState.get() else nil
		SurvivalHud.renderEdges(status)

		local visible = mode ~= "hidden"
		if visible ~= shown then
			shown = visible
			canvas.Visible = visible
		end
		SpectatorGui.render(now, visible and mode == "play" and GameMode.isSpectator(gameMode))
		if not visible then
			return
		end
		local showsHud = GameMode.showsHud(gameMode)
		if hotbar.Visible ~= showsHud then
			hotbar.Visible = showsHud
		end
		local window = previewWindow or ClientInventory.window()
		bar:render(now, mode, window, window.inventory.selected, attackProgress ~= nil)

		-- The held item's box: laid out again when the held stack or the reading changes.
		local held = ClientInventory.selectedStack()
		local item = if held then held.item else nil
		local count = if held then held.count else 0
		local damage = if held then held.damage or 0 else 0
		local data = if held then held.data else nil
		local thermometer = item == THERMOMETER and status ~= nil and status.temperatureOn
		local value, target = -99, -99
		if thermometer and status then
			value = math.round(math.clamp(status.temperature, Temperature.MIN, Temperature.MAX))
			target = math.round(math.clamp(status.target, Temperature.MIN, Temperature.MAX))
		end
		if
			item ~= boxItem
			or count ~= boxCount
			or damage ~= boxDamage
			or data ~= boxData
			or value ~= boxValue
			or target ~= boxTarget
		then
			if item ~= boxItem or count ~= boxCount or damage ~= boxDamage or data ~= boxData then
				lines = Theme.handsLines(held)
			end
			boxItem, boxCount, boxDamage, boxData = item, count, damage, data
			boxValue, boxTarget = value, target
			reading[1], reading[2] = value, target
			layoutNameBox(nameBox, lines, if thermometer then reading else nil)
			shownAlpha = -1
		end
		-- Shown for a while when the selection or the item in it changes; held with a Thermometer,
		-- a firearm or a magazine (Shared/Weapons).
		local slot = ClientInventory.selected()
		local itemKey = item or 0
		if slot ~= lastSlot or itemKey ~= lastItem then
			lastSlot, lastItem = slot, itemKey
			nameUntil = if held then now + Theme.Time.NAME else 0
		end
		local alpha = 0
		if mode == "play" and held then
			local weapon = Weapons.firearm(item) ~= nil or Weapons.magazine(item) ~= nil
			alpha = if thermometer or weapon then 1 else math.clamp((nameUntil - now) / Theme.Time.NAME_FADE, 0, 1)
		end
		if alpha ~= shownAlpha then
			shownAlpha = alpha
			nameBox.root.Visible = alpha > 0
			if alpha > 0 then
				fadeNameBox(nameBox, alpha)
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
			bar:wake(os.clock())
			if spectator then
				SpectatorGui.hotbarKey(slot)
			else
				ClientInventory.select(slot)
			end
		elseif input.KeyCode == Enum.KeyCode.ButtonR1 then
			bar:wake(os.clock())
			if spectator then
				SpectatorGui.step(1)
			else
				step(1)
			end
		elseif input.KeyCode == Enum.KeyCode.ButtonL1 then
			bar:wake(os.clock())
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
		bar:wake(os.clock())
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

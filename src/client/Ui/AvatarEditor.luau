--!strict
--[[
	The title screen's Create New Character page (Terraria's Create Player: look, name,
	difficulty), with an R15 look made from the player's own Roblox avatar (Shared/Characters/
	Appearance), a 320 x 214 block of Ui/MainMenu's scaled canvas. The rules are Ui/CharacterRules;
	the server keeps only its own snapshot of the user's avatar under the edit
	(Appearance.sanitize, Players/CharacterStore), so a client can only switch the user's own
	things on and off.

	  Opening   asks the server for the user's avatar (CharacterAction avatar): the look starts as
	            it (Avatar message), and the server builds the "editor" rig shown on the left
	            (Ui/CharacterPreview; drag to turn it).
	  Skin      a part to paint (All, Head, Torso, the arms and legs), the twelve skin tones,
	            hue and brightness sliders over the part's colour, Randomise (a skin tone for
	            all).
	  Body      a slider a scale (height, width, depth, head, body type, proportion) within
	            Config.Characters.Scales; Reset.
	  Clothing  "Blocky body" (none of the six body parts) and a toggle per thing of the user's
	            own avatar ("Hat 1: ON"), one of each single kind worn.
	  Presets   Classic, Natural, My Avatar.
	  Edits     show at once on the preview's clone (part colours, the R15 scale NumberValues,
	            shirts, pants, T-shirts and accessories hidden when none of their kind is worn),
	            and the server rebuilds the rig with the edit (CharacterAction edit preview, at
	            most every SEND_INTERVAL seconds, only when it changed); the rebuilt rig replaces
	            the clone with the edits put back on it.
	  Bottom    the name (Characters.cleanName: 1..20 characters; the server filters it), the
	            difficulty cycled with its line (Classic, Mediumcore, Hardcore), Create and
	            Cancel. A refused name or the server's answer shows in red on the line.
	  Tooltips  every widget says what it does when hovered, selected or long pressed (Ui/HoverTip,
	            Ui/ButtonHelp's "avatar.*": the difficulty's what each one keeps on death).
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Appearance = require(Shared.Characters.Appearance)
local CharacterSync = require(Shared.Net.CharacterSync)
local Characters = require(Shared.Characters)
local Protocol = require(Shared.Net.Protocol)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local CharacterPreview = require(script.Parent.CharacterPreview)
local CharacterRules = require(script.Parent.CharacterRules)
local FormWidgets = require(script.Parent.FormWidgets)
local HoverTip = require(script.Parent.HoverTip)
local Style = require(script.Parent.Style)

type Appearance = Appearance.Appearance

local WIDTH, HEIGHT = 320, 214
local BUTTON_H = 20
local PANE_X, PANE_Y, PANE_W, PANE_H = 102, 28, 214, 120
local SWATCH_STEP = 17
-- Seconds between edit previews sent to the server.
local SEND_INTERVAL = 0.5
local WHITE = Color3.fromRGB(255, 255, 255)
local GRAY = Color3.fromRGB(160, 160, 160)

-- The R15 scale NumberValues under a Humanoid, by Appearance.SCALES name.
local SCALE_VALUES = table.freeze({
	height = "BodyHeightScale",
	width = "BodyWidthScale",
	depth = "BodyDepthScale",
	head = "HeadScale",
	bodyType = "BodyTypeScale",
	proportion = "BodyProportionScale",
} :: { [string]: string })
-- Classic clothing instances by kind (shirt, pants, T-shirt).
local CLOTHING_CLASSES = table.freeze({ [8] = "Shirt", [9] = "Pants", [10] = "ShirtGraphic" } :: { [number]: string })

export type Editor = {
	frame: Frame,
	-- Starts a new character: the form reset, the user's avatar asked for.
	open: (self: Editor, gamepad: boolean) -> (),
	-- The server's snapshot of the user's avatar (the Avatar message).
	setSnapshot: (self: Editor, look: Appearance) -> (),
	setError: (self: Editor, text: string) -> (),
	setBusy: (self: Editor, busy: boolean) -> (),
	destroy: (self: Editor) -> (),
	onCreate: ((name: string, difficulty: number, look: Appearance) -> ())?,
	onCancel: (() -> ())?,
}

local AvatarEditor = {}

local function toColor3(rgb: number): Color3
	return Color3.fromRGB(bit32.rshift(rgb, 16), bit32.band(bit32.rshift(rgb, 8), 0xFF), bit32.band(rgb, 0xFF))
end

local function place(parent: Instance, x: number, y: number, w: number, h: number, z: number?): Frame
	local frame = Instance.new("Frame")
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Position = UDim2.fromOffset(x, y)
	frame.Size = UDim2.fromOffset(w, h)
	frame.ZIndex = z or 5
	frame.Parent = parent
	return frame
end

-- The editor in `page` (a page of the title screen's canvas), centred.
function AvatarEditor.new(page: Frame): Editor
	local frame = Instance.new("Frame")
	frame.Name = "Editor"
	frame.BackgroundTransparency = 1
	frame.Position = UDim2.new(0.5, -WIDTH / 2, 0.5, -HEIGHT / 2)
	frame.Size = UDim2.fromOffset(WIDTH, HEIGHT)
	frame.ZIndex = 5
	frame.Parent = page
	local self = { frame = frame, onCreate = nil, onCancel = nil }

	local snapshot: Appearance? = nil
	local look: Appearance = Appearance.default()
	local part = 0
	-- The tab shown: "skin", "body", "clothing" or "presets".
	local tab = "skin"
	local difficulty = Characters.DEFAULT_DIFFICULTY
	local busy = false
	local sentKey = ""
	local sendQueued = false
	-- Instances of the clone hidden by the edit, and where they were.
	local hiddenParents: { [Instance]: Instance? } = {}

	local preview = CharacterPreview.new(frame, 4, 4, 94, 144, 5)

	-- Tabs.
	local tabNames: { string } = { "skin", "body", "clothing", "presets" }
	local tabLabels = { "Skin", "Body", "Clothing", "Presets" }
	local tabButtons: { FormWidgets.Button } = {}
	for i, label in tabLabels do
		tabButtons[i] = FormWidgets.button(frame, label, PANE_X + (i - 1) * 54, 4, 52, BUTTON_H)
		HoverTip.attach(tabButtons[i].button, "avatar.tab", tabNames[i])
	end
	local underline = Style.frame(frame, PANE_X, 4 + BUTTON_H + 1, 52, 1, WHITE, 6)
	local panes: { [string]: Frame } = {}
	for _, name in tabNames do
		panes[name] = place(frame, PANE_X, PANE_Y, PANE_W, PANE_H)
	end

	-- Skin.
	local skin = panes.skin
	local partButton = FormWidgets.button(skin, "", 0, 0, PANE_W, BUTTON_H)
	local swatches: { TextButton } = {}
	for i, rgb in Appearance.SKIN_TONES do
		local swatch = Instance.new("TextButton")
		swatch.Text = ""
		swatch.AutoButtonColor = false
		swatch.BorderSizePixel = 0
		swatch.BackgroundColor3 = Style.Colour.Outline
		swatch.Position = UDim2.fromOffset((i - 1) * SWATCH_STEP, 24)
		swatch.Size = UDim2.fromOffset(SWATCH_STEP - 2, 16)
		swatch.ZIndex = 5
		swatch.SelectionImageObject = Style.selectionImage
		swatch.Parent = skin
		HoverTip.attach(swatch, "avatar.swatch")
		Style.frame(swatch, 1, 1, SWATCH_STEP - 4, 14, toColor3(rgb), 6)
		swatches[i] = swatch
	end
	local hueSlider = FormWidgets.slider(skin, 0, 44, PANE_W, BUTTON_H, 0, CharacterRules.HUE_STEPS - 1, function(v)
		return `Hue: {v * 10}`
	end)
	local valueSlider = FormWidgets.slider(skin, 0, 68, PANE_W, BUTTON_H, 0, CharacterRules.VALUE_STEPS, function(v)
		return `Brightness: {v * 5}%`
	end)
	local randomButton = FormWidgets.button(skin, "Randomise", 0, 92, 105, BUTTON_H)
	HoverTip.attach(partButton.button, "avatar.part")
	HoverTip.attach(hueSlider.button.button, "avatar.hue")
	HoverTip.attach(valueSlider.button.button, "avatar.brightness")
	HoverTip.attach(randomButton.button, "avatar.randomise")

	-- Body.
	local body = panes.body
	local scaleSliders: { [string]: FormWidgets.Slider } = {}
	for i, name in Appearance.SCALES do
		local column, row = (i - 1) // 3, (i - 1) % 3
		scaleSliders[name] = FormWidgets.slider(
			body,
			column * 110,
			row * 24,
			104,
			BUTTON_H,
			0,
			CharacterRules.scaleSteps(name),
			function(step)
				return CharacterRules.scaleLabel(name, CharacterRules.scaleAt(name, step))
			end
		)
		HoverTip.attach(scaleSliders[name].button.button, "avatar.scale", name)
	end
	local resetButton = FormWidgets.button(body, "Reset", 0, 76, 104, BUTTON_H)
	HoverTip.attach(resetButton.button, "avatar.resetBody")

	-- Clothing.
	local clothing = Instance.new("ScrollingFrame")
	clothing.BackgroundTransparency = 1
	clothing.BorderSizePixel = 0
	clothing.Size = UDim2.fromScale(1, 1)
	clothing.ScrollBarThickness = 4
	clothing.ScrollingDirection = Enum.ScrollingDirection.Y
	clothing.ZIndex = 5
	clothing.Parent = panes.clothing
	local clothingButtons: { FormWidgets.Button } = {}

	-- Presets.
	local presetButtons: { FormWidgets.Button } = {}
	for i, name in CharacterRules.PRESETS do
		presetButtons[i] = FormWidgets.button(panes.presets, name, 0, (i - 1) * 24, PANE_W, BUTTON_H)
		HoverTip.attach(presetButtons[i].button, "avatar.preset", name)
	end
	FormWidgets.label(panes.presets, "Presets set colours and body", 0, 76, PANE_W, GRAY, "centre")

	-- Name, difficulty, Create and Cancel.
	FormWidgets.label(frame, "Name", 4, 157, 34, GRAY)
	local nameBox = FormWidgets.editBox(frame, 41, 153, 158, 16, 5, function(text: string): string
		local length = utf8.len(text)
		if length and length > Characters.MAX_NAME then
			return string.sub(text, 1, (utf8.offset(text, Characters.MAX_NAME + 1) :: number) - 1)
		end
		return text
	end)
	local difficultyButton = FormWidgets.button(frame, "", 206, 151, 110, BUTTON_H)
	local lineHolder = place(frame, 0, 175, WIDTH, 10)
	local lineLabel, lineShadow =
		Style.shadowText(lineHolder, "", 0, 0, WIDTH, 10, GRAY, 5, Enum.TextXAlignment.Center, Style.TEXT_SIZE)
	local createButton = FormWidgets.button(frame, "Create", 5, 190, 150, BUTTON_H)
	local cancelButton = FormWidgets.button(frame, "Cancel", 165, 190, 150, BUTTON_H)
	HoverTip.attach(nameBox.box, "avatar.name")
	HoverTip.attach(difficultyButton.button, "avatar.difficulty")
	HoverTip.attach(createButton.button, "avatar.create")
	HoverTip.attach(cancelButton.button, "avatar.cancel")
	local errorText: string? = nil

	local function setLine(text: string, colour: Color3)
		lineLabel.Text = text
		lineShadow.Text = text
		lineLabel.TextColor3 = colour
		lineShadow.TextColor3 = Style.shadowOf(colour)
	end

	local function refreshLine()
		local problem = errorText
		if problem then
			setLine(problem, Style.Colour.Red)
		else
			setLine(Characters.DIFFICULTY_TEXT[difficulty] or "", GRAY)
		end
	end

	--[[ The preview's clone ]]

	local function hide(instance: Instance, hidden: boolean)
		local parent = hiddenParents[instance]
		if hidden and parent == nil and instance.Parent then
			hiddenParents[instance] = instance.Parent
			instance.Parent = nil
		elseif not hidden and parent then
			instance.Parent = parent
			hiddenParents[instance] = nil
		end
	end

	-- The edit put onto the clone at once (see the header).
	local function applyLocal(model: Model?)
		if model == nil then
			return
		end
		for i, names in CharacterRules.PART_NAMES do
			local color = toColor3(look.colors[i] or 0)
			for _, name in names do
				local bodyPart = model:FindFirstChild(name)
				if bodyPart and bodyPart:IsA("BasePart") then
					bodyPart.Color = color
				end
			end
		end
		local bodyColors = model:FindFirstChildOfClass("BodyColors")
		if bodyColors then
			for i, property in CharacterRules.BODY_COLORS do
				(bodyColors :: any)[property] = toColor3(look.colors[i] or 0)
			end
		end
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			for name, valueName in SCALE_VALUES do
				local value = humanoid:FindFirstChild(valueName)
				if value and value:IsA("NumberValue") then
					value.Value = (look.scales :: any)[name]
				end
			end
		end
		-- Things whose kind has nothing worn are hidden; the rebuild does the rest.
		local wornKinds: { [number]: boolean } = {}
		local kinds: { [number]: boolean } = {}
		for _, asset in look.assets do
			kinds[asset.kind] = true
			if asset.worn then
				wornKinds[asset.kind] = true
			end
		end
		-- (What is hidden is this clone's: a new clone starts with nothing hidden.)
		local candidates: { Instance } = model:GetChildren()
		for instance in hiddenParents do
			table.insert(candidates, instance)
		end
		for _, child in candidates do
			if child:IsA("Accessory") then
				local kind = Appearance.ACCESSORY + child.AccessoryType.Value
				if kinds[kind] then
					hide(child, not wornKinds[kind])
				end
			else
				for kind, class in CLOTHING_CLASSES do
					if child.ClassName == class and kinds[kind] then
						hide(child, not wornKinds[kind])
					end
				end
			end
		end
	end

	preview.cloned = function(model: Model)
		table.clear(hiddenParents)
		applyLocal(model)
	end

	-- Sends the edit for the server's rebuild (at most every SEND_INTERVAL, only when changed).
	local function queueSend()
		if sendQueued then
			return
		end
		sendQueued = true
		task.delay(SEND_INTERVAL, function()
			sendQueued = false
			if snapshot == nil or frame.Parent == nil then
				return
			end
			local key = buffer.tostring(Appearance.encode(look))
			if key == sentKey then
				return
			end
			sentKey = key
			ClientNet.send(
				Protocol.ClientMessage.CharacterAction,
				CharacterSync.encodeAction({ action = CharacterSync.Action.EditPreview, appearance = look })
			)
		end)
	end

	--[[ The form ]]

	local buildClothing: () -> ()

	local function refresh()
		for i, name in tabNames do
			panes[name].Visible = name == tab
			tabButtons[i]:setColour(if name == tab then Style.Colour.Yellow else nil)
			if name == tab then
				underline.Position = UDim2.fromOffset(PANE_X + (i - 1) * 54, 4 + BUTTON_H + 1)
			end
		end
		partButton:setText(`Part: {CharacterRules.PART_LABELS[part + 1]}`)
		local rgb = look.colors[math.max(part, 1)] or 0
		local hue, _, value = CharacterRules.toHsv(rgb)
		hueSlider:setValue(math.round(hue * CharacterRules.HUE_STEPS) % CharacterRules.HUE_STEPS)
		valueSlider:setValue(math.round(value * CharacterRules.VALUE_STEPS))
		for name, slider in scaleSliders do
			slider:setValue(CharacterRules.stepOf(name, (look.scales :: any)[name]))
		end
		difficultyButton:setText(CharacterRules.difficultyLabel(difficulty))
		createButton:setEnabled(snapshot ~= nil and not busy)
		refreshLine()
	end

	-- The look changed by the player: shown at once, sent soon.
	local function edited(newLook: Appearance)
		look = newLook
		errorText = nil
		applyLocal(preview:model())
		refresh()
		queueSend()
	end

	buildClothing = function()
		for _, button in clothingButtons do
			button.button:Destroy()
		end
		table.clear(clothingButtons)
		local blocky = FormWidgets.button(clothing, "", 0, 0, PANE_W - 6, BUTTON_H)
		HoverTip.attach(blocky.button, "avatar.blocky")
		blocky:setText(`Blocky body: {if CharacterRules.isBlocky(look) then "ON" else "OFF"}`)
		blocky.clicked = function()
			SoundPlayer.click()
			edited(CharacterRules.setBlocky(look, not CharacterRules.isBlocky(look)))
			buildClothing()
		end
		table.insert(clothingButtons, blocky)
		local y = 22
		for i, asset in look.assets do
			if asset.kind > #Appearance.PARTS then
				local button = FormWidgets.button(clothing, "", 0, y, PANE_W - 6, BUTTON_H)
				HoverTip.attach(button.button, "avatar.asset")
				button:setText(CharacterRules.assetToggleLabel(look, i))
				button.clicked = function()
					SoundPlayer.click()
					edited(CharacterRules.toggleAsset(look, i))
					buildClothing()
				end
				table.insert(clothingButtons, button)
				y += 22
			end
		end
		clothing.CanvasSize = UDim2.fromOffset(0, y)
	end

	local function click(fn: () -> ()): () -> ()
		return function()
			SoundPlayer.click()
			fn()
		end
	end

	for i, name in tabNames do
		tabButtons[i].clicked = click(function()
			tab = name
			refresh()
		end)
	end
	partButton.clicked = click(function()
		part = (part + 1) % (#Appearance.PARTS + 1)
		refresh()
	end)
	for i, swatch in swatches do
		swatch.Activated:Connect(function()
			SoundPlayer.click()
			edited(CharacterRules.paint(look, part, Appearance.SKIN_TONES[i]))
		end)
	end
	local function recolour()
		local rgb = look.colors[math.max(part, 1)] or 0
		local _, saturation = CharacterRules.toHsv(rgb)
		local colour = CharacterRules.fromHsv(
			hueSlider.value / CharacterRules.HUE_STEPS,
			if saturation > 0 then saturation else 0.5,
			valueSlider.value / CharacterRules.VALUE_STEPS
		)
		edited(CharacterRules.paint(look, part, colour))
	end
	hueSlider.changed = recolour
	valueSlider.changed = recolour
	randomButton.clicked = click(function()
		edited(CharacterRules.randomSkin(look, function(n: number): number
			return math.random(1, n)
		end))
	end)
	for name, slider in scaleSliders do
		slider.changed = function(step: number)
			local scales = table.clone(look.scales) :: any
			scales[name] = CharacterRules.scaleAt(name, step)
			local result = Appearance.copy(look)
			result.scales = Appearance.clampScales(scales)
			edited(result)
		end
	end
	resetButton.clicked = click(function()
		local result = Appearance.copy(look)
		result.scales = if snapshot then table.clone(snapshot.scales) else Appearance.default().scales
		edited(result)
	end)
	for i, name in CharacterRules.PRESETS do
		presetButtons[i].clicked = click(function()
			edited(CharacterRules.preset(look, snapshot or Appearance.default(), name))
			buildClothing()
		end)
	end
	difficultyButton.clicked = click(function()
		difficulty = CharacterRules.nextDifficulty(difficulty)
		refresh()
	end)
	nameBox.changed = function()
		errorText = nil
		refreshLine()
	end
	createButton.clicked = click(function()
		local name = nameBox:text()
		local problem = CharacterRules.nameProblem(name)
		if problem then
			errorText = problem
			refreshLine()
			return
		end
		local create = (self :: any).onCreate
		if create and snapshot then
			create(Characters.cleanName(name) :: string, difficulty, look)
		end
	end)
	cancelButton.clicked = click(function()
		local cancel = (self :: any).onCancel
		if cancel then
			cancel()
		end
	end)

	function self.open(_: Editor, gamepad: boolean)
		snapshot = nil
		look = Appearance.default()
		part = 0
		tab = "skin"
		difficulty = Characters.DEFAULT_DIFFICULTY
		busy = false
		sentKey = ""
		errorText = nil
		nameBox:setText(Characters.cleanName(Players.LocalPlayer.DisplayName) or "")
		buildClothing()
		refresh()
		setLine("Reading your avatar...", GRAY)
		preview:show(nil)
		preview:show("editor")
		ClientNet.send(
			Protocol.ClientMessage.CharacterAction,
			CharacterSync.encodeAction({ action = CharacterSync.Action.Avatar })
		)
		if gamepad then
			GuiService.SelectedObject = tabButtons[1].button
		end
	end

	function self.setSnapshot(_: Editor, own: Appearance)
		snapshot = Appearance.copy(own)
		look = Appearance.copy(own)
		sentKey = buffer.tostring(Appearance.encode(look))
		buildClothing()
		applyLocal(preview:model())
		refresh()
	end

	function self.setError(_: Editor, text: string)
		errorText = if text ~= "" then text else nil
		refreshLine()
	end

	function self.setBusy(_: Editor, isBusy: boolean)
		busy = isBusy
		refresh()
	end

	function self.destroy(_: Editor)
		preview:destroy()
	end

	refresh()
	return (self :: any) :: Editor
end

return AvatarEditor

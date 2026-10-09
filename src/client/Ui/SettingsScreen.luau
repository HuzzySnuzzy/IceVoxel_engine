--!strict
--[[
	The Options menu: Minecraft's Options screen and its sub-screens in this game's UI style, shown
	through Ui/Screens as a panel (the darkened world, the free mouse, the controls off), built with
	Ui/FormWidgets. What it holds and where: Settings/Pages; what the values mean and how they read:
	Shared/PlayerSettings; changing them: the client's Settings controller (which applies them
	live, the costly ones after a slider stops, and saves them on the server).

	  Opening   the Options key binding (P, Config.Settings.Key by default) or GamepadButton (D-pad
	            right) with no screen open, the HUD's touch gear, the inventory's gear (Ui/Screens.
	            onSettings). The key closes it again. The title screen (Ui/MainMenu) shows it
	            itself (`showIn`), before Ui/Screens starts: Done takes it back there.
	  Pages     Options (Graphics preset, FOV, the pages, Reset, Defaults), Video Settings,
	            Performance, Music & Sounds, Controls (Mouse Settings, Key Binds), HUD, Chat
	            Settings, Accessibility Settings. Sliders move by dragging, clicking, the D-pad (left /
	            right) or A; buttons cycle their values. "Graphics" cycles the presets and reads
	            "Custom" once a value it sets was changed; Reset puts the current preset's values
	            back, Defaults every setting (the device's default preset; the key bindings too).
	            The status lines say what the terrain is doing ("Updating terrain: 120 queued, 34
	            building"), far meshes' state and notes (Settings.setStatus). Key Binds needs a
	            keyboard and Mouse Settings a mouse (Settings.pageShown).
	  Key Binds Minecraft's KeyBindsScreen: a list scrolled by the wheel (half a row a step) or its
	            bar's thumb (dragged, or the bar clicked), a row per category and per action: the
	            action's name, its key and Reset (back to the default; greyed when it is). Clicking
	            the key (or A) waits for one ("> W <" in yellow): the next key or mouse button
	            pressed (anywhere: a click binds that button, as in Minecraft) becomes the
	            binding; Escape (which also opens Roblox's menu) makes it "Not Bound", as
	            Minecraft's does; a gamepad's B leaves it as it was. Meanwhile nothing else takes
	            the keys or the clicks (a cover over the panel; Screens' `capturing`). A key bound
	            to two actions that can be active together shows red in brackets ("[ Q ]"),
	            Shared/KeyBindings.conflicting: a warning, as only one of them may act on it
	            (Sprint and Sneak take it from the others; see KeyBindings). Reset Keys: every
	            binding back to its default.
	  Closing   Done (on a sub-page: back to the page it came from), E, Escape, gamepad B, P: every
	            waiting change applies at once and the settings are sent to the server
	            (Settings.flush).
	  Gamepad   A, B and the D-pad; Down / Up also step through the widgets in reading order, so
	            every widget is reachable while left / right move the sliders (in the key list the
	            selection scrolls the list).
	  Tooltips  a setting with a PlayerSettings `tooltip` (Caves: what Always Shown costs) shows
	            it in Minecraft's tooltip box while hovered or selected, below the widget or above
	            it (Pages.tooltipAt), wrapped to Pages.TOOLTIP_W pixels (Ui/TextWrap).
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local KeyBindings = require(Shared.KeyBindings)
local PlayerSettings = require(Shared.PlayerSettings)

local Settings = require(script.Parent.Parent.Settings)
local Keybinds = require(script.Parent.Parent.Settings.Keybinds)
local Pages = require(script.Parent.Parent.Settings.Pages)
local ViewSettings = require(script.Parent.Parent.Rendering.ViewSettings)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local FormWidgets = require(script.Parent.FormWidgets)
local Screens = require(script.Parent.Screens)
local Style = require(script.Parent.Style)
local TextWrap = require(script.Parent.TextWrap)
local UiScale = require(script.Parent.UiScale)

-- Minecraft's white title and gray status text, and the Key Binds list's red conflicts and
-- yellow key waiting for a press (ChatFormatting.RED / YELLOW).
local WHITE = Color3.fromRGB(255, 255, 255)
local GRAY = Color3.fromRGB(160, 160, 160)
local RED = Color3.fromRGB(255, 85, 85)
local YELLOW = Color3.fromRGB(255, 255, 85)
-- Seconds between status line updates while the menu is open.
local STATUS_INTERVAL = 0.25
-- After a key is taken, the screen still keeps the keys this long: the same press may reach the
-- screens' handlers, or open Roblox's menu, after the binding took it.
local CAPTURE_GRACE = 0.3
-- The tooltip's border, blended over its background as Minecraft draws it (translucent), like
-- Ui/Screens' item tooltips.
local TOOLTIP_TOP = Color3.fromRGB(36, 0, 90)
local TOOLTIP_BOTTOM = Color3.fromRGB(23, 0, 50)

type Widget = {
	button: FormWidgets.Button,
	slider: FormWidgets.Slider?,
	refresh: () -> (),
}

type PageView = {
	page: Pages.Page,
	frame: Frame,
	widgets: { Widget },
	status: { FormWidgets.Label },
	first: GuiObject?,
}

local SettingsScreen = {}

local started = false
local panel: Screens.Panel? = nil
local views: { [string]: PageView } = {}
local shownPage = "main"
-- Set by start: applies what waits, saves and closes the menu.
local finish: () -> () = function() end
-- The menu's frame (set by start), and what to call when Done closes it while another host than
-- Ui/Screens shows it (`showIn`).
local menuRoot: Frame? = nil
local hostDone: (() -> ())? = nil
-- Shows a page (set by start).
local showPage: (id: string) -> () = function() end

-- The Key Binds screen: the action waiting for a key (nil: none), when the last one was taken,
-- the waiting action taking a key (nil: none, it stays as it was) and the list's scrolling (both
-- set by buildKeyBinds).
local listening: string? = nil
local capturedAt = -math.huge
local takeKey: (code: number?) -> () = function() end
local scrollKeys: (delta: number) -> () = function() end

-- Is a gamepad steering (something selected, or the last input a gamepad's)? Then a page change
-- moves the selection to the new page's first widget: the old one is hidden, and with nothing
-- selected the D-pad reaches nothing (the title screen's menu: no Ui/Screens to select it).
local function gamepadSteering(): boolean
	if GuiService.SelectedObject ~= nil then
		return true
	end
	local last = UserInputService:GetLastInputType()
	return string.sub(last.Name, 1, 7) == "Gamepad"
end

-- Stops waiting for a key, leaving the binding as it was.
local function stopListening()
	takeKey(nil)
end

-- The tooltip (one for the menu) and the widget it is shown for.
local tooltip: Frame? = nil
local tooltipOwner: GuiObject? = nil

function SettingsScreen.isOpen(): boolean
	local p = panel
	return p ~= nil and Screens.panelShown(p)
end

-- Is the Key Binds screen waiting for a key (or just took one)?
function SettingsScreen.capturing(): boolean
	return listening ~= nil or os.clock() - capturedAt < CAPTURE_GRACE
end

-- A setting's value <-> its slider's whole index.
local function sliderRange(key: string): (number, (number) -> number, (number) -> number)
	local entry = PlayerSettings.entry(key)
	local mobile = Settings.isMobile()
	local max = PlayerSettings.maxOf(entry, mobile)
	local steps = math.floor((max - entry.min) / entry.step + 0.5)
	local function valueOf(index: number): number
		return PlayerSettings.clamp(key, entry.min + index * entry.step, mobile)
	end
	local function indexOf(value: number): number
		return math.floor((value - entry.min) / entry.step + 0.5)
	end
	return steps, valueOf, indexOf
end

-- Hides the tooltip (`owner`: only when it is that widget's).
local function hideTooltip(owner: GuiObject?)
	local frame = tooltip
	if frame and (owner == nil or owner == tooltipOwner) then
		frame.Visible = false
		tooltipOwner = nil
	end
end

-- Shows `text` in Minecraft's tooltip box for the widget `owner` at `placed`.
local function showTooltip(owner: GuiObject, placed: Pages.Placed, text: string)
	local frame = tooltip
	if frame == nil then
		return
	end
	frame:ClearAllChildren()
	local rows = TextWrap.wrap(text, Pages.TOOLTIP_W, function(row: string): number
		return Style.textWidth(row)
	end)
	local width = 0
	for _, row in rows do
		width = math.max(width, Style.textWidth(row))
	end
	local pad = Pages.TOOLTIP_PAD
	-- (Rows 10 pixels apart, as Minecraft's tooltip lines.)
	local w, h = width + pad * 2, (#rows - 1) * 10 + Style.TEXT_SIZE + pad * 2
	local back = Style.frame(frame, 0, 0, w, h, Style.Colour.TooltipBack, 1)
	back.BackgroundTransparency = 0.06
	for i, side in Style.border(back, 1, 1, w - 2, h - 2, 1, TOOLTIP_TOP, 2) do
		side.BackgroundColor3 = if i == 2 then TOOLTIP_BOTTOM else TOOLTIP_TOP
		if i >= 3 then
			side.BackgroundColor3 = Color3.new(1, 1, 1)
			local gradient = Instance.new("UIGradient")
			gradient.Rotation = 90
			gradient.Color = ColorSequence.new(TOOLTIP_TOP, TOOLTIP_BOTTOM)
			gradient.Parent = side
		end
	end
	for i, row in rows do
		Style.shadowText(back, row, pad, pad + (i - 1) * 10, width + 2, Style.TEXT_SIZE, Style.Colour.Text, 5)
	end
	local x, y = Pages.tooltipAt(placed, w, h)
	frame.Position = UDim2.fromOffset(x, y)
	frame.Size = UDim2.fromOffset(w, h)
	frame.Visible = true
	tooltipOwner = owner
end

-- The setting's tooltip (if it has one) follows its widget's hover and gamepad selection.
local function addTooltip(widget: Widget, placed: Pages.Placed)
	local text = PlayerSettings.entry(placed.item.id).tooltip
	if text == nil then
		return
	end
	local object = widget.button.button
	local function show()
		showTooltip(object, placed, text)
	end
	local function hide()
		hideTooltip(object)
	end
	object.MouseEnter:Connect(show)
	object.MouseLeave:Connect(hide)
	object.SelectionGained:Connect(show)
	object.SelectionLost:Connect(hide)
end

local function settingWidget(parent: Frame, placed: Pages.Placed): Widget
	local key = placed.item.id
	local entry = PlayerSettings.entry(key)
	if entry.kind == "slider" then
		local steps, valueOf, indexOf = sliderRange(key)
		local slider = FormWidgets.slider(parent, placed.x, placed.y, placed.w, placed.h, 0, steps, function(index)
			return PlayerSettings.text(key, valueOf(index))
		end)
		slider.changed = function(index: number)
			Settings.set(key, valueOf(index))
		end
		return {
			button = slider.button,
			slider = slider,
			refresh = function()
				slider:setValue(indexOf(Settings.get(key)))
			end,
		}
	end
	local button = FormWidgets.button(parent, "", placed.x, placed.y, placed.w, placed.h)
	button.clicked = function()
		SoundPlayer.click()
		Settings.cycle(key)
	end
	local function refresh()
		if key == "preset" then
			button:setText(`{entry.name}: {Settings.presetName()}`)
		elseif key == "fog" and ViewSettings.placeKeepsFog() then
			-- (The place keeps its own lighting and Atmosphere: nothing to switch.)
			button:setText("Fog: Place's Own")
		else
			button:setText(PlayerSettings.text(key, Settings.get(key)))
		end
		if key == "fog" then
			button:setEnabled(not ViewSettings.placeKeepsFog())
		end
	end
	return { button = button, slider = nil, refresh = refresh }
end

-- Gamepad: Down / Up go through the widgets in reading order, then Done (left / right stay free
-- for the sliders).
local function chain(objects: { GuiObject })
	for i, object in objects do
		object.NextSelectionDown = objects[i + 1] or objects[1]
		object.NextSelectionUp = objects[i - 1] or objects[#objects]
	end
end

local function pageFrame(root: Frame, page: Pages.Page): Frame
	local frame = Instance.new("Frame")
	frame.Name = page.id
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromScale(1, 1)
	frame.Visible = false
	frame.Parent = root
	FormWidgets.label(frame, page.title, 0, Pages.TITLE_Y, Pages.WIDTH, WHITE, "centre")
	return frame
end

local function buildPage(root: Frame, page: Pages.Page, show: (id: string) -> (), close: () -> ()): PageView
	local frame = pageFrame(root, page)

	local layout = Pages.layout(page, function(item: Pages.Item): boolean
		if item.kind == "setting" then
			return Settings.shown(item.id)
		elseif item.kind == "page" then
			return Settings.pageShown(item.id)
		end
		return true
	end)
	local widgets: { Widget } = {}
	local order: { GuiObject } = {}
	for _, placed in layout.widgets do
		local item = placed.item
		local widget: Widget
		if item.kind == "setting" then
			widget = settingWidget(frame, placed)
			addTooltip(widget, placed)
		else
			local button = FormWidgets.button(frame, item.text or item.id, placed.x, placed.y, placed.w, placed.h)
			if item.kind == "page" then
				button.clicked = function()
					SoundPlayer.click()
					show(item.id)
				end
			elseif item.id == "reset" then
				button.clicked = function()
					SoundPlayer.click()
					Settings.reset()
				end
			elseif item.id == "defaults" then
				button.clicked = function()
					SoundPlayer.click()
					Settings.restoreDefaults()
				end
			end
			widget = { button = button, slider = nil, refresh = function() end }
		end
		table.insert(widgets, widget)
		table.insert(order, widget.button.button)
	end

	local status: { FormWidgets.Label } = {}
	for i in page.status do
		local y = layout.statusY + (i - 1) * Pages.LINE
		table.insert(status, FormWidgets.label(frame, "", 0, y, Pages.WIDTH, GRAY, "centre"))
	end

	local donePlaced = layout.done
	local done = FormWidgets.button(frame, "Done", donePlaced.x, donePlaced.y, donePlaced.w, donePlaced.h)
	done.clicked = function()
		SoundPlayer.click()
		local back = Pages.back(page.id)
		if back then
			show(back)
		else
			close()
		end
	end
	table.insert(order, done.button)
	chain(order)

	return { page = page, frame = frame, widgets = widgets, status = status, first = order[1] }
end

--[[
	The Key Binds screen (Minecraft's KeyBindsScreen): the scrolling list of Settings/Pages.keyList,
	Reset Keys and Done.
]]
local function buildKeyBinds(root: Frame, page: Pages.Page, show: (id: string) -> ()): PageView
	local frame = pageFrame(root, page)
	local values = Settings.values
	local view = Pages.LIST_HEIGHT
	local rows, height = Pages.keyList(KeyBindings.ordered())
	local contentWidth = Pages.WIDTH - Pages.SCROLL_BAR - 2

	-- The list: a clipping frame (Minecraft's darker list background) and the rows in it,
	-- moved by the scroll.
	local clip = Instance.new("Frame")
	clip.Name = "List"
	clip.BackgroundColor3 = Color3.new(0, 0, 0)
	clip.BackgroundTransparency = 0.6
	clip.BorderSizePixel = 0
	clip.ClipsDescendants = true
	clip.Position = UDim2.fromOffset(0, Pages.TOP)
	clip.Size = UDim2.fromOffset(Pages.WIDTH, view)
	clip.Parent = frame
	local content = Instance.new("Frame")
	content.Name = "Rows"
	content.BackgroundTransparency = 1
	content.Size = UDim2.fromOffset(contentWidth, height)
	content.Parent = clip

	-- The scroll bar: its track at the right and the thumb.
	local track = Style.frame(clip, Pages.WIDTH - Pages.SCROLL_BAR, 0, Pages.SCROLL_BAR, view, Color3.new(0, 0, 0), 6)
	local thumb = Style.frame(track, 0, 0, Pages.SCROLL_BAR, 0, Style.Colour.ButtonDark, 1)
	Style.frame(thumb, 0, 0, Pages.SCROLL_BAR - 1, 1, Style.Colour.ButtonLight, 1)

	local scroll = 0
	local function setScroll(value: number)
		scroll = Pages.clampScroll(value, height, view)
		content.Position = UDim2.fromOffset(0, -scroll)
		local top, size = Pages.thumb(scroll, height, view)
		thumb.Visible = size > 0
		thumb.Position = UDim2.fromOffset(0, top)
		thumb.Size = UDim2.fromOffset(Pages.SCROLL_BAR, size)
	end
	setScroll(0)
	scrollKeys = function(delta: number)
		setScroll(scroll - delta * Pages.WHEEL_STEP)
	end

	-- Dragging the thumb (or clicking the track: the thumb's middle goes there), in GUI pixels
	-- (the panel is scaled: AbsoluteSize / view).
	local dragFrom: number? = nil
	local function trackY(screenY: number): number
		local scale = if track.AbsoluteSize.Y > 0 then track.AbsoluteSize.Y / view else 1
		return (screenY - track.AbsolutePosition.Y) / scale
	end
	track.Active = true
	track.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 or listening then
			return
		end
		local top, size = Pages.thumb(scroll, height, view)
		local y = trackY(input.Position.Y)
		if y < top or y > top + size then
			setScroll(Pages.scrollAtThumb(y - size / 2, height, view))
			top = Pages.thumb(scroll, height, view)
		end
		dragFrom = y - top
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		local from = dragFrom
		if from and input.UserInputType == Enum.UserInputType.MouseMovement then
			setScroll(Pages.scrollAtThumb(trackY(input.Position.Y) - from, height, view))
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragFrom = nil
		end
	end)

	-- While waiting for a key, a cover over the whole panel takes the clicks (the click itself
	-- still reaches the capture as a mouse button).
	local cover = Instance.new("TextButton")
	cover.Name = "Waiting"
	cover.Text = ""
	cover.BackgroundTransparency = 1
	cover.AutoButtonColor = false
	cover.Selectable = false
	cover.Size = UDim2.fromScale(1, 1)
	cover.ZIndex = 20
	cover.Visible = false
	cover.Parent = frame

	-- Reset Keys first among the widgets: its refresh works out the conflicts for the rows after.
	local widgets: { Widget } = {}
	local order: { GuiObject } = {}
	local conflicts: { [string]: boolean } = {}
	local resetPlaced, donePlaced = Pages.keyButtons()
	local resetKeys =
		FormWidgets.button(frame, "Reset Keys", resetPlaced.x, resetPlaced.y, resetPlaced.w, resetPlaced.h)
	resetKeys.clicked = function()
		SoundPlayer.click()
		local all = {}
		for _, action in KeyBindings.ACTIONS do
			table.insert(all, KeyBindings.settingKey(action.id))
		end
		Settings.unset(all)
	end
	table.insert(widgets, {
		button = resetKeys,
		slider = nil,
		refresh = function()
			table.clear(conflicts)
			for id in KeyBindings.conflicting(values) do
				conflicts[id] = true
			end
			local any = false
			for _, action in KeyBindings.ACTIONS do
				if not KeyBindings.isDefault(values, action.id) then
					any = true
					break
				end
			end
			resetKeys:setEnabled(any)
		end,
	})

	for _, row in rows do
		if row.kind == "category" then
			FormWidgets.label(content, row.text, 0, row.y + 8, contentWidth, WHITE, "centre")
			continue
		end
		local action = row.id
		local setting = KeyBindings.settingKey(action)
		FormWidgets.label(content, row.text, 0, row.y + 8, Pages.KEY_NAME_W, WHITE, "right")
		local key = FormWidgets.button(content, "", Pages.KEY_BUTTON_X, row.y + 2, Pages.KEY_BUTTON_W, Pages.BUTTON_H)
		local reset =
			FormWidgets.button(content, "Reset", Pages.KEY_RESET_X, row.y + 2, Pages.KEY_RESET_W, Pages.BUTTON_H)
		key.clicked = function()
			if listening or os.clock() - capturedAt < CAPTURE_GRACE then
				return
			end
			SoundPlayer.click()
			listening = action
			cover.Visible = true
			for _, widget in widgets do
				widget.refresh()
			end
		end
		reset.clicked = function()
			SoundPlayer.click()
			Settings.unset({ setting })
		end
		-- (A gamepad's selection scrolls the list to it.)
		local function showRow()
			setScroll(Pages.scrollToShow(scroll, row.y, Pages.KEY_ROW, height, view))
		end
		key.button.SelectionGained:Connect(showRow)
		reset.button.SelectionGained:Connect(showRow)
		table.insert(widgets, {
			button = key,
			slider = nil,
			refresh = function()
				local name = KeyBindings.text(KeyBindings.codeOf(values, action))
				if listening == action then
					key:setText(`> {name} <`)
					key:setColour(YELLOW)
				elseif conflicts[action] then
					key:setText(`[ {name} ]`)
					key:setColour(RED)
				else
					key:setText(name)
					key:setColour(nil)
				end
				reset:setEnabled(not KeyBindings.isDefault(values, action))
			end,
		})
		table.insert(order, key.button)
		table.insert(order, reset.button)
	end
	local done = FormWidgets.button(frame, "Done", donePlaced.x, donePlaced.y, donePlaced.w, donePlaced.h)
	done.clicked = function()
		SoundPlayer.click()
		show(Pages.back(page.id) or "main")
	end
	table.insert(order, resetKeys.button)
	table.insert(order, done.button)
	chain(order)

	--[[
		The action waiting takes `code` (nil: stays as it was). A default is not a choice: it is
		forgotten rather than saved, as any setting on its default.
	]]
	takeKey = function(code: number?)
		local action = listening
		if action == nil then
			return
		end
		listening = nil
		capturedAt = os.clock()
		cover.Visible = false
		if code then
			local setting = KeyBindings.settingKey(action)
			if code == KeyBindings.defaultCode(action) then
				Settings.unset({ setting })
			else
				Settings.set(setting, code)
			end
		end
		for _, widget in widgets do
			widget.refresh()
		end
	end
	-- The next key or mouse button (Escape: Not Bound; a gamepad's B: unchanged). Escape also
	-- reaches Screens, which hands it over (the panel's `escaped`) while capturing.
	UserInputService.InputBegan:Connect(function(input: InputObject)
		if listening == nil or shownPage ~= page.id then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape then
			takeKey(KeyBindings.NONE)
		elseif input.KeyCode == Enum.KeyCode.ButtonB then
			takeKey(nil)
		else
			local code = Keybinds.codeOf(input)
			if code then
				takeKey(code)
			end
		end
	end)

	return { page = page, frame = frame, widgets = widgets, status = {}, first = order[1] }
end

local function refresh()
	local view = views[shownPage]
	if view == nil then
		return
	end
	for _, widget in view.widgets do
		widget.refresh()
	end
end

local function refreshStatus()
	local view = views[shownPage]
	if view == nil then
		return
	end
	for i, kind in view.page.status do
		view.status[i]:setText(Settings.status(kind) or "", GRAY)
	end
end

-- The GUI Scale button cycles Auto, 1 .. this screen's largest choice (Minecraft's), whatever the
-- window: set when the menu shows and whenever the screen changes.
local function limitScale()
	Settings.setLimit("guiScale", UiScale.maxChoice())
end

-- Builds the menu and registers it with the screens (Ui/Screens.onSettings). Call after Screens.start.
function SettingsScreen.start()
	if started then
		return
	end
	started = true
	UiScale.follow(limitScale)

	local root = Instance.new("Frame")
	root.Name = "Options"
	root.BackgroundTransparency = 1
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromOffset(Pages.WIDTH, Pages.HEIGHT)
	root.Visible = false
	root.ZIndex = 2

	local thePanel: Screens.Panel

	-- (Above every page.)
	local tip = Instance.new("Frame")
	tip.Name = "Tooltip"
	tip.BackgroundTransparency = 1
	tip.Visible = false
	tip.ZIndex = 10
	tip.Parent = root
	tooltip = tip

	local function show(id: string)
		stopListening()
		-- (Before the old page hides: its selected widget goes with it.)
		local steering = gamepadSteering()
		-- (A page change or the menu closing: Done, P, E, Escape all come here.)
		hideTooltip()
		local previous = views[shownPage]
		if previous then
			previous.frame.Visible = false
		end
		shownPage = id
		local view = views[id]
		view.frame.Visible = true
		refresh()
		refreshStatus()
		-- (A gamepad's selection moves to the new page, in Ui/Screens or the title screen.)
		local first = view.first
		if first and steering and (Screens.panelShown(thePanel) or hostDone ~= nil) then
			GuiService.SelectedObject = first
		end
	end

	-- Done on the main page and P: apply what waits, save, close.
	finish = function()
		stopListening()
		Settings.flush()
		local done = hostDone
		if done then
			-- (Shown by the title screen: back to it.)
			hostDone = nil
			root.Visible = false
			root.Parent = nil
			show("main")
			done()
			return
		end
		Screens.closePanel(thePanel)
		show("main")
	end

	for _, page in Pages.list do
		if page.list == "keys" then
			views[page.id] = buildKeyBinds(root, page, show)
		else
			views[page.id] = buildPage(root, page, show, function()
				finish()
			end)
		end
	end

	thePanel = {
		root = root,
		size = function(): Vector2
			return Vector2.new(Pages.WIDTH, Pages.HEIGHT)
		end,
		-- E, Escape, gamepad B, death: Screens closed it.
		closed = function()
			stopListening()
			Settings.flush()
			show("main")
		end,
		firstSelectable = function(): GuiObject?
			local view = views[shownPage]
			return if view then view.first else nil
		end,
		-- The Key Binds screen waiting for a key takes them all; Escape unbinds it.
		capturing = SettingsScreen.capturing,
		escaped = function()
			takeKey(KeyBindings.NONE)
		end,
		wheel = function(delta: number)
			if shownPage == "keybinds" and listening == nil then
				scrollKeys(delta)
			end
		end,
	}
	panel = thePanel
	menuRoot = root
	showPage = show
	show("main")

	-- Shown by the title screen (`showIn`) the wheel comes here, not through Ui/Screens.
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if hostDone and input.UserInputType == Enum.UserInputType.MouseWheel and input.Position.Z ~= 0 then
			local wheel = thePanel.wheel
			if wheel then
				wheel(input.Position.Z)
			end
		end
	end)

	-- (A GUI Scale change rescales the panel by itself: Screens lays panels out every frame.)
	Settings.changed:Connect(function()
		if SettingsScreen.isOpen() or hostDone then
			refresh()
		end
	end)

	local sinceStatus = 0
	RunService.Heartbeat:Connect(function(dt)
		if not SettingsScreen.isOpen() and hostDone == nil then
			return
		end
		sinceStatus += dt
		if sinceStatus >= STATUS_INTERVAL then
			sinceStatus = 0
			refreshStatus()
		end
	end)

	Screens.onSettings(SettingsScreen.toggle)
end

-- Opens the menu (on its main page) when no screen is open, or closes it when it is shown.
function SettingsScreen.toggle()
	local p = panel
	if p == nil then
		return
	end
	if Screens.panelShown(p) then
		finish()
	elseif not Screens.isOpen() then
		limitScale()
		shownPage = "main"
		for id, view in views do
			view.frame.Visible = id == "main"
		end
		refresh()
		refreshStatus()
		Screens.showPanel(p)
	end
end

--[[
	Escape / gamepad B in the menu `showIn` shows (the title screen's): back a page from a sub-page
	(true), false on the main page (the host closes the menu then) or while the Key Binds screen
	waits for a key or just took one (it took that press itself: true). `escaped`: it was Escape
	(perhaps only as Roblox's menu opening, which the Key Binds list's own key listener never
	sees): a key waiting becomes "Not Bound", as Ui/Screens' `escaped` does.
]]
function SettingsScreen.back(escaped: boolean?): boolean
	if escaped and listening ~= nil then
		takeKey(KeyBindings.NONE)
		return true
	end
	if SettingsScreen.capturing() then
		return true
	end
	local parent = Pages.back(shownPage)
	if parent == nil then
		return false
	end
	showPage(parent)
	return true
end

--[[
	Shows the menu on its main page inside `host` instead of through Ui/Screens (the title screen,
	Ui/MainMenu, before the game's screens exist; `host` scales it). Done on the main page applies
	what waits, saves, takes it away and calls `onDone`. Returns a function that closes it the same
	way (the title screen's Escape). A gamepad's selection starts on its first widget (the button
	that opened it is hidden now). Call after start.
]]
function SettingsScreen.showIn(host: GuiObject, onDone: () -> ()): () -> ()
	local root = menuRoot
	assert(root, "SettingsScreen.showIn: call start first")
	limitScale()
	shownPage = "main"
	for id, view in views do
		view.frame.Visible = id == "main"
	end
	refresh()
	refreshStatus()
	hostDone = onDone
	root.Parent = host
	root.Visible = true
	local first = views.main and views.main.first
	if first and gamepadSteering() then
		GuiService.SelectedObject = first
	end
	return function()
		if hostDone == onDone then
			finish()
		end
	end
end

return SettingsScreen

--!strict
--[[
	The Options menu: Minecraft's Options screen and its sub-screens in this game's UI style, shown
	through Ui/Screens as a panel (the darkened world, the free mouse, the controls off), built with
	Ui/FormWidgets. What it holds and where: Settings/Pages; what the values mean and how they read:
	Shared/PlayerSettings; changing them: the client's Settings controller (which applies them
	live, the costly ones after a slider stops, and saves them on the server).

	  Opening   Config.Settings.Key (P) or GamepadButton (D-pad right) with no screen open, the
	            HUD's touch gear, the inventory's gear (Ui/Screens.onSettings). P closes it again.
	            The title screen (Ui/MainMenu) shows it itself (`showIn`), before Ui/Screens
	            starts: Done takes it back there.
	  Pages     Options (Graphics preset, FOV, the pages, Reset, Defaults), Video Settings,
	            Performance, Music & Sounds, Controls, HUD. Sliders move by dragging, clicking,
	            the D-pad (left / right) or A; buttons cycle their values. "Graphics" cycles the
	            presets and reads "Custom" once a value it sets was changed; Reset puts the current
	            preset's values back, Defaults every setting (the device's default preset). The
	            status lines say what the terrain is doing ("Updating terrain: 120 queued, 34 building"),
	            far meshes' state and notes (Settings.setStatus).
	  Closing   Done (on a sub-page: back to Options), E, Escape, gamepad B, P: every waiting
	            change applies at once and the settings are sent to the server (Settings.flush).
	  Gamepad   A, B and the D-pad; Down / Up also step through the widgets in reading order, so
	            every widget is reachable while left / right move the sliders.
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local PlayerSettings = require(Shared.PlayerSettings)

local Settings = require(script.Parent.Parent.Settings)
local Pages = require(script.Parent.Parent.Settings.Pages)
local ViewSettings = require(script.Parent.Parent.Rendering.ViewSettings)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local FormWidgets = require(script.Parent.FormWidgets)
local Screens = require(script.Parent.Screens)

-- Minecraft's white title and gray status text.
local WHITE = Color3.fromRGB(255, 255, 255)
local GRAY = Color3.fromRGB(160, 160, 160)
-- Seconds between status line updates while the menu is open.
local STATUS_INTERVAL = 0.25

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

function SettingsScreen.isOpen(): boolean
	local p = panel
	return p ~= nil and Screens.panelShown(p)
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
		elseif key == "fog" and ViewSettings.hasAtmosphere() then
			-- (An Atmosphere replaces the fog: nothing to switch.)
			button:setText("Fog: Atmosphere")
		else
			button:setText(PlayerSettings.text(key, Settings.get(key)))
		end
		if key == "fog" then
			button:setEnabled(not ViewSettings.hasAtmosphere())
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

local function buildPage(root: Frame, page: Pages.Page, show: (id: string) -> (), close: () -> ()): PageView
	local frame = Instance.new("Frame")
	frame.Name = page.id
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromScale(1, 1)
	frame.Visible = false
	frame.Parent = root
	FormWidgets.label(frame, page.title, 0, Pages.TITLE_Y, Pages.WIDTH, WHITE, "centre")

	local layout = Pages.layout(page, function(item: Pages.Item): boolean
		return item.kind ~= "setting" or Settings.shown(item.id)
	end)
	local widgets: { Widget } = {}
	local order: { GuiObject } = {}
	for _, placed in layout.widgets do
		local item = placed.item
		local widget: Widget
		if item.kind == "setting" then
			widget = settingWidget(frame, placed)
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
		if page.id == "main" then
			close()
		else
			show("main")
		end
	end
	table.insert(order, done.button)
	chain(order)

	return { page = page, frame = frame, widgets = widgets, status = status, first = order[1] }
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

-- Builds the menu and registers it with the screens (Ui/Screens.onSettings). Call after Screens.start.
function SettingsScreen.start()
	if started then
		return
	end
	started = true

	local root = Instance.new("Frame")
	root.Name = "Options"
	root.BackgroundTransparency = 1
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromOffset(Pages.WIDTH, Pages.HEIGHT)
	root.Visible = false
	root.ZIndex = 2

	local thePanel: Screens.Panel

	local function show(id: string)
		local previous = views[shownPage]
		if previous then
			previous.frame.Visible = false
		end
		shownPage = id
		local view = views[id]
		view.frame.Visible = true
		refresh()
		refreshStatus()
		-- (A gamepad's selection moves to the new page.)
		local first = view.first
		if first and Screens.panelShown(thePanel) and GuiService.SelectedObject ~= nil then
			GuiService.SelectedObject = first
		end
	end

	-- Done on the main page and P: apply what waits, save, close.
	finish = function()
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
		views[page.id] = buildPage(root, page, show, function()
			finish()
		end)
	end

	thePanel = {
		root = root,
		size = function(): Vector2
			return Vector2.new(Pages.WIDTH, Pages.HEIGHT)
		end,
		-- E, Escape, gamepad B, death: Screens closed it.
		closed = function()
			Settings.flush()
			show("main")
		end,
		firstSelectable = function(): GuiObject?
			local view = views[shownPage]
			return if view then view.first else nil
		end,
	}
	panel = thePanel
	menuRoot = root
	show("main")

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
	Shows the menu on its main page inside `host` instead of through Ui/Screens (the title screen,
	Ui/MainMenu, before the game's screens exist; `host` scales it). Done on the main page applies
	what waits, saves, takes it away and calls `onDone`. Returns a function that closes it the same
	way (the title screen's Escape). Call after start.
]]
function SettingsScreen.showIn(host: GuiObject, onDone: () -> ()): () -> ()
	local root = menuRoot
	assert(root, "SettingsScreen.showIn: call start first")
	shownPage = "main"
	for id, view in views do
		view.frame.Visible = id == "main"
	end
	refresh()
	refreshStatus()
	hostDone = onDone
	root.Parent = host
	root.Visible = true
	return function()
		if hostDone == onDone then
			finish()
		end
	end
end

return SettingsScreen

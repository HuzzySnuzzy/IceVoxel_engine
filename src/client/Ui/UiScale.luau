--!strict
--[[
	The one place the interface's size comes from: Minecraft's GUI scale (Ui/GuiScale, pure) on
	this screen with the player's GUI Scale setting, every ScreenGui the client creates, and the
	HUD's shared corner (Ui/HudLayout, pure) that the minimap, the toasts, the status effect icons,
	the saving icon and WAILA are placed from.

	  screen     one viewport source, the camera's ViewportSize (hooked again when the camera
	             changes), and one touch flag: UserInputService.PreferredInput is Touch (a phone
	             with a keyboard or a gamepad plays as a desktop; a touch laptop used with its
	             mouse is a desktop), TouchEnabled where PreferredInput does not exist. The safe
	             area's insets and Roblox's top bar are measured with three empty probe ScreenGuis
	             (ScreenInsets None, DeviceSafeInsets, CoreUISafeInsets): their AbsolutePositions
	             differ by exactly the notches and the bar, in the same pixels as everything else.
	  base       GuiScale.base: Auto (0) is the largest scale leaving 320 x 240 GUI pixels, a
	             choice above this screen's largest acts as the largest (Minecraft's rule: the
	             stored choice is kept). `fit(w, h, area?)` shrinks it for content that does not fit
	             (GuiScale.fit), `reference()` is for widgets drawn in fixed pixels at 1080p's Auto
	             (F3, the world map's bar, billboards: base / 4, at least 0.75).
	  changes    `changed` fires when the base changes (the setting or the screen); `follow(fn)`
	             calls fn now and whenever the base or the screen (viewport, insets, touch) changes,
	             once for each. `setSetting` is the GUI Scale setting (the boot script, and the
	             title screen's Options).
	  guis       `screenGui(name, layer, opts)` is the only Instance.new("ScreenGui") in the client
	             (tests/spec/UiScaleUsage): ResetOnSpawn off, Sibling ordering (children always draw
	             over their parents), an explicit IgnoreGuiInset, `full` for the whole screen
	             notches included (ScreenInsets None: offsets are screen pixels, the centre is the
	             camera's), and the DisplayOrder from `Layer`, the one table of what draws over
	             what. Its `kind` says whether it is "scaled" (GUI pixels under a UIScale that
	             follows the base) or "screen" (screen-relative by design: the first-person hand,
	             the fire and frost overlays, the Nuke's flash, the world map's backdrop).
	  corner     what shows in the HUD's corner (`setMinimap`, `setToast`, `setEffects`,
	             `setSaving`, `setDebugRight`) and Roblox's touch buttons (the live JumpButton and
	             ContextActionService buttons, measured again when PlayerGui's children change and
	             every BUTTON_CHECK seconds on touch screens) go into HudLayout.compute; `hud()` is
	             the result (screen pixels) and `hudChanged` fires when anything in it may have
	             moved.

	Ui/Style's guiScale, setScaleOverride and scaleChanged forward here for older callers.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local GuiScale = require(script.Parent.GuiScale)
local HudLayout = require(script.Parent.HudLayout)

local UiScale = {}

-- What draws over what (ScreenGui.DisplayOrder; higher is in front).
UiScale.Layer = table.freeze({
	-- Screen-relative pictures behind the interface: the first-person hand, the fire overlay, the
	-- frost and heat at the edges.
	Hand = -1,
	Fire = -1,
	Frost = -1,
	-- The crosshair and the F3 text.
	Crosshair = 0,
	Debug = 0,
	-- The minimap and the world map.
	Map = 5,
	-- The toasts and the status effect icons (over the maps).
	Toasts = 7,
	Effects = 7,
	-- The saving icon, WAILA, and the chat while a screen's backdrop covers it.
	Saving = 8,
	Waila = 8,
	ChatUnderScreens = 8,
	-- The screens (inventories, menus) and the attack indicator.
	Screens = 9,
	AttackBar = 9,
	-- The HUD (its hotbar is the creative screen's row) and the effect list beside open screens.
	Hud = 10,
	EffectList = 10,
	-- A new Age's banner.
	AgeToast = 11,
	-- The chat.
	Chat = 12,
	-- The game mode switcher (F3 + F4).
	Switcher = 15,
	-- The carried stack and its tooltip, over everything in the world.
	Cursor = 20,
	-- The title screen, and the Nuke's flash.
	Title = 100,
	Flash = 100,
})

export type Kind = "scaled" | "screen"

export type GuiOptions = {
	-- ScreenGui.IgnoreGuiInset: true from the screen's top (under Roblox's top bar), false below it.
	inset: boolean,
	kind: Kind,
	-- The whole screen, notches included (ScreenInsets None).
	full: boolean?,
	-- Enabled at first (default true).
	enabled: boolean?,
}

-- Seconds between measures of Roblox's touch buttons on touch screens.
local BUTTON_CHECK = 1
-- The viewport before the camera reports one.
local FALLBACK = Vector2.new(1280, 720)

local started = false
local cameraConnection: RBXScriptConnection? = nil
local viewport = FALLBACK
local touch = false
local setting = 0
local base = 1
local insets: HudLayout.Insets = { left = 0, top = 0, right = 0, bottom = 0, bar = 0 }
-- The probes (see the header): the whole screen, the device's safe area, the core UI's.
local fullProbe: ScreenGui? = nil
local safeProbe: ScreenGui? = nil
local coreProbe: ScreenGui? = nil
-- Every ScreenGui made here by name (weak: a flash's gui goes away), and its kind.
local guis: { [string]: ScreenGui } = setmetatable({}, { __mode = "v" }) :: any
local kinds: { [string]: Kind } = {}

local changedEvent = Instance.new("BindableEvent")
local screenEvent = Instance.new("BindableEvent")
local hudEvent = Instance.new("BindableEvent")
-- Fires (base) when the GUI scale changes.
UiScale.changed = changedEvent.Event
-- Fires when the base or the screen (viewport, insets, touch) changes (`follow`).
UiScale.screenChanged = screenEvent.Event
-- Fires when the HUD's corner was laid out again (`hud`).
UiScale.hudChanged = hudEvent.Event

-- What shows in the HUD's corner (HudLayout.Input's parts set by the widgets).
local corner = {
	minimap = false,
	coordsWidth = HudLayout.MINIMAP,
	music = false,
	save = nil :: number?,
	saveUnder = false,
	effects = nil :: { w: number, h: number }?,
	saving = false,
	debugRight = nil :: number?,
}
-- Roblox's touch buttons as last measured (nil: none found), and the corner's layout.
local buttons: { HudLayout.Rect }? = nil
local layout: HudLayout.Layout? = nil

--[[ The screen ]]

local function readTouch(): boolean
	local ok, preferred = pcall(function()
		return UserInputService.PreferredInput
	end)
	if ok and preferred ~= nil then
		return preferred == Enum.PreferredInput.Touch
	end
	return UserInputService.TouchEnabled
end

-- The insets from the probes (zeros until they have a size).
local function readInsets(): HudLayout.Insets
	local full, safe, core = fullProbe, safeProbe, coreProbe
	if full == nil or safe == nil or core == nil or full.AbsoluteSize.X <= 0 or safe.AbsoluteSize.X <= 0 then
		return { left = 0, top = 0, right = 0, bottom = 0, bar = 0 }
	end
	local origin, size = full.AbsolutePosition, full.AbsoluteSize
	local safeAt, safeSize = safe.AbsolutePosition, safe.AbsoluteSize
	return {
		left = math.max(safeAt.X - origin.X, 0),
		top = math.max(safeAt.Y - origin.Y, 0),
		right = math.max(origin.X + size.X - safeAt.X - safeSize.X, 0),
		bottom = math.max(origin.Y + size.Y - safeAt.Y - safeSize.Y, 0),
		bar = math.max(core.AbsolutePosition.Y - origin.Y, 0),
	}
end

local function sameInsets(a: HudLayout.Insets, b: HudLayout.Insets): boolean
	return a.left == b.left and a.top == b.top and a.right == b.right and a.bottom == b.bottom and a.bar == b.bar
end

-- Is `object` drawn (it and every ancestor visible, its ScreenGui enabled)?
local function drawn(object: Instance): boolean
	local current: Instance? = object
	while current do
		if current:IsA("GuiObject") then
			if not current.Visible then
				return false
			end
		elseif current:IsA("LayerCollector") then
			return current.Enabled
		end
		current = current.Parent
	end
	return false
end

--[[
	Roblox's touch buttons in screen pixels: TouchGui's JumpButton and the ContextActionService
	buttons (Sprint, Sneak), as drawn now; nil when none is (HudLayout then assumes PlayerModule's
	jump button on a touch screen).
]]
local function readButtons(): { HudLayout.Rect }?
	local full = fullProbe
	if not touch or full == nil then
		return nil
	end
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui == nil then
		return nil
	end
	local origin = full.AbsolutePosition
	local list: { HudLayout.Rect } = {}
	local function add(object: Instance)
		if object:IsA("GuiButton") and object.AbsoluteSize.X > 0 and drawn(object) then
			local at, size = object.AbsolutePosition, object.AbsoluteSize
			table.insert(list, { x = at.X - origin.X, y = at.Y - origin.Y, w = size.X, h = size.Y })
		end
	end
	local touchGui = playerGui:FindFirstChild("TouchGui")
	local jump = touchGui and touchGui:FindFirstChild("JumpButton", true)
	if jump then
		add(jump)
	end
	local actions = playerGui:FindFirstChild("ContextActionGui")
	if actions then
		for _, object in actions:GetDescendants() do
			add(object)
		end
	end
	return if #list > 0 then list else nil
end

local function sameButtons(a: { HudLayout.Rect }?, b: { HudLayout.Rect }?): boolean
	if a == nil or b == nil then
		return a == b
	end
	if #a ~= #b then
		return false
	end
	for i, r in a do
		local q = b[i]
		if r.x ~= q.x or r.y ~= q.y or r.w ~= q.w or r.h ~= q.h then
			return false
		end
	end
	return true
end

-- Lays the HUD's corner out again from the screen, the base and what shows.
local function layoutCorner()
	layout = HudLayout.compute({
		width = viewport.X,
		height = viewport.Y,
		insets = insets,
		scale = base,
		touch = touch,
		minimap = corner.minimap,
		coordsWidth = corner.coordsWidth,
		music = corner.music,
		save = corner.save,
		saveUnder = corner.saveUnder,
		effects = corner.effects,
		saving = corner.saving,
		debugRight = corner.debugRight,
		buttons = buttons,
	})
end

-- Reads the screen again; tells everyone what changed.
local function refresh()
	local camera = workspace.CurrentCamera
	local size = if camera then camera.ViewportSize else viewport
	if size.X < 2 or size.Y < 2 then
		size = viewport
	end
	local nowTouch = readTouch()
	local nowInsets = readInsets()
	local nowBase = GuiScale.base(size.X, size.Y, nowTouch, setting)
	local screenMoved = size ~= viewport or nowTouch ~= touch or not sameInsets(nowInsets, insets)
	local baseMoved = nowBase ~= base
	viewport, touch, insets, base = size, nowTouch, nowInsets, nowBase
	if screenMoved then
		buttons = readButtons()
	end
	if not (screenMoved or baseMoved) and layout ~= nil then
		return
	end
	layoutCorner()
	if baseMoved then
		changedEvent:Fire(base)
	end
	screenEvent:Fire()
	hudEvent:Fire()
end

-- Measures the touch buttons again; lays the corner out again if they moved.
local function checkButtons()
	local now = readButtons()
	if not sameButtons(now, buttons) then
		buttons = now
		layoutCorner()
		hudEvent:Fire()
	end
end

local function hookCamera()
	if cameraConnection then
		cameraConnection:Disconnect()
		cameraConnection = nil
	end
	local camera = workspace.CurrentCamera
	if camera then
		cameraConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(refresh)
	end
end

local function probe(playerGui: Instance, name: string, insetsKind: Enum.ScreenInsets): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = insetsKind ~= Enum.ScreenInsets.CoreUISafeInsets
	gui.ScreenInsets = insetsKind
	gui.DisplayOrder = -100
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(refresh)
	gui:GetPropertyChangedSignal("AbsolutePosition"):Connect(refresh)
	gui.Parent = playerGui
	return gui
end

-- Starts following the screen (the boot script, first thing; anything asking starts it too).
function UiScale.start()
	if started then
		return
	end
	started = true
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	fullProbe = probe(playerGui, "IceVoxelScreenProbe", Enum.ScreenInsets.None)
	safeProbe = probe(playerGui, "IceVoxelSafeAreaProbe", Enum.ScreenInsets.DeviceSafeInsets)
	coreProbe = probe(playerGui, "IceVoxelTopBarProbe", Enum.ScreenInsets.CoreUISafeInsets)
	hookCamera()
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		hookCamera()
		refresh()
	end)
	pcall(function()
		UserInputService:GetPropertyChangedSignal("PreferredInput"):Connect(refresh)
	end)
	UserInputService:GetPropertyChangedSignal("TouchEnabled"):Connect(refresh)
	playerGui.ChildAdded:Connect(checkButtons)
	playerGui.ChildRemoved:Connect(checkButtons)
	local since = 0
	RunService.Heartbeat:Connect(function(dt: number)
		since += dt
		if touch and since >= BUTTON_CHECK then
			since = 0
			checkButtons()
		end
	end)
	refresh()
end

--[[ Reading the scale ]]

-- The camera's viewport (screen pixels).
function UiScale.viewport(): Vector2
	UiScale.start()
	return viewport
end

-- Whether this plays as a touch screen (fractional scales, touch buttons).
function UiScale.touch(): boolean
	UiScale.start()
	return touch
end

-- The safe area's insets and the top bar's bottom (screen pixels; do not change the table).
function UiScale.insets(): HudLayout.Insets
	UiScale.start()
	return insets
end

-- The GUI scale for this screen and setting.
function UiScale.base(): number
	UiScale.start()
	return base
end

-- The base shrunk so `width` x `height` GUI pixels fit `area` (screen pixels; the viewport).
function UiScale.fit(width: number, height: number, area: Vector2?): number
	UiScale.start()
	local space = area or viewport
	if space.X < 2 or space.Y < 2 then
		space = viewport
	end
	return GuiScale.fit(base, width, height, space.X, space.Y, touch)
end

-- The scale of widgets drawn in fixed pixels at 1080p's Auto (GuiScale.reference).
function UiScale.reference(): number
	UiScale.start()
	return GuiScale.reference(base)
end

-- The largest GUI Scale choice on this screen (the setting's button cycles Auto, 1 .. this).
function UiScale.maxChoice(): number
	UiScale.start()
	return GuiScale.maxChoice(viewport.X, viewport.Y, touch)
end

-- The GUI Scale setting (0 Auto, else the choice).
function UiScale.setting(): number
	return setting
end

-- Sets the GUI Scale setting (0 or nil: Auto).
function UiScale.setSetting(value: number?)
	local now = if value and value == value and value >= 1 then math.floor(value) else 0
	if now ~= setting then
		setting = now
		if started then
			refresh()
		end
	end
end

-- Calls `fn` now and whenever the base or the screen changes (see the header).
function UiScale.follow(fn: () -> ()): RBXScriptConnection
	UiScale.start()
	local connection = screenEvent.Event:Connect(fn)
	fn()
	return connection
end

-- `gui`'s top left in screen pixels (where its offsets start).
function UiScale.origin(gui: GuiBase2d): Vector2
	UiScale.start()
	local full = fullProbe
	return if full then gui.AbsolutePosition - full.AbsolutePosition else gui.AbsolutePosition
end

--[[ ScreenGuis ]]

-- A new ScreenGui (see the header); not parented.
function UiScale.screenGui(name: string, layer: string, opts: GuiOptions): ScreenGui
	local order = UiScale.Layer[layer]
	assert(order ~= nil, `UiScale.screenGui: no layer "{layer}"`)
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset = opts.inset
	if opts.full then
		gui.ScreenInsets = Enum.ScreenInsets.None
	end
	gui.DisplayOrder = order
	if opts.enabled ~= nil then
		gui.Enabled = opts.enabled
	end
	guis[name] = gui
	kinds[name] = opts.kind
	return gui
end

-- A ScreenGui made here by name (the latest of that name), and its kind.
function UiScale.find(name: string): (ScreenGui?, Kind?)
	return guis[name], kinds[name]
end

-- Is the HUD shown (the world map hides it, and the toasts, effect icons and WAILA with it)?
function UiScale.hudShown(): boolean
	local hud: ScreenGui? = guis.IceVoxelHud
	return hud == nil or hud.Parent == nil or hud.Enabled
end

--[[ The HUD's corner ]]

-- The corner's layout (HudLayout.Layout, screen pixels; do not change it).
function UiScale.hud(): HudLayout.Layout
	UiScale.start()
	if layout == nil then
		layoutCorner()
	end
	return layout :: HudLayout.Layout
end

local function cornerChanged()
	if started then
		layoutCorner()
		hudEvent:Fire()
	end
end

-- The minimap shows (Map/Minimap) and its coordinates line's text width (GUI pixels).
function UiScale.setMinimap(shown: boolean, coordsWidth: number?)
	local width = coordsWidth or corner.coordsWidth
	if shown ~= corner.minimap or width ~= corner.coordsWidth then
		corner.minimap, corner.coordsWidth = shown, width
		cornerChanged()
	end
end

--[[
	A toast shows (`width` GUI pixels) or went (nil): "music" Now Playing (Ui/MusicToast), "save"
	World saved (Ui/SaveIndicator; `under`: it sits under Now Playing).
]]
function UiScale.setToast(kind: "music" | "save", width: number?, under: boolean?)
	if kind == "music" then
		local showing = width ~= nil
		if showing ~= corner.music then
			corner.music = showing
			cornerChanged()
		end
	else
		local below = under == true
		if width ~= corner.save or below ~= corner.saveUnder then
			corner.save, corner.saveUnder = width, below
			cornerChanged()
		end
	end
end

-- The status effect icons: `columns` in the longest row, `rows` rows (0: none; Ui/EffectHud).
function UiScale.setEffects(columns: number, rows: number)
	local size = HudLayout.effectsSize(columns, rows)
	local old = corner.effects
	if (size == nil) ~= (old == nil) or (size and old and (size.w ~= old.w or size.h ~= old.h)) then
		corner.effects = size
		cornerChanged()
	end
end

-- The saving icon shows (Ui/SaveIndicator).
function UiScale.setSaving(shown: boolean)
	if shown ~= corner.saving then
		corner.saving = shown
		cornerChanged()
	end
end

-- The F3 text's right edge (screen pixels) while it is open, nil when closed (Debug/DebugOverlay).
function UiScale.setDebugRight(x: number?)
	if x ~= corner.debugRight then
		corner.debugRight = x
		cornerChanged()
	end
end

return UiScale

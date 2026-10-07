--!strict
--[[
	Status effects on the HUD (Minecraft 1.20.1's Gui.renderEffects and
	EffectRenderingInventoryScreen), from Player/EffectState: every running effect, Minecraft's and
	this game's, and Tough As Nails' (Thirst, Internal Warmth, Internal Chill, Climate Clemency,
	which the server lists with them).

	  Icons    in the top right corner, under the minimap and the music toast's place
	           (MusicToast.bottom: they never cover the toast), Minecraft's 24 x 24 GUI pixel
	           squares: the effect's glyph (Ui/EffectIcons) in its colour on the light grey effect
	           background (an ambient effect's has a pale blue rim). Beneficial effects in the top
	           row, the rest (harmful, neutral) in the row below, each row from the right, longest
	           first (Effects.hudOrder). In its last 10 s an icon fades and blinks out, faster at the
	           end (Effects.iconAlpha). Hovering one with the mouse, or tapping it on a touch screen
	           (tap again to hide), writes its name, level and time under the rows ("Speed II
	           1:23", "**:**" for one that never ends).
	  List     while an inventory screen is open (the inventory, a chest, the creative picker:
	           Ui/Screens) the icons give way to Minecraft's inventory list, on the left of the
	           screen (where JEI moves it, its item list taking the right): a 120 x 32 panel per
	           effect with the glyph, the name and level in white and the time in grey, 33 apart
	           (closer when more than five need the room, as Minecraft squeezes them). It draws
	           over the screens' darkened backdrop (DisplayOrder 10 while shown, above Screens' 9,
	           under the cursor's 20), as Minecraft draws it over renderBackground, and never takes
	           clicks. When it would reach the screen's panels (Screens.screenLeft) it shrinks to
	           Minecraft's compact list, the glyphs alone in 32 wide panels, and hides when even
	           that doesn't fit. A panel screen (the Options menu, the skill tree, a structure
	           form: Screens.panelOpen) hides both, as Minecraft's menus show no effects.
	Scaled like the toasts (Style.guiScale: the GUI Scale setting, touch screens), hidden with the
	HUD (the world map hides it) and with Config.Effects.Hud off. Built again only when the server's
	effects come in another set or order (a refresh only takes the new times); a frame only fades
	the icons in their last 10 s and rewrites times that changed.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Effects = require(Shared.Effects)

local EffectState = require(script.Parent.Parent.Player.EffectState)
local EffectIcons = require(script.Parent.EffectIcons)
local MusicToast = require(script.Parent.MusicToast)
local Screens = require(script.Parent.Screens)
local Style = require(script.Parent.Style)

local EffectHud = {}

-- Minecraft's icon square, the step between icons and between the rows (GUI pixels).
local ICON = 24
local STEP = 25
local ROW = 26
-- The holder's width (room for a row of 12 icons) and height (two rows and the tooltip line).
local WIDTH = STEP * 12
local HEIGHT = ROW * 2 + 12
-- The inventory list's panels and their spacing (Minecraft: 120 x 32, 33 apart; with more than
-- five, 132 / (count - 1)).
local LIST_WIDTH, LIST_HEIGHT = 120, 32
-- Minecraft's compact list (no room for the names): the glyph alone.
local COMPACT_WIDTH = 32
-- DisplayOrder of the icons (with the toasts) and of the list (over Screens' backdrop at 9,
-- under the cursor and tooltip at 20).
local ICONS_ORDER, LIST_ORDER = 7, 10
local LIST_STEP = 33
local LIST_ROOM = 132
-- Screen pixels from the left edge and the top for the list.
local LIST_MARGIN = 8
local LIST_TOP = 40
-- The scale's basis (the toasts', so both grow alike).
local BASE_WIDTH, BASE_HEIGHT = 160, 32

local OUTLINE = Color3.fromRGB(16, 16, 16)
local BACKGROUND = Color3.fromRGB(198, 198, 198)
local LIGHT = Color3.fromRGB(255, 255, 255)
local SHADE = Color3.fromRGB(110, 110, 110)
local AMBIENT_RIM = Color3.fromRGB(150, 200, 230)
local TIME = Color3.fromRGB(127, 127, 127)

-- One drawn effect: its entry as of `builtAt`, its icon (a CanvasGroup, for fading it whole) and
-- the time label in the list (nil on the icons).
type Shown = {
	entry: Effects.Entry,
	group: CanvasGroup?,
	time: TextLabel?,
	timeShadow: TextLabel?,
	seconds: number,
	alpha: number,
}

local started = false
local icons: { Shown } = {}
local rows: { Shown } = {}
local builtAt = 0
local hovered: number? = nil
local pinned: number? = nil

-- Ticks left of `entry` now (counted down since the effects were drawn).
local function ticksLeft(entry: Effects.Entry, now: number): number
	return Effects.remaining(entry.ticks, math.floor((now - builtAt) * Effects.TICKS_PER_SECOND), entry.paused)
end

-- The background square and the glyph of `entry` at (x, y) of `parent`.
local function drawIcon(parent: Instance, x: number, y: number, entry: Effects.Entry, z: number)
	local effect = Effects.get(entry.effect)
	if effect == nil then
		return
	end
	Style.frame(parent, x, y, ICON, ICON, OUTLINE, z)
	Style.frame(parent, x + 1, y + 1, ICON - 2, ICON - 2, if entry.ambient then AMBIENT_RIM else LIGHT, z)
	Style.frame(parent, x + 2, y + 2, ICON - 3, ICON - 3, SHADE, z)
	Style.frame(parent, x + 2, y + 2, ICON - 4, ICON - 4, BACKGROUND, z)
	Style.pixelArt(parent, x + 3, y + 3, EffectIcons.glyph(effect.icon), EffectIcons.palette(effect.color), z + 1, 2)
end

function EffectHud.start()
	if started then
		return
	end
	started = true
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "IceVoxelEffects"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	-- (With the toasts: over the minimap, under WAILA, the HUD and the screens' tooltips.)
	gui.DisplayOrder = ICONS_ORDER
	-- Children draw over their parents whatever their ZIndex (Style's rule: a list panel's face,
	-- glyph and text sit inside its outline frame; with Global ordering the outline, at a higher
	-- ZIndex, covered them all: an empty black box).
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local holder = Instance.new("Frame")
	holder.Name = "Icons"
	holder.AnchorPoint = Vector2.new(1, 0)
	holder.Size = UDim2.fromOffset(WIDTH, HEIGHT)
	holder.BackgroundTransparency = 1
	holder.Parent = gui
	local scale = Instance.new("UIScale")
	scale.Parent = holder
	local tip, tipShadow =
		Style.shadowText(holder, "", 0, ROW * 2 + 2, WIDTH, 8, Style.Colour.Text, 8, Enum.TextXAlignment.Right)

	local list = Instance.new("Frame")
	list.Name = "List"
	list.Position = UDim2.fromOffset(LIST_MARGIN, LIST_TOP)
	list.Size = UDim2.fromOffset(LIST_WIDTH, LIST_HEIGHT)
	list.BackgroundTransparency = 1
	list.Visible = false
	list.Parent = gui
	local listScale = Instance.new("UIScale")
	listScale.Parent = list

	local lastTop, lastMargin = -1, -1
	local function layout()
		local camera = workspace.CurrentCamera
		local viewport = if camera then camera.ViewportSize else Vector2.new(1280, 720)
		local factor = Style.guiScale(viewport, BASE_WIDTH, BASE_HEIGHT, UserInputService.TouchEnabled)
		if scale.Scale ~= factor then
			scale.Scale = factor
			listScale.Scale = factor
		end
		local top, margin = MusicToast.bottom()
		if top ~= lastTop or margin ~= lastMargin then
			lastTop, lastMargin = top, margin
			holder.Position = UDim2.new(1, -margin, 0, top + 2)
		end
	end

	-- Draws the icons and the list again from the effects the server sent (`compact`: the list
	-- with the glyphs alone).
	local lastLayout = ""
	local compact = false
	local function build()
		local now = os.clock()
		local entries = EffectState.list(now)
		local good, rest = Effects.hudOrder(entries)
		-- (The same effects in the same places, only their times refreshed (a fluid's effects,
		-- once a second): keep the icons, take the new times.)
		local parts = table.create(#good + #rest + 1)
		for _, entry in good do
			table.insert(parts, `{entry.effect}:{entry.amplifier}:{entry.ambient}`)
		end
		table.insert(parts, "|")
		for _, entry in rest do
			table.insert(parts, `{entry.effect}:{entry.amplifier}:{entry.ambient}`)
		end
		table.insert(parts, if compact then "c" else "f")
		local key = table.concat(parts, " ")
		if key == lastLayout then
			local byEffect: { [number]: Effects.Entry } = {}
			for _, entry in entries do
				byEffect[entry.effect] = entry
			end
			for _, shown in icons do
				shown.entry = byEffect[shown.entry.effect] or shown.entry
			end
			for _, shown in rows do
				shown.entry = byEffect[shown.entry.effect] or shown.entry
				shown.seconds = -1
			end
			builtAt = now
			return
		end
		lastLayout = key
		for _, child in holder:GetChildren() do
			if child:IsA("CanvasGroup") then
				child:Destroy()
			end
		end
		for _, child in list:GetChildren() do
			if not child:IsA("UIScale") then
				child:Destroy()
			end
		end
		table.clear(icons)
		table.clear(rows)
		builtAt = now
		hovered, pinned = nil, nil
		for row, group in { good, rest } do
			for i, entry in group do
				local canvas = Instance.new("CanvasGroup")
				canvas.Name = Effects.levelName(entry.effect, entry.amplifier)
				canvas.BackgroundTransparency = 1
				canvas.Position = UDim2.fromOffset(WIDTH - STEP * i, (row - 1) * ROW)
				canvas.Size = UDim2.fromOffset(ICON, ICON)
				canvas.Parent = holder
				drawIcon(canvas, 0, 0, entry, 1)
				local button = Instance.new("TextButton")
				button.Text = ""
				button.BackgroundTransparency = 1
				button.Size = UDim2.fromScale(1, 1)
				button.ZIndex = 5
				button.Parent = canvas
				local effect = entry.effect
				button.MouseEnter:Connect(function()
					hovered = effect
				end)
				button.MouseLeave:Connect(function()
					if hovered == effect then
						hovered = nil
					end
				end)
				button.Activated:Connect(function()
					if UserInputService.TouchEnabled then
						pinned = if pinned == effect then nil else effect
					end
				end)
				table.insert(icons, { entry = entry, group = canvas, seconds = -1, alpha = 1 })
			end
		end
		-- The inventory list: every effect, beneficial first, as the icons.
		local all = table.clone(good)
		table.move(rest, 1, #rest, #all + 1, all)
		local step = if #all > 5 then math.min(LIST_STEP, LIST_ROOM // (#all - 1)) else LIST_STEP
		local width = if compact then COMPACT_WIDTH else LIST_WIDTH
		list.Size = UDim2.fromOffset(width, step * math.max(#all - 1, 0) + LIST_HEIGHT)
		for i, entry in all do
			local y = (i - 1) * step
			local panel = Style.panel(list, 0, y, width, LIST_HEIGHT)
			panel.ZIndex = i * 10
			-- (The list never takes the screen's clicks.)
			panel.Active = false
			drawIcon(panel, 4, 4, entry, 4)
			if compact then
				table.insert(rows, { entry = entry, seconds = -1, alpha = 1 })
				continue
			end
			Style.shadowText(
				panel,
				Effects.levelName(entry.effect, entry.amplifier),
				32,
				7,
				LIST_WIDTH - 36,
				8,
				Style.Colour.Text,
				6
			)
			local time, timeShadow = Style.shadowText(panel, "", 32, 18, LIST_WIDTH - 36, 8, TIME, 6)
			table.insert(rows, { entry = entry, time = time, timeShadow = timeShadow, seconds = -1, alpha = 1 })
		end
	end

	layout()
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(layout)
	end
	Style.scaleChanged:Connect(layout)
	EffectState.changed:Connect(build)
	gui.Parent = playerGui

	local lastTipEffect, lastTipSeconds = 0, -1
	RunService.RenderStepped:Connect(function()
		local hud = playerGui:FindFirstChild("IceVoxelHud")
		local hudShown = hud == nil or not hud:IsA("ScreenGui") or hud.Enabled
		local on = Config.Effects.Hud == true and hudShown and #icons + #rows > 0 and not Screens.panelOpen()
		local screen = Screens.isOpen()
		if gui.Enabled ~= on then
			gui.Enabled = on
		end
		if not on then
			return
		end
		local order = if screen then LIST_ORDER else ICONS_ORDER
		if gui.DisplayOrder ~= order then
			gui.DisplayOrder = order
		end
		-- The list beside the screen's panels: full, compact, or none when even that would reach them.
		local listShown = screen
		if screen then
			local left = Screens.screenLeft()
			local room = if left then left - LIST_MARGIN * 2 else math.huge
			local wantCompact = LIST_WIDTH * listScale.Scale > room
			listShown = COMPACT_WIDTH * listScale.Scale <= room
			if wantCompact ~= compact then
				compact = wantCompact
				build()
			end
		end
		if holder.Visible == screen or list.Visible ~= listShown then
			holder.Visible = not screen
			list.Visible = listShown
		end
		-- (The minimap setting moves the toast's place: follow it.)
		layout()
		local now = os.clock()
		if screen then
			for _, shown in rows do
				local seconds = ticksLeft(shown.entry, now) // Effects.TICKS_PER_SECOND
				if seconds ~= shown.seconds and shown.time and shown.timeShadow then
					shown.seconds = seconds
					local text = Effects.formatTicks(ticksLeft(shown.entry, now))
					shown.time.Text, shown.timeShadow.Text = text, text
				end
			end
			return
		end
		for _, shown in icons do
			local alpha = Effects.iconAlpha(ticksLeft(shown.entry, now), shown.entry.ambient)
			if math.abs(alpha - shown.alpha) > 0.02 and shown.group then
				shown.alpha = alpha
				shown.group.GroupTransparency = 1 - alpha
			end
		end
		-- The hovered (or tapped) icon's name and time, rewritten when its seconds change.
		local showing = pinned or hovered
		local tipEffect, tipSeconds = 0, -1
		local entry: Effects.Entry? = nil
		if showing then
			for _, shown in icons do
				if shown.entry.effect == showing then
					entry = shown.entry
					tipEffect = showing
					tipSeconds = ticksLeft(shown.entry, now) // Effects.TICKS_PER_SECOND
				end
			end
		end
		if tipEffect ~= lastTipEffect or tipSeconds ~= lastTipSeconds then
			lastTipEffect, lastTipSeconds = tipEffect, tipSeconds
			local text = ""
			if entry then
				local name = Effects.levelName(entry.effect, entry.amplifier)
				text = `{name} {Effects.formatTicks(ticksLeft(entry, now))}`
			end
			tip.Text, tipShadow.Text = text, text
		end
	end)
end

return EffectHud

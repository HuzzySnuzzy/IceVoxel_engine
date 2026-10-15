--!strict
--[[
	Status effects on the HUD (Minecraft 1.20.1's Gui.renderEffects and
	EffectRenderingInventoryScreen), from Player/EffectState: every running effect, Minecraft's and
	this game's, and Tough As Nails' (Thirst, Internal Warmth, Internal Chill, Climate Clemency,
	which the server lists with them).

	  Icons    in the top right corner where Ui/HudLayout puts them (UiScale.hud().effects: in the
	           toast slot under the minimap while no toast shows, under the toasts while they do,
	           beside the minimap column when that would reach the bottom of the screen or Roblox's
	           jump button, drawn smaller as a last resort), Minecraft's 24 x 24 GUI pixel squares:
	           the effect's glyph (Ui/EffectIcons) in its colours on a dark square (see Look; an
	           ambient effect's outline is pale blue). Beneficial effects in the top
	           row, the rest (harmful, neutral) in the row below, each row from the right, longest
	           first (Effects.hudOrder); the block's size goes to Ui/UiScale (`setEffects`). In its
	           last 10 s an icon fades and blinks out, faster at the end (Effects.iconAlpha).
	           Hovering one with the mouse, or tapping it on a touch screen (tap again to hide),
	           writes its name, level and time under the rows ("Speed II 1:23", "**:**" for one
	           that never ends).
	  Band     while the survival inventory is open (window 0, a chest, a block: Ui/Screens.
	           effectsDock, the free stretch of its quickbar band beside the bar, or while the
	           recipe view hides the bar the band's row under the VICINITY column, left of the
	           view) the icons give way to a row of every running effect there, at the bar's
	           height: harmful and neutral ones first from the right end, then the beneficial
	           ones, 25 apart and closer when they need the room (HudLayout.effectRow), the glyphs
	           alone. That inventory is as wide as the screen, so nothing would fit beside it; the
	           status icons beside the row show no badges.
	  List     while another inventory screen is open (the creative picker, or the inventory when
	           its band has no room: Ui/Screens) the icons give way to Minecraft's inventory
	           list, on the left of the screen (where JEI moves it, its item list taking the
	           right): a 120 x 32 panel per effect with the glyph, the name and level in white and
	           the time in grey, 33 apart (closer when more than five need the room, as Minecraft
	           squeezes them). It draws over the screens' darkened backdrop (DisplayOrder 10 while
	           shown, above Screens' 9, under the cursor's 20), as Minecraft draws it over
	           renderBackground, and never takes clicks. When it would reach the screen's panels
	           (Screens.screenLeft) it shrinks to Minecraft's compact list, the glyphs alone in 32
	           wide panels, and hides when even that doesn't fit. A panel screen (the Options menu,
	           the skill tree, a structure form: Screens.panelOpen) hides both, as Minecraft's
	           menus show no effects.
	At the GUI scale (Ui/UiScale), hidden with the HUD (the world map hides it) and with
	Config.Effects.Hud off. Built again only when the server's effects come in another set or order
	(a refresh only takes the new times), or when the status icons start or stop showing their
	badges; a frame only fades the icons in their last 10 s and rewrites times that changed.

	Look: the survival look's flat dark squares (Panel, a Hairline outline) with the effect's glyph
	in its colours, and in the list flat dark panels with the name in white and the time in grey
	(Roboto: Style.Dayz.label). While the status icons show their badges in the HUD
	(StatusCluster.badgesShown: Bleeding, Infection, Poison, Wither, Hunger, Thirst, Nausea:
	StatusLayout.BADGES) the icons leave those effects out, and the block's size given to UiScale
	is the size without them; the inventory's row and list show every effect.
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
local HudLayout = require(script.Parent.HudLayout)
local Screens = require(script.Parent.Screens)
local StatusCluster = require(script.Parent.StatusCluster)
local StatusLayout = require(script.Parent.StatusLayout)
local Style = require(script.Parent.Style)
local UiScale = require(script.Parent.UiScale)

local EffectHud = {}

-- Minecraft's icon square, the step between icons and between the rows (GUI pixels).
local ICON = 24
local STEP = HudLayout.EFFECT_STEP
local ROW = HudLayout.EFFECT_ROW
-- The inventory list's panels and their spacing (Minecraft: 120 x 32, 33 apart; with more than
-- five, 132 / (count - 1)).
local LIST_WIDTH, LIST_HEIGHT = 120, 32
-- Minecraft's compact list (no room for the names): the glyph alone.
local COMPACT_WIDTH = 32
-- DisplayOrder of the icons (with the toasts) and of the list (over Screens' backdrop, under the
-- cursor and tooltip).
local ICONS_ORDER, LIST_ORDER = UiScale.Layer.Effects, UiScale.Layer.EffectList
local LIST_STEP = 33
local LIST_ROOM = 132
-- Screen pixels from the safe area's left edge and below the top bar for the list.
local LIST_MARGIN = 8
local LIST_TOP = 40

-- How the list draws: Minecraft's list, its compact one (the glyphs alone), or the row in the
-- open inventory's band (Screens.effectsDock).
type ListMode = "full" | "compact" | "dock"

-- The effects the status icons show as badges (left out of the icons while they do).
local BADGE_IDS: { [number]: boolean } = {}
for _, name in StatusLayout.BADGES do
	BADGE_IDS[Effects.id[name]] = true
end

-- One drawn effect: its entry as of `builtAt`, its icon (a CanvasGroup, for fading it whole) and
-- the time label in the list (nil on the icons).
type Shown = {
	entry: Effects.Entry,
	group: CanvasGroup?,
	time: TextLabel?,
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

-- The dark square and the glyph of `entry` at (x, y) of `parent`, its outline following `scaled`.
local function drawIcon(parent: Instance, x: number, y: number, entry: Effects.Entry, z: number, scaled: Style.Scaled)
	local effect = Effects.get(entry.effect)
	if effect == nil then
		return
	end
	local Dayz = Style.Dayz
	local square = Style.frame(parent, x, y, ICON, ICON, Dayz.Colour.Panel, z)
	square.BackgroundTransparency = Dayz.Alpha.Panel
	if entry.ambient then
		-- (An ambient effect's, a beacon's or a fluid's: a pale blue rim instead of the hairline.)
		Dayz.outline(square, Dayz.Colour.AmbientRim, Dayz.Alpha.AmbientRim, scaled)
	else
		Dayz.outline(square, Dayz.Colour.Hairline, Dayz.Alpha.Hairline, scaled)
	end
	Style.pixelArt(square, 3, 3, EffectIcons.glyph(effect.icon), EffectIcons.palette(effect.color), 2, 2)
end

-- `list` without the effects the status icons show as badges (a new table).
local function withoutBadges(list: { Effects.Entry }): { Effects.Entry }
	local kept = table.create(#list)
	for _, entry in list do
		if not BADGE_IDS[entry.effect] then
			table.insert(kept, entry)
		end
	end
	return kept
end

function EffectHud.start()
	if started then
		return
	end
	started = true
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	-- (The whole screen: Ui/HudLayout's screen pixels. With the toasts: over the minimap, under
	-- WAILA, the HUD and the screens' tooltips. Children draw over their parents whatever their
	-- ZIndex (Style's rule: a list panel's face, glyph and text sit inside its outline frame).)
	local gui = UiScale.screenGui("IceVoxelEffects", "Effects", { inset = true, full = true, kind = "scaled" })

	local holder = Instance.new("Frame")
	holder.Name = "Icons"
	holder.BackgroundTransparency = 1
	holder.Parent = gui
	local scale = Instance.new("UIScale")
	scale.Parent = holder
	Style.Dayz.mark(holder)
	-- (Outlines and text weights follow each part's scale.)
	local iconsScaled = Style.Dayz.scaled()
	-- The icons' block (GUI pixels: HudLayout.effectsSize), set by `build`.
	local blockWidth = ICON
	local tip = Style.Dayz.label(
		holder,
		"",
		0,
		ICON + 2,
		ICON,
		8,
		"small",
		Style.Dayz.Colour.Text,
		8,
		Enum.TextXAlignment.Right,
		iconsScaled
	)
	Style.Dayz.textStroke(tip, "TextStroke")

	local list = Instance.new("Frame")
	list.Name = "List"
	list.Size = UDim2.fromOffset(LIST_WIDTH, LIST_HEIGHT)
	list.BackgroundTransparency = 1
	list.Visible = false
	list.Parent = gui
	Style.Dayz.mark(list)
	local listScale = Instance.new("UIScale")
	listScale.Parent = list
	local listScaled = Style.Dayz.scaled()

	-- How the list draws now, and the band's row's width (the icons' pixels) while it is there.
	local listMode: ListMode = "full"
	local dockWidth = 0

	-- The list beside the screens: at the GUI scale, below the top bar.
	local function placeList()
		local scaleNow = UiScale.hud().scale
		if listScale.Scale ~= scaleNow then
			listScale.Scale = scaleNow
		end
		listScaled:setScale(scaleNow)
		local insets = UiScale.insets()
		list.Position = UDim2.fromOffset(insets.left + LIST_MARGIN, insets.bar + LIST_TOP)
	end

	-- Where Ui/HudLayout puts the icons (hidden when it finds no room), at its scale; the list
	-- (`placeList`) beside the screens.
	local placed = true
	local function layout()
		local corner = UiScale.hud()
		local block = corner.effects
		placed = block ~= nil
		if block then
			holder.Position = UDim2.fromOffset(block.x, block.y)
			if scale.Scale ~= corner.effectsScale then
				scale.Scale = corner.effectsScale
			end
			iconsScaled:setScale(corner.effectsScale)
		end
		-- (In the band, the row follows the dock every frame instead.)
		if listMode ~= "dock" then
			placeList()
		end
	end

	-- Draws the icons and the list again from the effects the server sent (`listMode`: the list,
	-- its compact form, or the band's row `dockWidth` of the icons' pixels wide; `badges`: the
	-- status icons show their badges, which the icons leave out).
	local lastLayout = ""
	local badges = false
	local function build()
		local now = os.clock()
		local entries = EffectState.list(now)
		local good, rest = Effects.hudOrder(entries)
		-- (The icons without the badges' effects while the status icons show them.)
		local iconGood, iconRest = good, rest
		if badges then
			iconGood, iconRest = withoutBadges(good), withoutBadges(rest)
		end
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
		table.insert(parts, if listMode == "dock" then `d{dockWidth}` else listMode)
		table.insert(parts, if badges then "b" else "-")
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
		-- The block: beneficial effects in the top row, the rest in the second (Minecraft's rows,
		-- the top one left empty without beneficial effects).
		local columns = math.max(#iconGood, #iconRest)
		local rowCount = if #iconRest > 0 then 2 elseif #iconGood > 0 then 1 else 0
		local size = HudLayout.effectsSize(columns, rowCount)
		blockWidth = if size then size.w else ICON
		holder.Size = UDim2.fromOffset(blockWidth, if size then size.h else ICON)
		local tipY = math.max(rowCount - 1, 0) * ROW + ICON + 2
		tip.Position = UDim2.fromOffset(0, tipY)
		tip.Size = UDim2.fromOffset(blockWidth, 8)
		UiScale.setEffects(columns, rowCount)
		for row, group in { iconGood, iconRest } do
			for i, entry in group do
				local canvas = Instance.new("CanvasGroup")
				canvas.Name = Effects.levelName(entry.effect, entry.amplifier)
				canvas.BackgroundTransparency = 1
				canvas.Position = UDim2.fromOffset(blockWidth + 1 - STEP * i, (row - 1) * ROW)
				canvas.Size = UDim2.fromOffset(ICON, ICON)
				canvas.Parent = holder
				drawIcon(canvas, 0, 0, entry, 1, iconsScaled)
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
		if listMode == "dock" then
			-- The band's row: every effect, the harmful and neutral ones first from the right end
			-- (the first drawn over the ones left of it when they squeeze), then the beneficial.
			local ordered = table.clone(rest)
			table.move(good, 1, #good, #ordered + 1, ordered)
			local shown, step = HudLayout.effectRow(#ordered, dockWidth)
			list.Size = UDim2.fromOffset(dockWidth, ICON)
			for i = 1, shown do
				local entry = ordered[i]
				drawIcon(list, dockWidth - ICON - (i - 1) * step, 0, entry, (shown - i + 1) * 10, listScaled)
				table.insert(rows, { entry = entry, seconds = -1, alpha = 1 })
			end
			return
		end
		-- The inventory list: every effect, beneficial first, as the icons.
		local compact = listMode == "compact"
		local all = table.clone(good)
		table.move(rest, 1, #rest, #all + 1, all)
		local step = if #all > 5 then math.min(LIST_STEP, LIST_ROOM // (#all - 1)) else LIST_STEP
		local width = if compact then COMPACT_WIDTH else LIST_WIDTH
		list.Size = UDim2.fromOffset(width, step * math.max(#all - 1, 0) + LIST_HEIGHT)
		local Dayz = Style.Dayz
		for i, entry in all do
			local y = (i - 1) * step
			local panel = Style.frame(list, 0, y, width, LIST_HEIGHT, Dayz.Colour.Panel, i * 10)
			panel.BackgroundTransparency = Dayz.Alpha.Panel
			Dayz.outline(panel, Dayz.Colour.Hairline, Dayz.Alpha.Hairline, listScaled)
			-- (The list never takes the screen's clicks.)
			panel.Active = false
			drawIcon(panel, 4, 4, entry, 4, listScaled)
			if compact then
				table.insert(rows, { entry = entry, seconds = -1, alpha = 1 })
				continue
			end
			Dayz.label(
				panel,
				Effects.levelName(entry.effect, entry.amplifier),
				32,
				5,
				LIST_WIDTH - 36,
				10,
				"body",
				Dayz.Colour.Text,
				6,
				Enum.TextXAlignment.Left,
				listScaled
			)
			local time =
				Dayz.label(panel, "", 32, 17, LIST_WIDTH - 36, 9, "small", Dayz.Colour.TextMuted, 6, nil, listScaled)
			table.insert(rows, { entry = entry, time = time, seconds = -1, alpha = 1 })
		end
	end

	layout()
	UiScale.hudChanged:Connect(layout)
	EffectState.changed:Connect(build)
	gui.Parent = playerGui

	local lastTipEffect, lastTipSeconds = 0, -1
	RunService.RenderStepped:Connect(function()
		-- (The status icons started or stopped showing their badges: the icons change.)
		local withBadges = StatusCluster.badgesShown()
		if withBadges ~= badges then
			badges = withBadges
			build()
		end
		local on = Config.Effects.Hud == true and UiScale.hudShown() and #icons + #rows > 0 and not Screens.panelOpen()
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
		-- The row in the open inventory's band, else the list beside the screen's panels: full,
		-- compact, or none when even that would reach them.
		local listShown = screen
		if screen then
			local dock = Screens.effectsDock()
			local want: ListMode
			local width = dockWidth
			if dock and dock.h > 0 then
				want = "dock"
				local iconScale = dock.h / ICON
				width = math.floor(dock.w / iconScale + 1e-6)
				local origin = gui.AbsolutePosition
				local x, y = dock.x - origin.X, dock.y - origin.Y
				local at = list.Position
				if at.X.Offset ~= x or at.Y.Offset ~= y or at.X.Scale ~= 0 or at.Y.Scale ~= 0 then
					list.Position = UDim2.fromOffset(x, y)
				end
				if listScale.Scale ~= iconScale then
					listScale.Scale = iconScale
					listScaled:setScale(iconScale)
				end
			else
				if listMode == "dock" then
					-- (Back beside the screen, at the GUI scale.)
					placeList()
				end
				local left = Screens.screenLeft()
				local room = if left then left - LIST_MARGIN * 2 else math.huge
				want = if LIST_WIDTH * listScale.Scale > room then "compact" else "full"
				listShown = COMPACT_WIDTH * listScale.Scale <= room
			end
			if want ~= listMode or (want == "dock" and width ~= dockWidth) then
				listMode, dockWidth = want, width
				build()
			end
		end
		local iconsShown = not screen and placed
		if holder.Visible ~= iconsShown or list.Visible ~= listShown then
			holder.Visible = iconsShown
			list.Visible = listShown
		end
		local now = os.clock()
		if screen then
			for _, shown in rows do
				local seconds = ticksLeft(shown.entry, now) // Effects.TICKS_PER_SECOND
				local time = shown.time
				if seconds ~= shown.seconds and time then
					shown.seconds = seconds
					time.Text = Effects.formatTicks(ticksLeft(shown.entry, now))
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
			tip.Text = text
		end
	end)
end

return EffectHud

--!strict
--[[
	The status icons: a survival game's notifiers at the bottom right of the screen in place of
	Minecraft's hearts, armor, hunger shanks, Tough As Nails' droplets and thermometer, Terraria's
	mana stars and the experience bar. Where and how they are laid out, their levels, colours and
	trends are Ui/StatusLayout's (pure, specced); their silhouettes Ui/StatusGlyphs'. Survival and
	adventure only (GameMode.isSurvivalLike).

	  where      a Frame in the HUD's ScreenGui (Ui/Hud builds it: no ScreenGui of its own), not
	             Active (clicks go through), with its own UIScale. While the open inventory docks it
	             (Ui/StatusDock: its quickbar band, absolute screen pixels and a scale) the "dock"
	             variant, the notifiers alone, sits there; otherwise, with the HUD in "play", where
	             Ui/HudLayout put it (UiScale.hud(): `status`, `statusScale`, `statusVariant`: the
	             "full" variant with the knowledge bar at the bottom right on the quickbar's base
	             line where it fits, else the "lean" one, else elsewhere); otherwise hidden. Placed
	             again only when the dock, the HUD's corner or the mode changes.
	  sizes      the variants' sizes go to Ui/UiScale (`setStatus`) whenever the badges' rows, the
	             knowledge row or Config.Ui.StatusValues change them, and nil outside survival, so
	             the rest of the HUD's corner keeps clear of them.
	  notifiers  THIRST, FOOD, TEMPERATURE | MANA, ARMOR, HEALTH (each while its feature is on:
	             StatusLayout.columns). Each glyph is a dim copy (GlyphEmpty) under a bright one in a
	             bottom-anchored clipping frame as tall as the rows lit (StatusLayout.fill), so it
	             empties from the top; the bright one takes its level's colour (StatusLayout.colour,
	             blinking every Theme.Time.BLINK at level 5); up to three chevrons above it while
	             the stat rises, below while it falls. The data:
	               health       the Humanoid's health as half hearts of 20 (StatusLayout.halves);
	                            flashes white for Theme.Time.FLASH after a hit; falls by its drains
	                            (Bleeding, Poison, Wither, starving, dehydrated), else for a hit in
	                            the last 2 s, else rises while it regenerates (StatusLayout.
	                            regenerating with the bars as the server sent them).
	               food, thirst the server's bars (Player/SurvivalState); falling under the Hunger /
	                            Thirst effects or without saturation / hydration.
	               temperature  the body temperature on Tough As Nails' -10..10 scale (its fill), its
	                            zone's level (cold side blue), blinking while freezing or
	                            overheating; the chevrons point to its target (a held Thermometer
	                            says how fast).
	               mana         Player/ManaState; dimmed whole (GlyphEmpty) while Ui/ManaStars says
	                            the stars would not show (no magic weapon, full and unchanged);
	                            blinks white after a cast the server refused.
	               armor        Items/Accessories.armorPoints, out of 20, always Icon white.
	             With Config.Ui.StatusValues the number under each (full variant only).
	  badges     StatusLayout.BADGES while their effect runs (Player/EffectState), and
	             STATUS_BADGES with Config.Effects.Hud off, in priority order, in rows above the
	             notifiers with their number (StatusLayout.badgeText). Not in the dock variant.
	             `badgesShown` tells Ui/EffectHud to leave them out of its icons.
	  knowledge  the knowledge level and the progress into it (Player/ProgressionState,
	             Shared/Progression/Knowledge.progress) in the full variant, while there is one.

	Built once; every frame only compares and writes what changed (the blink and the flash change
	a colour four times a second while they run). The masks are drawn once and kept by name
	("status." and the glyph's name) by Style.Dayz.maskImage.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Effects = require(Shared.Effects)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Accessories = require(Shared.Items.Accessories)
local Knowledge = require(Shared.Progression.Knowledge)
local Temperature = require(Shared.ToughAsNails.Temperature)

local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local EffectState = require(script.Parent.Parent.Player.EffectState)
local ManaState = require(script.Parent.Parent.Player.ManaState)
local ProgressionState = require(script.Parent.Parent.Player.ProgressionState)
local SurvivalState = require(script.Parent.Parent.Player.SurvivalState)
local ManaStars = require(script.Parent.ManaStars)
local Masks = require(script.Parent.Masks)
local StatusDock = require(script.Parent.StatusDock)
local StatusGlyphs = require(script.Parent.StatusGlyphs)
local StatusLayout = require(script.Parent.StatusLayout)
local Style = require(script.Parent.Style)
local Theme = require(script.Parent.Theme)
local UiScale = require(script.Parent.UiScale)

local StatusCluster = {}

type Notifier = StatusLayout.Notifier
type Variant = StatusLayout.Variant

-- One notifier's column and what it shows.
type Column = {
	frame: Frame,
	clip: Frame,
	bright: GuiObject,
	up: { GuiObject },
	down: { GuiObject },
	value: TextLabel,
	rows: number,
	colour: string,
	trend: number,
	number: number,
}

-- One badge and what it shows (`seen`: the last frame it was in the order).
type Badge = {
	name: string,
	id: number,
	frame: Frame,
	count: TextLabel,
	slot: number,
	amplifier: number,
	minutes: number,
	seen: number,
}

local GLYPH = StatusLayout.GLYPH
local COLUMN = StatusLayout.COLUMN
-- The glyph's place in its column.
local GLYPH_X = (COLUMN - GLYPH) // 2
-- A badge number's faint dark outline.
local COUNT_STROKE_T = 0.4
-- The thermometer item (its holder's trend shows how fast).
local THERMOMETER = Items.id.Thermometer
local DRAINS = { Effects.id.Bleeding, Effects.id.Poison, Effects.id.Wither }
local HUNGER_EFFECT = Effects.id.Hunger

local built = false
local hudGui: ScreenGui? = nil
local root: Frame? = nil
local scale: UIScale? = nil
local scaled: Style.Scaled? = nil
local notifiers: Frame? = nil
local divider: Frame? = nil
local knowledgeRow: Frame? = nil
local levelLabel: TextLabel? = nil
local xpFill: Frame? = nil
local columns: { [Notifier]: Column } = {}
local badges: { Badge } = {}

-- Reused: the features on, the columns' x, the badges shown in order.
local present: { [Notifier]: boolean } = {}
local xs: { [Notifier]: number } = {}
local order: { Badge } = {}

-- What is placed and shown.
local placedVariant: Variant? = nil
local shownBadges = 0
local shownKnowledge = false
-- (Bit i: ORDER[i] is there; -1: nothing placed yet.)
local shownPresent = -1
local placementDirty = true
local lastSerial = -1
local lastMode = ""
local lastSurvival = false
local inHud = false
-- (The sizes UiScale was told: badge rows, knowledge and values packed; -1: none.)
local sizesKey = -2
local frameCount = 0

-- Changes noticed between frames.
local armorDirty = true
local armorPoints = 0
local knowledgeDirty = true
local knowledgePoints = -1
local character: Model? = nil
local humanoid: Humanoid? = nil
local lastHalves = -1
local hurtAt = -math.huge
local flashUntil = 0
local lastMana = -1
local manaDelta = 0
local manaChangedAt = -math.huge

local function mask(name: string): () -> Masks.Mask
	return function()
		return StatusGlyphs.render(name)
	end
end

local function newColumn(parent: Frame, name: Notifier, s: Style.Scaled): Column
	local Dayz = Style.Dayz
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromOffset(COLUMN, StatusLayout.NOTIFIERS_H)
	frame.Visible = false
	frame.Parent = parent
	local glyphY = StatusLayout.ROW.glyph
	Dayz.maskImage(
		frame,
		`status.{name}`,
		mask(name),
		GLYPH_X,
		glyphY,
		GLYPH,
		GLYPH,
		Dayz.Colour.GlyphEmpty,
		Dayz.Alpha.GlyphEmpty,
		2
	)
	-- (The bright copy in a frame anchored at the glyph's bottom: as tall as the rows lit.)
	local clip = Instance.new("Frame")
	clip.Name = "Fill"
	clip.BackgroundTransparency = 1
	clip.BorderSizePixel = 0
	clip.ClipsDescendants = true
	clip.AnchorPoint = Vector2.new(0, 1)
	clip.Position = UDim2.fromOffset(GLYPH_X, glyphY + GLYPH)
	clip.Size = UDim2.fromOffset(GLYPH, 0)
	clip.ZIndex = 3
	clip.Parent = frame
	local bright = Dayz.maskImage(clip, `status.{name}`, mask(name), 0, 0, GLYPH, GLYPH, Dayz.Colour.Icon, 0, 1)
	bright.AnchorPoint = Vector2.new(0, 1)
	bright.Position = UDim2.new(0, 0, 1, 0)
	local c = StatusLayout.CHEVRON
	local up, down = {}, {}
	for i = 1, StatusLayout.MAX_TREND do
		local ux, uy = StatusLayout.chevronAt(1, i)
		local rising =
			Dayz.maskImage(frame, "status.chevronUp", mask("chevronUp"), ux, uy, c.w, c.h, Dayz.Colour.Icon, 0, 4)
		rising.Visible = false
		up[i] = rising
		local dx, dy = StatusLayout.chevronAt(-1, i)
		local falling =
			Dayz.maskImage(frame, "status.chevronDown", mask("chevronDown"), dx, dy, c.w, c.h, Dayz.Colour.Icon, 0, 4)
		falling.Visible = false
		down[i] = falling
	end
	local value = Dayz.label(
		frame,
		"",
		-4,
		StatusLayout.ROW.value,
		COLUMN + 8,
		StatusLayout.VALUE_H,
		"small",
		Dayz.Colour.TextSoft,
		4,
		Enum.TextXAlignment.Center,
		s
	)
	value.Visible = false
	return {
		frame = frame,
		clip = clip,
		bright = bright,
		up = up,
		down = down,
		value = value,
		rows = 0,
		colour = "Icon",
		trend = 0,
		number = math.huge,
	}
end

local function newBadge(parent: Frame, name: string, s: Style.Scaled): Badge
	local Dayz = Style.Dayz
	local size = StatusLayout.BADGE
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromOffset(size, size)
	frame.Visible = false
	frame.Parent = parent
	Dayz.maskImage(frame, `status.{name}`, mask(name), 0, 0, size, size, Dayz.Colour.Icon, 0, 1)
	local count = Dayz.label(
		frame,
		"",
		2,
		3,
		size,
		StatusLayout.VALUE_H,
		"small",
		Dayz.Colour.Text,
		3,
		Enum.TextXAlignment.Right,
		s
	)
	count.TextStrokeColor3 = Color3.new(0, 0, 0)
	count.TextStrokeTransparency = COUNT_STROKE_T
	return {
		name = name,
		id = Effects.id[name],
		frame = frame,
		count = count,
		slot = 0,
		amplifier = -1,
		minutes = -1,
		seen = 0,
	}
end

-- Builds the icons into the HUD's `gui` (hidden until `render` places them).
function StatusCluster.build(gui: ScreenGui)
	if built then
		return
	end
	built = true
	hudGui = gui
	local Dayz = Style.Dayz
	local s = Dayz.scaled()
	scaled = s
	local frame = Instance.new("Frame")
	frame.Name = "Status"
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Active = false
	frame.Visible = false
	frame.ZIndex = 2
	frame.Size = UDim2.fromOffset(StatusLayout.WIDTH, StatusLayout.NOTIFIERS_H)
	frame.Parent = gui
	Dayz.mark(frame)
	root = frame
	local uiScale = Instance.new("UIScale")
	uiScale.Parent = frame
	scale = uiScale

	local block = Instance.new("Frame")
	block.Name = "Notifiers"
	block.BackgroundTransparency = 1
	block.BorderSizePixel = 0
	block.Size = UDim2.fromOffset(StatusLayout.NOTIFIERS_W, StatusLayout.NOTIFIERS_H)
	block.Parent = frame
	notifiers = block
	for _, name in StatusLayout.ORDER do
		columns[name] = newColumn(block, name, s)
	end
	local bar = StatusLayout.DIVIDER_BAR
	local glyphMiddle = StatusLayout.ROW.glyph + GLYPH / 2
	local line = Dayz.divider(block, 0, glyphMiddle - bar.h / 2, bar.w, bar.h, 2)
	line.Visible = false
	divider = line
	for _, list in { StatusLayout.BADGES, StatusLayout.STATUS_BADGES } do
		for _, name in list do
			table.insert(badges, newBadge(block, name, s))
		end
	end

	local row = Instance.new("Frame")
	row.Name = "Knowledge"
	row.BackgroundTransparency = 1
	row.BorderSizePixel = 0
	row.Size = UDim2.fromOffset(StatusLayout.WIDTH, StatusLayout.XP_H)
	row.Visible = false
	row.Parent = frame
	knowledgeRow = row
	local level = StatusLayout.LEVEL
	levelLabel = Dayz.label(
		row,
		"",
		level.x,
		0,
		level.w,
		StatusLayout.XP_H,
		"small",
		Dayz.Colour.Text,
		3,
		Enum.TextXAlignment.Right,
		s
	)
	local xp = StatusLayout.XP_BAR
	local track = Style.frame(row, xp.x, xp.y, xp.w, xp.h, Dayz.Colour.XpTrack, 2)
	track.BackgroundTransparency = Dayz.Alpha.XpTrack
	local fill = Style.frame(track, 0, 0, 0, xp.h, Dayz.Colour.XpFill, 1)
	fill.BackgroundTransparency = Dayz.Alpha.XpFill
	fill.Size = UDim2.fromScale(0, 1)
	xpFill = fill

	UiScale.hudChanged:Connect(function()
		placementDirty = true
	end)
	ClientInventory.changed:Connect(function()
		armorDirty = true
	end)
	ProgressionState.changed:Connect(function()
		knowledgeDirty = true
	end)
end

-- Are the badges showing in the HUD (the full or lean variant, visible)? Ui/EffectHud then leaves
-- them out of its icons.
function StatusCluster.badgesShown(): boolean
	return inHud
end

local function setVisible(object: GuiObject?, visible: boolean)
	if object and object.Visible ~= visible then
		object.Visible = visible
	end
end

-- Paints a column: rows lit, colour key, trend, and its value (nil: none).
local function paint(column: Column, rows: number, colour: string, trend: number, number: number?, name: Notifier)
	if rows ~= column.rows then
		column.rows = rows
		column.clip.Size = UDim2.fromOffset(GLYPH, rows)
	end
	if colour ~= column.colour then
		column.colour = colour
		Style.Dayz.tint(column.bright, Style.Dayz.Colour[colour], 0)
	end
	if trend ~= column.trend then
		column.trend = trend
		for i = 1, StatusLayout.MAX_TREND do
			column.up[i].Visible = trend >= i
			column.down[i].Visible = -trend >= i
		end
	end
	local shows = number ~= nil and placedVariant == "full" and Config.Ui.StatusValues == true
	setVisible(column.value, shows)
	if shows and number and number ~= column.number then
		column.number = number
		column.value.Text = StatusLayout.valueText(name, number)
		column.value.TextColor3 = if name == "temperature"
			then Style.Dayz.Zone[Temperature.zone(number)]
			else Style.Dayz.Colour.TextSoft
	end
end

-- Lays the frame's parts out for `variant` and the badges' rows (on change only).
local function arrange(variant: Variant, badgeCount: number, knowledge: boolean)
	local frame, block, row = root, notifiers, knowledgeRow
	if frame == nil or block == nil or row == nil then
		return
	end
	local values = Config.Ui.StatusValues == true
	local top, _, xpY = StatusLayout.blocks(variant, values, badgeCount, knowledge)
	local w, h = StatusLayout.size(variant, values, badgeCount, knowledge)
	frame.Size = UDim2.fromOffset(w, h)
	block.Position = UDim2.fromOffset(0, top)
	setVisible(row, xpY ~= nil)
	if xpY then
		row.Position = UDim2.fromOffset(0, xpY)
	end
end

-- Tells UiScale the HUD variants' sizes (nil: none), only when they change; whether they did.
local function reportSizes(survival: boolean, badgeCount: number, knowledge: boolean): boolean
	local values = Config.Ui.StatusValues == true
	local rows = StatusLayout.badgeRows(badgeCount)
	local key = if survival then rows * 4 + (if knowledge then 2 else 0) + (if values then 1 else 0) else -1
	if key == sizesKey then
		return false
	end
	sizesKey = key
	if not survival then
		UiScale.setStatus(nil)
		return true
	end
	-- (Sizes by the rows' count: any badge count in a row gives the same size.)
	local fw, fh = StatusLayout.size("full", values, rows * StatusLayout.BADGES_PER_ROW, knowledge)
	local lw, lh = StatusLayout.size("lean", values, rows * StatusLayout.BADGES_PER_ROW, knowledge)
	UiScale.setStatus({ full = { w = fw, h = fh }, lean = { w = lw, h = lh } })
	return true
end

-- The present notifiers' columns (when the features on change).
local function placeColumns()
	local key = 0
	for i, name in StatusLayout.ORDER do
		if present[name] then
			key += bit32.lshift(1, i - 1)
		end
	end
	if key == shownPresent then
		return
	end
	shownPresent = key
	local x = StatusLayout.columns(present, 0, xs)
	for name, column in columns do
		local at = xs[name]
		setVisible(column.frame, at ~= nil)
		if at then
			column.frame.Position = UDim2.fromOffset(at, 0)
		end
	end
	setVisible(divider, x ~= nil)
	if divider and x then
		divider.Position = UDim2.new(0, x, 0, divider.Position.Y.Offset)
	end
end

-- The badges running now, in priority order, into `order` (whether they show or not: the HUD's
-- sizes count them while the dock hides them, so opening the inventory moves nothing).
local function collectBadges(survival: boolean)
	table.clear(order)
	if not survival then
		return
	end
	local statusBadges = Config.Effects.Hud ~= true
	for i, badge in badges do
		if i > #StatusLayout.BADGES and not statusBadges then
			break
		end
		local amplifier = EffectState.get(badge.id)
		if amplifier ~= nil and #order < StatusLayout.MAX_BADGES then
			table.insert(order, badge)
		end
	end
end

-- Shows the badges in `order` in their slots, with their numbers (`frameId`: this frame's; none
-- unless `shown`).
local function paintBadges(frameId: number, shown: boolean)
	for slot, badge in order do
		if not shown then
			break
		end
		badge.seen = frameId
		if badge.slot ~= slot then
			badge.slot = slot
			local x, y = StatusLayout.badgeAt(slot)
			badge.frame.Position = UDim2.fromOffset(x, y)
		end
		setVisible(badge.frame, true)
		local amplifier, ticks = EffectState.get(badge.id)
		local amp = amplifier or 0
		local minutes = if badge.name == "ClimateClemency" then math.ceil(ticks / (20 * 60)) else 0
		if amp ~= badge.amplifier or minutes ~= badge.minutes then
			badge.amplifier, badge.minutes = amp, minutes
			badge.count.Text = StatusLayout.badgeText(badge.name, amp, ticks)
		end
	end
	for _, badge in badges do
		if badge.seen ~= frameId and badge.frame.Visible then
			badge.frame.Visible = false
			badge.slot = 0
		end
	end
end

--[[
	Places the frame: in the dock (`variant` "dock"), or where the HUD's corner put it, or nowhere
	(nil). Returns the variant shown.
]]
local function place(mode: string, survival: boolean): Variant?
	local frame, uiScale, gui = root, scale, hudGui
	if frame == nil or uiScale == nil or gui == nil then
		return nil
	end
	local dock, dockScale = StatusDock.get()
	local variant: Variant? = nil
	local x, y, s = 0, 0, 1
	if survival and dock then
		-- (The dock is in the GUI's AbsolutePosition space.)
		local origin = gui.AbsolutePosition
		variant, x, y, s = "dock", dock.x - origin.X, dock.y - origin.Y, dockScale
	elseif survival and mode == "play" then
		local corner = UiScale.hud()
		local rect = corner.status
		if rect and corner.statusVariant then
			-- (HudLayout's screen pixels, from the screen's top left.)
			local origin = UiScale.origin(gui)
			variant, x, y, s = corner.statusVariant, rect.x - origin.X, rect.y - origin.Y, corner.statusScale
		end
	end
	if variant then
		frame.Position = UDim2.fromOffset(x, y)
		if uiScale.Scale ~= s then
			uiScale.Scale = s
		end
		local registry = scaled
		if registry then
			registry:setScale(s)
		end
	end
	return variant
end

local function readHumanoid(): Humanoid?
	local current = Players.LocalPlayer.Character
	if current ~= character then
		character = current
		humanoid = if current then current:FindFirstChildOfClass("Humanoid") else nil
		lastHalves = -1
	elseif current and humanoid == nil then
		humanoid = current:FindFirstChildOfClass("Humanoid")
	end
	return humanoid
end

--[[
	Draws this frame (Ui/Hud's RenderStepped, before its open-screen check): `mode` is the HUD's
	("play", "creative", "hidden").
]]
function StatusCluster.render(now: number, mode: string)
	local frame = root
	if frame == nil then
		return
	end
	local survival = GameMode.isSurvivalLike(ClientInventory.mode())
	local status = SurvivalState.get()
	local progress = ProgressionState.get()
	local knowledge = survival and progress ~= nil and ProgressionState.enabled()

	-- The badges running, and the sizes the HUD's corner keeps room for (laid out again at once
	-- when they change).
	collectBadges(survival)
	if reportSizes(survival, #order, knowledge) then
		placementDirty = true
	end
	-- Placement: on a change of the dock, the corner, the mode or survival.
	local serial = StatusDock.serial()
	if placementDirty or serial ~= lastSerial or mode ~= lastMode or survival ~= lastSurvival then
		placementDirty, lastSerial, lastMode, lastSurvival = false, serial, mode, survival
		placedVariant = place(mode, survival)
		shownBadges, shownKnowledge = -1, not knowledge
		knowledgeDirty = true
	end
	local variant = placedVariant
	inHud = variant == "full" or variant == "lean"
	setVisible(frame, variant ~= nil)
	if variant == nil then
		return
	end
	-- (The dock shows the notifiers alone.)
	local badgeCount = if inHud then #order else 0
	if badgeCount ~= shownBadges or knowledge ~= shownKnowledge then
		shownBadges, shownKnowledge = badgeCount, knowledge
		arrange(variant, badgeCount, knowledge)
	end
	frameCount += 1
	paintBadges(frameCount, inHud)

	-- Which notifiers are there.
	present.thirst = status ~= nil and status.thirstOn
	present.food = status ~= nil and status.hungerOn
	present.temperature = status ~= nil and status.temperatureOn
	present.mana = Config.Mana.Enabled == true
	present.armor = true
	present.health = true
	placeColumns()

	local blink = StatusLayout.blinkOn(now, Theme.Time.BLINK)
	local levels = EffectState.levels()

	-- Health.
	local h = readHumanoid()
	local health, maxHealth = 0, 20
	if h then
		health, maxHealth = h.Health, h.MaxHealth
	end
	local halves = StatusLayout.halves(health, maxHealth)
	if lastHalves >= 0 and halves < lastHalves then
		hurtAt = now
		flashUntil = now + Theme.Time.FLASH
	end
	lastHalves = halves
	local drains = 0
	for _, id in DRAINS do
		if levels[id] ~= nil then
			drains += 1
		end
	end
	local food, thirst = 20, 20
	if status then
		food, thirst = status.food, status.thirst
		if status.hungerOn and food <= 0 then
			drains += 1
		end
		if status.thirstOn and thirst <= 0 then
			drains += 1
		end
	end
	local regenerating = status ~= nil
		and StatusLayout.regenerating(status.hungerOn, status.thirstOn, food, thirst, halves >= 20)
	local healthLevel = StatusLayout.level("health", health, maxHealth)
	local healthColour = StatusLayout.colour(healthLevel, "neutral", blink)
	if now < flashUntil and blink then
		healthColour = "Blink"
	end
	paint(
		columns.health,
		StatusLayout.fill(halves, 20),
		healthColour,
		StatusLayout.healthTrend(drains, regenerating, now - hurtAt < StatusLayout.HURT_TREND),
		halves,
		"health"
	)

	-- Armor.
	if armorDirty then
		armorDirty = false
		armorPoints = Accessories.armorPoints(ClientInventory.inventory())
	end
	paint(columns.armor, StatusLayout.fill(math.min(armorPoints, 20), 20), "Icon", 0, armorPoints, "armor")

	-- Mana.
	if present.mana then
		local mana, max = ManaState.get()
		if mana ~= lastMana then
			if lastMana >= 0 then
				manaDelta = mana - lastMana
				manaChangedAt = now
			end
			lastMana = mana
		end
		local held = ClientInventory.selectedStack()
		local refused = now - ManaState.refusedAt() < Theme.Time.FLASH
		local magic = held ~= nil and Items.magic(held.item) ~= nil
		local shows = ManaStars.shown(survival, magic or refused, mana, max, now - ManaState.changedAt())
		if shows then
			local level = StatusLayout.level("mana", mana, max)
			local colour = if refused and blink then "Blink" else StatusLayout.colour(level, "neutral", blink)
			paint(
				columns.mana,
				StatusLayout.fill(mana, max),
				colour,
				StatusLayout.manaTrend(manaDelta, now - manaChangedAt),
				mana,
				"mana"
			)
		else
			-- (Dimmed whole: the dim copy alone.)
			paint(columns.mana, 0, "Icon", 0, mana, "mana")
		end
	end

	if status then
		local held = ClientInventory.selectedStack()
		if status.hungerOn then
			local level = StatusLayout.level("food", food, 20)
			paint(
				columns.food,
				StatusLayout.fill(food, 20),
				StatusLayout.colour(level, "neutral", blink),
				StatusLayout.foodTrend(status.saturation, levels[HUNGER_EFFECT] ~= nil),
				food,
				"food"
			)
		end
		if status.thirstOn then
			local level = StatusLayout.level("thirst", thirst, 20)
			paint(
				columns.thirst,
				StatusLayout.fill(thirst, 20),
				StatusLayout.colour(level, "neutral", blink),
				StatusLayout.thirstTrend(status.hydration, status.effect > 0),
				thirst,
				"thirst"
			)
		end
		if status.temperatureOn then
			local value = math.clamp(status.temperature, Temperature.MIN, Temperature.MAX)
			local level, side = StatusLayout.temperatureLevel(Temperature.zone(value), status.frozen, status.heat)
			paint(
				columns.temperature,
				StatusLayout.fill(value - Temperature.MIN, Temperature.MAX - Temperature.MIN),
				StatusLayout.colour(level, side, blink),
				StatusLayout.temperatureTrend(value, status.target, held ~= nil and held.item == THERMOMETER),
				math.round(value),
				"temperature"
			)
		end
	end

	-- Knowledge (full variant; worked out again only when the points change or it is re-placed).
	if knowledge and progress and variant == "full" and (knowledgeDirty or progress.points ~= knowledgePoints) then
		knowledgeDirty = false
		knowledgePoints = progress.points
		local level, into, needed = Knowledge.progress(progress.points)
		local share = math.clamp(into / math.max(needed, 1), 0, 1)
		local label, fill = levelLabel, xpFill
		if label then
			label.Text = if level > 0 then tostring(level) else ""
		end
		if fill then
			fill.Size = UDim2.fromScale(share, 1)
		end
	end
end

return StatusCluster

--!strict
--[[
	Tough As Nails on the HUD (Ui/Hud builds it into its canvas, so the GUI scale is the hotbar's),
	from the state the server sends (Player/SurvivalState), survival and adventure only, as the
	hearts:

	  droplets     with thirst on: 10 droplets on the right above the hotbar, where Minecraft's
	               hunger sits (its 81 x 9 row level with the hearts), filled from the right as
	               hunger is (thirst 2 points a droplet, a half droplet its right half). Pixel art
	               like the hearts. Under TAN's Thirst effect (dirty water) they turn a sickly
	               green, as hunger's shanks do under Hunger; with no hydration left they jitter
	               like hunger without saturation (Gui.renderPlayerHealth: each droplet moves
	               -1..1 pixel on ticks where tick % (thirst x 3 + 1) == 0).
	  gauge        with temperature on: a thermometer in the row over the droplets (the armor
	               row's mirror, where Minecraft draws the air bubbles), 75 x 9 pixels, right-
	               aligned with them: a round bulb in the colour of the body's zone (pale blue
	               icy, blue cold, green neutral, orange warm, red hot; TAN's orb colours), then a
	               tube of 21 cells of 3 pixels, one per step of the -10..10 scale, tinted dimly by
	               zone, with a dark tick through it at each zone border, and a pin in the zone's
	               colour on the body temperature. A small arrow beside the pin says where it is
	               going (right, orange: warming; left, pale blue: cooling; none: on target).
	  status       a row above the held item name's row (which is over the gauge's: Ui/Hud's
	               name is centred, and a long one such as "Purified Water Canteen" reaches the
	               right side), right-aligned: TAN's Climate Clemency while it lasts (a gold
	               shield and the minutes and seconds left, with thirst or temperature on), then
	               Internal Warmth (a flame) and Internal Chill (a snowflake) while they do (with
	               temperature on). Only with Config.Effects.Hud off: the status effects' icons in
	               the top right (Ui/EffectHud) show the same three with their time left. When
	               Terraria's mana stars (Ui/ManaHud) push the item name up, this row and the
	               reading above it go up as far (`render`'s `raise`).
	  reading      while a Thermometer (ItemList, TAN's) is the held item, with temperature on: the
	               row above the status row (in its place when it isn't drawn) reads out the body
	               temperature and its target as numbers ("-3", "+5"), each in its zone's colour,
	               with an arrow between them in the trend's colour (orange warming, pale blue
	               cooling, white on target), right-aligned like the rows below it.
	  edges        hypothermia and hyperthermia close in from the screen's edges, frost white-blue
	               or heat orange-red, as strong as they have got (Minecraft's powder snow outline,
	               alpha = the share of Temperature.EXTREME_TICKS frozen; TAN's heat overlay the
	               same way).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local Temperature = require(Shared.ToughAsNails.Temperature)

local SurvivalState = require(script.Parent.Parent.Player.SurvivalState)
local Style = require(script.Parent.Style)

-- Where Ui/Hud puts things (GUI pixels in its canvas).
export type Layout = {
	-- The canvas' width (the hotbar's), the droplets' row, and the tops of the gauge's row and of
	-- the status row above it, clear of the held item name's row (both right-aligned with the
	-- droplets; the thermometer's reading goes a row above the status row).
	width: number,
	rowY: number,
	gaugeY: number,
	statusY: number,
}

local SurvivalHud = {}

local TICK = 0.05
-- The edges reach this far into the screen (share of its height / width) at full strength.
local EDGE = 0.3
local EDGE_STRENGTH = 0.85
-- The gauge: its width, a cell's width and where the first cell starts (after the bulb).
local GAUGE_WIDTH = 75
local CELL = 3
local TUBE_X = 7
-- The rows' width (the droplets').
local ROW_WIDTH = 81
-- The item whose holder sees the reading.
local THERMOMETER = Items.id.Thermometer
-- The status row, unless the effect icons (Ui/EffectHud) show its effects already.
local STATUS_ROW = Config.Effects.Hud ~= true

-- 9 x 9: K outline, L / R the left / right half, H a highlight (with the left half).
local DROPLET = {
	"....K....",
	"...KLK...",
	"..KHLRK..",
	".KHLLRRK.",
	".KHLLRRK.",
	"KHLLLRRRK",
	"KLLLLRRRK",
	".KLLLRRK.",
	"..KKKKK..",
}
-- 7 x 7 (the gauge's rows 1..7): K outline, F fill, H highlight; its right column runs into the
-- tube.
local BULB = {
	"..KKK..",
	".KFFFKK",
	"KFHFFFF",
	"KFFFFFF",
	"KFFFFFF",
	".KFFFKK",
	"..KKK..",
}
-- 5 x 9 around a cell: K outline, P the zone's colour, H highlight, D shade.
local PIN = {
	"KKKKK",
	"KHHHK",
	"KPPPK",
	"KPPPK",
	"KPPPK",
	"KPPPK",
	"KPPPK",
	"KDDDK",
	"KKKKK",
}
local RIGHT = { "A..", "AA.", "AAA", "AA.", "A.." }
local LEFT = { "..A", ".AA", "AAA", ".AA", "..A" }
-- 7 x 7 icons: Climate Clemency's shield, Internal Warmth's flame, Internal Chill's snowflake.
local SHIELD = {
	"KKKKKKK",
	"KGHGGGK",
	"KGHGGGK",
	"KGGGGGK",
	".KGGGK.",
	"..KGK..",
	"...K...",
}
local FLAME = {
	"...R...",
	"..RR...",
	"..RRR..",
	".RROR.R",
	".ROOORR",
	"RROYORR",
	".RRRRR.",
}
local SNOWFLAKE = {
	"B..B..B",
	".B.B.B.",
	"..BBB..",
	"BBBWBBB",
	"..BBB..",
	".B.B.B.",
	"B..B..B",
}

local OUTLINE = Color3.fromRGB(16, 16, 16)
local WATER = Color3.fromRGB(48, 118, 230)
local WATER_SHINE = Color3.fromRGB(160, 210, 255)
local SICK = Color3.fromRGB(112, 160, 64)
local SICK_SHINE = Color3.fromRGB(176, 214, 120)
local EMPTY = Color3.fromRGB(28, 32, 44)
local EMPTY_SHINE = Color3.fromRGB(44, 50, 66)
local WARMING = Color3.fromRGB(255, 150, 40)
local COOLING = Color3.fromRGB(150, 210, 255)
local FROST = Color3.fromRGB(205, 235, 255)
local HEAT = Color3.fromRGB(255, 96, 32)
local CLEMENCY = Color3.fromRGB(236, 200, 92)
local CLEMENCY_SHINE = Color3.fromRGB(255, 240, 178)
local TEXT = Color3.fromRGB(255, 255, 255)

-- Zone colours (TAN's orb): fill, highlight, shade.
local ZONE_COLOURS: { [number]: { Color3 } } = {
	[-2] = { Color3.fromRGB(180, 230, 255), Color3.fromRGB(240, 250, 255), Color3.fromRGB(120, 180, 220) },
	[-1] = { Color3.fromRGB(70, 140, 230), Color3.fromRGB(150, 200, 255), Color3.fromRGB(40, 90, 170) },
	[0] = { Color3.fromRGB(120, 200, 90), Color3.fromRGB(190, 240, 160), Color3.fromRGB(70, 140, 50) },
	[1] = { Color3.fromRGB(245, 160, 40), Color3.fromRGB(255, 215, 130), Color3.fromRGB(190, 110, 20) },
	[2] = { Color3.fromRGB(225, 45, 30), Color3.fromRGB(255, 140, 110), Color3.fromRGB(150, 20, 15) },
}
-- How much of a zone's colour the tube's cells keep (the rest is the empty colour).
local TUBE_TINT = 0.45

type Droplet = { frame: Frame, parts: { [string]: { Frame } }, key: string, x: number }

local row: Frame? = nil
local droplets: { Droplet } = {}
local gauge: Frame? = nil
local bulb: { [string]: { Frame } } = {}
local pin: Frame? = nil
local pinArt: { [string]: { Frame } } = {}
local arrows: { right: Frame?, left: Frame? } = {}
local statusRow: Frame? = nil
local clemencyIcon: Frame? = nil
local clemencyText: TextLabel? = nil
local clemencyShadow: TextLabel? = nil
local warmthIcon: Frame? = nil
local chillIcon: Frame? = nil
local readingRow: Frame? = nil
local readingValue: TextLabel? = nil
local readingValueShadow: TextLabel? = nil
local readingTarget: TextLabel? = nil
local readingTargetShadow: TextLabel? = nil
local readingArrow: Frame? = nil
local readingArt: { [string]: { Frame } } = {}
local lastReading = ""
-- The status and reading rows' places as built, and how far up they are moved now (Ui/Hud's
-- `raise`: the mana stars under the held item's name, Ui/ManaHud).
local statusY, readingY = 0, 0
local raised = 0
local edgesGui: ScreenGui? = nil
local edges: { Frame } = {}
local lastZone = math.huge
local lastValue = math.huge
local lastStatus = ""
local lastEdge = ""
local tickCount = 0
local nextTick = 0

-- The state of droplet `i` (1 = rightmost) at `thirst` points: 0 empty, 1 half, 2 full.
function SurvivalHud.dropletState(thirst: number, i: number): number
	return math.clamp(thirst - (i - 1) * 2, 0, 2)
end

-- Does droplet `i` jitter this tick (Minecraft's rule for hunger, see the header)?
function SurvivalHud.jitters(hydration: number, thirst: number, tick: number): boolean
	return hydration <= 0 and tick % (thirst * 3 + 1) == 0
end

-- The left x (gauge pixels) of body temperature `value`'s cell: three pixels a step, and one
-- more for each zone border below it (the ticks).
function SurvivalHud.cellX(value: number): number
	local v = math.clamp(math.round(value), Temperature.MIN, Temperature.MAX)
	local borders = 0
	for zone = Temperature.COLD, Temperature.HOT do
		if v >= Temperature.ZONES[zone][1] then
			borders += 1
		end
	end
	return TUBE_X + (v - Temperature.MIN) * CELL + borders
end

-- A temperature as the reading writes it: "0", "-3", "+5".
function SurvivalHud.signed(value: number): string
	local whole = math.round(value)
	return if whole == 0 then "0" else string.format("%+d", whole)
end

-- "m:ss" of `seconds`.
function SurvivalHud.clock(seconds: number): string
	local whole = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", whole // 60, whole % 60)
end

local function paintDroplet(droplet: Droplet, state: number, sick: boolean)
	local key = `{state}{sick}`
	if droplet.key == key then
		return
	end
	droplet.key = key
	local fill, shine = if sick then SICK else WATER, if sick then SICK_SHINE else WATER_SHINE
	Style.paint(droplet.parts.R, if state >= 1 then fill else EMPTY)
	Style.paint(droplet.parts.L, if state >= 2 then fill else EMPTY)
	Style.paint(droplet.parts.H, if state >= 2 then shine else EMPTY_SHINE)
end

local function newEdge(parent: Instance, anchor: Vector2, position: UDim2, size: UDim2, rotation: number): Frame
	local frame = Instance.new("Frame")
	frame.BorderSizePixel = 0
	frame.AnchorPoint = anchor
	frame.Position = position
	frame.Size = size
	frame.BackgroundTransparency = 1
	frame.Parent = parent
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = rotation
	gradient.Transparency = NumberSequence.new(0, 1)
	gradient.Parent = frame
	return frame
end

-- A transparent frame of `w` x `h` at (x, y) to hold pixel art.
local function holder(parent: Instance, name: string, x: number, y: number, w: number, h: number, z: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundTransparency = 1
	frame.Position = UDim2.fromOffset(x, y)
	frame.Size = UDim2.fromOffset(w, h)
	frame.ZIndex = z
	frame.Parent = parent
	return frame
end

-- The thermometer (see the header) at the top left of `parent`.
local function buildGauge(parent: Frame)
	local tubeEnd = SurvivalHud.cellX(Temperature.MAX) + CELL
	-- The tube's outline (the bulb draws its left end).
	Style.frame(parent, TUBE_X - 1, 2, tubeEnd - TUBE_X + 2, 1, OUTLINE, 2)
	Style.frame(parent, TUBE_X - 1, 6, tubeEnd - TUBE_X + 2, 1, OUTLINE, 2)
	Style.frame(parent, tubeEnd, 3, 1, 3, OUTLINE, 2)
	-- The cells, tinted by zone, and a tick at each zone border.
	for value = Temperature.MIN, Temperature.MAX do
		local colour = ZONE_COLOURS[Temperature.zone(value)][1]
		Style.frame(parent, SurvivalHud.cellX(value), 3, CELL, 3, EMPTY:Lerp(colour, TUBE_TINT), 2)
	end
	for zone = Temperature.COLD, Temperature.HOT do
		Style.frame(parent, SurvivalHud.cellX(Temperature.ZONES[zone][1]) - 1, 1, 1, 7, OUTLINE, 2)
	end
	bulb = Style.pixelArt(parent, 0, 1, BULB, { K = OUTLINE }, 3)

	local marker = holder(parent, "Pin", 0, 0, 5, 9, 4)
	pinArt = Style.pixelArt(marker, 0, 0, PIN, { K = OUTLINE }, 4)
	pin = marker
	local right = holder(parent, "Warming", 0, 2, 3, 5, 4)
	right.Visible = false
	Style.pixelArt(right, 0, 0, RIGHT, { A = WARMING }, 4)
	local left = holder(parent, "Cooling", 0, 2, 3, 5, 4)
	left.Visible = false
	Style.pixelArt(left, 0, 0, LEFT, { A = COOLING }, 4)
	arrows.right, arrows.left = right, left
end

-- Builds the droplets, the gauge and the status row into Ui/Hud's `canvas`, and the edges in a
-- screen of their own.
function SurvivalHud.build(canvas: Frame, layout: Layout)
	local thirstRow = holder(canvas, "Thirst", layout.width - ROW_WIDTH, layout.rowY, ROW_WIDTH, 9, 2)
	thirstRow.Visible = false
	row = thirstRow
	for i = 1, 10 do
		local x = 72 - (i - 1) * 8
		local frame = holder(thirstRow, `Droplet{i}`, x, 0, 9, 9, 1)
		local parts = Style.pixelArt(frame, 0, 0, DROPLET, { K = OUTLINE, L = EMPTY, R = EMPTY, H = EMPTY_SHINE }, 1)
		droplets[i] = { frame = frame, parts = parts, key = "", x = x }
	end

	local gaugeFrame = holder(canvas, "Temperature", layout.width - GAUGE_WIDTH, layout.gaugeY, GAUGE_WIDTH, 9, 2)
	gaugeFrame.Visible = false
	gauge = gaugeFrame
	buildGauge(gaugeFrame)

	local statusFrame = holder(canvas, "SurvivalStatus", layout.width - ROW_WIDTH, layout.statusY, ROW_WIDTH, 9, 2)
	statusRow = statusFrame
	local shield = holder(statusFrame, "Clemency", 0, 1, 7, 7, 2)
	shield.Visible = false
	Style.pixelArt(shield, 0, 0, SHIELD, { K = OUTLINE, G = CLEMENCY, H = CLEMENCY_SHINE }, 2)
	clemencyIcon = shield
	local text, shadow =
		Style.shadowText(statusFrame, "", 0, 1, ROW_WIDTH, 8, TEXT, 2, Enum.TextXAlignment.Right, Style.TEXT_SIZE)
	text.Visible, shadow.Visible = false, false
	clemencyText, clemencyShadow = text, shadow
	local flame = holder(statusFrame, "InternalWarmth", 0, 1, 7, 7, 2)
	flame.Visible = false
	Style.pixelArt(flame, 0, 0, FLAME, {
		R = Color3.fromRGB(235, 88, 32),
		O = Color3.fromRGB(255, 168, 40),
		Y = Color3.fromRGB(255, 236, 130),
	}, 2)
	warmthIcon = flame
	local snowflake = holder(statusFrame, "InternalChill", 0, 1, 7, 7, 2)
	snowflake.Visible = false
	Style.pixelArt(snowflake, 0, 0, SNOWFLAKE, { B = Color3.fromRGB(150, 210, 255), W = TEXT }, 2)
	chillIcon = snowflake

	-- (In the status row's place when that isn't drawn.)
	statusY = layout.statusY
	readingY = if STATUS_ROW then layout.statusY - 10 else layout.statusY
	local readingFrame = holder(canvas, "Thermometer", layout.width - ROW_WIDTH, readingY, ROW_WIDTH, 9, 2)
	readingFrame.Visible = false
	readingRow = readingFrame
	local value, valueShadow =
		Style.shadowText(readingFrame, "", 0, 1, ROW_WIDTH, 8, TEXT, 2, Enum.TextXAlignment.Left, Style.TEXT_SIZE)
	local target, targetShadow =
		Style.shadowText(readingFrame, "", 0, 1, ROW_WIDTH, 8, TEXT, 2, Enum.TextXAlignment.Left, Style.TEXT_SIZE)
	readingValue, readingValueShadow = value, valueShadow
	readingTarget, readingTargetShadow = target, targetShadow
	local arrow = holder(readingFrame, "Trend", 0, 2, 3, 5, 3)
	readingArt = Style.pixelArt(arrow, 0, 0, RIGHT, { A = TEXT }, 3)
	readingArrow = arrow

	local gui = Instance.new("ScreenGui")
	gui.Name = "IceVoxelTemperatureOverlay"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = -1
	gui.Enabled = false
	edges = {
		newEdge(gui, Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(1, EDGE), 90),
		newEdge(gui, Vector2.new(0, 1), UDim2.fromScale(0, 1), UDim2.fromScale(1, EDGE), -90),
		newEdge(gui, Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(EDGE, 1), 0),
		newEdge(gui, Vector2.new(1, 0), UDim2.fromScale(1, 0), UDim2.fromScale(EDGE, 1), 180),
	}
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	edgesGui = gui
end

local function setVisible(object: GuiObject?, visible: boolean)
	if object and object.Visible ~= visible then
		object.Visible = visible
	end
end

local function place(object: GuiObject?, x: number, y: number)
	if object and (object.Position.X.Offset ~= x or object.Position.Y.Offset ~= y) then
		object.Position = UDim2.fromOffset(x, y)
	end
end

-- The frost or heat at the edges (strength 0..1).
local function renderEdges(colour: Color3, strength: number)
	local gui = edgesGui
	if gui == nil then
		return
	end
	local on = strength > 0
	if gui.Enabled ~= on then
		gui.Enabled = on
	end
	if not on then
		return
	end
	local key = `{colour}{math.floor(strength * 50)}`
	if key == lastEdge then
		return
	end
	lastEdge = key
	for _, edge in edges do
		edge.BackgroundColor3 = colour
		edge.BackgroundTransparency = 1 - strength * EDGE_STRENGTH
	end
end

-- The pin, the bulb and the arrow for body temperature `value` going to `target`.
local function renderGauge(value: number, target: number)
	local zone = Temperature.zone(value)
	if zone ~= lastZone then
		lastZone = zone
		local colours = ZONE_COLOURS[zone]
		Style.paint(bulb.F, colours[1])
		Style.paint(bulb.H, colours[2])
		Style.paint(pinArt.P, colours[1])
		Style.paint(pinArt.H, colours[2])
		Style.paint(pinArt.D, colours[3])
	end
	local x = SurvivalHud.cellX(value)
	if value ~= lastValue then
		lastValue = value
		place(pin, x - 1, 0)
		place(arrows.right, x + CELL + 2, 2)
		place(arrows.left, x - CELL - 2, 2)
	end
	setVisible(arrows.right, target > value)
	setVisible(arrows.left, target < value)
end

-- The status row (see the header): Climate Clemency's time left, the effects.
local function renderStatus(clemency: number, warmth: boolean, chill: boolean)
	local key = `{clemency} {warmth} {chill}`
	if key == lastStatus then
		return
	end
	lastStatus = key
	local x = ROW_WIDTH
	local text = if clemency > 0 then SurvivalHud.clock(clemency) else ""
	setVisible(clemencyIcon, clemency > 0)
	setVisible(clemencyText, clemency > 0)
	setVisible(clemencyShadow, clemency > 0)
	if clemency > 0 and clemencyText and clemencyShadow then
		clemencyText.Text, clemencyShadow.Text = text, text
		-- (The shield 2 pixels left of the text, which ends at the row's right.)
		x = math.floor(x - Style.textWidth(text, Style.TEXT_SIZE) - 2) - 7
		place(clemencyIcon, x, 1)
		x -= 2
	end
	setVisible(chillIcon, chill)
	if chill then
		x -= 7
		place(chillIcon, x, 1)
		x -= 2
	end
	setVisible(warmthIcon, warmth)
	if warmth then
		x -= 7
		place(warmthIcon, x, 1)
	end
end

-- Writes `text` in `colour` into a label and its shadow at x.
local function setText(label: TextLabel?, shadow: TextLabel?, text: string, colour: Color3, x: number)
	if not label or not shadow then
		return
	end
	label.Text, shadow.Text = text, text
	label.TextColor3, shadow.TextColor3 = colour, Style.shadowOf(colour)
	label.Position, shadow.Position = UDim2.fromOffset(x, 1), UDim2.fromOffset(x + 1, 2)
end

-- The thermometer's reading (see the header): body temperature `value` going to `target`.
local function renderReading(value: number, target: number)
	local key = `{value} {target}`
	if key == lastReading then
		return
	end
	lastReading = key
	local valueText, targetText = SurvivalHud.signed(value), SurvivalHud.signed(target)
	-- (Right-aligned: the target ends at the row's right, the arrow 2 pixels before it, the
	-- body temperature 2 before the arrow.)
	local x = math.floor(ROW_WIDTH - Style.textWidth(targetText, Style.TEXT_SIZE))
	setText(readingTarget, readingTargetShadow, targetText, ZONE_COLOURS[Temperature.zone(target)][1], x)
	x -= 5
	place(readingArrow, x, 2)
	Style.paint(readingArt.A, if target > value then WARMING elseif target < value then COOLING else TEXT)
	x = math.floor(x - 2 - Style.textWidth(valueText, Style.TEXT_SIZE))
	setText(readingValue, readingValueShadow, valueText, ZONE_COLOURS[Temperature.zone(value)][1], x)
end

--[[
	Draws this frame (Ui/Hud's RenderStepped): `survival` when the hearts show (survival,
	adventure, the HUD in play), `held` the held item (the Thermometer shows its reading), `raise`
	GUI pixels the status and reading rows move up with the held item's name (Ui/ManaHud's stars
	under it; 0 or nil: where they were built).
]]
function SurvivalHud.render(now: number, survival: boolean, held: number?, raise: number?)
	local up = raise or 0
	if up ~= raised then
		raised = up
		local statusFrame, readingFrame = statusRow, readingRow
		if statusFrame then
			statusFrame.Position = UDim2.fromOffset(statusFrame.Position.X.Offset, statusY - up)
		end
		if readingFrame then
			readingFrame.Position = UDim2.fromOffset(readingFrame.Position.X.Offset, readingY - up)
		end
	end
	local status = SurvivalState.get()
	local thirstShown = survival and status ~= nil and status.thirstOn
	local temperatureShown = survival and status ~= nil and status.temperatureOn
	setVisible(row, thirstShown)
	setVisible(gauge, temperatureShown)
	setVisible(statusRow, STATUS_ROW and (thirstShown or temperatureShown))
	setVisible(readingRow, temperatureShown and held == THERMOMETER)
	if status == nil or not temperatureShown then
		renderEdges(FROST, 0)
	end
	if status == nil then
		return
	end
	local ticked = now >= nextTick
	if ticked then
		nextTick = now + TICK
		tickCount += 1
	end

	if thirstShown then
		local sick = status.effect > 0
		for i, droplet in droplets do
			paintDroplet(droplet, SurvivalHud.dropletState(status.thirst, i), sick)
			if ticked then
				local y = if SurvivalHud.jitters(status.hydration, status.thirst, tickCount)
					then math.random(-1, 1)
					else 0
				if droplet.frame.Position.Y.Offset ~= y then
					droplet.frame.Position = UDim2.fromOffset(droplet.x, y)
				end
			end
		end
	end

	if thirstShown or temperatureShown then
		renderStatus(status.clemency, temperatureShown and status.warmth, temperatureShown and status.chill)
	end

	if temperatureShown then
		local value = math.clamp(status.temperature, Temperature.MIN, Temperature.MAX)
		renderGauge(value, status.target)
		if held == THERMOMETER then
			renderReading(value, math.clamp(status.target, Temperature.MIN, Temperature.MAX))
		end
		local frost, heat = status.frozen / Temperature.EXTREME_TICKS, status.heat / Temperature.EXTREME_TICKS
		if frost >= heat then
			renderEdges(FROST, frost)
		else
			renderEdges(HEAT, heat)
		end
	end
end

return SurvivalHud

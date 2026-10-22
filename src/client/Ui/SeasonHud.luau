--!strict
--[[
	The season clock (DayZ-styled): Don't Starve's dial of the year and the day beside the minimap,
	with the season's days left under it, and the seasons' toasts. What it says: Ui/SeasonLine;
	its face: Ui/SeasonClock (both pure and tested); where it goes: Ui/HudLayout's `clock` through
	Ui/UiScale (`setClock`); the calendar: Shared/Seasons/Calendar's state, which
	Rendering/LightingController reads from the server's attributes, at the replicated clock's
	day time (LightingController.dayTime).

	  Dial      HudLayout.CLOCK GUI pixels square (CLOCK_SMALL on tight screens) at the top of the
	            block HudLayout gives, at its right edge: a dark disc (Theme ClockFace), the year
	            ring's 32 ticks in the seasons' colours (Theme.Season; the other seasons' at
	            CLOCK_DIM_T) with a white marker at the year's progress, the day ring's 16
	            segments (ClockDay, ClockDusk, ClockNight: the sun's real split of this day, so
	            winter's long nights show) with the hand at the time of day, and the day number in
	            the centre in the HUD's pixel font. All plain Frames turned with Rotation, sized in
	            scale UDim2s under one UIScale: no images, nothing to upload.
	  Caption   under the dial, right aligned (the Dayz look's small Roboto in capitals, with a text
	            outline): "WINTER · 3 DAYS LEFT", "LAST DAY OF AUTUMN", "HEAT WAVE" (Warn). Its
	            width (SeasonLine.captionWidth, measured with TextService) goes to UiScale, which
	            drops it, then shrinks the dial, where the corner has no room.
	  Updates   every SeasonClock.UPDATE seconds (4 Hz): the hand and the marker turn (written only
	            when they moved), the caption and the day number change with the day; the ticks are
	            recoloured only when the season, the lengths or the day's split change
	            (SeasonClock.signature). Nothing else runs per frame.
	  Toasts    the season's turn at the sunrise of its first day and a heat wave's dawn
	            (SeasonLine.events) through Ui/SurvivorHud's one toast queue with the blood moon's
	            notices, in the season's colour (a heat wave in Warn), each with its stinger
	            (ambient.season.<name>, ambient.season.heat_wave) played as it shows. With
	            Config.Seasons.Clock.Toasts; whatever the player's setting, as the blood moon's.
	  Shown     with Config.Seasons.Enabled and Config.Seasons.Clock.Enabled, the calendar on (the
	            server's: a debug world publishes it off), the player's Season Clock setting
	            (PlayerSettings "seasonClock", read from Settings at each look) and while the HUD
	            shows (the world map hides it). Hidden, it tells UiScale so (`setClock(false)`), so
	            nothing in the corner moves for it: with the seasons off the HUD is as before.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Calendar = require(Shared.Seasons.Calendar)
local Config = require(Shared.Config)

local LightingController = require(script.Parent.Parent.Rendering.LightingController)
local Settings = require(script.Parent.Parent.Settings)
local HudLayout = require(script.Parent.HudLayout)
local SeasonClock = require(script.Parent.SeasonClock)
local SeasonLine = require(script.Parent.SeasonLine)
local Style = require(script.Parent.Style)
local SurvivorHud = require(script.Parent.SurvivorHud)
local Theme = require(script.Parent.Theme)
local UiScale = require(script.Parent.UiScale)

local Dayz = Style.Dayz

local SeasonHud = {}

-- Degrees the hand or the marker must move before it is turned again.
local TURN = 0.1
-- ZIndex of the dial's layers (siblings: ZIndexBehavior.Sibling).
local Z_FACE, Z_TICK, Z_POINTER, Z_TEXT = 1, 2, 3, 4

local started = false

-- The world's seed (the heat waves' hash): published before the client starts (the boot waits for it).
local function worldSeed(): number
	local value = Shared:GetAttribute("Seed")
	return if type(value) == "number" then value else 0
end

-- Does the clock show now (see the header)?
local function clockShown(state: Calendar.State): boolean
	return Config.Seasons.Enabled == true
		and Config.Seasons.Clock.Enabled == true
		and state.enabled
		and Settings.on("seasonClock")
		and UiScale.hudShown()
end

-- A radial bar (SeasonClock.Bar) as a Frame in `parent`, filled with the colour `key`.
local function barFrame(parent: Instance, bar: SeasonClock.Bar, key: string, z: number): Frame
	local frame = Instance.new("Frame")
	frame.BorderSizePixel = 0
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(bar.x, bar.y)
	frame.Size = UDim2.fromScale(bar.w, bar.h)
	frame.Rotation = bar.rotation
	frame.BackgroundColor3 = Dayz.Colour[key]
	frame.BackgroundTransparency = Dayz.Alpha[key]
	frame.ZIndex = z
	frame.Parent = parent
	return frame
end

-- Turns `frame` to `bar` (its place and angle).
local function turn(frame: Frame, bar: SeasonClock.Bar)
	frame.Position = UDim2.fromScale(bar.x, bar.y)
	frame.Rotation = bar.rotation
end

-- Starts the clock and its toasts (the client boot, after the day line).
function SeasonHud.start()
	assert(not started, "SeasonHud.start was already called")
	started = true
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local seed = worldSeed()

	--[[ The block: the dial over its caption (with the minimap's corner: HudLayout's pixels) ]]

	local gui = UiScale.screenGui("IceVoxelSeasonClock", "Map", { inset = true, full = true, kind = "scaled" })
	local block = Instance.new("Frame")
	block.Name = "SeasonClock"
	block.BackgroundTransparency = 1
	block.BorderSizePixel = 0
	block.Size = UDim2.fromOffset(HudLayout.CLOCK, HudLayout.CLOCK)
	block.Visible = false
	Dayz.mark(block)
	local blockScale = Instance.new("UIScale")
	blockScale.Parent = block
	block.Parent = gui
	local scaled = Dayz.scaled()

	local dial = Instance.new("Frame")
	dial.Name = "Dial"
	dial.BackgroundTransparency = 1
	dial.BorderSizePixel = 0
	dial.AnchorPoint = Vector2.new(1, 0)
	dial.Position = UDim2.fromScale(1, 0)
	dial.Size = UDim2.fromOffset(HudLayout.CLOCK, HudLayout.CLOCK)
	dial.Parent = block

	local face = Instance.new("Frame")
	face.Name = "Face"
	face.BorderSizePixel = 0
	face.Size = UDim2.fromScale(1, 1)
	face.BackgroundColor3 = Dayz.Colour.ClockFace
	face.BackgroundTransparency = Dayz.Alpha.ClockFace
	face.ZIndex = Z_FACE
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0.5, 0)
	round.Parent = face
	face.Parent = dial

	local yearTicks: { Frame } = {}
	for i, bar in SeasonClock.yearTicks() do
		yearTicks[i] = barFrame(dial, bar, "SeasonAutumn", Z_TICK)
	end
	local dayTicks: { Frame } = {}
	for j, bar in SeasonClock.dayTicks() do
		dayTicks[j] = barFrame(dial, bar, "ClockDay", Z_TICK)
	end
	local hand = barFrame(dial, SeasonClock.hand(0), "ClockHand", Z_POINTER)
	local marker = barFrame(dial, SeasonClock.marker(0), "ClockMarker", Z_POINTER)

	-- The day number: the pixel font with its shadow, centred in the dial.
	local dayLabel, dayShadow =
		Style.shadowText(dial, "", 0, 0, 0, 0, Dayz.Colour.Text, Z_TEXT, Enum.TextXAlignment.Center)
	for _, label in { dayLabel, dayShadow } do
		label.Size = UDim2.fromScale(1, 1)
		label.TextYAlignment = Enum.TextYAlignment.Center
	end
	dayShadow.Position = UDim2.fromOffset(1, 1)

	-- The caption: the Dayz look's small Roboto in capitals, right aligned under the dial.
	local caption = Instance.new("TextLabel")
	caption.Name = "Caption"
	caption.BackgroundTransparency = 1
	caption.BorderSizePixel = 0
	caption.TextSize = Theme.Text.small
	caption.TextXAlignment = Enum.TextXAlignment.Right
	caption.TextYAlignment = Enum.TextYAlignment.Center
	caption.TextColor3 = Dayz.Colour.Text
	caption.Text = ""
	caption.Visible = false
	Dayz.textStroke(caption, "TextStroke")
	scaled:label(caption, "small")
	caption.Parent = block
	gui.Parent = playerGui

	--[[ Placing ]]

	local showing = false
	-- The caption shown and its width (GUI pixels), the dial's side drawn.
	local shownCaption, captionWidth = "", HudLayout.CLOCK
	local dialSize = 0

	local function place()
		local layout = UiScale.hud()
		local r = layout.clock
		block.Visible = showing and r ~= nil
		if blockScale.Scale ~= layout.scale then
			blockScale.Scale = layout.scale
			scaled:setScale(layout.scale)
		end
		if r == nil then
			return
		end
		local s = layout.scale
		local w = math.floor(r.w / s + 0.5)
		local d = layout.clockDial
		block.Position = UDim2.fromOffset(r.x, r.y)
		block.Size = UDim2.fromOffset(w, math.floor(r.h / s + 0.5))
		if d ~= dialSize then
			dialSize = d
			dial.Size = UDim2.fromOffset(d, d)
			-- (The day number's size depends on the dial: set again at the next look.)
			dayLabel.Text, dayShadow.Text = "", ""
		end
		caption.Visible = layout.clockCaption
		caption.Position = UDim2.fromOffset(0, d)
		caption.Size = UDim2.fromOffset(w, HudLayout.COORDS_HEIGHT)
	end
	UiScale.hudChanged:Connect(place)

	--[[ The face ]]

	local segments: { SeasonClock.Segment } = {}
	local signature = ""
	local captionKey = ""
	local handAngle, markerAngle = math.huge, math.huge
	local position: Calendar.Position? = nil

	-- Colours the ticks for `season` with `lengths` and the day's `segments`.
	local function recolour(season: number, lengths: { number })
		for i, tickSeason in SeasonClock.yearSeasons(lengths) do
			local key = Theme.Season[tickSeason]
			local tick = yearTicks[i]
			tick.BackgroundColor3 = Dayz.Colour[key]
			tick.BackgroundTransparency = if tickSeason == season then Dayz.Alpha[key] else Theme.CLOCK_DIM_T
		end
		for j, segment in segments do
			local key = if segment == "day" then "ClockDay" elseif segment == "dusk" then "ClockDusk" else "ClockNight"
			dayTicks[j].BackgroundColor3 = Dayz.Colour[key]
			dayTicks[j].BackgroundTransparency = Dayz.Alpha[key]
		end
	end

	-- The face at `dayTime` with `state` (see the header).
	local function draw(dayTime: number, state: Calendar.State)
		local at = Calendar.position(dayTime, state, position)
		position = at
		-- The caption (measured again when its text changes; UiScale hears the width).
		local text, key = SeasonLine.caption(at, SeasonLine.heatWaveShown(dayTime, seed, state), state.lock ~= nil)
		if text ~= shownCaption then
			shownCaption = text
			caption.Text = text
			captionWidth = SeasonLine.captionWidth(text, function(value: string): number
				return Style.textWidth(value, Theme.Text.small, Dayz.FONT)
			end)
		end
		if key ~= captionKey then
			captionKey = key
			caption.TextColor3 = Dayz.Colour[key]
		end
		-- The ticks' colours, only when something they show changed.
		SeasonClock.daySegments(dayTime, segments)
		local now = SeasonClock.signature(at.season, state.lengths, segments)
		if now ~= signature then
			signature = now
			recolour(at.season, state.lengths)
		end
		-- The hand and the marker.
		local angle = SeasonClock.handAngle(dayTime)
		if math.abs(angle - handAngle) >= TURN then
			handAngle = angle
			turn(hand, SeasonClock.hand(angle))
		end
		angle = SeasonClock.yearAngle(at)
		if math.abs(angle - markerAngle) >= TURN then
			markerAngle = angle
			turn(marker, SeasonClock.marker(angle))
		end
		-- The day number.
		local number, size = SeasonClock.dayText(dayTime, if dialSize > 0 then dialSize else HudLayout.CLOCK)
		if number ~= dayLabel.Text or size ~= dayLabel.TextSize then
			dayLabel.Text, dayShadow.Text = number, number
			dayLabel.TextSize, dayShadow.TextSize = size, size
		end
	end

	--[[ Every SeasonClock.UPDATE seconds ]]

	local before: number? = nil
	local reported: number? = nil
	local elapsed = SeasonClock.UPDATE
	RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		if elapsed < SeasonClock.UPDATE then
			return
		end
		elapsed = 0
		local dayTime = LightingController.dayTime()
		local state = Calendar.state()
		-- The toasts (whatever the setting).
		if Config.Seasons.Enabled and Config.Seasons.Clock.Toasts then
			for _, event in SeasonLine.events(before, dayTime, seed, state) do
				local key = SeasonLine.colourKey(event)
				SurvivorHud.toast(SeasonLine.toastText(event, state), Dayz.Colour[key], SeasonLine.sound(event))
			end
		end
		before = dayTime
		-- The clock.
		local shown = clockShown(state)
		if shown then
			draw(dayTime, state)
		end
		local width = if shown then captionWidth else nil
		if shown ~= showing or width ~= reported then
			showing, reported = shown, width
			UiScale.setClock(shown, width)
		end
		place()
	end)
end

return SeasonHud

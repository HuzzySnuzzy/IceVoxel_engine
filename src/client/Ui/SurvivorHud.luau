--!strict
--[[
	The zombie apocalypse's day counter and the HUD's one queue of notice toasts: the blood moon's
	and the seasons' (what they say: Ui/SurvivorLine and Ui/SeasonLine, pure and tested; where they
	go: Ui/HudLayout through Ui/UiScale).

	  Day line  "Day 4 · Survived 2 days" in the HUD's pixel font, right aligned in the top right
	            corner (HudLayout's `day`: under the minimap's coordinates line, under the touch
	            Map button with the minimap off, else in the corner itself), at the GUI scale;
	            "Day 4" alone outside survival and adventure. A blood moon's word follows it in
	            red ("Blood Moon", "Blood Moon tonight", "Blood Moon tomorrow"), on the same row
	            where the corner has room, else on a second row under it (HudLayout's `dayRows`:
	            an iPad's or a 1024 x 768 window's corner at its Auto GUI scale). The day comes
	            from the replicated clock (Rendering/LightingController.dayTime), the days survived
	            from Player/SurvivorState. Both widths go to UiScale (`setDayLine`), so the toasts
	            and the effect icons move under it.
	  Toasts    "A Blood Moon rises tonight" at dawn of a blood moon's day, "The Blood Moon rises"
	            as it rises (with ambient.blood_moon.rise), "You survived the Blood Moon" when the
	            server counts the moon this character lived through from its rise (the clock's
	            set and SurvivorState's `moonsRaised` together: SurvivorLine.confirmSet), in the
	            notices' red; and whatever else calls `toast(text, colour, sound)`: the seasons'
	            turns and heat waves (Ui/SeasonHud, in their seasons' colours, each with its
	            stinger played as it shows). One queue for all of them, so they never overlap: a
	            toast 32 GUI pixels high and as wide as its text (SurvivorLine.toastWidth, at least
	            Minecraft's 160) in HudLayout's `notice` slot (under Now Playing and "World saved"
	            when they show) for TOAST_SECONDS, one at a time in the order they came; while the
	            corner has no room for it, it waits (its time counts only while it shows).
	  Shown     with Config.Apocalypse.Enabled, Config.Apocalypse.Survivor.DayCounter and the
	            player's Day Counter setting (PlayerSettings "dayCounter": `setEnabled`), while
	            the HUD shows (the world map hides it). The toasts come whatever the setting.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)

local LightingController = require(script.Parent.Parent.Rendering.LightingController)
local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local SurvivorState = require(script.Parent.Parent.Player.SurvivorState)
local HudLayout = require(script.Parent.HudLayout)
local Style = require(script.Parent.Style)
local SurvivorLine = require(script.Parent.SurvivorLine)
local UiScale = require(script.Parent.UiScale)

local SurvivorHud = {}

-- Seconds between looks at the clock and the record.
local UPDATE = 0.25
-- The toast's height (GUI pixels) and how long it shows.
local TOAST_HEIGHT = 32
local TOAST_SECONDS = 5
-- Minecraft's toast: a dark face with a lighter edge.
local FACE = Color3.fromRGB(33, 33, 38)
local EDGE = Color3.fromRGB(86, 86, 96)

local started = false
local enabled = true

-- A toast waiting or showing: its text, its colour and the sound played as it shows.
type Toast = { text: string, colour: Color3, sound: string? }
local queue: { Toast } = {}
-- Shows the next toast of the queue (set by `start`; nil before).
local advance: (() -> ())? = nil
-- The toast showing (nil: none).
local current: Toast? = nil

local function noticeColour(): Color3
	local rgb = SurvivorLine.NOTICE_COLOUR
	return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

-- The player's Day Counter setting.
function SurvivorHud.setEnabled(value: boolean)
	enabled = value
end

--[[
	Queues a notice toast (see the header): `text` in `colour` (default the notices' red), `sound`
	(a Shared/Sounds event) played when it shows. Toasts queued before `start` show once it ran.
]]
function SurvivorHud.toast(text: string, colour: Color3?, sound: string?)
	table.insert(queue, { text = text, colour = colour or noticeColour(), sound = sound })
	local show = advance
	if show and current == nil then
		show()
	end
end

-- Does the day line show now?
local function lineShown(): boolean
	return enabled and Config.Apocalypse.Enabled and Config.Apocalypse.Survivor.DayCounter and UiScale.hudShown()
end

-- A frame of `w` x `h` GUI pixels under a UIScale, in `parent`.
local function scaled(parent: Instance, name: string, w: number, h: number): (Frame, UIScale)
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromOffset(w, h)
	frame.Visible = false
	local scale = Instance.new("UIScale")
	scale.Parent = frame
	frame.Parent = parent
	return frame, scale
end

-- Puts `label` and its `shadow` at (x, y), `w` wide, with `text`.
local function setLabel(label: TextLabel, shadow: TextLabel, text: string, x: number, y: number, w: number)
	label.Text, shadow.Text = text, text
	label.Position = UDim2.fromOffset(x, y)
	shadow.Position = UDim2.fromOffset(x + 1, y + 1)
	label.Size = UDim2.fromOffset(w, Style.TEXT_SIZE)
	shadow.Size = UDim2.fromOffset(w, Style.TEXT_SIZE)
end

function SurvivorHud.start()
	if started then
		return
	end
	started = true
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	--[[ The day line (with the minimap's corner: the whole screen, HudLayout's pixels) ]]

	local gui = UiScale.screenGui("IceVoxelSurvivor", "Map", { inset = true, full = true, kind = "scaled" })
	local row = HudLayout.COORDS_HEIGHT
	local line, lineScale = scaled(gui, "DayLine", HudLayout.MINIMAP, row)
	local text, textShadow = Style.shadowText(
		line,
		"",
		0,
		1,
		HudLayout.MINIMAP,
		Style.TEXT_SIZE,
		Style.Colour.Text,
		1,
		Enum.TextXAlignment.Right
	)
	local notice, noticeShadow = Style.shadowText(
		line,
		"",
		0,
		1,
		HudLayout.MINIMAP,
		Style.TEXT_SIZE,
		noticeColour(),
		1,
		Enum.TextXAlignment.Right
	)
	gui.Parent = playerGui

	-- The texts shown, their widths on one row and wrapped (GUI pixels), and the rows drawn.
	local shownText, shownNotice = "", ""
	local oneRow, wrapped = HudLayout.MINIMAP, nil :: number?
	local drawnRows = 0
	local showing = false

	-- Lays the labels out on the rows HudLayout gave (one: the notice at the right edge after the
	-- day's text; two: the notice right aligned under it).
	local function arrange(rows: number)
		local w = math.max(HudLayout.MINIMAP, if rows == 2 then wrapped or oneRow else oneRow)
		line.Size = UDim2.fromOffset(w, row * rows)
		if shownNotice == "" then
			setLabel(text, textShadow, shownText, 0, 1, w)
			setLabel(notice, noticeShadow, "", 0, 1, 0)
		elseif rows == 2 then
			setLabel(text, textShadow, shownText, 0, 1, w)
			setLabel(notice, noticeShadow, shownNotice, 0, row + 1, w)
		else
			local word = SurvivorLine.GAP .. shownNotice
			local noticeWidth = Style.textWidth(word)
			setLabel(text, textShadow, shownText, 0, 1, w - noticeWidth)
			setLabel(notice, noticeShadow, word, w - noticeWidth, 1, noticeWidth)
		end
		drawnRows = rows
	end

	local function place()
		local layout = UiScale.hud()
		local day = layout.day
		line.Visible = showing and day ~= nil
		if lineScale.Scale ~= layout.scale then
			lineScale.Scale = layout.scale
		end
		if day then
			line.Position = UDim2.fromOffset(day.x, day.y)
			if layout.dayRows ~= drawnRows then
				arrange(layout.dayRows)
			end
		end
	end
	UiScale.hudChanged:Connect(place)

	-- Sets the line's text (and its notice), measuring it again when it changed.
	local function setText(main: string, word: string?)
		local after = if word then word else ""
		if main == shownText and after == shownNotice then
			return
		end
		shownText, shownNotice = main, after
		oneRow, wrapped = SurvivorLine.widths(main, word, function(s: string): number
			return Style.textWidth(s)
		end)
		-- (Drawn again on the rows HudLayout gives the new widths: `place`.)
		drawnRows = 0
		UiScale.setDayLine(showing, oneRow, wrapped)
	end

	--[[ The toasts ]]

	local toastGui =
		UiScale.screenGui("IceVoxelSurvivorToasts", "Toasts", { inset = true, full = true, kind = "scaled" })
	local toastWidth = SurvivorLine.TOAST_WIDTH
	local toast, toastScale = scaled(toastGui, "Notice", toastWidth, TOAST_HEIGHT)
	local outline = Style.frame(toast, 0, 0, toastWidth, TOAST_HEIGHT, Color3.new(0, 0, 0), 1)
	local edge = Style.frame(toast, 1, 1, toastWidth - 2, TOAST_HEIGHT - 2, EDGE, 2)
	local face = Style.frame(toast, 2, 2, toastWidth - 4, TOAST_HEIGHT - 4, FACE, 3)
	local toastText, toastShadow = Style.shadowText(
		toast,
		"",
		0,
		(TOAST_HEIGHT - Style.TEXT_SIZE) / 2,
		toastWidth,
		Style.TEXT_SIZE,
		noticeColour(),
		5,
		Enum.TextXAlignment.Center
	)
	toastGui.Parent = playerGui

	-- The toast `w` GUI pixels wide (its frames and its text).
	local function sizeToast(w: number)
		toastWidth = w
		toast.Size = UDim2.fromOffset(w, TOAST_HEIGHT)
		outline.Size = UDim2.fromOffset(w, TOAST_HEIGHT)
		edge.Size = UDim2.fromOffset(w - 2, TOAST_HEIGHT - 2)
		face.Size = UDim2.fromOffset(w - 4, TOAST_HEIGHT - 4)
		toastText.Size = UDim2.fromOffset(w, Style.TEXT_SIZE)
		toastShadow.Size = UDim2.fromOffset(w, Style.TEXT_SIZE)
	end

	local left = 0
	-- The showing toast's sound, until it is first on the screen.
	local soundDue: string? = nil

	local function placeToast()
		local layout = UiScale.hud()
		local slot = layout.notice
		toast.Visible = current ~= nil and slot ~= nil and UiScale.hudShown()
		local sound = soundDue
		if sound and toast.Visible then
			soundDue = nil
			SoundPlayer.playFlat(sound)
		end
		if toastScale.Scale ~= layout.scale then
			toastScale.Scale = layout.scale
		end
		if slot then
			toast.Position = UDim2.fromOffset(slot.x, slot.y)
		end
	end
	UiScale.hudChanged:Connect(placeToast)

	local function nextToast()
		current = table.remove(queue, 1)
		local shown = current
		if shown then
			local words = shown.text
			toastText.Text, toastShadow.Text = words, words
			toastText.TextColor3, toastShadow.TextColor3 = shown.colour, Style.shadowOf(shown.colour)
			sizeToast(SurvivorLine.toastWidth(Style.textWidth(words)))
			left = TOAST_SECONDS
			soundDue = shown.sound
			UiScale.setToast("notice", toastWidth)
		else
			soundDue = nil
			UiScale.setToast("notice", nil)
		end
		placeToast()
	end
	advance = nextToast

	local function announce(event: string)
		-- (The rise's boom comes as the moon rises, even while another toast still shows.)
		if event == "rises" then
			SoundPlayer.playFlat("ambient.blood_moon.rise")
		end
		SurvivorHud.toast(SurvivorLine.TOASTS[event], noticeColour())
	end

	-- (Toasts queued before the start.)
	if current == nil and #queue > 0 then
		nextToast()
	end

	-- A survived moon's toast waits for both halves (see the header).
	local pending: SurvivorLine.Pending = {}
	SurvivorState.moonsRaised:Connect(function()
		if Config.Apocalypse.Enabled and SurvivorLine.confirmSet(pending, "raised", os.clock()) then
			announce("sets")
		end
	end)

	--[[ Every UPDATE seconds ]]

	local before: number? = nil
	local elapsed = UPDATE
	RunService.Heartbeat:Connect(function(dt: number)
		-- (A toast's time counts only while it shows.)
		if current and toast.Visible then
			left -= dt
			if left <= 0 then
				nextToast()
			end
		end
		elapsed += dt
		if elapsed < UPDATE then
			return
		end
		elapsed = 0
		local dayTime = LightingController.dayTime()
		local settings = Config.Apocalypse.BloodMoon
		if Config.Apocalypse.Enabled then
			for _, event in SurvivorLine.events(before, dayTime, settings) do
				-- (The set's toast waits for the server's count.)
				local due = event ~= "sets" or SurvivorLine.confirmSet(pending, "sets", os.clock())
				if due then
					announce(event)
				end
			end
		end
		before = dayTime
		local shown = lineShown()
		local survivalLike = GameMode.isSurvivalLike(GameMode.of(Players.LocalPlayer))
		local main, word = SurvivorLine.text(dayTime, SurvivorState.alive(), survivalLike, settings)
		if shown ~= showing then
			showing = shown
			UiScale.setDayLine(shown, oneRow, wrapped)
		end
		setText(main, word)
		place()
		placeToast()
	end)
end

return SurvivorHud

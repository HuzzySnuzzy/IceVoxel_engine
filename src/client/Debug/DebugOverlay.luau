--!strict
--[[
	F3 toggles a small overlay with streaming statistics: chunks per LOD level, jobs in flight,
	builds pending, parts and PointLights in the world, the cave view (how far caves are revealed,
	or "always shown"; the full detail split underground), far mesh status (MeshOverlay), the frame rate, and the
	player's movement hull (position, speed, ground / water / sprint / flying / noclip /
	spectating / pose, game mode, flying speed; MovementController), the dropped items the client
	knows about (EntityRenderer), the time of day (the clock, day number, Minecraft's sky light
	outdoors and how much of it reaches the camera; Rendering/LightingController), the fog showing
	(LightingController.describeFog: the Atmosphere's density, how far it hazes things 90%, its
	haze, glare and offset; or a fluid's or Blindness' Lighting fog, start and end in blocks) and
	the music (surface or cave, the track playing or the seconds to the next; Audio/Music) with the cave
	mood (Audio/Ambience), as Minecraft's "Mood N%", and Tough As Nails' numbers (Player/
	SurvivalState: thirst, hydration, exhaustion, the Thirst effect's seconds, Climate Clemency's
	time left; the body temperature (-10..10) and its target with their zones, hypothermia and
	hyperthermia ticks of Temperature.EXTREME_TICKS, wet, Internal Warmth and Chill), and the
	status effects (Player/EffectState: each one's name, level and time left, "**:**" for one
	that never ends), and the weather at the player (Weather/: what falls there, the
	precipitation, thunder and cloud cover, the wind and the weather clock, a /weather override's
	share; the cloud parts and rings, the rain strips drawn, the bolts showing). Under the frame
	rate, the world: its name, world type, difficulty, seed and whether commands are allowed
	(Shared/WorldSettings.info, from the server's attributes). The panel grows to fit its lines.

	`isOpen()` and `changed` tell other modules whether the overlay is shown: WAILA (Ui/Waila) shows
	its extended view while it is, as Jade does with F3.

	F3 is also Minecraft's debug key (Debug/DebugKeys, pure): the overlay toggles when F3 is let go,
	not pressed, unless a combination ran while it was held: F3 + N (spectator <-> the previous
	game mode: Protocol SetGameMode), F3 + F4 (the game mode switcher, Ui/GameModeSwitcher, which
	then gets F4 itself) and F3 + Q (the list, in the chat). Their "[Debug]:" lines go to the chat
	through Net/Notices. No combination runs while a screen is open or the player types. "F3" is
	the Debug Screen key binding (Settings/Keybinds; F3 by default): rebound, its key does all of
	this and the combinations become that key + N / Q / F4.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")
local UserInputService = game:GetService("UserInputService")

local ChunkStreamer = require(script.Parent.Parent.Streaming.ChunkStreamer)
local ChunkRenderer = require(script.Parent.Parent.Rendering.ChunkRenderer)
local MeshOverlay = require(script.Parent.Parent.Rendering.MeshOverlay)
local MovementController = require(script.Parent.Parent.Player.MovementController)
local SurvivalState = require(script.Parent.Parent.Player.SurvivalState)
local EffectState = require(script.Parent.Parent.Player.EffectState)
local EntityRenderer = require(script.Parent.Parent.Entities.EntityRenderer)
local LightingController = require(script.Parent.Parent.Rendering.LightingController)
local WeatherClient = require(script.Parent.Parent.Weather)
local Ambience = require(script.Parent.Parent.Audio.Ambience)
local Music = require(script.Parent.Parent.Audio.Music)
local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local Notices = require(script.Parent.Parent.Net.Notices)
local GameModeSwitcher = require(script.Parent.Parent.Ui.GameModeSwitcher)
local Screens = require(script.Parent.Parent.Ui.Screens)
local DebugKeys = require(script.Parent.DebugKeys)
local Keybinds = require(script.Parent.Parent.Settings.Keybinds)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local DayCycle = require(Shared.DayCycle)
local Effects = require(Shared.Effects)
local GameMode = require(Shared.GameMode)
local LodTree = require(Shared.World.LodTree)
local Protocol = require(Shared.Net.Protocol)
local Temperature = require(Shared.ToughAsNails.Temperature)
local WorldSettings = require(Shared.WorldSettings)
local WorldTypes = require(Shared.Generation.WorldTypes)

local DebugOverlay = {}

local open = false
local changedEvent = Instance.new("BindableEvent")
-- Fires with `true` when F3 shows the overlay and `false` when it hides it.
DebugOverlay.changed = changedEvent.Event

-- Is the overlay shown (F3)?
function DebugOverlay.isOpen(): boolean
	return open
end

-- The world line: name, world type, difficulty, seed, and "cheats" with Allow Commands on.
local function worldLine(): string
	local info = WorldSettings.info(Shared)
	if info == nil then
		return "world  (none yet)"
	end
	local worldType = WorldTypes.get(info.worldType)
	return `world  "{info.name}"  {if worldType then worldType.name else info.worldType}  `
		.. `{WorldSettings.difficultyName(info.difficulty) or "?"}  seed {WorldSettings.seedText(info.seed)}`
		.. (if info.allowCommands then "  cheats" else "")
end

-- The time of day line: clock, day number, tick in the day, sky light outdoors (0..15) and the
-- share of the sky's light reaching the camera (1 outdoors, 0 deep underground).
local function timeLine(): string
	local now = LightingController.dayTime()
	return string.format(
		"time    %s  day %d  tick %d  sky %d  exposure %.2f",
		DayCycle.clockString(now),
		DayCycle.day(now),
		DayCycle.timeInDay(now),
		DayCycle.skyLight(now),
		LightingController.skyExposure()
	)
end

-- The music (where the player is for it, what plays or how long until the next) and the mood.
local function musicLine(): string
	local place, title, wait = Music.status()
	local seconds = math.floor(wait)
	local playing = if title then `"{title}"` else string.format("next in %d:%02d", seconds // 60, seconds % 60)
	return string.format("music   %s  %s  mood %d%%", place, playing, math.floor(Ambience.mood() * 100))
end

-- Tough As Nails: thirst and body temperature, as the server last sent them.
local function survivalLine(): string
	local status = SurvivalState.get()
	if status == nil then
		return "survival -"
	end
	local thirst = if status.thirstOn
		then string.format(
			"thirst %d  hydration %.1f  exhaustion %.2f  effect %ds",
			status.thirst,
			status.hydration,
			status.exhaustion,
			math.ceil(status.effect / 20)
		)
		else "thirst off"
	local clemency = if status.clemency > 0
		then string.format("  clemency %d:%02d", status.clemency // 60, status.clemency % 60)
		else ""
	local temperature = if status.temperatureOn
		then string.format(
			"temp %d %s -> %d %s  frozen %d/%d  heat %d/%d%s%s%s",
			status.temperature,
			Temperature.name(status.temperature),
			status.target,
			Temperature.name(status.target),
			status.frozen,
			Temperature.EXTREME_TICKS,
			status.heat,
			Temperature.EXTREME_TICKS,
			if status.wet then "  wet" else "",
			if status.warmth then "  warmth" else "",
			if status.chill then "  chill" else ""
		)
		else "temp off"
	return `survival {thirst}{clemency}\n        {temperature}`
end

-- The status effects, as the server last sent them (counted down since).
local function effectsLine(): string
	local list = EffectState.list()
	if #list == 0 then
		return "effects -"
	end
	local parts = table.create(#list)
	for i, entry in list do
		parts[i] = `{Effects.levelName(entry.effect, entry.amplifier)} {Effects.formatTicks(entry.ticks)}`
	end
	return `effects {table.concat(parts, ", ")}`
end

-- Movement hull line (blocks; speeds in blocks per second).
local function movementLine(): string
	local view = MovementController.current
	if view == nil then
		return "player  -"
	end
	local s = view.state
	local flags: { string } = {}
	local function flag(on: boolean, name: string)
		if on then
			table.insert(flags, name)
		end
	end
	flag(s.onGround, "ground")
	flag(s.inWater, "water")
	flag(s.inLava, "lava")
	flag(s.sprinting, "sprint")
	flag(s.sneaking, "sneak")
	flag(s.flying, "flying")
	flag(s.noClip, "noclip")
	flag(view.frozen, "waiting")
	flag(MovementController.spectating() ~= nil, "spectating")
	local speed = math.sqrt(s.vx * s.vx + s.vz * s.vz) * 20
	return string.format(
		"player  %.2f %.2f %.2f  %.2f m/s  vy %.3f  %s %s\n        %s, flying speed %.3f, %d items nearby",
		s.x,
		s.y,
		s.z,
		speed,
		s.vy,
		s.pose,
		table.concat(flags, " "),
		GameMode.of(Players.LocalPlayer),
		s.flyingSpeed,
		EntityRenderer.count()
	)
end

local function meshLine(stats: MeshOverlay.Stats): string
	return string.format(
		"meshes  %s\n        %d/%d regions, %d/%d chunks, %d parts%s, %dk tris\n        %d built, %d failed, last %.0f ms, frames +%.0f ms, tiny mesh +%.0f ms",
		stats.status,
		stats.meshedRegions,
		stats.regions,
		stats.meshedNodes,
		stats.nodes,
		stats.meshParts,
		-- (Far Materials: MeshParts in a material or texture, not plain.)
		if stats.looks then ` ({stats.lookParts} with materials)` else "",
		stats.triangles // 1000,
		stats.builds,
		stats.failures,
		stats.lastBuildMs,
		stats.slowestFrameMs,
		-- (The startup probe's one-block mesh: does a tiny MeshPart cost a long frame too?)
		stats.tinyFrameMs
	)
end

-- Parts, pooled parts and PointLights (glow lichen's and lava's: how many are on, near the camera).
local function partsLine(renderer: ChunkRenderer.ChunkRenderer): string
	local lights = renderer.lightCount - renderer.sparseCount + renderer.sparseOn
	local lichenOn, lichen = renderer.sparseOn - renderer.lavaOn, renderer.sparseCount - renderer.lavaCount
	return `parts   {renderer.partCount}  pooled {renderer.pool.freeCount}  lights {lights} (lichen {lichenOn} of {lichen}, lava {renderer.lavaOn} of {renderer.lavaCount})`
end

-- The cave view: how far caves are revealed and whether full detail reaches further.
local function caveLine(stats: ChunkStreamer.Stats): string
	if stats.alwaysCaves then
		return `caves   always shown  full detail split {LodTree.splitDistanceL1(stats.underground)}`
	end
	if stats.revealRadius <= 0 and not stats.underground then
		return "caves   hidden"
	end
	local reveal = if stats.revealRadius > 0 then `revealed to {stats.revealRadius}` else "hidden"
	return `caves   {reveal}  full detail split {LodTree.splitDistanceL1(stats.underground)}`
end

function DebugOverlay.start(streamer: ChunkStreamer.ChunkStreamer)
	local gui = Instance.new("ScreenGui")
	gui.Name = "IceVoxelDebug"
	gui.ResetOnSpawn = false
	gui.Enabled = false

	local label = Instance.new("TextLabel")
	label.Position = UDim2.fromOffset(10, 10)
	label.Size = UDim2.fromOffset(420, 280)
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.BackgroundTransparency = 0.5
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.Code
	label.TextSize = 14
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Parent = gui
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 6)
	padding.PaddingTop = UDim.new(0, 6)
	padding.PaddingRight = UDim.new(0, 6)
	padding.PaddingBottom = UDim.new(0, 6)
	padding.Parent = label

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	--[[ Debug keys ]]

	local player = Players.LocalPlayer
	local keys = DebugKeys.new()

	-- Typing into a text box or Roblox's chat bar?
	local function typing(): boolean
		if UserInputService:GetFocusedTextBox() ~= nil then
			return true
		end
		local bar = TextChatService:FindFirstChildOfClass("ChatInputBarConfiguration")
		return bar ~= nil and bar.IsFocused
	end

	local function context(): DebugKeys.Context
		return {
			screenOpen = Screens.isOpen() or GameModeSwitcher.isOpen() or typing(),
			mode = GameMode.of(player),
			previous = GameMode.previousOf(player),
			mayChange = GameMode.mayChangeOwn(player),
		}
	end

	local function perform(action: DebugKeys.Action?)
		if action == nil then
			return
		end
		if action.kind == "toggle" then
			open = not open
			gui.Enabled = open
			changedEvent:Fire(open)
		elseif action.kind == "setMode" then
			local mode = action.mode
			if mode and GameMode.mayChangeOwn(player) then
				ClientNet.send(Protocol.ClientMessage.SetGameMode, Protocol.encodeSetGameMode(mode))
			end
		elseif action.kind == "switcher" then
			GameModeSwitcher.open()
		elseif action.kind == "chat" then
			if action.feedback then
				Notices.debug(DebugKeys.PREFIX, action.feedback)
			end
			local lines = action.lines
			if lines then
				for _, line in lines do
					Notices.show(line)
				end
			end
		end
	end

	--[[
		DebugKeys knows the debug key as "F3": the Debug Screen key binding (Settings/Keybinds, F3
		by default; a mouse button too) reads as "F3", and F3 itself, rebound away, as nothing.
		The combinations' second keys (N, Q, F4) stay fixed.
	]]
	local function keyName(input: InputObject): string?
		if Keybinds.matches("debug", input) then
			return "F3"
		elseif input.UserInputType ~= Enum.UserInputType.Keyboard or input.KeyCode == Enum.KeyCode.F3 then
			return nil
		end
		return input.KeyCode.Name
	end
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		-- The open switcher takes F4 itself (GameModeSwitcherScreen.keyPressed).
		if input.KeyCode == Enum.KeyCode.F4 and GameModeSwitcher.isOpen() then
			GameModeSwitcher.next()
			return
		end
		local name = keyName(input)
		if name then
			perform((DebugKeys.press(keys, name, context())))
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		local name = keyName(input)
		if name then
			perform(DebugKeys.release(keys, name, context()))
		end
	end)
	-- (Key releases are missed while the window has no focus.)
	UserInputService.WindowFocusReleased:Connect(function()
		DebugKeys.reset(keys)
	end)

	local frames, elapsed, fps = 0, 0, 0
	RunService.RenderStepped:Connect(function(dt)
		frames += 1
		elapsed += dt
		if elapsed < 0.5 then
			return
		end
		fps = frames / elapsed
		frames, elapsed = 0, 0
		if not gui.Enabled then
			return
		end

		local stats = streamer:stats()
		local levels = {}
		for level = 0, 15 do
			local n = stats.nodes[level]
			if n then
				table.insert(levels, `L{level}:{n}`)
			end
		end
		label.Text = table.concat({
			string.format("IceVoxel  %.0f fps", fps),
			worldLine(),
			`chunks  {table.concat(levels, " ")}`,
			`waiting {stats.waiting}  queued {stats.queued}  working {stats.working}`,
			`workers busy {stats.busyWorkers}  builds pending {stats.building}`,
			partsLine(streamer.renderer),
			caveLine(stats),
			meshLine(streamer.renderer.overlay:getStats()),
			movementLine(),
			timeLine(),
			LightingController.describeFog(),
			WeatherClient.describe(),
			musicLine(),
			survivalLine(),
			effectsLine(),
		}, "\n")
	end)
end

return DebugOverlay

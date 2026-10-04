--!strict
--[[
	F3 toggles a small overlay with streaming statistics: chunks per LOD level, jobs in flight,
	builds pending, parts in the world, far mesh status (MeshOverlay), the frame rate, and the
	player's movement hull (position, speed, ground / water / sprint / flying / pose, game mode;
	MovementController), the dropped items the client knows about (EntityRenderer) and the time
	of day (the clock, day number, Minecraft's sky light outdoors and how much of it reaches the
	camera; Rendering/LightingController).

	`isOpen()` and `changed` tell other modules whether the overlay is shown: WAILA (Ui/Waila) shows
	its extended view while it is, as Jade does with F3.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local ChunkStreamer = require(script.Parent.Parent.Streaming.ChunkStreamer)
local MeshOverlay = require(script.Parent.Parent.Rendering.MeshOverlay)
local MovementController = require(script.Parent.Parent.Player.MovementController)
local EntityRenderer = require(script.Parent.Parent.Entities.EntityRenderer)
local LightingController = require(script.Parent.Parent.Rendering.LightingController)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local DayCycle = require(Shared.DayCycle)
local GameMode = require(Shared.GameMode)

local DebugOverlay = {}

local open = false
local changedEvent = Instance.new("BindableEvent")
-- Fires with `true` when F3 shows the overlay and `false` when it hides it.
DebugOverlay.changed = changedEvent.Event

-- Is the overlay shown (F3)?
function DebugOverlay.isOpen(): boolean
	return open
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
	flag(s.sprinting, "sprint")
	flag(s.sneaking, "sneak")
	flag(s.flying, "flying")
	flag(view.frozen, "waiting")
	local speed = math.sqrt(s.vx * s.vx + s.vz * s.vz) * 20
	return string.format(
		"player  %.2f %.2f %.2f  %.2f m/s  vy %.3f  %s %s\n        %s, %d items nearby",
		s.x,
		s.y,
		s.z,
		speed,
		s.vy,
		s.pose,
		table.concat(flags, " "),
		GameMode.of(Players.LocalPlayer),
		EntityRenderer.count()
	)
end

local function meshLine(stats: MeshOverlay.Stats): string
	return string.format(
		"meshes  %s\n        %d/%d regions, %d/%d chunks, %d parts, %dk tris\n        %d built, %d failed, last %.0f ms, frames +%.0f ms",
		stats.status,
		stats.meshedRegions,
		stats.regions,
		stats.meshedNodes,
		stats.nodes,
		stats.meshParts,
		stats.triangles // 1000,
		stats.builds,
		stats.failures,
		stats.lastBuildMs,
		stats.slowestFrameMs
	)
end

function DebugOverlay.start(streamer: ChunkStreamer.ChunkStreamer)
	local gui = Instance.new("ScreenGui")
	gui.Name = "IceVoxelDebug"
	gui.ResetOnSpawn = false
	gui.Enabled = false

	local label = Instance.new("TextLabel")
	label.Position = UDim2.fromOffset(10, 10)
	label.Size = UDim2.fromOffset(380, 226)
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
	padding.Parent = label

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.F3 then
			open = not open
			gui.Enabled = open
			changedEvent:Fire(open)
		end
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
			`chunks  {table.concat(levels, " ")}`,
			`waiting {stats.waiting}  queued {stats.queued}  working {stats.working}`,
			`workers busy {stats.busyWorkers}  builds pending {stats.building}`,
			`parts   {streamer.renderer.partCount}  pooled {streamer.renderer.pool.freeCount}`,
			meshLine(streamer.renderer.overlay:getStats()),
			movementLine(),
			timeLine(),
		}, "\n")
	end)
end

return DebugOverlay

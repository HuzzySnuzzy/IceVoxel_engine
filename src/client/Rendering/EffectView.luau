--!strict
--[[
	What status effects do to this player's view (Minecraft's GameRenderer, LightTexture and
	FogRenderer), from Player/EffectState, every frame after the camera moved:

	  Night Vision  lights the world: LightingController.setNightVision raises the ambients (caves,
	                nights) by Effects.nightVisionScale (full, flickering in the last 10 s), and the
	                view brightens a little (a ColorCorrectionEffect, "IceVoxelEffectView").
	  Blindness     the fog closes in to 5 blocks, black (ViewSettings.setEffectFog, LightingController
	                .setEffectFogColour: Effects.blindnessFog, opening up over its last second),
	                and the view darkens; it keeps sprints from starting (Player/MovementController).
	  Nausea        the camera rolls and the field of view sways (Minecraft's spinning distortion,
	                which a Roblox camera can't do): Effects.nauseaIntensity builds up over about
	                8 s once it has more than 3 s left and fades over 5 s after, and Effects.
	                nauseaSway gives the wobble, at most Config.Effects.NauseaRoll degrees and
	                NauseaFov of the field of view, times the Distortion Effects setting squared
	                (Minecraft's screenEffectScale: `setDistortion`, PlayerSettings.distortion; 0
	                keeps the view still). A faint purple tint goes with it either way.
	Glowing is the server's (a Highlight on the character, Players/Effects). Writes happen only when
	something changed, so a frame with no effects costs a few comparisons.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Effects = require(Shared.Effects)

local EffectState = require(script.Parent.Parent.Player.EffectState)
local MovementController = require(script.Parent.Parent.Player.MovementController)
local LightingController = require(script.Parent.LightingController)
local ViewSettings = require(script.Parent.ViewSettings)

local EffectView = {}

local BLOCK = Config.BlockSize
local TICKS_PER_SECOND = Effects.TICKS_PER_SECOND
-- The view's brightening at full Night Vision, and its darkening at full Blindness.
local NIGHT_BRIGHTNESS = 0.06
local BLIND_BRIGHTNESS = -0.3
local BLIND_SATURATION = -0.6
-- Nausea's tint at full intensity.
local NAUSEA_TINT = Color3.fromRGB(232, 214, 255)
local BLACK = Color3.new(0, 0, 0)
local WHITE = Color3.new(1, 1, 1)

local NIGHT_VISION = Effects.id.NightVision
local BLINDNESS = Effects.id.Blindness
local NAUSEA = Effects.id.Nausea

local started = false
-- The Distortion Effects setting's share of the Nausea wobble (0..1, already squared).
local distortion = 1

-- The Distortion Effects setting (PlayerSettings.distortion: the slider's share squared).
function EffectView.setDistortion(share: number)
	distortion = math.clamp(share, 0, 1)
end

function EffectView.start()
	if started then
		return
	end
	started = true
	local correction = Instance.new("ColorCorrectionEffect")
	correction.Name = "IceVoxelEffectView"
	correction.Enabled = false
	correction.Parent = Lighting

	local nausea = 0
	local lastNight = 0
	-- The blindness fog last set (blocks; 0: none).
	local lastFog = 0
	-- The colour correction last written (hundredths of night, blindness and nausea).
	local lastNightShade, lastBlindShade, lastSickShade = -1, -1, -1
	RunService:BindToRenderStep("IceVoxelEffectView", Enum.RenderPriority.Camera.Value + 3, function(dt: number)
		local now = os.clock()
		local _, nightTicks = EffectState.get(NIGHT_VISION)
		local hasNight = EffectState.levels()[NIGHT_VISION] ~= nil
		local night = if hasNight then Effects.nightVisionScale(nightTicks) else 0
		if night ~= lastNight then
			lastNight = night
			LightingController.setNightVision(night)
		end

		local _, blindTicks = EffectState.get(BLINDNESS)
		local blind = EffectState.levels()[BLINDNESS] ~= nil
		local fog = 0
		if blind then
			local _, finish = Effects.blindnessFog(blindTicks, (ViewSettings.lod()))
			fog = math.floor(finish * 10 + 0.5) / 10
		end
		if fog ~= lastFog then
			if fog > 0 then
				ViewSettings.setEffectFog(fog * 0.25 * BLOCK, fog * BLOCK)
				if lastFog == 0 then
					LightingController.setEffectFogColour(BLACK)
				end
			else
				ViewSettings.setEffectFog(nil, nil)
				LightingController.setEffectFogColour(nil)
			end
			lastFog = fog
		end
		local blindness = if blind
			then (if blindTicks == Effects.INFINITE then 1 else math.min(1, blindTicks / TICKS_PER_SECOND))
			else 0

		local _, nauseaTicks = EffectState.get(NAUSEA)
		local left = if EffectState.levels()[NAUSEA] ~= nil then nauseaTicks else 0
		nausea = Effects.nauseaIntensity(nausea, left, dt * TICKS_PER_SECOND)
		local roll, sway = Effects.nauseaSway(nausea * distortion, now)
		MovementController.setFovSway(1 + sway * Config.Effects.NauseaFov)
		local camera = workspace.CurrentCamera
		if roll ~= 0 and camera then
			camera.CFrame *= CFrame.Angles(0, 0, math.rad(roll * Config.Effects.NauseaRoll))
		end

		-- The view's colour: brighter with Night Vision, darker and greyer blind, tinted sick.
		local nightShade = math.floor(night * 100 + 0.5)
		local blindShade = math.floor(blindness * 100 + 0.5)
		local sickShade = math.floor(nausea * 100 + 0.5)
		if nightShade ~= lastNightShade or blindShade ~= lastBlindShade or sickShade ~= lastSickShade then
			lastNightShade, lastBlindShade, lastSickShade = nightShade, blindShade, sickShade
			local on = night > 0 or blindness > 0 or nausea > 0
			correction.Enabled = on
			if on then
				correction.Brightness = night * NIGHT_BRIGHTNESS + blindness * BLIND_BRIGHTNESS
				correction.Saturation = blindness * BLIND_SATURATION
				correction.TintColor = WHITE:Lerp(NAUSEA_TINT, nausea)
			end
		end
	end)
end

return EffectView

--!strict
--[[
	Picks the view distance for this device and sets up lighting for long views.

	  * Phones and tablets (touch screen, no keyboard) use Config.Lod.Mobile: they draw parts much
	    less far than computers anyway, and have less memory. That includes a shorter distance
	    for plants (LodTree.setFoliageDistance), whose every box is a part, and a shorter cave view
	    (Lod.Mobile.UndergroundSplitDistanceL1, Config.Caves.Mobile's reveal radii).
	  * Lighting.PrioritizeLightingQuality = false: when the engine has to lower quality it keeps the
	    draw distance and gives up lighting detail first.
	  * Fog fades the edge of the view distance (skipped when the place has an Atmosphere, which
	    replaces fog). Its distance is set here; its colour follows the time of day
	    (Rendering/LightingController, while `usesFog` says this fog is in use).

	How far parts are really drawn is decided by the engine from the graphics quality level and how
	many objects are visible; scripts can not raise it. Studio ignores that limit, so check long
	views in the Roblox player.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local LodTree = require(Shared.World.LodTree)

local ViewSettings = {}

function ViewSettings.isMobile(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

-- Is IceVoxel's distance fog in use (Config.Render.Fog, and no Atmosphere replacing it)?
function ViewSettings.usesFog(): boolean
	return Config.Render.Fog and Lighting:FindFirstChildOfClass("Atmosphere") == nil
end

-- How far caves are revealed around an underground camera on this device (blocks): in tunnels
-- and at most, in big caverns (Streaming/CaveReach).
function ViewSettings.revealRadii(): (number, number)
	local caves = if ViewSettings.isMobile() then Config.Caves.Mobile else Config.Caves
	return caves.RevealRadius, math.max(caves.RevealRadius, caves.RevealRadiusMax)
end

-- How far from the camera glow lichen's lights are on, on this device (blocks).
function ViewSettings.lichenLightDistance(): number
	return (if ViewSettings.isMobile() then Config.Caves.Mobile else Config.Caves).LichenLightDistance
end

function ViewSettings.apply()
	if ViewSettings.isMobile() then
		local mobile = Config.Lod.Mobile
		LodTree.configure(mobile.ViewDistance, mobile.SplitDistance, nil, mobile.UndergroundSplitDistanceL1)
		LodTree.setFoliageDistance(mobile.FoliageDistance)
	end

	local ok, err = pcall(function()
		Lighting.PrioritizeLightingQuality = false
	end)
	if not ok then
		warn(`[IceVoxel] could not set Lighting.PrioritizeLightingQuality: {err}`)
	end

	if ViewSettings.usesFog() then
		Lighting.FogEnd = LodTree.viewDistance() * Config.BlockSize
		Lighting.FogStart = Lighting.FogEnd * 0.55
	end
end

return ViewSettings

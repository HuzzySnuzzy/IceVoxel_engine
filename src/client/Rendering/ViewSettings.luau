--!strict
--[[
	Picks the view distance for this device and sets up lighting for long views.

	  * Phones and tablets (touch screen, no keyboard) use Config.Lod.Mobile: they draw parts much
	    less far than computers anyway, and have less memory. That includes a shorter distance
	    for plants (LodTree.setFoliageDistance), whose every box is a part.
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

function ViewSettings.apply()
	if ViewSettings.isMobile() then
		LodTree.configure(Config.Lod.Mobile.ViewDistance, Config.Lod.Mobile.SplitDistance)
		LodTree.setFoliageDistance(Config.Lod.Mobile.FoliageDistance)
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

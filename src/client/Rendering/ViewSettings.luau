--!strict
--[[
	The view this device uses: distances, caves, plants, lights, fog and lighting quality, from the
	player's settings (Shared/PlayerSettings values, bound by the client's Settings controller,
	`bind`). Unbound (before that, and in tests) the lights, caves and fog come from Config as
	before, read live, and the distances from the device's default preset.

	  * Phones and tablets (touch screen, no keyboard) start on the Low preset (Config.Lod.Mobile's
	    view and caves: they draw parts much less far than computers anyway, and have less memory);
	    other devices by Roblox's graphics quality (PlayerSettings.defaultPreset).
	  * `applyLod`: LodTree's four distances (always all four, with the balance rule:
	    PlayerSettings.lod), how far plants are drawn, and Config.Render.Foliage (off with the
	    plants setting at 0; Config's own false always wins). The streamer re-selects at its next
	    refresh.
	  * `applyLighting`: Lighting.PrioritizeLightingQuality (the "Prefer: Distance" setting: when
	    the engine has to lower quality it keeps the draw distance and gives up lighting detail
	    first), and Config.Lighting.CaveAmbient from the brightness slider (0% is Config's own,
	    captured when this module loads; Rendering/LightingController reads it every update).
	  * `applyFog`: fog fades the edge of the view distance, FogEnd = view x BlockSize and FogStart
	    55% of that (skipped when the place has an Atmosphere, which replaces fog); with the fog
	    setting off the place's own FogEnd / FogStart come back. Its colour follows the time of day
	    (Rendering/LightingController, while `usesFog` says this fog is in use). While the camera
	    is in a fluid, its fog wins over both (`setFluidFog`, Rendering/FluidFog).
	  * Getters for the streamer and renderer, read live: `revealReach` / `revealRadii` (caves),
	    `lichenLightDistance`, `lavaLightDistance` (Config only), `foliageDistance`, `lod`, `get`.

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
local PlayerSettings = require(Shared.PlayerSettings)

local ViewSettings = {}

-- Config's own values the settings start from (its Foliage = false always wins; brightness 0% is
-- its CaveAmbient).
local CONFIG_FOLIAGE = Config.Render.Foliage
local CONFIG_CAVE_AMBIENT = table.clone(Config.Lighting.CaveAmbient)

-- The settings in use (the Settings controller's table, `bind`), else the device's defaults.
local values: PlayerSettings.Values? = nil
local fallback: PlayerSettings.Values? = nil
-- The place's own fog, captured before IceVoxel first sets it.
local placeFog: { finish: number, start: number }? = nil
-- The fog of the fluid the camera is in (studs; Rendering/FluidFog), nil while it is in none.
local fluidFog: { finish: number, start: number }? = nil

function ViewSettings.isMobile(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

-- Uses `settings` (changed in place by the Settings controller) from now on.
function ViewSettings.bind(settings: PlayerSettings.Values)
	values = settings
end

local function current(): PlayerSettings.Values
	local bound = values
	if bound then
		return bound
	end
	local defaults = fallback
	if defaults == nil then
		defaults = PlayerSettings.defaults(ViewSettings.isMobile())
		fallback = defaults
	end
	return defaults :: PlayerSettings.Values
end

-- A setting's value (PlayerSettings key).
function ViewSettings.get(key: string): number
	return current()[key]
end

-- Does the place have an Atmosphere (which replaces IceVoxel's fog)?
function ViewSettings.hasAtmosphere(): boolean
	return Lighting:FindFirstChildOfClass("Atmosphere") ~= nil
end

-- Is IceVoxel's distance fog in use (the fog setting, Config.Render.Fog, and no Atmosphere)?
function ViewSettings.usesFog(): boolean
	local bound = values
	return Config.Render.Fog and (bound == nil or PlayerSettings.on(bound, "fog")) and not ViewSettings.hasAtmosphere()
end

-- Config's caves for this device (unbound: Caves, or Caves.Mobile on phones).
local function configCaves(): any
	return if ViewSettings.isMobile() then Config.Caves.Mobile else Config.Caves
end

-- LodTree's view distance (blocks), split distance, full detail's and full detail's underground.
function ViewSettings.lod(): (number, number, number, number)
	return PlayerSettings.lod(current())
end

-- How far plants are drawn (blocks; 0: none).
function ViewSettings.foliageDistance(): number
	if not CONFIG_FOLIAGE then
		return 0
	end
	return PlayerSettings.foliageDistance(current())
end

-- How far caves are revealed around an underground camera (blocks).
function ViewSettings.revealReach(): number
	return PlayerSettings.revealReach(current())
end

-- How far caves are revealed around an underground camera on this device (blocks): in tunnels
-- and at most, in big caverns (Streaming/CaveReach).
function ViewSettings.revealRadii(): (number, number)
	local bound = values
	if bound == nil then
		local caves = configCaves()
		return caves.RevealRadius, math.max(caves.RevealRadius, caves.RevealRadiusMax)
	end
	return PlayerSettings.revealRadii(bound)
end

-- How far from the camera glow lichen's lights are on (blocks; math.huge: all).
function ViewSettings.lichenLightDistance(): number
	local bound = values
	if bound == nil then
		return configCaves().LichenLightDistance
	end
	return PlayerSettings.lichenLightDistance(bound)
end

-- How far from the camera lava's lights are on (blocks): Config.Caves.LavaLightDistance, or its
-- Mobile value on phones (no player setting yet).
function ViewSettings.lavaLightDistance(): number
	return configCaves().LavaLightDistance or Config.Caves.LavaLightDistance or math.huge
end

-- LodTree's distances and plants from the settings (the streamer selects again at its next refresh).
function ViewSettings.applyLod()
	local view, split, splitL1, underground = ViewSettings.lod()
	LodTree.configure(view, split, splitL1, underground)
	local foliage = ViewSettings.foliageDistance()
	LodTree.setFoliageDistance(foliage)
	Config.Render.Foliage = CONFIG_FOLIAGE and foliage > 0
end

-- Lighting quality and the cave brightness from the settings.
function ViewSettings.applyLighting()
	local settings = current()
	local ok, err = pcall(function()
		Lighting.PrioritizeLightingQuality = not PlayerSettings.on(settings, "preferDistance")
	end)
	if not ok then
		warn(`[IceVoxel] could not set Lighting.PrioritizeLightingQuality: {err}`)
	end
	Config.Lighting.CaveAmbient = PlayerSettings.caveAmbient(settings, CONFIG_CAVE_AMBIENT)
end

-- The fog for the view distance, or the place's own with the fog setting off; a fluid's while the
-- camera is in one.
function ViewSettings.applyFog()
	if ViewSettings.hasAtmosphere() then
		return
	end
	if placeFog == nil then
		placeFog = { finish = Lighting.FogEnd, start = Lighting.FogStart }
	end
	local fluid = fluidFog
	if fluid then
		Lighting.FogEnd = fluid.finish
		Lighting.FogStart = fluid.start
	elseif ViewSettings.usesFog() then
		local view = ViewSettings.lod()
		Lighting.FogEnd = view * Config.BlockSize
		Lighting.FogStart = Lighting.FogEnd * 0.55
	else
		local own = placeFog :: { finish: number, start: number }
		Lighting.FogEnd = own.finish
		Lighting.FogStart = own.start
	end
end

--[[
	The fog of the fluid the camera is in, `start` to `finish` studs (Rendering/FluidFog), or with
	nil the normal fog again; applied at once.
]]
function ViewSettings.setFluidFog(start: number?, finish: number?)
	fluidFog = if start and finish then { start = start, finish = finish } else nil
	ViewSettings.applyFog()
end

-- Everything above, at start (before the streamer is created).
function ViewSettings.apply()
	ViewSettings.applyLod()
	ViewSettings.applyLighting()
	ViewSettings.applyFog()
end

return ViewSettings

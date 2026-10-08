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
	  * `applyFog`: which fog shows (Rendering/AtmosphereModel.fog). Normally the Atmosphere in
	    Lighting (`atmosphere`: the place's first, else the one Rendering/LightingController makes),
	    whose haze LightingController works out from the view distance, the weather's fog factor
	    (`setWeatherFog`: nearer in rain, snow and thunder), the time of day, the sky exposure and
	    the Fog setting (`usesFog`). While the camera is in a fluid, the fluid's short fog wins
	    (`setFluidFog`, Rendering/FluidFog), and a status effect's (Blindness: `setEffectFog`,
	    Rendering/EffectView) over the fluid's when nearer: those are the old Lighting fog
	    (FogStart / FogEnd, their colour LightingController's), which Roblox ignores while an
	    Atmosphere is in Lighting, so the Atmosphere is taken out (Parent nil) in the same call
	    that writes them and put back when they end, with the place's own FogStart / FogEnd.
	    Without an Atmosphere at all (Config.Lighting.Enabled false in a place that has none of its
	    own: default.project.json's, marked with the PROJECT_ATTRIBUTE, is IceVoxel's and taken out
	    then) the old view fog stays: FogEnd = view x BlockSize x the weather's factor, FogStart
	    55% of it, or the place's own with the Fog setting off.
	  * Getters for the streamer and renderer, read live: `revealReach` / `revealRadii` (caves),
	    `alwaysCaves` (the Caves setting), `lichenLightDistance`, `lavaLightDistance` (Config
	    only), `foliageDistance`, `lod`, `get`.

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

local AtmosphereModel = require(script.Parent.AtmosphereModel)

local ViewSettings = {}

-- The attribute (true) default.project.json marks its Atmosphere with: IceVoxel's, not the place's.
ViewSettings.PROJECT_ATTRIBUTE = "IceVoxel"

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
-- A status effect's fog (studs; Blindness), nil while there is none.
local effectFog: { finish: number, start: number }? = nil
-- The weather's fog factor (Weather/WeatherSky.fog: 1 in clear weather, nearer in rain).
local weatherFog = 1
-- The Atmosphere the view uses (nil: none yet), whether it is in Lighting, and the fog showing.
local atmosphere: Atmosphere? = nil
local attached = true
local mode: AtmosphereModel.Mode = "none"

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

--[[
	The Atmosphere the view uses: the one `setAtmosphere` gave, else the place's first in Lighting
	(adopted the first time it is found); nil while there is none. With Config.Lighting.Enabled
	false IceVoxel drives none, so the project's own (PROJECT_ATTRIBUTE) is taken out of Lighting
	instead: its fixed daytime haze would neither follow the view nor the Fog setting, where the
	old view fog does.
]]
function ViewSettings.atmosphere(): Atmosphere?
	local current = atmosphere
	if current == nil then
		current = Lighting:FindFirstChildOfClass("Atmosphere")
		while
			current
			and not Config.Lighting.Enabled
			and current:GetAttribute(ViewSettings.PROJECT_ATTRIBUTE) == true
		do
			current.Parent = nil
			current = Lighting:FindFirstChildOfClass("Atmosphere")
		end
		if current then
			atmosphere = current
			attached = true
		end
	end
	return current
end

-- Uses `created` (in Lighting) as the view's Atmosphere from now on (Rendering/LightingController
-- makes one when the place has none); the fog is applied again at once.
function ViewSettings.setAtmosphere(created: Atmosphere)
	atmosphere = created
	attached = true
	ViewSettings.applyFog()
end

--[[
	Does the place keep its own Atmosphere (Config.Lighting.Enabled false with one in Lighting that
	is not the project's)? Then only the place decides the haze and the Fog setting changes nothing.
]]
function ViewSettings.placeKeepsFog(): boolean
	return not Config.Lighting.Enabled and ViewSettings.atmosphere() ~= nil
end

-- Is the view's haze on (the Fog setting, or Config.Render.Fog while unbound; Config's false
-- always wins)?
function ViewSettings.usesFog(): boolean
	local bound = values
	return Config.Render.Fog and (bound == nil or PlayerSettings.on(bound, "fog"))
end

-- The fog showing now (AtmosphereModel.Mode), as the last `applyFog` chose it.
function ViewSettings.fogMode(): AtmosphereModel.Mode
	return mode
end

-- The weather's fog factor now (1 in clear weather).
function ViewSettings.weatherFog(): number
	return weatherFog
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

-- Are caves always shown (the Caves setting: "Always Shown"; unbound Config.Caves.AlwaysShow)?
function ViewSettings.alwaysCaves(): boolean
	return PlayerSettings.alwaysCaves(current())
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

--[[
	The fog that shows (see the header): the Atmosphere, a fluid's or a status effect's short fog
	(the old Lighting fog, with the Atmosphere out of Lighting), or without an Atmosphere the old
	view fog (the place's own with the Fog setting off). The old fog's distances are written
	before the Atmosphere goes out or comes back, in the same call.
]]
function ViewSettings.applyFog()
	if placeFog == nil then
		placeFog = { finish = Lighting.FogEnd, start = Lighting.FogStart }
	end
	local handle = ViewSettings.atmosphere()
	local view = ViewSettings.lod()
	local shown: AtmosphereModel.Mode, start: number?, finish: number? = AtmosphereModel.fog(
		effectFog,
		fluidFog,
		handle ~= nil,
		ViewSettings.usesFog(),
		view * Config.BlockSize,
		weatherFog
	)
	mode = shown
	if start == nil or finish == nil then
		local own = placeFog :: { finish: number, start: number }
		start, finish = own.start, own.finish
	end
	Lighting.FogEnd = finish
	Lighting.FogStart = start
	local inLighting = AtmosphereModel.attached(shown)
	if handle and inLighting ~= attached then
		attached = inLighting
		handle.Parent = if inLighting then Lighting else nil
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

--[[
	A status effect's fog, `start` to `finish` studs (Blindness, Rendering/EffectView), or with nil
	none; applied at once.
]]
function ViewSettings.setEffectFog(start: number?, finish: number?)
	effectFog = if start and finish then { start = start, finish = finish } else nil
	ViewSettings.applyFog()
end

--[[
	The weather's fog factor (Weather/WeatherSky.fog: 1 clear, down to Config.Weather.Fog's in
	rain, snow and thunder): the Atmosphere's density follows at LightingController's next update;
	the old view fog (without an Atmosphere) is applied again at once when it changed.
]]
function ViewSettings.setWeatherFog(factor: number)
	factor = math.clamp(factor, 0.05, 1)
	if math.abs(factor - weatherFog) < 0.005 then
		return
	end
	weatherFog = factor
	if mode == "classic" then
		ViewSettings.applyFog()
	end
end

-- Everything above, at start (before the streamer is created).
function ViewSettings.apply()
	ViewSettings.applyLod()
	ViewSettings.applyLighting()
	ViewSettings.applyFog()
end

return ViewSettings

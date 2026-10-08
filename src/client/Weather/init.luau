--!strict
--[[
	The weather on this client: what the player sees and hears of Shared/Weather's storms.

	  WeatherState       the server's weather state, this frame's moment and the weather over the
	                     camera (smoothed), the column biomes, the wind
	  PrecipitationView  rain and snow in the block columns around the camera, stopping at roofs
	                     (Minecraft's renderSnowAndRain), and the rain's sound (tickRain)
	  CloudView          clouds out to the view distance in rings of detail (CloudLod), white,
	                     grey or towering dark by the weather under them, drifting with its wind,
	                     rain shafts under distant rain
	  LightningView      lightning: the server's strikes and the distant storms' flashes, the
	                     bolt (far ones as wide, bright beams), the clouds lit over it, the sky's
	                     flash, the crack and the thunder (later, lower and muffled with distance)
	  StormView          the distant storms (DistantStorms): every thunderstorm in reach flashes
	                     and rumbles, the same on every client with nothing sent, and rain falling
	                     nearby is heard as a muffled hiss
	  (Rendering/LightingController darkens the light by the weather: Weather/WeatherSky)
	  (Map/WeatherLayer  the minimap's and the world map's weather mode and forecasts)

	This module starts them and keeps the rest of the picture in step at 10 Hz: a
	ColorCorrectionEffect ("IceVoxelWeatherView" in Lighting) greys and cools the picture in rain
	and thunder (WeatherSky.grading, by the sky exposure), and the haze thickens (WeatherSky.fog
	through Rendering/ViewSettings.setWeatherFog: the Atmosphere's density for a view that much
	nearer, Rendering/AtmosphereModel). The Clouds and Weather settings reach CloudView and
	PrecipitationView through `setClouds` and `setWeather`.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)
local Weather = require(Shared.Weather)

local SoundPlayer = require(script.Parent.Audio.SoundPlayer)
local ClientWorld = require(script.Parent.World.ClientWorld)
local LightingController = require(script.Parent.Rendering.LightingController)
local ViewSettings = require(script.Parent.Rendering.ViewSettings)
local CloudView = require(script.CloudView)
local LightningView = require(script.LightningView)
local PrecipitationView = require(script.PrecipitationView)
local StormView = require(script.StormView)
local WeatherSky = require(script.WeatherSky)
local WeatherState = require(script.WeatherState)

local INTERVAL = 0.1

local WeatherClient = {}

WeatherClient.State = WeatherState

local written = { saturation = 0, contrast = 0, tint = 1 }

local function grade(effect: ColorCorrectionEffect)
	local exposure = LightingController.skyExposure()
	local saturation, contrast, tint = WeatherSky.grading(WeatherState.rain, WeatherState.storm, exposure)
	if
		math.abs(saturation - written.saturation) > 0.004
		or math.abs(contrast - written.contrast) > 0.004
		or math.abs(tint[1] - written.tint) > 0.004
	then
		written.saturation, written.contrast, written.tint = saturation, contrast, tint[1]
		effect.Saturation = saturation
		effect.Contrast = contrast
		effect.TintColor = Color3.new(tint[1], tint[2], tint[3])
		effect.Enabled = saturation < 0 or contrast < 0
	end
	local snow = WeatherState.form == Weather.SNOW
	ViewSettings.setWeatherFog(WeatherSky.fog(WeatherState.rain, WeatherState.storm, snow, exposure))
end

-- The Clouds setting (Off 0, Fast 1, Fancy 2).
function WeatherClient.setClouds(mode: number)
	CloudView.setMode(mode)
end

-- The Weather setting: rain and snow (Off 0, Fast 1, Fancy 2).
function WeatherClient.setWeather(mode: number)
	PrecipitationView.setMode(mode)
end

--[[
	F3's weather lines (see Weather/WeatherState.describe), and what draws it: cloud parts, rings
	and parts still to place or remove, rain and snow strips shown of the setting's, near bolts
	showing; the distant storms' flashes a minute expected in reach and shown in the last minute,
	distant flashes showing, distant sounds playing and the distant rain's volume.
]]
function WeatherClient.describe(): string
	local parts, rings, waiting = CloudView.stats()
	local shown, columns = PrecipitationView.stats()
	local near, far = LightningView.count()
	local perMinute, lastMinute, hiss = StormView.stats()
	return string.format(
		"%s\n        clouds %d parts %d rings (%d to do)  strips %d/%d  bolts %d"
			.. "\n        distant %.1f/min (%d last min)  flashes %d  thunder %d  rain %.2f",
		WeatherState.describe(),
		parts,
		rings,
		waiting,
		shown,
		columns,
		near,
		perMinute,
		lastMinute,
		far,
		SoundPlayer.distantPlaying(),
		hiss
	)
end

--[[
	Starts the weather for world `seed`: `generator` for biomes and ground heights, `world` for the
	roofs over the rain, `viewDistance()` how far clouds and distant lightning reach (blocks).
]]
function WeatherClient.start(
	seed: number,
	generator: TerrainGenerator.Generator,
	world: ClientWorld.ClientWorld,
	viewDistance: () -> number
)
	WeatherState.start(seed, generator)
	PrecipitationView.start(world)
	CloudView.start(seed, viewDistance)
	LightningView.start(viewDistance)
	StormView.start(seed, viewDistance)
	local effect = Instance.new("ColorCorrectionEffect")
	effect.Name = "IceVoxelWeatherView"
	effect.Enabled = false
	effect.Parent = Lighting
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		if elapsed >= INTERVAL then
			elapsed = 0
			grade(effect)
		end
	end)
end

return WeatherClient

--!strict
--[[
	What the weather does to the day's light, pure (Rendering/LightingController applies it;
	tests/spec/WeatherVisuals checks it). Minecraft darkens the sky by rain and thunder, 5/16 each
	(Shared/Weather.dimming: down to 0.47 in a full thunderstorm), greys the sky, clouds and fog
	(ClientLevel.getSkyColor, FogRenderer.setupColor) and brings nothing else; here the same
	numbers move Roblox's Lighting, scaled by how much sky reaches the camera (`exposure`, Rendering/
	SkyExposure: none of it in a cave).

	  `apply`     DayCycle.environment's values for the weather at the camera: what the sky gives
	              (OutdoorAmbient, the sun's Brightness, the sky box's diffuse and specular light)
	              times the dimming; the sun's warm ColorShift_Top and its Brightness also by
	              Config.Weather.Sky.CoverSun of the cloud cover (an overcast sky hides the sun
	              before it rains); the fog's colour Weather.fogColour (darker, bluer: the
	              Atmosphere's Color); the Atmosphere's Haze up by Sky.Haze x rain (and
	              ThunderHaze x thunder), so the horizon greys over, and its Glare gone with the
	              sun behind rain clouds. Ambient (the caves' light) is never touched.
	  `grading`   a ColorCorrectionEffect for the rest of the picture, since Roblox's sky box can't
	              be greyed by a property (the haze only reaches up from the horizon): saturation
	              down by Sky.Saturation x rain (and thunder), contrast slightly down (flat,
	              overcast light), a cool tint; all 0 indoors.
	  `fog`       the fog's distance factor (Weather.fogFactor: 0.6 at full rain, 0.4 in snow,
	              0.45 in thunder), back to 1 with no sky exposure: the Atmosphere's density
	              for a view that factor to Config.Lighting.Atmosphere.WeatherPower shorter
	              (Rendering/AtmosphereModel), the old view fog's FogEnd that much nearer.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local DayCycle = require(Shared.DayCycle)
local Weather = require(Shared.Weather)

local WeatherSky = {}

local function scale(colour: { number }, factor: number): { number }
	return { colour[1] * factor, colour[2] * factor, colour[3] * factor }
end

local function sky()
	return Config.Weather.Sky
end

--[[
	`environment` (DayCycle.environment's, changed in place and returned) under rain `rain`,
	thunder `thunder` and cloud cover `cover` (0..1 each) with `exposure` (0..1) of the sky
	reaching the camera.
]]
function WeatherSky.apply(
	environment: DayCycle.Environment,
	rain: number,
	thunder: number,
	cover: number,
	exposure: number
): DayCycle.Environment
	local reach = math.clamp(exposure, 0, 1)
	if reach <= 0 or (rain <= 0 and thunder <= 0 and cover <= 0) then
		return environment
	end
	-- (1 where the weather does nothing, `dimming` in full view of the sky.)
	local dim = 1 - (1 - Weather.dimming(rain, thunder)) * reach
	local sun = dim * (1 - sky().CoverSun * math.clamp(cover, 0, 1) * reach)
	environment.outdoorAmbient = scale(environment.outdoorAmbient, dim)
	environment.brightness *= sun
	environment.colorShiftTop = scale(environment.colorShiftTop, sun)
	environment.environmentDiffuse *= dim
	environment.environmentSpecular *= sun
	local fog = Weather.fogColour(environment.fogColor, rain * reach, thunder * reach)
	environment.fogColor = fog
	local settings = sky()
	local wet = math.clamp(rain, 0, 1) * reach
	environment.haze += settings.Haze * wet + settings.ThunderHaze * math.clamp(thunder, 0, 1) * reach
	environment.glare *= sun * (1 - wet)
	return environment
end

--[[
	The colour grading for the weather: saturation (-1..0), contrast and the tint's { r, g, b }
	(0..1 each, white = none).
]]
function WeatherSky.grading(rain: number, thunder: number, exposure: number): (number, number, { number })
	local settings = sky()
	local reach = math.clamp(exposure, 0, 1)
	local r, t = math.clamp(rain, 0, 1) * reach, math.clamp(thunder, 0, 1) * reach
	local saturation = -(settings.Saturation * r + settings.ThunderSaturation * t)
	local contrast = -settings.Contrast * math.max(r, t)
	local tint = settings.Tint
	local amount = math.max(r, t)
	return saturation,
		contrast,
		{
			1 + (tint[1] / 255 - 1) * amount,
			1 + (tint[2] / 255 - 1) * amount,
			1 + (tint[3] / 255 - 1) * amount,
		}
end

-- The fog distance factor with the weather at the camera (1: no change).
function WeatherSky.fog(precipitation: number, thunder: number, snow: boolean, exposure: number): number
	local reach = math.clamp(exposure, 0, 1)
	local factor = Weather.fogFactor(precipitation, thunder, snow)
	return 1 + (factor - 1) * reach
end

return WeatherSky

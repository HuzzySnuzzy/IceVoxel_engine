--!strict
--[[
	The wind's sound, pure (Weather/StormView plays it as a looped weather.wind bed through
	Audio/SoundPlayer; tests/spec/DistantStorms checks it). Minecraft has no wind; this follows what
	the weather model already knows:

	  volume   Config.Weather.Wind.Volume x (Calm + PerSpeed x the wind's speed (blocks a second,
	           Shared/Weather's prevailing wind and its swings, 0 while doWeatherCycle is off) +
	           Storm x the storm at the camera (its precipitation, thunder counting double, at most
	           1) + Altitude.Gain over Altitude.From..To blocks above sea level), at most Max; then
	           times the sky reaching the camera (Rendering/SkyExposure: none in a cave) and, under
	           a roof, Roofed (`roof`: 0 in the open .. 1 under one, smoothed by the caller).
	  muffle   the equalizer (dB: low, mid, high): flat in the open, towards RoofMuffle under a
	           roof.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

local WindSound = {}

local function clamp(value: number, low: number, high: number): number
	return math.clamp(value, low, high)
end

--[[
	The wind's cue volume (see the header) for a wind of `speed` blocks a second, `rain` and
	`thunder` (0..1) at the camera, the camera `height` blocks above sea level, `exposure` (0..1)
	of the sky reaching it and `roof` (0..1).
]]
function WindSound.volume(
	speed: number,
	rain: number,
	thunder: number,
	height: number,
	exposure: number,
	roof: number
): number
	local wind = Config.Weather.Wind
	if not wind.Enabled then
		return 0
	end
	local altitude = wind.Altitude
	local span = math.max(altitude.To - altitude.From, 1)
	local high = clamp((height - altitude.From) / span, 0, 1)
	local storm = clamp(math.max(rain, 0) + 2 * math.max(thunder, 0), 0, 1)
	local level = wind.Calm + wind.PerSpeed * math.max(speed, 0) + wind.Storm * storm + altitude.Gain * high
	local roofed = 1 - (1 - wind.Roofed) * clamp(roof, 0, 1)
	return wind.Volume * math.min(level, wind.Max) * clamp(exposure, 0, 1) * roofed
end

-- The wind's equalizer gains (dB: low, mid, high) for `roof` (0 in the open .. 1 under one).
function WindSound.muffle(roof: number): (number, number, number)
	local under = Config.Weather.Wind.RoofMuffle
	local t = clamp(roof, 0, 1)
	return under.Low * t, under.Mid * t, under.High * t
end

return WindSound

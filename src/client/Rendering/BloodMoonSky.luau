--!strict
--[[
	The blood moon's red sky (the zombie apocalypse's horde nights; the schedule is
	Shared/Apocalypse/BloodMoon, a function of the replicated day time, so it needs no message).
	Rendering/LightingController calls it on every lighting update, right after the weather
	(Weather/WeatherSky.apply). `s` is Config.Apocalypse.BloodMoon.

	  Strength   `intensity(dayTime)`: BloodMoon.intensity (0 by day and on other nights, rising
	             over Ramp ticks after Start to 1, falling over Ramp before End), 0 with
	             Config.Apocalypse.Enabled or BloodMoon.Enabled false. LightingController passes
	             it times the sky exposure (Rendering/SkyExposure: caves keep their own light, as
	             the weather's darkening does).
	  Light      `apply(environment, amount)` tints DayCycle.environment's ambient, outdoor
	             ambient, sky colour shift and the Atmosphere's haze colours (its Color, the
	             environment's fogColor, and its Decay) toward Tint ({170, 28, 28}) by amount x
	             TintStrength (0.55): pure, the tests check it.
	  Grading    its own ColorCorrectionEffect ("IceVoxelBloodMoon" in Lighting, made and owned
	             here): TintColor toward Tint by intensity x TintStrength x the sky exposure,
	             disabled at 0. Roblox composes it with the weather's, the effects' and the
	             fluids' corrections, so nothing else changes for it.
	  The moon   the Sky's MoonAngularSize grows by (MoonSize - 1) x intensity (1.6 x at full):
	             the place's own size is taken as the base the first time, and given back at 0.
	Off (Config.Lighting.Enabled false: the place keeps its own lighting) nothing here is called.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local BloodMoon = require(Shared.Apocalypse.BloodMoon)
local Config = require(Shared.Config)
local DayCycle = require(Shared.DayCycle)

-- What the sky reads of Config.Apocalypse.BloodMoon.
export type Settings = BloodMoon.Settings & {
	Tint: { number },
	TintStrength: number,
	MoonSize: number,
}

local BloodMoonSky = {}

-- The ColorCorrectionEffect this module owns.
BloodMoonSky.CORRECTION = "IceVoxelBloodMoon"

local correction: ColorCorrectionEffect? = nil
local moonBase: number? = nil
-- What was last written (to write only changes): the correction's strength in thousandths and
-- the moon's size in hundredths.
local shownTint = -1
local shownMoon = -1

local function settings(): Settings
	return Config.Apocalypse.BloodMoon
end

-- The blood moon's strength at `dayTime` (0..1; 0 when the apocalypse or the moon is off).
function BloodMoonSky.intensity(dayTime: number, s: Settings?): number
	if not Config.Apocalypse.Enabled then
		return 0
	end
	return BloodMoon.intensity(dayTime, s or settings())
end

-- `rgb` moved toward `tint` by `share` (0..1).
local function toward(rgb: { number }, tint: { number }, share: number): { number }
	return {
		rgb[1] + (tint[1] - rgb[1]) * share,
		rgb[2] + (tint[2] - rgb[2]) * share,
		rgb[3] + (tint[3] - rgb[3]) * share,
	}
end

--[[
	`environment` (DayCycle.environment's, changed in place and returned) tinted by a blood moon of
	strength `amount` (0..1; see the header).
]]
function BloodMoonSky.apply(environment: DayCycle.Environment, amount: number, s: Settings?): DayCycle.Environment
	local current = s or settings()
	local share = math.clamp(amount, 0, 1) * current.TintStrength
	if share <= 0 then
		return environment
	end
	local tint = current.Tint
	environment.ambient = toward(environment.ambient, tint, share)
	environment.outdoorAmbient = toward(environment.outdoorAmbient, tint, share)
	environment.colorShiftTop = toward(environment.colorShiftTop, tint, share)
	environment.fogColor = toward(environment.fogColor, tint, share)
	environment.decay = toward(environment.decay, tint, share)
	return environment
end

-- The colour grading's TintColor (0..255 each) for a moon of `intensity` seen with `exposure`.
function BloodMoonSky.tintColour(intensity: number, exposure: number, s: Settings?): { number }
	local current = s or settings()
	local share = math.clamp(intensity, 0, 1) * math.clamp(exposure, 0, 1) * current.TintStrength
	return toward({ 255, 255, 255 }, current.Tint, share)
end

-- The moon's angular size for a moon of `intensity` over the place's own `base` size.
function BloodMoonSky.moonSize(base: number, intensity: number, s: Settings?): number
	local current = s or settings()
	return base * (1 + (current.MoonSize - 1) * math.clamp(intensity, 0, 1))
end

--[[
	Writes the grading and the moon for a blood moon of `intensity` seen with `exposure` (the
	glue: LightingController's update). Only what changed is written.
]]
function BloodMoonSky.update(intensity: number, exposure: number)
	local strength = math.floor(math.clamp(intensity, 0, 1) * math.clamp(exposure, 0, 1) * 1000 + 0.5)
	if strength ~= shownTint then
		shownTint = strength
		local effect = correction
		if effect == nil and strength > 0 then
			local made = Instance.new("ColorCorrectionEffect")
			made.Name = BloodMoonSky.CORRECTION
			made.Enabled = false
			made.Parent = Lighting
			correction = made
			effect = made
		end
		if effect then
			local rgb = BloodMoonSky.tintColour(intensity, exposure)
			effect.TintColor = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
			effect.Enabled = strength > 0
		end
	end
	local sky = Lighting:FindFirstChildOfClass("Sky")
	if sky then
		local base = moonBase
		if base == nil then
			base = sky.MoonAngularSize
			moonBase = base
		end
		local size = math.floor(BloodMoonSky.moonSize(base :: number, intensity) * 100 + 0.5)
		if size ~= shownMoon then
			shownMoon = size
			sky.MoonAngularSize = size / 100
		end
	end
end

return BloodMoonSky

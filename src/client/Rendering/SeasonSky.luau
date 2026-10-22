--!strict
--[[
	The seasons' mood in the sky: a subtle cool winter and a warm autumn over the lighting, never a
	tint of the foliage (Shared/Seasons/Foliage and Rendering/SeasonTint recolour the leaves and
	grass themselves: a lighting tint would colour snow, stone and players too). Rendering/
	LightingController calls it on every lighting update, right after the blood moon
	(Rendering/BloodMoonSky), with the calendar's state (Shared/Seasons/Calendar).

	  Mood       `mood(dayTime, heatWave)`: per season (MOODS: Autumn, Winter, Spring, Summer) a
	             shift added to the sun's colour (Lighting.ColorShift_Top: winter cool, autumn
	             warm) and to the outdoor ambient, and a colour grading's brightness (winter +0.05:
	             the snow's glare), saturation and tint, each blended at the turns with
	             Calendar.value's smoothstep (Config.Seasons.BlendDays), so nothing steps. A heat
	             wave (`heatWave`: SeasonClimate's 0..1 at the world's seed) adds HEAT_WAVE's
	             warm, washed-out glare. All of it is the daylight's: it fades with
	             DayCycle.daylight of the sun's height (as DayCycle.environment blends night to
	             day), whole by day and none at night, so a winter night is no brighter or bluer
	             than any other. With the calendar off it is neutral: nothing changes.
	  Light      `apply(environment, mood, exposure)` adds the shifts to DayCycle.environment's
	             colour shift and outdoor ambient as far as the sky reaches the camera
	             (`exposure`, Rendering/SkyExposure: caves keep their own light): pure, the tests
	             check it.
	  Grading    its own ColorCorrectionEffect ("IceVoxelSeason" in Lighting, made and owned here,
	             only once the mood is not neutral): `correction(mood, exposure)` is its
	             brightness, saturation and tint (pure); `update` writes them when they changed
	             (thousandths), disabled while neutral. Roblox composes it with the blood moon's,
	             the weather's, the effects' and the fluids' corrections.
	Off (Config.Lighting.Enabled false: the place keeps its own lighting) nothing here is called.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Calendar = require(Shared.Seasons.Calendar)
local DayCycle = require(Shared.DayCycle)
local SeasonClimate = require(Shared.Seasons.SeasonClimate)

export type Mood = {
	-- Added to the sun's colour shift and to the outdoor ambient (0..255 channels).
	shift: { number },
	ambient: { number },
	-- The grading's brightness and saturation (added), and its tint (0..255, white is none).
	brightness: number,
	saturation: number,
	tint: { number },
}

local SeasonSky = {}

-- The ColorCorrectionEffect this module owns.
SeasonSky.CORRECTION = "IceVoxelSeason"

-- Per season (Autumn, Winter, Spring, Summer): see the header.
SeasonSky.MOODS = table.freeze({
	Shift = table.freeze({ { 26, 10, 0 }, { 4, 12, 30 }, { 4, 10, 2 }, { 12, 8, 0 } }),
	Ambient = table.freeze({ { 8, 3, 0 }, { 4, 8, 16 }, { 0, 4, 0 }, { 6, 4, 0 } }),
	Brightness = table.freeze({ 0, 0.05, 0, 0.02 }),
	Saturation = table.freeze({ 0.06, -0.08, 0.04, 0.02 }),
	Tint = table.freeze({ { 255, 246, 232 }, { 238, 245, 255 }, { 248, 255, 246 }, { 255, 250, 238 } }),
})
-- What a full heat wave adds: a little glare, a washed-out warmth.
SeasonSky.HEAT_WAVE = table.freeze({ brightness = 0.03, saturation = -0.05, tint = table.freeze({ 255, 236, 208 }) })

-- Per channel, per season (the shape Calendar.value takes), built once from MOODS.
local function channels(colours: { { number } }, channel: number): { number }
	return { colours[1][channel], colours[2][channel], colours[3][channel], colours[4][channel] }
end
local SHIFT =
	{ channels(SeasonSky.MOODS.Shift, 1), channels(SeasonSky.MOODS.Shift, 2), channels(SeasonSky.MOODS.Shift, 3) }
local AMBIENT =
	{ channels(SeasonSky.MOODS.Ambient, 1), channels(SeasonSky.MOODS.Ambient, 2), channels(SeasonSky.MOODS.Ambient, 3) }
local TINT = { channels(SeasonSky.MOODS.Tint, 1), channels(SeasonSky.MOODS.Tint, 2), channels(SeasonSky.MOODS.Tint, 3) }

local correction: ColorCorrectionEffect? = nil
-- What was last written (thousandths), to write only changes.
local shown = { brightness = math.huge, saturation = math.huge, r = -1, g = -1, b = -1, on = false }

-- A neutral mood (written into `into` when given).
function SeasonSky.neutral(into: Mood?): Mood
	local mood: Mood = into or { shift = { 0, 0, 0 }, ambient = { 0, 0, 0 }, brightness = 0, saturation = 0, tint = {} }
	for i = 1, 3 do
		mood.shift[i] = 0
		mood.ambient[i] = 0
		mood.tint[i] = 255
	end
	mood.brightness, mood.saturation = 0, 0
	return mood
end

-- Is `mood` neutral (nothing to change)?
function SeasonSky.isNeutral(mood: Mood): boolean
	for i = 1, 3 do
		if mood.shift[i] ~= 0 or mood.ambient[i] ~= 0 or mood.tint[i] ~= 255 then
			return false
		end
	end
	return mood.brightness == 0 and mood.saturation == 0
end

--[[
	0..1: the heat wave at `dayTime` in a world of `seed` (SeasonClimate's, as the climate takes
	it: the calendar's day, which stands while the calendar is held, and the real time of day); 0
	with the calendar off.
]]
function SeasonSky.heatWave(dayTime: number, seed: number, s: Calendar.State?): number
	local state = s or Calendar.state()
	if not state.enabled then
		return 0
	end
	local ticks = dayTime - math.floor(dayTime / Calendar.TICKS_PER_DAY) * Calendar.TICKS_PER_DAY
	return SeasonClimate.heatWave(Calendar.day(dayTime, state) + ticks / Calendar.TICKS_PER_DAY, seed, state)
end

--[[
	The season's mood at `dayTime` with a heat wave of `heatWave` (0..1), `s` defaulting to the
	calendar's state (see the header), written into `into` when given. `sunHeight` (-1..1) is the
	height of the sun its daylight follows; it defaults to Minecraft's with `s`'s warp (the client
	passes the sun Roblox draws, as to DayCycle.environment).
]]
function SeasonSky.mood(dayTime: number, heatWave: number, s: Calendar.State?, into: Mood?, sunHeight: number?): Mood
	local state = s or Calendar.state()
	local mood = SeasonSky.neutral(into)
	if not state.enabled then
		return mood
	end
	local height = sunHeight or math.cos(DayCycle.celestialAngle(Calendar.solarTime(dayTime, state)) * 2 * math.pi)
	local daylight = DayCycle.daylight(math.clamp(height, -1, 1))
	if daylight <= 0 then
		return mood
	end
	local time = Calendar.time(dayTime, state)
	local moods = SeasonSky.MOODS
	local wave = math.clamp(heatWave, 0, 1)
	local heat = SeasonSky.HEAT_WAVE
	for i = 1, 3 do
		mood.shift[i] = Calendar.valueAt(SHIFT[i], time, state) * daylight
		mood.ambient[i] = Calendar.valueAt(AMBIENT[i], time, state) * daylight
		local tint = Calendar.valueAt(TINT[i], time, state)
		tint += (heat.tint[i] - tint) * wave
		mood.tint[i] = 255 + (tint - 255) * daylight
	end
	mood.brightness = (Calendar.valueAt(moods.Brightness, time, state) + heat.brightness * wave) * daylight
	mood.saturation = (Calendar.valueAt(moods.Saturation, time, state) + heat.saturation * wave) * daylight
	return mood
end

--[[
	`environment` (DayCycle.environment's, changed in place and returned) with `mood`'s shifts
	added as far as the sky reaches the camera (`exposure`, 0..1).
]]
function SeasonSky.apply(environment: DayCycle.Environment, mood: Mood, exposure: number): DayCycle.Environment
	local share = math.clamp(exposure, 0, 1)
	if share <= 0 then
		return environment
	end
	local shift, ambient = environment.colorShiftTop, environment.outdoorAmbient
	for i = 1, 3 do
		shift[i] = math.clamp(shift[i] + mood.shift[i] * share, 0, 255)
		ambient[i] = math.clamp(ambient[i] + mood.ambient[i] * share, 0, 255)
	end
	return environment
end

-- The grading for `mood` seen with `exposure`: its brightness, saturation and tint (0..255 each).
function SeasonSky.correction(mood: Mood, exposure: number): (number, number, { number })
	local share = math.clamp(exposure, 0, 1)
	local tint = mood.tint
	return mood.brightness * share,
		mood.saturation * share,
		{
			255 + (tint[1] - 255) * share,
			255 + (tint[2] - 255) * share,
			255 + (tint[3] - 255) * share,
		}
end

local function thousandths(value: number): number
	return math.floor(value * 1000 + 0.5)
end

--[[
	Writes the grading for `mood` seen with `exposure` (the glue: LightingController's update).
	Only what changed is written; the effect is made the first time it is needed.
]]
function SeasonSky.update(mood: Mood, exposure: number)
	local brightness, saturation, tint = SeasonSky.correction(mood, exposure)
	local b, s = thousandths(brightness), thousandths(saturation)
	local r, g, bl = math.floor(tint[1] + 0.5), math.floor(tint[2] + 0.5), math.floor(tint[3] + 0.5)
	local on = b ~= 0 or s ~= 0 or r ~= 255 or g ~= 255 or bl ~= 255
	local effect = correction
	if effect == nil then
		if not on then
			return
		end
		local made = Instance.new("ColorCorrectionEffect")
		made.Name = SeasonSky.CORRECTION
		made.Enabled = false
		made.Parent = Lighting
		correction = made
		effect = made
	end
	assert(effect, "made above")
	if b ~= shown.brightness then
		shown.brightness = b
		effect.Brightness = b / 1000
	end
	if s ~= shown.saturation then
		shown.saturation = s
		effect.Saturation = s / 1000
	end
	if r ~= shown.r or g ~= shown.g or bl ~= shown.b then
		shown.r, shown.g, shown.b = r, g, bl
		effect.TintColor = Color3.fromRGB(r, g, bl)
	end
	if on ~= shown.on then
		shown.on = on
		effect.Enabled = on
	end
end

return SeasonSky

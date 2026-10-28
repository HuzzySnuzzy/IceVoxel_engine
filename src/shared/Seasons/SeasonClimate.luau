--!strict
--[[
	What a season does to the climate, pure (Config.Seasons.Climate over Shared/Seasons/Calendar):
	the numbers Tough As Nails' temperature (ToughAsNails/Temperature: `seasonShift`, `nightDrop`),
	the weather (Shared/Weather's Moment: `weatherShift`, `wetBias`, `thunderBias`), plants'
	growth and the snow (caps, melting, the far landscape's cover) take from it.

	  Classes   `classOf(biome)`: the biome's `seasonClass` (the packs' biomes, Content/Schema's
	            BIOME_FIELDS; the Minecraft pack's "cold" Tundra, Taiga, Old Growth Taiga, Grove,
	            Snowy Slopes, Jagged and Frozen Peaks, "dry" Desert, Savanna and Windswept Savanna,
	            "tropical" Jungle and Mushroom Fields), else "temperate". A class's Amplitude (cold
	            1, temperate 1, dry 0.75, tropical 0.5) scales the day shift, the heat wave and the
	            weather's temperature shift: a jungle's winter is half a plain's.
	  Sample    `sample(dayTime, class, seed)`: every quantity blended at the calendar time
	            (Calendar.value), the climate's `shift` already times the class's amplitude (and
	            with the heat wave), `weatherShift` not (Shared/Weather scales it by each biome's
	            class: `amplitude`). With the calendar disabled every value is the identity's (shift
	            0, the old night drop, no biases, growth 1, no snow cover) and `active` is false:
	            callers pass no season at all then, so the game is as it was.
	  Heat wave `heatWave(time, seed)`: 0..1 at calendar time `time` (the day and the share of it
	            gone): a summer day is a heat wave's with Chance (Util/Hash of the day and the
	            world's seed), never two in a row (the summer's days are looked at from its first),
	            and it bumps from HeatWave.From (09:00) to To (18:00), ramping over Ramp ticks.
	  Snow      `snowCap(class, x, y, z, seed)`: the most layers snow piles up to in a column (0..8:
	            Snow.Caps by class, +1 every CapPerBlocks above CapAltitude, a drift of +-1 from a
	            noise over DriftWavelength blocks; none where it is dry). `melts(temperature)`:
	            snow melts where Minecraft's temperature (Shared/Weather.temperatureAt, the season's
	            shift added) is at least SNOW_BELOW (Weather's 0.15) + MeltMargin.
	            `snowCover(position, class)`: how white the far landscape is (0..1), and
	            `thawing(position, class)` whether that white is going or gone (below 1 and not
	            rising): the season's own snow (server Seasons/SnowWorld: where the biome would not
	            snow without the season) melts then whatever the temperature, so the near snow and
	            the far cover come and go together.

	Requires Config, Calendar, Biomes, Content/Schema and Util/Hash only (Shared/Weather requires
	this, for the classes: SNOW_BELOW is Weather's copied, tests/spec/SeasonClimate checks they
	agree).
]]

local Biomes = require(script.Parent.Parent.Biomes)
local Config = require(script.Parent.Parent.Config)
local Schema = require(script.Parent.Parent.Content.Schema)
local Hash = require(script.Parent.Parent.Util.Hash)
local Calendar = require(script.Parent.Calendar)

export type Class = "cold" | "temperate" | "dry" | "tropical"

export type Sample = {
	-- Added to the biome's climate (Tough As Nails' units), times the class's amplitude, the heat
	-- wave included.
	shift: number,
	-- Outdoors and under a roof at night, colder by this (replaces Temperature.NIGHT).
	nightDrop: number,
	-- 0..1: the heat wave now.
	heatWave: number,
	-- Added to Minecraft's biome temperature before the snow test (times each biome's amplitude:
	-- Shared/Weather).
	weatherShift: number,
	-- Lowers the moisture rain needs; lowers the moisture thunder needs (-1: none).
	wetBias: number,
	thunderBias: number,
	-- Plants' random-tick chance factor.
	growth: number,
	-- 0..1: how white the far landscape is (Shared/Seasons/Foliage).
	snowCover: number,
}

local SeasonClimate = {}

-- (Content/Schema's SEASON_CLASSES, a biome's `seasonClass`, are these: checked below.)
SeasonClimate.CLASSES = table.freeze({ "cold", "temperate", "dry", "tropical" })
-- Minecraft's Biome.coldEnoughToSnow border (Shared/Weather.SNOW_BELOW, copied: see the header).
SeasonClimate.SNOW_BELOW = 0.15
-- The most snow layers in a column.
SeasonClimate.MAX_LAYERS = 8
-- The night drop without seasons (Shared/ToughAsNails/Temperature.NIGHT).
SeasonClimate.NIGHT = 0.3

local isClass: { [string]: boolean } = {}
for _, class in SeasonClimate.CLASSES do
	isClass[class] = true
end
for _, class in Schema.SEASON_CLASSES do
	assert(isClass[class], `SeasonClimate: Content/Schema's season class {class} is none of CLASSES`)
end
local classByIndex: { [number]: Class } = {}
for index = 1, Biomes.count do
	classByIndex[index] = Biomes.get(index).seasonClass :: Class
end

-- The class of biome `biome` (a Biomes index; unknown ones are temperate).
function SeasonClimate.classOf(biome: number): Class
	return classByIndex[biome] or "temperate"
end

-- The amplitude of `class` (Config.Seasons.Climate.Amplitude).
function SeasonClimate.amplitude(class: Class): number
	local amplitude = (Config.Seasons.Climate.Amplitude :: any)[class]
	return if type(amplitude) == "number" then amplitude else 1
end

-- Do the seasons count with `s` (default the calendar's state)?
function SeasonClimate.active(s: Calendar.State?): boolean
	return (s or Calendar.state()).enabled
end

local function smoothstep(x: number): number
	return Calendar.smoothstep(x)
end

-- Is calendar day `day` a heat wave's candidate (the hash alone)?
local function candidate(day: number, seed: number): boolean
	return Hash.float3(seed, Hash.string("heat wave"), day, 0) < Config.Seasons.Climate.HeatWave.Chance
end

-- Is calendar day `day` a heat wave's (a summer day, its candidate, and not after one)?
function SeasonClimate.isHeatWave(day: number, seed: number, s: Calendar.State?): boolean
	local state = s or Calendar.state()
	local position = Calendar.at(day + 0.5, state)
	if position.season ~= Calendar.SUMMER then
		return false
	end
	-- (From the summer's first day: a wave, then never the day after.)
	local first = day - position.day
	local before = false
	for d = first, day do
		local wave = not before and candidate(d, seed)
		if d == day then
			return wave
		end
		before = wave
	end
	return false
end

-- 0..1: the heat wave at calendar time `time` with the world's `seed` (see the header).
function SeasonClimate.heatWave(time: number, seed: number, s: Calendar.State?): number
	local day = math.floor(time)
	if not SeasonClimate.isHeatWave(day, seed, s) then
		return 0
	end
	local wave = Config.Seasons.Climate.HeatWave
	local ticks = (time - day) * Calendar.TICKS_PER_DAY
	local ramp = math.max(wave.Ramp, 1)
	return smoothstep((ticks - wave.From) / ramp) * smoothstep((wave.To - ticks) / ramp)
end

--[[
	0..1: how white the far landscape of `class` is at `position` (Calendar.Position): temperate
	biomes over winter's first RampDays and back over spring's first, cold ones from
	ColdEarlyDays before winter to spring's ColdLateDays (the last RampDays of them thawing), dry
	and tropical ones never.
]]
function SeasonClimate.snowCover(position: Calendar.Position, class: Class): number
	if class == "dry" or class == "tropical" then
		return 0
	end
	local cover = Config.Seasons.Climate.SnowCover
	local ramp = math.max(cover.RampDays, 1e-6)
	local season = position.season
	local into = position.progress * position.days
	if class == "cold" then
		if season == Calendar.WINTER then
			return 1
		elseif season == Calendar.AUTUMN then
			local early = math.min(cover.ColdEarlyDays, position.days)
			return smoothstep((into - (position.days - early)) / math.max(early, 1e-6))
		elseif season == Calendar.SPRING then
			local late = math.min(cover.ColdLateDays, position.days)
			local thaw = math.min(ramp, late)
			return 1 - smoothstep((into - (late - thaw)) / math.max(thaw, 1e-6))
		end
		return 0
	end
	if season == Calendar.WINTER then
		return smoothstep(into / ramp)
	elseif season == Calendar.SPRING then
		return 1 - smoothstep(into / ramp)
	end
	return 0
end

--[[
	Is the far landscape's snow of `class` going or gone at `position` (`snowCover` below 1 and
	not rising)? Cold biomes from spring's thaw (its last RampDays of ColdLateDays) to autumn's
	last ColdEarlyDays, temperate ones outside winter, dry and tropical ones always.
]]
function SeasonClimate.thawing(position: Calendar.Position, class: Class): boolean
	if class == "dry" or class == "tropical" then
		return true
	end
	local season = position.season
	if season == Calendar.WINTER then
		return false
	elseif class ~= "cold" or season == Calendar.SUMMER then
		return true
	end
	local cover = Config.Seasons.Climate.SnowCover
	local into = position.progress * position.days
	if season == Calendar.AUTUMN then
		return into <= position.days - math.min(cover.ColdEarlyDays, position.days)
	end
	local late = math.min(cover.ColdLateDays, position.days)
	return into > late - math.min(math.max(cover.RampDays, 1e-6), late)
end

local function neutral(into: Sample?): Sample
	local sample: Sample = into
		or {
			shift = 0,
			nightDrop = SeasonClimate.NIGHT,
			heatWave = 0,
			weatherShift = 0,
			wetBias = 0,
			thunderBias = 0,
			growth = 1,
			snowCover = 0,
		}
	sample.shift = 0
	sample.nightDrop = SeasonClimate.NIGHT
	sample.heatWave = 0
	sample.weatherShift = 0
	sample.wetBias = 0
	sample.thunderBias = 0
	sample.growth = 1
	sample.snowCover = 0
	return sample
end

--[[
	The season's climate at `dayTime` for a biome of `class` in a world of `seed` (see the header),
	written into `into` when given. `s` defaults to the calendar's state; a disabled one gives the
	identity's values.
]]
function SeasonClimate.sample(dayTime: number, class: Class, seed: number, s: Calendar.State?, into: Sample?): Sample
	local state = s or Calendar.state()
	if not state.enabled then
		return neutral(into)
	end
	local climate = Config.Seasons.Climate
	local time = Calendar.time(dayTime, state)
	local amplitude = SeasonClimate.amplitude(class)
	-- (The heat wave goes by the real time of day, even while the calendar is locked.)
	local day = Calendar.day(dayTime, state)
	local ticks = dayTime - math.floor(dayTime / Calendar.TICKS_PER_DAY) * Calendar.TICKS_PER_DAY
	local wave = SeasonClimate.heatWave(day + ticks / Calendar.TICKS_PER_DAY, seed, state)
	local sample = into or neutral(nil)
	sample.heatWave = wave
	sample.shift = (Calendar.valueAt(climate.DayShift, time, state) + wave * climate.HeatWave.Shift) * amplitude
	sample.nightDrop = Calendar.valueAt(climate.NightDrop, time, state)
	sample.weatherShift = Calendar.valueAt(climate.WeatherShift, time, state)
	sample.wetBias = Calendar.valueAt(climate.WetBias, time, state)
	sample.thunderBias = Calendar.valueAt(climate.ThunderBias, time, state)
	sample.growth = Calendar.valueAt(climate.Growth, time, state)
	sample.snowCover = SeasonClimate.snowCover(Calendar.at(time, state), class)
	return sample
end

--[[
	The most snow layers a column (x, z) whose top cell is at height `y` piles up in a biome of
	`class` (see the header), 0..MAX_LAYERS.
]]
function SeasonClimate.snowCap(class: Class, x: number, y: number, z: number, seed: number): number
	local snow = Config.Seasons.Snow
	local base = (snow.Caps :: any)[class]
	if type(base) ~= "number" or base <= 0 then
		return 0
	end
	local cap = base + math.floor(math.max(0, y - snow.CapAltitude) / math.max(snow.CapPerBlocks, 1))
	-- (A drift of -1, 0 or +1 over DriftWavelength blocks; math.noise repeats every 256 units.)
	local frequency = 1 / math.max(snow.DriftWavelength, 1)
	local salt = (Hash.hash3(seed, Hash.string("snow drift"), 0, 0) % 4096) / 16
	local drift = math.noise((x * frequency) % 256 + 0.37, (z * frequency) % 256 + 0.71, salt)
	cap += if drift > 0.25 then 1 elseif drift < -0.25 then -1 else 0
	return math.clamp(cap, 0, SeasonClimate.MAX_LAYERS)
end

-- Does snow melt at Minecraft's temperature `temperature` (the season's shift added)?
function SeasonClimate.melts(temperature: number): boolean
	return temperature >= SeasonClimate.SNOW_BELOW + Config.Seasons.Climate.MeltMargin
end

return SeasonClimate

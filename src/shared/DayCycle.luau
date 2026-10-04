--!strict
--[[
	Minecraft's day, as pure maths (used by the server clock, the client's lighting and /time).

	  Day time   ticks: a day is 24000 (TICKS_PER_DAY), 0 is sunrise (06:00), 6000 noon, 12000
	             sunset, 18000 midnight. It keeps counting past 24000 (day 1, 2 ...), as Minecraft's
	             dayTime does. At 20 ticks a second a day lasts 20 minutes; Config.Time.DayLength
	             changes that (`rate`).
	  Angle      Minecraft's celestial angle (DimensionType.timeOfDay): 0 is noon, 0.5 midnight, and
	             the sun lingers a little around noon and midnight. ClockTime turns it into
	             Roblox's Lighting.ClockTime, so the sun stands where Minecraft draws it.
	  Sky light  Level.getSkyDarken (0 by day to 11 at night, so the night sky light is 4 of 15),
	             and the client's smooth 0..1 version (skyBrightness), used to blend lighting.
	             Both, and the sunrise glow, only depend on how high the sun stands (sunHeight), so
	             the client can blend by the sun Roblox really draws (`environment`).

	Replication: the server publishes the day time at one moment (ATTRIBUTE_TIME), that moment as
	workspace:GetServerTimeNow() (ATTRIBUTE_SYNC) and the speed in ticks a second (ATTRIBUTE_RATE,
	0 while the cycle is stopped) as workspace attributes. Everyone computes the time from those
	(`now`), so the clock costs no network traffic while it runs.
]]

local Config = require(script.Parent.Config)

local DayCycle = {}

DayCycle.TICKS_PER_DAY = 24000
-- Minecraft's tick rate: units of `s` in time arguments, and the speed of /time query gametime.
DayCycle.TICKS_PER_SECOND = 20

-- Workspace attributes the server clock publishes (server World/TimeOfDay).
DayCycle.ATTRIBUTE_TIME = "IceVoxelDayTime"
DayCycle.ATTRIBUTE_SYNC = "IceVoxelDaySync"
DayCycle.ATTRIBUTE_RATE = "IceVoxelDayRate"

-- The named times of /time set.
DayCycle.NAMED = table.freeze({ day = 1000, noon = 6000, night = 13000, midnight = 18000 } :: { [string]: number })

-- Units of a time argument (Minecraft's TimeArgument): days, seconds, ticks.
DayCycle.UNITS = table.freeze({ [""] = 1, t = 1, s = 20, d = 24000 } :: { [string]: number })

-- Minecraft's time arguments are Java ints.
DayCycle.MAX_TICKS = 2147483647

export type Lighting = typeof(Config.Lighting)

-- Lighting values for one moment (`environment`). Colours are { r, g, b } in 0..255.
export type Environment = {
	ambient: { number },
	outdoorAmbient: { number },
	brightness: number,
	colorShiftTop: { number },
	environmentDiffuse: number,
	environmentSpecular: number,
	fogColor: { number },
}

local function frac(x: number): number
	return x - math.floor(x)
end

local function clamp01(x: number): number
	return math.clamp(x, 0, 1)
end

-- Ticks a real second while the cycle runs (20 at Minecraft's 20 minute day; 0 for a day length
-- of 0 or less).
function DayCycle.rate(): number
	local length = Config.Time.DayLength
	return if length > 0 then DayCycle.TICKS_PER_DAY / length else 0
end

--[[
	The day time now, from what the server published: `base` ticks at server time `syncedAt`,
	advancing `rate` ticks a second. `serverNow` is workspace:GetServerTimeNow(). The time never
	runs backwards when the local clock estimate is a little behind the sync.
]]
function DayCycle.now(base: number, syncedAt: number, serverNow: number, rate: number): number
	return base + math.max(serverNow - syncedAt, 0) * rate
end

-- Minecraft's celestial angle (DimensionType.timeOfDay), 0..1: 0 noon, 0.25 sunset, 0.5 midnight.
function DayCycle.timeOfDay(dayTime: number): number
	local d0 = frac(dayTime / DayCycle.TICKS_PER_DAY - 0.25)
	local d1 = 0.5 - math.cos(d0 * math.pi) / 2
	return (d0 * 2 + d1) / 3
end

--[[
	The Roblox Lighting.ClockTime (hours) that puts the sun at Minecraft's angle for `dayTime`:
	angle 0 is noon, and a full turn is 24 hours. Tick 0 gives about 6.8, since Minecraft's sun is
	already 12 degrees up at "sunrise".
]]
function DayCycle.clockTime(dayTime: number): number
	return (12 + DayCycle.timeOfDay(dayTime) * 24) % 24
end

--[[
	How high Minecraft's sun stands for `dayTime`: the up (Y) part of the unit vector towards it, 1
	at noon, 0 on the horizon, -1 at midnight (its path goes through the zenith). Minecraft's sky
	brightness and sunrise glow are functions of this one number (`daylight`, `glow`).
]]
function DayCycle.sunHeight(dayTime: number): number
	return math.cos(DayCycle.timeOfDay(dayTime) * 2 * math.pi)
end

-- Minecraft's Level.getSkyDarken (clear weather): 0 by day, 11 at night.
function DayCycle.skyDarken(dayTime: number): number
	local daylight = 0.5 + 2 * math.clamp(DayCycle.sunHeight(dayTime), -0.25, 0.25)
	return math.floor((1 - daylight) * 11)
end

-- The sky light level outdoors, 15 by day and 4 at night.
function DayCycle.skyLight(dayTime: number): number
	return 15 - DayCycle.skyDarken(dayTime)
end

--[[
	A smooth daylight factor for a sun `height` (sunHeight), 1 by day and 0 at night
	(ClientLevel.getSkyDarken before it is mapped to 0.2..1 for the light map): it falls while the
	sun goes from about 24 degrees above the horizon to 6 below.
]]
function DayCycle.daylight(height: number): number
	return clamp01(height * 2 + 0.2)
end

-- `daylight` of Minecraft's sun at `dayTime`.
function DayCycle.skyBrightness(dayTime: number): number
	return DayCycle.daylight(DayCycle.sunHeight(dayTime))
end

--[[
	How strong the sunrise / sunset glow is for a sun `height`, 0..1 (the alpha of Minecraft's
	DimensionSpecialEffects.getSunriseColor): it peaks with the sun on the horizon and is 0 while
	the sun is more than about 24 degrees above or below it.
]]
function DayCycle.glow(height: number): number
	if height < -0.4 or height > 0.4 then
		return 0
	end
	local position = height / 0.4 * 0.5 + 0.5
	local alpha = 1 - (1 - math.sin(position * math.pi)) * 0.99
	return alpha * alpha
end

-- `glow` of Minecraft's sun at `dayTime`.
function DayCycle.duskFactor(dayTime: number): number
	return DayCycle.glow(DayCycle.sunHeight(dayTime))
end

-- The day number (Minecraft's /time query day): 0 on the first day.
function DayCycle.day(dayTime: number): number
	return math.floor(dayTime / DayCycle.TICKS_PER_DAY)
end

-- The time within the day, 0..23999 (Minecraft's /time query daytime).
function DayCycle.timeInDay(dayTime: number): number
	return math.floor(dayTime) % DayCycle.TICKS_PER_DAY
end

-- "HH:MM" on a 24 hour clock (tick 0 is 06:00), e.g. for debug screens.
function DayCycle.clockString(dayTime: number): string
	local minutes = math.floor((dayTime % DayCycle.TICKS_PER_DAY) * 0.06) -- 1000 ticks an hour
	local total = (minutes + 6 * 60) % (24 * 60)
	return string.format("%02d:%02d", total // 60, total % 60)
end

--[[
	A duration in ticks, like Minecraft's TimeArgument: a number with an optional unit, "d" (days of
	24000 ticks), "s" (seconds of 20 ticks) or "t" (ticks): "1d", "0.5d", "30s", "100". Rounded to
	whole ticks; negative values are refused. Returns nil and why on bad input.
]]
function DayCycle.parseDuration(text: string): (number?, string?)
	local digits, unit = string.match(text, "^([%+%-]?[%d%.]+)(%a*)$")
	if digits == nil or unit == nil then
		return nil, `Expected a time, found '{text}'`
	end
	local value = tonumber(digits)
	if value == nil then
		return nil, `Invalid number '{digits}'`
	end
	local scale = DayCycle.UNITS[string.lower(unit)]
	if scale == nil then
		return nil, `Invalid unit '{unit}' (use d, s or t)`
	end
	-- Java's Math.round.
	local ticks = math.floor(value * scale + 0.5)
	if ticks < 0 then
		return nil, `The tick count must not be less than 0, found {ticks}`
	end
	return math.min(ticks, DayCycle.MAX_TICKS), nil
end

-- A /time set argument: day (1000), noon (6000), night (13000), midnight (18000) or a duration.
function DayCycle.parseTime(text: string): (number?, string?)
	local named = DayCycle.NAMED[string.lower(text)]
	if named then
		return named, nil
	end
	return DayCycle.parseDuration(text)
end

--[[
	How much sky light reaches the camera, 1..0, from how many blocks it is below the natural
	ground: 1 above `start`, 0 from `finish` down, smooth in between.
]]
function DayCycle.skyExposure(depth: number, start: number, finish: number): number
	if finish <= start then
		return if depth < start then 1 else 0
	end
	local t = clamp01((depth - start) / (finish - start))
	return 1 - t * t * (3 - 2 * t)
end

-- How close `approach` gets before it lands on the target (so the values written stop changing).
DayCycle.SETTLE = 1e-3

--[[
	`current` moved towards `target` over `dt` seconds, exponentially with time constant `seconds`
	(about 95% of the way after 3 x seconds). It lands exactly on the target once within SETTLE,
	where an exponential alone would creep on for half a minute. nil `current` or no `seconds`:
	the target at once.
]]
function DayCycle.approach(current: number?, target: number, dt: number, seconds: number): number
	if current == nil or seconds <= 0 then
		return target
	end
	local value = current + (target - current) * (1 - math.exp(-math.max(dt, 0) / seconds))
	return if math.abs(target - value) < DayCycle.SETTLE then target else value
end

local function mix(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function mixColour(a: { number }, b: { number }, t: number): { number }
	return { mix(a[1], b[1], t), mix(a[2], b[2], t), mix(a[3], b[3], t) }
end

local BLACK = table.freeze({ 0, 0, 0 })

--[[
	The Lighting values for `dayTime` with `exposure` (0..1, skyExposure) of the sky light reaching
	the camera: Night blended to Day by the daylight factor, the Dusk colours mixed in by the glow
	x Dusk.Strength, then everything the sky gives (outdoor ambient, sun / moon, sky box light)
	faded out underground. Ambient is always CaveAmbient. `settings` defaults to Config.Lighting.

	`sunHeight` (-1..1) is the height of the sun the blend follows; it defaults to Minecraft's
	(sunHeight(dayTime)). The client passes the sun Roblox really draws, whose path also depends
	on Lighting.GeographicLatitude and the Earth's tilt, so the light always agrees with the sky.
]]
function DayCycle.environment(dayTime: number, exposure: number, settings: Lighting?, sunHeight: number?): Environment
	local light = settings or Config.Lighting
	local day, night, dusk = light.Day, light.Night, light.Dusk
	local height = math.clamp(sunHeight or DayCycle.sunHeight(dayTime), -1, 1)
	local daylight = DayCycle.daylight(height)
	local glow = DayCycle.glow(height) * dusk.Strength
	local dark = 1 - clamp01(exposure)

	local function colour(dayValue: { number }, nightValue: { number }, duskValue: { number }, cave: { number })
		local base = mixColour(nightValue, dayValue, daylight)
		return mixColour(mixColour(base, duskValue, glow), cave, dark)
	end
	local function level(dayValue: number, nightValue: number): number
		return mix(mix(nightValue, dayValue, daylight), 0, dark)
	end

	return {
		ambient = table.clone(light.CaveAmbient),
		outdoorAmbient = colour(day.OutdoorAmbient, night.OutdoorAmbient, dusk.OutdoorAmbient, BLACK),
		brightness = level(day.Brightness, night.Brightness),
		colorShiftTop = colour(day.ColorShiftTop, night.ColorShiftTop, dusk.ColorShiftTop, BLACK),
		environmentDiffuse = level(day.EnvironmentDiffuse, night.EnvironmentDiffuse),
		environmentSpecular = level(day.EnvironmentSpecular, night.EnvironmentSpecular),
		fogColor = colour(day.FogColor, night.FogColor, dusk.FogColor, light.Underground.FogColor),
	}
end

return DayCycle

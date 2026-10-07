--!strict
--[[
	Weather: where it rains, snows and thunders, for the server's gameplay and the clients'
	visuals, pure (no Roblox APIs, so the tests run all of it). The storms themselves are a field
	over the world and time (Weather/WeatherModel: noise drifting with a slowly turning wind,
	calibrated there); this module adds the clock, /weather's overrides, what falls where (rain,
	snow or nothing, by the biome and the altitude) and what the weather does to the sky.

	  Clock     the weather clock counts ticks like the day's (Shared/DayCycle) but on its own: 20 a
	            real second times Config.Weather.Speed (`rate`), 0 while doWeatherCycle is off
	            (Config.Weather.Cycle), never moved by /time. The server (World/WeatherServer)
	            publishes it as three workspace attributes, ATTRIBUTE_TIME (a value),
	            ATTRIBUTE_SYNC (its workspace:GetServerTimeNow()) and ATTRIBUTE_RATE (ticks a
	            second), and everyone computes it in closed form (`clock`), so it costs no traffic.
	  Override  /weather clear|rain|thunder [duration] (server Players/WeatherCommand) blends the
	            whole world towards that kind (WeatherModel's targets: rain at least 0.8 and no
	            thunder; thunder: full rain and thunder; clear: no rain and thin clouds at most)
	            over Config.Weather.BlendSeconds (Minecraft's 0.01 rain level a tick: 5 s), and
	            back out over the last BlendSeconds before it ends. A new override blends from
	            whatever the old one gave (`previous`, at the weight it had). While doWeatherCycle
	            is off an override's time stands still (Minecraft's counters wait too): it never
	            ends, and one fading out stays where it was. Published as one string attribute,
	            ATTRIBUTE_OVERRIDE (`writeState` / `readState`), so a client never sees half a
	            change; ATTRIBUTE_ENABLED false (worlds without weather: the debug worlds,
	            Config.Weather.Enabled) means always clear.
	  Moment    `momentAt(state, serverTime)`: the clock and the override's weights then. The
	            field's `at`, `grid` and `forecast` take a Moment (or a bare clock value: the
	            natural weather). `at`, `kindAt`, `grid`, `wind` and `forecast` here use the
	            world's field once `setSeed` was called.
	  Form      what falls (Minecraft's Biome.getPrecipitationAt): nothing in biomes without
	            precipitation (deserts, savannas: Biomes `precipitation`), else snow where the
	            temperature is below SNOW_BELOW (0.15) and rain above it. The temperature is the
	            biome's Minecraft one (Biomes `weatherTemperature`) made colder with height as in
	            Minecraft (Biome.getHeightAdjustedTemperature: 0.05 every 40 blocks above y 80,
	            with a small noise so the snow line is ragged) on this world's scaled terrain
	            (Generation/Relief: the datapack's heights x 0.43, so from y LAPSE_START (71),
	            LAPSE (0.0029) a block): a plains valley rains while the peaks above it snow.
	            `kindAt` is "clear", "rain" or "snow" (precipitation over RAINING, 0.2: Minecraft's
	            isRaining). It lands on the first block from the top that blocks movement or holds
	            a fluid (`blocksRain`: Minecraft's MOTION_BLOCKING), not on torches or plants.
	  Sky       Minecraft's darkening, as functions of the local precipitation and thunder:
	            the sky light and the sun dim by (1 - rain x 5/16) x (1 - thunder x 5/16)
	            (Level.updateSkyBrightness, ClientLevel.getSkyDarken): `skyDarken`, `isDay`
	            (zombies may walk in a thunderstorm's daylight), `skyLight`, `sunBrightness`,
	            `dimming`; the sky, cloud and fog colours greyed and darkened
	            (ClientLevel.getSkyColor / getCloudColor, FogRenderer); the fog distance factor
	            (Config.Weather.Fog, `fogFactor`); the rain's sound (`rainSound`, LevelRenderer's
	            weather.rain 0.2 / weather.rain.above 0.1) and thunder's delay (`thunderDelay`,
	            Config.Weather.SoundSpeed).
	  Saving    `encodeState` / `decodeState`: the clock's value, doWeatherCycle and the override
	            with the time it has left, as a short string (server World/WeatherServer's encode
	            and decode for the world's save).
]]

local Biomes = require(script.Parent.Biomes)
local Blocks = require(script.Parent.Blocks)
local Config = require(script.Parent.Config)
local DayCycle = require(script.Parent.DayCycle)
local WeatherModel = require(script.WeatherModel)

export type Field = WeatherModel.Field
export type Moment = WeatherModel.Moment
export type Sample = WeatherModel.Sample
export type Kind = WeatherModel.Kind

--[[
	The weather's state as the server keeps it and clients read it from the attributes: the clock
	(`base` ticks at server time `syncedAt`, `rate` ticks a second), doWeatherCycle (`cycle`), and
	the override: `override` ("" none, CLEAR, RAIN or THUNDER) since server time `start` until
	`finish` (math.huge while its time stands still: then `left` seconds remain), blended over
	`previous` at `previousWeight`.
]]
export type State = {
	enabled: boolean,
	base: number,
	syncedAt: number,
	rate: number,
	cycle: boolean,
	override: Kind,
	start: number,
	finish: number,
	left: number?,
	previous: Kind,
	previousWeight: number,
}

-- A forecast step: seconds from now and the weather then.
export type Forecast = { seconds: number, precipitation: number, thunder: number, cover: number }

local Weather = {}

Weather.Model = WeatherModel

-- The overrides /weather knows (Minecraft's names) and what falls at a place.
Weather.CLEAR = "clear"
Weather.RAIN = "rain"
Weather.THUNDER = "thunder"
Weather.SNOW = "snow"
Weather.NONE = ""
Weather.OVERRIDES = table.freeze({ Weather.CLEAR, Weather.RAIN, Weather.THUNDER })

-- Precipitation over this is rain (or snow) falling (Minecraft's isRaining: rain level > 0.2).
Weather.RAINING = WeatherModel.RAINING
-- Minecraft's Biome.coldEnoughToSnow: below 0.15 it snows.
Weather.SNOW_BELOW = 0.15
-- Where it gets colder with height (Minecraft's y 80 on this world's terrain) and how fast.
Weather.LAPSE_START = 71
Weather.LAPSE = 0.05 / 40 / 0.43
-- Minecraft's darkening by rain and by thunder: 5/16 of the sky's brightness each.
Weather.RAIN_DARKEN = 5 / 16
Weather.THUNDER_DARKEN = 5 / 16

-- Workspace attributes the server publishes (World/WeatherServer).
Weather.ATTRIBUTE_ENABLED = "IceVoxelWeatherEnabled"
Weather.ATTRIBUTE_TIME = "IceVoxelWeatherTime"
Weather.ATTRIBUTE_SYNC = "IceVoxelWeatherSync"
Weather.ATTRIBUTE_RATE = "IceVoxelWeatherRate"
Weather.ATTRIBUTE_OVERRIDE = "IceVoxelWeatherOverride"

-- Minecraft's ticks a second (durations of /weather, the clock at Speed 1).
Weather.TICKS_PER_SECOND = DayCycle.TICKS_PER_SECOND

local floor, clamp, min, max = math.floor, math.clamp, math.min, math.max

local function finite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function isOverride(kind: any): boolean
	return kind == Weather.CLEAR or kind == Weather.RAIN or kind == Weather.THUNDER
end
Weather.isOverride = isOverride

--[[ Clock and overrides ]]

-- Weather ticks a real second while the cycle runs (20 x Config.Weather.Speed).
function Weather.rate(): number
	return Weather.TICKS_PER_SECOND * max(Config.Weather.Speed, 0)
end

-- Seconds an override blends in and out.
function Weather.blendSeconds(): number
	return max(Config.Weather.BlendSeconds, 0)
end

-- A fresh state: the clock at `time` (default 0) since server time `now`, Config's cycle, no
-- override.
function Weather.newState(time: number?, now: number?, cycle: boolean?, enabled: boolean?): State
	local on = if cycle == nil then Config.Weather.Cycle else cycle
	return {
		enabled = if enabled == nil then Config.Weather.Enabled else enabled,
		base = time or 0,
		syncedAt = now or 0,
		rate = if on then Weather.rate() else 0,
		cycle = on,
		override = Weather.NONE,
		start = 0,
		finish = 0,
		left = nil,
		previous = Weather.NONE,
		previousWeight = 0,
	}
end

-- The weather clock at server time `now` (never running backwards before the sync).
function Weather.clock(state: State, now: number): number
	return DayCycle.now(state.base, state.syncedAt, now, state.rate)
end

local function ramp(seconds: number, blend: number): number
	if blend <= 0 then
		return if seconds >= 0 then 1 else 0
	end
	return clamp(seconds / blend, 0, 1)
end

-- The override's own weight at `now` and how far it has blended in (0..1).
local function weights(state: State, now: number): (number, number)
	if state.override == Weather.NONE then
		return 0, 1
	end
	local blend = Weather.blendSeconds()
	local rampIn = ramp(now - state.start, blend)
	local left = state.left
	local rampOut
	if left then
		rampOut = ramp(left, blend)
	elseif state.finish == math.huge then
		rampOut = 1
	else
		rampOut = ramp(state.finish - now, blend)
	end
	return min(rampIn, rampOut), rampIn
end

-- The clock and the override's weights at server time `now` (see Moment), written into `into`
-- when given (the client's visuals ask every frame).
function Weather.momentAt(state: State, now: number, into: Moment?): Moment
	local weight, rampIn = weights(state, now)
	local moment: Moment = into
		or {
			time = 0,
			enabled = false,
			override = Weather.NONE :: Kind,
			weight = 0,
			previous = Weather.NONE :: Kind,
			previousWeight = 0,
		}
	moment.time = Weather.clock(state, now)
	moment.enabled = state.enabled
	moment.override = state.override
	moment.weight = weight
	moment.previous = state.previous
	moment.previousWeight = if state.override == Weather.NONE then 0 else state.previousWeight * (1 - rampIn)
	return moment
end

-- Moves the clock's base to `now` (same time, fresh numbers), before its speed changes.
local function rebase(state: State, now: number)
	state.base = Weather.clock(state, now)
	state.syncedAt = now
end

-- Sets the weather clock to `time` ticks at server time `now`.
function Weather.setClock(state: State, time: number, now: number)
	assert(finite(time), "Weather.setClock needs a finite number")
	state.base = time
	state.syncedAt = now
end

--[[
	Starts or stops the weather clock (doWeatherCycle) at server time `now`. Stopping holds an
	override's time left (`left`); starting again counts it down from there.
]]
function Weather.setCycle(state: State, on: boolean, now: number)
	if on == state.cycle then
		return
	end
	rebase(state, now)
	state.cycle = on
	state.rate = if on then Weather.rate() else 0
	if state.override == Weather.NONE then
		return
	end
	if not on and state.finish ~= math.huge then
		state.left = max(state.finish - now, 0)
		state.finish = math.huge
	elseif on and state.left then
		state.finish = now + (state.left :: number)
		state.left = nil
	end
end

--[[
	Sets override `kind` (CLEAR, RAIN or THUNDER) for `seconds` from server time `now`, blending in
	from what the weather is now. With the cycle stopped its time stands still (see the header).
]]
function Weather.setOverride(state: State, kind: Kind, seconds: number, now: number)
	assert(isOverride(kind), `Weather.setOverride: unknown kind {kind}`)
	assert(seconds > 0 and seconds == seconds, "Weather.setOverride needs a positive duration")
	local weight = weights(state, now)
	if weight > 0 then
		state.previous, state.previousWeight = state.override, weight
	else
		state.previous, state.previousWeight = Weather.NONE, 0
	end
	state.override = kind
	state.start = now
	if state.cycle then
		state.finish, state.left = now + seconds, nil
	else
		state.finish, state.left = math.huge, seconds
	end
end

-- Drops an override that has run out by server time `now`. Returns whether it did.
function Weather.expire(state: State, now: number): boolean
	if state.override ~= Weather.NONE and state.left == nil and state.finish <= now then
		state.override, state.previous, state.previousWeight = Weather.NONE, Weather.NONE, 0
		state.start, state.finish = 0, 0
		return true
	end
	return false
end

-- The override at `now` ("" when none, or when it has blended out).
function Weather.overrideAt(state: State, now: number): Kind
	local weight = weights(state, now)
	return if weight > 0 then state.override else Weather.NONE
end

--[[ Attributes ]]

local function number(text: string?): number?
	local value = if text then tonumber(text) else nil
	return if value and value == value then value else nil
end

-- The override as ATTRIBUTE_OVERRIDE's text: "kind;start;finish;left;previous;previousWeight"
-- (finish -1 and left >= 0 while its time stands still; "" for none).
function Weather.encodeOverride(state: State): string
	if state.override == Weather.NONE then
		return ""
	end
	return string.format(
		"%s;%.17g;%.17g;%.17g;%s;%.17g",
		state.override,
		state.start,
		if state.finish == math.huge then -1 else state.finish,
		state.left or -1,
		state.previous,
		state.previousWeight
	)
end

-- Reads ATTRIBUTE_OVERRIDE's text into `state` (none when it is empty or malformed).
function Weather.decodeOverride(state: State, text: any)
	state.override, state.previous, state.previousWeight = Weather.NONE, Weather.NONE, 0
	state.start, state.finish, state.left = 0, 0, nil
	if type(text) ~= "string" or text == "" then
		return
	end
	local parts = string.split(text, ";")
	local start, finish, left, previousWeight = number(parts[2]), number(parts[3]), number(parts[4]), number(parts[6])
	if #parts ~= 6 or not isOverride(parts[1]) or start == nil or finish == nil or left == nil then
		return
	end
	state.override = parts[1]
	state.start = start
	state.finish = if finish < 0 then math.huge else finish
	state.left = if left >= 0 then left else nil
	if isOverride(parts[5]) and previousWeight then
		state.previous, state.previousWeight = parts[5], clamp(previousWeight, 0, 1)
	end
end

--[[
	Writes `state` with `set(name, value)` (workspace:SetAttribute): the sync and the rate before
	the time, as World/TimeOfDay does, then the override.
]]
function Weather.writeState(state: State, set: (string, any) -> ())
	set(Weather.ATTRIBUTE_ENABLED, state.enabled)
	set(Weather.ATTRIBUTE_SYNC, state.syncedAt)
	set(Weather.ATTRIBUTE_RATE, state.rate)
	set(Weather.ATTRIBUTE_TIME, state.base)
	set(Weather.ATTRIBUTE_OVERRIDE, Weather.encodeOverride(state))
end

--[[
	The state the attributes describe, read with `get(name)` (workspace:GetAttribute). Before the
	server published anything: no weather (enabled false).
]]
function Weather.readState(get: (string) -> any, into: State?): State
	local state = into or Weather.newState(0, 0, true, false)
	local enabled, base, syncedAt, rate =
		get(Weather.ATTRIBUTE_ENABLED),
		get(Weather.ATTRIBUTE_TIME),
		get(Weather.ATTRIBUTE_SYNC),
		get(Weather.ATTRIBUTE_RATE)
	state.enabled = enabled == true
	state.base = if type(base) == "number" and finite(base) then base else 0
	state.syncedAt = if type(syncedAt) == "number" and finite(syncedAt) then syncedAt else 0
	state.rate = if type(rate) == "number" and finite(rate) and rate >= 0 then rate else 0
	state.cycle = state.rate > 0
	Weather.decodeOverride(state, get(Weather.ATTRIBUTE_OVERRIDE))
	return state
end

--[[ Saving ]]

local SAVE_TAG = "w1"

--[[
	The state to keep in the world's save at server time `now`: "w1;clock;cycle;override;left"
	(cycle 1 / 0, override "" for none, left: its seconds to go, or -1).
]]
function Weather.encodeState(state: State, now: number): string
	-- (An override just set, not blended in yet, is kept; one that has run out is not.)
	local left = -1
	local override = state.override
	if override ~= Weather.NONE then
		left = state.left or (state.finish - now)
		if left <= 0 then
			override, left = Weather.NONE, -1
		end
	end
	return string.format(
		"%s;%.17g;%d;%s;%.17g",
		SAVE_TAG,
		Weather.clock(state, now),
		if state.cycle then 1 else 0,
		override,
		left
	)
end

--[[
	A state from `encodeState`'s text, its clock running from server time `now` and its override
	(if any) already blended in, so a world loads as it was saved. nil when the text is malformed.
]]
function Weather.decodeState(text: any, now: number, enabled: boolean?): State?
	if type(text) ~= "string" then
		return nil
	end
	local parts = string.split(text, ";")
	local clock, left = number(parts[2]), number(parts[5])
	if #parts ~= 5 or parts[1] ~= SAVE_TAG or clock == nil or not finite(clock) or left == nil then
		return nil
	end
	if parts[3] ~= "0" and parts[3] ~= "1" then
		return nil
	end
	local kind = parts[4]
	if kind ~= Weather.NONE and not isOverride(kind) then
		return nil
	end
	local state = Weather.newState(clock, now, parts[3] == "1", enabled)
	if kind ~= Weather.NONE and left > 0 and finite(left) then
		Weather.setOverride(state, kind, left, now)
		state.start = now - Weather.blendSeconds()
	end
	return state
end

--[[ The world's field ]]

local worldField: Field? = nil

-- Makes `seed`'s field the world's (the module-level `at`, `kindAt`, `grid`, `wind`, `forecast`).
function Weather.setSeed(seed: number): Field
	local current = worldField
	if current and current.seed == seed then
		return current
	end
	local field = WeatherModel.new(seed)
	worldField = field
	return field
end

-- The world's field (nil before `setSeed`).
function Weather.field(): Field?
	return worldField
end

-- A field for any seed (tests, previews).
function Weather.new(seed: number): Field
	return WeatherModel.new(seed)
end

local function world(): Field
	local field = worldField
	assert(field, "Weather.setSeed was not called")
	return field
end

-- Precipitation, thunder and cloud cover (0..1 each) at (x, z) at `time` (a clock value or a
-- Moment), in the world's field.
function Weather.at(x: number, z: number, time: number | Moment): (number, number, number)
	return world():at(x, z, time)
end

-- The wind at clock `time`: blocks per weather tick along x and z (x `rate` for a second).
function Weather.wind(time: number): (number, number)
	return world():wind(time)
end

-- See WeatherModel's Field.grid.
function Weather.grid(
	time: number | Moment,
	x0: number,
	z0: number,
	step: number,
	cols: number,
	rows: number,
	into: buffer?
): buffer
	return world():grid(time, x0, z0, step, cols, rows, into)
end

--[[
	A forecast at (x, z): `steps` samples from server time `now`, every `stepSeconds`, with the
	override as it will be then (the clock frozen by doWeatherCycle stays frozen).
]]
function Weather.forecastAt(
	field: Field,
	state: State,
	x: number,
	z: number,
	now: number,
	steps: number,
	stepSeconds: number
): { Forecast }
	local list: { Forecast } = table.create(max(steps, 0))
	for i = 0, steps - 1 do
		local seconds = i * stepSeconds
		local p, th, c = field:at(x, z, Weather.momentAt(state, now + seconds))
		list[i + 1] = { seconds = seconds, precipitation = p, thunder = th, cover = c }
	end
	return list
end

-- The natural forecast in the world's field (WeatherModel's Field.forecast: clock ticks).
function Weather.forecast(x: number, z: number, fromTime: number, steps: number, stepTicks: number): { Sample }
	return world():forecast(x, z, fromTime, steps, stepTicks)
end

--[[
	The first clock value (from 0, in steps of 30 s) at which (x, z) stays dry for `seconds`: a
	new world starts there, so its first minutes are clear at spawn. 0 when none is found soon.
]]
function Weather.clearStart(field: Field, x: number, z: number, seconds: number): number
	if seconds <= 0 then
		return 0
	end
	local tick = Weather.TICKS_PER_SECOND
	local span, step = seconds * tick, 30 * tick
	for try = 0, 400 do
		local from = try * step
		local dry = true
		for t = from, from + span, 10 * tick do
			if field:at(x, z, t) > 0 then
				dry = false
				break
			end
		end
		if dry then
			return from
		end
	end
	return 0
end

--[[ What falls where ]]

-- A fixed noise offset for the snow line's raggedness (Minecraft's TEMPERATURE_NOISE has a
-- fixed seed too).
local WOBBLE_Y = 37.53
-- The wobble's amplitude (blocks: Minecraft's 8 times its noise, scaled like the terrain; the
-- noise's ~0.5 range doubled) and its frequency (Minecraft's x / 8, scaled).
local WOBBLE = 2 * 8 * 0.43
local WOBBLE_FREQUENCY = 1 / (8 * 0.43)

--[[
	Minecraft's biome temperature of biome `index` (Biomes `weatherTemperature`), nil when nothing
	falls there (no precipitation: deserts and savannas) or the biome is unknown.
]]
function Weather.biomeTemperature(index: number): number?
	local biome = Biomes.get(index)
	if biome == nil or not biome.precipitation then
		return nil
	end
	return biome.weatherTemperature
end

-- The temperature at (x, y, z) for a biome of `temperature`: colder with height (see the header).
function Weather.temperatureAt(temperature: number, x: number, y: number, z: number): number
	if y <= Weather.LAPSE_START - 2 * WOBBLE then
		-- (math.noise stays within about +-1.)
		return temperature
	end
	local wobble = math.noise(x * WOBBLE_FREQUENCY + 0.31, z * WOBBLE_FREQUENCY + 0.67, WOBBLE_Y) * WOBBLE
	return temperature - max(0, y - Weather.LAPSE_START + wobble) * Weather.LAPSE
end

-- What falls at (x, y, z) in a biome of Minecraft `temperature` (nil: no precipitation): "rain",
-- "snow" or "" (nothing).
function Weather.formAt(temperature: number?, x: number, y: number, z: number): string
	if temperature == nil then
		return Weather.NONE
	end
	return if Weather.temperatureAt(temperature, x, y, z) < Weather.SNOW_BELOW then Weather.SNOW else Weather.RAIN
end

-- 1 for every block that stops rain (built on first use).
local stops: buffer? = nil

--[[
	Does `block` stop rain and snow (Minecraft's MOTION_BLOCKING heightmap: anything with a
	collision box, Blocks.obstruction: full blocks, leaves, glass, slabs, fences; and fluids)?
	Torches, plants, fire and the like let it through. The server's rain (World/WeatherRules) and
	the client's drops land on the first such block from the top.
]]
function Weather.blocksRain(block: number): boolean
	local lut = stops
	if lut == nil then
		local built = buffer.create(Blocks.count)
		for id = 0, Blocks.count - 1 do
			local def = Blocks.get(id)
			if def and (Blocks.obstruction(id) ~= nil or def.fluid ~= nil) then
				buffer.writeu8(built, id, 1)
			end
		end
		stops = built
		lut = built
	end
	return block >= 0 and block < Blocks.count and buffer.readu8(lut :: buffer, block) == 1
end

-- "clear", "rain" or "snow" for `precipitation` with what falls there (`formAt`).
function Weather.kindOf(precipitation: number, form: string): string
	if precipitation <= Weather.RAINING or form == Weather.NONE then
		return Weather.CLEAR
	end
	return form
end

--[[
	"clear", "rain" or "snow" at (x, y, z) at `time` (a clock value or a Moment) in the world's
	field, for a biome of Minecraft `biomeTemperature` (`biomeTemperature(index)`; nil: nothing
	falls there).
]]
function Weather.kindAt(x: number, y: number, z: number, time: number | Moment, biomeTemperature: number?): string
	if biomeTemperature == nil then
		return Weather.CLEAR
	end
	local precipitation = world():at(x, z, time)
	return Weather.kindOf(precipitation, Weather.formAt(biomeTemperature, x, y, z))
end

--[[ Sky, light, fog and sound ]]

-- How much the weather leaves of the sky's brightness: (1 - rain x 5/16) x (1 - thunder x 5/16).
function Weather.dimming(rain: number, thunder: number): number
	return (1 - clamp(rain, 0, 1) * Weather.RAIN_DARKEN) * (1 - clamp(thunder, 0, 1) * Weather.THUNDER_DARKEN)
end

-- Minecraft's Level.updateSkyBrightness with the weather: 0 by day in clear weather, up to 11 at
-- night (5 at noon in a full thunderstorm).
function Weather.skyDarken(dayTime: number, rain: number, thunder: number): number
	local daylight = 0.5 + 2 * clamp(DayCycle.sunHeight(dayTime), -0.25, 0.25)
	return floor((1 - daylight * Weather.dimming(rain, thunder)) * 11)
end

-- Minecraft's Level.isDay with the weather: false in a full thunderstorm even at noon.
function Weather.isDay(dayTime: number, rain: number, thunder: number): boolean
	return Weather.skyDarken(dayTime, rain, thunder) < 4
end

-- The sky light outdoors with the weather (15 on a clear day, 10 at noon in a thunderstorm).
function Weather.skyLight(dayTime: number, rain: number, thunder: number): number
	return 15 - Weather.skyDarken(dayTime, rain, thunder)
end

-- How bright the sun is (ClientLevel.getSkyDarken with the weather): 0.2 .. 1.
function Weather.sunBrightness(dayTime: number, rain: number, thunder: number): number
	return DayCycle.skyBrightness(dayTime) * Weather.dimming(rain, thunder) * 0.8 + 0.2
end

local function luminance(colour: { number }): number
	return colour[1] * 0.3 + colour[2] * 0.59 + colour[3] * 0.11
end

local function towards(colour: { number }, grey: number, keep: number): { number }
	return {
		colour[1] * keep + grey * (1 - keep),
		colour[2] * keep + grey * (1 - keep),
		colour[3] * keep + grey * (1 - keep),
	}
end

-- The sky's colour { r, g, b } greyed by the weather (ClientLevel.getSkyColor).
function Weather.skyColour(colour: { number }, rain: number, thunder: number): { number }
	local out = colour
	if rain > 0 then
		out = towards(out, luminance(out) * 0.6, 1 - clamp(rain, 0, 1) * 0.75)
	end
	if thunder > 0 then
		out = towards(out, luminance(out) * 0.2, 1 - clamp(thunder, 0, 1) * 0.75)
	end
	return out
end

-- The clouds' colour greyed by the weather (ClientLevel.getCloudColor).
function Weather.cloudColour(colour: { number }, rain: number, thunder: number): { number }
	local out = colour
	if rain > 0 then
		out = towards(out, luminance(out) * 0.6, 1 - clamp(rain, 0, 1) * 0.95)
	end
	if thunder > 0 then
		out = towards(out, luminance(out) * 0.2, 1 - clamp(thunder, 0, 1) * 0.95)
	end
	return out
end

-- The fog's colour darkened by the weather (FogRenderer.setupColor).
function Weather.fogColour(colour: { number }, rain: number, thunder: number): { number }
	local r = clamp(rain, 0, 1)
	local t = clamp(thunder, 0, 1)
	local red, blue = (1 - r * 0.5) * (1 - t * 0.5), (1 - r * 0.4) * (1 - t * 0.5)
	return { colour[1] * red, colour[2] * red, colour[3] * blue }
end

--[[
	How far the fog reaches, as a factor of its clear weather distance: down to Config.Weather.Fog
	.Rain (Snow when `snow`) at full precipitation and .Thunder at full thunder (the nearer wins).
]]
function Weather.fogFactor(precipitation: number, thunder: number, snow: boolean?): number
	local fog = Config.Weather.Fog
	local full = if snow then fog.Snow else fog.Rain
	local byRain = 1 + (full - 1) * clamp(precipitation, 0, 1)
	local byThunder = 1 + (fog.Thunder - 1) * clamp(thunder, 0, 1)
	return min(byRain, byThunder)
end

--[[
	The rain's sound (LevelRenderer.tickRain): volume and pitch of weather.rain (0.2, 1) or, when
	the rain lands on a roof over the listener (`sheltered`), weather.rain.above (0.1, 0.5), louder
	with the precipitation up to 0.5 (Minecraft plays it while any rain lands near). 0 when nothing
	falls (precipitation not over RAINING).
]]
function Weather.rainSound(precipitation: number, sheltered: boolean): (number, number)
	if precipitation <= Weather.RAINING then
		return 0, 1
	end
	local level = clamp(precipitation / 0.5, 0, 1)
	if sheltered then
		return 0.1 * level, 0.5
	end
	return 0.2 * level, 1
end

-- Seconds after a strike `distance` blocks away its thunder is heard.
function Weather.thunderDelay(distance: number): number
	local speed = Config.Weather.SoundSpeed
	return if speed > 0 then max(distance, 0) / speed else 0
end

return Weather

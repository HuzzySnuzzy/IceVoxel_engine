--!strict
--!native
--[[
	The weather as a field over the world and time: pure and deterministic, so the server, every
	client and the tests compute the same storms from the same seed and the same weather clock
	(ticks, Shared/Weather's clock; independent of the day's, so /time set never moves a storm).
	Minecraft's weather is one switch for the whole world (ServerLevel.advanceWeatherCycle: clear
	for 12000-180000 ticks, rain for 12000-24000, thunder within it for 3600-15600); here it is
	regional, so a storm can be seen coming and left behind.

	  Wind      the air's displacement D(t) has a closed form: a prevailing wind (WIND_MEAN blocks
	            a tick, 1.2 a second, in a direction drawn from the seed) plus three swings in
	            time (WIND_SWINGS: periods of 7 to 31 minutes, amplitudes up to 0.7 blocks a
	            second, phases drawn from the seed), so the wind's speed (0 to about 3 blocks a
	            second) and direction wander slowly and smoothly (`wind`, `displacement`).
	            Everything below is drawn in the air's frame, (x, z) - D(t): storms drift with the
	            wind.
	  Moisture  three layers of Perlin noise (math.noise) in the air's frame, each also moving
	            slowly through its own time axis, so storms grow, merge and die out while they
	            drift (LAYERS: weather systems ~5 km across, storm cells ~1.6 km, ~450 block
	            showers; weights 0.55, 0.36, 0.08). Each changes in place about half as fast as
	            the mean wind carries it (a noise unit in 200000, 60000 and 20000 ticks), so a
	            storm keeps its shape while it comes closer, and one sits over a place for long
	            only while the wind is calm.
	  Rain      precipitation (0..1) is the moisture over RAIN_LOW, smoothed up to 1 at RAIN_HIGH:
	            drizzle at a storm's edge, a downpour in its core. It counts as raining (or
	            snowing) from RAINING (0.2, Minecraft's Level.isRaining: rain level over 0.2).
	  Clouds    cover (0..1) starts lower (CLOUD_LOW), so overcast skies spread around the rain
	            and a storm can be seen from far away before it arrives.
	  Thunder   (0..1) where the moisture is highest (THUNDER_LOW..HIGH) and a slower
	            "instability" noise allows it (so only some heavy storms thunder), never more
	            than the precipitation (Minecraft's thunder level is rain x thunder).

	Calibration (measured on seeds 12345, 777 and 4242, 192 places each over 40 in-game days,
	sampled every 10 s; tests/spec/Weather checks the ranges): it rains at a place 23-24% of the
	time (Minecraft: about 16%, 15 minutes of rain in every 95); a spell of rain lasts 16-18
	minutes on average (median 11-13, one in ten under 2, one in ten over 42 (two in-game days),
	the longest 2-3 hours, under a big system in calm air), clear stretches 50-56 minutes
	(median 26-31); a storm is about 1.1 km across along a line through it (median; one in ten
	under 225 blocks, one in ten over 3.5 km, the largest 8-10 km); thunder (over 0.5) 3.1-3.3%
	of the time, 13-14% of the rainy time (Minecraft: about 9%); the wind 0 to 3 blocks a second,
	median 1.3-1.4. A sample costs about 0.5 microseconds (Lune, native code).

	Overrides (/weather, Shared/Weather's clock state) blend the natural field towards a kind
	everywhere: a Moment carries the weather clock and the override's weight (`at`, `grid` and
	`forecast` take a Moment or a plain clock value).

	Precision: math.noise works in single precision and its lattice repeats every 256 units, so
	every noise coordinate is reduced modulo 256 in double precision first: storms stay smooth
	however far from the origin and however long the clock has run.
]]

local Hash = require(script.Parent.Parent.Util.Hash)
local Noise = require(script.Parent.Parent.Generation.Noise)

local noise = math.noise
local sin, cos = math.sin, math.cos
local max, min = math.max, math.min

-- An override's kind: none (""), or what /weather asked for.
export type Kind = string

--[[
	The weather clock at one moment with the /weather override then (Shared/Weather.momentAt): the
	override `kind` at `weight` (0..1), blended over what was there before it, `previous` at
	`previousWeight` (fading out while the new one comes in). `enabled` false: no weather at all.
]]
export type Moment = {
	time: number,
	enabled: boolean,
	override: Kind,
	weight: number,
	previous: Kind,
	previousWeight: number,
}

-- One step of a forecast: the weather clock and the weather then.
export type Sample = { time: number, precipitation: number, thunder: number, cover: number }

export type Field = {
	seed: number,

	-- Precipitation (0..1), thunder (0..1) and cloud cover (0..1) at (x, z) at `time` (a
	-- weather clock value, or a Moment with the override).
	at: (self: Field, x: number, z: number, time: number | Moment) -> (number, number, number),
	-- The wind at `time`: blocks per weather tick along x and z.
	wind: (self: Field, time: number) -> (number, number),
	-- How far the air has moved since time 0 (blocks along x and z).
	displacement: (self: Field, time: number) -> (number, number),
	-- The raw moisture (before the thresholds) at (x, z) at clock `time`.
	moisture: (self: Field, x: number, z: number, time: number) -> number,
	--[[
		Samples a grid in one call: `cols` x `rows` cells `step` blocks apart, the first at
		(x0, z0), cell (col, row) (0-based) at (x0 + col x step, z0 + row x step). Writes 3 bytes a
		cell, row by row, at ((row x cols) + col) x 3: precipitation, thunder and cover x 255,
		rounded, into `into` (reused when it is big enough) and returns the buffer.
	]]
	grid: (
		self: Field,
		time: number | Moment,
		x0: number,
		z0: number,
		step: number,
		cols: number,
		rows: number,
		into: buffer?
	) -> buffer,
	-- `steps` samples at (x, z): at fromTime, then every `stepTicks` weather ticks.
	forecast: (self: Field, x: number, z: number, fromTime: number, steps: number, stepTicks: number) -> { Sample },

	-- Internal: the seed's offsets and phases.
	_ox: { number },
	_oz: { number },
	_ot: { number },
	_meanX: number,
	_meanZ: number,
	_phaseX: { number },
	_phaseZ: { number },
}

local WeatherModel = {}

-- Minecraft's isRaining threshold: precipitation over this counts as rain (or snow) falling.
WeatherModel.RAINING = 0.2
-- The prevailing wind, blocks per weather tick (1.2 blocks a second at 20 ticks a second).
WeatherModel.WIND_MEAN = 0.06
-- The wind's swings: { period (ticks), amplitude (blocks a tick) }.
WeatherModel.WIND_SWINGS = table.freeze({
	table.freeze({ 8600, 0.035 }),
	table.freeze({ 17900, 0.025 }),
	table.freeze({ 37100, 0.015 }),
})
-- The moisture's layers: { wavelength (blocks), ticks per noise unit of change, weight }.
WeatherModel.LAYERS = table.freeze({
	table.freeze({ 5000, 200000, 0.55 }),
	table.freeze({ 1600, 60000, 0.36 }),
	table.freeze({ 450, 20000, 0.08 }),
})
-- The instability noise that lets a heavy storm thunder: { wavelength, ticks per unit }.
WeatherModel.INSTABILITY = table.freeze({ 2600, 60000 })
-- Moisture thresholds (see the header; the calibration there).
WeatherModel.CLOUD_LOW = 0.02
WeatherModel.CLOUD_HIGH = 0.16
WeatherModel.RAIN_LOW = 0.1
WeatherModel.RAIN_HIGH = 0.22
WeatherModel.THUNDER_LOW = 0.2
WeatherModel.THUNDER_HIGH = 0.28
WeatherModel.INSTABLE_LOW = 0.06
WeatherModel.INSTABLE_HIGH = 0.18

-- What an override blends towards (from the natural values): /weather clear leaves thin
-- clouds at most; rain and thunder rain everywhere, at least at these levels.
WeatherModel.CLEAR_COVER = 0.25
WeatherModel.RAIN_LEVEL = 0.8
WeatherModel.THUNDER_RAIN = 1

local CLOUD_LOW, CLOUD_SCALE = WeatherModel.CLOUD_LOW, 1 / (WeatherModel.CLOUD_HIGH - WeatherModel.CLOUD_LOW)
local RAIN_LOW, RAIN_SCALE = WeatherModel.RAIN_LOW, 1 / (WeatherModel.RAIN_HIGH - WeatherModel.RAIN_LOW)
local THUNDER_LOW, THUNDER_SCALE = WeatherModel.THUNDER_LOW, 1 / (WeatherModel.THUNDER_HIGH - WeatherModel.THUNDER_LOW)
local INSTABLE_LOW, INSTABLE_SCALE =
	WeatherModel.INSTABLE_LOW, 1 / (WeatherModel.INSTABLE_HIGH - WeatherModel.INSTABLE_LOW)

local F1, F2, F3 = 1 / WeatherModel.LAYERS[1][1], 1 / WeatherModel.LAYERS[2][1], 1 / WeatherModel.LAYERS[3][1]
local E1, E2, E3 = 1 / WeatherModel.LAYERS[1][2], 1 / WeatherModel.LAYERS[2][2], 1 / WeatherModel.LAYERS[3][2]
local W1, W2, W3 = WeatherModel.LAYERS[1][3], WeatherModel.LAYERS[2][3], WeatherModel.LAYERS[3][3]
local FI, EI = 1 / WeatherModel.INSTABILITY[1], 1 / WeatherModel.INSTABILITY[2]

local SWINGS = #WeatherModel.WIND_SWINGS
local OMEGA: { number } = {}
local AMPLITUDE: { number } = {}
for i, swing in WeatherModel.WIND_SWINGS do
	OMEGA[i] = 2 * math.pi / swing[1]
	AMPLITUDE[i] = swing[2]
end

local TAU = 2 * math.pi
local U32 = 4294967296

-- Smoothstep of x clamped to 0..1.
local function smooth(x: number): number
	if x <= 0 then
		return 0
	elseif x >= 1 then
		return 1
	end
	return x * x * (3 - 2 * x)
end
WeatherModel.smooth = smooth

local Field = {}
Field.__index = Field

-- A field for world `seed`.
function WeatherModel.new(seed: number): Field
	local ox, oz, ot = {}, {}, {}
	for layer = 1, 4 do
		ox[layer], ot[layer], oz[layer] = Noise.offsets(seed, "weather", layer)
	end
	local angle = Hash.hash3(seed, Hash.string("weather wind"), 0, 0) / U32 * TAU
	local phaseX, phaseZ = {}, {}
	for i = 1, SWINGS do
		phaseX[i] = Hash.hash3(seed, Hash.string("weather wind"), i, 1) / U32 * TAU
		phaseZ[i] = Hash.hash3(seed, Hash.string("weather wind"), i, 2) / U32 * TAU
	end
	local self = {
		seed = seed,
		_ox = ox,
		_oz = oz,
		_ot = ot,
		_meanX = cos(angle) * WeatherModel.WIND_MEAN,
		_meanZ = sin(angle) * WeatherModel.WIND_MEAN,
		_phaseX = phaseX,
		_phaseZ = phaseZ,
	}
	return setmetatable(self, Field) :: any
end

function Field.wind(self: Field, time: number): (number, number)
	local vx, vz = self._meanX, self._meanZ
	local phaseX, phaseZ = self._phaseX, self._phaseZ
	for i = 1, SWINGS do
		local a = OMEGA[i] * time
		vx += AMPLITUDE[i] * cos(a + phaseX[i])
		vz += AMPLITUDE[i] * cos(a + phaseZ[i])
	end
	return vx, vz
end

function Field.displacement(self: Field, time: number): (number, number)
	local dx, dz = self._meanX * time, self._meanZ * time
	local phaseX, phaseZ = self._phaseX, self._phaseZ
	for i = 1, SWINGS do
		local omega = OMEGA[i]
		local scale = AMPLITUDE[i] / omega
		local a = omega * time
		dx += scale * (sin(a + phaseX[i]) - sin(phaseX[i]))
		dz += scale * (sin(a + phaseZ[i]) - sin(phaseZ[i]))
	end
	return dx, dz
end

-- The moisture at air-frame point (u, w) with the layers' time coordinates t1..t3 (each already
-- reduced modulo 256).
local function moistureAt(self: Field, u: number, w: number, t1: number, t2: number, t3: number): number
	local ox, oz = self._ox, self._oz
	return W1 * noise((u * F1 + ox[1]) % 256, (w * F1 + oz[1]) % 256, t1)
		+ W2 * noise((u * F2 + ox[2]) % 256, (w * F2 + oz[2]) % 256, t2)
		+ W3 * noise((u * F3 + ox[3]) % 256, (w * F3 + oz[3]) % 256, t3)
end

-- Precipitation, thunder and cover from moisture `m` at air-frame (u, w), instability time `ti`.
local function shape(self: Field, m: number, u: number, w: number, ti: number): (number, number, number)
	local p = smooth((m - RAIN_LOW) * RAIN_SCALE)
	local c = smooth((m - CLOUD_LOW) * CLOUD_SCALE)
	local th = 0
	if m > THUNDER_LOW then
		local instability = noise((u * FI + self._ox[4]) % 256, (w * FI + self._oz[4]) % 256, ti)
		th = smooth((m - THUNDER_LOW) * THUNDER_SCALE) * smooth((instability - INSTABLE_LOW) * INSTABLE_SCALE)
		if th > p then
			th = p
		end
	end
	return p, th, c
end

-- The values an override of `kind` blends towards, from the natural ones.
local function target(kind: Kind, p: number, th: number, c: number): (number, number, number)
	if kind == "clear" then
		return 0, 0, min(c, WeatherModel.CLEAR_COVER)
	elseif kind == "rain" then
		return max(p, WeatherModel.RAIN_LEVEL), 0, 1
	elseif kind == "thunder" then
		return max(p, WeatherModel.THUNDER_RAIN), 1, 1
	end
	return p, th, c
end

--[[
	The natural values blended with a moment's override: first towards what was there before it
	(`previous` at `previousWeight`), then towards the override at `weight` (see the header).
]]
local function blend(moment: Moment, p: number, th: number, c: number): (number, number, number)
	local pw, w = moment.previousWeight, moment.weight
	if pw > 0 then
		local tp, tth, tc = target(moment.previous, p, th, c)
		p, th, c = p + (tp - p) * pw, th + (tth - th) * pw, c + (tc - c) * pw
	end
	if w > 0 then
		local tp, tth, tc = target(moment.override, p, th, c)
		p, th, c = p + (tp - p) * w, th + (tth - th) * w, c + (tc - c) * w
	end
	return p, th, c
end
WeatherModel.blend = blend

-- The clock of `time` (a value or a Moment) and its moment (nil for a plain value).
local function split(time: number | Moment): (number, Moment?)
	if type(time) == "number" then
		return time, nil
	end
	local moment = time :: Moment
	return moment.time, moment
end

function Field.moisture(self: Field, x: number, z: number, time: number): number
	local dx, dz = self:displacement(time)
	local ot = self._ot
	return moistureAt(
		self,
		x - dx,
		z - dz,
		(time * E1 + ot[1]) % 256,
		(time * E2 + ot[2]) % 256,
		(time * E3 + ot[3]) % 256
	)
end

function Field.at(self: Field, x: number, z: number, time: number | Moment): (number, number, number)
	local clock, moment = split(time)
	if moment and not moment.enabled then
		return 0, 0, 0
	end
	local dx, dz = self:displacement(clock)
	local ot = self._ot
	local u, w = x - dx, z - dz
	local m = moistureAt(self, u, w, (clock * E1 + ot[1]) % 256, (clock * E2 + ot[2]) % 256, (clock * E3 + ot[3]) % 256)
	local p, th, c = shape(self, m, u, w, (clock * EI + ot[4]) % 256)
	if moment then
		return blend(moment, p, th, c)
	end
	return p, th, c
end

local function byte(value: number): number
	return math.clamp(math.floor(value * 255 + 0.5), 0, 255)
end

function Field.grid(
	self: Field,
	time: number | Moment,
	x0: number,
	z0: number,
	step: number,
	cols: number,
	rows: number,
	into: buffer?
): buffer
	local size = cols * rows * 3
	local out = if into and buffer.len(into) >= size then into else buffer.create(size)
	local clock, moment = split(time)
	if moment and not moment.enabled then
		buffer.fill(out, 0, 0, size)
		return out
	end
	local blending = moment ~= nil and (moment.weight > 0 or moment.previousWeight > 0)
	local dx, dz = self:displacement(clock)
	local ot = self._ot
	local t1, t2, t3 = (clock * E1 + ot[1]) % 256, (clock * E2 + ot[2]) % 256, (clock * E3 + ot[3]) % 256
	local ti = (clock * EI + ot[4]) % 256
	local index = 0
	for row = 0, rows - 1 do
		local w = z0 + row * step - dz
		for col = 0, cols - 1 do
			local u = x0 + col * step - dx
			local p, th, c = shape(self, moistureAt(self, u, w, t1, t2, t3), u, w, ti)
			if blending then
				p, th, c = blend(moment :: Moment, p, th, c)
			end
			buffer.writeu8(out, index, byte(p))
			buffer.writeu8(out, index + 1, byte(th))
			buffer.writeu8(out, index + 2, byte(c))
			index += 3
		end
	end
	return out
end

function Field.forecast(
	self: Field,
	x: number,
	z: number,
	fromTime: number,
	steps: number,
	stepTicks: number
): { Sample }
	local list: { Sample } = table.create(math.max(steps, 0))
	for i = 0, steps - 1 do
		local time = fromTime + i * stepTicks
		local p, th, c = self:at(x, z, time)
		list[i + 1] = { time = time, precipitation = p, thunder = th, cover = c }
	end
	return list
end

return WeatherModel

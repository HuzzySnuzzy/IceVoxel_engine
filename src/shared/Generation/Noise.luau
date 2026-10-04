--!strict
--!native
--[[
	Seeded noise built on top of the engine's native `math.noise` (Perlin, implemented in C++).

	`math.noise` has no seed and returns 0 on integer lattice points, so every noise channel gets its
	own fractional offset derived from the world seed and a salt string. Different salts give
	independent noise fields.

	All sampler constructors return plain closures; calling a closure is much cheaper than a method
	lookup in the hot generation loops.
]]

local Hash = require(script.Parent.Parent.Util.Hash)

local noise = math.noise
local abs = math.abs
local sqrt = math.sqrt

-- Standard deviation of math.noise over random inputs (measured).
local RAW_STD = 0.28
-- Normalised samplers are scaled so their standard deviation is ~1/3: almost everything lands in
-- [-1, 1] without hard clamping.
local TARGET_STD = 1 / 3

local Noise = {}

export type Sampler2 = (x: number, z: number) -> number
export type Sampler3 = (x: number, y: number, z: number) -> number

-- Offsets kept small (< 4096) because math.noise works in single precision internally.
function Noise.offsets(seed: number, salt: string, octave: number?): (number, number, number)
	local s = Hash.string(salt)
	local o = octave or 0
	local a = Hash.hash3(seed, s, o, 1)
	local b = Hash.hash3(seed, s, o, 2)
	local c = Hash.hash3(seed, s, o, 3)
	-- (h % 4096) gives the integer part, the scaled hash gives a non-lattice fractional part.
	return (a % 4096) + 0.1 + (a / 4294967296) * 0.8,
		(b % 4096) + 0.1 + (b / 4294967296) * 0.8,
		(c % 4096) + 0.1 + (c / 4294967296) * 0.8
end

--[[
	Fractal Brownian motion in 2D. Output has a standard deviation of ~1/3 (mostly within [-1, 1]).
	`frequency` is in cycles per block, e.g. 1/256 for features roughly 256 blocks wide.
]]
function Noise.fbm2(
	seed: number,
	salt: string,
	frequency: number,
	octaves: number,
	persistence: number?,
	lacunarity: number?
): Sampler2
	local gain = persistence or 0.5
	local lac = lacunarity or 2

	local ox: { number }, oz: { number }, oy: { number }, freqs: { number }, amps: { number } = {}, {}, {}, {}, {}
	local f, a, sumSq = frequency, 1, 0
	for i = 1, octaves do
		local x, y, z = Noise.offsets(seed, salt, i)
		ox[i], oy[i], oz[i] = x, y, z
		freqs[i], amps[i] = f, a
		sumSq += a * a
		f *= lac
		a *= gain
	end
	local norm = TARGET_STD / (RAW_STD * sqrt(sumSq))

	if octaves == 1 then
		local f1, x1, y1, z1 = freqs[1], ox[1], oy[1], oz[1]
		return function(x: number, z: number): number
			return noise(x * f1 + x1, z * f1 + z1, y1) * norm
		end
	end

	return function(x: number, z: number): number
		local sum = 0
		for i = 1, octaves do
			local fi = freqs[i]
			sum += amps[i] * noise(x * fi + ox[i], z * fi + oz[i], oy[i])
		end
		return sum * norm
	end
end

--[[
	Ridged multifractal noise in 2D, in [0, 1]. Produces sharp ridges (1) separated by smooth
	valleys (0); used for mountain ranges.
]]
function Noise.ridged2(
	seed: number,
	salt: string,
	frequency: number,
	octaves: number,
	persistence: number?,
	lacunarity: number?
): Sampler2
	local gain = persistence or 0.5
	local lac = lacunarity or 2

	local ox: { number }, oz: { number }, oy: { number }, freqs: { number }, amps: { number } = {}, {}, {}, {}, {}
	local f, a, total = frequency, 1, 0
	for i = 1, octaves do
		local x, y, z = Noise.offsets(seed, salt, i)
		ox[i], oy[i], oz[i] = x, y, z
		freqs[i], amps[i] = f, a
		total += a
		f *= lac
		a *= gain
	end
	local inv = 1 / total

	return function(x: number, z: number): number
		local sum = 0
		for i = 1, octaves do
			local fi = freqs[i]
			local r = 1 - abs(noise(x * fi + ox[i], z * fi + oz[i], oy[i])) * 2.5
			if r < 0 then
				r = 0
			end
			sum += amps[i] * r * r
		end
		return sum * inv
	end
end

-- Single octave 3D noise, normalised like fbm2. `yScale` squashes / stretches features vertically.
function Noise.noise3(seed: number, salt: string, frequency: number, yScale: number?): Sampler3
	local ox, oy, oz = Noise.offsets(seed, salt, 0)
	local fy = frequency * (yScale or 1)
	local norm = TARGET_STD / RAW_STD
	return function(x: number, y: number, z: number): number
		return noise(x * frequency + ox, y * fy + oy, z * frequency + oz) * norm
	end
end

return Noise

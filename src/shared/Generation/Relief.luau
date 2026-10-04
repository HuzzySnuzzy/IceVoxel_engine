--!strict
--!native
--[[
	Terrain relief (one height per column), modelled on the "JJThunder To The Max" Minecraft
	datapack (version 0.6.0): mountain ranges hundreds of blocks high, flanked by hills and plains,
	wide river valleys and enclosed seas. The datapack's surface is a pure heightfield too; caves are
	carved separately (Caves.luau).

	All shapes are computed in the datapack's units and mapped to blocks at the end: heights in "H"
	(1 H = 1048 of its blocks), positions in its blocks, which are 1 / SCALE of ours.

	  selector   A very large single octave noise (~18 km wavelength here), warped near its zero
	             contour by a second one. a = |selector| picks the terrain type:
	               a = 0       extreme mountains (ranges follow the selector's zero contour)
	               a = 0.075   mountains
	               a = 0.15    extreme hills
	               a = 0.225   hills
	               a = 0.30    plains
	               a >= 0.40   ocean (the selector's extremes are enclosed seas)
	             Between two of these, their heights are blended with a smoothstep, so at most two
	             types are evaluated per column.
	  types      height = offset + a large, smooth offset noise + a "factor" noise (kilometre-scale
	             ridges and valleys) + "jagged" detail (many octaves, stronger on high ground).
	             The factor is eroded: multiplied by E = 1 / (1 + c), c growing with the factor's
	             slope, so flanks flatten while crests and troughs keep their height. The hill types
	             also squash positive factor values, which gives them plateau tops.
	  rivers     Valleys dug to below sea level along the zero contour of an independent noise,
	             through hills and plains and on into the sea.
	  mapping    y = SEA + 450 (H - H_SEA) above sea level and SEA + 524 (H - H_SEA) below it: the
	             datapack's world is ~2100 blocks tall, ours 1024, so heights are scaled by SCALE
	             (0.43) on land, and by the same SCALE horizontally so slopes keep their steepness.

	Far LOD chunks (`level` > 0) leave out jagged octaves narrower than two of their cells, which
	would only alias. That moves heights by up to ~3 blocks at level 2 and ~12 at level 4; at levels
	5-6 (cells 32-64 wide but still 16 tall) all jagged detail of the mountains is gone and heights
	move by up to ~30 blocks, less than resampling the terrain at those widths does anyway.
]]

local Config = require(script.Parent.Parent.Config)
local Noise = require(script.Parent.Noise)

local SEA = Config.SeaLevel

-- Horizontal and vertical scale relative to the datapack.
local SCALE = 0.43
local INV_SCALE = 1 / SCALE
-- H of the datapack's sea level (y 63 of -64..2032), and blocks per H above / below it.
local H_SEA = -0.8788
local LAND_BLOCKS = 450
local DEEP_BLOCKS = 524

-- Selector: wavelength (datapack blocks) and spread, calibrated so the terrain types cover the
-- same share of the map as in the datapack (see tests/spec/Generation).
local SELECTOR_WAVELENGTH = 256 / 0.006
local SELECTOR_STD = 0.34
local WARP_WAVELENGTH = 256 / 0.008

-- Type knots of the selector spline.
local KNOTS = { 0, 0.075, 0.15, 0.225, 0.3, 0.4 }

-- Rivers: wavelength of the river noise (our blocks), half width of a valley at its rim (blocks),
-- bed height, and the selector range they fade in over (hills and lower).
local RIVER_WAVELENGTH = 9000
local RIVER_STD = 0.33
-- Bound on |gradient| of the river noise per block (measured maximum ~14.4 std / wavelength over
-- the whole noise period), and the step its gradient is measured over (blocks).
local RIVER_MAX_GRADIENT = 16 * RIVER_STD / RIVER_WAVELENGTH
local RIVER_STEP = 8
local RIVER_VALLEY = 300
local RIVER_BED = SEA - 14
local RIVER_FADE_START, RIVER_FADE_END = 0.17, 0.23

-- Std of Minecraft's noises (measured): cave_layer (1 octave), gravel (4), jagged (16).
local STD_CL, STD_GRAVEL, STD_JAGGED = 0.314, 0.307, 0.341
local JAGGED_OCTAVES = 7

local MAX_LEVEL = Config.Lod.Levels - 1

local abs = math.abs
local sqrt = math.sqrt

local function smoothstep01(t: number): number
	if t <= 0 then
		return 0
	elseif t >= 1 then
		return 1
	end
	return t * t * (3 - 2 * t)
end

export type Relief = {
	--[[
		Surface height (first air block, fractional) of column (x, z) as seen by LOD `level`, the
		height without rivers (biomes are picked from it, so river beds belong to their banks), the
		signed selector (very negative in the middle of some seas: mushroom isles grow there), and
		how much of a river valley the column is in (0 = none, 1 = the middle).
	]]
	height: (x: number, z: number, level: number) -> (number, number, number, number),
	-- The selector alone (cheap): a = |selector| is the terrain type, see the header.
	selector: (x: number, z: number) -> number,
}

local Relief = {}

Relief.SCALE = SCALE
Relief.KNOTS = KNOTS

-- Datapack height H -> block height.
function Relief.toY(h: number): number
	if h >= H_SEA then
		return SEA + LAND_BLOCKS * (h - H_SEA)
	end
	return SEA + DEEP_BLOCKS * (h - H_SEA)
end
local toY = Relief.toY

-- Block height -> datapack height H (inverse of toY).
function Relief.toH(y: number): number
	if y >= SEA then
		return H_SEA + (y - SEA) / LAND_BLOCKS
	end
	return H_SEA + (y - SEA) / DEEP_BLOCKS
end

-- Blocks per H on land: depths below the surface in H (caves) are depth / LAND_BLOCKS.
Relief.LAND_BLOCKS = LAND_BLOCKS

-- Jagged octaves a level keeps: those at least two cells wide (`wavelength` in datapack blocks).
local function octaveLimits(wavelength: number): { number }
	local limits = {}
	for level = 0, MAX_LEVEL do
		local cell = 2 ^ level
		local keep = 0
		local w = wavelength * SCALE
		while keep < JAGGED_OCTAVES and w >= 2 * cell do
			keep += 1
			w /= 2
		end
		limits[level] = keep
	end
	return limits
end

function Relief.new(seed: number): Relief
	local selectorNoise = Noise.double2(seed, "relief.selector", SELECTOR_WAVELENGTH, SELECTOR_STD)
	local warpNoise = Noise.octaves2(seed, "relief.warp", WARP_WAVELENGTH, 4, STD_GRAVEL)

	-- Per type: offset noise (cave_layer), factor (gravel) and jagged noise. Wavelengths are the
	-- datapack's (256 / xz_scale, 65536 / xz_scale for jagged).
	local function offsetNoise(name: string, xz: number)
		return Noise.octaves2(seed, "relief.offset." .. name, 256 / xz, 1, STD_CL)
	end
	local function factorNoise(name: string, xz: number)
		return Noise.octaves2(seed, "relief.factor." .. name, 256 / xz, 4, STD_GRAVEL)
	end
	local function jaggedNoise(name: string, xz: number)
		return Noise.octaves2(seed, "relief.jagged." .. name, 65536 / xz, JAGGED_OCTAVES, STD_JAGGED),
			octaveLimits(65536 / xz)
	end

	local emOffset, emFactor = offsetNoise("extremeMountains", 0.25), factorNoise("extremeMountains", 0.12)
	local emJagged, emLimits = jaggedNoise("extremeMountains", 600)
	local mOffset, mFactor = offsetNoise("mountains", 0.3), factorNoise("mountains", 0.11)
	local mJagged, mLimits = jaggedNoise("mountains", 501)
	local ehOffset, ehFactor = offsetNoise("extremeHills", 0.2), factorNoise("extremeHills", 0.25)
	local ehJagged, ehLimits = jaggedNoise("extremeHills", 300)
	local hOffset = offsetNoise("hills", 0.15)
	local hJagged, hLimits = jaggedNoise("hills", 250)
	local pOffset = offsetNoise("plains", 0.1)
	local pJagged, pLimits = jaggedNoise("plains", 500)
	local oOffset, oFactor = offsetNoise("ocean", 0.2), factorNoise("ocean", 0.05)
	local oJagged, oLimits = jaggedNoise("ocean", 175)

	-- River noise (our blocks), with a little wobble so valleys meander.
	local riverNoise = Noise.double2(seed, "relief.river", RIVER_WAVELENGTH, RIVER_STD)
	local riverWobble = Noise.octaves2(seed, "relief.riverWobble", RIVER_WAVELENGTH / 4, 2, RIVER_STD * 0.08)
	local function riverValue(x: number, z: number): number
		return riverNoise(x, z) + riverWobble(x, z)
	end

	-- Mountain erosion: the factor and E from its slope over one noise unit (1 / xz blocks),
	-- c = 1000 |dg|^2.
	local function mountainFactor(noise: Noise.OctaveSampler2, u: number, v: number, d: number): (number, number)
		local g = noise(u, v)
		local gx, gz = noise(u + d, v) - g, noise(u, v + d) - g
		local c = 1000 * (gx * gx + gz * gz)
		if c > 1.5 then
			c = 1.5
		end
		return g, 1 / (1 + c)
	end

	--[[
		Hill factor (shared by extreme hills and hills, as in the datapack): troughs below -0.2 keep
		their depth, values above 0.2 are squashed to 0.3 g E with c = 80 |dg|, smoothstep between.
		Returns the eroded factor and the raw one (it sets the jagged amplitude).
	]]
	local function hillFactor(u: number, v: number): (number, number)
		local d = 1 / 0.25
		local g = ehFactor(u, v)
		if g <= -0.2 then
			return g, g
		end
		local gx, gz = ehFactor(u + d, v) - g, ehFactor(u, v + d) - g
		local c = 80 * sqrt(gx * gx + gz * gz)
		if c > 1.5 then
			c = 1.5
		end
		local squashed = 0.3 * g / (1 + c)
		if g >= 0.2 then
			return squashed, g
		end
		return g + (squashed - g) * smoothstep01((g + 0.2) / 0.4), g
	end

	-- Jagged amplitude: from `low` where the factor is -0.3 to `high` where it is 0.3.
	local function jaggedAmplitude(g: number, low: number, high: number): number
		return low + (high - low) * smoothstep01((g + 0.3) / 0.6)
	end

	-- Height (H) of terrain type `index` (1 = extreme mountains ... 6 = ocean).
	local function typeHeight(index: number, u: number, v: number, level: number): number
		if index == 1 then
			local g, e = mountainFactor(emFactor, u, v, 1 / 0.12)
			return 0.3
				+ 0.2 * emOffset(u, v)
				+ 0.8 * g * e
				+ emJagged(u, v, emLimits[level]) * jaggedAmplitude(g, 0.04, 0.05)
		elseif index == 2 then
			local g, e = mountainFactor(mFactor, u, v, 1 / 0.11)
			return 0.2 * mOffset(u, v) + 0.7 * g * e + mJagged(u, v, mLimits[level]) * jaggedAmplitude(g, 0.035, 0.045)
		elseif index == 3 then
			local x, g = hillFactor(u, v)
			return -0.2
				+ 0.4 * ehOffset(u, v)
				+ 0.3 * x
				+ ehJagged(u, v, ehLimits[level]) * jaggedAmplitude(g, 0.03, 0.06)
		elseif index == 4 then
			local x, g = hillFactor(u, v)
			return -0.5
				+ 0.25 * hOffset(u, v)
				+ 0.2 * x
				+ hJagged(u, v, hLimits[level]) * jaggedAmplitude(g, 0.03, 0.06)
		elseif index == 5 then
			return -0.8 + 0.1 * pOffset(u, v) + 0.015 * pJagged(u, v, pLimits[level])
		end
		return -0.9 + 0.09 * oOffset(u, v) + 0.05 * oFactor(u, v) + 0.015 * oJagged(u, v, oLimits[level])
	end

	-- Selector, warped by up to 0.5 * warp noise where it is near zero (|det| < 0.2, fading out to 0.35).
	local function selector(x: number, z: number): number
		local u, v = x * INV_SCALE, z * INV_SCALE
		local det = selectorNoise(u, v)
		local near = abs(det)
		if near >= 0.35 then
			return det
		end
		local warped = det + 0.5 * warpNoise(u, v)
		if near <= 0.2 then
			return warped
		end
		return warped + (det - warped) * smoothstep01((near - 0.2) / 0.15)
	end

	local function height(x: number, z: number, level: number): (number, number, number, number)
		local u, v = x * INV_SCALE, z * INV_SCALE
		local s = selector(x, z)
		local a = abs(s)

		local h
		if a >= KNOTS[6] then
			h = typeHeight(6, u, v, level)
		else
			local i = 1
			while a >= KNOTS[i + 1] do
				i += 1
			end
			local t = smoothstep01((a - KNOTS[i]) / (KNOTS[i + 1] - KNOTS[i]))
			if t <= 0 then
				h = typeHeight(i, u, v, level)
			elseif t >= 1 then
				h = typeHeight(i + 1, u, v, level)
			else
				local h0 = typeHeight(i, u, v, level)
				h = h0 + (typeHeight(i + 1, u, v, level) - h0) * t
			end
		end
		local y = toY(h)

		-- Rivers: a smoothstep valley around the river noise's zero contour, dug down to RIVER_BED.
		local river = 0
		if a > RIVER_FADE_START then
			local r = riverValue(x, z)
			-- Columns this far from zero are outside every valley (|gradient| stays below RIVER_MAX_GRADIENT).
			if abs(r) < RIVER_VALLEY * RIVER_MAX_GRADIENT then
				-- Distance to the contour ~ |r| / |gradient r|, which keeps valleys equally wide everywhere.
				local gx = riverValue(x + RIVER_STEP, z) - r
				local gz = riverValue(x, z + RIVER_STEP) - r
				local distance = abs(r) * RIVER_STEP / math.max(sqrt(gx * gx + gz * gz), 1e-9)
				if distance < RIVER_VALLEY then
					river = smoothstep01(1 - distance / RIVER_VALLEY)
						* smoothstep01((a - RIVER_FADE_START) / (RIVER_FADE_END - RIVER_FADE_START))
				end
			end
		end
		if river > 0 and y > RIVER_BED then
			return y - (y - RIVER_BED) * river, y, s, river
		end
		return y, y, s, river
	end

	return {
		height = height,
		selector = selector,
	}
end

return Relief

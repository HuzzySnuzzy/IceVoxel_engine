--!strict
--!native
--[[
	Deterministic terrain generator.

	`TerrainGenerator.new(seed)` returns a generator whose results depend only on the seed and the
	coordinates, so the server, every client and every worker actor produce identical worlds without
	sending any terrain over the network. Only player edits are replicated.

	Terrain shape
	  continentalness  low frequency noise deciding ocean / coast / inland (a spline maps it to a
	                   base height),
	  mountains        where it is high (and we are inland), ridged noise raises mountain ranges,
	  hills            rolling noise whose amplitude comes from the blended biomes,
	  biomes           weighted by distance in (temperature, humidity) space; their height offset,
	                   hilliness and vegetation density are averaged with those weights, so biome
	                   borders blend smoothly.

	Chunks (see World/ChunkLayout)
	  `generate(level, nx, nz)` fills a padded column. Level 0 is full detail; level L samples the
	  same terrain every 2^L blocks horizontally (and every min(2^L, Lod.MaxVerticalStep) blocks
	  vertically), which is what makes far LOD chunks cheap to generate.

	  LOD chunks lower their border (padding) columns by one cell. A coarse chunk next to a finer
	  one would otherwise hide border cells the finer neighbour leaves exposed, which shows up as
	  thin cracks at LOD boundaries; this "skirt" makes those cells visible.
]]

local Config = require(script.Parent.Parent.Config)
local Blocks = require(script.Parent.Parent.Blocks)
local Biomes = require(script.Parent.Parent.Biomes)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)
local Noise = require(script.Parent.Noise)
local Caves = require(script.Parent.Caves)
local Ores = require(script.Parent.Ores)
local Structures = require(script.Parent.Structures)
local Writer = require(script.Parent.Structures.Writer)

local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED
local LAYER = ChunkLayout.LAYER
local WORLD_HEIGHT = Config.WorldHeight
local SEA = Config.SeaLevel

-- Tuning --------------------------------------------------------------------------------------------
local BIOME_SHARPNESS = 1 / (0.3 * 0.3) -- 1 / sigma^2 of the biome weight gaussian
local BORDER_JITTER = 0.07 -- climate noise added when picking the surface biome
local LAPSE_RATE = 1 / 110 -- temperature drop per block above SEA + 40
local MOUNTAIN_HEIGHT = 105
local SNOW_LINE = SEA + 100
local TREE_LINE_START, TREE_LINE_END = SEA + 60, SEA + 85
local CLIMATE_SPREAD = 1.7 -- stretches climate noise so the outer biomes are reached as often as the inner ones
local COAST = -0.04 -- continentalness below which low land becomes beach
local CLIFF_SLOPE = 3 -- height difference (blocks per block) that turns the surface into stone

local exp = math.exp
local floor = math.floor
local huge = math.huge
local writeu16 = buffer.writeu16

local id = Blocks.id
local BEDROCK, STONE, GRAVEL, SNOW, ICE = id.Bedrock, id.Stone, id.Gravel, id.Snow, id.Ice
local WATER = Blocks.fluidId("Water", 0)

local biomeCount = Biomes.count
local biomeTemp: { number }, biomeHum: { number } = {}, {}
local biomeOffset: { number }, biomeHills: { number }, biomeVeg: { number } = {}, {}, {}
for i, biome in Biomes.list do
	biomeTemp[i], biomeHum[i] = biome.temperature, biome.humidity
	biomeOffset[i], biomeHills[i], biomeVeg[i] = biome.heightOffset, biome.hilliness, biome.vegetation
end

local function smoothstep(edge0: number, edge1: number, x: number): number
	local t = (x - edge0) / (edge1 - edge0)
	if t <= 0 then
		return 0
	elseif t >= 1 then
		return 1
	end
	return t * t * (3 - 2 * t)
end

-- Continentalness -> base height relative to sea level (piecewise linear spline).
local SPLINE_X = { -1.0, -0.55, -0.3, -0.15, 0.0, 0.45, 1.0 }
local SPLINE_Y = { -40, -34, -14, -2, 4, 14, 26 }
local function continentalHeight(c: number): number
	if c <= SPLINE_X[1] then
		return SPLINE_Y[1]
	end
	for i = 2, #SPLINE_X do
		if c <= SPLINE_X[i] then
			local t = (c - SPLINE_X[i - 1]) / (SPLINE_X[i] - SPLINE_X[i - 1])
			return SPLINE_Y[i - 1] + (SPLINE_Y[i] - SPLINE_Y[i - 1]) * t
		end
	end
	return SPLINE_Y[#SPLINE_Y]
end

export type ChunkResult = {
	data: buffer,
	level: number,
	nx: number,
	nz: number,
	-- Cells per column.
	height: number,
	-- Every padded cell below this is opaque or cave air.
	solidBelow: number,
	-- Every cell at or above this is air.
	emptyAbove: number,
}

export type Generator = {
	seed: number,
	-- Terrain height (first air block), surface biome index, vegetation chance, surface block.
	column: (x: number, z: number) -> (number, number, number, number),
	-- `yield` is called regularly so callers can spread the work over several frames.
	generate: (level: number, nx: number, nz: number, yield: (() -> ())?) -> ChunkResult,
	-- A dry land column near the origin: x, height, z.
	findSpawn: () -> (number, number, number),
}

local TerrainGenerator = {}

function TerrainGenerator.new(seed: number): Generator
	local temperature = Noise.fbm2(seed, "climate.temperature", 1 / 1100, 3)
	local humidity = Noise.fbm2(seed, "climate.humidity", 1 / 900, 3)
	local continental = Noise.fbm2(seed, "terrain.continental", 1 / 1600, 4)
	local mountains = Noise.fbm2(seed, "terrain.mountains", 1 / 1000, 3)
	local ridges = Noise.ridged2(seed, "terrain.ridges", 1 / 380, 5, 0.5)
	local hills = Noise.fbm2(seed, "terrain.hills", 1 / 170, 4, 0.5)
	local jitterT = Noise.fbm2(seed, "climate.jitterT", 1 / 24, 2)
	local jitterH = Noise.fbm2(seed, "climate.jitterH", 1 / 24, 2)
	local snowNoise = Noise.fbm2(seed, "terrain.snow", 1 / 40, 2)

	local carveCaves = Caves.new(seed)

	-- Returns height (first air block), surface biome, vegetation chance, surface block, continentalness.
	local function sample(x: number, z: number): (number, number, number, number, number)
		local t = math.clamp(temperature(x, z) * CLIMATE_SPREAD, -1, 1)
		local m = math.clamp(humidity(x, z) * CLIMATE_SPREAD, -1, 1)
		local c = continental(x, z)

		-- Blend biome terrain properties by climate distance.
		local wsum, offset, hilliness, vegetation = 0, 0, 0, 0
		for i = 1, biomeCount do
			local dt, dm = t - biomeTemp[i], m - biomeHum[i]
			local w = exp(-(dt * dt + dm * dm) * BIOME_SHARPNESS)
			wsum += w
			offset += w * biomeOffset[i]
			hilliness += w * biomeHills[i]
			vegetation += w * biomeVeg[i]
		end
		wsum = 1 / wsum
		offset *= wsum
		hilliness *= wsum
		vegetation *= wsum

		local land = smoothstep(-0.28, -0.08, c)
		local h = SEA + continentalHeight(c) + offset * land + hills(x, z) * (4 + (hilliness - 4) * land)
		local mountainness = smoothstep(0.04, 0.4, mountains(x, z)) * smoothstep(-0.15, 0.2, c)
		if mountainness > 0 then
			h += mountainness * (6 + ridges(x, z) * MOUNTAIN_HEIGHT)
		end
		h = floor(h)
		if h < 2 then
			h = 2
		elseif h > WORLD_HEIGHT - 24 then
			h = WORLD_HEIGHT - 24
		end

		-- Surface biome: nearest biome to a slightly jittered climate. Colder higher up.
		local st = t + jitterT(x, z) * BORDER_JITTER
		if h > SEA + 40 then
			st -= (h - SEA - 40) * LAPSE_RATE
		end
		local sm = m + jitterH(x, z) * BORDER_JITTER
		local biome, best = 1, huge
		for i = 1, biomeCount do
			local dt, dm = st - biomeTemp[i], sm - biomeHum[i]
			local d = dt * dt + dm * dm
			if d < best then
				best, biome = d, i
			end
		end

		local def = Biomes.list[biome]
		local surface
		if h < SEA then
			surface = if SEA - h > 14 then GRAVEL else def.underwater
		elseif h <= SEA + 2 and c < COAST then
			surface = def.beach
		elseif h >= SNOW_LINE - 8 and h >= SNOW_LINE + snowNoise(x, z) * 8 then
			surface = SNOW
		else
			surface = def.top
		end

		if h <= SEA then
			vegetation = 0
		elseif h > TREE_LINE_START then
			vegetation *= 1 - smoothstep(TREE_LINE_START, TREE_LINE_END, h)
		end

		return h, biome, vegetation, surface, c
	end

	local function column(x: number, z: number): (number, number, number, number)
		local h, biome, vegetation, surface = sample(x, z)
		return h, biome, vegetation, surface
	end

	-- Per-column scratch arrays, reused between chunks (each worker actor has its own copy).
	local heights: { number } = table.create(P * P, 0)
	local biomes: { number } = table.create(P * P, 1)
	local surfaces: { number } = table.create(P * P, 0)

	local function generate(level: number, nx: number, nz: number, yield: (() -> ())?): ChunkResult
		local step, stepY = ChunkLayout.steps(level)
		local half, halfY = step // 2, stepY // 2
		local cells = WORLD_HEIGHT // stepY
		local originX, originZ = nx * SIZE * step, nz * SIZE * step
		local data = ChunkLayout.create(cells)

		-- 1. Sample every padded column at its cell center.
		for pz = 0, P - 1 do
			local wz = originZ + (pz - 1) * step + half
			for px = 0, P - 1 do
				local h, biome, _, surface = sample(originX + (px - 1) * step + half, wz)
				local i = pz * P + px + 1
				heights[i], biomes[i], surfaces[i] = h, biome, surface
			end
			if yield and pz % 6 == 5 then
				yield()
			end
		end

		-- 2. Fill the columns.
		local solidBelow, emptyAbove = cells, 0
		local waterTop = (SEA - halfY + stepY - 1) // stepY - 1 -- highest cell whose sample is below sea level
		local stride = LAYER * 2
		for pz = 0, P - 1 do
			for px = 0, P - 1 do
				local i = pz * P + px + 1
				local h = heights[i]
				local biome = Biomes.list[biomes[i]]
				local top = surfaces[i]
				local filler = if top == biome.top then biome.filler else top
				local fillerDepth = biome.fillerDepth

				-- Steep slopes become bare stone.
				if h > SEA + 2 then
					local slope = 0
					if px > 0 then
						slope = math.max(slope, math.abs(h - heights[i - 1]))
					end
					if px < P - 1 then
						slope = math.max(slope, math.abs(h - heights[i + 1]))
					end
					if pz > 0 then
						slope = math.max(slope, math.abs(h - heights[i - P]))
					end
					if pz < P - 1 then
						slope = math.max(slope, math.abs(h - heights[i + P]))
					end
					if slope >= CLIFF_SLOPE * step then
						top, filler = STONE, STONE
					end
				end

				local topCell = (h - halfY + stepY - 1) // stepY - 1
				if level > 0 and (px == 0 or pz == 0 or px == P - 1 or pz == P - 1) and topCell > 1 then
					topCell -= 1
				end
				local base = (pz * P + px) * 2
				writeu16(data, base, BEDROCK)
				for y = 1, topCell do
					local depth = (topCell - y) * stepY
					local block = if depth == 0 then top elseif depth <= fillerDepth then filler else STONE
					writeu16(data, base + y * stride, block)
				end
				if topCell + 1 < solidBelow then
					solidBelow = topCell + 1
				end

				local columnTop = topCell + 1
				if topCell < waterTop then
					for y = topCell + 1, waterTop do
						writeu16(data, base + y * stride, WATER)
					end
					if biome.frozen then
						writeu16(data, base + waterTop * stride, ICE)
					end
					columnTop = waterTop + 1
				end
				if columnTop > emptyAbove then
					emptyAbove = columnTop
				end
			end
		end
		if yield then
			yield()
		end

		-- 3. Caves and ores only exist in full detail chunks.
		if level == 0 then
			if Config.Caves.Enabled then
				carveCaves(data, originX, originZ, heights)
				if yield then
					yield()
				end
			end
			Ores.place(data, seed, nx, nz, cells)
		end

		-- 4. Trees and other structures.
		if level <= Config.StructureMaxLevel then
			local w = Writer.new(data, originX, originZ, step, stepY, cells)
			local span = SIZE * step
			Structures.populate(
				seed,
				column,
				w,
				originX - step,
				originZ - step,
				originX + span + step - 1,
				originZ + span + step - 1
			)
			if w.top() > emptyAbove then
				emptyAbove = w.top()
			end
		end

		return {
			data = data,
			level = level,
			nx = nx,
			nz = nz,
			height = cells,
			solidBelow = solidBelow,
			emptyAbove = emptyAbove,
		}
	end

	local function findSpawn(): (number, number, number)
		-- Walk an outward square spiral until we find dry land that is not a beach or a cliff.
		local x, z, dx, dz = 0, 0, 0, -1
		for _ = 1, 4096 do
			local h, _, _, surface, c = sample(x * 8, z * 8)
			if h > SEA + 2 and c > COAST and surface ~= SNOW then
				return x * 8, h, z * 8
			end
			if x == z or (x < 0 and x == -z) or (x > 0 and x == 1 - z) then
				dx, dz = -dz, dx
			end
			x, z = x + dx, z + dz
		end
		local h = sample(0, 0)
		return 0, h, 0
	end

	return {
		seed = seed,
		column = column,
		generate = generate,
		findSpawn = findSpawn,
	}
end

return TerrainGenerator

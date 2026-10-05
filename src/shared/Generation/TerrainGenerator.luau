--!strict
--!native
--[[
	Deterministic terrain generator.

	`TerrainGenerator.new(seed)` returns a generator whose results depend only on the seed and the
	coordinates, so the server, every client and every worker actor produce identical worlds without
	sending any terrain over the network. Only player edits are replicated.

	Terrain shape (Relief.luau): huge mountain ranges, hills, plains, river valleys and enclosed seas
	in the style of the JJThunder To The Max datapack; one height per column.

	Biomes (Biomes/BiomeList.luau) are picked by altitude band first (lowland, forest, highland,
	meadow, alpine, snowy slopes, peaks), then by climate (temperature and humidity noise) among
	the biomes of that band. Islands far out in some seas are mushroom fields.

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
local Relief = require(script.Parent.Relief)
local Caves = require(script.Parent.Caves)
local Ores = require(script.Parent.Ores)
local Foliage = require(script.Parent.Foliage)
local CaveDecor = require(script.Parent.CaveDecor)
local StructureGen = require(script.Parent.StructureGen)
local Structures = require(script.Parent.Structures)
local Writer = require(script.Parent.Structures.Writer)
local Library = require(script.Parent.Parent.Structures.Library)

local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED
local LAYER = ChunkLayout.LAYER
local WORLD_HEIGHT = Config.WorldHeight
-- Blocks above the terrain kept in a chunk's buffer for structures (trees).
local STRUCTURE_ROOM = 32
local SEA = Config.SeaLevel

-- Tuning --------------------------------------------------------------------------------------------
local CLIMATE_SPREAD = 1.7 -- stretches climate noise so the outer biomes are reached as often as the inner ones
local BORDER_JITTER = 0.07 -- climate noise added when picking the biome
local BAND_JITTER = 12 -- altitude noise (blocks) added when picking the band
local CLIFF_SLOPE = 1.6 -- slope (blocks per block) above which the surface is bare rock (Biome.steep)
local MUSHROOM_SELECTOR = -0.475 -- selector below which islands are mushroom fields
local RIVER_MUD = 0.3 -- river strength (Relief) from which a river bed is packed mud
local DEEP_WATER = 14 -- sea floor deeper than this is gravel

local floor = math.floor
local huge = math.huge
local writeu16 = buffer.writeu16

local id = Blocks.id
local BEDROCK, STONE, GRAVEL, SNOW, ICE = id.Bedrock, id.Stone, id.Gravel, id.Snow, id.Ice
local PACKED_MUD = id.PackedMud
local WATER = Blocks.fluidId("Water", 0)
local MUSHROOM = (Biomes.byName("MushroomFields") :: Biomes.Biome).index

local biomeTemp: { number }, biomeHum: { number } = {}, {}
-- Patch noise threshold of each biome (the patch noise has a standard deviation of 1/3; the
-- logistic approximation of the normal quantile is plenty for blotches).
local patchThreshold: { number } = {}
for i, biome in Biomes.list do
	biomeTemp[i], biomeHum[i] = biome.temperature, biome.humidity
	local cover = math.clamp(biome.patchCover, 1e-3, 1 - 1e-3)
	patchThreshold[i] = if biome.patch ~= 0 then math.log((1 - cover) / cover) / 1.702 / 3 else huge
end
local inBand = Biomes.inBand
-- Deepest filler of any biome (blocks): below that every column is stone.
local MAX_FILLER = 0
for _, biome in Biomes.list do
	MAX_FILLER = math.max(MAX_FILLER, biome.fillerDepth)
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
	-- A spawn column: low, dry, gentle land near the hills. x, height, z.
	findSpawn: () -> (number, number, number),
	--[[
		Seam limits for the mesher (GreedyMesher.Border.open) of node (level, nx, nz), given the
		level of the coarser node on each side (-X, +X, -Z, +Z; 0 = none). nil when no side has one.
	]]
	seamLimits: (level: number, nx: number, nz: number, coarser: { number }) -> buffer?,
	--[[
		Items a generated container (a chest in a library structure) at world (x, y, z) starts
		with, nil when the generator put none there: the server fills a generated chest from it the
		first time its contents are needed. A fresh copy each call.
	]]
	structureContainer: (x: number, y: number, z: number) -> { StructureGen.ContainerItem }?,
	-- Every generated structure with a piece in the block rectangle (inclusive), in write order.
	structures: (minX: number, minZ: number, maxX: number, maxZ: number) -> { StructureGen.Start },
	--[[
		Seam limits of a far node (level >= 1) that hold whatever its neighbours are: the LOD tree
		only ever puts a node next to nodes at most one level coarser, so opening the padding for a
		one and a two levels coarser neighbour on every side (the lower of the two) covers every
		case. Far nodes then never need to be rebuilt when their neighbours change. nil for the
		coarsest level.
	]]
	farSeamLimits: (level: number, nx: number, nz: number) -> buffer?,
}

--[[
	`library`: the structure library to generate (default: Library.load() when
	Config.Structures.Generate); `structures = false`: no library structures at all.
]]
export type Options = {
	library: Library.Library?,
	structures: boolean?,
}

local TerrainGenerator = {}

function TerrainGenerator.new(seed: number, options: Options?): Generator
	local relief = Relief.new(seed)
	local temperature = Noise.fbm2(seed, "climate.temperature", 1 / 5900, 3)
	local humidity = Noise.fbm2(seed, "climate.humidity", 1 / 1500, 3)
	local jitterT = Noise.fbm2(seed, "climate.jitterT", 1 / 24, 2)
	local jitterH = Noise.fbm2(seed, "climate.jitterH", 1 / 24, 2)
	local bandJitter = Noise.fbm2(seed, "climate.band", 1 / 24, 2)
	local patchNoise = Noise.fbm2(seed, "surface.patches", 1 / 10, 2)

	local carveCaves = Caves.new(seed, function(x: number, z: number): number
		return (relief.height(x, z, 0))
	end)
	local growFoliage = Foliage.new(seed)
	local growLichen = CaveDecor.new(seed)

	-- Terrain height (first air block) of a relief height: whole blocks, with room for structures.
	local function clampHeight(y: number): number
		local h = floor(y)
		if h < 2 then
			return 2
		elseif h > WORLD_HEIGHT - STRUCTURE_ROOM then
			return WORLD_HEIGHT - STRUCTURE_ROOM
		end
		return h
	end

	--[[
		Column (x, z) as seen by LOD `level`: height (first air block), biome, vegetation chance,
		surface block, the relief's selector and river strength.
	]]
	local function sample(x: number, z: number, level: number): (number, number, number, number, number, number)
		local y, unrivered, selector, river = relief.height(x, z, level)
		local h = clampHeight(y)

		local biome = MUSHROOM
		if selector >= MUSHROOM_SELECTOR then
			-- Altitude band, then the biome of that band nearest to a slightly jittered climate.
			local band = Biomes.bandAt(unrivered + bandJitter(x, z) * BAND_JITTER)
			local t = math.clamp(temperature(x, z) * CLIMATE_SPREAD, -1, 1) + jitterT(x, z) * BORDER_JITTER
			local m = math.clamp(humidity(x, z) * CLIMATE_SPREAD, -1, 1) + jitterH(x, z) * BORDER_JITTER
			local best = huge
			for _, i in inBand[band] do
				local dt, dm = t - biomeTemp[i], m - biomeHum[i]
				local d = dt * dt + dm * dm
				if d < best then
					best, biome = d, i
				end
			end
		end

		local def = Biomes.list[biome]
		local surface
		if h < SEA then
			surface = if river >= RIVER_MUD then PACKED_MUD elseif SEA - h > DEEP_WATER then GRAVEL else def.underwater
		elseif h <= SEA + 2 then
			surface = def.beach
		elseif patchNoise(x, z) > patchThreshold[biome] then
			surface = def.patch
		else
			surface = def.top
		end

		local vegetation = if h <= SEA + 1 or river >= RIVER_MUD then 0 else def.vegetation
		return h, biome, vegetation, surface, selector, river
	end

	-- Full detail height of a column just outside a chunk's padding (see the steep rule).
	local function outsideHeight(x: number, z: number): number
		return clampHeight((relief.height(x, z, 0)))
	end

	local function column(x: number, z: number): (number, number, number, number)
		local h, biome, vegetation, surface = sample(x, z, 0)
		return h, biome, vegetation, surface
	end

	-- Can a tree grow at (x, z)? Not where `generate` turns the surface into bare rock (steep rule,
	-- with full detail heights so every level and chunk agrees).
	local function gentle(x: number, z: number, biome: number): boolean
		local h = column(x, z)
		local limit = Biomes.list[biome].steepSlope or CLIFF_SLOPE
		return math.abs(column(x - 1, z) - h) < limit
			and math.abs(column(x + 1, z) - h) < limit
			and math.abs(column(x, z - 1) - h) < limit
			and math.abs(column(x, z + 1) - h) < limit
	end

	-- Library structures (nil: none to place).
	local opts: Options = options or {}
	local library = opts.library
	if library == nil and opts.structures ~= false and Config.Structures.Generate then
		library = Library.load()
	end
	local placer: StructureGen.Placer? = nil
	if library and opts.structures ~= false and #library.structures > 0 then
		local function firstFreeHeight(x: number, z: number): number
			-- Minecraft's WORLD_SURFACE_WG: the sea's surface counts as ground.
			return math.max(outsideHeight(x, z), SEA)
		end
		placer = StructureGen.new(seed, library, {
			firstFreeHeight = firstFreeHeight,
			biome = function(x: number, z: number): number
				local _, biome = sample(x, z, 0)
				return biome
			end,
			-- Dry land that `generate` doesn't turn into bare rock.
			land = function(x: number, z: number): boolean
				local h, biome = column(x, z)
				return h > SEA and gentle(x, z, biome)
			end,
		})
	end

	-- Per-column scratch arrays, reused between chunks (each worker actor has its own copy).
	local heights: { number } = table.create(P * P, 0)
	local biomes: { number } = table.create(P * P, 1)
	local surfaces: { number } = table.create(P * P, 0)
	local topCells: { number } = table.create(P * P, 0)

	local function generate(level: number, nx: number, nz: number, yield: (() -> ())?): ChunkResult
		local step, stepY = ChunkLayout.steps(level)
		local half, halfY = step // 2, stepY // 2
		local originX, originZ = nx * SIZE * step, nz * SIZE * step

		-- 1. Sample every padded column at its cell center.
		local highest = SEA
		for pz = 0, P - 1 do
			local wz = originZ + (pz - 1) * step + half
			for px = 0, P - 1 do
				local h, biome, _, surface = sample(originX + (px - 1) * step + half, wz, level)
				local i = pz * P + px + 1
				heights[i], biomes[i], surfaces[i] = h, biome, surface
				if h > highest then
					highest = h
				end
			end
			if yield and pz % 6 == 5 then
				yield()
			end
		end

		-- Library structures reaching the padded chunk, or a vegetation spot near it (see
		-- StructureGen: trees keep clear of their pieces).
		local span = SIZE * step
		local starts: { StructureGen.Start }? = nil
		local needed = (highest + STRUCTURE_ROOM + stepY - 1) // stepY
		if placer and level <= Config.StructureMaxLevel then
			local reach = 2 * Structures.RADIUS
			local x0, z0 = originX - step, originZ - step
			local x1, z1 = originX + span + step - 1, originZ + span + step - 1
			local found = placer.starts(x0 - reach, z0 - reach, x1 + reach, z1 + reach)
			if #found > 0 then
				starts = found
				-- Room for their highest block, plus a cell of air on top.
				local top = placer.top(found, x0, z0, x1, z1, math.max(highest, SEA))
				needed = math.max(needed, top // stepY + 2)
			end
		end

		-- The column buffer ends a little above the highest terrain (room for structures).
		local cells = ChunkLayout.croppedHeight(needed, stepY)
		local data = ChunkLayout.create(cells)

		-- 2. Fill the columns. Highest cell of each column (border columns of LOD chunks one lower,
		-- see the header).
		local allStone = huge
		for pz = 0, P - 1 do
			for px = 0, P - 1 do
				local i = pz * P + px + 1
				local topCell = (heights[i] - halfY + stepY - 1) // stepY - 1
				if level > 0 and (px == 0 or pz == 0 or px == P - 1 or pz == P - 1) and topCell > 1 then
					topCell -= 1
				end
				topCells[i] = topCell
				allStone = math.min(allStone, topCell - MAX_FILLER // stepY - 1)
			end
		end

		-- Bedrock, then every column is stone up to `allStone`: write that a whole layer at a time
		-- (a tall mountain chunk is mostly that).
		local stride = LAYER * 2
		for j = 0, LAYER - 1 do
			writeu16(data, j * 2, BEDROCK)
		end
		if allStone >= 1 then
			for j = 0, LAYER - 1 do
				writeu16(data, stride + j * 2, STONE)
			end
			for y = 2, allStone do
				buffer.copy(data, y * stride, data, stride, stride)
			end
		end
		local firstY = math.max(1, allStone + 1)

		local solidBelow, emptyAbove = cells, 0
		local waterTop = (SEA - halfY + stepY - 1) // stepY - 1 -- highest cell whose sample is below sea level
		for pz = 0, P - 1 do
			for px = 0, P - 1 do
				local i = pz * P + px + 1
				local h = heights[i]
				local biome = Biomes.list[biomes[i]]
				local top = surfaces[i]
				local filler = if top == biome.top then biome.filler else top
				local fillerDepth = biome.fillerDepth

				-- Steep slopes become bare rock. A full detail chunk's outermost columns also look
				-- past the padding for their missing neighbour, so they get the surface the
				-- neighbouring chunk's core gets (plants grow by it). (LOD padding is a lowered
				-- skirt anyway.)
				if h > SEA + 2 then
					local limit = (biome.steepSlope or CLIFF_SLOPE) * step
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
					local edge = px == 0 or px == P - 1 or pz == 0 or pz == P - 1
					if slope < limit and level == 0 and edge and (top ~= biome.steep or filler ~= biome.steep) then
						local x, z = originX + px - 1, originZ + pz - 1
						local dx = if px == 0 then -1 elseif px == P - 1 then 1 else 0
						local dz = if pz == 0 then -1 elseif pz == P - 1 then 1 else 0
						if dx ~= 0 then
							slope = math.max(slope, math.abs(h - outsideHeight(x + dx, z)))
						end
						if dz ~= 0 and slope < limit then
							slope = math.max(slope, math.abs(h - outsideHeight(x, z + dz)))
						end
					end
					if slope >= limit then
						top, filler = biome.steep, biome.steep
					end
				end

				local topCell = topCells[i]
				local base = (pz * P + px) * 2
				for y = firstY, topCell do
					local depth = (topCell - y) * stepY
					local block = if depth == 0 then top elseif depth <= fillerDepth then filler else STONE
					writeu16(data, base + y * stride, block)
				end
				if topCell + 1 < solidBelow then
					solidBelow = topCell + 1
				end

				local columnTop = topCell + 1
				if topCell < waterTop then
					-- (Deep trenches and coarse cells can put topCell below 0: keep the bedrock.)
					for y = math.max(topCell + 1, 1), waterTop do
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
		local carved: Caves.Carved? = nil
		if level == 0 then
			if Config.Caves.Enabled then
				carved = carveCaves(data, originX, originZ, heights, cells, yield)
				if yield then
					yield()
				end
			end
			Ores.place(data, seed, nx, nz, cells)
		end

		-- 4. Trees and other structures. On LOD chunks they are rooted on the chunk's own (coarser)
		-- terrain: the height of the cell their root is in, sampled like `generate` does.
		if level <= Config.StructureMaxLevel then
			local w = Writer.new(data, originX, originZ, step, stepY, cells)
			local structureColumn = column
			if level > 0 then
				structureColumn = function(x: number, z: number): (number, number, number, number)
					local _, biome, vegetation, surface = column(x, z)
					local h = sample(x // step * step + half, z // step * step + half, level)
					return h, biome, vegetation, surface
				end
			end
			local accept = gentle
			if placer and starts then
				local p, list = placer, starts
				accept = function(x: number, z: number, biome: number): boolean
					return gentle(x, z, biome) and p.treeAllowed(list, x, z)
				end
			end
			Structures.populate(
				seed,
				structureColumn,
				w,
				originX - step,
				originZ - step,
				originX + span + step - 1,
				originZ + span + step - 1,
				accept
			)
			if w.top() > emptyAbove then
				emptyAbove = w.top()
			end

			-- Library structures, after the trees: their air clears trees, their voids keep them.
			if placer and starts then
				local top, lowest = placer.write(starts, {
					data = data,
					cells = cells,
					level = level,
					originX = originX,
					originZ = originZ,
					biomes = biomes,
					topCells = topCells,
				})
				if top > emptyAbove then
					emptyAbove = top
				end
				if lowest < solidBelow then
					solidBelow = lowest
				end
			end
		end

		-- 5. Glow lichen on cave walls (full detail only, like the caves).
		if carved then
			growLichen(data, cells, originX, originZ, heights, carved)
		end

		-- 6. Ground plants (full detail only: LOD cells would lose them, and each box is a Part).
		if level == 0 then
			local top = growFoliage(data, cells, originX, originZ, biomes, topCells)
			if top > emptyAbove then
				emptyAbove = top
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

	local function seamLimits(level: number, nx: number, nz: number, coarser: { number }): buffer?
		local out: buffer? = nil
		local step, stepY = ChunkLayout.steps(level)
		local half = step // 2
		local originX, originZ = nx * SIZE * step, nz * SIZE * step
		for side = 1, 4 do
			local coarse = coarser[side]
			if coarse and coarse > level then
				local limits = out or buffer.create(4 * SIZE * 2)
				if out == nil then
					buffer.fill(limits, 0, 0xFF)
					out = limits
				end
				local cs, csY = ChunkLayout.steps(coarse)
				local halfC, halfCY = cs // 2, csY // 2
				for i = 0, SIZE - 1 do
					-- Sample point of the padding column, then the coarse cell containing it.
					local along = i * step + half
					local x, z
					if side == 1 then
						x, z = originX - step + half, originZ + along
					elseif side == 2 then
						x, z = originX + SIZE * step + half, originZ + along
					elseif side == 3 then
						x, z = originX + along, originZ - step + half
					else
						x, z = originX + along, originZ + SIZE * step + half
					end
					local h = sample((x // cs) * cs + halfC, (z // cs) * cs + halfC, coarse)
					-- Same rounding as `generate` at the coarse level: blocks below `solidTop` are drawn.
					local solidTop = ((h - halfCY + csY - 1) // csY) * csY
					writeu16(limits, ((side - 1) * SIZE + i) * 2, math.max(solidTop // stepY, 1))
				end
			end
		end
		return out
	end

	local function farSeamLimits(level: number, nx: number, nz: number): buffer?
		local maxLevel = Config.Lod.Levels - 1
		if level >= maxLevel then
			return nil
		end
		local up = level + 1
		local limits = seamLimits(level, nx, nz, { up, up, up, up }) :: buffer
		if level + 2 <= maxLevel then
			local up2 = level + 2
			local other = seamLimits(level, nx, nz, { up2, up2, up2, up2 }) :: buffer
			for i = 0, buffer.len(limits) - 2, 2 do
				local b = buffer.readu16(other, i)
				if b < buffer.readu16(limits, i) then
					buffer.writeu16(limits, i, b)
				end
			end
		end
		return limits
	end

	local function findSpawn(): (number, number, number)
		--[[
			Walk an outward square spiral (every SPAWN_STEP blocks) for the first gentle, dry,
			unfrozen column in the hills or plains next to the mountains: a view of the ranges without
			starting on a cliff. The cheap selector rules out most spots first. The search stays within
			SPAWN_RANGE of the origin, where float precision is fine. Some seeds put the origin in the
			middle of a sea with no such land in range: then any dry land in range is taken (an
			island), then any dry land further out, then the origin itself.
		]]
		local SPAWN_STEP, SPAWN_RANGE, FAR_RANGE = 64, 5000, 12800
		for pass = 1, 3 do
			local strict = pass == 1
			local rings = (if pass == 3 then FAR_RANGE else SPAWN_RANGE) // SPAWN_STEP
			local x, z, dx, dz = 0, 0, 0, -1
			for _ = 1, (2 * rings + 1) ^ 2 do
				local wx, wz = x * SPAWN_STEP, z * SPAWN_STEP
				local a = if strict then math.abs(relief.selector(wx, wz)) else 0.25
				if a > 0.2 and a < 0.32 then
					local h, biome, _, surface, _, river = sample(wx, wz, 0)
					local ok
					if strict then
						ok = h > SEA + 3
							and h < SEA + 160
							and river == 0
							and surface == Biomes.list[biome].top
							and surface ~= SNOW
					else
						ok = h > SEA + 1 and river < RIVER_MUD
					end
					if ok then
						for _, offset in { { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 } } do
							if math.abs(sample(wx + offset[1], wz + offset[2], 0) - h) > (if strict then 2 else 4) then
								ok = false
								break
							end
						end
						if ok then
							return wx, h, wz
						end
					end
				end
				if x == z or (x < 0 and x == -z) or (x > 0 and x == 1 - z) then
					dx, dz = -dz, dx
				end
				x, z = x + dx, z + dz
			end
		end
		local h = sample(0, 0, 0)
		return 0, h, 0
	end

	local function structureContainer(x: number, y: number, z: number): { StructureGen.ContainerItem }?
		if placer == nil then
			return nil
		end
		return placer.container(x, y, z)
	end

	local function structuresIn(minX: number, minZ: number, maxX: number, maxZ: number): { StructureGen.Start }
		if placer == nil then
			return {}
		end
		return placer.starts(minX, minZ, maxX, maxZ)
	end

	return {
		seed = seed,
		column = column,
		generate = generate,
		findSpawn = findSpawn,
		seamLimits = seamLimits,
		farSeamLimits = farSeamLimits,
		structureContainer = structureContainer,
		structures = structuresIn,
	}
end

return TerrainGenerator

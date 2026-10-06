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

	Order of a chunk: fill, caves (Caves.luau, cave air), cave entrances and ravines
	(SurfaceCaves.luau, air open to the surface), lava below LavaLevel, surface lava lakes and oil
	wells (Lava.luau, OilWells.luau), water lakes and puddles (Lakes.luau), ores, underground lava
	lakes, trees and library structures, glow lichen, ground plants. Trees ask the worms (not the
	chunk) whether a surface cave opens under them, so every chunk agrees on every tree; no
	surface cave is carved next to a structure's piece, a surface lava or water lake, a puddle or
	a geyser's oil lake, and no tree grows in one.

	Chunks (see World/ChunkLayout)
	  `generate(level, nx, nz)` fills a padded column. Level 0 is full detail; level L samples the
	  same terrain every 2^L blocks horizontally (and every min(2^L, Lod.MaxVerticalStep) blocks
	  vertically), which is what makes far LOD chunks cheap to generate.

	  LOD chunks lower their border (padding) columns by one cell. A coarse chunk next to a finer
	  one would otherwise hide border cells the finer neighbour leaves exposed, which shows up as
	  thin cracks at LOD boundaries; this "skirt" makes those cells visible.

	  For the client's culling, `generate` also hands back what it knows anyway (`extras`): the
	  cave lattice (where caves may be), each column's terrain height and where library
	  structures wrote (World/SectionGraph reads fewer cells with them), and a per-tile summary of
	  the node's heights (World/Horizon). None of it changes the blocks.
]]

local Config = require(script.Parent.Parent.Config)
local Blocks = require(script.Parent.Parent.Blocks)
local Biomes = require(script.Parent.Parent.Biomes)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)
local Horizon = require(script.Parent.Parent.World.Horizon)
local Noise = require(script.Parent.Noise)
local Relief = require(script.Parent.Relief)
local Caves = require(script.Parent.Caves)
local SurfaceCaves = require(script.Parent.SurfaceCaves)
local Ores = require(script.Parent.Ores)
local Foliage = require(script.Parent.Foliage)
local CaveDecor = require(script.Parent.CaveDecor)
local Lava = require(script.Parent.Lava)
local OilWells = require(script.Parent.OilWells)
local Lakes = require(script.Parent.Lakes)
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
local STRUCTURE_MARGIN = 2 -- no surface cave within this many blocks of a library structure piece

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
	-- Where the chunk may hold cave air (full detail only; nil: no caves), see Caves.Carved.
	carved: Caves.Carved?,
	-- With `extras` (the client's culling, Shared/World/Horizon and SectionGraph): the node's
	-- Horizon summary; for full detail chunks the terrain height of each core column (u16 cells at
	-- (z * SIZE + x) * 2, before structures and caves), and the cells library structures wrote
	-- something other than rock or cave air into ({ lowest, highest }; nil: none).
	summary: buffer?,
	surface: buffer?,
	structureSpan: { number }?,
}

export type Generator = {
	seed: number,
	-- Terrain height (first air block), surface biome index, vegetation chance, surface block.
	column: (x: number, z: number) -> (number, number, number, number),
	-- `yield` is called regularly so callers can spread the work over several frames. `extras`:
	-- also return what the client's culling needs (ChunkResult `summary`, `surface`, ...).
	generate: (level: number, nx: number, nz: number, yield: (() -> ())?, extras: boolean?) -> ChunkResult,
	-- A spawn column: low, dry, gentle land near the hills, where no cave entrance or ravine opens
	-- (SurfaceCaves.carvesTop). x, height, z.
	findSpawn: () -> (number, number, number),
	--[[
		Seam limits for the mesher (GreedyMesher.Border.open) of node (level, nx, nz), given the
		level of the coarser node on each side (-X, +X, -Z, +Z; 0 = none): how high that node's
		terrain goes, or down to where its surface caves cut the column (levels up to
		SurfaceCaves.MAX_LEVEL, SurfaceCaves.lowestCarved). nil when no side has one.
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
		case; the padding is also opened down to where a finer neighbour's surface caves cut its
		border (see openToFinerCuts). Far nodes then never need to be rebuilt when their
		neighbours change. nil for the coarsest level.
	]]
	farSeamLimits: (level: number, nx: number, nz: number) -> buffer?,
	-- The cave entrances and ravines `generate` carves (Generation/SurfaceCaves): `worms` finds
	-- them, `carvesTop` says whether one opens at a column.
	surfaceCaves: SurfaceCaves.SurfaceCaves,
	-- The oil wells (Generation/OilWells) with a block within OilWells.MARGIN of the block
	-- rectangle (inclusive), deposits and geysers, and a geyser's lake columns (OilWells.lakeOf).
	oilWells: (minX: number, minZ: number, maxX: number, maxZ: number) -> { OilWells.Well },
	oilLake: (well: OilWells.Well) -> buffer,
	-- The surface lava lakes (Generation/Lava) whose box comes within Lava.PROTECT blocks of the
	-- block rectangle (inclusive).
	lavaLakes: (minX: number, minZ: number, maxX: number, maxZ: number) -> { Lava.Lake },
	-- The water lakes (Generation/Lakes) whose box comes within Lakes.PROTECT blocks of the block
	-- rectangle (inclusive), and the puddles whose columns come within Lakes.PUDDLE_MARGIN.
	waterLakes: (minX: number, minZ: number, maxX: number, maxZ: number) -> { Lakes.Lake },
	puddles: (minX: number, minZ: number, maxX: number, maxZ: number) -> { Lakes.Puddle },
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

	-- Cave entrances and ravines, from the full detail surface (heights as `generate` fills them).
	local surfaceCaves = SurfaceCaves.new(seed, function(x: number, z: number): (number, number)
		local y, _, _, river = relief.height(x, z, 0)
		return clampHeight(y), river
	end, if Config.Caves.Enabled then Caves.regions(seed) else nil)

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

	-- Does a library structure's piece reach the block rectangle (inclusive)?
	local function piecesIn(minX: number, minZ: number, maxX: number, maxZ: number): boolean
		if placer == nil then
			return false
		end
		for _, start in placer.starts(minX, minZ, maxX, maxZ) do
			for _, piece in start.pieces do
				local box = piece.box
				if box[1] <= maxX and box[4] >= minX and box[3] <= maxZ and box[6] >= minZ then
					return true
				end
			end
		end
		return false
	end

	-- The spawn column (findSpawn's, worked out once): lava lakes and oil wells keep clear of it.
	local findSpawn: () -> (number, number, number)
	local spawnX: number?, spawnZ: number? = nil, nil
	local function spawnColumn(): (number, number)
		if spawnX == nil or spawnZ == nil then
			local x, _, z = findSpawn()
			spawnX, spawnZ = x, z
			return x, z
		end
		return spawnX, spawnZ
	end
	local function biomeAt(x: number, z: number): number
		local _, biome = sample(x, z, 0)
		return biome
	end

	-- Oil wells and surface lava lakes, decided from the full detail terrain (every chunk and
	-- level agrees). A lava lake also keeps clear of a geyser's oil lake.
	local wells = OilWells.new(seed, {
		height = outsideHeight,
		biome = biomeAt,
		free = function(minX: number, minZ: number, maxX: number, maxZ: number): boolean
			return not piecesIn(minX, minZ, maxX, maxZ)
		end,
		spawn = spawnColumn,
		regions = if Config.Caves.Enabled then Caves.regions(seed) else nil,
		-- (Deposits keep under the surface caves, carved before them.)
		carved = function(x: number, z: number): number?
			if not surfaceCaves.mayCarve(x, z) then
				return nil
			end
			local h = outsideHeight(x, z)
			return surfaceCaves.lowestCarved(0, x, z, h, h - 1)
		end,
	})
	local lava = Lava.new(seed, {
		height = outsideHeight,
		biome = biomeAt,
		free = function(minX: number, minZ: number, maxX: number, maxZ: number): boolean
			for _, well in wells.find(minX, minZ, maxX, maxZ) do
				local x0, z0, x1, z1 = wells.lakeBox(well)
				if x0 and z0 and x1 and z1 and x0 <= maxX and x1 >= minX and z0 <= maxZ and z1 >= minZ then
					return false
				end
			end
			return not piecesIn(minX, minZ, maxX, maxZ)
		end,
		spawn = spawnColumn,
	})
	-- Water lakes and puddles, likewise; they keep clear of oil wells (deposits too), lava lakes
	-- and structures, and puddles of the columns a surface cave may open.
	local lakes = Lakes.new(seed, {
		height = outsideHeight,
		biome = biomeAt,
		free = function(minX: number, minZ: number, maxX: number, maxZ: number): boolean
			return #wells.find(minX, minZ, maxX, maxZ) == 0
				and #lava.surfaceLakes(minX, minZ, maxX, maxZ) == 0
				and not piecesIn(minX, minZ, maxX, maxZ)
		end,
		spawn = spawnColumn,
		carvesTop = surfaceCaves.carvesTop,
	})

	-- Per-column scratch arrays, reused between chunks (each worker actor has its own copy).
	local heights: { number } = table.create(P * P, 0)
	local biomes: { number } = table.create(P * P, 1)
	local surfaces: { number } = table.create(P * P, 0)
	local topCells: { number } = table.create(P * P, 0)
	local protected: { boolean } = table.create(P * P, false)

	-- Is column (x, z) within STRUCTURE_MARGIN blocks of a piece of `starts`?
	local function nearPiece(starts: { StructureGen.Start }, x: number, z: number): boolean
		for _, start in starts do
			for _, piece in start.pieces do
				local box = piece.box
				if
					x >= box[1] - STRUCTURE_MARGIN
					and x <= box[4] + STRUCTURE_MARGIN
					and z >= box[3] - STRUCTURE_MARGIN
					and z <= box[6] + STRUCTURE_MARGIN
				then
					return true
				end
			end
		end
		return false
	end

	--[[
		Padded columns no surface cave may carve: within STRUCTURE_MARGIN blocks of a library
		structure piece (its foundation would fill a pit under it and a path would float over a
		ravine), and in `boxes` (x0, z0, x1, z1 per box, inclusive: surface lava lakes and geysers'
		oil lakes with their margins; a surface cave there would open the lake's side). nil when
		there are none. Pieces and boxes are world boxes, so every chunk agrees.
	]]
	local function protectedColumns(
		starts: { StructureGen.Start }?,
		boxes: { number },
		level: number,
		originX: number,
		originZ: number
	): { boolean }?
		if starts == nil and #boxes == 0 then
			return nil
		end
		local step = ChunkLayout.steps(level)
		local half = step // 2
		local any = false
		table.clear(protected)
		local function protect(bx0: number, bz0: number, bx1: number, bz1: number)
			-- Padded columns whose sample block is in the box.
			local px0 = math.max(-((originX - step + half - bx0) // step), 0)
			local px1 = math.min((bx1 - (originX - step + half)) // step, P - 1)
			local pz0 = math.max(-((originZ - step + half - bz0) // step), 0)
			local pz1 = math.min((bz1 - (originZ - step + half)) // step, P - 1)
			for pz = pz0, pz1 do
				for px = px0, px1 do
					protected[pz * P + px + 1] = true
					any = true
				end
			end
		end
		if starts then
			for _, start in starts do
				for _, piece in start.pieces do
					local box = piece.box
					protect(
						box[1] - STRUCTURE_MARGIN,
						box[3] - STRUCTURE_MARGIN,
						box[4] + STRUCTURE_MARGIN,
						box[6] + STRUCTURE_MARGIN
					)
				end
			end
		end
		for i = 1, #boxes, 4 do
			protect(boxes[i], boxes[i + 1], boxes[i + 2], boxes[i + 3])
		end
		return if any then protected else nil
	end

	local function generate(level: number, nx: number, nz: number, yield: (() -> ())?, extras: boolean?): ChunkResult
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

		-- Surface lava lakes, oil wells, water lakes and puddles near the padded chunk (as far as
		-- tree spots that must keep out of their lakes), and the squares around their lakes
		-- (`keepOut`, x0, z0, x1, z1 per lake): no surface cave carves there and no tree grows there.
		-- (Far nodes don't draw puddles, but keep trees and surface caves out of them all the same,
		-- so every level agrees on every tree.)
		local lavaLakes: { Lava.Lake }? = nil
		local nearWells: { OilWells.Well }? = nil
		local waterLakes: { Lakes.Lake }? = nil
		local puddles: { Lakes.Puddle }? = nil
		local keepOut: { number } = {}
		if level <= Config.StructureMaxLevel then
			local reach = Structures.RADIUS + 1
			local x0, z0 = originX - step - reach, originZ - step - reach
			local x1, z1 = originX + span + step - 1 + reach, originZ + span + step - 1 + reach
			lavaLakes = lava.surfaceLakes(x0, z0, x1, z1)
			for _, lake in lavaLakes :: { Lava.Lake } do
				local m = Lava.PROTECT
				table.insert(keepOut, lake.x - m)
				table.insert(keepOut, lake.z - m)
				table.insert(keepOut, lake.x + Lava.BOX - 1 + m)
				table.insert(keepOut, lake.z + Lava.BOX - 1 + m)
			end
			nearWells = wells.find(x0, z0, x1, z1)
			for _, well in nearWells :: { OilWells.Well } do
				local bx0, bz0, bx1, bz1 = wells.lakeBox(well)
				if bx0 and bz0 and bx1 and bz1 then
					table.insert(keepOut, bx0)
					table.insert(keepOut, bz0)
					table.insert(keepOut, bx1)
					table.insert(keepOut, bz1)
				end
			end
			-- (A spout rises at most 16 blocks over its own column: within STRUCTURE_ROOM.)
			waterLakes = lakes.lakes(x0, z0, x1, z1)
			for _, lake in waterLakes :: { Lakes.Lake } do
				local m = Lakes.PROTECT
				table.insert(keepOut, lake.x - m)
				table.insert(keepOut, lake.z - m)
				table.insert(keepOut, lake.x + Lakes.BOX - 1 + m)
				table.insert(keepOut, lake.z + Lakes.BOX - 1 + m)
			end
			puddles = lakes.puddles(x0, z0, x1, z1)
			for _, puddle in puddles :: { Lakes.Puddle } do
				local m = Lakes.PUDDLE_MARGIN
				table.insert(keepOut, puddle.x0 - m)
				table.insert(keepOut, puddle.z0 - m)
				table.insert(keepOut, puddle.x1 + m)
				table.insert(keepOut, puddle.z1 + m)
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

		-- 3. Caves (full detail only), then cave entrances and ravines (point-sampled up to
		-- SurfaceCaves.MAX_LEVEL: far ravines show as cuts), lava below LavaLevel, surface lava
		-- lakes, oil wells and water lakes (point-sampled up to StructureMaxLevel) and puddles (full
		-- detail only), then ores (full detail only; they only replace stone, so they never fill
		-- carved air) and an underground lava lake.
		local carved: Caves.Carved? = nil
		if level == 0 and Config.Caves.Enabled then
			carved = carveCaves(data, originX, originZ, heights, cells, yield)
			if yield then
				yield()
			end
		end
		if level <= SurfaceCaves.MAX_LEVEL then
			local protectedCells = protectedColumns(starts, keepOut, level, originX, originZ)
			local lowest =
				surfaceCaves.carve(data, level, originX, originZ, heights, topCells, cells, protectedCells, yield)
			if lowest < solidBelow then
				solidBelow = lowest
			end
			-- Lava below LavaLevel: cave air into CaveLava, surface caves' air into Lava.
			lowest = Lava.aquifer(data, cells, level)
			if lowest < solidBelow then
				solidBelow = lowest
			end
		end
		-- Surface lava lakes and oil wells (deposits, geysers), before the ores so a deposit takes
		-- the same rock in a chunk's padding as in its neighbour's core.
		if lavaLakes and #lavaLakes > 0 then
			local lowest = lava.writeSurface(lavaLakes, data, level, originX, originZ, cells, topCells)
			if lowest < solidBelow then
				solidBelow = lowest
			end
		end
		if nearWells and #nearWells > 0 then
			local lowest, top, map = wells.write(nearWells, data, level, originX, originZ, cells, topCells, carved)
			carved = map
			if lowest < solidBelow then
				solidBelow = lowest
			end
			if top > emptyAbove then
				emptyAbove = top
			end
		end
		-- Water lakes and puddles (puddles in full detail chunks only).
		if (waterLakes and #waterLakes > 0) or (level == 0 and puddles and #puddles > 0) then
			local lowest, top =
				lakes.write(waterLakes or {}, puddles or {}, data, level, originX, originZ, cells, topCells)
			if lowest < solidBelow then
				solidBelow = lowest
			end
			if top > emptyAbove then
				emptyAbove = top
			end
		end
		if level == 0 then
			Ores.place(data, seed, nx, nz, cells)
			-- An underground lava lake, sunk into a cave floor (decided from this chunk's blocks; it
			-- never reaches the neighbours' padding), not into a library structure's piece.
			if carved then
				local blocked: ((number, number, number, number, number, number) -> boolean)? = nil
				if starts then
					local list = starts
					blocked = function(x0: number, y0: number, z0: number, x1: number, y1: number, z1: number): boolean
						for _, start in list do
							for _, piece in start.pieces do
								local b = piece.box
								if
									b[1] <= x1
									and b[4] >= x0
									and b[2] <= y1
									and b[5] >= y0
									and b[3] <= z1
									and b[6] >= z0
								then
									return true
								end
							end
						end
						return false
					end
				end
				local _, map = lava.underground(data, cells, nx, nz, heights, carved, blocked)
				carved = map
			end
		end

		local structureSpan: { number }? = nil

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
			-- Not on bare rock, near a library structure's piece, in a surface lava or water lake's,
			-- a puddle's or a geyser's square or over a surface cave (decided from the worms, so every chunk and
			-- level agrees).
			local function dry(x: number, z: number): boolean
				for i = 1, #keepOut, 4 do
					if x >= keepOut[i] and z >= keepOut[i + 1] and x <= keepOut[i + 2] and z <= keepOut[i + 3] then
						return false
					end
				end
				return true
			end
			local accept = function(x: number, z: number, biome: number): boolean
				return gentle(x, z, biome) and dry(x, z) and not surfaceCaves.carvesTop(x, z)
			end
			if placer and starts then
				local p, list = placer, starts
				accept = function(x: number, z: number, biome: number): boolean
					return gentle(x, z, biome)
						and p.treeAllowed(list, x, z)
						and dry(x, z)
						and not surfaceCaves.carvesTop(x, z)
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
				if lowest < huge then
					structureSpan = { lowest, top - 1 }
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

		-- 7. For the client's culling: the Horizon summary (per 4 x 4 cell tile, the lowest terrain
		-- top and the highest top) and the terrain height of every core column.
		local summary, surface = nil, nil
		if extras then
			summary = Horizon.summarise(data, cells, emptyAbove, topCells, stepY)
			if level == 0 then
				local heightsOut = buffer.create(SIZE * SIZE * 2)
				for z = 0, SIZE - 1 do
					for x = 0, SIZE - 1 do
						writeu16(heightsOut, (z * SIZE + x) * 2, math.max(topCells[(z + 1) * P + x + 2] + 1, 0))
					end
				end
				surface = heightsOut
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
			carved = carved,
			summary = summary,
			surface = surface,
			structureSpan = if extras then structureSpan else nil,
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
				-- The coarse node carves surface caves there (except next to structure pieces).
				local carves = coarse <= SurfaceCaves.MAX_LEVEL
				local pieces: { StructureGen.Start }? = nil
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
					local cx, cz = (x // cs) * cs + halfC, (z // cs) * cs + halfC
					local h = sample(cx, cz, coarse)
					-- Same rounding as `generate` at the coarse level: blocks below `solidTop` are drawn.
					local solidTop = ((h - halfCY + csY - 1) // csY) * csY
					local open = solidTop
					if carves then
						if placer and coarse <= Config.StructureMaxLevel and pieces == nil then
							-- The pieces along this side (`generate` leaves columns near them alone).
							local reach = SIZE * step + 2 * cs + STRUCTURE_MARGIN
							pieces = placer.starts(x - reach, z - reach, x + reach, z + reach)
						end
						if not (pieces and nearPiece(pieces, cx, cz)) then
							-- Down to the coarse column's cut, where its terrain ends.
							local cut = surfaceCaves.lowestCarved(coarse, cx, cz, h, solidTop // csY - 1)
							if cut and cut * csY < open then
								open = cut * csY
							end
						end
					end
					writeu16(limits, ((side - 1) * SIZE + i) * 2, math.max(open // stepY, 1))
				end
			end
		end
		return out
	end

	--[[
		Opens a far node's seam `limits` down to where a finer neighbour (one or two levels finer,
		up to SurfaceCaves.MAX_LEVEL) cuts its border columns with a surface cave. This node's
		padding there is its own coarser (or uncarved) terrain, so without it neither side would
		draw the rock facing the cut: a see-through slit at a ravine's or a pit's end. Where the
		neighbour is not that finer node, the opened cells only add faces inside the terrain.
	]]
	local function openToFinerCuts(level: number, nx: number, nz: number, limits: buffer)
		local step, stepY = ChunkLayout.steps(level)
		local span = SIZE * step
		local originX, originZ = nx * span, nz * span
		local pieces: { StructureGen.Start }? = nil
		for fine = math.max(level - 2, 0), math.min(level - 1, SurfaceCaves.MAX_LEVEL) do
			-- Only towards ravines from a node that carves nothing itself (it builds no worms and has
			-- no trees: an entrance's opening there is a few blocks some 400 blocks away, within the
			-- skirt), and towards a node two levels finer (rare: full detail chunks next to a level
			-- 2 node while the camera is underground). Every opened cell costs parts.
			local ravinesOnly = level > SurfaceCaves.MAX_LEVEL or fine < level - 1
			local fs, fsY = ChunkLayout.steps(fine)
			local halfF, halfFY = fs // 2, fsY // 2
			for side = 1, 4 do
				for i = 0, SIZE - 1 do
					local o = ((side - 1) * SIZE + i) * 2
					local open = buffer.readu16(limits, o)
					-- The finer node's border columns next to padding column i.
					for along = i * step + halfF, (i + 1) * step - 1, fs do
						local x, z
						if side == 1 then
							x, z = originX - fs + halfF, originZ + along
						elseif side == 2 then
							x, z = originX + span + halfF, originZ + along
						elseif side == 3 then
							x, z = originX + along, originZ - fs + halfF
						else
							x, z = originX + along, originZ + span + halfF
						end
						if not surfaceCaves.mayCarve(x, z, ravinesOnly) then
							continue
						end
						local h = clampHeight((relief.height(x, z, fine)))
						local cut =
							surfaceCaves.lowestCarved(fine, x, z, h, (h - halfFY + fsY - 1) // fsY - 1, ravinesOnly)
						if cut == nil or cut * fsY // stepY >= open then
							continue
						end
						-- (`generate` leaves the columns next to a structure's piece alone.)
						if placer and fine <= Config.StructureMaxLevel and pieces == nil then
							local m = step + STRUCTURE_MARGIN
							pieces = placer.starts(originX - m, originZ - m, originX + span + m, originZ + span + m)
						end
						if not (pieces and nearPiece(pieces, x, z)) then
							open = cut * fsY // stepY
						end
					end
					buffer.writeu16(limits, o, math.max(open, 1))
				end
			end
		end
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
		openToFinerCuts(level, nx, nz, limits)
		return limits
	end

	function findSpawn(): (number, number, number)
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
						-- Not where a cave entrance or ravine opens (last: it builds the worms around).
						if ok and not surfaceCaves.carvesTop(wx, wz) then
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
		surfaceCaves = surfaceCaves,
		oilWells = wells.find,
		oilLake = wells.lakeOf,
		lavaLakes = lava.surfaceLakes,
		waterLakes = lakes.lakes,
		puddles = lakes.puddles,
	}
end

return TerrainGenerator

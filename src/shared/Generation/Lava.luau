--!strict
--!native
--[[
	Generated lava, Minecraft 1.20.1's overworld lava in three parts.

	Aquifers (`aquifer`). Minecraft's noise generator fills every cave below y -54 with lava
	(NoiseBasedChunkGenerator.createFluidPicker: lava under min(-54, sea level), its surface 10
	blocks above the world's floor), and its carvers carve lava instead of air at aboveBottom(8)
	and below (WorldCarver.getCarveState). Here every cave air cell below Config.Caves.LavaLevel
	becomes CaveLava, the cave twin of a lava source (cave air while caves are hidden, so the lava
	seas on the deepest cave floors, the Underlands' floor under the highest mountains included,
	cost nothing until a cave is revealed), and every Air cell there (a surface cave dug that
	deep, Generation/SurfaceCaves) ordinary Lava. All of it sources (level 0) at rest: nothing
	flows until something changes next to it (the server's Behaviours/Fluid).

	Lakes: Minecraft's LakeFeature with lake_lava's configuration (lava, a barrier of stone).
	A lake is a 16 x 8 x 16 box: 4..7 overlapping ellipsoid blobs (3..9 wide, 2..6 tall) inside its
	cells 1..14 / 1..6 / 1..14 (`shapeOf`, Minecraft's draws). Blob cells in the lower four layers are
	lava, those from layer 4 up air (the bowl above the lava). The lake is refused where a cell
	next to the blobs (its shell) is liquid from layer 4 up, or not solid below it, so lava never
	spills; then shell cells that are solid become stone below layer 4, and half of them (one draw
	each) from layer 4 up.
	  * Underground (`underground`, Minecraft's lake_lava_underground: one try in 9 chunks, at a
	    random height, scanning 32 blocks down for a floor, 5+ blocks below the surface): here
	    one chunk in Underground.Rarity of those with caves tries Underground.Tries random columns
	    of its core at a random height for a cave floor (cave air above, rock below, within 32
	    blocks down) at least Underground.Depth blocks below the surface, and puts a lake box on
	    the chunk's core with the floor block in layer 4, so the lava's top is one below the floor
	    (Minecraft's origin is the floor block too). Lava is CaveLava and the bowl cave air: cave
	    cells, nothing while caves are hidden. The blobs never touch the core's outer columns, so
	    the neighbours' padding never holds lake cells; only the stone barrier can sit in a core
	    edge column, where it replaces rock (opaque in either chunk: they cull alike). The lake is
	    decided from the chunk's own blocks, which every machine generates alike.
	  * Surface (`surfaceLakes`, `writeSurface`; Minecraft's lake_lava_surface: one candidate in
	    200 chunks at a random spot on the surface): one candidate per 16 x 16 block cell with
	    chance 1 / Surface.Rarity, its box corner at a hashed spot of the cell, layer 4 at the
	    full detail surface height of the box's centre (Minecraft: of its corner). Decided from the
	    full detail heights alone, never from a chunk's blocks, so every chunk and LOD level agrees:
	    a cell below a column's height is ground, at or above it air, or water below sea level.
	    Not in snowy or wet biomes (frozen, snow covered, humidity WET or more), never next to
	    water (the shell rule), nowhere a cell could meet a deep cave (every cell of the box less
	    than Caves' 9 cave-free blocks below its column's surface), not near a library structure,
	    an oil well or the spawn. Ordinary Lava (open to the sky, always drawn). Surface caves
	    leave the box and PROTECT blocks around it alone (TerrainGenerator), trees stay out of it,
	    and LOD chunks up to Config.StructureMaxLevel point-sample it: a column whose sample block
	    lies over the lake's lava gets lava in its top cell, so lakes show from afar.
	All of it is level 0 lava (sources), deterministic and the same in a chunk's padding as in
	its neighbour's core.
]]

local Config = require(script.Parent.Parent.Config)
local Blocks = require(script.Parent.Parent.Blocks)
local Biomes = require(script.Parent.Parent.Biomes)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)
local Hash = require(script.Parent.Parent.Util.Hash)
local Caves = require(script.Parent.Caves)

local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED
local LAYER = ChunkLayout.LAYER
local STRIDE = LAYER * 2
local SEA = Config.SeaLevel
local MIN_Y = Config.Caves.MinY

-- Tuning --------------------------------------------------------------------------------------------
local BOX = 16 -- a lake's box: BOX x LAYERS x BOX cells (Minecraft's 16 x 8 x 16)
local LAYERS = 8
local SURFACE_LAYER = 4 -- layers below this are lava, the blob cells above it air
local SCAN = 32 -- an underground try looks this many blocks down for a floor (Minecraft's 32)
local CAVE_FREE = 9 -- no cave air within this many blocks of a column's surface (Caves: d < 0.02)
local WET = 0.45 -- biomes this humid or more get no surface lakes (jungles, birch forests...)
local PROTECT = 2 -- surface caves leave this many blocks around a surface lake's box alone

local readu8 = buffer.readu8
local writeu8 = buffer.writeu8
local readu16 = buffer.readu16
local writeu16 = buffer.writeu16
local huge = math.huge

local AIR, CAVE_AIR = Blocks.AIR, Blocks.CAVE_AIR
local id = Blocks.id
local LAVA, CAVE_LAVA, STONE, BEDROCK = id.Lava, id.CaveLava, id.Stone, id.Bedrock

-- Shape cell values.
local OUT, LAKE, BARRIER, SHELL = 0, 1, 2, 3

-- Per block id: 1 rock a lake may replace and a barrier may turn into stone (opaque, not bedrock),
-- 2 a fluid (any level, any cave twin).
local ROCK, FLUID = 1, 2
local class = buffer.create(Blocks.count)
for blockId = 0, Blocks.count - 1 do
	local def = Blocks.get(blockId)
	if def.fluid then
		writeu8(class, blockId, FLUID)
	elseif blockId ~= BEDROCK and readu8(Blocks.cullLut, blockId) == 1 then
		writeu8(class, blockId, ROCK)
	end
end

--[[
	A lake: its box's corner cell (world x, the y of layer 0, z) and its shape, a u8 per box cell
	at (x * BOX + z) * LAYERS + y: 0 outside, 1 the lake (lava below SURFACE_LAYER, air from it up),
	2 shell that turns into stone where it is solid, 3 shell left alone. `cells`: lava cells in
	the shape.
]]
export type Lake = {
	x: number,
	y: number,
	z: number,
	shape: buffer,
	cells: number,
	underground: boolean,
}

--[[
	What the surface lakes need of the terrain, all at full detail (TerrainGenerator): a column's
	height (first air) and biome index, whether a block rectangle (inclusive) is free of library
	structure pieces and oil wells, and the spawn column.
]]
export type Terrain = {
	height: (x: number, z: number) -> number,
	biome: (x: number, z: number) -> number,
	free: (minX: number, minZ: number, maxX: number, maxZ: number) -> boolean,
	spawn: () -> (number, number),
}

export type LavaGen = {
	-- Every surface lake whose box (grown by PROTECT) reaches the block rectangle (inclusive).
	surfaceLakes: (minX: number, minZ: number, maxX: number, maxZ: number) -> { Lake },
	-- The surface lake of candidate cell (cx, cz) (nil: none) without filling the cache:
	-- /locate's probe (Generation/Locate) looks at thousands of cells.
	peek: (cx: number, cz: number) -> Lake?,
	--[[
		Writes surface `lakes` into the padded `level` chunk (first core column originX, originZ;
		`cells` tall). Level 0 writes the box's cells (lava, air, the stone barrier); levels up to
		Config.StructureMaxLevel put lava into the top cell of each column whose sample block lies
		over the lake's lava. `topCells` (per padded column) drop below what was dug, so they keep
		describing the ground. Returns the lowest cell written with lava or air (math.huge: none).
	]]
	writeSurface: (
		lakes: { Lake },
		data: buffer,
		level: number,
		originX: number,
		originZ: number,
		cells: number,
		topCells: { number }
	) -> number,
	--[[
		Tries an underground lake in the full detail chunk (nx, nz), after its caves and ores:
		`heights` per padded column (surface height), `carved` its cave lattice (nil: no caves, no
		lake). `blocked(x0, y0, z0, x1, y1, z1)` says whether a world box is taken (library
		structures). Returns the lake written (nil: none) and the lattice, marked where the lake
		put cave cells into rock.
	]]
	underground: (
		data: buffer,
		cells: number,
		nx: number,
		nz: number,
		heights: { number },
		carved: Caves.Carved?,
		blocked: ((x0: number, y0: number, z0: number, x1: number, y1: number, z1: number) -> boolean)?
	) -> (Lake?, Caves.Carved?),
}

local Lava = {}

Lava.BOX = BOX
Lava.LAYERS = LAYERS
Lava.SURFACE_LAYER = SURFACE_LAYER
Lava.PROTECT = PROTECT
Lava.WET = WET
Lava.OUT, Lava.LAKE, Lava.BARRIER, Lava.SHELL = OUT, LAKE, BARRIER, SHELL

local function cellIndex(x: number, y: number, z: number): number
	return (x * BOX + z) * LAYERS + y
end
Lava.cellIndex = cellIndex

--[[
	Minecraft's lake shape (LakeFeature.place), drawing from `rng` as it does: the blob count
	(nextInt(4) + 4), six doubles per blob, then one nextInt(2) per shell cell from layer 4 up
	(in x, z, y order) for the barrier. Returns the shape (see Lake), its lake cells below
	SURFACE_LAYER and the columns it takes (x0, z0, x1, z1 in the box: lake and shell).
]]
function Lava.shapeOf(rng: Hash.Rng): (buffer, number, number, number, number, number)
	local shape = buffer.create(BOX * BOX * LAYERS)
	local blobs = rng:int(4, 7)
	-- The lake cells' columns.
	local ax, az, bx, bz = BOX, BOX, -1, -1
	for _ = 1, blobs do
		local sx = rng:float() * 6 + 3
		local sy = rng:float() * 4 + 2
		local sz = rng:float() * 6 + 3
		local cx = rng:float() * (16 - sx - 2) + 1 + sx / 2
		local cy = rng:float() * (8 - sy - 4) + 2 + sy / 2
		local cz = rng:float() * (16 - sz - 2) + 1 + sz / 2
		local hx, hy, hz = sx / 2, sy / 2, sz / 2
		-- (Only the blob's own box: Minecraft tests all cells 1..14 / 1..6, the same ones pass.)
		local x0, x1 = math.max(math.ceil(cx - hx), 1), math.min(math.floor(cx + hx), BOX - 2)
		local z0, z1 = math.max(math.ceil(cz - hz), 1), math.min(math.floor(cz + hz), BOX - 2)
		local y0, y1 = math.max(math.ceil(cy - hy), 1), math.min(math.floor(cy + hy), LAYERS - 2)
		for x = x0, x1 do
			local dx = (x - cx) / hx
			for z = z0, z1 do
				local dz = (z - cz) / hz
				for y = y0, y1 do
					local dy = (y - cy) / hy
					if dx * dx + dy * dy + dz * dz < 1 then
						writeu8(shape, cellIndex(x, y, z), LAKE)
						ax, az = math.min(ax, x), math.min(az, z)
						bx, bz = math.max(bx, x), math.max(bz, z)
					end
				end
			end
		end
	end
	if bx < 0 then
		return shape, 0, 0, 0, -1, -1
	end
	-- Shell cells lie within a cell of the lake's columns (the order of the draws is kept).
	ax, az, bx, bz = ax - 1, az - 1, bx + 1, bz + 1
	local lava = 0
	for x = ax, bx do
		for z = az, bz do
			for y = 0, LAYERS - 1 do
				local i = cellIndex(x, y, z)
				if readu8(shape, i) == LAKE then
					if y < SURFACE_LAYER then
						lava += 1
					end
					continue
				end
				local shell = (x < BOX - 1 and readu8(shape, i + BOX * LAYERS) == LAKE)
					or (x > 0 and readu8(shape, i - BOX * LAYERS) == LAKE)
					or (z < BOX - 1 and readu8(shape, i + LAYERS) == LAKE)
					or (z > 0 and readu8(shape, i - LAYERS) == LAKE)
					or (y < LAYERS - 1 and readu8(shape, i + 1) == LAKE)
					or (y > 0 and readu8(shape, i - 1) == LAKE)
				if shell then
					local barrier = y < SURFACE_LAYER or rng:int(0, 1) ~= 0
					writeu8(shape, i, if barrier then BARRIER else SHELL)
				end
			end
		end
	end
	return shape, lava, ax, az, bx, bz
end

--[[
	Turns cave air below LavaLevel into CaveLava and Air there (surface caves) into Lava in the
	padded `level` chunk (cells whose sample block lies below LavaLevel). Returns the lowest cell
	that became ordinary Lava (math.huge: none).
]]
function Lava.aquifer(data: buffer, cells: number, level: number): number
	local _, stepY = ChunkLayout.steps(level)
	local halfY = stepY // 2
	local last = math.min((Config.Caves.LavaLevel - 1 - halfY) // stepY, cells - 1)
	local lowest = huge
	for y = 1, last do
		local base = y * STRIDE
		for i = 0, LAYER - 1 do
			local o = base + i * 2
			local block = readu16(data, o)
			if block == CAVE_AIR then
				writeu16(data, o, CAVE_LAVA)
			elseif block == AIR then
				writeu16(data, o, LAVA)
				if y < lowest then
					lowest = y
				end
			end
		end
	end
	return lowest
end

-- Cell keys of the 16 x 16 candidate grid.
local function cellKey(cx: number, cz: number): number
	return (cx + 2097152) * 4194304 + (cz + 2097152)
end

function Lava.new(seed: number, terrain: Terrain): LavaGen
	local surfaceSalt = Hash.hash2(seed, Hash.string("lava.surfaceLakes"), 0x1A7A)
	local undergroundSalt = Hash.hash2(seed, Hash.string("lava.undergroundLakes"), 0x2B8B)
	local surfaceCfg = Config.Caves.LavaLakes.Surface
	local undergroundCfg = Config.Caves.LavaLakes.Underground
	local spawnClearance = Config.Caves.LavaLakes.SpawnClearance

	-- Decided candidate cells (`lake` nil: none), in two generations so the cache stays small.
	local recent: { [number]: { lake: Lake? } } = {}
	local older: { [number]: { lake: Lake? } } = {}
	local count = 0

	-- The surface lake of candidate cell (cx, cz), nil when it has none.
	local function decide(cx: number, cz: number): Lake?
		local rng = Hash.rng(Hash.hash2(surfaceSalt, cx, cz))
		if not surfaceCfg.Enabled or rng:float() * surfaceCfg.Rarity >= 1 then
			return nil
		end
		local x0 = cx * BOX + rng:int(0, BOX - 1)
		local z0 = cz * BOX + rng:int(0, BOX - 1)
		local shape, lava, ax, az, bx, bz = Lava.shapeOf(rng)
		if lava == 0 then
			return nil
		end
		local mx, mz = x0 + BOX // 2, z0 + BOX // 2
		local o = terrain.height(mx, mz)
		local base = o - SURFACE_LAYER
		if base <= MIN_Y or o <= SEA + 1 then
			return nil
		end
		local biome = Biomes.list[terrain.biome(mx, mz)]
		if biome.frozen or biome.top == id.Snow or biome.humidity >= WET then
			return nil
		end
		if spawnClearance > 0 then
			local sx, sz = terrain.spawn()
			if (mx - sx) ^ 2 + (mz - sz) ^ 2 < spawnClearance ^ 2 then
				return nil
			end
		end
		-- The shell rule and the cave-free rule, column by column, on the full detail heights.
		for x = ax, bx do
			for z = az, bz do
				local first = -1
				for y = 0, LAYERS - 1 do
					if readu8(shape, cellIndex(x, y, z)) ~= OUT then
						first = y
						break
					end
				end
				if first < 0 then
					continue
				end
				local h = terrain.height(x0 + x, z0 + z)
				if h - (base + first) >= CAVE_FREE then
					return nil
				end
				for y = first, LAYERS - 1 do
					local v = readu8(shape, cellIndex(x, y, z))
					if v == BARRIER or v == SHELL then
						local wy = base + y
						if y >= SURFACE_LAYER then
							if wy >= h and wy < SEA then
								return nil -- water beside the bowl
							end
						elseif wy >= h then
							return nil -- air or water beside the lava
						end
					end
				end
			end
		end
		if not terrain.free(x0 - PROTECT, z0 - PROTECT, x0 + BOX - 1 + PROTECT, z0 + BOX - 1 + PROTECT) then
			return nil
		end
		return table.freeze({ x = x0, y = base, z = z0, shape = shape, cells = lava, underground = false })
	end

	local function candidate(cx: number, cz: number): Lake?
		local key = cellKey(cx, cz)
		local entry = recent[key]
		if entry == nil then
			entry = older[key] or { lake = decide(cx, cz) }
			if count >= 4096 then
				older, recent, count = recent, {}, 0
			end
			recent[key] = entry
			count += 1
		end
		return entry.lake
	end

	local function surfaceLakes(minX: number, minZ: number, maxX: number, maxZ: number): { Lake }
		local list: { Lake } = {}
		-- A box's corner lies in its cell, so it reaches up to 2 BOX - 2 blocks past the cell's start.
		local reach = 2 * BOX - 2 + PROTECT
		for cz = (minZ - reach) // BOX, (maxZ + PROTECT) // BOX do
			for cx = (minX - reach) // BOX, (maxX + PROTECT) // BOX do
				local lake = candidate(cx, cz)
				if
					lake
					and lake.x - PROTECT <= maxX
					and lake.x + BOX - 1 + PROTECT >= minX
					and lake.z - PROTECT <= maxZ
					and lake.z + BOX - 1 + PROTECT >= minZ
				then
					table.insert(list, lake)
				end
			end
		end
		return list
	end

	local function writeSurface(
		lakes: { Lake },
		data: buffer,
		level: number,
		originX: number,
		originZ: number,
		cells: number,
		topCells: { number }
	): number
		local lowest = huge
		local step = ChunkLayout.steps(level)
		local half = step // 2
		local minX, minZ = originX - step, originZ - step
		for _, lake in lakes do
			local shape, base = lake.shape, lake.y
			if level == 0 then
				local xa, xb = math.max(lake.x, minX), math.min(lake.x + BOX - 1, minX + P - 1)
				local za, zb = math.max(lake.z, minZ), math.min(lake.z + BOX - 1, minZ + P - 1)
				for wz = za, zb do
					local pz = wz - minZ
					for wx = xa, xb do
						local px = wx - minX
						local col = pz * P + px
						local dug = huge
						for y = 0, LAYERS - 1 do
							local v = readu8(shape, cellIndex(wx - lake.x, y, wz - lake.z))
							local wy = base + y
							if v == OUT or v == SHELL or wy < 1 or wy >= cells then
								continue
							end
							local o = (wy * LAYER + col) * 2
							local block = readu16(data, o)
							if v == BARRIER then
								if readu8(class, block) == ROCK then
									writeu16(data, o, STONE)
								end
							elseif block ~= BEDROCK then
								local new = if y < SURFACE_LAYER then LAVA else AIR
								if block ~= new then
									writeu16(data, o, new)
									if wy < dug then
										dug = wy
									end
								end
							end
						end
						if dug <= topCells[col + 1] then
							topCells[col + 1] = dug - 1
						end
						if dug < lowest then
							lowest = dug
						end
					end
				end
			else
				-- Point-sampled: lava in the top cell of a column whose sample block lies over the
				-- lake's lava.
				for pz = 0, P - 1 do
					local lz = minZ + pz * step + half - lake.z
					if lz < 0 or lz >= BOX then
						continue
					end
					for px = 0, P - 1 do
						local lx = minX + px * step + half - lake.x
						if lx < 0 or lx >= BOX then
							continue
						end
						local wet = false
						for y = 1, SURFACE_LAYER - 1 do
							if readu8(shape, cellIndex(lx, y, lz)) == LAKE then
								wet = true
								break
							end
						end
						local col = pz * P + px
						local top = topCells[col + 1]
						if wet and top >= 1 and top < cells then
							writeu16(data, (top * LAYER + col) * 2, LAVA)
							topCells[col + 1] = top - 1
							if top < lowest then
								lowest = top
							end
						end
					end
				end
			end
		end
		return lowest
	end

	local depth = undergroundCfg.Depth
	local margin = Config.Caves.SurfaceMargin
	local function underground(
		data: buffer,
		cells: number,
		nx: number,
		nz: number,
		heights: { number },
		carved: Caves.Carved?,
		blocked: (
			(x0: number, y0: number, z0: number, x1: number, y1: number, z1: number) -> boolean
		)?
	): (Lake?, Caves.Carved?)
		if carved == nil or not undergroundCfg.Enabled then
			return nil, carved
		end
		local rng = Hash.rng(Hash.hash2(undergroundSalt, nx, nz))
		if rng:float() * undergroundCfg.Rarity >= 1 then
			return nil, carved
		end
		local originX, originZ = nx * SIZE, nz * SIZE
		for _ = 1, undergroundCfg.Tries do
			-- A random column of the core and height; then down through cave air to a floor.
			local lx, lz = rng:int(1, SIZE - 2), rng:int(1, SIZE - 2)
			local roll = rng:float()
			local col = (lz + 1) * P + lx + 1
			local top = math.min(heights[col + 1] - depth, cells - LAYERS)
			local low = MIN_Y + SURFACE_LAYER + 1
			if top < low then
				continue
			end
			local y = low + math.floor(roll * (top - low + 1))
			if readu16(data, (y * LAYER + col) * 2) ~= CAVE_AIR then
				continue
			end
			local floorY = -1
			for f = y - 1, math.max(y - SCAN, 1), -1 do
				local block = readu16(data, (f * LAYER + col) * 2)
				if block ~= CAVE_AIR then
					if readu8(class, block) == ROCK then
						floorY = f
					end
					break
				end
			end
			if floorY < low or floorY > top then
				continue
			end
			local base = floorY - SURFACE_LAYER
			-- Deep enough everywhere in the box (cave rules: SurfaceMargin under every column).
			local ok = true
			for i = 0, SIZE * SIZE - 1 do
				local h = heights[(i // SIZE + 1) * P + i % SIZE + 2]
				if base + LAYERS + margin >= h then
					ok = false
					break
				end
			end
			if
				ok
				and blocked
				and blocked(originX, base, originZ, originX + SIZE - 1, base + LAYERS - 1, originZ + SIZE - 1)
			then
				ok = false
			end
			if not ok then
				continue
			end
			local shape, lava, ax, az, bx, bz = Lava.shapeOf(rng)
			ok = lava > 0
			-- Minecraft's checks on the chunk's blocks: no liquid beside the bowl, solid rock
			-- beside the lava; and no Air (surface caves) or fluid in the lake itself.
			if ok then
				for x = ax, bx do
					for z = az, bz do
						local c = (z + 1) * P + x + 1
						for ly = 0, LAYERS - 1 do
							local v = readu8(shape, cellIndex(x, ly, z))
							if v == OUT then
								continue
							end
							local block = readu16(data, ((base + ly) * LAYER + c) * 2)
							local k = readu8(class, block)
							if v == LAKE then
								ok = block == CAVE_AIR or k == ROCK
							elseif ly >= SURFACE_LAYER then
								ok = k ~= FLUID and block ~= AIR
							else
								ok = k == ROCK
							end
							if not ok then
								break
							end
						end
						if not ok then
							break
						end
					end
					if not ok then
						break
					end
				end
			end
			if not ok then
				continue
			end
			for x = ax, bx do
				for z = az, bz do
					local c = (z + 1) * P + x + 1
					for ly = 0, LAYERS - 1 do
						local v = readu8(shape, cellIndex(x, ly, z))
						local o = ((base + ly) * LAYER + c) * 2
						if v == LAKE then
							writeu16(data, o, if ly < SURFACE_LAYER then CAVE_LAVA else CAVE_AIR)
						elseif v == BARRIER and readu8(class, readu16(data, o)) == ROCK then
							writeu16(data, o, STONE)
						end
					end
				end
			end
			-- The blobs lie in layers 1..6 of the box.
			local map = Caves.mark(
				carved,
				originX,
				originZ,
				originX + ax,
				base + 1,
				originZ + az,
				originX + bx,
				base + LAYERS - 2,
				originZ + bz
			)
			return table.freeze({ x = originX, y = base, z = originZ, shape = shape, cells = lava, underground = true }),
				map
		end
		return nil, carved
	end

	local function peek(cx: number, cz: number): Lake?
		local key = cellKey(cx, cz)
		local entry = recent[key] or older[key]
		if entry then
			return entry.lake
		end
		return decide(cx, cz)
	end

	return {
		surfaceLakes = surfaceLakes,
		writeSurface = writeSurface,
		underground = underground,
		peek = peek,
	}
end

return Lava

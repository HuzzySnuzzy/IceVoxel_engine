--!strict
--!native
--[[
	Library structures in generated terrain: Minecraft 1.20.1's jigsaw structures with their
	random_spread placement, written into chunks by TerrainGenerator (after trees, before cave
	decoration and ground plants).

	Placement (RandomSpreadStructurePlacement): the world is cut into regions of `spacing` x
	`spacing` chunks per structure. Each region has one start chunk at `region * spacing +
	rand(spacing - separation)` per axis, drawn from (seed, region, salt). The start position is
	that chunk's minimum corner, at y = startHeight (JigsawStructure).

	A start becomes a structure when (in this order, every check on full detail terrain so every
	chunk and level agrees):
	  1. its start piece (Jigsaw.assemble at depth 0) has a centre column in one of the
	     structure's biomes (Minecraft checks the biome there too);
	  2. with `onLand`, that column is dry land (above sea level) and not bare rock (no steeper than
	     the biome allows: the generator's steep rule);
	  3. then the whole structure is assembled (Jigsaw.assemble, `size` levels).
	Assembled starts (and rejected ones) are kept in an LRU per generator, sized by the library
	(CACHE_PER_STRUCTURE per structure), so the dozens of chunks a structure covers assemble it
	once per worker.

	Statelessness: a chunk asks for every start whose `reach` (Library: every block within that
	many blocks of the start position) touches its padded box, and writes their pieces clipped to
	it, the same way trees are written. Pieces are written in a fixed order (structure, region,
	assembly order), so where pieces overlap every chunk agrees on the result.

	Writing a piece (`write`):
	  - each cell's block is the template's, turned (Blocks.rotate via Jigsaw.writeTables); jigsaws
	    become their final state; structure void cells ("keep") leave the world alone; template
	    air clears terrain and trees; DATA markers are air in the template already;
	  - rigid pieces sit at their box's y. Terrain matching pieces put each column's layer 0 on
	    that column's top block: Minecraft's WORLD_SURFACE_WG height (the ground, or the sea's
	    surface over water) minus one, from the chunk's own column heights, which are exactly the
	    full detail heights at level 0; LOD chunks use their own (coarse, skirted) top cell;
	  - `foundation`: under a rigid piece's solid bottom cells, air and water down to the ground
	    (at most FOUNDATION_DEPTH blocks) become the column's biome filler, a simple stand-in for
	    Minecraft's beard terrain adaptation;
	  - LOD chunks (up to Config.StructureMaxLevel) point-sample like Generation/Structures/Writer:
	    a cell takes the block the structure puts at its sample point, so buildings keep their
	    real size from afar.
	`write` returns one above the highest cell it wrote with something other than air (for
	`emptyAbove`) and the lowest cell it wrote with a block that is not opaque or cave air (for
	`solidBelow`).

	Trees: a vegetation spot is refused (`treeAllowed`) within TREE_CLEARANCE blocks of a rigid
	piece or PATH_CLEARANCE of a terrain matching one, so no canopy is cut by a hut's box and no
	trunk stands in a path. The chunk asks for starts within twice the vegetation radius of its
	padded box, so every chunk that runs a spot sees the same pieces near it.

	Containers: `container(x, y, z)` gives the items the template stores for a generated block
	with slots (a chest) at a world position, nil when no piece has one there (or a later piece
	wrote over it): the server fills a generated chest from it the first time its contents are
	needed.

	Fixed layouts: `new`'s optional `layout` replaces the random spread: it lists the starts
	reaching a block rectangle (in write order, the same for every rectangle that holds them),
	and everything above (writing, trees, containers) works from it. The debug structures world
	(Generation/DebugWorlds) lays out every template of the library that way.

	Locating (/locate, Generation/Locate): `probe` is a start's first step alone (the start piece
	and its centre column's biome and ground, about 21 µs) for any region, never cached, so a
	search over thousands of regions leaves the LRU to the chunks; `assembleAt` is the cached
	assembly, for the few candidates that might be nearest. `pieceBlocks` lists where the starts'
	pieces put blocks of a set (points of interest: chests, furnaces...), from each template's
	cells (worked out once per template and rotation), so /locate poi finds generated chests
	without generating their chunks.
]]

local Config = require(script.Parent.Parent.Config)
local Blocks = require(script.Parent.Parent.Blocks)
local Biomes = require(script.Parent.Parent.Biomes)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)
local Hash = require(script.Parent.Parent.Util.Hash)
local Jigsaw = require(script.Parent.Parent.Structures.Jigsaw)
local Library = require(script.Parent.Parent.Structures.Library)
local Transform = require(script.Parent.Parent.Structures.Transform)

type Piece = Jigsaw.Piece
type Template = Library.Template
type Structure = Library.Structure
export type ContainerItem = Library.ContainerItem

local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED
local LAYER = ChunkLayout.LAYER
local SEA = Config.SeaLevel
local AIR = Blocks.AIR
local TERRAIN_MATCHING = Jigsaw.TERRAIN_MATCHING

local readu16 = buffer.readu16
local writeu16 = buffer.writeu16
local readu8 = buffer.readu8
local huge = math.huge

-- Cells writing these never lower solidBelow (opaque blocks, cave air, cave twins).
local cullHidden = Blocks.cullLutHiddenCaves
local solidLut = Blocks.solidLut

-- What a foundation may fill: air and fluids (water a piece stands in).
local FILLABLE: { [number]: boolean } = { [AIR] = true }
for id = 0, Blocks.count - 1 do
	if Blocks.get(id).fluid then
		FILLABLE[id] = true
	end
end

--[[
	The terrain the placer reads, all at full detail (every chunk and level must agree):
	  firstFreeHeight  Minecraft's WORLD_SURFACE_WG: the first air above the ground, or above the
	                   sea's surface over water;
	  biome            the column's biome index;
	  land             whether a start may stand there with `onLand` (dry, not bare rock).
]]
export type Terrain = {
	firstFreeHeight: (x: number, z: number) -> number,
	biome: (x: number, z: number) -> number,
	land: (x: number, z: number) -> boolean,
}

-- An assembled structure (read only).
export type Start = {
	name: string,
	index: number, -- the structure's position in library.structures
	chunkX: number, -- the start chunk
	chunkZ: number,
	x: number, -- the start position (the start chunk's minimum corner)
	z: number,
	pieces: { Piece },
	templates: { Template }, -- per piece
	bounds: { number }, -- union of the piece boxes (minX, minY, minZ, maxX, maxY, maxZ)
	foundation: boolean,
}

-- A chunk being generated, as TerrainGenerator has it.
export type Chunk = {
	data: buffer,
	cells: number, -- cells per column
	level: number,
	originX: number, -- world block of the first core column
	originZ: number,
	-- Per padded column (index pz * PADDED + px + 1): its biome and its top terrain cell (LOD
	-- skirts lowered one cell, as filled).
	biomes: { number },
	topCells: { number },
}

-- A fixed layout (see the header): every start with a piece in the block rectangle (inclusive).
export type Layout = (minX: number, minZ: number, maxX: number, maxZ: number) -> { Start }

export type Placer = {
	library: Library.Library,
	-- Every assembled start with a piece in the block rectangle (inclusive), in write order.
	starts: (minX: number, minZ: number, maxX: number, maxZ: number) -> { Start },
	-- Highest block y the starts' pieces may write in the rectangle (-1: none). `ground`: the
	-- highest first free height of the rectangle's columns (terrain matching pieces follow it).
	top: (starts: { Start }, minX: number, minZ: number, maxX: number, maxZ: number, ground: number) -> number,
	-- May a tree grow from vegetation spot (x, z)? (`starts` must cover the spot ± TREE_CLEARANCE.)
	treeAllowed: (starts: { Start }, x: number, z: number) -> boolean,
	-- Writes the starts' pieces into the chunk. Returns (one above the highest cell written with a
	-- block other than air, 0 when none; the lowest cell written with a block that is not opaque
	-- or cave air, math.huge when none).
	write: (starts: { Start }, chunk: Chunk) -> (number, number),
	-- Items a generated container at world (x, y, z) starts with, nil when none (a fresh copy).
	container: (x: number, y: number, z: number) -> { ContainerItem }?,
	-- Starts assembled (not served from the cache) so far, for tests and benchmarks.
	assembled: () -> number,
	--[[
		/locate (see the header): the centre column (x, z) of region (rx, rz)'s start piece of
		structure `index` (library.structures) when its start check passes (x nil: no start), never
		cached; the region's assembled start (cached), nil when it has none.
	]]
	probe: (index: number, rx: number, rz: number) -> (number?, number),
	assembleAt: (index: number, rx: number, rz: number) -> Start?,
	--[[
		Appends x, y, z, block to `out` for every cell of `starts`' pieces in the block rectangle
		(inclusive) whose block is marked in `lut` (u8 per block id, not 0: wanted), as the pieces
		write it (turned; a jigsaw's final state). A later piece or a player may have changed it.
	]]
	pieceBlocks: (
		starts: { Start },
		lut: buffer,
		minX: number,
		minZ: number,
		maxX: number,
		maxZ: number,
		out: { number }
	) -> (),
}

local StructureGen = {}

-- Deepest foundation under a rigid piece (blocks).
StructureGen.FOUNDATION_DEPTH = 12
-- No vegetation spot within this many blocks of a rigid / terrain matching piece's box.
StructureGen.TREE_CLEARANCE = 5
StructureGen.PATH_CLEARANCE = 1
-- Assembled (and rejected) starts kept per generator: CACHE_PER_STRUCTURE for each structure of
-- the library, at least CACHE_SIZE. A chunk needs the starts of every structure around it, so a
-- fixed size would thrash (assembling the same starts again and again) once a library holds a
-- few dozen structures.
StructureGen.CACHE_SIZE = 48
StructureGen.CACHE_PER_STRUCTURE = 8

-- Java's (a + b) / 2 (rounds towards zero), as Jigsaw centres boxes.
local function midpoint(a: number, b: number): number
	local s = a + b
	return if s >= 0 then s // 2 else -(-s // 2)
end

-- The start chunk of region (rx, rz) of a structure (RandomSpreadStructurePlacement, linear).
function StructureGen.startChunk(seed: number, structure: Structure, rx: number, rz: number): (number, number)
	local spacing = structure.spacing
	local range = math.max(1, spacing - structure.separation)
	local rng = Hash.rng(Hash.hash3(Hash.hash2(seed, 0x5778C7, 0x0EAC), rx, structure.salt, rz))
	return rx * spacing + rng:int(0, range - 1), rz * spacing + rng:int(0, range - 1)
end

function StructureGen.new(seed: number, library: Library.Library, terrain: Terrain, layout: Layout?): Placer
	local structures = library.structures
	local templateOf = library.template
	local poolOf = library.pool
	local assemblySalt = Hash.hash2(seed, Hash.string("structures.assembly"), 0x1A65)
	local firstFreeHeight = terrain.firstFreeHeight

	--[[ Assembly, cached ]]

	type Entry = { start: Start | false, used: number }
	local cache: { [string]: Entry } = {}
	local cached, clock, assembledCount = 0, 0, 0
	local capacity = math.max(StructureGen.CACHE_SIZE, StructureGen.CACHE_PER_STRUCTURE * #structures)

	local function remember(key: string, start: Start | false)
		if cached >= capacity then
			-- Drop the least recently used entry.
			local oldest, oldestKey = huge, nil
			for k, entry in cache do
				if entry.used < oldest then
					oldest, oldestKey = entry.used, k
				end
			end
			if oldestKey then
				cache[oldestKey] = nil
				cached -= 1
			end
		end
		clock += 1
		cache[key] = { start = start, used = clock }
		cached += 1
	end

	-- The assembly options of the start in chunk (cx, cz), the start piece alone (maxDepth 0).
	local function startOptions(structure: Structure, cx: number, cz: number): Jigsaw.Options
		return {
			seed = Hash.hash3(assemblySalt, cx, structure.salt, cz),
			startPool = structure.startPool,
			startJigsawName = structure.startJigsawName,
			x = cx * SIZE,
			z = cz * SIZE,
			startHeight = structure.startHeight,
			projectToHeightmap = structure.projectToHeightmap,
			firstFreeHeight = firstFreeHeight,
			maxDepth = 0,
			maxDistance = structure.maxDistance,
			pool = poolOf,
			template = templateOf,
		}
	end

	-- The start check: the centre column (x, z) of the start piece when it stands in one of the
	-- structure's biomes (and on land with `onLand`), x nil otherwise.
	local function startCheck(structure: Structure, options: Jigsaw.Options): (number?, number)
		local first = Jigsaw.assemble(options)[1]
		if first == nil then
			return nil, 0
		end
		local box = first.box
		local mx, mz = midpoint(box[1], box[4]), midpoint(box[3], box[6])
		if structure.biomeSet[terrain.biome(mx, mz)] ~= true or (structure.onLand and not terrain.land(mx, mz)) then
			return nil, 0
		end
		return mx, mz
	end

	local function assemble(index: number, structure: Structure, rx: number, rz: number): Start?
		local key = `{index}:{rx}:{rz}`
		local entry = cache[key]
		if entry then
			clock += 1
			entry.used = clock
			return if entry.start then entry.start else nil
		end
		assembledCount += 1
		local cx, cz = StructureGen.startChunk(seed, structure, rx, rz)
		local x, z = cx * SIZE, cz * SIZE
		local options = startOptions(structure, cx, cz)
		-- The start piece alone first (the same draws begin the full assembly): its centre column
		-- decides the biome and the ground.
		local ok = startCheck(structure, options) ~= nil
		local start: Start? = nil
		if ok then
			options.maxDepth = structure.size
			local pieces = Jigsaw.assemble(options)
			local templates: { Template } = {}
			local kept: { Piece } = {}
			for _, piece in pieces do
				local t = templateOf(piece.template)
				if t then
					table.insert(kept, piece)
					table.insert(templates, t)
				end
			end
			local bounds = Jigsaw.bounds(kept)
			if bounds then
				start = {
					name = structure.name,
					index = index,
					chunkX = cx,
					chunkZ = cz,
					x = x,
					z = z,
					pieces = kept,
					templates = templates,
					bounds = bounds,
					foundation = structure.foundation,
				}
			end
		end
		remember(key, start or false)
		return start
	end

	local function starts(minX: number, minZ: number, maxX: number, maxZ: number): { Start }
		if layout then
			return layout(minX, minZ, maxX, maxZ)
		end
		local list: { Start } = {}
		for index, structure in structures do
			local reach = structure.reach
			local spacing = structure.spacing
			-- Start chunks whose start position (minimum corner) is within reach of the rectangle.
			local cx0, cx1 = -((reach - minX) // SIZE), (maxX + reach) // SIZE
			local cz0, cz1 = -((reach - minZ) // SIZE), (maxZ + reach) // SIZE
			for rx = cx0 // spacing, cx1 // spacing do
				for rz = cz0 // spacing, cz1 // spacing do
					local cx, cz = StructureGen.startChunk(seed, structure, rx, rz)
					if cx >= cx0 and cx <= cx1 and cz >= cz0 and cz <= cz1 then
						local start = assemble(index, structure, rx, rz)
						if start then
							local b = start.bounds
							if b[1] <= maxX and b[4] >= minX and b[3] <= maxZ and b[6] >= minZ then
								table.insert(list, start)
							end
						end
					end
				end
			end
		end
		return list
	end

	local function top(list: { Start }, minX: number, minZ: number, maxX: number, maxZ: number, ground: number): number
		local highest = -1
		for _, start in list do
			for k, piece in start.pieces do
				local box = piece.box
				if box[1] <= maxX and box[4] >= minX and box[3] <= maxZ and box[6] >= minZ then
					local y = if piece.projection == TERRAIN_MATCHING
						then ground - 2 + start.templates[k].size[2]
						else box[5]
					if y > highest then
						highest = y
					end
				end
			end
		end
		return highest
	end

	local function treeAllowed(list: { Start }, x: number, z: number): boolean
		local clearance = StructureGen.TREE_CLEARANCE
		for _, start in list do
			local b = start.bounds
			if x < b[1] - clearance or x > b[4] + clearance or z < b[3] - clearance or z > b[6] + clearance then
				continue
			end
			for _, piece in start.pieces do
				local box = piece.box
				local m = if piece.projection == TERRAIN_MATCHING then StructureGen.PATH_CLEARANCE else clearance
				if x >= box[1] - m and x <= box[4] + m and z >= box[3] - m and z <= box[6] + m then
					return false
				end
			end
		end
		return true
	end

	--[[ Writing ]]

	local foundationDepth = StructureGen.FOUNDATION_DEPTH

	local function write(list: { Start }, chunk: Chunk): (number, number)
		local data, cells, level = chunk.data, chunk.cells, chunk.level
		local step, stepY = ChunkLayout.steps(level)
		local half, halfY = step // 2, stepY // 2
		local minX, minZ = chunk.originX - step, chunk.originZ - step
		local stride = LAYER * 2
		-- Highest cell whose sample point is below sea level (the water's top cell when filled).
		local waterTop = (SEA - halfY + stepY - 1) // stepY - 1
		local topCells, biomes = chunk.topCells, chunk.biomes
		local written, lowest = 0, huge

		for _, start in list do
			for k, piece in start.pieces do
				local box = piece.box
				-- Padded columns whose sample point is in the piece's box.
				local px0 = math.max(0, -((minX + half - box[1]) // step))
				local px1 = math.min(P - 1, (box[4] - minX - half) // step)
				local pz0 = math.max(0, -((minZ + half - box[3]) // step))
				local pz1 = math.min(P - 1, (box[6] - minZ - half) // step)
				if px0 > px1 or pz0 > pz1 then
					continue
				end
				local template = start.templates[k]
				local palette, finals = Jigsaw.writeTables(piece, template)
				local tcells = template.cells
				local size = template.size
				local sx, sy, sz = size[1], size[2], size[3]
				local rotation = piece.rotation
				local terrainMatching = piece.projection == TERRAIN_MATCHING
				local foundation = start.foundation and not terrainMatching

				for pz = pz0, pz1 do
					local wz = minZ + pz * step + half
					for px = px0, px1 do
						local wx = minX + px * step + half
						local lx, _, lz = Transform.inverse(wx - piece.x, 0, wz - piece.z, sx, sz, rotation)
						local column = pz * P + px + 1
						-- World y of the piece's layer 0 in this column.
						local base
						if terrainMatching then
							local cell = topCells[column]
							if cell < waterTop then
								cell = waterTop
							end
							base = cell * stepY + halfY
						else
							base = piece.y
						end
						local offset = (pz * P + px) * 2
						local cy0 = math.max(0, (base - halfY + stepY - 1) // stepY)
						local cy1 = math.min(cells - 1, (base + sy - 1 - halfY) // stepY)
						for cy = cy0, cy1 do
							local ly = cy * stepY + halfY - base
							local index = (ly * sz + lz) * sx + lx
							local v = readu16(tcells, index * 2)
							if v == 0 then
								continue
							end
							local block = finals[index]
							if block == nil then
								block = palette[v]
							elseif block < 0 then
								continue
							end
							writeu16(data, offset + cy * stride, block)
							if block ~= AIR and cy >= written then
								written = cy + 1
							end
							if cy < lowest and readu8(cullHidden, block) == 0 then
								lowest = cy
							end
						end

						-- Foundation: under a solid bottom cell, air and water down to the ground.
						if foundation then
							local index = lz * sx + lx
							local v = readu16(tcells, index * 2)
							local bottom = if v == 0 then nil else finals[index] or palette[v]
							if bottom and bottom >= 0 and readu8(solidLut, bottom) == 1 then
								local filler = Biomes.list[biomes[column]].filler
								local first = math.min(cells - 1, (base - 1 - halfY) // stepY)
								local last = math.max(0, -((halfY - base + foundationDepth) // stepY))
								for cy = first, last, -1 do
									local at = offset + cy * stride
									if not FILLABLE[readu16(data, at)] then
										break
									end
									writeu16(data, at, filler)
									if cy >= written then
										written = cy + 1
									end
								end
							end
						end
					end
				end
			end
		end
		return written, lowest
	end

	--[[ Generated containers ]]

	local function container(x: number, y: number, z: number): { ContainerItem }?
		local found: Template? = nil
		local fx, fy, fz = 0, 0, 0
		for _, start in starts(x, z, x, z) do
			for k, piece in start.pieces do
				local box = piece.box
				if x < box[1] or x > box[4] or z < box[3] or z > box[6] then
					continue
				end
				local template = start.templates[k]
				local size = template.size
				local sx, sy, sz = size[1], size[2], size[3]
				local base = if piece.projection == TERRAIN_MATCHING then firstFreeHeight(x, z) - 1 else piece.y
				local ly = y - base
				if ly < 0 or ly >= sy then
					continue
				end
				local lx, _, lz = Transform.inverse(x - piece.x, 0, z - piece.z, sx, sz, piece.rotation)
				local index = (ly * sz + lz) * sx + lx
				if readu16(template.cells, index * 2) == 0 then
					continue
				end
				local _, finals = Jigsaw.writeTables(piece, template)
				local final = finals[index]
				if final and final < 0 then
					continue
				end
				-- The last piece writing the cell decides what is there.
				found, fx, fy, fz = if final then nil else template, lx, ly, lz
			end
		end
		if found == nil then
			return nil
		end
		for _, c in found.containers do
			if c.x == fx and c.y == fy and c.z == fz then
				local items: { ContainerItem } = {}
				for i, item in c.items do
					items[i] = { slot = item.slot, item = item.item, count = item.count, damage = item.damage }
				end
				return items
			end
		end
		return nil
	end

	--[[ Locating ]]

	local function probe(index: number, rx: number, rz: number): (number?, number)
		local structure = structures[index]
		local cx, cz = StructureGen.startChunk(seed, structure, rx, rz)
		return startCheck(structure, startOptions(structure, cx, cz))
	end

	local function assembleAt(index: number, rx: number, rz: number): Start?
		return assemble(index, structures[index], rx, rz)
	end

	local function pieceBlocks(
		list: { Start },
		lut: buffer,
		minX: number,
		minZ: number,
		maxX: number,
		maxZ: number,
		out: { number }
	)
		for _, start in list do
			for k, piece in start.pieces do
				local box = piece.box
				if box[1] > maxX or box[4] < minX or box[3] > maxZ or box[6] < minZ then
					continue
				end
				local template = start.templates[k]
				local palette, finals = Jigsaw.writeTables(piece, template)
				local size = template.size
				local sx, sz = size[1], size[3]
				local rotation = piece.rotation
				local terrainMatching = piece.projection == TERRAIN_MATCHING
				for _, index in StructureGen.cellsOf(template, piece, lut) do
					local final = finals[index]
					local block = if final ~= nil then final else palette[readu16(template.cells, index * 2)]
					local lx = index % sx
					local lz = (index // sx) % sz
					local ly = index // (sx * sz)
					local tx, _, tz = Transform.position(lx, 0, lz, sx, sz, rotation)
					local x, z = piece.x + tx, piece.z + tz
					if x < minX or x > maxX or z < minZ or z > maxZ then
						continue
					end
					local base = if terrainMatching then firstFreeHeight(x, z) - 1 else piece.y
					table.insert(out, x)
					table.insert(out, base + ly)
					table.insert(out, z)
					table.insert(out, block)
				end
			end
		end
	end

	return {
		library = library,
		starts = starts,
		top = top,
		treeAllowed = treeAllowed,
		write = write,
		container = container,
		assembled = function(): number
			return assembledCount
		end,
		probe = probe,
		assembleAt = assembleAt,
		pieceBlocks = pieceBlocks,
	}
end

--[[
	The cells of `template` (indices, as Jigsaw.writeTables reads them: (ly * sz + lz) * sx + lx)
	whose block, as `piece`'s rotation writes it (a jigsaw's final state), is marked in `lut`;
	worked out once per template, rotation and lut.
]]
type CellLists = { lut: buffer, byRotation: { [number]: { number } } }
local cellLists: { [Template]: CellLists } = setmetatable({}, { __mode = "k" }) :: any
function StructureGen.cellsOf(template: Template, piece: Piece, lut: buffer): { number }
	local lists = cellLists[template]
	if lists == nil or lists.lut ~= lut then
		local new: CellLists = { lut = lut, byRotation = {} }
		cellLists[template] = new
		lists = new
	end
	assert(lists)
	local rotation = piece.rotation % 4
	local found = lists.byRotation[rotation]
	if found == nil then
		local list: { number } = {}
		local palette, finals = Jigsaw.writeTables(piece, template)
		local size = template.size
		local cells = template.cells
		for index = 0, size[1] * size[2] * size[3] - 1 do
			local v = readu16(cells, index * 2)
			if v == 0 then
				continue
			end
			local final = finals[index]
			local block = if final ~= nil then final else palette[v]
			if block >= 0 and readu8(lut, block) ~= 0 then
				table.insert(list, index)
			end
		end
		lists.byRotation[rotation] = list
		found = list
	end
	return found
end

return StructureGen

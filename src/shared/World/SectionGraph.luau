--!strict
--!native
--[[
	Cave visibility graph: which 16^3 sections of full detail chunks an underground camera can see
	into (Minecraft's "advanced cave culling", adapted to IceVoxel's hidden caves).

	Caves are meshed as rock (Blocks.cullLutHiddenCaves) except in revealed sections, so the client
	only pays for the cave walls it can see. Revealing a sphere around the camera wastes parts on
	caves behind rock and cuts tunnels off at its edge; instead the streamer reveals the sections a
	search from the camera reaches through connected air.

	Per section (worker side, `compute` / `build` / `refresh`): a flood fill over the passable cells
	(not opaque: Blocks.cullLut 0), done on 16-bit rows (row y * 16 + z, bit x) instead of cells,
	finds the connected pockets of air. For each pocket it records the faces of the section it
	touches; every pair of faces touched by one pocket is connected. Pockets come in three classes:
	  * cave pockets: they hold cave cells (cave air, cave twins);
	  * sealed pockets: no cave cells and not touching the section's top face (dug tunnels, rooms);
	  * the rest: open air, usually the sky.
	The search follows cave and sealed pockets only, and in buried sections (entirely below the
	chunk's lowest generated surface, where all open air was dug) every pocket. Following all air
	would leak out of a cave mouth into the sky and visit thousands of sections; sky air always
	reaches the top of its section (the terrain is a height field), so a pocket that doesn't is
	underground.

	Section value (u32, `value`; a graph is one per section, BYTES per chunk):
	  bits 0-14   pairs of faces connected by a followed pocket (PAIR order: (0,1), (0,2) ... (4,5))
	  bits 15-20  faces touched by a followed pocket
	  bits 21-26  faces touched by any passable cell (where a camera in the section can look out)
	  bit  27     CAVES: the section holds cave cells
	  bit  28     BURIED: the section lies below the chunk's lowest generated surface
	Faces are numbered like GreedyMesher.Border's hidden bits: 0 -X, 1 +X, 2 -Z, 3 +Z, 4 -Y, 5 +Y
	(so a cap mask is a set of face bits), and the opposite of face f is f xor 1.

	Search (main thread, `search`), like Minecraft's: each section is visited once, a section is
	left only through a face connected to a face it was seen through, and a step never goes back
	against a direction already taken on the path (a straight line of sight never does), so the
	search does not wrap around behind rock. It starts from the camera's section and the
	neighbours its air touches (leaving those through any face of theirs: that covers a camera
	next to a section corner) and works outwards in distance bands, nearest first. It stops `reach`
	blocks from the camera (section centres) and, past `budget` sections, drops the whole band
	where that happened, so the cut is a distance and moves little with the camera (the
	Underlands). Every section reached is revealed: one entered only through rock still has to draw
	its walls facing the cave next door. Sections of full detail chunks not generated yet are
	reported as `pending` (reveal them when they are generated).

	Then (`tracker`): sections stay revealed until they were unreachable for a while (hysteresis),
	and `capMask` closes the tunnels of a revealed section in stone where they run into hidden
	space. A section the search misses shows such a stone cap, never the void.

	Pure Luau (buffers, bit32), tested in tests/spec/SectionGraph against a per-cell flood fill.
]]

local Blocks = require(script.Parent.Parent.Blocks)
local Config = require(script.Parent.Parent.Config)
local ChunkLayout = require(script.Parent.ChunkLayout)

local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED
local LAYER = ChunkLayout.LAYER
local SECTION = Config.SectionHeight
local SECTIONS = Config.WorldHeight // SECTION
assert(SIZE == 16 and SECTION == 16, "SectionGraph works on 16 x 16 x 16 sections")

local band, bor, bxor, bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
local lshift, rshift, btest = bit32.lshift, bit32.rshift, bit32.btest
local readu8, readu16, writeu16 = buffer.readu8, buffer.readu16, buffer.writeu16
local readu32, writeu32 = buffer.readu32, buffer.writeu32

local SectionGraph = {}

SectionGraph.NEG_X = 0
SectionGraph.POS_X = 1
SectionGraph.NEG_Z = 2
SectionGraph.POS_Z = 3
SectionGraph.NEG_Y = 4
SectionGraph.POS_Y = 5

SectionGraph.MASK = 0x1FFFFF -- pairs and faces of the followed pockets
SectionGraph.FACES_SHIFT = 15
SectionGraph.PASSABLE_SHIFT = 21
SectionGraph.CAVES = 0x8000000
SectionGraph.BURIED = 0x10000000
SectionGraph.SECTIONS = SECTIONS
SectionGraph.BYTES = SECTIONS * 4

local MASK = SectionGraph.MASK
local CAVES = SectionGraph.CAVES
local BURIED = SectionGraph.BURIED
local UP = lshift(1, SectionGraph.POS_Y)

-- Pair bit index of faces a ~= b, and the 15-bit pair mask of each 6-bit face set.
local PAIR: { number } = table.create(36, -1)
do
	local k = 0
	for a = 0, 5 do
		for b = a + 1, 5 do
			PAIR[a * 6 + b + 1] = k
			PAIR[b * 6 + a + 1] = k
			k += 1
		end
	end
end
local pairsOf: { number } = table.create(64, 0)
for faces = 0, 63 do
	local m = 0
	for a = 0, 5 do
		for b = a + 1, 5 do
			if btest(faces, lshift(1, a)) and btest(faces, lshift(1, b)) then
				m = bor(m, lshift(1, PAIR[a * 6 + b + 1]))
			end
		end
	end
	pairsOf[faces + 1] = m
end
-- All pairs and all faces: one pocket touching every face (a section of open air).
SectionGraph.FULL = bor(pairsOf[64], lshift(63, 15))
local FULL = SectionGraph.FULL

-- Are faces a and b connected in `mask` (a == b: is face a touched)?
function SectionGraph.connected(mask: number, a: number, b: number): boolean
	if a == b then
		return btest(mask, lshift(1, 15 + a))
	end
	return btest(mask, lshift(1, PAIR[a * 6 + b + 1]))
end

--[[ Per section: the flood fill ]]

-- Block class (u8 per block id): 0 opaque, 1 passable, 3 passable cave cell.
local classLut = buffer.create(Blocks.count)
for id = 0, Blocks.count - 1 do
	if readu8(Blocks.cullLut, id) == 0 then
		local cave = id == Blocks.CAVE_AIR or readu8(Blocks.caveTwinLut, id) == 1
		buffer.writeu8(classLut, id, if cave then 3 else 1)
	end
end

-- Scratch: passable / cave cells per row, rows already filled, the fill's queue of row runs.
local openRows = buffer.create(512)
local caveRows = buffer.create(512)
local seen = buffer.create(512)
local qRow = buffer.create(4096 * 2)
local qRun = buffer.create(4096 * 2)

-- Flood fill of the rows in openRows / caveRows: cave, open and sealed masks.
local function flood(): (number, number, number)
	buffer.fill(seen, 0, 0, 512)
	local cave, open, sealed = 0, 0, 0
	for r0 = 0, 255 do
		local rem = band(readu16(openRows, r0 * 2), bnot(readu16(seen, r0 * 2)))
		while rem ~= 0 do
			-- The lowest run of set bits of the row starts a pocket (unless the last pocket took it).
			rem = band(rem, bnot(readu16(seen, r0 * 2)))
			if rem == 0 then
				break
			end
			local low = band(rem, bnot(rem) + 1)
			local run = band(bxor(rem + low, rem), rem)
			rem = band(rem, bnot(run))
			writeu16(seen, r0 * 2, bor(readu16(seen, r0 * 2), run))
			writeu16(qRow, 0, r0)
			writeu16(qRun, 0, run)
			local head, tail = 0, 1
			local faces, hasCave = 0, false
			while head < tail do
				local r = readu16(qRow, head * 2)
				local span = readu16(qRun, head * 2)
				head += 1
				local y = rshift(r, 4)
				local z = band(r, 15)
				if btest(span, 1) then
					faces = bor(faces, 1)
				end
				if btest(span, 0x8000) then
					faces = bor(faces, 2)
				end
				if z == 0 then
					faces = bor(faces, 4)
				elseif z == 15 then
					faces = bor(faces, 8)
				end
				if y == 0 then
					faces = bor(faces, 16)
				elseif y == 15 then
					faces = bor(faces, 32)
				end
				if not hasCave and btest(span, readu16(caveRows, r * 2)) then
					hasCave = true
				end
				-- Runs of the four neighbouring rows (z - 1, z + 1, y - 1, y + 1) overlapping this run.
				for k = 1, 4 do
					local q
					if k == 1 then
						if z == 0 then
							continue
						end
						q = r - 1
					elseif k == 2 then
						if z == 15 then
							continue
						end
						q = r + 1
					elseif k == 3 then
						if y == 0 then
							continue
						end
						q = r - 16
					else
						if y == 15 then
							continue
						end
						q = r + 16
					end
					local s = readu16(seen, q * 2)
					local cand = band(readu16(openRows, q * 2), bnot(s))
					if btest(cand, span) then
						while cand ~= 0 do
							local lo = band(cand, bnot(cand) + 1)
							local rr = band(bxor(cand + lo, cand), cand)
							cand = band(cand, bnot(rr))
							if btest(rr, span) then
								s = bor(s, rr)
								writeu16(qRow, tail * 2, q)
								writeu16(qRun, tail * 2, rr)
								tail += 1
							end
						end
						writeu16(seen, q * 2, s)
					end
				end
			end
			local m = bor(pairsOf[faces + 1], lshift(faces, 15))
			if hasCave then
				cave = bor(cave, m)
			else
				open = bor(open, m)
				if not btest(faces, UP) then
					sealed = bor(sealed, m)
				end
			end
		end
	end
	return cave, open, sealed
end

--[[
	What the generator knows about a fresh chunk, so most cells need not be read (`build`): the
	cave carver's lattice (Generation/Caves' Carved, cells cellXZ x cellY x cellXZ blocks, world
	aligned: flag 0 nothing carved, 2 cave air throughout), the chunk's origin, the terrain height
	of each core column (u16 cells at (z * 16 + x) * 2, TerrainGenerator's `surface`) and the
	sections to read cell by cell anyway (edits, library structures).
	A lattice cell flagged 2 is all cave cells (glow lichen only turns cave air into cave twins);
	one flagged 0 (or outside the lattice) and below every column's terrain height is all rock
	(ores only replace stone). Anything else is read.
]]
export type Hint = {
	carved: { x: number, y: number, z: number, nx: number, ny: number, nz: number, flags: buffer }?,
	cellXZ: number,
	cellY: number,
	originX: number,
	originZ: number,
	surface: buffer,
	exact: { [number]: boolean }?,
}

-- Fills openRows / caveRows for cells y0 .. y0 + 15 by reading every cell; returns the number of
-- passable and cave cells (as sums of row bits: zero or not is all that matters).
local function readRows(data: buffer, height: number, y0: number): (number, number)
	local passable, caves = 0, 0
	for y = 0, 15 do
		local yy = y0 + y
		if yy >= height then
			for z = 0, 15 do
				writeu16(openRows, (y * 16 + z) * 2, 0xFFFF)
				writeu16(caveRows, (y * 16 + z) * 2, 0)
			end
			passable += 256
		else
			local rowBase = yy * LAYER
			for z = 0, 15 do
				local base = (rowBase + (z + 1) * P + 1) * 2
				local o, c = 0, 0
				for x = 0, 15 do
					local k = readu8(classLut, readu16(data, base + x * 2))
					if k ~= 0 then
						local bit = lshift(1, x)
						o += bit
						if k == 3 then
							c += bit
						end
					end
				end
				writeu16(openRows, (y * 16 + z) * 2, o)
				writeu16(caveRows, (y * 16 + z) * 2, c)
				passable += o
				caves += c
			end
		end
	end
	return passable, caves
end

-- Same as readRows, reading only the cells the lattice doesn't settle (see Hint).
local noFlags = buffer.create(0)
local function hintRows(data: buffer, height: number, y0: number, hint: Hint, groupGround: { number }): (number, number)
	local carved = hint.carved
	local cellXZ, cellY = hint.cellXZ, hint.cellY
	local flags, lx0, ly0, lz0, lnx, lny, lnz = noFlags, 0, 0, 0, 0, 0, 0
	if carved then
		flags, lnx, lny, lnz = carved.flags, carved.nx, carved.ny, carved.nz
		-- Lattice indices of the chunk's first core column and of cell 0.
		lx0 = (hint.originX - carved.x) // cellXZ
		lz0 = (hint.originZ - carved.z) // cellXZ
		ly0 = carved.y
	end
	local passable, caves = 0, 0
	for y = 0, 15 do
		local yy = y0 + y
		if yy >= height then
			for z = 0, 15 do
				writeu16(openRows, (y * 16 + z) * 2, 0xFFFF)
				writeu16(caveRows, (y * 16 + z) * 2, 0)
			end
			passable += 256
			continue
		end
		local rowBase = yy * LAYER
		-- The lattice layer of this row (-1: outside the lattice, nothing carved).
		local iy = (yy - ly0) // cellY
		if lnx == 0 or iy < 0 or iy >= lny then
			iy = -1
		end
		for z = 0, 15 do
			local base = (rowBase + (z + 1) * P + 1) * 2
			local o, c = 0, 0
			local gz = z // 4
			local layerRow = if iy >= 0 then (iy * lnz + lz0 + gz) * lnx + lx0 else -1
			for gx = 0, 3 do
				local flag = if layerRow >= 0 then readu8(flags, layerRow + gx) else 0
				local bits = lshift(15, gx * 4)
				if flag == 2 then
					o += bits
					c += bits
				elseif flag ~= 0 or yy >= groupGround[gz * 4 + gx + 1] then
					for x = gx * 4, gx * 4 + 3 do
						local k = readu8(classLut, readu16(data, base + x * 2))
						if k ~= 0 then
							local bit = lshift(1, x)
							o += bit
							if k == 3 then
								c += bit
							end
						end
					end
				end
			end
			writeu16(openRows, (y * 16 + z) * 2, o)
			writeu16(caveRows, (y * 16 + z) * 2, c)
			passable += o
			caves += c
		end
	end
	return passable, caves
end

-- See SectionGraph.masks; `hint` / `groupGround` from `build` (nil: read every cell).
local function sectionMasks(
	data: buffer,
	height: number,
	s: number,
	hint: Hint?,
	groupGround: { number }?
): (number, number, number, boolean)
	local y0 = s * SECTION
	if y0 >= height then
		return 0, FULL, 0, false
	end
	local passable, caves
	if hint and groupGround and not (hint.exact and hint.exact[s]) then
		passable, caves = hintRows(data, height, y0, hint, groupGround)
	else
		passable, caves = readRows(data, height, y0)
	end
	if passable == 0 then
		return 0, 0, 0, false
	end
	if passable == 256 * 0xFFFF then
		-- All air (the Underlands are mostly that): one pocket touching every face.
		if caves > 0 then
			return FULL, 0, 0, true
		end
		return 0, FULL, 0, false
	end
	local cave, open, sealed = flood()
	return cave, open, sealed, caves > 0
end

--[[
	Connectivity of section `s` of a full detail chunk's padded column `data` (`height` cells per
	column; air above): the cave, open and sealed masks (bits 0-14 pairs, 15-20 faces, see the
	header; sealed pockets are open pockets not touching the top face), and whether it holds cave
	cells.
]]
function SectionGraph.masks(data: buffer, height: number, s: number): (number, number, number, boolean)
	return sectionMasks(data, height, s, nil, nil)
end

-- The section value (see the header) of masks from `masks`.
function SectionGraph.value(cave: number, open: number, sealed: number, hasCave: boolean, buried: boolean): number
	local follow = bor(cave, if buried then open else sealed)
	local passable = rshift(bor(cave, open), 15)
	local v = bor(follow, lshift(passable, 21))
	if hasCave then
		v = bor(v, CAVES)
	end
	if buried then
		v = bor(v, BURIED)
	end
	return v
end

local function sectionValue(
	data: buffer,
	height: number,
	s: number,
	buried: boolean,
	hint: Hint?,
	groupGround: { number }?
): number
	local cave, open, sealed, hasCave = sectionMasks(data, height, s, hint, groupGround)
	return SectionGraph.value(cave, open, sealed, hasCave, buried)
end

-- The value of section `s` (see `masks`; `buried`: below the chunk's lowest generated surface).
function SectionGraph.compute(data: buffer, height: number, s: number, buried: boolean): number
	return sectionValue(data, height, s, buried, nil, nil)
end

-- An empty graph (every section all rock, nothing buried).
function SectionGraph.create(): buffer
	return buffer.create(SectionGraph.BYTES)
end

function SectionGraph.get(graph: buffer, s: number): number
	return readu32(graph, s * 4)
end

--[[
	The graph of a freshly generated full detail chunk. `buryLine`: the chunk's lowest generated
	surface (cells; TerrainGenerator's solidBelow before any edit): sections below it are BURIED.
	Only `sections` are filled in (those that may hold cave cells or player edits: see
	`carvedSections`); every other section is rock or untouched surface, which nothing follows.
	`hint` (optional) saves reading most cells; the result is the same. `yield` (optional) is
	called between sections.
]]
function SectionGraph.build(
	data: buffer,
	height: number,
	buryLine: number,
	sections: { number },
	hint: Hint?,
	yield: (() -> ())?
): buffer
	-- Lowest terrain height of each 4 x 4 group of core columns (index gz * 4 + gx + 1).
	local groupGround: { number }? = nil
	if hint then
		local ground = table.create(16, 0)
		groupGround = ground
		-- (Groups of 4 x 4 core columns are lattice columns: chunk origins are multiples of 16.)
		assert(hint.cellXZ == 4 and hint.originX % 4 == 0 and hint.originZ % 4 == 0, "lattice must be 4 wide")
		for gz = 0, 3 do
			for gx = 0, 3 do
				local lowest = math.huge
				for z = gz * 4, gz * 4 + 3 do
					for x = gx * 4, gx * 4 + 3 do
						lowest = math.min(lowest, readu16(hint.surface, (z * 16 + x) * 2))
					end
				end
				ground[gz * 4 + gx + 1] = lowest
			end
		end
	end
	local graph = buffer.create(SectionGraph.BYTES)
	for s = 0, SECTIONS - 1 do
		if (s + 1) * SECTION <= buryLine then
			writeu32(graph, s * 4, BURIED)
		end
	end
	for _, s in sections do
		if s >= 0 and s < SECTIONS then
			local buried = (s + 1) * SECTION <= buryLine
			writeu32(graph, s * 4, sectionValue(data, height, s, buried, hint, groupGround))
			if yield then
				yield()
			end
		end
	end
	return graph
end

--[[
	Recomputes `sections` of `graph` in place after edits (an edit can open or seal a cave, or dig
	a tunnel). The BURIED bits stay as generated.
]]
function SectionGraph.refresh(graph: buffer, data: buffer, height: number, sections: { number }, yield: (() -> ())?)
	for _, s in sections do
		if s >= 0 and s < SECTIONS then
			local buried = btest(readu32(graph, s * 4), BURIED)
			writeu32(graph, s * 4, SectionGraph.compute(data, height, s, buried))
			if yield then
				yield()
			end
		end
	end
end

--[[
	Sections a chunk's carved cave lattice (Generation/Caves' Carved, nil: no caves; `cellY`: its
	cells' height, Caves.CELL_Y) overlaps, plus `extra` (sections holding edits), in ascending
	order: the only sections that can hold cave cells or dug air. The lattice is world aligned and
	SectionHeight is a multiple of `cellY`, so each cell lies in one section.
]]
function SectionGraph.carvedSections(
	carved: { y: number, nx: number, ny: number, nz: number, flags: buffer }?,
	cellY: number,
	extra: { number }?
): { number }
	assert(SECTION % cellY == 0, "lattice cells must not straddle sections")
	local found: { [number]: boolean } = {}
	if carved then
		local layer = carved.nx * carved.nz
		for ly = 0, carved.ny - 1 do
			local s = (carved.y + ly * cellY) // SECTION
			if not found[s] then
				local base = ly * layer
				for i = 0, layer - 1 do
					if readu8(carved.flags, base + i) ~= 0 then
						found[s] = true
						break
					end
				end
			end
		end
	end
	if extra then
		for _, s in extra do
			found[s] = true
		end
	end
	local list = {}
	for s in found do
		if s >= 0 and s < SECTIONS then
			table.insert(list, s)
		end
	end
	table.sort(list)
	return list
end

--[[ Section keys ]]

-- Coords.chunkKey, inlined in the search.
local OFFSET = 1048576
local SPAN = 2097152

-- A number naming section `s` of chunk (cx, cz): Coords.chunkKey(cx, cz) * SECTIONS + s.
function SectionGraph.key(cx: number, cz: number, s: number): number
	return ((cx + OFFSET) * SPAN + (cz + OFFSET)) * SECTIONS + s
end

function SectionGraph.decode(key: number): (number, number, number)
	local chunk = key // SECTIONS
	local s = key - chunk * SECTIONS
	local cx = chunk // SPAN
	return cx - OFFSET, chunk - cx * SPAN - OFFSET, s
end

--[[ The search ]]

--[[
	The graph of full detail chunk (cx, cz) for the search: its buffer once generated, false for a
	full detail chunk not generated yet, nil for anything else (no caves there).
]]
export type Lookup = (cx: number, cz: number) -> (buffer | false)?

export type Options = {
	-- Blocks from the camera to the centres of the sections entered (default 128).
	reach: number?,
	-- Sections reached at most (default 1500).
	budget: number?,
}

export type Result = {
	-- Section keys reached (revealed), each with the faces it was seen through (bit f; 64 for the
	-- camera's section and its neighbours).
	reached: { [number]: number },
	-- Sections of full detail chunks not generated yet the search would have entered.
	pending: { [number]: boolean },
	-- Sections reached, and whether the budget stopped the search early.
	count: number,
	truncated: boolean,
}

local DX = { -1, 1, 0, 0, 0, 0 }
local DY = { 0, 0, 0, 0, -1, 1 }
local DZ = { 0, 0, -1, 1, 0, 0 }
local START = 64
-- Width of the distance bands the search works through, nearest first (blocks).
local BAND = 8
SectionGraph.BAND = BAND

-- The pair bit of faces a and b at a * 6 + b + 1 (0 when a == b).
local pairBit: { number } = table.create(36, 0)
for a = 0, 5 do
	for b = 0, 5 do
		pairBit[a * 6 + b + 1] = if a == b then 0 else lshift(1, PAIR[a * 6 + b + 1])
	end
end

-- Search queue (reused): chunk x / z, section, directions taken so far, section key.
local qx: { number } = {}
local qz: { number } = {}
local qs: { number } = {}
local qdirs: { number } = {}
local qkey: { number } = {}

--[[
	The sections a camera at block coordinates (x, y, z) sees into (see the header). The camera's
	chunk must be generated, or nothing is reached.

	The search works through distance bands (BAND blocks from the camera to section centres) in
	order. A step never goes back against a direction already taken, so every path moves away
	from the camera's section on each axis and a band only feeds the bands after it. When the
	sections reached pass the budget, the whole band where that happened is dropped (and everything
	beyond it): the cut is a distance from the camera, like a sphere's edge, so it moves little
	when the camera does.
]]
function SectionGraph.search(lookup: Lookup, x: number, y: number, z: number, options: Options?): Result
	local opts: Options = options or {}
	local reach = opts.reach or 128
	local budget = opts.budget or 1500
	local reach2 = reach * reach
	local reached: { [number]: number } = {}
	local pendingBand: { [number]: number } = {}
	local result: Result = { reached = reached, pending = {}, count = 0, truncated = false }

	local bx, by, bz = math.floor(x), math.floor(y), math.floor(z)
	local s0 = by // SECTION
	if s0 < 0 or s0 >= SECTIONS then
		return result
	end
	local cx0, cz0 = bx // SIZE, bz // SIZE

	-- Graphs by chunk key: the buffer, false (pending) or true (not full detail).
	local graphs: { [number]: buffer | boolean } = {}
	local function graphOf(cx: number, cz: number, chunk: number): buffer | boolean
		local g = graphs[chunk]
		if g == nil then
			local found = lookup(cx, cz)
			g = if found == nil then true else found
			graphs[chunk] = g
		end
		return g
	end

	local chunk0 = (cx0 + OFFSET) * SPAN + (cz0 + OFFSET)
	local g0 = graphOf(cx0, cz0, chunk0)
	if type(g0) ~= "buffer" then
		if g0 == false then
			result.pending[chunk0 * SECTIONS + s0] = true
		end
		return result
	end
	reached[chunk0 * SECTIONS + s0] = START

	-- Queue indices per band, and sections per band.
	local bands: { { number } } = {}
	local lastBand = 1
	local tail = 0
	local function push(cx: number, cz: number, s: number, dirs: number, key: number, band: number)
		if band > lastBand then
			lastBand = band
		end
		tail += 1
		qx[tail], qz[tail], qs[tail], qdirs[tail], qkey[tail] = cx, cz, s, dirs, key
		local list = bands[band]
		if list == nil then
			list = {}
			bands[band] = list
		end
		table.insert(list, tail)
	end

	-- The camera's neighbours its air touches (all six when it is in rock or unknown).
	local passable = band(rshift(readu32(g0, s0 * 4), 21), 63)
	if passable == 0 then
		passable = 63
	end
	for d = 0, 5 do
		if btest(passable, lshift(1, d)) then
			local ns = s0 + DY[d + 1]
			if ns < 0 or ns >= SECTIONS then
				continue
			end
			local ncx, ncz = cx0 + DX[d + 1], cz0 + DZ[d + 1]
			local chunk = (ncx + OFFSET) * SPAN + (ncz + OFFSET)
			local g = graphOf(ncx, ncz, chunk)
			local key = chunk * SECTIONS + ns
			if g == false then
				pendingBand[key] = 1
			elseif g ~= true then
				reached[key] = START
				push(ncx, ncz, ns, 0, key, 1)
			end
		end
	end

	local count = 1 -- sections reached in the bands kept so far (the camera's included)
	local b = 1
	while b <= lastBand do
		local list = bands[b]
		if list == nil then
			b += 1
			continue
		end
		local i = 1
		-- (Once this band can't fit the budget any more it is dropped: stop exploring it.)
		while i <= #list and count + #list <= budget do
			local q = list[i]
			i += 1
			local cx, cz, s, dirs, key = qx[q], qz[q], qs[q], qdirs[q], qkey[q]
			local chunk = (cx + OFFSET) * SPAN + (cz + OFFSET)
			local graph = graphs[chunk] :: buffer
			local mask = band(readu32(graph, s * 4), MASK)
			if mask == 0 then
				continue
			end
			-- Faces we may leave through: connected to a face we were seen through (any touched
			-- face for the camera's neighbours).
			local entries = reached[key]
			local exits = 0
			if btest(entries, START) or mask == FULL then
				exits = band(rshift(mask, 15), 63)
			else
				for e = 0, 5 do
					if btest(entries, lshift(1, e)) then
						local row = e * 6 + 1
						for d = 0, 5 do
							if btest(mask, pairBit[row + d]) then
								exits = bor(exits, lshift(1, d))
							end
						end
					end
				end
			end
			-- Never back against a direction already taken.
			exits = band(exits, bnot(bor(rshift(band(dirs, 0x2A), 1), lshift(band(dirs, 0x15), 1))))
			if exits == 0 then
				continue
			end
			for d = 0, 5 do
				local bit = lshift(1, d)
				if not btest(exits, bit) then
					continue
				end
				local ns = s + DY[d + 1]
				if ns < 0 or ns >= SECTIONS then
					continue
				end
				local ncx, ncz = cx + DX[d + 1], cz + DZ[d + 1]
				local ddx = ncx * SIZE + 8 - x
				local ddy = ns * SECTION + 8 - y
				local ddz = ncz * SIZE + 8 - z
				local d2 = ddx * ddx + ddy * ddy + ddz * ddz
				if d2 >= reach2 then
					continue
				end
				local nchunk = if d < 4 then (ncx + OFFSET) * SPAN + (ncz + OFFSET) else chunk
				local nkey = nchunk * SECTIONS + ns
				local opposite = lshift(1, bxor(d, 1))
				local was = reached[nkey]
				if was then
					reached[nkey] = bor(was, opposite)
					continue
				end
				local nb = math.max(b, (math.sqrt(d2) // BAND) + 1)
				local g = if d < 4 then graphOf(ncx, ncz, nchunk) else graph
				if g == false then
					local pb = pendingBand[nkey]
					if pb == nil or nb < pb then
						pendingBand[nkey] = nb
					end
					continue
				elseif g == true then
					continue
				end
				reached[nkey] = opposite
				-- (push, inlined: this is the hot path)
				if nb > lastBand then
					lastBand = nb
				end
				tail += 1
				qx[tail], qz[tail], qs[tail], qdirs[tail], qkey[tail] = ncx, ncz, ns, bor(dirs, bit), nkey
				local into = bands[nb]
				if into == nil then
					into = {}
					bands[nb] = into
				end
				into[#into + 1] = tail
			end
		end
		-- The budget: keep this band only if it fits.
		if count + #list > budget then
			result.truncated = true
			for drop = b, lastBand do
				local dropped = bands[drop]
				if dropped then
					for _, q in dropped do
						reached[qkey[q]] = nil
					end
				end
			end
			for key, pb in pendingBand do
				if pb >= b then
					pendingBand[key] = nil
				end
			end
			break
		end
		count += #list
		b += 1
	end
	for key in pendingBand do
		result.pending[key] = true
	end
	result.count = count
	return result
end

--[[ Revealed sections ]]

--[[
	The GreedyMesher.Border hidden mask of revealed section `s` of chunk (cx, cz): the faces whose
	neighbour is not revealed (`revealed` holds section keys), or not in a full detail chunk
	(`fullDetail`; coarser nodes have no caves).
]]
function SectionGraph.capMask(
	revealed: { [number]: any },
	cx: number,
	cz: number,
	s: number,
	fullDetail: (cx: number, cz: number) -> boolean
): number
	local mask = 0
	for d = 0, 3 do
		local nx, nz = cx + DX[d + 1], cz + DZ[d + 1]
		if not fullDetail(nx, nz) or revealed[SectionGraph.key(nx, nz, s)] == nil then
			mask += lshift(1, d)
		end
	end
	local key = SectionGraph.key(cx, cz, s)
	if s > 0 and revealed[key - 1] == nil then
		mask += 16
	end
	if s < SECTIONS - 1 and revealed[key + 1] == nil then
		mask += 32
	end
	return mask
end

-- The revealed sections of chunk (cx, cz), ascending.
function SectionGraph.sectionsOf(revealed: { [number]: any }, cx: number, cz: number): { number }
	local list = {}
	local base = SectionGraph.key(cx, cz, 0)
	for s = 0, SECTIONS - 1 do
		if revealed[base + s] ~= nil then
			table.insert(list, s)
		end
	end
	return list
end

--[[
	The sections whose cap mask may differ after the sections in `changed` were revealed or hidden:
	those sections and their six neighbours (keys; neighbours past the world's top or bottom are
	left out).
]]
function SectionGraph.neighbourhood(changed: { number }): { [number]: boolean }
	local out: { [number]: boolean } = {}
	for _, key in changed do
		out[key] = true
		local cx, cz, s = SectionGraph.decode(key)
		for d = 0, 5 do
			local ns = s + DY[d + 1]
			if ns >= 0 and ns < SECTIONS then
				out[SectionGraph.key(cx + DX[d + 1], cz + DZ[d + 1], ns)] = true
			end
		end
	end
	return out
end

export type Tracker = {
	-- Revealed section keys.
	revealed: { [number]: boolean },
	--[[
		Feed the latest search (at time `now`, seconds): sections reached (and pending ones, when
		the tracker includes them) are revealed at once; a revealed section is hidden once it was
		not reached for `hold` seconds. Returns the keys revealed and hidden by this update.
	]]
	update: (self: Tracker, result: Result, now: number) -> ({ number }, { number }),
	-- Hides everything at once (the camera came above ground); returns the keys hidden.
	reset: (self: Tracker) -> { number },
}

--[[
	Hysteresis for the revealed set: `hold` seconds before an unreachable section is hidden again.
	`includePending`: pending sections count as revealed (so a chunk generated next to a revealed
	cave is generated revealed there, and its neighbours need no cap meanwhile).
]]
function SectionGraph.tracker(hold: number, includePending: boolean?): Tracker
	local revealed: { [number]: boolean } = {}
	local lastSeen: { [number]: number } = {}
	local tracker = { revealed = revealed }

	function tracker.update(_: Tracker, result: Result, now: number): ({ number }, { number })
		local added, removed = {}, {}
		local function see(key: number)
			lastSeen[key] = now
			if not revealed[key] then
				revealed[key] = true
				table.insert(added, key)
			end
		end
		for key in result.reached do
			see(key)
		end
		if includePending then
			for key in result.pending do
				see(key)
			end
		end
		for key in revealed do
			if now - lastSeen[key] >= hold then
				table.insert(removed, key)
			end
		end
		for _, key in removed do
			revealed[key] = nil
			lastSeen[key] = nil
		end
		return added, removed
	end

	function tracker.reset(_: Tracker): { number }
		local removed = {}
		for key in revealed do
			table.insert(removed, key)
		end
		table.clear(revealed)
		table.clear(lastSeen)
		return removed
	end

	return (tracker :: any) :: Tracker
end

return SectionGraph

--!strict
--[[
	Seasons (Shared/Seasons/Foliage): the seasonal boxes (GreedyMesher) and quads (QuadMesher) of a
	far node cut at chunk column borders where the biome classes on the two sides differ, so every
	cell of a piece stands in chunk columns of one class. A part (client Rendering/ChunkRenderer) or
	a far-mesh quad (Rendering/MeshOverlay) then takes the class of its centre cell, which is every
	cell's own: each seasonal cell shows its own chunk column's class, in parts and in meshes alike,
	however differently the two meshers merged the cells.

	A cell's chunk column is the one its centre stands in (`column`; a cell of level 5 and up is
	wider than a chunk). A footprint (the cells a box or a quad covers, seen from above) within one
	chunk column, or over columns of one class, stays whole; one over several classes is cut into
	rectangles of one class each, greedily: row by row of its columns, each piece as wide as its
	class runs and then as deep as whole rows of it allow. Nothing but seasonal boxes and quads is
	looked at and nothing else changes, so the geometry differs only where classes meet; a buffer
	with nothing to cut is handed back itself.

	`classAt(cx, cz)` gives a chunk column's class (Foliage.classIndex, 1..255), or -1 to stop (a
	build out of time: that box is cut afresh when it goes on). The scratch space is shared:
	nothing here yields, and `quads` calls `pause` (which may yield) only between quads.
]]

local Config = require(script.Parent.Parent.Config)
local Foliage = require(script.Parent.Parent.Seasons.Foliage)

local SIZE = Config.ChunkSize
-- GreedyMesher.BOX_BYTES, QuadMesher.QUAD_BYTES, the appearance's share of a key (both meshers').
local BOX = 14
local QUAD = 16
local KEY_STRIDE = 1024
local SEASONAL = Foliage.kindLut

local readu8 = buffer.readu8
local readu16 = buffer.readu16
local writeu8 = buffer.writeu8
local writeu16 = buffer.writeu16

-- The axis (1 X, 2 Y, 3 Z) of a quad's du and dv by its direction + 1 (QuadMesher.corners).
local U_AXIS = { 2, 3, 3, 1, 1, 2 }
local V_AXIS = { 3, 2, 1, 3, 2, 1 }

-- Scratch: the class of each chunk column of a footprint (at most SIZE x SIZE: a cell each), which
-- of them a piece took, and the pieces (x0, x1, z0, z1 each).
local classes = buffer.create(SIZE * SIZE)
local taken = buffer.create(SIZE * SIZE)
local rects: { number } = table.create(SIZE * SIZE * 4, 0)

local ClassCuts = {}

ClassCuts.rects = rects

export type ClassAt = (cx: number, cz: number) -> number

--[[
	What `boxes` works on (resumable): the mesher's boxes, the next box, the cut boxes so far (nil
	while none was cut: the boxes are the source's own) and how many, and whether a seasonal box
	stands in several chunk columns (a change of classes may cut it).
]]
export type Job = {
	source: buffer,
	at: number,
	out: buffer?,
	count: number,
	spans: boolean,
}

-- The chunk column cell `x` of a node at `n` (its nx or nz), cells `step` blocks wide, stands in.
function ClassCuts.column(n: number, x: number, step: number): number
	return ((n * SIZE + x) * 2 + 1) * step // (2 * SIZE)
end
local column = ClassCuts.column

-- Does footprint [x0, x1) x [z0, z1) stand in several chunk columns (cells `step` blocks wide)?
local function spans(step: number, x0: number, x1: number, z0: number, z1: number): boolean
	local unit = math.max(1, SIZE // step)
	return x0 // unit ~= (x1 - 1) // unit or z0 // unit ~= (z1 - 1) // unit
end
ClassCuts.spans = spans

--[[
	Partitions the w x h chunk columns in `classes` (row by row: v, then u) into rectangles of one
	class, greedily: each as long as its class runs along the row, then over as many whole rows as
	it can. Returns how many, each one's first and last u and first and last v in `rects`.
]]
local function partition(w: number, h: number): number
	buffer.fill(taken, 0, 0, w * h)
	local n = 0
	for v = 0, h - 1 do
		for u = 0, w - 1 do
			local i = v * w + u
			if readu8(taken, i) ~= 0 then
				continue
			end
			local class = readu8(classes, i)
			local u1 = u
			while u1 + 1 < w and readu8(taken, i + u1 + 1 - u) == 0 and readu8(classes, i + u1 + 1 - u) == class do
				u1 += 1
			end
			local v1 = v
			while v1 + 1 < h do
				local row = (v1 + 1) * w
				local whole = true
				for uu = u, u1 do
					if readu8(taken, row + uu) ~= 0 or readu8(classes, row + uu) ~= class then
						whole = false
						break
					end
				end
				if not whole then
					break
				end
				v1 += 1
			end
			for vv = v, v1 do
				buffer.fill(taken, vv * w + u, 1, u1 - u + 1)
			end
			local r = n * 4
			rects[r + 1], rects[r + 2], rects[r + 3], rects[r + 4] = u, u1, v, v1
			n += 1
		end
	end
	return n
end

--[[
	Cuts footprint [x0, x1) x [z0, z1) (cells of node (nx, nz), `step` blocks wide) where the classes
	of its chunk columns differ (see the header). Returns the number of pieces, in `ClassCuts.rects`
	(x0, x1, z0, z1 each; 0: of one class, it stays whole), or -1 when `classAt` said to stop.
]]
function ClassCuts.cut(
	nx: number,
	nz: number,
	step: number,
	x0: number,
	x1: number,
	z0: number,
	z1: number,
	classAt: ClassAt
): number
	local unit = math.max(1, SIZE // step)
	local ua, ub = x0 // unit, (x1 - 1) // unit
	local va, vb = z0 // unit, (z1 - 1) // unit
	if ua == ub and va == vb then
		return 0
	end
	local w, h = ub - ua + 1, vb - va + 1
	local first, mixed = -1, false
	for v = 0, h - 1 do
		local cz = column(nz, (va + v) * unit, step)
		for u = 0, w - 1 do
			local class = classAt(column(nx, (ua + u) * unit, step), cz)
			if class < 0 then
				return -1
			end
			writeu8(classes, v * w + u, class)
			if first < 0 then
				first = class
			elseif class ~= first then
				mixed = true
			end
		end
	end
	if not mixed then
		return 0
	end
	-- (In cells, within the footprint.)
	local n = partition(w, h)
	for r = 0, n * 4 - 1, 4 do
		rects[r + 1] = math.max(x0, (ua + rects[r + 1]) * unit)
		rects[r + 2] = math.min(x1, (ua + rects[r + 2] + 1) * unit)
		rects[r + 3] = math.max(z0, (va + rects[r + 3]) * unit)
		rects[r + 4] = math.min(z1, (va + rects[r + 4] + 1) * unit)
	end
	return n
end
local cut = ClassCuts.cut

-- `out` with room for `need` bytes (grown, its first `used` bytes kept).
local function room(out: buffer, used: number, need: number): buffer
	if need <= buffer.len(out) then
		return out
	end
	local grown = buffer.create(math.max(need, buffer.len(out) * 2))
	buffer.copy(grown, 0, out, 0, used)
	return grown
end

-- `out`'s first `count` items of `bytes` each, as a buffer of its own.
local function trimmed(out: buffer, count: number, bytes: number): buffer
	if buffer.len(out) == count * bytes then
		return out
	end
	local exact = buffer.create(count * bytes)
	buffer.copy(exact, 0, out, 0, count * bytes)
	return exact
end

-- A job for `boxes`: the mesher's boxes `source`.
function ClassCuts.job(source: buffer): Job
	return { source = source, at = 0, out = nil, count = 0, spans = false }
end

--[[
	Cuts the seasonal boxes (GreedyMesher layout) of node (nx, nz), cells `step` blocks wide, where
	classes meet (see the header), from box `job.at` on. Returns false when `classAt` said to stop
	(`job.at` is that box), true when done: then `job.out` holds the boxes (the source itself when
	none was cut) and `job.count` how many. With `cutting` false nothing is cut and no class asked:
	only `job.spans` is found.
]]
function ClassCuts.boxes(job: Job, nx: number, nz: number, step: number, classAt: ClassAt, cutting: boolean): boolean
	local source = job.source
	local total = buffer.len(source) // BOX
	for i = job.at, total - 1 do
		local o = i * BOX
		local pieces = 0
		if readu8(SEASONAL, readu16(source, o + 12) % KEY_STRIDE) ~= 0 then
			local x, z = readu16(source, o), readu16(source, o + 4)
			local x1, z1 = x + readu16(source, o + 6), z + readu16(source, o + 10)
			if spans(step, x, x1, z, z1) then
				job.spans = true
				if cutting then
					pieces = cut(nx, nz, step, x, x1, z, z1, classAt)
					if pieces < 0 then
						job.at = i
						return false
					end
				end
			end
		end
		local out = job.out
		if pieces > 0 and out == nil then
			-- (The first box cut: the ones before it as they are.)
			local first = buffer.create((total + pieces) * BOX)
			buffer.copy(first, 0, source, 0, o)
			out = first
			job.count = i
		end
		if out then
			local n = job.count
			out = room(out, n * BOX, (n + math.max(1, pieces)) * BOX)
			if pieces == 0 then
				buffer.copy(out, n * BOX, source, o, BOX)
				n += 1
			else
				for p = 0, pieces - 1 do
					local q, r = n * BOX, p * 4
					buffer.copy(out, q, source, o, BOX)
					writeu16(out, q, rects[r + 1])
					writeu16(out, q + 6, rects[r + 2] - rects[r + 1])
					writeu16(out, q + 4, rects[r + 3])
					writeu16(out, q + 10, rects[r + 4] - rects[r + 3])
					n += 1
				end
			end
			job.out = out
			job.count = n
		end
	end
	job.at = total
	local out = job.out
	if out then
		job.out = trimmed(out, job.count, BOX)
	else
		job.out = source
		job.count = total
	end
	return true
end

--[[
	The quads (QuadMesher layout) of node (nx, nz), cells `step` blocks wide, with the seasonal ones
	cut where classes meet (see the header; `classAt` never stops here), and how many: `quads`
	itself when none was cut. `pause` is called after each quad whose classes were looked at.
]]
function ClassCuts.quads(
	quads: buffer,
	count: number,
	nx: number,
	nz: number,
	step: number,
	classAt: ClassAt,
	pause: (() -> ())?
): (buffer, number)
	local out: buffer? = nil
	local n = 0
	for i = 0, count - 1 do
		local o = i * QUAD
		local pieces = 0
		local looked = false
		local dir = readu16(quads, o)
		if readu8(SEASONAL, readu16(quads, o + 12) % KEY_STRIDE) ~= 0 then
			local x, z = readu16(quads, o + 2), readu16(quads, o + 6)
			local du, dv = readu16(quads, o + 8), readu16(quads, o + 10)
			local ua, va = U_AXIS[dir + 1], V_AXIS[dir + 1]
			-- (Its footprint: one cell thick across a side face.)
			local w = if ua == 1 then du elseif va == 1 then dv else 1
			local d = if ua == 3 then du elseif va == 3 then dv else 1
			if spans(step, x, x + w, z, z + d) then
				looked = true
				pieces = cut(nx, nz, step, x, x + w, z, z + d, classAt)
				assert(pieces >= 0, "ClassCuts.quads: classAt stopped")
			end
		end
		local into = out
		if pieces > 0 and into == nil then
			-- (The first quad cut: the ones before it as they are.)
			local first = buffer.create((count + pieces) * QUAD)
			buffer.copy(first, 0, quads, 0, o)
			into = first
			n = i
		end
		if into then
			into = room(into, n * QUAD, (n + math.max(1, pieces)) * QUAD)
			if pieces == 0 then
				buffer.copy(into, n * QUAD, quads, o, QUAD)
				n += 1
			else
				local ua, va = U_AXIS[dir + 1], V_AXIS[dir + 1]
				for p = 0, pieces - 1 do
					local q, r = n * QUAD, p * 4
					local dx, dz = rects[r + 2] - rects[r + 1], rects[r + 4] - rects[r + 3]
					buffer.copy(into, q, quads, o, QUAD)
					writeu16(into, q + 2, rects[r + 1])
					writeu16(into, q + 6, rects[r + 3])
					writeu16(into, q + 8, if ua == 1 then dx elseif ua == 3 then dz else readu16(quads, o + 8))
					writeu16(into, q + 10, if va == 1 then dx elseif va == 3 then dz else readu16(quads, o + 10))
					n += 1
				end
			end
			out = into
		end
		if looked and pause then
			pause()
		end
	end
	if out then
		return trimmed(out, n, QUAD), n
	end
	return quads, count
end

return ClassCuts

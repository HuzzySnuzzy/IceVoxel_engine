--!strict
--!native
--[[
	Far terrain hidden behind nearer terrain (horizon occlusion), so the client can build what is
	visible first and, optionally, not build parts for what nobody can see. Roblox already culls
	draw calls; this saves our own worker time, part building and part counts.

	Summary (`summarise`, SUMMARY_BYTES per node, made by the generator for every node): the node's
	16 x 16 cells in 4 x 4 tiles of 4 x 4 cells, per tile
	  ground  the lowest drawn terrain top (blocks): the tile is solid from 0 up to there, an
	          occluder (terrain only: no trees, water or structures). These are the heights
	          before surface caves (Generation/SurfaceCaves): a pit or a ravine does not lower
	          its tile, an overstatement judged negligible (sight lines along a cut's floor);
	  top     the highest drawn cell top (blocks), trees, water and structures included: the tile
	          lies below it, an occludee.
	Layout: u16 ground of tile tz * 4 + tx at byte 2 * t, u16 top at 32 + 2 * t. A top of UNKNOWN
	means never hidden (`estimate` for nodes not generated yet). Players' edits of full detail
	chunks update it (`applyEdits`): dug ground lowers a tile's ground, built blocks raise its top.

	Evaluation (`evaluate`, in a worker): a front-to-back sweep from the eye over a horizon of
	`bins` compass directions, each holding the steepest slope (rise over horizontal distance)
	known to be blocked in every direction of the bin. Tiles are taken in rings of BUCKET blocks:
	the tiles whose nearest point lies in a ring are tested first, then those whose farthest point
	lies in it raise the horizon, so an occluder always lies entirely in front of whatever it hides.
	An occluder raises the bins its footprint covers completely to rise / farthest distance (it is
	above the eye) or rise / nearest distance (below it): both are slopes it blocks along every ray
	of the bin. A tile is hidden when every bin it touches is steeper than its own steepest point;
	a node when all its tiles are.

	Safety margin: the camera moves between evaluations, so a node only counts as hidden when it is
	hidden from every eye: the eye raised `raise` blocks, and four more `spread` blocks to its
	sides (also raised). Nodes within `keep` blocks are never hidden.

	Records (`pack`): RECORD_BYTES per node, f64 node key (Coords.nodeKey) then its summary.
]]

local ChunkLayout = require(script.Parent.ChunkLayout)
local Coords = require(script.Parent.Coords)

local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED
local LAYER = ChunkLayout.LAYER

local floor, ceil, sqrt, atan2, max, min = math.floor, math.ceil, math.sqrt, math.atan2, math.max, math.min
local readu8, readu16, writeu16 = buffer.readu8, buffer.readu16, buffer.writeu16
local TWO_PI = 2 * math.pi

local Horizon = {}

Horizon.TILES = 4 -- tiles per node side
Horizon.TILE_CELLS = SIZE // 4 -- cells per tile side
Horizon.SUMMARY_BYTES = 64
Horizon.RECORD_BYTES = 72
Horizon.UNKNOWN = 0xFFFF
-- Width of the distance rings of the sweep (blocks).
Horizon.BUCKET = 8

local TILE_CELLS = Horizon.TILE_CELLS
local UNKNOWN = Horizon.UNKNOWN
local BUCKET = Horizon.BUCKET

--[[ Summaries ]]

--[[
	The summary of a generated node: `data` its padded column (`cells` per column, every cell at or
	above `emptyAbove` air), `topCells` the highest terrain cell of each padded column (index
	pz * PADDED + px + 1; trees, water and structures not included), `stepY` its cell height.
]]
function Horizon.summarise(data: buffer, cells: number, emptyAbove: number, topCells: { number }, stepY: number): buffer
	local summary = buffer.create(Horizon.SUMMARY_BYTES)
	local scanTop = min(emptyAbove, cells) - 1
	for tz = 0, 3 do
		for tx = 0, 3 do
			local t = tz * 4 + tx
			local lowest, highest = math.huge, -1
			for z = 0, TILE_CELLS - 1 do
				local row = (tz * TILE_CELLS + z + 1) * P + tx * TILE_CELLS + 1
				for x = 0, TILE_CELLS - 1 do
					local cell = topCells[row + x + 1]
					if cell < lowest then
						lowest = cell
					end
					if cell > highest then
						highest = cell
					end
				end
			end
			-- Highest cell that is not air: scan down from the top of the chunk to the tile's
			-- highest terrain cell (its trees, water or structures, if any, are above that).
			local top = max(highest, 0)
			for y = scanTop, top + 1, -1 do
				local found = false
				local layer = y * LAYER
				for z = 0, TILE_CELLS - 1 do
					local base = (layer + (tz * TILE_CELLS + z + 1) * P + tx * TILE_CELLS + 1) * 2
					for x = 0, TILE_CELLS - 1 do
						-- (Air and cave air are blocks 0 and 1.)
						if readu16(data, base + x * 2) > 1 then
							found = true
							break
						end
					end
					if found then
						break
					end
				end
				if found then
					top = y
					break
				end
			end
			writeu16(summary, t * 2, max(lowest + 1, 1) * stepY)
			writeu16(summary, 32 + t * 2, min((top + 1) * stepY, UNKNOWN - 1))
		end
	end
	return summary
end

--[[
	Edits written into a full detail node's `data` (`height` cells per column) after its summary
	was made: `edits` holds padded cell index, block pairs (ClientWorld.collectJobEdits; padding
	cells belong to the neighbours). A tile's ground drops to an edited cell that is not solid
	(`solid`: u8 per block id, 1 for blocks that hide what is behind them) when nothing solid lies
	above it below the ground: dug from above, a quarry or a levelled hill (a tunnel under the
	ground leaves it, like the caves the generated summary ignores). Its top rises to a placed
	block. Ground never rises again: an occluder is never overstated. Returns whether the summary
	changed.
]]
function Horizon.applyEdits(summary: buffer, data: buffer, height: number, edits: { number }, solid: buffer): boolean
	local changed = false
	for i = 1, #edits, 2 do
		local index = edits[i]
		local y = index // LAYER
		local rest = index - y * LAYER
		local pz, px = rest // P, rest % P
		if px < 1 or px > SIZE or pz < 1 or pz > SIZE or y >= height then
			continue
		end
		local t = ((pz - 1) // TILE_CELLS) * 4 + (px - 1) // TILE_CELLS
		-- (The cell as it is now: a later edit of the same cell wins.)
		local block = readu16(data, index * 2)
		local ground = readu16(summary, t * 2)
		if readu8(solid, block) == 0 and y < ground then
			local open = true
			for above = y + 1, min(ground, height) - 1 do
				if readu8(solid, readu16(data, (index + (above - y) * LAYER) * 2)) == 1 then
					open = false
					break
				end
			end
			if open then
				writeu16(summary, t * 2, y)
				changed = true
			end
		end
		local top = readu16(summary, 32 + t * 2)
		-- (Air and cave air are blocks 0 and 1.)
		if block > 1 and top ~= UNKNOWN and y + 1 > top then
			writeu16(summary, 32 + t * 2, min(y + 1, UNKNOWN - 1))
			changed = true
		end
	end
	return changed
end

function Horizon.ground(summary: buffer, tile: number): number
	return readu16(summary, tile * 2)
end

function Horizon.top(summary: buffer, tile: number): number
	return readu16(summary, 32 + tile * 2)
end

export type Source = { level: number, nx: number, nz: number, summary: buffer }

--[[
	An occludee-only summary for node (level, nx, nz) not generated yet, from generated nodes
	covering its area (`sources`, not overlapping each other: an ancestor, or some of its
	descendants). A tile's top is the highest top of the source tiles over it, raised by a coarser
	source's cell size (coarse cells average the terrain out); tiles not fully covered are UNKNOWN.
	Ground is 0: estimates never hide anything.
]]
function Horizon.estimate(level: number, nx: number, nz: number, sources: { Source }): buffer
	local out = buffer.create(Horizon.SUMMARY_BYTES)
	local w = TILE_CELLS * bit32.lshift(1, level)
	local ox, oz = nx * SIZE * bit32.lshift(1, level), nz * SIZE * bit32.lshift(1, level)
	for t = 0, 15 do
		local x0, z0 = ox + (t % 4) * w, oz + (t // 4) * w
		local x1, z1 = x0 + w, z0 + w
		local area, top = 0, 0
		for _, source in sources do
			local cell = bit32.lshift(1, source.level)
			local sw = TILE_CELLS * cell
			local sx, sz = source.nx * SIZE * cell, source.nz * SIZE * cell
			local slack = if source.level > level then cell else 0
			for st = 0, 15 do
				local a0, c0 = sx + (st % 4) * sw, sz + (st // 4) * sw
				local ix = min(x1, a0 + sw) - max(x0, a0)
				local iz = min(z1, c0 + sw) - max(z0, c0)
				if ix > 0 and iz > 0 then
					area += ix * iz
					top = max(top, readu16(source.summary, 32 + st * 2) + slack)
				end
			end
		end
		writeu16(out, 32 + t * 2, if area >= w * w then min(top, UNKNOWN - 1) else UNKNOWN)
	end
	return out
end

-- Records for `evaluate`: node keys and their summaries.
function Horizon.pack(keys: { number }, summaries: { buffer }): buffer
	local records = buffer.create(#keys * Horizon.RECORD_BYTES)
	for i, key in keys do
		local offset = (i - 1) * Horizon.RECORD_BYTES
		buffer.writef64(records, offset, key)
		buffer.copy(records, offset + 8, summaries[i], 0, Horizon.SUMMARY_BYTES)
	end
	return records
end

--[[ The sweep ]]

export type Options = {
	-- Blocks every eye is raised above the camera (default 16).
	raise: number?,
	-- Blocks the four side eyes are moved along X and Z (default 16; 0: the raised eye only).
	spread: number?,
	-- Nodes closer than this to the camera (blocks, horizontally) are never hidden (default 64).
	keep: number?,
	-- Compass directions of the horizon (default 512).
	bins: number?,
}

-- Per evaluation scratch, reused: occludee tiles (square) and occluder boxes.
local tileX0: { number } = {}
local tileZ0: { number } = {}
local tileW: { number } = {}
local tileTop: { number } = {}
local tileNode: { number } = {}
local occX0: { number } = {}
local occZ0: { number } = {}
local occX1: { number } = {}
local occZ1: { number } = {}
local occGround: { number } = {}
local horizon: { number } = {}

-- Angular span [lo, hi] (radians, lo in [0, 2 pi), hi >= lo) of a box seen from outside it.
local function span(ex: number, ez: number, x0: number, z0: number, x1: number, z1: number): (number, number)
	-- The two corners on the silhouette, by where the eye is.
	local ax, az, bx, bz
	if ex < x0 then
		if ez < z0 then
			ax, az, bx, bz = x1, z0, x0, z1
		elseif ez > z1 then
			ax, az, bx, bz = x0, z0, x1, z1
		else
			ax, az, bx, bz = x0, z0, x0, z1
		end
	elseif ex > x1 then
		if ez < z0 then
			ax, az, bx, bz = x1, z1, x0, z0
		elseif ez > z1 then
			ax, az, bx, bz = x0, z1, x1, z0
		else
			ax, az, bx, bz = x1, z1, x1, z0
		end
	elseif ez < z0 then
		ax, az, bx, bz = x1, z0, x0, z0
	else
		ax, az, bx, bz = x0, z1, x1, z1
	end
	local a = atan2(az - ez, ax - ex)
	local b = atan2(bz - ez, bx - ex)
	-- Counter-clockwise from a to b, by less than pi.
	if b < a then
		b += TWO_PI
	end
	if a < 0 then
		a += TWO_PI
		b += TWO_PI
	end
	return a, b
end
Horizon.span = span

-- Nearest and farthest horizontal distance from the eye to a box.
local function nearFar(ex: number, ez: number, x0: number, z0: number, x1: number, z1: number): (number, number)
	local dx = max(x0 - ex, 0, ex - x1)
	local dz = max(z0 - ez, 0, ez - z1)
	local fx = max(ex - x0, x1 - ex)
	local fz = max(ez - z0, z1 - ez)
	return sqrt(dx * dx + dz * dz), sqrt(fx * fx + fz * fz)
end
Horizon.nearFar = nearFar

-- Per sweep scratch: spans and distances of the tiles tested and of the occluders used.
local testLo: { number } = {}
local testHi: { number } = {}
local testSteep: { number } = {}
local occLo: { number } = {}
local occHi: { number } = {}
local occSlope: { number } = {}
-- Bins some tested tile touches, as running counts (index b + 1 counts bins below b; doubled for
-- spans that wrap past 2 pi).
local interest: { number } = {}

--[[
	One sweep from eye (ex, ey, ez) over tiles 1..nTiles and occluders 1..nOcc, testing only the
	tiles of nodes still marked hidden in `hidden` (node index -> true); nodes found visible are
	removed from it. Occluders over no bin a tested tile touches are skipped.
]]
local function sweep(
	nTiles: number,
	nOcc: number,
	ex: number,
	ey: number,
	ez: number,
	bins: number,
	hidden: { [number]: boolean },
	yield: (() -> ())?
)
	local w = TWO_PI / bins
	for b = 1, bins do
		horizon[b] = -math.huge
	end
	-- Rings: tiles to test (by nearest point) and occluders (by farthest point).
	local tests: { { number } } = {}
	local occluders: { { number } } = {}
	local rings = 0
	local marks: { number } = table.create(2 * bins + 1, 0)
	for i = 1, nTiles do
		if yield and i % 512 == 0 then
			yield()
		end
		local node = tileNode[i]
		if not hidden[node] then
			continue
		end
		local x0, z0, size = tileX0[i], tileZ0[i], tileW[i]
		local x1, z1 = x0 + size, z0 + size
		if ex >= x0 and ex <= x1 and ez >= z0 and ez <= z1 then
			hidden[node] = nil
			continue
		end
		local near, far = nearFar(ex, ez, x0, z0, x1, z1)
		local rise = tileTop[i] - ey
		testSteep[i] = if rise > 0 then rise / max(near, 1e-6) else rise / far
		local lo, hi = span(ex, ez, x0, z0, x1, z1)
		local b0, b1 = floor(lo / w), floor(hi / w)
		testLo[i], testHi[i] = b0, b1
		for b = b0, b1 do
			marks[b + 1] = 1
		end
		local ring = floor(near / BUCKET) + 1
		local list = tests[ring]
		if list == nil then
			list = {}
			tests[ring] = list
		end
		table.insert(list, i)
		if ring > rings then
			rings = ring
		end
	end
	-- Running counts of the marked bins (a span may run past 2 pi: bins b and b + bins alike).
	local total = 0
	interest[1] = 0
	for k = 1, 2 * bins do
		local m = marks[k] or 0
		if k > bins then
			m = max(m, marks[k - bins] or 0)
		elseif marks[k + bins] == 1 then
			m = 1
		end
		total += m
		interest[k + 1] = total
	end
	for i = 1, nOcc do
		if yield and i % 512 == 0 then
			yield()
		end
		local x0, z0, x1, z1 = occX0[i], occZ0[i], occX1[i], occZ1[i]
		if ex >= x0 and ex <= x1 and ez >= z0 and ez <= z1 then
			continue
		end
		local near, far = nearFar(ex, ez, x0, z0, x1, z1)
		local ring = floor(far / BUCKET) + 1
		if ring >= rings then
			continue
		end
		local lo, hi = span(ex, ez, x0, z0, x1, z1)
		local b0, b1 = ceil(lo / w), floor(hi / w) - 1
		if b1 < b0 or interest[b1 + 2] - interest[b0 + 1] == 0 then
			continue
		end
		local rise = occGround[i] - ey
		occSlope[i] = if rise > 0 then rise / far else rise / max(near, 1e-6)
		occLo[i], occHi[i] = b0, b1
		local list = occluders[ring]
		if list == nil then
			list = {}
			occluders[ring] = list
		end
		table.insert(list, i)
	end
	for ring = 1, rings do
		-- Test first: the occluders of this ring may lie behind these tiles.
		local list = tests[ring]
		if list then
			for _, i in list do
				local node = tileNode[i]
				if not hidden[node] then
					continue
				end
				local steepest = testSteep[i]
				for b = testLo[i], testHi[i] do
					if horizon[b % bins + 1] <= steepest then
						hidden[node] = nil
						break
					end
				end
			end
		end
		list = occluders[ring]
		if list then
			for _, i in list do
				local slope = occSlope[i]
				for b = occLo[i], occHi[i] do
					local k = b % bins + 1
					if slope > horizon[k] then
						horizon[k] = slope
					end
				end
			end
		end
		if yield and ring % 4 == 0 then
			yield()
		end
	end
end

--[[
	The nodes of `records` (`count` of them, see `pack`) hidden behind terrain from a camera at
	block coordinates (x, y, z), as a list of node keys. `yield` is called regularly.

	Occluders are each node's tiles, plus its rows and columns of four tiles at their lowest
	ground, and the same rows and columns continued into the next node of the same level: a bin
	is only raised by a box covering all of it, and without them the bins straddling the edges
	between tiles and nodes would stay open (worst along the axes through the eye, where the edges
	of every row line up).
]]
function Horizon.evaluate(
	records: buffer,
	count: number,
	x: number,
	y: number,
	z: number,
	options: Options?,
	yield: (() -> ())?
): { number }
	local opts: Options = options or {}
	local raise = opts.raise or 16
	local spread = opts.spread or 16
	local keep = opts.keep or 64
	local bins = opts.bins or 512

	-- Tiles of every node, and the nodes that may be hidden (not too close).
	local hidden: { [number]: boolean } = {}
	local keys: { number } = table.create(count)
	local indexOf: { [number]: number } = {}
	local rowGround: { number } = table.create(count * 4, 0)
	local columnGround: { number } = table.create(count * 4, 0)
	local nTiles, nOcc = 0, 0
	local function occluder(x0: number, z0: number, x1: number, z1: number, ground: number)
		if ground > 0 then
			nOcc += 1
			occX0[nOcc], occZ0[nOcc], occX1[nOcc], occZ1[nOcc], occGround[nOcc] = x0, z0, x1, z1, ground
		end
	end
	for i = 1, count do
		local offset = (i - 1) * Horizon.RECORD_BYTES
		local key = buffer.readf64(records, offset)
		keys[i] = key
		local level, nx, nz = Coords.decodeNodeKey(key)
		local cell = bit32.lshift(1, level)
		local size = SIZE * cell
		local ox, oz = nx * size, nz * size
		local dx = max(ox - x, 0, x - (ox + size))
		local dz = max(oz - z, 0, z - (oz + size))
		if sqrt(dx * dx + dz * dz) >= keep then
			hidden[i] = true
		end
		local w = TILE_CELLS * cell
		for t = 0, 15 do
			nTiles += 1
			local tx0, tz0 = ox + (t % 4) * w, oz + (t // 4) * w
			tileX0[nTiles] = tx0
			tileZ0[nTiles] = tz0
			tileW[nTiles] = w
			tileTop[nTiles] = readu16(records, offset + 40 + t * 2)
			tileNode[nTiles] = i
			occluder(tx0, tz0, tx0 + w, tz0 + w, readu16(records, offset + 8 + t * 2))
		end
		for k = 0, 3 do
			local row, column = math.huge, math.huge
			for j = 0, 3 do
				row = min(row, readu16(records, offset + 8 + (k * 4 + j) * 2))
				column = min(column, readu16(records, offset + 8 + (j * 4 + k) * 2))
			end
			occluder(ox, oz + k * w, ox + size, oz + (k + 1) * w, row)
			occluder(ox + k * w, oz, ox + (k + 1) * w, oz + size, column)
			rowGround[(i - 1) * 4 + k + 1] = row
			columnGround[(i - 1) * 4 + k + 1] = column
		end
		indexOf[key] = i
		if yield and i % 64 == 0 then
			yield()
		end
	end
	-- Rows and columns continued into the next node of the same level along +X / +Z: the edges
	-- between nodes would leave bins open too.
	for i = 1, count do
		local level, nx, nz = Coords.decodeNodeKey(keys[i])
		local cell = bit32.lshift(1, level)
		local size = SIZE * cell
		local w = TILE_CELLS * cell
		local ox, oz = nx * size, nz * size
		local east = indexOf[Coords.nodeKey(level, nx + 1, nz)]
		local south = indexOf[Coords.nodeKey(level, nx, nz + 1)]
		for k = 0, 3 do
			local at = (i - 1) * 4 + k + 1
			if east then
				local ground = min(rowGround[at], rowGround[(east - 1) * 4 + k + 1])
				occluder(ox, oz + k * w, ox + 2 * size, oz + (k + 1) * w, ground)
			end
			if south then
				local ground = min(columnGround[at], columnGround[(south - 1) * 4 + k + 1])
				occluder(ox + k * w, oz, ox + (k + 1) * w, oz + 2 * size, ground)
			end
		end
	end

	local eyes = { { x, z } }
	if spread > 0 then
		table.insert(eyes, { x + spread, z })
		table.insert(eyes, { x - spread, z })
		table.insert(eyes, { x, z + spread })
		table.insert(eyes, { x, z - spread })
	end
	for _, eye in eyes do
		if next(hidden) == nil then
			break
		end
		sweep(nTiles, nOcc, eye[1], y + raise, eye[2], bins, hidden, yield)
	end

	local out = {}
	for i in hidden do
		table.insert(out, keys[i])
	end
	return out
end

return Horizon

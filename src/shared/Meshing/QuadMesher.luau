--!strict
--!native
--[[
	Face-based greedy mesher, for rendering chunks as triangle meshes (EditableMesh) instead of parts.

	GreedyMesher covers blocks with boxes because a Roblox part is a box. A mesh only needs the faces
	you can see, so this one emits quads: for each of the six directions and each slice, the visible
	faces form a mask that is merged into as few rectangles of the same key as possible.

	Visibility (same rules as GreedyMesher, per face):
	  * opaque blocks: a face is drawn where the neighbour does not hide it (cull LUT; cave air hides
	    when `hideCaves`),
	  * transparent blocks (glass): where the neighbour is see-through and a different block,
	  * fluids: where the neighbour is see-through and not the same fluid. A fluid cell without the same
	    fluid above is lowered to its level's height (Blocks.fluidHeightLut), like GreedyMesher; only
	    faces of the same height merge,
	  * with `hideCaves`, cave cells (cave air, cave twins) are rock that is not drawn, except for
	    their faces towards a cell that is neither opaque nor a cave cell (a surface cave's entrance,
	    a dug shaft): those are stone caps, like GreedyMesher's.
	Below the world counts as solid, above it as air.

	Output: a buffer of quads, QUAD_BYTES each, as u16 values
	  dir          0 +X, 1 -X, 2 +Y, 3 -Y, 4 +Z, 5 -Z (the face's outward normal),
	  x, y, z      cell whose face starts the quad (x / z local to the chunk core, y absolute),
	  du, dv       size in cells along the face's two axes (see `corners`),
	  key          appearance id + surfaceHeight * KEY_STRIDE (as GreedyMesher; 0 = full height).

	`corners` turns a quad into four positions wound counter-clockwise seen from outside, which is
	Roblox's front face.
]]

local Blocks = require(script.Parent.Parent.Blocks)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)

local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED
local LAYER = ChunkLayout.LAYER

local OPAQUE = Blocks.KIND_OPAQUE
local TRANSPARENT = Blocks.KIND_TRANSPARENT
local FLUID = Blocks.KIND_FLUID
local AIR = Blocks.AIR
local FLUID_FULL = Blocks.FLUID_FULL
local KEY_STRIDE = 1024

local appearanceLut = Blocks.appearanceLut
local fluidHeightLut = Blocks.fluidHeightLut
local kindLut = Blocks.kindLut
local cullVisibleCaves = Blocks.cullLut
local cullHiddenCaves = Blocks.cullLutHiddenCaves

local readu8 = buffer.readu8
local readu16 = buffer.readu16
local writeu8 = buffer.writeu8
local writeu16 = buffer.writeu16

-- Hidden caves: the appearance of each block (u16; cave cells: CAVE_CELL), and the stone caps'.
local CAVE_CELL = 0xFFFF
local appearanceHiddenCaves = buffer.create(Blocks.count * 2)
buffer.copy(appearanceHiddenCaves, 0, appearanceLut)
for id = 0, Blocks.count - 1 do
	if id == Blocks.CAVE_AIR or readu8(Blocks.caveTwinLut, id) == 1 then
		writeu16(appearanceHiddenCaves, id * 2, CAVE_CELL)
	end
end
local STONE_APPEARANCE = readu16(appearanceLut, Blocks.id.Stone * 2)

local QuadMesher = {}

QuadMesher.QUAD_BYTES = 16
QuadMesher.KEY_STRIDE = KEY_STRIDE

-- Outward normal of each direction.
QuadMesher.NORMALS = table.freeze({
	{ 1, 0, 0 },
	{ -1, 0, 0 },
	{ 0, 1, 0 },
	{ 0, -1, 0 },
	{ 0, 0, 1 },
	{ 0, 0, -1 },
})

-- Scratch space, reused (every actor has its own copy of this module).
local mask = buffer.create(SIZE * 256 * 2) -- u16 key per face of the slice, 0 = none
local used = buffer.create(SIZE * 256)
local quads = buffer.create(16 * 512)

local function ensureSlice(cells: number)
	if buffer.len(used) < cells then
		mask = buffer.create(cells * 2)
		used = buffer.create(cells)
	end
end

local function pushQuad(
	count: number,
	dir: number,
	x: number,
	y: number,
	z: number,
	du: number,
	dv: number,
	key: number
)
	local offset = count * 16
	if offset + 16 > buffer.len(quads) then
		local grown = buffer.create(buffer.len(quads) * 2)
		buffer.copy(grown, 0, quads, 0, offset)
		quads = grown
	end
	writeu16(quads, offset, dir)
	writeu16(quads, offset + 2, x)
	writeu16(quads, offset + 4, y)
	writeu16(quads, offset + 6, z)
	writeu16(quads, offset + 8, du)
	writeu16(quads, offset + 10, dv)
	writeu16(quads, offset + 12, key)
	writeu16(quads, offset + 14, 0)
end

--[[
	Key of the face of `block` (at byte offset `o`) towards neighbour `n`, or 0 when it is not drawn.
	`drawn` is the appearance lookup (appearanceHiddenCaves while caves are hidden).
]]
local function faceKey(
	data: buffer,
	o: number,
	block: number,
	n: number,
	cull: buffer,
	drawn: buffer,
	hasAbove: boolean
): number
	local app = readu16(drawn, block * 2)
	if app == 0 then
		return 0
	elseif app == CAVE_CELL then
		-- A hidden cave cell: rock, drawn as a stone cap towards open space that is not cave.
		return if readu8(cull, n) == 0 then STONE_APPEARANCE else 0
	end
	local kind = readu8(kindLut, app)
	if kind == OPAQUE then
		return if readu8(cull, n) == 0 then app else 0
	elseif kind == TRANSPARENT then
		return if readu8(cull, n) == 0 and n ~= block then app else 0
	elseif kind == FLUID then
		if readu8(cull, n) ~= 0 or readu16(appearanceLut, n * 2) == app then
			return 0
		end
		local surface = readu8(fluidHeightLut, block)
		if surface < FLUID_FULL then
			local above = if hasAbove then readu16(data, o + LAYER * 2) else AIR
			if readu16(appearanceLut, above * 2) ~= app then
				return app + surface * KEY_STRIDE
			end
		end
		return app
	end
	return 0
end

-- Merges the slice mask (W x H keys) into quads; `emit(u, v, du, dv, key)` positions them.
local function mergeSlice(
	W: number,
	H: number,
	count: number,
	dir: number,
	place: (u: number, v: number) -> (number, number, number),
	swap: boolean
): number
	buffer.fill(used, 0, 0, W * H)
	for v = 0, H - 1 do
		for u = 0, W - 1 do
			local i = v * W + u
			local key = readu16(mask, i * 2)
			if key ~= 0 and readu8(used, i) == 0 then
				local u1 = u
				while u1 + 1 < W do
					local j = i + u1 + 1 - u
					if readu16(mask, j * 2) ~= key or readu8(used, j) ~= 0 then
						break
					end
					u1 += 1
				end
				local v1 = v
				while v1 + 1 < H do
					local row = (v1 + 1) * W
					local ok = true
					for uu = u, u1 do
						local j = row + uu
						if readu16(mask, j * 2) ~= key or readu8(used, j) ~= 0 then
							ok = false
							break
						end
					end
					if not ok then
						break
					end
					v1 += 1
				end
				for vv = v, v1 do
					local row = vv * W
					for uu = u, u1 do
						writeu8(used, row + uu, 1)
					end
				end
				local x, y, z = place(u, v)
				-- Sizes are stored along the face's own axes (see `corners`).
				if swap then
					pushQuad(count, dir, x, y, z, v1 - v + 1, u1 - u + 1, key)
				else
					pushQuad(count, dir, x, y, z, u1 - u + 1, v1 - v + 1, key)
				end
				count += 1
			end
		end
	end
	return count
end

--[[
	Meshes cells y0 .. y1-1 of a padded chunk column `data` with `height` cells per column.
	Returns a new buffer of quads and the quad count.
]]
function QuadMesher.mesh(data: buffer, height: number, y0: number, y1: number, hideCaves: boolean): (buffer, number)
	local cull = if hideCaves then cullHiddenCaves else cullVisibleCaves
	local drawn = if hideCaves then appearanceHiddenCaves else appearanceLut
	local sh = y1 - y0
	if sh <= 0 then
		return buffer.create(0), 0
	end
	ensureSlice(SIZE * math.max(sh, SIZE))
	local count = 0

	-- ±Y: one slice per layer, u = x, v = z. Face axes: +Y (z, x), -Y (x, z).
	for dir = 2, 3 do
		local up = dir == 2
		for y = y0, y1 - 1 do
			local hasAbove = y + 1 < height
			local neighbourExists = if up then hasAbove else y > 0
			local any = false
			for z = 0, SIZE - 1 do
				local o = ((y * P + z + 1) * P + 1) * 2
				for x = 0, SIZE - 1 do
					local block = readu16(data, o)
					local key = 0
					if block ~= AIR then
						if neighbourExists then
							local n = readu16(data, if up then o + LAYER * 2 else o - LAYER * 2)
							key = faceKey(data, o, block, n, cull, drawn, hasAbove)
						elseif up then
							key = faceKey(data, o, block, AIR, cull, drawn, false)
						end
					end
					writeu16(mask, (z * SIZE + x) * 2, key)
					any = any or key ~= 0
					o += 2
				end
			end
			if any then
				local yy = y
				count = mergeSlice(SIZE, SIZE, count, dir, function(u, v)
					return u, yy, v
				end, up)
			end
		end
	end

	-- ±X: one slice per x, u = z, v = y. Face axes: +X (y, z), -X (z, y).
	for dir = 0, 1 do
		local step = if dir == 0 then 2 else -2
		for x = 0, SIZE - 1 do
			local any = false
			for y = y0, y1 - 1 do
				local hasAbove = y + 1 < height
				for z = 0, SIZE - 1 do
					local o = ((y * P + z + 1) * P + x + 1) * 2
					local block = readu16(data, o)
					local key = 0
					if block ~= AIR then
						key = faceKey(data, o, block, readu16(data, o + step), cull, drawn, hasAbove)
					end
					writeu16(mask, ((y - y0) * SIZE + z) * 2, key)
					any = any or key ~= 0
				end
			end
			if any then
				local xx = x
				count = mergeSlice(SIZE, sh, count, dir, function(u, v)
					return xx, v + y0, u
				end, dir == 0)
			end
		end
	end

	-- ±Z: one slice per z, u = x, v = y. Face axes: +Z (x, y), -Z (y, x).
	for dir = 4, 5 do
		local step = if dir == 4 then P * 2 else -P * 2
		for z = 0, SIZE - 1 do
			local any = false
			for y = y0, y1 - 1 do
				local hasAbove = y + 1 < height
				for x = 0, SIZE - 1 do
					local o = ((y * P + z + 1) * P + x + 1) * 2
					local block = readu16(data, o)
					local key = 0
					if block ~= AIR then
						key = faceKey(data, o, block, readu16(data, o + step), cull, drawn, hasAbove)
					end
					writeu16(mask, ((y - y0) * SIZE + x) * 2, key)
					any = any or key ~= 0
				end
			end
			if any then
				local zz = z
				count = mergeSlice(SIZE, sh, count, dir, function(u, v)
					return u, v + y0, zz
				end, dir == 5)
			end
		end
	end

	local out = buffer.create(count * 16)
	buffer.copy(out, 0, quads, 0, count * 16)
	return out, count
end

--[[
	Corners of quad `i` of `quadBuffer` in studs, as 12 numbers (x, y, z of four corners), wound
	counter-clockwise seen from outside. The chunk's core starts at (originX, originZ); a cell is
	`scale` studs wide and `scaleY` tall. Lowered fluid faces end `blockSize * (1 - surface / 9)`
	below the top of their cell. `grow` extends the quad in its own plane on every side (a tiny
	overlap hides the sparkling cracks of T-junctions between neighbouring quads).
]]
function QuadMesher.corners(
	quadBuffer: buffer,
	i: number,
	originX: number,
	originZ: number,
	scale: number,
	scaleY: number,
	blockSize: number,
	grow: number
): (
	number,
	number,
	number,
	number,
	number,
	number,
	number,
	number,
	number,
	number,
	number,
	number
)
	local o = i * 16
	local dir = readu16(quadBuffer, o)
	local x, y, z = readu16(quadBuffer, o + 2), readu16(quadBuffer, o + 4), readu16(quadBuffer, o + 6)
	local du, dv = readu16(quadBuffer, o + 8), readu16(quadBuffer, o + 10)
	local surface = readu16(quadBuffer, o + 12) // KEY_STRIDE
	local lower = if surface > 0 then (FLUID_FULL - surface) / FLUID_FULL * blockSize else 0

	-- Cell box of the quad's first cell.
	local x0, y0, z0 = originX + x * scale, y * scaleY, originZ + z * scale
	-- Face plane and the two in-plane axes (U, V with U x V = outward normal), each as
	-- (axis index 1 = X, 2 = Y, 3 = Z, length in studs).
	local px, py, pz = x0, y0, z0
	local ua, ul, va, vl
	if dir == 0 then -- +X: U = +Y, V = +Z
		px += scale
		ua, ul, va, vl = 2, du * scaleY - lower, 3, dv * scale
	elseif dir == 1 then -- -X: U = +Z, V = +Y
		ua, ul, va, vl = 3, du * scale, 2, dv * scaleY - lower
	elseif dir == 2 then -- +Y: U = +Z, V = +X
		py += scaleY - lower
		ua, ul, va, vl = 3, du * scale, 1, dv * scale
	elseif dir == 3 then -- -Y: U = +X, V = +Z
		ua, ul, va, vl = 1, du * scale, 3, dv * scale
	elseif dir == 4 then -- +Z: U = +X, V = +Y
		pz += scale
		ua, ul, va, vl = 1, du * scale, 2, dv * scaleY - lower
	else -- -Z: U = +Y, V = +X
		ua, ul, va, vl = 2, du * scaleY - lower, 1, dv * scale
	end

	-- Start corner moved back by `grow` along U and V, sizes grown by 2 * grow.
	local s = { px, py, pz }
	s[ua] -= grow
	s[va] -= grow
	ul += 2 * grow
	vl += 2 * grow
	local u = { 0, 0, 0 }
	local v = { 0, 0, 0 }
	u[ua] = ul
	v[va] = vl
	return s[1],
		s[2],
		s[3],
		s[1] + u[1],
		s[2] + u[2],
		s[3] + u[3],
		s[1] + u[1] + v[1],
		s[2] + u[2] + v[2],
		s[3] + u[3] + v[3],
		s[1] + v[1],
		s[2] + v[2],
		s[3] + v[3]
end

return QuadMesher

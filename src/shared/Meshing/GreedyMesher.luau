--!strict
--!native
--[[
	Greedy box mesher.

	Roblox parts are boxes, not faces, so instead of emitting quads we cover the blocks of a chunk
	with as few axis-aligned boxes as possible. Each box later becomes one Part.

	Rules
	  * A drawn block is "visible" when at least one neighbour does not hide it. Every visible block
	    must be covered by exactly one box of its own appearance.
	  * Opaque blocks that are completely enclosed by opaque blocks can never be seen. They are
	    wildcards: any opaque box may extend through them (whatever their material) or skip them.
	    This is what lets a grass box continue under a one block step, or a stone box swallow a
	    whole hillside, and keeps part counts low.
	  * Transparent blocks (glass) are covered exactly; fluids only where they touch a non-opaque
	    block other than themselves (their surface), so oceans become thin sheets instead of tall
	    boxes. A fluid cell without the same fluid above is lowered to its level's height
	    (Blocks.fluidHeightLut), so flowing water steps down like in Minecraft; only cells of the
	    same height merge.
	  * Blocks with decorated faces (Blocks.singleLut, e.g. chests) are always one box per block, so
	    each gets its own part to draw the faces on. Other opaque boxes may still grow through such
	    blocks where they are hidden (wildcards), which nobody can see. The same goes for shaped
	    blocks (torches, lanterns: the renderer draws their shape boxes in the cell) and blocks
	    giving off light (glowstone: one PointLight per block). Shaped blocks render like glass, so
	    they never hide a neighbour and no opaque box runs through them.
	  * Cave air can be treated as rock (`hideCaves`), which removes every cave wall from sections
	    the camera is not close to.
	  * Plants (Blocks.foliageLut: grass, ferns, flowers, mushrooms) are shaped blocks like torches.
	    With `hideFoliage` (Config.Render.Foliage off, or a chunk too far: LodTree.drawsFoliage)
	    they are not drawn at all; they hide nothing, so that changes no other box. `mesh` counts
	    them either way. A `tinted` plant (Blocks.tintedLut: grass and ferns) takes the
	    foliage colour of the soil it grows on: the soil's Blocks.tintLut entry is packed into its
	    key (the block below; for the top of a tall plant, the block below its lower half).
	  * `border` (optional) describes what surrounds the meshed range (see `Border`):
	      - seams: where a coarser LOD node is next to this one, it is drawn lower than the exact
	        terrain in the padding says. Padding above what the neighbour really draws is opened,
	        so this side draws its border cells there instead of leaving see-through holes.
	      - cave caps: a section meshed with caves visible, next to space where they are hidden
	        (a hidden section, or a coarser node), closes its tunnels with stone where they run
	        into that space; otherwise you would look out of the tunnel into the void.

	Output: a buffer of boxes, BOX_BYTES each, as u16 values
	  x, y, z      first cell (x / z local to the chunk core, y absolute cell index),
	  sx, sy, sz   size in cells,
	  key          appearance id + surface * KEY_STRIDE (see `decodeKey`). The surface field has two
	               uses, told apart by the appearance: a fluid's height (0 for full cells, otherwise
	               the height of the top cell in ninths of a block), and a tinted plant's foliage
	               tint (0 = none, t = Blocks.FOLIAGE_TINTS[t]). Shaped blocks never use the first,
	               so the field is free for the second. At most 63 either way (u16 keys).
]]

local Blocks = require(script.Parent.Parent.Blocks)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)

local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED
local LAYER = ChunkLayout.LAYER

local OPAQUE = Blocks.KIND_OPAQUE
local FLUID = Blocks.KIND_FLUID

local KEY_STRIDE = 1024
local AIR = Blocks.AIR
local FLUID_FULL = Blocks.FLUID_FULL

local appearanceLut = Blocks.appearanceLut
local fluidHeightLut = Blocks.fluidHeightLut
local kindLut = Blocks.kindLut
local singleLut = Blocks.singleLut
local tintLut = Blocks.tintLut
local tintedLut = Blocks.tintedLut
local foliageLut = Blocks.foliageLut
local cullVisibleCaves = Blocks.cullLut
local cullHiddenCaves = Blocks.cullLutHiddenCaves

local readu8 = buffer.readu8
local writeu8 = buffer.writeu8
local readu16 = buffer.readu16
local writeu16 = buffer.writeu16

local CAVE_AIR = Blocks.CAVE_AIR
local STONE = Blocks.id.Stone

--[[
	open     4 * SIZE u16 values (sides -X, +X, -Z, +Z, then position along the side): padding
	         cells at or above this cell index count as air. 0xFFFF = nothing opened.
	hidden   bit mask of the sides beyond which caves are hidden (only used when caves are visible):
	         1 -X, 2 +X, 4 -Z, 8 +Z, 16 below the range, 32 above it.
]]
export type Border = {
	open: buffer?,
	hidden: number,
}

local GreedyMesher = {}

GreedyMesher.BOX_BYTES = 14
GreedyMesher.KEY_STRIDE = KEY_STRIDE
GreedyMesher.NOT_OPEN = 0xFFFF
GreedyMesher.HIDDEN_BELOW = 16
GreedyMesher.HIDDEN_ABOVE = 32

--[[
	Splits a box key into its appearance id and its surface field: for fluids the surface height
	(0 = full height, else ninths), for tinted plants the foliage tint (0 = none, else an index
	into Blocks.FOLIAGE_TINTS).
]]
function GreedyMesher.decodeKey(key: number): (number, number)
	return key % KEY_STRIDE, key // KEY_STRIDE
end

--[[
	The foliage tint (Blocks.tintLut) of the soil under the tinted plant at padded cell index `idx`
	(cell y of `data`): the block below, or the one below that when the block below is a tinted
	plant too (the plant is the top of a tall one, standing on its lower half). 0 at the bottom of
	the world.
]]
local function soilTint(data: buffer, idx: number, y: number): number
	if y < 1 then
		return 0
	end
	local soil = readu16(data, (idx - LAYER) * 2)
	if readu8(tintedLut, readu16(appearanceLut, soil * 2)) == 1 then
		if y < 2 then
			return 0
		end
		soil = readu16(data, (idx - 2 * LAYER) * 2)
	end
	return readu8(tintLut, soil)
end

-- Scratch space, grown on demand and reused (every actor has its own copy of this module).
local scratchCells = 0
local need = buffer.create(0) -- u16 appearance that must be covered, 0 = nothing
local wild = buffer.create(0) -- u8 1 = hidden opaque cell (wildcard)
local done = buffer.create(0) -- u8 1 = already covered
local boxes = buffer.create(14 * 256)
local borderData = buffer.create(0) -- copy of the chunk with the border applied

local function ensureScratch(cells: number)
	if cells > scratchCells then
		scratchCells = cells
		need = buffer.create(cells * 2)
		wild = buffer.create(cells)
		done = buffer.create(cells)
	end
end

local function pushBox(count: number, x: number, y: number, z: number, sx: number, sy: number, sz: number, key: number)
	local offset = count * 14
	if offset + 14 > buffer.len(boxes) then
		local grown = buffer.create(buffer.len(boxes) * 2)
		buffer.copy(grown, 0, boxes, 0, offset)
		boxes = grown
	end
	writeu16(boxes, offset, x)
	writeu16(boxes, offset + 2, y)
	writeu16(boxes, offset + 4, z)
	writeu16(boxes, offset + 6, sx)
	writeu16(boxes, offset + 8, sy)
	writeu16(boxes, offset + 10, sz)
	writeu16(boxes, offset + 12, key)
end

-- True when a section cannot produce any boxes (all air, or all buried rock with caves hidden).
function GreedyMesher.isTrivial(
	y0: number,
	y1: number,
	solidBelow: number,
	emptyAbove: number,
	hideCaves: boolean
): boolean
	return y0 >= emptyAbove or (hideCaves and y1 < solidBelow)
end

--[[
	The cell range of a column that can contain visible blocks when caves are hidden: everything
	below `solidBelow - 1` is buried and everything from `emptyAbove` up is air.
]]
function GreedyMesher.activeRange(solidBelow: number, emptyAbove: number, height: number): (number, number)
	local y0 = math.max(0, solidBelow - 1)
	local y1 = math.min(height, math.max(emptyAbove, y0))
	return y0, y1
end

-- Lowest opened cell of a seam buffer (cells below it are unaffected), or NOT_OPEN.
function GreedyMesher.lowestOpen(open: buffer?): number
	local lowest = 0xFFFF
	if open then
		for i = 0, buffer.len(open) // 2 - 1 do
			lowest = math.min(lowest, readu16(open, i * 2))
		end
	end
	return lowest
end

--[[
	Returns a copy of layers y0-2 .. y1 of `data` (same layout) with `border` applied. The copy is
	scratch memory reused by the next call. Meshing that copy with no border gives the same result
	as meshing `data` with `border` (QuadMesher uses it the same way). (Two layers below the range:
	a tinted plant's soil may be two cells down, under a tall plant's lower half.)
]]
local function applyBorder(
	data: buffer,
	height: number,
	y0: number,
	y1: number,
	hideCaves: boolean,
	border: Border
): buffer
	local lo, hi = math.max(y0 - 2, 0), math.min(y1, height - 1)
	if buffer.len(borderData) < buffer.len(data) then
		borderData = buffer.create(buffer.len(data))
	end
	local d = borderData
	buffer.copy(d, lo * LAYER * 2, data, lo * LAYER * 2, (hi - lo + 1) * LAYER * 2)

	local open = border.open
	if open then
		for side = 0, 3 do
			for i = 0, SIZE - 1 do
				local limit = readu16(open, (side * SIZE + i) * 2)
				if limit <= hi then
					local px, pz
					if side == 0 then
						px, pz = 0, i + 1
					elseif side == 1 then
						px, pz = P - 1, i + 1
					elseif side == 2 then
						px, pz = i + 1, 0
					else
						px, pz = i + 1, P - 1
					end
					for y = math.max(limit, lo), hi do
						local o = ((y * P + pz) * P + px) * 2
						if readu8(cullHiddenCaves, readu16(d, o)) == 1 then
							writeu16(d, o, AIR)
						end
					end
				end
			end
		end
	end

	local hidden = border.hidden
	if hidden ~= 0 and not hideCaves then
		-- `own` is a cell being meshed, `beyond` its neighbour in hidden space (byte offsets).
		-- Hidden cave air counts as rock, and our own cave air touching hidden rock becomes a
		-- stone cap (the hidden side never draws its rock there).
		local function cap(own: number, beyond: number)
			local b = readu16(d, beyond)
			if readu8(cullHiddenCaves, b) == 1 then
				if b == CAVE_AIR then
					writeu16(d, beyond, STONE)
				end
				if readu16(d, own) == CAVE_AIR then
					writeu16(d, own, STONE)
				end
			end
		end
		for y = y0, y1 - 1 do
			local layer = y * P
			for i = 1, SIZE do
				if bit32.btest(hidden, 1) then
					cap(((layer + i) * P + 1) * 2, ((layer + i) * P) * 2)
				end
				if bit32.btest(hidden, 2) then
					cap(((layer + i) * P + SIZE) * 2, ((layer + i) * P + SIZE + 1) * 2)
				end
				if bit32.btest(hidden, 4) then
					cap(((layer + 1) * P + i) * 2, (layer * P + i) * 2)
				end
				if bit32.btest(hidden, 8) then
					cap(((layer + SIZE) * P + i) * 2, ((layer + SIZE + 1) * P + i) * 2)
				end
			end
		end
		for _, pair in { { 16, y0, y0 - 1 }, { 32, y1 - 1, y1 } } do
			local yOwn, yBeyond = pair[2], pair[3]
			if bit32.btest(hidden, pair[1]) and yBeyond >= 0 and yBeyond < height then
				for z = 1, SIZE do
					for x = 1, SIZE do
						cap(((yOwn * P + z) * P + x) * 2, ((yBeyond * P + z) * P + x) * 2)
					end
				end
			end
		end
	end
	return d
end

GreedyMesher.applyBorder = applyBorder

--[[
	Meshes cells y0 .. y1-1 of a padded chunk column `data` with `height` cells per column.
	`hideFoliage`: leave plants out (Config.Render.Foliage off, or a chunk beyond
	LodTree.drawsFoliage). Returns a new buffer of boxes, the box count and the number of plant
	cells in the range, drawn or not (the streamer remeshes those sections when its chunk starts or
	stops drawing plants).
]]
function GreedyMesher.mesh(
	data: buffer,
	height: number,
	y0: number,
	y1: number,
	hideCaves: boolean,
	border: Border?,
	hideFoliage: boolean?
): (buffer, number, number)
	if border and (border.open or border.hidden ~= 0) then
		data = applyBorder(data, height, y0, y1, hideCaves, border)
	end
	local cull = if hideCaves then cullHiddenCaves else cullVisibleCaves
	local noFoliage = hideFoliage == true
	local sh = y1 - y0
	local cells = SIZE * SIZE * sh
	ensureScratch(cells)
	buffer.fill(done, 0, 0, cells)

	-- Pass 1: classify every cell.
	local anyNeeded = false
	local plants = 0
	for y = y0, y1 - 1 do
		local hasAbove = y + 1 < height
		local hasBelow = y > 0
		for z = 0, SIZE - 1 do
			local idx = (y * P + z + 1) * P + 1
			local c = ((y - y0) * SIZE + z) * SIZE
			for _ = 0, SIZE - 1 do
				local block = readu16(data, idx * 2)
				local app = readu16(appearanceLut, block * 2)
				local needed, hidden = 0, 0
				if app ~= 0 then
					local kind = readu8(kindLut, app)
					if kind == OPAQUE then
						if
							(not hasAbove or readu8(cull, readu16(data, (idx + LAYER) * 2)) == 0)
							or readu8(cull, readu16(data, (idx - 1) * 2)) == 0
							or readu8(cull, readu16(data, (idx + 1) * 2)) == 0
							or readu8(cull, readu16(data, (idx - P) * 2)) == 0
							or readu8(cull, readu16(data, (idx + P) * 2)) == 0
							or (hasBelow and readu8(cull, readu16(data, (idx - LAYER) * 2)) == 0)
						then
							needed = app
						else
							hidden = 1
						end
					elseif kind == FLUID then
						-- Surface only: a neighbour that is neither opaque nor this exact block (a
						-- different level of the same fluid counts, so steps between levels are closed).
						local above = if hasAbove then readu16(data, (idx + LAYER) * 2) else AIR
						local visible = not hasAbove or (readu8(cull, above) == 0 and above ~= block)
						if not visible then
							local n = readu16(data, (idx - 1) * 2)
							visible = readu8(cull, n) == 0 and n ~= block
						end
						if not visible then
							local n = readu16(data, (idx + 1) * 2)
							visible = readu8(cull, n) == 0 and n ~= block
						end
						if not visible then
							local n = readu16(data, (idx - P) * 2)
							visible = readu8(cull, n) == 0 and n ~= block
						end
						if not visible then
							local n = readu16(data, (idx + P) * 2)
							visible = readu8(cull, n) == 0 and n ~= block
						end
						if not visible and hasBelow then
							local n = readu16(data, (idx - LAYER) * 2)
							visible = readu8(cull, n) == 0 and n ~= block
						end
						if visible then
							-- Lower the surface unless the same fluid continues above.
							local surface = readu8(fluidHeightLut, block)
							if surface < FLUID_FULL and readu16(appearanceLut, above * 2) ~= app then
								needed = app + surface * KEY_STRIDE
							else
								needed = app
							end
						end
					elseif readu8(foliageLut, app) == 1 then
						-- Plants (never opaque or fluid): counted, and drawn unless hidden; tinted ones
						-- carry their soil's foliage tint in the surface field. They hide nothing, so
						-- leaving them out changes no other box.
						plants += 1
						if noFoliage then
							needed = 0
						elseif readu8(tintedLut, app) == 1 then
							needed = app + soilTint(data, idx, y) * KEY_STRIDE
						else
							needed = app
						end
					else
						needed = app
					end
				end
				if needed ~= 0 then
					anyNeeded = true
				end
				writeu16(need, c * 2, needed)
				writeu8(wild, c, hidden)
				idx += 1
				c += 1
			end
		end
	end

	if not anyNeeded then
		return buffer.create(0), 0, plants
	end

	-- Pass 2: grow boxes along X, then Z, then Y.
	local count = 0
	for ly = 0, sh - 1 do
		for z = 0, SIZE - 1 do
			for x = 0, SIZE - 1 do
				local c = (ly * SIZE + z) * SIZE + x
				local key = readu16(need, c * 2)
				if key ~= 0 and readu8(done, c) == 0 then
					local app = key % KEY_STRIDE
					local opaque = readu8(kindLut, app) == OPAQUE
					-- Decorated blocks never grow: the limits below stop every loop at once.
					local single = readu8(singleLut, app) == 1
					local maxX = if single then x + 1 else SIZE
					local maxZ = if single then z + 1 else SIZE
					local maxY = if single then ly + 1 else sh

					local x1 = x
					while x1 + 1 < maxX do
						local c2 = c + x1 + 1 - x
						local a2 = readu16(need, c2 * 2)
						if (a2 == key and readu8(done, c2) == 0) or (opaque and readu8(wild, c2) == 1) then
							x1 += 1
						else
							break
						end
					end

					local z1 = z
					while z1 + 1 < maxZ do
						local row = (ly * SIZE + z1 + 1) * SIZE
						local ok = true
						for xx = x, x1 do
							local c2 = row + xx
							local a2 = readu16(need, c2 * 2)
							if not ((a2 == key and readu8(done, c2) == 0) or (opaque and readu8(wild, c2) == 1)) then
								ok = false
								break
							end
						end
						if not ok then
							break
						end
						z1 += 1
					end

					local ly1 = ly
					while ly1 + 1 < maxY do
						local ok = true
						for zz = z, z1 do
							local row = ((ly1 + 1) * SIZE + zz) * SIZE
							for xx = x, x1 do
								local c2 = row + xx
								local a2 = readu16(need, c2 * 2)
								if
									not ((a2 == key and readu8(done, c2) == 0) or (opaque and readu8(wild, c2) == 1))
								then
									ok = false
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
						ly1 += 1
					end

					for yy = ly, ly1 do
						for zz = z, z1 do
							local row = (yy * SIZE + zz) * SIZE
							for xx = x, x1 do
								local c2 = row + xx
								if readu16(need, c2 * 2) == key then
									writeu8(done, c2, 1)
								end
							end
						end
					end

					pushBox(count, x, ly + y0, z, x1 - x + 1, ly1 - ly + 1, z1 - z + 1, key)
					count += 1
				end
			end
		end
	end

	local out = buffer.create(count * 14)
	buffer.copy(out, 0, boxes, 0, count * 14)
	return out, count, plants
end

return GreedyMesher

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
	  * Cave air can be treated as rock (`hideCaves`), which removes every cave wall from sections
	    the camera is not close to.

	Output: a buffer of boxes, BOX_BYTES each, as u16 values
	  x, y, z      first cell (x / z local to the chunk core, y absolute cell index),
	  sx, sy, sz   size in cells,
	  key          appearance id + surfaceHeight * KEY_STRIDE. surfaceHeight is 0 for full cells,
	               otherwise the height of the top cell in ninths of a block (see `decodeKey`).
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
local cullVisibleCaves = Blocks.cullLut
local cullHiddenCaves = Blocks.cullLutHiddenCaves

local readu8 = buffer.readu8
local writeu8 = buffer.writeu8
local readu16 = buffer.readu16
local writeu16 = buffer.writeu16

local GreedyMesher = {}

GreedyMesher.BOX_BYTES = 14
GreedyMesher.KEY_STRIDE = KEY_STRIDE

-- Splits a box key into its appearance id and surface height (0 = full height, else ninths).
function GreedyMesher.decodeKey(key: number): (number, number)
	return key % KEY_STRIDE, key // KEY_STRIDE
end

-- Scratch space, grown on demand and reused (every actor has its own copy of this module).
local scratchCells = 0
local need = buffer.create(0) -- u16 appearance that must be covered, 0 = nothing
local wild = buffer.create(0) -- u8 1 = hidden opaque cell (wildcard)
local done = buffer.create(0) -- u8 1 = already covered
local boxes = buffer.create(14 * 256)

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

--[[
	Meshes cells y0 .. y1-1 of a padded chunk column `data` with `height` cells per column.
	Returns a new buffer of boxes and the box count.
]]
function GreedyMesher.mesh(data: buffer, height: number, y0: number, y1: number, hideCaves: boolean): (buffer, number)
	local cull = if hideCaves then cullHiddenCaves else cullVisibleCaves
	local sh = y1 - y0
	local cells = SIZE * SIZE * sh
	ensureScratch(cells)
	buffer.fill(done, 0, 0, cells)

	-- Pass 1: classify every cell.
	local anyNeeded = false
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
		return buffer.create(0), 0
	end

	-- Pass 2: grow boxes along X, then Z, then Y.
	local count = 0
	for ly = 0, sh - 1 do
		for z = 0, SIZE - 1 do
			for x = 0, SIZE - 1 do
				local c = (ly * SIZE + z) * SIZE + x
				local key = readu16(need, c * 2)
				if key ~= 0 and readu8(done, c) == 0 then
					local opaque = readu8(kindLut, key % KEY_STRIDE) == OPAQUE

					local x1 = x
					while x1 + 1 < SIZE do
						local c2 = c + x1 + 1 - x
						local a2 = readu16(need, c2 * 2)
						if (a2 == key and readu8(done, c2) == 0) or (opaque and readu8(wild, c2) == 1) then
							x1 += 1
						else
							break
						end
					end

					local z1 = z
					while z1 + 1 < SIZE do
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
					while ly1 + 1 < sh do
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
	return out, count
end

return GreedyMesher

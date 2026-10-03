--!strict
--!native
--[[
	The interface structures use to write blocks into the chunk currently being generated.

	Structures are written in *world block coordinates*; the writer clips everything outside the
	chunk (including its one-cell border), so a tree whose canopy crosses a chunk edge is simply
	written partially by each chunk it touches. Because placement is deterministic, all those
	partial writes line up.

	On LOD chunks (cells of `step` blocks) the writer point-samples like the terrain does: a cell is
	written when the block at its sample point (the cell center) is written. Structures therefore
	keep their real size from far away instead of growing to whole cells. Trunks (`force`) still mark
	the whole cell on LOD 1 so trees do not lose their trunks at medium range.
]]

local Blocks = require(script.Parent.Parent.Parent.Blocks)
local ChunkLayout = require(script.Parent.Parent.Parent.World.ChunkLayout)

local AIR = Blocks.AIR
local CAVE_AIR = Blocks.CAVE_AIR
local P = ChunkLayout.PADDED
local readu16 = buffer.readu16
local writeu16 = buffer.writeu16

export type Writer = {
	-- Places a block only where there is air (leaves, decorations).
	set: (x: number, y: number, z: number, id: number) -> (),
	-- Always places the block (trunks).
	force: (x: number, y: number, z: number, id: number) -> (),
	-- Block at a world position, or nil when outside this chunk.
	get: (x: number, y: number, z: number) -> number?,
	-- One above the highest cell written so far.
	top: () -> number,
}

local Writer = {}

-- `originX` / `originZ`: world block coordinate of the first *core* cell. `heightCells`: cells per column.
function Writer.new(data: buffer, originX: number, originZ: number, step: number, heightCells: number): Writer
	local minX = originX - step
	local minZ = originZ - step
	local half = step // 2
	local highest = 0

	-- Byte offset of the cell containing a block, or -1 when outside the chunk.
	local function cellOffset(x: number, y: number, z: number): number
		local px = (x - minX) // step
		local pz = (z - minZ) // step
		local cy = y // step
		if px < 0 or px >= P or pz < 0 or pz >= P or cy < 0 or cy >= heightCells then
			return -1
		end
		return ((cy * P + pz) * P + px) * 2
	end

	-- Same, but only when the block is the sample point of its cell.
	local function sampleOffset(x: number, y: number, z: number): number
		if (x - minX) % step ~= half or y % step ~= half or (z - minZ) % step ~= half then
			return -1
		end
		return cellOffset(x, y, z)
	end

	local forceOffset: (number, number, number) -> number = if step <= 2 then cellOffset else sampleOffset

	local function touch(y: number)
		local cell = y // step + 1
		if cell > highest then
			highest = cell
		end
	end

	return {
		set = function(x: number, y: number, z: number, id: number)
			local o = sampleOffset(x, y, z)
			if o >= 0 then
				local current = readu16(data, o)
				if current == AIR or current == CAVE_AIR then
					writeu16(data, o, id)
					touch(y)
				end
			end
		end,
		force = function(x: number, y: number, z: number, id: number)
			local o = forceOffset(x, y, z)
			if o >= 0 then
				writeu16(data, o, id)
				touch(y)
			end
		end,
		get = function(x: number, y: number, z: number): number?
			local o = cellOffset(x, y, z)
			if o >= 0 then
				return readu16(data, o)
			end
			return nil
		end,
		top = function(): number
			return highest
		end,
	}
end

return Writer

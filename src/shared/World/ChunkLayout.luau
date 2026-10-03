--!strict
--!native
--[[
	Memory layout of chunk voxel data.

	A chunk is a full-height column stored in a `buffer` with one u16 block id per cell. Every chunk
	carries a one-cell border ("padding") copied from its four neighbours, so the mesher can decide
	which faces are visible without touching other chunks:

	    padded X/Z coordinates: 0 .. PADDED - 1     (core cells are 1 .. SIZE)
	    index(px, y, pz) = (y * PADDED + pz) * PADDED + px

	Y is the outermost axis so one section of the column is a contiguous slice of the buffer.

	LOD chunks use the same layout with fewer, larger cells: a level L chunk covers SIZE * 2^L blocks
	horizontally with SIZE cells and WorldHeight / 2^L cells vertically.

	"Local indices" address only the core of a LOD 0 chunk and are what the server stores / sends
	for edits:  localIndex(lx, y, lz) = (y * SIZE + lz) * SIZE + lx
]]

local Config = require(script.Parent.Parent.Config)

local SIZE = Config.ChunkSize
local PADDED = SIZE + 2
local LAYER = PADDED * PADDED

local ChunkLayout = {}

ChunkLayout.SIZE = SIZE
ChunkLayout.PADDED = PADDED
ChunkLayout.LAYER = LAYER
ChunkLayout.HEIGHT = Config.WorldHeight

-- Index of a padded cell.
function ChunkLayout.index(px: number, y: number, pz: number): number
	return (y * PADDED + pz) * PADDED + px
end

-- Index of a core cell given local coordinates (0 .. SIZE-1).
function ChunkLayout.coreIndex(lx: number, y: number, lz: number): number
	return (y * PADDED + lz + 1) * PADDED + lx + 1
end

function ChunkLayout.cellCount(height: number): number
	return LAYER * height
end

function ChunkLayout.create(height: number): buffer
	return buffer.create(LAYER * height * 2)
end

function ChunkLayout.height(data: buffer): number
	return buffer.len(data) // (LAYER * 2)
end

function ChunkLayout.get(data: buffer, lx: number, y: number, lz: number): number
	return buffer.readu16(data, ((y * PADDED + lz + 1) * PADDED + lx + 1) * 2)
end

function ChunkLayout.set(data: buffer, lx: number, y: number, lz: number, id: number)
	buffer.writeu16(data, ((y * PADDED + lz + 1) * PADDED + lx + 1) * 2, id)
end

-- Padded accessors; px / pz range over -1 .. SIZE (i.e. include the border).
function ChunkLayout.getPadded(data: buffer, px: number, y: number, pz: number): number
	return buffer.readu16(data, ((y * PADDED + pz + 1) * PADDED + px + 1) * 2)
end

function ChunkLayout.setPadded(data: buffer, px: number, y: number, pz: number, id: number)
	buffer.writeu16(data, ((y * PADDED + pz + 1) * PADDED + px + 1) * 2, id)
end

function ChunkLayout.localIndex(lx: number, y: number, lz: number): number
	return (y * SIZE + lz) * SIZE + lx
end

function ChunkLayout.fromLocalIndex(index: number): (number, number, number)
	local lx = index % SIZE
	local rest = index // SIZE
	return lx, rest // SIZE, rest % SIZE
end

return ChunkLayout

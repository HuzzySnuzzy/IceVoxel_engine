--!strict
--[[
	Coordinate conversions and numeric keys.

	Block coordinates are integers; block (x, y, z) occupies studs [x, x+1) * BlockSize on each axis.
	Chunk (cx, cz) contains blocks cx*SIZE .. cx*SIZE + SIZE - 1 on X (same on Z).

	Keys are plain numbers (no string building in hot paths) and fit losslessly in a double:
	  * node keys:  level * 2^42 + (nx + 2^20) * 2^21 + (nz + 2^20)
	                a LOD 0 node key is the same number as the chunk key.
	  * pos keys:   ((x + 2^20) * 2^21 + (z + 2^20)) * 1024 + y   (|x|,|z| < 2^20, 0 <= y < 1024)
]]

local Config = require(script.Parent.Parent.Config)

local SIZE = Config.ChunkSize
local BLOCK = Config.BlockSize

local OFFSET = 1048576 -- 2^20
local SPAN = 2097152 -- 2^21
local LEVEL_SPAN = 4398046511104 -- 2^42

local Coords = {}

function Coords.chunkKey(cx: number, cz: number): number
	return (cx + OFFSET) * SPAN + (cz + OFFSET)
end

function Coords.nodeKey(level: number, nx: number, nz: number): number
	return level * LEVEL_SPAN + (nx + OFFSET) * SPAN + (nz + OFFSET)
end

function Coords.decodeNodeKey(key: number): (number, number, number)
	local level = key // LEVEL_SPAN
	local rest = key - level * LEVEL_SPAN
	local nx = rest // SPAN
	return level, nx - OFFSET, rest - nx * SPAN - OFFSET
end

function Coords.decodeChunkKey(key: number): (number, number)
	local cx = key // SPAN
	return cx - OFFSET, key - cx * SPAN - OFFSET
end

function Coords.posKey(x: number, y: number, z: number): number
	return ((x + OFFSET) * SPAN + (z + OFFSET)) * 1024 + y
end

function Coords.decodePosKey(key: number): (number, number, number)
	local y = key % 1024
	local xz = key // 1024
	local xo = xz // SPAN
	return xo - OFFSET, y, xz - xo * SPAN - OFFSET
end

-- Block -> (chunk x, chunk z, local x, local z).
function Coords.blockToChunk(x: number, z: number): (number, number, number, number)
	local cx, cz = x // SIZE, z // SIZE
	return cx, cz, x - cx * SIZE, z - cz * SIZE
end

-- Studs -> block coordinate (works per axis).
function Coords.studToBlock(v: number): number
	return math.floor(v / BLOCK)
end

-- Center of a block in studs, per axis.
function Coords.blockCenter(v: number): number
	return (v + 0.5) * BLOCK
end

return Coords

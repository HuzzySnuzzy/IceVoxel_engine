--!strict
--[[
	Chooses which chunks (quadtree nodes) should be visible around a point.

	The world is tiled with root nodes of the coarsest level. A node at level L covers
	ChunkSize * 2^L blocks and is split into its four children while the viewer is closer than
	`SplitDistance * nodeSize`. The leaves of that recursion are the chunks to display; they never
	overlap and leave no gaps, and detail falls off smoothly with distance.

	Hysteresis: a node that was a leaf in the previous selection needs the viewer a bit closer
	before it splits, so standing on a boundary does not rebuild chunks back and forth.
]]

local Config = require(script.Parent.Parent.Config)
local Coords = require(script.Parent.Coords)

local SIZE = Config.ChunkSize
local MAX_LEVEL = Config.Lod.Levels - 1
local SPLIT = Config.Lod.SplitDistance
local VIEW = Config.Lod.ViewDistance
local HYSTERESIS = 0.85

local LodTree = {}

LodTree.MAX_LEVEL = MAX_LEVEL

function LodTree.nodeSize(level: number): number
	return SIZE * bit32.lshift(1, level)
end

-- Horizontal distance (blocks) from (x, z) to the square of a node; 0 inside it.
function LodTree.distance(level: number, nx: number, nz: number, x: number, z: number): number
	local size = SIZE * bit32.lshift(1, level)
	local minX, minZ = nx * size, nz * size
	local dx = math.max(minX - x, 0, x - (minX + size))
	local dz = math.max(minZ - z, 0, z - (minZ + size))
	return math.sqrt(dx * dx + dz * dz)
end

--[[
	Returns { [nodeKey] = level } for the viewer at block coordinates (x, z).
	`previous` is the result of the last call (optional, enables hysteresis).
]]
function LodTree.select(x: number, z: number, previous: { [number]: number }?): { [number]: number }
	local out: { [number]: number } = {}
	local distance = LodTree.distance

	local function visit(level: number, nx: number, nz: number)
		if level > 0 then
			local threshold = SPLIT * SIZE * bit32.lshift(1, level)
			if previous and previous[Coords.nodeKey(level, nx, nz)] then
				threshold *= HYSTERESIS
			end
			if distance(level, nx, nz, x, z) < threshold then
				local cx, cz = nx * 2, nz * 2
				visit(level - 1, cx, cz)
				visit(level - 1, cx + 1, cz)
				visit(level - 1, cx, cz + 1)
				visit(level - 1, cx + 1, cz + 1)
				return
			end
		end
		out[Coords.nodeKey(level, nx, nz)] = level
	end

	local rootSize = LodTree.nodeSize(MAX_LEVEL)
	local reach = math.ceil(VIEW / rootSize)
	local rx, rz = x // rootSize, z // rootSize
	for nz = rz - reach, rz + reach do
		for nx = rx - reach, rx + reach do
			if distance(MAX_LEVEL, nx, nz, x, z) <= VIEW then
				visit(MAX_LEVEL, nx, nz)
			end
		end
	end
	return out
end

return LodTree

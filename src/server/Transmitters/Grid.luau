--!strict
--[[
	Block positions for the server's Mekanism pipes: pos keys (Shared/World/Coords) and the sides
	between them (Shared/Transmitters: 0 Down, 1 Up, 2 North, 3 South, 4 West, 5 East).

	Pos keys only exist inside the world (0 <= y < Config.WorldHeight, |x| and |z| below 2^20), so
	stepping out of it gives nil.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)
local Transmitters = require(Shared.Transmitters)

local HEIGHT = Config.WorldHeight
local SIZE = Config.ChunkSize
-- Coords.posKey holds |x| and |z| below 2^20.
local LIMIT = 1048575

local DX = { 0, 0, 0, 0, -1, 1 }
local DY = { -1, 1, 0, 0, 0, 0 }
local DZ = { 0, 0, -1, 1, 0, 0 }
for side = 0, 5 do
	local dx, dy, dz = Transmitters.offset(side)
	assert(DX[side + 1] == dx and DY[side + 1] == dy and DZ[side + 1] == dz, "Grid sides disagree with Transmitters")
end

local Grid = {}

-- The pos key of (x, y, z), nil outside the world.
function Grid.key(x: number, y: number, z: number): number?
	if y < 0 or y >= HEIGHT or math.abs(x) > LIMIT or math.abs(z) > LIMIT then
		return nil
	end
	return Coords.posKey(x, y, z)
end

Grid.decode = Coords.decodePosKey

-- The key of the block beyond `side` of `key`, nil outside the world.
function Grid.neighbour(key: number, side: number): number?
	local x, y, z = Coords.decodePosKey(key)
	return Grid.key(x + DX[side + 1], y + DY[side + 1], z + DZ[side + 1])
end

-- The side of `from` that faces `to` (neighbours only), else nil.
function Grid.sideBetween(from: number, to: number): number?
	local ax, ay, az = Coords.decodePosKey(from)
	local bx, by, bz = Coords.decodePosKey(to)
	return Transmitters.sideOf(bx - ax, by - ay, bz - az)
end

-- The chunk key (Coords.chunkKey) of block (x, z).
function Grid.chunkKey(x: number, z: number): number
	return Coords.chunkKey(x // SIZE, z // SIZE)
end

return Grid

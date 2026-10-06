--!strict
--[[
	Is a cell under the open sky? The server keeps no light levels, so the random ticks that need
	daylight (grass spreading, saplings growing: Minecraft's light 9 or more) ask whether nothing
	opaque stands above the cell up to the top of its chunk (everything higher is air). Fluids,
	leaves, glass and plants let it through. nil when the chunk isn't loaded.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local ChunkLayout = require(Shared.World.ChunkLayout)

local SIZE = ChunkLayout.SIZE

local Skylight = {}

function Skylight.open(world: any, x: number, y: number, z: number): boolean?
	local chunk = world:peekChunk(x // SIZE, z // SIZE)
	if chunk == nil then
		return nil
	end
	for cell = y, chunk.height - 1 do
		local block = world:peekBlock(x, cell, z)
		if block == nil then
			return nil
		elseif Blocks.isOpaque(block) then
			return false
		end
	end
	return true
end

return Skylight

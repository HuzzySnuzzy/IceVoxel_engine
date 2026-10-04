--!strict
--[[
	Grass turns into dirt when something opaque is placed on top of it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)

local Grass = {}

Grass.tickDelay = 20

function Grass.onTick(world: any, _ticker: any, x: number, y: number, z: number, _block: number)
	local above = world:peekBlock(x, y + 1, z)
	if above ~= nil and Blocks.isOpaque(above) then
		world:setBlock(x, y, z, Blocks.id.Dirt)
	end
end

return Grass

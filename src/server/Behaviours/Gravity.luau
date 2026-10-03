--!strict
--[[
	Falling blocks (sand, gravel): move down one block per update while there is air or fluid below.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)

local Gravity = {}

Gravity.tickDelay = 2

function Gravity.onTick(world: any, _ticker: any, x: number, y: number, z: number, block: number)
	if y <= 0 then
		return
	end
	local below = world:peekBlock(x, y - 1, z)
	if below ~= nil and Blocks.isReplaceable(below) then
		world:setBlock(x, y, z, Blocks.AIR)
		-- Landing in the new spot notifies it again, so the block keeps falling next tick.
		world:setBlock(x, y - 1, z, block)
	end
end

return Gravity

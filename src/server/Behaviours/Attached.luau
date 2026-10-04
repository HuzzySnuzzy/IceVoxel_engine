--!strict
--[[
	Blocks that hang on another one (torches, wall torches, lanterns: BlockList `support`).

	When a neighbour changes, the block checks the block it hangs on next tick; if that is no longer
	sturdy (broken, replaced by water, never there), the block breaks and drops its item, in every
	game mode (Minecraft's updateShape returning air: TorchBlock, WallTorchBlock, LanternBlock). A
	support in an unloaded chunk is waited for, not guessed. Drops go through Behaviours/Drops.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)

local Drops = require(script.Parent.Drops)

local RETRY_TICKS = 40

local Attached = {}

Attached.tickDelay = 1

function Attached.onTick(world: any, ticker: any, x: number, y: number, z: number, block: number)
	local dx, dy, dz = Blocks.supportOffset(block)
	if dx == nil or dy == nil or dz == nil then
		return
	end
	local support = world:peekBlock(x + dx, y + dy, z + dz)
	if support == nil then
		ticker:schedule(x, y, z, RETRY_TICKS)
		return
	end
	if not Blocks.isSturdy(support) and world:setBlock(x, y, z, Blocks.AIR) then
		Drops.block(x, y, z, block)
	end
end

return Attached

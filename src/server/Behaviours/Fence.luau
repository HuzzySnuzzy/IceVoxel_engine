--!strict
--[[
	Fences joining what is beside them (Minecraft's FenceBlock.updateShape): when a neighbour
	changes, next tick a fence becomes the variant of its group with arms to every side whose
	neighbour is a fence or a sturdy block (Blocks.fenceConnections). No sound, no drop: it is the
	same fence. A generated lone post in a cave (CaveOakFence) stays one until it gains an arm,
	then becomes the ordinary fence. A neighbour in a chunk that is not loaded is waited for, not
	guessed (as Attached does).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)

local RETRY_TICKS = 40

local Fence = {}

Fence.tickDelay = 1

--[[
	The variant the fence `block` at (x, y, z) should be, nil while a neighbour is not loaded
	(`getBlock` nil). A cave twin with no arms stays as it is.
]]
function Fence.variant(
	block: number,
	getBlock: (x: number, y: number, z: number) -> number?,
	x: number,
	y: number,
	z: number
): number?
	for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
		if getBlock(x + d[1], y, z + d[2]) == nil then
			return nil
		end
	end
	local mask = Blocks.fenceConnections(getBlock, x, y, z)
	if mask == 0 and Blocks.isCaveTwin(block) then
		return block
	end
	return Blocks.fenceVariant(block, mask) or block
end

function Fence.onTick(world: any, ticker: any, x: number, y: number, z: number, block: number)
	local wanted = Fence.variant(block, function(bx: number, by: number, bz: number): number?
		return world:peekBlock(bx, by, bz)
	end, x, y, z)
	if wanted == nil then
		ticker:schedule(x, y, z, RETRY_TICKS)
	elseif wanted ~= block then
		world:setBlock(x, y, z, wanted)
	end
end

return Fence

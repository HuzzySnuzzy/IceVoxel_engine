--!strict
--[[
	Blocks that hang on another one (torches, wall torches, lanterns, ladders, rails, rope, vines,
	glow lichen: BlockList `support`).

	When a neighbour changes, the block checks what holds it next tick (Blocks.canSurvive: a sturdy
	block on its `support` side, or for `chain` blocks the same kind of block right above: a rope
	under a rope, a vine under a vine); if nothing does any more (broken, replaced by water, never
	there), the block breaks and drops its item, in every game mode (Minecraft's updateShape
	returning air: TorchBlock, WallTorchBlock, LanternBlock, LadderBlock, Supplementaries'
	RopeBlock), and everyone near hears it break (Level.destroyBlock's break effect, Audio/Sounds).
	Breaking it is a neighbour change for the block below, so a hanging rope or vine comes down one
	block a tick. A support in an unloaded chunk is waited for, not guessed. Drops go through
	Behaviours/Drops.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)

local Drops = require(script.Parent.Drops)
local Sounds = require(script.Parent.Parent.Audio.Sounds)

local RETRY_TICKS = 40

local Attached = {}

Attached.tickDelay = 1

function Attached.onTick(world: any, ticker: any, x: number, y: number, z: number, block: number)
	local dx, dy, dz = Blocks.supportOffset(block)
	if dx == nil or dy == nil or dz == nil then
		return
	end
	local function peek(bx: number, by: number, bz: number): number?
		return world:peekBlock(bx, by, bz)
	end
	if Blocks.canSurvive(block, peek, x, y, z) then
		return
	end
	-- (Its support, or for a chain the block above it, may only not be loaded yet.)
	if peek(x + dx, y + dy, z + dz) == nil or (Blocks.get(block).chain and peek(x, y + 1, z) == nil) then
		ticker:schedule(x, y, z, RETRY_TICKS)
		return
	end
	if world:setBlock(x, y, z, Blocks.AIR) then
		Sounds.playBlock(block, "break", x, y, z)
		Drops.block(x, y, z, block)
	end
end

return Attached

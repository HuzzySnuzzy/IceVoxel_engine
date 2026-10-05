--!strict
--[[
	Plants (BlockList `plant`: grass, ferns, flowers, mushrooms and both halves of tall ones), kept
	up like Minecraft's BushBlock and DoublePlantBlock.updateShape.

	When a neighbour changes, the plant checks next tick that it can still stand there:
	  * a single plant or a lower half needs a block of its soil set below (Blocks.canSurvive:
	    grass, dirt, podzol...; sand for dead bushes; mycelium, podzol or any sturdy opaque block
	    for mushrooms), and a lower half its own upper half right above;
	  * an upper half needs its own lower half right below.
	If not, it breaks: air, everyone near hears it (Audio/Sounds), and it drops what it drops by
	itself (Behaviours/Drops, Items.blockDrops: no tool), in every game mode, like Minecraft's
	updateShape returning air (Level.destroyBlock with drops). An upper half drops nothing, so a
	tall plant pops once: its soil goes -> the lower half breaks and drops -> the top, alone,
	breaks with nothing; its top washed away by water (dropping nothing) -> the lower half breaks
	and drops. A neighbour in a chunk that is not loaded is waited for, not guessed (as in
	Attached), though a plant's neighbours above and below are always in its own chunk.

	A player breaking either half removes both at once with a single drop (Network/EditRules,
	ServerNet), so this only sees plants whose world changed under them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)

local Drops = require(script.Parent.Drops)
local Sounds = require(script.Parent.Parent.Audio.Sounds)

local RETRY_TICKS = 40

local Plant = {}

Plant.tickDelay = 1

--[[
	Can the plant `block` stay at (x, y, z)? Its soil (or lower half) below and, for a lower half,
	its upper half above. nil when that depends on a block that is not loaded (`getBlock` nil).
]]
function Plant.stays(
	block: number,
	getBlock: (x: number, y: number, z: number) -> number?,
	x: number,
	y: number,
	z: number
): boolean?
	if getBlock(x, y - 1, z) == nil then
		return nil
	end
	local top = Blocks.plantTop(block)
	if top ~= nil then
		local above = getBlock(x, y + 1, z)
		if above == nil then
			return nil
		elseif above ~= top then
			return false
		end
	end
	return Blocks.canSurvive(block, getBlock, x, y, z)
end

function Plant.onTick(world: any, ticker: any, x: number, y: number, z: number, block: number)
	local stays = Plant.stays(block, function(bx: number, by: number, bz: number): number?
		return world:peekBlock(bx, by, bz)
	end, x, y, z)
	if stays == nil then
		ticker:schedule(x, y, z, RETRY_TICKS)
	elseif not stays and world:setBlock(x, y, z, Blocks.AIR) then
		Sounds.playBlock(block, "break", x, y, z)
		Drops.block(x, y, z, block)
	end
end

return Plant

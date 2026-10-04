--!strict
--[[
	How long survival players take to break blocks, with Minecraft's rules for bare hands (there are
	no tools): every block can be harvested, so each tick of mining adds

	    progress = 1 / hardness / 30

	(x 0.2 under water and x 0.2 while not standing on the ground), and the block breaks when the
	progress reaches 1: stone (hardness 1.5) takes 45 ticks, 2.25 s. Hardness 0 breaks at once,
	unbreakable blocks (hardness < 0) never.

	The server accepts a break once `TOLERANCE` of the time has passed since the player started
	(Minecraft's ServerPlayerGameMode does the same), which covers network delay.
]]

local Blocks = require(script.Parent.Blocks)

local Mining = {}

Mining.TICK_RATE = 20
Mining.TOLERANCE = 0.7
-- Ticks between breaking a block and starting on the next one (survival and creative).
Mining.DELAY_TICKS = 5

-- Progress per tick of mining `block` (0 = can't be mined).
function Mining.progressPerTick(block: number, onGround: boolean?, underwater: boolean?): number
	local def = Blocks.get(block)
	if def == nil or not def.breakable or def.hardness < 0 then
		return 0
	end
	if def.hardness == 0 then
		return 1
	end
	local speed = 1
	if underwater then
		speed /= 5
	end
	if onGround == false then
		speed /= 5
	end
	return speed / def.hardness / 30
end

-- Ticks of mining it takes (math.huge if it can't be mined).
function Mining.ticks(block: number, onGround: boolean?, underwater: boolean?): number
	local progress = Mining.progressPerTick(block, onGround, underwater)
	if progress <= 0 then
		return math.huge
	end
	return math.ceil(1 / progress - 1e-9)
end

--[[
	Server check: may a player who started mining `block` `elapsed` seconds ago break it now? Uses
	the fastest possible speed (on the ground, dry), like Minecraft's server.
]]
function Mining.mayBreak(block: number, elapsed: number): boolean
	local progress = Mining.progressPerTick(block, true, false)
	if progress <= 0 then
		return false
	end
	local ticks = math.floor(elapsed * Mining.TICK_RATE + 1e-6)
	return progress * (ticks + 1) >= Mining.TOLERANCE
end

return Mining

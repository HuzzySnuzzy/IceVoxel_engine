--!strict
--[[
	How long survival players take to break blocks, with Minecraft's rules (Block.getDestroyProgress,
	Player.getDestroySpeed). Each tick of mining adds

	    progress = speed / hardness / (canHarvest ? 30 : 100)

	where `speed` is the held tool's speed when it is the block's kind of tool (BlockList `tool`;
	Minecraft's tiers: wood 2, stone 4, iron 6, diamond 8, gold 12; swords 1.5 on leaves; Shears 15
	on blocks they harvest, BlockList `shearDrops`: leaves, and plants that break at once), else 1,
	divided by 5 under water and by 5 while not standing on the ground. `canHarvest`: the block drops
	anything with that tool (Items.canHarvest: blocks with a `toolLevel` need a good enough tool, so
	stone by hand takes 7.5 s and drops nothing). The block breaks when the progress reaches 1:
	stone with a wooden pickaxe (hardness 1.5, speed 2) takes 23 ticks. Hardness 0 breaks at once,
	unbreakable blocks (hardness < 0) never.

	The server accepts a break once `TOLERANCE` of the time has passed since the player started
	(Minecraft's ServerPlayerGameMode does the same), which covers network delay. A break arriving
	earlier still is finished by the server once the full time has passed (Minecraft's delayed
	destroy, in ServerNet).
]]

local Blocks = require(script.Parent.Blocks)
local Items = require(script.Parent.Items)

local Mining = {}

Mining.TICK_RATE = 20
Mining.TOLERANCE = 0.7
-- Ticks between breaking a block and starting on the next one (survival and creative).
Mining.DELAY_TICKS = 5
-- A sword's speed on blocks it cuts well (leaves; Minecraft's sword_efficient tag).
local SWORD_SPEED = 1.5

-- Mining speed of `tool` (an item id, nil = bare hands) on `block`.
function Mining.toolSpeed(block: number, tool: number?): number
	local data = Items.tool(tool)
	if data == nil then
		return 1
	end
	local def = Blocks.get(block)
	local kind = def.tool
	if data.kind == "sword" then
		return if kind == "hoe" then SWORD_SPEED else 1
	elseif data.kind == "shears" then
		-- (Minecraft's ShearsItem.getDestroySpeed: 15 on leaves and cobwebs, which they harvest.)
		return if def.shearDrops ~= nil then data.speed else 1
	end
	return if kind ~= nil and data.kind == kind then data.speed else 1
end

-- Progress per tick of mining `block` holding `tool` (0 = can't be mined).
function Mining.progressPerTick(block: number, onGround: boolean?, underwater: boolean?, tool: number?): number
	local def = Blocks.get(block)
	if def == nil or not def.breakable or def.hardness < 0 then
		return 0
	end
	if def.hardness == 0 then
		return 1
	end
	local speed = Mining.toolSpeed(block, tool)
	if underwater then
		speed /= 5
	end
	if onGround == false then
		speed /= 5
	end
	return speed / def.hardness / (if Items.canHarvest(block, tool) then 30 else 100)
end

-- Ticks of mining it takes (math.huge if it can't be mined).
function Mining.ticks(block: number, onGround: boolean?, underwater: boolean?, tool: number?): number
	local progress = Mining.progressPerTick(block, onGround, underwater, tool)
	if progress <= 0 then
		return math.huge
	end
	return math.ceil(1 / progress - 1e-9)
end

--[[
	Server check: may a player who started mining `block` `elapsed` seconds ago, holding `tool`
	now, break it? Uses the fastest possible speed (on the ground, dry), like Minecraft's server, and
	accepts a break once `needed` of the progress is done (default TOLERANCE; 1 for a delayed break
	finishing).
]]
function Mining.mayBreak(block: number, elapsed: number, needed: number?, tool: number?): boolean
	local progress = Mining.progressPerTick(block, true, false, tool)
	if progress <= 0 then
		return false
	end
	local ticks = math.floor(elapsed * Mining.TICK_RATE + 1e-6)
	-- (1e-9: progress sums like 45 x 1/45 come out a hair under 1.)
	return progress * (ticks + 1) >= (needed or Mining.TOLERANCE) - 1e-9
end

--[[
	Wear a tool takes from a survival player breaking a block (creative players' tools never wear:
	the callers' business). Minecraft: 1 for tools, 2 for swords, nothing for blocks that break at
	once or for anything else held; Shears 1 for every block, instant ones too (ShearsItem.mineBlock
	wears them on everything but fire).
]]
function Mining.wear(block: number, tool: number?): number
	local data = Items.tool(tool)
	local def = Blocks.get(block)
	if data == nil or def == nil then
		return 0
	elseif data.kind == "shears" then
		return 1
	elseif def.hardness == 0 then
		return 0
	end
	return if data.kind == "sword" then 2 else 1
end

return Mining

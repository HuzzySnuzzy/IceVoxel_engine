--!strict
--[[
	Flowing fluids, modelled after Minecraft.

	Levels (see Blocks.fluidId): 0 = source, 1..7 = flowing (weaker as the number grows),
	8 = falling (fed from above).

	On every update a non-source block recomputes its level from its neighbours:
	  * fluid above            -> falling (8)
	  * otherwise              -> strongest horizontal neighbour + 1 (falling and sources count as 0)
	  * two or more horizontal sources on solid ground -> becomes a source (infinite water)
	  * nothing feeds it       -> disappears
	Then it spreads: straight down if possible, otherwise sideways with level + 1 (up to 7).

	Works for any fluid group registered in BlockList, so lava etc. only need new block entries.

	Block updates never generate chunks. A fluid next to a chunk that is not loaded waits and
	retries later instead of guessing what is there.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)

local FALLING = 8
local MAX_FLOW = 7
local RETRY_TICKS = 40
local SIDES = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local Fluid = {}

-- Ticks between updates come from the block's `fluid.tickDelay`.
function Fluid.onNeighborChanged(_world: any, ticker: any, x: number, y: number, z: number, block: number)
	local fluid = Blocks.get(block).fluid
	ticker:schedule(x, y, z, if fluid then fluid.tickDelay else 5)
end

local function levelOf(block: number?, group: string): number?
	if block == nil then
		return nil
	end
	local fluid = Blocks.get(block).fluid
	if fluid and fluid.group == group then
		return fluid.level
	end
	return nil
end

-- Can fluid of `group` flow into `block` with `level`?
local function canFlowInto(block: number, group: string, level: number): boolean
	local existing = levelOf(block, group)
	if existing ~= nil then
		if existing == 0 or existing == FALLING then
			return false
		end
		-- Strengthen weaker flowing fluid, or turn it into falling fluid.
		return level == FALLING or existing > level
	end
	return Blocks.isReplaceable(block) and Blocks.get(block).fluid == nil
end

local function expectedLevel(world: any, x: number, y: number, z: number, group: string): number?
	if levelOf(world:peekBlock(x, y + 1, z), group) ~= nil then
		return FALLING
	end

	local best: number? = nil
	local sources = 0
	for _, side in SIDES do
		local level = levelOf(world:peekBlock(x + side[1], y, z + side[2]), group)
		if level ~= nil then
			if level == 0 then
				sources += 1
			end
			local candidate = (if level == FALLING then 0 else level) + 1
			if best == nil or candidate < best then
				best = candidate
			end
		end
	end

	if sources >= 2 then
		local below = world:peekBlock(x, y - 1, z)
		if below ~= nil and (Blocks.isSolid(below) or levelOf(below, group) == 0) then
			return 0
		end
	end

	if best ~= nil and best <= MAX_FLOW then
		return best
	end
	return nil
end

function Fluid.onTick(world: any, ticker: any, x: number, y: number, z: number, block: number)
	local fluid = Blocks.get(block).fluid
	if fluid == nil then
		return
	end
	for _, side in SIDES do
		if world:peekBlock(x + side[1], y, z + side[2]) == nil then
			ticker:schedule(x, y, z, RETRY_TICKS)
			return
		end
	end
	local group = fluid.group
	local level = fluid.level

	if level ~= 0 then
		local expected = expectedLevel(world, x, y, z, group)
		if expected == nil then
			world:setBlock(x, y, z, Blocks.AIR)
			return
		elseif expected ~= level then
			world:setBlock(x, y, z, Blocks.fluidId(group, expected))
			level = expected
		end
	end

	local below = world:peekBlock(x, y - 1, z)
	if below == nil or y <= 0 then
		return
	end
	if canFlowInto(below, group, FALLING) then
		world:setBlock(x, y - 1, z, Blocks.fluidId(group, FALLING))
		return
	end
	-- Flowing fluid resting on the same fluid does not spread sideways (it would just pile up).
	if level ~= 0 and levelOf(below, group) ~= nil then
		return
	end

	local nextLevel = if level == 0 or level == FALLING then 1 else level + 1
	if nextLevel > MAX_FLOW then
		return
	end
	for _, side in SIDES do
		local sx, sz = x + side[1], z + side[2]
		local neighbour = world:peekBlock(sx, y, sz)
		if neighbour ~= nil and canFlowInto(neighbour, group, nextLevel) then
			world:setBlock(sx, y, sz, Blocks.fluidId(group, nextLevel))
		end
	end
end

return Fluid

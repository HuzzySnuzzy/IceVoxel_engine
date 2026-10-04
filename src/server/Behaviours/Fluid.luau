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
	Then it spreads (FlowingFluid.spread):
	  * straight down if possible (a source with three or more source neighbours also spreads
	    sideways meanwhile, so the edge of a lake over a hole keeps spreading),
	  * otherwise sideways with level + 1 (up to 7), but only towards the nearest way down: each
	    open side is scored by how many blocks it takes to reach a hole (open block with room
	    below), searching up to SLOPE_FIND_DISTANCE blocks, and only the sides with the lowest
	    score get fluid. With no hole in reach, every open side gets fluid. That is what makes
	    Minecraft water run down a slope instead of flooding the plateau above it.

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
-- How far (blocks) sideways spreading looks for a way down, per fluid group (Minecraft: water 4,
-- lava 2 in the overworld).
local SLOPE_FIND_DISTANCE: { [string]: number } = { Water = 4 }
local NO_HOLE = 1000

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

-- Can fluid spread sideways into (x, y, z)? Open blocks and weaker fluid of the group, not sources
-- (FlowingFluid.canPassThrough). Unloaded blocks are not.
local function passable(world: any, x: number, y: number, z: number, group: string): boolean
	local block = world:peekBlock(x, y, z)
	if block == nil then
		return false
	end
	local level = levelOf(block, group)
	if level ~= nil then
		return level ~= 0
	end
	return Blocks.isReplaceable(block) and Blocks.get(block).fluid == nil
end

-- Is there a way down below (x, y, z): the same fluid or an open block (FlowingFluid.isWaterHole)?
local function isHole(world: any, x: number, y: number, z: number, group: string): boolean
	local below = world:peekBlock(x, y - 1, z)
	if below == nil then
		return false
	end
	if levelOf(below, group) ~= nil then
		return true
	end
	return Blocks.isReplaceable(below) and Blocks.get(below).fluid == nil
end

--[[
	Blocks from (x, y, z) to the nearest hole, not going back the way it came (FlowingFluid.
	getSlopeDistance); NO_HOLE if there is none within `limit`.
]]
local function slopeDistance(
	world: any,
	x: number,
	y: number,
	z: number,
	depth: number,
	fromX: number,
	fromZ: number,
	group: string,
	limit: number
): number
	local best = NO_HOLE
	for _, side in SIDES do
		if side[1] ~= fromX or side[2] ~= fromZ then
			local nx, nz = x + side[1], z + side[2]
			if passable(world, nx, y, nz, group) then
				if isHole(world, nx, y, nz, group) then
					return depth
				end
				if depth < limit then
					local d = slopeDistance(world, nx, y, nz, depth + 1, -side[1], -side[2], group, limit)
					if d < best then
						best = d
					end
				end
			end
		end
	end
	return best
end

-- The sides fluid at (x, y, z) spreads to: those closest to a way down (FlowingFluid.getSpread).
local function spreadSides(world: any, x: number, y: number, z: number, group: string): { { number } }
	local limit = SLOPE_FIND_DISTANCE[group] or 4
	local best = NO_HOLE
	local sides: { { number } } = {}
	for _, side in SIDES do
		local nx, nz = x + side[1], z + side[2]
		if passable(world, nx, y, nz, group) then
			local d = if isHole(world, nx, y, nz, group)
				then 0
				else slopeDistance(world, nx, y, nz, 1, -side[1], -side[2], group, limit)
			if d < best then
				table.clear(sides)
				best = d
			end
			if d <= best then
				table.insert(sides, side)
			end
		end
	end
	return sides
end

local function spreadToSides(world: any, x: number, y: number, z: number, group: string, level: number)
	local nextLevel = if level == 0 or level == FALLING then 1 else level + 1
	if nextLevel > MAX_FLOW then
		return
	end
	for _, side in spreadSides(world, x, y, z, group) do
		local sx, sz = x + side[1], z + side[2]
		local neighbour = world:peekBlock(sx, y, sz)
		if neighbour ~= nil and canFlowInto(neighbour, group, nextLevel) then
			world:setBlock(sx, y, sz, Blocks.fluidId(group, nextLevel))
		end
	end
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
		-- The edge of a pool of sources keeps spreading while it pours down.
		if level == 0 then
			local sources = 0
			for _, side in SIDES do
				if levelOf(world:peekBlock(x + side[1], y, z + side[2]), group) == 0 then
					sources += 1
				end
			end
			if sources >= 3 then
				spreadToSides(world, x, y, z, group, level)
			end
		end
		return
	end
	-- Flowing fluid resting on the same fluid does not spread sideways (it would just pile up).
	if level ~= 0 and levelOf(below, group) ~= nil then
		return
	end
	spreadToSides(world, x, y, z, group, level)
end

return Fluid

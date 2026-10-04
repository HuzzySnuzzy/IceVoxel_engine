--!strict
--[[
	Flowing fluids, modelled after Minecraft.

	Levels (see Blocks.fluidId): 0 = source, 1..7 = flowing (weaker as the number grows),
	8 = falling (fed from above).

	On every update a non-source block recomputes its level from its neighbours
	(FlowingFluid.getNewLiquid, in its order):
	  * two or more horizontal sources on solid ground or a source -> becomes a source (infinite
	    water; fluids whose RULES say so)
	  * fluid above            -> falling (8)
	  * otherwise              -> strongest horizontal neighbour + dropOff (falling and sources
	                              count as 0)
	  * nothing feeds it       -> disappears
	Then it spreads (FlowingFluid.spread):
	  * straight down if possible (a source with three or more source neighbours also spreads
	    sideways meanwhile, so the edge of a lake over a hole keeps spreading),
	  * otherwise sideways (level + dropOff, up to 7), but only towards the nearest way down: each
	    open side is scored by how many blocks it takes to reach a hole (an open block with room
	    below), following open blocks up to the fluid's slope distance (water 4, so holes up to 5
	    blocks away count), and only the sides with the lowest score get fluid. With no hole in
	    reach, every open side gets fluid. That is what makes Minecraft water run down a slope
	    instead of flooding the plateau above it. Block lookups are cached during one search, as
	    Minecraft does.

	Any fluid group registered in BlockList works; its rules (slope distance, drop off, infinite
	sources) come from RULES (Minecraft's lava: 2, 2, no).

	Block updates never generate chunks. A fluid whose neighbours or whose slope search reach a
	chunk that is not loaded waits and retries later instead of guessing what is there.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)

local FALLING = 8
local MAX_FLOW = 7
local RETRY_TICKS = 40
local SIDES = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
-- Per fluid group: how far sideways spreading looks for a way down, how much weaker each step
-- sideways gets and whether two sources make a third (Minecraft: water 4 / 1 / yes, lava in the
-- overworld 2 / 2 / no).
type Rules = { slopeDistance: number, dropOff: number, infinite: boolean }
local RULES: { [string]: Rules } = {
	Water = { slopeDistance = 4, dropOff = 1, infinite = true },
}
local DEFAULT_RULES: Rules = { slopeDistance = 4, dropOff = 1, infinite = false }
local NO_HOLE = 1000
-- A slope search reached an unloaded block.
local UNKNOWN = -1

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

local function rulesOf(group: string): Rules
	return RULES[group] or DEFAULT_RULES
end

local function expectedLevel(world: any, x: number, y: number, z: number, group: string): number?
	local rules = rulesOf(group)
	local best: number? = nil
	local sources = 0
	for _, side in SIDES do
		local level = levelOf(world:peekBlock(x + side[1], y, z + side[2]), group)
		if level ~= nil then
			if level == 0 then
				sources += 1
			end
			local candidate = (if level == FALLING then 0 else level) + rules.dropOff
			if best == nil or candidate < best then
				best = candidate
			end
		end
	end

	if rules.infinite and sources >= 2 then
		local below = world:peekBlock(x, y - 1, z)
		if below ~= nil and (Blocks.isSolid(below) or levelOf(below, group) == 0) then
			return 0
		end
	end

	if levelOf(world:peekBlock(x, y + 1, z), group) ~= nil then
		return FALLING
	end

	if best ~= nil and best <= MAX_FLOW then
		return best
	end
	return nil
end

--[[
	The slope search (FlowingFluid.getSpread / getSlopeDistance): for every open side, the fewest
	blocks along open blocks to a hole, up to the fluid's slope distance. Minecraft walks every path
	recursively (with cached block reads); a breadth-first search over the same blocks finds the
	same shortest distance and looks at each block once. What each block around the fluid is gets
	read once per search into flat arrays, stamped so nothing needs clearing between searches.
]]
-- Largest slope distance supported, plus one.
local REACH = 8
local SPAN = 2 * REACH + 1
local CELL_BLOCKED, CELL_OPEN, CELL_HOLE, CELL_UNKNOWN = 1, 2, 3, 4
local readStamp = table.create(SPAN * SPAN, 0)
local cells = table.create(SPAN * SPAN, 0)
local visitStamp = table.create(SPAN * SPAN, 0)
local queueX = table.create(SPAN * SPAN, 0)
local queueZ = table.create(SPAN * SPAN, 0)
local queueDepth = table.create(SPAN * SPAN, 0)
local searchStamp = 0
local visitCount = 0

local function cellIndex(dx: number, dz: number): number
	return (dx + REACH) * SPAN + dz + REACH + 1
end

--[[
	What block (x0 + dx, y, z0 + dz) is to fluid of `group` spreading sideways: blocked, open
	(FlowingFluid.canPassThrough: open blocks and weaker fluid of the group, not sources), a hole (open
	with the same fluid or an open block below: isWaterHole) or unknown (not loaded).
]]
local function cellAt(world: any, x0: number, y: number, z0: number, dx: number, dz: number, group: string): number
	local i = cellIndex(dx, dz)
	if readStamp[i] == searchStamp then
		return cells[i]
	end
	readStamp[i] = searchStamp
	local x, z = x0 + dx, z0 + dz
	local cell = CELL_BLOCKED
	local block = world:peekBlock(x, y, z)
	if block == nil then
		cell = CELL_UNKNOWN
	else
		local level = levelOf(block, group)
		local open = if level ~= nil then level ~= 0 else Blocks.isReplaceable(block) and Blocks.get(block).fluid == nil
		if open then
			local below = world:peekBlock(x, y - 1, z)
			if below == nil then
				cell = CELL_UNKNOWN
			elseif levelOf(below, group) ~= nil or (Blocks.isReplaceable(below) and Blocks.get(below).fluid == nil) then
				cell = CELL_HOLE
			else
				cell = CELL_OPEN
			end
		end
	end
	cells[i] = cell
	return cell
end

--[[
	Blocks from the open side (sx, sz) (an offset from the fluid at x0, z0) to the nearest hole,
	never through the fluid's own block; NO_HOLE if there is none within `limit`, UNKNOWN if the
	search reached an unloaded block.
]]
local function slopeDistance(
	world: any,
	x0: number,
	y: number,
	z0: number,
	group: string,
	limit: number,
	sx: number,
	sz: number
): number
	visitCount += 1
	visitStamp[cellIndex(0, 0)] = visitCount
	visitStamp[cellIndex(sx, sz)] = visitCount
	queueX[1], queueZ[1], queueDepth[1] = sx, sz, 1
	local head, tail = 1, 1
	while head <= tail do
		local dx, dz, depth = queueX[head], queueZ[head], queueDepth[head]
		head += 1
		for _, side in SIDES do
			local nx, nz = dx + side[1], dz + side[2]
			local i = cellIndex(nx, nz)
			if visitStamp[i] ~= visitCount then
				visitStamp[i] = visitCount
				local cell = cellAt(world, x0, y, z0, nx, nz, group)
				if cell == CELL_UNKNOWN then
					return UNKNOWN
				elseif cell == CELL_HOLE then
					return depth
				elseif cell == CELL_OPEN and depth < limit then
					tail += 1
					queueX[tail], queueZ[tail], queueDepth[tail] = nx, nz, depth + 1
				end
			end
		end
	end
	return NO_HOLE
end

--[[
	The sides fluid at (x, y, z) spreads to: those closest to a way down (FlowingFluid.getSpread).
	UNKNOWN if the search reached an unloaded block (the answer could be wrong, so wait).
]]
local function spreadSides(world: any, x: number, y: number, z: number, group: string): { { number } } | number
	local limit = math.min(rulesOf(group).slopeDistance, REACH - 1)
	searchStamp += 1
	local best = NO_HOLE
	local sides: { { number } } = {}
	for _, side in SIDES do
		local cell = cellAt(world, x, y, z, side[1], side[2], group)
		if cell == CELL_UNKNOWN then
			return UNKNOWN
		end
		if cell ~= CELL_BLOCKED then
			local d = if cell == CELL_HOLE then 0 else slopeDistance(world, x, y, z, group, limit, side[1], side[2])
			if d == UNKNOWN then
				return UNKNOWN
			end
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

-- Spreads sideways; false if that has to wait for unloaded chunks.
local function spreadToSides(world: any, x: number, y: number, z: number, group: string, level: number): boolean
	-- Falling fluid and sources spread like full ones (FlowingFluid.getSpread: amount - drop off).
	local nextLevel = (if level == FALLING then 0 else level) + rulesOf(group).dropOff
	if nextLevel > MAX_FLOW then
		return true
	end
	local sides = spreadSides(world, x, y, z, group)
	if type(sides) == "number" then
		return false
	end
	for _, side in sides do
		local sx, sz = x + side[1], z + side[2]
		local neighbour = world:peekBlock(sx, y, sz)
		if neighbour ~= nil and canFlowInto(neighbour, group, nextLevel) then
			world:setBlock(sx, y, sz, Blocks.fluidId(group, nextLevel))
		end
	end
	return true
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
			if sources >= 3 and not spreadToSides(world, x, y, z, group, level) then
				ticker:schedule(x, y, z, RETRY_TICKS)
			end
		end
		return
	end
	-- Flowing fluid resting on the same fluid does not spread sideways (it would just pile up).
	if level ~= 0 and levelOf(below, group) ~= nil then
		return
	end
	if not spreadToSides(world, x, y, z, group, level) then
		ticker:schedule(x, y, z, RETRY_TICKS)
	end
end

return Fluid

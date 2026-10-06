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

	Every fluid group of BlockList (Shared/Fluids: water, lava, oil, fuel) has its RULES: slope
	distance, drop off, infinite sources, and whether what it washes away burns (the tick delay is
	BlockList's):
	  Water  4, 1, yes, tick 5    Minecraft's WaterFluid
	  Lava   2, 2, no,  tick 30   Minecraft 1.20.1's LavaFluid in the overworld: flows 3 blocks
	  Oil    2, 1, no,  tick 20   BuildCraft-like: viscous, slow, flows 7 but looks only 2 for a hole
	  Fuel   4, 1, no,  tick 5    thin like water, but no infinite sources
	Different fluids never flow into each other; only lava and water meet (below).

	Cave twins of sources (CaveLava, CaveOil: generated underground) are sources of their group
	here in every way; what flows out of them is ordinary fluid (Blocks.fluidId).

	Lava meets water as in Minecraft (LiquidBlock.shouldSpreadLiquid, LavaFluid.spreadTo), each with
	the fizz (LiquidBlock.fizz: block.lava.extinguish, when Shared/Sounds has it):
	  * lava with water above it or beside it (not below) hardens: a source (its cave twin too)
	    into obsidian, flowing or falling lava into cobblestone. Minecraft does it when the water
	    arrives (neighborChanged, onPlace); here the lava's next tick, one tick later;
	  * lava pouring down into water (any level) turns that water into stone.
	Lava burns what it washes away (torches, plants): no drop, a fizz (LavaFluid.beforeDestroying-
	Block); water, oil and fuel drop it.

	Block updates never generate chunks. A fluid whose neighbours or whose slope search reach a
	chunk that is not loaded waits and retries later instead of guessing what is there.

	Fluids flow into replaceable blocks (air; not the structure void) and wash away blocks marked
	`brokenByFluid` (torches, glow lichen), which drop what they drop by themselves
	(Behaviours/Drops: a torch its item, glow lichen nothing), like Minecraft's canHoldFluid /
	beforeDestroyingBlock.

	Fuel touching Fire or lava (World/FuelBlast.isHot) catches: whenever the fuel or one of its
	neighbours changes (fire or lava arriving next to it, the fuel flowing next to them), the
	fuel's cell is handed to World/Explosions, which blows up the whole connected body.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local SharedSounds = require(Shared.Sounds)

local Sounds = require(script.Parent.Parent.Audio.Sounds)
local Drops = require(script.Parent.Drops)
local Explosions = require(script.Parent.Parent.World.Explosions)
local FuelBlast = require(script.Parent.Parent.World.FuelBlast)

local FALLING = 8
local MAX_FLOW = 7
local RETRY_TICKS = 40
local SIDES = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
-- Per fluid group: how far sideways spreading looks for a way down, how much weaker each step
-- sideways gets, whether two sources make a third and whether what it washes away burns
-- (Minecraft: water 4 / 1 / yes, lava in the overworld 2 / 2 / no; see the header).
type Rules = { slopeDistance: number, dropOff: number, infinite: boolean, burns: boolean }
local RULES: { [string]: Rules } = {
	Water = { slopeDistance = 4, dropOff = 1, infinite = true, burns = false },
	Lava = { slopeDistance = 2, dropOff = 2, infinite = false, burns = true },
	Oil = { slopeDistance = 2, dropOff = 1, infinite = false, burns = false },
	Fuel = { slopeDistance = 4, dropOff = 1, infinite = false, burns = false },
}
-- (Every fluid needs its rules: a new group without them fails here, not quietly flows like water.)
for _, def in Blocks.defs do
	assert(def.fluid == nil or RULES[def.fluid.group], `No flow rules for fluid {def.fluid and def.fluid.group}`)
end
local NO_HOLE = 1000
-- A slope search reached an unloaded block.
local UNKNOWN = -1

local LAVA, WATER, FUEL = "Lava", "Water", "Fuel"
-- Where fuel catches from: its six sides.
local TOUCHING = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
local OBSIDIAN, COBBLESTONE, STONE = Blocks.id.Obsidian, Blocks.id.Cobblestone, Blocks.id.Stone
-- Where water hardens lava from: above and the four sides (LiquidBlock.POSSIBLE_FLOW_DIRECTIONS'
-- opposites; water below is poured into instead).
local QUENCH = { { 0, 1, 0 }, { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
-- Minecraft's LiquidBlock.fizz (level event 1501): nil until Shared/Sounds has the event.
local FIZZ = SharedSounds.find("block.lava.extinguish")

local Fluid = {}

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

local function fizz(x: number, y: number, z: number)
	Sounds.play(FIZZ, x + 0.5, y + 0.5, z + 0.5)
end

-- Is there water above or beside the lava at (x, y, z)?
local function quenched(world: any, x: number, y: number, z: number): boolean
	for _, d in QUENCH do
		if levelOf(world:peekBlock(x + d[1], y + d[2], z + d[3]), WATER) ~= nil then
			return true
		end
	end
	return false
end

--[[
	Ticks between updates come from the block's `fluid.tickDelay`; lava that water touches hardens
	on the next tick instead (Minecraft hardens it the moment the water arrives, long before the
	water's own next tick). Fuel touching fire or lava catches (World/Explosions.ignite).
]]
function Fluid.onNeighborChanged(world: any, ticker: any, x: number, y: number, z: number, block: number)
	local fluid = Blocks.get(block).fluid
	if fluid and fluid.group == FUEL then
		for _, side in TOUCHING do
			if FuelBlast.isHot(world:peekBlock(x + side[1], y + side[2], z + side[3])) then
				Explosions.ignite(world, x, y, z)
				break
			end
		end
	end
	if fluid and fluid.group == LAVA and quenched(world, x, y, z) then
		ticker:schedule(x, y, z, 1)
		return
	end
	ticker:schedule(x, y, z, if fluid then fluid.tickDelay else 5)
end

-- The structure void holds no fluid (Minecraft's FlowingFluid.canHoldFluid), though it is
-- replaceable: water never flows into the cells a structure's builder marked "keep".
local STRUCTURE_VOID = Blocks.find("StructureVoid")

-- Does `block` make way for any fluid: air and other replaceable non-fluids (not the structure
-- void), and blocks the flow washes away (torches)?
local function yields(block: number): boolean
	local def = Blocks.get(block)
	return def.fluid == nil and (def.replaceable or def.brokenByFluid) and block ~= STRUCTURE_VOID
end

-- Puts `fluid` at (x, y, z), where `old` was; a washed away block drops its item, or burns with a
-- fizz in lava.
local function flowInto(world: any, x: number, y: number, z: number, old: number, fluid: number)
	if world:setBlock(x, y, z, fluid) and Blocks.get(old).brokenByFluid then
		local def = Blocks.get(fluid).fluid
		if def and RULES[def.group].burns then
			fizz(x, y, z)
		else
			Drops.block(x, y, z, old)
		end
	end
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
	return yields(block)
end

local function rulesOf(group: string): Rules
	return RULES[group]
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
		local open = if level ~= nil then level ~= 0 else yields(block)
		if open then
			local below = world:peekBlock(x, y - 1, z)
			if below == nil then
				cell = CELL_UNKNOWN
			elseif levelOf(below, group) ~= nil or yields(below) then
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
			flowInto(world, sx, y, sz, neighbour, Blocks.fluidId(group, nextLevel))
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

	-- Water above or beside lava hardens it: a source into obsidian, the rest into cobblestone.
	if group == LAVA and quenched(world, x, y, z) then
		world:setBlock(x, y, z, if level == 0 then OBSIDIAN else COBBLESTONE)
		fizz(x, y, z)
		return
	end

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
	local pours = canFlowInto(below, group, FALLING)
	if pours or (group == LAVA and levelOf(below, WATER) ~= nil) then
		if pours then
			flowInto(world, x, y - 1, z, below, Blocks.fluidId(group, FALLING))
		else
			-- Lava pouring into water turns the water into stone (LavaFluid.spreadTo, down).
			world:setBlock(x, y - 1, z, STONE)
			fizz(x, y - 1, z)
		end
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

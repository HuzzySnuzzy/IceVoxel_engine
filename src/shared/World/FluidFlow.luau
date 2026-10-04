--!strict
--[[
	Which way fluid flows at a block (Minecraft's FlowingFluid.getFlow), used to push players.

	Heights are a fluid block's own height (amount / 9: sources and falling fluid 8/9, flowing
	level L (8 - L) / 9). For every side, the difference between this block's height and the
	neighbour's adds to the flow (towards lower fluid); an open side with fluid below it counts as
	a drop. Falling fluid next to a solid face also pushes down (Minecraft adds -6 on Y before
	normalising, so that is almost straight down). The result is a unit vector, or zero in still
	fluid such as an ocean of sources.
]]

local Blocks = require(script.Parent.Parent.Blocks)

local SIDES = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local FALLING = 8
local SOURCE_HEIGHT = 0.8888889
local ICE = Blocks.id.Ice

local FluidFlow = {}

-- Own height of `block` as fluid of `group` (FluidState.getOwnHeight), 0 for anything else.
local function ownHeight(block: number?, group: string): number
	local fluid = if block then Blocks.get(block).fluid else nil
	if fluid == nil or fluid.group ~= group then
		return 0
	end
	local amount = if fluid.level == 0 or fluid.level == FALLING then 8 else 8 - fluid.level
	return amount / 9
end

-- Does `block` let fluid of `group` affect the flow (no fluid or the same fluid)?
local function affectsFlow(block: number, group: string): boolean
	local fluid = Blocks.get(block).fluid
	return fluid == nil or fluid.group == group
end

-- A solid face falling fluid runs down along (FlowingFluid.isSolidFace; ice is not one).
local function solidFace(block: number?, group: string): boolean
	if block == nil or ownHeight(block, group) > 0 then
		return false
	end
	return Blocks.isSolid(block) and block ~= ICE
end

--[[
	Flow at block (x, y, z) as a unit vector (or zero). `getBlock` returns nil for unknown blocks,
	which are ignored.
]]
function FluidFlow.at(
	getBlock: (number, number, number) -> number?,
	x: number,
	y: number,
	z: number
): (number, number, number)
	local block = getBlock(x, y, z)
	if block == nil then
		return 0, 0, 0
	end
	local fluid = Blocks.get(block).fluid
	if fluid == nil then
		return 0, 0, 0
	end
	local group = fluid.group
	local own = ownHeight(block, group)

	local fx, fz = 0, 0
	for _, side in SIDES do
		local nx, nz = x + side[1], z + side[2]
		local neighbour = getBlock(nx, y, nz)
		if neighbour ~= nil and affectsFlow(neighbour, group) then
			local height = ownHeight(neighbour, group)
			local diff = 0
			if height == 0 then
				if not Blocks.isSolid(neighbour) then
					-- An open side over fluid is a drop.
					local below = getBlock(nx, y - 1, nz)
					if below ~= nil and affectsFlow(below, group) then
						local belowHeight = ownHeight(below, group)
						if belowHeight > 0 then
							diff = own - (belowHeight - SOURCE_HEIGHT)
						end
					end
				end
			else
				diff = own - height
			end
			fx += side[1] * diff
			fz += side[2] * diff
		end
	end

	local length = math.sqrt(fx * fx + fz * fz)
	if length > 0 then
		fx, fz = fx / length, fz / length
	end
	if fluid.level == FALLING then
		for _, side in SIDES do
			local nx, nz = x + side[1], z + side[2]
			if solidFace(getBlock(nx, y, nz), group) or solidFace(getBlock(nx, y + 1, nz), group) then
				local total = math.sqrt(fx * fx + 36 + fz * fz)
				return fx / total, -6 / total, fz / total
			end
		end
	end
	return fx, 0, fz
end

return FluidFlow

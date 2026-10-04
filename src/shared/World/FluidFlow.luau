--!strict
--[[
	Which way fluid flows at a block, used to push characters (and anything else) around.

	Same idea as Minecraft: compare the amount of fluid in a block with its horizontal neighbours and
	flow towards less fluid, and strongly towards drops (air with fluid below it). Still water such
	as an ocean of source blocks does not flow. Falling fluid pushes downwards.

	Amounts: sources and falling fluid 8, flowing level L 8 - L, anything else 0.
]]

local Blocks = require(script.Parent.Parent.Blocks)

local SIDES = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local FALLING = 8

local FluidFlow = {}

local function amount(block: number?, group: string): number
	if block == nil then
		return 0
	end
	local fluid = Blocks.get(block).fluid
	if fluid == nil or fluid.group ~= group then
		return 0
	end
	return if fluid.level == 0 or fluid.level == FALLING then 8 else 8 - fluid.level
end

--[[
	Flow direction at block (x, y, z): a horizontal unit vector (or zero) plus -1 on Y for falling
	fluid. `getBlock` returns nil for unknown blocks, which are ignored.
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
	local own = amount(block, group)
	local fx, fz = 0, 0
	for _, side in SIDES do
		local nx, nz = x + side[1], z + side[2]
		local neighbour = getBlock(nx, y, nz)
		if neighbour ~= nil then
			local other = amount(neighbour, group)
			if other > 0 then
				fx += side[1] * (own - other)
				fz += side[2] * (own - other)
			elseif Blocks.isReplaceable(neighbour) then
				-- An open side above more fluid is a drop: flow there hard.
				local below = amount(getBlock(nx, y - 1, nz), group)
				if below > 0 then
					fx += side[1] * (own - below + 8)
					fz += side[2] * (own - below + 8)
				end
			end
		end
	end

	local length = math.sqrt(fx * fx + fz * fz)
	if length > 0 then
		fx, fz = fx / length, fz / length
	end
	return fx, if fluid.level == FALLING then -1 else 0, fz
end

return FluidFlow

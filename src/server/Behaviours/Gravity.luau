--!strict
--[[
	Falling blocks (sand, gravel): move down one block per update while there is air or fluid below.

	Like Minecraft's falling block entity, a falling block passes through blocks without a collision
	box (torches) and lands on those with one (Blocks.obstruction). Where it lands in a cell it
	can't replace (a torch's, or a lantern's, whose box ends inside its cell) it breaks and drops as
	an item, and the torch stays: the torch trick for clearing sand and gravel. A block that rests
	on a torch without falling (placed there) stays, as Minecraft's FallingBlock only falls into
	free cells. Drops go through Behaviours/Drops.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)

local Drops = require(script.Parent.Drops)

local Gravity = {}

Gravity.tickDelay = 2

function Gravity.onTick(world: any, _ticker: any, x: number, y: number, z: number, block: number)
	if y <= 0 then
		return
	end
	local below = world:peekBlock(x, y - 1, z)
	if below == nil or not Blocks.isReplaceable(below) then
		return
	end
	-- Under the cell it falls into: torches it would fall through, and what comes after them.
	local at = y - 2
	local under = world:peekBlock(x, at, z)
	local passed = false
	while under ~= nil and not Blocks.isReplaceable(under) and Blocks.obstruction(under) == nil do
		passed = true
		at -= 1
		under = world:peekBlock(x, at, z)
	end
	world:setBlock(x, y, z, Blocks.AIR)
	if under ~= nil and not Blocks.isSolid(under) and Blocks.obstruction(under) ~= nil then
		-- On top of a lantern.
		Drops.block(x, at, z, block)
	elseif passed and (under == nil or Blocks.isSolid(under)) then
		-- Into the lowest torch's cell.
		Drops.block(x, at + 1, z, block)
	else
		-- Landing in the new spot (past any torches, into the open) notifies it again, so the block
		-- keeps falling next tick.
		world:setBlock(x, if passed then at else y - 1, z, block)
	end
end

return Gravity

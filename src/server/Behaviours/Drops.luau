--!strict
--[[
	How block behaviours drop items into the world (a torch popping off, a plant losing its soil,
	water washing either away, a bucket's water poured over a dead bush: Transmitters/UseRules).

	Behaviours run inside the block ticker and know nothing about item entities, so the server
	plugs the spawner in: Network/ServerNet passes the `dropBlock` rule it is given (Entities.dropBlock)
	to `set`. Until then (and in tests that don't set one) drops are simply lost.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Items = require(Shared.Items)

export type Spawner = (x: number, y: number, z: number, stack: Items.Stack) -> ()

local Drops = {}

local spawner: Spawner? = nil

-- Sets (or clears) the function that spawns a dropped stack at block (x, y, z).
function Drops.set(fn: Spawner?)
	spawner = fn
end

-- Drops what `block` gives when it breaks by itself (Items.blockDrops) at block (x, y, z).
function Drops.block(x: number, y: number, z: number, block: number)
	local stack = Items.blockDrops(block)
	local spawn = spawner
	if stack and spawn then
		spawn(x, y, z, stack)
	end
end

return Drops

--!strict
--[[
	Block behaviours: what a block does when it or a neighbour changes.

	Blocks opt in with `behaviour = "Name"` in BlockList; this module loads the child module of that
	name. A behaviour module returns a table with any of:

	  tickDelay           ticks to wait before reacting to a neighbour change (default 1)
	  onNeighborChanged   (world, ticker, x, y, z, block) -> ()   override the default scheduling
	  onTick              (world, ticker, x, y, z, block) -> ()   the actual update

	See Grass.luau for the smallest example.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)

local BlockTicker = require(script.Parent.World.BlockTicker)

local Behaviours = {}

local byId: { [number]: BlockTicker.Behaviour } = {}
for id, def in Blocks.defs do
	if def.behaviour then
		local module = script:FindFirstChild(def.behaviour)
		assert(module and module:IsA("ModuleScript"), `Block {def.name} uses unknown behaviour {def.behaviour}`)
		byId[id] = require(module) :: any
	end
end

Behaviours.byId = byId

return Behaviours

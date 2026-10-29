--!strict
--[[
	Block behaviours: what a block does when it or a neighbour changes.

	Blocks opt in with `behaviour = "Name"` in BlockList; this module loads the child module of that
	name. A behaviour module returns a table with any of:

	  tickDelay           ticks to wait before reacting to a neighbour change (default 1)
	  onNeighborChanged   (world, ticker, x, y, z, block) -> ()   override the default scheduling
	  onTick              (world, ticker, x, y, z, block) -> ()   the actual update

	See Grass.luau for the smallest example.

	The names blocks may give are Content/Schema's BEHAVIOURS (the packs are checked against them
	as they load, where the server's modules can't be seen), so this module checks the list as it
	loads: every name in it is a behaviour here, and every module here with `onTick` or
	`onNeighborChanged` is in it (Drops, the behaviours' helper, has neither). A new behaviour is a
	module here and its name in that list.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Schema = require(Shared.Content.Schema)

local BlockTicker = require(script.Parent.World.BlockTicker)

local Behaviours = {}

do
	local listed: { [string]: boolean } = {}
	for _, name in Schema.BEHAVIOURS do
		listed[name] = true
		local module = script:FindFirstChild(name)
		assert(
			module and module:IsA("ModuleScript"),
			`Behaviours: Content/Schema's BEHAVIOURS lists {name}, but there is no module of that name here`
		)
	end
	for _, module in script:GetChildren() do
		if module:IsA("ModuleScript") then
			local behaviour = require(module) :: any
			local behaves = type(behaviour) == "table"
				and (behaviour.onTick ~= nil or behaviour.onNeighborChanged ~= nil)
			assert(
				behaves == (listed[module.Name] == true),
				if behaves
					then `Behaviours: {module.Name} is a behaviour, which Content/Schema's BEHAVIOURS must list (so a pack may name it)`
					else `Behaviours: Content/Schema's BEHAVIOURS lists {module.Name}, which has no onTick or onNeighborChanged`
			)
		end
	end
end

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

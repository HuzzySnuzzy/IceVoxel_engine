--!strict
--[[
	Entry point for your own server scripts.

	    local IceVoxel = require(game.ServerScriptService.IceVoxel.Api)
	    local world = IceVoxel.waitForWorld()
	    world:setBlock(x, y, z, Blocks.id.Stone)   -- replicated to every client automatically
	    print(world:getBlock(x, y, z))
	    IceVoxel.explode(x + 0.5, y + 0.5, z + 0.5, 4)   -- a TNT-sized blast (World/Explosions)
]]

local WorldServer = require(script.Parent.World.WorldServer)
local BlockTicker = require(script.Parent.World.BlockTicker)
local Explosions = require(script.Parent.World.Explosions)

local Api = {}

Api.world = nil :: WorldServer.World?
Api.ticker = nil :: BlockTicker.Ticker?

local waiting: { thread } = {}

-- Yields until the server finished booting, then returns the world.
function Api.waitForWorld(): WorldServer.World
	if Api.world == nil then
		table.insert(waiting, coroutine.running())
		coroutine.yield()
	end
	return Api.world :: WorldServer.World
end

--[[
	Sets off an explosion of `power` (Minecraft's: TNT 4) at (x, y, z) (blocks) on the next server
	tick: blocks, drops, items and players as World/Explosions does; `fiery` also sets fire.
]]
function Api.explode(x: number, y: number, z: number, power: number, fiery: boolean?)
	Explosions.explode(Api.waitForWorld(), x, y, z, power, fiery)
end

-- Called once by the server entry script.
function Api._ready(world: WorldServer.World, ticker: BlockTicker.Ticker)
	Api.world = world
	Api.ticker = ticker
	for _, thread in waiting do
		task.spawn(thread)
	end
	table.clear(waiting)
end

return Api

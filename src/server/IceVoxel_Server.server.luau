--!strict
--[[
	IceVoxel server: the authority over the world.

	The server never sends terrain. It picks the seed, keeps the list of edits per chunk, validates
	players' edit requests, runs block updates (falling sand, flowing water...) and replicates every
	change. Clients generate and render the terrain themselves from the seed.

	Boot order:
	  1. seed       -> published as an attribute on ReplicatedStorage.IceVoxel
	  2. world      -> generated chunk cache + edit lists (World/WorldServer)
	  3. ticker     -> scheduled block updates (World/BlockTicker, Behaviours/)
	  4. network    -> chunk edit requests, edit validation, replication (Network/ServerNet)
	  5. clock      -> the day time, published to the clients (World/TimeOfDay)
	  6. players    -> game modes (/gamemode), the time (/time, /gamerule doDaylightCycle), cosmetic
	                   characters (collision group, teleports, fall damage), item entities (drops),
	                   inventories, chests, furnaces and crafting tables, tools (mining speed, drops,
	                   wear), safe spawning, map teleports, waypoints, keeping chunks around players
	                   generated
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)

local Server = script.Parent
local Api = require(Server.Api)
local WorldServer = require(Server.World.WorldServer)
local BlockTicker = require(Server.World.BlockTicker)
local Simulation = require(Server.World.Simulation)
local TimeOfDay = require(Server.World.TimeOfDay)
local Behaviours = require(Server.Behaviours)
local ServerNet = require(Server.Network.ServerNet)
local Characters = require(Server.Players.Characters)
local GameModes = require(Server.Players.GameModes)
local TimeCommands = require(Server.Players.TimeCommands)
local Inventories = require(Server.Players.Inventories)
local Entities = require(Server.Entities.Entities)
local Spawning = require(Server.Players.Spawning)
local Teleport = require(Server.Players.Teleport)
local WaypointStore = require(Server.Players.WaypointStore)

local seed = Config.Seed or Random.new():NextInteger(1, 2_147_483_646)
Shared:SetAttribute("Seed", seed)
print(`[IceVoxel] world seed {seed}`)

local world = WorldServer.new(TerrainGenerator.new(seed))
local ticker = BlockTicker.new(world, Behaviours.byId, Config.Server.MaxUpdatesPerTick)
world.onChanged = function(x, y, z, old, new)
	ticker:blockChanged(x, y, z)
	-- A chest or furnace replaced by anything (breaking, the Api, block updates) drops what it
	-- holds, and any block with a window closes it for its users.
	Inventories.blockChanged(x, y, z, old, new)
end

local net = ServerNet.start(world)
TimeOfDay.start()
GameModes.start(net)
TimeCommands.start(net)
Characters.start(net)
-- Items must exist before anything can drop them.
Entities.start(net, world)
Inventories.start(net, world)
net.setRules({
	place = Inventories.place,
	acknowledge = Inventories.acknowledge,
	dropBlock = Entities.dropBlock,
	removeContainer = Inventories.removeContainer,
	mayRemoveContainer = Inventories.mayRemoveContainer,
	heldTool = Inventories.heldTool,
	wearTool = Inventories.wearTool,
})
Spawning.start(world)
Teleport.start(world, net)
WaypointStore.start(net)
Simulation.start(world)
Api._ready(world, ticker)

-- Fixed rate block updates, then one replication message per frame.
local tickLength = 1 / Config.Server.TickRate
local accumulator = 0
RunService.Heartbeat:Connect(function(dt)
	accumulator = math.min(accumulator + dt, tickLength * 4)
	while accumulator >= tickLength do
		accumulator -= tickLength
		ticker:step()
	end
	net.flush()
end)

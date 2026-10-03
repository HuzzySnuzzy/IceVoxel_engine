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
	  5. players    -> safe spawning, map teleports, waypoints, keeping chunks around players generated
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
local Behaviours = require(Server.Behaviours)
local ServerNet = require(Server.Network.ServerNet)
local Spawning = require(Server.Players.Spawning)
local Teleport = require(Server.Players.Teleport)
local WaypointStore = require(Server.Players.WaypointStore)

local seed = Config.Seed or Random.new():NextInteger(1, 2_147_483_646)
Shared:SetAttribute("Seed", seed)
print(`[IceVoxel] world seed {seed}`)

local world = WorldServer.new(TerrainGenerator.new(seed))
local ticker = BlockTicker.new(world, Behaviours.byId, Config.Server.MaxUpdatesPerTick)
world.onChanged = function(x, y, z)
	ticker:blockChanged(x, y, z)
end

local net = ServerNet.start(world)
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

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
	  4. network    -> chunk edit requests, edit validation, replication (Network/ServerNet), and
	                   the sounds players should hear (Audio/Sounds)
	  5. clock      -> the day time, published to the clients (World/TimeOfDay)
	  6. players    -> game modes (/gamemode, the F3 + F4 switcher and F3 + N), the time (/time,
	                   /gamerule doDaylightCycle), cosmetic characters (collision group, teleports,
	                   fall damage, invulnerability), item entities (drops), inventories, chests,
	                   furnaces and crafting tables, tools (mining speed, drops, wear), safe
	                   spawning, map and spectator teleports, waypoints, player settings (the
	                   Options menu's choices, Players/SettingsStore), keeping chunks around
	                   players generated
	  7. pipes      -> Mekanism's transmitters and fluid tanks (Transmitters/Transmitters: items in
	                   transporters, water in pipes, replication), and the Configurator and buckets
	                   (Players/ItemUse)
	  8. machines   -> Mekanism's machines and energy (Machines/Machines: machine ticks, energy
	                   networks through Universal Cables, energy kept in items, replication)
	  9. structures -> structure blocks and jigsaw blocks (Structures/StructureBlocks: their
	                   settings and replication, SAVE / LOAD / DETECT, a jigsaw's Generate, who may
	                   use them), and generated structures' chests filled on first use
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
local Sounds = require(Server.Audio.Sounds)
local Characters = require(Server.Players.Characters)
local GameModes = require(Server.Players.GameModes)
local TimeCommands = require(Server.Players.TimeCommands)
local Inventories = require(Server.Players.Inventories)
local Entities = require(Server.Entities.Entities)
local Spawning = require(Server.Players.Spawning)
local Teleport = require(Server.Players.Teleport)
local WaypointStore = require(Server.Players.WaypointStore)
local SettingsStore = require(Server.Players.SettingsStore)
local Transmitters = require(Server.Transmitters.Transmitters)
local Machines = require(Server.Machines.Machines)
local ItemUse = require(Server.Players.ItemUse)
local Containers = require(Server.Players.Containers)
local StructureBlocks = require(Server.Structures.StructureBlocks)

local seed = Config.Seed or Random.new():NextInteger(1, 2_147_483_646)
Shared:SetAttribute("Seed", seed)
print(`[IceVoxel] world seed {seed}`)

local world = WorldServer.new(TerrainGenerator.new(seed))
local ticker = BlockTicker.new(world, Behaviours.byId, Config.Server.MaxUpdatesPerTick)
world.onChanged = function(x, y, z, old, new)
	-- A generated structure's chest gets its contents before anything hears it change, so one
	-- broken or replaced unopened still drops them.
	Containers.materialize(x, y, z, old)
	ticker:blockChanged(x, y, z)
	-- A chest or furnace replaced by anything (breaking, the Api, block updates) drops what it
	-- holds, and any block with a window closes it for its users.
	Inventories.blockChanged(x, y, z, old, new)
	-- Transmitters and fluid tanks come and go (a transporter's items drop), and pipes notice the
	-- chests, furnaces, tanks and energy blocks around them.
	Transmitters.blockChanged(x, y, z, old, new)
	-- Machines come and go, and energy networks are worked out again around them.
	Machines.blockChanged(x, y, z, old, new)
	-- Structure blocks and jigsaws keep their settings while they stand.
	StructureBlocks.blockChanged(x, y, z, old, new)
end

local net = ServerNet.start(world)
Sounds.start(net)
TimeOfDay.start()
GameModes.start(net)
TimeCommands.start(net)
Characters.start(net, world)
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
	chunksSent = function(player: Player, coords: { { number } })
		Transmitters.sendChunks(player, coords)
		Machines.sendChunks(player, coords)
		StructureBlocks.sendChunks(player, coords)
	end,
	operator = StructureBlocks.operator,
})
-- Pipes after inventories and items (they fill chests and drop items); item use after the pipes;
-- machines after the pipes (their cables are the pipes' nodes).
Transmitters.start(net, world)
ItemUse.start(net, world)
Machines.start(net, world)
-- Structure blocks after inventories (containers, the Use hook).
StructureBlocks.start(net, world)
Spawning.start(world)
Teleport.start(world, net)
WaypointStore.start(net)
SettingsStore.start(net)
Simulation.start(world)
Api._ready(world, ticker)

-- Fixed rate block updates, then the frame's share of structures being placed, then one
-- replication message per frame, then the pipes, machines and structure blocks.
local tickLength = 1 / Config.Server.TickRate
local accumulator = 0
RunService.Heartbeat:Connect(function(dt)
	accumulator = math.min(accumulator + dt, tickLength * 4)
	while accumulator >= tickLength do
		accumulator -= tickLength
		ticker:step()
	end
	StructureBlocks.place()
	net.flush()
	-- The pipes after the edits: a client knows a transmitter's block before its state.
	Transmitters.update(dt)
	Machines.update(dt)
	StructureBlocks.update(dt)
end)

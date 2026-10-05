--!strict
--[[
	IceVoxel client: generates, meshes and renders the world locally.

	  World/ClientWorld          block data of nearby chunks, edit lists, edit prediction
	  Streaming/ChunkStreamer    which chunks (and LOD levels) exist, job scheduling
	  Streaming/WorkerPool       Actors running Streaming/ChunkWorker (parallel generation + meshing)
	  Rendering/ChunkRenderer    mesh boxes -> parts, within a per-frame budget
	  Rendering/ViewSettings     view distance per device, lighting quality and fog
	  Rendering/LightingController  day and night: the sun, sky light, cave darkness, fog colour
	  Inventory/ClientInventory  the inventory, predicted (Inventory/Menu) and corrected by the server
	  Ui/                        hotbar HUD, inventory and creative screens (Screens), item icons
	  Ui/Waila                   what the crosshair points at (Jade's WAILA; more while F3 is open)
	  Interaction/               mining / placing / using blocks (BlockInteraction, CrackOverlay)
	  Entities/EntityRenderer    dropped items
	  Rendering/TransmitterRenderer  Mekanism pipes and machines: arms, water in pipes and tanks,
	                             items moving through transporters, the windows of a burning Heat
	                             Generator and a smelting Electric Furnace (the server's
	                             Transmitters / Tanks / Machines / Transport messages)
	  Net/Notices                server messages in the chat (/gamemode answers)
	  Net/StructureNet           structure blocks and jigsaws: their records, their screens
	                             (Ui/StructureScreen), SAVE's data and pasted data in pieces
	  Rendering/StructureBoxes   structure blocks' outlines and names
	  Map/                       minimap, world map (M), waypoints, teleporting
	  Net/ClientNet              routes server messages to the modules above
	  Audio/                     sounds: SoundPlayer (pooled 3D and interface sounds, the server's
	                             Sound messages, developer overrides), MovementSounds (footsteps,
	                             swimming, landings), Ambience (a lit furnace or Heat
	                             Generator, caves)
	  Player/MovementController  Minecraft movement: a hull simulated against the blocks, the
	                             character only drawn on top of it (waits for the ground to load)
	  Player/CharacterAnimator   the character's animations from the hull's movement
	  Player/HeldItems           the item in every character's hand, and in first person
	  Debug/DebugOverlay         F3 statistics
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)
local Coords = require(Shared.World.Coords)

local Client = script.Parent
local ClientWorld = require(Client.World.ClientWorld)
local ChunkStreamer = require(Client.Streaming.ChunkStreamer)
local WorkerPool = require(Client.Streaming.WorkerPool)
local ChunkRenderer = require(Client.Rendering.ChunkRenderer)
local ViewSettings = require(Client.Rendering.ViewSettings)
local LightingController = require(Client.Rendering.LightingController)
local BlockInteraction = require(Client.Interaction.BlockInteraction)
local ClientInventory = require(Client.Inventory.ClientInventory)
local Screens = require(Client.Ui.Screens)
local EntityRenderer = require(Client.Entities.EntityRenderer)
local TransmitterRenderer = require(Client.Rendering.TransmitterRenderer)
local Notices = require(Client.Net.Notices)
local StructureNet = require(Client.Net.StructureNet)
local StructureBoxes = require(Client.Rendering.StructureBoxes)
local HeldItems = require(Client.Player.HeldItems)
local MovementController = require(Client.Player.MovementController)
local CharacterAnimator = require(Client.Player.CharacterAnimator)
local DebugOverlay = require(Client.Debug.DebugOverlay)
local Waila = require(Client.Ui.Waila)
local Map = require(Client.Map)
local SoundPlayer = require(Client.Audio.SoundPlayer)
local MovementSounds = require(Client.Audio.MovementSounds)
local Ambience = require(Client.Audio.Ambience)

-- First, so the server's sounds play from the start instead of piling up.
SoundPlayer.start()

local seed = Shared:GetAttribute("Seed")
while type(seed) ~= "number" do
	Shared:GetAttributeChangedSignal("Seed"):Wait()
	seed = Shared:GetAttribute("Seed")
end

ViewSettings.apply()

local world = ClientWorld.new()
local renderer = ChunkRenderer.new()
local pool = WorkerPool.new(Client.Streaming.ChunkWorker :: LocalScript)
local generator = TerrainGenerator.new(seed :: number)
local streamer = ChunkStreamer.new(generator, world, pool, renderer)
LightingController.start(generator, world)

ClientInventory.start()
Screens.start()
Notices.start()
StructureNet.start(world)
StructureBoxes.start(world, StructureNet.records)
EntityRenderer.start(world)
-- (Pipes are decorated only where their chunk is on screen.)
TransmitterRenderer.start(world, function(cx: number, cz: number): boolean
	local node = streamer.nodes[Coords.chunkKey(cx, cz)]
	return node ~= nil and node.shown
end)
MovementController.start(world, streamer)
CharacterAnimator.start()
HeldItems.start()
BlockInteraction.start(world)
DebugOverlay.start(streamer)
Waila.start(world, generator)
Map.start(pool, generator)
MovementSounds.start(world)
Ambience.start()

RunService.Heartbeat:Connect(function(dt)
	streamer:update(dt)
end)

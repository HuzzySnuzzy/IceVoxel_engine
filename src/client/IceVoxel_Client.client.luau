--!strict
--[[
	IceVoxel client: generates, meshes and renders the world locally.

	  World/ClientWorld          block data of nearby chunks, edit lists, edit prediction
	  Streaming/ChunkStreamer    which chunks (and LOD levels) exist, job scheduling
	  Streaming/WorkerPool       Actors running Streaming/ChunkWorker (parallel generation + meshing)
	  Rendering/ChunkRenderer    mesh boxes -> parts, within a per-frame budget
	  Rendering/ViewSettings     view distance per device, lighting and fog
	  Inventory/ClientInventory  the inventory, predicted (Inventory/Menu) and corrected by the server
	  Ui/                        hotbar HUD, inventory and creative screens (Screens), item icons
	  Interaction/               mining / placing / using blocks (BlockInteraction, CrackOverlay)
	  Entities/EntityRenderer    dropped items
	  Net/Notices                server messages in the chat (/gamemode answers)
	  Map/                       minimap, world map (M), waypoints, teleporting
	  Net/ClientNet              routes server messages to the modules above
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

local Client = script.Parent
local ClientWorld = require(Client.World.ClientWorld)
local ChunkStreamer = require(Client.Streaming.ChunkStreamer)
local WorkerPool = require(Client.Streaming.WorkerPool)
local ChunkRenderer = require(Client.Rendering.ChunkRenderer)
local ViewSettings = require(Client.Rendering.ViewSettings)
local BlockInteraction = require(Client.Interaction.BlockInteraction)
local ClientInventory = require(Client.Inventory.ClientInventory)
local Screens = require(Client.Ui.Screens)
local EntityRenderer = require(Client.Entities.EntityRenderer)
local Notices = require(Client.Net.Notices)
local HeldItems = require(Client.Player.HeldItems)
local MovementController = require(Client.Player.MovementController)
local CharacterAnimator = require(Client.Player.CharacterAnimator)
local DebugOverlay = require(Client.Debug.DebugOverlay)
local Map = require(Client.Map)

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

ClientInventory.start()
Screens.start()
Notices.start()
EntityRenderer.start(world)
MovementController.start(world, streamer)
CharacterAnimator.start()
HeldItems.start()
BlockInteraction.start(world)
DebugOverlay.start(streamer)
Map.start(pool, generator)

RunService.Heartbeat:Connect(function(dt)
	streamer:update(dt)
end)

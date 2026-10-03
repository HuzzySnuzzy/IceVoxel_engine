--!strict
--[[
	IceVoxel client: generates, meshes and renders the world locally.

	  World/ClientWorld          block data of nearby chunks, edit lists, edit prediction
	  Streaming/ChunkStreamer    which chunks (and LOD levels) exist, job scheduling
	  Streaming/WorkerPool       Actors running Streaming/ChunkWorker (parallel generation + meshing)
	  Rendering/ChunkRenderer    mesh boxes -> parts, within a per-frame budget
	  Interaction/               breaking / placing blocks, hotbar
	  Map/                       minimap, world map (M), waypoints, teleporting
	  Net/ClientNet              routes server messages to the modules above
	  Player/SpawnGuard          holds the character until the ground exists
	  Player/WaterController     swimming and water currents
	  Debug/DebugOverlay         F3 statistics
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)

local Client = script.Parent
local ClientWorld = require(Client.World.ClientWorld)
local ChunkStreamer = require(Client.Streaming.ChunkStreamer)
local WorkerPool = require(Client.Streaming.WorkerPool)
local ChunkRenderer = require(Client.Rendering.ChunkRenderer)
local BlockInteraction = require(Client.Interaction.BlockInteraction)
local SpawnGuard = require(Client.Player.SpawnGuard)
local WaterController = require(Client.Player.WaterController)
local DebugOverlay = require(Client.Debug.DebugOverlay)
local Map = require(Client.Map)

local seed = Shared:GetAttribute("Seed")
while type(seed) ~= "number" do
	Shared:GetAttributeChangedSignal("Seed"):Wait()
	seed = Shared:GetAttribute("Seed")
end

local world = ClientWorld.new()
local renderer = ChunkRenderer.new()
local pool = WorkerPool.new(Client.Streaming.ChunkWorker :: LocalScript)
local generator = TerrainGenerator.new(seed :: number)
local streamer = ChunkStreamer.new(generator, world, pool, renderer)

SpawnGuard.start(streamer)
WaterController.start(world)
BlockInteraction.start(world)
DebugOverlay.start(streamer)
Map.start(pool, generator)

-- Fade out the edge of the view distance (an Atmosphere replaces fog, so respect one if present).
if Config.Render.Fog and Lighting:FindFirstChildOfClass("Atmosphere") == nil then
	Lighting.FogEnd = Config.Lod.ViewDistance * Config.BlockSize
	Lighting.FogStart = Lighting.FogEnd * 0.55
end

RunService.Heartbeat:Connect(function(dt)
	streamer:update(dt)
end)

--!strict
--[[
	Map feature: minimap, world map (M), waypoints.

	Both maps paint terrain from the generator in the worker actors (Map/MapPainter) into
	EditableImages (Map/MapLayer). Without EditableImage access (see README) the maps still show
	the player, other players and waypoints, and the world map's menu still works.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)

local WorkerPool = require(script.Parent.Streaming.WorkerPool)
local MapLayer = require(script.MapLayer)
local Minimap = require(script.Minimap)
local WorldMap = require(script.WorldMap)
local Waypoints = require(script.Waypoints)

local TILE = Config.Map.TileSize

local Map = {}

-- Smallest ring image (multiple of the tile size) for a window of `pixels`.
local function layerSize(pixels: number): number
	return math.ceil((pixels + TILE) / TILE) * TILE
end

function Map.start(pool: WorkerPool.WorkerPool, generator: TerrainGenerator.Generator)
	if not Config.Map.Enabled then
		return
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "IceVoxelMap"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 5
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local waypoints = Waypoints.new()
	local miniLayer = MapLayer.new(layerSize(Config.Map.MinimapSize), Config.Map.MinimapScale)
	local worldLayer = MapLayer.new(layerSize(WorldMap.MAX_PIXELS), 4)

	local worldMap = WorldMap.new(gui, worldLayer, waypoints, generator)
	local minimap = Minimap.new(gui, miniLayer, waypoints, worldMap.toggle)

	RunService.Heartbeat:Connect(function()
		minimap.update()
		worldMap.update()
		-- The world map gets the workers first while it is open.
		if worldMap.isOpen() then
			worldLayer:step(pool)
		end
		miniLayer:step(pool)
	end)
end

return Map

--!strict
--[[
	Map feature: minimap, world map (M), waypoints.

	Both maps paint terrain from the generator in the worker actors (Map/MapPainter) into
	EditableImages (Map/MapLayer). Without EditableImage access (see README) the maps still show
	the player, other players and waypoints, and the world map's menu still works.

	The Minimap setting (`setMinimapVisible`) hides the minimap; while hidden it neither draws nor
	asks the workers for tiles (the world map still does while open). `setPaused` holds every
	tile job (both maps) while the terrain needs the workers more, e.g. right after a teleport.
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

-- The Minimap setting, and the minimap once started.
local minimapVisible = true
local minimap: Minimap.Minimap? = nil
local paused = false

-- Smallest ring image (multiple of the tile size) for a window of `pixels`.
local function layerSize(pixels: number): number
	return math.ceil((pixels + TILE) / TILE) * TILE
end

-- Shows or hides the minimap (and its coordinates line); hidden, it does no work.
function Map.setMinimapVisible(visible: boolean)
	minimapVisible = visible
	local shown = minimap
	if shown then
		shown.setVisible(visible)
	end
end

-- Holds (true) or resumes the maps' tile jobs.
function Map.setPaused(value: boolean)
	paused = value
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
	local mini = Minimap.new(gui, miniLayer, waypoints, worldMap.toggle)
	minimap = mini
	mini.setVisible(minimapVisible)

	RunService.Heartbeat:Connect(function()
		if minimapVisible then
			mini.update()
		end
		worldMap.update()
		if paused then
			return
		end
		-- The world map gets the workers first while it is open.
		if worldMap.isOpen() then
			worldLayer:step(pool)
		end
		if minimapVisible then
			miniLayer:step(pool)
		end
	end)
end

return Map

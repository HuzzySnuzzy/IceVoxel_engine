--!strict
--[[
	Map feature: minimap, world map (M), waypoints, the weather mode (B: Map/WeatherLayer).

	Both maps paint terrain from the generator in the worker actors (Map/MapPainter) into
	EditableImages (Map/MapLayer). Without EditableImage access (see README) the maps still show
	the player, other players and waypoints, and the world map's menu still works.

	The Minimap setting (`setMinimapVisible`) hides the minimap; while hidden it neither draws nor
	asks the workers for tiles (the world map still does while open). `setPaused` holds every
	tile job (both maps) while the terrain needs the workers more, e.g. right after a teleport.

	Two ScreenGuis (Ui/UiScale): the world map's (its backdrop covers the screen; below Roblox's top
	bar, where input positions start) and the minimap's corner (the whole screen, so its offsets
	are Ui/HudLayout's screen pixels), which hides while the world map covers it.

	The Weather Map key binding (B by default, Settings/Keybinds) switches both maps' weather
	mode, as their cloud buttons do (the way in on touch screens): rain, snow, thunder and
	clouds over the terrain, the wind, and forecasts on the world map.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)

local WorkerPool = require(script.Parent.Streaming.WorkerPool)
local Keybinds = require(script.Parent.Settings.Keybinds)
local Screens = require(script.Parent.Ui.Screens)
local UiScale = require(script.Parent.Ui.UiScale)
local MapLayer = require(script.MapLayer)
local Minimap = require(script.Minimap)
local WorldMap = require(script.WorldMap)
local Waypoints = require(script.Waypoints)
local WeatherLayer = require(script.WeatherLayer)

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

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = UiScale.screenGui("IceVoxelMap", "Map", { inset = false, kind = "screen" })
	gui.Parent = playerGui
	local cornerGui = UiScale.screenGui("IceVoxelMinimap", "Map", { inset = true, full = true, kind = "scaled" })
	cornerGui.Parent = playerGui

	local waypoints = Waypoints.new()
	local miniLayer = MapLayer.new(layerSize(Config.Map.MinimapSize), Config.Map.MinimapScale)
	local worldLayer = MapLayer.new(layerSize(WorldMap.MAX_PIXELS), 4)

	local worldMap = WorldMap.new(gui, worldLayer, waypoints, generator)
	local mini = Minimap.new(cornerGui, miniLayer, waypoints, worldMap.toggle)
	minimap = mini
	mini.setVisible(minimapVisible)

	UserInputService.InputBegan:Connect(function(input, processed)
		-- (The Weather Map key binding; with the world map open too, which is not a screen.)
		if not processed and Keybinds.matches("weatherMap", input) and not Screens.isOpen() then
			WeatherLayer.toggle()
		end
	end)

	RunService.Heartbeat:Connect(function()
		local covered = worldMap.isOpen()
		if cornerGui.Enabled == covered then
			cornerGui.Enabled = not covered
		end
		if minimapVisible and not covered then
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

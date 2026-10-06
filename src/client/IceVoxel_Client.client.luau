--!strict
--[[
	IceVoxel client: generates, meshes and renders the world locally.

	  World/ClientWorld          block data of nearby chunks, edit lists, edit prediction
	  Streaming/ChunkStreamer    which chunks (and LOD levels) exist, job scheduling
	  Streaming/WorkerPool       Actors running Streaming/ChunkWorker (parallel generation + meshing)
	  Rendering/ChunkRenderer    mesh boxes -> parts, within a per-frame budget
	  Rendering/ViewSettings     the view from the player's settings: distances, caves, plants,
	                             lights, lighting quality and fog
	  Settings/                  the player's settings (the Options menu, Ui/SettingsScreen: P):
	                             values, saving them on the server, and the effects registered
	                             below that apply them live
	  Rendering/LightingController  day and night: the sun, sky light, cave darkness, fog colour
	  Inventory/ClientInventory  the inventory, predicted (Inventory/Menu) and corrected by the server
	  Ui/                        hotbar HUD, inventory and creative screens (Screens), item icons,
	                             the spectator menu (SpectatorGui), the game mode switcher
	                             (GameModeSwitcher: F3 + F4)
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
	  Player/SpectatorView       spectators invisible to other players, a floating head to spectators
	  Debug/DebugOverlay         F3 statistics and Minecraft's debug keys (F3 + N, F3 + F4, F3 + Q)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)
local Coords = require(Shared.World.Coords)
local PlayerSettings = require(Shared.PlayerSettings)

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
local SpectatorView = require(Client.Player.SpectatorView)
local GameModeSwitcher = require(Client.Ui.GameModeSwitcher)
local DebugOverlay = require(Client.Debug.DebugOverlay)
local Waila = require(Client.Ui.Waila)
local Map = require(Client.Map)
local SoundPlayer = require(Client.Audio.SoundPlayer)
local MovementSounds = require(Client.Audio.MovementSounds)
local Ambience = require(Client.Audio.Ambience)
local Settings = require(Client.Settings)
local SettingsScreen = require(Client.Ui.SettingsScreen)
local Hud = require(Client.Ui.Hud)
local Style = require(Client.Ui.Style)

-- First, so the server's sounds play from the start instead of piling up.
SoundPlayer.start()
-- Listens for the player's saved settings (the terrain below waits a moment for them).
Settings.start()

local seed = Shared:GetAttribute("Seed")
while type(seed) ~= "number" do
	Shared:GetAttributeChangedSignal("Seed"):Wait()
	seed = Shared:GetAttribute("Seed")
end

-- Up to Config.Settings.LoadWait seconds, so the first terrain is already the player's view.
Settings.waitForSaved()
ViewSettings.apply()

--[[
	What changing a setting takes (Settings.register; each runs once now, then after changes:
	Settings/ batches them once per frame and holds the costly ones until a slider stops).
	Registered before the modules they set up start where that matters (touch buttons are bound
	once, in MovementController.start).
]]
local on = PlayerSettings.on
Settings.register("controls", function(values)
	Config.Movement.ToggleSprint = on(values, "toggleSprint")
	-- (Bound once a session: a change applies after rejoining.)
	Config.Movement.TouchButtons = on(values, "touchButtons")
	Hud.setWheelSelects(on(values, "scrollHotbar"))
end)
Settings.register("camera", function(values)
	MovementController.setFieldOfView(values.fov)
	MovementController.setFovEffects(values.fovEffects / 100)
end)
Settings.register("audio", function(values)
	local volume = PlayerSettings.volume
	SoundPlayer.setPlayerSettings(volume(values, "masterVolume"), {
		blocks = volume(values, "blocksVolume"),
		players = volume(values, "playersVolume"),
		ambient = volume(values, "ambientVolume"),
		ui = volume(values, "uiVolume"),
	}, {
		footsteps = on(values, "footsteps"),
		interface = on(values, "interfaceClicks"),
		ambient = on(values, "caveRumble"),
	})
end)
Settings.register("hud", function(values)
	local minimap = on(values, "minimap")
	Map.setMinimapVisible(minimap)
	Waila.setMinimapShown(minimap)
	Waila.setEnabled(on(values, "waila"))
	Style.setScaleOverride(values.guiScale)
end)
Settings.register("lighting", function()
	ViewSettings.applyLighting()
end)
Settings.register("fog", function()
	ViewSettings.applyFog()
end)
-- (Read live: ChunkRenderer's light sweep asks ViewSettings.lichenLightDistance.)
Settings.register("lichen", function() end)
-- (Read live: the streamer checks "skipHidden" at every refresh.)
Settings.register("skipHidden", function() end)
Settings.register("swapFrames", function(values)
	-- (Read live by the renderer and the far meshes.)
	Config.Render.SwapFrames = values.swapFrames
end)

local world = ClientWorld.new()
local renderer = ChunkRenderer.new()
local pool = WorkerPool.new(Client.Streaming.ChunkWorker :: LocalScript)
local generator = TerrainGenerator.new(seed :: number)
local streamer = ChunkStreamer.new(generator, world, pool, renderer)
LightingController.start(generator, world)

-- The view: LodTree's four distances, plants and the cave view's radii, then the streamer selects
-- again at once (one call a frame whichever of them changed). Hidden terrain ("skipHidden") is
-- a slot for the horizon culling to fill.
local function applyView()
	streamer:applyView()
end
Settings.register("lod", applyView)
Settings.register("caves", applyView)
Settings.register("foliage", applyView)
-- Teleports (and the first load): map tiles wait until the new area is there.
streamer.onTeleportMode = function(active: boolean)
	Map.setPaused(active)
end
-- Shadows, far shadows and textures restyle live parts (ChunkRenderer.restyle).
local function restyle(values: PlayerSettings.Values)
	renderer:restyle({
		shadows = on(values, "shadows"),
		farShadows = on(values, "farShadows"),
		textures = on(values, "textures"),
	})
end
Settings.register("shadows", restyle)
Settings.register("farShadows", restyle)
Settings.register("textures", restyle)
Settings.register("overlay", function(values)
	renderer.overlay:setUserEnabled(on(values, "farMeshes"))
end)
Settings.register("budget", function(values)
	renderer:setBuildBudget(PlayerSettings.buildBudget(values))
end)
-- The menu's status lines.
Settings.setStatus("terrain", function(): string?
	local stats = streamer:stats()
	local queued = stats.waiting + stats.queued
	local building = stats.working + stats.building
	if queued + building == 0 then
		return "Terrain up to date"
	end
	return `Updating terrain: {queued} queued, {building} building`
end)
Settings.setStatus("farMeshes", function(): string?
	local stats = renderer.overlay:getStats()
	return `Far meshes: {stats.status}, {stats.meshParts} meshes`
end)
Settings.setStatus("controls", function(): string?
	return if Settings.shown("touchButtons") then "Touch buttons change after rejoining" else nil
end)

ClientInventory.start()
Screens.start()
SettingsScreen.start()
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
SpectatorView.start()
BlockInteraction.start(world)
GameModeSwitcher.start()
DebugOverlay.start(streamer)
Waila.start(world, generator)
Map.start(pool, generator)
MovementSounds.start(world)
Ambience.start()

RunService.Heartbeat:Connect(function(dt)
	-- While the player waits for the ground, the renderer may build longer per frame.
	local view = MovementController.current
	streamer:setFrozen(view ~= nil and view.frozen)
	streamer:update(dt)
end)

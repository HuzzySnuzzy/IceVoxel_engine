--!strict
--[[
	IceVoxel client: generates, meshes and renders the world locally.

	  Ui/MainMenu                the title screen, first (Config.MainMenu.Enabled): the operator
	                             creates the world there, everyone joins it from there; nothing
	                             below starts before the player enters the world (no input, no
	                             terrain), then everything starts as on a plain join

	  World/ClientWorld          block data of nearby chunks, edit lists, edit prediction
	  Streaming/ChunkStreamer    which chunks (and LOD levels) exist, job scheduling
	  Streaming/WorkerPool       Actors running Streaming/ChunkWorker (parallel generation + meshing)
	  Rendering/ChunkRenderer    mesh boxes -> parts, within a per-frame budget
	  Rendering/TextureLooks     how blocks look with the texture pack (Shared/TexturePack):
	                             variants, tints, images, sprites, far looks; checks the ids
	                             and measures the textures' averages in the background
	  Rendering/ViewSettings     the view from the player's settings: distances, caves, plants,
	                             lights, lighting quality and fog
	  Settings/                  the player's settings (the Options menu, Ui/SettingsScreen: P):
	                             values, saving them on the server, and the effects registered
	                             below that apply them live; the key bindings every input site
	                             reads (Settings/Keybinds), the mouse's sensitivity and inversion
	                             (Player/MouseLook) and the attack indicator (Ui/AttackIndicator)
	  Rendering/LightingController  day and night: the sun, sky light, cave darkness, fog colour
	  Rendering/FluidFog         the view from inside water, lava, oil or fuel: Minecraft's fluid
	                             fog in the fluid's colour and a tint
	  Inventory/ClientInventory  the inventory, predicted (Inventory/Menu) and corrected by the server
	  Ui/                        hotbar HUD, inventory and creative screens (Screens), item icons,
	                             the spectator menu (SpectatorGui), the game mode switcher
	                             (GameModeSwitcher: F3 + F4)
	  Ui/Waila                   what the crosshair points at (Jade's WAILA; more while F3 is open)
	  Interaction/               mining / placing / using blocks (BlockInteraction, CrackOverlay,
	                             TankUse: buckets on machines)
	  Entities/EntityRenderer    dropped items
	  Entities/MobRenderer       mobs (cows, sheep, pigs, chickens, zombies, skeletons, creepers,
	                             spiders): boxes gliding between the server's updates, hurt
	                             flashes, creepers' fuses, flames, arrows, their hits' knockback
	  Rendering/TransmitterRenderer  Mekanism pipes and machines: arms, fluids in pipes and tanks,
	                             items moving through transporters, the windows of working
	                             generators, furnaces and refineries (the server's
	                             Transmitters / Tanks / Machines / Transport messages)
	  Net/Notices                server messages in the chat (/gamemode answers)
	  Net/StructureNet           structure blocks and jigsaws: their records, their screens
	                             (Ui/StructureScreen), SAVE's data and pasted data in pieces
	  Rendering/StructureBoxes   structure blocks' outlines and names
	  Rendering/FireRenderer     fire's animated flames on the floor and on burning walls
	  Rendering/FuseView         lit TNT and Nukes flashing
	  Map/                       minimap, world map (M), waypoints, teleporting
	  Net/ClientNet              routes server messages to the modules above
	  Audio/                     sounds: SoundPlayer (pooled 3D and interface sounds, the server's
	                             Sound messages, developer overrides), MovementSounds (footsteps,
	                             swimming, landings), Ambience (a lit furnace, Heat or
	                             Combustion Generator, lava, fire, Minecraft's cave mood:
	                             CaveMood),
	                             Music (surface and cave tracks, Minecraft's timing: MusicRules)
	  Ui/MusicToast              the "Now Playing" toast in the top right corner
	  Player/MovementController  Minecraft movement: a hull simulated against the blocks, the
	                             character only drawn on top of it (waits for the ground to load)
	  Player/CharacterAnimator   the character's animations from the hull's movement
	  Player/HeldItems           the item in every character's hand, and in first person
	  Player/SpectatorView       spectators invisible to other players, a floating head to spectators
	  Player/BurningView         flames on burning players (lava), the fire overlay in first person
	  Rendering/ExplosionView    explosions (the server's Explosion messages): the blast drawn, its
	                             knockback on the movement, a short camera shake; the Nuke's
	                             flash, fireball and mushroom cloud
	  Player/SurvivalState       Tough As Nails: this player's thirst and body temperature from
	                             the server, which Ui/SurvivalHud draws (droplets, the gauge, frost
	                             and heat at the edges); Interaction/Drinking drinks and fills
	                             bottles and canteens (and drinks potions), Player/Exertion
	                             reports sprinting and jumps
	  Player/EffectState         status effects from the server (Speed, Haste, Night Vision,
	                             Oil Coated...): the movement and mining read them, Ui/EffectHud
	                             draws them in the top right corner (a list beside open screens),
	                             Rendering/EffectView does Night Vision, Blindness and Nausea
	  Debug/DebugOverlay         F3 statistics and Minecraft's debug keys (F3 + N, F3 + F4, F3 + Q)
	  Player/ProgressionState    knowledge, the Age and skills from the server (the recipe gate on
	                             the predicted inventory, mining and boiling perks), which Ui/Hud
	                             draws as the knowledge bar; Ui/AgeToast shows a new Age's banner,
	                             Ui/SkillTreeScreen the skill tree (K)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local WorldTypes = require(Shared.Generation.WorldTypes)
local Coords = require(Shared.World.Coords)
local PlayerSettings = require(Shared.PlayerSettings)

local Client = script.Parent
local ClientWorld = require(Client.World.ClientWorld)
local ChunkStreamer = require(Client.Streaming.ChunkStreamer)
local WorkerPool = require(Client.Streaming.WorkerPool)
local ChunkRenderer = require(Client.Rendering.ChunkRenderer)
local TextureLooks = require(Client.Rendering.TextureLooks)
local ViewSettings = require(Client.Rendering.ViewSettings)
local LightingController = require(Client.Rendering.LightingController)
local FluidFog = require(Client.Rendering.FluidFog)
local BlockInteraction = require(Client.Interaction.BlockInteraction)
local ClientInventory = require(Client.Inventory.ClientInventory)
local Screens = require(Client.Ui.Screens)
local EntityRenderer = require(Client.Entities.EntityRenderer)
local MobRenderer = require(Client.Entities.MobRenderer)
local TransmitterRenderer = require(Client.Rendering.TransmitterRenderer)
local FireRenderer = require(Client.Rendering.FireRenderer)
local FuseView = require(Client.Rendering.FuseView)
local Notices = require(Client.Net.Notices)
local StructureNet = require(Client.Net.StructureNet)
local StructureBoxes = require(Client.Rendering.StructureBoxes)
local HeldItems = require(Client.Player.HeldItems)
local MovementController = require(Client.Player.MovementController)
local CharacterAnimator = require(Client.Player.CharacterAnimator)
local SpectatorView = require(Client.Player.SpectatorView)
local BurningView = require(Client.Player.BurningView)
local ExplosionView = require(Client.Rendering.ExplosionView)
local SurvivalState = require(Client.Player.SurvivalState)
local EffectState = require(Client.Player.EffectState)
local EffectView = require(Client.Rendering.EffectView)
local EffectHud = require(Client.Ui.EffectHud)
local ProgressionState = require(Client.Player.ProgressionState)
local GameModeSwitcher = require(Client.Ui.GameModeSwitcher)
local DebugOverlay = require(Client.Debug.DebugOverlay)
local Waila = require(Client.Ui.Waila)
local Map = require(Client.Map)
local SoundPlayer = require(Client.Audio.SoundPlayer)
local MovementSounds = require(Client.Audio.MovementSounds)
local Ambience = require(Client.Audio.Ambience)
local Music = require(Client.Audio.Music)
local MusicToast = require(Client.Ui.MusicToast)
local Settings = require(Client.Settings)
local Keybinds = require(Client.Settings.Keybinds)
local MouseLook = require(Client.Player.MouseLook)
local AttackIndicator = require(Client.Ui.AttackIndicator)
local SettingsScreen = require(Client.Ui.SettingsScreen)
local SkillTreeScreen = require(Client.Ui.SkillTreeScreen)
local AgeToast = require(Client.Ui.AgeToast)
local Hud = require(Client.Ui.Hud)
local MainMenu = require(Client.Ui.MainMenu)
local Style = require(Client.Ui.Style)

-- First, so the server's sounds play from the start instead of piling up.
SoundPlayer.start()
-- Listens for the player's saved settings (the terrain below waits a moment for them).
Settings.start()
-- The title screen until the player enters the world (Ui/MainMenu: its Options menu works).
MainMenu.run()

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
-- (Read live: Settings/Keybinds reads the session's values; listeners such as the sprint and sneak
-- actions bind their new keys.)
Settings.register("keys", Keybinds.refresh)
Settings.register("controls", function(values)
	Config.Movement.ToggleSprint = on(values, "toggleSprint")
	Config.Movement.ToggleSneak = on(values, "toggleSneak")
	-- (Bound once a session: a change applies after rejoining.)
	Config.Movement.TouchButtons = on(values, "touchButtons")
	Hud.setWheelSelects(on(values, "scrollHotbar"))
	Hud.setScrolling(values)
end)
Settings.register("mouse", function(values)
	MouseLook.setSensitivity(PlayerSettings.mouseSensitivity(values))
	MouseLook.setInverted(on(values, "invertMouse"))
end)
Settings.register("camera", function(values)
	MovementController.setFieldOfView(values.fov)
	MovementController.setFovEffects(values.fovEffects / 100)
	MovementController.setViewBobbing(on(values, "viewBobbing"))
	MovementController.setDamageTilt(values.damageTilt / 100)
	EffectView.setDistortion(PlayerSettings.distortion(values))
end)
Settings.register("audio", function(values)
	local volume = PlayerSettings.volume
	SoundPlayer.setPlayerSettings(volume(values, "masterVolume"), {
		blocks = volume(values, "blocksVolume"),
		players = volume(values, "playersVolume"),
		ambient = volume(values, "ambientVolume"),
		ui = volume(values, "uiVolume"),
		music = volume(values, "musicVolume"),
	}, {
		footsteps = on(values, "footsteps"),
		interface = on(values, "interfaceClicks"),
		ambient = on(values, "caveRumble"),
	})
	Music.setToasts(on(values, "musicToasts"))
end)
Settings.register("hud", function(values)
	local minimap = on(values, "minimap")
	Map.setMinimapVisible(minimap)
	Waila.setMinimapShown(minimap)
	MusicToast.setMinimapShown(minimap)
	Waila.setEnabled(on(values, "waila"))
	Style.setScaleOverride(values.guiScale)
	AttackIndicator.setMode(values.attackIndicator)
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
-- Texture ids are checked and averages measured in the background from now on; the renderer
-- follows TextureLooks' looks (its parts, and the far meshes through MeshOverlay:setLooks).
TextureLooks.start()
local renderer = ChunkRenderer.new()
local pool = WorkerPool.new(Client.Streaming.ChunkWorker :: LocalScript)
-- (The world type and options the server published with the seed: Generation/WorldTypes.)
local generator = WorldTypes.fromAttributes(Shared)
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
-- Shadows, far shadows, textures and far materials restyle live parts (ChunkRenderer.restyle;
-- "farMaterials" uses the "textures" effect).
local function restyle(values: PlayerSettings.Values)
	renderer:restyle({
		shadows = on(values, "shadows"),
		farShadows = on(values, "farShadows"),
		textures = on(values, "textures"),
		farMaterials = on(values, "farMaterials"),
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
Settings.setStatus("mouse", function(): string?
	return if MouseLook.available() then nil else "Invert Mouse needs Roblox's camera scripts"
end)

ClientInventory.start()
SurvivalState.start()
EffectState.start()
-- (After the inventory: it sets the recipe gate on the prediction.)
ProgressionState.start()
Screens.start()
-- (After the HUD: the hotbar's attack indicator square is the HUD's.)
AttackIndicator.start()
SettingsScreen.start()
SkillTreeScreen.start()
AgeToast.start()
Notices.start()
StructureNet.start(world)
StructureBoxes.start(world, StructureNet.records)
EntityRenderer.start(world)
MobRenderer.start(world)
-- (Pipes are decorated only where their chunk is on screen.)
TransmitterRenderer.start(world, function(cx: number, cz: number): boolean
	local node = streamer.nodes[Coords.chunkKey(cx, cz)]
	return node ~= nil and node.shown
end)
-- (Flames too: never over coarse terrain still being built.)
FireRenderer.start(world, function(cx: number, cz: number): boolean
	local node = streamer.nodes[Coords.chunkKey(cx, cz)]
	return node ~= nil and node.shown
end)
FuseView.start(world)
MovementController.start(world, streamer)
-- (After the camera: the fluid at the camera, its fog and tint.)
FluidFog.start(
	function(x: number, y: number, z: number): number?
		return world:getBlock(x, y, z)
	end,
	function(): boolean
		local view = MovementController.current
		return view ~= nil and view.state.noClip
	end,
	function(): number
		return FluidFog.light(LightingController.dayTime(), LightingController.skyExposure())
	end,
	ViewSettings.setFluidFog,
	LightingController.setFogColour,
	function(): number
		return (ViewSettings.lod())
	end
)
CharacterAnimator.start()
HeldItems.start()
SpectatorView.start()
BurningView.start()
ExplosionView.start()
BlockInteraction.start(world)
GameModeSwitcher.start()
DebugOverlay.start(streamer)
Waila.start(world, generator)
Map.start(pool, generator)
MovementSounds.start(world)
Ambience.start(function(x: number, y: number, z: number): number?
	return world:getBlock(x, y, z)
end)
MusicToast.start()
Music.start()
-- (After the toast: the icons go under its place; after the camera and the fluid's fog.)
EffectHud.start()
EffectView.start()

RunService.Heartbeat:Connect(function(dt)
	-- While the player waits for the ground, the renderer may build longer per frame.
	local view = MovementController.current
	streamer:setFrozen(view ~= nil and view.frozen)
	streamer:update(dt)
end)

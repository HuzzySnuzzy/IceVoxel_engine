--!strict
--[[
	IceVoxel configuration.

	Shared by the server, the client and the worker actors. Anything that affects what the world *is*
	(seed handling, world shape, generation) must be identical on every machine, which is why it lives
	in ReplicatedStorage. Purely visual / performance settings live under `Lod`, `Render` and `Workers`
	and only affect the client.
]]

local Config = {
	-- World ------------------------------------------------------------------------------------------

	-- nil picks a random seed for every server. Set a number for a fixed, reproducible world.
	Seed = nil :: number?,

	-- Size of one block in studs. 3 makes the default character ~1.7 blocks tall (Minecraft is 1.8).
	BlockSize = 3,

	-- Blocks per chunk along X and Z. Chunks are full-height columns (stored cropped just above
	-- their highest block, see World/ChunkLayout).
	ChunkSize = 16,

	-- World height in blocks. Must be a multiple of SectionHeight and of Lod.MaxVerticalStep.
	WorldHeight = 1024,

	-- LOD 0 chunks are meshed in vertical sections of this many blocks so edits only rebuild a slice.
	SectionHeight = 16,

	SeaLevel = 64,

	-- Generation -------------------------------------------------------------------------------------

	Caves = {
		Enabled = true,
		-- Caves never come closer to the surface than this, so they are invisible from above ground.
		SurfaceMargin = 5,
		MinY = 4,
		-- While the camera is below the surface, cave walls are meshed in sections within this many
		-- blocks of it. Otherwise caves are treated as solid rock, which keeps the part count low.
		RevealRadius = 64,
		-- In big caverns (the Underlands) the radius grows with the open space around the camera, up
		-- to this. Caves only exist in full detail chunks, so more than their reach does nothing:
		-- underground they reach about Lod.UndergroundSplitDistanceL1 x 32 blocks (up to 15% less
		-- ahead of a moving camera: LodTree's hysteresis).
		RevealRadiusMax = 128,
		-- Glow lichen carries one PointLight per 8 x 8 x 8 blocks (Meshing/GreedyMesher), and only
		-- lights within this many blocks of the camera are on (Rendering/ChunkRenderer): about
		-- 25-50 in a cave, instead of every lichen of the revealed caves (1,000-3,000). Farther
		-- lichen still glows (its speck is Neon).
		LichenLightDistance = 32,
		-- Used instead on phones and tablets (Rendering/ViewSettings).
		Mobile = {
			RevealRadius = 48,
			RevealRadiusMax = 96,
			LichenLightDistance = 24,
		},
	},

	-- Highest LOD level that still receives trees / structures (0 = only full detail chunks).
	StructureMaxLevel = 2,

	-- Level of detail (client) -----------------------------------------------------------------------

	Lod = {
		-- Number of detail levels. Level L chunks cover (ChunkSize * 2^L) blocks with ChunkSize cells.
		Levels = 7,
		-- Cells are 2^L blocks wide but never taller than this, so far mountains keep their shape.
		MaxVerticalStep = 16,
		-- A node is split into four children while the camera is closer than SplitDistance * nodeSize.
		-- Higher = more full detail chunks around the player (radius of LOD 0 is ~2 * SplitDistance chunks).
		SplitDistance = 3,
		-- SplitDistance for level 1 nodes only, i.e. how far full detail chunks reach (radius about
		-- 2 x this, in chunks). Full detail chunks are the most expensive (collision, caves, textures):
		-- 2 removes about 12% of all parts in mountains, at the cost of full detail ending sooner.
		SplitDistanceL1 = 3,
		-- SplitDistanceL1 while the camera is underground (the cave view: below the terrain surface,
		-- and for UndergroundSeconds after coming up, so walking in and out of a cave mouth does not
		-- rebuild chunks back and forth). Caves only exist in full detail chunks, so this is how far
		-- they can be seen: about 2 x this chunks (4: ~128 blocks, ~110 ahead of a moving camera;
		-- 3: ~96), from the first selection underground on (LodTree.select). Measured with a
		-- camera in a cave near the spawn (seed 12345), with Caves' radii: 268 full detail chunks
		-- instead of 164, ~57,000 parts instead of ~47,000 (under the highest mountains, in the
		-- Underlands: ~139,000 instead of ~110,000, before far meshes).
		UndergroundSplitDistanceL1 = 4,
		UndergroundSeconds = 5,
		-- Nothing is rendered further away than this (blocks).
		ViewDistance = 2048,
		-- Plants (Render.Foliage) are drawn in full detail chunks closer than this (blocks from the
		-- viewer to the chunk; once drawn, up to half a chunk further: LodTree.drawsFoliage). Every
		-- box of a plant is a part, up to 4 a plant: 25-32 chunks (45 in that band) hold about
		-- 1,000-3,000 parts of plants on grassland, at most 6,000 (tests/spec/FoliageGeneration);
		-- all ~180 full detail chunks would hold 10,000-20,000. Further chunks leave them out.
		FoliageDistance = 40,
		-- Used instead on phones and tablets (touch screen without keyboard). They also draw parts
		-- much less far than computers do, so a long view distance would only cost memory there.
		Mobile = {
			ViewDistance = 512,
			SplitDistance = 2,
			UndergroundSplitDistanceL1 = 3,
			FoliageDistance = 24,
		},
	},

	-- Streaming (client) -----------------------------------------------------------------------------

	Streaming = {
		-- Seconds between recomputing which chunks should be visible.
		UpdateInterval = 0.2,
		-- Old meshes are force-removed after this long even if their replacement is not ready yet.
		ReplaceTimeout = 8,
		-- Max chunk diff requests sent to the server per message.
		DiffRequestBatch = 64,
	},

	Workers = {
		-- Number of Actors used for generation + meshing. 4-8 is a good range.
		Count = 6,
		-- Jobs queued per worker at once. Keeps priorities fresh while the camera moves.
		JobsPerWorker = 2,
		-- A worker yields to the next frame after running this long (milliseconds).
		SliceBudgetMs = 3,
	},

	-- Rendering (client) -----------------------------------------------------------------------------

	Render = {
		-- Milliseconds per frame spent creating / recycling parts.
		BuildBudgetMs = 4,
		-- Shadows on full detail chunks / on LOD chunks. Shadows also gives torches' and
		-- lanterns' light shadows, so it stops at walls (Rendering/PartPool; glowstone's cube
		-- casts one instead).
		Shadows = true,
		FarShadows = false,
		-- Recycled parts kept around for reuse.
		PoolLimit = 8000,
		-- Fades the edge of the view distance with Lighting fog (ignored if an Atmosphere exists).
		Fog = true,
		-- Use the blocks' MaterialVariant textures / face images (BlockList `texture`, `faces`).
		Textures = true,
		-- Draw plants (grass, ferns, flowers, mushrooms: up to 4 parts each, in full detail chunks
		-- within Lod.FoliageDistance only). false saves those parts on slow devices; plants are still
		-- there, aimed at and broken as usual, only not drawn. Read by the streamer's refresh.
		Foliage = true,

		--[[
			Far meshes (Rendering/MeshOverlay): regions of far chunks that stopped changing are merged
			into a few MeshParts built with EditableMesh, replacing thousands of parts. Parts are
			always built first and come back instantly when a region changes or a build fails.
			Published games need the Mesh / Image APIs enabled (see README). Levels below MinLevel and
			nodes wider than MaxRegionBlocks always stay parts; parts of merged levels use a plain
			look (SmoothPlastic, block colour, opaque water) so the swap is invisible.
		]]
		FarMeshes = {
			Enabled = true,
			-- Phones and tablets keep parts (unknown mesh budgets, slower CPUs).
			Mobile = false,
			-- Lowest LOD level merged. Level 1 starts ~100 blocks away, where block textures still show.
			MinLevel = 2,
			-- A region is RegionNodes x RegionNodes nodes of one level, at most MaxRegionBlocks wide
			-- (a part can be at most 2048 studs long).
			RegionNodes = 4,
			MaxRegionBlocks = 512,
			-- Seconds a region's chunks must stay unchanged before it is merged, and before a merged
			-- region that gained chunks (shown as parts meanwhile) is merged again.
			StableSeconds = 2,
			RebuildSeconds = 8,
			-- Triangles per MeshPart (EditableMesh allows 20,000; smaller meshes build in shorter steps).
			MaxTriangles = 10000,
			-- Seconds between mesh builds. None starts right after a hitch: a frame longer than both
			-- 1.5 x the average frame and MaxFrameTime seconds.
			BuildInterval = 0.35,
			MaxFrameTime = 1 / 40,
			-- Studs each quad overlaps its neighbours (hides cracks where quads meet).
			Overlap = 0.05,
			-- Meshes stay off when, in the startup probe, building a full-size mesh makes frames this
			-- much longer than usual (ms; measured up to three times).
			MaxBlockingMs = 35,
			-- No new meshes while the shown ones hold this many triangles (a safety limit; the whole
			-- default view needs ~100k on hills and ~300k in the mountains).
			MaxLiveTriangles = 1000000,
		},
	},

	-- Day cycle (server clock, shared maths) ---------------------------------------------------------

	--[[
		Minecraft's day: 24000 ticks, 0 sunrise (06:00), 6000 noon, 12000 sunset, 18000 midnight
		(Shared/DayCycle). The server keeps the clock (World/TimeOfDay) and admins change it with
		/time and /gamerule doDaylightCycle (Players/TimeCommands; who may: Gameplay.Admins, the
		owner and Studio).
	]]
	Time = {
		-- Real seconds per day (Minecraft: 1200, i.e. 20 minutes at 20 ticks a second).
		DayLength = 1200,
		-- Day time when the server starts, in ticks (1000 is Minecraft's "/time set day").
		StartTime = 1000,
		-- Minecraft's doDaylightCycle game rule: false stops the clock.
		Cycle = true,
	},

	-- Lighting (client) ------------------------------------------------------------------------------

	--[[
		Rendering/LightingController drives the Lighting service from the day time. Roblox's own
		engine does the lighting (Future technology and shadows, set in default.project.json): the sun
		and moon move with Lighting.ClockTime, and the settings below are blended by daylight (Night
		to Day, by Minecraft's sky brightness for the height of the sun Roblox draws), the sunrise /
		sunset glow (Dusk) and how deep the camera is under the natural ground (Underground). Colours
		are { r, g, b } in 0..255.

		Lighting.Ambient lights everything, caves and closed rooms too, while OutdoorAmbient, the sun
		and the environment light only reach what the engine sees as open to the sky. So CaveAmbient
		is how dark caves are, at any time of day as in Minecraft. Raise it to brighten them, like
		Minecraft's Brightness slider (Moody to Bright).

		An Atmosphere or Sky the place has is left alone (Roblox lights them by the sun and moon
		itself). Fog colour follows FogColor only while IceVoxel's fog is in use (Render.Fog and no
		Atmosphere, see Rendering/ViewSettings).
	]]
	Lighting = {
		-- false: only Lighting.ClockTime follows the day; everything else is left to the place. The
		-- sky light reaching the camera is still worked out (the cave rumble and F3 read it).
		Enabled = true,
		-- Seconds between updates (the sun moves 0.3 degrees a second at the default day length).
		UpdateInterval = 0.1,
		-- Lighting.Ambient: the light that reaches everywhere (caves are this dark).
		CaveAmbient = { 26, 26, 32 },
		Day = {
			OutdoorAmbient = { 112, 112, 118 },
			-- Lighting.Brightness: the sun's (and at night the moon's) strength.
			Brightness = 3,
			-- Lighting.ColorShift_Top: tint of faces lit by the sun / moon.
			ColorShiftTop = { 10, 6, 0 },
			-- Lighting.EnvironmentDiffuseScale / EnvironmentSpecularScale: light from the sky box.
			EnvironmentDiffuse = 1,
			EnvironmentSpecular = 0.5,
			-- Lighting.FogColor (Minecraft's day fog).
			FogColor = { 192, 216, 255 },
		},
		-- Dark blue but readable (Minecraft's night sky light is 4 of 15).
		Night = {
			OutdoorAmbient = { 44, 52, 84 },
			Brightness = 1,
			ColorShiftTop = { 16, 24, 48 },
			EnvironmentDiffuse = 0.4,
			EnvironmentSpecular = 0.2,
			FogColor = { 14, 18, 34 },
		},
		-- Warm sunrise and sunset light, mixed in up to Strength (Minecraft's sunrise colour curve).
		Dusk = {
			Strength = 0.8,
			OutdoorAmbient = { 150, 104, 84 },
			ColorShiftTop = { 200, 96, 30 },
			FogColor = { 230, 140, 96 },
		},
		-- Sky light fades out between Start and End blocks below the natural ground at the camera,
		-- smoothed with a time constant of Seconds (settled after about 3 x Seconds), leaving only
		-- CaveAmbient (and light blocks): the engine's own sky occlusion does not reach far, so big
		-- caves would otherwise be lit. A pit or shaft with nothing opaque above the camera keeps
		-- the sky's light, and open air within End blocks (a tunnel's mouth, a quarry under an
		-- overhang) gives 1 - distance / End of it (Rendering/SkyExposure).
		Underground = {
			Start = 4,
			End = 16,
			Seconds = 0.75,
			FogColor = { 12, 12, 16 },
		},
	},

	-- Player movement (client) ----------------------------------------------------------------------

	--[[
		Players move like in Minecraft Java Edition (Movement/PlayerPhysics): a 0.6 x 1.8 block hull
		simulated at 20 ticks per second against the block data, with the Roblox character only
		drawn on top of it (Player/MovementController).
	]]
	Movement = {
		-- Landing after a fall of more than 3 blocks hurts: ceil(distance - 3) half hearts of the
		-- 20 a Minecraft player has, scaled to Humanoid.MaxHealth.
		FallDamage = true,
		-- Highest step (blocks) walked up without jumping. Minecraft's is 0.6 (a slab); just over one
		-- block makes the steep terrain walkable. Sneaking still stops at every block edge.
		StepHeight = 1.0625,
		-- Sprint (also: double tap forward) and sneak keys, as Enum.KeyCode names. Sneaking on Left
		-- Shift takes that key away from Roblox's shift lock (Right Shift still toggles it).
		SprintKeys = { "LeftControl", "ButtonL3" },
		SneakKeys = { "LeftShift", "ButtonB" },
		-- true: the sprint key turns sprinting on and off (Minecraft's "Sprint: Toggle"; while on,
		-- moving forward sprints). false: hold the key.
		ToggleSprint = true,
		-- Field of view while sprinting, relative to normal (Minecraft: 1.15). 1 turns it off.
		SprintFov = 1.15,
		-- Sprint and sneak buttons on touch screens (toggles).
		TouchButtons = true,
		-- How fast the character turns towards where it walks (radians per second; third person).
		TurnSpeed = 14,
	},

	-- Map --------------------------------------------------------------------------------------------

	Map = {
		Enabled = true,
		-- Minimap size in pixels and blocks per minimap pixel.
		MinimapSize = 192,
		MinimapScale = 2,
		-- Zoom levels of the world map (M), in blocks per pixel.
		ZoomLevels = { 1, 2, 4, 8, 16, 32, 64 },
		-- Pixels per side of a map tile (tiles are painted and uploaded one at a time).
		TileSize = 64,
		-- Who may teleport by right clicking the world map: true = everyone, false = nobody,
		-- or a list of user ids. Checked by the server.
		Teleport = (true :: any) :: boolean | { number },
		-- Seconds between teleports of one player.
		TeleportCooldown = 2,
		-- Keep waypoints between sessions in a DataStore. In Studio this needs
		-- Game Settings > Security > "Enable Studio Access to API Services".
		SaveWaypoints = true,
	},

	-- Interaction ------------------------------------------------------------------------------------

	Interaction = {
		-- Max distance in blocks between the character and a block it edits.
		Reach = 8,
		-- Seconds between repeated places while a button is held, and between breaks in creative
		-- (Minecraft: 4 ticks, and a 5 tick destroy delay, so every 6th tick).
		RepeatInterval = 0.2,
		BreakInterval = 0.3,
		-- The mouse wheel changes the selected hotbar slot (as in Minecraft) instead of zooming
		-- the camera (I / O still zoom).
		ScrollWheelHotbar = true,
	},

	-- Game modes, inventories and item drops ---------------------------------------------------------

	Gameplay = {
		-- Game mode of players when they join: "Survival" (blocks are mined over time and drop as
		-- items, placing uses them up) or "Creative" (every block, instant breaking, flying).
		DefaultGameMode = "Survival",
		-- Who may switch their own game mode with the /gamemode chat command: true = everyone,
		-- false = nobody, or a list of user ids. The game's owner and Studio sessions always may.
		GameModeCommand = (true :: any) :: boolean | { number },
		-- Who may change other players' game modes (/gamemode creative Name) and the time
		-- (/time set|add, /gamerule doDaylightCycle): user ids, besides the game's owner and
		-- Studio sessions.
		Admins = {} :: { number },
		-- Keep the inventory when dying (Minecraft's keepInventory rule); otherwise it drops.
		KeepInventory = false,
	},

	-- Structures -------------------------------------------------------------------------------------

	--[[
		Structure blocks and jigsaw blocks (Minecraft's, creative only) and the structures generated
		in the world from the structure library (Shared/Structures, StructureLibrary). A structure
		block saves a region as compact text ("IVS1:...", Structures/Template) that can be pasted
		into the library, into a StringValue of the place's ReplicatedStorage.IceVoxelStructures
		folder, or back into a structure block in LOAD mode.
	]]
	Structures = {
		-- Who may use structure blocks and jigsaw blocks (creative players only; Minecraft's
		-- operators): a list of user ids, true = every creative player, false = nobody. The game's
		-- owner, Gameplay.Admins and Studio sessions always may. true lets anyone who can enter
		-- creative (Gameplay.GameModeCommand is everyone by default) upload, save and load
		-- structures of up to 48 x 48 x 48 blocks and generate whole jigsaw structures.
		Permission = {} :: boolean | { number },
		-- Largest structure size and relative position a structure block takes, per axis
		-- (Minecraft's 48 and -48..48).
		MaxSize = 48,
		MaxOffset = 48,
		-- How far DETECT looks for CORNER blocks of the same name (Minecraft's 80).
		DetectRange = 80,
		-- Blocks LOAD and a jigsaw's Generate place per frame (the rest wait for the next frames).
		LoadBlocksPerFrame = 2000,
		-- Longest structure text (characters) the server saves or accepts pasted. A StringValue
		-- holds at most 200,000 characters (IceVoxelSavedStructures, IceVoxelStructures).
		MaxDataChars = 200000,
		-- Structure text travels in pieces of this many characters (Protocol StructureData, both
		-- ways), at most DataPiecesPerSecond pieces a second each way: a 200,000 character text
		-- is 13 pieces. Reliable RemoteEvents name no size limit but share about 500 requests a
		-- second per client among all remotes; pieces keep each message small.
		DataPieceChars = 16000,
		DataPiecesPerSecond = 20,
		-- Library structures generate in the world (StructureLibrary/Structures and the
		-- IceVoxelStructures folder's `Generate` attributes). false: none do.
		Generate = true,
	},

	Entities = {
		-- Dropped items disappear after this many seconds (Minecraft: 5 minutes).
		ItemLifetime = 300,
		-- At most this many dropped items exist; the oldest disappear first.
		MaxItems = 1000,
		-- Players see dropped items within this many blocks.
		TrackingDistance = 96,
	},

	-- Sounds -----------------------------------------------------------------------------------------

	--[[
		Minecraft's sound events (Shared/Sounds, listed in Sounds/SoundList) played with sounds that
		ship with Roblox. The server sends the ones other players cause (breaking, placing, chests,
		pickups, tools breaking, hurting; server Audio/Sounds); clients play their own actions,
		footsteps and the interface themselves (Audio/SoundPlayer).

		To use your own sounds, put Sound instances in a Folder named OverrideFolder in SoundService
		or ReplicatedStorage, named like an event ("block.stone.break") or its category with the
		variant left out ("block.break"); several with one name are picked from at random. They play
		with their own Volume and PlaybackSpeed instead of the event's (still scaled by the settings
		below and varied by the event's pitch variance), heard as far as the event.
	]]
	Sounds = {
		-- false: no sounds at all (the server sends none and clients play none).
		Enabled = true,
		-- Master volume (client): multiplies every sound.
		Volume = 1,
		-- Volume per kind of sound (client), like Minecraft's Music & Sounds options. Every event
		-- names its `source`.
		Sources = {
			blocks = 1,
			players = 1,
			ambient = 1,
			ui = 1,
		},
		-- Sounds are heard within their event's maxDistance (blocks; Minecraft's 16) and fade out
		-- linearly; closer than MinDistance they are at full volume (client).
		MinDistance = 1,
		-- The server sends a sound to the players whose feet are within its maxDistance plus this
		-- (a third person camera hears from behind the character).
		BroadcastSlack = 8,
		-- Most sounds one player is sent per frame (the rest are dropped).
		MaxPerFrame = 64,
		-- Sounds a player's own inventory clicks and chest opening may cause per second (armor put
		-- on, chest lids), in bursts of twice that; more are dropped, so a client spamming those
		-- messages can't flood everyone near with sounds.
		PlayerRate = 8,
		-- Where developers' replacement Sounds live (see above).
		OverrideFolder = "IceVoxelSounds",
		-- Footsteps (the player's and others'), interface clicks and the rare cave rumble
		-- underground (client).
		Footsteps = true,
		Interface = true,
		Ambient = true,
	},

	-- Server -----------------------------------------------------------------------------------------

	Server = {
		-- Block updates (falling sand, fluids, ...) per second.
		TickRate = 20,
		MaxUpdatesPerTick = 4000,
		-- Edit requests a single player may make per second.
		EditsPerSecond = 25,
		-- Chunks (in chunk units) kept generated around every player for block updates / validation.
		SimulationRadius = 3,
		-- Generated chunks the server keeps in memory beyond the ones near players.
		CacheSize = 192,
		-- Max chunks the server generates per frame while preloading around players.
		GenerationsPerFrame = 1,
	},
}

return Config

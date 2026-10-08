--!strict
--[[
	IceVoxel configuration.

	Shared by the server, the client and the worker actors. Anything that affects what the world *is*
	(seed handling, world shape, generation) must be identical on every machine, which is why it lives
	in ReplicatedStorage. Purely visual / performance settings live under `Lod`, `Streaming`, `Render`
	and `Workers` (and the cave view's part of `Caves`) and only affect the client. Players change many
	of them for themselves in the Options menu (`Settings`, Shared/PlayerSettings): these are the
	defaults and the presets (High is this file's view, Low its Mobile values).
]]

local Config = {
	-- World ------------------------------------------------------------------------------------------

	-- nil picks a random seed for every server. Set a number for a fixed, reproducible world.
	Seed = nil :: number?,

	-- (The world type, its options, name, difficulty...: `World` below, by the title screen.)

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
		-- The deep caves (Generation/Caves) never come closer to the surface than this on their own;
		-- only the surface caves below (entrances, ravines) open them up.
		SurfaceMargin = 5,
		MinY = 4,
		-- Surface caves (Generation/SurfaceCaves): worms carved as Air, after the caves, that open at
		-- the surface. Never under water, near a river bed or into a library structure. Ranges are
		-- { lowest, highest }; lengths are in steps of about a block.
		-- Cave entrances (Minecraft's cave carver, adapted): one candidate per Spacing x Spacing
		-- blocks, taken with Chance, starting on the surface at a hashed spot. A tunnel of Radius
		-- (varying smoothly along it) winds down to Depth blocks below the surface, levels off there
		-- and ends in a small chamber; Branch is the chance of a side tunnel. On steep slopes it
		-- heads into the slope, so mountains get mouths and flat ground gets pits.
		Entrances = {
			Enabled = true,
			Spacing = 96,
			Chance = 0.6,
			Radius = { 1.5, 3.5 },
			Length = { 48, 140 },
			Depth = { 15, 60 },
			Branch = 0.35,
		},
		-- Ravines (Minecraft's canyon carver): rarer, long and narrow cuts open at the top, widest
		-- and deepest in the middle of their length (Radius: half width at the ends .. at the middle;
		-- Depth: below the surface in the middle, ~8 blocks at the ends).
		Ravines = {
			Enabled = true,
			Spacing = 384,
			Chance = 0.5,
			Radius = { 1.5, 6 },
			Length = { 60, 160 },
			Depth = { 20, 45 },
		},
		-- Lava (Generation/Lava). Cave air below LavaLevel (absolute y: blocks 1..LavaLevel - 1)
		-- is lava, as Minecraft's aquifers fill everything below y -54 (its surface 10 blocks above
		-- the world's floor) and its carvers below aboveBottom(8): the lava seas of the deepest
		-- caves and of the Underlands' floor under the highest mountains. It is CaveLava, the cave
		-- twin (nothing to draw while caves are hidden); surface caves dug that deep get Lava.
		LavaLevel = 11,
		LavaLakes = {
			-- Minecraft's lake_lava_underground (one try in 9 chunks, mostly ending inside rock):
			-- here one chunk in Rarity of those with caves tries Tries random spots for a cave floor
			-- at least Depth blocks below the surface and sinks a lake into it (CaveLava, a stone
			-- barrier around it): about one in 3-5 chunks with 2,000+ cells of caves gets one.
			Underground = { Enabled = true, Rarity = 1, Tries = 8, Depth = 30 },
			-- Minecraft's lake_lava_surface: one candidate per Rarity chunks of area (16 x 16 block
			-- cells), never in snowy or wet biomes, next to water or a deep cave (ordinary Lava).
			Surface = { Enabled = true, Rarity = 200 },
			-- No surface lake this close to the spawn (blocks).
			SpawnClearance = 128,
		},
		-- Oil wells (Generation/OilWells, BuildCraft's OilPopulate): one candidate per Spacing x
		-- Spacing blocks, a well with Chance, or the chance of its biome in Biomes, or Sea under
		-- the sea (undersea pockets: all of SeaSize, no geyser), never within SpawnClearance blocks
		-- of the spawn or next to a library structure. A deposit is a sphere of oil (CaveOil, the
		-- cave twin) of Radius centred Depth blocks down; large and medium wells on land get a
		-- geyser: a lake of Lake radius (less by the shore) and LakeDepth, and a spout Spout blocks
		-- into the air (BuildCraft's 16 and 6; 0: no geyser).
		OilWells = {
			Enabled = true,
			Spacing = 512,
			Chance = 0.12,
			Biomes = ({
				Desert = 0.6,
				Savanna = 0.5,
				WindsweptSavanna = 0.5,
				Plains = 0.45,
			} :: any) :: { [string]: number },
			Sea = 0.15,
			SeaSize = "Small",
			SpawnClearance = 256,
			Depth = { 20, 40 },
			-- (Spout 0: no geyser.)
			Sizes = {
				{ Name = "Large", Share = 0.25, Radius = { 8, 12 }, Lake = { 7, 10 }, Spout = 16 },
				{ Name = "Medium", Share = 0.5, Radius = { 5, 7 }, Lake = { 4, 7 }, Spout = 6 },
				{ Name = "Small", Share = 0.25, Radius = { 3, 4 }, Lake = { 0, 0 }, Spout = 0 },
			},
			LakeDepth = { 1, 3 },
		},
		-- While the camera is below the surface, the cave walls it can see into are meshed (in 16^3
		-- sections: World/SectionGraph's search through connected cave air, Streaming/CaveReach).
		-- Otherwise caves are treated as solid rock, which keeps the part count low.
		-- The search reaches RevealReach blocks along tunnels (to section centres; the cave view
		-- setting scales it, this is its value at RevealRadiusMax). 88 costs about what the old
		-- reveal sphere (80 blocks in tunnels) did: median 0.96x its parts over 29 caves on three
		-- seeds, at most 1.12x; 96 would cost 1.02x (at most 1.28x), 112 1.11x.
		RevealReach = 88,
		-- In big caverns (the Underlands) it reaches further: the open space around the camera
		-- (CaveReach.probe) gives a radius between these two, and the search reaches that plus a
		-- section. Caves only exist in full detail chunks, so more than their reach does nothing:
		-- underground they reach about Lod.UndergroundSplitDistanceL1 x 32 blocks (up to 15% less
		-- ahead of a moving camera: LodTree's hysteresis).
		RevealRadius = 64,
		RevealRadiusMax = 128,
		-- Sections the search reveals at most (the nearest; the Underlands' giant caverns).
		RevealBudget = 1500,
		-- The default of the Caves video setting: false hides caves until the camera can see into
		-- them (the search above); true ("Always Shown") meshes every cave of every full detail
		-- chunk with its walls, wherever the camera is (Streaming/ChunkStreamer). That costs about
		-- 4x the parts of full detail terrain (seed 12345, Config's view: +26k parts at the spawn,
		-- +60k in the mountains, +100k there underground) and a few hundred more lights.
		AlwaysShow = false,
		-- Seconds a section stays revealed after the search stopped reaching it.
		RevealHold = 2,
		-- Glow lichen carries one PointLight per 8 x 8 x 8 blocks (Meshing/GreedyMesher), on in
		-- every revealed cave (a few hundred, instead of one per lichen: 1,000-3,000). A number
		-- switches off the lights farther than that many blocks from the camera (Rendering/
		-- ChunkRenderer) on slow devices; the lichen still glows there (its speck is Neon).
		LichenLightDistance = math.huge,
		-- Lava carries one PointLight per 16 x 16 x 16 blocks of its drawn surface (Meshing/
		-- GreedyMesher; a light 15's 13.5 block reach, PartPool), about one a chunk on a lava sea:
		-- an Underlands sea revealed 128 blocks around the camera holds some 210. Only those within
		-- this many blocks of the camera are on (Rendering/ChunkRenderer; ~110 there at 96, ~30 at
		-- 48); the rest still glows (lava is Neon).
		LavaLightDistance = 96,
		-- Used instead on phones and tablets (Rendering/ViewSettings).
		Mobile = {
			RevealRadius = 48,
			RevealRadiusMax = 96,
			LichenLightDistance = math.huge,
			LavaLightDistance = 48,
		},
	},

	-- Water lakes and puddles on the surface (Generation/Lakes). Water sources at rest, always held
	-- in beside and below, so nothing flows until a player changes something next to them.
	Lakes = {
		-- Minecraft's lake_water (LakeFeature before 1.18): the lava lakes' box of blobs, water in
		-- its lower half, the bowl above it dug out, ice on top in frozen and snowy biomes. One
		-- candidate per Rarity chunks of area (16 x 16 block cells) on dry land, kept with its
		-- biome's weight in Biomes (others 1); never by water, a deep cave, a structure, an oil
		-- well or a lava lake (about 0.3-0.6 lakes per km²: rarer than lava lakes).
		Water = {
			Enabled = true,
			Rarity = 600,
			Biomes = ({
				Desert = 0.3,
				Savanna = 0.6,
				WindsweptSavanna = 0.5,
			} :: any) :: { [string]: number },
		},
		-- Puddles: water in place of the top block of Size columns (fewest, most) at the bottom of
		-- a dip, flooding out to a radius of Radius blocks (smallest, largest). One candidate per
		-- Spacing x Spacing blocks, a puddle with its biome's chance in Biomes or Chance (frozen and
		-- snowy biomes none). Full detail chunks only.
		Puddles = {
			Enabled = true,
			Spacing = 32,
			Chance = 0.05,
			Biomes = ({
				Jungle = 0.14,
				MushroomFields = 0.12,
				BirchForest = 0.1,
				Forest = 0.1,
				OldGrowthTaiga = 0.1,
				Taiga = 0.08,
				Plains = 0.05,
				Meadow = 0.06,
				WindsweptHills = 0.03,
				Savanna = 0.012,
				WindsweptSavanna = 0.008,
				StonyPeaks = 0.008,
				Desert = 0.005,
			} :: any) :: { [string]: number },
			Size = { 3, 20 },
			Radius = { 1.5, 3.5 },
		},
		-- No lake or puddle this close to the spawn (blocks).
		SpawnClearance = 24,
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
		-- SplitDistanceL1 while the camera is shut in underground (the cave view with
		-- Streaming/CaveReach.enclosed: below the terrain surface in a cave or under rock, not at the
		-- open bottom of a pit or a ravine), and for UndergroundSeconds after that, so walking in and
		-- out of a cave mouth does not rebuild chunks back and forth. Caves only exist in full detail
		-- chunks, so this is how far they can be seen: about 2 x this chunks (4: ~128 blocks, ~110
		-- ahead of a moving camera; 3: ~96), from the first selection underground on (LodTree.select).
		-- Measured with a camera in a cave near the spawn (seed 12345), with Caves' radii: 268 full
		-- detail chunks instead of 164, ~57,000 parts instead of ~47,000 (under the highest
		-- mountains, in the Underlands: ~139,000 instead of ~110,000, before far meshes).
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
		-- A jump of more than this (blocks) between two refreshes, or a teleport this far, drops
		-- the old area at once (teleport mode) instead of keeping it until the new one is ready.
		TeleportDistance = 128,
		-- Teleport mode (also the first load) ends once the 3x3 chunks under the player are shown
		-- and at most TeleportSettle nodes and builds are left, or after TeleportTimeout seconds.
		-- Far meshes and map tiles wait meanwhile.
		TeleportTimeout = 10,
		TeleportSettle = 16,
		-- Cave reveal, seam and plant remesh jobs in flight while generation has work (edits are
		-- never limited), so generation keeps the other workers.
		RemeshJobs = 4,
		-- A cave reveal pass changing at most this many sections goes live in one frame (a cave
		-- cap opening and the tunnel behind it together); bigger ones (entering a cave) as they come.
		RevealGroupSections = 96,
		-- A failed generation keeps the old terrain and is retried after this many seconds,
		-- doubling per failure up to RetryMax.
		RetryDelay = 0.5,
		RetryMax = 8,
		-- Far meshes are not built while more nodes than this wait for generation, or more
		-- section builds than BusyBuilds wait for the renderer.
		BusyJobs = 8,
		BusyBuilds = 24,
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
		-- Milliseconds per frame spent creating / recycling parts. With AutoBudget this is the
		-- base of an adaptive budget (Rendering/FrameBudget): lower while frames run longer than
		-- usual, up to 8 ms while work waits and frames have room, 12 ms while the player is
		-- frozen waiting for terrain.
		BuildBudgetMs = 4,
		AutoBudget = true,
		-- Edits (placing and breaking blocks) get their own milliseconds per frame, so they never
		-- wait behind loading.
		EditBudgetMs = 2,
		-- Frames old geometry stays in the workspace after its replacement went in (remeshed
		-- sections, water and glass too, LOD swaps, far meshes; lights go off at once). A part the
		-- engine draws a frame late would otherwise show the sky behind it for that frame. 0 swaps
		-- in one frame.
		SwapFrames = 2,
		-- Parts taken out of the workspace per frame (old nodes, teleports), parts per frame put in
		-- or taken out by swaps (one allowance for the streamer's LOD swap units and far meshes
		-- hiding or showing parts, which still move one node a frame), and milliseconds per frame
		-- giving parts back to the pool (or destroying them once it is full).
		UnparentPartsPerFrame = 3000,
		SwapPartsPerFrame = 6000,
		ReleaseBudgetMs = 1.5,
		-- Shadows on full detail chunks / on LOD chunks. Shadows also gives torches' and
		-- lanterns' light shadows, so it stops at walls (Rendering/PartPool; glowstone's cube
		-- casts one instead).
		Shadows = true,
		FarShadows = false,
		-- Recycled parts kept around for reuse.
		PoolLimit = 8000,
		-- Fades the edge of the view distance with Lighting fog (ignored if an Atmosphere exists).
		Fog = true,
		-- Draw the texture pack's textures (Shared/TexturePack; see Config.Textures). false: every
		-- block in its plain Roblox material and colour.
		Textures = true,
		-- Materials on distant chunks (the "Far Materials" setting): merged far levels keep their
		-- materials and textures, one far mesh per look (FarMeshes.LookMinShare and below), instead
		-- of plain SmoothPlastic in the colour each block averages to (its texture and tint). More
		-- MeshParts to build; off by default.
		FarMaterials = false,
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
			look (SmoothPlastic in the colour each block averages to, opaque water) so the swap is
			invisible.
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
			-- No builds while the camera moved faster than this on average (blocks per second) over
			-- the last SpeedWindow seconds: regions keep changing while it moves, and every
			-- MeshPart costs a long frame. Parts keep drawing meanwhile.
			MaxBuildSpeed = 2,
			SpeedWindow = 2,
			-- Studs each quad overlaps its neighbours (hides cracks where quads meet).
			Overlap = 0.05,
			-- Meshes stay off when, in the startup probe, building a full-size mesh makes frames this
			-- much longer than usual (ms; measured up to three times).
			MaxBlockingMs = 35,
			-- No new meshes while the shown ones hold this many triangles (a safety limit; the whole
			-- default view needs ~100k on hills and ~300k in the mountains).
			MaxLiveTriangles = 1000000,
			-- With Render.FarMaterials: a look (material + texture) gets its own MeshParts in a
			-- region when it covers at least LookMinShare of the region's drawn area, at most
			-- MaxLooks of them (the largest); the rest is drawn as LookRemainder: "plain"
			-- (SmoothPlastic in the colour it averages to) or "largest" (joined to the largest
			-- opaque look: that look's texture, tinted towards the colour each face averages to).
			-- UvStuds: studs per texture tile in the meshes' UVs (a block face).
			LookMinShare = 0.05,
			MaxLooks = 4,
			LookRemainder = "plain",
			UvStuds = 3,
		},
	},

	-- Textures (client; the pack itself is Shared/TexturePack) ---------------------------------------

	Textures = {
		-- Give every box of a textured block an odd size (in blocks) along each axis at full
		-- detail, so textures that tile from the centre of a face still show one whole tile per
		-- block. Only needed if your Studio check shows tiles centred on part faces (see README,
		-- "Block textures"): it costs about 20% more parts near the player.
		OddBoxes = false,
		-- Draw a block's own bottom texture (Grass: dirt) as an extra image on the bottom face of
		-- its parts. Bottoms are rarely seen; each image is one more instance per part.
		BottomFaces = false,
		-- Draw the side textures of blocks whose sides differ from their top (grass, logs,
		-- sandstone, cactus) as upright images instead of the MaterialVariant, in case the
		-- variant's sides come out turned in your game. Four more instances per part.
		SideImages = false,
		-- Measure each colour map's average colour in the game (EditableImage) when the pack has no
		-- Average for it; the game prints them, ready to paste into the pack.
		MeasureAverages = true,
		-- Check every image id (colour, normal, roughness and metalness maps) once at startup
		-- (ContentProvider) and name each one that fails; a colour map that fails draws the pack's
		-- missing texture instead.
		ValidateIds = true,
		-- Plants with a Sprite texture are drawn as two crossed images, as in Minecraft, instead of
		-- their boxes.
		Sprites = true,
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

	-- Weather (shared model, server clock and gameplay) ----------------------------------------------

	--[[
		Regional weather (Shared/Weather): storms drift over the world with a wind that turns
		slowly, raining or snowing by the biome and the altitude under them, thundering where they
		are heaviest. Everyone computes it from the seed and the weather clock (server World/
		WeatherServer publishes the clock as workspace attributes, like the day's), so nothing is
		sent while it runs. Operators change it with /weather clear|rain|thunder [duration] and
		/gamerule doWeatherCycle (Players/WeatherCommands, Players/TimeCommands).
	]]
	Weather = {
		-- false: always clear (no clouds, rain, snow or lightning anywhere).
		Enabled = true,
		-- Minecraft's doWeatherCycle game rule: false stops the weather clock (storms stand where
		-- they are, and a /weather override never runs out).
		Cycle = true,
		-- How fast the weather clock runs: 1 is 20 ticks a real second, whatever the day length;
		-- 2 moves and changes the storms twice as fast.
		Speed = 1,
		-- Seconds a /weather override takes to blend in and out (Minecraft's rain level moves
		-- 0.01 a tick: 5 s).
		BlendSeconds = 5,
		-- A new world's clock starts where its spawn stays clear for this many seconds
		-- (Minecraft's first rain waits 10 to 150 minutes); 0 starts it at 0.
		ClearStartSeconds = 300,
		-- Lightning (server World/Lightning, Minecraft's LightningBolt) in thunderstorms near
		-- players: one strike a player every MeanSeconds on average at full thunder (fewer where
		-- it is lighter), within Radius blocks, only where it rains (not in snow or deserts). A
		-- strike hurts the living within 3 blocks by Damage half hearts and sets them burning for
		-- BurnSeconds, and lights fires by Minecraft's rules (with doFireTick:
		-- Server.Fire.Tick). Clients within Distance blocks see the bolt and hear the thunder.
		Lightning = {
			Enabled = true,
			MeanSeconds = 20,
			Radius = 64,
			Damage = 5,
			BurnSeconds = 8,
			Distance = 1024,
		},
		-- Fog distance factor at full rain, snow and thunder (client: the fog comes closer).
		Fog = { Rain = 0.6, Snow = 0.4, Thunder = 0.45 },
		-- Blocks a second thunder travels (the client hears a strike that much later).
		SoundSpeed = 343,

		--[[
			What the player sees and hears of it (client Weather/): rain and snow around the camera,
			the clouds out to the view distance, the light, lightning, and the maps' weather mode
			(Map/WeatherLayer). Options > Weather... has Clouds and Weather (Off / Fast / Fancy).
			Images are Config values so they are easy to swap: any rbxassetid:// (or rbxasset://)
			works; the defaults are Roblox's built-in particle sparkle, a stand-in.
		]]
		-- Rain and snow (Weather/PrecipitationView, Minecraft's renderSnowAndRain): one strip a
		-- block column, facing the camera, within Radius (Fast, Fancy) blocks, from the column's
		-- roof (or the camera's height - radius) to the camera's height + radius. Length: blocks
		-- one tile of the image covers; Width: the streak's width (blocks); Speed: tiles a second it
		-- falls (if your rain rises, make it negative); Color { r, g, b }; Transparency: the
		-- streak's at full intensity (more see-through towards the disc's edge and in drizzle).
		Precipitation = {
			Radius = { 5, 10 },
			Rain = {
				Texture = "rbxasset://textures/particles/sparkles_main.dds",
				Length = 1.25,
				Width = 0.12,
				Speed = 7,
				Color = { 178, 196, 230 },
				Transparency = 0.25,
			},
			Snow = {
				Texture = "rbxasset://textures/particles/sparkles_main.dds",
				Length = 1,
				Width = 0.3,
				Speed = 0.9,
				Color = { 250, 252, 255 },
				Transparency = 0.1,
			},
			-- Seconds the intensity at the camera takes to follow the weather (time constant).
			Smoothing = 0.8,
			-- Block columns whose roof is looked up in one frame at most (a scan of loaded data).
			ScansPerFrame = 64,
		},
		--[[
			Clouds (Weather/CloudView, Weather/CloudLod): flat boxes in rings of detail out to the
			view distance, drifting with the wind. Altitude 320: above 9 in 10 of the land even in
			mountainous worlds (seed 12345: half the land below 82, 1 in 10 above 283, 1 in 20 above
			367), so most hills stay under them, but the great ranges (up to ~900) push through as
			JJThunder's peaks do; rain lowers a cloud's base by Drop and thickens it by
			RainThickness, thunder raises a tower of up to Tower blocks (anvils seen from far off).
			Fancy: Cell-block cells, Cells across a ring, Thickness thick, rain shafts under rain
			clouds from ring ShaftLevel on (over ShaftMin precipitation); Fast: one flat layer of
			cells twice the size, half as many rings' cells, no towers or shafts. CoverBase: the
			share of a clear sky that still has clouds (Minecraft always has some); Wavelength: the
			size of a fair-weather cloud. Transparency 0 is cheapest; ShaftTransparency is a
			shaft's (heavy, light). PartsPerFrame: parts placed, moved or removed in a frame at
			most; a ring is planned again every RefreshSeconds x 2^ring (or when the camera moved
			two of its cells), one ring a frame. Colours: Color (fair weather) to Dark at full
			thunder; ShaftColor the rain shafts'.
		]]
		Clouds = {
			Altitude = 320,
			Thickness = 6,
			Cell = 16,
			Cells = 24,
			FastCells = 16,
			CoverBase = 0.22,
			Wavelength = 96,
			Drop = 32,
			RainThickness = 28,
			Tower = 160,
			Step = 4,
			ShaftLevel = 1,
			ShaftMin = 0.4,
			Transparency = 0.12,
			ShaftTransparency = { 0.72, 0.84 },
			Color = { 248, 250, 255 },
			Dark = { 38, 40, 48 },
			ShaftColor = { 108, 116, 132 },
			Material = "SmoothPlastic",
			CastShadow = false,
			PartsPerFrame = 48,
			RefreshSeconds = 4,
			MaxLevels = 8,
		},
		-- The light (Rendering/LightingController, Weather/WeatherSky): Minecraft's darkening by
		-- rain and thunder on the sky's light; CoverSun of the sun's light hidden at full cloud
		-- cover; a grading of the picture (saturation down by Saturation in rain, ThunderSaturation
		-- more in thunder, contrast by Contrast, a cool Tint); Smoothing: seconds the light takes to
		-- follow (time constant).
		Sky = {
			CoverSun = 0.3,
			Saturation = 0.28,
			ThunderSaturation = 0.18,
			Contrast = 0.08,
			Tint = { 226, 234, 255 },
			Smoothing = 1.5,
		},
		-- Lightning on the client (Weather/LightningView): the bolt's colour, its glow, the flash of
		-- the sky (ColorCorrection brightness at the strike, less with distance and indoors) and
		-- the light at the struck point; thunder within Distance (above) is heard ThunderDelay
		-- (Shared/Weather.thunderDelay) later.
		Bolt = {
			Color = { 214, 220, 255 },
			Glow = 0.75,
			Flash = 0.45,
			LightRange = 60,
		},
		-- The maps' weather mode (Map/WeatherLayer): grid cells across at most (minimap, world map),
		-- seconds before a picture is drawn again, biome lookups for snow per frame, cells painted
		-- per frame at most (a picture is spread over frames: ~0.7 us a cell with native code,
		-- ~2.4 us interpreted), and the milliseconds a map may paint in a frame (bands are sized
		-- to it by what the last one cost: a phone paints thinner ones; both maps open, twice it).
		Map = {
			MiniCells = 48,
			WorldCells = 96,
			RefreshSeconds = 3,
			LookupsPerFrame = 96,
			CellsPerFrame = 1536,
			FrameMs = 0.75,
		},
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
		-- Shift takes that key away from Roblox's shift lock (Right Shift still toggles it). The
		-- keyboard key is the default of the Sprint / Sneak key bindings (Options > Controls > Key
		-- Binds, Shared/KeyBindings), the gamepad buttons stay these.
		SprintKeys = { "LeftControl", "ButtonL3" },
		SneakKeys = { "LeftShift", "ButtonB" },
		-- true: the sprint key turns sprinting on and off (Minecraft's "Sprint: Toggle"; while on,
		-- moving forward sprints). false: hold the key.
		ToggleSprint = true,
		-- true: the sneak key turns sneaking on and off (Minecraft's "Sneak: Toggle"); false (its
		-- default): hold it. The touch Sneak button always toggles.
		ToggleSneak = false,
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

	-- The title screen, operators and the world's settings -------------------------------------------

	--[[
		Minecraft's title screen and Create World screen (client Ui/MainMenu; server
		Players/WorldMenu, Players/Operators, World/WorldInfo; the rules: Shared/WorldSettings).
		The first player to join a server becomes its operator (Minecraft's ops; Gameplay.Admins,
		the game's owner and Studio sessions always are; see AutoOperator) and creates the world
		from the menu: its name, game mode, difficulty, commands, world type
		(Generation/WorldTypes), seed and structures. Nothing of the world exists before that,
		and nobody gets a character.
	]]
	MainMenu = {
		-- false: no title screen; the server creates the world at once from `World` below (and
		-- Seed), and players join straight into it (characters load as Roblox's usual).
		Enabled = true,
		-- true: until the world exists, the first player to join is made an operator (and the one
		-- here longest when the last operator leaves), so somebody can create it; once it exists
		-- nobody becomes one by being here (operators /op others). false: only Gameplay.Admins,
		-- the game's owner and Studio sessions are operators, so only they can create the world
		-- (for a private game). Ignored with Enabled false (the old rule: those, and /op).
		AutoOperator = true,
		-- The title screen's corners (Minecraft's version and copyright lines).
		Version = "IceVoxel (Minecraft 1.20.1 style)",
		Credits = "Not an official Minecraft product",
	},
	-- The world the server creates at once with MainMenu.Enabled false, and the Create World
	-- screen's first choices otherwise (its game mode: Gameplay.DefaultGameMode).
	World = {
		Name = "New World",
		-- A Generation/WorldTypes id: "default", "superflat", "void", "singleBiome", "largeBiomes",
		-- "debugBlocks", "debugStructures", "debugBiomes" (unknown ids make the Default).
		Type = "default",
		-- The type's options with the title screen off (its `settings` keys, e.g. { preset =
		-- "Bedrock,2*Dirt,Grass;Plains" } for superflat or { biome = "Desert" } for a single
		-- biome; undeclared keys are dropped, missing ones take the type's defaults).
		Options = {} :: { [string]: string | number | boolean },
		-- Minecraft's difficulty: "Peaceful" (no monsters spawn), "Easy", "Normal" or "Hard" (fire
		-- spreads a little faster on harder ones, Server.Fire).
		Difficulty = "Normal",
		-- Minecraft's Allow Commands (cheats): true lets every player use the operators' commands
		-- (/gamemode for others, /time, /effect, /summon...); false keeps them to operators.
		AllowCommands = false,
		-- Generate Structures (trees always grow; library structures need Structures.Generate).
		Structures = true,
	},

	-- Game modes, inventories and item drops ---------------------------------------------------------

	Gameplay = {
		-- Game mode of players when they join (Shared/GameMode): "Survival" (blocks are mined over
		-- time and drop as items, placing uses them up), "Creative" (every block, instant breaking,
		-- flying), "Adventure" (survival without breaking or placing; menus still open) or
		-- "Spectator" (flies through everything, invisible, changes nothing).
		DefaultGameMode = "Survival",
		-- Who may switch their own game mode, with the /gamemode chat command or the F3 + F4 game
		-- mode switcher and F3 + N (Minecraft's permission level 2): true = everyone, false =
		-- nobody, or a list of user ids. Admins, the game's owner and Studio sessions always may.
		GameModeCommand = (true :: any) :: boolean | { number },
		-- Who may change other players' game modes (/gamemode creative Name) and the time
		-- (/time set|add, /gamerule doDaylightCycle): user ids, besides the game's owner and
		-- Studio sessions.
		Admins = {} :: { number },
		-- Keep the inventory when dying (Minecraft's keepInventory rule); otherwise it drops.
		KeepInventory = false,
	},

	-- Thirst and body temperature (Tough As Nails) ---------------------------------------------------

	--[[
		The Tough As Nails mod's survival mechanics (TAN for Minecraft 1.20; Shared/ToughAsNails,
		server Players/ToughAsNails): thirst (0..20 with hydration and exhaustion, Minecraft's
		FoodData in water's place) and body temperature (-10..10 in five zones, ICY, COLD, NEUTRAL,
		WARM, HOT, drifting a step at a time towards what the surroundings say), with TAN's Climate
		Clemency for a gentle start. Survival and adventure players only: creative and spectator
		players' stats stand still and never hurt.
	]]
	ToughAsNails = {
		-- Thirst: drinking, dehydration at 0 and the droplets over the hotbar.
		Thirst = true,
		-- Body temperature: the gauge over the hotbar, hypothermia and hyperthermia.
		Temperature = true,
		-- With Thirst on, health comes back only while thirst is 18 or more: half a heart every 80
		-- ticks for 6 exhaustion (Minecraft's natural regeneration, thirst for food). This replaces
		-- Roblox's own regeneration (the character's Health script). false keeps Roblox's. With
		-- Temperature on, neither heals while the body is fully frozen or overheated.
		ThirstRegeneration = true,
		-- Dehydration (thirst 0) takes half a heart every 120 ticks while health is above this many
		-- half hearts (Minecraft's starvation on normal difficulty: 1; 0 = to death, hard).
		DehydrationFloor = 1,
		-- Right clicking a water source with an empty hand drinks from it (TAN's hand drinking).
		HandDrinking = true,
		-- Thirst exhaustion each tick in the HOT zone (sweating): 0.005 is a thirst point (half a
		-- droplet) every 40 s once the hydration is gone, a whole droplet every 80 s.
		HotExhaustion = 0.005,
		-- Ticks between two steps of the body temperature (-10..10) away from neutral (0) towards
		-- its target: 140 is 7 s a step, so from neutral the icy edge (-8) takes 56 s in the
		-- coldest place, and the hot edge (8) as long in the hottest.
		ChangeTicks = 140,
		-- Ticks between two steps back towards neutral (warming up at a fire, cooling off in the
		-- shade): from the coldest (-10) to NEUTRAL's edge (-2) at 70 is 28 s.
		RecoverTicks = 70,
		-- TAN's Climate Clemency, ticks of it on joining (6000: 5 minutes) and after respawning
		-- (1200: a minute). While it lasts the temperature's target stays within NEUTRAL (no
		-- hypothermia or hyperthermia), thirst drains at half the rate and dehydration doesn't
		-- hurt. It counts down only in survival and adventure. 0 turns either off.
		ClemencyTicks = 6000,
		RespawnClemencyTicks = 1200,
		-- Ticks the player stays wet after leaving water (being wet cools by 3 steps).
		WetTicks = 100,
		-- Blocks around the player (a cube this many blocks out each way) searched for heat and
		-- cold sources, once a second.
		ProximityRadius = 5,
		-- Blocks that warm the player within ProximityRadius (3 steps; 5 within 2 blocks): fluid
		-- names (every level and the cave twin) or block names. A name no block has is skipped
		-- with a warning, so a block may be listed here before it exists. Lit furnaces and working
		-- Heat and Combustion Generators warm too (server Players/ToughAsNails registers them).
		-- Within 2 blocks of one, cold sources no longer cool (a fire beats the snow around it).
		HeatingBlocks = { "Lava", "Fire", "Campfire" },
		-- Blocks that cool the player by 3 steps within ProximityRadius.
		CoolingBlocks = { "Ice", "PackedIce", "BlueIce", "Snow" },
	},

	-- Progression: knowledge, Ages and the skill tree -----------------------------------------------

	--[[
		Knowledge (this game's experience: Minecraft's curve, the green bar over the hotbar), the
		Ages (Stone, Iron, Industrial, Electric, Atomic: each opens recipes) and the skill tree (a
		point a level, small perks). Shared/Progression has the rules and numbers, server
		Players/Progression plays them out. Survival and adventure players earn knowledge;
		creative players have every recipe and earn nothing.
	]]
	Progression = {
		-- Knowledge, Ages and skills at all (off: no bar, no gates, no perks, nothing saved).
		Enabled = true,
		-- Crafting and smelting results of a later Age (or of a skill not unlocked) are locked.
		GateRecipes = true,
		-- Keep each player's progress between sessions (DataStore "IceVoxelProgress_v1"). In
		-- Studio this needs API access, as Settings.Save.
		Save = true,
		-- Seconds between saves of a player whose progress changed (and on leaving and shutdown).
		SaveInterval = 120,
		-- Points a minute at most from repeated actions together (ores, logs, smelting, crafting,
		-- mobs; the knowledge perks included), each also wearing off when repeated
		-- (Progression/Knowledge's fatigue). Discoveries are not limited.
		RepeatBudget = 20,
		-- Share (0..1) of the progress into the current level lost on death. Levels, the Age,
		-- skills and discoveries are never lost; 0 keeps everything (knowledge is learning).
		DeathLoss = 0,
		-- Seconds between two looks at the biome a player stands in (a first visit is a discovery).
		BiomeInterval = 2,
		-- Opens and closes the skill tree (Enum.KeyCode names; touch: the button over the gear). The
		-- key is the Skill Tree key binding's default (Options > Controls > Key Binds).
		Key = "K",
		GamepadButton = "DPadLeft",
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

	-- Mobs (Shared/Entities/MobList: cows, sheep, pigs, chickens, zombies, skeletons, creepers,
	-- spiders; server Mobs/). They tick within Server.SimulationRadius chunks of a player and
	-- freeze beyond.
	Mobs = {
		-- false: no mobs at all (nothing spawns, ticks or is sent; /summon says so).
		Enabled = true,
		-- false: no natural spawning (/summon still works).
		Spawning = true,
		-- Most mobs at once in the world, and of each category (Minecraft's mob caps, scaled to the
		-- simulated area) ...
		MaxMobs = 300,
		MaxPassive = 120,
		MaxHostile = 160,
		-- ... and within 128 blocks of each player.
		PassiveCap = 10,
		HostileCap = 15,
		-- Ticks between spawning rounds: monsters every second, creatures every 400 ticks
		-- (Minecraft's spawnPersistent), each round `Attempts` packs a player.
		HostileInterval = 20,
		PassiveInterval = 400,
		Attempts = 3,
		-- Blocks from a player a pack may spawn (Minecraft: never within 24).
		SpawnDistance = { 24, 44 },
		-- A creature with no player within 128 blocks for this many ticks is dropped (5 minutes):
		-- creatures don't despawn, but the server keeps no mob it can't reach.
		ForgetTicks = 6000,
		-- Players see mobs within this many blocks; mobs are sent 10 times a second
		-- (SyncTicks 2) while they move.
		TrackingDistance = 64,
		SyncTicks = 2,
		-- Attacks a player may send per second (anti-spam; Minecraft's fastest is the hand's 4).
		AttacksPerSecond = 10,
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
			-- The background music (Config.Music), which no event uses.
			music = 1,
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
		-- Footsteps (the player's and others'), interface clicks and the cave moods (client).
		Footsteps = true,
		Interface = true,
		Ambient = true,
	},

	-- Music (client; the tracks are in Shared/Sounds/MusicList) --------------------------------------

	--[[
		Minecraft's background music (MusicManager): a track now and then, at random, never during
		another. Surface tracks above ground, cave tracks in caves (the sky light reaching the
		camera, Rendering/LightingController.skyExposure); a track of the other kind fades out when
		the player goes underground or comes back up, and one of the new kind follows. A "Now
		Playing" toast shows each track's title in the top right corner.
	]]
	Music = {
		Enabled = true,
		-- Sound.Volume of a track, times the master and music volumes (Config.Sounds and the
		-- player's settings).
		Volume = 0.5,
		-- Seconds before the first track after joining (Minecraft: 100 ticks), and between the end
		-- of one track and the next: a random wait from MinDelay to MaxDelay (Minecraft's music.game:
		-- 12000 to 24000 ticks, 10 to 20 minutes).
		FirstDelay = 5,
		MinDelay = 600,
		MaxDelay = 1200,
		-- In a cave below this sky exposure, on the surface again above SurfaceExposure (a gap, so
		-- the edge of a cave mouth doesn't flip it), each for SwitchSeconds in a row.
		CaveExposure = 0.2,
		SurfaceExposure = 0.5,
		SwitchSeconds = 5,
		-- A track of the other kind fades out over FadeSeconds; the new kind's starts after a
		-- random wait up to SwitchDelay seconds (Minecraft waits up to half its MinDelay when music
		-- has to change).
		FadeSeconds = 4,
		SwitchDelay = 3,
		-- The Now Playing toast (and the player's Music Toasts setting): seconds it stays.
		Toast = true,
		ToastSeconds = 5,
		-- Seconds a track may take to load before it is skipped (with a warning).
		LoadTimeout = 20,
	},

	-- Player settings (client menu, server store) ----------------------------------------------------

	--[[
		The Options menu (Ui/SettingsScreen; what it holds: Shared/PlayerSettings). Its presets and
		defaults come from the settings above (High is this file's view, Low its Mobile values), and
		a player's choices apply on top of them on that player's client only.
	]]
	Settings = {
		-- Keep each player's choices between sessions in a DataStore, one profile per kind of
		-- device (desktop, touch, console). In Studio this needs API access, as SaveWaypoints.
		Save = true,
		-- Opens and closes the menu (Enum.KeyCode names; touch: the gear beside the hotbar, and
		-- the gear in the inventory). The key is the Options key binding's default.
		Key = "P",
		GamepadButton = "DPadRight",
		-- Seconds after the last change before the costly ones apply (view distance, caves,
		-- plants, shadows, textures, far meshes), and before the choices are sent to the server.
		ApplyDelay = 0.4,
		SaveDelay = 1.5,
		-- Seconds a joining client waits for its saved choices before it starts loading terrain.
		LoadWait = 1,
	},

	-- Saving worlds (server World/WorldSave, the codecs in server Save/) ---------------------------

	--[[
		Worlds are saved in the DataStore `StoreName`: an index of the worlds, a record per world
		(its settings, clock, operators, the regions and players saved), its edits and block
		state in regions of RegionChunks x RegionChunks chunks (one key each, split into parts
		near the 4 MB a key holds), and each player's record in it. In Studio this needs API
		access (Game Settings > Security > Enable Studio Access to API Services), as SaveWaypoints;
		without it worlds last for the session and the title screen says so.
	]]
	Save = {
		-- Save worlds at all (off: every world is the session's only; Load World stays greyed).
		Enabled = true,
		-- The DataStore (a new name starts afresh; the old one stays untouched).
		StoreName = "IceVoxelWorlds_v1",
		-- Seconds between automatic saves (Minecraft's autosave: 6000 ticks, 5 minutes), each
		-- writing only what changed. 0 saves only on /save-all and at shutdown.
		Interval = 300,
		-- The most a world may take in the store (bytes, all its keys); a save that would go over
		-- is refused (the world plays on, unsaved) and operators are told. Operators are warned in
		-- the chat once a save passes WarnShare of it.
		MaxWorldBytes = 64 * 1048576,
		WarnShare = 0.8,
		-- Roblox's limit per key (4,194,304 characters), and the bytes of text a key is filled to
		-- before a region goes on in another part (room for the record around it).
		KeyLimit = 4194304,
		MaxKeyBytes = 4000000,
		-- Chunks per region side (32: Minecraft's region files, 512 x 512 blocks a key).
		RegionChunks = 32,
		-- Seconds without a heartbeat after which another server may take a world over (a server
		-- that crashed); the server holding it renews its lock every third of that.
		LockTimeout = 180,
		-- Also saved: dropped items, and farm animals (cows, sheep, pigs, chickens; monsters are
		-- not kept, as they despawn anyway).
		Items = true,
		Mobs = true,
		-- With MainMenu.Enabled off, the server opens the world played last (when no other server
		-- has it open) instead of making a new one from `World`.
		LoadLatest = true,
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
		-- Minecraft's randomTickSpeed: blocks picked at random per 16 x 16 x 16 section of every
		-- chunk within SimulationRadius of a player, each tick (World/RandomTicker): grass spreads,
		-- leaves cut off from their logs decay, saplings grow, herbs spread. 0 turns random ticks
		-- off.
		RandomTickSpeed = 3,
		-- Fast leaf decay: a leaf whose tree lost its logs (no log within 6 blocks through leaves)
		-- decays MinDelay..MaxDelay ticks after a neighbour changed, so a felled tree's canopy
		-- falls apart in a few seconds instead of Minecraft's minutes. Leaves players placed never
		-- decay.
		LeafDecay = { MinDelay = 4, MaxDelay = 12 },
		-- Chance per random tick that a sapling with daylight grows into its tree (Minecraft:
		-- 1/7 a stage, two stages): about 16 minutes on average.
		SaplingGrowth = 1 / 14,
		-- Chance per random tick that a herb (Mint, Wild Ginger) spreads to a free spot next to it
		-- while fewer than 5 of it grow within 4 blocks (Behaviours/Herb, Minecraft's mushroom
		-- spreading at 1/25): a try about every 9 minutes from each.
		HerbSpread = 1 / 8,
		-- Generated chunks the server keeps in memory beyond the ones near players.
		CacheSize = 192,
		-- Max chunks the server generates per frame while preloading around players.
		GenerationsPerFrame = 1,
		-- Fire (Behaviours/Fire, Minecraft's FireBlock): `Tick` is the doFireTick game rule (off:
		-- fire neither spreads, burns blocks nor goes out by itself, and lava lights nothing);
		-- `Difficulty` is the world's (0 peaceful, 1 easy, 2 normal, 3 hard), which makes fire
		-- spread a little faster (FireBlock.tick: + difficulty x 7 on the ignite odds); the
		-- world's settings set it when it is created (World.Difficulty, the Create World screen).
		Fire = { Tick = true, Difficulty = 2 },
	},
	-- Explosions (Shared/World/Explosion, Minecraft's) and burning fuel setting them off (server
	-- World/FuelBlast, World/Explosions): fuel touching fire or lava explodes, harder the more of
	-- it is connected.
	Explosions = {
		-- Power of a blast of `v` buckets of fuel: BucketPower x cube root of v (the cube root
		-- scaling of blast radius with charge), so one bucket is TNT (4), 8 buckets 8, 27 buckets
		-- 12. Between MinPower and MaxPower (a charged creeper is 6, Minecraft's biggest
		-- vanilla blasts 7-8).
		BucketPower = 4,
		MinPower = 1,
		MaxPower = 12,
		-- What a flowing (or falling) fuel cell counts as: its fill (8 - level) / 8 of a bucket
		-- times this. Flowing fluid is a thin sheet Minecraft makes out of nothing, so a puddle
		-- spread from one bucket (113 cells) counts about 3.6 buckets, not 43.
		FlowingShare = 1 / 16,
		-- Flowing fuel (not a source) burns like a fuse: touched by fire or lava it turns into fire
		-- this many ticks later, lighting the next flowing cell (5 blocks a second), up the trail
		-- to its source, which explodes.
		FuseTicks = 4,
		-- Fuel cells one ignition measures at most (a flood fill through the connected fuel);
		-- fuel beyond them catches from the fire the blasts leave.
		MaxCells = 4096,
		-- A connected body goes off as one blast per ClusterSize-wide cube of it, each with the
		-- power of the fuel in that cube, ...
		ClusterSize = 4,
		-- ... cubes holding less than this many buckets just flash into fire, ...
		MinBlastVolume = 0.5,
		-- ... staggered by the distance (through the fuel) from where it caught: a flame front of
		-- this many blocks per tick.
		ChainBlocksPerTick = 1.5,
		-- Cost bounds per server tick: ignitions measured, blasts set off, and block reads of
		-- their rays (at least one blast a tick always goes; TNT in open air reads about 9 000
		-- blocks, a power 12 blast about 26 000, some 7 ms interpreted). What doesn't fit waits
		-- for the next tick.
		MaxIgnitionsPerTick = 4,
		MaxBlastsPerTick = 8,
		RayBudget = 60000,
		-- Players this close (blocks) see and feel a blast (Minecraft sends its explosion packet
		-- within 64 blocks); clients shake the camera within ShakeDistance x power.
		EffectDistance = 64,
		ShakeDistance = 4,
	},
	-- TNT (Minecraft 1.20.1's TntBlock and PrimedTnt; server Behaviours/Tnt): lit by flint and
	-- steel, fire (lava lights the fire) or a blast, it falls while its fuse burns, then explodes.
	Tnt = {
		-- Ticks from lighting to the blast (PrimedTnt's 80: 4 s). A blast lights TNT with a short
		-- fuse instead: rand(FuseTicks / 4) + FuseTicks / 8 (10..29 ticks), so chains ripple.
		FuseTicks = 80,
		-- Minecraft's TNT: power 4, no fire.
		Power = 4,
	},
	-- The Nuke (this game's, mod style; server Behaviours/Tnt and World/Nuke): lit like TNT, it
	-- wails for FuseTicks, then digs a crater no ray explosion could (Minecraft's rays thin out and
	-- cost too much at such powers).
	Nuke = {
		-- Ticks from lighting to the blast (10 s); a blast lights it with the short fuse rule.
		FuseTicks = 200,
		-- Ticks between the alarm's beeps while it is lit.
		AlarmTicks = 20,
		-- The crater: a sphere of this radius (blocks) where a block goes when its blast resistance
		-- is below Strength x (1 - distance / radius): dirt to the rim, stone to 0.9 of it,
		-- obsidian, bedrock and fluids (100) never. The radius wanders by up to Ragged of itself
		-- with 3D noise of wavelength RaggedScale (blocks), plus a block of crumble, so the rim is
		-- ragged.
		Radius = 24,
		Strength = 60,
		Ragged = 0.2,
		RaggedScale = 9,
		-- Scorched around the crater, out to ScorchRadius blocks sideways (and the crater's radius
		-- up and down): grass turns to dirt or coarse dirt, leaves, plants, glass and snow (blast
		-- resistance below ScorchResistance) are blown away, and one air cell over an opaque block
		-- in FireOdds catches fire.
		ScorchRadius = 40,
		ScorchResistance = 0.45,
		FireOdds = 6,
		-- Cost bounds per server tick: block edits (each one replicated: 12 bytes to every client)
		-- and block reads. The crater grows outwards from the centre as the work goes.
		EditsPerTick = 500,
		ReadsPerTick = 16000,
		-- Players and items: Minecraft's explosion damage and push with this power (reach 2 x
		-- power), so the open within about 50 blocks is deadly; players within EffectDistance see
		-- the flash, the fireball and the mushroom cloud (blasts of LookPower and more look like
		-- this), and feel it within Explosions.ShakeDistance x power.
		Power = 28,
		EffectDistance = 256,
		LookPower = 16,
	},
	-- Status effects (Shared/Effects, server Players/Effects, client Player/EffectState): Minecraft
	-- 1.20.1's MobEffects (Speed, Haste, Strength, Regeneration, Poison, Night Vision...), what
	-- oil and fuel do to a player (Oil Coated, Fuel Soaked), the potions and /effect.
	Effects = {
		-- Oil and fuel give their effects (FluidList `effects`: Slowness II and Oil Coated, Nausea,
		-- Poison and Fuel Soaked; water washes the coat off). Off, the fluids leave players be;
		-- potions and /effect still work.
		FluidEffects = true,
		-- The effect icons in the top right corner (and the list beside open screens). Off, Tough
		-- As Nails' status row over the hotbar shows Climate Clemency, Internal Warmth and Chill.
		Hud = true,
		-- Nausea's wobble at full strength: the camera's roll (degrees) and the field of view's
		-- sway (a share of it), times the FOV Effects setting (Minecraft's Distortion Effects).
		NauseaRoll = 7,
		NauseaFov = 0.1,
		-- Night Vision lights places closed to the sky up to this grey (0..255, Lighting.Ambient):
		-- the darkest cave reads like an overcast day.
		NightVisionAmbient = 150,
	},
}

return Config

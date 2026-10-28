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

	-- Mineshafts (Generation/Mineshafts): Minecraft's abandoned mineshafts, at a depth under the
	-- local surface, and overgrown ones in humid biomes, some with an entrance shaft open to the
	-- sky and a rope all the way down. They follow Generate Structures (off with it, and with
	-- Structures.Generate false).
	Mineshafts = {
		Enabled = true,
		-- One candidate start room per Grid x Grid blocks, kept with Chance: about one mineshaft
		-- per 256 x 256 blocks (Minecraft's 0.4% of chunks, 15 per km²).
		Grid = 128,
		Chance = 0.25,
		-- The start room's floor this many blocks under its column's surface (fewest, most).
		Depth = { 28, 64 },
		-- No mineshaft block below this height (the caves' lava seas lie below Caves.LavaLevel).
		MinY = 16,
		-- Blocks of ground kept above every piece (under each column's surface).
		Cover = 6,
		-- Minecraft's piece grammar: pieces at most MaxDepth steps from the start room, starting
		-- within Extent blocks of its corner.
		MaxDepth = 8,
		Extent = 80,
		-- The chance a mineshaft is overgrown, by its start's biome humidity: none at
		-- OvergrownHumidity[1] or drier, rising to OvergrownChance at OvergrownHumidity[2].
		OvergrownHumidity = { 0.1, 0.6 },
		OvergrownChance = 0.8,
		-- The chance an overgrown mineshaft has an entrance shaft from the surface, and how far
		-- from the spawn an entrance keeps (blocks).
		EntranceChance = 0.5,
		SpawnClearance = 32,
	},

	--[[
		Overgrown cities and the roads between them (Generation/Cities): the zombie apocalypse's
		ruins, decided from the raw terrain only. They follow Generate Structures and the world's
		Ruins setting (WorldTypes `ruins`; a world saved before it reads as off unless OldWorlds).
	]]
	Cities = {
		Enabled = true,
		-- true: worlds saved before the ruins also get them, in ground nobody has edited (cut and
		-- fill next to an old world's edited chunks would leave cliffs at the seams).
		OldWorlds = false,
		-- One candidate city per Grid x Grid blocks, kept with Chance, then only where Accept of
		-- the 25 lattice samples over its footprint are fit to build on (Tries spots per cell, at
		-- the end of this section). 0.36 with 4 tries: 6-11 sites per 100 km² where a third or
		-- more of the land is hills and plains (tests/spec/Cities: 11.0, 6.8 and 8.5 on seeds
		-- 12345, 1 and 99; a 20 km square mostly of mountains or sea has fewer).
		Grid = 1024,
		Chance = 0.36,
		Accept = 21,
		-- Footprint half-widths (blocks), and the margin blended back to the raw terrain.
		MinRadius = 48,
		MaxRadius = 224,
		Margin = 24,
		-- The street grid: a block every Block blocks, streets Street wide.
		Block = 32,
		Street = 7,
		-- Floors: at most MaxFloors, full interiors up to FullFloors, FloorHeight blocks each.
		MaxFloors = 12,
		FullFloors = 4,
		FloorHeight = 4,
		-- Where a city may stand: the plateau's slope and height above the sea.
		MaxSlope = 10,
		MinAboveSea = 3,
		-- LOD levels buildings are drawn at (massing beyond 0; nothing beyond this).
		LodLevels = 4,
		-- Decay: ruin, overgrowth and wrecked cars. A city's overgrowth o is Overgrowth times its
		-- biome's humidity factor ((humidity + 0.8) / 1.4, at least OvergrowthFloor: a desert or
		-- plains town still greens, a jungle one most): 0.4 to 0.8. Trees: a vegetation spot on
		-- the city's grass (parks, plazas, the streets' grass patches off the sidewalks and the
		-- wrecks) grows one of its biome's trees at least Trees x o of the time, whatever the
		-- biome's own chance (a plains town's 0.012 grew next to none); a desert has none (its
		-- cactus takes no root on grass), so a desert town grows next to no trees. (Overgrowth 0.6
		-- and a floor of 0.15 left 94% of a taiga city's streets bare asphalt, and a plains town at
		-- o 0.24.)
		Ruin = 0.55,
		Overgrowth = 0.8,
		OvergrowthFloor = 0.5,
		Trees = 0.5,
		Cars = 0.08,
		-- Bunkers under each city (fewest, most), in shed lots.
		Bunkers = { 1, 2 },
		-- Plan caches (entries): existence cells, site plans, road links, 256 block tiles.
		Caches = { Cells = 1024, Sites = 32, Links = 64, Tiles = 512 },
		Roads = {
			Enabled = true,
			-- Asphalt Width wide, a Shoulder each side, blended into the terrain over Blend.
			Width = 5,
			Shoulder = 1,
			Blend = 8,
			-- Links to the nearest city in each quadrant within LinkCells cells, wobbling up to
			-- Wobble blocks, sampled every Step, graded to at most MaxGrade.
			LinkCells = 2,
			Wobble = 48,
			Step = 8,
			MaxGrade = 1 / 6,
			-- A link is dropped where it would cut or fill more, or cross more water, than this.
			MaxCut = 24,
			MaxFill = 24,
			MaxWater = 48,
			-- Roads draw at LOD 0..SurfaceLevels and cut and fill at 0..CutLevels; none beyond.
			SurfaceLevels = 2,
			CutLevels = 3,
			-- Decay: cracks, overgrown patches (Grass and Moss Block on Overgrown x o of the
			-- asphalt, a fifth to two fifths, and half again of the sidewalks; 0.12 left 94-99%
			-- of the streets and roads bare), potholes and wrecked cars.
			Cracks = 0.25,
			Overgrown = 0.55,
			Potholes = 0.02,
			Cars = 0.004,
		},
		-- Spots (a size and a centre) tried per kept cell until one fits.
		Tries = 4,
	},

	-- Hidden bunkers (Generation/Bunkers): concrete rooms under a steel hatch, in the wild and under
	-- the cities' sheds. They follow Generate Structures and the Ruins setting, as the cities do.
	Bunkers = {
		Enabled = true,
		-- One candidate per Grid x Grid blocks, kept with Chance (0.35, was 0.3: seas and mountains
		-- leave many cells without a site, and 0.3 measured 0.22 per km² on seed 777's coasts;
		-- 0.35 measures 0.38-0.61 on five seeds, at most 0.59 on dry land).
		Grid = 768,
		Chance = 0.35,
		-- The floor this many blocks under the hatch (fewest, most), and its rooms (a city's shed
		-- drops some where its town is short of room, down to the bunks and the storeroom).
		Depth = { 9, 16 },
		Rooms = { 3, 6 },
		-- Chances a bunker is lit and overrun; no bunker within SpawnClearance blocks of the spawn;
		-- hatch columns tried per cell (24, was 16: a coastal cell's land is found more often).
		Lit = 0.8,
		Overrun = 0.15,
		SpawnClearance = 64,
		Candidates = 24,
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
		-- Fades the view distance's edge into the sky with the Lighting Atmosphere IceVoxel drives
		-- (Lighting.Atmosphere below; the Fog setting's default). false: no haze (Density 0).
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

	-- Seasons (shared calendar and climate, server clock, snow, rooms) -------------------------------

	--[[
		Don't Starve's seasons: Autumn, Winter, Spring and Summer, each Lengths days, one calendar
		every machine works out from the day time and a published offset (Shared/Seasons/Calendar;
		server World/SeasonClock keeps it and saves it with the world). A world starts in Autumn.
		Every quantity a season changes (the climate, the weather's biases, the sun's day share,
		plant growth, foliage colours) blends over BlendDays centred on the turn, so nothing
		steps. Winter's days are shorter and summer's longer by warping the sun (DaylightScale),
		never the clock. false: none of it, the game as it was without seasons.
	]]
	Seasons = {
		Enabled = true,
		-- Days of Autumn, Winter, Spring and Summer (whole days, each at least BlendDays).
		Lengths = { 8, 8, 8, 8 },
		-- Days a season's quantities blend over, centred on the turn (the old season's last day and
		-- the new one's first). At most the shortest length.
		BlendDays = 2,
		-- The sun's day half as a share of half the day, per season (Autumn, Winter, Spring,
		-- Summer), a solar day (midnight to midnight) at a time; 0.6..1.4. Winter's 0.8 is about
		-- 9 minutes of day in 20, summer's 1.2 about 12.7.
		DaylightScale = { 1.0, 0.8, 1.0, 1.2 },
		--[[
			The climate per season (Autumn, Winter, Spring, Summer; Shared/Seasons/SeasonClimate):
			  DayShift      added to the biome's climate by day and night (Tough As Nails' units),
			                times the biome class's Amplitude
			  NightDrop     outdoors and under a roof at night, colder by this (replaces 0.3)
			  WeatherShift  added to Minecraft's biome temperature before the snow test (0.15)
			  WetBias       lowers the moisture rain needs (more rain), raises it when negative
			  ThunderBias   lowers the moisture thunder needs; -1: none
			  Growth        plants' random-tick chance factor (saplings, herbs, grass)
			Heat waves: a summer day is one with Chance (never two in a row), adding Shift (times
			the Amplitude) between From and To ticks into the day, ramping over Ramp ticks.
			Snow melts where Minecraft's temperature is at least Weather's 0.15 + MeltMargin.
			SnowCover (the far landscape's white, Shared/Seasons/Foliage): temperate biomes over
			winter's first RampDays and back over spring's first; cold ones from ColdEarlyDays
			before winter to spring's ColdLateDays.
		]]
		Climate = {
			DayShift = { -0.10, -0.40, -0.05, 0.30 },
			NightDrop = { 0.30, 0.35, 0.30, 0.25 },
			WeatherShift = { -0.20, -0.80, -0.10, 0.20 },
			WetBias = { 0, 0.02, 0.06, -0.08 },
			ThunderBias = { 0, -1, 0.04, 0.02 },
			Growth = { 0.5, 0, 1.5, 1.0 },
			Amplitude = { cold = 1, temperate = 1, dry = 0.75, tropical = 0.5 },
			HeatWave = { Chance = 0.3, Shift = 0.30, From = 3000, To = 12000, Ramp = 1000 },
			MeltMargin = 0.05,
			SnowCover = { RampDays = 2, ColdEarlyDays = 2, ColdLateDays = 4 },
		},
		--[[
			Snow layers (server Seasons/SnowWorld, Shared/Seasons/SnowLayers): each active chunk is
			visited with TileChance a tick (at most MaxTilesPerTick visits a tick), one of its 4 x 4
			tiles; snow rises evenly up to the column's cap (Caps by biome class, +1 every
			CapPerBlocks above CapAltitude, a drift of +-1 over DriftWavelength blocks, at most 8)
			and melts a layer at a time (a visit's MeltChance, times MeltClear by a clear day,
			MeltRain in rain, MeltNight at night). Every HeatMeltSeconds a lit heat source melts a layer within
			HeatMeltRadius; a room at RoomMelt or warmer melts what is in or on it. Ice: still
			water freezes from its edges in winter and thaws in spring.
		]]
		Snow = {
			Enabled = true,
			TileChance = 1 / 250,
			MaxTilesPerTick = 8,
			Caps = { cold = 6, temperate = 3, tropical = 1, dry = 0 },
			CapAltitude = 160,
			CapPerBlocks = 64,
			DriftWavelength = 32,
			MeltChance = 0.5,
			MeltClear = 2,
			MeltRain = 2,
			MeltNight = 0.5,
			HeatMeltSeconds = 5,
			HeatMeltRadius = 2,
			RoomMelt = 3,
			Ice = true,
		},
		--[[
			Rooms (enclosed, insulated spaces: Shared/Seasons/Rooms, server Seasons/RoomWorld): a
			flood fill from the player's feet over passable cells, given up past MaxVolume cells,
			MaxExtent blocks across or MaxOpenings faces open to the sky (then the roof rule
			holds). An opening face loses OpeningU; the air holds HeatCapacity per cell. At most
			FillsPerFrame fills and FillMs a frame; seeds come from players every SeedSeconds and
			from room-source machines every MachineSeedSeconds within Range blocks of a player; a
			room unvisited for ForgetSeconds with no live source is forgotten, a failed seed is not
			tried again for NotRoomSeconds. The outdoor value a room loses to is kept within
			+-OutsideLimit.
		]]
		Rooms = {
			Enabled = true,
			MaxVolume = 1024,
			MaxExtent = 32,
			MaxOpenings = 6,
			OpeningU = 1.0,
			HeatCapacity = 2,
			FillsPerFrame = 2,
			FillMs = 2,
			SeedSeconds = 1,
			MachineSeedSeconds = 5,
			Range = 128,
			ForgetSeconds = 60,
			NotRoomSeconds = 5,
			OutsideLimit = 15,
		},
		--[[
			Heat and cold in heat units (HU) a second, what each source gives a room (Players/
			Climate's room sources) and what the heaters, coolers and stoves cost (Shared/Machines
			kinds "heater", "cooler", "stove", "oilheater"): a Campfire, each Fire (at most
			FireMax), each Lava block (at most LavaMax), a lit Furnace, a working Heat or
			Combustion Generator, each player inside. The Wood Stove burns furnace fuel for
			StoveBurnFactor x its burn time; the Oil Heater's tank holds OilTank mB, a mB of Oil
			lasting OilTicks at full output, of Fuel FuelTicks. Electric heaters take
			HeaterJoules a tick per HU, coolers CoolerJoules, the fan FanJoules while it runs.
			Outdoors an electric heater warms players within SpaceHeaterRadius (a SpaceHeater HU
			source) and a running fan cools within FanRadius; a heater with no player within
			StandbyRadius stands by. Thermostats hold SetPointMin..SetPointMax.
		]]
		Heat = {
			Campfire = 20,
			Fire = 15,
			FireMax = 3,
			Lava = 10,
			LavaMax = 6,
			Furnace = 8,
			Generator = 10,
			Player = 1,
			WoodStove = 30,
			OilHeater = 35,
			ElectricHeater = 40,
			ElectricFan = -10,
			AirConditioner = -40,
			StoveBurnFactor = 4,
			OilTank = 4000,
			OilTicks = 30,
			FuelTicks = 60,
			HeaterJoules = 4,
			CoolerJoules = 5,
			FanJoules = 30,
			SpaceHeater = 20,
			SpaceHeaterRadius = 5,
			FanRadius = 3,
			StandbyRadius = 16,
			SetPointMin = -5,
			SetPointMax = 5,
		},
		--[[
			Foliage colours by season (Shared/Seasons/Foliage, client Rendering/SeasonTint):
			keyframes over the year's progress p (Autumn 0..0.25, Winter, Spring, Summer
			0.75..1), each { at, colour, keep }: a keyframe is lerp(colour, authored, keep) in
			linear light (keep 1: the authored colour), and the colour moves evenly in CIELAB
			between keyframes. Classes: grass (grass blocks and tinted plants), deciduous (oak,
			acacia, vines), birch, evergreen (spruce), tropical (jungle). Overrides: a biome
			class's own keyframes for a class (dry biomes' grass yellows in summer), or the name
			of another class's (tropical biomes keep every colour). Dust: how far full snow cover
			moves a kind towards SnowColour (grass and plants, leaves and vines, spruce, jungle).
			Consecutive steps (BlendDays / 24 days, shorter with seasons under 8 days) stay within
			ΔE76 2.5 (tests/spec/Foliage: keep the snow ramps and the spring green-up apart when
			tuning). The sweep writes at most SweepWrites properties and SweepMs a frame; far
			meshes are rebuilt when their palette moved more than FarDeltaE (ΔE76; a far palette
			every FarStepDays).
		]]
		Foliage = {
			Enabled = true,
			SnowColour = { 236, 240, 246 },
			Dust = { grass = 0.75, leaves = 0.5, evergreen = 0.45, tropical = 0 },
			Keyframes = {
				deciduous = {
					{ at = 0.00, colour = { 150, 140, 50 }, keep = 0.4 },
					{ at = 0.08, colour = { 210, 110, 40 }, keep = 0 },
					{ at = 0.15, colour = { 170, 90, 50 }, keep = 0 },
					{ at = 0.23, colour = { 110, 90, 70 }, keep = 0 },
					{ at = 0.62, colour = { 110, 90, 70 }, keep = 0 },
					{ at = 0.69, colour = { 130, 200, 90 }, keep = 0.3 },
					{ at = 0.77, colour = { 0, 0, 0 }, keep = 1 },
					{ at = 0.86, colour = { 0, 0, 0 }, keep = 1 },
					{ at = 0.96, colour = { 110, 130, 50 }, keep = 0.6 },
				},
				birch = {
					{ at = 0.00, colour = { 190, 170, 60 }, keep = 0.4 },
					{ at = 0.08, colour = { 230, 190, 60 }, keep = 0 },
					{ at = 0.15, colour = { 190, 150, 60 }, keep = 0 },
					{ at = 0.23, colour = { 110, 90, 70 }, keep = 0 },
					{ at = 0.62, colour = { 110, 90, 70 }, keep = 0 },
					{ at = 0.69, colour = { 130, 200, 90 }, keep = 0.3 },
					{ at = 0.77, colour = { 0, 0, 0 }, keep = 1 },
					{ at = 0.86, colour = { 0, 0, 0 }, keep = 1 },
					{ at = 0.96, colour = { 110, 130, 50 }, keep = 0.6 },
				},
				grass = {
					{ at = 0.05, colour = { 176, 150, 72 }, keep = 0 },
					{ at = 0.20, colour = { 128, 118, 92 }, keep = 0 },
					{ at = 0.62, colour = { 128, 118, 92 }, keep = 0 },
					{ at = 0.70, colour = { 120, 190, 80 }, keep = 0 },
					{ at = 0.80, colour = { 0, 0, 0 }, keep = 1 },
					{ at = 0.88, colour = { 0, 0, 0 }, keep = 1 },
					{ at = 0.97, colour = { 150, 165, 70 }, keep = 0.4 },
				},
				evergreen = {
					{ at = 0.10, colour = { 50, 80, 70 }, keep = 0.8 },
					{ at = 0.35, colour = { 50, 80, 70 }, keep = 0.7 },
					{ at = 0.60, colour = { 50, 80, 70 }, keep = 0.8 },
					{ at = 0.85, colour = { 0, 0, 0 }, keep = 1 },
				},
				tropical = {
					{ at = 0.00, colour = { 0, 0, 0 }, keep = 1 },
				},
			},
			Overrides = {
				dry = {
					grass = {
						{ at = 0.05, colour = { 176, 150, 72 }, keep = 0 },
						{ at = 0.30, colour = { 140, 126, 88 }, keep = 0 },
						{ at = 0.45, colour = { 140, 126, 88 }, keep = 0 },
						{ at = 0.60, colour = { 0, 0, 0 }, keep = 1 },
						{ at = 0.72, colour = { 0, 0, 0 }, keep = 1 },
						{ at = 0.90, colour = { 200, 172, 84 }, keep = 0.2 },
					},
				},
				tropical = { grass = "tropical", deciduous = "tropical", birch = "tropical", evergreen = "tropical" },
			},
			SweepWrites = 1500,
			SweepMs = 0.75,
			FarStepDays = 0.5,
			FarDeltaE = 6,
		},
		-- The season clock (client Ui/SeasonHud, beside the minimap; Options > HUD "Season Clock")
		-- and the season's toasts. false: neither.
		Clock = { Enabled = true, Toasts = true },
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
		-- Server.Fire.Tick). Clients within Distance blocks are told (17 bytes a strike; 4096 is
		-- Ultra's view, so a storm where players stand is seen from as far as any view reaches):
		-- each sees the bolt within its view distance and hears it within Distant.Hearing.
		Lightning = {
			Enabled = true,
			MeanSeconds = 20,
			Radius = 64,
			Damage = 5,
			BurnSeconds = 8,
			Distance = 4096,
		},
		-- Fog distance factor at full rain, snow and thunder (client: the haze comes closer, as a
		-- denser Atmosphere: Rendering/AtmosphereModel).
		Fog = { Rain = 0.6, Snow = 0.4, Thunder = 0.45 },
		-- Blocks a second thunder travels (the client hears a strike that much later).
		SoundSpeed = 343,

		--[[
			What the player sees and hears of it (client Weather/): rain and snow around the camera,
			the clouds out to the view distance, the light, lightning, and the maps' weather mode
			(Map/WeatherLayer). Options > Weather... has Clouds and Weather (Off / Fast / Fancy).
			Images are Config values so they are easy to swap: any rbxassetid:// (or rbxasset://)
			works.
		]]
		-- Rain and snow (Weather/PrecipitationView, Minecraft's renderSnowAndRain): one strip a
		-- block column, facing the camera, within Radius (Fast, Fancy) blocks, from the column's
		-- roof (or the camera's height - radius) to the camera's height + radius. Length: blocks
		-- one tile of the image covers along the fall; Width: the strip's width (blocks); Speed:
		-- tiles a second it falls (if your rain rises, make it negative); Color { r, g, b }
		-- multiplies the image (white: as drawn); Transparency: the strip's at full intensity
		-- (more see-through towards the disc's edge and in drizzle).
		-- The strips are Beams, and a Beam lays its image's WIDTH along its length: the image's
		-- left-to-right runs down the fall. So an image drawn upright (rain streaks running top to
		-- bottom, as Minecraft's rain.png) must be uploaded turned 90 degrees counter-clockwise
		-- (the image's bottom on its right), and Length / Width keep its proportions: an upright
		-- 180 x 720 rain image (Minecraft's 1 x 4 blocks a sheet) turned is 720 x 180 = Length 4,
		-- Width 1. The snow image (1024 x 576) is round flakes, which look the same either way:
		-- Length 1.78, Width 1 keeps them round.
		Precipitation = {
			Radius = { 5, 10 },
			Rain = {
				Texture = "rbxassetid://75812216912065",
				Length = 4,
				Width = 1,
				-- (2.2 sheets of 4 blocks a second: about 9 blocks a second, Minecraft's rain.)
				Speed = 2.2,
				Color = { 255, 255, 255 },
				Transparency = 0,
			},
			Snow = {
				Texture = "rbxassetid://12003098335",
				Length = 1.78,
				Width = 1,
				-- (About a block a second, drifting down slowly.)
				Speed = 0.55,
				Color = { 255, 255, 255 },
				Transparency = 0,
			},
			-- The rain's sound where it lands within 10 blocks (Minecraft's tickRain finds the spot;
			-- here a looped weather.rain plays while it keeps finding one): Volume of the loop at
			-- Minecraft's full cue, Hold seconds it stays up after the last spot found (the spots
			-- come every 2-3 ticks), Smoothing (seconds, time constant), and the equalizer (dB)
			-- under a roof (weather.rain.above's spots: the same loop, duller).
			Sound = {
				Volume = 1,
				Hold = 0.6,
				Smoothing = 0.6,
				RoofMuffle = { Low = 0, Mid = -6, High = -20 },
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
		-- follow (time constant). Haze: Atmosphere.Haze added at full rain or snow, ThunderHaze
		-- more at full thunder (the horizon greys over in the storm's darker fog colour; the sun's
		-- glare goes as the rain comes).
		Sky = {
			CoverSun = 0.3,
			Saturation = 0.28,
			ThunderSaturation = 0.18,
			Contrast = 0.08,
			Tint = { 226, 234, 255 },
			Smoothing = 1.5,
			Haze = 1.8,
			ThunderHaze = 1,
		},
		-- Lightning on the client (Weather/LightningView): the bolt's colour, its glow, the flash of
		-- the sky (ColorCorrection brightness at the strike, less with distance and indoors) and
		-- the light at the struck point; thunder is heard Shared/Weather.thunderDelay (SoundSpeed)
		-- later. Strikes farther than Distant.Near are drawn and heard as distant ones (below).
		Bolt = {
			Color = { 214, 220, 255 },
			Glow = 0.75,
			Flash = 0.45,
			LightRange = 60,
		},
		--[[
			Distant storms (client Weather/DistantStorms, Weather/StormView, Weather/LightningView):
			lightning each client works out for itself from the weather field, the same flashes on
			every client with nothing sent (a hash of the world seed, a Cell-block cell and a
			Period-second slot of the server's clock), so a thunderstorm on the horizon flickers and
			rumbles. Rate: flashes a minute per km^2 of full thunder, none below MinThunder (the
			clouds' first tower step; seed 12345's median 2 km view with thunder in it holds 0.38
			km^2 of it: a flash every 13 s); GroundShare of them bolts to the ground (only where it
			rains), the rest in the cloud. At most PerMinute in reach (FastPerMinute with Clouds on
			Fast; Off: none at all); no bolt within MinDistance of anyone or Lightning.Radius +
			Margin of a player in thunder (the server's strikes are there): those flash in the
			cloud. A period's flashes are worked out during the one before, at least CellsPerFrame
			cells of its grid a frame, more when the frames are few (ready before it starts).
			Seen out to the view distance (Bolts / FastBolts bolts, Glows flashes at once; bolts
			about two pixels wide at any distance, PixelWidth blocks per block away, and up to
			MaxBrightness times as bright as the haze needs (Beam.Brightness); Glow: how far the
			lit clouds go towards the bolt's colour, GlowParts parts within GlowRadius blocks); the
			sky's flash weakens with distance and by day (to DayFlash from Near on), InCloudFlash
			for a flash in the cloud. Heard out to Hearing blocks (MobileHearing on phones;
			MaxReach: no flashes made farther): half as loud at HalfVolume blocks (InCloudVolume
			for a flash in the cloud), up to Deepen lower (and longer) at the edge, muffled from
			Near on by an equalizer (High and Mid dB less every 256 blocks, down to HighFloor /
			MidFloor; Low dB more by 1024), an echo from Echo.From blocks (Volume, Pitch, Delay
			seconds later); at most Voices distant sounds at once (MobileVoices on phones), the
			quietest giving way.
			Rain: a hiss of the rain around (Rings blocks out in Directions directions, Half: blocks
			at which it counts half), Volume at full rain, muffled by Muffle (dB), Smoothing
			seconds to follow, sampled every Interval s; it fades as the rain here takes over, and
			under a roof to Roofed of it, muffled by RoofMuffle instead.
		]]
		Distant = {
			Enabled = true,
			Rate = 12,
			MinThunder = 0.15,
			GroundShare = 0.3,
			PerMinute = 24,
			FastPerMinute = 12,
			Cell = 128,
			Period = 2,
			CellsPerFrame = 128,
			MinDistance = 64,
			Margin = 32,
			MaxReach = 4096,
			Near = 256,
			Bolts = 3,
			FastBolts = 2,
			Glows = 4,
			PixelWidth = 0.0026,
			MaxBrightness = 20,
			Glow = 0.85,
			GlowParts = 6,
			GlowRadius = 96,
			DayFlash = 0.3,
			InCloudFlash = 0.5,
			Hearing = 2048,
			MobileHearing = 1024,
			HalfVolume = 700,
			InCloudVolume = 0.7,
			Deepen = 0.25,
			High = 10,
			HighFloor = 40,
			Mid = 2.5,
			MidFloor = 15,
			Low = 2,
			Echo = { From = 768, Volume = 0.55, Pitch = 0.92, Delay = { 0.8, 1.8 } },
			Voices = 3,
			MobileVoices = 2,
			Rain = {
				Enabled = true,
				Rings = { 24, 56, 104, 168 },
				Directions = 8,
				Half = 64,
				Volume = 0.6,
				Muffle = { Low = 0, Mid = -4, High = -14 },
				Roofed = 0.5,
				RoofMuffle = { Low = 0, Mid = -8, High = -24 },
				Smoothing = 1.2,
				Interval = 0.25,
			},
		},
		-- Wind (Weather/WindSound, Weather/StormView): a looped weather.wind around the player
		-- under the open sky. Its cue volume is Volume x (Calm + PerSpeed x the wind's speed in
		-- blocks a second + Storm x the storm at the camera (rain 0..1, thunder counts double) +
		-- Altitude.Gain over Altitude.From..To blocks above sea level), at most Max, times the sky
		-- reaching the camera (none in caves) and Roofed under a roof (duller: RoofMuffle dB).
		-- Smoothing: seconds (time constant).
		Wind = {
			Enabled = true,
			Volume = 0.5,
			Calm = 0.3,
			PerSpeed = 0.2,
			Storm = 0.5,
			Altitude = { From = 40, To = 300, Gain = 0.6 },
			Max = 1.6,
			Roofed = 0.45,
			RoofMuffle = { Low = 0, Mid = -6, High = -18 },
			Smoothing = 2,
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

		The view's haze is a Lighting Atmosphere (Atmosphere below; Roblox ignores the old FogStart /
		FogEnd while one is in Lighting): IceVoxel drives the place's first (default.project.json's)
		or makes one, and a Sky if there is none (without one Roblox ignores the Atmosphere). Its
		Color is FogColor below (Minecraft's fog colours, the horizon's colour in Minecraft too),
		its Haze, Glare and Decay are blended like the rest, and Roblox fades distant geometry
		into the sky behind it (lit by the sun and moon itself: dark at night, warm at sunset).
		Lighting.FogColor itself only shows inside fluids and under Blindness, whose short fogs are
		the old Lighting fog (Rendering/ViewSettings takes the Atmosphere out meanwhile).
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
			-- Minecraft's day fog: the Atmosphere's Color (see Atmosphere.ColorFloor).
			FogColor = { 192, 216, 255 },
			-- Atmosphere.Haze (0..10: how far up the sky the horizon's haze reaches; Color only
			-- shows through it), Glare (0..10: a glow around the sun; needs Haze) and Decay (the
			-- haze's colour away from the sun; needs Haze and Glare). Minecraft's sun has no glow.
			Haze = 0.25,
			Glare = 0,
			Decay = { 106, 112, 125 },
		},
		-- Dark blue but readable (Minecraft's night sky light is 4 of 15).
		Night = {
			OutdoorAmbient = { 44, 52, 84 },
			Brightness = 1,
			ColorShiftTop = { 16, 24, 48 },
			EnvironmentDiffuse = 0.4,
			EnvironmentSpecular = 0.2,
			FogColor = { 14, 18, 34 },
			-- (No glare: the moon side would glow.)
			Haze = 0.2,
			Glare = 0,
			Decay = { 40, 50, 80 },
		},
		-- Warm sunrise and sunset light, mixed in up to Strength (Minecraft's sunrise colour curve).
		Dusk = {
			Strength = 0.8,
			OutdoorAmbient = { 150, 104, 84 },
			ColorShiftTop = { 200, 96, 30 },
			FogColor = { 230, 140, 96 },
			-- A warm haze along the horizon with a glow around the low sun, cooler away from it.
			Haze = 0.8,
			Glare = 0.4,
			Decay = { 120, 110, 150 },
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
		--[[
			The Atmosphere (Rendering/AtmosphereModel). It has no FogStart / FogEnd: the light of a
			thing d studs away is let through by T = exp(-Scale x Density^4 x d) (an exponential
			from the camera on; Roblox publishes no formula, Scale 0.1 and the 4th power come from
			a re-implementation of its renderer and match what developers report, e.g. Density 1
			hides things some 30 studs off). Density is worked out so that Edge of the light is
			left at the view distance: 0.1, so the edge of the loaded terrain is 90% hazed, its far
			LOD nodes (up to a third further) 95%, while what is near stays clear (6% at 1/40 of the
			view, 13% at 1/16, 44% at 1/4: an exponential's shape, whatever Scale is). Density at
			2048 blocks: 0.247 (1024: 0.294, 512: 0.350, 4096: 0.208). To calibrate Scale in
			Studio: put a part d studs away, find the Density at which it looks half hazed, then
			Scale = 0.693 / (Density^4 x d); a larger Edge keeps more of the middle distance (and
			shows more of the edge).
			WeatherPower: rain, snow and thunder haze it as for a view their fog factor
			(Weather.Fog) to this power as far: 1/3 keeps the storm clouds overhead under half
			hazed into the clear sky behind them from 1024 blocks of view up (the whole factor, 1,
			would wash them out: this haze starts at the camera, the old fog at 55%); the storm's
			Haze and darker Color grey the horizon instead.
			RainDensity / ThunderDensity: the Density the weather itself brings, whatever the view
			(the denser of this and the edge rule shows): rising from clear weather to RainDensity
			in full rain, then to ThunderDensity in a full thunderstorm or full snow (Weather.Fog's
			nearer factors), blended in k (~ Density^4); none indoors.
			At Scale 0.1: 0.44 hazes things half at 62 blocks and 90% at 205 (heavy rain); 0.667
			half at 12 blocks and 90% at 39 (a downpour: the storm clouds overhead and lightning
			farther than about 40 blocks fade into the grey). 0 turns it off (WeatherPower alone).
			ThinBelow: under this much sky exposure (Rendering/SkyExposure) the haze thins out, k
			by (exposure / ThinBelow)^2, so deep cave walls never fade into a daylit sky, while a
			tunnel's mouth (exposure 1 - distance / 16) keeps the full haze over the view out of it
			for its first 9-10 blocks.
			Offset: how sharp a sky the haze fades to (0: the sky right behind, so the edge melts
			into it; 1: one blurred average, a silhouette, and LOD changes show).
			ColorFloor: the time of day's fog colour (Color) has its brightest channel raised to at
			least this before the weather darkens it; 0: Minecraft's own colours. Roblox scatters
			the sky's light into the haze by Color (in the re-implementation that light is not
			darkened at night, so a brighter night Color would glow over the dark sky): raise it
			(e.g. 64) only if the night's horizon looks black in the Roblox player.
		]]
		Atmosphere = {
			Scale = 0.1,
			Edge = 0.1,
			WeatherPower = 1 / 3,
			RainDensity = 0.44,
			ThunderDensity = 0.667,
			ThinBelow = 0.4,
			Offset = 0.05,
			ColorFloor = 0,
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
		-- Only with Camera.Enabled false: the camera's rig turns the body to the aim instead.
		TurnSpeed = 14,
	},

	-- Camera (client) ----------------------------------------------------------------------------------

	--[[
		DayZ's camera on Roblox's camera scripts (client Player/CameraRig, its numbers and rules in
		Player/CameraRules): third person over a shoulder at a fixed distance that never enters a
		block, first person from the eyes with the body drawn (Player/FirstPersonBody), the view
		toggled with Toggle Perspective (F5; not while a weapon is raised), Freelook (Left Alt: the
		camera turns while the body and the aim keep their heading) and Focus (Z: the eyes' zoom).
		Lengths are studs (a block is BlockSize studs), angles degrees, times seconds.
	]]
	Camera = {
		-- false: Roblox's camera as before the rig (its zoom, the raised shoulder from
		-- Weapons.ShoulderOffset, the body turning where it walks; no freelook, no focus, no
		-- first-person body).
		Enabled = true,
		-- The view a player starts in, "third" or "first" (the Camera setting's default).
		DefaultView = "third",
		-- The First-Person Body setting's default (false: Minecraft's hand instead of the body).
		FirstPersonBody = true,
		-- The Freelook setting's default: false holds the key, true toggles (DayZ's Lock Freelook).
		FreelookToggle = false,
		-- The third-person rig by what the body does: { distance behind the pivot, shoulder (to
		-- the side), height (of the pivot above the hull's eyes), forward } in the body's frame:
		-- DayZ's third-person cameras (dayzplayercamera3rdperson.c) in studs. `raised` is a raised
		-- firearm, `raisedHands` a melee guard. A change of rig eases over DayZ's blend times
		-- (CameraRules.transition).
		Profiles = {
			standing = { 4.8, 0.9, 0.25, 0 },
			sprinting = { 6.0, 0.45, 0.1, 0 },
			crouching = { 4.2, 0.9, 0.3, 0.3 },
			lying = { 3.0, 1.5, 0.6, 0 },
			climbing = { 3.6, 0.9, 0.3, 0 },
			flying = { 6.0, 0.9, 0.25, 0 },
			raised = { 2.4, 1.5, 0.0, 0.6 },
			raisedHands = { 3.6, 1.2, 0.0, 0.6 },
			crouchRaised = { 2.4, 1.5, 0.1, 0.3 },
		},
		-- Freelook: how far the camera may turn from the aim each way (third person; first person:
		-- the neck's 70 and the waist's 30), and the smooth time it comes back in (DayZ's 0.14).
		FreelookYaw = 160,
		FreelookYawFirst = 100,
		SnapBackSeconds = 0.14,
		-- Collision with blocks: the gap kept between them and the camera behind the shoulder, and
		-- how fast a boom pulled in eases back out (per second, as Roblox's Popper). The near plane
		-- kept out of them is measured from the camera every frame (Player/CameraRules.setLens:
		-- 0.1 studs ahead on a computer, up to 0.5 on a phone, as wide as the field of view and the
		-- screen make it).
		Margin = 0.3,
		EaseOut = 6,
		-- First person: the eye point this far ahead of the hull's eyes, and this much more when
		-- looking straight down (times the sine of the pitch): past the front of the chest (half a
		-- torso's depth, 0.5) by 0.3 or more from 60 degrees down, so the chest's edge, the legs and
		-- the feet show instead of the inside of the neck or the top of the torso. Pulled back where
		-- a block would cut the near plane.
		FirstForward = 0.15,
		FirstDownPush = 0.75,
		-- The body turning to the aim while standing: the smooth time, the most it lags behind
		-- (degrees), and the speed (blocks a second) above which it turns at once.
		IdleTurnSeconds = 0.12,
		IdleTurnMaxLag = 60,
		IdleTurnSpeed = 0.5,
		-- Focus (held): the field of view (never wider than the FOV setting's), the one while
		-- sprinting (DayZ's shallow zoom), and the smooth time of the change. None while raised.
		FocusFov = 45,
		FocusSprintFov = 70,
		FocusSeconds = 0.1,
	},

	-- Map --------------------------------------------------------------------------------------------

	Map = {
		Enabled = true,
		-- The minimap's image in map pixels (its size on screen: UiScale.Minimap GUI pixels) and
		-- blocks per map pixel.
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

	-- Floating origin (client) -----------------------------------------------------------------------

	Origin = {
		-- Every client-made instance is placed at (world studs - origin), and the origin follows the
		-- camera (Shared/World/Origin, client Rendering/Rebase), so nothing drawn is ever farther than
		-- RebaseDistance + the view distance from 0 (float32 stays within 1/512 stud). false: the
		-- origin stays at 0 and every conversion is the identity (a kill switch: turn it off only
		-- together with Players.ServerPositions, as a client-owned character would replicate
		-- render studs).
		Enabled = true,
		-- The camera farther than this (studs, along X or Z) from the origin moves it at once (one
		-- frame moves every client part: a hitch). 8192 studs: 1/1024 stud near the camera.
		RebaseDistance = 8192,
		-- Beyond this the origin moves at a moment a hitch can't be seen (teleports, respawns,
		-- terrain loading, the world map, inventory screens, menus: Rebase.setHidden).
		SoftDistance = 3072,
		-- The origin is a multiple of this (16 chunks, 2^8 x 3): blocks, chunks, texture tiles and
		-- the lighting grid line up the same after a move.
		Snap = 768,
	},

	-- Who learns what about whom (server) ------------------------------------------------------------

	Interest = {
		-- Other players' poses are sent this near (blocks, horizontal: Minecraft's tracked entity
		-- range is 144 at its default view distance, at most 512) ...
		PlayerDistance = 256,
		-- ... and until this much farther.
		PlayerHysteresis = 16,
		-- Pose messages a second, and an unchanged pose is sent again after KeepAliveSeconds.
		RelayRate = 20,
		KeepAliveSeconds = 0.5,
		-- Poses in one unreliable message (22 bytes each; Roblox drops unreliable messages over
		-- 1000 bytes, so at most 45: Net/PlayerSync).
		MaxPosesPerMessage = 40,
		-- Seconds (client) remote players are drawn behind the newest pose, to glide between them.
		InterpolationDelay = 0.1,
		-- Chunks (x 16 blocks, from the feet to a chunk's nearest point): edit lists are answered
		-- this near (else deferred until the player comes near), live edits reach players this
		-- near, and at most this many requests wait. 14: an edit this near is made by someone
		-- within PlayerDistance, and the client's lists reach 195 blocks at most (Players/Interest).
		EditChunkRadius = 14,
		EditSendRadius = 14,
		DeferredChunkRequests = 1024,
		-- Blocks: server lightning strikes are sent this near (the client draws far storms itself).
		-- Strikes fall within Weather.Lightning.Radius (64) of a player (and up to 4 blocks aside,
		-- onto someone standing there: World/Lightning.target), so 184 tells only of players
		-- within PlayerDistance.
		LightningDistance = 184,
	},

	-- Players' positions (server) --------------------------------------------------------------------

	Players = {
		-- Positions come from the clients' Move messages (checked), characters are parked and
		-- anchored, and poses are relayed by interest. false: positions are read from the
		-- characters as before (server Players/PlayerPositions' compat backend; a kill switch, off
		-- only together with Origin.Enabled).
		ServerPositions = true,
		-- Move messages a client sends a second.
		MoveRate = 20,
		-- What a move faster than MoveLimits does: "correct" (teleport back, Minecraft's "moved too
		-- quickly"), "log" (warn) or "off".
		MoveCheck = "correct",
		-- Seconds of movement at the limits the checks' buckets hold.
		MoveSlack = 2,
		-- Blocks a second, by game mode (generous: sprint-jumping on ice with Speed II is about 10,
		-- creative sprint-flying 21.8, spectators about 87, falling at most 78).
		MoveLimits = {
			Survival = { horizontal = 12, up = 12, down = 80 },
			Adventure = { horizontal = 12, up = 12, down = 80 },
			Creative = { horizontal = 30, up = 30, down = 80 },
			Spectator = { horizontal = 100, up = 100, down = 100 },
		},
		-- Studs: where every character stands on the server (what replicates: the fake coordinates).
		ParkPosition = { 0, 20000, 0 },
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

	-- Hunger (Minecraft's food bar) -----------------------------------------------------------------

	--[[
		Minecraft 1.20.1's hunger (FoodData; Shared/Hunger, server Players/ToughAsNails runs it with
		thirst): the food bar (food 0..20, saturation, exhaustion; the HUD's FOOD status icon),
		foods filling it (Items/Foods: Minecraft's nutrition and saturation), natural regeneration
		from a full bar, starvation at an empty one, no sprinting at 6 or less, and Minecraft's
		Hunger effect. With Tough As Nails' thirst on, health comes back only while both bars are
		high. Survival and adventure players only: creative and spectator
		players' food stands still and they may always eat.
	]]
	Hunger = {
		-- The food bar at all. false: no FOOD status icon, foods heal health at once as before
		-- (Items/Foods' `heal`), and thirst's own regeneration rules health
		-- (ToughAsNails.ThirstRegeneration).
		Enabled = true,
		-- Minecraft's naturalRegeneration game rule: health comes back from food (with saturation
		-- at a full bar, half a heart every 10 ticks for up to 6 exhaustion; else at 18 or more,
		-- half a heart every 80 ticks for 6). This replaces Roblox's own regeneration (the
		-- character's Health script). false: no natural regeneration at all.
		NaturalRegeneration = true,
		-- Starvation (food 0) takes half a heart every 80 ticks while health is above this many half
		-- hearts (Minecraft's normal difficulty: 1; easy stops at 10; 0 = to death, hard).
		StarvationFloor = 1,
		-- Food exhaustion each tick of Minecraft's Hunger effect, per level (HungerMobEffect:
		-- 0.005 x (amplifier + 1)): rotten flesh's 30 s at level I is 3 exhaustion, most of a point.
		EffectExhaustion = 0.005,
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
		-- Thirst: drinking, dehydration at 0 and the HUD's THIRST status icon.
		Thirst = true,
		-- Body temperature: the HUD's TEMPERATURE status icon, hypothermia and hyperthermia.
		Temperature = true,
		-- With Thirst on, health comes back only while thirst is 18 or more. With Hunger on, that is
		-- a condition on hunger's natural regeneration (TAN: both bars high); with Hunger off,
		-- thirst regenerates itself: half a heart every 80 ticks for 6 exhaustion (Minecraft's
		-- natural regeneration, thirst for food), replacing Roblox's own regeneration (the
		-- character's Health script). false: thirst has no say (Hunger off: Roblox's stays). With
		-- Temperature on, nothing heals while the body is fully frozen or overheated.
		ThirstRegeneration = true,
		-- Dehydration (thirst 0) takes half a heart every 120 ticks while health is above this many
		-- half hearts (Minecraft's starvation on normal difficulty: 1; 0 = to death, hard).
		DehydrationFloor = 1,
		-- Right clicking a water source with an empty hand drinks from it (TAN's hand drinking).
		HandDrinking = true,
		-- Thirst exhaustion each tick in the HOT zone (sweating): 0.005 is a thirst point (half a
		-- droplet) every 40 s once the hydration is gone, a whole droplet every 80 s.
		HotExhaustion = 0.005,
		-- Food exhaustion each tick in the COLD zone and below (shivering) while seasons are on
		-- (Config.Seasons): 0.005 is a food point every 40 s once the saturation is gone.
		ColdExhaustion = 0.005,
		-- A leather (freeze immune, ItemList `tan.freezeImmune`) piece stops hypothermia
		-- (Minecraft's freeze_immune_wearables). Only read while seasons are on: without them a
		-- piece always does, as before; with them (false) clothes slow freezing but never stop
		-- it, as Don't Starve's.
		LeatherFreezeImmunity = false,
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
		-- hurt (Hunger's food bar is untouched by it, as in TAN). It counts down only in survival
		-- and adventure. 0 turns either off.
		ClemencyTicks = 6000,
		RespawnClemencyTicks = 1200,
		-- Ticks the player stays wet after leaving water (being wet cools by 3 steps).
		WetTicks = 100,
		-- Blocks around the player (a cube this many blocks out each way) searched for heat and
		-- cold sources, once a second. The content packs' block entries say which blocks are
		-- sources (Shared/Content): `heats` warms the player within this (3 steps; 5 within 2
		-- blocks; a fluid's source every level and its cave twin: lava), `cools` cools them by 3
		-- steps. Lit furnaces and working Heat and Combustion Generators warm too (server
		-- Players/ToughAsNails registers them). Within 2 blocks of a heat source, cold sources no
		-- longer cool (a fire beats the snow around it).
		ProximityRadius = 5,
		-- The picture as the extremes build (client Rendering/TemperatureGrade): its Saturation
		-- goes by Freezing at full hypothermia (colour draining out as the player freezes to
		-- death) and by Overheating at full hyperthermia (too vivid as they cook), in proportion
		-- on the way; Seconds: how fast it follows (time constant).
		Grading = { Enabled = true, Freezing = -0.5, Overheating = 0.5, Seconds = 1 },
	},

	-- Progression: knowledge, Ages and the skill tree -----------------------------------------------

	--[[
		Knowledge (this game's experience: Minecraft's curve, the bar under the status icons), the
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
		in the world from the structure library (Shared/Structures: the content packs' templates,
		pools and structures). A structure block saves a region as compact text ("IVS1:...",
		Structures/Template) that can be pasted into a content pack's `templates`, into a
		StringValue of the place's ReplicatedStorage.IceVoxelStructures folder, or back into a
		structure block in LOAD mode.
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
		-- Library structures generate in the world (the content packs' `structures` and the
		-- IceVoxelStructures folder's `Generate` attributes). false: none do.
		Generate = true,
	},

	--[[
		/locate structure | biome | poi (Players/LocateCommands, Generation/Locate, World/PoiSearch)
		and /tp. Searches run on the server a slice of each frame, one at a time: at most BudgetMs
		a frame, just before the generation preload's slice (World/Simulation), which takes what
		is left of the frame (Server.FrameBudgetMs), at most
		Queue of them waiting (one per player: a new /locate replaces that player's), and one still
		running after TimeoutSeconds gives up with the not-found answer.
	]]
	Locate = {
		BudgetMs = 3,
		TimeoutSeconds = 20,
		Queue = 8,
		-- Library structures: Minecraft's 100 rings of placement regions (an outpost's region is
		-- 56 x 56 chunks: 89,600 blocks out). A full miss costs some 40,000 probes (0.9 s).
		StructureRings = 100,
		-- How far (blocks) the built-in kinds are searched: mineshafts and their entrances,
		-- oil wells (geysers, deposits), surface lava lakes and water lakes, cave entrances,
		-- ravines. Each is a ring count of its grid (Generation/Locate).
		Radius = { mineshaft = 4096, oil = 16384, lake = 4096, cave = 3072, ravine = 6144, city = 24576, bunker = 6144 },
		-- Biomes: Minecraft's 6400 blocks in steps of 32, both times min(the world's climate
		-- scale, 2) (Large Biomes: 12800 in steps of 64, the same 160,801 samples at most).
		BiomeRadius = 6400,
		BiomeStep = 32,
		-- Points of interest: Minecraft's 256 blocks (3D). Generated ones (a structure's chests and
		-- furnaces, a mineshaft's chests) count wherever they are; true: only in chunks the
		-- server has loaded, as Minecraft knows only generated chunks' points of interest.
		PoiRadius = 256,
		PoiGeneratedNear = false,
	},

	Entities = {
		-- Dropped items disappear after this many seconds (Minecraft: 5 minutes).
		ItemLifetime = 300,
		-- At most this many dropped items exist; the oldest disappear first.
		MaxItems = 1000,
		-- Players see dropped items within this many blocks.
		TrackingDistance = 96,
	},

	-- Mobs (Shared/Entities/MobList: cows, sheep, pigs, chickens and zombies; server Mobs/). They
	-- tick within Server.SimulationRadius chunks of a player and freeze beyond.
	Mobs = {
		-- false: no mobs at all (nothing spawns, ticks or is sent; /summon says so).
		Enabled = true,
		-- false: no natural spawning (/summon still works).
		Spawning = true,
		-- Most mobs at once in the world, and of each category (Minecraft's mob caps, scaled to the
		-- simulated area) ...
		MaxMobs = 320,
		MaxPassive = 120,
		MaxHostile = 200,
		-- ... and within 128 blocks of each player (HostileCap: the zombies' night cap; by day,
		-- in cities and in a blood moon Apocalypse scales it; Peaceful zeroes it).
		PassiveCap = 10,
		HostileCap = 20,
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
		-- The zombies' R15 rigs (client Entities/MobRig, MobRigPool): at most MaxRigs drawn as
		-- rigs, MaxFull of them full within FullDistance blocks, reduced to ReducedDistance, the
		-- two-box stand-in beyond; Hysteresis blocks before a tier changes; spare rigs kept per
		-- tier; parts that cast shadows.
		Rig = {
			MaxRigs = 40,
			MaxFull = 16,
			FullDistance = 16,
			ReducedDistance = 40,
			Hysteresis = 4,
			SpareFull = 12,
			SpareReduced = 16,
			ShadowParts = 3,
		},
	},

	--[[ The zombie apocalypse (server Mobs/ZombieDirector, Apocalypse/*; client SurvivorHud, BloodMoonSky) ]]
	Apocalypse = {
		-- false: no director, noise, breaking, infection, bleeding, blood moon or day counter
		-- (zombies then act like the old zombie, without burning).
		Enabled = true,
		Zombies = {
			-- By day zombies spawn on sky-open floors (no darkness roll; block light 0 still).
			DaySpawning = true,
			-- The per-player hostile cap by day, times HostileCap.
			DayFactor = 0.35,
			-- Cells LightEstimate.blockLight may search for a day spawn (2048: every cell a
			-- torch lights on open ground, 13 blocks, as LightEstimate.SPAWN_BUDGET).
			DayLightBudget = 2048,
			-- Caps times this while the player stands in a city.
			CityFactor = 1.75,
			-- Extra spacing (blocks) zombies keep from each other.
			Separation = 0.1,
			-- An idle or wandering zombie this far from every player thinks every 4th tick.
			ThinDistance = 32,
			-- Ticks between line-of-sight checks while chasing.
			SightInterval = 3,
			-- Zombies break blocks only within BreakReach blocks (horizontally) of the target or
			-- noise they follow, HuntBreakReach of the player they hunt.
			BreakReach = 8,
			HuntBreakReach = 16,
			-- (Blood moon) zombies this near a player hunt them (inside the ticking area), and keep
			-- hunting while this near.
			HuntRadius = 44,
			HuntKeep = 56,
			-- Leave rounds: every Interval ticks by day, a zombie over the cap walks away for Ticks,
			-- and goes once Distance blocks from every player and unseen; a hunter that closed
			-- less than a block in StuckTicks gives up.
			Leave = { Interval = 600, Ticks = 600, Distance = 24, StuckTicks = 400 },
			-- An infected player who dies rises as a zombie, this many ticks later.
			RiseOnDeath = true,
			RiseDelay = 100,
		},
		-- Noise (server Apocalypse/NoiseBus, Shared/Apocalypse/NoiseRules): radii in blocks.
		Noise = {
			Enabled = true,
			Sprint = 8,
			Break = 10,
			Glass = 16,
			Place = 6,
			Door = 10,
			Container = 6,
			Hit = 8,
			Hurt = 10,
			ExplosionBase = 24,
			ExplosionPerPower = 12,
			ExplosionMax = 56,
			Scream = 48,
			-- The taker's factors: louder at night, muffled by rain at the source.
			NightFactor = 1.25,
			RainFactor = 0.7,
			-- (Seasons) muffled by snowfall at the source.
			SnowFactor = 0.85,
			-- Ticks a zombie investigates a noise; noises kept a tick, and merged within Merge.
			InvestigateTicks = 400,
			MaxPerTick = 32,
			Merge = 4,
		},
		-- Zombies breaking blocks: damage decays after Decay idle ticks; a hit sound every
		-- HitInterval ticks.
		Breaking = { Enabled = true, Decay = 100, HitInterval = 20 },
		-- A bite's infection: Stages of StageTicks each (death at the end), a bite while infected
		-- adds BiteAdvance, at most one roll every RollInterval ticks; each armor point shields
		-- ArmorShield of the chance (at most ArmorShieldMax); stage IV hurts every DamageInterval.
		Infection = {
			Enabled = true,
			StageTicks = 12000,
			Stages = 4,
			BiteAdvance = 2400,
			RollInterval = 100,
			ArmorShield = 0.0375,
			ArmorShieldMax = 0.75,
			DamageInterval = 100,
		},
		-- Bleeding from a hit: at least Ticks a hit, the amplifier at most MaxAmplifier.
		Bleeding = { Enabled = true, Ticks = 400, MaxAmplifier = 1 },
		-- Blood moons (Shared/Apocalypse/BloodMoon): every Every-th night from the First, from
		-- Start to End ticks into the day (ramping over Ramp); waves every WaveInterval of WaveBase
		-- + WavePerMoon x k a player into a cap of CapBase + CapPerMoon x k (at most CapMax), the
		-- world's limits raised to MaxHostile and MaxMobs; hunts assigned every HuntInterval; the
		-- sky tinted towards Tint, the moon MoonSize times as big.
		BloodMoon = {
			Enabled = true,
			Every = 3,
			First = 3,
			Start = 12500,
			End = 23500,
			Ramp = 600,
			WaveInterval = 600,
			WaveBase = 6,
			WavePerMoon = 2,
			CapBase = 24,
			CapPerMoon = 4,
			CapMax = 60,
			MaxHostile = 260,
			MaxMobs = 360,
			HuntInterval = 100,
			Tint = { 170, 28, 28 },
			TintStrength = 0.55,
			MoonSize = 1.6,
		},
		-- The day counter (client Ui/SurvivorHud) and how often the server sends it.
		Survivor = { DayCounter = true, SyncTicks = 1200 },
	},

	-- Sounds -----------------------------------------------------------------------------------------

	--[[
		Minecraft's sound events (Shared/Sounds, the content packs' sounds) played with sounds that
		ship with Roblox. The server sends the ones other players cause (breaking, placing, chests,
		pickups, tools breaking, hurting; server Audio/Sounds); clients play their own actions,
		footsteps and the interface themselves (Audio/SoundPlayer).

		To use your own sounds, put Sound instances in a Folder named OverrideFolder in SoundService
		or ReplicatedStorage, named like an event ("block.stone.break") or its category with the
		variant left out ("block.break"); several with one name are picked from at random. They play
		with their own Volume and PlaybackSpeed instead of the event's (still scaled by the settings
		below and varied by the event's pitch variance), heard as far as the event. The game ships
		its own recordings there too (src/sounds: the weather's, the zombies' voices); one whose
		file fails to load is left out, so its event plays the stand-in.
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

	-- Music (client; the tracks are the content packs' music, Sounds/MusicList) ----------------------

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
		-- Opens and closes the menu (Enum.KeyCode names; touch: the gear beside the quickbar, and
		-- the gear in the inventory's EQUIPMENT header). The key is the Options key binding's default.
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
		-- Preloading around players (World/Simulation, World/GenQueue): a background generator
		-- works on them a slice of every frame, closest first, instead of a whole chunk a frame
		-- (3.5-11 ms each, up to 45; at most 60 a second). Milliseconds a frame; Urgent while a
		-- player's own chunk or one around it is missing (a join, a teleport) or more than
		-- UrgentBacklog chunks wait (a window is 49): about 2 chunks a frame instead of 1. The
		-- slice never takes the frame's work so far (from its first script step) past
		-- FrameBudgetMs, but is always at least MinGenerationBudgetMs. /locate's search slice
		-- (Locate.BudgetMs) runs just before it and counts in that work; the pose relay may come
		-- on top.
		GenerationBudgetMs = 4,
		UrgentGenerationBudgetMs = 8,
		UrgentBacklog = 49,
		FrameBudgetMs = 12,
		MinGenerationBudgetMs = 1,
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
		-- The effect icons in the top right corner (and the list beside open screens). Off, the
		-- status icons' badges show Climate Clemency, Internal Warmth and Chill too.
		Hud = true,
		-- Nausea's wobble at full strength: the camera's roll (degrees) and the field of view's
		-- sway (a share of it), times the FOV Effects setting (Minecraft's Distortion Effects).
		NauseaRoll = 7,
		NauseaFov = 0.1,
		-- Night Vision lights places closed to the sky up to this grey (0..255, Lighting.Ambient):
		-- the darkest cave reads like an overcast day.
		NightVisionAmbient = 150,
	},

	-- Radiation (Mekanism's, simplified) --------------------------------------------------------------

	--[[
		Uranium is radioactive (Shared/Radiation, server Players/Radiation, client Audio/Geiger): its
		ore and blocks near a player and the uranium they carry give an exposure rate in Sv/h (as
		Mekanism's Geiger Counter reads it), which builds up a dose (Sv) that decays slowly; the
		dose's bands bring Radiation Sickness I, II and III. A Hazmat suit keeps it out, and the
		client clicks like a Geiger counter while the player is exposed. Survival and adventure
		players only: creative and spectator players are never exposed (their dose only decays).
		What is radioactive is the content packs' entries' to say (Shared/Content): `radiation`,
		Sv/h a block away or nearer, or carried (a block's item as the block, times the stack's
		count; uranium's ore, blocks, lump, ingot and nugget in the Ores pack, which says why they
		are what they are), `shielding`, the share a piece of armor worn keeps out (the Hazmat
		suit's, Mekanism's: the whole suit all of it), and `radiationShield`, a block's own share
		let through (lead's).
	]]
	Radiation = {
		-- false: nothing is radioactive (no exposure, sickness or clicks); a saved dose is kept as
		-- it is, for when it is back.
		Enabled = true,
		-- Blocks are looked for within this many blocks of the body (a sphere). Exposure falls off
		-- with the square of the distance from a block away in (Mekanism's magnitude /
		-- max(1, d^2)), less its value at this radius, so it fades to nothing there.
		Radius = 8,
		-- The share of radiation each block between a source and the body lets through: any full
		-- solid block (rock, earth, wood, metal) `Solid`, unless its content pack entry gives its
		-- own `radiationShield` (lead's blocks, 0.02 and 0.1: lead stops nearly all). Glass,
		-- plants and fluids let it all through (leaves are solid: Solid).
		Shielding = { Solid = 0.5 },
		-- The most sources traced for shielding in one look, nearest first (the rest take the
		-- mean of those traced in their octant of directions, unshielded in one with none): a
		-- look reads at most the sphere and this many rays.
		MaxRays = 32,
		-- Seconds for a dose to halve (Mekanism's 0.9995 a second is 23 minutes: a game's pace
		-- is quicker).
		HalfLife = 600,
		-- Rates below this (Sv/h) are none: no dose and no clicks.
		MinRate = 0.0005,
		-- Seconds between two looks at a player (the server spreads the players over them).
		Interval = 1,
		Sickness = {
			-- The doses (Sv) from which Radiation Sickness I, II and III come (Mekanism's bands).
			Bands = { 0.1, 1, 10 },
			-- Ticks it (and what comes with it) lasts once the dose falls below its band; renewed
			-- while the dose holds.
			Ticks = 600,
			-- Minecraft's Hunger comes with it from this level (Hunger I at II, II at III), and
			-- Nausea from this one.
			HungerFrom = 2,
			NauseaFrom = 3,
		},
		-- The Geiger counter (client): clicks a second at 1 Sv/h, growing with the rate's square
		-- root (a vein in the rock nearby a click every few seconds, one beside you a few a
		-- second, a stack of Raw Uranium a dozen), at most Max.
		Clicks = { PerSvh = 2.5, Max = 16 },
	},

	-- Characters (Terraria's player files) -----------------------------------------------------------

	--[[
		Terraria's players: each Roblox user keeps several characters, chosen on the title screen
		before the world (Shared/Characters; server Players/CharacterStore; client Ui/MainMenu).
		A character carries its look (an R15 avatar made from the user's own, Shared/Characters/
		Appearance), name, difficulty, inventory and equipment, health, mana, status effects,
		Tough As Nails and Knowledge, Ages and skills from world to world; a world keeps only where
		each character stood and its game mode (server Save/CharacterCodec, Save/
		WorldCharacterCodec). In Studio this needs API access, as Save; without it characters last
		for the session and the title screen says so.
	]]
	Characters = {
		-- false: no characters (the title screen goes straight to the world buttons, inventories stay
		-- in each world's player records and progression per user, as before).
		Enabled = true,
		-- The DataStore: an index per user ("u<UserId>") and a key per character ("u<UserId>/c<id>").
		StoreName = "IceVoxelCharacters_v1",
		-- Most characters a user keeps (Terraria has no limit; the list is one key).
		MaxPerUser = 10,
		-- Characters (code points) in a name, after trimming (Terraria's 20).
		NameLength = 20,
		-- A new character's difficulty: "Classic" (keeps everything on death), "Mediumcore" (drops
		-- everything, Minecraft's rule) or "Hardcore" (drops everything and dies for good).
		DefaultDifficulty = "Classic",
		-- Seconds between saves of a character that changed (and on leaving and shutdown).
		SaveInterval = 60,
		-- Seconds a selected character waits for another server's live lock on it (that server is
		-- still saving it) before the player is told it is open elsewhere.
		LockWait = 30,
		-- What a body may be (HumanoidDescription scales, Roblox's avatar rules): { least, most }.
		-- Body type and proportion 0 are the classic blocky shape. The hull stays Minecraft's
		-- 0.6 x 1.8 blocks whatever the look.
		Scales = {
			height = { 0.9, 1.05 },
			width = { 0.7, 1 },
			depth = { 0.7, 1 },
			head = { 0.95, 1 },
			bodyType = { 0, 1 },
			proportion = { 0, 1 },
		},
		-- Most items of the user's own avatar a character keeps (accessories, clothing, body parts,
		-- animations), and seconds the server waits after an edit before rebuilding the preview.
		MaxAssets = 40,
		PreviewDelay = 0.5,
		-- Reading the user's own avatar (Players:GetHumanoidDescriptionFromUserIdAsync): tries, and
		-- seconds before the second (doubled before each next). An avatar read is kept for the
		-- session; a read that failed every try gives the plain look for SnapshotRetrySeconds only,
		-- and making a character reads again at once rather than keep a failure.
		SnapshotTries = 3,
		SnapshotBackoff = 1,
		SnapshotRetrySeconds = 30,
		-- Make a first character for a returning player from their old progress, and bring the
		-- inventories of their old world records into the first character entering each world.
		Migrate = true,
	},

	-- Accessories and vanity (Terraria's equipment) ----------------------------------------------------

	--[[
		Terraria's accessory slots, vanity armor and vanity accessories (Inventory/Types, Items/
		Accessories; ItemList `accessory`, `vanity`). An accessory works from its slot (Hermes
		Boots, Cloud in a Bottle, Band of Regeneration...); a vanity item only changes what the
		character looks like.
	]]
	Accessories = {
		-- Accessory slots every character has open (Terraria's 5), and the Ages (Shared/
		-- Progression/Ages ids) that open one more each (Terraria's Demon Heart and Master mode):
		-- at most Inventory/Types.ACCESSORY_SIZE (7) in all.
		Slots = 5,
		ExtraSlotAges = { "industrial", "atomic" },
		-- Hermes Boots: ticks of sprinting on the ground before the speed builds, then ticks to build
		-- it to the full `runBoost` (Terraria's run acceleration up to its accRunSpeed).
		RunDelay = 10,
		RunRamp = 12,
		-- A Cloud in a Bottle's jump: take-off speed in blocks a tick (a ground jump is 0.42: 1.25
		-- blocks; 0.36 is 0.96 blocks, Terraria's three quarters of a jump).
		AirJumpPower = 0.36,
	},

	-- Mana and magic -----------------------------------------------------------------------------------

	--[[
		Terraria's mana (Shared/Mana, server Players/Mana): 20 to start, Mana Crystals (five Fallen
		Stars) add 20 each up to 200, accessories more; it comes back by Terraria 1.4.4's
		regeneration (faster standing still and when nearly full) and is spent by magic weapons
		(Wand of Sparking, Emerald Staff, Water Bolt). Mana potions restore it and give Mana
		Sickness. Fallen Stars fall at night.
	]]
	Mana = {
		-- false: no mana (no MANA status icon, no falling stars; magic weapons do nothing).
		Enabled = true,
		-- Mana to start with, per Mana Crystal used, crystals usable, and the most with everything.
		Base = 20,
		PerCrystal = 20,
		MaxCrystals = 9,
		Max = 400,
		-- Mana Sickness: seconds each mana potion adds, the most it reaches, and the share of magic
		-- damage taken off per second left (Terraria: 5 s, 10 s, 5%).
		SicknessSeconds = 5,
		SicknessMax = 10,
		SicknessDamage = 0.05,
		-- Seconds the MANA status icon stays lit after mana changed (it is lit while a magic item is
		-- held or mana is not full, dimmed otherwise).
		HudLinger = 3,
		-- Fallen Stars: each player sees about PerNight a night, falling FallHeight blocks onto the
		-- ground MinDistance..MaxDistance blocks away, between NightStart and NightEnd (time of day,
		-- ticks); at NightEnd the ones still on the ground vanish.
		Stars = {
			Enabled = true,
			PerNight = 5,
			MinDistance = 16,
			MaxDistance = 48,
			FallHeight = 40,
			NightStart = 13000,
			NightEnd = 23000,
		},
	},

	-- Weapons -----------------------------------------------------------------------------------------

	--[[
		Firearms and the melee rework in the manner of DayZ (Shared/Weapons, server Weapons/, client
		Interaction/Firearms): raise to fire, magazines and chambers in the item data, condition and
		jams, server-side ballistics with head shots, noise that draws the infected.
	]]
	Weapons = {
		-- false: firearms never fire (they bash like clubs) and no shot is sent.
		Enabled = true,
		-- Bullets, pellets and bolts hurt players.
		PvP = true,
		-- Damage times this on a head hit: zombies, other mobs, players; a zombie whose look wears a
		-- helmet, hard hat or fire helmet takes this share of a head hit.
		ZombieHead = 3,
		MobHead = 2,
		PlayerHead = 2,
		HelmetShare = 0.6,
		-- Flight: gravity (blocks/s^2), the longest flight (blocks), seconds of flight a segment.
		Gravity = 9.8,
		MaxRange = 256,
		SegmentSeconds = 0.05,
		-- Glass (block names) shatters and the bullet goes on with GlassShare of its damage (not for
		-- players who may not build); bullets pass leaves.
		ShatterGlass = true,
		ShatterBlocks = { "Glass" },
		GlassShare = 0.7,
		PassLeaves = true,
		-- Knockback (blocks a tick) of a bullet and of each pellet (a shot's pellets at most 0.4).
		BulletKnockback = 0.1,
		PelletKnockback = 0.05,
		-- A firearm's hit on a player opens Bleeding this often (Apocalypse.Bleeding's rules).
		BleedChance = 0.5,
		-- Spread: raised in third person, moving, crouching (times the weapon's).
		ShoulderSpread = 1.8,
		MovingSpread = 2,
		CrouchSpread = 0.8,
		-- Sway: moving, crouching, hurt (under half health), not in the sights.
		MovingSway = 2.5,
		CrouchSway = 0.6,
		HurtSway = 1.5,
		ShoulderSway = 1.3,
		-- Holding breath (the sprint key in the sights): seconds, then seconds out of breath, and
		-- the sway factors of each.
		HoldBreathSeconds = 3,
		OutOfBreathSeconds = 3,
		HoldBreathSway = 0.15,
		OutOfBreathSway = 1.5,
		-- Recoil: the share of each kick that comes back and over how long; crouching and shoulder
		-- (third person) factors.
		RecoilRecover = 0.6,
		RecoilRecoverSeconds = 0.25,
		CrouchRecoil = 0.8,
		ShoulderRecoil = 1.2,
		-- Jam chance a shot by condition (Pristine, Worn, Damaged, Badly damaged, Ruined): the
		-- weapon's and its magazine's are added.
		JamChance = { 0, 0.002, 0.01, 0.04, 1 },
		-- Ticks: raised before the first shot, clearing a jam, switching the fire mode.
		RaiseTicks = 6,
		UnjamTicks = 40,
		ModeTicks = 4,
		-- Speed while raised, in the sights and guarding (no sprinting in any of them).
		RaisedSpeed = 0.65,
		SightsSpeed = 0.5,
		GuardSpeed = 0.5,
		-- Field of view divided by this in iron sights (an optic's own zoom instead).
		IronSightsZoom = 1.15,
		-- Third person raised: the camera over the right shoulder (studs), and a centre dot.
		-- The offset is superseded by Camera.Profiles' `raised` rig (Player/CameraRig); it only
		-- applies with Camera.Enabled false.
		ShoulderOffset = { 1.6, 0.4, 0 },
		ShoulderDot = true,
		-- Noise (blocks): at a shot's impact this far or more from the shooter; the least a
		-- suppressed shot makes.
		ImpactNoise = 8,
		SuppressedMinNoise = 8,
		-- Server checks: the claimed origin's distance from the server's eyes, the direction's
		-- length slack, shots a second (bursts of twice that), how far a mob's last-sent position
		-- may be from its own to count for lag compensation.
		OriginSlack = 2.5,
		DirectionSlack = 0.01,
		ShotsPerSecond = 20,
		LagCompMax = 2,
		-- Who is sent a shot (blocks), and beyond what distance its far sound plays instead.
		ShotBroadcast = 256,
		FarSound = 64,
		-- Tracers, and how long they show (seconds).
		Tracers = true,
		TracerSeconds = 0.06,
		-- A crossbow bolt that hits a block drops as an item this often (one that hits a mob:
		-- half): every round Weapons/WeaponList marks `recover` (a switch; this is its only chance).
		BoltRecover = 0.7,
		-- The melee rework (Shared/Weapons/Melee): seconds held for a heavy attack, its knockback
		-- and food exhaustion (times a light hit's), the guard's front cone and the finisher's back
		-- cone (cosines), and the strongest zombie a finisher kills (health).
		Melee = {
			Enabled = true,
			HeavyHold = 0.45,
			HeavyKnockback = 0.8,
			HeavyExhaustion = 3,
			GuardCone = 0.5,
			FinisherCone = 0.5,
			FinisherMaxHealth = 30,
		},
	},

	-- Turrets and the Metal Miner -----------------------------------------------------------------------

	--[[
		Turrets (Shared/Turrets, Machines/Kinds/Turret; server Turrets/, client Rendering/TurretView):
		SMG, Rifle and Sniper turrets in four tiers matching the transmitters'. A turret holds a
		tiny buffer of its calibre's rounds that a Logistical Transporter feeds and Mekanism energy;
		it fires at most the rate of the best transporter tier feeding it (the feeder rule), and its
		gunfire and an idle armed turret's lure at night draw zombies. Numbers per tier are lists
		(Basic, Advanced, Elite, Ultimate); energy is in J, ranges in blocks, angles in degrees.
	]]
	Turrets = {
		-- false: the game as before: the kinds tick inert ("Disabled", no energy taken), no recipes
		-- for turrets, parts or the Laser Sight, no service, no messages, no demand rule (blocks
		-- and items stay registered: ids are append-only).
		Enabled = true,
		-- Per type: its round and stand-in gun (sound, noise; Weapons/WeaponList), damage times the
		-- round's, J a shot, the most degrees off its aim it fires at, the barrel's length (blocks
		-- from the pivot to the muzzle), the lowest pitch it aims at (`pitchMin`, degrees: the
		-- lowest whole degree at which every tier and mount of the type, drawn, clears its own
		-- block at every yaw, never under PitchMin; tests/spec/TurretClient sweeps it), and per
		-- tier its range, rate (rounds a minute), the rounds its ammo slot holds, its turn rate
		-- (degrees a second) and its cone (degrees).
		Types = {
			smg = {
				ammo = "Rounds9mm",
				firearm = "Smg",
				damageScale = 0.85,
				shot = 30,
				settle = 4,
				barrel = 0.7,
				pitchMin = -60,
				range = { 16, 20, 24, 32 },
				rpm = { 90, 150, 240, 360 },
				buffer = { 2, 3, 4, 6 },
				turn = { 180, 240, 300, 360 },
				spread = { 1.6, 1.4, 1.2, 1.0 },
			},
			rifle = {
				ammo = "Rounds556",
				firearm = "AssaultRifle",
				damageScale = 1.0,
				shot = 80,
				settle = 2,
				barrel = 0.85,
				pitchMin = -60,
				range = { 24, 32, 40, 48 },
				rpm = { 45, 75, 120, 180 },
				buffer = { 1, 2, 3, 4 },
				turn = { 120, 150, 180, 240 },
				spread = { 0.6, 0.5, 0.4, 0.3 },
			},
			sniper = {
				ammo = "Rounds308",
				firearm = "HuntingRifle",
				damageScale = 1.0,
				shot = 300,
				settle = 1,
				barrel = 1.0,
				pitchMin = -51,
				range = { 40, 48, 56, 64 },
				rpm = { 15, 20, 30, 40 },
				buffer = { 1, 1, 2, 2 },
				turn = { 60, 75, 90, 120 },
				spread = { 0.25, 0.2, 0.15, 0.1 },
			},
		},
		-- Per tier: the energy store (J, also what the network may put in a tick), J a tick idle
		-- and while tracking a target.
		Capacity = { 20000, 40000, 80000, 160000 },
		IdleJoules = { 4, 8, 12, 16 },
		TrackingJoules = { 8, 16, 24, 32 },
		-- Optics (the optic slot): the Laser Sight tightens the cone and rescans sooner, the Rifle
		-- Scope reaches further (to MaxRange) and lets a sniper aim at heads; the types each fits.
		Optics = {
			LaserSight = { spread = 0.5, scan = 5, types = { "smg", "rifle", "sniper" } },
			-- (`head`: the sniper's only.)
			RifleScope = { range = 1.25, head = true, types = { "rifle", "sniper" } },
		},
		-- Muzzle devices (the muzzle slot; every type takes them): their WeaponList numbers apply.
		Muzzles = { "Suppressor", "ImprovisedSuppressor" },
		-- Gunfire's noise times this (the stand-in gun's, with its muzzle device), at most once
		-- every ShotNoiseTicks a turret.
		NoiseScale = 0.75,
		ShotNoiseTicks = 20,
		-- The lure: a powered, armed turret with no target and its Lure on makes a Noise-block noise
		-- (more at night: the director's factor) every Ticks while it is night or a blood moon, at
		-- most one in each Cell x Cell blocks a time.
		Lure = { Enabled = true, Noise = 24, Ticks = 600, Cell = 48 },
		-- Targeting (ticks): a scan for a target every ScanTicks (a Laser Sight's own `scan`), sight
		-- of the one held checked every SightTicks, lost after LoseTicks unseen; at most
		-- MaxSightChecks candidates looked at a scan (best first, those the scans' pass has not
		-- looked at yet, the best three again every second scan), MaxScansPerTick scans and
		-- MaxShotsPerTick shots a tick for every turret together (those refused go first next
		-- tick, the longest waiting first).
		ScanTicks = 10,
		SightTicks = 4,
		LoseTicks = 10,
		MaxSightChecks = 6,
		MaxScansPerTick = 16,
		MaxShotsPerTick = 32,
		-- Nothing nearer than MinRange blocks; the gun's pitch limits (degrees: PitchMin the lowest
		-- any type aims at, each its own `pitchMin` at or over it, with the pivot
		-- Shared/Turrets/TurretRules.PIVOT; PitchMax the highest); a shot flies ExtraFlight blocks
		-- past the turret's range (at most its round's); no range beyond MaxRange; a turret shows
		-- "Firing" for FiringTicks after a shot.
		MinRange = 1.5,
		PitchMin = -60,
		PitchMax = 75,
		ExtraFlight = 16,
		MaxRange = 80,
		FiringTicks = 10,
		-- The feeder rule's look at the transporters around a turret, every FeedTicks; the panel's
		-- "In: x/s" averages arrivals over FeedRateTicks.
		FeedTicks = 20,
		FeedRateTicks = 100,
		-- Turrets messages: to players within RecordRange blocks (sideways: as far as edit lists
		-- go, Interest.EditChunkRadius chunks, past every chunk a client keeps records for: full
		-- detail's and its neighbours', a turret up to 207 blocks off at the highest settings), at
		-- most every RecordTicks a turret, when its target, flags or ammo change or its aim moved
		-- RecordAngle degrees, and every RecordRefresh ticks while it tracks.
		RecordRange = 224,
		RecordTicks = 2,
		RecordAngle = 3,
		RecordRefresh = 20,
		-- The client: turrets drawn within DrawDistance blocks of the camera, at most MaxDrawn of
		-- them from MaxParts pooled parts; a Laser Sight's beam at most BeamLength long; the servo
		-- loop at the ServoLoops nearest turning turrets.
		Client = { DrawDistance = 96, MaxDrawn = 48, MaxParts = 720, BeamLength = 24, ServoLoops = 4 },
	},

	--[[
		The Metal Miner (Machines/Kinds/Miner, Machines/MinerRules): on an ore block it makes that
		ore's drop forever for energy. Per ore, on its content pack entry (`miner`, Shared/Content):
		ticks an item takes, J a tick, and the least J an item costs whatever its cards (`floor`:
		coal is never worth more energy than it burns for).
	]]
	Miner = {
		-- false: the miner ticks inert and has no recipe (its block stays registered).
		Enabled = true,
		-- Its energy store (J; the network may fill it in a tick), before Energy Upgrades.
		Capacity = 200000,
	},

	--[[
		The Ammo Press (Machines/Kinds/AmmoPress): a Brass Ingot (the cases), a Lead Ingot (the
		bullets) and a Gunpowder pressed into rounds of the calibre its button picks, Ticks ticks
		at Joules J a tick an operation.
	]]
	AmmoPress = {
		-- false: the press ticks inert and has no recipe (its block stays registered).
		Enabled = true,
		-- Its energy store (J; the network may fill it in a tick), before Energy Upgrades.
		Capacity = 20000,
		Ticks = 200,
		Joules = 50,
		-- What one operation makes, by the Calibre button's choice (in its order). The same as
		-- when it took an Iron Ingot: the turrets' feed is balanced on them, and the Metal Miner
		-- copies copper, zinc and lead as it does iron, so the extra ingot costs little.
		Calibres = {
			{ ammo = "Rounds9mm", count = 16 },
			{ ammo = "Rounds556", count = 10 },
			{ ammo = "Rounds308", count = 5 },
		},
	},

	-- GUI scale (client) -------------------------------------------------------------------------------

	--[[
		Minecraft's GUI Scale for every part of the interface (client Ui/GuiScale, Ui/UiScale): the
		automatic scale is the largest that keeps 320 x 240 GUI pixels on the screen, the setting
		picks a smaller one, and touch screens take eighths.
	]]
	UiScale = {
		-- Largest scale (Minecraft has none: a 4K screen's automatic scale is 9).
		MaxScale = 12,
		-- Widgets drawn in fixed pixels (F3, the world map's bar, billboards) were drawn for this
		-- scale (1920 x 1080's automatic one) and keep at least MinReference of their size.
		ReferenceScale = 4,
		MinReference = 0.75,
		-- The minimap's side in GUI pixels (times the scale on screen; Map.MinimapSize is its image).
		Minimap = 56,
	},

	--[[
		The inventory and the HUD's quickbar (client Ui/Theme, Ui/Screens, the quickbar and the
		status icons): drawn in a dark, flat survival-game look.
	]]
	Ui = {
		-- The quickbar's fade: seconds without hotbar activity before it fades (0: never), the
		-- transparency it fades to, and how long the fade takes.
		QuickbarFadeAfter = 0,
		QuickbarFadeTo = 0.6,
		QuickbarFadeTime = 0.6,
		-- The world behind an open inventory blurs (BlurEffect.Size; 0: off); never on touch screens.
		InventoryBlur = 8,
		-- The VICINITY column's GROUND strip shows dropped items within this many blocks (0: none,
		-- the strip stays as the place to throw things), refreshed this often (seconds).
		GroundRadius = 4,
		GroundRefresh = 0.25,
		-- Numbers under the status icons (false: icons, colours and arrows only, like the survival
		-- games they follow).
		StatusValues = false,
	},
}

return Config

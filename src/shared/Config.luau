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

	-- Blocks per chunk along X and Z. Chunks are full-height columns.
	ChunkSize = 16,

	-- World height in blocks. Must be a multiple of SectionHeight and of Lod.MaxVerticalStep.
	WorldHeight = 256,

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
		RevealRadius = 48,
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
		-- Nothing is rendered further away than this (blocks).
		ViewDistance = 2048,
		-- Used instead on phones and tablets (touch screen without keyboard). They also draw parts
		-- much less far than computers do, so a long view distance would only cost memory there.
		Mobile = {
			ViewDistance = 512,
			SplitDistance = 2,
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
		-- Shadows on full detail chunks / on LOD chunks.
		Shadows = true,
		FarShadows = false,
		-- Recycled parts kept around for reuse.
		PoolLimit = 8000,
		-- Fades the edge of the view distance with Lighting fog (ignored if an Atmosphere exists).
		Fog = true,
		-- Use the blocks' MaterialVariant textures / face images (BlockList `texture`, `faces`).
		Textures = true,

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
			-- Seconds a region's chunks must stay unchanged before it is merged.
			StableSeconds = 2,
			-- Triangles per MeshPart (EditableMesh allows 20,000; smaller meshes build in shorter steps).
			MaxTriangles = 10000,
			-- Seconds between mesh builds; none starts after a frame longer than MaxFrameTime seconds.
			BuildInterval = 0.35,
			MaxFrameTime = 1 / 40,
			-- Studs each quad overlaps its neighbours (hides cracks where quads meet).
			Overlap = 0.05,
			-- Meshes stay off when the startup probe sees a build block a frame longer than this (ms).
			MaxBlockingMs = 35,
			-- No new meshes after this many triangles were baked in one session (the engine keeps
			-- baked content for the session; how it is reclaimed is not documented).
			MaxSessionTriangles = 5000000,
		},
	},

	-- Water (client: swimming and currents for the local character) --------------------------------

	Water = {
		-- Fraction of gravity cancelled when fully under water (below 1 = sink slowly).
		Buoyancy = 0.92,
		-- Vertical drag in water (1/s). Sinking speed is about Gravity * (1 - Buoyancy) / Drag.
		Drag = 4,
		-- Upward acceleration (studs/s^2) while Jump is held with the waist under water. Must beat
		-- the gravity left over at waist depth (Gravity * (1 - Buoyancy * 0.55)) to reach the surface.
		SwimUpAcceleration = 110,
		-- Rising speed (studs/s) while climbing out of the water onto a ledge.
		ClimbOutSpeed = 12,
		-- Speed (studs/s) a full strength current carries you at, and how fast (1/s) it gets you
		-- there. The current never slows you down; it only pushes until you move at its speed.
		CurrentSpeed = 8,
		CurrentGain = 3,
		-- Strongest push of the current (studs/s^2) while swimming / while standing on the ground
		-- (the Humanoid brakes hard on the ground, so it needs more there).
		CurrentMaxAcceleration = 40,
		CurrentMaxAccelerationGrounded = 150,
		-- Walk speed multiplier in water.
		WalkSpeedFactor = 0.6,
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
		-- Seconds between repeated breaks / places while a button is held.
		RepeatInterval = 0.2,
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

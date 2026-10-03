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

	-- World height in blocks. Must be a multiple of SectionHeight and of 2^(Lod.Levels - 1).
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
		Levels = 5,
		-- A node is split into four children while the camera is closer than SplitDistance * nodeSize.
		-- Higher = more full detail chunks around the player (radius of LOD 0 is ~2 * SplitDistance chunks).
		SplitDistance = 3,
		-- Nothing is rendered further away than this (blocks).
		ViewDistance = 1024,
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

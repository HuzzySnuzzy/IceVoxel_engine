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
		-- Use the blocks' MaterialVariant textures / face images (BlockList `texture`, `faces`).
		Textures = true,
	},

	-- Water (client: swimming and currents for the local character) --------------------------------

	Water = {
		-- Fraction of gravity cancelled while waist deep / fully under water (1 = weightless).
		Buoyancy = 0.7,
		SubmergedBuoyancy = 1.05,
		-- Push of flowing water in studs/s^2 along the current.
		CurrentAcceleration = 60,
		-- Studs/s: swimming up while Jump is held, fastest sinking speed.
		SwimUpSpeed = 14,
		SinkSpeed = 8,
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
		-- Pixels per side of a map tile, and how many painted tiles are kept in memory.
		TileSize = 64,
		MaxTiles = 160,
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

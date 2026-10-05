--!strict
--[[
	Structures the terrain generator places (Minecraft's jigsaw structures and their
	random_spread placement), read by Structures/Library. A list of entries:

	    {
	        name = "mything",                  -- unique
	        startPool = "mything/centres",     -- a pool or a template name (see Pools.luau)
	        startJigsawName = nil,             -- a jigsaw of the start piece to put on the start
	                                           -- position (default: the piece's corner)
	        size = 6,                          -- jigsaw depth 0..7 (default 7; 0 = the start only)
	        maxDistance = 80,                  -- pieces stay within this many blocks of the
	                                           -- start piece's centre (1..128)
	        biomes = { "Plains", "Savanna" },  -- BiomeList names (default: every biome)
	        spacing = 34, separation = 8,      -- one start per spacing × spacing chunks, at least
	                                           -- separation chunks apart (Minecraft's villages)
	        salt = 12345,                      -- default: a hash of the name
	        startHeight = 0,                   -- added to the ground height (or the y when not
	                                           -- projected)
	        projectToHeightmap = true,         -- start on the ground at the start piece's centre
	        onLand = true,                     -- no start below sea level or on bare rock
	        foundation = true,                 -- fill air under rigid pieces' solid bottom cells
	                                           -- down to the terrain (up to ~12 blocks)
	    },

	A template in ReplicatedStorage.IceVoxelStructures with the Generate attribute adds an entry
	itself (attributes Biomes, Spacing, Separation, Size, Foundation, OnLand, StartHeight,
	MaxDistance).
]]

return {
	-- The example: a watchtower (or its ruin) with paths, huts, a storehouse (a chest of supplies)
	-- and a forge (Templates/Outpost.luau, built by tests/build_structures.luau; Pools.luau). Rare:
	-- at most one per 56 x 56 chunks (896 x 896 blocks), in grassland and forests.
	{
		name = "outpost",
		startPool = "outpost/centres",
		size = 3,
		maxDistance = 48,
		biomes = { "Plains", "Savanna", "Meadow", "Forest" },
		spacing = 56,
		separation = 14,
	},
}

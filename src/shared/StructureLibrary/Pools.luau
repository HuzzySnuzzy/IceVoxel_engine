--!strict
--[[
	Explicit template pools (Minecraft's template_pool files), read by Structures/Library.

	Most structures need none: a pool name with no entry here is the template with exactly that
	name, else every template whose name starts with "<pool>/" (weight 1, rigid; a template in
	ReplicatedStorage.IceVoxelStructures with the TerrainMatching attribute is terrain matching).
	Add an entry for weights, empty elements, a fallback pool or terrain matching repo pieces:

	    ["mything/streets"] = {
	        fallback = "mything/terminators", -- tried after the elements, and alone at the last
	                                          -- level (end caps); default: none
	        projection = "terrain_matching",  -- default for the elements: "rigid" (as built) or
	                                          -- "terrain_matching" (each column follows the ground)
	        elements = {
	            { template = "mything/streets/straight", weight = 4 },   -- weight 1..150, default 1
	            { template = "mything/streets/crossing", weight = 1, projection = "rigid" },
	            { empty = true, weight = 2 },  -- the empty element: the jigsaw stays unused
	        },
	    },

	Pools are keyed by name; elements are tried in a weighted random order.
]]

type Element = { template: string?, weight: number?, empty: boolean?, projection: string? }
type Pool = { fallback: string?, projection: string?, elements: { Element } }

local pools: { [string]: Pool } = {
	-- The example outpost (Templates/Outpost.luau, built by tests/build_structures.luau). Its start
	-- pool "outpost/centres" needs no entry: it is every template named "outpost/centres/...".

	-- Paths follow the ground; at the last level (and where nothing else fits) they end in a lamp
	-- post or fade out.
	["outpost/paths"] = {
		projection = "terrain_matching",
		fallback = "outpost/path_ends",
		elements = {
			{ template = "outpost/paths/straight", weight = 5 },
			{ template = "outpost/paths/crossing", weight = 1 },
			{ template = "outpost/paths/turn_east", weight = 1 },
			{ template = "outpost/paths/turn_west", weight = 1 },
		},
	},
	["outpost/path_ends"] = {
		projection = "terrain_matching",
		elements = {
			{ template = "outpost/path_ends/lamp", weight = 2 },
			{ template = "outpost/path_ends/fade", weight = 1 },
		},
	},
	-- What stands along the paths: some plots stay empty.
	["outpost/houses"] = {
		elements = {
			{ template = "outpost/houses/hut", weight = 3 },
			{ template = "outpost/houses/storehouse", weight = 2 },
			{ template = "outpost/houses/forge", weight = 2 },
			{ template = "outpost/houses/woodpile", weight = 1 },
			{ empty = true, weight = 2 },
		},
	},
}

return pools

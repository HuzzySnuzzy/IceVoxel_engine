--!strict
--[[
	Which blocks make a spawn (or teleport) spot unsafe. Edit freely; names must exist in BlockList,
	and a fluid name (e.g. "Water") covers every level of that fluid.

	A spot is safe when:
	  * the block the player stands on is solid and not listed in `Floor`,
	  * the `Headroom` blocks the body occupies are not solid and not listed in `Body`,
	  * no block next to the body (the four sides, at body height) or right under the floor's sides
	    is listed in `Hazards`,
	  * the feet are not below the natural terrain surface (no spawning inside caves).

	See SafeSpot.luau for the search that uses these rules.
]]

return {
	-- Never stand on these.
	Floor = {
		"Cactus",
		"OakLeaves",
		"BirchLeaves",
		"SpruceLeaves",
		"AcaciaLeaves",
		"JungleLeaves",
	},

	-- Never stand inside these (a fluid's name covers its cave twin too: CaveLava, CaveOil).
	Body = {
		"Water",
		"Lava",
		"Oil",
		"Fuel",
	},

	-- Never stand next to these (lava burns a player whose box reaches into it).
	Hazards = {
		"Cactus",
		"Lava",
	},

	-- Free blocks needed above the floor (the default character is ~1.7 blocks tall).
	Headroom = 2,

	-- How far (in blocks) to search around the desired spot for a safe one.
	SearchRadius = 48,
}

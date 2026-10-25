--!strict
--[[
	The Minecraft pack's terrain: the ground the generator lays down (bedrock, stone, dirt and the
	grass blocks, sand, gravel, snow and ice; the mountains', rivers' and islands' packed ice,
	calcite, packed mud, mycelium, podzol and coarse dirt; the stone varieties Generation/Ores
	places by altitude), water, lava (and its cave twin) and obsidian.

	  * Water and lava are fluid groups (Content/Define's `fluid`: a source, seven flows and the
	    falling block; Shared/Fluids' ids, server Behaviours/Fluid's rules). Lava (Minecraft
	    1.20.1's, in the overworld): light 15 in every level, a Neon orange surface (its light is
	    sparse: the client lights only some of its cells, as glow lichen's), tick delay 30.
	    CaveLava is its source's cave twin (`caveFluid`): it fills the caves' lava seas and
	    underground lava lakes, a source in every way but cave air while caves are hidden.
	  * Obsidian (Minecraft's): what water makes of a lava source. Hardness 50, only a diamond
	    pickaxe gets it (9.4 s; by hand 250 s and nothing), drops itself.
	  * blastResistance: Minecraft 1.20.1's where it differs from the hardness (stone 6, packed mud
	    3, obsidian 1200; Properties.strength(f) gives both, so the rest keep their hardness).
	  * zombieBreak: ticks one ordinary zombie needs (server Mobs/MobAI): soil soon (300), stone
	    in two minutes (2400); nothing else here breaks.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return function(define: Define.Context): { Schema.BlockSpec }
	local list: { Schema.BlockSpec } = {
		{ name = "Bedrock", color = { 45, 45, 50 }, material = "Basalt", breakable = false, placeable = false },
		{
			name = "Stone",
			color = { 125, 125, 128 },
			material = "Slate",
			hardness = 1.5,
			blastResistance = 6,
			drops = "Cobblestone",
			tool = "pickaxe",
			toolLevel = 0,
			zombieBreak = 2400,
		},
		{
			name = "Cobblestone",
			color = { 110, 110, 112 },
			material = "Cobblestone",
			hardness = 2,
			blastResistance = 6,
			tool = "pickaxe",
			toolLevel = 0,
			zombieBreak = 2400,
		},
		{
			name = "Dirt",
			color = { 121, 85, 58 },
			material = "Ground",
			hardness = 0.5,
			tool = "shovel",
			zombieBreak = 300,
		},
		{
			name = "Grass",
			tool = "shovel",
			color = { 92, 158, 62 },
			material = "Grass",
			behaviour = "Grass",
			hardness = 0.6,
			drops = "Dirt",
			zombieBreak = 300,
		},
		{
			name = "DryGrass",
			tool = "shovel",
			color = { 168, 162, 84 },
			material = "Grass",
			behaviour = "Grass",
			hardness = 0.6,
			drops = "Dirt",
			-- Grass and ferns on it: Minecraft's savanna #BFB755 in this game's palette, a little
			-- greener than the block itself so they read against it.
			foliageColor = { 156, 160, 76 },
			zombieBreak = 300,
		},
		{
			name = "Snow",
			color = { 238, 242, 248 },
			material = "Snow",
			hardness = 0.2,
			tool = "shovel",
			toolLevel = 0,
			drops = "Snowball" :: string,
			dropCount = 4,
			zombieBreak = 300,
		},
		{
			name = "Sand",
			color = { 220, 206, 160 },
			material = "Sand",
			behaviour = "Gravity",
			hardness = 0.5,
			tool = "shovel",
			zombieBreak = 300,
		},
		{
			name = "Sandstone",
			color = { 206, 188, 138 },
			material = "Sandstone",
			hardness = 0.8,
			tool = "pickaxe",
			toolLevel = 0,
			zombieBreak = 2400,
		},
		{
			name = "Gravel",
			color = { 132, 126, 122 },
			material = "Pebble",
			behaviour = "Gravity",
			hardness = 0.6,
			tool = "shovel",
			zombieBreak = 300,
		},
		{
			name = "Ice",
			color = { 165, 205, 240 },
			material = "Glacier",
			friction = 0.98,
			hardness = 0.5,
			drops = false,
			tool = "pickaxe",
		},
	}

	define.append(
		list,
		define.fluid("Water", {
			name = "Water",
			color = { 44, 106, 196 },
			material = "Glass",
			transparency = 0.45,
			reflectance = 0.05,
		}, 5)
	)

	-- Mountains, rivers and islands (terrain generator).
	define.append(list, {
		{
			name = "PackedIce",
			color = { 141, 180, 236 },
			material = "Ice",
			friction = 0.98,
			hardness = 0.5,
			drops = false,
			tool = "pickaxe",
		},
		{
			name = "Calcite",
			color = { 222, 223, 218 },
			material = "Marble",
			hardness = 0.75,
			tool = "pickaxe",
			toolLevel = 0,
		},
		-- (Darker than Dirt: the texture pack draws it as "darker dirt", dirt's image in this colour.)
		{
			name = "PackedMud",
			color = { 97, 68, 46 },
			material = "Mud",
			hardness = 1,
			blastResistance = 3,
			tool = "pickaxe",
			zombieBreak = 300,
		},
		{
			name = "Mycelium",
			tool = "shovel",
			color = { 122, 104, 116 },
			material = "Grass",
			behaviour = "Grass",
			hardness = 0.6,
			drops = "Dirt" :: string,
			zombieBreak = 300,
		},
		{
			name = "Podzol",
			tool = "shovel",
			color = { 106, 74, 38 },
			material = "Ground",
			behaviour = "Grass",
			hardness = 0.5,
			drops = "Dirt" :: string,
			zombieBreak = 300,
		},
		{
			name = "CoarseDirt",
			color = { 112, 80, 56 },
			material = "Ground",
			hardness = 0.5,
			tool = "shovel",
			zombieBreak = 300,
		},
		-- Stone varieties by altitude (Generation/Ores; the ore features are the pack's `ores`).
		{
			name = "Andesite",
			color = { 134, 134, 136 },
			material = "Rock",
			hardness = 1.5,
			blastResistance = 6,
			tool = "pickaxe",
			toolLevel = 0,
		},
		{
			name = "Diorite",
			color = { 190, 190, 190 },
			material = "Limestone",
			hardness = 1.5,
			blastResistance = 6,
			tool = "pickaxe",
			toolLevel = 0,
		},
		{
			name = "Granite",
			color = { 150, 103, 85 },
			material = "Granite",
			hardness = 1.5,
			blastResistance = 6,
			tool = "pickaxe",
			toolLevel = 0,
		},
	})

	-- Lava, and its source's cave twin.
	local lava = define.fluid("Lava", {
		name = "Lava",
		color = { 212, 90, 20 },
		material = "Neon",
		light = 15,
		lightColor = { 255, 140, 60 },
	}, 30)
	define.append(list, lava)
	table.insert(list, define.caveFluid(lava[1]))

	table.insert(list, {
		name = "Obsidian",
		color = { 30, 22, 44 },
		material = "Basalt",
		hardness = 50,
		blastResistance = 1200,
		tool = "pickaxe",
		toolLevel = 3,
	})
	return list
end

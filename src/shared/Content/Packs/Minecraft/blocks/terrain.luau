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
	  * Gravel gives Flint one time in 10 in place of itself (its `loot`: Minecraft's gravel loot
	    table without Fortune), broken by a player or a blast.
	  * Ice, packed ice (and blocks/building's blue ice) need Silk Touch in Minecraft, which the
	    game has not: ice gives nothing, and packed ice drops itself with a pickaxe, the stand-in
	    for Silk Touch (`toolLevel` 0: by hand it mines 3.3 times slower, 2.5 s where Minecraft's
	    takes 0.75, and gives nothing; any pickaxe takes Minecraft's time), so it and what is made
	    of it (blue ice, the Survival pack's Air Conditioner) can be had. A blast takes it without
	    a drop, as Minecraft's (`silkTouch`: only its tool gets it, Items.blockDrops).
	  * Tough As Nails: ice, packed ice and snow chill a player near them (`cools`), lava warms
	    (`heats`: every level, and CaveLava).
	  * Spawns and teleports never land in water, nor in or beside lava (`spawnUnsafe`: every
	    level, and CaveLava; server Players/SafeSpot).
	  * knowledge: smelting cobblestone into stone gives Minecraft's furnace experience, 0.1.
	  * blastResistance: Minecraft 1.20.1's where it differs from the hardness (stone 6, packed mud
	    3, obsidian 1200; Properties.strength(f) gives both, so the rest keep their hardness).
	  * zombieBreak: ticks one ordinary zombie needs (server Mobs/MobAI): soil soon (300), stone
	    in two minutes (2400); nothing else here breaks.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return function(define: Define.Context): { Schema.BlockSpec }
	local list: { Schema.BlockSpec } = {
		{
			name = "Bedrock",
			color = { 45, 45, 50 },
			material = "Basalt",
			breakable = false,
			placeable = false,
			texture = { All = "bedrock" },
		},
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
			texture = { All = "stone" },
			lore = "Common rock. Breaks into Cobblestone.",
			knowledge = { smelt = 0.1 },
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
			texture = { All = "cobblestone" },
			lore = "Rough stone for tools, furnaces and walls. Smelts back into Stone.",
		},
		{
			name = "Dirt",
			color = { 121, 85, 58 },
			material = "Ground",
			hardness = 0.5,
			tool = "shovel",
			zombieBreak = 300,
			texture = { All = "dirt" },
			lore = "Soil that plants grow on.",
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
			texture = { Top = "grass top", Sides = "grass side", Bottom = "dirt" },
			lore = "Dirt with a grassy top. Breaks into Dirt.",
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
			-- (The same grass top in DryGrass's own colour; sides of its own, not the green
			-- fringe.)
			texture = { Top = "grass top", Sides = "dry grass side", Bottom = "dirt" },
			lore = "Sun-baked savanna turf. Breaks into Dirt.",
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
			texture = { All = "snow" },
			lore = "Packed snow. Dig it with a shovel for Snowballs. Chills you when close.",
			cools = true,
		},
		{
			name = "Sand",
			color = { 220, 206, 160 },
			material = "Sand",
			behaviour = "Gravity",
			hardness = 0.5,
			tool = "shovel",
			zombieBreak = 300,
			texture = { All = "sand" },
			lore = "Loose sand that falls. Smelts into Glass; four make Sandstone.",
		},
		{
			name = "Sandstone",
			color = { 206, 188, 138 },
			material = "Sandstone",
			hardness = 0.8,
			tool = "pickaxe",
			toolLevel = 0,
			zombieBreak = 2400,
			texture = { Top = "sandstone top", Sides = "sandstone side", Bottom = "sandstone bottom" },
			lore = "Sand pressed into stone. Cut or smelt it for a finer face.",
		},
		{
			name = "Gravel",
			color = { 132, 126, 122 },
			material = "Pebble",
			behaviour = "Gravity",
			hardness = 0.6,
			tool = "shovel",
			zombieBreak = 300,
			texture = { All = "gravel" },
			lore = "Loose stones that fall. Sometimes gives Flint.",
			loot = { { rolls = { 1, 1 }, entries = { { "Flint", 1, 1, 1 }, { false, 9, 0, 0 } } } } :: { Schema.Pool },
		},
		{
			name = "Ice",
			color = { 165, 205, 240 },
			material = "Glacier",
			friction = 0.98,
			hardness = 0.5,
			drops = false,
			tool = "pickaxe",
			texture = { All = "ice" },
			lore = "Slippery frozen water. Chills you when close.",
			cools = true,
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
			lore = "A water source. Fill bottles and buckets from it.",
			spawnUnsafe = "in",
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
			tool = "pickaxe",
			-- (A pickaxe for Silk Touch: see the header.)
			toolLevel = 0,
			silkTouch = true,
			texture = { All = "packed ice" },
			lore = "Ice packed hard. Mine it with a pickaxe to keep it. Chills you when close.",
			cools = true,
		},
		{
			name = "Calcite",
			color = { 222, 223, 218 },
			material = "Marble",
			hardness = 0.75,
			tool = "pickaxe",
			toolLevel = 0,
			texture = { All = "calcite" },
			lore = "Pale stone from mountain sides.",
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
			texture = { All = "packed mud" },
			lore = "Dried mud, firm enough to build with.",
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
			texture = { Top = "mycelium top", Sides = "mycelium side", Bottom = "dirt" },
			lore = "Mushroom soil from far-off fields. Breaks into Dirt.",
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
			texture = { Top = "podzol top", Sides = "podzol side", Bottom = "dirt" },
			lore = "Forest floor of needles. Mushrooms grow on it.",
		},
		{
			name = "CoarseDirt",
			color = { 112, 80, 56 },
			material = "Ground",
			hardness = 0.5,
			tool = "shovel",
			zombieBreak = 300,
			texture = { All = "coarse dirt" },
			lore = "Dirt mixed with gravel.",
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
			texture = { All = "andesite" },
			lore = "Gray igneous stone. Polish four into tiles.",
		},
		{
			name = "Diorite",
			color = { 190, 190, 190 },
			material = "Limestone",
			hardness = 1.5,
			blastResistance = 6,
			tool = "pickaxe",
			toolLevel = 0,
			texture = { All = "diorite" },
			lore = "Speckled white stone. Polish four into tiles.",
		},
		{
			name = "Granite",
			color = { 150, 103, 85 },
			material = "Granite",
			hardness = 1.5,
			blastResistance = 6,
			tool = "pickaxe",
			toolLevel = 0,
			texture = { All = "granite" },
			lore = "Pink-red stone. Polish four into tiles.",
		},
	})

	-- Lava, and its source's cave twin.
	local lava = define.fluid("Lava", {
		name = "Lava",
		color = { 212, 90, 20 },
		material = "Neon",
		light = 15,
		lightColor = { 255, 140, 60 },
		lore = "Molten rock. Burns anything that touches it.",
		heats = true,
		spawnUnsafe = "near",
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
		texture = { All = "obsidian" },
		lore = "Cooled lava, all but unbreakable. Needs a diamond pickaxe.",
	})
	return list
end

--!strict
--[[
	Vanilla Minecraft (1.20.1) as this game has it: the features below, each a file of its kind
	folders (blocks/, items/, recipes/, textures/), the mineshafts' loot (loot), the vanilla ore
	features (ores), the biomes (biomes), the status effects (effects) and the potions (potions).
	The pack's own shape and model helpers are _shapes and _models; the shared ones are
	Content/Define's.

	  terrain     the ground, stones, sand, snow and ice, water and lava (and CaveLava), obsidian:
	              blocks/terrain, textures/terrain, recipes/stone (and its ice and snow), ores
	  building    bricks, glass, stone bricks, smooth and polished stones, cut and smooth
	              sandstone, blue ice: blocks/building, textures/building, recipes/stone, smelting
	  ores        coal, iron, gold, diamond and emerald ore and their storage blocks, raw iron and
	              gold, ingots, nuggets, gems: blocks/ores, items/materials, recipes/minerals,
	              recipes/smelting, textures/ores, ores
	  wood        logs, leaves and planks of five trees, the stick: blocks/wood, items/materials,
	              recipes/wood, textures/wood
	  plants      the cactus, grass, ferns, the dead bush, flowers, tall flowers, mushrooms and
	              saplings: blocks/plants, textures/plants (_shapes' grass, bushes and sunflower)
	  lights      torches (and the mineshafts' cave twins of the wall torches), the Glow Block,
	              lanterns, glow lichen, Glow Dust: blocks/lights, items/lights, recipes/lights,
	              textures/lights (_shapes' lichen)
	  workshop    the chest, crafting table and furnace: blocks/crafting, recipes/wood and stone,
	              textures/crafting
	  fire        fire, TNT and the Nuke (which came with TNT: its uranium recipe is the Ores
	              pack's), flint, flint and steel, gunpowder: blocks/fire, items/fire,
	              recipes/fire, textures/fire
	  wool        White Wool: blocks/wool, recipes/mobs, textures/wool
	  doors       oak, spruce, birch, jungle and acacia doors: blocks/doors, recipes/doors,
	              textures/doors
	  fences      the Oak Fence (and its cave twin): blocks/fences, recipes/mineshafts
	  mineshafts  ladders, rope, rails, cobwebs, moss, vines, hanging roots, mossy cobblestone and
	              their cave twins, the mineshafts' loot: blocks/mineshafts, recipes/mineshafts,
	              textures/mineshafts, loot
	  structures  structure blocks, the structure void and jigsaws: blocks/structures
	  tools       wood, stone, iron, gold and diamond tools, the Shears: items/tools,
	              recipes/tools (_models' shears)
	  armor       leather, chainmail, iron, gold and diamond armor: items/armor, recipes/tools and
	              mobs
	  buckets     the bucket, water and lava buckets: items/buckets, recipes/buckets
	  mob drops   leather, meat, feathers, rotten flesh, bones and string, cooked meat:
	              items/mobs, recipes/mobs (_models' meat)
	  effects     Minecraft's status effects, and its Hunger (with the food bar): effects
	  potions     Minecraft's potions, and this game's Haste and Resistance: potions (Content
	              brews each into its items, drinks included, and their recipes, after the pack's
	              own)
	  biomes      the 18 biomes, their climate, weather, ground, trees, ground plants and biome
	              tags, in the generator's order: biomes (the Survival pack adds its herbs)

	Calls made here: Glow Dust and glow lichen are the lights' (the Glow Block is the game's
	glowstone); White Wool is the mob drops' (sheep); the mineshafts' loot table is whole here,
	though its fourth pool holds the Terraria pack's finds (a table is one pack's); fences have a
	file of their own though the mineshafts brought them. Entries name other packs' items freely
	(potions brew from the Survival pack's Purified Water Bottle, rope from its Straw): names are
	checked once every pack has loaded.
]]
return {
	order = 100,
	description = "Vanilla Minecraft: terrain, stone, ores, wood, plants, lights, doors, tools, armor, food, effects, potions, mineshafts, biomes.",
	requires = { "Core" },
}

--!strict
--[[
	The Ores pack's metals (Content/Define's `metal`), shared by its blocks, items, recipes and
	textures: copper, lead, zinc, brass and uranium, each with its colours and what its pieces say
	of themselves (lore, Age, knowledge, the Metal Miner's numbers, radiation).

	  * The ores are stone with coloured specks (Granite's speckled material, as Osmium Ore):
	    Minecraft's hardness 3 and a stone pickaxe to drop anything; uranium needs an iron one
	    (Mekanism's uranium is as hard as its osmium, but this game keeps it for later). Each drops
	    one of its raw metal.
	  * The storage blocks: Minecraft's raw blocks' hardness 5 for every one (the Block of Copper
	    Minecraft's 3) and its blast resistance 6, as every metal block (a Block of Lead, the
	    radiation shield, stands a blast as iron's does), a stone pickaxe (iron for uranium); the
	    metal blocks sound like metal, the raw ones like rock.
	  * The lumps, ingots and nuggets are drawn like iron's and gold's in each metal's colour:
	    copper orange, lead a dull blue-grey, zinc a pale grey-green, brass yellow, uranium
	    green-grey. Brass is an alloy (three copper ingots and a zinc ingot: the pack's recipes), so
	    it has no ore, raw lump or raw block.
	  * Ages: copper is the Stone Age's; lead, zinc and brass (ingots, nuggets, blocks) the Iron
	    Age's; uranium's ingot the Industrial Age's (smelting results are never of a later Age:
	    transporters feed furnaces ungated), its nugget and blocks the Atomic Age's. The ores and raw
	    lumps are mined in any Age.
	  * Knowledge (Minecraft's ore experience): mining a metal ore again gives 2 (as iron and
	    osmium), uranium's 3 (as gold); smelting an ingot 0.7 (Minecraft's copper ingot), uranium's
	    1 (as gold).
	  * The Metal Miner copies each ore (its `miner`): the metals as iron (400 ticks an item at
	    200 J a tick), uranium as rare as emerald (3600 at 800).
	  * The ores, with the pack's sulfur and saltpetre ores, are in the `ores` block tag (a tool's
	    tooltip lists them first).
	  * Radiation (Sv/h a block away or carried; Shared/Radiation): an ore's uranium is spread
	    through rock (1), and Raw Uranium is mostly rock too (0.3); an ingot is the refined metal,
	    forty lumps' worth (12), a nugget a ninth of it (1.33); the storage blocks are nine of their
	    item (2.7 and 108). So mining a vein bare skinned for a few minutes makes you mildly sick
	    (I), a stack of Raw Uranium carried for several minutes sick (II), a Block of Uranium beside
	    you is dangerous (II within a minute or two, III if you stay), and a vein a few blocks into
	    the rock is safe (tests/spec/Radiation plays these out). Lead shields: a Block of Lead lets
	    through 0.02 of it, a Block of Raw Lead 0.1 (any other solid block Config.Radiation
	    .Shielding.Solid).
]]

local Define = require(script.Parent.Parent.Parent.Define)

-- The metals, by name.
local metals: { [string]: Define.MetalSpec } = {
	Copper = {
		name = "Copper",
		level = 1,
		colors = {
			ore = { 170, 124, 98 },
			block = { 196, 110, 76 },
			rawBlock = { 156, 92, 64 },
			raw = { 176, 102, 70 },
			ingot = { 214, 124, 84 },
			light = { 236, 168, 120 },
			dark = { 112, 62, 40 },
		},
		oreBlock = {
			lore = "Gives Raw Copper, brass's main metal.",
			knowledge = { mine = 2 },
			miner = { ticks = 400, joules = 200 },
			tags = { "ores" },
		},
		storageBlock = { hardness = 3, lore = "Nine copper ingots in one block." },
		rawBlock = { lore = "Nine Raw Copper, kept compact." },
		rawItem = { lore = "Smelt it into a Copper Ingot." },
		ingotItem = { lore = "Three of them and a zinc ingot make four brass.", knowledge = { smelt = 0.7 } },
		nuggetItem = { lore = "A ninth of a copper ingot." },
	},
	Lead = {
		name = "Lead",
		level = 1,
		colors = {
			ore = { 122, 122, 142 },
			block = { 106, 108, 132 },
			rawBlock = { 94, 96, 116 },
			raw = { 100, 102, 124 },
			ingot = { 122, 124, 148 },
			light = { 160, 162, 186 },
			dark = { 64, 66, 84 },
		},
		oreBlock = {
			lore = "Gives Raw Lead: bullets and radiation shielding.",
			knowledge = { mine = 2 },
			miner = { ticks = 400, joules = 200 },
			tags = { "ores" },
		},
		storageBlock = { lore = "Nine lead ingots in one block.", age = "iron", radiationShield = 0.02 },
		rawBlock = { lore = "Nine Raw Lead, kept compact.", age = "iron", radiationShield = 0.1 },
		rawItem = { lore = "Smelt it into a Lead Ingot." },
		ingotItem = {
			lore = "Soft, heavy metal: bullets and the Hazmat suit.",
			age = "iron",
			knowledge = { smelt = 0.7 },
		},
		nuggetItem = { lore = "A ninth of a lead ingot.", age = "iron" },
	},
	Zinc = {
		name = "Zinc",
		level = 1,
		colors = {
			ore = { 150, 162, 152 },
			block = { 186, 196, 192 },
			rawBlock = { 150, 162, 158 },
			raw = { 156, 168, 162 },
			ingot = { 188, 198, 194 },
			light = { 218, 226, 222 },
			dark = { 104, 116, 110 },
		},
		oreBlock = {
			lore = "Gives Raw Zinc, alloyed with copper into brass.",
			knowledge = { mine = 2 },
			miner = { ticks = 400, joules = 200 },
			tags = { "ores" },
		},
		storageBlock = { lore = "Nine zinc ingots in one block.", age = "iron" },
		rawBlock = { lore = "Nine Raw Zinc, kept compact.", age = "iron" },
		rawItem = { lore = "Smelt it into a Zinc Ingot." },
		ingotItem = {
			lore = "With three copper ingots it makes four brass.",
			age = "iron",
			knowledge = { smelt = 0.7 },
		},
		nuggetItem = { lore = "A ninth of a zinc ingot.", age = "iron" },
	},
	Brass = {
		name = "Brass",
		level = 1,
		ore = false,
		colors = { block = { 206, 170, 84 }, ingot = { 214, 178, 88 } },
		storageBlock = { lore = "Nine brass ingots in one block.", age = "iron" },
		ingotItem = { lore = "Copper and zinc: cartridge cases for the Ammo Press.", age = "iron" },
		nuggetItem = { lore = "A ninth of a brass ingot.", age = "iron" },
	},
	Uranium = {
		name = "Uranium",
		level = 2,
		colors = {
			ore = { 122, 152, 98 },
			block = { 112, 170, 72 },
			rawBlock = { 98, 130, 72 },
			raw = { 104, 138, 80 },
			ingot = { 124, 176, 84 },
			light = { 176, 220, 120 },
			dark = { 64, 90, 48 },
		},
		oreBlock = {
			lore = "Radioactive. Gives Raw Uranium.",
			knowledge = { mine = 3 },
			miner = { ticks = 3600, joules = 800 },
			tags = { "ores" },
			radiation = 1,
		},
		storageBlock = {
			lore = "Nine uranium ingots in one block. Very radioactive.",
			age = "atomic",
			radiation = 108,
		},
		rawBlock = { lore = "Nine Raw Uranium, kept compact. Radioactive.", age = "atomic", radiation = 2.7 },
		rawItem = { lore = "Radioactive. Smelt it into a Uranium Ingot.", radiation = 0.3 },
		ingotItem = {
			lore = "Radioactive. Nine make the Block of Uranium, the Nuke's core.",
			age = "industrial",
			knowledge = { smelt = 1 },
			radiation = 12,
		},
		nuggetItem = { lore = "A ninth of a uranium ingot. A little radioactive.", age = "atomic", radiation = 1.33 },
	},
}

return metals

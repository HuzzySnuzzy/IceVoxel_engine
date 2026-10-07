--!strict
--[[
	The Ages, in order: what each one opens and what it takes to enter it. Data, pure. (No mod or
	Minecraft version has Ages; the shape is a tech tree's, as GregTech's tiers or the "eras" of a
	strategy game: each one a set of recipes and a gate of knowledge and milestones, fitted to what
	this game has.)

	  Stone Age       the start. Everything no later Age names: wood, planks, sticks, crafting
	                  tables, chests, furnaces, wooden and stone tools, torches, the Glow Block,
	                  stone bricks and polished stones, glass, smelting (iron ore and raw iron
	                  into ingots too: smelting the first iron ingot is the way into the Iron
	                  Age), Tough As Nails' basics (Glass Bottles, Bowls, mint and teas, the
	                  Campfire, Straw and Leaf armor). Whatever is added to the game later starts
	                  here unless an Age names it.
	  Iron Age        (level 5, a Furnace crafted, an Iron Ingot smelted) iron and gold: iron and
	                  golden tools and armor, iron and gold blocks and nuggets, gold smelting,
	                  Shears, the Bucket, Flint and Steel, the Lantern, the Canteen and the
	                  Thermometer, and osmium smelting.
	  Industrial Age  (level 15, an Osmium Ingot smelted, a Bucket crafted) diamond tools and
	                  armor, diamond, emerald and osmium blocks, osmium nuggets, Mekanism's basic
	                  and advanced transporters, pipes and fluid tanks, the Configurator, the
	                  Heat Generator, and Gunpowder and TNT (with the Demolition skill too).
	  Electric Age    (level 25, a Heat Generator crafted, 6 biomes discovered) basic and advanced
	                  Universal Cables, the Electric Furnace, basic and advanced Batteries, the
	                  upgrade cards, the Oil Refinery and the Combustion Generator, elite
	                  transporters, pipes and tanks.
	  Atomic Age      (level 40, an Oil Refinery and a Basic Battery crafted) the Solar Panel,
	                  elite and ultimate cables and Batteries, ultimate transporters, pipes and
	                  tanks, and the Nuke (with the Fission skill too).

	An Age's `recipes` are the results (item names) it opens: crafting and smelting results of a
	later Age are locked for a player who hasn't reached it (Shared/Progression.allows; how:
	Inventory/Menu). `milestones` are discoveries (Progression/Knowledge categories): one key
	("craft" "Furnace": crafted a Furnace at least once), or `count` of a category ("biome" 6).
	`level` is the knowledge level it needs. Reaching an Age is automatic once all are met (the
	server checks after every change), Ages one after another; it gives `reward` points (a
	discovery: Forager's perk counts).

	Ids (`id`) are what saves keep, so an Age may be renamed or a new one inserted without
	breaking them; the list's order is the order they come in.
]]

export type Milestone = {
	-- Knowledge category ("craft", "smelt", "mine", "biome", "mob").
	category: string,
	-- One discovery (an item, block, biome or mob name)...
	key: string?,
	-- ...or this many discoveries of the category.
	count: number?,
	text: string,
}

export type Age = {
	index: number,
	id: string,
	name: string,
	-- Knowledge level it needs.
	level: number,
	milestones: { Milestone },
	-- Points for reaching it.
	reward: number,
	-- Result item names it opens.
	recipes: { string },
	-- The banner's colour (r, g, b 0-255): the toast and the skill tree's column.
	color: { number },
}

local TOOLS = { "Pickaxe", "Axe", "Shovel", "Hoe", "Sword" }
local ARMOR = { "Helmet", "Chestplate", "Leggings", "Boots" }

-- Names `prefix` .. each of `pieces`, added to `list`.
local function each(list: { string }, prefix: string, pieces: { string }): { string }
	for _, piece in pieces do
		table.insert(list, prefix .. piece)
	end
	return list
end

local iron: { string } = {}
each(iron, "Iron", TOOLS)
each(iron, "Iron", ARMOR)
each(iron, "Golden", TOOLS)
each(iron, "Gold", ARMOR)
for _, name in
	{
		"IronBlock",
		"RawIronBlock",
		"IronNugget",
		"GoldIngot",
		"GoldNugget",
		"GoldBlock",
		"RawGoldBlock",
		"Shears",
		"Bucket",
		"FlintAndSteel",
		"Lantern",
		"Canteen",
		"Thermometer",
		"OsmiumIngot",
	}
do
	table.insert(iron, name)
end

local industrial: { string } = {}
each(industrial, "Diamond", TOOLS)
each(industrial, "Diamond", ARMOR)
for _, name in
	{
		"DiamondBlock",
		"EmeraldBlock",
		"OsmiumBlock",
		"RawOsmiumBlock",
		"OsmiumNugget",
		"BasicLogisticalTransporter",
		"RestrictiveTransporter",
		"BasicMechanicalPipe",
		"BasicFluidTank",
		"AdvancedLogisticalTransporter",
		"AdvancedMechanicalPipe",
		"AdvancedFluidTank",
		"Configurator",
		"HeatGenerator",
		"Gunpowder",
		"Tnt",
	}
do
	table.insert(industrial, name)
end

local electric: { string } = {
	"BasicUniversalCable",
	"AdvancedUniversalCable",
	"ElectricFurnace",
	"BasicBattery",
	"AdvancedBattery",
	"SpeedUpgrade",
	"EnergyUpgrade",
	"OilRefinery",
	"CombustionGenerator",
	"EliteLogisticalTransporter",
	"EliteMechanicalPipe",
	"EliteFluidTank",
}

local atomic: { string } = {
	"SolarPanel",
	"EliteUniversalCable",
	"UltimateUniversalCable",
	"EliteBattery",
	"UltimateBattery",
	"UltimateLogisticalTransporter",
	"UltimateMechanicalPipe",
	"UltimateFluidTank",
	"Nuke",
}

local list: { Age } = {
	{
		index = 1,
		id = "stone",
		name = "Stone Age",
		level = 0,
		milestones = {},
		reward = 0,
		recipes = {},
		color = { 150, 150, 150 },
	},
	{
		index = 2,
		id = "iron",
		name = "Iron Age",
		level = 5,
		milestones = {
			{ category = "craft", key = "Furnace", text = "Craft a Furnace" },
			{ category = "smelt", key = "IronIngot", text = "Smelt an Iron Ingot" },
		},
		reward = 50,
		recipes = iron,
		color = { 216, 216, 216 },
	},
	{
		index = 3,
		id = "industrial",
		name = "Industrial Age",
		level = 15,
		milestones = {
			{ category = "smelt", key = "OsmiumIngot", text = "Smelt an Osmium Ingot" },
			{ category = "craft", key = "Bucket", text = "Craft a Bucket" },
		},
		reward = 100,
		recipes = industrial,
		color = { 196, 140, 80 },
	},
	{
		index = 4,
		id = "electric",
		name = "Electric Age",
		level = 25,
		milestones = {
			{ category = "craft", key = "HeatGenerator", text = "Craft a Heat Generator" },
			{ category = "biome", count = 6, text = "Discover 6 biomes" },
		},
		reward = 150,
		recipes = electric,
		color = { 255, 214, 64 },
	},
	{
		index = 5,
		id = "atomic",
		name = "Atomic Age",
		level = 40,
		milestones = {
			{ category = "craft", key = "OilRefinery", text = "Craft an Oil Refinery" },
			{ category = "craft", key = "BasicBattery", text = "Craft a Basic Battery" },
		},
		reward = 200,
		recipes = atomic,
		color = { 110, 255, 120 },
	},
}

local Ages = {}

Ages.list = list
Ages.count = #list

local byId: { [string]: Age } = {}
-- Result item name -> the index of the Age that opens it.
local ageOfName: { [string]: number } = {}
-- Every milestone of every Age, in order (the protocol's bits).
local milestones: { Milestone } = {}
for index, age in list do
	assert(age.index == index, `Ages: {age.id} is listed at {index}`)
	assert(byId[age.id] == nil, `Ages: duplicate id {age.id}`)
	byId[age.id] = age
	for _, name in age.recipes do
		assert(ageOfName[name] == nil, `Ages: {name} is named by two Ages`)
		ageOfName[name] = index
	end
	for _, milestone in age.milestones do
		assert((milestone.key == nil) ~= (milestone.count == nil), `Ages: {age.id} milestone needs a key or a count`)
		table.insert(milestones, milestone)
	end
end
Ages.MILESTONES = milestones

-- The Age with id `id`, or nil.
function Ages.byId(id: string): Age?
	return byId[id]
end

-- The Age at `index` (1..count), or nil.
function Ages.get(index: number): Age?
	return list[index]
end

-- The index of the Age that opens result `name` (1, the Stone Age, for everything not named).
function Ages.ofName(name: string): number
	return ageOfName[name] or 1
end

-- The names each Age opens (for checks: every name must be a real item).
function Ages.names(): { [string]: number }
	return table.clone(ageOfName)
end

-- Is `milestone` met by the discoveries `found` (category -> key -> true)?
function Ages.met(milestone: Milestone, found: { [string]: { [string]: boolean } }): boolean
	local keys = found[milestone.category]
	local key = milestone.key
	if key then
		return keys ~= nil and keys[key] == true
	end
	local count = 0
	if keys then
		for _ in keys do
			count += 1
		end
	end
	return count >= (milestone.count :: number)
end

return Ages

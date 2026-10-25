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
	                  Campfire, Straw and Leaf armor), and what comes of the mobs' drops (cooked
	                  meat, leather armor, White Wool from String). Whatever is added to the game
	                  later starts here unless an Age names it.
	  Iron Age        (level 5, a Furnace crafted, an Iron Ingot smelted) iron and gold: iron and
	                  golden tools and armor, iron and gold blocks and nuggets, gold smelting,
	                  Shears, the Bucket, Flint and Steel, the Lantern, the Canteen and the
	                  Thermometer, Rails, osmium smelting, and brewing: every potion's base variant
	                  (Shared/Effects/PotionList; Minecraft's brewing waits for the Nether) and the
	                  Mana Potion; Terraria's Aglet, Anklet of the Wind, Band of Starpower,
	                  Obsidian Skull, Emerald Staff and Tuxedo (the Mana Crystal, Lesser Mana
	                  Potion and Top Hat are the Stone Age's); the apocalypse's Nails, Reinforced
	                  Barricade, Spiked Bat, Machete, Crowbar, Ceiling Lamp and Bunker Hatch (its
	                  Rag, Bandage, Medkit, Herbal Poultice, Barricade, Baseball Bat, Supply
	                  Crate and aged bricks are the Stone Age's; loot ignores Ages); the seasons'
	                  Wood Stove, Insulated Glass and Insulated Door (the Snow Layer and
	                  Insulated Planks are the Stone Age's); lead, zinc and brass (ingots,
	                  nuggets, blocks) and the Hazmat suit (copper, Sulfur and Saltpetre are the
	                  Stone Age's).
	  Industrial Age  (level 15, an Osmium Ingot smelted, a Bucket crafted) diamond tools and
	                  armor, diamond, emerald and osmium blocks, osmium nuggets, Mekanism's basic
	                  and advanced transporters, pipes and fluid tanks, the Configurator, the
	                  Heat Generator, Gunpowder and TNT (with the Demolition skill too), uranium
	                  smelting (no smelting result may come later: transporters feed furnaces
	                  ungated), the potions' strong (II) and long variants, Concrete (cracked
	                  and mossy too) and the Oil Heater.
	  Electric Age    (level 25, a Heat Generator crafted) basic and advanced
	                  Universal Cables, the Electric Furnace, basic and advanced Batteries, the
	                  upgrade cards, the Oil Refinery and the Combustion Generator, elite
	                  transporters, pipes and tanks, the Electric Heater, the Air Conditioner
	                  and the Electric Fan, the turret parts, the Laser Sight, the Basic,
	                  Advanced and Elite turrets, the Metal Miner and the Ammo Press.
	  Atomic Age      (level 40, an Oil Refinery and a Basic Battery crafted) the Solar Panel,
	                  elite and ultimate cables and Batteries, ultimate transporters, pipes and
	                  tanks, the Ultimate turrets, uranium's nuggets and blocks and the Nuke
	                  (with the Fission skill too).

	The Ages themselves are the content packs' `ages` (Shared/Content: Core's), in order. An Age's
	`recipes` are the results (item names) it opens: every block and item entry naming it (`age =
	"iron"`; Content checks the id), in id order. Crafting and smelting results of a later Age are
	locked for a player who hasn't reached it (Shared/Progression.allows; how: Inventory/Menu).
	`milestones` are discoveries (Progression/Knowledge categories): one key ("craft" "Furnace":
	crafted a Furnace at least once), or `count` of a category ("biome" 6). `level` is the
	knowledge level it needs. Reaching an Age is automatic once all are met (the server checks
	after every change), Ages one after another; it gives `reward` points (a discovery: Forager's
	perk counts).

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

local Content = require(script.Parent.Parent.Content)

local content = Content.default

-- The Ages: the packs' records, each with the results it opens (below: every entry naming it).
local list: { Age } = {}
for index, record in content.ages do
	table.insert(list, {
		index = index,
		id = record.id,
		name = record.name,
		level = record.level,
		milestones = record.milestones,
		reward = record.reward,
		recipes = {},
		color = record.color,
	})
end

local Ages = {}

Ages.list = list
Ages.count = #list

local byId: { [string]: Age } = {}
-- Result item name -> the index of the Age that opens it.
local ageOfName: { [string]: number } = {}
-- Every milestone of every Age, in order (the protocol's bits).
local milestones: { Milestone } = {}
for _, age in list do
	assert(byId[age.id] == nil, `Ages: duplicate id {age.id}`)
	byId[age.id] = age
	for _, milestone in age.milestones do
		assert((milestone.key == nil) ~= (milestone.count == nil), `Ages: {age.id} milestone needs a key or a count`)
		table.insert(milestones, milestone)
	end
end
-- The entries' own Ages (Content checked every id).
for _, entry in content.entries do
	local id = entry.age
	if id then
		local age = byId[id] :: Age
		table.insert(age.recipes, entry.name)
		ageOfName[entry.name] = age.index
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

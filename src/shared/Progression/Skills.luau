--!strict
--[[
	The skill tree: nodes grouped by Age, each unlocked with skill points (one per knowledge level,
	Progression/Knowledge) once its Age is reached and its prerequisites are unlocked. Data, pure.

	A node's `perk` is one small, real effect, applied where the game decides that thing (the same
	function on the client's prediction and the server's check where both decide it):

	  knowledge   `sources` ("discovery", "ore", "all": Knowledge.SOURCES) give `bonus` more
	              (Shared/Progression.knowledgeFactor: 1 + the bonuses that apply, added)
	  mining      mining speed x `factor` with tools of `tiers` (item name prefixes: "Stone" is
	              StonePickaxe, StoneAxe...; none: any tool) (Shared/Mining's `factor`, from
	              Progression.miningFactor: the client's mining and the server's break check)
	  wear        a tool's wear point is skipped with chance `chance` (Unbreaking's way; several
	              combine: 1 - (1 - a)(1 - b)) (Progression.wearChance, server
	              Players/Progression.wear on ServerNet's wearTool)
	  thirst      thirst drains x `factor` as fast (several multiply) (ToughAsNails/Thirst.tick's
	              `rate`, server Players/ToughAsNails)
	  insulation  `steps` more of both warmth and cooling, as armor gives (towards neutral either
	              way) (server Players/ToughAsNails, Climate's insulation)
	  boiling     a campfire boils dirty water `speed` x as fast (ToughAsNails/Boiling.ready's
	              `speed`: the client's wait and the server's check)

	A node may also name `recipes` (result item names) it unlocks: those stay locked until the
	node is unlocked, besides their Age (Demolition: Gunpowder and TNT; Fission: the Nuke).
	`row` places it on the skill tree screen (Ui/SkillTreeScreen: a column per Age), `icon` is
	the item drawn in its frame. Three branches run across the Ages: knowledge (rows 1 and 2),
	tools (3 and 4), survival (5 and 6).

	  Stone Age (1 point)       Forager, Quarrying, Hardy, Firekeeper
	  Iron Age (2 points)       Smithing, Prospector, Insulation, Ironworking
	  Industrial Age (3 points) Demolition, Scholar, Tempering, Diamond Cutting
	  Electric Age (4 points)   Thermoregulation, Endurance, Polymath
	  Atomic Age (5 points)     Fission, Mastery, Enlightenment

	51 points for the whole tree: level 51, past the Atomic Age's 40, so a player picks a path
	first and fills the rest in late.

	ALWAYS ADD NEW NODES AT THE END: the protocol numbers them by their place in the list (saves
	keep their ids).
]]

local Ages = require(script.Parent.Ages)

export type Perk = {
	kind: "knowledge" | "mining" | "wear" | "thirst" | "insulation" | "boiling" | "none",
	sources: { string }?,
	bonus: number?,
	tiers: { string }?,
	factor: number?,
	chance: number?,
	steps: number?,
	speed: number?,
}

export type Skill = {
	index: number,
	id: string,
	name: string,
	description: string,
	-- The skill tree screen's row (1..ROWS; its column is its Age) and the item drawn in its frame.
	row: number,
	icon: string,
	-- The Age it belongs to (Ages index) and its cost in skill points.
	age: number,
	cost: number,
	-- Ids of the nodes it needs.
	requires: { string },
	perk: Perk,
	-- Result item names it unlocks (besides their Age).
	recipes: { string },
}

type Spec = {
	id: string,
	row: number,
	icon: string,
	name: string,
	description: string,
	age: string,
	requires: { string }?,
	perk: Perk,
	recipes: { string }?,
}

local NONE: Perk = { kind = "none" }

local SPECS: { Spec } = {
	{
		id = "forager",
		row = 1,
		icon = "OakSapling",
		name = "Forager",
		description = "+10% knowledge from discoveries",
		age = "stone",
		perk = { kind = "knowledge", sources = { "discovery" }, bonus = 0.1 },
	},
	{
		id = "quarrying",
		row = 3,
		icon = "StonePickaxe",
		name = "Quarrying",
		description = "Mine 10% faster with stone tools",
		age = "stone",
		perk = { kind = "mining", tiers = { "Stone" }, factor = 1.1 },
	},
	{
		id = "hardy",
		row = 5,
		icon = "PurifiedWaterBottle",
		name = "Hardy",
		description = "Thirst drains 10% slower",
		age = "stone",
		perk = { kind = "thirst", factor = 0.9 },
	},
	{
		id = "firekeeper",
		row = 6,
		icon = "Campfire",
		name = "Firekeeper",
		description = "A campfire boils water twice as fast",
		age = "stone",
		requires = { "hardy" },
		perk = { kind = "boiling", speed = 2 },
	},
	{
		id = "smithing",
		row = 3,
		icon = "IronIngot",
		name = "Smithing",
		description = "Tools wear 15% slower",
		age = "iron",
		requires = { "quarrying" },
		perk = { kind = "wear", chance = 0.15 },
	},
	{
		id = "prospector",
		row = 1,
		icon = "RawIron",
		name = "Prospector",
		description = "Ores give twice the knowledge",
		age = "iron",
		requires = { "forager" },
		perk = { kind = "knowledge", sources = { "ore" }, bonus = 1 },
	},
	{
		id = "insulation",
		row = 5,
		icon = "StrawChestplate",
		name = "Insulation",
		description = "A step of warmth and of cooling, as armor",
		age = "iron",
		requires = { "hardy" },
		perk = { kind = "insulation", steps = 1 },
	},
	{
		id = "ironworking",
		row = 4,
		icon = "IronPickaxe",
		name = "Ironworking",
		description = "Mine 10% faster with iron and golden tools",
		age = "iron",
		requires = { "quarrying" },
		perk = { kind = "mining", tiers = { "Iron", "Golden" }, factor = 1.1 },
	},
	{
		id = "demolition",
		row = 2,
		icon = "Tnt",
		name = "Demolition",
		description = "Unlocks Gunpowder and TNT",
		age = "industrial",
		requires = { "prospector" },
		perk = NONE,
		recipes = { "Gunpowder", "Tnt" },
	},
	{
		id = "scholar",
		row = 1,
		icon = "Torch",
		name = "Scholar",
		description = "+10% knowledge from everything",
		age = "industrial",
		requires = { "prospector" },
		perk = { kind = "knowledge", sources = { "all" }, bonus = 0.1 },
	},
	{
		id = "tempering",
		row = 3,
		icon = "IronSword",
		name = "Tempering",
		description = "Tools wear another 15% slower",
		age = "industrial",
		requires = { "smithing" },
		perk = { kind = "wear", chance = 0.15 },
	},
	{
		id = "diamondCutting",
		row = 4,
		icon = "DiamondPickaxe",
		name = "Diamond Cutting",
		description = "Mine 10% faster with diamond tools",
		age = "industrial",
		requires = { "ironworking" },
		perk = { kind = "mining", tiers = { "Diamond" }, factor = 1.1 },
	},
	{
		id = "thermoregulation",
		row = 5,
		icon = "Thermometer",
		name = "Thermoregulation",
		description = "One more step of warmth and of cooling",
		age = "electric",
		requires = { "insulation" },
		perk = { kind = "insulation", steps = 1 },
	},
	{
		id = "endurance",
		row = 6,
		icon = "Canteen",
		name = "Endurance",
		description = "Thirst drains another 10% slower",
		age = "electric",
		requires = { "hardy" },
		perk = { kind = "thirst", factor = 0.9 },
	},
	{
		id = "polymath",
		row = 1,
		icon = "Lantern",
		name = "Polymath",
		description = "+15% knowledge from everything",
		age = "electric",
		requires = { "scholar" },
		perk = { kind = "knowledge", sources = { "all" }, bonus = 0.15 },
	},
	{
		id = "fission",
		row = 2,
		icon = "Nuke",
		name = "Fission",
		description = "Unlocks the Nuke",
		age = "atomic",
		requires = { "demolition" },
		perk = NONE,
		recipes = { "Nuke" },
	},
	{
		id = "mastery",
		row = 4,
		icon = "DiamondAxe",
		name = "Mastery",
		description = "Mine 10% faster with any tool",
		age = "atomic",
		requires = { "diamondCutting" },
		perk = { kind = "mining", factor = 1.1 },
	},
	{
		id = "enlightenment",
		row = 1,
		icon = "GlowBlock",
		name = "Enlightenment",
		description = "+25% knowledge from everything",
		age = "atomic",
		requires = { "polymath" },
		perk = { kind = "knowledge", sources = { "all" }, bonus = 0.25 },
	},
}

local Skills = {}

-- Rows of the skill tree screen (a node's `row`; an Age's nodes never share one).
Skills.ROWS = 6

local list: { Skill } = {}
local byId: { [string]: Skill } = {}
-- Result item name -> the skill that unlocks it.
local skillOfName: { [string]: Skill } = {}
-- Nodes by Age (Ages index), in list order.
local byAge: { { Skill } } = {}
for index = 1, Ages.count do
	byAge[index] = {}
end

for index, spec in SPECS do
	local age = Ages.byId(spec.age)
	assert(age, `Skills: {spec.id} names an unknown Age {spec.age}`)
	assert(byId[spec.id] == nil, `Skills: duplicate id {spec.id}`)
	local skill: Skill = {
		index = index,
		id = spec.id,
		name = spec.name,
		description = spec.description,
		row = spec.row,
		icon = spec.icon,
		age = age.index,
		-- (A point for each Age past the first: 1 in the Stone Age, 5 in the Atomic Age.)
		cost = age.index,
		requires = spec.requires or {},
		perk = spec.perk,
		recipes = spec.recipes or {},
	}
	assert(skill.row >= 1 and skill.row <= Skills.ROWS, `Skills: {spec.id} is on row {skill.row}`)
	for _, other in byAge[skill.age] do
		assert(other.row ~= skill.row, `Skills: {spec.id} and {other.id} share a row in their Age`)
	end
	for _, required in skill.requires do
		local before = byId[required]
		assert(before, `Skills: {spec.id} needs {required}, which must come before it`)
		assert(before.age <= skill.age, `Skills: {spec.id} needs {required} of a later Age`)
	end
	for _, name in skill.recipes do
		assert(skillOfName[name] == nil, `Skills: {name} is unlocked by two skills`)
		skillOfName[name] = skill
	end
	byId[skill.id] = skill
	table.insert(list, skill)
	table.insert(byAge[skill.age], skill)
end

Skills.list = list
Skills.count = #list

-- The node with id `id`, or nil.
function Skills.byId(id: string): Skill?
	return byId[id]
end

-- The node at `index` (its place in the list), or nil.
function Skills.get(index: number): Skill?
	return list[index]
end

-- The nodes of the Age at `age` (an Ages index), in list order.
function Skills.ofAge(age: number): { Skill }
	return byAge[age] or {}
end

-- The node whose unlock a result item name also needs, or nil.
function Skills.ofName(name: string): Skill?
	return skillOfName[name]
end

-- Points the whole tree costs.
function Skills.totalCost(): number
	local total = 0
	for _, skill in list do
		total += skill.cost
	end
	return total
end

return Skills

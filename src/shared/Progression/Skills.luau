--!strict
--[[
	The skill tree: nodes grouped by Age, each unlocked with skill points (one per knowledge level,
	Progression/Knowledge) once its Age is reached and its prerequisites are unlocked. Pure.

	The nodes are the content packs' `skills` (Shared/Content; Content/Schema's SKILL_FIELDS say
	what each field is), in load order: Core's knowledge and tools branches, the Minecraft pack's
	Demolition and Fission, the Survival pack's survival branch. A node's place in that order is
	its position (`index`), what the protocol sends as a u8 (UnlockSkill, Progress), so at most MAX
	nodes; saves keep ids. Content checks each node's Age, icon, prerequisites (known, of its Age or
	an earlier one, never in a loop) and cell (one node to an Age's row), and every entry's
	`skill`; this module what only it knows: the row is on the screen (1..ROWS), the icon is an
	item, the perk's knowledge sources and tool tiers are the game's.

	A node's `perk` is one small, real effect, applied where the game decides that thing (the same
	function on the client's prediction and the server's check where both decide it). The kinds
	are code, the closed set Content/Schema's SKILL_PERKS checks a perk against:

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
	  none        no effect of its own: the node is there for its `recipes`

	A node's `recipes` (result item names) stay locked until the node is unlocked, besides their
	Age (Demolition: Gunpowder and TNT; Fission: the Nuke): every content pack entry naming the
	node (`skill = "demolition"`), in id order. `row` places it on the skill tree screen
	(Ui/SkillTreeScreen: a column per Age, ROWS rows), `icon` is the item drawn in its frame. Three
	branches run across the Ages: knowledge (rows 1 and 2), tools (3 and 4), survival (5 and 6).

	  Stone Age (1 point)       Forager, Quarrying, Hardy, Firekeeper
	  Iron Age (2 points)       Smithing, Prospector, Insulation, Ironworking
	  Industrial Age (3 points) Demolition, Scholar, Tempering, Diamond Cutting
	  Electric Age (4 points)   Thermoregulation, Endurance, Polymath
	  Atomic Age (5 points)     Fission, Mastery, Enlightenment

	A node costs its Age's number in points (its `cost`): 51 for the whole tree, level 51, past the
	Atomic Age's 40, so a player picks a path first and fills the rest in late.
]]

local Ages = require(script.Parent.Ages)
local Knowledge = require(script.Parent.Knowledge)
local Content = require(script.Parent.Parent.Content)
local Schema = require(script.Parent.Parent.Content.Schema)
local Items = require(script.Parent.Parent.Items)

export type Perk = Schema.SkillPerk

export type Skill = {
	-- Its place among every pack's nodes (the protocol's u8).
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

local Skills = {}

-- Rows of the skill tree screen (a node's `row`; an Age's nodes never share one). The screen is
-- this many rows tall, short enough for GUI scale 3 on 900 pixel tall screens.
Skills.ROWS = 6
-- Most nodes: the protocol sends a node's place as a u8 (1-based; 0 is none).
Skills.MAX = 255

local content = Content.default

local list: { Skill } = {}
local byId: { [string]: Skill } = {}
-- Result item name -> the skill that unlocks it.
local skillOfName: { [string]: Skill } = {}
-- Nodes by Age (Ages index), in list order.
local byAge: { { Skill } } = {}
for index = 1, Ages.count do
	byAge[index] = {}
end

assert(
	#content.skills <= Skills.MAX,
	`Skills: {#content.skills} nodes, more than the {Skills.MAX} the protocol numbers (a u8 each)`
)
-- What a knowledge perk may name ("all": every source), and the tools' names (a mining perk's
-- tiers are their prefixes).
local sources: { [string]: boolean } = { all = true }
for _, source in Knowledge.SOURCES do
	sources[source] = true
end
local tools: { string } = {}
for _, def in Items.list do
	if def.tool then
		table.insert(tools, def.name)
	end
end

for index, record in content.skills do
	local where = content.where("skill", record.id)
	-- (Content checked the Age, the icon's name, the prerequisites and the cell.)
	local age = Ages.byId(record.age) :: Ages.Age
	assert(
		record.row <= Skills.ROWS,
		`Skills: {where}: row {record.row} is off the skill tree (rows 1..{Skills.ROWS}, the screen's)`
	)
	assert(Items.find(record.icon) ~= nil, `Skills: {where}: icon {record.icon} is a block that is no item`)
	local perk = record.perk
	for _, source in (perk.sources or {}) :: { string } do
		if not sources[source] then
			local near = Schema.suggest(source, sources)
			local hint = if near then ` (did you mean {near}?)` else ""
			error(`Skills: {where}'s perk names unknown knowledge source {source}{hint}`, 0)
		end
	end
	for _, tier in (perk.tiers or {}) :: { string } do
		local fits = false
		for _, name in tools do
			if string.sub(name, 1, #tier) == tier then
				fits = true
				break
			end
		end
		assert(fits, `Skills: {where}'s perk's tier {tier} begins no tool's name`)
	end
	local skill: Skill = {
		index = index,
		id = record.id,
		name = record.name,
		description = record.description,
		row = record.row,
		icon = record.icon,
		age = age.index,
		cost = record.cost,
		requires = table.clone(record.requires or {}),
		perk = table.clone(perk),
		recipes = {},
	}
	byId[skill.id] = skill
	table.insert(list, skill)
	table.insert(byAge[skill.age], skill)
end

-- The entries naming a node (`skill`; Content checked every id).
for _, entry in content.entries do
	local id = entry.skill
	if id then
		local skill = byId[id]
		table.insert(skill.recipes, entry.name)
		skillOfName[entry.name] = skill
	end
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

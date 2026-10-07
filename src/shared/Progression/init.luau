--!strict
--[[
	Progression: knowledge (this game's experience), the Ages and the skill tree, shared and pure
	(no Roblox APIs, so the tests run it). The server plays it out (server Players/Progression:
	awards, Ages, skills, saving, the commands) and sends each player their own state (Protocol
	Progress), which the client draws (Ui/Hud's knowledge bar and level, Ui/AgeToast, the skill
	tree screen Ui/SkillTreeScreen) and gates crafting with in its prediction.

	  Knowledge   Minecraft's experience curve, the sources and their numbers, the repeats'
	              fatigue and budget (Progression/Knowledge)
	  Ages        Stone, Iron, Industrial, Electric and Atomic: the recipes each opens, the level
	              and milestones each needs (Progression/Ages)
	  Skills      the tree: nodes by Age, costs, prerequisites, perks (Progression/Skills)

	A player's State: `points` (total knowledge, a whole number), `age` (an Ages index, 1 the
	Stone Age), `skills` (unlocked node ids) and `found` (discoveries: category -> key -> true,
	the "first time" of Knowledge). Its level is Knowledge.levelOf(points); skill points are the
	level minus what the unlocked nodes cost (`skillPoints`).

	  award       knowledge from a source, times the perks for it (`knowledgeFactor`), fractions
	              carried in the player's Session (Knowledge.carry)
	  discover    a first time: its category's points, once ever (Knowledge.DISCOVERY)
	  mined, crafted, smelted, visited, killed
	              what the server's events give (discoveries and repeats, Knowledge); a block a
	              player placed gives nothing
	  advance     enters every Age whose level and milestones are met, one after another,
	              giving each Age's reward (a discovery: "age")
	  canUnlock / unlock
	              a node: its Age reached, its prerequisites unlocked, enough skill points
	  allows      may a player make an item (crafting and smelting results)? Its Age reached and
	              the node that names it unlocked; nil state (no player: the tests' grids,
	              Config.Progression off, creative players) allows everything
	  perks       knowledgeFactor, miningFactor, wearChance / wear, thirstRate, insulation,
	              boilSpeed: what the unlocked nodes add up to (Skills' perk kinds); `perk(state,
	              id)` is whether one node is unlocked
	  die         Config.Progression.DeathLoss of the progress into the current level is lost;
	              levels, the Age, skills and discoveries never are (0: nothing is lost, the
	              default: knowledge is learning, which a death doesn't undo)
	  toRecord / fromRecord
	              the saved form (DataStore, server Players/ProgressStore), read back
	              migration-safe: garbage reads as a fresh start, unknown skills are dropped, an
	              unknown Age reads as the Stone Age (and is reached again by `advance`); a
	              record of another version reads as a fresh start that must not be saved over
	              (its second result), so an old server never overwrites a newer one's record
	  status      the Progress message's content: points, Age, skills, counts of discoveries by
	              category and which milestones are met
]]

local Items = require(script.Parent.Items)
local Ages = require(script.Ages)
local Knowledge = require(script.Knowledge)
local Skills = require(script.Skills)

export type Age = Ages.Age
export type Skill = Skills.Skill
export type Session = Knowledge.Session

export type State = {
	points: number,
	age: number,
	skills: { [string]: boolean },
	found: { [string]: { [string]: boolean } },
}

-- What the client knows of its player (Protocol Progress).
export type Status = {
	points: number,
	age: number,
	skills: { [string]: boolean },
	-- Discoveries by category (Knowledge.CATEGORIES).
	counts: { [string]: number },
	-- Ages.MILESTONES met, in order.
	milestones: { boolean },
}

local Progression = {}

Progression.Knowledge = Knowledge
Progression.Ages = Ages
Progression.Skills = Skills

-- The saved record's version.
Progression.RECORD_VERSION = 1
-- Most discoveries a category keeps in a record, and the longest key.
Progression.MAX_FOUND = 4096
Progression.MAX_KEY = 64

-- Item id -> the Age index / the skill a result needs (only those past the Stone Age / named).
local ageOfItem: { [number]: number } = {}
local skillOfItem: { [number]: Skill } = {}
for name, index in Ages.names() do
	local ok, id = pcall(function()
		return Items.id[name]
	end)
	assert(ok and id, `Progression: Age {index} names an unknown item {name}`)
	ageOfItem[id] = index
end
for _, skill in Skills.list do
	for _, name in skill.recipes do
		local ok, id = pcall(function()
			return Items.id[name]
		end)
		assert(ok and id, `Progression: {skill.name} names an unknown item {name}`)
		skillOfItem[id] = skill
	end
end

--[[ State ]]

function Progression.new(): State
	return { points = 0, age = 1, skills = {}, found = {} }
end

function Progression.level(state: State): number
	return Knowledge.levelOf(state.points)
end

-- Skill points the unlocked nodes cost.
function Progression.spent(state: State): number
	local spent = 0
	for id in state.skills do
		local skill = Skills.byId(id)
		if skill then
			spent += skill.cost
		end
	end
	return spent
end

-- Skill points left to spend (one per level, never below 0).
function Progression.skillPoints(state: State): number
	return math.max(Progression.level(state) - Progression.spent(state), 0)
end

-- Sets the total points (whole, 0..Knowledge.MAX_POINTS).
function Progression.setPoints(state: State, points: number)
	if points ~= points then
		points = 0
	end
	state.points = math.clamp(math.floor(points), 0, Knowledge.MAX_POINTS)
end

-- Adds whole points (negative takes away); returns the levels gained (negative: lost).
function Progression.addPoints(state: State, points: number): number
	local before = Progression.level(state)
	Progression.setPoints(state, state.points + points)
	return Progression.level(state) - before
end

--[[ Knowledge ]]

-- 1 + the bonuses of the unlocked knowledge perks for `source` (Knowledge.SOURCES).
function Progression.knowledgeFactor(state: State?, source: string): number
	local factor = 1
	if state == nil then
		return factor
	end
	for id in state.skills do
		local skill = Skills.byId(id)
		local perk = skill and skill.perk
		if perk and perk.kind == "knowledge" and perk.sources then
			for _, wanted in perk.sources do
				if wanted == "all" or wanted == source then
					factor += perk.bonus or 0
					break
				end
			end
		end
	end
	return factor
end

--[[
	Knowledge `amount` (a fraction or more) from `source`, times the perks for it; the whole points
	it makes now are added (the fraction waits in the session). Returns them.
]]
function Progression.award(state: State, session: Session, amount: number, source: string): number
	if not (amount > 0) then
		return 0
	end
	local whole = Knowledge.carry(session, amount * Progression.knowledgeFactor(state, source))
	if whole > 0 then
		Progression.addPoints(state, whole)
	end
	return whole
end

-- Has the player discovered `key` in `category`?
function Progression.found(state: State, category: string, key: string): boolean
	local keys = state.found[category]
	return keys ~= nil and keys[key] == true
end

-- Discoveries in `category`.
function Progression.count(state: State, category: string): number
	local keys = state.found[category]
	local count = 0
	if keys then
		for _ in keys do
			count += 1
		end
	end
	return count
end

--[[
	The first time of `key` in `category`: its points (Knowledge.discovery; an "age" its Age's
	reward). Returns the whole points given (0 when it was known, or the key is no proper name).
]]
function Progression.discover(state: State, session: Session, category: string, key: string): number
	if key == "" or #key > Progression.MAX_KEY or #category > Progression.MAX_KEY then
		return 0
	end
	local keys = state.found[category]
	if keys == nil then
		keys = {}
		state.found[category] = keys
	end
	if keys[key] then
		return 0
	end
	keys[key] = true
	local base
	if category == "age" then
		local age = Ages.byId(key)
		base = if age then age.reward else 0
	else
		base = Knowledge.discovery(category)
	end
	return Progression.award(state, session, base, "discovery")
end

--[[
	A repeat of `key` worth `base` from `source` at `now` (seconds), within `budget` repeat points a
	minute (Knowledge.repeatPoints: fatigue, the bucket). The perks multiply `base` before the
	bucket, so all repeats together give at most `budget` a minute, perks or not. Returns the whole
	points given.
]]
function Progression.repeatAction(
	state: State,
	session: Session,
	key: string,
	base: number,
	source: string,
	now: number,
	budget: number
): number
	local points = Knowledge.repeatPoints(session, key, base * Progression.knowledgeFactor(state, source), now, budget)
	local whole = Knowledge.carry(session, points)
	if whole > 0 then
		Progression.addPoints(state, whole)
	end
	return whole
end

--[[
	A survival player broke block `blockName` (`placed`: a player had placed it, the edit list
	says): its discovery and, for ores and logs, a repeat. Nothing for a placed block.
]]
function Progression.mined(
	state: State,
	session: Session,
	blockName: string,
	placed: boolean,
	now: number,
	budget: number
): number
	if placed then
		return 0
	end
	local given = Progression.discover(state, session, "mine", blockName)
	local base, source = Knowledge.minePoints(blockName)
	if base > 0 then
		given += Progression.repeatAction(state, session, `{source}:{blockName}`, base, source, now, budget)
	end
	return given
end

-- A crafting result `itemName` was taken (one craft): its discovery and a repeat.
function Progression.crafted(state: State, session: Session, itemName: string, now: number, budget: number): number
	return Progression.discover(state, session, "craft", itemName)
		+ Progression.repeatAction(state, session, `craft:{itemName}`, Knowledge.CRAFT, "craft", now, budget)
end

-- `count` of `itemName` were taken out of a furnace's or machine's output: its discovery and a
-- repeat worth every item.
function Progression.smelted(
	state: State,
	session: Session,
	itemName: string,
	count: number,
	now: number,
	budget: number
): number
	return Progression.discover(state, session, "smelt", itemName)
		+ Progression.repeatAction(
			state,
			session,
			`smelt:{itemName}`,
			Knowledge.smeltPoints(itemName) * math.max(count, 0),
			"smelt",
			now,
			budget
		)
end

-- The player stood in biome `biomeName`: its discovery.
function Progression.visited(state: State, session: Session, biomeName: string): number
	return Progression.discover(state, session, "biome", biomeName)
end

-- The player killed a mob of kind `mobName`: its discovery and a repeat (Knowledge.MOBS).
function Progression.killed(state: State, session: Session, mobName: string, now: number, budget: number): number
	return Progression.discover(state, session, "mob", mobName)
		+ Progression.repeatAction(state, session, `mob:{mobName}`, Knowledge.mobPoints(mobName), "mob", now, budget)
end

--[[ Ages ]]

-- Is the Age at `index` (Ages) open to the player: its level and every milestone met?
function Progression.requirementsMet(state: State, index: number): boolean
	local age = Ages.get(index)
	if age == nil then
		return false
	end
	if Progression.level(state) < age.level then
		return false
	end
	for _, milestone in age.milestones do
		if not Ages.met(milestone, state.found) then
			return false
		end
	end
	return true
end

--[[
	Enters every next Age whose requirements are met, one after another (each gives its reward,
	which may open the next). Returns the Ages reached, in order, and those of them reached for
	the first time (the others were reached before, then set lower by /age: no reward again, and
	nothing to announce).
]]
function Progression.advance(state: State, session: Session): ({ Age }, { Age })
	local reached: { Age } = {}
	local first: { Age } = {}
	while state.age < Ages.count and Progression.requirementsMet(state, state.age + 1) do
		state.age += 1
		local age = Ages.get(state.age) :: Age
		table.insert(reached, age)
		if not Progression.found(state, "age", age.id) then
			table.insert(first, age)
		end
		Progression.discover(state, session, "age", age.id)
	end
	return reached, first
end

-- Sets the Age (1..Ages.count; /age set). Ages passed on the way up count as discovered.
function Progression.setAge(state: State, index: number)
	state.age = math.clamp(math.floor(index), 1, Ages.count)
	local keys = state.found.age
	if keys == nil then
		keys = {}
		state.found.age = keys
	end
	for i = 2, state.age do
		keys[(Ages.get(i) :: Age).id] = true
	end
end

--[[ Recipes ]]

--[[
	May the player make `item` (a crafting or smelting result)? Its Age reached and the node that
	names it unlocked. A nil state allows everything (no player, gating off, creative).
]]
function Progression.allows(state: State?, item: number): boolean
	if state == nil then
		return true
	end
	local age = ageOfItem[item]
	if age and age > state.age then
		return false
	end
	local skill = skillOfItem[item]
	return skill == nil or state.skills[skill.id] == true
end

-- What `item` needs (whoever asks): the Age that opens it (nil: the Stone Age's) and the node
-- that also unlocks it (nil: none). For JEI's lock marks.
function Progression.requirement(item: number): (Age?, Skill?)
	local index = ageOfItem[item]
	return if index then Ages.get(index) else nil, skillOfItem[item]
end

--[[
	Why the player may not make `item` ("Requires the Iron Age", "Requires Demolition", "Requires
	the Industrial Age and Demolition"), or nil when they may.
]]
function Progression.lockText(state: State?, item: number): string?
	if Progression.allows(state, item) then
		return nil
	end
	local current = if state then state.age else 1
	local age, skill = Progression.requirement(item)
	local needsAge = age ~= nil and age.index > current
	local needsSkill = skill ~= nil and not (state and state.skills[skill.id])
	if needsAge and needsSkill then
		return `Requires the {(age :: Age).name} and {(skill :: Skill).name}`
	elseif needsAge then
		return `Requires the {(age :: Age).name}`
	elseif needsSkill then
		return `Requires {(skill :: Skill).name}`
	end
	return nil
end

--[[ Skills ]]

-- Is node `id` unlocked?
function Progression.perk(state: State?, id: string): boolean
	return state ~= nil and state.skills[id] == true
end

--[[
	May the player unlock node `id` now? false and why ("unknown", "unlocked", "age", "requires",
	"points") with a text for the player.
]]
function Progression.canUnlock(state: State, id: string): (boolean, string?, string?)
	local skill = Skills.byId(id)
	if skill == nil then
		return false, "unknown", "No such skill"
	elseif state.skills[id] then
		return false, "unlocked", `{skill.name} is already unlocked`
	elseif state.age < skill.age then
		return false, "age", `{skill.name} needs the {(Ages.get(skill.age) :: Age).name}`
	end
	for _, required in skill.requires do
		if not state.skills[required] then
			local before = Skills.byId(required) :: Skill
			return false, "requires", `{skill.name} needs {before.name} first`
		end
	end
	if Progression.skillPoints(state) < skill.cost then
		return false, "points", `{skill.name} costs {skill.cost} skill point{if skill.cost == 1 then "" else "s"}`
	end
	return true, nil, nil
end

-- Unlocks node `id` if `canUnlock` allows it; returns the same answers.
function Progression.unlock(state: State, id: string): (boolean, string?, string?)
	local ok, reason, text = Progression.canUnlock(state, id)
	if ok then
		state.skills[id] = true
	end
	return ok, reason, text
end

-- The unlocked nodes' perks of `kind`, in turn.
local function perks(state: State?, kind: string): { Skills.Perk }
	local found: { Skills.Perk } = {}
	if state then
		for id in state.skills do
			local skill = Skills.byId(id)
			if skill and skill.perk.kind == kind then
				table.insert(found, skill.perk)
			end
		end
	end
	return found
end

-- Mining speed factor with `tool` in hand (an item id, nil = bare hands): the mining perks whose
-- tiers it is of, multiplied (Shared/Mining's `factor`).
function Progression.miningFactor(state: State?, tool: number?): number
	local def = if tool then Items.get(tool) else nil
	if def == nil or def.tool == nil then
		return 1
	end
	local factor = 1
	for _, perk in perks(state, "mining") do
		local tiers = perk.tiers
		local fits = tiers == nil
		if tiers then
			for _, tier in tiers do
				if string.sub(def.name, 1, #tier) == tier then
					fits = true
					break
				end
			end
		end
		if fits then
			factor *= perk.factor or 1
		end
	end
	return factor
end

-- The chance a tool's wear point is skipped: 1 - the product of (1 - each wear perk's chance).
function Progression.wearChance(state: State?): number
	local kept = 1
	for _, perk in perks(state, "wear") do
		kept *= 1 - (perk.chance or 0)
	end
	return 1 - kept
end

-- Of `amount` wear points, those that land (each skipped with `wearChance`; `random` gives
-- 0..1, math.random's way).
function Progression.wear(state: State?, amount: number, random: () -> number): number
	local chance = Progression.wearChance(state)
	if chance <= 0 or amount <= 0 then
		return amount
	end
	local landed = 0
	for _ = 1, amount do
		if random() >= chance then
			landed += 1
		end
	end
	return landed
end

-- How fast thirst drains (the thirst perks' factors multiplied; ToughAsNails/Thirst's `rate`).
function Progression.thirstRate(state: State?): number
	local rate = 1
	for _, perk in perks(state, "thirst") do
		rate *= perk.factor or 1
	end
	return rate
end

-- Steps of warmth and of cooling the insulation perks give (added to the armor's).
function Progression.insulation(state: State?): number
	local steps = 0
	for _, perk in perks(state, "insulation") do
		steps += perk.steps or 0
	end
	return steps
end

-- How many times as fast a campfire boils water (ToughAsNails/Boiling's `speed`).
function Progression.boilSpeed(state: State?): number
	local speed = 1
	for _, perk in perks(state, "boiling") do
		speed *= perk.speed or 1
	end
	return speed
end

--[[ Death ]]

-- Dying: `loss` (0..1, Config.Progression.DeathLoss) of the progress into the current level goes.
function Progression.die(state: State, loss: number)
	if not (loss > 0) then
		return
	end
	local level = Progression.level(state)
	local start = Knowledge.total(level)
	local into = state.points - start
	Progression.setPoints(state, start + math.floor(into * (1 - math.min(loss, 1))))
end

--[[ The saved record ]]

local function sortedKeys(set: { [string]: boolean }): { string }
	local keys = {}
	for key in set do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

--[[
	The saved form: { v = 1, points = n, age = "iron", skills = { ids }, found = { [category] =
	{ keys } } }, ids and names rather than numbers, so lists can change around it.
]]
function Progression.toRecord(state: State): { [string]: any }
	local found: { [string]: { string } } = {}
	for category, keys in state.found do
		found[category] = sortedKeys(keys)
	end
	return {
		v = Progression.RECORD_VERSION,
		points = state.points,
		age = (Ages.get(state.age) :: Age).id,
		skills = sortedKeys(state.skills),
		found = found,
	}
end

local function isKey(value: unknown): boolean
	return type(value) == "string" and value ~= "" and #value <= Progression.MAX_KEY
end

--[[
	The state a record holds (see the header: anything odd reads safely), and whether it may be
	saved over: yes for nothing saved (nil) or a record of this version, no for anything else (a
	record of another version, a newer server's during an update, read as a fresh start but kept
	for the build that understands it: the caller then saves nothing this session).
]]
function Progression.fromRecord(record: unknown): (State, boolean)
	local state = Progression.new()
	if record == nil then
		return state, true
	end
	if type(record) ~= "table" then
		return state, false
	end
	local data = record :: { [any]: any }
	if data.v ~= Progression.RECORD_VERSION then
		return state, false
	end
	if type(data.points) == "number" then
		Progression.setPoints(state, data.points)
	end
	local age = if type(data.age) == "string" then Ages.byId(data.age) else nil
	if age then
		state.age = age.index
	end
	if type(data.skills) == "table" then
		for _, id in data.skills do
			if type(id) == "string" and Skills.byId(id) then
				state.skills[id] = true
			end
		end
	end
	if type(data.found) == "table" then
		for category, keys in data.found do
			if isKey(category) and type(keys) == "table" then
				local set: { [string]: boolean } = {}
				local n = 0
				for _, key in keys do
					if isKey(key) and n < Progression.MAX_FOUND then
						set[key] = true
						n += 1
					end
				end
				state.found[category] = set
			end
		end
	end
	return state, true
end

--[[ The client's view ]]

-- What the Progress message carries of `state`.
function Progression.status(state: State): Status
	local counts: { [string]: number } = {}
	for _, category in Knowledge.CATEGORIES do
		counts[category] = Progression.count(state, category)
	end
	local milestones: { boolean } = {}
	for i, milestone in Ages.MILESTONES do
		milestones[i] = Ages.met(milestone, state.found)
	end
	return {
		points = state.points,
		age = state.age,
		skills = table.clone(state.skills),
		counts = counts,
		milestones = milestones,
	}
end

-- A state for the client's rules (allows, perks, skill points) from a status: no discoveries.
function Progression.fromStatus(status: Status): State
	return { points = status.points, age = status.age, skills = table.clone(status.skills), found = {} }
end

return Progression

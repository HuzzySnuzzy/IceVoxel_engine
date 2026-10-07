--!strict
--[[
	Knowledge: this game's experience, pure (no Roblox APIs, so the tests run it). Points and
	levels follow Minecraft's experience curve exactly (Player.getXpNeededForNextLevel), so the
	green bar over the hotbar fills as Minecraft's does:

	    points from level L to L + 1    2L + 7    (L 0..14:   7, 9, 11, ... 35)
	                                    5L - 38   (L 15..29:  37, 42, ... 107)
	                                    9L - 158  (L 30 and up: 112, 121, ...)

	so level 5 takes 55 points in all, 15 takes 315, 25 takes 910, 30 takes 1395 and 40 takes
	2920 (`total`). Unlike Minecraft's experience it is never spent (enchanting has no place
	here): levels give skill points (Progression/Skills, one a level) and open the Ages
	(Progression/Ages), and dying keeps it (Config.Progression.DeathLoss).

	Where it comes from (the numbers are this module's tables; Shared/Progression applies them):

	  Discoveries  the first time a player does something, once ever (saved): DISCOVERY points by
	               category: mining a block kind 5, crafting an item kind 8, smelting a result 10
	               (taken out of a furnace or a machine), visiting a biome 20, killing a mob kind
	               10, and reaching an Age its own reward (Ages `reward`: 50 to 200). A category
	               nobody listed gives DEFAULT_DISCOVERY.
	  Repeats      small amounts, again and again: mining an ore (ORES: Minecraft's ore
	               experience, coal 1 .. diamond 5), chopping a log (LOG), each item smelted
	               (SMELTED: Minecraft's furnace experience, an iron ingot 0.7, glass 0.1), each
	               craft (CRAFT), each mob killed (MOBS). They wear off when repeated
	               (`repeatPoints`): every repeat of the same thing (the same ore, the same
	               result) within FATIGUE_SECONDS gives FATIGUE_FACTOR (0.75) of the last, the
	               fatigue easing by one repeat every FATIGUE_SECONDS (60 s), so a farm of one
	               thing dries up fast while a varied day keeps paying; and all repeats together
	               give at most Config.Progression.RepeatBudget points a minute (a token bucket
	               that refills smoothly). Fractions add up (`Session.fraction`): a stack of ten
	               glass taken out at once is one repeat worth ten (a point); taken out one at a
	               time each glass is a repeat of its own and wears off (about 0.38 for the ten).
	  Never        blocks a player placed (the server's edit list knows them, as Behaviours/Leaves
	               tells placed leaves): breaking them gives neither a discovery nor a repeat, so
	               placing and breaking an ore block, or a cobblestone generator, earns nothing.
	               Creative and spectator players earn nothing (they make anything from nothing).

	Perks (Progression/Skills: Forager, Prospector, Scholar...) multiply what a SOURCE gives.
]]

local Knowledge = {}

-- Levels never go past this (the points past it are kept off: `MAX_POINTS`).
Knowledge.MAX_LEVEL = 1000

-- What knowledge comes from (perks name these; "all" in a perk means every one).
Knowledge.SOURCES = { "discovery", "ore", "mine", "smelt", "craft", "mob", "other" }

-- Discovery categories, in the order the protocol counts them (append only).
Knowledge.CATEGORIES = { "mine", "craft", "smelt", "biome", "mob", "age" }

-- Points for a first discovery, by category ("age" uses each Age's own reward).
Knowledge.DISCOVERY = table.freeze({
	mine = 5,
	craft = 8,
	smelt = 10,
	biome = 20,
	mob = 10,
}) :: { [string]: number }
Knowledge.DEFAULT_DISCOVERY = 5

-- Points for mining an ore again (Minecraft's ore experience: coal 0-2, diamond and emerald 3-7;
-- iron and gold give theirs in the furnace there, a little here too).
Knowledge.ORES = table.freeze({
	CoalOre = 1,
	IronOre = 2,
	OsmiumOre = 2,
	GoldOre = 3,
	DiamondOre = 5,
	EmeraldOre = 5,
}) :: { [string]: number }

-- Points for chopping a log (blocks whose name ends in "Log").
Knowledge.LOG = 0.25

-- Points per item smelted (Minecraft's furnace recipe experience), by result; others SMELT_DEFAULT.
Knowledge.SMELTED = table.freeze({
	IronIngot = 0.7,
	GoldIngot = 1,
	OsmiumIngot = 0.7,
	Diamond = 1,
	Emerald = 1,
	Coal = 0.1,
	Charcoal = 0.15,
	Glass = 0.1,
	Stone = 0.1,
	SmoothStone = 0.1,
	-- (The mobs' meat: Minecraft's cooked food gives 0.35.)
	CookedBeef = 0.35,
	CookedMutton = 0.35,
	CookedPorkchop = 0.35,
	CookedChicken = 0.35,
}) :: { [string]: number }
Knowledge.SMELT_DEFAULT = 0.1

-- Points per craft (a result taken; a shift click's every round).
Knowledge.CRAFT = 0.1

-- Points per mob a player killed (Shared/Entities/MobList names; server Mobs/Mobs' `died` event
-- calls Players/Progression.killed): Minecraft's experience drops, animals 2 (the mean of their
-- 1-3), monsters 5, and a creeper one more for walking up to something that explodes. A mob
-- nobody listed gives MOB_DEFAULT.
Knowledge.MOBS = table.freeze({
	Sheep = 2,
	Cow = 2,
	Pig = 2,
	Chicken = 2,
	Zombie = 5,
	Skeleton = 5,
	Spider = 5,
	Creeper = 6,
}) :: { [string]: number }
Knowledge.MOB_DEFAULT = 3

-- A repeat of the same thing gives this share of the last one; one repeat of fatigue wears off
-- every FATIGUE_SECONDS.
Knowledge.FATIGUE_FACTOR = 0.75
Knowledge.FATIGUE_SECONDS = 60

-- Points needed from level `level` to the next (Minecraft's getXpNeededForNextLevel).
function Knowledge.needed(level: number): number
	if level >= 30 then
		return 9 * level - 158
	elseif level >= 15 then
		return 5 * level - 38
	end
	return 2 * level + 7
end

-- Total points at the start of each level, 0..MAX_LEVEL (TOTALS[level + 1]).
local TOTALS: { number } = { 0 }
for level = 1, Knowledge.MAX_LEVEL do
	TOTALS[level + 1] = TOTALS[level] + Knowledge.needed(level - 1)
end

-- The most points anyone has (the start of MAX_LEVEL).
Knowledge.MAX_POINTS = TOTALS[Knowledge.MAX_LEVEL + 1]

-- Total points at the start of `level` (0..MAX_LEVEL; clamped).
function Knowledge.total(level: number): number
	return TOTALS[math.clamp(math.floor(level), 0, Knowledge.MAX_LEVEL) + 1]
end

-- The level `points` reach (binary search over the totals).
function Knowledge.levelOf(points: number): number
	if not (points > 0) then
		return 0
	end
	local low, high = 0, Knowledge.MAX_LEVEL
	while low < high do
		local middle = (low + high + 1) // 2
		if TOTALS[middle + 1] <= points then
			low = middle
		else
			high = middle - 1
		end
	end
	return low
end

--[[
	The level `points` reach, the points into that level and the points the level needs (the bar's
	fill is into / needed: Minecraft's experienceProgress).
]]
function Knowledge.progress(points: number): (number, number, number)
	local level = Knowledge.levelOf(points)
	if level >= Knowledge.MAX_LEVEL then
		return level, 0, Knowledge.needed(level)
	end
	return level, math.max(points, 0) - TOTALS[level + 1], Knowledge.needed(level)
end

-- Points for a first discovery in `category` (not "age": Ages' own rewards).
function Knowledge.discovery(category: string): number
	return Knowledge.DISCOVERY[category] or Knowledge.DEFAULT_DISCOVERY
end

-- Points a block's breaking gives each time (ores and logs; 0 for the rest) and their source.
function Knowledge.minePoints(blockName: string): (number, string)
	local ore = Knowledge.ORES[blockName]
	if ore then
		return ore, "ore"
	elseif string.sub(blockName, -3) == "Log" then
		return Knowledge.LOG, "mine"
	end
	return 0, "mine"
end

-- Points one item of `itemName` smelted gives.
function Knowledge.smeltPoints(itemName: string): number
	return Knowledge.SMELTED[itemName] or Knowledge.SMELT_DEFAULT
end

-- Points a mob of kind `mobName` killed gives.
function Knowledge.mobPoints(mobName: string): number
	return Knowledge.MOBS[mobName] or Knowledge.MOB_DEFAULT
end

--[[ Repeats: fatigue and the budget (one Session per player per server visit, never saved) ]]

export type Fatigue = { value: number, at: number }

export type Session = {
	-- Per repeated thing ("ore:IronOre", "smelt:Glass"): how many recent repeats, as of `at`.
	fatigue: { [string]: Fatigue },
	-- Repeat points left in the bucket, as of `budgetAt` (seconds; nil: full).
	budget: number?,
	budgetAt: number,
	-- Knowledge earned but not yet a whole point.
	fraction: number,
}

function Knowledge.newSession(): Session
	return { fatigue = {}, budget = nil, budgetAt = 0, fraction = 0 }
end

--[[
	Points a repeat of `key` worth `base` gives at time `now` (seconds), with `budget` points a
	minute at most for all repeats together (Config.Progression.RepeatBudget): base times
	FATIGUE_FACTOR ^ the key's fatigue, then at most what is left in the bucket. Counts the
	repeat (fatigue + 1) and takes the points from the bucket. May be a fraction.
]]
function Knowledge.repeatPoints(session: Session, key: string, base: number, now: number, budget: number): number
	if not (base > 0) then
		return 0
	end
	local fatigue = session.fatigue[key]
	if fatigue == nil then
		fatigue = { value = 0, at = now }
		session.fatigue[key] = fatigue
	end
	fatigue.value = math.max(0, fatigue.value - math.max(now - fatigue.at, 0) / Knowledge.FATIGUE_SECONDS)
	fatigue.at = now
	local points = base * Knowledge.FATIGUE_FACTOR ^ fatigue.value
	fatigue.value += 1

	local saved = session.budget
	local left: number = if saved == nil
		then budget
		else math.min(budget, saved + math.max(now - session.budgetAt, 0) * budget / 60)
	session.budgetAt = now
	points = math.min(points, left)
	session.budget = left - points
	return points
end

--[[
	Adds `amount` (a fraction or more) to the session's carry and returns the whole points it makes
	now (the rest stays for next time).
]]
function Knowledge.carry(session: Session, amount: number): number
	if not (amount > 0) then
		return 0
	end
	local total = session.fraction + amount
	local whole = math.floor(total + 1e-9)
	session.fraction = math.max(total - whole, 0)
	return whole
end

return Knowledge

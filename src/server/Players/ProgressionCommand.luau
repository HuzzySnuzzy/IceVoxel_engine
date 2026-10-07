--!strict
--[[
	The /knowledge and /age chat commands, for testing progression, without the Roblox parts (those
	are in Players/Progression), so the tests can run them.

	    /knowledge add <player> <amount> [points | levels]   (aliases /xp, /experience)
	    /knowledge set <player> <amount> [points | levels]
	    /knowledge query <player> [points | levels]
	    /age set <player> <age>
	    /age query <player>

	Minecraft's /xp, on knowledge (Shared/Progression/Knowledge): `points` (the default) are the
	total points, `levels` whole levels (setting levels sets the points to that level's start,
	adding them adds the points those levels take from the current level, so the progress into it
	stays). A negative amount takes away (never below 0). `<age>` is an Age's id, name or number
	("iron", "Iron Age", "Iron", 2; Progression/Ages). `<player>` is as /gamemode reads it
	(GameModeCommand.findPlayers: a name or display name or the start of one, @s, @a).

	Who may: changing needs `mayUse` (Config.Gameplay.Admins, the game's owner and Studio, the rule
	for /time); queries are harmless, so anyone may ask. After a change the glue checks the Ages
	again (Progression.advance), so knowledge set high with the milestones met enters the next
	Ages, and an Age set lower holds until the next knowledge the player gets.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Progression = require(Shared.Progression)

local GameModeCommand = require(script.Parent.GameModeCommand)

local Ages = Progression.Ages
local Knowledge = Progression.Knowledge

type Candidate = GameModeCommand.Candidate

export type Context = {
	source: Candidate,
	players: { Candidate },
	-- May change knowledge and Ages.
	mayUse: boolean,
	-- A player's progression (nil: not loaded yet).
	stateOf: (key: any) -> Progression.State?,
}

export type Result = {
	-- Players whose progression changed (resend, save, check the Ages).
	changed: { any },
	-- Messages for the player who typed the command.
	feedback: { string },
}

local ProgressionCommand = {}

ProgressionCommand.KNOWLEDGE_ALIASES = { "/knowledge", "/xp", "/experience" }
ProgressionCommand.AGE_ALIASES = { "/age" }
ProgressionCommand.KNOWLEDGE_USAGE =
	"Usage: /knowledge <add | set> <player> <amount> [points | levels], /knowledge query <player> [points | levels]"
ProgressionCommand.AGE_USAGE = "Usage: /age set <player> <age>, /age query <player>"
ProgressionCommand.DENIED = "You can't change knowledge or Ages here"
ProgressionCommand.NOT_LOADED = "That player's progress hasn't loaded yet"

local function words(text: string): { string }
	local list = {}
	for word in string.gmatch(text, "%S+") do
		table.insert(list, word)
	end
	return list
end

local function firstWord(text: string): string?
	local first = string.match(text, "^%s*(%S+)")
	return if first then string.lower(first) else nil
end

-- Is `text` a /knowledge or /age command (the alias, then nothing or a space)?
function ProgressionCommand.matches(text: string): boolean
	local first = firstWord(text)
	return first ~= nil
		and (
			table.find(ProgressionCommand.KNOWLEDGE_ALIASES, first) ~= nil
			or table.find(ProgressionCommand.AGE_ALIASES, first) ~= nil
		)
end

-- The Age `text` names (id, name, name without " Age", or its number), or nil.
function ProgressionCommand.parseAge(text: string): Progression.Age?
	local lower = string.lower(text)
	local number = tonumber(text)
	if number then
		return Ages.get(number)
	end
	for _, age in Ages.list do
		local name = string.lower(age.name)
		if lower == age.id or lower == name or lower .. " age" == name then
			return age
		end
	end
	return nil
end

local function plural(n: number, word: string): string
	return `{n} {word}{if n == 1 then "" else "s"}`
end

local function describe(state: Progression.State): string
	return `{plural(Progression.level(state), "level")} ({plural(state.points, "point")}), the {(
		Ages.get(state.age) :: Progression.Age
	).name}`
end

--[[
	Runs a chat message as the commands. nil when the message is neither (ordinary chat); otherwise
	whose progression changed (the states are changed in place) and what to say.
]]
function ProgressionCommand.run(text: string, context: Context): Result?
	local first = firstWord(text)
	if first == nil or not ProgressionCommand.matches(text) then
		return nil
	end
	local isAge = table.find(ProgressionCommand.AGE_ALIASES, first) ~= nil
	local usage = if isAge then ProgressionCommand.AGE_USAGE else ProgressionCommand.KNOWLEDGE_USAGE
	local result: Result = { changed = {}, feedback = {} }
	local function say(message: string): Result
		table.insert(result.feedback, message)
		return result
	end

	local list = words(text)
	local action = if list[2] then string.lower(list[2]) else nil
	if action == nil or list[3] == nil then
		return say(usage)
	end
	local query = action == "query"
	if not query and not context.mayUse then
		return say(ProgressionCommand.DENIED)
	end
	local targets, problem = GameModeCommand.findPlayers(list[3], context.source, context.players)
	if targets == nil then
		return say(problem or GameModeCommand.NO_PLAYER)
	end

	if isAge then
		if query then
			if #list > 3 then
				return say(usage)
			end
			for _, target in targets do
				local state = context.stateOf(target.key)
				say(
					if state
						then `{target.displayName} is in the {(Ages.get(state.age) :: Progression.Age).name}`
						else ProgressionCommand.NOT_LOADED
				)
			end
			return result
		elseif action ~= "set" or list[4] == nil then
			return say(usage)
		end
		local age = ProgressionCommand.parseAge(table.concat(list, " ", 4))
		if age == nil then
			local names = {}
			for _, known in Ages.list do
				table.insert(names, known.id)
			end
			return say(`Unknown Age '{table.concat(list, " ", 4)}'. Use {table.concat(names, ", ")}`)
		end
		for _, target in targets do
			local state = context.stateOf(target.key)
			if state == nil then
				say(ProgressionCommand.NOT_LOADED)
			else
				Progression.setAge(state, age.index)
				table.insert(result.changed, target.key)
				say(`Set {target.displayName}'s Age to the {age.name}`)
			end
		end
		return result
	end

	-- /knowledge
	local unitWord = if query then list[4] else list[5]
	local unit = if unitWord then string.lower(unitWord) else "points"
	if unit == "level" then
		unit = "levels"
	elseif unit == "point" then
		unit = "points"
	end
	if unit ~= "points" and unit ~= "levels" then
		return say(usage)
	end
	if query then
		if #list > 4 then
			return say(usage)
		end
		for _, target in targets do
			local state = context.stateOf(target.key)
			if state == nil then
				say(ProgressionCommand.NOT_LOADED)
			elseif unit == "levels" then
				say(`{target.displayName} has {plural(Progression.level(state), "knowledge level")}`)
			else
				say(`{target.displayName} has {plural(state.points, "knowledge point")}`)
			end
		end
		return result
	end
	if (action ~= "add" and action ~= "set") or list[4] == nil or #list > 5 then
		return say(usage)
	end
	local amount = tonumber(list[4])
	if amount == nil or amount ~= amount or math.abs(amount) == math.huge or amount ~= math.floor(amount) then
		return say(`'{list[4]}' is no whole number`)
	end
	for _, target in targets do
		local state = context.stateOf(target.key)
		if state == nil then
			say(ProgressionCommand.NOT_LOADED)
			continue
		end
		if action == "set" then
			if unit == "levels" then
				Progression.setPoints(state, Knowledge.total(math.max(amount, 0)))
			else
				Progression.setPoints(state, amount)
			end
		elseif unit == "levels" then
			-- (The points those levels take from here: the progress into the level stays.)
			local level, into = Knowledge.progress(state.points)
			local goal = math.clamp(level + amount, 0, Knowledge.MAX_LEVEL)
			Progression.setPoints(state, Knowledge.total(goal) + math.min(into, Knowledge.needed(goal) - 1))
		else
			Progression.addPoints(state, amount)
		end
		table.insert(result.changed, target.key)
		say(`{target.displayName} now has {describe(state)}`)
	end
	return result
end

return ProgressionCommand

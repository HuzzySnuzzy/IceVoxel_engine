--!strict
--[[
	The /time and /gamerule chat commands, without the Roblox parts (those are in
	Players/TimeCommands), so the tests can run them.

	    /time set <day | noon | night | midnight | time>     day 1000, noon 6000, night 13000,
	                                                          midnight 18000
	    /time add <time>
	    /time query <daytime | gametime | day>
	    /gamerule doDaylightCycle [true | false]

	A time is a number of ticks with an optional unit, as in Minecraft: "d" days (24000 ticks), "s"
	seconds (20 ticks), "t" ticks: 1d, 0.5d, 30s, 600 (Shared/DayCycle.parseDuration). Setting the
	time replaces the day count too, as Minecraft 1.20 does (/time set day starts day 0 again).

	Who may: changing the time or a game rule needs `mayUse`, which the glue gives the operators'
	permission (Players/Operators: operators, among them Config.Gameplay.Admins, the game's owner
	and Studio sessions; everyone in a world created with Allow Commands). Queries are harmless,
	so anyone may ask.

	The feedback uses Minecraft's wording ("Set the time to 1000", "The time is 1000", "Gamerule
	doDaylightCycle is now set to: false").
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local DayCycle = require(Shared.DayCycle)

local GameModeCommand = require(script.Parent.GameModeCommand)

export type Context = {
	-- May change the time and game rules.
	mayUse: boolean,
	-- The day time now (ticks, counting past 24000), ticks since the server started, and the
	-- doDaylightCycle rule.
	dayTime: number,
	gameTime: number,
	cycle: boolean,
}

export type Result = {
	-- The new day time, when the command sets it.
	dayTime: number?,
	-- The new doDaylightCycle value, when the command changes it.
	cycle: boolean?,
	-- Messages for the player who typed the command.
	feedback: { string },
}

local TimeCommand = {}

TimeCommand.TIME_ALIASES = { "/time" }
TimeCommand.GAMERULE_ALIASES = { "/gamerule" }
TimeCommand.USAGE = "Usage: /time set <day | noon | night | midnight | ticks>, /time add <ticks>, "
	.. "/time query <daytime | gametime | day> (ticks may end in d, s or t: 1d, 30s)"
TimeCommand.SET_USAGE = "Usage: /time set <day | noon | night | midnight | ticks> (e.g. 6000, 0.5d, 30s)"
TimeCommand.ADD_USAGE = "Usage: /time add <ticks> (e.g. 1000, 1d, 30s)"
TimeCommand.QUERY_USAGE = "Usage: /time query <daytime | gametime | day>"
TimeCommand.GAMERULE_USAGE = "Usage: /gamerule doDaylightCycle [true | false]"
TimeCommand.DENIED = "You can't change the time here"
TimeCommand.DENIED_RULES = "You can't change game rules here"

-- The game rules /gamerule knows (Minecraft's names).
TimeCommand.DAYLIGHT_CYCLE = "doDaylightCycle"

--[[
	May user `userId` change the time and game rules? Admins (`admins`, Config.Gameplay.Admins),
	the game's owner and Studio sessions.
]]
function TimeCommand.mayUse(userId: number, admins: { number }, isOwner: boolean, isStudio: boolean): boolean
	return GameModeCommand.isAdmin(userId, admins, isOwner, isStudio)
end

local function firstWord(text: string): string?
	local first = string.match(text, "^%s*(%S+)")
	return if first then string.lower(first) else nil
end

-- Is `text` a /time or /gamerule command (the alias, then nothing or a space)?
function TimeCommand.matches(text: string): boolean
	local first = firstWord(text)
	if first == nil then
		return false
	end
	return table.find(TimeCommand.TIME_ALIASES, first) ~= nil or table.find(TimeCommand.GAMERULE_ALIASES, first) ~= nil
end

local function words(text: string): { string }
	local list = {}
	for word in string.gmatch(text, "%S+") do
		table.insert(list, word)
	end
	return list
end

local function runTime(list: { string }, context: Context, result: Result, say: (string) -> Result): Result
	local action = if list[2] then string.lower(list[2]) else nil
	if action == "query" then
		local what = if list[3] then string.lower(list[3]) else nil
		if what == nil or #list > 3 then
			return say(TimeCommand.QUERY_USAGE)
		elseif what == "daytime" then
			return say(`The time is {DayCycle.timeInDay(context.dayTime)}`)
		elseif what == "gametime" then
			return say(`The time is {math.floor(context.gameTime)}`)
		elseif what == "day" then
			return say(`The time is {DayCycle.day(context.dayTime)}`)
		end
		return say(TimeCommand.QUERY_USAGE)
	elseif action == "set" or action == "add" then
		local usage = if action == "set" then TimeCommand.SET_USAGE else TimeCommand.ADD_USAGE
		if list[3] == nil or #list > 3 then
			return say(usage)
		elseif not context.mayUse then
			return say(TimeCommand.DENIED)
		end
		-- Only /time set knows the named times.
		local ticks, problem
		if action == "set" then
			ticks, problem = DayCycle.parseTime(list[3])
		else
			ticks, problem = DayCycle.parseDuration(list[3])
		end
		if ticks == nil then
			return say(`{problem or "Invalid time"}. {usage}`)
		end
		if action == "set" then
			result.dayTime = ticks
			return say(`Set the time to {ticks}`)
		end
		local dayTime = math.floor(context.dayTime) + ticks
		result.dayTime = dayTime
		-- Minecraft answers /time add with the new time of day.
		return say(`Set the time to {DayCycle.timeInDay(dayTime)}`)
	end
	return say(TimeCommand.USAGE)
end

local function runGameRule(list: { string }, context: Context, result: Result, say: (string) -> Result): Result
	local rule = list[2]
	if rule == nil or #list > 3 then
		return say(TimeCommand.GAMERULE_USAGE)
	elseif string.lower(rule) ~= string.lower(TimeCommand.DAYLIGHT_CYCLE) then
		return say(`Unknown game rule '{rule}'. This game has: {TimeCommand.DAYLIGHT_CYCLE}`)
	end
	local name = TimeCommand.DAYLIGHT_CYCLE
	local value = list[3]
	if value == nil then
		return say(`Gamerule {name} is currently set to: {context.cycle}`)
	end
	local lower = string.lower(value)
	if lower ~= "true" and lower ~= "false" then
		return say(`Invalid boolean, expected 'true' or 'false' but found '{value}'`)
	elseif not context.mayUse then
		return say(TimeCommand.DENIED_RULES)
	end
	local on = lower == "true"
	result.cycle = on
	return say(`Gamerule {name} is now set to: {on}`)
end

--[[
	Runs a chat message as /time or /gamerule. nil when the message is neither (ordinary chat);
	otherwise what to change and say.
]]
function TimeCommand.run(text: string, context: Context): Result?
	local first = firstWord(text)
	if first == nil or not TimeCommand.matches(text) then
		return nil
	end
	local result: Result = { feedback = {} }
	local function say(message: string): Result
		table.insert(result.feedback, message)
		return result
	end
	local list = words(text)
	if table.find(TimeCommand.GAMERULE_ALIASES, first) then
		return runGameRule(list, context, result, say)
	end
	return runTime(list, context, result, say)
end

return TimeCommand

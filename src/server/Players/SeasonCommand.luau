--!strict
--[[
	The /season chat command, without the Roblox parts (those are in Players/SeasonCommands), so the
	tests can run it. In Players/TimeCommand's style and wording:

	    /season query                          "It is Winter, day 3 of 8 (6 days left), year 1"
	    /season set <season> [day]             "Set the season to Winter, day 1"

	A season is autumn (or fall), winter, spring or summer, in any case; the day is 1-based, a whole
	number within the season's length (default 1). Setting the season keeps the time of day, the day
	count (the "Day N" line), the blood moons and the year: server World/SeasonClock.setSeason moves
	only the calendar's offset (Shared/Seasons/Calendar.offsetFor). While /gamerule doSeasonCycle is
	false (Players/TimeCommand) the calendar stands on the day set, and the query says so.

	Who may: setting the season needs `mayUse`, which the glue gives the operators' permission
	(Players/Operators, as /time). The query is harmless, so anyone may ask. In a world without
	seasons (Config.Seasons.Enabled false, the debug worlds) it only says so.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Calendar = require(Shared.Seasons.Calendar)

export type Context = {
	-- May set the season.
	mayUse: boolean,
	-- The world has seasons (World/SeasonClock.enabled).
	enabled: boolean,
	-- The day time now (ticks, counting past 24000) and the calendar (World/SeasonClock.state).
	dayTime: number,
	state: Calendar.State,
}

export type Result = {
	-- The season to set (Calendar.AUTUMN .. SUMMER) and its day (1-based), when the command sets it.
	season: number?,
	day: number?,
	-- Messages for the player who typed the command.
	feedback: { string },
}

local SeasonCommand = {}

SeasonCommand.ALIASES = { "/season" }
SeasonCommand.USAGE = "Usage: /season query, /season set <autumn | winter | spring | summer> [day]"
SeasonCommand.SET_USAGE = "Usage: /season set <autumn | winter | spring | summer> [day] (day 1 by default)"
SeasonCommand.QUERY_USAGE = "Usage: /season query"
SeasonCommand.DENIED = "You can't change the season here"
SeasonCommand.NO_SEASONS = "This world has no seasons"
-- After the query while /gamerule doSeasonCycle is false.
SeasonCommand.HELD = "the seasons stand still (doSeasonCycle is false)"

-- The words a season goes by (lower case).
SeasonCommand.NAMES = table.freeze({
	autumn = Calendar.AUTUMN,
	fall = Calendar.AUTUMN,
	winter = Calendar.WINTER,
	spring = Calendar.SPRING,
	summer = Calendar.SUMMER,
} :: { [string]: number })

local function firstWord(text: string): string?
	local first = string.match(text, "^%s*(%S+)")
	return if first then string.lower(first) else nil
end

-- Is `text` a /season command (the alias, then nothing or a space)?
function SeasonCommand.matches(text: string): boolean
	local first = firstWord(text)
	return first ~= nil and table.find(SeasonCommand.ALIASES, first) ~= nil
end

local function words(text: string): { string }
	local list = {}
	for word in string.gmatch(text, "%S+") do
		table.insert(list, word)
	end
	return list
end

-- The season `word` names (any case), nil when none.
function SeasonCommand.parseSeason(word: string): number?
	return SeasonCommand.NAMES[string.lower(word)]
end

--[[
	The day `word` gives in a season `length` days long: a whole number 1..length, or nil and why
	not (Minecraft's IntegerArgumentType wording).
]]
function SeasonCommand.parseDay(word: string, length: number): (number?, string?)
	local value = tonumber(word)
	if value == nil or not string.match(word, "^[%+%-]?%d+$") then
		return nil, `Expected a whole day, found '{word}'`
	elseif value < 1 then
		return nil, `The day must not be less than 1, found {value}`
	elseif value > length then
		return nil, `The day must not be more than {length}, found {value}`
	end
	return value, nil
end

--[[
	The query's answer for `position` (Calendar.Position): "It is Winter, day 3 of 8 (6 days left),
	year 1" ("the last day" on it), and the held calendar's note when `held`.
]]
function SeasonCommand.describe(position: Calendar.Position, held: boolean?): string
	local left = if position.daysLeft <= 1 then "the last day" else `{position.daysLeft} days left`
	local text = `It is {Calendar.NAMES[position.season]}, day {position.day + 1} of {position.days} ({left}), `
		.. `year {position.year + 1}`
	if held then
		text ..= `; {SeasonCommand.HELD}`
	end
	return text
end

-- The set's answer: "Set the season to Winter, day 1".
function SeasonCommand.setText(season: number, day: number): string
	return `Set the season to {Calendar.NAMES[season]}, day {day}`
end

--[[
	Runs a chat message as /season. nil when the message is not one (ordinary chat); otherwise
	what to change and say.
]]
function SeasonCommand.run(text: string, context: Context): Result?
	if not SeasonCommand.matches(text) then
		return nil
	end
	local result: Result = { feedback = {} }
	local function say(message: string): Result
		table.insert(result.feedback, message)
		return result
	end
	local list = words(text)
	local action = if list[2] then string.lower(list[2]) else nil
	if action == "query" then
		if #list > 2 then
			return say(SeasonCommand.QUERY_USAGE)
		elseif not context.enabled then
			return say(SeasonCommand.NO_SEASONS)
		end
		local state = context.state
		return say(SeasonCommand.describe(Calendar.position(context.dayTime, state), state.lock ~= nil))
	elseif action == "set" then
		if list[3] == nil or #list > 4 then
			return say(SeasonCommand.SET_USAGE)
		elseif not context.enabled then
			return say(SeasonCommand.NO_SEASONS)
		elseif not context.mayUse then
			return say(SeasonCommand.DENIED)
		end
		local season = SeasonCommand.parseSeason(list[3])
		if season == nil then
			return say(`Unknown season '{list[3]}'. {SeasonCommand.SET_USAGE}`)
		end
		local day = 1
		if list[4] then
			local parsed, problem = SeasonCommand.parseDay(list[4], context.state.lengths[season])
			if parsed == nil then
				return say(`{problem or "Invalid day"}. {SeasonCommand.SET_USAGE}`)
			end
			day = parsed
		end
		result.season, result.day = season, day
		return say(SeasonCommand.setText(season, day))
	end
	return say(SeasonCommand.USAGE)
end

return SeasonCommand

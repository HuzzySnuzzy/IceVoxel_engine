--!strict
--[[
	The /weather chat command, without the Roblox parts (those are in Players/WeatherCommands), so
	the tests can run it. Minecraft 1.20.1's WeatherCommand:

	    /weather clear [duration]      "Set the weather to clear"
	    /weather rain [duration]       "Set the weather to rain"
	    /weather thunder [duration]    "Set the weather to rain & thunder"
	    /weather query                 "Weather state is: rain" (Bedrock's query: the weather where
	                                   the player stands: clear, rain, snow or thunder)

	A duration is a TimeArgument of at least 1 tick (Shared/DayCycle.parseDuration: a number with
	an optional unit, "d" days of 24000 ticks, "s" seconds of 20, "t" ticks: 300s, 0.5d, 6000).
	Without one, Minecraft's random durations (ServerLevel: clear 12000-180000 ticks, rain
	12000-24000, thunder 3600-15600; `DURATIONS`). The override applies to the whole world and
	blends in over a few seconds (Shared/Weather); with doWeatherCycle off it never runs out.

	Who may: setting the weather needs `mayUse`, which the glue gives the operators' permission
	(Players/Operators, as /time). The query is harmless, so anyone may ask. In a world without
	weather (Config.Weather.Enabled false, the debug worlds) it only says so.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local DayCycle = require(Shared.DayCycle)
local Weather = require(Shared.Weather)

export type Context = {
	-- May set the weather.
	mayUse: boolean,
	-- The world has weather.
	enabled: boolean,
	-- The weather where the player stands ("clear", "rain", "snow" or "thunder"), for the query.
	here: string,
	-- Rolls in [0, 1), for the random durations.
	random: () -> number,
}

export type Result = {
	-- The override to set (Weather.CLEAR, RAIN or THUNDER) and for how many ticks.
	kind: string?,
	ticks: number?,
	-- Messages for the player who typed the command.
	feedback: { string },
}

local WeatherCommand = {}

WeatherCommand.ALIASES = { "/weather" }
WeatherCommand.USAGE = "Usage: /weather <clear | rain | thunder> [duration], /weather query "
	.. "(durations may end in d, s or t: 1d, 300s)"
WeatherCommand.DENIED = "You can't change the weather here"
WeatherCommand.NO_WEATHER = "This world has no weather"

-- Minecraft's random durations in ticks (ServerLevel.RAIN_DELAY, RAIN_DURATION, THUNDER_DURATION).
WeatherCommand.DURATIONS = table.freeze({
	[Weather.CLEAR] = table.freeze({ 12000, 180000 }),
	[Weather.RAIN] = table.freeze({ 12000, 24000 }),
	[Weather.THUNDER] = table.freeze({ 3600, 15600 }),
} :: { [string]: { number } })

-- Minecraft's answers.
WeatherCommand.ANSWERS = table.freeze({
	[Weather.CLEAR] = "Set the weather to clear",
	[Weather.RAIN] = "Set the weather to rain",
	[Weather.THUNDER] = "Set the weather to rain & thunder",
} :: { [string]: string })

local function firstWord(text: string): string?
	local first = string.match(text, "^%s*(%S+)")
	return if first then string.lower(first) else nil
end

-- Is `text` a /weather command (the alias, then nothing or a space)?
function WeatherCommand.matches(text: string): boolean
	local first = firstWord(text)
	return first ~= nil and table.find(WeatherCommand.ALIASES, first) ~= nil
end

-- A random duration for `kind` (Minecraft's UniformInt: min..max, both included).
function WeatherCommand.randomTicks(kind: string, random: () -> number): number
	local range = WeatherCommand.DURATIONS[kind]
	local low, high = range[1], range[2]
	return low + math.min(high - low, math.floor(random() * (high - low + 1)))
end

--[[
	Runs a chat message as /weather. nil when it is something else (ordinary chat); otherwise
	what to set and say.
]]
function WeatherCommand.run(text: string, context: Context): Result?
	if not WeatherCommand.matches(text) then
		return nil
	end
	local result: Result = { feedback = {} }
	local function say(message: string): Result
		table.insert(result.feedback, message)
		return result
	end
	local words = {}
	for word in string.gmatch(text, "%S+") do
		table.insert(words, word)
	end
	local action = if words[2] then string.lower(words[2]) else nil
	if action == "query" then
		if #words > 2 then
			return say(WeatherCommand.USAGE)
		end
		return say(`Weather state is: {if context.enabled then context.here else Weather.CLEAR}`)
	elseif action == nil or WeatherCommand.ANSWERS[action] == nil or #words > 3 then
		return say(WeatherCommand.USAGE)
	elseif not context.mayUse then
		return say(WeatherCommand.DENIED)
	elseif not context.enabled then
		return say(WeatherCommand.NO_WEATHER)
	end
	local ticks
	if words[3] then
		local parsed, problem = DayCycle.parseDuration(words[3])
		if parsed == nil then
			return say(`{problem or "Invalid time"}. {WeatherCommand.USAGE}`)
		elseif parsed < 1 then
			return say(`The tick count must not be less than 1, found {parsed}`)
		end
		ticks = parsed
	else
		ticks = WeatherCommand.randomTicks(action, context.random)
	end
	result.kind = action
	result.ticks = ticks
	return say(WeatherCommand.ANSWERS[action])
end

return WeatherCommand

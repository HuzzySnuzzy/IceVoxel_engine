--!strict
--[[
	The /effect chat command (Minecraft 1.20.1's EffectCommands), without the Roblox parts (those
	are in Players/Effects), so the tests can run it.

	    /effect give <player> <effect> [seconds | infinite] [amplifier] [hideParticles]
	    /effect clear [player] [effect]

	`player` is a name or display name, the start of one, or @s (yourself), @p (the nearest
	player: yourself, who typed it) or @a (everyone): GameModeCommand.findPlayers. `effect` is
	an /effect id with or without "minecraft:" ("speed", "minecraft:jump_boost", this game's
	"oil_coated", Tough As Nails' "thirst") or a name ("JumpBoost"): Shared/Effects.find.
	`seconds` 1..1000000 (default 30; an instant effect's default is a single tick, and its
	seconds count as ticks, as Minecraft's), `amplifier` 0..255 (default 0: level I),
	`hideParticles` true or false (there are no particles; accepted for Minecraft's sake).

	Who may: both need `mayUse`, which the glue gives Config.Gameplay.Admins, the game's owner
	and Studio sessions (the /time rule, GameModeCommand.isAdmin).

	The work is done through the context's `give` and `clear` (Players/Effects: give says whether
	the effect took, MobEffectInstance.update's answer; clear how many effects went), and the
	feedback uses Minecraft's wording ("Applied effect Speed to Steve", "Removed every effect from
	3 targets", "Unable to apply this effect (target is either immune to effects, or has
	something stronger)").
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Effects = require(Shared.Effects)

local GameModeCommand = require(script.Parent.GameModeCommand)

export type Candidate = GameModeCommand.Candidate

export type Context = {
	-- Who typed the command, and everyone in the game (the source too).
	source: Candidate,
	players: { Candidate },
	-- May give and clear effects.
	mayUse: boolean,
	-- Gives effect `effect` for `ticks` at `amplifier` to the player `key`: whether it took.
	give: (key: any, effect: number, ticks: number, amplifier: number) -> boolean,
	-- Clears effect `effect` (nil: every effect) from player `key`: how many went.
	clear: (key: any, effect: number?) -> number,
}

export type Result = {
	-- Messages for the player who typed the command.
	feedback: { string },
}

local EffectCommand = {}

EffectCommand.ALIASES = { "/effect" }
EffectCommand.USAGE = "Usage: /effect give <player> <effect> [seconds | infinite] [amplifier] [hideParticles], "
	.. "/effect clear [player] [effect]"
EffectCommand.GIVE_USAGE = "Usage: /effect give <player> <effect> [seconds | infinite] [amplifier] [hideParticles]"
EffectCommand.CLEAR_USAGE = "Usage: /effect clear [player] [effect]"
EffectCommand.DENIED = "You can't change effects here"
EffectCommand.GIVE_FAILED =
	"Unable to apply this effect (target is either immune to effects, or has something stronger)"
EffectCommand.CLEAR_FAILED = "Target has no effects to remove"
EffectCommand.CLEAR_SPECIFIC_FAILED = "Target doesn't have the requested effect"
-- /effect's bounds and default (EffectCommands: seconds 1..1000000, default 30; amplifier 0..255).
EffectCommand.MAX_SECONDS = 1000000
EffectCommand.DEFAULT_SECONDS = 30

-- Is `text` an /effect command (the alias, then nothing or a space)?
function EffectCommand.matches(text: string): boolean
	local first = string.match(text, "^%s*(%S+)")
	return first ~= nil and table.find(EffectCommand.ALIASES, string.lower(first)) ~= nil
end

-- A whole number within min..max, or nil and Minecraft's complaint.
local function integer(text: string, min: number, max: number): (number?, string?)
	local value = tonumber(text)
	if value == nil or value ~= math.floor(value) or string.find(text, "[^%d%-]") then
		return nil, `Expected integer, found '{text}'`
	elseif value < min then
		return nil, `Integer must not be less than {min}, found {value}`
	elseif value > max then
		return nil, `Integer must not be more than {max}, found {value}`
	end
	return value, nil
end

-- The players `query` names (@p is the source: the nearest player to whoever typed it).
local function targets(query: string, context: Context): ({ Candidate }?, string?)
	if string.lower(query) == "@p" then
		return { context.source }, nil
	end
	return GameModeCommand.findPlayers(query, context.source, context.players)
end

-- "Steve", or "3 targets".
local function whom(list: { Candidate }, count: number): string
	if #list == 1 then
		return list[1].displayName
	end
	return `{count} targets`
end

local function give(words: { string }, context: Context, say: (string) -> Result): Result
	if words[3] == nil or words[4] == nil or #words > 7 then
		return say(EffectCommand.GIVE_USAGE)
	end
	local list, problem = targets(words[3], context)
	if list == nil then
		return say(problem or GameModeCommand.NO_PLAYER)
	end
	local effect = Effects.find(words[4])
	local def = if effect then Effects.get(effect) else nil
	if effect == nil or def == nil then
		return say(`Unknown effect: {words[4]}`)
	end
	local ticks = if def.instant then 1 else EffectCommand.DEFAULT_SECONDS * Effects.TICKS_PER_SECOND
	if words[5] then
		if string.lower(words[5]) == "infinite" then
			ticks = Effects.INFINITE
		else
			local seconds, complaint = integer(words[5], 1, EffectCommand.MAX_SECONDS)
			if seconds == nil then
				return say(complaint or EffectCommand.GIVE_USAGE)
			end
			-- (An instant effect's seconds are ticks: Minecraft's EffectCommands.)
			ticks = if def.instant then seconds else seconds * Effects.TICKS_PER_SECOND
		end
	end
	local amplifier = 0
	if words[6] then
		local value, complaint = integer(words[6], 0, Effects.MAX_AMPLIFIER)
		if value == nil then
			return say(complaint or EffectCommand.GIVE_USAGE)
		end
		amplifier = value
	end
	if words[7] then
		local flag = string.lower(words[7])
		if flag ~= "true" and flag ~= "false" then
			return say(`Invalid boolean, expected 'true' or 'false' but found '{words[7]}'`)
		end
	end
	if not context.mayUse then
		return say(EffectCommand.DENIED)
	end
	local count = 0
	for _, target in list do
		if context.give(target.key, effect, ticks, amplifier) then
			count += 1
		end
	end
	if count == 0 then
		return say(EffectCommand.GIVE_FAILED)
	end
	return say(`Applied effect {def.displayName} to {whom(list, count)}`)
end

local function clear(words: { string }, context: Context, say: (string) -> Result): Result
	if #words > 4 then
		return say(EffectCommand.CLEAR_USAGE)
	end
	local list: { Candidate } = { context.source }
	if words[3] then
		local found, problem = targets(words[3], context)
		if found == nil then
			return say(problem or GameModeCommand.NO_PLAYER)
		end
		list = found
	end
	local effect: number? = nil
	if words[4] then
		effect = Effects.find(words[4])
		if effect == nil then
			return say(`Unknown effect: {words[4]}`)
		end
	end
	if not context.mayUse then
		return say(EffectCommand.DENIED)
	end
	local count = 0
	for _, target in list do
		if context.clear(target.key, effect) > 0 then
			count += 1
		end
	end
	if effect then
		if count == 0 then
			return say(EffectCommand.CLEAR_SPECIFIC_FAILED)
		end
		return say(`Removed effect {Effects.levelName(effect, 0)} from {whom(list, count)}`)
	end
	if count == 0 then
		return say(EffectCommand.CLEAR_FAILED)
	end
	return say(`Removed every effect from {whom(list, count)}`)
end

--[[
	Runs a chat message as /effect. nil when the message is not the command (ordinary chat);
	otherwise what was said (the work went through the context).
]]
function EffectCommand.run(text: string, context: Context): Result?
	if not EffectCommand.matches(text) then
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
	if action == "give" then
		return give(words, context, say)
	elseif action == "clear" then
		return clear(words, context, say)
	end
	return say(EffectCommand.USAGE)
end

return EffectCommand

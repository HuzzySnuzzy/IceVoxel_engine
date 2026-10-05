--!strict
--[[
	The /gamemode chat command (alias /gm) and the client's game mode switching (the F3 + F4
	switcher, F3 + N: Protocol SetGameMode), without the Roblox parts (those are in
	Players/GameModes), so the tests can run them.

	    /gamemode <survival | creative | adventure | spectator> [player]

	Modes may be shortened as Shared/GameMode.parse reads them (s / c / a / sp, 0..3). `player` is
	a name or display name, or the start of one (any case), or Minecraft's selectors @s (yourself)
	and @a (everyone). Who may use it:
	  * your own game mode: Config.Gameplay.GameModeCommand (true = everyone, false = nobody, or a
	    list of user ids), plus admins (`mayChangeOwn`, which the server also tells each client as
	    the GameMode.PERMISSION_ATTRIBUTE);
	  * other players': Config.Gameplay.Admins;
	  * the game's owner and Studio sessions may always do both.

	The feedback uses Minecraft's wording ("Set own game mode to Creative Mode", "Set Steve's game
	mode to Survival Mode"; the other player reads "Your game mode has been updated to ...").
	`switchOwn` is the switcher's way in: the same permission and answer, and nothing at all when
	the mode is already the one asked for (Minecraft's switcher sends nothing then).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)

-- A player the command can name.
export type Candidate = { key: any, name: string, displayName: string }

export type Context = {
	-- Who typed the command.
	source: Candidate,
	-- Everyone in the game (the source too).
	players: { Candidate },
	-- May change their own / other players' game modes (`allowed` / `isAdmin`).
	mayUse: boolean,
	mayTarget: boolean,
	-- A player's current game mode.
	modeOf: (key: any) -> string,
}

export type Result = {
	-- Game modes to set.
	changes: { { key: any, mode: string } },
	-- Messages for the player who typed the command.
	feedback: { string },
	-- Messages for the other players whose game mode changed.
	notices: { { key: any, text: string } },
}

local GameModeCommand = {}

GameModeCommand.ALIASES = { "/gamemode", "/gm" }
GameModeCommand.USAGE = "Usage: /gamemode <survival | creative | adventure | spectator> [player]"
GameModeCommand.DENIED = "You can't change game modes here"
GameModeCommand.DENIED_OTHERS = "You can't change other players' game modes"
GameModeCommand.NO_PLAYER = "No player was found"

-- "Creative" -> "Creative Mode" (Minecraft's gameMode.* names).
GameModeCommand.modeName = GameMode.displayName

--[[
	May user `userId` change their own game mode? `rule` is Config.Gameplay.GameModeCommand: true
	(everyone), false (nobody) or a list of user ids. The owner and Studio always may.
]]
function GameModeCommand.allowed(
	userId: number,
	rule: boolean | { number },
	isOwner: boolean,
	isStudio: boolean
): boolean
	if isOwner or isStudio then
		return true
	end
	if type(rule) == "table" then
		return table.find(rule, userId) ~= nil
	end
	return rule == true
end

-- May user `userId` change other players' game modes (Config.Gameplay.Admins)?
function GameModeCommand.isAdmin(userId: number, admins: { number }, isOwner: boolean, isStudio: boolean): boolean
	return isOwner or isStudio or table.find(admins, userId) ~= nil
end

--[[
	May user `userId` change their own game mode, by the command or the switcher? `allowed`, or an
	admin (who may even where the command is off for everyone). Minecraft's permission level 2.
]]
function GameModeCommand.mayChangeOwn(
	userId: number,
	rule: boolean | { number },
	admins: { number },
	isOwner: boolean,
	isStudio: boolean
): boolean
	return GameModeCommand.allowed(userId, rule, isOwner, isStudio)
		or GameModeCommand.isAdmin(userId, admins, isOwner, isStudio)
end

-- Is `text` a /gamemode command (the alias, then nothing or a space)?
function GameModeCommand.matches(text: string): boolean
	local first = string.match(text, "^%s*(%S+)")
	if first == nil then
		return false
	end
	return table.find(GameModeCommand.ALIASES, string.lower(first)) ~= nil
end

--[[
	The players `query` names: @s, @a, an exact name or display name, else the one whose name or
	display name starts with it (any case). Returns the players, or nil and why not.
]]
function GameModeCommand.findPlayers(
	query: string,
	source: Candidate,
	players: { Candidate }
): ({ Candidate }?, string?)
	local lower = string.lower(query)
	if lower == "@s" then
		return { source }, nil
	elseif lower == "@a" then
		return table.clone(players), nil
	end
	-- Most specific first: an exact name, an exact display name, then prefixes.
	for pass = 1, 4 do
		local prefix = pass > 2
		local found = {}
		for _, candidate in players do
			local value = string.lower(if pass % 2 == 1 then candidate.name else candidate.displayName)
			if value == lower or (prefix and string.sub(value, 1, #lower) == lower) then
				table.insert(found, candidate)
			end
		end
		if #found == 1 then
			return found, nil
		elseif #found > 1 then
			local names = {}
			for _, candidate in found do
				table.insert(names, candidate.name)
			end
			table.sort(names)
			return nil, `'{query}' matches more than one player: {table.concat(names, ", ")}`
		end
	end
	return nil, GameModeCommand.NO_PLAYER
end

--[[
	Runs a chat message as the command. nil when the message is not the command (ordinary chat);
	otherwise what to change and say.
]]
function GameModeCommand.run(text: string, context: Context): Result?
	if not GameModeCommand.matches(text) then
		return nil
	end
	local result: Result = { changes = {}, feedback = {}, notices = {} }
	local function say(message: string): Result
		table.insert(result.feedback, message)
		return result
	end

	if not context.mayUse and not context.mayTarget then
		return say(GameModeCommand.DENIED)
	end
	local words = {}
	for word in string.gmatch(text, "%S+") do
		table.insert(words, word)
	end
	if words[2] == nil or #words > 3 then
		return say(GameModeCommand.USAGE)
	end
	local mode = GameMode.parse(words[2])
	if mode == nil then
		return say(
			`Unknown game mode '{words[2]}'. Use survival (s, 0), creative (c, 1), adventure (a, 2) or spectator (sp, 3)`
		)
	end

	local source = context.source
	local targets: { Candidate } = { source }
	if words[3] then
		local found, problem = GameModeCommand.findPlayers(words[3], source, context.players)
		if found == nil then
			return say(problem or GameModeCommand.NO_PLAYER)
		end
		targets = found
	end
	local onlySelf = #targets == 1 and targets[1].key == source.key
	-- Admins may change their own game mode too, even where the command is off for everyone.
	if onlySelf and not (context.mayUse or context.mayTarget) then
		return say(GameModeCommand.DENIED)
	elseif not onlySelf and not context.mayTarget then
		return say(GameModeCommand.DENIED_OTHERS)
	end

	local name = GameModeCommand.modeName(mode)
	for _, target in targets do
		if context.modeOf(target.key) ~= mode then
			table.insert(result.changes, { key = target.key, mode = mode })
			if target.key == source.key then
				say(`Set own game mode to {name}`)
			else
				say(`Set {target.displayName}'s game mode to {name}`)
				table.insert(result.notices, { key = target.key, text = `Your game mode has been updated to {name}` })
			end
		end
	end
	if #result.changes == 0 then
		if onlySelf then
			say(`Your game mode is already {name}`)
		elseif #targets == 1 then
			say(`{targets[1].displayName}'s game mode is already {name}`)
		else
			say(`Everyone is already in {name}`)
		end
	end
	return result
end

--[[
	The previous mode after a player's mode is set from `old` (the attribute as it was: nil before
	the first mode) to `new`: `old` when the mode really changes, else nil (the previous mode stays
	as it is). Minecraft's client (MultiPlayerGameMode.setLocalMode).
]]
function GameModeCommand.previousAfter(old: unknown, new: string): string?
	if old ~= new and GameMode.isValid(old) then
		return old :: string
	end
	return nil
end

--[[
	A player asks to switch their own mode to `mode` (Protocol SetGameMode: the switcher, F3 + N).
	The command's permission and answer; no change and no answer when they are in `mode` already.
	`context.players` is not used.
]]
function GameModeCommand.switchOwn(mode: string, context: Context): Result
	local result: Result = { changes = {}, feedback = {}, notices = {} }
	if not context.mayUse and not context.mayTarget then
		table.insert(result.feedback, GameModeCommand.DENIED)
	elseif context.modeOf(context.source.key) ~= mode then
		table.insert(result.changes, { key = context.source.key, mode = mode })
		table.insert(result.feedback, `Set own game mode to {GameModeCommand.modeName(mode)}`)
	end
	return result
end

return GameModeCommand

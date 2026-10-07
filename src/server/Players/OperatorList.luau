--!strict
--[[
	Minecraft's server operators (the ops list, /op and /deop) without the Roblox parts (those are
	in Players/Operators), so the tests can run them. Players are known by user id.

	  Operators  a player on the op list (`ops`, kept by user id for the server's lifetime: one
	             who leaves and comes back is an operator again, as Minecraft's ops.json), or a
	             permanent one: Config.Gameplay.Admins, the game's owner and everyone in a Studio
	             session (the glue says who, `setPermanent`); those are never taken off.
	  Automatic  only while `autoOperator` is on (`setAutoOperator`: Players/Operators turns it on
	             with the title screen and Config.MainMenu.AutoOperator, and off for good once the
	             world exists, so nobody becomes an operator just by being here after that):
	    First    a player who joins while no operator is in the server becomes one: the first
	             player of a server, and the first after it emptied. Everyone is told "Name is the
	             server operator" (in Studio too, where the first player is one anyway).
	    Last     while players are here, one of them is an operator: when the last operator here
	             leaves, the player here longest becomes one ("Name is now the server operator"),
	             and /deop refuses to take the last one away. So the world can always be created.
	             Without it (the menu off, or the world made) only the permanent operators and
	             those they /op are operators, and the last one here may /deop themselves.
	  Commands   `/op <player>` and `/deop <player>` (a name or display name, its start, @s or @a,
	             as /gamemode's: GameModeCommand.findPlayers), for operators only, with Minecraft's
	             answers ("Made Steve a server operator", "Nothing changed. The player already is
	             an operator", "Made Steve no longer a server operator", "Nothing changed. The
	             player is not an operator"); the player is told, and the other operators read
	             Minecraft's admin line ("[Alex: Made Steve a server operator]").
	  Permitted  what the operators' commands ask (/time, /gamemode for others, /effect, /summon,
	             /kill, /knowledge, /age, structure blocks): an operator, or anyone once the world
	             allows commands (the Create World screen's Allow Commands, `setAllowCommands`).
]]

local GameModeCommand = require(script.Parent.GameModeCommand)

-- A player here: GameModeCommand's candidate with the user id as its key.
export type Member = GameModeCommand.Candidate

export type List = {
	-- The op list (user ids).
	ops: { [number]: boolean },
	-- Always operators (user ids).
	permanent: { [number]: boolean },
	-- The players here, in the order they joined (the longest here first).
	present: { Member },
	-- Everyone may use the operators' commands.
	allowCommands: boolean,
	-- Players become operators by being here (the first to join, the hand-over: see the header).
	autoOperator: boolean,
}

export type Result = {
	-- For the player who typed the command.
	feedback: { string },
	-- For one player each (user id).
	notices: { { userId: number, text: string } },
	-- For everyone here.
	broadcast: { string },
	-- Players whose operator status (or permission) changed (user ids).
	changed: { number },
}

local OperatorList = {}

OperatorList.OP_ALIASES = { "/op" }
OperatorList.DEOP_ALIASES = { "/deop" }
OperatorList.OP_USAGE = "Usage: /op <player>"
OperatorList.DEOP_USAGE = "Usage: /deop <player>"

function OperatorList.new(): List
	return { ops = {}, permanent = {}, present = {}, allowCommands = false, autoOperator = true }
end

local function newResult(): Result
	return { feedback = {}, notices = {}, broadcast = {}, changed = {} }
end

local function userIdOf(member: Member): number
	return member.key :: number
end

function OperatorList.isOperator(list: List, userId: number): boolean
	return list.permanent[userId] == true or list.ops[userId] == true
end

-- Is `userId` always an operator (Config.Gameplay.Admins, the game's owner, Studio)?
function OperatorList.isPermanent(list: List, userId: number): boolean
	return list.permanent[userId] == true
end

-- May `userId` use the operators' commands (an operator, or anyone with commands allowed)?
function OperatorList.permitted(list: List, userId: number): boolean
	return list.allowCommands or OperatorList.isOperator(list, userId)
end

-- The operators here, longest here first.
function OperatorList.presentOperators(list: List): { Member }
	local found = {}
	for _, member in list.present do
		if OperatorList.isOperator(list, userIdOf(member)) then
			table.insert(found, member)
		end
	end
	return found
end

local function indexOf(list: List, userId: number): number?
	for i, member in list.present do
		if userIdOf(member) == userId then
			return i
		end
	end
	return nil
end

-- With players here and no operator among them, the one here longest becomes one (while operators
-- are automatic).
local function keepAnOperator(list: List, result: Result)
	local first = list.present[1]
	if not list.autoOperator or first == nil or #OperatorList.presentOperators(list) > 0 then
		return
	end
	list.ops[userIdOf(first)] = true
	table.insert(result.changed, userIdOf(first))
	table.insert(result.broadcast, `{first.displayName} is now the server operator`)
end

--[[
	`member` (key: their user id) joined; `permanent`: always an operator (as far as known yet).
	With no operator here before (and operators automatic), they become one and everyone is told.
]]
function OperatorList.join(list: List, member: Member, permanent: boolean): Result
	local result = newResult()
	local userId = userIdOf(member)
	local alone = list.autoOperator and #OperatorList.presentOperators(list) == 0
	local existing = indexOf(list, userId)
	if existing then
		table.remove(list.present, existing)
	end
	table.insert(list.present, member)
	if permanent then
		list.permanent[userId] = true
	end
	if alone then
		list.ops[userId] = true
		table.insert(result.broadcast, `{member.displayName} is the server operator`)
	end
	table.insert(result.changed, userId)
	return result
end

-- `userId` left: the last operator here leaving makes the one here longest one.
function OperatorList.leave(list: List, userId: number): Result
	local result = newResult()
	local index = indexOf(list, userId)
	if index == nil then
		return result
	end
	table.remove(list.present, index)
	keepAnOperator(list, result)
	return result
end

-- `userId` is (or is no longer) always an operator (the game's owner, found out late).
function OperatorList.setPermanent(list: List, userId: number, permanent: boolean): Result
	local result = newResult()
	if (list.permanent[userId] == true) ~= permanent then
		if permanent then
			list.permanent[userId] = true
		else
			list.permanent[userId] = nil
		end
		table.insert(result.changed, userId)
		keepAnOperator(list, result)
	end
	return result
end

--[[
	Players become operators by being here (`auto`: the first to join, the hand-over) or only as
	permanent ones and by /op. Turning it on with no operator here makes the one here longest one.
]]
function OperatorList.setAutoOperator(list: List, auto: boolean): Result
	local result = newResult()
	list.autoOperator = auto
	keepAnOperator(list, result)
	return result
end

-- Commands for everyone (the Create World screen's Allow Commands) or for operators only.
function OperatorList.setAllowCommands(list: List, allow: boolean): Result
	local result = newResult()
	if list.allowCommands ~= allow then
		list.allowCommands = allow
		for _, member in list.present do
			table.insert(result.changed, userIdOf(member))
		end
	end
	return result
end

--[[ /op and /deop ]]

local function firstWord(text: string): string?
	local first = string.match(text, "^%s*(%S+)")
	return if first then string.lower(first) else nil
end

-- Is `text` /op or /deop (the alias, then nothing or a space)?
function OperatorList.matches(text: string): boolean
	local first = firstWord(text)
	if first == nil then
		return false
	end
	return table.find(OperatorList.OP_ALIASES, first) ~= nil or table.find(OperatorList.DEOP_ALIASES, first) ~= nil
end

-- The other operators here (not `except`) read Minecraft's admin line about a change.
local function tellOperators(list: List, result: Result, except: { number }, text: string)
	for _, member in OperatorList.presentOperators(list) do
		local userId = userIdOf(member)
		if not table.find(except, userId) then
			table.insert(result.notices, { userId = userId, text = text })
		end
	end
end

--[[
	Runs a chat message from `sourceId` as /op or /deop: nil when it is neither (ordinary chat),
	otherwise what changed and what to say. The list changes as it says.
]]
function OperatorList.run(list: List, text: string, sourceId: number): Result?
	if not OperatorList.matches(text) then
		return nil
	end
	local op = table.find(OperatorList.OP_ALIASES, firstWord(text) :: string) ~= nil
	local result = newResult()
	local function say(message: string): Result
		table.insert(result.feedback, message)
		return result
	end
	if not OperatorList.isOperator(list, sourceId) then
		return say(if op then "Only operators can use /op" else "Only operators can use /deop")
	end
	local words = {}
	for word in string.gmatch(text, "%S+") do
		table.insert(words, word)
	end
	if #words ~= 2 then
		return say(if op then OperatorList.OP_USAGE else OperatorList.DEOP_USAGE)
	end
	local index = indexOf(list, sourceId)
	if index == nil then
		return result
	end
	local source = list.present[index]
	local targets, problem = GameModeCommand.findPlayers(words[2], source, list.present)
	if targets == nil then
		return say(problem or GameModeCommand.NO_PLAYER)
	end
	-- (The source last: `/deop @a` takes the others first, then refuses the last operator.)
	table.sort(targets, function(a: Member, b: Member): boolean
		return a.key ~= sourceId and b.key == sourceId
	end)
	for _, target in targets do
		local userId = userIdOf(target)
		local name = target.displayName
		if op then
			if OperatorList.isOperator(list, userId) then
				say("Nothing changed. The player already is an operator")
			else
				list.ops[userId] = true
				table.insert(result.changed, userId)
				say(`Made {name} a server operator`)
				if userId ~= sourceId then
					table.insert(result.notices, { userId = userId, text = "You are now a server operator" })
				end
				tellOperators(
					list,
					result,
					{ sourceId, userId },
					`[{source.displayName}: Made {name} a server operator]`
				)
			end
		elseif not OperatorList.isOperator(list, userId) then
			say("Nothing changed. The player is not an operator")
		elseif list.permanent[userId] then
			say(`Nothing changed. {name} is always an operator here`)
		elseif list.autoOperator and #OperatorList.presentOperators(list) <= 1 then
			say(`Nothing changed. {name} is the only operator here: /op another player first`)
		else
			list.ops[userId] = nil
			table.insert(result.changed, userId)
			say(`Made {name} no longer a server operator`)
			if userId ~= sourceId then
				table.insert(result.notices, { userId = userId, text = "You are no longer a server operator" })
			end
			tellOperators(
				list,
				result,
				{ sourceId, userId },
				`[{source.displayName}: Made {name} no longer a server operator]`
			)
		end
	end
	return result
end

return OperatorList

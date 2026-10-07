--[[
	Server operators (Players/OperatorList, the rules Players/Operators plays out): the first player
	becomes the operator, one of the players here always is one (both only until the world exists,
	and never with the menu off), rejoining keeps it, permanent
	operators (Config.Gameplay.Admins, the owner, Studio), Allow Commands, and /op and /deop with
	Minecraft's answers; which commands the chat offers a player (Shared/WorldSettings.mayRun).
]]

return function(t, shared, require, server)
	local OperatorList = require(server.Players.OperatorList)
	local WorldSettings = require(shared.WorldSettings)

	local function member(id: number, name: string)
		return { key = id, name = name, displayName = name }
	end

	local function has(list: { string }, text: string): boolean
		return table.find(list, text) ~= nil
	end

	local function noticeTo(result, id: number): string?
		for _, notice in result.notices do
			if notice.userId == id then
				return notice.text
			end
		end
		return nil
	end

	t.test("operators: the first player to join is the operator, and everyone is told", function()
		local list = OperatorList.new()
		local first = OperatorList.join(list, member(1, "Steve"), false)
		t.ok(OperatorList.isOperator(list, 1), "the first player")
		t.ok(has(first.broadcast, "Steve is the server operator"), "announced")
		t.ok(table.find(first.changed, 1) ~= nil, "their attribute is set")
		local second = OperatorList.join(list, member(2, "Alex"), false)
		t.ok(not OperatorList.isOperator(list, 2), "the second is not")
		t.eq(#second.broadcast, 0, "nothing to announce")
		t.ok(OperatorList.permitted(list, 1) and not OperatorList.permitted(list, 2), "the commands' check")
		t.eq(OperatorList.presentOperators(list)[1].name, "Steve")
	end)

	t.test("operators: the last operator leaving hands over to the player here longest", function()
		local list = OperatorList.new()
		OperatorList.join(list, member(1, "Steve"), false)
		OperatorList.join(list, member(2, "Alex"), false)
		OperatorList.join(list, member(3, "Sam"), false)
		local result = OperatorList.leave(list, 1)
		t.ok(OperatorList.isOperator(list, 2), "Alex was here longest")
		t.ok(not OperatorList.isOperator(list, 3))
		t.ok(has(result.broadcast, "Alex is now the server operator"))
		-- Steve comes back: still on the op list (Minecraft's ops.json), no announcement.
		local back = OperatorList.join(list, member(1, "Steve"), false)
		t.ok(OperatorList.isOperator(list, 1), "rejoining keeps it")
		t.eq(#back.broadcast, 0)
		-- A non-operator leaving changes nothing.
		local left = OperatorList.leave(list, 3)
		t.eq(#left.changed, 0)
		t.eq(#left.broadcast, 0)
	end)

	t.test("operators: after the server empties, the next player to join is the operator", function()
		local list = OperatorList.new()
		OperatorList.join(list, member(1, "Steve"), false)
		OperatorList.leave(list, 1)
		t.eq(#list.present, 0)
		local result = OperatorList.join(list, member(2, "Alex"), false)
		t.ok(OperatorList.isOperator(list, 2), "the next to join")
		t.ok(has(result.broadcast, "Alex is the server operator"))
	end)

	t.test("operators: permanent ones (admins, the owner, Studio) and the owner found out late", function()
		local list = OperatorList.new()
		-- Studio: everyone is permanent; the first is still announced.
		local first = OperatorList.join(list, member(1, "Steve"), true)
		t.ok(has(first.broadcast, "Steve is the server operator"))
		local second = OperatorList.join(list, member(2, "Alex"), true)
		t.ok(OperatorList.isOperator(list, 2), "every Studio player")
		t.eq(#second.broadcast, 0, "only the first is announced")
		-- A group game's owner, looked up after joining.
		local game = OperatorList.new()
		OperatorList.join(game, member(1, "Steve"), false)
		OperatorList.join(game, member(9, "Owner"), false)
		t.ok(not OperatorList.isOperator(game, 9))
		local found = OperatorList.setPermanent(game, 9, true)
		t.ok(OperatorList.isOperator(game, 9), "the owner")
		t.ok(table.find(found.changed, 9) ~= nil)
		t.eq(#OperatorList.setPermanent(game, 9, true).changed, 0, "already known: nothing changes")
	end)

	t.test("operators: Allow Commands lets everyone use the commands, not /op", function()
		local list = OperatorList.new()
		OperatorList.join(list, member(1, "Steve"), false)
		OperatorList.join(list, member(2, "Alex"), false)
		local result = OperatorList.setAllowCommands(list, true)
		t.eq(#result.changed, 2, "everyone's permission changed")
		t.ok(OperatorList.permitted(list, 2), "commands for everyone")
		t.ok(not OperatorList.isOperator(list, 2), "but no operator")
		local denied = OperatorList.run(list, "/op Alex", 2) :: any
		t.eq(denied.feedback[1], "Only operators can use /op")
	end)

	t.test("operators: /op and /deop, with Minecraft's answers", function()
		local list = OperatorList.new()
		OperatorList.join(list, member(1, "Steve"), false)
		OperatorList.join(list, member(2, "Alex"), false)
		OperatorList.join(list, member(3, "Sam"), false)
		t.eq(OperatorList.run(list, "hello there", 1), nil, "ordinary chat")
		t.ok(OperatorList.matches("/OP alex") and OperatorList.matches("/deop x"), "any case")
		t.ok(not OperatorList.matches("/operator"), "only the alias")

		local denied = OperatorList.run(list, "/op Sam", 2) :: any
		t.eq(denied.feedback[1], "Only operators can use /op", "not an operator")
		t.ok(not OperatorList.isOperator(list, 3))
		t.eq((OperatorList.run(list, "/deop Steve", 2) :: any).feedback[1], "Only operators can use /deop")

		local usage = OperatorList.run(list, "/op", 1) :: any
		t.eq(usage.feedback[1], OperatorList.OP_USAGE)
		local nobody = OperatorList.run(list, "/op Zed", 1) :: any
		t.eq(nobody.feedback[1], "No player was found")

		local made = OperatorList.run(list, "/op al", 1) :: any
		t.ok(OperatorList.isOperator(list, 2), "a name's start")
		t.eq(made.feedback[1], "Made Alex a server operator")
		t.eq(noticeTo(made, 2), "You are now a server operator")
		t.ok(table.find(made.changed, 2) ~= nil)
		local again = OperatorList.run(list, "/op Alex", 1) :: any
		t.eq(again.feedback[1], "Nothing changed. The player already is an operator")

		-- Sam is opped by Alex: Steve, the other operator, reads Minecraft's admin line.
		local third = OperatorList.run(list, "/op Sam", 2) :: any
		t.eq(noticeTo(third, 1), "[Alex: Made Sam a server operator]")

		local taken = OperatorList.run(list, "/deop Sam", 1) :: any
		t.eq(taken.feedback[1], "Made Sam no longer a server operator")
		t.eq(noticeTo(taken, 3), "You are no longer a server operator")
		t.eq(noticeTo(taken, 2), "[Steve: Made Sam no longer a server operator]")
		t.ok(not OperatorList.isOperator(list, 3))
		local notOne = OperatorList.run(list, "/deop Sam", 1) :: any
		t.eq(notOne.feedback[1], "Nothing changed. The player is not an operator")
	end)

	t.test("operators: /deop never takes the last operator here, nor a permanent one", function()
		local list = OperatorList.new()
		OperatorList.join(list, member(1, "Steve"), false)
		OperatorList.join(list, member(2, "Alex"), false)
		OperatorList.join(list, member(7, "Admin"), true)
		OperatorList.run(list, "/op Alex", 1)
		local permanent = OperatorList.run(list, "/deop Admin", 1) :: any
		t.eq(permanent.feedback[1], "Nothing changed. Admin is always an operator here")

		-- /deop @a: the others first (Alex), the admin stays, then Steve himself (an admin is left).
		local all = OperatorList.run(list, "/deop @a", 1) :: any
		t.ok(not OperatorList.isOperator(list, 2), "Alex")
		t.ok(not OperatorList.isOperator(list, 1), "Steve too: the admin is still an operator")
		t.ok(OperatorList.isOperator(list, 7))
		t.eq(all.feedback[#all.feedback], "Made Steve no longer a server operator", "the source last")

		local alone = OperatorList.new()
		OperatorList.join(alone, member(1, "Steve"), false)
		OperatorList.join(alone, member(2, "Alex"), false)
		local refused = OperatorList.run(alone, "/deop @s", 1) :: any
		t.eq(refused.feedback[1], "Nothing changed. Steve is the only operator here: /op another player first")
		t.ok(OperatorList.isOperator(alone, 1))
	end)

	t.test("operators: automatic only until the world exists (and not with the menu off)", function()
		-- The world made: nobody becomes an operator by being here, the first one stays one.
		local list = OperatorList.new()
		OperatorList.join(list, member(1, "Steve"), false)
		OperatorList.join(list, member(2, "Alex"), false)
		t.eq(#OperatorList.setAutoOperator(list, false).changed, 0, "the operator here stays")
		local left = OperatorList.leave(list, 1)
		t.ok(not OperatorList.isOperator(list, 2), "no hand-over once the world exists")
		t.eq(#left.broadcast, 0)
		OperatorList.leave(list, 2)
		local stranger = OperatorList.join(list, member(3, "Sam"), false)
		t.ok(not OperatorList.isOperator(list, 3), "an empty server's next player is no operator")
		t.eq(#stranger.broadcast, 0)
		local back = OperatorList.join(list, member(1, "Steve"), false)
		t.ok(OperatorList.isOperator(list, 1), "the first operator is still on the op list")
		t.eq(#back.broadcast, 0)
		-- The last operator here may /deop themselves then (no world left to create).
		local self = OperatorList.run(list, "/deop @s", 1) :: any
		t.eq(self.feedback[1], "Made Steve no longer a server operator")
		t.ok(not OperatorList.isOperator(list, 1))

		-- The menu off (or AutoOperator false): only permanent operators, and those they /op.
		local fixed = OperatorList.new()
		OperatorList.setAutoOperator(fixed, false)
		local first = OperatorList.join(fixed, member(1, "Steve"), false)
		t.ok(not OperatorList.isOperator(fixed, 1), "the first player is no operator")
		t.eq(#first.broadcast, 0)
		OperatorList.join(fixed, member(7, "Admin"), true)
		t.ok(OperatorList.isOperator(fixed, 7), "an admin is")
		OperatorList.run(fixed, "/op Steve", 7)
		t.ok(OperatorList.isOperator(fixed, 1), "opped by the admin")
		OperatorList.leave(fixed, 7)
		OperatorList.leave(fixed, 1)
		OperatorList.join(fixed, member(2, "Alex"), false)
		t.ok(not OperatorList.isOperator(fixed, 2))
		-- Turned on with nobody operator here: the one here longest becomes one.
		local on = OperatorList.setAutoOperator(fixed, true)
		t.ok(OperatorList.isOperator(fixed, 2))
		t.ok(has(on.broadcast, "Alex is now the server operator"))
	end)

	t.test("operators: the chat offers each player only the commands they may run", function()
		local function access(operator: boolean, allowCommands: boolean, gameMode: boolean): WorldSettings.Access
			return { operator = operator, allowCommands = allowCommands, gameMode = gameMode }
		end
		local op = access(true, false, true)
		local player = access(false, false, false)
		local cheats = access(false, true, false)
		local switcher = access(false, false, true)
		-- /op and /deop: operators only, Allow Commands or not (Minecraft's level 3).
		t.ok(WorldSettings.mayRun(WorldSettings.COMMAND_OPERATOR, op))
		t.ok(not WorldSettings.mayRun(WorldSettings.COMMAND_OPERATOR, cheats), "not with Allow Commands")
		t.ok(not WorldSettings.mayRun(WorldSettings.COMMAND_OPERATOR, player))
		-- /effect, /summon, /kill: Operators.permitted.
		t.ok(WorldSettings.mayRun(WorldSettings.COMMAND_PERMITTED, op))
		t.ok(WorldSettings.mayRun(WorldSettings.COMMAND_PERMITTED, cheats), "Allow Commands")
		t.ok(not WorldSettings.mayRun(WorldSettings.COMMAND_PERMITTED, player))
		-- /gamemode: the player's own game mode permission.
		t.ok(WorldSettings.mayRun(WorldSettings.COMMAND_GAMEMODE, switcher))
		t.ok(not WorldSettings.mayRun(WorldSettings.COMMAND_GAMEMODE, player))
		-- No mark (queries anyone may make: /time, /gamerule, /knowledge; Roblox's own): everyone.
		t.ok(WorldSettings.mayRun(nil, player))
		t.ok(WorldSettings.mayRun("something new", player), "an unknown mark hides nothing")
	end)
end

--[[
	Game modes (Shared/GameMode): Minecraft 1.20.1's four modes, their abilities, the player
	attributes; the game mode messages (Net/Protocol SetGameMode, SpectatorTeleport); /gamemode with
	adventure and spectator, the switcher's way in and the previous mode (Players/GameModeCommand).
	The spectator movement tests are in Movement.
]]

return function(t, shared, require, server)
	local GameMode = require(shared.GameMode)
	local Protocol = require(shared.Net.Protocol)
	local GameModeCommand = require(server.Players.GameModeCommand)

	local SURVIVAL, CREATIVE, ADVENTURE, SPECTATOR =
		GameMode.SURVIVAL, GameMode.CREATIVE, GameMode.ADVENTURE, GameMode.SPECTATOR

	-- A stand-in for a Player: only attributes.
	local function fakePlayer(attributes: { [string]: any }): any
		return {
			GetAttribute = function(_, name: string): any
				return attributes[name]
			end,
		}
	end

	t.test("game modes: names, Minecraft's ids and the switcher's order", function()
		t.eq(SURVIVAL, "Survival")
		t.eq(CREATIVE, "Creative")
		t.eq(ADVENTURE, "Adventure")
		t.eq(SPECTATOR, "Spectator")
		for id, mode in { [0] = SURVIVAL, [1] = CREATIVE, [2] = ADVENTURE, [3] = SPECTATOR } do
			t.eq(GameMode.id(mode), id, mode)
			t.eq(GameMode.fromId(id), mode, `id {id}`)
		end
		t.eq(GameMode.fromId(4), nil)
		t.eq(GameMode.fromId(-1), nil)
		t.eq(table.concat(GameMode.ORDER, " "), "Creative Survival Adventure Spectator")
		t.eq(#GameMode.ALL, 4)
		t.ok(GameMode.isValid(ADVENTURE) and not GameMode.isValid("adventure") and not GameMode.isValid(2))
		t.eq(GameMode.displayName(SPECTATOR), "Spectator Mode")
		t.eq(GameModeCommand.modeName(ADVENTURE), "Adventure Mode")
	end)

	t.test("game modes: parse names, letters and numbers in any case", function()
		local cases = {
			[SURVIVAL] = { "survival", "S", "0" },
			[CREATIVE] = { "Creative", "c", "1" },
			[ADVENTURE] = { "ADVENTURE", "a", "2" },
			[SPECTATOR] = { "spectator", "SP", "Sp", "3" },
		}
		for mode, words in cases do
			for _, word in words do
				t.eq(GameMode.parse(word), mode, word)
			end
		end
		for _, word in { "", "x", "4", "spec", "hardcore", "survival mode", "-1" } do
			t.eq(GameMode.parse(word), nil, word)
		end
	end)

	t.test("game modes: abilities as Minecraft's GameType.updatePlayerAbilities gives them", function()
		-- Columns: survival, creative, adventure, spectator.
		local expected: { [string]: { boolean } } = {
			mayFly = { false, true, false, true },
			alwaysFlying = { false, false, false, true },
			noClip = { false, false, false, true },
			instabuild = { false, true, false, false },
			invulnerable = { false, true, false, true },
			mayBuild = { true, true, false, false },
			isSurvivalLike = { true, false, true, false },
			isSpectator = { false, false, false, true },
			canPickUp = { true, true, true, false },
			canInteract = { true, true, true, false },
			showsHud = { true, true, true, false },
		}
		for name, row in expected do
			local helper = (GameMode :: any)[name]
			local ofPlayer = (GameMode :: any)[`{name}Of`]
			t.ok(type(helper) == "function" and type(ofPlayer) == "function", `{name} and {name}Of exist`)
			for i, mode in GameMode.ALL do
				t.eq(helper(mode), row[i], `{name}({mode})`)
				t.eq(ofPlayer(fakePlayer({ [GameMode.ATTRIBUTE] = mode })), row[i], `{name}Of({mode})`)
			end
		end
	end)

	t.test("game modes: a player's mode, previous mode and permission come from attributes", function()
		local player = fakePlayer({
			[GameMode.ATTRIBUTE] = SPECTATOR,
			[GameMode.PREVIOUS_ATTRIBUTE] = ADVENTURE,
			[GameMode.PERMISSION_ATTRIBUTE] = true,
		})
		t.eq(GameMode.of(player), SPECTATOR)
		t.eq(GameMode.previousOf(player), ADVENTURE)
		t.ok(GameMode.mayChangeOwn(player))
		t.ok(not GameMode.isCreative(player))
		t.ok(GameMode.isCreative(fakePlayer({ [GameMode.ATTRIBUTE] = CREATIVE })))

		-- Before the server set anything: the default mode, no previous mode, no permission.
		local fresh = fakePlayer({})
		t.eq(GameMode.of(fresh), GameMode.default())
		t.eq(GameMode.previousOf(fresh), nil)
		t.ok(not GameMode.mayChangeOwn(fresh))
		-- Rubbish in the attributes is ignored.
		local odd = fakePlayer({
			[GameMode.ATTRIBUTE] = "Hardcore",
			[GameMode.PREVIOUS_ATTRIBUTE] = 3,
			[GameMode.PERMISSION_ATTRIBUTE] = "yes",
		})
		t.eq(GameMode.of(odd), GameMode.default())
		t.eq(GameMode.previousOf(odd), nil)
		t.ok(not GameMode.mayChangeOwn(odd))
	end)

	t.test("game modes: what each mode may do in menus (Menu.allows)", function()
		local Menu = require(shared.Inventory.Menu)
		local actions = {
			click = { kind = "click", window = 0, slot = 9, clickType = 0, button = 0 },
			drag = { kind = "drag", window = 0, mode = 0, slots = { 9, 10 } },
			select = { kind = "select", slot = 3 },
			drop = { kind = "drop", all = false },
			place = { kind = "place", item = 1 },
			creative = { kind = "creative", window = 0, slot = 9, item = 1, count = 1 },
			close = { kind = "close", window = 0 },
		}
		-- Columns: survival, creative, adventure, spectator.
		local expected = {
			click = { true, true, true, false },
			drag = { true, true, true, false },
			select = { true, true, true, true },
			drop = { true, true, true, false },
			place = { true, true, true, false },
			creative = { false, true, false, false },
			close = { true, true, true, true },
		}
		for kind, row in expected do
			for i, mode in GameMode.ALL do
				t.eq(Menu.allows(actions[kind], mode), row[i], `{kind} in {mode}`)
			end
		end
	end)

	--[[ Protocol ]]

	t.test("protocol: SetGameMode carries a GameType id; anything else is refused", function()
		for _, mode in GameMode.ALL do
			local b = Protocol.encodeSetGameMode(mode)
			t.eq(buffer.len(b), 1)
			t.eq(buffer.readu8(b, 0), GameMode.id(mode))
			t.eq(Protocol.decodeSetGameMode(b), mode)
		end
		local bad = buffer.create(1)
		buffer.writeu8(bad, 0, 4)
		t.eq(Protocol.decodeSetGameMode(bad), nil, "id 4")
		buffer.writeu8(bad, 0, 255)
		t.eq(Protocol.decodeSetGameMode(bad), nil, "id 255")
		t.eq(Protocol.decodeSetGameMode(buffer.create(0)), nil, "empty")
		t.eq(Protocol.decodeSetGameMode(buffer.create(2)), nil, "too long")
		t.ok(Protocol.ClientMessage.SetGameMode ~= nil and Protocol.ClientMessage.SpectatorTeleport ~= nil)
		local seen = {}
		for name, kind in Protocol.ClientMessage do
			t.ok(seen[kind] == nil, `{name} has its own number`)
			seen[kind] = true
		end
	end)

	t.test("protocol: SpectatorTeleport carries a user id, whole and finite", function()
		for _, userId in { 1, 156, 8000000000, -1, -2, 0 } do
			t.eq(Protocol.decodeSpectatorTeleport(Protocol.encodeSpectatorTeleport(userId)), userId, `{userId}`)
		end
		for _, bad in { 0 / 0, math.huge, -math.huge, 1.5, 2 ^ 60 } do
			t.eq(Protocol.decodeSpectatorTeleport(Protocol.encodeSpectatorTeleport(bad)), nil, `{bad}`)
		end
		t.eq(Protocol.decodeSpectatorTeleport(buffer.create(4)), nil, "short")
		t.eq(Protocol.decodeSpectatorTeleport(buffer.create(9)), nil, "long")
	end)

	--[[ /gamemode, the switcher and the previous mode ]]

	local list = {
		{ key = "alice", name = "Alice", displayName = "Ally" },
		{ key = "bob", name = "Bob", displayName = "Builder" },
	}
	local function context(modes: { [string]: string }, mayUse: boolean, mayTarget: boolean)
		return {
			source = list[1],
			players = list,
			mayUse = mayUse,
			mayTarget = mayTarget,
			modeOf = function(key)
				return modes[key]
			end,
		}
	end

	t.test("gamemode: adventure and spectator by name, letter and number", function()
		local modes = { alice = SURVIVAL, bob = SURVIVAL }
		for mode, words in { [ADVENTURE] = { "adventure", "a", "2" }, [SPECTATOR] = { "spectator", "sp", "3" } } do
			for _, word in words do
				local result = GameModeCommand.run(`/gamemode {word}`, context(modes, true, false))
				t.eq(#result.changes, 1, word)
				t.eq(result.changes[1].mode, mode, word)
				t.eq(result.feedback[1], `Set own game mode to {mode} Mode`, word)
			end
		end
		local result = GameModeCommand.run("/gm sp Bob", context(modes, false, true))
		t.eq(result.changes[1].key, "bob")
		t.eq(result.feedback[1], "Set Builder's game mode to Spectator Mode")
		t.eq(result.notices[1].text, "Your game mode has been updated to Spectator Mode")
		t.eq(GameModeCommand.USAGE, "Usage: /gamemode <survival | creative | adventure | spectator> [player]")
		local unknown = GameModeCommand.run("/gamemode spec", context(modes, true, false)).feedback[1]
		t.ok(string.find(unknown, "Unknown game mode 'spec'", 1, true), unknown)
		t.ok(string.find(unknown, "spectator (sp, 3)", 1, true), unknown)
		t.eq(
			GameModeCommand.run("/gm a", context({ alice = ADVENTURE }, true, false)).feedback[1],
			"Your game mode is already Adventure Mode"
		)
	end)

	t.test("gamemode: the switcher's requests (switchOwn) answer like the command", function()
		local modes = { alice = CREATIVE, bob = SURVIVAL }
		local result = GameModeCommand.switchOwn(SPECTATOR, context(modes, true, false))
		t.eq(#result.changes, 1)
		t.eq(result.changes[1].key, "alice")
		t.eq(result.changes[1].mode, SPECTATOR)
		t.eq(result.feedback[1], "Set own game mode to Spectator Mode")
		t.eq(#result.notices, 0)
		-- Admins may, where the command is off for everyone else.
		t.eq(#GameModeCommand.switchOwn(SURVIVAL, context(modes, false, true)).changes, 1)
		-- Without permission: refused with the command's answer.
		local denied = GameModeCommand.switchOwn(SURVIVAL, context(modes, false, false))
		t.eq(#denied.changes, 0)
		t.eq(denied.feedback[1], GameModeCommand.DENIED)
		-- Already in that mode: nothing changes and nothing is said.
		local same = GameModeCommand.switchOwn(CREATIVE, context(modes, true, false))
		t.eq(#same.changes, 0)
		t.eq(#same.feedback, 0)
	end)

	t.test("gamemode: who may change their own mode (the permission attribute)", function()
		local may = GameModeCommand.mayChangeOwn
		t.ok(may(5, true, {}, false, false), "everyone may by default")
		t.ok(not may(5, false, {}, false, false), "the command is off")
		t.ok(may(5, false, { 5 }, false, false), "admins still may")
		t.ok(may(5, { 5 }, {}, false, false), "listed")
		t.ok(not may(6, { 5 }, {}, false, false), "not listed")
		t.ok(may(6, false, {}, true, false), "the owner")
		t.ok(may(6, false, {}, false, true), "Studio")
	end)

	t.test("gamemode: the previous mode changes only when the mode does", function()
		local previousAfter = GameModeCommand.previousAfter
		t.eq(previousAfter(nil, SURVIVAL), nil, "the first mode has no previous one")
		t.eq(previousAfter(SURVIVAL, CREATIVE), SURVIVAL)
		t.eq(previousAfter(CREATIVE, SPECTATOR), CREATIVE)
		t.eq(previousAfter(SPECTATOR, SPECTATOR), nil, "setting the same mode keeps the previous one")
		t.eq(previousAfter("Hardcore", SURVIVAL), nil, "not a mode")

		-- F3 + N as Minecraft does it, on top of the server's bookkeeping: survival -> spectator ->
		-- back to survival -> spectator again.
		local mode, previous: string? = SURVIVAL, nil
		local function set(new: string)
			previous = previousAfter(mode, new) or previous
			mode = new
		end
		local function f3n()
			set(if mode ~= SPECTATOR then SPECTATOR else previous or CREATIVE)
		end
		f3n()
		t.eq(mode, SPECTATOR)
		t.eq(previous, SURVIVAL)
		f3n()
		t.eq(mode, SURVIVAL)
		t.eq(previous, SPECTATOR)
		set(SURVIVAL)
		t.eq(previous, SPECTATOR, "no change, the previous mode stays")
		f3n()
		t.eq(mode, SPECTATOR)
	end)
end

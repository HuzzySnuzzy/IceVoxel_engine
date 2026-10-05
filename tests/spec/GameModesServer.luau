--[[
	The server's game mode rules for Minecraft 1.20.1's four modes: block edits (Network/EditRules:
	mayEdit, minesOverTime, blocksPlacing), using items on blocks, pickups, damage, sounds, deaths
	and the spectator teleport (Players/GameModeRules), inventory actions per mode
	(Players/InventoryState.applyAs: spectators read only, creative actions creative only) and
	spectators opening containers without being their openers (Players/Containers, quiet viewers).
]]

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local GameMode = require(shared.GameMode)
	local Items = require(shared.Items)
	local Menu = require(shared.Inventory.Menu)
	local PlayerPhysics = require(shared.Movement.PlayerPhysics)
	local Protocol = require(shared.Net.Protocol)
	local Types = require(shared.Inventory.Types)
	local Containers = require(server.Players.Containers)
	local EditRules = require(server.Network.EditRules)
	local GameModeRules = require(server.Players.GameModeRules)
	local InventoryState = require(server.Players.InventoryState)

	local SURVIVAL, CREATIVE, ADVENTURE, SPECTATOR =
		GameMode.SURVIVAL, GameMode.CREATIVE, GameMode.ADVENTURE, GameMode.SPECTATOR
	local CHEST, TABLE, FURNACE = Blocks.id.Chest, Blocks.id.CraftingTable, Blocks.id.Furnace
	local STONE, DIRT = Items.id.Stone, Items.id.Dirt
	local PICKUP, QUICK_MOVE = Menu.ClickType.Pickup, Menu.ClickType.QuickMove

	-- `rule(mode)` for every mode, as "survival creative adventure spectator" yes / no words.
	local function matrix(rule: (string) -> boolean): string
		local words = {}
		for _, mode in { SURVIVAL, CREATIVE, ADVENTURE, SPECTATOR } do
			table.insert(words, if rule(mode) then "yes" else "no")
		end
		return table.concat(words, " ")
	end

	local function hotbar(window, slot: number): number
		return Menu.windowIndex(window, "inventory", slot)
	end

	--[[ Block edits ]]

	t.test("game modes on the server: who breaks, places and mines (EditRules)", function()
		-- survival creative adventure spectator
		t.eq(matrix(EditRules.mayEdit), "yes yes no no", "mayBuild: adventure and spectator edit nothing")
		t.eq(matrix(EditRules.minesOverTime), "yes no no no", "only survival mines over time")
		t.eq(matrix(EditRules.blocksPlacing), "yes yes yes no", "spectators are never in the way")
		-- What the modes that may edit get from the instabuild rules.
		local dirt = Blocks.id.Dirt
		t.ok(EditRules.mayBreak(dirt, GameMode.instabuild(CREATIVE), nil, 0, 0, 0, 0, nil), "creative: at once")
		t.ok(
			not EditRules.mayBreak(dirt, GameMode.instabuild(SURVIVAL), nil, 0, 0, 0, 0, nil),
			"survival: needs a Mine start"
		)
		t.eq(EditRules.drops(dirt, GameMode.instabuild(CREATIVE), nil), nil, "creative: no drop")
		t.eq(EditRules.drops(dirt, GameMode.instabuild(SURVIVAL), nil).item, DIRT, "survival: the block")
	end)

	--[[ Players ]]

	t.test("game modes on the server: item use, pickups, sounds, openers, invulnerability", function()
		-- survival creative adventure spectator
		t.eq(matrix(GameModeRules.mayUseItemOn), "yes yes no no", "Configurator and buckets: mayBuild")
		t.eq(matrix(GameModeRules.picksUp), "yes yes yes no", "spectators pick nothing up")
		t.eq(matrix(GameModeRules.makesSounds), "yes yes yes no", "spectators are silent")
		t.eq(matrix(GameModeRules.opensContainers), "yes yes yes no", "spectators open no chest lid")
		t.eq(matrix(GameModeRules.invulnerable), "no yes no yes", "Abilities.invulnerable")
	end)

	t.test("game modes on the server: fall damage hurts survival and adventure alike", function()
		t.eq(GameModeRules.fallDamage(SURVIVAL, 10), 7, "ceil(10 - 3)")
		t.eq(GameModeRules.fallDamage(ADVENTURE, 10), 7, "adventure falls like survival")
		t.eq(GameModeRules.fallDamage(ADVENTURE, 3.25), 1, "just past 3 blocks")
		t.eq(GameModeRules.fallDamage(SURVIVAL, 3), 0, "3 blocks are safe")
		t.eq(GameModeRules.fallDamage(SURVIVAL, 0), 0)
		t.eq(GameModeRules.fallDamage(CREATIVE, 100), 0, "creative may fly")
		t.eq(GameModeRules.fallDamage(SPECTATOR, 100), 0, "spectators may fly")
		t.eq(GameModeRules.fallDamage(SURVIVAL, 0 / 0), 0, "no number, no damage")
		t.eq(GameModeRules.MINECRAFT_HEALTH, 20)
	end)

	t.test("game modes on the server: players walled in suffocate (in-wall damage)", function()
		local ROCK, BEDROCK = Blocks.id.Stone, Blocks.id.Bedrock
		-- A mountain: bedrock below the world (as the server's peekBlock), stone up to y = 64, a
		-- 1 high tunnel at y = 10 and a 2 high one at y = 20 (x = 0..9), unloaded at x >= 100.
		local mountain: PlayerPhysics.World = {
			getBlock = function(x: number, y: number, _z: number): number?
				if x >= 100 then
					return nil
				elseif y < 0 then
					return BEDROCK
				elseif y >= 64 or (x >= 0 and x <= 9 and (y == 10 or y == 20 or y == 21)) then
					return Blocks.AIR
				end
				return ROCK
			end,
		}
		-- survival creative adventure spectator
		t.eq(
			matrix(function(mode)
				return GameModeRules.inWall(mode, mountain, 50.5, 30.3, 0.5)
			end),
			"yes no yes no",
			"in rock: those who can be hurt"
		)
		t.ok(not GameModeRules.inWall(SURVIVAL, mountain, 50.5, 64, 0.5), "standing on top")
		t.ok(not GameModeRules.inWall(SURVIVAL, mountain, 4.5, 10, 0.5), "crawling through a 1 high tunnel")
		t.ok(not GameModeRules.inWall(ADVENTURE, mountain, 4.5, 20, 0.5), "walking a 2 high one")
		t.ok(not GameModeRules.inWall(ADVENTURE, mountain, 4.5, 20.4, 0.5), "jumping in it")
		t.ok(GameModeRules.inWall(SURVIVAL, mountain, 50.5, 0, 0.5), "at the bottom of the world")
		t.ok(not GameModeRules.inWall(SURVIVAL, mountain, 150.5, 30, 0.5), "unloaded blocks don't hurt")
		-- Feet that are no place (every client owns its character) are in no wall, at once.
		local nan, inf, far = 0 / 0, math.huge, Protocol.MAX_COORDINATE + 1
		for _, feet in
			{ { nan, 30, 0 }, { 0, inf, 0 }, { 0, 30, -inf }, { far, 30, 0 }, { 0, -far, 0 }, { 1e300, 30, 0 } }
		do
			t.ok(
				not GameModeRules.inWall(SURVIVAL, mountain, feet[1], feet[2], feet[3]),
				`{feet[1]} {feet[2]} {feet[3]}`
			)
		end
		t.eq(GameModeRules.IN_WALL_DAMAGE, 1, "half a heart")
		t.eq(GameModeRules.IN_WALL_INTERVAL, 0.5, "every 10 ticks: 20 health last 10 s, as in Minecraft")

		-- Flying into the mountain as a spectator, then going back to survival or adventure: the
		-- hull can't get out (adventure can't dig), so the player suffocates rather than stay there.
		local function input(jump: boolean, sneak: boolean): PlayerPhysics.Input
			return {
				moveX = 1,
				moveZ = 0,
				forward = 1,
				facingX = 1,
				facingZ = 0,
				lookY = 0,
				jump = jump,
				sneak = sneak,
				sprint = false,
			}
		end
		for _, mode in { SURVIVAL, ADVENTURE } do
			local state = PlayerPhysics.new(50.5, 30.3, 0.5)
			PlayerPhysics.setGameMode(state, SPECTATOR)
			PlayerPhysics.tick(state, input(false, false), mountain)
			t.ok(not GameModeRules.inWall(SPECTATOR, mountain, state.x, state.y, state.z), "spectators belong there")
			PlayerPhysics.setGameMode(state, mode)
			local x, y = state.x, state.y
			for tick = 1, 200 do
				PlayerPhysics.tick(state, input(tick % 2 == 0, tick > 100), mountain)
			end
			t.ok(math.abs(state.x - x) < 1 and math.abs(state.y - y) < 1, `{mode}: stuck at {state.x}, {state.y}`)
			t.ok(GameModeRules.inWall(mode, mountain, state.x, state.y, state.z), `{mode}: suffocates`)
		end
	end)

	t.test("game modes on the server: spectators keep their inventory when they die", function()
		t.eq(GameModeRules.keepsInventory(SURVIVAL, false), false)
		t.eq(GameModeRules.keepsInventory(ADVENTURE, false), false)
		t.eq(GameModeRules.keepsInventory(CREATIVE, false), false, "creative drops (Minecraft)")
		t.eq(GameModeRules.keepsInventory(SPECTATOR, false), true, "ServerPlayer.die skips the loot")
		t.eq(GameModeRules.keepsInventory(SURVIVAL, true), true, "keepInventory")

		local state = InventoryState.new()
		state:join("spectator")
		state:window("spectator").inventory.slots[1] = { item = DIRT, count = 10 }
		local dropped = state:die("spectator", GameModeRules.keepsInventory(SPECTATOR, false))
		t.eq(#dropped, 0, "nothing drops")
		t.eq(state:window("spectator").inventory.slots[1].count, 10, "and nothing is lost")
	end)

	t.test("game modes on the server: a spectator teleports to another player's feet", function()
		local x, y, z = GameModeRules.spectatorTeleport(SPECTATOR, 1, 2, 10.25, 64.5, -3.75)
		t.eq(x, 10.25)
		t.eq(y, 64.5)
		t.eq(z, -3.75)
		-- Studio's test players have negative ids.
		t.ok(GameModeRules.spectatorTeleport(SPECTATOR, -1, -2, 0, 0, 0) ~= nil, "negative ids")
		for _, mode in { SURVIVAL, CREATIVE, ADVENTURE } do
			t.eq(GameModeRules.spectatorTeleport(mode, 1, 2, 0, 0, 0), nil, `only spectators: {mode}`)
		end
		t.eq(GameModeRules.spectatorTeleport(SPECTATOR, 5, 5, 0, 0, 0), nil, "not to oneself")
		-- The target's client owns its character: its position may be anything.
		local nan, inf = 0 / 0, math.huge
		t.eq(GameModeRules.spectatorTeleport(SPECTATOR, 1, 2, nan, 0, 0), nil, "NaN")
		t.eq(GameModeRules.spectatorTeleport(SPECTATOR, 1, 2, 0, inf, 0), nil, "infinite height")
		t.eq(GameModeRules.spectatorTeleport(SPECTATOR, 1, 2, 0, 0, -inf), nil, "infinite z")
		local far = Protocol.MAX_COORDINATE + 1
		t.eq(GameModeRules.spectatorTeleport(SPECTATOR, 1, 2, far, 0, 0), nil, "past the world sideways")
		t.eq(GameModeRules.spectatorTeleport(SPECTATOR, 1, 2, 0, 0, -far), nil)
		-- Heights stay within what spectators may reach.
		local _, low = GameModeRules.spectatorTeleport(SPECTATOR, 1, 2, 0, -1000, 0)
		t.eq(low, PlayerPhysics.NO_CLIP_MIN_Y, "below the world")
		local _, high = GameModeRules.spectatorTeleport(SPECTATOR, 1, 2, 0, Config.WorldHeight + 1000, 0)
		t.eq(high, PlayerPhysics.NO_CLIP_MAX_Y, "above it")
	end)

	--[[ Inventory actions per mode ]]

	-- A state with player "a" in it, holding 10 dirt in hotbar slot 1 and 5 stone in slot 2.
	local function newState()
		local state = InventoryState.new(Containers.new())
		state:join("a")
		local inventory = state:window("a").inventory
		inventory.slots[1] = { item = DIRT, count = 10 }
		inventory.slots[2] = { item = STONE, count = 5 }
		state:takeDirty()
		return state
	end

	t.test("game modes on the server: spectators change nothing in their inventory, yet get snapshots", function()
		local state = newState()
		local window = state:window("a")
		local inventory = window.inventory
		local function act(seq: number, action): { any }
			return state:applyAs("a", seq, action, SPECTATOR)
		end

		local thrown = act(1, { kind = "click", window = 0, slot = hotbar(window, 1), clickType = PICKUP, button = 0 })
		t.eq(#thrown, 0)
		t.eq(inventory.cursor, nil, "nothing picked up")
		t.eq(inventory.slots[1].count, 10)
		t.eq(state:snapshot("a").ack, 1, "acknowledged")
		t.eq(state:takeDirty()[1], "a", "a snapshot undoes the prediction")

		act(2, { kind = "click", window = 0, slot = hotbar(window, 2), clickType = QUICK_MOVE, button = 0 })
		t.eq(inventory.slots[2].count, 5, "no shift-click")
		t.eq(#act(3, { kind = "drop", all = true }), 0, "Q throws nothing")
		t.eq(inventory.slots[1].count, 10)
		inventory.cursor = { item = STONE, count = 3 }
		act(4, { kind = "drag", window = 0, mode = Menu.DragMode.Split, slots = { 9, 10 } })
		t.eq(inventory.cursor.count, 3, "no drag")
		t.eq(#act(5, { kind = "click", window = 0, slot = Types.OUTSIDE, clickType = PICKUP, button = 0 }), 0)
		t.eq(inventory.cursor.count, 3, "no throwing the cursor out either")
		inventory.cursor = nil
		act(6, { kind = "creative", window = 0, slot = Types.CURSOR, item = DIRT, count = 64 })
		t.eq(inventory.cursor, nil, "no creative items")
		t.eq(state:snapshot("a").ack, 6)

		-- Selecting a hotbar slot and closing still work.
		act(7, { kind = "select", slot = 3 })
		t.eq(inventory.selected, 3)
		state:open("a", 0, 0, 0, CHEST, true)
		t.eq(window.id, 1)
		act(8, { kind = "close", window = 1 })
		t.eq(window.id, 0, "closed")
		t.eq(state:openPosition("a"), nil)
		t.eq(state:snapshot("a").ack, 8)
		-- Junk is acknowledged too.
		state:applyAs("a", 9, nil :: any, SPECTATOR)
		t.eq(state:snapshot("a").ack, 9)
	end)

	t.test("game modes on the server: a spectator looks into a chest but takes nothing", function()
		local state = newState()
		state:join("b")
		state:open("b", 4, 5, 6, CHEST)
		local chest = state:window("b").container
		chest.slots[1] = { item = STONE, count = 7 }
		state:open("a", 4, 5, 6, CHEST, true)
		local window = state:window("a")
		t.eq(window.container, chest, "the same chest, shared")
		state:takeDirty()

		state:applyAs(
			"a",
			1,
			{ kind = "click", window = window.id, slot = 0, clickType = QUICK_MOVE, button = 0 },
			SPECTATOR
		)
		t.eq(chest.slots[1].count, 7, "the chest keeps its stone")
		t.eq(window.inventory.slots[1].count, 10)
		local dirty = state:takeDirty()
		t.eq(#dirty, 1, "only the spectator gets a snapshot: nothing changed for b")
		t.eq(dirty[1], "a")

		-- A change by the other viewer reaches the spectator.
		state:applyAs(
			"b",
			1,
			{ kind = "click", window = state:window("b").id, slot = 0, clickType = QUICK_MOVE, button = 0 },
			SURVIVAL
		)
		t.eq(chest.slots[1], nil, "b took the stone")
		local seen = false
		for _, key in state:takeDirty() do
			seen = seen or key == "a"
		end
		t.ok(seen, "the spectator sees it")

		-- A crafting table: the grid stays empty.
		state:open("a", 9, 9, 9, TABLE, true)
		local craft = state:window("a")
		state:applyAs(
			"a",
			2,
			{ kind = "click", window = craft.id, slot = hotbar(craft, 1), clickType = PICKUP, button = 0 },
			SPECTATOR
		)
		state:applyAs(
			"a",
			3,
			{ kind = "click", window = craft.id, slot = 1, clickType = PICKUP, button = 0 },
			SPECTATOR
		)
		t.eq(craft.container.slots[2], nil, "nothing put into the grid")
		t.eq(craft.inventory.slots[1].count, 10)
	end)

	t.test(
		"game modes on the server: adventure plays the inventory like survival; creative actions are creative only",
		function()
			local state = newState()
			local window = state:window("a")
			local inventory = window.inventory
			state:applyAs(
				"a",
				1,
				{ kind = "click", window = 0, slot = hotbar(window, 1), clickType = PICKUP, button = 0 },
				ADVENTURE
			)
			t.eq(inventory.cursor.count, 10, "picked up")
			t.eq(inventory.slots[1], nil)
			state:applyAs(
				"a",
				2,
				{ kind = "click", window = 0, slot = hotbar(window, 1), clickType = PICKUP, button = 0 },
				ADVENTURE
			)
			t.eq(inventory.slots[1].count, 10, "put back")
			local thrown = state:applyAs("a", 3, { kind = "drop", all = false }, ADVENTURE)
			t.eq(#thrown, 1, "Q throws one")
			t.eq(inventory.slots[1].count, 9)

			local creative = { kind = "creative", window = 0, slot = Types.CURSOR, item = STONE, count = 64 }
			for i, mode in { SURVIVAL, ADVENTURE, SPECTATOR } do
				state:applyAs("a", 3 + i, creative, mode)
				t.eq(inventory.cursor, nil, `no creative items in {mode}`)
				t.eq(state:snapshot("a").ack, 3 + i, "but an answer")
			end
			state:applyAs("a", 7, creative, CREATIVE)
			t.eq(inventory.cursor.count, 64, "creative takes one from the picker")
			-- Middle-click clone is instabuild's too.
			inventory.cursor = nil
			state:applyAs(
				"a",
				8,
				{ kind = "click", window = 0, slot = hotbar(window, 2), clickType = Menu.ClickType.Clone, button = 2 },
				ADVENTURE
			)
			t.eq(inventory.cursor, nil, "adventure clones nothing")
			state:applyAs(
				"a",
				9,
				{ kind = "click", window = 0, slot = hotbar(window, 2), clickType = Menu.ClickType.Clone, button = 2 },
				CREATIVE
			)
			t.eq(inventory.cursor.count, 64, "creative clones a full stack")
		end
	)

	--[[ Containers: spectators are no openers ]]

	t.test("game modes on the server: a spectator opens no chest lid", function()
		local store = Containers.new()
		local calls = {}
		store.onOpeners = function(_x, _y, _z, _container, opened)
			table.insert(calls, if opened then "open" else "close")
		end
		local state = InventoryState.new(store)
		for _, key in { "spectator", "survivor" } do
			state:join(key)
		end
		state:open("spectator", 1, 2, 3, CHEST, true)
		t.eq(#calls, 0, "a spectator alone: the lid stays shut")
		t.eq(#store:viewers(1, 2, 3), 1, "but it is a viewer (snapshots)")
		state:open("survivor", 1, 2, 3, CHEST)
		t.eq(table.concat(calls, ","), "open", "the first opener")
		state:close("survivor")
		t.eq(table.concat(calls, ","), "open,close", "the last opener left")
		t.ok(store:peek(1, 2, 3) ~= nil, "the spectator still looks into it")
		state:close("spectator")
		t.eq(#calls, 2, "the spectator leaves silently")
		t.eq(store:peek(1, 2, 3), nil, "empty and closed: forgotten")

		-- In the other order: the spectator leaving changes nothing for the lid.
		state:open("survivor", 1, 2, 3, CHEST)
		state:open("spectator", 1, 2, 3, CHEST, true)
		state:close("spectator")
		t.eq(#calls, 3, "only the survivor's open")
		state:close("survivor")
		t.eq(calls[4], "close")
		-- A furnace opened by a spectator alone is a viewer too.
		state:open("spectator", 7, 7, 7, FURNACE, true)
		t.eq(#store:viewers(7, 7, 7), 1)
		t.eq(#calls, 4)
		state:close("spectator")
		-- Opening twice counts once.
		store:get(0, 0, 0, CHEST)
		store:addViewer(0, 0, 0, "x", true)
		store:addViewer(0, 0, 0, "x")
		store:removeViewer(0, 0, 0, "x")
		t.eq(#calls, 4, "still the quiet viewer it was")
	end)
end

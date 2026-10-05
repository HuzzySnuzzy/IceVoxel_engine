--[[
	Game modes on the client: Minecraft's debug keys (Debug/DebugKeys: F3 on release, F3 + N,
	F3 + F4, F3 + Q), the game mode switcher's model (Ui/ModeSwitch), the spectator menu's model
	(Ui/SpectatorMenu), who sees, hears and aims at spectators (Player/SpectatorRules), and the
	inventory prediction's refusals per game mode (Inventory/Prediction with Menu.allows).
]]

return function(t, shared, require, _server, client)
	local Blocks = require(shared.Blocks)
	local GameMode = require(shared.GameMode)
	local Items = require(shared.Items)
	local Menu = require(shared.Inventory.Menu)
	local Types = require(shared.Inventory.Types)
	local DebugKeys = require(client.Debug.DebugKeys)
	local ModeSwitch = require(client.Ui.ModeSwitch)
	local SpectatorMenu = require(client.Ui.SpectatorMenu)
	local SpectatorRules = require(client.Player.SpectatorRules)
	local Prediction = require(client.Inventory.Prediction)

	local SURVIVAL, CREATIVE, ADVENTURE, SPECTATOR =
		GameMode.SURVIVAL, GameMode.CREATIVE, GameMode.ADVENTURE, GameMode.SPECTATOR
	local Click = Menu.ClickType
	local DIRT, STONE = Items.id.Dirt, Items.id.Stone

	--[[ Debug keys ]]

	local function context(overrides: { [string]: any }?): any
		local c: any = { screenOpen = false, mode = SURVIVAL, previous = nil, mayChange = true }
		for key, value in overrides or {} do
			c[key] = value
		end
		return c
	end

	t.test("debug keys: F3 alone toggles the debug screen when let go, not when pressed", function()
		local keys = DebugKeys.new()
		local action, handled = DebugKeys.press(keys, "F3", context())
		t.eq(action, nil, "nothing on the press")
		t.eq(handled, false)
		local released = DebugKeys.release(keys, "F3", context())
		t.ok(released and released.kind == "toggle", "toggles on release")
		-- Again: each tap toggles.
		DebugKeys.press(keys, "F3", context())
		t.eq((DebugKeys.release(keys, "F3", context()) :: any).kind, "toggle")
		-- A release whose press never reached the game (typed in the chat) does nothing.
		t.eq(DebugKeys.release(keys, "F3", context()), nil, "no press, no toggle")
		-- Other keys let go do nothing.
		DebugKeys.press(keys, "F3", context())
		t.eq(DebugKeys.release(keys, "W", context()), nil)
	end)

	t.test("debug keys: a combination ran while F3 was held: letting go toggles nothing", function()
		local keys = DebugKeys.new()
		DebugKeys.press(keys, "F3", context())
		local action, handled = DebugKeys.press(keys, "Q", context())
		t.ok(action ~= nil and handled, "F3 + Q ran")
		t.eq(DebugKeys.release(keys, "F3", context()), nil, "no toggle after a combination")
		-- The next F3 starts afresh.
		DebugKeys.press(keys, "F3", context())
		t.eq((DebugKeys.release(keys, "F3", context()) :: any).kind, "toggle", "the next tap toggles")
		-- A key that is no combination (walking while F3 is down) still lets F3 toggle (Minecraft:
		-- handledDebugKey is only set by a combination), and keeps its own use.
		DebugKeys.press(keys, "F3", context())
		local walk, walkHandled = DebugKeys.press(keys, "W", context())
		t.eq(walk, nil)
		t.eq(walkHandled, false, "W is not taken")
		t.eq((DebugKeys.release(keys, "F3", context()) :: any).kind, "toggle")
	end)

	t.test("debug keys: F3 + N switches to spectator, and back to the previous mode or creative", function()
		local keys = DebugKeys.new()
		local function n(ctx): any
			DebugKeys.press(keys, "F3", ctx)
			local action, handled = DebugKeys.press(keys, "N", ctx)
			t.ok(handled, "N taken")
			DebugKeys.release(keys, "F3", ctx)
			return action
		end
		for _, mode in { SURVIVAL, CREATIVE, ADVENTURE } do
			local action = n(context({ mode = mode, previous = CREATIVE }))
			t.eq(action.kind, "setMode")
			t.eq(action.mode, SPECTATOR, `from {mode}`)
		end
		t.eq(n(context({ mode = SPECTATOR, previous = ADVENTURE })).mode, ADVENTURE, "back to the previous mode")
		t.eq(n(context({ mode = SPECTATOR, previous = SURVIVAL })).mode, SURVIVAL)
		t.eq(n(context({ mode = SPECTATOR, previous = nil })).mode, CREATIVE, "creative without one")
		t.eq(DebugKeys.cycleTarget(SPECTATOR, nil), CREATIVE)
		t.eq(DebugKeys.cycleTarget(SURVIVAL, SPECTATOR), SPECTATOR)
	end)

	t.test("debug keys: without permission F3 + N and F3 + F4 only say so", function()
		local keys = DebugKeys.new()
		local denied = context({ mayChange = false })
		DebugKeys.press(keys, "F3", denied)
		local action = DebugKeys.press(keys, "N", denied) :: any
		t.eq(action.kind, "chat")
		t.eq(action.feedback, "Unable to switch game mode; no permission")
		action = DebugKeys.press(keys, "F4", denied) :: any
		t.eq(action.kind, "chat")
		t.eq(action.feedback, "Unable to open game mode switcher; no permission")
		t.eq(DebugKeys.release(keys, "F3", denied), nil, "still handled: no toggle")
		t.eq(DebugKeys.PREFIX, "[Debug]:")
		-- With it, F3 + F4 opens the switcher.
		DebugKeys.press(keys, "F3", context())
		t.eq((DebugKeys.press(keys, "F4", context()) :: any).kind, "switcher")
	end)

	t.test("debug keys: F3 + Q lists the combinations, in Minecraft's words", function()
		local keys = DebugKeys.new()
		DebugKeys.press(keys, "F3", context({ mayChange = false }))
		local action = DebugKeys.press(keys, "Q", context({ mayChange = false })) :: any
		t.eq(action.kind, "chat", "the list needs no permission")
		t.eq(action.feedback, "Key bindings:")
		t.eq(#action.lines, 3)
		t.eq(action.lines[1], "F3 + N = Cycle previous gamemode <-> spectator")
		t.eq(action.lines[2], "F3 + Q = Show this list")
		t.eq(action.lines[3], "F3 + F4 = Open game mode switcher")
		-- (A copy: changing it leaves the module's list alone.)
		action.lines[1] = "x"
		t.eq(DebugKeys.HELP[1], "F3 + N = Cycle previous gamemode <-> spectator")
	end)

	t.test("debug keys: no combination without F3, or with a screen open; no toggle over a screen", function()
		local keys = DebugKeys.new()
		local action, handled = DebugKeys.press(keys, "N", context())
		t.eq(action, nil, "N alone")
		t.eq(handled, false)
		local screen = context({ screenOpen = true })
		DebugKeys.press(keys, "F3", screen)
		action, handled = DebugKeys.press(keys, "F4", screen)
		t.eq(action, nil, "the switcher takes F4 itself")
		t.eq(handled, false)
		t.eq(DebugKeys.release(keys, "F3", screen), nil, "no toggle over a screen")
		-- The window lost the focus with F3 down: the release never comes.
		DebugKeys.press(keys, "F3", context())
		DebugKeys.press(keys, "Q", context())
		DebugKeys.reset(keys)
		t.eq(DebugKeys.release(keys, "F3", context()), nil, "forgotten")
		DebugKeys.press(keys, "F3", context())
		t.eq((DebugKeys.release(keys, "F3", context()) :: any).kind, "toggle", "and starts afresh")
	end)

	--[[ The game mode switcher ]]

	t.test("switcher: opens on the previous mode, else survival from creative and creative otherwise", function()
		t.eq(ModeSwitch.defaultSelected(SURVIVAL, ADVENTURE), ADVENTURE)
		t.eq(ModeSwitch.defaultSelected(SPECTATOR, CREATIVE), CREATIVE)
		t.eq(ModeSwitch.defaultSelected(CREATIVE, nil), SURVIVAL)
		t.eq(ModeSwitch.defaultSelected(SURVIVAL, nil), CREATIVE)
		t.eq(ModeSwitch.defaultSelected(ADVENTURE, nil), CREATIVE)
		t.eq(ModeSwitch.defaultSelected(SPECTATOR, nil), CREATIVE)
		local switcher = ModeSwitch.new(CREATIVE, nil)
		t.eq(switcher.hovered, SURVIVAL)
		t.eq(ModeSwitch.title(switcher), "Survival Mode")
	end)

	t.test("switcher: F4 goes creative, survival, adventure, spectator and round again", function()
		t.eq(ModeSwitch.nextMode(CREATIVE), SURVIVAL)
		t.eq(ModeSwitch.nextMode(SURVIVAL), ADVENTURE)
		t.eq(ModeSwitch.nextMode(ADVENTURE), SPECTATOR)
		t.eq(ModeSwitch.nextMode(SPECTATOR), CREATIVE)
		local switcher = ModeSwitch.new(SURVIVAL, SPECTATOR)
		local seen = {}
		for _ = 1, 5 do
			ModeSwitch.next(switcher)
			table.insert(seen, switcher.hovered)
		end
		t.eq(table.concat(seen, " "), "Creative Survival Adventure Spectator Creative")
	end)

	t.test("switcher: the mouse highlights a slot only once it has moved", function()
		local switcher = ModeSwitch.new(SURVIVAL, nil)
		t.eq(switcher.hovered, CREATIVE)
		-- The pointer rests on Spectator's slot when the screen opens: it doesn't count yet.
		ModeSwitch.pointer(switcher, 100, 50, SPECTATOR)
		ModeSwitch.pointer(switcher, 100, 50, SPECTATOR)
		t.eq(switcher.hovered, CREATIVE, "a pointer at rest changes nothing")
		ModeSwitch.pointer(switcher, 101, 50, SPECTATOR)
		t.eq(switcher.hovered, SPECTATOR, "moved: the slot under it")
		ModeSwitch.pointer(switcher, 140, 50, nil)
		t.eq(switcher.hovered, SPECTATOR, "off the slots: the highlight stays")
		-- F4 wins over a pointer resting on a slot, until it moves again.
		ModeSwitch.pointer(switcher, 60, 50, ADVENTURE)
		t.eq(switcher.hovered, ADVENTURE)
		ModeSwitch.next(switcher)
		t.eq(switcher.hovered, SPECTATOR)
		ModeSwitch.pointer(switcher, 60, 50, ADVENTURE)
		ModeSwitch.pointer(switcher, 60, 50, ADVENTURE)
		t.eq(switcher.hovered, SPECTATOR, "the resting pointer doesn't undo F4")
		ModeSwitch.pointer(switcher, 61, 51, ADVENTURE)
		t.eq(switcher.hovered, ADVENTURE)
		ModeSwitch.pointer(switcher, 62, 51, "Hardcore")
		t.eq(switcher.hovered, ADVENTURE, "only real modes")
	end)

	t.test("switcher: letting go of F3 switches to the highlighted mode, unless it is the current one", function()
		local switcher = ModeSwitch.new(SURVIVAL, CREATIVE)
		t.eq(ModeSwitch.choice(switcher), CREATIVE)
		ModeSwitch.next(switcher)
		t.eq(ModeSwitch.choice(switcher), nil, "survival again: nothing to do")
		ModeSwitch.next(switcher)
		t.eq(ModeSwitch.choice(switcher), ADVENTURE)
		-- The mode changed meanwhile (the caller sets `current` when F3 is let go).
		switcher.current = ADVENTURE
		t.eq(ModeSwitch.choice(switcher), nil)
	end)

	t.test("switcher: Minecraft's layout around the screen's centre", function()
		t.eq(ModeSwitch.slotX(1), -59)
		t.eq(ModeSwitch.slotX(2), -28)
		t.eq(ModeSwitch.slotX(3), 3)
		t.eq(ModeSwitch.slotX(4), 34)
		-- Every slot inside the box.
		for index = 1, 4 do
			local x = ModeSwitch.slotX(index)
			t.ok(
				x >= ModeSwitch.PANEL_X and x + ModeSwitch.SLOT <= ModeSwitch.PANEL_X + ModeSwitch.PANEL_WIDTH,
				`slot {index}`
			)
		end
		t.ok(ModeSwitch.SLOT_Y >= ModeSwitch.PANEL_Y)
		t.ok(ModeSwitch.HELP_Y + 8 <= ModeSwitch.PANEL_Y + ModeSwitch.PANEL_HEIGHT)
		t.eq(`{ModeSwitch.HELP_KEY} {ModeSwitch.HELP_TEXT}`, "[ F4 ] Next")
	end)

	--[[ The spectator menu ]]

	local function players(n: number): { any }
		local list = {}
		for i = 1, n do
			-- (Out of order, so sorting shows.)
			table.insert(list, { userId = 1000 - i, name = `P{1000 - i}` })
		end
		table.sort(list, function(a, b)
			return a.userId < b.userId
		end)
		return list
	end

	local function kinds(menu): string
		local out = {}
		for _, item in SpectatorMenu.items(menu) do
			table.insert(out, if item.kind == "player" then tostring(item.player.userId) else item.kind)
		end
		return table.concat(out, " ")
	end

	t.test("spectator menu: whom it lists: other players who don't spectate, by user id", function()
		local list = SpectatorMenu.targets({
			{ userId = 30, name = "C", spectator = false },
			{ userId = 10, name = "Me", spectator = true },
			{ userId = -2, name = "Studio", spectator = false },
			{ userId = 20, name = "B", spectator = true },
			{ userId = 5, name = "A", spectator = false },
		}, 10)
		t.eq(#list, 3)
		t.eq(list[1].userId, -2)
		t.eq(list[2].userId, 5)
		t.eq(list[3].userId, 30)
		t.eq(list[3].name, "C")
	end)

	t.test("spectator menu: a number key opens it, a number selects, the same number again uses", function()
		local gui = SpectatorMenu.newGui()
		local list = players(3)
		t.eq(SpectatorMenu.hotbarKey(gui, 4, list, 0), nil, "the first key only opens")
		local menu = gui.menu
		assert(menu, "open")
		t.eq(menu.selected, -1, "nothing selected")
		t.eq(kinds(menu), "teleport empty empty empty empty empty empty next close")
		t.eq(SpectatorMenu.label(menu), "Press a key to select a command, and again to use it.")
		t.eq(SpectatorMenu.item(menu, 7).enabled, false, "no next page on the root")
		-- 1 selects "Teleport to Player", 1 again opens it.
		SpectatorMenu.hotbarKey(gui, 0, list, 1)
		t.eq(menu.selected, 0)
		t.eq(SpectatorMenu.label(menu), "Teleport to Player")
		SpectatorMenu.hotbarKey(gui, 0, list, 2)
		t.eq(menu.category, "teleport")
		t.eq(menu.selected, -1)
		t.eq(SpectatorMenu.label(menu), "Select a player to teleport to")
		t.eq(kinds(menu), "997 998 999 empty empty empty empty next close")
		-- A player: select, then teleport.
		t.eq(SpectatorMenu.hotbarKey(gui, 1, list, 3), nil)
		t.eq(SpectatorMenu.label(menu), "P998")
		local action = SpectatorMenu.hotbarKey(gui, 1, list, 4)
		t.ok(action and action.kind == "teleport" and action.userId == 998, "teleport to 998")
		t.ok(gui.menu ~= nil, "the menu stays open")
		-- An empty slot does nothing; 9 selects close, 9 again closes.
		t.eq(SpectatorMenu.hotbarKey(gui, 5, list, 5), nil)
		t.eq(menu.selected, 1, "empty slots are not selected")
		SpectatorMenu.hotbarKey(gui, 8, list, 6)
		t.eq(SpectatorMenu.label(menu), "Close Menu")
		SpectatorMenu.hotbarKey(gui, 8, list, 7)
		t.eq(gui.menu, nil, "closed")
	end)

	t.test("spectator menu: alone in the game, Teleport to Player can be selected but not used", function()
		local gui = SpectatorMenu.newGui()
		SpectatorMenu.hotbarKey(gui, 0, {}, 0)
		local menu = gui.menu :: any
		t.eq(SpectatorMenu.item(menu, 0).enabled, false)
		SpectatorMenu.hotbarKey(gui, 0, {}, 1)
		t.eq(menu.selected, 0, "selected")
		SpectatorMenu.hotbarKey(gui, 0, {}, 2)
		t.eq(menu.category, "root", "not used")
	end)

	t.test("spectator menu: pages of 7, then 6 after Previous Page; Next Page dims on the last", function()
		local gui = SpectatorMenu.newGui()
		local list = players(15)
		SpectatorMenu.open(gui, list, 0)
		local menu = gui.menu :: any
		menu.category = "teleport"
		t.eq(kinds(menu), "985 986 987 988 989 990 991 next close", "first page")
		t.ok(SpectatorMenu.item(menu, 7).enabled, "a next page")
		-- 8 twice: the next page.
		SpectatorMenu.hotbarKey(gui, 7, list, 1)
		SpectatorMenu.hotbarKey(gui, 7, list, 2)
		t.eq(menu.page, 1)
		t.eq(kinds(menu), "previous 992 993 994 995 996 997 next close", "second page")
		t.eq(SpectatorMenu.item(menu, 0).name, "Previous Page")
		SpectatorMenu.hotbarKey(gui, 7, list, 3)
		t.eq(menu.page, 2)
		t.eq(kinds(menu), "previous 998 999 empty empty empty empty next close", "last page")
		t.eq(SpectatorMenu.item(menu, 7).enabled, false, "no further page")
		SpectatorMenu.hotbarKey(gui, 7, list, 4)
		t.eq(menu.page, 2, "a dimmed Next Page does nothing")
		-- 1 is Previous Page now.
		SpectatorMenu.hotbarKey(gui, 0, list, 5)
		SpectatorMenu.hotbarKey(gui, 0, list, 6)
		t.eq(menu.page, 1)
		-- Exactly 7 players: no second page.
		local seven = players(7)
		SpectatorMenu.open(gui, seven, 0)
		local small = gui.menu :: any
		small.category = "teleport"
		t.eq(SpectatorMenu.item(small, 7).enabled, false)
		t.eq(SpectatorMenu.item(small, 6).kind, "player")
	end)

	t.test("spectator menu: the middle click opens, then uses the selected slot", function()
		local gui = SpectatorMenu.newGui()
		local list = players(2)
		t.eq(SpectatorMenu.middleClick(gui, list, 0), nil)
		local menu = gui.menu :: any
		t.ok(menu ~= nil, "opened")
		t.eq(SpectatorMenu.middleClick(gui, list, 1), nil, "nothing selected: nothing used")
		SpectatorMenu.hotbarKey(gui, 0, list, 2)
		SpectatorMenu.middleClick(gui, list, 3)
		t.eq(menu.category, "teleport", "used Teleport to Player")
		SpectatorMenu.hotbarKey(gui, 0, list, 4)
		local action = SpectatorMenu.middleClick(gui, list, 5)
		t.ok(action and action.userId == 998, "teleports")
	end)

	t.test("spectator menu: the wheel moves the selection over enabled items only", function()
		local gui = SpectatorMenu.newGui()
		local list = players(2)
		SpectatorMenu.open(gui, list, 0)
		local menu = gui.menu :: any
		SpectatorMenu.scroll(gui, -1, 1)
		t.eq(menu.selected, -1, "nothing left of nothing")
		SpectatorMenu.scroll(gui, 1, 1)
		t.eq(menu.selected, 0, "Teleport to Player")
		SpectatorMenu.scroll(gui, 1, 2)
		t.eq(menu.selected, 8, "past the empty slots and the dimmed Next Page, to Close Menu")
		SpectatorMenu.scroll(gui, 1, 3)
		t.eq(menu.selected, 8, "the end")
		SpectatorMenu.scroll(gui, -1, 4)
		t.eq(menu.selected, 0)
		t.eq(menu.category, "root", "scrolling never uses")
		SpectatorMenu.scroll(gui, 0, 5)
		t.eq(menu.selected, 0)
		-- Closed: nothing.
		SpectatorMenu.close(gui)
		SpectatorMenu.scroll(gui, 1, 6)
		t.eq(gui.menu, nil)
	end)

	t.test("spectator menu: shows 3 seconds, fades over 2 and closes", function()
		local gui = SpectatorMenu.newGui()
		t.eq(SpectatorMenu.alpha(gui, 0), 0, "closed")
		SpectatorMenu.hotbarKey(gui, 0, {}, 10)
		t.eq(SpectatorMenu.alpha(gui, 10), 1)
		t.eq(SpectatorMenu.alpha(gui, 13), 1)
		t.near(SpectatorMenu.alpha(gui, 14), 0.5, 1e-9)
		SpectatorMenu.update(gui, 14)
		t.ok(gui.menu ~= nil, "still open while fading")
		-- A key keeps it.
		SpectatorMenu.hotbarKey(gui, 0, {}, 14)
		t.eq(SpectatorMenu.alpha(gui, 16), 1)
		SpectatorMenu.update(gui, 19)
		t.eq(gui.menu, nil, "faded out: closed")
		t.eq(gui.lastSelection, 0)
		-- Reopened from scratch.
		SpectatorMenu.hotbarKey(gui, 4, {}, 20)
		t.eq((gui.menu :: any).category, "root")
		t.eq((gui.menu :: any).selected, -1)
	end)

	--[[ Seeing spectators ]]

	t.test("spectators: invisible to non-spectators, a translucent head to spectators", function()
		for _, viewer in GameMode.ALL do
			for _, target in GameMode.ALL do
				local spectatorTarget = target == SPECTATOR
				local spectatorViewer = viewer == SPECTATOR
				t.eq(
					SpectatorRules.sees(viewer, target),
					not spectatorTarget or spectatorViewer,
					`{viewer} sees {target}`
				)
				local body = SpectatorRules.transparency(viewer, target, false)
				local head = SpectatorRules.transparency(viewer, target, true)
				if not spectatorTarget then
					t.eq(body, 0, `{target}: drawn as it is`)
					t.eq(head, 0)
				elseif spectatorViewer then
					t.eq(body, 1, "no body")
					t.eq(head, 0.85, "Minecraft's alpha 0.15 head")
				else
					t.eq(body, 1)
					t.eq(head, 1, "nothing at all")
				end
			end
			t.eq(SpectatorRules.targetable(viewer), viewer ~= SPECTATOR)
			t.eq(SpectatorRules.audible(viewer), viewer ~= SPECTATOR)
		end
	end)

	t.test("spectators: their faces, textures and effects hide with them, not only their parts", function()
		-- Roblox classes as Instance.IsA sees them: the class and its base classes.
		local classes: { [string]: { string } } = {
			Part = { "Part", "BasePart", "PVInstance", "Instance" },
			MeshPart = { "MeshPart", "TriangleMeshPart", "BasePart", "PVInstance", "Instance" },
			-- A classic face is a Decal on the head; a Texture is a Decal too.
			Decal = { "Decal", "FaceInstance", "Instance" },
			Texture = { "Texture", "Decal", "FaceInstance", "Instance" },
			ParticleEmitter = { "ParticleEmitter", "Instance" },
			Beam = { "Beam", "Instance" },
			Trail = { "Trail", "Instance" },
			Fire = { "Fire", "Instance" },
			Smoke = { "Smoke", "Instance" },
			Sparkles = { "Sparkles", "Instance" },
			-- Nothing drawn of their own.
			Motor6D = { "Motor6D", "JointInstance", "Instance" },
			Attachment = { "Attachment", "Instance" },
			Accessory = { "Accessory", "Accoutrement", "Instance" },
			Humanoid = { "Humanoid", "Instance" },
			SpecialMesh = { "SpecialMesh", "FileMesh", "DataModelMesh", "Instance" },
		}
		local drawn = {
			Part = true,
			MeshPart = true,
			Decal = true,
			Texture = true,
			ParticleEmitter = true,
			Beam = true,
			Trail = true,
			Fire = true,
			Smoke = true,
			Sparkles = true,
		}
		for name, bases in classes do
			local hidden = SpectatorRules.hidden(function(class: string): boolean
				return table.find(bases, class) ~= nil
			end)
			t.eq(hidden, drawn[name] == true, name)
		end
	end)

	t.test("spectators: the player being spectated is never aimed at (the camera is inside them)", function()
		for _, target in GameMode.ALL do
			t.eq(SpectatorRules.aimable(target, false), target ~= SPECTATOR, `{target} aimed at`)
			t.eq(SpectatorRules.aimable(target, true), false, `{target} spectated: looked through`)
		end
	end)

	--[[ Inventory prediction per game mode ]]

	local function snapshot(ack: number, slots, extra)
		local inventory = Types.newInventory()
		for slot, stack in slots do
			inventory.slots[slot] = stack
		end
		local snap = { ack = ack, inventory = inventory, window = 0, container = Types.newCrafting("inventory") }
		for key, value in extra or {} do
			snap[key] = value
		end
		return snap
	end

	t.test("prediction: a spectator's clicks, drops and creative actions change nothing", function()
		local p = Prediction.new()
		p:receive(snapshot(0, { [1] = { item = DIRT, count = 10 } }), SPECTATOR)
		local w = p:window()
		local slot = Menu.windowIndex(w, "inventory", 1)
		p:push({ kind = "click", window = 0, slot = slot, clickType = Click.Pickup, button = 0 }, SPECTATOR)
		t.eq(p:window().inventory.cursor, nil, "nothing picked up")
		t.eq(p:window().inventory.slots[1].count, 10)
		p:push({ kind = "drop", all = true }, SPECTATOR)
		t.eq(p:window().inventory.slots[1].count, 10, "nothing thrown")
		p:push({ kind = "creative", window = 0, slot = Types.CURSOR, item = STONE, count = 64 }, SPECTATOR)
		t.eq(p:window().inventory.cursor, nil, "no creative stacks")
		p:push({ kind = "drag", window = 0, mode = 0, slots = { slot } }, SPECTATOR)
		t.eq(p:window().inventory.slots[1].count, 10)
		-- Picking hotbar slots and closing windows still work.
		p:push({ kind = "select", slot = 4 }, SPECTATOR)
		t.eq(p:window().inventory.selected, 4)
		t.ok(Menu.allows({ kind = "close", window = 0 }, SPECTATOR))
	end)

	t.test("prediction: a spectator looks into a chest read only and closes it", function()
		local p = Prediction.new()
		local chest =
			{ kind = "chest", block = Blocks.id.Chest, size = 27, slots = { [1] = { item = STONE, count = 5 } } }
		p:receive(snapshot(0, {}, { window = 3, container = chest }), SPECTATOR)
		p:push({ kind = "click", window = 3, slot = 0, clickType = Click.QuickMove, button = 0 }, SPECTATOR)
		t.eq(p:window().container.slots[1].count, 5, "still in the chest")
		t.eq(p:window().inventory.slots[1], nil, "not in the inventory")
		p:push({ kind = "close", window = 3 }, SPECTATOR)
		t.eq(p:window().id, 0, "closed: the inventory's window again")
	end)

	t.test("prediction: creative actions need instabuild; adventure uses blocks up like survival", function()
		for _, mode in { SURVIVAL, ADVENTURE } do
			local p = Prediction.new()
			p:receive(snapshot(0, { [1] = { item = DIRT, count = 2 } }), mode)
			p:push({ kind = "creative", window = 0, slot = Types.CURSOR, item = STONE, count = 64 }, mode)
			t.eq(p:window().inventory.cursor, nil, `{mode}: no creative stacks`)
			p:push({ kind = "place", item = DIRT }, mode)
			t.eq(p:window().inventory.slots[1].count, 1, `{mode}: placing uses one up`)
		end
		local p = Prediction.new()
		p:receive(snapshot(0, { [1] = { item = DIRT, count = 2 } }), CREATIVE)
		p:push({ kind = "creative", window = 0, slot = Types.CURSOR, item = STONE, count = 64 }, CREATIVE)
		t.eq(p:window().inventory.cursor.count, 64, "creative: a full stack")
		p:push({ kind = "place", item = DIRT }, CREATIVE)
		t.eq(p:window().inventory.slots[1].count, 2, "creative keeps it")
	end)

	t.test("prediction: pending actions replay by the new mode's rules after a mode change", function()
		local p = Prediction.new()
		p:receive(snapshot(0, { [1] = { item = DIRT, count = 10 } }), SURVIVAL)
		local slot = Menu.windowIndex(p:window(), "inventory", 1)
		p:push({ kind = "click", window = 0, slot = slot, clickType = Click.Pickup, button = 0 }, SURVIVAL)
		t.eq(p:window().inventory.cursor.count, 10, "picked up in survival")
		-- Switched to spectator before the server answered: the server refuses it now.
		p:replay(SPECTATOR)
		t.eq(p:window().inventory.cursor, nil, "refused as a spectator")
		t.eq(p:window().inventory.slots[1].count, 10)
		p:replay(SURVIVAL)
		t.eq(p:window().inventory.cursor.count, 10, "and back")
	end)
end

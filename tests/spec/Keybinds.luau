--[[
	Key bindings and the Controls / Accessibility settings: Shared/KeyBindings (the inputs and their
	codes checked against Roblox's own enum, the defaults against today's keys, conflicts, the Key
	Binds list's order), the bindings as settings (PlayerSettings: clamping, the wire, the saved
	record; Settings/State: choosing, Reset, Reset Keys, Defaults), the client's Settings/Keybinds
	with fake inputs (matches for keys and mouse buttons, isDown, hotbar slots, names), the
	Key Binds list's layout and scrolling (Settings/Pages), and the math behind the new settings:
	Minecraft's mouse sensitivity curve, scrolling, distortion, the view bob and hurt tilt
	(Player/ViewBob).
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

--[[
	Roblox's Enum with one object per item (Lune's enum items are new userdata at every access,
	so they can't be table keys): Enum.KeyCode.W is always the same table { Name, Value }.
]]
local function fakeEnum(): any
	local enums = {}
	return setmetatable({}, {
		__index = function(_, enumName: string)
			local enum = enums[enumName]
			if enum == nil then
				local items = {}
				enum = setmetatable({}, {
					__index = function(_, itemName: string)
						local item = items[itemName]
						if item == nil then
							local real = (roblox.Enum :: any)[enumName][itemName]
							item = { Name = real.Name, Value = real.Value, EnumType = enumName }
							items[itemName] = item
						end
						return item
					end,
				})
				enums[enumName] = enum
			end
			return enum
		end,
	})
end

--[[
	The client's Settings/Keybinds over `values` (its Settings stand-in), with a fake
	UserInputService: `world.down` holds the KeyCode names held, `world.mouse` the mouse buttons
	held, `world.last` the last input type's name, `world.typing` a focused text box.
]]
local function fakeKeybinds(shared: any, sharedRequire: (any) -> any, values: any): (any, any, any)
	local Enum = fakeEnum()
	local world: any = { down = {}, mouse = {}, last = "Keyboard", typing = false, keyboard = true }
	local services: { [string]: any } = {
		ReplicatedStorage = {
			WaitForChild = function(_, name: string)
				assert(name == "IceVoxel")
				return shared
			end,
		},
		UserInputService = setmetatable({
			IsKeyDown = function(_, code)
				return world.down[code.Name] == true
			end,
			IsMouseButtonPressed = function(_, kind)
				return world.mouse[kind.Name] == true
			end,
			GetLastInputType = function()
				return Enum.UserInputType[world.last]
			end,
			GetFocusedTextBox = function()
				return if world.typing then {} else nil
			end,
		}, {
			__index = function(_, key: string)
				if key == "KeyboardEnabled" then
					return world.keyboard
				end
				return nil
			end,
		}),
		TextChatService = {
			FindFirstChildOfClass = function()
				return nil
			end,
		},
	}
	local game = {
		GetService = function(_, name: string)
			return assert(services[name], `no fake service {name}`)
		end,
	}
	local Instance = {
		new = function(class: string)
			assert(class == "BindableEvent")
			local handlers = {}
			return {
				Event = {
					Connect = function(_, fn)
						table.insert(handlers, fn)
					end,
				},
				Fire = function()
					for _, fn in handlers do
						fn()
					end
				end,
			}
		end,
	}
	local settingsNode = { __fake = true, path = "src/client/Settings" }
	local keybindsNode = { __fake = true, path = "src/client/Settings/Keybinds", Parent = settingsNode }
	local function req(n: any): any
		if n == settingsNode then
			return { values = values }
		end
		return sharedRequire(n)
	end
	local GLOBALS = "script, require, game, Instance, Enum"
	local source = fs.readFile("src/client/Settings/Keybinds.luau")
	local lines = string.split(source, "\n")
	local i = 1
	while lines[i] and string.sub(lines[i], 1, 3) == "--!" do
		i += 1
	end
	lines[i] = `local {GLOBALS} = ...; ` .. (lines[i] or "")
	local chunk = luau.load(table.concat(lines, "\n"), { debugName = "Keybinds" })
	local Keybinds = chunk(keybindsNode, req, game, Instance, Enum)
	-- A fake InputObject: a key ("W") or a mouse button ("MouseButton1").
	local function input(name: string): any
		if string.sub(name, 1, 11) == "MouseButton" then
			return { UserInputType = Enum.UserInputType[name], KeyCode = Enum.KeyCode.Unknown }
		end
		return { UserInputType = Enum.UserInputType.Keyboard, KeyCode = Enum.KeyCode[name] }
	end
	return Keybinds, world, input
end

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local KeyBindings = require(shared.KeyBindings)
	local PlayerSettings = require(shared.PlayerSettings)
	local Protocol = require(shared.Net.Protocol)
	local Pages = require(client.Settings.Pages)
	local State = require(client.Settings.State)
	local ViewBob = require(client.Player.ViewBob)

	local Profile = PlayerSettings.Profile

	local function defaults()
		return PlayerSettings.defaults(false, 0)
	end

	--[[ The inputs ]]

	t.test("key bindings: every input is Roblox's KeyCode value, mouse buttons its mouse KeyCodes", function()
		local count = 0
		for _, key in KeyBindings.KEYS do
			count += 1
			local mouse = KeyBindings.MOUSE[key.name]
			if mouse then
				t.eq(key.code, mouse, key.name)
			else
				t.eq(key.code, (roblox.Enum.KeyCode :: any)[key.name].Value, `{key.name}'s code`)
				t.ok(key.code < 1000, `{key.name} is a keyboard key`)
			end
			t.eq(KeyBindings.find(key.name), key)
			t.eq(KeyBindings.keyOf(key.code), key)
			t.ok(KeyBindings.isCode(key.code), "bindable")
			t.ok(key.code <= KeyBindings.MAX_CODE, "within the settings' range")
		end
		t.ok(count >= 130, "every keyboard key")
		t.eq(KeyBindings.MOUSE.MouseButton1, roblox.Enum.KeyCode.MouseLeftButton.Value)
		t.eq(KeyBindings.MOUSE.MouseButton2, roblox.Enum.KeyCode.MouseRightButton.Value)
		t.eq(KeyBindings.MOUSE.MouseButton3, roblox.Enum.KeyCode.MouseMiddleButton.Value)
		t.eq(KeyBindings.NONE, roblox.Enum.KeyCode.Unknown.Value, "Not Bound is Unknown")
		t.ok(KeyBindings.isCode(KeyBindings.NONE), "Not Bound can be stored")
		t.eq(KeyBindings.find("Escape"), nil, "Escape unbinds, it is no binding")
		t.eq(KeyBindings.find("ButtonA"), nil, "gamepads are no bindings")
		t.ok(not KeyBindings.isCode(roblox.Enum.KeyCode.Escape.Value), "Escape's code can't be stored")
		t.ok(not KeyBindings.isCode(5), "an odd code can't")
		-- Roblox's report of an input -> a code.
		t.eq(KeyBindings.inputCode("Keyboard", 119), 119)
		t.eq(KeyBindings.inputCode("Keyboard", 27), nil, "Escape")
		t.eq(KeyBindings.inputCode("MouseButton2", 0), 1019)
		t.eq(KeyBindings.inputCode("Touch", 0), nil)
		t.eq(KeyBindings.inputCode("Gamepad1", 1002), nil)
		t.eq(KeyBindings.inputCode("MouseWheel", 0), nil)
		-- Minecraft's names.
		t.eq(KeyBindings.text(119), "W")
		t.eq(KeyBindings.text(304), "Left Shift")
		t.eq(KeyBindings.text(1018), "Left Button")
		t.eq(KeyBindings.text(1020), "Middle Button")
		t.eq(KeyBindings.text(47), "/")
		t.eq(KeyBindings.text(49), "1")
		t.eq(KeyBindings.text(KeyBindings.NONE), "Not Bound")
	end)

	t.test("key bindings: the defaults are today's keys and conflict nowhere", function()
		local expect = {
			forward = "W",
			back = "S",
			left = "A",
			right = "D",
			jump = "Space",
			sneak = Config.Movement.SneakKeys[1],
			sprint = Config.Movement.SprintKeys[1],
			attack = "MouseButton1",
			use = "MouseButton2",
			pickItem = "MouseButton3",
			drop = "Q",
			inventory = "E",
			hotbar1 = "One",
			hotbar5 = "Five",
			hotbar9 = "Nine",
			chat = "T",
			command = "Slash",
			options = Config.Settings.Key,
			skillTree = Config.Progression.Key,
			debug = "F3",
			worldMap = "M",
			zoomIn = "Equals",
			zoomOut = "Minus",
			jeiRecipes = "R",
			jeiUses = "U",
			jeiBack = "Backspace",
			weatherMap = "B",
		}
		for id, name in expect do
			t.eq(KeyBindings.action(id).default, name, `{id}'s default`)
			t.eq(KeyBindings.defaultCode(id), (KeyBindings.find(name) :: any).code)
		end
		t.eq(Config.Movement.SneakKeys[1], "LeftShift", "Config's sneak key")
		t.eq(Config.Movement.SprintKeys[1], "LeftControl", "Config's sprint key")
		local values = defaults()
		t.eq(next(KeyBindings.conflicting(values)), nil, "no conflicts by default")
		for _, action in KeyBindings.ACTIONS do
			t.ok(KeyBindings.isDefault(values, action.id), `{action.id} on its default`)
			t.eq(#KeyBindings.conflicts(values, action.id), 0)
		end
		t.ok(not pcall(KeyBindings.action, "nope"), "unknown actions error")
	end)

	t.test("key bindings: conflicts follow the contexts; Not Bound never conflicts", function()
		local values = defaults()
		-- Drop (universal) on W (walking, in the world): both red.
		values["key.drop"] = 119
		local red = KeyBindings.conflicting(values)
		t.ok(red.drop and red.forward, "universal vs game")
		t.eq(KeyBindings.conflicts(values, "drop")[1], "forward")
		-- Show Recipe (a screen key) on W: never at the same time, no conflict.
		values["key.drop"] = KeyBindings.defaultCode("drop")
		values["key.jeiRecipes"] = 119
		t.eq(next(KeyBindings.conflicting(values)), nil, "screen vs game")
		-- Show Recipe on Q (Drop works in screens too): a conflict.
		values["key.jeiRecipes"] = KeyBindings.defaultCode("drop")
		red = KeyBindings.conflicting(values)
		t.ok(red.jeiRecipes and red.drop, "screen vs universal")
		-- Two unbound keys don't conflict.
		values["key.jeiRecipes"] = KeyBindings.NONE
		values["key.jeiUses"] = KeyBindings.NONE
		t.eq(next(KeyBindings.conflicting(values)), nil, "Not Bound")
		t.ok(not KeyBindings.matches(values, "jeiUses", KeyBindings.NONE), "Not Bound matches nothing")
		t.ok(KeyBindings.overlap("game", "universal") and KeyBindings.overlap("screen", "screen"))
		t.ok(not KeyBindings.overlap("game", "screen"))
	end)

	t.test("key bindings: matches and hotbar slots read the values", function()
		local values = defaults()
		t.ok(KeyBindings.matches(values, "forward", 119))
		t.ok(not KeyBindings.matches(values, "forward", 115))
		t.ok(KeyBindings.matches(values, "attack", 1018), "a mouse button")
		t.ok(not KeyBindings.matches(values, "attack", nil))
		t.eq(KeyBindings.hotbarSlot(values, 49), 1)
		t.eq(KeyBindings.hotbarSlot(values, 57), 9)
		t.eq(KeyBindings.hotbarSlot(values, 119), nil)
		values["key.hotbar3"] = 122
		t.eq(KeyBindings.hotbarSlot(values, 122), 3, "rebound")
		t.eq(KeyBindings.hotbarSlot(values, 51), nil, "the old key does nothing")
		-- A missing value reads as the default.
		t.eq(KeyBindings.codeOf({}, "forward"), 119)
	end)

	t.test("key bindings: the list's order is Minecraft's (categories, then names)", function()
		local groups = KeyBindings.ordered()
		t.eq(groups[1].category.name, "Movement")
		local names = {}
		for _, action in groups[1].actions do
			table.insert(names, action.name)
		end
		t.eq(
			table.concat(names, ", "),
			"Jump, Sneak, Sprint, Strafe Left, Strafe Right, Walk Backwards, Walk Forwards",
			"Movement as Minecraft lists it"
		)
		t.eq(groups[2].actions[1].name, "Attack/Destroy")
		t.eq(groups[3].actions[1].name, "Drop Selected Item")
		t.eq(groups[3].actions[#groups[3].actions].name, "Open/Close Inventory")
		local seen, count = {}, 0
		for i, group in groups do
			if i > 1 then
				t.ok(
					table.find(KeyBindings.CATEGORIES, group.category)
						> table.find(KeyBindings.CATEGORIES, groups[i - 1].category),
					"categories in order"
				)
			end
			for _, action in group.actions do
				t.ok(seen[action.id] == nil, "once")
				seen[action.id] = true
				count += 1
			end
		end
		t.eq(count, #KeyBindings.ACTIONS, "every action listed")
		-- Pages lays them out: a row per category and per action, KEY_ROW apart.
		local rows, height = Pages.keyList(groups)
		t.eq(#rows, #groups + #KeyBindings.ACTIONS)
		t.eq(height, #rows * Pages.KEY_ROW)
		t.eq(rows[1].kind, "category")
		t.eq(rows[2].id, "jump")
		t.eq(rows[2].y, Pages.KEY_ROW)
		-- Name, key button and Reset side by side, inside the list beside the scroll bar.
		t.ok(Pages.KEY_NAME_W < Pages.KEY_BUTTON_X, "name before the key")
		t.ok(Pages.KEY_BUTTON_X + Pages.KEY_BUTTON_W < Pages.KEY_RESET_X, "key before Reset")
		t.ok(Pages.KEY_RESET_X + Pages.KEY_RESET_W <= Pages.WIDTH - Pages.SCROLL_BAR, "beside the bar")
		local reset, done = Pages.keyButtons()
		t.eq(reset.y, done.y, "Reset Keys and Done on one row")
		t.ok(reset.x + reset.w <= done.x and done.x + done.w <= Pages.WIDTH)
		t.ok(Pages.LIST_BOTTOM <= reset.y, "the list ends above them")
	end)

	t.test("key bindings: the list scrolls within its content; the thumb follows", function()
		local view = Pages.LIST_HEIGHT
		local content = 39 * Pages.KEY_ROW
		t.eq(Pages.clampScroll(-10, content, view), 0)
		t.eq(Pages.clampScroll(1e6, content, view), content - view)
		t.eq(Pages.clampScroll(50, view - 10, view), 0, "a list that fits doesn't scroll")
		local top, height = Pages.thumb(0, content, view)
		t.eq(top, 0)
		t.ok(height >= Pages.MIN_THUMB and height <= view - 8, "thumb size")
		local bottomTop, bottomHeight = Pages.thumb(content - view, content, view)
		t.eq(bottomTop + bottomHeight, view, "at the bottom, the thumb is too")
		local _, none = Pages.thumb(0, view - 1, view)
		t.eq(none, 0, "no thumb when it fits")
		-- Dragging the thumb back gives the scroll it shows.
		for _, scroll in { 0, 100, 333, content - view } do
			local at = Pages.thumb(scroll, content, view)
			t.near(Pages.scrollAtThumb(at, content, view), scroll, (content - view) / (view - height) + 1e-9, "drag")
		end
		-- A selected row comes into view, moving as little as possible.
		t.eq(Pages.scrollToShow(0, 400, Pages.KEY_ROW, content, view), 400 + Pages.KEY_ROW - view)
		t.eq(Pages.scrollToShow(300, 120, Pages.KEY_ROW, content, view), 120)
		t.eq(Pages.scrollToShow(100, 150, Pages.KEY_ROW, content, view), 100, "already shown")
		t.eq(Pages.WHEEL_STEP, Pages.KEY_ROW / 2, "half a row a wheel step")
	end)

	--[[ The bindings as settings ]]

	t.test("key bindings: stored as settings, clamped, sent and saved as codes", function()
		local entry = PlayerSettings.entry("key.forward")
		t.eq(entry.kind, "key")
		t.eq(entry.id, KeyBindings.KEY_BASE, "the first action's id")
		-- (Actions append: the Weather Map key, the newest, has the last id.)
		t.eq(PlayerSettings.entry("key.weatherMap").id, KeyBindings.KEY_BASE + #KeyBindings.ACTIONS - 1)
		t.eq(PlayerSettings.entry("key.jeiBack").id, KeyBindings.KEY_BASE + #KeyBindings.ACTIONS - 2)
		t.eq(PlayerSettings.clamp("key.forward", 104.6), 105, "whole codes")
		t.eq(PlayerSettings.clamp("key.forward", 500), 119, "a code that can't be bound: the default")
		t.eq(PlayerSettings.clamp("key.forward", 0 / 0), 119, "NaN: the default")
		t.eq(PlayerSettings.clamp("key.forward", 0), 0, "Not Bound stays")
		t.eq(PlayerSettings.clamp("key.attack", 1020), 1020, "a mouse button")
		t.eq(PlayerSettings.text("key.use", 1019), "Use Item/Place Block: Right Button")
		-- The wire: codes survive f32; unknown codes come back as the default.
		local b = Protocol.encodeSettings(Profile.Desktop, {
			["key.forward"] = 105,
			["key.attack"] = 1020,
			["key.drop"] = 0,
			["key.jump"] = 999,
		})
		local profile, decoded = Protocol.decodeSettings(b)
		t.eq(profile, Profile.Desktop)
		t.eq((decoded :: any)["key.forward"], 105)
		t.eq((decoded :: any)["key.attack"], 1020)
		t.eq((decoded :: any)["key.drop"], 0)
		t.eq((decoded :: any)["key.jump"], 32, "an odd code: the default")
		-- The saved record: ids as strings, like every setting.
		local record = PlayerSettings.toRecord({ [Profile.Desktop] = { ["key.forward"] = 105 } })
		t.eq(record.desktop[tostring(KeyBindings.KEY_BASE)], 105)
		t.eq(PlayerSettings.fromRecord(record)[Profile.Desktop]["key.forward"], 105)
		local odd = PlayerSettings.fromRecord({ desktop = { [tostring(KeyBindings.KEY_BASE)] = 3 } })
		t.eq(odd[Profile.Desktop]["key.forward"], 119, "an odd saved code: the default")
		-- Every binding of a whole profile fits the u8 count.
		t.ok(#PlayerSettings.ENTRIES <= 255, "a profile fits one message")
	end)

	t.test("key bindings: choosing, Reset, Reset Keys and Defaults", function()
		local state = State.new(Profile.Desktop, false, 0)
		t.eq(state.values["key.forward"], 119)
		local changed = State.set(state, "key.forward", 105)
		t.eq(changed[1], "key.forward")
		t.ok(state.chosen["key.forward"], "chosen")
		t.eq(State.payload(state)["key.forward"], 105, "saved")
		State.set(state, "key.drop", 0)
		-- Reset (one key): back to the default, no longer saved.
		local revision = state.revision
		changed = State.unset(state, { "key.forward" })
		t.eq(changed[1], "key.forward")
		t.eq(state.values["key.forward"], 119)
		t.eq(state.chosen["key.forward"], nil)
		t.eq(State.payload(state)["key.forward"], nil)
		t.ok(state.revision > revision, "sent again")
		-- Reset Keys: every binding.
		local all = {}
		for _, action in KeyBindings.ACTIONS do
			table.insert(all, KeyBindings.settingKey(action.id))
		end
		State.unset(state, all)
		t.eq(state.values["key.drop"], KeyBindings.defaultCode("drop"))
		t.eq(next(State.payload(state)), nil, "nothing left to save")
		-- Unsetting what is on its default changes nothing.
		revision = state.revision
		t.eq(#State.unset(state, { "key.jump" }), 0)
		t.eq(state.revision, revision)
		-- Presets' settings can't be unset (they follow the preset).
		t.ok(not pcall(State.unset, state, { "renderDistance" }), "presets' settings")
		-- Defaults resets the bindings too.
		State.set(state, "key.jump", 106)
		State.restoreDefaults(state)
		t.eq(state.values["key.jump"], 32)
		-- A saved profile's bindings load, a session's choice wins.
		state = State.new(Profile.Desktop, false, 0)
		State.set(state, "key.back", 120)
		State.receive(state, { ["key.forward"] = 105, ["key.back"] = 121 })
		t.eq(state.values["key.forward"], 105, "saved binding")
		t.eq(state.values["key.back"], 120, "this session's")
	end)

	--[[ The client's Keybinds ]]

	t.test("key bindings: the client matches keys and mouse buttons, and knows what is held", function()
		local values = defaults()
		local Keybinds, world, input = fakeKeybinds(shared, require, values)
		t.ok(Keybinds.matches("forward", input("W")))
		t.ok(not Keybinds.matches("forward", input("S")))
		t.ok(Keybinds.matches("attack", input("MouseButton1")))
		t.ok(Keybinds.matches("use", input("MouseButton2")))
		t.ok(Keybinds.matches("pickItem", input("MouseButton3")))
		t.ok(not Keybinds.matches("attack", input("MouseButton2")))
		t.ok(Keybinds.matches("command", input("Slash")))
		t.ok(Keybinds.matches("chat", input("T")))
		t.ok(not Keybinds.matches("drop", input("Escape")), "Escape is nobody's")
		t.eq(Keybinds.hotbarSlot(input("Four")), 4)
		t.eq(Keybinds.hotbarSlot(input("W")), nil)
		-- Rebinding takes effect at once (the session's values are read live).
		values["key.forward"] = 105
		t.ok(Keybinds.matches("forward", input("I")))
		t.ok(not Keybinds.matches("forward", input("W")), "the old key does nothing")
		values["key.attack"] = 113
		t.ok(Keybinds.matches("attack", input("Q")), "attack on a key")
		t.ok(not Keybinds.matches("attack", input("MouseButton1")))
		values["key.use"] = KeyBindings.NONE
		t.ok(not Keybinds.matches("use", input("MouseButton2")), "Not Bound")
		t.eq(Keybinds.input("use"), nil, "nothing to bind")
		t.eq(Keybinds.name("use"), "Not Bound")
		t.eq(Keybinds.name("forward"), "I")
		t.eq((Keybinds.input("forward") :: any).Name, "I")
		t.eq((Keybinds.input("pickItem") :: any).Name, "MouseButton3", "a mouse button binds as its input type")
		-- Held: keys and mouse buttons, never while typing.
		world.down.I = true
		t.ok(Keybinds.isDown("forward"))
		world.typing = true
		t.ok(not Keybinds.isDown("forward"), "typing")
		world.typing = false
		world.mouse.MouseButton3 = true
		t.ok(Keybinds.isDown("pickItem"))
		t.ok(not Keybinds.isDown("use"), "Not Bound is never held")
		-- The keyboard drives the walk unless a gamepad or a touch came last.
		t.ok(Keybinds.usingKeys())
		world.last = "MouseMovement"
		t.ok(Keybinds.usingKeys())
		world.last = "Gamepad1"
		t.ok(not Keybinds.usingKeys())
		world.last = "Touch"
		t.ok(not Keybinds.usingKeys())
		world.last = "Focus"
		t.ok(Keybinds.usingKeys(), "the window getting the focus back")
		world.keyboard = false
		world.last = "Keyboard"
		t.ok(not Keybinds.usingKeys(), "no keyboard")
		-- The "keys" effect tells the listeners.
		local fired = 0
		Keybinds.changed:Connect(function()
			fired += 1
		end)
		Keybinds.refresh()
		t.eq(fired, 1)
	end)

	--[[ The new settings and their math ]]

	t.test("controls settings: pages, ranges and Minecraft's defaults", function()
		local values = defaults()
		t.eq(values.sensitivity, 100, "Sensitivity 100%")
		t.eq(values.invertMouse, 0)
		t.eq(values.scrollSensitivity, 0, "Scroll Sensitivity 1.00")
		t.eq(values.discreteScrolling, 0)
		t.eq(values.toggleSneak, 0, "Sneak: Hold")
		t.eq(values.viewBobbing, 1)
		t.eq(values.distortionEffects, 100)
		t.eq(values.damageTilt, 100)
		t.eq(values.attackIndicator, 1, "Crosshair")
		t.eq(values.fov, 70)
		t.eq(PlayerSettings.clamp("sensitivity", 250), 200)
		t.eq(PlayerSettings.clamp("scrollSensitivity", -500), -200)
		t.eq(PlayerSettings.clamp("attackIndicator", 7), 2)
		t.eq(PlayerSettings.clamp("fov", 20), 30, "Minecraft's 30..110")
		t.eq(PlayerSettings.clamp("fov", 200), 110)
		local pages = {
			sensitivity = "mouse",
			invertMouse = "mouse",
			scrollSensitivity = "mouse",
			discreteScrolling = "mouse",
			scrollHotbar = "mouse",
			toggleSneak = "controls",
			toggleSprint = "controls",
			viewBobbing = "accessibility",
			distortionEffects = "accessibility",
			fovEffects = "accessibility",
			damageTilt = "accessibility",
			attackIndicator = "hud",
		}
		for key, page in pages do
			t.eq(PlayerSettings.entry(key).page, page, `{key}'s page`)
			t.ok(not PlayerSettings.entry(key).preset, "no preset sets it")
		end
		-- Saved like any other.
		local _, back = Protocol.decodeSettings(Protocol.encodeSettings(Profile.Desktop, {
			sensitivity = 150,
			invertMouse = 1,
			scrollSensitivity = -37,
			damageTilt = 25,
		}))
		t.eq((back :: any).sensitivity, 150)
		t.eq((back :: any).invertMouse, 1)
		t.eq((back :: any).scrollSensitivity, -37)
		t.eq((back :: any).damageTilt, 25)
		-- The mouse page needs a mouse, the key list a keyboard (Settings.pageShown); both hang
		-- off Controls.
		t.eq(Pages.back("mouse"), "controls")
		t.eq(Pages.back("keybinds"), "controls")
		t.eq(Pages.back("accessibility"), "main")
	end)

	t.test("controls settings: Minecraft's sensitivity curve, scrolling and distortion", function()
		local values = defaults()
		t.eq(PlayerSettings.mouseSensitivity(values), 1, "100% is Roblox's own feel")
		values.sensitivity = 0
		t.near(PlayerSettings.mouseSensitivity(values), 0.064, 1e-9, "*yawn*: slow, never still")
		values.sensitivity = 200
		t.near(PlayerSettings.mouseSensitivity(values), 4.096, 1e-9, "HYPERSPEED!!!")
		values.sensitivity = 50
		t.near(PlayerSettings.mouseSensitivity(values), (0.6 * 0.25 + 0.2) ^ 3 * 8, 1e-9)

		-- Scrolling: 1.00 gives a step a notch; the rest adds up; a turn back starts over.
		t.eq(PlayerSettings.scrollSensitivity(values), 1)
		local steps, rest = PlayerSettings.scroll(0, 1, values)
		t.eq(steps, 1)
		t.eq(rest, 0)
		steps = PlayerSettings.scroll(0, -1, values)
		t.eq(steps, -1, "down")
		values.scrollSensitivity = -100
		t.near(PlayerSettings.scrollSensitivity(values), 0.1, 1e-12, "0.10")
		local total, acc = 0, 0
		for _ = 1, 10 do
			local s
			s, acc = PlayerSettings.scroll(acc, 1, values)
			total += s
		end
		t.eq(total, 1, "ten notches at 0.10 make one step")
		local s
		s, acc = PlayerSettings.scroll(0.5, -1, values)
		t.eq(s, 0)
		t.near(acc, -0.1, 1e-12, "a turn the other way starts over")
		values.scrollSensitivity = 50
		local big, _, turn = PlayerSettings.scroll(0, 1, values)
		t.eq(big, 3, "10^0.5 = 3.16: three whole steps")
		t.near(turn, 10 ^ 0.5, 1e-12, "the scaled turn")
		t.near(PlayerSettings.scrollTurn(-1, values), -(10 ^ 0.5), 1e-12, "screens get the scaled turn")
		-- Discrete Scrolling: a trackpad's 0.2 counts as a whole notch.
		values.scrollSensitivity = 0
		local smooth = PlayerSettings.scroll(0, 0.2, values)
		t.eq(smooth, 0)
		values.discreteScrolling = 1
		local discrete = PlayerSettings.scroll(0, 0.2, values)
		t.eq(discrete, 1)

		-- Distortion Effects: squared, as Minecraft's screenEffectScale.
		values.distortionEffects = 50
		t.near(PlayerSettings.distortion(values), 0.25, 1e-12)
		values.distortionEffects = 0
		t.eq(PlayerSettings.distortion(values), 0)
		-- FOV Effects stays linear (Minecraft's fovEffectScale).
		values.fovEffects = 50
		t.near(PlayerSettings.fovModifier(1.1, values), 1.05, 1e-12)
	end)

	t.test("view bob: Minecraft's walking bob and hurt tilt", function()
		-- Walking (4.317 blocks a second) on the ground: the bob eases up to 0.1.
		local walk, bob = 0, 0
		for _ = 1, 60 do
			walk, bob = ViewBob.advance(walk, bob, 4.317, true, 1 / 60)
		end
		t.near(bob, 0.1, 1e-3, "full bob after a second")
		t.near(walk, 4.317 * 0.6, 1e-9, "0.6 a block walked")
		-- In the air (or flying, swimming) it fades away.
		for _ = 1, 120 do
			walk, bob = ViewBob.advance(walk, bob, 4.317, false, 1 / 60)
		end
		t.eq(bob, 0, "gone")
		-- Slow walking bobs less (the speed a tick, under 0.1).
		bob = 0
		for _ = 1, 120 do
			walk, bob = ViewBob.advance(walk, bob, 1, true, 1 / 60)
		end
		t.near(bob, 1 / 20, 1e-3)
		-- The view: at walk 0, straight down by the bob, pitched by |cos(-0.2)| x bob x 5.
		local x, y, roll, pitch = ViewBob.bobView(0, 0.1)
		t.near(x, 0, 1e-12)
		t.near(y, -0.1, 1e-12)
		t.near(roll, 0, 1e-12)
		t.near(pitch, math.cos(0.2) * 0.5, 1e-12)
		-- Half a step on: sideways and rolled the most.
		x, y, roll = ViewBob.bobView(0.5, 0.1)
		t.near(math.abs(x), 0.05, 1e-12)
		t.near(math.abs(roll), 0.3, 1e-12)
		t.near(y, 0, 1e-9)
		-- No bob, no movement.
		x, y, roll, pitch = ViewBob.bobView(1.7, 0)
		t.eq(x + y + roll + pitch, 0)

		-- Hurt: nothing at the hit's instant, 14 degrees soon after, nothing after 10 ticks.
		t.near(ViewBob.hurtRoll(0, 1), 0, 1e-9)
		local most = 0
		for age = 0, 10, 0.05 do
			most = math.min(most, ViewBob.hurtRoll(age, 1))
		end
		t.near(most, -14, 0.05, "the full tilt")
		t.eq(ViewBob.hurtRoll(10, 1), 0)
		t.eq(ViewBob.hurtRoll(-1, 1), 0)
		t.near(ViewBob.hurtRoll(1.6, 0.5), ViewBob.hurtRoll(1.6, 1) / 2, 1e-12, "Damage Tilt scales it")
		t.eq(ViewBob.hurtRoll(1.6, 0), 0, "Damage Tilt OFF")
	end)
end

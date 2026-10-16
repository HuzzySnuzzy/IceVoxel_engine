--[[
	The touch buttons round the jump button (Ui/TouchLayout, Ui/TouchButtons; the review that found a
	firearm's AIM under a phone's screen once the camera's VIEW and LOOK were bound):
	- every slot on phones (667 x 375 and 568 x 320, a notched 844 x 390) and tablets (1024 x 768,
	  1366 x 1024, 1180 x 820), below Roblox's top bar (36 or 58 pixels), at every GUI Scale choice:
	  on the screen inside the safe area, clear of each other, of the jump button, of the HUD's
	  quickbar canvas and its attack square, and of the movement thumbstick's corner;
	- the buttons as bound, on a fake ContextActionService that places them as Roblox's CoreScript
	  ContextActionTouch does (each new touch button takes the first free place of its seven round a
	  frame at the screen's lower right and keeps it; SetPosition moves it within the frame; an eighth
	  is never made): Player/MovementController's Sprint and Sneak, the real Ui/WeaponButtons' FIRE,
	  AIM and RELOAD and the real Player/CameraRig (which binds no touch button of its own any more),
	  in any order, end up in their slots, five of the seven places taken;
	- the camera's own VIEW and LOOK (the real Ui/TouchButtons on a fake client): in their slots,
	  shown only on a touch screen with the setting on while playing and not a spectator, VIEW a tap
	  on Toggle Perspective, LOOK held while the finger is down, let go when hidden.
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local FakeClient = require("../lib/FakeClient")

local Enum = roblox.Enum

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local GuiScale = require(client.Ui.GuiScale)
	local HudLayout = require(client.Ui.HudLayout)
	local TouchLayout = require(client.Ui.TouchLayout)

	type Rect = HudLayout.Rect
	type Insets = HudLayout.Insets

	local function insets(left: number, top: number, right: number, bottom: number, bar: number): Insets
		return { left = left, top = top, right = right, bottom = bottom, bar = bar }
	end

	-- width, height, the safe area's insets and Roblox's top bar.
	local SCREENS = {
		{ 667, 375, insets(0, 0, 0, 0, 36) },
		{ 667, 375, insets(0, 0, 0, 0, 58) },
		{ 568, 320, insets(0, 0, 0, 0, 58) },
		{ 844, 390, insets(0, 0, 0, 0, 36) },
		{ 844, 390, insets(47, 0, 47, 21, 58) },
		{ 1024, 768, insets(0, 0, 0, 0, 36) },
		{ 1024, 768, insets(0, 0, 0, 0, 58) },
		{ 1180, 820, insets(0, 24, 0, 20, 58) },
		{ 1366, 1024, insets(0, 0, 0, 0, 36) },
		{ 1366, 1024, insets(0, 0, 0, 0, 58) },
	}

	local function describe(r: Rect): string
		return string.format("x %d..%d y %d..%d", r.x, r.x + r.w, r.y, r.y + r.h)
	end

	t.test(
		"touch buttons: every slot on screen, clear of the others, the jump button, the HUD and the stick",
		function()
			local problems: { string } = {}
			local function problem(text: string)
				if #problems < 8 then
					table.insert(problems, text)
				end
			end
			for _, screen in SCREENS do
				local w, h, inset = screen[1], screen[2], screen[3]
				local label = `{w} x {h} bar {inset.bar}`
				local safe = HudLayout.safeArea(w, h, inset)
				local jump = HudLayout.jumpButton(w, h, inset)
				local stick = HudLayout.thumbstick(w, h)
				local rects: { [string]: Rect } = {}
				for _, slot in TouchLayout.ORDER do
					local r = TouchLayout.rect(slot, w, h, inset)
					rects[slot] = r
					if not HudLayout.inside(r, safe) then
						problem(`{label}: {slot} ({describe(r)}) off the safe area ({describe(safe)})`)
					end
					if HudLayout.overlaps(r, jump) then
						problem(`{label}: {slot} covers the jump button`)
					end
					if HudLayout.overlaps(r, stick) then
						problem(`{label}: {slot} in the thumbstick's corner`)
					end
					-- The whole button frame's place is anchored at the safe area's bottom right.
					local ox, oy = TouchLayout.offset(slot, w, h, inset)
					t.eq(r.x, w - inset.right + ox)
					t.eq(r.y, h - inset.bottom + oy)
				end
				for i, a in TouchLayout.ORDER do
					for j = i + 1, #TouchLayout.ORDER do
						local b = TouchLayout.ORDER[j]
						if HudLayout.overlaps(rects[a], rects[b]) then
							problem(`{label}: {a} covers {b}`)
						end
					end
				end
				-- The HUD's canvas (its quickbar, the touch buttons beside it) and the attack square, at
				-- every GUI Scale choice (the canvas only shrinks from there to fit).
				for _, choice in GuiScale.choices(w, h, true) do
					local scale = GuiScale.base(w, h, true, choice)
					local hud = HudLayout.hud(w, h, inset, scale, true)
					local attack = HudLayout.attack(hud, scale, true)
					for slot, r in rects do
						if HudLayout.overlaps(r, hud) then
							problem(`{label} scale {scale}: {slot} covers the quickbar ({describe(hud)})`)
						end
						if HudLayout.overlaps(r, attack) then
							problem(`{label} scale {scale}: {slot} covers the attack square`)
						end
					end
				end
			end
			t.eq(#problems, 0, table.concat(problems, "; "))
			-- A slot is the same offset on every screen with the same jump button.
			local a1, a2 = TouchLayout.offset("aim", 667, 375, insets(0, 0, 0, 0, 36))
			local b1, b2 = TouchLayout.offset("aim", 844, 390, insets(47, 0, 47, 21, 58))
			t.eq(a1, b1)
			t.eq(a2, b2)
			t.eq(TouchLayout.BUTTON, 45, "ContextActionService's button size")
		end
	)

	--[[ The buttons as bound ]]

	-- Roblox's ContextActionTouch: the seven places round its frame, in its frame's pixels.
	local PLACES = { { 123, 70 }, { 30, 60 }, { 180, 160 }, { 85, -25 }, { 185, -25 }, { 185, 260 }, { 216, 65 } }

	local function fakeCas()
		local vector: { any } = {}
		local buttons: { [string]: { place: number, position: any? } } = {}
		local cas: any = { dropped = {} }
		local function add(name: string, touch: boolean)
			if buttons[name] then
				vector[buttons[name].place] = "empty"
				buttons[name] = nil
			end
			if not touch then
				return
			end
			local place = nil
			for i = 1, #vector do
				if vector[i] == "empty" then
					place = i
					break
				end
			end
			place = place or #vector + 1
			if place > #PLACES then
				table.insert(cas.dropped, name)
				return
			end
			vector[place] = name
			buttons[name] = { place = place, position = nil }
		end
		function cas.BindAction(_, name: string, _fn: any, touch: boolean, ...: any)
			add(name, touch)
		end
		function cas.BindActionAtPriority(_, name: string, _fn: any, touch: boolean, _priority: number, ...: any)
			add(name, touch)
		end
		function cas.UnbindAction(_, name: string)
			local b = buttons[name]
			if b then
				vector[b.place] = "empty"
				buttons[name] = nil
			end
		end
		function cas.SetTitle() end
		function cas.SetPosition(_, name: string, position: any)
			local b = buttons[name]
			if b then
				b.position = position
			end
		end
		-- Each touch button's rectangle (screen pixels) on a w x h screen: ContextActionGui is
		-- below the top bar in the safe area, its frame at (0.7, 0.5) of it, (0.3, 0.5) its size.
		function cas.rects(w: number, h: number, inset: Insets): { [string]: { rect: Rect, placed: boolean } }
			local top = math.max(inset.top, inset.bar)
			local aw, ah = w - inset.left - inset.right, h - top - inset.bottom
			local fx, fy, fw, fh = inset.left + 0.7 * aw, top + 0.5 * ah, 0.3 * aw, 0.5 * ah
			local size = if h <= 320 then 35 else 45
			local out = {}
			for name, b in buttons do
				local x, y
				if b.position then
					local p = b.position
					x, y = fx + p.X.Scale * fw + p.X.Offset, fy + p.Y.Scale * fh + p.Y.Offset
				else
					local s = PLACES[b.place]
					x, y = fx + s[1], fy + s[2]
				end
				out[name] = { rect = { x = x, y = y, w = size, h = size }, placed = b.position ~= nil }
			end
			return out
		end
		return cas
	end

	-- Ui/TouchButtons on a fake client: `ui` the screen it reads (viewport, insets, touch), `rig` the
	-- camera's stand-in.
	local function loadTouchButtons(cas: any, ui: any, rig: any, extra: { [string]: any }?)
		local services = {
			ContextActionService = cas,
			Players = ui.players,
			RunService = { RenderStepped = ui.renderStepped, BindToRenderStep = function() end },
			UserInputService = { InputBegan = FakeClient.signal(), InputEnded = ui.inputEnded },
		}
		local stubs: { [string]: any } = {
			["src/client/Player/CameraRig.luau"] = rig,
			["src/client/Ui/UiScale.luau"] = {
				viewport = function()
					return roblox.Vector2.new(ui.width, ui.height)
				end,
				insets = function()
					return ui.insets
				end,
				touch = function()
					return ui.touch
				end,
				follow = function(fn: () -> ())
					table.insert(ui.followers, fn)
					fn()
				end,
				screenGui = function(name: string, _layer: string, opts: any)
					local gui = FakeClient.Instance.new("ScreenGui")
					gui.Name = name
					gui.Enabled = if opts.enabled == nil then true else opts.enabled
					return gui
				end,
			},
		}
		for path, stub in extra or {} do
			stubs[path] = stub
		end
		local load = FakeClient.loader(shared, require, stubs, services)
		return load("src/client/Ui/TouchButtons.luau"), load
	end

	local function fakeUi(w: number, h: number, inset: Insets): any
		local player = FakeClient.Instance.new("Player")
		local playerGui = FakeClient.Instance.new("Folder")
		playerGui.Name = "PlayerGui"
		playerGui.Parent = player
		return {
			width = w,
			height = h,
			insets = inset,
			touch = true,
			followers = {},
			players = { LocalPlayer = player },
			playerGui = playerGui,
			renderStepped = FakeClient.signal(),
			inputEnded = FakeClient.signal(),
		}
	end

	t.test("touch buttons: as bound in any order, each lands in its slot (none of Roblox's places left)", function()
		t.eq(Config.Movement.TouchButtons, true, "touch buttons on by default")
		-- Player/MovementController places its two after binding them (each its own slot).
		local movement = fs.readFile("src/client/Player/MovementController.luau")
		t.ok(string.find(movement, "TouchButtons.place(name, touchSlots[name])", 1, true) ~= nil, "Movement places")
		t.ok(
			string.find(movement, 'IceVoxelSprint = "sprint", IceVoxelSneak = "sneak"', 1, true) ~= nil,
			"Sprint's and Sneak's slots"
		)
		local SLOT_OF = {
			IceVoxelSprint = "sprint",
			IceVoxelSneak = "sneak",
			IceVoxelWeaponFire = "fire",
			IceVoxelWeaponAim = "aim",
			IceVoxelWeaponReload = "reload",
		}
		for _, screen in SCREENS do
			local w, h, inset = screen[1], screen[2], screen[3]
			for _, order in { "movement first", "gun first" } do
				local cas = fakeCas()
				local ui = fakeUi(w, h, inset)
				local rig = {
					enabled = function()
						return true
					end,
				}
				local TouchButtons, load = loadTouchButtons(cas, ui, rig)
				local function movementBinds()
					for _, name in { "IceVoxelSprint", "IceVoxelSneak" } do
						cas:BindActionAtPriority(name, nil, true, 3000)
						TouchButtons.place(name, SLOT_OF[name])
					end
				end
				local WeaponButtons = load("src/client/Ui/WeaponButtons.luau")
				WeaponButtons.start({ fire = function() end, aim = function() end, reload = function() end })
				if order == "movement first" then
					movementBinds()
					WeaponButtons.setShown(true)
				else
					WeaponButtons.setShown(true)
					movementBinds()
					-- (A key binding changed: Sprint unbound and bound again, in a later place.)
					cas:UnbindAction("IceVoxelSprint")
					cas:BindActionAtPriority("IceVoxelSprint", nil, true, 3000)
					TouchButtons.place("IceVoxelSprint", "sprint")
				end
				local rects = cas.rects(w, h, inset)
				local count = 0
				for name, entry in rects do
					count += 1
					t.ok(entry.placed, `{w} x {h}, {order}: {name} put in its slot explicitly`)
					local want = TouchLayout.rect(SLOT_OF[name], w, h, inset)
					t.ok(
						math.abs(entry.rect.x - want.x) < 1e-6 and math.abs(entry.rect.y - want.y) < 1e-6,
						`{w} x {h}, {order}: {name} at {describe(entry.rect)}, its slot {describe(want)}`
					)
				end
				t.eq(count, 5, "Sprint, Sneak, FIRE, AIM, RELOAD")
				t.eq(#cas.dropped, 0, "no button dropped")
				-- The gun put away and taken out again: the same places.
				WeaponButtons.setShown(false)
				WeaponButtons.setShown(true)
				local again = cas.rects(w, h, inset)
				t.eq(again.IceVoxelWeaponAim.rect.y, rects.IceVoxelWeaponAim.rect.y, "AIM where it was")
				-- The screen changes (a rotation, the safe area): placed again from the new corner.
				ui.width, ui.height = h + 400, w
				for _, follow in ui.followers do
					follow()
				end
				local moved = cas.rects(ui.width, ui.height, inset)
				local want = TouchLayout.rect("fire", ui.width, ui.height, inset)
				t.ok(math.abs(moved.IceVoxelWeaponFire.rect.x - want.x) < 1e-6, "placed again on a screen change")
			end
		end
	end)

	t.test(
		"touch buttons: the camera rig binds no touch button of its own (its VIEW and LOOK are the game's)",
		function()
			local cas = fakeCas()
			local load = FakeClient.loader(shared, require, {
				["src/client/World/ClientWorld.luau"] = {},
				["src/client/Settings/Keybinds.luau"] = {
					isDown = function()
						return false
					end,
					matches = function()
						return false
					end,
				},
				["src/client/Player/MouseLook.luau"] = {
					hookCamera = function() end,
					hooked = function()
						return true
					end,
					turn = function() end,
					setRoom = function() end,
				},
				["src/client/Player/CameraFade.luau"] = { hook = function() end },
			}, {
				ContextActionService = cas,
				Players = { LocalPlayer = { CameraMode = nil } },
				RunService = { BindToRenderStep = function() end },
				UserInputService = { InputBegan = FakeClient.signal(), MouseIconEnabled = true },
			})
			local CameraRig = load("src/client/Player/CameraRig.luau")
			CameraRig.start(
				{
					getBlock = function()
						return 0
					end,
				} :: any,
				{}
			)
			t.eq(next(cas.rects(844, 390, insets(0, 0, 0, 0, 36))), nil, "no ContextActionService touch button")
		end
	)

	t.test("touch buttons: VIEW and LOOK in their slots, shown only where they work", function()
		local w, h, inset = 844, 390, insets(47, 0, 47, 21, 58)
		local ui = fakeUi(w, h, inset)
		local calls = { view = 0, look = {} :: { string } }
		local state = { enabled = true, playing = true }
		local rig = {
			enabled = function()
				return state.enabled
			end,
			playing = function()
				return state.playing
			end,
			touchView = function()
				calls.view += 1
			end,
			touchLook = function(held: boolean)
				table.insert(calls.look, tostring(held))
			end,
		}
		local spectator = false
		local TouchButtons = loadTouchButtons(fakeCas(), ui, rig, {})
		-- (GameMode is Shared's: a spectator through the stand-in's mode.)
		local GameMode = require(shared.GameMode)
		local isSpectatorOf = GameMode.isSpectatorOf
		GameMode.isSpectatorOf = function(_player: any): boolean
			return spectator
		end
		TouchButtons.start()
		local gui = ui.playerGui:FindFirstChild("IceVoxelTouchButtons")
		t.ok(gui ~= nil, "the game's own ScreenGui")
		local view, look = gui:FindFirstChild("View"), gui:FindFirstChild("Look")
		t.ok(view ~= nil and look ~= nil, "VIEW and LOOK")
		t.eq(view.ActionTitle.Text, "VIEW")
		t.eq(look.ActionTitle.Text, "LOOK")
		for name, button in { view = view, look = look } do
			local x, y = TouchLayout.offset(name :: any, w, h, inset)
			t.eq(button.Position.X.Scale, 1)
			t.eq(button.Position.Y.Scale, 1)
			t.eq(button.Position.X.Offset, x, `{name}'s slot`)
			t.eq(button.Position.Y.Offset, y)
			t.eq(button.Size.X.Offset, TouchLayout.BUTTON)
		end
		local function frame(): boolean
			ui.renderStepped:Fire(1 / 60)
			return gui.Enabled
		end
		t.ok(frame(), "playing on a touch screen: shown")
		local touch = { UserInputType = Enum.UserInputType.Touch, UserInputState = Enum.UserInputState.Begin }
		view.InputBegan:Fire(touch)
		t.eq(calls.view, 1, "VIEW: Toggle Perspective")
		local finger = { UserInputType = Enum.UserInputType.Touch, UserInputState = Enum.UserInputState.Begin }
		look.InputBegan:Fire(finger)
		t.eq(table.concat(calls.look, ","), "true", "LOOK held")
		ui.inputEnded:Fire({ UserInputType = Enum.UserInputType.Touch })
		t.eq(#calls.look, 1, "another finger's lift changes nothing")
		ui.inputEnded:Fire(finger)
		t.eq(table.concat(calls.look, ","), "true,false", "let go where the finger lifts")
		-- Hidden: a spectator, a screen open (not playing), no touch, the setting off, the rig off.
		look.InputBegan:Fire(finger)
		spectator = true
		t.ok(not frame(), "a spectator: hidden")
		t.eq(table.concat(calls.look, ","), "true,false,true,false", "hiding lets LOOK go")
		spectator = false
		t.ok(frame(), "shown again")
		state.playing = false
		t.ok(not frame(), "a screen open: hidden")
		state.playing = true
		ui.touch = false
		t.ok(not frame(), "not a touch screen: hidden")
		ui.touch = true
		Config.Movement.TouchButtons = false
		t.ok(not frame(), "the Touch Buttons setting off: hidden")
		Config.Movement.TouchButtons = true
		t.ok(frame(), "back")
		GameMode.isSpectatorOf = isSpectatorOf
		-- The pure rule.
		t.ok(TouchLayout.cameraShown(true, true, true, true, false))
		t.ok(not TouchLayout.cameraShown(true, true, false, true, false), "the rig off")
	end)
end

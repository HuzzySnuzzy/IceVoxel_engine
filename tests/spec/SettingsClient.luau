--[[
	The client side of the settings (Settings/Schedule, Settings/State, Settings/Pages): when
	effects run (cheap ones once at the next frame, costly ones once after a slider stops),
	choosing, presets, Reset and Defaults, merging the saved profile, what is sent, and the Options
	menu's pages and layout. Then the controller (Settings/init) and Rendering/ViewSettings in a
	simulation with fake services (a frame clock, Heartbeat, ClientNet, Lighting): the saved
	profile arriving at start, registered effects, debounced rebuilds, saving, LodTree, fog and
	lighting. And the Minimap setting's touch fallback (Map/Minimap with fake GUI instances).
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

--[[ A fake client: Settings/init and ViewSettings with fake services ]]

-- Arguments every client module gets (as locals, like tests/lib/Loader).
local GLOBALS = "script, require, game, workspace, Instance, UserSettings, os, task, warn"

local function withHeader(source: string): string
	local lines = string.split(source, "\n")
	local i = 1
	while lines[i] and string.sub(lines[i], 1, 3) == "--!" do
		i += 1
	end
	lines[i] = `local {GLOBALS} = ...; ` .. (lines[i] or "")
	return table.concat(lines, "\n")
end

local function fakeSignal(): any
	local handlers = {}
	return {
		Connect = function(_, fn)
			table.insert(handlers, fn)
			return { Disconnect = function() end }
		end,
		fire = function(...)
			for _, fn in handlers do
				fn(...)
			end
		end,
	}
end

--[[
	A fresh client: `world.frame()` runs one Heartbeat (1/60 s), `world.serverSends(buffer)`
	delivers a Settings message, `world.sent` lists the SaveSettings payloads. Saved quality level
	`quality`; an Atmosphere in Lighting with `atmosphere` (`world.atmosphere`, a property bag
	whose Parent says whether it is in Lighting).
]]
local function fakeClient(shared: any, sharedRequire: (any) -> any, quality: number, atmosphere: boolean?): any
	local world: any = { clock = 100, sent = {}, warnings = {} }
	local heartbeat = fakeSignal()
	local handlers: { [number]: (buffer) -> () } = {}
	world.lighting = {
		FogEnd = 100000,
		FogStart = 0,
		PrioritizeLightingQuality = true,
		FindFirstChildOfClass = function(_, class: string)
			local found = world.atmosphere
			return if class == "Atmosphere" and found and found.Parent == world.lighting then found else nil
		end,
	}
	if atmosphere then
		world.atmosphere = { Name = "Atmosphere", Parent = world.lighting }
	end
	local services: { [string]: any } = {
		ReplicatedStorage = {
			WaitForChild = function(_, name: string)
				assert(name == "IceVoxel")
				return shared
			end,
		},
		RunService = { Heartbeat = heartbeat },
		UserInputService = { TouchEnabled = false, KeyboardEnabled = true },
		GuiService = {
			IsTenFootInterface = function()
				return false
			end,
		},
		Lighting = world.lighting,
	}
	local game = {
		GetService = function(_, name: string)
			local service = services[name]
			assert(service, `no fake service {name}`)
			return service
		end,
	}
	local Instance = {
		new = function(class: string)
			assert(class == "BindableEvent", `no fake {class}`)
			local event = fakeSignal()
			return {
				Event = event,
				Fire = function(_, ...)
					event.fire(...)
				end,
			}
		end,
	}
	local function UserSettings()
		return {
			GetService = function()
				return { SavedQualityLevel = { Value = quality } }
			end,
		}
	end
	local fakeOs = {
		clock = function(): number
			return world.clock
		end,
	}
	function world.frame()
		world.clock += 1 / 60
		heartbeat.fire(1 / 60)
	end
	local fakeTask = {
		wait = function()
			world.frame()
			return 1 / 60
		end,
	}
	local function warn(...)
		table.insert(world.warnings, table.concat({ ... }, " "))
	end
	local clientNet = {
		on = function(kind: number, handler)
			handlers[kind] = handler
		end,
		send = function(kind: number, payload: buffer)
			table.insert(world.sent, { kind = kind, payload = payload })
		end,
	}
	function world.serverSends(kind: number, payload: buffer)
		handlers[kind](payload)
	end

	-- Fake script nodes for src/client, loaded lazily from the files.
	local cache: { [any]: any } = {}
	local function node(path: string, parent: any): any
		return setmetatable({ __fake = true, path = path, Parent = parent }, {
			__index = function(self: any, name: string): any
				local child = node(`{path}/{name}`, self)
				rawset(self, name, child)
				return child
			end,
		})
	end
	local root = node("src/client", nil)
	local function req(n: any): any
		if type(n) ~= "table" or not rawget(n, "__fake") then
			return sharedRequire(n)
		end
		if n.path == "src/client/Net/ClientNet" then
			return clientNet
		end
		local cached = cache[n]
		if cached ~= nil then
			return cached
		end
		local file = if fs.isDir(n.path) then `{n.path}/init.luau` else `{n.path}.luau`
		local chunk = luau.load(withHeader(fs.readFile(file)), { debugName = file })
		local result = chunk(n, req, game, {}, Instance, UserSettings, fakeOs, fakeTask, warn)
		cache[n] = result
		return result
	end
	world.Settings = req(root.Settings)
	world.ViewSettings = req(root.Rendering.ViewSettings)
	return world
end

--[[
	Map/Minimap with fake GUI instances (property bags; Activated / InputBegan signals) on a touch
	screen or not. `ui.named(name)` finds a created instance; `opened` counts world map openings.
]]
local function fakeMinimap(shared: any, sharedRequire: (any) -> any, touch: boolean): any
	local ui: any = { created = {}, opened = 0 }
	local services: { [string]: any } = {
		ReplicatedStorage = {
			WaitForChild = function(_, name: string)
				assert(name == "IceVoxel")
				return shared
			end,
		},
		Players = {
			LocalPlayer = {},
			PlayerRemoving = fakeSignal(),
			GetPlayers = function()
				return {}
			end,
		},
		UserInputService = { TouchEnabled = touch, InputBegan = fakeSignal() },
	}
	local game = {
		GetService = function(_, name: string)
			return assert(services[name], `no fake service {name}`)
		end,
	}
	local Instance = {
		new = function(class: string)
			local instance = { ClassName = class, Activated = fakeSignal() }
			table.insert(ui.created, instance)
			return instance
		end,
	}
	local GLOBALS = "script, require, game, workspace, Instance, Vector2, UDim2, UDim, Color3, Enum"
	local function node(path: string, parent: any): any
		return setmetatable({ __fake = true, path = path, Parent = parent }, {
			__index = function(self: any, name: string): any
				local child = node(`{path}/{name}`, self)
				rawset(self, name, child)
				return child
			end,
		})
	end
	local cache: { [any]: any } = {}
	local function req(n: any): any
		if type(n) ~= "table" or not rawget(n, "__fake") then
			return sharedRequire(n)
		end
		if n.path == "src/client/Map/MapLayer" or n.path == "src/client/Map/Waypoints" then
			-- (Types only here; the real ones need the worker pool and the network.)
			return {}
		end
		if n.path == "src/client/Map/WeatherLayer" then
			-- (The weather mode needs EditableImage and the weather's state: off here.)
			return {
				new = function()
					return { update = function() end }
				end,
				toggle = function() end,
				isOn = function()
					return false
				end,
				changed = fakeSignal(),
			}
		end
		if n.path == "src/client/Settings/Keybinds" then
			-- (The zoom keys: no key is pressed here.)
			return {
				matches = function()
					return false
				end,
			}
		end
		if cache[n] == nil then
			local source = fs.readFile(`{n.path}.luau`)
			local lines = string.split(source, "\n")
			local i = 1
			while lines[i] and string.sub(lines[i], 1, 3) == "--!" do
				i += 1
			end
			lines[i] = `local {GLOBALS} = ...; ` .. (lines[i] or "")
			local chunk = luau.load(table.concat(lines, "\n"), { debugName = n.path })
			cache[n] =
				chunk(n, req, game, {}, Instance, roblox.Vector2, roblox.UDim2, roblox.UDim, roblox.Color3, roblox.Enum)
		end
		return cache[n]
	end
	local Minimap = req(node("src/client", nil).Map.Minimap)
	ui.gui = { ClassName = "ScreenGui" }
	local layer = { available = true, size = 4096, scale = 1 }
	ui.minimap = Minimap.new(ui.gui, layer, { list = {} }, function()
		ui.opened += 1
	end)
	function ui.named(name: string): any
		for _, instance in ui.created do
			if instance.Name == name then
				return instance
			end
		end
		return nil
	end
	return ui
end

return function(t, shared, require, _server, client)
	local PlayerSettings = require(shared.PlayerSettings)
	local Schedule = require(client.Settings.Schedule)
	local State = require(client.Settings.State)
	local Pages = require(client.Settings.Pages)

	local Profile = PlayerSettings.Profile
	local FRAME = 1 / 60

	--[[ Schedule ]]

	t.test("settings client: cheap effects run at the next frame, once however many changes", function()
		local schedule = Schedule.new(0.4)
		Schedule.markKeys(schedule, { "fov", "fovEffects", "masterVolume", "minimap", "waila" }, 10)
		local due = Schedule.due(schedule, 10)
		t.eq(table.concat(due, ","), "camera,audio,hud", "one each, in order")
		t.eq(#Schedule.due(schedule, 10 + FRAME), 0, "nothing left")
		t.eq(Schedule.waiting(schedule), 0)
	end)

	t.test("settings client: costly effects wait until the slider stops, then run once", function()
		local schedule = Schedule.new(0.4)
		-- A render distance drag: 30 steps over 1.5 s at 60 frames a second.
		local runs: { [string]: number } = {}
		local now = 0
		for frame = 0, 150 do
			if frame % 5 == 0 and frame <= 145 then
				Schedule.markKeys(schedule, { "renderDistance" }, now)
			end
			for _, effect in Schedule.due(schedule, now) do
				runs[effect] = (runs[effect] or 0) + 1
			end
			now += FRAME
		end
		t.eq(runs.fog, 30, "the fog (cheap) follows every step")
		t.eq(runs.lod, nil, "the view waits while the slider moves")
		for _ = 1, 30 do
			for _, effect in Schedule.due(schedule, now) do
				runs[effect] = (runs[effect] or 0) + 1
			end
			now += FRAME
		end
		t.eq(runs.lod, 1, "one rebuild after the slider stopped")
		-- Shadows, far meshes, caves, plants and textures wait too.
		for _, key in { "shadows", "farMeshes", "caveView", "plants", "textures", "farShadows" } do
			Schedule.markKeys(schedule, { key }, 100)
			for _, effect in Schedule.due(schedule, 100 + FRAME) do
				t.ok(not PlayerSettings.EXPENSIVE[effect], `{key}'s {effect} waits`)
			end
		end
		-- Closing the menu runs them all at once, in order (the view before its fog).
		Schedule.markKeys(schedule, { "renderDistance" }, 200)
		local all = Schedule.due(schedule, 200, true)
		t.ok(table.find(all, "lod") < table.find(all, "fog"), "view before fog")
		t.ok(table.find(all, "lod") < table.find(all, "caves"), "order")
		t.eq(Schedule.waiting(schedule), 0)
	end)

	--[[ State ]]

	t.test("settings client: choosing, the balance rule, presets, Reset and Defaults", function()
		local state = State.new(Profile.Desktop, false, 0)
		t.eq(State.presetName(state), "High")
		t.eq(next(State.payload(state)), nil, "nothing chosen")
		t.ok(not State.unsent(state), "nothing to send")

		local values = state.values
		local changed = State.set(state, "renderDistance", 3000)
		t.eq(values.renderDistance, 3072, "clamped to a step")
		t.eq(changed[1], "renderDistance")
		t.eq(State.presetName(state), "Custom")
		t.ok(State.unsent(state), "to send")
		t.eq(#State.set(state, "renderDistance", 3072), 0, "the same value changes nothing")

		-- Lowering the falloff clamps full detail, which counts as chosen.
		State.set(state, "fullDetail", 4)
		t.eq(values.fullDetail, 4, "within split + 1")
		State.set(state, "fullDetail", 5)
		t.eq(values.fullDetail, 4, "dragged past split + 1: clamped")
		changed = State.set(state, "detailFalloff", 2)
		t.eq(table.concat(changed, ","), "detailFalloff,fullDetail")
		t.eq(values.fullDetail, 3)
		local payload = State.payload(state)
		t.eq(payload.fullDetail, 3)
		t.eq(payload.fov, nil, "only chosen values are saved")

		-- A preset: its values follow it again.
		State.setPreset(state, PlayerSettings.LOW)
		t.eq(values.renderDistance, 512)
		t.eq(State.presetName(state), "Low")
		payload = State.payload(state)
		t.eq(payload.preset, PlayerSettings.LOW)
		t.eq(payload.renderDistance, nil, "follows the preset")

		-- Reset: the current preset's values again.
		State.set(state, "shadows", 1)
		t.eq(State.presetName(state), "Custom")
		State.reset(state)
		t.eq(values.shadows, 0)
		t.eq(State.presetName(state), "Low")

		-- Cycling: toggles flip, choices wrap, the preset button goes round the presets.
		State.cycle(state, "fog")
		t.eq(values.fog, 0)
		State.cycle(state, "fog")
		t.eq(values.fog, 1)
		values.guiScale = 3
		State.cycle(state, "guiScale")
		t.eq(values.guiScale, 0, "Auto after 3")
		State.cycle(state, "preset")
		t.eq(values.preset, PlayerSettings.MEDIUM)
		State.cycle(state, "preset", -1)
		State.cycle(state, "preset", -1)
		t.eq(values.preset, PlayerSettings.ULTRA, "wraps backwards")
		State.cycle(state, "renderDistance", 100)
		t.eq(values.renderDistance, 4096, "sliders clamp")

		-- Defaults: everything back, nothing chosen.
		local revision = state.revision
		State.restoreDefaults(state)
		t.eq(State.presetName(state), "High")
		t.eq(values.fog, PlayerSettings.byKey.fog.default)
		t.eq(next(State.payload(state)), nil)
		t.ok(state.revision > revision, "sent again (the saved profile empties)")
		State.markSent(state)
		t.ok(not State.unsent(state))
	end)

	t.test("settings client: the values table is changed in place (ViewSettings holds it)", function()
		local state = State.new(Profile.Touch, true, 0)
		local values = state.values
		State.receive(state, { preset = PlayerSettings.HIGH })
		t.eq(values.renderDistance, 1024, "High on a phone")
		State.setPreset(state, PlayerSettings.ULTRA)
		State.restoreDefaults(state)
		t.eq(state.values, values, "the same table")
		t.eq(values.renderDistance, 512, "phones' default: Low")
	end)

	t.test("settings client: the saved profile applies, merged under this session's choices", function()
		-- Nothing changed yet: the saved choices apply as they are.
		local state = State.new(Profile.Desktop, false, 0)
		local changed = State.receive(state, { preset = PlayerSettings.LOW, fov = 90 })
		t.eq(state.values.renderDistance, 512)
		t.eq(state.values.fov, 90)
		t.ok(table.find(changed, "renderDistance") and table.find(changed, "fov"), "changed keys")
		t.ok(state.chosen.preset and state.chosen.fov, "chosen")
		t.ok(not State.unsent(state), "nothing new to send")
		t.eq(#State.receive(state, { fov = 30 }), 0, "only once")

		-- Changed before it came: the session wins, the rest of the saved profile still applies.
		state = State.new(Profile.Desktop, false, 0)
		State.set(state, "fov", 100)
		State.receive(state, { fov = 40, masterVolume = 20, renderDistance = 768 })
		t.eq(state.values.fov, 100, "this session's choice")
		t.eq(state.values.masterVolume, 20, "saved, untouched this session")
		t.eq(state.values.renderDistance, 768)
		t.ok(State.unsent(state), "the merge is sent")
		t.eq(State.payload(state).masterVolume, 20)

		-- A preset picked this session drops the saved values presets set.
		state = State.new(Profile.Desktop, false, 0)
		State.setPreset(state, PlayerSettings.ULTRA)
		State.receive(state, { renderDistance = 768, masterVolume = 20 })
		t.eq(state.values.renderDistance, 4096, "Ultra's")
		t.eq(state.values.masterVolume, 20)

		-- Defaults pressed this session: nothing saved applies.
		state = State.new(Profile.Desktop, false, 0)
		State.restoreDefaults(state)
		State.receive(state, { fov = 40 })
		t.eq(state.values.fov, 70)
	end)

	--[[ Pages ]]

	t.test("settings client: every setting is on its page once, the layout fits and closes holes", function()
		local seen: { [string]: string } = {}
		for _, page in Pages.list do
			for _, item in page.items do
				if item.kind == "setting" then
					t.ok(seen[item.id] == nil, `{item.id} on one page`)
					seen[item.id] = page.id
					t.eq(PlayerSettings.entry(item.id).page, page.id, `{item.id}'s page`)
				elseif item.kind == "page" then
					t.ok(Pages.byId[item.id] ~= nil, `page {item.id} exists`)
				end
			end
		end
		for _, entry in PlayerSettings.ENTRIES do
			if entry.kind == "key" then
				-- (Key bindings are rows of the Key Binds list, not page items.)
				t.eq(Pages.byId[entry.page].list, "keys", `{entry.key} is on the Key Binds list`)
			else
				t.ok(seen[entry.key] ~= nil, `{entry.key} is on a page`)
			end
		end
		-- Every page is reachable from the main page, and Done goes back where it came from.
		local reached: { [string]: string } = { main = "main" }
		local queue = { "main" }
		while #queue > 0 do
			local id = table.remove(queue, 1) :: string
			for _, item in Pages.byId[id].items do
				if item.kind == "page" and reached[item.id] == nil then
					reached[item.id] = id
					table.insert(queue, item.id)
				end
			end
		end
		for _, page in Pages.list do
			t.ok(reached[page.id] ~= nil, `{page.id} is reachable`)
			if page.id ~= "main" then
				t.eq(Pages.back(page.id), reached[page.id], `{page.id}'s Done goes back to its parent`)
			end
		end
		t.eq(Pages.back("main"), nil, "the main page's Done closes the menu")
		for _, page in Pages.list do
			local layout = Pages.layout(page)
			local boxes = {}
			for _, placed in layout.widgets do
				t.ok(placed.x >= 0 and placed.x + placed.w <= Pages.WIDTH, `{placed.item.id} within the width`)
				t.ok(
					placed.y >= Pages.TOP and placed.y + placed.h <= layout.statusY,
					`{placed.item.id} above the status`
				)
				for _, other in boxes do
					local apart = placed.x >= other.x + other.w
						or other.x >= placed.x + placed.w
						or placed.y >= other.y + other.h
						or other.y >= placed.y + placed.h
					t.ok(apart, `{placed.item.id} and {other.item.id} overlap`)
				end
				table.insert(boxes, placed)
			end
			local statusEnd = layout.statusY + #page.status * Pages.LINE
			t.ok(statusEnd <= layout.done.y, `{page.id}: status lines above Done`)
			t.ok(layout.done.y + layout.done.h <= Pages.HEIGHT, `{page.id}: Done inside`)
		end
		-- Two columns of 150 with 10 between (Minecraft's), a wide master volume.
		local sounds = Pages.layout(Pages.byId.sounds)
		t.eq(sounds.widgets[1].w, Pages.WIDTH, "master volume is wide")
		t.eq(sounds.widgets[2].x, 0)
		t.eq(sounds.widgets[3].x, 160)
		t.eq(sounds.widgets[3].y, sounds.widgets[2].y)
		-- A hidden setting leaves no hole: without textures, far materials moves up beside fog;
		-- without far materials too (nothing textured, no far meshes), brightness does.
		local function placedIn(hidden: { string }): { [string]: any }
			local layout = Pages.layout(Pages.byId.video, function(item)
				return not table.find(hidden, item.id)
			end)
			local at = {}
			for _, placed in layout.widgets do
				at[placed.item.id] = placed
			end
			return at
		end
		local video = placedIn({ "textures" })
		t.eq(video.farMaterials.y, video.fog.y, "same row")
		t.eq(video.farMaterials.x, 160)
		video = placedIn({ "textures", "farMaterials" })
		t.eq(video.brightness.y, video.fog.y, "same row")
		t.eq(video.brightness.x, 160)
		-- Every Video setting shown: seven rows, within the page.
		video = placedIn({})
		t.eq(video.preferDistance.y, Pages.TOP + 6 * Pages.ROW, "the seventh row")
		-- Reset and Defaults start their own row on the main page.
		local main = Pages.layout(Pages.byId.main)
		local reset
		for _, placed in main.widgets do
			if placed.item.id == "reset" then
				reset = placed
			end
		end
		t.eq(reset.x, 0, "a new row")
	end)

	--[[ The controller and ViewSettings, simulated ]]

	local Config = require(shared.Config)
	local LodTree = require(shared.World.LodTree)
	local Protocol = require(shared.Net.Protocol)

	-- Runs `fn`, then puts back what the client's effects change in the shared Config and LodTree.
	local function restoring(fn: () -> ())
		local foliage, ambient, swap = Config.Render.Foliage, Config.Lighting.CaveAmbient, Config.Render.SwapFrames
		local ok, err = pcall(fn)
		Config.Render.Foliage, Config.Lighting.CaveAmbient, Config.Render.SwapFrames = foliage, ambient, swap
		local lod = Config.Lod
		LodTree.configure(lod.ViewDistance, lod.SplitDistance, lod.SplitDistanceL1, lod.UndergroundSplitDistanceL1)
		LodTree.setFoliageDistance(lod.FoliageDistance)
		if not ok then
			error(err, 0)
		end
	end

	t.test("settings client sim: the saved profile arrives at start; effects run once each", function()
		restoring(function()
			local world = fakeClient(shared, require, 5)
			local Settings = world.Settings
			t.eq(Settings.presetName(), "Medium", "quality 5: Medium")
			Settings.start()
			-- The server answers after 0.3 s with this profile's saved choices.
			local saved = PlayerSettings.encode(Profile.Desktop, { preset = PlayerSettings.ULTRA, fov = 80 })
			local other = PlayerSettings.encode(Profile.Touch, { preset = PlayerSettings.LOW })
			local frames = 0
			local waited = false
			-- (waitForSaved's task.wait runs frames; the message comes in during one.)
			world.frame = (function(frame)
				return function()
					frame()
					frames += 1
					if frames == 18 then
						world.serverSends(Protocol.ServerMessage.Settings, other)
						world.serverSends(Protocol.ServerMessage.Settings, saved)
					end
				end
			end)(world.frame)
			Settings.waitForSaved(1)
			waited = Settings.loaded()
			t.ok(waited, "loaded")
			t.ok(frames >= 18 and frames < 25, `waited until it came ({frames} frames)`)
			t.eq(Settings.get("renderDistance"), 4096, "Ultra")
			t.eq(Settings.get("fov"), 80)
			t.eq(world.ViewSettings.get("renderDistance"), 4096, "ViewSettings reads the same values")

			-- Registered effects run once now; one function under several keys runs once.
			local runs: { [string]: number } = {}
			local function count(name: string)
				return function()
					runs[name] = (runs[name] or 0) + 1
				end
			end
			local restyle = count("restyle")
			Settings.register("shadows", restyle)
			Settings.register("farShadows", restyle)
			Settings.register("textures", restyle)
			Settings.register("camera", count("camera"))
			Settings.register("lod", count("lod"))
			Settings.register("fog", count("fog"))
			t.eq(runs.restyle, 1, "once at registration")
			t.eq(runs.camera, 1)
			-- Shadows and far shadows changed in one frame: one restyle, after the delay.
			Settings.set("shadows", 0)
			Settings.set("farShadows", 0)
			world.frame()
			t.eq(runs.restyle, 1, "costly: waits")
			for _ = 1, 30 do
				world.frame()
			end
			t.eq(runs.restyle, 2, "then once")
			-- The FOV slider: every frame's change applies at the next frame.
			local before = runs.camera
			for value = 81, 90 do
				Settings.set("fov", value)
				Settings.set("fovEffects", value)
				world.frame()
			end
			t.eq(runs.camera - before, 10, "cheap: once each frame")
			t.eq(world.warnings[1], nil, "no warnings")
			-- Textures are offered (the pack has filled textures), Far Materials where far meshes
			-- run (on a computer, by Config).
			t.ok(Settings.shown("textures"), "textures shown")
			t.eq(Settings.shown("farMaterials"), Config.Render.FarMeshes.Enabled, "far materials shown")
			local missing = Settings.missing()
			t.ok(table.find(missing, "skipHidden") and table.find(missing, "caves"), "unregistered slots listed")
		end)
	end)

	t.test("settings client sim: a dragged slider rebuilds once; saves after the delay and on close", function()
		restoring(function()
			local world = fakeClient(shared, require, 0)
			local Settings = world.Settings
			Settings.start()
			world.serverSends(Protocol.ServerMessage.Settings, PlayerSettings.encode(Profile.Desktop, {}))
			local lod, fog = 0, 0
			Settings.register("lod", function()
				lod += 1
			end)
			Settings.register("fog", function()
				fog += 1
			end)
			lod, fog = 0, 0
			-- Dragging render distance from 2048 to 4096 over 0.8 s.
			for step = 1, 8 do
				Settings.set("renderDistance", 2048 + step * 256)
				for _ = 1, 6 do
					world.frame()
				end
			end
			t.eq(lod, 0, "nothing rebuilt while dragging")
			t.eq(fog, 8, "the fog follows")
			t.eq(#world.sent, 0, "not sent yet")
			for _ = 1, 30 do
				world.frame()
			end
			t.eq(lod, 1, "one rebuild, 0.4 s after the last step")
			for _ = 1, 60 do
				world.frame()
			end
			t.eq(#world.sent, 1, "sent 1.5 s after the last change")
			local profile, values = PlayerSettings.decode(world.sent[1].payload)
			t.eq(world.sent[1].kind, Protocol.ClientMessage.SaveSettings)
			t.eq(profile, Profile.Desktop)
			t.eq((values :: any).renderDistance, 4096)
			t.eq((values :: any).fov, nil, "only chosen settings")
			-- The menu closing: everything waiting applies now, the save goes at once.
			Settings.set("plants", 16)
			Settings.flush()
			t.eq(#world.sent, 2, "sent on close")
			local _, closed = PlayerSettings.decode(world.sent[2].payload)
			t.eq((closed :: any).plants, 16)
			Settings.flush()
			t.eq(#world.sent, 2, "nothing new, nothing sent")
		end)
	end)

	t.test("settings client sim: no saved profile in time: defaults, then it applies when it comes", function()
		restoring(function()
			local world = fakeClient(shared, require, 2)
			local Settings = world.Settings
			Settings.start()
			local before = world.clock
			Settings.waitForSaved(1)
			t.ok(world.clock - before >= 1 and world.clock - before < 1.1, "waits at most a second")
			t.ok(not Settings.loaded())
			t.eq(Settings.presetName(), "Low", "quality 2")
			local fovs = {}
			Settings.register("camera", function(values)
				table.insert(fovs, values.fov)
			end)
			world.serverSends(Protocol.ServerMessage.Settings, PlayerSettings.encode(Profile.Desktop, { fov = 100 }))
			world.frame()
			t.eq(fovs[#fovs], 100, "applied when it came")
			t.ok(Settings.loaded())
		end)
	end)

	t.test("settings client sim: ViewSettings configures LodTree, plants, fog and lighting", function()
		restoring(function()
			local world = fakeClient(shared, require, 0)
			local Settings, ViewSettings = world.Settings, world.ViewSettings
			ViewSettings.apply()
			t.eq(LodTree.viewDistance(), Config.Lod.ViewDistance, "High: Config's view")
			t.eq(LodTree.splitDistanceL1(true), Config.Lod.UndergroundSplitDistanceL1, "today's cave view")
			t.eq(world.lighting.FogEnd, Config.Lod.ViewDistance * Config.BlockSize, "fog at the view")
			t.eq(world.lighting.FogStart, world.lighting.FogEnd * 0.55)
			t.eq(world.lighting.PrioritizeLightingQuality, false, "prefer distance")

			Settings.set("renderDistance", 1024)
			Settings.set("detailFalloff", 2)
			Settings.set("caveView", 176)
			Settings.set("plants", 0)
			ViewSettings.applyLod()
			t.eq(LodTree.viewDistance(), 1024)
			t.eq(LodTree.splitDistanceL1(false), 3, "full detail clamped to split + 1")
			t.eq(LodTree.splitDistanceL1(true), 3, "underground too")
			t.eq(Config.Render.Foliage, false, "no plants")
			t.eq(LodTree.drawsFoliage(0, 0, 0, 0, 0, true), false, "none drawn, not even kept ones")
			Settings.set("plants", 24)
			ViewSettings.applyLod()
			t.eq(Config.Render.Foliage, true)
			t.eq(LodTree.foliageDistance(), 24)

			ViewSettings.applyFog()
			t.eq(world.lighting.FogEnd, 1024 * Config.BlockSize, "the fog follows the view")
			Settings.set("fog", 0)
			ViewSettings.applyFog()
			t.eq(world.lighting.FogEnd, 100000, "the place's own fog back")
			t.eq(world.lighting.FogStart, 0)
			t.ok(not ViewSettings.usesFog())

			Settings.set("brightness", 100)
			Settings.set("preferDistance", 0)
			ViewSettings.applyLighting()
			t.ok(Config.Lighting.CaveAmbient[1] >= 90, "Bright")
			t.eq(world.lighting.PrioritizeLightingQuality, true, "prefer lighting")
			Settings.set("lichenLights", 48)
			t.eq(ViewSettings.lichenLightDistance(), 48, "read live")
			local tunnels, caverns = ViewSettings.revealRadii()
			t.eq(caverns, 176)
			t.eq(tunnels, Config.Caves.RevealRadius)
		end)
	end)

	t.test("settings client sim: the Atmosphere is the view's haze; short fogs take it out of Lighting", function()
		restoring(function()
			-- Without an Atmosphere the old view fog stays (FogEnd at the view, FogStart 55%).
			local plain = fakeClient(shared, require, 0)
			plain.ViewSettings.applyFog()
			t.eq(plain.ViewSettings.fogMode(), "classic")
			t.eq(plain.lighting.FogEnd, Config.Lod.ViewDistance * Config.BlockSize)
			plain.ViewSettings.setWeatherFog(0.5)
			t.eq(plain.lighting.FogEnd, Config.Lod.ViewDistance * Config.BlockSize * 0.5, "nearer in rain")

			-- With one: adopted, left in Lighting, the old fog the place's own.
			local world = fakeClient(shared, require, 0, true)
			local Settings, ViewSettings = world.Settings, world.ViewSettings
			local atmosphere = world.atmosphere
			ViewSettings.applyFog()
			t.eq(ViewSettings.atmosphere(), atmosphere, "the place's Atmosphere")
			t.eq(ViewSettings.fogMode(), "atmosphere")
			t.eq(atmosphere.Parent, world.lighting, "in Lighting")
			t.eq(world.lighting.FogEnd, 100000, "the old fog: the place's own")
			t.eq(world.lighting.FogStart, 0)
			t.ok(ViewSettings.usesFog(), "the haze is on")
			t.ok(not ViewSettings.placeKeepsFog(), "IceVoxel drives it: the Fog setting works")
			-- The weather's factor is read by the lighting's update, not written as fog.
			ViewSettings.setWeatherFog(0.6)
			t.eq(ViewSettings.weatherFog(), 0.6)
			t.eq(world.lighting.FogEnd, 100000)

			-- Lava: Minecraft's 0.25 .. 1 block with the Atmosphere out, in the same call.
			local block = Config.BlockSize
			ViewSettings.setFluidFog(0.25 * block, 1 * block)
			t.eq(ViewSettings.fogMode(), "fluid")
			t.eq(atmosphere.Parent, nil, "out of Lighting")
			t.eq(world.lighting.FogStart, 0.25 * block)
			t.eq(world.lighting.FogEnd, 1 * block)
			-- Blindness (5 blocks) is further than the lava's: the lava's stays.
			ViewSettings.setEffectFog(1.25 * block, 5 * block)
			t.eq(ViewSettings.fogMode(), "fluid")
			t.eq(world.lighting.FogEnd, 1 * block)
			-- Out of the lava, still blind: Blindness' fog, the Atmosphere still out.
			ViewSettings.setFluidFog(nil, nil)
			t.eq(ViewSettings.fogMode(), "effect")
			t.eq(atmosphere.Parent, nil)
			t.eq(world.lighting.FogEnd, 5 * block)
			t.eq(world.lighting.FogStart, 1.25 * block)
			-- Blindness over: the Atmosphere back, the old fog the place's again.
			ViewSettings.setEffectFog(nil, nil)
			t.eq(ViewSettings.fogMode(), "atmosphere")
			t.eq(atmosphere.Parent, world.lighting, "back in Lighting")
			t.eq(world.lighting.FogEnd, 100000)
			t.eq(world.lighting.FogStart, 0)

			-- The Fog setting off: the Atmosphere stays (density 0), the old fog the place's.
			Settings.set("fog", 0)
			ViewSettings.applyFog()
			t.ok(not ViewSettings.usesFog())
			t.eq(ViewSettings.fogMode(), "atmosphere")
			t.eq(atmosphere.Parent, world.lighting)
			-- Water while it is off: the fluid's fog shows all the same.
			ViewSettings.setFluidFog(0, 24 * block)
			t.eq(atmosphere.Parent, nil)
			t.eq(world.lighting.FogEnd, 24 * block)
			ViewSettings.setFluidFog(nil, nil)
			t.eq(atmosphere.Parent, world.lighting)
			t.eq(PlayerSettings.text("fog", 0), "Fog: OFF")
			t.eq(PlayerSettings.text("fog", 1), "Fog: Atmosphere")

			-- A place that keeps its own lighting keeps its Atmosphere: the setting can't switch it.
			local enabled = Config.Lighting.Enabled
			Config.Lighting.Enabled = false
			local keeps, none = ViewSettings.placeKeepsFog(), plain.ViewSettings.placeKeepsFog()
			Config.Lighting.Enabled = enabled
			t.ok(keeps, "the place's own")
			t.ok(not none, "none to keep")

			-- One made for a place without (LightingController.start): the haze from then on.
			local made = { Name = "IceVoxelAtmosphere", Parent = plain.lighting }
			plain.ViewSettings.setAtmosphere(made)
			t.eq(plain.ViewSettings.fogMode(), "atmosphere")
			t.eq(plain.ViewSettings.atmosphere(), made)
			t.eq(plain.lighting.FogEnd, 100000, "the old view fog gone")

			-- Lighting.Enabled false with the project's own Atmosphere (marked): IceVoxel drives
			-- none, so it goes, and the old view fog follows the view and the Fog setting as it
			-- did before the project had one. A place's own (unmarked) one stays, as above.
			Config.Lighting.Enabled = false
			local ok, err = pcall(function()
				local project = fakeClient(shared, require, 0, true)
				local marked = project.atmosphere
				function marked.GetAttribute(_, name: string): any
					return if name == project.ViewSettings.PROJECT_ATTRIBUTE then true else nil
				end
				project.ViewSettings.applyFog()
				t.eq(marked.Parent, nil, "the project's Atmosphere out of Lighting")
				t.eq(project.ViewSettings.atmosphere(), nil)
				t.eq(project.ViewSettings.fogMode(), "classic")
				t.eq(project.lighting.FogEnd, Config.Lod.ViewDistance * Config.BlockSize, "the view's fog")
				t.ok(not project.ViewSettings.placeKeepsFog(), "the Fog setting switches it")
				project.Settings.set("fog", 0)
				project.ViewSettings.applyFog()
				t.eq(project.ViewSettings.fogMode(), "none", "off: the place's own fog")
			end)
			Config.Lighting.Enabled = enabled
			assert(ok, err)
		end)
	end)

	t.test("settings client sim: the Caves setting reaches ViewSettings; its tooltip fits by its button", function()
		restoring(function()
			local world = fakeClient(shared, require, 0)
			local Settings, ViewSettings = world.Settings, world.ViewSettings
			t.eq(ViewSettings.alwaysCaves(), Config.Caves.AlwaysShow == true, "Config's default")
			Settings.set("alwaysCaves", 1)
			t.ok(ViewSettings.alwaysCaves(), "read live by the streamer's applyView")
			Settings.set("alwaysCaves", 0)
			t.ok(not ViewSettings.alwaysCaves())
		end)
		-- On the Video page; its tooltip goes below the button, or above it near the bottom.
		local video = Pages.layout(Pages.byId.video)
		local caves
		for _, placed in video.widgets do
			if placed.item.id == "alwaysCaves" then
				caves = placed
			end
		end
		t.ok(caves ~= nil, "on the Video page")
		local w, h = Pages.TOOLTIP_W + 2 * Pages.TOOLTIP_PAD, 60
		local x, y = Pages.tooltipAt(caves, w, h)
		t.ok(x >= 0 and x + w <= Pages.WIDTH, "within the panel's width")
		t.ok(y + h <= caves.y or y >= caves.y + caves.h, "never over its button")
		local top = { item = caves.item, x = 0, y = Pages.TOP, w = 150, h = 20 }
		local tx, ty = Pages.tooltipAt(top, w, h)
		t.eq(ty, Pages.TOP + 20 + Pages.TOOLTIP_GAP, "below a button with room under it")
		t.eq(tx, 0)
		local bottom = { item = caves.item, x = 160, y = Pages.HEIGHT - 40, w = 150, h = 20 }
		local bx, by = Pages.tooltipAt(bottom, w, h)
		t.eq(by, Pages.HEIGHT - 40 - Pages.TOOLTIP_GAP - h, "above one near the bottom")
		t.eq(bx, Pages.WIDTH - w, "moved left to end inside the panel")
	end)

	t.test("settings client: Minimap off on a touch screen leaves a Map button to the world map", function()
		for _, touch in { true, false } do
			local ui = fakeMinimap(shared, require, touch)
			local holder, button = ui.named("Minimap"), ui.named("MapButton")
			t.ok(holder and button, "both made")
			t.eq(button.Parent, ui.gui, "beside the minimap, not in it")
			ui.minimap.setVisible(true)
			t.eq(holder.Visible, true)
			t.eq(button.Visible, false, "no button while the minimap shows")
			ui.minimap.setVisible(false)
			t.eq(holder.Visible, false, "hidden")
			-- (Tapping the minimap is the only way to the world map on a touch screen; M is a key.)
			t.eq(button.Visible, touch, if touch then "touch: the button takes its place" else "keyboard: M")
			button.Activated.fire()
			t.eq(ui.opened, 1, "opens the world map")
			ui.minimap.setVisible(true)
			t.eq(button.Visible, false, "gone again")
		end
	end)
end

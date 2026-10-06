--[[
	The server's settings store (Players/SettingsStore) in a simulation: the real module with a
	fake DataStore (latency, failures), Players, BindToClose and a cooperative task scheduler
	(task.wait / task.spawn yield and resume against a shared frame clock), connected by a fake
	remote to the real client controller (Settings/init with Rendering/ViewSettings).

	Covered: loading on join and sending each profile, saving once on leave and only when
	something changed, a failed load saving nothing, untrusted payloads, a profile the client sent
	before loading finished (Defaults or a preset picked then must not bring saved choices back;
	saved choices the player did not touch must stay), and BindToClose waiting for saves.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

-- A module's source with `globals` declared as locals taken from the chunk's arguments.
local function withHeader(source: string, globals: string): string
	local lines = string.split(source, "\n")
	local i = 1
	while lines[i] and string.sub(lines[i], 1, 3) == "--!" do
		i += 1
	end
	lines[i] = `local {globals} = ...; ` .. (lines[i] or "")
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
		handlers = handlers,
	}
end

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = deepCopy(v)
	end
	return out
end

--[[
	A server running SettingsStore, and clients.

	  world.step()           one 1/60 s frame: due server threads resume, then the client's Heartbeat
	  world.run(seconds)     steps that long
	  world.join(userId)     a player joins (the server's PlayerAdded runs in its own thread)
	  world.newClient(opts)  the joined player's client (Settings/init): { Settings }
	  world.send(p, buffer)  a SaveSettings message from player p, as the server gets it
	  world.leave(p)         PlayerRemoving
	  world.close()          BindToClose, run until it returns (false if it never did in 40 s)
	  world.store            { data = { [key] = record }, gets, sets, getLatency, setLatency,
	                           getFails, setFails }
	  world.received(p)      the Settings messages player p was sent, decoded: { [profile] = values }
]]
local function newWorld(shared: any, sharedRequire: (any) -> any): any
	local world: any = { clock = 100, warnings = {}, toClient = {}, toServer = {} }
	local waiting: { { co: thread, at: number } } = {}

	local fakeTask = {}
	function fakeTask.wait(dt: number?): number
		table.insert(waiting, { co = coroutine.running(), at = world.clock + (dt or 0) })
		return coroutine.yield()
	end
	function fakeTask.spawn(fn: any, ...: any): thread
		local co = if type(fn) == "thread" then fn else coroutine.create(fn)
		local ok, err = coroutine.resume(co, ...)
		if not ok then
			error(debug.traceback(co, tostring(err)), 0)
		end
		return co
	end
	local fakeOs = {
		clock = function(): number
			return world.clock
		end,
	}
	local function warn(...)
		table.insert(world.warnings, table.concat({ ... }, " "))
	end
	local PlayerSettings = sharedRequire(shared.PlayerSettings)
	local Protocol = sharedRequire(shared.Net.Protocol)

	--[[ DataStore ]]
	local store = { data = {}, gets = 0, sets = 0, getLatency = 0.2, setLatency = 0.1, getFails = 0, setFails = 0 }
	world.store = store
	local dataStore = {
		GetAsync = function(_, key: string)
			store.gets += 1
			fakeTask.wait(store.getLatency)
			if store.getFails > 0 then
				store.getFails -= 1
				error("DataStore request failed (simulated)")
			end
			return deepCopy(store.data[key])
		end,
		SetAsync = function(_, key: string, value: any, _userIds: any)
			store.sets += 1
			fakeTask.wait(store.setLatency)
			if store.setFails > 0 then
				store.setFails -= 1
				error("DataStore request failed (simulated)")
			end
			store.data[key] = deepCopy(value)
		end,
	}

	--[[ Server ]]
	local serverHandlers: { [number]: (any, buffer) -> () } = {}
	local clientHandlers: { [number]: (buffer) -> () } = {}
	local clientBacklog: { [number]: { buffer } } = {}
	local playerAdded, playerRemoving = fakeSignal(), fakeSignal()
	local players: { any } = {}
	local closeHandlers = {}
	local services: { [string]: any } = {
		DataStoreService = {
			GetDataStore = function()
				return dataStore
			end,
		},
		Players = {
			PlayerAdded = playerAdded,
			PlayerRemoving = playerRemoving,
			GetPlayers = function()
				return table.clone(players)
			end,
		},
		ReplicatedStorage = {
			WaitForChild = function(_, name: string)
				assert(name == "IceVoxel")
				return shared
			end,
		},
	}
	local serverGame = {
		GetService = function(_, name: string)
			return assert(services[name], `no fake server service {name}`)
		end,
		BindToClose = function(_, fn)
			table.insert(closeHandlers, fn)
		end,
	}
	local net = {
		on = function(kind: number, handler)
			serverHandlers[kind] = handler
		end,
		send = function(player: any, kind: number, payload: buffer)
			table.insert(world.toClient, { player = player, kind = kind, payload = payload })
			if player ~= world.clientPlayer then
				return
			end
			local handler = clientHandlers[kind]
			if handler then
				handler(payload)
			else
				clientBacklog[kind] = clientBacklog[kind] or {}
				table.insert(clientBacklog[kind], payload)
			end
		end,
	}
	local serverNet = {}
	local storeScript = { Parent = { Parent = { Network = { ServerNet = serverNet } } } }
	local function serverRequire(n: any): any
		return if n == serverNet then {} else sharedRequire(n)
	end
	local chunk = luau.load(
		withHeader(fs.readFile("src/server/Players/SettingsStore.luau"), "script, require, game, task, warn, os"),
		{ debugName = "SettingsStore" }
	)
	chunk(storeScript, serverRequire, serverGame, fakeTask, warn, fakeOs).start(net)

	--[[ Frames ]]
	local heartbeat = fakeSignal()
	function world.step()
		world.clock += 1 / 60
		local due = {}
		local i = 1
		while i <= #waiting do
			if waiting[i].at <= world.clock then
				table.insert(due, table.remove(waiting, i))
			else
				i += 1
			end
		end
		for _, entry in due do
			local ok, err = coroutine.resume(entry.co, 1 / 60)
			if not ok then
				error(debug.traceback(entry.co, tostring(err)), 0)
			end
		end
		heartbeat.fire(1 / 60)
	end
	function world.run(seconds: number)
		for _ = 1, math.floor(seconds * 60 + 0.5) do
			world.step()
		end
	end

	--[[ Players ]]
	function world.join(userId: number?): any
		local player = { Name = `Tester{userId or 4242}`, UserId = userId or 4242 }
		table.insert(players, player)
		for _, fn in playerAdded.handlers do
			fakeTask.spawn(fn, player)
		end
		return player
	end
	function world.leave(player: any)
		local i = table.find(players, player)
		if i then
			table.remove(players, i)
		end
		for _, fn in playerRemoving.handlers do
			fakeTask.spawn(fn, player)
		end
	end
	function world.send(player: any, payload: buffer)
		table.insert(world.toServer, { player = player, payload = payload, at = world.clock })
		serverHandlers[Protocol.ClientMessage.SaveSettings](player, payload)
	end
	function world.close(): boolean
		local done = false
		fakeTask.spawn(function()
			for _, fn in closeHandlers do
				fn()
			end
			done = true
		end)
		local frames = 0
		while not done and frames < 60 * 40 do
			world.step()
			frames += 1
		end
		return done
	end
	function world.received(player: any): { [number]: any }
		local out = {}
		for _, message in world.toClient do
			if message.player == player then
				local profile, values = PlayerSettings.decode(message.payload)
				out[profile :: number] = values
			end
		end
		return out
	end

	--[[ The client (Settings/init and ViewSettings with fake services) of `player` ]]
	function world.newClient(player: any, opts: any?): any
		local options = opts or {}
		world.clientPlayer = player
		table.clear(clientHandlers)
		table.clear(clientBacklog)
		local clientServices: { [string]: any } = {
			ReplicatedStorage = services.ReplicatedStorage,
			RunService = { Heartbeat = heartbeat },
			UserInputService = { TouchEnabled = options.touch == true, KeyboardEnabled = options.touch ~= true },
			GuiService = {
				IsTenFootInterface = function()
					return false
				end,
			},
			Lighting = {
				FogEnd = 100000,
				FogStart = 0,
				FindFirstChildOfClass = function()
					return nil
				end,
			},
		}
		local game = {
			GetService = function(_, name: string)
				return assert(clientServices[name], `no fake client service {name}`)
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
					return { SavedQualityLevel = { Value = options.quality or 0 } }
				end,
			}
		end
		local clientNet = {
			on = function(kind: number, handler)
				clientHandlers[kind] = handler
				local queued = clientBacklog[kind]
				clientBacklog[kind] = nil
				for _, payload in queued or {} do
					handler(payload)
				end
			end,
			send = function(_kind: number, payload: buffer)
				world.send(player, payload)
			end,
		}
		-- The client's start-up thread waits by running frames.
		local clientTask = {
			wait = function(): number
				world.step()
				return 1 / 60
			end,
		}
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
		local GLOBALS = "script, require, game, workspace, Instance, UserSettings, os, task, warn"
		local function req(n: any): any
			if type(n) ~= "table" or not rawget(n, "__fake") then
				return sharedRequire(n)
			end
			if n.path == "src/client/Net/ClientNet" then
				return clientNet
			end
			if cache[n] ~= nil then
				return cache[n]
			end
			local file = if fs.isDir(n.path) then `{n.path}/init.luau` else `{n.path}.luau`
			local load = luau.load(withHeader(fs.readFile(file), GLOBALS), { debugName = file })
			local result = load(n, req, game, {}, Instance, UserSettings, fakeOs, clientTask, warn)
			cache[n] = result
			return result
		end
		return { Settings = req(node("src/client", nil).Settings) }
	end

	return world
end

return function(t, shared, require, _server, _client)
	local PlayerSettings = require(shared.PlayerSettings)
	local Profile = PlayerSettings.Profile

	local KEY = "player_4242"

	local function saved(world: any, profile: number): any
		local record = world.store.data[KEY]
		return if record then PlayerSettings.fromRecord(record)[profile] else nil
	end

	local function count(values: any): number
		local n = 0
		for _ in values or {} do
			n += 1
		end
		return n
	end

	--[[
		A session with the real client: join, start, wait for the saved settings at most LoadWait,
		`actions(Settings)`, 12 s of play, leave, 5 s.
	]]
	local function session(world: any, actions: (any) -> ()): any
		local player = world.join()
		local Settings = world.newClient(player).Settings
		Settings.start()
		Settings.waitForSaved(1)
		actions(Settings)
		world.run(12)
		world.leave(player)
		world.run(5)
		return Settings
	end

	-- The next session's client, on the desktop, with a quick DataStore.
	local function nextSession(world: any): any
		world.store.getFails = 0
		return session(world, function() end)
	end

	t.test("settings store: loads on join and sends each profile once; nothing changed, nothing saved", function()
		local world = newWorld(shared, require)
		world.store.data[KEY] = PlayerSettings.toRecord({
			[Profile.Desktop] = { fov = 90 },
			[Profile.Touch] = { preset = PlayerSettings.LOW },
		})
		local player = world.join()
		world.run(1)
		t.eq(world.store.gets, 1, "one GetAsync")
		t.eq(#world.toClient, 3, "one Settings message per profile")
		local got = world.received(player)
		t.eq(got[Profile.Desktop].fov, 90)
		t.eq(got[Profile.Touch].preset, PlayerSettings.LOW)
		t.eq(count(got[Profile.Console]), 0, "nothing saved: count 0")
		world.leave(player)
		world.run(2)
		t.eq(world.store.sets, 0, "nothing changed: no SetAsync")
		t.eq(world.warnings[1], nil)
	end)

	t.test("settings store: the newest profile is saved once on leave; the other profiles stay", function()
		local world = newWorld(shared, require)
		world.store.data[KEY] = PlayerSettings.toRecord({
			[Profile.Desktop] = { fov = 90 },
			[Profile.Touch] = { preset = PlayerSettings.LOW },
		})
		local player = world.join()
		world.run(1)
		world.send(player, PlayerSettings.encode(Profile.Desktop, { fov = 100, renderDistance = 3072 }))
		world.send(player, PlayerSettings.encode(Profile.Desktop, { fov = 101 }))
		world.run(1)
		t.eq(world.store.sets, 0, "kept until the player leaves")
		world.leave(player)
		world.run(2)
		t.eq(world.store.sets, 1, "one SetAsync")
		local desktop = saved(world, Profile.Desktop)
		t.eq(desktop.fov, 101, "the newest, whole")
		t.eq(desktop.renderDistance, nil, "not merged with the older one")
		t.eq(saved(world, Profile.Touch).preset, PlayerSettings.LOW, "the touch profile kept")
		-- Another session that changes nothing saves nothing.
		local again = world.join()
		world.run(1)
		world.leave(again)
		world.run(2)
		t.eq(world.store.sets, 1, "still one")
	end)

	t.test("settings store: untrusted payloads: malformed ignored, unknown ids and NaN dropped, clamped", function()
		local world = newWorld(shared, require)
		local player = world.join()
		world.run(1)
		local function raw(version: number, profile: number, entries: { { number } }, extra: number?): buffer
			local b = buffer.create(3 + #entries * 5 + (extra or 0))
			buffer.writeu8(b, 0, version)
			buffer.writeu8(b, 1, profile)
			buffer.writeu8(b, 2, #entries)
			for i, pair in entries do
				buffer.writeu8(b, 3 + (i - 1) * 5, pair[1])
				buffer.writef32(b, 4 + (i - 1) * 5, pair[2])
			end
			return b
		end
		local fov = PlayerSettings.entry("fov")
		local view = PlayerSettings.entry("renderDistance")
		local volume = PlayerSettings.entry("masterVolume")
		world.send(
			player,
			raw(1, Profile.Touch, { { fov.id, 1000 }, { 250, 5 }, { view.id, 1e9 }, { volume.id, 0 / 0 } })
		)
		-- Malformed: another version, a profile out of range, a length that does not match.
		world.send(player, raw(2, Profile.Touch, { { fov.id, 50 } }))
		world.send(player, raw(1, 9, { { fov.id, 50 } }))
		world.send(player, raw(1, Profile.Touch, { { fov.id, 50 } }, 1))
		world.send(player, buffer.create(2))
		world.leave(player)
		world.run(2)
		local touch = saved(world, Profile.Touch)
		t.eq(touch.fov, fov.max, "clamped to the range")
		t.eq(touch.renderDistance, PlayerSettings.maxOf(view, true), "a touch profile to the phone limit")
		t.eq(count(touch), 2, "unknown ids and NaN dropped")
		t.eq(saved(world, Profile.Desktop), nil, "nothing else")
	end)

	t.test("settings store: a load that keeps failing saves nothing this session", function()
		local world = newWorld(shared, require)
		world.store.data[KEY] = PlayerSettings.toRecord({ [Profile.Desktop] = { fov = 90 } })
		world.store.getFails = 3
		local player = world.join()
		world.run(3)
		t.eq(#world.toClient, 0, "nothing sent while retrying")
		world.run(5)
		t.eq(world.store.gets, 3, "three attempts")
		t.eq(#world.toClient, 3, "then the (empty) profiles, so the client stops waiting")
		t.eq(count(world.received(player)[Profile.Desktop]), 0)
		world.send(player, PlayerSettings.encode(Profile.Desktop, { fov = 30 }))
		world.leave(player)
		world.run(2)
		t.eq(world.store.sets, 0, "never overwrites what it could not read")
		t.eq(saved(world, Profile.Desktop).fov, 90)
		local sessionOnly = false
		for _, line in world.warnings do
			sessionOnly = sessionOnly or string.find(line, "session-only", 1, true) ~= nil
		end
		t.ok(sessionOnly, "warned")
		-- A load that fails once retries, and then saves as usual.
		world.store.getFails = 1
		local again = world.join()
		world.run(3)
		t.eq(world.store.gets, 5, "retried")
		world.send(again, PlayerSettings.encode(Profile.Desktop, { fov = 30 }))
		world.leave(again)
		world.run(2)
		t.eq(saved(world, Profile.Desktop).fov, 30, "saved")
	end)

	t.test(
		"settings store: a profile sent before loading finished replaces it; the client gets the saved one",
		function()
			local world = newWorld(shared, require)
			world.store.data[KEY] = PlayerSettings.toRecord({
				[Profile.Desktop] = { preset = PlayerSettings.LOW, fov = 90 },
			})
			world.store.getLatency = 1
			local player = world.join()
			world.send(player, PlayerSettings.encode(Profile.Desktop, { shadows = 0 }))
			world.run(2)
			local got = world.received(player)[Profile.Desktop]
			t.eq(got.preset, PlayerSettings.LOW, "the saved profile, to merge under the early choices")
			t.eq(got.fov, 90)
			t.eq(got.shadows, nil)
			-- (A client that never sends the merge: what it sent stands, whole.)
			world.leave(player)
			world.run(2)
			local desktop = saved(world, Profile.Desktop)
			t.eq(desktop.shadows, 0)
			t.eq(desktop.preset, nil, "no saved choice comes back that the client did not send")
		end
	)

	-- The finding's scenarios: the first GetAsync fails, so loading takes over 2 s and the client's
	-- LoadWait (1 s) runs out first; the player changes settings in the menu meanwhile.

	t.test("settings store + client: Defaults pressed before the saved profile came is kept", function()
		local world = newWorld(shared, require)
		world.store.data[KEY] = PlayerSettings.toRecord({
			[Profile.Desktop] = { preset = PlayerSettings.LOW, fov = 90 },
		})
		world.store.getFails = 1
		world.store.getLatency = 0.3
		local Settings = session(world, function(Settings)
			t.ok(not Settings.loaded(), "not loaded yet")
			world.run(0.5)
			Settings.restoreDefaults()
			Settings.flush()
		end)
		t.eq(Settings.presetName(), "High", "this session: the device's default")
		t.eq(Settings.get("fov"), 70)
		t.eq(count(saved(world, Profile.Desktop)), 0, "nothing chosen is saved")
		local next = nextSession(world)
		t.eq(next.presetName(), "High", "the next session starts on the default")
		t.eq(next.get("fov"), 70)
	end)

	t.test("settings store + client: a preset picked before the saved profile came drops its saved view", function()
		local world = newWorld(shared, require)
		world.store.data[KEY] = PlayerSettings.toRecord({
			[Profile.Desktop] = { preset = PlayerSettings.HIGH, renderDistance = 4096 },
		})
		world.store.getFails = 1
		world.store.getLatency = 0.3
		local Settings = session(world, function(Settings)
			world.run(0.5)
			Settings.setPreset(PlayerSettings.LOW)
			Settings.flush()
		end)
		t.eq(Settings.presetName(), "Low")
		local desktop = saved(world, Profile.Desktop)
		t.eq(desktop.preset, PlayerSettings.LOW)
		t.eq(desktop.renderDistance, nil, "Low's view follows the preset")
		local next = nextSession(world)
		t.eq(next.presetName(), "Low", "not Custom")
		t.eq(next.get("renderDistance"), 512)
	end)

	t.test("settings store + client: early choices and saved ones not touched are both kept", function()
		local world = newWorld(shared, require)
		-- Saved choices equal to the values this device starts on (High: a 2048 view, FOV 70), so
		-- the saved profile arriving changes no value.
		world.store.data[KEY] = PlayerSettings.toRecord({
			[Profile.Desktop] = { renderDistance = 2048, fov = 70 },
		})
		world.store.getFails = 1
		world.store.getLatency = 0.3
		local player = world.join()
		local Settings = world.newClient(player).Settings
		Settings.start()
		Settings.waitForSaved(1)
		Settings.set("waila", 0)
		Settings.flush()
		local sent = #world.toServer
		while not Settings.loaded() do
			world.step()
		end
		t.eq(#world.toServer, sent + 1, "the merge goes back as it arrives, though no value changed")
		world.run(5)
		world.leave(player)
		world.run(2)
		local desktop = saved(world, Profile.Desktop)
		t.eq(desktop.waila, 0, "the early choice")
		t.eq(desktop.renderDistance, 2048, "saved, untouched")
		t.eq(desktop.fov, 70, "saved, untouched")
		t.eq(world.store.sets, 1, "one SetAsync")
	end)

	t.test("settings store + client: control: the same Defaults after loading", function()
		local world = newWorld(shared, require)
		world.store.data[KEY] = PlayerSettings.toRecord({
			[Profile.Desktop] = { preset = PlayerSettings.LOW, fov = 90 },
		})
		local Settings = session(world, function(Settings)
			t.ok(Settings.loaded(), "loaded within LoadWait")
			t.eq(Settings.presetName(), "Low")
			Settings.restoreDefaults()
			Settings.flush()
		end)
		t.eq(Settings.presetName(), "High")
		t.eq(count(saved(world, Profile.Desktop)), 0)
		t.eq(nextSession(world).presetName(), "High")
	end)

	t.test("settings store: BindToClose waits for saves in flight and saves who is still playing", function()
		local world = newWorld(shared, require)
		world.store.setLatency = 3
		local left = world.join(1)
		local staying = world.join(2)
		world.run(1)
		world.send(left, PlayerSettings.encode(Profile.Desktop, { fov = 31 }))
		world.send(staying, PlayerSettings.encode(Profile.Console, { fov = 32 }))
		world.leave(left)
		world.run(0.5)
		t.eq(world.store.sets, 1, "the leaver's save is in flight")
		local started = world.clock
		t.ok(world.close(), "returns")
		t.ok(world.clock - started >= 2.4, "waited for the save in flight")
		t.eq(world.store.sets, 2, "one each")
		t.eq(PlayerSettings.fromRecord(world.store.data.player_1)[Profile.Desktop].fov, 31)
		t.eq(PlayerSettings.fromRecord(world.store.data.player_2)[Profile.Console].fov, 32)
	end)

	t.test("settings store: BindToClose gives up after its wait when saving keeps failing", function()
		local world = newWorld(shared, require)
		world.store.data[KEY] = PlayerSettings.toRecord({ [Profile.Desktop] = { fov = 90 } })
		local player = world.join()
		world.run(1)
		world.send(player, PlayerSettings.encode(Profile.Desktop, { fov = 40 }))
		world.store.setFails = math.huge
		local started = world.clock
		t.ok(world.close(), "returns")
		local waited = world.clock - started
		t.ok(waited > 25 and waited < 30, `within its 25 s ({waited} s)`)
		t.eq(saved(world, Profile.Desktop).fov, 90, "the old record untouched")
		t.ok(#world.warnings > 0, "warned")
	end)
end

--[[
	Players/Radiation's glue under fake Roblox services (Players, RunService, a player, a character
	with a humanoid), with stubbed Effects, Inventories, PlayerPositions and WorldServer and the
	real RadiationRules and Shared modules: death clears the dose before any save reads it, a dose
	restored onto a dead body waits for the next one, and nothing is published with radiation off.
	task.spawn runs at once; task.defer is queued and flushed by hand (as Roblox runs it after the
	current handlers).
]]
local fs = require("@lune/fs")
local luau = require("@lune/luau")

return function(t, shared, require, server)
	local function signal()
		local handlers = {}
		return {
			Connect = function(_self, fn)
				table.insert(handlers, fn)
				return { Disconnect = function() end }
			end,
			Fire = function(_self, ...)
				for _, fn in handlers do
					fn(...)
				end
			end,
		}
	end
	local deferred = {}
	local fakeTask = {
		spawn = function(fn, ...)
			fn(...)
		end,
		defer = function(fn, ...)
			table.insert(deferred, { fn, table.pack(...) })
		end,
	}
	local function flush()
		local list = deferred
		deferred = {}
		for _, item in list do
			item[1](table.unpack(item[2], 1, item[2].n))
		end
	end

	-- Fake Players / RunService.
	local playersList = {}
	local Players = {
		PlayerAdded = signal(),
		PlayerRemoving = signal(),
		GetPlayers = function()
			return table.clone(playersList)
		end,
	}
	local Heartbeat = signal()
	local RunService = { Heartbeat = Heartbeat }
	local ReplicatedStorage = {
		WaitForChild = function(_self, name)
			assert(name == "IceVoxel")
			return shared
		end,
	}
	local game = {
		GetService = function(_self, name)
			if name == "Players" then
				return Players
			elseif name == "RunService" then
				return RunService
			elseif name == "ReplicatedStorage" then
				return ReplicatedStorage
			end
			error("no service " .. name)
		end,
	}

	-- Stubs.
	local feet: { [any]: { number } } = {}
	local windows: { [any]: any } = {}
	local effects: { [any]: { [number]: { amp: number, ticks: number } } } = {}
	local Stubs = {
		Effects = {
			amplifier = function(player, effect)
				local e = effects[player] and effects[player][effect]
				return if e then e.amp else nil
			end,
			ticks = function(player, effect)
				local e = effects[player] and effects[player][effect]
				return if e then e.ticks else 0
			end,
			give = function(player, effect, ticks, amp)
				effects[player] = effects[player] or {}
				effects[player][effect] = { amp = amp, ticks = ticks }
			end,
		},
		Inventories = {
			get = function(player)
				return windows[player]
			end,
		},
		PlayerPositions = {
			feet = function(player)
				local f = feet[player]
				if f then
					return f[1], f[2], f[3]
				end
				return nil, 0, 0
			end,
		},
		WorldServer = {},
	}
	local players = {
		Effects = { __stub = "Effects" },
		Inventories = { __stub = "Inventories" },
		PlayerPositions = { __stub = "PlayerPositions" },
		RadiationRules = server.Players.RadiationRules,
	}
	local world = { World = { WorldServer = { __stub = "WorldServer" } } }
	players.Parent = world
	local script = { Parent = players, Name = "Radiation" }
	local function req(node)
		if type(node) == "table" and rawget(node, "__stub") then
			return Stubs[rawget(node, "__stub")]
		end
		return require(node)
	end

	local source = fs.readFile("src/server/Players/Radiation.luau")
	local lines = string.split(source, "\n")
	lines[2] = "local script, require, game = ...; " .. lines[2]
	local chunk = luau.load(table.concat(lines, "\n"), {
		debugName = "Radiation(glue)",
		environment = { task = fakeTask },
	})
	local RadiationServer = chunk(script, req, game)

	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local Radiation = require(shared.Radiation)

	-- A world: a Block of Uranium at (1, 64, 0), air elsewhere (y >= 0).
	local fakeWorld = {
		peekBlock = function(_self, x, y, z)
			if x == 1 and y == 64 and z == 0 then
				return Blocks.id.UraniumBlock
			end
			return Blocks.id.Air
		end,
	}

	local function newPlayer(userId: number)
		local attrs = {}
		local p
		p = {
			UserId = userId,
			Name = `P{userId}`,
			Parent = Players,
			Character = nil,
			CharacterAdded = signal(),
			GetAttribute = function(_self, k)
				return attrs[k]
			end,
			SetAttribute = function(_self, k, v)
				attrs[k] = v
			end,
		}
		return p
	end
	local function newCharacter()
		local humanoid = { Health = 20, MaxHealth = 20, Died = signal() }
		function humanoid.IsA(_self, c)
			return c == "Humanoid"
		end
		local character = {}
		function character.WaitForChild(_self, name)
			return if name == "Humanoid" then humanoid else nil
		end
		function character.FindFirstChildOfClass(_self, name)
			return if name == "Humanoid" then humanoid else nil
		end
		return character, humanoid
	end
	local function spawnCharacter(p)
		local character, humanoid = newCharacter()
		p.Character = character
		p.CharacterAdded:Fire(character)
		return character, humanoid
	end
	local function heartbeat(seconds: number)
		for _ = 1, math.round(seconds * 20) do
			Heartbeat:Fire(1 / 20)
		end
	end

	RadiationServer.start(fakeWorld)

	t.test("radiation glue: death clears the dose before a save reads it, leaving on the death screen", function()
		local p = newPlayer(1)
		table.insert(playersList, p)
		Players.PlayerAdded:Fire(p)
		windows[p] = { inventory = { slots = {}, armor = {}, cursor = nil }, container = nil }
		feet[p] = { 0.2, 64, 0.5 }
		local _, humanoid = spawnCharacter(p)
		RadiationServer.restore(p, 12)
		heartbeat(2)
		t.ok(RadiationServer.dose(p) > 10, "a high dose alive")
		t.ok(p:GetAttribute(Radiation.DOSE_ATTRIBUTE) ~= nil, "published")
		-- Dies (of Radiation Sickness III, say), then leaves before respawning.
		humanoid.Health = 0
		humanoid.Died:Fire()
		local exported = RadiationServer.export(p)
		t.eq(exported, 0, "what WorldSave.finalRecord and CharacterStore.capture save")
		t.eq(p:GetAttribute(Radiation.DOSE_ATTRIBUTE), nil, "the dose attribute goes at once")
		t.eq(p:GetAttribute(Radiation.RATE_ATTRIBUTE), nil, "and the rate")
		Players.PlayerRemoving:Fire(p)
		flush()
		p.Parent = nil
		-- Rejoins with what was saved: nothing.
		local q = newPlayer(1)
		table.insert(playersList, q)
		Players.PlayerAdded:Fire(q)
		RadiationServer.restore(q, exported)
		windows[q] = { inventory = { slots = {}, armor = {}, cursor = nil }, container = nil }
		feet[q] = { 100.5, 64, 100.5 }
		spawnCharacter(q)
		t.eq(RadiationServer.dose(q), 0, "the next life starts clean")
		-- Respawning in the same session clears it too.
		local r = newPlayer(2)
		Players.PlayerAdded:Fire(r)
		spawnCharacter(r)
		RadiationServer.restore(r, 12)
		t.eq(RadiationServer.dose(r), 12, "restored onto the living body")
		spawnCharacter(r)
		t.eq(RadiationServer.dose(r), 0, "a new character has none")
	end)

	t.test("radiation glue: a dose restored while the body is dead waits for the next one", function()
		local p = newPlayer(4)
		Players.PlayerAdded:Fire(p)
		local _, humanoid = spawnCharacter(p)
		humanoid.Health = 0
		humanoid.Died:Fire()
		RadiationServer.restore(p, 5)
		t.eq(RadiationServer.dose(p), 0, "not into the dead body")
		spawnCharacter(p)
		t.eq(RadiationServer.dose(p), 5, "the next character gets it")
	end)

	t.test("radiation glue: switched off, nothing is published and a saved dose is kept", function()
		-- A second, fresh instance of the glue started with Config.Radiation.Enabled = false.
		Config.Radiation.Enabled = false
		local off = luau.load(table.concat(lines, "\n"), {
			debugName = "Radiation(glue, off)",
			environment = { task = fakeTask },
		})(script, req, game)
		off.start(fakeWorld)
		local p = newPlayer(3)
		table.insert(playersList, p)
		Players.PlayerAdded:Fire(p)
		off.restore(p, 2.5)
		spawnCharacter(p)
		heartbeat(3)
		Config.Radiation.Enabled = true
		t.eq(p:GetAttribute(Radiation.DOSE_ATTRIBUTE), nil, "no dose attribute")
		t.eq(p:GetAttribute(Radiation.RATE_ATTRIBUTE), nil, "no rate attribute")
		t.eq(off.export(p), 2.5, "the saved dose is kept as it is")
	end)
end

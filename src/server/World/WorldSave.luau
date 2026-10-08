--!strict
--[[
	Saving and loading worlds in the game (Minecraft's level saving, autosave, /save-all,
	/save-off, /save-on and its world list): the Roblox side of Save/ (WorldStore's rules,
	WorldSnapshot's state, the codecs), with Config.Save's numbers. The title screen's Load World
	goes through here (Players/WorldMenu), the boot's startWorld calls `attach`, `blockChanged`,
	`restore` and `begin`.

	  Store      the DataStore Config.Save.StoreName ("IceVoxelWorlds_v1"): one read of the world
	             list at boot tells whether there is one (Studio without API access, a game with
	             saving off: worlds last for the session, and the title screen and the chat say
	             so: Protocol WorldSave state). Requests go through Save/SaveScheduler with
	             DataStoreService:GetRequestBudgetForRequestType as their budget.
	  Owners     the title screen lists, loads, renames and deletes a player's own worlds only
	             (those they created: `claim` makes them the next world's owner, when their list
	             has room), and the game's people (Operators.isPermanent) the game's worlds too
	             (Save/WorldMeta's owners): the first stranger into an empty server, its operator
	             until a world exists, can't touch anyone else's.
	  Loading    `prepare` (the title screen's Load World, or the latest world with the menu off
	             and Config.Save.LoadLatest) takes the world's lock and reads its record and
	             regions, showing "Loading world: 12 / 40" on every title screen; a world that
	             can't be read whole is never started (nor written), and one holding what this
	             version doesn't know is played but not saved. startWorld then makes the world:
	             `attach` gives it the loaded edits before any chunk is generated (and makes a
	             new world's handle), `restore` puts containers, machines, pipes, structure
	             blocks, items, animals, operators and the sections (the clock, and whatever
	             registered: `registerSection`) back once every part has started, before the
	             world is published; block updates that were due come back as their chunks
	             generate (and are saved again, as they were, until then). A world whose start
	             failed (`abandon`) is never saved: half of it may be missing.
	  Dirty      every block change marks its region (`blockChanged`); a save writes the regions
	             that changed, those holding state now and those that held some at the last save
	             (WorldSnapshot.collect), comparing each with what the store holds (WorldStore:
	             unchanged regions are not written again).
	  Saving     every Config.Save.Interval seconds (300, Minecraft's 5 minutes) while automatic
	             saving is on, on /save-all, and at shutdown (BindToClose, within 25 of its 30
	             seconds, before the lock is given back: even after /save-off, as Minecraft's
	             stop saves). One save at a time: the snapshot is taken in one frame, then the
	             writes go out within the budgets. A new world is saved at once, so it is listed.
	  Feedback   everyone gets WorldSave "saving" and "saved" (the client's saving icon, bottom
	             right, while one is in flight: everyone may wonder at a hitch), operators the
	             sizes too (the toast: "World saved — 1.4 MB of 64 MB (largest region 0.3 /
	             4 MB)"); operators read in the chat when a save failed or was refused, and when
	             the world passes Config.Save.WarnShare of its most (again every 5% more).
	  Players    each player's record in the world (Save/PlayerCodec) is read when they join;
	             until it is, they wait on the title screen (WorldMenu's `beforeEnter`, at most
	             ENTER_WAIT seconds). Their inventory and game mode come back at once, the rest on
	             their first character: where they stood and looked (Players/Spawning's
	             placement), health (Characters.restoreHealth), Tough As Nails and effects; until
	             a character stands, what they are saved with is the record's (PlayerCodec
	             .withWaiting: leaving from the title screen keeps their place). A player whose
	             record could not be read starts afresh, and one whose record holds items this
	             version doesn't know plays with the rest: neither is written this session (an
	             outage never replaces a saved inventory with an empty one), and they are told.
	             Records go out with every save, and at once when a player leaves, each numbered
	             as it is captured: an older one is never written over a newer
	             (WorldStore's `order`).
	  Lock       held while the world is open, renewed while it loads, as it starts and every
	             third of Config.Save.LockTimeout, and looked at before every save writes; a lost
	             lock (another server took a stale world over) stops saving, and operators are
	             told.
	  Commands   /save-all [flush], /save-off, /save-on (operators: Save/SaveCommand), as
	             TextChatCommands (or the legacy chat's Chatted); in a world that can't be saved
	             they say why and change nothing.
	  Sections   `registerSection(name, encode, decode)`: other parts of the game keep state of
	             their own with the world (the weather's clock and overrides, say): `encode()`
	             returns a JSON-able value (strings, numbers, booleans, tables of them; small: it
	             goes in the world's record) at every save, `decode(value)` gets it back once
	             when a saved world starts (after every part started, before the world is
	             published), or at once when registered later. "time" is the day clock's (day
	             time and doDaylightCycle), "weather" the weather's (World/WeatherServer: its
	             clock, doWeatherCycle and a /weather override with its time left, so storms go on
	             where they were; a world saved without it starts clear at spawn, as a new one).
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)
local GameMode = require(Shared.GameMode)
local Protocol = require(Shared.Net.Protocol)
local SaveText = require(Shared.SaveText)
local InventoryTypes = require(Shared.Inventory.Types)
local WorldSettings = require(Shared.WorldSettings)

local Server = script.Parent.Parent
local ServerNet = require(Server.Network.ServerNet)
local WorldServer = require(script.Parent.WorldServer)
local TimeOfDay = require(script.Parent.TimeOfDay)
local WeatherServer = require(script.Parent.WeatherServer)
local Characters = require(Server.Players.Characters)
local Effects = require(Server.Players.Effects)
local GameModes = require(Server.Players.GameModes)
local Inventories = require(Server.Players.Inventories)
local Operators = require(Server.Players.Operators)
local PlayerPositions = require(Server.Players.PlayerPositions)
local Spawning = require(Server.Players.Spawning)
local ToughAsNails = require(Server.Players.ToughAsNails)
local PlayerCodec = require(Server.Save.PlayerCodec)
local RegionCodec = require(Server.Save.RegionCodec)
local SaveCommand = require(Server.Save.SaveCommand)
local SaveScheduler = require(Server.Save.SaveScheduler)
local WorldMeta = require(Server.Save.WorldMeta)
local WorldSnapshot = require(Server.Save.WorldSnapshot)
local WorldStore = require(Server.Save.WorldStore)

type Record = PlayerCodec.Record

-- Seconds a player entering the world waits for their record at most.
local ENTER_WAIT = 10
-- Seconds BindToClose spends saving (of Roblox's 30), and between looks at players' state.
local CLOSE_SECONDS = 25
local CACHE_INTERVAL = 2
-- Warnings in the chat each time the world takes this much more of its most.
local WARN_STEP = 0.05

local WorldSave = {}

type Section = { encode: () -> any, decode: (value: any) -> () }

type PlayerState = {
	-- Their record was read (or there is none); writing it is allowed (never after a failed read).
	loaded: boolean,
	canSave: boolean,
	-- The saved record whose place and health wait for their next character (Spawning takes it).
	record: Record?,
	-- The saved record no character has used yet (a save keeps its place, health, Tough As Nails
	-- and effects until one stands).
	waiting: Record?,
	-- Their inventory (the same table all session: Players/InventoryState).
	inventory: InventoryTypes.Inventory?,
	-- The record as last seen alive (what a leaving player whose character went already keeps).
	cache: Record?,
	waiters: { thread },
}

local saves: WorldStore.Saves? = nil
local lobby: ServerNet.ServerNet? = nil
local state: number = Protocol.SaveState.Unavailable
local reason: string? = "starting"
local probed = false
local current: WorldStore.World? = nil
local prepared: WorldStore.Loaded? = nil
local systems: WorldSnapshot.Systems? = nil
local dirty: { [string]: boolean } = {}
local live: { [string]: boolean } = {}
local autosave = true
local saving = false
local againAfter = false
local closing = false
local begun = false
local warnedShare = 0
local sections: { [string]: Section } = {}
local savedSections: { [string]: any } = {}
local restoredSections = false
local pendingTicks: { [number]: { RegionCodec.TickRecord } } = {}
local players: { [Player]: PlayerState } = {}
-- A captured record's order (WorldStore's: later captures are higher).
local captures = 0
-- Records of players who left, not written yet (user id -> text and order).
local departed: { [number]: { text: string, order: number } } = {}
-- The next new world's owner (`claim`: the player creating it; 0: the game's).
local creator = 0

--[[ Messages ]]

local function send(player: Player, kind: number, payload: buffer)
	local net = lobby
	if net and player.Parent then
		net.send(player, kind, payload)
	end
end

local function notify(player: Player, text: string)
	send(player, Protocol.ServerMessage.Notice, Protocol.encodeNotice(text))
end

local function notifyOperators(text: string)
	for _, player in Players:GetPlayers() do
		if Operators.isOperator(player) then
			notify(player, text)
		end
	end
end

local function sendState(player: Player)
	if not probed then
		return
	end
	send(
		player,
		Protocol.ServerMessage.WorldSave,
		Protocol.encodeWorldSave({ op = Protocol.SaveOp.State, state = state, text = reason or "" })
	)
end

local function setState(newState: number, why: string?)
	state, reason = newState, why
	for _, player in Players:GetPlayers() do
		sendState(player)
	end
end

-- Whether worlds can be saved and loaded here (Protocol.SaveState) and why not.
function WorldSave.status(): (number, string?)
	return state, reason
end

-- Everyone's title screen: keys a load read.
function WorldSave.progress(done: number, total: number, name: string)
	local payload = Protocol.encodeWorldSave({ op = Protocol.SaveOp.Loading, done = done, total = total, text = name })
	for _, player in Players:GetPlayers() do
		send(player, Protocol.ServerMessage.WorldSave, payload)
	end
end

--[[ The store ]]

-- Why the DataStore can't be used, in words for the title screen.
local function describe(err: unknown): string
	local text = tostring(err)
	if
		RunService:IsStudio() and (string.find(text, "403") or string.find(text, "API") or string.find(text, "publish"))
	then
		return "Studio has no API access (Game Settings > Security > Enable Studio Access to API Services)"
	end
	return `the DataStore can't be reached ({string.sub(text, 1, 120)})`
end

local function requestType(kind: SaveScheduler.Kind): Enum.DataStoreRequestType
	if kind == "get" then
		return Enum.DataStoreRequestType.GetAsync
	elseif kind == "update" then
		return Enum.DataStoreRequestType.UpdateAsync
	end
	return Enum.DataStoreRequestType.SetIncrementAsync
end

local function adapter(dataStore: DataStore): WorldStore.Store
	return {
		get = function(key: string): (boolean, unknown)
			return pcall(function(): unknown
				return dataStore:GetAsync(key)
			end)
		end,
		set = function(key: string, value: unknown, userIds: { number }?): (boolean, string?)
			local ok, err = pcall(function()
				dataStore:SetAsync(key, value, userIds)
			end)
			return ok, if ok then nil else tostring(err)
		end,
		update = function(key: string, transform: (unknown) -> unknown?): (boolean, unknown)
			return pcall(function(): unknown
				return dataStore:UpdateAsync(key, function(old: unknown): unknown?
					return transform(old)
				end)
			end)
		end,
		remove = function(key: string): (boolean, string?)
			local ok, err = pcall(function()
				dataStore:RemoveAsync(key)
			end)
			return ok, if ok then nil else tostring(err)
		end,
	}
end

local function newEnv(): WorldStore.Env
	local random = Random.new()
	local job = game.JobId
	if job == "" then
		job = `studio-{HttpService:GenerateGUID(false)}`
	end
	return {
		now = os.clock,
		budget = function(kind: SaveScheduler.Kind): number
			local ok, budget = pcall(function(): number
				return DataStoreService:GetRequestBudgetForRequestType(requestType(kind))
			end)
			return if ok then budget else 1
		end,
		wait = function(seconds: number)
			task.wait(seconds)
		end,
		spawn = function(fn: () -> ())
			task.spawn(fn)
		end,
		time = os.time,
		job = job,
		random = function(): number
			return random:NextNumber()
		end,
	}
end

-- Opens the DataStore and reads the world list once (see the header): the state it leaves.
local function probe(): (number, string?)
	if not Config.Save.Enabled then
		return Protocol.SaveState.Unavailable, "saving is off in this game (Config.Save.Enabled)"
	end
	local okStore, store = pcall(function(): DataStore
		return DataStoreService:GetDataStore(Config.Save.StoreName)
	end)
	if not okStore then
		return Protocol.SaveState.Unavailable, describe(store)
	end
	local readOk, err: unknown = false, nil
	for attempt = 1, 2 do
		readOk, err = pcall(function(): unknown
			return (store :: DataStore):GetAsync(WorldMeta.INDEX)
		end)
		if readOk then
			break
		elseif attempt == 1 then
			task.wait(2)
		end
	end
	if not readOk then
		warn(`[IceVoxel] worlds will not be saved: {err}`)
		return Protocol.SaveState.Unavailable, describe(err)
	end
	saves = WorldStore.new(adapter(store :: DataStore), newEnv())
	return Protocol.SaveState.On, nil
end

-- Waits for the boot's look at the DataStore (at most 20 s).
local function waitForProbe()
	local deadline = os.clock() + 20
	while not probed and os.clock() < deadline do
		task.wait(0.1)
	end
end

--[[ The title screen ]]

-- Who `player` is to the saved worlds (WorldMeta.mayManage); nil: the server itself.
local function requester(player: Player?): WorldMeta.Requester?
	if player == nil then
		return nil
	end
	return { userId = player.UserId, permanent = Operators.isPermanent(player) }
end

--[[
	The saved worlds `player` may open (see the header: their own, and the game's for its own
	people; nil: the game's, for the boot), last played first (yields), or nil and why not.
]]
function WorldSave.list(player: Player?): ({ Protocol.WorldEntry }?, string?)
	waitForProbe()
	local store = saves
	if store == nil then
		return nil, SaveText.state(state, reason)
	end
	local owners = { 0 }
	if player then
		owners = { player.UserId }
		if Operators.isPermanent(player) and player.UserId ~= 0 then
			table.insert(owners, 0)
		end
	end
	local found: { WorldMeta.Entry } = {}
	for _, owner in owners do
		local index, why = WorldStore.list(store, owner)
		if index == nil then
			return nil, why
		end
		table.move(index.worlds, 1, #index.worlds, #found + 1, found)
	end
	table.sort(found, function(a, b)
		if a.lastPlayed ~= b.lastPlayed then
			return a.lastPlayed > b.lastPlayed
		end
		return a.id < b.id
	end)
	local entries: { Protocol.WorldEntry } = {}
	for _, entry in found do
		table.insert(entries, {
			id = entry.id,
			name = entry.name,
			worldType = entry.worldType,
			seed = entry.seed,
			gameMode = entry.gameMode,
			lastPlayed = entry.lastPlayed,
			bytes = entry.bytes,
		})
	end
	return entries, nil
end

--[[
	The title screen's Create World: `player` will own the world about to be made, when their
	list has room (true, or false and why not; true when worlds can't be saved here at all).
]]
function WorldSave.claim(player: Player): (boolean, string?)
	waitForProbe()
	local store = saves
	if store == nil or state == Protocol.SaveState.Unavailable then
		return true, nil
	end
	local ok, why = WorldStore.room(store, player.UserId)
	if ok then
		creator = player.UserId
	end
	return ok, why
end

--[[
	Opens saved world `id` for startWorld (yields): its settings, or nil and why not. `player`
	(nil: the boot) must be allowed to (see the header).
]]
function WorldSave.prepare(
	id: string,
	progress: ((done: number, total: number) -> ())?,
	player: Player?
): (WorldSettings.Settings?, string?)
	waitForProbe()
	local store = saves
	if store == nil then
		return nil, SaveText.state(state, reason)
	elseif current or prepared then
		return nil, "a world is open already"
	end
	local loaded, why = WorldStore.load(store, id, progress, requester(player))
	if loaded == nil then
		return nil, why
	end
	prepared = loaded
	if loaded.dropped > 0 then
		warn(
			`[IceVoxel] {loaded.dropped} blocks, items or mobs this version doesn't know were left out of the world: it is not saved this session`
		)
	end
	return loaded.settings, nil
end

--[[
	A world that did not start (startWorld failed, after `prepare` or for a new world): it is never
	saved (half of its parts may not have its state), and its lock goes back.
]]
function WorldSave.abandon()
	local loaded, store = prepared, saves
	prepared = nil
	local world = current or (if loaded then loaded.world else nil)
	if world then
		world.canSave = false
		world.reason = "it could not be started"
		if store then
			WorldStore.release(store, world)
		end
	end
end

function WorldSave.delete(id: string, player: Player?): (boolean, string?)
	waitForProbe()
	local store = saves
	if store == nil then
		return false, SaveText.state(state, reason)
	end
	return WorldStore.delete(store, id, requester(player))
end

function WorldSave.rename(id: string, name: string, player: Player?): (boolean, string?)
	waitForProbe()
	local store = saves
	if store == nil then
		return false, SaveText.state(state, reason)
	end
	return WorldStore.rename(store, id, name, requester(player))
end

--[[
	The world played last that no other server has open (MainMenu.Enabled off with
	Config.Save.LoadLatest), prepared: its settings, or nil (none, or saving unavailable).
]]
function WorldSave.latest(): WorldSettings.Settings?
	if not Config.Save.LoadLatest then
		return nil
	end
	local worlds = WorldSave.list()
	if worlds == nil then
		return nil
	end
	for _, entry in worlds do
		local settings, why = WorldSave.prepare(entry.id)
		if settings then
			print(`[IceVoxel] loading the world "{entry.name}" ({entry.id})`)
			return settings
		end
		warn(`[IceVoxel] the world "{entry.name}" was not loaded: {why}`)
	end
	return nil
end

--[[ Players ]]

local function wake(waiters: { thread })
	for _, thread in waiters do
		task.spawn(thread)
	end
	table.clear(waiters)
end

-- Yields until the player's record was read (at most ENTER_WAIT s): WorldMenu's `beforeEnter`.
function WorldSave.beforeEnter(player: Player)
	local deadline = os.clock() + ENTER_WAIT
	while os.clock() < deadline do
		local ps = players[player]
		if ps and ps.loaded then
			return
		elseif ps == nil and begun then
			return
		end
		task.wait(0.1)
	end
end

-- The player as a save keeps them now (each capture numbered: `captures`).
local function capture(player: Player, ps: PlayerState): (Record, number)
	captures += 1
	local record = PlayerCodec.new()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local standing = false
	if character and humanoid and humanoid.Health > 0 then
		standing = true
		-- (Players/PlayerPositions: doubles, as the record keeps them.)
		local x, y, z = PlayerPositions.feet(player)
		if x then
			record.position = true
			record.x, record.y, record.z = x, y, z
			record.yaw = PlayerPositions.yaw(player)
		end
		record.health = if humanoid.MaxHealth > 0 then humanoid.Health / humanoid.MaxHealth * 20 else 20
	end
	record.mode = GameMode.of(player)
	record.previous = GameMode.previousOf(player)
	local inventory = ps.inventory
	if inventory == nil then
		local window = Inventories.get(player)
		inventory = window and window.inventory
		ps.inventory = inventory
	end
	if inventory then
		record.slots = inventory.slots
		record.armor = inventory.armor
		record.cursor = inventory.cursor
		record.selected = inventory.selected
	end
	local thirst, temperature = ToughAsNails.export(player)
	record.thirst = thirst :: any
	record.temperature = temperature :: any
	local effects = Effects.export(player)
	record.effects = (effects or {}) :: any
	-- (Until a character stands, the saved record's place and the rest are what they have.)
	local waiting = ps.waiting
	if standing then
		ps.waiting = nil
	end
	PlayerCodec.withWaiting(
		record,
		waiting,
		{ standing = standing, climate = thirst ~= nil and temperature ~= nil, effects = effects ~= nil }
	)
	return record, captures
end

-- A leaving player's record: as they are, or as last seen alive where their character went first.
local function finalRecord(player: Player, ps: PlayerState): (Record, number)
	local fresh, order = capture(player, ps)
	local cached = ps.cache
	if cached and player.Character == nil then
		fresh.position, fresh.x, fresh.y, fresh.z, fresh.yaw = cached.position, cached.x, cached.y, cached.z, cached.yaw
		fresh.health = cached.health
	end
	if cached and fresh.thirst == nil then
		fresh.thirst, fresh.temperature = cached.thirst, cached.temperature
	end
	if cached and Effects.export(player) == nil then
		fresh.effects = cached.effects
	end
	return fresh, order
end

-- Puts a player where the record says and gives their character the record's health.
local function placeCharacter(player: Player, record: Record)
	if record.position then
		Characters.teleportTo(player, record.x, record.y, record.z, record.yaw)
	end
	Characters.restoreHealth(player, record.health)
end

-- A player's saved record comes back (see the header).
local function applyRecord(player: Player, ps: PlayerState, record: Record)
	Inventories.restore(player, record.slots, record.armor, record.selected, record.cursor)
	local mode = record.mode
	if mode and GameMode.isValid(mode) then
		GameModes.set(player, mode, false)
	end
	if record.previous then
		player:SetAttribute(GameMode.PREVIOUS_ATTRIBUTE, record.previous)
	end
	ToughAsNails.restore(player, record.thirst :: any, record.temperature :: any)
	Effects.restore(player, record.effects :: any)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if character and humanoid and humanoid.Health > 0 then
		-- (Already standing: the menu off, characters load as Roblox's.)
		placeCharacter(player, record)
	else
		ps.record = record
		ps.waiting = record
	end
end

-- Players/Spawning's placement: a returning player's first character stands where they left
-- (feet, blocks, doubles, and yaw).
local function placement(player: Player): (number?, number, number, number?)
	local ps = players[player]
	local record = ps and ps.record
	if ps == nil or record == nil then
		return nil, 0, 0, nil
	end
	ps.record = nil
	task.defer(function()
		Characters.restoreHealth(player, record.health)
	end)
	if not record.position then
		return nil, 0, 0, nil
	end
	return record.x, record.y, record.z, record.yaw
end

local function track(player: Player)
	if players[player] then
		return
	end
	local ps: PlayerState = {
		loaded = false,
		canSave = false,
		record = nil,
		waiting = nil,
		inventory = nil,
		cache = nil,
		waiters = {},
	}
	players[player] = ps
	local window = Inventories.get(player)
	ps.inventory = window and window.inventory
	task.spawn(function()
		local world, store = current, saves
		if world == nil or store == nil then
			ps.loaded = true
			wake(ps.waiters)
			return
		end
		-- (Back before their record was written: the one they left with, theirs again now: a
		-- later capture of them supersedes it, and nothing writes it over their newer ones.)
		local left = departed[player.UserId]
		local ok, record
		if left then
			departed[player.UserId] = nil
			ok, record = true, PlayerCodec.fromText(left.text)
		else
			ok, record = WorldStore.loadPlayer(store, world, player.UserId)
		end
		if players[player] ~= ps then
			return
		end
		ps.loaded = true
		ps.canSave = ok and (record == nil or record.dropped == 0)
		if not ok then
			warn(`[IceVoxel] the record of {player.Name} in this world could not be read`)
			notify(
				player,
				"Your things in this world could not be read: you start afresh, and this visit is not saved for you"
			)
		elseif record then
			if record.dropped > 0 then
				warn(`[IceVoxel] the record of {player.Name} holds items this version doesn't know`)
				notify(
					player,
					"Your things in this world include items this version doesn't know: this visit is not saved for you"
				)
			end
			applyRecord(player, ps, record)
		end
		wake(ps.waiters)
	end)
end

-- Records of players who left, written now (Minecraft saves a player's data as they leave).
local function flushDeparted()
	local world, store = current, saves
	if world == nil or store == nil or closing or next(departed) == nil then
		return
	end
	local batch = table.clone(departed)
	local texts: { [number]: string } = {}
	local order: { [number]: number } = {}
	for userId, entry in batch do
		texts[userId], order[userId] = entry.text, entry.order
	end
	local written = WorldStore.savePlayers(store, world, texts, nil, order)
	for userId in written do
		if departed[userId] == batch[userId] then
			departed[userId] = nil
		end
	end
end

local function leave(player: Player)
	local ps = players[player]
	if ps == nil then
		return
	end
	players[player] = nil
	wake(ps.waiters)
	local world = current
	if ps.loaded and ps.canSave and world and world.canSave then
		local record, order = finalRecord(player, ps)
		departed[player.UserId] = { text = PlayerCodec.toText(record), order = order }
		task.spawn(flushDeparted)
	end
end

--[[ Sections ]]

--[[
	Keeps `name`'s state with the world (see the header): `encode()` at every save (a small
	JSON-able value, or nil for none), `decode(value)` once when a saved world with it starts.
]]
function WorldSave.registerSection(name: string, encode: () -> any, decode: (value: any) -> ())
	sections[name] = { encode = encode, decode = decode }
	local value = savedSections[name]
	if restoredSections and value ~= nil then
		local ok, err = pcall(function(): any
			decode(value)
			return nil
		end)
		if not ok then
			warn(`[IceVoxel] the saved {name} could not be read back: {err}`)
		end
	end
end

local function encodeSections(): { [string]: any }
	local out: { [string]: any } = {}
	for name, section in sections do
		local ok, value = pcall(section.encode)
		if ok and value ~= nil then
			out[name] = value
		elseif not ok then
			warn(`[IceVoxel] the {name} section could not be saved: {value}`)
			-- (Its last saved value stays.)
			out[name] = savedSections[name]
		end
	end
	return out
end

-- The day clock (Shared/DayCycle ticks) and doDaylightCycle.
WorldSave.registerSection("time", function(): any
	return { dayTime = TimeOfDay.get(), cycle = TimeOfDay.cycle() }
end, function(value: any)
	if type(value) ~= "table" then
		return
	end
	if type(value.cycle) == "boolean" then
		TimeOfDay.setCycle(value.cycle)
	end
	local dayTime = value.dayTime
	if type(dayTime) == "number" and dayTime == dayTime and math.abs(dayTime) ~= math.huge then
		TimeOfDay.set(dayTime)
	end
end)

--[[
	The weather (World/WeatherServer: Weather.encodeState's text). startWorld starts the weather
	before `restore`, so a saved world's replaces the new world's clear start there; text that
	can't be read leaves that clear start.
]]
WorldSave.registerSection("weather", function(): any
	return WeatherServer.encode()
end, function(value: any)
	if type(value) ~= "string" or not WeatherServer.decode(value) then
		warn("[IceVoxel] the saved weather could not be read back: it starts clear")
	end
end)

--[[ The world ]]

--[[
	startWorld, right after making the world: a loaded world's edits become its own (before any
	chunk is generated); a new world gets its handle (saved for the first time by `begin`).
]]
function WorldSave.attach(world: WorldServer.World, settings: WorldSettings.Settings)
	-- (A world made in the first seconds waits for the look at the DataStore.)
	waitForProbe()
	local loaded = prepared
	if loaded then
		WorldSnapshot.applyEdits(world, loaded.regions)
		current = loaded.world
		savedSections = loaded.world.meta.sections
	elseif saves and state ~= Protocol.SaveState.Unavailable then
		current = WorldStore.create(saves :: WorldStore.Saves, settings, creator)
		-- (Everything a new world has is dirty: its first save writes it all.)
	end
end

-- startWorld's WorldServer.onChanged: block (x, y, z) changed, its region must be written.
function WorldSave.blockChanged(x: number, _y: number, z: number)
	dirty[WorldSnapshot.regionName(x, z)] = true
end

--[[
	startWorld, once every part started and before the world is published: a loaded world's state
	goes back into `parts` (see the header).
]]
function WorldSave.restore(parts: WorldSnapshot.Systems)
	local loaded = prepared
	if loaded then
		-- (Throwing here fails startWorld: `prepared` stays for `abandon`, and `systems` stays
		-- unset, so nothing half restored is ever saved.)
		local report = WorldSnapshot.restore(parts, loaded.regions)
		pendingTicks = report.ticks
		Operators.grant(loaded.world.meta.operators)
		for _, region in loaded.regions do
			if
				#region.containers > 0
				or #region.sourced > 0
				or #region.structures > 0
				or #region.pipes > 0
				or #region.tanks > 0
				or #region.transport > 0
				or #region.items > 0
				or #region.mobs > 0
				or #region.ticks > 0
			then
				live[RegionCodec.name(region.rx, region.rz)] = true
			end
		end
		print(
			`[IceVoxel] world "{loaded.world.meta.name}" loaded: {#loaded.regions} regions, {report.containers} containers, {report.machines} machines, {report.pipes} pipes and tanks, {report.items} items, {report.mobs} animals`
		)
		prepared = nil
	end
	for name, value in savedSections do
		local section = sections[name]
		if section then
			local ok, err = pcall(function(): any
				section.decode(value)
				return nil
			end)
			if not ok then
				warn(`[IceVoxel] the saved {name} could not be read back: {err}`)
			end
		end
	end
	restoredSections = true
	local ticker = parts.ticker
	if ticker then
		local world = parts.world
		local chained = world.onGenerated
		world.onGenerated = function(cx: number, cz: number)
			local key = Coords.chunkKey(cx, cz)
			local ticks = pendingTicks[key]
			if ticks then
				pendingTicks[key] = nil
				WorldSnapshot.scheduleTicks(ticker, ticks)
			end
			if chained then
				chained(cx, cz)
			end
		end
	end
	-- Last: saves start from here, with everything restored.
	systems = parts
end

--[[ Saving ]]

local function report(result: WorldStore.SaveResult)
	for _, player in Players:GetPlayers() do
		local operator = Operators.isOperator(player)
		send(
			player,
			Protocol.ServerMessage.WorldSave,
			Protocol.encodeWorldSave({
				op = Protocol.SaveOp.Saved,
				ok = result.ok,
				sizes = operator,
				warn = result.state ~= "ok",
				bytes = result.bytes,
				max = result.max,
				largest = result.largest,
				keyLimit = result.keyLimit,
				text = if operator then result.message or "" else "",
			})
		)
	end
	if result.refused or not result.ok then
		notifyOperators(result.message or "The world could not be saved")
	end
	local share = SaveText.share(result.bytes, result.max)
	if share >= Config.Save.WarnShare and share >= warnedShare + WARN_STEP then
		warnedShare = share
		notifyOperators(SaveText.nearing(result.bytes, result.max))
	end
end

--[[
	Saves the world now (see the header): yields until written. `forced` waits for a save in
	flight and then saves (/save-all, shutdown); otherwise one in flight makes this one follow it.
	`deadline` (os.clock) stops starting writes. nil when there is nothing to save.
]]
local function saveNow(forced: boolean?, deadline: number?): WorldStore.SaveResult?
	local world, store, parts = current, saves, systems
	if world == nil or store == nil or parts == nil then
		return nil
	end
	if saving then
		if not forced then
			againAfter = true
			return nil
		end
		-- (A save in flight finishes first; at shutdown, only while there is time for another.)
		local wait = if deadline then deadline - 10 else math.huge
		while saving and os.clock() < wait do
			task.wait(0.1)
		end
		if saving then
			return nil
		end
	end
	saving = true
	for _, player in Players:GetPlayers() do
		send(player, Protocol.ServerMessage.WorldSave, Protocol.encodeWorldSave({ op = Protocol.SaveOp.Saving }))
	end
	local takenDirty = dirty
	local previousLive = live
	local okSnapshot, input, liveNow = pcall(function(): (WorldStore.SaveInput, { [string]: boolean })
		-- (One frame: see WorldSnapshot.collect.)
		dirty = {}
		local regions, liveRegions =
			WorldSnapshot.collect(parts, takenDirty, previousLive, Config.Save.Items, Config.Save.Mobs, pendingTicks)
		local encoded: { [string]: buffer } = {}
		local empty: { [string]: boolean } = {}
		for name, region in regions do
			encoded[name] = RegionCodec.encode(region)
			if RegionCodec.isEmpty(region) then
				empty[name] = true
			end
		end
		local records: { [number]: string } = {}
		local order: { [number]: number } = {}
		for userId, entry in departed do
			records[userId], order[userId] = entry.text, entry.order
		end
		for player, ps in players do
			if ps.loaded and ps.canSave then
				local record, captured = capture(player, ps)
				records[player.UserId], order[player.UserId] = PlayerCodec.toText(record), captured
			end
		end
		return {
			regions = encoded,
			empty = empty,
			players = records,
			order = order,
			sections = encodeSections(),
			operators = Operators.ops(),
		},
			liveRegions
	end)
	if not okSnapshot then
		warn(`[IceVoxel] the world could not be gathered for saving: {input}`)
		for name in takenDirty do
			dirty[name] = true
		end
		saving = false
		local failed: WorldStore.SaveResult = {
			ok = false,
			refused = true,
			bytes = 0,
			largest = 0,
			max = Config.Save.MaxWorldBytes,
			keyLimit = Config.Save.KeyLimit,
			regionsWritten = 0,
			playersWritten = 0,
			written = {},
			failed = 0,
			state = "ok",
			message = "The world could not be gathered for saving (see the server's output)",
		}
		report(failed)
		return failed
	end
	local saveInput = input :: WorldStore.SaveInput
	local result = WorldStore.save(store, world, saveInput, deadline)
	if not result.ok then
		for name in takenDirty do
			dirty[name] = true
		end
		for name in previousLive do
			(liveNow :: { [string]: boolean })[name] = true
		end
	end
	live = liveNow :: { [string]: boolean }
	for userId in result.written do
		local entry = departed[userId]
		if entry and entry.text == saveInput.players[userId] then
			departed[userId] = nil
		end
	end
	if not world.canSave and state == Protocol.SaveState.On then
		setState(Protocol.SaveState.SessionOnly, world.reason)
	end
	saving = false
	report(result)
	if againAfter and not closing then
		againAfter = false
		task.spawn(saveNow)
	end
	return result
end

-- /save-all, /save-off, /save-on from `player`.
local function runCommand(player: Player, text: string)
	if not SaveCommand.matches(text) or player.Parent == nil then
		return
	end
	local world = current
	local result = SaveCommand.run(text, {
		operator = Operators.isOperator(player),
		autosave = autosave,
		available = world ~= nil and world.canSave and saves ~= nil,
		reason = if world then world.reason else SaveText.state(state, reason),
	})
	if result == nil then
		return
	end
	for _, line in result.feedback do
		notify(player, line)
	end
	if result.action == "save" then
		task.spawn(function()
			local saved = saveNow(true)
			if saved and player.Parent then
				notify(player, if saved.ok then SaveCommand.SAVED else `Could not save the game: {saved.message}`)
			end
		end)
	elseif result.action == "off" then
		autosave = false
		-- (Only between On and Off: a world not being saved keeps saying why.)
		if state == Protocol.SaveState.On then
			setState(Protocol.SaveState.Off, nil)
		end
	elseif result.action == "on" then
		autosave = true
		if state == Protocol.SaveState.Off then
			setState(Protocol.SaveState.On, nil)
		end
	end
end

local function listenToCommands()
	if TextChatService.ChatVersion == Enum.ChatVersion.LegacyChatService then
		local function onPlayer(player: Player)
			player.Chatted:Connect(function(message: string)
				runCommand(player, message)
			end)
		end
		Players.PlayerAdded:Connect(onPlayer)
		for _, player in Players:GetPlayers() do
			onPlayer(player)
		end
		return
	end
	for i, alias in SaveCommand.ALIASES do
		local instance = Instance.new("TextChatCommand")
		instance.Name = `IceVoxelSave{i}`
		instance.PrimaryAlias = alias
		-- (Operators only: the chat suggests them to operators alone.)
		instance:SetAttribute(WorldSettings.COMMAND_ATTRIBUTE, WorldSettings.COMMAND_OPERATOR)
		instance.Triggered:Connect(function(source: TextSource, text: string)
			local player = Players:GetPlayerByUserId(source.UserId)
			if player then
				runCommand(player, text)
			end
		end)
		instance.Parent = TextChatService
	end
end

--[[ Starting ]]

--[[
	Before the world (the boot, on the lobby's net): opens the DataStore, tells every title screen
	whether worlds can be saved, and saves the world at shutdown.
]]
function WorldSave.start(net: ServerNet.ServerNet)
	assert(lobby == nil, "WorldSave.start was already called")
	lobby = net
	Players.PlayerAdded:Connect(sendState)
	task.spawn(function()
		local newState, why = probe()
		probed = true
		setState(newState, why)
	end)
	game:BindToClose(function()
		closing = true
		local world, store = current, saves
		if world == nil or store == nil then
			return
		end
		local deadline = os.clock() + CLOSE_SECONDS
		if world.canSave then
			saveNow(true, deadline)
		end
		WorldStore.release(store, world, deadline + 3)
	end)
end

--[[
	After the world is published (startWorld's last step): players' records, the saving loops,
	the commands; a new world is saved at once (so the list has it).
]]
function WorldSave.begin()
	assert(not begun, "WorldSave.begin was already called")
	begun = true
	Spawning.setPlacement(placement)
	Players.PlayerAdded:Connect(track)
	for _, player in Players:GetPlayers() do
		track(player)
	end
	Players.PlayerRemoving:Connect(leave)
	listenToCommands()
	local world = current
	if world == nil then
		-- (Session only: say why to the operators here and as they come in.)
		local why = SaveText.state(state, reason) or "this world is not being saved"
		notifyOperators(why)
		Players.PlayerAdded:Connect(function(player: Player)
			task.delay(5, function()
				if player.Parent and Operators.isOperator(player) then
					notify(player, why)
				end
			end)
		end)
		return
	end
	if not world.canSave then
		-- (Loaded, but not saved this session: say why, as a lost lock does.)
		setState(Protocol.SaveState.SessionOnly, world.reason)
		notifyOperators(`This world is not being saved: {world.reason or "it can't be"}`)
	elseif world.meta.gen == 0 then
		-- A new world: everything it has is in its first save.
		for name in WorldSnapshot.editedRegions((systems :: WorldSnapshot.Systems).world) do
			dirty[name] = true
		end
		task.spawn(saveNow)
	end
	-- Autosave.
	task.spawn(function()
		while not closing do
			local interval = Config.Save.Interval
			task.wait(if interval > 0 then interval else 60)
			if interval > 0 and autosave and not closing then
				saveNow()
			end
		end
	end)
	-- The lock's heartbeat: at once (startWorld took a while since the load), then every third of
	-- its timeout.
	task.spawn(function()
		while not closing do
			local store = saves
			if store and world.lockHeld and not closing and not WorldStore.heartbeat(store, world) then
				setState(Protocol.SaveState.SessionOnly, world.reason)
				notifyOperators(`The world is no longer saved here: {world.reason or "its lock was lost"}`)
			end
			task.wait(math.max(10, Config.Save.LockTimeout / 3))
		end
	end)
	-- What leaving players had, as last seen alive.
	task.spawn(function()
		while not closing do
			task.wait(CACHE_INTERVAL)
			for player, ps in players do
				local character = player.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if ps.loaded and humanoid and humanoid.Health > 0 then
					ps.cache = capture(player, ps)
				end
			end
		end
	end)
end

-- The open world's id (nil: none, or not saved), for tools and F3.
function WorldSave.worldId(): string?
	local world = current
	return if world then world.id else nil
end

return WorldSave

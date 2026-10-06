--!strict
--[[
	Keeps every player's settings (the Options menu, Shared/PlayerSettings) and, when
	Config.Settings.Save is on, saves them in a DataStore between sessions, as WaypointStore does
	for waypoints.

	  * One profile per kind of device (desktop, touch, console): a phone never loads a
	    computer's view distance. The client sends the profile of the device it runs on.
	  * Stored: DataStore "IceVoxelSettings_v1", key player_<UserId>, a table
	    { v = 1, desktop = {...}, touch = {...}, console = {...} } of { [id] = value } per profile
	    (PlayerSettings.toRecord / fromRecord), tied to the user (SetAsync's user ids).
	  * Loaded on join, with retries. If loading fails nothing is saved this session, so an outage
	    can never overwrite saved settings. Once loaded (or given up), the server sends one
	    Settings message per profile (count 0 when nothing is saved); the client takes its own.
	  * The client sends its profile (SaveSettings) after changes; the server decodes it with
	    PlayerSettings (unknown ids dropped, values clamped: there are no strings, so nothing to
	    filter) and keeps the newest per profile, whole: it is every choice the client made. One
	    that arrives before loading finished replaces the loaded one too, but the client is still
	    sent the loaded one: it merges that under its choices (Settings/State.receive, which knows
	    what Defaults and a preset picked since dropped) and sends the result back at once. A
	    key-by-key merge here would bring back saved choices the player had undone.
	  * Saved on leave and on shutdown (BindToClose), only when something changed: at most one
	    GetAsync and one SetAsync per session.
	Without DataStore access (Studio without API services) settings last for the session only.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local PlayerSettings = require(Shared.PlayerSettings)
local Protocol = require(Shared.Net.Protocol)

local ServerNet = require(script.Parent.Parent.Network.ServerNet)

type Values = PlayerSettings.Values

type State = {
	-- Profile number -> the chosen values.
	profiles: { [number]: Values },
	-- Profiles the client sent before loading finished (they replace the loaded ones).
	early: { [number]: Values },
	loaded: boolean,
	canSave: boolean,
	dirty: boolean,
	saving: boolean,
}

local STORE_NAME = "IceVoxelSettings_v1"
local LOAD_ATTEMPTS = 3
local SHUTDOWN_WAIT = 25

local SettingsStore = {}

function SettingsStore.start(net: ServerNet.ServerNet)
	local store: DataStore? = nil
	if Config.Settings.Save then
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(STORE_NAME)
		end)
		if ok then
			store = result
		else
			warn(`[IceVoxel] settings will not be saved: {result}`)
		end
	end

	local states: { [Player]: State } = {}
	local savesInFlight = 0

	local function key(player: Player): string
		return `player_{player.UserId}`
	end

	-- Saves the profiles if they changed; keeps saving while they change during the save.
	local function save(player: Player, state: State)
		if store == nil or not state.canSave or state.saving then
			return
		end
		state.saving = true
		savesInFlight += 1
		while state.dirty do
			state.dirty = false
			local saved = false
			local record = PlayerSettings.toRecord(state.profiles)
			for attempt = 1, 2 do
				local ok, err = pcall(function()
					(store :: DataStore):SetAsync(key(player), record, { player.UserId })
				end)
				if ok then
					saved = true
					break
				end
				warn(`[IceVoxel] could not save settings of {player.Name} (attempt {attempt}): {err}`)
				if attempt == 1 then
					task.wait(2)
				end
			end
			if not saved then
				state.dirty = true
				break
			end
		end
		state.saving = false
		savesInFlight -= 1
	end

	local function sendAll(player: Player, profiles: { [number]: Values })
		for profile in PlayerSettings.PROFILE_NAMES do
			local values = profiles[profile] or {}
			net.send(player, Protocol.ServerMessage.Settings, Protocol.encodeSettings(profile, values))
		end
	end

	local function onPlayer(player: Player)
		local state: State = {
			profiles = {},
			early = {},
			loaded = false,
			canSave = store ~= nil,
			dirty = false,
			saving = false,
		}
		states[player] = state

		if store then
			local loaded = false
			for attempt = 1, LOAD_ATTEMPTS do
				local ok, value = pcall(function()
					return (store :: DataStore):GetAsync(key(player))
				end)
				if ok then
					state.profiles = PlayerSettings.fromRecord(value)
					loaded = true
					break
				end
				warn(`[IceVoxel] could not load settings of {player.Name} (attempt {attempt}): {value}`)
				if attempt < LOAD_ATTEMPTS then
					task.wait(2 ^ attempt)
				end
			end
			if not loaded then
				-- Never overwrite what is stored with settings we could not read.
				state.canSave = false
				warn(`[IceVoxel] settings of {player.Name} are session-only this time`)
			end
		end
		if states[player] ~= state then
			return
		end
		-- The client gets what is saved; what it sent early stands until it sends the merge.
		local saved = table.clone(state.profiles)
		for profile, values in state.early do
			state.profiles[profile] = values
			state.dirty = true
		end
		table.clear(state.early)
		state.loaded = true
		sendAll(player, saved)
	end

	net.on(Protocol.ClientMessage.SaveSettings, function(player: Player, payload: buffer)
		local state = states[player]
		if state == nil then
			return
		end
		local profile, values = Protocol.decodeSettings(payload)
		if profile == nil or values == nil then
			return
		end
		if state.loaded then
			state.profiles[profile] = values
			state.dirty = true
		else
			state.early[profile] = values
		end
	end)

	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		local state = states[player]
		if state == nil then
			return
		end
		states[player] = nil
		if state.loaded then
			save(player, state)
		end
	end)

	game:BindToClose(function()
		local started = os.clock()
		repeat
			local waiting = savesInFlight > 0
			for player, state in states do
				if state.loaded and state.dirty and state.canSave and not state.saving then
					task.spawn(save, player, state)
					waiting = true
				end
			end
			if waiting then
				task.wait(0.2)
			end
		until not waiting or os.clock() - started > SHUTDOWN_WAIT
	end)
end

return SettingsStore

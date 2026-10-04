--!strict
--[[
	Keeps every player's map waypoints and, when Config.Map.SaveWaypoints is on, saves them in a
	DataStore between sessions.

	The client owns the list and sends the whole list (with a revision number) after changes. The
	server:
	  * loads the saved list on join (retrying); if loading fails the session's waypoints are never
	    saved, so a DataStore hiccup can not wipe a player's saved waypoints,
	  * ignores lists older than the newest one it has seen (filtering yields, so updates can finish
	    out of order),
	  * text-filters new names (only a few per update; names already in the list are reused) and
	    sends the list back when filtering changed something,
	  * rate limits updates but always keeps the latest one,
	  * saves on leave and on shutdown, waiting for saves still in flight.
	Without DataStore access (e.g. Studio without API services) waypoints still work per session.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Protocol = require(Shared.Net.Protocol)

local ServerNet = require(script.Parent.Parent.Network.ServerNet)

type Waypoint = Protocol.Waypoint

type State = {
	list: { Waypoint },
	-- Raw name -> filtered name, for the names in `list` only.
	filtered: { [string]: string },
	-- Highest revision received / revision of `list`.
	latest: number,
	loaded: boolean,
	canSave: boolean,
	dirty: boolean,
	saving: boolean,
	leaving: boolean,
	-- Updates currently being filtered.
	busy: number,
	updateTimes: { number },
	pending: buffer?,
	pendingScheduled: boolean,
}

local STORE_NAME = "IceVoxelWaypoints_v1"
local UPDATES_PER_MINUTE = 30
local NEW_NAMES_PER_UPDATE = 8
local LOAD_ATTEMPTS = 3
local SHUTDOWN_WAIT = 25

local WaypointStore = {}

-- Converts DataStore data back into waypoints, dropping anything malformed.
local function fromStored(value: unknown): { Waypoint }
	local list: { Waypoint } = {}
	if type(value) ~= "table" then
		return list
	end
	for _, entry in value :: { any } do
		if
			type(entry) == "table"
			and type(entry.name) == "string"
			and type(entry.x) == "number"
			and type(entry.y) == "number"
			and type(entry.z) == "number"
			and type(entry.color) == "table"
			and #list < Protocol.MAX_WAYPOINTS
		then
			table.insert(list, {
				name = Protocol.truncateName(entry.name),
				x = math.floor(entry.x),
				y = math.floor(entry.y),
				z = math.floor(entry.z),
				color = {
					math.clamp(tonumber(entry.color[1]) or 255, 0, 255),
					math.clamp(tonumber(entry.color[2]) or 255, 0, 255),
					math.clamp(tonumber(entry.color[3]) or 255, 0, 255),
				},
			})
		end
	end
	return list
end

-- Filters a waypoint name for its owner. Returns nil when filtering failed.
local function filterName(player: Player, name: string): string?
	local ok, result = pcall(function()
		local filtered = TextService:FilterStringAsync(name, player.UserId, Enum.TextFilterContext.PrivateChat)
		return filtered:GetNonChatStringForUserAsync(player.UserId)
	end)
	return if ok and type(result) == "string" then result else nil
end

function WaypointStore.start(net: ServerNet.ServerNet)
	local store: DataStore? = nil
	if Config.Map.SaveWaypoints then
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(STORE_NAME)
		end)
		if ok then
			store = result
		else
			warn(`[IceVoxel] waypoints will not be saved: {result}`)
		end
	end

	local states: { [Player]: State } = {}
	local savesInFlight = 0

	local function key(player: Player): string
		return `player_{player.UserId}`
	end

	-- Saves the list if it changed; keeps saving while it changes during the save.
	local function save(player: Player, state: State)
		if store == nil or not state.canSave or state.saving then
			return
		end
		state.saving = true
		savesInFlight += 1
		while state.dirty do
			state.dirty = false
			local saved = false
			for attempt = 1, 2 do
				local ok, err = pcall(function()
					(store :: DataStore):SetAsync(key(player), state.list, { player.UserId })
				end)
				if ok then
					saved = true
					break
				end
				warn(`[IceVoxel] could not save waypoints of {player.Name} (attempt {attempt}): {err}`)
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

	-- Called when a player left and no update is being filtered for them anymore.
	local function finish(player: Player, state: State)
		save(player, state)
		if states[player] == state then
			states[player] = nil
		end
	end

	local function onPlayer(player: Player)
		local state: State = {
			list = {},
			filtered = {},
			latest = 0,
			loaded = false,
			canSave = store ~= nil,
			dirty = false,
			saving = false,
			leaving = false,
			busy = 0,
			updateTimes = {},
			pending = nil,
			pendingScheduled = false,
		}
		states[player] = state

		if store then
			local loaded = false
			for attempt = 1, LOAD_ATTEMPTS do
				local ok, value = pcall(function()
					return (store :: DataStore):GetAsync(key(player))
				end)
				if ok then
					state.list = fromStored(value)
					loaded = true
					break
				end
				warn(`[IceVoxel] could not load waypoints of {player.Name} (attempt {attempt}): {value}`)
				task.wait(2 ^ attempt)
			end
			if not loaded then
				-- Never overwrite what is stored with a list we could not merge with.
				state.canSave = false
				warn(`[IceVoxel] waypoints of {player.Name} are session-only this time`)
			end
		end
		if states[player] ~= state then
			return
		end
		-- Stored names were filtered when they were saved.
		for _, waypoint in state.list do
			state.filtered[waypoint.name] = waypoint.name
		end
		state.loaded = true
		net.send(player, Protocol.ServerMessage.Waypoints, Protocol.encodeWaypoints(state.list, 0))
	end

	local function apply(player: Player, state: State, payload: buffer)
		local list, revision = Protocol.decodeWaypoints(payload)
		if list == nil or revision <= state.latest then
			return
		end
		local newNames = 0
		for _, waypoint in list do
			if state.filtered[waypoint.name] == nil then
				newNames += 1
			end
		end
		if newNames > NEW_NAMES_PER_UPDATE then
			return
		end
		state.latest = revision

		-- Filter new names (this yields). Any failure rejects the whole update; the client sends
		-- its list again with its next change.
		state.busy += 1
		local names: { [string]: string } = {}
		local failed = false
		for _, waypoint in list do
			local raw = waypoint.name
			if names[raw] == nil then
				local filtered = state.filtered[raw] or filterName(player, raw)
				if filtered == nil then
					failed = true
					break
				end
				names[raw] = filtered
			end
		end
		state.busy -= 1

		-- Apply only if no newer update arrived while filtering.
		if not failed and revision == state.latest then
			local changed = false
			for _, waypoint in list do
				local filtered = names[waypoint.name]
				if filtered ~= waypoint.name then
					changed = true
				end
				waypoint.name = filtered
			end
			state.list = list
			state.filtered = {}
			for raw, filtered in names do
				state.filtered[raw] = filtered
				state.filtered[filtered] = filtered
			end
			state.dirty = true
			if changed and not state.leaving then
				net.send(player, Protocol.ServerMessage.Waypoints, Protocol.encodeWaypoints(list, revision))
			end
		end
		if state.leaving and state.busy == 0 then
			finish(player, state)
		end
	end

	local function receive(player: Player, payload: buffer)
		local state = states[player]
		if state == nil or not state.loaded or state.leaving then
			return
		end
		-- Rate limit, but keep the newest update and apply it once the window allows.
		local now = os.clock()
		local times = state.updateTimes
		while times[1] and now - times[1] > 60 do
			table.remove(times, 1)
		end
		if #times >= UPDATES_PER_MINUTE then
			state.pending = payload
			if not state.pendingScheduled then
				state.pendingScheduled = true
				task.delay(60 - (now - times[1]) + 0.1, function()
					state.pendingScheduled = false
					local latest = state.pending
					state.pending = nil
					if latest and states[player] == state then
						receive(player, latest)
					end
				end)
			end
			return
		end
		table.insert(times, now)
		apply(player, state, payload)
	end

	net.on(Protocol.ClientMessage.SaveWaypoints, receive)

	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		local state = states[player]
		if state == nil then
			return
		end
		state.leaving = true
		if state.busy == 0 then
			finish(player, state)
		end
	end)

	game:BindToClose(function()
		-- Save everything that is not being filtered; updates still filtering are saved as soon
		-- as they finish (their players are leaving) or by a later pass of this loop.
		local started = os.clock()
		repeat
			local waiting = savesInFlight > 0
			for player, state in states do
				if state.busy > 0 then
					waiting = true
				elseif state.dirty and state.canSave and not state.saving then
					task.spawn(save, player, state)
					waiting = waiting or state.dirty
				end
			end
			if waiting or savesInFlight > 0 then
				task.wait(0.2)
			end
		until (savesInFlight == 0 and not waiting) or os.clock() - started > SHUTDOWN_WAIT
	end)
end

return WaypointStore

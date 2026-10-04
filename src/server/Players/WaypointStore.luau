--!strict
--[[
	Keeps every player's map waypoints and, when Config.Map.SaveWaypoints is on, saves them in a
	DataStore between sessions.

	The client owns the list and sends the whole list (with a revision number) after changes. The
	server:
	  * loads the saved list on join (retrying); if loading fails the session's waypoints are never
	    saved, so a DataStore hiccup can not wipe a player's saved waypoints,
	  * keeps only the newest list it received, ignoring older revisions,
	  * text-filters names it has not seen before, one list at a time per player. Filtered names are
	    cached, so a list that is replaced or fails half way never has to filter the same name
	    twice. A token bucket limits how many names a player can have filtered per minute; lists
	    with more new names simply take longer. A failed filter call is retried with backoff,
	  * sends the list back (with its revision) when filtering changed a name,
	  * saves on leave and on shutdown. Names that could not be filtered by then are replaced by
	    "Waypoint" so the positions are still kept.
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
	-- Revision of `list`, and the highest revision received.
	revision: number,
	received: number,
	-- Newest list waiting to be filtered and applied.
	pending: { Waypoint }?,
	-- Raw name -> filtered name (filtered names map to themselves). Survives replaced and failed
	-- updates; trimmed to the current list when it grows large.
	names: { [string]: string },
	cached: number,
	-- Name filter budget.
	tokens: number,
	refilled: number,
	working: boolean,
	loaded: boolean,
	canSave: boolean,
	dirty: boolean,
	saving: boolean,
	leaving: boolean,
}

local STORE_NAME = "IceVoxelWaypoints_v1"
local LOAD_ATTEMPTS = 3
local SHUTDOWN_WAIT = 25
-- Names a player can have filtered at once, and per second after that.
local FILTER_BURST = 20
local FILTER_RATE = 0.5
local MAX_CACHED = 4 * Protocol.MAX_WAYPOINTS
local MAX_RETRY_DELAY = 30
local PLACEHOLDER = "Waypoint"

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

local function remember(state: State, raw: string, filtered: string)
	if state.names[raw] == nil then
		state.cached += 1
	end
	state.names[raw] = filtered
	if state.names[filtered] == nil then
		state.cached += 1
		state.names[filtered] = filtered
	end
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
	local closing = false

	local function key(player: Player): string
		return `player_{player.UserId}`
	end

	-- No more waiting for filter budget or retries: the player is leaving or the server closing.
	local function hurry(state: State): boolean
		return state.leaving or closing
	end

	-- Waits up to `seconds`, returning early when in a hurry or when a newer list than `list` arrived.
	local function pause(state: State, seconds: number, list: { Waypoint }?)
		local until_ = os.clock() + seconds
		while os.clock() < until_ and not hurry(state) and state.pending == list do
			task.wait(math.min(0.25, until_ - os.clock()))
		end
	end

	-- Takes one name from the filter budget, waiting for it unless in a hurry.
	local function takeToken(state: State): boolean
		while true do
			local now = os.clock()
			state.tokens = math.min(FILTER_BURST, state.tokens + (now - state.refilled) * FILTER_RATE)
			state.refilled = now
			if state.tokens >= 1 then
				state.tokens -= 1
				return true
			end
			if hurry(state) then
				return false
			end
			pause(state, (1 - state.tokens) / FILTER_RATE, state.pending)
		end
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

	-- Called when a player left and their last list has been applied.
	local function finish(player: Player, state: State)
		save(player, state)
		if states[player] == state then
			states[player] = nil
		end
	end

	-- Makes `list` (revision `revision`) the player's list, with filtered names.
	local function apply(player: Player, state: State, list: { Waypoint }, revision: number)
		local raws: { string } = {}
		local changed = false
		for i, waypoint in list do
			raws[i] = waypoint.name
			local filtered = state.names[waypoint.name] or PLACEHOLDER
			if filtered ~= waypoint.name then
				changed = true
			end
			waypoint.name = filtered
		end
		state.list, state.revision = list, revision
		state.dirty = true
		if state.cached > MAX_CACHED then
			state.names, state.cached = {}, 0
			for i, waypoint in list do
				remember(state, raws[i], waypoint.name)
			end
		end
		if changed and not state.leaving then
			net.send(player, Protocol.ServerMessage.Waypoints, Protocol.encodeWaypoints(list, revision))
		end
	end

	-- Filters and applies pending lists until there are none; one worker per player at a time.
	local function work(player: Player, state: State)
		state.working = true
		local failures = 0
		while state.pending do
			local list = state.pending :: { Waypoint }
			local revision = state.received
			local complete = true
			for _, waypoint in list do
				if state.pending ~= list then
					break -- a newer list arrived: start over with it (finished names stay cached)
				end
				local raw = waypoint.name
				if state.names[raw] == nil then
					local filtered = if takeToken(state) then filterName(player, raw) else nil
					if filtered == nil then
						complete = false
						break
					end
					remember(state, raw, filtered)
				end
			end
			if state.pending == list then
				if complete or hurry(state) then
					state.pending = nil
					failures = 0
					apply(player, state, list, revision)
				else
					failures += 1
					pause(state, math.min(2 ^ failures, MAX_RETRY_DELAY), list)
				end
			end
		end
		state.working = false
		if state.leaving then
			finish(player, state)
		end
	end

	local function onPlayer(player: Player)
		local state: State = {
			list = {},
			revision = 0,
			received = 0,
			pending = nil,
			names = {},
			cached = 0,
			tokens = FILTER_BURST,
			refilled = os.clock(),
			working = false,
			loaded = false,
			canSave = store ~= nil,
			dirty = false,
			saving = false,
			leaving = false,
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
			remember(state, waypoint.name, waypoint.name)
		end
		state.loaded = true
		net.send(player, Protocol.ServerMessage.Waypoints, Protocol.encodeWaypoints(state.list, 0))
	end

	net.on(Protocol.ClientMessage.SaveWaypoints, function(player: Player, payload: buffer)
		local state = states[player]
		if state == nil or not state.loaded or state.leaving then
			return
		end
		local list, revision = Protocol.decodeWaypoints(payload)
		if list == nil or revision <= state.received then
			return
		end
		state.pending, state.received = list, revision
		if not state.working then
			task.spawn(work, player, state)
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
		state.leaving = true
		-- A running worker applies what is pending (without waiting) and then finishes.
		if not state.working then
			finish(player, state)
		end
	end)

	game:BindToClose(function()
		closing = true
		local started = os.clock()
		repeat
			local waiting = savesInFlight > 0
			for player, state in states do
				if state.working then
					waiting = true
				elseif state.dirty and state.canSave and not state.saving then
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

return WaypointStore

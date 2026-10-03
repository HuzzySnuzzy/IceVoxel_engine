--!strict
--[[
	Keeps every player's map waypoints and, when Config.Map.SaveWaypoints is on, saves them in a
	DataStore between sessions.

	The client owns the list (it sends the whole list after every change); the server validates
	it, filters the names (they are only ever shown to their owner, but are stored), and sends the
	saved list to the player when they join. Without DataStore access (e.g. Studio without API
	services) waypoints still work for the session.
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

local STORE_NAME = "IceVoxelWaypoints_v1"
local SAVES_PER_MINUTE = 30

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

local function filterName(player: Player, name: string): string
	local ok, result = pcall(function()
		local filtered = TextService:FilterStringAsync(name, player.UserId, Enum.TextFilterContext.PrivateChat)
		return filtered:GetNonChatStringForUserAsync(player.UserId)
	end)
	return if ok and type(result) == "string" then result else "Waypoint"
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

	local lists: { [Player]: { Waypoint } } = {}
	local loaded: { [Player]: boolean } = {}
	local dirty: { [Player]: boolean } = {}
	local filteredNames: { [Player]: { [string]: string } } = {}
	local saveTimes: { [Player]: { number } } = {}

	local function key(player: Player): string
		return `player_{player.UserId}`
	end

	local function save(player: Player)
		local list = lists[player]
		if store == nil or list == nil or not dirty[player] then
			return
		end
		dirty[player] = nil
		local ok, err = pcall(function()
			(store :: DataStore):SetAsync(key(player), list, { player.UserId })
		end)
		if not ok then
			warn(`[IceVoxel] could not save waypoints of {player.Name}: {err}`)
		end
	end

	local function onPlayer(player: Player)
		local list: { Waypoint } = {}
		if store then
			local ok, value = pcall(function()
				return (store :: DataStore):GetAsync(key(player))
			end)
			if ok then
				list = fromStored(value)
			else
				warn(`[IceVoxel] could not load waypoints of {player.Name}: {value}`)
			end
		end
		if player.Parent == nil then
			return
		end
		lists[player] = list
		filteredNames[player] = {}
		saveTimes[player] = {}
		loaded[player] = true
		net.send(player, Protocol.ServerMessage.Waypoints, Protocol.encodeWaypoints(list))
	end

	net.on(Protocol.ClientMessage.SaveWaypoints, function(player: Player, payload: buffer)
		if not loaded[player] then
			return
		end
		-- Simple rate limit: at most SAVES_PER_MINUTE updates in any 60 seconds.
		local now = os.clock()
		local times = saveTimes[player]
		while times[1] and now - times[1] > 60 do
			table.remove(times, 1)
		end
		if #times >= SAVES_PER_MINUTE then
			return
		end
		table.insert(times, now)

		local list = Protocol.decodeWaypoints(payload)
		if list == nil then
			return
		end
		local cache = filteredNames[player]
		local changed = false
		for _, waypoint in list do
			local filtered = cache[waypoint.name]
			if filtered == nil then
				filtered = filterName(player, waypoint.name)
				cache[waypoint.name] = filtered
			end
			if filtered ~= waypoint.name then
				waypoint.name = filtered
				changed = true
			end
		end
		if player.Parent == nil then
			return
		end
		lists[player] = list
		dirty[player] = true
		if changed then
			-- Show the player the filtered names.
			net.send(player, Protocol.ServerMessage.Waypoints, Protocol.encodeWaypoints(list))
		end
	end)

	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		save(player)
		lists[player] = nil
		loaded[player] = nil
		dirty[player] = nil
		filteredNames[player] = nil
		saveTimes[player] = nil
	end)

	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			task.spawn(save, player)
		end
		task.wait(2)
	end)
end

return WaypointStore

--!strict
--[[
	Sends each player the other players they may see (Config.Players.ServerPositions: the
	server's own positions, Players/PlayerPositions; nothing with the switch off, when characters
	still replicate where everyone is).

	Every 1 / Config.Interest.RelayRate seconds (20 a second), on Heartbeat:
	  1. who is alive (the Humanoids: the poses' Dead flag) and where spectators are (their
	     target's place: Players/PositionStore.follow);
	  2. for every player in the world, who they see now (Players/Interest.update: distance with
	     hysteresis, spectators, the player they spectate): changes go in one reliable Players
	     message (Net/PlayerSync: untracks by slot, tracks with the whole pose and game mode,
	     at most PlayerSync.MAX_CHANGES each);
	  3. the poses due (Interest.due: changed since last sent, else every KeepAliveSeconds) in
	     unreliable Poses messages on Net/Remotes.moves() (at most PlayerSync.MAX_POSES each, 22
	     bytes a pose: under the 1000 bytes Roblox allows), stamped with the relay's tick (u16).
	A message lost on the unreliable remote is replaced by the next change or keepalive; a pose for
	a slot the client hasn't tracked yet (the remotes aren't ordered together) is ignored by it.

	Positions are world blocks on the wire; each client converts with its own render origin.
	Cost: viewers x players distance checks a tick (trivial below 50 players); about 22 bytes a
	moving player a tick per viewer who sees them.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local PlayerSync = require(Shared.Net.PlayerSync)
local Protocol = require(Shared.Net.Protocol)
local Remotes = require(Shared.Net.Remotes)

local Interest = require(script.Parent.Interest)
local PlayerPositions = require(script.Parent.PlayerPositions)
local PositionStore = require(script.Parent.PositionStore)

type Record = PositionStore.Record

-- What PlayerRelay sends through: Network/ServerNet's `send` (reliable).
type Net = { send: (player: Player, kind: number, payload: buffer) -> () }

local PlayerRelay = {}

local started = false

-- A track of `record` (its whole pose, game mode and user).
local function track(record: Record): PlayerSync.Track
	local player = record.key :: Player
	return {
		slot = record.slot,
		userId = player.UserId,
		mode = record.mode,
		x = record.x,
		y = record.y,
		z = record.z,
		yaw = record.yaw,
		pitch = record.pitch,
		tilt = record.tilt,
		flags = record.flags,
		speed = record.speed,
		climb = record.climb,
	}
end

-- Sends `viewer` the tracks and untracks, in messages of at most MAX_CHANGES.
local function sendChanges(net: Net, viewer: Player, tracks: { Record }, untracks: { number })
	local limit = PlayerSync.MAX_CHANGES
	local message: PlayerSync.Players = { tracks = {}, untracks = {} }
	local count = 0
	local function flush()
		if count > 0 then
			net.send(viewer, Protocol.ServerMessage.Players, PlayerSync.encodePlayers(message))
			message = { tracks = {}, untracks = {} }
			count = 0
		end
	end
	-- (Untracks first: a rejoined player's new slot after its old one.)
	for _, slot in untracks do
		table.insert(message.untracks, slot)
		count += 1
		if count >= limit then
			flush()
		end
	end
	for _, record in tracks do
		table.insert(message.tracks, track(record))
		count += 1
		if count >= limit then
			flush()
		end
	end
	flush()
end

-- Starts relaying (after Players/PlayerPositions; does nothing while it reads characters).
function PlayerRelay.start(net: Net)
	local store = PlayerPositions.store()
	if started or store == nil then
		return
	end
	started = true
	local moves = Remotes.moves()
	local interval = 1 / math.max(1, Config.Interest.RelayRate)
	local accumulator = 0
	local tick = 0
	-- Per viewer: who they see and what they were last sent of them (Interest.Seen).
	local seen: { [Player]: { [any]: Interest.Seen } } = {}
	-- Reused every tick (no garbage once warm).
	local tracks: { Record } = {}
	local untracks: { number } = {}
	local due: { Record } = {}

	Players.PlayerRemoving:Connect(function(player: Player)
		seen[player] = nil
	end)

	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < interval then
			return
		end
		-- (One relay a frame at most; a long hitch doesn't make a burst.)
		accumulator = math.min(accumulator - interval, interval)
		tick = PlayerSync.nextU16(tick)
		local now = os.clock()
		local records = store.records
		for key in records do
			local player = key :: Player
			store:setAlive(player, PlayerPositions.alive(player))
		end
		store:follow()
		for key, record in records do
			local viewer = key :: Player
			if record.gone or viewer.Parent == nil then
				continue
			end
			local mine = seen[viewer]
			if mine == nil then
				mine = {}
				seen[viewer] = mine
			end
			table.clear(tracks)
			table.clear(untracks)
			Interest.update(records, record, mine, now, tracks, untracks)
			if #tracks > 0 or #untracks > 0 then
				sendChanges(net, viewer, tracks, untracks)
			end
			local n = Interest.due(records, mine, now, due)
			local first = 1
			while first <= n do
				local count = math.min(PlayerSync.MAX_POSES, n - first + 1)
				-- (Records carry every field of a pose, slot included.)
				moves:FireClient(viewer, PlayerSync.encodePoses(tick, due :: any, first, count))
				first += count
			end
		end
	end)
end

return PlayerRelay

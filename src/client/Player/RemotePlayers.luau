--!strict
--[[
	The other players this client knows about, and where they are: the one place client code asks
	for another player's position (world blocks, Luau doubles), never their Roblox character's
	parts (the same API as server Players/PlayerPositions).

	Two sources, one API:
	  compat     (Config.Players.ServerPositions false, as today): every other player with a
	             character is tracked, read from it when asked (Rig.feet, the root's facing and
	             lean, its replicated velocity, the Humanoid's health): exactly what consumers read
	             before.
	  networked  (ServerPositions true): the server tracks and untracks players by interest
	             (Net/PlayerSync Players messages: within Config.Interest.PlayerDistance, spectators
	             only for spectators), poses arrive 20 a second on Net/Remotes.moves() and are drawn
	             InterpolationDelay behind (Player/RemoteMotion); characters stand parked on the
	             server and each client places them itself (`Rig.rootCFrame` at
	             `Origin.blocksToRender` of the record, a render step after the origin's). Built
	             on top of this API; until then the switch reads the characters too.

	API (positions are feet, the bottom centre of the body, in world blocks):
	  get(player) -> Remote?            nil: not tracked (no character; later: beyond interest, an
	                                    invisible spectator...)
	  feet(player) -> (x?, y, z)
	  hull(player) -> (min?, max?)      the standing hull, blocks (Rig.hull's drop-in)
	  each() -> iterator                for player, remote in RemotePlayers.each()
	  isTracked(player) -> boolean
	  onTracked(fn) -> disconnect       fn(player, tracked) when a player starts or stops being
	                                    tracked
	  start()                           once, in the world (before MovementController)

	A Remote is one table per player, refreshed in place when asked (get / each): read it then,
	don't keep it across frames. No services are touched before `start` (specs load this module).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local PlayerSync = require(Shared.Net.PlayerSync)
local Rig = require(Shared.Movement.Rig)

local BLOCK = Config.BlockSize
local STANDING = PlayerPhysics.STANDING

export type Remote = {
	player: Player,
	character: Model?,
	-- Feet (world blocks, doubles), interpolated for this frame.
	x: number,
	y: number,
	z: number,
	-- Facing and view (radians), how far the body lies (0..1), PlayerSync.Flag bits, horizontal and
	-- vertical speed (blocks a second).
	yaw: number,
	pitch: number,
	tilt: number,
	flags: number,
	speed: number,
	climb: number,
	alive: boolean,
}

local RemotePlayers = {}

-- Tracked players' records, and the listeners of `onTracked`.
local records: { [Player]: Remote } = {}
local listeners: { (player: Player, tracked: boolean) -> () } = {}
local started = false

local function notify(player: Player, tracked: boolean)
	for _, listener in table.clone(listeners) do
		task.spawn(listener, player, tracked)
	end
end

--[[ compat: the characters, as before ]]

local function track(player: Player, character: Model?)
	local record = records[player]
	if character == nil then
		if record then
			records[player] = nil
			notify(player, false)
		end
		return
	end
	if record then
		record.character = character
		return
	end
	records[player] = {
		player = player,
		character = character,
		x = 0,
		y = 0,
		z = 0,
		yaw = 0,
		pitch = 0,
		tilt = 0,
		flags = 0,
		speed = 0,
		climb = 0,
		alive = true,
	}
	notify(player, true)
end

-- Reads a tracked player's character into their record: false when it has no root (nothing to
-- read; the record keeps its last values).
local function refresh(record: Remote): boolean
	local character = record.character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if character == nil or root == nil or not root:IsA("BasePart") then
		return false
	end
	local feet = Rig.feet(character)
	if feet == nil then
		return false
	end
	local cframe = root.CFrame
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local alive = humanoid ~= nil and humanoid.Health > 0
	local velocity = root.AssemblyLinearVelocity
	record.x, record.y, record.z = feet.X, feet.Y, feet.Z
	record.yaw = Rig.yaw(cframe)
	-- (The view's pitch never replicated; the body's lean is the root's, as Rig.feet reads it.)
	record.pitch = 0
	record.tilt = math.clamp(math.acos(math.clamp(cframe.UpVector.Y, -1, 1)) / (math.pi / 2), 0, 1)
	record.flags = if alive then 0 else PlayerSync.Flag.Dead
	record.speed = math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z) / BLOCK
	record.climb = velocity.Y / BLOCK
	record.alive = alive
	return true
end

--[[ The API ]]

function RemotePlayers.get(player: Player): Remote?
	local record = records[player]
	if record == nil or not refresh(record) then
		return nil
	end
	return record
end

function RemotePlayers.feet(player: Player): (number?, number, number)
	local record = RemotePlayers.get(player)
	if record == nil then
		return nil, 0, 0
	end
	return record.x, record.y, record.z
end

-- The standing hull (world blocks): min and max corners, or nil, nil.
function RemotePlayers.hull(player: Player): (Vector3?, Vector3?)
	local x, y, z = RemotePlayers.feet(player)
	if x == nil then
		return nil, nil
	end
	local half = STANDING.width / 2
	return Vector3.new(x - half, y, z - half), Vector3.new(x + half, y + STANDING.height, z + half)
end

-- Every tracked player with a position: `for player, remote in RemotePlayers.each() do`.
function RemotePlayers.each(): () -> (Player?, Remote)
	local key: Player? = nil
	return function(): (Player?, Remote)
		while true do
			local player, record = next(records, key)
			key = player
			if player == nil or record == nil then
				return nil, (nil :: any) :: Remote
			end
			if refresh(record) then
				return player, record
			end
		end
	end
end

function RemotePlayers.isTracked(player: Player): boolean
	return records[player] ~= nil
end

-- Calls fn(player, tracked) whenever a player starts or stops being tracked; returns its
-- disconnect.
function RemotePlayers.onTracked(fn: (player: Player, tracked: boolean) -> ()): () -> ()
	table.insert(listeners, fn)
	return function()
		local index = table.find(listeners, fn)
		if index then
			table.remove(listeners, index)
		end
	end
end

function RemotePlayers.start()
	if started then
		return
	end
	started = true
	if Config.Players.ServerPositions then
		warn("[IceVoxel] Config.Players.ServerPositions: relayed positions aren't built yet; reading characters")
	end
	local Players = game:GetService("Players")
	local localPlayer = Players.LocalPlayer
	local function watch(player: Player)
		if player == localPlayer then
			return
		end
		player.CharacterAdded:Connect(function(character)
			track(player, character)
		end)
		player.CharacterRemoving:Connect(function(character)
			if records[player] and records[player].character == character then
				track(player, nil)
			end
		end)
		if player.Character then
			track(player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(function(player)
		track(player, nil)
	end)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
end

return RemotePlayers

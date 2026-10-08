--!strict
--[[
	The other players this client knows about, and where they are: the one place client code asks
	for another player's position (world blocks, Luau doubles), never their Roblox character's
	parts (the same API as server Players/PlayerPositions).

	Two sources, one API:
	  compat     (Config.Players.ServerPositions false, as before): every other player with a
	             character is tracked, read from it when asked (Rig.feet, the root's facing and
	             lean, its replicated velocity, the Humanoid's health): exactly what consumers read
	             before.
	  networked  (ServerPositions true: "fake coords"): every character stands parked on the
	             server (Config.Players.ParkPosition), so nothing replicated says where anyone is.
	             The server tracks and untracks players for this client by interest (server
	             Players/Interest: within Config.Interest.PlayerDistance, spectators only for
	             spectators, the player spectated always) in reliable Players messages (Net/
	             PlayerSync: slot, user, whole pose; untracks by slot), and relays their poses
	             about 20 times a second on the unreliable Net/Remotes.moves() (Poses, stamped
	             with the relay's tick). Each tracked player is drawn InterpolationDelay (0.1 s)
	             behind the server, between the poses around that moment (Player/RemoteMotion:
	             the server clock from the ticks, glide, short extrapolation, snaps on teleports);
	             poses of slots not tracked (yet) are dropped, as the two remotes aren't ordered
	             together.
	             Placement: a render step ("IceVoxelRemotePlayers", Camera - 2: after the origin's
	             at Camera - 3, before the local character's and the camera, which may follow a
	             spectated player) puts each tracked character's (anchored) root where its pose
	             says, in render studs (`Rig.rootCFrame` at `Origin.blocksToRender` of the feet:
	             the client's own frame, a write that never replicates). A dead player (the pose's
	             Dead flag) falls over as Minecraft's LivingEntityRenderer turns them (`Rig.
	             deathCFrame`, 20 ticks), and after DEATH_SECONDS their body is no longer shown
	             (`shown`; Player/SpectatorView hides it, as it hides untracked players, who stay
	             parked: an untracked character's root is written back to the park, since this
	             client's last write to it would stay otherwise, in render studs that mean
	             another place after every move of the origin).

	API (positions are feet, the bottom centre of the body, in world blocks):
	  get(player) -> Remote?            nil: not tracked (compat: no character; networked: beyond
	                                    interest, an invisible spectator, not in the game)
	  feet(player) -> (x?, y, z)
	  hull(player) -> (min?, max?)      the standing hull, blocks (Rig.hull's drop-in)
	  each() -> iterator                for player, remote in RemotePlayers.each()
	  isTracked(player) -> boolean
	  shown(player) -> boolean          should their character be drawn (tracked, and not a body
	                                    gone after its death tilt); compat: always
	  onTracked(fn) -> disconnect       fn(player, tracked) when a player starts or stops being
	                                    tracked
	  networked() -> boolean            are positions the server's relay (started, ServerPositions)?
	  start()                           once, in the world (before MovementController)

	A Remote is one table per player, refreshed in place (compat: when asked; networked: every
	frame by the placement step): read it then, don't keep it across frames. No services are
	touched before `start` (specs load this module).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Origin = require(Shared.World.Origin)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local PlayerSync = require(Shared.Net.PlayerSync)
local Protocol = require(Shared.Net.Protocol)
local Rig = require(Shared.Movement.Rig)

local RemoteMotion = require(script.Parent.RemoteMotion)

local BLOCK = Config.BlockSize
local STANDING = PlayerPhysics.STANDING
local DEAD = PlayerSync.Flag.Dead
local IN_WATER = PlayerSync.Flag.InWater
-- Camera - 2: after the origin's step (Rendering/Rebase, Camera - 3), before the local character's
-- (Camera - 1) and the camera.
local RENDER_STEP = "IceVoxelRemotePlayers"
local RENDER_OFFSET = -2
-- Seconds a dead body is shown (Minecraft removes it at deathTime 20), and a relay tick (the
-- death roll starts one tick in, as Minecraft's (deathTime + partialTick - 1) / 20).
local DEATH_SECONDS = 1
local TICK = 1 / 20

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

-- A tracked slot (networked): the server's slot and user, the player once they are in this
-- client's game too, their record, poses and when they were first drawn dead.
type Entry = {
	slot: number,
	userId: number,
	player: Player?,
	remote: Remote?,
	motion: RemoteMotion.Motion,
	deadAt: number?,
}

local RemotePlayers = {}

-- Tracked players' records, and the listeners of `onTracked`.
local records: { [Player]: Remote } = {}
local listeners: { (player: Player, tracked: boolean) -> () } = {}
local started = false
local relayed = false
local localPlayer: Player? = nil

local function notify(player: Player, tracked: boolean)
	for _, listener in table.clone(listeners) do
		task.spawn(listener, player, tracked)
	end
end

local function newRemote(player: Player, character: Model?): Remote
	return {
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
end

local function rootOf(character: Model?): BasePart?
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
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
	records[player] = newRemote(player, character)
	notify(player, true)
end

-- Reads a tracked player's character into their record: false when it has no root (nothing to
-- read; the record keeps its last values).
local function refresh(record: Remote): boolean
	if relayed then
		-- (The placement step keeps relayed records up to date.)
		return true
	end
	local character = record.character
	local root = rootOf(character)
	if character == nil or root == nil then
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

--[[ networked: the server's relay ]]

local bySlot: { [number]: Entry } = {}
local entryOf: { [Player]: Entry } = {}
local clock = RemoteMotion.newClock()
-- Decoded poses, reused (PlayerSync.decodePoses).
local poses: { PlayerSync.Pose } = {}

-- Draws `entry`'s pose at server time `t` into its record (and the death clock).
local function sample(entry: Entry, remote: Remote, t: number, now: number)
	RemoteMotion.sample(entry.motion, t, remote)
	local dead = bit32.btest(remote.flags, DEAD)
	remote.alive = not dead
	if dead then
		entry.deadAt = entry.deadAt or now
	else
		entry.deadAt = nil
	end
end

local function playbackAt(now: number): number
	-- (No clock yet: the newest pose, held.)
	return RemoteMotion.playback(clock, now) or math.huge
end

-- `entry`'s player is in this client's game: their record exists and they count as tracked.
local function resolve(entry: Entry)
	if entry.player ~= nil then
		return
	end
	local Players = game:GetService("Players")
	local player = Players:GetPlayerByUserId(entry.userId)
	if player == nil or player == localPlayer then
		return
	end
	local previous = entryOf[player]
	if previous and previous ~= entry then
		-- (Tracked under another slot before: that one is gone.)
		bySlot[previous.slot] = nil
		entryOf[player] = nil
	end
	local remote = records[player] or newRemote(player, player.Character)
	remote.character = player.Character
	entry.player, entry.remote = player, remote
	local now = os.clock()
	sample(entry, remote, playbackAt(now), now)
	entryOf[player] = entry
	if records[player] == nil then
		records[player] = remote
		notify(player, true)
	end
end

-- Puts `character`'s root back at the park (Config.Players.ParkPosition, where the server left
-- it): the placement step's last write stays otherwise (the server never writes the anchored
-- root again), and a move of the render origin would carry the hidden body, its chat bubbles
-- with it, to some place near the viewer.
local function park(character: Model?)
	local root = rootOf(character)
	if root then
		local at = Config.Players.ParkPosition
		root.CFrame = CFrame.new(at[1], at[2], at[3])
	end
end

local function untrackSlot(slot: number)
	local entry = bySlot[slot]
	if entry == nil then
		return
	end
	bySlot[slot] = nil
	local remote = entry.remote
	if remote then
		park(remote.character)
	end
	local player = entry.player
	if player and entryOf[player] == entry then
		entryOf[player] = nil
		if records[player] then
			records[player] = nil
			notify(player, false)
		end
	end
end

local function onPlayers(payload: buffer)
	local message = PlayerSync.decodePlayers(payload)
	if message == nil then
		return
	end
	for _, slot in message.untracks do
		untrackSlot(slot)
	end
	local now = os.clock()
	for _, track in message.tracks do
		local entry: Entry? = bySlot[track.slot]
		if entry == nil or entry.userId ~= track.userId then
			-- (A slot taken by someone else: the server untracked them first, or this is news.)
			untrackSlot(track.slot)
			local fresh: Entry = { slot = track.slot, userId = track.userId, motion = RemoteMotion.new() }
			bySlot[track.slot] = fresh
			entry = fresh
		end
		assert(entry, "tracked slot")
		-- (The pose is the server's now: drawn from now on, gliding into the next one.)
		RemoteMotion.place(entry.motion, RemoteMotion.serverNow(clock, now) or -math.huge, track)
		local remote = entry.remote
		if remote then
			sample(entry, remote, playbackAt(now), now)
		else
			resolve(entry)
		end
	end
end

local function onPoses(payload: unknown)
	if typeof(payload) ~= "buffer" then
		return
	end
	local tick, n = PlayerSync.decodePoses(payload, poses)
	if tick == nil then
		return
	end
	local t = RemoteMotion.observe(clock, tick, os.clock())
	for i = 1, n do
		local pose = poses[i]
		local entry = bySlot[pose.slot]
		if entry then
			RemoteMotion.push(entry.motion, t, pose)
		end
	end
end

-- The placement step (see the header): every tracked character where its pose says.
local function place()
	local now = os.clock()
	local t = playbackAt(now)
	for _, entry in entryOf do
		local remote = entry.remote
		if remote == nil then
			continue
		end
		sample(entry, remote, t, now)
		local character = remote.character
		local root = rootOf(character)
		if character == nil or root == nil then
			continue
		end
		-- (The body lies face down crawling, along the view swimming: MovementController's.)
		local bodyPitch = if bit32.btest(remote.flags, IN_WATER)
			then math.clamp(math.pi / 2 - remote.pitch, 0, math.pi)
			else math.pi / 2
		local cframe = Rig.rootCFrame(
			character,
			Origin.blocksToRender(remote.x, remote.y, remote.z),
			remote.yaw,
			remote.tilt,
			bodyPitch
		)
		local deadAt = entry.deadAt
		if deadAt then
			cframe = Rig.deathCFrame(cframe, now - deadAt - TICK, Rig.rootHeight(character, remote.tilt))
		end
		root.CFrame = cframe
	end
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

-- Should `player`'s character be drawn on this client: tracked, and not a body gone after its
-- death tilt (networked); compat: always (characters show where they are, as before).
function RemotePlayers.shown(player: Player): boolean
	if not relayed then
		return true
	end
	local entry = entryOf[player]
	if entry == nil then
		return false
	end
	local deadAt = entry.deadAt
	return deadAt == nil or os.clock() - deadAt < DEATH_SECONDS
end

-- Are other players' positions the server's relay (ServerPositions, started)?
function RemotePlayers.networked(): boolean
	return relayed
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

-- The networked backend's connections (see the header).
local function listen(Players: Players)
	relayed = true
	-- (Required here: they find the remotes, which specs loading this module don't have.)
	local ClientNet = require(script.Parent.Parent.Net.ClientNet)
	local Remotes = require(Shared.Net.Remotes)
	ClientNet.on(Protocol.ServerMessage.Players, onPlayers)
	Remotes.moves().OnClientEvent:Connect(onPoses)
	-- (A tracked player's record follows their character; it is placed from the next frame.)
	local function watch(player: Player)
		player.CharacterAdded:Connect(function(character: Model)
			local record = records[player]
			if record then
				record.character = character
			end
		end)
		player.CharacterRemoving:Connect(function(character: Model)
			local record = records[player]
			if record and record.character == character then
				record.character = nil
			end
		end)
	end
	Players.PlayerAdded:Connect(function(player: Player)
		watch(player)
		-- (Tracked before this client heard of them: the record starts now.)
		for _, entry in bySlot do
			if entry.player == nil and entry.userId == player.UserId then
				resolve(entry)
			end
		end
	end)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		local entry = entryOf[player]
		if entry then
			untrackSlot(entry.slot)
		end
	end)
	local RunService = game:GetService("RunService")
	RunService:BindToRenderStep(RENDER_STEP, Enum.RenderPriority.Camera.Value + RENDER_OFFSET, place)
end

function RemotePlayers.start()
	if started then
		return
	end
	started = true
	local Players = game:GetService("Players")
	localPlayer = Players.LocalPlayer
	if Config.Players.ServerPositions then
		listen(Players)
		return
	end
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

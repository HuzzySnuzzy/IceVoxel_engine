--!strict
--[[
	The local player's side of the server's own positions (Config.Players.ServerPositions: "fake
	coords", server Players/PlayerPositions): the character stands parked and anchored on the
	server, so where this player is reaches the server only from here, and the server's teleports
	reach Player/MovementController only through here.

	  Teleport  the server's private Teleport message (Net/PlayerSync: epoch, life, feet in world
	            blocks as doubles, yaw or keep, reason spawn / teleport / correction) is kept as
	            the newest (`latest`) and told to `onTeleport`'s listeners. The movement snaps the
	            hull to it and then `adopt`s its epoch: until then the server drops this client's
	            moves (they carry the old one), as Minecraft's server waits for the teleport's
	            confirmation (awaitingPositionFromClient).
	  Life      a new character's IceVoxelLife attribute (Rig.LIFE, set by the server's
	            Characters.park) counts characters; the Teleport carrying the same life is the one
	            that placed it (`placing`). The attribute and the message travel separately (an
	            attribute change and a remote event are not ordered), so either may come first:
	            the movement keeps asking until both agree.
	  Move      `send` after the movement's ticks, at most Config.Players.MoveRate (20) a second,
	            on the unreliable Net/Remotes.moves(): the newest tick's hull (f64 feet), yaw, look
	            pitch, tilt, flags, speed and climb, the adopted epoch and a u16 sequence number.
	            An unchanged pose goes again only every KEEPALIVE seconds (one lost on the way is
	            then made good); nothing while frozen (waiting for the ground: the server has the
	            teleport's place), while spectating (the server follows the target) or before a
	            Teleport was adopted.
	  Spectate  `spectate(target)` tells the server whom this spectator follows (ClientMessage
	            .Spectate, 0: nobody), so it keeps the target in this player's interest and their
	            chunks allowed.

	The rules are a pure core (`newCore`, `receive`, `placing`, `adopt`, `step`, `flags`:
	tests/spec/LocalPosition); `start`, `send` and `spectate` are the glue around one core.
	Nothing is connected or sent with the switch off.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local PlayerSync = require(Shared.Net.PlayerSync)
local Protocol = require(Shared.Net.Protocol)

local LocalPosition = {}

-- Seconds an unchanged pose waits before it is sent again.
LocalPosition.KEEPALIVE = 1
-- Seconds after a jump the pose says "jumped" (the jump animation: CharacterAnimator's JUMP_TIME).
LocalPosition.JUMP_TIME = 0.31

local Flag = PlayerSync.Flag

-- The pose `step` sends: feet (world blocks, doubles), yaw (as CFrame.Angles(0, yaw, 0)), look
-- pitch (radians, up positive), tilt (0..1), Flag bits, speed and climb (blocks a second).
export type Pose = {
	x: number,
	y: number,
	z: number,
	yaw: number,
	pitch: number,
	tilt: number,
	flags: number,
	speed: number,
	climb: number,
}

export type Core = {
	-- The newest Teleport the server sent (any life).
	latest: PlayerSync.Teleport?,
	-- The epoch moves carry, once a Teleport was adopted (the hull snapped to it).
	epoch: number,
	adopted: boolean,
	-- The next move's sequence number (u16).
	seq: number,
	-- os.clock() seconds: when the next move may go, and when the last one went.
	nextAt: number,
	sentAt: number,
	-- The move last sent (its pose: to skip an unchanged one), and the one being built.
	sent: PlayerSync.Move,
	move: PlayerSync.Move,
}

local function newMove(): PlayerSync.Move
	return { seq = 0, epoch = 0, x = 0, y = 0, z = 0, yaw = 0, pitch = 0, tilt = 0, flags = 0, speed = 0, climb = 0 }
end

--[[ The core (pure) ]]

function LocalPosition.newCore(): Core
	return {
		latest = nil,
		epoch = 0,
		adopted = false,
		seq = 0,
		nextAt = -math.huge,
		sentAt = -math.huge,
		sent = newMove(),
		move = newMove(),
	}
end

-- A Teleport from the server: the newest (the reliable remote keeps them in order).
function LocalPosition.receive(core: Core, teleport: PlayerSync.Teleport)
	core.latest = teleport
end

--[[
	The Teleport that placed a character of life `life` (its IceVoxelLife attribute; nil: not
	known yet): the newest one when it carries that life (a later one of the same life, a teleport
	or a correction, replaces it), else nil (it is still on its way, or belongs to another
	character).
]]
function LocalPosition.placing(core: Core, life: number?): PlayerSync.Teleport?
	local teleport = core.latest
	if teleport == nil or life == nil or teleport.life ~= life % 65536 then
		return nil
	end
	return teleport
end

-- The hull snapped to `teleport`: moves carry its epoch from now on.
function LocalPosition.adopt(core: Core, teleport: PlayerSync.Teleport)
	core.epoch = teleport.epoch
	core.adopted = true
	-- (Due at once: the server learns the first position of the new epoch.)
	core.nextAt = -math.huge
end

-- The pose's Flag bits from a hull (PlayerPhysics.State's fields), whether it jumped lately and
-- whether the player is dead.
function LocalPosition.flags(
	state: {
		sneaking: boolean,
		sprinting: boolean,
		flying: boolean,
		onGround: boolean,
		inWater: boolean,
		climbing: boolean,
	},
	jumped: boolean,
	dead: boolean
): number
	local flags = 0
	if state.sneaking then
		flags += Flag.Sneaking
	end
	if state.sprinting then
		flags += Flag.Sprinting
	end
	if state.flying then
		flags += Flag.Flying
	end
	if state.onGround then
		flags += Flag.OnGround
	end
	if state.inWater then
		flags += Flag.InWater
	end
	if state.climbing then
		flags += Flag.Climbing
	end
	if jumped then
		flags += Flag.Jumped
	end
	if dead then
		flags += Flag.Dead
	end
	return flags
end

local function samePose(a: PlayerSync.Move, b: Pose): boolean
	return a.x == b.x
		and a.y == b.y
		and a.z == b.z
		and a.yaw == b.yaw
		and a.pitch == b.pitch
		and a.tilt == b.tilt
		and a.flags == b.flags
		and a.speed == b.speed
		and a.climb == b.climb
end

--[[
	The move to send at `now` (os.clock seconds) for `pose`, or nil: not before a Teleport was
	adopted, nor while `frozen` or `spectating`, nor sooner than 1 / MoveRate after the last (the
	sends keep their rhythm across frames of any length, but never catch up after a hitch), nor
	an unchanged pose within KEEPALIVE. The Move returned is the core's own (encode it now).
]]
function LocalPosition.step(core: Core, now: number, pose: Pose, frozen: boolean, spectating: boolean): PlayerSync.Move?
	if not core.adopted or frozen or spectating or now < core.nextAt then
		return nil
	end
	if samePose(core.sent, pose) and core.sent.epoch == core.epoch and now - core.sentAt < LocalPosition.KEEPALIVE then
		return nil
	end
	local interval = 1 / math.max(1, Config.Players.MoveRate)
	-- (In rhythm with the sends before, at most one an interval; after a pause or a long frame a
	-- new rhythm from now, never a burst to catch up.)
	core.nextAt = (if core.nextAt < now - interval then now else core.nextAt) + interval
	core.sentAt = now
	local move = core.move
	move.seq, move.epoch = core.seq, core.epoch
	move.x, move.y, move.z = pose.x, pose.y, pose.z
	move.yaw, move.pitch, move.tilt = pose.yaw, pose.pitch, pose.tilt
	move.flags, move.speed, move.climb = pose.flags, pose.speed, pose.climb
	core.seq = PlayerSync.nextU16(core.seq)
	local sent = core.sent
	sent.seq, sent.epoch = move.seq, move.epoch
	sent.x, sent.y, sent.z = move.x, move.y, move.z
	sent.yaw, sent.pitch, sent.tilt = move.yaw, move.pitch, move.tilt
	sent.flags, sent.speed, sent.climb = move.flags, move.speed, move.climb
	return move
end

--[[ The glue: one core for this client ]]

local core = LocalPosition.newCore()
local listeners: { (teleport: PlayerSync.Teleport) -> () } = {}
local moves: UnreliableRemoteEvent? = nil
local sendSpectate: ((userId: number) -> ())? = nil
local started = false

-- Are positions the server's own (Config.Players.ServerPositions) and is this started?
function LocalPosition.active(): boolean
	return moves ~= nil
end

-- The newest Teleport the server sent (nil: none yet).
function LocalPosition.latest(): PlayerSync.Teleport?
	return core.latest
end

-- The Teleport that placed a character of `life` (see `placing`).
function LocalPosition.placingFor(life: number?): PlayerSync.Teleport?
	return LocalPosition.placing(core, life)
end

-- The epoch the moves carry (the Teleport last adopted).
function LocalPosition.epoch(): number
	return core.epoch
end

-- The hull snapped to `teleport` (MovementController): moves carry its epoch now.
function LocalPosition.adopted(teleport: PlayerSync.Teleport)
	LocalPosition.adopt(core, teleport)
end

-- Calls fn(teleport) for every Teleport the server sends; returns its disconnect.
function LocalPosition.onTeleport(fn: (teleport: PlayerSync.Teleport) -> ()): () -> ()
	table.insert(listeners, fn)
	return function()
		local index = table.find(listeners, fn)
		if index then
			table.remove(listeners, index)
		end
	end
end

-- Sends the pose if one is due (see `step`): after the movement's ticks, every frame.
function LocalPosition.send(pose: Pose, frozen: boolean, spectating: boolean)
	local remote = moves
	if remote == nil then
		return
	end
	local move = LocalPosition.step(core, os.clock(), pose, frozen, spectating)
	if move then
		remote:FireServer(PlayerSync.encodeMove(move))
	end
end

-- Tells the server whom this spectator follows (nil: nobody).
function LocalPosition.spectate(target: Player?)
	local send = sendSpectate
	if send then
		send(if target then target.UserId else 0)
	end
end

-- Listens for Teleports (once, in the world; nothing with Config.Players.ServerPositions off).
function LocalPosition.start()
	if started then
		return
	end
	started = true
	if not Config.Players.ServerPositions then
		return
	end
	-- (Required here: they find the remotes, which specs loading this module don't have.)
	local ClientNet = require(script.Parent.Parent.Net.ClientNet)
	local Remotes = require(Shared.Net.Remotes)
	moves = Remotes.moves()
	sendSpectate = function(userId: number)
		ClientNet.send(Protocol.ClientMessage.Spectate, PlayerSync.encodeSpectate(userId))
	end
	ClientNet.on(Protocol.ServerMessage.Teleport, function(payload: buffer)
		local teleport = PlayerSync.decodeTeleport(payload)
		if teleport == nil then
			return
		end
		LocalPosition.receive(core, teleport)
		for _, listener in table.clone(listeners) do
			listener(teleport)
		end
	end)
end

return LocalPosition

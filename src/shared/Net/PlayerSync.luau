--!strict
--[[
	The wire format of players' positions ("fake coords": server Players/PlayerPositions, client
	Player/RemotePlayers and Player/LocalPosition). Pure codecs, kept out of Net/Protocol (which only
	holds their ids); every position is in world blocks, and each receiver converts with its own
	render origin (Shared/World/Origin).

	With Config.Players.ServerPositions on, characters replicate only the server's park spot. True
	positions travel here, and only to players whose interest includes them (server
	Players/Interest):

	  Move       client -> server, the unreliable remote Net/Remotes.moves() ("Moves"), about
	             Config.Players.MoveRate (20) a second: u16 seq, u16 epoch, f64 x, y, z (the feet,
	             the hull's bottom centre), pose tail. 36 bytes. Moves carrying another teleport
	             epoch than the server's are dropped (the client adopts a Teleport's epoch once it
	             has snapped); seq orders them (wrap-aware, `newer`).
	  Poses      server -> client, the same unreliable remote, Interest.RelayRate (20) a second:
	             u16 tick (the relay's tick, 1/20 s, wrapping), u8 n (at most MAX_POSES), n x (u16
	             slot, i32 x, y, z in 1/256 block, pose tail): the tracked players that moved, or
	             whose pose is older than Interest.KeepAliveSeconds. 3 + 22 n bytes: 883 for 40
	             (Roblox drops unreliable messages over 1000 bytes, so MAX_POSES is at most 45).
	  Players    server -> client, reliable (Net/Protocol ServerMessage.Players): u8 n, n x (u8 op;
	             op 1 track: u16 slot, f64 userId, u8 game mode (GameType id), i32 x, y, z in
	             1/256 block, pose tail; op 2 untrack: u16 slot): who this client now sees, with
	             their whole pose, and who it no longer does. Untracks come first.
	  Teleport   server -> the player alone, reliable (ServerMessage.Teleport): u16 epoch, u16 life
	             (the character's spawn counter, its IceVoxelLife attribute), f64 x, y, z (feet),
	             f32 yaw (NaN: keep the current one), u8 reason (TeleportReason: 0 spawn,
	             1 teleport, 2 correction). 33 bytes.
	  Spectate   client -> server, reliable (ClientMessage.Spectate): f64 userId of the player
	             spectated (0: stopped), whole and finite. 8 bytes.

	Pose tail (8 bytes): u16 yaw (2 pi / 65536), i16 look pitch (x 20860: +-pi/2), u8 tilt (0..255
	= 0..1, how far the body lies), u8 flags (Flag), u8 horizontal speed (x 8: 0..31.875 blocks a
	second), i8 vertical climb speed (x 8: +-15.875 blocks a second). Positions in 1/256 block
	(0.012 stud) reach +-8.4 million blocks, past Protocol.MAX_COORDINATE.

	Decoders return nil for a wrong length, non-finite numbers, |x| or |z| beyond
	Protocol.MAX_COORDINATE, y outside MIN_Y..MAX_Y, an op other than 1 or 2, a count beyond its
	limit, an unknown game mode or reason, or a user id that is not a whole number.
]]

local Config = require(script.Parent.Parent.Config)
local GameMode = require(script.Parent.Parent.GameMode)
local Protocol = require(script.Parent.Protocol)

local PlayerSync = {}

-- Pose flags (u8).
PlayerSync.Flag = table.freeze({
	Sneaking = 1,
	Sprinting = 2,
	Flying = 4,
	OnGround = 8,
	InWater = 16,
	Climbing = 32,
	-- Jumped within the last 0.31 s (the jump animation).
	Jumped = 64,
	-- Dead: the death tilt, then hidden.
	Dead = 128,
})

-- Why a Teleport was sent.
PlayerSync.TeleportReason = table.freeze({ Spawn = 0, Teleport = 1, Correction = 2 })

-- Players message ops.
PlayerSync.Op = table.freeze({ Track = 1, Untrack = 2 })

PlayerSync.TAIL_BYTES = 8
PlayerSync.MOVE_BYTES = 36
PlayerSync.POSE_BYTES = 22
PlayerSync.TRACK_BYTES = 32
PlayerSync.UNTRACK_BYTES = 3
PlayerSync.TELEPORT_BYTES = 33
PlayerSync.SPECTATE_BYTES = 8
-- Poses in one message (Config.Interest.MaxPosesPerMessage, kept to what fits 1000 bytes).
PlayerSync.MAX_POSES = math.clamp(math.floor(Config.Interest.MaxPosesPerMessage), 1, 45)
-- Tracks and untracks in one Players message.
PlayerSync.MAX_CHANGES = 255
-- Feet heights a position may have (blocks).
PlayerSync.MIN_Y = -256
PlayerSync.MAX_Y = 4096

local TWO_PI = 2 * math.pi
local YAW_UNITS = 65536 / TWO_PI
local PITCH_UNITS = 20860
local HALF_PI = math.pi / 2
local POSITION_UNITS = 256
-- Whole numbers a f64 holds exactly (user ids; Studio's test players are negative).
local MAX_USER_ID = 2 ^ 53

-- How a player stands: the pose tail. (Records below carry the same fields, flat.)
export type Tail = {
	-- View yaw (radians, any; it travels as 0..2 pi), look pitch (radians, -pi/2..pi/2).
	yaw: number,
	pitch: number,
	-- How far the body lies (0 standing .. 1 swimming / crawling).
	tilt: number,
	-- Flag bits.
	flags: number,
	-- Horizontal speed and vertical climb speed (blocks a second), for animation.
	speed: number,
	climb: number,
}

-- A Move: the sender's feet (blocks, doubles) and pose.
export type Move = {
	seq: number,
	epoch: number,
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

-- One record of a Poses message: a tracked player's slot, feet and pose.
export type Pose = {
	slot: number,
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

-- A Players message's track: a player this client now sees.
export type Track = {
	slot: number,
	userId: number,
	mode: string,
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

export type Players = {
	tracks: { Track },
	-- Slots no longer seen.
	untracks: { number },
}

export type Teleport = {
	epoch: number,
	life: number,
	x: number,
	y: number,
	z: number,
	-- Radians; nil keeps the current yaw.
	yaw: number?,
	reason: number,
}

--[[ Helpers ]]

local function finite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

-- A feet position the wire accepts.
local function inBounds(x: number, y: number, z: number): boolean
	return math.abs(x) <= Protocol.MAX_COORDINATE
		and math.abs(z) <= Protocol.MAX_COORDINATE
		and y >= PlayerSync.MIN_Y
		and y <= PlayerSync.MAX_Y
end

local function round(value: number): number
	return math.floor(value + 0.5)
end

-- A u16 counter's next value (seq, epoch, life, tick).
function PlayerSync.nextU16(value: number): number
	return (value + 1) % 65536
end

-- Is u16 counter `a` newer than `b` (wrap-aware: within half the range ahead)?
function PlayerSync.newer(a: number, b: number): boolean
	local ahead = (a - b) % 65536
	return ahead > 0 and ahead < 32768
end

-- A fresh, zeroed pose record (for pools: decodePoses reuses the tables it is given).
function PlayerSync.newPose(): Pose
	return { slot = 0, x = 0, y = 0, z = 0, yaw = 0, pitch = 0, tilt = 0, flags = 0, speed = 0, climb = 0 }
end

local function writeTail(b: buffer, o: number, t: Tail)
	local yaw = t.yaw % TWO_PI
	buffer.writeu16(b, o, round(if yaw == yaw then yaw * YAW_UNITS else 0) % 65536)
	local pitch = math.clamp(if t.pitch == t.pitch then t.pitch else 0, -HALF_PI, HALF_PI)
	buffer.writei16(b, o + 2, math.clamp(round(pitch * PITCH_UNITS), -32767, 32767))
	buffer.writeu8(b, o + 4, round(math.clamp(if t.tilt == t.tilt then t.tilt else 0, 0, 1) * 255))
	buffer.writeu8(b, o + 5, if t.flags == t.flags then math.clamp(math.floor(t.flags), 0, 255) else 0)
	buffer.writeu8(b, o + 6, math.clamp(round((if t.speed == t.speed then t.speed else 0) * 8), 0, 255))
	buffer.writei8(b, o + 7, math.clamp(round((if t.climb == t.climb then t.climb else 0) * 8), -127, 127))
end

-- Reads a pose tail at `o` into `into`.
local function readTail(b: buffer, o: number, into: Tail)
	into.yaw = buffer.readu16(b, o) / YAW_UNITS
	into.pitch = math.clamp(buffer.readi16(b, o + 2) / PITCH_UNITS, -HALF_PI, HALF_PI)
	into.tilt = buffer.readu8(b, o + 4) / 255
	into.flags = buffer.readu8(b, o + 5)
	into.speed = buffer.readu8(b, o + 6) / 8
	into.climb = buffer.readi8(b, o + 7) / 8
end

-- A position in 1/256 block (clamped into the wire's range).
local function writePosition(b: buffer, o: number, x: number, y: number, z: number)
	local limit = Protocol.MAX_COORDINATE
	buffer.writei32(b, o, round(math.clamp(if x == x then x else 0, -limit, limit) * POSITION_UNITS))
	buffer.writei32(
		b,
		o + 4,
		round(math.clamp(if y == y then y else 0, PlayerSync.MIN_Y, PlayerSync.MAX_Y) * POSITION_UNITS)
	)
	buffer.writei32(b, o + 8, round(math.clamp(if z == z then z else 0, -limit, limit) * POSITION_UNITS))
end

--[[ Move (client -> server, unreliable) ]]

function PlayerSync.encodeMove(move: Move): buffer
	local b = buffer.create(PlayerSync.MOVE_BYTES)
	buffer.writeu16(b, 0, move.seq % 65536)
	buffer.writeu16(b, 2, move.epoch % 65536)
	buffer.writef64(b, 4, move.x)
	buffer.writef64(b, 12, move.y)
	buffer.writef64(b, 20, move.z)
	writeTail(b, 28, move)
	return b
end

-- The Move in `b` (into `into` when given, else a new record), or nil when it is malformed.
function PlayerSync.decodeMove(b: buffer, into: Move?): Move?
	if buffer.len(b) ~= PlayerSync.MOVE_BYTES then
		return nil
	end
	local x, y, z = buffer.readf64(b, 4), buffer.readf64(b, 12), buffer.readf64(b, 20)
	if not (finite(x) and finite(y) and finite(z) and inBounds(x, y, z)) then
		return nil
	end
	local move: Move = into
		or { seq = 0, epoch = 0, x = 0, y = 0, z = 0, yaw = 0, pitch = 0, tilt = 0, flags = 0, speed = 0, climb = 0 }
	move.seq, move.epoch = buffer.readu16(b, 0), buffer.readu16(b, 2)
	move.x, move.y, move.z = x, y, z
	readTail(b, 28, move)
	return move
end

--[[ Poses (server -> client, unreliable) ]]

-- A Poses message of relay tick `tick` with records[first .. first + count - 1] (count at most
-- MAX_POSES: the relay splits longer lists).
function PlayerSync.encodePoses(tick: number, records: { Pose }, first: number, count: number): buffer
	assert(count >= 0 and count <= PlayerSync.MAX_POSES, "PlayerSync.encodePoses: too many poses")
	local b = buffer.create(3 + PlayerSync.POSE_BYTES * count)
	buffer.writeu16(b, 0, tick % 65536)
	buffer.writeu8(b, 2, count)
	local o = 3
	for i = first, first + count - 1 do
		local pose = records[i]
		buffer.writeu16(b, o, pose.slot % 65536)
		writePosition(b, o + 2, pose.x, pose.y, pose.z)
		writeTail(b, o + 14, pose)
		o += PlayerSync.POSE_BYTES
	end
	return b
end

--[[
	The tick of the Poses message in `b` and how many records it holds, written into out[1 .. n]
	(reusing the tables already there, adding new ones as needed: no garbage once warm). nil, 0
	when it is malformed (out's records may then be overwritten).
]]
function PlayerSync.decodePoses(b: buffer, out: { Pose }): (number?, number)
	local length = buffer.len(b)
	if length < 3 then
		return nil, 0
	end
	local n = buffer.readu8(b, 2)
	if n > PlayerSync.MAX_POSES or length ~= 3 + PlayerSync.POSE_BYTES * n then
		return nil, 0
	end
	local o = 3
	for i = 1, n do
		local x = buffer.readi32(b, o + 2) / POSITION_UNITS
		local y = buffer.readi32(b, o + 6) / POSITION_UNITS
		local z = buffer.readi32(b, o + 10) / POSITION_UNITS
		if not inBounds(x, y, z) then
			return nil, 0
		end
		local pose = out[i]
		if pose == nil then
			pose = PlayerSync.newPose()
			out[i] = pose
		end
		pose.slot = buffer.readu16(b, o)
		pose.x, pose.y, pose.z = x, y, z
		readTail(b, o + 14, pose)
		o += PlayerSync.POSE_BYTES
	end
	return buffer.readu16(b, 0), n
end

--[[ Players (server -> client, reliable) ]]

function PlayerSync.encodePlayers(message: Players): buffer
	local tracks, untracks = message.tracks, message.untracks
	local n = #tracks + #untracks
	assert(n <= PlayerSync.MAX_CHANGES, "PlayerSync.encodePlayers: too many changes")
	local b = buffer.create(1 + PlayerSync.UNTRACK_BYTES * #untracks + PlayerSync.TRACK_BYTES * #tracks)
	buffer.writeu8(b, 0, n)
	local o = 1
	for _, slot in untracks do
		buffer.writeu8(b, o, PlayerSync.Op.Untrack)
		buffer.writeu16(b, o + 1, slot % 65536)
		o += PlayerSync.UNTRACK_BYTES
	end
	for _, track in tracks do
		buffer.writeu8(b, o, PlayerSync.Op.Track)
		buffer.writeu16(b, o + 1, track.slot % 65536)
		buffer.writef64(b, o + 3, track.userId)
		buffer.writeu8(b, o + 11, GameMode.id(track.mode))
		writePosition(b, o + 12, track.x, track.y, track.z)
		writeTail(b, o + 24, track)
		o += PlayerSync.TRACK_BYTES
	end
	return b
end

-- The tracks and untracks of the Players message in `b` (in its order), or nil when it is
-- malformed.
function PlayerSync.decodePlayers(b: buffer): Players?
	local length = buffer.len(b)
	if length < 1 then
		return nil
	end
	local n = buffer.readu8(b, 0)
	local tracks: { Track }, untracks: { number } = {}, {}
	local o = 1
	for _ = 1, n do
		if o + 1 > length then
			return nil
		end
		local op = buffer.readu8(b, o)
		if op == PlayerSync.Op.Untrack then
			if o + PlayerSync.UNTRACK_BYTES > length then
				return nil
			end
			table.insert(untracks, buffer.readu16(b, o + 1))
			o += PlayerSync.UNTRACK_BYTES
		elseif op == PlayerSync.Op.Track then
			if o + PlayerSync.TRACK_BYTES > length then
				return nil
			end
			local userId = buffer.readf64(b, o + 3)
			local mode = GameMode.fromId(buffer.readu8(b, o + 11))
			local x = buffer.readi32(b, o + 12) / POSITION_UNITS
			local y = buffer.readi32(b, o + 16) / POSITION_UNITS
			local z = buffer.readi32(b, o + 20) / POSITION_UNITS
			if
				not finite(userId)
				or math.abs(userId) > MAX_USER_ID
				or userId ~= math.floor(userId)
				or mode == nil
				or not inBounds(x, y, z)
			then
				return nil
			end
			local track: Track = {
				slot = buffer.readu16(b, o + 1),
				userId = userId,
				mode = mode,
				x = x,
				y = y,
				z = z,
				yaw = 0,
				pitch = 0,
				tilt = 0,
				flags = 0,
				speed = 0,
				climb = 0,
			}
			readTail(b, o + 24, track)
			table.insert(tracks, track)
			o += PlayerSync.TRACK_BYTES
		else
			return nil
		end
	end
	if o ~= length then
		return nil
	end
	return { tracks = tracks, untracks = untracks }
end

--[[ Teleport (server -> the player, reliable) ]]

function PlayerSync.encodeTeleport(teleport: Teleport): buffer
	local b = buffer.create(PlayerSync.TELEPORT_BYTES)
	buffer.writeu16(b, 0, teleport.epoch % 65536)
	buffer.writeu16(b, 2, teleport.life % 65536)
	buffer.writef64(b, 4, teleport.x)
	buffer.writef64(b, 12, teleport.y)
	buffer.writef64(b, 20, teleport.z)
	local yaw = teleport.yaw
	buffer.writef32(b, 28, if yaw == nil then 0 / 0 else yaw % TWO_PI)
	buffer.writeu8(b, 32, teleport.reason)
	return b
end

function PlayerSync.decodeTeleport(b: buffer): Teleport?
	if buffer.len(b) ~= PlayerSync.TELEPORT_BYTES then
		return nil
	end
	local x, y, z = buffer.readf64(b, 4), buffer.readf64(b, 12), buffer.readf64(b, 20)
	local yaw: number? = buffer.readf32(b, 28)
	local reason = buffer.readu8(b, 32)
	if not (finite(x) and finite(y) and finite(z) and inBounds(x, y, z)) or reason > 2 then
		return nil
	end
	if yaw ~= yaw then
		yaw = nil
	elseif yaw == math.huge or yaw == -math.huge then
		return nil
	end
	return {
		epoch = buffer.readu16(b, 0),
		life = buffer.readu16(b, 2),
		x = x,
		y = y,
		z = z,
		yaw = yaw,
		reason = reason,
	}
end

--[[ Spectate (client -> server, reliable) ]]

-- `userId` 0: stopped spectating.
function PlayerSync.encodeSpectate(userId: number): buffer
	local b = buffer.create(PlayerSync.SPECTATE_BYTES)
	buffer.writef64(b, 0, userId)
	return b
end

-- The spectated player's user id (0: stopped), or nil when the payload is malformed.
function PlayerSync.decodeSpectate(b: buffer): number?
	if buffer.len(b) ~= PlayerSync.SPECTATE_BYTES then
		return nil
	end
	local userId = buffer.readf64(b, 0)
	if not finite(userId) or math.abs(userId) > MAX_USER_ID or userId ~= math.floor(userId) then
		return nil
	end
	return userId
end

return PlayerSync

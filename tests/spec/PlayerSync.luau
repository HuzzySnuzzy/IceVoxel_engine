--[[
	Players' positions on the wire (Shared/Net/PlayerSync, pure): Move, Poses, Players (track and
	untrack), Teleport and Spectate round-trip; the quantisation (positions within 1/512 block, yaw
	within 1e-4 radian, pitch, tilt, speed and climb within half a step, flags exact) and the clamps;
	a full Poses message stays under the 1000 bytes Roblox allows an unreliable message; decoding
	into a reused list makes no new records; malformed input (short or long buffers, NaN or
	infinity, beyond Protocol.MAX_COORDINATE, a height out of range, a bad op, too many records, an
	unknown game mode or reason, a user id that isn't whole) gives nil; wrap-aware counters; the
	protocol ids are new and distinct.
]]

return function(t, shared, require, _server, _client)
	local Config = require(shared.Config)
	local GameMode = require(shared.GameMode)
	local Protocol = require(shared.Net.Protocol)
	local PlayerSync = require(shared.Net.PlayerSync)

	local TWO_PI = 2 * math.pi
	local Flag = PlayerSync.Flag

	-- The difference of two angles (radians), wrapped into [0, pi].
	local function angle(a: number, b: number): number
		local d = (a - b) % TWO_PI
		return math.min(d, TWO_PI - d)
	end

	-- Checks a decoded pose tail against what was encoded.
	local function sameTail(got: any, want: any, what: string)
		t.ok(angle(got.yaw, want.yaw) <= 1e-4, `{what}: yaw {got.yaw} for {want.yaw}`)
		t.near(got.pitch, math.clamp(want.pitch, -math.pi / 2, math.pi / 2), 1 / 20860, `{what}: pitch`)
		t.near(got.tilt, math.clamp(want.tilt, 0, 1), 0.5 / 255 + 1e-12, `{what}: tilt`)
		t.eq(got.flags, want.flags, `{what}: flags`)
		t.near(got.speed, math.clamp(want.speed, 0, 31.875), 1 / 16 + 1e-12, `{what}: speed`)
		t.near(got.climb, math.clamp(want.climb, -15.875, 15.875), 1 / 16 + 1e-12, `{what}: climb`)
	end

	local function move(x: number, y: number, z: number): PlayerSync.Move
		return {
			seq = 65535,
			epoch = 7,
			x = x,
			y = y,
			z = z,
			yaw = -2.5,
			pitch = 0.75,
			tilt = 0.4,
			flags = Flag.Sprinting + Flag.OnGround + Flag.Jumped,
			speed = 5.6,
			climb = -3.1,
		}
	end

	local function pose(slot: number, x: number, y: number, z: number): PlayerSync.Pose
		return {
			slot = slot,
			x = x,
			y = y,
			z = z,
			yaw = slot * 0.37,
			pitch = -1.2,
			tilt = 1,
			flags = Flag.Flying + Flag.Sneaking,
			speed = 21.8,
			climb = 15.9,
		}
	end

	--[[ Protocol ids ]]

	t.test("player sync: the protocol ids are appended and distinct", function()
		t.eq(Protocol.ClientMessage.Spectate, 24)
		t.eq(Protocol.ServerMessage.Teleport, 26)
		t.eq(Protocol.ServerMessage.Players, 27)
		-- (Then Terraria's: Net/CharacterSync and Net/MagicSync.)
		t.eq(Protocol.ClientMessage.HeldUse, 26)
		t.eq(Protocol.ServerMessage.Projectiles, 31)
		for _, list in { Protocol.ClientMessage, Protocol.ServerMessage } do
			local seen = {}
			for name, kind in list :: { [string]: number } do
				t.ok(seen[kind] == nil, `{name} has its own number`)
				seen[kind] = true
			end
		end
	end)

	t.test("player sync: u16 counters wrap", function()
		t.eq(PlayerSync.nextU16(65535), 0)
		t.eq(PlayerSync.nextU16(7), 8)
		t.ok(PlayerSync.newer(1, 0), "1 after 0")
		t.ok(PlayerSync.newer(0, 65535), "0 after 65535")
		t.ok(PlayerSync.newer(10, 65530), "10 after 65530")
		t.ok(not PlayerSync.newer(5, 5), "not the same")
		t.ok(not PlayerSync.newer(65530, 10), "65530 before 10")
		t.ok(not PlayerSync.newer(0, 1), "0 before 1")
		t.ok(PlayerSync.newer(32767, 0), "half the range ahead")
		t.ok(not PlayerSync.newer(32768, 0), "beyond half the range is behind")
	end)

	--[[ Move ]]

	t.test("player sync: Move round-trips (f64 feet, the pose tail)", function()
		for _, at in
			{
				{ 0, 64, 0 },
				{ 123456.789012345, 70.25, -987654.321098765 },
				{ -Protocol.MAX_COORDINATE, PlayerSync.MIN_Y, Protocol.MAX_COORDINATE },
				{ 0.1, PlayerSync.MAX_Y, -0.1 },
			}
		do
			local sent = move(at[1], at[2], at[3])
			local b = PlayerSync.encodeMove(sent)
			t.eq(buffer.len(b), PlayerSync.MOVE_BYTES)
			t.eq(PlayerSync.MOVE_BYTES, 36)
			local got = PlayerSync.decodeMove(b) :: PlayerSync.Move
			t.ok(got ~= nil, "decodes")
			t.eq(got.seq, 65535)
			t.eq(got.epoch, 7)
			t.eq(got.x, at[1], "x exact")
			t.eq(got.y, at[2], "y exact")
			t.eq(got.z, at[3], "z exact")
			sameTail(got, sent, "move")
		end
		-- Into a reused record.
		local into = PlayerSync.decodeMove(PlayerSync.encodeMove(move(1, 2, 3))) :: PlayerSync.Move
		local again = PlayerSync.decodeMove(PlayerSync.encodeMove(move(4, 5, 6)), into)
		t.ok(again == into, "the same record")
		t.eq(into.x, 4)
		-- Counters wrap into u16.
		local wrapped = move(0, 64, 0)
		wrapped.seq, wrapped.epoch = 65536 + 3, -1
		local got = PlayerSync.decodeMove(PlayerSync.encodeMove(wrapped)) :: PlayerSync.Move
		t.eq(got.seq, 3)
		t.eq(got.epoch, 65535)
	end)

	t.test("player sync: malformed Moves give nil", function()
		local good = PlayerSync.encodeMove(move(1, 64, 1))
		t.eq(PlayerSync.decodeMove(buffer.create(35)), nil, "short")
		t.eq(PlayerSync.decodeMove(buffer.create(37)), nil, "long")
		t.eq(PlayerSync.decodeMove(buffer.create(0)), nil, "empty")
		local function with(offset: number, value: number): buffer
			local b = buffer.create(buffer.len(good))
			buffer.copy(b, 0, good)
			buffer.writef64(b, offset, value)
			return b
		end
		for offset, name in { [4] = "x", [12] = "y", [20] = "z" } do
			t.eq(PlayerSync.decodeMove(with(offset, 0 / 0)), nil, `NaN {name}`)
			t.eq(PlayerSync.decodeMove(with(offset, math.huge)), nil, `inf {name}`)
			t.eq(PlayerSync.decodeMove(with(offset, -math.huge)), nil, `-inf {name}`)
		end
		t.eq(PlayerSync.decodeMove(with(4, Protocol.MAX_COORDINATE + 0.5)), nil, "x beyond")
		t.eq(PlayerSync.decodeMove(with(20, -Protocol.MAX_COORDINATE - 0.5)), nil, "z beyond")
		t.eq(PlayerSync.decodeMove(with(12, PlayerSync.MIN_Y - 0.01)), nil, "y below")
		t.eq(PlayerSync.decodeMove(with(12, PlayerSync.MAX_Y + 0.01)), nil, "y above")
		t.ok(PlayerSync.decodeMove(good) ~= nil, "the good one decodes")
	end)

	t.test("player sync: the pose tail quantises, clamps and keeps every flag", function()
		for flags = 0, 255 do
			local sent = move(0, 64, 0)
			sent.flags = flags
			local got = PlayerSync.decodeMove(PlayerSync.encodeMove(sent)) :: PlayerSync.Move
			t.eq(got.flags, flags, `flags {flags}`)
		end
		for i = 0, 400 do
			local sent = move(0, 64, 0)
			sent.yaw = -10 + i * 0.05
			sent.pitch = -1.6 + i * 0.008
			sent.tilt = i / 400
			sent.speed = i * 0.08
			sent.climb = -16 + i * 0.08
			sameTail(PlayerSync.decodeMove(PlayerSync.encodeMove(sent)), sent, `step {i}`)
		end
		-- Out of range: clamped, NaN: zero.
		local wild = move(0, 64, 0)
		wild.pitch, wild.tilt, wild.speed, wild.climb = 3, 2, 100, -100
		local got = PlayerSync.decodeMove(PlayerSync.encodeMove(wild)) :: PlayerSync.Move
		t.near(got.pitch, math.pi / 2, 1e-4, "pitch clamped")
		t.eq(got.tilt, 1, "tilt clamped")
		t.eq(got.speed, 31.875, "speed clamped")
		t.eq(got.climb, -15.875, "climb clamped")
		wild.yaw, wild.pitch, wild.tilt, wild.speed, wild.climb = 0 / 0, 0 / 0, 0 / 0, 0 / 0, 0 / 0
		got = PlayerSync.decodeMove(PlayerSync.encodeMove(wild)) :: PlayerSync.Move
		t.eq(got.yaw, 0)
		t.eq(got.pitch, 0)
		t.eq(got.tilt, 0)
		t.eq(got.speed, 0)
		t.eq(got.climb, 0)
	end)

	--[[ Poses ]]

	t.test("player sync: Poses round-trip within 1/512 block, a slice at a time", function()
		local records = {}
		for i = 1, 50 do
			table.insert(records, pose(i * 1000 + 7, -999999.99 + i * 39999.7, -200 + i * 80.123, 543210.5 - i))
		end
		local out: { PlayerSync.Pose } = {}
		local b = PlayerSync.encodePoses(65536 + 9, records, 3, 40)
		t.eq(buffer.len(b), 3 + 22 * 40)
		local tick, n = PlayerSync.decodePoses(b, out)
		t.eq(tick, 9, "tick wraps into u16")
		t.eq(n, 40)
		for i = 1, n do
			local want, got = records[i + 2], out[i]
			t.eq(got.slot, want.slot, "slot")
			t.ok(math.abs(got.x - want.x) <= 1 / 512, `x {got.x} for {want.x}`)
			t.ok(math.abs(got.y - want.y) <= 1 / 512, `y {got.y} for {want.y}`)
			t.ok(math.abs(got.z - want.z) <= 1 / 512, `z {got.z} for {want.z}`)
			sameTail(got, want, `pose {i}`)
		end
		-- Decoding again reuses the records.
		local first = out[1]
		local _, m = PlayerSync.decodePoses(PlayerSync.encodePoses(1, records, 1, 2), out)
		t.eq(m, 2)
		t.ok(out[1] == first, "the same table")
		t.eq(out[1].slot, records[1].slot)
		-- An empty message.
		local _, none = PlayerSync.decodePoses(PlayerSync.encodePoses(0, records, 1, 0), out)
		t.eq(none, 0)
	end)

	t.test("player sync: a full Poses message fits the unreliable limit", function()
		t.eq(PlayerSync.MAX_POSES, math.min(Config.Interest.MaxPosesPerMessage, 45))
		local records = {}
		for i = 1, PlayerSync.MAX_POSES do
			table.insert(records, pose(i, i, 64, -i))
		end
		local b = PlayerSync.encodePoses(1, records, 1, PlayerSync.MAX_POSES)
		t.ok(buffer.len(b) <= 1000, `{buffer.len(b)} bytes`)
		t.eq(3 + 22 * 45 <= 1000, true, "even at the cap")
		t.ok(not pcall(PlayerSync.encodePoses, 1, records, 1, PlayerSync.MAX_POSES + 1), "more is refused")
	end)

	t.test("player sync: malformed Poses give nil", function()
		local out = {}
		local records = { pose(1, 10, 64, 10), pose(2, 20, 64, 20) }
		local good = PlayerSync.encodePoses(5, records, 1, 2)
		t.eq((PlayerSync.decodePoses(buffer.create(2), out)), nil, "short header")
		t.eq((PlayerSync.decodePoses(buffer.create(buffer.len(good) - 1), out)), nil, "short")
		local long = buffer.create(buffer.len(good) + 1)
		buffer.copy(long, 0, good)
		t.eq((PlayerSync.decodePoses(long, out)), nil, "long")
		-- More records than allowed, with bytes for all of them.
		local many = buffer.create(3 + 22 * (PlayerSync.MAX_POSES + 1))
		buffer.writeu8(many, 2, PlayerSync.MAX_POSES + 1)
		t.eq((PlayerSync.decodePoses(many, out)), nil, "too many")
		local function with(offset: number, value: number): buffer
			local b = buffer.create(buffer.len(good))
			buffer.copy(b, 0, good)
			buffer.writei32(b, offset, value)
			return b
		end
		-- Second record's x, y, z (record at 3 + 22, position after its u16 slot).
		local o = 3 + 22 + 2
		t.eq((PlayerSync.decodePoses(with(o, (Protocol.MAX_COORDINATE + 1) * 256), out)), nil, "x beyond")
		t.eq((PlayerSync.decodePoses(with(o + 4, (PlayerSync.MIN_Y - 1) * 256), out)), nil, "y below")
		t.eq((PlayerSync.decodePoses(with(o + 4, (PlayerSync.MAX_Y + 1) * 256), out)), nil, "y above")
		t.eq((PlayerSync.decodePoses(with(o + 8, -(Protocol.MAX_COORDINATE + 1) * 256), out)), nil, "z beyond")
		t.ok((PlayerSync.decodePoses(good, out)) ~= nil, "the good one decodes")
	end)

	--[[ Players ]]

	t.test("player sync: Players round-trip tracks (slot, user id, mode, pose) and untracks", function()
		local tracks: { PlayerSync.Track } = {}
		for i, mode in GameMode.ALL do
			local p = pose(i * 100, i * 1000.3, 64 + i, -i * 999.9) :: any
			p.userId = if i % 2 == 0 then -i else 8000000000 + i
			p.mode = mode
			table.insert(tracks, p)
		end
		local message = { tracks = tracks, untracks = { 7, 65535, 0 } }
		local b = PlayerSync.encodePlayers(message)
		t.eq(buffer.len(b), 1 + 3 * 3 + 32 * #tracks)
		local got = PlayerSync.decodePlayers(b) :: PlayerSync.Players
		t.ok(got ~= nil, "decodes")
		t.eq(#got.untracks, 3)
		t.eq(got.untracks[1], 7)
		t.eq(got.untracks[2], 65535)
		t.eq(got.untracks[3], 0)
		t.eq(#got.tracks, #tracks)
		for i, want in tracks do
			local track = got.tracks[i]
			t.eq(track.slot, want.slot)
			t.eq(track.userId, want.userId)
			t.eq(track.mode, want.mode)
			t.ok(math.abs(track.x - want.x) <= 1 / 512, "x")
			t.ok(math.abs(track.y - want.y) <= 1 / 512, "y")
			t.ok(math.abs(track.z - want.z) <= 1 / 512, "z")
			sameTail(track, want, `track {i}`)
		end
		-- Nothing changed: an empty message.
		local empty = PlayerSync.decodePlayers(PlayerSync.encodePlayers({ tracks = {}, untracks = {} }))
		t.ok(empty ~= nil and #empty.tracks == 0 and #empty.untracks == 0, "empty")
		-- At most MAX_CHANGES.
		local slots = {}
		for i = 1, PlayerSync.MAX_CHANGES + 1 do
			slots[i] = i
		end
		t.ok(not pcall(PlayerSync.encodePlayers, { tracks = {}, untracks = slots }), "too many changes")
	end)

	t.test("player sync: malformed Players give nil", function()
		local track = pose(3, 1, 64, 1) :: any
		track.userId, track.mode = 156, GameMode.CREATIVE
		local good = PlayerSync.encodePlayers({ tracks = { track }, untracks = { 9 } })
		local function copy(extra: number?): buffer
			local b = buffer.create(buffer.len(good) + (extra or 0))
			buffer.copy(b, 0, good, 0, math.min(buffer.len(good), buffer.len(b)))
			return b
		end
		t.eq(PlayerSync.decodePlayers(buffer.create(0)), nil, "empty")
		t.eq(PlayerSync.decodePlayers(copy(-1)), nil, "short")
		t.eq(PlayerSync.decodePlayers(copy(1)), nil, "long")
		-- The track starts after the untrack (1 + 3).
		local o = 4
		local b = copy()
		buffer.writeu8(b, 1, 3)
		t.eq(PlayerSync.decodePlayers(b), nil, "op 3")
		b = copy()
		buffer.writeu8(b, 1, 0)
		t.eq(PlayerSync.decodePlayers(b), nil, "op 0")
		b = copy()
		buffer.writeu8(b, 0, 3)
		t.eq(PlayerSync.decodePlayers(b), nil, "more changes than bytes")
		b = copy()
		buffer.writeu8(b, 0, 1)
		t.eq(PlayerSync.decodePlayers(b), nil, "fewer changes than bytes")
		for _, bad in { 0 / 0, math.huge, 1.5, 2 ^ 60 } do
			b = copy()
			buffer.writef64(b, o + 3, bad)
			t.eq(PlayerSync.decodePlayers(b), nil, `user id {bad}`)
		end
		b = copy()
		buffer.writeu8(b, o + 11, #GameMode.ALL)
		t.eq(PlayerSync.decodePlayers(b), nil, "unknown game mode")
		b = copy()
		buffer.writei32(b, o + 12, (Protocol.MAX_COORDINATE + 1) * 256)
		t.eq(PlayerSync.decodePlayers(b), nil, "x beyond")
		b = copy()
		buffer.writei32(b, o + 16, (PlayerSync.MAX_Y + 1) * 256)
		t.eq(PlayerSync.decodePlayers(b), nil, "y above")
		t.ok(PlayerSync.decodePlayers(good) ~= nil, "the good one decodes")
	end)

	--[[ Teleport ]]

	t.test("player sync: Teleport round-trips (yaw or keep, every reason)", function()
		for reason = 0, 2 do
			local sent =
				{ epoch = 70000, life = 3, x = -123456.789, y = 70.5, z = 999999.25, yaw = -1, reason = reason }
			local b = PlayerSync.encodeTeleport(sent)
			t.eq(buffer.len(b), PlayerSync.TELEPORT_BYTES)
			local got = PlayerSync.decodeTeleport(b) :: PlayerSync.Teleport
			t.ok(got ~= nil, "decodes")
			t.eq(got.epoch, 70000 % 65536)
			t.eq(got.life, 3)
			t.eq(got.x, sent.x, "x exact")
			t.eq(got.y, sent.y, "y exact")
			t.eq(got.z, sent.z, "z exact")
			t.ok(angle(got.yaw :: number, -1) <= 1e-6, "yaw")
			t.eq(got.reason, reason)
		end
		local keep = PlayerSync.decodeTeleport(
			PlayerSync.encodeTeleport({ epoch = 1, life = 1, x = 0, y = 64, z = 0, yaw = nil, reason = 0 })
		) :: PlayerSync.Teleport
		t.eq(keep.yaw, nil, "no yaw: keep it")
		t.eq(PlayerSync.TeleportReason.Correction, 2)
	end)

	t.test("player sync: malformed Teleports give nil", function()
		local good = PlayerSync.encodeTeleport({ epoch = 1, life = 1, x = 5, y = 64, z = 5, yaw = 0, reason = 1 })
		local function with(write: (b: buffer) -> ()): buffer
			local b = buffer.create(buffer.len(good))
			buffer.copy(b, 0, good)
			write(b)
			return b
		end
		t.eq(PlayerSync.decodeTeleport(buffer.create(PlayerSync.TELEPORT_BYTES - 1)), nil, "short")
		t.eq(PlayerSync.decodeTeleport(buffer.create(PlayerSync.TELEPORT_BYTES + 1)), nil, "long")
		t.eq(
			PlayerSync.decodeTeleport(with(function(b)
				buffer.writef64(b, 4, 0 / 0)
			end)),
			nil,
			"NaN x"
		)
		t.eq(
			PlayerSync.decodeTeleport(with(function(b)
				buffer.writef64(b, 20, Protocol.MAX_COORDINATE + 1)
			end)),
			nil,
			"z beyond"
		)
		t.eq(
			PlayerSync.decodeTeleport(with(function(b)
				buffer.writef64(b, 12, PlayerSync.MAX_Y + 1)
			end)),
			nil,
			"y above"
		)
		t.eq(
			PlayerSync.decodeTeleport(with(function(b)
				buffer.writef32(b, 28, math.huge)
			end)),
			nil,
			"infinite yaw"
		)
		t.eq(
			PlayerSync.decodeTeleport(with(function(b)
				buffer.writeu8(b, 32, 3)
			end)),
			nil,
			"reason 3"
		)
		t.ok(PlayerSync.decodeTeleport(good) ~= nil, "the good one decodes")
	end)

	--[[ Spectate ]]

	t.test("player sync: Spectate carries a user id (0: stopped), whole and finite", function()
		for _, userId in { 0, 1, 156, 8000000000, -1, -2 } do
			t.eq(PlayerSync.decodeSpectate(PlayerSync.encodeSpectate(userId)), userId, `{userId}`)
		end
		for _, bad in { 0 / 0, math.huge, -math.huge, 1.5, 2 ^ 60 } do
			t.eq(PlayerSync.decodeSpectate(PlayerSync.encodeSpectate(bad)), nil, `{bad}`)
		end
		t.eq(PlayerSync.decodeSpectate(buffer.create(7)), nil, "short")
		t.eq(PlayerSync.decodeSpectate(buffer.create(9)), nil, "long")
	end)
end

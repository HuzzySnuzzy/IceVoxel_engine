--[[
	The local player's moves and teleports (client Player/LocalPosition's pure core): nothing goes
	before a Teleport was adopted, nor while frozen or spectating; moves carry the adopted epoch
	and a wrapping sequence number; the cadence stays within Config.Players.MoveRate in every second
	whatever the frames (several hull ticks a frame, hitches, fast frames) and keeps it at 60 fps;
	an unchanged pose waits for the keepalive; the life handshake picks the Teleport of the
	character's life whichever of the attribute and the message comes first, and a later teleport
	of the same life replaces it; the pose's flags.
]]

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local PlayerSync = require(shared.Net.PlayerSync)
	local LocalPosition = require(client.Player.LocalPosition)

	local RATE = Config.Players.MoveRate
	local Flag = PlayerSync.Flag

	local function pose(x: number): any
		return { x = x, y = 64, z = -x, yaw = 1, pitch = 0.2, tilt = 0, flags = Flag.OnGround, speed = 4.3, climb = 0 }
	end

	local function teleport(epoch: number, life: number, x: number?): PlayerSync.Teleport
		return {
			epoch = epoch,
			life = life,
			x = x or 10.5,
			y = 70,
			z = -3.5,
			yaw = nil,
			reason = PlayerSync.TeleportReason.Teleport,
		}
	end

	-- A core that has adopted epoch `epoch`.
	local function ready(epoch: number?): any
		local core = LocalPosition.newCore()
		local placed = teleport(epoch or 1, 1)
		LocalPosition.receive(core, placed)
		LocalPosition.adopt(core, placed)
		return core
	end

	t.test("local position: nothing is sent before a Teleport was adopted", function()
		local core = LocalPosition.newCore()
		t.eq(LocalPosition.step(core, 0, pose(1), false, false), nil, "no teleport yet")
		LocalPosition.receive(core, teleport(3, 1))
		t.eq(LocalPosition.step(core, 1, pose(2), false, false), nil, "received, not adopted")
		LocalPosition.adopt(core, teleport(3, 1))
		local move = LocalPosition.step(core, 2, pose(3), false, false)
		t.ok(move ~= nil, "adopted: sent")
		t.eq((move :: any).epoch, 3, "with its epoch")
		t.eq((move :: any).x, 3)
	end)

	t.test("local position: no moves while frozen or spectating", function()
		local core = ready()
		t.eq(LocalPosition.step(core, 0, pose(1), true, false), nil, "frozen")
		t.eq(LocalPosition.step(core, 1, pose(2), false, true), nil, "spectating")
		t.ok(LocalPosition.step(core, 2, pose(3), false, false) ~= nil, "moving again")
	end)

	t.test("local position: moves carry the adopted epoch and a wrapping sequence", function()
		local core = ready(65535)
		core.seq = 65534
		local now = 0
		local seqs = {}
		for i = 1, 3 do
			now += 1
			local move = LocalPosition.step(core, now, pose(i), false, false)
			t.ok(move ~= nil, `move {i}`)
			t.eq((move :: any).epoch, 65535)
			table.insert(seqs, (move :: any).seq)
		end
		t.eq(seqs[1], 65534)
		t.eq(seqs[2], 65535)
		t.eq(seqs[3], 0, "wrapped")
		t.ok(PlayerSync.newer(seqs[3], seqs[2]), "still newer for the server")
		-- A new teleport: its epoch from the next move on.
		local next = teleport(0, 1)
		LocalPosition.receive(core, next)
		now += 1
		t.eq((LocalPosition.step(core, now, pose(9), false, false) :: any).epoch, 65535, "not adopted yet")
		LocalPosition.adopt(core, next)
		now += 0.001
		local move = LocalPosition.step(core, now, pose(10), false, false)
		t.ok(move ~= nil, "due at once after adopting")
		t.eq((move :: any).epoch, 0)
	end)

	t.test("local position: at most MoveRate a second whatever the frames, and keeping it at 60 fps", function()
		-- Frames of every length (fast monitors to hitches past 5 ticks), the pose changing every
		-- frame (several hull ticks each).
		local core = ready()
		local seed = 99
		local function random(): number
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed / 2147483648
		end
		local now, x = 0, 0
		local times: { number } = {}
		while now < 30 do
			local dt = if random() < 0.05 then 0.1 + random() * 0.9 else 1 / 240 + random() * 0.05
			now += dt
			x += dt * 5
			if LocalPosition.step(core, now, pose(x), false, false) then
				table.insert(times, now)
			end
		end
		-- In any one second window, at most RATE + 1 (the window may hold both ends of a rhythm).
		local j = 1
		for i = 1, #times do
			while times[i] - times[j] >= 1 do
				j += 1
			end
			t.ok(i - j + 1 <= RATE + 1, `{i - j + 1} sends within a second at {times[i]}`)
		end
		t.ok(#times <= 30 * RATE + 1, `{#times} in 30 s`)
		-- Steady 60 fps keeps the rate (no rhythm lost to rounding).
		local steady = ready()
		local count = 0
		for frame = 1, 600 do
			if LocalPosition.step(steady, frame / 60, pose(frame), false, false) then
				count += 1
			end
		end
		t.ok(count >= 10 * RATE - 1 and count <= 10 * RATE + 1, `{count} in 10 s at 60 fps`)
	end)

	t.test("local position: an unchanged pose waits for the keepalive", function()
		local core = ready()
		t.ok(LocalPosition.step(core, 0, pose(1), false, false) ~= nil)
		t.eq(LocalPosition.step(core, 0.2, pose(1), false, false), nil, "unchanged")
		t.eq(LocalPosition.step(core, 0.9, pose(1), false, false), nil, "still within the keepalive")
		t.ok(LocalPosition.step(core, LocalPosition.KEEPALIVE + 0.01, pose(1), false, false) ~= nil, "kept alive")
		-- Any field changing counts.
		local turned = pose(1)
		turned.yaw = 2
		t.ok(LocalPosition.step(core, LocalPosition.KEEPALIVE + 0.2, turned, false, false) ~= nil, "turned")
	end)

	t.test("local position: the handshake finds the Teleport of the character's life, either order", function()
		-- The message first, then the attribute.
		local core = LocalPosition.newCore()
		LocalPosition.receive(core, teleport(4, 2))
		local spawn = teleport(5, 3)
		LocalPosition.receive(core, spawn)
		t.eq(LocalPosition.placing(core, nil), nil, "no attribute yet")
		t.eq(LocalPosition.placing(core, 3), spawn, "then it matches")
		-- The attribute first, then the message: the previous character's teleport is no match.
		local other = LocalPosition.newCore()
		LocalPosition.receive(other, teleport(4, 2))
		t.eq(LocalPosition.placing(other, 3), nil, "the old life's teleport")
		local arrived = teleport(5, 3)
		LocalPosition.receive(other, arrived)
		t.eq(LocalPosition.placing(other, 3), arrived, "the spawn's, once it comes")
		-- A later teleport (or correction) of the same life replaces it; another life's doesn't
		-- place this character.
		local moved = teleport(6, 3, 500)
		LocalPosition.receive(other, moved)
		t.eq(LocalPosition.placing(other, 3), moved)
		LocalPosition.receive(other, teleport(7, 4))
		t.eq(LocalPosition.placing(other, 3), nil, "the next character's")
		-- Lives wrap like the server's u16 counter.
		local wrapped = LocalPosition.newCore()
		local zero = teleport(1, 0)
		LocalPosition.receive(wrapped, zero)
		t.eq(LocalPosition.placing(wrapped, 65536), zero)
	end)

	t.test("local position: the pose's flags", function()
		local state = {
			sneaking = true,
			sprinting = false,
			flying = true,
			onGround = false,
			inWater = true,
			climbing = true,
		}
		t.eq(
			LocalPosition.flags(state, true, false),
			Flag.Sneaking + Flag.Flying + Flag.InWater + Flag.Climbing + Flag.Jumped
		)
		state =
			{ sneaking = false, sprinting = true, flying = false, onGround = true, inWater = false, climbing = false }
		t.eq(LocalPosition.flags(state, false, true), Flag.Sprinting + Flag.OnGround + Flag.Dead)
		-- Every flag fits the wire's byte and comes back.
		local move = {
			seq = 1,
			epoch = 1,
			x = 0,
			y = 0,
			z = 0,
			yaw = 0,
			pitch = 0,
			tilt = 0,
			flags = LocalPosition.flags({
				sneaking = true,
				sprinting = true,
				flying = true,
				onGround = true,
				inWater = true,
				climbing = true,
			}, true, true),
			speed = 0,
			climb = 0,
		}
		t.eq((PlayerSync.decodeMove(PlayerSync.encodeMove(move)) :: any).flags, 255)
	end)
end

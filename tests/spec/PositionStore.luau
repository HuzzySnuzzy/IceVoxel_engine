--[[
	The server's record of where players are (server Players/PositionStore, pure): slots (in
	order, never one in use, wrapping); a new character's life and its spawn teleport; teleports
	(a new epoch, full buckets, the Teleport message); moves (stale epochs dropped until the client
	confirms, wrap-aware sequence numbers, MoveCheck); the "correct", "log" and "off" policies (a
	correction is a Teleport with reason 2 back to the last accepted place, at most one every half
	second); spectating (the spectator's place follows the target's every tick, through chains,
	never in a loop, their own moves ignored, ended by a teleport or leaving spectator); the server's
	Dead flag; grants; leaving.
]]

return function(t, shared, require, server, _client)
	local Config = require(shared.Config)
	local GameMode = require(shared.GameMode)
	local PlayerSync = require(shared.Net.PlayerSync)
	local MoveCheck = require(server.Players.MoveCheck)
	local PositionStore = require(server.Players.PositionStore)

	local SURVIVAL, CREATIVE, SPECTATOR = GameMode.SURVIVAL, GameMode.CREATIVE, GameMode.SPECTATOR
	local Reason = PlayerSync.TeleportReason
	local Flag = PlayerSync.Flag

	local function move(seq: number, epoch: number, x: number, y: number, z: number, flags: number?): PlayerSync.Move
		return {
			seq = seq,
			epoch = epoch,
			x = x,
			y = y,
			z = z,
			yaw = 1,
			pitch = 0.2,
			tilt = 0,
			flags = flags or Flag.OnGround,
			speed = 4.3,
			climb = 0,
		}
	end

	-- A store with player `key` standing at (x, y, z) after its spawn teleport; returns the epoch.
	local function placed(
		store: PositionStore.Store,
		key: string,
		mode: string,
		x: number,
		y: number,
		z: number
	): number
		store:add(key, mode, 0)
		store:spawned(key)
		local teleport = store:teleport(key, x, y, z, nil, 0)
		assert(teleport, "placed")
		return teleport.epoch
	end

	t.test("position store: slots are given in order and never one in use", function()
		local store = PositionStore.new()
		t.eq(store:add("a", SURVIVAL, 0).slot, 0, "first slot")
		t.eq(store:add("b", SURVIVAL, 0).slot, 1, "second")
		t.eq(store:add("a", SURVIVAL, 0).slot, 0, "adding again: the same record")
		store:remove("a")
		t.eq(store:add("c", SURVIVAL, 0).slot, 2, "slots go on increasing (a left slot is not reused at once)")
		-- Wrapping after 65,536 joins skips the slots in use.
		store.nextSlot = 65535
		t.eq(store:add("d", SURVIVAL, 0).slot, 65535, "the last u16")
		t.eq(store:add("e", SURVIVAL, 0).slot, 0, "wraps to 0, free again")
		t.eq(store:add("f", SURVIVAL, 0).slot, 3, "skips 1 and 2, in use")
		t.eq(store:get("zzz"), nil, "unknown key")
	end)

	t.test("position store: a character's life, its spawn teleport, then teleports", function()
		local store = PositionStore.new()
		local record = store:add("p", SURVIVAL, 0)
		t.ok(not record.known, "no position before a character stands")
		t.eq(store:spawned("p"), 1, "the first character's life")
		local spawn = store:teleport("p", 10.5, 64, -20.5, 1.25, 0)
		assert(spawn)
		t.eq(spawn.reason, Reason.Spawn, "the first teleport after a new character is the spawn")
		t.eq(spawn.life, 1, "carries the life")
		t.eq(spawn.epoch, 1, "a new epoch")
		t.eq(spawn.yaw, 1.25, "the facing")
		t.ok(record.known and record.x == 10.5 and record.y == 64 and record.z == -20.5, "placed")
		local again = store:teleport("p", 0.5, 70, 0.5, nil, 1)
		assert(again)
		t.eq(again.reason, Reason.Teleport, "then plain teleports")
		t.eq(again.epoch, 2, "epoch + 1")
		t.eq(again.yaw, nil, "nil yaw keeps it")
		t.eq(record.yaw, 1.25, "kept")
		t.eq(store:teleport("p", 0 / 0, 0, 0, nil, 1), nil, "NaN: refused")
		t.eq(store:teleport("p", 2e6, 0, 0, nil, 1), nil, "out of bounds: refused")
		t.eq(store:teleport("nobody", 0, 0, 0, nil, 1), nil, "unknown player")
		-- A new character: life + 1, no position until its spawn teleport.
		t.eq(store:spawned("p"), 2, "second life")
		t.ok(not record.known, "no position until placed")
		local respawn = store:teleport("p", 1, 2, 3, nil, 2)
		assert(respawn)
		t.eq(respawn.reason, Reason.Spawn, "the respawn's teleport")
		t.eq(respawn.life, 2, "with the new life")
		-- Life and epoch wrap as u16.
		record.life, record.epoch = 65535, 65535
		t.eq(store:spawned("p"), 0, "life wraps")
		local wrapped = store:teleport("p", 1, 2, 3, nil, 3)
		assert(wrapped)
		t.eq(wrapped.epoch, 0, "epoch wraps")
		-- The character going takes the position away.
		store:left("p")
		t.ok(not record.known, "gone")
		t.eq((store:move("p", move(1, 0, 1, 2, 3), 4)), "unknown", "no moves without a position")
	end)

	t.test("position store: moves need the epoch and newer sequence numbers", function()
		local store = PositionStore.new()
		local epoch = placed(store, "p", SURVIVAL, 0.5, 64, 0.5)
		local record = store:get("p") :: PositionStore.Record
		t.eq((store:move("p", move(10, epoch - 1, 1, 64, 0.5), 0.1)), "stale", "the old epoch: before the teleport")
		t.eq(record.x, 0.5, "not taken")
		t.eq((store:move("p", move(10, epoch, 1, 64, 0.5), 0.1)), "accepted", "the new epoch")
		t.eq(record.x, 1, "taken")
		t.eq(record.yaw, 1, "with its pose")
		t.eq(record.speed, 4.3, "speed")
		t.eq((store:move("p", move(10, epoch, 1.2, 64, 0.5), 0.15)), "old", "a repeated seq")
		t.eq((store:move("p", move(9, epoch, 1.2, 64, 0.5), 0.15)), "old", "an older seq")
		t.eq((store:move("p", move(11, epoch, 1.2, 64, 0.5), 0.15)), "accepted", "the next")
		-- Wrapping sequence numbers.
		record.lastSeq = 65535
		t.eq((store:move("p", move(0, epoch, 1.4, 64, 0.5), 0.2)), "accepted", "0 after 65535")
		t.eq((store:move("p", move(65534, epoch, 1.4, 64, 0.5), 0.2)), "old", "65534 after 0")
		-- A teleport: the moves on their way (old epoch) are dropped, any seq is taken after it.
		local teleport = store:teleport("p", 100.5, 70, 100.5, nil, 0.3) :: PlayerSync.Teleport
		t.eq((store:move("p", move(1, epoch, 1.6, 64, 0.5), 0.35)), "stale", "from before the teleport")
		t.eq(record.x, 100.5, "still at the destination")
		t.eq((store:move("p", move(1, teleport.epoch, 100.6, 70, 100.5), 0.4)), "accepted", "confirmed")
		-- Out of bounds (a decoder would refuse it already).
		t.eq((store:move("p", move(2, teleport.epoch, 0 / 0, 70, 100.5), 0.45)), "invalid", "NaN")
		-- The client's Dead flag is ignored: the server's is used.
		store:move("p", move(3, teleport.epoch, 100.7, 70, 100.5, Flag.Dead + Flag.Sprinting), 0.5)
		t.eq(record.flags, Flag.Sprinting, "no Dead from the client")
		store:setAlive("p", false)
		t.eq(record.flags, Flag.Sprinting + Flag.Dead, "the server's Dead")
		store:move("p", move(4, teleport.epoch, 100.8, 70, 100.5, Flag.OnGround), 0.55)
		t.eq(record.flags, Flag.OnGround + Flag.Dead, "kept through moves")
		local version = record.version
		store:setAlive("p", false)
		t.eq(record.version, version, "no change: same version")
		store:setAlive("p", true)
		t.eq(record.flags, Flag.OnGround, "alive again")
		t.ok(record.version > version, "a change bumps the version")
	end)

	t.test("position store: corrections, logging and no checks", function()
		local store = PositionStore.new()
		local epoch = placed(store, "p", SURVIVAL, 0.5, 64, 0.5)
		local record = store:get("p") :: PositionStore.Record
		local result, correction = store:move("p", move(1, epoch, 60.5, 64, 0.5), 0.1, "correct")
		t.eq(result, "corrected", "60 blocks at once: corrected")
		assert(correction)
		t.eq(correction.reason, Reason.Correction, "reason correction")
		t.eq(correction.x, 0.5, "back to the last accepted place")
		t.eq(correction.epoch, epoch + 1, "with a new epoch")
		t.eq(correction.yaw, nil, "the facing kept")
		t.eq(record.x, 0.5, "the record stayed")
		-- Within half a second: refused without another correction.
		local e2 = correction.epoch
		local again, second = store:move("p", move(2, e2, 80.5, 64, 0.5), 0.3, "correct")
		t.eq(again, "refused", "refused")
		t.eq(second, nil, "no second correction within CORRECTION_INTERVAL")
		local later, third =
			store:move("p", move(3, e2, 80.5, 64, 0.5), 0.1 + PositionStore.CORRECTION_INTERVAL, "correct")
		t.eq(later, "corrected", "half a second later: corrected again")
		t.ok(third ~= nil, "a correction")
		-- "log": taken, warned at most every WARN_INTERVAL.
		local logged = PositionStore.new()
		local le = placed(logged, "q", SURVIVAL, 0.5, 64, 0.5)
		t.eq((logged:move("q", move(1, le, 60.5, 64, 0.5), 1, "log")), "logged", "warn")
		t.eq((logged:get("q") :: PositionStore.Record).x, 60.5, "taken")
		t.eq((logged:move("q", move(2, le, 120.5, 64, 0.5), 2, "log")), "accepted", "no second warning so soon")
		t.eq(
			(logged:move("q", move(3, le, 180.5, 64, 0.5), 2 + PositionStore.WARN_INTERVAL, "log")),
			"logged",
			"warned again later"
		)
		-- "off": anything in bounds.
		local off = PositionStore.new()
		local oe = placed(off, "r", SURVIVAL, 0.5, 64, 0.5)
		t.eq((off:move("r", move(1, oe, 9000.5, 64, 0.5), 0.05, "off")), "accepted", "off: no limits")
		-- The default policy is Config's.
		t.eq(Config.Players.MoveCheck, "correct", "Config default")
		local default = PositionStore.new()
		local de = placed(default, "s", SURVIVAL, 0.5, 64, 0.5)
		t.eq((default:move("s", move(1, de, 900.5, 64, 0.5), 0.05)), "corrected", "Config's policy")
	end)

	t.test("position store: a teleport resets the checks, a grant lets a push through", function()
		local store = PositionStore.new()
		local epoch = placed(store, "p", SURVIVAL, 0.5, 64, 0.5)
		local cap = MoveCheck.limits(SURVIVAL).horizontal * Config.Players.MoveSlack
		t.eq((store:move("p", move(1, epoch, 0.5 + cap - 0.5, 64, 0.5), 0.05)), "accepted", "the bucket emptied")
		local teleport = store:teleport("p", 0.5, 64, 0.5, nil, 0.1) :: PlayerSync.Teleport
		t.eq((store:move("p", move(2, teleport.epoch, 0.5 + cap - 0.5, 64, 0.5), 0.15)), "accepted", "full again")
		local e = (store:teleport("p", 0.5, 64, 0.5, nil, 0.2) :: PlayerSync.Teleport).epoch
		store:grant("p", 40, 0.2)
		t.eq((store:move("p", move(3, e, 0.5 + cap + 30, 64, 0.5), 0.25)), "accepted", "a granted push")
		store:grant("nobody", 40, 0.2)
	end)

	t.test("position store: spectators follow their target, their moves ignored", function()
		local store = PositionStore.new()
		placed(store, "target", SURVIVAL, 100.5, 64, 100.5)
		local se = placed(store, "ghost", SPECTATOR, 0.5, 80, 0.5)
		placed(store, "far", SURVIVAL, 5000.5, 64, 0.5)
		local ghost = store:get("ghost") :: PositionStore.Record
		local target = store:get("target") :: PositionStore.Record
		t.ok(not store:spectate("far", "target", 0), "only spectators spectate")
		t.ok(not store:spectate("ghost", "ghost", 0), "not oneself")
		t.ok(not store:spectate("ghost", "nobody", 0), "not an unknown player")
		t.ok(store:spectate("ghost", "target", 0), "a spectator spectates")
		t.eq(ghost.spectating, "target", "spectating")
		t.ok(ghost.x == 100.5 and ghost.y == 64 and ghost.z == 100.5, "at the target at once")
		t.eq((store:move("ghost", move(1, se, 3, 80, 3), 0.1)), "spectating", "own moves ignored")
		-- The target moves: the spectator follows at the next tick.
		target.x, target.z = 110.5, 90.5
		local version = ghost.version
		store:follow()
		t.ok(ghost.x == 110.5 and ghost.z == 90.5, "followed")
		t.ok(ghost.version > version, "a change for the relay")
		version = ghost.version
		store:follow()
		t.eq(ghost.version, version, "no change: same version")
		-- Chains: a spectator spectating the spectator ends at the target.
		placed(store, "second", SPECTATOR, -50, 64, -50)
		t.ok(store:spectate("second", "ghost", 0), "spectating a spectator")
		local second = store:get("second") :: PositionStore.Record
		t.ok(second.x == 110.5 and second.z == 90.5, "at the end of the chain")
		-- Loops are refused.
		t.ok(not store:spectate("ghost", "second", 0), "no loop")
		t.eq(ghost.spectating, nil, "a refused spectate ends spectating")
		t.ok(store:spectate("ghost", "target", 0), "back on the target")
		-- A teleport ends spectating.
		store:teleport("ghost", 0.5, 80, 0.5, nil, 1)
		t.eq(ghost.spectating, nil, "teleported: no longer spectating")
		t.ok(store:spectate("ghost", "target", 1), "again")
		-- Leaving spectator ends it.
		store:setMode("ghost", CREATIVE, 2)
		t.eq(ghost.spectating, nil, "creative: no longer spectating")
		t.eq(ghost.check.mode, CREATIVE, "MoveCheck heard of the mode")
		store:setMode("ghost", SPECTATOR, 3)
		t.ok(store:spectate("ghost", "target", 3), "again")
		-- Stopping (nil) and the target leaving.
		t.ok(not store:spectate("ghost", nil, 4), "nil: stopped")
		t.eq(ghost.spectating, nil, "stopped")
		store:spectate("ghost", "target", 4)
		store:leaving("target")
		t.eq(ghost.spectating, nil, "the target is leaving")
		t.ok((store:get("target") :: PositionStore.Record).known, "their place stays until removed")
		store:remove("target")
		t.eq(store:get("target"), nil, "gone")
		-- A target without a position can't be spectated.
		store:add("new", SURVIVAL, 5)
		t.ok(not store:spectate("ghost", "new", 5), "no position yet")
	end)
end

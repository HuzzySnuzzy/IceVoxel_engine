--[[
	Who learns what about whom (server Players/Interest, pure): `sees` starts at PlayerDistance
	(256) and keeps until PlayerDistance + PlayerHysteresis (272) both ways, horizontal only;
	spectators are seen by spectators alone; the spectated player is always seen; never oneself,
	nobody without a position; the dead stay seen. `update` turns that into tracks and untracks
	(a slot that changed is untracked and tracked again), `due` sends changed poses and keepalives.
	`chunkAllowed` (24 chunks, the spectated target's chunk), edit routing by chunk (26: all, some
	or none per player, none without a position), and the deferred chunk request queue (bounded,
	oldest dropped, answered once in range).
]]

return function(t, shared, require, server, _client)
	local Config = require(shared.Config)
	local GameMode = require(shared.GameMode)
	local PlayerSync = require(shared.Net.PlayerSync)
	local Interest = require(server.Players.Interest)
	local PositionStore = require(server.Players.PositionStore)

	local SURVIVAL, CREATIVE, SPECTATOR = GameMode.SURVIVAL, GameMode.CREATIVE, GameMode.SPECTATOR
	local DISTANCE = Config.Interest.PlayerDistance
	local STAY = DISTANCE + Config.Interest.PlayerHysteresis
	local CHUNK = Config.ChunkSize

	local function at(store: PositionStore.Store, key: string, mode: string, x: number, z: number): PositionStore.Record
		local record = store:add(key, mode, 0)
		store:spawned(key)
		store:teleport(key, x, 64, z, nil, 0)
		return record
	end

	t.test("interest: distance with hysteresis, horizontal only", function()
		local store = PositionStore.new()
		local a = at(store, "a", SURVIVAL, 0.5, 0.5)
		local b = at(store, "b", SURVIVAL, 0.5 + DISTANCE - 1, 0.5)
		t.ok(Interest.sees(a, b, false), "within 256: seen")
		t.ok(Interest.sees(b, a, false), "both ways")
		b.x = 0.5 + DISTANCE + 8
		t.ok(not Interest.sees(a, b, false), "beyond 256: not yet seen")
		t.ok(Interest.sees(a, b, true), "but kept until 272")
		b.x = 0.5 + STAY + 1
		t.ok(not Interest.sees(a, b, true), "beyond 272: gone")
		-- Diagonal (Euclidean), and height doesn't count.
		local d = DISTANCE / math.sqrt(2)
		b.x, b.z = 0.5 + d - 0.5, 0.5 + d - 0.5
		t.ok(Interest.sees(a, b, false), "diagonal within")
		b.x, b.z = 0.5 + d + 1, 0.5 + d + 1
		t.ok(not Interest.sees(a, b, false), "diagonal beyond (not Chebyshev)")
		b.x, b.z, b.y = 0.5, 0.5, 4000
		t.ok(Interest.sees(a, b, false), "height doesn't count")
		t.ok(not Interest.sees(a, a, false), "never oneself")
		-- No position: nobody, either way.
		store:left("b")
		t.ok(not Interest.sees(a, b, true), "a target without a position")
		t.ok(not Interest.sees(b, a, true), "a viewer without a position")
		-- The dead stay seen.
		local c = at(store, "c", SURVIVAL, 10, 10)
		store:setAlive("c", false)
		t.ok(Interest.sees(a, c, false), "dead: still seen")
		-- Leaving the game: gone at once, either way, though the place stays (their save).
		store:leaving("c")
		t.ok(c.known, "the place stays")
		t.ok(not Interest.sees(a, c, true), "a leaving player isn't seen")
		t.ok(not Interest.sees(c, a, true), "nor sees")
	end)

	t.test("interest: spectators are seen by spectators; the spectated always", function()
		local store = PositionStore.new()
		local walker = at(store, "walker", SURVIVAL, 0, 0)
		local builder = at(store, "builder", CREATIVE, 5, 5)
		local ghost = at(store, "ghost", SPECTATOR, 3, 3)
		local other = at(store, "other", SPECTATOR, 4, 4)
		t.ok(not Interest.sees(walker, ghost, false), "survival doesn't see a spectator")
		t.ok(not Interest.sees(builder, ghost, false), "creative doesn't either")
		t.ok(Interest.sees(ghost, walker, false), "the spectator sees them")
		t.ok(Interest.sees(other, ghost, false), "spectators see spectators")
		t.eq(Interest.seesMode(SURVIVAL, SPECTATOR), false, "the mode rule")
		t.eq(Interest.seesMode(SPECTATOR, SURVIVAL), true, "the mode rule")
		-- Spectating a far player: always seen, at any distance (the spectator's place follows,
		-- but even before the tick).
		local far = at(store, "far", SURVIVAL, 90000, -90000)
		t.ok(store:spectate("ghost", "far", 0), "spectating far away")
		ghost.x, ghost.z = 0, 0
		t.ok(Interest.sees(ghost, far, false), "the spectated is always seen")
		t.ok(not Interest.sees(far, ghost, false), "the spectated doesn't see their spectator")
	end)

	t.test("interest: update gives tracks and untracks, due gives poses", function()
		local store = PositionStore.new()
		local viewer = at(store, "v", SURVIVAL, 0, 0)
		at(store, "near", SURVIVAL, 10, 0)
		local leaving = at(store, "leaving", SURVIVAL, 20, 0)
		at(store, "far", SURVIVAL, 1000, 0)
		local seen: { [any]: Interest.Seen } = {}
		local tracks, untracks = {}, {}
		Interest.update(store.records, viewer, seen, 0, tracks, untracks)
		t.eq(#tracks, 2, "two tracked")
		t.eq(#untracks, 0, "none untracked")
		t.ok(seen.near ~= nil and seen.leaving ~= nil and seen.far == nil and seen.v == nil, "the near ones")
		-- Nothing changed: nothing to send.
		tracks, untracks = {}, {}
		Interest.update(store.records, viewer, seen, 0.05, tracks, untracks)
		t.eq(#tracks + #untracks, 0, "no changes")
		-- One walks away past the hysteresis, one leaves the game.
		leaving.x = STAY + 5
		local nearSlot = seen.near.slot
		store:remove("near")
		Interest.update(store.records, viewer, seen, 0.1, tracks, untracks)
		t.eq(#untracks, 2, "two untracked")
		t.ok(table.find(untracks, nearSlot) ~= nil, "by slot, even once gone")
		t.eq(next(seen), nil, "nobody seen")
		-- Coming back: tracked again; a rejoin (new slot) is untracked and tracked.
		leaving.x = 30
		tracks, untracks = {}, {}
		Interest.update(store.records, viewer, seen, 0.2, tracks, untracks)
		t.eq(#tracks, 1, "back in range")
		store:remove("leaving")
		at(store, "leaving", SURVIVAL, 30, 0)
		tracks, untracks = {}, {}
		Interest.update(store.records, viewer, seen, 0.3, tracks, untracks)
		t.eq(#untracks, 1, "the old slot untracked")
		t.eq(#tracks, 1, "the new slot tracked")

		-- Poses: changed ones, then keepalives.
		local out = {}
		t.eq(Interest.due(store.records, seen, 0.35, out), 0, "just tracked: nothing due")
		local record = store:get("leaving") :: PositionStore.Record
		record.x += 1
		record.version += 1
		t.eq(Interest.due(store.records, seen, 0.4, out), 1, "a change is due")
		t.eq(out[1], record, "that record")
		t.eq(Interest.due(store.records, seen, 0.45, out), 0, "sent: no longer due")
		t.eq(out[1], nil, "the list is cut to n")
		local keepAlive = Config.Interest.KeepAliveSeconds
		t.eq(Interest.due(store.records, seen, 0.4 + keepAlive, out), 1, "a keepalive")

		-- Records go on the wire as they are (PlayerRelay): poses and tracks round-trip.
		store:setAlive("leaving", false)
		local n = Interest.due(store.records, seen, 0.5 + keepAlive, out)
		t.eq(n, 1, "dying is a change")
		local decoded = {}
		local tick, count = PlayerSync.decodePoses(PlayerSync.encodePoses(7, out :: any, 1, n), decoded)
		t.eq(tick, 7, "tick")
		t.eq(count, 1, "one pose")
		t.eq(decoded[1].slot, record.slot, "the slot")
		t.near(decoded[1].x, record.x, 1 / 512, "x")
		t.eq(decoded[1].flags, record.flags, "flags")
		t.ok(bit32.btest(decoded[1].flags, PlayerSync.Flag.Dead), "the server's Dead flag")
	end)

	t.test("interest: chunk edit lists near the player only", function()
		local store = PositionStore.new()
		local radius = Config.Interest.EditChunkRadius
		local p = at(store, "p", SURVIVAL, 0.5, 0.5)
		t.ok(Interest.chunkAllowed(p, 0, 0), "their own chunk")
		t.ok(Interest.chunkAllowed(p, radius, -radius), "the corner of the square")
		t.ok(not Interest.chunkAllowed(p, radius + 1, 0), "one beyond")
		t.ok(not Interest.chunkAllowed(nil, 0, 0), "no player")
		-- Negative coordinates: floor.
		p.x, p.z = -0.5, -16.5
		t.ok(Interest.chunkAllowed(p, -1 - radius, -2 - radius), "floored chunk")
		t.ok(not Interest.chunkAllowed(p, radius, 0), "the other side")
		store:left("p")
		t.ok(not Interest.chunkAllowed(p, 0, 0), "no position: nothing")
		-- A spectator's place is their target's.
		local target = at(store, "target", SURVIVAL, 50000.5, 0.5)
		local ghost = at(store, "ghost", SPECTATOR, 0.5, 0.5)
		store:spectate("ghost", "target", 0)
		t.ok(Interest.chunkAllowed(ghost, Interest.chunkOf(target.x), 0), "the target's chunk")
		t.ok(not Interest.chunkAllowed(ghost, 0, 0), "not their old one")
		t.eq(Interest.chunkOf(-1), -1, "chunkOf floors")
		t.eq(Interest.chunkOf(CHUNK), 1, "chunkOf")
	end)

	t.test("interest: edits go to the players near them", function()
		local radius = Config.Interest.EditSendRadius
		-- One edit in chunk (0, 0), one in chunk (40, 0).
		local pending = { 3, 64, 5, 1, 40 * CHUNK + 2, 70, 1, 2 }
		local viewers = {
			{ key = "both", cx = 20, cz = 0 },
			{ key = "first", cx = -radius, cz = radius },
			{ key = "second", cx = 40 + radius, cz = 0 },
			{ key = "neither", cx = 0, cz = radius + 1 },
		}
		local routed = Interest.routeEdits(pending, viewers)
		t.eq(routed.both, true, "within 26 of both: everything (one shared message)")
		local first = routed.first :: { number }
		t.eq(type(first), "table", "only some")
		t.eq(#first, 4, "one edit")
		t.eq(first[1], 3, "the first edit's x")
		t.eq(first[4], 1, "its block")
		local second = routed.second :: { number }
		t.eq(#second, 4, "one edit")
		t.eq(second[1], 40 * CHUNK + 2, "the second edit")
		t.eq(second[2], 70, "its y")
		t.eq(routed.neither, nil, "none")
		t.eq(next(Interest.routeEdits({}, viewers)), nil, "no edits: nothing")
		-- Negative blocks are in negative chunks.
		local negative = Interest.routeEdits({ -1, 64, -1, 1 }, { { key = "x", cx = radius, cz = radius } })
		t.eq(negative.x, nil, "chunk (-1, -1) is 27 away from (26, 26)")
		local edge = Interest.routeEdits({ -1, 64, -1, 1 }, { { key = "x", cx = radius - 1, cz = 0 } })
		t.eq(edge.x, true, "26 away: reached")
	end)

	t.test("interest: deferred chunk requests", function()
		local deferred = Interest.newDeferred(3)
		deferred:add(1, 1)
		deferred:add(2, 2)
		deferred:add(1, 1)
		t.eq(deferred:count(), 2, "once each")
		deferred:add(3, 3)
		deferred:add(-4, -4)
		t.eq(deferred:count(), 3, "bounded")
		local taken = deferred:take(function()
			return true
		end)
		t.eq(#taken, 3, "everything allowed")
		t.eq(taken[1][1], 2, "the oldest (1, 1) was dropped")
		t.eq(taken[3][1], -4, "negative chunks")
		t.eq(taken[3][2], -4, "negative chunks")
		t.eq(deferred:count(), 0, "taken out")
		-- Only those allowed now.
		deferred:add(0, 0)
		deferred:add(100, 0)
		local near = deferred:take(function(cx: number, _cz: number): boolean
			return math.abs(cx) <= 24
		end)
		t.eq(#near, 1, "the near one")
		t.eq(deferred:count(), 1, "the far one waits")
		deferred:add(0, 0)
		t.eq(deferred:count(), 2, "taken ones can come again")
		t.eq(Interest.newDeferred().limit, Config.Interest.DeferredChunkRequests, "Config's limit")
		local none = Interest.newDeferred(0)
		none:add(1, 1)
		t.eq(none:count(), 0, "a limit of 0 keeps nothing")
	end)
end

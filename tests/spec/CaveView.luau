--[[
	The cave view: how far caves are seen from underground. Full detail reaches further while the
	camera is in a cave (LodTree's underground split, held a few seconds after coming up), caves are
	revealed further (Config.Caves), revealed sections next to hidden space get their caps at the
	new edges (CaveReach.capMask), and glow lichen's lights stay few (GreedyMesher's sparse lights:
	one per LIGHT_BOX box, all on: Config.Caves.LichenLightDistance is math.huge).
]]

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Coords = require(shared.World.Coords)
	local GreedyMesher = require(shared.Meshing.GreedyMesher)
	local LodTree = require(shared.World.LodTree)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local CaveReach = require(client.Streaming.CaveReach)

	local SIZE = Config.ChunkSize
	local SECTION = Config.SectionHeight
	local lod = Config.Lod

	local function restore()
		LodTree.configure(lod.ViewDistance, lod.SplitDistance, lod.SplitDistanceL1, lod.UndergroundSplitDistanceL1)
	end

	-- Full detail chunks of a selection, as a set of chunk keys.
	local function fullDetail(nodes: { [number]: number }): { [number]: boolean }
		local set = {}
		for key, level in nodes do
			if level == 0 then
				local _, nx, nz = Coords.decodeNodeKey(key)
				set[Coords.chunkKey(nx, nz)] = true
			end
		end
		return set
	end

	local function count(set: { [any]: any }): number
		local n = 0
		for _ in set do
			n += 1
		end
		return n
	end

	-- The nearest column (blocks from the viewer) that is not full detail.
	local function fullDetailReach(set: { [number]: boolean }, x: number, z: number): number
		local best = math.huge
		local r = 24
		for cz = z // SIZE - r, z // SIZE + r do
			for cx = x // SIZE - r, x // SIZE + r do
				if not set[Coords.chunkKey(cx, cz)] then
					local dx = math.max(cx * SIZE - x, 0, x - (cx + 1) * SIZE)
					local dz = math.max(cz * SIZE - z, 0, z - (cz + 1) * SIZE)
					best = math.min(best, math.sqrt(dx * dx + dz * dz))
				end
			end
		end
		return best
	end

	t.test("cave view: settings reach further than before and fit the full detail range", function()
		t.ok(lod.UndergroundSplitDistanceL1 > lod.SplitDistanceL1, "underground, full detail reaches further")
		t.ok(Config.Caves.RevealRadius > 48 and Config.Caves.RevealRadiusMax > 96, "caves are revealed further")
		-- Revealing beyond full detail does nothing (caves only exist there); the radius plus a
		-- section (section centres) fits what the underground split keeps full detail.
		t.ok(
			Config.Caves.RevealRadiusMax <= lod.UndergroundSplitDistanceL1 * 2 * SIZE,
			"the largest reveal radius fits the underground full detail range"
		)
		local mobile = Config.Caves.Mobile
		t.ok(mobile.RevealRadius <= Config.Caves.RevealRadius, "phones reveal less")
		t.ok(mobile.RevealRadiusMax <= Config.Caves.RevealRadiusMax)
		t.ok(mobile.LichenLightDistance <= Config.Caves.LichenLightDistance)
		t.ok(lod.Mobile.UndergroundSplitDistanceL1 <= lod.UndergroundSplitDistanceL1)
		t.ok(lod.Mobile.UndergroundSplitDistanceL1 > lod.Mobile.SplitDistance, "phones see caves further too")
		t.ok(lod.UndergroundSeconds > 0)
	end)

	t.test("cave view: underground, full detail reaches further; the tiling stays whole", function()
		restore()
		for _, pos in { { 0, 0 }, { 1000.5, -333.25 }, { -4096, 77 } } do
			local above = LodTree.select(pos[1], pos[2])
			local below = LodTree.select(pos[1], pos[2], nil, true)
			local aboveSet, belowSet = fullDetail(above), fullDetail(below)
			for key in aboveSet do
				t.ok(belowSet[key], "every full detail chunk stays full detail underground")
			end
			t.ok(count(belowSet) > count(aboveSet), "more full detail chunks underground")
			local reachAbove = fullDetailReach(aboveSet, pos[1], pos[2])
			local reachBelow = fullDetailReach(belowSet, pos[1], pos[2])
			t.ok(reachAbove >= lod.SplitDistanceL1 * 2 * SIZE * 0.9, `full detail above ground: {reachAbove}`)
			t.ok(reachBelow >= lod.UndergroundSplitDistanceL1 * 2 * SIZE * 0.9, `full detail underground: {reachBelow}`)
			-- Every chunk covered exactly once.
			local covered: { [number]: number } = {}
			for key, level in below do
				local _, nx, nz = Coords.decodeNodeKey(key)
				local span = bit32.lshift(1, level)
				for cz = nz * span, nz * span + span - 1 do
					for cx = nx * span, nx * span + span - 1 do
						local k = Coords.chunkKey(cx, cz)
						covered[k] = (covered[k] or 0) + 1
					end
				end
			end
			for _, n in covered do
				t.eq(n, 1, "chunk covered more than once")
			end
		end
		t.eq(LodTree.splitDistanceL1(false), lod.SplitDistanceL1)
		t.eq(LodTree.splitDistanceL1(true), lod.UndergroundSplitDistanceL1)
		-- The phone preset: its own, smaller underground split; never below the normal one.
		LodTree.configure(lod.Mobile.ViewDistance, lod.Mobile.SplitDistance, nil, lod.Mobile.UndergroundSplitDistanceL1)
		local ok, err = pcall(function()
			t.eq(LodTree.splitDistanceL1(true), lod.Mobile.UndergroundSplitDistanceL1)
			local phone = fullDetail(LodTree.select(0, 0, nil, true))
			restore()
			local computer = fullDetail(LodTree.select(0, 0, nil, true))
			t.ok(count(phone) < count(computer), "phones keep fewer full detail chunks underground")
			LodTree.configure(lod.ViewDistance, lod.SplitDistance, 3, 1)
			t.eq(LodTree.splitDistanceL1(true), 3, "an underground split below the normal one is ignored")
		end)
		restore()
		assert(ok, err)
	end)

	t.test("cave view: going underground after walking above ground reaches as far as a fresh view", function()
		restore()
		local reachUnderground = lod.UndergroundSplitDistanceL1 * 2 * SIZE
		for _, pos in { { 520.5, -143.5 }, { 0.5, 0.5 }, { -4096, 77 } } do
			local x, z = pos[1], pos[2]
			-- The streamer's way: every refresh passes the last selection (hysteresis).
			local previous = nil
			for step = 300, 0, -4 do
				previous = LodTree.select(x - step, z, previous, false, false)
			end
			-- The cave view starts here: level 1 leaves of the selection above ground split as in a
			-- fresh selection (no hysteresis across the change).
			local below = LodTree.select(x, z, previous, true, false)
			local fresh = fullDetail(LodTree.select(x, z, nil, true))
			local belowSet = fullDetail(below)
			t.eq(count(belowSet), count(fresh), "as many full detail chunks as a fresh selection")
			for key in fresh do
				t.ok(belowSet[key], "the same full detail chunks")
			end
			t.ok(
				fullDetailReach(belowSet, x, z) >= reachUnderground * 0.95,
				"full detail reaches the underground range"
			)
			-- Staying underground keeps them.
			local again = fullDetail(LodTree.select(x, z, below, true, true))
			t.eq(count(again), count(belowSet))
			-- Coming up: back to the selection above ground.
			local above = fullDetail(LodTree.select(x, z, below, false, true))
			t.eq(count(above), count(fullDetail(LodTree.select(x, z, nil, false))), "the normal range above ground")

			-- Walking underground: ahead of the viewer, hysteresis keeps full detail at most 15% short.
			local walking = nil
			for step = 300, 0, -4 do
				walking = LodTree.select(x - step, z, walking, true, true)
			end
			local reach = fullDetailReach(fullDetail(walking :: any), x, z)
			t.ok(reach >= reachUnderground * 0.85, `full detail ahead while walking underground: {reach}`)
		end
	end)

	t.test("cave view: the underground split is held a few seconds after coming up", function()
		local hold = CaveReach.hold(5)
		t.eq(hold:update(false, 0), false, "above ground")
		t.eq(hold:update(true, 1), true, "in a cave")
		t.eq(hold:update(false, 2), true, "just came up")
		t.eq(hold:update(false, 5.9), true)
		t.eq(hold:update(false, 6.1), false, "after the hold")
		t.eq(hold:update(true, 7), true, "back in")
		t.eq(hold:update(true, 20), true)
		t.eq(hold:update(false, 24.9), true, "held from the last moment underground")
		t.eq(hold:update(false, 25.1), false)
	end)

	t.test("cave view: revealed sections are capped at the new edges", function()
		restore()
		local x, y, z = 8.5, 200.5, 8.5
		local radius = Config.Caves.RevealRadiusMax
		local reach = radius + SECTION
		local desired = fullDetail(LodTree.select(x, z, nil, true))
		local revealed, edge, inner = 0, 0, 0
		for key in desired do
			local cx, cz = Coords.decodeChunkKey(key)
			for s = 0, Config.WorldHeight // SECTION - 1 do
				if CaveReach.reveals(cx, cz, s, x, y, z, reach) then
					revealed += 1
					local mask = CaveReach.capMask(desired, cx, cz, s, x, y, z, reach)
					for i, side in { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } } do
						local nx, nz = cx + side[1], cz + side[2]
						local open = desired[Coords.chunkKey(nx, nz)] ~= nil
							and CaveReach.reveals(nx, nz, s, x, y, z, reach)
						t.eq(bit32.btest(mask, bit32.lshift(1, i - 1)), not open, "a side is capped unless revealed")
						if not desired[Coords.chunkKey(nx, nz)] then
							edge += 1
						elseif open then
							inner += 1
						end
					end
					t.eq(
						bit32.btest(mask, GreedyMesher.HIDDEN_BELOW),
						s > 0 and not CaveReach.reveals(cx, cz, s - 1, x, y, z, reach)
					)
					t.eq(
						bit32.btest(mask, GreedyMesher.HIDDEN_ABOVE),
						not CaveReach.reveals(cx, cz, s + 1, x, y, z, reach)
					)
				end
			end
		end
		t.ok(revealed > 0 and inner > 0, "sections revealed")
		-- The revealed sphere fits the underground full detail range: hardly any revealed section
		-- touches a chunk without caves (those sides are capped all the same).
		t.ok(edge < revealed * 0.1, `revealed sides next to coarser nodes: {edge} of {revealed} sections`)
		print(`    {revealed} sections revealed at radius {radius}, {edge} sides next to coarser nodes`)
	end)

	t.test("cave view: lichen light is sparse and steady: a few hundred lights in a revealed cave", function()
		local gen = TerrainGenerator.new(12345)
		-- A camera in the most open cave cell of a stretch of chunks under the hills.
		local chunks: { [number]: any } = {}
		local function chunk(cx: number, cz: number)
			local key = Coords.chunkKey(cx, cz)
			local r = chunks[key]
			if r == nil then
				r = gen.generate(0, cx, cz)
				chunks[key] = r
			end
			return r
		end
		local function getBlock(bx: number, by: number, bz: number): number?
			local fx, fy, fz = math.floor(bx), math.floor(by), math.floor(bz)
			if fy < 0 then
				return nil
			end
			local r = chunk(fx // SIZE, fz // SIZE)
			if fy >= r.height then
				return Blocks.AIR
			end
			return ChunkLayout.get(r.data, fx % SIZE, fy, fz % SIZE)
		end
		local camera, best = nil, -1
		for cx = 30, 34 do
			local r = chunk(cx, -9)
			for yy = 10, r.height - 20, 4 do
				if ChunkLayout.get(r.data, 8, yy, 8) == Blocks.CAVE_AIR then
					local open = CaveReach.probe(getBlock, cx * SIZE + 8.5, yy + 0.5, -9 * SIZE + 8.5, 48)
					if open > best then
						best, camera = open, { cx * SIZE + 8.5, yy + 0.5, -9 * SIZE + 8.5 }
					end
				end
			end
		end
		assert(camera, "a cave under the hills")
		local reach = Config.Caves.RevealRadius + SECTION
		local lichen, marked, boxesLit = 0, 0, 0
		for cx = (camera[1] - reach) // SIZE, (camera[1] + reach) // SIZE do
			for cz = (camera[3] - reach) // SIZE, (camera[3] + reach) // SIZE do
				local r = chunk(cx, cz)
				for s = 0, (r.height - 1) // SECTION do
					if CaveReach.reveals(cx, cz, s, camera[1], camera[2], camera[3], reach) then
						local y0, y1 = s * SECTION, math.min((s + 1) * SECTION, r.height)
						local boxes, n = GreedyMesher.mesh(r.data, r.height, y0, y1, false, nil, true)
						local again, m = GreedyMesher.mesh(r.data, r.height, y0, y1, false, nil, true)
						t.eq(m, n)
						t.ok(
							buffer.len(boxes) == buffer.len(again) and buffer.tostring(boxes) == buffer.tostring(again),
							"steady"
						)
						local lit: { [string]: boolean } = {}
						for b = 0, n - 1 do
							local o = b * GreedyMesher.BOX_BYTES
							local app, surface = GreedyMesher.decodeKey(buffer.readu16(boxes, o + 12))
							if buffer.readu8(GreedyMesher.sparseLightLut, app) == 1 then
								lichen += 1
								if surface == 1 then
									marked += 1
									local bx, by, bz =
										buffer.readu16(boxes, o),
										buffer.readu16(boxes, o + 2),
										buffer.readu16(boxes, o + 4)
									local box = GreedyMesher.LIGHT_BOX
									local key = `{bx // box},{by // box},{bz // box}`
									t.ok(not lit[key], "one light per box")
									lit[key] = true
									boxesLit += 1
								end
							end
						end
					end
				end
			end
		end
		print(
			string.format(
				"    camera in a cave at %d, %d, %d: %d lichen revealed, %d carry a light (all on)",
				camera[1],
				camera[2],
				camera[3],
				lichen,
				marked
			)
		)
		t.ok(lichen > 0, "lichen in the caves around")
		t.ok(marked < lichen / 2, "most lichen carries no light")
		-- (Every lichen light is on, Caves.LichenLightDistance being math.huge: one per 8^3 box
		-- keeps a revealed cave to a few hundred PointLights.)
		t.eq(Config.Caves.LichenLightDistance, math.huge, "lichen lights on at any distance")
		t.ok(marked <= 600, `lichen lights in the revealed caves: {marked}`)
	end)
end

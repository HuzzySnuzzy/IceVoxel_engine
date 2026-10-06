--[[
	The cave view: how far caves are seen from underground. Full detail reaches further while the
	camera is shut in underground (CaveReach.enclosed: in a cave or under rock, not at the open
	bottom of a pit or a ravine; LodTree's underground split, held a few seconds after that); the
	revealed sections are the ones SectionGraph's search reaches (CaveReach.view: reach, hold,
	pending chunks, caps where they meet hidden space, searching only when something changed), as
	far as Config.Caves and the cave view setting say; on real caves that costs about the old
	reveal sphere's parts while tunnels are seen further; walking down a real cave entrance turns
	the view on and reveals the cave beyond, and in a real ravine the search stays out of the sky;
	and glow lichen's lights stay few (GreedyMesher's sparse lights: one per LIGHT_BOX box, all on:
	Config.Caves.LichenLightDistance is math.huge).
]]

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Coords = require(shared.World.Coords)
	local GreedyMesher = require(shared.Meshing.GreedyMesher)
	local LodTree = require(shared.World.LodTree)
	local SectionGraph = require(shared.World.SectionGraph)
	local PlayerSettings = require(shared.PlayerSettings)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local Caves = require(shared.Generation.Caves)
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

	-- Is section `s` of chunk (cx, cz) within `reach` of (x, y, z) (section centres): the old sphere.
	local function inSphere(cx: number, cz: number, s: number, x: number, y: number, z: number, reach: number): boolean
		local dx = (cx + 0.5) * SIZE - x
		local dz = (cz + 0.5) * SIZE - z
		local dy = (s + 0.5) * SECTION - y
		return dx * dx + dy * dy + dz * dz < reach * reach
	end

	t.test("cave view: settings reach further than before and fit the full detail range", function()
		t.ok(lod.UndergroundSplitDistanceL1 > lod.SplitDistanceL1, "underground, full detail reaches further")
		t.ok(Config.Caves.RevealRadius > 48 and Config.Caves.RevealRadiusMax > 96, "caves are revealed further")
		t.ok(
			Config.Caves.RevealReach > Config.Caves.RevealRadius + SECTION,
			"tunnels are seen further than the sphere did"
		)
		t.ok(Config.Caves.RevealReach <= Config.Caves.RevealRadiusMax + SECTION, "caverns still see furthest")
		t.ok(Config.Caves.RevealBudget >= 1000 and Config.Caves.RevealHold > 0)
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

	t.test("cave view: only a camera shut in underground starts the underground split", function()
		-- Rock up to the surface (cell 100), air above; columns x 0..4 dug in different ways,
		-- column 9 not loaded.
		local SURFACE = 100
		local cells: { [string]: number } = {}
		local function getBlock(x: number, y: number, z: number): number?
			if x == 9 then
				return nil -- not loaded
			end
			return cells[`{x},{y},{z}`] or if y < SURFACE then Blocks.id.Stone else Blocks.AIR
		end
		local function dig(x: number, y0: number, y1: number, id: number)
			for y = y0, y1 do
				cells[`{x},{y},0`] = id
			end
		end
		local function shut(x: number, y: number): boolean
			return CaveReach.enclosed(getBlock, x + 0.5, y + 0.6, 0.5, SURFACE)
		end
		dig(0, 60, 99, Blocks.AIR)
		t.eq(shut(0, 60), false, "the bottom of a shaft open to the sky (a pit, a ravine)")
		t.eq(shut(0, 97), false, "just under the surface")
		dig(1, 60, 70, Blocks.AIR)
		t.eq(shut(1, 60), true, "under rock")
		dig(2, 40, 99, Blocks.AIR)
		dig(2, 40, 50, Blocks.CAVE_AIR)
		t.eq(shut(2, 41), true, "in a cave under a ravine's cut")
		local twin
		for id = 0, Blocks.count - 1 do
			if buffer.readu8(Blocks.caveTwinLut, id) == 1 then
				twin = id
				break
			end
		end
		assert(twin, "a cave twin")
		dig(3, 40, 99, Blocks.AIR)
		cells["3,40,0"] = twin
		t.eq(shut(3, 40), true, "in a cave twin's cell")
		dig(4, 40, 99, Blocks.AIR)
		cells["4,90,0"] = Blocks.id.Glass
		cells["4,91,0"] = Blocks.id.Water
		t.eq(shut(4, 40), false, "glass and water let the sky in")
		cells["4,95,0"] = Blocks.id.Stone
		t.eq(shut(4, 40), true, "a block of rock overhead")
		t.eq(shut(9, 40), true, "not loaded: generated ground")
	end)

	--[[ The revealed set (CaveReach.view) on a synthetic world ]]

	type World = {
		set: (x: number, y: number, z: number, id: number) -> (),
		box: (x0: number, y0: number, z0: number, x1: number, y1: number, z1: number, id: number) -> (),
		lookup: SectionGraph.Lookup,
		full: { [number]: boolean },
		pending: { [number]: boolean },
		graphs: { [number]: buffer },
	}

	-- Chunks -r..r around the origin, rock up to `ground` (cells), air above, all of it buried.
	local function world(r: number, height: number, ground: number): World
		local chunks: { [number]: buffer } = {}
		local w = { full = {}, pending = {}, graphs = {} } :: World
		for cz = -r, r do
			for cx = -r, r do
				local data = ChunkLayout.create(height)
				for y = 0, ground - 1 do
					for i = 0, ChunkLayout.LAYER - 1 do
						buffer.writeu16(data, (y * ChunkLayout.LAYER + i) * 2, Blocks.id.Stone)
					end
				end
				chunks[Coords.chunkKey(cx, cz)] = data
				w.full[Coords.chunkKey(cx, cz)] = true
			end
		end
		function w.set(x: number, y: number, z: number, id: number)
			local data = chunks[Coords.chunkKey(x // SIZE, z // SIZE)]
			if data then
				ChunkLayout.set(data, x % SIZE, y, z % SIZE, id)
				w.graphs[Coords.chunkKey(x // SIZE, z // SIZE)] = nil
			end
		end
		function w.box(x0: number, y0: number, z0: number, x1: number, y1: number, z1: number, id: number)
			for y = y0, y1 do
				for z = z0, z1 do
					for x = x0, x1 do
						w.set(x, y, z, id)
					end
				end
			end
		end
		function w.lookup(cx: number, cz: number): (buffer | false)?
			local key = Coords.chunkKey(cx, cz)
			if not w.full[key] then
				return nil
			end
			if w.pending[key] then
				return false
			end
			local g = w.graphs[key]
			if g == nil then
				local all = {}
				for s = 0, height // SECTION - 1 do
					table.insert(all, s)
				end
				g = SectionGraph.build(chunks[key], height, ground, all)
				w.graphs[key] = g
			end
			return g
		end
		return w
	end

	local function setOf(list: { number }): { [number]: boolean }
		local set = {}
		for _, v in list do
			set[v] = true
		end
		return set
	end

	t.test("cave view: reveals what the search reaches, holds it, pending chunks, searches only on change", function()
		local w = world(6, 64, 60)
		-- A cave tunnel along +X at y 20, z 8 from x 4 to 6 chunks on; a cave behind rock beside it.
		w.box(4, 20, 8, 6 * SIZE + 15, 21, 8, Blocks.CAVE_AIR)
		w.box(4, 20, 2 * SIZE + 4, 10, 25, 2 * SIZE + 10, Blocks.CAVE_AIR)
		local view = CaveReach.view(2, 1500)
		local added, removed = view:update(w.lookup, 8.5, 20.6, 8.5, 88, 0, false)
		local key = SectionGraph.key
		t.eq(#removed, 0)
		t.eq(view.count, #added, "count")
		for cx = 0, 5 do
			t.ok(view:reveals(cx, 0, 1), `tunnel chunk {cx} revealed`)
		end
		t.ok(not view:reveals(6, 0, 1), "beyond the reach (section centre 96.5 blocks away)")
		t.ok(not view:reveals(0, 2, 1), "a cave behind rock stays hidden")
		t.eq(view.searches, 1)

		-- Caps: tunnel ends and sides face hidden space, the tunnel's own direction does not.
		local function full(cx: number, cz: number): boolean
			return w.full[Coords.chunkKey(cx, cz)] == true
		end
		local mask = view:capMask(2, 0, 1, full)
		t.ok(not bit32.btest(mask, 1) and not bit32.btest(mask, 2), "open along the tunnel")
		t.ok(bit32.btest(mask, 4) and bit32.btest(mask, 8), "capped beside it")
		t.ok(bit32.btest(mask, GreedyMesher.HIDDEN_BELOW) and bit32.btest(mask, GreedyMesher.HIDDEN_ABOVE))
		t.ok(bit32.btest(view:capMask(5, 0, 1, full), 2), "capped where the reach ends")
		w.full[Coords.chunkKey(3, 0)] = nil
		t.ok(bit32.btest(view:capMask(2, 0, 1, full), 2), "capped against a chunk that is not full detail")
		w.full[Coords.chunkKey(3, 0)] = true

		-- Same section, nothing changed: no search.
		view:update(w.lookup, 9.5, 21.6, 9.5, 88, 0.5, false)
		t.eq(view.searches, 1, "same camera section: no search")
		view:update(w.lookup, 9.5, 21.6, 9.5, 88, 0.6, true)
		t.eq(view.searches, 2, "dirty: searched again")
		view:update(w.lookup, 9.5, 21.6, 9.5, 104, 0.7, false)
		t.eq(view.searches, 3, "the reach changed: searched again")
		t.ok(view:reveals(6, 0, 1), "a longer reach sees further")

		-- The camera walks back along the tunnel: the far end drops out but stays `hold` seconds.
		added, removed = view:update(w.lookup, 8.5 - 3 * SIZE + 4, 20.6, 8.5, 88, 1, false)
		t.eq(#removed, 0, "nothing hidden at once")
		t.ok(view:reveals(6, 0, 1), "held")
		added, removed = view:update(w.lookup, 8.5 - 3 * SIZE + 4, 20.6, 8.5, 88, 2.5, false)
		t.eq(#removed, 0, "no search and before the hold ran out: nothing")
		added, removed = view:update(w.lookup, 8.5 - 3 * SIZE + 4, 20.6, 8.5, 88, 3.05, false)
		t.ok(setOf(removed)[key(6, 0, 1)], "hidden once unreachable for the hold")
		t.ok(not view:reveals(6, 0, 1))

		-- A chunk not generated yet: the sections the search would enter count as revealed.
		w.pending[Coords.chunkKey(1, 0)] = true
		view:update(w.lookup, 8.5, 20.6, 8.5, 88, 4, true)
		t.ok(view:reveals(1, 0, 1), "pending section revealed")
		w.pending[Coords.chunkKey(1, 0)] = nil

		-- Above ground: everything goes after the hold.
		local before = view.count
		added, removed = view:update(w.lookup, nil, nil, nil, 0, 5, false)
		t.eq(#removed, 0, "kept a while")
		t.eq(view.count, before)
		added, removed = view:update(w.lookup, nil, nil, nil, 0, 7.1, false)
		t.eq(#removed, before, "all hidden after the hold")
		t.eq(view.count, 0)
		t.eq(next(view.revealed), nil)
	end)

	t.test("cave view: an edit that opens a wall reveals the cave behind it", function()
		local w = world(4, 64, 60)
		-- A cave into chunk 2, a wall of rock at x 41..43, a second cave beyond it into chunk 3.
		-- (Not next to the camera's section: the search leaves those through any face.)
		w.box(4, 20, 8, 40, 21, 8, Blocks.CAVE_AIR)
		w.box(44, 20, 8, 3 * SIZE + 12, 21, 8, Blocks.CAVE_AIR)
		local view = CaveReach.view(2, 1500)
		view:update(w.lookup, 8.5, 20.6, 8.5, 88, 0, false)
		t.ok(view:reveals(2, 0, 1), "the wall's section")
		t.ok(not view:reveals(3, 0, 1), "behind the wall: hidden")
		w.box(41, 20, 8, 43, 21, 8, Blocks.AIR)
		local added = view:update(w.lookup, 8.5, 20.6, 8.5, 88, 0.2, true)
		t.ok(setOf(added)[SectionGraph.key(3, 0, 1)], "dug through: revealed")
	end)

	t.test("cave view: tunnels reach further than the old sphere, caverns as far as the probe", function()
		t.eq(CaveReach.searchReach(88, 64), 88, "a tunnel: the tunnel reach")
		t.eq(CaveReach.searchReach(88, 128), 144, "a big cavern: the radius plus a section")
		local high = PlayerSettings.defaults(false, 0, PlayerSettings.HIGH)
		t.eq(PlayerSettings.revealReach(high), Config.Caves.RevealReach, "High: Config's tunnel reach")
		local tunnels, caverns = PlayerSettings.revealRadii(high)
		t.eq(tunnels, Config.Caves.RevealRadius)
		t.eq(caverns, Config.Caves.RevealRadiusMax)
		local low = PlayerSettings.defaults(true, 0)
		local lowTunnels = PlayerSettings.revealRadii(low)
		t.ok(PlayerSettings.revealReach(low) >= lowTunnels + SECTION, "phones: never less than the old sphere")
		local cave = PlayerSettings.byKey.caveView
		local last = 0
		for v = cave.min, cave.max, cave.step do
			high.caveView = v
			local reach = PlayerSettings.revealReach(high)
			local min = PlayerSettings.revealRadii(high)
			t.ok(reach >= last, "grows with the slider")
			t.eq(reach % SectionGraph.BAND, 0, "whole bands")
			t.ok(reach >= min + SECTION - SectionGraph.BAND, `cave view {v}: about the sphere's tunnels or more`)
			last = reach
		end
	end)

	--[[ Real caves ]]

	t.test("cave view: on a real cave the search sees tunnels further for about the sphere's parts", function()
		-- Cave A near the spawn (seed 12345, the research's scene): full detail chunks within 7
		-- chunks of the camera (the reach is 88 blocks, the old sphere's 80).
		local gen = TerrainGenerator.new(12345)
		local chunks: { [number]: any } = {}
		local function chunk(cx: number, cz: number): any
			local key = Coords.chunkKey(cx, cz)
			local r = chunks[key]
			if r == nil then
				r = gen.generate(0, cx, cz)
				r.graph = SectionGraph.build(
					r.data,
					r.height,
					r.solidBelow,
					SectionGraph.carvedSections(r.carved, Caves.CELL_Y)
				)
				chunks[key] = r
			end
			return r
		end
		local x, y, z = 512.5, 13.6, -159.5
		local ccx, ccz = math.floor(x) // SIZE, math.floor(z) // SIZE
		local R = 7
		local function inArea(cx: number, cz: number): boolean
			return math.abs(cx - ccx) <= R and math.abs(cz - ccz) <= R
		end
		local function lookup(cx: number, cz: number): (buffer | false)?
			if not inArea(cx, cz) then
				return nil
			end
			return chunk(cx, cz).graph
		end
		local function full(cx: number, cz: number): boolean
			return inArea(cx, cz)
		end
		local t0 = os.clock()
		for cz = ccz - R, ccz + R do
			for cx = ccx - R, ccx + R do
				chunk(cx, cz)
			end
		end
		local view = CaveReach.view(2, Config.Caves.RevealBudget)
		view:update(
			lookup,
			x,
			y,
			z,
			CaveReach.searchReach(Config.Caves.RevealReach, Config.Caves.RevealRadius),
			0,
			false
		)
		local searchMs = view.searchMs
		-- Parts each set adds over hidden caves (caps from the set), and the farthest cave section.
		local function cost(set: { [number]: boolean }): (number, number)
			local added, farthest = 0, 0
			for key in set do
				local cx, cz, s = SectionGraph.decode(key)
				if inArea(cx, cz) then
					local r = chunk(cx, cz)
					local y0, y1 = s * SECTION, math.min((s + 1) * SECTION, r.height)
					if y0 < r.height then
						local mask = SectionGraph.capMask(set, cx, cz, s, full)
						local _, shown = GreedyMesher.mesh(r.data, r.height, y0, y1, false, { hidden = mask }, true)
						local _, hidden = GreedyMesher.mesh(r.data, r.height, y0, y1, true, nil, true)
						added += shown - hidden
						if bit32.btest(SectionGraph.get(r.graph, s), SectionGraph.CAVES) then
							local dx, dy, dz = (cx + 0.5) * SIZE - x, (s + 0.5) * SECTION - y, (cz + 0.5) * SIZE - z
							farthest = math.max(farthest, math.sqrt(dx * dx + dy * dy + dz * dz))
						end
					end
				end
			end
			return added, farthest
		end
		local sphere: { [number]: boolean } = {}
		for cz = ccz - R, ccz + R do
			for cx = ccx - R, ccx + R do
				for s = 0, 10 do
					if inSphere(cx, cz, s, x, y, z, Config.Caves.RevealRadius + SECTION) then
						sphere[SectionGraph.key(cx, cz, s)] = true
					end
				end
			end
		end
		local graphParts, graphFar = cost(view.revealed)
		local sphereParts, sphereFar = cost(sphere)
		print(
			string.format(
				"    cave A: search %.2f ms, %d sections revealed: +%d parts, caves seen %.0f blocks away; old sphere: +%d parts, %.0f blocks (%.1f s)",
				searchMs,
				view.count,
				graphParts,
				graphFar,
				sphereParts,
				sphereFar,
				os.clock() - t0
			)
		)
		t.ok(graphFar > sphereFar + 4, "tunnels are seen further")
		t.ok(graphParts <= sphereParts * 1.3, "for about the sphere's parts")
		t.ok(view.count < Config.Caves.RevealBudget and not view.truncated)
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
		local reveals = inSphere
		for cx = (camera[1] - reach) // SIZE, (camera[1] + reach) // SIZE do
			for cz = (camera[3] - reach) // SIZE, (camera[3] + reach) // SIZE do
				local r = chunk(cx, cz)
				for s = 0, (r.height - 1) // SECTION do
					if reveals(cx, cz, s, camera[1], camera[2], camera[3], reach) then
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

	--[[ Surface caves: real entrances and ravines ]]

	local DIRS = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }

	--[[
		Generated full detail chunks with the graphs ChunkWorker builds (the lattice hint, the
		sections holding air carved below the surface, the surface as the sky line); `old`: the
		graph without a sky line (the rules before surface caves).
	]]
	local function realWorld(gen: any)
		local chunks: { [number]: any } = {}
		local w = {}
		function w.chunk(cx: number, cz: number): any
			local key = Coords.chunkKey(cx, cz)
			local r = chunks[key]
			if r == nil then
				r = gen.generate(0, cx, cz, nil, true)
				local exact: { [number]: boolean } = {}
				if r.structureSpan then
					for s = r.structureSpan[1] // SECTION, r.structureSpan[2] // SECTION do
						exact[s] = true
					end
				end
				SectionGraph.dugSections(r.data, r.height, r.surface, r.solidBelow, exact)
				local extra = {}
				for s in exact do
					table.insert(extra, s)
				end
				local list = SectionGraph.carvedSections(r.carved, Caves.CELL_Y, extra)
				r.graph = SectionGraph.build(r.data, r.height, r.solidBelow, list, {
					carved = r.carved,
					cellXZ = Caves.CELL_XZ,
					cellY = Caves.CELL_Y,
					originX = cx * SIZE,
					originZ = cz * SIZE,
					surface = r.surface,
					exact = exact,
				})
				r.old = SectionGraph.build(r.data, r.height, r.solidBelow, list)
				chunks[key] = r
			end
			return r
		end
		function w.block(x: number, y: number, z: number): number?
			if y < 0 then
				return nil
			end
			local r = w.chunk(x // SIZE, z // SIZE)
			if y >= r.height then
				return Blocks.AIR
			end
			return ChunkLayout.get(r.data, x % SIZE, y, z % SIZE)
		end
		-- The generated surface (first air block before any carving) of column (x, z).
		function w.surface(x: number, z: number): number
			local r = w.chunk(x // SIZE, z // SIZE)
			return buffer.readu16(r.surface, ((z % SIZE) * SIZE + x % SIZE) * 2)
		end
		return w
	end

	--[[
		Air carved below the surface (a surface cave) that touches cave air and has a way out to
		the open sky through carved air, scanning the chunks around (cx, cz) outwards: { x, y, z }
		of that air and of the cave air, and the way out (mouth first).
	]]
	local function findEntrance(w: any, cx: number, cz: number, r: number): ({ number }?, { { number } }?)
		local function key(x: number, y: number, z: number): string
			return `{x},{y},{z}`
		end
		-- Breadth first from `junction` through carved air to a cell under the open sky.
		local tried: { [string]: boolean } = {}
		local function wayOut(junction: { number }): { { number } }?
			local from: { [string]: { number } | false } = { [key(junction[1], junction[2], junction[3])] = false }
			local queue = { { junction[1], junction[2], junction[3] } }
			local head, mouth = 1, nil
			while head <= #queue do
				local p = queue[head]
				head += 1
				if p[2] + 1 >= w.surface(p[1], p[3]) then
					mouth = p
					break
				end
				for _, d in DIRS do
					local x, y, z = p[1] + d[1], p[2] + d[2], p[3] + d[3]
					local k = key(x, y, z)
					if from[k] == nil and w.block(x, y, z) == Blocks.AIR and y < w.surface(x, z) then
						from[k] = p
						tried[k] = true
						table.insert(queue, { x, y, z })
					end
				end
			end
			if mouth == nil then
				return nil
			end
			local path = {}
			local p: { number }? = mouth
			while p do
				table.insert(path, p)
				p = from[key(p[1], p[2], p[3])] or nil
			end
			return path
		end
		for ring = 0, r do
			for dz = -ring, ring do
				for dx = -ring, ring do
					if math.abs(dx) ~= ring and math.abs(dz) ~= ring then
						continue
					end
					local c = w.chunk(cx + dx, cz + dz)
					for z = 0, SIZE - 1 do
						for x = 0, SIZE - 1 do
							local top = buffer.readu16(c.surface, (z * SIZE + x) * 2)
							for y = math.max(c.solidBelow, 1), top - 1 do
								local wx, wz = (cx + dx) * SIZE + x, (cz + dz) * SIZE + z
								if ChunkLayout.get(c.data, x, y, z) ~= Blocks.AIR or tried[key(wx, y, wz)] then
									continue
								end
								for _, d in DIRS do
									if w.block(wx + d[1], y + d[2], wz + d[3]) == Blocks.CAVE_AIR then
										local junction = { wx, y, wz, wx + d[1], y + d[2], wz + d[3] }
										local path = wayOut(junction)
										if path then
											return junction, path
										end
										break
									end
								end
							end
						end
					end
				end
			end
		end
		return nil, nil
	end

	t.test("cave view: walking down a real cave entrance turns it on and reveals the cave beyond", function()
		local gen = TerrainGenerator.new(12345)
		local w = realWorld(gen)
		local junction, path = findEntrance(w, 0, 6, 5)
		assert(junction and path, "a surface cave meeting a cave near chunk 0, 6")
		local caveKey = SectionGraph.key(junction[4] // SIZE, junction[6] // SIZE, junction[5] // SECTION)
		local ccx, ccz = junction[1] // SIZE, junction[3] // SIZE
		local function lookupOf(field: string): SectionGraph.Lookup
			return function(cx: number, cz: number): (buffer | false)?
				if math.abs(cx - ccx) > 9 or math.abs(cz - ccz) > 9 then
					return nil
				end
				return w.chunk(cx, cz)[field]
			end
		end
		local lookup = lookupOf("graph")
		local reach = CaveReach.searchReach(Config.Caves.RevealReach, Config.Caves.RevealRadius)
		local view = CaveReach.view(Config.Caves.RevealHold, Config.Caves.RevealBudget)
		local switched, revealed, most, shutAt = nil, nil, 0, nil
		for i, c in path do
			local x, y, z = c[1] + 0.5, c[2] + 0.6, c[3] + 0.5
			-- The streamer's switch: the camera below its column's generated surface.
			local surface = gen.column(c[1], c[3])
			local under = y < surface - 1
			if under then
				switched = switched or i
				-- The underground split: only once shut in under rock.
				if shutAt == nil and CaveReach.enclosed(w.block, x, y, z, surface) then
					shutAt = i
				end
				view:update(lookup, x, y, z, reach, i * 0.25, false)
				most = math.max(most, view.reached)
				t.ok(not view.truncated, "within the budget")
			else
				t.eq(switched, nil, "once underground, the way down stays underground")
				view:update(lookup, nil, nil, nil, 0, i * 0.25, false)
			end
			if revealed == nil and view.revealed[caveKey] then
				revealed = i
			end
		end
		assert(switched and revealed, "the cave view came on and revealed the cave")
		t.ok(switched > 1, "off at the mouth, under the open sky")
		t.ok(switched <= 4, `on a few blocks into the entrance (step {switched})`)
		t.ok(shutAt ~= nil and shutAt > switched, `the underground split after the open mouth (step {shutAt})`)
		local j = junction
		t.ok(
			CaveReach.enclosed(w.block, j[4] + 0.5, j[5] + 0.6, j[6] + 0.5, gen.column(j[4], j[6])),
			"shut in, in the cave"
		)
		t.ok(revealed < #path, "the cave is revealed before the camera reaches it")
		-- As soon as the junction's section is within the search's reach.
		local c = path[switched]
		local dx = (junction[4] // SIZE + 0.5) * SIZE - c[1]
		local dy = (junction[5] // SECTION + 0.5) * SECTION - c[2]
		local dz = (junction[6] // SIZE + 0.5) * SIZE - c[3]
		if math.sqrt(dx * dx + dy * dy + dz * dz) < reach - SECTION then
			t.eq(revealed, switched, "the cave beyond the entrance shows as the view comes on")
		end
		-- The rules before: the open entrance is not followed from its mouth.
		local old = SectionGraph.search(lookupOf("old"), c[1] + 0.5, c[2] + 0.6, c[3] + 0.5, { reach = reach })
		local new = SectionGraph.search(lookup, c[1] + 0.5, c[2] + 0.6, c[3] + 0.5, { reach = reach })
		print(
			string.format(
				"    entrance %d,%d,%d -> cave %d,%d,%d (%d blocks): on at step %d, shut in at %d, cave revealed at %d; %d sections reached at the mouth (old rules %d, cave %s), at most %d",
				path[1][1],
				path[1][2],
				path[1][3],
				junction[4],
				junction[5],
				junction[6],
				#path,
				switched,
				shutAt or 0,
				revealed,
				new.count,
				old.count,
				if old.reached[caveKey] then "reached" else "not reached",
				most
			)
		)
		t.ok(most < 600, `no sky in the search ({most} sections)`)
	end)

	t.test("cave view: in a real ravine the view comes on and the search stays out of the sky", function()
		local gen = TerrainGenerator.new(12345)
		local w = realWorld(gen)
		-- The deepest open cut (carved air open to the sky) in chunks every 2 along a stretch.
		local best, camera = 0, nil
		for cz = -30, -24, 2 do
			for cx = 30, 38, 2 do
				local c = w.chunk(cx, cz)
				for z = 0, SIZE - 1 do
					for x = 0, SIZE - 1 do
						local top = buffer.readu16(c.surface, (z * SIZE + x) * 2)
						local y = top - 1
						while y > 0 and ChunkLayout.get(c.data, x, y, z) == Blocks.AIR do
							y -= 1
						end
						if top - 1 - y > best then
							best, camera = top - 1 - y, { cx * SIZE + x, y + 1, cz * SIZE + z }
						end
					end
				end
			end
		end
		assert(camera and best >= 15, `a ravine near 540, -420 (deepest cut {best})`)
		local x, y, z = camera[1] + 0.5, camera[2] + 0.6, camera[3] + 0.5
		t.ok(y < gen.column(camera[1], camera[3]) - 1, "a camera at the bottom of a ravine is underground")
		t.ok(
			not CaveReach.enclosed(w.block, x, y, z, gen.column(camera[1], camera[3])),
			"under the open sky: no underground split"
		)
		local ccx, ccz = camera[1] // SIZE, camera[3] // SIZE
		local result = SectionGraph.search(function(cx: number, cz: number): (buffer | false)?
			if math.abs(cx - ccx) > 8 or math.abs(cz - ccz) > 8 then
				return nil
			end
			return w.chunk(cx, cz).graph
		end, x, y, z, { reach = Config.Caves.RevealReach })
		-- Sky air is never followed: nothing well above the ground is reached.
		local above = 0
		for key in result.reached do
			local cx, cz, s = SectionGraph.decode(key)
			local c = w.chunk(cx, cz)
			local high = 0
			for i = 0, SIZE * SIZE - 1 do
				high = math.max(high, buffer.readu16(c.surface, i * 2))
			end
			if s * SECTION >= high + SECTION then
				above += 1
			end
		end
		print(
			string.format(
				"    ravine %d deep at %d,%d,%d: %d sections reached, %d above the ground",
				best,
				camera[1],
				camera[2],
				camera[3],
				result.count,
				above
			)
		)
		t.eq(above, 0, "no section above the ground beyond the camera's neighbours")
		t.ok(result.count < 400 and not result.truncated, `a few hundred sections at most ({result.count})`)
	end)
end

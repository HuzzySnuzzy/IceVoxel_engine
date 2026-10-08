--[[
	The server's chunk preloading (World/GenQueue, World/WorldServer.install; World/Simulation is the
	glue): the windows and the queue's order, abandoning, chunks made meanwhile, failures, the
	budget's packing (fake clock), installs (edits, crop growth, onGenerated once, the race with
	getChunk), and on the Default generator: a chunk generated a yield at a time on a second
	instance, with the world's generator run at every yield, is the chunk generated in one go, and
	slices keep near their budget (the generator yields inside its long decisions: Generation/
	Lakes, SurfaceCaves, Mineshafts, TerrainGenerator).
]]

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Coords = require(shared.World.Coords)
	local WorldTypes = require(shared.Generation.WorldTypes)
	local WorldServer = require(server.World.WorldServer)
	local GenQueue = require(server.World.GenQueue)

	local STONE, AIR = Blocks.id.Stone, Blocks.AIR
	local P = ChunkLayout.PADDED

	-- A fake world: which chunks are loaded, and what was installed, in order.
	local function fakeWorld()
		local loaded: { [number]: boolean } = {}
		local installs: { { number } } = {}
		local w = {
			loaded = loaded,
			installs = installs,
			isLoaded = function(cx: number, cz: number): boolean
				return loaded[Coords.chunkKey(cx, cz)] == true
			end,
			install = function(cx: number, cz: number): boolean
				local key = Coords.chunkKey(cx, cz)
				if loaded[key] then
					return false
				end
				loaded[key] = true
				table.insert(installs, { cx, cz })
				return true
			end,
		}
		return w
	end

	-- A queue over a fake world whose chunks are generated at once (or with `generate`).
	local function newQueue(world, generate: ((cx: number, cz: number, yield: () -> ()) -> (buffer, number))?, clock)
		return GenQueue.new({
			radius = 3,
			generate = generate or function(): (buffer, number)
				return buffer.create(0), 0
			end,
			install = function(cx: number, cz: number): boolean
				return world.install(cx, cz)
			end,
			loaded = world.isLoaded,
			clock = clock,
		})
	end

	t.test("genqueue: windows, closest first, ties by age then coordinates, no duplicates", function()
		local world = fakeWorld()
		local q = newQueue(world)
		q:update({ 0, 0 })
		t.eq(#q.active, 49, "7 x 7 near chunks")
		t.eq(q:backlog(), 49)
		t.ok(q:keeps(4, -4) and q:isNear(3, -3), "the kept ring is one wider than the near window")
		t.ok(not q:keeps(5, 0) and not q:isNear(4, 0), "nothing beyond")
		t.eq(q:step(1), 49, "all generated (instant)")
		local order = world.installs
		t.eq(order[1][1], 0)
		t.eq(order[1][2], 0, "the player's own chunk first")
		-- Then the four at distance 1, in z then x order: (0, -1), (-1, 0), (1, 0), (0, 1).
		local expected = { { 0, -1 }, { -1, 0 }, { 1, 0 }, { 0, 1 } }
		for i, e in expected do
			t.eq(order[i + 1][1], e[1], `ring 1 #{i} x`)
			t.eq(order[i + 1][2], e[2], `ring 1 #{i} z`)
		end
		local last = 0
		for i, c in order do
			local d2 = c[1] * c[1] + c[2] * c[2]
			t.ok(d2 >= last, `closest first (#{i})`)
			last = d2
		end

		-- Two overlapping windows: each chunk once, at its nearest player's distance.
		local w2 = fakeWorld()
		local q2 = newQueue(w2)
		q2:update({ 0, 0, 1, 0 })
		t.eq(q2:backlog(), 56, "8 x 7 distinct chunks")
		q2:step(1)
		t.eq(#w2.installs, 56)
		t.ok(w2.installs[1][1] == 0 and w2.installs[2][1] == 1, "both own chunks first")

		-- Ties by age: a second player's chunks at the same distance come after the first's.
		local w3 = fakeWorld()
		local q3 = newQueue(w3)
		q3:update({ 0, 0 })
		q3:update({ 0, 0, 100, 0 })
		q3:step(1)
		t.eq(w3.installs[1][1], 0, "queued earlier")
		t.eq(w3.installs[2][1], 100, "then the newcomer's own chunk")
		t.eq(w3.installs[3][1] + w3.installs[3][2], -1, "then the older ring (0, -1)")
		for i = 3, 6 do
			t.ok(math.abs(w3.installs[i][1]) <= 1, `the first player's ring before the second's (#{i})`)
		end
	end)

	t.test("genqueue: generated chunks skipped, windows left dropped, the job in flight abandoned", function()
		local world = fakeWorld()
		world.loaded[Coords.chunkKey(1, 0)] = true
		local yields = 0
		local q = newQueue(world, function(_cx: number, _cz: number, yield: () -> ()): (buffer, number)
			for _ = 1, 3 do
				yields += 1
				yield()
			end
			return buffer.create(0), 0
		end)
		q:update({ 0, 0 })
		t.eq(q:backlog(), 48, "a loaded chunk isn't queued")
		-- Budget 0: every yield suspends.
		t.eq(q:step(0), 0, "the first job started")
		t.eq(q:backlog(), 47)
		q:update({ 0, 0 })
		t.eq(q:backlog(), 47, "the chunk in flight isn't queued again")
		-- A chunk made meanwhile (getChunk) is skipped when its turn comes.
		world.loaded[Coords.chunkKey(0, -1)] = true
		for _ = 1, 3 do
			q:step(0)
		end
		t.eq(#world.installs, 1, "(0, 0) done")
		t.eq(q:stats().inFlight, nil, "(the step ended with it)")
		q:step(0)
		local flight = q:stats().inFlight
		t.eq(flight and flight.cx, -1, "(0, -1) skipped, (-1, 0) next")

		-- The player leaves: the queue empties and the job in flight is dropped.
		q:update({ 1000, 1000 })
		t.eq(q.abandoned, 1)
		t.eq(q:stats().inFlight, nil)
		t.eq(q:backlog(), 49, "the new window")
		local before = #world.installs
		q:step(1)
		for i = before + 1, #world.installs do
			t.ok(world.installs[i][1] >= 997, "nothing of the old window is installed")
		end
		t.eq(q.generated, 50)
	end)

	t.test("genqueue: a chunk made while in flight keeps its own; failures aren't retried", function()
		local world = fakeWorld()
		local q = newQueue(world, function(_cx: number, _cz: number, yield: () -> ()): (buffer, number)
			yield()
			return buffer.create(0), 0
		end)
		q:update({ 0, 0 })
		q:step(0)
		world.loaded[Coords.chunkKey(0, 0)] = true -- (getChunk, while the job waits)
		q:step(0)
		t.eq(q.dropped, 1, "the late terrain is dropped")
		t.eq(#world.installs, 0)

		local warned = {}
		local w2 = fakeWorld()
		local q2 = GenQueue.new({
			radius = 0,
			generate = function(cx: number): (buffer, number)
				if cx == 0 then
					error("broken")
				end
				return buffer.create(0), 0
			end,
			install = w2.install,
			loaded = w2.isLoaded,
			warn = function(message: string)
				table.insert(warned, message)
			end,
		})
		q2:update({ 0, 0, 5, 0 })
		q2:step(1)
		t.eq(q2.failed, 1)
		t.eq(#warned, 1)
		t.ok(string.find(warned[1], "(0, 0)", 1, true) ~= nil, "the warning names the chunk")
		t.eq(#w2.installs, 1, "the other chunk still generated")
		q2:update({ 0, 0, 5, 0 })
		t.eq(q2:backlog(), 0, "not queued again")
		t.eq(#q2:describe(), 3, "stats lines")
	end)

	t.test("genqueue: urgent while a player's 3 x 3 is missing; steps pack chunks into the budget", function()
		local now = 0
		local function clock(): number
			return now
		end
		local world = fakeWorld()
		-- 3.5 ms of work per chunk, yielding every 0.1 ms.
		local q = newQueue(world, function(_cx: number, _cz: number, yield: () -> ()): (buffer, number)
			for _ = 1, 35 do
				now += 0.0001
				yield()
			end
			return buffer.create(0), 0
		end, clock)
		q:update({ 0, 0 })
		t.ok(q:urgent(), "own chunks missing")
		-- The frame's budget: urgent, or a big backlog; never past the frame's own; at least least.
		local limits = { normal = 4, urgent = 8, backlog = 49, frame = 12, least = 1 }
		t.eq(q:budget(limits, 0), 8, "own chunks missing")
		t.eq(q:budget(limits, 6), 6, "the frame spent 6 of its 12 ms")
		t.eq(q:budget(limits, 20), 1, "at least `least`")
		local w2 = fakeWorld()
		for dz = -1, 1 do
			for dx = -1, 1 do
				w2.loaded[Coords.chunkKey(dx, dz)] = true
			end
		end
		local q2 = newQueue(w2)
		q2:update({ 0, 0 })
		t.eq(q2:budget(limits, 0), 4, "40 chunks waiting, own ones there")
		q2:update({ 0, 0, 50, 50 })
		t.eq(q2:budget(limits, 0), 8, "a newcomer")
		q2:step(1)
		t.eq(q2:budget(limits, 0), 4, "all done")
		q2:update({ 0, 0, 50, 50, 100, 100 })
		w2.loaded[Coords.chunkKey(100, 100)] = true
		t.eq(q2:budget(limits, 0), 8, "a newcomer missing 8 of its 3 x 3")
		q2:step(1)
		for _, c in { { 200, 200 }, { 300, 300 } } do
			for dz = -1, 1 do
				for dx = -1, 1 do
					w2.loaded[Coords.chunkKey(c[1] + dx, c[2] + dz)] = true
				end
			end
		end
		q2:update({ 0, 0, 50, 50, 100, 100, 200, 200, 300, 300 })
		t.eq(q2:backlog(), 80)
		t.eq(q2:budget(limits, 0), 8, "own chunks there, but 80 chunks waiting")
		local steps, worst = 0, 0
		while q:backlog() > 0 or q:stats().inFlight do
			local start = now
			q:step(0.008)
			worst = math.max(worst, now - start)
			steps += 1
			now += 0.010 -- (the rest of the frame)
			if steps == 3 then
				t.ok(q:urgent(), "6 chunks in 3 frames")
			elseif steps == 5 then
				t.ok(not q:urgent(), "the 3 x 3 came first (9 chunks in 4 frames)")
			end
			assert(steps < 100)
		end
		t.eq(#world.installs, 49)
		t.ok(worst <= 0.008 + 0.0001 + 1e-9, `a step ends at the first yield past its budget ({worst * 1000} ms)`)
		-- 49 x 3.5 ms in 8 ms steps: 22 frames (a whole chunk a frame took 49).
		t.ok(steps <= 23, `{steps} frames for 49 chunks`)
		local stats = q:stats()
		t.ok(stats.worstStepMs <= 8.2 and stats.chunksPerSecond > 0, "stats")
	end)

	-- A flat stone world (y < 10), chunks cropped at 32, as tests/spec/Server.
	local FLOOR, CROP = 10, 32
	local function flatChunk(): (buffer, number)
		local data = ChunkLayout.create(CROP)
		for y = 0, FLOOR - 1 do
			for i = 0, ChunkLayout.LAYER - 1 do
				buffer.writeu16(data, (y * ChunkLayout.LAYER + i) * 2, STONE)
			end
		end
		return data, CROP
	end
	local flat = {
		generate = function(level: number, nx: number, nz: number)
			local data, height = flatChunk()
			return { data = data, level = level, nx = nx, nz = nz, height = height }
		end,
	}
	local function blockIn(chunk: WorldServer.Chunk, lx: number, y: number, lz: number): number
		if y >= chunk.height then
			return AIR
		end
		return buffer.readu16(chunk.data, ((y * P + lz + 1) * P + lx + 1) * 2)
	end

	t.test("install: edits laid over (above the crop too), onGenerated once, a chunk there kept", function()
		local world = WorldServer.new(flat :: any)
		local generated = 0
		world.onGenerated = function()
			generated += 1
		end
		world.edits[Coords.chunkKey(0, 0)] = {
			[ChunkLayout.localIndex(3, 5, 4)] = AIR,
			[ChunkLayout.localIndex(1, 40, 2)] = STONE,
		}
		local data, height = flatChunk()
		local chunk, fresh = world:install(0, 0, data, height)
		t.ok(fresh, "installed")
		t.eq(generated, 1)
		t.eq(blockIn(chunk, 3, 5, 4), AIR, "an edit")
		t.ok(chunk.height > 40, "grown above the crop")
		t.eq(blockIn(chunk, 1, 40, 2), STONE, "an edit above the crop")
		t.eq(blockIn(chunk, 0, 0, 0), STONE, "the terrain")

		local again, fresh2 = world:install(0, 0, flatChunk())
		t.ok(again == chunk and not fresh2, "the chunk there is kept")
		t.eq(generated, 1, "onGenerated once")
		t.eq(world:getChunk(0, 0), chunk)
		t.eq(world.inlineChunks, 0, "getChunk didn't generate it")
		world:getChunk(1, 0)
		t.eq(world.inlineChunks, 1, "getChunk counts its own")
		t.eq(generated, 2)
	end)

	t.test("install: the race with getChunk and with edits loaded while a job runs", function()
		local world = WorldServer.new(flat :: any)
		local generated = 0
		world.onGenerated = function()
			generated += 1
		end
		local q = GenQueue.new({
			radius = 0,
			generate = function(cx: number, cz: number, yield: () -> ()): (buffer, number)
				yield()
				local r = flat.generate(0, cx, cz)
				return r.data, r.height
			end,
			install = function(cx: number, cz: number, data: buffer, height: number): boolean
				local _, fresh = world:install(cx, cz, data, height)
				return fresh
			end,
			loaded = function(cx: number, cz: number): boolean
				return world:peekChunk(cx, cz) ~= nil
			end,
		})
		-- A player's edit while the job waits: setBlock generates the chunk inline.
		q:update({ 0, 0 })
		q:step(0)
		t.ok(world:setBlock(2, 3, 2, AIR), "edited")
		q:step(0)
		t.eq(q.dropped, 1)
		t.eq(world:getBlock(2, 3, 2), AIR, "the edit stands")
		t.eq(generated, 1, "onGenerated once")

		-- A loaded world's edits arriving while a job runs are laid over at install.
		q:update({ 5, 0 })
		q:step(0)
		world.edits[Coords.chunkKey(5, 0)] = { [ChunkLayout.localIndex(0, 2, 0)] = AIR }
		q:step(0)
		t.eq(q.generated, 1)
		t.eq(world:getBlock(80, 2, 0), AIR, "laid over")
		t.eq(world:getBlock(81, 2, 0), STONE)
		t.eq(generated, 2)
	end)

	-- Cold chunks spread over the Default world (lakes, puddles, surface caves, mineshafts).
	local SPREAD = {
		{ -812, 377 },
		{ 1203, -95 },
		{ 40, 40 },
		{ -1500, -1499 },
		{ 733, 1288 },
		{ 5, -1210 },
		{ -260, 902 },
		{ 1444, 1100 },
	}

	t.test("default world: sliced on a second instance = in one go, the first run at every yield", function()
		local background = WorldTypes.create("default", 12345, {})
		local main = WorldTypes.create("default", 12345, {})
		local reference = WorldTypes.create("default", 12345, {})
		local sites: { [string]: number } = {}
		local results: { [number]: { data: buffer, height: number } } = {}
		local q = GenQueue.new({
			radius = 0,
			generate = function(cx: number, cz: number, yield: () -> ()): (buffer, number)
				local r = background.generate(0, cx, cz, function()
					local source = debug.info(2, "s")
					local site = string.match(source, "(%w+)%.luau") or string.match(source, '(%w+)"%]$') or source
					sites[site] = (sites[site] or 0) + 1
					yield()
				end)
				return r.data, r.height
			end,
			install = function(cx: number, cz: number, data: buffer, height: number): boolean
				results[Coords.chunkKey(cx, cz)] = { data = data, height = height }
				return true
			end,
			loaded = function(cx: number, cz: number): boolean
				return results[Coords.chunkKey(cx, cz)] ~= nil
			end,
		})
		local interleaved = 0
		for _, c in SPREAD do
			local cx, cz = c[1], c[2]
			q:update({ cx, cz })
			local k = 0
			while results[Coords.chunkKey(cx, cz)] == nil do
				q:step(0)
				-- The world's generator, at every yield of the background one: its neighbours.
				k += 1
				local nx, nz = cx + 2 + k % 3, cz - 2
				local r = main.generate(0, nx, nz)
				interleaved += 1
				if k <= 3 then
					local want = reference.generate(0, nx, nz)
					t.ok(
						r.height == want.height and buffer.tostring(r.data) == buffer.tostring(want.data),
						`({nx}, {nz}) generated while the background one waits`
					)
				end
			end
			local got = results[Coords.chunkKey(cx, cz)]
			local want = reference.generate(0, cx, cz)
			t.eq(got.height, want.height, `({cx}, {cz}) height`)
			t.ok(buffer.tostring(got.data) == buffer.tostring(want.data), `({cx}, {cz}) blocks`)
		end
		t.ok(interleaved > 8 * 20, `{interleaved} interleavings`)
		-- The yields inside the long decisions were among them.
		for _, site in { "Lakes", "SurfaceCaves", "Mineshafts", "TerrainGenerator", "Caves" } do
			t.ok((sites[site] or 0) > 0, `yields in {site}`)
		end
	end)

	t.test("default world: slices keep near the budget on cold chunks", function()
		local background = WorldTypes.create("default", 12345, {})
		local BUDGET = 0.004
		local done = 0
		local q = GenQueue.new({
			radius = 0,
			generate = function(cx: number, cz: number, yield: () -> ()): (buffer, number)
				local r = background.generate(0, cx, cz, yield)
				return r.data, r.height
			end,
			install = function(): boolean
				done += 1
				return true
			end,
			loaded = function(): boolean
				return false
			end,
		})
		local steps: { number } = {}
		local centers = {}
		for i, c in SPREAD do
			-- (Two chunks a spot: one cold, one beside it.)
			table.insert(centers, c[1] + 7)
			table.insert(centers, c[2] - 3)
			table.insert(centers, c[1] + 8 + i % 2)
			table.insert(centers, c[2] - 3)
		end
		q:update(centers)
		local total = os.clock()
		while done < #centers // 2 do
			local start = os.clock()
			q:step(BUDGET)
			table.insert(steps, (os.clock() - start) * 1000)
		end
		total = (os.clock() - total) * 1000
		table.sort(steps)
		local p90 = steps[math.ceil(#steps * 0.9)]
		local max = steps[#steps]
		print(
			string.format(
				"    %d cold chunks in %d steps of %.0f ms: p50 %.2f, p90 %.2f, max %.2f ms (%.1f ms a chunk)",
				done,
				#steps,
				BUDGET * 1000,
				steps[math.ceil(#steps * 0.5)],
				p90,
				max,
				total / done
			)
		)
		-- Generous (timing under load): the old way was a whole chunk, ~11 ms cold and up to 45.
		t.ok(p90 <= BUDGET * 1000 + 6, `p90 step {p90} ms`)
		t.ok(max <= BUDGET * 1000 + 25, `max step {max} ms`)
	end)
end
